//////////////////////////////////////////////////////////////////////////////////
// cart_mem.v - the cartridge, as block RAM the host fills over the network.
//
// Pulled out of the NES wrapper because the board cannot afford a second copy.
// The part has 135 block RAM tiles, about 600 kB, and the framebuffer, audio
// ring and this cartridge already account for most of it. A second console
// therefore does not get its own cartridge memory -- it reads this one. That is
// also how the real thing works: one slot, one cartridge at a time.
//
// Storage is 32-bit words because that is what the register bus carries, and
// the cores read single bytes, so the low two address bits pick the byte. The
// extra cycle that costs is free: a CPU holds an address for a whole CPU cycle
// and the PPU holds each fetch for two dots.
//
// Three independent reads, which is why this is worth being a module:
//
//   prog  the running core's code fetch      (NES PRG, SMS ROM)
//   char  the running core's tile fetch      (NES CHR; the SMS has no such bus)
//   host  the register bus reading back what it wrote
//
// The host port is not optional. Without it, reading the cartridge back returns
// whatever the core happened to be fetching, which looks exactly like a
// corrupted upload and is really a missing port.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module cart_mem #(
	parameter PROG_AW = 18,           // 256 kB of code
	parameter CHAR_AW = 17,           // 128 kB of tiles

	// Whether the running core ever WRITES these memories. Both are true when
	// the image contains the machine that does it -- the Z80 needs program
	// memory to be RAM, and the NES needs tile memory to be RAM for cartridges
	// that carry no tile ROM.
	//
	// They exist because of how block RAM inference works, not for tidiness. A
	// memory written from two always blocks is a true dual-port template, and
	// Vivado refuses to infer one when a port's write enable is a constant zero
	// -- which is exactly what it becomes in an image built without the machine
	// that does the writing. The error is "Unsupported RAM template", and the
	// fix is to not describe a port that is not there.
	parameter PROG_CORE_WRITES = 1,
	parameter CHAR_CORE_WRITES = 1
)(
	input  wire clk,

	// host side, one 32-bit word at a time
	input  wire [PROG_AW-3:0] prog_windex,
	input  wire               prog_we,
	input  wire [CHAR_AW-3:0] char_windex,
	input  wire               char_we,
	input  wire [31:0]        wdata,
	output wire [31:0]        prog_host_rdata,
	output wire [31:0]        char_host_rdata,

	// core side, one byte at a time
	input  wire [PROG_AW-1:0] prog_addr,
	output reg  [7:0]         prog_din,
	// The running core can write to program memory too. A NES cartridge never
	// does, but a Z80 running a test program needs its 64 kB to be RAM, and
	// this is where that RAM comes from -- there is not enough spare block RAM
	// on the part for a second 64 kB.
	input  wire [7:0]         prog_wdata,
	input  wire               prog_core_we,
	input  wire [CHAR_AW-1:0] char_addr,
	output reg  [7:0]         char_din,
	// Cartridges with no tile ROM give the PPU RAM instead and build their tiles
	// at runtime. UxROM boards almost all work that way.
	input  wire [7:0]         char_wdata,
	input  wire               char_core_we
);

	localparam PROG_WORDS = 1 << (PROG_AW - 2);
	localparam CHAR_WORDS = 1 << (CHAR_AW - 2);

	// cascade_height = 1: Vivado 2026.1 otherwise chains RAMB36s for the larger
	// cartridges and then fails its own DRC (REQP-1962, the ADDR15 tie-off of
	// the two halves disagreeing) before placement. The SMS build hit it; the
	// NES, with a smaller PROG_WORDS, did not. One RAMB36 per address slice
	// costs nothing here and is what every build gets.
	(* cascade_height = 1 *) reg [31:0] prog_mem [0:PROG_WORDS-1];
	reg [31:0] char_mem [0:CHAR_WORDS-1];

	reg [31:0] prog_q, char_q, prog_hq, char_hq;
	reg [1:0]  prog_sel, char_sel;

	// One write address per memory, and each read in its own block: writing a
	// memory from two different address expressions inside one block stops
	// Vivado inferring block RAM, and the whole cartridge lands in LUTs.
	always @(posedge clk) begin
		if (prog_we) prog_mem[prog_windex] <= wdata;
		prog_hq <= prog_mem[prog_windex];
	end
	// Byte writes into a 32-bit memory. Spelling out one `if` per byte lane is
	// what makes Vivado infer the block RAM's byte write enables rather than a
	// read-modify-write, which would need an extra cycle and a second port.
	generate if (PROG_CORE_WRITES) begin : g_prog
		always @(posedge clk) begin
			if (prog_core_we && prog_addr[1:0] == 2'd0)
				prog_mem[prog_addr[PROG_AW-1:2]][7:0]   <= prog_wdata;
			if (prog_core_we && prog_addr[1:0] == 2'd1)
				prog_mem[prog_addr[PROG_AW-1:2]][15:8]  <= prog_wdata;
			if (prog_core_we && prog_addr[1:0] == 2'd2)
				prog_mem[prog_addr[PROG_AW-1:2]][23:16] <= prog_wdata;
			if (prog_core_we && prog_addr[1:0] == 2'd3)
				prog_mem[prog_addr[PROG_AW-1:2]][31:24] <= prog_wdata;
			prog_q   <= prog_mem[prog_addr[PROG_AW-1:2]];
			prog_sel <= prog_addr[1:0];
		end
	end else begin : g_prog
		always @(posedge clk) begin
			prog_q   <= prog_mem[prog_addr[PROG_AW-1:2]];
			prog_sel <= prog_addr[1:0];
		end
	end endgenerate

	always @(posedge clk) begin
		if (char_we) char_mem[char_windex] <= wdata;
		char_hq <= char_mem[char_windex];
	end
	generate if (CHAR_CORE_WRITES) begin : g_char
		always @(posedge clk) begin
			if (char_core_we && char_addr[1:0] == 2'd0)
				char_mem[char_addr[CHAR_AW-1:2]][7:0]   <= char_wdata;
			if (char_core_we && char_addr[1:0] == 2'd1)
				char_mem[char_addr[CHAR_AW-1:2]][15:8]  <= char_wdata;
			if (char_core_we && char_addr[1:0] == 2'd2)
				char_mem[char_addr[CHAR_AW-1:2]][23:16] <= char_wdata;
			if (char_core_we && char_addr[1:0] == 2'd3)
				char_mem[char_addr[CHAR_AW-1:2]][31:24] <= char_wdata;
			char_q   <= char_mem[char_addr[CHAR_AW-1:2]];
			char_sel <= char_addr[1:0];
		end
	end else begin : g_char
		always @(posedge clk) begin
			char_q   <= char_mem[char_addr[CHAR_AW-1:2]];
			char_sel <= char_addr[1:0];
		end
	end endgenerate

	assign prog_host_rdata = prog_hq;
	assign char_host_rdata = char_hq;

	always @* begin
		case (prog_sel)
			2'd0:    prog_din = prog_q[7:0];
			2'd1:    prog_din = prog_q[15:8];
			2'd2:    prog_din = prog_q[23:16];
			default: prog_din = prog_q[31:24];
		endcase
		case (char_sel)
			2'd0:    char_din = char_q[7:0];
			2'd1:    char_din = char_q[15:8];
			2'd2:    char_din = char_q[23:16];
			default: char_din = char_q[31:24];
		endcase
	end

endmodule

`default_nettype wire
