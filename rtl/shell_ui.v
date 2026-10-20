//////////////////////////////////////////////////////////////////////////////////
// shell_ui.v - the menu image's picture, composed by the board: the ESP32 sends a list of things
// to draw (esp32/console/ui_list.h: a background, rounded rectangles, outlines, text, images) and
// the fonts and images once; this draws each line from the list into a line buffer just before
// the TV scans it. A page is a couple of kilobytes of list, not 300 kB of pixels: the menu
// changes as fast as the list is written (rtl/shell_fb.v, the picture drawn on the ESP32 and
// sent, took seconds a page).
//
// The arithmetic is ui_list.h's, exactly (tools/menu/ui_model.cpp renders the same lists;
// sim/tb_shell_ui.v compares them pixel for pixel).
//
// Composing runs on the serialiser's clock (pclk5, 5 x the pixel clock, the same MMCM): line R
// is drawn into buffer R[0] from when line R - 2 has gone out of it (x 648 of line R - 2) --
// 4760 clocks, against ~3000 for the busiest line of the menu. Each line: the background (a
// pixel a clock, written), then each object in order, its pixels through the blend pipeline
// (read, multiply, add, write: a pixel a clock; five clocks' gap between objects so a read never
// passes a write still in the pipe).
//
// The bus (clk), by page:
//   0x0009  0x0000 "UI01"; 0x0004 CTRL [0] on; 0x0008 COMMIT (write: the list just written
//           shows from the next frame; read [0] not yet, [1] the bank showing -- write the other);
//           0x000C [0] a line was not finished in time (sticky; a write clears it);
//           0x0020-0x00BC the highlight (as shell_fb.v); 0x0100 + 4f each font's ascent
//   0x000A  0x0000 + 0x1000 b + 16 i + 4 k  object i of bank b, word k; 0x4000 + 0x1000 b +
//           byte: the strings of bank b (a word: four bytes, the first lowest); 0x8000 + 8 g + 4 k:
//           the glyph table, entry g = 256 font + glyph, word k
//   0x000B-0x000C  the fonts' pixels (128 kB: a word, four bytes)
//   0x000D-0x000F  the images (96 K pixels of RGBA 4444: a word, two pixels, the first lowest)
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_ui (
	// the bus (clk)
	input  wire        clk,
	input  wire        rst,
	input  wire        we,
	input  wire [19:0] addr,               // {page[3:0], offset}: pages 9-F
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	// the picture
	input  wire        pclk,
	input  wire        pclk5,
	input  wire [9:0]  x,                  // hdmi_tx's request (pclk)
	input  wire [9:0]  y,
	output wire [23:0] rgb,                // a pclk after the request
	// the built-in picture's progress bar (shell_screen's, clk); and whether the ESP32 has drawn
	input  wire [9:0]  prog_w,
	input  wire        prog_on,
	output wire        gfx
);
	wire [3:0]  pg  = addr[19:16];
	wire [15:0] off = addr[15:0];

	// ===================================================================================== memories
	// (written on clk, read on pclk5)
	reg [31:0] obj0 [0:511], obj1 [0:511], obj2 [0:511], obj3 [0:511];   // {bank, object}: words 0-3
	reg [7:0]  str0 [0:2047], str1 [0:2047], str2 [0:2047], str3 [0:2047]; // {bank, byte[11:2]}: lanes
	reg [31:0] gly0 [0:4095], gly1 [0:4095];                              // the glyph table
	(* ram_style = "block" *) reg [31:0] fnt [0:32767];                   // the fonts' pixels
	(* ram_style = "block" *) reg [31:0] img [0:49151];                   // the images
	reg [7:0]  asc [0:15];
	integer k;
	initial for (k = 0; k < 16; k = k + 1) asc[k] = 8'd0;
	// the built-in picture (bank 0 at power-up, until the ESP32 commits its first list): the
	// background, a panel, the progress bar -- shell_screen's text over it
	initial begin
		obj0[0] = 32'h10000000; obj1[0] = 32'h00078280; obj2[0] = 32'hFF463CA0; obj3[0] = 32'h00000000;
		obj0[1] = 32'h20960046; obj1[1] = 32'h0902D1F4; obj2[1] = 32'h10FFFFFF; obj3[1] = 32'h00000000;
		obj0[2] = 32'h30960046; obj1[2] = 32'h0912D1F4; obj2[2] = 32'h28FFFFFF; obj3[2] = 32'h00000000;
		obj0[3] = 32'h2102006E; obj1[3] = 32'h028029A4; obj2[3] = 32'h1EFFFFFF; obj3[3] = 32'h00000000;
		obj0[4] = 32'h2102006E; obj1[4] = 32'h02802800; obj2[4] = 32'hFF5064EB; obj3[4] = 32'h00000000;
		obj0[5] = 32'h00000000; obj1[5] = 32'h00000000; obj2[5] = 32'h00000000; obj3[5] = 32'h00000000;
	end

	// (the composer's state the bus reads back: declared here, before both clocks use it)
	reg [2:0] c_seen_s;
	reg        front, pend, c_seen5;                    // the bank shown; a commit waiting
	reg        ever = 1'b0;                             // (the ESP32's first list has shown)
	reg [2:0]  ever_s;
	reg overrun; reg [2:0] overrun_clr_s;

	wire w_obj = we && pg == 4'hA && off[15:14] == 2'b00;
	wire w_str = we && pg == 4'hA && off[15:14] == 2'b01;
	wire w_gly = we && pg == 4'hA && off[15];
	wire w_fnt = we && (pg == 4'hB || pg == 4'hC);
	wire w_img = we && (pg == 4'hD || pg == 4'hE || pg == 4'hF);
	wire [8:0]  oa = {off[12], off[11:4]};
	wire [10:0] sa = {off[12], off[11:2]};
	wire [11:0] ga = off[14:3];
	wire [14:0] fa = {pg[0] ^ 1'b1, off[15:2]};                            // B: 0, C: 1
	wire [16:0] ia = (pg == 4'hD) ? {3'b000, off[15:2]} : (pg == 4'hE) ? {3'b001, off[15:2]} : {3'b010, off[15:2]};
	always @(posedge clk) begin
		if (w_obj) case (off[3:2]) 2'd0: obj0[oa] <= wdata; 2'd1: obj1[oa] <= wdata; 2'd2: obj2[oa] <= wdata; default: obj3[oa] <= wdata; endcase
		if (w_str) begin str0[sa] <= wdata[7:0]; str1[sa] <= wdata[15:8]; str2[sa] <= wdata[23:16]; str3[sa] <= wdata[31:24]; end
		if (w_gly) begin if (off[2]) gly1[ga] <= wdata; else gly0[ga] <= wdata; end
		if (w_fnt) fnt[fa] <= wdata;
		if (w_img) img[ia] <= wdata;
		if (we && pg == 4'h9 && off[15:6] == 10'h004) asc[off[5:2]] <= wdata[7:0];
	end

	// ===================================================================================== registers
	reg on, commit_t, overrun_clr_t;
	always @(posedge clk) begin
		if (rst) begin on <= 1'b1; commit_t <= 1'b0; overrun_clr_t <= 1'b0; end   // (on: the built-in picture from power-up)
		else if (we && pg == 4'h9) begin
			if (off == 16'h0004) on <= wdata[0];
			if (off == 16'h0008) commit_t <= ~commit_t;
			if (off == 16'h000C) overrun_clr_t <= ~overrun_clr_t;
		end
	end
	// the composer's state, back on clk (two flops: it changes once a frame)
	reg front5, pend5, overrun5;
	reg [2:0] front_s, pend_s, over_s;
	always @(posedge clk) begin front_s <= {front_s[1:0], front5}; pend_s <= {pend_s[1:0], pend5}; over_s <= {over_s[1:0], overrun5}; end
	wire [31:0] hl_rdata;
	always @* begin
		case (off)
		16'h0000: rdata = 32'h5549_3031;   // "UI01"
		16'h0004: rdata = {31'd0, on};
		16'h0008: rdata = {30'd0, front_s[2], pend_s[2] | (commit_t ^ c_seen_s[2])};
		16'h000C: rdata = {31'd0, over_s[2]};
		default:  rdata = hl_rdata;
		endcase
		if (pg != 4'h9) rdata = 32'd0;
	end
	always @(posedge clk) c_seen_s <= {c_seen_s[1:0], c_seen5};
	always @(posedge clk) ever_s <= {ever_s[1:0], ever};
	assign gfx = ever_s[2];

	// ===================================================================================== the line schedule (pclk)
	// line R into buffer R[0] from x 648 of line R - 2 (wrapping over the frame's 525 lines)
	reg        go_t;                       // toggles: a line to compose
	reg [8:0]  go_line;
	wire [9:0] y2 = (y >= 10'd523) ? y - 10'd523 : y + 10'd2;
	always @(posedge pclk) begin
		if (x == 10'd648 && y2 < 10'd480) begin go_t <= ~go_t; go_line <= y2[8:0]; end
	end
	initial go_t = 1'b0;

	// ===================================================================================== the composer (pclk5)
	reg [2:0]  go_s; reg [8:0] L; reg buf_w;            // the line being composed, its buffer
	reg [1:0]  commit_s; reg c_last;
	initial begin front = 1'b0; pend = 1'b0; c_seen5 = 1'b0; c_last = 1'b0; end
	always @* begin front5 = front; pend5 = pend; end

	// ---- the blend pipeline: op (x, colour, a 0..256, write-only) -> the back buffer
	reg        op_v, op_wo; reg [9:0] op_x; reg [23:0] op_c; reg [8:0] op_a;
	reg [23:0] lb0 [0:1023], lb1 [0:1023];
	reg [23:0] rd0, rd1;                                 // the buffers' read ports
	wire [9:0] disp_x;                                   // (the display's read: below)
	wire [9:0] ra0 = buf_w ? disp_x : op_x;              // buffer 0: composer's read when it is the back one
	wire [9:0] ra1 = buf_w ? op_x : disp_x;
	always @(posedge pclk5) begin rd0 <= lb0[ra0]; rd1 <= lb1[ra1]; end
	wire [23:0] rdb = buf_w ? rd1 : rd0;                 // the back buffer's word, a clock after
	reg        s1_v, s1_wo; reg [9:0] s1_x; reg [23:0] s1_c; reg [8:0] s1_a;
	reg        sb_v, sb_wo; reg [9:0] sb_x; reg [23:0] sb_c, sb_d; reg [8:0] sb_a;   // (the word, registered)
	reg        s2_v; reg [9:0] s2_x; reg [23:0] s2_d; reg signed [17:0] s2_pr, s2_pg, s2_pb; reg s2_wo; reg [23:0] s2_c;
	reg        s3_v; reg [9:0] s3_x; reg [23:0] s3_w;
	wire signed [9:0] dr = $signed({1'b0, sb_c[23:16]}) - $signed({1'b0, sb_d[23:16]});
	wire signed [9:0] dg = $signed({1'b0, sb_c[15:8]})  - $signed({1'b0, sb_d[15:8]});
	wire signed [9:0] db = $signed({1'b0, sb_c[7:0]})   - $signed({1'b0, sb_d[7:0]});
	always @(posedge pclk5) begin
		s1_v <= op_v; s1_wo <= op_wo; s1_x <= op_x; s1_c <= op_c; s1_a <= op_a;
		sb_v <= s1_v; sb_wo <= s1_wo; sb_x <= s1_x; sb_c <= s1_c; sb_a <= s1_a; sb_d <= rdb;
		s2_v <= sb_v; s2_x <= sb_x; s2_d <= sb_d; s2_wo <= sb_wo; s2_c <= sb_c;
		s2_pr <= dr * $signed({1'b0, sb_a}); s2_pg <= dg * $signed({1'b0, sb_a}); s2_pb <= db * $signed({1'b0, sb_a});
		s3_v <= s2_v; s3_x <= s2_x;
		s3_w <= s2_wo ? s2_c : { s2_d[23:16] + s2_pr[15:8], s2_d[15:8] + s2_pg[15:8], s2_d[7:0] + s2_pb[15:8] };
		if (s3_v) begin if (buf_w) lb1[s3_x] <= s3_w; else lb0[s3_x] <= s3_w; end
	end

	// ---- the per-object engines' memory reads (registered addresses, data a clock later)
	reg [8:0]  o_ra; reg [31:0] o0, o1, o2, o3;
	reg [12:0] s_ra; reg [1:0] s_lane_q; reg [7:0] s_q0, s_q1, s_q2, s_q3;
	reg [11:0] g_ra; reg [31:0] g0q, g1q;
	reg [16:0] f_ra; reg [1:0] f_lane; reg [31:0] f_q;
	reg [16:0] i_ra; reg i_half; reg [31:0] i_q;
	always @(posedge pclk5) begin
		o0 <= obj0[o_ra]; o1 <= obj1[o_ra]; o2 <= obj2[o_ra]; o3 <= obj3[o_ra];
		s_q0 <= str0[s_ra[12:2]]; s_q1 <= str1[s_ra[12:2]]; s_q2 <= str2[s_ra[12:2]]; s_q3 <= str3[s_ra[12:2]]; s_lane_q <= s_ra[1:0];
		g0q <= gly0[g_ra]; g1q <= gly1[g_ra];
		f_q <= fnt[f_ra[16:2]];
		i_q <= img[i_ra[16:1]];
	end
	wire [7:0] s_byte = s_lane_q == 2'd0 ? s_q0 : s_lane_q == 2'd1 ? s_q1 : s_lane_q == 2'd2 ? s_q2 : s_q3;

	// ---- the composer's sequence
	localparam S_IDLE = 0, S_BG = 1, S_OBJ = 2, S_OWAIT = 3, S_ODEC = 4, S_RECT = 5, S_TCH = 6, S_TCW = 7,
	           S_TGW = 8, S_TGD = 9, S_TPX = 10, S_IMG = 11, S_GAP = 12, S_NEXT = 13;
	reg [4:0]  st;
	reg [8:0]  oi;                          // the object
	reg [3:0]  gap;
	reg [9:0]  dy2_0;                       // (scratch)
	// the object as decoded
	reg [3:0]  ty; reg signed [11:0] ox, oy; reg [9:0] ow, oh; reg [4:0] orr; reg [2:0] oth; reg [23:0] oc; reg [7:0] oa_;
	reg [31:0] ow3;
	// rect engine state
	reg signed [11:0] px;                   // the pixel being issued
	reg signed [11:0] pend_x;               // last pixel of the span
	// the coverage pipeline (outer and inner rectangles)
	reg signed [11:0] yy_o, yy_i; reg [10:0] cy_o, cy_i;
	reg signed [11:0] ix, iy; reg [9:0] iw, ih; reg [4:0] ir;   // the inner rectangle (outlines)
	reg [21:0] Dy2_o, Dy2_i; reg [21:0] E2_o, E2_i; reg [20:0] inv_o, inv_i;
	reg        rowin_o, rowin_i;
	// text
	reg [7:0]  t_n, t_left; reg [12:0] t_sa; reg [3:0] t_f; reg signed [11:0] pen;
	reg [16:0] g_at; reg [5:0] g_w, g_h, g_adv; reg signed [7:0] g_dx, g_dy;
	reg [5:0]  t_xx; reg [16:0] t_base; reg [5:0] t_rb;
	// image
	reg [16:0] im_base; reg [9:0] im_xx;

	// the inverse table: 64 / (2R + 1) in 16 fractional bits
	function [20:0] invE; input [4:0] r; reg [6:0] e; begin e = {r, 1'b1}; invE = (21'd4194304 + {14'd0, e} / 7'd2) / {14'd0, e}; end endfunction
	reg [20:0] inv_tab [0:31];
	// (worked out inline: a function called in an initial loop is one of xsim's traps)
	initial for (k = 0; k < 32; k = k + 1) inv_tab[k] = (4194304 + (2 * k + 1) / 2) / (2 * k + 1);

	// ---- coverage: a pixel's cover by a rounded rectangle (and, for an outline, by the one inside it),
	// seven clocks after its x -- a step a clock, as 126 MHz wants:
	//   a the pixel; b where it is in each rectangle; c its corner distances; d the squared distance;
	//   e how far inside the edge; f times 64 / (2R + 1); g clamped, the outline's ring
	reg signed [11:0] ca_px; reg ca_v;
	reg signed [11:0] cb_px, cb_xo, cb_xi; reg cb_v;
	reg signed [11:0] c3_px; reg c3_v, c3_in_o, c3_in_i, c3_full_o, c3_full_i; reg [11:0] c3_dxo, c3_dxi;
	reg signed [11:0] c4_px; reg c4_v, c4_in_o, c4_in_i, c4_full_o, c4_full_i; reg [21:0] c4_qo, c4_qi;
	reg signed [11:0] c5_px; reg c5_v, c5_in_o, c5_in_i, c5_full_o, c5_full_i; reg [21:0] c5_no, c5_ni;
	reg signed [11:0] c6_px; reg c6_v, c6_in_o, c6_in_i, c6_full_o, c6_full_i; reg [42:0] c6_vo, c6_vi;
	reg [8:0]  cc_cov; reg cc_v; reg signed [11:0] cc_px;
	reg [8:0]  ch_ae; reg ch_v; reg signed [11:0] ch_px;
	reg        r_emit;                       // the rect engine is issuing r_px
	reg signed [11:0] r_px;
	function [10:0] cornd; input signed [11:0] xx; input [9:0] w; input [4:0] r;
		begin
			if (xx < $signed({7'd0, r})) cornd = {6'd0, r} - xx[10:0];
			else if (xx >= $signed({2'b0, w}) - $signed({7'd0, r})) cornd = xx[10:0] - ({1'b0, w} - {6'd0, r} - 11'd1);
			else cornd = 11'd0;
		end
	endfunction
	always @(posedge pclk5) begin
		ca_v <= r_emit; ca_px <= r_px;
		cb_v <= ca_v; cb_px <= ca_px; cb_xo <= ca_px - ox; cb_xi <= ca_px - ix;
		c3_v <= cb_v; c3_px <= cb_px;
		c3_in_o <= rowin_o && cb_xo >= 0 && cb_xo < $signed({2'b0, ow});
		c3_in_i <= (ty == 4'd3) && rowin_i && cb_xi >= 0 && cb_xi < $signed({2'b0, iw}) && iw != 10'd0 && ih != 10'd0;
		begin : c3c
			reg [10:0] cxo, cxi;
			cxo = cornd(cb_xo, ow, orr);
			cxi = cornd(cb_xi, iw, ir);
			c3_full_o <= (cxo == 11'd0) || (cy_o == 11'd0);
			c3_full_i <= (cxi == 11'd0) || (cy_i == 11'd0);
			c3_dxo <= {cxo, 1'b0} - 12'd1; c3_dxi <= {cxi, 1'b0} - 12'd1;
		end
		c4_v <= c3_v; c4_px <= c3_px; c4_in_o <= c3_in_o; c4_in_i <= c3_in_i; c4_full_o <= c3_full_o; c4_full_i <= c3_full_i;
		c4_qo <= c3_dxo * c3_dxo + Dy2_o; c4_qi <= c3_dxi * c3_dxi + Dy2_i;
		c5_v <= c4_v; c5_px <= c4_px; c5_in_o <= c4_in_o; c5_in_i <= c4_in_i; c5_full_o <= c4_full_o; c5_full_i <= c4_full_i;
		c5_no <= (E2_o > c4_qo) ? E2_o - c4_qo : 22'd0; c5_ni <= (E2_i > c4_qi) ? E2_i - c4_qi : 22'd0;
		c6_v <= c5_v; c6_px <= c5_px; c6_in_o <= c5_in_o; c6_in_i <= c5_in_i; c6_full_o <= c5_full_o; c6_full_i <= c5_full_i;
		c6_vo <= c5_no * inv_o; c6_vi <= c5_ni * inv_i;
		cc_v <= c6_v; cc_px <= c6_px;
		begin : ccov
			reg [8:0] co, ci;
			co = !c6_in_o ? 9'd0 : c6_full_o ? 9'd256 : (c6_vo[42:16] > 27'd256) ? 9'd256 : c6_vo[24:16];
			ci = !c6_in_i ? 9'd0 : c6_full_i ? 9'd256 : (c6_vi[42:16] > 27'd256) ? 9'd256 : c6_vi[24:16];
			cc_cov <= (co > ci) ? co - ci : 9'd0;
		end
		ch_v <= cc_v && cc_cov != 9'd0 && cc_px >= 0 && cc_px < 12'sd640; ch_px <= cc_px;
		begin : cha reg [16:0] t; t = oa_ * cc_cov; ch_ae <= t[16:8]; end
	end

	// ---- the font and image pixel pipelines: the address issued; the word a clock later; the pixel
	// picked out a clock after that (registered); then the blend's op
	reg        tp_v, tp_v2, tp_v3; reg signed [11:0] tp_x, tp_x2, tp_x3; reg tp_nib, tp_nib2; reg [3:0] tp_val3;
	reg        ip_v, ip_v2, ip_v3; reg signed [11:0] ip_x, ip_x2, ip_x3; reg ip_half2; reg [15:0] ip_px3;
	reg [1:0]  f_lane2;
	reg        tp_v4, ip_v4; reg signed [11:0] tp_x4, ip_x4; reg [7:0] tp_ae4, ip_ae4; reg [23:0] ip_c4;
	wire [7:0] f_byte = f_lane2 == 2'd0 ? f_q[7:0] : f_lane2 == 2'd1 ? f_q[15:8] : f_lane2 == 2'd2 ? f_q[23:16] : f_q[31:24];
	wire [3:0] f_v = tp_nib2 ? f_byte[7:4] : f_byte[3:0];
	wire [15:0] i_px = ip_half2 ? i_q[31:16] : i_q[15:0];
	always @(posedge pclk5) begin
		tp_v2 <= tp_v; tp_x2 <= tp_x; tp_nib2 <= tp_nib; f_lane2 <= f_ra[1:0];
		ip_v2 <= ip_v; ip_x2 <= ip_x; ip_half2 <= i_ra[0];
		tp_v3 <= tp_v2 && f_v != 4'd0 && tp_x2 >= 0 && tp_x2 < 12'sd640; tp_x3 <= tp_x2; tp_val3 <= f_v;
		ip_v3 <= ip_v2 && i_px[3:0] != 4'd0 && ip_x2 >= 0 && ip_x2 < 12'sd640; ip_x3 <= ip_x2; ip_px3 <= i_px;
		tp_v4 <= tp_v3; tp_x4 <= tp_x3;
		begin : t4 reg [15:0] t; t = oa_ * {tp_val3, tp_val3}; tp_ae4 <= (tp_val3 == 4'hF) ? oa_ : t[15:8]; end
		ip_v4 <= ip_v3; ip_x4 <= ip_x3;
		ip_c4 <= {ip_px3[15:12], ip_px3[15:12], ip_px3[11:8], ip_px3[11:8], ip_px3[7:4], ip_px3[7:4]};
		begin : i4 reg [15:0] t; t = oa_ * {ip_px3[3:0], ip_px3[3:0]}; ip_ae4 <= (ip_px3[3:0] == 4'hF) ? oa_ : t[15:8]; end
	end

	// ---- the background pipeline: x issued, the colour five clocks later
	reg [9:0]  bg_x; reg bg_v;
	reg [7:0]  base_r, base_g, base_b; reg [18:0] dy2;   // per line
	reg [23:0] acc;
	reg [9:0]  b1_x; reg b1_v; reg [20:0] b1_dx2;
	reg [9:0]  b2_x; reg b2_v; reg b2_in; reg [12:0] b2_s;
	reg [9:0]  b3_x; reg b3_v; reg [25:0] b3_sq;
	reg [9:0]  b4_x; reg b4_v; reg [7:0] b4_k;
	reg [9:0]  b5_x; reg b5_v; reg signed [17:0] b5_mr, b5_mg, b5_mb;
	reg [9:0]  b6_x; reg b6_v; reg [23:0] b6_c;
	wire signed [10:0] bdx = $signed({1'b0, bg_x}) - 11'sd90;
	always @(posedge pclk5) begin
		b1_v <= bg_v; b1_x <= bg_x; b1_dx2 <= bdx * bdx;
		b2_v <= b1_v; b2_x <= b1_x;
		begin : b2s reg [21:0] d2; d2 = {1'b0, b1_dx2} + {3'd0, dy2}; b2_in <= d2 < 22'd115600; b2_s <= (22'd115600 - d2) >> 4; end
		b3_v <= b2_v; b3_x <= b2_x; b3_sq <= b2_in ? b2_s * b2_s : 26'd0;
		b4_v <= b3_v; b4_x <= b3_x;
		begin : b4k reg [32:0] t; t = b3_sq * 7'd105; b4_k <= t[32:26]; end
		b5_v <= b4_v; b5_x <= b4_x;
		begin : b5c
			reg signed [9:0] er, eg, eb;
			er = $signed({1'b0, acc[23:16]}) - $signed({1'b0, base_r}); b5_mr <= er * $signed({1'b0, b4_k});
			eg = $signed({1'b0, acc[15:8]})  - $signed({1'b0, base_g}); b5_mg <= eg * $signed({1'b0, b4_k});
			eb = $signed({1'b0, acc[7:0]})   - $signed({1'b0, base_b}); b5_mb <= eb * $signed({1'b0, b4_k});
		end
		b6_v <= b5_v; b6_x <= b5_x;
		b6_c <= { base_r + b5_mr[15:8], base_g + b5_mg[15:8], base_b + b5_mb[15:8] };
	end

	// ---- the sequence
	localparam S_L1 = 14, S_L2 = 15, S_OP1 = 16, S_OP2 = 17, S_OP3 = 18, S_TG2 = 19, S_TG3 = 20, S_ODEC2 = 21, S_OP4 = 22;
	reg [31:0] ol0, ol1, ol2, ol3;           // (the object's words, out of the block RAM's slow outputs)
	reg [15:0] budget;                       // clocks since the line began (overrun if it ends past the next)
	reg        busy;
	reg [8:0]  t8_r, lr_r;                   // (line setup)
	reg        o_in;                         // (the object is on this line)
	reg signed [11:0] yo_r, yi_r; reg [9:0] ihh_r; reg [4:0] irr_r; reg [10:0] cyo_r, cyi_r; reg [9:0] rowoff;
	reg signed [11:0] gy0_r, rr_r; reg [5:0] rb_r;
	always @(posedge pclk5) begin
		go_s <= {go_s[1:0], go_t};
		commit_s <= {commit_s[0], commit_t};
		op_v <= 1'b0; op_wo <= 1'b0;
		bg_v <= 1'b0; r_emit <= 1'b0; tp_v <= 1'b0; ip_v <= 1'b0;
		if (commit_s[1] != c_last) begin c_last <= commit_s[1]; pend <= 1'b1; c_seen5 <= commit_s[1]; end
		if (busy) budget <= budget + 16'd1;
		// the outputs of the pipelines into the blend pipeline (only one runs at a time)
		if (b6_v) begin op_v <= 1'b1; op_wo <= 1'b1; op_x <= b6_x; op_c <= b6_c; op_a <= 9'd256; end
		if (ch_v) begin op_v <= 1'b1; op_x <= ch_px[9:0]; op_c <= oc; op_a <= ch_ae + {8'd0, ch_ae[7]}; end
		if (tp_v4) begin op_v <= 1'b1; op_x <= tp_x4[9:0]; op_c <= oc; op_a <= {1'b0, tp_ae4} + {8'd0, tp_ae4[7]}; end
		if (ip_v4) begin op_v <= 1'b1; op_x <= ip_x4[9:0]; op_c <= ip_c4; op_a <= {1'b0, ip_ae4} + {8'd0, ip_ae4[7]}; end
		case (st)
		// a line: its number in, then the background's constants over two clocks
		S_IDLE: if (go_s[2] != go_s[1]) begin
			L <= go_line; buf_w <= go_line[0]; busy <= 1'b1; budget <= 16'd0;
			if (go_line == 9'd0 && pend) begin front <= ~front; pend <= 1'b0; ever <= 1'b1; end
			st <= S_L1;
		end
		S_L1: begin
			begin : l1 reg [16:0] t; t = (17'd480 - {8'd0, L}) * 17'd136; t8_r <= t[16:8]; end
			lr_r <= L + 9'd30;
			st <= S_L2;
		end
		S_L2: begin
			base_r <= 8'd13 + (({8'd0, t8_r[7:0]} * 16'd9) >> 8); base_g <= 8'd15 + (({8'd0, t8_r[7:0]} * 16'd7) >> 8);
			base_b <= 8'd34 + (({8'd0, t8_r[7:0]} * 16'd18) >> 8);
			dy2 <= {10'd0, lr_r} * {10'd0, lr_r};
			oi <= 9'd0; st <= S_OBJ;
		end
		S_OBJ: begin o_ra <= {front, oi[7:0]}; st <= S_OWAIT; end
		S_OWAIT: st <= S_ODEC;
		// the object: its words latched, then taken apart (and whether it is on this line)
		S_ODEC: begin ol0 <= o0; ol1 <= o1; ol2 <= o2; ol3 <= o3; st <= S_ODEC2; end
		S_ODEC2: begin
			ty <= ol0[31:28]; ox <= {2'b00, ol0[9:0]}; oy <= {2'b00, ol0[25:16]};
			ow <= (!ever && oi == 9'd3) ? (prog_on ? 10'd420 : 10'd0) : (!ever && oi == 9'd4) ? (prog_on ? prog_w : 10'd0) : ol1[9:0];
			oh <= ol1[19:10]; orr <= ol1[27:23]; oth <= ol1[22:20];
			oc <= ol2[23:0]; oa_ <= ol2[31:24]; ow3 <= ol3;
			o_in <= {1'b0, L} >= {1'b0, ol0[25:16]} && {1'b0, L} < {1'b0, ol0[25:16]} + {1'b0, ol1[19:10]};
			if (ol0[31:28] == 4'd0) begin st <= S_GAP; gap <= 4'd8; oi <= 9'd256; end
			else st <= S_OP1;
		end
		// ... its line constants, a step a clock
		S_OP1: begin
			yo_r <= $signed({3'b0, L}) - oy;
			ihh_r <= (oh > {6'd0, oth, 1'b0}) ? oh - {6'd0, oth, 1'b0} : 10'd0;
			irr_r <= (orr > {2'd0, oth}) ? orr - {2'd0, oth} : 5'd0;
			rowoff <= L - oy[8:0];
			if (ty == 4'd1) begin
				acc <= oc; bg_x <= 10'd0; bg_v <= 1'b1; st <= S_RECT;
			end else if (!o_in || ow == 10'd0) st <= S_NEXT;
			else if (ty == 4'd4) begin
				t_n <= ow3[27:20]; t_left <= ow3[27:20]; t_sa <= ow3[12:0]; t_f <= ow3[31:28]; pen <= ox;
				st <= (ow3[27:20] == 8'd0) ? S_NEXT : S_TCH;
			end else if (ty == 4'd2 || ty == 4'd3 || ty == 4'd5) st <= S_OP2;
			else st <= S_NEXT;
		end
		S_OP2: begin
			yi_r <= yo_r - $signed({9'd0, oth});
			cyo_r <= cornd(yo_r, oh, orr);
			E2_o <= {16'd0, orr, 1'b1} * {16'd0, orr, 1'b1}; E2_i <= {16'd0, irr_r, 1'b1} * {16'd0, irr_r, 1'b1};
			inv_o <= inv_tab[orr]; inv_i <= inv_tab[irr_r];
			ix <= ox + $signed({9'd0, oth});
			iw <= (ow > {6'd0, oth, 1'b0}) ? ow - {6'd0, oth, 1'b0} : 10'd0;
			ih <= ihh_r; ir <= irr_r;
			im_base <= ow3[16:0] + rowoff * ow; im_xx <= 10'd0;
			st <= (ty == 4'd5) ? S_IMG : S_OP3;
		end
		S_OP3: begin
			cy_o <= cyo_r; cy_i <= cornd(yi_r, ihh_r, irr_r);
			rowin_o <= 1'b1; rowin_i <= (yi_r >= 0) && (yi_r < $signed({2'b0, ihh_r}));
			st <= S_OP4;
		end
		S_OP4: begin
			begin : op4 reg [11:0] dyo, dyi;
				dyo = {cy_o, 1'b0} - 12'd1; dyi = {cy_i, 1'b0} - 12'd1;
				Dy2_o <= dyo * dyo; Dy2_i <= dyi * dyi;
			end
			px <= ox; pend_x <= ox + $signed({2'b0, ow}) - 12'sd1;
			st <= S_RECT;
		end
		// the background, and the rectangles: a pixel a clock through their pipelines
		S_RECT: begin
			if (ty == 4'd1) begin
				if (bg_x == 10'd639) begin st <= S_GAP; gap <= 4'd10; end
				else begin bg_x <= bg_x + 10'd1; bg_v <= 1'b1; end
			end else begin
				r_emit <= 1'b1; r_px <= px;
				if (px == pend_x) begin st <= S_GAP; gap <= 4'd10; end
				else px <= px + 12'sd1;
			end
		end
		// text: the character, its glyph, its row's pixels
		S_TCH: begin s_ra <= {front, t_sa[11:0]}; st <= S_TCW; end
		S_TCW: st <= S_TGW;                                   // (the byte a clock later; registered)
		S_TGW: begin
			begin : gi reg [7:0] c; reg [7:0] idx;
				c = s_byte;
				idx = (c >= 8'd32 && c <= 8'd126) ? c - 8'd32 : (c >= 8'd160) ? c - 8'd65 : 8'd31;   // (160-255 -> 95-190; else '?')
				g_ra <= {t_f, idx};
			end
			st <= S_TGD; gap <= 4'd1;
		end
		S_TGD: if (gap != 4'd0) gap <= gap - 4'd1; else begin
			// the glyph: [16:0] at, [22:17] w, [28:23] h; [5:0] adv, [13:6] dx, [21:14] dy
			g_at <= g0q[16:0]; g_w <= g0q[22:17]; g_h <= g0q[28:23];
			g_adv <= g1q[5:0]; g_dx <= g1q[13:6]; g_dy <= g1q[21:14];
			gy0_r <= oy + $signed({4'd0, asc[t_f]}) + $signed({{4{g1q[21]}}, g1q[21:14]});
			rb_r <= (g0q[22:17] + 6'd1) >> 1;
			st <= S_TG2;
		end
		S_TG2: begin rr_r <= $signed({3'b0, L}) - gy0_r; st <= S_TG3; end
		S_TG3: begin
			t_base <= g_at + rr_r[5:0] * rb_r;
			t_xx <= 6'd0;
			if (rr_r >= 0 && rr_r < $signed({6'd0, g_h}) && g_w != 6'd0) st <= S_TPX;
			else begin st <= S_GAP; gap <= 4'd0; end
		end
		S_TPX: begin
			f_ra <= t_base + {12'd0, t_xx[5:1]};
			tp_v <= 1'b1; tp_x <= pen + $signed({{4{g_dx[7]}}, g_dx}) + $signed({6'd0, t_xx}); tp_nib <= t_xx[0];
			if (t_xx + 6'd1 >= g_w) begin st <= S_GAP; gap <= 4'd6; end
			else t_xx <= t_xx + 6'd1;
		end
		S_IMG: begin
			i_ra <= im_base + {7'd0, im_xx};
			ip_v <= 1'b1; ip_x <= ox + $signed({2'b0, im_xx});
			if (im_xx + 10'd1 >= ow) begin st <= S_GAP; gap <= 4'd6; end
			else im_xx <= im_xx + 10'd1;
		end
		// the pipes drain (a read must not pass a write still in them)
		S_GAP: if (gap != 4'd0) gap <= gap - 4'd1; else begin
			if (ty == 4'd4 && t_left > 8'd1 && oi != 9'd256) begin
				// the next character
				pen <= pen + $signed({6'd0, g_adv}); t_left <= t_left - 8'd1; t_sa <= t_sa + 13'd1; st <= S_TCH;
			end else st <= S_NEXT;
		end
		S_NEXT: begin
			if (oi >= 9'd255) begin st <= S_IDLE; busy <= 1'b0; if (budget > 16'd4700) overrun <= 1'b1; end
			else begin oi <= oi + 9'd1; st <= S_OBJ; ty <= 4'd0; end
		end
		default: st <= S_IDLE;
		endcase
		if (st == S_GAP && oi == 9'd256 && gap == 4'd0) begin st <= S_IDLE; busy <= 1'b0; if (budget > 16'd4700) overrun <= 1'b1; end
		if (overrun_clr_s[2] != overrun_clr_s[1]) overrun <= 1'b0;
	end
	initial begin st = S_IDLE; overrun = 1'b0; busy = 1'b0; end
	always @(posedge pclk5) overrun_clr_s <= {overrun_clr_s[1:0], overrun_clr_t};
	always @* overrun5 = overrun;

	// ===================================================================================== the display (pclk)
	// the line buffer for the request (read on pclk5, steady four of its clocks before pclk takes it)
	assign disp_x = x;
	reg [23:0] dpx; reg dsel; reg in1, on1, on2;
	always @(posedge pclk) begin
		dsel <= y[0];
		in1 <= x < 10'd640 && y < 10'd480; on1 <= on; on2 <= on1;
	end
	always @(posedge pclk) dpx <= y[0] ? rd1 : rd0;     // (the front buffer is y[0]; its read port is the display's)
	wire [23:0] base = (in1 && on2) ? dpx : 24'd0;

	// the highlight over it (shell_fb.v's, unchanged)
	shell_hl u_hl (.clk(clk), .rst(rst), .we(we && pg == 4'h9), .off(off), .wdata(wdata), .rdata(hl_rdata),
		.pclk(pclk), .x(x), .y(y), .base(base), .rgb(rgb));
endmodule

`default_nettype wire
