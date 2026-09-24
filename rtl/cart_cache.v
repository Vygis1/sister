`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// cart_cache.v - what makes DDR3 look like a cartridge.
//
// Every console in this tree so far has kept its cartridge in block RAM, where a
// read is answered the cycle after it is asked for. A Mega Drive cartridge does
// not fit there and never will: the smallest common game is 512 kB and there is
// about 400 kB of block RAM on the whole chip once the framebuffer, the work RAM
// and the VDP have taken theirs.
//
// So the cartridge moves to the 256 MB of DDR3 on the board, and DDR3 answers in
// tens of cycles with timing that varies. This sits between them.
//
// --- why a cache is the right shape here ------------------------------------------
//
// Cartridge reads are the friendly case. Code runs forwards; the 68000 fetches
// one word after another and only jumps occasionally. The VDP's DMA walks memory
// in a straight line by definition. The Z80's sound driver reads its music the
// same way. Almost every read is the one after the last.
//
// So: direct-mapped, a line of eight words to match a DDR3 burst, and a prefetch
// that is issued HALFWAY THROUGH a line rather than at the end of it. That
// distinction is the whole design. Prefetching when a line runs out means the
// next read stalls for the full latency anyway; prefetching four words early
// gives the memory four word-times to answer in, and at 68000 speed four word
// reads is over a hundred clocks -- far more than DDR3 needs.
//
// One request is outstanding at a time, and hits are served while it is in
// flight. That is what keeps the prefetch free: the requester is not waiting on
// it, it is reading the second half of the line it already has.
//
// Nothing here is clever. The measurement in sim/tb_cart_cache.v is the point:
// if a cached sequential read is not comfortably inside a 68000 bus cycle, the
// Mega Drive needs a different shape, and it is better to know that now than
// after the VDP has been written around it.
//
// --- the ports ---------------------------------------------------------------------
//
// Two requesters, because the machine has two: the 68000, which the VDP's DMA
// also comes through, and the Z80's window into the cartridge. One is served at
// a time, and the 68000 goes first -- its stalls are the ones anybody sees.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module cart_cache #(
	// 256 lines of eight words is 4 kB of cache for a cartridge of up to 16 MB.
	// Small, and deliberately so: the access pattern is sequential, so what
	// matters is the line and the prefetch, not how much is held.
	parameter IDXBITS = 8
) (
	input  wire         clk,
	input  wire         rst,

	// --- the 68000's side, which the VDP's DMA also comes through ----------------
	input  wire [22:0]  a_addr,     // a word address
	input  wire         a_req,
	output reg  [15:0]  a_data,
	output reg          a_ack,

	// --- the Z80's window --------------------------------------------------------
	input  wire [22:0]  b_addr,
	input  wire         b_req,
	output reg  [15:0]  b_data,
	output reg          b_ack,

	// --- the memory behind it -----------------------------------------------------
	// One line per transfer. A DDR3 controller on a 16-bit part at a 4:1 ratio
	// hands over 128 bits at a time, which is exactly eight cartridge words.
	output reg  [19:0]  m_addr,     // in LINES
	output reg          m_req,
	input  wire         m_ready,    // the controller took the request
	input  wire [127:0] m_data,
	input  wire         m_valid,

	// --- for the measurement to read ------------------------------------------------
	output wire [31:0]  dbg_hits,
	output wire [31:0]  dbg_misses,
	output wire [31:0]  dbg_stall,
	output wire [31:0]  dbg_prefetch
);

	localparam LINES   = 1 << IDXBITS;
	localparam TAGBITS = 20 - IDXBITS;

	// --- the store ----------------------------------------------------------------------
	// One read and one write, each in ONE place, with the addresses muxed rather
	// than written out at each use. Two read expressions is two read ports, and
	// with the write that is three -- at which point the 32 kilobits of cache
	// stop being a block RAM and become fifteen hundred LUTs of distributed
	// memory. Nothing warns about it; only the utilisation report shows it.
	reg [127:0]       data [0:LINES-1];
	reg [TAGBITS-1:0] tag  [0:LINES-1];
	reg [LINES-1:0]   valid;

	// Which requester is being served. The 68000 gets first refusal; the Z80 asks
	// rarely and can wait a cycle.
	reg         serving_b;
	wire [22:0] req_addr = serving_b ? b_addr : a_addr;

	// Who is about to be served, decided a cycle before serving_b catches up.
	// This exists so the lookup can start in the same cycle a request arrives
	// rather than the one after -- which halves the cost of a hit, and a hit is
	// what almost every read is.
	wire [22:0] pick_addr = a_req ? a_addr : b_addr;

	wire [IDXBITS-1:0] idx = req_addr[3 + IDXBITS - 1 : 3];
	wire [TAGBITS-1:0] tg  = req_addr[22 : 3 + IDXBITS];
	wire [2:0]         off = req_addr[2:0];
	wire [19:0]        ln  = req_addr[22:3];

	reg [127:0]       line_q;
	reg [TAGBITS-1:0] tag_q;
	reg               valid_q;
	reg [2:0]         off_q;

	wire [15:0] word_q = line_q[{off_q, 4'd0} +: 16];

	// --- the one outstanding request ---------------------------------------------------
	reg        mem_busy;
	reg [19:0] mem_line;
	reg        mem_wanted;          // somebody is waiting on it, rather than a prefetch

	wire [IDXBITS-1:0] mem_idx = mem_line[IDXBITS-1:0];

	// --- the lookup ----------------------------------------------------------------------
	localparam S_IDLE = 3'd0, S_LOOK = 3'd1, S_ANS  = 3'd2,
	           S_MISS = 3'd3, S_FILL = 3'd4, S_DONE = 3'd5;

	// A requester samples the acknowledgement on a clock edge, so its request is
	// necessarily still asserted for a cycle afterwards. Without waiting for it to
	// let go, that lingering request reads as a NEW one -- and the answer to it
	// arrives in time to be mistaken for the answer to whatever is asked next.
	wire still_asking = serving_b ? b_req : a_req;

	reg [2:0] st;

	reg [31:0] n_hits, n_misses, n_stall, n_pre;
	assign dbg_hits     = n_hits;
	assign dbg_misses   = n_misses;
	assign dbg_stall    = n_stall;
	assign dbg_prefetch = n_pre;

	wire [19:0] next_ln = ln + 20'd1;

	// The last line asked for speculatively. Remembering it is what stops a loop
	// that lives in two lines from asking for the same one every time round --
	// and it costs a register compare, where checking the cache itself would cost
	// another read port on the tags.
	reg [19:0] last_pf;

	// The one read address, muxed. S_IDLE starts a lookup off whichever requester
	// is about to be served; S_LOOK repeats one after a fill.
	wire [IDXBITS-1:0] rd_idx = (st == S_IDLE) ? pick_addr[3 + IDXBITS - 1 : 3]
	                                           : idx;
	wire rd_en = ((st == S_IDLE) && (a_req || b_req)) || (st == S_LOOK);

	// The whole of the store's traffic, in one place: one write when a line comes
	// back, one read when a lookup starts. `valid` is a plain register rather
	// than an array, so it stays with the state machine below.
	always @(posedge clk) begin
		if (m_valid && mem_busy) begin
			data[mem_idx] <= m_data;
			tag[mem_idx]  <= mem_line[19:IDXBITS];
		end
		if (rd_en) begin
			line_q  <= data[rd_idx];
			tag_q   <= tag[rd_idx];
			valid_q <= valid[rd_idx];
			off_q   <= (st == S_IDLE) ? pick_addr[2:0] : off;
		end
	end

	always @(posedge clk) begin
		if (rst) begin
			st        <= S_IDLE;
			valid     <= {LINES{1'b0}};
			a_ack     <= 1'b0;
			b_ack     <= 1'b0;
			m_req     <= 1'b0;
			mem_busy  <= 1'b0;
			mem_wanted <= 1'b0;
			serving_b <= 1'b0;
			last_pf   <= 20'hFFFFF;
			n_hits    <= 32'd0;
			n_misses  <= 32'd0;
			n_stall   <= 32'd0;
			n_pre     <= 32'd0;
		end else begin
			a_ack <= 1'b0;
			b_ack <= 1'b0;

			// The controller has taken the request; stop asking.
			if (m_req && m_ready) m_req <= 1'b0;

			// A line has come back. It is written whatever asked for it, because
			// a prefetch nobody is waiting on is still worth keeping.
			if (m_valid && mem_busy) begin
				valid[mem_idx] <= 1'b1;
				mem_busy       <= 1'b0;
				mem_wanted     <= 1'b0;
			end

			case (st)
			S_IDLE: if (a_req || b_req) begin
					// The lookup itself is above, so that the array has exactly
					// one read address; this only says who is being served.
					serving_b <= !a_req;
					st        <= S_ANS;
				end

			S_LOOK: st <= S_ANS;   // look again, after a fill landed unwatched

			S_ANS: if (valid_q && tag_q == tg) begin
					n_hits <= n_hits + 32'd1;
					if (serving_b) begin b_data <= word_q; b_ack <= 1'b1; end
					else           begin a_data <= word_q; a_ack <= 1'b1; end
					st <= S_DONE;

					// Halfway through the line, ask for the next one. Nobody is
					// waiting on it, so the four words still to come out of this
					// line are the time it has to arrive in.
					if (off_q == 3'd3 && next_ln != last_pf
					    && !mem_busy && !m_req) begin
						m_addr     <= next_ln;
						m_req      <= 1'b1;
						mem_line   <= next_ln;
						mem_busy   <= 1'b1;
						mem_wanted <= 1'b0;
						last_pf    <= next_ln;
						n_pre      <= n_pre + 32'd1;
					end
				end else begin
					n_misses <= n_misses + 32'd1;
					st       <= S_MISS;
				end

			S_MISS: begin
					n_stall <= n_stall + 32'd1;
					// A prefetch already in flight may be the very line wanted --
					// which is the case this design exists to create -- so wait
					// for it rather than asking for it again.
					if (mem_busy && mem_line == ln) begin
						mem_wanted <= 1'b1;
						st         <= S_FILL;
					end else if (!mem_busy && !m_req) begin
						m_addr     <= ln;
						m_req      <= 1'b1;
						mem_line   <= ln;
						mem_busy   <= 1'b1;
						mem_wanted <= 1'b1;
						st         <= S_FILL;
					end
					// Otherwise a prefetch for some other line has the memory.
					// Wait: there is only one request outstanding at a time.
				end

			S_FILL: begin
					n_stall <= n_stall + 32'd1;
					// The line arrived between one state and the next, so nothing
					// was here to catch it. It is in the cache now; look again.
					if (!mem_busy && !m_req) st <= S_LOOK;
					else if (m_valid && mem_busy && mem_line == ln) begin
						// Answer out of what just arrived rather than reading it
						// back: it is right here.
						if (serving_b) begin
							b_data <= m_data[{off_q, 4'd0} +: 16];
							b_ack  <= 1'b1;
						end else begin
							a_data <= m_data[{off_q, 4'd0} +: 16];
							a_ack  <= 1'b1;
						end
						st <= S_DONE;
					end
				end

			S_DONE: if (!still_asking) st <= S_IDLE;

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
