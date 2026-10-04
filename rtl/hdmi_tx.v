//////////////////////////////////////////////////////////////////////////////////
// hdmi_tx.v - 640x480 at 60 Hz over TMDS (DVI signalling, which every HDMI display
// takes): the timing, three TMDS encoders and the serialisers.
//
// Timing (VESA DMT, 25.175 MHz nominal; this takes what pclk is, 25.156 MHz from
// the MMCM below is within a monitor's tolerance):
//   horizontal: 640 active, 16 front porch, 96 sync, 48 back porch = 800
//   vertical:   480 active, 10 front porch,  2 sync, 33 back porch = 525
//   both syncs negative.
//
// The source is asked for a pixel a clock ahead: x, y and req (the pixel at x, y is
// wanted on the next clock, in rgb), so a block RAM line buffer can answer it.
//
// Serialising: each 10-bit symbol through an OSERDESE2 master/slave pair in 10:1
// DDR mode, CLKDIV = pclk, CLK = 5 x pclk, bit 0 first; then OBUFDS (the XDC makes
// them TMDS_33). The clocks come from clk50 through one MMCM: VCO 50 x 20.125 =
// 1006.25 MHz, /40 = 25.156 MHz, /8 = 125.78 MHz.
//
// PSEUDO = 1: each wire of a pair is its own single-ended output, + and - driven
// opposite (two serialiser pairs a channel, the second fed the inverted symbols) --
// for a connector whose + and - do not land on a true P/N pair of balls (the QMTECH
// headers pair across their rows; an HDMI breakout puts a pair's + and - in one).
// The XDC makes them LVCMOS33, fast slew.
//
// sym_* are the symbols before the serialisers (for the testbench, and for anything
// that wants to look).
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module hdmi_tx #(
	parameter SIM = 0,                   // 1: no MMCM/serialisers (pclk comes in on sim_pclk)
	parameter PSEUDO = 1,                // 1: single-ended + and - (see above); 0: OBUFDS
	parameter EXT_CLK = 0                // 1: the clocks come in (ext_*), from an MMCM already there
)(
	input  wire        clk50,
	input  wire        rst,
	input  wire        sim_pclk,
	input  wire        ext_pclk,         // (EXT_CLK) the pixel clock, 5 x it, and their MMCM's lock
	input  wire        ext_pclk5,
	input  wire        ext_locked,
	output wire        pclk,             // the pixel clock, for the source's read side
	// the source: the pixel at (x, y) next clock, while req
	output reg  [9:0]  x,
	output reg  [9:0]  y,
	output reg         req,
	input  wire [23:0] rgb,              // {r, g, b}
	output wire        frame_start,      // a clock at the start of each frame (y wraps to 0)
	// TMDS out: [2:0] = data channels 2 (red), 1 (green), 0 (blue)
	output wire [2:0]  tmds_p,
	output wire [2:0]  tmds_n,
	output wire        tmds_clk_p,
	output wire        tmds_clk_n,
	output wire [9:0]  sym_0, sym_1, sym_2
);
	localparam H_ACT = 640, H_FP = 16, H_SYNC = 96, H_BP = 48, H_TOT = 800;
	localparam V_ACT = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33, V_TOT = 525;

	// --- clocks --------------------------------------------------------------------
	wire pclk5, locked;
	generate if (SIM) begin : g_simclk
		assign pclk = sim_pclk; assign pclk5 = 1'b0; assign locked = 1'b1;
	end else if (EXT_CLK) begin : g_ext
		assign pclk = ext_pclk; assign pclk5 = ext_pclk5; assign locked = ext_locked;
	end else begin : g_mmcm
		wire fb, c0, c1;
		MMCME2_BASE #(
			.CLKIN1_PERIOD(20.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(20.125),
			.CLKOUT0_DIVIDE_F(40.0), .CLKOUT1_DIVIDE(8)
		) u_mmcm (
			.CLKIN1(clk50), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(c0), .CLKOUT1(c1),
			.LOCKED(locked), .PWRDWN(1'b0), .RST(rst),
			.CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
			.CLKOUT4(), .CLKOUT5(), .CLKOUT6()
		);
		BUFG u_bp (.I(c0), .O(pclk));
		BUFG u_b5 (.I(c1), .O(pclk5));
	end endgenerate
	// reset, held until the MMCM locks, in the pixel clock's domain
	reg [3:0] prst = 4'hF;
	always @(posedge pclk or negedge locked)
		if (!locked) prst <= 4'hF; else prst <= {prst[2:0], 1'b0};
	wire pr = prst[3];

	// --- timing ------------------------------------------------------------------------
	reg  [9:0] hc, vc;
	always @(posedge pclk) begin
		if (pr) begin hc <= 10'd0; vc <= 10'd0; end
		else if (hc == H_TOT - 1) begin
			hc <= 10'd0;
			vc <= (vc == V_TOT - 1) ? 10'd0 : vc + 10'd1;
		end else hc <= hc + 10'd1;
	end
	assign frame_start = !pr && hc == 10'd0 && vc == 10'd0;
	// the request runs a clock ahead of the symbols' de
	always @(posedge pclk) begin
		req <= !pr && hc < H_ACT && vc < V_ACT;
		x <= hc; y <= vc;
	end
	reg de, hs, vs;
	always @(posedge pclk) begin
		de <= req;
		hs <= !(hc >= H_ACT + H_FP + 1 && hc < H_ACT + H_FP + H_SYNC + 1);     // (a clock behind hc, as req)
		vs <= !(vc >= V_ACT + V_FP && vc < V_ACT + V_FP + V_SYNC);
	end

	// --- encoders: blue with the syncs on channel 0 ------------------------------------
	hdmi_tmds u_e0 (.clk(pclk), .de(de), .d(rgb[7:0]),   .c0(hs),   .c1(vs),   .q(sym_0));
	hdmi_tmds u_e1 (.clk(pclk), .de(de), .d(rgb[15:8]),  .c0(1'b0), .c1(1'b0), .q(sym_1));
	hdmi_tmds u_e2 (.clk(pclk), .de(de), .d(rgb[23:16]), .c0(1'b0), .c1(1'b0), .q(sym_2));

	// --- serialisers -----------------------------------------------------------------
	generate if (!SIM && PSEUDO) begin : g_ser
		// Single-ended: a 10:1 OSERDESE2 is two cascaded, the second in the OLOGIC of the
		// ball's differential partner -- here another HDMI pin, so the cascades collide.
		// Instead each pin has an ODDR (in its own OLOGIC) fed two bits a 5x clock from a
		// 10-bit shift register, loaded with the symbol once a pixel clock (the pixel
		// clock's toggle, seen from the 5x clock, says when: they come from one MMCM).
		wire [9:0] syms [0:3];
		assign syms[0] = sym_0; assign syms[1] = sym_1; assign syms[2] = sym_2;
		assign syms[3] = 10'b0000011111;                // the clock channel: one pixel clock period
		reg  ptog = 1'b0;
		always @(posedge pclk) ptog <= ~ptog;
		reg  [2:0] t5;                                   // ptog as the 5x clock saw it, three clocks
		always @(posedge pclk5) t5 <= {t5[1:0], ptog};
		wire load = t5[2] != t5[1];
		genvar ch, pol;
		for (ch = 0; ch < 4; ch = ch + 1) begin : g_ch
		for (pol = 0; pol < 2; pol = pol + 1) begin : g_pol
			reg  [9:0] sh;
			always @(posedge pclk5) sh <= load ? (pol ? ~syms[ch] : syms[ch]) : {2'b00, sh[9:2]};
			wire ser;
			ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr (
				.Q(ser), .C(pclk5), .CE(1'b1), .D1(sh[0]), .D2(sh[1]), .R(1'b0), .S(1'b0));
			if (ch < 3 && pol == 0) begin : g_dp OBUF u_ob (.I(ser), .O(tmds_p[ch])); end
			if (ch < 3 && pol == 1) begin : g_dn OBUF u_ob (.I(ser), .O(tmds_n[ch])); end
			if (ch == 3 && pol == 0) begin : g_cp OBUF u_ob (.I(ser), .O(tmds_clk_p)); end
			if (ch == 3 && pol == 1) begin : g_cn OBUF u_ob (.I(ser), .O(tmds_clk_n)); end
		end
		end
	end else if (!SIM) begin : g_ser
		wire [9:0] syms [0:3];
		assign syms[0] = sym_0; assign syms[1] = sym_1; assign syms[2] = sym_2;
		assign syms[3] = 10'b0000011111;                // the clock channel: one pixel clock period
		genvar ch, pol;
		for (ch = 0; ch < 4; ch = ch + 1) begin : g_ch
		for (pol = 0; pol < (PSEUDO ? 2 : 1); pol = pol + 1) begin : g_pol
			wire s1, s2, ser;
			wire [9:0] sy = pol ? ~syms[ch] : syms[ch];
			OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10), .SERDES_MODE("MASTER"),
			            .TRISTATE_WIDTH(1)) u_m (
				.OQ(ser), .OFB(), .TQ(), .TFB(), .SHIFTOUT1(), .SHIFTOUT2(), .TBYTEOUT(),
				.CLK(pclk5), .CLKDIV(pclk),
				.D1(sy[0]), .D2(sy[1]), .D3(sy[2]), .D4(sy[3]),
				.D5(sy[4]), .D6(sy[5]), .D7(sy[6]), .D8(sy[7]),
				.OCE(1'b1), .RST(pr), .SHIFTIN1(s1), .SHIFTIN2(s2),
				.T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
			);
			OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10), .SERDES_MODE("SLAVE"),
			            .TRISTATE_WIDTH(1)) u_s (
				.OQ(), .OFB(), .TQ(), .TFB(), .SHIFTOUT1(s1), .SHIFTOUT2(s2), .TBYTEOUT(),
				.CLK(pclk5), .CLKDIV(pclk),
				.D1(1'b0), .D2(1'b0), .D3(sy[8]), .D4(sy[9]),
				.D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
				.OCE(1'b1), .RST(pr), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
				.T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
			);
			if (PSEUDO) begin : g_se
				if (ch < 3 && pol == 0) begin : g_dp OBUF u_ob (.I(ser), .O(tmds_p[ch])); end
				if (ch < 3 && pol == 1) begin : g_dn OBUF u_ob (.I(ser), .O(tmds_n[ch])); end
				if (ch == 3 && pol == 0) begin : g_cp OBUF u_ob (.I(ser), .O(tmds_clk_p)); end
				if (ch == 3 && pol == 1) begin : g_cn OBUF u_ob (.I(ser), .O(tmds_clk_n)); end
			end else begin : g_df
				if (ch < 3) begin : g_d
					OBUFDS u_ob (.I(ser), .O(tmds_p[ch]), .OB(tmds_n[ch]));
				end else begin : g_c
					OBUFDS u_ob (.I(ser), .O(tmds_clk_p), .OB(tmds_clk_n));
				end
			end
		end
		end
	end else begin : g_noser
		assign tmds_p = 3'b000; assign tmds_n = 3'b111; assign tmds_clk_p = 1'b0; assign tmds_clk_n = 1'b1;
	end endgenerate
endmodule

`default_nettype wire
