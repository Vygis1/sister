//////////////////////////////////////////////////////////////////////////////////
// aud_filter.v - one channel of a console's sound, as the chip leaves it, made into
// a 48 kHz sample for HDMI: low-passed at about 15.5 kHz (y += (x - y) / 512 at
// 50 MHz, 8 fraction bits), its DC taken away by a slow second average (corner
// ~8 Hz, with 20 more fraction bits so it settles exactly), halved so the swing
// fits 16 signed bits, and then each output sample the AVERAGE of the ~1042 clocks
// since the last one -- not one clock picked out.
//
// The average is what matters for most of these chips: a square wave's harmonics
// run far past 24 kHz and picked samples fold them back as tones that are not in
// the music (the NES); and the Mega Drive's FM chip time-multiplexes its channels
// onto its output, as the real YM2612 does, so at any one clock it holds one
// channel's slot -- picked at 48 kHz that is a random channel each time, a crackle.
//
// The input is UNSIGNED, silence anywhere (the NES mixer's is 0 and its loudest
// 65000; a signed source XORs 0x8000 on the way in).
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module aud_filter (
	input  wire        clk,               // 50 MHz
	input  wire [15:0] x,
	input  wire        tick,              // a sample is due (48000 a second)
	output reg  [15:0] y                  // signed
);
	reg  signed [25:0] alp;
	reg  signed [45:0] adc;
	reg  signed [36:0] asum;
	wire signed [25:0] aac = alp - $signed(adc[45:20]);
	wire signed [53:0] amean = asum * $signed(18'sd64424);   // the mean, << 26 (2^26 / 1041.67)
	wire signed [16:0] ah  = amean[51:35];                   // (>> 26, then >> 9)
	initial begin alp = 26'sd0; adc = 46'sd0; asum = 37'sd0; y = 16'd0; end
	always @(posedge clk) begin
		alp <= alp + (($signed({2'b00, x, 8'd0}) - alp) >>> 9);
		adc <= adc + {{20{alp[25]}}, alp} - {{20{adc[45]}}, adc[45:20]};
		if (tick) begin
			y    <= (ah > 17'sd32767) ? 16'h7FFF : (ah < -17'sd32768) ? 16'h8000 : ah[15:0];
			asum <= {{11{aac[25]}}, aac};
		end else
			asum <= asum + {{11{aac[25]}}, aac};
	end
endmodule

`default_nettype wire
