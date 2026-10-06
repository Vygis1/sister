//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_pix.v - the RDP's pixel pipeline: a span's pixels, one a clock (one every two
// in two-cycle mode, where each pixel samples two texels), through the stages the
// RDP has (the N64 Programming Manual's RS -> TX/TF -> CC -> BL -> MI). The arithmetic
// is tools/n64/n64rdp.py's, as the per-pixel state machine before it did it, one stage
// each:
//
//   A  the pixel: its coverage; the running sums (interpolate_*) step on
//   B  the shade colour, z, and s/t/w (and one pixel on in x and in y, for the LOD)
//   C  the perspective divides (three, n64_rdp_persp.v: two clocks)
//   D  the texture coordinates; the LOD and the tiles it picks
//   E.. the sampler (n64_rdp_texp.v: eight clocks)
//   M  the texels in hand (two-cycle mode: the first is held for the second)
//   N  the combiner's first cycle (two-cycle mode)   O  its result, the alpha reference
//   P  the combiner's second (or only) cycle          Q  clamped; alpha compare; the
//      span buffer read for the pixel's colour and depth lines
//   R  the depth test, the memory colour             S  the blender's first cycle
//   T  its second (or only); the divider asked        U  the divider's answer
//   V  dithered, into the line being written
//
// The framebuffer's lines come from the span buffer (n64_rdp_raster.v fetches each span's
// lines when the span starts); the written lines go out through two small queues
// (colour, depth) as the pixels leave them. Anything that has to wait -- a span's lines
// not in yet, a full queue -- stops the whole pipeline (ce low) for that clock.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_pix (
	input  wire         clk,
	input  wire         rst,
	input  wire         no_dither,        // (a setting) no colour dither, whatever the other modes say
	output wire         busy,             // a pixel in flight, or a line not yet written
	input  wire         drain,            // the primitive's spans are all in: write the last lines
	output wire         ce,               // the pipeline moves (the span buffer reads hold on low)
	// the primitive (steady while busy)
	input  wire [31:0]  om0, om1, comb0, comb1,
	input  wire [31:0]  fog_color, blend_color, prim_color, env_color,
	input  wire [23:0]  key_center, key_scale,
	input  wire [8:0]   k4, k5,
	input  wire [7:0]   prim_lod_frac,
	input  wire [4:0]   prim_min_level,
	input  wire [5:0]   tile,
	input  wire         flip,
	input  wire [2:0]   fb_fmt,
	input  wire [127:0] d_rgba_dx, d_rgba_dy,     // channel i in [127 - 32 i -: 32]
	input  wire [31:0]  dz_dx, dz_dy,
	input  wire [95:0]  d_st_dx, d_st_dy,         // s, t, w
	input  wire [15:0]  dzpix,
	input  wire [3:0]   dz_c,
	// the tiles, all eight (n64_rdp2.v tile_w, tile_sz): tile i in [.. - i * width -: width]
	input  wire [447:0] tw_all,
	input  wire [383:0] tsz_all,
	// TMEM (n64_rdp_tmem.v)
	output wire [10:0]  fa0, fa1, fa2, fa3,
	input  wire [15:0]  fq0, fq1, fq2, fq3,
	output wire [10:0]  sa0, sa1, sa2, sa3,
	input  wire [15:0]  sq0, sq1, sq2, sq3,
	// the spans: {x0, x1, xleft[0..3], xright[0..3], rgba, z, s, t, w at x0, slot}
	input  wire         sp_valid,
	output wire         sp_ready,
	input  wire [12:0]  sp_x0, sp_x1,
	input  wire [63:0]  sp_xl, sp_xr,
	input  wire [255:0] sp_acc,
	input  wire         sp_slot,
	// the span buffer's slots: each one's scanline, its first pixel's index (width * y),
	// its first colour and depth lines; whether its lines are all in
	input  wire [23:0]  sl_y,             // slot i in [12 i +: 12]
	input  wire [47:0]  sl_row,           // [24 i +: 24]
	input  wire [39:0]  sl_clo, sl_zlo,   // [20 i +: 20]
	input  wire [1:0]   sl_filled,
	output reg          rel,              // a span's last pixel has read the buffer: its slot is free
	output reg          rel_slot,
	// the span buffer, read (a clock later, held while ce is low)
	output wire [8:0]   sc_ra,            // {slot, colour line}
	input  wire [127:0] sc_q,
	output wire [7:0]   sz_ra,            // {slot, depth line}
	input  wire [127:0] sz_q,
	input  wire [23:0]  fb_addr, z_addr,
	// the lines written, a line at a time
	output reg          mw_req,
	input  wire         mw_ack,
	output reg  [23:0]  mw_line,
	output reg  [127:0] mw_data,
	output reg  [15:0]  mw_mask,
	output wire [15:0]  dbg               // {stall_mem, stall_wr, cur_v, pipe_occ, wc_v, wz_v, mw_req, sp_valid, qc, qz count (3 each), ce, drain}
);
	localparam [2:0] FB_I4 = 3'd0, FB_I8 = 3'd1, FB_RGBA5551 = 3'd2, FB_IA88 = 3'd3, FB_RGBA8888 = 3'd4;
	integer i;

	// --- the modes (raster_flags, depth_blend_flags, static_flags) ---------------------------
	wire [1:0] cyc_type = om0[21:20];
	wire multi = cyc_type == 2'd1;
	wire aa = om1[3], cvg_ta = om1[12], acs = om1[13], alpha_test = om1[0];
	wire force_blend = om1[14], color_on_cvg = om1[7], image_read = om1[6];
	wire [1:0] cov_mode = om1[9:8];
	wire [1:0] dith_rgb = om0[7:6], dith_alpha = om0[5:4];
	wire db_dither = dith_rgb != 2'd3 && !no_dither;
	wire persp_en = om0[19], tlut_en = om0[15], tlut_type = om0[14], sample_quad = om0[13], mid_texel_en = om0[12];
	wire bilerp0 = om0[11], bilerp1 = om0[10];
	wire z_cmp = om1[4], z_upd = om1[5];
	wire [1:0] z_mode = om1[11:10];
	function rd_tex; input [3:0] a, b; input [4:0] c; input [2:0] d, aa_, ab, ac, ad; input [2:0] t; begin
		rd_tex = (a == {1'b0, t}) || (b == {1'b0, t}) || (c == {2'b0, t}) || (c == {2'b0, t} + 5'd7) || (d == t)
		     || (aa_ == t) || (ab == t) || (ac == t) || (ad == t);
	end endfunction
	wire c0_t1 = rd_tex(comb0[23:20], comb1[31:28], comb0[19:15], comb1[17:15], comb0[14:12], comb1[14:12], comb0[11:9], comb1[11:9], 3'd1);
	wire c0_t2 = rd_tex(comb0[23:20], comb1[31:28], comb0[19:15], comb1[17:15], comb0[14:12], comb1[14:12], comb0[11:9], comb1[11:9], 3'd2);
	wire c1_t1 = rd_tex(comb0[8:5], comb1[27:24], comb0[4:0], comb1[8:6], comb1[23:21], comb1[5:3], comb1[20:18], comb1[2:0], 3'd1);
	wire c1_t2 = rd_tex(comb0[8:5], comb1[27:24], comb0[4:0], comb1[8:6], comb1[23:21], comb1[5:3], comb1[20:18], comb1[2:0], 3'd2);
	wire uses_t1 = multi ? (c0_t2 || c1_t1) : 1'b0;
	wire c0_lf = comb0[19:15] == 5'd13 || comb0[11:9] == 3'd0;
	wire c1_lf = comb0[4:0] == 5'd13 || comb1[20:18] == 3'd0;
	wire tex_lod_en = om0[16], sharpen = om0[17], detail = om0[18];
	wire uses_lod = (multi ? (c0_lf || c1_lf) : c1_lf) || tex_lod_en;

	// --- the arithmetic (as n64_rdp_raster.v had it) ------------------------------------------
	function cv; input [15:0] l, r, p; cv = (l <= p) && (p < r); endfunction
	function [17:0] z_at; input signed [31:0] acc, zdx, zdy; input [1:0] xo, yo;
		reg signed [31:0] sz; reg signed [18:0] v; reg signed [19:0] w;
	begin
		sz = ((acc >>> 10) <<< 2) + $signed({30'd0, xo}) * (zdx >>> 10) + $signed({30'd0, yo}) * (zdy >>> 10);
		sz = sz >>> 5;
		v = sz[18:0] - 19'sh20000;
		w = {v[18], v} + 20'sh20000;
		z_at = (w < 0) ? 18'd0 : (w > 20'sh3FFFF) ? 18'h3FFFF : w[17:0];
	end endfunction
	function [4:0] msb18; input [17:0] v; integer k; begin
		msb18 = 5'd0; for (k = 0; k < 18; k = k + 1) if (v[k]) msb18 = k;
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
		v = {1'b0, c[8:0] + 9'h80} - 10'sd128;
		clamp9 = (v < 0) ? 8'd0 : (v > 10'sd255) ? 8'd255 : v[7:0];
	end endfunction
	function [7:0] shade_ch; input signed [31:0] acc, ddx, ddy; input [1:0] xo, yo;
		reg signed [31:0] sn;
	begin
		sn = ((acc >>> 14) <<< 2) + $signed({30'd0, xo}) * (ddx >>> 14) + $signed({30'd0, yo}) * (ddy >>> 14);
		shade_ch = clamp9(sn >>> 4);
	end endfunction
	// the dither matrix value at (x, y) (dither_coefficients, no noise)
	function [2:0] dmat; input mode; input [1:0] y, x; reg [3:0] d; begin
		case ({mode, y, x})
		5'h00: d = 0; 5'h01: d = 6; 5'h02: d = 1; 5'h03: d = 7; 5'h04: d = 4; 5'h05: d = 2; 5'h06: d = 5; 5'h07: d = 3;
		5'h08: d = 3; 5'h09: d = 5; 5'h0A: d = 2; 5'h0B: d = 4; 5'h0C: d = 7; 5'h0D: d = 1; 5'h0E: d = 6; 5'h0F: d = 0;
		5'h10: d = 0; 5'h11: d = 4; 5'h12: d = 1; 5'h13: d = 5; 5'h14: d = 4; 5'h15: d = 0; 5'h16: d = 5; 5'h17: d = 1;
		5'h18: d = 3; 5'h19: d = 7; 5'h1A: d = 2; 5'h1B: d = 6; 5'h1C: d = 7; 5'h1D: d = 3; 5'h1E: d = 6; default: d = 2;
		endcase
		dmat = d[2:0];
	end endfunction
	function [8:0] rgb_dith_f; input [1:0] dr; input [2:0] dm; rgb_dith_f = (dr < 2'd2) ? {dm, dm, dm} : 9'd0; endfunction
	function [2:0] alpha_dith_f; input [1:0] dr, da; input [2:0] dm; reg [2:0] a0; begin
		a0 = (dr >= 2'd2) ? dm : rgb_dith_f(dr, dm);
		alpha_dith_f = (da == 2'd3 || da == 2'd2) ? 3'd0 : (da == 2'd1) ? ~a0 : a0;
	end endfunction
	function [7:0] dith1; input [7:0] c; input [2:0] d; reg [8:0] up; begin
		up = (c > 8'd247) ? 9'd255 : {1'b0, c[7:3], 3'b000} + 9'd8;
		dith1 = (d < c[2:0]) ? up[7:0] : c;
	end endfunction
	function [23:0] src_rgb; input [1:0] m; input [23:0] p, mem; input [31:0] bc, fg; begin
		case (m)
		2'd0: src_rgb = p;
		2'd1: src_rgb = mem;
		2'd2: src_rgb = bc[31:8];
		default: src_rgb = fg[31:8];
		endcase
	end endfunction
	// a pixel's byte address in the colour image, and its depth's
	function [23:0] baddr_f; input [23:0] px; input [2:0] f; input [23:0] fa; begin
		case (f)
		FB_RGBA8888: baddr_f = {fa[23:2], 2'b00} + (px << 2);
		FB_RGBA5551, FB_IA88: baddr_f = {fa[23:1], 1'b0} + (px << 1);
		default: baddr_f = fa + px;
		endcase
	end endfunction

	// =====================================================================================
	// the stall
	// =====================================================================================
	wire         stall_mem, stall_wr;
	assign ce = !(stall_mem || stall_wr);

	// =====================================================================================
	// A: the pixel
	// =====================================================================================
	reg          cur_v, ph;
	reg  [12:0]  x, x1;
	reg  [15:0]  xl [0:3], xr [0:3];
	reg  signed [31:0] acc [0:7];         // rgba, z, s, t, w
	reg          cur_slot;
	assign sp_ready = ce && !cur_v;
	wire [15:0]  xs8 = {x, 3'b000};
	wire [7:0]   cov = {cv(xl[3], xr[3], xs8 + 16'd6), cv(xl[3], xr[3], xs8 + 16'd2),
	                    cv(xl[2], xr[2], xs8 + 16'd4), cv(xl[2], xr[2], xs8),
	                    cv(xl[1], xr[1], xs8 + 16'd6), cv(xl[1], xr[1], xs8 + 16'd2),
	                    cv(xl[0], xr[0], xs8 + 16'd4), cv(xl[0], xr[0], xs8)};
	wire [3:0]   cov_n = cov[0] + cov[1] + cov[2] + cov[3] + cov[4] + cov[5] + cov[6] + cov[7];
	reg  [2:0]   fc;
	always @(*) begin
		fc = 3'd0;
		if (!cov[0]) fc = cov[1] ? 3'd1 : cov[2] ? 3'd2 : cov[3] ? 3'd3 : cov[4] ? 3'd4 : cov[5] ? 3'd5 : cov[6] ? 3'd6 : 3'd7;
	end
	wire         adv = !multi || ph;      // this slot is the pixel's last: step on after it
	reg          a_occ, a_val, a_ph, a_end, a_slot;
	reg  [12:0]  a_x;
	reg  [3:0]   a_cc;
	reg  [1:0]   a_xo, a_yo;
	reg  signed [31:0] a_acc [0:7];
	always @(posedge clk) begin
		if (rst) begin cur_v <= 1'b0; a_occ <= 1'b0; ph <= 1'b0; end
		else if (ce) begin
			a_occ <= 1'b0;
			if (!cur_v) begin
				if (sp_valid) begin
					cur_v <= 1'b1; ph <= 1'b0;
					x <= sp_x0; x1 <= sp_x1; cur_slot <= sp_slot;
					for (i = 0; i < 4; i = i + 1) begin xl[i] <= sp_xl[63 - 16 * i -: 16]; xr[i] <= sp_xr[63 - 16 * i -: 16]; end
					for (i = 0; i < 8; i = i + 1) acc[i] <= sp_acc[255 - 32 * i -: 32];
				end
			end else begin
				a_occ <= 1'b1;
				// coverage: none, or (without AA) not the first sample: no pixel
				a_val <= !(cov == 8'd0 || (!aa && !cov[0]));
				a_ph <= ph; a_end <= adv && x >= x1; a_slot <= cur_slot;
				a_x <= x; a_cc <= cov_n;
				a_yo <= fc[2:1]; a_xo <= {fc[0], 1'b0} + {1'b0, fc[1]};
				for (i = 0; i < 8; i = i + 1) a_acc[i] <= acc[i];
				if (multi && !ph) ph <= 1'b1;
				else begin
					ph <= 1'b0;
					for (i = 0; i < 4; i = i + 1) acc[i] <= acc[i] + ($signed(d_rgba_dx[127 - 32 * i -: 32]) & ~32'sh1F);
					acc[4] <= acc[4] + $signed(dz_dx);
					acc[5] <= acc[5] + ($signed(d_st_dx[95:64]) & ~32'sh1F);
					acc[6] <= acc[6] + ($signed(d_st_dx[63:32]) & ~32'sh1F);
					acc[7] <= acc[7] + ($signed(d_st_dx[31:0]) & ~32'sh1F);
					if (x >= x1) cur_v <= 1'b0;
					else x <= x + 13'd1;
				end
			end
		end
	end

	// =====================================================================================
	// B: shade, z, s/t/w
	// =====================================================================================
	reg          b_occ, b_val, b_ph, b_end, b_slot;
	reg  [12:0]  b_x;  reg [3:0] b_cc;
	reg  [31:0]  b_shade;                 // r, g, b, a
	reg  [17:0]  b_pz;
	reg  signed [15:0] b_ps, b_pt, b_pw, b_xs, b_xt, b_xw, b_ys, b_yt, b_yw;
	always @(posedge clk) begin
		if (rst) b_occ <= 1'b0;
		else if (ce) begin : sh
			reg signed [31:0] dsx, dtx, dwx;
			b_occ <= a_occ; b_val <= a_val; b_ph <= a_ph; b_end <= a_end; b_slot <= a_slot; b_x <= a_x; b_cc <= a_cc;
			for (i = 0; i < 4; i = i + 1)
				b_shade[31 - 8 * i -: 8] <= shade_ch(a_acc[i], $signed(d_rgba_dx[127 - 32 * i -: 32]), $signed(d_rgba_dy[127 - 32 * i -: 32]), a_xo, a_yo);
			b_pz <= z_at(a_acc[4], $signed(dz_dx), $signed(dz_dy), a_xo, a_yo);
			b_ps <= a_acc[5][31:16]; b_pt <= a_acc[6][31:16]; b_pw <= a_acc[7][31:16];
			// the LOD's neighbours: one pixel on in x (the way the span is walked), one in y
			dsx = $signed(d_st_dx[95:64]) & ~32'sh1F; dtx = $signed(d_st_dx[63:32]) & ~32'sh1F; dwx = $signed(d_st_dx[31:0]) & ~32'sh1F;
			b_xs <= flip ? (a_acc[5] + dsx) >>> 16 : (a_acc[5] - dsx) >>> 16;
			b_xt <= flip ? (a_acc[6] + dtx) >>> 16 : (a_acc[6] - dtx) >>> 16;
			b_xw <= flip ? (a_acc[7] + dwx) >>> 16 : (a_acc[7] - dwx) >>> 16;
			b_ys <= (a_acc[5] + ($signed(d_st_dy[95:64]) & ~32'sh7FFF)) >>> 16;
			b_yt <= (a_acc[6] + ($signed(d_st_dy[63:32]) & ~32'sh7FFF)) >>> 16;
			b_yw <= (a_acc[7] + ($signed(d_st_dy[31:0]) & ~32'sh7FFF)) >>> 16;
		end
	end

	// =====================================================================================
	// C: the divides (two clocks); the payload waits beside them
	// =====================================================================================
	wire signed [16:0] p0s, p0t, p1s, p1t, p2s, p2t;  wire p0o, p1o, p2o;
	n64_rdp_persp u_p0 (.clk(clk), .ce(ce), .s(b_ps), .t(b_pt), .w(b_pw), .so(p0s), .to(p0t), .overflow(p0o));
	n64_rdp_persp u_p1 (.clk(clk), .ce(ce), .s(b_xs), .t(b_xt), .w(b_xw), .so(p1s), .to(p1t), .overflow(p1o));
	n64_rdp_persp u_p2 (.clk(clk), .ce(ce), .s(b_ys), .t(b_yt), .w(b_yw), .so(p2s), .to(p2t), .overflow(p2o));
	reg          c_occ [0:1], c_val [0:1], c_ph [0:1], c_end [0:1], c_slot [0:1];
	reg  [12:0]  c_x [0:1];  reg [3:0] c_cc [0:1];  reg [31:0] c_shade [0:1];  reg [17:0] c_pz [0:1];
	reg  signed [15:0] c_ps [0:1], c_pt [0:1], c_xs [0:1], c_xt [0:1], c_ys [0:1], c_yt [0:1];
	always @(posedge clk) begin
		if (rst) begin c_occ[0] <= 1'b0; c_occ[1] <= 1'b0; end
		else if (ce) begin
			c_occ[0] <= b_occ; c_val[0] <= b_val; c_ph[0] <= b_ph; c_end[0] <= b_end; c_slot[0] <= b_slot;
			c_x[0] <= b_x; c_cc[0] <= b_cc; c_shade[0] <= b_shade; c_pz[0] <= b_pz;
			c_ps[0] <= b_ps; c_pt[0] <= b_pt; c_xs[0] <= b_xs; c_xt[0] <= b_xt; c_ys[0] <= b_ys; c_yt[0] <= b_yt;
			c_occ[1] <= c_occ[0]; c_val[1] <= c_val[0]; c_ph[1] <= c_ph[0]; c_end[1] <= c_end[0]; c_slot[1] <= c_slot[0];
			c_x[1] <= c_x[0]; c_cc[1] <= c_cc[0]; c_shade[1] <= c_shade[0]; c_pz[1] <= c_pz[0];
			c_ps[1] <= c_ps[0]; c_pt[1] <= c_pt[0]; c_xs[1] <= c_xs[0]; c_xt[1] <= c_xt[0]; c_ys[1] <= c_ys[0]; c_yt[1] <= c_yt[0];
		end
	end

	// =====================================================================================
	// D: the coordinates; the LOD; the tile (the second texel's in a second slot)
	// =====================================================================================
	// D -> L: the coordinates, and the largest of the LOD's four deltas, registered before the
	// rest of the LOD and the tile (the deltas, the max tree, the priority encoder and the tile's
	// adds in one clock were the RDP's second-longest path at 62.5 MHz)
	reg          l_occ, l_val, l_ph, l_end, l_slot, l_povf;
	reg  [12:0]  l_x;  reg [3:0] l_cc;  reg [31:0] l_shade;  reg [17:0] l_pz;
	reg  signed [16:0] l_s, l_t;
	reg  [16:0]  l_mx;
	always @(posedge clk) begin
		if (rst) l_occ <= 1'b0;
		else if (ce) begin : lod1
			reg signed [16:0] ss, tt, sxd, txd, syd, tyd; reg povf;
			reg signed [17:0] d0, d1, d2, d3; reg [16:0] a0, a1, a2, a3, m01, m23;
			if (persp_en) begin ss = p0s; tt = p0t; sxd = p1s; txd = p1t; syd = p2s; tyd = p2t; povf = p0o | p1o | p2o; end
			else begin
				ss = {c_ps[1][15], c_ps[1]}; tt = {c_pt[1][15], c_pt[1]};
				sxd = {c_xs[1][15], c_xs[1]}; txd = {c_xt[1][15], c_xt[1]};
				syd = {c_ys[1][15], c_ys[1]}; tyd = {c_yt[1][15], c_yt[1]};
				povf = 1'b0;
			end
			// (the divide's overflow counts only where the LOD is worked out: as the
			// state machine had it, the LOD's neighbours were divided only then)
			if (!uses_lod) povf = 1'b0;
			// compute_lod: the largest of the four deltas, as a tree (two compares deep)
			d0 = sxd - ss; d1 = txd - tt; d2 = syd - ss; d3 = tyd - tt;
			a0 = d0[17] ? ~d0[16:0] : d0[16:0]; a1 = d1[17] ? ~d1[16:0] : d1[16:0];
			a2 = d2[17] ? ~d2[16:0] : d2[16:0]; a3 = d3[17] ? ~d3[16:0] : d3[16:0];
			m01 = (a1 > a0) ? a1 : a0; m23 = (a3 > a2) ? a3 : a2;
			l_mx <= (m23 > m01) ? m23 : m01;
			l_povf <= povf;
			l_occ <= c_occ[1]; l_val <= c_val[1]; l_ph <= c_ph[1]; l_end <= c_end[1]; l_slot <= c_slot[1];
			l_x <= c_x[1]; l_cc <= c_cc[1]; l_shade <= c_shade[1]; l_pz <= c_pz[1];
			l_s <= ss; l_t <= tt;
		end
	end
	// =====================================================================================
	// L: the LOD; the tile (the second texel's in a second slot)
	// =====================================================================================
	reg          e_occ, e_val, e_ph, e_end, e_slot;
	reg  [12:0]  e_x;  reg [3:0] e_cc;  reg [31:0] e_shade;  reg [17:0] e_pz;
	reg  signed [16:0] e_s, e_t;
	reg  [2:0]   e_tile;
	reg          e_bil;
	reg  [8:0]   e_lf;
	always @(posedge clk) begin
		if (rst) e_occ <= 1'b0;
		else if (ce) begin : lod
			reg [16:0] mx; reg [4:0] mb; reg dist, mag;
			reg [8:0] lf; reg [2:0] toff; reg [2:0] maxl, tl0, tl1; reg [11:0] lf12;
			mx = l_mx;
			tl0 = tile[2:0]; tl1 = tile[2:0] + 3'd1; lf = 9'd0;
			if (uses_lod) begin
				maxl = tile[5:3]; toff = 3'd0; mag = 1'b0; dist = 1'b0;
				if (l_povf) begin dist = 1'b1; lf = 9'h0FF; end
				else if (mx >= 17'h4000) begin dist = 1'b1; lf = 9'h0FF; toff = maxl; end
				else if (mx < 17'd32) begin
					dist = maxl == 3'd0; mag = 1'b1;
					if (!sharpen && !detail) lf = dist ? 9'h0FF : 9'd0;
					else begin
						lf12 = ((({7'd0, prim_min_level} > mx[11:0]) ? {7'd0, prim_min_level} : mx[11:0]) << 3) - (sharpen ? 12'h100 : 12'h000);
						lf = lf12[8:0];
					end
				end else begin
					mb = msb18({6'd0, mx[16:5]});
					dist = {2'b00, mb} >= {2'b00, maxl};
					if (dist && !sharpen && !detail) lf = 9'h0FF;
					else begin lf = {1'b0, (({mx, 3'b000}) >> mb)} & 9'h0FF; toff = mb[2:0]; end
				end
				if (tex_lod_en) begin
					if (dist) toff = maxl;
					if (!detail) begin
						tl0 = tile[2:0] + toff;
						tl1 = (dist || (!sharpen && mag)) ? tl0 : tl0 + 3'd1;
					end else begin
						tl1 = tile[2:0] + toff + ((dist || mag) ? 3'd1 : 3'd2);
						tl0 = tile[2:0] + toff + (mag ? 3'd0 : 3'd1);
					end
				end
			end
			e_occ <= l_occ; e_val <= l_val; e_ph <= l_ph; e_end <= l_end; e_slot <= l_slot;
			e_x <= l_x; e_cc <= l_cc; e_shade <= l_shade; e_pz <= l_pz;
			e_s <= l_s; e_t <= l_t; e_lf <= lf;
			e_tile <= l_ph ? tl1 : tl0;
			e_bil <= l_ph ? bilerp1 : bilerp0;
		end
	end

	// =====================================================================================
	// the sampler (eight clocks); the payload waits beside it
	// =====================================================================================
	wire [39:0]  texel;
	n64_rdp_texp u_tex (.clk(clk), .ce(ce), .s_in(e_s), .t_in(e_t),
		.tw(tw_all[447 - 56 * e_tile -: 56]), .tsz(tsz_all[383 - 48 * e_tile -: 48]),
		.tlut(tlut_en), .tlut_type(tlut_type), .sample_quad(sample_quad), .mid_texel_en(mid_texel_en), .bilerp(e_bil),
		.fa0(fa0), .fa1(fa1), .fa2(fa2), .fa3(fa3), .fq0(fq0), .fq1(fq1), .fq2(fq2), .fq3(fq3),
		.sa0(sa0), .sa1(sa1), .sa2(sa2), .sa3(sa3), .sq0(sq0), .sq1(sq1), .sq2(sq2), .sq3(sq3), .texel(texel));
	// {occ, val, ph, end, slot, x, cc, shade, pz, lf}: 1+1+1+1+1+13+4+32+18+9 = 81
	localparam PW = 81;
	wire [PW-1:0] e_pl = {e_occ, e_val, e_ph, e_end, e_slot, e_x, e_cc, e_shade, e_pz, e_lf};
	reg  [PW-1:0] dl [0:7];
	always @(posedge clk) if (ce) begin
		dl[0] <= e_pl;
		for (i = 1; i < 8; i = i + 1) dl[i] <= dl[i - 1];
	end
	wire [PW-1:0] m_pl = dl[7];
	// (the delay line keeps no reset: its occupancy is cleared by the one beside it)
	reg  [7:0]   dl_occ;
	always @(posedge clk) begin
		if (rst) dl_occ <= 8'd0;
		else if (ce) dl_occ <= {dl_occ[6:0], e_occ};
	end
	wire         m_occ = dl_occ[7];
	wire         m_val = m_pl[79], m_ph = m_pl[78], m_end = m_pl[77], m_slot = m_pl[76];
	wire [12:0]  m_x = m_pl[75:63];
	wire [3:0]   m_cc = m_pl[62:59];
	wire [31:0]  m_shade = m_pl[58:27];
	wire [17:0]  m_pz = m_pl[26:9];
	wire [8:0]   m_lf = m_pl[8:0];

	// =====================================================================================
	// M: the texels in hand
	// =====================================================================================
	reg  [39:0]  hold_t0;
	reg          n_occ, n_val, n_end, n_slot;
	reg  [12:0]  n_x;  reg [3:0] n_cc;  reg [31:0] n_shade;  reg [17:0] n_pz;  reg [8:0] n_lf;
	reg  [39:0]  n_t0, n_t1;
	always @(posedge clk) begin
		if (rst) n_occ <= 1'b0;
		else if (ce) begin
			if (multi && !m_ph) hold_t0 <= texel;
			n_occ <= m_occ; n_val <= m_val && (!multi || m_ph); n_end <= m_end; n_slot <= m_slot;
			n_x <= m_x; n_cc <= m_cc; n_shade <= m_shade; n_pz <= m_pz; n_lf <= m_lf;
			// (texels the combiner does not read stay 0, as the state machine left them)
			n_t0 <= multi ? hold_t0 : texel;
			n_t1 <= (multi && uses_t1) ? texel : 40'd0;
		end
	end

	// =====================================================================================
	// N, O, P: the combiner (cycle 0 in two-cycle mode, then the final cycle)
	// =====================================================================================
	wire [26:0]  k0a, k0b, k0c, k0d, k1a, k1b, k1c, k1d;
	wire [8:0]   k0aa, k0ab, k0ac, k0ad, k1aa, k1ab, k1ac, k1ad;
	n64_rdp_ccconst u_k0 (.sa(comb0[23:20]), .sb(comb1[31:28]), .sc(comb0[19:15]), .sd(comb1[17:15]),
		.aa(comb0[14:12]), .ab(comb1[14:12]), .ac(comb0[11:9]), .ad(comb1[11:9]),
		.prim(prim_color), .env(env_color), .key_center(key_center), .key_scale(key_scale), .k4(k4), .k5(k5),
		.prim_lod_frac(prim_lod_frac), .ka(k0a), .kb(k0b), .kc(k0c), .kd(k0d), .kaa(k0aa), .kab(k0ab), .kac(k0ac), .kad(k0ad));
	n64_rdp_ccconst u_k1 (.sa(comb0[8:5]), .sb(comb1[27:24]), .sc(comb0[4:0]), .sd(comb1[8:6]),
		.aa(comb1[23:21]), .ab(comb1[5:3]), .ac(comb1[20:18]), .ad(comb1[2:0]),
		.prim(prim_color), .env(env_color), .key_center(key_center), .key_scale(key_scale), .k4(k4), .k5(k5),
		.prim_lod_frac(prim_lod_frac), .ka(k1a), .kb(k1b), .kc(k1c), .kd(k1d), .kaa(k1aa), .kab(k1ab), .kac(k1ac), .kad(k1ad));
	function [39:0] sh40; input [31:0] s; sh40 = {2'b00, s[31:24], 2'b00, s[23:16], 2'b00, s[15:8], 2'b00, s[7:0]}; endfunction
	wire [39:0]  cc0_out;
	n64_rdp_cc u_cc0 (.sa(comb0[23:20]), .sb(comb1[31:28]), .sc(comb0[19:15]), .sd(comb1[17:15]),
		.aa(comb0[14:12]), .ab(comb1[14:12]), .ac(comb0[11:9]), .ad(comb1[11:9]),
		.combined(40'd0), .texel0(n_t0), .texel1(n_t1), .shade(sh40(n_shade)), .lod_frac(n_lf), .noise(9'h020),
		.ka(k0a), .kb(k0b), .kc(k0c), .kd(k0d), .kaa(k0aa), .kab(k0ab), .kac(k0ac), .kad(k0ad), .out(cc0_out));
	// N -> O: cycle 0's answer, registered
	reg          o_occ, o_val, o_end, o_slot;
	reg  [12:0]  o_x;  reg [3:0] o_cc;  reg [31:0] o_shade;  reg [17:0] o_pz;  reg [8:0] o_lf;
	reg  [39:0]  o_t0, o_t1, o_cc0;
	always @(posedge clk) begin
		if (rst) o_occ <= 1'b0;
		else if (ce) begin
			o_occ <= n_occ; o_val <= n_val; o_end <= n_end; o_slot <= n_slot;
			o_x <= n_x; o_cc <= n_cc; o_shade <= n_shade; o_pz <= n_pz; o_lf <= n_lf; o_t0 <= n_t0; o_t1 <= n_t1;
			o_cc0 <= cc0_out;
		end
	end
	// O -> P: the alpha reference (cycle 0's alpha, in two-cycle mode); the dither's alpha
	wire [11:0]  o_y = o_slot ? sl_y[23:12] : sl_y[11:0];
	wire [2:0]   o_dm = dmat(dith_rgb[0], o_y[1:0], o_x[1:0]);
	wire [2:0]   o_adith = alpha_dith_f(dith_rgb, dith_alpha, o_dm);
	reg          p_occ, p_val, p_end, p_slot;
	reg  [12:0]  p_x;  reg [1:0] p_y;  reg [3:0] p_cc;  reg [31:0] p_shade;  reg [17:0] p_pz;  reg [8:0] p_lf;
	reg  [39:0]  p_t0, p_t1, p_ccomb;
	reg  [7:0]   p_aref;
	reg  [2:0]   p_adith, p_dm;
	always @(posedge clk) begin
		if (rst) p_occ <= 1'b0;
		else if (ce) begin : ref
			reg [7:0] ca; reg [9:0] ea; reg [13:0] pr;
			p_occ <= o_occ; p_val <= o_val; p_end <= o_end; p_slot <= o_slot;
			p_x <= o_x; p_y <= o_y[1:0]; p_cc <= o_cc; p_shade <= o_shade; p_pz <= o_pz; p_lf <= o_lf;
			p_t0 <= o_t0; p_t1 <= o_t1; p_ccomb <= o_cc0;
			p_adith <= o_adith; p_dm <= o_dm;
			ca = clamp9({{22{o_cc0[9]}}, o_cc0[9:0]});
			ea = {2'b00, ca} + {9'd0, ca == 8'hFF};
			pr = ({4'd0, ea} * {10'd0, o_cc} + 14'd4) >> 3;
			if (acs) ea = cvg_ta ? pr[9:0] : {1'b0, o_cc, 5'd0};
			else ea = ea + {7'd0, o_adith};
			p_aref <= (ea > 10'd255) ? 8'd255 : ea[7:0];
		end
	end
	wire [39:0]  cc1_out;
	n64_rdp_cc u_cc1 (.sa(comb0[8:5]), .sb(comb1[27:24]), .sc(comb0[4:0]), .sd(comb1[8:6]),
		.aa(comb1[23:21]), .ab(comb1[5:3]), .ac(comb1[20:18]), .ad(comb1[2:0]),
		.combined(multi ? p_ccomb : 40'd0), .texel0(multi ? p_t1 : p_t0), .texel1(multi ? p_t0 : p_t1),
		.shade(sh40(p_shade)), .lod_frac(p_lf), .noise(9'h020),
		.ka(k1a), .kb(k1b), .kc(k1c), .kd(k1d), .kaa(k1aa), .kab(k1ab), .kac(k1ac), .kad(k1ad), .out(cc1_out));
	// P -> Q: the final cycle's answer, registered
	reg          q_occ, q_val, q_end, q_slot;
	reg  [12:0]  q_x;  reg [1:0] q_y;  reg [3:0] q_cc;  reg [7:0] q_sha;  reg [17:0] q_pz;
	reg  [39:0]  q_cc1;
	reg  [7:0]   q_aref;
	reg  [2:0]   q_adith, q_dm;
	always @(posedge clk) begin
		if (rst) q_occ <= 1'b0;
		else if (ce) begin
			q_occ <= p_occ; q_val <= p_val; q_end <= p_end; q_slot <= p_slot;
			q_x <= p_x; q_y <= p_y; q_cc <= p_cc; q_sha <= p_shade[7:0]; q_pz <= p_pz;
			q_cc1 <= cc1_out; q_aref <= p_aref; q_adith <= p_adith; q_dm <= p_dm;
		end
	end

	// =====================================================================================
	// Q: clamped, the coverage (cvg_x_alpha), alpha compare; the span buffer asked for the
	// pixel's lines
	// =====================================================================================
	wire [23:0]  q_row = q_slot ? sl_row[47:24] : sl_row[23:0];
	wire [23:0]  q_px = q_row + {11'd0, q_x};
	wire [23:0]  q_ba = baddr_f(q_px, fb_fmt, fb_addr);
	wire [23:0]  q_za = {z_addr[23:1], 1'b0} + (q_px << 1);
	wire [19:0]  q_cline = {1'b0, q_ba[22:4]}, q_zline = {1'b0, q_za[22:4]};
	wire [19:0]  q_clo = q_slot ? sl_clo[39:20] : sl_clo[19:0];
	wire [19:0]  q_zlo = q_slot ? sl_zlo[39:20] : sl_zlo[19:0];
	assign sc_ra = {q_slot, q_cline[7:0] - q_clo[7:0]};
	assign sz_ra = {q_slot, q_zline[6:0] - q_zlo[6:0]};
	assign stall_mem = q_occ && !(q_slot ? sl_filled[1] : sl_filled[0]);
	reg          r_occ, r_val;
	reg  [1:0]   r_y;  reg [12:0] r_x;
	reg  [3:0]   r_cc;  reg [17:0] r_pz;  reg [7:0] r_comb [0:3];  reg [7:0] r_sha;  reg [2:0] r_adith, r_dm;
	reg  [19:0]  r_cline, r_zline;  reg [3:0] r_pb, r_zbi;
	always @(posedge clk) begin
		if (rst) begin r_occ <= 1'b0; rel <= 1'b0; end
		else begin
			rel <= 1'b0;
			if (ce) begin : c1
				reg [7:0] c3; reg [9:0] ea, md; reg [3:0] ncc; reg [13:0] pr; reg [7:0] af;
				r_occ <= q_occ;
				if (q_occ && q_end) begin rel <= 1'b1; rel_slot <= q_slot; end
				c3 = clamp9({{22{q_cc1[9]}}, q_cc1[9:0]});
				ea = {2'b00, c3} + {9'd0, c3 == 8'hFF};
				ncc = q_cc;
				pr = ({4'd0, ea} * {10'd0, q_cc} + 14'd4) >> 3;
				if (cvg_ta) begin md = pr[9:0]; ncc = md[8:5]; end
				else md = {1'b0, q_cc, 5'd0};
				if (acs) ea = md; else ea = ea + {7'd0, q_adith};
				af = (ea > 10'd255) ? 8'd255 : ea[7:0];
				r_comb[0] <= clamp9({{22{q_cc1[39]}}, q_cc1[39:30]});
				r_comb[1] <= clamp9({{22{q_cc1[29]}}, q_cc1[29:20]});
				r_comb[2] <= clamp9({{22{q_cc1[19]}}, q_cc1[19:10]});
				r_comb[3] <= af;
				r_cc <= ncc;
				// no pixel: AA with no coverage left, or alpha compare (against the blend colour)
				r_val <= q_val && !((aa && ncc == 4'd0) || (alpha_test && (multi ? q_aref : af) < blend_color[7:0]));
				r_y <= q_y; r_x <= q_x; r_pz <= q_pz; r_sha <= q_sha; r_adith <= q_adith; r_dm <= q_dm;
				r_cline <= q_cline; r_zline <= q_zline; r_pb <= q_ba[3:0]; r_zbi <= q_za[3:0];
			end
		end
	end

	// =====================================================================================
	// R: the memory colour, the depth test
	// =====================================================================================
	wire [7:0]   by0 = sc_q[8 * r_pb +: 8], by1 = sc_q[8 * (r_pb + 4'd1) +: 8];
	wire [7:0]   by2 = sc_q[8 * (r_pb + 4'd2) +: 8], by3 = sc_q[8 * (r_pb + 4'd3) +: 8];
	wire [15:0]  w16 = {by0, by1};
	reg  [7:0]   mem_r, mem_g, mem_b, mem_a;
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
	wire [15:0]  zw = {sz_q[8 * r_zbi +: 8], sz_q[8 * (r_zbi + 4'd1) +: 8]};
	wire [13:0]  mem_depth = zw[15:2];
	wire [3:0]   mem_dz = {zw[1:0], 2'b11};                    // (the ninth bits as 3)
	// R -> K: what the memory holds, worked out and registered before the depth test (the span
	// buffer's block RAM through the decompression, the delta's priority encoder and shift, and
	// the compares in one clock were the RDP's longest path at 62.5 MHz)
	reg          k_occ, k_val, k_ovf, k_coplanar, k_maxz;
	reg  [3:0]   k_cc;  reg [17:0] k_pz;  reg [7:0] k_comb [0:3];  reg [7:0] k_sha;  reg [2:0] k_adith, k_dm;
	reg  [1:0]   k_y;  reg [12:0] k_x;
	reg  [19:0]  k_cline, k_zline;  reg [3:0] k_pb, k_zbi;
	reg  [23:0]  k_mem;  reg [7:0] k_mema;  reg [2:0] k_mcov;
	reg  [17:0]  k_mz;  reg [15:0] k_cdz;  reg [19:0] k_cdz8;  reg [2:0] k_bsh_a, k_bsh_b;
	always @(posedge clk) begin
		if (rst) k_occ <= 1'b0;
		else if (ce) begin : kd
			reg [16:0] mdz; reg [15:0] cdz; reg [3:0] prec; reg coplanar;
			k_occ <= r_occ; k_val <= r_val; k_cc <= r_cc; k_pz <= r_pz;
			for (i = 0; i < 4; i = i + 1) k_comb[i] <= r_comb[i];
			k_sha <= r_sha; k_adith <= r_adith; k_dm <= r_dm; k_y <= r_y; k_x <= r_x;
			k_cline <= r_cline; k_zline <= r_zline; k_pb <= r_pb; k_zbi <= r_zbi;
			k_mem <= {mem_r, mem_g, mem_b}; k_mema <= mem_a; k_mcov <= mem_cov;
			k_ovf <= ({1'b0, r_cc} + {2'b00, mem_cov}) >= 5'd8;
			k_mz <= z_decomp(mem_depth);
			k_maxz <= z_decomp(mem_depth) == 18'h3FFFF;
			mdz = 17'd1 << mem_dz;
			prec = {1'b0, mem_depth[13:11]};
			coplanar = 1'b0;
			if (prec < 4'd3) begin
				if (mdz != 17'h8000) mdz = ((mdz << 1) > (17'd16 >> prec)) ? (mdz << 1) : (17'd16 >> prec);
				else begin coplanar = 1'b1; mdz = 17'hFFFF; end
			end
			cdz = dzpix | mdz[15:0];
			k_cdz <= cdz;
			k_cdz8 <= (cdz == 16'd0) ? 20'd0 : (20'd1 << msb18({2'd0, cdz})) << 3;
			k_coplanar <= coplanar;
			if (z_cmp) begin
				k_bsh_a <= (dz_c > mem_dz) ? ((dz_c - mem_dz > 4'd4) ? 3'd4 : dz_c - mem_dz) : 3'd0;
				k_bsh_b <= (mem_dz > dz_c) ? ((mem_dz - dz_c > 4'd4) ? 3'd4 : mem_dz - dz_c) : 3'd0;
			end else begin
				k_bsh_a <= 3'd0;
				k_bsh_b <= (4'hF - dz_c > 4'd4) ? 3'd4 : 4'hF - dz_c;
			end
		end
	end
	reg          s_occ, s_val, s_bl_en, s_wrap;
	reg  [2:0]   s_bsh_a, s_bsh_b;
	reg  [3:0]   s_cc;  reg [2:0] s_mcov;
	reg  [7:0]   s_pix [0:3];  reg [7:0] s_sha;  reg [23:0] s_mem;  reg [7:0] s_mema;
	reg  [17:0]  s_pz;  reg [1:0] s_y;  reg [12:0] s_x;  reg [2:0] s_dm;
	reg  [19:0]  s_cline, s_zline;  reg [3:0] s_pb, s_zbi;
	always @(posedge clk) begin
		if (rst) s_occ <= 1'b0;
		else if (ce) begin : dt
			reg ok, farther, nearer, front;
			reg [4:0] sh; reg [3:0] coeff; reg [7:0] ncc;
			s_wrap <= k_ovf;
			s_bsh_a <= k_bsh_a; s_bsh_b <= k_bsh_b;
			if (z_cmp) begin
				farther = k_coplanar || ({2'd0, k_pz} + k_cdz8) >= {2'd0, k_mz};
				s_bl_en <= force_blend || (!k_ovf && aa && farther);
				front = k_pz < k_mz;
				nearer = k_coplanar || ($signed({2'd0, k_pz}) - $signed(k_cdz8)) <= $signed({2'd0, k_mz});
				ncc = {4'd0, k_cc};
				case (z_mode)
				2'd0: ok = k_maxz || (k_ovf ? front : nearer);
				2'd1: begin
					if (!front || !farther || !k_ovf) ok = k_maxz || (k_ovf ? front : nearer);
					else begin
						sh = (k_cdz == 16'd0) ? 5'd0 : msb18({2'd0, k_cdz});
						coeff = (k_mz >> sh) - (k_pz >> sh);
						ncc = ({4'd0, coeff} * {4'd0, k_cc}) >> 3;
						if (ncc > 8'd8) ncc = 8'd8;
						ok = 1'b1;
					end
				end
				2'd2: ok = front || k_maxz;
				default: ok = farther && nearer && !k_maxz;
				endcase
			end else begin
				ok = 1'b1; ncc = {4'd0, k_cc};
				s_bl_en <= force_blend || (!k_ovf && aa);
			end
			s_occ <= k_occ;
			s_val <= k_val && ok && !(aa && ncc == 8'd0);
			s_cc <= ncc[3:0]; s_mcov <= k_mcov;
			for (i = 0; i < 4; i = i + 1) s_pix[i] <= k_comb[i];
			s_sha <= ({1'b0, k_sha} + {6'd0, k_adith} > 9'd255) ? 8'd255 : k_sha + {5'd0, k_adith};
			s_mem <= k_mem; s_mema <= k_mema;
			s_pz <= k_pz; s_y <= k_y; s_x <= k_x; s_dm <= k_dm;
			s_cline <= k_cline; s_zline <= k_zline; s_pb <= k_pb; s_zbi <= k_zbi;
		end
	end

	// =====================================================================================
	// S, T: the blender (cycle 0 in two-cycle mode, then the final)
	// =====================================================================================
	// one blender cycle: modes (1a, 1b, 2a, 2b); -> {rgb0 [93:70], rgb1 [69:46], the
	// products r [45:32], g [31:18], b [17:4], the sum [3:0]}
	function [93:0] blend; input [1:0] bm0, bm1, bm2, bm3; input [31:0] pix; input [23:0] mem; input [7:0] mema;
		input [7:0] sha; input [2:0] bsh_a, bsh_b; input [31:0] bc, fg;
		reg [23:0] rgb0, rgb1; reg [7:0] a0f, a1f; reg [4:0] a0s, a1s, a0, a1; reg [13:0] br, bg, bb; reg [3:0] bsum;
	begin
		rgb1 = src_rgb(bm2, pix[31:8], mem, bc, fg);
		rgb0 = src_rgb(bm0, pix[31:8], mem, bc, fg);
		a0f = (bm1 == 2'd0) ? pix[7:0] : (bm1 == 2'd1) ? fg[7:0] : (bm1 == 2'd2) ? sha : 8'd0;
		a1f = (bm3 == 2'd0) ? ~a0f : (bm3 == 2'd1) ? mema : (bm3 == 2'd2) ? 8'hFF : 8'd0;
		a0s = a0f[7:3]; a1s = a1f[7:3];
		a0 = (bm3 == 2'd1) ? ((a0s >> bsh_a) & 5'h1C) : a0s;
		a1 = (bm3 == 2'd1) ? ((a1s >> bsh_b) | 5'd3) : a1s;
		br = rgb0[23:16] * a0 + rgb1[23:16] * ({1'b0, a1} + 6'd1);
		bg = rgb0[15:8] * a0 + rgb1[15:8] * ({1'b0, a1} + 6'd1);
		bb = rgb0[7:0] * a0 + rgb1[7:0] * ({1'b0, a1} + 6'd1);
		bsum = {1'b0, a0[4:2]} + {1'b0, a1[4:2]} + 4'd1;
		blend = {rgb0, rgb1, br, bg, bb, bsum};
	end endfunction
	// cycle 0 (two-cycle mode): always the shift (the state machine's first, non-final cycle)
	wire [93:0]  bl0 = blend(om1[31:30], om1[27:26], om1[23:22], om1[19:18],
		{s_pix[0], s_pix[1], s_pix[2], s_pix[3]}, s_mem, s_mema, s_sha, s_bsh_a, s_bsh_b, blend_color, fog_color);
	reg          t_occ, t_val, t_bl_en, t_wrap;
	reg  [2:0]   t_bsh_a, t_bsh_b;
	reg  [3:0]   t_cc;  reg [2:0] t_mcov;
	reg  [7:0]   t_sha;  reg [23:0] t_mem;  reg [7:0] t_mema;
	reg  [17:0]  t_pz;  reg [1:0] t_y;  reg [12:0] t_x;  reg [2:0] t_dm;
	reg  [19:0]  t_cline, t_zline;  reg [3:0] t_pb, t_zbi;
	always @(posedge clk) begin
		if (rst) t_occ <= 1'b0;
		else if (ce) begin
			t_occ <= s_occ; t_val <= s_val; t_bl_en <= s_bl_en; t_wrap <= s_wrap; t_bsh_a <= s_bsh_a; t_bsh_b <= s_bsh_b;
			t_cc <= s_cc; t_mcov <= s_mcov;
			t_sha <= s_sha; t_mem <= s_mem; t_mema <= s_mema;
			t_pz <= s_pz; t_y <= s_y; t_x <= s_x; t_dm <= s_dm;
			t_cline <= s_cline; t_zline <= s_zline; t_pb <= s_pb; t_zbi <= s_zbi;
		end
	end
	// (cycle 0's rgb: each product's bits 12:5; its alpha is the pixel's)
	wire [13:0]  bl0_r = bl0[45:32], bl0_g = bl0[31:18], bl0_b = bl0[17:4];
	reg  [31:0]  t_pixc;
	always @(posedge clk) if (ce) t_pixc <= multi ? {bl0_r[12:5], bl0_g[12:5], bl0_b[12:5], s_pix[3]}
	                                              : {s_pix[0], s_pix[1], s_pix[2], s_pix[3]};
	// the final cycle
	wire [1:0]   fm0 = multi ? om1[29:28] : om1[31:30], fm1 = multi ? om1[25:24] : om1[27:26];
	wire [1:0]   fm2 = multi ? om1[21:20] : om1[23:22], fm3 = multi ? om1[17:16] : om1[19:18];
	wire [93:0]  bl1 = blend(fm0, fm1, fm2, fm3, t_pixc, t_mem, t_mema, t_sha, t_bsh_a, t_bsh_b, blend_color, fog_color);
	wire [23:0]  f_rgb0 = bl1[93:70], f_rgb1 = bl1[69:46];
	wire [13:0]  f_r = bl1[45:32] , f_g = bl1[31:18], f_b = bl1[17:4];
	wire [3:0]   f_sum = bl1[3:0];
	wire         b_direct1 = color_on_cvg && !t_wrap;
	wire         b_direct0 = !t_bl_en || (fm1 == 2'd0 && fm3 == 2'd0 && t_pixc[7:0] == 8'hFF);
	wire         b_div = !b_direct1 && !b_direct0 && !force_blend;
	wire [7:0]   lut_r, lut_g, lut_b;
	n64_rdp_blut u_blr (.clk(clk), .ce(ce), .a({f_sum, f_r[12:2]}), .q(lut_r));
	n64_rdp_blut u_blg (.clk(clk), .ce(ce), .a({f_sum, f_g[12:2]}), .q(lut_g));
	n64_rdp_blut u_blb (.clk(clk), .ce(ce), .a({f_sum, f_b[12:2]}), .q(lut_b));
	reg          u_occ, u_val, u_div, u_bl_en;
	reg  [23:0]  u_rgb;
	reg  [3:0]   u_cc;  reg [2:0] u_mcov;
	reg  [17:0]  u_pz;  reg [2:0] u_dm;
	reg  [19:0]  u_cline, u_zline;  reg [3:0] u_pb, u_zbi;
	always @(posedge clk) begin
		if (rst) u_occ <= 1'b0;
		else if (ce) begin
			u_occ <= t_occ; u_val <= t_val; u_div <= b_div; u_bl_en <= t_bl_en;
			u_rgb <= b_direct1 ? f_rgb1 : b_direct0 ? f_rgb0 : {f_r[12:5], f_g[12:5], f_b[12:5]};
			u_cc <= t_cc; u_mcov <= t_mcov; u_pz <= t_pz; u_dm <= t_dm;
			u_cline <= t_cline; u_zline <= t_zline; u_pb <= t_pb; u_zbi <= t_zbi;
		end
	end
	// U -> V: the divider's answer
	reg          v_occ, v_val, v_bl_en;
	reg  [23:0]  v_rgb;
	reg  [3:0]   v_cc;  reg [2:0] v_mcov;
	reg  [17:0]  v_pz;  reg [2:0] v_dm;
	reg  [19:0]  v_cline, v_zline;  reg [3:0] v_pb, v_zbi;
	always @(posedge clk) begin
		if (rst) v_occ <= 1'b0;
		else if (ce) begin
			v_occ <= u_occ; v_val <= u_val; v_bl_en <= u_bl_en;
			v_rgb <= u_div ? {lut_r, lut_g, lut_b} : u_rgb;
			v_cc <= u_cc; v_mcov <= u_mcov; v_pz <= u_pz; v_dm <= u_dm;
			v_cline <= u_cline; v_zline <= u_zline; v_pb <= u_pb; v_zbi <= u_zbi;
		end
	end

	// =====================================================================================
	// V: dithered, and into the lines being written; full lines out through the queues
	// =====================================================================================
	wire [8:0]   v_dith = rgb_dith_f(dith_rgb, v_dm);
	wire [7:0]   v_r = db_dither ? dith1(v_rgb[23:16], v_dith[2:0]) : v_rgb[23:16];
	wire [7:0]   v_g = db_dither ? dith1(v_rgb[15:8], v_dith[5:3]) : v_rgb[15:8];
	wire [7:0]   v_b = db_dither ? dith1(v_rgb[7:0], v_dith[8:6]) : v_rgb[7:0];
	wire [4:0]   cov_sum = {2'b00, v_mcov} + {1'b0, v_cc};
	wire [2:0]   new_cov = (cov_mode == 2'd0) ? (v_bl_en ? ((cov_sum > 5'd7) ? 3'd7 : cov_sum[2:0]) : v_cc[2:0] - 3'd1)
	                     : (cov_mode == 2'd1) ? v_cc[2:0] + v_mcov : (cov_mode == 2'd2) ? 3'd7 : v_mcov;
	wire [15:0]  zword = {z_comp(v_pz), dz_c[3:2]};
	// the lines being written
	reg          wc_v, wz_v;
	reg  [19:0]  wc_line, wz_line;
	reg  [127:0] wc_d, wz_d;
	reg  [15:0]  wc_m, wz_m;
	// the queues: colour and depth lines, 4 each
	reg  [163:0] qc [0:3], qz [0:3];
	reg  [2:0]   qc_w, qc_r, qz_w, qz_r;
	wire         qc_full = (qc_w - qc_r) == 3'd4, qz_full = (qz_w - qz_r) == 3'd4;
	wire         qc_empty = qc_w == qc_r, qz_empty = qz_w == qz_r;
	wire         v_store = v_occ && v_val;
	wire         drain_now;               // the pipeline empty at the primitive's end: write the lines held
	wire         push_c = (v_store && wc_v && v_cline != wc_line) || (drain_now && wc_v);
	wire         push_z = (v_store && z_upd && wz_v && v_zline != wz_line) || (drain_now && wz_v);
	assign stall_wr = (push_c && qc_full) || (push_z && qz_full);
	always @(posedge clk) begin
		if (rst) begin
			wc_v <= 1'b0; wz_v <= 1'b0; qc_w <= 3'd0; qc_r <= 3'd0; qz_w <= 3'd0; qz_r <= 3'd0;
			mw_req <= 1'b0;
		end else begin
			if (ce) begin
				if (push_c) begin qc[qc_w[1:0]] <= {wc_line, wc_m, wc_d}; qc_w <= qc_w + 3'd1; end
				if (push_z) begin qz[qz_w[1:0]] <= {wz_line, wz_m, wz_d}; qz_w <= qz_w + 3'd1; end
				if (drain_now) begin wc_v <= 1'b0; wz_v <= 1'b0; end
				if (v_store) begin : st
					reg [127:0] d; reg [15:0] m; reg [7:0] a8;
					d = (wc_v && v_cline == wc_line) ? wc_d : 128'd0;
					m = (wc_v && v_cline == wc_line) ? wc_m : 16'd0;
					a8 = {new_cov, 5'd0};
					case (fb_fmt)
					FB_RGBA5551: begin
						d[8 * v_pb +: 8] = {v_r[7:3], v_g[7:5]};
						d[8 * (v_pb + 4'd1) +: 8] = {v_g[4:3], v_b[7:3], new_cov[2]};
						m[v_pb] = 1'b1; m[v_pb + 4'd1] = 1'b1;
					end
					FB_IA88: begin
						d[8 * v_pb +: 8] = v_r; d[8 * (v_pb + 4'd1) +: 8] = a8;
						m[v_pb] = 1'b1; m[v_pb + 4'd1] = 1'b1;
					end
					FB_RGBA8888: begin
						d[8 * v_pb +: 8] = v_r; d[8 * (v_pb + 4'd1) +: 8] = v_g;
						d[8 * (v_pb + 4'd2) +: 8] = v_b; d[8 * (v_pb + 4'd3) +: 8] = a8;
						m[v_pb] = 1'b1; m[v_pb + 4'd1] = 1'b1; m[v_pb + 4'd2] = 1'b1; m[v_pb + 4'd3] = 1'b1;
					end
					FB_I8: begin d[8 * v_pb +: 8] = (v_pb[0] ? v_g : v_r); m[v_pb] = 1'b1; end
					default: ;
					endcase
					wc_v <= 1'b1; wc_line <= v_cline; wc_d <= d; wc_m <= m;
					if (z_upd) begin : zst
						reg [127:0] zd; reg [15:0] zm;
						zd = (wz_v && v_zline == wz_line) ? wz_d : 128'd0;
						zm = (wz_v && v_zline == wz_line) ? wz_m : 16'd0;
						zd[8 * v_zbi +: 8] = zword[15:8]; zd[8 * (v_zbi + 4'd1) +: 8] = zword[7:0];
						zm[v_zbi] = 1'b1; zm[v_zbi + 4'd1] = 1'b1;
						wz_v <= 1'b1; wz_line <= v_zline; wz_d <= zd; wz_m <= zm;
					end
				end
			end
			// out to memory: a line at a time, colour first
			if (mw_ack) mw_req <= 1'b0;
			if (!mw_req || mw_ack) begin
				if (!qc_empty && !(mw_req && !mw_ack)) begin
					{mw_line, mw_mask, mw_data} <= {4'd0, qc[qc_r[1:0]]}; mw_req <= 1'b1; qc_r <= qc_r + 3'd1;
				end else if (!qz_empty) begin
					{mw_line, mw_mask, mw_data} <= {4'd0, qz[qz_r[1:0]]}; mw_req <= 1'b1; qz_r <= qz_r + 3'd1;
				end
			end
		end
	end

	// in flight: any stage, the delay line, the lines held, the queues, the port
	wire         pipe_occ = cur_v || a_occ || b_occ || c_occ[0] || c_occ[1] || l_occ || e_occ || (|dl_occ) || n_occ || o_occ
	                     || p_occ || q_occ || r_occ || k_occ || s_occ || t_occ || u_occ || v_occ;
	assign drain_now = drain && !pipe_occ && !sp_valid;
	assign busy = pipe_occ || wc_v || wz_v || !qc_empty || !qz_empty || mw_req;
	assign dbg = {stall_mem, stall_wr, cur_v, pipe_occ, wc_v, wz_v, mw_req, sp_valid, qc_w - qc_r, qz_w - qz_r, ce, drain};
endmodule

`default_nettype wire
