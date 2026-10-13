`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_gb_apu - the Game Boy's sound chip on its own, against the numbers in the
// documentation rather than against another implementation.
//
// One T-cycle per clock. The 512 Hz frame-sequencer tick is made here the way
// gb_top makes it -- DIV bit 4 (system counter bit 12) falling -- so every 8192
// clocks.
//
// What is checked:
//   - a pulse channel's period: 4 x (2048 - f) T-cycles per duty step, 8 steps,
//     and the 50% duty is high for exactly half of it; two frequencies
//   - the frame sequencer: length at 256 Hz, sweep at 128 Hz, envelope at 64 Hz,
//     measured as the spacing of the events it produces
//   - the length counter switches a channel off on exactly the n-th length clock
//   - the envelope steps the volume once per (pace) 64 Hz ticks
//   - the sweep: one iteration moves the period by f >> step, and a trigger that
//     would overflow switches the channel straight off
//   - the wave channel plays nibble 1 first (not 0), at 2 x (2048 - f) per sample
//   - the noise LFSR repeats every 127 clocks in 7-bit mode and 32767 in 15-bit
//   - the mixer's levels, the NR52 read-back and what power-off clears
//////////////////////////////////////////////////////////////////////////////////

module tb_gb_apu;

	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;

	reg  [5:0] reg_a = 0;
	reg        reg_we = 0;
	reg  [7:0] reg_d = 0;
	wire [7:0] reg_q;
	wire signed [15:0] audio_l, audio_r;

	// the system counter and the 512 Hz tick, as gb_top has them
	reg [15:0] sysc = 0;
	reg        b12_q = 0;
	always @(posedge clk) begin sysc <= sysc + 16'd1; b12_q <= sysc[12]; end
	wire fs_tick = b12_q && !sysc[12];

	gb_apu dut (
		.clk(clk), .rst(rst), .ce(1'b1), .fs_tick(fs_tick),
		.reg_a(reg_a), .reg_we(reg_we), .reg_d(reg_d), .reg_q(reg_q),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	integer errors = 0;
	task check;
		input cond;
		input [1023:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	task wr;
		input [7:0] a;      // the full $FFxx low byte
		input [7:0] d;
		begin
			@(negedge clk);
			reg_a = a[5:0]; reg_d = d; reg_we = 1;
			@(negedge clk);
			reg_we = 0;
		end
	endtask
	reg [7:0] rq;
	task rd;
		input [7:0] a;
		begin
			@(negedge clk);
			reg_a = a[5:0];
			#1 rq = reg_q;
		end
	endtask

	integer t0, t1, t2, i, n, k;
	integer clocks = 0;
	always @(posedge clk) clocks <= clocks + 1;

	// --- measuring one channel's digital output --------------------------------------------
	task wait_change;               // until ch2's output changes; returns the clock
		output integer at;
		reg [3:0] was;
		begin
			was = dut.c2_out;
			@(posedge clk); #1;
			while (dut.c2_out == was) begin @(posedge clk); #1; end
			at = clocks;
		end
	endtask

	task square_period;
		input [10:0] f;
		integer per, hi, a, b, c;
		reg [3:0] lvl;
		begin
			wr(8'h16, 8'h80);                 // 50% duty
			wr(8'h17, 8'hF0);                 // volume 15, no envelope
			wr(8'h18, f[7:0]);
			wr(8'h19, {5'b10000, f[10:8]});   // trigger
			wait_change(a); wait_change(a);   // past the start
			lvl = dut.c2_out;
			wait_change(b);
			wait_change(c);
			per = c - a; hi = (lvl == 4'd15) ? b - a : c - b;
			$display("    f=$%03x: period %0d T-cycles, high %0d", f, per, hi);
			check(per == 32 * (2048 - f), "the pulse period is 8 steps of 4 x (2048 - f) T-cycles");
			check(hi == 16 * (2048 - f), "50% duty is high for half of it");
		end
	endtask

	// spacing of a frame-sequencer event, in clocks
	task event_spacing;
		input integer which;          // 0 length, 1 sweep, 2 envelope
		output integer d1, d2;
		integer a, b, c;
		begin
			case (which)
				0: begin @(posedge dut.fs_len);   a = clocks; @(posedge dut.fs_len);   b = clocks; @(posedge dut.fs_len);   c = clocks; end
				1: begin @(posedge dut.fs_sweep); a = clocks; @(posedge dut.fs_sweep); b = clocks; @(posedge dut.fs_sweep); c = clocks; end
				default: begin @(posedge dut.fs_env); a = clocks; @(posedge dut.fs_env); b = clocks; @(posedge dut.fs_env); c = clocks; end
			endcase
			d1 = b - a; d2 = c - b;
		end
	endtask

	reg [15:0] lfsr0;

	initial begin
		$display("tb_gb_apu");
		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);

		// --- what the boot ROM leaves ----------------------------------------------------------
		$display(" after reset:");
		rd(8'h26); check(rq == 8'hF1, "NR52 reads $F1 (sound on, channel 1 on)");
		rd(8'h10); check(rq == 8'h80, "NR10 reads $80");
		rd(8'h11); check(rq == 8'hBF, "NR11 reads $BF");
		rd(8'h24); check(rq == 8'h77, "NR50 is $77");
		rd(8'h25); check(rq == 8'hF3, "NR51 is $F3");

		// --- the frame sequencer --------------------------------------------------------------------
		$display(" the frame sequencer (8192 T-cycles a step):");
		event_spacing(0, t1, t2); $display("    length every %0d, %0d", t1, t2);
		check(t1 == 16384 && t2 == 16384, "length clocks at 256 Hz");
		event_spacing(1, t1, t2); $display("    sweep every %0d, %0d", t1, t2);
		check(t1 == 32768 && t2 == 32768, "sweep clocks at 128 Hz");
		event_spacing(2, t1, t2); $display("    envelope every %0d, %0d", t1, t2);
		check(t1 == 65536 && t2 == 65536, "envelope clocks at 64 Hz");

		// --- pulse period ------------------------------------------------------------------------------
		$display(" a pulse channel's period:");
		wr(8'h25, 8'h22);                     // channel 2 to both sides
		square_period(11'h740);
		square_period(11'h500);

		// --- the mixer --------------------------------------------------------------------------------------
		$display(" the mixer:");
		// channel 2 at digital 15 and 0, NR50 = $77 (x8): 15 -> -15, 0 -> +15, times 8, times 64
		while (dut.c2_out != 4'd15) @(posedge clk);
		repeat (2) @(posedge clk); #1;
		$display("    digital 15 -> %0d", audio_l);
		check(audio_l == -15 * 8 * 64, "digital 15 is the bottom of the DAC's range");
		while (dut.c2_out != 4'd0) @(posedge clk);
		repeat (2) @(posedge clk); #1;
		check(audio_l == 15 * 8 * 64, "digital 0 is the top (the DAC slopes down)");
		wr(8'h24, 8'h70);                     // right volume 0 (x1), left 7 (x8)
		repeat (2) @(posedge clk); #1;
		check(audio_r == 15 * 1 * 64 && audio_l == 15 * 8 * 64, "NR50 scales each side separately, and 0 is x1, not mute");
		wr(8'h25, 8'h02);                     // channel 2 right only
		repeat (2) @(posedge clk); #1;
		check(audio_l == 0, "NR51 takes a channel off one side");
		wr(8'h24, 8'h77); wr(8'h25, 8'h22);

		// --- length -----------------------------------------------------------------------------------------
		$display(" the length counter:");
		wr(8'h16, 8'h80 | (64 - 4));          // 4 length clocks
		@(posedge dut.fs_len); #1;            // just after one, so the next is a full period off
		wr(8'h19, 8'hC7);                     // trigger with length on
		rd(8'h26); check(rq[1] == 1'b1, "triggering turns channel 2 on");
		n = 0;
		while (dut.c2_en) begin @(posedge clk); if (dut.fs_len) n = n + 1; end
		$display("    off after %0d length clocks", n);
		check(n == 4, "a length of 4 switches the channel off on the 4th length clock");
		rd(8'h26); check(rq[1] == 1'b0, "NR52 shows channel 2 off");

		// --- envelope --------------------------------------------------------------------------------------
		$display(" the envelope:");
		wr(8'h17, 8'hF2);                     // 15, down, every 2 ticks
		wr(8'h19, 8'h87);
		for (k = 0; k < 6; k = k + 1) @(posedge dut.fs_env);
		@(posedge clk); #1;
		$display("    volume after 6 envelope ticks at pace 2: %0d", dut.u_ch2.vol);
		check(dut.u_ch2.vol == 4'd12, "pace 2 takes one step per two 64 Hz ticks");
		wr(8'h17, 8'h19);                     // 1, up, every tick
		wr(8'h19, 8'h87);
		for (k = 0; k < 20; k = k + 1) @(posedge dut.fs_env);
		@(posedge clk); #1;
		check(dut.u_ch2.vol == 4'd15, "an increasing envelope stops at 15");

		// --- sweep -----------------------------------------------------------------------------------------------
		$display(" the sweep (channel 1):");
		wr(8'h12, 8'hF0);
		wr(8'h10, 8'h11);                     // pace 1, up, step 1
		wr(8'h13, 8'h00);
		wr(8'h14, 8'h84);                     // f = $400, trigger
		@(posedge dut.fs_sweep); @(posedge clk); #1;
		$display("    period after one iteration: $%03x", dut.u_ch1.shadow);
		check(dut.u_ch1.shadow == 11'h600 && {dut.u_ch1.nr4[2:0], dut.u_ch1.nr3} == 11'h600,
		      "one iteration adds f >> 1 and writes it back to NR13/NR14");
		@(posedge dut.fs_sweep); @(posedge clk); #1;
		check(dut.c1_en == 1'b0, "the next would pass $7FF: the channel is switched off");
		wr(8'h13, 8'h00);
		wr(8'h14, 8'h87);                     // f = $700: $700 + $380 overflows at the trigger itself
		rd(8'h26); check(rq[0] == 1'b0, "a trigger whose first calculation overflows leaves the channel off");
		wr(8'h10, 8'h00);

		// --- wave ------------------------------------------------------------------------------------------------
		$display(" the wave channel:");
		wr(8'h1A, 8'h00);
		for (i = 0; i < 16; i = i + 1) wr(8'h30 + i, {i[3:0], 4'hF - i[3:0]});   // nibbles 0,F,1,E,2,D,...
		rd(8'h31); check(rq == 8'h1E, "wave RAM reads back while the channel is stopped");
		wr(8'h1A, 8'h80);
		wr(8'h1C, 8'h20);                     // 100%
		wr(8'h1D, 8'hC0);
		wr(8'h1E, 8'h87);                     // f = $7C0: 2 x 64 = 128 T-cycles a sample
		@(posedge clk); #1;
		while (dut.c3_pos == 5'd0) begin @(posedge clk); #1; end
		t0 = clocks;
		$display("    first sample read: index %0d = %x", dut.c3_pos, dut.c3_out);
		check(dut.c3_pos == 5'd1 && dut.c3_out == 4'hF, "the first sample played is index 1 (index 0 is skipped)");
		while (dut.c3_pos == 5'd1) begin @(posedge clk); #1; end
		t1 = clocks;
		check(t1 - t0 == 128, "a sample lasts 2 x (2048 - f) T-cycles");
		check(dut.c3_out == 4'h1, "then index 2");
		rd(8'h30); check(rq == 8'hFF, "wave RAM reads $FF while the channel plays (DMG)");
		wr(8'h1A, 8'h00);

		// --- noise -----------------------------------------------------------------------------------------------
		$display(" the noise channel:");
		wr(8'h21, 8'hF0);
		wr(8'h22, 8'h08);                     // 7-bit, shift 0, divider 0: a clock every 8 T-cycles
		wr(8'h23, 8'h80);
		repeat (8 * 200) @(posedge clk);      // well into the sequence
		#1 lfsr0 = dut.lfsr;
		n = 0;
		repeat (8) @(posedge clk);
		#1 n = 1;
		while (dut.lfsr[6:0] != lfsr0[6:0] && n < 1000) begin repeat (8) @(posedge clk); #1 n = n + 1; end
		$display("    7-bit mode repeats after %0d clocks of the LFSR", n);
		check(n == 127, "7-bit noise has period 127");
		wr(8'h22, 8'h00);                     // 15-bit
		wr(8'h23, 8'h80);
		repeat (8 * 100) @(posedge clk);
		#1 lfsr0 = dut.lfsr;
		repeat (8) @(posedge clk);
		#1 n = 1;
		while (dut.lfsr[14:0] != lfsr0[14:0] && n < 40000) begin repeat (8) @(posedge clk); #1 n = n + 1; end
		$display("    15-bit mode repeats after %0d", n);
		check(n == 32767, "15-bit noise has period 32767");
		wr(8'h22, 8'hE0);                     // shift 14: no clocks at all
		wr(8'h23, 8'h80);
		#1 lfsr0 = dut.lfsr;
		repeat (5000) @(posedge clk);
		#1 check(dut.lfsr == lfsr0, "a clock shift of 14 stops the LFSR");

		// --- power ---------------------------------------------------------------------------------------------
		$display(" power:");
		wr(8'h30, 8'h5A);
		wr(8'h26, 8'h00);
		rd(8'h26); check(rq == 8'h70, "NR52 reads $70 with the sound off");
		rd(8'h25); check(rq == 8'h00, "power-off clears NR51");
		rd(8'h17); check(rq == 8'h00, "and NR22");
		wr(8'h25, 8'hFF);
		rd(8'h25); check(rq == 8'h00, "registers ignore writes while off");
		rd(8'h30); check(rq == 8'h5A, "wave RAM survives power-off");
		wr(8'h26, 8'h80);
		wr(8'h25, 8'hFF);
		rd(8'h25); check(rq == 8'hFF, "and work again once it is back on");

		if (errors == 0) $display("tb_gb_apu: all checks passed");
		else $display("tb_gb_apu: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		#(64'd20 * 64'd8_000_000);
		$display("tb_gb_apu: TIMEOUT");
		$finish;
	end

endmodule
