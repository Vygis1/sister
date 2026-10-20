//////////////////////////////////////////////////////////////////////////////////
// pc_top.v - the PC: a 486 (ao486) with VGA, IDE, PS/2, the timers, interrupt controller, DMA
// and CMOS clock of an AT -- 486Tang's system.sv (rtl/pc/README.md) with what touches the board
// taken out and ours put in:
//   memory     MiSTer's L2 cache and DDR3 (pc_ddr64) instead of 486Tang's SDRAM; the picture's two ports beside it
//   the BIOS   put into memory by the ESP32 through the fill (pc_ddr64's host port), the CPU held
//              in reset until it says run -- instead of 486Tang's loader reading the SD card
//   the disk   served by the ESP32 (pc_disk) instead of an SD card on the FPGA
//   config     the ESP32 writes the IDE's identify data and the CMOS (mgmt) -- 486Tang read them
//              out of a sector of its card
//   keyboard   bytes from the ESP32 (the PC's keyboard, forwarded) into a PS/2 device
//   picture    pc_fb: DDR3 and out at 640x480 at 60 Hz
//   sound      486Tang's Sound Blaster 16 (220h, IRQ 5, DMA 1 / 5) and OPL3 (388h), on this clock, with
//              the PC speaker: stereo to HDMI
//
// The host's registers (console_top page 8, at 0x7000; the buffer at 0x8000):
//   7000  CTRL       [0] run (the CPU out of reset)  [1] reset the rest (the IDE, the CMOS, the VGA ...:
//                    a start begins from nothing the last one wrote)
//   7004  KBD        w: a byte to the keyboard (a scan code, set 2)
//   7008  MGMT_ADDR  [15:0]: F0xx the IDE 0's identify words, F4xx the CMOS, ...
//   700C  MGMT_DATA  w: written at MGMT_ADDR
//   7010  FILL_BASE  the byte address the fill (the loader's cartridge path) writes from
//   7014  STAT       r: {the VGA picture's height[25:16], width[10:0]}
//   7018  DBG        r: the CPU's CS:EIP (CS << 16 | EIP[15:0])
//   7020  DSK_REQ    r: {valid, write, -, CD audio wants a sector [27], the CD drive's request [26:24],
//                       sectors[19:16]}   7024  DSK_LBA  r
//   7028  DSK_DONE   w: the piece is done (pc_disk); [3:0] the sectors put in the buffer (read ahead; 0: as asked)
//   701C  IRQS       r: {timer (IRQ0) interrupts, keyboard (IRQ1) interrupts} (16 bits each, counting)
//   7044  MARGIN     the border round the picture on HDMI (a television crops the edges): [6:0] left and
//                    right, [22:16] top and bottom, in pixels (from power-up 0: the full 640x480 -- a border squeezes the picture; a TV that crops wants its "unscaled" / "just scan" setting)
//   7048  PERF       r: clocks counting; w: all four counters back to 0
//   704C             r: clocks the CPU's memory port waited on the L2 cache (a request held, busy)
//   7050             r: clocks the L2 cache waited on DDR3 (a miss, or a write going through)
//   7054             r: the L2 cache's DDR3 reads (its misses)
//                    (read twice a second apart and subtract: where the CPU's time goes)
//   705C  MOUSE      w: a byte from the mouse (the ESP32's packets, 3 bytes each: buttons, dx, dy); the
//                    mouse's answers to the driver's commands are this module's (below)
//   7058  BIOSDBG    r: how many bytes the BIOS has written to its debug ports (0x400-0x403: the Bochs
//                    BIOS's panic and info text) -- the last 1024 of them at 9000-9FFC, one a word
//                    (byte n at 0x9000 + 4 * (n mod 1024)). A BIOS that stops at F000:0C93 has panicked.
//   A000-A018 CD_REG     the CD drive's controller registers 0-6 (ide_hps.v's management port, 16 bits)
//   B000-BFFC CD_AUDIO   w: a CD audio sample {right, left} into the 44.1 kHz FIFO (the address is ignored)
//   C000-FFFC CD_BUF     the CD drive's sector buffer, a 32-bit word an address (16 kB)
//   7030  HR_LINE    w: a DDR3 line to read (a line address: the picture is at 0x800000, 128 a row)
//   7034-7040        r: its four words (tools/pc/pcgrab.py: the screen, over the link)
//   8000-8FFF  the disk buffer, eight sectors
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module pc_top #(
	parameter CLK_HZ = 50_000_000
)(
	input  wire         clk,
	input  wire         rst,

	// the host (console_top's page 8)
	input  wire         h_we,
	input  wire [15:0]  h_off,
	input  wire [31:0]  h_wdata,
	output reg  [31:0]  h_rdata,
	input  wire         fill_we,
	input  wire [21:0]  fill_windex,
	input  wire [31:0]  fill_wdata,

	// DDR3 (ddr3_mem's port)
	output wire [23:0]  d_addr,
	output wire         d_req,
	output wire         d_we,
	output wire [127:0] d_wdata,
	output wire [15:0]  d_wmask,
	input  wire         d_ready,
	input  wire [127:0] d_rdata,
	input  wire         d_valid,

	// HDMI
	input  wire         pclk,
	input  wire [9:0]   vid_x,
	input  wire [9:0]   vid_y,
	input  wire         vid_req,
	output wire [23:0]  vid_rgb,

	output reg  [15:0]  audio_l,
	output reg  [15:0]  audio_r
);
	wire [15:0] cd_mgmt_q; wire [31:0] cd_buf_q;   // (declared up here: used above where it is made)
	reg [7:0] dbg_ring [0:1023]; reg [31:0] dbg_n; reg [7:0] dbg_q;   // (declared up here: used above where it is made)
	reg [31:0] pf_clk, pf_l2w, pf_ddr, pf_miss;   // (declared up here: used above where it is made)
	localparam [27:0] RATE = CLK_HZ;

	// --- the host's registers ---------------------------------------------------------------------
	// (debugging from the host: how many timer and keyboard interrupts, and a DDR3 line read)
	reg [15:0] n_irq0, n_irq1; reg irq0_r, irq1_r;
	reg [15:0] pk_opl = 16'd0, pk_mix = 16'd0;
	reg [15:0] n_fm_wr = 16'd0, n_sb_wr = 16'd0, n_fm_rd = 16'd0, n_sb_rd = 16'd0, n_irq7 = 16'd0, n_sb_dma = 16'd0; reg irq7_r = 1'b0;
	reg [23:0] hr_addr; reg hr_req; reg [127:0] hr_data;
	wire       hr_go = h_we && h_off == 16'h7030;

	reg        run;
	reg  [6:0] margin_x, margin_y;
	reg  [5:0] soft_rst;
	initial soft_rst = 6'd0;
	reg [15:0] mgmt_address;
	reg [31:0] mgmt_writedata;
	reg        mgmt_write;
	reg [31:0] fill_base;
	wire       fill_lost;
	reg  [7:0] kbd_data; reg kbd_we;
	reg  [7:0] mouse_host_data; reg mouse_host_we;
	reg        dsk_done; reg [3:0] dsk_done_n;
	wire [31:0] dsk_req_hd, dsk_lba, dsk_buf_q;
	// DSK_REQ: the hard disk's request, the CD drive's ([26:24]) and CD audio's room for a sector ([27])
	wire        cdda_req; wire [2:0] cd_request;          // (pc_cdda: room for a CD audio sector)
	wire [31:0] dsk_req = {dsk_req_hd[31:28], cdda_req, cd_request, dsk_req_hd[23:0]};
	wire        dsk_buf_we = h_we && h_off[15:12] == 4'h8;
	wire [10:0] pic_w; wire [9:0] pic_h;
	wire [31:0] debug_eip; wire [15:0] debug_cs;
	always @(posedge clk) begin
		mgmt_write <= 1'b0; kbd_we <= 1'b0; dsk_done <= 1'b0; mouse_host_we <= 1'b0;
		if (soft_rst != 6'd0) soft_rst <= soft_rst - 6'd1;
		if (rst) begin run <= 1'b0; fill_base <= 32'h000F0000; margin_x <= 7'd0; margin_y <= 7'd0; end
		else if (h_we) case (h_off)
			16'h7000: begin run <= h_wdata[0]; if (h_wdata[1]) soft_rst <= 6'd63; end
			16'h7004: begin kbd_data <= h_wdata[7:0]; kbd_we <= 1'b1; end
			16'h705C: begin mouse_host_data <= h_wdata[7:0]; mouse_host_we <= 1'b1; end
			16'h7008: mgmt_address <= h_wdata[15:0];
			16'h700C: begin mgmt_writedata <= h_wdata; mgmt_write <= 1'b1; end
			16'h7010: fill_base <= h_wdata;
			16'h7044: begin margin_x <= h_wdata[6:0]; margin_y <= h_wdata[22:16]; end
			16'h7028: begin dsk_done <= 1'b1; dsk_done_n <= h_wdata[3:0]; end
			default: ;
		endcase
	end
	always @(*) begin
		case (h_off)
		16'h7000: h_rdata = {31'd0, run};
		16'h7014: h_rdata = {6'd0, pic_h, 5'd0, pic_w};
		16'h7018: h_rdata = {debug_cs, debug_eip[15:0]};
		16'h7044: h_rdata = {9'd0, margin_y, 9'd0, margin_x};
		16'h701C: h_rdata = {n_irq0, n_irq1};
		16'h7048: h_rdata = pf_clk;
		16'h704C: h_rdata = pf_l2w;
		16'h7050: h_rdata = pf_ddr;
		16'h7054: h_rdata = pf_miss;
		16'h7058: h_rdata = dbg_n;
		16'h7060: h_rdata = {n_fm_wr, n_sb_wr};        // the sound chips' port writes: the OPL at 388h, the Sound Blaster at 220h
		16'h7064: h_rdata = {n_irq7, n_sb_dma};        // the Sound Blaster's interrupts (IRQ 7) and DMA transfers
		16'h7068: h_rdata = {n_fm_rd, n_sb_rd};        // and their port reads (a game's detection reads them)
		16'h7070: h_rdata = {pk_opl, pk_mix};           // the loudest sample since it was cleared (a write): the OPL3's, the mix's
		16'h706C: h_rdata = {31'd0, fill_lost};
		16'h7034: h_rdata = hr_data[31:0];
		16'h7038: h_rdata = hr_data[63:32];
		16'h703C: h_rdata = hr_data[95:64];
		16'h7040: h_rdata = hr_data[127:96];
		16'h7020: h_rdata = dsk_req;
		16'h7024: h_rdata = dsk_lba;
		default:  h_rdata =
		                    (h_off[15:12] == 4'h8) ? dsk_buf_q : (h_off[15:12] == 4'h9) ? {24'd0, dbg_q} :
		                    (h_off[15:8] == 8'hA0) ? {16'd0, cd_mgmt_q} : (h_off[15:14] == 2'b11) ? cd_buf_q :
		                    32'h5043_0001;   // ("PC")
		endcase
	end

	// the CPU's reset: the host's run; and a second clock of it for the rest, which run from power-up
	// (the IDE and the CMOS must take the host's configuration before the CPU starts)
	reg cpu_reset_n;
	always @(posedge clk) cpu_reset_n <= run && !rst;
	reg [15:0] rstv;
	always @(posedge clk) rstv <= {16{rst || soft_rst != 6'd0}};

	// --- the CPU ----------------------------------------------------------------------------------
	wire        a20_enable;
	wire        interrupt_done, interrupt_do; wire [7:0] interrupt_vector;
	reg  [15:0] interrupt;
	wire        cpu_io_read_do, cpu_io_write_do, cpu_io_read_done, cpu_io_write_done;
	wire [15:0] cpu_io_read_address, cpu_io_write_address;
	wire  [2:0] cpu_io_read_length, cpu_io_write_length;
	wire [31:0] cpu_io_read_data, cpu_io_write_data;
	wire [29:0] avm_address; wire [31:0] avm_writedata, avm_readdata; wire [3:0] avm_byteenable, avm_burstcount;
	wire        avm_write, avm_read, avm_waitrequest, avm_readdatavalid;
	wire [23:0] dma_address; wire dma_16bit, dma_write, dma_read, dma_readdatavalid, dma_waitrequest;
	wire [15:0] dma_writedata, dma_readdata;

	ao486 ao486 (
		.clk(clk), .rst_n(cpu_reset_n), .cache_disable(1'b0),
		.avm_address(avm_address), .avm_writedata(avm_writedata), .avm_byteenable(avm_byteenable),
		.avm_burstcount(avm_burstcount), .avm_write(avm_write), .avm_read(avm_read),
		.avm_waitrequest(avm_waitrequest), .avm_readdatavalid(avm_readdatavalid), .avm_readdata(avm_readdata),
		.interrupt_do(interrupt_do), .interrupt_vector(interrupt_vector), .interrupt_done(interrupt_done),
		.io_read_do(cpu_io_read_do), .io_read_address(cpu_io_read_address), .io_read_length(cpu_io_read_length),
		.io_read_data(cpu_io_read_data), .io_read_done(cpu_io_read_done),
		.io_write_do(cpu_io_write_do), .io_write_address(cpu_io_write_address), .io_write_length(cpu_io_write_length),
		.io_write_data(cpu_io_write_data), .io_write_done(cpu_io_write_done),
		.a20_enable(a20_enable),
		.dma_address(dma_address), .dma_16bit(dma_16bit), .dma_write(dma_write), .dma_writedata(dma_writedata),
		.dma_read(dma_read), .dma_readdata(dma_readdata), .dma_readdatavalid(dma_readdatavalid), .dma_waitrequest(dma_waitrequest),
		.debug_eip(debug_eip), .debug_cs(debug_cs)
	);

	// --- memory: MiSTer's ao486 L2 cache (32 kB, 4-way, write-through; the VGA window to vga.v, the
	// BIOSes read only) and behind it DDR3 (pc_ddr64). Without it every miss of the CPU's own small
	// caches was a DDR3 round trip: measured, DOS and Doom's start-up ran at a fraction of a 486's pace.
	wire [16:0] vga_address; wire [7:0] vga_readdata, vga_writedata; wire vga_read, vga_write;
	wire [2:0] vga_memmode; wire [5:0] video_wr_seg, video_rd_seg;
	wire [24:0] ddr_addr; wire [63:0] ddr_din, ddr_dout; wire [7:0] ddr_be, ddr_burst; wire ddr_busy, ddr_rd, ddr_we, ddr_dout_ready;
	l2_cache #(.ADDRBITS(24)
	) u_l2 (
		.CLK(clk), .RESET(!cpu_reset_n), .DISABLE(1'b0),
		.CPU_ADDR(avm_address), .CPU_DIN(avm_writedata), .CPU_DOUT(avm_readdata), .CPU_DOUT_READY(avm_readdatavalid),
		.CPU_BE(avm_byteenable), .CPU_BURSTCNT(avm_burstcount), .CPU_BUSY(avm_waitrequest),
		.CPU_RD(avm_read), .CPU_WE(avm_write),
		.DDRAM_ADDR(ddr_addr), .DDRAM_DIN(ddr_din), .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_dout_ready),
		.DDRAM_BE(ddr_be), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_BUSY(ddr_busy), .DDRAM_RD(ddr_rd), .DDRAM_WE(ddr_we),
		.VGA_ADDR(vga_address), .VGA_DIN(vga_readdata), .VGA_DOUT(vga_writedata), .VGA_MODE(vga_memmode),
		.VGA_RD(vga_read), .VGA_WE(vga_write), .VGA_WR_SEG(video_wr_seg), .VGA_RD_SEG(video_rd_seg),
		.VGA_FB_EN(fb_en), .uma_ram(1'b0)
	);

	// the performance counters (PERF, above)
	always @(posedge clk) begin
		if (rst || (h_we && h_off == 16'h7048)) begin pf_clk <= 32'd0; pf_l2w <= 32'd0; pf_ddr <= 32'd0; pf_miss <= 32'd0; end
		else begin
			pf_clk <= pf_clk + 32'd1;
			if ((avm_read || avm_write) && avm_waitrequest) pf_l2w <= pf_l2w + 32'd1;
			if (ddr_busy) pf_ddr <= pf_ddr + 32'd1;
			if (ddr_rd && !ddr_busy) pf_miss <= pf_miss + 32'd1;
		end
	end

	// the DDR3 port, three ways: the picture's scanout first, its capture, then the CPU
	wire [95:0]  pa_addr; wire [3:0] pa_req, pa_we, pa_ready, pa_valid; wire [511:0] pa_wdata, pa_rdata; wire [63:0] pa_wmask;
	mem_arb #(.PORTS(4), .AW(24)) u_arb (
		.clk(clk), .rst(rst),
		.p_addr(pa_addr), .p_req(pa_req), .p_we(pa_we), .p_wdata(pa_wdata), .p_wmask(pa_wmask),
		.p_ready(pa_ready), .p_rdata(pa_rdata), .p_valid(pa_valid),
		.m_addr(d_addr), .m_req(d_req), .m_we(d_we), .m_wdata(d_wdata), .m_wmask(d_wmask),
		.m_ready(d_ready), .m_rdata(d_rdata), .m_valid(d_valid)
	);
	pc_ddr64 #(.BASE(24'h000000)
	) u_mem (
		.clk(clk), .rst(rst),
		.a_addr(ddr_addr), .a_din(ddr_din), .a_be(ddr_be), .a_burst(ddr_burst),
		.a_rd(ddr_rd), .a_we(ddr_we), .a_busy(ddr_busy), .a_dout(ddr_dout), .a_dout_ready(ddr_dout_ready),
		.h_we(fill_we), .h_addr(fill_base + {8'd0, fill_windex, 2'b00}), .h_wdata(fill_wdata), .h_lost(fill_lost),
		.m_addr(pa_addr[71:48]), .m_req(pa_req[2]), .m_we(pa_we[2]), .m_wdata(pa_wdata[383:256]), .m_wmask(pa_wmask[47:32]),
		.m_ready(pa_ready[2]), .m_rdata(pa_rdata[383:256]), .m_valid(pa_valid[2])
	);

	// --- the I/O bus ------------------------------------------------------------------------------
	wire [15:0] iobus_address; wire iobus_write, iobus_read; wire [2:0] iobus_datasize; wire [31:0] iobus_writedata;

	// the BIOS's debug ports (BIOSDBG, above): what it writes to 0x400-0x403, the last 1024 bytes
	always @(posedge clk) begin
		if (rst) dbg_n <= 32'd0;
		else if (iobus_write && iobus_address[15:2] == 14'h0100) begin
			dbg_ring[dbg_n[9:0]] <= iobus_writedata[7:0]; dbg_n <= dbg_n + 32'd1;
		end
		dbg_q <= dbg_ring[h_off[11:2]];
	end

	reg ide0_cs, ide1_cs, floppy0_cs, dma_master_cs, dma_page_cs, dma_slave_cs, pic_master_cs, pic_slave_cs,
	    pit_cs, ps2_io_cs, ps2_ctl_cs, rtc_cs, vga_b_cs, vga_c_cs, vga_d_cs, sysctl_cs, fm_cs, sb_cs, fpu_cs;
	always @(posedge clk) begin
		ide0_cs       <= ({iobus_address[15:3], 3'd0} == 16'h01F0) || (iobus_address == 16'h03F6);
		ide1_cs       <= ({iobus_address[15:3], 3'd0} == 16'h0170) || (iobus_address == 16'h0376);
		floppy0_cs    <= ({iobus_address[15:2], 2'd0} == 16'h03F0) || ({iobus_address[15:1], 1'd0} == 16'h03F4) || (iobus_address == 16'h03F7);
		dma_master_cs <= ({iobus_address[15:5], 5'd0} == 16'h00C0);
		dma_page_cs   <= ({iobus_address[15:4], 4'd0} == 16'h0080);
		dma_slave_cs  <= ({iobus_address[15:4], 4'd0} == 16'h0000);
		pic_master_cs <= ({iobus_address[15:1], 1'd0} == 16'h0020);
		pic_slave_cs  <= ({iobus_address[15:1], 1'd0} == 16'h00A0);
		pit_cs        <= ({iobus_address[15:2], 2'd0} == 16'h0040) || (iobus_address == 16'h0061);
		ps2_io_cs     <= ({iobus_address[15:3], 3'd0} == 16'h0060);
		ps2_ctl_cs    <= ({iobus_address[15:4], 4'd0} == 16'h0090);
		rtc_cs        <= ({iobus_address[15:1], 1'd0} == 16'h0070);
		vga_b_cs      <= ({iobus_address[15:4], 4'd0} == 16'h03B0);
		vga_c_cs      <= ({iobus_address[15:4], 4'd0} == 16'h03C0);
		vga_d_cs      <= ({iobus_address[15:4], 4'd0} == 16'h03D0);
		fm_cs         <= ({iobus_address[15:2], 2'd0} == 16'h0388);
		sb_cs         <= ({iobus_address[15:4], 4'd0} == 16'h0220);
		sysctl_cs     <= (iobus_address == 16'h8888);
	end
	always @(posedge clk) fpu_cs <= 1'b0;

	wire [7:0] floppy0_readdata, pit_readdata, ps2_readdata, rtc_readdata, dma_io_readdata, pic_readdata, vga_io_readdata, sound_readdata;
	wire [31:0] ide0_readdata, ide1_readdata;
	wire [7:0] iobus_readdata8 =
		floppy0_cs                             ? floppy0_readdata :
		(dma_master_cs|dma_slave_cs|dma_page_cs) ? dma_io_readdata :
		(pic_master_cs|pic_slave_cs)           ? pic_readdata     :
		pit_cs                                 ? pit_readdata     :
		(ps2_io_cs|ps2_ctl_cs)                 ? ps2_readdata     :
		rtc_cs                                 ? rtc_readdata     :
		(vga_b_cs|vga_c_cs|vga_d_cs)           ? vga_io_readdata  :
		(sb_cs|fm_cs)                          ? sound_readdata   :
		                                         8'hFF;
	iobus iobus (
		.clk(clk), .reset(rstv[0]),
		.cpu_read_do(cpu_io_read_do), .cpu_read_address(cpu_io_read_address), .cpu_read_length(cpu_io_read_length),
		.cpu_read_data(cpu_io_read_data), .cpu_read_done(cpu_io_read_done),
		.cpu_write_do(cpu_io_write_do), .cpu_write_address(cpu_io_write_address), .cpu_write_length(cpu_io_write_length),
		.cpu_write_data(cpu_io_write_data), .cpu_write_done(cpu_io_write_done),
		.bus_address(iobus_address), .bus_write(iobus_write), .bus_read(iobus_read),
		.bus_io32(((ide0_cs | ide1_cs) & ~iobus_address[9]) | sysctl_cs),
		.bus_datasize(iobus_datasize), .bus_writedata(iobus_writedata),
		.bus_readdata(ide0_cs ? ide0_readdata : ide1_cs ? ide1_readdata : {24'd0, iobus_readdata8}),
		.bus_wait(1'b0)
	);
	wire [3:0]  ide_io_addr  = {iobus_address[9], iobus_address[2:0]};
	wire [31:0] ide_io_wdata = iobus_writedata;
	wire        ide_io_32    = iobus_datasize[2];
	wire        ide_io_rd    = iobus_read, ide_io_wr = iobus_write;
	wire        irq_13 = 1'b0;

	// --- DMA, the floppy (none in it) -------------------------------------------------------------
	wire dma_floppy_req, dma_floppy_ack, dma_floppy_tc; wire [7:0] dma_floppy_readdata, dma_floppy_writedata;
	wire dma_sb_ack_8, dma_sb_ack_16; wire [7:0] dma_sb_readdata_8; wire [15:0] dma_sb_readdata_16;
	wire dma_sb_req_8, dma_sb_req_16; wire [15:0] dma_sb_writedata;
	dma dma (
		.clk(clk), .rst_n(~rstv[1]),
		.mem_address(dma_address), .mem_16bit(dma_16bit), .mem_waitrequest(dma_waitrequest),
		.mem_read(dma_read), .mem_readdatavalid(dma_readdatavalid), .mem_readdata(dma_readdata),
		.mem_write(dma_write), .mem_writedata(dma_writedata),
		.io_address(iobus_address[4:0]), .io_writedata(iobus_writedata[7:0]), .io_read(iobus_read), .io_write(iobus_write),
		.io_readdata(dma_io_readdata), .io_master_cs(dma_master_cs), .io_slave_cs(dma_slave_cs), .io_page_cs(dma_page_cs),
		.dma_2_req(dma_floppy_req), .dma_2_ack(dma_floppy_ack), .dma_2_tc(dma_floppy_tc),
		.dma_2_readdata(dma_floppy_readdata), .dma_2_writedata(dma_floppy_writedata),
		.dma_1_req(dma_sb_req_8), .dma_1_ack(dma_sb_ack_8), .dma_1_readdata(dma_sb_readdata_8), .dma_1_writedata(dma_sb_writedata[7:0]),
		.dma_5_req(dma_sb_req_16), .dma_5_ack(dma_sb_ack_16), .dma_5_readdata(dma_sb_readdata_16), .dma_5_writedata(dma_sb_writedata)
	);
	wire mgmt_ide0_cs = (mgmt_address[15:8] == 8'hF0);
	wire mgmt_ide1_cs = (mgmt_address[15:8] == 8'hF1);
	wire mgmt_fdd_cs  = (mgmt_address[15:8] == 8'hF2);
	wire mgmt_rtc_cs  = (mgmt_address[15:8] == 8'hF4);
	wire fdd0_inserted; wire irq_6;
	floppy floppy (
		.clk(clk), .rst_n(~rstv[2]), .clock_rate(RATE),
		.io_address(iobus_address[2:0]), .io_writedata(iobus_writedata[7:0]),
		.io_read(iobus_read & floppy0_cs), .io_write(iobus_write & floppy0_cs), .io_readdata(floppy0_readdata),
		.fdd0_inserted(fdd0_inserted),
		.dma_req(dma_floppy_req), .dma_ack(dma_floppy_ack), .dma_tc(dma_floppy_tc),
		.dma_readdata(dma_floppy_readdata), .dma_writedata(dma_floppy_writedata),
		.mgmt_address(mgmt_address[3:0]), .mgmt_fddn(mgmt_address[7]), .mgmt_writedata(mgmt_writedata[15:0]), .mgmt_readdata(),
		.mgmt_write(mgmt_write & mgmt_fdd_cs), .mgmt_read(1'b0),
		.wp(2'b00), .request(), .irq(irq_6)
	);

	// --- the hard disk: IDE 0, its data from the ESP32 (pc_disk); IDE 1 empty --------------------
	wire [3:0] ide_address = {iobus_address[9], iobus_address[2:0]};
	wire [31:0] sd_avs_address, sd_avs_writedata, sd_avs_readdata;
	wire        sd_avs_read, sd_avs_write;
	reg         sd_avs_readdatavalid;
	always @(posedge clk) sd_avs_readdatavalid <= sd_avs_read;
	wire        d_slave_write, d_slave_read; wire [31:0] d_slave_writedata, d_slave_readdata;
	wire irq_14, irq_15;
	ide ide0 (
		.clk(clk), .rst_n(~rstv[3]),
		.io_address(ide_io_addr), .io_writedata(ide_io_wdata),
		.io_read(ide_io_rd & ide0_cs), .io_write(ide_io_wr & ide0_cs), .io_readdata(ide0_readdata),
		.io_32(ide_io_32),
		.mgmt_address(mgmt_address[3:0]), .mgmt_writedata(mgmt_writedata), .mgmt_write(mgmt_write & mgmt_ide0_cs),
		.irq(irq_14),
		.sd_master_address(sd_avs_address), .sd_master_waitrequest(1'b0), .sd_master_read(sd_avs_read),
		.sd_master_readdatavalid(sd_avs_readdatavalid), .sd_master_readdata(sd_avs_readdata),
		.sd_master_write(sd_avs_write), .sd_master_writedata(sd_avs_writedata),
		.sd_slave_address(9'd0), .sd_slave_read(d_slave_read), .sd_slave_readdata(d_slave_readdata),
		.sd_slave_write(d_slave_write), .sd_slave_writedata(d_slave_writedata)
	);
	pc_disk u_disk (
		.clk(clk), .rst(rstv[4]),
		.avs_address(sd_avs_address[3:2]), .avs_read(sd_avs_read), .avs_readdata(sd_avs_readdata),
		.avs_write(sd_avs_write), .avs_writedata(sd_avs_writedata),
		.d_write(d_slave_write), .d_writedata(d_slave_writedata), .d_read(d_slave_read), .d_readdata(d_slave_readdata),
		.h_req(dsk_req_hd), .h_lba(dsk_lba), .h_done(dsk_done), .h_done_n(dsk_done_n),
		.h_buf_addr(h_off[11:2]), .h_buf_we(dsk_buf_we), .h_buf_wdata(h_wdata), .h_buf_rdata(dsk_buf_q)
	);
	// the secondary channel: the CD-ROM drive -- MiSTer's IDE controller whose commands the ESP32 carries
	// out (ide_hps.v; esp32/console/cdrom.h): its registers at CD_REG, its sector buffer at CD_BUF, its
	// request in DSK_REQ [26:24] (4 a command, 5 a data phase, 6 a reset)
	wire        cd_reg_sel = h_off[15:8] == 8'hA0;
	ide_hps ide1 (
		.clk(clk), .rst_n(~rstv[5]), .irq(irq_15), .drq(), .use_fast(1'b0), .no_data(), .drive_en(),
		.io_address(ide_io_addr), .io_writedata(ide_io_wdata),
		.io_read(ide_io_rd & ide1_cs), .io_write(ide_io_wr & ide1_cs), .io_readdata(ide1_readdata),
		.io_32(ide_io_32), .io_wait(),
		.request(cd_request),
		.mgmt_address(h_off[5:2]), .mgmt_writedata(h_wdata[15:0]), .mgmt_write(h_we && cd_reg_sel),
		.mgmt_read(1'b0), .mgmt_readdata(cd_mgmt_q),
		.host_buf_addr(h_off[13:2]), .host_buf_we(h_we && h_off[15:14] == 2'b11),
		.host_buf_wdata(h_wdata), .host_buf_rdata(cd_buf_q)
	);
	// CD audio: the samples the ESP32 pushes (CD_AUDIO, a burst of a sector at a time), at 44.1 kHz
	wire [15:0] cdda_l, cdda_r;   // (cdda_req: declared at DSK_REQ)
	pc_cdda #(.CLK_HZ(CLK_HZ)) cdda (
		.clk(clk), .rst(rstv[13]), .push(h_we && h_off[15:12] == 4'hB), .sample(h_wdata),
		.req(cdda_req), .audio_l(cdda_l), .audio_r(cdda_r)
	);

	// --- timers, keyboard controller, CMOS clock, VGA, interrupts ---------------------------------
	wire speaker_out, irq_0;
	pit pit (
		.clk(clk), .rst_n(~rstv[6]), .clock_rate(RATE),
		.io_address({iobus_address[5], iobus_address[1:0]}), .io_writedata(iobus_writedata[7:0]), .io_readdata(pit_readdata),
		.io_read(iobus_read & pit_cs), .io_write(iobus_write & pit_cs),
		.speaker_out(speaker_out), .irq(irq_0)
	);

	// the keyboard: a PS/2 device fed the host's bytes, its clock ~12.5 kHz
	localparam integer PS2DIV = CLK_HZ / 25_000;
	reg clk_ps2; integer ps2c;
	initial begin clk_ps2 = 1'b0; ps2c = 0; end
	always @(posedge clk) begin
		ps2c <= (ps2c == PS2DIV) ? 0 : ps2c + 1;
		if (ps2c == PS2DIV) clk_ps2 <= ~clk_ps2;
	end
	wire kbd_ps2_clk, kbd_ps2_dat, ps2_kbclk_out, ps2_kbdat_out;
	wire mouse_ps2_clk, mouse_ps2_dat, ps2_mouseclk_out, ps2_mousedat_out;
	wire irq_1, irq_12, kbc_reset_out;
	ps2 ps2 (
		.clk(clk), .rst_n(~rstv[7]),
		.io_address(iobus_address[3:0]), .io_writedata(iobus_writedata[7:0]), .io_read(iobus_read), .io_write(iobus_write),
		.io_readdata(ps2_readdata), .io_cs(ps2_io_cs), .ctl_cs(ps2_ctl_cs),
		.ps2_kbclk(kbd_ps2_clk), .ps2_kbdat(kbd_ps2_dat), .ps2_kbclk_out(ps2_kbclk_out), .ps2_kbdat_out(ps2_kbdat_out),
		.ps2_mouseclk(mouse_ps2_clk), .ps2_mousedat(mouse_ps2_dat), .ps2_mouseclk_out(ps2_mouseclk_out), .ps2_mousedat_out(ps2_mousedat_out),
		.output_a20_enable(), .output_reset_n(kbc_reset_out), .a20_enable(a20_enable),
		.irq_keyb(irq_1), .irq_mouse(irq_12)
	);
	ps2_device ps2_kbd (
		.clk_sys(clk), .reset(rstv[11]), .ps2_clk(clk_ps2),
		.wdata(kbd_data), .we(kbd_we),
		.ps2_clk_out(kbd_ps2_clk), .ps2_dat_out(kbd_ps2_dat), .tx_empty(),
		.ps2_clk_in(ps2_kbclk_out), .ps2_dat_in(ps2_kbdat_out), .rdata(), .rd(1'b0)
	);
	// The mouse: a PS/2 device fed the ESP32's packets (MOUSE), and answering the commands the driver sends
	// it as a mouse does -- nothing else would (MiSTer's ARM answers them): FA for each; a reset (FF) then
	// its self-test pass and ID (AA 00), Get ID (F2) its ID (00), Status (E9) a status (00 02 64).
	wire [8:0] mouse_rx;                // {a byte from the host, it}
	reg        mouse_rd;
	reg  [7:0] mouse_q [0:3]; reg [2:0] mouse_qn, mouse_qi;
	reg  [7:0] mouse_wdata; reg mouse_we;
	always @(posedge clk) begin
		mouse_rd <= 1'b0; mouse_we <= 1'b0;
		if (rstv[12]) begin mouse_qn <= 3'd0; mouse_qi <= 3'd0; end
		else if (mouse_rx[8] && !mouse_rd) begin
			// a command: its answer queued (it goes out once the device has taken it, below)
			mouse_rd <= 1'b1; mouse_qi <= 3'd0;
			mouse_q[0] <= 8'hFA;
			case (mouse_rx[7:0])
			8'hFF:   begin mouse_q[1] <= 8'hAA; mouse_q[2] <= 8'h00; mouse_qn <= 3'd3; end
			8'hF2:   begin mouse_q[1] <= 8'h00; mouse_qn <= 3'd2; end
			8'hE9:   begin mouse_q[1] <= 8'h00; mouse_q[2] <= 8'h02; mouse_q[3] <= 8'h64; mouse_qn <= 3'd4; end
			default: mouse_qn <= 3'd1;
			endcase
		end else if (mouse_qi != mouse_qn) begin
			mouse_wdata <= mouse_q[mouse_qi[1:0]]; mouse_we <= 1'b1; mouse_qi <= mouse_qi + 3'd1;
		end else if (mouse_host_we) begin
			mouse_wdata <= mouse_host_data; mouse_we <= 1'b1;
		end
	end
	ps2_device ps2_mouse (
		.clk_sys(clk), .reset(rstv[12]), .ps2_clk(clk_ps2),
		.wdata(mouse_wdata), .we(mouse_we),
		.ps2_clk_out(mouse_ps2_clk), .ps2_dat_out(mouse_ps2_dat), .tx_empty(),
		.ps2_clk_in(ps2_mouseclk_out), .ps2_dat_in(ps2_mousedat_out), .rdata(mouse_rx), .rd(mouse_rd)
	);

	wire irq_8;
	rtc rtc (
		.clk(clk), .rst_n(~rstv[8]), .clock_rate(RATE),
		.io_address(iobus_address[0]), .io_writedata(iobus_writedata[7:0]),
		.io_read(iobus_read & rtc_cs), .io_write(iobus_write & rtc_cs), .io_readdata(rtc_readdata),
		.mgmt_address(mgmt_address[7:0]), .mgmt_write(mgmt_write & mgmt_rtc_cs), .mgmt_writedata(mgmt_writedata[7:0]),
		.bootcfg({4'd0, ~fdd0_inserted, fdd0_inserted}),
		.irq(irq_8)
	);

	wire video_ce, video_blank_n, video_hsync, video_vsync; wire [7:0] video_r, video_g, video_b; wire irq_2;
	// SVGA (the VGA's VBE modes): the picture a framebuffer in DDR3 the L2 cache writes (MiSTer ao486.sv):
	// on in a high-resolution 8/16/24-bit mode; at 0xF800000 + start * 4 (the L2's {111110, segment})
	wire [7:0]  vga_pal_a; wire [17:0] vga_pal_d; wire vga_pal_we;
	wire [19:0] vga_start_addr; wire [8:0] vga_width, vga_stride; wire [10:0] vga_height; wire [3:0] vga_flags;
	reg         fb_en, fb_16;
	reg  [23:0] fb_line; reg [11:0] fb_width; reg [10:0] fb_height; reg [13:0] fb_stride;
	always @(posedge clk) begin
		fb_en     <= ~vga_flags[2] && |vga_flags[1:0];
		fb_16     <= vga_flags[1:0] == 2'd2;
		fb_line   <= 24'hF80000 + {6'd0, vga_start_addr[19:2]};
		fb_width  <= (vga_flags[1:0] == 2'd3) ? 12'd640 : vga_flags[2] ? {1'b0, vga_width, 2'b00} : {vga_width, 3'b000};
		fb_height <= vga_flags[3] ? {1'b0, vga_height[10:1]} : vga_height;
		fb_stride <= {2'd0, vga_stride, 3'b000};
	end
	vga vga (
		.clk_sys(clk), .rst_n(~rstv[9]),
		.clk_vga(clk), .clock_rate_vga(RATE),
		.io_address(iobus_address[3:0]), .io_writedata(iobus_writedata[7:0]), .io_read(iobus_read), .io_write(iobus_write),
		.io_readdata(vga_io_readdata), .io_b_cs(vga_b_cs), .io_c_cs(vga_c_cs), .io_d_cs(vga_d_cs),
		.mem_address(vga_address), .mem_read(vga_read), .mem_readdata(vga_readdata),
		.mem_write(vga_write), .mem_writedata(vga_writedata),
		.vga_ce(video_ce), .vga_blank_n(video_blank_n), .vga_horiz_sync(video_hsync), .vga_vert_sync(video_vsync),
		.vga_r(video_r), .vga_g(video_g), .vga_b(video_b),
		.vga_f60(1'b1),                     // (the pixel clock at most ~25 MHz: under half of clk)
		.vga_memmode(vga_memmode), .vga_pal_a(vga_pal_a), .vga_pal_d(vga_pal_d), .vga_pal_we(vga_pal_we),
		.vga_start_addr(vga_start_addr),
		.vga_wr_seg(video_wr_seg), .vga_rd_seg(video_rd_seg),
		.vga_width(vga_width), .vga_height(vga_height), .vga_flags(vga_flags), .vga_stride(vga_stride), .vga_off(),
		.vga_lores(1'b0), .vga_border(1'b0),
		.irq(irq_2)
	);

	// the Sound Blaster 16 and the OPL3 (486Tang's sound.v), the OPL on this clock (opl3_pkg CLK_FREQ)
	wire irq_5, irq_7, irq_10;
	wire [15:0] sample_sb_l, sample_sb_r, sample_opl_l, sample_opl_r;
	sound sound (
		.clk(clk), .clk_audio(clk), .rst_n(~rstv[15]), .clock_rate(RATE),
		.address(iobus_address[3:0]), .writedata(iobus_writedata[7:0]), .read(iobus_read), .write(iobus_write),
		.readdata(sound_readdata), .sb_cs(sb_cs), .fm_cs(fm_cs),
		.dma_req8(dma_sb_req_8), .dma_req16(dma_sb_req_16), .dma_ack(dma_sb_ack_16 | dma_sb_ack_8),
		.dma_readdata(dma_sb_req_16 ? dma_sb_readdata_16 : {8'd0, dma_sb_readdata_8}), .dma_writedata(dma_sb_writedata),
		.vol_l(), .vol_r(), .vol_cd_l(), .vol_cd_r(), .vol_midi_l(), .vol_midi_r(), .vol_line_l(), .vol_line_r(),
		.vol_spk(), .vol_en(),
		.sample_l(sample_sb_l), .sample_r(sample_sb_r), .sample_opl_l(sample_opl_l), .sample_opl_r(sample_opl_r),
		.fm_mode(1'b1), .cms_en(1'b0),
		.irq_5(irq_5), .irq_7(irq_7), .irq_10(irq_10)
	);

	pic pic (
		.clk(clk), .rst_n(~rstv[10]),
		.io_address(iobus_address[0]), .io_writedata(iobus_writedata[7:0]), .io_read(iobus_read), .io_write(iobus_write),
		.io_readdata(pic_readdata), .io_master_cs(pic_master_cs), .io_slave_cs(pic_slave_cs),
		.interrupt_vector(interrupt_vector), .interrupt_done(interrupt_done), .interrupt_do(interrupt_do),
		.interrupt_input(interrupt)
	);
	always @(*) begin
		interrupt = 16'd0;
		interrupt[0]  = irq_0;
		interrupt[1]  = irq_1;
		interrupt[5]  = irq_5;
		interrupt[7]  = irq_7;
		interrupt[10] = irq_10;
		interrupt[6]  = irq_6;
		interrupt[8]  = irq_8;
		interrupt[9]  = irq_2;
		interrupt[12] = irq_12;
		interrupt[13] = irq_13;
		interrupt[14] = irq_14;
		interrupt[15] = irq_15;
	end

	// --- the picture --------------------------------------------------------------------------------
	pc_fb #(.BASE(24'h800000)) u_fb (
		.clk(clk), .rst(rst),
		.v_ce(video_ce), .v_de(video_blank_n), .v_vs(video_vsync), .v_r(video_r), .v_g(video_g), .v_b(video_b),
		.w_addr(pa_addr[47:24]), .w_req(pa_req[1]), .w_we(pa_we[1]), .w_data(pa_wdata[255:128]), .w_ready(pa_ready[1]),
		.r_addr(pa_addr[23:0]), .r_req(pa_req[0]), .r_ready(pa_ready[0]), .r_data(pa_rdata[127:0]), .r_valid(pa_valid[0]),
		.pclk(pclk), .x(vid_x), .y(vid_y), .req(vid_req), .rgb(vid_rgb),
		.pic_w(pic_w), .pic_h(pic_h), .mx(margin_x), .my(margin_y),
		.fb_en(fb_en), .fb_line(fb_line), .fb_width(fb_width), .fb_height(fb_height), .fb_stride(fb_stride),
		.fb_16(fb_16), .pal_a(vga_pal_a), .pal_d(vga_pal_d), .pal_we(vga_pal_we)
	);
	assign pa_we[0] = 1'b0; assign pa_wdata[127:0] = 128'd0; assign pa_wmask[15:0] = 16'h0000; assign pa_wmask[31:16] = 16'hFFFF;
	// port 3: the host's line read
	assign pa_addr[95:72] = hr_addr; assign pa_req[3] = hr_req; assign pa_we[3] = 1'b0;
	assign pa_wdata[511:384] = 128'd0; assign pa_wmask[63:48] = 16'h0000;
	always @(posedge clk) begin
		if (rst) hr_req <= 1'b0;
		else begin
			if (hr_go) begin hr_addr <= h_wdata[23:0]; hr_req <= 1'b1; end
			else if (hr_req && pa_ready[3]) hr_req <= 1'b0;
			if (pa_valid[3]) hr_data <= pa_rdata[511:384];
		end
		irq0_r <= irq_0; irq1_r <= irq_1; irq7_r <= irq_7;
		// (the sound counters: whether a game talks to the sound chips at all -- 0x7060-0x7068)
		if (iobus_write && fm_cs) n_fm_wr <= n_fm_wr + 16'd1;
		if (iobus_write && sb_cs) n_sb_wr <= n_sb_wr + 16'd1;
		if (iobus_read && fm_cs) n_fm_rd <= n_fm_rd + 16'd1;
		if (iobus_read && sb_cs) n_sb_rd <= n_sb_rd + 16'd1;
		if (irq_7 && !irq7_r) n_irq7 <= n_irq7 + 16'd1;
		if (dma_sb_ack_8 || dma_sb_ack_16) n_sb_dma <= n_sb_dma + 16'd1;
		// (the sound's level: |sample| at its peak -- the music chip's own output, and what goes to HDMI)
		if (h_we && h_off == 16'h7070) begin pk_opl <= 16'd0; pk_mix <= 16'd0; end
		else begin
			if (abs16(sample_opl_l) > pk_opl) pk_opl <= abs16(sample_opl_l);
			if (abs16(audio_l) > pk_mix) pk_mix <= abs16(audio_l);
		end
		if (rst) begin n_irq0 <= 16'd0; n_irq1 <= 16'd0; end
		else begin
			if (irq_0 && !irq0_r) n_irq0 <= n_irq0 + 16'd1;
			if (irq_1 && !irq1_r) n_irq1 <= n_irq1 + 16'd1;
		end
	end

	// the sound out: the Sound Blaster's samples, the OPL3's and the speaker, mixed (halves, and the
	// speaker an eighth), clipped
	function [15:0] abs16; input [15:0] v; abs16 = v[15] ? (~v + 16'd1) : v; endfunction
	function [15:0] clip; input signed [17:0] v; begin
		clip = (v > 18'sd32767) ? 16'h7FFF : (v < -18'sd32768) ? 16'h8000 : v[15:0];
	end endfunction
	wire signed [17:0] spk = speaker_out ? 18'sd4096 : -18'sd4096;
	always @(posedge clk) begin
		audio_l <= clip($signed({{2{sample_sb_l[15]}}, sample_sb_l}) + $signed({{2{sample_opl_l[15]}}, sample_opl_l}) + $signed({{2{cdda_l[15]}}, cdda_l}) + spk);
		audio_r <= clip($signed({{2{sample_sb_r[15]}}, sample_sb_r}) + $signed({{2{sample_opl_r[15]}}, sample_opl_r}) + $signed({{2{cdda_r[15]}}, cdda_r}) + spk);
	end
endmodule

`default_nettype wire
