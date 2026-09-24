//////////////////////////////////////////////////////////////////////////////////
// tb_md_hw.v - the Mega Drive wired the way the BOARD wires it.
//
// tb_md_console already proves the console runs, but it feeds it from a few
// lines of testbench that answer a line request in a single cycle and never say
// no. The board feeds it from md_cart, which takes four cycles, holds ready low
// while it works, and is filled beforehand by the host over the register bus.
//
// On hardware the 68000 sat at PC $000000 and never fetched anything. Everything
// upstream passed: md_cart's own testbench, the console's own testbench, the
// byte order, the build. What had never been tested was the two of them
// TOGETHER, which is exactly the seam a fault of that shape lives in.
//
// So this is the seam: real md_cart, filled the way the host fills it, driving
// the real console. If the CPU runs here and not on the board, the fault is
// outside both; if it stops here too, it is in the handshake between them and
// visible in a waveform instead of a register read over Ethernet.
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none

module tb_md_hw;

	localparam AW = 12;                    // 16 kB, ample for the test program

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz, as on the board

	reg  [AW-1:0] host_windex = 0;
	reg           host_we = 0;
	reg  [31:0]   wdata = 0;

	wire [19:0]  m_addr;
	wire         m_req, m_ready, m_valid;
	wire [127:0] m_data;

	md_cart #(.AW(AW)) u_cart (
		.clk(clk), .rst(rst),
		.host_windex(host_windex), .host_we(host_we), .wdata(wdata),
		.host_rdata(),
		.m_addr(m_addr), .m_req(m_req), .m_ready(m_ready),
		.m_data(m_data), .m_valid(m_valid)
	);

	wire        px_valid;
	wire [8:0]  px_x, px_y;
	wire [7:0]  px_rgb;
	wire [31:0] dbg_pc;

	md_console u_md (
		.clk(clk), .rst(rst),
		.mem_addr(m_addr), .mem_req(m_req), .mem_ready(m_ready),
		.mem_data(m_data), .mem_valid(m_valid),
		.joy1(8'hFF), .joy2(8'hFF),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.audio_l(), .audio_r(), .dbg_pc(dbg_pc)
	);

	integer fails = 0;
	task ok;
		input cond;
		input [800:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); fails = fails + 1; end
		end
	endtask

	// The program, as 16-bit words exactly as the assembler emits them.
	reg [15:0] img [0:8191];
	integer    ii;

	integer i, pixels;
	reg [31:0] pc_first, pc_later;
	reg [15:0] lo, hi;

	initial begin
		for (i = 0; i < 8192; i = i + 1) img[i] = 16'h0000;
		// Defined everywhere first. The 68000 prefetches two words ahead, so a
		// program that stops at the end of an 868-byte ROM still fetches past
		// it -- and an X opcode is not a missing instruction, it is a testbench
		// that stops modelling the board where the ROM stops. Real memory holds
		// something there.
		for (ii = 0; ii < 8192; ii = ii + 1) img[ii] = 16'd0;
		$readmemh("../../sim/roms/md/mdtest.hex", img);

		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		// Fill it the way the HOST does: 32-bit words, the ROM's bytes packed
		// little-endian into lanes. Two of the assembler's big-endian words go
		// into each one, and md_cart puts them back the right way round on the
		// way out. Packing this wrong here would hide exactly the bug being
		// looked for, so it is written out rather than done with a helper.
		for (i = 0; i < (1 << AW); i = i + 1) begin
			lo = img[2*i];          // the earlier address
			hi = img[2*i + 1];
			@(negedge clk);
			host_windex = i[AW-1:0];
			wdata = {hi[7:0], hi[15:8], lo[7:0], lo[15:8]};
			host_we = 1;
		end
		@(negedge clk);
		host_we = 0;

		// Let it out of reset and give it time to fetch its vectors and start.
		repeat (200) @(posedge clk);
		pc_first = dbg_pc;
		$display("    after 200 clocks the 68000 is at %08X", pc_first);
		ok(pc_first !== 32'h0000_0000,
		   "the 68000 fetched its reset vector and left address zero");

		repeat (20000) @(posedge clk);
		pc_later = dbg_pc;
		if (u_md.md.cpu.bad_hit)
			$display("    CPU TRAPPED: opcode $%04h at PC $%06h",
			         u_md.md.cpu.bad_op, u_md.md.cpu.bad_pc);
		$display("    after 20200 clocks it is at %08X", pc_later);
		ok(pc_later !== pc_first, "and it is still executing, not spinning");

		// The program draws; the console should be emitting pixels.
		pixels = 0;
		for (i = 0; i < 200000; i = i + 1) begin
			@(posedge clk);
			if (px_valid) pixels = pixels + 1;
		end
		$display("    %0d pixels in 200000 clocks", pixels);
		ok(pixels > 1000, "the VDP is putting pixels out");

		if (fails == 0) $display("tb_md_hw: all checks passed");
		else            $display("tb_md_hw: %0d FAIL(s)", fails);
		$finish;
	end

endmodule

`default_nettype wire
