`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pce_psg.v - the PC Engine's sound: the six wavetable channels inside the HuC6280.
//
// Each channel plays a 32-step, 5-bit waveform the program writes, at a rate set by a 12-bit
// divider of the 3.58 MHz sound clock (the step advances every `frequency` clocks, 0 counting
// as 4096), or in DDA mode puts out the samples the program writes one by one, and channels
// 4 and 5 can play noise instead (an 18-bit shift register, taps 0 1 11 12 17, clocked every
// 64 x (31 - rate) sound clocks). Channel 0 can be frequency-modulated by channel 1's
// waveform (the LFO registers). Three volumes attenuate each side in 1.5 dB steps: the main
// balance, the channel's volume and its balance, the nibbles through the chip's table.
//
// The registers at $0800-$0809 as MAME's c6280 and the documentation give them. The output is
// the six channels summed, signed 16 bits a side, continuous: the top's HDMI path takes it
// at its own rate.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module pce_psg #(
	parameter CLK_HZ = 50_000_000
) (
	input  wire        clk,
	input  wire        rst,
	input  wire        sel,           // physical $1FE800-$1FEBFF
	input  wire [3:0]  a,
	input  wire        we,
	input  wire [7:0]  d,
	output reg  signed [15:0] audio_l,
	output reg  signed [15:0] audio_r
);
	// --- the registers --------------------------------------------------------------------------
	reg [2:0]  chsel;
	reg [7:0]  mainbal;               // left in the high nibble, right in the low
	reg [11:0] freq  [0:5];
	reg [7:0]  ctl   [0:5];           // [7] on, [6] DDA, [4:0] volume
	reg [7:0]  bal   [0:5];
	reg [4:0]  dda   [0:5];
	reg [7:0]  noise [0:5];           // [7] on, [4:0] rate (channels 4 and 5)
	reg [7:0]  lfo_f;
	reg [7:0]  lfo_c;
	reg [4:0]  wave [0:191];          // 6 x 32 samples
	reg [4:0]  widx  [0:5];           // the write index
	integer i;
	always @(posedge clk) begin
		if (rst) begin
			chsel <= 0; mainbal <= 0; lfo_f <= 0; lfo_c <= 0;
			for (i = 0; i < 6; i = i + 1) begin freq[i] <= 0; ctl[i] <= 0; bal[i] <= 0; dda[i] <= 0; noise[i] <= 0; widx[i] <= 0; end
		end else if (sel && we) case (a)
			4'd0: chsel <= d[2:0];
			4'd1: mainbal <= d;
			4'd2: if (chsel < 6) freq[chsel][7:0] <= d;
			4'd3: if (chsel < 6) freq[chsel][11:8] <= d[3:0];
			4'd4: if (chsel < 6) begin
				ctl[chsel] <= d;
				if (ctl[chsel][6] && !d[6]) widx[chsel] <= 5'd0;        // leaving DDA: the waveform from its start
			end
			4'd5: if (chsel < 6) bal[chsel] <= d;
			4'd6: if (chsel < 6) begin
				if (ctl[chsel][6]) dda[chsel] <= d[4:0];
				else if (!ctl[chsel][7]) begin wave[{chsel, widx[chsel]}] <= d[4:0]; widx[chsel] <= widx[chsel] + 5'd1; end
			end
			4'd7: if (chsel >= 4 && chsel < 6) noise[chsel] <= d;
			4'd8: lfo_f <= d;
			4'd9: lfo_c <= d;
			default: ;
		endcase
	end

	// --- the sound clock: 3579545 Hz -----------------------------------------------------------------
	localparam [31:0] PSG_HZ = 32'd3_579_545;
	reg [31:0] acc; reg psg_ce;
	always @(posedge clk) begin
		psg_ce <= 1'b0;
		if (rst) acc <= 0;
		else if (acc + PSG_HZ >= CLK_HZ) begin acc <= acc + PSG_HZ - CLK_HZ; psg_ce <= 1'b1; end
		else acc <= acc + PSG_HZ;
	end

	// --- the channels: a counter, a step, the noise registers ----------------------------------------
	reg [12:0] cnt  [0:5];
	reg [4:0]  step [0:5];            // the sample being played
	reg [12:0] ncnt [0:5];
	reg [17:0] lfsr [0:5];
	reg [7:0]  lfo_cnt; reg [4:0] lfo_i;
	wire [12:0] lfo_amt = {{8{wave[{3'd1, lfo_i}][4]}}, 1'b0, wave[{3'd1, lfo_i}][3:0]} ^ 13'h0010;   // (sample - 16, signed)
	always @(posedge clk) begin
		if (rst) begin
			for (i = 0; i < 6; i = i + 1) begin cnt[i] <= 0; step[i] <= 0; ncnt[i] <= 0; lfsr[i] <= 18'd1; end
			lfo_cnt <= 0; lfo_i <= 0;
		end else if (psg_ce) begin
			for (i = 0; i < 6; i = i + 1) begin
				if (ctl[i][7]) begin
					if (cnt[i] <= 13'd1) begin
						// channel 0 under the LFO: the frequency moved by channel 1's sample
						if (i == 0 && lfo_c[1:0] != 2'd0)
							cnt[i] <= {1'b0, freq[0]} + (lfo_c[1:0] == 2'd1 ? lfo_amt : lfo_c[1:0] == 2'd2 ? {lfo_amt[10:0], 2'd0} : {lfo_amt[8:0], 4'd0});
						else cnt[i] <= (freq[i] == 12'd0) ? 13'd4096 : {1'b0, freq[i]};
						if (!ctl[i][6]) step[i] <= step[i] + 5'd1;
					end else cnt[i] <= cnt[i] - 13'd1;
				end
				// the noise shift register, channels 4 and 5
				if (i >= 4 && noise[i][7]) begin
					if (ncnt[i] == 13'd0) begin
						ncnt[i] <= {2'd0, ~noise[i][4:0], 6'd0};                 // 64 x (rate ^ 31)
						lfsr[i] <= {lfsr[i][0] ^ lfsr[i][1] ^ lfsr[i][11] ^ lfsr[i][12] ^ lfsr[i][17], lfsr[i][17:1]};
					end else ncnt[i] <= ncnt[i] - 13'd1;
				end
			end
			// the LFO: channel 1's waveform at its rate times the LFO frequency
			if (lfo_c[7]) begin lfo_i <= 5'd0; lfo_cnt <= 8'd0; end
			else if (lfo_c[1:0] != 2'd0) begin
				if (cnt[1] <= 13'd1) begin
					if (lfo_cnt >= lfo_f) begin lfo_cnt <= 8'd0; lfo_i <= lfo_i + 5'd1; end
					else lfo_cnt <= lfo_cnt + 8'd1;
				end
			end
		end
	end

	// --- the mix: a channel a clock after each sound clock, through the volume table ---------------
	function [4:0] baltab; input [3:0] n; begin
		case (n) 0: baltab = 0; 1: baltab = 3; 2: baltab = 5; 3: baltab = 7; 4: baltab = 9; 5: baltab = 11; 6: baltab = 13; 7: baltab = 15;
		         8: baltab = 16; 9: baltab = 19; 10: baltab = 21; 11: baltab = 23; 12: baltab = 25; 13: baltab = 27; 14: baltab = 29; default: baltab = 31; endcase
	end endfunction
	function [8:0] voltab; input [4:0] n; begin
		case (n) 0: voltab = 400; 1: voltab = 337; 2: voltab = 283; 3: voltab = 238; 4: voltab = 200; 5: voltab = 169; 6: voltab = 142; 7: voltab = 119;
		         8: voltab = 100; 9: voltab = 85; 10: voltab = 71; 11: voltab = 60; 12: voltab = 50; 13: voltab = 42; 14: voltab = 36; 15: voltab = 30;
		         16: voltab = 25; 17: voltab = 21; 18: voltab = 18; 19: voltab = 15; 20: voltab = 13; 21: voltab = 11; 22: voltab = 9; 23: voltab = 8;
		         24: voltab = 6; 25: voltab = 5; 26: voltab = 4; 27: voltab = 4; 28: voltab = 3; 29: voltab = 3; 30: voltab = 2; default: voltab = 0; endcase
	end endfunction
	reg [2:0] mix_i; reg mixing;
	reg signed [17:0] sum_l, sum_r;
	wire [2:0] mi = mix_i;
	wire [4:0] samp = ctl[mi][6] ? dda[mi] : (mi >= 4 && noise[mi][7]) ? {5{lfsr[mi][0]}} : wave[{mi, step[mi]}];
	wire signed [5:0] samp_s = {1'b0, samp} - 6'd16;
	wire [6:0] att_l = (7'd31 - baltab(mainbal[7:4])) + (7'd31 - {2'd0, ctl[mi][4:0]}) + (7'd31 - baltab(bal[mi][7:4]));
	wire [6:0] att_r = (7'd31 - baltab(mainbal[3:0])) + (7'd31 - {2'd0, ctl[mi][4:0]}) + (7'd31 - baltab(bal[mi][3:0]));
	wire [8:0] g_l = ctl[mi][7] ? voltab(att_l > 7'd31 ? 5'd31 : att_l[4:0]) : 9'd0;
	wire [8:0] g_r = ctl[mi][7] ? voltab(att_r > 7'd31 ? 5'd31 : att_r[4:0]) : 9'd0;
	wire signed [15:0] p_l = samp_s * $signed({1'b0, g_l});
	wire signed [15:0] p_r = samp_s * $signed({1'b0, g_r});
	always @(posedge clk) begin
		if (rst) begin mix_i <= 0; mixing <= 0; sum_l <= 0; sum_r <= 0; audio_l <= 0; audio_r <= 0; end
		else begin
			if (psg_ce) begin mixing <= 1'b1; mix_i <= 3'd0; sum_l <= 0; sum_r <= 0; end
			else if (mixing) begin
				sum_l <= sum_l + p_l; sum_r <= sum_r + p_r;
				if (mix_i == 3'd5) begin
					mixing <= 1'b0;
					// six channels of 16 x 400 at most: 38400, into 16 bits with a little in hand
					audio_l <= (sum_l + p_l) >>> 1; audio_r <= (sum_r + p_r) >>> 1;
				end
				mix_i <= mix_i + 3'd1;
			end
		end
	end

endmodule

`default_nettype wire
