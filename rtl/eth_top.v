//////////////////////////////////////////////////////////////////////////////////
// eth_top.v - the Ethernet endpoint, wired to real pins.
//
// Everything of consequence runs in the PHY's REF_CLK domain. That is a
// deliberate choice: the RMII receiver, transmitter, packet engine and register
// file all share one clock, so there is not a single clock-domain crossing in
// the data path to get subtly wrong. The board's own oscillator drives only a
// heartbeat LED, which doubles as the way to tell "bitstream dead" apart from
// "PHY clock dead".
//
// led0  heartbeat off the board oscillator - always blinks if configured
// led1  network activity - flashes on every frame we accept or answer
//
// If led0 blinks and led1 never does, the board is alive but nothing addressed
// to us is arriving. If neither blinks, configuration failed. If led1 is solid,
// something is wrong with the activity stretcher, not the network.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module eth_top #(
	// Which console this image is. Set from the build -- tools/core.sh makes one
	// image per machine -- so that a core in a flash slot has the whole chip to
	// itself. Both at once is for development over JTAG.
	parameter CORE_NES = 1,
	parameter CORE_SMS = 1,
	parameter CORE_MD  = 0,
	// The Mega Drive's cartridge in DDR3 rather than block RAM. Only meaningful
	// with CORE_MD, and it brings the whole memory controller in with it.
	parameter MD_DDR3  = 0,
	parameter CORE_PS1 = 0,
	parameter CORE_N64 = 0
)(
	input  wire       sys_clk,       // 50 MHz onboard oscillator, ball U22
	input  wire       eth_refclk,    // 50 MHz from the LAN8720, U4 pin 47

	input  wire [1:0] eth_rxd,
	input  wire       eth_crs_dv,
	output wire [1:0] eth_txd,
	output wire       eth_tx_en,

	output wire       eth_mdc,
	inout  wire       eth_mdio,

	output wire       led0,
	output wire       led1,

	// --- the ESP32's SPI wires, on header U2 (see esp32/README.md) ----------------
	input  wire       esp_sclk,
	input  wire       esp_mosi,
	output wire       esp_miso,
	input  wire       esp_cs_n,

	// --- HDMI, a bare connector breakout on header U4 pins 7-26 (boards/qmtech_a100t/
	// HEADERS.md): TMDS single-ended (+ and - driven opposite), the shields, ground,
	// CEC, DDC and hot-plug held low, the +5V pin held at 3.3 V
	output wire [2:0] hdmi_d_p,
	output wire [2:0] hdmi_d_n,
	output wire       hdmi_ck_p,
	output wire       hdmi_ck_n,
	output wire [10:0] hdmi_lo,
	output wire       hdmi_5v,

	// --- DDR3, present only in a build that uses it ---------------------------
	inout  wire [15:0] ddr3_dq,
	inout  wire [1:0]  ddr3_dqs_p,
	inout  wire [1:0]  ddr3_dqs_n,
	output wire [13:0] ddr3_addr,
	output wire [2:0]  ddr3_ba,
	output wire        ddr3_ras_n,
	output wire        ddr3_cas_n,
	output wire        ddr3_we_n,
	output wire        ddr3_reset_n,
	output wire [0:0]  ddr3_ck_p,
	output wire [0:0]  ddr3_ck_n,
	output wire [0:0]  ddr3_cke,
	// Chip select goes to a bank 16 ball the board does not connect. The memory
	// has its CS tied on the board, but the controller wants the signal, and
	// disabling it in the controller's own configuration leaves its internal
	// address multiplexer with two drivers on the same nets. Bank 16 is the
	// memory's bank and is not on the headers, so an unused pin there drives
	// nothing. One wasted ball, and a controller that is internally consistent.
	output wire [1:0]  ddr3_dm,
	output wire [0:0]  ddr3_odt
);

	// --- clocks -------------------------------------------------------------
	wire refclk;
	BUFG bufg_ref (.I(eth_refclk), .O(refclk));

	// Hold reset for ~1.3 ms after configuration so the PHY's clock and the
	// logic that runs off it are both settled before the first frame.
	reg [15:0] rst_cnt = 16'd0;
	reg        rst = 1'b1;
	always @(posedge refclk) begin
		if (rst_cnt == 16'hFFFF) rst <= 1'b0;
		else                     rst_cnt <= rst_cnt + 16'd1;
	end

	// --- heartbeat, deliberately on the other clock --------------------------
	reg [24:0] hb = 25'd0;
	always @(posedge sys_clk) hb <= hb + 1'b1;
	assign led0 = hb[24];

	// --- register bus --------------------------------------------------------
	wire [31:0] bus_addr, bus_wdata, bus_rdata;
	wire        bus_we, bus_re, bus_ack;
	wire [1:0]  bus_err;
	wire        rx_frame, tx_frame;

	// the frame streamer's settings come from the console's registers
	wire        stream_en, stream_ready, stream_done_tog;
	wire [15:0] stream_port;
	wire [31:0] stream_base;
	wire [17:0] stream_words;
	wire [15:0] stream_rowlen, stream_stride;
	wire        stream_direct, stream_fvalid, stream_frd;
	wire [31:0] stream_fdata;

	net_core #(
		.MAC_ADDR (48'h02_00_5E_10_00_01),
		.IP_ADDR  ({8'd192, 8'd168, 8'd178, 8'd50}),
		.UDP_PORT (16'd5005)
	) u_net (
		.clk(refclk), .rst(rst),
		.rmii_rxd(eth_rxd), .rmii_crs_dv(eth_crs_dv),
		.rmii_txd(eth_txd), .rmii_tx_en(eth_tx_en),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		.rx_frame(rx_frame), .tx_frame(tx_frame),
		.stream_en(stream_en), .stream_port(stream_port), .stream_base(stream_base), .stream_words(stream_words),
		.stream_rowlen(stream_rowlen), .stream_stride(stream_stride),
		.stream_ready(stream_ready), .stream_done_tog(stream_done_tog),
		.stream_direct(stream_direct), .stream_fdata(stream_fdata), .stream_fvalid(stream_fvalid), .stream_frd(stream_frd)
	);

	// What the analyser watches. Pointing it at the RMII pins makes the board
	// able to show you its own network traffic in the browser: ping it, capture,
	// and the frame is there dibit by dibit. When the PSR-2 tap arrives these
	// become header pins instead and nothing else changes.
	wire [31:0] la_probe = {
		22'd0,
		tx_frame, rx_frame,       // [9:8]
		eth_mdio, eth_mdc,        // [7:6]
		eth_txd, eth_tx_en,       // [5:3]
		eth_rxd, eth_crs_dv       // [2:0]
	};

	// --- the memory ---------------------------------------------------------------
	wire [23:0]  d_addr;
	wire         d_req, d_we;
	wire [127:0] d_wdata, d_rdata;
	wire [15:0]  d_wdata_wmask;
	wire         d_ready, d_valid, d_calibrated;

	localparam HAS_DDR3 = MD_DDR3 || CORE_PS1 || CORE_N64;
	// the HDMI clocks, from the memory's MMCM (below)
	wire         vid_pclk, vid_pclk5, vid_locked;
	wire [9:0]   vid_x, vid_y;
	wire         vid_req;
	wire [23:0]  vid_rgb;
	assign hdmi_lo = 11'd0;
	assign hdmi_5v = 1'b1;
	generate if (HAS_DDR3) begin : g_ddr3
		// MIG wants 200 MHz for both its system clock and its IDELAY reference,
		// and the board has a 50 MHz oscillator. One MMCM: 50 x 16 = 800 MHz in
		// the VCO, divided by four.
		// (and HDMI's: VCO 50 x 20 = 1000 MHz; /5 = 200 MHz for MIG, /40 = 25.000 MHz
		// pixel clock -- 640x480's is 25.175, monitors take this -- /8 = 125 MHz, five
		// times it for the serialisers, which must be exactly five times, one MMCM)
		wire mmcm_fb, clk200_raw, clk200, mmcm_locked, pclk_raw, pclk5_raw;
		MMCME2_BASE #(
			.CLKIN1_PERIOD(20.0),          // 50 MHz
			.CLKFBOUT_MULT_F(20.0),        // 1000 MHz VCO
			.DIVCLK_DIVIDE(1),
			.CLKOUT0_DIVIDE_F(5.0),        // 200 MHz
			.CLKOUT1_DIVIDE(40),           // 25 MHz
			.CLKOUT2_DIVIDE(8)             // 125 MHz
		) u_mmcm (
			.CLKIN1(sys_clk), .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb),
			.CLKOUT0(clk200_raw), .LOCKED(mmcm_locked),
			.RST(1'b0), .PWRDWN(1'b0),
			.CLKOUT0B(), .CLKOUT1(pclk_raw), .CLKOUT1B(), .CLKOUT2(pclk5_raw), .CLKOUT2B(),
			.CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
			.CLKFBOUTB()
		);
		BUFG bufg200 (.I(clk200_raw), .O(clk200));
		BUFG bufgpx  (.I(pclk_raw),   .O(vid_pclk));
		BUFG bufgpx5 (.I(pclk5_raw),  .O(vid_pclk5));
		assign vid_locked = mmcm_locked;
		hdmi_tx #(.SIM(0), .PSEUDO(1), .EXT_CLK(1)) u_hdmi (
			.clk50(1'b0), .rst(1'b0), .sim_pclk(1'b0),
			.ext_pclk(vid_pclk), .ext_pclk5(vid_pclk5), .ext_locked(vid_locked),
			.pclk(), .x(vid_x), .y(vid_y), .req(vid_req), .rgb(vid_rgb), .frame_start(),
			.tmds_p(hdmi_d_p), .tmds_n(hdmi_d_n), .tmds_clk_p(hdmi_ck_p), .tmds_clk_n(hdmi_ck_n),
			.sym_0(), .sym_1(), .sym_2()
		);

		wire        ui_clk, ui_rst, calib_done;
		wire [27:0] app_addr;
		wire [2:0]  app_cmd;
		wire        app_en, app_rdy, app_wdf_rdy, app_wdf_wren, app_wdf_end;
		wire [127:0] app_wdf_data, app_rd_data;
		wire [15:0] app_wdf_mask;
		wire        app_rd_data_valid;

		ddr3_mem #(.AW(24)) u_mem (
			// The console side runs on refclk -- the PHY's 50 MHz, which is what
			// the register bus and every core already use. MIG's own 200 MHz
			// comes from the board oscillator through the MMCM above, so the
			// two are genuinely unrelated clocks and the crossing inside
			// ddr3_mem is doing real work.
			.clk(refclk), .rst(rst),
			.m_addr(d_addr), .m_req(d_req), .m_we(d_we), .m_wdata(d_wdata), .m_wmask(d_wdata_wmask),
			.m_ready(d_ready), .m_rdata(d_rdata), .m_valid(d_valid),
			.m_calibrated(d_calibrated),
			.ui_clk(ui_clk), .ui_rst(ui_rst), .calib_done(calib_done),
			.app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en),
			.app_rdy(app_rdy),
			.app_wdf_data(app_wdf_data), .app_wdf_wren(app_wdf_wren),
			.app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask),
			.app_wdf_rdy(app_wdf_rdy),
			.app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid)
		);

		mig_a100t u_mig (
			.ddr3_dq(ddr3_dq), .ddr3_dqs_p(ddr3_dqs_p), .ddr3_dqs_n(ddr3_dqs_n),
			.ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba),
			.ddr3_ras_n(ddr3_ras_n), .ddr3_cas_n(ddr3_cas_n),
			.ddr3_we_n(ddr3_we_n), .ddr3_reset_n(ddr3_reset_n),
			.ddr3_ck_p(ddr3_ck_p), .ddr3_ck_n(ddr3_ck_n), .ddr3_cke(ddr3_cke),
			.ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt),
			.app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en),
			.app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
			.app_wdf_wren(app_wdf_wren), .app_wdf_mask(app_wdf_mask),
			.app_rd_data(app_rd_data), .app_rd_data_end(),
			.app_rd_data_valid(app_rd_data_valid),
			.app_rdy(app_rdy), .app_wdf_rdy(app_wdf_rdy),
			.app_sr_req(1'b0), .app_ref_req(1'b0), .app_zq_req(1'b0),
			.app_sr_active(), .app_ref_ack(), .app_zq_ack(),
			.ui_clk(ui_clk), .ui_clk_sync_rst(ui_rst),
			.init_calib_complete(calib_done),
			.sys_clk_i(clk200), .clk_ref_i(clk200),
			.sys_rst(mmcm_locked)           // active low: held down until locked
		);
	end else begin : g_noddr3
		assign d_ready = 1'b0;
		assign d_rdata = 128'd0;
		assign d_valid = 1'b0;
		assign d_calibrated = 1'b0;
		assign ddr3_addr = 14'd0; assign ddr3_ba = 3'd0;
		assign ddr3_ras_n = 1'b1; assign ddr3_cas_n = 1'b1;
		assign ddr3_we_n = 1'b1;  assign ddr3_reset_n = 1'b0;
		assign ddr3_ck_p = 1'b0;  assign ddr3_ck_n = 1'b1;
		assign ddr3_cke = 1'b0;
		assign ddr3_dm = 2'd0;    assign ddr3_odt = 1'b0;
		// (no MMCM, no HDMI)
		assign vid_pclk = 1'b0; assign vid_pclk5 = 1'b0; assign vid_locked = 1'b0;
		assign vid_x = 10'd0; assign vid_y = 10'd0; assign vid_req = 1'b0;
		assign hdmi_d_p = 3'd0; assign hdmi_d_n = 3'd0; assign hdmi_ck_p = 1'b0; assign hdmi_ck_n = 1'b0;
	end endgenerate

	// --- the MDIO bus, and who owns it ----------------------------------------
	// Two masters: the one that resets the PHY at power-up, on the board's own
	// oscillator, and the host's, on the PHY's clock. The first has the bus
	// until it is finished, which is a few hundred microseconds.
	wire rf_mdc, rf_mdio_o, rf_mdio_oe;
	wire pr_mdc, pr_mdio_o, pr_mdio_oe, pr_done;

	phy_reset u_phy_reset (
		.clk(sys_clk), .rst(1'b0),
		.mdc(pr_mdc), .mdio_o(pr_mdio_o), .mdio_oe(pr_mdio_oe),
		.mdio_i(eth_mdio), .done(pr_done)
	);

	assign eth_mdc  = pr_done ? rf_mdc : pr_mdc;
	wire   mdio_oe  = pr_done ? rf_mdio_oe : pr_mdio_oe;
	wire   mdio_out = pr_done ? rf_mdio_o  : pr_mdio_o;
	assign eth_mdio = mdio_oe ? mdio_out : 1'bz;

	regfile #(.CORE_NES(CORE_NES), .CORE_SMS(CORE_SMS), .CORE_MD(CORE_MD),
	          .MD_DDR3(MD_DDR3), .CORE_PS1(CORE_PS1), .CORE_N64(CORE_N64)) u_regs (
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wdata_wmask),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid),
		.d_calibrated(d_calibrated),
		.clk(refclk), .rst(rst),
		.la_probe(la_probe),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		.eth_mdc(rf_mdc),
		.mdio_o(rf_mdio_o), .mdio_oe(rf_mdio_oe), .mdio_i(eth_mdio),
		.esp_sclk(esp_sclk), .esp_mosi(esp_mosi), .esp_miso(esp_miso), .esp_cs_n(esp_cs_n),
		.stream_en(stream_en), .stream_port(stream_port), .stream_base(stream_base), .stream_words(stream_words),
		.stream_rowlen(stream_rowlen), .stream_stride(stream_stride),
		.stream_ready(stream_ready), .stream_done_tog(stream_done_tog),
		.stream_direct(stream_direct), .stream_fdata(stream_fdata), .stream_fvalid(stream_fvalid), .stream_frd(stream_frd),
		.pclk(vid_pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(vid_rgb)
	);

	// --- activity LED --------------------------------------------------------
	// A frame is over in microseconds. Stretch it to ~80 ms so an eye can see it.
	reg [21:0] act;
	always @(posedge refclk) begin
		if (rst)                        act <= 22'd0;
		else if (rx_frame || tx_frame)  act <= 22'h3F_FFFF;
		else if (act != 22'd0)          act <= act - 22'd1;
	end
	assign led1 = (act != 22'd0);

endmodule

`default_nettype wire
