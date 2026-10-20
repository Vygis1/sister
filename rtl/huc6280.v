`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// huc6280.v - the PC Engine's processor: a 65C02 with Hudson's additions.
//
// What it has beyond the 6502 (cpu6502.v is the NES's NMOS one; this is written fresh):
// the 65C02's instructions (BRA, PHX/PHY/PLX/PLY, STZ, TRB/TSB, INC/DEC A, BIT #imm and
// indexed, the (zp) mode, JMP (abs,X), RMB/SMB, BBR/BBS), and Hudson's: SXY SAX SAY swaps,
// CLA CLX CLY, ST0/ST1/ST2 (a byte straight into the video chip), TAM/TMA and the eight
// mapping registers, the five block transfers (TII TDD TIN TIA TAI), TST, BSR, CSL/CSH
// (the speed), and SET with its T flag, which turns the next ADC/AND/EOR/ORA/SBC into a
// memory-to-memory operation on zero page X.
//
// --- memory -----------------------------------------------------------------------------
//
// The 64 kB the program sees is eight 8 kB banks, each mapped by MPRn to one of 256 pages
// of a 2 MB physical space: `addr` is the 21-bit physical address. Zero page and the stack
// are in whatever page MPR1 maps (offsets $0000-$00FF and $0100-$01FF of it), which is why a
// program sets MPR1 = $F8 (work RAM) first. Page $FF is the hardware: the top decodes the
// physical address $1FE000-$1FFFFF into the VDC, VCE, PSG, timer, pad port and interrupt
// control -- the timer and the interrupt registers are inside the real chip, but live in
// pce_top here with the rest. ST0/ST1/ST2 are plain writes to $1FE000 + 0 / 2 / 3.
//
// --- timing ---------------------------------------------------------------------------------
//
// One `ce` is one cycle of the 7.16 MHz clock; in low speed (CSL, the reset state) an
// instruction cycle takes four of them. Every instruction takes exactly the number of cycles
// the chip's table says (MAME's h6280, which agrees with the documentation): the bus
// accesses an instruction needs are done in order, and the rest of its cycles are spent
// idle. Games time raster effects and sound by these counts; nothing times the order of the
// reads inside an instruction, so that is not kept (the NES core keeps every dummy read;
// this one does not need to). A VDC or VCE access (physical $1FE000-$1FE7FF) costs one cycle
// more, as on the chip. A block transfer is 17 + 6 per byte and runs to the end.
//
// Interrupts are looked at between instructions: NMI (unused in the console), then the
// timer, IRQ1 (the VDC) and IRQ2 (the CD-ROM) in that order, the three through the I flag
// and the top's mask register. Entry is 7 cycles: the return address and P pushed (B clear),
// I set, D and T cleared, the vector read through bank 7 ($FFFA timer, $FFF8 IRQ1, $FFF6 IRQ2,
// $FFFC NMI, $FFFE reset). BRK is the same through $FFF6 with B set, 8 cycles.
//
// Bus: `addr`, `dout`, `we` and `rd` are registered -- what a state assigns is on the bus the
// next cycle, and the byte read arrives in `din` the cycle after that, which is how a block
// RAM or a cache answers. `left` counts the instruction's cycles down; a state that finds
// left == 1 is the instruction's last cycle and sets up the next opcode fetch (or the
// interrupt entry) itself, so the count comes out exactly.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module huc6280 (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,            // a 7.16 MHz cycle
	output reg  [20:0] addr,          // physical
	input  wire [7:0]  din,
	output reg  [7:0]  dout,
	output reg         we,
	output reg         rd,
	input  wire        irq1,          // already through the mask register
	input  wire        irq2,
	input  wire        irq_timer,
	input  wire        nmi,
	output reg         fast,          // CSH: 7.16 MHz cycles; CSL: 1.79
	output wire        sync,          // an opcode fetch cycle
	output wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p,
	output wire [15:0] dbg_pc,
	output wire [7:0]  dbg_mpr1
);

	// --- registers ---------------------------------------------------------------------------
	reg [7:0]  A, X, Y, S;
	reg [15:0] PC;
	reg        fC, fZ, fI, fD, fT, fV, fN;
	reg [7:0]  MPR [0:7];
	wire [7:0] P = {fN, fV, fT, 1'b0, fD, fI, fZ, fC};
	assign dbg_a = A; assign dbg_x = X; assign dbg_y = Y; assign dbg_s = S; assign dbg_p = P;
	assign dbg_pc = PC; assign dbg_mpr1 = MPR[1];

	// --- the speed: four clock cycles an instruction cycle in low speed ----------------------
	reg [1:0] slow;
	wire cyc = ce && (fast || slow == 2'd3);
	always @(posedge clk) if (rst) slow <= 2'd0; else if (ce) slow <= fast ? 2'd0 : slow + 2'd1;

	// --- the MMU -----------------------------------------------------------------------------------
	function [20:0] phys; input [15:0] l; begin phys = {MPR[l[15:13]], l[12:0]}; end endfunction
	function [20:0] zpa;  input [7:0] z;  begin zpa  = {MPR[1], 5'd0, z}; end endfunction
	function [20:0] stk;  input [7:0] s;  begin stk  = {MPR[1], 4'd0, 1'b1, s}; end endfunction
	function        slowio; input [20:0] a; begin slowio = (a[20:11] == 10'h3FC); end endfunction   // $1FE000-$1FE7FF: VDC, VCE

	// --- decode --------------------------------------------------------------------------------------
	localparam [4:0]
		M_IMP = 5'd0,  M_IMM = 5'd1,  M_ZP = 5'd2,   M_ZPX = 5'd3,  M_ZPY = 5'd4,  M_ABS = 5'd5,
		M_ABX = 5'd6,  M_ABY = 5'd7,  M_IDX = 5'd8,  M_IDY = 5'd9,  M_ZPI = 5'd10, M_REL = 5'd11,
		M_ZPR = 5'd12, M_IND = 5'd13, M_IAX = 5'd14, M_BLK = 5'd15, M_TZP = 5'd16, M_TZX = 5'd17,
		M_TAB = 5'd18, M_TAX = 5'd19;
	localparam [1:0] A_NONE = 2'd0, A_READ = 2'd1, A_WRITE = 2'd2, A_RMW = 2'd3;
	localparam [6:0]
		O_NOP=0,  O_LDA=1,  O_LDX=2,  O_LDY=3,  O_STA=4,  O_STX=5,  O_STY=6,  O_STZ=7,
		O_ADC=8,  O_SBC=9,  O_AND=10, O_ORA=11, O_EOR=12, O_CMP=13, O_CPX=14, O_CPY=15,
		O_BIT=16, O_ASL=17, O_LSR=18, O_ROL=19, O_ROR=20, O_INC=21, O_DEC=22, O_TSB=23,
		O_TRB=24, O_RMB=25, O_SMB=26, O_TST=27, O_INX=28, O_INY=29, O_DEX=30, O_DEY=31,
		O_INA=32, O_DEA=33, O_TAX=34, O_TAY=35, O_TXA=36, O_TYA=37, O_TSX=38, O_TXS=39,
		O_CLC=40, O_SEC=41, O_CLI=42, O_SEI=43, O_CLV=44, O_CLD=45, O_SED=46, O_SET=47,
		O_CLA=48, O_CLX=49, O_CLY=50, O_SXY=51, O_SAX=52, O_SAY=53, O_CSL=54, O_CSH=55,
		O_JMP=56, O_JSR=57, O_RTS=58, O_RTI=59, O_BRK=60, O_BSR=61, O_BRA=62, O_BCC=63,
		O_PHA=64, O_PHP=65, O_PHX=66, O_PHY=67, O_PLA=68, O_PLP=69, O_PLX=70, O_PLY=71,
		O_BBR=72, O_BBS=73, O_ST=74,  O_TAM=75, O_TMA=76, O_TII=77, O_TDD=78, O_TIN=79,
		O_TIA=80, O_TAI=81;

	reg [4:0] mode; reg [1:0] acc; reg [6:0] op; reg [4:0] ncyc;
	wire [7:0] opc = din;              // (looked at in the fetch state only)
	always @(*) begin
		mode = M_IMP; acc = A_NONE; op = O_NOP; ncyc = 5'd2;
		case (opc)
		8'h00: begin op = O_BRK; ncyc = 8; end
		8'h01: begin mode = M_IDX; acc = A_READ; op = O_ORA; ncyc = 7; end
		8'h02: begin op = O_SXY; ncyc = 3; end
		8'h03: begin mode = M_IMM; op = O_ST; ncyc = 4; end
		8'h04: begin mode = M_ZP; acc = A_RMW; op = O_TSB; ncyc = 6; end
		8'h05: begin mode = M_ZP; acc = A_READ; op = O_ORA; ncyc = 4; end
		8'h06: begin mode = M_ZP; acc = A_RMW; op = O_ASL; ncyc = 6; end
		8'h07, 8'h17, 8'h27, 8'h37, 8'h47, 8'h57, 8'h67, 8'h77: begin mode = M_ZP; acc = A_RMW; op = O_RMB; ncyc = 7; end
		8'h08: begin op = O_PHP; ncyc = 3; end
		8'h09: begin mode = M_IMM; acc = A_READ; op = O_ORA; ncyc = 2; end
		8'h0A: begin op = O_ASL; ncyc = 2; end
		8'h0C: begin mode = M_ABS; acc = A_RMW; op = O_TSB; ncyc = 7; end
		8'h0D: begin mode = M_ABS; acc = A_READ; op = O_ORA; ncyc = 5; end
		8'h0E: begin mode = M_ABS; acc = A_RMW; op = O_ASL; ncyc = 7; end
		8'h0F, 8'h1F, 8'h2F, 8'h3F, 8'h4F, 8'h5F, 8'h6F, 8'h7F: begin mode = M_ZPR; op = O_BBR; ncyc = 6; end
		8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0: begin mode = M_REL; op = O_BCC; ncyc = 2; end
		8'h11: begin mode = M_IDY; acc = A_READ; op = O_ORA; ncyc = 7; end
		8'h12: begin mode = M_ZPI; acc = A_READ; op = O_ORA; ncyc = 7; end
		8'h13: begin mode = M_IMM; op = O_ST; ncyc = 4; end
		8'h14: begin mode = M_ZP; acc = A_RMW; op = O_TRB; ncyc = 6; end
		8'h15: begin mode = M_ZPX; acc = A_READ; op = O_ORA; ncyc = 4; end
		8'h16: begin mode = M_ZPX; acc = A_RMW; op = O_ASL; ncyc = 6; end
		8'h18: begin op = O_CLC; end
		8'h19: begin mode = M_ABY; acc = A_READ; op = O_ORA; ncyc = 5; end
		8'h1A: begin op = O_INA; end
		8'h1C: begin mode = M_ABS; acc = A_RMW; op = O_TRB; ncyc = 7; end
		8'h1D: begin mode = M_ABX; acc = A_READ; op = O_ORA; ncyc = 5; end
		8'h1E: begin mode = M_ABX; acc = A_RMW; op = O_ASL; ncyc = 7; end
		8'h20: begin mode = M_ABS; op = O_JSR; ncyc = 7; end
		8'h21: begin mode = M_IDX; acc = A_READ; op = O_AND; ncyc = 7; end
		8'h22: begin op = O_SAX; ncyc = 3; end
		8'h23: begin mode = M_IMM; op = O_ST; ncyc = 4; end
		8'h24: begin mode = M_ZP; acc = A_READ; op = O_BIT; ncyc = 4; end
		8'h25: begin mode = M_ZP; acc = A_READ; op = O_AND; ncyc = 4; end
		8'h26: begin mode = M_ZP; acc = A_RMW; op = O_ROL; ncyc = 6; end
		8'h28: begin op = O_PLP; ncyc = 4; end
		8'h29: begin mode = M_IMM; acc = A_READ; op = O_AND; ncyc = 2; end
		8'h2A: begin op = O_ROL; ncyc = 2; end
		8'h2C: begin mode = M_ABS; acc = A_READ; op = O_BIT; ncyc = 5; end
		8'h2D: begin mode = M_ABS; acc = A_READ; op = O_AND; ncyc = 5; end
		8'h2E: begin mode = M_ABS; acc = A_RMW; op = O_ROL; ncyc = 7; end
		8'h31: begin mode = M_IDY; acc = A_READ; op = O_AND; ncyc = 7; end
		8'h32: begin mode = M_ZPI; acc = A_READ; op = O_AND; ncyc = 7; end
		8'h34: begin mode = M_ZPX; acc = A_READ; op = O_BIT; ncyc = 4; end
		8'h35: begin mode = M_ZPX; acc = A_READ; op = O_AND; ncyc = 4; end
		8'h36: begin mode = M_ZPX; acc = A_RMW; op = O_ROL; ncyc = 6; end
		8'h38: begin op = O_SEC; end
		8'h39: begin mode = M_ABY; acc = A_READ; op = O_AND; ncyc = 5; end
		8'h3A: begin op = O_DEA; end
		8'h3C: begin mode = M_ABX; acc = A_READ; op = O_BIT; ncyc = 5; end
		8'h3D: begin mode = M_ABX; acc = A_READ; op = O_AND; ncyc = 5; end
		8'h3E: begin mode = M_ABX; acc = A_RMW; op = O_ROL; ncyc = 7; end
		8'h40: begin op = O_RTI; ncyc = 7; end
		8'h41: begin mode = M_IDX; acc = A_READ; op = O_EOR; ncyc = 7; end
		8'h42: begin op = O_SAY; ncyc = 3; end
		8'h43: begin mode = M_IMM; op = O_TMA; ncyc = 4; end
		8'h44: begin mode = M_REL; op = O_BSR; ncyc = 8; end
		8'h45: begin mode = M_ZP; acc = A_READ; op = O_EOR; ncyc = 4; end
		8'h46: begin mode = M_ZP; acc = A_RMW; op = O_LSR; ncyc = 6; end
		8'h48: begin op = O_PHA; ncyc = 3; end
		8'h49: begin mode = M_IMM; acc = A_READ; op = O_EOR; ncyc = 2; end
		8'h4A: begin op = O_LSR; ncyc = 2; end
		8'h4C: begin mode = M_ABS; op = O_JMP; ncyc = 4; end
		8'h4D: begin mode = M_ABS; acc = A_READ; op = O_EOR; ncyc = 5; end
		8'h4E: begin mode = M_ABS; acc = A_RMW; op = O_LSR; ncyc = 7; end
		8'h51: begin mode = M_IDY; acc = A_READ; op = O_EOR; ncyc = 7; end
		8'h52: begin mode = M_ZPI; acc = A_READ; op = O_EOR; ncyc = 7; end
		8'h53: begin mode = M_IMM; op = O_TAM; ncyc = 5; end
		8'h54: begin op = O_CSL; ncyc = 3; end
		8'h55: begin mode = M_ZPX; acc = A_READ; op = O_EOR; ncyc = 4; end
		8'h56: begin mode = M_ZPX; acc = A_RMW; op = O_LSR; ncyc = 6; end
		8'h58: begin op = O_CLI; end
		8'h59: begin mode = M_ABY; acc = A_READ; op = O_EOR; ncyc = 5; end
		8'h5A: begin op = O_PHY; ncyc = 3; end
		8'h5D: begin mode = M_ABX; acc = A_READ; op = O_EOR; ncyc = 5; end
		8'h5E: begin mode = M_ABX; acc = A_RMW; op = O_LSR; ncyc = 7; end
		8'h60: begin op = O_RTS; ncyc = 7; end
		8'h61: begin mode = M_IDX; acc = A_READ; op = O_ADC; ncyc = 7; end
		8'h62: begin op = O_CLA; end
		8'h63: begin ncyc = 4; end
		8'h64: begin mode = M_ZP; acc = A_WRITE; op = O_STZ; ncyc = 4; end
		8'h65: begin mode = M_ZP; acc = A_READ; op = O_ADC; ncyc = 4; end
		8'h66: begin mode = M_ZP; acc = A_RMW; op = O_ROR; ncyc = 6; end
		8'h68: begin op = O_PLA; ncyc = 4; end
		8'h69: begin mode = M_IMM; acc = A_READ; op = O_ADC; ncyc = 2; end
		8'h6A: begin op = O_ROR; ncyc = 2; end
		8'h6C: begin mode = M_IND; op = O_JMP; ncyc = 7; end
		8'h6D: begin mode = M_ABS; acc = A_READ; op = O_ADC; ncyc = 5; end
		8'h6E: begin mode = M_ABS; acc = A_RMW; op = O_ROR; ncyc = 7; end
		8'h71: begin mode = M_IDY; acc = A_READ; op = O_ADC; ncyc = 7; end
		8'h72: begin mode = M_ZPI; acc = A_READ; op = O_ADC; ncyc = 7; end
		8'h73: begin mode = M_BLK; op = O_TII; ncyc = 17; end
		8'h74: begin mode = M_ZPX; acc = A_WRITE; op = O_STZ; ncyc = 4; end
		8'h75: begin mode = M_ZPX; acc = A_READ; op = O_ADC; ncyc = 4; end
		8'h76: begin mode = M_ZPX; acc = A_RMW; op = O_ROR; ncyc = 6; end
		8'h78: begin op = O_SEI; end
		8'h79: begin mode = M_ABY; acc = A_READ; op = O_ADC; ncyc = 5; end
		8'h7A: begin op = O_PLY; ncyc = 4; end
		8'h7C: begin mode = M_IAX; op = O_JMP; ncyc = 7; end
		8'h7D: begin mode = M_ABX; acc = A_READ; op = O_ADC; ncyc = 5; end
		8'h7E: begin mode = M_ABX; acc = A_RMW; op = O_ROR; ncyc = 7; end
		8'h80: begin mode = M_REL; op = O_BRA; ncyc = 4; end
		8'h81: begin mode = M_IDX; acc = A_WRITE; op = O_STA; ncyc = 7; end
		8'h82: begin op = O_CLX; end
		8'h83: begin mode = M_TZP; acc = A_READ; op = O_TST; ncyc = 7; end
		8'h84: begin mode = M_ZP; acc = A_WRITE; op = O_STY; ncyc = 4; end
		8'h85: begin mode = M_ZP; acc = A_WRITE; op = O_STA; ncyc = 4; end
		8'h86: begin mode = M_ZP; acc = A_WRITE; op = O_STX; ncyc = 4; end
		8'h87, 8'h97, 8'hA7, 8'hB7, 8'hC7, 8'hD7, 8'hE7, 8'hF7: begin mode = M_ZP; acc = A_RMW; op = O_SMB; ncyc = 7; end
		8'h88: begin op = O_DEY; end
		8'h89: begin mode = M_IMM; acc = A_READ; op = O_BIT; ncyc = 2; end
		8'h8A: begin op = O_TXA; end
		8'h8C: begin mode = M_ABS; acc = A_WRITE; op = O_STY; ncyc = 5; end
		8'h8D: begin mode = M_ABS; acc = A_WRITE; op = O_STA; ncyc = 5; end
		8'h8E: begin mode = M_ABS; acc = A_WRITE; op = O_STX; ncyc = 5; end
		8'h8F, 8'h9F, 8'hAF, 8'hBF, 8'hCF, 8'hDF, 8'hEF, 8'hFF: begin mode = M_ZPR; op = O_BBS; ncyc = 6; end
		8'h91: begin mode = M_IDY; acc = A_WRITE; op = O_STA; ncyc = 7; end
		8'h92: begin mode = M_ZPI; acc = A_WRITE; op = O_STA; ncyc = 7; end
		8'h93: begin mode = M_TAB; acc = A_READ; op = O_TST; ncyc = 8; end
		8'h94: begin mode = M_ZPX; acc = A_WRITE; op = O_STY; ncyc = 4; end
		8'h95: begin mode = M_ZPX; acc = A_WRITE; op = O_STA; ncyc = 4; end
		8'h96: begin mode = M_ZPY; acc = A_WRITE; op = O_STX; ncyc = 4; end
		8'h98: begin op = O_TYA; end
		8'h99: begin mode = M_ABY; acc = A_WRITE; op = O_STA; ncyc = 5; end
		8'h9A: begin op = O_TXS; end
		8'h9C: begin mode = M_ABS; acc = A_WRITE; op = O_STZ; ncyc = 5; end
		8'h9D: begin mode = M_ABX; acc = A_WRITE; op = O_STA; ncyc = 5; end
		8'h9E: begin mode = M_ABX; acc = A_WRITE; op = O_STZ; ncyc = 5; end
		8'hA0: begin mode = M_IMM; acc = A_READ; op = O_LDY; ncyc = 2; end
		8'hA1: begin mode = M_IDX; acc = A_READ; op = O_LDA; ncyc = 7; end
		8'hA2: begin mode = M_IMM; acc = A_READ; op = O_LDX; ncyc = 2; end
		8'hA3: begin mode = M_TZX; acc = A_READ; op = O_TST; ncyc = 7; end
		8'hA4: begin mode = M_ZP; acc = A_READ; op = O_LDY; ncyc = 4; end
		8'hA5: begin mode = M_ZP; acc = A_READ; op = O_LDA; ncyc = 4; end
		8'hA6: begin mode = M_ZP; acc = A_READ; op = O_LDX; ncyc = 4; end
		8'hA8: begin op = O_TAY; end
		8'hA9: begin mode = M_IMM; acc = A_READ; op = O_LDA; ncyc = 2; end
		8'hAA: begin op = O_TAX; end
		8'hAC: begin mode = M_ABS; acc = A_READ; op = O_LDY; ncyc = 5; end
		8'hAD: begin mode = M_ABS; acc = A_READ; op = O_LDA; ncyc = 5; end
		8'hAE: begin mode = M_ABS; acc = A_READ; op = O_LDX; ncyc = 5; end
		8'hB1: begin mode = M_IDY; acc = A_READ; op = O_LDA; ncyc = 7; end
		8'hB2: begin mode = M_ZPI; acc = A_READ; op = O_LDA; ncyc = 7; end
		8'hB3: begin mode = M_TAX; acc = A_READ; op = O_TST; ncyc = 8; end
		8'hB4: begin mode = M_ZPX; acc = A_READ; op = O_LDY; ncyc = 4; end
		8'hB5: begin mode = M_ZPX; acc = A_READ; op = O_LDA; ncyc = 4; end
		8'hB6: begin mode = M_ZPY; acc = A_READ; op = O_LDX; ncyc = 4; end
		8'hB8: begin op = O_CLV; end
		8'hB9: begin mode = M_ABY; acc = A_READ; op = O_LDA; ncyc = 5; end
		8'hBA: begin op = O_TSX; end
		8'hBC: begin mode = M_ABX; acc = A_READ; op = O_LDY; ncyc = 5; end
		8'hBD: begin mode = M_ABX; acc = A_READ; op = O_LDA; ncyc = 5; end
		8'hBE: begin mode = M_ABY; acc = A_READ; op = O_LDX; ncyc = 5; end
		8'hC0: begin mode = M_IMM; acc = A_READ; op = O_CPY; ncyc = 2; end
		8'hC1: begin mode = M_IDX; acc = A_READ; op = O_CMP; ncyc = 7; end
		8'hC2: begin op = O_CLY; end
		8'hC3: begin mode = M_BLK; op = O_TDD; ncyc = 17; end
		8'hC4: begin mode = M_ZP; acc = A_READ; op = O_CPY; ncyc = 4; end
		8'hC5: begin mode = M_ZP; acc = A_READ; op = O_CMP; ncyc = 4; end
		8'hC6: begin mode = M_ZP; acc = A_RMW; op = O_DEC; ncyc = 6; end
		8'hC8: begin op = O_INY; end
		8'hC9: begin mode = M_IMM; acc = A_READ; op = O_CMP; ncyc = 2; end
		8'hCA: begin op = O_DEX; end
		8'hCC: begin mode = M_ABS; acc = A_READ; op = O_CPY; ncyc = 5; end
		8'hCD: begin mode = M_ABS; acc = A_READ; op = O_CMP; ncyc = 5; end
		8'hCE: begin mode = M_ABS; acc = A_RMW; op = O_DEC; ncyc = 7; end
		8'hD1: begin mode = M_IDY; acc = A_READ; op = O_CMP; ncyc = 7; end
		8'hD2: begin mode = M_ZPI; acc = A_READ; op = O_CMP; ncyc = 7; end
		8'hD3: begin mode = M_BLK; op = O_TIN; ncyc = 17; end
		8'hD4: begin op = O_CSH; ncyc = 3; end
		8'hD5: begin mode = M_ZPX; acc = A_READ; op = O_CMP; ncyc = 4; end
		8'hD6: begin mode = M_ZPX; acc = A_RMW; op = O_DEC; ncyc = 6; end
		8'hD8: begin op = O_CLD; end
		8'hD9: begin mode = M_ABY; acc = A_READ; op = O_CMP; ncyc = 5; end
		8'hDA: begin op = O_PHX; ncyc = 3; end
		8'hDD: begin mode = M_ABX; acc = A_READ; op = O_CMP; ncyc = 5; end
		8'hDE: begin mode = M_ABX; acc = A_RMW; op = O_DEC; ncyc = 7; end
		8'hE0: begin mode = M_IMM; acc = A_READ; op = O_CPX; ncyc = 2; end
		8'hE1: begin mode = M_IDX; acc = A_READ; op = O_SBC; ncyc = 7; end
		8'hE3: begin mode = M_BLK; op = O_TIA; ncyc = 17; end
		8'hE4: begin mode = M_ZP; acc = A_READ; op = O_CPX; ncyc = 4; end
		8'hE5: begin mode = M_ZP; acc = A_READ; op = O_SBC; ncyc = 4; end
		8'hE6: begin mode = M_ZP; acc = A_RMW; op = O_INC; ncyc = 6; end
		8'hE8: begin op = O_INX; end
		8'hE9: begin mode = M_IMM; acc = A_READ; op = O_SBC; ncyc = 2; end
		8'hEC: begin mode = M_ABS; acc = A_READ; op = O_CPX; ncyc = 5; end
		8'hED: begin mode = M_ABS; acc = A_READ; op = O_SBC; ncyc = 5; end
		8'hEE: begin mode = M_ABS; acc = A_RMW; op = O_INC; ncyc = 7; end
		8'hF1: begin mode = M_IDY; acc = A_READ; op = O_SBC; ncyc = 7; end
		8'hF2: begin mode = M_ZPI; acc = A_READ; op = O_SBC; ncyc = 7; end
		8'hF3: begin mode = M_BLK; op = O_TAI; ncyc = 17; end
		8'hF4: begin op = O_SET; end
		8'hF5: begin mode = M_ZPX; acc = A_READ; op = O_SBC; ncyc = 4; end
		8'hF6: begin mode = M_ZPX; acc = A_RMW; op = O_INC; ncyc = 6; end
		8'hF8: begin op = O_SED; end
		8'hF9: begin mode = M_ABY; acc = A_READ; op = O_SBC; ncyc = 5; end
		8'hFA: begin op = O_PLX; ncyc = 4; end
		8'hFD: begin mode = M_ABX; acc = A_READ; op = O_SBC; ncyc = 5; end
		8'hFE: begin mode = M_ABX; acc = A_RMW; op = O_INC; ncyc = 7; end
		default: ;                                                  // the rest: NOP, 2 cycles
		endcase
	end
	wire op_alu = (op == O_ADC || op == O_AND || op == O_EOR || op == O_ORA || op == O_SBC);
	wire [2:0] opr_n = (mode == M_IMM || mode == M_ZP || mode == M_ZPX || mode == M_ZPY ||
	                    mode == M_IDX || mode == M_IDY || mode == M_ZPI || mode == M_REL) ? 3'd1 :
	                   (mode == M_ABS || mode == M_ABX || mode == M_ABY || mode == M_IND || mode == M_IAX ||
	                    mode == M_ZPR || mode == M_TZP || mode == M_TZX) ? 3'd2 :
	                   (mode == M_TAB || mode == M_TAX) ? 3'd3 : (mode == M_BLK) ? 3'd6 : 3'd0;

	// --- states --------------------------------------------------------------------------------------
	localparam [5:0]
		S_RST0 = 6'd0,  S_RST1 = 6'd1,  S_RST2 = 6'd2,  S_FETCH = 6'd3,  S_OPR = 6'd4,   S_ZPX = 6'd5,
		S_PTRL = 6'd6,  S_PTRH = 6'd7,  S_IDXY = 6'd8,  S_READ = 6'd9,   S_EXEC = 6'd10, S_MOD = 6'd11,
		S_TREAD = 6'd13, S_TWRITE = 6'd14, S_PAD = 6'd15, S_PUSH = 6'd16, S_PULL = 6'd17,
		S_VECL = 6'd19, S_VECH = 6'd20, S_JSR1 = 6'd21, S_JSR2 = 6'd22, S_RTS1 = 6'd23,
		S_RTS2 = 6'd24, S_RTI1 = 6'd25, S_RTI2 = 6'd26, S_RTI3 = 6'd27, S_BLKR = 6'd28, S_BLKW = 6'd29,
		S_BLKP = 6'd30, S_IRQ0 = 6'd31, S_IRQ1 = 6'd32, S_IRQ2 = 6'd33, S_IRQ3 = 6'd34, S_BBR = 6'd35,
		S_INDL = 6'd36, S_INDH = 6'd37;
	reg [5:0]  st;
	reg [7:0]  IR;
	reg [4:0]  imode; reg [1:0] iacc; reg [6:0] iop;
	reg [5:0]  left;                  // cycles still to spend on this instruction, this one included
	reg [7:0]  opr [0:5];             // operand bytes
	reg [2:0]  nopr, iopr;            // how many, how many in hand
	reg [15:0] EA;                    // the effective logical address
	reg [7:0]  D;                     // the byte read (or being written back)
	reg [7:0]  tmpz;                  // T mode: the zero page X byte
	reg        t_mode;                // this ADC/AND/EOR/ORA/SBC goes through zero page X
	reg [16:0] blen;                  // block transfer bytes left
	reg [15:0] bsrc, bdst;
	reg        balt;                  // the alternating side of TIA/TAI
	reg [2:0]  irq_sel;               // which vector: 1 NMI, 2 timer, 3 IRQ1, 4 IRQ2, 5 BRK
	reg        nmi_q, nmi_pend;
	reg        penalty;               // a VDC/VCE access just happened: one cycle more
	assign sync = (st == S_FETCH);

	// --- the ALU --------------------------------------------------------------------------------------
	// The operand is the byte arriving now (din, in the operand or read state) or the one
	// kept (D); the other side A, or the zero page X byte in T mode. Decimal ADC/SBC as the
	// 65C02 does them: N and Z from the adjusted result.
	wire [7:0] Dv  = (st == S_OPR || st == S_READ) ? din : D;
	wire [7:0] opa = t_mode ? tmpz : A;
	reg [7:0] res; reg rC, rZ, rV, rN; reg flags_nz, flags_c, flags_v;
	reg [4:0] al; reg [5:0] ah; reg [8:0] bin;
	always @(*) begin
		res = 8'd0; rC = fC; rZ = fZ; rV = fV; rN = fN; flags_nz = 1'b0; flags_c = 1'b0; flags_v = 1'b0;
		al = 5'd0; ah = 6'd0; bin = 9'd0;
		case (iop)
		O_ADC: begin
			bin = {1'b0, opa} + {1'b0, Dv} + {8'd0, fC};
			if (!fD) begin res = bin[7:0]; rC = bin[8]; rV = (opa[7] == Dv[7]) && (res[7] != opa[7]); end
			else begin
				// (Bruce Clark's description of the 65C02: a low nibble past 9 carries and wraps,
				// V from the sum before the high adjust, the flags from the adjusted result)
				al = {1'b0, opa[3:0]} + {1'b0, Dv[3:0]} + {4'd0, fC};
				if (al > 5'd9) al = {1'b1, al[3:0] + 4'd6};
				ah = {2'd0, opa[7:4]} + {2'd0, Dv[7:4]} + {5'd0, al[4]};
				rV = (opa[7] == Dv[7]) && (ah[3] != opa[7]);
				if (ah > 6'd9) ah = ah + 6'd6;
				rC = ah[4] | ah[5];
				res = {ah[3:0], al[3:0]};
			end
			flags_nz = 1; flags_c = 1; flags_v = 1;
		end
		O_SBC: begin
			bin = {1'b0, opa} - {1'b0, Dv} - {8'd0, !fC};
			rC = !bin[8]; rV = (opa[7] != Dv[7]) && (bin[7] != opa[7]);
			if (!fD) res = bin[7:0];
			else begin
				// (the 65C02: the binary difference, less $60 if it borrowed, less 6 if the low
				// nibble did; C and V as in binary, N and Z from what is left)
				al = {1'b0, opa[3:0]} - {1'b0, Dv[3:0]} - {4'd0, !fC};
				res = bin[7:0] - (bin[8] ? 8'h60 : 8'h00) - (al[4] ? 8'h06 : 8'h00);
			end
			flags_nz = 1; flags_c = 1; flags_v = 1;
		end
		O_AND: begin res = opa & Dv; flags_nz = 1; end
		O_ORA: begin res = opa | Dv; flags_nz = 1; end
		O_EOR: begin res = opa ^ Dv; flags_nz = 1; end
		O_CMP: begin bin = {1'b0, A} - {1'b0, Dv}; res = bin[7:0]; rC = !bin[8]; flags_nz = 1; flags_c = 1; end
		O_CPX: begin bin = {1'b0, X} - {1'b0, Dv}; res = bin[7:0]; rC = !bin[8]; flags_nz = 1; flags_c = 1; end
		O_CPY: begin bin = {1'b0, Y} - {1'b0, Dv}; res = bin[7:0]; rC = !bin[8]; flags_nz = 1; flags_c = 1; end
		O_ASL: begin res = {Dv[6:0], 1'b0}; rC = Dv[7]; flags_nz = 1; flags_c = 1; end
		O_LSR: begin res = {1'b0, Dv[7:1]}; rC = Dv[0]; flags_nz = 1; flags_c = 1; end
		O_ROL: begin res = {Dv[6:0], fC}; rC = Dv[7]; flags_nz = 1; flags_c = 1; end
		O_ROR: begin res = {fC, Dv[7:1]}; rC = Dv[0]; flags_nz = 1; flags_c = 1; end
		O_INC: begin res = Dv + 8'd1; flags_nz = 1; end
		O_DEC: begin res = Dv - 8'd1; flags_nz = 1; end
		O_TSB: begin res = Dv | A; end
		O_TRB: begin res = Dv & ~A; end
		O_RMB: begin res = Dv & ~(8'd1 << IR[6:4]); end
		O_SMB: begin res = Dv | (8'd1 << IR[6:4]); end
		default: begin res = Dv; flags_nz = 1; end        // LDA/LDX/LDY
		endcase
		if (flags_nz) begin rZ = (res == 8'd0); rN = res[7]; end
	end
	// the accumulator shifts (ASL A and friends)
	wire [7:0] ash = (iop == O_ASL) ? {A[6:0], 1'b0} : (iop == O_LSR) ? {1'b0, A[7:1]} : (iop == O_ROL) ? {A[6:0], fC} : {fC, A[7:1]};
	wire       ashc = (iop == O_ASL || iop == O_ROL) ? A[7] : A[0];

	// --- the sequencer ------------------------------------------------------------------------------
	wire irq_any = nmi_pend || (!fI && (irq_timer || irq1 || irq2));
	wire branch_taken = (iop == O_BRA) || (iop == O_BSR) ||
	                    (IR[7:6] == 2'b00 ? (fN == IR[5]) : IR[7:6] == 2'b01 ? (fV == IR[5]) :
	                     IR[7:6] == 2'b10 ? (fC == IR[5]) : (fZ == IR[5]));
	wire [15:0] pc1 = PC + 16'd1;                                   // (the PC after this operand byte)
	wire [15:0] pc_rel = pc1 + {{8{din[7]}}, din};                 // a branch's target, from the byte arriving
	wire [15:0] pc_rel2 = PC + {{8{opr[1][7]}}, opr[1]};           // BBR/BBS's (both operands in hand)
	wire [15:0] blk_src_next = (iop == O_TDD) ? bsrc - 16'd1 : (iop == O_TAI) ? (balt ? bsrc - 16'd1 : bsrc + 16'd1) : bsrc + 16'd1;
	wire [15:0] blk_dst_next = (iop == O_TDD) ? bdst - 16'd1 : (iop == O_TIN) ? bdst : (iop == O_TIA) ? (balt ? bdst - 16'd1 : bdst + 16'd1) : bdst + 16'd1;
	wire [7:0]  st_val = (iop == O_STA) ? A : (iop == O_STX) ? X : (iop == O_STY) ? Y : 8'd0;   // what a store writes (STZ: 0)
	wire [15:0] ea_ix = (imode == M_ABY || imode == M_IDY) ? EA + {8'd0, Y} : (imode == M_TAX) ? {opr[2], opr[1]} + {8'd0, X} : EA + {8'd0, X};
	wire [20:0] rmw_addr = (imode == M_ZP || imode == M_ZPX) ? zpa(EA[7:0]) : phys(EA);
	wire        last = (left == 6'd1);                              // this is the instruction's last cycle
	wire [7:0]  pushed_p = (irq_sel == 3'd5 || iop == O_PHP) ? (P | 8'h10) : P;

	// the operation on the registers: implied ones, and the read ones once their byte is in (Dv)
	task exec_op;
		begin
			st <= S_PAD;
			case (iop)
			O_LDA: begin A <= Dv; fZ <= rZ; fN <= rN; end
			O_LDX: begin X <= Dv; fZ <= rZ; fN <= rN; end
			O_LDY: begin Y <= Dv; fZ <= rZ; fN <= rN; end
			O_ADC, O_SBC, O_AND, O_ORA, O_EOR: begin A <= res; fZ <= rZ; fN <= rN; if (flags_c) fC <= rC; if (flags_v) fV <= rV; end
			O_CMP, O_CPX, O_CPY: begin fZ <= rZ; fN <= rN; fC <= rC; end
			O_BIT: begin fZ <= ((A & Dv) == 8'd0); if (imode != M_IMM) begin fN <= Dv[7]; fV <= Dv[6]; end end
			O_TST: begin fZ <= ((opr[0] & Dv) == 8'd0); fN <= Dv[7]; fV <= Dv[6]; end
			O_ASL, O_LSR, O_ROL, O_ROR: begin A <= ash; fC <= ashc; fZ <= (ash == 8'd0); fN <= ash[7]; end
			O_INA: begin A <= A + 8'd1; fZ <= (A == 8'hFF); fN <= (A == 8'h7F) || (A[7] && A != 8'hFF); end
			O_DEA: begin A <= A - 8'd1; fZ <= (A == 8'd1); fN <= (A == 8'd0) || (A[7] && A != 8'h80); end
			O_INX: begin X <= X + 8'd1; fZ <= (X == 8'hFF); fN <= (X == 8'h7F) || (X[7] && X != 8'hFF); end
			O_DEX: begin X <= X - 8'd1; fZ <= (X == 8'd1); fN <= (X == 8'd0) || (X[7] && X != 8'h80); end
			O_INY: begin Y <= Y + 8'd1; fZ <= (Y == 8'hFF); fN <= (Y == 8'h7F) || (Y[7] && Y != 8'hFF); end
			O_DEY: begin Y <= Y - 8'd1; fZ <= (Y == 8'd1); fN <= (Y == 8'd0) || (Y[7] && Y != 8'h80); end
			O_TAX: begin X <= A; fZ <= (A == 8'd0); fN <= A[7]; end
			O_TAY: begin Y <= A; fZ <= (A == 8'd0); fN <= A[7]; end
			O_TXA: begin A <= X; fZ <= (X == 8'd0); fN <= X[7]; end
			O_TYA: begin A <= Y; fZ <= (Y == 8'd0); fN <= Y[7]; end
			O_TSX: begin X <= S; fZ <= (S == 8'd0); fN <= S[7]; end
			O_TXS: S <= X;
			O_CLC: fC <= 0;  O_SEC: fC <= 1;  O_CLI: fI <= 0;  O_SEI: fI <= 1;
			O_CLV: fV <= 0;  O_CLD: fD <= 0;  O_SED: fD <= 1;  O_SET: fT <= 1;
			O_CLA: A <= 8'd0; O_CLX: X <= 8'd0; O_CLY: Y <= 8'd0;
			O_SXY: begin X <= Y; Y <= X; end
			O_SAX: begin A <= X; X <= A; end
			O_SAY: begin A <= Y; Y <= A; end
			O_CSL: fast <= 1'b0;
			O_CSH: fast <= 1'b1;
			O_PHA, O_PHX, O_PHY, O_PHP: begin addr <= stk(S); we <= 1'b1; S <= S - 8'd1; dout <= (iop == O_PHA) ? A : (iop == O_PHX) ? X : (iop == O_PHY) ? Y : pushed_p; end
			O_PLA, O_PLX, O_PLY, O_PLP: begin addr <= stk(S + 8'd1); rd <= 1'b1; S <= S + 8'd1; st <= S_PULL; end
			O_RTS: begin addr <= stk(S + 8'd1); rd <= 1'b1; S <= S + 8'd1; st <= S_RTS1; end
			O_RTI: begin addr <= stk(S + 8'd1); rd <= 1'b1; S <= S + 8'd1; st <= S_RTI1; end
			O_BRK: begin irq_sel <= 3'd5; PC <= pc1; st <= S_IRQ1; end     // (the return address skips the padding byte)
			default: ;
			endcase
		end
	endtask

	integer k;
	reg fin, extend; reg [15:0] npc;  // set by a state that ends the instruction: the PC to go on from; extend: it added cycles
	always @(posedge clk) begin
		if (rst) begin
			st <= S_RST0; A <= 8'd0; X <= 8'd0; Y <= 8'd0; S <= 8'hFF; PC <= 16'd0;
			fC <= 0; fZ <= 0; fI <= 1; fD <= 0; fT <= 0; fV <= 0; fN <= 0;
			for (k = 0; k < 8; k = k + 1) MPR[k] <= 8'd0;
			fast <= 1'b0; addr <= 21'd0; dout <= 8'd0; we <= 1'b0; rd <= 1'b0; left <= 6'd0;
			nmi_q <= 1'b0; nmi_pend <= 1'b0; irq_sel <= 3'd0; penalty <= 1'b0; t_mode <= 1'b0;
			imode <= M_IMP; iacc <= A_NONE; iop <= O_NOP; nopr <= 3'd0; iopr <= 3'd0;
			EA <= 16'd0; D <= 8'd0; tmpz <= 8'd0; blen <= 17'd0; bsrc <= 16'd0; bdst <= 16'd0; balt <= 1'b0; IR <= 8'd0;
		end else begin
			nmi_q <= nmi;
			if (nmi && !nmi_q) nmi_pend <= 1'b1;
			if (cyc) begin
				we <= 1'b0; rd <= 1'b0;
				fin = 1'b0; extend = 1'b0; npc = PC;
				if (penalty) penalty <= 1'b0;     // the video chips' extra cycle: nothing moves
				else begin
				if (left != 6'd0) left <= left - 6'd1;
				case (st)
				// --- reset: the vector through bank 7 (MPR7 = 0) -------------------------------------
				S_RST0: begin addr <= phys(16'hFFFE); rd <= 1'b1; st <= S_RST1; end
				S_RST1: begin addr <= phys(16'hFFFF); rd <= 1'b1; st <= S_RST2; PC[7:0] <= din; end
				S_RST2: begin fin = 1'b1; npc = {din, PC[7:0]}; irq_sel <= 3'd0; end

				// --- an opcode -----------------------------------------------------------------------------
				S_FETCH: begin
					IR <= opc; imode <= mode; iacc <= acc; iop <= op;
					left <= {1'b0, ncyc} - 6'd1 + (fT && op_alu ? 6'd3 : 6'd0) + (fD && (op == O_ADC || op == O_SBC) ? 6'd1 : 6'd0);
					nopr <= opr_n; iopr <= 3'd0;
					t_mode <= fT && op_alu;
					if (op != O_SET) fT <= 1'b0;
					PC <= pc1;
					if (opr_n != 3'd0) begin addr <= phys(pc1); rd <= 1'b1; st <= S_OPR; end
					else st <= S_EXEC;
				end
				// operand bytes, one a cycle; the last one may be the whole instruction (immediates, branches)
				S_OPR: begin
					opr[iopr] <= din; iopr <= iopr + 3'd1; PC <= pc1; npc = pc1;
					if (iopr + 3'd1 < nopr) begin addr <= phys(pc1); rd <= 1'b1; end
					else case (imode)
						M_IMM: begin
							D <= din;
							if (t_mode) begin addr <= zpa(X); rd <= 1'b1; st <= S_TREAD; end
							else case (iop)
								O_ST: begin addr <= {10'h3FC, 9'd0, IR[5:4] == 2'd0 ? 2'd0 : IR[5:4] == 2'd1 ? 2'd2 : 2'd3}; dout <= din; we <= 1'b1; penalty <= 1'b1; st <= S_PAD; end
								O_TAM: begin for (k = 0; k < 8; k = k + 1) if (din[k]) MPR[k] <= A; st <= S_PAD; end
								O_TMA: begin for (k = 0; k < 8; k = k + 1) if (din[k]) A <= MPR[k]; st <= S_PAD; end
								default: exec_op;
							endcase
						end
						M_REL: begin
							if (iop == O_BSR) begin st <= S_PUSH; EA <= pc_rel; end
							else if (branch_taken) begin PC <= pc_rel; npc = pc_rel; if (iop == O_BCC) begin left <= left + 6'd1; extend = 1'b1; end st <= S_PAD; end
							else st <= S_PAD;
						end
						M_ZP: begin
							EA <= {8'd0, din}; addr <= zpa(din);
							if (iacc == A_WRITE) begin dout <= st_val; we <= 1'b1; penalty <= slowio(zpa(din)); st <= S_PAD; end
							else begin rd <= 1'b1; st <= S_READ; end
						end
						M_ZPX, M_ZPY, M_TZX: st <= S_ZPX;
						M_ABS: begin
							EA <= {din, opr[0]};
							if (iop == O_JMP) begin PC <= {din, opr[0]}; npc = {din, opr[0]}; st <= S_PAD; end
							else if (iop == O_JSR) st <= S_PUSH;
							else if (iacc == A_WRITE) begin addr <= phys({din, opr[0]}); dout <= st_val; we <= 1'b1; penalty <= slowio(phys({din, opr[0]})); st <= S_PAD; end
							else begin addr <= phys({din, opr[0]}); rd <= 1'b1; st <= S_READ; end
						end
						M_TAB: begin EA <= {din, opr[1]}; addr <= phys({din, opr[1]}); rd <= 1'b1; st <= S_READ; end   // (TST: the mask came first)
						M_ABX, M_ABY, M_TAX: begin EA <= {din, opr[0]}; st <= S_IDXY; end
						M_IDX: st <= S_ZPX;
						M_IDY, M_ZPI: begin addr <= zpa(din); rd <= 1'b1; st <= S_PTRL; end     // (the operand is arriving now)
						M_IND: begin EA <= {din, opr[0]}; addr <= phys({din, opr[0]}); rd <= 1'b1; st <= S_INDL; end
						M_IAX: begin EA <= {din, opr[0]}; st <= S_IDXY; end
						M_ZPR: begin addr <= zpa(opr[0]); rd <= 1'b1; st <= S_BBR; end
						M_TZP: begin EA <= {8'd0, din}; addr <= zpa(din); rd <= 1'b1; st <= S_READ; end
						M_BLK: begin
							bsrc <= {opr[1], opr[0]}; bdst <= {opr[3], opr[2]}; blen <= ({din, opr[4]} == 16'd0) ? 17'h10000 : {1'b0, din, opr[4]};
							balt <= 1'b0; addr <= phys({opr[1], opr[0]}); rd <= 1'b1; st <= S_BLKR;
						end
						default: st <= S_EXEC;
					endcase
				end
				// zero page plus an index: one cycle, then the read / write / pointer
				S_ZPX: begin
					EA <= {8'd0, (imode == M_ZPY) ? opr[0] + Y : (imode == M_TZX) ? opr[1] + X : opr[0] + X};
					addr <= zpa((imode == M_IDX) ? opr[0] + X : (imode == M_ZPY) ? opr[0] + Y : (imode == M_TZX) ? opr[1] + X : opr[0] + X);
					if (imode == M_IDX) begin rd <= 1'b1; st <= S_PTRL; end
					else if (iacc == A_WRITE) begin dout <= st_val; we <= 1'b1; st <= S_PAD; end
					else begin rd <= 1'b1; st <= S_READ; end
				end
				// a zero page pointer: low byte in hand, ask for the high
				S_PTRL: begin
					EA[7:0] <= din;
					addr <= zpa((imode == M_IDX ? opr[0] + X : opr[0]) + 8'd1); rd <= 1'b1; st <= S_PTRH;
				end
				S_PTRH: begin
					EA[15:8] <= din;
					if (imode == M_IDY) st <= S_IDXY;
					else if (iacc == A_WRITE) begin addr <= phys({din, EA[7:0]}); dout <= st_val; we <= 1'b1; penalty <= slowio(phys({din, EA[7:0]})); st <= S_PAD; end
					else begin addr <= phys({din, EA[7:0]}); rd <= 1'b1; st <= S_READ; end
				end
				// an absolute (or pointer) address plus an index: one cycle
				S_IDXY: begin
					EA <= ea_ix; addr <= phys(ea_ix);
					if (imode == M_IAX) begin rd <= 1'b1; st <= S_INDL; end
					else if (iacc == A_WRITE) begin dout <= st_val; we <= 1'b1; penalty <= slowio(phys(ea_ix)); st <= S_PAD; end
					else begin rd <= 1'b1; st <= S_READ; end
				end
				// JMP (abs) / (abs,X): the target through EA, low byte then high
				S_INDL: begin D <= din; addr <= phys(EA + 16'd1); rd <= 1'b1; st <= S_INDH; end
				S_INDH: begin PC <= {din, D}; npc = {din, D}; st <= S_PAD; end
				// the data byte arrives: read instructions finish here (or go on to T mode / modify)
				S_READ: begin
					D <= din; penalty <= slowio(addr);
					if (t_mode) begin addr <= zpa(X); rd <= 1'b1; st <= S_TREAD; end
					else if (iacc == A_RMW) st <= S_MOD;
					else exec_op;
				end
				S_TREAD: begin tmpz <= din; st <= S_TWRITE; end
				S_TWRITE: begin
					addr <= zpa(X); dout <= res; we <= 1'b1; st <= S_PAD;
					fZ <= rZ; fN <= rN; if (flags_c) fC <= rC; if (flags_v) fV <= rV;
				end
				S_MOD: begin
					addr <= rmw_addr; dout <= res; we <= 1'b1; penalty <= slowio(rmw_addr); st <= S_PAD;
					if (iop == O_TSB || iop == O_TRB) fZ <= ((D & A) == 8'd0);
					else if (iop != O_RMB && iop != O_SMB) begin fZ <= rZ; fN <= rN; if (flags_c) fC <= rC; end
				end
				// BBR/BBS: the zero page byte arrives, the branch decides
				S_BBR: begin
					if (din[IR[6:4]] == (iop == O_BBS)) begin left <= left + 6'd1; extend = 1'b1; PC <= pc_rel2; end
					st <= S_PAD;
				end

				// --- the operation itself (implied ones; the read ones when the byte is in) ----------------
				S_EXEC: exec_op;
				// pushes: JSR/BSR the return address (the last byte of the instruction), PHx a register
				S_PUSH: begin addr <= stk(S); we <= 1'b1; S <= S - 8'd1; dout <= (PC - 16'd1) >> 8; st <= S_JSR1; end
				S_JSR1: begin addr <= stk(S); we <= 1'b1; S <= S - 8'd1; dout <= PC - 16'd1; st <= S_JSR2; end
				S_JSR2: begin PC <= EA; npc = EA; st <= S_PAD; end
				S_PULL: begin
					case (iop)
					O_PLA: begin A <= din; fZ <= (din == 8'd0); fN <= din[7]; end
					O_PLX: begin X <= din; fZ <= (din == 8'd0); fN <= din[7]; end
					O_PLY: begin Y <= din; fZ <= (din == 8'd0); fN <= din[7]; end
					default: {fN, fV, fT, fD, fI, fZ, fC} <= {din[7], din[6], din[5], din[3], din[2], din[1], din[0]};
					endcase
					st <= S_PAD;
				end
				S_RTS1: begin PC[7:0] <= din; addr <= stk(S + 8'd1); rd <= 1'b1; S <= S + 8'd1; st <= S_RTS2; end
				S_RTS2: begin PC <= {din, PC[7:0]} + 16'd1; npc = {din, PC[7:0]} + 16'd1; st <= S_PAD; end
				S_RTI1: begin
					{fN, fV, fT, fD, fI, fZ, fC} <= {din[7], din[6], din[5], din[3], din[2], din[1], din[0]};
					addr <= stk(S + 8'd1); rd <= 1'b1; S <= S + 8'd1; st <= S_RTI2;
				end
				S_RTI2: begin PC[7:0] <= din; addr <= stk(S + 8'd1); rd <= 1'b1; S <= S + 8'd1; st <= S_RTI3; end
				S_RTI3: begin PC <= {din, PC[7:0]}; npc = {din, PC[7:0]}; st <= S_PAD; end

				// --- block transfers: a byte read, a byte written, four cycles of rest ---------------------
				S_BLKR: begin penalty <= slowio(addr); addr <= phys(bdst); dout <= din; we <= 1'b1; st <= S_BLKW; iopr <= 3'd0; end
				S_BLKW: begin
					penalty <= slowio(addr);
					bsrc <= blk_src_next; bdst <= blk_dst_next; balt <= ~balt; blen <= blen - 17'd1;
					st <= S_BLKP;
				end
				S_BLKP: begin
					iopr <= iopr + 3'd1;
					if (iopr == 3'd3) begin
						if (blen == 17'd0) begin left <= 6'd10; st <= S_PAD; end     // the 10 cycles at the end
						else begin addr <= phys(bsrc); rd <= 1'b1; st <= S_BLKR; end
					end
				end

				// --- the rest of the instruction's cycles ---------------------------------------------------
				S_PAD: ;
				// --- an interrupt: the return address and P, the vector ---------------------------------------
				S_IRQ0: st <= S_IRQ1;
				S_IRQ1: begin addr <= stk(S); we <= 1'b1; dout <= PC[15:8]; S <= S - 8'd1; st <= S_IRQ2; end
				S_IRQ2: begin addr <= stk(S); we <= 1'b1; dout <= PC[7:0]; S <= S - 8'd1; st <= S_IRQ3; end
				S_IRQ3: begin
					addr <= stk(S); we <= 1'b1; dout <= (irq_sel == 3'd5) ? (P | 8'h10) : P; S <= S - 8'd1;
					fI <= 1'b1; fD <= 1'b0; fT <= 1'b0;
					st <= S_VECL;
				end
				S_VECL: begin
					addr <= phys(irq_sel == 3'd1 ? 16'hFFFC : irq_sel == 3'd2 ? 16'hFFFA : irq_sel == 3'd3 ? 16'hFFF8 : 16'hFFF6);
					rd <= 1'b1; st <= S_VECH;
				end
				S_VECH: begin PC[7:0] <= din; addr <= addr + 21'd1; rd <= 1'b1; st <= S_RST2; end
				default: st <= S_FETCH;
				endcase

				// --- the instruction's last cycle: the next opcode, or an interrupt's entry -----------------
				if (last && !extend && st != S_RST2 && st != S_IRQ0 && st != S_IRQ1 && st != S_IRQ2 && st != S_IRQ3 && st != S_VECL && st != S_VECH && st != S_RST0 && st != S_RST1 &&
				    st != S_BLKR && st != S_BLKW && st != S_BLKP)
					fin = 1'b1;
				if (fin) begin
					if (irq_any && irq_sel == 3'd0) begin
						irq_sel <= nmi_pend ? 3'd1 : irq_timer ? 3'd2 : irq1 ? 3'd3 : 3'd4;
						nmi_pend <= 1'b0;
						PC <= npc; left <= 6'd7; st <= S_IRQ0;
					end else begin
						PC <= npc; addr <= phys(npc); rd <= 1'b1; st <= S_FETCH;
					end
				end
				end
			end
		end
	end

endmodule

`default_nettype wire
