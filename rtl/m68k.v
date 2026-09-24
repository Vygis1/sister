//////////////////////////////////////////////////////////////////////////////////
// m68k.v - a Motorola 68000.
//
// The largest CPU in this tree by a wide margin, and the one a Mega Drive is
// built around. It is being built in increments that each end with a green
// testbench, because an instruction set this size cannot be written and then
// debugged.
//
// --- the shape, and why -----------------------------------------------------
//
// Same architecture as the Z80 next door, for the same reason. An instruction is
// a state machine that needs memory part-way through, and the naive way to write
// that -- go back to the fetch state and carry on -- re-decodes the opcode and
// starts the instruction again, forever. The Z80's first attempt did exactly
// that and had to be thrown away.
//
// So a memory access goes to a shared state and a CONTINUATION says where to
// resume. The continuation is checked at the top of S_EXEC before anything is
// decoded, so an instruction in the middle of itself is never mistaken for a new
// one.
//
// --- the effective address machinery -------------------------------------------
//
// Twelve addressing modes, and every instruction that touches memory uses the
// same twelve. Writing them into each instruction would be twelve chances to get
// each one wrong; instead there is one resolver, driven twice for an instruction
// like MOVE that has a source and a destination.
//
//   ea_start   which mode, which register, what size, and where to go after
//   S_EA_*     fetch any extension words, compute the address, do the access
//
// A resolve either produces a value in `src` (a read) or takes one from `src`
// (a write), and jumps to `ea_ret` when it is done.
//
// --- the bus -----------------------------------------------------------------
//
// Not the real chip's /AS, /UDS, /LDS, /DTACK handshake: that exists to talk to
// 1979 memory and nothing on this board is 1979 memory. Sixteen bits wide, one
// enable of latency, like everything else here. A byte access still moves a word
// and picks a half; `ds` says which, for memory that cares.
//
// --- reset --------------------------------------------------------------------
//
// There is no reset vector in the usual sense: the chip reads its initial stack
// pointer from $000000 and its initial PC from $000004. That is why every Mega
// Drive cartridge begins with two longwords rather than code.
//
// --- what is here so far --------------------------------------------------------
//
//   MOVE.B/W/L and MOVEA, with modes Dn, An, (An), (An)+, -(An), d16(An),
//   (xxx).W, (xxx).L and #imm.  MOVEQ, NOP, BRA, STOP.
//   ADD, SUB, AND, OR, CMP in the <ea>-to-Dn direction, and ADDA/SUBA/CMPA.
//   BRA, BSR, all fourteen Bcc, RTS, JMP, JSR and LEA.
//   ADDQ, SUBQ, DBcc and TST.
//   ORI, ANDI, SUBI, ADDI, EORI, CMPI, and CLR/NEG/NOT.
//   The Dn-to-<ea> direction of the ALU group, EOR, EXT and SWAP.
//   ASL/ASR, LSL/LSR, ROL/ROR and ROXL/ROXR on a data register.
//   MOVEM, both directions and both sizes.
//   BTST, BCHG, BCLR, BSET (both forms), and Scc.
//   The d8(An,Xn), d16(PC) and d8(PC,Xn) addressing modes.
//   Exceptions: autovectored interrupts, TRAP, RTE, ILLEGAL and lines A and F.
//   MOVE to and from SR and CCR, and ORI/ANDI/EORI to either.
//   MULU, MULS, DIVU and DIVS, with the divide-by-zero exception.
//   ADDX, SUBX, NEGX, CMPM, EXG, PEA, LINK, UNLK and TAS.
//
// Not here, listed rather than left to be discovered: MOVEP, the shifts in their
// one-bit memory form, MOVE USP, CHK and TRAPV, the BCD instructions, the address
// and bus error exceptions, tracing, and the separate user stack pointer. Each
// arrives with its own tests.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module m68k (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,

	// --- the bus -----------------------------------------------------------
	output reg  [23:0] addr,
	input  wire [15:0] din,
	output reg  [15:0] dout,
	output reg         we,
	output reg  [1:0]  ds,          // 11 word, 10 upper byte, 01 lower byte
	output reg         req,

	input  wire [2:0]  ipl_n,       // interrupt level, active low; 7 = none
	// High while an interrupt is being taken, which is what lets whatever asked
	// for it stop asking. The 68000's own acknowledge cycle is a bus access at a
	// magic address; this is the same information without the ceremony.
	output wire        iack,

	// --- for the testbench --------------------------------------------------
	output wire [31:0] dbg_pc,
	output wire [15:0] dbg_ir,
	output wire [15:0] dbg_sr,
	output wire        dbg_halted,
	output wire [31:0] dbg_d0,
	output wire [31:0] dbg_a7
);

	// --- registers ------------------------------------------------------------
	reg [31:0] D [0:7];
	reg [31:0] A [0:7];             // A[7] is the active stack pointer
	reg [31:0] usp_save;            // the inactive one
	reg [31:0] PC;

	reg        T, S;
	reg [2:0]  I;
	reg        X, N, Z, V, C;

	wire [15:0] SR = {T, 1'b0, S, 2'b00, I, 3'b000, X, N, Z, V, C};

	// --- exceptions ---------------------------------------------------------------
	reg [7:0]  exc_vec;             // which vector, as a number not an address
	reg        exc_irq;             // an interrupt, so the mask moves up
	reg [2:0]  exc_lvl;
	reg [15:0] exc_sr;              // the status register as it was BEFORE

	// What the decoder could not decode. Not used by the design; it exists so a
	// testbench can say WHICH instruction a cartridge died on instead of leaving
	// somebody to bisect a megabyte of 68000 code by hand.
	reg [15:0] bad_op;
	reg [31:0] bad_pc;
	reg        bad_hit;

	// The interrupt lines are asynchronous to this clock and are sampled through
	// two flops. Level 7 cannot be masked; every other level has to be strictly
	// above the mask to be heard at all.
	reg [2:0]  ipl_s, ipl_q;
	always @(posedge clk) begin
		ipl_q <= ~ipl_n;
		ipl_s <= ipl_q;
	end
	wire irq_pending = (ipl_s == 3'd7) || (ipl_s > I);

	reg [15:0] ir;
	reg        halted;

	assign dbg_pc     = PC;
	assign dbg_ir     = ir;
	assign dbg_sr     = SR;
	assign dbg_halted = halted;
	assign dbg_d0     = D[0];
	assign dbg_a7     = A[7];

	// --- states ---------------------------------------------------------------
	localparam S_RST0   = 7'd0,  S_RST1   = 7'd1,  S_RST2  = 7'd2,
	           S_RST3   = 7'd3,  S_RST4   = 7'd4,  S_RST5  = 7'd5,
	           S_RST6   = 7'd6,
	           S_FETCH  = 7'd7,  S_FETCH2 = 7'd8,  S_EXEC  = 7'd9,
	           S_EXT    = 7'd10, S_EXT2   = 7'd11,
	           S_EA     = 7'd12, S_EA_E1  = 7'd13, S_EA_E2 = 7'd14,
	           S_EA_GO  = 7'd15,
	           S_RD1    = 7'd16, S_RD2    = 7'd17, S_RD3   = 7'd18,
	           S_RD4    = 7'd19,
	           S_WR1    = 7'd20, S_WR2    = 7'd21,
	           S_MOVE_D = 7'd22, S_MOVE_F = 7'd23,
	           S_BRA    = 7'd24,
	           S_ALU    = 7'd26,
	           S_BRW    = 7'd27, S_BRW2  = 7'd28, S_BRW3  = 7'd29,
	           S_PUSH1  = 7'd30, S_PUSH2 = 7'd31,
	           S_POP1   = 7'd32, S_POP2  = 7'd33, S_POP3  = 7'd34,
	           S_POP4   = 7'd35, S_POP5  = 7'd36,
	           S_JSR    = 7'd37, S_LEA   = 7'd38, S_JSRP  = 7'd39,
	           S_TST    = 7'd40,
	           S_EAW    = 7'd41,
	           S_IMM    = 7'd42, S_IMM1  = 7'd43, S_IMM2  = 7'd44,
	           S_UNOP   = 7'd45, S_SHIFT = 7'd46,
	           S_MMM    = 7'd47, S_MMM1  = 7'd48, S_MMM2  = 7'd49,
	           S_MM     = 7'd50, S_MM_GO = 7'd51, S_MM_W2 = 7'd52,
	           S_MM_R1  = 7'd53, S_MM_R2 = 7'd54, S_MM_R3 = 7'd55,
	           S_MM_R4  = 7'd56, S_BIT   = 7'd57,
	           S_EXC    = 7'd58, S_EXC_SR = 7'd59, S_EXC_V  = 7'd60,
	           S_EXC_V1 = 7'd61, S_EXC_V2 = 7'd62, S_EXC_V3 = 7'd63,
	           S_EXC_V4 = 7'd64,
	           S_RTE    = 7'd65, S_RTE1  = 7'd66, S_RTE2  = 7'd67,
	           S_TOSR   = 7'd68, S_SROP  = 7'd69, S_EXTW  = 7'd70,
	           S_MUL    = 7'd71, S_DIV0  = 7'd72, S_DIV   = 7'd73,
	           S_DIV1   = 7'd74, S_X2ND  = 7'd75, S_PEA   = 7'd76,
	           S_LINK   = 7'd77, S_LINK1 = 7'd78, S_UNLK  = 7'd79,
	           S_TAS    = 7'd80,
	           S_HALT   = 7'd25;

	reg [6:0] st;
	reg [6:0] ea_ret;               // where the resolver returns to

	// High for as long as an interrupt is being taken. Placed here rather than
	// with the other outputs because it reads the state register, which is
	// declared just above -- and xsim, unlike Vivado, refuses a forward
	// reference in a continuous assignment.
	assign iack = (st == S_EXC) && exc_irq;

	// --- what the resolver is doing --------------------------------------------
	reg [2:0]  ea_m, ea_r;
	reg [1:0]  ea_sz;               // 0 byte, 1 word, 2 long
	reg        ea_wr;               // 0 = read into src, 1 = write src out
	reg [31:0] ea_addr;
	reg        ea_second;           // waiting for the low half of a 32-bit ext
	reg        ea_imm;              // ...and it is an immediate, not an address
	reg [31:0] src;
	reg [31:0] tmp;
	reg [15:0] ext;

	// --- the ALU group ----------------------------------------------------------
	localparam AOP_ADD = 3'd0, AOP_SUB = 3'd1, AOP_AND = 3'd2,
	           AOP_OR  = 3'd3, AOP_CMP = 3'd4, AOP_EOR = 3'd5;
	reg [2:0] aop;
	reg       to_an;                // ADDA/SUBA/CMPA: destination is an An
	reg [2:0] areg;                 // which register the result goes to

	// --- control flow -----------------------------------------------------------
	reg       br_take;              // a 16-bit branch: is it actually taken?
	reg       is_dbcc;              // ...or is it the other kind of loop

	// --- read-modify-write ------------------------------------------------------
	// The immediate group and CLR/NEG/NOT all read a destination, change it and
	// put it back where it came from. `imm` holds the literal, `imm_hi` tracks
	// the two halves of a longword one, and `alu_rmw` tells the ALU that its left
	// operand is the value just read rather than a register.
	reg [31:0] imm;
	reg        imm_hi;
	reg        imm_w;               // fetch exactly one word, whatever the size
	reg        imm_only;            // the literal IS the operand; skip the resolver
	reg [2:0]  sr_op;               // which of ORI, ANDI, EORI to the status word
	reg        sr_wide;             // the whole SR, or only the condition codes
	reg [15:0] newsr;

	// --- multiply and divide --------------------------------------------------------
	// Both are 16-bit operations that produce 32 bits. The multiply is one cycle
	// and will land on a DSP slice; the divide is a shift-and-subtract that takes
	// thirty-two, which is still faster than the real part managed.
	reg        md_sign;             // the signed forms, MULS and DIVS
	reg [31:0] dvd;                 // the dividend, becoming the quotient
	reg [16:0] rem;                 // seventeen bits: it is shifted before compare
	reg [15:0] dvr;
	reg [5:0]  dvn;
	reg        q_neg, r_neg;
	reg [31:0] mres;
	// Signed operands need signed declarations, not $signed() inside a ternary:
	// a conditional whose other arm is unsigned makes the WHOLE expression
	// unsigned, and MULS then quietly does what MULU does.
	reg signed [15:0] mula, mulb;
	reg [31:0] qfix, rfix;
	reg        alu_rmw;
	// The extended forms carry the X bit into the operation, and report Z by
	// CLEARING it rather than setting it -- so a multi-word result is zero only
	// if every word of it was.
	reg        alu_x;
	reg        pop_an;              // a popped longword goes to An, not to PC
	localparam UOP_CLR = 2'd0, UOP_NEG = 2'd1, UOP_NOT = 2'd2,
	           UOP_NEGX = 2'd3;
	reg [1:0]  uop;

	// --- the shift group ----------------------------------------------------------
	// One bit per cycle rather than a barrel shifter. The real part takes two
	// clocks per bit anyway, and ASL's overflow flag -- set if the sign bit
	// changes at ANY point during the shift, not just between the ends -- is
	// awkward to get right any other way.
	localparam SH_AS = 2'd0, SH_LS = 2'd1, SH_ROX = 2'd2, SH_RO = 2'd3;
	reg [31:0] shv;                 // the value being shifted
	reg [5:0]  shn;                 // bits left to go
	reg [1:0]  shtype;
	reg        shleft;
	reg        shc;                 // the last bit shifted out
	reg        shov;                // ASL only: did the sign ever change
	reg        shmsb, shmsb1, shin;

	// --- MOVEM --------------------------------------------------------------------
	// One register per pass through S_MM, driven by a mask word that arrives
	// between the opcode and the address's own extension words.
	reg [15:0] mm_mask;
	reg [4:0]  mm_i;                // 0..15, then 16 meaning done
	reg [31:0] mm_addr;             // the next slot to use
	reg [31:0] mm_ea;               // the slot in use, kept for a long's low half
	reg        mm_dir;              // 1 = memory to registers
	reg        mm_long;
	reg        mm_pd;               // the -(An) form, which runs backwards
	reg [31:0] mma;

	// Which register this pass is about. Numbering is D0..D7 then A0..A7, and the
	// -(An) form walks it backwards -- so bit 0 of the mask means A7 there and D0
	// everywhere else. Getting that round the wrong way stores the right number of
	// registers in the wrong order, which a stack frame will not survive.
	wire [3:0]  mm_rn = mm_pd ? (4'd15 - mm_i[3:0]) : mm_i[3:0];
	wire [31:0] mm_rv = mm_rn[3] ? A[mm_rn[2:0]] : D[mm_rn[2:0]];

	// --- the bit instructions -----------------------------------------------------
	// A bit number counts to 32 in a register and to 8 in memory, and wraps
	// rather than faulting -- BSET #9 on a byte in memory sets bit 1.
	localparam BOP_TST = 2'd0, BOP_CHG = 2'd1, BOP_CLR = 2'd2, BOP_SET = 2'd3;
	reg [1:0] bop;
	reg [4:0] bnum;
	reg [4:0] bsel;

	// The index register of a d8(An,Xn) or d8(PC,Xn) address, from the brief
	// extension word: which register, and whether its low half is used sign
	// extended or the whole thing.
	function [31:0] idx;
		input [15:0] w;
		reg   [31:0] r;
		begin
			r   = w[15] ? A[w[14:12]] : D[w[14:12]];
			idx = w[11] ? r : {{16{r[15]}}, r[15:0]};
		end
	endfunction
	reg [6:0] push_ret;             // where a push returns to
	reg       ea_lea;               // resolve the ADDRESS and stop there

	// Which conditions each Bcc tests. Written out rather than derived, because
	// GE/LT/GT/LE are the ones people get wrong and a table can be read against
	// the manual line by line.
	function cond_met;
		input [3:0] cc;
		begin
			case (cc)
			4'h0: cond_met = 1'b1;              // T   (this encoding is BRA)
			4'h1: cond_met = 1'b0;              // F   (this encoding is BSR)
			4'h2: cond_met = !C && !Z;          // HI
			4'h3: cond_met =  C ||  Z;          // LS
			4'h4: cond_met = !C;                // CC / HS
			4'h5: cond_met =  C;                // CS / LO
			4'h6: cond_met = !Z;                // NE
			4'h7: cond_met =  Z;                // EQ
			4'h8: cond_met = !V;                // VC
			4'h9: cond_met =  V;                // VS
			4'hA: cond_met = !N;                // PL
			4'hB: cond_met =  N;                // MI
			4'hC: cond_met = (N == V);          // GE
			4'hD: cond_met = (N != V);          // LT
			4'hE: cond_met = (N == V) && !Z;    // GT
			default: cond_met = (N != V) || Z;  // LE
			endcase
		end
	endfunction

	// Working values for one ALU evaluation. Blocking assignment inside the
	// clocked block, and read nowhere else -- they exist so the flag logic can
	// be written once instead of five times.
	reg [31:0] opa, opb, res;
	reg        cf, vf, ma, mb, mr;

	// --- instruction fields ----------------------------------------------------
	wire [3:0] op   = ir[15:12];
	wire [2:0] rx   = ir[11:9];     // destination register for MOVE
	wire [2:0] dm   = ir[8:6];      // destination mode for MOVE
	wire [2:0] sm   = ir[5:3];      // source mode
	wire [2:0] sr_  = ir[2:0];      // source register

	// MOVE encodes its size differently from everything else, which is a trap
	// worth naming: 01 is BYTE here and 00 is byte everywhere else.
	wire [1:0] move_sz = (ir[13:12] == 2'b01) ? 2'd0 :
	                     (ir[13:12] == 2'b11) ? 2'd1 : 2'd2;

	// How far a postincrement moves. A byte access through A7 moves it by two,
	// not one, because the stack stays word-aligned -- a real 68000 rule and a
	// real source of misaligned stacks when forgotten.
	function [31:0] step;
		input [1:0] size;
		input [2:0] r;
		begin
			step = (size == 2'd2) ? 32'd4
			     : (size == 2'd1) ? 32'd2
			     : (r == 3'd7)    ? 32'd2 : 32'd1;
		end
	endfunction

	integer i;

	// --- starting a resolve -----------------------------------------------------
	task ea_begin;
		input [2:0] m;
		input [2:0] r;
		input [1:0] size;
		input       is_write;
		input [5:0] ret;
		begin
			ea_m   <= m;
			ea_r   <= r;
			ea_sz  <= size;
			ea_wr  <= is_write;
			ea_ret <= ret;
			st     <= S_EA;
		end
	endtask

	always @(posedge clk) begin
		if (rst) begin
			st <= S_RST0; ea_ret <= S_FETCH;
			PC <= 32'd0; usp_save <= 32'd0;
			T <= 1'b0; S <= 1'b1; I <= 3'd7;
			X <= 1'b0; N <= 1'b0; Z <= 1'b0; V <= 1'b0; C <= 1'b0;
			ir <= 16'd0; halted <= 1'b0;
			addr <= 24'd0; dout <= 16'd0; we <= 1'b0; ds <= 2'b11; req <= 1'b0;
			tmp <= 32'd0; ext <= 16'd0; src <= 32'd0; ea_addr <= 32'd0;
			ea_m <= 3'd0; ea_r <= 3'd0; ea_sz <= 2'd1; ea_wr <= 1'b0;
			ea_second <= 1'b0; ea_imm <= 1'b0;
			aop <= 3'd0; to_an <= 1'b0; areg <= 3'd0;
			br_take <= 1'b0; push_ret <= S_FETCH; ea_lea <= 1'b0;
			is_dbcc <= 1'b0;
			imm <= 32'd0; imm_hi <= 1'b0; alu_rmw <= 1'b0; uop <= 2'd0;
			shv <= 32'd0; shn <= 6'd0; shtype <= 2'd0; shleft <= 1'b0;
			shc <= 1'b0; shov <= 1'b0;
			mm_mask <= 16'd0; mm_i <= 5'd0; mm_addr <= 32'd0; mm_ea <= 32'd0;
			mm_dir <= 1'b0; mm_long <= 1'b0; mm_pd <= 1'b0;
			bop <= 2'd0; bnum <= 5'd0; imm_w <= 1'b0;
			exc_vec <= 8'd0; exc_irq <= 1'b0; exc_lvl <= 3'd0; exc_sr <= 16'd0;
			bad_op <= 16'd0; bad_pc <= 32'd0; bad_hit <= 1'b0;
			imm_only <= 1'b0; sr_op <= 3'd0; sr_wide <= 1'b0;
			alu_x <= 1'b0; pop_an <= 1'b0;
			md_sign <= 1'b0; dvd <= 32'd0; rem <= 17'd0; dvr <= 16'd0;
			dvn <= 6'd0; q_neg <= 1'b0; r_neg <= 1'b0;
			for (i = 0; i < 8; i = i + 1) begin D[i] <= 32'd0; A[i] <= 32'd0; end
		end else if (ce) begin
			req <= 1'b0;
			we  <= 1'b0;

			case (st)

			// --- the stack pointer and PC come out of memory -----------------
			S_RST0: begin addr <= 24'h000000; ds <= 2'b11; req <= 1'b1;
			              st <= S_RST1; end
			S_RST1: st <= S_RST2;
			S_RST2: begin tmp[31:16] <= din;
			              addr <= 24'h000002; req <= 1'b1; st <= S_RST3; end
			S_RST3: st <= S_RST4;
			S_RST4: begin A[7] <= {tmp[31:16], din};
			              addr <= 24'h000004; req <= 1'b1; st <= S_RST5; end
			S_RST5: st <= S_RST6;
			S_RST6: begin tmp[31:16] <= din;
			              addr <= 24'h000006; req <= 1'b1; st <= S_BRA; end

			// Shared tail: the second half of a longword that becomes the PC.
			S_BRA: st <= S_MOVE_F;
			S_MOVE_F: begin PC <= {tmp[31:16], din}; st <= S_FETCH; end

			// --- fetch ---------------------------------------------------------
			// An interrupt is taken here and nowhere else: between one
			// instruction and the next, never in the middle of one.
			S_FETCH:
				if (irq_pending) begin
					exc_vec <= 8'd24 + {5'd0, ipl_s};
					exc_irq <= 1'b1;
					exc_lvl <= ipl_s;
					st      <= S_EXC;
				end else begin
					addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
					st   <= S_FETCH2;
				end
			S_FETCH2: st <= S_EXEC;

			S_EXEC: begin
					ir <= din;
					PC <= PC + 32'd2;
					st <= S_FETCH;

					casez (din)
					// MOVEQ -- its own encoding, and the simplest thing that
					// writes a register.
					16'b0111_???0_????_????: begin
						D[din[11:9]] <= {{24{din[7]}}, din[7:0]};
						N <= din[7];
						Z <= (din[7:0] == 8'd0);
						V <= 1'b0; C <= 1'b0;
					end

					16'b0100_1110_0111_0011:                 // RTE
						st <= S_RTE;

					16'b0100_1110_0100_????: begin           // TRAP #n
						exc_vec <= 8'd32 + {4'd0, din[3:0]};
						exc_irq <= 1'b0;
						st      <= S_EXC;
					end

					// The two unassigned opcode lines, which exist so a system can
					// emulate instructions it does not have. The address pushed is
					// the one of the opcode ITSELF, not the one after it -- so PC
					// has to be put back, the fetch above having moved it on.
					16'b1010_????_????_????: begin           // line A
						exc_vec <= 8'd10;
						exc_irq <= 1'b0;
						PC      <= PC;
						st      <= S_EXC;
					end
					16'b1111_????_????_????: begin           // line F
						exc_vec <= 8'd11;
						exc_irq <= 1'b0;
						PC      <= PC;
						st      <= S_EXC;
					end
					16'b0100_1010_1111_1100: begin           // ILLEGAL
						exc_vec <= 8'd4;
						exc_irq <= 1'b0;
						PC      <= PC;
						st      <= S_EXC;
					end

					16'b0100_1110_0111_0001: ;               // NOP

					16'b0100_1110_0111_0010:                 // STOP #imm
						st <= S_EXT;

					// BRA, BSR and the fourteen Bcc, which share one encoding.
					// A displacement of zero does not mean "branch nowhere": it
					// means the real displacement is in the following word.
					16'b0110_????_????_????:
						if (din[11:8] == 4'b0001) begin              // BSR
							if (din[7:0] != 8'd0) begin
								tmp      <= PC + 32'd2;   // return address
								ea_addr  <= PC + 32'd2 + {{24{din[7]}}, din[7:0]};
								push_ret <= S_JSR;
								st       <= S_PUSH1;
							end else begin
								br_take <= 1'b1;
								st      <= S_BRW;
							end
						end else if (din[7:0] != 8'd0) begin         // 8-bit
							if (cond_met(din[11:8]))
								PC <= PC + 32'd2 + {{24{din[7]}}, din[7:0]};
						end else begin                               // 16-bit
							br_take <= cond_met(din[11:8]);
							st      <= S_BRW;
						end

					16'b0100_1110_0111_0101: begin           // RTS
						st <= S_POP1;
					end

					// ORI, ANDI and EORI to the status register or to just the
					// condition codes. These come FIRST because the immediate
					// group below reads their encoding as "destination is a
					// literal", which is not a thing.
					16'b0000_0000_0?11_1100,        // ORI
					16'b0000_0010_0?11_1100,        // ANDI
					16'b0000_1010_0?11_1100: begin  // EORI
						sr_op    <= din[11:9];
						sr_wide  <= din[6];
						imm_w    <= 1'b1;
						imm_only <= 1'b1;
						ea_sz    <= 2'd1;
						ea_ret   <= S_SROP;
						st       <= S_IMM;
					end

					// MOVE to and from SR, and to CCR. All three have a size
					// field of 11, which is what keeps them out of CLR, NEG and
					// NOT -- the same four top bits with a real size.
					16'b0100_0000_11??_????: begin  // MOVE SR,<ea>
						src    <= {16'd0, SR};
						ea_m   <= din[5:3];
						ea_r   <= din[2:0];
						ea_sz  <= 2'd1;
						ea_wr  <= 1'b1;
						ea_ret <= S_FETCH;
						st     <= S_EA;
					end
					16'b0100_0100_11??_????: begin  // MOVE <ea>,CCR
						sr_wide <= 1'b0;
						ea_m    <= din[5:3];
						ea_r    <= din[2:0];
						ea_sz   <= 2'd1;
						ea_wr   <= 1'b0;
						ea_ret  <= S_TOSR;
						st      <= S_EA;
					end
					16'b0100_0110_11??_????: begin  // MOVE <ea>,SR
						sr_wide <= 1'b1;
						ea_m    <= din[5:3];
						ea_r    <= din[2:0];
						ea_sz   <= 2'd1;
						ea_wr   <= 1'b0;
						ea_ret  <= S_TOSR;
						st      <= S_EA;
					end

					// --- the immediate group ---------------------------------
					// ORI, ANDI, SUBI, ADDI, EORI, CMPI. The literal comes
					// first, in the word (or two) after the opcode, and the
					// destination's own extension words come after THAT -- so
					// the immediate has to be fetched before the resolver runs.
					// The same four top bits also carry the static bit
					// instructions and MOVEP, which is why only the six opmodes
					// below are let through.
					16'b0000_???0_????_????:
						// A bit instruction with a static bit number occupies the
						// one opmode the arithmetic immediates do not use -- and
						// in it, bits 7 and 6 are WHICH of the four it is, not a
						// size. Testing them as a size throws BSET away, which
						// then leaves its bit-number word to be run as an opcode.
						if (din[11:9] == 3'd4) begin
							bop    <= din[7:6];
							imm_w  <= 1'b1;
							ea_m   <= din[5:3];
							ea_r   <= din[2:0];
							ea_sz  <= (din[5:3] == 3'b000) ? 2'd2 : 2'd0;
							ea_wr  <= 1'b0;
							ea_ret <= S_BIT;
							st     <= S_IMM;
						end
						else if (din[7:6] != 2'b11
						 && !(din[5:3] == 3'b111 && din[2:0] == 3'b100))
							case (din[11:9])
							3'd0, 3'd1, 3'd2, 3'd3, 3'd5, 3'd6: begin
								aop <= (din[11:9] == 3'd0) ? AOP_OR
								     : (din[11:9] == 3'd1) ? AOP_AND
								     : (din[11:9] == 3'd2) ? AOP_SUB
								     : (din[11:9] == 3'd3) ? AOP_ADD
								     : (din[11:9] == 3'd5) ? AOP_EOR
								                           : AOP_CMP;
								to_an   <= 1'b0;
								alu_rmw <= 1'b1;
								imm_hi  <= 1'b0;
								ea_m    <= din[5:3];
								ea_r    <= din[2:0];
								ea_sz   <= din[7:6];
								ea_wr   <= 1'b0;
								ea_ret  <= S_ALU;
								st      <= S_IMM;
							end
							default: begin
								// Reached by the instructions m68k.v does not
								// implement -- MOVEP here, the BCD group and the
								// one-bit memory shifts below. Silently doing
								// nothing let a cartridge run on past a missing
								// instruction; vector 4 at least stops it at the
								// one that is missing. See the outer default.
								bad_op  <= din;
								bad_pc  <= PC;
								bad_hit <= 1'b1;
								exc_vec <= 8'd4;
								exc_irq <= 1'b0;
								PC      <= PC;
								st      <= S_EXC;
							end
							endcase

					// The same four instructions with the bit number in a
					// register. Mode 001 in this encoding is MOVEP, not a bit
					// instruction -- an address register has no bits to test.
					16'b0000_???1_????_????:
						if (din[5:3] != 3'b001) begin
							bop    <= din[7:6];
							bnum   <= D[din[11:9]][4:0];
							ea_m   <= din[5:3];
							ea_r   <= din[2:0];
							ea_sz  <= (din[5:3] == 3'b000) ? 2'd2 : 2'd0;
							ea_wr  <= 1'b0;
							ea_ret <= S_BIT;
							st     <= S_EA;
						end

					// CLR, NEG and NOT: read, change, put back. A size of 11
					// makes each of them a different instruction entirely
					// (MOVE from SR and friends), so it is excluded here.
					16'b0100_0000_????_????,
					16'b0100_0010_????_????,
					16'b0100_0100_????_????,
					16'b0100_0110_????_????:
						if (din[7:6] != 2'b11) begin
							uop    <= (din[11:8] == 4'b0000) ? UOP_NEGX
							        : (din[11:8] == 4'b0010) ? UOP_CLR
							        : (din[11:8] == 4'b0100) ? UOP_NEG
							                                 : UOP_NOT;
							ea_m   <= din[5:3];
							ea_r   <= din[2:0];
							ea_sz  <= din[7:6];
							ea_wr  <= 1'b0;
							ea_ret <= S_UNOP;
							st     <= S_EA;
						end

					// --- the shift group -------------------------------------
					// The count is either three bits in the opcode (with 0
					// meaning eight) or the low six bits of a register, which is
					// why a shift of 40 is a real thing and 64 is not. A size of
					// 11 is the memory form, which shifts a word in place by one
					// and is not implemented here.
					16'b1110_????_????_????:
						if (din[7:6] != 2'b11) begin
							shleft <= din[8];
							shtype <= din[4:3];
							shn    <= din[5] ? D[din[11:9]][5:0]
							        : (din[11:9] == 3'd0) ? 6'd8
							                              : {3'd0, din[11:9]};
							shv    <= D[din[2:0]];
							shc    <= 1'b0;
							shov   <= 1'b0;
							ea_sz  <= din[7:6];
							ea_m   <= 3'b000;
							ea_r   <= din[2:0];
							st     <= S_SHIFT;
						end

					// SWAP and EXT. All three live inside MOVEM's and PEA's
					// encodings and are told apart from them by the mode field
					// being 000 -- a register, which those two cannot address.
					16'b0100_1110_0101_0???: begin           // LINK An,#d
						areg     <= din[2:0];
						imm_w    <= 1'b1;
						imm_only <= 1'b1;
						ea_sz    <= 2'd1;
						ea_ret   <= S_LINK;
						st       <= S_IMM;
					end
					16'b0100_1110_0101_1???: begin           // UNLK An
						areg <= din[2:0];
						st   <= S_UNLK;
					end

					16'b0100_1000_01??_????:
						if (din[5:3] != 3'b000) begin           // PEA <ea>
							ea_m   <= din[5:3];
							ea_r   <= din[2:0];
							ea_sz  <= 2'd2;
							ea_wr  <= 1'b0;
							ea_lea <= 1'b1;
							ea_ret <= S_PEA;
							st     <= S_EA;
						end else begin                          // SWAP Dn
							D[din[2:0]] <= {D[din[2:0]][15:0],
							                D[din[2:0]][31:16]};
							N <= D[din[2:0]][15];
							Z <= (D[din[2:0]] == 32'd0);
							V <= 1'b0; C <= 1'b0;
						end
					// MOVEM, both directions. The to-memory form shares its
					// encoding with EXT and is told apart by the mode field.
					16'b0100_1100_1???_????: begin
						mm_dir  <= 1'b1;
						mm_long <= din[6];
						mm_pd   <= 1'b0;        // (An)+ walks forwards
						ea_m    <= din[5:3];
						ea_r    <= din[2:0];
						ea_sz   <= din[6] ? 2'd2 : 2'd1;
						st      <= S_MMM;
					end

					16'b0100_1000_1???_????:
						// Bit 7 is already pinned by the pattern, so the size bit
						// is bit 6 alone -- EXT.L's opmode is 011, and a check for
						// "not 11" here would throw it away.
						if (din[5:3] != 3'b000) begin           // MOVEM to memory
							mm_dir  <= 1'b0;
							mm_long <= din[6];
							mm_pd   <= (din[5:3] == 3'b100);
							ea_m    <= din[5:3];
							ea_r    <= din[2:0];
							ea_sz   <= din[6] ? 2'd2 : 2'd1;
							st      <= S_MMM;
						end else begin
							// EXT.W takes a byte up to a word, EXT.L a word up to
							// a longword. The flags describe the RESULT's width,
							// which is why they are written out twice.
							if (din[6] == 1'b0) begin           // EXT.W
								D[din[2:0]][15:0] <= {{8{D[din[2:0]][7]}},
								                      D[din[2:0]][7:0]};
								N <= D[din[2:0]][7];
								Z <= (D[din[2:0]][7:0] == 8'd0);
							end else begin                      // EXT.L
								D[din[2:0]] <= {{16{D[din[2:0]][15]}},
								                D[din[2:0]][15:0]};
								N <= D[din[2:0]][15];
								Z <= (D[din[2:0]][15:0] == 16'd0);
							end
							V <= 1'b0; C <= 1'b0;
						end

					// TST: read it, judge it, keep nothing.
					// A size of 11 here is TAS, which is TST plus a bit set --
					// the 68000's one indivisible read-modify-write.
					16'b0100_1010_????_????: begin
						ea_m   <= din[5:3];
						ea_r   <= din[2:0];
						ea_sz  <= (din[7:6] == 2'b11) ? 2'd0 : din[7:6];
						ea_wr  <= 1'b0;
						ea_ret <= (din[7:6] == 2'b11) ? S_TAS : S_TST;
						st     <= S_EA;
					end

					// DBcc and Scc share the encoding ADDQ/SUBQ would have used
					// with a size of 11, which is why this has to come first.
					16'b0101_????_11??_????:
						if (din[5:3] == 3'b001) begin      // DBcc
							is_dbcc <= 1'b1;
							br_take <= 1'b1;               // decided in S_BRW3
							st      <= S_BRW;
						end else begin                     // Scc
							// All ones or all zeroes, never 1 and 0 -- which is
							// why a true Scc result is $FF and tests against it
							// with a signed compare come out negative.
							src    <= cond_met(din[11:8]) ? 32'hFFFFFFFF : 32'd0;
							ea_m   <= din[5:3];
							ea_r   <= din[2:0];
							ea_sz  <= 2'd0;
							ea_wr  <= 1'b1;
							ea_ret <= S_FETCH;
							st     <= S_EA;
						end

					// ADDQ and SUBQ. The value 0 in the data field means eight,
					// which is the only way to encode it -- a quick add of zero
					// would be pointless and the encoding space is precious.
					16'b0101_????_????_????:
						if (din[5:3] == 3'b000 || din[5:3] == 3'b001) begin
							aop     <= din[8] ? AOP_SUB : AOP_ADD;
							to_an   <= (din[5:3] == 3'b001);
							areg    <= din[2:0];
							alu_rmw <= 1'b0;
							alu_x   <= 1'b0;
							// An address register takes the whole 32 bits and
							// sets no flags, whatever size the instruction says.
							ea_sz <= (din[5:3] == 3'b001) ? 2'd2 : din[7:6];
							src   <= (din[11:9] == 3'd0) ? 32'd8
							                             : {29'd0, din[11:9]};
							st    <= S_ALU;
						end else begin
							// The destination can also be memory, which makes it
							// a read-modify-write like ADDI -- with the literal
							// coming out of the opcode instead of a word after it.
							aop     <= din[8] ? AOP_SUB : AOP_ADD;
							to_an   <= 1'b0;
							alu_rmw <= 1'b1;
							alu_x   <= 1'b0;
							imm     <= (din[11:9] == 3'd0) ? 32'd8
							                               : {29'd0, din[11:9]};
							ea_m    <= din[5:3];
							ea_r    <= din[2:0];
							ea_sz   <= din[7:6];
							ea_wr   <= 1'b0;
							ea_ret  <= S_ALU;
							st      <= S_EA;
						end

					// JMP and JSR: the same effective address, one of them
					// remembering where it came from.
					16'b0100_1110_11??_????: begin           // JMP <ea>
						ea_m   <= din[5:3];
						ea_r   <= din[2:0];
						ea_sz  <= 2'd2;
						ea_wr  <= 1'b0;
						ea_lea <= 1'b1;
						ea_ret <= S_LEA;
						st     <= S_EA;
					end
					16'b0100_1110_10??_????: begin           // JSR <ea>
						ea_m   <= din[5:3];
						ea_r   <= din[2:0];
						ea_sz  <= 2'd2;
						ea_wr  <= 1'b0;
						ea_lea <= 1'b1;
						// Not S_JSR: that is where BSR lands, and BSR has
						// already pushed by the time it gets there. JSR has to
						// push FIRST, and the return address is only known once
						// the address mode's extension words have been read.
						ea_ret <= S_JSRP;
						st     <= S_EA;
					end

					// LEA <ea>,An -- the address itself, never what is at it.
					16'b0100_???1_11??_????: begin
						areg   <= din[11:9];
						ea_m   <= din[5:3];
						ea_r   <= din[2:0];
						ea_sz  <= 2'd2;
						ea_wr  <= 1'b0;
						ea_lea <= 1'b1;
						ea_ret <= S_LEA;
						st     <= S_EA;
					end

					// MOVE and MOVEA, in all three sizes. Spelled out as three
					// patterns rather than one with a wildcard, because the size
					// field here is 01 byte, 11 word, 10 LONG -- not a counting
					// order, and any single mask over it either misses long or
					// catches $0xxx, which is a different instruction group
					// entirely.
					16'b0001_????_????_????,       // MOVE.B
					16'b0011_????_????_????,       // MOVE.W
					16'b0010_????_????_????: begin // MOVE.L
						// The source is resolved first, then the destination.
						// Order matters: -(An) on the source side must decrement
						// before the destination is touched.
						ea_m   <= din[5:3];
						ea_r   <= din[2:0];
						ea_sz  <= (din[13:12] == 2'b01) ? 2'd0 :
						          (din[13:12] == 2'b11) ? 2'd1 : 2'd2;
						ea_wr  <= 1'b0;
						ea_ret <= S_MOVE_D;
						st     <= S_EA;
					end

					// --- the ALU group ---------------------------------------
					// ADD, SUB, AND, OR, CMP and their address-register forms.
					// Matched as whole opcode groups and then sorted by opmode,
					// because the same four top bits also carry MULU, DIVU, ABCD
					// and EXG -- which is why the opmode check below is an
					// allow-list and everything else falls through to nothing.
					16'b1101_????_????_????,        // ADD / ADDA
					16'b1001_????_????_????,        // SUB / SUBA
					16'b1011_????_????_????,        // CMP / CMPA
					16'b1100_????_????_????,        // AND
					16'b1000_????_????_????:        // OR
						case (din[8:6])
						3'b000, 3'b001, 3'b010: begin   // <ea> op Dn -> Dn
							aop <= (din[15:12] == 4'b1101) ? AOP_ADD
							     : (din[15:12] == 4'b1001) ? AOP_SUB
							     : (din[15:12] == 4'b1011) ? AOP_CMP
							     : (din[15:12] == 4'b1100) ? AOP_AND
							                               : AOP_OR;
							to_an  <= 1'b0;
							areg   <= din[11:9];
							ea_m   <= din[5:3];
							ea_r   <= din[2:0];
							ea_sz  <= din[7:6];
							ea_wr  <= 1'b0;
							ea_ret <= S_ALU;
							st     <= S_EA;
						end
						3'b011, 3'b111:
							// In this opmode 1100 and 1000 are MULU and DIVU,
							// which are not the same instruction at all.
							if (din[15:12] == 4'b1100
							 || din[15:12] == 4'b1000) begin
								areg    <= din[11:9];
								md_sign <= din[8];   // opmode 111 is the signed one
								ea_m    <= din[5:3];
								ea_r    <= din[2:0];
								ea_sz   <= 2'd1;
								ea_wr   <= 1'b0;
								ea_ret  <= (din[15:12] == 4'b1100) ? S_MUL
								                                   : S_DIV0;
								st      <= S_EA;
							end
							else if (din[15:12] == 4'b1101 || din[15:12] == 4'b1001
							 || din[15:12] == 4'b1011) begin
								aop <= (din[15:12] == 4'b1101) ? AOP_ADD
								     : (din[15:12] == 4'b1001) ? AOP_SUB
								                               : AOP_CMP;
								to_an  <= 1'b1;
								areg   <= din[11:9];
								ea_m   <= din[5:3];
								ea_r   <= din[2:0];
								ea_sz  <= din[8] ? 2'd2 : 2'd1;
								ea_wr  <= 1'b0;
								ea_ret <= S_ALU;
								st     <= S_EA;
							end
						// The other direction: the memory operand is the one
						// that changes, and the register is the right-hand side.
						// It reuses the read-modify-write path by simply putting
						// the register's value where an immediate would go.
						//
						// A destination of Dn or An in this direction is not this
						// instruction at all -- it is ADDX, SUBX, ABCD, SBCD or
						// EXG -- except for EOR, which has no other direction and
						// so keeps Dn for itself.
						// ADDX and SUBX. Their encodings are exactly the ones
						// the Dn-to-<ea> direction cannot use, a destination of
						// Dn or An, which is how they fit.
						3'b100, 3'b101, 3'b110:
							if (din[5:4] == 2'b00
							 && (din[15:12] == 4'b1101
							  || din[15:12] == 4'b1001)) begin
								aop   <= (din[15:12] == 4'b1101) ? AOP_ADD
								                                 : AOP_SUB;
								to_an <= 1'b0;
								alu_x <= 1'b1;
								areg  <= din[11:9];
								ea_sz <= din[7:6];
								if (din[3]) begin           // -(Ay),-(Ax)
									ea_m   <= 3'b100;
									ea_r   <= din[2:0];
									ea_wr  <= 1'b0;
									ea_ret <= S_X2ND;
									st     <= S_EA;
								end else begin              // Dy,Dx
									alu_rmw <= 1'b0;
									src     <= D[din[2:0]];
									st      <= S_ALU;
								end
							end
							// CMPM: the one compare that walks two pointers.
							else if (din[15:12] == 4'b1011
							      && din[5:3] == 3'b001) begin
								aop    <= AOP_CMP;
								to_an  <= 1'b0;
								alu_x  <= 1'b0;
								areg   <= din[11:9];
								ea_sz  <= din[7:6];
								ea_m   <= 3'b011;           // (Ay)+
								ea_r   <= din[2:0];
								ea_wr  <= 1'b0;
								ea_ret <= S_X2ND;
								st     <= S_EA;
							end
							// EXG, which is not an arithmetic instruction at all
							// and only lives here because the encoding was free.
							else if (din[15:12] == 4'b1100
							      && (din[7:3] == 5'b01000
							       || din[7:3] == 5'b01001
							       || din[7:3] == 5'b10001)) begin
								case (din[7:3])
								5'b01000: begin
									D[din[11:9]] <= D[din[2:0]];
									D[din[2:0]]  <= D[din[11:9]];
								end
								5'b01001: begin
									A[din[11:9]] <= A[din[2:0]];
									A[din[2:0]]  <= A[din[11:9]];
								end
								default: begin              // Dx <-> Ay
									D[din[11:9]] <= A[din[2:0]];
									A[din[2:0]]  <= D[din[11:9]];
								end
								endcase
							end
							else if (din[15:12] == 4'b1011
							     ? (din[5:3] != 3'b001)          // not CMPM
							     : (din[5:3] != 3'b000 && din[5:3] != 3'b001))
							begin
								aop <= (din[15:12] == 4'b1101) ? AOP_ADD
								     : (din[15:12] == 4'b1001) ? AOP_SUB
								     : (din[15:12] == 4'b1011) ? AOP_EOR
								     : (din[15:12] == 4'b1100) ? AOP_AND
								                               : AOP_OR;
								to_an   <= 1'b0;
								alu_rmw <= 1'b1;
								imm     <= D[din[11:9]];
								ea_m    <= din[5:3];
								ea_r    <= din[2:0];
								ea_sz   <= din[7:6];
								ea_wr   <= 1'b0;
								ea_ret  <= S_ALU;
								st      <= S_EA;
							end

						default: begin
							bad_op  <= din;
							bad_pc  <= PC;
							bad_hit <= 1'b1;
							exc_vec <= 8'd4;
							exc_irq <= 1'b0;
							PC      <= PC;
							st      <= S_EXC;
						end
						endcase

					// Anything the decoder does not recognise.
					//
					// This was `;` -- a silent NOP. That is the worst answer
					// available: the program keeps running with one instruction
					// quietly missing, drifts for thousands of cycles, and dies
					// somewhere else entirely with nothing pointing back here. A
					// commercial cartridge hitting one unimplemented opcode looks
					// exactly like a broken VDP, a broken cache or a broken
					// memory controller, and every one of those gets suspected
					// first because they are the parts that were changed last.
					//
					// A real 68000 raises vector 4 here, and a cartridge's own
					// handler at least stops somewhere findable. PC is held so
					// the stacked address points AT the instruction, not past it.
					default: begin
						bad_op  <= din;
						bad_pc  <= PC;
						bad_hit <= 1'b1;
						exc_vec <= 8'd4;
						exc_irq <= 1'b0;
						PC      <= PC;
						st      <= S_EXC;
					end
					endcase
				end

			// --- the ALU ----------------------------------------------------------
			// One evaluation, sized three ways. The flags are the point: half of
			// what goes wrong in a 68000 is X, N, Z, V and C after an operation
			// that produced the right number, and a test that only checks the
			// number passes anyway.
			S_ALU: begin
					st      <= S_FETCH;
					alu_rmw <= 1'b0;
					alu_x   <= 1'b0;

					// Two shapes share this state. In the register direction the
					// left operand is a register and the right one came from the
					// effective address. In the immediate direction it is the
					// other way round: the value read from the address is what
					// gets changed, and the literal is the right operand.
					//
					// An address register takes the whole 32 bits whatever the
					// operation size, so a word operand is SIGN extended first.
					// Zero extending here is a bug that only shows up with
					// negative displacements.
					opb = alu_rmw ? imm
					    : (to_an && ea_sz == 2'd1)
					      ? {{16{src[15]}}, src[15:0]} : src;
					opa = alu_rmw ? src : (to_an ? A[areg] : D[areg]);

					if (to_an) begin
						case (aop)
						AOP_ADD: A[areg] <= opa + opb;
						AOP_SUB: A[areg] <= opa - opb;
						default: begin                  // CMPA
							{cf, res} = {1'b0, opa} - {1'b0, opb};
							N <= res[31];
							Z <= (res == 32'd0);
							C <= cf;
							V <= (opa[31] != opb[31]) && (res[31] != opa[31]);
						end
						endcase
						// ADDA and SUBA set NO flags at all. That is not an
						// omission: address arithmetic is not supposed to
						// disturb a condition being tested around it.
					end else begin
						case (ea_sz)
						2'd0: begin ma = opa[7];  mb = opb[7];  end
						2'd1: begin ma = opa[15]; mb = opb[15]; end
						default: begin ma = opa[31]; mb = opb[31]; end
						endcase

						case (aop)
						AOP_ADD: case (ea_sz)
							2'd0: {cf, res[7:0]}   = opa[7:0]  + opb[7:0]
							                       + (alu_x ? X : 1'b0);
							2'd1: {cf, res[15:0]}  = opa[15:0] + opb[15:0]
							                       + (alu_x ? X : 1'b0);
							default: {cf, res}     = {1'b0, opa} + {1'b0, opb}
							                       + (alu_x ? X : 1'b0);
							endcase
						AOP_SUB, AOP_CMP: case (ea_sz)
							2'd0: {cf, res[7:0]}   = opa[7:0]  - opb[7:0]
							                       - (alu_x ? X : 1'b0);
							2'd1: {cf, res[15:0]}  = opa[15:0] - opb[15:0]
							                       - (alu_x ? X : 1'b0);
							default: {cf, res}     = {1'b0, opa} - {1'b0, opb}
							                       - (alu_x ? X : 1'b0);
							endcase
						AOP_AND: begin res = opa & opb; cf = 1'b0; end
						AOP_EOR: begin res = opa ^ opb; cf = 1'b0; end
						default: begin res = opa | opb; cf = 1'b0; end
						endcase

						case (ea_sz)
						2'd0: mr = res[7];
						2'd1: mr = res[15];
						default: mr = res[31];
						endcase

						// Overflow: for an add, when both operands agree in sign
						// and the result does not. For a subtract, when they
						// disagree and the result does not match the first.
						vf = (aop == AOP_ADD) ? ((ma == mb) && (mr != ma))
						   : (aop == AOP_SUB || aop == AOP_CMP)
						     ? ((ma != mb) && (mr != ma))
						     : 1'b0;

						N <= mr;
						// ADDX and SUBX clear Z when the result is non-zero and
						// otherwise leave it, so that a chain of them ends with Z
						// meaning "all of the words were zero".
						case (ea_sz)
						2'd0: if (res[7:0]  != 8'd0)  Z <= 1'b0;
						      else if (!alu_x)        Z <= 1'b1;
						2'd1: if (res[15:0] != 16'd0) Z <= 1'b0;
						      else if (!alu_x)        Z <= 1'b1;
						default: if (res != 32'd0)    Z <= 1'b0;
						      else if (!alu_x)        Z <= 1'b1;
						endcase
						V <= vf;
						C <= (aop == AOP_ADD || aop == AOP_SUB
						   || aop == AOP_CMP) ? cf : 1'b0;
						// X follows C, but only for arithmetic. A compare and a
						// logic operation leave it alone, which is what makes
						// multi-word arithmetic work across them.
						if (aop == AOP_ADD || aop == AOP_SUB) X <= cf;

						// A compare keeps its result to itself.
						if (aop != AOP_CMP) begin
							if (alu_rmw) begin
								src <= res;
								st  <= S_EAW;
							end else case (ea_sz)
								2'd0: D[areg][7:0]  <= res[7:0];
								2'd1: D[areg][15:0] <= res[15:0];
								default: D[areg]    <= res;
							endcase
						end
					end
				end

			// --- the immediate word, or two of them ------------------------------
			// This runs BEFORE the effective address resolver, because that is
			// the order the words sit in memory: opcode, literal, then whatever
			// extension words the destination needs.
			S_IMM:  begin addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
			              st <= S_IMM1; end
			S_IMM1: st <= S_IMM2;
			S_IMM2: begin
					PC <= PC + 32'd2;
					// The bit instructions carry their bit number in a word of
					// their own, whatever size the destination turns out to be.
					bnum <= din[4:0];
					if (imm_hi) begin
						imm[15:0] <= din;
						imm_hi    <= 1'b0;
						st        <= imm_only ? ea_ret : S_EA;
						imm_only  <= 1'b0;
					end else if (ea_sz == 2'd2 && !imm_w) begin
						imm[31:16] <= din;
						imm_hi     <= 1'b1;
						addr <= PC[23:0] + 24'd2; ds <= 2'b11; req <= 1'b1;
						st   <= S_IMM1;
					end else begin
						// A byte immediate occupies a whole word, with the value
						// in the low half and the high half ignored.
						imm <= (ea_sz == 2'd0 && !imm_w) ? {{24{din[7]}}, din[7:0]}
						                                 : {{16{din[15]}}, din};
						imm_w    <= 1'b0;
						imm_only <= 1'b0;
						st       <= imm_only ? ea_ret : S_EA;
					end
				end

			// --- put it back where it came from ----------------------------------
			// The address is still in ea_addr and any (An)+ or -(An) side effect
			// has already happened, so this re-enters the resolver halfway: at
			// the access, not at the address computation. Doing it again would
			// step the register a second time.
			S_EAW: begin
					ea_wr  <= 1'b1;
					ea_ret <= S_FETCH;
					case (ea_m)
					3'b000: begin
						case (ea_sz)
						2'd0: D[ea_r][7:0]  <= src[7:0];
						2'd1: D[ea_r][15:0] <= src[15:0];
						default: D[ea_r]    <= src;
						endcase
						st <= S_FETCH;
					end
					3'b001: begin
						A[ea_r] <= (ea_sz == 2'd1)
						           ? {{16{src[15]}}, src[15:0]} : src;
						st <= S_FETCH;
					end
					default: st <= S_EA_GO;
					endcase
				end

			// --- CLR, NEG and NOT --------------------------------------------------
			S_UNOP: begin
					case (ea_sz)
					2'd0: mb = src[7];
					2'd1: mb = src[15];
					default: mb = src[31];
					endcase

					case (uop)
					UOP_CLR: res = 32'd0;
					UOP_NOT: res = ~src;
					UOP_NEG: case (ea_sz)
						2'd0: {cf, res[7:0]}  = 8'd0  - src[7:0];
						2'd1: {cf, res[15:0]} = 16'd0 - src[15:0];
						default: {cf, res}    = 33'd0 - {1'b0, src};
						endcase
					default: case (ea_sz)          // NEGX
						2'd0: {cf, res[7:0]}  = 8'd0  - src[7:0]  - X;
						2'd1: {cf, res[15:0]} = 16'd0 - src[15:0] - X;
						default: {cf, res}    = 33'd0 - {1'b0, src} - X;
						endcase
					endcase

					case (ea_sz)
					2'd0: mr = res[7];
					2'd1: mr = res[15];
					default: mr = res[31];
					endcase

					N <= (uop == UOP_CLR) ? 1'b0 : mr;
					// NEGX follows the extended rule: it can only ever clear Z.
					case (ea_sz)
					2'd0: if (uop == UOP_NEGX) begin
					          if (res[7:0]  != 8'd0)  Z <= 1'b0; end
					      else Z <= (uop == UOP_CLR) || (res[7:0]  == 8'd0);
					2'd1: if (uop == UOP_NEGX) begin
					          if (res[15:0] != 16'd0) Z <= 1'b0; end
					      else Z <= (uop == UOP_CLR) || (res[15:0] == 16'd0);
					default: if (uop == UOP_NEGX) begin
					          if (res != 32'd0)       Z <= 1'b0; end
					      else Z <= (uop == UOP_CLR) || (res == 32'd0);
					endcase
					V <= 1'b0;
					C <= 1'b0;

					if (uop == UOP_NEG || uop == UOP_NEGX) begin
						// Negating the most negative number cannot be done in the
						// same width, and that is the only case V is set. The
						// borrow out is simply "the operand was not zero", and X
						// follows it so NEGX can chain.
						V <= mb && mr;
						C <= cf;
						X <= cf;
					end

					src <= res;
					st  <= S_EAW;
				end

			// --- one extension word, for the instructions that just want one ----
			// Three states, not two: issue, wait, capture. The memory answers
			// one enable after the address, exactly as it does for a fetch, and
			// reading din a cycle early gets the PREVIOUS word -- which for STOP
			// is its own opcode, quietly loaded into the status register.
			S_EXT:  begin addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
			              st <= S_EXTW; end
			S_EXTW: st <= S_EXT2;
			S_EXT2: begin
					ext <= din;
					if (ir[15:8] == 8'h60) PC <= PC + {{16{din[15]}}, din};
					else                   PC <= PC + 32'd2;
					// STOP's operand is not decoration: it becomes the status
					// register, and setting the interrupt mask there is how a
					// program says which interrupt it is waiting for.
					if (ir == 16'b0100_1110_0111_0010) begin
						T <= din[15];
						S <= din[13];
						I <= din[10:8];
						X <= din[4];
						N <= din[3];
						Z <= din[2];
						V <= din[1];
						C <= din[0];
						st <= S_HALT;
					end else
						st <= S_FETCH;
				end

			// --- the effective address resolver ---------------------------------
			S_EA: case (ea_m)
				3'b000: begin                       // Dn
						if (!ea_wr) src <= D[ea_r];
						else case (ea_sz)
							2'd0: D[ea_r][7:0]  <= src[7:0];
							2'd1: D[ea_r][15:0] <= src[15:0];
							default: D[ea_r]    <= src;
						endcase
						st <= ea_ret;
					end
				3'b001: begin                       // An -- always full width
						if (!ea_wr) src <= A[ea_r];
						else A[ea_r] <= (ea_sz == 2'd1)
						                ? {{16{src[15]}}, src[15:0]} : src;
						st <= ea_ret;
					end
				3'b010: begin ea_addr <= A[ea_r]; st <= S_EA_GO; end
				3'b011: begin                       // (An)+
						ea_addr <= A[ea_r];
						A[ea_r] <= A[ea_r] + step(ea_sz, ea_r);
						st <= S_EA_GO;
					end
				3'b100: begin                       // -(An)
						ea_addr <= A[ea_r] - step(ea_sz, ea_r);
						A[ea_r] <= A[ea_r] - step(ea_sz, ea_r);
						st <= S_EA_GO;
					end
				3'b101: begin addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
				              st <= S_EA_E1; end    // d16(An)
				default: begin                      // the 111 family
						addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
						st <= S_EA_E1;
					end
				endcase

			S_EA_E1: st <= S_EA_E2;
			S_EA_E2: begin
					// PC moves on nonblockingly, so within this cycle PC is still
					// pointing at the word that just arrived and the NEXT one is
					// at PC+2. Every address computed here has to say so.
					PC <= PC + 32'd2;

					if (ea_second) begin
						// The low half of a 32-bit extension, whichever kind.
						ea_second <= 1'b0;
						if (ea_imm) begin
							src <= {tmp[31:16], din};
							st  <= ea_ret;
						end else begin
							ea_addr <= {tmp[31:16], din};
							st      <= S_EA_GO;
						end
					end else if (ea_m == 3'b101) begin           // d16(An)
						ea_addr <= A[ea_r] + {{16{din[15]}}, din};
						st <= S_EA_GO;
					end else if (ea_m == 3'b110) begin           // d8(An,Xn)
						ea_addr <= A[ea_r] + {{24{din[7]}}, din[7:0]}
						                   + idx(din);
						st <= S_EA_GO;
					end else case (ea_r)
						3'b000: begin                            // (xxx).W
							// Sign extended, not zero extended: $FFFF means the
							// top of the address space, not address 65535.
							ea_addr <= {{16{din[15]}}, din};
							st <= S_EA_GO;
						end
						3'b001: begin                            // (xxx).L
							tmp       <= {din, 16'd0};
							ea_second <= 1'b1;
							ea_imm    <= 1'b0;
							addr <= PC[23:0] + 24'd2; ds <= 2'b11; req <= 1'b1;
							st   <= S_EA_E1;
						end
						// The two PC-relative modes. The displacement counts
						// from the address of THIS extension word, which is where
						// PC still points -- it moves on nonblockingly above.
						3'b010: begin                            // d16(PC)
							ea_addr <= PC + {{16{din[15]}}, din};
							st <= S_EA_GO;
						end
						3'b011: begin                            // d8(PC,Xn)
							ea_addr <= PC + {{24{din[7]}}, din[7:0]}
							              + idx(din);
							st <= S_EA_GO;
						end
						3'b100:                                  // #imm
							if (ea_sz == 2'd2) begin
								tmp       <= {din, 16'd0};
								ea_second <= 1'b1;
								ea_imm    <= 1'b1;
								addr <= PC[23:0] + 24'd2; ds <= 2'b11;
								req  <= 1'b1;
								st   <= S_EA_E1;
							end else begin
								src <= (ea_sz == 2'd0)
								       ? {{24{din[7]}}, din[7:0]}
								       : {{16{din[15]}}, din};
								st <= ea_ret;
							end
						default: st <= ea_ret;
					endcase
				end

			S_EA_GO: begin
					// LEA, JMP and JSR want the address and nothing else. Reading
					// what is at it would be wrong AND would fault on an odd one.
					if (ea_lea) begin
						st <= ea_ret;
					end else if (ea_wr) begin
						addr <= ea_addr[23:0];
						if (ea_sz == 2'd0) begin
							ds   <= ea_addr[0] ? 2'b01 : 2'b10;
							dout <= {src[7:0], src[7:0]};
						end else begin
							ds   <= 2'b11;
							dout <= (ea_sz == 2'd2) ? src[31:16] : src[15:0];
						end
						we  <= 1'b1;
						req <= 1'b1;
						st  <= (ea_sz == 2'd2) ? S_WR1 : ea_ret;
					end else begin
						addr <= ea_addr[23:0];
						ds   <= (ea_sz == 2'd0) ? (ea_addr[0] ? 2'b01 : 2'b10)
						                        : 2'b11;
						req  <= 1'b1;
						st   <= S_RD1;
					end
				end

			// The low half of a longword write.
			S_WR1: begin
					addr <= ea_addr[23:0] + 24'd2;
					ds   <= 2'b11;
					dout <= src[15:0];
					we   <= 1'b1;
					req  <= 1'b1;
					st   <= ea_ret;
				end

			S_RD1: st <= S_RD2;
			S_RD2: begin
					if (ea_sz == 2'd2) begin
						tmp  <= {din, 16'd0};
						addr <= ea_addr[23:0] + 24'd2;
						ds   <= 2'b11;
						req  <= 1'b1;
						st   <= S_RD3;
					end else begin
						src <= (ea_sz == 2'd0)
						       ? {24'd0, (ea_addr[0] ? din[7:0] : din[15:8])}
						       : {16'd0, din};
						st <= ea_ret;
					end
				end
			S_RD3: st <= S_RD4;
			S_RD4: begin src <= {tmp[31:16], din}; st <= ea_ret; end

			// --- MOVE: the source is in `src`, now place it -----------------------
			S_MOVE_D: begin
					// Flags come from the value moved, and MOVEA sets none at
					// all -- which is exactly why it is a separate mnemonic.
					if (dm != 3'b001) begin
						case (ea_sz)
						2'd0: begin N <= src[7];  Z <= (src[7:0]  == 8'd0);  end
						2'd1: begin N <= src[15]; Z <= (src[15:0] == 16'd0); end
						default: begin N <= src[31]; Z <= (src == 32'd0);    end
						endcase
						V <= 1'b0; C <= 1'b0;
					end
					ea_m   <= dm;
					ea_r   <= rx;
					ea_wr  <= 1'b1;
					ea_ret <= S_FETCH;
					st     <= S_EA;
				end

			// --- a 16-bit branch displacement ---------------------------------
			S_BRW:  begin addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
			              st <= S_BRW2; end
			S_BRW2: st <= S_BRW3;
			S_BRW3: begin
					// DBcc is a loop, not a branch: it falls through when its
					// condition becomes TRUE, and otherwise counts a register
					// down and goes round again. The counter is sixteen bits and
					// the loop ends at -1, not at zero -- so a count of n runs
					// n+1 times, which is the classic off-by-one here.
					if (is_dbcc) begin
						is_dbcc <= 1'b0;
						st      <= S_FETCH;
						if (cond_met(ir[11:8])) begin
							PC <= PC + 32'd2;
						end else begin
							D[ir[2:0]][15:0] <= D[ir[2:0]][15:0] - 16'd1;
							if (D[ir[2:0]][15:0] != 16'd0)
								PC <= PC + {{16{din[15]}}, din};
							else
								PC <= PC + 32'd2;
						end
					end
					// Taken: the target is measured from the word AFTER the
					// opcode, which is where PC already points. Not taken: step
					// over the displacement word.
					else if (br_take) begin
						if (ir[11:8] == 4'b0001) begin      // BSR.W
							tmp      <= PC + 32'd2;
							ea_addr  <= PC + {{16{din[15]}}, din};
							push_ret <= S_JSR;
							st       <= S_PUSH1;
						end else begin
							PC <= PC + {{16{din[15]}}, din};
							st <= S_FETCH;
						end
					end else begin
						PC <= PC + 32'd2;
						st <= S_FETCH;
					end
				end

			// --- push and pop a longword ---------------------------------------
			// The 68000 stack grows down and a return address is four bytes, so
			// this is two word writes to a stack pointer that has already moved.
			S_PUSH1: begin
					A[7] <= A[7] - 32'd4;
					addr <= A[7] - 32'd4;
					ds   <= 2'b11;
					dout <= tmp[31:16];
					we   <= 1'b1;
					req  <= 1'b1;
					st   <= S_PUSH2;
				end
			S_PUSH2: begin
					addr <= A[7] + 32'd2;    // A[7] is the new value by now
					ds   <= 2'b11;
					dout <= tmp[15:0];
					we   <= 1'b1;
					req  <= 1'b1;
					st   <= push_ret;
				end

			S_POP1: begin addr <= A[7][23:0]; ds <= 2'b11; req <= 1'b1;
			              st <= S_POP2; end
			S_POP2: st <= S_POP3;
			S_POP3: begin
					tmp[31:16] <= din;
					addr <= A[7][23:0] + 24'd2; ds <= 2'b11; req <= 1'b1;
					st <= S_POP4;
				end
			S_POP4: st <= S_POP5;
			S_POP5: begin
					// RTS and RTE want a return address; UNLK wants the old frame
					// pointer. Same four bytes off the same stack.
					if (pop_an) A[areg] <= {tmp[31:16], din};
					else        PC      <= {tmp[31:16], din};
					pop_an <= 1'b0;
					A[7]   <= A[7] + 32'd4;
					st     <= S_FETCH;
				end

			// --- where a call lands --------------------------------------------
			// JSR: the effective address is resolved, so PC now points past the
			// whole instruction and that is exactly the return address.
			S_JSRP: begin
					tmp      <= PC;
					push_ret <= S_JSR;
					st       <= S_PUSH1;
				end

			S_JSR: begin
					PC     <= ea_addr;
					ea_lea <= 1'b0;
					st     <= S_FETCH;
				end

			S_LEA: begin
					ea_lea <= 1'b0;
					// LEA and JMP share this state because they want the same
					// thing from S_EA: the address, never what is at it.
					//
					// They are told apart by ir[8:6] alone. LEA is
					// 0100 rrr1 11 mmmrrr, so those bits are 111. JMP is
					// 0100 1110 11 mmmrrr, so they are 011 -- bit 8 is what
					// differs, and the test below already covers it.
					//
					// There used to be a second clause here, `ir[11:9] != 3'b111`,
					// meant to keep JMP out. It excluded register 7 instead, and
					// register 7 is A7 -- the stack pointer. So LEA $xxxxxxxx,A7
					// was executed as JMP $xxxxxxxx.
					//
					// That is the first thing a Mega Drive cartridge does: set up
					// its own stack before touching anything else. Combat Cars
					// does it at $06c2 with LEA $00FFF000,A7, and jumped to
					// $FFF000 -- into its own uninitialised stack -- instead.
					// Every commercial game dies this way, at the third
					// instruction, long before it draws anything. The test
					// cartridge never did because it kept the stack pointer the
					// reset vector gave it.
					if (ir[15:12] == 4'b0100 && ir[8:6] == 3'b111)
						A[areg] <= ea_addr;          // LEA, A7 included
					else
						PC <= ea_addr;               // JMP
					st <= S_FETCH;
				end

			S_TST: begin
					case (ea_sz)
					2'd0: begin N <= src[7];  Z <= (src[7:0]  == 8'd0);  end
					2'd1: begin N <= src[15]; Z <= (src[15:0] == 16'd0); end
					default: begin N <= src[31]; Z <= (src == 32'd0);    end
					endcase
					V  <= 1'b0;
					C  <= 1'b0;
					st <= S_FETCH;
				end

			S_SHIFT: begin
					case (ea_sz)
					2'd0:    begin shmsb = shv[7];  shmsb1 = shv[6];  end
					2'd1:    begin shmsb = shv[15]; shmsb1 = shv[14]; end
					default: begin shmsb = shv[31]; shmsb1 = shv[30]; end
					endcase

					if (shn == 6'd0) begin
						// The flags describe the shift as a whole. A count of
						// zero leaves X alone and clears C -- which is why shc
						// starts at zero rather than at the old C.
						N  <= shmsb;
						case (ea_sz)
						2'd0:    Z <= (shv[7:0]  == 8'd0);
						2'd1:    Z <= (shv[15:0] == 16'd0);
						default: Z <= (shv       == 32'd0);
						endcase
						C   <= shc;
						V   <= shov;
						src <= shv;
						st  <= S_EAW;
					end else begin
						shn <= shn - 6'd1;

						if (shleft) begin
							shin = (shtype == SH_ROX) ? X
							     : (shtype == SH_RO)  ? shmsb : 1'b0;
							shc <= shmsb;
							if (shtype != SH_RO) X <= shmsb;
							// Only an arithmetic left shift has an overflow, and
							// it latches: once the sign has moved it stays
							// reported even if a later bit puts it back.
							if (shtype == SH_AS && shmsb != shmsb1) shov <= 1'b1;
							case (ea_sz)
							2'd0:    shv[7:0]  <= {shv[6:0],  shin};
							2'd1:    shv[15:0] <= {shv[14:0], shin};
							default: shv       <= {shv[30:0], shin};
							endcase
						end else begin
							shin = (shtype == SH_AS)  ? shmsb
							     : (shtype == SH_ROX) ? X
							     : (shtype == SH_RO)  ? shv[0] : 1'b0;
							shc <= shv[0];
							if (shtype != SH_RO) X <= shv[0];
							case (ea_sz)
							2'd0:    shv[7:0]  <= {shin, shv[7:1]};
							2'd1:    shv[15:0] <= {shin, shv[15:1]};
							default: shv       <= {shin, shv[31:1]};
							endcase
						end
					end
				end

			// --- MOVEM ------------------------------------------------------------
			// The mask word comes first, before whatever extension words the
			// address needs -- so it is fetched here and the resolver runs after.
			S_MMM:  begin addr <= PC[23:0]; ds <= 2'b11; req <= 1'b1;
			              st <= S_MMM1; end
			S_MMM1: st <= S_MMM2;
			S_MMM2: begin
					mm_mask <= din;
					mm_i    <= 5'd0;
					PC      <= PC + 32'd2;
					// (An)+ and -(An) are not ordinary side effects here: the
					// register ends up moved by the whole transfer, not by one
					// step, so the resolver is skipped for them.
					if (ea_m == 3'b011 || ea_m == 3'b100) begin
						mm_addr <= A[ea_r];
						st      <= S_MM;
					end else begin
						ea_lea <= 1'b1;
						ea_wr  <= 1'b0;
						ea_ret <= S_MM_GO;
						st     <= S_EA;
					end
				end
			S_MM_GO: begin
					ea_lea  <= 1'b0;
					mm_addr <= ea_addr;
					st      <= S_MM;
				end

			S_MM: begin
					if (mm_i == 5'd16) begin
						// Both stepping modes finish with the register moved by
						// the whole transfer. For -(An) with An itself in the
						// mask, the value STORED was the original -- which it is,
						// because this is the only place An is written.
						if (ea_m == 3'b011 || ea_m == 3'b100) A[ea_r] <= mm_addr;
						st <= S_FETCH;
					end else if (!mm_mask[mm_i[3:0]]) begin
						mm_i <= mm_i + 5'd1;
					end else begin
						if (mm_pd) begin
							mma     = mm_addr - (mm_long ? 32'd4 : 32'd2);
							mm_addr <= mma;
						end else begin
							mma     = mm_addr;
							mm_addr <= mm_addr + (mm_long ? 32'd4 : 32'd2);
						end
						mm_ea <= mma;
						addr  <= mma[23:0];
						ds    <= 2'b11;
						req   <= 1'b1;
						if (mm_dir) begin
							st <= S_MM_R1;
						end else begin
							dout <= mm_long ? mm_rv[31:16] : mm_rv[15:0];
							we   <= 1'b1;
							st   <= mm_long ? S_MM_W2 : S_MM;
							if (!mm_long) mm_i <= mm_i + 5'd1;
						end
					end
				end

			S_MM_W2: begin
					addr <= mm_ea[23:0] + 24'd2;
					ds   <= 2'b11;
					dout <= mm_rv[15:0];
					we   <= 1'b1;
					req  <= 1'b1;
					mm_i <= mm_i + 5'd1;
					st   <= S_MM;
				end

			S_MM_R1: st <= S_MM_R2;
			S_MM_R2: begin
					if (mm_long) begin
						tmp  <= {din, 16'd0};
						addr <= mm_ea[23:0] + 24'd2;
						ds   <= 2'b11;
						req  <= 1'b1;
						st   <= S_MM_R3;
					end else begin
						// A word loaded into a register is SIGN extended to all
						// thirty-two bits, and that is true of data registers too,
						// not only address ones.
						if (mm_rn[3]) A[mm_rn[2:0]] <= {{16{din[15]}}, din};
						else          D[mm_rn[2:0]] <= {{16{din[15]}}, din};
						mm_i <= mm_i + 5'd1;
						st   <= S_MM;
					end
				end
			S_MM_R3: st <= S_MM_R4;
			S_MM_R4: begin
					if (mm_rn[3]) A[mm_rn[2:0]] <= {tmp[31:16], din};
					else          D[mm_rn[2:0]] <= {tmp[31:16], din};
					mm_i <= mm_i + 5'd1;
					st   <= S_MM;
				end

			// Writing the status register, whole or in part. The condition-code
			// form leaves the supervisor bit and the interrupt mask alone, which
			// is the only difference between the two.
			S_TOSR: begin
					if (sr_wide) begin
						T <= src[15];
						S <= src[13];
						I <= src[10:8];
					end
					X  <= src[4];
					N  <= src[3];
					Z  <= src[2];
					V  <= src[1];
					C  <= src[0];
					st <= S_FETCH;
				end

			S_SROP: begin
					newsr = (sr_op == 3'd0) ? (SR | imm[15:0])
					      : (sr_op == 3'd1) ? (SR & imm[15:0])
					                        : (SR ^ imm[15:0]);
					if (sr_wide) begin
						T <= newsr[15];
						S <= newsr[13];
						I <= newsr[10:8];
					end
					X  <= newsr[4];
					N  <= newsr[3];
					Z  <= newsr[2];
					V  <= newsr[1];
					C  <= newsr[0];
					st <= S_FETCH;
				end

			// --- multiply ----------------------------------------------------------
			S_MUL: begin
					mula = D[areg][15:0];
					mulb = src[15:0];
					if (md_sign) mres = mula * mulb;
					else         mres = D[areg][15:0] * src[15:0];
					D[areg] <= mres;
					N  <= mres[31];
					Z  <= (mres == 32'd0);
					// Neither flag can happen: the result of a 16 by 16 multiply
					// always fits in the 32 bits it is given.
					V  <= 1'b0;
					C  <= 1'b0;
					st <= S_FETCH;
				end

			// --- divide ------------------------------------------------------------
			// Signed division is done by dividing the magnitudes and putting the
			// signs back afterwards: the quotient takes both signs together, the
			// remainder takes the dividend's alone.
			S_DIV0:
				if (src[15:0] == 16'd0) begin
					exc_vec <= 8'd5;            // divide by zero
					exc_irq <= 1'b0;
					st      <= S_EXC;
				end else begin
					q_neg <= md_sign && (D[areg][31] ^ src[15]);
					r_neg <= md_sign && D[areg][31];
					dvd   <= (md_sign && D[areg][31]) ? (~D[areg] + 32'd1)
					                                  : D[areg];
					dvr   <= (md_sign && src[15]) ? (~src[15:0] + 16'd1)
					                              : src[15:0];
					rem   <= 17'd0;
					dvn   <= 6'd32;
					st    <= S_DIV;
				end

			S_DIV: begin
					if (dvn == 6'd0) begin
						st <= S_DIV1;
					end else begin
						dvn <= dvn - 6'd1;
						// One bit of the dividend moves up into the remainder and
						// one bit of the quotient moves in at the bottom, sharing
						// the register the dividend is vacating.
						if ({rem[15:0], dvd[31]} >= {1'b0, dvr}) begin
							rem <= {rem[15:0], dvd[31]} - {1'b0, dvr};
							dvd <= {dvd[30:0], 1'b1};
						end else begin
							rem <= {rem[15:0], dvd[31]};
							dvd <= {dvd[30:0], 1'b0};
						end
					end
				end

			S_DIV1: begin
					qfix = q_neg ? (~dvd + 32'd1) : dvd;
					rfix = r_neg ? (~{15'd0, rem} + 32'd1) : {15'd0, rem};
					st <= S_FETCH;
					// A quotient that will not fit in sixteen bits sets the
					// overflow flag and leaves the destination ALONE -- the
					// dividend is still there for a wider routine to retry with.
					if (md_sign ? (q_neg ? (dvd > 32'h00008000)
					                     : (dvd > 32'h00007FFF))
					            : (dvd > 32'h0000FFFF)) begin
						V <= 1'b1;
						// N and Z are undefined after this, but the carry is
						// not: a divide always clears it, overflow or no.
						C <= 1'b0;
					end else begin
						D[areg] <= {rfix[15:0], qfix[15:0]};
						N <= qfix[15];
						Z <= (qfix[15:0] == 16'd0);
						V <= 1'b0;
						C <= 1'b0;
					end
				end

			// The second operand of a two-address memory instruction: the same
			// addressing mode again, on the other register. The first one is
			// already in src, so it moves aside into imm.
			S_X2ND: begin
					imm     <= src;
					alu_rmw <= 1'b1;
					ea_r    <= ir[11:9];
					ea_wr   <= 1'b0;
					ea_ret  <= S_ALU;
					st      <= S_EA;
				end

			S_PEA: begin
					ea_lea   <= 1'b0;
					tmp      <= ea_addr;
					push_ret <= S_FETCH;
					st       <= S_PUSH1;
				end

			// LINK saves the old frame pointer, points it at the new frame, and
			// then opens the frame -- with a displacement that is nearly always
			// negative, the stack growing down.
			S_LINK: begin
					tmp      <= A[areg];
					push_ret <= S_LINK1;
					st       <= S_PUSH1;
				end
			S_LINK1: begin
					A[areg] <= A[7];
					A[7]    <= A[7] + {{16{imm[15]}}, imm[15:0]};
					st      <= S_FETCH;
				end

			S_UNLK: begin
					A[7]   <= A[areg];
					pop_an <= 1'b1;
					st     <= S_POP1;
				end

			S_TAS: begin
					N <= src[7];
					Z <= (src[7:0] == 8'd0);
					V <= 1'b0;
					C <= 1'b0;
					src[7] <= 1'b1;
					st <= S_EAW;
				end

			S_BIT: begin
					// Thirty-two bits in a register, eight in memory. The number
					// wraps to the width rather than being an error.
					bsel = (ea_sz == 2'd2) ? bnum : {2'b00, bnum[2:0]};
					// Z is the ONLY flag any of these four touch, and it reports
					// the bit as it was BEFORE the change.
					Z <= ~src[bsel];
					case (bop)
					BOP_TST: st <= S_FETCH;
					BOP_CHG: begin src[bsel] <= ~src[bsel]; st <= S_EAW; end
					BOP_CLR: begin src[bsel] <= 1'b0;       st <= S_EAW; end
					default: begin src[bsel] <= 1'b1;       st <= S_EAW; end
					endcase
				end

			// --- exception processing ---------------------------------------------
			// The frame is PC then SR, so SR ends up at the LOWER address and a
			// handler finds the return address at 2(SP).
			S_EXC: begin
					exc_sr   <= SR;
					S        <= 1'b1;       // always supervisor inside a handler
					T        <= 1'b0;       // and never tracing
					if (exc_irq) I <= exc_lvl;
					tmp      <= PC;
					push_ret <= S_EXC_SR;
					st       <= S_PUSH1;
				end
			S_EXC_SR: begin
					A[7] <= A[7] - 32'd2;
					addr <= A[7][23:0] - 24'd2;
					ds   <= 2'b11;
					dout <= exc_sr;
					we   <= 1'b1;
					req  <= 1'b1;
					st   <= S_EXC_V;
				end
			S_EXC_V: begin
					addr <= {14'd0, exc_vec, 2'b00};
					ds   <= 2'b11;
					req  <= 1'b1;
					st   <= S_EXC_V1;
				end
			S_EXC_V1: st <= S_EXC_V2;
			S_EXC_V2: begin
					tmp  <= {din, 16'd0};
					addr <= {14'd0, exc_vec, 2'b00} + 24'd2;
					ds   <= 2'b11;
					req  <= 1'b1;
					st   <= S_EXC_V3;
				end
			S_EXC_V3: st <= S_EXC_V4;
			S_EXC_V4: begin
					PC      <= {tmp[31:16], din};
					exc_irq <= 1'b0;
					st      <= S_FETCH;
				end

			// RTE undoes it: the status register first, then the return address.
			// That order matters -- restoring SR is what puts the interrupt mask
			// back, and doing it after the jump would leave a window.
			S_RTE:  begin addr <= A[7][23:0]; ds <= 2'b11; req <= 1'b1;
			              st <= S_RTE1; end
			S_RTE1: st <= S_RTE2;
			S_RTE2: begin
					T <= din[15];
					S <= din[13];
					I <= din[10:8];
					X <= din[4];
					N <= din[3];
					Z <= din[2];
					V <= din[1];
					C <= din[0];
					A[7] <= A[7] + 32'd2;
					st   <= S_POP1;
				end

			// STOP waits for an interrupt, which is the whole reason it exists.
			S_HALT:
				if (irq_pending) begin
					halted  <= 1'b0;
					exc_vec <= 8'd24 + {5'd0, ipl_s};
					exc_irq <= 1'b1;
					exc_lvl <= ipl_s;
					st      <= S_EXC;
				end else
					halted <= 1'b1;

			default: st <= S_FETCH;
			endcase
		end
	end

endmodule

`default_nettype wire
