//////////////////////////////////////////////////////////////////////////////////
// arm7tdmi - the Game Boy Advance's processor: ARMv4T, ARM and Thumb.
//
// One instruction at a time, its bus cycles one after the other (the real part's three-stage
// pipeline is modelled, not built: R15 reads as the instruction's address + 8 in ARM state, + 4
// in Thumb, the two words behind it are held in `ir` and `ir1`, and every instruction's first
// cycle fetches the word after them). The timing the Game Boy Advance's games were tuned to
// comes from the cycle counts: an S or N cycle is a bus request the memory answers in as many
// console cycles as its wait states take, an I cycle is one `tick` of waiting here. So the core
// runs at the console's pace when the ticks come at 16.78 MHz (one in 2.98 clocks at 50 MHz).
//
// Registers: the user bank R0-R15 and the banked sets (fiq R8-R14, svc/abt/irq/und R13-R14)
// in one array, the mode picking the index; CPSR and the five SPSRs. The bench loads and reads
// them all through ld_*/st_* (the SingleStepTests ARM7TDMI suite: tools/gba/armtests.py +
// sim/tb_arm7.v).
//
// The bus: addr/size/we/dout/req, din/ack. A request stays up until ack (the next clock at the
// earliest). `code` marks instruction fetches, `seq` the sequential ones (the memory's S cycle
// pricing). Loads give the memory the unaligned address (the console's bus ignores the low
// bits); the rotation of an unaligned word or halfword load is done here.
//
// Not built: coprocessor instructions (undefined trap, as on the console), aborts, FIQ.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module arm7tdmi (
	input  wire        clk,
	input  wire        rst,
	input  wire        tick,                 // one console cycle has passed (an I cycle ends on one)
	input  wire        prime,                // leaving reset: the pipeline is already loaded (the bench)
	// the bus
	output reg  [31:0] addr,
	output reg  [1:0]  size,                 // 0 byte, 1 halfword, 2 word
	output reg         we,
	output reg  [31:0] dout,
	input  wire [31:0] din,
	output reg         req,
	input  wire        ack,
	output reg         code,
	output reg         seq,
	// interrupts
	input  wire        irq,
	// the bench's state port: 0-15 user R0-R15, 16-22 fiq R8-R14, 23-24 svc, 25-26 abt,
	// 27-28 irq, 29-30 und, 31 CPSR, 32-36 SPSR fiq svc abt irq und, 37 pipeline decode word,
	// 38 fetch word
	input  wire        ld_we,
	input  wire [5:0]  ld_idx,
	input  wire [31:0] ld_data,
	input  wire [5:0]  st_idx,
	output reg  [31:0] st_data,
	output wire        retire,               // one instruction done
	output wire [31:0] dbg_pc
);
	// ---- modes and the register file -----------------------------------------------------------
	localparam [4:0] M_USR = 5'h10, M_FIQ = 5'h11, M_IRQ = 5'h12, M_SVC = 5'h13, M_ABT = 5'h17, M_UND = 5'h1B, M_SYS = 5'h1F;
	reg [31:0] R [0:30];
	reg [31:0] cpsr;
	reg [31:0] spsr [0:4];                   // fiq svc abt irq und
	reg [31:0] pc;                           // R15 as the program sees it
	reg [31:0] ir, ir1;                      // the instruction executing, the one after it

	function [4:0] rix;                      // the array index of register n in mode m
		input [3:0] n; input [4:0] m;
		begin
			if (n < 4'd8 || n == 4'd15) rix = {1'b0, n};
			else if (n < 4'd13) rix = (m == M_FIQ) ? 5'd16 + {1'b0, n} - 5'd8 : {1'b0, n};
			else case (m)
				M_FIQ: rix = 5'd21 + {4'd0, ~n[0]};      // (13 -> the first of the pair, 14 the second)
				M_SVC: rix = 5'd23 + {4'd0, ~n[0]};
				M_ABT: rix = 5'd25 + {4'd0, ~n[0]};
				M_IRQ: rix = 5'd27 + {4'd0, ~n[0]};
				M_UND: rix = 5'd29 + {4'd0, ~n[0]};
				default: rix = {1'b0, n};
			endcase
		end
	endfunction
	function [2:0] six;                      // the SPSR of mode m (5: none)
		input [4:0] m;
		case (m)
			M_FIQ: six = 3'd0; M_SVC: six = 3'd1; M_ABT: six = 3'd2; M_IRQ: six = 3'd3; M_UND: six = 3'd4;
			default: six = 3'd5;
		endcase
	endfunction

	wire [4:0] mode  = cpsr[4:0];
	wire       tbit  = cpsr[5];
	wire       fN = cpsr[31], fZ = cpsr[30], fC = cpsr[29], fV = cpsr[28];
	wire       privileged = (mode != M_USR);
	wire [2:0] cur_spsr = six(mode);

	// ---- Thumb: the instruction as the ARM equivalent --------------------------------------------
	// Nearly every Thumb instruction is an ARM one in a shorter coat; the expansion gives the
	// executor one decoder. The ones that are not (the branches, with halfword offsets) come out
	// as `tk` with their target computed here.
	// ---- Thumb: the instruction as the ARM equivalent --------------------------------------------
	// Nearly every Thumb instruction is an ARM one in a shorter coat; the expansion gives the
	// executor one decoder. It is done as the word enters the pipeline's decode slot, so the
	// ARM-form opcode (aop) is a register and the expansion is off the execute path. The ones
	// that are not ARM instructions (the branches, with halfword offsets) come out as `tk`, with
	// their target computed from the executing word.
	function [31:0] thumb_aop;
		input [15:0] u;
		reg [31:0] aop;
		begin
			aop = 32'hE7F000F0;
			casez (u[15:11])
			5'b000_00, 5'b000_01, 5'b000_10:              // LSL/LSR/ASR Rd, Rs, #imm -> MOVS Rd, Rs, shift #imm
				aop = 32'hE1B00000 | {u[2:0], 12'd0} | {u[10:6], 7'd0} | {u[12:11], 5'd0} | {29'd0, u[5:3]};
			5'b000_11:                                    // ADD/SUB Rd, Rs, Rn / #imm3
				aop = (u[10] ? (u[9] ? 32'hE2500000 : 32'hE2900000) : (u[9] ? 32'hE0500000 : 32'hE0900000))
				      | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[8:6]};
			5'b001_00: aop = 32'hE3B00000 | {u[10:8], 12'd0} | {24'd0, u[7:0]};                     // MOVS Rd, #imm
			5'b001_01: aop = 32'hE3500000 | {u[10:8], 16'd0} | {24'd0, u[7:0]};                     // CMP Rd, #imm
			5'b001_10: aop = 32'hE2900000 | {u[10:8], 16'd0} | {u[10:8], 12'd0} | {24'd0, u[7:0]};  // ADDS
			5'b001_11: aop = 32'hE2500000 | {u[10:8], 16'd0} | {u[10:8], 12'd0} | {24'd0, u[7:0]};  // SUBS
			5'b010_00: begin
				if (u[10] == 1'b0) begin                  // the ALU operations Rd, Rs
					case (u[9:6])
					4'h0: aop = 32'hE0100000 | {u[2:0], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[5:3]};   // ANDS
					4'h1: aop = 32'hE0300000 | {u[2:0], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[5:3]};   // EORS
					4'h2: aop = 32'hE1B00010 | {u[2:0], 12'd0} | {u[5:3], 8'd0} | {29'd0, u[2:0]};     // MOVS Rd, Rd, LSL Rs
					4'h3: aop = 32'hE1B00030 | {u[2:0], 12'd0} | {u[5:3], 8'd0} | {29'd0, u[2:0]};     // LSR
					4'h4: aop = 32'hE1B00050 | {u[2:0], 12'd0} | {u[5:3], 8'd0} | {29'd0, u[2:0]};     // ASR
					4'h5: aop = 32'hE0B00000 | {u[2:0], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[5:3]};   // ADCS
					4'h6: aop = 32'hE0D00000 | {u[2:0], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[5:3]};   // SBCS
					4'h7: aop = 32'hE1B00070 | {u[2:0], 12'd0} | {u[5:3], 8'd0} | {29'd0, u[2:0]};     // ROR
					4'h8: aop = 32'hE1100000 | {u[2:0], 16'd0} | {29'd0, u[5:3]};                      // TST
					4'h9: aop = 32'hE2700000 | {u[5:3], 16'd0} | {u[2:0], 12'd0};                      // NEG: RSBS Rd, Rs, #0
					4'hA: aop = 32'hE1500000 | {u[2:0], 16'd0} | {29'd0, u[5:3]};                      // CMP
					4'hB: aop = 32'hE1700000 | {u[2:0], 16'd0} | {29'd0, u[5:3]};                      // CMN
					4'hC: aop = 32'hE1900000 | {u[2:0], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[5:3]};   // ORRS
					4'hD: aop = 32'hE0100090 | {u[2:0], 16'd0} | {u[5:3], 8'd0} | {29'd0, u[2:0]};     // MULS Rd, Rd, Rs
					4'hE: aop = 32'hE1D00000 | {u[2:0], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[5:3]};   // BICS
					default: aop = 32'hE1F00000 | {u[2:0], 12'd0} | {29'd0, u[5:3]};                   // MVNS
					endcase
				end else begin                            // the high-register operations and BX
					case (u[9:8])
					2'd0: aop = 32'hE0800000 | {u[7], u[2:0], 16'd0} | {u[7], u[2:0], 12'd0} | {28'd0, u[6], u[5:3]};   // ADD
					2'd1: aop = 32'hE1500000 | {u[7], u[2:0], 16'd0} | {28'd0, u[6], u[5:3]};                           // CMP
					2'd2: aop = 32'hE1A00000 | {u[7], u[2:0], 12'd0} | {28'd0, u[6], u[5:3]};                           // MOV
					default: aop = 32'hE12FFF10 | {28'd0, u[6], u[5:3]};                                                // BX
					endcase
				end
			end
			5'b010_01: aop = 32'hE59F0000 | {u[10:8], 12'd0} | {22'd0, u[7:0], 2'd0};              // LDR Rd, [PC, #imm*4]
			5'b010_10, 5'b010_11: begin
				if (u[9] == 1'b0)                         // STR/STRB/LDR/LDRB Rd, [Rb, Ro]
					aop = 32'hE7800000 | (u[11] ? 32'h00100000 : 32'd0) | (u[10] ? 32'h00400000 : 32'd0)
					      | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[8:6]};
				else begin                                // STRH / LDRSB / LDRH / LDRSH Rd, [Rb, Ro]
					case (u[11:10])
					2'd0: aop = 32'hE18000B0 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[8:6]};
					2'd1: aop = 32'hE19000D0 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[8:6]};
					2'd2: aop = 32'hE19000B0 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[8:6]};
					default: aop = 32'hE19000F0 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {29'd0, u[8:6]};
					endcase
				end
			end
			5'b011_00: aop = 32'hE5800000 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {20'd0, u[10:6], 2'd0};   // STR  Rd, [Rb, #imm*4]
			5'b011_01: aop = 32'hE5900000 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {20'd0, u[10:6], 2'd0};   // LDR
			5'b011_10: aop = 32'hE5C00000 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {27'd0, u[10:6]};         // STRB Rd, [Rb, #imm]
			5'b011_11: aop = 32'hE5D00000 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {27'd0, u[10:6]};         // LDRB
			5'b100_00: aop = 32'hE1C000B0 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {22'd0, u[10:9], 8'd0} | {28'd0, u[8:6], 1'b0};    // STRH Rd, [Rb, #imm*2]
			5'b100_01: aop = 32'hE1D000B0 | {u[5:3], 16'd0} | {u[2:0], 12'd0} | {22'd0, u[10:9], 8'd0} | {28'd0, u[8:6], 1'b0};    // LDRH
			5'b100_10: aop = 32'hE58D0000 | {u[10:8], 12'd0} | {22'd0, u[7:0], 2'd0};             // STR Rd, [SP, #imm*4]
			5'b100_11: aop = 32'hE59D0000 | {u[10:8], 12'd0} | {22'd0, u[7:0], 2'd0};             // LDR
			5'b101_00: aop = 32'hE28F0F00 | {u[10:8], 12'd0} | {24'd0, u[7:0]};                   // ADD Rd, PC, #imm*4 (imm ROR 30)
			5'b101_01: aop = 32'hE28D0F00 | {u[10:8], 12'd0} | {24'd0, u[7:0]};                   // ADD Rd, SP, #imm*4
			5'b101_10, 5'b101_11: begin
				if (u[10:8] == 3'b000)                    // ADD SP, #+-imm*4
					aop = (u[7] ? 32'hE24DDF00 : 32'hE28DDF00) | {25'd0, u[6:0]};
				else if (u[10:9] == 2'b10)                // PUSH {rlist, LR}: STMDB SP!, POP: LDMIA SP!
					aop = (u[11] ? 32'hE8BD0000 : 32'hE92D0000) | {24'd0, u[7:0]} | (u[8] ? (u[11] ? 32'h8000 : 32'h4000) : 32'd0);
				else
					aop = 32'hE7F000F0;                   // (undefined)
			end
			5'b110_00: aop = 32'hE8A00000 | {u[10:8], 16'd0} | {24'd0, u[7:0]};                   // STMIA Rb!, {rlist}
			5'b110_01: aop = 32'hE8B00000 | {u[10:8], 16'd0} | {24'd0, u[7:0]};                   // LDMIA Rb!, {rlist}
			5'b110_10, 5'b110_11: begin
				if (u[11:8] == 4'hF) aop = 32'hEF000000 | {24'd0, u[7:0]};                        // SWI
				else aop = {u[11:8], 28'd0};                                                     // Bcc: its condition
			end
			5'b111_00: aop = 32'd0;                                                                // B (tk)
			5'b111_10: aop = 32'd0;                                                                // BL prefix (tk)
			5'b111_01, 5'b111_11: aop = 32'd0;                                                     // BL suffix (tk)
			default: aop = 32'hE7F000F0;
			endcase
			thumb_aop = aop;
		end
	endfunction
	reg  [31:0] aop;                         // the ARM-form opcode executing (registered)
	reg  [2:0]  tk;                          // 0 ARM op; 1 Bcc, 2 B, 3 BL prefix, 4 BL suffix
	reg  [31:0] tgt;                         // the Thumb branch target / BL prefix link
	wire [15:0] t = ir[15:0];
	always @(*) begin
		tk = 3'd0; tgt = 32'd0;
		if (tbit) casez (t[15:11])
			5'b110_10, 5'b110_11: if (t[11:8] != 4'hF) begin tk = 3'd1; tgt = pc + {{23{t[7]}}, t[7:0], 1'b0}; end   // Bcc (SWI apart)
			5'b111_00: begin tk = 3'd2; tgt = pc + {{20{t[10]}}, t[10:0], 1'b0}; end               // B
			5'b111_10: begin tk = 3'd3; tgt = pc + {{9{t[10]}}, t[10:0], 12'd0}; end               // BL prefix: LR
			5'b111_01, 5'b111_11: begin tk = 3'd4; tgt = {21'd0, t[10:0]}; end                     // BL suffix (and BLX's form: as BL)
			default: ;
		endcase
	end

	// ---- decode of the ARM form ----------------------------------------------------------------
	wire [3:0]  cond = aop[31:28];
	wire [3:0]  rn   = aop[19:16], rd = aop[15:12], rs = aop[11:8], rm = aop[3:0];
	wire        is_dp     = (aop[27:26] == 2'b00) && !(aop[27:25] == 3'b000 && aop[7] == 1'b1 && aop[4] == 1'b1);   // data processing (not the bit-7/4 group)
	wire        is_mul    = (aop[27:24] == 4'b0000) && (aop[7:4] == 4'b1001);
	wire        is_mull   = is_mul && aop[23];
	wire        is_swp    = (aop[27:23] == 5'b00010) && (aop[21:20] == 2'b00) && (aop[11:4] == 8'b00001001);
	wire        is_hw     = (aop[27:25] == 3'b000) && (aop[7] == 1'b1) && (aop[4] == 1'b1) && (aop[6:5] != 2'b00) && !is_swp;   // LDRH/STRH/LDRSB/LDRSH
	wire        is_bx     = (aop[27:4] == 24'h12FFF1);
	wire        is_psr    = is_dp && (aop[24:23] == 2'b10) && !aop[20];           // TST..CMN without S: MRS/MSR
	wire        is_mrs    = is_psr && (aop[21] == 1'b0) && !aop[25];
	wire        is_msr    = is_psr && (aop[21] == 1'b1);
	wire        is_ldst   = (aop[27:26] == 2'b01);
	wire        is_ldm    = (aop[27:25] == 3'b100);
	wire        is_b      = (aop[27:25] == 3'b101);
	wire        is_swi    = (aop[27:24] == 4'hF);
	wire        is_cop    = (aop[27:26] == 2'b11) && !is_swi;                      // coprocessor: undefined here
	wire        is_undef  = ((aop[27:25] == 3'b011) && aop[4]) || is_cop || (is_dp && !is_mul && !is_swp && !is_hw && !is_bx && is_psr && !is_mrs && !is_msr);
	wire        dp_S      = aop[20];
	wire [3:0]  dp_op     = aop[24:21];
	wire        dp_imm    = aop[25];
	wire        dp_regsh  = !aop[25] && aop[4];                                    // shift by register
	wire        dp_wr     = !(dp_op[3:2] == 2'b10);                                // TST TEQ CMP CMN write no register
	wire        ld_L = aop[20], ld_P = aop[24], ld_U = aop[23], ld_B = aop[22], ld_W = aop[21];
	wire        hw_H = aop[5], hw_S = aop[6];
	wire        lm_S = aop[22];
	wire [15:0] rlist = aop[15:0];
	reg         cond_ok;
	always @(*) begin : condeval
		reg c;
		case (cond)
			4'h0: c = fZ;           4'h1: c = !fZ;
			4'h2: c = fC;           4'h3: c = !fC;
			4'h4: c = fN;           4'h5: c = !fN;
			4'h6: c = fV;           4'h7: c = !fV;
			4'h8: c = fC && !fZ;    4'h9: c = !fC || fZ;
			4'hA: c = fN == fV;     4'hB: c = fN != fV;
			4'hC: c = !fZ && (fN == fV); 4'hD: c = fZ || (fN != fV);
			4'hE: c = 1'b1;         default: c = 1'b0;
		endcase
		cond_ok = c;
	end

	// ---- register reads --------------------------------------------------------------------------
	// R15 reads as pc, +4 more when a data-processing shift is by register (the ARM's extra
	// cycle lets the pipeline advance under it)
	wire        bank_usr;                    // LDM/STM with the S bit: the user bank
	wire [4:0]  rmode = bank_usr ? M_USR : mode;
	wire        dp_real = is_dp && !is_bx && !is_psr && !is_mul && !is_swp && !is_hw;   // a data-processing instruction proper
	wire [31:0] pc_rd  = pc + ((dp_real && dp_regsh) ? 32'd4 : 32'd0);
	wire [31:0] v_rn   = (rn == 4'd15) ? pc_rd : R[rix(rn, rmode)];
	wire [31:0] v_rm   = (rm == 4'd15) ? pc_rd : R[rix(rm, rmode)];
	wire [31:0] v_rs   = (rs == 4'd15) ? pc_rd : R[rix(rs, rmode)];
	wire [31:0] v_rd   = (rd == 4'd15) ? pc + 32'd4 : R[rix(rd, rmode)];         // a stored PC: +12
	// Thumb's PC-relative addressing uses the word-aligned PC (LDR Rd, [PC], ADD Rd, PC)
	wire        thumb_pcrel = tbit && (rn == 4'd15) && ((is_ldst && ld_L) || (is_dp && dp_imm && dp_op == 4'h4));
	wire [31:0] v_rn_a = thumb_pcrel ? {pc[31:2], 2'b00} : v_rn;

	// ---- the barrel shifter and operand 2 -----------------------------------------------------
	// (an arithmetic shift written out: inside a ?: Verilog drops $signed and shifts in zeros)
	function [31:0] asr;
		input [31:0] v; input [4:0] n;
		reg [63:0] w;
		begin w = {{32{v[31]}}, v} >> n; asr = w[31:0]; end
	endfunction
	reg  [31:0] op2; reg sh_c;
	always @(*) begin : shifter
		reg [7:0] amt; reg [1:0] ty; reg [31:0] v; reg byreg;
		op2 = 32'd0; sh_c = fC;
		if (is_dp && dp_imm) begin                              // imm8 ROR 2*rot
			amt = {3'd0, aop[11:8], 1'b0};
			v = {24'd0, aop[7:0]};
			op2 = (v >> amt) | (v << (6'd32 - {1'b0, amt[4:0]}));
			if (amt == 8'd0) op2 = v;
			sh_c = (amt == 8'd0) ? fC : op2[31];
		end else if (is_ldst && aop[25] && !is_dp) begin        // LDR/STR register offset: shift by imm5
			v = v_rm; ty = aop[6:5]; amt = {3'd0, aop[11:7]};
			case (ty)
				2'd0: op2 = v << amt[4:0];
				2'd1: op2 = (amt == 8'd0) ? 32'd0 : (v >> amt[4:0]);
				2'd2: op2 = (amt == 8'd0) ? {32{v[31]}} : asr(v, amt[4:0]);
				default: op2 = (amt == 8'd0) ? {fC, v[31:1]} : ((v >> amt[4:0]) | (v << (6'd32 - {1'b0, amt[4:0]})));
			endcase
		end else begin                                          // register, shifted by imm5 or Rs
			v = v_rm; ty = aop[6:5]; byreg = aop[4];
			amt = byreg ? v_rs[7:0] : {3'd0, aop[11:7]};
			case (ty)
			2'd0: begin                                         // LSL
				if (amt == 8'd0) begin op2 = v; sh_c = fC; end
				else if (amt < 8'd32) begin op2 = v << amt[4:0]; sh_c = v[6'd32 - {1'b0, amt[4:0]}]; end
				else if (amt == 8'd32) begin op2 = 32'd0; sh_c = v[0]; end
				else begin op2 = 32'd0; sh_c = 1'b0; end
			end
			2'd1: begin                                         // LSR (#0 = #32)
				if (amt == 8'd0) begin if (byreg) begin op2 = v; sh_c = fC; end else begin op2 = 32'd0; sh_c = v[31]; end end
				else if (amt < 8'd32) begin op2 = v >> amt[4:0]; sh_c = v[amt[4:0] - 5'd1]; end
				else if (amt == 8'd32) begin op2 = 32'd0; sh_c = v[31]; end
				else begin op2 = 32'd0; sh_c = 1'b0; end
			end
			2'd2: begin                                         // ASR (#0 = #32)
				if (amt == 8'd0) begin if (byreg) begin op2 = v; sh_c = fC; end else begin op2 = {32{v[31]}}; sh_c = v[31]; end end
				else if (amt < 8'd32) begin op2 = asr(v, amt[4:0]); sh_c = v[amt[4:0] - 5'd1]; end
				else begin op2 = {32{v[31]}}; sh_c = v[31]; end
			end
			default: begin                                      // ROR (#0 = RRX)
				if (amt == 8'd0) begin if (byreg) begin op2 = v; sh_c = fC; end else begin op2 = {fC, v[31:1]}; sh_c = v[0]; end end
				else if (amt[4:0] == 5'd0) begin op2 = v; sh_c = v[31]; end
				else begin op2 = (v >> amt[4:0]) | (v << (6'd32 - {1'b0, amt[4:0]})); sh_c = v[amt[4:0] - 5'd1]; end
			end
			endcase
		end
	end

	// ---- the ALU ---------------------------------------------------------------------------------
	reg  [31:0] alu; reg alu_c, alu_v, alu_logic;
	always @(*) begin : alunit
		reg [32:0] s; reg [31:0] a, b; reg cin;
		a = v_rn_a; b = op2; cin = 1'b0; alu_logic = 1'b0; s = 33'd0;
		case (dp_op)
			4'h0, 4'h8: begin alu = a & b; alu_logic = 1'b1; end
			4'h1, 4'h9: begin alu = a ^ b; alu_logic = 1'b1; end
			4'hC:       begin alu = a | b; alu_logic = 1'b1; end
			4'hD:       begin alu = b; alu_logic = 1'b1; end
			4'hE:       begin alu = a & ~b; alu_logic = 1'b1; end
			4'hF:       begin alu = ~b; alu_logic = 1'b1; end
			4'h2, 4'hA: begin b = ~op2; cin = 1'b1; end          // SUB CMP
			4'h3:       begin a = op2; b = ~v_rn_a; cin = 1'b1; end   // RSB
			4'h4, 4'hB: cin = 1'b0;                                // ADD CMN
			4'h5:       cin = fC;                                  // ADC
			4'h6:       begin b = ~op2; cin = fC; end              // SBC
			default:    begin a = op2; b = ~v_rn_a; cin = fC; end  // RSC
		endcase
		s = {1'b0, a} + {1'b0, b} + {32'd0, cin};
		if (!alu_logic) alu = s[31:0];
		alu_c = alu_logic ? sh_c : s[32];
		alu_v = alu_logic ? fV : ((a[31] == b[31]) && (s[31] != a[31]));
	end

	// ---- the multiplier -----------------------------------------------------------------------
	// Rd = Rm * Rs (+ Rn); the long forms {RdHi, RdLo} = Rm * Rs (+ {RdHi, RdLo}), signed when
	// bit 22. The ARM's early-out: 1 to 4 cycles by how many bytes of Rs matter.
	wire        mul_acc = aop[21];
	wire        mul_signed = aop[22];
	// the operands latched as the instruction starts, the product formed over its I cycles (a
	// 32 x 32 multiply is too long for one clock), the registers written as they end
	reg  [63:0] mul_a, mul_b, mul_p, mul_add;
	reg         mul_pend, mul_long, mul_s; reg [4:0] mul_rd_hi, mul_rd_lo;
	// mul_p is a clock behind mul_a/mul_b: the product is there from the second clock after the
	// operands. A one-I-cycle multiply whose tick comes on the first would write the PREVIOUS
	// product; it waits that clock instead (mul_wait: the I cycles are over, the product is not)
	reg         mul_rdy, mul_wait;
	always @(posedge clk) mul_p <= mul_a * mul_b;
	wire [63:0] mul_r  = mul_long ? mul_p + mul_add : {32'd0, mul_p[31:0] + mul_add[31:0]};
	wire [2:0]  mul_m  = (mul_signed ? ((v_rs[31:8] == 24'd0 || v_rs[31:8] == 24'hFFFFFF) ? 3'd1 : (v_rs[31:16] == 16'd0 || v_rs[31:16] == 16'hFFFF) ? 3'd2 : (v_rs[31:24] == 8'd0 || v_rs[31:24] == 8'hFF) ? 3'd3 : 3'd4)
	                                 : ((v_rs[31:8] == 24'd0) ? 3'd1 : (v_rs[31:16] == 16'd0) ? 3'd2 : (v_rs[31:24] == 8'd0) ? 3'd3 : 3'd4));

	// ---- memory addresses ----------------------------------------------------------------------
	wire [31:0] ld_off  = is_hw ? (aop[22] ? {24'd0, aop[11:8], aop[3:0]} : v_rm)          // halfword forms: imm8 or Rm
	                            : (aop[25] ? op2 : {20'd0, aop[11:0]});
	wire [31:0] ld_base = v_rn_a;
	wire [31:0] ld_ea   = ld_U ? ld_base + ld_off : ld_base - ld_off;
	wire [31:0] ld_addr = ld_P ? ld_ea : ld_base;                                 // pre: offset first; post: the base
	wire        ld_wb   = !ld_P || ld_W;                                          // post-indexed always writes back
	// LDM/STM: n words up from the lowest address
	wire [4:0]  lm_n;
	wire [15:0] lm_cnt_in = rlist;
	assign lm_n = lm_cnt_in[0] + lm_cnt_in[1] + lm_cnt_in[2] + lm_cnt_in[3] + lm_cnt_in[4] + lm_cnt_in[5] + lm_cnt_in[6] + lm_cnt_in[7]
	            + lm_cnt_in[8] + lm_cnt_in[9] + lm_cnt_in[10] + lm_cnt_in[11] + lm_cnt_in[12] + lm_cnt_in[13] + lm_cnt_in[14] + lm_cnt_in[15];
	wire [5:0]  lm_words = (rlist == 16'd0) ? 6'd16 : {1'b0, lm_n};               // (an empty list: the PC, and 0x40)
	wire [31:0] lm_span  = {24'd0, lm_words, 2'd0};
	wire [31:0] lm_start = ld_U ? (ld_P ? v_rn + 32'd4 : v_rn) : (ld_P ? v_rn - lm_span : v_rn - lm_span + 32'd4);
	wire [31:0] lm_final = ld_U ? v_rn + lm_span : v_rn - lm_span;

	// ---- the machine ----------------------------------------------------------------------------
	localparam [3:0] S_EX = 4'd0, S_I = 4'd1, S_MEM = 4'd2, S_LMEM = 4'd3, S_LDWB = 4'd4, S_SWP2 = 4'd5,
	                 S_REFILL1 = 4'd6, S_REFILL2 = 4'd7, S_EXC = 4'd8;
	reg  [3:0]  st;
	reg  [7:0]  icnt;                        // I cycles left
	reg  [31:0] ld_data_r;                   // the load result's register, address
	reg  [3:0]  ld_rd;
	reg  [1:0]  ld_kind;                     // 0 word, 1 byte, 2 halfword, 3 signed halfword/byte
	reg         ld_sbyte, ld_load, ld_swp;   // (latched: `ir` is the next instruction once S_EX is over)
	reg  [31:0] ld_a;
	reg  [15:0] lm_left;
	reg  [31:0] lm_addr, lm_wbv;
	reg         lm_first, lm_wb, lm_load, lm_pc, lm_usr, lm_psr, lm_empty;
	reg  [3:0]  lm_rn;
	reg         flush;                       // the instruction wrote the PC: refill
	reg  [31:0] npc;
	reg         swp_byte;
	reg  [31:0] swp_rd_v;
	reg         exc_pend; reg [2:0] exc_kind;   // 1 undefined, 2 SWI, 3 IRQ
	reg         bank_usr_r;
	assign bank_usr = bank_usr_r;
	reg         retire_r;
	assign retire = retire_r;
	assign dbg_pc = pc;

	wire [31:0] fetch_step = tbit ? 32'd2 : 32'd4;
	wire        irq_take = irq && !cpsr[7];

	// the lowest register in the list still to transfer
	reg [3:0] lm_next;
	always @(*) begin : lowest
		integer k; lm_next = 4'd15;
		for (k = 15; k >= 0; k = k - 1) if (lm_left[k]) lm_next = k[3:0];
	end
	wire [31:0] lm_rd_val = (lm_next == 4'd15) ? pc                   // (already past the fetch: the instruction + 12)
	                      : (lm_next == lm_rn && lm_wb && !lm_first) ? lm_wbv : R[rix(lm_next, lm_usr ? M_USR : mode)];

	// a loaded word, rotated by its address; halfwords and bytes
	function [31:0] load_fix;
		input [31:0] d; input [31:0] a; input [1:0] kind; input sbyte;
		reg [31:0] r;
		begin
			case (kind)
			2'd0: begin                                           // word: ROR 8*(a&3)
				case (a[1:0])
					2'd0: r = d; 2'd1: r = {d[7:0], d[31:8]}; 2'd2: r = {d[15:0], d[31:16]}; default: r = {d[23:0], d[31:24]};
				endcase
			end
			2'd1: r = {24'd0, d[7:0]};                            // byte
			2'd2: r = a[0] ? {d[7:0], 16'd0, d[15:8]} : {16'd0, d[15:0]};   // halfword (odd: rotated)
			default: begin                                        // signed halfword (odd: the signed byte); signed byte
				if (sbyte || a[0]) r = {{24{sbyte ? d[7] : d[15]}}, sbyte ? d[7:0] : d[15:8]};
				else r = {{16{d[15]}}, d[15:0]};
			end
			endcase
			load_fix = r;
		end
	endfunction

	// the bench's state read
	always @(*) begin
		if (st_idx < 6'd31) st_data = R[st_idx[4:0]];
		else if (st_idx == 6'd31) st_data = cpsr;
		else if (st_idx < 6'd37) st_data = spsr[st_idx - 6'd32];
		else if (st_idx == 6'd37) st_data = ir;
		else if (st_idx == 6'd38) st_data = ir1;
		else st_data = pc;
	end

	// MSR's new value: the fields the instruction names, what the mode may change
	wire [31:0] msr_src  = dp_imm ? op2 : v_rm;
	function [31:0] msr_mix;
		input [31:0] old; input [31:0] v; input [3:0] f; input priv; input is_cpsr;
		reg [31:0] r;
		begin
			r = old;
			if (f[3]) r[31:24] = v[31:24];
			if (priv) begin
				if (f[2]) r[23:16] = v[23:16];
				if (f[1]) r[15:8]  = v[15:8];
				if (f[0]) r[7:0]   = {v[7:5], v[4] | is_cpsr, v[3:0]};   // (bit 4 of the CPSR's mode is always set)
			end
			msr_mix = r;
		end
	endfunction

	integer i;
	always @(posedge clk) begin
		retire_r <= 1'b0;
		if (mul_pend) mul_rdy <= 1'b1;
		if (rst) begin
			st <= prime ? S_EX : S_REFILL1;
			req <= 1'b0; we <= 1'b0; code <= 1'b0; seq <= 1'b0; size <= 2'd2; addr <= 32'd0; dout <= 32'd0;
			flush <= 1'b0; exc_pend <= 1'b0; bank_usr_r <= 1'b0; icnt <= 8'd0; mul_pend <= 1'b0; mul_rdy <= 1'b0; mul_wait <= 1'b0;
			if (ld_we) begin
				if (ld_idx < 6'd31) R[ld_idx[4:0]] <= ld_data;
				else if (ld_idx == 6'd31) cpsr <= ld_data;
				else if (ld_idx < 6'd37) spsr[ld_idx - 6'd32] <= ld_data;
				else if (ld_idx == 6'd37) begin ir <= ld_data; aop <= cpsr[5] ? thumb_aop(ld_data[15:0]) : ld_data; end
				else if (ld_idx == 6'd38) ir1 <= ld_data;
				else pc <= ld_data;
			end else if (!prime) begin
				cpsr <= 32'h000000D3; pc <= 32'd0;
				spsr[0] <= 32'd0; spsr[1] <= 32'd0; spsr[2] <= 32'd0; spsr[3] <= 32'd0; spsr[4] <= 32'd0;
			end
		end else begin
			case (st)
			// -------- the instruction's first cycle: the fetch, the datapath ---------------------
			S_EX: begin
				if (!req) begin
					// an interrupt lands before the instruction
					if (irq_take) begin
						exc_kind <= 3'd3; st <= S_EXC;
					end else begin
						req <= 1'b1; code <= 1'b1; seq <= 1'b1; we <= 1'b0; addr <= tbit ? {pc[31:1], 1'b0} : {pc[31:2], 2'b00}; size <= tbit ? 2'd1 : 2'd2;
					end
				end else if (ack && irq_take) begin
					// an interrupt landed while the fetch was out: the instruction waits
					req <= 1'b0; exc_kind <= 3'd3; st <= S_EXC;
				end else if (ack) begin
					req <= 1'b0;
					// the pipeline moves up; a branch below replaces it
					ir <= ir1; ir1 <= tbit ? {16'd0, din[15:0]} : din; pc <= pc + fetch_step;
					aop <= tbit ? thumb_aop(ir1[15:0]) : ir1;
					flush <= 1'b0; retire_r <= 1'b1; bank_usr_r <= 1'b0;
					// the next instruction's fetch, now, unless this one goes on (set below)
					req <= 1'b1; code <= 1'b1; seq <= 1'b1; we <= 1'b0; size <= tbit ? 2'd1 : 2'd2;
					addr <= tbit ? {pc[31:1], 1'b0} + 32'd2 : {pc[31:2], 2'b00} + 32'd4;
					if (tk != 3'd0) begin
						// Thumb's own branches
						case (tk)
						3'd1: if (cond_ok) begin pc <= tgt; st <= S_REFILL1; retire_r <= 1'b0; req <= 1'b0; end
						3'd2: begin pc <= tgt; st <= S_REFILL1; retire_r <= 1'b0; req <= 1'b0; end
						3'd3: R[rix(4'd14, mode)] <= tgt;
						default: begin
							R[rix(4'd14, mode)] <= (pc - 32'd2) | 32'd1;
							pc <= (R[rix(4'd14, mode)] + {20'd0, tgt[10:0], 1'b0}) & 32'hFFFFFFFE;
							st <= S_REFILL1; retire_r <= 1'b0; req <= 1'b0;
						end
						endcase
					end else if (!cond_ok) begin
						// not executed: one S cycle
					end else if (is_swi) begin
						exc_kind <= 3'd2; st <= S_EXC; retire_r <= 1'b0; req <= 1'b0;
					end else if (is_undef) begin
						exc_kind <= 3'd1; st <= S_EXC; retire_r <= 1'b0; req <= 1'b0;
					end else if (is_bx) begin
						pc <= {v_rm[31:1], 1'b0};                             // (an ARM target's bit 1 stays: the fetch ignores it)
						cpsr[5] <= v_rm[0];
						st <= S_REFILL1; retire_r <= 1'b0; req <= 1'b0;
					end else if (is_b) begin
						if (aop[24]) R[rix(4'd14, mode)] <= pc - 32'd4;
						pc <= pc + {{6{aop[23]}}, aop[23:0], 2'b00};
						st <= S_REFILL1; retire_r <= 1'b0; req <= 1'b0;
					end else if (is_mul) begin
						// the operands now; the product lands as the I cycles end
						mul_a <= mul_signed ? {{32{v_rm[31]}}, v_rm} : {32'd0, v_rm};
						mul_b <= mul_signed ? {{32{v_rs[31]}}, v_rs} : {32'd0, v_rs};
						mul_add <= is_mull ? (mul_acc ? {v_rn, v_rd} : 64'd0) : (mul_acc ? {32'd0, v_rd} : 64'd0);
						mul_pend <= 1'b1; mul_rdy <= 1'b0; mul_wait <= 1'b0; mul_long <= is_mull; mul_s <= dp_S;
						mul_rd_hi <= rix(rn, mode); mul_rd_lo <= rix(rd, mode);
						icnt <= {5'd0, mul_m} + (mul_acc ? 8'd1 : 8'd0) + (is_mull ? 8'd1 : 8'd0);
						 st <= S_I; retire_r <= 1'b0; req <= 1'b0;
					end else if (is_swp) begin
						swp_byte <= aop[22]; ld_a <= v_rn; swp_rd_v <= (rm == 4'd15) ? pc + 32'd4 : v_rm; ld_rd <= rd; ld_swp <= 1'b1; ld_load <= 1'b1;
						addr <= v_rn; size <= aop[22] ? 2'd0 : 2'd2; we <= 1'b0; code <= 1'b0; seq <= 1'b0; req <= 1'b1;
						st <= S_MEM; retire_r <= 1'b0;
					end else if (is_mrs) begin
						R[rix(rd, mode)] <= aop[22] ? ((cur_spsr == 3'd5) ? cpsr : spsr[cur_spsr]) : cpsr;
					end else if (is_msr) begin
						if (aop[22]) begin
							if (cur_spsr != 3'd5) spsr[cur_spsr] <= msr_mix(spsr[cur_spsr], msr_src, aop[19:16], 1'b1, 1'b0);
						end else
							cpsr <= msr_mix(cpsr, msr_src, aop[19:16], privileged, 1'b1);
					end else if (is_hw || is_ldst) begin
						// the data cycle next; the base written back now (a load of the same
						// register overrides it)
						ld_a <= ld_addr; ld_rd <= rd; ld_swp <= 1'b0; ld_load <= ld_L;
						ld_kind <= is_hw ? (hw_S ? 2'd3 : 2'd2) : (ld_B ? 2'd1 : 2'd0);
						ld_sbyte <= is_hw && hw_S && !hw_H;
						if (ld_wb && rn != 4'd15) R[rix(rn, mode)] <= ld_ea;
						addr <= ld_addr; code <= 1'b0; seq <= 1'b0; req <= 1'b1;
						size <= is_hw ? ((hw_S && !hw_H) ? 2'd0 : 2'd1) : (ld_B ? 2'd0 : 2'd2);
						we <= !ld_L;
						dout <= is_hw ? {v_rd[15:0], v_rd[15:0]} : ld_B ? {4{v_rd[7:0]}} : v_rd;
						st <= S_MEM; retire_r <= 1'b0;
					end else if (is_ldm) begin
						lm_left <= (rlist == 16'd0) ? 16'h8000 : rlist;
						lm_addr <= lm_start; lm_wbv <= lm_final; lm_rn <= rn;
						lm_wb <= ld_W; lm_load <= ld_L; lm_first <= 1'b1;
						lm_pc <= rlist[15] || (rlist == 16'd0); lm_empty <= (rlist == 16'd0);
						lm_usr <= lm_S && !(ld_L && (rlist[15] || rlist == 16'd0));
						lm_psr <= lm_S && ld_L && (rlist[15] || rlist == 16'd0);
						bank_usr_r <= lm_S && !(ld_L && (rlist[15] || rlist == 16'd0));
						if (ld_L && ld_W) R[rix(rn, (lm_S && !(rlist[15] || rlist == 16'd0)) ? M_USR : mode)] <= lm_final;   // (a loaded Rn overrides it; a user-bank transfer's lands there)
						st <= S_LMEM; retire_r <= 1'b0; req <= 1'b0;
					end else if (is_dp) begin
						// the data processing: the result, the flags, the PC
						if (dp_wr) begin
							if (rd == 4'd15) begin
								pc <= tbit ? {alu[31:1], 1'b0} : alu;
								if (dp_S && cur_spsr != 3'd5) cpsr <= spsr[cur_spsr];
								else if (dp_S) begin cpsr[31] <= alu[31]; cpsr[30] <= (alu == 32'd0); cpsr[29] <= alu_c; cpsr[28] <= alu_v; end
								st <= dp_regsh ? S_I : S_REFILL1; flush <= 1'b1; retire_r <= 1'b0; req <= 1'b0;
								icnt <= 8'd1; 
							end else begin
								R[rix(rd, mode)] <= alu;
								if (dp_S) begin cpsr[31] <= alu[31]; cpsr[30] <= (alu == 32'd0); cpsr[29] <= alu_c; cpsr[28] <= alu_v; end
								if (dp_regsh) begin st <= S_I; icnt <= 8'd1;  retire_r <= 1'b0; req <= 1'b0; end
							end
						end else begin
							if (rd == 4'd15 && dp_S && cur_spsr != 3'd5) cpsr <= spsr[cur_spsr];   // (TEQP and kin)
							else begin cpsr[31] <= alu[31]; cpsr[30] <= (alu == 32'd0); cpsr[29] <= alu_c; cpsr[28] <= alu_v; end
							if (dp_regsh) begin st <= S_I; icnt <= 8'd1;  retire_r <= 1'b0; req <= 1'b0; end
						end
					end
				end
			end
			// -------- internal cycles --------------------------------------------------------------
			S_I: begin
				if (mul_wait ? mul_rdy : tick) begin
					if (mul_pend && !mul_rdy && icnt <= 8'd1) begin
						icnt <= 8'd0; mul_wait <= 1'b1;                           // (the product a clock away)
					end else if (icnt <= 8'd1) begin
						icnt <= 8'd0; mul_wait <= 1'b0;
						st <= flush ? S_REFILL1 : S_EX;
						retire_r <= !flush;
						if (mul_pend) begin
							mul_pend <= 1'b0;
							// synthesis translate_off
							if (mul_p !== mul_a * mul_b) $display("arm7tdmi: STALE PRODUCT %h, want %h", mul_p, mul_a * mul_b);
							// synthesis translate_on
							if (mul_long) begin
								R[mul_rd_lo] <= mul_r[31:0]; R[mul_rd_hi] <= mul_r[63:32];   // (the same register for both: the high half stays)
								if (mul_s) begin cpsr[31] <= mul_r[63]; cpsr[30] <= (mul_r == 64'd0); end
							end else begin
								R[mul_rd_hi] <= mul_r[31:0];
								if (mul_s) begin cpsr[31] <= mul_r[31]; cpsr[30] <= (mul_r[31:0] == 32'd0); end
							end
						end
					end else icnt <= icnt - 8'd1;
				end
			end
			// -------- one data cycle (LDR/STR, SWP's read) -----------------------------------------
			S_MEM: begin
				if (ack) begin
					req <= 1'b0;
					if (ld_swp) begin
						ld_data_r <= load_fix(din, ld_a, swp_byte ? 2'd1 : 2'd0, 1'b0);
						addr <= ld_a; we <= 1'b1; dout <= swp_byte ? {4{swp_rd_v[7:0]}} : swp_rd_v; req <= 1'b1; seq <= 1'b0;
						st <= S_SWP2;
					end else if (ld_load) begin
						ld_data_r <= load_fix(din, ld_a, ld_kind, ld_sbyte);
						st <= S_LDWB; icnt <= 8'd1; 
					end else begin
						we <= 1'b0; st <= S_EX; retire_r <= 1'b1;
					end
				end
			end
			S_SWP2: begin
				if (ack) begin
					req <= 1'b0; we <= 1'b0;
					st <= S_LDWB; icnt <= 8'd1; 
				end
			end
			// -------- the load's writeback: an I cycle, then the register (the PC: a refill) ------
			S_LDWB: begin
				if (tick) begin
					if (ld_rd == 4'd15) begin
						pc <= ld_data_r;                                     // (the fetch ignores the low bits)
						st <= S_REFILL1;
					end else begin
						R[rix(ld_rd, mode)] <= ld_data_r;
						st <= S_EX; retire_r <= 1'b1;
					end
				end
			end
			// -------- LDM/STM: a word a cycle --------------------------------------------------
			S_LMEM: begin
				if (!req) begin
					if (lm_left == 16'd0) begin
						// done: STM's writeback, LDM's final I cycle and PC
						bank_usr_r <= 1'b0;
						if (!lm_load) begin
							if (lm_wb) R[rix(lm_rn, lm_usr ? M_USR : mode)] <= lm_wbv;
							st <= S_EX; retire_r <= 1'b1;
						end else begin
							st <= S_LDWB; icnt <= 8'd1; 
							ld_rd <= lm_pc ? 4'd15 : 4'd0;
							if (!lm_pc) ld_rd <= 4'd0;
							if (lm_pc) begin
								if (lm_psr && cur_spsr != 3'd5) cpsr <= spsr[cur_spsr];
								pc <= (tbit && !lm_empty) ? {ld_data_r[31:1], 1'b0} : ld_data_r;   // (an empty list's PC keeps bit 0, as the reference has it)
								st <= S_REFILL1;
							end else begin
								st <= S_I; icnt <= 8'd1; 
							end
						end
					end else begin
						addr <= lm_addr; size <= 2'd2; code <= 1'b0; seq <= !lm_first; req <= 1'b1;
						we <= !lm_load; dout <= lm_rd_val;
					end
				end else if (ack) begin
					req <= 1'b0; we <= 1'b0;
					lm_addr <= lm_addr + 32'd4; lm_first <= 1'b0;
					lm_left[lm_next] <= 1'b0;
					if (lm_load) begin
						if (lm_next == 4'd15) ld_data_r <= din;
						else R[rix(lm_next, lm_usr ? M_USR : mode)] <= din;
					end
				end
			end
			// -------- the pipeline refill after a branch: two fetches --------------------------
			S_REFILL1: begin
				if (!req) begin
					req <= 1'b1; code <= 1'b1; seq <= 1'b0; we <= 1'b0; addr <= tbit ? {pc[31:1], 1'b0} : {pc[31:2], 2'b00}; size <= tbit ? 2'd1 : 2'd2;
				end else if (ack) begin
					req <= 1'b0; ir <= tbit ? {16'd0, din[15:0]} : din; pc <= pc + fetch_step; st <= S_REFILL2;
					aop <= tbit ? thumb_aop(din[15:0]) : din;
				end
			end
			S_REFILL2: begin
				if (!req) begin
					req <= 1'b1; code <= 1'b1; seq <= 1'b1; we <= 1'b0; addr <= tbit ? {pc[31:1], 1'b0} : {pc[31:2], 2'b00}; size <= tbit ? 2'd1 : 2'd2;
				end else if (ack) begin
					req <= 1'b0; ir1 <= tbit ? {16'd0, din[15:0]} : din; pc <= pc + fetch_step; st <= S_EX;
					retire_r <= 1'b1; flush <= 1'b0;
				end
			end
			// -------- an exception: the mode, the link, the vector ----------------------------
			S_EXC: begin
				case (exc_kind)
				3'd1: begin                                                      // undefined
					spsr[4] <= cpsr; R[29 + 1] <= pc - fetch_step - fetch_step;        // (pc is past the fetch: the next instruction)
					cpsr[4:0] <= M_UND; cpsr[5] <= 1'b0; cpsr[7] <= 1'b1; pc <= 32'h04;
				end
				3'd2: begin                                                      // SWI
					spsr[1] <= cpsr; R[23 + 1] <= pc - fetch_step - fetch_step;
					cpsr[4:0] <= M_SVC; cpsr[5] <= 1'b0; cpsr[7] <= 1'b1; pc <= 32'h08;
				end
				default: begin                                                   // IRQ: LR = next + 4
					spsr[3] <= cpsr; R[27 + 1] <= pc - fetch_step - fetch_step + 32'd4;
					cpsr[4:0] <= M_IRQ; cpsr[5] <= 1'b0; cpsr[7] <= 1'b1; pc <= 32'h18;
				end
				endcase
				st <= S_REFILL1;
			end
			default: st <= S_EX;
			endcase
		end
	end
endmodule
`default_nettype wire
