`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// md_vdp.v - the Mega Drive's video chip, a Sega 315-5313.
//
// A descendant of the Master System's 315-5124 next door, and it shows in the
// small things: tiles are still four bitplanes and thirty-two bytes, the name
// table is still one word per cell, and the line-interrupt counter works the
// same way. Everything else is bigger.
//
//   - Two scrolling planes instead of one, plus a Window that replaces part of
//     plane A, plus 80 sprites instead of 64.
//   - Each plane cell carries a PRIORITY bit, so a plane is not simply in front
//     of or behind another -- high-priority cells of the back plane come out in
//     front of low-priority cells of the front one. Four layers from two.
//   - Scrolling comes out of memory rather than out of registers: horizontal
//     from a table in VRAM, vertical from a separate 40-word VSRAM, either of
//     them whole-screen, per-cell or per-line.
//   - 64 kB of VRAM, and a DMA engine to fill it, because a 68000 writing it a
//     word at a time cannot keep up with a game.
//
// --- the ports ------------------------------------------------------------------
//
// The 68000 sees two 16-bit registers, and as on the Master System the protocol
// lives in the SEQUENCE rather than in the address.
//
//   data     read or write VRAM, CRAM or VSRAM at the current address, then add
//            the auto-increment register to it
//   control  write once with the top two bits 10 to set a register; write twice
//            otherwise to set up a 6-bit code and a 17-bit address. Read it for
//            the status word.
//
// The two-word command splits oddly, and getting it wrong is the classic way to
// have a VDP that works until a game uses the upper half of VRAM:
//
//       15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
//   1: CD1 CD0 <----------------- A13..A0 ----------->
//   2:  0  0  0  0  0  0  0  0 CD5 CD4 CD3 CD2  0 A16 A15 A14
//
// A control-port READ clears the pending half of that sequence, exactly as the
// Master System's status read does -- so a status read in the middle of a
// command does not merely report, it resynchronises.
//
// --- how this differs from the real part ------------------------------------------
//
// On real hardware the renderer and the CPU share one path into VRAM, and the
// renderer wins: a game that writes during active display gets stalled, and the
// FIFO is how it finds out. Here VRAM is block RAM with two ports, so the
// renderer has its own and never has to negotiate. Games do not depend on being
// stalled -- they depend on NOT being -- so the difference is invisible to
// anything except a test that measures FIFO timing.
//
// This file is being built in increments, each with its own tests. What is here
// now: the control port, the register file, all three memories with their
// auto-increment, the status word, video timing, both scrolling planes with
// their priority resolved, the window layer, the two interrupts, all three kinds
// of DMA, and sprites.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module md_vdp (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,           // one pixel

	// --- the 68000 side ---------------------------------------------------------
	input  wire        cpu_sel,      // an access is happening this cycle
	input  wire        cpu_ctrl,     // 0 = data port, 1 = control port
	input  wire        cpu_wr,
	input  wire [15:0] cpu_din,
	output wire [15:0] cpu_dout,

	// --- interrupts -------------------------------------------------------------
	// Active low and three bits wide, because that is the shape the 68000 wants.
	// VBlank is level 6 and the line counter is level 4.
	output wire [2:0]  ipl_n,
	output reg         zint,         // the Z80's interrupt: one line long, from the vertical blank's start
	input  wire        int_ack,     // the 68000 has taken one

	// --- the way out to the 68000's memory, for the DMA that reads it -----------
	// The VDP becomes a bus master for the duration. The top level answers by
	// putting a word on dma_din and raising dma_ack for one clock.
	output wire        dma_req,
	output wire [22:0] dma_addr,    // a WORD address; the 68000's bus is 16 bits
	input  wire [15:0] dma_din,
	input  wire        dma_ack,
	output wire        dma_busy_out, // the bus is the VDP's until this goes away

	// H40 or H32. The framebuffer is 320 across whatever the game picks, so
	// something has to say which of those columns the picture actually occupies
	// -- otherwise the 64 the game never touches keep whatever was in them.
	output wire        h40_out,

	// --- the H/V counter, read at $C00008 ---------------------------------------
	// High byte the line, low byte the dot over two. Games poll it to find the
	// top of the frame without taking an interrupt, and one that does will spin
	// forever if it always reads the same value.
	output wire [15:0] hv_count,

	// --- video out --------------------------------------------------------------
	output wire [9:0]  px,
	output wire [9:0]  py,
	output wire        pixel_en,
	output wire [5:0]  color_ix,     // which of the 64 CRAM entries
	output wire [8:0]  color,        // and what is in it: BBBGGGRRR

	// --- things the rest of the machine wants to see -----------------------------
	output wire [7:0]  dbg_reg0,
	output wire [16:0] dbg_addr,
	output wire [5:0]  dbg_code,
	output wire        dbg_pending
);

	// --- the register file ----------------------------------------------------------
	// Twenty-four of them. Only the ones the current increment uses are named
	// here; the rest are kept because a game writes them all at startup and a
	// register that is not stored is a register that reads back wrong.
	reg [7:0] r [0:23];

	wire [7:0] inc = r[15];          // how far the address moves after an access

	// --- the address and code ---------------------------------------------------------
	reg [16:0] addr;
	reg [5:0]  code;
	reg        pending;              // the first half of a command has arrived

	// --- the memories ------------------------------------------------------------------
	// VRAM is 64 kB and is reached as 32768 words. CRAM is 64 colours of nine
	// bits, three each of blue, green and red. VSRAM is 40 words of eleven bits,
	// one per two-cell column plus a couple the hardware does not use.
	//
	// VRAM has to be BLOCK RAM, and block RAM has exactly two ports. Everything
	// that touches it therefore goes through one of the two always blocks at the
	// bottom of this file and nowhere else: a third access point -- a CPU read
	// written separately from the CPU write, say -- makes the whole 64 kB come
	// out as sixteen thousand LUTs of distributed memory, which is most of the
	// chip, and it does so silently.
	reg [15:0] vram  [0:32767];
	reg [8:0]  cram  [0:63];
	reg [10:0] vsram [0:39];

	// --- DMA -----------------------------------------------------------------------------
	// Three kinds, told apart by the top two bits of register 23:
	//
	//   0x  read the 68000's memory and write it here, a word at a time. The
	//       destination is whatever the command's code field said, so one engine
	//       fills VRAM, CRAM and VSRAM.
	//   10  fill VRAM with a byte. Armed by the command, but it does not START
	//       until the value arrives through the data port -- and that first write
	//       goes in as an ordinary word write before the fill begins.
	//   11  copy VRAM to VRAM, a byte at a time.
	//
	// A length of zero means 65536, which is how a game clears the whole of VRAM
	// in one go.
	reg        dma_active;
	reg        dma_armed;           // a fill, waiting for its value
	reg [1:0]  dma_mode;
	reg [1:0]  dma_st;
	reg [16:0] dma_len;
	reg [22:0] dma_sa;              // the source: words for the 68000, bytes here
	reg [15:0] dma_fill;
	reg [7:0]  dma_byte;            // the byte a copy has just read

	// --- status ---------------------------------------------------------------------
	wire dma_busy = dma_active;
	assign dma_busy_out = dma_active;
	reg odd_frame;
	reg spr_collide;
	reg spr_overflow;
	reg vint_pending;
	reg hint_pending;
	wire is_pal = 1'b0;


	assign dbg_reg0    = r[0];
	assign dbg_addr    = addr;
	assign dbg_code    = code;
	assign dbg_pending = pending;

	// --- what the registers mean ------------------------------------------------------
	// Named here rather than at each use. A register pulled out of r[] by number
	// in the middle of an address calculation is how a plane ends up being
	// fetched from the sprite table.
	wire        disp_en = r[1][6];
	wire        h40     = r[12][0] | r[12][7];
	wire        v30     = r[1][3];

	// Base addresses, all of them in WORDS, because that is how VRAM is indexed
	// here. Each is one bit less of shift than the manual's byte figure.
	wire [14:0] nt_a_base = {r[2][5:3], 12'd0};
	wire [14:0] nt_b_base = {r[4][2:0], 12'd0};
	wire [14:0] win_base  = {r[3][5:1], 10'd0};
	wire [14:0] hs_base   = {r[13][5:0], 9'd0};
	wire [5:0]  backdrop  = r[7][5:0];

	// --- the window ---------------------------------------------------------------------
	// Not a third plane: where the window is, it REPLACES plane A. Two registers
	// say where, each as a position plus a direction, and the window is
	// everything on the named side of either of them -- so a status bar across
	// the top and a panel down one side are the same feature used twice.
	//
	// It does not scroll, which is the whole point of it. Its name table is also
	// always the full width of the screen rather than the plane size.
	wire [5:0] win_hpos  = {r[17][4:0], 1'b0};   // in cells, from a 2-cell field
	wire       win_right = r[17][7];
	wire [5:0] win_vpos  = r[18][4:0];
	wire       win_down  = r[18][7];

	// Plane size in cells. 00 is 32, 01 is 64, 11 is 128; 10 is not a size.
	function [7:0] plane_cells;
		input [1:0] code;
		begin
			case (code)
			2'b00:   plane_cells = 8'd32;
			2'b01:   plane_cells = 8'd64;
			default: plane_cells = 8'd128;
			endcase
		end
	endfunction
	wire [7:0] pw      = plane_cells(r[16][1:0]);
	wire [7:0] ph      = plane_cells(r[16][5:4]);
	wire [7:0] pw_mask = pw - 8'd1;
	wire [7:0] ph_mask = ph - 8'd1;

	wire [1:0] hscroll_mode = r[11][1:0];
	wire       vscroll_col  = r[11][2];

	// --- video timing -------------------------------------------------------------------
	// H40 is 420 cycles of which 320 are picture; H32 is 342 of which 256 are.
	// The totals make the line the right LENGTH, which is what a television
	// cares about; the active counts make the picture the right width.
	wire [9:0] h_total  = h40 ? 10'd420 : 10'd342;
	wire [9:0] h_active = h40 ? 10'd320 : 10'd256;
	wire [9:0] v_total  = v30 ? 10'd313 : 10'd262;
	wire [9:0] v_active = v30 ? 10'd240 : 10'd224;

	reg [9:0] hc, vc;
	wire      line_end  = (hc == h_total - 10'd1);
	wire      frame_end = (vc == v_total - 10'd1);
	wire [9:0] next_line = frame_end ? 10'd0 : vc + 10'd1;

	assign px       = hc;
	assign py       = vc;

	// Both counters JUMP partway along, and the jumps are not cosmetic.
	//
	// 262 lines do not fit in a byte, so the real chip counts 0..$EA and then
	// starts again from $E5, which lands the last line on $FF. Without that, the
	// lines past 255 report 0..5 -- the same numbers as the top of the frame. A
	// game that waits for a particular line gets woken six lines early, once per
	// frame, and does its VDP work at the wrong moment. The writes all land;
	// they just land while the raster is somewhere it should not be, so the
	// picture decays as the game keeps playing rather than breaking outright.
	//
	// The dot counter does the same: in H40 it runs $00..$B6 then $E4..$FF, and
	// in H32 $00..$93 then $E9..$FF.
	wire [9:0] vc_adj = (vc <= 10'd234) ? vc : (vc - 10'd6);
	wire [9:0] hc_raw = {1'b0, hc[9:1]};
	wire [9:0] hc_adj = h40 ? ((hc_raw <= 10'd182) ? hc_raw : hc_raw + 10'd45)
	                        : ((hc_raw <= 10'd147) ? hc_raw : hc_raw + 10'd85);
	assign hv_count = {vc_adj[7:0], hc_adj[7:0]};
	assign h40_out  = h40;
	assign pixel_en = (hc < h_active) && (vc < v_active);

	// The two blanking flags are just where the beam is, so they are read off the
	// counters rather than kept. A game polls these when it does not want to be
	// interrupted, and they have to be true for the whole of each interval.
	wire vblank_flag = (vc >= v_active);
	wire hblank_flag = (hc >= h_active);

	// VBlank is level 6 and the line counter level 4, and each is only offered if
	// its own enable bit says so -- a pending interrupt that is not enabled still
	// sets its status bit, which is how a game that polls instead of using
	// interrupts finds out about it.
	wire [2:0] int_level = (vint_pending && r[1][5]) ? 3'd6
	                     : (hint_pending && r[0][4]) ? 3'd4 : 3'd0;
	assign ipl_n = ~int_level;

	// --- the line counter ---------------------------------------------------------------
	// Reloaded from register 10 outside the picture and counted down once per
	// active line. It fires when it would go past zero, not when it reaches it --
	// so a register of 0 interrupts on every line and a register of 1 on every
	// other one.
	reg [7:0] hcnt;

	// Bit 9 is "the write FIFO is empty", which is true whenever nothing is
	// queued -- and nothing is queued until there is a FIFO to queue it in.
	wire [15:0] status = {6'b001101, 1'b1, 1'b0,
	                      vint_pending, spr_overflow, spr_collide, odd_frame,
	                      vblank_flag, hblank_flag, dma_busy, is_pal};

	// Reading the status clears the VBlank flag, and so does the 68000 taking the
	// interrupt. Both, because a game may do either: poll it, or let the handler
	// run and never look.
	wire status_read = cpu_sel && cpu_ctrl && !cpu_wr;


	// --- the renderer's own way into VRAM -------------------------------------------------
	// A second port, so nothing here ever waits for the CPU or stalls it.
	//
	// The read is gated by `ce` as well, and that is not tidiness: without it the
	// memory answers on every clock while the schedule below counts in pixel
	// slots, so the data turns up a slot early and every capture takes the
	// previous fetch's answer. With it, the latency is exactly one slot whatever
	// the ratio between the clock and the pixel rate happens to be.
	reg  [14:0] r_addr;
	reg  [15:0] r_data;
	// (the port itself is below the sprite engine's address: it reads on every clock,
	// for the planes on a ce clock and for the sprite engine on the others)

	// --- which cell is being fetched ---------------------------------------------------------
	// Always the one eight pixels ahead of the one being shown, which at the end
	// of a line means the first cell of the NEXT line. Priming that is the whole
	// reason for the wrap below: without it the leftmost cell of every line is
	// drawn with whatever the right-hand edge left behind.
	//
	// It is LATCHED, once per group of eight, rather than recomputed from the
	// counter in every slot. With no scrolling the two are the same thing, which
	// is exactly why the difference is easy to miss: as soon as a plane is
	// scrolled by something that is not a multiple of eight, a live value crosses
	// a cell boundary halfway through fetching the cell, and the name entry and
	// the pattern come from two different places.
	// Sixteen pixels ahead, not eight. A scroll that is not a multiple of eight
	// means the eight pixels of a display cell come from two different plane
	// cells, so BOTH have to be in hand before the cell starts -- and the second
	// of them cannot be fetched during the cell that needs it.
	wire [9:0] nxt_raw  = hc + 10'd17;
	wire       nxt_wrap = nxt_raw >= h_total;
	wire [9:0] nxt_x    = nxt_wrap ? (nxt_raw - h_total) : nxt_raw;
	wire [9:0] nxt_line = nxt_wrap ? next_line : vc;

	reg [9:0] fbase;                 // screen x of the cell being fetched
	reg [9:0] fline;                 // and which line it is on

	// Which pixel of the cell is being SHOWN. This one is just the low bits of
	// the counter, because the picture starts at hc = 0 and cells follow from
	// there.
	wire [2:0] slot = hc[2:0];

	// Which step of the FETCH is running, which is not the same thing. A line is
	// 420 cycles in H40 and 342 in H32, and neither is a multiple of eight -- so
	// the groups of eight that fetch the leftmost cells of the next line, during
	// this line's blanking, do not line up with hc[2:0] at all.
	//
	// SIXTEEN cycles before the line ends, not eight: with two cells in flight,
	// the two last groups of the line both have to be aligned, because they
	// fetch the two cells the first display cell of the next line is made of.
	reg [2:0] fslot;

	// --- scrolling ---------------------------------------------------------------------------
	// Horizontal comes out of a table in VRAM, one longword per entry: plane A in
	// the first word, plane B in the second. Which entry depends on the mode --
	// one for the whole screen, one per eight lines, or one per line.
	reg [9:0] hs_a, hs_b;
	// The table holds one longword per entry -- two words -- so a per-line index
	// is the line doubled, and a per-cell one is the line's top five bits
	// doubled after being multiplied by the eight lines they cover.
	wire [14:0] hs_off =
		(hscroll_mode == 2'b00) ? 15'd0 :
		(hscroll_mode == 2'b10) ? {6'd0, next_line[7:3], 4'd0} :
		                          {6'd0, next_line[7:0], 1'b0};

	// Vertical comes out of VSRAM, either one value for the whole screen or one
	// per two-cell column. The column is the one being FETCHED.
	wire [4:0]  vs_col = fbase[8:4];
	wire [10:0] vs_a   = vscroll_col ? vsram[{vs_col, 1'b0}] : vsram[0];
	wire [10:0] vs_b   = vscroll_col ? vsram[{vs_col, 1'b1}] : vsram[1];

	// --- where in each plane the fetched cell sits --------------------------------------------
	// Horizontal scroll SUBTRACTS: a positive value slides the plane to the
	// right, so the part of it under a given pixel is further to the left.
	wire [10:0] xa = {1'b0, fbase} - {1'b0, hs_a};
	wire [10:0] xb = {1'b0, fbase} - {1'b0, hs_b};
	wire [10:0] ya = {1'b0, fline} + {1'b0, vs_a[9:0]};
	wire [10:0] yb = {1'b0, fline} + {1'b0, vs_b[9:0]};

	wire [7:0] cell_xa = xa[10:3] & pw_mask;
	wire [7:0] cell_xb = xb[10:3] & pw_mask;
	wire [7:0] cell_ya = ya[10:3] & ph_mask;
	wire [7:0] cell_yb = yb[10:3] & ph_mask;

	// The name table is row-major, one word per cell.
	wire [14:0] name_a_addr = nt_a_base + cell_ya * pw + {7'd0, cell_xa};
	wire [14:0] name_b_addr = nt_b_base + cell_yb * pw + {7'd0, cell_xb};

	// Where the cell being fetched sits ON THE SCREEN, which is what the window
	// is measured against -- it is the one thing here that does not care where
	// the planes have been scrolled to.
	wire [5:0] scell_x = fbase[8:3];
	wire [5:0] scell_y = fline[8:3];
	wire in_window = (win_right ? (scell_x >= win_hpos) : (scell_x < win_hpos))
	              || (win_down  ? (scell_y >= win_vpos) : (scell_y < win_vpos));

	wire [7:0]  win_w = h40 ? 8'd64 : 8'd32;
	wire [14:0] name_w_addr = win_base + {9'd0, scell_y} * {7'd0, win_w}
	                        + {9'd0, scell_x};

	// Plane A's fetch takes its name entry and its row from the window instead,
	// where there is one.
	wire [14:0] a_name_addr = in_window ? name_w_addr : name_a_addr;
	wire [10:0] a_row       = in_window ? {1'b0, fline} : ya;

	// A pattern is sixteen words, two to a row. Vertical flip counts the row from
	// the other end. Taking the name entry as an argument rather than off a
	// register lets the address be formed in the same slot the entry arrives in.
	function [14:0] pat_addr;
		input [15:0] name;
		input [10:0] y;
		reg   [2:0]  rowsel;
		begin
			rowsel   = name[12] ? ~y[2:0] : y[2:0];
			pat_addr = {name[10:0], 4'd0} + {11'd0, rowsel, 1'b0};
		end
	endfunction

	reg [15:0] name_a, name_b;
	reg [15:0] pat_hi;
	reg [31:0] row_a_fetch;          // plane A's row, assembled two slots early

	// Two cells of each plane, and the name entry that goes with each. `cur` is
	// the one the display cell starts in and `nxt` the one it runs into.
	reg [31:0] row_a_cur, row_a_nxt;
	reg [31:0] row_b_cur, row_b_nxt;
	reg [15:0] attr_a_cur, attr_a_nxt;
	reg [15:0] attr_b_cur, attr_b_nxt;
	reg        win_cur, win_nxt;

	// --- sprites -----------------------------------------------------------------------
	// The attribute table is a LINKED LIST, not an array: each entry names the
	// index of the next, and the list ends at a link of zero. A game reorders its
	// sprites by rewriting links rather than by moving them, and that order is
	// also the priority order -- the first sprite in the list wins where two
	// overlap.
	//
	//   word 0  Y position, 10 bits. 128 is the top of the picture.
	//   word 1  [11:10] width in cells minus one, [9:8] height minus one,
	//           [6:0] the link
	//   word 2  priority, palette, flips and a tile index, exactly as a plane
	//           cell carries them
	//   word 3  X position, 9 bits. 128 is the left edge.
	//
	// Tiles within a multi-cell sprite run down each COLUMN before moving to the
	// next, which is the opposite of what a plane does and is the single easiest
	// thing here to get backwards.
	// The table sits on a $200 byte boundary, so the register holds bits 15 to 9
	// of its address -- which in words, the way VRAM is indexed here, is a shift
	// of eight and not of seven.
	wire [14:0] sat_base = {r[5][6:0], 8'd0};

	// --- the line buffer ----------------------------------------------------------------------
	// Two of them, and which is which swaps every line: one is read out as this
	// line is drawn, the other is filled for the next. Two separate arrays rather
	// than one with a bank bit, because the read side EMPTIES each slot as it
	// passes -- so in any cycle one array is being cleared and the other written,
	// and a single array would need two write ports to manage it.
	//
	// Each array gets ONE write port, with its address and data muxed below. That
	// is not tidiness either: written as two separate conditional writes, the
	// synthesiser cannot prove they never happen at once and builds the whole
	// thing out of flip-flops -- seven thousand of them, for something that
	// should be a few hundred LUTs of distributed memory.
	//
	// Seven bits each: a priority bit, two of palette and four of colour.
	reg [6:0] sba [0:511];
	reg [6:0] sbb [0:511];

	wire rbank = vc[0];             // the line being shown
	wire wbank = ~vc[0];            // the line being prepared

	wire [6:0] sb_q = rbank ? sbb[hc[8:0]] : sba[hc[8:0]];

	wire [3:0] pix_s = sb_q[3:0];
	wire       op_s  = (pix_s != 4'd0);   // colour 0 is transparent here too
	wire [5:0] col_s = sb_q[5:0];
	wire       pr_s  = sb_q[6];

	// --- picking a pixel out of a row -----------------------------------------------------------
	// Four bits each, leftmost in the top nibble. A flipped cell is read from the
	// other end rather than reversed on the way in, which costs nothing.
	function [3:0] nib;
		input [31:0] row;
		input [2:0]  n;
		input        flip;
		reg   [2:0]  k;
		begin
			k   = flip ? n : ~n;
			nib = row[{k, 2'd0} +: 4];
		end
	endfunction

	// Where in the pair of cells this pixel falls. A display cell starts at a
	// multiple of eight, so the offset into the plane is simply the scroll's low
	// three bits counted backwards -- and once the sum passes eight, the pixel
	// belongs to the next cell, with the next cell's palette and flip.
	// A window cell does not scroll, so its eight pixels come entirely from
	// itself. At the boundary between the window and a finely scrolled plane A
	// this leaves a seam -- which is exactly the seam the real part has, and
	// which is why games put the window where the background is quiet.
	wire [2:0] fa = win_cur ? 3'd0 : (3'd0 - hs_a[2:0]);
	wire [2:0] fb = 3'd0 - hs_b[2:0];
	wire [3:0] ia = {1'b0, fa} + {1'b0, slot};
	wire [3:0] ib = {1'b0, fb} + {1'b0, slot};

	wire [15:0] at_a = ia[3] ? attr_a_nxt : attr_a_cur;
	wire [15:0] at_b = ib[3] ? attr_b_nxt : attr_b_cur;
	wire [31:0] rw_a = ia[3] ? row_a_nxt  : row_a_cur;
	wire [31:0] rw_b = ib[3] ? row_b_nxt  : row_b_cur;

	wire [3:0] pix_a = nib(rw_a, ia[2:0], at_a[11]);
	wire [3:0] pix_b = nib(rw_b, ib[2:0], at_b[11]);
	wire       op_a  = (pix_a != 4'd0);     // colour 0 is transparent, always
	wire       op_b  = (pix_b != 4'd0);

	// A cell's priority bit does not put a whole plane in front of another: a
	// high-priority cell of B beats a low-priority cell of A. Two planes, four
	// layers.
	wire [5:0] col_a = {at_a[14:13], pix_a};
	wire [5:0] col_b = {at_b[14:13], pix_b};

	// Six layers out of three, because each carries its own priority bit: every
	// high-priority layer in order, and then every low-priority one.
	wire [5:0] picked =
		(op_s && pr_s)     ? col_s :
		(op_a && at_a[15]) ? col_a :
		(op_b && at_b[15]) ? col_b :
		 op_s              ? col_s :
		 op_a              ? col_a :
		 op_b              ? col_b : backdrop;

	assign color_ix = (pixel_en && disp_en) ? picked : backdrop;
	assign color    = cram[color_ix];

	// --- decoding an access -------------------------------------------------------------
	// The low four bits of the code say which memory; the upper two say whether
	// this is a DMA, which nothing here acts on yet.
	localparam CD_VRAM_RD  = 4'b0000,
	           CD_VRAM_WR  = 4'b0001,
	           CD_CRAM_WR  = 4'b0011,
	           CD_VSRAM_RD = 4'b0100,
	           CD_VSRAM_WR = 4'b0101,
	           CD_CRAM_RD  = 4'b1000;

	wire [14:0] vaddr = addr[15:1];
	wire [5:0]  caddr = addr[6:1];
	wire [5:0]  saddr = addr[6:1];

	// A VRAM word written through the data port has its bytes SWAPPED when the
	// address is odd. Real games rely on it -- it is how a byte write to an odd
	// address lands in the right half.
	wire [15:0] vdata = addr[0] ? {cpu_din[7:0], cpu_din[15:8]} : cpu_din;

	// Port A of the VRAM. Both the CPU and the DMA go through it, because there
	// are two ports and the renderer has the other -- and because a running DMA
	// stops the CPU anyway, so they are never both asking.
	//
	// The write enables are per BYTE. A fill and a copy each move one byte at a
	// time to an address that may be odd, and a word-wide write would take the
	// neighbouring byte with it.
	wire cpu_data = cpu_sel && !cpu_ctrl;
	wire cpu_vwr  = cpu_data && cpu_wr && (code[3:0] == CD_VRAM_WR) && !dma_active;

	// A copy presents its SOURCE for two cycles and its destination on the third.
	wire dma_reading = (dma_mode == 2'b11) && (dma_st != 2'd2);

	wire [15:0] dma_vdata =
		(dma_mode == 2'b10) ? {dma_fill[15:8], dma_fill[15:8]} :
		(dma_mode == 2'b11) ? {dma_byte, dma_byte} :
		addr[0] ? {dma_din[7:0], dma_din[15:8]} : dma_din;

	// The word-at-a-time kind writes when its word arrives; the two byte-at-a-time
	// kinds write every pass.
	wire dma_wr_word = dma_active && !dma_mode[1] && dma_ack
	                   && (code[3:0] == CD_VRAM_WR);
	wire dma_wr_byte = dma_active && ((dma_mode == 2'b10)
	                                || (dma_mode == 2'b11 && dma_st == 2'd2));

	wire [14:0] pa_addr = dma_reading ? dma_sa[15:1]
	                    : dma_active  ? addr[15:1] : vaddr;
	wire [15:0] pa_data = dma_active ? dma_vdata : vdata;
	wire        pa_hi   = dma_active ? (dma_wr_word || (dma_wr_byte && !addr[0]))
	                                 : cpu_vwr;
	wire        pa_lo   = dma_active ? (dma_wr_word || (dma_wr_byte &&  addr[0]))
	                                 : cpu_vwr;
	wire        pa_en   = dma_active ? 1'b1 : cpu_data;

	// --- the sprite attribute cache ------------------------------------------------------------
	// As the real chip has: the first two words of each of the 80 entries -- Y, then size
	// and link -- kept inside, updated by every VRAM write that lands on them (by the CPU
	// or by DMA, a byte at a time as the write is), so walking the list costs a clock an
	// entry and no VRAM at all. (Moving the table with register 5 leaves the cache as it
	// was until those words are written again -- which is the real chip's behaviour too.)
	wire [14:0] sat_off = pa_addr - sat_base;
	wire        sat_hit = sat_off < 15'd320 && !sat_off[1];
	wire [6:0]  sat_ent = sat_off[8:2];
	reg  [7:0]  satc_y_lo [0:127];  reg [1:0] satc_y_hi [0:127];
	reg  [7:0]  satc_s_lo [0:127];  reg [7:0] satc_s_hi [0:127];
	always @(posedge clk) if (sat_hit) begin
		if (!sat_off[0]) begin
			if (pa_hi) satc_y_hi[sat_ent] <= pa_data[9:8];
			if (pa_lo) satc_y_lo[sat_ent] <= pa_data[7:0];
		end else begin
			if (pa_hi) satc_s_hi[sat_ent] <= pa_data[15:8];
			if (pa_lo) satc_s_lo[sat_ent] <= pa_data[7:0];
		end
	end

	reg  [15:0] cpu_q;
	always @(posedge clk) begin
		if (pa_hi) vram[pa_addr][15:8] <= pa_data[15:8];
		if (pa_lo) vram[pa_addr][7:0]  <= pa_data[7:0];
		// Gated, because the address auto-increments the moment an access is
		// over: an ungated read would immediately replace the answer with
		// whatever the NEXT location happens to hold.
		if (pa_en) cpu_q <= vram[pa_addr];
	end

	assign dma_req  = dma_active && !dma_mode[1];
	assign dma_addr = dma_sa;

	// Everything that is not VRAM answers out of a register; VRAM answers out of
	// its own port, a cycle later, which is what the read latch below remembers.
	reg [15:0] cpu_reg_out;
	reg        vram_reading;
	assign cpu_dout = vram_reading ? cpu_q : cpu_reg_out;

	// --- the sprite engine ---------------------------------------------------------------------
	// It runs through the whole of one line, filling the buffer for the NEXT one.
	// Reads of VRAM only happen in the slots the plane fetch leaves free -- two
	// in every eight while the picture is drawn, and nearly all of them during
	// the blanking -- so the machine ASKS for a slot and waits rather than
	// assuming it can read whenever it likes. The address register belongs to the
	// fetch schedule below; this drives a request into it.
	localparam SP_IDLE = 4'd0,  SP_RD0  = 4'd1,  SP_GET0 = 4'd2,
	           SP_RD1  = 4'd3,  SP_GET1 = 4'd4,  SP_TEST = 4'd5,
	           SP_RD2  = 4'd6,  SP_GET2 = 4'd7,  SP_RD3  = 4'd8,
	           SP_GET3 = 4'd9,  SP_COL  = 4'd10, SP_PAT  = 4'd11,
	           SP_GETP = 4'd12, SP_PIX  = 4'd13, SP_NEXT = 4'd14;

	reg [3:0]  sp_st;
	// The address is taken up the cycle after the slot is granted and the word
	// arrives the cycle after that, so the capture happens two cycles after the
	// grant -- which is one cycle of waiting. Waiting two lands a cycle late, and
	// by then the plane fetch has put its own answer on the bus. That is
	// invisible during the blanking, where nothing else is reading, and wrong
	// everywhere else.
	reg [6:0]  sp_ix;               // which sprite in the list
	reg [6:0]  sp_seen;
	reg [4:0]  sp_online;
	reg [9:0]  sp_budget;           // pixels left to spend on this line
	reg [9:0]  sp_y;
	reg [15:0] sp_sz;
	reg [15:0] sp_at;
	reg [11:0] sp_px;               // where this column's eight pixels start
	reg [1:0]  sp_col;
	reg [4:0]  sp_row;              // the row of the whole sprite this line wants
	reg [15:0] sp_word;
	reg        sp_half;
	reg [1:0]  sp_k;                // which of the four pixels in the word
	reg [14:0] sp_addr;
	reg        sp_rd;

	wire [1:0] sp_w    = sp_sz[11:10];
	wire [1:0] sp_h    = sp_sz[9:8];
	wire [6:0] sp_link = sp_sz[6:0];

	// A sprite covers this line if the line falls inside its height. Positions
	// are offset by 128, which is how a sprite is moved off the top of the screen
	// without its coordinate having to go negative.
	wire [9:0] sp_dy    = next_line + 10'd128 - sp_y;
	wire       sp_onrow = (sp_dy < ({6'd0, sp_h, 3'd0} + 10'd8));

	// The render port reads on every clock: on a ce clock for the planes (and the
	// horizontal scroll) as the schedule below has it -- their word is held in r_data
	// until their next read, so they see it exactly a slot later as they always did --
	// and on the three clocks between for the sprite engine, which runs on every clock.
	// It used to share the planes' ce clocks, taking the slots they left free, and
	// walking the list one pixel at a time: a long list ran out of line before its
	// end, and what was left was not drawn -- the eyes and mouths of a game's
	// character screens, extra sprites late in the list, vanished for frames.
	reg  [15:0] vq;  reg vq_ce;
	always @(posedge clk) begin
		vq    <= vram[ce ? r_addr : sp_addr];
		vq_ce <= ce;
		if (vq_ce) r_data <= vq;
	end

	// The per-line limits the real part has, and the reason a Mega Drive game
	// flickers its sprites when it is asked for too many.
	wire [4:0] sp_max = h40 ? 5'd20 : 5'd16;

	// The column and row actually fetched, once the flips have had their say. A
	// horizontal flip reverses which COLUMN as well as the pixels within it, and
	// a vertical one counts rows from the far end of the whole sprite rather than
	// of one cell.
	wire [1:0] eff_col = sp_at[11] ? (sp_w - sp_col) : sp_col;
	wire [4:0] eff_row = sp_at[12] ? ({3'd0, sp_h, 3'b111} - sp_row) : sp_row;
	wire       eff_half = sp_at[11] ? ~sp_half : sp_half;

	// tile = base + column * height + the cell row within the column
	wire [14:0] sp_tile = {sp_at[10:0], 4'd0}
	                    + ({13'd0, eff_col} * ({13'd0, sp_h} + 15'd1)
	                       + {12'd0, eff_row[4:3]}) * 15'd16;
	wire [14:0] sp_pat  = sp_tile + {11'd0, eff_row[2:0], 1'b0} + {14'd0, eff_half};

	// One pixel per cycle out of the four in the fetched word.
	wire [3:0] sp_nib = sp_at[11] ? sp_word[{sp_k, 2'd0} +: 4]
	                              : sp_word[{~sp_k, 2'd0} +: 4];
	wire [11:0] sp_dx = sp_px + {9'd0, sp_half, 2'd0} + {10'd0, sp_k};
	wire        sp_on = !sp_dx[11] && (sp_dx < {2'd0, h_active});

	// The first sprite to reach a slot keeps it, which is what turns the list's
	// order into the priority order. So a write only happens where nothing is.
	wire [6:0] sb_cur = wbank ? sbb[sp_dx[8:0]] : sba[sp_dx[8:0]];
	wire       sp_wr  = (sp_st == SP_PIX) && sp_on && (sp_nib != 4'd0)
	                    && (sb_cur[3:0] == 4'd0);

	// Emptying happens on the way out: the slot just read is cleared, so the
	// buffer is ready to be filled again with no pass of its own. Whichever array
	// is being read is the one being cleared, and the other is the one being
	// filled -- so neither ever has to do both.
	wire       sb_clr  = (hc < h_active);
	wire [6:0] sb_fill = {sp_at[15], sp_at[14:13], sp_nib};

	wire       a_clr = sb_clr && !rbank && ce;
	wire       a_we  = a_clr || (sp_wr && !wbank);
	wire [8:0] a_wa  = a_clr ? hc[8:0] : sp_dx[8:0];
	wire [6:0] a_wd  = a_clr ? 7'd0    : sb_fill;

	wire       b_clr = sb_clr && rbank && ce;
	wire       b_we  = b_clr || (sp_wr && wbank);
	wire [8:0] b_wa  = b_clr ? hc[8:0] : sp_dx[8:0];
	wire [6:0] b_wd  = b_clr ? 7'd0    : sb_fill;

	always @(posedge clk) begin
		if (a_we) sba[a_wa] <= a_wd;
		if (b_we) sbb[b_wa] <= b_wd;
	end

	integer i;

	always @(posedge clk) begin
		if (rst) begin
			sp_st     <= SP_IDLE;
			sp_ix     <= 7'd0;
			sp_seen   <= 7'd0;
			sp_online <= 5'd0;
			sp_budget <= 10'd0;
			sp_col    <= 2'd0;
			sp_half   <= 1'b0;
			sp_k      <= 2'd0;
			sp_rd     <= 1'b0;
			sp_addr   <= 15'd0;
			spr_overflow <= 1'b0;
		end else begin
			if (status_read) spr_overflow <= 1'b0;

			begin
				if (ce && line_end) begin
					// Start again for the next line, whatever the last pass got to.
					sp_st     <= SP_RD0;
					sp_ix     <= 7'd0;
					sp_seen   <= 7'd0;
					sp_online <= 5'd0;
					sp_budget <= h_active;
					sp_rd     <= 1'b0;
				end else case (sp_st)
				// Y and size/link out of the cache: a clock an entry
				SP_RD0: begin
						sp_y  <= {satc_y_hi[sp_ix], satc_y_lo[sp_ix]};
						sp_sz <= {satc_s_hi[sp_ix], satc_s_lo[sp_ix]};
						sp_st <= SP_TEST;
					end

				SP_TEST: begin
						sp_seen <= sp_seen + 7'd1;
						if (sp_online >= sp_max) begin
							spr_overflow <= 1'b1;
							sp_st        <= SP_IDLE;
						end else if (sp_onrow) begin
							sp_row <= sp_dy[4:0];
							sp_st  <= SP_RD2;
						end else
							sp_st <= SP_NEXT;
					end

				SP_RD2: if (!sp_rd) begin
						sp_addr <= sat_base + {5'd0, sp_ix, 2'd0} + 15'd2;
						sp_rd   <= 1'b1;
					end else if (!ce) begin
						sp_rd <= 1'b0;
						sp_st <= SP_GET2;
					end
				SP_GET2: begin sp_at <= vq; sp_st <= SP_RD3; end

				SP_RD3: if (!sp_rd) begin
						sp_addr <= sat_base + {5'd0, sp_ix, 2'd0} + 15'd3;
						sp_rd   <= 1'b1;
					end else if (!ce) begin
						sp_rd <= 1'b0;
						sp_st <= SP_GET3;
					end
				SP_GET3: begin
						// The position is offset by 128 the same way Y is.
						sp_px     <= {2'd0, vq[9:0]} - 12'd128;
						sp_col    <= 2'd0;
						sp_half   <= 1'b0;
						sp_online <= sp_online + 5'd1;
						sp_st     <= SP_COL;
					end

				SP_COL: begin
						sp_half <= 1'b0;
						sp_st   <= SP_PAT;
					end

				SP_PAT: if (!sp_rd) begin
						sp_addr <= sp_pat;
						sp_rd   <= 1'b1;
					end else if (!ce) begin
						sp_rd <= 1'b0;
						sp_st <= SP_GETP;
					end
				SP_GETP: begin
						sp_word <= vq;
						sp_k    <= 2'd0;
						sp_st   <= SP_PIX;
					end

				SP_PIX: begin
						sp_budget <= (sp_budget == 10'd0) ? 10'd0
						                                  : sp_budget - 10'd1;
						if (sp_budget == 10'd0) begin
							// Out of pixels for this line, which is exactly what
							// the overflow flag is for.
							spr_overflow <= 1'b1;
							sp_st        <= SP_IDLE;
						end else if (sp_k == 2'd3) begin
							if (sp_half) begin
								// The eight pixels of this column are done.
								if (sp_col == sp_w) sp_st <= SP_NEXT;
								else begin
									sp_col <= sp_col + 2'd1;
									sp_px  <= sp_px + 12'd8;
									sp_st  <= SP_COL;
								end
							end else begin
								sp_half <= 1'b1;
								sp_st   <= SP_PAT;
							end
						end else
							sp_k <= sp_k + 2'd1;
					end

				SP_NEXT: begin
						// The list ends at a link of zero, and cannot be longer
						// than the table. Either way the pass is over.
						if (sp_link == 7'd0 || sp_seen >= 7'd80) sp_st <= SP_IDLE;
						else begin
							sp_ix <= sp_link;
							sp_st <= SP_RD0;
						end
					end

				default: ;
				endcase
			end
		end
	end

	// --- the timing and the fetch schedule ------------------------------------------------
	// Six reads in eight slots, two planes' worth. Each address is presented two
	// slots before the data it fetches is used.
	always @(posedge clk) begin
		if (rst) begin
			hc     <= 10'd0;
			vc     <= 10'd0;
			hcnt   <= 8'd0;
			vint_pending <= 1'b0; zint <= 1'b0;
			hint_pending <= 1'b0;
			fslot  <= 3'd0;
			fbase  <= 10'd0;
			fline  <= 10'd0;
			hs_a   <= 10'd0;
			hs_b   <= 10'd0;
			win_cur   <= 1'b0;
			win_nxt   <= 1'b0;
			row_a_cur <= 32'd0;
			row_a_nxt <= 32'd0;
			row_b_cur <= 32'd0;
			row_b_nxt <= 32'd0;
			row_a_fetch <= 32'd0;
			attr_a_cur <= 16'd0;
			attr_a_nxt <= 16'd0;
			attr_b_cur <= 16'd0;
			attr_b_nxt <= 16'd0;
			name_a <= 16'd0;
			name_b <= 16'd0;
			pat_hi <= 16'd0;
			r_addr <= 15'd0;
		end else if (ce) begin
			if (line_end) begin
				hc <= 10'd0;
				vc <= frame_end ? 10'd0 : vc + 10'd1;
			end else begin
				hc <= hc + 10'd1;
			end

			// The group restarts here, and the cell it is about to fetch is
			// fixed at the same moment.
			if (hc == h_total - 10'd17) fslot <= 3'd0;
			else                        fslot <= fslot + 3'd1;

			if (fslot == 3'd7 || hc == h_total - 10'd17) begin
				fbase <= nxt_x;
				fline <= nxt_line;
			end

			// An address assigned in slot k is presented during slot k+1 and its
			// data captured in slot k+2.
			case (fslot)
			3'd0: r_addr <= a_name_addr;
			3'd1: r_addr <= name_b_addr;
			// The name entry arrives and is turned straight into the address of
			// its own pattern, in the same slot.
			3'd2: begin name_a <= r_data; r_addr <= pat_addr(r_data, a_row); end
			3'd3: begin name_b <= r_data;
			            r_addr <= pat_addr(name_a, a_row) + 15'd1; end
			3'd4: begin pat_hi <= r_data; r_addr <= pat_addr(name_b, yb); end
			3'd5: begin row_a_fetch <= {pat_hi, r_data};
			            r_addr <= pat_addr(name_b, yb) + 15'd1; end
			3'd6: pat_hi <= r_data;
			// Everything moves along one place at once. Loading a row earlier
			// would replace it halfway through the cell being shown; loading the
			// attributes later would draw a row in the previous cell's palette.
			3'd7: begin
					row_a_cur  <= row_a_nxt;
					row_a_nxt  <= row_a_fetch;
					row_b_cur  <= row_b_nxt;
					row_b_nxt  <= {pat_hi, r_data};
					attr_a_cur <= attr_a_nxt;
					attr_a_nxt <= name_a;
					win_cur    <= win_nxt;
					win_nxt    <= in_window;
					attr_b_cur <= attr_b_nxt;
					attr_b_nxt <= name_b;
				end
			endcase

			// The horizontal scroll for the NEXT line is read during this line's
			// blanking, where there is nothing else for the port to do. It
			// overrides the schedule above, which at this point is fetching cells
			// nobody will ever see.
			if (hc == h_active + 10'd2)      r_addr <= hs_base + hs_off;
			else if (hc == h_active + 10'd3) r_addr <= hs_base + hs_off + 15'd1;
			else if (hc == h_active + 10'd4) hs_a <= r_data[9:0];
			else if (hc == h_active + 10'd5) hs_b <= r_data[9:0];

			// --- the two interrupts, both decided at the end of a line ----------
			if (line_end) begin
				if (vc < v_active) begin
					if (hcnt == 8'd0) begin
						hint_pending <= 1'b1;
						hcnt         <= r[10];
					end else
						hcnt <= hcnt - 8'd1;
				end else begin
					// Held reloaded through the whole of the blanking, so the
					// first line of the picture always gets a full count.
					hcnt <= r[10];
				end

				// The VBlank interrupt happens once, as the picture ends. The Z80 has
				// one too, at the same moment, held for a line (it is a level, and
				// unlike the 68000's nothing acknowledges it).
				if (next_line == v_active) vint_pending <= 1'b1;
				zint <= (next_line == v_active);
			end
		end

		// Acknowledging is not gated by the pixel enable: the CPU runs on its own
		// clock and its accesses do not line up with pixels.
		if (!rst) begin
			if (status_read) vint_pending <= 1'b0;
			if (int_ack) begin
				if (int_level == 3'd6)      vint_pending <= 1'b0;
				else if (int_level == 3'd4) hint_pending <= 1'b0;
			end
		end
	end

	// --- the CPU side -----------------------------------------------------------------------
	always @(posedge clk) begin
		if (rst) begin
			addr    <= 17'd0;
			code    <= 6'd0;
			pending <= 1'b0;
			for (i = 0; i < 24; i = i + 1) r[i] <= 8'd0;
			// The auto-increment powers up at 2, which is what a program that
			// forgets to set it is relying on.
			r[15]        <= 8'd2;
			cpu_reg_out  <= 16'd0;
			vram_reading <= 1'b0;
			odd_frame    <= 1'b0;
			dma_active   <= 1'b0;
			dma_armed    <= 1'b0;
			dma_mode     <= 2'd0;
			dma_st       <= 2'd0;
			dma_len      <= 17'd0;
			dma_sa       <= 23'd0;
			dma_fill     <= 16'd0;
			dma_byte     <= 8'd0;
			spr_collide  <= 1'b0;
		end else if (dma_active) begin
			// While this runs the CPU is stopped, which is what the busy bit in
			// the status word is telling a game that bothers to look.
			case (dma_mode)
			2'b10: begin                            // fill
				addr <= addr + {9'd0, inc};
				if (dma_len == 17'd1) dma_active <= 1'b0;
				dma_len <= dma_len - 17'd1;
			end
			2'b11: case (dma_st)                    // VRAM to VRAM
				// The source address is presented in one cycle and the word
				// arrives in the next, so reading a byte takes two -- and then
				// writing it takes a third.
				2'd0: dma_st <= 2'd1;
				2'd1: begin
						dma_byte <= dma_sa[0] ? cpu_q[7:0] : cpu_q[15:8];
						dma_st   <= 2'd2;
					end
				default: begin
						addr   <= addr + {9'd0, inc};
						dma_sa <= dma_sa + 23'd1;
						dma_st <= 2'd0;
						if (dma_len == 17'd1) dma_active <= 1'b0;
						dma_len <= dma_len - 17'd1;
					end
				endcase
			default: if (dma_ack) begin             // from the 68000's memory
				// VRAM is written by port A above; the other two destinations
				// are written here, so that one engine serves all three.
				case (code[3:0])
				CD_CRAM_WR:  cram[caddr] <= {dma_din[11:9], dma_din[7:5],
				                             dma_din[3:1]};
				CD_VSRAM_WR: if (saddr < 6'd40) vsram[saddr] <= dma_din[10:0];
				default: ;
				endcase
				addr   <= addr + {9'd0, inc};
				dma_sa <= dma_sa + 23'd1;
				if (dma_len == 17'd1) dma_active <= 1'b0;
				dma_len <= dma_len - 17'd1;
			end
			endcase
		end else if (cpu_sel) begin
			if (cpu_ctrl) begin
				// --- the control port ---------------------------------------
				if (!cpu_wr) begin
					// Reading the status also abandons a half-written command.
					cpu_reg_out  <= status;
					vram_reading <= 1'b0;
					pending      <= 1'b0;
				end else if (!pending && cpu_din[15:14] == 2'b10) begin
					// A register write is ONE word and does not start a command,
					// which is why this test comes before the one below.
					if (cpu_din[12:8] < 5'd24) r[cpu_din[12:8]] <= cpu_din[7:0];
				end else if (!pending) begin
					addr[13:0] <= cpu_din[13:0];
					code[1:0]  <= cpu_din[15:14];
					pending    <= 1'b1;
				end else begin
					addr[16:14] <= cpu_din[2:0];
					code[5:2]   <= cpu_din[7:4];
					pending     <= 1'b0;

					// The second word is also what asks for a DMA, and the code
					// bit that says so only exists in this half. Register 1 has
					// to allow them at all, which is how a game disables them
					// without rewriting every command it issues.
					// CD5 is bit 7 of this word, not bit 5 -- the code's four
					// upper bits sit in bits 7 to 4, so the one that means "this
					// is a DMA" is the topmost of them.
					if (cpu_din[7] && r[1][4]) begin
						dma_mode <= r[23][7:6];
						dma_st   <= 2'd0;
						dma_sa   <= {r[23][6:0], r[22], r[21]};
						dma_len  <= ({r[20], r[19]} == 16'd0)
						            ? 17'h10000 : {1'b0, r[20], r[19]};
						// A fill waits for its value; the other two start now.
						if (r[23][7:6] == 2'b10) dma_armed  <= 1'b1;
						else                     dma_active <= 1'b1;
					end
				end
			end else begin
				// --- the data port ------------------------------------------
				// Either direction ends the same way: the address moves on by
				// whatever register 15 says, and a half-written command is
				// abandoned.
				pending <= 1'b0;
				addr    <= addr + {9'd0, inc};

				// The write that arms a fill is also an ordinary write, and it
				// happens at the address the command set. The fill proper starts
				// one increment further on.
				if (dma_armed && cpu_wr) begin
					dma_fill   <= cpu_din;
					dma_armed  <= 1'b0;
					dma_active <= 1'b1;
				end

				// VRAM itself is written and read by its own port above; what
				// happens here is everything else, plus remembering which of the
				// two answers a read should come from.
				vram_reading <= !cpu_wr && (code[3:0] == CD_VRAM_RD);

				if (cpu_wr) begin
					case (code[3:0])
					// A colour word is 0000 BBB0 GGG0 RRR0: three bits of
					// each, spread out with a gap below every one of them.
					CD_CRAM_WR:  cram[caddr]  <= {cpu_din[11:9], cpu_din[7:5],
					                              cpu_din[3:1]};
					CD_VSRAM_WR: if (saddr < 6'd40) vsram[saddr] <= cpu_din[10:0];
					default: ;
					endcase
				end else begin
					case (code[3:0])
					// A colour is nine bits spread across a sixteen-bit word
					// with gaps, and it reads back in the same shape it was
					// written -- the gaps are not zero, they are undefined, and
					// returning zero there is what every emulator does.
					CD_CRAM_RD:  cpu_reg_out <= {4'd0, cram[caddr][8:6], 1'b0,
					                             cram[caddr][5:3], 1'b0,
					                             cram[caddr][2:0], 1'b0};
					CD_VSRAM_RD: cpu_reg_out <= (saddr < 6'd40)
					                            ? {5'd0, vsram[saddr]} : 16'd0;
					default: cpu_reg_out <= 16'd0;
					endcase
				end
			end
		end
	end

endmodule

`default_nettype wire
