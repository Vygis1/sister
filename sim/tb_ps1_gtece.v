//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_gtece - a GTE command must happen ONCE, whatever the processor's clock
// enable does.
//
// `c2_cmd` used to be cleared inside the processor's `if (ce)` block with
// everything else. Lose the enable on the clock after issuing a command -- a
// cache miss, a DMA owning the bus -- and the line stayed high; the GTE starts
// on `cmd && !run`, so the moment it finished it ran the same command again,
// and again, for as long as the enable stayed low.
//
// For RTPS that is fatal in a way no arithmetic test can see: each run pushes
// another entry through the screen-coordinate FIFO, so a game that projects
// three vertices and reads SXY0/1/2 gets one corner carrying another vertex's
// position. On the board that drew a crate leaning, with its left corner pulled
// towards the camera, on about half the frames -- at random, because whether
// the enable happens to drop there depends on memory.
//
// This drives the GTE the way the processor does and counts how many times a
// command actually runs, with the enable held low for a while afterwards.
//
//   ./tools/sim.sh tb_ps1_gtece
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_ps1_gtece;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg         we = 0, ctl = 0, cmd = 0;
	reg  [4:0]  reg_i = 0;
	reg  [31:0] wdata = 0;
	reg  [24:0] word = 0;
	wire [31:0] rdata;
	wire        busy;

	ps1_gte dut (.gte_old(4'd0), .clk(clk), .rst(rst),
		.we(we), .ctl(ctl), .reg_i(reg_i), .wdata(wdata), .rdata(rdata),
		.cmd(cmd), .word(word), .busy(busy));

	// how many times the sequencer actually started a command
	integer runs = 0;
	reg run_d = 0;
	always @(posedge clk) begin
		run_d <= dut.run;
		if (dut.run && !run_d) runs = runs + 1;
	end

	integer errors = 0;
	task check; input c; input [1023:0] what; begin
		if (c) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end
	end endtask

	task wr; input ictl; input [4:0] r; input [31:0] v; begin
		@(negedge clk); we = 1; ctl = ictl; reg_i = r; wdata = v;
		@(negedge clk); we = 0;
		while (busy) @(negedge clk);
	end endtask

	// issue a command the way the processor does, then hold the line for `hold`
	// clocks -- which is what losing the clock enable used to do
	task issue; input [24:0] w; input integer hold; integer k; begin
		@(negedge clk); cmd = 1; word = w;
		for (k = 0; k < hold; k = k + 1) @(negedge clk);
		cmd = 0;
		@(negedge clk);
		while (busy) @(negedge clk);
	end endtask

	integer r0;
	reg [31:0] sxy0, sxy1, sxy2;
	initial begin
		repeat (4) @(posedge clk); rst = 0; repeat (2) @(posedge clk);

		// a sane projection: identity rotation, a translation down Z, and H/OF
		wr(1, 5'd0, 32'h0000_1000); wr(1, 5'd1, 32'h0000_0000);   // R11R12, R13R21
		wr(1, 5'd2, 32'h1000_0000); wr(1, 5'd3, 32'h0000_0000);   // R22R23, R31R32
		wr(1, 5'd4, 32'h0000_1000);                               // R33
		wr(1, 5'd5, 32'd0); wr(1, 5'd6, 32'd0); wr(1, 5'd7, 32'd1000);  // TRX TRY TRZ
		wr(1, 5'd24, 32'd0); wr(1, 5'd25, 32'd0);                 // OFX OFY
		wr(1, 5'd26, 32'd300);                                    // H
		wr(0, 5'd0, 32'h0064_0032);                               // VXY0 = (50,100)
		wr(0, 5'd1, 32'd200);                                     // VZ0

		// --- one clock, as it must be ---------------------------------------
		r0 = runs;
		issue(25'h0180001, 1);                                    // RTPS
		$display("  RTPS with the line held 1 clock:  the sequencer ran it %0d time(s)", runs - r0);
		check(runs - r0 == 1, "a command held for one clock runs once");
		sxy2 = dut.d[14];   // SXY2 after one projection

		// --- and held, as losing the clock enable used to do -----------------
		r0 = runs;
		issue(25'h0180001, 40);
		$display("  RTPS with the line held 40 clocks: the sequencer ran it %0d time(s)", runs - r0);
		check(runs - r0 == 1, "a command held while the processor is stalled STILL runs once");

		// --- and the coordinate FIFO has moved exactly one place -------------
		// Three projections of the same vertex must leave all three slots equal.
		// If a held command ran twice, the FIFO shifted twice and the three
		// vertices a game reads back are not the three it projected.
		wr(0, 5'd0, 32'h0064_0032); wr(0, 5'd1, 32'd200);
		issue(25'h0180001, 1);
		wr(0, 5'd0, 32'h00C8_0064); wr(0, 5'd1, 32'd200);
		issue(25'h0180001, 25);                                   // the stalled one
		wr(0, 5'd0, 32'h012C_0096); wr(0, 5'd1, 32'd200);
		issue(25'h0180001, 1);
		sxy0 = dut.d[12]; sxy1 = dut.d[13]; sxy2 = dut.d[14];
		$display("  three projections -> SXY0=%08x SXY1=%08x SXY2=%08x", sxy0, sxy1, sxy2);
		check(sxy0 != sxy1 && sxy1 != sxy2,
		      "three different vertices leave three different screen coordinates");

		// --- back-to-back register writes must BOTH land ---------------------
		// The processor asserts `we` on two consecutive clocks when a game loads
		// a matrix with back-to-back MTC2/CTC2. Edge-detecting that line drops
		// the second of every pair; on the board that came out as objects
		// warping across the whole screen and the character vanishing.
		@(negedge clk); we = 1; ctl = 0; reg_i = 5'd9;  wdata = 32'h0000_1111;   // IR1
		@(negedge clk);        ctl = 0; reg_i = 5'd10; wdata = 32'h0000_2222;   // IR2
		@(negedge clk); we = 0;
		while (busy) @(negedge clk);
		$display("  two writes on consecutive clocks -> IR1=%04x IR2=%04x",
		         dut.d[9][15:0], dut.d[10][15:0]);
		check(dut.d[9][15:0] == 16'h1111 && dut.d[10][15:0] == 16'h2222,
		      "two register writes on consecutive clocks both land");

		if (errors == 0) $display("tb_ps1_gtece: all checks passed");
		else begin $display("tb_ps1_gtece: %0d FAILED", errors); $fatal(1); end
		$finish;
	end

	initial begin
		#2_000_000;
		$display("tb_ps1_gtece: TIMED OUT");
		$fatal(1);
	end
endmodule

`default_nettype wire
