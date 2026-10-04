//////////////////////////////////////////////////////////////////////////////////
// hdmi_test_top.v - HDMI alone, for bringing the link up: 640x480 colour bars, a
// white border on the picture's edge and a square moving across, on the HDMI
// breakout on header U4 (as eth_top). Builds in minutes, where a core takes most
// of an hour.
//
//   ./tools/vivado.sh build -top hdmi_test_top -xdc boards/qmtech_a100t/hdmi_test.xdc
//   ./tools/vivado.sh prog build/hdmi_test_top/hdmi_test_top.bit
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module hdmi_test_top #(
	parameter AUD = 0,                    // (bring-up) HDMI mode with data islands
	parameter NULLPK = 0,                 // (bring-up) and all its packets null
	parameter PKMASK = 15,                // (bring-up) which packets (see hdmi_tx)
	parameter TONE = 0                    // (bring-up) a 440 Hz square wave as the sound, 48 kHz
)(
	input  wire        sys_clk,          // 50 MHz
	output wire [2:0]  hdmi_d_p,
	output wire [2:0]  hdmi_d_n,
	output wire        hdmi_ck_p,
	output wire        hdmi_ck_n,
	output wire [10:0] hdmi_lo,
	output wire        hdmi_5v,
	output wire        led0
);
	assign hdmi_lo = 11'd0;
	assign hdmi_5v = 1'b1;

	// the clocks as eth_top makes them: VCO 1000 MHz, /40 = 25 MHz, /8 = 125 MHz
	wire fb, p_raw, p5_raw, pclk, pclk5, locked;
	MMCME2_BASE #(.CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
	              .CLKOUT0_DIVIDE_F(40.0), .CLKOUT1_DIVIDE(8)) u_mmcm (
		.CLKIN1(sys_clk), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(p_raw), .CLKOUT1(p5_raw), .LOCKED(locked),
		.RST(1'b0), .PWRDWN(1'b0), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
		.CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB());
	BUFG u_b0 (.I(p_raw), .O(pclk));
	BUFG u_b1 (.I(p5_raw), .O(pclk5));

	wire [9:0] x, y; wire req, fs;
	reg  [23:0] rgb;
	hdmi_tx #(.SIM(0), .PSEUDO(1), .EXT_CLK(1), .AUDIO(AUD), .NULLPK(NULLPK), .PKMASK(PKMASK)) u_tx (
		.clk50(1'b0), .rst(1'b0), .sim_pclk(1'b0), .ext_pclk(pclk), .ext_pclk5(pclk5), .ext_locked(locked),
		.pclk(), .x(x), .y(y), .req(req), .rgb(rgb), .frame_start(fs),
		.tmds_p(hdmi_d_p), .tmds_n(hdmi_d_n), .tmds_clk_p(hdmi_ck_p), .tmds_clk_n(hdmi_ck_n),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(tone), .aud_r(tone), .aud_tog(ttog));
	// the tone: 48000 samples a second from the 50 MHz clock, a square wave of 440 Hz
	reg [25:0] t48 = 26'd0; reg ttog = 1'b0; reg [15:0] tone = 16'd0; reg [6:0] tph = 7'd0;
	always @(posedge sys_clk) if (TONE) begin
		if (t48 + 26'd48_000 >= 26'd50_000_000) begin
			t48 <= t48 + 26'd48_000 - 26'd50_000_000; ttog <= ~ttog;
			tph <= (tph == 7'd108) ? 7'd0 : tph + 7'd1;               // 48000 / 109 = 440 Hz
			tone <= (tph < 7'd55) ? 16'd6000 : -16'd6000;
		end else t48 <= t48 + 26'd48_000;
	end

	// the picture: eight bars (white, yellow, cyan, green, magenta, red, blue, black),
	// a white border, a square moving across the lower half
	reg [9:0] bx = 10'd0; reg [8:0] by = 9'd300; reg dx = 1'b1;
	always @(posedge pclk) if (fs) begin
		if (dx) begin if (bx >= 10'd590) dx <= 1'b0; else bx <= bx + 10'd3; end
		else    begin if (bx <= 10'd3)   dx <= 1'b1; else bx <= bx - 10'd3; end
	end
	wire [2:0] bar = x[9:7] + {x[9:7] == 3'd4 ? 3'd0 : 3'd0};      // 0..4 across 640 (5 bars of 128)
	wire [2:0] b8 = (x < 10'd80) ? 3'd0 : (x < 10'd160) ? 3'd1 : (x < 10'd240) ? 3'd2 : (x < 10'd320) ? 3'd3
	              : (x < 10'd400) ? 3'd4 : (x < 10'd480) ? 3'd5 : (x < 10'd560) ? 3'd6 : 3'd7;
	always @(posedge pclk) begin
		if (x == 10'd0 || x == 10'd639 || y == 10'd0 || y == 10'd479) rgb <= 24'hFFFFFF;
		else if (x >= bx && x < bx + 10'd48 && y >= {1'b0, by} && y < {1'b0, by} + 10'd48) rgb <= 24'hFFFFFF;
		else if (y < 10'd240) case (b8)
			3'd0: rgb <= 24'hC0C0C0; 3'd1: rgb <= 24'hC0C000; 3'd2: rgb <= 24'h00C0C0; 3'd3: rgb <= 24'h00C000;
			3'd4: rgb <= 24'hC000C0; 3'd5: rgb <= 24'hC00000; 3'd6: rgb <= 24'h0000C0; default: rgb <= 24'h000000;
		endcase
		else rgb <= {x[7:0], y[7:0], 8'h40};                                   // a gradient below
	end
	reg [24:0] blink; always @(posedge pclk) blink <= blink + 25'd1;
	assign led0 = blink[24];
endmodule

`default_nettype wire
