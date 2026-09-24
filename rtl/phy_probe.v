//////////////////////////////////////////////////////////////////////////////////
// phy_probe.v - does the LAN8720 module give us a 50 MHz RMII reference clock?
//
// This is the one question that has to be answered before any Ethernet RTL is
// worth writing, because it decides which way REF_CLK flows:
//
//   REF_CLK Out mode - the module's own 25 MHz crystal feeds the PHY, the PHY
//                      generates 50 MHz and drives it OUT on nINT/REFCLK. The
//                      FPGA takes it as an input and clocks its RMII logic from
//                      it. This is the easy case: no module modification, and no
//                      round-trip skew to think about.
//
//   REF_CLK In mode  - the PHY expects 50 MHz driven IN. The FPGA must source it.
//                      Needs the module's clock strapping changed.
//
// So: park eth_refclk as an INPUT and see whether anything arrives. Never drive
// this pin until you know the answer -- if the module is in REF_CLK Out mode and
// the FPGA drives the same net, two outputs fight each other.
//
// led0  heartbeat off the onboard oscillator. Blinks whenever the bitstream is
//       loaded at all, whatever the PHY is doing. The control.
// led1  the same divider clocked by whatever arrives on REF_CLK.
//
//   both blinking, same rate  -> REF_CLK present at ~50 MHz. REF_CLK Out mode.
//   led0 only, led1 dark      -> no clock. Module is not driving it.
//   led1 flickering randomly  -> floating pin picking up noise, not a clock.
//
// Because the two dividers are the same width and both nominally 50 MHz, they
// blink at the same rate but drift slowly out of phase. That drift is itself the
// measurement: fast drift means the PHY clock is off frequency.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module phy_probe (
	input  wire sys_clk,     // 50 MHz onboard oscillator, ball U22
	input  wire eth_refclk,  // RMII REF_CLK from the LAN8720, U2 pin 56 (W21)
	output wire led0,        // heartbeat  - onboard clock
	output wire led1         // under test - PHY clock
);

	// 2^24 cycles at 50 MHz = 336 ms per half period, so ~1.5 Hz. Slow enough
	// to count by eye, fast enough that a dead clock is obvious immediately.
	localparam BIT = 24;

	reg [BIT:0] sys_cnt = 0;
	always @(posedge sys_clk) sys_cnt <= sys_cnt + 1'b1;
	assign led0 = sys_cnt[BIT];

	// REF_CLK arrives on an SRCC pin, so it can reach a BUFG and drive real
	// logic. If nothing is driving the pin the constraint file's pull-down holds
	// it low and this counter simply never advances.
	wire refclk;
	BUFG bufg_refclk (.I(eth_refclk), .O(refclk));

	reg [BIT:0] ref_cnt = 0;
	always @(posedge refclk) ref_cnt <= ref_cnt + 1'b1;
	assign led1 = ref_cnt[BIT];

endmodule

`default_nettype wire
