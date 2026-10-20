//////////////////////////////////////////////////////////////////////////////////
// gba_ppu - the Game Boy Advance's picture: four backgrounds, the sprites, windows, blending.
//
// The console draws a line in 960 of its 1232 cycles; here a line is drawn in up to 3600 clocks
// at 50 MHz, in passes over 240 pixels: each enabled background into its own line buffer (an
// 8-bit palette index, or a direct colour in the bitmap modes), the sprites into theirs (the
// first sprite to claim a pixel keeps it, as the console's does), then a composing pass that
// finds the top two opaque layers under the windows, blends them as BLDCNT says, and sends the
// pixel out. The line is drawn from the registers as they stand when the line begins, which is
// when a game's H-blank DMA or interrupt has just set them.
//
// Memory: VRAM (96 kB), the palette (two copies, so a background and a sprite colour come out
// together) and OAM are the top's block RAMs; this reads them on their second ports, 32 bits a
// clock, a clock late.
//
// Timing: `tick` is one 16.78 MHz cycle; 4 a dot, 308 dots a line, 228 lines a frame. The
// flags and interrupts (V-blank, H-blank, V-count) and the DMA triggers come from here.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module gba_ppu (
	input  wire        clk,
	input  wire        rst,
	input  wire        tick,
	// registers (0x04000000-0x5F), halfword writes with byte enables; two read ports (a word)
	input  wire [5:0]  reg_a,              // halfword address bits 6:1
	input  wire        reg_we,
	input  wire [1:0]  reg_be,
	input  wire [15:0] reg_d,
	input  wire [5:0]  reg_ra0,
	output reg  [15:0] reg_q0,
	input  wire [5:0]  reg_ra1,
	output reg  [15:0] reg_q1,
	// the memories' second ports
	output reg  [14:0] vram_a,             // 32-bit words (96 kB = 24K words)
	input  wire [31:0] vram_q,
	output reg  [7:0]  oam_a,              // 32-bit words
	input  wire [31:0] oam_q,
	output reg  [8:0]  pal_a0,             // the background copy
	input  wire [15:0] pal_q0,
	output reg  [8:0]  pal_a1,             // the sprite copy
	input  wire [15:0] pal_q1,
	// the picture
	output reg         px_we,
	output reg  [7:0]  px_x,
	output reg  [7:0]  px_y,
	output reg  [14:0] px_rgb,
	output reg         frame_start,
	// flags and triggers
	output wire        irq_vblank,
	output wire        irq_hblank,
	output wire        irq_vcount,
	output reg         dma_vblank,         // pulses
	output reg         dma_hblank,
	output wire [7:0]  vcount,
	output wire        in_vblank,
	output wire        in_hblank
);
	// ---- registers --------------------------------------------------------------------------------
	reg [15:0] dispcnt, dispstat;
	reg [15:0] bgcnt [0:3];
	reg [8:0]  bghofs [0:3], bgvofs [0:3];
	reg [15:0] pa [2:3], pb [2:3], pc [2:3], pd [2:3];
	reg [27:0] bgx [2:3], bgy [2:3];
	reg [27:0] cx [2:3], cy [2:3];         // the internal reference points, stepping a line at a time
	reg [15:0] win0h, win1h, win0v, win1v, winin, winout, mosaic, bldcnt, bldalpha, bldy;
	reg [7:0]  line;                       // VCOUNT
	reg [10:0] cyc;                        // the cycle in the line
	assign vcount = line;
	wire       vblank = (line >= 8'd160) && (line != 8'd227);
	wire       hblank = (cyc >= 11'd1006);
	assign in_vblank = vblank; assign in_hblank = hblank;
	wire       vmatch = (line == dispstat[15:8]);
	assign irq_vblank = dispstat[3] && (line == 8'd160) && (cyc == 11'd0) && tick;
	assign irq_hblank = dispstat[4] && (cyc == 11'd1006) && tick;
	assign irq_vcount = dispstat[5] && vmatch && (cyc == 11'd0) && tick;
	integer k;

	function [15:0] rdreg;
		input [5:0] a;
		case (a)
			6'h00: rdreg = dispcnt;
			6'h02: rdreg = {dispstat[15:8], 2'd0, dispstat[5:3], vmatch, hblank, vblank};   // (the enables read back: games set them by read-modify-write)
			6'h03: rdreg = {8'd0, line};
			6'h04: rdreg = bgcnt[0]; 6'h05: rdreg = bgcnt[1]; 6'h06: rdreg = bgcnt[2]; 6'h07: rdreg = bgcnt[3];
			6'h24: rdreg = winin; 6'h25: rdreg = winout;
			6'h28: rdreg = bldcnt; 6'h29: rdreg = bldalpha;
			default: rdreg = 16'd0;
		endcase
	endfunction
	always @(*) begin reg_q0 = rdreg(reg_ra0); reg_q1 = rdreg(reg_ra1); end

	// a halfword register with byte enables
	function [15:0] mix;
		input [15:0] old; input [15:0] d; input [1:0] be;
		mix = {be[1] ? d[15:8] : old[15:8], be[0] ? d[7:0] : old[7:0]};
	endfunction

	reg bgx_w [2:3], bgy_w [2:3];          // written this frame: the internal point takes it
	always @(posedge clk) begin
		if (rst) begin
			dispcnt <= 16'h0080; dispstat <= 16'd0;
			for (k = 0; k < 4; k = k + 1) begin bgcnt[k] <= 0; bghofs[k] <= 0; bgvofs[k] <= 0; end
			for (k = 2; k < 4; k = k + 1) begin pa[k] <= 16'h0100; pb[k] <= 0; pc[k] <= 0; pd[k] <= 16'h0100; bgx[k] <= 0; bgy[k] <= 0; bgx_w[k] <= 0; bgy_w[k] <= 0; end
			win0h <= 0; win1h <= 0; win0v <= 0; win1v <= 0; winin <= 0; winout <= 0; mosaic <= 0; bldcnt <= 0; bldalpha <= 0; bldy <= 0;
		end else if (reg_we) begin
			case (reg_a)
			6'h00: dispcnt <= mix(dispcnt, reg_d, reg_be);
			6'h02: begin if (reg_be[1]) dispstat[15:8] <= reg_d[15:8]; if (reg_be[0]) dispstat[7:3] <= reg_d[7:3]; end
			6'h04, 6'h05, 6'h06, 6'h07: bgcnt[reg_a[1:0]] <= mix(bgcnt[reg_a[1:0]], reg_d, reg_be);
			6'h08: bghofs[0] <= mix({7'd0, bghofs[0]}, reg_d, reg_be); 6'h09: bgvofs[0] <= mix({7'd0, bgvofs[0]}, reg_d, reg_be);
			6'h0A: bghofs[1] <= mix({7'd0, bghofs[1]}, reg_d, reg_be); 6'h0B: bgvofs[1] <= mix({7'd0, bgvofs[1]}, reg_d, reg_be);
			6'h0C: bghofs[2] <= mix({7'd0, bghofs[2]}, reg_d, reg_be); 6'h0D: bgvofs[2] <= mix({7'd0, bgvofs[2]}, reg_d, reg_be);
			6'h0E: bghofs[3] <= mix({7'd0, bghofs[3]}, reg_d, reg_be); 6'h0F: bgvofs[3] <= mix({7'd0, bgvofs[3]}, reg_d, reg_be);
			6'h10: pa[2] <= mix(pa[2], reg_d, reg_be); 6'h11: pb[2] <= mix(pb[2], reg_d, reg_be);
			6'h12: pc[2] <= mix(pc[2], reg_d, reg_be); 6'h13: pd[2] <= mix(pd[2], reg_d, reg_be);
			6'h14: begin bgx[2][15:0] <= mix(bgx[2][15:0], reg_d, reg_be); bgx_w[2] <= 1'b1; end
			6'h15: begin bgx[2][27:16] <= mix({4'd0, bgx[2][27:16]}, reg_d, reg_be); bgx_w[2] <= 1'b1; end
			6'h16: begin bgy[2][15:0] <= mix(bgy[2][15:0], reg_d, reg_be); bgy_w[2] <= 1'b1; end
			6'h17: begin bgy[2][27:16] <= mix({4'd0, bgy[2][27:16]}, reg_d, reg_be); bgy_w[2] <= 1'b1; end
			6'h18: pa[3] <= mix(pa[3], reg_d, reg_be); 6'h19: pb[3] <= mix(pb[3], reg_d, reg_be);
			6'h1A: pc[3] <= mix(pc[3], reg_d, reg_be); 6'h1B: pd[3] <= mix(pd[3], reg_d, reg_be);
			6'h1C: begin bgx[3][15:0] <= mix(bgx[3][15:0], reg_d, reg_be); bgx_w[3] <= 1'b1; end
			6'h1D: begin bgx[3][27:16] <= mix({4'd0, bgx[3][27:16]}, reg_d, reg_be); bgx_w[3] <= 1'b1; end
			6'h1E: begin bgy[3][15:0] <= mix(bgy[3][15:0], reg_d, reg_be); bgy_w[3] <= 1'b1; end
			6'h1F: begin bgy[3][27:16] <= mix({4'd0, bgy[3][27:16]}, reg_d, reg_be); bgy_w[3] <= 1'b1; end
			6'h20: win0h <= mix(win0h, reg_d, reg_be); 6'h21: win1h <= mix(win1h, reg_d, reg_be);
			6'h22: win0v <= mix(win0v, reg_d, reg_be); 6'h23: win1v <= mix(win1v, reg_d, reg_be);
			6'h24: winin <= mix(winin, reg_d, reg_be) & 16'h3F3F; 6'h25: winout <= mix(winout, reg_d, reg_be) & 16'h3F3F;
			6'h26: mosaic <= mix(mosaic, reg_d, reg_be);
			6'h28: bldcnt <= mix(bldcnt, reg_d, reg_be) & 16'h3FFF; 6'h29: bldalpha <= mix(bldalpha, reg_d, reg_be) & 16'h1F1F;
			6'h2A: bldy <= mix(bldy, reg_d, reg_be) & 16'h001F;
			default: ;
			endcase
		end
		// the affine reference points: taken when written, stepped a line at a time, back to the
		// register's value as the frame begins
		if (!rst) begin
			for (k = 2; k < 4; k = k + 1) begin
				if (bgx_w[k] && !(reg_we && (reg_a == 6'h14 + (k - 2) * 8 || reg_a == 6'h15 + (k - 2) * 8))) begin cx[k] <= bgx[k]; bgx_w[k] <= 1'b0; end
				if (bgy_w[k] && !(reg_we && (reg_a == 6'h16 + (k - 2) * 8 || reg_a == 6'h17 + (k - 2) * 8))) begin cy[k] <= bgy[k]; bgy_w[k] <= 1'b0; end
			end
			if (tick && cyc == 11'd1231) begin
				if (line == 8'd227) begin
					for (k = 2; k < 4; k = k + 1) begin cx[k] <= bgx[k]; cy[k] <= bgy[k]; end
				end else if (line < 8'd159) begin
					for (k = 2; k < 4; k = k + 1) begin
						cx[k] <= cx[k] + {{12{pb[k][15]}}, pb[k]};
						cy[k] <= cy[k] + {{12{pd[k][15]}}, pd[k]};
					end
				end
			end
		end
	end

	// ---- timing -------------------------------------------------------------------------------------
	reg render_go;                         // a line to draw: pulses at the start of a visible line
	always @(posedge clk) begin
		render_go <= 1'b0; dma_vblank <= 1'b0; dma_hblank <= 1'b0; frame_start <= 1'b0;
		if (rst) begin line <= 8'd0; cyc <= 11'd0; end
		else if (tick) begin
			if (cyc == 11'd1231) begin
				cyc <= 11'd0;
				line <= (line == 8'd227) ? 8'd0 : line + 8'd1;
				if (line == 8'd227) frame_start <= 1'b1;
				if (line < 8'd159) render_go <= 1'b1;          // (the line after this one)
				if (line == 8'd227) render_go <= 1'b1;         // line 0
				if (line == 8'd159) dma_vblank <= 1'b1;
			end else cyc <= cyc + 11'd1;
			if (cyc == 11'd1005 && line < 8'd160) dma_hblank <= 1'b1;
		end
	end

	// ---- the line buffers ------------------------------------------------------------------------
	// a background pixel: [15] direct colour (the bitmap modes), else [7:0] the palette index,
	// 0 transparent; a sprite pixel: [7:0] index (0 none), [9:8] priority, [10] semi-transparent;
	// the sprite window mask apart. One write port each (the passes write them in turn), read by
	// the composing pass.
	reg [15:0] bgbuf0 [0:255], bgbuf1 [0:255], bgbuf2 [0:255], bgbuf3 [0:255];
	reg [10:0] objbuf [0:255];
	reg        objwin [0:255];
	reg        bgw_we; reg [1:0] bgw_n; reg [7:0] bgw_a; reg [15:0] bgw_d;
	reg        ow_we; reg [7:0] ow_a; reg [10:0] ow_d; reg ow_win;
	reg        clr_we; reg [7:0] clr_a;
	reg [15:0] bgr0, bgr1, bgr2, bgr3; reg [10:0] objr; reg objwr;
	reg [7:0]  rd_x;
	always @(posedge clk) begin
		if (bgw_we) case (bgw_n)
			2'd0: bgbuf0[bgw_a] <= bgw_d; 2'd1: bgbuf1[bgw_a] <= bgw_d; 2'd2: bgbuf2[bgw_a] <= bgw_d; default: bgbuf3[bgw_a] <= bgw_d;
		endcase
		if (clr_we) begin objbuf[clr_a] <= 11'd0; objwin[clr_a] <= 1'b0; end
		else if (ow_we) begin if (ow_win) objwin[ow_a] <= 1'b1; else objbuf[ow_a] <= ow_d; end
		bgr0 <= bgbuf0[rd_x]; bgr1 <= bgbuf1[rd_x]; bgr2 <= bgbuf2[rd_x]; bgr3 <= bgbuf3[rd_x];
		objr <= objbuf[rd_x]; objwr <= objwin[rd_x];
	end

	wire [2:0] vmode = dispcnt[2:0];
	wire       bg_on0 = dispcnt[8] && (vmode <= 3'd1);
	wire       bg_on1 = dispcnt[9] && (vmode <= 3'd1);
	wire       bg_on2 = dispcnt[10] && (vmode != 3'd6 && vmode != 3'd7);
	wire       bg_on3 = dispcnt[11] && (vmode == 3'd0 || vmode == 3'd2);
	wire       bg_aff2 = (vmode == 3'd1 || vmode == 3'd2);
	wire       bg_aff3 = (vmode == 3'd2);
	wire       bitmap  = (vmode >= 3'd3);

	// ---- the drawing machine ----------------------------------------------------------------------
	localparam [3:0] R_IDLE = 4'd0, R_CLEAR = 4'd1, R_TEXT = 4'd2, R_AFF = 4'd3, R_OBJ = 4'd4, R_OBJPAR = 4'd5,
	                 R_OBJPIX = 4'd6, R_COMP = 4'd7;
	reg [3:0]  rs;
	reg [7:0]  ry;                         // the line being drawn
	reg [1:0]  rbg;                        // the background being drawn
	reg [8:0]  rx;                         // the pixel
	reg [15:0] cnt;                        // this background's control
	reg [15:0] rdispcnt;
	reg [15:0] rbldcnt, rbldalpha; reg [4:0] rbldy;
	reg [15:0] rwinin, rwinout;
	reg [7:0]  w0l, w0r, w1l, w1r;         // the windows on this line
	reg        w0y, w1y;
	reg [3:0]  mos_bh, mos_bv, mos_oh, mos_ov;
	reg [3:0]  mosy_cnt, mosx_cnt;         // the mosaic block's line and pixel counters
	reg [3:0]  mosyo_cnt, omx_cnt;         // the sprites' mosaic: its line counter, a sprite's pixel counter
	reg [7:0]  omos_px;                    // the sprite pixel held across a mosaic block
	reg [7:0]  mosy_base;                  // the first line of the block
	reg [7:0]  mos_px;
	// text background: the tile being output and the one being fetched
	reg [8:0]  tx0, ty;                    // the scrolled position of pixel 0, the row
	reg [15:0] tmap;  reg [63:0] tpix;     // the tile out
	reg [15:0] ntmap; reg [63:0] ntpix;    // the tile fetched
	reg [3:0]  fst;                        // the fetch's phase
	reg [8:0]  ftx;                        // the tile fetched: its x (the tile's first pixel)
	reg        fdone, tstart;
	wire [8:0] tx = tx0 + rx;              // the pixel's x in the map
	// affine
	reg signed [27:0] ax, ay;              // the texel position, .8
	reg [15:0] apa, apc;
	reg [3:0]  aph;
	// the affine pass's queue: the pixel whose map byte is out (q1), in (q2), whose tile word is out (q3)
	reg        q1v, q2v, q3v, a_done, q1_out, q2_out, q3_out;
	reg [7:0]  q1_rx, q2_rx, q3_rx, q2_map;
	reg [2:0]  q1_axm, q2_axm, q3_axm, q1_aym, q2_aym;
	reg [1:0]  q1_mapb, q1_bm;
	// sprites
	reg [6:0]  oi;                         // the OAM entry
	reg [2:0]  oph;
	reg [15:0] oa0, oa1, oa2;
	reg [15:0] opa, opb, opc, opd;
	reg [10:0] obudget;                    // cycles left to sprites on this line
	reg [6:0]  ow, oh;                     // the sprite's size
	reg [6:0]  oxx;                        // the pixel across the sprite's box
	reg [8:0]  osx;                        // its x on the screen
	reg [6:0]  osy;                        // the line within the box
	reg signed [23:0] oax, oay;            // affine texel position .8
	reg [31:0] opix; reg [14:0] opix_a; reg opix_v;   // the tile word held, its address
	// composing: a pipeline, a pixel a clock
	reg [7:0]  c_x;                        // the pixel entering
	reg        c_run, c_started;
	reg [3:0]  c_v;                        // the stages' valid bits
	reg [7:0]  c_x1, c_x2, c_x3, c_x4;
	reg [5:0]  c_wmask, c_wmask2;
	reg [2:0]  c_top, c_sec, c_top2, c_sec2;
	reg [15:0] c_top_px, c_sec_px, c_top_px2, c_sec_px2;
	reg        c_semi, c_semi2;
	reg [14:0] c_bd;

	// the sprite's size from shape and size bits
	function [13:0] objsize;               // {w, h} in pixels, 7 bits each
		input [1:0] shape; input [1:0] size;
		case ({shape, size})
			4'b00_00: objsize = {7'd8, 7'd8};   4'b00_01: objsize = {7'd16, 7'd16}; 4'b00_10: objsize = {7'd32, 7'd32}; 4'b00_11: objsize = {7'd64, 7'd64};
			4'b01_00: objsize = {7'd16, 7'd8};  4'b01_01: objsize = {7'd32, 7'd8};  4'b01_10: objsize = {7'd32, 7'd16}; 4'b01_11: objsize = {7'd64, 7'd32};
			4'b10_00: objsize = {7'd8, 7'd16};  4'b10_01: objsize = {7'd8, 7'd32};  4'b10_10: objsize = {7'd16, 7'd32}; 4'b10_11: objsize = {7'd32, 7'd64};
			default:  objsize = {7'd8, 7'd8};
		endcase
	endfunction

	// text background: the fetched tile's map entry address (a 32-bit word) and its row's
	wire [1:0]  tsize = cnt[15:14];
	wire [8:0]  tmx = ftx, tmy = ty;
	wire [5:0]  tsb = {1'b0, cnt[12:8]} + (tmx[8] && tsize[0] ? 6'd1 : 6'd0) + (tmy[8] && tsize[1] ? (tsize[0] ? 6'd2 : 6'd1) : 6'd0);
	wire [14:0] tmap_word = {tsb[5:0], 9'd0} + {6'd0, tmy[7:3], tmx[7:4]};                // 2 kB blocks of 1024 entries, 2 per word
	wire        tmap_hi = tmx[3];
	wire [9:0]  nttile = ntmap[9:0];
	wire        ntvf = ntmap[11];
	wire [2:0]  trow = ntvf ? ~ty[2:0] : ty[2:0];
	wire [14:0] ttile_word8 = {1'b0, cnt[3:2], 12'd0} + {nttile, 4'd0} + {trow, 1'b0};        // 8bpp: 64 bytes a tile, 8 a row = 2 words (16 kB blocks)
	wire [14:0] ttile_word4 = {1'b0, cnt[3:2], 12'd0} + {2'd0, nttile, 3'd0} + {12'd0, trow}; // 4bpp: 32 bytes a tile, 4 a row = 1 word
	// the pixel out of the tile held
	wire        thf = tmap[10];
	wire [2:0]  tfx = thf ? ~tx[2:0] : tx[2:0];
	wire [7:0]  tpx8 = (tfx[2] ? tpix[63:32] : tpix[31:0]) >> {tfx[1:0], 3'd0};
	wire [3:0]  tpx4 = tpix[31:0] >> {tfx, 2'd0};
	wire [7:0]  tidx = cnt[7] ? tpx8 : (tpx4 == 4'd0 ? 8'd0 : {tmap[15:12], tpx4});

	// affine background / bitmap: the texel address
	wire [1:0]  asize = cnt[15:14];
	wire [9:0]  amask = (asize == 2'd0) ? 10'h07F : (asize == 2'd1) ? 10'h0FF : (asize == 2'd2) ? 10'h1FF : 10'h3FF;
	wire signed [19:0] axi = ax[27:8], ayi = ay[27:8];
	wire        aout = (axi[19:10] != 10'd0 || ayi[19:10] != 10'd0 || (axi[9:0] & ~amask) != 10'd0 || (ayi[9:0] & ~amask) != 10'd0) && !cnt[13];
	wire [9:0]  axm = axi[9:0] & amask, aym = ayi[9:0] & amask;
	wire [3:0]  ashift = (asize == 2'd0) ? 4'd4 : (asize == 2'd1) ? 4'd5 : (asize == 2'd2) ? 4'd6 : 4'd7;   // tiles across, log2
	wire [13:0] amap_byte = ({4'd0, aym[9:3]} << ashift) + {7'd0, axm[9:3]};
	wire [14:0] amap_word = {cnt[12:8], 9'd0} + {3'd0, amap_byte[13:2]};
	// bitmaps: mode 3 240x160x16 at 0; mode 4 240x160x8 at 0/A000; mode 5 160x128x16 at 0/A000
	wire        bm_frame = dispcnt[4] && vmode != 3'd3;
	wire        bm_out = (vmode == 3'd5) ? (axi >= 160 || ayi >= 128 || axi < 0 || ayi < 0) : (axi >= 240 || ayi >= 160 || axi < 0 || ayi < 0);
	wire [16:0] bm_y256 = {1'b0, ayi[7:0], 8'd0};
	wire [16:0] bm_byte = (vmode == 3'd4) ? (bm_y256 - {5'd0, ayi[7:0], 4'd0} + {9'd0, axi[7:0]})            // 240 y + x
	                    : (vmode == 3'd5) ? (bm_y256 + {3'd0, ayi[7:0], 6'd0} + {8'd0, axi[7:0], 1'b0})      // 320 y + 2x
	                    : ({ayi[7:0], 9'd0} - {4'd0, ayi[7:0], 5'd0} + {8'd0, axi[7:0], 1'b0});              // 480 y + 2x
	wire [16:0] bm_addr = bm_byte + (bm_frame ? 17'h0A000 : 17'd0);

	// sprites: this pixel's texel and tile word, and the next pixel's
	wire        o_aff = oa0[8];
	wire        o_dbl = oa0[9] && o_aff;
	wire        o_dis = oa0[9] && !o_aff;
	wire [1:0]  o_mode = oa0[11:10];
	wire        o_256 = oa0[13];
	wire [8:0]  o_x = oa1[8:0];
	wire        o_hf = oa1[12] && !o_aff, o_vf = oa1[13] && !o_aff;
	wire [9:0]  o_tile = oa2[9:0];
	wire [1:0]  o_prio = oa2[11:10];
	wire [3:0]  o_pal = oa2[15:12];
	wire [6:0]  o_bw = o_dbl ? {ow[5:0], 1'b0} : ow;      // the box the sprite is drawn in
	wire [6:0]  o_bh = o_dbl ? {oh[5:0], 1'b0} : oh;
	wire [13:0] s_wh = objsize(oa0[15:14], oa1[15:14]);  // the size as the entry is judged
	wire [6:0]  s_bw = o_dbl ? {s_wh[12:7], 1'b0} : s_wh[13:7];
	wire [6:0]  s_bh = o_dbl ? {s_wh[5:0], 1'b0} : s_wh[6:0];
	function [14:0] objword;               // the VRAM word of texel (tx, ty)
		input [5:0] tx; input [5:0] ty; input bpp8; input map1d; input [9:0] tile; input [6:0] w;
		reg [9:0] row, n;
		begin
			row = map1d ? (tile + ({4'd0, ty[5:3]} * (bpp8 ? {3'd0, w[6:2]} : {4'd0, w[6:3]}))) : (tile + {2'd0, ty[5:3], 5'd0});
			n = bpp8 ? (row + {5'd0, tx[5:3], 1'b0}) : (row + {6'd0, tx[5:3]});
			objword = 15'h4000 + (bpp8 ? ({n[9:1], 4'd0} + {ty[2:0], 1'b0} + {13'd0, tx[2]}) : ({2'd0, n, 3'd0} + {12'd0, ty[2:0]}));
		end
	endfunction
	function [9:0] objtile;                // the tile number of texel (tx, ty): the bitmap modes own the low ones
		input [5:0] tx; input [5:0] ty; input bpp8; input map1d; input [9:0] tile; input [6:0] w;
		reg [9:0] row;
		begin
			row = map1d ? (tile + ({4'd0, ty[5:3]} * (bpp8 ? {3'd0, w[6:2]} : {4'd0, w[6:3]}))) : (tile + {2'd0, ty[5:3], 5'd0});
			objtile = bpp8 ? (row + {5'd0, tx[5:3], 1'b0}) : (row + {6'd0, tx[5:3]});
		end
	endfunction
	// the affine start point's signed terms: -(box width / 2), (this line - box height / 2)
	wire signed [23:0] s_pa = {{8{opa[15]}}, opa}, s_pb = {{8{opb[15]}}, opb}, s_pc = {{8{opc[15]}}, opc};
	wire signed [23:0] s_pd_now = {{8{oam_q[31]}}, oam_q[31:16]};
	wire signed [23:0] s_nhw = -$signed({17'd0, o_bw[6:1]});
	wire signed [23:0] s_dy = $signed({17'd0, osy}) - $signed({17'd0, o_bh[6:1]});
	wire [5:0]  o_tx_reg = o_hf ? (ow[5:0] - 6'd1 - oxx[5:0]) : oxx[5:0];
	wire [5:0]  o_ty_reg = o_vf ? (oh[5:0] - 6'd1 - osy[5:0]) : osy[5:0];
	wire signed [15:0] oaxi = oax[23:8], oayi = oay[23:8];
	wire        o_aout = oaxi < 0 || oayi < 0 || oaxi >= $signed({9'd0, ow}) || oayi >= $signed({9'd0, oh});
	wire [5:0]  o_tx = o_aff ? oaxi[5:0] : o_tx_reg;
	wire [5:0]  o_ty = o_aff ? oayi[5:0] : o_ty_reg;
	wire [14:0] o_word = objword(o_tx, o_ty, o_256, rdispcnt[6], o_tile, ow);
	wire        o_bitmap_lo = bitmap && (objtile(o_tx, o_ty, o_256, rdispcnt[6], o_tile, ow) < 10'd512);
	wire [8:0]  o_bx = osx + {2'd0, oxx};                  // the pixel's x on the screen
	wire [7:0]  o_pix4 = (opix >> {o_tx[2:0], 2'd0}) & 32'hF;
	wire [7:0]  o_pix8 = (opix >> {o_tx[1:0], 3'd0}) & 32'hFF;
	wire [7:0]  o_idx  = o_256 ? o_pix8 : (o_pix4 == 8'd0 ? 8'd0 : {o_pal, o_pix4[3:0]});
	wire        o_have = opix_v && (opix_a == o_word);     // the word held is this pixel's
	// the next pixel across the box: its texel, its word -- the same word means no fetch
	wire [6:0]  oxx_n = oxx + 7'd1;
	wire signed [23:0] oax_n = oax + {{8{opa[15]}}, opa}, oay_n = oay + {{8{opc[15]}}, opc};
	wire [5:0]  o_tx_n = o_aff ? oax_n[13:8] : (o_hf ? (ow[5:0] - 6'd1 - oxx_n[5:0]) : oxx_n[5:0]);
	wire [5:0]  o_ty_n = o_aff ? oay_n[13:8] : o_ty_reg;
	wire        o_aout_n = oax_n[23:8] < 0 || oay_n[23:8] < 0 || $signed(oax_n[23:8]) >= $signed({9'd0, ow}) || $signed(oay_n[23:8]) >= $signed({9'd0, oh});
	wire [14:0] o_word_n = objword(o_tx_n, o_ty_n, o_256, rdispcnt[6], o_tile, ow);
	wire        o_have_n = opix_v && (opix_a == o_word_n) && !(o_aff && o_aout_n);
	wire [10:0] objbuf_at = objbuf[o_bx[7:0]];              // (a sprite pixel already there keeps its place)

	// the composing pass: the top two layers under the window
	wire        win_any = rdispcnt[15:13] != 3'd0;
	// priority order: lower priority number first, a sprite before backgrounds at the same
	// number, then the background's number
	function [2:0] best;                   // the top of up to five candidates
		input [15:0] b0, b1, b2, b3; input [10:0] ob; input [5:0] en; input [15:0] cnt0, cnt1, cnt2, cnt3;
		input [2:0] skip;                  // a layer already taken (for the second)
		reg [2:0] r; reg [2:0] rp; reg [2:0] p;
		begin
			r = 3'd5; rp = 3'd4;
			if (en[4] && ob[7:0] != 8'd0 && skip != 3'd4) begin r = 3'd4; rp = {1'b0, ob[9:8]}; end
			p = {1'b0, cnt0[1:0]}; if (en[0] && b0[7:0] != 8'd0 && skip != 3'd0 && p < rp) begin r = 3'd0; rp = p; end
			p = {1'b0, cnt1[1:0]}; if (en[1] && b1[7:0] != 8'd0 && skip != 3'd1 && p < rp) begin r = 3'd1; rp = p; end
			p = {1'b0, cnt2[1:0]}; if (en[2] && b2[7:0] != 8'd0 && skip != 3'd2 && p < rp) begin r = 3'd2; rp = p; end
			p = {1'b0, cnt3[1:0]}; if (en[3] && b3[7:0] != 8'd0 && skip != 3'd3 && p < rp) begin r = 3'd3; rp = p; end
			best = r;
		end
	endfunction
	// a channel blended
	function [4:0] blend;
		input [4:0] a; input [4:0] b; input [4:0] eva; input [4:0] evb;
		reg [10:0] s;
		begin s = (a * eva + b * evb) >> 4; blend = (s > 11'd31) ? 5'd31 : s[4:0]; end
	endfunction
	function [4:0] bright;
		input [4:0] a; input [4:0] evy; input up;
		reg [9:0] s;
		begin
			if (up) begin s = a + (((5'd31 - a) * evy) >> 4); bright = s[4:0]; end
			else begin s = a - ((a * evy) >> 4); bright = s[4:0]; end
		end
	endfunction
	function [14:0] effect;                // the pixel after BLDCNT
		input [14:0] c1; input [14:0] c2; input t1; input t2; input semi; input fxon; input [1:0] eff; input [15:0] alpha; input [4:0] evy;
		reg [14:0] o;
		begin
			o = c1;
			if ((semi && t2) || (fxon && eff == 2'd1 && t1 && t2))
				o = {blend(c1[14:10], c2[14:10], alpha[4:0], alpha[12:8]), blend(c1[9:5], c2[9:5], alpha[4:0], alpha[12:8]), blend(c1[4:0], c2[4:0], alpha[4:0], alpha[12:8])};
			else if (fxon && (eff == 2'd2 || eff == 2'd3) && t1)
				o = {bright(c1[14:10], evy, eff == 2'd2), bright(c1[9:5], evy, eff == 2'd2), bright(c1[4:0], evy, eff == 2'd2)};
			effect = o;
		end
	endfunction
	// the window at pixel x
	function [5:0] winmask;
		input [7:0] x; input ow;
		reg in0, in1;
		begin
			in0 = rdispcnt[13] && w0y && ((w0l <= w0r) ? (x >= w0l && x < w0r) : (x >= w0l || x < w0r));
			in1 = rdispcnt[14] && w1y && ((w1l <= w1r) ? (x >= w1l && x < w1r) : (x >= w1l || x < w1r));
			if (!win_any) winmask = 6'h3F;
			else if (in0) winmask = rwinin[5:0];
			else if (in1) winmask = rwinin[13:8];
			else if (rdispcnt[15] && ow) winmask = rwinout[13:8];
			else winmask = rwinout[5:0];
		end
	endfunction
	reg  [15:0] c_bgcnt [0:3];
	wire [5:0]  c_wmask_w = winmask(c_x2, objwr);
	wire [5:0]  c_en = c_wmask_w & {1'b1, rdispcnt[12], bg_on3, bg_on2, bg_on1, bg_on0};
	wire [2:0]  c_top_w = best(bgr0, bgr1, bgr2, bgr3, objr, c_en, c_bgcnt[0], c_bgcnt[1], c_bgcnt[2], c_bgcnt[3], 3'd7);
	wire [2:0]  c_sec_w = best(bgr0, bgr1, bgr2, bgr3, objr, c_en, c_bgcnt[0], c_bgcnt[1], c_bgcnt[2], c_bgcnt[3], c_top_w);
	function [15:0] layer_px; input [2:0] l; input [15:0] b0, b1, b2, b3; input [10:0] ob;
		layer_px = (l == 3'd4) ? {5'd0, ob} : (l == 3'd5) ? 16'd0 : (l == 3'd0) ? b0 : (l == 3'd1) ? b1 : (l == 3'd2) ? b2 : b3;
	endfunction
	wire [15:0] c_top_px_w = layer_px(c_top_w, bgr0, bgr1, bgr2, bgr3, objr);
	wire [15:0] c_sec_px_w = layer_px(c_sec_w, bgr0, bgr1, bgr2, bgr3, objr);
	wire [14:0] c_col1 = c_top_px2[15] ? c_top_px2[14:0] : (c_top2 == 3'd5) ? c_bd : pal_q0[14:0];
	wire [14:0] c_col2 = c_sec_px2[15] ? c_sec_px2[14:0] : (c_sec2 == 3'd5) ? c_bd : pal_q1[14:0];

	always @(posedge clk) begin
		px_we <= 1'b0; bgw_we <= 1'b0; ow_we <= 1'b0; clr_we <= 1'b0;
		if (rst) begin
			rs <= R_IDLE; c_run <= 1'b0; c_v <= 4'd0; c_started <= 1'b0; c_x <= 8'd0; mosy_cnt <= 4'd0; mosy_base <= 8'd0; mosyo_cnt <= 4'd0;
		end else begin
			// ---- the composing pipeline, a pixel a clock: read, choose, look up, blend ----
			// the pixel x: asked of the buffers (c_x1), answered (c_x2), chosen and its palette entries
			// asked (c_x3), the palette answered (c_x4), out
			c_v <= {c_v[2:0], c_run};
			rd_x <= c_x; c_x1 <= c_x;
			if (c_run) c_x <= c_x + 8'd1;
			if (c_run && c_x == 8'd239) c_run <= 1'b0;
			c_x2 <= c_x1;
			// the buffers hold c_x2's pixels now: the window, the top two layers, the palette asked
			c_x3 <= c_x2;
			c_wmask <= c_wmask_w; c_top <= c_top_w; c_sec <= c_sec_w;
			c_top_px <= c_top_px_w; c_sec_px <= c_sec_px_w;
			c_semi <= (c_top_w == 3'd4) && objr[10];
			pal_a0 <= (c_top_w == 3'd4) ? {1'b1, objr[7:0]} : {1'b0, c_top_px_w[7:0]};
			pal_a1 <= (c_sec_w == 3'd4) ? {1'b1, objr[7:0]} : {1'b0, c_sec_px_w[7:0]};
			// the palette answering: the choice carried along
			c_x4 <= c_x3;
			c_wmask2 <= c_wmask; c_top2 <= c_top; c_sec2 <= c_sec; c_top_px2 <= c_top_px; c_sec_px2 <= c_sec_px; c_semi2 <= c_semi;
			// the pixel out
			if (c_v[3]) begin
				px_we <= 1'b1; px_x <= c_x4; px_y <= ry;
				px_rgb <= rdispcnt[7] ? 15'h7FFF
				        : effect(c_col1, c_col2, rbldcnt[c_top2], rbldcnt[8 + c_sec2], c_semi2, c_wmask2[5], rbldcnt[7:6], rbldalpha, rbldy);
			end

			case (rs)
			R_IDLE: if (render_go) begin
				// the line's state, frozen
				ry <= line;                                            // (the counter has just reached it)
				rdispcnt <= dispcnt; rbldcnt <= bldcnt; rbldalpha <= bldalpha; rbldy <= bldy[4:0];
				rwinin <= winin; rwinout <= winout;
				w0l <= win0h[15:8]; w0r <= win0h[7:0]; w1l <= win1h[15:8]; w1r <= win1h[7:0];
				mos_bh <= mosaic[3:0]; mos_bv <= mosaic[7:4]; mos_oh <= mosaic[11:8]; mos_ov <= mosaic[15:12];
				// the mosaic's vertical block: its first line
				if (line == 8'd0 || mosy_cnt >= mosaic[7:4]) begin mosy_cnt <= 4'd0; mosy_base <= line; end
				else mosy_cnt <= mosy_cnt + 4'd1;
				if (line == 8'd0 || mosyo_cnt >= mosaic[15:12]) mosyo_cnt <= 4'd0; else mosyo_cnt <= mosyo_cnt + 4'd1;
				for (k = 0; k < 4; k = k + 1) c_bgcnt[k] <= bgcnt[k];
				pal_a0 <= 9'd0;                                      // (the backdrop, read during the clear)
				rx <= 9'd0; rs <= R_CLEAR;
			end
			// -------- the sprite buffers emptied (the backgrounds are rewritten whole) ----------------
			R_CLEAR: begin
				clr_we <= 1'b1; clr_a <= rx[7:0];
				if (rx == 9'd1) c_bd <= pal_q0[14:0];
				if (rx == 9'd239) begin
					rx <= 9'd0; rbg <= 2'd0;
					// the window rows
					w0y <= (win0v[15:8] <= ry && ry < win0v[7:0]) || (win0v[15:8] > win0v[7:0] && (ry >= win0v[15:8] || ry < win0v[7:0]));
					w1y <= (win1v[15:8] <= ry && ry < win1v[7:0]) || (win1v[15:8] > win1v[7:0] && (ry >= win1v[15:8] || ry < win1v[7:0]));
					if (rdispcnt[7]) rs <= R_COMP;                       // forced blank: white
					else begin rs <= R_TEXT; cnt <= bgcnt[0]; tstart <= 1'b1; fst <= 4'd0; fdone <= 1'b0; end
				end else rx <= rx + 9'd1;
			end
			// -------- a text background: the tile out while the next one is fetched -------------------
			R_TEXT: begin
				if ((rbg == 2'd0 && !bg_on0) || (rbg == 2'd1 && !bg_on1) || (rbg == 2'd2 && (!bg_on2 || bg_aff2 || bitmap)) || (rbg == 2'd3 && (!bg_on3 || bg_aff3))) begin
					// off, or not a text background in this mode
					if (rbg == 2'd3) begin rs <= R_AFF; rbg <= 2'd2; aph <= 4'd0; rx <= 9'd0; cnt <= bgcnt[2]; end
					else begin rbg <= rbg + 2'd1; cnt <= bgcnt[rbg + 2'd1]; tstart <= 1'b1; fst <= 4'd0; fdone <= 1'b0; rx <= 9'd0; end
				end else begin
					// the fetch of a tile: its map entry, its row (one word, two for 8bpp)
					case (fst)
					4'd0: if (tstart) begin                                // the first tile of the line
						tx0 <= bghofs[rbg]; ty <= bgvofs[rbg] + (cnt[6] ? mosy_base : ry);
						ftx <= bghofs[rbg]; tstart <= 1'b0; mosx_cnt <= 4'd0; fst <= 4'd1;
					end
					4'd1: begin vram_a <= tmap_word; fst <= 4'd2; end
					4'd2: fst <= 4'd3;
					4'd3: begin ntmap <= tmap_hi ? vram_q[31:16] : vram_q[15:0]; fst <= 4'd4; end
					4'd4: begin vram_a <= cnt[7] ? ttile_word8 : ttile_word4; fst <= 4'd5; end
					4'd5: begin vram_a <= vram_a + 15'd1; fst <= 4'd6; end
					4'd6: begin ntpix[31:0] <= vram_q; fst <= 4'd7; end
					4'd7: begin ntpix[63:32] <= vram_q; fdone <= 1'b1; fst <= 4'd8; end
					default: ;                                             // 8: holding the tile until it is taken
					endcase
					// the pixels out: a tile taken when its first pixel is due
					if (fst != 4'd0 && !tstart) begin
						if (rx == 9'd0 || tx[2:0] == 3'd0) begin
							// the tile boundary: the fetched tile becomes the one out
							if (fdone) begin
								tmap <= ntmap; tpix <= ntpix; fdone <= 1'b0;
								ftx <= ftx + 9'd8; fst <= 4'd1;                 // the next fetch
							end
						end
						if (!(rx == 9'd0 || tx[2:0] == 3'd0) || fdone) begin
							// (the pixel from the tile just taken, or the one held)
							begin : outpx
								reg [7:0] idx; reg [15:0] tm; reg [63:0] tp; reg [2:0] fx;
								tm = (rx == 9'd0 || tx[2:0] == 3'd0) ? ntmap : tmap;
								tp = (rx == 9'd0 || tx[2:0] == 3'd0) ? ntpix : tpix;
								fx = tm[10] ? ~tx[2:0] : tx[2:0];
								if (cnt[7]) idx = (fx[2] ? tp[63:32] : tp[31:0]) >> {fx[1:0], 3'd0};
								else begin idx = (tp[31:0] >> {fx, 2'd0}) & 8'hF; if (idx != 8'd0) idx = {tm[15:12], idx[3:0]}; end
								if (cnt[6]) begin                                // mosaic: the block's first pixel repeats
									if (mosx_cnt == 4'd0) mos_px <= idx; else idx = mos_px;
									mosx_cnt <= (mosx_cnt >= mos_bh) ? 4'd0 : mosx_cnt + 4'd1;
								end
								bgw_we <= 1'b1; bgw_n <= rbg; bgw_a <= rx[7:0]; bgw_d <= {8'd0, idx};
							end
							if (rx == 9'd239) begin
								rx <= 9'd0;
								if (rbg == 2'd3) begin rs <= R_AFF; rbg <= 2'd2; aph <= 4'd0; cnt <= bgcnt[2]; end
								else begin rbg <= rbg + 2'd1; cnt <= bgcnt[rbg + 2'd1]; tstart <= 1'b1; fst <= 4'd0; fdone <= 1'b0; end
							end else rx <= rx + 9'd1;
						end
					end
				end
			end
			// -------- an affine background, or the bitmap: two clocks a pixel ---------------------------
			// VRAM answers a clock after it is asked, so a pixel goes through a three-deep queue: its map
			// byte is asked for on an even clock and lands two clocks later (q2), its tile word is asked
			// for on the odd clock after that and lands two clocks later still (q3), when the pixel is
			// written. In the bitmap modes the first read is the pixel itself (written from q1).
			R_AFF: begin
				if ((rbg == 2'd2 && (!bg_on2 || !(bg_aff2 || bitmap))) || (rbg == 2'd3 && (!bg_on3 || !bg_aff3))) begin
					if (rbg == 2'd3) begin rs <= R_OBJ; oi <= 7'd0; oph <= 3'd0; obudget <= rdispcnt[5] ? 11'd954 : 11'd1210; end
					else begin rbg <= 2'd3; cnt <= bgcnt[3]; aph <= 4'd0; rx <= 9'd0; end
				end else case (aph)
				4'd0: begin                                           // the line's start point
					ax <= cx[rbg]; ay <= cy[rbg]; apa <= pa[rbg]; apc <= pc[rbg];
					if (cnt[6] && !bitmap) begin                      // (vertical mosaic: the block's first line)
						ax <= cx[rbg] - ({{12{pb[rbg][15]}}, pb[rbg]} * {24'd0, mosy_cnt});
						ay <= cy[rbg] - ({{12{pd[rbg][15]}}, pd[rbg]} * {24'd0, mosy_cnt});
					end
					aph <= 4'd1; mosx_cnt <= 4'd0; q1v <= 1'b0; q2v <= 1'b0; q3v <= 1'b0; a_done <= 1'b0;
				end
				4'd1: begin                                           // even: a map byte lands (q1 -> q2), the next pixel's is asked
					q2v <= q1v; q2_rx <= q1_rx; q2_axm <= q1_axm; q2_aym <= q1_aym; q2_out <= q1_out;
					q2_map <= (vram_q >> {q1_mapb, 3'd0}) & 8'hFF;
					if (bitmap && q1v) begin                          // the bitmap: the word is the pixel
						begin : bmpx
							reg [15:0] c;
							if (vmode == 3'd4) c = {8'd0, (vram_q >> {q1_bm, 3'd0}) & 8'hFF};
							else c = {1'b1, (q1_bm[1] ? vram_q[30:16] : vram_q[14:0])};
							if (q1_out) c = 16'd0;
							if (vmode == 3'd4 && c[7:0] == 8'd0) c = 16'd0;
							bgw_we <= 1'b1; bgw_n <= 2'd2; bgw_a <= q1_rx; bgw_d <= c;
						end
					end
					q3v <= q2v; q3_rx <= q2_rx; q3_axm <= q2_axm; q3_out <= q2_out;
					if (!a_done) begin
						if (bitmap) vram_a <= bm_addr[16:2]; else vram_a <= amap_word;
						q1v <= 1'b1; q1_rx <= rx[7:0]; q1_axm <= axm[2:0]; q1_aym <= aym[2:0]; q1_out <= bitmap ? bm_out : aout;
						q1_mapb <= amap_byte[1:0]; q1_bm <= bm_addr[1:0];
						ax <= ax + {{12{apa[15]}}, apa}; ay <= ay + {{12{apc[15]}}, apc};
						if (rx == 9'd239) a_done <= 1'b1; else rx <= rx + 9'd1;
					end else q1v <= 1'b0;
					aph <= 4'd2;
				end
				4'd2: begin                                           // odd: a tile word lands (q3 written), the next one's asked (q2)
					if (!bitmap && q3v) begin
						begin : affpx
							reg [7:0] idx;
							idx = (vram_q >> {q3_axm[1:0], 3'd0}) & 8'hFF;
							if (q3_out) idx = 8'd0;
							if (cnt[6]) begin
								if (mosx_cnt == 4'd0) mos_px <= idx; else idx = mos_px;
								mosx_cnt <= (mosx_cnt >= mos_bh) ? 4'd0 : mosx_cnt + 4'd1;
							end
							bgw_we <= 1'b1; bgw_n <= rbg; bgw_a <= q3_rx; bgw_d <= {8'd0, idx};
						end
					end
					if (!bitmap && q2v) vram_a <= {1'b0, cnt[3:2], 12'd0} + {q2_map, 4'd0} + {q2_aym, 1'b0} + {14'd0, q2_axm[2]};
					aph <= 4'd1;
					// the line is done when the queue has drained
					if (a_done && !q1v && !q2v && (bitmap || !q3v)) begin
						rx <= 9'd0; aph <= 4'd0;
						if (rbg == 2'd3 || bitmap) begin rs <= R_OBJ; oi <= 7'd0; oph <= 3'd0; obudget <= rdispcnt[5] ? 11'd954 : 11'd1210; end
						else begin rbg <= 2'd3; cnt <= bgcnt[3]; end
					end
				end
				default: aph <= 4'd0;
				endcase
			end
			// -------- the sprites: OAM in order, two clocks an entry, each one's line into the buffer ---
			R_OBJ: begin
				if (!rdispcnt[12]) rs <= R_COMP;
				else case (oph)
				3'd0: begin oam_a <= {oi, 1'b0}; oph <= 3'd1; end                      // (warming up: this entry's two words)
				3'd1: begin oam_a <= {oi, 1'b1}; oph <= 3'd2; end
				3'd2: begin oa0 <= oam_q[15:0]; oa1 <= oam_q[31:16]; oam_a <= {oi + 7'd1, 1'b0}; oph <= 3'd3; end
				3'd3: begin
					// the third word in: judged now (the size from the first two), the next entry's
					// second word asked for
					oa2 <= oam_q[15:0]; oam_a <= {oi + 7'd1, 1'b1};
					{ow, oh} <= s_wh;
					begin : onl
						reg [8:0] dy;
						dy = {1'b0, ry} - {1'b0, oa0[7:0]};
						if (dy[8]) dy = dy + 9'd256;
						osy <= oa0[12] ? ((dy[6:0] >= {3'd0, mosyo_cnt}) ? dy[6:0] - {3'd0, mosyo_cnt} : 7'd0) : dy[6:0];
						omx_cnt <= o_x % ({5'd0, mos_oh} + 9'd1);
						if (o_dis || oa0[15:14] == 2'b11 || dy >= {2'd0, s_bh} || obudget < 11'd10 || (oa0[11:10] == 2'd3) || (o_x >= 9'd240 && o_x + {2'd0, s_bw} <= 9'd512)) begin
							// not drawn: the next entry, whose words are on their way
							if (oi == 7'd127) rs <= R_COMP; else begin oi <= oi + 7'd1; oph <= 3'd2; end
						end else begin
							osx <= o_x; oxx <= 7'd0; opix_v <= 1'b0;
							if (o_aff) begin oam_a <= {oa1[13:9], 3'd1}; obudget <= obudget - 11'd10; rs <= R_OBJPAR; oph <= 3'd0; end
							else begin rs <= R_OBJPIX; oph <= 3'd0; end
						end
					end
				end
				default: oph <= 3'd0;
				endcase
			end
			R_OBJPAR: case (oph)                                      // PA PB PC PD from the parameter group
				3'd0: begin oam_a <= oam_a + 8'd2; oph <= 3'd1; end
				3'd1: begin opa <= oam_q[31:16]; oam_a <= oam_a + 8'd2; oph <= 3'd2; end
				3'd2: begin opb <= oam_q[31:16]; oam_a <= oam_a + 8'd2; oph <= 3'd3; end
				3'd3: begin opc <= oam_q[31:16]; oph <= 3'd4; end
				3'd4: begin
					opd <= oam_q[31:16];
					// the texel at the box's left edge on this line: centre + (x - w/2)*pa + (y - h/2)*pb
					oax <= s_pa * s_nhw + s_pb * s_dy + {9'd0, ow[6:1], 8'd0};
					oay <= s_pc * s_nhw + s_pd_now * s_dy + {9'd0, oh[6:1], 8'd0};
					rs <= R_OBJPIX; oph <= 3'd0;
				end
				default: oph <= 3'd0;
			endcase
			R_OBJPIX: case (oph)
				3'd0: begin                                           // the pixel: its word held, or fetched
					if (o_have || (o_aff && o_aout) || o_bx >= 9'd240 || o_bitmap_lo) oph <= 3'd3;
					else begin vram_a <= o_word; opix_a <= o_word; oph <= 3'd1; end
				end
				3'd1: oph <= 3'd2;
				3'd2: begin opix <= vram_q; opix_v <= 1'b1; oph <= 3'd3; end
				3'd3: begin
					// into the buffer if on screen, in the sprite, and free
					begin : opx
						reg [7:0] idx;
						idx = o_idx;
						if (oa0[12]) begin                                // mosaic: the block's first pixel repeats
							if (omx_cnt == 4'd0) omos_px <= o_idx; else idx = omos_px;
							omx_cnt <= (omx_cnt >= mos_oh) ? 4'd0 : omx_cnt + 4'd1;
						end
						if (o_bx < 9'd240 && !(o_aff && o_aout) && !o_bitmap_lo && idx != 8'd0) begin
							if (o_mode == 2'd2) begin ow_we <= 1'b1; ow_win <= 1'b1; ow_a <= o_bx[7:0]; end
							else if (objbuf_at[7:0] == 8'd0) begin ow_we <= 1'b1; ow_win <= 1'b0; ow_a <= o_bx[7:0]; ow_d <= {o_mode == 2'd1, o_prio, idx}; end
						end
					end
					// the next pixel across the box
					if (o_aff) begin oax <= oax + {{8{opa[15]}}, opa}; oay <= oay + {{8{opc[15]}}, opc}; end
					obudget <= obudget - (o_aff ? 11'd2 : 11'd1);
					if (oxx == o_bw - 7'd1 || obudget <= (o_aff ? 11'd2 : 11'd1)) begin
						if (oi == 7'd127) rs <= R_COMP; else begin oi <= oi + 7'd1; rs <= R_OBJ; oph <= 3'd0; end
					end else begin oxx <= oxx + 7'd1; oph <= o_have_n ? 3'd3 : 3'd0; end   // (the word held: the next pixel next clock)
				end
				default: oph <= 3'd0;
			endcase
			// -------- composing: the pipeline started, the line done when it drains -------------------
			R_COMP: begin
				if (!c_run && c_v == 4'd0 && !c_started) begin c_x <= 8'd0; c_run <= 1'b1; c_started <= 1'b1; end
				else if (!c_run && c_v == 4'd0 && c_started) begin c_started <= 1'b0; rs <= R_IDLE; end
			end
			default: rs <= R_IDLE;
			endcase
		end
	end
endmodule
`default_nettype wire
