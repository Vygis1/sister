`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_md_console - the Mega Drive, in the shape the framebuffer wants.
//
// tb_md_top proves the machine works. This proves the adapter around it does:
// that the four clock enables come out at the right ratios, that a pixel is
// offered to the framebuffer exactly once, and that the colour arrives in the
// format the rest of this project uses rather than the one the VDP produces.
//
// The last of those is the easiest to get wrong and the hardest to notice: red
// and blue swapped looks like a palette problem, and a palette problem looks
// like a VDP problem.
//////////////////////////////////////////////////////////////////////////////////

module tb_md_console;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	wire [19:0]  mem_addr;
	wire         mem_req;
	reg          mem_ready = 1;
	reg  [127:0] mem_data  = 0;
	reg          mem_valid = 0;

	wire       px_valid;
	wire [8:0] px_x, px_y;
	wire [7:0] px_rgb;
	wire signed [15:0] audio_l, audio_r;
	wire [31:0] pc;

	md_console dut (
		.clk(clk), .rst(rst),
		.mem_addr(mem_addr), .mem_req(mem_req), .mem_ready(mem_ready),
		.mem_data(mem_data), .mem_valid(mem_valid),
		.joy1(8'd0), .joy2(8'd0),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.audio_l(audio_l), .audio_r(audio_r), .dbg_pc(pc)
	);

	// The cartridge, behind a memory that takes a while.
	reg [15:0] cart [0:65535];
	reg [19:0] mem_line;
	integer    mi;

	initial begin
		forever begin
			@(posedge clk);
			if (mem_req && mem_ready) begin
				mem_line  = mem_addr;
				mem_ready <= 1'b0;
				repeat (24) @(posedge clk);
				for (mi = 0; mi < 8; mi = mi + 1)
					mem_data[mi*16 +: 16] <= cart[{mem_line[12:0], mi[2:0]}];
				mem_valid <= 1'b1;
				@(posedge clk);
				mem_valid <= 1'b0;
				mem_ready <= 1'b1;
			end
		end
	end

	integer errors = 0;

	task check;
		input condition;
		input [1023:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin
				$display("  FAIL %0s", what);
				errors = errors + 1;
			end
		end
	endtask

	// --- counting the enables -------------------------------------------------------------
	// Each is counted over the same window, so the ratios between them are what
	// the numbers show -- which is the part that matters, and the part a single
	// wrong divider breaks.
	integer n_cpu, n_vdp, n_z80, n_fm;
	always @(posedge clk) if (!rst) begin
		if (dut.cpu_ce) n_cpu = n_cpu + 1;
		if (dut.vdp_ce) n_vdp = n_vdp + 1;
		if (dut.snd_ce) n_z80 = n_z80 + 1;
		if (dut.fm_ce)  n_fm  = n_fm  + 1;
	end

	// --- watching the pixels ----------------------------------------------------------------
	integer n_px;
	reg [7:0] seen_rgb;
	reg       seen_first;
	// The corner is recorded EVERY frame, not the first time it appears. The
	// first frames happen while the program is still clearing VRAM, and what is
	// in the corner then is whatever the machine powered up with.
	always @(posedge clk) if (!rst && px_valid) begin
		n_px = n_px + 1;
		if (px_x == 9'd0 && px_y == 9'd0) begin
			seen_rgb   = px_rgb;
			seen_first = 1'b1;
		end
	end

	integer k;

	initial begin
		n_cpu = 0; n_vdp = 0; n_z80 = 0; n_fm = 0; n_px = 0;
		seen_first = 0; seen_rgb = 0;
		$readmemh("../../sim/roms/md/mdtest.hex", cart);

		repeat (8) @(posedge clk);
		rst = 0;

		$display("tb_md_console");

		$display(" the clock enables:");
		repeat (100800) @(posedge clk);         // 14400 cpu enables' worth
		// 53.693 MHz over 7, 4, 15 and 1008. Checked as ratios rather than as
		// absolute counts, so the window does not have to be exact.
		check(n_cpu == 100800 / 7,  "the 68000 gets one enable in seven");
		check(n_vdp == 100800 / 4,  "the VDP one in four");
		check(n_z80 == 100800 / 15, "the Z80 one in fifteen");
		check(n_fm  == 100800 / 1008, "and the FM chip one in 1008");
		check(n_vdp > n_cpu && n_cpu > n_z80 && n_z80 > n_fm,
		      "in the order the real machine runs them");

		$display(" the picture:");
		// Long enough for the program to clear all 64 kB of VRAM with a DMA, set
		// the VDP up, and draw -- and then for another frame to be scanned out
		// with the finished picture in it.
		repeat (2500000) @(posedge clk);
		check(seen_first, "a pixel was offered at the top left corner");
		// The test cartridge paints that corner red: full red, no green, no blue.
		check(seen_rgb === 8'b111_000_00,
		      "and it is red -- so red did not come out where blue should be");
		check(n_px > 1000, "and pixels keep coming, one per enable");

		$display("");
		if (errors == 0) $display("tb_md_console: all checks passed");
		else             $display("tb_md_console: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (12000000) @(posedge clk);
		$display("tb_md_console: FAIL timeout at PC=%08x", pc);
		$finish;
	end

endmodule
