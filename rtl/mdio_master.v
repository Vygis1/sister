//////////////////////////////////////////////////////////////////////////////////
// mdio_master.v - IEEE 802.3 clause 22 management interface master.
//
// MDIO is the PHY's control channel: two wires, independent of the RMII data
// path, running at a leisurely couple of MHz. Through it you can read the PHY's
// identity, link state, speed and duplex, and write its control registers.
//
// This is deliberately generic and has no LAN8720 in it. It is written to be
// reused: the same module later sits behind the fpgalink register bus so the web
// UI can poke PHY registers directly.
//
// Frame format, MSB first, after 32 bits of preamble:
//
//   ST(2) OP(2) PHYAD(5) REGAD(5) TA(2) DATA(16)
//   01    10=rd
//         01=wr
//
// On a read the master releases MDIO for the turnaround and the PHY drives the
// data. The master drives on the MDC falling edge and samples on the rising
// edge, which is what the PHY expects.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module mdio_master #(
	parameter CLK_DIV = 32          // MDC = clk / CLK_DIV. 50 MHz / 32 = 1.56 MHz,
)(                                  // comfortably under the 2.5 MHz ceiling.
	input  wire        clk,
	input  wire        rst,

	input  wire        start,        // pulse to begin a transaction
	input  wire        we,           // 1 = write, 0 = read
	input  wire [4:0]  phy_addr,
	input  wire [4:0]  reg_addr,
	input  wire [15:0] wdata,
	output reg  [15:0] rdata,
	output reg         done,         // one-cycle pulse when rdata is valid
	output wire        busy,

	output reg         mdc,

	// The pad is not driven here. Two masters share this bus -- the host's, in
	// the PHY's own clock domain, and the one that resets the PHY at power-up,
	// which cannot be in that domain because it is the PHY that supplies it. So
	// the tristate lives at the top level, where the two can be muxed.
	output wire        mdio_o,
	output wire        mdio_oe,
	input  wire        mdio_i
);

	localparam HALF = CLK_DIV / 2;

	// --- MDC generation ------------------------------------------------------
	reg [15:0] divcnt;
	wire tick = (divcnt == HALF - 1);
	always @(posedge clk) divcnt <= (rst || tick) ? 16'd0 : divcnt + 16'd1;

	// --- transaction state ---------------------------------------------------
	reg        running;
	reg [6:0]  bitcnt;               // 63..32 preamble, 31..0 frame
	reg [31:0] frame;
	reg        rd;                   // latched direction for this transaction

	assign busy = running;

	// --- MDIO drive ----------------------------------------------------------
	// Preamble and the driven part of the frame come from the master. On a read
	// everything from the turnaround down is the PHY's to drive, so let go.
	reg  mdio_out, mdio_oe_r;
	wire mdio_in = mdio_i;
	assign mdio_o  = mdio_out;
	assign mdio_oe = mdio_oe_r;

	always @* begin
		if (!running) begin
			mdio_oe_r = 1'b0;
			mdio_out  = 1'b0;
		end else if (bitcnt >= 7'd32) begin
			mdio_oe_r = 1'b1;         // preamble: 32 ones
			mdio_out  = 1'b1;
		end else if (rd && bitcnt <= 7'd17) begin
			mdio_oe_r = 1'b0;         // turnaround + data belong to the PHY
			mdio_out  = 1'b0;
		end else begin
			mdio_oe_r = 1'b1;
			mdio_out  = frame[bitcnt[4:0]];
		end
	end

	always @(posedge clk) begin
		done <= 1'b0;

		if (rst) begin
			running <= 1'b0;
			mdc     <= 1'b0;
			bitcnt  <= 7'd0;
			rdata   <= 16'd0;
		end else if (!running) begin
			mdc <= 1'b0;
			if (start) begin
				rd      <= ~we;
				// TA is 10 on a write; on a read these bits are not driven, so
				// the value here is don't-care and just keeps the field aligned.
				frame   <= {2'b01, we ? 2'b01 : 2'b10, phy_addr, reg_addr, 2'b10, wdata};
				bitcnt  <= 7'd63;
				running <= 1'b1;
			end
		end else if (tick) begin
			mdc <= ~mdc;

			// Everything happens on the FALLING edge of MDC, and nothing on the
			// rising edge. This is not arbitrary:
			//
			//   Our output. mdio_out is combinational from bitcnt, so advancing
			//   bitcnt is what changes the wire. Do that on the rising edge and
			//   the data moves at the very instant the PHY samples it -- a
			//   setup violation that mostly works, which is the worst kind. On
			//   the falling edge the new bit gets a full half period to settle.
			//
			//   Their output. The PHY drives its read data on the rising edge,
			//   so by the following falling edge it is stable. Sampling there
			//   rather than on the rising edge buys half a period of margin
			//   instead of racing it.
			if (mdc) begin
				// The data window is bitcnt 16 down to 1, not 15 down to 0.
				// Clause 22 allows the PHY to start driving during the FIRST
				// turnaround bit time rather than the second, and this one does:
				// sampling 15..0 captures DATA[14:0] plus one idle bit after the
				// PHY lets go, which reads back as (value << 1) | 1 -- stable,
				// plausible, and wrong. Confirmed against known register values.
				if (rd && bitcnt <= 7'd16 && bitcnt != 7'd0)
					rdata <= {rdata[14:0], mdio_in};

				if (bitcnt == 7'd0) begin
					running <= 1'b0;
					done    <= 1'b1;
				end else begin
					bitcnt <= bitcnt - 7'd1;
				end
			end
		end
	end

endmodule

`default_nettype wire
