//////////////////////////////////////////////////////////////////////////////////
// n64_vid.v - the N64's (and the PlayStation's) picture for HDMI, and what is done to
// it on the way: a four-line ring between n64_top / fb_ddr (which fetch the source
// lines out of DDR3, clk) and hdmi_tx (which asks for a pixel a clock ahead, pclk).
//
// The fetch side: the pixel side says which source line it needs next (want); the
// fetcher puts line n into slot n & 3. A source line is 320 pixels or fewer (shown
// doubled, 640x480) or up to 640 (shown 1:1); N64 16-bit RGBA5551 or 32-bit RGBA8888,
// as VI_STATUS says, or the PlayStation's RGB555. Written a 128-bit DDR3 line at a
// time (slot, word): a line's bytes little-endian in the word (byte k at 8k+7:8k) and
// the N64's pixels big-endian in them, as n64_top's frame reads. Bits 143:128 of a
// word are the N64's hidden coverage bits for its 8 pixels (pixel i at 2i+1:2i), when
// the fetcher has them (hid_ok); else a pixel's coverage is its alpha bit only.
//
// The pixel side keeps a window of the source around the pixel -- the line above, the
// line, the line below; x-2..x+2 on the line, x-1..x+1 above and below -- read out of
// the ring a word at a time by three row readers, and runs it through the filters the
// real VI has, as MAME's notes on it (rdpfiltr.ipp) and Nintendo's patents describe:
//   anti-aliasing (US5742277): a pixel not fully covered is blended toward a
//     background guessed from its fully covered neighbours on a checkerboard (x-1 and
//     x+1 above and below, x-2 and x+2 beside): the second-largest plus the second-
//     smallest, less the pixel;
//   restore / dedither (US5699079): a fully covered 16-bit pixel moves one step up
//     for each of its 8 neighbours brighter than it, one down for each darker;
//   divot: a pixel by an edge takes the median of itself and the two beside it;
//   gamma (the game's VI_STATUS bit 3): the square root curve.
// Then the picture is scaled to the screen: replicated, smoothed (the VI's own
// horizontal interpolation, or both ways), or edge-directed (Scale2x's rule, blended
// half way); and scanlines, if asked for. What the game asks of the VI is the default;
// the settings (opt) can switch each part off or on.
//
// opt: [1:0] scaling: 0 as the console (N64: VI resample; PS1: sharp), 1 sharp,
//            2 smooth, 3 edge-directed
//      [3:2] scanlines: 0 off, 1 light, 2 heavy
//      [5:4] the N64's VI filters: 0 as the game sets them, 1 off, 2 all on
//      [6]   dedither always (the PlayStation's too)
//      [7]   no gamma
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_vid #(
	parameter PS1 = 0,                 // 1: the PlayStation's frame (fb_ddr): RGB555, R in the low
	                                   // bits, pixel n of a word at bits 16n+15:16n
	parameter H_TOT = 800, parameter V_TOT = 525   // hdmi_tx's line and frame
)(
	// the fetch side (clk)
	input  wire         clk,
	input  wire         wr_en,
	input  wire [8:0]   wr_addr,           // {slot, word}
	input  wire [143:0] wr_data,
	output reg  [8:0]   want,              // (clk) the source line the pixel side needs next
	input  wire [11:0]  width,             // VI_WIDTH (pixels a line)
	input  wire [9:0]   height,            // source lines in the picture (240 / 480 for the N64)
	input  wire         bpp32,
	input  wire         on,                // VI is showing a picture
	input  wire         hid_ok,            // the words carry the hidden coverage bits
	input  wire [16:0]  vist,              // VI_STATUS (what the game asked of the VI)
	input  wire [15:0]  opt,               // the settings (above)
	// the pixel side (pclk)
	input  wire         pclk,
	input  wire [9:0]   x,
	input  wire [9:0]   y,
	input  wire         req,
	output reg  [23:0]  rgb
);
	(* ram_style = "block" *) reg [143:0] lbuf [0:511];
	always @(posedge clk) if (wr_en) lbuf[wr_addr] <= wr_data;

	// --- the settings, into pclk (they change between frames: two flops each) ----------------
	reg [11:0] w1, w2; reg [9:0] h1, h2; reg b1, b2, o1, o2, k1, k2; reg [16:0] v1, v2; reg [15:0] p1, p2;
	always @(posedge pclk) begin
		w1 <= width; w2 <= w1; h1 <= height; h2 <= h1; b1 <= bpp32; b2 <= b1; o1 <= on; o2 <= o1;
		k1 <= hid_ok; k2 <= k1; v1 <= vist; v2 <= v1; p1 <= opt; p2 <= p1;
	end
	wire       dbl  = w2 <= 12'd320;                      // shown doubled
	wire       b32  = !PS1 && b2;
	wire [9:0] wpx  = w2[9:0];                            // (640 at most)
	wire [9:0] hgt  = (h2 == 10'd0) ? 10'd1 : h2;
	// a doubled picture narrower than 320 is centred: it starts (640 - 2w) / 2 in
	wire [9:0] xoff = dbl ? 10'd320 - wpx : 10'd0;
	wire [10:0] span = dbl ? {wpx, 1'b0} : {1'b0, wpx};
	wire [1:0] vf   = p2[5:4];
	wire [1:0] aam  = v2[9:8];
	wire       en_aa = !PS1 && ((vf == 2'd0 && aam[1] == 1'b0) || vf == 2'd2);
	wire       en_dd = !b32 && (PS1 ? p2[6] : ((vf == 2'd0 && v2[16]) || vf == 2'd2 || p2[6]));
	wire       en_dv = !PS1 && ((vf == 2'd0 && v2[4]) || vf == 2'd2);
	wire       en_gm = !PS1 && v2[3] && !p2[7];
	wire [1:0] scl  = !dbl ? 2'd1 : (p2[1:0] != 2'd0) ? p2[1:0] : (!PS1 && aam != 2'd3) ? 2'd0 : 2'd1;   // 0: VI resample
	wire [1:0] scan = dbl ? p2[3:2] : 2'd0;

	// --- where the picture is ---------------------------------------------------------------
	// co: the column the output stage makes this clock (x + 1: two stages follow it), on line cy
	reg [9:0] co, cy;
	always @(posedge pclk) begin
		if ({1'b0, x} + 11'd2 >= H_TOT) begin co <= x + 10'd2 - H_TOT; cy <= (y == V_TOT - 1) ? 10'd0 : y + 10'd1; end
		else begin co <= x + 10'd2; cy <= y; end
	end
	wire [9:0]  cn  = (co == H_TOT - 1) ? 10'd0 : co + 10'd1;     // next clock's column (same line while it matters)
	wire [10:0] reln = {1'b0, cn} - {1'b0, xoff};
	wire        adv_n = cn >= xoff && cn < 10'd640 && reln < span && reln != 11'd0 && (!dbl || !reln[0]);
	// the line being made ready (the next one from the blanking on)
	wire [9:0]  cyn = (cy == V_TOT - 1) ? 10'd0 : cy + 10'd1;
	wire [9:0]  cyp = (co >= 10'd640) ? cyn : cy;

	// the line wanted next: while row s shows, the window is on s+1 (rows s..s+2 read) and s+3
	// is fetched; in the blanking 0, then 1 (the line before the picture's first works out row
	// 0's filtered pixels: its window needs rows 0 and 1), then 2
	// (never past the picture's last row: the window there is clamped onto rows the ring still
	// holds, and a row fetched below them would land on one of them)
	reg [8:0] want_p;
	wire [9:0] want_r = (cyp >= 10'd480) ? ((cyp == V_TOT - 2) ? 10'd1 : (cyp == V_TOT - 1) ? 10'd2 : 10'd0)
	                                     : (dbl ? {1'b0, cyp[9:1]} : cyp) + 10'd3;
	always @(posedge pclk) want_p <= (want_r >= hgt) ? hgt[8:0] - 9'd1 : want_r[8:0];
	reg [8:0] wa, wb;
	always @(posedge clk) begin
		wa <= want_p; wb <= wa;
		if (wa == wb) want <= wb;
	end

	// --- the row readers ------------------------------------------------------------------
	// three of them -- 0 the line above, 1 the line, 2 the line below -- each with the word
	// it is taking pixels from (cw) and the one after (nw), refilled through the one port
	localparam ST_IDLE = 3'd0, ST_WAIT = 3'd1, ST_LOAD = 3'd2, ST_SH1 = 3'd3, ST_SH2 = 3'd4,
	           ST_ADV1 = 3'd5, ST_ADV2 = 3'd6, ST_RUN = 3'd7;
	reg [2:0]   st;
	reg [143:0] cw0, cw1, cw2, nw0, nw1, nw2;
	reg [2:0]   cv, nv, pend;
	reg [2:0]   k0, k1r, k2r;
	reg [6:0]   wi0, wi1, wi2;
	reg [1:0]   sl0, sl1, sl2;
	reg [9:0]   na, nc;               // the next pixel index the outer rows / the line will take
	reg         ln_vis;               // the line being shown is in the picture
	reg         ln_odd;
	wire [2:0]  lastk = b32 ? 3'd3 : 3'd7;
	wire [2:0]  rdy = {cv[2] && (k2r != lastk || nv[2]), cv[1] && (k1r != lastk || nv[1]), cv[0] && (k0 != lastk || nv[0])};

	// a pixel out of a word: {coverage, r, g, b}
	function [26:0] pix;
		input [143:0] w; input [2:0] k; input b32f; input hok;
		reg [15:0] p; reg [31:0] p4; reg [1:0] hb;
		begin
			if (PS1) begin
				p = w[16 * k +: 16];
				pix = {3'd7, p[4:0], p[4:2], p[9:5], p[9:7], p[14:10], p[14:12]};
			end else if (b32f) begin
				p4 = {w[8 * {k[1:0], 2'd0} +: 8], w[8 * {k[1:0], 2'd1} +: 8], w[8 * {k[1:0], 2'd2} +: 8], w[8 * {k[1:0], 2'd3} +: 8]};
				pix = {p4[7:5], p4[31:8]};
			end else begin
				p = {w[8 * {k, 1'b0} +: 8], w[8 * {k, 1'b1} +: 8]};
				hb = hok ? w[128 + 2 * k +: 2] : 2'b11;
				pix = {p[0], hb, p[15:11], p[15:13], p[10:6], p[10:8], p[5:1], p[5:3]};
			end
		end
	endfunction
	wire [26:0] px0 = pix(cw0, k0,  b32, k2);
	wire [26:0] px1 = pix(cw1, k1r, b32, k2);
	wire [26:0] px2 = pix(cw2, k2r, b32, k2);

	// the window: A above (x-1..x+1), C the line (x-2..x+2), B below
	reg [26:0] A0, A1, A2, C0, C1, C2, C3, C4, B0, B1, B2;
	// The window is a row ahead of the picture: on row s's lines it works out row s+1, which
	// goes into a line store beside the row it is below -- {edge, F(r), F(r-1)} for every x, two
	// rows of it -- and the picture is made from the store's row s (and s-1 with it) and the
	// window's s+1: every neighbour filtered.
	// G: the window's answers at x-1, x, x+1 (row s+1); L: the store's (rows s and s-1)
	reg [23:0] G0, G1, G2;
	reg [48:0] L0, L1, L2;
	wire [24:0] fpk;                       // the filters' answer for the window now: {edge, rgb}
	reg        do_load, do_sh1, do_sh2, do_adv, adv_first;   // (the step this clock takes; below)
	(* ram_style = "block" *) reg [48:0] lst [0:2047];
	reg  [48:0] lq;                        // the store at the window's x (rows s, s-1)
	reg  [9:0]  wm;                        // the window's x
	reg         ls_rd, ls_wr, ls_pre;      // the line's store rows: read, written; the line before the picture
	wire [9:0]  wm_n = do_adv ? wm + 10'd1 : wm;
	always @(posedge pclk) begin
		lq <= lst[{ls_rd, wm_n}];
		if (do_adv && ls_wr) lst[{~ls_rd, wm}] <= {fpk, ls_pre ? fpk[23:0] : lq[47:24]};
	end

	// the step this clock takes: which rows pop, and how the window moves
	always @(*) begin
		do_load = 1'b0; do_sh1 = 1'b0; do_sh2 = 1'b0; do_adv = 1'b0; adv_first = 1'b0;
		case (st)
		ST_LOAD: do_load = &rdy;
		ST_SH1:  do_sh1  = &rdy;
		ST_SH2:  do_sh2  = rdy[1];
		ST_ADV1: begin do_adv = &rdy; adv_first = 1'b1; end
		ST_ADV2: do_adv = &rdy;
		ST_RUN:  do_adv = adv_n;
		default: ;
		endcase
	end
	// a row pops when the step takes a pixel from it and there is one left on the line
	wire       out_ok = na < wpx;          // the outer rows' next pixel is on the line
	wire       ctr_ok = nc < wpx;
	wire       pop_o = (do_load || do_sh1 || do_adv) && out_ok;
	wire       pop_c = (do_load || do_sh1 || do_sh2 || do_adv) && ctr_ok;
	// what goes in: the pixel popped, or (past the line's end) the last one again
	wire [26:0] inA = out_ok ? px0 : A2, inB = out_ok ? px2 : B2, inC = ctr_ok ? px1 : C4;

	// the read port: a row with no current word first, then one with no next word
	reg  [8:0]  ra; reg rd_v; reg [1:0] rd_row; reg rd_tgt;
	always @(*) begin
		rd_v = 1'b0; rd_row = 2'd0; rd_tgt = 1'b0; ra = 9'd0;
		if (st != ST_IDLE) begin
			if      (!cv[0] && !pend[0]) begin rd_v = 1'b1; rd_row = 2'd0; ra = {sl0, wi0}; end
			else if (!cv[1] && !pend[1]) begin rd_v = 1'b1; rd_row = 2'd1; ra = {sl1, wi1}; end
			else if (!cv[2] && !pend[2]) begin rd_v = 1'b1; rd_row = 2'd2; ra = {sl2, wi2}; end
			else if (cv[0] && !nv[0] && !pend[0]) begin rd_v = 1'b1; rd_row = 2'd0; rd_tgt = 1'b1; ra = {sl0, wi0 + 7'd1}; end
			else if (cv[1] && !nv[1] && !pend[1]) begin rd_v = 1'b1; rd_row = 2'd1; rd_tgt = 1'b1; ra = {sl1, wi1 + 7'd1}; end
			else if (cv[2] && !nv[2] && !pend[2]) begin rd_v = 1'b1; rd_row = 2'd2; rd_tgt = 1'b1; ra = {sl2, wi2 + 7'd1}; end
		end
	end
	reg [143:0] q; reg q_v; reg [1:0] q_row; reg q_tgt;
	always @(posedge pclk) q <= lbuf[ra];

	// the rows of the line after this one
	wire [9:0] s_n  = dbl ? {1'b0, cyn[9:1]} : cyn;       // the row the next line shows
	wire       pre_n = cyn == V_TOT - 1;                   // (the line before the picture: row 0 into the store)
	wire [9:0] s_c  = pre_n ? 10'd0 : (s_n + 10'd1 >= hgt) ? s_n : s_n + 10'd1;   // its window's row
	wire [9:0] s_up = (s_c == 10'd0) ? 10'd0 : s_c - 10'd1;
	wire [9:0] s_dn = (s_c + 10'd1 >= hgt) ? s_c : s_c + 10'd1;
	wire       vis_n = o2 && cyn < 10'd480 && s_n < hgt;
	wire       prime = co == 10'd640;

	reg underrun;                           // (for the bench: a row was asked for a pixel it did not have)
	always @(posedge pclk) begin
		q_v <= rd_v && !prime; q_row <= rd_row; q_tgt <= rd_tgt;
		if (rd_v && !prime) pend[rd_row] <= 1'b1;
		// a word back from the port
		if (q_v && !prime) begin
			pend[q_row] <= 1'b0;
			case (q_row)
			2'd0: if (q_tgt) begin nw0 <= q; nv[0] <= 1'b1; end else begin cw0 <= q; cv[0] <= 1'b1; end
			2'd1: if (q_tgt) begin nw1 <= q; nv[1] <= 1'b1; end else begin cw1 <= q; cv[1] <= 1'b1; end
			default: if (q_tgt) begin nw2 <= q; nv[2] <= 1'b1; end else begin cw2 <= q; cv[2] <= 1'b1; end
			endcase
		end
		// the pops
		if (pop_o) begin
			if (k0 == lastk) begin cw0 <= nw0; nv[0] <= 1'b0; wi0 <= wi0 + 7'd1; k0 <= 3'd0; end else k0 <= k0 + 3'd1;
			if (k2r == lastk) begin cw2 <= nw2; nv[2] <= 1'b0; wi2 <= wi2 + 7'd1; k2r <= 3'd0; end else k2r <= k2r + 3'd1;
			na <= na + 10'd1;
		end
		if (pop_c) begin
			if (k1r == lastk) begin cw1 <= nw1; nv[1] <= 1'b0; wi1 <= wi1 + 7'd1; k1r <= 3'd0; end else k1r <= k1r + 3'd1;
			nc <= nc + 10'd1;
		end
		if (st == ST_RUN && do_adv && ((!rdy[0] || !rdy[2]) && out_ok || !rdy[1] && ctr_ok)) underrun <= 1'b1;
		// the window
		if (do_load) begin
			A0 <= inA; A1 <= inA; A2 <= inA; B0 <= inB; B1 <= inB; B2 <= inB;
			C0 <= inC; C1 <= inC; C2 <= inC; C3 <= inC; C4 <= inC;
		end
		if (do_sh1 || do_adv) begin
			A0 <= A1; A1 <= A2; A2 <= inA; B0 <= B1; B1 <= B2; B2 <= inB;
		end
		if (do_sh1 || do_sh2 || do_adv) begin
			C0 <= C1; C1 <= C2; C2 <= C3; C3 <= C4; C4 <= inC;
		end
		if (do_adv) begin
			wm <= wm + 10'd1;
			if (adv_first) begin G0 <= fpk[23:0]; G1 <= fpk[23:0]; G2 <= fpk[23:0]; L0 <= lq; L1 <= lq; L2 <= lq; end
			else begin G0 <= G1; G1 <= G2; G2 <= fpk[23:0]; L0 <= L1; L1 <= L2; L2 <= lq; end
		end
		// the steps
		case (st)
		ST_WAIT: if (&rdy) st <= ST_LOAD;
		ST_LOAD: if (do_load) st <= ST_SH1;
		ST_SH1:  if (do_sh1)  st <= ST_SH2;
		ST_SH2:  if (do_sh2)  st <= ST_ADV1;
		ST_ADV1: if (do_adv)  st <= ST_ADV2;
		ST_ADV2: if (do_adv)  st <= ST_RUN;
		default: ;
		endcase
		// the line after this one: start again (the blanking's first clock)
		if (prime) begin
			cv <= 3'd0; nv <= 3'd0; pend <= 3'd0; k0 <= 3'd0; k1r <= 3'd0; k2r <= 3'd0;
			wi0 <= 7'd0; wi1 <= 7'd0; wi2 <= 7'd0; na <= 10'd0; nc <= 10'd0;
			sl0 <= s_up[1:0]; sl1 <= s_c[1:0]; sl2 <= s_dn[1:0];
			ln_vis <= vis_n; wm <= 10'd0;
			// (the store: row s+1 written on the first of row s's lines, beside row s read)
			ls_pre <= pre_n; ls_rd <= pre_n ? 1'b1 : s_n[0]; ls_wr <= pre_n || (vis_n && (!dbl || !cyn[0]));
			ln_odd <= cyn[0];
			st <= ((vis_n || pre_n) && o2) ? ST_WAIT : ST_IDLE;
			if (cy == 10'd0) underrun <= 1'b0;
		end
	end

	// --- the filters, on the window ---------------------------------------------------------
	// P the pixel; the anti-aliasing's neighbours A0 A2 B0 B2 C0 C4; dedither's the 8 round it
	wire [2:0] cvg = C2[26:24];
	wire       full_n0 = A0[26:24] == 3'd7, full_n1 = A2[26:24] == 3'd7, full_n2 = B0[26:24] == 3'd7,
	           full_n3 = B2[26:24] == 3'd7, full_n4 = C0[26:24] == 3'd7, full_n5 = C4[26:24] == 3'd7;
	wire [5:0] nfull = {full_n5, full_n4, full_n3, full_n2, full_n1, full_n0};
	wire       do_aa = en_aa && cvg != 3'd7;
	wire [23:0] aa_o, dd_o;
	genvar ch;
	generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_ch
		wire [7:0] p  = C2[8 * ch +: 8];
		wire [7:0] n0 = A0[8 * ch +: 8], n1 = A2[8 * ch +: 8], n2 = B0[8 * ch +: 8], n3 = B2[8 * ch +: 8], n4 = C0[8 * ch +: 8], n5 = C4[8 * ch +: 8];
		// the second largest and the second smallest of the pixel and its full neighbours
		wire [8:0] mx1, mx2, mn1, mn2;
		vid_max2 u_mx (.k0({1'b1, p}), .k1({nfull[0], n0}), .k2({nfull[1], n1}), .k3({nfull[2], n2}),
		               .k4({nfull[3], n3}), .k5({nfull[4], n4}), .k6({nfull[5], n5}), .m1(mx1), .m2(mx2));
		vid_max2 u_mn (.k0({1'b1, ~p}), .k1({nfull[0], ~n0}), .k2({nfull[1], ~n1}), .k3({nfull[2], ~n2}),
		               .k4({nfull[3], ~n3}), .k5({nfull[4], ~n4}), .k6({nfull[5], ~n5}), .m1(mn1), .m2(mn2));
		wire [7:0] pmax = mx2[8] ? mx2[7:0] : mx1[7:0];
		wire [7:0] pmin = mn2[8] ? ~mn2[7:0] : ~mn1[7:0];
		// out = p + ((pmax + pmin - 2p) * (7 - cvg) + 4) >> 3
		wire signed [10:0] d  = $signed({3'd0, pmax}) + $signed({3'd0, pmin}) - $signed({2'd0, p, 1'b0});
		wire signed [14:0] t  = d * $signed({1'b0, 3'd7 - cvg}) + 15'sd4;
		wire signed [11:0] o  = $signed({4'd0, p}) + (t >>> 3);
		assign aa_o[8 * ch +: 8] = o < 0 ? 8'd0 : o > 255 ? 8'd255 : o[7:0];
		// restore: one step for each neighbour above (+) or below (-) it, at 5 bits
		wire [4:0] p5 = p[7:3];
		wire [4:0] m0 = A0[8 * ch + 3 +: 5], m1 = A1[8 * ch + 3 +: 5], m2 = A2[8 * ch + 3 +: 5], m3 = C1[8 * ch + 3 +: 5],
		           m4 = C3[8 * ch + 3 +: 5], m5 = B0[8 * ch + 3 +: 5], m6 = B1[8 * ch + 3 +: 5], m7 = B2[8 * ch + 3 +: 5];
		wire [3:0] up = (m0 > p5) + (m1 > p5) + (m2 > p5) + (m3 > p5) + (m4 > p5) + (m5 > p5) + (m6 > p5) + (m7 > p5);
		wire [3:0] dn = (m0 < p5) + (m1 < p5) + (m2 < p5) + (m3 < p5) + (m4 < p5) + (m5 < p5) + (m6 < p5) + (m7 < p5);
		wire [9:0] r  = {2'd0, p} + {6'd0, up} - {6'd0, dn};
		assign dd_o[8 * ch +: 8] = r[9] ? 8'd0 : r[8] ? 8'd255 : r[7:0];
	end endgenerate
	wire [23:0] f_rgb = do_aa ? aa_o : en_dd ? dd_o : C2[23:0];
	assign fpk = {do_aa, f_rgb};

	// --- the output: divot, scaling, scanlines (co), then gamma -------------------------------
	wire [23:0] hW = L0[47:24], hP = L1[47:24], hE = L2[47:24];        // row s
	wire [23:0] hN = L1[23:0];                                          // row s-1
	wire [23:0] hS = G1, hSE = G2;                                      // row s+1
	wire        hedge = L0[48] || L1[48] || L2[48];
	wire [10:0] relo = {1'b0, co} - {1'b0, xoff};
	wire        qx = dbl && relo[0], qy = dbl && cy[0];
	wire        vis = ln_vis && co >= xoff && co < 10'd640 && relo < span && cy < 10'd480;
	function [7:0] med3; input [7:0] a, b, c;
		med3 = (a >= b) ? ((b >= c) ? b : (a >= c) ? c : a) : ((a >= c) ? a : (b >= c) ? c : b);
	endfunction
	function [23:0] avg2; input [23:0] a, b;
		reg [8:0] r, g, bb;
		begin r = a[23:16] + b[23:16]; g = a[15:8] + b[15:8]; bb = a[7:0] + b[7:0]; avg2 = {r[8:1], g[8:1], bb[8:1]}; end
	endfunction
	function sim; input [23:0] a, b;        // near enough to be the same colour
		reg [7:0] dr, dg, db; reg [9:0] s;
		begin
			dr = (a[23:16] > b[23:16]) ? a[23:16] - b[23:16] : b[23:16] - a[23:16];
			dg = (a[15:8]  > b[15:8])  ? a[15:8]  - b[15:8]  : b[15:8]  - a[15:8];
			db = (a[7:0]   > b[7:0])   ? a[7:0]   - b[7:0]   : b[7:0]   - a[7:0];
			s = {2'd0, dr} + {2'd0, dg} + {2'd0, db};
			sim = s < 10'd40;
		end
	endfunction
	wire [23:0] dP = (en_dv && hedge) ? {med3(hW[23:16], hP[23:16], hE[23:16]), med3(hW[15:8], hP[15:8], hE[15:8]), med3(hW[7:0], hP[7:0], hE[7:0])} : hP;
	// edge-directed: Scale2x's rule for the quarter of the pixel this is, blended half way --
	// that quarter's vertical neighbour V and horizontal one Hz, and the two opposite
	wire [23:0] eV = qy ? hS : hN, eVo = qy ? hN : hS, eH = qx ? hE : hW, eHo = qx ? hW : hE;
	wire [23:0] e_q = (sim(eV, eH) && !sim(eV, eHo) && !sim(eH, eVo)) ? avg2(dP, avg2(eV, eH)) : dP;
	wire [23:0] s_r  = qx ? avg2(dP, hE) : dP;                         // the VI's: across only
	wire [23:0] s_lo = qx ? avg2(hS, hSE) : hS;                        // (the line below, likewise)
	wire [23:0] s_b  = qy ? avg2(s_r, s_lo) : s_r;
	wire [23:0] scaled = (scl == 2'd0) ? s_r : (scl == 2'd2) ? s_b : (scl == 2'd3) ? e_q : dP;
	function [7:0] dim; input [7:0] v; input [1:0] how;
		dim = (how == 2'd1) ? v - {2'd0, v[7:2]} : (how >= 2'd2) ? {1'b0, v[7:1]} : v;
	endfunction
	wire [1:0] sdim = (scan != 2'd0 && qy) ? scan : 2'd0;
	reg  [23:0] post; reg post_g;
	always @(posedge pclk) begin
		post <= !vis ? 24'd0 : {dim(scaled[23:16], sdim), dim(scaled[15:8], sdim), dim(scaled[7:0], sdim)};
		post_g <= en_gm && vis;
	end
	// gamma: the square root curve, 255 sqrt(v / 255)
	reg [7:0] gam [0:255];
	integer gi, gs;
	initial for (gi = 0; gi < 256; gi = gi + 1) begin
		gs = 0;
		while ((gs + 1) * (gs + 1) <= gi * 255) gs = gs + 1;
		if ((gs * gs + gs) < gi * 255) gs = gs + 1;          // (rounded)
		gam[gi] = (gs > 255) ? 8'd255 : gs[7:0];
	end
	always @(posedge pclk) rgb <= post_g ? {gam[post[23:16]], gam[post[15:8]], gam[post[7:0]]} : post;
endmodule

// the largest and second largest of seven keys {valid, value} (a key with valid 0 loses
// to any with valid 1; m2 has valid 0 when only one key was valid)
module vid_max2 (
	input  wire [8:0] k0, k1, k2, k3, k4, k5, k6,
	output reg  [8:0] m1, m2
);
	reg [8:0] k [0:6];
	integer i; reg taken;
	always @(*) begin
		k[0] = k0; k[1] = k1; k[2] = k2; k[3] = k3; k[4] = k4; k[5] = k5; k[6] = k6;
		m1 = 9'd0;
		for (i = 0; i < 7; i = i + 1) if (k[i] > m1) m1 = k[i];
		m2 = 9'd0; taken = 1'b0;
		for (i = 0; i < 7; i = i + 1)
			if (!taken && k[i] == m1) taken = 1'b1;
			else if (k[i] > m2) m2 = k[i];
	end
endmodule

`default_nettype wire
