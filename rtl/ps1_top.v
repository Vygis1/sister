//////////////////////////////////////////////////////////////////////////////////
// ps1_top.v - the PlayStation: CPU, GPU, the memory they share, and enough of
// the rest for the Sony BIOS to boot.
//
// Two worlds live in DDR3 and reach it through one arbiter: the CPU's (2 MB of
// main RAM and the 512 kB BIOS) and the GPU's (1 MB of VRAM). Each is behind a
// write-back line cache, so the CPU running code and the GPU drawing polygons
// share the controller the way they do on the console. The DMA controller
// reaches RAM through the CPU cache's second port, so a display list the CPU
// just built is the one the GPU gets.
//
// --- the DDR3 map (bytes) ------------------------------------------------------------
//   0x000000..0x0FFFFF   VRAM (1 MB)
//   0x100000..0x2FFFFF   main RAM (2 MB)
//   0x300000..0x37FFFF   BIOS (512 kB)
//
// --- the CPU map (physical; segment bits already stripped) ---------------------------
//   0x00000000..0x001FFFFF   main RAM     (cached -> DDR3)
//   0x1F800000..0x1F8003FF   scratchpad   (1 kB block RAM)
//   0x1F801000..0x1F802FFF   I/O          (GPU, DMA, IRQ, timers, and stubs)
//   0x1FC00000..0x1FC7FFFF   BIOS         (cached -> DDR3)
//
// --- the CPU stall -------------------------------------------------------------------
//
// The R3000's bus allows one wait cycle. DDR3 takes about thirty, so a cached
// access freezes the whole CPU -- `ce` is held low -- until the cache answers,
// then ticks once to let the instruction consume the data. Everything else
// (scratchpad, registers, stubs) answers next clock, which the one wait already
// covers, so only the DDR3 path ever stalls it.
//
// --- what is a stub ------------------------------------------------------------------
//
// The GTE (COP2) retires without computing: the BIOS's 2D screens draw, its 3D
// logo does not. The SPU and CD answer their probes with "nothing here" so the
// BIOS moves on rather than hanging. Each becomes real in its own step.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_top #(
	// the core's clock. Everything timed in clocks -- the console-rate enable, the drive, the
	// pad port, the GPU's 60 Hz raster -- is worked out from it, so it can run faster than 50 MHz
	// and the console still keeps the console's time (only the CPU and the drawing are quicker)
	parameter CLK_HZ = 50_000_000,
	// the debug hardware (performance counters, event ring, GTE write trace): 0 for a shipping image
	parameter DBG    = 1,
	// the older debug hardware -- 64 performance counters, the event ring, the GTE write
	// trace -- off unless asked for: the JTAG traces replaced them, and the debug image
	// no longer fits with them
	parameter DBG_OLD = 0
) (
	input  wire        clk,
	input  wire        rst,        // resets the memory infrastructure
	input  wire        cpu_run,    // 0 holds the CPU and GPU (while the BIOS loads)
	// STOP the processor where it stands, without resetting it. cpu_run is a
	// RESET line (core_rst = rst || !cpu_run), so clearing it to 'pause' the
	// machine puts the CPU back at bfc00000 and throws away everything worth
	// looking at -- which is what every tool that claimed to freeze the machine
	// was actually doing. This holds the clock enable instead: the picture stays
	// on the screen, video memory stops moving, and the display list, the
	// palettes and the textures can all be read at leisure and be CONSISTENT
	// with each other and with the frame on the page.
	input  wire        cpu_halt,

	// host fill of the BIOS into DDR3: byte offset within the 512 kB BIOS region
	input  wire [18:0] host_windex,
	input  wire        host_we,
	input  wire [31:0] host_wdata,

	// the memory card in slot 1 (ps1_sio.v). Its 128 kB are in DDR3 at CARD_LINE;
	// with card_fill set the host's fill above lands there instead of in the
	// BIOS. The queue says which sectors the console has stored since the PC
	// last looked, so the PC can copy them into the card's file.
	input  wire        card_in,
	input  wire        card_fill,
	input  wire        card2_in,        // the card in slot 2, 128 kB after card 1
	input  wire        card2_fill,      // the host's fill goes to card 2
	output wire [10:0] card_wq_sector,  // {slot, sector}
	output wire [4:0]  card_wq_count,
	output wire        card_wq_ovf,
	input  wire        card_wq_pop,
	input  wire        card_wq_clr,

	// CD audio (ps1_cdrom.v): the disc's table of contents, and XA-ADPCM decoded
	// on the PC -- the sectors to decode out, the samples back in
	input  wire        toc_we,
	input  wire [7:0]  toc_addr,
	input  wire [31:0] toc_data,
	output wire [23:0] xa_lba,
	output wire [4:0]  xa_count,
	input  wire        xa_pop,
	input  wire        xa_we,
	input  wire [31:0] xa_wdata,
	output wire [12:0] xa_level,
	output wire [7:0]  xa_gen,
	output wire        xa_filt,

	// --- DDR3 line interface -------------------------------------------------------
	output wire [23:0]  d_addr,
	output wire         d_req,
	output wire         d_we,
	output wire [127:0] d_wdata,
	output wire [15:0]  d_wmask,
	input  wire [127:0] d_rdata,
	input  wire         d_ready,
	input  wire         d_valid,
	input  wire         d_calibrated,

	// --- the picture --------------------------------------------------------------------
	output wire        px_valid,
	output wire [8:0]  px_x,
	output wire [8:0]  px_y,
	output wire [7:0]  px_rgb,

	output wire [31:0] dbg_pc,
	// --- introspection: what the CPU last read from I/O, and how far the GPU got.
	// A booting BIOS that stalls sits polling one register; this says which and
	// with what answer, without a logic analyser on a chip that has no pins left.
	output reg  [31:0] dbg_io_addr,   // last I/O address the CPU read
	output reg  [31:0] dbg_io_data,   // the value it got back
	output reg  [31:0] dbg_gpu_wr,    // count of GP0/GP1 writes issued so far
	// the whole memory fabric's handshake, one bit each, and the line the DDR3
	// port is on -- when a DMA hangs these are steady and say who is not answering
	output reg  [31:0] dbg_mem,
	output reg  [31:0] dbg_daddr,
	// vblank edges seen and CPU interrupts raised -- says whether VSync is firing
	// and reaching the CPU, which is what advances the BIOS's intro frame to frame
	output reg  [31:0] dbg_irq,
	output wire [31:0] dbg_gpu_st,
	output wire        dbg_gpu_pop, output wire [31:0] dbg_gpu_popword,
	// the CPU's last exception: COP0 CAUSE and EPC
	output wire [31:0] dbg_cause,
	output wire [31:0] dbg_epc,
	// the GTE's debug snapshot (ps1_gte.v)
	input  wire        gte_snap_arm,
	input  wire        gte_snap_go,
	input  wire [15:0] gte_snap_skip,
	input  wire [6:0]  gte_snap_idx,
	output wire [31:0] gte_snap_data,
	output wire [24:0] gte_snap_word,
	output wire [1:0]  gte_snap_state,
	input  wire [5:0]  gte_wt_idx,      // the GTE write trace: entry (0 = the oldest of the 64)
	output wire [31:0] gte_wt_pc,       // ...the processor's PC as the write was taken
	output wire [31:0] gte_wt_data,     // ...the value
	output wire [5:0]  gte_wt_reg,      // ...{control, register}
	// the DMA engine: state, channel, ch2 busy, next-pointer
	output wire [31:0] dbg_dma,
	// the last four GP0 opcodes the GPU dispatched
	output wire [31:0] dbg_gpu2,
	output wire [31:0] dbg_disp,
	// console time lost: system clocks the processor's credit was full and went unspent (it
	// was held -- by memory, a DMA, the GPU -- longer than the console would have been), and
	// our clocks the GPU worked behind the console's time for its command
	output reg  [31:0] lost_cpu,
	output reg  [31:0] lost_gpu,
	output wire [31:0] dbg_live,     // now: why the processor waits, and what the GPU is doing
	output wire [31:0] dbg_cc_miss,  // the processor's RAM cache: misses so far...
	output reg  [31:0] dbg_cpu_wait, // ...and clocks it waited on the cache for a load or fetch
	output wire [31:0] dbg_draw,
	output wire [31:0] dbg_v2c,     // VRAM->CPU word accounting (see ps1_gpu)
	output wire [31:0] dbg_c0,      // and the size that transfer asked for
	// Where the machine's time goes, so "it feels slow" can be measured instead
	// of guessed at. One counter at a time, chosen by dbg_perf_sel.
	input  wire [5:0]  dbg_perf_sel,
	// the TTY (DBG): every character the program prints through the BIOS, in a 16 kB ring --
	// tty_count characters so far, the ring read a word (four characters, the first in [7:0])
	// at tty_idx, a clock after the index
	input  wire [11:0] tty_idx,
	// the GPU input trace (DBG): the last 2048 things that went INTO the GPU -- GP0 words from
	// the processor (type 0) or the DMA (1), GP1 writes (2) -- and the DMA's linked-list node
	// headers (3); it stops when the engine starts a command the BIOS never sends (an opcode
	// 03-1E) -- the place the stream it was given stopped making sense.
	// gtr_stat {frozen, armed, 18'd0, next index [11:0]}; gtr_arm (a pulse) clears and starts it.
	input  wire [10:0] gtr_idx,
	output reg  [31:0] gtr_word,
	output reg  [1:0]  gtr_head,
	output wire [31:0] gtr_stat,
	input  wire        gtr_arm,
	input  wire        gtr_pops,       // with the arm: trace what the engine TAKES (0 a command's head, 1 its words)
	input  wire        gtr_halt,       // with the arm: stop the processor when the trace freezes (memory kept as it was)
	output wire        dbg_rgb_odd,    // (debug) the first SWC2 of RGB2 whose code byte is not RGBC's (see rgb_odd_now)
	input  wire        fb_hr_raw,      // (DBG) the frame window reads DDR3 at fb_hr_base instead (VRAM: 0)
	input  wire [23:0] fb_hr_base,
	output reg  [31:0] tty_word,
	output reg  [31:0] tty_count,
	// Switches for the two paths that answer a read without asking memory, so
	// either can be taken out of the picture on a running board instead of
	// costing a ten-minute build to bisect.
	input  wire        no_icache,
	input  wire        no_ibuf,
	// With this set the instruction cache is answered from, and checked
	// against, the bus: every fetch still goes to memory, and the first word
	// the cache would have got wrong is latched with the address it was for.
	input  wire        ic_verify,
	input  wire        no_overlap,
	// The console's pace, or ours. The R3000 in a PlayStation runs at 33.8688
	// MHz; this one runs at the board's 50 MHz. With cpu_fast clear it is let
	// run on 33.8688 of every 50 million clocks, by a phase accumulator, so its
	// clock IS the console's (what it gets done per clock still depends on the
	// memory behind it, as on the console). The timers count that clock either
	// way -- they are the console's 33.8688 MHz counters whatever the CPU does.
	input  wire        cpu_fast,
	input  wire        gpu_fast,
	input  wire [3:0]  gte_old,       // debug: each bit puts one GTE fix back as it was
	input  wire        no_tcache, no_ccache, no_trun, no_capfirst,
	// the CD-ROM's sector transport (see ps1_cdrom.v): what it wants, and the bytes
	output wire [23:0] cd_fill_lba_o,
	output wire [3:0]  cd_fill_room_o,
	output wire        cd_fill_run_o,
	input  wire        cd_disc_in,
	input  wire        cd_sb_we,
	input  wire [11:0] cd_sb_addr,
	input  wire [7:0]  cd_sb_data,
	input  wire        cd_sb_done,
	input  wire [23:0] cd_sb_lba,
	output wire [31:0] cd_dbg_o,
	output wire [31:0] cd_dbg_cmds_o, cd_dbg_setloc_o, cd_dbg_seek_o, cd_dbg_hdr_o,
	input  wire [5:0]  cd_trace_idx,
	input  wire        cc_flush,        // a pulse: write every dirty line of the CPU cache back (host debugging)
	output wire        cc_flush_busy,
	output wire [31:0] cd_trace_data,
	output wire [5:0]  cd_trace_wp,
	output wire [15:0] cd_dma_words_o,
	output wire [31:0] dbg_perf,       // the counter dbg_perf_sel selects
	// the instruction-cache check: the first word it got wrong, and how many it checked
	output reg  [31:0] dbg_icv_pc, dbg_icv_got, dbg_icv_want, dbg_icv_n,
	input  wire [15:0] joy1,           // the web UI's pad, pressed bits in PS1 order
	input  wire [15:0] joy2,           // the second pad, in slot 2
	input  wire        cap_every_vsync,   // frame capture at every vertical sync (see ps1_gpu)
	input  wire        vram_flush,     // pulse: the VRAM cache writes its dirty lines back (for host dumps)
	output wire        vram_flush_busy,
	output wire        dbg_exec,
	input  wire [5:0]  dbg_rsel,
	output wire [31:0] dbg_rval,
	output wire [31:0] dbg_a0, dbg_a1, dbg_ra, dbg_sp,
	input  wire [20:0] dbg_watch,      // RAM word (byte address) whose writes are reported
	output reg  [31:0] dbg_watch_hit,  // last ZERO write: {cpu, dma, 6'd0, count[15:0], 8'd0}
	output reg  [31:0] dbg_watch_nz,   // last other write: {cpu, dma, 6'd0, count[15:0], data[7:0]}
	output wire        dbg_watch_pulse, dbg_watch_npulse,   // this cycle: a zero / non-zero write to the word
	output wire        dbg_wa_en, output wire [4:0] dbg_wa_reg, output wire [31:0] dbg_wa_val,
	output wire        dbg_wb_en, output wire [4:0] dbg_wb_reg, output wire [31:0] dbg_wb_val,
	output wire [31:0] dbg_word,
	// host-fill accounting: words seen, lines requested, lines taken by the arbiter
	output reg  [31:0] dbg_fill,
	// a host read of one DDR3 line: pulse hr_go with hr_line, then hr_data is
	// valid when hr_done -- the only way to look at RAM after a crash
	input  wire        hr_go,
	input  wire [23:0] hr_line,
	output reg         hr_done,
	output reg [127:0] hr_data,
	output wire        dbg_node_v,
	output wire [23:0] dbg_node_addr,
	output wire [31:0] dbg_node_hdr,
	// the display frame in DDR3: capture on request, read back a word at a time
	input  wire        fb_cap_go,
	// the picture on its way to the network without going through memory
	input  wire        fs_en,      // the network is taking the picture this way
	input  wire        fs_arm,
	output wire        fs_empty,
	output wire        fs_ready,    // the word at the head of the stream is the first of a capture
	input  wire        fs_rd,
	output wire [31:0] fs_data,
	output wire        fs_valid,
	output wire        fb_cap_ready,
	output wire [9:0]  fb_width,
	output wire [8:0]  fb_height,
	// HDMI: the scanout runs every frame (each flip, for a double-buffered game) and
	// its pixels -- RGB555, at half width in the wide modes -- go out here too
	input  wire        hdmi_on,
	input  wire [8:0]  lf_want,        // the line HDMI's line buffer wants next (n64_vid)
	output wire        lf_we,
	output wire [8:0]  lf_addr,
	output wire [127:0] lf_data,
	input  wire [17:0] fbr_addr,
	input  wire        fbr_req,
	output wire [31:0] fbr_rdata,
	output wire        fbr_ack,
	// the sound: one {right, left} sample per spu_out_we, 44.1 kHz
	output wire [31:0] spu_out,
	output wire        spu_out_we,
	// Let the processor run on through a DMA as long as it does not need the bus
	// (instruction-cache hits, the scratchpad, registers). Off: it stops dead the
	// moment any DMA starts, as it always has.
	input  wire        dma_relax,
	input  wire        cd_edc_on,      // the drive checks each data sector's EDC (see ps1_cdrom)
	input  wire        wq_off,         // (experiment) the CPU pace model charges loads no write-queue wait
	input  wire        lead_big,       // (experiment) with pace_long, a lead of 16,000 console cycles
	input  wire        run_ahead,      // (experiment) the processor may run up to 4,000 cycles ahead (see cpu_go)
	input  wire        pace_long,      // the processor may make up 4,000 console cycles, not 48 (see pace_credit)
	input  wire        dma_charge,     // a DMA costs the processor the console's cycle a word, not our time
	// the frame event log (see "where a frame goes" below)
	input  wire [5:0]  ev_idx,
	output wire [31:0] ev_data,
	output wire [5:0]  ev_wp
);
	localparam [23:0] RAM_LINE  = 24'h01_0000;   // 0x100000 >> 4
	localparam [23:0] BIOS_LINE = 24'h03_0000;   // 0x300000 >> 4
	localparam [23:0] CARD_LINE = 24'h09_0000;   // 9 MB: the memory card's 128 kB, after SPU RAM (8 MB)

	// ================================================================================
	// the CPU
	// ================================================================================
	wire [31:0] c_addr, c_dout, c_din;
	assign dbg_word = c_din;
	wire [3:0]  c_be;
	wire        c_we, c_req;
	wire        cpu_irq;
	wire        cpu_ready;
	wire        vz_active_w;
	wire        dma_hog, dma_in_flight;
	wire        dma_gpu_active;
	reg  [19:0] pace_acc;
	reg         sys_ce;                  // 33.8688 MHz, as an enable on the core's clock
	localparam [19:0] PACE_DEN = CLK_HZ / 100;
	always @(posedge clk) begin
		if (rst) begin pace_acc <= 20'd0; sys_ce <= 1'b0; end
		else if (pace_acc + 20'd338688 >= PACE_DEN) begin pace_acc <= pace_acc + 20'd338688 - PACE_DEN; sys_ce <= 1'b1; end
		else begin pace_acc <= pace_acc + 20'd338688; sys_ce <= 1'b0; end
	end
	// While a DMA is in flight -- paused on a full GPU FIFO or not -- the
	// processor's RAM accesses wait, as on the chip, where the DMA owns the bus
	// and the processor runs on only from its instruction cache. Released
	// during those pauses (which are long here, the drawing engine being bound
	// by DDR3), a game wrote its next display-list nodes into the buffer the
	// DMA was still walking, and the DMA read a node before it was written:
	// one word of a triangle, and the engine waited for the rest for ever.
	// I/O accesses (a GPUSTAT poll) still go through.
	wire        dma_ram_wait = dma_in_flight && c_req && (c_addr[28:21] == 8'h00 || c_addr[28:19] == 10'b11_1111_1000);   // RAM or BIOS (= `cached`, declared below)
	wire        dma_block;              // a DMA holds the processor (see below, after the decode)
	// The console's pace: the processor runs on this clock, and each instruction it finishes
	// is charged what the console's R3000A would have spent on it (r3000 t_cost); credit
	// comes in at the console's 33.8688 MHz and the processor waits while it is spent. It
	// was paced a cycle of ours to a cycle of the console's, so every load took two of its
	// own states' worth and cost ~2.4 cycles wherever it went: RAM twice as fast as the
	// console's, the BIOS ROM ten times, the SPU eight -- and the libraries' VSync() gave up
	// before every vertical blank. A short lead (CREDIT_MAX) is kept, so a wait on DDR3
	// can be made up, but never more than that.
	// With pace_long the lead is 4,000 cycles: a DDR3 miss, or a DMA held up on DDR3, is time a
	// console never loses, and with 48 the processor could make up almost none of it -- GT2
	// lost 22% of the console's time that way (cache misses 10%, DMA 7%) and ran 24 fps for 30.
	// The processor still never gets AHEAD of the console: credit is console time not yet spent.
	// A DMA then costs it what the console's would, a cycle a word (dma_charge), rather than
	// however long ours took; without dma_charge the credit stands still while a DMA holds it.
	wire signed [15:0] CREDIT_MAX = !pace_long ? 16'sd48 : lead_big ? 16'sd16000 : 16'sd4000;
	reg  signed [15:0] credit;
	wire [2:0]  dma_wc;                 // words a DMA moved this clock (declared with the DMA below)
	wire        t_take; wire [6:0] t_cost;
	// with run_ahead the processor may also get AHEAD of the console by up to 4,000 cycles in a
	// stretch where it is faster, and spend that in one where DDR3 or a DMA slows it -- averaged
	// over more than that it still runs at the console's pace, never faster
	wire        cpu_go = cpu_fast || (credit > (run_ahead ? -16'sd4000 : 16'sd0));
	wire        gpu_behind;
	wire        cpu_c2w;
	wire        gtr_stop;               // (debug) the GPU trace froze, armed to stop the processor
	wire [31:0] cc_hits, cc_misses;
	assign dbg_cc_miss = cc_misses;
	wire [11:0] gpu_live;
	always @(posedge clk)
		if (rst) begin lost_cpu <= 32'd0; lost_gpu <= 32'd0; end
		else begin
			if (sys_ce && !cpu_fast && credit == CREDIT_MAX && !(t_take && t_cost != 7'd0)) lost_cpu <= lost_cpu + 32'd1;
			if (gpu_behind) lost_gpu <= lost_gpu + 32'd1;
		end
	always @(posedge clk) begin : pace_credit
		reg signed [16:0] n;
		if (rst) credit <= 16'sd0;
		else begin
			n = credit + ((sys_ce && !(pace_long && !dma_charge && dma_block)) ? 17'sd1 : 17'sd0)
			           - (t_take ? $signed({10'd0, t_cost}) : 17'sd0)
			           - ((pace_long && dma_charge) ? $signed({14'd0, dma_wc}) : 17'sd0);
			credit <= (n > CREDIT_MAX) ? CREDIT_MAX : (n < -17'sd5000) ? -16'sd5000 : n[15:0];
		end
	end
	wire        cpu_ce = d_calibrated && cpu_ready && !vz_active_w && !dma_block && !dma_ram_wait   // a DMA owns the bus
	                     && !cpu_halt && !gtr_stop
	                     && cpu_go;
	wire        core_rst = rst || !cpu_run;

	// COP2 (the GTE) hangs off the CPU's coprocessor-2 port
	wire        c2_we, c2_ctl, c2_cmd, c2_busy;
	wire [4:0]  c2_reg, c2_wreg; wire c2_wctl;
	wire [31:0] c2_wdata, c2_rdata;
	wire [24:0] c2_word;

	wire [31:0] dbg_t1;                    // (the processor's t1, for the TTY below)
	r3000 cpu (
		.isc_inv(isc_inv), .isc_addr(isc_addr),
		.clk(clk), .rst(core_rst), .ce(cpu_ce),
		.addr(c_addr), .din(c_din), .dout(c_dout), .be(c_be), .we(c_we), .req(c_req),
		.fetch_addr(cpu_fa), .fetch_hit(cpu_fa_hit), .fetch_word(cpu_fa_word), .fetching(cpu_fetching),
		.no_overlap(no_overlap),
		.irq({5'd0, cpu_irq}),
		.c2_we(c2_we), .c2_ctl(c2_ctl), .c2_reg(c2_reg), .c2_wreg(c2_wreg), .c2_wctl(c2_wctl), .c2_wdata(c2_wdata),
		.c2_rdata(c2_rdata), .c2_cmd(c2_cmd), .c2_word(c2_word), .c2_busy(c2_busy),
		.dbg_pc(dbg_pc), .dbg_ir(), .dbg_exec(dbg_exec), .dbg_rsel(dbg_rsel), .dbg_rval(dbg_rval), .dbg_a0(dbg_a0), .dbg_a1(dbg_a1), .dbg_ra(dbg_ra), .dbg_sp(dbg_sp), .dbg_t1(dbg_t1), .dbg_c2w(cpu_c2w), .dbg_swc2_rgb2(cpu_swc2_rgb2), .wq_off(wq_off), .dbg_cost(cpu_cost), .t_take(t_take), .t_cost(t_cost),
		.dbg_wa_en(dbg_wa_en), .dbg_wa_reg(dbg_wa_reg), .dbg_wa_val(dbg_wa_val), .dbg_wb_en(dbg_wb_en), .dbg_wb_reg(dbg_wb_reg), .dbg_wb_val(dbg_wb_val), .dbg_halted(),
		.dbg_cause(dbg_cause), .dbg_epc(dbg_epc)
	);

	ps1_gte gte (
		.gte_old(gte_old),
		.clk(clk), .rst(core_rst),
		.we(c2_we), .ctl(c2_ctl), .reg_i(c2_reg), .wreg_i(c2_wreg), .wctl(c2_wctl), .wdata(c2_wdata), .rdata(c2_rdata),
		.cmd(c2_cmd), .word(c2_word), .busy(c2_busy),
		.snap_arm(gte_snap_arm), .snap_go(gte_snap_go), .snap_skip(gte_snap_skip), .snap_idx(gte_snap_idx),
		.snap_data(gte_snap_data), .snap_word(gte_snap_word), .snap_state(gte_snap_state),
		.wr_ok(gte_wr_ok), .dbg_drops(gte_drops), .dbg_rgbc(gte_rgbc), .snap_busy(gte_snap_busy)
	);
	// The GTE write trace: the last 64 register writes (MTC2, CTC2, LWC2) with the PC they were
	// taken at, stopped while the snapshot holds a command -- so stopped before an RTPS it shows
	// what loaded the matrix the RTPS uses, from which code. Gran Turismo 2 projected every
	// vertex onto one line: its rotation matrix had a zero middle row, and the GTE itself
	// checked right against the model on 30 of the game's commands.
	wire gte_wr_ok, gte_snap_busy;
	reg  [5:0]  gw_wp = 6'd0;
	(* ram_style = "distributed" *) reg [31:0] gw_pc [0:63];
	(* ram_style = "distributed" *) reg [31:0] gw_d  [0:63];
	(* ram_style = "distributed" *) reg [5:0]  gw_r  [0:63];
	always @(posedge clk) if (DBG && DBG_OLD && gte_wr_ok && !gte_snap_busy) begin
		gw_pc[gw_wp] <= dbg_pc; gw_d[gw_wp] <= c2_wdata; gw_r[gw_wp] <= {c2_wctl, c2_wreg}; gw_wp <= gw_wp + 6'd1;
	end
	wire [5:0] gw_ra = gw_wp + gte_wt_idx;
	assign gte_wt_pc = gw_pc[gw_ra]; assign gte_wt_data = gw_d[gw_ra]; assign gte_wt_reg = gw_r[gw_ra];

	// ================================================================================
	// CPU address decode
	// ================================================================================
	wire ram_hit  = (c_addr[28:21] == 8'h00);
	wire bios_hit = (c_addr[28:19] == 10'b11_1111_1000);   // 0x1FC00000, incl. bit 28
	wire spad_hit = (c_addr[28:10] == {13'h1F80, 6'd0});
	// The chip's CPU keeps executing during a DMA until it needs the bus: its
	// instruction cache and scratchpad are on the CPU's side. Ours stopped dead
	// the moment a transfer was even asked for -- measured 2026-09-28 in N. Sanity
	// Beach, 8.4% of all program-counter samples sat on the `jr ra` straight after
	// the game's DrawOTag kicked the display-list DMA. With dma_relax it waits only
	// for an access that goes to the bus (anything but the scratchpad).
	assign dma_block = dma_hog && (!dma_relax || (c_req && !spad_hit));
	wire io_hit   = (c_addr[28:16] == 13'h1F80) && !spad_hit;
	wire gpu_hit  = io_hit && (c_addr[15:4] == 12'h181);
	wire irq_hit  = io_hit && (c_addr[15:4] == 12'h107);
	wire tmr_hit  = io_hit && (c_addr[15:8] == 8'h11);
	wire dma_hit  = io_hit && (c_addr[15:7] == 9'b0001_0000_1);   // 0x1080..0x10FF
	wire mem_ctl  = io_hit && (c_addr[15:7] == 9'b0001_0000_0);   // 0x1000..0x107F
	wire cd_hit   = io_hit && (c_addr[15:4] == 12'h180);
	wire mdec_hit = io_hit && (c_addr[15:4] == 12'h182);
	wire mdec_rd_stall;
	wire [1:0] mdec_depth;
	wire pad_hit  = io_hit && (c_addr[15:4] == 12'h104);
	wire spu_hit  = io_hit && (c_addr[15:10] == 6'b0001_11);       // 0x1C00..0x1FFF: the SPU (1E00+ are its current volumes)
	wire cached   = ram_hit || bios_hit;

	// a cached CPU address, as a DDR3 line
	wire [23:0] cpu_line = ram_hit ? (RAM_LINE  + {8'd0, c_addr[20:4]})
	                               : (BIOS_LINE + {10'd0, c_addr[18:4]});
	// which 32-bit word of the 128-bit line
	wire [1:0]  cpu_wsel = c_addr[3:2];

	// ================================================================================
	// the CPU cache (its port A) -- built to speak byte addresses; feed it
	// {line, word, 00} so its own index/tag math lands in the DDR3 map
	// ================================================================================
	wire [28:0] cpu_ca = {cpu_line, cpu_wsel, 2'b00};

	wire [28:0] dm_addr;
	wire        isc_inv; wire [31:0] isc_addr;   // a store made with the cache isolated
	wire        dm_req, dm_we;
	wire [31:0] dm_wdata, dm_rdata;
	wire [127:0] dm_line;
	wire        dm_lwe; wire [15:0] dm_be16; wire [127:0] dm_wdata128;
	wire        dm_ack;

	wire [31:0] cc_rdata;
	wire        cc_ack;
	wire [23:0] cc_m_addr;  wire cc_m_req, cc_m_we;  wire [127:0] cc_m_wdata;
	wire        cc_m_ready; wire [127:0] cc_m_rdata; wire cc_m_valid;

	// the stall: freeze the CPU on a cached access until the cache answers THIS
	// access. The cache's ack is registered, so it can arrive a cycle or two
	// after the CPU has already walked on to the next access -- a fetch's ack
	// landing on the store that follows it (req never drops between them), or a
	// branch's ack landing on its delay-slot fetch (req drops, then rises). If
	// that stale ack were allowed to satisfy the next access, the CPU would read
	// a line the cache has not fetched and run on stale data. So `served` is
	// pinned to exactly one presentation: it clears the moment nothing is
	// presented (a gap) AND the moment the presented address changes under a
	// held req, and an ack only counts while the CPU is actually presenting.
	// Stores no longer go to the cache from here -- the buffer below carries
	// them -- so what is "present" to be waited for is reads and fetches.
	wire       present = cached && c_req && !c_we;
	reg        sb_v;                 // a store is in hand, not yet in the cache
	reg [28:0] sb_addr;
	// The store buffer holds a CACHE address -- the DDR3 line, with RAM's 0x100000 base added -- and the
	// DMA's line buffer is tagged by RAM address. Compared directly, bit 20 of the two always differed
	// (the base's carry), so no store ever reached the DMA: a list line the processor rewrote while the
	// DMA had it in hand was walked as it had been.
	wire [23:0] sb_ram = sb_addr[23:0] - {RAM_LINE[19:0], 4'd0};
	reg [31:0] sb_data;
	reg [3:0]  sb_be;
	reg        pres_d;
	reg [28:0] pres_addr;
	wire       acc_start = present && (!pres_d || cpu_ca != pres_addr);
	always @(posedge clk) begin
		pres_d <= present;
		if (present) pres_addr <= cpu_ca;
	end

	reg served;
	// The one acknowledgement that belongs to the access being presented right
	// now. The cache can answer after the processor has moved on -- a fetch's
	// answer arriving once the store behind it is already on the bus -- and
	// anything that remembers the line against the address showing at that
	// moment remembers it against the WRONG address. Everything read out of
	// that line afterwards is then somebody else's memory, which on the board
	// showed up as the BIOS loading a pointer that was never written and
	// faulting on it.
	// While a store sits in the buffer the cache port belongs to the buffer, so
	// an acknowledgement arriving then is the store's and nobody else's. Without
	// `!sb_v` a load presented behind a store was released by the store's ack and
	// read whatever the cache happened to be driving.
	wire cc_take = present && !acc_start && !served && cc_ack && !sb_v;

	// --- the line the processor is running out of -----------------------------
	// A cache hit costs several clocks and the processor waits through every one
	// of them, for every instruction. But instructions come in order, and a
	// cache line is four of them, so keeping the line the last fetch came from
	// answers the next three without touching the cache at all.
	//
	// It is dropped whenever anything writes through this cache -- the processor
	// or the DMA -- because either could be writing the very words it holds.
	// Writes are rare next to fetches, so the buffer survives long enough to be
	// worth having, and a stale instruction is not a risk worth taking.
	wire [127:0] cc_line;
	wire         cpu_fetching;    // this bus access is an instruction
	wire [31:0]  cpu_fa;          // the address the processor will fetch next
	wire         cpu_fa_hit, ic_hit_raw;
	wire [31:0]  cpu_fa_word;
	// --- the data cache -------------------------------------------------------
	// Measured on the board once everything else was done: a load cost four and
	// a third clocks, and loads are a fifth of all instructions. That was the
	// biggest thing left. This is the same 4 KB direct-mapped cache the
	// instructions use, answering in the cycle it is asked, filled only from
	// data reads so the two cannot evict each other. Answering fetches here
	// would be a fetch the instruction cache never sees and so never keeps,
	// which measured slower.
	//
	// The real machine has no data cache -- it has a scratchpad instead -- so
	// this is faster than hardware rather than faithful to it. Coherency is the
	// same conservative rule: any write to the sixteen bytes a line maps drops
	// that line, whoever wrote them.
	wire         d_hit;
	wire [31:0]  d_word;
	wire         ib_hit  = present && !c_we && d_hit && !no_ibuf && !cpu_fetching;
	wire [31:0]  ib_word = d_word;

	// --- the instruction cache -------------------------------------------------
	// 4 KB, as on the chip, answering in the cycle it is asked so the processor
	// never waits for an instruction it already has. Addressed in the
	// processor's own physical map, not the cache's DDR3 one, because that is
	// what the fetch has to hand.
	wire        fa_ram  = (cpu_fa[28:21] == 8'h00);
	wire        fa_bios = (cpu_fa[28:19] == 10'b11_1111_1000);
	wire [28:0] cpu_pa = c_addr[28:0];              // the physical address of the access

	// While verifying, the processor is told there is no hit so it fetches from
	// memory as it used to, and what the cache holds is compared with what came
	// back.
	assign cpu_fa_hit = ic_hit_raw && !ic_verify;
	always @(posedge clk) begin
		if (core_rst) begin
			dbg_icv_pc <= 32'd0; dbg_icv_got <= 32'd0; dbg_icv_want <= 32'd0; dbg_icv_n <= 32'd0;
		end else if (ic_verify && cc_take && !c_we && cpu_fetching && ic_hit_raw
		            && (cpu_fa_word != cc_rdata)) begin
			dbg_icv_n <= dbg_icv_n + 32'd1;
			if (dbg_icv_n == 32'd0) begin
				dbg_icv_pc   <= {3'd0, cpu_pa};
				dbg_icv_got  <= cpu_fa_word;
				dbg_icv_want <= cc_rdata;
			end
		end
	end

	// 4 KB, like the instruction one. Doubling it to 8 KB was tried and measured
	// on the board: identical speed, 29.8 MIPS either way, and it took the
	// timing margin from 0.43 ns down to 0.12. The loads that miss are not
	// missing for want of room.
	ps1_icache #(.IDXBITS(8), .WR_PATCH(1)) u_dcache (
		.clk(clk), .rst(core_rst),
		.fa(cpu_pa), .fa_ok(cached && !c_we && !cpu_fetching),
		.hit(d_hit), .word(d_word), .fa2(29'd0), .fa2_ok(1'b0), .hit2(), .line2(),
		.fill_en(cc_take && !c_we && !cpu_fetching),
		.fill_addr(cpu_pa), .fill_line(cc_line),
		.inv_a_en((c_req && c_we && cpu_ce && ram_hit) || isc_inv), .inv_a_addr(isc_inv ? {3'd0, isc_addr[28:0]} : cpu_pa),
		// A store made with the cache ISOLATED must DROP the line, never patch it:
		// the data never reached memory, and this cache patches a line in place
		// when a whole word lands in it. Leaving the byte enables as the store's
		// own wrote that store's zeros into the cached copy -- and the zeros the
		// BIOS writes over 0000..0FFF to clear the instruction cache then landed
		// on top of the kernel's jump tables, so the next BIOS call dispatched
		// into the table itself. The machine died at boot, every time, at 874h.
		.inv_a_be(isc_inv ? 4'd0 : c_be), .inv_a_data(c_dout),
		.inv_b_en(dm_req && dm_we && dm_ack),         .inv_b_addr({8'd0, dm_addr[20:0]})
	);

	ps1_icache u_icache (
		.clk(clk), .rst(core_rst),
		.fa(cpu_fa[28:0]), .fa_ok((fa_ram || fa_bios) && !no_icache),
		.hit(ic_hit_raw), .word(cpu_fa_word), .fa2(29'd0), .fa2_ok(1'b0), .hit2(), .line2(),
		// filled from the line the general cache hands back, but only for
		// instruction fetches: data reads would push instructions out
		.fill_en(cc_take && !c_we && cpu_fetching),
		.fill_addr(cpu_pa), .fill_line(cc_line),
		// anything that writes memory drops the line it maps to
		.inv_a_en((c_req && c_we && cpu_ce && ram_hit) || isc_inv), .inv_a_addr(isc_inv ? {3'd0, isc_addr[28:0]} : cpu_pa),
		.inv_a_be(4'd0), .inv_a_data(32'd0),
		.inv_b_en(dm_req && dm_we && dm_ack),         .inv_b_addr({8'd0, dm_addr[20:0]})
	);

	// The processor hands a store over and forgets it; the buffer drains into
	// the cache and clears when the cache answers. While it is full the cache is
	// the buffer's, which is what keeps a later access from overtaking it.
	always @(posedge clk) begin
		if (rst || !d_calibrated) sb_v <= 1'b0;
		// (the BIOS is a ROM: a store to it is taken and goes nowhere -- ps1-tests
		// cpu/io-access-bitwidth read back what it had written)
		else if (!sb_v && ram_hit && c_req && c_we && cpu_ce) begin
			sb_v    <= 1'b1;
			sb_addr <= cpu_ca;
			sb_data <= c_dout;
			sb_be   <= c_be;
		end else if (sb_v && cc_ack) sb_v <= 1'b0;
	end

	always @(posedge clk) begin
		if (rst)            served <= 1'b0;
		else if (!present)  served <= 1'b0;   // no cached access outstanding
		else if (acc_start) served <= ib_hit; // a different one just presented, unless we hold it
		else if ((cc_ack && !sb_v) || ib_hit) served <= 1'b1;
	end

	wire        gpu_gp0_full, gp0_wr;   // from the GPU and the DMA, declared here for the stall below
	wire [159:0] gpu_xfer; wire gpu_xfer_dry, gpu_xfer_on;
	wire [31:0]  gte_drops, gte_rgbc;
	wire [15:0]  cd_edc_bad;
	wire         cpu_swc2_rgb2;
	wire [191:0] cpu_cost;

	// (the RGB2-vs-RGBC check that found the interrupt-on-a-GTE-command bug: taken out for room,
	// commit 0ae39eb has it)
	assign dbg_rgb_odd = 1'b0;
	wire        gpu_rd_stall;           // GPUREAD asked for before the GPU has the word
	// A GP0 write waits while the GPU's FIFO is full or the DMA is pushing a
	// word this cycle: otherwise the word is lost and the command stream
	// desyncs (the FIFO sits full whenever the engine is slower than the BIOS).
	wire gp0_wait = gpu_hit && c_req && c_we && !c_addr[2] && (gpu_gp0_full || gp0_wr);
	// The BIOS reads a VRAM read-back faster than the engine can fetch it: it
	// polls the ready bit once and then runs a tight load loop, the way the
	// chip lets it, because the chip holds the bus until each word is there.
	// Answering early instead handed it the status word for one pixel and the
	// read-back stayed one word short for ever -- the BIOS froze on its next
	// poll. It only showed when the GPU was slowed by something else sharing
	// video memory, which is exactly what capturing frames for the web UI does.
	wire gpuread_wait = (gpu_hit && c_req && !c_we && !c_addr[2] && gpu_rd_stall)
	                 || (mdec_hit && c_req && !c_we && !c_addr[2] && mdec_rd_stall);   // (the MDEC's data port: the same wait)
	// A read the data cache already holds does not have to wait for `served`,
	// which is a clock later: the word is registered into din_r at the end of
	// this cycle, which is the cycle the processor collects it in anyway. That
	// is a whole clock off every load that hits, and loads are an eighth of all
	// instructions.
	// A store is ready the moment the buffer can take it. Everything else waits
	// for the cache, and for the buffer in front of it to be gone.
	assign cpu_ready = (!cached || !c_req
	                    || (c_we ? !sb_v : (!sb_v && (served || ib_hit || cc_take))))
	                   && !gp0_wait && !gpuread_wait;

	// --- the instruction-fetch run: TRIED, AND IT MADE THE GAME SLOWER ------
	// A miss fetched the whole aligned run of four lines instead of one, and
	// the three the processor had not asked for went into the instruction
	// cache. It did exactly what it was meant to: instruction-cache misses fell
	// from 11.6% of all clocks to 5.9%, load-miss stalls from 20.3% to 14.6%,
	// and the processor retired 15.5 M instructions a second against 14.1.
	//
	// And the GAME HALVED: one frame every 5.45 vertical syncs against 3.00,
	// measured over twenty seconds on the same scene, 11.0 flips a second
	// against 20.0. The memory was never saturated (2.99 M transactions a
	// second, and it refused a request 0.0% of the time) -- what changed is
	// LATENCY. A run puts four reads back to back into the arbiter, and every
	// other client's reads queue behind them; the drawing engine spent 1.8x the
	// clocks on the same scene. The processor got faster by making everything
	// else wait, and the frame is what the everything-else builds.
	//
	// If this is tried again: give the run its own arbiter port, or let it be
	// preempted, so it cannot push the engine's reads back. Do not simply turn
	// it on again.
	ps1_cache #(.IDXBITS(13), .FAST_ACK(1), .BRAM(1), .B_LINE(1)) ccache (
		.flush(cc_flush), .flush_busy(cc_flush_busy), .inv_v(1'b0), .inv_line(25'd0),
		.clk(clk), .rst(core_rst),   // a program is loaded under the cache's feet: forget every line
		// the buffered store first; the processor's reads only once it is gone
		.a_addr(sb_v ? sb_addr : cpu_ca), .a_around(1'b0), .a_lin(1'b0),
		.a_req(d_calibrated && (sb_v || (present && !served && !ib_hit))),
		.a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0),
		.a_we(sb_v), .a_be(sb_v ? sb_be : c_be), .a_wdata(sb_v ? sb_data : c_dout),
		.a_rdata(cc_rdata), .a_ack(cc_ack), .a_line(cc_line),
		// the DMA addresses CPU RAM (0..0x1FFFFF); the cache works in the DDR3
		// map, so lift it into the RAM region the same way port A lifts the CPU.
		.b_first(1'b0),
		.b_addr({RAM_LINE + {8'd0, dm_addr[20:4]}, dm_addr[3:0]}),
		// ...and never ahead of a store the processor has handed over but the
		// cache has not taken yet: a game writes a display-list node's header
		// last and starts the DMA in the next instruction, and the DMA read it
		// before the store landed -- the header of whatever last sat in that
		// slot, size 1 for an environment primitive, so one word of a nine-word
		// triangle went out and the engine waited for the rest for ever.
		.b_req(dm_req && !sb_v), .b_we(dm_we), .b_be(4'hF), .b_lwe(dm_lwe), .b_be16(dm_be16), .b_wdata128(dm_wdata128),
		.b_wdata(dm_wdata), .b_rdata(dm_rdata), .b_ack(dm_ack), .b_line(dm_line),
		.m_addr(cc_m_addr), .m_req(cc_m_req), .m_we(cc_m_we), .m_wdata(cc_m_wdata), .m_wmask(cc_m_wmask),
		.m_ready(cc_m_ready), .m_rdata(cc_m_rdata), .m_valid(cc_m_valid),
		.dbg_hits(cc_hits), .dbg_misses(cc_misses)
	);

	// ================================================================================
	// scratchpad (1 kB block RAM)
	// ================================================================================
	reg [31:0] spad [0:255];
	always @(posedge clk) begin
		if (spad_hit && c_req && c_we && cpu_ce) begin
			if (c_be[0]) spad[c_addr[9:2]][7:0]   <= c_dout[7:0];
			if (c_be[1]) spad[c_addr[9:2]][15:8]  <= c_dout[15:8];
			if (c_be[2]) spad[c_addr[9:2]][23:16] <= c_dout[23:16];
			if (c_be[3]) spad[c_addr[9:2]][31:24] <= c_dout[31:24];
		end
	end

	// ================================================================================
	// the GPU and its VRAM cache
	// ================================================================================
	wire [31:0] gpu_rdata;
	wire [28:0] v_addr, s_addr;
	wire        v_req, v_we, s_req;
	wire [127:0] s_vline;
	wire [3:0]  v_be;
	wire [31:0] v_wdata, v_rdata, s_rdata;
	wire        v_lwe;
	wire [127:0] v_wdata128;
	wire        v_ack, s_ack;
	wire        gpu_vblank, gpu_hblank, gpu_dot_ce, gpu_irq;
	wire        gpu_dma_rd;
	wire [31:0] gp0_data, gpu_dma_rdata;
	wire        gp0_ready, gpu_dma_rvalid;

	wire [23:0] vc_m_addr;  wire vc_m_req, vc_m_we;  wire [127:0] vc_m_wdata;
	wire        vc_m_ready; wire [127:0] vc_m_rdata; wire vc_m_valid;

	// scan_enable is what lets a capture start. It used to be fb_want OR the
	// stream's want, so the frame-in-DDR3 path could start a scan while the
	// straight-to-network path was still draining the previous frame. A scan
	// starting resets fb_stream's pointers, the sender then found the buffer
	// empty, waited a millisecond and gave the frame up half sent -- and the
	// page was handed a picture with a black band through it.
	//
	// So while the direct stream is on, a capture may start only when there is
	// no WHOLE frame waiting to go out. Not "only when the stream asks": a
	// capture abandoned at a display flip leaves no whole frame and never asks
	// again, and the picture would stop for good at the first flip -- which in
	// a double-buffered game is immediately.
	wire        fpx_valid, scan_start, scan_done, scan_abort, scan_busy, fb_hold, fb_want;
	// Whole lines go to the frame in DDR3; the network's own path takes pixels,
	// so the line route is only used when the frame writer is the one reading.
	wire         gfl_valid;
	wire [127:0] gfl_data;
	wire [9:0]   gfl_x;
	wire [8:0]   gfl_y;
	wire [9:0]  fpx_x, gpu_disp_w; wire gpu_v480, gpu_weave, gpu_wfield;
	wire [8:0]  fpx_y;
	wire [15:0] fpx_rgb;

	ps1_gpu #(.CLK_HZ(CLK_HZ)) gpu (
		.clk(clk), .rst(core_rst),
		.sel(gpu_hit & c_req & cpu_ce), .we(c_we), .a4(c_addr[2]), .dma_active(dma_gpu_active), .cap_every_vsync(cap_every_vsync), .gpu_fast(gpu_fast), .no_tcache(no_tcache), .no_ccache(no_ccache), .no_trun(no_trun),
		.wdata(c_dout), .rdata(gpu_rdata),
		.dma_wr(gp0_wr), .dma_data(gp0_data), .dma_ready(gp0_ready),
		.dma_rd(gpu_dma_rd), .dma_rdata(gpu_dma_rdata), .dma_rvalid(gpu_dma_rvalid), .gp0_full(gpu_gp0_full),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(v_around), .v_lin(v_lin), .v_one(v_one),
		.tx_valid(vx_valid), .tx_addr(vx_addr), .tx_line(vx_line),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack),
		.s_addr(s_addr), .s_req(s_req), .s_rdata(s_rdata), .s_ack(s_ack), .s_line(s_vline),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.vblank(gpu_vblank), .hblank(gpu_hblank), .dot_ce(gpu_dot_ce), .irq(gpu_irq),
		.dbg_gpu(dbg_gpu_st), .dbg_gpu2(dbg_gpu2), .dbg_pop(dbg_gpu_pop), .dbg_pophead(dbg_gpu_pophead), .dbg_popword(dbg_gpu_popword),
		.dbg_in_v(gin_v), .dbg_in_type(gin_type), .dbg_in_word(gin_word), .dbg_disp(dbg_disp), .dbg_behind(gpu_behind), .dbg_live(gpu_live), .dbg_draw(dbg_draw), .dbg_v2c(dbg_v2c), .dbg_c0(dbg_c0), .dbg_xfer(gpu_xfer), .dbg_xfer_dry(gpu_xfer_dry), .dbg_xfer_on(gpu_xfer_on), .rd_stall(gpu_rd_stall),
		.fpx_valid(fpx_valid), .fpx_x(fpx_x), .fpx_y(fpx_y), .fpx_rgb(fpx_rgb),
		.scan_start(scan_start), .scan_done(scan_done), .scan_abort(scan_abort), .every_flip(fs_en || hdmi_on), .scan_busy(scan_busy), .scan_hold(fb_hold || (fs_en && fs_hold)), .scan_enable(fs_en ? fs_want : (fb_want || hdmi_on)), .disp_w(gpu_disp_w), .disp_v480(gpu_v480), .cap_weave(gpu_weave), .cap_field(gpu_wfield),
		.scan_lines(fb_want && !fs_en),
		.fl_valid(gfl_valid), .fl_data(gfl_data), .fl_x(gfl_x), .fl_y(gfl_y)
	);

	// Straight from the scanout to the network. See fb_stream.v: the round trip
	// through DDR3 cost 42 ms a frame and held the web page to fifteen frames a
	// second.
	wire fs_hold, fs_want;
	// A queue of 2K words, not a frame. It used to be a whole frame (64K words,
	// 64 block RAMs) so a capture could be read at VRAM speed and finish before
	// the game flipped: at the time a capture took longer than a frame, and one
	// read at network pace tore. The capture is three times cheaper now and the
	// network sends a half-width frame in about 13 ms against 33-50 ms between
	// the game's flips, so the scanout reads the buffer on screen at the
	// network's pace, starting at a flip, and a flip in the middle abandons the
	// frame (every_flip) rather than tearing it. The frame is put together on
	// the PC, from the id and offset every packet already carries.
	fb_stream #(.AW(11)) u_fs (
		.clk(clk), .rst(core_rst),
		.frame_start(scan_start), .frame_done(scan_done), .abort(scan_abort),
		.px_valid(fpx_valid), .px_x(fpx_x), .px_rgb(fpx_rgb),
		.hold(fs_hold),
		.rd_en(fs_rd), .rd_data(fs_data), .rd_valid(fs_valid), .head_sof(fs_ready),
		.arm(fs_arm), .want(fs_want), .empty(fs_empty)
	);

	// the display frame in DDR3 (see fb_ddr.v): 640 x 240 x RGB555 at 4 MB
	fb_ddr u_fb (
		.clk(clk), .rst(rst),
		.frame_start(scan_start), .frame_abort(scan_abort), .px_valid(fpx_valid), .px_x(fpx_x), .px_y(fpx_y), .px_rgb(fpx_rgb),
		.fl_valid(gfl_valid), .fl_data(gfl_data), .fl_x(gfl_x), .fl_y(gfl_y),
		.hold(fb_hold), .want(fb_want),
		.cap_go(fb_cap_go), .cap_ready(fb_cap_ready),
		.hr_addr(fbr_addr), .hr_req(fbr_req), .hr_raw(DBG ? fb_hr_raw : 1'b0), .hr_base(fb_hr_base), .hr_rdata(fbr_rdata), .hr_ack(fbr_ack),
		.m_addr(fb_m_addr), .m_req(fb_m_req), .m_we(fb_m_we), .m_wdata(fb_m_wdata),
		.m_ready(fb_m_ready), .m_rdata(fb_m_rdata), .m_valid(fb_m_valid),
		.hdmi_on(hdmi_on), .weave(gpu_weave), .weave_field(gpu_wfield), .lf_want(lf_want), .lf_words(fb_width[9:3] + {6'd0, fb_width[2:0] != 3'd0}),
		.lf_we(lf_we), .lf_addr(lf_addr), .lf_data(lf_data)
	);
	// Wide modes are captured at half width: the scanout emits every other
	// pixel, so a 512-wide display is 256 columns and 640 is 320. Reporting 320
	// for both packed a 512 game's 256-pixel rows into 320-pixel rows on the
	// page: the picture sheared into repeats of itself.
	// full width and, for a 480-line mode, 480 rows (ps1_gpu's capture): HDMI shows them 1:1
	assign fb_width  = gpu_disp_w;
	assign fb_height = gpu_v480 ? 9'd480 : 9'd240;

	// the draw port goes through a write combiner (see vram_wc.v): a line of
	// pixels per cache access instead of one, and no DDR3 fetch for a full line
	wire [28:0]  wc_addr; wire wc_req, wc_we, wc_lwe, wc_around; wire [3:0] wc_be; wire [31:0] wc_wdata, wc_rdata;
	wire         v_around; wire v_lin; wire v_one; wire gp_lin; wire wc_lin;
	wire         vx_valid; wire [24:0] vx_addr; wire [127:0] vx_line;   // the rest of a texel run
	wire [127:0] wc_line, v_line;     // the whole line a draw read came from
	wire [15:0]  wc_be16; wire [127:0] wc_wdata128; wire wc_ack;
	// The engine's writes no longer go through the combiner and the cache at
	// all: ps1_vram_port hands them to a block writer that posts sixteen pixels
	// at a time straight to the arbiter (see ps1_gpu_blk.v). Only reads go on.
	wire [28:0]  gp_addr; wire gp_req, gp_around, gp_ack; wire [31:0] gp_rdata; wire [127:0] gp_line;
	wire [23:0]  bk_m_addr; wire bk_m_req, bk_m_we, bk_m_ready; wire [127:0] bk_m_wdata; wire [15:0] bk_m_wmask;
	wire         bk_inv_v; wire [24:0] bk_inv_line;
	wire         bk_busy, vc_flush_busy;
	ps1_vram_port u_vp (
		.clk(clk), .rst(core_rst),
		.v_addr(v_addr), .v_req(v_req & d_calibrated), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(v_around), .v_lin(v_lin), .v_one(v_one),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack),
		.eng_idle(!gpu.busy), .host_flush(vram_flush), .busy(bk_busy),
		.g_addr(gp_addr), .g_req(gp_req), .g_around(gp_around), .g_lin(gp_lin),
		.g_rdata(gp_rdata), .g_line(gp_line), .g_ack(gp_ack),
		.m_addr(bk_m_addr), .m_req(bk_m_req), .m_we(bk_m_we), .m_wdata(bk_m_wdata), .m_wmask(bk_m_wmask), .m_ready(bk_m_ready),
		.inv_v(bk_inv_v), .inv_line(bk_inv_line)
	);
	assign vram_flush_busy = vc_flush_busy || bk_busy;
	vram_wc u_wc (
		.clk(clk), .rst(core_rst),
		.g_addr(gp_addr), .g_req(gp_req), .g_we(1'b0), .g_be(4'hF), .g_wdata(32'd0),
		.g_lwe(1'b0), .g_wdata128(128'd0), .g_around(gp_around), .g_lin(gp_lin), .c_around(wc_around), .c_lin(wc_lin),
		.g_rdata(gp_rdata), .g_line(gp_line), .g_ack(gp_ack),
		.c_addr(wc_addr), .c_req(wc_req), .c_we(wc_we), .c_lwe(wc_lwe), .c_be(wc_be), .c_wdata(wc_wdata),
		.c_be16(wc_be16), .c_wdata128(wc_wdata128), .c_rdata(wc_rdata),
		.c_line(wc_line), .c_ack(wc_ack)
	);

	// Port B here is the scanout: it reads around the cache so that walking the
	// displayed frame every 1/60 s stops evicting what the drawing engine is using.
	ps1_cache #(.IDXBITS(9), .B_NOALLOC(1), .A_AROUND(1)) vcache (
		.flush(vram_flush), .flush_busy(vc_flush_busy),
		.clk(clk), .rst(core_rst),
		.inv_v(bk_inv_v), .inv_line(bk_inv_line),
		.a_addr(wc_addr), .a_req(wc_req), .a_we(wc_we), .a_be(wc_be), .a_wdata(wc_wdata), .a_around(wc_around), .a_lin(wc_lin),
		.a_lwe(wc_lwe), .a_be16(wc_be16), .a_wdata128(wc_wdata128),
		.a_rdata(wc_rdata), .a_ack(wc_ack),
		.b_first(scan_busy && !no_capfirst),
		.b_addr(s_addr), .b_req(s_req & d_calibrated), .b_we(1'b0), .b_be(4'hF), .b_wdata(32'd0), .b_lwe(1'b0), .b_be16(16'd0), .b_wdata128(128'd0),
		.b_rdata(s_rdata), .b_ack(s_ack), .b_line(s_vline), .a_line(wc_line),
		.x_valid(vx_valid), .x_addr(vx_addr), .x_line(vx_line),
		.m_addr(vc_m_addr), .m_req(vc_m_req), .m_we(vc_m_we), .m_wdata(vc_m_wdata), .m_wmask(vc_m_wmask),
		.m_ready(vc_m_ready), .m_rdata(vc_m_rdata), .m_valid(vc_m_valid),
		.dbg_hits(), .dbg_misses()
	);

	reg         vz_active;
	reg  [16:0] vz_line;
	assign vz_active_w = vz_active;
	// ================================================================================
	// host fill of the BIOS: four words -> a line, one arbiter client
	// ================================================================================
	reg  [127:0] hf_line;
	reg          hf_req_r;
	reg  [23:0]  hf_addr_r;
	wire         hf_ready;
	always @(posedge clk) begin
		if (rst) dbg_fill <= 32'd0;
		else begin
			if (host_we) dbg_fill[15:0] <= dbg_fill[15:0] + 16'd1;
			if (host_we && host_windex[3:2] == 2'd3) dbg_fill[23:16] <= dbg_fill[23:16] + 8'd1;
			if (hf_req_r && hf_ready && !vz_active) dbg_fill[31:24] <= dbg_fill[31:24] + 8'd1;
		end
	end
	always @(posedge clk) begin
		if (rst) hf_req_r <= 1'b0;
		else begin
			if (host_we) begin
				hf_line[host_windex[3:2]*32 +: 32] <= host_wdata;
				if (host_windex[3:2] == 2'd3) begin
					hf_req_r  <= 1'b1;
					hf_addr_r <= card2_fill ? CARD_LINE + 24'h2000 + {11'd0, host_windex[16:4]}
					           : card_fill ? CARD_LINE + {11'd0, host_windex[16:4]}
					                       : BIOS_LINE + {5'd0, host_windex[18:4]};
				end
			end
			if (hf_req_r && hf_ready && !vz_active) hf_req_r <= 1'b0;   // the sweep owns the port first
		end
	end

	// ================================================================================
	// VRAM starts as zeros. DDR3 powers up holding noise, and the BIOS never
	// clears VRAM: its fading full-screen quads carry the frame buffer's origin
	// in their vertices AND set the drawing offset to it, so the second buffer's
	// clear lands below its drawing area and is clipped away -- on a console
	// whose VRAM is blank that costs nothing, on ours it showed a frame of
	// static every other frame. Sweep the megabyte with zeros once, out of
	// reset, on the host-fill port, holding the CPU until it is done.
	// ================================================================================
	// The sweep starts the moment the core is RELEASED. While it is held the
	// host is filling the BIOS through this same port, and a sweep that ran
	// during the hold took the port for itself: the BIOS never landed and the
	// CPU ran whatever DDR3 held from the previous program.
	reg         core_rst_d;
	wire        vz_req = vz_active;
	always @(posedge clk) begin
		core_rst_d <= core_rst;
		if (core_rst) begin vz_active <= 1'b0; vz_line <= 17'd0; end
		else if (core_rst_d) begin vz_active <= 1'b1; vz_line <= 17'd0; end   // released: sweep now
		else if (vz_active && hf_ready) begin
			vz_line <= vz_line + 17'd1;
			if (vz_line == 17'h0FFFF) vz_active <= 1'b0;
		end
	end

	// ================================================================================
	// the arbiter: VRAM port 0, CPU port 1, host-fill (and the sweep) port 2
	// ================================================================================
	wire [5:0]   p_ready;
	wire [767:0] p_rdata;
	wire [5:0]   p_valid;
	// the host read shares port 2; it waits its turn behind a fill or the sweep
	reg          hr_req, hr_go_d;
	reg  [23:0]  hr_addr;
	always @(posedge clk) hr_go_d <= hr_go;
	// The memory card shares it too, last in line. Replies come back in order
	// but carry no owner, so only ONE read is out on this port at a time (p4_rd),
	// and it remembers whose it is (p4_mc).
	wire [13:0]  mc_line; wire mc_req, mc_we; wire [127:0] mc_wdata;
	reg          p4_rd, p4_mc;
	wire         hr_turn = hr_req && !hf_req_r && !vz_active && !p4_rd;
	wire         mc_turn = mc_req && !hf_req_r && !vz_active && !hr_req && (mc_we || !p4_rd);
	wire         mc_ready = mc_turn && hf_ready;
	wire         mc_valid = p_valid[4] && p4_mc;
	always @(posedge clk) begin
		if (rst) begin hr_req <= 1'b0; hr_done <= 1'b0; hr_addr <= 24'd0; hr_data <= 128'd0; p4_rd <= 1'b0; p4_mc <= 1'b0; end
		else begin
			if (hr_go_d) begin hr_req <= 1'b1; hr_addr <= hr_line; hr_done <= 1'b0; end   // hr_line is stable a cycle after hr_go
			if (hr_turn && hf_ready) begin hr_req <= 1'b0; p4_rd <= 1'b1; p4_mc <= 1'b0; end
			if (mc_turn && !mc_we && hf_ready) begin p4_rd <= 1'b1; p4_mc <= 1'b1; end
			if (p_valid[4]) begin
				p4_rd <= 1'b0;
				if (!p4_mc) begin hr_data <= p_rdata[639:512]; hr_done <= 1'b1; end
			end
		end
	end
	wire [23:0]  hf_p_addr  = vz_active ? {8'd0, vz_line[15:0]} : hr_turn ? hr_addr : mc_turn ? CARD_LINE + {10'd0, mc_line} : hf_addr_r;
	wire [127:0] hf_p_wdata = vz_active ? 128'd0 : mc_turn ? mc_wdata : hf_line;
	wire         hf_p_we    = hr_turn ? 1'b0 : mc_turn ? mc_we : 1'b1;
	// port 3: the display frame
	wire [23:0]  fb_m_addr; wire fb_m_req, fb_m_we; wire [127:0] fb_m_wdata;
	wire         fb_m_ready, fb_m_valid; wire [127:0] fb_m_rdata;

	// 0 the processor's cache, 1 the VRAM cache, 2 the engine's block writer, 3 the frame capture,
	// 4 the host, 5 the SPU. The processor first: its misses are what it waits on, one at a time,
	// and behind the GPU's traffic they averaged 24 clocks -- 26% of GT2's clocks spent waiting on
	// memory, the largest single loss (the console's RAM answers in ~5 cycles). The arbiter's
	// starvation guard still promotes anyone kept waiting 64 cycles.
	wire [23:0]  sp_m_addr; wire sp_m_req, sp_m_we, sp_m_ready, sp_m_valid;
	wire [127:0] sp_m_wdata, sp_m_rdata; wire [15:0] sp_m_wmask;
	wire [143:0] p_addr  = {sp_m_addr,  hf_p_addr,  fb_m_addr,  bk_m_addr,  vc_m_addr,  cc_m_addr};
	wire [5:0]   p_req   = {sp_m_req,   hf_req_r | vz_req | hr_turn | mc_turn, fb_m_req, bk_m_req, vc_m_req, cc_m_req};
	wire [5:0]   p_we    = {sp_m_we,    hf_p_we,    fb_m_we,    bk_m_we,    vc_m_we,    cc_m_we};
	wire [767:0] p_wdata = {sp_m_wdata, hf_p_wdata, fb_m_wdata, bk_m_wdata, vc_m_wdata, cc_m_wdata};
	wire [15:0]  vc_m_wmask, cc_m_wmask;
	wire [95:0]  p_wmask = {sp_m_wmask, 16'hFFFF, 16'hFFFF, bk_m_wmask, vc_m_wmask, cc_m_wmask};
	assign sp_m_ready = p_ready[5]; assign sp_m_valid = p_valid[5]; assign sp_m_rdata = p_rdata[767:640];

	assign cc_m_ready = p_ready[0]; assign vc_m_ready = p_ready[1]; assign bk_m_ready = p_ready[2]; assign fb_m_ready = p_ready[3]; assign hf_ready = p_ready[4];
	assign cc_m_valid = p_valid[0]; assign vc_m_valid = p_valid[1]; assign fb_m_valid = p_valid[3];
	assign cc_m_rdata = p_rdata[127:0];
	assign vc_m_rdata = p_rdata[255:128];
	assign fb_m_rdata = p_rdata[511:384];

	// The arbiter and the DDR3 path are memory infrastructure: they live on the
	// GLOBAL reset. On the core's reset they sat dead while the host was filling
	// the BIOS through them, acknowledging every line and issuing none.
	mem_arb #(.PORTS(6), .AW(24)) arb (
		.clk(clk), .rst(rst),
		.p_addr(p_addr), .p_req(p_req), .p_we(p_we), .p_wdata(p_wdata), .p_wmask(p_wmask),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(d_addr), .m_req(d_req), .m_we(d_we), .m_wdata(d_wdata), .m_wmask(d_wmask),
		.m_ready(d_ready), .m_rdata(d_rdata), .m_valid(d_valid)
	);

	// ================================================================================
	// interrupts, timers, DMA
	// ================================================================================
	wire [31:0] irq_rdata, tmr_rdata, dma_rdata;
	wire [2:0]  tmr_irq;
	wire        dma_irq, gpu_vblank_edge;
	reg         dma_irq_d;  always @(posedge clk) dma_irq_d <= dma_irq;   // for the interrupt counter
	reg         vbl_d;
	// the console's own numbering: 0 VBLANK, 1 GPU, 2 CDROM, 3 DMA, 4/5/6 TMR0-2,
	// then controller, SIO, SPU, PIO. The BIOS enables the DMA and timer lines and
	// waits on them during boot, so they have to sit where it expects.
	// the controller port: SIO0 with a digital pad in slot 1
	wire [31:0] sio_rdata;
	wire        sio_irq;
	// (the 50 MHz counts scaled to CLK_HZ in kHz, as small factors: 120000 * 52631 is past a
	// Verilog integer's 2^31, and the 52.6 MHz image got the CD's second response 3x too soon)
	ps1_sio #(.SHIFT_CYCLES((CLK_HZ / 1000) * 7 / 250)) u_sio (
		.clk(clk), .rst(core_rst),
		.sel(pad_hit & c_req & cpu_ce), .we(c_we), .addr(c_addr[3:0]), .be(c_be), .wdata(c_dout), .rdata(sio_rdata),
		.buttons(joy1), .buttons2(joy2), .irq(sio_irq), .card2_in(card2_in),
		.rst_q(rst), .card_in(card_in),
		.m_line(mc_line), .m_req(mc_req), .m_we(mc_we), .m_wdata(mc_wdata),
		.m_ready(mc_ready), .m_valid(mc_valid), .m_rdata(p_rdata[639:512]),
		.wq_sector(card_wq_sector), .wq_count(card_wq_count), .wq_ovf(card_wq_ovf),
		.wq_pop(card_wq_pop), .wq_clr_ovf(card_wq_clr)
	);
	// the CD-ROM controller: registers, FIFOs and the response protocol, no disc
	wire [31:0] cd_rdata;
	wire        cd_irq;
	wire        cd_dma_rd, cd_dma_rvalid, cd_dma_go; wire [31:0] cd_dma_rdata, cd_dma_go_info; wire [15:0] cd_dma_words;
	wire signed [15:0] cd_audio_l, cd_audio_r;   // CD-DA / XA, to the SPU
	wire        cd_tick;                         // the SPU's 44.1 kHz tick (made further down)
	wire [23:0] cd_fill_lba; wire [3:0] cd_fill_room; wire cd_fill_run; wire [31:0] cd_dbg, cd_dbg_cmds, cd_dbg_setloc, cd_dbg_seek, cd_dbg_hdr;
	assign cd_fill_lba_o = cd_fill_lba; assign cd_fill_room_o = cd_fill_room; assign cd_fill_run_o = cd_fill_run; assign cd_dbg_o = cd_dbg; assign cd_dbg_cmds_o = cd_dbg_cmds; assign cd_dbg_setloc_o = cd_dbg_setloc; assign cd_dbg_seek_o = cd_dbg_seek; assign cd_dbg_hdr_o = cd_dbg_hdr; assign cd_dma_words_o = cd_dma_words;
	// The processor's enable for an I/O access: cpu_ce without its cache terms, which an
	// uncached address never waits on (cpu_ready is then just !gp0_wait && !gpuread_wait).
	// The same value for every access these devices see -- and the caches' hit logic is no
	// longer in front of their registers' write enables (52.6 MHz missed by 0.57 ns there).
	wire        cpu_ce_io = d_calibrated && !gp0_wait && !gpuread_wait && !vz_active_w && !dma_block && !dma_ram_wait
	                        && !cpu_halt && !gtr_stop && cpu_go;
	// (the acknowledge: 50,401 console cycles, Init's 81,102 -- psx-spx; 1.488 / 2.395 ms)
	ps1_cdrom #(.ACK_CYCLES((CLK_HZ / 1000) * 1488 / 1000), .SECOND_CYCLES((CLK_HZ / 1000) * 12 / 5),
	            .INIT_ACK_CYCLES((CLK_HZ / 1000) * 2395 / 1000), .INIT_DONE_CYCLES((CLK_HZ / 1000) * 14),
	            .PAUSE_DONE_CYCLES((CLK_HZ / 1000) * 30),
	            .SEEK_CYCLES(CLK_HZ / 25), .SECTOR_1X(CLK_HZ / 75), .SECTOR_2X(CLK_HZ / 150)) u_cd (
		.clk(clk), .rst(core_rst),
		.sel(cd_hit & c_req & cpu_ce_io), .we(c_we), .addr(c_addr[3:0]), .be(c_be), .wdata(c_dout), .rdata(cd_rdata),
		.irq(cd_irq),
		.dma_rd(cd_dma_rd), .dma_rdata(cd_dma_rdata), .dma_rvalid(cd_dma_rvalid),
		.fill_lba(cd_fill_lba), .fill_room(cd_fill_room), .fill_run(cd_fill_run),
		.disc_in(cd_disc_in), .sb_we(cd_sb_we), .sb_addr(cd_sb_addr), .sb_data(cd_sb_data), .sb_done(cd_sb_done), .edc_on(cd_edc_on), .dbg_edc_bad(cd_edc_bad), .sb_lba(cd_sb_lba), .sb_abort(1'b0),
		.dbg(cd_dbg), .dbg_cmds(cd_dbg_cmds), .dbg_setloc(cd_dbg_setloc), .dbg_seek(cd_dbg_seek), .dbg_hdr(cd_dbg_hdr),
		.ev_v(cd_dma_go), .ev_data(cd_dma_go_info), .trace_idx(cd_trace_idx), .trace_data(cd_trace_data), .trace_wp(cd_trace_wp),
		.toc_we(toc_we), .toc_addr(toc_addr), .toc_data(toc_data),
		.tick(cd_tick), .cd_l(cd_audio_l), .cd_r(cd_audio_r),
		.xa_lba(xa_lba), .xa_count(xa_count), .xa_pop(xa_pop),
		.xa_we(xa_we), .xa_wdata(xa_wdata), .xa_level(xa_level), .xa_gen(xa_gen), .xa_filt(xa_filt)
	);
	// the SPU's side of DMA channel 4, its memory port and its interrupt
	wire        spu_dma_wr, spu_dma_ready, spu_dma_rd, spu_dma_rvalid, spu_irq;
	wire [31:0] spu_dma_wdata, spu_dma_rdata;
	wire [10:0] irq_src = {1'b0, spu_irq, 1'b0, sio_irq,   // 10 lightpen, 9 SPU, 8 SIO1; 7 controller
	                       tmr_irq[2], tmr_irq[1], tmr_irq[0],  // 6:4 TMR2..TMR0
	                       dma_irq,                    // 3 DMA
	                       cd_irq,                     // 2 CDROM
	                       gpu_irq,                    // 1 GPU
	                       gpu_vblank_edge};           // 0 VBLANK
	always @(posedge clk) vbl_d <= gpu_vblank;
	assign gpu_vblank_edge = gpu_vblank & ~vbl_d;

	ps1_irq u_irq (
		.clk(clk), .rst(core_rst), .src(irq_src),
		.sel(irq_hit & c_req & cpu_ce), .we(c_we), .a(c_addr[3:0]),
		.wdata(c_dout), .rdata(irq_rdata), .irq(cpu_irq)
	);

	ps1_timers u_timers (
		.clk(clk), .rst(core_rst),
		.sys_ce(sys_ce), .dot_ce(gpu_dot_ce), .hblank(gpu_hblank), .vblank(gpu_vblank),
		.sel(tmr_hit & c_req & cpu_ce), .we(c_we), .a(c_addr[5:0]),
		.wdata(c_dout), .rdata(tmr_rdata), .irq(tmr_irq)
	);

	// the MDEC (1F801820h / 24h), on DMA channels 0 and 1
	wire        mdec_wr, mdec_in_ready, mdec_dreq0, mdec_pop, mdec_rvalid, mdec_dreq1;
	wire [31:0] mdec_rdata, mdec_odata;
	ps1_mdec u_mdec (
		.clk(clk), .rst(core_rst),
		.sel(mdec_hit & c_req & cpu_ce_io), .we(c_we), .a2(c_addr[2]), .wdata(c_dout), .rdata(mdec_rdata),
		.in_wr(mdec_wr), .in_data(gp0_data), .in_ready(mdec_in_ready), .dreq0(mdec_dreq0),
		.out_rd(mdec_pop), .out_data(mdec_odata), .out_valid(mdec_rvalid), .dreq1(mdec_dreq1), .rd_stall(mdec_rd_stall), .out_depth(mdec_depth)
	);
	ps1_dma u_dma (
		.clk(clk), .rst(core_rst),
		.sel(dma_hit & c_req & cpu_ce), .we(c_we), .a(c_addr[7:0]),
		.wdata(c_dout), .rdata(dma_rdata),
		.r_addr(dm_addr), .r_req(dm_req), .r_we(dm_we), .r_wdata(dm_wdata),
		.r_rdata(dm_rdata), .r_line(dm_line), .r_ack(dm_ack), .r_lwe(dm_lwe), .r_be16(dm_be16), .r_wdata128(dm_wdata128), .snoop_v(sb_v), .snoop_a(sb_ram),
		.gp0_wr(gp0_wr), .gp0_data(gp0_data), .gp0_ready(gp0_ready),
		.gpu_rd(gpu_dma_rd), .gpu_rdata(gpu_dma_rdata), .gpu_rvalid(gpu_dma_rvalid),
		.cd_rd(cd_dma_rd), .cd_rdata(cd_dma_rdata), .cd_rvalid(cd_dma_rvalid), .cd_go(cd_dma_go), .cd_go_info(cd_dma_go_info), .cd_words(cd_dma_words),
		.spu_wr(spu_dma_wr), .spu_data(spu_dma_wdata), .spu_ready(spu_dma_ready),
		.spu_rd(spu_dma_rd), .spu_rdata(spu_dma_rdata), .spu_rvalid(spu_dma_rvalid),
		.mdec_wr(mdec_wr), .mdec_in_ready(mdec_in_ready), .mdec_dreq0(mdec_dreq0),
		.mdec_pop(mdec_pop), .mdec_rdata(mdec_odata), .mdec_rvalid(mdec_rvalid), .mdec_dreq1(mdec_dreq1), .mdec_depth(mdec_depth),
		.hog(dma_hog), .in_flight(dma_in_flight),
		.gpu_active(dma_gpu_active),
		.dbg_node_v(dbg_node_v), .dbg_node_addr(dbg_node_addr), .dbg_node_hdr(dbg_node_hdr),
		.irq(dma_irq), .dbg_dma(dbg_dma)
	);
	// the words a DMA moved this clock, for the processor's pace (the console's DMA moves a word a
	// cycle): into a device, out of one into RAM, a line of the ordering-table clear, a list header
	wire [2:0] dm_lw = {2'd0, |dm_be16[3:0]} + {2'd0, |dm_be16[7:4]} + {2'd0, |dm_be16[11:8]} + {2'd0, |dm_be16[15:12]};
	assign dma_wc = (gp0_wr || spu_dma_wr || mdec_wr || dbg_node_v ? 3'd1 : 3'd0)
	              + ((dm_req && dm_ack && dm_we) ? (dm_lwe ? dm_lw : 3'd1) : 3'd0);

	// ================================================================================
	// the stubs the BIOS probes
	// ================================================================================
	reg [31:0] memctl [0:31];
	always @(posedge clk) if (mem_ctl && c_req && c_we && cpu_ce)
		memctl[c_addr[6:2]] <= c_dout;

	// ================================================================================
	// the SPU: 24 voices, its RAM in DDR3 (arbiter port 5), DMA channel 4, IRQ 9
	// ================================================================================
	// One sample every 768 cycles of the console's own 33.8688 MHz, counted on the
	// same enable the timers use, so the sound keeps the console's time: 44.1 kHz.
	reg  [9:0]  spu_div;
	reg         spu_tick;
	always @(posedge clk) begin
		spu_tick <= 1'b0;
		if (core_rst) spu_div <= 10'd0;
		else if (sys_ce) begin
			if (spu_div == 10'd767) begin spu_div <= 10'd0; spu_tick <= 1'b1; end
			else spu_div <= spu_div + 10'd1;
		end
	end
	wire [31:0] spu_rdata;
	assign cd_tick = spu_tick;
	ps1_spu u_spu (
		.clk(clk), .rst(core_rst),
		.sel(spu_hit & c_req & cpu_ce_io), .we(c_we), .addr(c_addr[9:0]), .be(c_be), .wdata(c_dout), .rdata(spu_rdata),
		.tick(spu_tick), .irq(spu_irq),
		.cd_l(cd_audio_l), .cd_r(cd_audio_r),
		.dma_wr(spu_dma_wr), .dma_wdata(spu_dma_wdata), .dma_ready(spu_dma_ready),
		.dma_rd(spu_dma_rd), .dma_rdata(spu_dma_rdata), .dma_rvalid(spu_dma_rvalid),
		.m_addr(sp_m_addr), .m_req(sp_m_req), .m_we(sp_m_we), .m_wdata(sp_m_wdata), .m_wmask(sp_m_wmask),
		.m_ready(sp_m_ready), .m_rdata(sp_m_rdata), .m_valid(sp_m_valid),
		.out_lr(spu_out), .out_we(spu_out_we)
	);
	wire [31:0] stub_rdata =
	      mem_ctl ? memctl[c_addr[6:2]]
	    : spu_hit ? spu_rdata
	    // Expansion 2 (1F802000h on): an 8-bit bus with nothing on it reads all ones
	    // (ps1-tests cpu/io-access-bitwidth)
	    : (c_addr[28:13] == 16'hFC01) ? 32'hFFFF_FFFF
	    :           32'd0;              // the rest: zero

	// ================================================================================
	// what the CPU reads, registered one clock after the address
	// ================================================================================
	// Latched on the clock the processor is let run (cpu_ce): the devices answer
	// the request's own clock, and a read with a side effect (GPUREAD pops a
	// word) must not be latched again on the frozen clocks between that one
	// and the one the processor consumes it on. A cached answer is stable once
	// served, and the freeze waits for it, so it may land any clock.
	reg [31:0] din_r;
	always @(posedge clk) if (cpu_ce || cached) begin
		if (cached)         din_r <= (d_hit && !c_we) ? d_word : cc_rdata;
		else if (spad_hit)  din_r <= spad[c_addr[9:2]];   // one clock after the address, like everything else
		                                                  // (a registered copy in between made every read one access stale)
		else if (gpu_hit)   din_r <= gpu_rdata;
		else if (irq_hit)   din_r <= irq_rdata;
		else if (tmr_hit)   din_r <= tmr_rdata;
		else if (dma_hit)   din_r <= dma_rdata;
		else if (cd_hit)    din_r <= cd_rdata;
		else if (mdec_hit)  din_r <= mdec_rdata;
		else if (pad_hit)   din_r <= sio_rdata;
		else                din_r <= stub_rdata;
	end
	assign c_din = din_r;

	// a write watchpoint on one RAM word: the LAST write of zero and the LAST
	// write of anything else before the CPU is looked at (each with the PC and
	// the count of such writes), so a crash can be traced back to whoever left
	// the word as it was found. CPU stores and the DMA's port B are both seen.
	wire w_cpu = ram_hit && c_req && c_we && cpu_ce && (c_addr[20:2] == dbg_watch[20:2]);
	wire w_dma = dm_req && dm_we && (dm_addr[20:2] == dbg_watch[20:2]);
	wire [31:0] w_data = w_cpu ? c_dout : dm_wdata;
	reg  [20:0] watch_d;
	reg  [15:0] wz_count, wn_count;
	always @(posedge clk) begin
		watch_d <= dbg_watch;
		if (rst || watch_d != dbg_watch) begin
			dbg_watch_hit <= 32'd0; dbg_watch_nz <= 32'd0; wz_count <= 16'd0; wn_count <= 16'd0;
		end else if (w_cpu || w_dma) begin
			if (w_data == 32'd0) begin
				dbg_watch_hit <= {w_cpu, w_dma, 6'd0, wz_count + 16'd1, 8'd0}; wz_count <= wz_count + 16'd1;
			end else begin
				dbg_watch_nz  <= {w_cpu, w_dma, 6'd0, wn_count + 16'd1, w_data[7:0]}; wn_count <= wn_count + 16'd1;
			end
		end
	end
	assign dbg_watch_pulse = (w_cpu || w_dma) && (w_data == 32'd0);
	assign dbg_watch_npulse = (w_cpu || w_dma) && (w_data != 32'd0);
	// --- where the time goes -------------------------------------------------------
	// 0 clocks, 1 memory transactions started, 2 clocks the CPU spent held up,
	// 3 instructions executed, 4 clocks a DMA held the bus, 5 video-memory cache
	// misses, 6 CPU cache misses, 7 clocks the drawing engine was busy.
	// which sixteenth of the frame we are in: the bin edge walks forward by a
	// sixteenth of the last frame's length, which avoids a divider.
	reg  [3:0]  ph_bin;
	reg  [19:0] ph_next;
	wire [19:0] ph_step = gpu.frame_len >> 4;
	always @(posedge clk) begin
		if (rst || gpu.frame_tick) begin ph_bin <= 4'd0; ph_next <= ph_step; end
		else if (gpu.post_vsync >= ph_next && ph_bin != 4'd15) begin
			ph_bin  <= ph_bin + 4'd1;
			ph_next <= ph_next + ph_step;
		end
	end

	// how long one whole read of the screen takes, start to finish
	reg        cap_run;
	reg [31:0] cap_clk;
	wire       cap_done = cap_run && fb_cap_ready;
	always @(posedge clk) begin
		if (rst) begin cap_run <= 1'b0; cap_clk <= 32'd0; end
		else if (!cap_run && fb_cap_go)  begin cap_run <= 1'b1; cap_clk <= 32'd0; end
		else if (cap_run && fb_cap_ready) cap_run <= 1'b0;
		else if (cap_run) cap_clk <= cap_clk + 32'd1;
	end

	reg pfb_d;
	always @(posedge clk) pfb_d <= vcache.pf_busy;

	// --- where a frame goes: a log of timestamped events ------------------------------
	// The counters above say how busy each part is on average; they cannot say
	// whether the processor and the drawing engine work at the same time or take
	// turns, which is the whole question for a frame rate that is quantised to
	// vertical syncs. So: the last 64 of these, each {type, 29-bit clock stamp}:
	//   0 the displayed buffer changed (the game flipped)
	//   1 the display-list DMA started    2 ...and finished (the list is sent)
	//   3 the drawing engine went idle with nothing queued (the frame is drawn)
	//   4 a vertical sync
	reg  [28:0] ev_clk;
	reg  [31:0] ev_ring [0:63];
	reg  [5:0]  ev_p;
	reg  [31:0] ev_disp_d;
	reg         ev_dma_d, ev_draw_d;
	wire        ev_draw = gpu.busy || !gpu.f_empty || dma_gpu_active;
	assign ev_wp   = ev_p;
	assign ev_data = ev_ring[ev_idx];
	always @(posedge clk) begin
		ev_clk <= ev_clk + 29'd1;
		ev_disp_d <= dbg_disp; ev_dma_d <= dma_gpu_active; ev_draw_d <= ev_draw;
		if (rst || !(DBG && DBG_OLD)) ev_p <= 6'd0;
		else if (dbg_disp[18:0] != ev_disp_d[18:0]) begin ev_ring[ev_p] <= {3'd0, ev_clk}; ev_p <= ev_p + 6'd1; end
		else if (ev_draw_d && !ev_draw)             begin ev_ring[ev_p] <= {3'd3, ev_clk}; ev_p <= ev_p + 6'd1; end
		else if (dma_gpu_active && !ev_dma_d)       begin ev_ring[ev_p] <= {3'd1, ev_clk}; ev_p <= ev_p + 6'd1; end
		else if (!dma_gpu_active && ev_dma_d)       begin ev_ring[ev_p] <= {3'd2, ev_clk}; ev_p <= ev_p + 6'd1; end
		else if (gpu_vblank_edge)                   begin ev_ring[ev_p] <= {3'd4, ev_clk}; ev_p <= ev_p + 6'd1; end
	end

	// --- the TTY: B(3Dh) std_out_putchar and A(3Ch) putchar, caught as the processor enters the
	// BIOS's call vector with the function number in t1 and the character in a0 -- what the
	// reference logs of the test suites (ps1-tests' psx.log) are made of, by emulators that hook
	// the same two calls. A byte lane an array, each written once: block RAM.
	wire        tty_hit = DBG && dbg_exec && ((dbg_pc[28:0] == 29'h000000B4 && dbg_t1 == 32'h3D)
	                                        || (dbg_pc[28:0] == 29'h000000A4 && dbg_t1 == 32'h3C));
	(* ram_style = "block" *) reg [7:0] tty0 [0:4095];
	(* ram_style = "block" *) reg [7:0] tty1 [0:4095];
	(* ram_style = "block" *) reg [7:0] tty2 [0:4095];
	(* ram_style = "block" *) reg [7:0] tty3 [0:4095];
	reg [7:0] tq0, tq1, tq2, tq3;
	always @(posedge clk) begin
		if (rst) tty_count <= 32'd0;
		else if (tty_hit) tty_count <= tty_count + 32'd1;
	end
	always @(posedge clk) if (tty_hit && tty_count[1:0] == 2'd0) tty0[tty_count[13:2]] <= dbg_a0[7:0];
	always @(posedge clk) if (tty_hit && tty_count[1:0] == 2'd1) tty1[tty_count[13:2]] <= dbg_a0[7:0];
	always @(posedge clk) if (tty_hit && tty_count[1:0] == 2'd2) tty2[tty_count[13:2]] <= dbg_a0[7:0];
	always @(posedge clk) if (tty_hit && tty_count[1:0] == 2'd3) tty3[tty_count[13:2]] <= dbg_a0[7:0];
	always @(posedge clk) begin tq0 <= tty0[tty_idx]; tq1 <= tty1[tty_idx]; tq2 <= tty2[tty_idx]; tq3 <= tty3[tty_idx]; end
	always @(*) tty_word = {tq3, tq2, tq1, tq0};

	wire       dbg_gpu_pophead;
	wire       gin_v; wire [1:0] gin_type; wire [31:0] gin_word;
	(* ram_style = "block" *) reg [31:0] gtr_w [0:2047];
	(* ram_style = "block" *) reg [1:0]  gtr_h [0:2047];
	// What went IN (CPU, DMA, GP1, list nodes) -- or, armed with gtr_pops, what the engine took out:
	// a wedged engine stops taking, so the ring then ends exactly where the stream went wrong, where
	// the words still queued behind it had pushed that point out of an input trace.
	reg        gtr_pm, gtr_hm;
	wire       gin_gp1  = gin_v && (gin_type == 2'd2);
	// (an upload's pixel words are left out: one wrong one runs to thousands, and would push
	// everything that led to it out of the ring)
	wire       gtr_ev   = gtr_pm ? ((dbg_gpu_pop && !(gpu_xfer_on && !dbg_gpu_pophead)) || gin_gp1) : (gin_v || dbg_node_v);
	wire [1:0] gtr_ty   = gtr_pm ? (gin_gp1 ? 2'd2 : dbg_gpu_pophead ? 2'd0 : 2'd1) : (gin_v ? gin_type : 2'd3);
	wire [31:0] gtr_in  = gtr_pm ? (gin_gp1 ? gin_word : dbg_gpu_popword) : (gin_v ? gin_word : dbg_node_hdr);
	reg [11:0] gtr_n; reg gtr_frozen, gtr_on;
	wire       gtr_take = DBG && gtr_on && !gtr_frozen && gtr_ev;
	wire       gtr_odd  = (dbg_gpu_pophead && (dbg_gpu_popword[31:24] >= 8'h03) && (dbg_gpu_popword[31:24] <= 8'h1E))
	                   || (dbg_node_v && gpu_xfer_dry)    // a list node while a CPU->VRAM transfer starves: it came up short
	                   // a transfer command with anything in its low bits: no library sends one, but a
	                   // packet's data word read as a command does (GT2: a06faf6f, then 7,752 words as pixels)
	                   || (dbg_gpu_pophead && (dbg_gpu_popword[31:29] == 3'b101 || dbg_gpu_popword[31:29] == 3'b110 || dbg_gpu_popword[31:29] == 3'b100)
	                       && dbg_gpu_popword[23:0] != 24'd0);
	always @(posedge clk) begin
		if (rst) begin gtr_n <= 12'd0; gtr_frozen <= 1'b0; gtr_on <= 1'b0; end
		else if (gtr_arm) begin gtr_n <= 12'd0; gtr_frozen <= 1'b0; gtr_on <= 1'b1; gtr_pm <= gtr_pops; gtr_hm <= gtr_halt; end
		else begin
			if (gtr_take) gtr_n <= gtr_n + 12'd1;
			if (DBG && gtr_on && gtr_odd) gtr_frozen <= 1'b1;
		end
	end
	always @(posedge clk) if (gtr_take) begin gtr_w[gtr_n[10:0]] <= gtr_in; gtr_h[gtr_n[10:0]] <= gtr_ty; end
	always @(posedge clk) begin gtr_word <= gtr_w[gtr_idx]; gtr_head <= gtr_h[gtr_idx]; end
	assign gtr_stat = {gtr_frozen, gtr_on, 18'd0, gtr_n};
	assign gtr_stop = DBG && gtr_frozen && gtr_hm;

	reg [31:0] perf [0:63];
	integer pk;
	initial for (pk = 0; pk < 64; pk = pk + 1) perf[pk] = 32'd0;
	always @(posedge clk) begin
		// NOT RESET. Every tool reads these as a difference between two samples,
		// and the reset was 2,048 flip-flops on the global reset net: the worst
		// path of the build at 0.002 ns of slack, 18.7 ns of pure routing from
		// the reset register to their reset pins (2026-09-27).
		if (DBG && DBG_OLD) begin
			perf[0] <= perf[0] + 32'd1;
			if (d_req && d_ready)            perf[1] <= perf[1] + 32'd1;
			if (c_req && !cpu_ce)            perf[2] <= perf[2] + 32'd1;
			if (cpu_ce && cpu.st == 3'd1)    perf[3] <= perf[3] + 32'd1;
			if (dma_hog)                     perf[4] <= perf[4] + 32'd1;
			if (vc_m_req && vc_m_ready)      perf[5] <= perf[5] + 32'd1;
			if (cc_m_req && cc_m_ready)      perf[6] <= perf[6] + 32'd1;
			if (gpu.busy)                    perf[7] <= perf[7] + 32'd1;
			// 8 instruction fetches that the instruction cache answered,
			// 9 fetches it missed, 10 loads, 11 stores, 12 clocks spent
			// collecting a load, 13 clocks a store took
			if (cpu.st == 4'd0)                          perf[8]  <= perf[8]  + 32'd1;
			if (cpu.st == 4'd6)                          perf[9]  <= perf[9]  + 32'd1;
			if (cpu.ce && cpu.st == 4'd7)                perf[10] <= perf[10] + 32'd1;
			if (cpu.ce && cpu.st == 4'd2)                perf[11] <= perf[11] + 32'd1;
			if (cpu.st == 4'd7 || cpu.st == 4'd3)        perf[12] <= perf[12] + 32'd1;
			if (cpu.st == 4'd2)                          perf[13] <= perf[13] + 32'd1;
			// 14 clocks the video cache spent waiting for a line to arrive,
			// 15 clocks the memory refused a request it was being offered.
			// Between them these say whether the drawing engine is held up
			// waiting for reads it asked for one at a time, or by the memory
			// simply not being able to take the writes fast enough. Those want
			// opposite fixes and guessing between them has cost two builds.
			if (vcache.st == 4'd5)                       perf[14] <= perf[14] + 32'd1;
			if (d_req && !d_ready)                       perf[15] <= perf[15] + 32'd1;
			// 16..23: the drawing engine is busy essentially always, so the only
			// question worth asking is busy doing what. 16 counts pixels it put
			// down; the rest are clocks, and they should add up to most of its
			// time. Between them they say whether a pixel costs what it costs
			// because of the box walk or because of one particular wait.
			// Pixels, not writes: the engine puts two out in one write when they
			// share a word, so counting writes made it look slower exactly when
			// it had got faster. All four byte enables set means two pixels.
			if (gpu.v_req && gpu.v_we && gpu.v_ack)
				perf[16] <= perf[16] + ((gpu.v_be == 4'b1111) ? 32'd2 : 32'd1);
			// the raster: 17 busy, 18 held for a texel line, 19 loading a palette,
			// 20 held for a destination line, 21 held by a full block queue,
			// 22 primitives started, 23 gradient set-up (D_GRADW) clocks
			if (gpu.r_busy)                              perf[17] <= perf[17] + 32'd1;
			if (gpu.r_st_tex)                            perf[18] <= perf[18] + 32'd1;
			if (gpu.r_st_clut)                           perf[19] <= perf[19] + 32'd1;
			if (gpu.r_st_dst)                            perf[20] <= perf[20] + 32'd1;
			if (gpu.r_st_full)                           perf[21] <= perf[21] + 32'd1;
			if (gpu.r_start)                             perf[22] <= perf[22] + 32'd1;
			if (gpu.ds == 6'd7)                          perf[23] <= perf[23] + 32'd1;
			// 24..27: why the processor waits. A load that stalls with the data
			// cache missing is ours to fix; one waiting on the drawing engine's
			// read-back is the chip's own behaviour and is not.
			if (gpuread_wait)                            perf[24] <= perf[24] + 32'd1;
			if (gp0_wait)                                perf[25] <= perf[25] + 32'd1;
			if (present && !c_we && !served && !ib_hit)  perf[26] <= perf[26] + 32'd1;
			// 28 loads the data cache could not answer, 54 loads presented:
			// the miss rate itself, which up to now has only been inferred
			if (acc_start && !c_we && !cpu_fetching)     perf[54] <= perf[54] + 32'd1;
			if (acc_start && !c_we && !cpu_fetching && !ib_hit)
				perf[28] <= perf[28] + 32'd1;
			// 55: stores that dropped a line the data cache really held. If this
			// is a large share of the misses above, patching the word in place
			// instead of dropping the line is the next thing worth building.
			if (u_dcache.inv_a_en && u_dcache.a_tag_hit)
				perf[55] <= perf[55] + 32'd1;
			// 56 lines the scanout actually read, 57 trips the video cache made
			// to memory for them. The cache reads around itself in runs of four
			// lines, so these should be four to one; if they are one to one the
			// run is being destroyed by the drawing engine writing into it, and
			// that is what the 168,668 clocks a frame of waiting for VRAM is.
			if (s_req && s_ack)                          perf[56] <= perf[56] + 32'd1;
			if (vc_m_req && vc_m_ready && !vc_m_we)      perf[57] <= perf[57] + 32'd1;
			// 58: runs the video cache started for the scanout. With 56 this is
			// lines per run, which says whether lengthening the run helped or
			// whether the drawing engine is destroying it before it is used.
			if (vcache.pf_busy && !pfb_d)                perf[58] <= perf[58] + 32'd1;
			if (v_req && v_we && !v_ack)                 perf[59] <= perf[59] + 32'd1;   // write held: block queue full
			if (v_req && !v_we && u_vp.r_hold)           perf[60] <= perf[60] + 32'd1;   // read held: its line still on its way
			if (bk_m_req && bk_m_ready)                  perf[61] <= perf[61] + 32'd1;   // lines posted by the block writer
			if (dma_irq && !dma_irq_d)                   perf[62] <= perf[62] + 32'd1;   // DMA interrupts raised
			if (u_dma.st == 4'd12 && u_dma.cur == 3'd4)  perf[63] <= perf[63] + 32'd1;   // channel 4 (SPU) transfers finished
			// a store now stalls only behind the buffer in front of it
			if (cached && c_req && c_we && sb_v)         perf[27] <= perf[27] + 32'd1;

			// --- how long it takes to read the screen, and what paces it ------
			// The picture tears because the machine redraws the screen while the
			// screen is being read. Whether that is fixable depends on two
			// numbers nobody has measured: how long a read takes, and what is
			// holding it up while it happens. 29 is the read running, 30 is it
			// stopped because whoever is taking the pixels is full, 31 is the
			// last complete read end to end.
			if (gpu.sc != 2'd0)                          perf[29] <= perf[29] + 32'd1;
			if (gpu.scan_hold)                           perf[30] <= perf[30] + 32'd1;
			if (gpu.sc == 2'd1)                          perf[50] <= perf[50] + 32'd1;
			if (gpu.sc == 2'd2)                          perf[51] <= perf[51] + 32'd1;
			if (gpu.sc == 2'd3)                          perf[52] <= perf[52] + 32'd1;
			if (gpu.s_req && !gpu.s_ack)                 perf[53] <= perf[53] + 32'd1;

			// --- where in a frame the engine is busy --------------------------
			// Sixteen counters across one frame. Capturing "when the engine is
			// idle" was tried and fails because it is idle between primitives
			// too; what is needed is a stretch of the frame that is quiet every
			// time, and this is the only way to find out whether one exists.
			perf[{2'b10, ph_bin}] <= perf[{2'b10, ph_bin}] + (gpu.busy ? 32'd1 : 32'd0);
			if (cap_done)                                perf[31] <= cap_clk;
			perf[48] <= {12'd0, gpu.frame_len};
			if (gpu.frame_tick)                          perf[49] <= perf[49] + 32'd1;
			// what the drawing engine actually gets through: pixel PAIRS written,
			// and the clocks it was busy. Without these the only way to say where
			// a frame goes is to guess, and guessing is what has cost the time.
			if (gpu.u_raster.w_done)                     perf[32] <= perf[32] + 32'd1;
			if (gpu.u_raster.busy)                       perf[33] <= perf[33] + 32'd1;
			if (gpu.u_raster.st_dst_miss)                perf[34] <= perf[34] + 32'd1;
			if (gpu.u_raster.cl_loading)                 perf[35] <= perf[35] + 32'd1;
		end
	end
	assign dbg_perf = DBG_OLD ? perf[dbg_perf_sel]
	                : (dbg_perf_sel[4:0] == 5'd11) ? {16'd0, cd_edc_bad}
	                : (dbg_perf_sel[4:0] >= 5'd12 && dbg_perf_sel[4:0] <= 5'd17) ? cpu_cost[(5'd17 - dbg_perf_sel[4:0]) * 32 +: 32]
	                : 32'd0;

	// --- introspection capture ---------------------------------------------------
	// The value an I/O read returns is exactly din_r one clock after the address
	// is presented, so latch the address on the read and the data the next clock.
	reg io_rd_d;
	reg [31:0] io_addr_d;
	reg cpu_irq_d;
	always @(posedge clk) cpu_irq_d <= cpu_irq;
	always @(posedge clk) begin
		if (rst) begin
			dbg_io_addr <= 32'd0; dbg_io_data <= 32'd0; dbg_gpu_wr <= 32'd0;
			dbg_mem <= 32'd0; dbg_daddr <= 32'd0; dbg_irq <= 32'd0;
			io_rd_d <= 1'b0; io_addr_d <= 32'd0;
		end else begin
			io_rd_d   <= io_hit && c_req && !c_we && cpu_ce;
			io_addr_d <= c_addr;
			if (io_rd_d) begin dbg_io_addr <= io_addr_d; dbg_io_data <= din_r; end
			if (gpu_hit && c_req && c_we && cpu_ce) dbg_gpu_wr <= dbg_gpu_wr + 32'd1;
			dbg_mem <= {
				d_req, d_we, d_ready, d_valid,                 // 31:28 DDR3 port
				vc_m_req, vc_m_ready, vc_m_valid, 1'b0,        // 27:24 VRAM cache <-> arbiter
				cc_m_req, cc_m_ready, cc_m_valid, 1'b0,        // 23:20 CPU cache <-> arbiter
				v_req, v_ack, s_req, s_ack,                    // 19:16 GPU draw / scanout <-> vcache
				dm_req, dm_ack, gp0_ready, gp0_wr,             // 15:12 DMA <-> ccache / DMA -> GPU
				hf_req_r, served, cpu_ready, d_calibrated,     // 11:8  host-fill, CPU stall
				4'd0, 4'd0
			};
			dbg_daddr <= {8'd0, d_addr};
			if (cpu_run) begin
				if (gpu_vblank_edge)       dbg_irq[15:0]  <= dbg_irq[15:0]  + 16'd1;
				if (cpu_irq && !cpu_irq_d) dbg_irq[31:16] <= dbg_irq[31:16] + 16'd1;
			end
		end
	end

	// (debug) a live look, for sampling: {credit full, waits: DMA owns the bus, DMA RAM, processor
	// not ready, GP0 full, GPUREAD, VRAM flush; cpu_ce; 12'd0; GPU}
	assign dbg_live = {credit == CREDIT_MAX, dma_block, dma_ram_wait, !cpu_ready, gp0_wait, gpuread_wait, vz_active_w, cpu_ce,
	                   cpu_c2w, 11'd0, gpu_live};
	always @(posedge clk)
		if (rst) dbg_cpu_wait <= 32'd0;
		else if (c_req && !cpu_ready && d_calibrated) dbg_cpu_wait <= dbg_cpu_wait + 32'd1;
endmodule

`default_nettype wire
