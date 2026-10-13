//////////////////////////////////////////////////////////////////////////////////
// psg.v - the SN76489, the Master System's sound.
//
// Four voices: three square waves and a noise channel. No envelopes, no sweep,
// no sample playback -- next to the NES's APU it is almost nothing, which is
// why Master System music leans on fast arpeggios where a NES tune would just
// play a chord.
//
// --- how a program talks to it ---------------------------------------------------
//
// One port, one byte at a time, and the byte says which kind it is:
//
//   1ccTdddd   latch: channel cc, T picks volume (1) or tone (0), low 4 bits
//   0-dddddd   data: the upper 6 bits of whatever was latched last
//
// So setting a 10-bit period is two writes and setting a volume is one. There
// is no way to read any of it back, which is why a game keeps its own copy of
// what it last wrote.
//
// --- volume is attenuation ---------------------------------------------------------
//
// Zero is loudest and fifteen is silent, in 2 dB steps. The table below is that
// curve: each step is about 0.794 of the one before, and the last entry is a
// true zero rather than the -30 dB the curve would give, because the chip
// switches the channel off rather than turning it down.
//
// --- the counters -------------------------------------------------------------------
//
// Each tone channel counts its 10-bit period down at the chip clock over
// sixteen and flips its output at zero, so the note is the period over 32. A
// period of zero or one is too fast to hear and the real chip outputs a steady
// level; games use that deliberately to mute a channel without changing its
// volume.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module psg (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,           // one CPU clock, nominally 3.58 MHz
	input  wire [7:0]  din,
	input  wire        we,
	output wire [15:0] sample,       // unsigned, centred on $8000
	// the Game Gear's stereo (port 06h): bits 7-4 let channels 3-0 out on the LEFT, bits 3-0 on
	// the RIGHT. The two sides, SIGNED.
	input  wire [7:0]  stereo,
	output wire signed [15:0] sample_l,
	output wire signed [15:0] sample_r
);

	// --- the registers, as the chip sees them -----------------------------------
	reg [9:0] period [0:3];          // channel 3's is the noise control
	reg [3:0] att    [0:3];
	reg [1:0] latch_ch;
	reg       latch_vol;

	// --- the divider ------------------------------------------------------------
	// Everything runs at the chip clock over sixteen.
	reg [3:0] predivide;
	wire tick = ce && (predivide == 4'd15);
	always @(posedge clk) begin
		if (rst) predivide <= 4'd0;
		else if (ce) predivide <= predivide + 4'd1;
	end

	// --- tone channels -----------------------------------------------------------
	reg [9:0] counter [0:3];
	reg [2:0] level;                 // one bit per tone channel
	reg [15:0] lfsr;

	// Rate 3 means "follow channel 2", which is how a game makes pitched noise.
	wire [9:0] noise_period = (period[3][1:0] == 2'd0) ? 10'd16
	                        : (period[3][1:0] == 2'd1) ? 10'd32
	                        : (period[3][1:0] == 2'd2) ? 10'd64
	                                                   : period[2];
	wire noise_white = period[3][2];

	integer i;
	always @(posedge clk) begin
		if (rst) begin
			for (i = 0; i < 4; i = i + 1) begin
				period[i]  <= 10'd0;
				att[i]     <= 4'd15;       // silent, which is how it powers up
				counter[i] <= 10'd0;
			end
			latch_ch <= 2'd0; latch_vol <= 1'b0;
			level <= 3'b000;
			lfsr  <= 16'h8000;
		end else begin
			if (tick) begin
				for (i = 0; i < 3; i = i + 1) begin
					if (counter[i] == 10'd0) begin
						counter[i] <= period[i];
						level[i]   <= ~level[i];
					end else counter[i] <= counter[i] - 10'd1;
				end

				if (counter[3] == 10'd0) begin
					counter[3] <= noise_period;
					// White noise taps two bits; periodic noise just rotates,
					// giving a buzz at a fifteenth of the rate.
					lfsr <= {(noise_white ? (lfsr[0] ^ lfsr[3]) : lfsr[0]),
					         lfsr[15:1]};
				end else counter[3] <= counter[3] - 10'd1;
			end

			// --- writes ---------------------------------------------------------
			if (we) begin
				if (din[7]) begin
					latch_ch  <= din[6:5];
					latch_vol <= din[4];
					if (din[4]) att[din[6:5]] <= din[3:0];
					else        period[din[6:5]][3:0] <= din[3:0];
					// A latch to the noise register restarts its shift register,
					// which is what stops a noise burst from sounding different
					// depending on what came before it.
					if (!din[4] && din[6:5] == 2'd3) lfsr <= 16'h8000;
				end else begin
					if (latch_vol) att[latch_ch] <= din[3:0];
					else           period[latch_ch][9:4] <= din[5:0];
				end
			end
		end
	end

	// --- mixing -------------------------------------------------------------------
	// Attenuation in 2 dB steps. The last entry is a true zero: the chip switches
	// the channel off rather than turning it down another notch.
	function [11:0] amp;
		input [3:0] a;
		case (a)
		4'd0:  amp = 12'd2047;  4'd1:  amp = 12'd1625;
		4'd2:  amp = 12'd1290;  4'd3:  amp = 12'd1024;
		4'd4:  amp = 12'd813;   4'd5:  amp = 12'd645;
		4'd6:  amp = 12'd512;   4'd7:  amp = 12'd407;
		4'd8:  amp = 12'd323;   4'd9:  amp = 12'd256;
		4'd10: amp = 12'd203;   4'd11: amp = 12'd161;
		4'd12: amp = 12'd128;   4'd13: amp = 12'd102;
		4'd14: amp = 12'd81;    default: amp = 12'd0;
		endcase
	endfunction

	// A period below two is faster than the output can follow, so the channel
	// sits at a steady level. Games use that to mute without touching volume.
	wire t0 = (period[0] < 10'd2) ? 1'b1 : level[0];
	wire t1 = (period[1] < 10'd2) ? 1'b1 : level[1];
	wire t2 = (period[2] < 10'd2) ? 1'b1 : level[2];

	wire signed [13:0] c0 = t0      ? $signed({2'b0, amp(att[0])}) : -$signed({2'b0, amp(att[0])});
	wire signed [13:0] c1 = t1      ? $signed({2'b0, amp(att[1])}) : -$signed({2'b0, amp(att[1])});
	wire signed [13:0] c2 = t2      ? $signed({2'b0, amp(att[2])}) : -$signed({2'b0, amp(att[2])});
	wire signed [13:0] c3 = lfsr[0] ? $signed({2'b0, amp(att[3])}) : -$signed({2'b0, amp(att[3])});

	wire signed [15:0] mix = {{2{c0[13]}}, c0} + {{2{c1[13]}}, c1}
	                       + {{2{c2[13]}}, c2} + {{2{c3[13]}}, c3};

	// The ring buffer downstream reads samples as unsigned centred on half
	// scale, the same convention the NES's APU uses.
	assign sample = mix + 16'sd32768;
	assign sample_l = (stereo[4] ? {{2{c0[13]}}, c0} : 16'sd0) + (stereo[5] ? {{2{c1[13]}}, c1} : 16'sd0)
	                + (stereo[6] ? {{2{c2[13]}}, c2} : 16'sd0) + (stereo[7] ? {{2{c3[13]}}, c3} : 16'sd0);
	assign sample_r = (stereo[0] ? {{2{c0[13]}}, c0} : 16'sd0) + (stereo[1] ? {{2{c1[13]}}, c1} : 16'sd0)
	                + (stereo[2] ? {{2{c2[13]}}, c2} : 16'sd0) + (stereo[3] ? {{2{c3[13]}}, c3} : 16'sd0);

endmodule

`default_nettype wire
