//////////////////////////////////////////////////////////////////////////////////
// tb_vr4300 - the N64 CPU against tools/n64model.py, instruction by instruction.
//
//   python tools/n64sim.py ROM.N64 --steps 200000      (RDRAM image, boot stub, model trace)
//   ./tools/sim.sh tb_vr4300 STEPS200000 [WAITS1]
//   python tools/n64sim.py --compare
//
// RDRAM (8 MB) is preloaded with what the model's boot put there; the boot stub
// sits at the reset address. Both ports answer with a clock of latency, or,
// with WAITS1, after a random number of clocks -- so the pipeline's holds are
// exercised by the same program. Every retired instruction goes to rtl.trace in
// the model's format: its address, and the register and value if it changed
// one; an exception is a line of its own.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_vr4300;
	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	wire        i_req, i_cached, d_req, d_we, d_cached;
	wire [31:0] i_addr, d_addr;
	wire [7:0]  d_be;
	wire [63:0] d_wdata;
	reg         i_ready = 0, d_ready = 0;
	reg  [31:0] i_rdata = 0;
	reg  [63:0] d_rdata = 0;
	wire        tr_valid, tr_we, tr_exc;
	wire [31:0] tr_pc;
	wire [4:0]  tr_rd, tr_code;
	wire [63:0] tr_val;

	vr4300 cpu (
		.clk(clk), .rst(rst),
		.i_req(i_req), .i_addr(i_addr), .i_cached(i_cached), .i_ready(i_ready), .i_rdata(i_rdata),
		.d_req(d_req), .d_we(d_we), .d_addr(d_addr), .d_cached(d_cached), .d_be(d_be), .d_wdata(d_wdata),
		.d_ready(d_ready), .d_rdata(d_rdata),
		.irq(5'd0), .count_tick(1'b1),
		.tr_valid(tr_valid), .tr_pc(tr_pc), .tr_we(tr_we), .tr_rd(tr_rd), .tr_val(tr_val),
		.tr_exc(tr_exc), .tr_code(tr_code)
	);

	// --- memory ----------------------------------------------------------------------
	reg [63:0] ram [0:1048575];      // 8 MB, big-endian lanes
	reg [31:0] pif [0:495];
	integer i;
	initial begin
		for (i = 0; i < 1048576; i = i + 1) ram[i] = 64'd0;
		for (i = 0; i < 496; i = i + 1) pif[i] = 32'd0;
		$readmemh("../../sim/n64/rdram.hex", ram);
		$readmemh("../../sim/n64/pifrom.hex", pif);
	end

	function [31:0] fetch32; input [31:0] a;
		if (a < 32'h0080_0000) fetch32 = a[2] ? ram[a[22:3]][31:0] : ram[a[22:3]][63:32];
		else if (a >= 32'h1FC0_0000 && a < 32'h1FC0_07C0) fetch32 = pif[(a - 32'h1FC0_0000) >> 2];
		else fetch32 = 32'd0;
	endfunction
	function [63:0] read64; input [31:0] a;
		if (a < 32'h0080_0000) read64 = ram[a[22:3]];
		else if (a >= 32'h1FC0_0000 && a < 32'h1FC0_07C0) read64 = {pif[(a - 32'h1FC0_0000) >> 2], pif[((a - 32'h1FC0_0000) >> 2) + 1]};
		else read64 = 64'd0;           // registers: zero (the CPU tests only write them)
	endfunction

	integer WAITS = 0;
	initial if (!$value$plusargs("WAITS%d", WAITS)) WAITS = 0;
	reg [31:0] seed = 32'h1234_5678;
	function [2:0] waits; input dummy;
		begin seed = seed * 1103515245 + 12345; waits = (WAITS != 0) ? seed[18:16] & 3'd3 : 3'd0; end
	endfunction

	// instruction port
	reg [31:0] ia; reg [2:0] iw; reg ipend = 0;
	always @(posedge clk) begin
		if (i_req) begin
			ia = i_addr; iw = waits(0);
			if (iw == 0) begin i_ready <= 1'b1; i_rdata <= fetch32(i_addr); ipend <= 1'b0; end
			else begin i_ready <= 1'b0; ipend <= 1'b1; end
		end else if (ipend) begin
			if (iw == 0 || iw == 1) begin i_ready <= 1'b1; i_rdata <= fetch32(ia); ipend <= 1'b0; end
			iw = iw - 1;
		end
	end
	// data port
	reg [31:0] da; reg [2:0] dwt; reg dpend = 0; integer bk;
	always @(posedge clk) begin
		if (d_req) begin
			if (d_we && d_addr < 32'h0080_0000)
				for (bk = 0; bk < 8; bk = bk + 1)
					if (d_be[bk]) ram[d_addr[22:3]][63 - 8 * bk -: 8] <= d_wdata[63 - 8 * bk -: 8];
			da = d_addr; dwt = waits(0);
			if (dwt == 0) begin d_ready <= 1'b1; d_rdata <= read64(d_addr); dpend <= 1'b0; end
			else begin d_ready <= 1'b0; dpend <= 1'b1; end
		end else if (dpend) begin
			if (dwt == 0 || dwt == 1) begin d_ready <= 1'b1; d_rdata <= read64(da); dpend <= 1'b0; end
			dwt = dwt - 1;
		end
	end

	// --- the trace ---------------------------------------------------------------------
	integer f, STEPS = 200000, n = 0;
	initial if (!$value$plusargs("STEPS%d", STEPS)) STEPS = 200000;
	initial f = $fopen("../../sim/n64/rtl.trace", "w");
	always @(posedge clk) begin
		if (tr_exc) begin $fwrite(f, "X %02x\n", tr_code); n = n + 1; end
		if (tr_valid) begin
			if (tr_we) $fwrite(f, "%08x %02d %016x\n", tr_pc, tr_rd, tr_val);
			else       $fwrite(f, "%08x\n", tr_pc);
			n = n + 1;
		end
		if (n >= STEPS) begin
			$fclose(f);
			// RDRAM as the CPU left it: the model's is compared with it, and the
			// framebuffer in it is the test's screen
			f = $fopen("../../sim/n64/rtl_rdram.hex", "w");
			for (i = 0; i < 1048576; i = i + 1) $fwrite(f, "%016x\n", ram[i]);
			$fclose(f);
			$display("tb_vr4300: %0d instructions retired at %0t", n, $time);
			$finish;
		end
	end
	initial begin
		repeat (5) @(posedge clk); rst = 0;
		#(64'd2_000_000_000);
		$display("tb_vr4300: TIMED OUT after %0d instructions", n);
		$fclose(f); $finish;
	end
endmodule

`default_nettype wire
