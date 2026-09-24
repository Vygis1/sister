//////////////////////////////////////////////////////////////////////////////////
// shell_regs.v - the shell, as the fpgalink register bus sees it.
//
// The ESP32 is the front door this was designed around. This is the other one:
// the PC already has a register bus over UDP, a host library and a web UI, and
// none of that should have to wait for a parcel. Same flash engine underneath,
// same guarantees; only the way a command arrives is different.
//
//   0x0000_0000  SHELL
//     0x00  ID        "SHEL", read only
//     0x04  VERSION   read only
//     0x08  STATUS    0 busy, 1 MISO pin, 2 MISO ever low,
//                         15:8 clock edges sent, 23:16 transactions started,
//                         28:24 the flash controller's state
//     0x0C  SCRATCH   read/write, for proving the link carries data both ways
//     0x10  CTRL      write {offset[26:4], op[1:0]} and it starts
//     0x18  BOOT      $B007_0000 = the shell, $B007_0001 = the core
//
//   0x0001_0000  PAGE      64 words, the 256-byte page buffer
//   0x0002_0000  LA        the logic analyser, control
//   0x0003_0000  LABUF     its capture buffer, one sample per word
//
// The analyser is in the golden image on purpose. Both of the shell's jobs are
// wiggling pins at something that may or may not answer -- a flash chip and an
// ESP32 -- and on both of them "nothing came back" has half a dozen possible
// causes that a counter cannot tell apart and a waveform can.
//
// Everything a flash operation needs is in the one CTRL word, so installing a
// core is two packets per page -- the buffer, then go -- rather than three. Over
// 8192 pages that is the difference between a progress bar and a wait.
//
// BOOT takes a magic number because it is the one register whose side effect
// cannot be undone by writing it again: the chip stops being this design
// half a microsecond later. A stray write of 0 or 1 from a confused host would
// otherwise reconfigure the board.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_regs (
	input  wire        clk,
	input  wire        rst,

	// --- the bus -----------------------------------------------------------
	input  wire [31:0] bus_addr,
	input  wire [31:0] bus_wdata,
	input  wire        bus_we,
	input  wire        bus_re,
	output reg  [31:0] bus_rdata,
	output wire        bus_ack,
	output reg  [1:0]  bus_err,

	// --- the flash engine ---------------------------------------------------
	output reg  [1:0]  op,
	output reg  [22:0] offset,
	output reg         start,
	input  wire        busy,
	input  wire        miso_level,
	input  wire [7:0]  sck_edges,
	input  wire [7:0]  cs_falls,
	input  wire        miso_ever_low,
	input  wire [4:0]  fl_state,

	// --- the logic analyser -------------------------------------------------
	output wire [15:0] la_off,
	output wire        la_we,
	output wire [31:0] la_wdata,
	input  wire [31:0] la_rdata,
	output wire [11:0] la_buf_addr,
	input  wire [31:0] la_buf_rdata,

	output wire [5:0]  buf_windex,
	// High whenever the bus is addressing the page buffer, READ or write. The
	// index alone is not enough: a read has no write strobe to key off, and
	// selecting the index only on writes means every word of a page read comes
	// back as word 0.
	output wire        buf_sel,
	output reg         buf_we,
	output reg  [31:0] buf_wdata,
	input  wire [31:0] buf_rdata,

	// --- reconfiguration -----------------------------------------------------
	output reg         boot_core,     // 0 = back to the shell, 1 = the core
	output reg         boot_go
);

	localparam [31:0] ID      = 32'h5348_454C;      // "SHEL"
	localparam [31:0] VERSION = 32'h0001_0000;
	localparam [31:0] BOOT_MAGIC = 32'hB007_0000;

	localparam [15:0] PAGE_SHELL = 16'h0000;
	localparam [15:0] PAGE_BUF   = 16'h0001;
	localparam [15:0] PAGE_LA    = 16'h0002;
	localparam [15:0] PAGE_LABUF = 16'h0003;

	// The same two-cycle handshake the main register file uses: latch on the
	// first cycle, answer on the second. Acknowledging combinationally rather
	// than from a register matters -- a registered ack is still high a cycle
	// after the requester drops its strobe, and the transaction runs twice.
	reg        pending;
	reg [31:0] req_addr;

	assign bus_ack = pending;

	wire [31:0] sel_addr = pending ? req_addr : bus_addr;
	wire [15:0] page     = sel_addr[31:16];
	wire [15:0] off      = sel_addr[15:0];

	wire new_req = (bus_we || bus_re) && !pending;

	assign buf_windex = off[7:2];

	assign la_off      = off;
	assign la_wdata    = bus_wdata;
	assign la_we       = new_req && bus_we && (bus_addr[31:16] == PAGE_LA);
	assign la_buf_addr = sel_addr[13:2];
	// Only during an actual transaction. Decoding the address alone would leave
	// this following whatever the bus happens to be showing while idle -- which
	// in simulation is X, and X on the buffer index means every write lands
	// nowhere and every read comes back unknown.
	assign buf_sel    = (new_req && bus_addr[31:16] == PAGE_BUF)
	                 || (pending && req_addr[31:16] == PAGE_BUF);

	always @(posedge clk) begin
		if (rst) begin
			pending <= 1'b0; req_addr <= 32'd0;
		end else begin
			pending  <= new_req;
			if (new_req) req_addr <= bus_addr;
		end
	end

	reg [31:0] scratch;

	always @(posedge clk) begin
		if (rst) begin
			op <= 2'd0; offset <= 23'd0; start <= 1'b0;
			buf_we <= 1'b0; buf_wdata <= 32'd0;
			boot_core <= 1'b0; boot_go <= 1'b0;
			scratch <= 32'd0;
		end else begin
			start  <= 1'b0;
			buf_we <= 1'b0;

			if (new_req && bus_we) begin
				case (bus_addr[31:16])
				PAGE_SHELL: case (bus_addr[15:0])
					16'h000C: scratch <= bus_wdata;
					16'h0010: begin
						op     <= bus_wdata[1:0];
						offset <= bus_wdata[26:4];
						start  <= 1'b1;
					end
					16'h0018:
						if (bus_wdata[31:8] == BOOT_MAGIC[31:8]) begin
							boot_core <= bus_wdata[0];
							boot_go   <= 1'b1;
						end
					default: ;
					endcase
				PAGE_BUF: begin
					buf_we    <= 1'b1;
					buf_wdata <= bus_wdata;
				end
				default: ;
				endcase
			end
		end
	end

	always @* begin
		bus_rdata = 32'd0;
		bus_err   = 2'd0;
		case (page)
		PAGE_SHELL: case (off)
			16'h0000: bus_rdata = ID;
			16'h0004: bus_rdata = VERSION;
			16'h0008: bus_rdata = {3'd0, fl_state, cs_falls, sck_edges,
			                       5'd0, miso_ever_low, miso_level, busy};
			16'h000C: bus_rdata = scratch;
			default:  bus_rdata = 32'd0;
			endcase
		PAGE_BUF:   bus_rdata = buf_rdata;
		PAGE_LA:    bus_rdata = la_rdata;
		PAGE_LABUF: bus_rdata = la_buf_rdata;
		default:    bus_err   = 2'd1;          // unmapped
		endcase
	end

endmodule

`default_nettype wire
