//////////////////////////////////////////////////////////////////////////////////
// cart_ddr3.v - the cartridge, in DDR3 instead of block RAM.
//
// Drop-in for md_cart: the same line interface to cart_cache and the same 32-bit
// host fill port, so nothing above it changes. What changes is the ceiling --
// from 128 kB of block RAM to as much of 256 MB as anyone wants.
//
// --- two jobs on one port -----------------------------------------------------------
//
// Filling and playing never overlap. The host holds the console in reset while it
// writes a cartridge in, and releases it afterwards; that is how every loader
// here works and it is not an accident of timing but the order of operations.
// So one memory port is muxed between them rather than two arbitrated, which
// removes a whole class of question about what happens when a fill lands in the
// middle of a fetch.
//
// If that ever stops being true -- a PlayStation streaming disc sectors into
// memory WHILE the CPU runs is exactly that -- the fill side becomes its own
// client of mem_arb and this mux goes away. The interface here does not change
// when it does.
//
// --- packing --------------------------------------------------------------------------
//
// The register bus carries 32 bits and DDR3 wants 128, so four host words are
// gathered and written as one line. The host writes sequentially, which makes
// this a counter rather than a cache: the line is flushed when its fourth word
// arrives, and any trailing partial line is flushed when the fill is ended.
//
// Forgetting that flush loses the last few bytes of every cartridge -- which for
// a 68000 image is usually padding, so it would work for a long time and then
// not.
//
// --- byte order -------------------------------------------------------------------------
//
// Identical to md_cart, deliberately. The host packs the ROM's bytes
// little-endian into 32-bit words; the 68000 is big-endian; so a stored word
// holds two cartridge words that come out byte-swapped:
//
//     stored d[31:0]  ->  cart word 2k   = {d[7:0],   d[15:8]}
//                         cart word 2k+1 = {d[23:16], d[31:24]}
//
// The swap is done HERE on the way out rather than on the way in, so that what
// sits in DDR3 is the ROM file byte for byte and can be read back and compared
// against it without a transformation in the way.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module cart_ddr3 #(
	// Where the cartridge starts in DDR3, in 16-byte lines. Clear of anything a
	// console might want for work RAM later.
	parameter [23:0] BASE = 24'h00_0000
)(
	input  wire        clk,
	input  wire        rst,

	// --- the host filling it ----------------------------------------------------
	input  wire [21:0] host_windex,    // 32-bit word index into the cartridge
	input  wire        host_we,
	input  wire [31:0] wdata,
	input  wire        fill_end,       // flush whatever is left of a part line

	// --- the cache asking for lines ------------------------------------------------
	input  wire [19:0]  m_addr,
	input  wire         m_req,
	output wire         m_ready,
	output reg  [127:0] m_data,
	output reg          m_valid,

	// --- out to memory --------------------------------------------------------------
	output reg  [23:0]  d_addr,
	output reg          d_req,
	output reg          d_we,
	output reg  [127:0] d_wdata,
	input  wire         d_ready,
	input  wire [127:0] d_rdata,
	input  wire         d_valid,
	input  wire         d_calibrated
);

	// --- gathering four host words into a line -----------------------------------------
	reg [127:0] fill_buf;
	reg [21:0]  fill_line;       // which line the buffer belongs to
	reg [1:0]   fill_cnt;
	reg         fill_pending;    // a full line is waiting to be written

	// --- what the port is doing --------------------------------------------------------
	localparam S_IDLE = 2'd0, S_WRITE = 2'd1, S_READ = 2'd2;
	reg [1:0] st;

	// Reads are refused while a fill is in progress. The console is in reset then
	// and asks for nothing, so this costs nothing; it exists so that the one
	// memory port has an unambiguous owner at every moment.
	assign m_ready = d_calibrated && (st == S_IDLE) && !fill_pending;

	always @(posedge clk) begin
		if (rst) begin
			st <= S_IDLE;
			d_req <= 1'b0; d_we <= 1'b0; d_addr <= 24'd0; d_wdata <= 128'd0;
			m_valid <= 1'b0; m_data <= 128'd0;
			fill_buf <= 128'd0; fill_cnt <= 2'd0; fill_pending <= 1'b0;
			fill_line <= 22'd0;
		end else begin
			m_valid <= 1'b0;

			// --- the host writing ---------------------------------------------------
			if (host_we) begin
				fill_buf[host_windex[1:0] * 32 +: 32] <= wdata;
				fill_line <= host_windex[21:2];
				// A line is complete when its last word arrives. Counting the
				// words rather than watching the index change means a host that
				// writes them out of order still fills the line it is in.
				if (host_windex[1:0] == 2'd3) fill_pending <= 1'b1;
				fill_cnt <= host_windex[1:0];
			end

			// A short final line still has to go out, or the tail of every
			// cartridge is missing.
			if (fill_end && (fill_cnt != 2'd3)) fill_pending <= 1'b1;

			case (st)
			S_IDLE: begin
				d_req <= 1'b0;
				if (fill_pending && d_calibrated) begin
					d_addr  <= BASE + {2'd0, fill_line};
					d_wdata <= fill_buf;
					d_we    <= 1'b1;
					d_req   <= 1'b1;
					st      <= S_WRITE;
					// The line is in d_wdata now, so the buffer is free for the next one:
					// cleared here (a short final line pads with zeros), keeping a word the
					// host writes this same clock. It used to be cleared when the memory
					// TOOK the write -- and a memory that held d_ready low (refresh,
					// calibration, another port) for longer than a word's interval had by
					// then had the next line's first words written into the buffer, which
					// the clear wiped: a random zero word in the cartridge.
					fill_buf     <= host_we ? ({96'd0, wdata} << (host_windex[1:0] * 32)) : 128'd0;
					fill_pending <= host_we && (host_windex[1:0] == 2'd3);
				end else if (m_req && m_ready) begin
					d_addr <= BASE + {4'd0, m_addr};
					d_we   <= 1'b0;
					d_req  <= 1'b1;
					st     <= S_READ;
				end
			end

			S_WRITE: if (d_ready) begin
					d_req        <= 1'b0;
					st           <= S_IDLE;
				end

			S_READ: begin
				if (d_ready) d_req <= 1'b0;
				if (d_valid) begin
					// Back into big-endian 68000 words. See the header.
					m_data[  0 +: 16] <= {d_rdata[  7:  0], d_rdata[ 15:  8]};
					m_data[ 16 +: 16] <= {d_rdata[ 23: 16], d_rdata[ 31: 24]};
					m_data[ 32 +: 16] <= {d_rdata[ 39: 32], d_rdata[ 47: 40]};
					m_data[ 48 +: 16] <= {d_rdata[ 55: 48], d_rdata[ 63: 56]};
					m_data[ 64 +: 16] <= {d_rdata[ 71: 64], d_rdata[ 79: 72]};
					m_data[ 80 +: 16] <= {d_rdata[ 87: 80], d_rdata[ 95: 88]};
					m_data[ 96 +: 16] <= {d_rdata[103: 96], d_rdata[111:104]};
					m_data[112 +: 16] <= {d_rdata[119:112], d_rdata[127:120]};
					m_valid <= 1'b1;
					st      <= S_IDLE;
				end
			end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
