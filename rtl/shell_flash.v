//////////////////////////////////////////////////////////////////////////////////
// shell_flash.v - the flash engine, and the reason the board cannot brick itself.
//
// A module of its own because there are two front doors -- an ESP32 on four
// wires, and a PC over Ethernet -- and the rule about what may be written must
// be true for both. Put the rule in one place and it is verified once; put it in
// each caller and it is a matter of everyone remembering.
//
// --- the layout ---------------------------------------------------------------
//
//   $000000 - $1FFFFF   the shell. 2 MB, and it uses half of that.
//   $200000 - $7FFFFF   the core.  6 MB, which is everything else.
//
// --- erase is ONE sector ---------------------------------------------------------
//
// Not the whole slot. An earlier version erased all ninety-six sectors on one
// command, which is tidy right up until you notice it spends three minutes
// clearing four megabytes nobody is about to write -- a sector erase on this
// part is up to three seconds and there is no way to hurry it.
//
// So the caller erases the sectors it needs and no others, which for a 1.9 MB
// core is thirty of them. It also removes a whole class of bug: with one chip
// operation per command there is no gap between sectors for a status poll to
// fall into and read "finished" early.
//
// --- one slot ---------------------------------------------------------------------
//
// Not several. Three 2 MB slots would let three cores sit resident and switch
// instantly, which is a real thing to want -- but it buys about thirty seconds
// against slot allocation, eviction, and a user interface that has to explain
// which core is in which numbered hole. One slot means a core is installed or it
// is not, and it gets every byte the shell is not using.
//
// 6 MB is more than a core can need: an uncompressed bitstream for this part is
// 3.65 MB and a compressed one about 2. The slack is where a BIOS image or a
// cartridge cache goes when a console wants one.
//
// --- the rule -----------------------------------------------------------------
//
// An offset is checked against the slot size and then added to the slot base.
// A comparison rather than a bit trick, because the sizes here are not powers of
// two that would make concatenation exact -- and a comparison the testbench
// actually fires $FFFFFF at is worth more than an elegant one nobody tested.
//
// Erase and program go through it. Reads do NOT: an offset given to a read is an
// absolute flash address anywhere in the 8 MB, because reading cannot damage
// anything and being able to read back the shell's own image is the only way to
// check that what was written is what is there. The rule exists to stop the
// board destroying itself, and a read cannot.
//
// --- busy ----------------------------------------------------------------------
//
// Includes the cycle in which a start has been accepted but the chip has not yet
// raised its own flag. Without that, a caller polling in exactly that cycle
// reads "finished" for an operation that has not begun.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_flash #(
	// Slower than it needs to be. The flash is comfortable far faster, but the
	// clock reaches it through STARTUPE2 rather than an ordinary pad, and that
	// path's delay is not something this design can measure. At DIV=16 a half
	// bit is 320 ns, which is wider than any plausible delay, so timing stops
	// being a candidate when something does not answer.
	parameter DIV = 16              // clocks per half SPI bit; see spi_flash.v
)(
	input  wire        clk,
	input  wire        rst,

	// --- what to do --------------------------------------------------------
	input  wire [1:0]  op,          // 0 chip id, 1 erase, 2 program, 3 read
	input  wire [22:0] offset,      // within the core slot
	input  wire        start,       // one clock
	output wire        busy,

	// --- the page buffer ----------------------------------------------------
	input  wire [5:0]  buf_windex,
	input  wire        buf_we,
	input  wire [31:0] buf_wdata,
	output wire [31:0] buf_rdata,

	// --- the pins -----------------------------------------------------------
	output wire        flash_cs_n,
	output wire        flash_mosi,
	input  wire        flash_miso,
	output wire        miso_level,   // the raw pin, for telling dead from idle
	// Three counters, because at this point reasoning has run out and the only
	// way forward is to measure. Between them they say whether the controller is
	// driving the pins at all, and whether the chip ever answers.
	output reg  [7:0]  sck_edges,    // rising edges sent, saturating
	output reg  [7:0]  cs_falls,     // transactions started
	output reg         miso_ever_low,
	output wire [4:0]  dbg_state,
	output wire        flash_sck     // to STARTUPE2, not to a pad
);

	localparam [23:0] SLOT_BASE = 24'h200000;     // 2 MB in
	localparam [23:0] SLOT_SIZE = 24'h600000;     // 6 MB of core

	localparam [1:0] OP_ID = 2'd0,
	                 OP_ERASE = 2'd1, OP_PROGRAM = 2'd2, OP_READ = 2'd3;
	localparam [1:0] FCMD_ID = 2'd0,
	                 FCMD_ERASE = 2'd1, FCMD_PROGRAM = 2'd2, FCMD_READ = 2'd3;

	reg  [1:0]  f_cmd;
	reg         f_start;
	reg  [23:0] f_addr;
	wire        f_busy;

	spi_flash #(.DIV(DIV)) u_flash (
		.clk(clk), .rst(rst),
		.cmd(f_cmd), .start(f_start), .addr(f_addr), .busy(f_busy),
		.buf_windex(buf_windex), .buf_we(buf_we),
		.buf_wdata(buf_wdata), .buf_rdata(buf_rdata),
		.spi_cs_n(flash_cs_n), .spi_mosi(flash_mosi),
		.spi_miso(flash_miso), .spi_clk(flash_sck),
		.dbg_state(dbg_state)
	);

	// Straight out to the status register. A flash that is not answering and a
	// flash answering with $FF are the same bytes; the difference is whether the
	// pin ever moves, and that is not visible anywhere else.
	assign miso_level = flash_miso;

	reg sck_d, cs_d;
	always @(posedge clk) begin
		if (rst) begin
			sck_edges <= 8'd0; cs_falls <= 8'd0; miso_ever_low <= 1'b0;
			sck_d <= 1'b0; cs_d <= 1'b1;
		end else begin
			sck_d <= flash_sck;
			cs_d  <= flash_cs_n;
			if (flash_sck && !sck_d && sck_edges != 8'hFF)
				sck_edges <= sck_edges + 8'd1;
			if (!flash_cs_n && cs_d && cs_falls != 8'hFF)
				cs_falls <= cs_falls + 8'd1;
			// Sticky, and only while selected: an idle bus says nothing.
			if (!flash_cs_n && !flash_miso) miso_ever_low <= 1'b1;
		end
	end

	// The one place an address is turned into a flash address. Anything outside
	// the slot is refused rather than clamped: clamping would write SOMEWHERE,
	// and a write nobody asked for is worse than a command that did nothing.
	wire        in_slot = ({1'b0, offset} < SLOT_SIZE);
	wire [23:0] target  = SLOT_BASE + {1'b0, offset};

	// Busy means "anything outstanding", which is not quite the same as the flash
	// chip's own flag: a start pulse has been accepted a cycle before the chip
	// raises it, and a caller polling in that cycle would read "finished".
	assign busy = f_busy | f_start;

	always @(posedge clk) begin
		if (rst) begin
			f_cmd <= 2'd0; f_start <= 1'b0; f_addr <= 24'd0;
		end else begin
			f_start <= 1'b0;

			if (start && !busy) case (op)
			// Touches no address, so it needs no bounds check: it asks the chip
			// who it is and puts the answer in the page buffer.
			OP_ID: begin
				f_cmd   <= FCMD_ID;
				f_start <= 1'b1;
			end
			// The 64 kB sector the offset falls in. The low sixteen bits are
			// dropped rather than required to be zero, so a caller can point at
			// any byte in a sector and mean that sector.
			OP_ERASE:
				if (in_slot) begin
					f_cmd   <= FCMD_ERASE;
					f_addr  <= {target[23:16], 16'd0};
					f_start <= 1'b1;
				end
			OP_PROGRAM:
				if (in_slot) begin
					f_cmd   <= FCMD_PROGRAM;
					f_addr  <= target;
					f_start <= 1'b1;
				end
			// Absolute, and unchecked, because 23 bits IS the whole flash and a
			// read has nothing to damage.
			OP_READ: begin
				f_cmd   <= FCMD_READ;
				f_addr  <= {1'b0, offset};
				f_start <= 1'b1;
			end
			default: ;
			endcase
		end
	end

endmodule

`default_nettype wire
