//////////////////////////////////////////////////////////////////////////////////
// ps1_cache.v - what sits between a 32-bit CPU and a memory that speaks in lines.
//
// The PlayStation's RAM and BIOS live in DDR3, which answers in 128-bit lines
// after a wait the CPU cannot afford on every access. This holds lines, serves
// words out of them, and takes the CPU's stores without touching DDR3 until a
// line has to go: write-back, direct-mapped, one dirty bit per line.
//
// --- why write-back and not write-through -------------------------------------------
//
// The memory behind this has no byte enables. A store that went straight
// through would be a read-modify-write of a whole line, per store, and a
// PlayStation clears its RAM and builds its display lists a word at a time.
// Keeping the line and writing it back once, when it is evicted, turns a
// thousand stores to a stack frame into one line write.
//
// --- two askers, one view ---------------------------------------------------------------
//
// The DMA controller reads RAM too -- ordering tables, display lists, sound
// samples -- and it has to see what the CPU just wrote. So it comes through
// here rather than round it: one cache, two ports, and coherence is not a
// problem because there is nothing to be coherent with. Port B (DMA) is taken
// when the CPU is between accesses.
//
// --- what is cached -----------------------------------------------------------------------
//
// Everything the arbiter serves: RAM at 0, the BIOS at $1FC00000. The caller
// decides which physical addresses come here; I/O never does. The BIOS is read
// only in practice but nothing here knows that, and a store to it will land in
// DDR3 like any other -- which is what the console's would NOT do. If a program
// depends on stores to ROM being ignored, mask them above.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_cache #(
	parameter IDXBITS = 9,          // 512 lines of 16 bytes = 8 kB
	// Port B reads around the cache instead of through it: it is answered
	// from memory and allocates nothing. See the run-ahead block below for
	// why that is both correct and worth doing.
	parameter B_NOALLOC = 0,
	parameter A_AROUND  = 0,   // port A reads marked a_around go round the cache like port B's
	// port B may write a whole line (b_lwe, byte mask b_be16): the DMA clearing an ordering table.
	// A full line that misses is allocated without reading memory first. Off, b_lwe is ignored.
	parameter B_LINE    = 0,

	// --- answering a hit in the cycle it is decided --------------------------
	// S_ANS works entirely out of registers: the line, the tag and the valid bit
	// were all latched on the way in, so `hit` and the word are true the moment
	// the state is entered. Registering the acknowledgement on top of that spends
	// a whole clock restating something already known, and the processor sits
	// through it on every access the small caches could not answer -- measured at
	// 21% of loads, three clocks each.
	//
	// So port A can be told in the same cycle. The word and the line become
	// combinational on that one path; everything else, and port B, keep the
	// registered acknowledgement they had. Off by default: this is the handshake
	// every video bug in this tree has come from, and it is turned on only for
	// the cache the processor talks to, which is the only one that waits.
	parameter FAST_ACK = 0,

	// --- the lines in block RAM ----------------------------------------------
	// The processor's cache is the one that wants to be big: in a level, Crash
	// spends ~86% of each frame running, and giving the processor a third more
	// clocks bought only 5% of that back -- it is waiting on memory, 35,000 DDR3
	// round trips a frame out of 8 kB. The lines and tags then live in block RAM
	// (64 kB is 16 tiles) and are read on the same clock edges the LUT-RAM
	// arrays were read on, so the look-up still takes one clock. The one thing
	// that differs: a fill does not load the line register from the memory
	// reply -- block RAM has only its own output register -- so after a fill the
	// line is read back out of the array in S_LOOK, one more clock per miss.
	// Invalidation (inv_v) is not supported in this mode: its tag read would
	// need a second port.
	parameter BRAM = 0,
	// --- a store that misses does not fetch the line first (BRAM mode only) -----------
	// Each line carries four word-valid bits beside its tag. A whole-word store that misses
	// claims the line with just that word valid -- no DDR3 read: the game is writing it, and
	// what memory held there is about to be overwritten. Measured on Syphon Filter's code
	// (tools/ps1/memtrace.py + cachemodel.py): a store that misses fetched a line it then wrote
	// over, 68,000 times in 20 frames, and dropping those fetches is a fifth of all the time the
	// processor waits on memory. A read wants the whole line (the L1s and the DMA take all of
	// it), so a line that is not wholly valid is fetched on a read and merged under its valid
	// words; a write-back sends only the valid words (the byte mask).
	parameter WVALID = 0,
	// --- a stream buffer beside the cache, for port A's reads (BRAM mode) -------------
	// A read that misses starts a stream: the next lines after it are fetched into four
	// slots beside the cache -- not into it, so nothing is evicted for a line nobody wants --
	// while the processor works on the one it asked for. A later miss that finds its line in a
	// slot takes it from there instead of from DDR3, and the stream runs on ahead of it.
	// Measured on Syphon Filter's code (tools/ps1/cachemodel.py): a quarter of what the
	// processor waits on memory, on top of the WVALID claims. Coherence: a slot holds what
	// memory held when it was read; the only way memory changes under it is this cache writing
	// a line back (nothing else writes RAM: the DMA comes through port B), and a write-back
	// kills any slot holding that line, even one whose read is still out.
	parameter SBUF = 0
)(
	input  wire        flush,        // a pulse: write every dirty line back
	output wire        flush_busy,
	input  wire         clk,
	input  wire         rst,

	// --- port A: the CPU ----------------------------------------------------------
	input  wire [28:0]  a_addr,     // physical, byte
	input  wire         a_req,
	// line mode: a whole 16-byte line with a byte mask, from the write combiner
	input  wire         a_lwe,
	input  wire [15:0]  a_be16,
	input  wire [127:0] a_wdata128,
	input  wire         a_we,
	input  wire         a_around,   // this read: no allocation, fetch a run (A_AROUND only)
	// The SHAPE of that run. A texture wants a tile, because a span walks down
	// the texture as well as across it. A palette is 32 consecutive lines of one
	// VRAM row, so half of a tile is the row below and worth nothing to it --
	// measured, the palette got two useful lines a fetch instead of four.
	input  wire         a_lin,
	input  wire [3:0]   a_be,
	input  wire [31:0]  a_wdata,
	output wire [31:0]  a_rdata,
	output wire         a_ack,
	output wire [127:0] a_line,      // the whole line port A's read came from

	// --- port B: the DMA controller ------------------------------------------------
	input  wire [28:0]  b_addr,
	// While the scanout is reading the screen it is racing the drawing engine,
	// and a capture that loses gets overtaken by the game's next flip -- which
	// is a torn picture. This puts port B first for as long as that lasts; the
	// engine gives up a few microseconds and the frame comes out whole.
	input  wire         b_first,
	input  wire         b_req,
	input  wire         b_we,
	input  wire [3:0]   b_be,
	input  wire [31:0]  b_wdata,
	input  wire         b_lwe,
	input  wire [15:0]  b_be16,
	input  wire [127:0] b_wdata128,
	output reg  [31:0]  b_rdata,
	output reg          b_ack,
	output reg  [127:0] b_line,      // and port B's, for the same reason

	// --- the rest of a run, offered line by line ---------------------------------
	// A port-A read-around fetches PFL lines to answer one. The other PFL-1 are
	// exactly the texel lines the drawing engine is about to want, so once the
	// run is in they are offered here, one a clock, for the texture cache to
	// keep. Measured before this: 500 of 718 textured-run stops in tb_ps1_gpu
	// were "next texel line not in hand", and on the board 16,900 a frame.
	output reg          x_valid,
	output reg  [24:0]  x_addr,      // line address
	output reg  [127:0] x_line,

	// --- a line was written to memory past this cache: drop any copy ------------
	// The drawing engine's block writer (ps1_gpu_blk.v) posts straight to the
	// arbiter, so a line held here, or a run in the read-around buffer, is stale
	// the moment one of its writes is accepted. Tag-checked: another line at the
	// same index is left alone.
	input  wire         inv_v,
	input  wire [24:0]  inv_line,

	// --- the memory behind it, one line per transfer -------------------------------
	output reg  [23:0]  m_addr,     // in LINES: address >> 4
	output reg          m_req,
	output reg          m_we,
	output reg  [127:0] m_wdata,
	output reg  [15:0]  m_wmask,     // which bytes of it land (write-around of a partial line)
	input  wire         m_ready,
	input  wire [127:0] m_rdata,
	input  wire         m_valid,

	output reg  [31:0]  dbg_hits,
	output reg  [31:0]  dbg_misses
);
	localparam LINES = 1 << IDXBITS;
	localparam TAGW  = 25 - IDXBITS;          // 29-bit byte address, 4 bits in the line

	localparam DL    = (BRAM != 0) ? 1 : LINES;  // the LUT-RAM arrays, unused when BRAM is set
	reg [127:0] data  [0:DL-1];
	reg [TAGW-1:0] tag [0:DL-1];
	wire [IDXBITS-1:0] didx;       // their index: 0 when they are one-entry stubs
	// VALID IS TWO BANKS OF LUT-RAM, XORED. A line is valid when va ^ vb is 1.
	// It has two writers that can land on the same clock -- the state machine
	// setting a line it has just filled, and the invalidation port clearing a
	// line the block writer has just overwritten in memory -- and it had to clear
	// all 512 in one clock at reset. That made it flip-flops with two decoders and
	// two 512-to-1 read muxes: with the invalidation logic, about 1,600 LUTs in the
	// VRAM cache alone (netlist, 2026-09-27). Each writer now owns a bank and
	// writes its value XOR the other bank's, so either can land without the other
	// (the "XOR multi-port memory"); a reset starts a sweep that zeroes both banks
	// a line a clock, LINES clocks, while the machine holds the ports off.
	(* ram_style = "distributed" *) reg va [0:LINES-1];   // the state machine's bank
	(* ram_style = "distributed" *) reg vb [0:LINES-1];   // the invalidation's bank
	reg               clr;         // the reset sweep is running: nothing is valid
	reg [IDXBITS-1:0] clr_i;
	reg               va_we, vb_we; // this clock's writes (blocking, decided below)
	integer vi;
	initial for (vi = 0; vi < LINES; vi = vi + 1) begin va[vi] = 1'b0; vb[vi] = 1'b0; end
	`define CV(n) (va[n] ^ vb[n])
`ifndef SYNTHESIS
	// for testbenches that look at `valid[i]`: read out of the two banks
	wire valid [0:LINES-1];
	genvar vg;
	generate for (vg = 0; vg < LINES; vg = vg + 1) begin : g_vview
		assign valid[vg] = !clr && `CV(vg);
	end endgenerate
`endif
	// NOT RESET, so that it is LUT-RAM. Every reader asks `valid_q && dirty_q`,
	// and every write that sets a line valid writes its dirty bit too, so a
	// dirty bit left over from before a reset is never looked at. Clearing all
	// 512 of them in the reset loop made them flip-flops with a decoder and a
	// 512-to-1 read mux each: about 1,100 LUTs per cache instance, measured by
	// name in the synthesised netlist on 2026-09-27.
	(* ram_style = "distributed" *) reg dirty [0:LINES-1];
	integer di;
	initial for (di = 0; di < LINES; di = di + 1) dirty[di] = 1'b0;

	// --- the state machine's states, declared here because the port arbitration
	// below has to know whether a look-up is starting this cycle
	reg  [31:0]  a_rdata_r;
	reg          a_ack_r;
	reg  [127:0] a_line_r;

	localparam S_IDLE = 4'd0, S_LOOK = 4'd1, S_WB = 4'd2, S_WBWAIT = 4'd3,
	           S_FILL = 4'd4, S_FILLWAIT = 4'd5, S_ANS = 4'd6, S_ALLOC = 4'd7,
	           S_FLOOK = 4'd8, S_FANS = 4'd9, S_FWB = 4'd10, S_FNEXT = 4'd11,   // the flush walk
	           S_PF = 4'd12, S_PFWAIT = 4'd13, S_PFANS = 4'd14,
	           S_WA = 4'd15;                 // port B's run-ahead
	localparam S_WALLOC = 5'd16;     // a whole-word store claims a missing line (WVALID)
	localparam S_SBREQ  = 5'd17;     // a stream-buffer slot's read goes out (SBUF)
	localparam S_SBFILL = 5'd18;     // a miss served from a slot (SBUF)
	reg [4:0] st;

	// --- who is being served -------------------------------------------------------------
	reg         serving_b;
	// Which port the next look-up is for, known in the same cycle the request
	// is seen so the array read can start there rather than a cycle later. The
	// processor waits on this path for every instruction it fetches, so a cycle
	// here is a cycle on every instruction.
	wire        a_go   = a_req && !a_ack;
	wire        b_go   = b_req && !b_ack;
	wire        nxt_b  = !a_go ? 1'b1 : !b_go ? 1'b0 : b_first ? 1'b1 : !serving_b;
	wire        look_b = (st == S_IDLE) ? nxt_b : serving_b;
	wire [28:0] addr  = look_b ? b_addr  : a_addr;
	wire        we    = look_b ? b_we    : a_we;
	wire [3:0]  be    = look_b ? b_be    : a_be;
	wire [31:0] wdata = look_b ? b_wdata : a_wdata;

	// a flush writes every dirty line back, so a reader of the memory behind
	// the cache (the host's DDR3 port) sees what the machine sees
	reg flushing, fl_serve;
	// the request, held: a pulse that came while the machine was busy (filling, or sending a
	// stream-buffer slot's read) was lost, and the dirty lines it was for never reached memory
	reg fl_req;
	wire fl_want = flush || fl_req;
	reg [IDXBITS-1:0] fidx;
	assign flush_busy = flushing || fl_req || flush;   // (a flush asked for and not yet started is busy too)
	wire [IDXBITS-1:0] idx = fl_serve ? fidx : addr[IDXBITS+3:4];
	assign didx = (BRAM != 0) ? {IDXBITS{1'b0}} : idx;
	wire [TAGW-1:0]    tg  = addr[28:IDXBITS+4];
	wire [1:0]         wsel = addr[3:2];

	// --- state ---------------------------------------------------------------------------

	// --- port B reads around the cache, a run of lines at a time -----------------
	//
	// Port B of the VRAM cache is the scanout, and it walks the whole displayed
	// buffer once every frame. Letting it allocate meant that every frame it
	// evicted the lines the drawing engine was working in: three streams -- the
	// texture, the frame being drawn, the frame being shown -- through one
	// direct-mapped cache, and the drawing engine is the one that loses. It was
	// missing about as often as it was asking.
	//
	// It does not need to be cached at all. Direct mapped means a line that
	// misses here cannot be sitting dirty under some other index, so for an
	// address port B misses on, memory IS the current value -- reading around
	// the cache is exactly right, and it disturbs nothing.
	//
	// What it does need is to stop paying a full memory round trip for every
	// eight pixels. So a miss asks for the whole aligned run of PFL lines
	// back-to-back -- the queue behind us takes one a cycle, so the run costs
	// one round trip, not four -- and the next few requests, which the scanout
	// is certainly about to make, are answered from here without going out at
	// all.
	// Measured on the board: the scanout waits 16.8 clocks for every line it
	// reads, 214,343 clocks a frame, and that is now the largest single thing
	// standing between the page and a picture that does not tear. Almost all of
	// it is the round trip to memory, so the run is lengthened to amortise it
	// over four times as many lines: sixteen of them, 256 bytes, which is most
	// of a 320-pixel row.
	// Sixteen was tried on the board and hung the machine: sixteen reads
	// outstanding from one port, plus the other ports', overran a return queue
	// that could not tell full from empty, and the replies were dropped. The
	// queue is fixed (see mem_arb.v) but SIMULATION NEVER REPRODUCED THAT HANG --
	// tb_ps1_fb and tb_ps1_c0 both passed with sixteen -- so the depth is not
	// something to trust a passing test about. Eight is under even the old
	// queue's limit with every other port busy, and still halves the round trips.
	// Measured per capture: 2,395 runs of exactly eight lines, 95 clocks each, of
	// which the eight requests account for about sixteen -- the rest is the round
	// trip to memory, and the memory refused a request 19 times in two seconds,
	// so nothing is saturated. It is latency, not bandwidth, which means the run
	// length pays directly: the same 80 clocks of waiting spread over twice as
	// many lines. Sixteen is safe now that the arbiter's return queue can tell
	// full from empty and refuses a read it cannot record (mem_arb.v); it was the
	// queue, not the run, that hung the machine.
	// SIXTEEN DOES NOT WORK ON THE BOARD, twice, in two different ways: once the
	// scanout stopped dead, and once the processor hung at bfc00250 with zero
	// instructions retiring and the clock still running. The second time the
	// arbiter's return queue had already been fixed to tell full from empty, so
	// that was not the cause. Sixteen reads outstanding from one port is simply
	// more than the memory behind it tracks: the replies do not all come back,
	// the queue fills, q_full blocks every further read and the machine starves.
	// Simulation never reproduced either failure -- tb_ps1_fb and tb_ps1_c0 pass
	// with sixteen. Eight is the value this board has actually run.
	localparam PFL  = 4;                    // lines in a run: 8 x 16 B = 128 B
	localparam PFLB = 2;                    // log2(PFL)
	reg [127:0] pf_data [0:PFL-1];
	reg [24:0]  pf_base;                    // the line the run in hand starts at
	reg         pf_valid;
	// which lines of the run are still good. One bit for the whole run threw all four away
	// when any one was written -- and a semi-transparent span writes the line it has just
	// read, so the three after it went back to memory one by one (ps1-tests gpu/bandwidth:
	// semi-transparent drawing at a quarter of the console's speed). And a write landing
	// while the run was still in flight was forgotten when the run completed and set the
	// one bit again: a stale line served. A bit a line, cleared even in flight, is both.
	reg [PFL-1:0] pf_lv;
	// Issued and received are counted separately because they overlap: the
	// arbiter in front of the memory takes a request every few cycles, so the
	// first line of a run comes back while the last is still going out. Counting
	// them with one number threw those early answers away and the run then
	// waited for lines that had already arrived -- a dead machine.
	reg [PFLB:0] pf_i;                      // lines of the run sent
	reg [PFLB:0] xs_i;                      // lines of the run offered to the texture cache
	reg          xs_on;
	reg [PFLB:0] pf_n;                      // lines of the run collected
	reg         pf_busy;                    // a run is in flight: take what comes back
	reg [PFLB-1:0] pf_want;                 // the one the request that started it wanted
	reg          pf_early;                  // the wanted line has been handed over already
	// the lines come back in order, so the wanted one is here once the count passes it
	wire         pf_ans = !pf_early && (pf_n > {1'b0, pf_want});

	// the line and tag being looked at: registers loaded from the LUT-RAM arrays,
	// or the block RAM's own output register (see BRAM above)
	reg [127:0] line_r;
	reg [TAGW-1:0] tag_r;
	wire [127:0] bq_line;
	wire [TAGW-1:0] bq_tag;
	wire [127:0] line_q = (BRAM != 0) ? bq_line : line_r;
	wire [TAGW-1:0] tag_q = (BRAM != 0) ? bq_tag : tag_r;
	reg valid_q, dirty_q;
	reg refilled;                   // this S_ANS follows a fill: not a hit

	// the line's word-valid bits (WVALID): what of it the cache really holds
	wire [3:0]  bq_wv;
	wire [3:0]  wvq      = (WVALID != 0) ? bq_wv : 4'hF;
	wire        tmatch   = valid_q && (tag_q == tg);
	wire        line_w_m, line_w_full;                // (line_mode, and a whole-line write: below)
	// A hit: the line is here, and so is what this access needs of it -- all of it for a read,
	// the word for a partial store; a whole-word or whole-line store needs nothing.
	// (The access's kind -- write, byte enables, line write -- as latched when its look-up began:
	// port A's are the processor's live outputs, which wait on this cache's own fast answer, and
	// reading them here closed a combinational loop through a_ack: the build's DRC LUTLP-1.)
	reg         we_l, lm_l, lfull_l;
	reg  [3:0]  be_l;
	wire hit = tmatch && ((WVALID == 0) || (wvq == 4'hF) || (we_l && !lm_l && (be_l == 4'hF || wvq[wsel])) || (we_l && lm_l && lfull_l));
	wire part = tmatch && !hit;                       // here, but not enough of it: fetch and merge
	reg         fm;                                   // this fill merges under the line's valid words
	reg  [3:0]  fm_wv;
	function [15:0] wvmask; input [3:0] v; wvmask = {{4{v[3]}}, {4{v[2]}}, {4{v[1]}}, {4{v[0]}}}; endfunction
	function [127:0] wvmerge; input [127:0] have; input [3:0] v; input [127:0] mem;
		wvmerge = {v[3] ? have[127:96] : mem[127:96], v[2] ? have[95:64] : mem[95:64],
		           v[1] ? have[63:32]  : mem[63:32],  v[0] ? have[31:0]  : mem[31:0]};
	endfunction
	wire        walloc   = (WVALID != 0) && we_l && !lm_l && (be_l == 4'hF);   // a miss claims the line
	wire [127:0] fill_line = fm ? wvmerge(line_q, fm_wv, m_rdata) : m_rdata;

	// --- the stream buffer (SBUF) ----------------------------------------------------------
	localparam SBN = 4;
	reg  [24:0]  sb_line [0:SBN-1];
	reg  [127:0] sb_d    [0:SBN-1];
	reg  [SBN-1:0] sb_vld, sb_pend, sb_kill;         // holds its line / its read is out / a write-back hit it
	reg  [1:0]   sb_fifo [0:SBN-1];                   // the slots of the reads out, in the order sent
	reg  [1:0]   sb_wp, sb_rp;
	reg  [2:0]   sb_out;                              // reads out (their answers come before any later one's)
	reg          sb_act;                              // a stream is running
	reg  [24:0]  sb_next, sb_head;                    // the next line to ask for; the one after the last taken
	reg          sbh;                                 // this miss is served from a slot
	reg  [1:0]   sbs;                                 // ...that one
	wire [24:0]  rq_ln   = addr[28:4];
	wire [SBN-1:0] sb_m;                              // the slots holding the line asked for
	wire [SBN-1:0] sb_free;                           // slots neither holding nor waiting
	genvar sbg;
	generate for (sbg = 0; sbg < SBN; sbg = sbg + 1) begin : g_sbm
		assign sb_m[sbg]    = sb_vld[sbg] && (sb_line[sbg] == rq_ln);
		assign sb_free[sbg] = !sb_vld[sbg] && !sb_pend[sbg];
	end endgenerate
	wire         sb_hit  = (SBUF != 0) && (|sb_m);
	wire [1:0]   sb_hs   = sb_m[0] ? 2'd0 : sb_m[1] ? 2'd1 : sb_m[2] ? 2'd2 : 2'd3;
	wire [1:0]   sb_fs   = sb_free[0] ? 2'd0 : sb_free[1] ? 2'd1 : sb_free[2] ? 2'd2 : 2'd3;
	wire         sb_go   = (SBUF != 0) && sb_act && (|sb_free) && (sb_out != SBN) && ((sb_next - sb_head) < 25'd4);
	wire [127:0] sb_line_q = sb_d[sbs];

	// port A's answer, this cycle, when it is already known
	wire fast_a = (FAST_ACK != 0) && (st == S_ANS) && hit && !serving_b;
	assign a_ack   = a_ack_r | fast_a;
	assign a_rdata = fast_a ? pick(line_q, wsel) : a_rdata_r;
	assign a_line  = fast_a ? line_q             : a_line_r;

	// port B is read-only where this is switched on, so a write is always port A
	// which reads go round the cache: port B always (when built so), and a port
	// A read that asked to -- latched with the request, as serving_b is
	reg         ar_q;
	wire        around   = ar_q && !we;
	wire        b_around = around;   // the name the run logic was written against
	// The run used to be the ALIGNED block the wanted line falls in, so the line
	// asked for sat four deep in it on average and the answer waited for the
	// lines in front of it. It starts at the wanted line instead: the answer
	// comes back on the first beat, and the seven that follow are the ones the
	// span is about to walk into anyway.
	wire [24:0] rq_line  = addr[28:4];
	wire [24:0] pf_off   = rq_line - pf_base;      // how far into the run in hand
	// A run used to be eight lines along ONE texture row. A game draws its
	// textures at about one texel to the pixel, so the next screen row wants the
	// next texture ROW, which the run never brought: measured on a game-shaped
	// scene, one fetch every five pixel pairs and 57% of the drawing time spent
	// waiting. Both fast open-source PS1 GPUs cache a tile for exactly this. So
	// a run is four lines of one row and four of the row below (a VRAM row is
	// 2048 bytes = 128 lines): the same eight reads, twice the rows.
	localparam [24:0] ROWL = 25'd128;
	localparam [24:0] PFLW = PFL;      // the run length, wide enough to compare with
	reg         pf_lin;                            // the run in hand is along one row
	wire        pf_lo  = pf_lin ? (pf_off < PFLW) : (pf_off < 25'd2);
	wire        pf_hi  = !pf_lin && (pf_off >= ROWL) && (pf_off < ROWL + 25'd2);
	wire        pf_hit0 = pf_valid && (pf_lo || pf_hi);
	wire [24:0] pf_first = rq_line;                // the run starts where it was asked
	wire [PFLB-1:0] pf_sel = pf_lin ? pf_off[PFLB-1:0]
	                               : (pf_lo ? {1'b0, pf_off[0]} : {1'b1, pf_off[0]});
	function [24:0] runaddr; input [PFLB:0] k;     // line k of the run
		runaddr = pf_lin ? (pf_base + {22'd0, k})
		                 : (pf_base + {24'd0, k[0]} + (k[1] ? ROWL : 25'd0));
	endfunction
	// is this line inside the run in hand?
	function in_run; input [24:0] d;
		in_run = pf_lin ? (d < PFLW)
		                : ((d < 25'd2) || ((d >= ROWL) && (d < ROWL + 25'd2)));
	endfunction
	function [PFLB-1:0] run_ix; input [24:0] d;     // which of the run's lines (when in_run)
		run_ix = pf_lin ? d[PFLB-1:0] : ((d < 25'd2) ? {1'b0, d[0]} : {1'b1, d[0]});
	endfunction
	wire        pf_hit = pf_hit0 && pf_lv[pf_sel];
	wire [24:0] inv_d  = inv_line - pf_base;
	// The walk steps from the address just issued, NOT from pf_base: pf_base is
	// written in the same clock the first request goes out, so a walk computed
	// from it got the SECOND line of every tile wrong (line 1 of VRAM instead of
	// base+1), and the texture cache filled that line with whatever sat there.
	wire [23:0] next_run = (!pf_lin && (pf_i == {1'b0, 2'd1})) ? (m_addr - 24'd1 + ROWL[23:0])
	                                                          : (m_addr + 24'd1);
	wire [24:0] evicted  = {tag_q, idx};    // the line a miss is about to throw out

	function [31:0] pick;
		input [127:0] l;
		input [1:0]   w;
		pick = l[w*32 +: 32];
	endfunction

	// a line write: every byte the mask enables
	function [127:0] merge16;
		input [127:0] l;
		input [15:0]  b;
		input [127:0] v;
		integer k;
		begin
			merge16 = l;
			for (k = 0; k < 16; k = k + 1)
				if (b[k]) merge16[k*8 +: 8] = v[k*8 +: 8];
		end
	endfunction
	wire line_mode = serving_b ? ((B_LINE != 0) && b_lwe) : a_lwe;
	wire [15:0]  l_be16 = serving_b ? b_be16 : a_be16;           // the line write's mask and data
	wire [127:0] l_wd   = serving_b ? b_wdata128 : a_wdata128;
	assign line_w_m    = line_mode;
	assign line_w_full = line_mode && (&l_be16);

	function [127:0] merge;
		input [127:0] l;
		input [1:0]   w;
		input [3:0]   b;
		input [31:0]  v;
		integer k;
		begin
			merge = l;
			for (k = 0; k < 4; k = k + 1)
				if (b[k]) merge[w*32 + k*8 +: 8] = v[k*8 +: 8];
		end
	endfunction

	wire [IDXBITS-1:0] inv_idx = inv_line[IDXBITS-1:0];
	wire [TAGW-1:0]    inv_tg  = inv_line[24:IDXBITS];
	integer i;
	reg         sb_out_inc, sb_take, sb_kill_go;          // (blocking: this clock's slot events)
	reg  [24:0] sb_kill_line;
	wire        sb_rd = (SBUF != 0) && !serving_b && !we_l && !lm_l && !part;   // a read port A misses on
	integer     sbi;
	always @(posedge clk) begin
		va_we = 1'b0; vb_we = 1'b0;
		sb_out_inc = 1'b0; sb_take = 1'b0; sb_kill_go = 1'b0; sb_kill_line = 25'd0;
		if (!rst && inv_v) begin
			if (BRAM == 0 && !clr && `CV(inv_idx) && tag[(BRAM != 0) ? {IDXBITS{1'b0}} : inv_idx] == inv_tg) vb_we = 1'b1;
			if (in_run(inv_d)) pf_lv[run_ix(inv_d)] <= 1'b0;
		end
		if (rst) begin
			st <= S_IDLE; flushing <= 1'b0; fl_serve <= 1'b0; fl_req <= 1'b0; we_l <= 1'b0; be_l <= 4'h0; lm_l <= 1'b0; lfull_l <= 1'b0; fidx <= {IDXBITS{1'b0}}; ar_q <= 1'b0;
			a_ack_r <= 1'b0; b_ack <= 1'b0; a_line_r <= 128'd0; b_line <= 128'd0;
			m_req <= 1'b0; m_we <= 1'b0; m_wmask <= 16'hFFFF;
			serving_b <= 1'b0; refilled <= 1'b0;
			pf_valid <= 1'b0; pf_lv <= {PFL{1'b0}}; pf_i <= 0; pf_n <= 0; pf_busy <= 1'b0;
			xs_on <= 1'b0; xs_i <= 0; x_valid <= 1'b0; x_addr <= 25'd0; x_line <= 128'd0; pf_lin <= 1'b0;
			pf_want <= 0; pf_base <= 25'd0; pf_early <= 1'b0; fm <= 1'b0; fm_wv <= 4'hF;
			sb_vld <= {SBN{1'b0}}; sb_pend <= {SBN{1'b0}}; sb_kill <= {SBN{1'b0}}; sb_wp <= 2'd0; sb_rp <= 2'd0; sb_out <= 3'd0;
			sb_act <= 1'b0; sb_next <= 25'd0; sb_head <= 25'd0; sbh <= 1'b0; sbs <= 2'd0;
			dbg_hits <= 32'd0; dbg_misses <= 32'd0;
			clr <= 1'b1; clr_i <= {IDXBITS{1'b0}};   // every line invalid (dirty: see its declaration)
		end else begin
			a_ack_r <= 1'b0;
			b_ack <= 1'b0;
			if (flush) fl_req <= 1'b1;

			// Lines of a run are taken wherever the machine happens to be, not
			// only in the state that waits for them, because the first of them
			// can arrive before the last has been asked for. They come back in
			// the order they went out.
			if (pf_busy && m_valid && (pf_n != PFL) && (sb_out == 0)) begin
				pf_data[pf_n[PFLB-1:0]] <= m_rdata;
				pf_n <= pf_n + 1'b1;
			end

			// offer the rest of a finished run, one line a clock, skipping the one
			// that was answered; a new run starting takes the buffer back
			x_valid <= 1'b0;
			if (xs_on) begin
				if (pf_busy || !pf_valid) xs_on <= 1'b0;
				else if (xs_i == PFL) xs_on <= 1'b0;
				else begin
					if (xs_i[PFLB-1:0] != pf_want && pf_lv[xs_i[PFLB-1:0]]) begin
						x_valid <= 1'b1;
						x_addr  <= runaddr(xs_i);
						x_line  <= pf_data[xs_i[PFLB-1:0]];
					end
					xs_i <= xs_i + 1'b1;
				end
			end

			case (st)
			// A request that is held until its ack is still high in the cycle
			// the ack comes out, because the ack is registered: taking it again
			// here served every held access twice, and the second, stale ack
			// landed on whatever the port asked for next. A port being acked
			// this cycle has nothing new to say.
			S_IDLE: if (clr) ;   // the reset sweep: hold every port off until it is done
				else if (fl_want) begin flushing <= 1'b1; fidx <= {IDXBITS{1'b0}}; fl_req <= 1'b0; end
				else if (flushing) begin fl_serve <= 1'b1; st <= S_FLOOK; end
				else if (!(a_go || b_go) && sb_go) begin
					m_addr <= sb_next[23:0]; m_we <= 1'b0; m_req <= 1'b1;
					st <= S_SBREQ;
				end
				else if (a_go || b_go) begin
					// Take turns. Port B of the VRAM cache is the frame capture's
					// scanout; giving it the cache whenever it asked starved the
					// drawing engine, because the scanout asks again the cycle
					// after it is served and never stops until the frame is in.
					// The machine then ran at a fraction of its speed for as long
					// as anybody was watching the video, and the BIOS's VRAM
					// read-back could sit behind a whole frame of scanout.
					// Alternating costs the scanout nothing it cannot wait for:
					// the frame writer holds it back anyway.
					serving_b <= nxt_b;
					ar_q      <= nxt_b ? (B_NOALLOC != 0) : ((A_AROUND != 0) && a_around);
					we_l      <= nxt_b ? b_we : a_we;
					be_l      <= nxt_b ? b_be : a_be;
					lm_l      <= nxt_b ? ((B_LINE != 0) && b_lwe) : a_lwe;
					lfull_l   <= nxt_b ? ((B_LINE != 0) && b_lwe && (&b_be16)) : (a_lwe && (&a_be16));
					line_r  <= data[didx];
					tag_r   <= tag[didx];
					valid_q <= `CV(idx);
					dirty_q <= dirty[idx];
					st <= S_ANS;
				end

			// Kept for the flush walk's sake and as a safe landing state; the
			// ordinary path looks up in S_IDLE now.
			S_LOOK: begin
					line_r  <= data[didx];
					tag_r   <= tag[didx];
					valid_q <= `CV(idx);
					dirty_q <= dirty[idx];
					st <= S_ANS;
				end

			S_ANS: if (hit) begin
					if (!refilled) dbg_hits <= dbg_hits + 32'd1;
					refilled <= 1'b0;
					if (we) begin
						if (BRAM == 0) data[didx] <= line_mode ? merge16(line_q, l_be16, l_wd) : merge(line_q, wsel, be, wdata);
						dirty[idx] <= 1'b1;
						// this write makes any copy of the same line stale
						if (pf_hit) pf_lv[pf_sel] <= 1'b0;
					end
					if (serving_b) begin b_rdata <= pick(line_q, wsel); b_line <= line_q; b_ack <= 1'b1; end
					else           begin a_rdata_r <= pick(line_q, wsel); a_line_r <= line_q; a_ack_r <= !fast_a; end
					st <= S_IDLE;
				end else if (b_around && !part) begin
					dbg_misses <= dbg_misses + 32'd1;
					if (pf_hit) begin
						// the run this walked into is already here
						if (serving_b) begin
							b_rdata <= pick(pf_data[pf_sel], wsel);
							b_line  <= pf_data[pf_sel];
							b_ack   <= 1'b1;
						end else begin
							a_rdata_r <= pick(pf_data[pf_sel], wsel);
							a_line_r  <= pf_data[pf_sel];
							a_ack_r   <= 1'b1;
						end
						st <= S_IDLE;
					end else begin
						pf_valid <= 1'b0;
						pf_lv    <= {PFL{1'b1}};      // (a write from here on clears its line)
						// Port B is the scanout, and the scanout is the most
						// perfectly sequential reader in the machine: it walks
						// straight along a row, eight pixels at a time. Its run
						// has to be the LINEAR one. It was taking the 2D tile
						// layout the drawing engine wants for textures -- two
						// lines along the row and two on the row below -- so half
						// of every run it paid for was thrown away and it went
						// back to memory twice as often as it needed to. Measured
						// on the board 2026-09-26: 76% of the capture was spent
						// waiting for video memory, 54 clocks for every line, and
						// a capture outlasting one of the machine's frames is why
						// the bottom of the picture comes back as whatever the
						// game cleared the buffer to.
						pf_lin   <= serving_b ? 1'b1 : a_lin;
						pf_base  <= rq_line;
						pf_want  <= {PFLB{1'b0}};   // the run starts at the wanted line
						pf_i     <= 0;
						pf_n     <= 0;
						pf_busy  <= 1'b1;
						m_addr   <= pf_first[23:0];
						m_we     <= 1'b0;
						m_req    <= 1'b1;
						st <= S_PF;
					end
				end else if (!serving_b && line_mode && we && !part) begin
					// --- a whole line that misses goes round the cache -------------
					// Measured on the board: the drawing engine's framebuffer writes
					// missed this 8 KB cache on nearly every line (a frame's working
					// set is 300 KB), and each miss evicted a dirty line and
					// allocated -- 0.31 DDR3 transactions per pixel against 0.125
					// for one per line, and 1.26 clocks per pixel spent waiting for
					// lines to arrive that were about to be overwritten. Worse, every
					// one threw out a texel line the engine was still using.
					//
					// The real machine does not cache its framebuffer at all. A line is
					// posted straight to memory with a byte mask, so a partial one -- a
					// span's first or last sixteen bytes -- needs no read either: no
					// eviction, no allocation, the cache untouched and still holding its
					// texels. Measured before the mask: 22,000 such reads a frame, 14
					// clocks each, 37% of the frame. Order is kept by the arbiter and the
					// memory, so a later read of this line from any port sees it.
					dbg_misses <= dbg_misses + 32'd1;
					if (pf_hit) pf_lv[pf_sel] <= 1'b0;   // the read-around copy is stale now
					m_addr  <= {tg, idx};
					m_wdata <= a_wdata128;
					m_we    <= 1'b1;
					m_wmask <= a_be16;
					m_req   <= 1'b1;
					st <= S_WA;
				end else begin
					dbg_misses <= dbg_misses + 32'd1;
					// The line is here but not all of what is wanted (WVALID): fetch it and
					// merge it under the words the cache holds -- no write-back, it is this line.
					sbh <= sb_rd && sb_hit; sbs <= sb_hs;
					if (sb_rd) begin
						if (sb_hit) begin
							// taken from the slot: the stream runs on from here, and slots
							// behind the line taken are of no more use
							sb_head <= rq_ln + 25'd1;
							if (sb_next < rq_ln + 25'd1) sb_next <= rq_ln + 25'd1;
						end else begin
							// a new stream from this line
							sb_act  <= 1'b1;
							sb_head <= rq_ln + 25'd1;
							sb_next <= rq_ln + 25'd1;
						end
					end
					if (part) begin
						fm <= 1'b1; fm_wv <= wvq;
						st <= S_FILL;
					// The line here is somebody else's. Write it back if it is
					// dirty, then fetch the one wanted.
					end else if (valid_q && dirty_q) begin
						if (in_run(evicted - pf_base)) pf_lv[run_ix(evicted - pf_base)] <= 1'b0;
						sb_kill_line = evicted; sb_kill_go = 1'b1;
						m_addr  <= {tag_q, idx};
						m_wdata <= line_q;
						m_we    <= 1'b1;
						m_wmask <= wvmask(wvq);           // (only the words it holds: WVALID)
						m_req   <= 1'b1;
						st <= S_WB;
					end else
						// a whole line arriving needs nothing from memory: allocate it
						st <= (line_mode && we && (&l_be16)) ? S_ALLOC : walloc ? S_WALLOC : (sb_rd && sb_hit) ? S_SBFILL : S_FILL;
				end

			S_WB: if (m_ready) begin
					m_req <= 1'b0;
					m_we  <= 1'b0;
					st <= (line_mode && we && (&l_be16)) ? S_ALLOC : walloc ? S_WALLOC : sbh ? S_SBFILL : S_FILL;
				end

			// a slot's read goes out
			S_SBREQ: if (m_ready) begin
					m_req <= 1'b0;
					sb_line[sb_fs] <= sb_next; sb_pend[sb_fs] <= 1'b1; sb_kill[sb_fs] <= 1'b0;
					sb_fifo[sb_wp] <= sb_fs; sb_wp <= sb_wp + 2'd1;
					sb_out_inc = 1'b1;
					sb_next <= sb_next + 25'd1;
					st <= S_IDLE;
				end

			// the line is in a slot: into the cache from there, and answered
			S_SBFILL: begin
					if (BRAM == 0) begin data[didx] <= sb_line_q; tag[didx] <= tg; end
					va_we = 1'b1;
					dirty[idx] <= 1'b0;
					a_rdata_r <= pick(sb_line_q, wsel); a_line_r <= sb_line_q; a_ack_r <= 1'b1;
					sb_take = 1'b1;
					sbh <= 1'b0;
					st <= S_IDLE;
				end

			// a whole-word store claims the line with only that word valid (WVALID)
			S_WALLOC: begin
					if (pf_hit) pf_lv[pf_sel] <= 1'b0;
					va_we = 1'b1;
					dirty[idx] <= 1'b1;
					if (serving_b) b_ack <= 1'b1; else a_ack_r <= 1'b1;
					st <= S_IDLE;
				end

			// the write-around is taken by memory: that is the whole of it
			S_WA: if (m_ready) begin
					m_req <= 1'b0;
					m_we  <= 1'b0;
					a_ack_r <= 1'b1;
					st <= S_IDLE;
				end

			S_ALLOC: begin
					if (pf_hit) pf_lv[pf_sel] <= 1'b0;
					if (BRAM == 0) begin data[didx] <= l_wd; tag[didx] <= tg; end
					va_we = 1'b1;
					dirty[idx] <= 1'b1;
					if (serving_b) b_ack <= 1'b1; else a_ack_r <= 1'b1;
					st <= S_IDLE;
				end

			S_FILL: begin
					m_addr <= {tg, idx};
					m_we   <= 1'b0;
					m_req  <= 1'b1;
					st <= S_FILLWAIT;
				end

			S_FILLWAIT: begin
					if (m_req && m_ready) m_req <= 1'b0;
					if (m_valid && (sb_out == 0)) begin
						if (BRAM == 0) begin data[didx] <= m_rdata; tag[didx] <= tg; end
						va_we = 1'b1;
						dirty[idx] <= fm && dirty_q;      // (a merge keeps the words it held, and their dirt)
						line_r  <= fill_line;
						tag_r   <= tg;
						valid_q <= 1'b1;
						dirty_q <= fm && dirty_q;
						fm      <= 1'b0;
						refilled <= 1'b1;
						// A read is answered from the line as it arrives: going back through the
						// block RAM (S_LOOK, S_ANS) cost two clocks a miss, and the processor waits
						// on every one (GT2: half a million misses a second). A store goes round to
						// be merged in. (The line is written into the RAM this same clock.)
						if (!we && !line_mode) begin
							if (serving_b) begin b_rdata <= pick(fill_line, wsel); b_line <= fill_line; b_ack <= 1'b1; end
							else           begin a_rdata_r <= pick(fill_line, wsel); a_line_r <= fill_line; a_ack_r <= 1'b1; end
							refilled <= 1'b0;
							st <= S_IDLE;
						end else
							// now it hits; out of block RAM, once it has been read back
							st <= (BRAM != 0) ? S_LOOK : S_ANS;
					end
				end

			// Ask for the run. m_req stays up and the address walks: the queue
			// takes one every cycle it is not full, so all four are in flight
			// together and we wait out one round trip rather than four.
			S_PF: if (m_ready) begin
					pf_i <= pf_i + 1'b1;
					if (pf_i == PFL - 1) begin
						m_req <= 1'b0;
						st <= S_PFWAIT;
					end else
						m_addr <= next_run;   // three along this row, then the row below
				end

			// The collector above is doing the taking; this just waits for the
			// count to come up, which it may already have done.
			// A run is eight lines and they come back in order, but this used to
			// wait for ALL of them before answering the one that was asked for.
			// The rasteriser stalls for the whole of that: measured at 32 clocks
			// a texture miss, and 30,000 of 80,000 drawing clocks in a textured
			// scene. Answer the moment the wanted line lands and go on collecting
			// the rest behind it -- the engine is drawing again while they arrive.
			S_PFWAIT: begin
					if (pf_ans) begin
						pf_early <= 1'b1;
						if (serving_b) begin
							b_rdata <= pick(pf_data[pf_want], wsel);
							b_line  <= pf_data[pf_want];
							b_ack   <= 1'b1;
						end else begin
							a_rdata_r <= pick(pf_data[pf_want], wsel);
							a_line_r  <= pf_data[pf_want];
							a_ack_r   <= 1'b1;
						end
					end
					if (pf_n == PFL) begin
						pf_valid <= 1'b1;
						pf_busy  <= 1'b0;
						pf_early <= 1'b0;
						// the rest of the run goes up to the texture cache
						if (!serving_b) begin xs_on <= 1'b1; xs_i <= 0; end
						st <= S_IDLE;
					end
				end

			S_PFANS: begin
					if (serving_b) begin
						b_rdata <= pick(pf_data[pf_want], wsel);
						b_line  <= pf_data[pf_want];
						b_ack   <= 1'b1;
					end else begin
						a_rdata_r <= pick(pf_data[pf_want], wsel);
						a_line_r  <= pf_data[pf_want];
						a_ack_r   <= 1'b1;
						xs_on <= 1'b1; xs_i <= 0;      // and the rest of the run goes up
					end
					st <= S_IDLE;
				end

			S_FLOOK: begin
					line_r <= data[didx]; tag_r <= tag[didx]; valid_q <= `CV(idx); dirty_q <= dirty[idx];
					st <= S_FANS;
				end
			S_FANS: if (valid_q && dirty_q) begin
					if (in_run(evicted - pf_base)) pf_lv[run_ix(evicted - pf_base)] <= 1'b0;
					sb_kill_line = evicted; sb_kill_go = 1'b1;
					m_addr <= {tag_q, idx}; m_wdata <= line_q; m_we <= 1'b1; m_req <= 1'b1; m_wmask <= wvmask(wvq);
					dirty[idx] <= 1'b0;
					st <= S_FWB;
				end else st <= S_FNEXT;
			S_FWB: if (m_ready) begin m_req <= 1'b0; m_we <= 1'b0; st <= S_FNEXT; end
			S_FNEXT: begin
					fl_serve <= 1'b0;
					if (fidx == {IDXBITS{1'b1}}) flushing <= 1'b0;
					fidx <= fidx + 1'b1;
					st <= S_IDLE;
				end
			default: st <= S_IDLE;
			endcase

			if (clr) begin
				clr_i <= clr_i + 1'b1;
				if (&clr_i) clr <= 1'b0;
			end

			// --- the stream buffer's slots ----------------------------------------------
			if (SBUF != 0) begin
				// an answer for a slot (they come in the order the reads went out, before any
				// read sent after them)
				if (m_valid && (sb_out != 0)) begin
					sb_d[sb_fifo[sb_rp]]    <= m_rdata;
					sb_pend[sb_fifo[sb_rp]] <= 1'b0;
					sb_vld[sb_fifo[sb_rp]]  <= !sb_kill[sb_fifo[sb_rp]] && !(sb_kill_go && sb_line[sb_fifo[sb_rp]] == sb_kill_line);
					sb_rp <= sb_rp + 2'd1;
				end
				sb_out <= sb_out + (sb_out_inc ? 3'd1 : 3'd0) - ((m_valid && (sb_out != 0)) ? 3'd1 : 3'd0);
				if (sb_out_inc) sb_vld[sb_fs] <= 1'b0;
				// taken: the slot is free, and so is any holding a line behind it
				if (sb_take)
					for (sbi = 0; sbi < SBN; sbi = sbi + 1)
						if (sbi == sbs || (sb_vld[sbi] && sb_line[sbi] < rq_ln)) sb_vld[sbi] <= 1'b0;
				// a new stream: what the slots hold is the old one's (their reads out finish)
				if (st == S_ANS && !hit && sb_rd && !sb_hit) sb_vld <= {SBN{1'b0}};
				// a line written back to memory: no slot may keep, or receive, the old copy
				if (sb_kill_go)
					for (sbi = 0; sbi < SBN; sbi = sbi + 1)
						if (sb_line[sbi] == sb_kill_line && (sb_vld[sbi] || sb_pend[sbi])) begin
							sb_vld[sbi] <= 1'b0; sb_kill[sbi] <= 1'b1;
						end
			end
		end

		// The valid banks, written in one place each. The sweep zeroes both. A
		// fill and an invalidation of the SAME line on the same clock: the fill
		// won in the old code (it was the later statement), so the invalidation
		// is dropped then -- with both, the XOR would flip the line instead.
		if (!rst && clr) begin
			va[clr_i] <= 1'b0;
			vb[clr_i] <= 1'b0;
		end else if (!rst) begin
			if (vb_we && !(va_we && inv_idx == idx)) vb[inv_idx] <= va[inv_idx];
			if (va_we) va[idx] <= !vb[idx];
		end
	end

	// --- the block RAM (BRAM mode) --------------------------------------------------
	// One port. Written where the LUT-RAM arrays are written above, read where
	// they are read; the two never fall on the same clock.
	generate if (BRAM != 0) begin : g_bram
		(* ram_style = "block" *) reg [127:0]    bdata [0:LINES-1];
		(* ram_style = "block" *) reg [TAGW+3:0] btag  [0:LINES-1];   // {word-valid, tag}
		reg [127:0]    q_line;
		reg [TAGW+3:0] q_tag;
		wire br  = !rst && (((st == S_IDLE) && !clr && !fl_want && !flushing && (a_go || b_go))
		                    || (st == S_LOOK) || (st == S_FLOOK));
		wire bwn = !rst && ((st == S_ALLOC) || ((st == S_FILLWAIT) && m_valid && (sb_out == 0)) || (st == S_WALLOC) || (st == S_SBFILL));  // a new line: data and tag
		wire bw  = bwn || (!rst && (st == S_ANS) && hit && we);                  // or a store into one
		wire [127:0] bwd = (st == S_ALLOC)    ? l_wd
		                 : (st == S_FILLWAIT) ? fill_line
		                 : (st == S_WALLOC)   ? merge(128'd0, wsel, be, wdata)
		                 : (st == S_SBFILL)   ? sb_line_q
		                 : line_mode ? merge16(line_q, l_be16, l_wd) : merge(line_q, wsel, be, wdata);
		// the word-valid bits: all four for a fetched or whole line, the one word for a claim, and
		// a store into a line adds the word it wrote whole (WVALID; otherwise always all four)
		wire [3:0] wv_new = ((WVALID == 0) || (st == S_ALLOC) || (st == S_FILLWAIT) || (st == S_SBFILL) || line_w_full) ? 4'hF
		                  : (st == S_WALLOC) ? (4'b0001 << wsel)
		                  : (wvq | ((be == 4'hF) ? (4'b0001 << wsel) : 4'b0000));
		wire bwt = bwn || ((WVALID != 0) && !rst && (st == S_ANS) && hit && we);
		integer bi;
		initial for (bi = 0; bi < LINES; bi = bi + 1) begin bdata[bi] = 128'd0; btag[bi] = {(TAGW+4){1'b0}}; end
		always @(posedge clk) begin
			if (bw)  bdata[idx] <= bwd;
			if (br)  q_line <= bdata[idx];
		end
		always @(posedge clk) begin
			if (bwt) btag[idx] <= {wv_new, tg};
			if (br)  q_tag <= btag[idx];
		end
		assign bq_line = q_line;
		assign bq_tag  = q_tag[TAGW-1:0];
		assign bq_wv   = q_tag[TAGW+3:TAGW];
	end else begin : g_nobram
		assign bq_line = 128'd0;
		assign bq_tag  = {TAGW{1'b0}};
		assign bq_wv   = 4'hF;
	end endgenerate
`undef CV
endmodule

`default_nettype wire
