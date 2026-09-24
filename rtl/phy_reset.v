//////////////////////////////////////////////////////////////////////////////////
// phy_reset.v - hold the LAN8720's hand at power-up, from a clock it does not own.
//
// Nothing on this board resets the PHY. Its nRST is not wired to the FPGA and
// there is no pin for it in the constraints, so across an FPGA reconfiguration
// the PHY keeps whatever state it was in -- and reconfiguring drops every pin
// for a moment, RMII included. It can come out of that with its link state
// machine stuck: ARP sometimes answers, fpgalink never does, and the only thing
// that has ever cleared it is unplugging the barrel jack.
//
// BMCR bit 15 is a soft reset and MDIO reaches it without any extra wiring, so
// the board can do for itself what the missing pin would have done.
//
// The clock is the point. The obvious place for this was beside the register
// file's existing MDIO master -- and that runs on eth_refclk, which the LAN8720
// generates. A reset that depends on the chip it is resetting cannot rescue it:
// if the PHY stops clocking, the logic that would fix it stops with it. So this
// runs on sys_clk, the 50 MHz oscillator on the board, which is there whatever
// the PHY is doing.
//
// It owns the MDIO pins until `done`, then the host's master has them.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module phy_reset #(
	parameter [4:0]  PHY_ADDR = 5'd1,        // strapped on the module
	parameter [19:0] SETTLE   = 20'd500_000  // 10 ms at 50 MHz
)(
	input  wire        clk,                  // sys_clk: NOT the PHY's
	input  wire        rst,

	output wire        mdc,
	output wire        mdio_o,
	output wire        mdio_oe,
	input  wire        mdio_i,

	output wire        done
);
	localparam BMCR     = 5'd0;
	localparam BMCR_RST = 16'h8000;

	reg [1:0]  st = 2'd0;
	reg [19:0] wait_ct = 20'd0;
	reg        start = 1'b0;
	wire       busy;

	assign done = (st == 2'd3);

	mdio_master #(.CLK_DIV(32)) u_m (
		.clk(clk), .rst(rst),
		.start(start), .we(1'b1),
		.phy_addr(PHY_ADDR), .reg_addr(BMCR),
		.wdata(BMCR_RST), .rdata(), .done(), .busy(busy),
		.mdc(mdc), .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(mdio_i)
	);

	always @(posedge clk) begin
		start <= 1'b0;
		if (rst) begin
			st <= 2'd0; wait_ct <= 20'd0;
		end else case (st)
			2'd0: if (!busy) begin start <= 1'b1; st <= 2'd1; end
			2'd1: if (busy)  st <= 2'd2;              // it has taken it
			2'd2: if (!busy) begin
					// The chip needs its settling time before anything else
					// speaks to it, and the link needs far longer than that to
					// negotiate -- but nothing here has to wait for the link.
					if (wait_ct == SETTLE) st <= 2'd3;
					else wait_ct <= wait_ct + 20'd1;
				end
			default: ;
		endcase
	end
endmodule

`default_nettype wire
