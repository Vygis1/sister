//////////////////////////////////////////////////////////////////////////////////
// cpu6502.v - a cycle-accurate NMOS 6502.
//
// Cycle-accurate rather than merely instruction-accurate, because the NES needs
// it: games time raster effects by counting CPU cycles, so an instruction that
// produces the right answer in the wrong number of cycles breaks them.
//
// Every bus cycle a real 6502 performs is performed here, including the ones
// that exist only as artifacts: the dummy read while an indexed address is being
// fixed up, the dummy stack read during RTS, and the read-write-write of a
// read-modify-write instruction that makes hardware side effects happen twice.
//
// NMOS quirks are implemented deliberately, not tolerated:
//
//   JMP ($xxFF)  takes the high byte from $xx00 -- the vector wraps inside its
//                own page rather than crossing into the next one.
//   zero page    indexing wraps inside page zero: $FF + X stays below $0100.
//   B flag       exists only in the byte pushed to the stack, never in P.
//   decimal      ADC/SBC with NMOS flag behaviour: N and V come from the high
//                nibble BEFORE the decimal adjust, Z from the binary result.
//                The NES's 2A03 drops decimal mode, but Klaus Dormann's test
//                exercises it and that test is the reason to have it.
//
// Bus timing: addr, dout and we are registered, so what is assigned during one
// cycle appears on the bus the next. "Write V to Y at cycle N" is therefore set
// up at cycle N-1. One cycle per `ce`, so the caller sets the clock rate; a real
// NES runs one CPU cycle per twelve master clocks.
//
// Every state below is a named constant. The first attempt at this used bare
// numbers and two of them collided, which is invisible in review and fatal in
// simulation.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module cpu6502 #(
	// The NES's 2A03 is a 6502 with the decimal adder removed: the D flag still
	// sets and clears and is still pushed and pulled, but ADC and SBC are always
	// binary. Default to that, since this core exists for a NES; set DECIMAL=1
	// for a real 6502, which is what Klaus Dormann's test expects.
	parameter DECIMAL = 0,
	// The 2600's 6507 is halted by the TIA (WSYNC pulls RDY low) and the NES's
	// 2A03 never is. RDY is behind a parameter rather than always live so that
	// the NES, which leaves the pin unconnected, is unchanged: with HAS_RDY=0
	// the input is ignored and the sequencer is exactly what it was.
	parameter HAS_RDY = 0
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,
	// Ready. Low holds the processor in its current READ cycle -- the address
	// stays on the bus and nothing advances until it rises. Write cycles are
	// never held: the NMOS 6502 ignores RDY while writing, and the TIA relies
	// on that (the STA WSYNC that drops RDY must itself complete).
	input  wire        rdy,

	output reg  [15:0] addr,
	input  wire [7:0]  din,
	output reg  [7:0]  dout,
	output reg         we,

	input  wire        irq,
	input  wire        nmi,

	output wire        sync,
	output wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p,
	output wire [15:0] dbg_pc
);

	// --- addressing modes ---------------------------------------------------
	localparam [3:0]
		M_IMP = 4'd0,  M_ACC = 4'd1,  M_IMM = 4'd2,  M_ZP  = 4'd3,
		M_ZPX = 4'd4,  M_ZPY = 4'd5,  M_ABS = 4'd6,  M_ABX = 4'd7,
		M_ABY = 4'd8,  M_IND = 4'd9,  M_IZX = 4'd10, M_IZY = 4'd11,
		M_REL = 4'd12, M_NON = 4'd13;

	localparam [1:0] A_NONE = 2'd0, A_READ = 2'd1, A_WRITE = 2'd2, A_RMW = 2'd3;

	localparam [5:0]
		O_NOP=0,  O_LDA=1,  O_LDX=2,  O_LDY=3,  O_STA=4,  O_STX=5,  O_STY=6,
		O_ADC=7,  O_SBC=8,  O_AND=9,  O_ORA=10, O_EOR=11, O_CMP=12, O_CPX=13,
		O_CPY=14, O_BIT=15, O_ASL=16, O_LSR=17, O_ROL=18, O_ROR=19, O_INC=20,
		O_DEC=21, O_INX=22, O_INY=23, O_DEX=24, O_DEY=25, O_TAX=26, O_TAY=27,
		O_TXA=28, O_TYA=29, O_TSX=30, O_TXS=31, O_CLC=32, O_SEC=33, O_CLI=34,
		O_SEI=35, O_CLV=36, O_CLD=37, O_SED=38, O_JMP=39, O_JSR=40, O_RTS=41,
		O_RTI=42, O_BRK=43, O_PHA=44, O_PHP=45, O_PLA=46, O_PLP=47, O_BRANCH=48,
		O_LAX=49, O_SAX=50;

	// --- states --------------------------------------------------------------
	localparam [5:0]
		S_RST_LO   = 6'd0,  S_RST_HI   = 6'd1,  S_FETCH    = 6'd2,
		S_DECODE   = 6'd3,  S_ZP_DATA  = 6'd4,  S_ZPI_ADD  = 6'd5,
		S_ABS_HI   = 6'd6,  S_ABI_DATA = 6'd7,  S_ABI_FIX  = 6'd8,
		S_IZX_IDX  = 6'd9,  S_IZX_LO   = 6'd10, S_IZX_HI   = 6'd11,
		S_IZY_LO   = 6'd12, S_IZY_HI   = 6'd13, S_WR_DONE  = 6'd14,
		S_RMW_MOD  = 6'd15, S_RMW_WR   = 6'd16, S_BR_ADD   = 6'd17,
		S_BR_FIX   = 6'd18, S_JMPI_LO  = 6'd19, S_JMPI_HI  = 6'd20,
		S_PUSH_DN  = 6'd21, S_PULL_DUM = 6'd22, S_PULL_DAT = 6'd23,
		S_JSR_DUM  = 6'd24, S_JSR_PH   = 6'd25, S_JSR_PL   = 6'd26,
		S_JSR_TGT  = 6'd27, S_RTS_DUM  = 6'd28, S_RTS_PL   = 6'd29,
		S_RTS_PH   = 6'd30, S_RTS_INC  = 6'd31, S_RTI_DUM  = 6'd32,
		S_RTI_P    = 6'd33, S_RTI_PL   = 6'd34, S_RTI_PH   = 6'd35,
		S_BRK_PH   = 6'd36, S_BRK_PL   = 6'd37, S_BRK_P    = 6'd38,
		S_BRK_VL   = 6'd39, S_BRK_VH   = 6'd40;

	// --- registers -----------------------------------------------------------
	reg [7:0]  A, X, Y, S;
	reg [15:0] PC;
	reg        fC, fZ, fI, fD, fV, fN;

	wire [7:0] P = {fN, fV, 1'b1, 1'b0, fD, fI, fZ, fC};

	reg [7:0]  IR;
	reg [5:0]  t;
	reg [15:0] AD;
	reg [7:0]  BAL, BAH, T;
	reg        page_cross, br_up;
	reg [15:0] vecaddr;
	reg        nmi_prev, nmi_pending, brk_is_irq;

	assign sync   = (t == S_FETCH);
	wire rdy_i = (HAS_RDY != 0) ? rdy : 1'b1;
	assign dbg_a  = A;  assign dbg_x = X;  assign dbg_y = Y;
	assign dbg_s  = S;  assign dbg_p = P;  assign dbg_pc = PC;

	// --- decode --------------------------------------------------------------
	wire [7:0] din_opcode = (t == S_FETCH) ? din : IR;

	reg [3:0] mode;
	reg [1:0] acc;
	reg [5:0] op;
	// The undocumented read-modify-write opcodes do an ordinary RMW and then
	// apply a second operation to the result: SLO is ASL then ORA, DCP is DEC
	// then CMP, and so on. op2 is that second operation.
	reg [5:0] op2;

	always @* begin
		mode = M_IMP; acc = A_NONE; op = O_NOP; op2 = O_NOP;
		case (din_opcode)
		8'hA9: begin mode=M_IMM; acc=A_READ;  op=O_LDA; end
		8'hA5: begin mode=M_ZP;  acc=A_READ;  op=O_LDA; end
		8'hB5: begin mode=M_ZPX; acc=A_READ;  op=O_LDA; end
		8'hAD: begin mode=M_ABS; acc=A_READ;  op=O_LDA; end
		8'hBD: begin mode=M_ABX; acc=A_READ;  op=O_LDA; end
		8'hB9: begin mode=M_ABY; acc=A_READ;  op=O_LDA; end
		8'hA1: begin mode=M_IZX; acc=A_READ;  op=O_LDA; end
		8'hB1: begin mode=M_IZY; acc=A_READ;  op=O_LDA; end
		8'hA2: begin mode=M_IMM; acc=A_READ;  op=O_LDX; end
		8'hA6: begin mode=M_ZP;  acc=A_READ;  op=O_LDX; end
		8'hB6: begin mode=M_ZPY; acc=A_READ;  op=O_LDX; end
		8'hAE: begin mode=M_ABS; acc=A_READ;  op=O_LDX; end
		8'hBE: begin mode=M_ABY; acc=A_READ;  op=O_LDX; end
		8'hA0: begin mode=M_IMM; acc=A_READ;  op=O_LDY; end
		8'hA4: begin mode=M_ZP;  acc=A_READ;  op=O_LDY; end
		8'hB4: begin mode=M_ZPX; acc=A_READ;  op=O_LDY; end
		8'hAC: begin mode=M_ABS; acc=A_READ;  op=O_LDY; end
		8'hBC: begin mode=M_ABX; acc=A_READ;  op=O_LDY; end
		8'h85: begin mode=M_ZP;  acc=A_WRITE; op=O_STA; end
		8'h95: begin mode=M_ZPX; acc=A_WRITE; op=O_STA; end
		8'h8D: begin mode=M_ABS; acc=A_WRITE; op=O_STA; end
		8'h9D: begin mode=M_ABX; acc=A_WRITE; op=O_STA; end
		8'h99: begin mode=M_ABY; acc=A_WRITE; op=O_STA; end
		8'h81: begin mode=M_IZX; acc=A_WRITE; op=O_STA; end
		8'h91: begin mode=M_IZY; acc=A_WRITE; op=O_STA; end
		8'h86: begin mode=M_ZP;  acc=A_WRITE; op=O_STX; end
		8'h96: begin mode=M_ZPY; acc=A_WRITE; op=O_STX; end
		8'h8E: begin mode=M_ABS; acc=A_WRITE; op=O_STX; end
		8'h84: begin mode=M_ZP;  acc=A_WRITE; op=O_STY; end
		8'h94: begin mode=M_ZPX; acc=A_WRITE; op=O_STY; end
		8'h8C: begin mode=M_ABS; acc=A_WRITE; op=O_STY; end
		8'h69: begin mode=M_IMM; acc=A_READ;  op=O_ADC; end
		8'h65: begin mode=M_ZP;  acc=A_READ;  op=O_ADC; end
		8'h75: begin mode=M_ZPX; acc=A_READ;  op=O_ADC; end
		8'h6D: begin mode=M_ABS; acc=A_READ;  op=O_ADC; end
		8'h7D: begin mode=M_ABX; acc=A_READ;  op=O_ADC; end
		8'h79: begin mode=M_ABY; acc=A_READ;  op=O_ADC; end
		8'h61: begin mode=M_IZX; acc=A_READ;  op=O_ADC; end
		8'h71: begin mode=M_IZY; acc=A_READ;  op=O_ADC; end
		8'hE9, 8'hEB: begin mode=M_IMM; acc=A_READ; op=O_SBC; end
		8'hE5: begin mode=M_ZP;  acc=A_READ;  op=O_SBC; end
		8'hF5: begin mode=M_ZPX; acc=A_READ;  op=O_SBC; end
		8'hED: begin mode=M_ABS; acc=A_READ;  op=O_SBC; end
		8'hFD: begin mode=M_ABX; acc=A_READ;  op=O_SBC; end
		8'hF9: begin mode=M_ABY; acc=A_READ;  op=O_SBC; end
		8'hE1: begin mode=M_IZX; acc=A_READ;  op=O_SBC; end
		8'hF1: begin mode=M_IZY; acc=A_READ;  op=O_SBC; end
		8'h29: begin mode=M_IMM; acc=A_READ;  op=O_AND; end
		8'h25: begin mode=M_ZP;  acc=A_READ;  op=O_AND; end
		8'h35: begin mode=M_ZPX; acc=A_READ;  op=O_AND; end
		8'h2D: begin mode=M_ABS; acc=A_READ;  op=O_AND; end
		8'h3D: begin mode=M_ABX; acc=A_READ;  op=O_AND; end
		8'h39: begin mode=M_ABY; acc=A_READ;  op=O_AND; end
		8'h21: begin mode=M_IZX; acc=A_READ;  op=O_AND; end
		8'h31: begin mode=M_IZY; acc=A_READ;  op=O_AND; end
		8'h09: begin mode=M_IMM; acc=A_READ;  op=O_ORA; end
		8'h05: begin mode=M_ZP;  acc=A_READ;  op=O_ORA; end
		8'h15: begin mode=M_ZPX; acc=A_READ;  op=O_ORA; end
		8'h0D: begin mode=M_ABS; acc=A_READ;  op=O_ORA; end
		8'h1D: begin mode=M_ABX; acc=A_READ;  op=O_ORA; end
		8'h19: begin mode=M_ABY; acc=A_READ;  op=O_ORA; end
		8'h01: begin mode=M_IZX; acc=A_READ;  op=O_ORA; end
		8'h11: begin mode=M_IZY; acc=A_READ;  op=O_ORA; end
		8'h49: begin mode=M_IMM; acc=A_READ;  op=O_EOR; end
		8'h45: begin mode=M_ZP;  acc=A_READ;  op=O_EOR; end
		8'h55: begin mode=M_ZPX; acc=A_READ;  op=O_EOR; end
		8'h4D: begin mode=M_ABS; acc=A_READ;  op=O_EOR; end
		8'h5D: begin mode=M_ABX; acc=A_READ;  op=O_EOR; end
		8'h59: begin mode=M_ABY; acc=A_READ;  op=O_EOR; end
		8'h41: begin mode=M_IZX; acc=A_READ;  op=O_EOR; end
		8'h51: begin mode=M_IZY; acc=A_READ;  op=O_EOR; end
		8'hC9: begin mode=M_IMM; acc=A_READ;  op=O_CMP; end
		8'hC5: begin mode=M_ZP;  acc=A_READ;  op=O_CMP; end
		8'hD5: begin mode=M_ZPX; acc=A_READ;  op=O_CMP; end
		8'hCD: begin mode=M_ABS; acc=A_READ;  op=O_CMP; end
		8'hDD: begin mode=M_ABX; acc=A_READ;  op=O_CMP; end
		8'hD9: begin mode=M_ABY; acc=A_READ;  op=O_CMP; end
		8'hC1: begin mode=M_IZX; acc=A_READ;  op=O_CMP; end
		8'hD1: begin mode=M_IZY; acc=A_READ;  op=O_CMP; end
		8'hE0: begin mode=M_IMM; acc=A_READ;  op=O_CPX; end
		8'hE4: begin mode=M_ZP;  acc=A_READ;  op=O_CPX; end
		8'hEC: begin mode=M_ABS; acc=A_READ;  op=O_CPX; end
		8'hC0: begin mode=M_IMM; acc=A_READ;  op=O_CPY; end
		8'hC4: begin mode=M_ZP;  acc=A_READ;  op=O_CPY; end
		8'hCC: begin mode=M_ABS; acc=A_READ;  op=O_CPY; end
		8'h24: begin mode=M_ZP;  acc=A_READ;  op=O_BIT; end
		8'h2C: begin mode=M_ABS; acc=A_READ;  op=O_BIT; end
		8'h0A: begin mode=M_ACC; op=O_ASL; end
		8'h06: begin mode=M_ZP;  acc=A_RMW;  op=O_ASL; end
		8'h16: begin mode=M_ZPX; acc=A_RMW;  op=O_ASL; end
		8'h0E: begin mode=M_ABS; acc=A_RMW;  op=O_ASL; end
		8'h1E: begin mode=M_ABX; acc=A_RMW;  op=O_ASL; end
		8'h4A: begin mode=M_ACC; op=O_LSR; end
		8'h46: begin mode=M_ZP;  acc=A_RMW;  op=O_LSR; end
		8'h56: begin mode=M_ZPX; acc=A_RMW;  op=O_LSR; end
		8'h4E: begin mode=M_ABS; acc=A_RMW;  op=O_LSR; end
		8'h5E: begin mode=M_ABX; acc=A_RMW;  op=O_LSR; end
		8'h2A: begin mode=M_ACC; op=O_ROL; end
		8'h26: begin mode=M_ZP;  acc=A_RMW;  op=O_ROL; end
		8'h36: begin mode=M_ZPX; acc=A_RMW;  op=O_ROL; end
		8'h2E: begin mode=M_ABS; acc=A_RMW;  op=O_ROL; end
		8'h3E: begin mode=M_ABX; acc=A_RMW;  op=O_ROL; end
		8'h6A: begin mode=M_ACC; op=O_ROR; end
		8'h66: begin mode=M_ZP;  acc=A_RMW;  op=O_ROR; end
		8'h76: begin mode=M_ZPX; acc=A_RMW;  op=O_ROR; end
		8'h6E: begin mode=M_ABS; acc=A_RMW;  op=O_ROR; end
		8'h7E: begin mode=M_ABX; acc=A_RMW;  op=O_ROR; end
		8'hE6: begin mode=M_ZP;  acc=A_RMW;  op=O_INC; end
		8'hF6: begin mode=M_ZPX; acc=A_RMW;  op=O_INC; end
		8'hEE: begin mode=M_ABS; acc=A_RMW;  op=O_INC; end
		8'hFE: begin mode=M_ABX; acc=A_RMW;  op=O_INC; end
		8'hC6: begin mode=M_ZP;  acc=A_RMW;  op=O_DEC; end
		8'hD6: begin mode=M_ZPX; acc=A_RMW;  op=O_DEC; end
		8'hCE: begin mode=M_ABS; acc=A_RMW;  op=O_DEC; end
		8'hDE: begin mode=M_ABX; acc=A_RMW;  op=O_DEC; end
		8'hE8: begin mode=M_IMP; op=O_INX; end
		8'hC8: begin mode=M_IMP; op=O_INY; end
		8'hCA: begin mode=M_IMP; op=O_DEX; end
		8'h88: begin mode=M_IMP; op=O_DEY; end
		8'hAA: begin mode=M_IMP; op=O_TAX; end
		8'hA8: begin mode=M_IMP; op=O_TAY; end
		8'h8A: begin mode=M_IMP; op=O_TXA; end
		8'h98: begin mode=M_IMP; op=O_TYA; end
		8'hBA: begin mode=M_IMP; op=O_TSX; end
		8'h9A: begin mode=M_IMP; op=O_TXS; end
		8'h18: begin mode=M_IMP; op=O_CLC; end
		8'h38: begin mode=M_IMP; op=O_SEC; end
		8'h58: begin mode=M_IMP; op=O_CLI; end
		8'h78: begin mode=M_IMP; op=O_SEI; end
		8'hB8: begin mode=M_IMP; op=O_CLV; end
		8'hD8: begin mode=M_IMP; op=O_CLD; end
		8'hF8: begin mode=M_IMP; op=O_SED; end
		8'hEA: begin mode=M_IMP; op=O_NOP; end
		8'h4C: begin mode=M_ABS; op=O_JMP; end
		8'h6C: begin mode=M_IND; op=O_JMP; end
		8'h20: begin mode=M_NON; op=O_JSR; end
		8'h60: begin mode=M_NON; op=O_RTS; end
		8'h40: begin mode=M_NON; op=O_RTI; end
		8'h00: begin mode=M_NON; op=O_BRK; end
		8'h48: begin mode=M_NON; op=O_PHA; end
		8'h08: begin mode=M_NON; op=O_PHP; end
		8'h68: begin mode=M_NON; op=O_PLA; end
		8'h28: begin mode=M_NON; op=O_PLP; end
		8'h10, 8'h30, 8'h50, 8'h70,
		8'h90, 8'hB0, 8'hD0, 8'hF0: begin mode=M_REL; op=O_BRANCH; end
		// --- undocumented, used by real games ------------------------------
		// NOPs that still perform their read: the cycle count and the dummy
		// read are observable, so the addressing mode matters.
		8'h1A, 8'h3A, 8'h5A, 8'h7A, 8'hDA, 8'hFA: begin mode=M_IMP; op=O_NOP; end
		8'h80, 8'h82, 8'h89, 8'hC2, 8'hE2: begin mode=M_IMM; acc=A_READ; op=O_NOP; end
		8'h04, 8'h44, 8'h64: begin mode=M_ZP;  acc=A_READ; op=O_NOP; end
		8'h14, 8'h34, 8'h54, 8'h74, 8'hD4, 8'hF4: begin mode=M_ZPX; acc=A_READ; op=O_NOP; end
		8'h0C: begin mode=M_ABS; acc=A_READ; op=O_NOP; end
		8'h1C, 8'h3C, 8'h5C, 8'h7C, 8'hDC, 8'hFC: begin mode=M_ABX; acc=A_READ; op=O_NOP; end
		// LAX: load A and X together.
		8'hA3: begin mode=M_IZX; acc=A_READ; op=O_LAX; end
		8'hA7: begin mode=M_ZP;  acc=A_READ; op=O_LAX; end
		8'hAF: begin mode=M_ABS; acc=A_READ; op=O_LAX; end
		8'hB3: begin mode=M_IZY; acc=A_READ; op=O_LAX; end
		8'hB7: begin mode=M_ZPY; acc=A_READ; op=O_LAX; end
		8'hBF: begin mode=M_ABY; acc=A_READ; op=O_LAX; end
		// SAX: store A AND X, affecting no flags.
		8'h83: begin mode=M_IZX; acc=A_WRITE; op=O_SAX; end
		8'h87: begin mode=M_ZP;  acc=A_WRITE; op=O_SAX; end
		8'h8F: begin mode=M_ABS; acc=A_WRITE; op=O_SAX; end
		8'h97: begin mode=M_ZPY; acc=A_WRITE; op=O_SAX; end
		// SLO = ASL then ORA
		8'h03: begin mode=M_IZX; acc=A_RMW; op=O_ASL; op2=O_ORA; end
		8'h07: begin mode=M_ZP;  acc=A_RMW; op=O_ASL; op2=O_ORA; end
		8'h0F: begin mode=M_ABS; acc=A_RMW; op=O_ASL; op2=O_ORA; end
		8'h13: begin mode=M_IZY; acc=A_RMW; op=O_ASL; op2=O_ORA; end
		8'h17: begin mode=M_ZPX; acc=A_RMW; op=O_ASL; op2=O_ORA; end
		8'h1B: begin mode=M_ABY; acc=A_RMW; op=O_ASL; op2=O_ORA; end
		8'h1F: begin mode=M_ABX; acc=A_RMW; op=O_ASL; op2=O_ORA; end
		// RLA = ROL then AND
		8'h23: begin mode=M_IZX; acc=A_RMW; op=O_ROL; op2=O_AND; end
		8'h27: begin mode=M_ZP;  acc=A_RMW; op=O_ROL; op2=O_AND; end
		8'h2F: begin mode=M_ABS; acc=A_RMW; op=O_ROL; op2=O_AND; end
		8'h33: begin mode=M_IZY; acc=A_RMW; op=O_ROL; op2=O_AND; end
		8'h37: begin mode=M_ZPX; acc=A_RMW; op=O_ROL; op2=O_AND; end
		8'h3B: begin mode=M_ABY; acc=A_RMW; op=O_ROL; op2=O_AND; end
		8'h3F: begin mode=M_ABX; acc=A_RMW; op=O_ROL; op2=O_AND; end
		// SRE = LSR then EOR
		8'h43: begin mode=M_IZX; acc=A_RMW; op=O_LSR; op2=O_EOR; end
		8'h47: begin mode=M_ZP;  acc=A_RMW; op=O_LSR; op2=O_EOR; end
		8'h4F: begin mode=M_ABS; acc=A_RMW; op=O_LSR; op2=O_EOR; end
		8'h53: begin mode=M_IZY; acc=A_RMW; op=O_LSR; op2=O_EOR; end
		8'h57: begin mode=M_ZPX; acc=A_RMW; op=O_LSR; op2=O_EOR; end
		8'h5B: begin mode=M_ABY; acc=A_RMW; op=O_LSR; op2=O_EOR; end
		8'h5F: begin mode=M_ABX; acc=A_RMW; op=O_LSR; op2=O_EOR; end
		// RRA = ROR then ADC
		8'h63: begin mode=M_IZX; acc=A_RMW; op=O_ROR; op2=O_ADC; end
		8'h67: begin mode=M_ZP;  acc=A_RMW; op=O_ROR; op2=O_ADC; end
		8'h6F: begin mode=M_ABS; acc=A_RMW; op=O_ROR; op2=O_ADC; end
		8'h73: begin mode=M_IZY; acc=A_RMW; op=O_ROR; op2=O_ADC; end
		8'h77: begin mode=M_ZPX; acc=A_RMW; op=O_ROR; op2=O_ADC; end
		8'h7B: begin mode=M_ABY; acc=A_RMW; op=O_ROR; op2=O_ADC; end
		8'h7F: begin mode=M_ABX; acc=A_RMW; op=O_ROR; op2=O_ADC; end
		// DCP = DEC then CMP
		8'hC3: begin mode=M_IZX; acc=A_RMW; op=O_DEC; op2=O_CMP; end
		8'hC7: begin mode=M_ZP;  acc=A_RMW; op=O_DEC; op2=O_CMP; end
		8'hCF: begin mode=M_ABS; acc=A_RMW; op=O_DEC; op2=O_CMP; end
		8'hD3: begin mode=M_IZY; acc=A_RMW; op=O_DEC; op2=O_CMP; end
		8'hD7: begin mode=M_ZPX; acc=A_RMW; op=O_DEC; op2=O_CMP; end
		8'hDB: begin mode=M_ABY; acc=A_RMW; op=O_DEC; op2=O_CMP; end
		8'hDF: begin mode=M_ABX; acc=A_RMW; op=O_DEC; op2=O_CMP; end
		// ISC = INC then SBC
		8'hE3: begin mode=M_IZX; acc=A_RMW; op=O_INC; op2=O_SBC; end
		8'hE7: begin mode=M_ZP;  acc=A_RMW; op=O_INC; op2=O_SBC; end
		8'hEF: begin mode=M_ABS; acc=A_RMW; op=O_INC; op2=O_SBC; end
		8'hF3: begin mode=M_IZY; acc=A_RMW; op=O_INC; op2=O_SBC; end
		8'hF7: begin mode=M_ZPX; acc=A_RMW; op=O_INC; op2=O_SBC; end
		8'hFB: begin mode=M_ABY; acc=A_RMW; op=O_INC; op2=O_SBC; end
		8'hFF: begin mode=M_ABX; acc=A_RMW; op=O_INC; op2=O_SBC; end
		default: begin mode=M_IMP; op=O_NOP; end
		endcase
	end

	// --- ALU -----------------------------------------------------------------
	// Read operations act on the byte arriving THIS cycle, so they use din
	// directly. Read-modify-write latches into T first, because its arithmetic
	// happens a cycle after the read.
	reg [7:0] rmw_result;
	always @* begin
		case (op)
			O_ASL:   rmw_result = {T[6:0], 1'b0};
			O_LSR:   rmw_result = {1'b0, T[7:1]};
			O_ROL:   rmw_result = {T[6:0], fC};
			O_ROR:   rmw_result = {fC, T[7:1]};
			O_INC:   rmw_result = T + 8'd1;
			O_DEC:   rmw_result = T - 8'd1;
			default: rmw_result = T;
		endcase
	end

	// The carry the shift produces. RRA is ROR followed by ADC, and the ADC must
	// see the carry the ROR just made -- reading fC gives the value from before
	// the shift, because the non-blocking assignment has not landed yet.
	reg rmw_c;
	always @* begin
		case (op)
			O_ASL, O_ROL: rmw_c = T[7];
			O_LSR, O_ROR: rmw_c = T[0];
			default:      rmw_c = fC;     // INC/DEC leave carry alone
		endcase
	end

	wire alu_c = (t == S_RMW_WR) ? rmw_c : fC;

	wire [7:0] M = (t == S_RMW_WR) ? rmw_result : din;

	wire [8:0] adc_bin = {1'b0, A} + {1'b0, M} + {8'd0, alu_c};
	wire       adc_v   = (~(A[7] ^ M[7])) & (A[7] ^ adc_bin[7]);
	wire [8:0] sbc_bin = {1'b0, A} + {1'b0, ~M} + {8'd0, alu_c};
	wire       sbc_v   = (A[7] ^ M[7]) & (A[7] ^ sbc_bin[7]);

	// Decimal ADC, NMOS: N and V come from the high nibble BEFORE its adjust.
	wire [4:0] d_lo   = {1'b0, A[3:0]} + {1'b0, M[3:0]} + {4'd0, alu_c};
	wire       d_lo_c = (d_lo > 5'd9);
	wire [4:0] d_lo_a = d_lo_c ? (d_lo + 5'd6) : d_lo;
	wire [5:0] d_hi   = {2'b00, A[7:4]} + {2'b00, M[7:4]} + {5'd0, d_lo_c};
	wire       d_hi_c = (d_hi > 6'd9);
	wire [5:0] d_hi_a = d_hi_c ? (d_hi + 6'd6) : d_hi;
	wire [7:0] dec_add = {d_hi_a[3:0], d_lo_a[3:0]};
	wire       dec_add_n = d_hi[3];
	wire       dec_add_v = (~(A[7] ^ M[7])) & (A[7] ^ d_hi[3]);

	// Decimal SBC: result adjusts, but every flag comes from the binary form.
	wire [4:0] s_lo   = {1'b0, A[3:0]} - {1'b0, M[3:0]} - {4'd0, ~alu_c};
	wire [5:0] s_hi   = {2'b00, A[7:4]} - {2'b00, M[7:4]} - {5'd0, s_lo[4]};
	wire [3:0] s_lo_a = s_lo[4] ? (s_lo[3:0] - 4'd6) : s_lo[3:0];
	wire [3:0] s_hi_a = s_hi[4] ? (s_hi[3:0] - 4'd6) : s_hi[3:0];
	wire [7:0] dec_sub = {s_hi_a, s_lo_a};

	wire [7:0] r_and = A & M;
	wire [7:0] r_ora = A | M;
	wire [7:0] r_eor = A ^ M;
	wire [7:0] r_bit = A & M;

	wire [7:0] cmp_l = (op == O_CPX) ? X : (op == O_CPY) ? Y : A;
	wire [8:0] cmp_r = {1'b0, cmp_l} - {1'b0, M};

	wire [7:0] inx_r = X + 8'd1, iny_r = Y + 8'd1;
	wire [7:0] dex_r = X - 8'd1, dey_r = Y - 8'd1;
	wire [7:0] asl_a = {A[6:0], 1'b0}, lsr_a = {1'b0, A[7:1]};
	wire [7:0] rol_a = {A[6:0], fC},   ror_a = {fC, A[7:1]};

	// --- addressing helpers ---------------------------------------------------
	wire [7:0]  store_val = (op == O_SAX) ? (A & X) :
	                        (op == O_STA) ? A : (op == O_STX) ? X : Y;
	wire [7:0]  idx       = (mode == M_ZPY || mode == M_ABY) ? Y : X;
	wire [8:0]  bal_idx   = {1'b0, BAL} + {1'b0, idx};
	wire [8:0]  izy_lo    = {1'b0, T} + {1'b0, Y};
	wire [15:0] pc1       = PC + 16'd1;
	wire [15:0] ad_fixed  = page_cross ? {BAH + 8'd1, AD[7:0]} : AD;

	wire [8:0] br_lo   = {1'b0, PC[7:0]} + {1'b0, T};
	wire       br_up_w = !T[7] &&  br_lo[8];
	wire       br_dn_w =  T[7] && !br_lo[8];

	reg branch_taken;
	always @* begin
		case (IR[7:6])
			2'b00: branch_taken = (fN == IR[5]);
			2'b01: branch_taken = (fV == IR[5]);
			2'b10: branch_taken = (fC == IR[5]);
			default: branch_taken = (fZ == IR[5]);
		endcase
	end

	// Executing a read operation. Only ever called on a cycle where din holds
	// the operand.
	task do_alu;
		input [5:0] which;
		begin
			case (which)
			O_LDA: begin A <= M; fN <= M[7]; fZ <= (M == 8'd0); end
			O_LDX: begin X <= M; fN <= M[7]; fZ <= (M == 8'd0); end
			O_LDY: begin Y <= M; fN <= M[7]; fZ <= (M == 8'd0); end
			O_AND: begin A <= r_and; fN <= r_and[7]; fZ <= (r_and == 8'd0); end
			O_ORA: begin A <= r_ora; fN <= r_ora[7]; fZ <= (r_ora == 8'd0); end
			O_EOR: begin A <= r_eor; fN <= r_eor[7]; fZ <= (r_eor == 8'd0); end
			O_ADC: begin
				if (fD && DECIMAL != 0) begin
					A  <= dec_add; fC <= d_hi_c;
					fN <= dec_add_n; fV <= dec_add_v;
					fZ <= (adc_bin[7:0] == 8'd0);
				end else begin
					A  <= adc_bin[7:0]; fC <= adc_bin[8];
					fN <= adc_bin[7];   fV <= adc_v;
					fZ <= (adc_bin[7:0] == 8'd0);
				end
			end
			O_SBC: begin
				if (fD && DECIMAL != 0) A <= dec_sub;
				else    A <= sbc_bin[7:0];
				fC <= sbc_bin[8];
				fN <= sbc_bin[7];
				fV <= sbc_v;
				fZ <= (sbc_bin[7:0] == 8'd0);
			end
			O_CMP, O_CPX, O_CPY: begin
				fC <= ~cmp_r[8];
				fN <= cmp_r[7];
				fZ <= (cmp_r[7:0] == 8'd0);
			end
			O_BIT: begin fN <= M[7]; fV <= M[6]; fZ <= (r_bit == 8'd0); end
			O_LAX: begin A <= M; X <= M; fN <= M[7]; fZ <= (M == 8'd0); end
			default: ;
			endcase
		end
	endtask

	// --- sequencer ------------------------------------------------------------
	always @(posedge clk) begin
		if (rst) begin
			t          <= S_RST_LO;
			addr       <= 16'hFFFC;
			we         <= 1'b0;
			S          <= 8'hFD;
			A <= 8'd0; X <= 8'd0; Y <= 8'd0;
			fC <= 1'b0; fZ <= 1'b0; fV <= 1'b0; fN <= 1'b0;
			fI <= 1'b1; fD <= 1'b0;
			IR <= 8'd0;
			nmi_prev    <= 1'b0;
			nmi_pending <= 1'b0;
			brk_is_irq  <= 1'b0;
			page_cross  <= 1'b0;
		end else if (ce && (rdy_i || we)) begin
			we       <= 1'b0;
			nmi_prev <= nmi;
			if (nmi && !nmi_prev) nmi_pending <= 1'b1;   // edge triggered

			case (t)

			S_RST_LO: begin T <= din; addr <= 16'hFFFD; t <= S_RST_HI; end
			S_RST_HI: begin PC <= {din, T}; addr <= {din, T}; t <= S_FETCH; end

			S_FETCH: begin
				// An interrupt replaces the fetched opcode: the byte is read and
				// discarded, PC does not advance, and BRK runs with B clear.
				if (nmi_pending || (irq && !fI)) begin
					IR <= 8'h00; brk_is_irq <= 1'b1; addr <= PC;
				end else begin
					IR <= din;   brk_is_irq <= 1'b0; PC <= pc1; addr <= pc1;
				end
				t <= S_DECODE;
			end

			S_DECODE: begin
				case (mode)
				M_IMP, M_ACC: begin
					case (op)
					O_INX: begin X <= inx_r; fN <= inx_r[7]; fZ <= (inx_r == 8'd0); end
					O_INY: begin Y <= iny_r; fN <= iny_r[7]; fZ <= (iny_r == 8'd0); end
					O_DEX: begin X <= dex_r; fN <= dex_r[7]; fZ <= (dex_r == 8'd0); end
					O_DEY: begin Y <= dey_r; fN <= dey_r[7]; fZ <= (dey_r == 8'd0); end
					O_TAX: begin X <= A; fN <= A[7]; fZ <= (A == 8'd0); end
					O_TAY: begin Y <= A; fN <= A[7]; fZ <= (A == 8'd0); end
					O_TXA: begin A <= X; fN <= X[7]; fZ <= (X == 8'd0); end
					O_TYA: begin A <= Y; fN <= Y[7]; fZ <= (Y == 8'd0); end
					O_TSX: begin X <= S; fN <= S[7]; fZ <= (S == 8'd0); end
					O_TXS: S  <= X;                       // sets no flags
					O_CLC: fC <= 1'b0;   O_SEC: fC <= 1'b1;
					O_CLI: fI <= 1'b0;   O_SEI: fI <= 1'b1;
					O_CLV: fV <= 1'b0;
					O_CLD: fD <= 1'b0;   O_SED: fD <= 1'b1;
					O_ASL: begin A <= asl_a; fC <= A[7]; fN <= asl_a[7]; fZ <= (asl_a == 8'd0); end
					O_LSR: begin A <= lsr_a; fC <= A[0]; fN <= 1'b0;     fZ <= (lsr_a == 8'd0); end
					O_ROL: begin A <= rol_a; fC <= A[7]; fN <= rol_a[7]; fZ <= (rol_a == 8'd0); end
					O_ROR: begin A <= ror_a; fC <= A[0]; fN <= ror_a[7]; fZ <= (ror_a == 8'd0); end
					default: ;
					endcase
					addr <= PC;
					t    <= S_FETCH;
				end

				M_IMM: begin
					do_alu(op);
					PC   <= pc1;
					addr <= pc1;
					t    <= S_FETCH;
				end

				M_ZP: begin
					AD <= {8'h00, din};
					PC <= pc1;
					addr <= {8'h00, din};
					if (acc == A_WRITE) begin
						dout <= store_val; we <= 1'b1; t <= S_WR_DONE;
					end else t <= S_ZP_DATA;
				end

				M_ZPX, M_ZPY: begin
					BAL  <= din;
					PC   <= pc1;
					addr <= {8'h00, din};          // dummy read, unindexed
					t    <= S_ZPI_ADD;
				end

				M_ABS, M_ABX, M_ABY, M_IND: begin
					BAL  <= din;
					PC   <= pc1;
					addr <= pc1;
					t    <= S_ABS_HI;
				end

				M_IZX: begin
					BAL  <= din;
					PC   <= pc1;
					addr <= {8'h00, din};          // dummy read before indexing
					t    <= S_IZX_IDX;
				end

				M_IZY: begin
					BAL  <= din;
					PC   <= pc1;
					addr <= {8'h00, din};          // pointer low
					t    <= S_IZY_LO;
				end

				M_REL: begin
					T    <= din;
					PC   <= pc1;
					addr <= pc1;
					t    <= branch_taken ? S_BR_ADD : S_FETCH;
				end

				default: begin
					case (op)
					O_JSR: begin BAL <= din; PC <= pc1; addr <= {8'h01, S}; t <= S_JSR_DUM; end
					O_RTS: begin addr <= {8'h01, S}; t <= S_RTS_DUM; end
					O_RTI: begin addr <= {8'h01, S}; t <= S_RTI_DUM; end
					O_PHA: begin addr <= {8'h01, S}; dout <= A;         we <= 1'b1; t <= S_PUSH_DN; end
					O_PHP: begin addr <= {8'h01, S}; dout <= P | 8'h30; we <= 1'b1; t <= S_PUSH_DN; end
					O_PLA, O_PLP: begin addr <= {8'h01, S}; t <= S_PULL_DUM; end
					default: begin                  // BRK and interrupts
						if (!brk_is_irq) PC <= pc1;
						addr <= {8'h01, S};
						dout <= brk_is_irq ? PC[15:8] : pc1[15:8];
						we   <= 1'b1;
						t    <= S_BRK_PH;
					end
					endcase
				end
				endcase
			end

			S_ZP_DATA: begin
				if (acc == A_RMW) begin
					T    <= din;
					addr <= AD;
					dout <= din;                    // the dummy write-back
					we   <= 1'b1;
					t    <= S_RMW_MOD;
				end else begin
					do_alu(op);
					addr <= PC;
					t    <= S_FETCH;
				end
			end

			S_ZPI_ADD: begin
				AD   <= {8'h00, bal_idx[7:0]};      // wraps inside page zero
				addr <= {8'h00, bal_idx[7:0]};
				if (acc == A_WRITE) begin
					dout <= store_val; we <= 1'b1; t <= S_WR_DONE;
				end else t <= S_ZP_DATA;
			end

			S_ABS_HI: begin
				BAH <= din;
				PC  <= pc1;
				if (mode == M_ABS) begin
					if (op == O_JMP) begin
						PC <= {din, BAL}; addr <= {din, BAL}; t <= S_FETCH;
					end else begin
						AD <= {din, BAL}; addr <= {din, BAL};
						if (acc == A_WRITE) begin
							dout <= store_val; we <= 1'b1; t <= S_WR_DONE;
						end else t <= S_ZP_DATA;
					end
				end else if (mode == M_IND) begin
					AD <= {din, BAL}; addr <= {din, BAL}; t <= S_JMPI_LO;
				end else begin
					AD         <= {din, bal_idx[7:0]};
					page_cross <= bal_idx[8];
					addr       <= {din, bal_idx[7:0]};
					t          <= S_ABI_DATA;
				end
			end

			// The access at the possibly-wrong page. For a read that did not
			// cross, this IS the data cycle. Writes and RMW always spend it as a
			// dummy, which is why they never get the "fast" timing.
			S_ABI_DATA: begin
				AD         <= ad_fixed;
				page_cross <= 1'b0;
				if (acc == A_WRITE) begin
					addr <= ad_fixed; dout <= store_val; we <= 1'b1; t <= S_WR_DONE;
				end else if (acc == A_RMW) begin
					addr <= ad_fixed; t <= S_ZP_DATA;
				end else if (page_cross) begin
					addr <= ad_fixed; t <= S_ABI_FIX;
				end else begin
					do_alu(op); addr <= PC; t <= S_FETCH;
				end
			end

			S_ABI_FIX: begin do_alu(op); addr <= PC; t <= S_FETCH; end

			S_IZX_IDX: begin
				BAL  <= bal_idx[7:0];
				addr <= {8'h00, bal_idx[7:0]};
				t    <= S_IZX_LO;
			end
			S_IZX_LO: begin
				T    <= din;
				addr <= {8'h00, BAL + 8'd1};        // wraps inside page zero
				t    <= S_IZX_HI;
			end
			S_IZX_HI: begin
				AD   <= {din, T};
				addr <= {din, T};
				if (acc == A_WRITE) begin
					dout <= store_val; we <= 1'b1; t <= S_WR_DONE;
				end else t <= S_ZP_DATA;
			end

			S_IZY_LO: begin
				T    <= din;
				addr <= {8'h00, BAL + 8'd1};
				t    <= S_IZY_HI;
			end
			S_IZY_HI: begin
				BAH        <= din;
				AD         <= {din, izy_lo[7:0]};
				page_cross <= izy_lo[8];
				addr       <= {din, izy_lo[7:0]};
				t          <= S_ABI_DATA;
			end

			S_WR_DONE: begin addr <= PC; t <= S_FETCH; end

			S_RMW_MOD: begin
				addr <= AD;
				dout <= rmw_result;
				we   <= 1'b1;
				t    <= S_RMW_WR;
			end
			S_RMW_WR: begin
				case (op)
				O_ASL: begin fC <= T[7]; fN <= rmw_result[7]; fZ <= (rmw_result == 8'd0); end
				O_LSR: begin fC <= T[0]; fN <= 1'b0;          fZ <= (rmw_result == 8'd0); end
				O_ROL: begin fC <= T[7]; fN <= rmw_result[7]; fZ <= (rmw_result == 8'd0); end
				O_ROR: begin fC <= T[0]; fN <= rmw_result[7]; fZ <= (rmw_result == 8'd0); end
				default: begin fN <= rmw_result[7]; fZ <= (rmw_result == 8'd0); end
				endcase
				// Applied after, so the second operation's flags take priority --
				// SLO reports ORA's N and Z but keeps ASL's carry.
				if (op2 != O_NOP) do_alu(op2);
				addr <= PC;
				t    <= S_FETCH;
			end

			S_BR_ADD: begin
				PC[7:0] <= br_lo[7:0];
				br_up   <= br_up_w;
				addr    <= {PC[15:8], br_lo[7:0]};
				t       <= (br_up_w || br_dn_w) ? S_BR_FIX : S_FETCH;
			end
			S_BR_FIX: begin
				PC[15:8] <= br_up ? (PC[15:8] + 8'd1) : (PC[15:8] - 8'd1);
				addr     <= {br_up ? (PC[15:8] + 8'd1) : (PC[15:8] - 8'd1), PC[7:0]};
				t        <= S_FETCH;
			end

			S_JMPI_LO: begin
				T    <= din;
				addr <= {AD[15:8], AD[7:0] + 8'd1};   // stays inside the page
				t    <= S_JMPI_HI;
			end
			S_JMPI_HI: begin PC <= {din, T}; addr <= {din, T}; t <= S_FETCH; end

			S_PUSH_DN: begin S <= S - 8'd1; addr <= PC; t <= S_FETCH; end

			S_PULL_DUM: begin addr <= {8'h01, S + 8'd1}; t <= S_PULL_DAT; end
			S_PULL_DAT: begin
				S <= S + 8'd1;
				if (op == O_PLA) begin
					A <= din; fN <= din[7]; fZ <= (din == 8'd0);
				end else begin
					fN <= din[7]; fV <= din[6]; fD <= din[3];
					fI <= din[2]; fZ <= din[1]; fC <= din[0];
				end
				addr <= PC;
				t    <= S_FETCH;
			end

			S_JSR_DUM: begin
				addr <= {8'h01, S};
				dout <= PC[15:8];
				we   <= 1'b1;
				t    <= S_JSR_PH;
			end
			S_JSR_PH: begin
				addr <= {8'h01, S - 8'd1};
				dout <= PC[7:0];
				we   <= 1'b1;
				t    <= S_JSR_PL;
			end
			S_JSR_PL: begin S <= S - 8'd2; addr <= PC; t <= S_JSR_TGT; end
			S_JSR_TGT: begin PC <= {din, BAL}; addr <= {din, BAL}; t <= S_FETCH; end

			S_RTS_DUM: begin addr <= {8'h01, S + 8'd1}; t <= S_RTS_PL; end
			S_RTS_PL:  begin T <= din; addr <= {8'h01, S + 8'd2}; t <= S_RTS_PH; end
			S_RTS_PH:  begin PC <= {din, T}; S <= S + 8'd2; addr <= {din, T}; t <= S_RTS_INC; end
			S_RTS_INC: begin PC <= pc1; addr <= pc1; t <= S_FETCH; end

			S_RTI_DUM: begin addr <= {8'h01, S + 8'd1}; t <= S_RTI_P; end
			S_RTI_P: begin
				fN <= din[7]; fV <= din[6]; fD <= din[3];
				fI <= din[2]; fZ <= din[1]; fC <= din[0];
				addr <= {8'h01, S + 8'd2};
				t    <= S_RTI_PL;
			end
			S_RTI_PL: begin T <= din; addr <= {8'h01, S + 8'd3}; t <= S_RTI_PH; end
			S_RTI_PH: begin PC <= {din, T}; S <= S + 8'd3; addr <= {din, T}; t <= S_FETCH; end

			S_BRK_PH: begin
				addr <= {8'h01, S - 8'd1};
				dout <= PC[7:0];
				we   <= 1'b1;
				t    <= S_BRK_PL;
			end
			S_BRK_PL: begin
				addr <= {8'h01, S - 8'd2};
				// B is set only in the byte a BRK pushes, never by an interrupt
				// and never in P itself.
				dout <= brk_is_irq ? (P | 8'h20) : (P | 8'h30);
				we   <= 1'b1;
				t    <= S_BRK_P;
			end
			S_BRK_P: begin
				S  <= S - 8'd3;
				fI <= 1'b1;
				if (nmi_pending) begin
					vecaddr <= 16'hFFFA; addr <= 16'hFFFA; nmi_pending <= 1'b0;
				end else begin
					vecaddr <= 16'hFFFE; addr <= 16'hFFFE;
				end
				t <= S_BRK_VL;
			end
			S_BRK_VL: begin T <= din; addr <= vecaddr + 16'd1; t <= S_BRK_VH; end
			S_BRK_VH: begin PC <= {din, T}; addr <= {din, T}; t <= S_FETCH; end

			default: begin addr <= PC; t <= S_FETCH; end
			endcase
		end
	end

endmodule

`default_nettype wire
