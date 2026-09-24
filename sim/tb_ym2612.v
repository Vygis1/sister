`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_ym2612 - the FM chip's front door and its timers.
//
// No sound is checked here, because there is not any yet. What is checked is
// everything a sound driver does BEFORE it makes a sound, and every one of these
// is a place where a register can land somewhere plausible and wrong:
//
//   - a write is two accesses, an address then a value, and the two ports have
//     separate latches because a driver interleaves them
//   - the second port's three channels are 4, 5 and 6, and a chip that files
//     them as 4, 5 and 6 rather than as the fourth, fifth and sixth writes past
//     the end of itself
//   - operators appear in the register map in the order 1, 3, 2, 4
//   - a channel field of 3 addresses nothing, and must not be treated as a
//     fourth channel
//   - the timers count UP to an overflow, so the value written is the period
//     subtracted from the top
//////////////////////////////////////////////////////////////////////////////////

module tb_ym2612;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One FM sample every 128 clocks. Twenty-four operators at four clocks each
	// is 96, so this is the smallest round number that lets a pass finish -- and
	// a pass that does not finish produces silence rather than an error.
	localparam SAMP = 128;
	reg [6:0] div = 0;
	always @(posedge clk) div <= div + 7'd1;
	wire ce = (div == 7'd127);

	reg        cs = 0, wr = 0;
	reg  [1:0] a  = 0;
	reg  [7:0] din = 0;
	wire [7:0] dout;
	wire signed [15:0] left, right;
	wire       ta_flag, tb_flag;
	wire [5:0] keyon;

	ym2612 dut (
		.clk(clk), .rst(rst), .ce(ce),
		.cs(cs), .a(a), .wr(wr), .din(din), .dout(dout),
		.left(left), .right(right),
		.dbg_timer_a(ta_flag), .dbg_timer_b(tb_flag), .dbg_keyon(keyon)
	);

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

	// A register write: the number, then the value, through one of the two ports.
	task ywr;
		input       part;
		input [7:0] rnum;
		input [7:0] val;
		begin
			@(negedge clk); cs = 1; wr = 1; a = {part, 1'b0}; din = rnum;
			@(negedge clk); cs = 0; wr = 0;
			@(negedge clk); cs = 1; wr = 1; a = {part, 1'b1}; din = val;
			@(negedge clk); cs = 0; wr = 0;
			@(negedge clk);
		end
	endtask

	integer k;

	// Run for a while and report what came out: how loud it got, and how often it
	// changed sign. Those two between them say "an oscillator of about this
	// frequency and this amplitude" without needing to know the waveform.
	reg signed [15:0] peak;
	integer crossings;
	reg last_sign;

	// `n` is a count of SAMPLES, not of clocks. Counting clocks here and calling
	// them samples is how a window that looks generous turns out to be three
	// cycles long, and every measurement taken through it turns out low.
	task collect;
		input integer n;
		integer got;
		begin
			peak      = 16'sd0;
			crossings = 0;
			last_sign = 1'b0;
			got       = 0;
			while (got < n) begin
				@(posedge clk);
				if (ce) begin
					// The new sample is handed over on this edge; read it once it
					// has settled.
					@(negedge clk);
					if (left > peak)  peak = left;
					if (-left > peak) peak = -left;
					if ((left < 0) != last_sign) begin
						crossings = crossings + 1;
						last_sign = (left < 0);
					end
					got = got + 1;
				end
			end
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		$display("tb_ym2612");

		$display(" the register ports:");
		ywr(0, 8'h30, 8'h35);           // channel 1, operator 1: detune 3, mul 5
		check(dut.op_mul[0] === 4'h5 && dut.op_dt[0] === 3'h3,
		      "a two-access write lands in the operator it names");

		// The same register number through the other port is a different channel
		// entirely -- the fourth, not the first.
		ywr(1, 8'h30, 8'h42);
		check(dut.op_mul[12] === 4'h2 && dut.op_dt[12] === 3'h4,
		      "the second port's first channel is the fourth, not the seventh");
		check(dut.op_mul[0] === 4'h5, "and it left the first channel alone");

		// Register $34 is operator 3 of channel 1 by the manual's numbering, but
		// it is the SECOND operator slot in the map. A chip that takes the slot
		// number at face value files it as operator 2.
		ywr(0, 8'h34, 8'h07);
		check(dut.op_mul[2] === 4'h7,
		      "register $34 is operator 3, not operator 2");
		check(dut.op_mul[1] === 4'h0, "so operator 2 is untouched");

		// A channel field of 3 is not a channel.
		ywr(0, 8'h33, 8'h0F);
		check(dut.op_mul[3] === 4'h0 && dut.op_mul[0] === 4'h5,
		      "a channel field of 3 writes nothing at all");

		$display(" the channel registers:");
		ywr(0, 8'hA4, 8'h1A);           // block 3, fnum high 2
		ywr(0, 8'hA0, 8'h55);           // fnum low
		check(dut.ch_fnum[0] === 11'h255 && dut.ch_block[0] === 3'd3,
		      "the frequency arrives in two halves, high one first");
		ywr(1, 8'hB0, 8'h1D);
		check(dut.ch_alg[3] === 3'd5 && dut.ch_fb[3] === 3'd3,
		      "algorithm and feedback, on the second port's first channel");

		$display(" key on:");
		ywr(0, 8'h28, 8'hF0);           // all four operators of channel 1
		check(dut.ch_keyon[0] === 4'hF, "channel 1 keyed on");
		ywr(0, 8'h28, 8'hF4);           // channel 4 -- bit 2 selects the part
		check(dut.ch_keyon[3] === 4'hF,
		      "and channel 4, which the key-on register names by number");
		check(keyon === 6'b001001, "two channels sounding, and only those two");
		ywr(0, 8'h28, 8'h00);
		check(dut.ch_keyon[0] === 4'h0, "and off again");

		$display(" the timers:");
		// 1020 counts up to 1023, so it overflows after four samples.
		ywr(0, 8'h24, 8'hFF);           // the top eight bits
		ywr(0, 8'h25, 8'h00);           // and the bottom two: 1020
		ywr(0, 8'h27, 8'h05);           // load and enable timer A
		check(ta_flag === 1'b0, "nothing has overflowed yet");
		repeat (3 * SAMP) @(posedge clk);
		check(ta_flag === 1'b0, "still not, three samples in");
		repeat (2 * SAMP) @(posedge clk);
		check(ta_flag === 1'b1, "and it fires on the fourth");

		// Writing the reset bit clears the flag; the bit does not stay set.
		ywr(0, 8'h27, 8'h15);
		check(ta_flag === 1'b0, "the reset bit clears it");
		check(dut.ta_run === 1'b1, "without stopping the timer");

		// With the interrupt disabled the timer still runs, it just says nothing.
		ywr(0, 8'h27, 8'h11);
		repeat (16 * SAMP) @(posedge clk);
		check(ta_flag === 1'b0, "a timer with its flag disabled stays quiet");

		// Timer B runs at a sixteenth of the rate, so the same period takes
		// sixteen times as long.
		ywr(0, 8'h26, 8'hFE);           // 254: two ticks of timer B
		ywr(0, 8'h27, 8'h0A);           // load and enable timer B alone
		repeat (30 * SAMP) @(posedge clk);
		check(tb_flag === 1'b0, "timer B has not fired after thirty samples");
		repeat (10 * SAMP) @(posedge clk);
		check(tb_flag === 1'b1, "but has by forty, which is sixteen times slower");

		$display(" the DAC:");
		ywr(0, 8'h2B, 8'h80);           // channel 6 becomes a DAC
		ywr(0, 8'h2A, 8'hFF);
		check(left > 16'sd8000, "a full-scale sample comes out loud");
		ywr(0, 8'h2A, 8'h00);
		check(left < -16'sd8000, "and the other extreme the other way");
		ywr(0, 8'h2A, 8'h80);
		check(left === 16'sd0, "with silence in the middle");
		ywr(0, 8'h2B, 8'h00);
		check(left === 16'sd0, "and nothing at all once it is switched off");

		// ==================================================================
		// The operators.
		//
		// Not a check that it sounds right -- that needs a recording from real
		// hardware to compare against, and a powered board to make one. What can
		// be checked without one is that it oscillates at the frequency it was
		// asked for, that the envelope goes up and comes back down, and that a
		// key-off leaves silence rather than a held note.
		// ==================================================================
		$display(" the operators:");
		ywr(0, 8'h2B, 8'h00);           // the DAC out of the way

		// Algorithm 7 is the one with no modulation at all: four operators
		// straight to the output. With three of them silent, what comes out is
		// one sine and nothing else.
		ywr(0, 8'hB0, 8'h07);
		ywr(0, 8'h30, 8'h01);           // operator 1: multiple 1, no detune
		ywr(0, 8'h40, 8'h00);           //   at full volume
		ywr(0, 8'h50, 8'h1F);           //   attack as fast as it goes
		ywr(0, 8'h60, 8'h00);           //   and no decay at all
		ywr(0, 8'h70, 8'h00);
		ywr(0, 8'h80, 8'h0F);           //   release quickly when it ends
		for (k = 1; k < 4; k = k + 1) begin
			ywr(0, 8'h40 + k[7:0] * 8'd4, 8'h7F);   // the other three silent
			ywr(0, 8'h50 + k[7:0] * 8'd4, 8'h1F);
			ywr(0, 8'h80 + k[7:0] * 8'd4, 8'h0F);
		end
		// Block 7 and a high frequency number, so a cycle takes about sixteen
		// samples and a short run holds plenty of them.
		ywr(0, 8'hA4, 8'h3B);           // block 7, fnum high 3
		ywr(0, 8'hA0, 8'hE8);           // fnum = $3E8 = 1000

		ywr(0, 8'h28, 8'hF0);           // key on, all four operators
		collect(600);
		check(peak > 16'sd500, "keyed on, it makes a sound");
		check(crossings > 20 && crossings < 80,
		      "which crosses zero at about the rate the frequency asks for");

		// A silent operator contributes nothing, so all four keyed on at full
		// volume must be louder than one.
		ywr(0, 8'h44, 8'h00);           // operator 2 up to full volume too
		collect(600);
		check(peak > 16'sd900, "a second operator at full volume is louder");
		ywr(0, 8'h44, 8'h7F);

		// Key off, and the release takes it down to nothing.
		ywr(0, 8'h28, 8'h00);
		collect(600);
		collect(200);
		check(peak < 16'sd80, "keyed off, it falls silent");

		// And an operator whose total level is at the bottom makes no sound even
		// while it is keyed on, which is how a driver mutes a channel.
		ywr(0, 8'h40, 8'h7F);
		ywr(0, 8'h28, 8'hF0);
		collect(200);
		check(peak < 16'sd80, "a muted operator stays quiet even when struck");

		$display("");
		if (errors == 0) $display("tb_ym2612: all checks passed");
		else             $display("tb_ym2612: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (2000000) @(posedge clk);
		$display("tb_ym2612: FAIL timeout");
		$finish;
	end

endmodule
