//////////////////////////////////////////////////////////////////////////////////
// a26_riot.v - the 6532 RAM-I/O-Timer as the Atari 2600 wires it.
//
// From the 6532 datasheet. The console uses all three parts: the 128 bytes are the
// whole of its RAM, port A reads the two joysticks, port B the console switches,
// and the timer is how every kernel knows when vertical blank and overscan end.
//
// Address decode is the console's, not a general one: RS (RAM select) is A9 and
// the chip select is A7 high with A12 low, so RAM answers at $80-$FF and the I/O
// registers at $280-$29F (both with mirrors). Inside the I/O space A2 picks the
// timer over the ports; on a write A4 picks the timer over the edge-detect
// control, A1:A0 the interval and A3 whether the timer may interrupt (it cannot
// reach anything here -- the 6507 has no IRQ pin).
//
// The timer, as the datasheet's worked example has it (52 written at /8: the
// count reads 51 on the next cycle, "52-26-1 = 25" 213 cycles on, 0 at 415, and
// the interrupt at 416 -- "(52 x 8) + 1 = 417T" including the write): the count
// steps once on the cycle after the write and then once an interval, so a read p
// cycles after the write sees N - 1 - floor(p / interval). Stepping through zero
// reads $FF and sets the flag (TIMINT bit 7); from then on the count drops one a
// cycle, so a late reader can tell how late it is. Reading or writing the timer
// clears the flag -- except a read in the very cycle the flag sets, which the
// datasheet says does not.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module a26_riot (
	input  wire        clk,
	input  wire        rst,
	input  wire        cpu_ce,     // the processor's cycle edge; the timer counts these

	input  wire        ram_sel,    // A12 low, A7 high, A9 low
	input  wire        io_sel,     // A12 low, A7 high, A9 high
	input  wire [6:0]  addr,
	input  wire        we,
	input  wire [7:0]  din,
	output wire [7:0]  dout,

	// the port pins as the console drives them (switches are active low)
	input  wire [7:0]  pa_in,
	input  wire [7:0]  pb_in
);

	// --- RAM ------------------------------------------------------------------
	reg [7:0] ram [0:127];
	integer i;
	// Block RAM powers up zeroed on this part; an initial block is how both the
	// synthesiser and the simulator spell that. (The real console's RAM holds
	// garbage at power-up, which is why every game clears it first.)
	initial for (i = 0; i < 128; i = i + 1) ram[i] = 8'd0;

	reg [7:0] ram_q;
	always @(posedge clk) begin
		if (cpu_ce && ram_sel && we) ram[addr] <= din;
		ram_q <= ram[addr];
	end

	// --- ports ----------------------------------------------------------------------
	// A pin set as an output reads back its output register; an input reads the pin.
	reg [7:0] ora, ddra, orb, ddrb;
	wire [7:0] pa = (pa_in & ~ddra) | (ora & ddra);
	wire [7:0] pb = (pb_in & ~ddrb) | (orb & ddrb);

	// --- timer -------------------------------------------------------------------------
	reg [7:0]  intim;
	reg [1:0]  interval;           // 0: 1T  1: 8T  2: 64T  3: 1024T
	reg [9:0]  prescale;
	reg        tim_flag;           // TIMINT bit 7
	reg        underflowed;        // counting one a cycle now
	reg        irq_en;
	reg        pa7_flag, pa7_pos, pa7_prev;

	reg [9:0] period_m1;
	always @* begin
		case (interval)
		2'd0: period_m1 = 10'd0;
		2'd1: period_m1 = 10'd7;
		2'd2: period_m1 = 10'd63;
		default: period_m1 = 10'd1023;
		endcase
	end
	wire step = underflowed || (interval == 2'd0) || (prescale == period_m1);

	wire io_wr = cpu_ce && io_sel && we;
	wire io_rd = cpu_ce && io_sel && !we;

	always @(posedge clk) begin
		if (rst) begin
			ora <= 8'd0; ddra <= 8'd0; orb <= 8'd0; ddrb <= 8'd0;
			intim <= 8'd0; interval <= 2'd0; prescale <= 10'd0;
			tim_flag <= 1'b0; underflowed <= 1'b1; irq_en <= 1'b0;
			pa7_flag <= 1'b0; pa7_pos <= 1'b0; pa7_prev <= 1'b0;
		end else begin
			// a read clears the flag; written first so that the flag setting in the
			// same cycle, below, wins
			if (io_rd && addr[2]) begin
				if (!addr[0]) tim_flag <= 1'b0;   // INTIM
				else          pa7_flag <= 1'b0;   // TIMINT
			end

			if (cpu_ce) begin
				// the countdown
				if (step) begin
					prescale <= 10'd0;
					intim    <= intim - 8'd1;
					if (intim == 8'd0 && !underflowed) begin
						tim_flag    <= 1'b1;
						underflowed <= 1'b1;
					end
				end else
					prescale <= prescale + 10'd1;

				// PA7 edge detect (the flag only; nothing is wired to be interrupted)
				pa7_prev <= pa[7];
				if (pa7_pos ? (pa[7] && !pa7_prev) : (!pa[7] && pa7_prev)) pa7_flag <= 1'b1;
			end

			if (io_wr) begin
				if (!addr[2]) begin
					case (addr[1:0])
					2'd0: ora  <= din;
					2'd1: ddra <= din;
					2'd2: orb  <= din;
					default: ddrb <= din;
					endcase
				end else if (addr[4]) begin
					// A timer write. The count goes in already stepped once (N - 1 is
					// what the next cycle reads), and the prescaler starts at 1 so the
					// next step lands `interval` cycles after that first one.
					intim       <= din - 8'd1;
					interval    <= addr[1:0];
					irq_en      <= addr[3];
					prescale    <= 10'd1;
					tim_flag    <= 1'b0;
					underflowed <= 1'b0;
				end else begin
					pa7_pos <= addr[0];
					irq_en  <= irq_en;        // A1 enables the PA7 interrupt; nothing to drive
				end
			end

		end
	end

	// --- read mux ---------------------------------------------------------------------------
	reg [7:0] io_q;
	always @* begin
		if (!addr[2]) begin
			case (addr[1:0])
			2'd0: io_q = pa;
			2'd1: io_q = ddra;
			2'd2: io_q = pb;
			default: io_q = ddrb;
			endcase
		end else if (!addr[0])
			io_q = intim;
		else
			io_q = {tim_flag, pa7_flag, 6'd0};
	end

	assign dout = ram_sel ? ram_q : io_q;

endmodule
