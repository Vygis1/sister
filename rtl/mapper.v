//////////////////////////////////////////////////////////////////////////////////
// mapper.v - the chip on the cartridge board.
//
// The CPU can only see 32 KB of program ROM and the PPU 8 KB of tiles. Early
// carts wired ROM straight to those windows and stopped there (NROM, mapper 0).
// Bigger games put a chip on the board that swaps chunks of a much larger ROM
// into those windows as the game runs. This module is that chip.
//
// Two are implemented:
//
//   0  NROM   no banking at all
//   1  MMC1   Nintendo's first, and the odd one: its registers are written one
//             BIT at a time through a shift register, because the chip had too
//             few pins to take a byte
//   2  UxROM  the simplest possible: one switchable 16 kB window, one fixed
//   4  MMC3   the common one: eight banking registers, mirroring control, and a
//             scanline counter that interrupts the CPU partway down the frame
//
// MMC3's counter is the interesting part. It has no idea what a scanline is --
// it counts rising edges of PPU address line A12, which flips as the PPU
// alternates between fetching background tiles from one pattern table and
// sprites from the other. That happens once per scanline while rendering, so
// counting A12 counts lines. It is a hack, it is what the games rely on, and it
// is why A12 has to be sampled on real PPU bus cycles rather than continuously:
// an address bus that keeps toggling with rendering switched off would hand out
// interrupts the game never asked for.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module mapper #(
	parameter PRG_AW = 18,            // byte-address width of PRG ROM (256 KB)
	parameter CHR_AW = 17             // byte-address width of CHR ROM (128 KB)
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,            // one PPU dot
	input  wire        cpu_ce,

	input  wire [3:0]  mapper_id,     // from the iNES header
	input  wire        hdr_mirror_v,  // header mirroring, used when the cart has no say
	input  wire [5:0]  prg_last,      // (PRG size / 8 KB) - 1

	input  wire [15:0] cpu_addr,
	input  wire [7:0]  cpu_dout,
	input  wire        cpu_we,

	input  wire [13:0] ppu_addr,
	input  wire        ppu_rd,        // high only on a real PPU memory cycle

	output wire [PRG_AW-1:0] prg_addr,
	output wire [CHR_AW-1:0] chr_addr,
	// Two bits, not one: MMC1 can point both name tables at the same kilobyte,
	// which a single vertical/horizontal flag cannot express.
	//   0 one-screen, lower   1 one-screen, upper   2 vertical   3 horizontal
	output wire [1:0]  mirror,
	output reg         irq
);

	wire is_mmc1 = (mapper_id == 4'd1);
	wire is_uxrom = (mapper_id == 4'd2);
	wire is_mmc3 = (mapper_id == 4'd4);

	// --- MMC3 registers -------------------------------------------------------
	reg [7:0] bank [0:7];             // R0..R7
	reg [2:0] bank_sel;
	reg       prg_mode;               // which window R6 lands in
	reg       chr_inv;                // swaps the 2 KB and 1 KB halves
	reg       mmc3_mirror;            // 0 = vertical, the opposite sense to iNES

	// Register writes are decoded from two address bits and one: the range picks
	// the pair, the low bit picks which of the pair.
	wire cart_wr  = cpu_ce && cpu_we && cpu_addr[15];
	wire [1:0] rng = cpu_addr[14:13];
	wire even      = ~cpu_addr[0];

	integer bi;
	always @(posedge clk) begin
		if (rst) begin
			bank_sel <= 3'd0; prg_mode <= 1'b0; chr_inv <= 1'b0;
			mmc3_mirror <= 1'b0;
			for (bi = 0; bi < 8; bi = bi + 1) bank[bi] <= 8'd0;
		end else if (cart_wr && is_mmc3) begin
			case (rng)
			2'b00: if (even) begin                        // $8000 bank select
					bank_sel <= cpu_dout[2:0];
					prg_mode <= cpu_dout[6];
					chr_inv  <= cpu_dout[7];
				end else bank[bank_sel] <= cpu_dout;      // $8001 bank data
			2'b01: if (even) mmc3_mirror <= cpu_dout[0];  // $A000 mirroring
			       // $A001 is PRG RAM protection; this cart always allows writes.
			default: ;                                    // $C000/$E000: IRQ, below
			endcase
		end
	end

	// --- MMC1 -------------------------------------------------------------------
	// Five writes to load one register. Each carries a single bit in its low
	// position; the fifth also carries the destination, in the address. A write
	// with bit 7 set abandons whatever was part-way through and returns the PRG
	// mapping to its default, which is how a game recovers if an interrupt lands
	// in the middle of a sequence.
	reg [4:0] m1_shift;
	reg [2:0] m1_count;
	reg [4:0] m1_ctrl;                // mirroring, PRG mode, CHR mode
	reg [4:0] m1_chr0, m1_chr1, m1_prg;

	wire [4:0] m1_in = {cpu_dout[0], m1_shift[4:1]};

	always @(posedge clk) begin
		if (rst) begin
			m1_shift <= 5'd0; m1_count <= 3'd0;
			m1_ctrl  <= 5'b01100;     // 32 kB PRG at $8000, horizontal mirroring
			m1_chr0  <= 5'd0; m1_chr1 <= 5'd0; m1_prg <= 5'd0;
		end else if (cart_wr && is_mmc1) begin
			if (cpu_dout[7]) begin
				m1_shift <= 5'd0;
				m1_count <= 3'd0;
				m1_ctrl  <= m1_ctrl | 5'b01100;
			end else if (m1_count == 3'd4) begin
				case (cpu_addr[14:13])
				2'd0: m1_ctrl <= m1_in;
				2'd1: m1_chr0 <= m1_in;
				2'd2: m1_chr1 <= m1_in;
				default: m1_prg <= m1_in;
				endcase
				m1_shift <= 5'd0;
				m1_count <= 3'd0;
			end else begin
				m1_shift <= m1_in;
				m1_count <= m1_count + 3'd1;
			end
		end
	end

	// --- UxROM --------------------------------------------------------------------
	// One register, no shifting, no protocol: whatever byte is written anywhere
	// in $8000-$FFFF becomes the bank at $8000. The top half is always the last
	// bank, which is where the vectors live.
	reg [4:0] ux_bank;
	always @(posedge clk) begin
		if (rst) ux_bank <= 5'd0;
		else if (cart_wr && is_uxrom) ux_bank <= cpu_dout[4:0];
	end

	// --- PRG banking ----------------------------------------------------------
	// Two of the four windows are fixed to the end of the ROM; which two depends
	// on the mode bit, and R6 moves between them.
	wire [5:0] prg_last1 = prg_last - 6'd1;
	reg  [5:0] prg_bank;
	always @* begin
		case (cpu_addr[14:13])
		2'b00:   prg_bank = prg_mode ? prg_last1 : bank[6][5:0];
		2'b01:   prg_bank = bank[7][5:0];
		2'b10:   prg_bank = prg_mode ? bank[6][5:0] : prg_last1;
		default: prg_bank = prg_last;
		endcase
	end

	wire [18:0] prg_mmc3 = {prg_bank, cpu_addr[12:0]};
	wire [18:0] prg_nrom = {4'd0, cpu_addr[14:0]};

	// UxROM: 16 kB switchable low, the last 16 kB fixed high.
	wire [5:0] ux_last = prg_last[5:1];       // in 16 kB units
	wire [18:0] prg_ux = cpu_addr[14] ? {ux_last[4:0], cpu_addr[13:0]}
	                                  : {ux_bank[4:0], cpu_addr[13:0]};

	// MMC1's PRG mode: 0 and 1 switch a whole 32 kB, 2 fixes the FIRST bank low
	// and switches high, 3 switches low and fixes the LAST bank high. Mode 3 is
	// the default and what most cartridges use.
	reg [4:0] m1_bank;
	always @* begin
		case (m1_ctrl[3:2])
		2'd0, 2'd1: m1_bank = {m1_prg[4:1], cpu_addr[14]};
		2'd2:       m1_bank = cpu_addr[14] ? m1_prg : 5'd0;
		default:    m1_bank = cpu_addr[14] ? ux_last[4:0] : m1_prg;
		endcase
	end
	wire [18:0] prg_mmc1 = {m1_bank, cpu_addr[13:0]};

	assign prg_addr = is_mmc3  ? prg_mmc3[PRG_AW-1:0]
	                : is_mmc1  ? prg_mmc1[PRG_AW-1:0]
	                : is_uxrom ? prg_ux[PRG_AW-1:0]
	                           : prg_nrom[PRG_AW-1:0];

	// --- CHR banking ----------------------------------------------------------
	// Half the pattern space is two 2 KB banks, the other half four 1 KB banks.
	// The inversion bit swaps which half is which, so it folds into A12.
	wire a12 = ppu_addr[12] ^ chr_inv;
	reg [7:0] chr_bank;
	always @* begin
		if (!a12)
			// A 2 KB bank ignores the low bit of the register and takes it from
			// the address instead.
			chr_bank = ppu_addr[11] ? {bank[1][7:1], ppu_addr[10]}
			                        : {bank[0][7:1], ppu_addr[10]};
		else case (ppu_addr[11:10])
			2'b00:   chr_bank = bank[2];
			2'b01:   chr_bank = bank[3];
			2'b10:   chr_bank = bank[4];
			default: chr_bank = bank[5];
		endcase
	end

	wire [17:0] chr_mmc3 = {chr_bank, ppu_addr[9:0]};
	wire [17:0] chr_nrom = {5'd0, ppu_addr[12:0]};

	// MMC1 CHR: one 8 kB bank, or two 4 kB banks.
	wire [17:0] chr_mmc1 = m1_ctrl[4]
	    ? {ppu_addr[12] ? m1_chr1 : m1_chr0, ppu_addr[11:0]}
	    : {m1_chr0[4:1], ppu_addr[12:0]};

	assign chr_addr = is_mmc3 ? chr_mmc3[CHR_AW-1:0]
	                : is_mmc1 ? chr_mmc1[CHR_AW-1:0]
	                          : chr_nrom[CHR_AW-1:0];

	// MMC3 says horizontal with a one, the iNES header says vertical with a one,
	// and MMC1 has four modes of its own. Each convention is translated here
	// rather than left for something downstream to guess at.
	assign mirror = is_mmc1 ? m1_ctrl[1:0]
	              : is_mmc3 ? (mmc3_mirror ? 2'd3 : 2'd2)
	                        : (hdr_mirror_v ? 2'd2 : 2'd3);

	// --- the scanline counter -------------------------------------------------
	// A12 has to be seen low for a while before a rise counts. Without that
	// filter the pattern-table fetches within a single scanline each look like a
	// new line and the counter runs many times too fast.
	reg       a12_q;
	reg [3:0] a12_low;
	wire      ppu_cycle = ce && ppu_rd;
	wire      a12_rise  = ppu_cycle && ppu_addr[12] && !a12_q && (a12_low >= 4'd8);

	reg [7:0] irq_latch, irq_counter;
	reg       irq_enable, irq_reload_req;

	wire       reload   = (irq_counter == 8'd0) || irq_reload_req;
	wire [7:0] next_cnt = reload ? irq_latch : (irq_counter - 8'd1);

	always @(posedge clk) begin
		if (rst) begin
			a12_q <= 1'b0; a12_low <= 4'd0;
			irq_latch <= 8'd0; irq_counter <= 8'd0;
			irq_enable <= 1'b0; irq_reload_req <= 1'b0; irq <= 1'b0;
		end else begin
			if (ppu_cycle) begin
				a12_q <= ppu_addr[12];
				if (ppu_addr[12]) a12_low <= 4'd0;
				else if (a12_low != 4'd15) a12_low <= a12_low + 4'd1;
			end

			if (a12_rise) begin
				irq_counter    <= next_cnt;
				irq_reload_req <= 1'b0;
				if (next_cnt == 8'd0 && irq_enable) irq <= 1'b1;
			end

			// Written after the counter so an acknowledge in the same clock wins.
			if (cart_wr && is_mmc3 && rng[1]) begin
				case ({rng[0], even})
				2'b01: irq_latch      <= cpu_dout;   // $C000 latch
				2'b00: irq_reload_req <= 1'b1;       // $C001 reload on the next rise
				2'b11: begin irq_enable <= 1'b0; irq <= 1'b0; end  // $E000 off + ack
				2'b10: irq_enable     <= 1'b1;       // $E001 on
				endcase
			end

			if (!is_mmc3) irq <= 1'b0;
		end
	end

endmodule

`default_nettype wire
