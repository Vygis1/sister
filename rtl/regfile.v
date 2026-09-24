//////////////////////////////////////////////////////////////////////////////////
// regfile.v - what lives behind the fpgalink register bus.
//
// Peripherals are addresses, not endpoints. Adding a feature to the debugger
// means adding a case here; the packet handling, the host library and the web UI
// all stay exactly as they are.
//
//   0x0000_0000  SYS   identity, scratch, uptime, memory status
//   0x0001_0000  LA    logic analyzer control
//   0x0002_0000  LA    capture buffer, one sample per word
//   0x0003_0000  SYN   eight-voice oscillator bank
//   0x0004_0000  SYN   audio ring buffer, two 16-bit samples per word (671 ms)
//   0x0005_0000  MDIO  a window onto the PHY's own registers
//   0x0006_0000  VID   256x240 framebuffer control
//   0x0010_0000  VID   framebuffer, four RGB332 pixels per word (2 pages)
//   0x0008_0000  NES   console control and controllers
//   0x0009_0000  NES   cartridge PRG, 32 KB
//   0x000A_0000  NES   cartridge CHR, 8 KB
//
// Every transaction takes two cycles: the request is latched and any write
// applied on the first, and the result is presented with the acknowledge on the
// second. The second cycle exists for the capture buffer, whose block RAM
// cannot answer in the same cycle it is addressed. Uniform timing is cheaper
// than special-casing one page, and two cycles is nothing next to the
// microseconds a UDP round trip already costs.
//
// MDIO is the exception to "fast": a transaction takes ~40 us. Rather than stall
// a reply for that long, a bus write only starts one and the host polls
// STATUS.busy then reads RDATA. That keeps the network path non-blocking and
// hands the waiting to a client that already retries and times out.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module regfile #(
	parameter [31:0] GATEWARE_VERSION = 32'h0001_0000,
	parameter        LA_DEPTH = 2048,
	parameter        LA_AW    = 11,

	// Passed straight through to console_top. A shipped core image contains one
	// machine, because the whole reason the shell exists is that a core should
	// get the entire chip rather than share it.
	parameter        CORE_NES = 1,
	parameter        CORE_SMS = 1,
	parameter        CORE_MD  = 0,
	parameter        MD_DDR3  = 0,
	parameter        CORE_PS1 = 0
)(
	input  wire        clk,
	input  wire        rst,

	// --- out to DDR3, for a core whose cartridge lives there ------------------
	output wire [23:0]  d_addr,
	output wire         d_req,
	output wire         d_we,
	output wire [127:0] d_wdata,
	output wire [15:0]  d_wmask,
	input  wire         d_ready,
	input  wire [127:0] d_rdata,
	input  wire         d_valid,
	input  wire         d_calibrated,

	input  wire [31:0] bus_addr,
	input  wire [31:0] bus_wdata,
	input  wire        bus_we,
	input  wire        bus_re,
	output reg  [31:0] bus_rdata,
	output wire        bus_ack,
	output reg  [1:0]  bus_err,      // 0 ok, 1 unmapped, 2 read-only

	input  wire [31:0] la_probe,
	// the frame streamer's settings, from the console's control registers
	output wire        stream_en,
	output wire [15:0] stream_port,
	output wire [31:0] stream_base,
	output wire [17:0] stream_words,
	output wire [15:0] stream_rowlen,
	output wire [15:0] stream_stride,
	output wire        stream_ready,
	input  wire        stream_done_tog,
	output wire        stream_direct,
	output wire [31:0] stream_fdata,
	output wire        stream_fvalid,
	input  wire        stream_frd,

	output wire        eth_mdc,
	output wire        mdio_o,
	output wire        mdio_oe,
	input  wire        mdio_i,
	// the ESP32's SPI wires, straight through to the console
	input  wire        esp_sclk,
	input  wire        esp_mosi,
	output wire        esp_miso,
	input  wire        esp_cs_n
);

	localparam PAGE_SYS  = 16'h0000;
	localparam PAGE_LA   = 16'h0001;
	localparam PAGE_LBUF = 16'h0002;
	localparam PAGE_SYN  = 16'h0003;
	localparam PAGE_ABUF = 16'h0004;
	localparam PAGE_MDIO = 16'h0005;
	localparam PAGE_VID  = 16'h0006;
	localparam PAGE_NES  = 16'h0008;
	// The cartridge is bigger than a 64 KB page, so it spans several: PRG covers
	// 0x0009-0x000C and CHR 0x000D-0x000E. The page number becomes the top of
	// the offset, which keeps the host side a plain linear write.
	localparam PAGE_PRG  = 16'h0009;
	localparam PRG_PAGES = 4;
	localparam PAGE_CHR  = 16'h000D;
	localparam CHR_PAGES = 2;
	// Whatever the running core has printed: how a test program reports its
	// result when there is no screen to put it on.
	localparam PAGE_CON  = 16'h000F;
	// The framebuffer is 320x240 now, and 19200 words do not fit one 64 KB page
	// (16384). It cannot grow in place either -- 0x0007 is boxed in by the NES
	// page above it -- so it lives up here where there is room for two.
	localparam PAGE_FB   = 16'h0010;
	// Two pages of block RAM frame, or ten of the DDR3 one (640 x 240 x 16 bits
	// is 600 kB) when the PlayStation is built: that frame is read through the
	// console with a wait on the bus.
	localparam FB_DDR    = (CORE_PS1 != 0);
	localparam FB_PAGES  = FB_DDR ? 10 : 2;

	// --- two-cycle handshake -------------------------------------------------
	reg        pending;
	reg [31:0] req_addr;
	reg        req_we;

	// Acknowledge combinationally on the second cycle. A registered ack would
	// still be asserted a cycle after the requester dropped its strobes, and the
	// same transaction would be accepted twice.

	wire [31:0] sel_addr = pending ? req_addr : bus_addr;
	wire [15:0] page     = sel_addr[31:16];
	wire [15:0] off      = sel_addr[15:0];

	wire new_req = (bus_we || bus_re) && !pending;

	wire in_fb  = (page >= PAGE_FB)  && (page < PAGE_FB  + FB_PAGES);
	wire [31:0] con_fb_rdata; wire con_fb_ack;
	wire [17:0] con_fb_addr = {page[3:0] - PAGE_FB[3:0], off[15:2]};
	wire        con_fb_req  = FB_DDR && pending && in_fb && !req_we;
	// A read of the DDR3 frame waits for the word to come back; the bridge holds
	// its request until the acknowledge, so a wait costs nothing else.
	wire        fb_wait = FB_DDR && pending && in_fb && !req_we && !con_fb_ack;
	assign bus_ack = pending && !fb_wait;

	// --- uptime -------------------------------------------------------------
	reg [15:0] ms_div;
	reg [31:0] uptime_ms;
	always @(posedge clk) begin
		if (rst) begin ms_div <= 0; uptime_ms <= 0; end
		else if (ms_div == 16'd49999) begin ms_div <= 0; uptime_ms <= uptime_ms + 1; end
		else ms_div <= ms_div + 1;
	end

	// --- MDIO ---------------------------------------------------------------
	reg         mdio_start;
	reg         mdio_we;
	reg [4:0]   mdio_phy;
	reg [4:0]   mdio_reg;
	reg [15:0]  mdio_wdata;
	wire [15:0] mdio_rdata;
	wire        mdio_busy;

	mdio_master #(.CLK_DIV(32)) u_mdio (
		.clk(clk), .rst(rst),
		.start(mdio_start), .we(mdio_we),
		.phy_addr(mdio_phy), .reg_addr(mdio_reg),
		.wdata(mdio_wdata), .rdata(mdio_rdata),
		.done(), .busy(mdio_busy),
		.mdc(eth_mdc),
		.mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(mdio_i)
	);

	// --- logic analyzer ------------------------------------------------------
	wire [31:0] la_rdata;
	wire        la_err;
	wire [31:0] lbuf_rdata;
	wire        la_we = new_req && bus_we && (bus_addr[31:16] == PAGE_LA);

	// A PlayStation build carries no logic analyser: the board is there to run
	// the console, and the network is for its picture and its controls. The
	// page reads back as unmapped, which the server's analyser panel reports
	// cleanly; nothing else looks here.
	generate if (CORE_PS1 == 0) begin : g_la
	logic_analyzer #(.DEPTH_MAX(LA_DEPTH), .AW(LA_AW)) u_la (
		.clk(clk), .rst(rst),
		.probe(la_probe),
		.off(off), .we(la_we), .re(1'b0), .wdata(bus_wdata),
		.rdata(la_rdata), .err(la_err),
		.buf_addr(sel_addr[LA_AW+1:2]),
		.buf_rdata(lbuf_rdata)
	);
	end else begin : g_nola
		assign la_rdata   = 32'd0;
		assign la_err     = 1'b1;
		assign lbuf_rdata = 32'd0;
	end endgenerate

	// --- synthesiser ---------------------------------------------------------
	wire [31:0] syn_rdata;
	wire        syn_err;
	wire        syn_we = new_req && bus_we && (bus_addr[31:16] == PAGE_SYN);

	wire [31:0] abuf_rdata;
	wire [15:0] console_audio;

	synth u_synth (
		.clk(clk), .rst(rst),
		.off(off), .we(syn_we), .wdata(bus_wdata),
		.rdata(syn_rdata), .err(syn_err),
		.ext_sample(console_audio),
		.buf_addr(sel_addr[14:2]),
		.buf_rdata(abuf_rdata)
	);

	// --- video ---------------------------------------------------------------
	wire [31:0] vid_rdata, fb_rdata;
	wire        vid_err;
	wire        vid_we = new_req && bus_we && (bus_addr[31:16] == PAGE_VID);

	video #(.FB_DDR(FB_DDR)) u_video (
		.clk(clk), .rst(rst),
		.off(off), .we(vid_we), .wdata(bus_wdata),
		.rdata(vid_rdata), .err(vid_err),
		.fb_addr(sel_addr[16:2]),
		.fb_rdata(fb_rdata),
		.ext_valid(nes_px_valid), .ext_x(nes_px_x),
		.ext_y(nes_px_y), .ext_rgb(nes_px_rgb),
		.frame_count()
	);

	// --- NES ------------------------------------------------------------------
	// The console runs at one PPU dot per system clock here. Real NTSC timing is
	// 5.37 MHz; what the console cares about is the CPU:PPU ratio, which is
	// internal, so the absolute rate only sets how fast the game plays.
	wire [31:0] nes_ctrl_rdata, nes_prg_rdata, nes_chr_rdata;
	wire        nes_px_valid;
	wire [8:0]  nes_px_x, nes_px_y;
	wire [7:0]  nes_px_rgb;

	reg [3:0] nes_div;
	wire nes_ce = (nes_div == 4'd8);       // ~5.5 MHz from 50 MHz
	always @(posedge clk) begin
		if (rst) nes_div <= 4'd0;
		else     nes_div <= nes_ce ? 4'd0 : nes_div + 4'd1;
	end

	wire [31:0] con_rdata;
	wire in_prg = (page >= PAGE_PRG) && (page < PAGE_PRG + PRG_PAGES);
	wire in_chr = (page >= PAGE_CHR) && (page < PAGE_CHR + CHR_PAGES);
	wire [1:0] prg_pg = page[1:0] - PAGE_PRG[1:0];

	// Which 256 kB of the cartridge the write window points at.
	//
	// The window is four 64 kB pages and the page above it is the tile memory,
	// so it cannot simply be made bigger. Writing a megabyte through a single
	// data register instead would be one UDP packet per four bytes, which is
	// forty times the traffic for the same cartridge. A bank register keeps the
	// block writes and removes the ceiling.
	reg [3:0] cart_bank;
	// Pulsed when the last word of a cartridge has been written, so a DDR3
	// cartridge can flush a part-filled line. Nothing else needs it.
	reg       fill_end;

	always @(posedge clk) begin
		fill_end <= 1'b0;
		if (rst) cart_bank <= 4'd0;
		else if (new_req && bus_we && (page == PAGE_NES)) begin
			case (off[15:0])
			16'h0030: cart_bank <= bus_wdata[3:0];
			16'h0034: fill_end  <= 1'b1;
			default: ;
			endcase
		end
	end
	wire [0:0] chr_pg = page[0:0] - PAGE_CHR[0:0];

	// A Mega Drive build gives its block RAM to md_cart instead of to the other
	// machines' cartridge, which would otherwise sit there fully sized and
	// entirely unread. 384 kB of block RAM is not something this part can spend
	// on a memory nothing in the image can address.
	localparam MD_ONLY = (CORE_MD && !CORE_NES && !CORE_SMS);

	console_top #(.CORE_NES(CORE_NES), .CORE_SMS(CORE_SMS), .CORE_MD(CORE_MD),
	              .MD_DDR3(MD_DDR3), .CORE_PS1(CORE_PS1),
	              .PROG_AW(MD_ONLY ? 12 : 18),
	              .CHAR_AW(MD_ONLY ? 12 : 17)) u_console (
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid),
		.d_calibrated(d_calibrated),
		.fill_end(fill_end),
		.clk(clk), .rst(rst), .ce(nes_ce),
		.esp_sclk(esp_sclk), .esp_mosi(esp_mosi), .esp_miso(esp_miso), .esp_cs_n(esp_cs_n),
		.off(off),
		.con_index(off[11:2]),
		.con_rdata(con_rdata),
		.prog_windex({prg_pg, off[15:2]}),
		.md_windex({prg_pg, off[15:2]}),
		// Bank, then page, then word: 4 + 2 + 14 bits is 4 MB of cartridge,
		// which is the largest a Mega Drive ever had.
		.md_windex_full({cart_bank[3:0], prg_pg, off[15:2]}),
		.char_windex({chr_pg, off[15:2]}),
		.ctrl_we(new_req && bus_we && (bus_addr[31:16] == PAGE_NES)),
		.stream_en(stream_en), .stream_port(stream_port), .stream_base(stream_base), .stream_words(stream_words),
		.stream_rowlen(stream_rowlen), .stream_stride(stream_stride),
		.stream_ready(stream_ready), .stream_done_tog(stream_done_tog),
		.stream_direct(stream_direct), .stream_fdata(stream_fdata), .stream_fvalid(stream_fvalid), .stream_frd(stream_frd),
		.prog_we(new_req && bus_we && in_prg),
		.char_we(new_req && bus_we && in_chr),
		.wdata(bus_wdata),
		.audio(console_audio),
		.ctrl_rdata(nes_ctrl_rdata),
		.prog_rdata(nes_prg_rdata),
		.char_rdata(nes_chr_rdata),
		.px_valid(nes_px_valid), .px_x(nes_px_x), .px_y(nes_px_y), .px_rgb(nes_px_rgb),
		.fbr_addr(con_fb_addr), .fbr_req(con_fb_req), .fbr_rdata(con_fb_rdata), .fbr_ack(con_fb_ack)
	);

	// --- scratch -------------------------------------------------------------
	reg [31:0] scratch;

	always @(posedge clk) begin
		mdio_start <= 1'b0;

		if (rst) begin
			pending <= 1'b0;
			scratch <= 32'd0;
		end else begin
			pending <= new_req || fb_wait;
			if (new_req) begin
				req_addr <= bus_addr;
				req_we   <= bus_we;

				if (bus_we) begin
					case (bus_addr[31:16])
					PAGE_SYS: if (bus_addr[15:0] == 16'h0008) scratch <= bus_wdata;
					PAGE_MDIO: case (bus_addr[15:0])
						16'h0004: if (!mdio_busy) begin
								mdio_we    <= bus_wdata[16];
								mdio_phy   <= bus_wdata[12:8];
								mdio_reg   <= bus_wdata[4:0];
								mdio_start <= 1'b1;
							end
						16'h000C: mdio_wdata <= bus_wdata[15:0];
						default: ;
					endcase
					default: ;      // LA writes go straight into the LA module
					endcase
				end
			end
		end
	end

	// --- read mux and error reporting ----------------------------------------
	always @* begin
		bus_rdata = 32'd0;
		bus_err   = 2'd0;

		case (page)
		PAGE_SYS: case (off)
			16'h0000: if (req_we) bus_err = 2'd2; else bus_rdata = 32'h4650_4741; // "FPGA"
			16'h0004: if (req_we) bus_err = 2'd2; else bus_rdata = GATEWARE_VERSION;
			16'h0008: bus_rdata = scratch;
			16'h000C: if (req_we) bus_err = 2'd2; else bus_rdata = uptime_ms;
			// MEM: whether this image has DDR3 in it, and whether the controller
			// finished training. Without this a memory that never calibrates and
			// a console that was never going to draw look identical from the
			// outside -- both are a black screen -- and the board gets blamed for
			// the design or the other way round. One bit ends that.
			16'h0010: if (req_we) bus_err = 2'd2;
			          else bus_rdata = {30'd0, (MD_DDR3 != 0) || (CORE_PS1 != 0), d_calibrated};
			default:  bus_err = 2'd1;
		endcase

		PAGE_LA: begin
			bus_rdata = la_rdata;
			if (la_err) bus_err = 2'd1;
		end

		PAGE_LBUF: if (req_we) bus_err = 2'd2; else bus_rdata = lbuf_rdata;

		PAGE_SYN: begin
			bus_rdata = syn_rdata;
			if (syn_err) bus_err = 2'd1;
		end

		PAGE_ABUF: if (req_we) bus_err = 2'd2; else bus_rdata = abuf_rdata;

		PAGE_VID: begin
			bus_rdata = vid_rdata;
			if (vid_err) bus_err = 2'd1;
		end


		PAGE_NES: bus_rdata = nes_ctrl_rdata;
		PAGE_CON: if (req_we) bus_err = 2'd2; else bus_rdata = con_rdata;

		PAGE_MDIO: case (off)
			16'h0000: if (req_we) bus_err = 2'd2; else bus_rdata = 32'h4D44_0001; // "MD"
			16'h0004: bus_rdata = {15'd0, mdio_we, 3'd0, mdio_phy, 3'd0, mdio_reg};
			16'h0008: if (req_we) bus_err = 2'd2; else bus_rdata = {31'd0, mdio_busy};
			16'h000C: bus_rdata = {16'd0, mdio_wdata};
			16'h0010: if (req_we) bus_err = 2'd2; else bus_rdata = {16'd0, mdio_rdata};
			default:  bus_err = 2'd1;
		endcase

		default: bus_err = 2'd1;
		endcase

		// The cartridge spans a range of pages rather than one, which a case on
		// the page number cannot express, so it is decoded after it.
		if (in_fb)  begin bus_rdata = FB_DDR ? con_fb_rdata : fb_rdata; bus_err = req_we ? 2'd2 : 2'd0; end
		if (in_prg) begin bus_rdata = nes_prg_rdata; bus_err = 2'd0; end
		if (in_chr) begin bus_rdata = nes_chr_rdata; bus_err = 2'd0; end
	end

endmodule

`default_nettype wire
