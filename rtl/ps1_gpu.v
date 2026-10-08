//////////////////////////////////////////////////////////////////////////////////
// ps1_gpu.v - the PlayStation's GPU, drawing into a megabyte of DDR3.
//
// VRAM is 1024 x 512 pixels of 16 bits, and it lives out in DDR3 behind a
// cache exactly like the CPU's: this module asks for halfwords at (x, y) and
// the cache turns them into lines. Drawing and display are two ports on that
// cache, so a scanline being shown and a triangle being drawn share the memory
// the way they do on the console.
//
// --- what it draws --------------------------------------------------------------------
//
// GP0, the drawing port, takes commands as words from the CPU or the DMA:
//
//   $02          fill a rectangle with one colour
//   $20-$3F      polygons: triangle or quad, flat or Gouraud, textured or not,
//                opaque or semi-transparent
//   $40-$5F      lines, flat or Gouraud
//   $60-$7F      rectangles, sized or 1/8/16 square, textured or not
//   $80          copy VRAM to VRAM
//   $A0 / $C0    CPU to VRAM / VRAM to CPU
//   $E1-$E6      the drawing environment: texture page, window, area, offset,
//                mask
//
// GP1 is the display side: reset, enable, DMA direction, where the picture is
// in VRAM and how big it is.
//
// --- how a triangle happens -----------------------------------------------------------
//
// Bounding box, edge functions, one pixel at a time. Colour and texture
// coordinates are interpolated by GRADIENTS worked out once per triangle --
// one division, done sequentially -- and then stepped by addition per pixel,
// which is what the real chip does and why its polygons look the way they do.
// A quad is two triangles, (0 1 2) and (1 2 3), also as the chip does it.
//
// Textured pixels look the texel up through the CLUT for 4- and 8-bit pages,
// read it directly for 15-bit, treat $0000 as transparent, and modulate by the
// vertex colour unless told not to. Semi-transparent pixels read what is there
// first and blend. All of that is a handful of cache accesses per pixel, which
// is slow, and enough: the BIOS draws a few hundred polygons a frame.
//
// --- the display ----------------------------------------------------------------------------
//
// Once per frame the active area is read out of VRAM and handed to the
// framebuffer as 320 x 240 RGB332, dropping columns when the mode is wider and
// halving the 24-bit modes' colour depth on the way. Timing runs free at 60 Hz
// from the system clock: VBlank goes to the interrupt controller and the
// counters, HBlank and the dot clock to the counters.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_gpu #(
	parameter CLK_HZ = 50_000_000    // (the raster's 60 Hz and the swap waits are worked out from it)
) (
	input  wire        clk,
	input  wire        rst,

	// --- registers: GP0 at +0, GP1 at +4; GPUREAD at +0, GPUSTAT at +4 ----------
	input  wire        sel,
	input  wire        we,
	input  wire        a4,          // address bit 2: 0 = GP0/GPUREAD, 1 = GP1/GPUSTAT
	input  wire        dma_active,  // the DMA's GPU channel is queued or running
	input  wire        cap_every_vsync,   // capture at each vertical sync, idle or not (the host's choice: rate over tearing)
	input  wire        gpu_fast,
	input  wire        no_tcache, no_ccache, no_trun,   // debug: bypass the texture and palette caches, and the offered runs          // 0: the console's drawing pace (see ps1_raster.v); 1: ours
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,

	// --- the DMA's way in and out ------------------------------------------------------
	input  wire        dma_wr,
	input  wire [31:0] dma_data,
	output wire        dma_ready,
	output wire        gp0_full,     // the CPU must wait before writing GP0
	input  wire        dma_rd,
	output reg  [31:0] dma_rdata,
	output reg         dma_rvalid,

	// --- VRAM, halfwords, through a cache: drawing --------------------------------------
	output wire [28:0] v_addr,
	output wire        v_req,
	output wire        v_we,
	output wire [3:0]  v_be,
	output wire [31:0] v_wdata,
	// A texel fetch is marked, so the cache reads around itself in a run of
	// lines instead of allocating one. Measured: 16,900 texel-line fetches a
	// frame at ~14 clocks each was 0.72 clocks on every pixel drawn, and the
	// lines it allocated pushed out framebuffer lines the engine was writing.
	// The next texel line along is then already in the prefetch run.
	output wire        v_around,
	output wire        v_lin,
	// the rest of a texel run, offered by the video cache a line at a time
	input  wire        tx_valid,
	input  wire [24:0] tx_addr,
	input  wire [127:0] tx_line,
	// A whole 16-byte line in one go: eight pixels of a flat span, which is what
	// a screen clear is made of. Measured on the board, the BIOS's 640x480 clear
	// took 19.75 ms at two pixels a clock -- 119% of a frame -- so the engine
	// could never finish one before the next vertical sync and was permanently
	// behind. Eight pixels a clock is what puts it back inside a frame.
	output reg         v_lwe,
	output reg  [127:0] v_wdata128,
	input  wire [31:0] v_rdata,
	input  wire [127:0] v_line,     // the whole 16 bytes that read came from
	input  wire        v_ack,

	// --- and display ------------------------------------------------------------------------
	output reg  [28:0] s_addr,
	output reg         s_req,
	input  wire [31:0] s_rdata,
	input  wire [127:0] s_line,   // the whole line that read came from
	input  wire        s_ack,

	// --- the picture, one pixel at a time, 320 x 240 ----------------------------------
	output reg         px_valid,
	output reg  [8:0]  px_x,
	output reg  [8:0]  px_y,
	output reg  [7:0]  px_rgb,

	// the same picture at full width in 15-bit colour, for a frame in DDR3
	output reg         fpx_valid,
	output reg  [9:0]  fpx_x,
	output reg  [8:0]  fpx_y,
	output reg  [15:0] fpx_rgb,
	output reg         scan_start,   // the scanout begins a frame
	output reg         scan_done,    // ...and when it has finished one
	output reg         scan_abort,   // ...or when it gave one up at a display flip
	// Capture at EVERY flip, and abandon a capture at every flip. For the
	// network's paced stream (fb_stream.v): a capture there reads the buffer on
	// screen while the network sends it, about 13 ms, well inside one of the
	// game's frames, and a flip in the middle means the game is about to draw
	// into what is being read. Clear, it is one flip in two, for the paths that
	// read a whole frame into a buffer first.
	input  wire        every_flip,
	output wire        scan_busy,    // a capture is running: it needs the memory more than the engine does
	input  wire        scan_hold,   // the frame writer is full: do not read more
	input  wire        scan_enable, // somebody wants the picture; otherwise VRAM is left alone

	// --- the picture, a whole VRAM line at a time -------------------------------
	// A line read out of VRAM is eight pixels of RGB555, and the frame kept in
	// DDR3 is the same eight pixels of RGB555 in the same order -- the identical
	// sixteen bytes. Taking them apart into eight pixels and putting them back
	// together cost 101,554 clocks a frame, measured, while the machine went on
	// redrawing the screen underneath. So when the frame writer is the one
	// taking the picture, the line is handed over whole.
	//
	// The BIOS runs a 640-wide display and the picture goes out at 320, so most
	// of the time every other pixel is dropped. That does not stop the line
	// route: two VRAM lines are sixteen source pixels and make one output line
	// of eight, and picking every other halfword out of them is a shuffle of
	// wires. Only the window's alignment matters -- it has to start on a line
	// boundary, or an output line would straddle two VRAM lines -- and if it
	// does not, the pixel path is used exactly as before.
	input  wire        scan_lines,  // the frame writer wants whole lines
	output reg         fl_valid,
	output reg [127:0] fl_data,
	output reg [9:0]   fl_x,
	output reg [8:0]   fl_y,
	output wire [9:0]  disp_w,      // how many VRAM columns the display shows
	output wire        disp_v480,   // ...and that it is 480 lines (interlaced): the capture has 480 rows
	output wire        cap_weave,   // this capture is one field of a 480i picture (fb_ddr weave)
	output wire        cap_field,   // ...and which: its rows are 2k + cap_field

	output reg         vblank,
	output reg         hblank,
	output reg         dot_ce,
	output reg         irq,         // GP0 $1F asks for one; almost nothing does
	// draw-engine state, for finding a command the engine gets stuck on
	output wire [31:0] dbg_gpu,
	output wire [31:0] dbg_gpu2,    // the last four command opcodes dispatched
	output wire        dbg_pop,       // the engine takes a word from the FIFO this cycle
	output wire        dbg_pophead,   // ...and it is the first word of a command
	// what goes IN: a GP0 word from the processor (type 0) or the DMA (1), or a GP1 write (2)
	output wire        dbg_in_v,
	output wire [1:0]  dbg_in_type,
	output wire [31:0] dbg_in_word,
	output wire [31:0] dbg_popword,
	output wire [31:0] dbg_disp,    // where the display points, and its mode
	output wire [31:0] dbg_draw,    // the drawing area and offset
	// VRAM->CPU accounting, for the read-back the BIOS hangs on: words the
	// engine produced, words the CPU took, words the DMA took, and reads of
	// GPUREAD that found nothing waiting (each one hands the CPU a status
	// word in place of a pixel and puts the transfer one word out of step)
	output wire [31:0] dbg_v2c,
	output wire [31:0] dbg_c0,      // the last VRAM->CPU transfer's width and height
	// A VRAM->CPU transfer is running and the next word is not ready yet. The
	// chip holds the bus here; reading GPUREAD anyway gets the status word in
	// place of a pixel, and the transfer is one word out of step from then on.
	output wire        rd_stall
);
	// ==================================================================================
	// the command FIFO
	// ==================================================================================
	// 8192 words of block RAM: a whole frame's display list, so a DMA drains at
	// bus speed and completes while the engine draws behind it (the chip and
	// the emulators behave this way; a 16-word FIFO tied the DMA to the
	// rasteriser's pace and the BIOS rewrote packets it had not read yet).
	localparam FIFO_AW = 14;
	reg [31:0] fifo [0:(1 << FIFO_AW) - 1];
	reg [FIFO_AW:0] f_wr, f_rd;
	reg [31:0] cmd_hist;            // last four opcodes the engine started on
	wire [FIFO_AW:0] f_count = f_wr - f_rd;
	wire       f_empty = (f_count == 0);
	wire       f_full  = f_count[FIFO_AW];
	// --- the processor's writes arrive through one register ------------------
	// `sel` is the processor's address decode AND its ready cone: the data
	// cache's tag read, `served`, the I/O stall. Used directly, that whole chain
	// ran on into GP1 dispatch and the drawing state in the same clock -- 27
	// levels, the worst path in the design, and what held the build at a
	// hundredth of a nanosecond. One register here ends the processor's cone
	// at a flop and starts the GPU's from one.
	//
	// A word can wait in it: if the DMA is pushing in the clock the word would
	// land, the DMA takes the FIFO and the word is consumed the clock after.
	// It cannot be overwritten meanwhile, because the processor is already
	// stalled whenever the DMA writes (gp0_wait in ps1_top).
	reg         wr_r;
	reg         a4_r;
	reg  [31:0] wdata_r;
	always @(posedge clk) begin
		if (rst) wr_r <= 1'b0;
		else if (sel && we) begin wr_r <= 1'b1; a4_r <= a4; wdata_r <= wdata; end
		else if (wr_r && (a4_r || !dma_wr)) wr_r <= 1'b0;   // consumed
	end
	wire       cpu_gp0 = wr_r && !a4_r && !dma_wr;
	wire       f_push  = (cpu_gp0 || dma_wr) && !f_full;
	wire [31:0] f_in   = dma_wr ? dma_data : wdata_r;
	// One slot of margin: the DMA decides to push a cycle before the push lands,
	// and the CPU can push in the same cycle, so "not full" alone is a word lost.
	assign dma_ready = (f_count < ((1 << FIFO_AW) - 2));
	// The head word comes out of block RAM a cycle after the pointer lands on
	// it: f_head_ok says the registered copy is the word at f_rd.
	reg  [31:0] f_head;
	reg         f_head_ok;
	// The chip holds the bus when its FIFO is full; dropping the word instead
	// desynced every command after it once the engine fell behind the BIOS.
	assign gp0_full = (f_count >= ((1 << FIFO_AW) - 1));   // one slot kept for the word in the register
	// f_pop must be COMBINATIONAL. Registered, it advances f_rd one cycle after
	// the engine has already moved on, so the state that reads the next word
	// reads the current one again -- the command comes back as its own first
	// argument, and every multi-word command is off by one. It is combinational
	// on the state that is consuming a word this cycle.
	wire       f_pop;
	reg        fifo_flush;
	reg        gp1_abort;    // a GP1 reset landed this clock: abandon the command in hand

	// f_rd has exactly one driver: this block. The GP1 reset flushes the FIFO by
	// raising fifo_flush (below) rather than writing f_rd itself -- two blocks
	// driving f_rd is a multi-driven net, which synthesis "resolves" by keeping
	// one driver and silently dropping the other, so on the board the FIFO
	// pointer does something neither block intended.
	wire [FIFO_AW:0] f_rd_n = fifo_flush ? f_wr : f_pop ? f_rd + 1'b1 : f_rd;   // where the pointer lands
	always @(posedge clk) begin
		if (rst) begin f_wr <= 0; f_rd <= 0; f_head_ok <= 1'b0; end
		else begin
			if (f_push) begin fifo[f_wr[FIFO_AW-1:0]] <= f_in; f_wr <= f_wr + 1'b1; end
			f_rd <= f_rd_n;
			// a write landing on the very word being read this cycle is not seen
			// by that read: the head is stale for one cycle
			f_head_ok <= !(f_push && (f_wr[FIFO_AW-1:0] == f_rd_n[FIFO_AW-1:0]));
		end
		f_head <= fifo[f_rd_n[FIFO_AW-1:0]];
	end

	// ==================================================================================
	// the drawing environment
	// ==================================================================================
	reg [19:0] e2_raw; reg [18:0] e3_raw, e4_raw; reg [21:0] e5_raw;   // as written, for GP1(10h)
	reg [31:0] info_word;     // what GPUREAD answers when no VRAM word is pending
	reg [3:0]  tp_x;          // texture page x, in 64-pixel units
	reg        tp_y;          // texture page y, 0 or 256
	reg [1:0]  tp_abr;        // semi-transparency mode
	reg [1:0]  tp_depth;      // 0 = 4-bit, 1 = 8-bit, 2 = 15-bit
	reg        dither, draw_display;
	reg        tflip_x, tflip_y;      // E1 bits 12/13: a textured rectangle's texture runs backwards
	// texture disable (ps1-tests gpu/gp0-e1): E1 bit 11, or a polygon's texture page bit 11, sets it
	// only while GP1(09) allows; GPUSTAT 15 shows it, and textured primitives then draw without
	reg        tex_allow, tex_off;
	reg [4:0]  tw_mx, tw_my, tw_ox, tw_oy;   // texture window mask/offset (in 8s)
	reg [9:0]  da_x0, da_x1;  // drawing area
	reg [8:0]  da_y0, da_y1;
	reg signed [10:0] dofs_x, dofs_y;
	reg        mask_set, mask_chk;

	// ==================================================================================
	// display
	// ==================================================================================
	reg        disp_on;
	reg [9:0]  disp_x;        // where the picture is in VRAM
	reg [8:0]  disp_y;
	reg [1:0]  hres;          // 0=256 1=320 2=512 3=640
	reg        hres368, vres480, pal, bpp24, interlace;
	reg [1:0]  dma_dir;
	reg [11:0] hrange0, hrange1;
	reg [9:0]  vrange0, vrange1;

	// ==================================================================================
	// raster timing: free-running, 60 Hz, from the core's clock (3168 clocks a line at 50 MHz)
	// ==================================================================================
	localparam LINE_CYC = CLK_HZ / (60 * 263), LINES = 263, ACTIVE_LINES = 240;
	reg [11:0] rc_x;
	reg [8:0]  rc_y;
	reg        frame_tick;
	reg        field;         // 480i: which field the next frame shows
	reg [1:0]  arm_ticks;     // vertical syncs seen while a capture waits for an idle engine
	// A scan started at the vertical sync itself reads the buffer the machine is
	// ABOUT to draw into, not the one it is showing: the BIOS swaps the two in
	// its vertical blank handler, which has not run yet. The picture then comes
	// out half drawn -- background but no text, or text but no spheres -- and a
	// different half every frame, which is what the flicker was. Waiting a
	// couple of milliseconds lets the swap happen first.
	reg [19:0] post_vsync;
	localparam [19:0] SWAP_WAIT = CLK_HZ / 500;     // 2 ms
	localparam [19:0] LATE      = CLK_HZ / 1000 * 15;   // 15 ms: give up waiting for idle
	wire       swap_done = (post_vsync == SWAP_WAIT);

	// vertical sync arms exactly one capture; see the note by SC_IDLE
	reg        want_scan;
	// A game that double-buffers flips the display area once a frame, right
	// after the vertical sync, and then draws into the other buffer. A capture
	// that starts at that flip reads a buffer nothing is drawing into and is
	// done (about half a frame) before the next flip: no tear. So a flip arms
	// the capture, and while flips keep coming the idle-engine rules below are
	// not used at all -- they were written for the BIOS, which draws in place.
	reg        flip_pend;       // the display area moved since the last vertical sync
	reg        flip_alt;        // take one flip in two: a capture is longer than a frame
	reg [1:0]  flips_recent;    // frames since the last flip, saturating: 0 = none lately
	reg [9:0]  disp_x_d; reg [8:0] disp_y_d;   // to see the display area move (the flip is seen a clock late)
	// A flip WHILE a capture is running is the tear: the game is about to draw
	// into the buffer being read, and what goes out is half of one picture and
	// half of the next. It shows when the engine is slow -- a big textured
	// scene, a character close to the camera -- because then a capture lasts
	// longer than the game's frame. So that capture is abandoned and started
	// again at the flip; the frame is dropped, never spliced.
	reg        sc_abort;
	// 480i (il_skip): a capture reads the field on screen while the engine draws the other, so
	// it must start as the field turns -- it then has a whole field's time before its rows are
	// drawn over -- and the two fields must take turns. Started whenever the HDMI side asked,
	// a capture ran across a field turn (a tear down the boot logo), and only every other scan
	// was ever kept, so one field's rows were never refreshed: the last game's picture showed
	// through every other line of the BIOS's screens.
	reg        il_field_d, il_fresh, il_last;
	reg [19:0] frame_len;        // how long the last frame was, in clocks
	// three quarters through, and almost at the end
	wire [19:0] capture_at = frame_len - (frame_len >> 2);
	wire [19:0] late_at    = frame_len - (frame_len >> 4);
	always @(posedge clk) begin
		if (rst) begin rc_x <= 0; rc_y <= 0; vblank <= 0; hblank <= 0; dot_ce <= 0; frame_tick <= 0; field <= 0; post_vsync <= 0; frame_len <= 0; end
		else begin
			frame_tick <= 1'b0;
			if (frame_tick) begin post_vsync <= 0; frame_len <= post_vsync; end
			else if (post_vsync != {20{1'b1}}) post_vsync <= post_vsync + 1'b1;
			dot_ce <= (rc_x[2:0] == 3'd0);          // ~6.25 MHz, near enough a dot
			if (rc_x == LINE_CYC - 1) begin
				rc_x <= 0;
				// The field turns at the START of vertical blanking, not at the end:
				// from the vblank interrupt on, the field in `field` is the one the
				// next scan shows, and a frame the BIOS draws in that interrupt must
				// go to the other one. Turned at the end of blanking, the first
				// twenty-two lines of every frame went to the field about to be
				// shown and the rest to the other: the picture came in two halves.
				if (rc_y == ACTIVE_LINES - 1) field <= ~field;
				if (rc_y == LINES - 1) begin rc_y <= 0; frame_tick <= 1'b1; end
				else rc_y <= rc_y + 9'd1;
			end else rc_x <= rc_x + 12'd1;
			hblank <= (rc_x >= 2560);
			vblank <= (rc_y >= ACTIVE_LINES);
		end
	end

	// ==================================================================================
	// GPUSTAT
	// ==================================================================================
	reg        busy;               // the drawing engine is on something
	reg [31:0] rd_word;             // a VRAM->CPU word waiting to be collected
	reg        rd_have;
	// Counted per VRAM->CPU transfer: cleared when one starts, so what they hold
	// afterwards describes that transfer and not the whole session.
	reg [7:0]  n_made, n_cpu, n_dma, n_empty;
	reg [10:0] c0_w; reg [9:0] c0_h;            // the size that transfer asked for
	assign dbg_v2c = {n_made, n_cpu, n_dma, n_empty};
	assign dbg_c0  = {5'd0, c0_w, 6'd0, c0_h};
	reg        rd_pending;         // a VRAM->CPU is in progress
	// A read-back is running and the next word is not there yet: the CPU must
	// wait, as it does on the chip.
	assign rd_stall = rd_pending && !rd_have;
	wire        c2v_phase;          // a CPU->VRAM transfer is taking its data (assigned below)
	wire [31:0] gpustat = {
		// 31: the line being drawn is odd (0 in vblank); in 480i it is the FIELD,
		// which toggles every frame -- the BIOS's VSync in that mode waits for it
		vblank ? 1'b0 : ((interlace && vres480) ? field : rc_y[0]),
		dma_dir,                    // 30:29
		// 28 ready for DMA: clear while a drawing / CPU->VRAM command executes. NOT
		// during a VRAM->CPU (C0) transfer: the BIOS queues a C0 with the DMA
		// direction off and then waits for THIS bit before collecting the words,
		// so a C0 that held it low stalled the BIOS until its 4 s GPU timeout
		// (the board seemed to pass; it was timing out; the sim never got that far).
		// ...and SET while a CPU->VRAM transfer waits for its data: that is exactly when the
		// chip wants a DMA block. psxsdk's DrawSync after an A0 header waits for this bit,
		// and held low it waited for ever (ps1-tests dma/chopping)
		!busy || rd_pending || c2v_phase,
		rd_have,                    // 27 ready to send VRAM to CPU: a word is actually waiting
		                            // (the BIOS polls this before every GPUREAD; a 0 read as data
		                            // leaves the last word in the GPU and it never goes idle)
		// 26 ready for commands. PSX_MiSTer clears it when a command starts and
		// sets it when the worker is done -- and a VRAM->CPU read is "done" once
		// its words are queued for collection, so the BIOS's self-test (C0, then
		// wait for bit 26, THEN collect) does not wait on the collection itself.
		// ...and never while the DMA's GPU channel is at work: PSX_MiSTer masks
		// it with the DMA request, and the BIOS relies on that -- it writes a
		// VRAM read-back by CPU as soon as this bit is set, and a display list
		// still being fed by DMA would interleave with those words.
		(!busy || rd_pending) && f_empty && !dma_active,
		// 25 DMA request, by GP1(04h) direction (psx-spx): 1 = FIFO not full,
		// 2 = same as bit 28 (ready for a DMA block), 3 = same as bit 27
		(dma_dir == 2'd1) ? !f_full : (dma_dir == 2'd2) ? (!busy || rd_pending) : (dma_dir == 2'd3) ? rd_have : 1'b0,
		1'b0,                       // 24 irq
		!disp_on,                   // 23 display disabled
		interlace,                  // 22
		bpp24,                      // 21
		pal,                        // 20
		vres480,                    // 19
		hres,                       // 18:17
		hres368,                    // 16
		tex_off,                    // 15 texture disable
		1'b0,                       // 14 reverse
		1'b0,                       // 13 interlace field
		mask_chk,                   // 12
		mask_set,                   // 11
		draw_display,               // 10
		dither,                     // 9
		tp_depth,                   // 8:7
		tp_abr,                     // 6:5
		tp_y,                       // 4
		tp_x                        // 3:0
	};

	// ==================================================================================
	// the drawing engine
	// ==================================================================================
	localparam
		D_IDLE   = 6'd0,  D_HEAD   = 6'd1,  D_ARG    = 6'd2,
		D_FILL   = 6'd3,  D_FILLW  = 6'd4,
		D_TRI    = 6'd5,  D_GRAD   = 6'd6,  D_GRADW  = 6'd7,  D_SCAN = 6'd8,
		D_TEXEL  = 6'd9,  D_TEXELW = 6'd10, D_CLUT   = 6'd11, D_CLUTW = 6'd12,
		D_BLEND  = 6'd13, D_BLENDW = 6'd14, D_WRITE  = 6'd15, D_WRITEW = 6'd16,
		D_NEXT   = 6'd17,
		D_RECT   = 6'd18,
		D_LINE   = 6'd19,
		D_PLNEXT = 6'd27,   // polyline: the next vertex, or the terminator
		D_COPY   = 6'd20, D_COPYR  = 6'd21, D_COPYW  = 6'd22,
		D_C2V    = 6'd23, D_C2VW   = 6'd24,
		D_V2C    = 6'd25, D_V2CR   = 6'd26,
		D_QUAD2  = 6'd27, D_TEXUSE = 6'd28,
		D_RAST   = 6'd29,   // ps1_raster is drawing the polygon or rectangle
		D_GDONE  = 6'd30,   // the last gradient has landed: now the row start
		D_COPYB  = 6'd31, D_COPYBW = 6'd32,   // VRAM -> VRAM: writing the buffered run
		D_C2VM   = 6'd33, D_COPYM  = 6'd34;   // ...a transfer's write waiting on the mask check
	reg [5:0]  ds;
	// consume the FIFO head this cycle in the states that read a word. D_C2V
	// (CPU->VRAM) also consumes, and adds its own term through c2v_pop below.
	wire c2v_pop;
	assign f_pop = !f_empty && f_head_ok && ((ds == D_IDLE) || (ds == D_ARG) || (ds == D_PLNEXT) || c2v_pop);
	assign c2v_phase = (ds == D_C2V) || (ds == D_C2VW) || (ds == D_C2VM);

	reg [7:0]  cmd;
	reg [31:0] args [0:15];
	reg [4:0]  nargs, argc;
	reg [4:0]  need;

	// polygon
	reg        is_gour, is_tex, is_quad, is_semi, is_raw;
	reg        is_poly;             // a polyline: segments until the $5555_5555 terminator
	reg        in_line;             // the engine is on a line segment (rxe means something else then)
	reg        pl_col;              // a Gouraud polyline: the next word is a colour
	reg signed [11:0] vx [0:3];
	reg signed [11:0] vy [0:3];
	reg [7:0]  vr [0:3], vg [0:3], vb [0:3];
	reg [7:0]  vu [0:3], vv [0:3];
	reg [15:0] clut;
	reg [15:0] texpage;
	reg        second;              // drawing the quad's second triangle

	// current triangle
	reg signed [11:0] x0, y0, x1, y1, x2, y2;
	reg signed [11:0] bx0, bx1, by0, by1;
	reg signed [11:0] px, py;
	reg signed [23:0] area;

	// gradients, 16.16 fixed
	reg signed [31:0] dr_dx, dr_dy, dg_dx, dg_dy, db_dx, db_dy, du_dx, du_dy, dv_dx, dv_dy;
	reg signed [31:0] cr, cg, cb, cu, cv;          // at the current pixel
	reg signed [31:0] rr, rg_, rb, ru, rv;         // at the start of the row

	// sequential divider for the gradients: 10 numerators over one area
	reg [3:0]  gq;                  // which gradient is being divided
	reg [5:0]  dcnt;
	reg signed [47:0] dnum;
	reg [48:0] rcq, rcr;              // 2^48 / |area| and the remainder as it is formed
	reg [23:0] dd;
	reg        dneg;
	reg [2:0]  gph;                 // where a gradient is: numerator, magnitude, product, quotient, remainder, store
	reg [47:0] nmag;
	reg [72:0] gprod;
	reg [31:0] gq0;
	reg [55:0] grem;
	wire [55:0] gqdd = gq0 * dd;    // 56 bits: in a concatenation the product would be cut to 32
	wire [31:0] gfix = (grem[55:0] >= {32'd0, dd}) ? gq0 + 32'd1 : gq0;

	// the pixel in flight
	reg [9:0]  wx;
	reg [8:0]  wy;
	reg [15:0] wpix;                // what is going to VRAM
	reg [15:0] texel;
	reg [15:0] dst;                 // what is there, for blending / mask
	reg        pix_semi;

	// rectangles and lines
	reg [10:0] rw;  reg [8:0] rh;      // (11 bits: a fill rounds 1009..1023 up to 1024)
	reg signed [11:0] rx, ry, rxe, rye;
	reg [7:0]  ru0, rv0;
	reg signed [11:0] lx0, ly0, lx1, ly1;
	// --- a line, as the chip draws it (Mednafen/DuckStation's DDA, which matches the
	// hardware): k = the longer side; the end with the smaller x first; x and y step by
	// d/k in 32-bit fixed point from the pixel's centre, nudged (-1024) so a tie rounds
	// the chip's way; colours step by (c1 - c0) * 4096 / k. Lines 1024 wide or 512 tall
	// are not drawn. Every pixel dithers when E1 dithering is on -- flat lines too, on the
	// console (ps1-tests gpu/lines). Bresenham, which this replaced, put the steps of a
	// shallow line in other places, and drew a Gouraud line in its first colour.
	reg [2:0]  lst;                     // 0 set up, 1 divide, 2 start, 3 position, 4 plot, 5 done
	reg [10:0] lk, lcnt;
	reg signed [11:0] lpx0, lpy0, lddx, lddy;
	reg signed [44:0] lcx, lcy, lsdx, lsdy;
	reg signed [20:0] lcr, lcg, lcb, lsr, lsg, lsb;
	reg [7:0]  lc0r, lc0g, lc0b;
	reg signed [8:0] ldcr, ldcg, ldcb;
	reg [1:0]  ldiv;                    // which quotient: 0 the short side, 1-3 r g b
	reg [43:0] dv_n, dv_q; reg [10:0] dv_r; reg [5:0] dv_i; reg dv_neg;
	wire [11:0] dv_r2 = {dv_r, dv_n[43]};
	wire        dv_ge = dv_r2 >= {1'b0, lk};
	wire [11:0] l_adx = lddx < 0 ? -lddx : lddx;
	wire [11:0] l_ady = lddy < 0 ? -lddy : lddy;
	wire        l_xmaj = l_adx >= l_ady;    // x is the long side (or they tie)

	// copies
	// cx/cw count to 1024 and cy/ch to 512 -- a full-width transfer. Ten bits
	// made 10'd1024 into 0, so a 1024-wide VRAM read or upload finished before
	// its first pixel and whoever was collecting the words waited forever.
	reg [10:0] cx, cw;
	reg [9:0]  cy, ch, cxs, cys, cxd, cyd, cxi, cyi;
	reg [15:0] chold;
	reg [15:0] cbuf [0:15];          // VRAM -> VRAM: up to 16 pixels read before any is written
	reg [4:0]  ck, cn;
	reg        t_skip;                // a transfer's pixel the mask check keeps: no write
	reg        cphase;              // CPU<->VRAM: which half of the word
	reg [31:0] cword;

	wire [31:0] w0 = args[0], w1 = args[1], w2 = args[2], w3 = args[3];

	reg        skip;                // this pixel is not drawn: transparent or masked

	// --- the raster, and the engine's own side of the VRAM port ---------------------
	reg  [28:0] e_addr; reg e_req, e_we; reg [3:0] e_be; reg [31:0] e_wdata;
	reg         r_start, r_rect;
	wire        r_busy;
	reg signed [11:0] r_bx0, r_bx1, r_by0, r_by1;
	reg signed [23:0] r_e0, r_e1, r_e2;
	wire [28:0] r_v_addr; wire r_v_req, r_v_we, r_v_around, r_v_lin; wire [3:0] r_v_be; wire [31:0] r_v_wdata;
	wire        r_st_tex, r_st_dst, r_st_full, r_st_clut;
	assign v_addr   = r_busy ? r_v_addr   : e_addr;
	assign v_req    = r_busy ? r_v_req    : e_req;
	assign v_we     = r_busy ? r_v_we     : e_we;
	assign v_be     = r_busy ? r_v_be     : e_be;
	assign v_wdata  = r_busy ? r_v_wdata  : e_wdata;
	assign v_around = r_busy && r_v_around;
	assign v_lin    = r_busy && r_v_lin;

	// --- helpers ----------------------------------------------------------------------
	function [28:0] vaddr;          // pixel (x, y) -> byte address of its word
		input [9:0] x; input [8:0] y;
		vaddr = {y, x[9:1], 2'b00};
	endfunction
	function [3:0] vbe;
		input [9:0] x;
		vbe = x[0] ? 4'b1100 : 4'b0011;
	endfunction
	function [15:0] half;
		input [31:0] w; input odd;
		half = odd ? w[31:16] : w[15:0];
	endfunction
	function [15:0] to555;
		input [7:0] r, g, b;
		to555 = {1'b0, b[7:3], g[7:3], r[7:3]};
	endfunction
	// the chip's 4x4 dither, added before the colour drops to five bits
	function [4:0] dith5;
		input [7:0] c; input [1:0] x, y;
		reg signed [3:0] o; reg signed [9:0] v;
		begin
			case ({y, x})
			4'h0: o = -4; 4'h1: o =  0; 4'h2: o = -3; 4'h3: o =  1;
			4'h4: o =  2; 4'h5: o = -2; 4'h6: o =  3; 4'h7: o = -1;
			4'h8: o = -3; 4'h9: o =  1; 4'hA: o = -4; 4'hB: o =  0;
			4'hC: o =  3; 4'hD: o = -1; 4'hE: o =  2; default: o = -2;
			endcase
			v = $signed({2'b0, c}) + o;
			dith5 = v[9] ? 5'd0 : v[8] ? 5'd31 : v[7:3];
		end
	endfunction
	function [7:0] sat8;
		input [8:0] v;
		sat8 = v[8] ? 8'hFF : v[7:0];
	endfunction
	function [4:0] sat5;
		input [5:0] v;
		sat5 = v[5] ? 5'h1F : v[4:0];
	endfunction

	// modulate a texel by a colour: (t * c) / 128, saturating
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

	// how many words a command needs after its first
	function [4:0] argcount;
		input [7:0] c;
		reg g, q, t;
		begin
			g = c[4]; q = c[3]; t = c[2];
			casez (c)
			8'h02:      argcount = 5'd2;
			8'b001?_????: argcount = g ? (q ? 4 : 3) * (2 + t) - 1 : (q ? 4 : 3) * (1 + t);
			8'b0100_????,
			8'b0101_????: argcount = c[4] ? 5'd3 : 5'd2;        // one segment; polylines below
			8'b011?_????: argcount = (c[4:3] == 2'd0 ? 1 : 0) + (t ? 1 : 0) + 1;
			// the transfers decode on their top three bits: 80-9F are all VRAM->VRAM, A0-BF
			// all CPU->VRAM, C0-DF all VRAM->CPU (psx-spx)
			8'b100?_????: argcount = 5'd3;
			8'b101?_????, 8'b110?_????: argcount = 5'd2;
			default:    argcount = 5'd0;
			endcase
		end
	endfunction

	// an edge function's sign says which side of the edge a point is on
	function signed [23:0] edgefn;
		input signed [11:0] ax, ay, bx, by, px, py;
		edgefn = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
	endfunction

	// the edge values at (px, py), carried forward rather than recomputed
	reg signed [23:0] ex0, ex1, ex2;      // here
	reg signed [23:0] er0, er1, er2;      // at the start of this row
	reg signed [23:0] sx0, sx1, sx2;      // one pixel right
	reg signed [23:0] sy0, sy1, sy2;      // one row down
	wire signed [23:0] e0 = ex0;
	wire signed [23:0] e1 = ex1;
	wire signed [23:0] e2 = ex2;
	wire inside = (area > 0) ? (e0 >= 0 && e1 >= 0 && e2 >= 0)
	                         : (e0 <= 0 && e1 <= 0 && e2 <= 0);
	// 480i, drawing to the display area prohibited: only the field not on
	// screen is drawn (see ps1_raster.v); a line's pixels obey it as well
	wire il_skip = interlace && vres480 && !draw_display;
	wire in_area = (px >= $signed({1'b0, da_x0})) && (px <= $signed({1'b0, da_x1}))
	            && (py >= $signed({2'b0, da_y0})) && (py <= $signed({2'b0, da_y1}))
	            && px >= 0 && py >= 0 && px < 1024 && py < 512
	            && !(il_skip && (py[0] == field));

	// the same questions asked of the pixels two and three to the right, which
	// is the pair after this one
	wire signed [11:0] px2 = px + 12'd2;
	wire signed [11:0] px3 = px + 12'd3;
	wire signed [23:0] r0 = ex0 + (sx0 <<< 1);
	wire signed [23:0] r1 = ex1 + (sx1 <<< 1);
	wire signed [23:0] r2 = ex2 + (sx2 <<< 1);
	wire signed [23:0] q0 = r0 + sx0;
	wire signed [23:0] q1 = r1 + sx1;
	wire signed [23:0] q2 = r2 + sx2;
	wire inside_2 = (area > 0) ? (r0 >= 0 && r1 >= 0 && r2 >= 0)
	                           : (r0 <= 0 && r1 <= 0 && r2 <= 0);
	wire inside_3 = (area > 0) ? (q0 >= 0 && q1 >= 0 && q2 >= 0)
	                           : (q0 <= 0 && q1 <= 0 && q2 <= 0);
	wire in_area_2 = (px2 >= $signed({1'b0, da_x0})) && (px2 <= $signed({1'b0, da_x1}))
	              && (py >= $signed({2'b0, da_y0})) && (py <= $signed({2'b0, da_y1}))
	              && px2 >= 0 && px2 < 1024;
	wire in_area_3 = (px3 >= $signed({1'b0, da_x0})) && (px3 <= $signed({1'b0, da_x1}))
	              && (py >= $signed({2'b0, da_y0})) && (py <= $signed({2'b0, da_y1}))
	              && px3 >= 0 && px3 < 1024;

	wire [15:0] dst_now = half(v_rdata, wx[0]);           // what is under the pixel, as it arrives

	// --- the destination line a line-drawing pixel reads back ------------------
	// Polygons and rectangles no longer come through here at all: they go to
	// ps1_raster (below), two pixels a clock. What is left of the per-pixel
	// engine draws lines, fills and copies, and a line that blends reads the
	// pixel under it through this held line.
	reg [127:0] cl_d, dl_d;              // (cl_d: no longer used; the raster has its own palette)
	reg [24:0]  cl_a, dl_a;
	reg         cl_v, dl_v;

	function [15:0] lhalf;
		input [127:0] l; input [28:0] a; input odd;
		lhalf = half(l[a[3:2]*32 +: 32], odd);
	endfunction

	wire [28:0] wa_now = vaddr(wx, wy);                // where the pixel lands
	wire        dl_hit = dl_v && (dl_a == wa_now[28:4]);
	wire [15:0] dst_held = lhalf(dl_d, wa_now, wx[0]);

	assign c2v_pop = (ds == D_C2V) && !cphase && (cx != cw) && (cy != ch) && f_head_ok;

	integer i;
	always @(posedge clk) begin
		if (rst) begin
			ds <= D_IDLE; busy <= 1'b0; fifo_flush <= 1'b0;
			e_req <= 1'b0; e_we <= 1'b0; v_lwe <= 1'b0; v_wdata128 <= 128'd0;
			r_start <= 1'b0; r_rect <= 1'b0; r_bx0 <= 0; r_bx1 <= 0; r_by0 <= 0; r_by1 <= 0; r_e0 <= 0; r_e1 <= 0; r_e2 <= 0;
			ex0 <= 0; ex1 <= 0; ex2 <= 0; er0 <= 0; er1 <= 0; er2 <= 0;
			sx0 <= 0; sx1 <= 0; sx2 <= 0; sy0 <= 0; sy1 <= 0; sy2 <= 0;
			tp_x <= 0; tp_y <= 0; tp_abr <= 0; tp_depth <= 0; dither <= 0; draw_display <= 0; tflip_x <= 1'b0; tflip_y <= 1'b0; t_skip <= 1'b0; tex_allow <= 1'b0; tex_off <= 1'b0;
			tw_mx <= 0; tw_my <= 0; tw_ox <= 0; tw_oy <= 0;
			da_x0 <= 0; da_y0 <= 0; da_x1 <= 10'd1023; da_y1 <= 9'd511;
			dofs_x <= 0; dofs_y <= 0; mask_set <= 0; mask_chk <= 0;
			disp_on <= 1'b0; disp_x <= 0; disp_y <= 0; hres <= 0; hres368 <= 0;
			vres480 <= 0; pal <= 0; bpp24 <= 0; interlace <= 0; dma_dir <= 0;
			hrange0 <= 12'h200; hrange1 <= 12'hC00; vrange0 <= 10'h10; vrange1 <= 10'h100;
			irq <= 1'b0; rd_pending <= 1'b0; dma_rvalid <= 1'b0;
			n_made <= 8'd0; n_cpu <= 8'd0; n_dma <= 8'd0; n_empty <= 8'd0;
			c0_w <= 11'd0; c0_h <= 10'd0;
			second <= 1'b0; nargs <= 0; argc <= 0; need <= 0; skip <= 1'b0; rd_have <= 1'b0; gp1_abort <= 1'b0;
			e2_raw <= 20'd0; e3_raw <= 19'd0; e4_raw <= 19'd0; e5_raw <= 22'd0; info_word <= 32'd0;
			is_poly <= 1'b0; pl_col <= 1'b0; in_line <= 1'b0;
			cl_v <= 1'b0; dl_v <= 1'b0;
			cl_a <= 25'd0; dl_a <= 25'd0;
			cl_d <= 128'd0; dl_d <= 128'd0;
		end else begin
			fifo_flush <= 1'b0;
			gp1_abort  <= 1'b0;   // a pulse; the GP1 handler below may set it again this clock
			// v_req is a held request, not a pulse: once a draw state raises it,
			// keep it high until the VRAM cache acknowledges. The cache only
			// takes a new request while it is idle, and the scanout shares that
			// cache -- a one-cycle pulse issued while the scanout is being served
			// is simply missed, and the draw engine then waits forever for an
			// ack that never comes. Clearing only on v_ack closes that race.
			if (v_ack) begin e_req <= 1'b0; v_lwe <= 1'b0; end
			// A write changes VRAM underneath what is being held, so fix the held
			// lines up as it goes out rather than throwing them away: the
			// destination takes the new pixel, because the next pixel along the
			// scanline is almost always in the same line, and a texel or palette
			// line that happens to cover the same sixteen bytes is dropped.
			if (e_req && e_we && v_ack) begin
				if (dl_v && (dl_a == e_addr[28:4])) begin
					if (v_lwe) dl_d <= v_wdata128;    // the whole line was replaced
					else begin
						if (e_be[1:0] == 2'b11) dl_d[{e_addr[3:2], 1'b0} * 16 +: 16] <= e_wdata[15:0];
						if (e_be[3:2] == 2'b11) dl_d[{e_addr[3:2], 1'b1} * 16 +: 16] <= e_wdata[31:16];
					end
				end
				if (cl_v && (cl_a == e_addr[28:4])) cl_v <= 1'b0;
			end
			if (r_busy) begin dl_v <= 1'b0; cl_v <= 1'b0; end   // the raster is writing: nothing held is current
			dma_rvalid <= 1'b0;

			// --- GP1 is immediate ------------------------------------------------------
			if (wr_r && a4_r) begin
				case (wdata_r[29:24])
				6'h00: begin gp1_abort <= 1'b1; disp_on <= 1'b0; dma_dir <= 0; disp_x <= 0; disp_y <= 0;
				             tp_x <= 0; tp_y <= 0; da_x0 <= 0; da_y0 <= 0;
				             da_x1 <= 10'd1023; da_y1 <= 9'd511; dofs_x <= 0; dofs_y <= 0;
				             fifo_flush <= 1'b1; ds <= D_IDLE; busy <= 1'b0; end
				6'h01: begin gp1_abort <= 1'b1; fifo_flush <= 1'b1; ds <= D_IDLE; busy <= 1'b0; in_line <= 1'b0; rxe <= 0; end
				6'h02: irq <= 1'b0;
				6'h03: disp_on <= !wdata_r[0];
				6'h04: dma_dir <= wdata_r[1:0];
				6'h05: begin disp_x <= wdata_r[9:0]; disp_y <= wdata_r[18:10]; end
				6'h06: begin hrange0 <= wdata_r[11:0]; hrange1 <= wdata_r[23:12]; end
				6'h07: begin vrange0 <= wdata_r[9:0]; vrange1 <= wdata_r[19:10]; end
				6'h09: tex_allow <= wdata_r[0];
				6'h08: begin hres <= wdata_r[1:0]; vres480 <= wdata_r[2]; pal <= wdata_r[3];
				             bpp24 <= wdata_r[4]; interlace <= wdata_r[5]; hres368 <= wdata_r[6]; end
				// GP1(10h) Get GPU Info (psx-spx): the answer appears on GPUREAD. The
				// BIOS asks 07h (version) at boot to tell a v2 GPU from the original.
				6'h10, 6'h11, 6'h12, 6'h13, 6'h14, 6'h15, 6'h16, 6'h17, 6'h18, 6'h19, 6'h1A, 6'h1B, 6'h1C, 6'h1D, 6'h1E, 6'h1F:
					case (wdata_r[3:0])
					4'h2: info_word <= {12'd0, e2_raw};
					4'h3: info_word <= {13'd0, e3_raw};
					4'h4: info_word <= {13'd0, e4_raw};
					4'h5: info_word <= {10'd0, e5_raw};
					4'h7: info_word <= 32'd2;
					4'h8: info_word <= 32'd0;
					default: ;                       // 0/1 and the rest: the old value stays
					endcase
				default: ;
				endcase
			end

			case (ds)
			// -------------------------------------------------------------------------------
			D_IDLE: if ((!f_empty && f_head_ok)) begin
					cmd   <= f_head[31:24];
					cmd_hist <= {cmd_hist[23:0], f_head[31:24]};
					// anything could have changed the texture page, the palette or
					// the drawing area between primitives: start each one clean
					cl_v <= 1'b0; dl_v <= 1'b0;
					args[0] <= f_head;
					need  <= argcount(f_head[31:24]);
					argc  <= 5'd1;
					busy  <= 1'b1;
					second <= 1'b0;
					// the environment commands need no arguments: do them now
					case (f_head[31:24])
					8'h00, 8'h01: begin busy <= 1'b0; end
					8'h1F: begin irq <= 1'b1; busy <= 1'b0; end
					8'hE1: begin tp_x <= f_head[3:0]; tp_y <= f_head[4]; tp_abr <= f_head[6:5]; tflip_x <= f_head[12]; tflip_y <= f_head[13];
					             tp_depth <= f_head[8:7]; dither <= f_head[9]; draw_display <= f_head[10];
					             tex_off <= tex_allow && f_head[11];
					             busy <= 1'b0; end
					8'hE2: begin e2_raw <= f_head[19:0]; tw_mx <= f_head[4:0]; tw_my <= f_head[9:5]; tw_ox <= f_head[14:10];
					             tw_oy <= f_head[19:15]; busy <= 1'b0; end
					8'hE3: begin e3_raw <= f_head[18:0]; da_x0 <= f_head[9:0]; da_y0 <= f_head[18:10]; busy <= 1'b0; end
					8'hE4: begin e4_raw <= f_head[18:0]; da_x1 <= f_head[9:0]; da_y1 <= f_head[18:10]; busy <= 1'b0; end
					8'hE5: begin e5_raw <= f_head[21:0]; dofs_x <= f_head[10:0]; dofs_y <= f_head[21:11]; busy <= 1'b0; end
					8'hE6: begin mask_set <= f_head[0]; mask_chk <= f_head[1]; busy <= 1'b0; end
					// anything else with no arguments is a one-word no-op on the chip (03-1E, E0,
					// E7-EF): the engine must say it is ready again. It used to stay busy for good,
					// and the BIOS's libgpu then waited out its 'GPU timeout' -- seconds a frame.
					default: if (argcount(f_head[31:24]) == 0) begin busy <= 1'b0; ds <= D_IDLE; end
					         else ds <= D_ARG;
					endcase
				end

			// collect the rest of the words
			D_ARG: if ((!f_empty && f_head_ok)) begin
					args[argc] <= f_head;
					argc  <= argc + 5'd1;
					if (argc == need) ds <= D_HEAD;
				end

			// dispatch
			D_HEAD: begin
					casez (cmd)
					8'h02: begin                                  // fill
						// psx-spx: X start AND 3F0h, width ((n AND 3FFh) + 0Fh) AND NOT 0Fh -- which
						// reaches 1024 for 1009..1023, and the fill then wraps round the whole row.
						// Done in 10 bits that width came out 0 and the fill drew nothing
						// (ps1-tests gpu/triangle clears its last quarter with width 1009).
						rx  <= {2'b0, w1[9:4], 4'b0};  ry <= {3'b0, w1[24:16]};
						rw  <= ({1'b0, w2[9:0]} + 11'h0F) & 11'h7F0;
						rh  <= w2[24:16];
						rxe <= {2'b0, w1[9:4], 4'b0};
						wpix <= to555(w0[7:0], w0[15:8], w0[23:16]);
						ds <= D_FILL;
					end
					8'b001?_????: begin                           // polygon
						rxe <= 0; in_line <= 1'b0;
						is_gour <= cmd[4]; is_quad <= cmd[3]; is_tex <= cmd[2] && !tex_off;
						is_semi <= cmd[1]; is_raw <= cmd[0];
						unpack_poly();
						ds <= D_TRI;
					end
					8'b011?_????: begin                           // rectangle
						is_tex <= cmd[2] && !tex_off; is_semi <= cmd[1]; is_raw <= cmd[0];
						vr[0] <= w0[7:0]; vg[0] <= w0[15:8]; vb[0] <= w0[23:16];
						rx <= $signed(w1[10:0]) + dofs_x; ry <= $signed(w1[26:16]) + dofs_y;
						case (cmd[4:3])
						2'd0: begin rw <= cmd[2] ? w3[9:0] : w2[9:0]; rh <= cmd[2] ? w3[24:16] : w2[24:16]; end
						2'd1: begin rw <= 10'd1;  rh <= 9'd1;  end
						2'd2: begin rw <= 10'd8;  rh <= 9'd8;  end
						default: begin rw <= 10'd16; rh <= 9'd16; end
						endcase
						if (cmd[2]) begin ru0 <= w2[7:0]; rv0 <= w2[15:8]; clut <= w2[31:16]; end
						rxe <= 0;
						ds <= D_RECT;
					end
					8'b010?_????: begin                           // line: the first segment
						is_gour <= cmd[4]; is_semi <= cmd[1]; is_poly <= cmd[3]; pl_col <= cmd[4];
						vr[0] <= w0[7:0]; vg[0] <= w0[15:8]; vb[0] <= w0[23:16];
						lx0 <= $signed(w1[10:0]) + dofs_x; ly0 <= $signed(w1[26:16]) + dofs_y;
						if (cmd[4]) begin
							vr[1] <= w2[7:0]; vg[1] <= w2[15:8]; vb[1] <= w2[23:16];
							lx1 <= $signed(w3[10:0]) + dofs_x; ly1 <= $signed(w3[26:16]) + dofs_y;
						end else begin
							lx1 <= $signed(w2[10:0]) + dofs_x; ly1 <= $signed(w2[26:16]) + dofs_y;
						end
						ds <= D_LINE; rxe <= 0; in_line <= 1'b1; lst <= 3'd0;
					end
					8'b100?_????: begin                           // VRAM -> VRAM
						cxs <= w1[9:0]; cys <= w1[24:16]; cxd <= w2[9:0]; cyd <= w2[24:16];
						cw <= (w3[9:0] == 0) ? 11'd1024 : {1'b0, w3[9:0]};   // 0 means max
						ch <= (w3[24:16] == 0) ? 10'd512 : {1'b0, w3[24:16]};
						cx <= 0; cy <= 0;
						ds <= D_COPY;
					end
					8'b101?_????: begin                           // CPU -> VRAM
						cxd <= w1[9:0]; cyd <= w1[24:16];
						cw <= (w2[9:0] == 0) ? 11'd1024 : {1'b0, w2[9:0]};
						ch <= (w2[24:16] == 0) ? 10'd512 : {1'b0, w2[24:16]};
						cx <= 0; cy <= 0; cphase <= 1'b0;
						ds <= D_C2V;
					end
					8'b110?_????: begin                           // VRAM -> CPU
						cxs <= w1[9:0]; cys <= w1[24:16];
						cw <= (w2[9:0] == 0) ? 11'd1024 : {1'b0, w2[9:0]};
						ch <= (w2[24:16] == 0) ? 10'd512 : {1'b0, w2[24:16]};
							cx <= 0; cy <= 0; cphase <= 1'b0;
						rd_pending <= 1'b1;
						c0_w <= (w2[9:0] == 0) ? 11'd1024 : {1'b0, w2[9:0]};
						c0_h <= (w2[24:16] == 0) ? 10'd512 : {1'b0, w2[24:16]};
						n_made <= 8'd0; n_cpu <= 8'd0; n_dma <= 8'd0; n_empty <= 8'd0;
						ds <= D_V2C;
					end
					default: begin busy <= 1'b0; ds <= D_IDLE; end
					endcase
				end

			// -------------------------------------------------------------------------------
			// fill: rows of whole words, no blending, no mask
			// a fill walks with rxe and must leave it clear: a polygon after a fill
			// took the leftover as "in a rectangle" and stepped its pixels wrongly
			// (the BIOS menu's text came out as rainbow noise)
			D_FILL: if (rh == 0) begin busy <= 1'b0; ds <= D_IDLE; rxe <= 0; end
				else if (rxe >= $signed({2'b0, rx}) + $signed({2'b0, rw})) begin
					rxe <= rx; ry <= ry + 12'd1; rh <= rh - 9'd1;
				end else begin
					// a fill starts on a 16-pixel boundary and is a multiple of 16 wide, so it
					// goes out a whole VRAM line -- eight pixels -- at a time (it went two at a
					// time, and a 1024 x 512 clear took longer than a frame: ps1-tests' frames
					// were never finished when they were looked at)
					e_addr <= vaddr({rxe[9:3], 3'd0}, ry[8:0]);
					e_be   <= 4'b1111;
					e_wdata <= {wpix, wpix};
					v_lwe  <= 1'b1; v_wdata128 <= {8{wpix}};
					e_we   <= 1'b1; e_req <= 1'b1;
					ds <= D_FILLW;
				end
			D_FILLW: if (v_ack) begin rxe <= rxe + 12'd8; ds <= D_FILL; end

			// -------------------------------------------------------------------------------
			// polygon: set up the triangle, compute gradients, scan
			D_TRI: begin
					if (!second) begin
						x0 <= vx[0]; y0 <= vy[0]; x1 <= vx[1]; y1 <= vy[1]; x2 <= vx[2]; y2 <= vy[2];
					end else begin
						x0 <= vx[1]; y0 <= vy[1]; x1 <= vx[2]; y1 <= vy[2]; x2 <= vx[3]; y2 <= vy[3];
					end
					gq <= 4'd0;
					ds <= D_GRAD;
				end

			D_GRAD: begin
					// the area (twice it, signed), and the bounding box
					area <= edgefn(x0, y0, x1, y1, x2, y2);
					bx0 <= min3(x0, x1, x2); bx1 <= max3(x0, x1, x2);
					by0 <= min3(y0, y1, y2); by1 <= max3(y0, y1, y2);
					// how much each edge changes over one pixel and one row
					sx0 <= {{12{y1[11]}}, y1} - {{12{y2[11]}}, y2};
					sx1 <= {{12{y2[11]}}, y2} - {{12{y0[11]}}, y0};
					sx2 <= {{12{y0[11]}}, y0} - {{12{y1[11]}}, y1};
					sy0 <= {{12{x2[11]}}, x2} - {{12{x1[11]}}, x1};
					sy1 <= {{12{x0[11]}}, x0} - {{12{x2[11]}}, x2};
					sy2 <= {{12{x1[11]}}, x1} - {{12{x0[11]}}, x0};
					if (edgefn(x0, y0, x1, y1, x2, y2) == 0
					    || max3(x0, x1, x2) - min3(x0, x1, x2) > 1023
					    || max3(y0, y1, y2) - min3(y0, y1, y2) > 511) begin
						// degenerate or oversized: the chip skips it
						ds <= D_NEXT;
					end else begin
						dcnt <= 6'd0;
						ds <= D_GRADW;
					end
				end

			// ten gradients, each a 48/24 division taking 48 steps; the numerators
			// are the "cross products" of the attribute with the edges
			D_GRADW: begin
					// Ten gradients over one area. Dividing each one took 48 clocks,
					// 500 a triangle, which for a game's thousands of small triangles
					// is a whole frame of nothing. So: 1/area once (49 clocks), then
					// every gradient is a multiply and a one-step correction, and the
					// result is bit for bit the truncated quotient the divider gave.
					if (dcnt == 6'd0) begin
						dd <= area[23] ? -area : area;
						rcq <= 49'd0; rcr <= 49'd0; gph <= 3'd0;
						dcnt <= 6'd1;
					end else if (dcnt <= 6'd49) begin
						// 2^48 / |area|, restoring: the numerator's only set bit
						// comes down on the first step
						if ({rcr[47:0], dcnt == 6'd1} >= {25'd0, dd}) begin
							rcr <= {rcr[47:0], dcnt == 6'd1} - {25'd0, dd};
							rcq <= {rcq[47:0], 1'b1};
						end else begin
							rcr <= {rcr[47:0], dcnt == 6'd1};
							rcq <= {rcq[47:0], 1'b0};
						end
						dcnt <= dcnt + 6'd1;
					end else begin
						case (gph)
						3'd0: begin
							case (gq)
							4'd0:  dnum <= gnum_x(vi(0, 0), vi(0, 1), vi(0, 2));
							4'd1:  dnum <= gnum_y(vi(0, 0), vi(0, 1), vi(0, 2));
							4'd2:  dnum <= gnum_x(vi(1, 0), vi(1, 1), vi(1, 2));
							4'd3:  dnum <= gnum_y(vi(1, 0), vi(1, 1), vi(1, 2));
							4'd4:  dnum <= gnum_x(vi(2, 0), vi(2, 1), vi(2, 2));
							4'd5:  dnum <= gnum_y(vi(2, 0), vi(2, 1), vi(2, 2));
							4'd6:  dnum <= gnum_x(vi(3, 0), vi(3, 1), vi(3, 2));
							4'd7:  dnum <= gnum_y(vi(3, 0), vi(3, 1), vi(3, 2));
							4'd8:  dnum <= gnum_x(vi(4, 0), vi(4, 1), vi(4, 2));
							default: dnum <= gnum_y(vi(4, 0), vi(4, 1), vi(4, 2));
							endcase
							gph <= 3'd1;
						end
						3'd1: begin
							dneg <= dnum[47] ^ area[23];
							nmag <= dnum[47] ? -dnum : dnum;
							gph <= 3'd2;
						end
						3'd2: begin
							// |num| is |X| << 16, so |num| / |area| = |X| * (2^48 / |area|) / 2^32
							gprod <= nmag[39:16] * rcq;
							gph <= 3'd3;
						end
						3'd3: begin
							// the reciprocal was rounded down, so this is the quotient or one under
							gq0  <= gprod[63:32];
							gph <= 3'd4;
						end
						3'd4: begin
							grem <= {8'd0, nmag} - gqdd;
							gph <= 3'd5;
						end
						default: begin
							case (gq)
							4'd0: dr_dx <= dneg ? -gfix : gfix;
							4'd1: dr_dy <= dneg ? -gfix : gfix;
							4'd2: dg_dx <= dneg ? -gfix : gfix;
							4'd3: dg_dy <= dneg ? -gfix : gfix;
							4'd4: db_dx <= dneg ? -gfix : gfix;
							4'd5: db_dy <= dneg ? -gfix : gfix;
							4'd6: du_dx <= dneg ? -gfix : gfix;
							4'd7: du_dy <= dneg ? -gfix : gfix;
							4'd8: dv_dx <= dneg ? -gfix : gfix;
							default: dv_dy <= dneg ? -gfix : gfix;
							endcase
							gph <= 3'd0;
							if (gq == 4'd9 || (!is_gour && gq == 4'd1 && !is_tex)
							    || (!is_gour && !is_tex)) begin
								// NOT start_row() here. The gradient this clock
								// writes is still on its way to the register, so
								// start_row would read the one the PREVIOUS
								// primitive left -- dv_dy for a textured polygon.
								// The starting v was then off by the old gradient
								// times the distance from vertex 0 to the top of
								// the box, and the polygon sampled the wrong rows
								// of its texture. One clock, once a primitive.
								dcnt <= 6'd0;
								ds <= D_GDONE;
							end else
								gq <= gq + 4'd1;
						end
						endcase
					end
				end

			// the gradients are all in the registers now: take the row start
			// from them and hand the primitive to the rasteriser
			D_GDONE: begin
					start_row();
					r_rect  <= 1'b0;
					r_bx0 <= bx0; r_bx1 <= bx1; r_by0 <= by0; r_by1 <= by1;
					// the only edge multiply left: once, here
					r_e0 <= edgefn(x1, y1, x2, y2, bx0, by0);
					r_e1 <= edgefn(x2, y2, x0, y0, bx0, by0);
					r_e2 <= edgefn(x0, y0, x1, y1, bx0, by0);
					r_start <= 1'b1;
					ds <= D_RAST;
				end

			// walk the box
			// read what is there, for blending or the mask check
			D_BLEND: if (dl_hit) begin
					dst <= dst_held;
					if (mask_chk && dst_held[15]) begin skip <= 1'b1; ds <= D_WRITEW; end
					else begin
						if (pix_semi) wpix <= blend(dst_held, wpix, tp_abr);
						ds <= D_WRITE;
					end
				end else begin
					e_addr <= wa_now; e_be <= 4'b1111; e_we <= 1'b0; e_req <= 1'b1;
					ds <= D_BLENDW;
				end
			D_BLENDW: if (v_ack) begin
					dl_d <= v_line; dl_a <= v_addr[28:4]; dl_v <= 1'b1;
					dst <= half(v_rdata, wx[0]);
					if (mask_chk && dst_now[15]) begin skip <= 1'b1; ds <= D_WRITEW; end   // protected
					else begin
						if (pix_semi) wpix <= blend(dst_now, wpix, tp_abr);
						ds <= D_WRITE;
					end
				end

			D_WRITE: begin
					e_addr <= vaddr(wx, wy); e_be <= vbe(wx);
					e_wdata <= {wpix | {mask_set, 15'd0}, wpix | {mask_set, 15'd0}};
					e_we <= 1'b1; e_req <= 1'b1;
					ds <= D_WRITEW;
				end
			D_WRITEW: if (skip || v_ack) begin
					skip <= 1'b0;
					e_we <= 1'b0;
					ds <= in_line ? D_LINE : D_NEXT;   // only a line's pixel comes this way now
				end


			D_NEXT: begin
					if (is_quad && !second) begin second <= 1'b1; ds <= D_TRI; end
					else begin busy <= 1'b0; ds <= D_IDLE; end
				end

			// -------------------------------------------------------------------------------
			// rectangles: rows, textured or flat, no interpolation
			D_RECT: begin
					// a rectangle is a box the raster fills: one texel a pixel, flat colour
					r_rect  <= 1'b1; is_gour <= 1'b0;
					r_bx0 <= rx; r_bx1 <= rx + $signed({2'b0, rw}) - 12'sd1;
					r_by0 <= ry; r_by1 <= ry + $signed({3'b0, rh}) - 12'sd1;
					r_e0 <= 24'd0; r_e1 <= 24'd0; r_e2 <= 24'd0;
					// (an X-flipped rectangle starts a texel on: u0+1, u0, u0-1 ... on the console --
					// ps1-tests gpu/texture-flip; the Y flip has no such offset)
					cu <= {8'd0, ru0 + (tflip_x ? 8'd1 : 8'd0), 16'd0}; cv <= {8'd0, rv0, 16'd0};
					// (E1's flips run the texture backwards: ps1-tests gpu/texture-flip)
					du_dx <= tflip_x ? -32'sh10000 : 32'h10000; dv_dx <= 32'd0; du_dy <= 32'd0;
					dv_dy <= tflip_y ? -32'sh10000 : 32'h10000;
					r_start <= 1'b1;
					ds <= D_RAST;
				end

			// the raster has the primitive: wait for it
			D_RAST: begin
					if (r_start) r_start <= 1'b0;
					else if (!r_busy) begin
						if (r_rect) begin busy <= 1'b0; ds <= D_IDLE; end
						else ds <= D_NEXT;
					end
				end


			D_LINE: case (lst)
				3'd0: begin : l_setup
					// the ends, offset and cut to 11 bits as every vertex is
					reg signed [11:0] ax, ay, bx, by, adx, ady, kk;
					reg sw;
					ax = {lx0[10], lx0[10:0]}; ay = {ly0[10], ly0[10:0]};
					bx = {lx1[10], lx1[10:0]}; by = {ly1[10], ly1[10:0]};
					adx = (bx > ax) ? bx - ax : ax - bx;
					ady = (by > ay) ? by - ay : ay - by;
					kk  = (adx > ady) ? adx : ady;
					sw  = (ax >= bx) && (kk != 0);
					lk  <= kk[10:0];
					lpx0 <= sw ? bx : ax; lpy0 <= sw ? by : ay;
					lddx <= sw ? ax - bx : bx - ax; lddy <= sw ? ay - by : by - ay;
					lc0r <= (is_gour && sw) ? vr[1] : vr[0];
					lc0g <= (is_gour && sw) ? vg[1] : vg[0];
					lc0b <= (is_gour && sw) ? vb[1] : vb[0];
					ldcr <= !is_gour ? 9'sd0 : sw ? $signed({1'b0, vr[0]}) - $signed({1'b0, vr[1]}) : $signed({1'b0, vr[1]}) - $signed({1'b0, vr[0]});
					ldcg <= !is_gour ? 9'sd0 : sw ? $signed({1'b0, vg[0]}) - $signed({1'b0, vg[1]}) : $signed({1'b0, vg[1]}) - $signed({1'b0, vg[0]});
					ldcb <= !is_gour ? 9'sd0 : sw ? $signed({1'b0, vb[0]}) - $signed({1'b0, vb[1]}) : $signed({1'b0, vb[1]}) - $signed({1'b0, vb[0]});
					lsdx <= 45'sd0; lsdy <= 45'sd0; lsr <= 21'sd0; lsg <= 21'sd0; lsb <= 21'sd0;
					ldiv <= 2'd0; dv_i <= 6'd0;
					if (adx >= 12'sd1024 || ady >= 12'sd512) lst <= 3'd5;        // too big: not drawn
					else if (kk == 0) lst <= 3'd2;
					else lst <= 3'd1;
				end
				// one quotient at a time, a bit a clock: the short side's step, then the colours'
				3'd1: if (dv_i == 6'd0) begin : l_load
					reg [11:0] m; reg [8:0] c;
					case (ldiv)
					2'd0: begin
						m = l_xmaj ? l_ady : l_adx;
						dv_neg <= l_xmaj ? (lddy < 0) : (lddx < 0);
						dv_n <= (m == 0) ? 44'd0 : ({1'b0, m[10:0], 32'd0} + {33'd0, lk} - 44'd1);
					end
					2'd1: begin c = ldcr[8] ? -ldcr : ldcr; dv_neg <= ldcr[8]; dv_n <= {24'd0, c[7:0], 12'd0}; end
					2'd2: begin c = ldcg[8] ? -ldcg : ldcg; dv_neg <= ldcg[8]; dv_n <= {24'd0, c[7:0], 12'd0}; end
					default: begin c = ldcb[8] ? -ldcb : ldcb; dv_neg <= ldcb[8]; dv_n <= {24'd0, c[7:0], 12'd0}; end
					endcase
					dv_r <= 11'd0; dv_q <= 44'd0; dv_i <= 6'd44;
				end else begin
					dv_r <= dv_ge ? dv_r2[10:0] - lk : dv_r2[10:0];
					dv_q <= {dv_q[42:0], dv_ge};
					dv_n <= {dv_n[42:0], 1'b0};
					dv_i <= dv_i - 6'd1;
					if (dv_i == 6'd1) begin : l_store
						reg [43:0] q;
						q = {dv_q[42:0], dv_ge};
						case (ldiv)
						2'd0: begin
							// the long side steps a whole pixel; the short one by the quotient
							if (l_xmaj) begin
								lsdx <= lddx < 0 ? -45'sh1_0000_0000 : 45'sh1_0000_0000;
								lsdy <= dv_neg ? -$signed({1'b0, q}) : $signed({1'b0, q});
							end else begin
								lsdy <= lddy < 0 ? -45'sh1_0000_0000 : 45'sh1_0000_0000;
								lsdx <= dv_neg ? -$signed({1'b0, q}) : $signed({1'b0, q});
							end
						end
						2'd1: lsr <= dv_neg ? -$signed({1'b0, q[19:0]}) : $signed({1'b0, q[19:0]});
						2'd2: lsg <= dv_neg ? -$signed({1'b0, q[19:0]}) : $signed({1'b0, q[19:0]});
						default: lsb <= dv_neg ? -$signed({1'b0, q[19:0]}) : $signed({1'b0, q[19:0]});
						endcase
						if (ldiv == 2'd3 || (ldiv == 2'd0 && !is_gour)) lst <= 3'd2;
						else ldiv <= ldiv + 2'd1;
					end
				end
				3'd2: begin
					lcx <= ($signed({lpx0[11], lpx0, 32'd0}) | 45'sh0_8000_0000) - 45'sd1024;
					lcy <= ($signed({lpy0[11], lpy0, 32'd0}) | 45'sh0_8000_0000) - (lsdy < 0 ? 45'sd1024 : 45'sd0);
					lcr <= $signed({1'b0, lc0r, 12'h800}); lcg <= $signed({1'b0, lc0g, 12'h800}); lcb <= $signed({1'b0, lc0b, 12'h800});
					lcnt <= 11'd0;
					lst <= 3'd3;
				end
				3'd3: begin
					px <= {lcx[42], lcx[42:32]}; py <= {lcy[42], lcy[42:32]};
					lst <= 3'd4;
				end
				3'd4: begin
					if (in_area) begin
						wx <= px[9:0]; wy <= py[8:0]; pix_semi <= is_semi;
						wpix <= dither ? {1'b0, dith5(lcb[19:12], px[1:0], py[1:0]), dith5(lcg[19:12], px[1:0], py[1:0]), dith5(lcr[19:12], px[1:0], py[1:0])}
						               : to555(lcr[19:12], lcg[19:12], lcb[19:12]);
						is_tex <= 1'b0;
						ds <= (is_semi || mask_chk) ? D_BLEND : D_WRITE;
					end
					lcx <= lcx + lsdx; lcy <= lcy + lsdy;
					lcr <= lcr + lsr; lcg <= lcg + lsg; lcb <= lcb + lsb;
					lcnt <= lcnt + 11'd1;
					lst <= (lcnt == lk) ? 3'd5 : 3'd3;
				end
				default: begin
					// finished; a polyline goes on from this end, in this end's colour
					rxe <= 0; lst <= 3'd0;
					if (is_poly) begin
						lx0 <= lx1; ly0 <= ly1;
						if (is_gour) begin vr[0] <= vr[1]; vg[0] <= vg[1]; vb[0] <= vb[1]; end
						ds <= D_PLNEXT;
					end else begin busy <= 1'b0; in_line <= 1'b0; ds <= D_IDLE; end
				end
				endcase

			// A polyline's remaining words: a vertex per segment (with a colour first
			// when Gouraud), until a word whose bits 31:28 and 15:12 are both 5.
			// Treating it as one segment left every later vertex to be read as a
			// command, which is how the BIOS's menu screen wedged the engine.
			D_PLNEXT: if ((!f_empty && f_head_ok)) begin
					if ((f_head & 32'hF000_F000) == 32'h5000_5000) begin
						busy <= 1'b0; in_line <= 1'b0; ds <= D_IDLE;
					end else if (pl_col) begin
						vr[1] <= f_head[7:0]; vg[1] <= f_head[15:8]; vb[1] <= f_head[23:16];   // the next end's colour
						pl_col <= 1'b0;
					end else begin
						lx1 <= $signed(f_head[10:0]) + dofs_x; ly1 <= $signed(f_head[26:16]) + dofs_y;
						pl_col <= is_gour;
						ds <= D_LINE; lst <= 3'd0;
					end
				end

			// -------------------------------------------------------------------------------
			// VRAM -> VRAM, halfword at a time (wraps at 1024/512 as the chip does)
			// a row goes in runs of up to 16 pixels, each read in full before any of it is
			// written: a copy one to three pixels to the right of itself then comes out as a
			// clean shifted copy, as on the chip (ps1-tests gpu/vram-to-vram-overlap), where a
			// pixel at a time read back what it had just written and smeared it along the row
			D_COPY: if (cy == ch) begin busy <= 1'b0; ds <= D_IDLE; end
				else if (cx == cw) begin cx <= 0; cy <= cy + 10'd1; end
				else begin
					cn <= ((cw - cx) > 11'd16) ? 5'd16 : (cw - cx);
					ck <= 5'd0;
					e_addr <= vaddr(cxs + cx, cys + cy[8:0]); e_be <= 4'b1111; e_we <= 1'b0; e_req <= 1'b1;
					ds <= D_COPYR;
				end
			D_COPYR: if (v_ack) begin
					cbuf[ck[3:0]] <= half(v_rdata, (cxs + cx + ck) & 1);
					if (ck + 5'd1 < cn) begin
						ck <= ck + 5'd1;
						e_addr <= vaddr(cxs + cx + ck + 5'd1, cys + cy[8:0]); e_req <= 1'b1;
					end else begin
						ck <= 5'd0; ds <= D_COPYB;
					end
				end
			D_COPYB: begin
					e_addr <= vaddr(cxd + cx + ck, cyd + cy[8:0]); e_be <= vbe(cxd + cx + ck);
					e_wdata <= {2{cbuf[ck[3:0]] | {mask_set, 15'd0}}};
					chold <= cbuf[ck[3:0]] | {mask_set, 15'd0};
					if (mask_chk) begin e_we <= 1'b0; e_req <= 1'b1; ds <= D_COPYM; end
					else begin e_we <= 1'b1; e_req <= 1'b1; ds <= D_COPYBW; end
				end
			D_COPYM: if (v_ack) begin
					if (half(v_rdata, (cxd + cx + ck) & 1) & 16'h8000) begin t_skip <= 1'b1; ds <= D_COPYBW; end
					else begin e_wdata <= {2{chold}}; e_we <= 1'b1; e_req <= 1'b1; ds <= D_COPYBW; end
				end
			D_COPYBW: if (t_skip || v_ack) begin
					t_skip <= 1'b0;
					e_we <= 1'b0;
					if (ck + 5'd1 < cn) begin ck <= ck + 5'd1; ds <= D_COPYB; end
					else begin cx <= cx + cn; ds <= D_COPY; end
				end

			// CPU -> VRAM: words arrive through the FIFO, two pixels each
			D_C2V: if (cy == ch) begin busy <= 1'b0; ds <= D_IDLE; end
				else if (cx == cw) begin cx <= 0; cy <= cy + 10'd1; end
				else if (cphase || (!f_empty && f_head_ok)) begin
					// GP0(E6) applies to a transfer as to drawing (ps1-tests gpu/mask-bit): bit 15
					// set on the way in, and a pixel whose destination has it kept
					if (!cphase) cword <= f_head;
					chold <= (cphase ? cword[31:16] : f_head[15:0]) | {mask_set, 15'd0};
					e_addr <= vaddr(cxd + cx, cyd + cy[8:0]); e_be <= vbe(cxd + cx);
					e_wdata <= {2{(cphase ? cword[31:16] : f_head[15:0]) | {mask_set, 15'd0}}};
					if (mask_chk) begin e_we <= 1'b0; e_req <= 1'b1; ds <= D_C2VM; end
					else begin e_we <= 1'b1; e_req <= 1'b1; ds <= D_C2VW; end
				end
			D_C2VM: if (v_ack) begin
					if (half(v_rdata, (cxd + cx) & 1) & 16'h8000) begin t_skip <= 1'b1; ds <= D_C2VW; end
					else begin e_wdata <= {2{chold}}; e_we <= 1'b1; e_req <= 1'b1; ds <= D_C2VW; end
				end
			D_C2VW: if (t_skip || v_ack) begin
					t_skip <= 1'b0;
					e_we <= 1'b0; cx <= cx + 10'd1;
					// an odd-width row ends mid-word; the chip still consumes the word
					cphase <= !cphase;
					if (cx + 10'd1 == cw && cy + 10'd1 == ch) cphase <= 1'b0;
					ds <= D_C2V;
				end

			// VRAM -> CPU: read two pixels into a word the CPU/DMA then collects
			// The next word is not read until the last one has been collected:
			// rd_word is a single register, and running ahead overwrote it --
			// a CPU polling GPUREAD saw one word in a thousand and the rest 0.
			D_V2C: if (rd_have) ;   // wait for GPUREAD / the DMA to take the word -- the last one too
				// an odd number of pixels ends half way through a word: that word goes out too
				// (ps1-tests gpu/mask-bit reads ONE pixel back, and waited for ever for its word)
				else if (cy == ch && cphase) begin
					rd_word <= {16'd0, cword[15:0]}; rd_have <= 1'b1; cphase <= 1'b0;
					n_made  <= n_made + 8'd1;
				end
				else if (cy == ch) begin busy <= 1'b0; rd_pending <= 1'b0; ds <= D_IDLE; end
				else if (cx == cw) begin cx <= 0; cy <= cy + 10'd1; end
				else begin
					e_addr <= vaddr(cxs + cx, cys + cy[8:0]); e_be <= 4'b1111; e_we <= 1'b0; e_req <= 1'b1;
					ds <= D_V2CR;
				end
			D_V2CR: if (v_ack) begin
					if (!cphase) begin cword[15:0] <= half(v_rdata, (cxs + cx) & 1); cphase <= 1'b1; cx <= cx + 10'd1; ds <= D_V2C; end
					else begin
						cword[31:16] <= half(v_rdata, (cxs + cx) & 1);
						cphase <= 1'b0; cx <= cx + 10'd1;
						rd_word <= {half(v_rdata, (cxs + cx) & 1), cword[15:0]};
						rd_have <= 1'b1;
						n_made  <= n_made + 8'd1;
						ds <= D_V2C;
					end
				end

			default: ds <= D_IDLE;
			endcase

			// GP1(00) and GP1(01) throw the command FIFO away, and a command that
			// was half way through its arguments must be thrown away with it.
			// This is applied HERE, after the drawing machine, because both live
			// in this one block and the machine's own assignment to `ds` a few
			// lines above would otherwise win -- the words were discarded and the
			// engine went on waiting for them, which is a game that has stopped
			// dead with the picture it had. libgpu issues GP1(01) routinely.
			if (gp1_abort) begin
				ds     <= D_IDLE;
				busy   <= 1'b0;
				argc   <= 0;
				need   <= 0;
				second <= 1'b0;
				skip   <= 1'b0; t_skip <= 1'b0;
				in_line<= 1'b0;
				rxe    <= 0;
				rd_have    <= 1'b0;
				rd_pending <= 1'b0;
				cphase <= 1'b0;
			end

			// hand a read word to whoever asks
			if (rd_have && (dma_rd || (sel && !we && !a4))) begin
				dma_rdata  <= rd_word;
				dma_rvalid <= dma_rd;
				rd_have    <= 1'b0;
				if (dma_rd) n_dma <= n_dma + 8'd1; else n_cpu <= n_cpu + 8'd1;
			end
			// a GPUREAD with nothing waiting: the reader gets the status word
			if (!rd_have && !dma_rd && sel && !we && !a4) n_empty <= n_empty + 8'd1;
		end
	end

	// --- tasks and functions the engine uses ----------------------------------------------
	task unpack_poly;
		reg g, t, q;
		integer k, idx;
		begin
			g = cmd[4]; t = cmd[2]; q = cmd[3];
			idx = 0;
			for (k = 0; k < 4; k = k + 1) begin
				if (k < (q ? 4 : 3)) begin
					if (k == 0 || g) begin
						vr[k] <= args[idx][7:0]; vg[k] <= args[idx][15:8]; vb[k] <= args[idx][23:16];
						idx = idx + 1;
					end else begin
						vr[k] <= args[0][7:0]; vg[k] <= args[0][15:8]; vb[k] <= args[0][23:16];
					end
					vx[k] <= $signed(args[idx][10:0]) + dofs_x;
					vy[k] <= $signed(args[idx][26:16]) + dofs_y;
					idx = idx + 1;
					if (t) begin
						vu[k] <= args[idx][7:0]; vv[k] <= args[idx][15:8];
						if (k == 0) clut <= args[idx][31:16];
						if (k == 1) begin
							// the texture page rides on the second vertex
							tp_x <= args[idx][19:16]; tp_y <= args[idx][20];
							tp_abr <= args[idx][22:21]; tp_depth <= args[idx][24:23];
							tex_off <= tex_allow && args[idx][27];
						end
						idx = idx + 1;
					end
				end
			end
		end
	endtask

	// attribute `which` (0 r, 1 g, 2 b, 3 u, 4 v) at triangle vertex n
	function [15:0] vi;
		input [2:0] which; input [1:0] n;
		reg [1:0] m;
		begin
			m = second ? n + 2'd1 : n;
			case (which)
			3'd0: vi = {8'd0, vr[m]};
			3'd1: vi = {8'd0, vg[m]};
			3'd2: vi = {8'd0, vb[m]};
			3'd3: vi = {8'd0, vu[m]};
			default: vi = {8'd0, vv[m]};
			endcase
		end
	endfunction

	// d(attr)/dx * area = (a1-a0)(y2-y0) - (a2-a0)(y1-y0), shifted by 16 to keep
	// sixteen fraction bits through the division
	function signed [47:0] gnum_x;
		input [15:0] a0, a1, a2;
		gnum_x = (($signed({1'b0, a1}) - $signed({1'b0, a0})) * (y2 - y0)
		        - ($signed({1'b0, a2}) - $signed({1'b0, a0})) * (y1 - y0)) <<< 16;
	endfunction
	function signed [47:0] gnum_y;
		input [15:0] a0, a1, a2;
		gnum_y = (($signed({1'b0, a2}) - $signed({1'b0, a0})) * (x1 - x0)
		        - ($signed({1'b0, a1}) - $signed({1'b0, a0})) * (x2 - x0)) <<< 16;
	endfunction

	function signed [11:0] min3;
		input signed [11:0] p, q, r;
		min3 = (p < q) ? ((p < r) ? p : r) : ((q < r) ? q : r);
	endfunction
	function signed [11:0] max3;
		input signed [11:0] p, q, r;
		max3 = (p > q) ? ((p > r) ? p : r) : ((q > r) ? q : r);
	endfunction

	// the attribute values at the box corner: vertex 0's, walked by the gradients
	task start_row;
		reg signed [31:0] r0, g0, b0, u0, v0;
		reg signed [11:0] ddx, ddy;
		begin
			ddx = bx0 - x0; ddy = by0 - y0;
			// 8.16 fixed point, like the gradients (16 fraction bits): the
			// attribute's 8 bits belong at [23:16]. vi() is 16 bits wide, and
			// placing it at [23:8] put the vertex colour at 1/256 of itself --
			// every shaded polygon started from black and showed only its
			// gradient (the SCE diamond came out as a black-to-green ramp).
			r0 = {8'd0, vi(0, 0), 8'd0} << 8;
			g0 = {8'd0, vi(1, 0), 8'd0} << 8;
			b0 = {8'd0, vi(2, 0), 8'd0} << 8;
			u0 = {8'd0, vi(3, 0), 8'd0} << 8;
			v0 = {8'd0, vi(4, 0), 8'd0} << 8;
			// ...plus half a step: the chip rounds an interpolated colour or texture
			// coordinate to the nearest, not down (ps1-tests gpu/uv-interpolation: a strip
			// from texel 0 to texel 1 turns to texel 1 half way across, and ours never did)
			r0 = r0 + dr_dx * ddx + dr_dy * ddy + 32'sh8000;
			g0 = g0 + dg_dx * ddx + dg_dy * ddy + 32'sh8000;
			b0 = b0 + db_dx * ddx + db_dy * ddy + 32'sh8000;
			u0 = u0 + du_dx * ddx + du_dy * ddy + 32'sh8000;
			v0 = v0 + dv_dx * ddx + dv_dy * ddy + 32'sh8000;
			rr <= r0; rg_ <= g0; rb <= b0; ru <= u0; rv <= v0;
			cr <= r0; cg <= g0; cb <= b0; cu <= u0; cv <= v0;
		end
	endtask

	// ==================================================================================
	// the pixel pipeline: polygons and rectangles, two pixels a clock (ps1_raster.v)
	// ==================================================================================
	ps1_raster #(.CLK_HZ(CLK_HZ)) u_raster (
		.clk(clk), .rst(rst),
		.start(r_start), .busy(r_busy), .always_in(r_rect),
		.bx0(r_bx0), .bx1(r_bx1), .by0(r_by0), .by1(r_by1),
		.e0_0(r_e0), .e1_0(r_e1), .e2_0(r_e2), .sx0(sx0), .sx1(sx1), .sx2(sx2), .sy0(sy0), .sy1(sy1), .sy2(sy2),
		.apos(area > 0),
		.cr_0(cr), .cg_0(cg), .cb_0(cb), .cu_0(cu), .cv_0(cv),
		.dr_dx(dr_dx), .dg_dx(dg_dx), .db_dx(db_dx), .du_dx(du_dx), .dv_dx(dv_dx),
		.dr_dy(dr_dy), .dg_dy(dg_dy), .db_dy(db_dy), .du_dy(du_dy), .dv_dy(dv_dy),
		.is_gour(is_gour), .is_tex(is_tex), .is_semi(is_semi), .is_raw(is_raw), .dither(dither),
		.fr(vr[0]), .fg(vg[0]), .fb(vb[0]),
		.tp_x(tp_x), .tp_y(tp_y), .tp_abr(tp_abr), .tp_depth(tp_depth), .clut(clut),
		.tw_mx(tw_mx), .tw_my(tw_my), .tw_ox(tw_ox), .tw_oy(tw_oy),
		.no_tcache(no_tcache), .no_ccache(no_ccache), .no_trun(no_trun),
		.da_x0(da_x0), .da_x1(da_x1), .da_y0(da_y0), .da_y1(da_y1), .mask_set(mask_set), .mask_chk(mask_chk),
		.il_skip(il_skip), .il_field(field), .pace(!gpu_fast),
		.v_addr(r_v_addr), .v_req(r_v_req), .v_we(r_v_we), .v_be(r_v_be), .v_wdata(r_v_wdata), .v_around(r_v_around), .v_lin(r_v_lin),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack && r_busy),
		.tx_valid(tx_valid), .tx_addr(tx_addr), .tx_line(tx_line),
		.inv_en(e_req && e_we && v_ack && !r_busy), .inv_line(e_addr[28:4]),
		.st_tex_miss(r_st_tex), .st_dst_miss(r_st_dst), .st_full(r_st_full), .st_clut(r_st_clut)
	);

	// ==================================================================================
	// the display: read the active area once per frame, hand it over as 320 x 240
	// ==================================================================================
	localparam SC_IDLE = 2'd0, SC_RD = 2'd1, SC_WAIT = 2'd2, SC_EMIT = 2'd3;
	reg [1:0]  sc;
	assign scan_busy = (sc != SC_IDLE);   // the engine yields memory while this is up
	reg [9:0]  sx;                  // column in VRAM, relative to disp_x
	reg [8:0]  sy;                  // row
	reg [8:0]  ox;                  // output column
	reg [31:0] sword;
	// The line the scanout is working through. A cache line is 128 bits, four of
	// these words, and the scan walks straight along it -- so asking the cache
	// four separate times for the same line is three accesses wasted. At one
	// word at a time a frame took 20.3 ms to read, longer than the 16.7 ms the
	// console takes to draw one, which meant the picture could never be read
	// before the machine swapped buffers and drew over what was being read.
	// That is where the tearing came from.
	reg [127:0]  sline;
	reg [24:0]   sline_tag;
	reg          sline_v;
	reg [1:0]  step;                // VRAM columns per output column
	reg [1:0]  substep;
	// Where the picture is, as it was when this frame's scan began. The BIOS
	// shows one buffer while it draws the next and swaps between them, so
	// reading the live registers row by row put the top of the frame in one
	// buffer and the bottom in the other -- a picture that jumped every frame.
	reg [9:0]  sc_x;
	reg [8:0]  sc_y;
	reg [9:0]  sc_w, sc_lines;
	// ROWS THE GAME NEVER DRAWS ARE SENT BLACK. They keep whatever VRAM held
	// before them, and the two buffers of a double-buffered game hold different
	// leftovers there -- so, captured at every flip, those rows flash between two
	// pictures. Crash draws y 12..227 of a 240-line display: rows 0..11 (a strip
	// of garbled glyphs) and 228..239 (a LOADING bar left from an earlier screen)
	// alternated on the board 2026-09-27, everything else was steady. A TV's
	// overscan hides them; a capture must blank them. (This existed on 2026-09-25
	// and came out when the design stopped fitting.)
	// The bound is the rows the engine actually WROTE since the last flip -- the
	// drawing area was tried then and is not tight enough, the game sets a
	// full-screen clip at some point in a frame. Rows at or past 240 are left out,
	// so uploading a texture below the framebuffers cannot widen it. Applied only
	// to a capture started by a flip: the BIOS draws in place and is left alone.
	reg [8:0]  wr_lo, wr_hi;        // rows the engine wrote since the last flip
	reg [8:0]  sc_ylo, sc_yhi;      // ...as they stood for the buffer on screen
	reg        sc_crop;             // this capture blanks outside them
	reg        sc_lmode;      // this frame is being taken a line at a time
	reg        sc_ldec;       // ...and every other pixel is dropped, so two make one
	reg [63:0] fl_half;       // the first of a pair, already thinned
	reg        fl_half_v;
	// 24-bit colour (GP1(08h) bit 4), the way movies are shown: pixel n is the three bytes at
	// byte 3n of the row -- red, green, blue -- so two VRAM columns make each one, and every other
	// pixel starts in the column the last one ended in. Read here as 16-bit pixels, a movie was
	// colour noise on the screen (Gran Turismo 2's intro).
	reg        sc_24;         // this capture is of a 24-bit picture
	reg        ph24;          // ...the second column of the pixel is next
	reg [15:0] hw24;          // ...the first column, in hand
	reg [9:0]  ox24;          // ...the pixel

	// every other pixel of a VRAM line: four of the eight, in order
	function [63:0] thin4;
		input [127:0] l;
		thin4 = {l[6*16 +: 16], l[4*16 +: 16], l[2*16 +: 16], l[0*16 +: 16]};
	endfunction
	reg        sc_v480;

	function [7:0] rgb332;
		input [15:0] p;
		rgb332 = {p[4:2], p[9:7], p[14:13]};
	endfunction

	// How many rows the display actually shows: the vertical range GP1 $07
	// sets, in lines -- the BIOS asks for fewer than 240, and the rows below
	// that are VRAM nobody draws, which on a real TV are simply not scanned.
	// A frame that shows them shows garbage under the picture.
	wire [9:0] vr_lines   = vrange1 - vrange0;
	wire [9:0] disp_lines = vres480 ? {vr_lines[8:0], 1'b0} : vr_lines;
	// the horizontal resolution, in VRAM columns
	assign disp_v480 = vres480;
	assign disp_w = hres368 ? 10'd368 : (hres == 2'd0) ? 10'd256 : (hres == 2'd1) ? 10'd320 : (hres == 2'd2) ? 10'd512 : 10'd640;

	// where the next pixel pair lives
	reg         sc_field;     // the field this capture reads (480i: the one on screen)
	// A 480-line picture is captured whole now -- both fields, 480 rows -- and a wide one at full
	// width: HDMI shows 640 x 480 1:1. One field (every other row) and every other column was
	// what the old network stream could carry, and it left a quarter of each glyph of a
	// high-resolution menu (Gran Turismo 2's, 512 x 480i): unreadable.
	// ...except interlaced with the GPU drawing one field a frame (il_skip): then the rows of the
	// field NOT on screen are being drawn while it shows, and a pass over all 480 read them half
	// drawn -- the top of Gran Turismo 2's menu fine, the lower part broken, lines of the PS logo
	// out of place. So each capture is the field on screen (stable: the GPU does not touch it),
	// its rows only, into rows 2k + field; the next field's capture fills in the others (weave).
	reg         sc_il;
	wire [8:0]  out_y   = sc_il ? {sy[7:0], sc_field} : sy;
	assign cap_weave = sc_il;
	assign cap_field = sc_field;
	wire [8:0]  sc_last = (sc_v480 && !sc_il) ? 9'd479 : 9'd239;
	wire [28:0] s_next = vaddr(sc_x + sx, sc_y + out_y);
	wire [8:0]  src_y   = sc_y + out_y;
	wire        row_lit = disp_on && ({1'b0, out_y} < sc_lines)
	                      && (!sc_crop || (src_y >= sc_ylo && src_y <= sc_yhi));
	// every write the engine makes, and the picture row it lands on
	wire [8:0]  wr_y    = v_addr[19:11];
	// Rows under 240 only (so textures below a y=0 buffer cannot widen it), and the flip keeps
	// only those inside the window it shows: a buffer shown at y=256 was cropped to whatever had
	// been drawn up above it -- rows never on screen -- and came out black. Gran Turismo 2 shows
	// its movies at y=256. (Counting every row instead cropped a buffer to rows drawn in the SAME
	// rows of another buffer beside it: the crop knows rows, not columns.)
	wire        wr_go   = v_req && v_we && v_ack && (wr_y < 9'd240);
	wire [9:0]  dwin_hi = {1'b0, disp_y} + (vres480 ? 10'd479 : 10'd239);
	wire [8:0]  dwin_h9 = dwin_hi[9] ? 9'd511 : dwin_hi[8:0];
	// A wide picture is captured at half width -- every other column -- so the
	// odd columns were being walked one at a time to emit nothing at all: 256
	// clocks a row, 61,440 a capture, 23% of it, spent stepping past pixels the
	// capture does not want. The step skips them.
	wire [9:0]  sx_step = 10'd1;
	// the 24-bit pixel in hand: an even one starts on a column's low byte, an odd one on its high
	wire [15:0] h24b = half(sword, (sc_x + sx) & 1);
	wire [7:0]  r24  = !ox24[0] ? hw24[7:0]  : hw24[15:8];
	wire [7:0]  g24  = !ox24[0] ? hw24[15:8] : h24b[7:0];
	wire [7:0]  b24  = !ox24[0] ? h24b[7:0]  : h24b[15:8];
	// ...and where the one after that lives, so SC_EMIT can tell whether it is
	// inside the line already in hand.
	wire [28:0] s_after = vaddr(sc_x + sx + sx_step, sc_y + out_y);

	always @(posedge clk) begin
		if (rst) begin sc <= SC_IDLE; s_req <= 1'b0; px_valid <= 1'b0; sx <= 0; sy <= 0; ox <= 0; fpx_valid <= 1'b0; scan_start <= 1'b0; scan_done <= 1'b0; scan_abort <= 1'b0; arm_ticks <= 2'd0; want_scan <= 1'b1; flip_pend <= 1'b0; flip_alt <= 1'b0; flips_recent <= 2'd0; disp_x_d <= 0; disp_y_d <= 0; sc_abort <= 1'b0; fl_valid <= 1'b0; sc_lmode <= 1'b0; sc_ldec <= 1'b0; fl_half_v <= 1'b0;
		               sc_x <= 0; sc_y <= 0; sc_w <= 10'd320; sc_lines <= 10'd240; sc_v480 <= 1'b0; sc_field <= 1'b0; sc_il <= 1'b0;
		               wr_lo <= 9'd511; wr_hi <= 9'd0; sc_ylo <= 9'd0; sc_yhi <= 9'd511; sc_crop <= 1'b0;
		               sline_v <= 1'b0; sline_tag <= 25'd0; sline <= 128'd0; end
		else begin
			if (!scan_enable || sc != SC_IDLE) arm_ticks <= 2'd0;
			else if (swap_done && arm_ticks != 2'd3) arm_ticks <= arm_ticks + 2'd1;
			// a new frame is owed a capture; taking one clears the debt
			if (frame_tick) want_scan <= 1'b1;
			else if (scan_start) want_scan <= 1'b0;
			// a flip is good until the next vertical sync; a flip seen this clock
			// wins over the clearing
			if (frame_tick) begin flip_pend <= 1'b0; if (flips_recent != 2'd0) flips_recent <= flips_recent - 2'd1; end
			if (scan_start) flip_pend <= 1'b0;
			disp_x_d <= disp_x; disp_y_d <= disp_y;
			if (disp_x != disp_x_d || disp_y != disp_y_d) begin
				// EVERY OTHER FLIP, not every one. Measured on the board with a
				// game running: a capture takes about 35 ms and the game flips
				// every 33.3, so a capture ALWAYS spanned a flip and about two
				// frames in ten came off the wire visibly torn -- the same
				// picture doubled and offset. The scanout was busy 70% of ALL
				// clocks, a third of that held waiting for the network to drain
				// it, and every one of those clocks is VRAM the drawing engine
				// did not get. Taking one flip in two gives a capture 66 ms
				// instead of 33 and halves what it takes from the game; the
				// page cannot show more than it already receives anyway.
				flip_alt <= ~flip_alt;
				flips_recent <= 2'd3;
				// the buffer just flipped to was drawn over the interval that has
				// just ended, so the rows written over it are exactly its bound
				// (an empty overlap -- lo past hi -- means no crop: nothing drawn there was seen)
				sc_ylo <= (wr_lo > disp_y)  ? wr_lo : disp_y;
				sc_yhi <= (wr_hi < dwin_h9) ? wr_hi : dwin_h9;
				wr_lo  <= 9'd511; wr_hi <= 9'd0;
				if (flip_alt || every_flip) begin
					flip_pend <= 1'b1;
					if (sc != SC_IDLE) sc_abort <= 1'b1;
				end
			end
			if (!(disp_x != disp_x_d || disp_y != disp_y_d) && wr_go) begin
				if (wr_y < wr_lo) wr_lo <= wr_y;
				if (wr_y > wr_hi) wr_hi <= wr_y;
			end
			fpx_valid  <= 1'b0;
			fl_valid   <= 1'b0;
			scan_start <= 1'b0;
			il_field_d <= field;
			if (field != il_field_d) il_fresh <= 1'b1;            // the field has just turned
			else if (rc_y == 9'd40) il_fresh <= 1'b0;             // ...too long ago to start now
			scan_done  <= 1'b0;
			scan_abort <= 1'b0;
			// s_req is held, not pulsed, for the same reason v_req is: the cache
			// only takes a request while idle, and while the draw engine has it
			// a one-cycle pulse is simply missed -- the scanout then waits in
			// SC_WAIT for an ack that never comes, and the picture is whatever
			// the framebuffer held before the display came on. Forever.
			if (s_ack) s_req <= 1'b0;
			px_valid <= 1'b0;
			case (sc)
			// The scanout reads all of VRAM once a frame -- 19200 DDR3 lines, which
			// on a controller that does one access a microsecond is the whole
			// budget. With the frame in DDR3 nothing needs it unless a capture is
			// armed, so it runs only then and the drawing engine gets the memory.
			// a capture starts at a vertical sync where nothing is being drawn and
			// nothing is queued: a frame taken while the BIOS is still drawing into
			// it is torn, and torn frames one after another look like flicker
			// ...so a capture starts when the engine and its queue are idle, at
			// any point in the frame; if that never happens (the machine keeps the
			// GPU busy across frames) it goes on the third vertical sync anyway,
			// so the page always gets a picture
			// frame_len is zero until a whole frame has gone by -- and in a
			// testbench that may never happen -- so fall back to taking one
			// whenever nothing is being drawn.
			SC_IDLE: if (scan_enable && want_scan
			          && (flip_pend                // a double-buffered game: at its flip, and only then
			              || flips_recent == 2'd0 && (
			                 il_skip && il_fresh && (field != il_last)   // 480i: as each field turns, the fields in turn
			              || !il_skip && (!busy && f_empty && !dma_active)
			              && (frame_len == 20'd0 || post_vsync >= capture_at)
			              || !il_skip && (frame_len != 20'd0 && post_vsync >= late_at
			                  && (arm_ticks == 2'd3 || cap_every_vsync))))) begin
					sc_field <= field; sc_il <= il_skip; sc_abort <= 1'b0;
					il_fresh <= 1'b0; il_last <= field;
					sc_crop  <= flip_pend && !vres480 && (sc_ylo <= sc_yhi);   // (the bounds are rows under 240)   // a flipping game, and it drew something
					sx <= 0; sy <= 0; ox <= 0; substep <= 0;
					step <= (hres == 2'd0) ? 2'd1 : (hres == 2'd1) ? 2'd1 : 2'd2;   // 256/320 -> 1:1, 512/640 -> 2:1
					sc_x <= disp_x; sc_y <= disp_y; sc_w <= disp_w;
					// decided once, for the whole frame
					sc_24 <= bpp24; ph24 <= 1'b0; ox24 <= 10'd0;
					sc_lmode  <= scan_lines && !bpp24 && (disp_x[2:0] == 3'd0)
					             && ((disp_w <= 10'd320) ? (disp_w[2:0] == 3'd0)
					                                     : (disp_w[3:0] == 4'd0));
					sc_ldec   <= 1'b0;                  // (full width: no thinning)
					fl_half_v <= 1'b0;
					sc_lines <= disp_lines; sc_v480 <= vres480;
					sline_v  <= 1'b0;
					scan_start <= 1'b1;
					sc <= SC_RD;
				end
			SC_RD: if (sc_abort) begin sc <= SC_IDLE; sc_abort <= 1'b0; scan_abort <= 1'b1; want_scan <= 1'b1; sline_v <= 1'b0; fl_half_v <= 1'b0; end
				else if (!scan_hold) begin
					// a 480-line picture is captured one field at a time: every other row
					// (a whole-line frame moves eight pixels at a time, so the line it
					// already holds is never the one it wants next)
					if (!sc_lmode && sline_v && (s_next[28:4] == sline_tag)) begin
						sword <= sline[s_next[3:2]*32 +: 32];   // already in hand
						sc    <= SC_EMIT;
					end else begin
						s_addr <= s_next;
						s_req  <= 1'b1;
						sc <= SC_WAIT;
					end
				end
			SC_WAIT: if (s_ack) begin
					sword     <= s_rdata;
					sline     <= s_line;
					sline_tag <= s_addr[28:4];
					sline_v   <= 1'b1;
					if (sc_lmode) begin
						if (!sc_ldec) begin
							// eight pixels, straight out, in the bytes they arrived in
							fl_valid <= 1'b1;
							fl_data  <= row_lit ? s_line : 128'd0;
							fl_x     <= sx;
							fl_y     <= out_y;
						end else if (!fl_half_v) begin
							// first of a pair: thinned and held
							fl_half   <= row_lit ? thin4(s_line) : 64'd0;
							fl_half_v <= 1'b1;
						end else begin
							// second of the pair completes one output line
							fl_valid  <= 1'b1;
							fl_data   <= {row_lit ? thin4(s_line) : 64'd0,
							              fl_half};
							fl_x      <= (sx - 10'd8) >> 1;
							fl_y      <= out_y;
							fl_half_v <= 1'b0;
						end
						if (sx + 10'd8 >= sc_w) begin
							sx <= 0; ox <= 0; substep <= 0; fl_half_v <= 1'b0;
							if (sy == sc_last) begin sc <= SC_IDLE; scan_done <= 1'b1; end
							else begin sy <= sy + 9'd1; sc <= SC_RD; end
						end else begin
							sx <= sx + 10'd8;
							sc <= SC_RD;
						end
					end else
						sc <= SC_EMIT;
				end
			SC_EMIT: if (sc_abort) begin sc <= SC_IDLE; sc_abort <= 1'b0; scan_abort <= 1'b1; want_scan <= 1'b1; sline_v <= 1'b0; fl_half_v <= 1'b0; end
				else if (sc_24) begin
					if (!ph24) begin
						// the pixel's first column; the second is the next one
						hw24 <= h24b; ph24 <= 1'b1;
						sx <= sx + 10'd1;
						if (!scan_hold && sline_v && (s_after[28:4] == sline_tag)) sword <= sline[s_after[3:2]*32 +: 32];
						else sc <= SC_RD;
					end else begin
						begin
							fpx_valid <= 1'b1;
							fpx_x <= ox24; fpx_y <= out_y;
							fpx_rgb <= row_lit ? {1'b0, b24[7:3], g24[7:3], r24[7:3]} : 16'd0;
						end
						ph24 <= 1'b0;
						if (ox24 + 10'd1 >= sc_w) begin
							ox24 <= 10'd0; ox <= 0; sx <= 0; substep <= 0;
							if (sy == sc_last) begin sc <= SC_IDLE; scan_done <= 1'b1; end else begin sy <= sy + 9'd1; sc <= SC_RD; end
						end else begin
							ox24 <= ox24 + 10'd1;
							// an odd pixel ends on its second column's high byte: the next starts a
							// column on; an even one ends on its low byte: the next starts right there
							if (ox24[0]) begin
								sx <= sx + 10'd1;
								if (!scan_hold && sline_v && (s_after[28:4] == sline_tag)) sword <= sline[s_after[3:2]*32 +: 32];
								else sc <= SC_RD;
							end
						end
					end
				end else begin
					// every pixel, full width, to the frame in DDR3
					// a 512/640-wide picture is captured at half width (every other
					// pixel): the frame crosses the register link at about 1 MB/s, so
					// 300 KB was six frames a second and 150 KB is twelve or more
					if (sx < sc_w) begin
						// Always, even with the display off: the frame streamer waits
						// on these, and a blanked display used to starve it. Black is
						// what a blanked display shows anyway.
						fpx_valid <= 1'b1;
						fpx_x <= sx; fpx_y <= out_y;
						fpx_rgb <= row_lit ? half(sword, (sc_x + sx) & 1) : 16'd0;
					end
					// two pixels per word; emit those that land on output columns
					// (with the step skipping the odd columns, every pixel the
					// capture takes is one output column)
					if (ox < 9'd320 && substep == 2'd0) begin
						px_valid <= disp_on && (sy < 9'd240);   // (the old 320 x 240 preview)
						px_x <= ox; px_y <= sy;
						px_rgb <= ({1'b0, sy} < sc_lines) ? rgb332(half(sword, (sc_x + sx) & 1)) : 8'd0;
						ox <= ox + 9'd1;
					end
					substep <= (substep + 2'd1 == step) ? 2'd0 : substep + 2'd1;
					sx <= sx + sx_step;
					// The row ends where the PICTURE ends. It used to run on until
					// the low-resolution preview had 320 columns, which for a
					// 512-wide game meant reading 640 VRAM columns for a 512-wide
					// display: 80 lines a row instead of 64, a quarter of the
					// capture spent on columns outside the window -- and for a
					// double-buffered game those columns are the OTHER buffer.
					// The capture has to fit inside one of the machine's frames or
					// it reads a buffer the game has started drawing into again,
					// and measured on the board 2026-09-26 it does not: 18.67 ms
					// against a frame of 16.62. This is a quarter of that, free.
					// The preview a 512-wide game leaves in the register-bus
					// framebuffer is 256 columns wide now instead of 320; the page
					// takes the picture off the network and never reads it.
					if (sx + sx_step >= sc_w || sx >= 10'd640 + 10'd2) begin
						// next row
						ox <= 0; sx <= 0; substep <= 0;
						if (sy == sc_last) begin sc <= SC_IDLE; scan_done <= 1'b1; end else begin sy <= sy + 9'd1; sc <= SC_RD; end
					// The line in hand is EIGHT pixels. Going back through SC_RD
					// between them spent a clock a pixel asking a question already
					// answered -- the tag is the one just read. Take the next word
					// straight out of it and stay here. SC_RD is then entered once
					// a line instead of once a word.
					end else if (!sc_lmode && !scan_hold && sline_v && (s_after[28:4] == sline_tag))
						sword <= sline[s_after[3:2]*32 +: 32];
					else
						sc <= SC_RD;
				end
			endcase
		end
	end

	// ==================================================================================
	// the register read side
	// ==================================================================================
	always @(*) begin
		rdata = a4 ? gpustat : (rd_have ? rd_word : info_word);
	end

	// draw-engine state, for finding where a command list stalls: whether the
	// display is on, whether the engine is busy, which state, and the scan
	// position -- a rasteriser that is stuck shows the same (px, py) forever,
	// one that is merely slow shows them sweeping.
	assign dbg_gpu  = {disp_on, busy, ds[5:0], cmd[7:0], argc[3:0], f_count[11:0]};   // fits 32 bits: the count is capped for display
	assign dbg_gpu2 = cmd_hist;
	assign dbg_pop = f_pop; assign dbg_popword = f_head; assign dbg_pophead = f_pop && (ds == D_IDLE);
	assign dbg_in_v    = f_push || (wr_r && a4_r);
	assign dbg_in_type = f_push ? {1'b0, dma_wr} : 2'd2;
	assign dbg_in_word = f_push ? f_in : wdata_r;

	// what is shown versus what is drawn: if these never meet, the screen is static
	assign dbg_disp = {disp_on, hres, vres480, interlace, 1'b0, disp_y, 7'd0, disp_x};
	assign dbg_draw = {da_y0, da_x0, 4'd0, dofs_y[10:2]};

endmodule

`default_nettype wire
