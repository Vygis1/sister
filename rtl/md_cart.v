//////////////////////////////////////////////////////////////////////////////////
// md_cart.v - a Mega Drive cartridge in block RAM, shaped like DDR3.
//
// `cart_cache` was written against a DDR3 controller: it asks for a 128-bit LINE
// and waits. This answers that same interface out of block RAM, so the Mega
// Drive can run on the board before the memory controller exists.
//
// --- what this is and is not ----------------------------------------------------
//
// It is not a substitute for DDR3 and it is not pretending to be. The part has
// about 600 kB of block RAM in total and a framebuffer, the VDP's VRAM, the
// 68000's work RAM and the cache all want some of it, so what is left for a
// cartridge is a couple of hundred kilobytes. Mega Drive games start at 512 kB
// and go to 4 MB: almost nothing commercial fits here.
//
// What does fit is every test ROM and most homebrew, which is exactly what is
// needed to prove the 68000, the VDP, the Z80 and the FM chip work on real
// hardware rather than only in a testbench. When the MIG exists this module is
// replaced by it and NOTHING above it changes -- that is the whole reason
// cart_cache was given a line interface in the first place.
//
// --- why four cycles and not one ------------------------------------------------
//
// A line is eight 16-bit cartridge words: 128 bits. Storing it as one 128-bit
// wide memory would answer in a single cycle and cost four block RAMs minimum
// per line-width regardless of depth, which at this size wastes most of them.
// Storing 32-bit words and reading four of them costs four cycles and uses the
// RAM fully.
//
// Four cycles is free here. The cache was measured against a DDR3 model that
// takes twelve cycles to open a row, and it was built to hide exactly this.
//
// --- how the bytes sit --------------------------------------------------------
//
// The host fills this over the register bus, which carries 32-bit words, and it
// writes the ROM image byte for byte: byte N of the file lands in bit lane
// (N mod 4) of word (N div 4). The 68000 is big-endian, so a cartridge word at
// word-address W is byte 2W followed by byte 2W+1 -- high byte first.
//
// Therefore one stored 32-bit word holds two cartridge words, and they come out
// byte-swapped relative to how a little-endian host wrote them:
//
//     stored d[31:0]  ->  cart word 2k   = {d[7:0],   d[15:8]}
//                         cart word 2k+1 = {d[23:16], d[31:24]}
//
// Getting this wrong does not produce garbage on screen, it produces a 68000
// that executes the high and low halves of every instruction the wrong way
// round and dies on the first branch -- so it is worth stating rather than
// leaving to be rediscovered.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module md_cart #(
	// Words of 32 bits. 15 bits is 32768 words -- 128 kB -- which is about what
	// can be spared once the framebuffer, VRAM and work RAM have taken theirs.
	parameter AW = 15
)(
	input  wire        clk,
	input  wire        rst,

	// --- the host filling it, over the register bus ---------------------------
	input  wire [AW-1:0] host_windex,
	input  wire          host_we,
	input  wire [31:0]   wdata,
	output wire [31:0]   host_rdata,

	// --- the cache asking for lines -------------------------------------------
	input  wire [19:0]  m_addr,      // in LINES of sixteen bytes
	input  wire         m_req,
	output reg          m_ready,
	output reg  [127:0] m_data,
	output reg          m_valid
);

	localparam WORDS = 1 << AW;

	// ONE write port and ONE read address, explicitly muxed. Two read
	// expressions would be two read ports, and with the write that is three --
	// at which point this stops being block RAM and becomes thousands of LUTs.
	reg [31:0] mem [0:WORDS-1];

	// Block RAM comes up zeroed when the FPGA is configured, so say so. Left
	// undefined, simulation disagrees with the board everywhere the cartridge
	// has not been written -- and the 68000 prefetches two words past whatever
	// it is running, so even a program that stops cleanly at the end of a small
	// ROM reads there. An X opcode then looks like a missing instruction rather
	// than like memory nobody filled in.
	integer mi;
	initial for (mi = 0; mi < WORDS; mi = mi + 1) mem[mi] = 32'd0;
	reg [31:0] q;
	reg [31:0] host_q;

	// A line is four consecutive 32-bit words. The line address times four is
	// the first of them.
	reg [1:0]      beat;
	reg [AW-1:0]   fetch_base;
	reg [2:0]      st;

	localparam S_IDLE = 3'd0, S_READ = 3'd1, S_WAIT = 3'd2, S_DONE = 3'd3;

	wire [AW-1:0] read_addr = (st == S_IDLE) ? host_windex
	                                         : (fetch_base | {{(AW-2){1'b0}}, beat});

	always @(posedge clk) begin
		if (host_we) mem[host_windex] <= wdata;
		q <= mem[read_addr];
	end
	assign host_rdata = q;

	// A stored word holds two cartridge words, high byte first. See the header.
	function [31:0] swap2;
		input [31:0] d;
		swap2 = {d[23:16], d[31:24], d[7:0], d[15:8]};
	endfunction

	always @(posedge clk) begin
		if (rst) begin
			st      <= S_IDLE;
			m_ready <= 1'b1;
			m_valid <= 1'b0;
			m_data  <= 128'd0;
			beat    <= 2'd0;
		end else begin
			m_valid <= 1'b0;

			case (st)
			S_IDLE: begin
				m_ready <= 1'b1;
				if (m_req) begin
					// The line address is in sixteen-byte units; the store is in
					// four-byte words, so the bottom two bits of the word address
					// are the beat and the rest is the line.
					fetch_base <= {m_addr[AW-3:0], 2'b00};
					beat       <= 2'd0;
					m_ready    <= 1'b0;
					st         <= S_READ;
				end
			end

			// One cycle of address, one of data: the memory is registered, so
			// the word asked for in S_READ arrives during S_WAIT.
			S_READ: st <= S_WAIT;

			S_WAIT: begin
				m_data[beat * 32 +: 32] <= swap2(q);
				if (beat == 2'd3) st <= S_DONE;
				else begin
					beat <= beat + 2'd1;
					st   <= S_READ;
				end
			end

			S_DONE: begin
				m_valid <= 1'b1;
				m_ready <= 1'b1;
				st      <= S_IDLE;
			end
			default: st <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
