//////////////////////////////////////////////////////////////////////////////////
// phy_id.v - find the LAN8720 on the MDIO bus and report its address.
//
// Second rung of the Ethernet ladder, after phy_probe proved the PHY is handing
// us a 50 MHz reference clock. This one proves the management channel works and
// answers a question the module's documentation will not: which of the 32
// possible PHY addresses it strapped itself to. On these breakouts it is usually
// 0 or 1, set by resistors, and nothing on the silkscreen tells you.
//
// The scan runs continuously, so unplugging the module makes led1 go dark and
// plugging it back in brings it straight back.
//
// led0  heartbeat. Blinks whenever the bitstream is loaded.
// led1  dark          -> no PHY answered on any address
//       n blinks, pause, repeat -> found at address (n - 1)
//
// So one blink means PHY address 0, two blinks means address 1, and so on.
//
// Runs off sys_clk, not the PHY's reference clock: MDIO is independent of the
// RMII data path, so this still works even if REF_CLK is unplugged.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module phy_id (
	input  wire sys_clk,        // 50 MHz onboard oscillator, ball U22
	output wire led0,
	output reg  led1,
	output wire eth_mdc,        // U2 pin 52 (Y25)
	inout  wire eth_mdio        // U2 pin 53 (AC24)
);

	localparam [15:0] LAN8720_PHYIDR1 = 16'h0007;  // OUI high bits, Microchip
	localparam [4:0]  REG_PHYIDR1     = 5'd2;

	// --- heartbeat -----------------------------------------------------------
	reg [24:0] hb = 0;
	always @(posedge sys_clk) hb <= hb + 1'b1;
	assign led0 = hb[24];

	// --- 0.05 s tick, for the blink display ----------------------------------
	localparam TICK_CYCLES = 2_500_000;
	reg [21:0] tickdiv = 0;
	wire tick = (tickdiv == TICK_CYCLES - 1);
	always @(posedge sys_clk) tickdiv <= tick ? 22'd0 : tickdiv + 22'd1;

	// --- MDIO master ---------------------------------------------------------
	reg         start = 0;
	reg  [4:0]  addr  = 0;
	wire [15:0] rdata;
	wire        done, busy;

	wire pid_mdio_o, pid_mdio_oe;
	assign eth_mdio = pid_mdio_oe ? pid_mdio_o : 1'bz;

	mdio_master #(.CLK_DIV(32)) u_mdio (
		.clk      (sys_clk),
		.rst      (1'b0),
		.start    (start),
		.we       (1'b0),
		.phy_addr (addr),
		.reg_addr (REG_PHYIDR1),
		.wdata    (16'd0),
		.rdata    (rdata),
		.done     (done),
		.busy     (busy),
		.mdc      (eth_mdc),
		.mdio_o(pid_mdio_o), .mdio_oe(pid_mdio_oe), .mdio_i(eth_mdio)
	);

	// --- scan ----------------------------------------------------------------
	// Sweep all 32 addresses, then publish what the sweep found. Publishing only
	// at the end of a sweep means a PHY that stops answering clears the result
	// instead of leaving a stale one latched forever.
	reg       found       = 0;
	reg [4:0] found_addr  = 0;
	reg       hit_sweep   = 0;
	reg [4:0] hit_addr    = 0;

	always @(posedge sys_clk) begin
		start <= 1'b0;

		if (!busy && !start && !done) begin
			start <= 1'b1;
		end else if (done) begin
			if (rdata == LAN8720_PHYIDR1) begin
				hit_sweep <= 1'b1;
				hit_addr  <= addr;
			end

			if (addr == 5'd31) begin
				found      <= hit_sweep;
				found_addr <= hit_addr;
				hit_sweep  <= 1'b0;
			end
			addr <= addr + 5'd1;
		end
	end

	// --- blink out the address ----------------------------------------------
	localparam ON_TICKS    = 3;    // 150 ms
	localparam OFF_TICKS   = 5;    // 250 ms
	localparam PAUSE_TICKS = 24;   // 1.2 s between repeats

	localparam S_ON = 2'd0, S_OFF = 2'd1, S_PAUSE = 2'd2;

	reg [1:0] bstate  = S_PAUSE;
	reg [5:0] btimer  = 0;
	reg [5:0] bleft   = 0;

	always @(posedge sys_clk) begin
		if (!found) begin
			led1   <= 1'b0;
			bstate <= S_PAUSE;
			btimer <= 0;
			bleft  <= 0;
		end else if (tick) begin
			case (bstate)
				S_ON: begin
					led1 <= 1'b1;
					if (btimer == ON_TICKS - 1) begin
						btimer <= 0;
						bstate <= S_OFF;
					end else btimer <= btimer + 1'b1;
				end

				S_OFF: begin
					led1 <= 1'b0;
					if (btimer == OFF_TICKS - 1) begin
						btimer <= 0;
						if (bleft == 1) bstate <= S_PAUSE;
						else begin
							bleft  <= bleft - 1'b1;
							bstate <= S_ON;
						end
					end else btimer <= btimer + 1'b1;
				end

				default: begin        // S_PAUSE
					led1 <= 1'b0;
					if (btimer == PAUSE_TICKS - 1) begin
						btimer <= 0;
						bleft  <= found_addr + 1'b1;   // address 0 blinks once
						bstate <= S_ON;
					end else btimer <= btimer + 1'b1;
				end
			endcase
		end
	end

endmodule

`default_nettype wire
