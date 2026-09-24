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
	parameter FAST_ACK = 0
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

	reg [127:0] data  [0:LINES-1];
	reg [TAGW-1:0] tag [0:LINES-1];
	reg         valid [0:LINES-1];
	reg         dirty [0:LINES-1];

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
	reg [3:0] st;

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
	reg [IDXBITS-1:0] fidx;
	assign flush_busy = flushing;
	wire [IDXBITS-1:0] idx = fl_serve ? fidx : addr[IDXBITS+3:4];
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

	reg [127:0] line_q;
	reg [TAGW-1:0] tag_q;
	reg valid_q, dirty_q;
	reg refilled;                   // this S_ANS follows a fill: not a hit

	wire hit = valid_q && (tag_q == tg);

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
	wire        pf_hit = pf_valid && (pf_lo || pf_hi);
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
	wire line_mode = !serving_b && a_lwe;

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
	always @(posedge clk) begin
		if (!rst && inv_v) begin
			if (valid[inv_idx] && tag[inv_idx] == inv_tg) valid[inv_idx] <= 1'b0;
			if (pf_valid && (((inv_line - pf_base) < 25'd2)
			    || in_run(inv_line - pf_base))) pf_valid <= 1'b0;
		end
		if (rst) begin
			st <= S_IDLE; flushing <= 1'b0; fl_serve <= 1'b0; fidx <= {IDXBITS{1'b0}}; ar_q <= 1'b0;
			a_ack_r <= 1'b0; b_ack <= 1'b0; a_line_r <= 128'd0; b_line <= 128'd0;
			m_req <= 1'b0; m_we <= 1'b0; m_wmask <= 16'hFFFF;
			serving_b <= 1'b0; refilled <= 1'b0;
			pf_valid <= 1'b0; pf_i <= 0; pf_n <= 0; pf_busy <= 1'b0;
			xs_on <= 1'b0; xs_i <= 0; x_valid <= 1'b0; x_addr <= 25'd0; x_line <= 128'd0; pf_lin <= 1'b0;
			pf_want <= 0; pf_base <= 25'd0; pf_early <= 1'b0;
			dbg_hits <= 32'd0; dbg_misses <= 32'd0;
			for (i = 0; i < LINES; i = i + 1) begin valid[i] <= 1'b0; dirty[i] <= 1'b0; end
		end else begin
			a_ack_r <= 1'b0;
			b_ack <= 1'b0;

			// Lines of a run are taken wherever the machine happens to be, not
			// only in the state that waits for them, because the first of them
			// can arrive before the last has been asked for. They come back in
			// the order they went out.
			if (pf_busy && m_valid && (pf_n != PFL)) begin
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
					if (xs_i[PFLB-1:0] != pf_want) begin
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
			S_IDLE: if (flush) begin flushing <= 1'b1; fidx <= {IDXBITS{1'b0}}; end
				else if (flushing) begin fl_serve <= 1'b1; st <= S_FLOOK; end
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
					line_q  <= data[idx];
					tag_q   <= tag[idx];
					valid_q <= valid[idx];
					dirty_q <= dirty[idx];
					st <= S_ANS;
				end

			// Kept for the flush walk's sake and as a safe landing state; the
			// ordinary path looks up in S_IDLE now.
			S_LOOK: begin
					line_q  <= data[idx];
					tag_q   <= tag[idx];
					valid_q <= valid[idx];
					dirty_q <= dirty[idx];
					st <= S_ANS;
				end

			S_ANS: if (hit) begin
					if (!refilled) dbg_hits <= dbg_hits + 32'd1;
					refilled <= 1'b0;
					if (we) begin
						data[idx]  <= line_mode ? merge16(line_q, a_be16, a_wdata128) : merge(line_q, wsel, be, wdata);
						dirty[idx] <= 1'b1;
						// this write makes any copy of the same run stale
						if (pf_hit) pf_valid <= 1'b0;
					end
					if (serving_b) begin b_rdata <= pick(line_q, wsel); b_line <= line_q; b_ack <= 1'b1; end
					else           begin a_rdata_r <= pick(line_q, wsel); a_line_r <= line_q; a_ack_r <= !fast_a; end
					st <= S_IDLE;
				end else if (b_around) begin
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
						pf_lin   <= serving_b ? 1'b0 : a_lin;
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
				end else if (!serving_b && line_mode && we) begin
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
					if (pf_hit) pf_valid <= 1'b0;   // the read-around copy is stale now
					m_addr  <= {tg, idx};
					m_wdata <= a_wdata128;
					m_we    <= 1'b1;
					m_wmask <= a_be16;
					m_req   <= 1'b1;
					st <= S_WA;
				end else begin
					dbg_misses <= dbg_misses + 32'd1;
					// The line here is somebody else's. Write it back if it is
					// dirty, then fetch the one wanted.
					if (valid_q && dirty_q) begin
						if (pf_valid && in_run(evicted - pf_base)) pf_valid <= 1'b0;
						m_addr  <= {tag_q, idx};
						m_wdata <= line_q;
						m_we    <= 1'b1;
						m_wmask <= 16'hFFFF;
						m_req   <= 1'b1;
						st <= S_WB;
					end else
						// a whole line arriving needs nothing from memory: allocate it
						st <= (line_mode && we && (&a_be16)) ? S_ALLOC : S_FILL;
				end

			S_WB: if (m_ready) begin
					m_req <= 1'b0;
					m_we  <= 1'b0;
					st <= (line_mode && we && (&a_be16)) ? S_ALLOC : S_FILL;
				end

			// the write-around is taken by memory: that is the whole of it
			S_WA: if (m_ready) begin
					m_req <= 1'b0;
					m_we  <= 1'b0;
					a_ack_r <= 1'b1;
					st <= S_IDLE;
				end

			S_ALLOC: begin
					if (pf_hit) pf_valid <= 1'b0;
					data[idx]  <= a_wdata128;
					tag[idx]   <= tg;
					valid[idx] <= 1'b1;
					dirty[idx] <= 1'b1;
					a_ack_r <= 1'b1;
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
					if (m_valid) begin
						data[idx]  <= m_rdata;
						tag[idx]   <= tg;
						valid[idx] <= 1'b1;
						dirty[idx] <= 1'b0;
						line_q  <= m_rdata;
						tag_q   <= tg;
						valid_q <= 1'b1;
						dirty_q <= 1'b0;
						refilled <= 1'b1;
						st <= S_ANS;          // now it hits
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
					line_q <= data[idx]; tag_q <= tag[idx]; valid_q <= valid[idx]; dirty_q <= dirty[idx];
					st <= S_FANS;
				end
			S_FANS: if (valid_q && dirty_q) begin
					if (pf_valid && (((evicted - pf_base) < 25'd2)
					    || (((evicted - pf_base) >= ROWL) && ((evicted - pf_base) < ROWL + 25'd2)))) pf_valid <= 1'b0;
					m_addr <= {tag_q, idx}; m_wdata <= line_q; m_we <= 1'b1; m_req <= 1'b1;
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
		end
	end
endmodule

`default_nettype wire
