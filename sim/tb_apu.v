`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_apu - does each voice actually make a sound, and does it stop?
//
// Sound is the one part of a console where "it looks right" is no help at all,
// so these checks are deliberately about things that are true or false rather
// than about waveforms: a channel that is enabled moves, a channel whose length
// counter has run out is silent, a sweep changes the period, the frame counter
// raises its interrupt on time.
//
// The trap this is written against: every one of those mechanisms can be broken
// while the channel still makes a noise. A length counter that never decrements
// sounds fine on a held note and turns every game's music into a drone.
//////////////////////////////////////////////////////////////////////////////////

module tb_apu;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One CPU cycle every 12 clocks -- the ratio does not matter here, only that
	// the APU sees a clock enable rather than every edge.
	reg [3:0] div = 0;
	wire cpu_ce = (div == 4'd11);
	always @(posedge clk) div <= cpu_ce ? 4'd0 : div + 4'd1;

	reg  [4:0] addr = 0;
	reg  [7:0] din = 0;
	reg        we = 0, rd_status = 0;
	wire [7:0] status;
	wire       irq;
	wire [15:0] dmc_addr;
	wire       dmc_req;
	// Unsigned: the ring buffer is read as unsigned centred on 0x8000, and
	// treating it as signed here would make every comparison below a lie.
	wire [15:0] sample;

	reg dmc_ack_r = 0;
	integer ack_addr, ack_left;

	apu dut (
		.clk(clk), .rst(rst), .cpu_ce(cpu_ce),
		.addr(addr), .din(din), .we(we), .rd_status(rd_status),
		.status(status), .irq(irq),
		.dmc_addr(dmc_addr), .dmc_data(8'hAA),
		.dmc_req(dmc_req), .dmc_ack(dmc_ack_r),
		.sample(sample)
	);

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// Writes have to land on a cycle the APU is actually clocked on, or they
	// vanish -- which is its own class of bug and worth not having in the tests.
	task wr;
		input [4:0] a;
		input [7:0] d;
		begin
			@(posedge clk); while (!cpu_ce) @(posedge clk);
			#1 addr = a; din = d; we = 1;
			@(posedge clk); #1 we = 0;
		end
	endtask

	task cycles;
		input integer n;
		integer c;
		begin
			c = 0;
			while (c < n) begin @(posedge clk); if (cpu_ce) c = c + 1; end
		end
	endtask

	// Peak-to-peak over a window: the only honest way to ask "is this channel
	// making a sound" without caring what shape the sound is.
	// The sample is copied into an integer before comparing. Comparing an
	// unsigned wire against a signed integer makes the WHOLE comparison
	// unsigned in Verilog, so a negative initial value would never be beaten
	// and every measurement would come back empty.
	integer lo, hi, k, sv;
	task measure;
		input integer n;
		integer c;
		begin
			lo = 99999; hi = -1; c = 0;
			while (c < n) begin
				@(posedge clk);
				if (cpu_ce) begin
					c  = c + 1;
					sv = sample;
					if (sv < lo) lo = sv;
					if (sv > hi) hi = sv;
				end
			end
		end
	endtask

	initial begin
		$display("tb_apu");
		repeat (8) @(posedge clk);
		rst = 0;
		cycles(10);

		// --- pulse 1 ----------------------------------------------------------
		$display(" pulse:");
		wr(5'h15, 8'h01);          // enable pulse 1
		wr(5'h00, 8'h9F);          // 50% duty, looped envelope, constant volume 15
		wr(5'h02, 8'h40);          // period low
		wr(5'h03, 8'h08);          // period high + length index 1 (254)
		measure(4000);
		check(hi > lo, "pulse 1 output moves once enabled");
		check(hi - lo > 1000, "pulse 1 swing is a real signal, not a wobble");

		// Silence must sit at half scale, not at zero: the host reads these as
		// unsigned centred on 0x8000, so a zero would be full deflection.
		check(sample > 8000 && sample < 58000,
		      "output stays inside the range, centred rather than railed");

		// A period under eight cannot produce a waveform and the channel mutes.
		// "Silent" is not "instantly constant": the DC blocker takes a few
		// thousand samples to settle back to the centre, so the test waits for
		// it and then asks whether the swing has collapsed.
		wr(5'h02, 8'h04);
		wr(5'h03, 8'h08);
		cycles(80000);
		measure(2000);
		check(hi - lo < 200, "pulse 1 silent when its period is below eight");

		wr(5'h02, 8'h40);
		wr(5'h03, 8'h08);

		// --- the length counter stops a note ----------------------------------
		$display(" length counter:");
		wr(5'h00, 8'h1F);          // clear the halt bit so the counter runs
		wr(5'h03, 8'h18);          // length index 3 -> 2 half-frames
		check(status[0] === 1'b1, "status reports pulse 1 playing");
		cycles(40000);             // several half-frames
		check(status[0] === 1'b0, "length counter ran out and the note stopped");
		cycles(80000);             // let the DC blocker settle
		measure(2000);
		check(hi - lo < 200, "silent once the length counter is empty");

		// --- disabling clears it outright --------------------------------------
		wr(5'h15, 8'h01);
		wr(5'h03, 8'h08);
		check(status[0] === 1'b1, "re-triggered");
		wr(5'h15, 8'h00);
		check(status[0] === 1'b0, "clearing the enable bit empties the counter");

		// --- triangle -----------------------------------------------------------
		$display(" triangle:");
		wr(5'h15, 8'h04);
		wr(5'h08, 8'hFF);          // halt cleared later; long linear counter
		wr(5'h0A, 8'h40);
		wr(5'h0B, 8'h08);
		measure(4000);
		check(hi > lo, "triangle output moves");

		// --- noise ---------------------------------------------------------------
		$display(" noise:");
		wr(5'h15, 8'h08);
		wr(5'h0C, 8'h3F);          // looped envelope, constant volume 15
		wr(5'h0E, 8'h04);          // a short period, so it moves quickly
		wr(5'h0F, 8'h08);
		measure(4000);
		check(hi > lo, "noise output moves");
		check(dut.lfsr !== 15'd0, "the shift register never reaches zero");

		// --- sweep ----------------------------------------------------------------
		$display(" sweep:");
		wr(5'h15, 8'h01);
		wr(5'h00, 8'h9F);
		wr(5'h02, 8'h00);
		wr(5'h03, 8'h0A);          // period 0x200, long length
		wr(5'h01, 8'h8B);          // sweep on, period 0, negate, shift 3
		k = dut.pul_per[0];
		cycles(30000);
		check(dut.pul_per[0] != k[10:0], "the sweep moved the pulse period");

		// $08 in the sweep register (off, negate, shift 0) is how games keep low notes
		// playing: pulse 1's target is then period - period - 1, and a negated target
		// must never mute. (It did: the melody channel went silent in most songs.)
		wr(5'h01, 8'h08);
		wr(5'h02, 8'h40);
		wr(5'h03, 8'h08);
		cycles(80000);
		measure(4000);
		check(hi - lo > 1000, "pulse 1 plays with the sweep at $08 (negate, shift 0)");

		// --- the noise period is in CPU cycles ----------------------------------------
		// Index 4 is 64 CPU cycles a step: the shift register moves every 64th cycle.
		wr(5'h0E, 8'h04);
		begin : nper
			integer c, first, second; reg [14:0] l0;
			c = 0; first = -1; second = -1; l0 = dut.lfsr;
			while (second < 0 && c < 1000) begin
				@(posedge clk);
				if (cpu_ce) c = c + 1;
				if (dut.lfsr != l0) begin
					l0 = dut.lfsr;
					if (first < 0) first = c; else second = c;
				end
			end
			check(second - first == 64, "noise index 4 steps every 64 CPU cycles");
			if (second - first != 64) $display("       (every %0d)", second - first);
		end

		// --- the frame counter's interrupt ------------------------------------------
		$display(" frame counter:");
		wr(5'h17, 8'h00);          // four-step mode, interrupt allowed
		cycles(30000);             // more than one full sequence
		check(irq === 1'b1, "frame interrupt raised in four-step mode");
		// at the real rate: 29829 CPU cycles after the $4017 write, not half that
		rd_status = 1;
		@(posedge clk); while (!cpu_ce) @(posedge clk);
		@(posedge clk); #1 rd_status = 0;
		wr(5'h17, 8'h00);
		cycles(29000);
		check(irq === 1'b0, "no frame interrupt before 29000 CPU cycles");
		cycles(1000);
		check(irq === 1'b1, "the frame interrupt by 30000");
		rd_status = 1;
		@(posedge clk); while (!cpu_ce) @(posedge clk);
		@(posedge clk); #1 rd_status = 0;
		cycles(4);
		check(irq === 1'b0, "reading $4015 acknowledges it");

		wr(5'h17, 8'h80);          // five-step mode raises no interrupt at all
		cycles(40000);
		check(irq === 1'b0, "five-step mode never interrupts");

		// --- the delta player asks for data -------------------------------------------
		$display(" delta player:");
		wr(5'h10, 8'h0F);          // fastest rate
		wr(5'h12, 8'h00);          // sample at $C000
		wr(5'h13, 8'h01);          // 17 bytes
		wr(5'h15, 8'h10);          // enable it
		cycles(50);
		check(dmc_req === 1'b1, "requests a byte once it has something to play");
		check(dmc_addr == 16'hC000, "fetches from $C000, where $4012 pointed it");

		// One acknowledge must advance the sample pointer exactly once. The
		// acknowledge comes from outside and is not gated by the clock enable,
		// so a handler that runs on every clock it is held would tear through
		// the sample many times too fast -- which sounds like a buzz under the
		// music rather than like silence, and is easy to miss by ear.
		ack_addr = dmc_addr;
		ack_left = dut.dmc_left;
		dmc_ack_r = 1'b1;
		repeat (8) @(posedge clk);      // held for several clocks, as it would be
		#1 dmc_ack_r = 1'b0;
		repeat (4) @(posedge clk); #1;
		check(dmc_addr == ack_addr + 16'd1,
		      "one acknowledge advances the address by exactly one");
		check(dut.dmc_left == ack_left - 12'd1,
		      "and the remaining length by exactly one");

		$display("");
		if (errors == 0) $display("tb_apu: all checks passed");
		else             $display("tb_apu: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (20_000_000) @(posedge clk);
		$display("tb_apu: FAIL timeout");
		$finish;
	end

endmodule
