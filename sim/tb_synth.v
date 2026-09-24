`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_synth - does the oscillator bank actually produce the waveform it claims?
//
// DIV is overridden to 16 so a sample takes 16 clocks instead of 1024. The
// arithmetic is identical; only the wall-clock time to simulate changes.
//
// The phase increment is chosen as 2^32/64, which makes the period exactly 64
// samples whatever the sample rate is. That turns "is the frequency right" into
// counting edges, with no floating point and no tolerance fudging.
//////////////////////////////////////////////////////////////////////////////////

module tb_synth;

	localparam DIV        = 16;
	localparam BUF_AW     = 14;      // must track synth.v
	localparam PERIOD     = 64;                 // samples per cycle
	localparam PHASE_INC  = 32'h0400_0000;      // 2^32 / 64

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	reg  [15:0] off;
	reg         we;
	reg  [31:0] wdata;
	wire [31:0] rdata;
	wire        err;
	reg  [BUF_AW-1:0] buf_addr;
	wire [31:0] buf_rdata;

	synth #(.DIV(DIV), .BUF_AW(BUF_AW)) dut (
		.clk(clk), .rst(rst),
		.off(off), .we(we), .wdata(wdata), .rdata(rdata), .err(err),
		.buf_addr(buf_addr), .buf_rdata(buf_rdata)
	);

	task wr;
		input [15:0] a;
		input [31:0] d;
		begin
			@(posedge clk); #1;
			off = a; wdata = d; we = 1;
			@(posedge clk); #1;
			we = 0;
		end
	endtask

	task rd;
		input [15:0] a;
		begin
			@(posedge clk); #1;
			off = a; we = 0;
			#1;
		end
	endtask

	integer k, transitions, nsamp;
	reg [15:0] s, prev_s;
	reg first_env_small;
	reg [31:0] w0, wN;

	initial begin
		we = 0; off = 0; wdata = 0; buf_addr = 0;
		repeat (5) @(posedge clk);
		rst = 0;
		repeat (5) @(posedge clk);

		$display("tb_synth");

		rd(16'h0000);
		check(rdata == 32'h5359_0001, "synth identifies itself");
		rd(16'h000C);
		check(rdata == 50_000_000 / DIV, "reports its sample rate");

		// Silence until enabled: the ring buffer should fill with mid-scale.
		rd(16'h0020); w0 = rdata;
		repeat (DIV * 40) @(posedge clk);
		rd(16'h0020); wN = rdata;
		check(wN > w0, "ring buffer advances even while disabled");
		buf_addr = w0[BUF_AW-1:0] + 2; @(posedge clk); @(posedge clk); #1;
		check(buf_rdata == 32'h8000_8000, "disabled output is exactly mid-scale silence");

		// A square wave at a period of exactly 64 samples.
		wr(16'h0008, 32'h0000_FFFF);          // master volume
		wr(16'h0010, 32'h0000_FFFF);          // instant attack, so the test is not
		wr(16'h0014, 32'h0000_FFFF);          // measuring the envelope ramp
		wr(16'h0040, PHASE_INC);              // voice 0 frequency
		wr(16'h0060, {16'hFFFF, 12'd0, 3'd0, 1'b1});   // gate on, wave 0 = square
		wr(16'h0004, 32'h0000_0001);          // enable

		rd(16'h0040);
		check(rdata == PHASE_INC, "phase increment reads back");
		rd(16'h0060);
		check(rdata[0] == 1'b1 && rdata[3:1] == 3'd0, "voice control reads back");

		// Every voice must be reachable, not just voice 0 -- the address decode
		// spans 32 bytes and it is easy to cover only the first 16.
		begin : all_voices
			integer v, bad;
			bad = 0;
			for (v = 0; v < 8; v = v + 1) begin
				wr(16'h0040 + v[15:0]*4, 32'h1000_0000 + v);
				wr(16'h0060 + v[15:0]*4, {16'h4000, 12'd0, 3'd1, 1'b1});
			end
			for (v = 0; v < 8; v = v + 1) begin
				rd(16'h0040 + v[15:0]*4);
				if (rdata !== 32'h1000_0000 + v) bad = bad + 1;
				rd(16'h0060 + v[15:0]*4);
				if (rdata[0] !== 1'b1 || rdata[3:1] !== 3'd1) bad = bad + 1;
			end
			check(bad == 0, "all eight voices are addressable");
			for (v = 1; v < 8; v = v + 1) wr(16'h0060 + v[15:0]*4, 32'd0);
			wr(16'h0040, PHASE_INC);
			wr(16'h0060, {16'hFFFF, 12'd0, 3'd0, 1'b1});
		end

		// Let it settle, then capture a known number of samples.
		repeat (DIV * 200) @(posedge clk);
		rd(16'h0020); w0 = rdata;
		repeat (DIV * 2 * 512) @(posedge clk);     // 512 words = 1024 samples
		rd(16'h0020); wN = rdata;
		check(wN - w0 >= 32'd500, "produced roughly the expected number of words");

		// Count transitions across 1024 samples. A 64-sample period gives 16
		// cycles, so 32 edges.
		transitions = 0;
		nsamp = 0;
		prev_s = 16'h8000;
		for (k = 0; k < 512; k = k + 1) begin
			buf_addr = w0[BUF_AW-1:0] + k[BUF_AW-1:0];
			@(posedge clk); @(posedge clk); #1;
			s = buf_rdata[15:0];
			if (nsamp > 0 && ((s > 16'h8000) != (prev_s > 16'h8000))) transitions = transitions + 1;
			prev_s = s; nsamp = nsamp + 1;
			s = buf_rdata[31:16];
			if ((s > 16'h8000) != (prev_s > 16'h8000)) transitions = transitions + 1;
			prev_s = s; nsamp = nsamp + 1;
		end
		$display("       %0d samples, %0d transitions (expect ~%0d)",
		         nsamp, transitions, (2 * nsamp) / PERIOD);
		check(transitions >= ((2 * nsamp) / PERIOD) - 2 &&
		      transitions <= ((2 * nsamp) / PERIOD) + 2,
		      "square wave frequency matches the phase increment");

		// Gate off: the envelope must fall to silence rather than cut abruptly.
		wr(16'h0014, 32'h0000_0100);          // slower release
		wr(16'h0060, {16'hFFFF, 12'd0, 3'd0, 1'b0});
		repeat (DIV * 2000) @(posedge clk);
		rd(16'h0020); w0 = rdata;
		repeat (DIV * 40) @(posedge clk);
		buf_addr = w0[BUF_AW-1:0] + 2; @(posedge clk); @(posedge clk); #1;
		check(buf_rdata == 32'h8000_8000, "returns to silence after release");

		$display("");
		if (errors == 0) $display("tb_synth: all checks passed");
		else             $display("tb_synth: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		#50_000_000;
		$display("FAIL timeout");
		$finish;
	end

endmodule
