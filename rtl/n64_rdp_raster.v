//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_raster.v - the RDP's rasteriser: a primitive's scanlines (span setup), as
// tools/n64/n64rdp.py's span_setup does it, handed a span at a time to the pixel pipeline
// (n64_rdp_pix.v), which draws a pixel a clock. FILL mode is drawn here, a line (16
// bytes) at a time: the fill colour repeats every four bytes, so a line is that pattern
// and a byte mask.
//
// The framebuffer is read a span at a time, as the RDP does it: when a scanline's span
// is known, all its colour lines (and depth lines) are asked for at once, pipelined,
// into one of two slots of a span buffer (block RAM), while the pipeline draws the span
// in the other. The pipeline writes its lines back itself. A primitive's spans are all
// different scanlines, so nothing a span reads was written by the spans before it in
// the same primitive; between primitives the pipeline is emptied first and every line
// it wrote was taken, so the next primitive's reads see them. RDRAM's ninth bits are
// not kept (the board's DDR3 has none): they read as 3, as tools/n64/n64rdpsim.py runs the
// model. Addresses wrap at 8 MB, as the model's RDRAM does.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_raster (
	input  wire         clk,
	input  wire         rst,
	input  wire         go,
	output wire         busy,
	// the primitive (tools/n64/n64rdp.py Tri): x in s.15, y in s.11.2
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
	input  wire [4:0]   prim_min_level,
	input  wire [15:0]  prim_dz,
	input  wire [11:0]  sc_xlo, sc_ylo, sc_xhi, sc_yhi,
	input  wire         sc_field, sc_odd,
	input  wire [23:0]  fb_addr,
	input  wire [23:0]  z_addr,
	input  wire [14:0]  prim_depth,
	input  wire [9:0]   fb_width_m1,
	input  wire [2:0]   fb_fmt,
	// the tiles, all eight (n64_rdp2.v tile_w, tile_sz)
	input  wire [447:0] tw_all,
	input  wire [383:0] tsz_all,
	// TMEM's read ports (n64_rdp_tmem.v)
	output wire         tm_ce,
	output wire [10:0]  fa0, fa1, fa2, fa3,
	input  wire [15:0]  fq0, fq1, fq2, fq3,
	output wire [10:0]  sa0, sa1, sa2, sa3,
	input  wire [15:0]  sq0, sq1, sq2, sq3,
	// RDRAM: span reads, pipelined (taken on rq_ready; the lines come back in order on
	// rs_valid), and line writes, a line at a time
	output wire         rq_valid,
	input  wire         rq_ready,
	output wire [23:0]  rq_line,
	input  wire         rs_valid,
	input  wire [127:0] rs_data,
	output wire         mw_req,
	input  wire         mw_ack,
	output wire [23:0]  mw_line,
	output wire [127:0] mw_data,
	output wire [15:0]  mw_mask,
	output wire [63:0]  dbg
);
	localparam [2:0] FB_I4 = 3'd0, FB_I8 = 3'd1, FB_RGBA5551 = 3'd2, FB_IA88 = 3'd3, FB_RGBA8888 = 3'd4;

	// --- the modes ------------------------------------------------------------------------------
	wire [1:0] cyc_type = om0[21:20];
	wire fill_mode = cyc_type == 2'd3, copy_mode = cyc_type == 2'd2;
	wire use_prim_depth = om1[2];
	wire z_cmp = om1[4], z_upd = om1[5];
	wire flip = tflags[0], do_offset = tflags[1], skip_xfrac = tflags[2];

	// =============================================================================
	// the per-primitive values the pixels use (loaded from attr at the start)
	// =============================================================================
	reg  signed [31:0] d_rgba_dx [0:3], d_rgba_dy [0:3];
	reg  signed [31:0] dz_dx, dz_dy;
	reg  signed [31:0] d_st_dx [0:2];    // s, t, w's x slopes (attr 20, 21, 23)
	reg  signed [31:0] d_st_dy [0:2];    // and y slopes (28, 29, 31), for the LOD
	reg  signed [31:0] at_v [0:7], at_e [0:7];   // each attribute's value and edge slope (attr i, i + 8)
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
	// the row's attributes, all eight at once: rgba, s, t, z, w (attr order); a's dx and dy
	// slopes as the pixels step them (z's: SET_PRIM_DEPTH's none)
	// (wires, not functions: a function called in a for loop simulates wrong in xsim)
	wire signed [31:0] adx [0:7], ady [0:7];
	assign adx[0] = d_rgba_dx[0], adx[1] = d_rgba_dx[1], adx[2] = d_rgba_dx[2], adx[3] = d_rgba_dx[3];
	assign adx[4] = d_st_dx[0], adx[5] = d_st_dx[1], adx[6] = dz_dx, adx[7] = d_st_dx[2];
	assign ady[0] = d_rgba_dy[0], ady[1] = d_rgba_dy[1], ady[2] = d_rgba_dy[2], ady[3] = d_rgba_dy[3];
	assign ady[4] = d_st_dy[0], ady[5] = d_st_dy[1], ady[6] = dz_dy, ady[7] = d_st_dy[2];
	reg  signed [47:0] pa_de [0:7], pa_xf [0:7];   // dy * de; xfrac * ((dx >> 8) & ~1)
	reg  signed [31:0] sp_v [0:7];
	// the running sums at the span's first pixel (for the pipeline): rgba, z, s, t, w
	reg  signed [31:0] acc_rgba [0:3];
	reg  signed [31:0] acc_z, acc_s, acc_t, acc_w;

	// =============================================================================
	// the pixel's place (FILL mode; and the span's lines)
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
	// the fill colour, and a pixel's bytes (fill_pixel_color, store_color)
	wire [31:0]  fc32 = fill_color;
	wire [2:0]   pn = (fb_fmt == FB_RGBA8888) ? 3'd4 : (fb_fmt == FB_RGBA5551 || fb_fmt == FB_IA88) ? 3'd2
	                : (fb_fmt == FB_I8) ? 3'd1 : 3'd0;
	// FILL mode's line being written
	reg  [127:0] lb;  reg [15:0] lb_m;  reg [19:0] lb_line;  reg lb_v;
	reg          fw_req;  reg [23:0] fw_line;  reg [127:0] fw_data;  reg [15:0] fw_mask;

	// =============================================================================
	// the span buffer: two slots; a slot's colour lines at {slot, 0..255}, its depth
	// lines at {slot, 0..127}
	// =============================================================================
	(* ram_style = "block" *) reg [127:0] sbc [0:511];
	(* ram_style = "block" *) reg [127:0] sbz [0:255];
	wire         pce;                     // the pipeline moves (its reads hold while it does not)
	wire [8:0]   sc_ra;  wire [7:0] sz_ra;
	reg  [127:0] sc_q, sz_q;
	reg  [8:0]   f_wa;                    // the next line's place in the slot being filled
	reg          f_slot, f_ph;            // the slot being filled; colour (0) or depth (1) lines
	always @(posedge clk) begin
		if (rs_valid && !f_ph) sbc[{f_slot, f_wa[7:0]}] <= rs_data;
		if (pce) sc_q <= sbc[sc_ra];
	end
	always @(posedge clk) begin
		if (rs_valid && f_ph) sbz[{f_slot, f_wa[6:0]}] <= rs_data;
		if (pce) sz_q <= sbz[sz_ra];
	end
	// each slot: its scanline, the index of its first pixel, its first colour and depth lines;
	// in use (from the fetch until the pipeline has read its last pixel); its lines all in
	reg  [11:0]  sl_y [0:1];
	reg  [23:0]  sl_row [0:1];
	reg  [19:0]  sl_clo [0:1], sl_zlo [0:1];
	reg  [1:0]   sl_used, sl_filled;
	wire         p_rel, p_rel_slot;
	// the fetch: n_c colour lines from c_lo, then n_z depth lines from z_lo
	reg  [19:0]  c_lo, z_lo;
	reg  [8:0]   n_c, n_z, f_i, f_got;
	reg          f_iss, f_iph;            // issuing; which (0 colour, 1 depth)
	wire [8:0]   f_total = n_c + n_z;
	wire         f_done = !f_iss && f_got == f_total;
	assign rq_valid = f_iss;
	assign rq_line = {4'd0, (f_iph ? z_lo : c_lo) + {11'd0, f_i}};
	reg          f_go;                    // (the sequence's: start a fetch into slot g_slot)
	reg          g_slot;
	reg  [19:0]  g_clo, g_zlo;  reg [8:0] g_nc, g_nz;
	always @(posedge clk) begin
		if (rst) begin
			f_iss <= 1'b0; f_got <= 9'd0; n_c <= 9'd0; n_z <= 9'd0; f_wa <= 9'd0; f_ph <= 1'b0;
			sl_used <= 2'b00; sl_filled <= 2'b00;
		end else begin
			if (p_rel) sl_used[p_rel_slot] <= 1'b0;
			if (f_go) begin
				c_lo <= g_clo; z_lo <= g_zlo; n_c <= g_nc; n_z <= g_nz;
				f_i <= 9'd0; f_iph <= g_nc == 9'd0; f_got <= 9'd0; f_wa <= 9'd0; f_ph <= g_nc == 9'd0;
				f_slot <= g_slot;
				f_iss <= g_nc != 9'd0 || g_nz != 9'd0;
				sl_used[g_slot] <= 1'b1;
				sl_filled[g_slot] <= g_nc == 9'd0 && g_nz == 9'd0;
			end else begin
				if (f_iss && rq_ready) begin
					if (!f_iph && f_i + 9'd1 == n_c) begin
						f_i <= 9'd0; f_iph <= 1'b1;
						if (n_z == 9'd0) f_iss <= 1'b0;
					end else if (f_iph && f_i + 9'd1 == n_z) f_iss <= 1'b0;
					else f_i <= f_i + 9'd1;
				end
				if (rs_valid) begin
					f_got <= f_got + 9'd1;
					// (the next line's place: the colour lines, then the depth lines)
					if (f_got + 9'd1 < n_c) f_wa <= f_got + 9'd1;
					else begin f_wa <= f_got + 9'd1 - n_c; f_ph <= 1'b1; end
					if (f_got + 9'd1 == f_total) sl_filled[f_slot] <= 1'b1;
				end
			end
		end
	end
	// a pixel's line: colour and depth
	function [19:0] cline; input [23:0] p; input [2:0] f; input [23:0] fa; reg [23:0] a; begin
		case (f)
		3'd4: a = {fa[23:2], 2'b00} + (p << 2);
		3'd2, 3'd3: a = {fa[23:1], 1'b0} + (p << 1);
		default: a = fa + p;
		endcase
		cline = {1'b0, a[22:4]};
	end endfunction
	function [19:0] zlinef; input [23:0] p; input [23:0] za; reg [23:0] a; begin
		a = {za[23:1], 1'b0} + (p << 1);
		zlinef = {1'b0, a[22:4]};
	end endfunction
	reg          nslot;                   // the slot the next span goes in
	reg          sp_slot;                 // the slot of the span offered to the pipeline

	// =============================================================================
	// the pixel pipeline
	// =============================================================================
	reg          sp_valid;
	wire         sp_ready;
	reg          p_drain;
	wire         p_busy;
	wire         pw_req;  wire [23:0] pw_line;  wire [127:0] pw_data;  wire [15:0] pw_mask;
	wire [15:0]  p_dbg;
	n64_rdp_pix u_pix (
		.clk(clk), .rst(rst), .busy(p_busy), .drain(p_drain), .ce(pce),
		.om0(om0), .om1(om1), .comb0(comb0), .comb1(comb1),
		.fog_color(fog_color), .blend_color(blend_color), .prim_color(prim_color), .env_color(env_color),
		.key_center(key_center), .key_scale(key_scale), .k4(k4), .k5(k5),
		.prim_lod_frac(prim_lod_frac), .prim_min_level(prim_min_level), .tile(tile), .flip(flip), .fb_fmt(fb_fmt),
		.d_rgba_dx({d_rgba_dx[0], d_rgba_dx[1], d_rgba_dx[2], d_rgba_dx[3]}),
		.d_rgba_dy({d_rgba_dy[0], d_rgba_dy[1], d_rgba_dy[2], d_rgba_dy[3]}),
		.dz_dx(dz_dx), .dz_dy(dz_dy),
		.d_st_dx({d_st_dx[0], d_st_dx[1], d_st_dx[2]}), .d_st_dy({d_st_dy[0], d_st_dy[1], d_st_dy[2]}),
		.dzpix(dzpix), .dz_c(dz_c),
		.tw_all(tw_all), .tsz_all(tsz_all),
		.fa0(fa0), .fa1(fa1), .fa2(fa2), .fa3(fa3), .fq0(fq0), .fq1(fq1), .fq2(fq2), .fq3(fq3),
		.sa0(sa0), .sa1(sa1), .sa2(sa2), .sa3(sa3), .sq0(sq0), .sq1(sq1), .sq2(sq2), .sq3(sq3),
		.sp_valid(sp_valid), .sp_ready(sp_ready), .sp_x0(x), .sp_x1(x_end),
		.sp_xl({xleft[0], xleft[1], xleft[2], xleft[3]}), .sp_xr({xright[0], xright[1], xright[2], xright[3]}),
		.sp_acc({acc_rgba[0], acc_rgba[1], acc_rgba[2], acc_rgba[3], acc_z, acc_s, acc_t, acc_w}),
		.sp_slot(sp_slot),
		.sl_y({sl_y[1], sl_y[0]}), .sl_row({sl_row[1], sl_row[0]}),
		.sl_clo({sl_clo[1], sl_clo[0]}), .sl_zlo({sl_zlo[1], sl_zlo[0]}), .sl_filled(sl_filled),
		.rel(p_rel), .rel_slot(p_rel_slot),
		.sc_ra(sc_ra), .sc_q(sc_q), .sz_ra(sz_ra), .sz_q(sz_q),
		.fb_addr(fb_addr), .z_addr(z_addr),
		.mw_req(pw_req), .mw_ack(mw_ack && pw_req), .mw_line(pw_line), .mw_data(pw_data), .mw_mask(pw_mask),
		.dbg(p_dbg)
	);
	assign tm_ce = pce;
	// the line port: FILL mode's writes, or the pipeline's (never both: a FILL primitive
	// starts only once the pipeline is empty)
	assign mw_req = fw_req || pw_req;
	assign mw_line = fw_req ? fw_line : pw_line;
	assign mw_data = fw_req ? fw_data : pw_data;
	assign mw_mask = fw_req ? fw_mask : pw_mask;

	// the row's multipliers' other operands
	wire signed [15:0] dy16 = {{3{dy_s[12]}}, dy_s};
	wire signed [15:0] xf16 = {8'd0, xfrac};
	wire signed [15:0] dxb = $signed({3'd0, x}) - $signed(base_x[15:0]);   // x - base_x

	// =============================================================================
	// the sequence
	// =============================================================================
	localparam [4:0] S_IDLE = 5'd0, S_PRIM = 5'd1, S_Y = 5'd2, S_K0 = 5'd3, S_K1 = 5'd4, S_SPAN = 5'd5,
	                 S_ATTR = 5'd6, S_AINIT = 5'd7, S_PIX = 5'd8, S_NEXT = 5'd9, S_FLUSH = 5'd10, S_FWAIT = 5'd11,
	                 S_DONE = 5'd12, S_PUSH = 5'd13, S_LINE = 5'd21, S_DRAIN = 5'd22;
	reg  [4:0]   st, st_after;
	reg  [5:0]   sub;                     // a step within a state
	assign busy = st != S_IDLE || p_busy;
	integer      i;

	always @(posedge clk) begin
		if (mw_ack && fw_req) fw_req <= 1'b0;
		f_go <= 1'b0;
		if (sp_valid && sp_ready) sp_valid <= 1'b0;
		if (rst) begin
			st <= S_IDLE; fw_req <= 1'b0; lb_v <= 1'b0; lb_m <= 16'd0; at_ra <= 5'd0;
			sp_valid <= 1'b0; p_drain <= 1'b0; nslot <= 1'b0;
		end else case (st)
		// (a new primitive once the last one's pixels are all written: the pipeline uses
		// the primitive's state, and the next one's reads must see the last one's writes)
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
			4'd8: at_ra <= 5'd30; 4'd9: at_ra <= 5'd20; 4'd10: at_ra <= 5'd21; 4'd11: at_ra <= 5'd23;
			5'd12: at_ra <= 5'd28; 5'd13: at_ra <= 5'd29; 5'd14: at_ra <= 5'd31;
			// (then the values and edge slopes: 0-3, 16-19, 8-11, 24-27)
			5'd15: at_ra <= 5'd0;  5'd16: at_ra <= 5'd1;  5'd17: at_ra <= 5'd2;  5'd18: at_ra <= 5'd3;
			5'd19: at_ra <= 5'd16; 5'd20: at_ra <= 5'd17; 5'd21: at_ra <= 5'd18; 5'd22: at_ra <= 5'd19;
			5'd23: at_ra <= 5'd8;  5'd24: at_ra <= 5'd9;  5'd25: at_ra <= 5'd10; 5'd26: at_ra <= 5'd11;
			5'd27: at_ra <= 5'd24; 5'd28: at_ra <= 5'd25; 5'd29: at_ra <= 5'd26; default: at_ra <= 5'd27;
			endcase
			if (sub == 4'd11) d_st_dx[0] <= at_q;
			if (sub == 4'd12) d_st_dx[1] <= at_q;
			if (sub == 4'd13) d_st_dx[2] <= at_q;
			if (sub == 5'd14) d_st_dy[0] <= at_q;
			if (sub == 5'd15) d_st_dy[1] <= at_q;
			if (sub == 5'd16) d_st_dy[2] <= at_q;
			if (sub >= 5'd17 && sub <= 5'd24) at_v[sub - 5'd17] <= at_q;
			if (sub >= 5'd25) at_e[sub - 5'd25] <= at_q;
			if (sub == 6'd32) st <= S_Y;
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
		// the span: its lines asked for into a free slot (the fetcher one span at a time),
		// then its attributes, then it goes to the pipeline
		S_SPAN: begin : span
			reg [12:0] xe;
			xe = (sx_max[15:3] > {2'd0, width} - 13'd1) ? {2'd0, width} - 13'd1 : sx_max[15:3];
			x <= sx_min[15:3];
			x_end <= xe;
			sub <= 6'd0;
			if (all_inv || all_over || all_under || (sc_field && (y[0] != sc_odd))) st <= S_LINE;
			else if (sx_min[15:3] > xe) st <= S_LINE;
			else if (fill_mode) st <= S_PIX;
			else if (f_done && !sl_used[nslot] && !sp_valid) begin
				g_slot <= nslot;
				g_clo <= cline(row_px + {11'd0, sx_min[15:3]}, fb_fmt, fb_addr);
				g_nc <= cline(row_px + {11'd0, xe}, fb_fmt, fb_addr) - cline(row_px + {11'd0, sx_min[15:3]}, fb_fmt, fb_addr) + 20'd1;
				g_zlo <= zlinef(row_px + {11'd0, sx_min[15:3]}, z_addr);
				g_nz <= (z_cmp || z_upd) ? zlinef(row_px + {11'd0, xe}, z_addr) - zlinef(row_px + {11'd0, sx_min[15:3]}, z_addr) + 20'd1 : 9'd0;
				sl_y[nslot] <= y; sl_row[nslot] <= row_px;
				sl_clo[nslot] <= cline(row_px + {11'd0, sx_min[15:3]}, fb_fmt, fb_addr);
				sl_zlo[nslot] <= zlinef(row_px + {11'd0, sx_min[15:3]}, z_addr);
				f_go <= 1'b1;
				st <= S_ATTR;
			end
		end
		// the span's attributes, all eight at once: ((a + dy * de) & ~0x1FF) + diff - xfrac *
		// ((dx >> 8) & ~1), & ~0x3FF; then the running sums at the span's first pixel: that +
		// (d & ~0x1F) * (x - base_x) (z: dz * (x - base_x), unmasked). (z with SET_PRIM_DEPTH:
		// prim_depth << 16 and no slopes)
		S_ATTR: begin : attrs
			reg signed [31:0] av, ae, ax, ay, deh, dyh, diff, dm;
			sub <= sub + 6'd1;
			for (i = 0; i < 8; i = i + 1) begin
				av = (use_prim_depth && i == 6) ? {1'b0, prim_depth, 16'd0} : at_v[i];
				ae = (use_prim_depth && i == 6) ? 32'sd0 : at_e[i];
				ax = (use_prim_depth && i == 6) ? 32'sd0 : adx[i];
				ay = (use_prim_depth && i == 6) ? 32'sd0 : ady[i];
				case (sub)
				6'd0: begin
					pa_de[i] <= ae * dy16;
					pa_xf[i] <= ((ax >>> 8) & ~32'sd1) * xf16;
				end
				6'd1: begin
					deh = ae & ~32'sh1FF; dyh = ay & ~32'sh1FF;
					diff = do_offset ? deh - (deh >>> 2) - dyh + (dyh >>> 2) : 32'sd0;
					sp_v[i] <= (((av + pa_de[i][31:0]) & ~32'sh1FF) + diff - pa_xf[i][31:0]) & ~32'sh3FF;
				end
				6'd2: begin
					dm = (i == 6) ? dz_dx : (adx[i] & ~32'sh1F);
					pa_de[i] <= dm * dxb;
				end
				default: ;
				endcase
			end
			if (sub == 6'd3) begin
				for (i = 0; i < 4; i = i + 1) acc_rgba[i] <= sp_v[i] + pa_de[i][31:0];
				acc_s <= sp_v[4] + pa_de[4][31:0];
				acc_t <= sp_v[5] + pa_de[5][31:0];
				acc_z <= sp_v[6] + pa_de[6][31:0];
				acc_w <= sp_v[7] + pa_de[7][31:0];
				st <= S_PUSH;
			end
		end
		// to the pipeline (it takes the span from these registers on sp_ready)
		S_PUSH: begin
			sp_valid <= 1'b1; sp_slot <= nslot; nslot <= ~nslot; st <= S_LINE; end
		// FILL mode: the span's pixels in this line, all at once (byte k of a line is the fill
		// colour's byte k & 3, as fill_pixel_color gives each pixel its half or byte), into the
		// line held -- flushing it first if it is another
		S_PIX: begin
			if (pn == 3'd0) st <= S_LINE;                         // (4-bit: nothing written)
			else if (lb_v && lb_line != pline) begin
				st_after <= S_PIX; st <= S_FLUSH;
			end else begin : fl
				reg [4:0] room; reg [12:0] npx, last; reg [4:0] eb; reg [15:0] m;
				room = 5'd16 - {1'b0, pb};                          // bytes from this pixel to the line's end
				npx = (pn == 3'd4) ? {10'd0, room[4:2]} : (pn == 3'd2) ? {9'd0, room[4:1]} : {8'd0, room};
				last = (x + npx - 13'd1 > x_end) ? x_end : x + npx - 13'd1;
				eb = {1'b0, pb} + (last - x + 13'd1) * pn - 5'd1;  // the span's last byte in this line
				for (i = 0; i < 16; i = i + 1) begin
					lb[8 * i +: 8] <= fc32[31 - 8 * (i % 4) -: 8];
					m[i] = (i >= pb) && (i <= eb);
				end
				lb_m <= (lb_v ? lb_m : 16'd0) | m;
				lb_v <= 1'b1; lb_line <= pline;
				if (last >= x_end) st <= S_LINE;
				else x <= last + 13'd1;
			end
		end
		// (the registers the span went from are free once the pipeline took it)
		S_LINE: if (!sp_valid) begin
			if (y == y_last) begin
				if (fill_mode) begin st_after <= S_DONE; st <= lb_v ? S_FLUSH : S_DONE; end
				else st <= S_DRAIN;
			end else begin y <= y + 12'sd1; st <= S_Y; end
		end
		S_FLUSH: begin
			if (lb_m != 16'd0) begin
				fw_req <= 1'b1; fw_line <= {4'd0, lb_line}; fw_data <= lb; fw_mask <= lb_m;
				st <= S_FWAIT;
			end else st <= st_after;
			lb_v <= 1'b0; lb_m <= 16'd0;
		end
		S_FWAIT: if (mw_ack && fw_req) st <= st_after;
		// the primitive's last span is in: the pipeline writes its last lines, then is empty
		S_DRAIN: begin
			p_drain <= 1'b1;
			if (!p_busy && p_drain) begin p_drain <= 1'b0; st <= S_DONE; end
		end
		S_DONE: st <= S_IDLE;
		default: st <= S_IDLE;
		endcase
	end
	// [47:32] {st, f_iss, f_iph, f_got}  [31:16] {f_total, sl_used, sl_filled, nslot, fw_req, p_busy}  [15:0] the pipeline's
	assign dbg = {4'd0, y, st, f_iss, f_iph, f_got, f_total, sl_used, sl_filled, nslot, fw_req, p_busy, p_dbg};
endmodule

`default_nettype wire
