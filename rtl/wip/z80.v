//////////////////////////////////////////////////////////////////////////////////
// z80.v - a Zilog Z80, for the Master System side of this console.
//
// Much larger than the 6502 next door, and for a specific reason: the 6502 has
// one accumulator and a handful of addressing modes, while the Z80 has seven
// general registers, a shadow set, two index registers, and four prefix pages
// that re-interpret the opcode that follows. Roughly 1200 distinguishable
// instructions against the 6502's 151.
//
// What makes it tractable is that most of that is regular:
//
//   0x40-0x7F   LD r,r'      both operands are the 3-bit register code
//   0x80-0xBF   ALU A,r      operation in bits 5:3, operand in bits 2:0
//   CB page     rotates, BIT, RES, SET -- entirely regular
//   DD / FD     the previous page again, with HL replaced by IX or IY
//
// So the decode is written to exploit that rather than as a flat table. The
// irregular parts -- the ED page, the block instructions, the odd corners of
// 0x00-0x3F -- are the ones spelled out case by case.
//
// Register codes are the Z80's own: 0=B 1=C 2=D 3=E 4=H 5=L 6=(HL) 7=A. Code 6
// is memory rather than a register, which is why almost every instruction form
// has a "does this touch memory" branch. Under a DD or FD prefix, codes 4 and 5
// become the halves of the index register and code 6 becomes (IX+d) -- except
// where the operand is the *other* side of a LD r,(IX+d), which is never
// redirected. That exception is the single most common thing to get wrong.
//
// Flags, bit 7 down to 0: S Z Y H X P/V N C. Y and X are copies of result bits
// 5 and 3. They are undocumented, no program is supposed to depend on them, and
// ZEXALL checks them anyway -- which is the point of testing against it.
//
// Memory is synchronous: an address presented in one cycle returns data in the
// next. That is why every access here is two states rather than one.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module z80 (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,

	output reg  [15:0] addr,
	input  wire [7:0]  din,
	output reg  [7:0]  dout,
	output reg         we,
	output reg         io,          // 1 = I/O space, 0 = memory
	output reg         m1,          // opcode fetch, for the debugger

	input  wire        int_n,       // active low, level triggered
	input  wire        nmi_n,       // active low, edge triggered

	output wire [15:0] dbg_pc, dbg_sp, dbg_af, dbg_bc, dbg_de, dbg_hl,
	output wire        dbg_m1
);

	// --- registers --------------------------------------------------------------
	// Indexed by the Z80's own register code so LD r,r' is a pair of array
	// accesses. Slot 6 is where (HL) would be; it is never read as a register
	// and is used as scratch for the memory operand instead.
	localparam RB = 3'd0, RC = 3'd1, RD = 3'd2, RE = 3'd3,
	           RH = 3'd4, RL = 3'd5, RM = 3'd6, RA = 3'd7;

	reg [7:0] R [0:7];
	reg [7:0] F;
	reg [7:0] Rs [0:7];          // the shadow set
	reg [7:0] Fs;
	reg [15:0] IX, IY, SP, PC;
	reg [7:0]  I, Rr;            // interrupt vector high byte, refresh counter
	reg        IFF1, IFF2;
	reg [1:0]  IM;
	reg        halted;

	// Flag bit positions.
	localparam FC = 0, FN = 1, FP = 2, FX = 3, FH = 4, FY = 5, FZ = 6, FS = 7;

	assign dbg_pc = PC;
	assign dbg_sp = SP;
	assign dbg_af = {R[RA], F};
	assign dbg_bc = {R[RB], R[RC]};
	assign dbg_de = {R[RD], R[RE]};
	assign dbg_hl = {R[RH], R[RL]};
	assign dbg_m1 = m1;

	// --- decode state -----------------------------------------------------------
	reg [7:0]  op;               // the opcode being executed
	reg [1:0]  pfx;              // 0 none, 1 DD (IX), 2 FD (IY)
	reg        cb, ed;           // which prefix page the opcode came from
	reg [7:0]  tmp, tmp2;
	reg [15:0] wz;               // the Z80's internal address latch
	reg [7:0]  disp;             // the d in (IX+d)

	// --- the sequencer ------------------------------------------------------------
	localparam S_RESET   = 6'd0,  S_FETCH   = 6'd1,  S_FETCH2  = 6'd2,
	           S_EXEC    = 6'd3,
	           S_RD      = 6'd4,  S_RD2     = 6'd5,
	           S_WR      = 6'd6,
	           S_IMM     = 6'd7,  S_IMM2    = 6'd8,
	           S_IMMW    = 6'd9,  S_IMMW2   = 6'd10, S_IMMW3 = 6'd11, S_IMMW4 = 6'd12,
	           S_DISP    = 6'd13, S_DISP2   = 6'd14,
	           S_PUSH1   = 6'd15, S_PUSH2   = 6'd16,
	           S_POP1    = 6'd17, S_POP2    = 6'd18, S_POP3  = 6'd19, S_POP4 = 6'd20,
	           S_MRD     = 6'd21, S_MRD2    = 6'd22,
	           S_MWR     = 6'd23,
	           S_MRDW    = 6'd24, S_MRDW2   = 6'd25, S_MRDW3 = 6'd26, S_MRDW4 = 6'd27,
	           S_MWRW    = 6'd28, S_MWRW2   = 6'd29,
	           S_IORD    = 6'd30, S_IORD2   = 6'd31,
	           S_IOWR    = 6'd32,
	           S_HALT    = 6'd33,
	           S_INT     = 6'd34, S_INT2    = 6'd35, S_INT3  = 6'd36,
	           S_BLK     = 6'd37, S_BLK2    = 6'd38,
	           S_IDLE    = 6'd39;

	reg [5:0] st, ret_st;

	// Where a gathered operand should go, and what to do once it arrives.
	reg [2:0] dst;
	reg [1:0] pend;              // a small "what was I doing" for shared states

	// --- helpers ------------------------------------------------------------------
	wire [15:0] HL = {R[RH], R[RL]};
	wire [15:0] BC = {R[RB], R[RC]};
	wire [15:0] DE = {R[RD], R[RE]};
	wire [15:0] IDX = (pfx == 2'd1) ? IX : (pfx == 2'd2) ? IY : HL;

	// Under DD/FD, H and L are the halves of the index register -- but only when
	// the instruction is not one whose operand is (IX+d). The caller decides by
	// passing `plain`.
	function [7:0] rd_reg;
		input [2:0] c;
		input       plain;       // 1 = ignore the prefix for this operand
		begin
			if (!plain && pfx == 2'd1 && c == RH)      rd_reg = IX[15:8];
			else if (!plain && pfx == 2'd1 && c == RL) rd_reg = IX[7:0];
			else if (!plain && pfx == 2'd2 && c == RH) rd_reg = IY[15:8];
			else if (!plain && pfx == 2'd2 && c == RL) rd_reg = IY[7:0];
			else                                       rd_reg = R[c];
		end
	endfunction

	function parity8;
		input [7:0] v;
		parity8 = ~^v;
	endfunction

	// --- the 8-bit ALU ---------------------------------------------------------------
	reg [7:0] alu_r;
	reg [7:0] alu_f;

	task do_alu;
		input [2:0] kind;        // 0 ADD 1 ADC 2 SUB 3 SBC 4 AND 5 XOR 6 OR 7 CP
		input [7:0] a;
		input [7:0] b;
		reg [8:0] s;
		reg       cin;
		reg [7:0] res;
		begin
			cin = (kind == 3'd1 || kind == 3'd3) ? F[FC] : 1'b0;
			case (kind)
			3'd0, 3'd1: begin
				s   = {1'b0, a} + {1'b0, b} + {8'd0, cin};
				res = s[7:0];
				alu_f[FH] = a[4] ^ b[4] ^ res[4];
				alu_f[FP] = (~(a[7] ^ b[7])) & (a[7] ^ res[7]);
				alu_f[FN] = 1'b0;
				alu_f[FC] = s[8];
			end
			3'd2, 3'd3, 3'd7: begin
				s   = {1'b0, a} - {1'b0, b} - {8'd0, cin};
				res = s[7:0];
				alu_f[FH] = a[4] ^ b[4] ^ res[4];
				alu_f[FP] = (a[7] ^ b[7]) & (a[7] ^ res[7]);
				alu_f[FN] = 1'b1;
				alu_f[FC] = s[8];
			end
			3'd4: begin
				res = a & b;
				alu_f[FH] = 1'b1; alu_f[FN] = 1'b0; alu_f[FC] = 1'b0;
				alu_f[FP] = parity8(res);
			end
			3'd5: begin
				res = a ^ b;
				alu_f[FH] = 1'b0; alu_f[FN] = 1'b0; alu_f[FC] = 1'b0;
				alu_f[FP] = parity8(res);
			end
			default: begin
				res = a | b;
				alu_f[FH] = 1'b0; alu_f[FN] = 1'b0; alu_f[FC] = 1'b0;
				alu_f[FP] = parity8(res);
			end
			endcase

			alu_f[FS] = res[7];
			alu_f[FZ] = (res == 8'd0);
			// CP leaves the result nowhere, and takes its undocumented bits from
			// the operand rather than from the difference. Every other operation
			// takes them from the result.
			if (kind == 3'd7) begin
				alu_f[FY] = b[5];
				alu_f[FX] = b[3];
				alu_r = a;
			end else begin
				alu_f[FY] = res[5];
				alu_f[FX] = res[3];
				alu_r = res;
			end
		end
	endtask

	// --- rotates and shifts -------------------------------------------------------
	task do_rot;
		input [2:0] kind;        // 0 RLC 1 RRC 2 RL 3 RR 4 SLA 5 SRA 6 SLL 7 SRL
		input [7:0] v;
		reg [7:0] res;
		reg       cout;
		begin
			case (kind)
			3'd0: begin res = {v[6:0], v[7]};   cout = v[7]; end
			3'd1: begin res = {v[0], v[7:1]};   cout = v[0]; end
			3'd2: begin res = {v[6:0], F[FC]};  cout = v[7]; end
			3'd3: begin res = {F[FC], v[7:1]};  cout = v[0]; end
			3'd4: begin res = {v[6:0], 1'b0};   cout = v[7]; end
			3'd5: begin res = {v[7], v[7:1]};   cout = v[0]; end
			// SLL is undocumented and shifts a one in at the bottom. It exists,
			// programs use it, and ZEXALL tests it.
			3'd6: begin res = {v[6:0], 1'b1};   cout = v[7]; end
			default: begin res = {1'b0, v[7:1]}; cout = v[0]; end
			endcase
			alu_r = res;
			alu_f[FS] = res[7];
			alu_f[FZ] = (res == 8'd0);
			alu_f[FY] = res[5];
			alu_f[FH] = 1'b0;
			alu_f[FX] = res[3];
			alu_f[FP] = parity8(res);
			alu_f[FN] = 1'b0;
			alu_f[FC] = cout;
		end
	endtask

	task do_inc;
		input [7:0] v;
		reg [7:0] res;
		begin
			res = v + 8'd1;
			alu_r = res;
			alu_f = F;
			alu_f[FS] = res[7];
			alu_f[FZ] = (res == 8'd0);
			alu_f[FY] = res[5];
			alu_f[FH] = (v[3:0] == 4'hF);
			alu_f[FX] = res[3];
			alu_f[FP] = (v == 8'h7F);
			alu_f[FN] = 1'b0;
		end
	endtask

	task do_dec;
		input [7:0] v;
		reg [7:0] res;
		begin
			res = v - 8'd1;
			alu_r = res;
			alu_f = F;
			alu_f[FS] = res[7];
			alu_f[FZ] = (res == 8'd0);
			alu_f[FY] = res[5];
			alu_f[FH] = (v[3:0] == 4'h0);
			alu_f[FX] = res[3];
			alu_f[FP] = (v == 8'h80);
			alu_f[FN] = 1'b1;
		end
	endtask

	// --- condition codes ------------------------------------------------------------
	function cond_met;
		input [2:0] c;
		case (c)
		3'd0: cond_met = ~F[FZ];
		3'd1: cond_met =  F[FZ];
		3'd2: cond_met = ~F[FC];
		3'd3: cond_met =  F[FC];
		3'd4: cond_met = ~F[FP];
		3'd5: cond_met =  F[FP];
		3'd6: cond_met = ~F[FS];
		default: cond_met = F[FS];
		endcase
	endfunction

	// --- interrupt edge detection -----------------------------------------------------
	reg nmi_prev, nmi_pending;

	integer i;

	always @(posedge clk) begin
		if (rst) begin
			st <= S_RESET;
			PC <= 16'd0; SP <= 16'hFFFF; F <= 8'd0; Fs <= 8'd0;
			IX <= 16'd0; IY <= 16'd0; I <= 8'd0; Rr <= 8'd0;
			IFF1 <= 1'b0; IFF2 <= 1'b0; IM <= 2'd0; halted <= 1'b0;
			pfx <= 2'd0; cb <= 1'b0; ed <= 1'b0;
			we <= 1'b0; io <= 1'b0; m1 <= 1'b0; addr <= 16'd0; dout <= 8'd0;
			nmi_prev <= 1'b1; nmi_pending <= 1'b0;
			wz <= 16'd0; tmp <= 8'd0; tmp2 <= 8'd0; disp <= 8'd0;
			dst <= 3'd0; pend <= 2'd0; ret_st <= S_FETCH;
			for (i = 0; i < 8; i = i + 1) begin R[i] <= 8'd0; Rs[i] <= 8'd0; end
		end else if (ce) begin
			we <= 1'b0;
			io <= 1'b0;
			m1 <= 1'b0;

			// The NMI is edge triggered, so it is latched rather than sampled.
			nmi_prev <= nmi_n;
			if (nmi_prev && !nmi_n) nmi_pending <= 1'b1;

			case (st)
			// ---------------------------------------------------------------
			S_RESET: begin
				PC <= 16'd0; SP <= 16'hFFFF; IFF1 <= 1'b0; IFF2 <= 1'b0;
				IM <= 2'd0; I <= 8'd0; Rr <= 8'd0;
				st <= S_FETCH;
			end

			// ---------------------------------------------------------------
			// An opcode fetch. The prefix state is cleared here rather than at
			// the end of the previous instruction, so a DD or FD can simply not
			// clear it and fall through to the next fetch.
			S_FETCH: begin
				if (nmi_pending) begin
					nmi_pending <= 1'b0;
					halted <= 1'b0;
					IFF2 <= IFF1;
					IFF1 <= 1'b0;
					wz   <= 16'h0066;
					pend <= 2'd1;                 // an interrupt-style call
					st   <= S_INT;
				end else if (!int_n && IFF1 && !cb && !ed && pfx == 2'd0) begin
					halted <= 1'b0;
					IFF1 <= 1'b0; IFF2 <= 1'b0;
					// Only mode 1 is implemented, which is what the Master
					// System uses; modes 0 and 2 land here as a restart to $38
					// rather than silently doing nothing.
					wz   <= 16'h0038;
					pend <= 2'd1;
					st   <= S_INT;
				end else if (halted) begin
					st <= S_HALT;
				end else begin
					addr <= PC;
					m1   <= 1'b1;
					PC   <= PC + 16'd1;
					Rr   <= {Rr[7], Rr[6:0] + 7'd1};   // bit 7 does not count
					st   <= S_FETCH2;
				end
			end

			S_FETCH2: begin
				op <= din;
				st <= S_EXEC;
			end

			// ---------------------------------------------------------------
			// Generic operand gathering. Each of these returns to `ret_st`.
			S_IMM:  begin addr <= PC; PC <= PC + 16'd1; st <= S_IMM2; end
			S_IMM2: begin tmp <= din; st <= ret_st; end

			S_IMMW:  begin addr <= PC; PC <= PC + 16'd1; st <= S_IMMW2; end
			S_IMMW2: begin wz[7:0] <= din; addr <= PC; PC <= PC + 16'd1; st <= S_IMMW3; end
			S_IMMW3: begin st <= S_IMMW4; end
			S_IMMW4: begin wz[15:8] <= din; st <= ret_st; end

			S_MRD:  begin addr <= wz; st <= S_MRD2; end
			S_MRD2: begin tmp <= din; st <= ret_st; end

			S_MWR:  begin addr <= wz; dout <= tmp; we <= 1'b1; st <= ret_st; end

			S_MRDW:  begin addr <= wz; st <= S_MRDW2; end
			S_MRDW2: begin tmp <= din; addr <= wz + 16'd1; st <= S_MRDW3; end
			S_MRDW3: begin st <= S_MRDW4; end
			S_MRDW4: begin tmp2 <= din; st <= ret_st; end

			S_MWRW:  begin addr <= wz; dout <= tmp; we <= 1'b1; st <= S_MWRW2; end
			S_MWRW2: begin addr <= wz + 16'd1; dout <= tmp2; we <= 1'b1; st <= ret_st; end

			S_PUSH1: begin SP <= SP - 16'd1; addr <= SP - 16'd1; dout <= tmp2; we <= 1'b1; st <= S_PUSH2; end
			S_PUSH2: begin SP <= SP - 16'd1; addr <= SP - 16'd1; dout <= tmp;  we <= 1'b1; st <= ret_st; end

			S_POP1: begin addr <= SP; SP <= SP + 16'd1; st <= S_POP2; end
			S_POP2: begin tmp <= din; addr <= SP; SP <= SP + 16'd1; st <= S_POP3; end
			S_POP3: begin st <= S_POP4; end
			S_POP4: begin tmp2 <= din; st <= ret_st; end

			S_IORD:  begin addr <= wz; io <= 1'b1; st <= S_IORD2; end
			S_IORD2: begin tmp <= din; st <= ret_st; end

			S_IOWR: begin addr <= wz; dout <= tmp; io <= 1'b1; we <= 1'b1; st <= ret_st; end

			S_HALT: begin
				// Sit here until something interrupts. PC already points past
				// the HALT, which is what makes the return address correct.
				if (nmi_pending || (!int_n && IFF1)) begin
					halted <= 1'b0;
					st <= S_FETCH;
				end
			end

			S_INT: begin
				tmp  <= PC[7:0];
				tmp2 <= PC[15:8];
				ret_st <= S_INT2;
				st <= S_PUSH1;
			end
			S_INT2: begin PC <= wz; st <= S_FETCH; end

			S_IDLE: st <= S_FETCH;

`include "z80_exec.vh"

			default: st <= S_FETCH;
			endcase
		end
	end

endmodule

`default_nettype wire

//////////////////////////////////////////////////////////////////////////////////
// NOT BUILT YET -- parked here deliberately, see docs/Z80-DESIGN.md.
//
// What is right: the register file, the flag model including the undocumented
// X and Y bits, the 8-bit ALU, the rotate/shift unit, the condition codes, the
// sequencer's operand-gathering states, and the decode's shape.
//
// What is wrong: every multi-cycle instruction sets `ret_st <= S_EXEC` to come
// back once its operand has arrived, but S_EXEC begins by re-decoding `op`.
// So instead of finishing, the instruction starts again -- forever. The fix is
// a continuation code checked at the top of S_EXEC, described in the design
// note. Not a patch over this file: the continuation half has to be designed
// alongside the decode, because which state each instruction resumes in is
// part of the instruction's definition.
//////////////////////////////////////////////////////////////////////////////////
