//////////////////////////////////////////////////////////////////////////////////
// mem_arb.v - one DDR3 controller, several machines asking it for things.
//
// The Mega Drive needs one port: a cartridge, read-only, behind a cache. That is
// what exists today and it would be a mistake to build the memory around it,
// because the machine this is aimed at needs four at once.
//
// A PlayStation has 2 MB of main RAM, 1 MB of VRAM and 512 kB of sound RAM, and
// the CPU, the GPU and the SPU are all in them at the same time. None of that
// fits in block RAM -- the part has about 600 kB in total -- so all three live
// out here, and the thing they share is this. Bolting a second master onto a
// single-port controller later is a rewrite; starting with an arbiter is not.
//
// --- what a port looks like -------------------------------------------------------
//
// One LINE of 128 bits, which is what a 16-bit DDR3 hands over in one burst at a
// 4:1 PHY ratio. Every client works in whole lines: a cache fills a line, the
// GPU reads a run of texels, the disc streamer writes a sector as four lines.
// Byte-granular access would mean read-modify-write inside the controller and a
// masked write path through every client, to serve nothing that needs it.
//
//     req    the client wants the line at addr; hold until ready
//     we     this is a write; wdata goes with it
//     ready  taken this cycle -- the client may drop req or present another
//     valid  rdata is the line that was asked for, one per accepted read
//
// Reads come back IN ORDER per port, because every client here either waits for
// its line or counts them, and reordering would buy latency that none of them
// can use.
//
// --- who wins ------------------------------------------------------------------------
//
// Fixed priority, lowest port number first, with a starvation guard.
//
// Fixed priority because the clients are genuinely not equal: a GPU that misses
// its scanline draws a torn frame, and a disc streamer that waits a microsecond
// does not care at all. Round-robin would treat them as if they were, which is
// fairness bought with the one thing the fast client cannot spare.
//
// The guard is what stops that becoming unfairness: a port that has been waiting
// while others are served for STARVE cycles is promoted above everyone. Without
// it a GPU in a tight loop can hold the bus indefinitely and the CPU behind it
// simply stops, which looks like a hung machine rather than a busy one.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module mem_arb #(
	parameter PORTS  = 4,
	parameter AW     = 24,          // line addresses: 24 bits of 16 bytes = 256 MB
	parameter STARVE = 64,          // cycles waiting before a port is promoted
	// ports whose request after `ready` is always a NEW one (they replace or drop it in the clock
	// after being taken): those may be taken again at once. The rest sit out the clock after a turn.
	parameter [PORTS-1:0] PIPE = {PORTS{1'b0}}
)(
	input  wire clk,
	input  wire rst,

	// --- the clients, concatenated ------------------------------------------------
	input  wire [PORTS*AW-1:0]  p_addr,
	input  wire [PORTS-1:0]     p_req,
	input  wire [PORTS-1:0]     p_we,
	input  wire [PORTS*128-1:0] p_wdata,
	input  wire [PORTS*16-1:0]  p_wmask,
	output wire [PORTS-1:0]     p_ready,
	output reg  [PORTS*128-1:0] p_rdata,
	output reg  [PORTS-1:0]     p_valid,

	// --- the memory ------------------------------------------------------------------
	output reg  [AW-1:0]   m_addr,
	output reg             m_req,
	output reg             m_we,
	output reg  [127:0]    m_wdata,
	output reg  [15:0]     m_wmask,
	input  wire            m_ready,
	input  wire [127:0]    m_rdata,
	input  wire            m_valid
);

	// --- picking a winner --------------------------------------------------------------
	//
	// `waited` counts, per port, how long it has had a request up while somebody
	// else was served. A port at STARVE is promoted; among promoted ports the
	// lowest still wins, so the rule stays simple enough to reason about.
	reg [15:0] waited [0:PORTS-1];
	integer    i;

	localparam QD = 32, QB = 5;
	reg [$clog2(PORTS+1)-1:0] q [0:QD-1];
	reg [QB:0] q_head, q_tail;
	wire       q_empty = (q_head == q_tail);
	wire       q_full  = ((q_tail - q_head) == QD[QB:0]);

	// A read that cannot be recorded is not a contender at all. Taking it out
	// here rather than refusing it after it has won is the whole difference
	// between "that read waits" and "nothing moves": the winner is chosen first,
	// so a read that wins and is then refused takes the bus down with it, and a
	// port with a WRITE to do -- which needs no queue entry, and whose completion
	// is what lets the queue drain -- never gets a turn. That deadlocked the
	// whole machine: no instructions retired and the picture stopped.
	wire [PORTS-1:0] p_req_ok = p_req & ~(q_full ? ~p_we : {PORTS{1'b0}});

	reg [PORTS-1:0] urgent;
	always @(*) begin
		urgent = {PORTS{1'b0}};
		for (i = 0; i < PORTS; i = i + 1)
			urgent[i] = p_req_ok[i] && (waited[i] >= STARVE);
	end

	// The port taken in the last clock may still be holding that request (see the handshake,
	// below): it sits this one out, unless it is a PIPE port. Everyone else may go now.
	reg  [$clog2(PORTS+1)-1:0] last_win; reg last_v;
	wire [PORTS-1:0] cool = (last_v && !PIPE[last_win]) ? ({{(PORTS-1){1'b0}}, 1'b1} << last_win) : {PORTS{1'b0}};
	wire [PORTS-1:0] contenders = ((|urgent) ? urgent : p_req_ok) & ~cool;

	reg [$clog2(PORTS+1)-1:0] win;
	reg                       any;
	always @(*) begin
		win = {$clog2(PORTS+1){1'b0}};
		any = 1'b0;
		for (i = PORTS - 1; i >= 0; i = i - 1)
			if (contenders[i]) begin
				win = i[$clog2(PORTS+1)-1:0];
				any = 1'b1;
			end
	end

	// --- whose read is outstanding ------------------------------------------------------
	//
	// The memory returns data some cycles after it accepted the request, and says
	// nothing about who asked. A queue of port numbers, one entry per accepted
	// read, is what puts each line back where it came from.
	//
	// It used to be depth 16 with four-bit pointers and NO full detection, on the
	// reasoning that nothing would ever have that many reads outstanding. The
	// video cache then started asking for a run of sixteen lines at once, the head
	// wrapped onto the tail, the queue read as EMPTY while it was full, and every
	// reply after that was thrown away: the scanout waited forever for a count
	// that could never arrive and the picture stopped dead. Nothing in the old
	// code could have noticed.
	//
	// So: an extra bit on each pointer, which tells full and empty apart, and a
	// read is not issued when there is nowhere to record it. Depth is a
	// performance choice now; correctness no longer depends on guessing it right.

	// --- the handshake --------------------------------------------------------------
	//
	// `p_ready` is COMBINATIONAL and means "your request is being taken on this
	// cycle", which is the only definition a client can act on.
	//
	// It was registered to begin with, and that is data corruption rather than a
	// style choice: ready arrives a cycle after the transfer, the client is
	// still holding req when it does, and the arbiter takes the same request
	// again -- and again -- issuing several reads where one was asked for. The
	// extra lines come back and are handed to a client no longer expecting them,
	// so from there on every port gets somebody else's data. It passes a
	// single-request test perfectly, because the duplicates fetch the same
	// address and nothing looks wrong until two clients are busy at once.
	// One command per m_req PULSE, not a held level. The memory (and a real MIG
	// controller) accepts a command every cycle req and ready are both high, so a
	// req held for even one extra cycle -- which happens because a client drops
	// its own req a cycle after it sees ready -- is taken twice, and once two
	// ports are busy the duplicates fill the return queue with reads nobody is
	// waiting for. So: issue only from idle, hold until the memory accepts, then
	// drop for a cycle. The gap is what makes "accepted once" true.
	// The memory's register is free when nothing is in it OR it is being taken this clock: the next
	// one goes up in the same clock. Issued only from idle, a transaction took two clocks at the
	// least -- 25 M lines a second, and the PlayStation's fill stopped at 365 MB/s (the console
	// 779). The gap is now per port (`cool`), which is all "accepted once" ever needed.
	wire             issue = !rst && (!m_req || m_ready) && any;   // never acknowledge what reset will not issue
	wire [PORTS-1:0] grant = issue
	                         ? ({{(PORTS-1){1'b0}}, 1'b1} << win)
	                         : {PORTS{1'b0}};
	assign p_ready = grant;

	always @(posedge clk) begin
		if (rst) begin
			m_req <= 1'b0; m_we <= 1'b0; m_addr <= {AW{1'b0}}; m_wdata <= 128'd0; m_wmask <= 16'hFFFF;
			last_v <= 1'b0; last_win <= {$clog2(PORTS+1){1'b0}};
			p_valid <= {PORTS{1'b0}};
			q_head <= 0; q_tail <= 0;
			for (i = 0; i < PORTS; i = i + 1) waited[i] <= 16'd0;
		end else begin
			p_valid <= {PORTS{1'b0}};

			last_v <= issue;
			if (issue) last_win <= win;
			if (m_req && m_ready && !issue) begin
				// accepted this cycle, nothing behind it: drop req so the memory cannot take it again
				m_req <= 1'b0;
			end else if (issue) begin
				// idle and someone wants in: present it and remember a read
				m_req   <= 1'b1;
				m_addr  <= p_addr [win*AW  +: AW];
				m_we    <= p_we   [win];
				m_wdata <= p_wdata[win*128 +: 128];
				m_wmask <= p_wmask[win*16 +: 16];
				waited[win] <= 16'd0;
				if (!p_we[win]) begin
					q[q_tail[QB-1:0]] <= win;
					q_tail            <= q_tail + 1'b1;
				end
			end

			// Everyone else who is asking has waited another cycle.
			for (i = 0; i < PORTS; i = i + 1)
				if (p_req[i] && !grant[i])
					waited[i] <= waited[i] + 16'd1;

			// A line came back: it belongs to whoever is at the head.
			if (m_valid && !q_empty) begin
				p_rdata[q[q_head[QB-1:0]]*128 +: 128] <= m_rdata;
				p_valid[q[q_head[QB-1:0]]]            <= 1'b1;
				q_head                                <= q_head + 1'b1;
			end
		end
	end

endmodule

`default_nettype wire
