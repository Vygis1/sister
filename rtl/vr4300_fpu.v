//////////////////////////////////////////////////////////////////////////////////
// vr4300_fpu.v - the VR4300's floating-point arithmetic (COP1), one operation at
// a time: the CPU holds the instruction in E from `start` until `done`.
//
// Behaviour is tools/n64/n64fpu.py's, which follows ares (ISC): IEEE single and
// double in the four rounding modes, with the VR4300's limits -- a subnormal
// operand or a quiet NaN traps as Unimplemented Operation, and so does a
// subnormal result unless FCR31.FS flushes it; a signalling NaN (quiet bit SET,
// the old MIPS convention) is an invalid operation whose result is the default
// NaN 7FBFFFFF / 7FF7FFFFFFFFFFFF; conversions to integer trap as unimplemented
// for anything not finite and in range. Underflow is detected after rounding
// and flagged only when the result is inexact, as the x86 ares runs on does.
//
// The registers stay in the CPU, which hands over the operands already read
// (fs paired as Status.FR says, ft as is) and writes back what comes out.
//
// --- how ------------------------------------------------------------------------
//
// Every arithmetic operation ends with a 64-bit significand, normalised so bit
// 63 is the leading one, an exponent E (bit 63 is worth 2^E) and a sticky bit
// for anything below bit 0. One rounding stage serves them all:
//   add/sub   the smaller operand shifted right (the bits shifted out are the
//             sticky, borrowed into a subtraction), then one 64-bit add
//   multiply  53 x 14 bits a clock, four clocks, into a 106-bit sum
//   divide    restoring, a quotient bit a clock: 56 for double, 27 for single
//             (the chip takes 58 and 29)
//   sqrt      the digit-by-digit square root, a bit a clock, 56 clocks
//   int->fp   the integer as the significand, E = 63
// A result too small to be normal never needs its subnormal bits: it either
// traps or is flushed (to zero or the smallest normal, by the rounding mode).
// So the second rounding, on the denormalised value, only says whether the
// result came out zero, subnormal or the smallest normal.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module vr4300_fpu (
	input  wire        clk,
	input  wire        rst,
	input  wire        start,         // take the operation (one clock)
	input  wire [4:0]  fmt,           // the rs field: 16 S, 17 D, 20 W, 21 L
	input  wire [5:0]  fn,
	input  wire [63:0] fs_v,          // fs (single and word in [31:0])
	input  wire [63:0] ft_v,          // ft
	input  wire [1:0]  rm,            // FCR31: rounding mode
	input  wire [4:0]  en,            //        exception enables, I U O Z V
	input  wire        fs_flush,      //        FS: flush subnormal results
	output reg         done,          // the outputs are valid; held until the next start
	output reg  [63:0] res,
	output reg         res32,         // a single or word result: written with the upper half 0
	output reg         wr,            // fd is written
	output reg         trap,          // a floating-point exception
	output reg  [5:0]  cause,         // FCR31's new cause field, I U O Z V E
	output reg  [4:0]  flags,         // to OR into the flags, I U O Z V
	output reg         cmp_wr,        // a C.cond: the condition bit
	output reg         cmp_val,
	// the operation taken cannot trap: the fast path's, with Flush (FS) set and Overflow
	// and Underflow not enabled (whatever path its result takes, nothing traps). The CPU
	// lets the instruction go on and takes the result when done (see vr4300.v, fp_pend).
	output reg         asy
);
	localparam BI = 0, BU = 1, BO = 2, BZ = 3, BV = 4, BE = 5;

	localparam [4:0] P_IDLE = 5'd0, P_DEC = 5'd1, P_ADD = 5'd2, P_MUL = 5'd3, P_DIV = 5'd4,
	                 P_SQRT = 5'd5, P_NORM = 5'd6, P_ROUND = 5'd7, P_DENORM = 5'd8, P_TOINT = 5'd9,
	                 P_FIN = 5'd10, P_DONE = 5'd11, P_UNP = 5'd12, P_ALIGN = 5'd13, P_TOINT2 = 5'd14, P_FAST = 5'd15,
	                 P_NORM2 = 5'd16, P_MULE = 5'd17;
	reg  [4:0]  st;

	// --- the operation, as taken ----------------------------------------------------
	reg  [4:0]  q_fmt;
	reg  [5:0]  q_fn;
	reg  [63:0] q_a, q_b;
	reg  [1:0]  q_rm;
	reg  [4:0]  q_en;
	reg         q_fs;

	wire        dbl = q_fmt == 5'd17;
	// unpacking: sign, biased exponent, fraction, in either format
	function [70:0] unpack;      // {kind[2:0], snan, sign, e[12:0] unbiased, sig[52:0]}
		input [63:0] v;
		input        d;
		reg [10:0] e; reg [51:0] m; reg s; reg [2:0] kind; reg sn; reg [12:0] eu; reg [52:0] g;
		begin
			if (d) begin s = v[63]; e = v[62:52]; m = v[51:0]; end
			else   begin s = v[31]; e = {3'd0, v[30:23]}; m = {v[22:0], 29'd0}; end
			sn = m[51];
			// kinds: 0 zero 1 subnormal 2 normal 3 infinity 4 NaN
			if (e == (d ? 11'h7FF : 11'h0FF)) kind = (m != 52'd0) ? 3'd4 : 3'd3;
			else if (e == 11'd0) kind = (m != 52'd0) ? 3'd1 : 3'd0;
			else kind = 3'd2;
			eu = {2'b00, e} - (d ? 13'd1023 : 13'd127);
			g = {1'b1, m};
			unpack = {kind, sn, s, eu, g};
		end
	endfunction
	wire [70:0] ua = unpack(q_a, dbl), ub = unpack(q_b, dbl);
	localparam [2:0] K_ZERO = 3'd0, K_SUB = 3'd1, K_NORM = 3'd2, K_INF = 3'd3, K_NAN = 3'd4;
	// the operands unpacked, and how they compare -- registered (P_UNP), so the
	// decision on what to do is not in the same clock as the unpacking
	reg  [2:0]  ka, kb;
	reg         sna, snb, sa, sb_raw;
	reg  [12:0] ea, eb;
	reg  [52:0] ga, gb;
	reg         c_eq, c_lt;
	wire        a_qnan = ka == K_NAN && !sna, b_qnan = kb == K_NAN && !snb;
	wire        a_snan = ka == K_NAN && sna,  b_snan = kb == K_NAN && snb;

	// --- the working value ------------------------------------------------------------
	reg         r_sign;
	reg  [13:0] r_e;              // signed: bit 63 of r_sig is worth 2^r_e
	reg  [63:0] r_sig;
	reg         r_st;             // sticky: something nonzero below bit 0
	reg         tf_d;             // the format being rounded to
	reg  [4:0]  raised;           // I U O Z V, from the operation
	reg         is_conv;          // a conversion to integer (its V is an unimplemented trap)

	// special results in the target format
	function [63:0] inf_of;  input s; input d; inf_of  = d ? {s, 11'h7FF, 52'd0} : {32'd0, s, 8'hFF, 23'd0}; endfunction
	function [63:0] zero_of; input s; input d; zero_of = d ? {s, 63'd0} : {32'd0, s, 31'd0}; endfunction
	function [63:0] max_of;  input s; input d; max_of  = d ? {s, 11'h7FE, {52{1'b1}}} : {32'd0, s, 8'hFE, {23{1'b1}}}; endfunction
	function [63:0] min_of;  input s; input d; min_of  = d ? {s, 11'h001, 52'd0} : {32'd0, s, 8'h01, 23'd0}; endfunction
	function [63:0] dnan_of; input d; dnan_of = d ? 64'h7FF7_FFFF_FFFF_FFFF : 64'h0000_0000_7FBF_FFFF; endfunction

	// --- add: the operands ordered by magnitude ---------------------------------------
	wire        b_sub_sign = sb_raw ^ (q_fn == 6'h01);          // B's sign as added
	wire        a_big = ($signed(ea) > $signed(eb)) || (ea == eb && ga >= gb);
	wire [12:0] e_big = a_big ? ea : eb;
	wire [12:0] e_dif = a_big ? ea - eb : eb - ea;
	wire [52:0] g_big = a_big ? ga : gb, g_small = a_big ? gb : ga;
	wire        s_big = a_big ? sa : b_sub_sign;
	wire        eff_sub = sa ^ b_sub_sign;
	wire [63:0] small64 = {1'b0, g_small, 10'd0};
	wire [6:0]  ash = (e_dif > 13'd64) ? 7'd64 : e_dif[6:0];
	wire [127:0] small_sh = {small64, 64'd0} >> ash;               // [127:64] kept, [63:0] shifted out
	wire        add_st = small_sh[63:0] != 64'd0;
	wire [63:0] big64 = {1'b0, g_big, 10'd0};
	reg  [63:0] al_big, al_small;
	reg         al_st, al_sign, al_sub;
	reg  [12:0] al_e;

	// --- multiply ------------------------------------------------------------------------
	reg  [105:0] macc;
	reg  [1:0]   mstep;
	wire [55:0]  gb56 = {3'd0, gb};
	wire [13:0]  mchunk = gb56[14 * mstep +: 14];
	wire [66:0]  mpart = ga * mchunk;
	// (registered before it is shifted and added: the multiply, the shift and the 106-bit add
	// in one clock were over 16 ns. P_MULE adds the last one.)
	reg  [66:0]  mp_q;
	reg  [1:0]   mp_sh;
	reg          mp_v;

	// --- divide ---------------------------------------------------------------------------
	reg  [53:0]  drem;
	reg  [55:0]  dq;
	reg  [5:0]   dn;
	wire [54:0]  drem_sub = {1'b0, drem} - {2'b00, gb};

	// --- square root ------------------------------------------------------------------------
	reg  [111:0] sx;
	reg  [59:0]  srem;
	reg  [55:0]  sroot;
	wire [59:0]  srem_t = {srem[57:0], sx[111:110]};
	wire [59:0]  strial = {2'b00, sroot, 2'b01};
	wire         s_ge = srem_t >= strial;

	// --- normalise ----------------------------------------------------------------------------
	function [6:0] lzc64; input [63:0] v; integer i; reg f; begin
		lzc64 = 7'd64; f = 1'b0;
		for (i = 63; i >= 0; i = i - 1) if (!f && v[i]) begin lzc64 = 7'd63 - i[6:0]; f = 1'b1; end
	end endfunction
	wire [6:0]  lz = lzc64(r_sig);
	reg  [6:0]  lz_q;

	// --- rounding --------------------------------------------------------------------------
	// the kept bits, the round bit and the sticky, at the format's position
	function [55:0] cut;      // {kept[52:0] right-aligned, rbit, st, pad}
		input [63:0] v; input stk; input d;
		begin
			if (d) cut = {v[63:11], v[10], (v[9:0] != 10'd0) | stk, 1'b0};
			else   cut = {29'd0, v[63:40], v[39], (v[38:0] != 39'd0) | stk, 1'b0};
		end
	endfunction
	function inc_of; input [1:0] mode; input s; input lsb; input rb; input stk; begin
		case (mode)
		2'd0: inc_of = rb && (stk || lsb);
		2'd1: inc_of = 1'b0;
		2'd2: inc_of = !s && (rb || stk);
		default: inc_of = s && (rb || stk);
		endcase
	end endfunction
	wire [55:0] cu = cut(r_sig, r_st, tf_d);
	wire [52:0] kept = cu[55:3];
	wire        rbit = cu[2], rst_ = cu[1];
	wire        inc = inc_of(q_rm, r_sign, kept[0], rbit, rst_);
	wire [53:0] kept_r = {1'b0, kept} + {53'd0, inc};
	wire        carry = tf_d ? kept_r[53] : kept_r[24];
	wire [13:0] e_u = r_e + {13'd0, carry};
	wire        inexact_u = rbit || rst_;
	wire [13:0] emin = tf_d ? -14'sd1022 : -14'sd126;
	wire [13:0] emax = tf_d ? 14'sd1023 : 14'sd127;
	wire        ovf  = $signed(e_u) > $signed(emax);
	wire        tiny = $signed(e_u) < $signed(emin);
	wire [13:0] bias = tf_d ? 14'd1023 : 14'd127;
	wire [13:0] e_b  = e_u + bias;
	wire [52:0] mant = carry ? (kept_r[53:1]) : kept_r[52:0];
	wire [63:0] packed = tf_d ? {r_sign, e_b[10:0], mant[51:0]} : {32'd0, r_sign, e_b[7:0], mant[22:0]};

	// the bounded rounding, for a tiny result: shifted right to emin's position
	reg  [63:0] dn_sig; reg dn_st;
	wire [13:0] dsh_full = emin - r_e;                              // >= 1 when tiny
	wire [6:0]  dsh = ($signed(dsh_full) > 14'sd64) ? 7'd64 : dsh_full[6:0];
	wire [127:0] den = {r_sig, 64'd0} >> dsh;
	wire [55:0] cb = cut(dn_sig, dn_st, tf_d);
	wire        inc_b = inc_of(q_rm, r_sign, cb[3], cb[2], cb[1]);
	wire [53:0] kept_b = {1'b0, cb[55:3]} + {53'd0, inc_b};
	wire        b_zero = kept_b == 54'd0;
	wire        b_min  = tf_d ? kept_b[52] : kept_b[23];            // reached the hidden bit: 2^emin
	wire        inexact_b = cb[2] || cb[1];

	// --- to an integer -------------------------------------------------------------------------
	wire [12:0] ti_sh = 13'd52 - ea;                                // >= 0 (|x| < 2^53)
	wire        ti_far = $signed(ti_sh) > 13'sd55;
	wire [5:0]  ti_s = ti_far ? 6'd0 : ti_sh[5:0];
	wire [115:0] ti_w = {ga, 63'd0} >> ti_s;                        // [115:63] integer, [62] round, [61:0] sticky
	reg  [52:0] ti_int;
	reg         ti_rb, ti_st;
	wire [1:0]  ti_mode = (q_fn[5] == 1'b1) ? q_rm
	                    : (q_fn[1:0] == 2'd0) ? 2'd0 : (q_fn[1:0] == 2'd1) ? 2'd1 : (q_fn[1:0] == 2'd2) ? 2'd2 : 2'd3;
	wire        ti_inc = inc_of(ti_mode, sa, ti_int[0], ti_rb, ti_st);
	wire [53:0] ti_n = {1'b0, ti_int} + {53'd0, ti_inc};
	wire        ti_w32 = !(q_fn == 6'h08 || q_fn == 6'h09 || q_fn == 6'h0A || q_fn == 6'h0B || q_fn == 6'h25);
	wire        ti_ovf = ti_w32 && (sa ? (ti_n > 54'h8000_0000) : (ti_n > 54'h7FFF_FFFF));
	wire [63:0] ti_val = sa ? -{10'd0, ti_n} : {10'd0, ti_n};

	// --- compares -------------------------------------------------------------------------------
	wire [62:0] mag_a = dbl ? q_a[62:0] : {32'd0, q_a[30:0]};
	wire [62:0] mag_b = dbl ? q_b[62:0] : {32'd0, q_b[30:0]};
	wire        u_sa = ua[66], u_sb = ub[66];
	wire        both_zero = ua[70:68] == K_ZERO && ub[70:68] == K_ZERO;
	wire        u_c_eq = both_zero || (u_sa == u_sb && mag_a == mag_b);
	wire        u_c_lt = !both_zero && ((u_sa && !u_sb) || (!u_sa && !u_sb && mag_a < mag_b) || (u_sa && u_sb && mag_a > mag_b));

	// --- the fast path ----------------------------------------------------------------------------
	// ADD/SUB/MUL.S of two normal singles, rounding to nearest, Inexact not enabled: what
	// SM64 spends its floating point on. A pipeline of its own -- add four clocks, multiply
	// three, where the general path takes eight or nine and the CPU waits through all of
	// them (22% of its clocks) -- that gives the operation back to the general path from
	// P_UNP whenever the result would not be a normal number (overflow, underflow: what
	// traps or is flushed is the general path's business). Bit for bit the same; checked by
	// sim/tb_vr4300_fpu.v against tools/n64/n64fpu.py (n64fpuvec.py --fast).
	// (the enables: only Inexact's matters -- two normal operands raise no Invalid and no
	// divide-by-zero, and Overflow and Underflow go to the general path. SM64 runs with
	// Invalid enabled, as libultra sets FCR31, and "none enabled" took nothing of it.)
	wire        fast_in = fmt == 5'd16 && fn <= 6'h02 && rm == 2'd0 && !en[0]
	                      && fs_v[30:23] != 8'h00 && fs_v[30:23] != 8'hFF && ft_v[30:23] != 8'h00 && ft_v[30:23] != 8'hFF;
	reg  [2:0]  fx;                          // the step
	// step 1 -- add: the operands ordered by magnitude, the smaller aligned; multiply: the product
	wire        x_sa = q_a[31], x_sb = q_b[31] ^ (q_fn[1:0] == 2'd1);
	wire [7:0]  x_ea = q_a[30:23], x_eb = q_b[30:23];
	wire [23:0] x_ma = {1'b1, q_a[22:0]}, x_mb = {1'b1, q_b[22:0]};
	wire        x_abig = {x_ea, x_ma} >= {x_eb, x_mb};
	wire [7:0]  x_d = x_abig ? x_ea - x_eb : x_eb - x_ea;
	wire [4:0]  x_dc = (x_d > 8'd31) ? 5'd31 : x_d[4:0];
	wire [50:0] x_sh = {x_abig ? x_mb : x_ma, 27'd0} >> x_dc;
	reg         f_s, f_sub, f_mul;
	reg  [9:0]  f_e;                         // biased, with room for the multiply's range
	reg  [27:0] f_big, f_small;              // {carry, hidden, 23, guard, round, sticky}
	reg  [47:0] f_p;
	// step 2 -- add: the sum; multiply: normalised
	reg  [27:0] f_sum;
	// step 3 (add): normalised -- {hidden, 23, guard, round, sticky}
	function [4:0] lz27; input [26:0] v; integer i; reg f; begin
		lz27 = 5'd27; f = 1'b0;
		for (i = 26; i >= 0; i = i - 1) if (!f && v[i]) begin lz27 = 5'd26 - i[4:0]; f = 1'b1; end
	end endfunction
	wire [4:0]  f_lz = lz27(f_sum[26:0]);
	reg  [26:0] f_n;
	reg         f_zero;
	// the last step: rounded to nearest, even; packed, or handed to the general path
	wire        f_inc = f_n[2] && (f_n[1] || f_n[0] || f_n[3]);
	wire [24:0] f_m = {1'b0, f_n[26:3]} + {24'd0, f_inc};
	wire [9:0]  f_er = f_e + {9'd0, f_m[24]};
	wire [22:0] f_frac = f_m[24] ? f_m[23:1] : f_m[22:0];
	wire        f_ok = f_zero || (!f_er[9] && f_er != 10'd0 && f_er < 10'd255);
	wire        f_inexact = !f_zero && (f_n[2] || f_n[1] || f_n[0]);

	// --- the end: flags, cause, the trap ----------------------------------------------------------
	// raise(bits): the cause for each; the flag for those not enabled; a trap if any is
	task finish_with; input [4:0] r; input [63:0] v; input is32; input w; begin
		cause <= {1'b0, r};
		flags <= r & ~q_en;
		trap  <= (r & q_en) != 5'd0;
		res <= v; res32 <= is32; wr <= w && ((r & q_en) == 5'd0);
		done <= 1'b1; st <= P_IDLE;           // (done with the result: a P_DONE clock cost every operation one)
	end endtask
	task unimpl; begin
		cause <= 6'b100000; flags <= 5'd0; trap <= 1'b1; wr <= 1'b0; done <= 1'b1; st <= P_IDLE;
	end endtask

	wire is_fp = q_fmt == 5'd16 || q_fmt == 5'd17;

	always @(posedge clk) begin
		if (rst) begin
			st <= P_IDLE; done <= 1'b0; asy <= 1'b0;
		end else if (start) begin
			q_fmt <= fmt; q_fn <= fn; q_a <= fs_v; q_b <= ft_v; q_rm <= rm; q_en <= en; q_fs <= fs_flush;
			st <= fast_in ? P_FAST : P_UNP; fx <= 3'd0; done <= 1'b0;
			asy <= fast_in && fs_flush && en[2:1] == 2'b00;
			trap <= 1'b0; wr <= 1'b0; cmp_wr <= 1'b0; cause <= 6'd0; flags <= 5'd0; res32 <= 1'b0;
		end else begin
			case (st)
			P_UNP: begin
				ka <= ua[70:68]; kb <= ub[70:68]; sna <= ua[67]; snb <= ub[67]; sa <= ua[66]; sb_raw <= ub[66];
				ea <= ua[65:53]; eb <= ub[65:53]; ga <= ua[52:0]; gb <= ub[52:0];
				c_eq <= u_c_eq; c_lt <= u_c_lt;
				st <= P_DEC;
			end

			P_DEC: begin
				raised <= 5'd0; r_st <= 1'b0; is_conv <= 1'b0;
				tf_d <= dbl;
				if (is_fp && q_fn <= 6'h03) begin
					// ADD SUB MUL DIV: the inputs, in ares's order
					if (a_qnan || b_qnan || ka == K_SUB || kb == K_SUB) unimpl;
					else if (a_snan || b_snan) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
					else case (q_fn[1:0])
					2'd0, 2'd1: begin
						if (ka == K_INF || kb == K_INF) begin
							if (ka == K_INF && kb == K_INF && sa != b_sub_sign) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
							else finish_with(5'd0, inf_of(ka == K_INF ? sa : b_sub_sign, dbl), !dbl, 1'b1);
						end else if (ka == K_ZERO && kb == K_ZERO)
							finish_with(5'd0, zero_of((sa == b_sub_sign) ? sa : (q_rm == 2'd3), dbl), !dbl, 1'b1);
						else if (kb == K_ZERO) finish_with(5'd0, dbl ? q_a : {32'd0, q_a[31:0]}, !dbl, 1'b1);
						else if (ka == K_ZERO) finish_with(5'd0, dbl ? {b_sub_sign, q_b[62:0]} : {32'd0, b_sub_sign, q_b[30:0]}, !dbl, 1'b1);
						else st <= P_ALIGN;
					end
					2'd2: begin
						if (ka == K_INF || kb == K_INF) begin
							if (ka == K_ZERO || kb == K_ZERO) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
							else finish_with(5'd0, inf_of(sa ^ sb_raw, dbl), !dbl, 1'b1);
						end else if (ka == K_ZERO || kb == K_ZERO) finish_with(5'd0, zero_of(sa ^ sb_raw, dbl), !dbl, 1'b1);
						// (a single's significand is the top 24 bits: its low two 14-bit chunks are zero)
						else begin macc <= 106'd0; mstep <= dbl ? 2'd0 : 2'd2; mp_v <= 1'b0; st <= P_MUL; end
					end
					default: begin
						if (ka == K_INF) begin
							if (kb == K_INF) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
							else finish_with(5'd0, inf_of(sa ^ sb_raw, dbl), !dbl, 1'b1);
						end else if (kb == K_INF) finish_with(5'd0, zero_of(sa ^ sb_raw, dbl), !dbl, 1'b1);
						else if (kb == K_ZERO) begin
							if (ka == K_ZERO) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
							else finish_with(5'b01000, inf_of(sa ^ sb_raw, dbl), !dbl, 1'b1);
						end else if (ka == K_ZERO) finish_with(5'd0, zero_of(sa ^ sb_raw, dbl), !dbl, 1'b1);
						else begin drem <= {1'b0, ga}; dq <= 56'd0; dn <= dbl ? 6'd56 : 6'd27; st <= P_DIV; end
					end
					endcase
				end else if (is_fp && (q_fn == 6'h04 || q_fn == 6'h05 || q_fn == 6'h07)) begin
					// SQRT ABS NEG: one input
					if (ka == K_SUB || a_qnan) unimpl;
					else if (a_snan) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
					else if (q_fn == 6'h05) finish_with(5'd0, dbl ? {1'b0, q_a[62:0]} : {32'd0, 1'b0, q_a[30:0]}, !dbl, 1'b1);
					else if (q_fn == 6'h07) finish_with(5'd0, dbl ? {~q_a[63], q_a[62:0]} : {32'd0, ~q_a[31], q_a[30:0]}, !dbl, 1'b1);
					else if (ka == K_ZERO) finish_with(5'd0, dbl ? q_a : {32'd0, q_a[31:0]}, !dbl, 1'b1);
					else if (sa) finish_with(5'b10000, dnan_of(dbl), !dbl, 1'b1);
					else if (ka == K_INF) finish_with(5'd0, dbl ? q_a : {32'd0, q_a[31:0]}, !dbl, 1'b1);
					else begin
						// the significand, doubled when the exponent is odd, as the top of 112 bits
						sx <= ea[0] ? {ga, 1'b0, 58'd0} : {1'b0, ga, 58'd0};
						r_e <= $signed({ea[12], ea}) >>> 1;
						srem <= 60'd0; sroot <= 56'd0; dn <= 6'd56;
						r_sign <= 1'b0;
						st <= P_SQRT;
					end
				end else if (is_fp && ((q_fn >= 6'h08 && q_fn <= 6'h0F) || q_fn == 6'h24 || q_fn == 6'h25)) begin
					// to an integer: finite and in range, or it is not handled
					is_conv <= 1'b1;
					if (ka == K_SUB || ka == K_INF || ka == K_NAN) unimpl;
					else if (ka == K_ZERO) finish_with(5'd0, 64'd0, ti_w32, 1'b1);
					else if (ti_w32 ? ($signed(ea) >= 13'sd31 && !(sa && ea == 13'd31 && ga == {1'b1, 52'd0}))
					                : ($signed(ea) >= 13'sd53))
						unimpl;
					else st <= P_TOINT;
				end else if (is_fp && (q_fn == 6'h20 || q_fn == 6'h21)) begin
					// CVT.S / CVT.D between the two
					if ((q_fn == 6'h20) == !dbl) unimpl;
					else if (ka == K_SUB || a_qnan) unimpl;
					else if (a_snan) finish_with(5'b10000, dnan_of(!dbl), dbl, 1'b1);
					else if (ka == K_INF) finish_with(5'd0, inf_of(sa, !dbl), dbl, 1'b1);
					else if (ka == K_ZERO) finish_with(5'd0, zero_of(sa, !dbl), dbl, 1'b1);
					else begin
						tf_d <= !dbl; r_sign <= sa; r_e <= {ea[12], ea}; r_sig <= {ga, 11'd0}; st <= P_ROUND;
					end
				end else if (is_fp && q_fn[5:4] == 2'b11) begin
					// C.cond
					if (ka == K_NAN || kb == K_NAN) begin
						if (((ka == K_NAN) && (q_fn[3] || sna)) || ((kb == K_NAN) && (q_fn[3] || snb))) begin
							cause <= 6'b010000;
							if (q_en[BV]) begin trap <= 1'b1; done <= 1'b1; st <= P_IDLE; end
							else begin flags <= 5'b10000; cmp_wr <= 1'b1; cmp_val <= q_fn[0]; done <= 1'b1; st <= P_IDLE; end
						end else begin cmp_wr <= 1'b1; cmp_val <= q_fn[0]; done <= 1'b1; st <= P_IDLE; end
					end else begin
						cmp_wr <= 1'b1; cmp_val <= (q_fn[2] && c_lt) || (q_fn[1] && c_eq); done <= 1'b1; st <= P_IDLE;
					end
				end else if ((q_fmt == 5'd20 || q_fmt == 5'd21) && (q_fn == 6'h20 || q_fn == 6'h21)) begin
					// CVT.S / CVT.D from W or L
					tf_d <= q_fn[0];
					if (q_fmt == 5'd21 && ($signed(q_a) >= 64'sh0080_0000_0000_0000 || $signed(q_a) < -64'sh0080_0000_0000_0000)) unimpl;
					else begin
						if (q_fmt == 5'd20) begin
							r_sign <= q_a[31];
							r_sig  <= q_a[31] ? {32'd0, -q_a[31:0]} : {32'd0, q_a[31:0]};
						end else begin
							r_sign <= q_a[63];
							r_sig  <= q_a[63] ? -q_a : q_a;
						end
						r_e <= 14'd63;
						if ((q_fmt == 5'd20 ? q_a[31:0] == 32'd0 : q_a == 64'd0))
							finish_with(5'd0, zero_of(1'b0, q_fn[0]), !q_fn[0], 1'b1);
						else st <= P_NORM;
					end
				end else unimpl;
			end

			P_ALIGN: begin
				al_big <= big64; al_small <= small_sh[127:64]; al_st <= add_st;
				al_sign <= s_big; al_sub <= eff_sub; al_e <= e_big;
				st <= P_ADD;
			end

			P_ADD: begin
				r_sign <= al_sign;
				r_e <= {al_e[12], al_e} + 14'd1;
				r_st <= al_st;
				if (al_sub) begin
					if (al_big == al_small && !al_st)
						finish_with(5'd0, zero_of(q_rm == 2'd3, dbl), !dbl, 1'b1);   // exactly cancelled
					else begin r_sig <= al_big - al_small - {63'd0, al_st}; st <= P_NORM; end
				end else begin
					r_sig <= al_big + al_small; st <= P_NORM;
				end
			end

			P_MUL: begin
				mp_q <= mpart; mp_sh <= mstep; mp_v <= 1'b1;
				if (mp_v) macc <= macc + ({39'd0, mp_q} << (14 * mp_sh));
				mstep <= mstep + 2'd1;
				if (mstep == 2'd3) st <= P_MULE;
			end

			P_MULE: begin
				macc <= macc + ({39'd0, mp_q} << (14 * mp_sh));
				mp_v <= 1'b0;
				r_sign <= sa ^ sb_raw;
				r_e <= {ea[12], ea} + {eb[12], eb} + 14'd1;
				st <= P_FIN;          // P_FIN here: take the product (see below)
			end

			P_DIV: begin
				if (dn != 6'd0) begin
					if (!drem_sub[54]) begin drem <= {drem_sub[52:0], 1'b0}; dq <= {dq[54:0], 1'b1}; end
					else begin drem <= {drem[52:0], 1'b0}; dq <= {dq[54:0], 1'b0}; end
					dn <= dn - 6'd1;
				end else begin
					r_sign <= sa ^ sb_raw;
					r_e <= {ea[12], ea} - {eb[12], eb};
					r_sig <= dbl ? {dq, 8'd0} : ({dq[26:0], 37'd0});
					r_st <= drem != 54'd0;
					st <= P_NORM;
				end
			end

			P_SQRT: begin
				if (dn != 6'd0) begin
					sx <= {sx[109:0], 2'b00};
					if (s_ge) begin srem <= srem_t - strial; sroot <= {sroot[54:0], 1'b1}; end
					else begin srem <= srem_t; sroot <= {sroot[54:0], 1'b0}; end
					dn <= dn - 6'd1;
				end else begin
					r_sig <= {sroot, 8'd0};
					r_st <= srem != 60'd0;
					st <= P_NORM;
				end
			end

			// (the count and the 64-bit shift by it in one clock were over 16 ns)
			P_NORM: begin
				lz_q <= lz;
				st <= P_NORM2;
			end

			P_NORM2: begin
				r_sig <= r_sig << lz_q;
				r_e <= r_e - {7'd0, lz_q};
				st <= P_ROUND;
			end

			P_ROUND: begin
				if (ovf) begin
					if (q_rm == 2'd0 || (q_rm == 2'd2 && !r_sign) || (q_rm == 2'd3 && r_sign))
						finish_with(5'b00101, inf_of(r_sign, tf_d), !tf_d, 1'b1);
					else finish_with(5'b00101, max_of(r_sign, tf_d), !tf_d, 1'b1);
				end else if (tiny) begin
					dn_sig <= den[127:64]; dn_st <= r_st || (den[63:0] != 64'd0);
					st <= P_DENORM;
				end else
					finish_with(inexact_u ? 5'b00001 : 5'd0, packed, !tf_d, 1'b1);
			end

			P_DENORM: begin
				// too small to be normal: it traps, unless FS flushes it
				if (!q_fs || q_en[BU] || q_en[BI]) unimpl;
				else if (inexact_b && b_zero) finish_with(5'b00011, zero_of(r_sign, tf_d), !tf_d, 1'b1);
				else if (inexact_b && b_min) finish_with(5'b00011, min_of(r_sign, tf_d), !tf_d, 1'b1);
				else begin
					// a subnormal result, flushed by the rounding mode
					if (q_rm == 2'd2 && !r_sign) finish_with(5'b00011, min_of(1'b0, tf_d), !tf_d, 1'b1);
					else if (q_rm == 2'd3 && r_sign) finish_with(5'b00011, min_of(1'b1, tf_d), !tf_d, 1'b1);
					else finish_with(5'b00011, zero_of(r_sign, tf_d), !tf_d, 1'b1);
				end
			end

			P_TOINT: begin
				ti_int <= ti_far ? 53'd0 : ti_w[115:63];
				ti_rb  <= ti_far ? 1'b0 : ti_w[62];
				ti_st  <= ti_far ? 1'b1 : (ti_w[61:0] != 62'd0);
				st <= P_TOINT2;
			end

			P_TOINT2: begin
				if (ti_ovf) unimpl;                                    // rounded out of range
				else finish_with((ti_rb || ti_st) ? 5'b00001 : 5'd0, ti_w32 ? {32'd0, ti_val[31:0]} : ti_val, ti_w32, 1'b1);
			end

			P_FIN: begin
				// the product: its top 64 bits, the rest sticky
				r_sig <= macc[105:42];
				r_st  <= macc[41:0] != 42'd0;
				st <= P_NORM;
			end

			P_DONE: begin
				done <= 1'b1;
				st <= P_IDLE;
			end

			// the fast path (see above), a step a clock
			P_FAST: begin
				fx <= fx + 3'd1;
				case (fx)
				3'd0: begin
					f_mul <= q_fn[1:0] == 2'd2;
					if (q_fn[1:0] == 2'd2) begin
						f_s <= q_a[31] ^ q_b[31];
						f_e <= {2'b00, x_ea} + {2'b00, x_eb} - 10'd127;
						f_p <= x_ma * x_mb;
					end else begin
						f_s <= x_abig ? x_sa : x_sb;
						f_sub <= x_sa ^ x_sb;
						f_e <= {2'b00, x_abig ? x_ea : x_eb};
						f_big <= {1'b0, x_abig ? x_ma : x_mb, 3'b000};
						f_small <= {1'b0, x_sh[50:25], x_sh[24:0] != 25'd0};
					end
				end
				3'd1: begin
					if (f_mul) begin
						// the product is in [2^46, 2^48): its top 24 bits, guard, round, sticky
						f_zero <= 1'b0;
						if (f_p[47]) begin f_n <= {f_p[47:22], f_p[21:0] != 22'd0}; f_e <= f_e + 10'd1; end
						else f_n <= {f_p[46:21], f_p[20:0] != 21'd0};
						fx <= 3'd3;                      // (to the rounding)
					end else
						f_sum <= f_sub ? f_big - f_small : f_big + f_small;
				end
				3'd2: begin
					f_zero <= f_sum == 28'd0;
					if (f_sum[27]) begin f_n <= {f_sum[27:2], f_sum[1] | f_sum[0]}; f_e <= f_e + 10'd1; end
					else begin f_n <= f_sum[26:0] << f_lz; f_e <= f_e - {5'd0, f_lz}; end
				end
				default: begin
					if (!f_ok) begin st <= P_UNP; fx <= 3'd0; end                    // the general path
					else finish_with({4'd0, f_inexact}, {32'd0, f_zero ? 32'd0 : {f_s, f_er[7:0], f_frac}}, 1'b1, 1'b1);
				end
				endcase
			end
			default: ;
			endcase
		end
	end
endmodule

`default_nettype wire
