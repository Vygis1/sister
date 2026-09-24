`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// spiflash_model.v - enough of a Micron N25Q64 to argue with.
//
// The controller that drives this is about to rewrite the flash the board boots
// from. Testing it for the first time on hardware has exactly one failure mode
// worth naming: the board stops booting and the only way back is JTAG. So it
// gets a chip to talk to first, and the chip is deliberately PEDANTIC about the
// things real flash is pedantic about:
//
//   - A write needs WRITE ENABLE immediately before it, in its own transaction.
//     Chip select must rise in between. The chip clears the latch itself when
//     the write finishes, so one WREN never authorises two writes.
//   - Programming can only CLEAR bits. Writing $FF over $00 leaves $00. A model
//     that simply stored the byte would hide a controller that forgot to erase,
//     which is the single most likely thing to be wrong.
//   - Erase and program take real time, and the only way to know they have
//     finished is to poll the status register.
//   - Anything written while the chip is busy is ignored entirely.
//   - A page program wraps within its 256-byte page rather than running on.
//
// Not modelled: quad mode, subsector erase, OTP, lock and protection registers.
// None of them are on the path this design uses.
//////////////////////////////////////////////////////////////////////////////////

module spiflash_model #(
	parameter ADDR_BITS  = 23,              // 8 Mbyte
	parameter ERASE_NS   = 20000,           // the real part takes ~700 ms
	parameter PROGRAM_NS = 2000,            // the real part takes ~0.5 ms

	// Start in the state a real chip is often found in: some other mode, left
	// behind by a configuration engine or an external programmer, in which
	// single-bit commands are not understood. Nothing works until the controller
	// resets it. Worth modelling because the symptom is invisible -- a chip in
	// the wrong mode and an erased chip both answer with ones.
	parameter CONFUSED   = 0,

	// How long chip select must stay HIGH between two transactions before this
	// part will look at the second one.
	//
	// Modelling this is not fussiness. A controller that raised chip select for
	// twenty nanoseconds between a write enable and the command it enables
	// passed every test in this file while writing nothing whatsoever to real
	// hardware for a day -- because a model that ignores the deselect time
	// cheerfully accepts a command the silicon refuses. Reads were unaffected
	// and looked perfect, which is what made it so hard to see.
	parameter DESELECT_NS = 50,

	// How long MOSI must hold still before the rising edge that samples it.
	//
	// Modelling this is not fussiness either. A master that changed MOSI in the
	// same instant it raised the clock read this flash perfectly in simulation
	// for weeks: Verilog applies both updates before the sampling block runs, so
	// the model always saw the bit that was intended. The silicon saw a line
	// still in motion and latched the old bit OR the new one -- which turns $9F
	// into $DF and $06 into $07. Not corrupted data: DIFFERENT COMMANDS,
	// obeyed exactly. $03 happens to be immune, so reads stayed flawless while
	// nothing could be written.
	//
	// None of that is visible in the data, so the model has to be what notices.
	parameter SETUP_NS = 5
)(
	input  wire cs_n,
	input  wire sclk,
	input  wire mosi,
	output reg  miso
);

	localparam SIZE        = 1 << ADDR_BITS;
	localparam SECTOR_SIZE = 65536;
	localparam PAGE_SIZE   = 256;

	localparam [7:0] OP_WREN = 8'h06, OP_WRDI = 8'h04, OP_RDSR = 8'h05,
	                 OP_READ = 8'h03, OP_PP   = 8'h02, OP_SE   = 8'hD8,
	                 OP_RDID = 8'h9F, OP_RSTEN = 8'h66, OP_RST  = 8'h99;

	// Whether this chip is currently listening in a language we speak, and
	// whether a RESET ENABLE has been seen -- a RESET MEMORY on its own does
	// nothing, exactly as on the real part.
	reg confused;
	reg reset_armed;

	reg [7:0] mem     [0:SIZE-1];
	reg [7:0] progbuf [0:PAGE_SIZE-1];

	reg  wel;                       // the write enable latch
	time busy_until;

	// A function and not a wire. `$time` is not an operand a continuous
	// assignment re-evaluates on, so `wire busy = ($time < busy_until)` latches
	// the answer at the moment busy_until changes and never updates -- the chip
	// would report itself busy forever.
	function is_busy;
		input dummy;
		begin is_busy = ($time < busy_until); end
	endfunction

	integer i;
	initial begin
		for (i = 0; i < SIZE; i = i + 1) mem[i] = 8'hFF;   // erased
		for (i = 0; i < PAGE_SIZE; i = i + 1) progbuf[i] = 8'hFF;
		wel = 1'b0;
		busy_until = 0;
		miso = 1'b0;
		confused = (CONFUSED != 0);
		reset_armed = 1'b0;
	end

	// --- transaction state ----------------------------------------------------
	reg [7:0]  shin, shout;
	reg [2:0]  bitn;
	integer    bytec;               // index of the byte being processed
	reg [7:0]  op;
	reg [23:0] addr;
	reg [23:0] prog_base;
	integer    prog_n;

	// --- what a byte means, given where it landed in the transaction ----------
	task byte_in;
		input [7:0] b;
		begin
			if (bytec == 0) begin
				op = b;
				// The reset pair is understood in any mode -- that is the whole
				// point of it. Everything else, while confused, is not.
				if (b == OP_RSTEN) reset_armed = 1'b1;
				else if (b == OP_RST) begin
					if (reset_armed) confused = 1'b0;
					reset_armed = 1'b0;
				end else reset_armed = 1'b0;

				if (confused) op = 8'h00;       // understood as nothing at all
				case (op)
				OP_WREN: if (!is_busy(0)) wel = 1'b1;
				OP_WRDI: wel = 1'b0;
				OP_RDSR: shout = {6'd0, wel, is_busy(0)};
				OP_RDID: shout = 8'h20;              // Micron
				default: ;
				endcase
			end else case (op)
				OP_RDSR: shout = {6'd0, wel, is_busy(0)};  // repeats as long as asked
				OP_RDID: shout = (bytec == 1) ? 8'hBA : 8'h17;

				OP_READ, OP_PP, OP_SE:
					if (bytec <= 3) begin
						addr = {addr[15:0], b};
						if (bytec == 3) begin
							// The byte after the address is already going out,
							// so the first data byte has to be ready here.
							if (op == OP_READ)
								shout = mem[addr[ADDR_BITS-1:0]];
							if (op == OP_PP) begin
								prog_base = addr;
								prog_n    = 0;
							end
							if (op == OP_SE && wel && !is_busy(0)) begin
								for (i = 0; i < SECTOR_SIZE; i = i + 1)
									mem[((addr & ~(SECTOR_SIZE-1)) + i) & (SIZE-1)]
									  = 8'hFF;
								busy_until = $time + ERASE_NS;
								wel = 1'b0;
							end
						end
					end else begin
						if (op == OP_READ) begin
							addr  = addr + 24'd1;
							shout = mem[addr[ADDR_BITS-1:0]];
						end else if (op == OP_PP && prog_n < PAGE_SIZE) begin
							progbuf[prog_n] = b;
							prog_n = prog_n + 1;
						end
					end
				default: ;
			endcase
		end
	endtask

	// --- the deselect time ------------------------------------------------------
	// A real part needs chip select held high for a while between transactions.
	// Too short and it never registers the new command at all -- it does not
	// complain, it simply does nothing, and the controller sees a chip that is
	// not busy and calls that success.
	time    cs_rose  = 0;
	reg     deaf     = 1'b0;      // this transaction started too soon; ignore it
	integer n_short  = 0;

	always @(posedge cs_n) cs_rose = $time;

	// Everything resets when chip select falls, including a half-finished byte:
	// a real chip keeps no memory of an aborted transaction.
	always @(negedge cs_n) begin
		if (cs_rose != 0 && ($time - cs_rose) < DESELECT_NS) begin
			n_short = n_short + 1;
			deaf    = 1'b1;
			$display("  *** flash: chip select was high for only %0d ns between transactions (needs %0d) -- ignoring this command",
			         $time - cs_rose, DESELECT_NS);
		end else
			deaf = 1'b0;

		bitn   = 3'd0;
		bytec  = 0;
		op     = 8'h00;
		addr   = 24'd0;
		shin   = 8'd0;
		shout  = 8'd0;
		prog_n = 0;
	end

	// The program buffer is applied when chip select RISES, not as the bytes
	// arrive. That is what the part does, and it is not a detail: a controller
	// that never deasserted chip select would otherwise appear to work.
	integer j;
	always @(posedge cs_n) begin
		if (!deaf && op == OP_PP && prog_n > 0 && wel && !is_busy(0)) begin
			for (j = 0; j < prog_n; j = j + 1)
				mem[(prog_base & ~(PAGE_SIZE-1)) |
				    ((prog_base + j) & (PAGE_SIZE-1))]
				  = mem[(prog_base & ~(PAGE_SIZE-1)) |
				        ((prog_base + j) & (PAGE_SIZE-1))] & progbuf[j];
			busy_until = $time + PROGRAM_NS;
			wel = 1'b0;
		end
	end

	// --- shifting -------------------------------------------------------------
	// Mode 0: the master presents a bit while the clock is low, both ends sample
	// on the rising edge, and the slave presents its next bit on the falling one.
	time    mosi_moved = 0;
	integer n_setup    = 0;
	reg     last_bit   = 1'b0;      // what this part latched on the last edge
	reg     got;

	always @(mosi) mosi_moved = $time;

	always @(posedge sclk) if (!cs_n && !deaf) begin
		// A bit that is still moving when the clock arrives is not read as the
		// bit the master meant. Rather than warn and carry on -- which lets a
		// suite go green over a design that cannot talk to the chip at all --
		// this does what the silicon did: latches the old bit OR the new one.
		//
		// Downstream that shows up as commands arriving as OTHER commands, which
		// is what makes the real failure so strange to watch, so the tests
		// should see exactly the same thing.
		got = mosi;
		if (mosi_moved != 0 && ($time - mosi_moved) < SETUP_NS) begin
			n_setup = n_setup + 1;
			if (n_setup <= 4)
				$display("  *** flash: MOSI changed %0d ns before the edge that samples it (needs %0d) -- latching the previous bit OR this one, as a real part would",
				         $time - mosi_moved, SETUP_NS);
			got = last_bit | mosi;
		end
		last_bit = got;
		shin = {shin[6:0], got};
		if (bitn == 3'd7) begin
			byte_in(shin);
			bytec = bytec + 1;
			bitn  = 3'd0;
		end else bitn = bitn + 3'd1;
	end

	always @(negedge sclk) if (!cs_n) begin
		miso  = shout[7];
		shout = {shout[6:0], 1'b0};
	end

endmodule
