`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// gb_top.v - a Nintendo Game Boy: the SM83, the PPU, the APU, and the rest of the
// machine around them -- a DMG, or a Game Boy Color for a cartridge made for one.
//
// --- the memory map ----------------------------------------------------------------
//
//   $0000-$7FFF   cartridge ROM, through the mapper (MBC); writes go to the MBC
//   $8000-$9FFF   8 kB video RAM (in the PPU)
//   $A000-$BFFF   cartridge RAM, up to 32 kB banked (here; see "saves" below)
//   $C000-$DFFF   8 kB work RAM, mirrored at $E000-$FDFF (the Color: 32 kB, $D000 banked by SVBK)
//   $FE00-$FE9F   OAM (in the PPU)
//   $FEA0-$FEFF   nothing; reads 0
//   $FF00-$FF7F   the I/O registers (joypad, serial, timer, IF, sound, video, DMA)
//   $FF80-$FFFE   127 bytes of high RAM
//   $FFFF         IE
//
// --- clocks ---------------------------------------------------------------------------------
//
// Everything is in the one system clock domain. A phase accumulator turns it into
// a 4.194304 MHz clock-enable, the T-cycle, and the CPU, PPU, APU and timer all
// take that same enable; the CPU counts four of them to an M-cycle. When the
// cartridge is slow to answer (it is in DDR3 behind a cache, on the board) the
// enable is simply withheld from everybody for the clocks it takes, so the parts
// never get out of step with each other -- the machine as a whole pauses.
//
// --- the cartridge ------------------------------------------------------------------------
//
// ROM is outside, behind a request/acknowledge pair: rom_req pulses with rom_addr
// and rom_ack comes back some clocks later with rom_data. A request goes out the
// clock after the CPU puts a cartridge address on the bus; with four T-cycles
// (48 system clocks on the board) before the CPU wants the byte, anything cached
// answers in time and nothing pauses. There is no boot ROM: the header is read
// through the same port at reset to learn the mapper (byte $0147), the ROM size
// ($0148) and the RAM size ($0149), the registers get the values the DMG boot
// ROM leaves, and the CPU starts at $0100.
//
// Mappers: none, MBC1, MBC3 (with its real-time clock) and MBC5, by the header
// type. Anything else is treated as MBC5 -- the most forgiving guess, since its
// bank registers are plain and bank 0 is allowed everywhere. Not here: MBC2 (its
// 512 x 4-bit RAM and register decode on A8), MBC1 multicarts, MMM01, HuC1/3,
// and the camera. The MBC3 clock counts T-cycles, so it keeps game time, not
// wall time, and starts from zero at every reset -- a host that wants it right
// across power cycles has to save and restore it, which is not provided yet.
//
// The ROM must be in place (DDR3 loaded) before rst is released: the header is
// the first thing read.
//
// Cartridge RAM is 32 kB of block RAM inside. Saves: `sav_addr`/`sav_q` is a
// read port on it for the host, `cram_dirty` goes high on the first write after
// `sav_clear`; a host that wants battery saves polls dirty, reads the RAM out
// through that port and clears the flag. Loading a save is not yet provided
// (there is no host write port); that is the hook to add when it is wanted.
//
// --- post-boot state ---------------------------------------------------------------------------
//
// CPU registers and I/O registers as Pan Docs lists them for the DMG after its
// boot ROM, with two differences: the PPU starts at line 0 dot 0 (STAT reads $84
// rather than $85 for the first dots), and the boot logo is not in VRAM.
//
// --- the Color ----------------------------------------------------------------------------------
//
// Header byte $0143 bit 7 says the cartridge is for a Game Boy Color, and then this is one
// (Pan Docs' CGB chapters): the CPU starts with A = $11, the PPU has its second VRAM bank,
// attributes and colour palettes (gb_ppu), work RAM is 32 kB banked by SVBK ($FF70), KEY1
// ($FF4D) and STOP switch the CPU, timer and OAM DMA to double speed (the picture and sound
// keep their clock; the CPU pauses 8200 T-cycles over the switch), and HDMA ($FF51-$FF55)
// copies 16-byte blocks from ROM or RAM into VRAM -- all at once (GDMA, the CPU held until it
// is done) or one block at the start of each horizontal blank (HDMA), a byte every two
// T-cycles, the CPU held for each block. The infrared port ($FF56) is wired to nobody. A
// cartridge without the flag gets the DMG as before, to the last register value: a Color
// would run it through a boot ROM that picks it a palette; here it stays grey.
//
// --- the joypad ------------------------------------------------------------------------------
//
// joy[7:0] = {start, select, B, A, down, up, left, right}, active high, so bit 0
// is right and bit 7 is start. $FF00 presents them the way the console does:
// active low, in the nibble the game has selected.
//
// --- what the timer gets right -------------------------------------------------------------
//
// DIV is the top byte of a 16-bit counter of T-cycles, and TIMA is clocked by the
// falling edge of one bit of that counter chosen by TAC, so writing DIV, changing
// TAC or disabling the timer can all tick TIMA -- they do here, because the edge
// detector watches the actual bit. The overflow reloads TMA and raises the
// interrupt one M-cycle late, with TIMA reading 0 in between, and a write to
// TIMA in that cycle cancels the reload. STOP resets DIV.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module gb_top #(
	parameter CLK_HZ = 50_000_000     // 4194304 makes a T-cycle every clock, for the benches
) (
	input  wire        clk,
	input  wire        rst,
	// the menu's pause (console_top's cpu_halt): every T-cycle withheld, so the whole machine
	// stops where it stands and resumes as if nothing happened
	input  wire        pause,

	// the cartridge ROM, with latency
	output reg  [22:0] rom_addr,
	output reg         rom_req,
	input  wire        rom_ack,
	input  wire [7:0]  rom_data,

	// the pad: bit 0 right, 1 left, 2 up, 3 down, 4 A, 5 B, 6 select, 7 start; 1 = pressed
	input  wire [7:0]  joy,

	// video: one pixel per dot, shade 0 lightest .. 3 darkest -- or, on a Color (cgb_mode),
	// its 15-bit colour (BBBBBGGGGGRRRRR)
	output wire [7:0]  px_x,
	output wire [7:0]  px_y,
	output wire [1:0]  px_shade,
	output wire [14:0] px_rgb,
	output wire        cgb_mode,
	output wire        pixel_en,
	output wire        frame_start,

	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// saves: a read port on the cartridge RAM for the host
	input  wire [14:0] sav_addr,
	output reg  [7:0]  sav_q,
	output reg         cram_dirty,
	input  wire        sav_clear,

	// the serial port, for anyone listening (the test ROMs print through it)
	output wire [7:0]  sio_data,
	output wire        sio_start,     // pulse: a transfer was started with sio_data in SB

	output wire [15:0] dbg_pc,
	output wire        dbg_halted
);

	// --- the T-cycle --------------------------------------------------------------------------------
	localparam [31:0] GB_HZ = 32'd4194304;
	reg  [31:0] acc, acc2;
	reg         ce_raw, ce2_raw;
	// (and the Color's double speed, 8.388608 MHz, from an accumulator of its own: the CPU's
	// clock when `fast`; in a bench clocked at GB_HZ it can only be the same as ce_raw)
	always @(posedge clk) begin
		if (rst) begin acc <= 32'd0; ce_raw <= 1'b0; acc2 <= 32'd0; ce2_raw <= 1'b0; end
		else begin
			if (acc + GB_HZ >= CLK_HZ) begin acc <= acc + GB_HZ - CLK_HZ; ce_raw <= 1'b1; end
			else begin acc <= acc + GB_HZ; ce_raw <= 1'b0; end
			if (acc2 + 2 * GB_HZ >= CLK_HZ) begin acc2 <= acc2 + 2 * GB_HZ - CLK_HZ; ce2_raw <= 1'b1; end
			else begin acc2 <= acc2 + 2 * GB_HZ; ce2_raw <= 1'b0; end
		end
	end

	// The whole machine waits while a cartridge byte is still on its way.
	reg         boot_done;
	reg         cgb;                  // the cartridge is for a Color: be one
	reg         fast;                 // (cgb) double speed
	wire        rom_busy;
	wire [1:0]  tcyc;
	wire        stall = rom_busy && (tcyc == 2'd3);
	wire        ce  = ce_raw && !stall && boot_done && !pause;
	wire        ce2 = ce2_raw && !stall && boot_done && !pause;
	wire        ce_cpu = fast ? ce2 : ce;            // the CPU's, the timer's and OAM DMA's clock
	wire        hd_run;                              // HDMA holds the CPU while it copies, and until its byte is back
	wire        hd_running;                          // ...the copying itself
	assign cgb_mode = cgb;

	// --- the CPU ---------------------------------------------------------------------------------------
	wire [15:0] a;
	wire [7:0]  cpu_dout;
	reg  [7:0]  cpu_din;
	wire        rd, we, wr_strobe, m_end, m1;
	wire        cpu_halted, cpu_stop, cpu_ime, cpu_ime_pend, irq_ack;
	wire [2:0]  irq_n;
	reg  [4:0]  if_r;
	reg  [7:0]  ie_r;

	reg         speed_wake;
	gb_cpu u_cpu (
		.clk(clk), .rst(rst || !boot_done), .ce(ce_cpu && !hd_run), .cgb(cgb), .wake(speed_wake),
		.addr(a), .din(cpu_din), .dout(cpu_dout), .rd(rd), .we(we),
		.wr_strobe(wr_strobe), .m_end(m_end), .tcyc(tcyc), .m1(m1),
		.irq(if_r & ie_r[4:0]), .irq_ack(irq_ack), .irq_n(irq_n),
		.halted(cpu_halted), .stop(cpu_stop), .ime(cpu_ime), .ime_pend(cpu_ime_pend),
		.dbg_pc(dbg_pc)
	);
	assign dbg_halted = cpu_halted;

	// --- decode ---------------------------------------------------------------------------------------
	wire sel_rom  = (a[15] == 1'b0);
	wire sel_vram = (a[15:13] == 3'b100);
	wire sel_cram = (a[15:13] == 3'b101);
	wire sel_wram = (a[15:13] == 3'b110) || (a[15:13] == 3'b111 && a[12:9] != 4'b1111);   // and the echo to $FDFF
	wire sel_oam  = (a[15:8] == 8'hFE) && (a[7:0] < 8'hA0);
	wire sel_nil  = (a[15:8] == 8'hFE) && (a[7:0] >= 8'hA0);
	wire sel_io   = (a[15:8] == 8'hFF) && (a[7] == 1'b0);
	wire sel_hram = (a[15:8] == 8'hFF) && (a[7] == 1'b1) && (a[7:0] != 8'hFF);
	wire sel_ie   = (a == 16'hFFFF);
	wire sel_apu  = sel_io && (a[7:4] >= 4'h1) && (a[7:4] <= 4'h3);
	wire sel_ppu  = sel_io && (((a[7:4] == 4'h4) && (a[3:0] <= 4'hB)) || a[7:0] == 8'h4F ||
	                           (a[7:0] >= 8'h68 && a[7:0] <= 8'h6C));         // ($FF4F VBK, $FF68-6C the palettes, OPRI)

	wire cpu_wr = wr_strobe;                    // the write commits at the end of its M-cycle

	// --- OAM DMA -----------------------------------------------------------------------------------------
	// 160 M-cycles copying from src to OAM. The external bus (ROM, cartridge RAM,
	// work RAM) belongs to the DMA while it runs; the CPU reads $FF there, as the
	// console's does, and writes are dropped. Games sit in HRAM waiting for it.
	reg         dma_active, dma_pend;
	reg  [7:0]  dma_src;
	reg  [7:0]  dma_cnt;
	wire [15:0] dma_a = {dma_src, dma_cnt};
	reg  [15:0] hd_src;                            // HDMA's source address (below)
	reg         hd_req, hd_done;                   // HDMA asks the cartridge port for a byte; has let the bus go
	wire [15:0] ext_a = hd_running ? hd_src : dma_active ? dma_a : a;    // the external bus address this M-cycle
	wire        ext_is_rom  = (ext_a[15] == 1'b0);
	wire        ext_is_cram = (ext_a[15:13] == 3'b101);
	wire        ext_is_vram = (ext_a[15:13] == 3'b100);
	wire        ext_rd = dma_active || rd;         // somebody reads the external bus

	// --- work RAM ------------------------------------------------------------------------------------------
	// 32 kB: bank 0 at $C000, SVBK's (0 means 1) at $D000 on a Color; a DMG sees banks 0 and 1
	reg [7:0] wram [0:32767];
	reg [7:0] wram_q;
	reg [2:0] svbk;
	wire [2:0] wbank = !cgb ? 3'd1 : (svbk == 3'd0) ? 3'd1 : svbk;
	wire [14:0] wram_a = {ext_a[12] ? wbank : 3'd0, ext_a[11:0]};
	always @(posedge clk) begin
		if (cpu_wr && sel_wram && !dma_active && !hd_run) wram[wram_a] <= cpu_dout;
		wram_q <= wram[wram_a];
	end

	// --- high RAM ----------------------------------------------------------------------------------------------
	reg [7:0] hram [0:127];
	reg [7:0] hram_q;
	always @(posedge clk) begin
		if (cpu_wr && sel_hram) hram[a[6:0]] <= cpu_dout;
		hram_q <= hram[a[6:0]];
	end

	// --- the cartridge: header, mapper, RAM ------------------------------------------------------------------
	reg  [7:0]  cart_type, rom_size, ram_size;
	reg  [2:0]  boot_st;
	reg         boot_busy;
	// MBC state
	reg         ram_en;
	reg  [8:0]  bank_lo;         // MBC1: 5 bits; MBC3: 7; MBC5: 9
	reg  [3:0]  bank_hi;         // MBC1: 2 bits (RAM bank or ROM upper); MBC3: RAM bank / RTC select; MBC5: RAM bank
	reg         mbc1_mode;
	wire        is_mbc1 = (cart_type >= 8'h01 && cart_type <= 8'h03);
	wire        is_mbc3 = (cart_type >= 8'h0F && cart_type <= 8'h13);
	wire        is_none = (cart_type == 8'h00 || cart_type == 8'h08 || cart_type == 8'h09);
	// MBC5 and anything unknown
	wire        is_mbc5 = !is_mbc1 && !is_mbc3 && !is_none;

	// the ROM bank for this access, before the size mask
	reg [8:0] rom_bank;
	always @(*) begin
		if (is_none) rom_bank = {8'd0, ext_a[14]};
		else if (is_mbc1) begin
			if (!ext_a[14]) rom_bank = mbc1_mode ? {2'b00, bank_hi[1:0], 5'd0} : 9'd0;
			else rom_bank = {2'b00, bank_hi[1:0], (bank_lo[4:0] == 5'd0) ? 5'd1 : bank_lo[4:0]};
		end else if (is_mbc3) begin
			if (!ext_a[14]) rom_bank = 9'd0;
			else rom_bank = {2'b00, (bank_lo[6:0] == 7'd0) ? 7'd1 : bank_lo[6:0]};
		end else begin
			rom_bank = ext_a[14] ? bank_lo : 9'd0;
		end
	end
	// ROM size: $0148 = n means 32 kB << n, i.e. 2 << n banks of 16 kB
	wire [9:0] bank_mask = (10'd2 << rom_size[3:0]) - 10'd1;
	wire [22:0] rom_phys = {rom_bank & bank_mask[8:0], ext_a[13:0]};

	// the RAM bank; RAM size $0149: 2 = 8 kB, 3 = 32 kB (others: treat as 32 kB)
	wire [1:0] ram_bank = is_mbc1 ? (mbc1_mode ? bank_hi[1:0] : 2'd0) :
	                      is_mbc3 ? bank_hi[1:0] : bank_hi[1:0];
	wire [1:0] ram_bank_m = (ram_size == 8'h02) ? 2'd0 : ram_bank;
	wire       rtc_sel = is_mbc3 && (bank_hi >= 4'h8);
	wire       cram_ok = ram_en && !rtc_sel && (ram_size != 8'd0);

	reg [7:0] cram [0:32767];
	reg [7:0] cram_q;
	wire [14:0] cram_a = {ram_bank_m, ext_a[12:0]};
	always @(posedge clk) begin
		if (cpu_wr && sel_cram && !dma_active && cram_ok) cram[cram_a] <= cpu_dout;
		cram_q <= cram[cram_a];
	end
	always @(posedge clk) sav_q <= cram[sav_addr];
	always @(posedge clk) begin
		if (rst || sav_clear) cram_dirty <= 1'b0;
		else if (cpu_wr && sel_cram && !dma_active && cram_ok) cram_dirty <= 1'b1;
	end

	// --- MBC3 real-time clock ---------------------------------------------------------------------------------
	reg [21:0] rtc_sub;          // T-cycles to a second
	reg [5:0]  rtc_s, rtc_m;
	reg [4:0]  rtc_h;
	reg [8:0]  rtc_d;
	reg        rtc_halt, rtc_carry;
	reg [5:0]  l_s, l_m;
	reg [4:0]  l_h;
	reg [8:0]  l_d;
	reg        l_halt, l_carry, rtc_latch;
	reg [7:0]  rtc_q;
	always @(*) begin
		case (bank_hi)
			4'h8: rtc_q = {2'b00, l_s};
			4'h9: rtc_q = {2'b00, l_m};
			4'hA: rtc_q = {3'b000, l_h};
			4'hB: rtc_q = l_d[7:0];
			4'hC: rtc_q = {l_carry, l_halt, 5'd0, l_d[8]};
			default: rtc_q = 8'hFF;
		endcase
	end

	// --- the mapper's registers and the clock -----------------------------------------------------------------
	always @(posedge clk) begin
		if (rst) begin
			ram_en <= 1'b0; bank_lo <= 9'd1; bank_hi <= 4'd0; mbc1_mode <= 1'b0;
			rtc_sub <= 22'd0; rtc_s <= 6'd0; rtc_m <= 6'd0; rtc_h <= 5'd0; rtc_d <= 9'd0;
			rtc_halt <= 1'b0; rtc_carry <= 1'b0; rtc_latch <= 1'b0;
			l_s <= 6'd0; l_m <= 6'd0; l_h <= 5'd0; l_d <= 9'd0; l_halt <= 1'b0; l_carry <= 1'b0;
		end else begin
			// the clock
			if (ce && !rtc_halt) begin
				if (rtc_sub == 22'd4194303) begin
					rtc_sub <= 22'd0;
					if (rtc_s == 6'd59) begin
						rtc_s <= 6'd0;
						if (rtc_m == 6'd59) begin
							rtc_m <= 6'd0;
							if (rtc_h == 5'd23) begin
								rtc_h <= 5'd0;
								if (rtc_d == 9'd511) rtc_carry <= 1'b1;
								rtc_d <= rtc_d + 9'd1;
							end else rtc_h <= rtc_h + 5'd1;
						end else rtc_m <= rtc_m + 6'd1;
					end else rtc_s <= rtc_s + 6'd1;
				end else rtc_sub <= rtc_sub + 22'd1;
			end

			if (cpu_wr && sel_rom && !dma_active) begin
				case (a[14:13])
					2'd0: ram_en <= (cpu_dout[3:0] == 4'hA);
					2'd1: begin
						if (is_mbc1) bank_lo[4:0] <= cpu_dout[4:0];
						else if (is_mbc3) bank_lo[6:0] <= cpu_dout[6:0];
						else if (!a[12]) bank_lo[7:0] <= cpu_dout;          // MBC5 $2000: low 8 bits
						else bank_lo[8] <= cpu_dout[0];                      // MBC5 $3000: bit 8
					end
					2'd2: bank_hi <= cpu_dout[3:0];
					default: begin
						if (is_mbc1) mbc1_mode <= cpu_dout[0];
						if (is_mbc3) begin
							// 0 then 1 latches the clock
							if (cpu_dout[0] && !rtc_latch) begin
								l_s <= rtc_s; l_m <= rtc_m; l_h <= rtc_h; l_d <= rtc_d;
								l_halt <= rtc_halt; l_carry <= rtc_carry;
							end
							rtc_latch <= cpu_dout[0];
						end
					end
				endcase
			end
			if (cpu_wr && sel_cram && !dma_active && ram_en && rtc_sel) begin
				case (bank_hi)
					4'h8: begin rtc_s <= cpu_dout[5:0]; rtc_sub <= 22'd0; end
					4'h9: rtc_m <= cpu_dout[5:0];
					4'hA: rtc_h <= cpu_dout[4:0];
					4'hB: rtc_d[7:0] <= cpu_dout;
					4'hC: begin rtc_d[8] <= cpu_dout[0]; rtc_halt <= cpu_dout[6]; rtc_carry <= cpu_dout[7]; end
					default: ;
				endcase
			end
		end
	end

	// --- the ROM port -----------------------------------------------------------------------------------------
	// A request goes out the clock after an M-cycle starts with a cartridge read on
	// the bus; the byte is held in rom_q for the CPU (or the DMA) to take at the end
	// of the cycle. At reset the header is read the same way before the CPU runs.
	reg        rom_pend;
	reg  [7:0] rom_q;
	reg        arm;
	// HDMA's reads come through the same port, so rom_q -- which the CPU may still be using a
	// cycle after its read (a jr's displacement, say) -- is kept across a run and put back; the
	// CPU stays held two clocks more, for the RAMs' outputs to settle on its address again.
	reg  [1:0] hd_hold;
	reg  [7:0] rom_q_cpu;
	reg        rom_for_hd;           // the request out is HDMA's
	assign rom_busy = rom_pend;
	assign hd_run = hd_running || hd_done || (hd_hold != 2'd0);   // (hd_done: the clock before the hold counter is set)
	always @(posedge clk) begin
		rom_req <= 1'b0;
		if (rst) begin
			rom_pend <= 1'b0; rom_q <= 8'hFF; arm <= 1'b0; hd_hold <= 2'd0; rom_q_cpu <= 8'hFF; rom_for_hd <= 1'b0;
			boot_done <= 1'b0; boot_st <= 3'd0; boot_busy <= 1'b0; cgb <= 1'b0;
			cart_type <= 8'd0; rom_size <= 8'd0; ram_size <= 8'd0; rom_addr <= 23'd0;
		end else if (!boot_done) begin
			// $0143 (the Color flag), $0147, $0148, $0149
			if (!boot_busy && !rom_pend) begin
				rom_addr <= (boot_st == 3'd0) ? 23'h143 : {14'd0, 9'h146} + {20'd0, boot_st};
				rom_req <= 1'b1; rom_pend <= 1'b1; boot_busy <= 1'b1;
			end
			if (rom_ack) begin
				rom_pend <= 1'b0; boot_busy <= 1'b0;
				case (boot_st)
					3'd0: cgb <= rom_data[7];
					3'd1: cart_type <= rom_data;
					3'd2: rom_size <= rom_data;
					default: ram_size <= rom_data;
				endcase
				if (boot_st == 3'd3) begin boot_done <= 1'b1; arm <= 1'b1; end
				else boot_st <= boot_st + 3'd1;
			end
		end else begin
			if (m_end) arm <= 1'b1;
			if (arm && !hd_running) begin
				arm <= 1'b0;
				if (ext_rd && ext_is_rom) begin
					rom_addr <= rom_phys;
					rom_req  <= 1'b1;
					rom_pend <= 1'b1;
					rom_for_hd <= 1'b0;
				end
			end
			if (hd_req) begin
				rom_addr <= rom_phys;
				rom_req  <= 1'b1;
				rom_pend <= 1'b1;
				rom_for_hd <= 1'b1;
			end
			if (rom_ack && rom_pend) begin
				rom_q <= rom_data;
				rom_pend <= 1'b0;
				if (!rom_for_hd) rom_q_cpu <= rom_data;
			end
			if (hd_done) begin rom_q <= rom_q_cpu; hd_hold <= 2'd2; end
			else if (hd_hold != 2'd0) hd_hold <= hd_hold - 2'd1;
		end
	end

	// --- the PPU --------------------------------------------------------------------------------------------------
	wire [7:0]  ppu_q, vram_q, oam_q;
	wire        irq_vblank, irq_stat;
	wire [1:0]  ppu_mode;
	wire        lcd_on;
	// the DMA takes the VRAM port when it reads from there; HDMA when it writes
	wire        dma_from_vram = dma_active && ext_is_vram;
	reg  [12:0] hd_dst;
	reg         hd_wr;
	reg  [7:0]  hd_data;
	wire [12:0] vram_a = hd_running ? hd_dst : dma_from_vram ? dma_a[12:0] : a[12:0];
	wire        dma_wr;
	reg  [7:0]  dma_data;
	wire        hblank_start;

	gb_ppu u_ppu (
		.clk(clk), .rst(rst), .ce(ce), .cgb(cgb),
		.reg_a(a[6:0]), .reg_we(cpu_wr && sel_ppu), .reg_d(cpu_dout), .reg_q(ppu_q),
		.vram_a(vram_a), .vram_we(hd_running ? hd_wr : (cpu_wr && sel_vram && !dma_from_vram)), .vram_force(hd_running),
		.vram_d(hd_running ? hd_data : cpu_dout), .vram_q(vram_q),
		.oam_a(dma_active ? dma_cnt : a[7:0]), .oam_we(dma_active ? dma_wr : (cpu_wr && sel_oam)),
		.oam_d(dma_active ? dma_data : cpu_dout), .oam_dma(dma_active), .oam_q(oam_q),
		.irq_vblank(irq_vblank), .irq_stat(irq_stat),
		.px_x(px_x), .px_y(px_y), .px_shade(px_shade), .px_rgb(px_rgb), .pixel_en(pixel_en), .frame_start(frame_start),
		.mode_out(ppu_mode), .lcd_on(lcd_on), .hblank_start(hblank_start)
	);

	// --- the Color's registers: KEY1, HDMA, RP, SVBK and the undocumented ones -------------------
	reg        key1_arm;
	reg [13:0] speed_cnt;             // T-cycles of the pause over a speed switch
	reg [6:0]  hd_len;                // blocks still to copy, minus one; $7F when done
	reg        hd_hbl;                // HDMA (a block each horizontal blank), not GDMA
	reg        hd_active;             // HDMA armed, waiting for blanks
	reg        hd_running_r;
	reg [1:0]  hd_st;
	reg [4:0]  hd_byte;
	reg [1:0]  hd_pace;
	reg [1:0]  rp;
	reg [7:0]  u72, u73, u74;
	reg [2:0]  u75;
	assign hd_running = hd_running_r;
	wire wr_cgb = cpu_wr && sel_io && cgb;
	wire hd_src_rom = (hd_src[15] == 1'b0);
	always @(posedge clk) begin
		speed_wake <= 1'b0; hd_wr <= 1'b0; hd_req <= 1'b0; hd_done <= 1'b0;
		if (rst) begin
			fast <= 1'b0; key1_arm <= 1'b0; speed_cnt <= 14'd0; svbk <= 3'd0; rp <= 2'd0;
			hd_src <= 16'hFFF0; hd_dst <= 13'h1FF0; hd_len <= 7'h7F; hd_hbl <= 1'b0; hd_active <= 1'b0;
			hd_running_r <= 1'b0; hd_st <= 2'd0; hd_byte <= 5'd0; hd_pace <= 2'd0; hd_data <= 8'd0;
			u72 <= 8'd0; u73 <= 8'd0; u74 <= 8'd0; u75 <= 3'd0;
		end else begin
			// the speed switch: STOP with KEY1 bit 0 set flips the speed; the CPU sits in its
			// STOP (a HALT here) for 8200 T-cycles and is woken
			if (wr_cgb && a[7:0] == 8'h4D) key1_arm <= cpu_dout[0];
			if (cpu_stop && cgb && key1_arm) begin fast <= ~fast; key1_arm <= 1'b0; speed_cnt <= 14'd8200; end
			if (speed_cnt != 14'd0 && ce) begin
				speed_cnt <= speed_cnt - 14'd1;
				if (speed_cnt == 14'd1) speed_wake <= 1'b1;
			end
			if (wr_cgb && a[7:0] == 8'h70) svbk <= cpu_dout[2:0];
			if (wr_cgb && a[7:0] == 8'h56) rp <= {cpu_dout[7], cpu_dout[0]};
			if (wr_cgb && a[7:0] == 8'h72) u72 <= cpu_dout;
			if (wr_cgb && a[7:0] == 8'h73) u73 <= cpu_dout;
			if (wr_cgb && a[7:0] == 8'h74) u74 <= cpu_dout;
			if (wr_cgb && a[7:0] == 8'h75) u75 <= cpu_dout[6:4];
			// HDMA's registers (the low four bits of the addresses are not kept)
			if (wr_cgb && a[7:0] == 8'h51) hd_src[15:8] <= cpu_dout;
			if (wr_cgb && a[7:0] == 8'h52) hd_src[7:0]  <= {cpu_dout[7:4], 4'd0};
			if (wr_cgb && a[7:0] == 8'h53) hd_dst[12:8] <= cpu_dout[4:0];
			if (wr_cgb && a[7:0] == 8'h54) hd_dst[7:0]  <= {cpu_dout[7:4], 4'd0};
			if (wr_cgb && a[7:0] == 8'h55) begin
				if (hd_active && !cpu_dout[7]) hd_active <= 1'b0;          // an HDMA stopped where it is
				else begin
					hd_len <= cpu_dout[6:0]; hd_hbl <= cpu_dout[7];
					if (cpu_dout[7]) hd_active <= 1'b1;                     // ...blocks from the next blank on
					else begin hd_running_r <= 1'b1; hd_st <= 2'd0; hd_byte <= 5'd0; hd_pace <= 2'd0; end   // GDMA: now
				end
			end
			// a horizontal blank begins: HDMA's block
			if (hblank_start && hd_active && !hd_running) begin hd_running_r <= 1'b1; hd_st <= 2'd0; hd_byte <= 5'd0; hd_pace <= 2'd0; end
			// the copy: a byte every two T-cycles -- asked for (ROM through the cartridge port,
			// RAM straight from its block RAM), taken, written to VRAM
			if (hd_running) case (hd_st)
				2'd0: if (!rom_pend) begin                                  // (the CPU's own fetch first)
					if (hd_src_rom) hd_req <= 1'b1;
					hd_st <= 2'd1;
				end
				2'd1: if (!hd_src_rom || (!rom_pend && !hd_req)) begin
					hd_data <= hd_src_rom ? rom_q : ext_is_cram ? (cram_ok ? cram_q : 8'hFF) : wram_q;
					hd_wr <= 1'b1; hd_st <= 2'd2;
				end
				2'd2: begin
					hd_src <= hd_src + 16'd1; hd_dst <= hd_dst + 13'd1; hd_byte <= hd_byte + 5'd1;
					hd_st <= 2'd3; hd_pace <= 2'd0;
				end
				default: if (ce) begin
					hd_pace <= hd_pace + 2'd1;
					if (hd_pace == 2'd1) begin
						if (hd_byte == 5'd16) begin
							hd_len <= hd_len - 7'd1;
							hd_byte <= 5'd0;
							if (hd_len == 7'd0 || hd_dst == 13'd0) begin  // all copied, or off the end of VRAM
								hd_len <= 7'h7F; hd_active <= 1'b0; hd_running_r <= 1'b0; hd_done <= 1'b1;
							end else if (hd_hbl) begin hd_running_r <= 1'b0; hd_done <= 1'b1; end
							else hd_st <= 2'd0;
						end else hd_st <= 2'd0;
					end
				end
			endcase
		end
	end

	// what the DMA is copying this M-cycle
	always @(*) begin
		if (ext_is_rom) dma_data = rom_q;
		else if (ext_is_vram) dma_data = vram_q;
		else if (ext_is_cram) dma_data = cram_ok ? cram_q : (rtc_sel && ram_en ? rtc_q : 8'hFF);
		else dma_data = wram_q;
	end
	assign dma_wr = m_end && dma_active;

	always @(posedge clk) begin
		if (rst) begin dma_active <= 1'b0; dma_pend <= 1'b0; dma_cnt <= 8'd0; dma_src <= cgb ? 8'h00 : 8'hFF; end
		else begin
			if (cpu_wr && sel_io && a[7:0] == 8'h46) begin dma_src <= cpu_dout; dma_pend <= 1'b1; end
			if (m_end) begin
				if (dma_active) begin
					if (dma_cnt == 8'd159) dma_active <= 1'b0;
					dma_cnt <= dma_cnt + 8'd1;
				end
				if (dma_pend) begin
					// one M-cycle after the write, the copy begins
					dma_pend <= 1'b0; dma_active <= 1'b1; dma_cnt <= 8'd0;
				end
			end
		end
	end

	// --- the APU --------------------------------------------------------------------------------------------------
	wire [7:0] apu_q;
	reg        div_bit4_q;
	reg [15:0] sysc;
	wire       div_bit4 = fast ? sysc[13] : sysc[12];    // DIV bit 4 (bit 5 at double speed): 512 Hz either way
	wire       fs_tick = div_bit4_q && !div_bit4;        // ...its falling edge
	gb_apu u_apu (
		.clk(clk), .rst(rst), .ce(ce), .fs_tick(fs_tick),
		.reg_a(a[5:0]), .reg_we(cpu_wr && sel_apu), .reg_d(cpu_dout), .reg_q(apu_q),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	// --- timer ------------------------------------------------------------------------------------------------------
	reg [7:0] tima, tma, tac;
	reg       tsel_q;
	reg [2:0] tima_ovf;          // T-cycles until the reload; 0 = none pending
	reg       div_hold;
	reg       tsel_bit;
	always @(*) begin
		case (tac[1:0])
			2'd0: tsel_bit = sysc[9];
			2'd1: tsel_bit = sysc[3];
			2'd2: tsel_bit = sysc[5];
			default: tsel_bit = sysc[7];
		endcase
		tsel_bit = tsel_bit & tac[2];
	end
	wire tima_tick = tsel_q && !tsel_bit;
	wire wr_div  = cpu_wr && sel_io && a[7:0] == 8'h04;
	wire wr_tima = cpu_wr && sel_io && a[7:0] == 8'h05;
	wire wr_tma  = cpu_wr && sel_io && a[7:0] == 8'h06;
	wire wr_tac  = cpu_wr && sel_io && a[7:0] == 8'h07;
	reg  irq_timer;

	always @(posedge clk) begin
		irq_timer <= 1'b0;
		if (rst) begin
			sysc <= 16'hAB00; div_hold <= 1'b0; tima <= 8'd0; tma <= 8'd0; tac <= 8'd0; tsel_q <= 1'b0; tima_ovf <= 3'd0; div_bit4_q <= 1'b0;
		end else begin
			tsel_q <= tsel_bit;
			div_bit4_q <= div_bit4;
			// A DIV write lands in the third T-cycle of its M-cycle (see gb_cpu); clear
			// the counter there and also skip the increment of the fourth, so its low
			// two bits stay in step with the M-cycle as they are on the console --
			// otherwise every timer tick afterwards falls mid-cycle, two T-cycles off.
			// STOP's pulse comes on the fourth T-cycle, which is already in step.
			if (wr_div) begin sysc <= 16'd0; div_hold <= 1'b1; end
			else if (cpu_stop) sysc <= 16'd0;
			else if (ce_cpu) begin
				if (div_hold) div_hold <= 1'b0;
				else sysc <= sysc + 16'd1;
			end
			if (wr_tma) tma <= cpu_dout;
			if (wr_tac) tac <= cpu_dout;

			// the overflow: TIMA reads 0 for one M-cycle, then TMA and the interrupt
			if (tima_ovf != 3'd0 && ce_cpu) begin
				if (tima_ovf == 3'd1) begin
					tima <= wr_tma ? cpu_dout : tma;
					irq_timer <= 1'b1;
				end
				tima_ovf <= tima_ovf - 3'd1;
			end
			if (tima_tick) begin
				if (tima == 8'hFF) begin tima <= 8'd0; tima_ovf <= 3'd4; end
				else tima <= tima + 8'd1;
			end
			if (wr_tima) begin
				// a write in the cycle after the overflow cancels the reload; one in
				// the reload cycle itself is lost to it
				if (!(tima_ovf == 3'd1 && ce_cpu)) tima <= cpu_dout;
				tima_ovf <= 3'd0;
			end
		end
	end

	// --- joypad -------------------------------------------------------------------------------------------------------
	reg  [1:0] p1_sel;           // bits 5:4 as written (1 = not selected)
	wire [3:0] joy_dpad = joy[3:0];              // down up left right
	wire [3:0] joy_btn  = joy[7:4];              // start select B A
	wire [3:0] p1_in = ~((p1_sel[0] ? 4'd0 : joy_dpad) | (p1_sel[1] ? 4'd0 : joy_btn));
	reg  [3:0] p1_in_q;
	wire       irq_joy = |(p1_in_q & ~p1_in);    // any line falling

	// --- serial ------------------------------------------------------------------------------------------------------------
	// Nobody is on the other end: a transfer with the internal clock shifts in $FF
	// over 8 bits at 8192 Hz and raises the interrupt; with the external clock
	// nothing ever happens, as on a console with no cable.
	reg [7:0]  sb;
	reg [1:0]  sc;               // bit 7 and bit 0
	reg [3:0]  sio_bits;
	reg [8:0]  sio_cnt;
	reg        irq_serial;
	assign sio_data  = sb;
	assign sio_start = cpu_wr && sel_io && a[7:0] == 8'h02 && cpu_dout[7];

	always @(posedge clk) begin
		irq_serial <= 1'b0;
		if (rst) begin
			// P1 reads $CF after the boot ROM: both groups selected, nothing pressed
			sb <= 8'd0; sc <= 2'b00; sio_bits <= 4'd0; sio_cnt <= 9'd0; p1_sel <= 2'b00; p1_in_q <= 4'hF;
		end else begin
			p1_in_q <= p1_in;
			if (cpu_wr && sel_io && a[7:0] == 8'h00) p1_sel <= cpu_dout[5:4];
			if (cpu_wr && sel_io && a[7:0] == 8'h01) sb <= cpu_dout;
			if (cpu_wr && sel_io && a[7:0] == 8'h02) begin
				sc <= {cpu_dout[7], cpu_dout[0]};
				if (cpu_dout[7] && cpu_dout[0]) begin sio_bits <= 4'd8; sio_cnt <= 9'd0; end
			end else if (sc[1] && sc[0] && sio_bits != 4'd0 && ce) begin
				if (sio_cnt == 9'd511) begin
					sio_cnt <= 9'd0;
					sb <= {sb[6:0], 1'b1};
					sio_bits <= sio_bits - 4'd1;
					if (sio_bits == 4'd1) begin sc[1] <= 1'b0; irq_serial <= 1'b1; end
				end else sio_cnt <= sio_cnt + 9'd1;
			end
		end
	end

	// --- IF / IE --------------------------------------------------------------------------------------------------------------
	always @(posedge clk) begin
		if (rst) begin if_r <= 5'b00001; ie_r <= 8'd0; end
		else begin
			if_r <= if_r | {irq_joy, irq_serial, irq_timer, irq_stat, irq_vblank};
			if (irq_ack) if_r[irq_n] <= 1'b0;
			if (cpu_wr && sel_io && a[7:0] == 8'h0F) if_r <= cpu_dout[4:0] | {irq_joy, irq_serial, irq_timer, irq_stat, irq_vblank};
			if (cpu_wr && sel_ie) ie_r <= cpu_dout;
		end
	end

	// --- reads ----------------------------------------------------------------------------------------------------------------
	reg [7:0] io_q;
	always @(*) begin
		if (sel_apu) io_q = apu_q;
		else if (sel_ppu) io_q = (a[3:0] == 4'h6) ? dma_src : ppu_q;
		else case (a[7:0])
			8'h00: io_q = {2'b11, p1_sel, p1_in};
			8'h01: io_q = sb;
			8'h02: io_q = {sc[1], 6'b111111, sc[0]};
			8'h04: io_q = sysc[15:8];
			8'h05: io_q = tima;
			8'h06: io_q = tma;
			8'h07: io_q = {5'b11111, tac[2:0]};
			8'h0F: io_q = {3'b111, if_r};
			// the Color's
			8'h4D: io_q = cgb ? {fast, 6'b111111, key1_arm} : 8'hFF;
			8'h55: io_q = cgb ? {!(hd_active || hd_running), hd_len} : 8'hFF;
			8'h56: io_q = cgb ? {rp[1], 5'b01111, 1'b1, rp[0]} : 8'hFF;     // (nobody shines at it: bit 1 reads 1)
			8'h70: io_q = cgb ? {5'b11111, svbk} : 8'hFF;
			8'h72: io_q = cgb ? u72 : 8'hFF;
			8'h73: io_q = cgb ? u73 : 8'hFF;
			8'h74: io_q = cgb ? u74 : 8'hFF;
			8'h75: io_q = cgb ? {1'b1, u75, 4'b1111} : 8'hFF;
			8'h76, 8'h77: io_q = cgb ? 8'h00 : 8'hFF;                       // (PCM12/34: the channels' samples; not kept)
			default: io_q = 8'hFF;
		endcase
	end

	always @(*) begin
		if (sel_rom)       cpu_din = dma_active ? 8'hFF : rom_q;
		else if (sel_vram) cpu_din = dma_from_vram ? 8'hFF : vram_q;
		else if (sel_cram) cpu_din = dma_active ? 8'hFF : (cram_ok ? cram_q : (rtc_sel && ram_en ? rtc_q : 8'hFF));
		else if (sel_wram) cpu_din = dma_active ? 8'hFF : wram_q;
		else if (sel_oam)  cpu_din = dma_active ? 8'hFF : oam_q;
		else if (sel_nil)  cpu_din = 8'h00;
		else if (sel_io)   cpu_din = io_q;
		else if (sel_hram) cpu_din = hram_q;
		else               cpu_din = ie_r;
	end

endmodule
