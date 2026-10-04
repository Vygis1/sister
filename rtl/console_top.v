//////////////////////////////////////////////////////////////////////////////////
// console_top.v - the slot, the cartridge and whichever console is plugged in.
//
// Was nes_top.v. Renamed because the NES is now one core behind a contract
// rather than the only thing here.
//
// --- the console contract ---------------------------------------------------
//
// A core is anything that can be handed a clock enable and a cartridge and
// produce a picture:
//
//   in    clk, rst, ce          ce is the core's native pixel/dot rate
//   in    joy1, joy2            one bit per button, the core decides the order
//   out   px, py, pixel_en      where the next pixel goes
//   out   frame_start           one pulse per frame, for the frame counter
//   out   prog_addr / in prog_din   code fetch, into the shared cartridge
//   out   char_addr / in char_din   tile fetch, for cores that have one
//
// Colour is deliberately NOT part of the contract as an index. Each core
// resolves its own palette and this file takes RGB332, because the two machines
// disagree about what a palette even is: the NES has 64 fixed colours chosen by
// the silicon, the Master System has a writable one. Making the contract "a
// colour" rather than "an index into something" is what stops the second
// console leaking its palette model into the first.
//
// Only one core runs at a time. That is not a simplification -- there is one
// cartridge slot, and the block RAM for a second cartridge does not exist.
//
// Register map (page 0x0008):
//   0x00  ID      "NE"
//   0x04  CTRL    bit 0 run, bit 1 vertical mirroring
//   0x08  JOY1    bit 0 A, 1 B, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right
//   0x0C  JOY2
//   0x10  FRAME   frames rendered since reset
//   0x14  PC      the running core's program counter
//   0x18  NMI     how many times the video chip has interrupted the CPU
//   0x1C  MAPPER  iNES mapper number, and (PRG size / 8 kB) - 1 in bits 13:8
//   0x20  CONSOLE bits 3:0 selected core, bits 19:16 which cores are built in
//
//   0x0009-0x000C  cartridge code,  256 kB
//   0x000D-0x000E  cartridge tiles, 128 kB
//
// A bus page is 64 kB, so a cartridge bigger than that spans several and the
// host just keeps writing; the page number is the top of the address.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module console_top #(
	parameter PROG_AW = 18,
	parameter CHAR_AW = 17,

	// Which machines this bitstream contains. The point of the shell is that a
	// core gets the WHOLE chip rather than sharing it, so a shipped image has
	// exactly one of these set. Both is still useful during development -- it
	// is one JTAG load instead of a flash install and a reconfiguration -- and
	// costs nothing except the space it obviously costs.
	parameter CORE_NES = 1,
	parameter CORE_SMS = 1,
	// The Mega Drive. Its cartridge does not live in cart_mem with the other
	// two -- it is behind cart_cache, which wants 128-bit lines because it was
	// written against DDR3. md_cart answers that shape out of block RAM until
	// the memory controller exists.
	parameter CORE_MD  = 0,
	// Words of 32 bits in that cartridge. 15 bits is 128 kB, which is what can
	// be spared once the framebuffer, VRAM and work RAM have taken theirs.
	parameter MD_AW    = 15,
	// Where the Mega Drive's cartridge lives. 0 keeps it in block RAM, capped
	// at MD_AW words and therefore at 128 kB; 1 puts it in DDR3, where a real
	// cartridge fits. The interface either side of it is identical, which is
	// the whole reason cart_cache was given a line interface.
	parameter MD_DDR3  = 0,
	// The PlayStation. Its own image; shares the DDR3 port the Mega Drive uses
	// for its cartridge (never both in one bitstream), where it keeps 1 MB of
	// VRAM. Draws its boot screen from a pre-loaded program.
	parameter CORE_PS1 = 0,
	// The Nintendo 64 (n64_top.v). Its own image, like the PlayStation's; RDRAM
	// and the cartridge are in DDR3.
	parameter CORE_N64 = 0
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,              // one NES PPU dot

	// register slave
	input  wire [15:0] off,
	input  wire [9:0]  con_index,       // word index into the Z80's output buffer
	output wire [31:0] con_rdata,
	input  wire [PROG_AW-3:0] prog_windex,
	// The Mega Drive's cartridge is its own memory, so its host index must not
	// be sized from PROG_AW -- that is the width of a memory this core does not
	// use, and tying the two together made a Mega Drive build ask for bits of
	// an index that had been shrunk out from under it.
	// 22 bits of 32-bit words: 16 MB of cartridge. The old 16-bit index reached
	// 256 kB, which was the block RAM ceiling anyway; a DDR3 cartridge is not
	// bounded by that and the index must not be the new limit.
	input  wire [21:0]        md_windex_full,
	input  wire [15:0]        md_windex,
	input  wire [CHAR_AW-3:0] char_windex,
	// the ESP32's SPI wires (the PlayStation's disc comes over them; see cd_feed.v)
	input  wire        esp_sclk,
	input  wire        esp_mosi,
	output wire        esp_miso,
	input  wire        esp_cs_n,
	input  wire        ctrl_we,
	// the frame streamer (net_core): its settings live here, its frame-done comes back
	output wire        stream_en,
	output wire [15:0] stream_port,
	output wire [31:0] stream_base,
	output wire [17:0] stream_words,
	output wire [15:0] stream_rowlen,
	output wire [15:0] stream_stride,
	output wire        stream_ready,
	input  wire        stream_done_tog,
	output wire        stream_direct,
	output wire [31:0] stream_fdata,
	output wire        stream_fvalid,
	input  wire        stream_frd,
	// Raised by the host when the last word of a cartridge has been written.
	// A DDR3 cartridge gathers four host words into a line, so without this the
	// tail of every image that is not a multiple of sixteen bytes stays in the
	// buffer and never reaches memory.
	input  wire        fill_end,
	input  wire        prog_we,
	input  wire        char_we,
	input  wire [31:0] wdata,
	// --- out to DDR3, when the cartridge lives there --------------------------
	output wire [23:0]  d_addr,
	output wire         d_req,
	output wire         d_we,
	output wire [127:0] d_wdata,
	output wire [15:0]  d_wmask,
	input  wire         d_ready,
	input  wire [127:0] d_rdata,
	input  wire         d_valid,
	input  wire         d_calibrated,

	output reg  [31:0] ctrl_rdata,
	output wire [31:0] prog_rdata,
	output wire [31:0] char_rdata,

	// sound, for the ring buffer the synth already streams from
	output wire [15:0] audio,
	// ...and the PlayStation's, which is stereo at 44.1 kHz and has a ring of its
	// own (ps1_aring.v): {right, left}, signed, one pulse of audio_lr_we a sample
	output wire [31:0] audio_lr,
	output wire        audio_lr_we,

	// pixels for the framebuffer
	output wire        px_valid,
	output wire [8:0]  px_x,
	output wire [8:0]  px_y,
	output wire [7:0]  px_rgb,

	// the display frame in DDR3 (PlayStation): a word of it, with a wait
	input  wire [17:0] fbr_addr,
	input  wire        fbr_req,
	output wire [31:0] fbr_rdata,
	output wire        fbr_ack,
	// the picture for HDMI: hdmi_tx asks for a pixel a clock ahead, in its pixel clock
	input  wire        pclk,
	input  wire [9:0]  vid_x,
	input  wire [9:0]  vid_y,
	input  wire        vid_req,
	output wire [23:0] vid_rgb
);

	// Which cores this bitstream actually contains. The host reads this rather
	// than assuming, so a build without a given core reports that honestly
	// instead of selecting it and showing a black screen.
	localparam [3:0] CONSOLE_NES = 4'd0;
	localparam [3:0] CONSOLE_SMS = 4'd1;
	localparam [3:0] CONSOLE_MD  = 4'd2;
	localparam [3:0] CONSOLE_PS1 = 4'd3;
	localparam [3:0] CONSOLE_N64 = 4'd4;
	// Read by the host rather than assumed, so a build without a given core
	// reports that honestly instead of selecting it and showing a black screen.
	localparam [7:0] CORES_BUILT = (CORE_NES ? 8'b0000_0001 : 8'd0)
	                             | (CORE_SMS ? 8'b0000_0010 : 8'd0)
	                             | (CORE_MD  ? 8'b0000_0100 : 8'd0)
	                             | (CORE_PS1 ? 8'b0000_1000 : 8'd0)
	                             | (CORE_N64 ? 8'b0001_0000 : 8'd0);

	// Which core is selected out of reset: the first one this image actually
	// contains.
	//
	// This used to be CONSOLE_NES unconditionally, which is right for the only
	// build that existed at the time and wrong for every other. A Master System
	// image came up with the NES selected -- a core that is not in the bitstream
	// -- so nothing ran and the screen stayed black, while the register map
	// cheerfully reported "built: Master System, running: NES".
	//
	// The write path already refuses a core that is not built. The reset value
	// went around that check rather than through it.
	localparam [3:0] CONSOLE_FIRST = CORE_NES ? CONSOLE_NES
	                               : CORE_SMS ? CONSOLE_SMS
	                               : CORE_MD  ? CONSOLE_MD
	                               : CORE_PS1 ? CONSOLE_PS1
	                               : CORE_N64 ? CONSOLE_N64
	                                          : CONSOLE_NES;

	wire [15:0] dbg_pc;
	wire        dbg_nmi;
	reg  [31:0] nmi_count;

	// Up here rather than next to the Z80 itself, because the cartridge address
	// mux and the register read mux both come before it and synthesis will
	// accept a forward reference that the simulator's parser will not.
	wire [7:0]  nes_chr_dout;
	wire        nes_chr_we;

	// Up here with the other forward declarations, and for the same reason: the
	// register read mux and the pixel mux both come before the Mega Drive's own
	// section, and xsim refuses a reference to a signal declared later while
	// Vivado accepts it. Declaring these at the point of use builds a bitstream
	// and stops the testbenches compiling, which is the worst way round.
	wire         md_px_valid;
	wire [8:0]   md_px_x, md_px_y;
	wire         ps1_px_valid;
	wire [8:0]   ps1_px_x, ps1_px_y;
	wire [7:0]   ps1_px_rgb;
	wire [31:0]  ps1_dbg_pc;
	wire [31:0]  ps1_dbg_io_addr, ps1_dbg_io_data, ps1_dbg_gpu_wr;
	wire [31:0]  ps1_dbg_mem, ps1_dbg_daddr, ps1_dbg_irq, ps1_dbg_gpu_st;
	wire [31:0]  ps1_dbg_cause, ps1_dbg_epc, ps1_dbg_dma, ps1_dbg_gpu2, ps1_dbg_disp, ps1_dbg_draw;
	wire [31:0]  ps1_dbg_v2c, ps1_dbg_c0, ps1_dbg_perf;
	wire [15:0]  ps1_d_wmask;
	wire [15:0]  n64_d_wmask;
	wire [31:0]  n64_vi_status, n64_vi_origin, n64_vi_width, n64_vi_yscale, n64_dbg_pc, n64_retired;
	wire [31:0]  n64_dbg_q;                 // the N64's debug window (n64_top.v), shown at 0x174
	wire [17:0]  n64_fb_words;
	wire [15:0]  n64_fb_wpr;
	wire         n64_fb_halve;
	assign d_wmask = (CORE_PS1 != 0) ? ps1_d_wmask : (CORE_N64 != 0) ? n64_d_wmask : 16'hFFFF;
	reg  [5:0]   perf_sel;   // 64 now: the drawing engine, and where in a frame it is busy
	// --- the debug switches, TIED OFF ----------------------------------------
	// Each of these kept a second implementation alive so the two could be
	// compared on the board: the instruction cache, the instruction buffer, the
	// cache self-check, the non-overlapped fetch, the texture and palette
	// caches, the texture run, the capture's cache priority, and four separate
	// GTE behaviours. Every one of those questions is settled -- the GTE matches
	// real hardware on 2,000 fuzz cases, and the caches are all worth keeping --
	// and the duplicates are not free: the gte_old pair alone muxes 44- and
	// 64-bit arithmetic, and the part is at 100.00% of its slices, which is why
	// the instruction-fetch run misses timing by 0.342 ns on a path that is 76%
	// ROUTING. Constants here, so synthesis deletes the halves nobody uses.
	//
	// To bring one back for a measurement: make it a reg again and restore its
	// bit in the ctrl 0xEC write below. Bits 8..11, 14..17 and 20..23 are free.
	wire         no_icache = 1'b0, no_ibuf = 1'b0, ic_verify = 1'b0, no_overlap = 1'b0;
	wire         no_tcache = 1'b0, no_ccache = 1'b0, no_trun = 1'b0, no_capfirst = 1'b0;
	wire [3:0]   gte_old   = 4'd0;
	// ctrl 0xEC bit 12 holds the CPU to the console's 33.8688 MHz; clear (the
	// default) it runs on every 50 MHz clock. The console's timers, video and
	// sound keep the console's clock either way. The default is the board's
	// clock because this CPU is slower than the R3000 per clock -- a load takes
	// three where the chip's takes one -- and at the console's clock Crash's
	// levels ran at 20 fps where the console's run at 30 (measured 2026-09-28:
	// 35 ms of work a frame against a 33.3 ms frame). Inverted so that the many
	// tools that write this register with only a counter number in it leave
	// the pace alone. Bit 13 lets the drawing engine past the chip's fill rate.
	reg          cpu_pace = 1'b0, gpu_fast = 1'b0;
	wire         cpu_fast = !cpu_pace;
	reg          dma_relax = 1'b0;                              // ctrl 0xEC bit 14: see ps1_top
	reg  [5:0]   ev_idx = 6'd0;
	// the PlayStation's memory card: ctrl 0x134 {fill aimed at the card, card in},
	// 0x138 the queue of sectors it has stored (see ps1_sio.v / pc/server.py)
	reg          card_in = 1'b0, card_fill = 1'b0, card2_in = 1'b0, card2_fill = 1'b0;
	wire [10:0]  card_wq_sector; wire [4:0] card_wq_count; wire card_wq_ovf;
	wire         card_wq_pop = ctrl_we && (off == 16'h0138) && wdata[0];
	wire         card_wq_clr = ctrl_we && (off == 16'h0138) && wdata[31];
	// the PlayStation's CD audio:
	//   0x5000-0x53FC  the table of contents, a word per entry (ps1_cdrom.v toc_*)
	//   0x6000-0x6FFC  XA samples decoded on the PC: every write is the next one
	//   0x013C  read {waiting[31:27], 0, lba[23:0]} of the oldest XA sector to
	//           decode; write bit 0 pops it
	//   0x0140  read {flushes[31:24], 0, samples in the FIFO[12:0]}
	wire         toc_we   = ctrl_we && (off[15:12] == 4'h5) && (off[11:10] == 2'b00);
	wire [7:0]   toc_addr = off[9:2];
	wire         xa_we    = ctrl_we && (off[15:12] == 4'h6);
	wire         xa_pop   = ctrl_we && (off == 16'h013C) && wdata[0];
	wire [23:0]  xa_lba; wire [4:0] xa_count; wire [12:0] xa_level; wire [7:0] xa_gen; wire xa_filt;
	wire [31:0]  ps1_ev_data; wire [5:0] ps1_ev_wp;             // the frame event log (ctrl 0x120/0x124)
	wire [31:0]  ps1_icv_pc, ps1_icv_got, ps1_icv_want, ps1_icv_n;
	wire         ps1_dbg_exec;
	reg  [5:0]   ps1_rsel;          // CPU register peek: write the index to ctrl 0x9C, read it back
	wire [31:0]  ps1_rval;
	// a trace of the writes to ONE register (the one ps1_rsel[4:0] selects):
	// 16 entries of {pc, value}; freezes at the first write of rw_freeze_val
	// from a PC in 0x8005xxxx (the BIOS shell). ctrl 0xA0: write = index, read
	// = pc; 0xA4: read = value; 0xA8: write = freeze value, read = {frozen, wr}.
	wire        ps1_wa_en, ps1_wb_en;
	wire [4:0]  ps1_wa_reg, ps1_wb_reg;
	wire [31:0] ps1_wa_val, ps1_wb_val;
	reg  [31:0] rwtrace_pc [0:15];
	reg  [31:0] rwtrace_v  [0:15];
	reg  [3:0]  rw_wr, rw_idx;
	reg         rw_frozen;
	reg  [31:0] rw_freeze_val;
	wire        ps1_gpu_pop; wire [31:0] ps1_gpu_popword;
	// The last 64 GP0 words the drawing engine took, as a ring that stops when
	// the engine has sat waiting for a command's arguments with an empty FIFO
	// for a while -- the shape of a command stream that broke off. Reading the
	// ring then shows what arrived last; a write to 0xD8 lets it run again.
	reg  [31:0] gpw [0:63];
	reg  [5:0]  gpw_n; reg [5:0] gpw_idx; reg gpw_frozen; reg [19:0] gpw_stall;
	reg         gpw_arm_tog, gpw_arm_seen;   // the re-arm crosses from the control write to the capture
	reg  [31:0] rw_freeze_pc;       // ctrl 0xD4: when non-zero, freeze both rings when this PC executes with R[rsel] == rw_freeze_val
	reg  [20:0]  ps1_watch;         // ctrl 0xAC: RAM word to watch for writes; 0xB0 reads {cpu, dma, data}
	wire [31:0]  ps1_watch_hit, ps1_watch_nz;
	wire         ps1_watch_pulse, ps1_watch_npulse;
	reg  [31:0]  snapn_pc, snapn_sp;   // where the last non-zero write came from
	wire [31:0]  ps1_a0, ps1_a1, ps1_ra, ps1_sp;
	reg  [31:0]  snap_a0, snap_a1, snap_ra, snap_sp, snap_pc;   // the CPU's registers when the watchpoint hit
	wire [31:0]  ps1_dbg_fill;
	reg  [23:0]  hr_line;
	reg  [31:0]  stream_ctl, stream_base_r, stream_words_r;   // ctrl 0xF0 {en, .., port}, 0xF4 base, 0xF8 words
	reg  [31:0]  stream_row_r;                                // ctrl 0xFC {row pitch, words per row}
	reg  [1:0]   sdt_sync; reg sdt_seen;                      // the streamer's done toggle, edge-detected
	wire         stream_rearm = (sdt_sync[1] != sdt_seen);
	// bit 31 enables; bit 29 = one frame per kick (a write with bit 28), so the
	// register link is free between frames; bit 30 = capture at every vsync
	reg          stream_kick;
	assign stream_en = stream_ctl[31] && (!stream_ctl[29] || stream_kick);
	assign stream_port = stream_ctl[15:0];
	assign stream_base = stream_base_r;
	assign stream_rowlen = stream_row_r[15:0]; assign stream_stride = stream_row_r[31:16];
	// The capture into DDR3 is now only for the slow read-back path the host
	// falls back on. While streaming, the scanout feeds the network directly.
	reg          cap_kick;   // the streamer asking for a fresh DDR3 frame
	wire         fb_cap_go = (ctrl_we && (off == 16'h0098)) || cap_kick;
	wire         fs_arm    = stream_en && stream_rearm;
	// the CD-ROM's sector transport: the ESP32 over SPI (cd_feed.v) into the drive
	wire        cd_disc_in, cd_sb_we, cd_sb_done, cd_fill_run;
	wire [11:0] cd_sb_addr; wire [7:0] cd_sb_data; wire [23:0] cd_sb_lba, cd_fill_lba; wire [3:0] cd_fill_room;
	// the ESP32's feed (cd_feed.v), and the PC's (below): the drive takes one of them
	wire        esp_disc_in, esp_sb_we, esp_sb_done;
	wire [11:0] esp_sb_addr; wire [7:0] esp_sb_data; wire [23:0] esp_sb_lba;
	wire [31:0] cd_dbg, cd_dbg_cmds, cd_dbg_setloc, cd_dbg_seek, cd_dbg_hdr, cd_sectors_in, cd_trace_data; wire [5:0] cd_trace_wp; reg [5:0] cd_trace_idx = 6'd0; wire [15:0] cd_dma_words; wire [15:0] cd_frames_short;
	wire cc_flush = ctrl_we && (off == 16'h0118); wire cc_flush_busy;   // a write to 0x118 flushes the CPU's write-back cache to DDR3 (read: busy)
	generate if (CORE_PS1) begin : g_cdfeed
		cd_feed u_cdfeed (
			.clk(clk), .rst(rst),
			.spi_sclk(esp_sclk), .spi_mosi(esp_mosi), .spi_miso(esp_miso), .spi_cs_n(esp_cs_n),
			.fill_lba(cd_fill_lba), .fill_room(cd_fill_room), .fill_run(cd_fill_run), .disc_in(esp_disc_in),
			.sb_we(esp_sb_we), .sb_addr(esp_sb_addr), .sb_data(esp_sb_data), .sb_done(esp_sb_done), .sb_lba(esp_sb_lba),
			.sectors_in(cd_sectors_in), .frames_short(cd_frames_short)
		);
	end else begin : g_nocdfeed
		assign esp_miso = 1'b0; assign esp_disc_in = 1'b0; assign esp_sb_we = 1'b0; assign esp_sb_done = 1'b0;
		assign esp_sb_addr = 12'd0; assign esp_sb_data = 8'd0; assign esp_sb_lba = 24'd0;
		assign cd_sectors_in = 32'd0; assign cd_frames_short = 16'd0;
	end endgenerate

	// --- the disc from the PC, over Ethernet ----------------------------------------
	// The same job cd_feed.v does for the ESP32, for when the ESP32 cannot: the PC
	// reads what the drive wants (ctrl 0x128), writes the 2352-byte raw sector into
	// a window at ctrl 0x4000..0x492F with block writes, and commits it with its LBA
	// (ctrl 0x12C), which the drive takes only if it is the sector it asked for.
	// ctrl 0x130 bit 0 hands the drive to the PC, bit 1 says a disc is in.
	// Wired Ethernet, no SD card, no Wi-Fi: the ESP32's card stopped answering on
	// 2026-09-28 and its Wi-Fi disc path is known to lose a sector.
	wire        hcd_own, hcd_disc, hcd_we, hcd_done;
	wire [11:0] hcd_addr; wire [7:0] hcd_data; wire [23:0] hcd_lba;
	host_cd u_hcd (
		.clk(clk), .rst(rst), .we(ctrl_we), .off(off), .wdata(wdata),
		.own(hcd_own), .disc(hcd_disc),
		.sb_we(hcd_we), .sb_addr(hcd_addr), .sb_data(hcd_data), .sb_done(hcd_done), .sb_lba(hcd_lba)
	);
	assign cd_disc_in = hcd_own ? hcd_disc : esp_disc_in;
	assign cd_sb_we   = hcd_own ? hcd_we   : esp_sb_we;
	assign cd_sb_addr = hcd_own ? hcd_addr : esp_sb_addr;
	assign cd_sb_data = hcd_own ? hcd_data : esp_sb_data;
	assign cd_sb_done = hcd_own ? hcd_done : esp_sb_done;
	assign cd_sb_lba  = hcd_own ? hcd_lba  : esp_sb_lba;
	// fb_ddr's read port: the streamer takes it while it is the one using the
	// DDR3 copy, otherwise it belongs to the register bus as before.
	wire [31:0]  fbr_rdata_w; wire fbr_ack_w;
	wire [31:0]  fs_data_w;   wire fs_valid_w;
	wire         fs_empty, fs_ready;
	wire         vram_flush_go = ctrl_we && (off == 16'h00E0);   // ctrl 0xE0: write = flush the VRAM cache, read bit 31 = busy
	wire         vram_flush_busy;
	wire         fb_cap_ready; wire [9:0] fb_width; wire [8:0] fb_height;
	// How many words a frame is, worked out from the picture the machine is
	// actually showing rather than taken from the host. The host measures the
	// size once and can easily be holding an old answer -- it measured 256 wide
	// during the boot animation and then kept sending that while the scanout
	// produced 320, so the streamer ended every frame 7680 words early and the
	// picture came apart into stripes. The machine knows its own frame size.
	wire [9:0]  fb_wpr  = (fb_width + 10'd1) >> 1;
	wire [18:0] fb_auto = fb_wpr * fb_height;
	assign stream_words = (CORE_PS1 != 0) ? fb_auto[17:0] : (CORE_N64 != 0) ? n64_fb_words : stream_words_r[17:0];
	// a streamed frame may start when the capture behind it is complete; the
	// block-RAM framebuffers of the older cores are always readable
	// A frame may go out as soon as the scanout has put something in the
	// buffer; the buffer is emptied when a scan starts, so this is the top of
	// a frame and not the middle of the last one.
	// --- the frame the network sends: from DDR3, or straight off the scanout --
	wire from_ddr = ((CORE_PS1 != 0) || (CORE_N64 != 0)) && stream_ctl[27];
	// fb_stream is only in the way when the DDR3 copy is being used: switched
	// off, it stops holding the scanout back, and only the capture does.
	wire fs_en    = stream_en && !from_ddr;

	localparam [17:0] FB_ROW_WORDS = 18'd320;   // a row of the DDR3 frame, in words
	// the word being fetched: 19 bits, since an N64 frame sent every other row
	// (640 x 480 at 32 bits) reaches twice as far as its 153,600 words -- with
	// 18 its last rows wrapped round to the top of the picture
	reg  [18:0] sfa;
	reg  [15:0] sfc;        // how far along its row that is
	reg         sfr;        // a read is out
	reg  [31:0] sfd;        // the word in hand
	reg         sfv;        // and it is good
	reg         cap_wait;   // a capture was asked for and is not finished
	// a row of the frame in words, and the step to the next row's start: the
	// PlayStation's copy is at a 320-word pitch, the N64's rows are contiguous
	wire [15:0] sf_rowlen = (CORE_N64 != 0) ? n64_fb_wpr : {6'd0, fb_wpr};
	wire [18:0] sf_pitch  = (CORE_N64 != 0) ? ({3'd0, n64_fb_wpr} << n64_fb_halve) : {1'b0, FB_ROW_WORDS};

	assign fbr_rdata = fbr_rdata_w;
	assign fbr_ack   = from_ddr ? 1'b1 : fbr_ack_w;   // the host's slow path yields while streaming
	// For the PlayStation, stream_ready means THE WORD IN HAND IS THE FIRST OF A
	// FRAME: the network core starts a frame only on one, drops stray words until
	// it sees one, and gives a frame up if one turns up in the middle (a capture
	// abandoned at a flip, see fb_stream.v). The DDR3 copy's first word is the
	// one at the start of its first row.
	assign stream_ready  = (CORE_PS1 == 0 && CORE_N64 == 0) ? 1'b1
	                     : (from_ddr ? (!cap_wait && sfv && sfa == 18'd0 && sfc == 16'd0) : fs_ready);
	assign stream_direct = (CORE_PS1 != 0) || (CORE_N64 != 0);
	assign stream_fvalid = from_ddr ? sfv : fs_valid_w;
	assign stream_fdata  = from_ddr ? sfd : fs_data_w;

	always @(posedge clk) begin
		if (rst) begin
			sfa <= 18'd0; sfc <= 16'd0; sfr <= 1'b0; sfv <= 1'b0; sfd <= 32'd0;
			cap_wait <= 1'b0; cap_kick <= 1'b0;
		end else begin
			cap_kick <= 1'b0;
			if (!from_ddr) begin
				sfr <= 1'b0; sfv <= 1'b0; cap_wait <= 1'b0;
			end else begin
				// a finished frame, or switching this on, asks for the next one
				if (stream_rearm || (stream_en && !cap_wait && !sfv && !sfr && sfa == 18'd0 && sfc == 16'd0 && !cap_kick && !fb_cap_ready)) begin
					cap_kick <= 1'b1; cap_wait <= 1'b1;
					sfa <= 18'd0; sfc <= 16'd0; sfv <= 1'b0; sfr <= 1'b0;
				end
				if (cap_wait && fb_cap_ready) cap_wait <= 1'b0;

				// fetch the next word while the one in hand is being taken
				if (!cap_wait && !sfv && !sfr) sfr <= 1'b1;
				if (sfr && fbr_ack_w) begin sfd <= fbr_rdata_w; sfv <= 1'b1; sfr <= 1'b0; end
				if (stream_frd && sfv) begin
					sfv <= 1'b0;
					// the frame is 320 words a row in memory but only fb_wpr of
					// them are the picture; step over the rest
					if (sfc + 16'd1 >= sf_rowlen) begin
						sfa <= sfa + (sf_pitch - {3'd0, sf_rowlen} + 19'd1);
						sfc <= 16'd0;
					end else begin
						sfa <= sfa + 19'd1;
						sfc <= sfc + 16'd1;
					end
				end
			end
		end
	end
	always @(posedge clk) begin
		sdt_sync <= {sdt_sync[0], stream_done_tog};
		if (rst) begin sdt_seen <= 1'b0; stream_kick <= 1'b0; end
		else begin
			if (stream_rearm) begin sdt_seen <= sdt_sync[1]; stream_kick <= 1'b0; end   // the frame went out
			if (ctrl_we && off == 16'h00F0 && wdata[28]) stream_kick <= 1'b1;
		end
	end
	wire         ps1_node_v; wire [23:0] ps1_node_addr; wire [31:0] ps1_node_hdr;
	reg  [23:0]  ntrace_a [0:15]; reg [31:0] ntrace_h [0:15]; reg [3:0] nt_wr, nt_idx;
	reg          nt_frozen;         // stops at the first header whose next pointer is not a RAM word
	wire         hr_go;
	wire         hr_done;
	wire [127:0] hr_data;
	wire [31:0]  ps1_dbg_word;
	reg  [31:0]  pitrace [0:15];    // the instruction words beside pctrace
	// a PC trace for the PlayStation: the last sixteen distinct PCs before an
	// exception that was not an interrupt or a syscall, frozen there (logic at
	// the end of the module; declared here so the register mux may read it)
	reg [31:0] pctrace [0:15];
	reg [3:0]  pct_wr, pct_idx;
	reg        pct_frozen;
	reg [31:0] pct_last;
	wire [7:0]   md_px_rgb;
	wire signed [15:0] md_audio_l, md_audio_r;
	wire [31:0]  md_dbg_pc;
	wire [31:0]  md_host_rdata;      // reading the Mega Drive's cartridge back
	wire [31:0]  md_dbg_mem;         // line requests, and lines delivered
	// Wide enough for the whole cartridge, not just the 64 kB a Z80 can see at
	// once. The Master System reaches past that through its mapper -- the
	// address arriving here is already banked -- and declaring this 16 bits
	// silently threw the top of it away, so every cartridge larger than 64 kB
	// folded onto its own first bank. A 32 kB test cartridge cannot notice that
	// and neither can a testbench that drives the console module directly.
	wire [PROG_AW-1:0] z80_addr;
	wire [7:0]  z80_dout;
	wire        z80_we, z80_io;
	wire [15:0] z80_pc;
	reg  [31:0] con_count;
	reg         test_mode;      // slot 1 is a bare CPU rather than a console

	// --- control registers ----------------------------------------------------
	reg        run;
	reg        cpu_halt;    // ctrl 0x04 bit 2: stop the processor where it stands
	reg        mirror_v;
	reg [3:0]  mapper_id;
	reg        chr_is_ram;      // the cartridge has tile RAM, not tile ROM
	reg [5:0]  prg_last;
	reg [3:0]  console_sel;
	reg [15:0] joy1, joy2;           // 8 bits for the older cores; the PS1 pad uses all 16
	reg [15:0] n64_stick1;
	reg [1:0]  n64_eep;              // the N64 cartridge's EEPROM: 0 none, 1 4 kbit, 2 16 kbit
	reg [3:0]  n64_pads;             // which N64 controllers are plugged in
	reg [10:0] n64_eh_addr;
	reg        n64_vi_slow;          // the N64's VI at half rate (0x178 bit 0)
	reg [31:0] n64_dbg_sel;          // what the N64's debug window shows (0x170): [5:0] which, [15:8] a log entry, [25:16] a DMEM word
	reg [7:0]  n64_eh_wdata;
	wire [7:0] n64_eh_rdata;
	// a write to 0x16C with bit 31 set writes the EEPROM's byte; any write moves the read
	wire       n64_eh_we = ctrl_we && off == 16'h016C && wdata[31];
	reg [31:0] frame_count;

	// A core that is not selected is held in reset, so it cannot drive the
	// framebuffer or count frames behind the running one's back.
	wire nes_sel  = (console_sel == CONSOLE_NES);
	wire sms_sel  = (console_sel == CONSOLE_SMS);
	wire md_sel   = (console_sel == CONSOLE_MD);
	wire ps1_sel  = (console_sel == CONSOLE_PS1);
	wire n64_sel  = (console_sel == CONSOLE_N64);
	wire core_rst = rst || !run;
	wire nes_rst  = core_rst || !nes_sel;
	wire z80_rst  = core_rst || !sms_sel;
	wire md_rst   = core_rst || !md_sel;
	wire z80_mem_we = z80_we && !z80_io && sms_sel;
	wire z80_io_we  = z80_we &&  z80_io && sms_sel;

	always @(posedge clk) begin
		if (rst) begin
			run <= 1'b0; cpu_halt <= 1'b0; mirror_v <= 1'b0; joy1 <= 16'd0; joy2 <= 16'd0;
			n64_stick1 <= 16'd0; n64_eep <= 2'd0; n64_pads <= 4'b0001; n64_dbg_sel <= 32'd0; n64_vi_slow <= 1'b0;
			mapper_id <= 4'd0; prg_last <= 6'd3; console_sel <= CONSOLE_FIRST;
			chr_is_ram <= 1'b0;
			test_mode <= 1'b0;
		end else if (ctrl_we) begin
			case (off)
			16'h0004: begin run <= wdata[0]; mirror_v <= wdata[1]; cpu_halt <= wdata[2]; end
		16'h0064: pct_idx <= wdata[3:0];        // which PC-trace entry 0x64 reads back
			16'h007C: hr_line <= wdata[23:0];       // read one DDR3 line (hr_go fires with the write)
			16'h0090: nt_idx <= wdata[3:0];         // which DMA node-trace entry 0x90/0x94 read back
			16'h009C: ps1_rsel <= wdata[5:0];
			16'h0110: cd_trace_idx <= wdata[5:0];
			16'h00EC: begin perf_sel <= wdata[5:0];
			                cpu_pace <= wdata[12]; gpu_fast <= wdata[13]; dma_relax <= wdata[14]; end
			16'h0120: ev_idx <= wdata[5:0];         // which frame-event entry 0x120 reads back
			16'h0134: begin card_in <= wdata[0]; card_fill <= wdata[1]; card2_in <= wdata[2]; card2_fill <= wdata[3]; end
			16'h00F0: stream_ctl <= wdata;
			16'h00F4: stream_base_r <= wdata;
			16'h00F8: stream_words_r <= wdata;
			16'h00FC: stream_row_r <= wdata;
			16'h00A0: rw_idx <= wdata[3:0];
			16'h00A8: rw_freeze_val <= wdata;
			16'h00D4: rw_freeze_pc <= wdata;
			16'h00D8: gpw_arm_tog <= ~gpw_arm_tog;   // let the GP0 ring run again
			16'h00DC: gpw_idx <= wdata[5:0];
			16'h00AC: ps1_watch <= wdata[20:0];
			16'h0008: joy1 <= wdata[15:0];
			16'h000C: joy2 <= wdata[15:0];
			16'h0164: n64_stick1 <= wdata[15:0];                     // the N64's stick: X [15:8], Y [7:0]
			16'h0168: begin n64_eep <= wdata[1:0]; n64_pads <= wdata[7:4]; end
			16'h016C: begin n64_eh_addr <= wdata[10:0]; n64_eh_wdata <= wdata[23:16]; end   // the EEPROM, a byte
			16'h0170: n64_dbg_sel <= wdata;                       // the N64's debug window: what 0x174 shows
			16'h0178: n64_vi_slow <= wdata[0];                         // the N64's VI at half rate
			16'h001C: begin
				mapper_id  <= wdata[3:0];
				prg_last   <= wdata[13:8];
				chr_is_ram <= wdata[14];
			end
			// Selecting a core that was not built would be a black screen with
			// no explanation, so the write is ignored and the read-back shows
			// the host what actually happened.
			16'h0020: begin
				if (wdata[3:0] < 4'd8 && CORES_BUILT[wdata[2:0]]) console_sel <= wdata[3:0];
				test_mode <= wdata[8];
			end
			default: ;
			endcase
		end
	end

	always @* begin
		case (off)
		16'h0000: ctrl_rdata = 32'h4E45_0001;      // "NE"
		16'h0004: ctrl_rdata = {29'd0, cpu_halt, mirror_v, run};
		16'h0008: ctrl_rdata = {16'd0, joy1};
		16'h000C: ctrl_rdata = {16'd0, joy2};
		16'h0010: ctrl_rdata = frame_count;
		// The Mega Drive's program counter is 32 bits and the other two are 16,
		// so this reports whichever machine is actually running. Reading the
		// NES's PC while the Mega Drive was selected returned a tied-off zero
		// and looked exactly like a CPU that had stopped -- the most misleading
		// possible answer, since a stuck PC is the first thing anyone checks.
		16'h0014: ctrl_rdata = ps1_sel ? ps1_dbg_pc : n64_sel ? n64_dbg_pc : md_sel ? md_dbg_pc : {16'd0, dbg_pc};
		16'h0018: ctrl_rdata = nmi_count;
		16'h001C: ctrl_rdata = {17'd0, chr_is_ram, prg_last, 4'd0, mapper_id};
		16'h0020: ctrl_rdata = {8'd0, CORES_BUILT, 7'd0, test_mode, 4'd0, console_sel};
		16'h0024: ctrl_rdata = con_count;
		16'h0028: ctrl_rdata = {16'd0, z80_pc};
		// Lines the Mega Drive's cache asked for, and lines it got. Equal and
		// rising means the cartridge is feeding it; asking and not receiving
		// means the memory behind it is not answering; not asking at all means
		// the CPU never got as far as a fetch.
		16'h002C: ctrl_rdata = md_dbg_mem;
		// PlayStation boot introspection: the last I/O register the CPU read,
		// the value it got, and how many GPU commands it has issued.
		16'h0038: ctrl_rdata = ps1_dbg_io_addr;
		16'h003C: ctrl_rdata = ps1_dbg_io_data;
		16'h0040: ctrl_rdata = ps1_dbg_gpu_wr;
		16'h0044: ctrl_rdata = ps1_dbg_mem;
		16'h0048: ctrl_rdata = ps1_dbg_daddr;
		16'h004C: ctrl_rdata = ps1_dbg_irq;
		16'h0050: ctrl_rdata = ps1_dbg_gpu_st;
		16'h0054: ctrl_rdata = ps1_dbg_cause;
		16'h0058: ctrl_rdata = ps1_dbg_epc;
		16'h005C: ctrl_rdata = ps1_dbg_dma;
		16'h0060: ctrl_rdata = ps1_dbg_gpu2;
		16'h0064: ctrl_rdata = pctrace[pct_idx];
		16'h0068: ctrl_rdata = {27'd0, pct_frozen, pct_wr};
		16'h006C: ctrl_rdata = ps1_dbg_disp;
		16'h0070: ctrl_rdata = ps1_dbg_draw;
		16'h0074: ctrl_rdata = pitrace[pct_idx];
		16'h0078: ctrl_rdata = ps1_dbg_fill;
		16'h007C: ctrl_rdata = {hr_done, 7'd0, hr_line};
		16'h0080: ctrl_rdata = hr_data[31:0];
		16'h0084: ctrl_rdata = hr_data[63:32];
		16'h0088: ctrl_rdata = hr_data[95:64];
		16'h008C: ctrl_rdata = hr_data[127:96];
		16'h0090: ctrl_rdata = {3'd0, nt_frozen, nt_wr, ntrace_a[nt_idx]};
		16'h0094: ctrl_rdata = ntrace_h[nt_idx];
		16'h0098: ctrl_rdata = {fb_cap_ready, 12'd0, fb_height, fb_width};   // the DDR3 frame: ready, size
		16'h00AC: ctrl_rdata = cd_dbg;                                         // the CD-ROM drive: stat, reading, seeking, ring, wanted LBA
		16'h00D4: ctrl_rdata = {cd_frames_short, cd_sectors_in[15:0]};        // the sector transport: short frames, sectors in
		16'h0100: ctrl_rdata = cd_dbg_cmds;                                    // the drive's last four command bytes
		16'h0104: ctrl_rdata = cd_dbg_setloc;                                  // the last Setloc's mm ss ff, and the mode
		16'h0108: ctrl_rdata = cd_dbg_seek;                                    // int flag, and the last seek target LBA
		16'h010C: ctrl_rdata = cd_dbg_hdr;                                     // the last delivered sector's header: mm ss ff mode
		16'h0110: ctrl_rdata = {cd_dma_words, 10'd0, cd_trace_wp};              // DMA ch3 words written; the trace's write pointer (index on write)
		16'h0114: ctrl_rdata = cd_trace_data;                                  // the entry at the index: {cmd, p0, p1, p2}
		16'h0118: ctrl_rdata = {31'd0, cc_flush_busy};                        // the CPU cache flush: 1 while it is writing back
		16'h0128: ctrl_rdata = {cd_fill_run, cd_fill_room[2:0], 4'd0, cd_fill_lba};   // the drive: running, room, the LBA it wants next
		16'h0130: ctrl_rdata = {30'd0, hcd_disc, hcd_own};                    // the PC has the drive / a disc is in
		16'h0134: ctrl_rdata = {28'd0, card2_fill, card2_in, card_fill, card_in};   // memory cards: {fill to 2, 2 in, fill to 1, 1 in}
		// the oldest sector the card stored that the PC has not copied: {overflow, 10'd0,
		// how many are waiting[4:0], 6'd0, sector[9:0]}. Reading takes nothing; writing
		// bit 0 pops it, bit 31 clears the overflow -- a read that is retried over UDP
		// must not lose a save.
		16'h0138: ctrl_rdata = {card_wq_ovf, 10'd0, card_wq_count, 5'd0, card_wq_sector};   // sector bit 10: the slot
		16'h013C: ctrl_rdata = {xa_count, 3'd0, xa_lba};
		16'h0140: ctrl_rdata = {xa_gen, 7'd0, xa_filt, 3'd0, xa_level};   // bit 16: the game filters XA itself
		// the N64: the VI's registers (where the framebuffer is, and its shape) and
		// how far the CPU has got -- the host reads the screen out of RDRAM by these
		16'h0150: ctrl_rdata = n64_vi_status;
		16'h0154: ctrl_rdata = n64_vi_origin;
		16'h0158: ctrl_rdata = n64_vi_width;
		16'h015C: ctrl_rdata = n64_vi_yscale;
		16'h0160: ctrl_rdata = n64_retired;
		16'h0168: ctrl_rdata = {24'd0, n64_pads, 2'd0, n64_eep};
		16'h016C: ctrl_rdata = {8'd0, n64_eh_rdata, 5'd0, n64_eh_addr};
		16'h0170: ctrl_rdata = n64_dbg_sel;
		16'h0174: ctrl_rdata = n64_dbg_q;
		16'h0178: ctrl_rdata = {31'd0, n64_vi_slow};
		16'h0120: ctrl_rdata = ps1_ev_data;                                    // the frame event log entry at ev_idx: {type[2:0], clock[28:0]}
		16'h0124: ctrl_rdata = {26'd0, ps1_ev_wp};                             // ...and where the next one will go
		16'h00E4: ctrl_rdata = ps1_dbg_v2c;   // {made, taken by CPU, taken by DMA, read with nothing there}
		16'h00E8: ctrl_rdata = ps1_dbg_c0;    // the last read-back's width and height
		16'h00EC: ctrl_rdata = ps1_dbg_perf;  // the counter perf_sel selects (see ps1_top)
		16'h0100: ctrl_rdata = ps1_icv_n;     // instruction-cache disagreements, and the first one
		16'h0104: ctrl_rdata = ps1_icv_pc;
		16'h0108: ctrl_rdata = ps1_icv_got;
		16'h010C: ctrl_rdata = ps1_icv_want;
		16'h00F0: ctrl_rdata = stream_ctl;
		16'h00F4: ctrl_rdata = stream_base_r;
		16'h00F8: ctrl_rdata = stream_words_r;
		16'h00FC: ctrl_rdata = stream_row_r;
		16'h009C: ctrl_rdata = ps1_rval;
		16'h00A0: ctrl_rdata = rwtrace_pc[rw_idx];
		16'h00A4: ctrl_rdata = rwtrace_v[rw_idx];
		16'h00A8: ctrl_rdata = {rw_frozen, 27'd0, rw_wr};
		16'h00B0: ctrl_rdata = ps1_watch_hit;
		16'h00B4: ctrl_rdata = snap_a0;
		16'h00B8: ctrl_rdata = snap_a1;
		16'h00BC: ctrl_rdata = snap_ra;
		16'h00C0: ctrl_rdata = snap_sp;
		16'h00C4: ctrl_rdata = snap_pc;
		16'h00C8: ctrl_rdata = ps1_watch_nz;
		16'h00CC: ctrl_rdata = snapn_pc;
		16'h00D0: ctrl_rdata = snapn_sp;
		16'h00E0: ctrl_rdata = {vram_flush_busy, 31'd0};
		16'h00D8: ctrl_rdata = {gpw_frozen, 25'd0, gpw_n};   // frozen (the stream broke off), and where the ring's oldest word is
		16'h00DC: ctrl_rdata = gpw[gpw_idx];
		default:  ctrl_rdata = 32'd0;
		endcase
	end

	// --- the cartridge ---------------------------------------------------------
	// A Mega Drive build keeps its cartridge in md_cart, not in cart_mem, so
	// reading the cartridge back has to come from whichever one holds it.
	// Without this the readback returned cart_mem -- a 4 kB memory nothing in
	// that image writes -- and an upload that never arrived would have looked
	// identical to one that did.
	wire [31:0] cart_prog_rdata;
	assign prog_rdata = md_sel ? md_host_rdata : cart_prog_rdata;

	wire [PROG_AW-1:0] prog_addr;
	wire [CHAR_AW-1:0] char_addr;
	wire [7:0]         prog_din, char_din;

	// The cartridge's program memory is shared: the NES reads it as ROM, the
	// Z80 uses its low 64 kB as read/write memory.
	wire [PROG_AW-1:0] core_prog_addr = sms_sel ? z80_addr : prog_addr;

	// The cartridge memory exists only for the machines that have one. A
	// PlayStation build keeps its BIOS and disc in DDR3 and never touches this,
	// yet it was instantiated regardless: 96 of the chip's 135 block RAM tiles,
	// holding nothing, in every PS1 image (found 2026-09-22 by a hierarchical
	// utilisation report; the PS1 core itself uses 19).
	generate if (CORE_NES || CORE_SMS) begin : g_cart
	cart_mem #(.PROG_AW(PROG_AW), .CHAR_AW(CHAR_AW),
	           .PROG_CORE_WRITES(CORE_SMS),   // only the bare Z80 writes it
	           .CHAR_CORE_WRITES(CORE_NES))   // only the NES has tile RAM
	  u_cart (
		.clk(clk),
		.prog_windex(prog_windex), .prog_we(prog_we),
		.char_windex(char_windex), .char_we(char_we),
		.wdata(wdata),
		.prog_host_rdata(cart_prog_rdata), .char_host_rdata(char_rdata),
		.prog_addr(core_prog_addr), .prog_din(prog_din),
		.prog_wdata(z80_dout), .prog_core_we(z80_mem_we),
		.char_addr(char_addr), .char_din(char_din),
		.char_wdata(nes_chr_dout), .char_core_we(nes_chr_we)
	);
	end else begin : g_nocart
		assign cart_prog_rdata = 32'd0;
		assign char_rdata      = 32'd0;
	end endgenerate

	// --- the picture for HDMI: the running core's ----------------------------------------
	wire [23:0] n64_vid_rgb, nes_vid_rgb;
	assign vid_rgb = n64_sel ? n64_vid_rgb : nes_sel ? nes_vid_rgb : 24'd0;

	// --- the NES ---------------------------------------------------------------
	wire [8:0] nes_px, nes_py;
	wire       nes_pixel_en, nes_frame_start;
	wire [5:0] nes_color;
	wire [7:0] nes_rgb;
	wire [15:0] nes_audio;

	generate if (CORE_NES) begin : g_nes
		nes #(.PRG_AW(PROG_AW), .CHR_AW(CHAR_AW)) u_nes (
			.clk(clk), .rst(nes_rst), .ce(ce),
			.prg_addr(prog_addr), .prg_din(prog_din),
			.chr_addr(char_addr), .chr_din(char_din),
			.chr_dout(nes_chr_dout), .chr_we(nes_chr_we),
			.chr_is_ram(chr_is_ram),
			.mapper_id(mapper_id), .hdr_mirror_v(mirror_v), .prg_last(prg_last),
			.joy1(joy1[7:0]), .joy2(joy2[7:0]),
			.audio(nes_audio),
			.px(nes_px), .py(nes_py), .pixel_en(nes_pixel_en),
			.color(nes_color), .frame_start(nes_frame_start),
			.dbg_pc(dbg_pc), .dbg_sync(), .dbg_nmi(dbg_nmi)
		);
		nes_palette u_pal (.idx(nes_color), .rgb332(nes_rgb));
		nes_hdmi u_hdmi (.clk(clk), .pixel_en(nes_pixel_en), .px(nes_px), .py(nes_py), .color(nes_color),
			.pclk(pclk), .x(vid_x), .y(vid_y), .req(vid_req), .rgb(nes_vid_rgb));
	end else begin : g_nes
		// Everything the core would have driven, tied off. Not for tidiness:
		// an undriven wire feeding the pixel mux is an X that propagates into
		// the framebuffer in simulation and an unpredictable constant on the
		// board.
		assign prog_addr = {PROG_AW{1'b0}};
		assign char_addr = {CHAR_AW{1'b0}};
		assign nes_chr_dout = 8'd0;
		assign nes_chr_we   = 1'b0;
		assign nes_audio    = 16'h8000;
		assign nes_px = 9'd0; assign nes_py = 9'd0;
		assign nes_pixel_en = 1'b0; assign nes_frame_start = 1'b0;
		assign nes_color = 6'd0; assign nes_rgb = 8'd0;
		assign nes_vid_rgb = 24'd0;
		assign dbg_pc = 16'd0; assign dbg_nmi = 1'b0;
	end endgenerate

	// --- slot 1: either a bare Z80 or a whole Master System -----------------------
	// The bare CPU is kept because it is how ZEXDOC and ZEXALL get run: they
	// need 64 kB of RAM and no video chip, which is the opposite of what a game
	// needs. Bit 8 of the CONSOLE register chooses, so verifying the CPU stays a
	// register write rather than a different bitstream.
	wire raw_z80 = test_mode && (CORE_SMS != 0);

	wire [15:0] bare_addr;
	wire [7:0]  bare_dout;
	wire        bare_we, bare_io;
	wire [15:0] bare_pc;

	wire [PROG_AW-1:0] sms_rom_addr;
	wire [8:0]  sms_px, sms_py;
	wire        sms_pixel_en, sms_frame_start;
	wire [5:0]  sms_color;
	wire [15:0] sms_pc;
	wire [15:0] sms_audio;

	generate if (CORE_SMS) begin : g_sms
		z80 u_z80 (
			.clk(clk), .rst(z80_rst || !raw_z80), .ce(1'b1),
			.addr(bare_addr), .din(prog_din), .dout(bare_dout),
			.we(bare_we), .io(bare_io), .m1(),
			.int_n(1'b1), .nmi_n(1'b1),
			.dbg_pc(bare_pc), .dbg_sp(), .dbg_af(), .dbg_bc(), .dbg_de(),
			.dbg_hl(), .dbg_m1()
		);

		sms #(.ROM_AW(PROG_AW)) u_sms (
			.clk(clk), .rst(z80_rst || raw_z80), .ce(ce),
			.rom_addr(sms_rom_addr), .rom_data(prog_din),
			.joy1(joy1[7:0]), .joy2(joy2[7:0]),
			.px(sms_px), .py(sms_py), .pixel_en(sms_pixel_en),
			.color(sms_color), .frame_start(sms_frame_start),
			.audio(sms_audio),
			.dbg_pc(sms_pc)
		);
	end else begin : g_sms
		assign bare_addr = 16'd0; assign bare_dout = 8'd0;
		assign bare_we = 1'b0;    assign bare_io = 1'b0;
		assign bare_pc = 16'd0;
		assign sms_rom_addr = {PROG_AW{1'b0}};
		assign sms_px = 9'd0; assign sms_py = 9'd0;
		assign sms_pixel_en = 1'b0; assign sms_frame_start = 1'b0;
		assign sms_color = 6'd0; assign sms_pc = 16'd0;
		assign sms_audio = 16'h8000;
	end endgenerate

	// Only the bare CPU writes to the cartridge: the Master System's own RAM is
	// inside it, so a game never does. And the bare CPU is a 64 kB machine with
	// no mapper, so its address is the bottom of the cartridge and nothing
	// above it -- which is where `z80_mem_we` points it.
	// Zero-extended through a wire rather than a concatenation, because the
	// concatenation was {{(PROG_AW-16){1'b0}}, bare_addr} and PROG_AW is not
	// always larger than 16. A Mega Drive image shrinks this cartridge to 4 kB,
	// since nothing in that image reads it, and a replication count of minus
	// four is an elaboration error. Synthesis happened to optimise the whole
	// expression away first -- raw_z80 is constant false without the Z80 -- so
	// the bitstream built and only the simulator objected. An assignment does
	// the same widening for any width, and cannot go negative.
	wire [PROG_AW-1:0] bare_addr_ext = bare_addr;
	assign z80_addr = raw_z80 ? bare_addr_ext : sms_rom_addr;
	assign z80_dout = bare_dout;
	assign z80_we   = raw_z80 && bare_we;
	assign z80_io   = bare_io;
	assign z80_pc   = raw_z80 ? bare_pc : sms_pc;

	// Anything the program writes to an I/O port lands here, so a test that
	// reports its results as text has somewhere to report them to. This is the
	// same idea as the blargg ROMs writing to $6000: let the program say whether
	// it passed rather than reading it off a waveform.
	// The Z80's console text, four kilobytes of it. ONLY BUILT FOR A CORE THAT
	// HAS A Z80. In a PlayStation image nothing ever writes it, so it has no
	// write port, so it cannot be a block RAM -- and it cannot be optimised away
	// either, because the register bus reads it. Synthesis built 32,768
	// flip-flops and a 1024-to-1 multiplexer of dead storage into every image:
	// "RAM 'con_mem_reg' ... dissolved into (32768) registers bits". On a part
	// already at 93% that is what stopped the design fitting at all, and it had
	// nothing to do with the core being built.
	generate if (CORE_NES || CORE_SMS || CORE_MD) begin : g_con
		(* ram_style = "block" *) reg [31:0] con_mem [0:1023];
		reg [31:0] con_q;
		wire       con_we = z80_io_we && (con_count < 32'd4096);
		wire [9:0] con_wa = con_count[11:2];
		wire [1:0] con_wb = con_count[1:0];

		always @(posedge clk) begin
			if (z80_rst)     con_count <= 32'd0;
			else if (con_we) con_count <= con_count + 32'd1;
		end

		// one write port with byte enables, one read port: a block RAM's shape
		always @(posedge clk) begin
			if (con_we) begin
				if (con_wb == 2'd0) con_mem[con_wa][7:0]   <= z80_dout;
				if (con_wb == 2'd1) con_mem[con_wa][15:8]  <= z80_dout;
				if (con_wb == 2'd2) con_mem[con_wa][23:16] <= z80_dout;
				if (con_wb == 2'd3) con_mem[con_wa][31:24] <= z80_dout;
			end
			con_q <= con_mem[con_index];
		end
		assign con_rdata = con_q;
	end else begin : g_nocon
		always @(posedge clk) con_count <= 32'd0;
		assign con_rdata = 32'd0;
	end endgenerate

	// --- the Mega Drive -----------------------------------------------------------
	// Its own cartridge memory, because it reads through cart_cache in 128-bit
	// lines rather than a byte at a time like the other two. See md_cart.v.

	generate if (CORE_MD) begin : g_md
		wire [19:0]  md_m_addr;
		wire         md_m_req, md_m_ready, md_m_valid;
		wire [127:0] md_m_data;

		// One of the two, never both. They present the same line interface to
		// cart_cache and take the same 32-bit host fill, so md_console cannot
		// tell which it is reading from -- only how much of a cartridge fits.
		if (MD_DDR3) begin : g_ddr3
			cart_ddr3 #(.BASE(24'h00_0000)) u_md_cart (
				.clk(clk), .rst(rst),
				.host_windex(md_windex_full), .host_we(prog_we && md_sel),
				.wdata(wdata), .fill_end(fill_end && md_sel),
				.m_addr(md_m_addr), .m_req(md_m_req), .m_ready(md_m_ready),
				.m_data(md_m_data), .m_valid(md_m_valid),
				.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata),
				.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid),
				.d_calibrated(d_calibrated)
			);
			assign md_host_rdata = 32'd0;   // DDR3 readback is not wired yet
		end else begin : g_bram
			md_cart #(.AW(MD_AW)) u_md_cart (
				.clk(clk), .rst(rst),
				// Filled by the same host writes that fill the other cartridges,
				// so loading a Mega Drive ROM is the same operation as loading
				// any other. Only the low MD_AW bits are used; a larger image is
				// refused by the host, not silently wrapped.
				.host_windex(md_windex[MD_AW-1:0]),
				.host_we(prog_we && md_sel),
				.wdata(wdata),
				.host_rdata(md_host_rdata),
				.m_addr(md_m_addr), .m_req(md_m_req), .m_ready(md_m_ready),
				.m_data(md_m_data), .m_valid(md_m_valid)
			);
			assign d_addr = 24'd0; assign d_req = 1'b0; assign d_we = 1'b0;
			assign d_wdata = 128'd0;
		end

		// Two counters, because "the CPU is stuck" has two very different
		// causes and they look identical from outside: either it never asks
		// the cartridge for anything, or it asks and nothing comes back.
		reg [15:0] req_n, val_n;
		always @(posedge clk) begin
			if (md_rst) begin req_n <= 16'd0; val_n <= 16'd0; end
			else begin
				if (md_m_req && md_m_ready) req_n <= req_n + 16'd1;
				if (md_m_valid)             val_n <= val_n + 16'd1;
			end
		end
		assign md_dbg_mem = {req_n, val_n};

		md_console u_md (
			.clk(clk), .rst(md_rst),
			.mem_addr(md_m_addr), .mem_req(md_m_req), .mem_ready(md_m_ready),
			.mem_data(md_m_data), .mem_valid(md_m_valid),
			.joy1(joy1[7:0]), .joy2(joy2[7:0]),
			.px_valid(md_px_valid), .px_x(md_px_x), .px_y(md_px_y),
			.px_rgb(md_px_rgb),
			.audio_l(md_audio_l), .audio_r(md_audio_r),
			.dbg_pc(md_dbg_pc)
		);
	end else begin : g_md
		// Tied off for the same reason the NES is: an undriven wire into the
		// pixel mux is an X in simulation and an unpredictable constant on the
		// board, neither of which announces itself.
		assign md_px_valid = 1'b0;
		assign md_px_x = 9'd0; assign md_px_y = 9'd0; assign md_px_rgb = 8'd0;
		assign md_audio_l = 16'sd0; assign md_audio_r = 16'sd0;
		assign md_dbg_pc = 32'd0;
		assign md_host_rdata = 32'd0;
		assign md_dbg_mem = 32'd0;
	end endgenerate

	// --- the Nintendo 64 -------------------------------------------------------------
	generate if (CORE_N64) begin : g_n64
		n64_top u_n64 (
			.clk(clk), .rst(rst),
			// held in reset (and the cartridge filling) until the host releases it
			.run(n64_sel && run),
			.host_windex(md_windex_full), .host_we(prog_we && n64_sel), .host_wdata(wdata),
			.fill_end(fill_end && n64_sel),
			.hr_go(hr_go), .hr_line(hr_line), .hr_done(hr_done), .hr_data(hr_data),
			.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(n64_d_wmask),
			.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid), .d_calibrated(d_calibrated),
			.joy1(joy1), .vi_slow(n64_vi_slow), .stick1(n64_stick1), .pad_present(n64_pads), .eep_size(n64_eep),
			.eh_we(n64_eh_we), .eh_addr(n64_eh_we ? wdata[10:0] : n64_eh_addr), .eh_wdata(wdata[23:16]), .eh_rdata(n64_eh_rdata),
			.vi_status(n64_vi_status), .vi_origin(n64_vi_origin), .vi_width(n64_vi_width), .vi_yscale(n64_vi_yscale),
			.dbg_pc(n64_dbg_pc), .dbg_retired(n64_retired), .dbg_sel(n64_dbg_sel), .dbg_q(n64_dbg_q),
			// the picture: straight out of RDRAM, no capture step
			.fbr_req(from_ddr && sfr), .fbr_word(sfa), .fbr_ack(fbr_ack_w), .fbr_rdata(fbr_rdata_w),   // all 19 bits
			.fb_words(n64_fb_words), .fb_wpr(n64_fb_wpr), .fb_halve(n64_fb_halve),
			.audio_lr(audio_lr), .audio_lr_we(audio_lr_we),
			.pclk(pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(n64_vid_rgb)
		);
		assign fb_cap_ready = 1'b1;
	end else begin : g_n64
		assign n64_d_wmask = 16'hFFFF;
		assign n64_vi_status = 32'd0; assign n64_vi_origin = 32'd0; assign n64_vi_width = 32'd0;
		assign n64_vi_yscale = 32'd0; assign n64_dbg_pc = 32'd0; assign n64_retired = 32'd0; assign n64_dbg_q = 32'd0;
		assign n64_fb_words = 18'd0; assign n64_fb_wpr = 16'd0; assign n64_fb_halve = 1'b0;
		assign n64_eh_rdata = 8'd0;
		assign n64_vid_rgb = 24'd0;
	end endgenerate

	// The DDR3 port has exactly one driver: the Mega Drive when its cartridge is
	// there, the PlayStation when it is the core, and a tie-off when neither uses
	// memory (NES, Master System). Without this last case the port floats; with
	// it in the wrong place it fights the core that legitimately drives it, which
	// is the multi-driven net that showed up the first time PS1 was built.
	generate if (!((CORE_MD && MD_DDR3) || CORE_PS1 || CORE_N64)) begin : g_no_mem
		assign d_addr = 24'd0; assign d_req = 1'b0; assign d_we = 1'b0;
		assign d_wdata = 128'd0;
	end endgenerate

	// --- whichever core is running ---------------------------------------------
	// One core today, so this is a pass-through; it is written as a selection
	// because that is the line a second core gets added to.
	// The Master System's colours are 6-bit RGB from its own palette; the NES's
	// come out of a fixed table. Both arrive here already resolved, which is
	// what keeps either machine's idea of colour out of the other.
	wire [7:0] sms_rgb = {sms_color[1:0], sms_color[1],     // red, 2 bits -> 3
	                      sms_color[3:2], sms_color[3],     // green
	                      sms_color[5:4]};                  // blue, 2 bits

	wire       core_pixel_en = nes_sel ? nes_pixel_en    :
	                           sms_sel ? (sms_pixel_en && !raw_z80) : 1'b0;
	// The Mega Drive has no separate frame-start signal; the top-left pixel of
	// a frame is the start of one. Without this the frame counter sat at zero
	// while the core was running perfectly well, which reads as a dead machine.
	wire       md_frame_st  = md_px_valid && (md_px_x == 9'd0) && (md_px_y == 9'd0);
	wire       core_frame_st = nes_sel ? nes_frame_start :
	                           sms_sel ? sms_frame_start :
	                           md_sel  ? md_frame_st     : 1'b0;
	wire [8:0] core_px       = nes_sel ? nes_px  : sms_px;
	wire [8:0] core_py       = nes_sel ? nes_py  : sms_py;
	wire [7:0] core_rgb      = nes_sel ? nes_rgb : sms_rgb;
	// Silence is 0x8000, not zero: the ring buffer is read as unsigned centred
	// on half scale, so zero would be full-negative deflection -- a loud click
	// every time a core stops.
	// The Mega Drive's two channels are SIGNED and centred on zero; everything
	// downstream of here is unsigned centred on half scale. Summing to mono and
	// re-centring is done in one step, with the sum halved first so that two
	// channels at full deflection cannot wrap round to silence.
	wire [15:0] md_audio = 16'h8000 +
	              {{1{md_audio_l[15]}}, md_audio_l[15:1]} +
	              {{1{md_audio_r[15]}}, md_audio_r[15:1]};

	assign     audio         = !run              ? 16'h8000
	                         : nes_sel           ? nes_audio
	                         : (sms_sel && !raw_z80) ? sms_audio
	                         : md_sel            ? md_audio
	                                               : 16'h8000;

	always @(posedge clk) begin
		if (core_rst)           frame_count <= 32'd0;
		else if (core_frame_st) frame_count <= frame_count + 32'd1;
	end

	// How many times the video chip has interrupted the CPU. A game that renders
	// one frame and then freezes is usually one that never gets its interrupt.
	reg nmi_prev;
	always @(posedge clk) begin
		if (core_rst) begin
			nmi_count <= 32'd0;
			nmi_prev  <= 1'b0;
		end else begin
			nmi_prev <= dbg_nmi;
			if (dbg_nmi && !nmi_prev) nmi_count <= nmi_count + 32'd1;
		end
	end

	// --- the PlayStation ----------------------------------------------------------
	generate if (CORE_PS1) begin : g_ps1
		ps1_top u_ps1 (
			.clk(clk), .rst(rst),
			// The CPU runs when the PlayStation is selected AND the host has
			// released it (run=1), which the host sets after the BIOS is loaded.
			.cpu_run(ps1_sel && run), .cpu_halt(cpu_halt),
			// The BIOS is host-loaded the same way a cartridge is: 32-bit words
			// through the program-fill path, here a byte offset into the BIOS.
			.host_windex({md_windex_full[16:0], 2'b00}),
			.host_we(prog_we && ps1_sel), .host_wdata(wdata),
			.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(ps1_d_wmask),
			.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid),
			.d_calibrated(d_calibrated),
			.px_valid(ps1_px_valid), .px_x(ps1_px_x), .px_y(ps1_px_y), .px_rgb(ps1_px_rgb),
			.dbg_pc(ps1_dbg_pc),
			.dbg_io_addr(ps1_dbg_io_addr), .dbg_io_data(ps1_dbg_io_data),
			.dbg_gpu_pop(ps1_gpu_pop), .dbg_gpu_popword(ps1_gpu_popword),
			.dbg_gpu_wr(ps1_dbg_gpu_wr), .dbg_mem(ps1_dbg_mem), .dbg_daddr(ps1_dbg_daddr),
			.dbg_irq(ps1_dbg_irq), .dbg_gpu_st(ps1_dbg_gpu_st),
			.dbg_cause(ps1_dbg_cause), .dbg_epc(ps1_dbg_epc), .dbg_dma(ps1_dbg_dma), .dbg_gpu2(ps1_dbg_gpu2), .dbg_disp(ps1_dbg_disp), .dbg_draw(ps1_dbg_draw), .dbg_v2c(ps1_dbg_v2c), .dbg_c0(ps1_dbg_c0), .dbg_perf_sel(perf_sel), .dbg_perf(ps1_dbg_perf), .no_icache(no_icache), .no_ibuf(no_ibuf), .ic_verify(ic_verify), .no_overlap(no_overlap), .no_tcache(no_tcache), .no_ccache(no_ccache), .no_trun(no_trun), .no_capfirst(no_capfirst), .gte_old(gte_old), .cpu_fast(cpu_fast), .gpu_fast(gpu_fast), .cd_disc_in(cd_disc_in), .cd_sb_we(cd_sb_we), .cd_sb_addr(cd_sb_addr), .cd_sb_data(cd_sb_data), .cd_sb_done(cd_sb_done), .cd_sb_lba(cd_sb_lba),
			.cd_fill_lba_o(cd_fill_lba), .cd_fill_room_o(cd_fill_room), .cd_fill_run_o(cd_fill_run), .cd_dbg_o(cd_dbg), .cd_dbg_cmds_o(cd_dbg_cmds), .cd_dbg_setloc_o(cd_dbg_setloc), .cd_dbg_seek_o(cd_dbg_seek), .cd_dbg_hdr_o(cd_dbg_hdr), .cd_trace_idx(cd_trace_idx), .cc_flush(cc_flush), .cc_flush_busy(cc_flush_busy), .cd_trace_data(cd_trace_data), .cd_trace_wp(cd_trace_wp), .cd_dma_words_o(cd_dma_words),
			.dbg_icv_pc(ps1_icv_pc), .dbg_icv_got(ps1_icv_got), .dbg_icv_want(ps1_icv_want), .dbg_icv_n(ps1_icv_n),
			.dbg_exec(ps1_dbg_exec), .dbg_rsel(ps1_rsel), .dbg_rval(ps1_rval),
			.fs_en(fs_en), .fs_arm(fs_arm), .fs_empty(fs_empty), .fs_ready(fs_ready), .fs_rd(stream_frd && !from_ddr), .fs_data(fs_data_w), .fs_valid(fs_valid_w),
			.joy1(joy1), .joy2(joy2), .vram_flush(vram_flush_go), .vram_flush_busy(vram_flush_busy), .cap_every_vsync(stream_ctl[30]),
			.dbg_watch(ps1_watch), .dbg_watch_hit(ps1_watch_hit), .dbg_watch_nz(ps1_watch_nz), .dbg_watch_pulse(ps1_watch_pulse), .dbg_watch_npulse(ps1_watch_npulse),
			.dbg_a0(ps1_a0), .dbg_a1(ps1_a1), .dbg_ra(ps1_ra), .dbg_sp(ps1_sp),
			.dbg_wa_en(ps1_wa_en), .dbg_wa_reg(ps1_wa_reg), .dbg_wa_val(ps1_wa_val), .dbg_wb_en(ps1_wb_en), .dbg_wb_reg(ps1_wb_reg), .dbg_wb_val(ps1_wb_val), .dbg_word(ps1_dbg_word), .dbg_fill(ps1_dbg_fill),
			.hr_go(hr_go), .hr_line(hr_line), .hr_done(hr_done), .hr_data(hr_data),
			.dbg_node_v(ps1_node_v), .dbg_node_addr(ps1_node_addr), .dbg_node_hdr(ps1_node_hdr),
			.fb_cap_go(fb_cap_go), .fb_cap_ready(fb_cap_ready), .fb_width(fb_width), .fb_height(fb_height),
			.fbr_addr(from_ddr ? sfa[17:0] : fbr_addr), .fbr_req(from_ddr ? sfr : fbr_req),
			.fbr_rdata(fbr_rdata_w), .fbr_ack(fbr_ack_w),
			.spu_out(audio_lr), .spu_out_we(audio_lr_we),
			.dma_relax(dma_relax), .ev_idx(ev_idx), .ev_data(ps1_ev_data), .ev_wp(ps1_ev_wp),
			.card_in(card_in), .card_fill(card_fill), .card2_in(card2_in), .card2_fill(card2_fill),
			.card_wq_sector(card_wq_sector), .card_wq_count(card_wq_count),
			.card_wq_ovf(card_wq_ovf), .card_wq_pop(card_wq_pop), .card_wq_clr(card_wq_clr),
			.toc_we(toc_we), .toc_addr(toc_addr), .toc_data(wdata),
			.xa_lba(xa_lba), .xa_count(xa_count), .xa_pop(xa_pop),
			.xa_we(xa_we), .xa_wdata(wdata), .xa_level(xa_level), .xa_gen(xa_gen), .xa_filt(xa_filt)
		);
	end else begin : g_ps1
		if (!CORE_N64) begin : g_no_lr      // the N64 drives it when it is the core
			assign audio_lr = 32'd0; assign audio_lr_we = 1'b0;
		end
		assign ps1_ev_data = 32'd0; assign ps1_ev_wp = 6'd0;
		assign ps1_px_valid = 1'b0;
		assign ps1_px_x = 9'd0; assign ps1_px_y = 9'd0; assign ps1_px_rgb = 8'd0;
		assign ps1_dbg_pc = 32'd0;
		assign ps1_dbg_io_addr = 32'd0; assign ps1_dbg_io_data = 32'd0;
		assign ps1_dbg_gpu_wr = 32'd0; assign ps1_gpu_pop = 1'b0; assign ps1_gpu_popword = 32'd0;
		assign ps1_dbg_mem = 32'd0; assign ps1_dbg_daddr = 32'd0; assign ps1_dbg_irq = 32'd0;
		assign ps1_dbg_gpu_st = 32'd0;
		assign ps1_dbg_cause = 32'd0; assign ps1_dbg_epc = 32'd0; assign ps1_dbg_dma = 32'd0; assign ps1_dbg_gpu2 = 32'd0; assign ps1_dbg_disp = 32'd0; assign ps1_dbg_draw = 32'd0;
		assign ps1_dbg_exec = 1'b0; assign ps1_dbg_word = 32'd0; assign ps1_rval = 32'd0;
		assign ps1_watch_hit = 32'd0;
		assign vram_flush_busy = 1'b0;
		assign ps1_watch_nz = 32'd0; assign ps1_watch_pulse = 1'b0; assign ps1_watch_npulse = 1'b0;
		assign ps1_a0 = 32'd0; assign ps1_a1 = 32'd0; assign ps1_ra = 32'd0; assign ps1_sp = 32'd0;
		assign ps1_wa_en = 1'b0; assign ps1_wb_en = 1'b0; assign ps1_wa_reg = 5'd0; assign ps1_wb_reg = 5'd0; assign ps1_wa_val = 32'd0; assign ps1_wb_val = 32'd0;
		assign ps1_dbg_fill = 32'd0;
		if (!CORE_N64) begin : g_no_hr
			assign hr_done = 1'b0; assign hr_data = 128'd0;   // the N64 answers these when it is the core
		end
		assign card_wq_sector = 11'd0; assign card_wq_count = 5'd0; assign card_wq_ovf = 1'b0;
		assign xa_lba = 24'd0; assign xa_count = 5'd0; assign xa_level = 13'd0; assign xa_gen = 8'd0; assign xa_filt = 1'b0;
		assign ps1_node_v = 1'b0; assign ps1_node_addr = 24'd0; assign ps1_node_hdr = 32'd0;
		assign fb_width = 10'd0; assign fb_height = 9'd0;
		if (!CORE_N64) begin : g_no_frame          // the N64 answers these when it is the core
			assign fb_cap_ready = 1'b0;
			assign fbr_rdata_w = 32'd0; assign fbr_ack_w = fbr_req;   // no frame here: answer at once
		end
		assign fs_data_w = 32'd0; assign fs_valid_w = 1'b0;
	end endgenerate

		// The NES numbers its visible dots 1..256, so x is one less than the cycle.
	// The Master System counts from zero and needs no such correction.
	//
	// The Mega Drive arrives already resolved -- its own valid, its own
	// coordinates, its own RGB -- and at full clock rate rather than gated by
	// `ce`, because it is not running at one dot per enable like the other two.
	//
	// This used to stop at 256, because the framebuffer did: in H40 the VDP is
	// 320 across, and writing those pixels into a 256-wide buffer would wrap
	// them onto the next line and shear the picture. Dropping them cost a game
	// its right quarter, which at least looked like a crop rather than a broken
	// VDP.
	//
	// The buffer is 320 now, so the clamp has to be too -- and it is not just
	// about H40. md_console blanks the columns the picture does not reach, so
	// that the 64 left over in H32 do not keep the video generator's colour
	// bars; a clamp at 256 throws those blanks away along with everything else
	// and the bars stay exactly where they were. Widening the buffer without
	// widening this does nothing at all, which is precisely what it did.
	wire md_in_frame  = (md_px_x  < 9'd320) && (md_px_y  < 9'd240);
	wire ps1_in_frame = (ps1_px_x < 9'd320) && (ps1_px_y < 9'd240);

	assign px_valid = ps1_sel ? (ps1_px_valid && ps1_in_frame)
	                : md_sel  ? (md_px_valid && md_in_frame)
	                          : (core_pixel_en && ce);
	assign px_x     = ps1_sel ? ps1_px_x
	                : md_sel  ? md_px_x
	                          : (nes_sel ? (core_px - 9'd1) : core_px);
	assign px_y     = ps1_sel ? ps1_px_y : md_sel ? md_px_y  : core_py;
	assign px_rgb   = ps1_sel ? ps1_px_rgb : md_sel ? md_px_rgb : core_rgb;

	assign hr_go = ctrl_we && (off == 16'h007C);
	// the last sixteen linked-list headers the DMA read, oldest at nt_wr
	wire nt_bad = (ps1_node_hdr[23:0] != 24'hFFFFFF) && (ps1_node_hdr[1:0] != 2'b00 || ps1_node_hdr[23:21] != 3'd0);   // the terminator is not a link
	always @(posedge clk) begin
		if (rst || !run) begin nt_wr <= 4'd0; nt_frozen <= 1'b0; end
		else if (ps1_node_v && !nt_frozen) begin
			ntrace_a[nt_wr] <= ps1_node_addr; ntrace_h[nt_wr] <= ps1_node_hdr; nt_wr <= nt_wr + 4'd1;
			if (nt_bad || gpw_frozen) nt_frozen <= 1'b1;   // a bad link, or the drawing engine stalled mid-command: keep the last 16 headers
		end
	end   // the line lands in hr_line on the same edge

	// --- the PC trace ----------------------------------------------------------
	// When a program dies at an address like 1 the only useful question is
	// the GP0 word capture: from the first popped word whose opcode matches (or any, 0x100) until 64 are in
	always @(posedge clk) begin
		if (rst) begin gpw_n <= 6'd0; gpw_frozen <= 1'b0; gpw_stall <= 20'd0; gpw_arm_seen <= gpw_arm_tog; end
		else begin
			if (gpw_arm_seen != gpw_arm_tog) begin gpw_arm_seen <= gpw_arm_tog; gpw_frozen <= 1'b0; gpw_stall <= 20'd0; end
			else if (!gpw_frozen && ps1_gpu_pop) begin gpw[gpw_n] <= ps1_gpu_popword; gpw_n <= gpw_n + 6'd1; end
			// waiting for arguments (D_ARG = 2) with nothing in the FIFO: a stall
			// of a million clocks (20 ms) is a stream that ended mid-command
			if (ps1_dbg_gpu_st[24 +: 6] == 6'd2 && ps1_dbg_gpu_st[11:0] == 12'd0) begin
				if (gpw_stall != 20'hFFFFF) gpw_stall <= gpw_stall + 20'd1; else gpw_frozen <= 1'b1;
			end else gpw_stall <= 20'd0;
		end
	end
	// the snapshots: the CPU's registers at the last zero write, and the PC/sp of
	// the last non-zero write, to the watched word
	always @(posedge clk) begin
		if (ps1_watch_pulse) begin
			snap_a0 <= ps1_a0; snap_a1 <= ps1_a1; snap_ra <= ps1_ra; snap_sp <= ps1_sp; snap_pc <= ps1_dbg_pc;
		end
		if (ps1_watch_npulse) begin snapn_pc <= ps1_dbg_pc; snapn_sp <= ps1_sp; end
	end
	// A clock of pipeline before any of this is compared. It is a debugging
	// aid -- which register was written, at which PC, with which value -- and
	// comparing it live put a 32-bit compare fed from deep inside the processor
	// on the critical path of the whole design: 28 levels of logic, and the
	// build that came out of it would not run at all.
	reg         ps1_exec_d, ps1_wa_en_d, ps1_wb_en_d;
	reg  [4:0]  ps1_wa_reg_d, ps1_wb_reg_d;
	reg  [31:0] ps1_wa_val_d, ps1_wb_val_d, ps1_pc_d, ps1_rval_d;
	always @(posedge clk) begin
		ps1_exec_d   <= ps1_dbg_exec;  ps1_pc_d   <= ps1_dbg_pc;   ps1_rval_d <= ps1_rval;
		ps1_wa_en_d  <= ps1_wa_en;     ps1_wa_reg_d <= ps1_wa_reg; ps1_wa_val_d <= ps1_wa_val;
		ps1_wb_en_d  <= ps1_wb_en;     ps1_wb_reg_d <= ps1_wb_reg; ps1_wb_val_d <= ps1_wb_val;
	end
	wire        rw_hit = (ps1_wa_en_d && ps1_wa_reg_d == ps1_rsel[4:0]) || (ps1_wb_en_d && ps1_wb_reg_d == ps1_rsel[4:0]);
	wire [31:0] rw_val = (ps1_wb_en_d && ps1_wb_reg_d == ps1_rsel[4:0]) ? ps1_wb_val_d : ps1_wa_val_d;
	always @(posedge clk) begin
		if (rst || !run) begin rw_wr <= 4'd0; rw_frozen <= 1'b0; end
		else if (rw_hit && !rw_frozen) begin
			rwtrace_pc[rw_wr] <= ps1_pc_d; rwtrace_v[rw_wr] <= rw_val; rw_wr <= rw_wr + 4'd1;
			if (rw_freeze_pc == 32'd0 && rw_val == rw_freeze_val && ps1_pc_d[31:16] == 16'h8005) rw_frozen <= 1'b1;
		end
		if (rw_freeze_pc != 32'd0 && ps1_exec_d && ps1_pc_d == rw_freeze_pc && ps1_rval_d == rw_freeze_val && !(rst || !run))
			rw_frozen <= 1'b1;
	end
	wire pc_freeze_now = (rw_freeze_pc != 32'd0) && ps1_dbg_exec && (ps1_dbg_pc == rw_freeze_pc) && (ps1_rval == rw_freeze_val);
	// "what were the instructions before that". Write the index to 0x64, read
	// 0x64; 0x68 is {frozen, write pointer} -- the pointer is the oldest entry.
	wire [4:0] pct_code = ps1_dbg_cause[6:2];
	always @(posedge clk) begin
		if (rst || !run) begin pct_wr <= 4'd0; pct_frozen <= 1'b0; pct_last <= 32'd0; end
		else if (!pct_frozen) begin
			// one entry per COMMITTED instruction: its address and its word.
			// Recording every PC value instead left out delay slots and put in
			// fetches that were never run, and the trace read like a CPU bug.
			if (ps1_dbg_exec) begin
				pctrace[pct_wr] <= ps1_dbg_pc; pitrace[pct_wr] <= ps1_dbg_word;
				pct_wr <= pct_wr + 4'd1; pct_last <= ps1_dbg_pc;
			end
			if (pct_code != 5'd0 && pct_code != 5'd8) pct_frozen <= 1'b1;
			// ...and at a jump to address zero: the kernel keeps a copy of the
			// exception stub there, so a null call looks like an interrupt with
			// a stale EPC and the BIOS "returns" into the wrong context
			if (ps1_dbg_exec && ps1_dbg_pc == 32'd0) pct_frozen <= 1'b1;
			if (pc_freeze_now) pct_frozen <= 1'b1;
		end
	end

endmodule

`default_nettype wire
