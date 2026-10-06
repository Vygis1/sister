//////////////////////////////////////////////////////////////////////////////////
// snes_dsp.v - the SNES's sound chip (S-DSP): eight BRR voices with Gaussian interpolation,
// ADSR / GAIN envelopes, pitch modulation, noise, the echo and its 8-tap FIR, the mixer.
//
// One sample per `sample` pulse (every 32 SPC700 cycles, 32 kHz), worked out step by step
// in the order of the model tools/snes/dsp.py -- sim/tb_snes_dsp.v replays what the model
// was told (tools/snes/dsprec.py) and compares every sample, and ENVX / OUTX / ENDX.
// A sample takes ~1200 clocks of a 50 MHz clock; there are ~1560 between pulses.
//
// The registers are the 128-byte array the chip has (the SPC700 reads and writes it
// through $F2 / $F3); ENVX, OUTX and ENDX are written back by the chip each sample.
// The 64 kB of sound RAM is outside: a read port (address, data a clock later) and a
// write port for the echo.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_dsp (
	input  wire        clk,
	input  wire        rst,
	input  wire        sample,         // work out the next sample
	// the SPC700's $F2 / $F3
	input  wire        r_we,
	input  wire [6:0]  r_addr,
	input  wire [7:0]  r_wdata,
	output wire [7:0]  r_rdata,
	// sound RAM
	output reg  [15:0] ram_a,
	input  wire [7:0]  ram_q,
	output reg         ram_we,
	output reg  [7:0]  ram_wd,
	// out
	output reg  signed [15:0] out_l,
	output reg  signed [15:0] out_r,
	output reg         out_stb
);
	// --- the register array ----------------------------------------------------------------
	reg [7:0] R [0:127];
	assign r_rdata = R[r_addr];
	reg [7:0] new_kon;

	// --- per voice --------------------------------------------------------------------------
	reg [10:0] env    [0:7];
	reg [10:0] hidden [0:7];
	reg [1:0]  vmode  [0:7];             // 0 attack 1 decay 2 sustain 3 release
	reg [2:0]  kdel   [0:7];
	reg [15:0] baddr  [0:7];
	reg [3:0]  boff   [0:7];
	reg [3:0]  bpos   [0:7];
	reg [14:0] vpos   [0:7];
	reg signed [15:0] buf_ [0:95];       // 12 decoded samples a voice (15-bit values)
	localparam ATTACK = 2'd0, DECAY = 2'd1, SUSTAIN = 2'd2, RELEASE = 2'd3;

	// --- the Gauss table (Fullsnes) ---------------------------------------------------------
	`include "snes_gauss.vh"

	// --- shared state -------------------------------------------------------------------------
	reg [15:0] counter;
	reg [14:0] noise;
	reg [7:0]  kon;
	reg        every_other;
	reg [14:0] echo_idx, echo_len;
	reg signed [15:0] fir_l [0:7], fir_r [0:7];
	reg [2:0]  fir_i;

	// --- rates: (counter + offset) % period == 0, periods 1 / 3 / 5 times a power of two ------
	// rate r (1..31): period = k << n with (k, n) by r; offset by r's kind
	function fires;
		input [15:0] cnt; input [4:0] r;
		reg [15:0] v, q; reg [3:0] n; reg [2:0] k;
		begin
			// period = k << n (k 1, 3 or 5); offset by r's kind
			case (r)
			5'd28: begin k = 1; n = 2; end
			5'd29: begin k = 3; n = 0; end
			5'd30: begin k = 1; n = 1; end
			5'd31: begin k = 1; n = 0; end
			default: case ((r - 5'd1) % 3)
				0: begin k = 1; n = 4'd11 - (r - 5'd1) / 3; end
				1: begin k = 3; n = 4'd9 - (r - 5'd1) / 3; end
				default: begin k = 5; n = 4'd8 - (r - 5'd1) / 3; end
				endcase
			endcase
			case ((r - 5'd1) % 3)
			0: v = cnt;
			1: v = cnt + 16'd1040;
			default: v = cnt + 16'd536;
			endcase
			q = v >> n;
			if (r == 5'd0) fires = 1'b0;
			else fires = ((v & ((16'd1 << n) - 16'd1)) == 16'd0) &&
			             (k == 3'd1 ? 1'b1 : k == 3'd3 ? (q % 3 == 0) : (q % 5 == 0));
		end
	endfunction

	// (32 bits in: the products here are 24 bits, and an expression is sized by where it goes)
	function signed [15:0] clamp16;
		input signed [31:0] v;
		clamp16 = (v > 32'sd32767) ? 16'sd32767 : (v < -32'sd32768) ? -16'sd32768 : v[15:0];
	endfunction

	// --- the work -------------------------------------------------------------------------------
	localparam [4:0]
		W_IDLE = 5'd0, W_START = 5'd1, W_VOICE = 5'd2, W_DIR0 = 5'd3, W_DIR1 = 5'd4, W_DIR2 = 5'd5,
		W_DEC0 = 5'd6, W_DEC1 = 5'd7, W_DEC2 = 5'd8, W_DEC3 = 5'd9, W_DECN = 5'd10,
		W_INT = 5'd11, W_ENV = 5'd12, W_PITCH = 5'd13, W_MIX = 5'd14, W_NEXT = 5'd15,
		W_ECHO0 = 5'd16, W_ECHO1 = 5'd17, W_FIR = 5'd18, W_EOUT = 5'd19, W_EWR = 5'd20, W_END = 5'd21,
		W_BLK0 = 5'd22, W_BLK1 = 5'd23, W_BLK2 = 5'd24;
	reg [4:0]  ws;
	reg [4:0]  wret;                    // where a decode returns
	reg [2:0]  x;                       // the voice
	reg        kphase;                  // this sample takes KON / KOFF
	reg [7:0]  koff;
	reg signed [15:0] prev_out, vout;
	reg signed [31:0] main_l, main_r, echo_l, echo_r;
	reg [7:0]  hdr;
	reg [7:0]  db0, db1;
	reg [2:0]  dk;                      // nibble within the decode
	reg [1:0]  ik;                      // interpolation tap
	reg signed [31:0] iacc;
	reg [15:0] eaddr;
	reg [2:0]  ek;
	reg signed [15:0] echo_in_l, echo_in_r;
	reg [15:0] ew;
	reg signed [15:0] fl, fr;
	reg [3:0]  bufidx;

	wire signed [15:0] noise15 = {noise[14], noise};
	wire [6:0] vb = {x, 4'h0};

	integer i;
	reg signed [31:0] s20, p1, p2;
	reg signed [31:0] m32;
	reg [3:0] nib;
	reg [3:0] shift_;
	reg [1:0] filt;
	reg [7:0] gi;
	reg [3:0] tap;
	reg signed [15:0] s16v;
	reg [13:0] step;
	reg [15:0] pstep;
	reg [4:0] rate;
	reg signed [12:0] estep;
	reg signed [12:0] e13;
	reg [10:0] e11;
	reg [7:0] a1, a2, g;
	reg signed [31:0] acc20;
	reg signed [15:0] t16;
	reg [7:0] endx;

	always @(posedge clk) begin
		out_stb <= 1'b0;
		ram_we <= 1'b0;
		if (rst) begin
			for (i = 0; i < 128; i = i + 1) R[i] <= 8'h00;
			R[7'h6C] <= 8'hE0;
			for (i = 0; i < 8; i = i + 1) begin
				env[i] <= 0; hidden[i] <= 0; vmode[i] <= RELEASE; kdel[i] <= 0; baddr[i] <= 0; boff[i] <= 1;
				bpos[i] <= 0; vpos[i] <= 0; fir_l[i] <= 0; fir_r[i] <= 0;
			end
			for (i = 0; i < 96; i = i + 1) buf_[i] <= 16'sd0;
			counter <= 16'd0; noise <= 15'h4000; kon <= 8'h00; new_kon <= 8'h00; every_other <= 1'b0;
			echo_idx <= 0; echo_len <= 0; fir_i <= 0; ws <= W_IDLE;
		end else begin
			// the SPC700's writes (any write to ENDX clears it)
			if (r_we) begin
				R[r_addr] <= (r_addr == 7'h7C) ? 8'h00 : r_wdata;
				if (r_addr == 7'h4C) new_kon <= r_wdata;
			end

			case (ws)
			W_IDLE: if (sample) ws <= W_START;
			W_START: begin
				counter <= (counter == 16'd0) ? 16'h77FF : counter - 16'd1;
				if (fires((counter == 16'd0) ? 16'h77FF : counter - 16'd1, R[7'h6C][4:0]))
					noise <= {noise[0] ^ noise[1], noise[14:1]};
				every_other <= !every_other;
				kphase <= !every_other;
				if (!every_other) begin kon <= new_kon; new_kon <= 8'h00; koff <= R[7'h5C]; end
				main_l <= 0; main_r <= 0; echo_l <= 0; echo_r <= 0; prev_out <= 0;
				x <= 3'd0;
				ws <= W_VOICE;
			end

			// ---------- a voice ----------
			W_VOICE: begin
				if (kphase && kon[x]) begin
					// key on: the start address from the directory
					kdel[x] <= 3'd5; vmode[x] <= ATTACK; env[x] <= 0; hidden[x] <= 0;
					vpos[x] <= 0; bpos[x] <= 0;
					for (i = 0; i < 12; i = i + 1) buf_[x * 12 + i] <= 16'sd0;
					R[7'h7C][x] <= 1'b0;
					ram_a <= {R[7'h5D], 8'h00} + {6'd0, R[vb | 7'h4], 2'b00};
					ws <= W_DIR0;
				end else ws <= W_DIR2;
			end
			W_DIR0: begin ram_a <= ram_a + 16'd1; ws <= W_DIR1; end
			W_DIR1: begin baddr[x][7:0] <= ram_q; ws <= W_BLK0; end
			W_BLK0: begin baddr[x][15:8] <= ram_q; boff[x] <= 4'd1; ws <= W_DIR2; end
			W_DIR2: begin
				// key off; FLG's soft reset
				if (kphase && koff[x]) vmode[x] <= RELEASE;
				if (R[7'h6C][7]) begin vmode[x] <= RELEASE; env[x] <= 11'd0; end
				if (kdel[x] != 3'd0) begin
					kdel[x] <= kdel[x] - 3'd1;
					vout <= 16'sd0; vpos[x] <= 15'd0;
					if (kdel[x] == 3'd4 || kdel[x] == 3'd3 || kdel[x] == 3'd2) begin wret <= W_MIX; ws <= W_DEC0; end
					else ws <= W_MIX;
				end else begin
					ik <= 2'd0; iacc <= 20'sd0;
					ws <= W_INT;
				end
			end

			// ---------- the Gauss interpolation (or the noise) ----------
			W_INT: begin
				gi = vpos[x][11:4];
				tap = bpos[x] + {1'b0, vpos[x][14:12]} + {2'b0, ik};
				if (tap >= 4'd12) tap = tap - 4'd12;
				if (tap >= 4'd12) tap = tap - 4'd12;
				s16v = buf_[x * 12 + tap];
				case (ik)
				2'd0: m32 = $signed({1'b0, gauss_rom(9'h0FF - {1'b0, gi})}) * s16v;
				2'd1: m32 = $signed({1'b0, gauss_rom(9'h1FF - {1'b0, gi})}) * s16v;
				2'd2: m32 = $signed({1'b0, gauss_rom(9'h100 + {1'b0, gi})}) * s16v;
				default: m32 = $signed({1'b0, gauss_rom({1'b0, gi})}) * s16v;
				endcase
				case (ik)
				2'd0, 2'd1: iacc <= iacc + (m32 >>> 10);
				2'd2: begin acc20 = iacc + (m32 >>> 10); iacc <= {{16{acc20[15]}}, acc20[15:0]}; end   // wraps
				default: begin
					acc20 = iacc + (m32 >>> 10);
					t16 = clamp16(acc20);
					// out = the 15-bit sample times the envelope
					s16v = R[7'h3D][x] ? noise15 : (t16 >>> 1);
					m32 = s16v * $signed({1'b0, env[x]});
					vout <= (m32 >>> 11) & ~32'sd1;
				end
				endcase
				ik <= ik + 2'd1;
				if (ik == 2'd3) ws <= W_ENV;
			end

			// ---------- the envelope ----------
			W_ENV: begin
				a1 = R[vb | 7'h5]; a2 = R[vb | 7'h6]; g = R[vb | 7'h7];
				e13 = {2'b00, env[x]};
				if (vmode[x] == RELEASE) begin
					e13 = e13 - 13'sd8;
					env[x] <= (e13 < 0) ? 11'd0 : e13[10:0];
				end else begin
					rate = 5'd0; estep = 13'sd0;
					if (a1[7]) begin
						case (vmode[x])
						ATTACK: begin rate = {a1[3:0], 1'b1}; estep = (rate == 5'd31) ? 13'sd1024 : 13'sd32; end
						DECAY:  begin rate = {2'b10, a1[6:4]} << 1; rate = {1'b1, a1[6:4], 1'b0}; estep = -($signed({2'b00, env[x]} - 13'sd1) >>> 8) - 13'sd1; end
						default: begin rate = a2[4:0]; estep = -($signed({2'b00, env[x]} - 13'sd1) >>> 8) - 13'sd1; end
						endcase
					end else if (!g[7]) begin
						env[x] <= {g[6:0], 4'd0}; hidden[x] <= {g[6:0], 4'd0};
						e13 = {2'b00, g[6:0], 4'd0};
					end else begin
						rate = g[4:0];
						case (g[6:5])
						2'd0: estep = -13'sd32;
						2'd1: estep = -($signed({2'b00, env[x]} - 13'sd1) >>> 8) - 13'sd1;
						2'd2: estep = 13'sd32;
						default: estep = (hidden[x] < 11'h600) ? 13'sd32 : 13'sd8;
						endcase
					end
					if (vmode[x] == DECAY && e13[10:8] == (a1[7] ? a2[7:5] : g[7:5])) vmode[x] <= SUSTAIN;
					if (fires(counter, rate)) begin
						e13 = e13 + estep;
						hidden[x] <= e13[10:0];
						e11 = (e13 < 0) ? 11'd0 : (e13 > 13'sd2047) ? 11'h7FF : e13[10:0];
						env[x] <= e11;
						if (vmode[x] == ATTACK && e11 >= 11'h7E0) vmode[x] <= DECAY;
					end else if (vmode[x] == ATTACK && e13 >= 13'sd2016) vmode[x] <= DECAY;
				end
				ws <= W_PITCH;
			end

			// ---------- the pitch ----------
			W_PITCH: begin
				step = {R[vb | 7'h3][5:0], R[vb | 7'h2]};
				if (R[7'h2D][x] && x != 3'd0) begin
					m32 = $signed({18'd0, step}) * $signed((prev_out >>> 4) + 16'sd1024);
					step = m32[23:10];
					pstep = m32[25:10];
				end else pstep = {2'b00, step};
				if ({1'b0, vpos[x]} + pstep > 17'h7FFF) vpos[x] <= 15'h7FFF;
				else vpos[x] <= vpos[x] + pstep[14:0];
				if (({1'b0, vpos[x]} + pstep) >= 17'h4000) begin
					// (the new position, less 4000h, after the decode)
					wret <= W_MIX; ws <= W_DEC0;
				end else ws <= W_MIX;
			end

			// ---------- four more BRR samples ----------
			W_DEC0: begin ram_a <= baddr[x]; ws <= W_DEC1; end
			W_DEC1: begin ram_a <= baddr[x] + {12'd0, boff[x]}; ws <= W_DEC2; end
			W_DEC2: begin hdr <= ram_q; ram_a <= baddr[x] + {12'd0, boff[x]} + 16'd1; ws <= W_DEC3; end
			W_DEC3: begin db0 <= ram_q; ws <= W_DECN; dk <= 3'd0; end
			W_DECN: begin
				if (dk == 3'd0) db1 <= ram_q;
				nib = (dk == 3'd0) ? db0[7:4] : (dk == 3'd1) ? db0[3:0] : (dk == 3'd2) ? ram_q[7:4] : db1[3:0];
				if (dk == 3'd2) nib = db1[7:4];
				if (dk == 3'd0) nib = db0[7:4];
				shift_ = hdr[7:4]; filt = hdr[3:2];
				s20 = $signed({{28{nib[3]}}, nib});
				if (shift_ <= 4'd12) s20 = (s20 <<< shift_) >>> 1;
				else s20 = nib[3] ? -20'sd2048 : 20'sd0;
				bufidx = (bpos[x] == 4'd0) ? 4'd11 : bpos[x] - 4'd1;
				p1 = buf_[x * 12 + bufidx];
				bufidx = (bpos[x] == 4'd0) ? 4'd10 : (bpos[x] == 4'd1) ? 4'd11 : bpos[x] - 4'd2;
				p2 = buf_[x * 12 + bufidx];
				case (filt)
				2'd1: s20 = s20 + p1 + ((-p1) >>> 4);
				2'd2: s20 = s20 + (p1 <<< 1) + ((-(p1 * 3)) >>> 5) - p2 + (p2 >>> 4);
				2'd3: s20 = s20 + (p1 <<< 1) + ((-(p1 * 13)) >>> 6) - p2 + ((p2 * 3) >>> 4);
				default: ;
				endcase
				t16 = clamp16(s20);
				buf_[x * 12 + bpos[x]] <= {t16[14], t16[14:0]};         // (15 bits: bit 15 lost)
				bpos[x] <= (bpos[x] == 4'd11) ? 4'd0 : bpos[x] + 4'd1;
				dk <= dk + 3'd1;
				if (dk == 3'd3) begin
					boff[x] <= boff[x] + 4'd2;
					if (boff[x] + 4'd2 > 4'd8) begin
						boff[x] <= 4'd1;
						if (hdr[0]) begin
							R[7'h7C][x] <= 1'b1;
							ram_a <= {R[7'h5D], 8'h00} + {6'd0, R[vb | 7'h4], 2'b00} + 16'd2;
							if (!hdr[1]) begin vmode[x] <= RELEASE; env[x] <= 11'd0; end
							ws <= W_BLK1;
						end else begin baddr[x] <= baddr[x] + 16'd9; ws <= wret; end
					end else ws <= wret;
					if (wret == W_MIX && kdel[x] == 3'd0) vpos[x] <= vpos[x] - 15'h4000;
				end
			end
			W_BLK1: begin ram_a <= ram_a + 16'd1; ws <= W_BLK2; end
			W_BLK2: begin baddr[x][7:0] <= ram_q; ws <= W_BLK0 + 5'd0; wret <= wret; ws <= 5'd25; end
			5'd25:  begin baddr[x][15:8] <= ram_q; ws <= wret; end

			// ---------- this voice's output, the mixes ----------
			W_MIX: begin
				prev_out <= vout;
				R[vb | 7'h8] <= {1'b0, env[x][10:4]};
				R[vb | 7'h9] <= vout[14:7];
				m32 = vout * $signed(R[vb | 7'h0]);
				main_l <= clamp16(main_l + (m32 >>> 6));
				if (R[7'h4D][x]) echo_l <= clamp16(echo_l + (m32 >>> 6));
				m32 = vout * $signed(R[vb | 7'h1]);
				main_r <= clamp16(main_r + (m32 >>> 6));
				if (R[7'h4D][x]) echo_r <= clamp16(echo_r + (m32 >>> 6));
				x <= x + 3'd1;
				if (x == 3'd7) begin
					if (kphase) kon <= 8'h00;
					eaddr <= {R[7'h6D], 8'h00} + {echo_idx[13:0], 2'b00};
					ek <= 3'd0;
					ws <= W_ECHO0;
				end else ws <= W_VOICE;
			end

			// ---------- the echo ----------
			W_ECHO0: begin ram_a <= eaddr; ek <= 3'd0; fir_i <= fir_i + 3'd1; ws <= W_ECHO1; end
			W_ECHO1: begin
				// four bytes: left lo, hi, right lo, hi
				ram_a <= eaddr + {13'd0, ek} + 16'd1;
				if (ek != 3'd0) begin
					case (ek)
					3'd1: ew[7:0] <= ram_q;
					3'd2: fir_l[fir_i] <= $signed({ram_q, ew[7:0]}) >>> 1;
					3'd3: ew[7:0] <= ram_q;
					default: ;
					endcase
				end
				if (ek == 3'd4) begin fir_r[fir_i] <= $signed({ram_q, ew[7:0]}) >>> 1; ws <= W_FIR; end
				ek <= ek + 3'd1;
			end
			W_FIR: begin : fir
				reg signed [31:0] al, ar; integer k; reg [2:0] fk;
				al = 0; ar = 0;
				for (k = 0; k < 7; k = k + 1) begin
					fk = fir_i + 3'd1 + k[2:0];          // (fir_i - 7 + k, mod 8)
					al = al + ((fir_l[fk] * $signed(R[{k[2:0], 4'hF}])) >>> 6);
					ar = ar + ((fir_r[fk] * $signed(R[{k[2:0], 4'hF}])) >>> 6);
				end
				al = {{16{al[15]}}, al[15:0]};
				ar = {{16{ar[15]}}, ar[15:0]};
				fl <= clamp16(al + ((fir_l[fir_i] * $signed(R[7'h7F])) >>> 6));
				fr <= clamp16(ar + ((fir_r[fir_i] * $signed(R[7'h7F])) >>> 6));
				ws <= W_EOUT;
			end
			W_EOUT: begin
				out_l <= R[7'h6C][6] ? 16'sd0 : clamp16((($signed(main_l[15:0]) * $signed(R[7'h0C])) >>> 7) + ((fl * $signed(R[7'h2C])) >>> 7));
				out_r <= R[7'h6C][6] ? 16'sd0 : clamp16((($signed(main_r[15:0]) * $signed(R[7'h1C])) >>> 7) + ((fr * $signed(R[7'h3C])) >>> 7));
				out_stb <= 1'b1;
				t16 = clamp16(echo_l + ((fl * $signed(R[7'h0D])) >>> 7));
				echo_in_l <= t16 & ~16'sd1;
				t16 = clamp16(echo_r + ((fr * $signed(R[7'h0D])) >>> 7));
				echo_in_r <= t16 & ~16'sd1;
				ek <= 3'd0;
				ws <= W_EWR;
			end
			W_EWR: begin
				if (!R[7'h6C][5]) begin
					ram_we <= 1'b1;
					ram_a <= eaddr + {13'd0, ek};
					case (ek[1:0])
					2'd0: ram_wd <= echo_in_l[7:0];
					2'd1: ram_wd <= echo_in_l[15:8];
					2'd2: ram_wd <= echo_in_r[7:0];
					default: ram_wd <= echo_in_r[15:8];
					endcase
				end
				ek <= ek + 3'd1;
				if (ek == 3'd3) ws <= W_END;
			end
			W_END: begin
				if (echo_idx == 15'd0) echo_len <= {R[7'h7D][3:0], 9'd0} ;
				if (echo_idx + 15'd1 >= ((echo_idx == 15'd0) ? {2'd0, R[7'h7D][3:0], 9'd0} : echo_len)) echo_idx <= 15'd0;
				else echo_idx <= echo_idx + 15'd1;
				ws <= W_IDLE;
			end
			default: ws <= W_IDLE;
			endcase
		end
	end
endmodule
