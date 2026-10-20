//////////////////////////////////////////////////////////////////////////////////
// gba_top - the Game Boy Advance: the ARM7TDMI, its memories and bus, DMA, timers, keys,
// interrupts, the picture (gba_ppu) and the sound (gba_snd).
//
// The processor runs at the console's pace: `tick` is one 16.78 MHz cycle, made here from the
// board clock, and every bus access costs the cycles the console's memory map charges for it
// (GBATEK's table: the BIOS and the work RAM inside the chip in one, the 256 kB of work RAM
// outside it in three per halfword, the cartridge as WAITCNT says, with a prefetch buffer).
//
// Memories here: the BIOS (16 kB, loaded through bios_*), IWRAM (32 kB), VRAM (96 kB), the
// palette (two copies for the picture's sake), OAM. Outside: the cartridge through the
// console's cache (rom_*, 16-bit halfwords) and the external work RAM and the save RAM through
// a 32-bit port with byte enables (ext_*: EWRAM words 0-0xFFFF, SRAM words 0x10000-0x13FFF).
//
// The console's quirks kept: a byte store into VRAM or the palette writes the halfword, into
// OAM or the sprite half of VRAM nothing; the save RAM is 8 bits wide, a wider access takes
// the lane the address selects; a data read of the BIOS from outside it gives the last word
// fetched from it; reads past the cartridge's end give the address.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module gba_top #(
	parameter CLK_HZ = 50_000_000
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        pause,
	// the BIOS, loaded
	input  wire        bios_we,
	input  wire [11:0] bios_wa,
	input  wire [31:0] bios_wd,
	// the cartridge
	output reg  [24:0] rom_addr,           // halfword aligned byte address
	output reg         rom_req,
	input  wire        rom_ack,
	input  wire [15:0] rom_data,
	input  wire [24:0] rom_size,
	// the external RAM (EWRAM, SRAM)
	output reg  [16:0] ext_addr,           // 32-bit words: 0-0xFFFF EWRAM, 0x10000-0x13FFF SRAM
	output reg         ext_req,
	output reg         ext_we,
	output reg  [3:0]  ext_be,
	output reg  [31:0] ext_wdata,
	input  wire        ext_ack,
	input  wire [31:0] ext_rdata,
	// keys, pressed: 0 A, 1 B, 2 Select, 3 Start, 4 Right, 5 Left, 6 Up, 7 Down, 8 R, 9 L
	input  wire [9:0]  keys,
	// the picture
	output wire        px_we,
	output wire [7:0]  px_x,
	output wire [7:0]  px_y,
	output wire [14:0] px_rgb,
	output wire        frame_start,
	// the sound
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	output wire [31:0] dbg_pc,
	output wire [31:0] dbg_bus,             // what the bus is doing (ctrl 0x1D4 on the console)
	output reg         sram_dirty,          // the save RAM was written since the flag was cleared
	input  wire        sram_dirty_clr,
	// the cartridge's clock (Pokemon, Boktai): on or not, and the time the menu keeps
	input  wire        rtc_en,
	input  wire [55:0] rtc_now              // {year, month, day, weekday, hour, minute, second}, BCD
);

	// ---- the console's cycle ----------------------------------------------------------------------
	reg [27:0] tacc; reg tick;
	always @(posedge clk) begin
		if (rst) begin tacc <= 28'd0; tick <= 1'b0; end
		else if (pause) tick <= 1'b0;
		else if (tacc + 28'd16777216 >= CLK_HZ) begin tacc <= tacc + 28'd16777216 - CLK_HZ; tick <= 1'b1; end
		else begin tacc <= tacc + 28'd16777216; tick <= 1'b0; end
	end

	// ---- the processor ----------------------------------------------------------------------------
	wire [31:0] c_addr, c_dout; reg [31:0] c_din;
	wire [1:0]  c_size; wire c_we, c_req, c_code, c_seq; reg c_ack;
	wire        cpu_irq;
	arm7tdmi cpu (
		.clk(clk), .rst(rst), .tick(tick), .prime(1'b0),
		.addr(c_addr), .size(c_size), .we(c_we), .dout(c_dout), .din(c_din), .req(c_req), .ack(c_ack), .code(c_code), .seq(c_seq),
		.irq(cpu_irq),
		.ld_we(1'b0), .ld_idx(6'd0), .ld_data(32'd0), .st_idx(6'd0), .st_data(),
		.retire(), .dbg_pc(dbg_pc)
	);

	// ---- memories ---------------------------------------------------------------------------------
	reg [31:0] bios  [0:4095];
	`include "gba_bios_data.vh"            // (the open BIOS, until a loader writes another)
	reg [31:0] iwram [0:8191];
	reg [31:0] vram  [0:24575];
	reg [31:0] oam   [0:255];
	reg [15:0] pram0 [0:511], pram1 [0:511];
	reg [31:0] bios_q, iwram_q, vram_q, oam_q; reg [15:0] pram_q;
	// the picture's ports
	wire [14:0] vram_b_a; reg [31:0] vram_b_q;
	wire [7:0]  oam_b_a;  reg [31:0] oam_b_q;
	wire [8:0]  pal_a0, pal_a1; reg [15:0] pal_q0, pal_q1;
	// the palette's one write port (the engine hands it a halfword a clock)
	reg        pw_we; reg [8:0] pw_a; reg [15:0] pw_d;
	reg        pal_pend; reg [8:0] pal_pend_a; reg [15:0] pal_pend_d;
	always @(posedge clk) begin
		if (bios_we) bios[bios_wa] <= bios_wd;
		vram_b_q <= vram[vram_b_a];
		oam_b_q <= oam[oam_b_a];
		if (pw_we) begin pram0[pw_a] <= pw_d; pram1[pw_a] <= pw_d; end
		pal_q0 <= pram0[pal_a0]; pal_q1 <= pram1[pal_a1];
	end

	// ---- I/O registers ----------------------------------------------------------------------------
	reg [15:0] ie, iflags, waitcnt; reg ime;
	reg [15:0] keycnt;
	reg        halted;
	wire [15:0] keyinput = {6'd0, ~keys};
	// timers
	reg [15:0] tm_reload [0:3], tm_cnt [0:3]; reg [7:0] tm_ctl [0:3];
	reg [3:0]  tm_ov;
	reg [9:0]  tpre;
	// DMA
	reg [27:0] dma_sad [0:3], dma_dad [0:3]; reg [15:0] dma_cnt [0:3], dma_ctl [0:3];
	reg [27:0] dma_src [0:3], dma_dst [0:3]; reg [16:0] dma_n [0:3];
	reg [3:0]  dma_pend;                   // triggered, waiting for the bus
	reg [3:0]  dma_fifo;                   // ...for a FIFO refill (4 words, fixed destination)
	// the picture's and the sound's registers
	wire [15:0] ppu_q0, ppu_q1;
	wire        irq_vb, irq_hb, irq_vc, dma_vb, dma_hb;
	wire        fifo_a_req, fifo_b_req;
	reg         ppu_we; reg [5:0] ppu_a; reg [1:0] ppu_be; reg [15:0] ppu_d;
	reg         ppu_pend; reg [5:0] ppu_pend_a; reg [1:0] ppu_pend_be; reg [15:0] ppu_pend_d;   // the high half of a word write, next clock
	reg         snd_we; reg [31:0] snd_d; reg [3:0] snd_be; reg [6:2] snd_a;
	reg         snd_rd_req; wire [31:0] snd_rd_q; wire snd_rd_done;
	reg         fifo_a_we, fifo_b_we; reg [31:0] fifo_d; reg [3:0] fifo_be;

	// ---- the save RAM's flash chip --------------------------------------------------------------------
	// Games that save to flash talk to the chip with the AA/55 command handshake at 0x5555/0x2AAA:
	// 0x90 enters ID mode (reads at 0/1 give the maker and the part -- Sanyo's 128 kB one here,
	// which has two 64 kB banks picked by command 0xB0), 0xF0 leaves it, 0x80 then 0x10 erases
	// the chip, 0x80 then 0x30 at an address erases its 4 kB sector, 0xA0 programs the next byte
	// written. A chip erase fills DDR3 with 0xFF while the processor waits, as the real chip would
	// have it poll. Games that use plain SRAM never send the handshake and see 64 kB of RAM.
	reg  [2:0]  fl_st;                     // 0 idle, 1 AA seen, 2 AA 55 seen, 3 erase armed, 4 erase armed + AA, 5 erase armed + AA 55, 6 program next, 7 bank next
	reg         fl_id, fl_bank;
	reg  [14:0] fl_fill_n;                 // words of 0xFF still to write (an erase)
	reg  [14:0] fl_fill_a;                 // ...and where (words from the save RAM's start)
	reg         fl_fill_rq;
	wire        fl_busy = (fl_fill_n != 15'd0);

	// ---- the bus ----------------------------------------------------------------------------------
	// One access engine for the processor and the DMA controller. An access is accepted the clock
	// it is seen (its backing memory asked that same clock), and it is answered on the console
	// cycle its wait states say: the N-th tick after it was accepted. The processor asks for its
	// next instruction the clock it gets one, so a run of one-cycle fetches costs one tick each --
	// the console's own pace.
	localparam [1:0] B_IDLE = 2'd0, B_WAIT = 2'd1;
	reg [1:0]  bs;
	reg        b_dma;                      // the access is a DMA transfer's
	reg [1:0]  b_ch;
	reg        b_dma_rd;                   // ...its read half
	reg [31:0] b_addr, b_wdata; reg [1:0] b_size; reg b_we;
	reg        b_second;                   // this is the second halfword of a 32-bit access on a 16-bit bus
	reg        b_two;                      // the access has two halfword units
	reg [4:0]  b_wait;                     // ticks still to see before this unit is done
	reg        b_data_ok;                  // the backing memory has answered (registered)
	reg        b_snd;                      // a sound register read in flight
	reg        l_rom, l_ext, l_sram, l_bios, l_iw, l_vram, l_oam, l_pal, l_io, l_code;
	reg [15:0] b_lo;                       // the first halfword
	reg [31:0] bios_last;                  // the last word fetched from the BIOS
	reg [31:0] mem_q;                      // the unit's data
	reg [31:0] io_rd;
	// the prefetch buffer: halfwords ahead of the last cartridge fetch
	reg [24:0] pf_head; reg [3:0] pf_n; reg [3:0] pf_cnt; reg pf_rom_busy;

	// the access being set up: a new one (the DMA's or the processor's), a DMA write, or a second unit
	wire [3:0]  dma_want = dma_pend & {dma_ctl[3][15], dma_ctl[2][15], dma_ctl[1][15], dma_ctl[0][15]};
	wire        dma_any = |dma_want;
	wire [1:0]  dma_first = dma_want[0] ? 2'd0 : dma_want[1] ? 2'd1 : dma_want[2] ? 2'd2 : 2'd3;
	wire        irq_line = |(ie & iflags);
	assign cpu_irq = ime && irq_line;
	reg  [31:0] acc_addr, acc_wdata; reg [1:0] acc_size; reg acc_we, acc_code, acc_seq, acc_second, acc_dma;
	// the flash's view of the access being set up
	wire        fl_cmd_addr = (acc_addr[15:0] == 16'h5555);
	wire        fl_alt_addr = (acc_addr[15:0] == 16'h2AAA);
	wire [7:0]  fl_byte = acc_wdata[8 * acc_addr[1:0] +: 8];
	// a write that belongs to the handshake, not to the memory
	wire        fl_handshake = (fl_st == 3'd0 && fl_cmd_addr && fl_byte == 8'hAA) || (fl_st == 3'd1 && fl_alt_addr && fl_byte == 8'h55)
	                        || (fl_st == 3'd2 && fl_cmd_addr) || (fl_st == 3'd3 && fl_cmd_addr && fl_byte == 8'hAA)
	                        || (fl_st == 3'd4 && fl_alt_addr && fl_byte == 8'h55) || (fl_st == 3'd5) || (fl_st == 3'd7);
	// decoded from the access being set up
	wire [3:0]  region = acc_addr[27:24];
	wire        r_bios = (region == 4'h0) && (acc_addr[23:14] == 10'd0);
	wire        r_ew   = (region == 4'h2);
	wire        r_iw   = (region == 4'h3);
	wire        r_io   = (region == 4'h4);
	wire        r_pal  = (region == 4'h5);
	wire        r_vram = (region == 4'h6);
	wire        r_oam  = (region == 4'h7);
	wire        r_rom  = (region >= 4'h8) && (region <= 4'hD);
	wire        r_sram = (region == 4'hE) || (region == 4'hF);
	wire        bus16  = r_ew || r_pal || r_vram || r_rom;
	wire        units2 = bus16 && (acc_size == 2'd2);
	// wait states (GBATEK): the cycles of this unit
	wire [1:0]  ws = region[2:1];          // 8/9: 0, A/B: 1, C/D: 2
	function [3:0] nwait; input [1:0] v; nwait = (v == 2'd0) ? 4'd4 : (v == 2'd1) ? 4'd3 : (v == 2'd2) ? 4'd2 : 4'd8; endfunction
	wire [3:0]  rom_n = nwait((ws == 2'd0) ? waitcnt[3:2] : (ws == 2'd1) ? waitcnt[6:5] : waitcnt[9:8]);
	wire [3:0]  rom_s = (ws == 2'd0) ? (waitcnt[4] ? 4'd1 : 4'd2) : (ws == 2'd1) ? (waitcnt[7] ? 4'd1 : 4'd4) : (waitcnt[10] ? 4'd1 : 4'd8);
	wire [3:0]  sram_w = nwait(waitcnt[1:0]);
	wire        pf_hit = r_rom && acc_code && waitcnt[14] && (pf_n != 4'd0) && (acc_addr[24:1] == pf_head[24:1]);
	// a sequential fetch the prefetcher was already part way through: the rest of its cycles
	wire        pf_part = r_rom && acc_code && waitcnt[14] && (pf_n == 4'd0) && (acc_addr[24:1] == pf_head[24:1]) && (pf_cnt != 4'd0);
	wire [4:0]  pf_left = ({1'b0, rom_s} + 5'd1 > {1'b0, pf_cnt}) ? ({1'b0, rom_s} + 5'd1 - {1'b0, pf_cnt}) : 5'd1;
	wire [4:0]  unit_cycles = r_ew ? 5'd3 : r_rom ? (pf_part ? pf_left : (acc_seq || acc_second) ? {1'b0, rom_s} + 5'd1 : {1'b0, rom_n} + 5'd1) : r_sram ? {1'b0, sram_w} + 5'd1 : 5'd1;
	// VRAM's mirror: 96 kB in 128 kB
	wire [16:0] vram_byte = acc_addr[16] ? {2'b10, acc_addr[14:0]} : acc_addr[16:0];
	wire [14:0] vram_word = vram_byte[16:2];
	wire        vram_obj  = (vram_byte >= 17'h10000);
	// the byte enables of this access at this address
	wire [3:0]  be_w = (acc_size == 2'd2) ? 4'hF : (acc_size == 2'd1) ? (acc_addr[1] ? 4'hC : 4'h3) : (4'h1 << acc_addr[1:0]);
	wire [3:0]  be_h16 = acc_addr[1] ? 4'hC : 4'h3;                   // the whole halfword (a byte store's quirk)
	// the DMA's addresses, aligned to its unit
	wire [31:0] dma_src_a = {4'd0, dma_src[dma_first]} & (dma_ctl[dma_first][10] ? 32'hFFFFFFFC : 32'hFFFFFFFE);
	wire [31:0] dma_dst_a = {4'd0, dma_dst[b_ch]} & (b_size == 2'd2 ? 32'hFFFFFFFC : 32'hFFFFFFFE);

	// what is being set up this clock
	wire        setup_new = (bs == B_IDLE) && !fl_busy && (dma_any || (c_req && !c_ack && !halted && !pause));
	wire        done_w;                    // the current unit completes this clock (below)
	wire        setup_second = (bs == B_WAIT) && done_w && b_two && !b_second;
	wire        setup_dmaw = (bs == B_WAIT) && done_w && !(b_two && !b_second) && b_dma && b_dma_rd;
	wire        setup_any = setup_new || setup_second || setup_dmaw;
	// the data assembled for the unit completing now
	wire [31:0] rd_now = (l_rom && b_two && b_second) ? {mem_q[15:0], b_lo} : (b_two && b_second) ? {mem_q[31:16], b_lo} : mem_q;
	always @(*) begin
		acc_second = 1'b0; acc_dma = b_dma;
		if (setup_second) begin
			acc_addr = {b_addr[31:2], 2'b10}; acc_size = b_size; acc_we = b_we; acc_wdata = b_wdata; acc_code = l_code; acc_seq = 1'b1; acc_second = 1'b1;
		end else if (setup_dmaw) begin
			acc_addr = dma_dst_a; acc_size = b_size; acc_we = 1'b1; acc_code = 1'b0; acc_seq = 1'b0;
			acc_wdata = (b_size == 2'd2) ? rd_now : l_sram ? rd_now : l_rom ? {2{rd_now[15:0]}} : (b_addr[1] ? {2{rd_now[31:16]}} : {2{rd_now[15:0]}});
		end else if (dma_any) begin
			acc_addr = dma_src_a; acc_size = dma_ctl[dma_first][10] ? 2'd2 : 2'd1; acc_we = 1'b0; acc_wdata = 32'd0; acc_code = 1'b0; acc_seq = 1'b0; acc_dma = 1'b1;
		end else begin
			acc_addr = c_addr; acc_size = c_size; acc_we = c_we; acc_wdata = c_dout; acc_code = c_code; acc_seq = c_seq; acc_dma = 1'b0;
		end
	end
	// the completion of the unit in flight: its data is in, its ticks are up
	// (the registered flag only: an answer that lands after the cycles are up is taken the clock
	// after it is latched, never the clock it arrives -- mem_q is still the last word then)
	wire data_in = b_data_ok;
	assign done_w = (bs == B_WAIT) && data_in && (b_wait == 5'd0 || (tick && b_wait == 5'd1));

	// the DMA's step for a channel
	function [27:0] dstep;
		input [27:0] a; input [1:0] ctl; input wide;
		case (ctl)
			2'd0, 2'd3: dstep = a + (wide ? 28'd4 : 28'd2);
			2'd1: dstep = a - (wide ? 28'd4 : 28'd2);
			default: dstep = a;
		endcase
	endfunction
	// the DMA's count as latched
	function [16:0] dcount; input [15:0] c; input [1:0] ch; dcount = (c == 16'd0) ? (ch == 2'd3 ? 17'h10000 : 17'h4000) : {1'b0, c}; endfunction

	// ---- I/O reads ------------------------------------------------------------------------------------
	wire [5:0]  ppu_ra0 = {acc_addr[6:2], 1'b0};   // (the picture's registers read as the access is accepted: the word's two halves)
	wire [5:0]  ppu_ra1 = {acc_addr[6:2], 1'b1};
	function [31:0] io_read;
		input [11:0] a;
		reg [31:0] r;
		begin
			r = 32'd0;
			if (a < 12'h060) r = {ppu_q1, ppu_q0};
			else case (a[11:2])
				10'h02E: r = {dma_ctl[0], 16'd0}; 10'h031: r = {dma_ctl[1], 16'd0};
				10'h034: r = {dma_ctl[2], 16'd0}; 10'h037: r = {dma_ctl[3], 16'd0};
				10'h040: r = {8'd0, tm_ctl[0], tm_cnt[0]}; 10'h041: r = {8'd0, tm_ctl[1], tm_cnt[1]};
				10'h042: r = {8'd0, tm_ctl[2], tm_cnt[2]}; 10'h043: r = {8'd0, tm_ctl[3], tm_cnt[3]};
				10'h04C: r = {keycnt, keyinput};
				10'h080: r = {iflags, ie};
				10'h081: r = {16'd0, waitcnt};
				10'h082: r = {31'd0, ime};
				10'h0C0: r = 32'h00000001;                            // POSTFLG
				default: r = 32'd0;
			endcase
			io_read = r;
		end
	endfunction

	// ---- the cartridge's GPIO port and its clock (0x080000C4 / C6 / C8) ----------------------------
	wire        gpio_a = rtc_en && (acc_addr[24:4] == 21'h00000C) && (acc_addr[3:1] >= 3'd2) && (acc_addr[3:1] <= 3'd4);
	wire [1:0]  gpio_r = acc_addr[3:1] - 3'd2;
	reg         rtc_we; reg [1:0] rtc_wa; reg [3:0] rtc_wd;
	wire [15:0] rtc_q; wire rtc_rd;
	gba_rtc u_rtc (.clk(clk), .rst(rst), .en(rtc_en), .we(rtc_we), .wa(rtc_wa), .wd(rtc_wd),
		.ra(gpio_r), .rq(rtc_q), .readable(rtc_rd), .now_bcd(rtc_now));

	integer k;
	reg [3:0] ovn;                         // the timers overflowing this cycle (the cascade sees it)
	// the data a completing read gives the processor: the word, the halfword or the byte, low
	wire [31:0] cpu_q = l_sram ? rd_now : (b_size == 2'd2) ? rd_now
	                  : (b_size == 2'd1) ? ((l_rom || !b_addr[1]) ? {16'd0, rd_now[15:0]} : {16'd0, rd_now[31:16]})
	                  : l_rom ? {24'd0, rd_now[8 * b_addr[0] +: 8]} : {24'd0, rd_now[8 * b_addr[1:0] +: 8]};

	always @(posedge clk) begin
		c_ack <= 1'b0; ppu_we <= 1'b0; snd_we <= 1'b0; snd_rd_req <= 1'b0; fifo_a_we <= 1'b0; fifo_b_we <= 1'b0;
		pw_we <= 1'b0;
		rom_req <= 1'b0;                       // (a one-clock request, as the cartridge cache wants it)
		rtc_we <= 1'b0;
		if (pal_pend) begin pal_pend <= 1'b0; pw_we <= 1'b1; pw_a <= pal_pend_a; pw_d <= pal_pend_d; end
		if (rst) begin
			bs <= B_IDLE; rom_req <= 1'b0; ext_req <= 1'b0; ie <= 0; iflags <= 0; ime <= 0; waitcnt <= 0; keycnt <= 0; halted <= 0;
			for (k = 0; k < 4; k = k + 1) begin
				tm_reload[k] <= 0; tm_cnt[k] <= 0; tm_ctl[k] <= 0;
				dma_sad[k] <= 0; dma_dad[k] <= 0; dma_cnt[k] <= 0; dma_ctl[k] <= 0; dma_src[k] <= 0; dma_dst[k] <= 0; dma_n[k] <= 0;
			end
			dma_pend <= 0; dma_fifo <= 0; tm_ov <= 0; tpre <= 0; pf_n <= 0; pf_cnt <= 0; pf_head <= 0; pf_rom_busy <= 0; bios_last <= 32'hE129F000;
			b_dma <= 0; b_second <= 0; b_two <= 0; b_snd <= 0; ppu_pend <= 0; b_data_ok <= 0; pal_pend <= 0;
			fl_st <= 3'd0; fl_id <= 1'b0; fl_bank <= 1'b0; fl_fill_n <= 15'd0; fl_fill_a <= 15'd0; fl_fill_rq <= 1'b0; sram_dirty <= 1'b0;
		end else begin
			tm_ov <= 4'd0;
			// the second half of a word written to the picture's registers
			if (ppu_pend) begin ppu_pend <= 1'b0; ppu_we <= 1'b1; ppu_a <= ppu_pend_a; ppu_be <= ppu_pend_be; ppu_d <= ppu_pend_d; end
			// ---- interrupts from the picture, the keys ----
			if (irq_vb) iflags[0] <= 1'b1;
			if (irq_hb) iflags[1] <= 1'b1;
			if (irq_vc) iflags[2] <= 1'b1;
			if (keycnt[14] && (keycnt[15] ? ((keys & keycnt[9:0]) == keycnt[9:0] && keycnt[9:0] != 10'd0) : ((keys & keycnt[9:0]) != 10'd0))) iflags[12] <= 1'b1;
			if (halted && irq_line) halted <= 1'b0;
			// ---- the timers ----
			if (tick) begin
				tpre <= tpre + 10'd1;
				ovn = 4'd0;
				for (k = 0; k < 4; k = k + 1) begin
					if (tm_ctl[k][7]) begin
						if ((k != 0 && tm_ctl[k][2]) ? ovn[(k == 0) ? 0 : k - 1]
						    : ((tm_ctl[k][1:0] == 2'd0) || (tm_ctl[k][1:0] == 2'd1 && tpre[5:0] == 6'd0)
						       || (tm_ctl[k][1:0] == 2'd2 && tpre[7:0] == 8'd0) || (tm_ctl[k][1:0] == 2'd3 && tpre[9:0] == 10'd0))) begin
							if (tm_cnt[k] == 16'hFFFF) begin
								tm_cnt[k] <= tm_reload[k]; ovn[k] = 1'b1;
								if (tm_ctl[k][6]) iflags[3 + k] <= 1'b1;
							end else tm_cnt[k] <= tm_cnt[k] + 16'd1;
						end
					end
				end
				tm_ov <= ovn;
			end
			// ---- DMA triggers ----
			if (dma_vb) for (k = 0; k < 4; k = k + 1) if (dma_ctl[k][15] && dma_ctl[k][13:12] == 2'd1) dma_pend[k] <= 1'b1;
			if (dma_hb) for (k = 0; k < 4; k = k + 1) if (dma_ctl[k][15] && dma_ctl[k][13:12] == 2'd2) dma_pend[k] <= 1'b1;
			if (fifo_a_req && dma_ctl[1][15] && dma_ctl[1][13:12] == 2'd3) begin dma_pend[1] <= 1'b1; dma_fifo[1] <= 1'b1; dma_n[1] <= 17'd4; end
			if (fifo_b_req && dma_ctl[2][15] && dma_ctl[2][13:12] == 2'd3) begin dma_pend[2] <= 1'b1; dma_fifo[2] <= 1'b1; dma_n[2] <= 17'd4; end
			// ---- the prefetch buffer fills while the cartridge bus is idle ----
			if (tick && waitcnt[14] && !pf_rom_busy && pf_n < 4'd8) begin
				if (pf_cnt + 4'd1 >= rom_s + 4'd1) begin pf_cnt <= 4'd0; pf_n <= pf_n + 4'd1; end
				else pf_cnt <= pf_cnt + 4'd1;
			end

			// ---- an erase of the flash: 0xFF a word while the bus is idle ----
			if (fl_busy && bs == B_IDLE) begin
				if (!fl_fill_rq) begin
					ext_addr <= {2'b10, fl_fill_a}; ext_we <= 1'b1; ext_be <= 4'hF; ext_wdata <= 32'hFFFFFFFF; ext_req <= 1'b1; fl_fill_rq <= 1'b1;
				end else if (ext_ack) begin
					ext_req <= 1'b0; fl_fill_rq <= 1'b0; fl_fill_a <= fl_fill_a + 15'd1; fl_fill_n <= fl_fill_n - 15'd1;
				end
			end
			if (sram_dirty_clr) sram_dirty <= 1'b0;
			// ---- the access engine ----
			// the unit in flight: its data arriving
			if (bs == B_WAIT) begin
				if (l_rom && rom_ack) begin mem_q <= {rom_data, rom_data}; b_data_ok <= 1'b1; end
				if (l_ext && ext_ack) begin
					ext_req <= 1'b0; b_data_ok <= 1'b1;
					mem_q <= l_sram ? {4{ext_rdata[8 * b_addr[1:0] +: 8]}} : ext_rdata;
					if (l_sram && fl_id && b_addr[15:1] == 15'd0) mem_q <= b_addr[0] ? 32'h13131313 : 32'h62626262;   // Sanyo 128 kB
				end
				if (b_snd && snd_rd_done) begin mem_q <= snd_rd_q; b_data_ok <= 1'b1; b_snd <= 1'b0; end
				if (tick && b_wait != 5'd0) b_wait <= b_wait - 5'd1;
				// a block RAM read's data, the clock after the accept
				if (!l_rom && !l_ext && !b_snd && !b_we && !b_data_ok) begin
					b_data_ok <= 1'b1;
					if (l_bios) begin
						if (l_code || dbg_pc < 32'h4000) begin mem_q <= bios_q; if (l_code) bios_last <= bios_q; end
						else mem_q <= bios_last;
					end
					else if (l_iw) mem_q <= iwram_q;
					else if (l_vram) mem_q <= vram_q;
					else if (l_oam) mem_q <= oam_q;
					else if (l_pal) mem_q <= {pram_q, pram_q};
					else if (l_io) mem_q <= io_rd;
					else mem_q <= 32'd0;
				end
			end
			// the unit completing: the answer, or what follows
			if (done_w) begin
				b_data_ok <= 1'b0;
				if (b_two && !b_second) begin
					b_lo <= rd_now[15:0];                                // (the first halfword: the second unit is being set up)
				end else if (!b_dma) begin
					c_din <= cpu_q; c_ack <= 1'b1; bs <= B_IDLE; pf_rom_busy <= 1'b0;
				end else if (b_dma_rd) begin
					b_dma_rd <= 1'b0;                                     // (the write is being set up)
				end else begin
					// one transfer done: step, count
					dma_src[b_ch] <= dstep(dma_src[b_ch], dma_ctl[b_ch][8:7], b_size == 2'd2);
					dma_dst[b_ch] <= dma_fifo[b_ch] ? dma_dst[b_ch] : dstep(dma_dst[b_ch], dma_ctl[b_ch][6:5], b_size == 2'd2);
					dma_n[b_ch] <= dma_n[b_ch] - 17'd1;
					if (dma_n[b_ch] == 17'd1) begin
						dma_pend[b_ch] <= 1'b0; dma_fifo[b_ch] <= 1'b0;
						if (dma_ctl[b_ch][14]) iflags[8 + b_ch] <= 1'b1;
						if (dma_ctl[b_ch][9] && dma_ctl[b_ch][13:12] != 2'd0) begin
							dma_n[b_ch] <= dcount(dma_cnt[b_ch], b_ch);
							if (dma_ctl[b_ch][6:5] == 2'd3) dma_dst[b_ch] <= dma_dad[b_ch];
						end else dma_ctl[b_ch][15] <= 1'b0;
					end
					b_dma <= 1'b0; bs <= B_IDLE; pf_rom_busy <= 1'b0;
				end
			end
			// an access set up: this clock's backing operation, its cycles
			if (setup_any) begin
				bs <= B_WAIT;
				b_addr <= acc_addr; b_size <= acc_size; b_we <= acc_we; b_wdata <= acc_wdata;
				b_second <= acc_second; b_two <= units2; b_dma <= acc_dma;
				if (setup_new && acc_dma) begin b_ch <= dma_first; b_dma_rd <= 1'b1; end
				l_rom <= r_rom; l_ext <= r_ew || r_sram; l_sram <= r_sram; l_bios <= r_bios; l_iw <= r_iw; l_vram <= r_vram;
				l_oam <= r_oam; l_pal <= r_pal; l_io <= r_io; l_code <= acc_code;
				b_wait <= pf_hit ? 5'd1 : unit_cycles;
				b_data_ok <= 1'b0; b_snd <= 1'b0;
				if (pf_hit) begin pf_n <= pf_n - 4'd1; pf_head <= pf_head + 25'd2; end
				else if (r_rom) begin pf_n <= 4'd0; pf_cnt <= 4'd0; pf_head <= acc_addr[24:0] + 25'd2; end   // (the buffer starts again past this word)
				pf_rom_busy <= r_rom;
				if (r_rom) begin
					if (acc_we) begin
						b_data_ok <= 1'b1;                                     // (a cartridge write: nothing -- but the clock's port)
						if (gpio_a) begin rtc_we <= 1'b1; rtc_wa <= gpio_r; rtc_wd <= acc_addr[1] ? acc_wdata[19:16] : acc_wdata[3:0]; end
					end
					else if (gpio_a && rtc_rd) begin mem_q <= {2{rtc_q}}; b_data_ok <= 1'b1; end   // the port, read back
					else if (acc_addr[24:0] >= rom_size) begin mem_q <= {2{acc_addr[16:1]}}; b_data_ok <= 1'b1; end   // open bus: the address
					else begin rom_addr <= {acc_addr[24:1], 1'b0}; rom_req <= 1'b1; end
				end else if (r_ew || r_sram) begin
					if (acc_second) b_data_ok <= 1'b1;                       // (a write went whole; the second unit is cycles only)
					else begin
						ext_addr <= r_sram ? {2'b10, fl_bank, acc_addr[15:2]} : {1'b0, acc_addr[17:2]};
						ext_we <= acc_we;
						if (r_sram) begin ext_be <= 4'h1 << acc_addr[1:0]; ext_wdata <= {4{acc_wdata[8 * acc_addr[1:0] +: 8]}}; end
						else begin ext_be <= be_w; ext_wdata <= acc_wdata; end
						ext_req <= 1'b1;
						if (r_sram && acc_we) begin
							// the flash's commands: taken by the chip, not written
							if (fl_handshake || fl_st == 3'd6) begin
								if (fl_st != 3'd6) begin ext_req <= 1'b0; b_data_ok <= 1'b1; end
								case (fl_st)
								3'd0: fl_st <= 3'd1;
								3'd1: fl_st <= 3'd2;
								3'd2: begin
									fl_st <= 3'd0;
									case (fl_byte)
										8'h90: fl_id <= 1'b1;
										8'hF0: fl_id <= 1'b0;
										8'h80: fl_st <= 3'd3;
										8'hA0: fl_st <= 3'd6;
										8'hB0: fl_st <= 3'd7;
										default: ;
									endcase
								end
								3'd3: fl_st <= 3'd4;
								3'd4: fl_st <= 3'd5;
								3'd5: begin
									fl_st <= 3'd0;
									if (fl_cmd_addr && fl_byte == 8'h10) begin fl_fill_a <= {fl_bank, 14'd0}; fl_fill_n <= 15'd16384; end   // the chip (this bank)
									else if (fl_byte == 8'h30) begin fl_fill_a <= {fl_bank, acc_addr[15:12], 10'd0}; fl_fill_n <= 15'd1024; end   // a sector
								end
								3'd6: fl_st <= 3'd0;                                 // (the programmed byte goes through)
								default: begin fl_st <= 3'd0; fl_bank <= fl_byte[0]; end
								endcase
							end
							if (!fl_handshake) sram_dirty <= 1'b1;
						end
					end
				end else begin
					// block RAMs and I/O: a write now; a read's data is a clock away
					b_data_ok <= acc_we;
					if (acc_we) begin
						if (acc_second) ;                                    // (written whole the first time)
						else if (r_iw) begin
							for (k = 0; k < 4; k = k + 1) if (be_w[k]) iwram[acc_addr[14:2]][k*8 +: 8] <= acc_wdata[k*8 +: 8];
						end else if (r_vram) begin
							if (!(acc_size == 2'd0 && vram_obj))
								for (k = 0; k < 4; k = k + 1) if ((acc_size == 2'd0 ? be_h16[k] : be_w[k])) vram[vram_word][k*8 +: 8] <= acc_wdata[k*8 +: 8];
						end else if (r_pal) begin
							pw_we <= 1'b1;
							if (acc_size == 2'd2) begin
								pw_a <= {acc_addr[9:2], 1'b0}; pw_d <= acc_wdata[15:0];
								pal_pend <= 1'b1; pal_pend_a <= {acc_addr[9:2], 1'b1}; pal_pend_d <= acc_wdata[31:16];
							end else begin
								// a halfword, or a byte doubled (the console's quirk): the data is replicated already
								pw_a <= acc_addr[9:1]; pw_d <= acc_addr[1] ? acc_wdata[31:16] : acc_wdata[15:0];
							end
						end else if (r_oam) begin
							if (acc_size != 2'd0) for (k = 0; k < 4; k = k + 1) if (be_w[k]) oam[acc_addr[9:2]][k*8 +: 8] <= acc_wdata[k*8 +: 8];
						end else if (r_io) begin
							io_write(acc_addr[11:0], acc_wdata, be_w);
						end
					end else begin
						// a read: the word at the address, next clock
						bios_q <= bios[acc_addr[13:2]]; iwram_q <= iwram[acc_addr[14:2]]; vram_q <= vram[vram_word]; oam_q <= oam[acc_addr[9:2]];
						pram_q <= pram0[acc_addr[9:1]];
						io_rd <= io_read(acc_addr[11:0]);
						if (r_io && acc_addr[11:0] >= 12'h060 && acc_addr[11:0] < 12'h0A0) begin snd_rd_req <= 1'b1; b_snd <= 1'b1; end
					end
				end
			end
		end
	end

	// ---- I/O: writes ------------------------------------------------------------------------------
	task io_write;
		input [11:0] a; input [31:0] d; input [3:0] be;
		integer j;
		begin
			// the picture's registers (0x00-0x5F) by halfword; a word's high half the clock after
			if (a < 12'h060) begin
				if (be[1:0] != 2'd0) begin ppu_we <= 1'b1; ppu_a <= a[6:1]; ppu_be <= be[1:0]; ppu_d <= d[15:0]; end
				if (be[3:2] != 2'd0) begin
					if (be[1:0] != 2'd0) begin ppu_pend <= 1'b1; ppu_pend_a <= a[6:1] + 6'd1; ppu_pend_be <= be[3:2]; ppu_pend_d <= d[31:16]; end
					else begin ppu_we <= 1'b1; ppu_a <= a[6:1]; ppu_be <= be[3:2]; ppu_d <= d[31:16]; end
				end
			end
			// the sound: its own queue takes the word
			if (a >= 12'h060 && a < 12'h0A0) begin snd_we <= 1'b1; snd_a <= a[6:2]; snd_d <= d; snd_be <= be; end
			if (a[11:2] == 10'h028) begin fifo_a_we <= 1'b1; fifo_d <= d; fifo_be <= be; end   // 0xA0
			if (a[11:2] == 10'h029) begin fifo_b_we <= 1'b1; fifo_d <= d; fifo_be <= be; end   // 0xA4
			// DMA
			for (j = 0; j < 4; j = j + 1) begin
				if (a[11:2] == 10'h02C + j * 3) begin                  // SAD
					if (be[0]) dma_sad[j][7:0] <= d[7:0]; if (be[1]) dma_sad[j][15:8] <= d[15:8];
					if (be[2]) dma_sad[j][23:16] <= d[23:16]; if (be[3]) dma_sad[j][27:24] <= d[27:24];
				end
				if (a[11:2] == 10'h02D + j * 3) begin                  // DAD
					if (be[0]) dma_dad[j][7:0] <= d[7:0]; if (be[1]) dma_dad[j][15:8] <= d[15:8];
					if (be[2]) dma_dad[j][23:16] <= d[23:16]; if (be[3]) dma_dad[j][27:24] <= d[27:24];
				end
				if (a[11:2] == 10'h02E + j * 3) begin                  // CNT_L, CNT_H
					if (be[0]) dma_cnt[j][7:0] <= d[7:0]; if (be[1]) dma_cnt[j][15:8] <= d[15:8];
					if (be[2]) dma_ctl[j][7:0] <= d[23:16];
					if (be[3]) begin
						dma_ctl[j][15:8] <= d[31:24];
						if (d[31] && !dma_ctl[j][15]) begin
							// enabled: the addresses and the count latch; an immediate one starts
							dma_src[j] <= dma_sad[j]; dma_dst[j] <= dma_dad[j];
							dma_n[j] <= dcount(be[1:0] != 2'd0 ? d[15:0] : dma_cnt[j], j[1:0]);
							if (d[29:28] == 2'd0) dma_pend[j] <= 1'b1;
							if (d[29:28] == 2'd3 && (j == 1 || j == 2)) dma_n[j] <= 17'd4;
						end
						if (!d[31]) dma_pend[j] <= 1'b0;
					end
				end
			end
			// timers
			for (j = 0; j < 4; j = j + 1) begin
				if (a[11:2] == 10'h040 + j) begin
					if (be[0]) tm_reload[j][7:0] <= d[7:0]; if (be[1]) tm_reload[j][15:8] <= d[15:8];
					if (be[2]) begin
						tm_ctl[j] <= d[23:16];
						if (d[23] && !tm_ctl[j][7]) tm_cnt[j] <= {be[1] ? d[15:8] : tm_reload[j][15:8], be[0] ? d[7:0] : tm_reload[j][7:0]};
					end
				end
			end
			// keys
			if (a[11:2] == 10'h04C) begin if (be[2]) keycnt[7:0] <= d[23:16]; if (be[3]) keycnt[15:8] <= d[31:24]; end
			// interrupts
			if (a[11:2] == 10'h080) begin                              // IE, IF
				if (be[0]) ie[7:0] <= d[7:0]; if (be[1]) ie[15:8] <= d[15:8];
				if (be[2]) iflags[7:0] <= iflags[7:0] & ~d[23:16];
				if (be[3]) iflags[15:8] <= iflags[15:8] & ~d[31:24];
			end
			if (a[11:2] == 10'h081) begin if (be[0]) waitcnt[7:0] <= d[7:0]; if (be[1]) waitcnt[15:8] <= d[15:8]; end
			if (a[11:2] == 10'h082) begin if (be[0]) ime <= d[0]; end
			if (a[11:2] == 10'h0C0) begin if (be[1]) halted <= 1'b1; end   // HALTCNT (0x301)
		end
	endtask

	// ---- the picture --------------------------------------------------------------------------------
	gba_ppu u_ppu (
		.clk(clk), .rst(rst), .tick(tick),
		.reg_a(ppu_a), .reg_we(ppu_we), .reg_be(ppu_be), .reg_d(ppu_d),
		.reg_ra0(ppu_ra0), .reg_q0(ppu_q0), .reg_ra1(ppu_ra1), .reg_q1(ppu_q1),
		.vram_a(vram_b_a), .vram_q(vram_b_q), .oam_a(oam_b_a), .oam_q(oam_b_q),
		.pal_a0(pal_a0), .pal_q0(pal_q0), .pal_a1(pal_a1), .pal_q1(pal_q1),
		.px_we(px_we), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .frame_start(frame_start),
		.irq_vblank(irq_vb), .irq_hblank(irq_hb), .irq_vcount(irq_vc), .dma_vblank(dma_vb), .dma_hblank(dma_hb),
		.vcount(), .in_vblank(), .in_hblank()
	);

	// ---- the sound ------------------------------------------------------------------------------------
	gba_snd u_snd (
		.clk(clk), .rst(rst), .tick(tick),
		.wr_a(snd_a), .wr_we(snd_we), .wr_d(snd_d), .wr_be(snd_be),
		.rd_a(b_addr[6:2]), .rd_req(snd_rd_req), .rd_q(snd_rd_q), .rd_done(snd_rd_done),
		.fifo_a_we(fifo_a_we), .fifo_b_we(fifo_b_we), .fifo_d(fifo_d), .fifo_be(fifo_be),
		.tm0_ov(tm_ov[0]), .tm1_ov(tm_ov[1]), .dma_a_req(fifo_a_req), .dma_b_req(fifo_b_req),
		.audio_l(audio_l), .audio_r(audio_r)
	);
	// ---- what the bus is doing, for the console's debug register ------------------------------------
	reg [11:0] dbg_ticks; reg [7:0] dbg_romacks;
	always @(posedge clk) begin
		if (tick) dbg_ticks <= dbg_ticks + 12'd1;
		if (rom_ack) dbg_romacks <= dbg_romacks + 8'd1;
	end
	assign dbg_bus = {dbg_ticks, dbg_romacks, rom_req, ext_req, halted, c_req, bs, b_wait, pause};
endmodule
`default_nettype wire
