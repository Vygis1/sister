//////////////////////////////////////////////////////////////////////////////////
// z80.v - a Zilog Z80, for the Master System side of this console.
//
// Much larger than the 6502 next door, and for a specific reason: the 6502 has
// one accumulator and a handful of addressing modes, while the Z80 has seven
// general registers, a shadow set, two index registers, and four prefix pages
// that re-interpret whatever opcode follows.
//
// What makes it tractable is that most of it is regular:
//
//   0x40-0x7F   LD r,r'      both operands are the 3-bit register code
//   0x80-0xBF   ALU A,r      operation in bits 5:3, operand in bits 2:0
//   CB page     rotates, BIT, RES, SET -- entirely regular
//   DD / FD     the same pages again, with HL replaced by IX or IY
//
// so the decode exploits that rather than being a flat table. The irregular
// parts -- the ED page, the block instructions, the corners of 0x00-0x3F -- are
// the ones spelled out one at a time.
//
// --- how an instruction gets through here ------------------------------------
//
// Memory is synchronous: an address presented in one cycle returns data in the
// next. So anything touching memory takes several states, and the states that
// do the touching are shared between all the instructions that need them.
// Each returns to `ret_st`, and `cont` says what to do once it gets there.
//
//     decode:  wz <= HL; cont <= C_ALUM; ret_st <= S_EXEC; st <= S_MRD;
//     resume:  C_ALUM: do_alu(alukind, A, tmp); ...
//
// That split is the whole architecture, and the first attempt at this file
// (now in rtl/wip/, with docs/Z80-DESIGN.md) got it wrong by returning to the
// decode itself -- so every multi-cycle instruction restarted forever instead
// of finishing. `cont` is what makes S_EXEC mean "resume" as well as "decode".
//
// Instructions needing two gathered operands -- LD (IX+d),n fetches a
// displacement and then an immediate -- chain two continuation codes. That is
// the case a single "am I resuming" flag cannot express.
//
// --- registers and flags ------------------------------------------------------
//
// Register codes are the Z80's own: 0=B 1=C 2=D 3=E 4=H 5=L 6=(HL) 7=A, so
// LD r,r' is a pair of array accesses. Code 6 is memory rather than a register,
// which is why nearly every form has a "does this touch memory" branch.
//
// Under DD or FD, codes 4 and 5 become the halves of the index register and 6
// becomes (IX+d) -- except that the OTHER side of a LD r,(IX+d) is never
// redirected. Every register access therefore says whether the prefix applies
// to it, rather than the prefix being read from state; that exception is the
// single most common thing to get wrong here.
//
// Flags, bit 7 down to 0: S Z Y H X P/V N C. Y and X are undocumented copies of
// result bits 5 and 3. Nothing is supposed to read them and ZEXALL checks them
// anyway, which is exactly why it is worth testing against.
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
	output reg         m1,          // opcode fetch

	input  wire        int_n,       // active low, level triggered
	input  wire        nmi_n,       // active low, edge triggered

	output wire [15:0] dbg_pc, dbg_sp, dbg_af, dbg_bc, dbg_de, dbg_hl,
	output wire        dbg_m1
);

	localparam RB = 3'd0, RC = 3'd1, RD = 3'd2, RE = 3'd3,
	           RH = 3'd4, RL = 3'd5, RM = 3'd6, RA = 3'd7;
	localparam FC = 0, FN = 1, FP = 2, FX = 3, FH = 4, FY = 5, FZ = 6, FS = 7;

	reg [7:0]  R  [0:7];
	reg [7:0]  Rs [0:7];
	reg [7:0]  F, Fs;
	reg [15:0] IX, IY, SP, PC;
	reg [7:0]  I, Rr;
	reg        IFF1, IFF2;
	reg [1:0]  IM;
	reg        halted;

	assign dbg_pc = PC;
	assign dbg_sp = SP;
	assign dbg_af = {R[RA], F};
	assign dbg_bc = {R[RB], R[RC]};
	assign dbg_de = {R[RD], R[RE]};
	assign dbg_hl = {R[RH], R[RL]};
	assign dbg_m1 = m1;

	reg [7:0]  op;
	reg [1:0]  pfx;              // 0 none, 1 DD (IX), 2 FD (IY)
	reg        cb, ed;
	reg [7:0]  tmp, tmp2;
	reg [15:0] wz;
	reg [2:0]  dst, alukind;
	reg        incdec;           // 0 = INC, 1 = DEC
	reg        taken;

	// --- states ---------------------------------------------------------------
	localparam S_RESET = 6'd0,  S_FETCH = 6'd1,  S_FETCH2 = 6'd2, S_EXEC = 6'd3,
	           S_IMM   = 6'd4,  S_IMM2  = 6'd5,
	           S_IMMW  = 6'd6,  S_IMMW2 = 6'd7,  S_IMMW3 = 6'd8,  S_IMMW4 = 6'd9,
	           S_MRD   = 6'd10, S_MRD2  = 6'd11, S_MWR   = 6'd12,
	           S_MRDW  = 6'd13, S_MRDW2 = 6'd14, S_MRDW3 = 6'd15, S_MRDW4 = 6'd16,
	           S_MWRW  = 6'd17, S_MWRW2 = 6'd18,
	           S_PUSH1 = 6'd19, S_PUSH2 = 6'd20,
	           S_POP1  = 6'd21, S_POP2  = 6'd22, S_POP3  = 6'd23, S_POP4 = 6'd24,
	           S_IORD  = 6'd25, S_IORD2 = 6'd26, S_IOWR  = 6'd27,
	           S_HALT  = 6'd28, S_INT   = 6'd29, S_INT2  = 6'd30,
	           // An address presented during a cycle is only latched by memory
	           // at the END of it, so the data appears a cycle after that. The
	           // word-sized transfers below already have the gap because they
	           // present a second address in between; the byte-sized ones need
	           // it spelled out.
	           S_FETCHW = 6'd31, S_IMMW_ = 6'd32, S_MRDW_ = 6'd33, S_IORDW = 6'd34,
	           S_IMMW5 = 6'd35, S_MRDW5 = 6'd36, S_POP5 = 6'd37;

	// --- continuations --------------------------------------------------------
	localparam C_NONE   = 6'd0,
	           C_LDRN   = 6'd1,   // an immediate arrived, for a register or (HL)
	           C_LDRM   = 6'd2,   // a memory byte arrived, for a register
	           C_ALUM   = 6'd3,   // an operand arrived, for the ALU
	           C_INCM   = 6'd4,   // a memory byte arrived, to be INCed or DECed
	           C_LDRPNN = 6'd5,   // an immediate word arrived, for a pair
	           C_JP     = 6'd6,
	           C_CALL   = 6'd7,
	           C_CALL2  = 6'd8,
	           C_RET    = 6'd9,
	           C_POPRP  = 6'd10,
	           C_JR     = 6'd11,
	           C_RST    = 6'd12,
	           C_INN    = 6'd13,
	           C_INN2   = 6'd14,
	           C_OUTN   = 6'd15,
	           C_EXSP   = 6'd16,
	           C_LDNNA  = 6'd17,  // (nn) arrived, write A there
	           C_LDANN  = 6'd18,  // (nn) arrived, read A from there
	           C_LDNNHL = 6'd19,
	           C_LDHLNN = 6'd20,
	           C_LDHLNN2= 6'd21,
	           C_CBM    = 6'd22,  // a memory byte arrived, for a CB operation
	           C_DISP   = 6'd23,  // a displacement arrived; chains to `after`
	           C_DDCBD  = 6'd24,  // DDCB displacement arrived, fetch the opcode
	           C_DDCBOP = 6'd25,  // DDCB opcode arrived, read the operand
	           C_LDMN   = 6'd26,  // (IX+d) known and n arrived
	           C_EDNNW  = 6'd27,
	           C_EDNNR  = 6'd28,
	           C_EDNNR2 = 6'd29,
	           // The block instructions. Each is a read, a write, a pointer
	           // update and a decision about whether to do it all again -- so
	           // each needs two continuations, not one.
	           C_LDBLK  = 6'd30, C_LDBLK2  = 6'd31,
	           C_CPBLK  = 6'd32,
	           C_INBLK  = 6'd33, C_INBLK2  = 6'd34,
	           C_OUTBLK = 6'd35, C_OUTBLK2 = 6'd36,
	           C_RRD    = 6'd37,
	           C_INRC   = 6'd38;

	reg [5:0] st, ret_st, cont, after;

	// --- convenience ------------------------------------------------------------
	wire [15:0] HL  = {R[RH], R[RL]};
	wire [15:0] BC  = {R[RB], R[RC]};
	wire [15:0] DE  = {R[RD], R[RE]};
	wire [15:0] IDX = (pfx == 2'd1) ? IX : (pfx == 2'd2) ? IY : HL;

	function [7:0] rd_reg;
		input [2:0] c;
		input       plain;       // 1 = this operand ignores the prefix
		begin
			if      (!plain && pfx == 2'd1 && c == RH) rd_reg = IX[15:8];
			else if (!plain && pfx == 2'd1 && c == RL) rd_reg = IX[7:0];
			else if (!plain && pfx == 2'd2 && c == RH) rd_reg = IY[15:8];
			else if (!plain && pfx == 2'd2 && c == RL) rd_reg = IY[7:0];
			else                                       rd_reg = R[c];
		end
	endfunction

	task wr_reg;
		input [2:0] c;
		input [7:0] v;
		input       plain;
		begin
			if      (!plain && pfx == 2'd1 && c == RH) IX[15:8] <= v;
			else if (!plain && pfx == 2'd1 && c == RL) IX[7:0]  <= v;
			else if (!plain && pfx == 2'd2 && c == RH) IY[15:8] <= v;
			else if (!plain && pfx == 2'd2 && c == RL) IY[7:0]  <= v;
			else                                       R[c]     <= v;
		end
	endtask

	// Register pairs, with the prefix substituting HL. Pair 3 is SP for the
	// arithmetic forms and AF for push and pop, so the caller says which.
	function [15:0] rp16;
		input [1:0] p;
		input       af;
		case (p)
		2'd0:    rp16 = {R[RB], R[RC]};
		2'd1:    rp16 = {R[RD], R[RE]};
		2'd2:    rp16 = IDX;
		default: rp16 = af ? {R[RA], F} : SP;
		endcase
	endfunction

	task wr_rp16;
		input [1:0] p;
		input [15:0] v;
		input        af;
		begin
			case (p)
			2'd0: begin R[RB] <= v[15:8]; R[RC] <= v[7:0]; end
			2'd1: begin R[RD] <= v[15:8]; R[RE] <= v[7:0]; end
			2'd2: if (pfx == 2'd1) IX <= v;
			      else if (pfx == 2'd2) IY <= v;
			      else begin R[RH] <= v[15:8]; R[RL] <= v[7:0]; end
			default: if (af) begin R[RA] <= v[15:8]; F <= v[7:0]; end
			         else SP <= v;
			endcase
		end
	endtask

	function parity8;
		input [7:0] v;
		parity8 = ~^v;
	endfunction

	// --- ALU ----------------------------------------------------------------------
	reg [7:0]  alu_r, alu_f;
	reg [15:0] alu16;

	task do_alu;
		input [2:0] kind;
		input [7:0] a;
		input [7:0] b;
		reg [8:0] s;
		reg       cin;
		reg [7:0] res;
		begin
			cin = (kind == 3'd1 || kind == 3'd3) ? F[FC] : 1'b0;
			case (kind)
			3'd0, 3'd1: begin
				s = {1'b0, a} + {1'b0, b} + {8'd0, cin};
				res = s[7:0];
				alu_f[FH] = a[4] ^ b[4] ^ res[4];
				alu_f[FP] = (~(a[7] ^ b[7])) & (a[7] ^ res[7]);
				alu_f[FN] = 1'b0;
				alu_f[FC] = s[8];
			end
			3'd2, 3'd3, 3'd7: begin
				s = {1'b0, a} - {1'b0, b} - {8'd0, cin};
				res = s[7:0];
				alu_f[FH] = a[4] ^ b[4] ^ res[4];
				alu_f[FP] = (a[7] ^ b[7]) & (a[7] ^ res[7]);
				alu_f[FN] = 1'b1;
				alu_f[FC] = s[8];
			end
			3'd4: begin res = a & b;
				alu_f[FH] = 1'b1; alu_f[FN] = 1'b0; alu_f[FC] = 1'b0;
				alu_f[FP] = parity8(res); end
			3'd5: begin res = a ^ b;
				alu_f[FH] = 1'b0; alu_f[FN] = 1'b0; alu_f[FC] = 1'b0;
				alu_f[FP] = parity8(res); end
			default: begin res = a | b;
				alu_f[FH] = 1'b0; alu_f[FN] = 1'b0; alu_f[FC] = 1'b0;
				alu_f[FP] = parity8(res); end
			endcase

			alu_f[FS] = res[7];
			alu_f[FZ] = (res == 8'd0);
			// CP throws the result away and takes its undocumented bits from the
			// operand instead. Everything else takes them from the result.
			if (kind == 3'd7) begin
				alu_f[FY] = b[5];  alu_f[FX] = b[3];  alu_r = a;
			end else begin
				alu_f[FY] = res[5]; alu_f[FX] = res[3]; alu_r = res;
			end
		end
	endtask

	task do_rot;
		input [2:0] kind;        // 0 RLC 1 RRC 2 RL 3 RR 4 SLA 5 SRA 6 SLL 7 SRL
		input [7:0] v;
		reg [7:0] res;
		reg       cout;
		begin
			case (kind)
			3'd0: begin res = {v[6:0], v[7]};    cout = v[7]; end
			3'd1: begin res = {v[0], v[7:1]};    cout = v[0]; end
			3'd2: begin res = {v[6:0], F[FC]};   cout = v[7]; end
			3'd3: begin res = {F[FC], v[7:1]};   cout = v[0]; end
			3'd4: begin res = {v[6:0], 1'b0};    cout = v[7]; end
			3'd5: begin res = {v[7], v[7:1]};    cout = v[0]; end
			// SLL is undocumented, shifts a one in at the bottom, and is tested.
			3'd6: begin res = {v[6:0], 1'b1};    cout = v[7]; end
			default: begin res = {1'b0, v[7:1]}; cout = v[0]; end
			endcase
			alu_r = res;
			alu_f = {res[7], res == 8'd0, res[5], 1'b0, res[3],
			         parity8(res), 1'b0, cout};
		end
	endtask

	task do_inc;
		input [7:0] v;
		reg [7:0] res;
		begin
			res = v + 8'd1;
			alu_r = res;
			alu_f = {res[7], res == 8'd0, res[5], v[3:0] == 4'hF, res[3],
			         v == 8'h7F, 1'b0, F[FC]};
		end
	endtask

	task do_dec;
		input [7:0] v;
		reg [7:0] res;
		begin
			res = v - 8'd1;
			alu_r = res;
			alu_f = {res[7], res == 8'd0, res[5], v[3:0] == 4'h0, res[3],
			         v == 8'h80, 1'b1, F[FC]};
		end
	endtask

	// ADD HL,ss leaves S, Z and P alone and takes the half-carry from bit 11.
	task do_add16;
		input [15:0] a;
		input [15:0] b;
		reg [16:0] s;
		begin
			s = {1'b0, a} + {1'b0, b};
			alu16 = s[15:0];
			alu_f = {F[FS], F[FZ], s[13], a[12] ^ b[12] ^ s[12], s[11],
			         F[FP], 1'b0, s[16]};
		end
	endtask

	task do_adc16;
		input [15:0] a;
		input [15:0] b;
		input        addsub;      // 1 = ADC, 0 = SBC
		reg [16:0] s;
		begin
			if (addsub) s = {1'b0, a} + {1'b0, b} + {16'd0, F[FC]};
			else        s = {1'b0, a} - {1'b0, b} - {16'd0, F[FC]};
			alu16 = s[15:0];
			alu_f[FS] = s[15];
			alu_f[FZ] = (s[15:0] == 16'd0);
			alu_f[FY] = s[13];
			alu_f[FH] = a[12] ^ b[12] ^ s[12];
			alu_f[FX] = s[11];
			alu_f[FP] = addsub ? ((~(a[15] ^ b[15])) & (a[15] ^ s[15]))
			                   : (( (a[15] ^ b[15])) & (a[15] ^ s[15]));
			alu_f[FN] = ~addsub;
			alu_f[FC] = s[16];
		end
	endtask

	// DAA repairs a binary result into packed BCD, using H and N to know what
	// the preceding operation did. There is no way to derive this; it is a
	// table in the silicon and a table here.
	task do_daa;
		input [7:0] a;
		reg [7:0] adj;
		reg       cout;
		reg [7:0] res;
		begin
			adj  = 8'd0;
			cout = F[FC];
			if (F[FH] || (a[3:0] > 4'd9)) adj = 8'h06;
			if (F[FC] || (a > 8'h99)) begin adj = adj | 8'h60; cout = 1'b1; end
			res = F[FN] ? (a - adj) : (a + adj);
			alu_r = res;
			alu_f = {res[7], res == 8'd0, res[5],
			         F[FN] ? (F[FH] && (a[3:0] < 4'd6)) : (a[3:0] > 4'd9),
			         res[3], parity8(res), F[FN], cout};
		end
	endtask

	function cond_met;
		input [2:0] c;
		case (c)
		3'd0: cond_met = ~F[FZ];   3'd1: cond_met =  F[FZ];
		3'd2: cond_met = ~F[FC];   3'd3: cond_met =  F[FC];
		3'd4: cond_met = ~F[FP];   3'd5: cond_met =  F[FP];
		3'd6: cond_met = ~F[FS];   default: cond_met = F[FS];
		endcase
	endfunction

	reg nmi_prev, nmi_pending;
	reg [7:0] cbv;
	// Scratch for the block instructions, assigned blocking so the flag
	// expressions below can use the updated values in the same cycle.
	reg [7:0]  blkn, blkb, blkd;
	reg [15:0] hlx, dex, bcx;
	integer i;

	always @(posedge clk) begin
		if (rst) begin
			st <= S_RESET; cont <= C_NONE; after <= C_NONE; ret_st <= S_FETCH;
			PC <= 16'd0; SP <= 16'hFFFF; F <= 8'd0; Fs <= 8'd0;
			IX <= 16'd0; IY <= 16'd0; I <= 8'd0; Rr <= 8'd0;
			IFF1 <= 1'b0; IFF2 <= 1'b0; IM <= 2'd0; halted <= 1'b0;
			pfx <= 2'd0; cb <= 1'b0; ed <= 1'b0;
			we <= 1'b0; io <= 1'b0; m1 <= 1'b0; addr <= 16'd0; dout <= 8'd0;
			nmi_prev <= 1'b1; nmi_pending <= 1'b0;
			wz <= 16'd0; tmp <= 8'd0; tmp2 <= 8'd0;
			dst <= 3'd0; alukind <= 3'd0; incdec <= 1'b0; taken <= 1'b0;
			op <= 8'd0; blkn <= 8'd0; blkb <= 8'd0; blkd <= 8'd0;
			hlx <= 16'd0; dex <= 16'd0; bcx <= 16'd0;
			for (i = 0; i < 8; i = i + 1) begin R[i] <= 8'd0; Rs[i] <= 8'd0; end
		end else if (ce) begin
			we <= 1'b0;
			io <= 1'b0;
			m1 <= 1'b0;

			nmi_prev <= nmi_n;
			if (nmi_prev && !nmi_n) nmi_pending <= 1'b1;

			case (st)
			S_RESET: begin
				PC <= 16'd0; SP <= 16'hFFFF;
				IFF1 <= 1'b0; IFF2 <= 1'b0; IM <= 2'd0;
				st <= S_FETCH;
			end

			S_FETCH: begin
				if (nmi_pending && !cb && !ed && pfx == 2'd0) begin
					nmi_pending <= 1'b0; halted <= 1'b0;
					IFF2 <= IFF1; IFF1 <= 1'b0;
					wz <= 16'h0066;
					st <= S_INT;
				end else if (!int_n && IFF1 && !cb && !ed && pfx == 2'd0) begin
					halted <= 1'b0;
					IFF1 <= 1'b0; IFF2 <= 1'b0;
					// Mode 1 only, which is what the Master System uses. Modes 0
					// and 2 land on the same restart rather than doing nothing
					// silently.
					wz <= 16'h0038;
					st <= S_INT;
				end else if (halted) begin
					st <= S_HALT;
				end else begin
					addr <= PC;
					m1   <= 1'b1;
					PC   <= PC + 16'd1;
					Rr   <= {Rr[7], Rr[6:0] + 7'd1};   // bit 7 does not count
					st   <= S_FETCHW;
				end
			end

			S_FETCHW: st <= S_FETCH2;
			S_FETCH2: begin op <= din; st <= S_EXEC; end

			// --- shared operand gathering -------------------------------------
			S_IMM:   begin addr <= PC; PC <= PC + 16'd1; st <= S_IMMW_; end
			S_IMMW_: st <= S_IMM2;
			S_IMM2:  begin tmp <= din; st <= ret_st; end

			// Present, wait, CONSUME, then present the next -- never present a
			// second address before the first byte has been taken.
			//
			// The old order presented both addresses and then read both bytes,
			// which only works if memory answers in exactly one enable cycle.
			// Give the CPU a slow clock enable against memory that is clocked
			// faster -- which is exactly what happens inside the Master System
			// -- and the second address lands before the first byte is read, so
			// both reads return the second byte. Every 16-bit immediate came
			// back as its own high half, which meant every JP and every LD dd,nn
			// went to the wrong place.
			S_IMMW:  begin addr <= PC; PC <= PC + 16'd1; st <= S_IMMW2; end
			S_IMMW2: st <= S_IMMW3;
			S_IMMW3: begin
				wz[7:0] <= din;
				addr <= PC; PC <= PC + 16'd1;
				st <= S_IMMW4;
			end
			S_IMMW4: st <= S_IMMW5;
			S_IMMW5: begin wz[15:8] <= din; st <= ret_st; end

			S_MRD:   begin addr <= wz; st <= S_MRDW_; end
			S_MRDW_: st <= S_MRD2;
			S_MRD2:  begin tmp <= din; st <= ret_st; end

			S_MWR:  begin addr <= wz; dout <= tmp; we <= 1'b1; st <= ret_st; end

			S_MRDW:  begin addr <= wz;         st <= S_MRDW2; end
			S_MRDW2: st <= S_MRDW3;
			S_MRDW3: begin tmp <= din; addr <= wz + 16'd1; st <= S_MRDW4; end
			S_MRDW4: st <= S_MRDW5;
			S_MRDW5: begin tmp2 <= din; st <= ret_st; end

			S_MWRW:  begin addr <= wz;         dout <= tmp;  we <= 1'b1; st <= S_MWRW2; end
			S_MWRW2: begin addr <= wz + 16'd1; dout <= tmp2; we <= 1'b1; st <= ret_st;  end

			S_PUSH1: begin SP <= SP - 16'd1; addr <= SP - 16'd1;
			               dout <= tmp2; we <= 1'b1; st <= S_PUSH2; end
			S_PUSH2: begin SP <= SP - 16'd1; addr <= SP - 16'd1;
			               dout <= tmp;  we <= 1'b1; st <= ret_st;  end

			S_POP1: begin addr <= SP;      st <= S_POP2; end
			S_POP2: st <= S_POP3;
			S_POP3: begin tmp <= din; addr <= SP + 16'd1; st <= S_POP4; end
			S_POP4: st <= S_POP5;
			S_POP5: begin tmp2 <= din; SP <= SP + 16'd2; st <= ret_st; end

			S_IORD:  begin addr <= wz; io <= 1'b1; st <= S_IORDW; end
			S_IORDW: st <= S_IORD2;
			S_IORD2: begin tmp <= din; st <= ret_st; end
			S_IOWR:  begin addr <= wz; dout <= tmp; io <= 1'b1; we <= 1'b1;
			               st <= ret_st; end

			S_HALT: if (nmi_pending || (!int_n && IFF1)) begin
					halted <= 1'b0; st <= S_FETCH;
				end

			S_INT: begin
				tmp <= PC[7:0]; tmp2 <= PC[15:8];
				ret_st <= S_INT2;
				st <= S_PUSH1;
			end
			S_INT2: begin PC <= wz; st <= S_FETCH; end

			// --- decode, or resume ---------------------------------------------
			S_EXEC: begin
				// Defaults for "this instruction is finished": go back for the
				// next opcode, with no continuation and no prefix page in
				// effect. Both branches below override what they need.
				//
				// The prefix clearing has to live HERE and not in the decode
				// branch. A multi-cycle prefixed instruction keeps its prefix
				// alive across the continuation and finishes in the resume
				// branch, so clearing it only on the way into a decode leaves
				// it set -- and the NEXT opcode gets decoded as a CB opcode.
				// The reads of pfx/cb/ed inside both branches still see the
				// current values, because these are nonblocking.
				st   <= S_FETCH;
				cont <= C_NONE;
				pfx  <= 2'd0;
				cb   <= 1'b0;
				ed   <= 1'b0;

				if (cont != C_NONE) begin
`include "z80_resume.vh"
				end else begin
`include "z80_decode.vh"
				end
			end

			default: st <= S_FETCH;
			endcase
		end
	end

endmodule

`default_nettype wire
