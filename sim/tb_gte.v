//////////////////////////////////////////////////////////////////////////////////
// tb_gte - the GTE against its model.
//
// tools/ps1/gtetest.py runs random register states and commands through the Python
// model and writes sim/roms/gte_vectors.hex: 129 words a case -- 32 data and 32
// control registers to load, the command, then what every register reads back
// afterwards. This loads the same state into the RTL, runs the same command,
// and compares all 64 registers. A mismatch names the case, the register and
// both values, and the run stops at the first, because one wrong flag bit is a
// GTE that will draw something subtly wrong forever.
//
//   python tools/ps1/gtetest.py 2000 > sim/roms/gte_vectors.hex
//   ./tools/sim.sh tb_gte
//
// AND against a real machine. sim/roms/gte_hw_vectors.hex is 1100 cases read
// off hardware (JaCzekanski's ps1-tests, gte-fuzz), converted by
// tools/ps1/gtehw.py. The model is only as right as the documentation it was
// written from -- these caught three things the model and the RTL had agreed
// on and both had wrong: the read-back widths, a projection that must saturate
// rather than wrap, and IR saturating off the 32-bit MAC register instead of
// the wider accumulator. To run them, copy that file over gte_vectors.hex and
// set NCASES to 1100. What still differs is the colour and lighting commands;
// nothing in the transform path.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_gte;
	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	reg         we = 0, ctl = 0, cmd = 0;
	reg  [4:0]  reg_i = 0;
	reg  [31:0] wdata = 0;
	reg  [24:0] word = 0;
	wire [31:0] rdata;
	wire        busy;

	ps1_gte dut (
		.gte_old(4'd0),
		.clk(clk), .rst(rst),
		.we(we), .ctl(ctl), .reg_i(reg_i), .wreg_i(reg_i), .wctl(ctl), .wdata(wdata), .rdata(rdata),
		.cmd(cmd), .word(word), .busy(busy),
		.snap_arm(1'b0), .snap_go(1'b0), .snap_skip(16'd0), .snap_idx(7'd0), .snap_data(), .snap_word(), .snap_state()
	);

	localparam NCASES = 2000;
	localparam CW = 129;
	reg [31:0] vec [0:NCASES*CW-1];
	integer dmiss [0:31];
	reg shown10 = 0;
	integer ir1_by_op [0:63];
	integer sxy_by_op [0:63];
	integer cmiss [0:31];

	integer n, i, base, errors, ops_by_kind [0:63], t;
	reg [31:0] got, want;

	task load_reg; input c; input [4:0] r; input [31:0] v; begin
		@(negedge clk); we = 1; ctl = c; reg_i = r; wdata = v;
		@(negedge clk); we = 0;
	end endtask

	initial begin
		for (i = 0; i < 64; i = i + 1) ops_by_kind[i] = 0;
		for (i = 0; i < 32; i = i + 1) begin dmiss[i] = 0; cmiss[i] = 0; end
		for (i = 0; i < 64; i = i + 1) begin ir1_by_op[i] = 0; sxy_by_op[i] = 0; end
		$readmemh("../../sim/roms/gte_vectors.hex", vec);
		errors = 0;

		for (n = 0; n < NCASES; n = n + 1) begin
			base = n * CW;
			// a fresh GTE each case, exactly as the model makes a fresh one
			@(negedge clk); rst = 1; @(negedge clk); rst = 0; @(negedge clk);

			// Every data register in index order, exactly as the machine was
			// written, so its write side effects happen here too: writing SXYP
			// pushes the screen FIFO, writing IRGB sets IR1..IR3, writing LZCS
			// works out LZCR. Skipping those (this bench used to) left our
			// starting state different from the machine's and made every
			// comparison after it meaningless.
			for (i = 0; i < 32; i = i + 1)
				if (i != 29 && i != 31)
					load_reg(1'b0, i[4:0], vec[base + i]);
			for (i = 0; i < 32; i = i + 1)
				load_reg(1'b1, i[4:0], vec[base + 32 + i]);

			// the command: one-cycle strobe, then wait for the engine to finish
			@(negedge clk); cmd = 1; word = vec[base + 64][24:0];
			@(negedge clk); cmd = 0;
			t = 0;
			while (busy && t < 200) begin @(negedge clk); t = t + 1; end
			if (busy) begin
				$display("  case %0d: command %02h never finished", n, vec[base+64][5:0]);
				errors = errors + 1;
			end
			@(negedge clk);
			ops_by_kind[vec[base + 64][5:0]] = ops_by_kind[vec[base + 64][5:0]] + 1;

			// compare every register the model reads back
			for (i = 0; i < 32; i = i + 1) begin
				ctl = 0; reg_i = i[4:0]; #1;
				got = rdata; want = vec[base + 65 + i];
				if (got !== want) begin
					dmiss[i] = dmiss[i] + 1;
					if (i == 9)  ir1_by_op[vec[base+64][5:0]] = ir1_by_op[vec[base+64][5:0]] + 1;
					if (i == 9 && vec[base+64][5:0] == 6'h10 && !shown10) begin
						shown10 = 1;
						$display("  DPCS case %0d  sf=%0d lm=%0d", n, vec[base+64][19], vec[base+64][10]);
						$display("    in:  RGBC=%08h IR0=%08h  FC=%08h %08h %08h",
						         vec[base+6], vec[base+8], vec[base+32+21], vec[base+32+22], vec[base+32+23]);
						$display("    IR1  rtl=%08h hw=%08h", got, want);
						$display("    MAC1 rtl=%08h hw=%08h", 32'd0, vec[base+65+25]);
					end
					if (i == 14) sxy_by_op[vec[base+64][5:0]] = sxy_by_op[vec[base+64][5:0]] + 1;
					if (i == 14 && dmiss[14] <= 6)
						$display("  SXY2 differs: case %0d op %02h sf=%0d lm=%0d  rtl=%08h hw=%08h",
						         n, vec[base+64][5:0], vec[base+64][19], vec[base+64][10], got, want);
					if (i == 9 && dmiss[9] <= 4)
						$display("  IR1 differs:  case %0d op %02h sf=%0d lm=%0d  rtl=%08h hw=%08h",
						         n, vec[base+64][5:0], vec[base+64][19], vec[base+64][10], got, want);
					errors = errors + 1;
				end
			end
			for (i = 0; i < 32; i = i + 1) begin
				ctl = 1; reg_i = i[4:0]; #1;
				got = rdata; want = vec[base + 97 + i];
				if (got !== want) begin
					cmiss[i] = cmiss[i] + 1;
					if (cmiss[i] == 1) $display("  first ctrl r%0d: case %0d op %02h  rtl=%08h hw=%08h", i, n, vec[base+64][5:0], got, want);
					errors = errors + 1;
				end
			end

		end

		for (i = 0; i < 32; i = i + 1) if (dmiss[i] != 0) $display("   data r%0d differed in %0d of %0d cases", i, dmiss[i], NCASES);
		for (i = 0; i < 32; i = i + 1) if (cmiss[i] != 0) $display("   ctrl r%0d differed in %0d of %0d cases", i, cmiss[i], NCASES);
		$display("   IR1 differences by op:");
		for (i = 0; i < 64; i = i + 1) if (ir1_by_op[i]) $display("      op %02h: %0d of %0d run", i, ir1_by_op[i], ops_by_kind[i]);
		$display("   screen coordinate differences by op:");
		for (i = 0; i < 64; i = i + 1) if (sxy_by_op[i]) $display("      op %02h: %0d of %0d run", i, sxy_by_op[i], ops_by_kind[i]);
		$display("  ops exercised:");
		for (i = 0; i < 64; i = i + 1)
			if (ops_by_kind[i]) $display("    %02h x%0d", i, ops_by_kind[i]);
		if (errors == 0) $display("tb_gte: all %0d cases match the model -- %0d registers checked",
		                          NCASES, NCASES * 64);
		else             $display("tb_gte: %0d MISMATCH(es)", errors);
		$finish;
	end
endmodule

`default_nettype wire
