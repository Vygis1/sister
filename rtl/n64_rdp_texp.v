//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_texp.v - the RDP's texture sampler, pipelined: a texel a clock. The same
// arithmetic as tools/n64/n64rdp.py sample_texture (texture.h) -- the coordinates
// shifted, clamped, wrapped and mirrored; four texels read from TMEM at once (one
// per copy, n64_rdp_tmem.v), through the TLUT where there is one; and the filter
// (3-tap bilinear, the mid-texel average, or the one texel) -- in eight stages:
//
//   1 the coordinates   2 the four texels' (s, t)   3 their TMEM addresses (first read)
//   4 TMEM answers      5 the words decoded; a TLUT's entry or a 32-bit texel's second
//                         half asked for (the high half, its own ports)
//   6 TMEM answers      7 the second words           8 the filter
//
// A request presented with its tile on clock c has its texel on `texel` on clock
// c + 8. Nothing moves while ce is low (the pixel pipeline is stalled).
//
// COPY mode (copy = 1) goes the same way: the coordinates shifted but never clamped, the
// pixel's offset in the framebuffer word added to s, and out of stage 8 on `cword` the 16-bit
// word the copy pipe writes (n64rdp.py sample_texture_copy / _copy_word): the TMEM word, its
// TLUT entry, or -- the 8 and 4-bit texels, in the word's first half -- two texels a byte
// each, read by the first two ports. (an 8-bit framebuffer: cword[7:0] is the byte)
//
// Not yet: YUV, the convert stage (SET_CONVERT's K0-K3) and convert_one.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_texp (
	input  wire         clk,
	input  wire         ce,
	input  wire signed [16:0] s_in, t_in, // s10.5 (the perspective divide's, or straight)
	// the tile (SET_TILE as sent: n64_rdp2.v tile_w; SET_TILE_SIZE)
	input  wire [55:0]  tw,
	input  wire [47:0]  tsz,
	// the modes
	input  wire         tlut, tlut_type, sample_quad, mid_texel_en, bilerp,
	// COPY mode: the pixel's offset in its framebuffer word (dx & ~dx_mask); an 8-bit framebuffer
	input  wire         copy,
	input  wire [2:0]   soff,
	input  wire         fb8,
	// TMEM: the first reads (either half) and the second (the high half), a clock later
	output reg  [10:0]  fa0, fa1, fa2, fa3,
	input  wire [15:0]  fq0, fq1, fq2, fq3,
	output reg  [10:0]  sa0, sa1, sa2, sa3,
	input  wire [15:0]  sq0, sq1, sq2, sq3,
	output reg  [39:0]  texel,             // {r, g, b, a}, 10 bits each, signed
	output reg  [15:0]  cword              // COPY mode's word (beside texel)
);
	integer      i;

	// --- the tile ---------------------------------------------------------------------------
	wire [2:0]   fmt_i = tw[55:53];
	wire [1:0]   size_i = tw[52:51];
	wire [8:0]   line_i = tw[49:41];
	wire [8:0]   tmem_i = tw[40:32];
	wire [3:0]   palette_i = tw[23:20];
	wire         clamp_t_b = tw[19], mirror_t = tw[18];
	wire [3:0]   mask_t_r = tw[17:14], shift_t = tw[13:10];
	wire         clamp_s_b = tw[9], mirror_s = tw[8];
	wire [3:0]   mask_s_r = tw[7:4], shift_s = tw[3:0];
	// (SET_TILE: a mask over 10 is 10; a mask of 0 clamps)
	wire [3:0]   mask_s = (mask_s_r > 4'd10) ? 4'd10 : mask_s_r;
	wire [3:0]   mask_t = (mask_t_r > 4'd10) ? 4'd10 : mask_t_r;
	wire         clamp_s = clamp_s_b || mask_s_r == 4'd0;
	wire         clamp_t = clamp_t_b || mask_t_r == 4'd0;
	wire [11:0]  slo = tsz[47:36], tlo = tsz[35:24], shi = tsz[23:12], thi = tsz[11:0];

	// --- the coordinates (clamp_and_shift_coord, texel_mask_s/t) -----------------------------
	function signed [15:0] shift_c; input signed [16:0] c; input [3:0] sh; reg signed [16:0] cc; reg signed [31:0] w; begin
		cc = (c < -17'sd32768) ? -17'sd32768 : (c > 17'sd32767) ? 17'sd32767 : c;
		if (sh < 4'd11) shift_c = cc >>> sh;
		else begin w = {{15{cc[16]}}, cc} <<< (5'd16 - {1'b0, sh}); shift_c = w[15:0]; end
	end endfunction
	function signed [16:0] clamp_c; input clamp; input signed [16:0] c; input [3:0] sh; input [11:0] lo, hi;
		reg signed [15:0] v; reg signed [17:0] d;
	begin
		v = shift_c(c, sh);
		d = {{2{v[15]}}, v} - {3'd0, lo, 3'd0};
		if (clamp) begin
			if ((v >>> 3) >= $signed({4'd0, hi})) clamp_c = {2'b00, (hi[11:2] - lo[11:2]), 5'd0};
			else clamp_c = (d < 0) ? 17'sd0 : d[16:0];
		end else clamp_c = d[16:0];
	end endfunction
	function [10:0] mask_c; input signed [11:0] v; input [3:0] m; input mirror; reg [11:0] x, msk; begin
		x = v;
		if (m != 4'd0) begin
			msk = 12'd1 << m;
			if (mirror && (x & msk) != 12'd0) x = x ^ (msk - 12'd1);
			x = x & (msk - 12'd1);
		end
		mask_c = x[10:0];
	end endfunction

	// --- decoding (texel_*) ------------------------------------------------------------------
	function [39:0] rgba16; input [15:0] w; reg [4:0] r, g, b; begin
		r = w[15:11]; g = w[10:6]; b = w[5:1];
		rgba16 = {2'b00, r, r[4:2], 2'b00, g, g[4:2], 2'b00, b, b[4:2], 2'b00, {8{w[0]}}};
	end endfunction
	function [39:0] ia16; input [15:0] w; ia16 = {2'b00, w[15:8], 2'b00, w[15:8], 2'b00, w[15:8], 2'b00, w[7:0]}; endfunction
	function [39:0] rep4; input [7:0] v; rep4 = {2'b00, v, 2'b00, v, 2'b00, v, 2'b00, v}; endfunction
	// COPY mode's texel a byte: 8-bit the byte, 4-bit the nibble twice, else the high byte
	function [7:0] cp_samp; input [15:0] w; input bsel, nsel; input [1:0] sz; reg [7:0] b; reg [3:0] n; begin
		b = bsel ? w[7:0] : w[15:8]; n = nsel ? b[3:0] : b[7:4];
		cp_samp = (sz == 2'd1) ? b : (sz == 2'd0) ? {n, n} : w[15:8];
	end endfunction

	// --- the modes, carried down the stages: {fmt, size, line, tmem, palette, tlut,
	// tlut_type, sample_quad, bilerp} (31 bits) ------------------------------------------------
	localparam MW = 31;
	wire [MW-1:0] m_in = {fmt_i, size_i, line_i, tmem_i, palette_i, tlut, tlut_type, sample_quad, bilerp};
	reg  [MW-1:0] m1, m2, m3, m4, m5, m6, m7;
	`define M_FMT(m)  m[30:28]
	`define M_SIZE(m) m[27:26]
	`define M_LINE(m) m[25:17]
	`define M_TMEM(m) m[16:8]
	`define M_PAL(m)  m[7:4]
	`define M_TLUT(m) m[3]
	`define M_TLT(m)  m[2]
	`define M_SQ(m)   m[1]
	`define M_BL(m)   m[0]

	// --- 1: the coordinates -------------------------------------------------------------------
	// (shifted and clamped here; masked and mirrored, and the next row's offset, at the head
	// of stage 2, from what this registers -- all of it in one clock was the RDP's longest
	// path at 62.5 MHz)
	reg  signed [11:0] si_1, ti_1;
	reg  [9:0]   mk_1;                    // {mask_s, mirror_s, mask_t, mirror_t} of the request
	reg  [4:0]   fx_1, fy_1;
	reg          mid_1, upr_1, up_1;      // mid-texel; fx + fy >= 32 as fetched; and after mid-texel
	// COPY mode, down the stages: {copy, the two-texel word, the 16-bit word's offset (0-3),
	// an 8-bit framebuffer; its pixel's offset odd}
	reg  [5:0]   cp_1, cp_2, cp_3, cp_4, cp_5, cp_6, cp_7;
	wire [1:0]   so_in = fb8 ? soff[2:1] : soff[1:0];
	wire         rep_in = so_in < 2'd2 && size_i != 2'd2 && !tlut;
	always @(posedge clk) if (ce) begin : coord
		reg signed [16:0] sc, tcv;
		reg [4:0] ffx, ffy;
		sc = clamp_c(clamp_s && !copy, s_in, shift_s, slo, shi);
		tcv = clamp_c(clamp_t && !copy, t_in, shift_t, tlo, thi);
		ffx = ((sample_quad || tlut) && !copy) ? sc[4:0] : 5'd0;
		ffy = ((sample_quad || tlut) && !copy) ? tcv[4:0] : 5'd0;
		fx_1 <= ffx; fy_1 <= ffy;
		// (COPY: s + the offset; two texels from s + 2 * the offset)
		si_1 <= (sc >>> 5) + (!copy ? 12'sd0 : rep_in ? $signed({9'd0, so_in, 1'b0}) : $signed({10'd0, so_in}));
		ti_1 <= tcv >>> 5;
		cp_1 <= {copy, rep_in, so_in, fb8, soff[0]};
		mk_1 <= {mask_s, mirror_s, mask_t, mirror_t};
		mid_1 <= mid_texel_en && bilerp && ffx == 5'h10 && ffy == 5'h10;
		upr_1 <= ({1'b0, ffx} + {1'b0, ffy}) >= 6'h20;
		up_1 <= ({1'b0, ffx} + {1'b0, ffy}) >= 6'h20 && !(mid_texel_en && bilerp && ffx == 5'h10 && ffy == 5'h10);
		m1 <= m_in;
	end
	wire [10:0]  sm0_1 = mask_c(si_1, mk_1[9:6], mk_1[5]);
	wire [10:0]  sm1_1 = mask_c(si_1 + 12'sd1, mk_1[9:6], mk_1[5]);
	wire [10:0]  tm0_1 = mask_c(ti_1, mk_1[4:1], mk_1[0]);
	wire [10:0]  tm1_1 = mask_c(ti_1 + 12'sd1, mk_1[4:1], mk_1[0]);
	wire signed [11:0] tdr_1 = $signed({1'b0, tm1_1}) - $signed({1'b0, tm0_1});
	wire signed [11:0] td_1 = (tdr_1 < -12'sd255) ? -12'sd255 : tdr_1;
	wire [10:0]  s0_1 = sm0_1, s1_1 = sm1_1;
	wire signed [9:0] t0_1 = {2'b00, tm0_1[7:0]};
	wire signed [9:0] t1_1 = $signed({2'b00, tm0_1[7:0]}) + td_1[9:0];

	// --- 2: the four texels: base (s1, t1 when the fractions add to a texel or more), t10
	// (s1, t0), t01 (s0, t1), t11 (s1, t1). Without sample_quad, only the base, at (s0, t0)
	reg  [10:0]  ts_2 [0:3];  reg signed [9:0] tt_2 [0:3];
	reg  [1:0]   lo_2 [0:3];
	reg  [4:0]   fx_2, fy_2;  reg mid_2, upr_2, up_2;
	always @(posedge clk) if (ce) begin
		ts_2[0] <= up_1 ? s1_1 : s0_1;
		tt_2[0] <= up_1 ? t1_1 : t0_1;
		ts_2[1] <= s1_1; tt_2[1] <= t0_1;
		ts_2[2] <= s0_1; tt_2[2] <= t1_1;
		ts_2[3] <= s1_1; tt_2[3] <= t1_1;
		if (`M_TLUT(m1) && !`M_SQ(m1)) begin
			ts_2[1] <= s0_1; ts_2[3] <= s0_1; tt_2[2] <= t0_1; tt_2[3] <= t0_1; ts_2[0] <= s0_1; tt_2[0] <= t0_1;
		end
		lo_2[0] <= cp_1[5] ? cp_1[3:2] : up_1 ? 2'd3 : 2'd0; lo_2[1] <= 2'd1; lo_2[2] <= 2'd2; lo_2[3] <= 2'd3;
		fx_2 <= fx_1; fy_2 <= fy_1; mid_2 <= mid_1; upr_2 <= upr_1; up_2 <= up_1;
		cp_2 <= cp_1;
		m2 <= m1;
	end

	// --- 3: the first reads' addresses (_byte_index / _word_index: TMEM bytes (offset +
	// stride * t + s's bytes) & mask, odd lines swapped) ----------------------------------------
	function [11:0] byte_ix; input [11:0] sb; input signed [9:0] t; input [11:0] msk; input [11:0] offset, stride;
		reg signed [23:0] a;
	begin
		a = $signed({12'd0, offset}) + $signed({12'd0, stride}) * t + $signed({12'd0, sb});
		byte_ix = (a[11:0] & msk) ^ {9'd0, t[0], 2'b00};
	end endfunction
	function [10:0] word_ix; input [10:0] s; input signed [9:0] t; input [11:0] msk; input [11:0] offset, stride;
		reg signed [23:0] a; reg [11:0] m;
	begin
		a = $signed({12'd0, offset}) + $signed({12'd0, stride}) * t + $signed({12'd0, s, 1'b0});
		m = a[11:0] & msk;
		word_ix = m[11:1] ^ {9'd0, t[0], 1'b0};
	end endfunction
	reg  [11:0]  bix_3 [0:3];  reg [10:0] wix_3 [0:3];
	reg  [10:0]  ts_3 [0:3];   reg [1:0] lo_3 [0:3];
	reg  [4:0]   fx_3, fy_3;  reg mid_3, upr_3, up_3;
	always @(posedge clk) if (ce) begin : r1
		reg [11:0] bi; reg [10:0] wi; reg [11:0] msk;
		for (i = 0; i < 4; i = i + 1) begin
			msk = (`M_TLUT(m2) || `M_SIZE(m2) == 2'd3) ? 12'h7FF : 12'hFFF;
			if (`M_SIZE(m2) == 2'd0) bi = byte_ix({1'b0, ts_2[i][10:1]}, tt_2[i], msk, {`M_TMEM(m2), 3'b000}, {`M_LINE(m2), 3'b000});
			else bi = byte_ix({1'b0, ts_2[i]}, tt_2[i], msk, {`M_TMEM(m2), 3'b000}, {`M_LINE(m2), 3'b000});
			wi = word_ix(ts_2[i], tt_2[i], msk, {`M_TMEM(m2), 3'b000}, {`M_LINE(m2), 3'b000});
			bix_3[i] <= bi; wix_3[i] <= wi; ts_3[i] <= ts_2[i]; lo_3[i] <= lo_2[i];
			case (i)
			0: fa0 <= (`M_SIZE(m2) >= 2'd2) ? wi : bi[11:1];
			1: fa1 <= (`M_SIZE(m2) >= 2'd2) ? wi : bi[11:1];
			2: fa2 <= (`M_SIZE(m2) >= 2'd2) ? wi : bi[11:1];
			default: fa3 <= (`M_SIZE(m2) >= 2'd2) ? wi : bi[11:1];
			endcase
		end
		fx_3 <= fx_2; fy_3 <= fy_2; mid_3 <= mid_2; upr_3 <= upr_2; up_3 <= up_2;
		m3 <= m2; cp_3 <= cp_2;
	end

	// --- 4: TMEM reads (its own register) -----------------------------------------------------------
	reg  [11:0]  bix_4 [0:3];  reg [10:0] wix_4 [0:3];  reg [10:0] ts_4 [0:3];  reg [1:0] lo_4 [0:3];
	reg  [4:0]   fx_4, fy_4;  reg mid_4, upr_4, up_4;
	always @(posedge clk) if (ce) begin
		for (i = 0; i < 4; i = i + 1) begin bix_4[i] <= bix_3[i]; wix_4[i] <= wix_3[i]; ts_4[i] <= ts_3[i]; lo_4[i] <= lo_3[i]; end
		fx_4 <= fx_3; fy_4 <= fy_3; mid_4 <= mid_3; upr_4 <= upr_3; up_4 <= up_3;
		m4 <= m3; cp_4 <= cp_3;
	end

	// --- 5: the words: decoded, and (a TLUT, a 32-bit RGBA texel) the second reads ------------
	reg  [15:0]  fw_5 [0:3];
	reg  [39:0]  tx_5 [0:3];
	reg  [15:0]  cw_5;
	reg  [4:0]   fx_5, fy_5;  reg mid_5, up_5;
	always @(posedge clk) if (ce) begin : r2
		reg [15:0] w; reg [7:0] byt; reg [3:0] nib; reg [7:0] v; reg [10:0] e; reg [1:0] sz; reg [2:0] fm;
		sz = `M_SIZE(m4); fm = `M_FMT(m4);
		for (i = 0; i < 4; i = i + 1) begin
			w = (i == 0) ? fq0 : (i == 1) ? fq1 : (i == 2) ? fq2 : fq3;
			fw_5[i] <= w;
			byt = bix_4[i][0] ? w[7:0] : w[15:8];
			nib = ts_4[i][0] ? byt[3:0] : byt[7:4];
			// the second read: a TLUT's entry ((v << 2) + offset) ^ (3 when the fractions
			// add to a texel, before mid-texel), or a 32-bit texel's high half
			v = (sz == 2'd0) ? {`M_PAL(m4), nib} : (sz == 2'd1) ? byt : w[15:8];
			e = (({3'd0, v} << 2) + {9'd0, lo_4[i]}) ^ (upr_4 ? 11'd3 : 11'd0);
			if (sz[1]) e = ({1'b0, w[15:8], 2'b00} + {9'd0, lo_4[i]}) ^ (upr_4 ? 11'd3 : 11'd0);
			if (!`M_TLUT(m4)) e = wix_4[i] | 11'h400;
			case (i)
			0: sa0 <= {1'b1, e[9:0]};
			1: sa1 <= {1'b1, e[9:0]};
			2: sa2 <= {1'b1, e[9:0]};
			default: sa3 <= {1'b1, e[9:0]};
			endcase
			case ({fm == 3'd0 ? 2'd0 : fm == 3'd2 ? 2'd1 : fm == 3'd3 ? 2'd2 : 2'd3, sz})
			// RGBA
			4'b00_00: tx_5[i] <= rep4({nib, nib});
			4'b00_01: tx_5[i] <= rep4(byt);
			4'b00_10: tx_5[i] <= rgba16(w);
			// CI (no TLUT)
			4'b01_00: tx_5[i] <= rep4({`M_PAL(m4), nib});
			4'b01_01: tx_5[i] <= rep4(byt);
			// IA
			4'b10_00: tx_5[i] <= {2'b00, nib[3:1], nib[3:1], nib[3:2], 2'b00, nib[3:1], nib[3:1], nib[3:2],
			                      2'b00, nib[3:1], nib[3:1], nib[3:2], 2'b00, {8{nib[0]}}};
			4'b10_01: tx_5[i] <= {2'b00, byt[7:4], byt[7:4], 2'b00, byt[7:4], byt[7:4], 2'b00, byt[7:4], byt[7:4], 2'b00, byt[3:0], byt[3:0]};
			4'b10_10: tx_5[i] <= ia16(w);
			// I (and the other codes)
			4'b11_00: tx_5[i] <= rep4({nib, nib});
			4'b11_01: tx_5[i] <= rep4(byt);
			// the 16-bit CI and I, and every 32-bit but RGBA: w as (hi, lo, hi, lo)
			default: tx_5[i] <= {2'b00, w[15:8], 2'b00, w[7:0], 2'b00, w[15:8], 2'b00, w[7:0]};
			endcase
		end
		fx_5 <= fx_4; fy_5 <= fy_4; mid_5 <= mid_4; up_5 <= up_4;
		m5 <= m4; cp_5 <= cp_4;
		// COPY: the word; or two texels, a byte each (8-bit: the byte; 4-bit: the nibble twice;
		// 32-bit: the word's high byte)
		if (cp_4[4]) cw_5 <= {cp_samp(fq0, bix_4[0][0], ts_4[0][0], sz), cp_samp(fq1, bix_4[1][0], ts_4[1][0], sz)};
		else cw_5 <= fq0;
	end

	// --- 6: TMEM's second reads (its own register) --------------------------------------------
	reg  [15:0]  fw_6 [0:3];  reg [39:0] tx_6 [0:3];  reg [15:0] cw_6, cw_7;
	reg  [4:0]   fx_6, fy_6;  reg mid_6, up_6;
	always @(posedge clk) if (ce) begin
		for (i = 0; i < 4; i = i + 1) begin fw_6[i] <= fw_5[i]; tx_6[i] <= tx_5[i]; end
		fx_6 <= fx_5; fy_6 <= fy_5; mid_6 <= mid_5; up_6 <= up_5;
		m6 <= m5; cp_6 <= cp_5; cw_6 <= cw_5;
	end

	// --- 7: the second words: a TLUT's colour, a 32-bit texel's blue and alpha --------------
	reg  [39:0]  tx_7 [0:3];
	reg  [4:0]   fx_7, fy_7;  reg mid_7, up_7;
	always @(posedge clk) if (ce) begin
		for (i = 0; i < 4; i = i + 1) begin : w2
			reg [15:0] w;
			w = (i == 0) ? sq0 : (i == 1) ? sq1 : (i == 2) ? sq2 : sq3;
			if (`M_TLUT(m6)) tx_7[i] <= `M_TLT(m6) ? ia16(w) : rgba16(w);
			else if (`M_SIZE(m6) == 2'd3 && `M_FMT(m6) == 3'd0)
				tx_7[i] <= {2'b00, fw_6[i][15:8], 2'b00, fw_6[i][7:0], 2'b00, w[15:8], 2'b00, w[7:0]};   // RGBA32
			else tx_7[i] <= tx_6[i];
		end
		fx_7 <= fx_6; fy_7 <= fy_6; mid_7 <= mid_6; up_7 <= up_6;
		m7 <= m6; cp_7 <= cp_6;
		cw_7 <= `M_TLUT(m6) ? sq0 : cw_6;
	end

	// --- 8: the filter: mid-texel average; 3-tap bilinear; or the base texel ------------------
	always @(posedge clk) if (ce) begin : filt
		reg signed [11:0] b, a10, a01, a11, r; reg signed [17:0] acc;
		for (i = 0; i < 4; i = i + 1) begin
			b   = {{2{tx_7[0][39 - 10 * i]}}, tx_7[0][39 - 10 * i -: 10]};
			a10 = {{2{tx_7[1][39 - 10 * i]}}, tx_7[1][39 - 10 * i -: 10]};
			a01 = {{2{tx_7[2][39 - 10 * i]}}, tx_7[2][39 - 10 * i -: 10]};
			a11 = {{2{tx_7[3][39 - 10 * i]}}, tx_7[3][39 - 10 * i -: 10]};
			if (mid_7) r = (b + a01 + a10 + a11 + 12'sd2) >>> 2;
			else if (`M_BL(m7) && (`M_SQ(m7) || `M_TLUT(m7))) begin
				acc = (a10 - b) * $signed({1'b0, up_7 ? 6'd32 - {1'b0, fy_7} : {1'b0, fx_7}})
				    + (a01 - b) * $signed({1'b0, up_7 ? 6'd32 - {1'b0, fx_7} : {1'b0, fy_7}}) + 18'sd16;
				r = (acc >>> 5) + b;
			end else r = b;
			texel[39 - 10 * i -: 10] <= r[9:0];
		end
		// (an 8-bit framebuffer takes a byte: a TLUT's high one; else the offset's)
		cword <= (!cp_7[1] || (cp_7[0] && !`M_TLUT(m7))) ? cw_7 : {cw_7[15:8], cw_7[15:8]};
	end
	`undef M_FMT
	`undef M_SIZE
	`undef M_LINE
	`undef M_TMEM
	`undef M_PAL
	`undef M_TLUT
	`undef M_TLT
	`undef M_SQ
	`undef M_BL
endmodule

`default_nettype wire
