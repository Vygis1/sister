`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ym2612.v - the chip that makes a Mega Drive sound like a Mega Drive.
//
// Six channels of four-operator FM. An operator is a sine oscillator with an
// envelope on its output; what makes it FM is that one operator's output is
// added to another's PHASE rather than to its amplitude, so it bends the second
// one's pitch thousands of times a second and the ear hears a timbre instead of
// a vibrato. Eight "algorithms" say which operators feed which.
//
// --- the shape of this implementation ---------------------------------------------
//
// Twenty-four operators, ONE datapath. The chip's own sample rate is the master
// clock over 144, and at the rate this fabric runs there are far more than 24
// clocks between samples -- so each operator is computed in its own slot, in
// turn, out of a register file. That is the same arrangement rtl/synth.v uses
// for its eight voices, and for the same reason: adding operators costs clocks,
// which are plentiful, rather than logic, which is not.
//
// --- the register interface ---------------------------------------------------------
//
// Four addresses, in two pairs. Channels 1 to 3 are reached through the first
// pair and channels 4 to 6 through the second, which is why the register map
// only ever describes three channels: there are two copies of nearly everything.
//
//   $4000  address, part 1        $4002  address, part 2
//   $4001  data, part 1           $4003  data, part 2
//
// Reading any of the four gives the status: the two timer flags, and a busy bit
// that a driver waits on after every write.
//
// Operators inside a channel are numbered 1, 2, 3, 4 in the documentation but
// appear in the register map in the order 1, 3, 2, 4. That is not a mistake in
// anybody's notes -- the silicon really is laid out that way, and a driver
// written against the manual expects it.
//
// --- the logarithmic domain -----------------------------------------------------------
//
// The one thing to understand about this chip is that its arithmetic is in
// decibels, not in amplitudes. A sine lookup does not return a sine: it returns
// how far DOWN from full scale that point of a sine is. The envelope is also an
// attenuation. So applying an envelope to an oscillator is an ADD, and the only
// conversion back to a linear number happens once, at the very end, through an
// exponential table. Both tables are in rtl/ym_tables.vh, generated from their
// definitions by tools/ymtables.py.
//
// --- what is exact here, and what is not ------------------------------------------------
//
// The tables, the phase generator, the algorithms and the shape of the envelope
// are as the chip specifies them. Three things are NOT verified, and are written
// down here rather than left to be discovered:
//
//   - The envelope's rate table. Its structure is right -- a shift chosen by the
//     rate and one of four increment patterns -- but the exact steps want
//     checking against a recording from real hardware, which needs a powered
//     board.
//   - Operators are computed in the order 1, 2, 3, 4 within a channel, each
//     modulating the next from the value just calculated. The real chip runs
//     them as 1, 3, 2, 4 with a one-sample delay on some paths, which changes
//     the timbre slightly on the algorithms that feed backwards.
//   - Detune and the LFO are not implemented. Both are audible; neither stops a
//     driver from working.
//
// None of these stops a sound driver from running. All three would be audible to
// somebody who knows the tune.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ym2612 (
	input  wire        clk,
	input  wire        rst,
	// One enable per FM sample period. The real part divides its master clock by
	// 144; what matters here is that it is SLOW ENOUGH -- at least 96 clocks
	// between enables, four for each of the twenty-four operators. A faster
	// enable restarts the pass before it finishes, and the chip goes silent
	// without complaining about anything.
	input  wire        ce,

	// --- the register ports -------------------------------------------------------
	input  wire        cs,           // an access is happening this cycle
	input  wire [1:0]  a,            // which of the four addresses
	input  wire        wr,
	input  wire [7:0]  din,
	output wire [7:0]  dout,

	// --- what comes out ------------------------------------------------------------
	output wire signed [15:0] left,
	output wire signed [15:0] right,

	// --- for a testbench to look at --------------------------------------------------
	output wire        dbg_timer_a,
	output wire        dbg_timer_b,
	output wire [5:0]  dbg_keyon
);

	// --- the register file ------------------------------------------------------------
	// Per-operator parameters live in one array of 24, indexed the way the slots
	// are computed rather than the way they are written. Per-channel ones live in
	// six.
	//
	// The register address carries the channel in its low two bits and the
	// operator slot in the next two, and a value of 3 in the channel field is not
	// a channel at all. Unpacking that here, once, is what keeps the arithmetic
	// out of the audio path.
	reg [6:0]  op_tl   [0:23];      // total level: how loud, inverted
	reg [4:0]  op_ar   [0:23];      // attack rate
	reg [4:0]  op_d1r  [0:23];      // first decay
	reg [4:0]  op_d2r  [0:23];      // second decay, the sustain slope
	reg [3:0]  op_rr   [0:23];      // release
	reg [3:0]  op_d1l  [0:23];      // the level the first decay stops at
	reg [1:0]  op_ks   [0:23];      // rate scaling by pitch
	reg [3:0]  op_mul  [0:23];      // frequency multiple
	reg [2:0]  op_dt   [0:23];      // detune
	reg        op_am   [0:23];      // does the LFO reach its amplitude

	reg [10:0] ch_fnum [0:5];
	reg [2:0]  ch_block[0:5];
	reg [2:0]  ch_alg  [0:5];
	reg [2:0]  ch_fb   [0:5];
	reg        ch_l    [0:5];
	reg        ch_r    [0:5];
	reg [2:0]  ch_ams  [0:5];
	reg [2:0]  ch_pms  [0:5];

	reg [3:0]  ch_keyon[0:5];       // one bit per operator

	// The latched half of a two-byte write. Each port has its own, because a
	// driver interleaves writes to the two of them.
	reg [7:0] addr_lo, addr_hi;

	// --- global registers ---------------------------------------------------------------
	reg [2:0]  lfo_freq;
	reg        lfo_en;
	reg [9:0]  timer_a_load;
	reg [7:0]  timer_b_load;
	reg        ta_run, tb_run, ta_irq_en, tb_irq_en;
	reg [1:0]  ch3_mode;
	reg [7:0]  dac_data;
	reg        dac_en;

	// --- the timers ----------------------------------------------------------------------
	// Both count UP and overflow, which is why a driver writes 1024 minus the
	// period it wants. Timer A steps once per sample and timer B once per
	// sixteen; a game uses them to pace its music without needing a clock.
	reg [9:0] timer_a;
	reg [7:0] timer_b;
	reg [3:0] tb_div;
	reg       ta_flag, tb_flag;

	assign dbg_timer_a = ta_flag;
	assign dbg_timer_b = tb_flag;
	assign dbg_keyon   = {|ch_keyon[5], |ch_keyon[4], |ch_keyon[3],
	                      |ch_keyon[2], |ch_keyon[1], |ch_keyon[0]};

	// Reading any of the four addresses gives the same status byte. The busy bit
	// is always clear here: this implementation accepts a write the cycle it
	// arrives, where the real part needs a moment and makes a driver wait.
	assign dout = {1'b0, 5'd0, tb_flag, ta_flag};

	// --- writing a register ----------------------------------------------------------------
	// Which part of the chip a write lands in is decided by the address port it
	// came through, not by the register number -- so $B0 written through part 2
	// is channel 6's algorithm, not channel 3's.
	wire       part  = a[1];
	wire [7:0] rnum  = part ? addr_hi : addr_lo;
	wire       is_data = a[0] && cs && wr;
	wire       is_addr = !a[0] && cs && wr;

	// The three channels of a part, and the operator slot within one. A channel
	// field of 3 addresses nothing at all.
	wire [1:0] rch  = rnum[1:0];
	wire [1:0] rslot = rnum[3:2];
	wire       rch_ok = (rch != 2'd3);
	// Part 2's three channels are 4, 5 and 6 -- which are 3, 4 and 5 counting
	// from zero. Concatenating the part bit on the front gives 4, 5 and 6
	// instead, and channel 6 is one past the end of every array here.
	wire [2:0] chan = part ? (3'd3 + {1'b0, rch}) : {1'b0, rch};

	// Register order is 1, 3, 2, 4 while the operators are numbered 1, 2, 3, 4.
	// One swap, here, rather than everywhere the slot is used.
	wire [1:0] opnum = (rslot == 2'd1) ? 2'd2
	                 : (rslot == 2'd2) ? 2'd1 : rslot;
	wire [4:0] opix = {chan, opnum};

	integer i;

	always @(posedge clk) begin
		if (rst) begin
			addr_lo  <= 8'd0;
			addr_hi  <= 8'd0;
			lfo_freq <= 3'd0;
			lfo_en   <= 1'b0;
			timer_a_load <= 10'd0;
			timer_b_load <= 8'd0;
			ta_run <= 1'b0; tb_run <= 1'b0;
			ta_irq_en <= 1'b0; tb_irq_en <= 1'b0;
			ch3_mode <= 2'd0;
			dac_data <= 8'd0;
			dac_en   <= 1'b0;
			timer_a  <= 10'd0;
			timer_b  <= 8'd0;
			tb_div   <= 4'd0;
			ta_flag  <= 1'b0;
			tb_flag  <= 1'b0;
			for (i = 0; i < 24; i = i + 1) begin
				op_tl[i]  <= 7'd0;  op_ar[i]  <= 5'd0; op_d1r[i] <= 5'd0;
				op_d2r[i] <= 5'd0;  op_rr[i]  <= 4'd0; op_d1l[i] <= 4'd0;
				op_ks[i]  <= 2'd0;  op_mul[i] <= 4'd0; op_dt[i]  <= 3'd0;
				op_am[i]  <= 1'b0;
			end
			for (i = 0; i < 6; i = i + 1) begin
				ch_fnum[i] <= 11'd0; ch_block[i] <= 3'd0; ch_alg[i] <= 3'd0;
				ch_fb[i]   <= 3'd0;  ch_l[i]     <= 1'b1; ch_r[i]   <= 1'b1;
				ch_ams[i]  <= 3'd0;  ch_pms[i]   <= 3'd0; ch_keyon[i] <= 4'd0;
			end
		end else begin
			if (is_addr) begin
				if (part) addr_hi <= din;
				else      addr_lo <= din;
			end

			if (is_data) begin
				// The globals are only reachable through part 1, whatever the
				// register number looks like.
				if (!part && rnum < 8'h30) begin
					case (rnum)
					8'h22: begin lfo_freq <= din[2:0]; lfo_en <= din[3]; end
					8'h24: timer_a_load[9:2] <= din;
					8'h25: timer_a_load[1:0] <= din[1:0];
					8'h26: timer_b_load <= din;
					8'h27: begin
							ta_run    <= din[0];
							tb_run    <= din[1];
							ta_irq_en <= din[2];
							tb_irq_en <= din[3];
							// Writing a one to a reset bit CLEARS the flag; the
							// bit itself does not stay set.
							if (din[4]) ta_flag <= 1'b0;
							if (din[5]) tb_flag <= 1'b0;
							ch3_mode  <= din[7:6];
							// Starting a timer reloads it.
							if (din[0] && !ta_run) timer_a <= timer_a_load;
							if (din[1] && !tb_run) begin
								timer_b <= timer_b_load;
								tb_div  <= 4'd0;
							end
						end
					// Key on and off. The channel is named in the low three bits
					// and the four operators in the top four, which is the one
					// register where a channel is addressed by number rather than
					// by which port the write came through.
					8'h28: if (din[1:0] != 2'd3)
						ch_keyon[din[2] ? (3'd3 + {1'b0, din[1:0]})
						                : {1'b0, din[1:0]}] <= din[7:4];
					8'h2A: dac_data <= din;
					8'h2B: dac_en   <= din[7];
					default: ;
					endcase
				end else if (rnum >= 8'h30 && rnum < 8'hA0) begin
					if (rch_ok) case (rnum[7:4])
					4'h3: begin op_mul[opix] <= din[3:0]; op_dt[opix] <= din[6:4]; end
					4'h4: op_tl[opix] <= din[6:0];
					4'h5: begin op_ar[opix] <= din[4:0]; op_ks[opix] <= din[7:6]; end
					4'h6: begin op_d1r[opix] <= din[4:0]; op_am[opix] <= din[7]; end
					4'h7: op_d2r[opix] <= din[4:0];
					4'h8: begin op_rr[opix] <= din[3:0]; op_d1l[opix] <= din[7:4]; end
					default: ;                          // $90: SSG-EG
					endcase
				end else if (rnum >= 8'hA0) begin
					if (rch_ok) case (rnum[7:2])
					6'h28: ch_fnum[chan][7:0] <= din;               // $A0-$A2
					6'h29: begin                                     // $A4-$A6
							ch_fnum[chan][10:8] <= din[2:0];
							ch_block[chan]      <= din[5:3];
						end
					6'h2C: begin ch_alg[chan] <= din[2:0];           // $B0-$B2
					             ch_fb[chan]  <= din[5:3]; end
					6'h2D: begin                                     // $B4-$B6
							ch_r[chan]   <= din[7];
							ch_l[chan]   <= din[6];
							ch_ams[chan] <= din[5:3];
							ch_pms[chan] <= din[2:0];
						end
					default: ;
					endcase
				end
			end

			// --- the timers tick ---------------------------------------------------
			if (ce) begin
				if (ta_run) begin
					if (timer_a == 10'h3FF) begin
						timer_a <= timer_a_load;
						if (ta_irq_en) ta_flag <= 1'b1;
					end else
						timer_a <= timer_a + 10'd1;
				end

				if (tb_run) begin
					// Timer B runs at a sixteenth of timer A's rate, which is why
					// a driver uses it for the slow half of its tempo.
					if (tb_div == 4'd15) begin
						tb_div <= 4'd0;
						if (timer_b == 8'hFF) begin
							timer_b <= timer_b_load;
							if (tb_irq_en) tb_flag <= 1'b1;
						end else
							timer_b <= timer_b + 8'd1;
					end else
						tb_div <= tb_div + 4'd1;
				end
			end
		end
	end

	// --- the tables -----------------------------------------------------------------------
	reg [11:0] logsin [0:255];
	reg [10:0] ymexp  [0:255];
	`include "ym_tables.vh"

	// --- per-operator state -------------------------------------------------------------------
	reg [19:0] op_phase [0:23];     // ten bits of index, ten of fraction
	reg [9:0]  op_env   [0:23];     // attenuation: 0 is loudest, 1023 silent
	reg [1:0]  op_st    [0:23];
	reg [3:0]  ch_key_d [0:5];      // key-on as it was, to find the edges

	localparam EG_ATTACK = 2'd0, EG_DECAY = 2'd1,
	           EG_SUSTAIN = 2'd2, EG_RELEASE = 2'd3;

	// The envelope's own clock. Every rate is measured in these.
	reg [15:0] eg_cnt;

	// Operator 1 can modulate itself. The chip averages its last two outputs
	// before feeding them back, which is what stops the loop from screaming.
	reg signed [13:0] fb1 [0:5];
	reg signed [13:0] fb2 [0:5];

	// What the operators of the channel being computed produced.
	reg signed [13:0] o1, o2, o3;

	// --- the slot machine ---------------------------------------------------------------------
	// Twenty-four operators, four clocks each, one at a time. Ninety-six clocks
	// per sample where there are hundreds available, so nothing here is in a
	// hurry and none of it has to be overlapped.
	reg       running;
	reg [4:0] slot;
	reg [1:0] stage;

	wire [2:0] s_ch = slot[4:2];
	wire [1:0] s_op = slot[1:0];

	// --- the phase increment ------------------------------------------------------------------
	// The key code is the block and the top of the frequency number. It is what
	// the envelope's rate scaling is measured against -- and is the reason a high
	// note decays faster than a low one, as a real instrument does.
	wire [10:0] fnum = ch_fnum[s_ch];
	wire [2:0]  blk  = ch_block[s_ch];
	wire        kc_n = (fnum[10] & (fnum[9] | fnum[8] | fnum[7]))
	                 | (~fnum[10] & fnum[9] & fnum[8] & fnum[7]);
	wire [4:0]  keycode = {blk, fnum[10], kc_n};

	wire [17:0] fshift = {7'd0, fnum} << blk;
	wire [16:0] fbase  = fshift[17:1];

	// A multiple of zero means a HALF, not nothing -- the one field in this chip
	// that does not mean what it says.
	wire [3:0]  mul  = op_mul[slot];
	wire [20:0] fmul = {17'd0, mul} * {4'd0, fbase};
	wire [19:0] phase_inc = (mul == 4'd0) ? {4'd0, fbase[16:1]} : fmul[19:0];

	// --- the envelope's rate -------------------------------------------------------------------
	wire [1:0] ks   = op_ks[slot];
	wire [4:0] ksr  = keycode >> (2'd3 - ks);

	wire [4:0] rate_base =
		(op_st[slot] == EG_ATTACK)  ? op_ar[slot]  :
		(op_st[slot] == EG_DECAY)   ? op_d1r[slot] :
		(op_st[slot] == EG_SUSTAIN) ? op_d2r[slot] : {op_rr[slot], 1'b1};

	wire [6:0] rate_raw = {2'd0, rate_base} + {2'd0, rate_base} + {2'd0, ksr};
	wire [5:0] rate = (rate_base == 5'd0) ? 6'd0
	                : (rate_raw > 7'd63)  ? 6'd63 : rate_raw[5:0];

	// Below rate four the envelope never moves at all. Above it, the rate decides
	// how OFTEN a step happens; past 48 there is nothing faster than every
	// sample, so the steps get bigger instead.
	wire [3:0]  rsh    = (rate >= 6'd48) ? 4'd0 : (4'd11 - rate[5:2]);
	wire [15:0] rmask  = (16'd1 << rsh) - 16'd1;
	wire        rstep  = (rate >= 6'd4) && ((eg_cnt & rmask) == 16'd0);
	wire [15:0] rphase_w = eg_cnt >> rsh;
	wire [2:0]  rphase = rphase_w[2:0];

	function [2:0] eg_inc;
		input [1:0] lo;
		input [2:0] ph;
		begin
			// Every other step, then more of them, then all of them. Four
			// patterns and two bits of rate: that is the whole of the chip's fine
			// control over how fast an envelope moves.
			case (lo)
			2'd0:    eg_inc = ph[0] ? 3'd1 : 3'd0;
			2'd1:    eg_inc = (ph[0] || ph == 3'd4) ? 3'd1 : 3'd0;
			2'd2:    eg_inc = (ph[0] || ph[1]) ? 3'd1 : 3'd0;
			default: eg_inc = (ph == 3'd0) ? 3'd0 : 3'd1;
			endcase
		end
	endfunction

	wire [3:0] rbig = (rate >= 6'd48) ? (4'd1 << (rate[5:2] - 4'd12)) : 4'd1;
	wire [6:0] env_step = rstep ? ({4'd0, eg_inc(rate[1:0], rphase)} * {3'd0, rbig})
	                            : 7'd0;

	// --- feedback and the algorithm's wiring ------------------------------------------------
	wire signed [14:0] fbsum = {fb1[s_ch][13], fb1[s_ch]}
	                         + {fb2[s_ch][13], fb2[s_ch]};
	wire signed [14:0] fbsh  = fbsum >>> (4'd10 - ch_fb[s_ch]);
	wire signed [13:0] fbmod = (ch_fb[s_ch] == 3'd0) ? 14'sd0 : fbsh[13:0];

	// Which operator feeds which is the whole of what an "algorithm" is.
	reg signed [13:0] modin;
	always @(*) begin
		case (s_op)
		2'd0: modin = fbmod;                    // operator 1 modulates only itself
		2'd1: case (ch_alg[s_ch])
			3'd2, 3'd7: modin = 14'sd0;
			default:    modin = o1;
			endcase
		2'd2: case (ch_alg[s_ch])
			3'd0:    modin = o2;
			3'd1:    modin = o1 + o2;
			3'd2:    modin = o2;
			3'd5:    modin = o1;
			default: modin = 14'sd0;
			endcase
		default: case (ch_alg[s_ch])
			3'd0, 3'd1, 3'd2: modin = o3;
			3'd3:             modin = o2 + o3;
			3'd4:             modin = o3;
			3'd5:             modin = o1;
			default:          modin = 14'sd0;
			endcase
		endcase
	end

	// Does this operator reach the output, or only another operator?
	function carrier;
		input [2:0] alg;
		input [1:0] op;
		begin
			case (alg)
			3'd0, 3'd1, 3'd2, 3'd3: carrier = (op == 2'd3);
			3'd4:                   carrier = (op == 2'd1) || (op == 2'd3);
			3'd5, 3'd6:             carrier = (op != 2'd0);
			default:                carrier = 1'b1;
			endcase
		end
	endfunction

	// --- the stages ------------------------------------------------------------------------------
	reg [9:0]  ph_idx;
	reg [7:0]  sin_ix;
	reg        ph_neg;
	reg [13:0] att_tot;

	// The envelope's arithmetic, split across the stages that were already there.
	//
	// Everything below is a function of `slot`, `op_env[slot]` and `op_st[slot]`,
	// and none of those moves until stage 3: slot advances at the end of it, and
	// op_env and op_st are written in it. So the values are already settled by
	// stage 2 and registering them there changes no behaviour and costs no
	// latency -- the pass is still four stages per operator.
	//
	// What it does change is the critical path. Unregistered, stage 3 reaches
	// from `slot` through a 24-entry mux, the rate arithmetic, a DSP48 multiply
	// and back into op_env: 22 levels of logic, 20.2 ns of it on a 20 ns clock.
	// That was the whole design's worst path, and it only became a violation
	// when the DDR3 controller arrived and took the placement room away.
	//
	// There is no shortage of cycles to spend. A pass is 24 slots of 4 stages,
	// 96 clocks, and fm_ce comes round every 1008.
	reg [5:0]  rate_q;
	reg [6:0]  env_step_q;
	reg [9:0]  env_atk_q, env_up_q, d1l_att_q;

	// Total level is the patch's own volume and rides on top of the envelope.
	wire [11:0] att_sum = {2'd0, op_env[slot]} + {3'd0, op_tl[slot], 2'd0};
	wire [9:0]  att_env = (att_sum > 12'd1023) ? 10'd1023 : att_sum[9:0];

	// Back out of the logarithmic domain: the table holds the fraction and the
	// leading one is put back by hand, then the whole thing is shifted down by
	// however many powers of two the attenuation came to.
	// The table holds the FRACTION of a power of two; the leading one is put back
	// here. It belongs at bit 10, so that a mantissa of zero reads as 1024 and a
	// full one as 2042 -- concatenating it on the front instead puts it at bit 11
	// and makes everything twice as loud as it should be.
	wire [10:0] exp_q = ymexp[~att_tot[7:0]];
	wire [11:0] exp_f = 12'd1024 + {1'b0, exp_q};
	wire [11:0] exp_s = exp_f >> att_tot[12:8];
	wire signed [13:0] op_out = ph_neg ? -$signed({2'd0, exp_s})
	                                   :  $signed({2'd0, exp_s});

	reg signed [16:0] acc_l, acc_r;
	reg signed [15:0] out_l, out_r;

	// Every envelope step, worked out at a width that cannot wrap. A ten-bit
	// attenuation plus a step is eleven bits, and adding them in ten makes an
	// envelope that reaches silence, rolls over, and brings the note back.
	wire [10:0] env_wide = {1'b0, op_env[slot]} + {4'd0, env_step_q};
	wire [9:0]  env_up   = (env_wide > 11'd1023) ? 10'd1023 : env_wide[9:0];

	// The attack's step shrinks as the level rises, which is what makes a curve
	// rather than a ramp -- and it must not be allowed to overshoot past zero.
	wire [17:0] atk_mul  = ({1'b0, op_env[slot]} + 11'd1) * {4'd0, env_step_q};
	wire [13:0] atk_step = atk_mul[17:4];
	wire [9:0]  env_atk  = (atk_step >= {4'd0, op_env[slot]}) ? 10'd0
	                       : op_env[slot] - atk_step[9:0];

	// The sustain level the first decay stops at. Fifteen means silence, not
	// fifteen sixteenths of it.
	wire [9:0] d1l_att = (op_d1l[slot] == 4'd15) ? 10'd1023
	                                             : {1'b0, op_d1l[slot], 5'd0};

	integer j;

	always @(posedge clk) begin
		if (rst) begin
			running <= 1'b0;
			slot    <= 5'd0;
			stage   <= 2'd0;
			eg_cnt  <= 16'd0;
			acc_l   <= 17'sd0;
			acc_r   <= 17'sd0;
			out_l   <= 16'sd0;
			out_r   <= 16'sd0;
			o1 <= 14'sd0; o2 <= 14'sd0; o3 <= 14'sd0;
			ph_idx  <= 10'd0;
			sin_ix  <= 8'd0;
			ph_neg  <= 1'b0;
			att_tot <= 14'd0;
			rate_q     <= 6'd0;
			env_step_q <= 7'd0;
			env_atk_q  <= 10'd0;
			env_up_q   <= 10'd0;
			d1l_att_q  <= 10'd0;
			for (j = 0; j < 24; j = j + 1) begin
				op_phase[j] <= 20'd0;
				op_env[j]   <= 10'd1023;
				op_st[j]    <= EG_RELEASE;
			end
			for (j = 0; j < 6; j = j + 1) begin
				fb1[j] <= 14'sd0;
				fb2[j] <= 14'sd0;
				ch_key_d[j] <= 4'd0;
			end
		end else if (ce) begin
			// A new sample: hand over what the last pass made, and start again.
			out_l <= (acc_l >  17'sd32767) ?  16'sd32767
			       : (acc_l < -17'sd32768) ? -16'sd32768 : acc_l[15:0];
			out_r <= (acc_r >  17'sd32767) ?  16'sd32767
			       : (acc_r < -17'sd32768) ? -16'sd32768 : acc_r[15:0];
			acc_l   <= 17'sd0;
			acc_r   <= 17'sd0;
			eg_cnt  <= eg_cnt + 16'd1;
			slot    <= 5'd0;
			stage   <= 2'd0;
			running <= 1'b1;
		end else if (running) begin
			case (stage)
			2'd0: begin
					// Key-on restarts the envelope AND the phase, which is why a
					// note struck twice sounds identical both times.
					if (ch_keyon[s_ch][s_op] && !ch_key_d[s_ch][s_op]) begin
						op_st[slot]    <= EG_ATTACK;
						op_phase[slot] <= 20'd0;
						ph_idx         <= 10'd0 + modin[13:1];
					end else begin
						if (!ch_keyon[s_ch][s_op] && ch_key_d[s_ch][s_op])
							op_st[slot] <= EG_RELEASE;
						op_phase[slot] <= op_phase[slot] + phase_inc;
						// Half the modulator: that is the depth the chip uses,
						// and it is what makes the algorithms line up.
						ph_idx <= op_phase[slot][19:10] + modin[13:1];
					end

					// The rate arithmetic, latched the moment the slot is valid.
					// Splitting it from the attack multiply is the point: as one
					// expression they are 23 levels of logic ending in a DSP48,
					// and 20 ns at 50 MHz does not cover that. As two they are
					// comfortably inside a cycle each.
					rate_q     <= rate;
					env_step_q <= env_step;

					stage <= 2'd1;
				end

			2'd1: begin
					// A quarter period is stored; the second and fourth are it
					// backwards, and the bottom half is the same shape negated.
					sin_ix <= ph_idx[8] ? ~ph_idx[7:0] : ph_idx[7:0];
					ph_neg <= ph_idx[9];
					stage  <= 2'd2;
				end

			2'd2: begin
					// An add, because both of these are attenuations. The
					// envelope's ten bits sit on the same scale as the sine's
					// twelve once it is shifted up by two.
					att_tot <= {2'd0, logsin[sin_ix]} + {2'd0, att_env, 2'd0};

					// Settled since stage 0; latched here so stage 3 is a
					// select and a write rather than the whole computation.
					env_atk_q  <= env_atk;
					env_up_q   <= env_up;
					d1l_att_q  <= d1l_att;

					stage   <= 2'd3;
				end

			default: begin
					// --- the operator's answer ------------------------------------
					if (s_op == 2'd0) begin
						o1     <= op_out;
						fb2[s_ch] <= fb1[s_ch];
						fb1[s_ch] <= op_out;
					end else if (s_op == 2'd1) o2 <= op_out;
					else if (s_op == 2'd2)     o3 <= op_out;

					if (carrier(ch_alg[s_ch], s_op)) begin
						if (ch_l[s_ch]) acc_l <= acc_l + {{3{op_out[13]}}, op_out};
						if (ch_r[s_ch]) acc_r <= acc_r + {{3{op_out[13]}}, op_out};
					end

					// --- and its envelope moves on ---------------------------------
					case (op_st[slot])
					EG_ATTACK:
						// The step shrinks as the level rises, which is what makes
						// an attack curve rather than a ramp. A rate of 62 or more
						// is instant.
						if (rate_q >= 6'd62 || op_env[slot] == 10'd0) begin
							op_env[slot] <= 10'd0;
							op_st[slot]  <= EG_DECAY;
						end else if (env_step_q != 7'd0)
							op_env[slot] <= env_atk_q;
					EG_DECAY:
						if (op_env[slot] >= d1l_att_q) op_st[slot] <= EG_SUSTAIN;
						else op_env[slot] <= env_up_q;
					default:
						op_env[slot] <= env_up_q;
					endcase

					ch_key_d[s_ch][s_op] <= ch_keyon[s_ch][s_op];

					stage <= 2'd0;
					if (slot == 5'd23) running <= 1'b0;
					else               slot    <= slot + 5'd1;
				end
			endcase
		end
	end

	// --- what comes out ------------------------------------------------------------------------
	// Channel 6 can be turned into a plain eight-bit DAC instead of an FM voice,
	// which is how a Mega Drive plays a drum sample or a voice. When it is, the
	// FM side of that channel goes quiet and this takes its place.
	wire signed [15:0] dac_out =
		dac_en ? {~dac_data[7], dac_data[6:0], 8'd0} : 16'sd0;

	assign left  = dac_en ? dac_out : out_l;
	assign right = dac_en ? dac_out : out_r;

endmodule

`default_nettype wire
