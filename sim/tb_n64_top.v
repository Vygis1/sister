//////////////////////////////////////////////////////////////////////////////////
// tb_n64_top - the N64 as the board will run it: the cartridge filled through the
// host's port into DDR3, the run bit raised, our boot ROM copying the game into
// RDRAM and jumping to it, the program running to its end. Then the screen.
//
//   python tools/n64sim.py ROM.N64 --system        (writes sim/n64/cart.hex)
//   ./tools/sim.sh tb_n64_top
//   python tools/n64sim.py --system-check          (the screen against the model's)
//
// DDR3 is a model with latency and back-pressure. The VI runs at the board's
// rate (1587 clocks a half-line): with no caches yet a frame is only ~67k
// instructions, and a shorter one ended tests before they had finished.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_top;
	reg clk = 0, rst = 1, run = 0;
	always #10 clk = ~clk;

	reg  [21:0]  host_windex = 0; reg host_we = 0; reg [31:0] host_wdata = 0; reg fill_end = 0;
	reg          hr_go = 0; reg [23:0] hr_line = 0;
	wire         hr_done; wire [127:0] hr_data;
	wire [23:0]  d_addr; wire d_req, d_we; wire [127:0] d_wdata; wire [15:0] d_wmask;
	reg          d_ready = 0, d_valid = 0; reg [127:0] d_rdata = 0;
	wire [31:0]  vi_status, vi_origin, vi_width, vi_yscale, dbg_pc, dbg_retired;

	n64_top #(.HALFLINE(11'd1587)) dut (
		.clk(clk), .rst(rst), .run(run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata), .fill_end(fill_end),
		.hr_go(hr_go), .hr_line(hr_line), .hr_done(hr_done), .hr_data(hr_data),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid), .d_calibrated(1'b1),
		.joy1(16'd0), .vi_status(vi_status), .vi_origin(vi_origin), .vi_width(vi_width), .vi_yscale(vi_yscale),
		.dbg_pc(dbg_pc), .dbg_retired(dbg_retired)
	);

	// --- DDR3: RDRAM (8 MB) at line 0, the cartridge (16 MB) at line 0x100000 -----------
	reg [127:0] rdram [0:524287];
	reg [127:0] cart  [0:1048575];
	integer i;
	initial begin
		for (i = 0; i < 524288; i = i + 1) rdram[i] = 128'd0;
		for (i = 0; i < 1048576; i = i + 1) cart[i] = 128'd0;
	end
	reg [31:0] rnd = 32'hC0FF_EE11;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
	localparam LAT = 12;
	reg [23:0] q_a [0:LAT-1]; reg q_v [0:LAT-1];
	initial for (i = 0; i < LAT; i = i + 1) begin q_v[i] = 0; q_a[i] = 0; end
	integer mk, rdram_writes = 0;
	always @(posedge clk) begin
		d_ready <= (rnd[1:0] != 2'b00);
		d_valid <= q_v[LAT-1];
		d_rdata <= (q_a[LAT-1] >= 24'h10_0000) ? cart[q_a[LAT-1] - 24'h10_0000] : rdram[q_a[LAT-1][18:0]];
		for (mk = LAT-1; mk > 0; mk = mk - 1) begin q_v[mk] <= q_v[mk-1]; q_a[mk] <= q_a[mk-1]; end
		q_v[0] <= 1'b0;
		if (d_req && d_ready) begin
			if (d_we) begin
				for (mk = 0; mk < 16; mk = mk + 1) if (d_wmask[mk]) begin
					if (d_addr >= 24'h10_0000) cart[d_addr - 24'h10_0000][8 * mk +: 8] <= d_wdata[8 * mk +: 8];
					else rdram[d_addr[18:0]][8 * mk +: 8] <= d_wdata[8 * mk +: 8];
				end
				if (d_addr < 24'h10_0000) rdram_writes = rdram_writes + 1;
			end else begin
				q_v[0] <= 1'b1; q_a[0] <= d_addr;
			end
		end
	end

	// --- the run --------------------------------------------------------------------------
	reg [31:0] words [0:524287];          // the cartridge, as the PC sends it: little-endian 32-bit words
	integer nwords, frames = 0, last_frame = 0, last_wr = 0, quiet = 0;
	reg [9:0] prev_line = 0;
	always @(posedge clk) begin
		prev_line <= dut.vi_line;
		if (dut.vi_line == 10'd0 && prev_line != 10'd0) frames = frames + 1;
	end
	// the retire trace, in tools/n64sim.py's format, for comparison with the model
	integer f, tf;
	initial tf = $fopen("../../sim/n64/sys.trace", "w");
	always @(posedge clk) begin
		if (dut.tr_exc) $fwrite(tf, "X %02x\n", dut.tr_code);
		if (dut.tr_valid) begin
			if (dut.tr_we) $fwrite(tf, "%08x %02d %016x\n", dut.tr_pc, dut.tr_rd, dut.tr_val);
			else           $fwrite(tf, "%08x\n", dut.tr_pc);
		end
	end
	initial begin
		for (i = 0; i < 524288; i = i + 1) words[i] = 32'hxxxx_xxxx;
		$readmemh("../../sim/n64/cart.hex", words);
		nwords = 0; while (nwords < 524288 && words[nwords] !== 32'hxxxx_xxxx) nwords = nwords + 1;
		$display("tb_n64_top: cartridge %0d words", nwords);
		repeat (5) @(posedge clk); rst = 0;
		// the host's fill: a word a clock is faster than the network, which is fine
		for (i = 0; i < nwords; i = i + 1) begin
			@(negedge clk); host_we = 1; host_windex = i; host_wdata = words[i];
			@(negedge clk); host_we = 0;
			repeat (3) @(negedge clk);       // leave the port time to write each line
		end
		@(negedge clk); fill_end = 1; @(negedge clk); fill_end = 0;
		repeat (200) @(negedge clk);
		$display("tb_n64_top: filled; run at %0t", $time);
		run = 1;
		// the end: two frames with no RDRAM write after the boot's copy is done
		while (quiet < 2 || dbg_retired < 1000) begin
			@(posedge clk);
			if (frames != last_frame) begin
				quiet = (rdram_writes == last_wr) ? quiet + 1 : 0;
				last_frame = frames; last_wr = rdram_writes;
				if (frames % 10 == 0) $display("  frame %0d: %0d retired, pc %08x", frames, dbg_retired, dbg_pc);
			end
		end
		$display("tb_n64_top: done after %0d instructions, VI origin %08x width %0d status %08x", dbg_retired, vi_origin, vi_width, vi_status);
		f = $fopen("../../sim/n64/sys_rdram.hex", "w");
		for (i = 0; i < 524288; i = i + 1) $fwrite(f, "%032x\n", rdram[i]);
		$fclose(f);
		$finish;
	end
	initial begin
		#(64'd20_000_000_000);
		$display("tb_n64_top: TIMED OUT, %0d retired, pc %08x", dbg_retired, dbg_pc);
		$finish;
	end
endmodule

`default_nettype wire
