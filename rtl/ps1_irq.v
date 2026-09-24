//////////////////////////////////////////////////////////////////////////////////
// ps1_irq.v - the PlayStation's interrupt controller: two registers.
//
//   $1F801070  I_STAT   which sources have fired. A source SETS its bit on a
//                       rising edge; software CLEARS bits by writing zeros to
//                       them (a write ANDs), so acknowledging one leaves the
//                       rest alone.
//   $1F801074  I_MASK   which of them reach the CPU.
//
// The CPU sees one line -- IP2, its first external interrupt -- high while any
// masked source is set. Eleven sources, in the order the console numbers them:
//
//   0 VBLANK  1 GPU  2 CDROM  3 DMA  4 TMR0  5 TMR1  6 TMR2
//   7 controller and memory card  8 SIO  9 SPU  10 PIO (lightgun)
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_irq (
	input  wire        clk,
	input  wire        rst,

	input  wire [10:0] src,         // level from each device; edges are taken here

	// the register bus, already decoded to this block
	input  wire        sel,         // an access is happening
	input  wire        we,
	input  wire [3:0]  a,           // low address bits: 0 = I_STAT, 4 = I_MASK
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,

	output wire        irq          // to the CPU
);
	reg [10:0] stat, mask, src_d;

	assign irq = |(stat & mask);

	always @(posedge clk) begin
		if (rst) begin
			stat <= 11'd0; mask <= 11'd0; src_d <= 11'd0;
		end else begin
			src_d <= src;
			// a write to I_STAT acknowledges; a rising edge in the same cycle wins,
			// so an interrupt that fires while being acknowledged is not lost
			if (sel && we && a[3:2] == 2'd0)
				stat <= (stat & wdata[10:0]) | (src & ~src_d);
			else
				stat <= stat | (src & ~src_d);
			if (sel && we && a[3:2] == 2'd1)
				mask <= wdata[10:0];
		end
	end

	always @(*) begin
		case (a[3:2])
		2'd0:    rdata = {21'd0, stat};
		2'd1:    rdata = {21'd0, mask};
		default: rdata = 32'd0;
		endcase
	end
endmodule

`default_nettype wire
