`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// gb_apu.v - the Game Boy's sound: two pulse channels, a wave channel, noise.
//
// "The PPU is a bunch of state machines, the APU is a bunch of counters." Every
// channel is a period counter that overflows into a waveform step, a length
// counter that can switch the channel off, and (except the wave channel) a
// volume envelope. All of them are paced by a frame sequencer that steps at
// 512 Hz -- derived in the top from DIV bit 4 falling, which is why writing DIV
// also hurries the sound along, as it does on the console:
//
//   step   0  1  2  3  4  5  6  7
//   length x     x     x     x
//   sweep        x           x
//   envelope                    x
//
// Output is what the console's DACs and mixer would give: a channel whose DAC is
// on contributes +15 for digital 0 down to -15 for digital 15 (the slope really is
// negative), the four are summed per side as NR51 says, scaled by NR50's volume
// (1..8), and the result is left as a signed 16-bit sample updated every T-cycle.
// There is no high-pass filter here: a channel sitting idle with its DAC on puts
// a DC offset on the output exactly as the real one does before its capacitor,
// and whatever plays this should take the DC out as a real speaker path would.
//
// --- what is and is not here ------------------------------------------------------------
//
// In: length, envelope, sweep with its overflow check and the second calculation,
// the duty waveforms, the wave channel's sample buffer and its skipped first
// sample, the 15/7-bit LFSR, NR52 power with the register clear, the read masks,
// the "period 0 means 8" rule, the extra length clock when enabling length on an
// odd frame-sequencer half, and the wave RAM lockout while channel 3 plays.
// Out: the DMG's wave RAM corruption on retrigger and the "zombie" volume tricks.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

// --- one pulse channel; CH1 has the sweep unit, CH2 does not -----------------------------
module gb_apu_pulse #(
	parameter SWEEP = 0
) (
	input  wire       clk,
	input  wire       rst,
	input  wire       ce,          // T-cycle
	input  wire       apu_on,
	input  wire       power_off,   // pulse: NR52 bit 7 went low
	input  wire       fs_len,      // frame sequencer pulses
	input  wire       fs_env,
	input  wire       fs_sweep,
	input  wire       fs_odd,      // the NEXT frame-sequencer step will not clock length

	input  wire       we,
	input  wire [2:0] wsel,        // 0 NRx0 .. 4 NRx4
	input  wire [7:0] wd,
	output wire [7:0] q0, q1, q2, q3, q4,

	output reg        enabled,
	output wire       dac_on,
	output wire [3:0] dout
);
	reg [7:0] nr0, nr1, nr2, nr3, nr4;
	assign q0 = nr0; assign q1 = nr1; assign q2 = nr2; assign q3 = nr3; assign q4 = nr4;
	assign dac_on = (nr2[7:3] != 5'd0);

	wire [10:0] freq = {nr4[2:0], nr3};
	wire        len_en = nr4[6];

	reg [6:0]  len;                // 64 - what was written; 0 is expired
	reg [10:0] pcnt;               // the period counter, 1 MHz
	reg [1:0]  pre;                // T-cycles to 1 MHz
	reg [2:0]  duty_step;
	reg [3:0]  vol;
	reg [2:0]  env_t;
	reg        started;            // the first trigger has happened: the duty counter runs

	// sweep
	reg [10:0] shadow;
	reg [2:0]  sw_t;
	reg        sw_en;
	reg        sw_neg_used;

	function [11:0] sweep_calc;    // 12 bits: bit 11 is the overflow
		input [10:0] sh;
		input [2:0]  stp;
		input        neg;
		reg   [10:0] d;
		begin
			d = sh >> stp;
			sweep_calc = neg ? {1'b0, sh} - {1'b0, d} : {1'b0, sh} + {1'b0, d};
		end
	endfunction

	wire [11:0] sw_new  = sweep_calc(shadow, nr0[2:0], nr0[3]);
	wire [11:0] sw_new2 = sweep_calc(sw_new[10:0], nr0[2:0], nr0[3]);
	wire [11:0] sw_at_trig = sweep_calc(freq, nr0[2:0], nr0[3]);

	// the duty waveforms, read from the top bit down as the step advances
	reg duty_bit;
	always @(*) begin
		case (nr1[7:6])
			2'd0: duty_bit = (8'b00000001 >> (3'd7 - duty_step)) & 1'b1;
			2'd1: duty_bit = (8'b10000001 >> (3'd7 - duty_step)) & 1'b1;
			2'd2: duty_bit = (8'b10000111 >> (3'd7 - duty_step)) & 1'b1;
			default: duty_bit = (8'b01111110 >> (3'd7 - duty_step)) & 1'b1;
		endcase
	end
	assign dout = (enabled && duty_bit) ? vol : 4'd0;

	always @(posedge clk) begin
		if (rst || power_off) begin
			nr0 <= 8'd0; nr1 <= 8'd0; nr2 <= 8'd0; nr3 <= 8'd0; nr4 <= 8'd0;
			if (rst && SWEEP != 0) begin nr1 <= 8'h80; nr2 <= 8'hF3; end
			// what the boot ROM's chime leaves in channel 1: still on (NR52 reads $F1),
			// its envelope run down to 0
			enabled <= (rst && SWEEP != 0); vol <= 4'd0; env_t <= 3'd0; duty_step <= 3'd0; pcnt <= 11'd0; pre <= 2'd0;
			shadow <= 11'd0; sw_t <= 3'd0; sw_en <= 1'b0; sw_neg_used <= 1'b0; started <= 1'b0;
			if (rst) len <= 7'd0;
		end else begin
			// --- the period counter, at 1 MHz -----------------------------------------------
			if (ce) begin
				pre <= pre + 2'd1;
				if (pre == 2'd3 && started) begin
					if (pcnt == 11'h7FF) begin
						pcnt <= freq;
						duty_step <= duty_step + 3'd1;
					end else pcnt <= pcnt + 11'd1;
				end
			end

			// --- frame sequencer events ---------------------------------------------------------
			if (fs_len && len_en && len != 7'd0) begin
				len <= len - 7'd1;
				if (len == 7'd1) enabled <= 1'b0;
			end
			if (fs_env && nr2[2:0] != 3'd0) begin
				if (env_t == 3'd1) begin
					env_t <= nr2[2:0];
					if (nr2[3] && vol != 4'd15) vol <= vol + 4'd1;
					if (!nr2[3] && vol != 4'd0) vol <= vol - 4'd1;
				end else env_t <= (env_t == 3'd0) ? 3'd7 : env_t - 3'd1;
			end
			if (SWEEP != 0 && fs_sweep && sw_en && nr0[6:4] != 3'd0) begin
				if (sw_t == 3'd1) begin
					sw_t <= nr0[6:4];
					if (nr0[3]) sw_neg_used <= 1'b1;
					if (sw_new[11]) enabled <= 1'b0;
					else if (nr0[2:0] != 3'd0) begin
						shadow <= sw_new[10:0];
						nr3 <= sw_new[7:0];
						nr4[2:0] <= sw_new[10:8];
						if (sw_new2[11]) enabled <= 1'b0;
					end
				end else sw_t <= (sw_t == 3'd0) ? 3'd7 : sw_t - 3'd1;
			end

			// --- register writes --------------------------------------------------------------------
			if (we && (apu_on || wsel == 3'd1)) case (wsel)
				3'd0: begin
					if (SWEEP != 0) begin
						// clearing the direction after a subtraction has been used kills the channel
						if (nr0[3] && !wd[3] && sw_neg_used) enabled <= 1'b0;
						nr0 <= wd;
					end
				end
				3'd1: begin
					// the length counter is writable with the APU off (DMG), the duty is not
					if (apu_on) nr1 <= wd; else nr1[5:0] <= wd[5:0];
					len <= 7'd64 - {1'b0, wd[5:0]};
				end
				3'd2: begin
					nr2 <= wd;
					if (wd[7:3] == 5'd0) enabled <= 1'b0;             // DAC off
				end
				3'd3: nr3 <= wd;
				3'd4: begin
					nr4 <= wd;
					// enabling length on the odd half of the sequencer clocks it once more
					if (wd[6] && !nr4[6] && fs_odd && len != 7'd0) begin
						len <= len - 7'd1;
						if (len == 7'd1 && !wd[7]) enabled <= 1'b0;
					end
					if (wd[7]) begin                                     // trigger
						enabled <= (nr2[7:3] != 5'd0);
						started <= 1'b1;
						if (len == 7'd0) len <= (wd[6] && fs_odd) ? 7'd63 : 7'd64;
						pcnt <= {wd[2:0], nr3};
						env_t <= nr2[2:0];
						vol <= nr2[7:4];
						if (SWEEP != 0) begin
							shadow <= {wd[2:0], nr3};
							sw_t <= nr0[6:4];
							sw_en <= (nr0[6:4] != 3'd0) || (nr0[2:0] != 3'd0);
							sw_neg_used <= 1'b0;
							if (nr0[2:0] != 3'd0 && sw_at_trig[11]) enabled <= 1'b0;
						end
					end
				end
				default: ;
			endcase
		end
	end
endmodule

// --- the APU ---------------------------------------------------------------------------------------------
module gb_apu (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,            // T-cycle
	input  wire        fs_tick,       // one clock pulse at 512 Hz: DIV bit 4 fell

	input  wire [5:0]  reg_a,         // addr[5:0], $10-$3F
	input  wire        reg_we,        // one clock pulse
	input  wire [7:0]  reg_d,
	output reg  [7:0]  reg_q,

	output reg signed [15:0] audio_l,
	output reg signed [15:0] audio_r
);

	reg [7:0] nr50, nr51;
	reg       apu_on;
	wire      power_off = reg_we && reg_a == 6'h26 && !reg_d[7] && apu_on;

	// --- the frame sequencer ------------------------------------------------------------------
	reg [2:0] fs_step;
	wire fs_len   = fs_tick && apu_on && !fs_step[0];
	wire fs_sweep = fs_tick && apu_on && (fs_step == 3'd2 || fs_step == 3'd6);
	wire fs_env   = fs_tick && apu_on && (fs_step == 3'd7);
	// fs_step is the step the NEXT tick will perform; length clocks on even ones, so
	// an odd value means the next tick will not clock length (the NRx4 quirk).
	wire fs_odd   = fs_step[0];
	always @(posedge clk) begin
		if (rst || power_off) fs_step <= 3'd0;
		else if (fs_tick && apu_on) fs_step <= fs_step + 3'd1;
	end

	// --- channels 1 and 2 ---------------------------------------------------------------------------
	wire [7:0] c1q0, c1q1, c1q2, c1q3, c1q4, c2q0, c2q1, c2q2, c2q3, c2q4;
	wire       c1_en, c2_en, c1_dac, c2_dac;
	wire [3:0] c1_out, c2_out;

	gb_apu_pulse #(.SWEEP(1)) u_ch1 (
		.clk(clk), .rst(rst), .ce(ce), .apu_on(apu_on), .power_off(power_off),
		.fs_len(fs_len), .fs_env(fs_env), .fs_sweep(fs_sweep), .fs_odd(fs_odd),
		.we(reg_we && reg_a >= 6'h10 && reg_a <= 6'h14), .wsel(reg_a[2:0]), .wd(reg_d), // $10-$14
		.q0(c1q0), .q1(c1q1), .q2(c1q2), .q3(c1q3), .q4(c1q4),
		.enabled(c1_en), .dac_on(c1_dac), .dout(c1_out)
	);
	gb_apu_pulse #(.SWEEP(0)) u_ch2 (
		.clk(clk), .rst(rst), .ce(ce), .apu_on(apu_on), .power_off(power_off),
		.fs_len(fs_len), .fs_env(fs_env), .fs_sweep(1'b0), .fs_odd(fs_odd),
		.we(reg_we && reg_a >= 6'h15 && reg_a <= 6'h19), .wsel(reg_a[2:0] - 3'd5), .wd(reg_d), // $15-$19 ($15 is a hole)
		.q0(c2q0), .q1(c2q1), .q2(c2q2), .q3(c2q3), .q4(c2q4),
		.enabled(c2_en), .dac_on(c2_dac), .dout(c2_out)
	);

	// --- channel 3: wave ------------------------------------------------------------------------------
	reg [7:0]  nr30, nr31, nr32, nr33, nr34;
	reg [7:0]  wave [0:15];
	reg        c3_en;
	reg [8:0]  c3_len;               // 256 - n
	reg [10:0] c3_pcnt;
	reg        c3_pre;               // T-cycles to 2 MHz
	reg [4:0]  c3_pos;
	reg [7:0]  c3_buf;
	wire       c3_dac = nr30[7];
	wire [10:0] c3_freq = {nr34[2:0], nr33};
	wire [3:0] c3_nib = c3_pos[0] ? c3_buf[3:0] : c3_buf[7:4];
	wire [4:0] c3_pos_next = c3_pos + 5'd1;
	reg  [3:0] c3_out;
	always @(*) begin
		if (!c3_en) c3_out = 4'd0;
		else case (nr32[6:5])
			2'd0: c3_out = 4'd0;
			2'd1: c3_out = c3_nib;
			2'd2: c3_out = {1'b0, c3_nib[3:1]};
			default: c3_out = {2'b00, c3_nib[3:2]};
		endcase
	end

	// --- channel 4: noise -------------------------------------------------------------------------------
	reg [7:0]  nr41, nr42, nr43, nr44;
	reg        c4_en;
	reg [6:0]  c4_len;
	reg [3:0]  c4_vol;
	reg [2:0]  c4_env_t;
	reg [15:0] lfsr;
	reg [21:0] c4_cnt;               // T-cycles to the next LFSR clock
	wire       c4_dac = (nr42[7:3] != 5'd0);
	// 16 x divider x 2^shift T-cycles, with divider 0 counting as a half
	wire [4:0]  c4_shift  = {1'b0, nr43[7:4]} + 5'd4;
	wire [21:0] c4_period = (nr43[2:0] == 3'd0) ? (22'd8 << nr43[7:4]) : ({19'd0, nr43[2:0]} << c4_shift);
	wire [3:0]  c4_out = (c4_en && lfsr[0]) ? c4_vol : 4'd0;
	wire        lfsr_nb = ~(lfsr[0] ^ lfsr[1]);

	always @(posedge clk) begin
		if (rst || power_off) begin
			nr30 <= 8'd0; nr32 <= 8'd0; nr33 <= 8'd0; nr34 <= 8'd0;
			nr42 <= 8'd0; nr43 <= 8'd0; nr44 <= 8'd0;
			nr50 <= 8'd0; nr51 <= 8'd0;
			c3_en <= 1'b0; c3_pcnt <= 11'd0; c3_pre <= 1'b0; c3_pos <= 5'd0; c3_buf <= 8'd0;
			c4_en <= 1'b0; c4_vol <= 4'd0; c4_env_t <= 3'd0; lfsr <= 16'd0; c4_cnt <= 22'd0;
			if (rst) begin
				nr31 <= 8'd0; nr41 <= 8'd0; c3_len <= 9'd0; c4_len <= 7'd0;
				apu_on <= 1'b1; nr50 <= 8'h77; nr51 <= 8'hF3;
			end
			if (power_off) apu_on <= 1'b0;
		end else begin
			// --- channel 3 timing: 2 MHz ---------------------------------------------------------
			if (ce) begin
				c3_pre <= ~c3_pre;
				if (c3_pre && c3_en) begin
					if (c3_pcnt == 11'h7FF) begin
						c3_pcnt <= c3_freq;
						c3_pos <= c3_pos + 5'd1;
						c3_buf <= wave[c3_pos_next[4:1]];
					end else c3_pcnt <= c3_pcnt + 11'd1;
				end
				// --- channel 4 timing ----------------------------------------------------------------
				if (c4_en && nr43[7:4] < 4'd14) begin
					if (c4_cnt <= 22'd1) begin
						c4_cnt <= c4_period;
						// bit 15 takes the XNOR of bits 0 and 1 (bit 7 too in short mode), then
						// everything shifts right one
						lfsr <= {1'b0, lfsr_nb, lfsr[14:8], nr43[3] ? lfsr_nb : lfsr[7], lfsr[6:1]};
					end else c4_cnt <= c4_cnt - 22'd1;
				end
			end

			// --- frame sequencer events -----------------------------------------------------------------
			if (fs_len) begin
				if (nr34[6] && c3_len != 9'd0) begin
					c3_len <= c3_len - 9'd1;
					if (c3_len == 9'd1) c3_en <= 1'b0;
				end
				if (nr44[6] && c4_len != 7'd0) begin
					c4_len <= c4_len - 7'd1;
					if (c4_len == 7'd1) c4_en <= 1'b0;
				end
			end
			if (fs_env && nr42[2:0] != 3'd0) begin
				if (c4_env_t == 3'd1) begin
					c4_env_t <= nr42[2:0];
					if (nr42[3] && c4_vol != 4'd15) c4_vol <= c4_vol + 4'd1;
					if (!nr42[3] && c4_vol != 4'd0) c4_vol <= c4_vol - 4'd1;
				end else c4_env_t <= (c4_env_t == 3'd0) ? 3'd7 : c4_env_t - 3'd1;
			end

			// --- register writes --------------------------------------------------------------------------
			if (reg_we) begin
				if (reg_a == 6'h26) apu_on <= reg_d[7];
				if (reg_a[5:4] == 2'b11) begin                                   // wave RAM $30-$3F
					if (!c3_en) wave[reg_a[3:0]] <= reg_d;
				end else if (apu_on) case (reg_a)
					6'h1A: begin nr30 <= reg_d; if (!reg_d[7]) c3_en <= 1'b0; end
					6'h1B: begin nr31 <= reg_d; c3_len <= 9'd256 - {1'b0, reg_d}; end
					6'h1C: nr32 <= reg_d;
					6'h1D: nr33 <= reg_d;
					6'h1E: begin
						nr34 <= reg_d;
						if (reg_d[6] && !nr34[6] && fs_odd && c3_len != 9'd0) begin
							c3_len <= c3_len - 9'd1;
							if (c3_len == 9'd1 && !reg_d[7]) c3_en <= 1'b0;
						end
						if (reg_d[7]) begin
							c3_en <= nr30[7];
							if (c3_len == 9'd0) c3_len <= (reg_d[6] && fs_odd) ? 9'd255 : 9'd256;
							c3_pcnt <= {reg_d[2:0], nr33};
							c3_pos <= 5'd0;
						end
					end
					6'h20: begin nr41 <= reg_d; c4_len <= 7'd64 - {1'b0, reg_d[5:0]}; end
					6'h21: begin nr42 <= reg_d; if (reg_d[7:3] == 5'd0) c4_en <= 1'b0; end
					6'h22: nr43 <= reg_d;
					6'h23: begin
						nr44 <= reg_d;
						if (reg_d[6] && !nr44[6] && fs_odd && c4_len != 7'd0) begin
							c4_len <= c4_len - 7'd1;
							if (c4_len == 7'd1 && !reg_d[7]) c4_en <= 1'b0;
						end
						if (reg_d[7]) begin
							c4_en <= (nr42[7:3] != 5'd0);
							if (c4_len == 7'd0) c4_len <= (reg_d[6] && fs_odd) ? 7'd63 : 7'd64;
							c4_env_t <= nr42[2:0];
							c4_vol <= nr42[7:4];
							lfsr <= 16'd0;
							c4_cnt <= c4_period;
						end
					end
					6'h24: nr50 <= reg_d;
					6'h25: nr51 <= reg_d;
					default: ;
				endcase
				// the length counters take writes with the APU off, on the DMG
				else case (reg_a)
					6'h1B: begin nr31 <= reg_d; c3_len <= 9'd256 - {1'b0, reg_d}; end
					6'h20: begin nr41[5:0] <= reg_d[5:0]; c4_len <= 7'd64 - {1'b0, reg_d[5:0]}; end
					default: ;
				endcase
			end
		end
	end

	// --- the mixer --------------------------------------------------------------------------------------------
	// DAC: digital 0..15 to +15..-15 (yes, falling); a DAC that is off gives 0.
	function signed [5:0] dac;
		input       on;
		input [3:0] d;
		begin
			dac = on ? (6'sd15 - $signed({1'b0, d, 1'b0})) : 6'sd0;
		end
	endfunction
	wire signed [5:0] a1 = dac(c1_dac, c1_out);
	wire signed [5:0] a2 = dac(c2_dac, c2_out);
	wire signed [5:0] a3 = dac(c3_dac, c3_out);
	wire signed [5:0] a4 = dac(c4_dac, c4_out);
	wire signed [7:0] sum_l = (nr51[4] ? a1 : 6'sd0) + (nr51[5] ? a2 : 6'sd0) + (nr51[6] ? a3 : 6'sd0) + (nr51[7] ? a4 : 6'sd0);
	wire signed [7:0] sum_r = (nr51[0] ? a1 : 6'sd0) + (nr51[1] ? a2 : 6'sd0) + (nr51[2] ? a3 : 6'sd0) + (nr51[3] ? a4 : 6'sd0);
	wire signed [4:0] vol_l = {1'b0, nr50[6:4]} + 5'sd1;
	wire signed [4:0] vol_r = {1'b0, nr50[2:0]} + 5'sd1;
	wire signed [12:0] mix_l = sum_l * vol_l;      // +-480
	wire signed [12:0] mix_r = sum_r * vol_r;
	wire signed [15:0] mix_l16 = mix_l;
	wire signed [15:0] mix_r16 = mix_r;
	always @(posedge clk) begin
		if (rst) begin audio_l <= 16'sd0; audio_r <= 16'sd0; end
		else if (ce) begin
			// x64: +-30720, most of the 16-bit range with a little headroom
			audio_l <= apu_on ? (mix_l16 <<< 6) : 16'sd0;
			audio_r <= apu_on ? (mix_r16 <<< 6) : 16'sd0;
		end
	end

	// --- register reads ------------------------------------------------------------------------------------
	always @(*) begin
		case (reg_a)
			6'h10: reg_q = c1q0 | 8'h80;
			6'h11: reg_q = c1q1 | 8'h3F;
			6'h12: reg_q = c1q2;
			6'h13: reg_q = 8'hFF;
			6'h14: reg_q = c1q4 | 8'hBF;
			6'h16: reg_q = c2q1 | 8'h3F;
			6'h17: reg_q = c2q2;
			6'h18: reg_q = 8'hFF;
			6'h19: reg_q = c2q4 | 8'hBF;
			6'h1A: reg_q = nr30 | 8'h7F;
			6'h1B: reg_q = 8'hFF;
			6'h1C: reg_q = nr32 | 8'h9F;
			6'h1D: reg_q = 8'hFF;
			6'h1E: reg_q = nr34 | 8'hBF;
			6'h20: reg_q = 8'hFF;
			6'h21: reg_q = nr42;
			6'h22: reg_q = nr43;
			6'h23: reg_q = nr44 | 8'hBF;
			6'h24: reg_q = nr50;
			6'h25: reg_q = nr51;
			6'h26: reg_q = {apu_on, 3'b111, c4_en, c3_en, c2_en, c1_en};
			default: begin
				if (reg_a[5:4] == 2'b11) reg_q = c3_en ? 8'hFF : wave[reg_a[3:0]];
				else reg_q = 8'hFF;
			end
		endcase
	end

endmodule
