//////////////////////////////////////////////////////////////////////////////////
// eth_top.v - the Ethernet endpoint, wired to real pins.
//
// The console runs from the board's own oscillator, through the MMCM (cclk,
// 1000 MHz / CLK_DIV). The ESP32 is the board's one way in (esp_bus). The network
// (NET = 1: the LAN8720 module's RMII logic, net_core, on the 50 MHz REF_CLK the
// module drives, onto the register bus through net_bridge) is not built: the board has
// no LAN module. Its pins stay in the constraints, driven low.
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
	parameter CORE_GG  = 0,     // the Game Gear (sms.v with GG): its own image, core id 'G'
	parameter CORE_MD  = 0,
	// The Mega Drive's cartridge in DDR3 rather than block RAM. Only meaningful
	// with CORE_MD, and it brings the whole memory controller in with it.
	parameter MD_DDR3  = 0,
	parameter CORE_PS1 = 0,
	parameter CORE_N64 = 0,
	parameter CORE_SNES = 0,
	parameter CORE_GB  = 0,     // the Game Boy (gb_top): its own image, the cartridge in DDR3, core id 'B'
	parameter CORE_A26 = 0,     // the Atari 2600 (a26_top): its own image, core id 'A'
	parameter CORE_PCE = 0,     // the PC Engine (pce_top): its own image, the HuCard in DDR3, core id 'E'
	parameter CORE_GBA = 0,     // the Game Boy Advance (gba_top): its own image, core id 'V'
	parameter CORE_PC  = 0,     // the PC (pc_top): its own image, core id 'C'
	// 1: the network (see the top). 0: none -- the ESP32 alone.
	parameter NET      = 0,
	// 1: the picture to the web page too, as a UDP stream (net_core's streamer, the
	// NES / Master System / Mega Drive framebuffer in regfile, the console's stream
	// registers). The picture is on HDMI; the network keeps only the register API.
	// (not with the console on its own clock: the streamer reads the console's
	// framebuffer directly, in the PHY's clock, and would need a crossing of its own)
	parameter WEBVID   = 0,
	parameter N64_DBG  = 1,      // the N64's debug window: 0 for a shipping image (n64_top DBG)
	parameter N64_ISV  = 0,      // the N64's ISViewer text capture, for n64-systemtest (n64_top ISV)
	parameter PS1_DBG  = 1,      // the PlayStation's debug hardware: 0 for a shipping image (ps1_top DBG)
	parameter JTAG_DBG = 0,      // the register bus over JTAG (jtag_axi + jtag_bus, tools/jtag.py): debug builds
	// 1: a shipping image. Nothing in it that only a PC on the network or a developer at the
	// JTAG port ever read: no logic analyser, no PC sound ring, no frame reader, no bare-CPU test
	// slot (regfile, console_top). Built with PS1_DBG = 0, N64_DBG = 0, JTAG_DBG = 0 (tools/core.sh
	// RELEASE=1). The parts that stay are the console, HDMI, the ESP32 link and the OSD.
	parameter RELEASE  = 0,
	parameter PS1_DCIDX = 8,     // the PlayStation's data cache: 2^n lines of 16 bytes (8 = 4 KB, 10 = 16 KB)
	// The console's clock: the MMCM's 1000 MHz VCO divided by this. 20 is 50 MHz,
	// what every core was written for; a core that runs faster says so in its build.
	parameter CLK_DIV  = 20
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
	inout  wire       esp_miso,          // (let go in a quad write's data: the ESP32 drives it then)
	input  wire       esp_cs_n,
	input  wire       esp_d2,            // quad's third and fourth data wires: the ESP32's WP (GPIO 22) and
	input  wire       esp_d3,            // HD (GPIO 21), on U2 pins 12 and 11

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
	// cclk: the console's, from the board oscillator through the MMCM below (cclk_raw,
	// cclk_locked). (The LAN module's REF_CLK only with NET, for net_core.)
	wire cclk_raw, cclk_locked, cclk;
	BUFG bufg_con (.I(cclk_raw), .O(cclk));

	// Hold reset for 65,536 clocks after the MMCM locks.
	reg [15:0] rst_cnt = 16'd0;
	reg        rst = 1'b1;
	always @(posedge cclk) begin
		if (!cclk_locked)             begin rst_cnt <= 16'd0; rst <= 1'b1; end
		else if (rst_cnt == 16'hFFFF) rst <= 1'b0;
		else                          rst_cnt <= rst_cnt + 16'd1;
	end

	// --- heartbeat, deliberately on the other clock --------------------------
	reg [24:0] hb = 25'd0;
	always @(posedge sys_clk) hb <= hb + 1'b1;
	assign led0 = hb[24];

	// --- register bus --------------------------------------------------------
	// net_core's bus (n_*, through net_bridge to b_*) and the ESP32's (e_*), taking
	// turns onto regfile's (bus_*)
	wire [31:0] n_addr, n_wdata, n_rdata, b_addr, b_wdata, e_addr, e_wdata, bus_rdata;
	wire        n_we, n_re, b_we, b_re, b_ack, e_we, e_re, bus_ack, n_ack, e_ack;
	wire [1:0]  bus_err, n_err;
	wire        n_frd;
	wire        rx_frame, tx_frame;
	wire        rf_mdc, rf_mdio_o, rf_mdio_oe;     // the register file's MDIO master (NET)

	// the frame streamer's settings come from the console's registers
	wire        stream_en, stream_ready, stream_done_tog;
	wire [15:0] stream_port;
	wire [31:0] stream_base;
	wire [17:0] stream_words;
	wire [15:0] stream_rowlen, stream_stride;
	wire        stream_direct, stream_fvalid, stream_frd;
	wire [31:0] stream_fdata;

	generate if (NET) begin : g_net
	wire refclk;
	BUFG bufg_ref (.I(eth_refclk), .O(refclk));
	// net_core's reset, on the module's clock (which may never come)
	reg [15:0] nrst_cnt = 16'd0;
	reg        nrst = 1'b1;
	always @(posedge refclk) begin
		if (nrst_cnt == 16'hFFFF) nrst <= 1'b0;
		else                      nrst_cnt <= nrst_cnt + 16'd1;
	end
	net_core #(
		.MAC_ADDR (48'h02_00_5E_10_00_01),
		.IP_ADDR  ({8'd192, 8'd168, 8'd178, 8'd50}),
		.UDP_PORT (16'd5005)
	) u_net (
		.clk(refclk), .rst(nrst),
		.rmii_rxd(eth_rxd), .rmii_crs_dv(eth_crs_dv),
		.rmii_txd(eth_txd), .rmii_tx_en(eth_tx_en),
		.bus_addr(n_addr), .bus_wdata(n_wdata),
		.bus_we(n_we), .bus_re(n_re),
		.bus_rdata(n_rdata), .bus_ack(n_ack), .bus_err(n_err),
		.rx_frame(rx_frame), .tx_frame(tx_frame),
		// (without WEBVID the streamer never starts, and synthesis removes it)
		.stream_en(WEBVID ? stream_en : 1'b0), .stream_port(stream_port), .stream_base(stream_base), .stream_words(stream_words),
		.stream_rowlen(stream_rowlen), .stream_stride(stream_stride),
		.stream_ready(WEBVID ? stream_ready : 1'b0), .stream_done_tog(stream_done_tog),
		.stream_direct(stream_direct), .stream_fdata(stream_fdata), .stream_fvalid(WEBVID ? stream_fvalid : 1'b0), .stream_frd(n_frd)
	);
	assign stream_frd = WEBVID ? n_frd : 1'b0;
	net_bridge u_nbr (
		.n_clk(refclk), .n_rst(nrst),
		.n_addr(n_addr), .n_wdata(n_wdata), .n_we(n_we), .n_re(n_re),
		.n_rdata(n_rdata), .n_err(n_err), .n_ack(n_ack),
		.c_clk(cclk), .c_rst(rst),
		.c_addr(b_addr), .c_wdata(b_wdata), .c_we(b_we), .c_re(b_re),
		.c_rdata(bus_rdata), .c_err(bus_err), .c_ack(b_ack));
	// the activity LED: a frame is over in microseconds; stretched to ~80 ms
	reg [21:0] act;
	always @(posedge refclk) begin
		if (nrst)                       act <= 22'd0;
		else if (rx_frame || tx_frame)  act <= 22'h3F_FFFF;
		else if (act != 22'd0)          act <= act - 22'd1;
	end
	assign led1 = (act != 22'd0);
	// the MDIO bus: the PHY's reset at power-up (on the board's oscillator), then the
	// register file's
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
	end else begin : g_nonet
	// no network: the bus's first master is the JTAG cable in a debug build (registers, frames and
	// memory windows read from the PC: tools/jtag.py), else it asks nothing; the pins are still
	if (JTAG_DBG) begin : g_jtag
		wire [31:0] awaddr, wdata_j, araddr, rdata_j; wire [7:0] awlen, arlen;
		wire awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
		wire [1:0] bresp, rresp;
		jtag_axi_0 u_jtag (.aclk(cclk), .aresetn(!rst),
			.m_axi_awid(), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(), .m_axi_awburst(),
			.m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(), .m_axi_awvalid(awvalid), .m_axi_awready(awready),
			.m_axi_wdata(wdata_j), .m_axi_wstrb(), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
			.m_axi_bid(1'b0), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
			.m_axi_arid(), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(), .m_axi_arburst(),
			.m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(), .m_axi_arvalid(arvalid), .m_axi_arready(arready),
			.m_axi_rid(1'b0), .m_axi_rdata(rdata_j), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready));
		jtag_bus u_jbus (.clk(cclk), .rst(rst),
			.awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
			.wdata(wdata_j), .wlast(wlast), .wvalid(wvalid), .wready(wready),
			.bresp(bresp), .bvalid(bvalid), .bready(bready),
			.araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
			.rdata(rdata_j), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
			.bus_addr(b_addr), .bus_wdata(b_wdata), .bus_we(b_we), .bus_re(b_re), .bus_ack(b_ack), .bus_rdata(bus_rdata));
	end else begin : g_nojtag
		assign b_addr = 32'd0; assign b_wdata = 32'd0; assign b_we = 1'b0; assign b_re = 1'b0;
	end
	assign stream_frd = 1'b0; assign rx_frame = 1'b0; assign tx_frame = 1'b0;
	assign eth_txd = 2'b00; assign eth_tx_en = 1'b0;
	assign eth_mdc = 1'b0; assign eth_mdio = 1'bz;
	assign led1 = !rst;                       // (lit: the console is out of reset)
	end endgenerate

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

	localparam HAS_DDR3 = MD_DDR3 || CORE_PS1 || CORE_N64 || CORE_SNES || CORE_GB || CORE_PCE || CORE_GBA || CORE_PC;
	// the HDMI clocks, from the memory's MMCM (below)
	wire         vid_pclk, vid_pclk5, vid_locked;
	wire         pclk_raw_w, pclk5_raw_w, hlocked_w;
	wire [15:0]  aud_s, aud_r;  wire aud_tog;
	wire [9:0]   vid_x, vid_y;
	wire         vid_req;
	wire [23:0]  vid_rgb;
	// The connector's other pins: shields, grounds, the reserved pin, DDC and hot-plug held low
	// (a display's pull-ups then cannot lift a ball to 5 V); CEC (pin 13, hdmi_lo[4]) left
	// alone -- a 3.3 V bus the display idles high, and one held low all the time is a jammed
	// bus to a set that uses it; the +5V pin at 3.3 V, the most this chip has.
	assign hdmi_lo[3:0] = 4'd0; assign hdmi_lo[10:5] = 6'd0;
	OBUFT u_cec (.I(1'b0), .T(1'b1), .O(hdmi_lo[4]));
	assign hdmi_5v = 1'b1;
	generate if (HAS_DDR3) begin : g_ddr3
		// MIG wants 200 MHz for both its system clock and its IDELAY reference,
		// and the board has a 50 MHz oscillator. One MMCM: 50 x 20 = 1000 MHz in
		// the VCO, /5 = 200 MHz for MIG, /CLK_DIV the console. (The pixel clock came
		// from here too, /40 = 25.000 MHz, until 2026-10-16: hdmi_clk now.)
		wire mmcm_fb, clk200_raw, clk200, mmcm_locked;
		MMCME2_BASE #(
			.CLKIN1_PERIOD(20.0),          // 50 MHz
			.CLKFBOUT_MULT_F(20.0),        // 1000 MHz VCO
			.DIVCLK_DIVIDE(1),
			.CLKOUT0_DIVIDE_F(5.0),        // 200 MHz
			.CLKOUT3_DIVIDE(CLK_DIV)       // the console
		) u_mmcm (
			.CLKIN1(sys_clk), .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb),
			.CLKOUT0(clk200_raw), .LOCKED(mmcm_locked),
			.RST(1'b0), .PWRDWN(1'b0),
			.CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
			.CLKOUT3(cclk_raw), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
			.CLKFBOUTB()
		);
		assign cclk_locked = mmcm_locked;
		BUFG bufg200 (.I(clk200_raw), .O(clk200));
		if (CORE_N64 != 0) begin : g_n64pclk
			// The N64's picture at the N64's own rate. Its VI interrupt -- the game's clock -- is
			// locked to HDMI's frame (n64_top "the VI's clock"), so HDMI's rate IS the game's speed:
			// at 25.000 MHz that was 59.52 Hz, 0.5% slower than a real NTSC N64 (3094 VI clocks x
			// 263 lines at 48.681812 MHz = 59.826 Hz). Its own MMCM: 50 / 2 x 25.125 = 628.125 MHz,
			// /25 = 25.125 MHz (59.821 Hz, 0.008% off), /5 = 125.625 MHz for the serialisers.
			wire vfb, vp_raw, vp5_raw, vlocked;
			MMCME2_BASE #(.CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(25.125), .DIVCLK_DIVIDE(2),
			              .CLKOUT0_DIVIDE_F(25.0), .CLKOUT1_DIVIDE(5)) u_vmmcm (
				.CLKIN1(sys_clk), .CLKFBIN(vfb), .CLKFBOUT(vfb), .CLKOUT0(vp_raw), .CLKOUT1(vp5_raw), .LOCKED(vlocked),
				.RST(1'b0), .PWRDWN(1'b0), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
				.CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB());
			assign pclk_raw_w = vp_raw; assign pclk5_raw_w = vp5_raw; assign hlocked_w = vlocked;
		end else begin : g_pclk
			// 25.2 MHz and its 5x (hdmi_clk: why not the memory MMCM's /40)
			hdmi_clk u_hclk (.sys_clk(sys_clk), .pclk_raw(pclk_raw_w), .pclk5_raw(pclk5_raw_w), .locked(hlocked_w));
		end

		wire        ui_clk, ui_rst, calib_done;
		wire [27:0] app_addr;
		wire [2:0]  app_cmd;
		wire        app_en, app_rdy, app_wdf_rdy, app_wdf_wren, app_wdf_end;
		wire [127:0] app_wdf_data, app_rd_data;
		wire [15:0] app_wdf_mask;
		wire        app_rd_data_valid;

		ddr3_mem #(.AW(24)) u_mem (
			// The console side runs on cclk, MIG's user clock on its own MMCM: the
			// crossing inside ddr3_mem is between unrelated clocks.
			.clk(cclk), .rst(rst),
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
		// (no memory: an MMCM for the console -- VCO 1000 MHz, /CLK_DIV -- and hdmi_clk's
		// for the picture)
		wire hfb, hl;
		MMCME2_BASE #(.CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
		              .CLKOUT2_DIVIDE(CLK_DIV)) u_hmmcm (
			.CLKIN1(sys_clk), .CLKFBIN(hfb), .CLKFBOUT(hfb), .CLKOUT0(), .CLKOUT1(), .LOCKED(hl),
			.RST(1'b0), .PWRDWN(1'b0), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(cclk_raw), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
			.CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB());
		hdmi_clk u_hclk (.sys_clk(sys_clk), .pclk_raw(pclk_raw_w), .pclk5_raw(pclk5_raw_w), .locked(hlocked_w));
		assign cclk_locked = hl;
	end endgenerate
	// HDMI, in every build: the clocks from whichever MMCM above
	BUFG bufgpx  (.I(pclk_raw_w),  .O(vid_pclk));
	BUFG bufgpx5 (.I(pclk5_raw_w), .O(vid_pclk5));
	assign vid_locked = hlocked_w;
	hdmi_tx #(.SIM(0), .PSEUDO(1), .EXT_CLK(1), .FS441(CORE_PS1 != 0 || CORE_N64 != 0), .PX125(CORE_N64 != 0)) u_hdmi (
		.clk50(1'b0), .rst(1'b0), .sim_pclk(1'b0),
		.ext_pclk(vid_pclk), .ext_pclk5(vid_pclk5), .ext_locked(vid_locked),
		.pclk(), .x(vid_x), .y(vid_y), .req(vid_req), .rgb(vid_rgb), .frame_start(),
		.tmds_p(hdmi_d_p), .tmds_n(hdmi_d_n), .tmds_clk_p(hdmi_ck_p), .tmds_clk_n(hdmi_ck_n),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(aud_s), .aud_r(aud_r), .aud_tog(aud_tog)
	);


	// --- the ESP32: a second master on the bus ------------------------------------
	// A turn is one transfer: a master holds its request until the acknowledge, and
	// the one that did not go last goes first when both ask. In the PlayStation image
	// the disc feed (cd_feed, in console_top) listens on the same four wires: both
	// take every frame, and the command byte says which one answers (0x3x the drive,
	// everything else this). Byte 0 out is the signature from both alike.
	wire rf_esp_miso, e_miso; wire [7:0] e_cmd;
	esp_bus #(.CORE_ID(CORE_PC ? 8'h43 : CORE_GBA ? 8'h56 : CORE_PCE ? 8'h45 : CORE_GB ? 8'h42 : CORE_A26 ? 8'h41 : CORE_GG ? 8'h47 : CORE_SNES ? 8'h46 : CORE_PS1 ? 8'h50 : CORE_N64 ? 8'h36 : CORE_MD ? 8'h4D : CORE_NES ? 8'h4E : 8'h53)) u_espbus (
		.clk(cclk), .rst(rst),
		.spi_sclk(esp_sclk), .spi_mosi(esp_mosi), .spi_miso(e_miso), .spi_cs_n(esp_cs_n),
		.spi_d1(esp_miso), .spi_d2(esp_d2), .spi_d3(esp_d3), .spi_miso_t(e_miso_t),
		.bus_addr(e_addr), .bus_wdata(e_wdata), .bus_we(e_we), .bus_re(e_re),
		.bus_rdata(bus_rdata), .bus_ack(e_ack), .cmd(e_cmd));
	wire e_miso_t;
	assign esp_miso = e_miso_t ? 1'bz : (CORE_PS1 && e_cmd[7:4] == 4'h3) ? rf_esp_miso : e_miso;
	wire [31:0] bus_addr, bus_wdata;
	wire        bus_we, bus_re;
	bus_arb u_arb (.clk(cclk), .rst(rst),
		.a_addr(b_addr), .a_wdata(b_wdata), .a_we(b_we), .a_re(b_re), .a_ack(b_ack),
		.b_addr(e_addr), .b_wdata(e_wdata), .b_we(e_we), .b_re(e_re), .b_ack(e_ack),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_we(bus_we), .bus_re(bus_re), .bus_ack(bus_ack));

	// Back to the shell: 0xB0070000 written to SYS 0x0014 (by the ESP32, to switch
	// consoles; regfile takes the write as a no-op).
	icap_reboot u_reboot (.clk(cclk), .rst(rst),
		.go(bus_we && bus_ack && bus_addr == 32'h0000_0014 && bus_wdata == 32'hB007_0000));

	regfile #(.CORE_NES(CORE_NES), .CORE_SMS(CORE_SMS), .CORE_GG(CORE_GG), .CORE_MD(CORE_MD), .CORE_GB(CORE_GB), .CORE_A26(CORE_A26), .CORE_PCE(CORE_PCE), .CORE_GBA(CORE_GBA), .CORE_PC(CORE_PC),
	          .MD_DDR3(MD_DDR3), .CORE_PS1(CORE_PS1), .CORE_N64(CORE_N64), .CORE_SNES(CORE_SNES), .WEBVID(WEBVID), .N64_DBG(N64_DBG), .N64_ISV(N64_ISV), .PS1_DBG(PS1_DBG),
	          .RELEASE(RELEASE), .PS1_DCIDX(PS1_DCIDX),
	          .CLK_HZ(1_000_000_000 / CLK_DIV)) u_regs (
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wdata_wmask),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid),
		.d_calibrated(d_calibrated),
		.clk(cclk), .rst(rst),
		.la_probe(la_probe),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		.eth_mdc(rf_mdc),
		.mdio_o(rf_mdio_o), .mdio_oe(rf_mdio_oe), .mdio_i(eth_mdio),
		.esp_sclk(esp_sclk), .esp_mosi(esp_mosi), .esp_miso(rf_esp_miso), .esp_cs_n(CORE_PS1 ? esp_cs_n : 1'b1),
		.stream_en(stream_en), .stream_port(stream_port), .stream_base(stream_base), .stream_words(stream_words),
		.stream_rowlen(stream_rowlen), .stream_stride(stream_stride),
		.stream_ready(stream_ready), .stream_done_tog(stream_done_tog),
		.stream_direct(stream_direct), .stream_fdata(stream_fdata), .stream_fvalid(stream_fvalid), .stream_frd(stream_frd),
		.pclk(vid_pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(vid_rgb),
		.aud_s(aud_s), .aud_r(aud_r), .aud_tog(aud_tog)
	);

endmodule

`default_nettype wire
