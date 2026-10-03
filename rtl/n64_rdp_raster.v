//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_raster.v - the RDP's rasteriser and pixel pipeline: a primitive's
// scanlines (span setup) and their pixels, as tools/n64rdp.py's span_setup,
// Primitive.run, shade_pixel and depth_blend do them.
//
// So far: FILL mode, and 1- and 2-cycle shading without textures or Z: coverage,
// the shade colour, the combiner (n64_rdp_cc.v), alpha compare, the blender
// (with its divider, n64_rdp_blut.v), dithering, the coverage the framebuffer
// keeps. One pixel at a time, over several clocks.
//
// The framebuffer is read and written a 128-bit RDRAM line at a time through a
// one-line buffer (written back, with byte enables, when the pixels leave it).
// Addresses wrap at 8 MB, as the model's RDRAM does. RDRAM's ninth bits are not
// kept (the board's DDR3 has none): they read as 3, as tools/n64rdpsim.py runs
// the model.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_raster (
	input  wire         clk,
	input  wire         rst,
	input  wire         go,
	output wire         busy,
	// the primitive (tools/n64rdp.py Tri): x in s.15, y in s.11.2
	input  wire signed [26:0] xh, xm, xl, dxhdy, dxmdy, dxldy,
	input  wire signed [13:0] yh, ym, yl,
	input  wire [2:0]   tflags,           // {skip_xfrac, do_offset, flip}
	input  wire [5:0]   tile,
	output reg  [4:0]   at_ra,            // its attributes (n64_rdp2.v attr), a clock after the address
	input  wire [31:0]  at_q,
	// the state
	input  wire [31:0]  om0, om1, comb0, comb1,
	input  wire [31:0]  fill_color, fog_color, blend_color, prim_color, env_color,
	input  wire [23:0]  key_center, key_scale,
	input  wire [8:0]   k4, k5,
	input  wire [7:0]   prim_lod_frac,
	input  wire [15:0]  prim_dz,
	input  wire [11:0]  sc_xlo, sc_ylo, sc_xhi, sc_yhi,
	input  wire         sc_field, sc_odd,
	input  wire [23:0]  fb_addr,
	input  wire [23:0]  z_addr,
	input  wire [14:0]  prim_depth,
	input  wire [9:0]   fb_width_m1,
	input  wire [2:0]   fb_fmt,
	// the tiles: the one asked for (n64_rdp2.v tile_w, tile_sz)
	output reg  [2:0]   tsel,
	input  wire [55:0]  tw,
	input  wire [47:0]  tsz,
	// TMEM's read ports (n64_rdp_tmem.v)
	output wire [10:0]  ra0, ra1, ra2, ra3,
	input  wire [15:0]  rq0, rq1, rq2, rq3,
	// RDRAM, a line at a time
	output reg          mr_req,
	input  wire         mr_ack,
	output reg  [23:0]  mr_line,
	input  wire [127:0] mr_data,
	output reg          mw_req,
	input  wire         mw_ack,
	output reg  [23:0]  mw_line,
	output reg  [127:0] mw_data,
	output reg  [15:0]  mw_mask
);
	localparam [2:0] FB_I4 = 3'd0, FB_I8 = 3'd1, FB_RGBA5551 = 3'd2, FB_IA88 = 3'd3, FB_RGBA8888 = 3'd4;

	// --- the modes (raster_flags, depth_blend_flags, static_flags) ---------------------------
	wire [1:0] cyc_type = om0[21:20];
	wire fill_mode = cyc_type == 2'd3, copy_mode = cyc_type == 2'd2, multi = cyc_type == 2'd1;
	wire aa = om1[3], cvg_ta = om1[12], acs = om1[13], alpha_test = om1[0], alpha_test_dith = om1[1];
	wire force_blend = om1[14], color_on_cvg = om1[7], image_read = om1[6];
	wire [1:0] cov_mode = om1[9:8];
	wire [1:0] dith_rgb = om0[7:6], dith_alpha = om0[5:4];
	wire db_dither = dith_rgb != 2'd3;
	wire use_prim_depth = om1[2];
	wire flip = tflags[0], do_offset = tflags[1], skip_xfrac = tflags[2];
	wire persp_en = om0[19], tlut_en = om0[15], tlut_type = om0[14], sample_quad = om0[13], mid_texel_en = om0[12];
	wire bilerp0 = om0[11], bilerp1 = om0[10];
	// which texels the combiner reads (static_flags): a cycle reads texel t when a selector
	// is t (rgb C also t + 7, its alpha); in two-cycle mode cycle 1's texels are swapped
	function rd_tex; input [3:0] a, b; input [4:0] c; input [2:0] d, aa, ab, ac, ad; input [2:0] t; begin
		rd_tex = (a == {1'b0, t}) || (b == {1'b0, t}) || (c == {2'b0, t}) || (c == {2'b0, t} + 5'd7) || (d == t)
		     || (aa == t) || (ab == t) || (ac == t) || (ad == t);
	end endfunction
	wire c0_t1 = rd_tex(comb0[23:20], comb1[31:28], comb0[19:15], comb1[17:15], comb0[14:12], comb1[14:12], comb0[11:9], comb1[11:9], 3'd1);
	wire c0_t2 = rd_tex(comb0[23:20], comb1[31:28], comb0[19:15], comb1[17:15], comb0[14:12], comb1[14:12], comb0[11:9], comb1[11:9], 3'd2);
	wire c1_t1 = rd_tex(comb0[8:5], comb1[27:24], comb0[4:0], comb1[8:6], comb1[23:21], comb1[5:3], comb1[20:18], comb1[2:0], 3'd1);
	wire c1_t2 = rd_tex(comb0[8:5], comb1[27:24], comb0[4:0], comb1[8:6], comb1[23:21], comb1[5:3], comb1[20:18], comb1[2:0], 3'd2);
	wire uses_t0 = multi ? (c0_t1 || c1_t2) : c1_t1;
	wire uses_t1 = multi ? (c0_t2 || c1_t1) : 1'b0;

	// =============================================================================
	// the per-primitive values the pixels use (loaded from attr at the start)
	// =============================================================================
	reg  signed [31:0] d_rgba_dx [0:3], d_rgba_dy [0:3];
	reg  signed [31:0] dz_dx, dz_dy;
	reg  signed [31:0] d_st_dx [0:2];    // s, t, w's x slopes (attr 20, 21, 23)
	reg  [15:0]  dzpix;                   // the primitive's depth slope
	reg  [3:0]   dz_c;                    // compressed
	function [15:0] dz_norm; input [16:0] v; integer i; begin
		if (v >= 17'h8000) dz_norm = 16'h8000;
		else if (v == 17'd0) dz_norm = 16'd1;
		else begin dz_norm = 16'd2; for (i = 1; i < 15; i = i + 1) if (v[i]) dz_norm = 16'd1 << (i + 1); end
	end endfunction
	function [3:0] dz_comp; input [15:0] dz; begin
		dz_comp = {dz[15:8] != 0, (dz & 16'hF0F0) != 0, (dz & 16'hCCCC) != 0, (dz & 16'hAAAA) != 0};
	end endfunction

	// =============================================================================
	// span setup
	// =============================================================================
	reg  signed [13:0] ym_f;              // ym, after fixup_triangle_setup
	reg  signed [13:0] y_lo, y_hi;        // in sub-scanlines: max(yh, scissor), min(yl, scissor)
	reg  signed [11:0] y, y_last;
	reg  signed [13:0] yh_ib;             // yh & ~3

	// the four sub-scanlines' edges: two multiplies a clock
	reg  [1:0]   k;
	wire signed [13:0] ys = {y, k};
	wire signed [14:0] dh = ys - yh_ib;
	wire signed [14:0] dl_l = ys - ym_f;
	wire         upper = ys < ym_f;
	reg  signed [41:0] ph, pl;
	reg  signed [26:0] xh_b, xl_b;
	always @(posedge clk) begin
		ph <= dh * dxhdy;
		pl <= upper ? dh * dxmdy : dl_l * dxldy;
		xh_b <= xh;
		xl_b <= upper ? xm : xl;
	end
	wire signed [26:0] xhk = xh_b + ph[26:0];
	wire signed [26:0] xlk = xl_b + pl[26:0];
	function signed [15:0] quant; input signed [26:0] x; begin   // to 1/8 pixel, sticky
		quant = {x[26], x[26:12]} | {15'd0, x[11:0] != 12'd0};
	end endfunction
	wire signed [15:0] hq = quant(xhk), lq = quant(xlk);
	wire signed [15:0] xl_k = flip ? hq : lq;
	wire signed [15:0] xr_k = flip ? lq : hq;
	wire signed [15:0] lo_sc = {3'd0, sc_xlo, 1'b0};
	wire signed [15:0] hi_sc = {3'd0, sc_xhi, 1'b0};
	wire         bad_k = ($signed(xl_k) >>> 1) > ($signed(xr_k) >>> 1);
	wire         clip_k = ys < y_lo || ys >= y_hi;
	wire signed [15:0] mn_k = (xl_k < xr_k) ? xl_k : xr_k;
	wire signed [15:0] mx_k = (xl_k < xr_k) ? xr_k : xl_k;
	wire signed [15:0] xlc = (xl_k < lo_sc) ? lo_sc : (xl_k > hi_sc) ? hi_sc : xl_k;
	wire signed [15:0] xrc = (xr_k < lo_sc) ? lo_sc : (xr_k > hi_sc) ? hi_sc : xr_k;
	wire         inv_k = bad_k || clip_k;
	wire [15:0]  xls_k = inv_k ? 16'hFFFF : xlc;
	wire [15:0]  xrs_k = inv_k ? 16'h0000 : xrc;

	reg  [15:0]  xleft [0:3], xright [0:3];
	reg  [15:0]  sx_min, sx_max;
	reg          all_inv, all_over, all_under;

	// the general multiplier: 32 x 16 signed, a clock
	reg  signed [31:0] m_a;
	reg  signed [15:0] m_b;
	reg  signed [47:0] m_p;
	always @(posedge clk) m_p <= m_a * m_b;

	// the span's x and attributes
	wire signed [12:0] dy_s = y - (yh >>> 2);               // y - (yh >> 2)
	reg  signed [31:0] xh_y;              // xh at this scanline (s32)
	reg  signed [16:0] base_x;
	reg  [7:0]   xfrac;
	reg  signed [31:0] sp_at [0:7];       // the span's rgba, then s, t, z, w, at base_x
	reg  [2:0]   ai;                      // which attribute: 0-3 rgba, 4-7 stzw
	wire [4:0]   abase = {ai[2], 2'b00, ai[1:0]};          // attr[] index of its value
	wire         ai_pz = use_prim_depth && ai == 3'd6;      // z, replaced by SET_PRIM_DEPTH's
	reg  signed [31:0] at_a, at_de, at_dx, at_dy;

	// =============================================================================
	// the pixel
	// =============================================================================
	wire [10:0]  width = {1'b0, fb_width_m1} + 11'd1;
	reg  [12:0]  x, x_end;
	reg  [23:0]  row_px;                  // width * y
	wire [23:0]  px = row_px + {11'd0, x};
	reg  [23:0]  baddr;
	always @(*) begin
		case (fb_fmt)
		FB_RGBA8888: baddr = {fb_addr[23:2], 2'b00} + (px << 2);     // (the model's index is fb_addr >> size)
		FB_RGBA5551, FB_IA88: baddr = {fb_addr[23:1], 1'b0} + (px << 1);
		default: baddr = fb_addr + px;
		endcase
	end
	wire [19:0]  pline = {1'b0, baddr[22:4]};
	wire [3:0]   pb = baddr[3:0];
	wire [23:0]  zaddr = {z_addr[23:1], 1'b0} + (px << 1);       // the depth image: 16 bits a pixel
	wire [19:0]  zline = {1'b0, zaddr[22:4]};
	wire [3:0]   zbi = zaddr[3:0];

	// coverage (compute_coverage): sample k is sub-scanline k >> 1 at x offsets
	// 0,4 / 2,6 / 0,4 / 2,6 (1/8 pixel); the first in scanline order is bit 0
	wire [15:0]  xs8 = {x[12:0], 3'b000};
	function cv; input [15:0] l, r, p; cv = (l <= p) && (p < r); endfunction
	wire [7:0]   cov = {cv(xleft[3], xright[3], xs8 + 16'd6), cv(xleft[3], xright[3], xs8 + 16'd2),
	                    cv(xleft[2], xright[2], xs8 + 16'd4), cv(xleft[2], xright[2], xs8),
	                    cv(xleft[1], xright[1], xs8 + 16'd6), cv(xleft[1], xright[1], xs8 + 16'd2),
	                    cv(xleft[0], xright[0], xs8 + 16'd4), cv(xleft[0], xright[0], xs8)};
	wire [3:0]   cov_n = cov[0] + cov[1] + cov[2] + cov[3] + cov[4] + cov[5] + cov[6] + cov[7];
	// the first covered sample: its offsets (_centroid)
	reg  [2:0]   fc;
	always @(*) begin
		fc = 3'd0;
		if (!cov[0]) fc = cov[1] ? 3'd1 : cov[2] ? 3'd2 : cov[3] ? 3'd3 : cov[4] ? 3'd4 : cov[5] ? 3'd5 : cov[6] ? 3'd6 : 3'd7;
	end
	wire [1:0]   yoff = fc[2:1];
	wire [1:0]   xoff = {fc[0], 1'b0} + {1'b0, fc[1]};

	// the shade colour at the pixel (interpolate_rgba): from the running sums
	reg  signed [31:0] acc_rgba [0:3];   // sp_rgba + (d & ~0x1F) * (x - base_x)
	reg  signed [31:0] acc_z;            // sp z + dz_dx * (x - base_x)
	reg  signed [31:0] acc_s, acc_t, acc_w;   // sp + (d & ~0x1F) * (x - base_x)
	reg  [17:0]  pz;                      // the pixel's z (interpolate_stz)
	function [17:0] z_at; input signed [31:0] acc, zdx, zdy; input [1:0] xo, yo;
		reg signed [31:0] sz; reg signed [18:0] v; reg signed [19:0] w;
	begin
		sz = ((acc >>> 10) <<< 2) + $signed({30'd0, xo}) * (zdx >>> 10) + $signed({30'd0, yo}) * (zdy >>> 10);
		sz = sz >>> 5;
		v = sz[18:0] - 19'sh20000;                               // sext(sz - (1 << 17), 19) + (1 << 17)
		w = {v[18], v} + 20'sh20000;
		z_at = (w < 0) ? 18'd0 : (w > 20'sh3FFFF) ? 18'h3FFFF : w[17:0];
	end endfunction
	// the depth image's line (a second one-line buffer)
	reg  [127:0] zb;  reg [15:0] zb_m;  reg [19:0] zb_line;  reg zb_v;
	wire [15:0]  zw = {zb[8 * zbi +: 8], zb[8 * (zbi + 4'd1) +: 8]};
	wire [13:0]  mem_depth = zw[15:2];
	wire [3:0]   mem_dz = {zw[1:0], 2'b11};                    // (the ninth bits as 3)
	wire         z_cmp = om1[4], z_upd = om1[5];
	wire [1:0]   z_mode = om1[11:10];
	function [4:0] msb18; input [17:0] v; integer i; begin          // msb(v), 0 for 0
		msb18 = 5'd0; for (i = 0; i < 18; i = i + 1) if (v[i]) msb18 = i;
	end endfunction
	function [17:0] z_decomp; input [13:0] z; reg [2:0] e, sh; reg [18:0] base; begin
		e = z[13:11];
		sh = (e >= 3'd6) ? 3'd0 : 3'd6 - e;
		base = 19'h40000 - (19'h40000 >> e);
		z_decomp = ({7'd0, z[10:0]} << sh) + base[17:0];
	end endfunction
	function [13:0] z_comp; input [17:0] z; reg [17:0] inv; reg [4:0] m; reg [2:0] e, sh; begin
		inv = (z == 18'h3FFFF) ? 18'd1 : 18'h3FFFF - z;
		m = msb18(inv);
		e = (m >= 5'd17) ? 3'd0 : (5'd17 - m > 5'd7) ? 3'd7 : 5'd17 - m;
		sh = (e >= 3'd6) ? 3'd0 : 3'd6 - e;
		z_comp = {e, 11'd0} + ((z >> sh) & 18'h7FF);
	end endfunction
	function [7:0] clamp9; input [31:0] c; reg signed [9:0] v; begin
		v = {1'b0, c[8:0] + 9'h80} - 10'sd128;                    // sext(c - 0x80, 9) + 0x80
		clamp9 = (v < 0) ? 8'd0 : (v > 10'sd255) ? 8'd255 : v[7:0];
	end endfunction
	function [7:0] shade_ch; input signed [31:0] acc, ddx, ddy; input [1:0] xo, yo;
		reg signed [31:0] sn;
	begin
		sn = ((acc >>> 14) <<< 2) + $signed({30'd0, xo}) * (ddx >>> 14) + $signed({30'd0, yo}) * (ddy >>> 14);
		shade_ch = clamp9(sn >>> 4);
	end endfunction

	// dithering (dither_coefficients): no noise yet
	reg  [3:0]   dm;
	always @(*) begin
		case ({dith_rgb[0], y[1:0], x[1:0]})
		5'h00: dm = 0; 5'h01: dm = 6; 5'h02: dm = 1; 5'h03: dm = 7; 5'h04: dm = 4; 5'h05: dm = 2; 5'h06: dm = 5; 5'h07: dm = 3;
		5'h08: dm = 3; 5'h09: dm = 5; 5'h0A: dm = 2; 5'h0B: dm = 4; 5'h0C: dm = 7; 5'h0D: dm = 1; 5'h0E: dm = 6; 5'h0F: dm = 0;
		5'h10: dm = 0; 5'h11: dm = 4; 5'h12: dm = 1; 5'h13: dm = 5; 5'h14: dm = 4; 5'h15: dm = 0; 5'h16: dm = 5; 5'h17: dm = 1;
		5'h18: dm = 3; 5'h19: dm = 7; 5'h1A: dm = 2; 5'h1B: dm = 6; 5'h1C: dm = 7; 5'h1D: dm = 3; 5'h1E: dm = 6; default: dm = 2;
		endcase
	end
	// (the matrix is indexed by the pixel's y with interlacing's halving: sc_field)
	wire [2:0]   dm3 = dm[2:0];
	wire [8:0]   rgb_dith = (dith_rgb < 2'd2) ? {dm3, dm3, dm3} : 9'd0;
	wire [2:0]   a_dith0 = (dith_rgb >= 2'd2) ? dm3 : rgb_dith[2:0];
	wire [2:0]   alpha_dith = (dith_alpha == 2'd3 || dith_alpha == 2'd2) ? 3'd0 : (dith_alpha == 2'd1) ? ~a_dith0 : a_dith0;

	// --- the combiner -------------------------------------------------------------------------
	reg          cyc;                     // the combiner cycle being run
	wire [31:0]  csel0 = comb0, csel1 = comb1;
	wire [3:0]   s_a = cyc ? csel0[8:5]   : csel0[23:20];
	wire [3:0]   s_b = cyc ? csel1[27:24] : csel1[31:28];
	wire [4:0]   s_c = cyc ? csel0[4:0]   : csel0[19:15];
	wire [2:0]   s_d = cyc ? csel1[8:6]   : csel1[17:15];
	wire [2:0]   s_aa = cyc ? csel1[23:21] : csel0[14:12];
	wire [2:0]   s_ab = cyc ? csel1[5:3]   : csel1[14:12];
	wire [2:0]   s_ac = cyc ? csel1[20:18] : csel0[11:9];
	wire [2:0]   s_ad = cyc ? csel1[2:0]   : csel1[11:9];
	wire [26:0]  k_a, k_b, k_c, k_d;  wire [8:0] k_aa, k_ab, k_ac, k_ad;
	n64_rdp_ccconst u_cck (.sa(s_a), .sb(s_b), .sc(s_c), .sd(s_d), .aa(s_aa), .ab(s_ab), .ac(s_ac), .ad(s_ad),
		.prim(prim_color), .env(env_color), .key_center(key_center), .key_scale(key_scale), .k4(k4), .k5(k5),
		.prim_lod_frac(prim_lod_frac), .ka(k_a), .kb(k_b), .kc(k_c), .kd(k_d),
		.kaa(k_aa), .kab(k_ab), .kac(k_ac), .kad(k_ad));
	reg  [39:0]  cc_combined;             // the first cycle's result, unclamped
	reg  [7:0]   shade [0:3];
	wire [39:0]  cc_out;
	n64_rdp_cc u_cc (.sa(s_a), .sb(s_b), .sc(s_c), .sd(s_d), .aa(s_aa), .ab(s_ab), .ac(s_ac), .ad(s_ad),
		.combined((multi && cyc) ? cc_combined : 40'd0),
		.texel0((multi && cyc) ? tex1 : tex0), .texel1((multi && cyc) ? tex0 : tex1),
		.shade({2'b00, shade[0], 2'b00, shade[1], 2'b00, shade[2], 2'b00, shade[3]}),
		.lod_frac(9'd0), .noise(9'h020),
		.ka(k_a), .kb(k_b), .kc(k_c), .kd(k_d), .kaa(k_aa), .kab(k_ab), .kac(k_ac), .kad(k_ad), .out(cc_out));
	reg  [7:0]   comb [0:3];              // the combined colour, 8-bit
	reg  [3:0]   cc;                      // the coverage count
	reg  [7:0]   alpha_ref;

	// --- the texels: the perspective divide and the sampler --------------------------------------
	reg  signed [15:0] ps, pt, pw;
	wire signed [16:0] pso, pto;  wire povf;
	n64_rdp_persp u_persp (.clk(clk), .s(ps), .t(pt), .w(pw), .so(pso), .to(pto), .overflow(povf));
	reg  signed [16:0] ss, tt;            // the texture coordinates at the pixel
	reg          tx_go, tx_b1;            // (tx_b1: the sampler's bilerp, by the texel)
	wire         tx_done;
	wire [39:0]  tx_out;
	reg  [39:0]  tex0, tex1;
	n64_rdp_tex u_tex (.clk(clk), .rst(rst), .go(tx_go), .done(tx_done), .s_in(ss), .t_in(tt),
		.tw(tw), .tsz(tsz), .tlut(tlut_en), .tlut_type(tlut_type), .sample_quad(sample_quad),
		.mid_texel_en(mid_texel_en), .bilerp(tx_b1),
		.ra0(ra0), .ra1(ra1), .ra2(ra2), .ra3(ra3), .rq0(rq0), .rq1(rq1), .rq2(rq2), .rq3(rq3), .texel(tx_out));

	// --- memory: the framebuffer's line ---------------------------------------------------------
	reg  [127:0] lb;  reg [15:0] lb_m;  reg [19:0] lb_line;  reg lb_v, lb_full;   // lb_full: read in
	// the pixel in it (load_color, decode_memory_color, with the ninth bits read as 3)
	wire [7:0]   by0 = lb[8 * pb +: 8], by1 = lb[8 * (pb + 4'd1) +: 8];
	wire [7:0]   by2 = lb[8 * (pb + 4'd2) +: 8], by3 = lb[8 * (pb + 4'd3) +: 8];
	wire [15:0]  w16 = {by0, by1};
	reg  [7:0]   mem_r, mem_g, mem_b, mem_a;      // memory, as the blender sees it
	always @(*) begin
		case (fb_fmt)
		FB_RGBA5551: begin
			mem_r = {w16[15:11], 3'd0}; mem_g = {w16[10:6], 3'd0}; mem_b = {w16[5:1], 3'd0};
			mem_a = image_read ? {w16[0], 2'b11, 5'd0} : 8'hE0;
		end
		FB_IA88: begin mem_r = by0; mem_g = by0; mem_b = by0; mem_a = image_read ? {by1[7:5], 5'd0} : 8'hE0; end
		FB_RGBA8888: begin mem_r = by0; mem_g = by1; mem_b = by2; mem_a = image_read ? {by3[7:5], 5'd0} : 8'hE0; end
		FB_I8: begin mem_r = by0; mem_g = by0; mem_b = by0; mem_a = 8'hE0; end
		default: begin mem_r = 8'd0; mem_g = 8'd0; mem_b = 8'd0; mem_a = 8'hE0; end
		endcase
	end
	wire [2:0]   mem_cov = mem_a[7:5];

	// --- the blender (blender) -------------------------------------------------------------------
	reg          bcyc;                    // the blender cycle: 0, or 1 the final
	reg  [7:0]   bpix [0:3];              // the pixel going in (combined, or cycle 0's rgb)
	reg  [7:0]   shade_alpha;
	wire [31:0]  m1 = om1;
	wire [1:0]   bm0 = (multi && !bcyc) ? m1[31:30] : multi ? m1[29:28] : m1[31:30];
	wire [1:0]   bm1 = (multi && !bcyc) ? m1[27:26] : multi ? m1[25:24] : m1[27:26];
	wire [1:0]   bm2 = (multi && !bcyc) ? m1[23:22] : multi ? m1[21:20] : m1[23:22];
	wire [1:0]   bm3 = (multi && !bcyc) ? m1[19:18] : multi ? m1[17:16] : m1[19:18];
	wire         final_cycle = !multi || bcyc;
	reg          blend_en, cov_wrap, z_fail;
	reg  [2:0]   bsh_a, bsh_b;
	function [23:0] src_rgb; input [1:0] m; input [7:0] pr, pg, pbl, mr, mg, mb; input [31:0] bc, fg; begin
		case (m)
		2'd0: src_rgb = {pr, pg, pbl};
		2'd1: src_rgb = {mr, mg, mb};
		2'd2: src_rgb = bc[31:8];
		default: src_rgb = fg[31:8];
		endcase
	end endfunction
	wire [23:0]  rgb1 = src_rgb(bm2, bpix[0], bpix[1], bpix[2], mem_r, mem_g, mem_b, blend_color, fog_color);
	wire [23:0]  rgb0 = src_rgb(bm0, bpix[0], bpix[1], bpix[2], mem_r, mem_g, mem_b, blend_color, fog_color);
	wire [7:0]   a0f = (bm1 == 2'd0) ? bpix[3] : (bm1 == 2'd1) ? fog_color[7:0] : (bm1 == 2'd2) ? shade_alpha : 8'd0;
	wire [7:0]   a1f = (bm3 == 2'd0) ? ~a0f : (bm3 == 2'd1) ? mem_a : (bm3 == 2'd2) ? 8'hFF : 8'd0;
	wire [4:0]   a0s = a0f[7:3], a1s = a1f[7:3];
	wire [4:0]   a0 = (bm3 == 2'd1) ? ((a0s >> bsh_a) & 5'h1C) : a0s;     // (& 0x3C, of five bits)
	wire [4:0]   a1 = (bm3 == 2'd1) ? ((a1s >> bsh_b) | 5'd3) : a1s;
	wire [13:0]  bl_r = rgb0[23:16] * a0 + rgb1[23:16] * ({1'b0, a1} + 6'd1);
	wire [13:0]  bl_g = rgb0[15:8] * a0 + rgb1[15:8] * ({1'b0, a1} + 6'd1);
	wire [13:0]  bl_b = rgb0[7:0] * a0 + rgb1[7:0] * ({1'b0, a1} + 6'd1);
	wire [3:0]   bsum = {1'b0, a0[4:2]} + {1'b0, a1[4:2]} + 4'd1;
	wire         b_direct1 = final_cycle && color_on_cvg && !cov_wrap;                         // -> rgb1
	wire         b_direct0 = final_cycle && (!blend_en || (bm1 == 2'd0 && bm3 == 2'd0 && bpix[3] == 8'hFF));   // -> rgb0
	wire         b_shift = !final_cycle || force_blend;                                       // -> >> 5
	reg  [14:0]  lut_a;
	wire [7:0]   lut_q;
	n64_rdp_blut u_blut (.clk(clk), .a(lut_a), .q(lut_q));
	reg  [7:0]   brgb [0:2];              // the blender's result
	reg  [13:0]  bl_hold [0:2];
	reg  [3:0]   bsum_hold;

	// the dithered colour and the coverage stored (rgb_dither, blend_coverage)
	function [7:0] dith1; input [7:0] c; input [2:0] d; reg [8:0] up; begin
		up = (c > 8'd247) ? 9'd255 : {1'b0, c[7:3], 3'b000} + 9'd8;
		dith1 = (d < c[2:0]) ? up[7:0] : c;
	end endfunction
	wire [4:0]   cov_sum = {2'b00, mem_cov} + {1'b0, cc};
	wire [2:0]   new_cov = (cov_mode == 2'd0) ? (blend_en ? ((cov_sum > 5'd7) ? 3'd7 : cov_sum[2:0]) : cc[2:0] - 3'd1)
	                     : (cov_mode == 2'd1) ? cc[2:0] + mem_cov : (cov_mode == 2'd2) ? 3'd7 : mem_cov;

	// the fill colour's bytes for this pixel (fill_pixel_color, store_color)
	wire [31:0]  fc32 = fill_color;
	reg  [31:0]  pbytes;
	reg  [2:0]   pn;
	always @(*) begin
		case (fb_fmt)
		FB_RGBA8888: begin pbytes = fc32; pn = 3'd4; end
		FB_RGBA5551, FB_IA88: begin pbytes = {baddr[1] ? fc32[15:0] : fc32[31:16], 16'd0}; pn = 3'd2; end
		FB_I8: begin pbytes = {fc32[8 * (3 - baddr[1:0]) +: 8], 24'd0}; pn = 3'd1; end
		default: begin pbytes = 32'd0; pn = 3'd0; end
		endcase
	end

	// =============================================================================
	// the sequence
	// =============================================================================
	localparam [4:0] S_IDLE = 5'd0, S_PRIM = 5'd1, S_Y = 5'd2, S_K0 = 5'd3, S_K1 = 5'd4, S_SPAN = 5'd5,
	                 S_ATTR = 5'd6, S_AINIT = 5'd7, S_PIX = 5'd8, S_NEXT = 5'd9, S_FLUSH = 5'd10, S_FWAIT = 5'd11,
	                 S_DONE = 5'd12, P_SHADE = 5'd13, P_CC0 = 5'd14, P_CC1 = 5'd15, P_MEM = 5'd16, P_RWAIT = 5'd17,
	                 P_BL = 5'd18, P_DIV = 5'd19, P_ST = 5'd20, S_LINE = 5'd21,
	                 S_ZFLUSH = 5'd22, P_ZWAIT = 5'd23, S_ZEND = 5'd24, P_ZT = 5'd25,
	                 P_TC = 5'd26, P_TX0 = 5'd27, P_TX1 = 5'd28;
	reg  [4:0]   st, st_after;
	reg  [3:0]   sub;                     // a step within a state
	assign busy = st != S_IDLE;
	integer      i;

	always @(posedge clk) begin
		if (mw_ack) mw_req <= 1'b0;
		if (mr_ack) mr_req <= 1'b0;
		tx_go <= 1'b0;
		if (rst) begin
			st <= S_IDLE; mw_req <= 1'b0; mr_req <= 1'b0; lb_v <= 1'b0; lb_m <= 16'd0; zb_v <= 1'b0; zb_m <= 16'd0; at_ra <= 5'd0;
		end else case (st)
		S_IDLE: if (go) begin : setup
			reg signed [13:0] ymf, lo, hi;
			ymf = (ym < (yh & ~14'sd3)) ? 14'sd8191 : ym;   // (0x7FFF: past every scanline)
			lo = (yh > $signed({2'b00, sc_ylo})) ? yh : $signed({2'b00, sc_ylo});
			hi = (yl < $signed({2'b00, sc_yhi})) ? yl : $signed({2'b00, sc_yhi});
			ym_f <= ymf; y_lo <= lo; y_hi <= hi;
			yh_ib <= yh & ~14'sd3;
			y <= lo >>> 2;
			y_last <= (hi - 14'sd1) >>> 2;
			sub <= 4'd0; at_ra <= 5'd4;
			if ((((hi - 14'sd1) >>> 2) < (lo >>> 2)) || copy_mode) st <= S_DONE;
			else st <= fill_mode ? S_Y : S_PRIM;
		end
		// the per-primitive values: drgba_dx (attr 4-7), drgba_dy (12-15), dz dx/dy (22, 30)
		S_PRIM: begin
			sub <= sub + 4'd1;
			// (the addresses in turn: 4-7, 12-15, 22, 30, 20, 21, 23 -- this one's, the next set)
			case (sub)
			4'd0: at_ra <= 5'd5;  4'd1: at_ra <= 5'd6;  4'd2: at_ra <= 5'd7;  4'd3: at_ra <= 5'd12;
			4'd4: at_ra <= 5'd13; 4'd5: at_ra <= 5'd14; 4'd6: at_ra <= 5'd15; 4'd7: at_ra <= 5'd22;
			4'd8: at_ra <= 5'd30; 4'd9: at_ra <= 5'd20; 4'd10: at_ra <= 5'd21; default: at_ra <= 5'd23;
			endcase
			if (sub == 4'd11) d_st_dx[0] <= at_q;
			if (sub == 4'd12) d_st_dx[1] <= at_q;
			if (sub == 4'd13) begin d_st_dx[2] <= at_q; st <= S_Y; end
			if (sub >= 4'd1 && sub <= 4'd4) d_rgba_dx[sub - 4'd1] <= at_q;
			if (sub >= 4'd5 && sub <= 4'd8) d_rgba_dy[sub - 4'd5] <= at_q;
			if (sub == 4'd9) dz_dx <= at_q;
			if (sub == 4'd10) begin : dz
				reg signed [15:0] zx, zy; reg [16:0] sum;
				// (z's slopes, which SET_PRIM_DEPTH replaces with none: after their dz is taken)
				dz_dy <= use_prim_depth ? 32'sd0 : at_q;
				if (use_prim_depth) dz_dx <= 32'sd0;
				zx = dz_dx >>> 16; zy = $signed(at_q) >>> 16;
				sum = (zx < 0 ? {2'd0, ~zx[14:0]} : {1'b0, zx}) + (zy < 0 ? {2'd0, ~zy[14:0]} : {1'b0, zy});
				dzpix <= use_prim_depth ? prim_dz : dz_norm(sum);
				dz_c <= dz_comp(use_prim_depth ? prim_dz : dz_norm(sum));
			end
		end
		S_Y: begin
			k <= 2'd0; all_inv <= 1'b1; all_over <= 1'b1; all_under <= 1'b1;
			sx_min <= 16'hFFFF; sx_max <= 16'd0;
			row_px <= width * y[9:0];
			// xh at this scanline: xh + dy * (dxhdy << 2)
			m_a <= {{3{dxhdy[26]}}, dxhdy, 2'b00}; m_b <= {{3{dy_s[12]}}, dy_s};
			st <= S_K0;
		end
		S_K0: st <= S_K1;
		S_K1: begin
			xleft[k] <= xls_k; xright[k] <= xrs_k;
			if (xls_k < sx_min) sx_min <= xls_k;
			if (xrs_k > sx_max) sx_max <= xrs_k;
			if (!inv_k) all_inv <= 1'b0;
			if (mn_k < hi_sc) all_over <= 1'b0;
			if (mx_k >= lo_sc) all_under <= 1'b0;
			if (k == 2'd0) begin : xhy
				reg signed [31:0] v;
				v = {{5{xh[26]}}, xh} + m_p[31:0] + (do_offset ? 32'sd3 * {{5{dxhdy[26]}}, dxhdy} : 32'sd0);
				xh_y <= v;
				base_x <= v >>> 15;
				xfrac <= skip_xfrac ? 8'd0 : v[14:7];
			end
			k <= k + 2'd1;
			st <= (k == 2'd3) ? S_SPAN : S_K0;
		end
		S_SPAN: begin
			x <= sx_min[15:3];
			x_end <= (sx_max[15:3] > {2'd0, width} - 13'd1) ? {2'd0, width} - 13'd1 : sx_max[15:3];
			sub <= 4'd0; ai <= 3'd0; at_ra <= 5'd0;
			if (all_inv || all_over || all_under || (sc_field && (y[0] != sc_odd))) st <= S_LINE;
			else if (sx_min[15:3] > ((sx_max[15:3] > {2'd0, width} - 13'd1) ? {2'd0, width} - 13'd1 : sx_max[15:3])) st <= S_LINE;
			else st <= fill_mode ? S_PIX : S_ATTR;
		end
		// the span's attributes: ((a + dy * de) & ~0x1FF) + diff - xfrac * ((dx >> 8) & ~1), & ~0x3FF
		// (z with SET_PRIM_DEPTH: prim_depth << 16 and no slopes)
		S_ATTR: begin
			sub <= sub + 4'd1;
			case (sub)
			4'd0: at_ra <= abase + 5'd8;                                            // de
			4'd1: begin at_a <= ai_pz ? {1'b0, prim_depth, 16'd0} : at_q; at_ra <= abase + 5'd4; end   // (a) dx
			4'd2: begin
				at_de <= ai_pz ? 32'sd0 : at_q; at_ra <= abase + 5'd12;
				m_a <= ai_pz ? 32'sd0 : at_q; m_b <= {{3{dy_s[12]}}, dy_s};
			end
			4'd3: begin at_dx <= ai_pz ? 32'sd0 : at_q; end
			4'd4: begin at_dy <= ai_pz ? 32'sd0 : at_q; m_a <= (at_dx >>> 8) & ~32'sd1; m_b <= {8'd0, xfrac}; end
			4'd5: at_a <= (at_a + m_p[31:0]) & ~32'sh1FF;                           // (a + dy*de) & ~0x1FF
			4'd6: begin : fin
				reg signed [31:0] deh, dyh, diff;
				deh = at_de & ~32'sh1FF; dyh = at_dy & ~32'sh1FF;
				diff = do_offset ? deh - (deh >>> 2) - dyh + (dyh >>> 2) : 32'sd0;
				sp_at[ai] <= (at_a + diff - m_p[31:0]) & ~32'sh3FF;
				sub <= 4'd0;
				if (ai == 3'd7) begin sub <= 4'd0; ai <= 3'd0; st <= S_AINIT; end
				else begin ai <= ai + 3'd1; at_ra <= {ai[2] | (ai[1:0] == 2'd3), 2'b00, ai[1:0] + 2'd1}; end
			end
			default: ;
			endcase
		end
		// the running sums at the span's first pixel: sp + (d & ~0x1F) * (x - base_x), and
		// z's sp + dz * (x - base_x), unmasked
		S_AINIT: begin
			sub <= sub + 4'd1;
			if (sub < 4'd5) begin
				m_a <= (sub == 4'd4) ? dz_dx : (d_rgba_dx[sub[1:0]] & ~32'sh1F);
				m_b <= $signed({3'd0, x}) - base_x[15:0];
			end
			if (sub >= 4'd2 && sub <= 4'd5) acc_rgba[sub - 4'd2] <= sp_at[sub - 4'd2] + m_p[31:0];
			if (sub == 4'd6) acc_z <= sp_at[6] + m_p[31:0];
			if (sub >= 4'd5 && sub < 4'd8) begin m_a <= d_st_dx[sub - 4'd5] & ~32'sh1F; m_b <= $signed({3'd0, x}) - base_x[15:0]; end
			if (sub == 4'd7) acc_s <= sp_at[4] + m_p[31:0];
			if (sub == 4'd8) acc_t <= sp_at[5] + m_p[31:0];
			if (sub == 4'd9) begin acc_w <= sp_at[7] + m_p[31:0]; st <= S_PIX; end
		end
		S_PIX: begin
			if (fill_mode) begin
				// a FILL pixel into the line held, flushing it first if it is another
				if (lb_v && lb_line != pline) begin
					st_after <= S_PIX; st <= S_FLUSH;
				end else begin
					if (!lb_v) begin lb_v <= 1'b1; lb_full <= 1'b0; lb_line <= pline; lb_m <= 16'd0; end
					for (i = 0; i < 4; i = i + 1)
						if (i < pn) begin
							lb[8 * (pb + i) +: 8] <= pbytes[31 - 8 * i -: 8];
							lb_m[pb + i] <= 1'b1;
						end
					st <= S_NEXT;
				end
			end else begin
				// coverage: none, or (without AA) not the first sample: no pixel
				cc <= cov_n;
				if (cov == 8'd0 || (!aa && !cov[0])) st <= S_NEXT;
				else st <= P_SHADE;
			end
		end
		P_SHADE: begin
			for (i = 0; i < 4; i = i + 1) shade[i] <= shade_ch(acc_rgba[i], d_rgba_dx[i], d_rgba_dy[i], xoff, yoff);
			pz <= z_at(acc_z, dz_dx, dz_dy, xoff, yoff);
			cyc <= !multi;
			ps <= acc_s[31:16]; pt <= acc_t[31:16]; pw <= acc_w[31:16];
			tex0 <= 40'd0; tex1 <= 40'd0; sub <= 4'd0;
			st <= (uses_t0 || uses_t1) ? P_TC : multi ? P_CC0 : P_CC1;
		end
		// the texture coordinates: through the divide (two clocks) or straight
		P_TC: begin
			sub <= sub + 4'd1;
			if (!persp_en) begin ss <= {ps[15], ps}; tt <= {pt[15], pt}; end
			else begin ss <= pso; tt <= pto; end
			if (!persp_en || sub == 4'd2) begin
				tsel <= tile[2:0]; tx_b1 <= bilerp0; tx_go <= 1'b1; st <= P_TX0;
			end
		end
		P_TX0: if (tx_done) begin
			tex0 <= tx_out;
			if (uses_t1) begin tsel <= tile[2:0] + 3'd1; tx_b1 <= bilerp1; tx_go <= 1'b1; st <= P_TX1; end
			else st <= multi ? P_CC0 : P_CC1;
		end
		P_TX1: if (tx_done) begin tex1 <= tx_out; st <= multi ? P_CC0 : P_CC1; end
		P_CC0: begin
			// cycle 0 (two-cycle mode): its result, unclamped, for cycle 1; the alpha
			// compare's reference
			cc_combined <= cc_out;
			begin : ref
				reg [7:0] ca; reg [9:0] ea; reg [13:0] pr;
				ca = clamp9({{22{cc_out[9]}}, cc_out[9:0]});
				ea = {2'b00, ca} + {9'd0, ca == 8'hFF};
				pr = ({4'd0, ea} * {10'd0, cc} + 14'd4) >> 3;
				if (acs) ea = cvg_ta ? pr[9:0] : {1'b0, cc, 5'd0};
				else ea = ea + {7'd0, alpha_dith};
				alpha_ref <= (ea > 10'd255) ? 8'd255 : ea[7:0];
			end
			cyc <= 1'b1;
			st <= P_CC1;
		end
		P_CC1: begin : c1
			reg [7:0] c3; reg [9:0] ea, md; reg [3:0] ncc; reg [13:0] pr;
			comb[0] <= clamp9({{22{cc_out[39]}}, cc_out[39:30]});
			comb[1] <= clamp9({{22{cc_out[29]}}, cc_out[29:20]});
			comb[2] <= clamp9({{22{cc_out[19]}}, cc_out[19:10]});
			c3 = clamp9({{22{cc_out[9]}}, cc_out[9:0]});
			ea = {2'b00, c3} + {9'd0, c3 == 8'hFF};
			ncc = cc;
			pr = ({4'd0, ea} * {10'd0, cc} + 14'd4) >> 3;
			if (cvg_ta) begin md = pr[9:0]; ncc = md[8:5]; end
			else md = {1'b0, cc, 5'd0};
			if (acs) ea = md; else ea = ea + {7'd0, alpha_dith};
			comb[3] <= (ea > 10'd255) ? 8'd255 : ea[7:0];
			cc <= ncc;
			if (!multi) alpha_ref <= (ea > 10'd255) ? 8'd255 : ea[7:0];
			// no pixel: AA with no coverage left, or alpha compare (against the blend colour)
			if ((aa && ncc == 4'd0) ||
			    (alpha_test && (multi ? alpha_ref : ((ea > 10'd255) ? 8'd255 : ea[7:0])) < blend_color[7:0])) st <= S_NEXT;
			else st <= P_MEM;
		end
		P_MEM: begin
			// the framebuffer's line in the buffer
			if (lb_v && lb_line != pline) begin st_after <= P_MEM; st <= S_FLUSH; end
			else if (!lb_v || !lb_full) begin
				mr_req <= 1'b1; mr_line <= {4'd0, pline}; lb_line <= pline; st <= P_RWAIT;
			end else if ((z_cmp || z_upd) && zb_v && zb_line != zline) begin
				st_after <= P_MEM; st <= S_ZFLUSH;
			end else if ((z_cmp || z_upd) && !zb_v) begin
				mr_req <= 1'b1; mr_line <= {4'd0, zline}; zb_line <= zline; st <= P_ZWAIT;
			end else begin
				// depth_test
				begin : dt
					reg ovf, ok, coplanar, farther, nearer, front, max_z;
					reg [17:0] mz; reg [16:0] mdz; reg [15:0] cdz; reg [19:0] cdz8; reg [3:0] prec;
					reg [3:0] shd; reg [4:0] sh; reg [3:0] coeff; reg [7:0] ncc;
					ovf = ({1'b0, cc} + {2'b00, mem_cov}) >= 5'd8;
					cov_wrap <= ovf;
					if (z_cmp) begin
						mz = z_decomp(mem_depth);
						mdz = 17'd1 << mem_dz;
						prec = {1'b0, mem_depth[13:11]};
						coplanar = 1'b0;
						bsh_a <= (dz_c > mem_dz) ? ((dz_c - mem_dz > 4'd4) ? 3'd4 : dz_c - mem_dz) : 3'd0;
						bsh_b <= (mem_dz > dz_c) ? ((mem_dz - dz_c > 4'd4) ? 3'd4 : mem_dz - dz_c) : 3'd0;
						if (prec < 4'd3) begin
							if (mdz != 17'h8000) mdz = ((mdz << 1) > (17'd16 >> prec)) ? (mdz << 1) : (17'd16 >> prec);
							else begin coplanar = 1'b1; mdz = 17'hFFFF; end
						end
						cdz = dzpix | mdz[15:0];
						cdz8 = (cdz == 16'd0) ? 20'd0 : (20'd1 << msb18({2'd0, cdz})) << 3;
						farther = coplanar || ({2'd0, pz} + cdz8) >= {2'd0, mz};
						blend_en <= force_blend || (!ovf && aa && farther);
						max_z = mz == 18'h3FFFF;
						front = pz < mz;
						nearer = coplanar || ($signed({2'd0, pz}) - $signed(cdz8)) <= $signed({2'd0, mz});
						ncc = {4'd0, cc};
						case (z_mode)
						2'd0: ok = max_z || (ovf ? front : nearer);
						2'd1: begin
							if (!front || !farther || !ovf) ok = max_z || (ovf ? front : nearer);
							else begin
								sh = (cdz == 16'd0) ? 5'd0 : msb18({2'd0, cdz});
								coeff = (mz >> sh) - (pz >> sh);
								ncc = ({4'd0, coeff} * {4'd0, cc}) >> 3;
								if (ncc > 8'd8) ncc = 8'd8;
								ok = 1'b1;
							end
						end
						2'd2: ok = front || max_z;
						default: ok = farther && nearer && !max_z;
						endcase
					end else begin
						ok = 1'b1; ncc = {4'd0, cc};
						blend_en <= force_blend || (!ovf && aa);
						bsh_a <= 3'd0;
						bsh_b <= (4'hF - dz_c > 4'd4) ? 3'd4 : 4'hF - dz_c;
					end
					cc <= ncc[3:0];
					if (!ok || (aa && ncc == 8'd0)) z_fail <= 1'b1; else z_fail <= 1'b0;
				end
				bpix[0] <= comb[0]; bpix[1] <= comb[1]; bpix[2] <= comb[2]; bpix[3] <= comb[3];
				shade_alpha <= ({1'b0, shade[3]} + {6'd0, alpha_dith} > 9'd255) ? 8'd255 : shade[3] + {5'd0, alpha_dith};
				bcyc <= 1'b0; sub <= 4'd0;
				st <= P_ZT;
			end
		end
		P_ZT: st <= z_fail ? S_NEXT : P_BL;                 // (the depth test's verdict)
		P_ZWAIT: if (mr_ack) begin zb <= mr_data; zb_m <= 16'd0; zb_v <= 1'b1; st <= P_MEM; end
		P_RWAIT: if (mr_ack) begin
			// (the bytes already written into it this span stay)
			for (i = 0; i < 16; i = i + 1) if (!(lb_v && lb_m[i])) lb[8 * i +: 8] <= mr_data[8 * i +: 8];
			if (!lb_v) lb_m <= 16'd0;
			lb_v <= 1'b1; lb_full <= 1'b1;
			st <= P_MEM;
		end
		P_BL: begin
			// one blender cycle (cycle 0 of two non-final; the final one)
			if (b_direct1 || (!b_direct1 && b_direct0) || b_shift) begin
				brgb[0] <= b_direct1 ? rgb1[23:16] : b_direct0 ? rgb0[23:16] : bl_r[12:5];
				brgb[1] <= b_direct1 ? rgb1[15:8]  : b_direct0 ? rgb0[15:8]  : bl_g[12:5];
				brgb[2] <= b_direct1 ? rgb1[7:0]   : b_direct0 ? rgb0[7:0]   : bl_b[12:5];
				if (!final_cycle) begin
					bpix[0] <= bl_r[12:5]; bpix[1] <= bl_g[12:5]; bpix[2] <= bl_b[12:5];
					bcyc <= 1'b1;
				end else st <= P_ST;
			end else begin
				bl_hold[0] <= bl_r; bl_hold[1] <= bl_g; bl_hold[2] <= bl_b; bsum_hold <= bsum;
				sub <= 4'd0; st <= P_DIV;
			end
		end
		P_DIV: begin
			// the divider, a channel a clock (the ROM answers a clock after its address)
			sub <= sub + 4'd1;
			if (sub < 4'd3) lut_a <= {bsum_hold, bl_hold[sub[1:0]][12:2]};
			if (sub >= 4'd2 && sub <= 4'd4) brgb[sub - 4'd2] <= lut_q;
			if (sub == 4'd4) st <= P_ST;
		end
		P_ST: begin
			// dither, and the colour and its coverage into the line
			begin : stc
				reg [7:0] r, g, b; reg [7:0] a8;
				r = db_dither ? dith1(brgb[0], rgb_dith[2:0]) : brgb[0];
				g = db_dither ? dith1(brgb[1], rgb_dith[5:3]) : brgb[1];
				b = db_dither ? dith1(brgb[2], rgb_dith[8:6]) : brgb[2];
				a8 = {new_cov, 5'd0};
				case (fb_fmt)
				FB_RGBA5551: begin
					lb[8 * pb +: 8] <= {r[7:3], g[7:5]};
					lb[8 * (pb + 4'd1) +: 8] <= {g[4:3], b[7:3], new_cov[2]};
					lb_m[pb] <= 1'b1; lb_m[pb + 4'd1] <= 1'b1;
				end
				FB_IA88: begin
					lb[8 * pb +: 8] <= r; lb[8 * (pb + 4'd1) +: 8] <= a8;
					lb_m[pb] <= 1'b1; lb_m[pb + 4'd1] <= 1'b1;
				end
				FB_RGBA8888: begin
					lb[8 * pb +: 8] <= r; lb[8 * (pb + 4'd1) +: 8] <= g;
					lb[8 * (pb + 4'd2) +: 8] <= b; lb[8 * (pb + 4'd3) +: 8] <= a8;
					lb_m[pb] <= 1'b1; lb_m[pb + 4'd1] <= 1'b1; lb_m[pb + 4'd2] <= 1'b1; lb_m[pb + 4'd3] <= 1'b1;
				end
				FB_I8: begin lb[8 * pb +: 8] <= (pb[0] ? g : r); lb_m[pb] <= 1'b1; end
				default: ;
				endcase
			end
			if (z_upd) begin : zst                           // store_depth
				reg [15:0] w;
				w = {z_comp(pz), dz_c[3:2]};
				zb[8 * zbi +: 8] <= w[15:8]; zb[8 * (zbi + 4'd1) +: 8] <= w[7:0];
				zb_m[zbi] <= 1'b1; zb_m[zbi + 4'd1] <= 1'b1;
			end
			st <= S_NEXT;
		end
		S_NEXT: begin
			// the next pixel; at the span's end, the next scanline
			for (i = 0; i < 4; i = i + 1) acc_rgba[i] <= acc_rgba[i] + (d_rgba_dx[i] & ~32'sh1F);
			acc_z <= acc_z + dz_dx;
			acc_s <= acc_s + (d_st_dx[0] & ~32'sh1F);
			acc_t <= acc_t + (d_st_dx[1] & ~32'sh1F);
			acc_w <= acc_w + (d_st_dx[2] & ~32'sh1F);
			if (x >= x_end) st <= S_LINE;
			else begin x <= x + 13'd1; st <= S_PIX; end
		end
		S_LINE: begin
			if (y == y_last) begin st_after <= S_ZEND; st <= lb_v ? S_FLUSH : S_ZEND; end
			else begin y <= y + 12'sd1; st <= S_Y; end
		end
		S_FLUSH: begin
			if (lb_m != 16'd0) begin
				mw_req <= 1'b1; mw_line <= {4'd0, lb_line}; mw_data <= lb; mw_mask <= lb_m;
				st <= S_FWAIT;
			end else st <= st_after;
			lb_v <= 1'b0; lb_full <= 1'b0; lb_m <= 16'd0;
		end
		S_FWAIT: if (mw_ack) st <= st_after;
		S_ZFLUSH: begin
			if (zb_m != 16'd0) begin
				mw_req <= 1'b1; mw_line <= {4'd0, zb_line}; mw_data <= zb; mw_mask <= zb_m;
				st <= S_FWAIT;
			end else st <= st_after;
			zb_v <= 1'b0; zb_m <= 16'd0;
		end
		S_ZEND: begin st_after <= S_DONE; st <= zb_v ? S_ZFLUSH : S_DONE; end
		S_DONE: st <= S_IDLE;
		default: st <= S_IDLE;
		endcase
	end
endmodule

`default_nettype wire
