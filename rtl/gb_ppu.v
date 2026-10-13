`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// gb_ppu.v - the Game Boy's picture processor, as the DMG has it.
//
// 160x144, four shades, one dot per T-cycle of the 4.194304 MHz clock. A line is
// 456 dots and a frame 154 lines; the first 144 lines are drawn and the last ten
// are the vertical blank. Within a drawn line the PPU walks through three modes:
//
//   mode 2   dots 0-79     OAM scan: which of the 40 objects touch this line
//   mode 3   from dot 80   drawing: 172 dots at least, more with scrolling,
//                          the window and objects
//   mode 0   to dot 455    horizontal blank
//
// and mode 1 is the vertical blank. The CPU is locked out of VRAM during mode 3
// and of OAM during modes 2 and 3; reads then give $FF and writes are dropped.
//
// --- how a line is drawn -------------------------------------------------------------
//
// The drawing is a small pipeline, the way the real chip does it, because the
// length of mode 3 depends on what is on the line and games time things by it:
//
// A fetcher reads a tile number from the map, then the two bytes of that tile's
// row, two dots each. When the background FIFO has run empty it pushes the eight
// pixels in and starts the next tile. The FIFO shifts one pixel out per dot to
// the LCD. Before the first real tile there is one throw-away fetch, which is
// what makes the first pixel appear twelve dots into mode 3 and the minimum
// length 172 (12 + 160). The low three bits of SCX are discarded pixels at the
// start of the line, so fine scrolling lengthens mode 3 by that many dots.
//
// When the window starts (WY has matched LY this frame, LCDC.5 is on, and the
// pixel about to be output is at WX-7) the background FIFO is thrown away and
// the fetcher restarts on the window map: six dots, during which nothing comes
// out. The window has its own line counter that only advances on lines it was
// actually drawn on -- this is what makes it resume where it left off after being
// hidden for a few lines, which dmg-acid2's chin checks.
//
// When an object's X reaches the pixel about to be output, the shifting stops,
// the object's tile number and attributes are read from OAM and its two bytes
// of row data from VRAM -- six dots -- and the pixels are merged into the object
// FIFO: a slot already holding a non-transparent pixel keeps it. Objects are
// fetched in the order their X positions are reached and, for equal X, in OAM
// order, which is exactly the DMG's priority rule, so "first in wins" is all the
// merging has to know. Objects at X<8 have their leading pixels cut off; objects
// at X=0 are fetched and cost their six dots but show nothing.
//
// Output: one pixel per dot on pixel_en with its position and shade (0 lightest,
// 3 darkest, already through BGP/OBP). frame_start is a pulse at dot 0 of line
// 144 -- the moment the frame is complete. With the LCD off the counters keep
// running and shade 0 is output in the same raster, so whatever displays the
// picture keeps getting frames.
//
// --- memories ------------------------------------------------------------------------------
//
// VRAM (8 kB) and OAM (160 bytes) are inside. Each is a block RAM with the CPU
// (and DMA, for OAM) on one port and the PPU on the other. The PPU's read
// address is combinational from its state and the data is used the dot after it
// was asked for, which is what a one-clock block RAM delivers whether a dot is
// one clock (the benches) or twelve (the board).
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module gb_ppu (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,            // one dot

	// registers $FF40-$FF4B (DMA at $FF46 is the top's; a write here is ignored)
	input  wire [3:0]  reg_a,         // addr[3:0]
	input  wire        reg_we,        // one clock pulse
	input  wire [7:0]  reg_d,
	output reg  [7:0]  reg_q,

	// VRAM $8000-$9FFF from the CPU; blocked in mode 3
	input  wire [12:0] vram_a,
	input  wire        vram_we,
	input  wire [7:0]  vram_d,
	output wire [7:0]  vram_q,

	// OAM $FE00-$FE9F from the CPU or DMA; blocked in modes 2 and 3 for the CPU
	input  wire [7:0]  oam_a,
	input  wire        oam_we,
	input  wire [7:0]  oam_d,
	input  wire        oam_dma,       // the write comes from DMA: never blocked
	output wire [7:0]  oam_q,

	output reg         irq_vblank,    // pulses
	output reg         irq_stat,

	output reg  [7:0]  px_x,
	output reg  [7:0]  px_y,
	output reg  [1:0]  px_shade,
	output reg         pixel_en,
	output reg         frame_start,

	output wire [1:0]  mode_out,
	output wire        lcd_on
);

	// --- registers ---------------------------------------------------------------------
	reg [7:0] lcdc, scy, scx, lyc, bgp, obp0, obp1, wy, wx;
	reg [3:0] stat_ie;                 // STAT bits 6:3
	assign lcd_on = lcdc[7];

	// --- counters ------------------------------------------------------------------------
	reg [8:0] dot;                     // 0..455
	reg [7:0] line;                    // 0..153
	reg [1:0] mode;
	assign mode_out = mode;

	// LY reads 0 for most of line 153: the real counter wraps early.
	wire [7:0] ly = (line == 8'd153 && dot >= 9'd4) ? 8'd0 : line;
	wire       lyc_eq = lcd_on && (ly == lyc);

	// --- VRAM -------------------------------------------------------------------------------
	reg [7:0] vram [0:8191];
	reg [7:0] vram_q_r;
	always @(posedge clk) begin
		if (vram_we && !(lcd_on && mode == 2'd3)) vram[vram_a] <= vram_d;
		vram_q_r <= vram[vram_a];
	end
	assign vram_q = (lcd_on && mode == 2'd3) ? 8'hFF : vram_q_r;

	reg [12:0] fv_a;                   // the fetcher's read address (combinational)
	reg [7:0]  fv_q;
	// Read on the dot only. The pipeline uses this the dot AFTER it asked; read on
	// every clock it would instead hold the answer for the current dot's address
	// whenever a dot is longer than a clock -- on the board (12 clocks) and in any
	// stall. acid2 drew wrong objects with the ROM 2 clocks late and right with it
	// 1 clock late, which is how this was found.
	always @(posedge clk) if (ce) fv_q <= vram[fv_a];

	// --- OAM ---------------------------------------------------------------------------------
	reg [7:0] oam [0:159];
	reg [7:0] oam_q_r;
	wire oam_blocked = lcd_on && (mode == 2'd2 || mode == 2'd3);
	always @(posedge clk) begin
		if (oam_we && (oam_dma || !oam_blocked) && oam_a < 8'd160) oam[oam_a] <= oam_d;
		oam_q_r <= (oam_a < 8'd160) ? oam[oam_a] : 8'h00;
	end
	assign oam_q = oam_blocked ? 8'hFF : oam_q_r;

	reg [7:0] fo_a;                    // the PPU's own OAM read address (combinational)
	reg [7:0] fo_q;
	always @(posedge clk) if (ce) fo_q <= oam[fo_a];       // on the dot, as fv_q

	// --- the line's objects --------------------------------------------------------------------
	reg [5:0] sp_idx [0:9];
	reg [7:0] sp_x   [0:9];
	reg [7:0] sp_y   [0:9];
	reg [9:0] sp_done;                 // fetched already this line
	reg [3:0] sp_n;                    // how many were found
	reg [7:0] scan_y;                  // the Y just read in the scan
	wire      obj16 = lcdc[2];

	// is object `scan_i` on this line? (ly+16 falls within its 8 or 16 rows)
	wire [8:0] scan_dy = {1'b0, line} + 9'd16 - {1'b0, scan_y};
	wire       scan_hit = (scan_dy[8] == 1'b0) && (obj16 ? (scan_dy < 9'd16) : (scan_dy < 9'd8));

	// --- the pipeline ----------------------------------------------------------------------------
	reg [7:0]  lx;                     // the pixel about to be output, 0..160
	reg [2:0]  discard;                // SCX & 7 pixels to drop
	reg [15:0] bg_fifo;                // 8 pixels, 2 bits each, next out at the top
	reg [3:0]  bg_cnt;
	reg [31:0] ob_fifo;                // 8 x {bg_priority, palette, color[1:0]}
	reg        win_act;                // drawing the window on this line
	reg        wy_hit;                 // WY == LY happened this frame
	reg [7:0]  wline;                  // the window's own line counter
	reg [4:0]  ftx;                    // fetcher's tile column (background: added to SCX/8; window: as is)
	reg [2:0]  fstep;                  // 0..5 fetch, 6/7 waiting to push
	reg        fdummy;                 // the throw-away fetch at the start of the line
	reg [7:0]  ftile, fdat_lo, fdat_hi;
	reg        sfetch;                 // an object fetch is in progress
	reg [2:0]  sstep;
	reg [3:0]  sk;                     // which of the line's objects
	reg [7:0]  stile, sattr, sdat_lo;

	// Which object (if any) starts at this pixel: the first unfetched one whose X
	// has been reached. X <= lx+8 rather than ==, so objects at X < 8 are taken at
	// lx = 0 with their first pixels cut off.
	reg       sp_match;
	reg [3:0] sp_match_k;
	integer   si;
	always @(*) begin
		sp_match = 1'b0;
		sp_match_k = 4'd0;
		for (si = 9; si >= 0; si = si - 1)
			if (si < sp_n && !sp_done[si] && ({1'b0, sp_x[si]} <= {1'b0, lx} + 9'd8)) begin
				sp_match = 1'b1;
				sp_match_k = si[3:0];
			end
	end

	// the fetcher's addresses
	wire [7:0]  bg_y   = line + scy;
	wire [4:0]  bg_tx  = scx[7:3] + ftx;
	wire [7:0]  map_y  = win_act ? wline : bg_y;
	wire [4:0]  map_x  = win_act ? ftx : bg_tx;
	wire        map_hi = win_act ? lcdc[6] : lcdc[3];
	wire [12:0] map_addr  = {2'b11, map_hi, map_y[7:3], map_x};
	wire [12:0] tile_addr = {(!lcdc[4] && !ftile[7]), ftile, map_y[2:0], 1'b0};

	// the object being fetched
	wire [7:0] s_y   = sp_y[sk];
	wire [7:0] s_x   = sp_x[sk];
	wire [3:0] s_row0 = line[3:0] + 4'd0 - s_y[3:0];            // line + 16 - y, low 4 bits
	wire [3:0] s_row  = sattr[6] ? (obj16 ? ~s_row0 : {1'b0, ~s_row0[2:0]}) : s_row0;
	wire [12:0] s_addr = obj16 ? {1'b0, stile[7:1], s_row, 1'b0} : {1'b0, stile, s_row[2:0], 1'b0};
	wire [7:0] s_cut = (s_x < 8'd8) ? (8'd8 - s_x) : 8'd0;    // leading pixels off the left edge

	// PPU-side memory addresses, by state
	always @(*) begin
		// OAM: the scan reads Y then X of object dot/2; a fetch reads tile then attributes
		if (sfetch) fo_a = {sp_idx[sk], 1'b1, sstep[0]};          // +2 tile, +3 attr
		else        fo_a = {dot[6:1], 1'b0, dot[0]};              // +0 Y, +1 X
		// VRAM: background fetch or object fetch
		if (sfetch) fv_a = s_addr | {12'd0, (sstep == 3'd4)};     // low byte asked in step 3, high in step 4
		else case (fstep)
			3'd0, 3'd1: fv_a = map_addr;
			3'd2, 3'd3: fv_a = tile_addr;
			default:    fv_a = tile_addr | 13'd1;
		endcase
	end

	// --- pixel output ----------------------------------------------------------------------------------
	// Background FIFO front pixel and object FIFO front pixel
	wire [1:0] bg_px  = lcdc[0] ? bg_fifo[15:14] : 2'd0;
	wire [3:0] ob_px  = ob_fifo[31:28];                          // {prio, pal, color}
	wire       ob_vis = lcdc[1] && (ob_px[1:0] != 2'd0) && !(ob_px[3] && bg_px != 2'd0);
	reg  [1:0] shade;
	always @(*) begin
		if (ob_vis) begin
			case (ob_px[1:0])
				2'd1: shade = ob_px[2] ? obp1[3:2] : obp0[3:2];
				2'd2: shade = ob_px[2] ? obp1[5:4] : obp0[5:4];
				default: shade = ob_px[2] ? obp1[7:6] : obp0[7:6];
			endcase
		end else begin
			case (bg_px)
				2'd0: shade = bgp[1:0];
				2'd1: shade = bgp[3:2];
				2'd2: shade = bgp[5:4];
				default: shade = bgp[7:6];
			endcase
		end
	end

	// The object merge: the row's 8 pixels (flipped if asked), cut on the left,
	// each dropped into a slot that is still transparent.
	reg [31:0] ob_merged;
	reg [7:0]  m_lo, m_hi;
	integer    mi;
	reg [3:0]  mslot;
	always @(*) begin
		m_lo = sattr[5] ? {sdat_lo[0], sdat_lo[1], sdat_lo[2], sdat_lo[3], sdat_lo[4], sdat_lo[5], sdat_lo[6], sdat_lo[7]} : sdat_lo;
		m_hi = sattr[5] ? {fv_q[0], fv_q[1], fv_q[2], fv_q[3], fv_q[4], fv_q[5], fv_q[6], fv_q[7]} : fv_q;
		ob_merged = ob_fifo;
		for (mi = 0; mi < 8; mi = mi + 1) begin
			// pixel mi (0 = leftmost) lands in slot mi - cut
			mslot = mi[3:0] - s_cut[3:0];
			if (mi >= s_cut && ob_fifo[(29 - 4 * mslot) -: 2] == 2'd0 && {m_hi[7 - mi], m_lo[7 - mi]} != 2'd0)
				ob_merged[(31 - 4 * mslot) -: 4] = {sattr[7], sattr[4], m_hi[7 - mi], m_lo[7 - mi]};
		end
	end

	// --- STAT interrupt line -------------------------------------------------------------------------
	// Any enabled source high raises it; the interrupt is its rising edge, so a
	// second source turning on while one is already high does nothing (STAT
	// blocking). Line 144 also gives one mode-2 pulse at its start, as the chip does.
	wire stat_line = lcd_on && (
		(stat_ie[0] && mode == 2'd0) ||
		(stat_ie[1] && mode == 2'd1) ||
		(stat_ie[2] && (mode == 2'd2 || (line == 8'd144 && dot < 9'd4))) ||
		(stat_ie[3] && lyc_eq));
	reg stat_line_q;

	// --- the machine -------------------------------------------------------------------------------------
	wire mode3 = lcd_on && (mode == 2'd3);
	wire out_now = mode3 && !sfetch && bg_cnt != 4'd0;          // a pixel could leave the FIFO this dot
	wire win_start = out_now && !win_act && lcdc[5] && wy_hit && (wx == lx + 8'd7) && (discard == 3'd0);
	wire obj_start = out_now && !win_start && lcdc[1] && sp_match && (discard == 3'd0);
	wire pop       = out_now && !win_start && !obj_start;
	wire [3:0] bg_cnt_after = pop ? bg_cnt - 4'd1 : bg_cnt;
	wire fetch_ready = (fstep >= 3'd5);                           // both data bytes in hand (hi arrives at 5)
	// The high data byte is used the dot it arrives (step 5), before fdat_hi holds it.
	wire [7:0] fdat_hi_now = (fstep == 3'd5) ? fv_q : fdat_hi;
	wire [7:0] fdat_lo_now = fdat_lo;
	wire push = mode3 && !sfetch && fetch_ready && !fdummy && (bg_cnt_after == 4'd0) && !win_start;

	integer i;
	always @(posedge clk) begin
		irq_vblank  <= 1'b0;
		irq_stat    <= 1'b0;
		pixel_en    <= 1'b0;
		frame_start <= 1'b0;

		if (rst) begin
			lcdc <= 8'h91; stat_ie <= 4'd0; scy <= 8'd0; scx <= 8'd0; lyc <= 8'd0;
			bgp <= 8'hFC; obp0 <= 8'hFF; obp1 <= 8'hFF; wy <= 8'd0; wx <= 8'd0;
			dot <= 9'd0; line <= 8'd0; mode <= 2'd0;
			stat_line_q <= 1'b0;
			sp_n <= 4'd0; sp_done <= 10'd0;
			lx <= 8'd0; bg_cnt <= 4'd0; bg_fifo <= 16'd0; ob_fifo <= 32'd0;
			win_act <= 1'b0; wy_hit <= 1'b0; wline <= 8'd0;
			ftx <= 5'd0; fstep <= 3'd0; fdummy <= 1'b1; discard <= 3'd0;
			sfetch <= 1'b0; sstep <= 3'd0; sk <= 4'd0;
			px_x <= 8'd0; px_y <= 8'd0; px_shade <= 2'd0;
		end else begin
			// --- CPU register writes --------------------------------------------------------
			if (reg_we) case (reg_a)
				4'h0: begin
					lcdc <= reg_d;
					// Turning the LCD off or on restarts the raster at line 0.
					if (lcdc[7] != reg_d[7]) begin
						dot <= 9'd0; line <= 8'd0; mode <= 2'd0;
						wy_hit <= 1'b0; wline <= 8'd0;
					end
				end
				4'h1: stat_ie <= reg_d[6:3];
				4'h2: scy <= reg_d;
				4'h3: scx <= reg_d;
				4'h5: lyc <= reg_d;
				4'h7: bgp <= reg_d;
				4'h8: obp0 <= reg_d;
				4'h9: obp1 <= reg_d;
				4'hA: wy <= reg_d;
				4'hB: wx <= reg_d;
				default: ;
			endcase

			// --- the STAT interrupt is the rising edge of its line ----------------------------
			stat_line_q <= stat_line;
			if (stat_line && !stat_line_q) irq_stat <= 1'b1;

			if (ce) begin
				// --- the raster --------------------------------------------------------------
				if (dot == 9'd455) begin
					dot <= 9'd0;
					line <= (line == 8'd153) ? 8'd0 : line + 8'd1;
				end else dot <= dot + 9'd1;

				if (!lcd_on) begin
					// Off: the same raster of shade 0, so the picture keeps coming.
					mode <= 2'd0;
					if (line < 8'd144 && dot >= 9'd92 && dot < 9'd252) begin
						pixel_en <= 1'b1; px_x <= dot[7:0] - 8'd92; px_y <= line; px_shade <= 2'd0;
					end
					if (line == 8'd144 && dot == 9'd0) frame_start <= 1'b1;
				end else begin
					// --- modes ---------------------------------------------------------------------
					if (dot == 9'd0) begin
						if (line < 8'd144) begin
							mode <= 2'd2;
							sp_n <= 4'd0; sp_done <= 10'd0;
							// WY is compared at the start of every line; a match arms the
							// window for the rest of the frame.
							if (lcdc[5] && wy == line) wy_hit <= 1'b1;
							if (line == 8'd0) begin wy_hit <= (lcdc[5] && wy == 8'd0); wline <= 8'd0; end
						end else begin
							mode <= 2'd1;
							if (line == 8'd144) begin irq_vblank <= 1'b1; frame_start <= 1'b1; end
						end
						// the window's line counter: one more for each line it was drawn on
						if (win_act) wline <= wline + 8'd1;
						win_act <= 1'b0;
					end

					// --- mode 2: the scan, two dots per object ---------------------------------
					// dot 2i asks for Y, 2i+1 has Y and asks for X, 2i+2 has X and decides.
					if (mode == 2'd2 && line < 8'd144) begin
						if (dot[0] == 1'b1) scan_y <= fo_q;
						if (dot[0] == 1'b0 && dot != 9'd0 && sp_n < 4'd10 && scan_hit) begin
							sp_idx[sp_n] <= dot[6:1] - 6'd1;
							sp_x[sp_n]   <= fo_q;
							sp_y[sp_n]   <= scan_y;
							sp_n <= sp_n + 4'd1;
						end
						if (dot == 9'd79) begin
							mode <= 2'd3;
							// the pipeline starts empty
							lx <= 8'd0; bg_cnt <= 4'd0; ob_fifo <= 32'd0;
							ftx <= 5'd0; fstep <= 3'd0; fdummy <= 1'b1;
							discard <= scx[2:0];
							sfetch <= 1'b0;
						end
					end
					// object 39's X arrives at dot 80, the first dot of mode 3
					if (mode == 2'd3 && dot == 9'd80 && sp_n < 4'd10 && scan_hit) begin
						sp_idx[sp_n] <= 6'd39;
						sp_x[sp_n]   <= fo_q;
						sp_y[sp_n]   <= scan_y;
						sp_n <= sp_n + 4'd1;
					end

					// --- mode 3: the pipeline -----------------------------------------------------
					if (mode == 2'd3) begin
						// the background fetcher
						if (!sfetch) begin
							case (fstep)
								3'd1: begin ftile <= fv_q; fstep <= 3'd2; end
								3'd3: begin fdat_lo <= fv_q; fstep <= 3'd4; end
								3'd5: begin
									fdat_hi <= fv_q;
									if (fdummy) begin fdummy <= 1'b0; fstep <= 3'd0; end
									else if (push) begin fstep <= 3'd0; ftx <= ftx + 5'd1; end
									else fstep <= 3'd6;
								end
								3'd6, 3'd7: if (push) begin fstep <= 3'd0; ftx <= ftx + 5'd1; end
								// An address step. If an object fetch starts now it takes the
								// VRAM port for six dots, so the data this step asked for would
								// be gone by the time the next step looked: stay here and ask
								// again afterwards. (The first version resumed on the latch step
								// and took the object's bytes for the tile's.)
								default: if (!obj_start) fstep <= fstep + 3'd1;
							endcase
						end
						if (push) begin
							bg_fifo <= {fdat_hi_now[7], fdat_lo_now[7], fdat_hi_now[6], fdat_lo_now[6],
							            fdat_hi_now[5], fdat_lo_now[5], fdat_hi_now[4], fdat_lo_now[4],
							            fdat_hi_now[3], fdat_lo_now[3], fdat_hi_now[2], fdat_lo_now[2],
							            fdat_hi_now[1], fdat_lo_now[1], fdat_hi_now[0], fdat_lo_now[0]};
							bg_cnt <= 4'd8;
						end else if (pop) begin
							bg_fifo <= {bg_fifo[13:0], 2'b00};
							bg_cnt  <= bg_cnt - 4'd1;
						end

						// the window starts: throw the background away and refetch
						if (win_start) begin
							win_act <= 1'b1;
							bg_cnt <= 4'd0;
							ftx <= 5'd0; fstep <= 3'd0; fdummy <= 1'b0;
						end

						// an object starts: six dots of fetching
						if (obj_start) begin
							sfetch <= 1'b1; sstep <= 3'd0; sk <= sp_match_k;
							sp_done[sp_match_k] <= 1'b1;
						end
						if (sfetch) begin
							case (sstep)
								3'd1: stile <= fo_q;
								3'd2: sattr <= fo_q;
								3'd4: sdat_lo <= fv_q;
								3'd5: begin ob_fifo <= ob_merged; sfetch <= 1'b0; end
								default: ;
							endcase
							sstep <= sstep + 3'd1;
						end

						// a pixel leaves
						if (pop) begin
							ob_fifo <= {ob_fifo[27:0], 4'd0};
							if (discard != 3'd0) discard <= discard - 3'd1;
							else begin
								pixel_en <= 1'b1; px_x <= lx; px_y <= line; px_shade <= shade;
								lx <= lx + 8'd1;
								if (lx == 8'd159) mode <= 2'd0;
							end
						end
					end
				end
			end
		end
	end

	// --- register reads -----------------------------------------------------------------------
	always @(*) begin
		case (reg_a)
			4'h0: reg_q = lcdc;
			4'h1: reg_q = {1'b1, stat_ie, lyc_eq, lcd_on ? mode : 2'd0};
			4'h2: reg_q = scy;
			4'h3: reg_q = scx;
			4'h4: reg_q = lcd_on ? ly : 8'd0;
			4'h5: reg_q = lyc;
			4'h7: reg_q = bgp;
			4'h8: reg_q = obp0;
			4'h9: reg_q = obp1;
			4'hA: reg_q = wy;
			4'hB: reg_q = wx;
			default: reg_q = 8'hFF;
		endcase
	end

endmodule
