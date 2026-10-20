`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pce_top.v - a NEC PC Engine / TurboGrafx-16: the HuC6280 with its sound and timer, the
// HuC6270 video controller, the HuC6260 colour encoder, the pad port, a HuCard.
//
// --- the physical map (the processor's 21-bit address) ------------------------------------
//
//   $000000-$0FFFFF   the HuCard, through the cartridge port (DDR3 behind a cache outside)
//   $1F0000-$1F1FFF   8 kB of work RAM (mirrored through $1F7FFF)
//   $1FE000-$1FE3FF   VDC     $1FE400-$1FE7FF   VCE     $1FE800-$1FEBFF   PSG
//   $1FEC00-$1FEFFF   timer   $1FF000-$1FF3FF   pads    $1FF400-$1FF7FF   interrupt control
//   $1FF800-$1FFBFF   CD-ROM: nobody there, reads $FF
//
// A HuCard of 384 or 768 kB is laid out as the chip sees those: the first 256 (512) kB, then
// the rest twice; other sizes repeat through their power of two. The loader says the size.
//
// --- clocks ------------------------------------------------------------------------------------
//
// The processor's 7.16 MHz is an enable from the system clock; the chip's low speed is the
// processor's own business (four of them a cycle). A cartridge byte not in the cache holds
// the enable until it comes. The VCE makes the 21.48 MHz master enable and the dot clock
// from the same system clock; the PSG its 3.58 MHz.
//
// --- the pad port --------------------------------------------------------------------------------
//
// $1FF000: a write sets SEL (bit 0) and CLR (bit 1); a read gives four buttons active low in
// the low nibble -- SEL high: left, down, right, up; SEL low: run, select, II, I (the pad's
// 74LS157: select 1 = the directions, as MAME's pce_ctrl/joypad2.cpp wires it) -- and 1011
// above. A five-port multitap sits on the port as the games expect: CLR resets it to the
// first pad and SEL rising moves it on. joy1 / joy2 are {left, down, right, up, run, select,
// II, I}, 1 = pressed.
//
// The timer: a 7-bit counter stepped every 1024 processor clocks, reloaded from $0C00 when
// it passes 0 and raising its interrupt; $0C01 bit 0 runs it. Interrupts: $1402 masks
// (bit 0 IRQ2, 1 IRQ1 -- the VDC --, 2 the timer; 1 = off), $1403 reads them (same bits) and a
// write to it acknowledges the timer.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module pce_top #(
	parameter CLK_HZ = 50_000_000
) (
	input  wire        clk,
	input  wire        rst,
	input  wire        pause,

	// the HuCard, with latency
	output reg  [19:0] rom_addr,
	output reg         rom_req,
	input  wire        rom_ack,
	input  wire [7:0]  rom_data,
	input  wire [19:0] rom_size,      // bytes (the loader's)

	input  wire [7:0]  joy1,
	input  wire [7:0]  joy2,

	// the picture: a dot at a time, 9-bit GGGRRRBBB, in a window of disp_w x disp_h
	output wire [8:0]  px_rgb,
	output wire        px_en,
	output wire [9:0]  px_x,
	output wire [8:0]  px_y,
	output wire [9:0]  disp_w,
	output wire [8:0]  disp_h,
	output wire [1:0]  dot_rate,
	output wire        frame_start,

	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	output wire [15:0] dbg_pc
);

	// --- the processor's clock, and the cartridge's wait ---------------------------------------
	localparam [31:0] CPU_HZ = 32'd7_159_090;
	reg  [31:0] acc; reg cpu_ce_raw;
	always @(posedge clk) begin
		cpu_ce_raw <= 1'b0;
		if (rst) acc <= 0;
		else if (acc + CPU_HZ >= CLK_HZ) begin acc <= acc + CPU_HZ - CLK_HZ; cpu_ce_raw <= 1'b1; end
		else acc <= acc + CPU_HZ;
	end
	reg        rom_pend, rom_issued;
	reg  [7:0] rom_q;
	wire       cpu_ce = cpu_ce_raw && !rom_pend && !pause;

	// --- the processor ------------------------------------------------------------------------------
	wire [20:0] c_addr; wire [7:0] c_dout; wire c_we, c_rd, c_fast;
	reg  [7:0]  c_din;
	wire        irq1;
	reg         irq_timer;
	reg  [2:0]  irq_mask;
	huc6280 u_cpu (
		.clk(clk), .rst(rst), .ce(cpu_ce),
		.addr(c_addr), .din(c_din), .dout(c_dout), .we(c_we), .rd(c_rd),
		.irq1(irq1 && !irq_mask[1]), .irq2(1'b0), .irq_timer(irq_timer && !irq_mask[2]), .nmi(1'b0),
		.fast(c_fast), .sync(),
		.dbg_a(), .dbg_x(), .dbg_y(), .dbg_s(), .dbg_p(), .dbg_pc(dbg_pc), .dbg_mpr1()
	);

	// --- the map ------------------------------------------------------------------------------------
	wire is_rom  = (c_addr[20] == 1'b0);
	wire is_ram  = (c_addr[20:15] == 6'b111110);                 // $1F0000-$1F7FFF
	wire is_io   = (c_addr[20:13] == 8'hFF);
	wire sel_vdc = is_io && (c_addr[12:10] == 3'd0);
	wire sel_vce = is_io && (c_addr[12:10] == 3'd1);
	wire sel_psg = is_io && (c_addr[12:10] == 3'd2);
	wire sel_tim = is_io && (c_addr[12:10] == 3'd3);
	wire sel_pad = is_io && (c_addr[12:10] == 3'd4);
	wire sel_irq = is_io && (c_addr[12:10] == 3'd5);
	wire we_pulse = cpu_ce && c_we;
	wire rd_pulse = cpu_ce && c_rd;

	// --- the HuCard: the request goes out as the processor asks; its clock waits for the byte ----
	// (384 and 768 kB cards: the first 256 / 512 kB, then the last 128 / 256 kB twice)
	// (the size rounded up to a power of two: a card is one, a loader's odd image reads $FF past its end)
	wire [19:0] rom_mask = rom_size > 20'h80000 ? 20'hFFFFF : rom_size > 20'h40000 ? 20'h7FFFF : rom_size > 20'h20000 ? 20'h3FFFF :
	                       rom_size > 20'h10000 ? 20'h1FFFF : rom_size > 20'h8000 ? 20'hFFFF : rom_size > 20'h4000 ? 20'h7FFF : 20'h3FFF;
	wire        odd_size = (rom_size == 20'h60000) || (rom_size == 20'hC0000);
	wire [19:0] rom_half = rom_size == 20'h60000 ? 20'h40000 : 20'h80000;
	wire [19:0] rom_tail = rom_size == 20'h60000 ? 20'h1FFFF : 20'h3FFFF;
	wire [19:0] rom_phys = !odd_size ? (c_addr[19:0] & rom_mask) :
	                       (c_addr[19:0] < rom_half) ? c_addr[19:0] : rom_half + ((c_addr[19:0] - rom_half) & rom_tail);
	// The processor puts the address out at one of its cycles and takes the byte at the next;
	// the request goes the clock the address appears, so a cached byte is back inside the cycle
	// (seven clocks) and only a miss holds the clock.
	always @(posedge clk) begin
		rom_req <= 1'b0;
		if (rst) begin rom_pend <= 1'b0; rom_issued <= 1'b0; rom_q <= 8'hFF; rom_addr <= 20'd0; end
		else begin
			if (cpu_ce) rom_issued <= 1'b0;
			else if (c_rd && is_rom && !rom_issued && !rom_pend) begin rom_addr <= rom_phys; rom_req <= 1'b1; rom_pend <= 1'b1; rom_issued <= 1'b1; end
			if (rom_ack && rom_pend) begin rom_q <= rom_data; rom_pend <= 1'b0; end
		end
	end

	// --- work RAM -----------------------------------------------------------------------------------
	(* ram_style = "block" *) reg [7:0] wram [0:8191];
	reg [7:0] wram_q;
	always @(posedge clk) begin
		if (we_pulse && is_ram) wram[c_addr[12:0]] <= c_dout;
		wram_q <= wram[c_addr[12:0]];
	end

	// --- the timer --------------------------------------------------------------------------------------
	reg [6:0]  tim_reload;
	reg        tim_on;
	reg [16:0] tim_cnt;               // 1024 clocks a step, 7 bits of steps
	always @(posedge clk) begin
		if (rst) begin tim_reload <= 7'd0; tim_on <= 1'b0; tim_cnt <= 17'd0; irq_timer <= 1'b0; end
		else begin
			if (we_pulse && sel_tim) begin
				if (!c_addr[0]) tim_reload <= c_dout[6:0];
				else begin
					if (c_dout[0] && !tim_on) tim_cnt <= {tim_reload, 10'd0} | 17'h3FF;
					tim_on <= c_dout[0];
				end
			end
			if (we_pulse && sel_irq && c_addr[1:0] == 2'd3) irq_timer <= 1'b0;
			if (cpu_ce_raw && tim_on) begin
				if (tim_cnt == 17'd0) begin tim_cnt <= {tim_reload, 10'd0} | 17'h3FF; irq_timer <= 1'b1; end
				else tim_cnt <= tim_cnt - 17'd1;
			end
		end
	end

	// --- the pads ---------------------------------------------------------------------------------------
	reg       pad_sel, pad_clr;
	reg [2:0] pad_n;                  // the multitap's port
	wire [7:0] joy = (pad_n == 3'd0) ? joy1 : (pad_n == 3'd1) ? joy2 : 8'd0;
	wire [3:0] pad_nib = pad_clr ? 4'h0 : pad_sel ? ~{joy[7], joy[6], joy[5], joy[4]} : ~{joy[3], joy[2], joy[1], joy[0]};
	always @(posedge clk) begin
		if (rst) begin pad_sel <= 1'b0; pad_clr <= 1'b0; pad_n <= 3'd0; end
		else if (we_pulse && sel_pad) begin
			pad_sel <= c_dout[0]; pad_clr <= c_dout[1];
			if (c_dout[1]) pad_n <= 3'd0;
			else if (c_dout[0] && !pad_sel && pad_n != 3'd5) pad_n <= pad_n + 3'd1;
		end
	end

	// --- interrupt control ----------------------------------------------------------------------------------
	always @(posedge clk) begin
		if (rst) irq_mask <= 3'd0;
		else if (we_pulse && sel_irq && c_addr[1:0] == 2'd2) irq_mask <= c_dout[2:0];
	end

	// --- the video chips ---------------------------------------------------------------------------------
	wire dot_ce, line_start, frame_start_v; wire [9:0] dot; wire [8:0] line;
	wire [8:0] vdc_idx; wire vdc_en; wire [9:0] vdc_x; wire [8:0] vdc_y;
	wire [7:0] vdc_q, vce_q;
	reg  [9:0] px_x_q, px_x_q2; reg [8:0] px_y_q, px_y_q2;
	pce_vdc u_vdc (
		.clk(clk), .rst(rst),
		.sel(sel_vdc), .a(c_addr[1:0]), .we(we_pulse), .rd(rd_pulse), .d(c_dout), .q(vdc_q), .irq(irq1),
		.dot_ce(dot_ce), .line_start(line_start), .frame_start(frame_start_v), .dot(dot), .line(line),
		.px_idx(vdc_idx), .px_en(vdc_en), .px_x(vdc_x), .px_y(vdc_y), .disp_w(disp_w), .disp_h(disp_h), .disp_start(frame_start)
	);
	pce_vce #(.CLK_HZ(CLK_HZ)) u_vce (
		.clk(clk), .rst(rst),
		.sel(sel_vce), .a(c_addr[2:0]), .we(we_pulse), .rd(rd_pulse), .d(c_dout), .q(vce_q),
		.dot_ce(dot_ce), .line_start(line_start), .frame_start(frame_start_v), .dot(dot), .line(line), .dot_rate(dot_rate),
		.idx(vdc_idx), .idx_en(vdc_en), .rgb(px_rgb), .rgb_en(px_en)
	);
	// (the colour comes two clocks after the index: the position goes along with it)
	always @(posedge clk) begin px_x_q <= vdc_x; px_y_q <= vdc_y; px_x_q2 <= px_x_q; px_y_q2 <= px_y_q; end
	assign px_x = px_x_q2; assign px_y = px_y_q2;

	// --- the sound -------------------------------------------------------------------------------------------
	pce_psg #(.CLK_HZ(CLK_HZ)) u_psg (
		.clk(clk), .rst(rst), .sel(sel_psg), .a(c_addr[3:0]), .we(we_pulse), .d(c_dout),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	// --- what the processor reads --------------------------------------------------------------------------
	always @(*) begin
		if (is_rom)       c_din = rom_q;
		else if (is_ram)  c_din = wram_q;
		else if (sel_vdc) c_din = vdc_q;
		else if (sel_vce) c_din = vce_q;
		else if (sel_tim) c_din = {1'b0, tim_cnt[16:10]};
		else if (sel_pad) c_din = {4'b1011, pad_nib};
		else if (sel_irq) c_din = (c_addr[1:0] == 2'd2) ? {5'd0, irq_mask} : (c_addr[1:0] == 2'd3) ? {5'd0, irq_timer, irq1, 1'b0} : 8'd0;
		else              c_din = 8'hFF;
	end

endmodule

`default_nettype wire
