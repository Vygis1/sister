//////////////////////////////////////////////////////////////////////////////////
// spi_flash.v - writing the board's configuration flash from user logic.
//
// This is what lets the board install a new core into itself. The flash it
// boots from is an ordinary SPI part, and after configuration its pins are
// ordinary I/O -- with one exception that matters: the clock is not a normal
// pin at all and has to be driven through the STARTUPE2 primitive. That single
// detail is most of why this is a module rather than three lines.
//
// On this package:
//
//   R14  D00_MOSI     data out
//   R15  D01_DIN      data in
//   P18  FCS_B        chip select
//   H13  CCLK         via STARTUPE2.USRCCLKO, not directly
//
// Single-bit SPI on purpose. Writing two megabytes over a 100 Mbit link takes
// far longer than the flash does, so a four-bit controller would add states for
// no gain anyone could measure.
//
// --- what a caller does -----------------------------------------------------
//
// Erasing comes first, always: flash can clear a bit but not set one, so a
// sector has to be erased before anything is written into it. A sector is
// 64 kB, and a page -- the most that can be programmed at once -- is 256 bytes.
// So installing a 2 MB core is 32 erases and 8192 page writes.
//
//   1. load 256 bytes into the page buffer
//   2. set the address, issue PROGRAM, wait for busy to clear
//
// Every operation that changes the flash needs a WRITE ENABLE first, and the
// chip clears that latch itself when the operation finishes, so it is issued
// per operation rather than once.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module spi_flash #(
	// Clocks per half SPI bit. 1 gives clk/2 -- 25 MHz from a 50 MHz clock --
	// which the flash is comfortable with and the ROUND TRIP is not: the clock
	// leaves through STARTUPE2, crosses to the flash, comes back through a pad
	// and a synchroniser, and all of that has to fit inside one clk period.
	// There is no margin in that at 25 MHz.
	//
	// It costs nothing to slow down, because nothing here is bounded by the
	// link: programming 2 MB is four seconds of flash busy time whatever rate
	// the bytes arrive at. DIV=4 gives 6.25 MHz and 80 ns of round trip to play
	// with, which is a different kind of number entirely.
	parameter DIV = 1
)(
	input  wire        clk,
	input  wire        rst,

	// --- control ---------------------------------------------------------
	input  wire [1:0]  cmd,          // 1 erase sector, 2 program page, 3 read page
	input  wire        start,
	input  wire [23:0] addr,
	output reg         busy,

	// --- the page buffer, as the register bus sees it ----------------------
	input  wire [5:0]  buf_windex,   // 64 words of 32 bits = one 256-byte page
	input  wire        buf_we,
	input  wire [31:0] buf_wdata,
	output wire [31:0] buf_rdata,

	// --- the pins ----------------------------------------------------------
	output reg         spi_cs_n,
	output reg         spi_mosi,
	input  wire        spi_miso,
	output wire        spi_clk,      // goes to STARTUPE2, not to a pad

	// Where the state machine is, straight out to a register the host can read.
	// Reasoning about this from the outside ran out: busy said one thing and the
	// pins said another, and only the state itself settles which.
	output wire [4:0]  dbg_state
);

	// Command 0 reads the chip's JEDEC identity into the first word of the page
	// buffer. It is not needed to install anything, and it is the most useful
	// command here: every other operation can fail silently against a flash that
	// is not answering -- an erased part and an absent one both read as $FF --
	// whereas $20 $BA $17 can only come from a Micron N25Q that is listening.
	localparam CMD_ID = 2'd0,
	           CMD_ERASE = 2'd1, CMD_PROGRAM = 2'd2, CMD_READ = 2'd3;

	// Micron N25Q opcodes.
	// RESET ENABLE then RESET MEMORY. Together they put the part back into its
	// power-on state from any mode it happens to be in -- including the quad and
	// XIP modes a configuration engine or an external programmer can leave it
	// in, where single-bit commands are not merely ignored but misread.
	localparam [7:0] OP_RSTEN = 8'h66, OP_RST = 8'h99;
	localparam [7:0] OP_WREN = 8'h06, OP_RDSR = 8'h05, OP_RDID = 8'h9F,
	                 OP_SE   = 8'hD8,          // 64 kB sector erase
	                 OP_PP   = 8'h02,          // page program, up to 256 bytes
	                 OP_READ = 8'h03;

	// --- the page buffer ----------------------------------------------------
	// Explicitly registers, not inferred RAM. It is 256 bytes -- 2048 flops out
	// of 126,800 -- and asking for RAM means asking for a memory written from
	// two places with different address shapes, which nothing can infer. Saying
	// what it is costs less than making the tool guess, and it all lives in the
	// one clocked block below for the same reason.
	(* ram_style = "registers" *)
	reg [31:0] page [0:63];

	assign buf_rdata = page[buf_windex];

	// --- the shift engine ----------------------------------------------------
	// One bit per two clocks: data changes while the clock is low and the chip
	// samples it on the rising edge.
	reg        sclk;
	reg [2:0]  bit_cnt;
	reg [7:0]  shift_out, shift_in;
	reg        shifting, byte_done;
	reg [7:0]  byte_idx;

	assign spi_clk   = sclk;

	// Where the next byte to send lives, and where a received one goes.
	wire [31:0] send_word = page[byte_idx[7:2]];
	wire [7:0]  page_q = byte_idx[1:0] == 2'd0 ? send_word[7:0]
	                   : byte_idx[1:0] == 2'd1 ? send_word[15:8]
	                   : byte_idx[1:0] == 2'd2 ? send_word[23:16]
	                                           : send_word[31:24];

	wire [7:0] rcv_idx = byte_idx - 8'd1;      // the byte just clocked in

	localparam S_IDLE   = 5'd0,  S_WREN    = 5'd1,  S_WREN_END = 5'd2,
	           S_OPCODE = 5'd3,  S_ADDR2   = 5'd4,  S_ADDR1    = 5'd5,
	           S_ADDR0  = 5'd6,  S_DATA    = 5'd7,  S_END      = 5'd8,
	           S_POLL   = 5'd9,  S_POLL_RD = 5'd10, S_POLL_CHK = 5'd11,
	           S_ID0    = 5'd12, S_ID1     = 5'd13, S_ID2      = 5'd14,
	           S_ID3    = 5'd15, S_WARM    = 5'd16, S_WARM2    = 5'd17,
	           S_RSTEN  = 5'd18, S_RSTEN2  = 5'd19, S_RST      = 5'd20,
	           S_RST2   = 5'd21, S_SETTLE  = 5'd22, S_DESEL    = 5'd23;

	// How long chip select must stay HIGH between two transactions.
	//
	// This is the whole reason writes to this flash did nothing for a day. The
	// code knew a write enable had to be its own transaction and raised chip
	// select between it and the command that followed -- but raised it for one
	// system clock, twenty nanoseconds, and the part wants fifty. So the flash
	// latched the write enable and then refused the command, every time, leaving
	// its status register reading $02: enabled, nothing in progress.
	//
	// It never looked like a timing problem. Reads worked perfectly, because a
	// read is one transaction that follows a long idle. Only the operations with
	// two transactions back to back failed, and they failed silently -- the
	// controller saw "not busy" and reported success.
	//
	// Sixteen clocks is 320 ns: six times the minimum, and free. Even in the
	// poll loop, which runs this most often, it is a tenth of one transaction.
	localparam [4:0] DESEL_CLKS = 5'd16;

	reg [4:0]  st;
	// Declared with `st` rather than up with the other outputs: xsim rejects a
	// reference to a signal before its declaration, and Vivado does not -- so a
	// forward reference builds a bitstream and stops the testbenches compiling.
	assign dbg_state = st;
	reg [3:0]  warm;
	reg [12:0] settle;
	reg [4:0]  desel_cnt;
	reg [4:0]  desel_next;
	reg [1:0]  op;
	reg [23:0] a;
	reg        need_poll;

	// Raise chip select, hold it up long enough for the part to notice, and then
	// go wherever the caller was heading.
	task deselect;
		input [4:0] nxt;
		begin
			spi_cs_n   <= 1'b1;
			desel_cnt  <= DESEL_CLKS;
			desel_next <= nxt;
			st         <= S_DESEL;
		end
	endtask

	task send;
		input [7:0] v;
		begin
			shift_out <= v;
			// The first bit goes out HERE, half a bit-time before the clock
			// that samples it. See the bit clock below for why that matters.
			spi_mosi  <= v[7];
			bit_cnt   <= 3'd7;
			shifting  <= 1'b1;
			sclk      <= 1'b0;
		end
	endtask

	// The bit engine's pace. Everything else runs at full speed; only the pin
	// wiggling is slowed.
	reg [7:0] divc;
	wire      tick = (divc == DIV[7:0] - 8'd1);
	always @(posedge clk) begin
		if (rst)      divc <= 8'd0;
		else if (tick) divc <= 8'd0;
		else          divc <= divc + 8'd1;
	end

	always @(posedge clk) begin
		if (rst) begin
			// Not S_IDLE: the clock has to be woken up first. See S_WARM.
			st <= S_WARM; busy <= 1'b1; spi_cs_n <= 1'b1; sclk <= 1'b0;
			shifting <= 1'b0; byte_done <= 1'b0; spi_mosi <= 1'b0;
			byte_idx <= 8'd0; need_poll <= 1'b0; op <= 2'd0; a <= 24'd0;
			bit_cnt <= 3'd0; shift_out <= 8'd0; shift_in <= 8'd0;
			warm <= 4'd0; settle <= 13'd0;
			desel_cnt <= 5'd0; desel_next <= S_IDLE;
		end else begin
			byte_done <= 1'b0;

			// The host filling the buffer. Its writes and the controller's are
			// in one block so the array has a single driver.
			if (buf_we) page[buf_windex] <= buf_wdata;

			// --- the bit clock ------------------------------------------------
			//
			// MOSI changes on the FALLING edge, never the rising one. This is
			// the whole of SPI mode 0 and it is not a detail.
			//
			// This code used to do `spi_mosi <= shift_out[7]; sclk <= 1'b1;` in
			// one cycle -- presenting a bit at the very instant the flash
			// latches it, with no setup time at all. In simulation that is
			// perfect, because the model samples after the update and sees the
			// new bit. On the wire the flash sampled a line that was still
			// moving, and latched the old bit OR the new one.
			//
			// The effect was every sent bit coming back OR'd with the bit before
			// it: the chip received `x | (x >> 1)`. That did not break
			// everything, which is why it survived so long -- $03, READ, is the
			// one opcode this mangling leaves alone, so reads were flawless
			// while every other command turned into a different command:
			//
			//   $9F read-id      -> $DF   nothing; MISO stays high, id reads FF
			//   $06 write-enable -> $07   nothing; writes are never enabled
			//   $05 read-status  -> $07   nothing; status reads FF, so bit 0 is
			//                             set, so a poll for "still busy" never
			//                             ends -- an erase appeared to hang
			//   $D8 sector-erase -> $FC   nothing
			//   $02 page-program -> $03   a READ, which is why programming was
			//                             silently harmless
			//
			// Addresses were mangled the same way, so a read of $200000 quietly
			// returned $300000. Every symptom, from one missing half-bit-time.
			if (shifting && tick) begin
				if (!sclk) begin
					sclk <= 1'b1;          // MOSI has been stable a half-bit
				end else begin
					sclk      <= 1'b0;
					shift_in  <= {shift_in[6:0], spi_miso};
					shift_out <= {shift_out[6:0], 1'b0};
					// Present the next bit now, while the clock is low, so it is
					// settled long before the edge that reads it.
					spi_mosi  <= shift_out[6];
					if (bit_cnt == 3'd0) begin
						shifting  <= 1'b0;
						byte_done <= 1'b1;
					end else bit_cnt <= bit_cnt - 3'd1;
				end
			end

			case (st)
			// --- waking the clock up -------------------------------------
			// CCLK is not an ordinary pin. Until configuration finishes it
			// belongs to the configuration engine, and when user logic takes it
			// over through STARTUPE2 the first few edges are simply not emitted.
			// A controller that starts its first command immediately loses the
			// top bits of the first opcode, and every transaction after that is
			// against a chip that heard something else entirely -- which reads
			// exactly like a flash that is not wired up.
			//
			// So: a hundred and twenty-eight edges with chip select HIGH, which
			// the flash ignores completely, purely to get the clock running
			// before anything is said over it. Sixteen microseconds, once.
			S_WARM: begin
					spi_cs_n <= 1'b1;
					send(8'hFF);
					st <= S_WARM2;
				end
			S_WARM2: if (byte_done) begin
					if (warm == 4'd15) st <= S_RSTEN;
					else begin
						warm <= warm + 4'd1;
						st   <= S_WARM;
					end
				end

			// --- putting the chip back where it started ------------------
			// Nothing here knows what state the flash was left in. The
			// configuration engine reads it at power-up, an external programmer
			// may have written it, and either can leave it in quad or XIP mode
			// -- where a single-bit command is not ignored but MISREAD, and
			// every answer comes back as ones. That failure is invisible: an
			// erased flash reads as ones too.
			//
			// So the first thing said to it is "go back to how you were", twice,
			// because the reset needs enabling before it will happen.
			S_RSTEN: begin
					spi_cs_n <= 1'b0;
					send(OP_RSTEN);
					st <= S_RSTEN2;
				end
			S_RSTEN2: if (byte_done) deselect(S_RST);
			S_RST: begin
					spi_cs_n <= 1'b0;
					send(OP_RST);
					st <= S_RST2;
				end
			S_RST2: if (byte_done) begin
					spi_cs_n <= 1'b1;
					settle   <= 13'd5000;      // 100 us at 50 MHz
					st       <= S_SETTLE;
				end
			// The part is unresponsive while it resets. Talking to it here would
			// be talking to nothing, and the answer would look exactly like the
			// problem this is fixing.
			S_SETTLE: if (settle == 13'd0) begin
					busy <= 1'b0;
					st   <= S_IDLE;
				end else settle <= settle - 13'd1;

			S_IDLE: if (start) begin
					busy      <= 1'b1;
					op        <= cmd;
					// A page program wraps WITHIN its page: give the chip $480
					// and the last 64 words land back at $400 rather than in
					// the page above. Nothing good comes of that, so the low
					// byte is dropped and a mid-page address means the page it
					// is in. Reads and erases keep the address they were given
					// -- a read can legitimately start anywhere, and an erase
					// address is already only meaningful to sector granularity.
					a         <= (cmd == CMD_PROGRAM) ? {addr[23:8], 8'd0} : addr;
					byte_idx  <= 8'd0;
					spi_cs_n  <= 1'b0;
					// A read changes nothing, so it needs neither the write
					// enable in front nor the wait for the chip behind.
					need_poll <= (cmd != CMD_READ) && (cmd != CMD_ID);
					if (cmd == CMD_ID) begin
						send(OP_RDID);
						st <= S_ID0;
					end else if (cmd == CMD_READ) begin
						send(OP_READ);
						st <= S_OPCODE;
					end else begin
						send(OP_WREN);
						st <= S_WREN;
					end
				end

			// Three bytes out of the chip and nowhere to put them but the page
			// buffer, which is idle whenever this runs.
			S_ID0: if (byte_done) begin send(8'h00); st <= S_ID1; end
			S_ID1: if (byte_done) begin
					page[0][7:0] <= shift_in;
					send(8'h00);
					st <= S_ID2;
				end
			S_ID2: if (byte_done) begin
					page[0][15:8] <= shift_in;
					send(8'h00);
					st <= S_ID3;
				end
			S_ID3: if (byte_done) begin
					page[0][23:16] <= shift_in;
					deselect(S_END);
				end

			// The write enable is its own transaction: chip select has to rise
			// between it and the operation it enables, or the chip ignores it.
			S_WREN:     if (byte_done) deselect(S_WREN_END);
			S_WREN_END: begin
					spi_cs_n <= 1'b0;
					send(op == CMD_ERASE ? OP_SE : OP_PP);
					st <= S_OPCODE;
				end

			S_OPCODE: if (byte_done) begin send(a[23:16]); st <= S_ADDR2; end
			S_ADDR2:  if (byte_done) begin send(a[15:8]);  st <= S_ADDR1; end
			S_ADDR1:  if (byte_done) begin send(a[7:0]);   st <= S_ADDR0; end
			S_ADDR0:  if (byte_done) begin
					if (op == CMD_ERASE) begin
						deselect(S_POLL);
					end else begin
						send(op == CMD_READ ? 8'h00 : page_q);
						byte_idx <= 8'd1;
						st <= S_DATA;
					end
				end

			S_DATA: if (byte_done) begin
					// Store the byte that just arrived, at the index it was
					// requested for rather than the one about to be requested.
					if (op == CMD_READ)
						page[rcv_idx[7:2]][{rcv_idx[1:0], 3'b000} +: 8] <= shift_in;

					if (byte_idx == 8'd0) begin        // wrapped: all 256 done
						deselect(need_poll ? S_POLL : S_END);
					end else begin
						send(op == CMD_READ ? 8'h00 : page_q);
						byte_idx <= byte_idx + 8'd1;
					end
				end

			// An erase takes the best part of a second and a page write about a
			// millisecond, so the only way to know it is done is to ask.
			S_POLL: begin
					spi_cs_n <= 1'b0;
					send(OP_RDSR);
					st <= S_POLL_RD;
				end
			S_POLL_RD:  if (byte_done) begin send(8'h00); st <= S_POLL_CHK; end
			S_POLL_CHK: if (byte_done)
					// Bit 0 is write-in-progress. Deselecting properly between
					// polls matters as much as it does anywhere else: the part
					// answers a status read it did not see the start of with
					// whatever the line happens to be sitting at.
					deselect(shift_in[0] ? S_POLL : S_END);

			S_DESEL: if (desel_cnt == 5'd0) st <= desel_next;
			         else desel_cnt <= desel_cnt - 5'd1;

			S_END: begin busy <= 1'b0; st <= S_IDLE; end

			default: st <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
