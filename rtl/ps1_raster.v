//////////////////////////////////////////////////////////////////////////////////
// ps1_raster.v - the pixel pipeline: two pixels a clock, from the bounding box
//                to the block writer.
//
// The engine that came before walked one pixel at a time through a state
// machine -- scan, texel, palette, blend, write -- and every clock it spent
// deciding was a clock no pixel landed in. Measured on the board it managed
// 2.4 clocks a pixel on the BIOS; the chip in the console does one, and two
// for the flat case. Fast open-source cores get there the same way, and this
// is that way, written from the description:
//
//   A  the scanner: a pair of pixels (x even, x+1) per clock across the
//      bounding box, with the three edge functions and the colour/texture
//      interpolants for both;
//   B  texel addresses for the pair, looked up in a 4 KB texture cache (tiled,
//      so a walk down a texture does not throw away the rows above);
//   C  the index out of the texel line, then the palette entry from a copy of
//      the whole CLUT kept on chip;
//   D  shading: the texel modulated by the colour, or the colour itself;
//   E  what is under the pixel when it matters (semi-transparency, mask), from
//      a held destination line, then the blend and the mask test;
//   F  the write: a word (two pixels) with byte enables, to the VRAM port,
//      which posts it.
//
// Every stage holds when anything below it cannot take its output. The only
// things that hold are a texel line or a destination line that is not in
// hand (fetched through the VRAM port, one at a time, with the rest of the
// run of eight offered by the video cache) and the block writer's queue being
// full. Opaque pixels never read the framebuffer.
//
// Coordinates, edge functions, interpolants and the drawing rules are exactly
// the old engine's (see ps1_gpu.v: edgefn, inside, in_area, modulate, blend,
// the texture window), so the picture is the same; only the rate changed.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_raster #(
	parameter CLK_HZ = 50_000_000    // (the console-pace mode's rate is worked out from it)
) (
	input  wire        clk,
	input  wire        rst,

	// --- a primitive, set up by the engine ---------------------------------------
	input  wire        start,            // a pulse; everything below is held until done
	output reg         busy,
	input  wire        always_in,        // a rectangle: the bounding box is the shape
	input  wire signed [11:0] bx0, bx1, by0, by1,
	input  wire signed [23:0] e0_0, e1_0, e2_0,     // edge functions at (bx0, by0)
	input  wire signed [23:0] sx0, sx1, sx2,        // ...one pixel right
	input  wire signed [23:0] sy0, sy1, sy2,        // ...one row down
	input  wire        apos,             // area > 0: inside is all >= 0, else all <= 0
	input  wire signed [31:0] cr_0, cg_0, cb_0, cu_0, cv_0,   // 16.16 at (bx0, by0)
	input  wire signed [31:0] dr_dx, dg_dx, db_dx, du_dx, dv_dx,
	input  wire signed [31:0] dr_dy, dg_dy, db_dy, du_dy, dv_dy,
	input  wire        is_gour, is_tex, is_semi, is_raw,
	input  wire [7:0]  fr, fg, fb,       // the flat colour
	input  wire [3:0]  tp_x,
	input  wire        tp_y,
	input  wire [1:0]  tp_abr,
	input  wire [1:0]  tp_depth,
	input  wire [15:0] clut,
	input  wire [4:0]  tw_mx, tw_my, tw_ox, tw_oy,
	// Two switches for finding where a wrong texel comes from, on the board,
	// without a build in between: never reuse a cached texture line, and
	// reload the palette for every primitive.
	input  wire        no_tcache,
	input  wire        no_ccache,
	input  wire        no_trun,     // ignore texture lines the video cache offers from its runs
	input  wire [9:0]  da_x0, da_x1,
	input  wire [8:0]  da_y0, da_y1,
	input  wire        mask_set, mask_chk,
	// 480i with drawing to the display area prohibited: the chip draws only
	// the lines of the field that is NOT being shown. That is how a 480-line
	// picture is double buffered in a VRAM that cannot hold two of them, and
	// the BIOS menu depends on it: drawing every line put each frame over the
	// field on screen, and the capture saw the half that was drawn so far.
	input  wire        il_skip,
	input  wire        il_field,          // the field on screen: its parity of line is skipped
	// The chip's pace or ours. The console's GPU runs at 53.2 MHz and lands two
	// flat pixels a clock, one textured or shaded: 106 and 53 million a second.
	// This pipeline lands two a clock at 50 MHz whatever the pixel, so a textured
	// primitive would go twice as fast as on the console. With `pace` set the
	// scanner is let go on 53.2 of every 100 clocks for textured, shaded and
	// blended primitives; flat ones run free (100 against 106 a second: the 6%
	// the clock is short, and not worth a stall pattern).
	input  wire        pace,

	// --- VRAM: the engine's port, ours while busy ------------------------------------
	output reg  [28:0] v_addr,
	output reg         v_req,
	output reg         v_we,
	output reg  [3:0]  v_be,
	output reg  [31:0] v_wdata,
	output reg         v_around,
	// ...and whether the run it wants should be LINEAR. A texture wants a tile
	// -- two lines of one row and two of the row below -- because a span walks
	// down as well as across. A palette is 32 consecutive lines of ONE row, so
	// half of every tile is the row below and useless to it.
	output reg         v_lin,
	input  wire [31:0] v_rdata,
	input  wire [127:0] v_line,
	input  wire        v_ack,

	// the rest of a texel run, offered by the video cache a line at a time
	input  wire        tx_valid,
	input  wire [24:0] tx_addr,
	input  wire [127:0] tx_line,

	// a write from elsewhere in the engine (a fill, a copy, an upload): the
	// caches here drop what it covers
	input  wire        inv_en,
	input  wire [24:0] inv_line,

	// what happened, for the counters
	output wire        st_tex_miss,      // holding for a texel line
	output wire        st_dst_miss,      // holding for a destination line
	output wire        st_full,          // holding for the block writer
	output wire        st_clut           // loading the palette
);
	// ------------------------------------------------------------------------------------
	// helpers, as in ps1_gpu.v
	// ------------------------------------------------------------------------------------
	function [28:0] vaddr;
		input [9:0] x; input [8:0] y;
		vaddr = {y, x[9:1], 2'b00};
	endfunction
	function [15:0] half;
		input [31:0] w; input odd;
		half = odd ? w[31:16] : w[15:0];
	endfunction
	function [15:0] lhalf;
		input [127:0] l; input [28:0] a; input odd;
		lhalf = half(l[a[3:2]*32 +: 32], odd);
	endfunction
	function [15:0] to555;
		input [7:0] r, g, b;
		to555 = {1'b0, b[7:3], g[7:3], r[7:3]};
	endfunction
	function [4:0] sat5;
		input [5:0] v;
		sat5 = v[5] ? 5'h1F : v[4:0];
	endfunction
	function [15:0] modulate;
		input [15:0] t; input [7:0] r, g, b;
		reg [12:0] pr, pg, pb;
		begin
			pr = t[4:0]   * r; pg = t[9:5] * g; pb = t[14:10] * b;
			modulate = {t[15], sat5(pb[12:7]), sat5(pg[12:7]), sat5(pr[12:7])};
		end
	endfunction
	function [15:0] blend;
		input [15:0] back, fore; input [1:0] mode;
		reg [5:0] r, g, b;
		begin
			case (mode)
			2'd0: begin r = (back[4:0] + fore[4:0]) >> 1; g = (back[9:5] + fore[9:5]) >> 1; b = (back[14:10] + fore[14:10]) >> 1; end
			2'd1: begin r = back[4:0] + fore[4:0]; g = back[9:5] + fore[9:5]; b = back[14:10] + fore[14:10]; end
			2'd2: begin r = (back[4:0] > fore[4:0]) ? back[4:0] - fore[4:0] : 6'd0;
			            g = (back[9:5] > fore[9:5]) ? back[9:5] - fore[9:5] : 6'd0;
			            b = (back[14:10] > fore[14:10]) ? back[14:10] - fore[14:10] : 6'd0; end
			default: begin r = back[4:0] + (fore[4:0] >> 2); g = back[9:5] + (fore[9:5] >> 2); b = back[14:10] + (fore[14:10] >> 2); end
			endcase
			blend = {fore[15], sat5(b), sat5(g), sat5(r)};
		end
	endfunction
	function inside3;
		input signed [23:0] a, b, c; input pos;
		inside3 = pos ? (a >= 0 && b >= 0 && c >= 0) : (a <= 0 && b <= 0 && c <= 0);
	endfunction
	// texture coordinates through the window, then the texel's pixel address
	function [7:0] twin;
		input [7:0] c; input [4:0] m, o;
		twin = (c & ~{m, 3'd0}) | ({o, 3'd0} & {m, 3'd0});
	endfunction
	function [9:0] texx;
		input [7:0] u; input [3:0] page; input [1:0] depth;
		case (depth)
		2'd0:    texx = {page, 6'd0} + {4'd0, u[7:2]};
		2'd1:    texx = {page, 6'd0} + {3'd0, u[7:1]};
		default: texx = {page, 6'd0} + {2'd0, u};
		endcase
	endfunction
	function [7:0] tindex;         // the index (or the low byte of the texel) out of its halfword
		input [15:0] hw; input [7:0] u; input [1:0] depth;
		case (depth)
		2'd0:    tindex = {4'd0, hw[{u[1:0], 2'b00} +: 4]};
		2'd1:    tindex = hw[{u[0], 3'b000} +: 8];
		default: tindex = hw[7:0];
		endcase
	endfunction

	// ------------------------------------------------------------------------------------
	// the hold: everything above F stands still while anything is being waited for
	// ------------------------------------------------------------------------------------
	wire hold;

	// the pace: a pair may go on the clocks a 53.2 MHz chip would have landed one
	// textured/shaded pixel-pair on -- 26.6 of every 50 -- by a phase accumulator
	reg  [19:0] pace_acc;
	reg         pace_go;
	always @(posedge clk) begin
		if (rst) begin pace_acc <= 20'd0; pace_go <= 1'b0; end
		else if (pace_acc + 20'd266000 >= CLK_HZ / 100) begin pace_acc <= pace_acc + 20'd266000 - CLK_HZ / 100; pace_go <= 1'b1; end
		else begin pace_acc <= pace_acc + 20'd266000; pace_go <= 1'b0; end   // (CLK_HZ / 100 < 2^20: under 104 MHz)
	end
	wire slow_prim = is_tex || is_gour || is_semi;
	wire pace_ok   = !pace || !slow_prim || pace_go;



	// ------------------------------------------------------------------------------------
	// A: the scanner
	// ------------------------------------------------------------------------------------
	reg signed [11:0] px, py;                       // px even
	reg signed [23:0] ea0, ea1, ea2;                // edges at px
	reg signed [23:0] er0, er1, er2;                // at the row start
	reg signed [31:0] cr, cg, cb, cu, cv;           // at px
	reg signed [31:0] rr, rg, rb, ru, rv;           // at the row start
	reg               scanning;
	wire signed [11:0] px1 = px + 12'sd1;
	wire signed [23:0] eb0 = ea0 + sx0, eb1 = ea1 + sx1, eb2 = ea2 + sx2;
	wire in_a = always_in || inside3(ea0, ea1, ea2, apos);
	wire in_b = always_in || inside3(eb0, eb1, eb2, apos);
	wire row_ok = (py >= $signed({3'b0, da_y0})) && (py <= $signed({3'b0, da_y1})) && py >= 0 && py < 512
	           && !(il_skip && (py[0] == il_field));
	wire xa_ok  = (px  >= $signed({2'b0, da_x0})) && (px  <= $signed({2'b0, da_x1})) && px  >= 0 && px  < 1024 && px  >= bx0 && px  <= bx1;
	wire xb_ok  = (px1 >= $signed({2'b0, da_x0})) && (px1 <= $signed({2'b0, da_x1})) && px1 >= 0 && px1 < 1024 && px1 >= bx0 && px1 <= bx1;
	wire a_ok = scanning && row_ok && xa_ok && in_a;
	wire b_ok = scanning && row_ok && xb_ok && in_b;
	wire signed [31:0] cr1 = cr + dr_dx, cg1 = cg + dg_dx, cb1 = cb + db_dx, cu1 = cu + du_dx, cv1 = cv + dv_dx;
	// 12'sd: an unsigned literal would make the compare unsigned. A row the
	// field rule skips is over before it starts: one clock, not one a pair.
	wire row_end = (px + 12'sd2 > bx1) || (il_skip && (py[0] == il_field));
	wire last    = row_end && (py >= by1);

	// eight ahead: when neither of the next four pairs is inside, jump
	wire signed [23:0] e8_0 = ea0 + (sx0 <<< 3), e8_1 = ea1 + (sx1 <<< 3), e8_2 = ea2 + (sx2 <<< 3);
	// a convex shape: if this pair and the one eight on are both outside on the
	// same side of every edge, the ones between are too
	wire skip8 = !always_in && !in_a && !in_b && (px + 12'sd8 <= bx1)
	             && !inside3(e8_0, e8_1, e8_2, apos)
	             && ((ea0 < 0) == (e8_0 < 0)) && ((ea1 < 0) == (e8_1 < 0)) && ((ea2 < 0) == (e8_2 < 0))
	             && ((eb0 < 0) == (e8_0 < 0)) && ((eb1 < 0) == (e8_1 < 0)) && ((eb2 < 0) == (e8_2 < 0));

	// ------------------------------------------------------------------------------------
	// B: the pair, registered; texel addresses; the texture cache
	// ------------------------------------------------------------------------------------
	reg        vB, lastB, okB0, okB1;
	reg [9:0]  xB;                                  // even
	reg [8:0]  yB;
	reg [7:0]  rB0, gB0, bB0, rB1, gB1, bB1;
	reg [7:0]  uB0, vB0, uB1, vB1;                  // through the window
	wire [9:0]  txB0 = texx(uB0, tp_x, tp_depth), txB1 = texx(uB1, tp_x, tp_depth);
	wire [28:0] taB0 = vaddr(txB0, {tp_y, vB0});
	wire [28:0] taB1 = vaddr(txB1, {tp_y, vB1});

	// The texture cache: 256 lines of 16 bytes, indexed by four bits of the row
	// and four of the line within it -- a 16-row by 128-byte window, so a walk
	// down the texture keeps the rows above. Data in block RAM (a clock), tags
	// and valid bits in registers so a write anywhere can drop a line at once.
	// The index takes (TIDX-4) bits of the texture's ROW and four of its column,
	// so the cache spans 2^(TIDX-4) VRAM rows. At TIDX=8 that is SIXTEEN rows,
	// and texels sixteen rows apart collide -- which is fine for the small
	// triangles a bench draws and wrong for the big ones a game draws: measured
	// on the board, the frames that miss 30 fps draw bigger primitives and spend
	// 27% of ALL clocks waiting for texel lines against 12.8% in the frames that
	// make it, and the same thing reproduces in sim/tb_ps1_clut.v with +BIG3
	// (texel stall 20% of busy -> 35%).
	// A VRAM byte address splits as: a[3:0] inside the line, a[10:4] which line
	// along the row, a[19:11] the row. ROWS and COLUMNS are chosen separately,
	// because what matters is how many texture ROWS the cache spans and not how
	// big it is: 4 KB over 16 rows and 8 KB over 32 rows measured the SAME, and
	// 16 KB over 64 rows was 26-52% faster. But the SIZE was never the point:
	// 64 rows over a QUARTER of the columns measures identically, in the same
	// 256 lines and the same tag width the cache always had. So this costs
	// nothing -- it is the same 4 KB, indexed on the right bits. Sixteen
	// halfwords is 32 texels of a row at 8 bit, which is wider than the
	// primitives a game draws; the rows are what it walks.
	//   before {v[3:0], u[6:3]}   4 KB, 16 rows: 3.65 clocks a pair, texel 35%
	//   after  {v[5:0], u[4:3]}   4 KB, 64 rows: 2.71 clocks a pair, texel 16%
	// and on tb_ps1_speed's 15-bit scene 3.56 -> 1.69, texel 40% -> 0%.
	localparam TROWB = 6;                           // rows spanned = 2^TROWB
	localparam TCOLB = 2;                           // line-columns = 2^TCOLB
	localparam TIDX  = TROWB + TCOLB;
	// VRAM is 1 MB and `vaddr` builds {y[8:0], x[9:1], 2'b00}, so a texture
	// address is TWENTY bits and a[28:20] is always zero. The tag used to carry
	// them anyway: nine dead bits per line, stored once and compared on three
	// read ports, on the path that decides a hit.
	localparam TTAGW = 16 - TIDX;                   // what is left to tag with
	function [TIDX-1:0]  tidx; input [28:0] a; tidx = {a[10+TROWB:11], a[3+TCOLB:4]}; endfunction
	function [TTAGW-1:0] ttag; input [28:0] a; ttag = {a[19:11+TROWB], a[10:4+TCOLB]}; endfunction
	reg [127:0]      tdata [0:(1<<TIDX)-1];         // block RAM: one write, two reads
	reg [TTAGW-1:0]  ttagv [0:(1<<TIDX)-1];         // distributed RAM: one write, three reads
	reg [(1<<TIDX)-1:0] tvalid;
	// stage C's addresses (below) so the RAM can be re-read while it waits
	reg [28:0]  taC0, taC1;
	wire        advBC;                              // B -> C this clock
	wire [TIDX-1:0] ti0 = advBC ? tidx(taB0) : tidx(taC0);
	wire [TIDX-1:0] ti1 = advBC ? tidx(taB1) : tidx(taC1);
	reg [127:0] tl0, tl1;                           // the RAM's answer, a clock on: stage C's lines
	always @(posedge clk) begin
		tl0 <= tdata[ti0];
		tl1 <= tdata[ti1];
	end

	// fills, one a clock: a fetch of our own first, else a line the video cache
	// offers from a texel run. Written from here and nowhere else, so Vivado
	// sees one write port (written from two places it gave up and built the
	// 4 KB out of 32,000 flip-flops).
	reg [1:0]    fs;                                // the fetch machine (below)
	reg [1:0]    fwho;
	reg [28:0]   faddr;
	wire         f_ack;
	wire         own_fill   = (fs == 2'd1) && f_ack && (fwho == 2'd0);
	// The cache is direct mapped and a pixel PAIR needs both its texels in hand
	// before it may move on. When the two land in the same line index with
	// different tags -- which they do whenever dv/dx is 16, or du/dx is 128, as
	// on a steeply angled polygon close to the camera -- each fetch evicted the
	// line the other one needed, neither lane ever hit, and the rasteriser
	// stopped for good: busy high, GPUSTAT never ready, the game's DrawSync
	// never returning. So the second of a colliding pair is kept in a line of
	// its own instead of going into the cache, and nothing is evicted.
	wire         collide    = (tidx(taC0) == tidx(taC1)) && (ttag(taC0) != ttag(taC1));
	wire         fill_hold  = own_fill && collide && (faddr[28:4] == taC1[28:4]);
	wire         tfill_go   = (own_fill && !fill_hold) || (tx_valid && !no_trun);
	wire [28:0]  tfill_addr = own_fill ? faddr  : {tx_addr, 4'd0};
	wire [127:0] tfill_line = own_fill ? v_line : tx_line;
	always @(posedge clk)
		if (tfill_go) begin
			tdata[tidx(tfill_addr)] <= tfill_line;
			ttagv[tidx(tfill_addr)] <= ttag(tfill_addr);
		end
	// a write drops the line it lands in: ours as it goes out, or one from the
	// rest of the engine (never both in one clock: the engine only writes when
	// the raster is idle)
	wire         w_done;
	reg  [28:0]  waddr;
	wire         inv_go = w_done || inv_en;
	wire [28:0]  inv_a  = w_done ? waddr : {inv_line, 4'd0};
	always @(posedge clk) begin
		if (rst) tvalid <= {(1<<TIDX){1'b0}};
		else begin
			if (tfill_go) tvalid[tidx(tfill_addr)] <= 1'b1;
			if (inv_go && tvalid[tidx(inv_a)] && (ttagv[tidx(inv_a)] == ttag(inv_a))) tvalid[tidx(inv_a)] <= 1'b0;
		end
	end
	// Whether stage C's lines are in hand is REGISTERED: looked up as the pair
	// moves from B to C, then kept right by the fills and drops that follow.
	// Looked up live it was a 256-way mux and a compare on the path that holds
	// the whole pipeline.
	// the held line: one texel line that is not in the cache
	reg          h_v;
	reg [24:0]   h_a;
	reg [127:0]  h_d;
	always @(posedge clk) begin
		if (rst) begin h_v <= 1'b0; h_a <= 25'd0; h_d <= 128'd0; end
		else begin
			if (fill_hold) begin h_v <= 1'b1; h_a <= faddr[28:4]; h_d <= v_line; end
			// a write to what it holds drops it, exactly as for a cached line
			if (inv_go && h_v && (inv_a[28:4] == h_a)) h_v <= 1'b0;
		end
	end
	wire h_hit1 = h_v && (h_a == taC1[28:4]) && !no_tcache;

	wire hitB0 = tvalid[tidx(taB0)] && (ttagv[tidx(taB0)] == ttag(taB0));
	wire hitB1 = tvalid[tidx(taB1)] && (ttagv[tidx(taB1)] == ttag(taB1));
	reg  hitC0_r, hitC1_r;
	wire [28:0] nC0 = advBC ? taB0 : taC0;          // what C holds next clock
	wire [28:0] nC1 = advBC ? taB1 : taC1;
	always @(posedge clk) begin
		if (rst) begin hitC0_r <= 1'b0; hitC1_r <= 1'b0; end
		else begin
			hitC0_r <= advBC ? hitB0 : hitC0_r;
			hitC1_r <= advBC ? hitB1 : hitC1_r;
			if (tfill_go && tidx(tfill_addr) == tidx(nC0)) hitC0_r <= (ttag(tfill_addr) == ttag(nC0));
			if (tfill_go && tidx(tfill_addr) == tidx(nC1)) hitC1_r <= (ttag(tfill_addr) == ttag(nC1));
			if (inv_go && inv_a[28:4] == nC0[28:4]) hitC0_r <= 1'b0;
			if (inv_go && inv_a[28:4] == nC1[28:4]) hitC1_r <= 1'b0;
		end
	end
	// a fill lands in the RAM a clock before its line can be read back out, so a
	// hit on the index just filled waits that clock
	reg            tfill_d;
	reg [TIDX-1:0] tfill_i;
	always @(posedge clk) begin
		if (rst) begin tfill_d <= 1'b0; tfill_i <= 0; end
		else begin tfill_d <= tfill_go; tfill_i <= tidx(tfill_addr); end
	end
	wire hitC0 = hitC0_r && !(tfill_d && tfill_i == tidx(taC0)) && !no_tcache;
	wire hitC1 = (hitC1_r && !(tfill_d && tfill_i == tidx(taC1)) && !no_tcache) || h_hit1;

	// ------------------------------------------------------------------------------------
	// C: the texel line in hand?  the index, the palette
	// ------------------------------------------------------------------------------------
	reg        vC, lastC, okC0, okC1;
	reg [9:0]  xC;
	reg [8:0]  yC;
	reg [7:0]  rC0, gC0, bC0, rC1, gC1, bC1;
	reg [7:0]  uC0, uC1;
	reg        oC0, oC1;                            // the texel is the odd pixel of its word
	wire       needC0 = vC && okC0 && is_tex;
	wire       needC1 = vC && okC1 && is_tex;
	wire       missC  = (needC0 && !hitC0) || (needC1 && !hitC1);
	wire [15:0] hwC0 = lhalf(tl0, taC0, oC0);
	wire [15:0] hwC1 = lhalf(h_hit1 ? h_d : tl1, taC1, oC1);
	wire [7:0]  ixC0 = tindex(hwC0, uC0, tp_depth);
	wire [7:0]  ixC1 = tindex(hwC1, uC1, tp_depth);

	// The palette: the whole CLUT in hand, 256 entries as 32 lines of 8. Loaded
	// when a textured primitive starts with a CLUT that is not the one held
	// (16 entries for 4-bit, 256 for 8-bit), dropped by a write into it.
	reg [127:0] cdata [0:31];
	reg [15:0]  cl_tag;                             // {clut} the copy is of
	reg [1:0]   cl_depth;
	reg         cl_v;
	// Which of the 32 lines are in hand. It used to be a counter, because the
	// lines were asked for strictly in order and one at a time -- 32 round
	// trips to DDR3 with the rasteriser stopped, measured at HALF of the
	// engine's busy clocks in a game-shaped scene (sim/tb_ps1_clut.v) and 1.21
	// of 2.26 clocks a pixel on the board. A read-around fetch already brings a
	// RUN of lines back and offers the spares to the texture cache; the palette
	// threw them away and asked again. Now it keeps the ones that belong to it,
	// which is why the order stops being sequential and a counter will no
	// longer do.
	reg [31:0]  cl_have;
	reg [4:0]   cl_req;                             // the line the outstanding read is for
	wire [127:0] clC0 = cdata[ixC0[7:3]];
	wire [127:0] clC1 = cdata[ixC1[7:3]];
	wire [15:0] texC0 = (tp_depth == 2'd2) ? hwC0 : clC0[ixC0[2:0]*16 +: 16];
	wire [15:0] texC1 = (tp_depth == 2'd2) ? hwC1 : clC1[ixC1[2:0]*16 +: 16];
	wire [24:0] cl_base  = vaddr({clut[5:0], 4'd0}, clut[14:6]) >> 4;
	wire [5:0]  cl_lines = (tp_depth == 2'd0) ? 6'd2 : 6'd32;
	// Where the copy IN HAND came from, which is not always where the primitive
	// being drawn now would load it: a write into the palette must be checked
	// against what is held, or a palette replaced in VRAM while another one is
	// current stays in the cache and comes back wrong the next time it is used.
	wire [24:0] cl_hbase  = vaddr({cl_tag[5:0], 4'd0}, cl_tag[14:6]) >> 4;
	wire [5:0]  cl_hlines = (cl_depth == 2'd0) ? 6'd2 : 6'd32;
	wire        cl_need  = is_tex && (tp_depth != 2'd2);
	wire        cl_ok    = !cl_need || (cl_v && cl_tag == clut && cl_depth == tp_depth && !no_ccache);

	// ------------------------------------------------------------------------------------
	// D: shading
	// ------------------------------------------------------------------------------------
	reg        vD, lastD, okD0, okD1;
	reg [9:0]  xD;
	reg [8:0]  yD;
	reg [15:0] tD0, tD1;                            // the texel (or nothing)
	reg [7:0]  rD0, gD0, bD0, rD1, gD1, bD1;
	wire [15:0] pixD0 = !is_tex ? to555(rD0, gD0, bD0) : is_raw ? tD0 : modulate(tD0, rD0, gD0, bD0);
	wire [15:0] pixD1 = !is_tex ? to555(rD1, gD1, bD1) : is_raw ? tD1 : modulate(tD1, rD1, gD1, bD1);
	wire drawD0 = okD0 && !(is_tex && tD0 == 16'd0);  // a zero texel is transparent
	wire drawD1 = okD1 && !(is_tex && tD1 == 16'd0);
	wire semiD0 = is_semi && (!is_tex || tD0[15]);
	wire semiD1 = is_semi && (!is_tex || tD1[15]);

	// ------------------------------------------------------------------------------------
	// E: what is under it, the blend, the mask
	// ------------------------------------------------------------------------------------
	reg        vE, lastE, drawE0, drawE1, semiE0, semiE1;
	reg [9:0]  xE;
	reg [8:0]  yE;
	reg [15:0] pE0, pE1;
	wire [28:0] waE  = vaddr(xE, yE);
	wire        needE = vE && (drawE0 || drawE1) && (mask_chk || semiE0 || semiE1);
	// the destination line in hand, patched with what this pipeline writes
	reg [127:0] dl_d;
	reg [24:0]  dl_a;
	reg         dl_v;
	wire        dl_hit = dl_v && (dl_a == waE[28:4]);
	wire        missE  = needE && !dl_hit;
	wire [31:0] dstw   = dl_d[waE[3:2]*32 +: 32];
	wire [15:0] dst0 = dstw[15:0], dst1 = dstw[31:16];
	wire        landE0 = drawE0 && !(mask_chk && dst0[15]);
	wire        landE1 = drawE1 && !(mask_chk && dst1[15]);
	wire [15:0] outE0 = (semiE0 ? blend(dst0, pE0, tp_abr) : pE0) | {mask_set, 15'd0};
	wire [15:0] outE1 = (semiE1 ? blend(dst1, pE1, tp_abr) : pE1) | {mask_set, 15'd0};

	// ------------------------------------------------------------------------------------
	// F: the write, and the fetches, on the one port
	// ------------------------------------------------------------------------------------
	localparam F_IDLE = 2'd0, F_REQ = 2'd1, F_WAIT = 2'd2;
	reg        wreq;                                // v_req for a write, held until v_ack
	reg        lastF;                               // the write out is the primitive's last
	reg [3:0]  wbe;
	reg [31:0] wdata;
	assign     w_done = wreq && v_ack;
	// F can take another write this clock. Not while a fetch is out: the port
	// is one request at a time, and a write taking it from under an
	// unanswered read would lose the answer.
	wire       f_free = (!wreq || v_ack) && (fs == F_IDLE);

	// fetch: which line, and for whom
	// fwho: 0 texel, 1 destination, 2 palette
	reg        cl_loading;
	reg  [3:0] cl_wait;       // clocks to let a read-around run finish offering
	wire       want_tex = vC && missC && !tfill_d;  // a line just landed: look again first
	wire       want_dst = vE && missE;
	wire       want_fetch = (cl_loading && (cl_wait == 4'd0)) || want_dst || want_tex;


	assign st_tex_miss = busy && want_tex && !cl_loading && !want_dst;
	assign st_dst_miss = busy && want_dst && !cl_loading;
	assign st_full     = busy && wreq && !v_ack;
	assign st_clut     = busy && cl_loading;

	// the port: a pending write owns it; otherwise a fetch
	always @(*) begin
		if (wreq) begin
			v_req = 1'b1; v_we = 1'b1; v_addr = waddr; v_be = wbe; v_wdata = wdata; v_around = 1'b0; v_lin = 1'b0;
		end else begin
			v_req = (fs != F_IDLE); v_we = 1'b0; v_addr = faddr; v_be = 4'hF; v_wdata = 32'd0;
			v_around = (fwho != 2'd1);              // texel and palette lines come as runs
			v_lin    = (fwho == 2'd2);              // a palette's run is along one row
		end
	end
	assign f_ack = (fs != F_IDLE) && !wreq && v_ack;

	// --- the palette load, in the order the memory answers ------------------------
	wire [31:0] cl_mask  = (tp_depth == 2'd0) ? 32'h0000_0003 : 32'hFFFF_FFFF;
	function [4:0] lowmiss;                         // lowest bit that is still 0
		input [31:0] m; integer j; reg got;
		begin lowmiss = 5'd0; got = 1'b0;
			for (j = 0; j < 32; j = j + 1)
				if (!m[j] && !got) begin lowmiss = j[4:0]; got = 1'b1; end
		end
	endfunction
	wire [4:0]  cl_next = lowmiss(cl_have | ~cl_mask);
	// A read-around fetch brings back a RUN -- the wanted line and the three
	// after it -- and offers the spares a clock at a time. Asking for the next
	// line the instant this one lands outruns that offering: measured, every
	// one of a palette's 32 lines was still fetched on demand and the run's
	// 2,560 spare lines arrived after the demand for them had already gone out,
	// so they were written twice and saved nothing. Wait for the offering to
	// stop, and the demands drop to one per run.
	// a line the run brought back that belongs to the palette being loaded
	wire [24:0] cl_off_d  = tx_addr - cl_base;
	wire        cl_off_in = cl_loading && tx_valid && !no_trun && (cl_off_d < {19'd0, cl_lines});
	wire [4:0]  cl_off_i  = cl_off_d[4:0];
	wire        cl_wr_dem = (fs == F_REQ) && f_ack && (fwho == 2'd2);
	// The store has ONE write port, so an offer that lands on the same clock as
	// a demand fill loses. A register to hold it over was tried and MEASURED: it
	// never once fired, because with a linear run the demand and the offers do
	// not collide. It cost 128 flip-flops and a 128-bit multiplexer, and the
	// design missed fitting by 24 slices with it in. Left out deliberately.
	wire        cl_wr_off = cl_off_in && !cl_wr_dem;
	wire [4:0]  cl_wr_i   = cl_wr_dem ? cl_req : cl_off_i;
	wire [127:0] cl_wr_d  = cl_wr_dem ? v_line : tx_line;
	wire        cl_wr     = cl_wr_dem || cl_wr_off;
	wire [31:0] cl_nhave  = cl_have | ((cl_wr ? 32'd1 : 32'd0) << cl_wr_i);
	wire        cl_full   = (cl_nhave & cl_mask) == cl_mask;

	// ------------------------------------------------------------------------------------
	// the hold, and who moves
	// ------------------------------------------------------------------------------------
	// E moves into F when F is free; D into E when E moves or is empty; and so
	// on up. A miss in C or E holds everything above it as well as itself.
	wire mvE = vE && !missE && f_free;              // E's pair goes out (or is dropped)
	wire eFree = !vE || mvE;
	wire mvD = vD && eFree;
	wire dFree = !vD || mvD;
	wire mvC = vC && !missC && dFree && !cl_loading;
	wire cFree = !vC || mvC;
	wire mvB = vB && cFree;
	assign advBC = mvB;
	wire bFree = !vB || mvB;
	assign hold = !bFree;                           // the scanner stands still

	// ------------------------------------------------------------------------------------
	// the stages
	// ------------------------------------------------------------------------------------
	integer k;
	always @(posedge clk) begin
		if (rst) begin
			busy <= 1'b0; scanning <= 1'b0;
			vB <= 1'b0; vC <= 1'b0; vD <= 1'b0; vE <= 1'b0; wreq <= 1'b0; lastF <= 1'b0;
			fs <= F_IDLE; fwho <= 2'd0; faddr <= 29'd0; cl_have <= 32'd0; cl_req <= 5'd0; cl_loading <= 1'b0;
			cl_wait <= 4'd0;
			cl_v <= 1'b0; cl_tag <= 16'd0; cl_depth <= 2'd0; dl_v <= 1'b0; dl_a <= 25'd0; dl_d <= 128'd0;
			px <= 0; py <= 0; ea0 <= 0; ea1 <= 0; ea2 <= 0; er0 <= 0; er1 <= 0; er2 <= 0;
			cr <= 0; cg <= 0; cb <= 0; cu <= 0; cv <= 0; rr <= 0; rg <= 0; rb <= 0; ru <= 0; rv <= 0;
			taC0 <= 0; taC1 <= 0; waddr <= 0; wbe <= 0; wdata <= 0;
		end else begin
			// --- start: the scanner at the box's top-left, the palette if needed ------
			if (start && !busy) begin
				busy <= 1'b1; scanning <= (by0 <= by1);   // an empty box draws nothing
				px <= {bx0[11:1], 1'b0}; py <= by0;
				// the pair starts one left of the box when bx0 is odd: the edge
				// functions and interpolants are asked for at px, so step back
				ea0 <= bx0[0] ? e0_0 - sx0 : e0_0; er0 <= bx0[0] ? e0_0 - sx0 : e0_0;
				ea1 <= bx0[0] ? e1_0 - sx1 : e1_0; er1 <= bx0[0] ? e1_0 - sx1 : e1_0;
				ea2 <= bx0[0] ? e2_0 - sx2 : e2_0; er2 <= bx0[0] ? e2_0 - sx2 : e2_0;
				cr <= bx0[0] ? cr_0 - dr_dx : cr_0; rr <= bx0[0] ? cr_0 - dr_dx : cr_0;
				cg <= bx0[0] ? cg_0 - dg_dx : cg_0; rg <= bx0[0] ? cg_0 - dg_dx : cg_0;
				cb <= bx0[0] ? cb_0 - db_dx : cb_0; rb <= bx0[0] ? cb_0 - db_dx : cb_0;
				cu <= bx0[0] ? cu_0 - du_dx : cu_0; ru <= bx0[0] ? cu_0 - du_dx : cu_0;
				cv <= bx0[0] ? cv_0 - dv_dx : cv_0; rv <= bx0[0] ? cv_0 - dv_dx : cv_0;
				if (!cl_ok) begin cl_loading <= 1'b1; cl_have <= 32'd0; cl_v <= 1'b0; end
			end

			// --- A: the scanner ------------------------------------------------------------
			if (scanning && !hold && pace_ok) begin
				if (last) scanning <= 1'b0;
				if (row_end) begin
					px <= {bx0[11:1], 1'b0}; py <= py + 12'd1;
					er0 <= er0 + sy0; er1 <= er1 + sy1; er2 <= er2 + sy2;
					ea0 <= er0 + sy0; ea1 <= er1 + sy1; ea2 <= er2 + sy2;
					rr <= rr + dr_dy; rg <= rg + dg_dy; rb <= rb + db_dy; ru <= ru + du_dy; rv <= rv + dv_dy;
					cr <= rr + dr_dy; cg <= rg + dg_dy; cb <= rb + db_dy; cu <= ru + du_dy; cv <= rv + dv_dy;
				end else if (skip8) begin
					px <= px + 12'd8;
					ea0 <= e8_0; ea1 <= e8_1; ea2 <= e8_2;
					cr <= cr + (dr_dx <<< 3); cg <= cg + (dg_dx <<< 3); cb <= cb + (db_dx <<< 3);
					cu <= cu + (du_dx <<< 3); cv <= cv + (dv_dx <<< 3);
				end else begin
					px <= px + 12'd2;
					ea0 <= ea0 + (sx0 <<< 1); ea1 <= ea1 + (sx1 <<< 1); ea2 <= ea2 + (sx2 <<< 1);
					cr <= cr + (dr_dx <<< 1); cg <= cg + (dg_dx <<< 1); cb <= cb + (db_dx <<< 1);
					cu <= cu + (du_dx <<< 1); cv <= cv + (dv_dx <<< 1);
				end
			end

			// --- B -------------------------------------------------------------------------
			if (bFree) begin
				// a pair with nothing in it is not sent down, except the last one,
				// which carries the end of the primitive
				vB    <= scanning && !hold && pace_ok && (a_ok || b_ok || last) && !skip8;
				lastB <= last;
				okB0  <= a_ok; okB1 <= b_ok;
				xB    <= px[9:0]; yB <= py[8:0];
				rB0 <= is_gour ? cr[23:16] : fr; gB0 <= is_gour ? cg[23:16] : fg; bB0 <= is_gour ? cb[23:16] : fb;
				rB1 <= is_gour ? cr1[23:16] : fr; gB1 <= is_gour ? cg1[23:16] : fg; bB1 <= is_gour ? cb1[23:16] : fb;
				uB0 <= twin(cu[23:16], tw_mx, tw_ox);  vB0 <= twin(cv[23:16], tw_my, tw_oy);
				uB1 <= twin(cu1[23:16], tw_mx, tw_ox); vB1 <= twin(cv1[23:16], tw_my, tw_oy);
			end

			// --- C -------------------------------------------------------------------------
			if (cFree) begin
				vC <= mvB; lastC <= lastB; okC0 <= okB0; okC1 <= okB1;
				xC <= xB; yC <= yB;
				rC0 <= rB0; gC0 <= gB0; bC0 <= bB0; rC1 <= rB1; gC1 <= gB1; bC1 <= bB1;
				uC0 <= uB0; uC1 <= uB1; oC0 <= txB0[0]; oC1 <= txB1[0];
				taC0 <= taB0; taC1 <= taB1;
			end

			// --- D -------------------------------------------------------------------------
			if (dFree) begin
				vD <= mvC; lastD <= lastC; okD0 <= okC0; okD1 <= okC1;
				xD <= xC; yD <= yC;
				tD0 <= texC0; tD1 <= texC1;
				rD0 <= rC0; gD0 <= gC0; bD0 <= bC0; rD1 <= rC1; gD1 <= gC1; bD1 <= bC1;
			end

			// --- E -------------------------------------------------------------------------
			if (eFree) begin
				vE <= mvD; lastE <= lastD;
				drawE0 <= drawD0; drawE1 <= drawD1; semiE0 <= semiD0; semiE1 <= semiD1;
				xE <= xD; yE <= yD; pE0 <= pixD0; pE1 <= pixD1;
			end

			// --- F: the write ------------------------------------------------------------
			if (f_free) begin
				wreq  <= mvE && (landE0 || landE1);
				lastF <= mvE && lastE;
				waddr <= waE;
				wbe   <= {{2{landE1}}, {2{landE0}}};
				wdata <= {outE1, outE0};
				// the held destination line sees the write too
				if (mvE && dl_hit) begin
					if (landE0) dl_d[waE[3:2]*32      +: 16] <= outE0;
					if (landE1) dl_d[waE[3:2]*32 + 16 +: 16] <= outE1;
				end
			end
			// the primitive is over when its last pair has gone out (or was empty)
			if (busy && !scanning && !vB && !vC && !vD && !vE && !wreq && fs == F_IDLE && !cl_loading)
				busy <= 1'b0;

			// --- the fetches -----------------------------------------------------------------
			case (fs)
			// not when a write is pending, nor when F is taking one this clock
			F_IDLE: if (want_fetch && !wreq && !(mvE && (landE0 || landE1))) begin
					if (cl_loading && (cl_wait == 4'd0)) begin fwho <= 2'd2; faddr <= {cl_base + {20'd0, cl_next}, 4'd0}; cl_req <= cl_next; end
					else if (want_dst)   begin fwho <= 2'd1; faddr <= waE; end
					else                 begin fwho <= 2'd0; faddr <= (needC0 && !hitC0) ? taC0 : taC1; end
					fs <= F_REQ;
				end
			F_REQ: if (f_ack) begin
					fs <= F_IDLE;
					case (fwho)
					2'd0: ;                            // the line is written into the cache above
					2'd1: begin dl_d <= v_line; dl_a <= faddr[28:4]; dl_v <= 1'b1; end
					default: ;                         // the palette line is written below
					endcase
				end

			default: fs <= F_IDLE;
			endcase

			// --- the palette store: ONE write port, the demand fill first ------------
			if (cl_wr) begin
				cdata[cl_wr_i] <= cl_wr_d;
				cl_have <= cl_nhave;
				if (cl_loading && cl_full) begin
					cl_loading <= 1'b0; cl_v <= 1'b1; cl_tag <= clut; cl_depth <= tp_depth;
				end
			end
			// hold off the next palette demand while the run is still offering
			if (no_trun)                    cl_wait <= 4'd0;
			else if (cl_wr_dem || cl_off_in) cl_wait <= 4'd12;
			else if (cl_wait != 4'd0)        cl_wait <= cl_wait - 4'd1;
			// --- writes drop what they cover (the texture cache does its own above) ------
			if (inv_go && cl_v && (inv_a[28:4] >= cl_hbase) && (inv_a[28:4] < cl_hbase + {19'd0, cl_hlines})) begin
				cl_v <= 1'b0; cl_have <= 32'd0;
			end
			if (inv_en && dl_v && dl_a == inv_line) dl_v <= 1'b0;
		end
	end
endmodule

`default_nettype wire
