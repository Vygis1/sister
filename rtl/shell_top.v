//////////////////////////////////////////////////////////////////////////////////
// shell_top.v - the golden image. What the board is when it is not a console.
//
// This lives at address 0 of the configuration flash and is what loads on
// power-up, every time, for ever. Its whole job is to put a different bitstream
// into the rest of the flash and then jump into it.
//
//   $000000 - $1FFFFF   the shell, which uses half of its two megabytes
//   $200000 - $7FFFFF   the core, which gets all six of the rest
//
// ONE core at a time, with the whole chip to itself. That is the entire point:
// a NES image contains a NES and nothing else, and the Master System image is a
// different file. Sharing one bitstream between two machines is what this
// arrangement replaces.
//
// --- two front doors -------------------------------------------------------------
//
// An ESP32 on four wires, and a PC over Ethernet. Both reach the same flash
// engine, and the engine is a module of its own (shell_flash.v) precisely so
// that the rule about what may be written is true for both without either
// having to remember it.
//
// The Ethernet path is not a stopgap. It is how the shell gets developed and
// debugged -- the register bus, the host library and the web UI already exist
// and work -- and the ESP32 is what makes the finished thing an appliance you
// can drive from a phone with no PC in the room.
//
// --- why it is deliberately small -------------------------------------------------
//
// Everything here is load-bearing in a way the consoles are not. A console that
// misbehaves is a bad afternoon; a shell that misbehaves is a board that needs
// JTAG to come back. So: the two links, the flash engine, the primitive that
// restarts configuration, and two LEDs. No video, no audio, no CPU. It should
// never need to change when a console does, and it should always fit.
//
// --- why the board cannot be bricked -----------------------------------------------
//
//   1. Power-up configuration ALWAYS reads address 0. A broken core is one
//      power cycle away from not mattering.
//   2. Neither link can reach the shell's own image. The address arithmetic in
//      shell_flash.v makes it unreachable, rather than a check that could be
//      forgotten in one of the two callers.
//   3. CONFIGFALLBACK returns here if a slot fails to load, instead of leaving
//      DONE low -- which is indistinguishable from dead.
//   4. JTAG overrides all of it.
//
// --- the clocks -------------------------------------------------------------------
//
// Everything of consequence runs on the PHY's REF_CLK, the same choice eth_top
// makes and for the same reason: the RMII receiver, the packet engine and the
// register file share one clock, so there is no crossing in the data path to get
// subtly wrong. REF_CLK comes from the PHY's own crystal and runs whether or not
// a cable is plugged in.
//
// The heartbeat LED deliberately runs on the board oscillator instead, so that
// "configured, but the PHY clock is dead" looks different from "never
// configured".
//
// --- the flash pins ----------------------------------------------------------------
//
// CCLK is not a pin that can be constrained; it goes through STARTUPE2. And in
// single-bit mode the N25Q's DQ2 and DQ3 are /W and /HOLD -- the board parks
// unused pins with a pulldown, which asserts write protect AND holds the chip,
// so flash writes would silently do nothing at all. They are driven high on
// purpose.
//
// --- the SPI protocol (the ESP32 door) ----------------------------------------------
//
// One chip-select frame per exchange. Byte 0 in is the command; byte 0 out is
// always the fixed signature, so "is anything alive down there" costs one byte.
//
//   01 PING / 02 STATUS                  -> sig, version, core, busy
//   10 FLASH_ERASE  a2,a1,a0                one 64 kB sector, then poll
//   11 FLASH_WRITE  a2,a1,a0, 256 bytes     one page, then poll
//   12 FLASH_READ   a2,a1,a0                fetch a page, then poll
//   13 FLASH_PAGE   + 257 dummy bytes    -> that page
//   20 BOOT         0 shell / 1 core        no reply; the chip is gone
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_top (
	input  wire       sys_clk,        // 50 MHz board oscillator, heartbeat only
	output wire       led0,           // heartbeat
	output wire       led1,           // flash busy, or network activity

	// --- the PC, over Ethernet --------------------------------------------
	input  wire       eth_refclk,
	input  wire [1:0] eth_rxd,
	input  wire       eth_crs_dv,
	output wire [1:0] eth_txd,
	output wire       eth_tx_en,
	output wire       eth_mdc,
	inout  wire       eth_mdio,

	// --- the ESP32, on header U2 pins 7-10 --------------------------------
	input  wire       esp_sclk,
	input  wire       esp_mosi,
	output wire       esp_miso,
	input  wire       esp_cs_n,

	// --- the configuration flash -------------------------------------------
	output wire       flash_cs_n,     // P18  FCS_B
	output wire       flash_mosi,     // R14  D00
	input  wire       flash_miso,     // R15  D01
	output wire       flash_wp_n,     // P14  D02, held high
	output wire       flash_hold_n,   // N14  D03, held high

	// HDMI (the breakout on U4, as eth_top): a picture while a core is installed
	output wire [2:0] hdmi_d_p,
	output wire [2:0] hdmi_d_n,
	output wire       hdmi_ck_p,
	output wire       hdmi_ck_n,
	output wire [10:0] hdmi_lo,
	output wire       hdmi_5v
);

	wire clk;
	BUFG bufg_ref (.I(eth_refclk), .O(clk));

	reg [15:0] rst_cnt = 16'd0;
	reg        rst = 1'b1;
	always @(posedge clk) begin
		if (rst_cnt == 16'hFFFF) rst <= 1'b0;
		else                     rst_cnt <= rst_cnt + 16'd1;
	end

	localparam [7:0] VERSION = 8'd1;
	localparam [7:0] CORE_ID = 8'd0;          // 0 is the shell itself

	// --- the flash engine, shared by both doors ------------------------------
	wire [1:0]  fl_op;
	wire [22:0] fl_offset;
	wire        fl_start;
	wire        busy;
	wire [5:0]  fl_windex;
	wire        fl_we;
	wire [31:0] fl_wdata, fl_rdata;
	wire        flash_sck;
	wire        miso_level;
	wire [7:0]  sck_edges, cs_falls;
	wire        miso_ever_low;
	wire [4:0]  fl_state;

	shell_flash #(.DIV(16)) u_flash (
		.clk(clk), .rst(rst),
		.op(fl_op), .offset(fl_offset),
		.start(fl_start), .busy(busy),
		.buf_windex(fl_windex), .buf_we(fl_we),
		.buf_wdata(fl_wdata), .buf_rdata(fl_rdata),
		.flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi),
		.flash_miso(flash_miso), .flash_sck(flash_sck),
		.miso_level(miso_level), .sck_edges(sck_edges),
		.cs_falls(cs_falls), .miso_ever_low(miso_ever_low),
		.dbg_state(fl_state)
	);

	assign flash_wp_n   = 1'b1;
	assign flash_hold_n = 1'b1;

	// --- door one: the PC ----------------------------------------------------
	wire [31:0] bus_addr, bus_wdata, bus_rdata;
	wire        bus_we, bus_re, bus_ack;
	wire [1:0]  bus_err;
	wire        rx_frame, tx_frame;

	net_core #(
		.MAC_ADDR (48'h02_00_5E_10_00_01),
		.IP_ADDR  ({8'd192, 8'd168, 8'd178, 8'd50}),
		.UDP_PORT (16'd5005)
	) u_net (
		.clk(clk), .rst(rst),
		.rmii_rxd(eth_rxd), .rmii_crs_dv(eth_crs_dv),
		.rmii_txd(eth_txd), .rmii_tx_en(eth_tx_en),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		.rx_frame(rx_frame), .tx_frame(tx_frame)
	);

	wire [1:0]  rg_op;
	wire [22:0] rg_offset;
	wire        rg_start;
	wire [5:0]  rg_windex;
	wire        rg_sel;
	wire        rg_we;
	wire [31:0] rg_wdata;
	wire        rg_boot_core;
	wire        rg_boot_go;

	shell_regs u_regs (
		.clk(clk), .rst(rst),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		.op(rg_op), .offset(rg_offset),
		.start(rg_start), .busy(busy), .miso_level(miso_level),
		.sck_edges(sck_edges), .cs_falls(cs_falls),
		.miso_ever_low(miso_ever_low), .fl_state(fl_state),
		.la_off(la_off), .la_we(la_we), .la_wdata(la_wdata),
		.la_rdata(la_rdata),
		.la_buf_addr(la_buf_addr), .la_buf_rdata(la_buf_rdata),
		.buf_windex(rg_windex), .buf_sel(rg_sel),
		.buf_we(rg_we), .buf_wdata(rg_wdata),
		.buf_rdata(fl_rdata),
		.boot_core(rg_boot_core), .boot_go(rg_boot_go)
	);

	// The PHY's own registers are not reachable from here. The shell has no use
	// for them and leaving MDIO idle costs nothing; the console image keeps the
	// window onto the PHY for when it is wanted.
	assign eth_mdc  = 1'b0;
	assign eth_mdio = 1'bz;

	// --- the logic analyser --------------------------------------------------
	// Every signal that leaves this design towards something that might not
	// answer. Both of the shell's failures so far -- a flash that says nothing
	// and an ESP32 link that returns zeros -- are questions about whether these
	// pins move, and in what order. A counter cannot answer that; a captured
	// waveform can, and the browser already knows how to draw one.
	wire [31:0] la_probe = {
		24'd0,
		esp_miso, esp_cs_n, esp_mosi, esp_sclk,        // [7:4]
		flash_miso, flash_cs_n, flash_mosi, flash_sck  // [3:0]
	};

	wire [15:0] la_off;
	wire        la_we;
	wire [31:0] la_wdata, la_rdata;
	wire [11:0] la_buf_addr;
	wire [31:0] la_buf_rdata;

	logic_analyzer #(.DEPTH_MAX(4096), .AW(12)) u_la (
		.clk(clk), .rst(rst),
		.probe(la_probe),
		.off(la_off), .we(la_we), .re(1'b0), .wdata(la_wdata),
		.rdata(la_rdata), .err(),
		.buf_addr(la_buf_addr), .buf_rdata(la_buf_rdata)
	);

	// --- door two: the ESP32 -------------------------------------------------
	wire        frame_start, frame_end, rx_stb;
	wire [7:0]  rx_byte;
	wire [23:0] rx_index;
	reg  [7:0]  tx_byte;

	esp_link u_link (
		.clk(clk), .rst(rst),
		.spi_sclk(esp_sclk), .spi_mosi(esp_mosi),
		.spi_miso(esp_miso), .spi_cs_n(esp_cs_n),
		.frame_start(frame_start), .frame_end(frame_end),
		.rx_byte(rx_byte), .rx_stb(rx_stb), .rx_index(rx_index),
		.tx_byte(tx_byte)
	);

	localparam [7:0] CMD_PING        = 8'h01,
	                 CMD_STATUS      = 8'h02,
	                 CMD_FLASH_ERASE = 8'h10,
	                 CMD_FLASH_WRITE = 8'h11,
	                 CMD_FLASH_READ  = 8'h12,
	                 CMD_FLASH_PAGE  = 8'h13,
	                 CMD_BOOT        = 8'h20;

	reg [7:0]  cmd;
	// Ten bits, not eight. A page dump is 258 bytes in one frame, and an eight
	// bit counter wraps to zero on byte 256 -- where the "is this still the
	// header" test below catches it a second time, and the last two bytes of
	// every page come back as status instead of data.
	reg [9:0]  rn;

	// `rn` counts bytes RECEIVED and has already been incremented by the time
	// the reply byte it belongs to is loaded, so the byte going out when rn == k
	// is out-byte k. The page starts at out-byte 2: one for the signature, one
	// for a dummy that buys `cmd` a whole byte time to settle rather than two
	// clock cycles.
	wire [9:0] page_i = rn - 10'd2;

	reg  [1:0]  sp_op;
	reg  [22:0] sp_offset;
	reg         sp_start;
	reg  [5:0]  sp_windex;
	reg         sp_we;
	reg  [31:0] sp_wdata;
	reg         sp_boot_core;
	reg         sp_boot_go;

	reg [23:0] arg_addr;
	reg [31:0] byte_sh;
	// A page frame is three address bytes then 256 of data, so data starts at
	// index 4 and (index - 4) / 4 is the word. One byte earlier than it was when
	// a slot number came first.
	wire [6:0] wr_word = rx_index[8:2] - 7'd1;

	// Reading a page back and writing one in never happen at the same time, so
	// one index serves both -- as a wire, so the buffer keeps a single driver.
	wire [5:0] sp_idx = (cmd == CMD_FLASH_PAGE) ? page_i[7:2] : sp_windex;

	wire [7:0] page_byte = (page_i[1:0] == 2'd0) ? fl_rdata[7:0]
	                     : (page_i[1:0] == 2'd1) ? fl_rdata[15:8]
	                     : (page_i[1:0] == 2'd2) ? fl_rdata[23:16]
	                                             : fl_rdata[31:24];

	// Combinational: the link needs the next byte ready within half an SPI clock
	// of the last one arriving, which is about two cycles here. Nothing can be
	// registered in that.
	always @* begin
		case (cmd)
		CMD_PING, CMD_STATUS:
			case (rn)
			10'd1:   tx_byte = VERSION;
			10'd2:   tx_byte = CORE_ID;
			default: tx_byte = {7'd0, busy};
			endcase
		CMD_FLASH_PAGE: tx_byte = (rn < 10'd2) ? {7'd0, busy} : page_byte;
		// Busy answers everything else, so a master that only wants "are you
		// finished" can send any command and read byte 1.
		default:        tx_byte = {7'd0, busy};
		endcase
	end

	always @(posedge clk) begin
		if (frame_start) rn <= 10'd0;
		else if (rx_stb) rn <= rn + 10'd1;
	end

	always @(posedge clk) begin
		if (rst) begin
			cmd <= 8'd0; arg_addr <= 24'd0; byte_sh <= 32'd0;
			sp_op <= 2'd0; sp_offset <= 23'd0; sp_start <= 1'b0;
			sp_windex <= 6'd0; sp_we <= 1'b0; sp_wdata <= 32'd0;
			sp_boot_core <= 1'b0; sp_boot_go <= 1'b0;
		end else begin
			sp_start <= 1'b0;
			sp_we    <= 1'b0;

			if (frame_start) cmd <= 8'd0;

			if (rx_stb) begin
				if (rx_index == 24'd0) cmd <= rx_byte;
				else case (cmd)

				// Erase takes an address like the others: it clears the one
				// 64 kB sector that address falls in, so a caller erases what it
				// is about to write and nothing else.
				CMD_FLASH_ERASE, CMD_FLASH_WRITE, CMD_FLASH_READ: begin
					if (rx_index >= 24'd1 && rx_index <= 24'd3)
						arg_addr <= {arg_addr[15:0], rx_byte};
					if (cmd == CMD_FLASH_WRITE &&
					    rx_index >= 24'd4 && rx_index < 24'd260) begin
						byte_sh <= {rx_byte, byte_sh[31:8]};
						// Every fourth byte completes a word; index 7 is the
						// fourth byte of the page, which is word 0.
						if (rx_index[1:0] == 2'd3) begin
							sp_we     <= 1'b1;
							sp_windex <= wr_word[5:0];
							sp_wdata  <= {rx_byte, byte_sh[31:8]};
						end
					end
				end

				CMD_BOOT:
					if (rx_index == 24'd1) sp_boot_core <= rx_byte[0];

				default: ;
				endcase
			end

			// At the END of the frame, not on the last byte: chip select rising
			// is the only moment the master has certainly finished, and a flash
			// program started early would race the bytes still arriving.
			if (frame_end) case (cmd)
			CMD_FLASH_ERASE: begin
				sp_op <= 2'd1; sp_offset <= arg_addr[22:0]; sp_start <= 1'b1;
			end
			CMD_FLASH_WRITE: begin
				sp_op <= 2'd2; sp_offset <= arg_addr[22:0]; sp_start <= 1'b1;
			end
			CMD_FLASH_READ: begin
				sp_op <= 2'd3; sp_offset <= arg_addr[22:0]; sp_start <= 1'b1;
			end
			CMD_BOOT: sp_boot_go <= 1'b1;
			default: ;
			endcase
		end
	end

	// --- the two doors joined -------------------------------------------------
	// Never both in use in practice: a person is at a phone or at a PC, not
	// both. So this is an OR rather than an arbiter, and what makes that safe is
	// that the flash engine ignores a start while it is busy -- the worst a
	// collision can do is lose a command, and both callers poll.
	assign fl_op     = rg_start ? rg_op     : sp_op;
	assign fl_offset = rg_start ? rg_offset : sp_offset;
	assign fl_start  = rg_start | sp_start;

	assign fl_we     = rg_we | sp_we;
	assign fl_wdata  = rg_we ? rg_wdata  : sp_wdata;
	// Keyed on the bus ADDRESSING the buffer, not on it writing: a read has no
	// write strobe, and keying on one made every word of a page read come back
	// as word 0.
	assign fl_windex = rg_sel ? rg_windex : sp_idx;

	// --- restarting configuration somewhere else -------------------------------
	// The data going into ICAPE2 has its bits reversed within each byte. Not a
	// convention anyone would guess; it is what the primitive wants, and getting
	// it wrong means the sequence is ignored and the board carries on being the
	// shell.
	function [31:0] bitswap;
		input [31:0] v;
		integer b;
		begin
			for (b = 0; b < 8; b = b + 1) begin
				bitswap[b]      = v[7  - b];
				bitswap[8  + b] = v[15 - b];
				bitswap[16 + b] = v[23 - b];
				bitswap[24 + b] = v[31 - b];
			end
		end
	endfunction

	wire boot_go   = rg_boot_go | sp_boot_go;
	wire boot_core = rg_boot_go ? rg_boot_core : sp_boot_core;

	reg        icap_run;
	reg [3:0]  icap_step;
	reg        icap_csib;
	reg [31:0] icap_din;
	reg [23:0] boot_addr;

	always @(posedge clk) begin
		if (rst) begin
			icap_run <= 1'b0; icap_step <= 4'd0;
			icap_csib <= 1'b1; icap_din <= 32'hFFFFFFFF;
			boot_addr <= 24'd0;
		end else if (!icap_run) begin
			if (boot_go) begin
				// Two destinations and no others: the core, or back here.
				boot_addr <= boot_core ? 24'h200000 : 24'h000000;
				icap_run  <= 1'b1;
			end
		end else begin
			icap_csib <= 1'b0;
			case (icap_step)
			4'd0: icap_din <= bitswap(32'hFFFFFFFF);   // dummy
			4'd1: icap_din <= bitswap(32'hAA995566);   // sync word
			4'd2: icap_din <= bitswap(32'h20000000);   // NOOP
			4'd3: icap_din <= bitswap(32'h30020001);   // write 1 word to WBSTAR
			4'd4: icap_din <= bitswap({8'd0, boot_addr});
			4'd5: icap_din <= bitswap(32'h30008001);   // write 1 word to CMD
			4'd6: icap_din <= bitswap(32'h0000000F);   // IPROG
			default: icap_din <= bitswap(32'h20000000);
			endcase
			// Stops rather than wrapping. By now the chip is already
			// reconfiguring; if IPROG somehow did not take, sitting still and
			// letting the host notice beats issuing the sequence in a loop.
			if (icap_step != 4'd15) icap_step <= icap_step + 4'd1;
		end
	end

	ICAPE2 #(.ICAP_WIDTH("X32")) u_icap (
		.O(), .CLK(clk), .CSIB(icap_csib), .I(icap_din), .RDWRB(1'b0)
	);

	// CCLK is not a pad; everything else about the flash is ordinary I/O.
	STARTUPE2 #(.PROG_USR("FALSE"), .SIM_CCLK_FREQ(0.0)) u_startup (
		.CFGCLK(), .CFGMCLK(), .EOS(), .PREQ(),
		.CLK(1'b0), .GSR(1'b0), .GTS(1'b0), .KEYCLEARB(1'b0),
		.PACK(1'b0), .USRCCLKO(flash_sck), .USRCCLKTS(1'b0),
		.USRDONEO(1'b1), .USRDONETS(1'b1)
	);

	// --- the picture -------------------------------------------------------------
	// 640 x 480 from the board oscillator (VCO 1000 MHz: /40 25 MHz, /8 125 MHz, as
	// eth_top), DVI (no sound); what the flash is doing, as text and a bar.
	assign hdmi_lo = 11'd0;
	assign hdmi_5v = 1'b1;
	wire hfb, hp_raw, hp5_raw, hpclk, hpclk5, hlocked;
	MMCME2_BASE #(.CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
	              .CLKOUT0_DIVIDE_F(40.0), .CLKOUT1_DIVIDE(8)) u_hmmcm (
		.CLKIN1(sys_clk), .CLKFBIN(hfb), .CLKFBOUT(hfb), .CLKOUT0(hp_raw), .CLKOUT1(hp5_raw), .LOCKED(hlocked),
		.RST(1'b0), .PWRDWN(1'b0), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
		.CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKFBOUTB());
	BUFG u_hb0 (.I(hp_raw), .O(hpclk));
	BUFG u_hb1 (.I(hp5_raw), .O(hpclk5));
	wire [9:0] hx, hy; wire [23:0] hrgb;
	hdmi_tx #(.SIM(0), .PSEUDO(1), .EXT_CLK(1), .AUDIO(0)) u_hdmi (
		.clk50(1'b0), .rst(1'b0), .sim_pclk(1'b0), .ext_pclk(hpclk), .ext_pclk5(hpclk5), .ext_locked(hlocked),
		.pclk(), .x(hx), .y(hy), .req(), .rgb(hrgb), .frame_start(),
		.tmds_p(hdmi_d_p), .tmds_n(hdmi_d_n), .tmds_clk_p(hdmi_ck_p), .tmds_clk_n(hdmi_ck_n),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(16'd0), .aud_r(16'd0), .aud_tog(1'b0));
	shell_screen u_screen (.clk(clk), .rst(rst),
		.op_start(fl_start), .op(fl_op), .offset(fl_offset), .boot_go(boot_go),
		.pclk(hpclk), .x(hx), .y(hy), .rgb(hrgb));

	// --- lights ----------------------------------------------------------------
	// The heartbeat runs on the BOARD oscillator, not the PHY's, so that a dead
	// PHY clock -- which would stop everything else in here -- still looks
	// different from a board that never configured at all.
	reg [24:0] beat;
	always @(posedge sys_clk) beat <= beat + 25'd1;
	assign led0 = beat[24];

	// Busy, plus network activity stretched to something an eye can see. While
	// wiring, "did anything happen when I sent that" is the only question.
	reg [21:0] act;
	always @(posedge clk) begin
		if (rst)                       act <= 22'd0;
		else if (rx_frame || tx_frame) act <= 22'h3F_FFFF;
		else if (act != 22'd0)         act <= act - 22'd1;
	end
	assign led1 = busy | (act != 22'd0);

endmodule

`default_nettype wire
