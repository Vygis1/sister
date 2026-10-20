//////////////////////////////////////////////////////////////////////////////////
// hdmi_clk.v - the 640 x 480 pixel clock and its 5x for the serialisers, from the board's
// 50 MHz: 25.2 MHz and 126 MHz.
//
// 640 x 480 is 25.175 MHz. Until 2026-10-16 the pixel clock was the memory controller's
// MMCM divided by 40 -- 25.000 MHz, 0.7% low, outside the 0.5% CEA-861 allows a source,
// 59.52 Hz frames. 25.2 MHz is 0.1% high (60.000 Hz exactly) and divides both audio
// rates: 25.2 MHz / 48 kHz = 525 and / 44.1 kHz = 4000 / 7, so the samples pushed into the
// data islands and the Audio Clock Regeneration the sink rebuilds its clock from agree
// exactly (hdmi_tx: A_TOP, CTS 25200 and 31500).
//
// MMCM: 50 MHz / 5 x 63 = 630 MHz in the VCO (its floor is 600), /25 = 25.2, /5 = 126. The
// phase detector runs at 10 MHz, the MMCM's minimum: allowed, more jitter than a faster
// one, nothing a 252 Mb/s link notices. The N64 keeps its own 25.125 MHz MMCM (eth_top):
// its picture runs at the N64's rate.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module hdmi_clk (
	input  wire sys_clk,           // the board's 50 MHz
	output wire pclk_raw,          // 25.2 MHz, for a BUFG
	output wire pclk5_raw,         // 126 MHz, for a BUFG
	output wire locked
);
	wire fb;
	MMCME2_BASE #(
		.CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(63.0), .DIVCLK_DIVIDE(5),
		.CLKOUT0_DIVIDE_F(25.0), .CLKOUT1_DIVIDE(5)
	) u_mmcm (
		.CLKIN1(sys_clk), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(pclk_raw), .CLKOUT1(pclk5_raw), .LOCKED(locked),
		.RST(1'b0), .PWRDWN(1'b0), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
		.CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB());
endmodule

`default_nettype wire
