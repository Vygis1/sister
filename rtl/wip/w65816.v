//////////////////////////////////////////////////////////////////////////////////
// w65816.v - the SNES's CPU core, the WDC 65C816, cycle by cycle.
//
// Written from the WDC data sheet and Fullsnes, to the same bus order as the model
// tools/snes/w65816.py, and checked against the SingleStepTests 65816 suite one bus
// cycle at a time (sim/tb_w65816.v, tools/snes/sst2vec.py): address, data, read /
// write / internal, and the registers and memory after.
//
// --- the bus -------------------------------------------------------------------------
// One CPU cycle per `ce`. The cycle in progress is described by the outputs, which are
// a function of the registered state only, so they hold still for the whole cycle and
// the system can pick its length from them (the SNES: 6, 8 or 12 master clocks by
// address, 6 for an internal cycle). At `ce` the cycle ends and a read takes `din`.
//
//   vda vpa   0 0  internal cycle (no access; addr is don't-care)
//             1 1  opcode fetch     0 1  operand fetch     1 0  data
//   we        1 on a write cycle (dout valid)
//
// Interrupts: `nmi` is an edge (a one-clock pulse, taken at the next instruction
// boundary); `irq` is a level, taken when I is clear. Either ends WAI. An interrupt
// replaces an opcode fetch: that cycle's read is thrown away, one internal cycle
// follows, then the pushes, as the chip does.
//
// Emulation-mode quirks follow the model, and gilyon's hardware-checked cputest where
// it and SingleStepTests disagree: (d,X) wraps its pointer's high byte in its page;
// JSR (a,X) pushes out of page 1 like the other new instructions.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module w65816 (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,
	output reg  [23:0] addr,
	output reg  [7:0]  dout,
	output reg         we,
	output reg         vda,
	output reg         vpa,
	input  wire [7:0]  din,
	input  wire        nmi,
	input  wire        irq,
	output wire        e_flag,
	output wire        m_flag,
	output wire        x_flag,
	output wire        sync,          // this cycle fetches an opcode
	output wire [15:0] dbg_pc,
	output wire [7:0]  dbg_pbr
);
	// --- registers --------------------------------------------------------------------
	reg [15:0] A, X, Y, S, D, PC;
	reg [7:0]  DBR, PBR, P;
	reg        E;
	wire m8 = P[5];
	wire x8 = P[4];
	assign e_flag = E; assign m_flag = m8; assign x_flag = x8;
	assign dbg_pc = PC; assign dbg_pbr = PBR;

	localparam FC = 0, FZ = 1, FI = 2, FD = 3, FX = 4, FM = 5, FV = 6, FN = 7;

	// --- states (one bus cycle each) ---------------------------------------------------
	localparam [5:0]
		S_FETCH = 6'd0,
		S_OP1 = 6'd1, S_OP2 = 6'd2, S_OP3 = 6'd3,
		S_IODL = 6'd4,          // the cycle a non-zero D low byte costs
		S_IOX = 6'd5,           // d,X / d,Y / (d,X): the index add
		S_IOP = 6'd6,           // a,X / a,Y / (d),Y: the page / width penalty
		S_PLO = 6'd7, S_PHI = 6'd8, S_PBK = 6'd9,    // an operand pointer
		S_IOS = 6'd10,          // sr,S: the add
		S_IOS2 = 6'd11,         // (sr,S),Y: after the pointer
		S_RLO = 6'd12, S_RHI = 6'd13,
		S_WLO = 6'd14, S_WHI = 6'd15,
		S_MIO = 6'd16,          // read-modify-write: the modify
		S_MWHI = 6'd17, S_MWLO = 6'd18,
		S_IO1 = 6'd19, S_IO2 = 6'd20,                // implied ops
		S_BR1 = 6'd21, S_BR2 = 6'd22,
		S_PUSH_HI = 6'd23, S_PUSH_LO = 6'd24, S_PUSH_BK = 6'd25, S_PUSH_P = 6'd26,
		S_PULL_LO = 6'd27, S_PULL_HI = 6'd28, S_PULL_BK = 6'd29, S_PULL_P = 6'd30,
		S_SQ_IO = 6'd31, S_SQ_IO2 = 6'd32, S_SQ_IO3 = 6'd33,
		S_VEC_LO = 6'd34, S_VEC_HI = 6'd35,
		S_JRD_LO = 6'd36, S_JRD_HI = 6'd37, S_JRD_BK = 6'd38,   // a pointer to jump through
		S_MV_R = 6'd39, S_MV_W = 6'd40, S_MV_IO1 = 6'd41, S_MV_IO2 = 6'd42,
		S_WAIT = 6'd43,
		S_INT_IO = 6'd44,
		S_JSL_OP3 = 6'd45,
		S_PER_IO = 6'd46,
		S_RTS_IO = 6'd47;
	reg [5:0] st;

	// --- the instruction ---------------------------------------------------------------
	reg [7:0]  ir;
	reg [7:0]  o1, o2, o3;          // operand bytes
	reg [23:0] ea;                  // the data's address
	reg [1:0]  ew;                  // its second byte: 0 24-bit carry, 1 bank 0, 2 page
	reg [15:0] dat;                 // data read / to write; a pointer's bytes on the way
	reg [15:0] ptr;                 // the address of a pointer being read (bank ptrb)
	reg [7:0]  ptrb;
	reg [15:0] push_val;            // what a sequence pushes, high byte first
	reg [7:0]  vec_lo;              // the vector's low address byte (FFxx, bank 0)
	reg        brk_sw;              // BRK / COP: B pushed set in emulation mode
	reg        stopped, waiting;
	reg        nmi_pend;
	reg        new_stk;             // this instruction's stack may leave page 1

	wire [23:0] ea2 = (ew == 2'd0) ? ea + 24'd1 :
	                  (ew == 2'd1) ? {8'h00, ea[15:0] + 16'd1} :
	                                 {ea[23:8], ea[7:0] + 8'd1};

	// --- decode --------------------------------------------------------------------------
	localparam [4:0]
		AM_IMM = 5'd1, AM_DP = 5'd2, AM_DPX = 5'd3, AM_DPY = 5'd4,
		AM_ABS = 5'd5, AM_ABSX = 5'd6, AM_ABSY = 5'd7, AM_LONG = 5'd8, AM_LONGX = 5'd9,
		AM_IND = 5'd10, AM_INDX = 5'd11, AM_INDY = 5'd12, AM_INDL = 5'd13, AM_INDLY = 5'd14,
		AM_SR = 5'd15, AM_SRY = 5'd16, AM_SPECIAL = 5'd17;
	localparam [1:0] K_READ = 2'd0, K_WRITE = 2'd1, K_RMW = 2'd2, K_NONE = 2'd3;
	localparam [4:0]
		O_ORA = 5'd0, O_AND = 5'd1, O_EOR = 5'd2, O_ADC = 5'd3, O_STA = 5'd4, O_LDA = 5'd5,
		O_CMP = 5'd6, O_SBC = 5'd7, O_LDX = 5'd8, O_LDY = 5'd9, O_CPX = 5'd10, O_CPY = 5'd11,
		O_BIT = 5'd12, O_STX = 5'd13, O_STY = 5'd14, O_STZ = 5'd15, O_ASL = 5'd16,
		O_ROL = 5'd17, O_LSR = 5'd18, O_ROR = 5'd19, O_INC = 5'd20, O_DEC = 5'd21,
		O_TSB = 5'd22, O_TRB = 5'd23, O_BITI = 5'd24, O_NONE = 5'd31;

	reg [4:0] am;
	reg [1:0] kind;
	reg [4:0] op;
	reg       xw;                  // the width is X's, not M's
	always @(*) begin
		am = AM_SPECIAL; kind = K_NONE; op = O_NONE; xw = 1'b0;
		case (ir[4:0])
		5'h01: am = AM_INDX; 5'h03: am = AM_SR; 5'h05: am = AM_DP; 5'h07: am = AM_INDL;
		5'h09: am = AM_IMM; 5'h0D: am = AM_ABS; 5'h0F: am = AM_LONG; 5'h11: am = AM_INDY;
		5'h12: am = AM_IND; 5'h13: am = AM_SRY; 5'h15: am = AM_DPX; 5'h17: am = AM_INDLY;
		5'h19: am = AM_ABSY; 5'h1D: am = AM_ABSX; 5'h1F: am = AM_LONGX;
		default: am = AM_SPECIAL;
		endcase
		if (am != AM_SPECIAL) begin
			op = {2'd0, ir[7:5]};
			kind = (ir[7:5] == 3'd4) ? K_WRITE : K_READ;
			if (ir == 8'h89) op = O_BITI;
		end
		case (ir)
		8'h06: begin am = AM_DP;   kind = K_RMW; op = O_ASL; end
		8'h0E: begin am = AM_ABS;  kind = K_RMW; op = O_ASL; end
		8'h16: begin am = AM_DPX;  kind = K_RMW; op = O_ASL; end
		8'h1E: begin am = AM_ABSX; kind = K_RMW; op = O_ASL; end
		8'h26: begin am = AM_DP;   kind = K_RMW; op = O_ROL; end
		8'h2E: begin am = AM_ABS;  kind = K_RMW; op = O_ROL; end
		8'h36: begin am = AM_DPX;  kind = K_RMW; op = O_ROL; end
		8'h3E: begin am = AM_ABSX; kind = K_RMW; op = O_ROL; end
		8'h46: begin am = AM_DP;   kind = K_RMW; op = O_LSR; end
		8'h4E: begin am = AM_ABS;  kind = K_RMW; op = O_LSR; end
		8'h56: begin am = AM_DPX;  kind = K_RMW; op = O_LSR; end
		8'h5E: begin am = AM_ABSX; kind = K_RMW; op = O_LSR; end
		8'h66: begin am = AM_DP;   kind = K_RMW; op = O_ROR; end
		8'h6E: begin am = AM_ABS;  kind = K_RMW; op = O_ROR; end
		8'h76: begin am = AM_DPX;  kind = K_RMW; op = O_ROR; end
		8'h7E: begin am = AM_ABSX; kind = K_RMW; op = O_ROR; end
		8'hE6: begin am = AM_DP;   kind = K_RMW; op = O_INC; end
		8'hEE: begin am = AM_ABS;  kind = K_RMW; op = O_INC; end
		8'hF6: begin am = AM_DPX;  kind = K_RMW; op = O_INC; end
		8'hFE: begin am = AM_ABSX; kind = K_RMW; op = O_INC; end
		8'hC6: begin am = AM_DP;   kind = K_RMW; op = O_DEC; end
		8'hCE: begin am = AM_ABS;  kind = K_RMW; op = O_DEC; end
		8'hD6: begin am = AM_DPX;  kind = K_RMW; op = O_DEC; end
		8'hDE: begin am = AM_ABSX; kind = K_RMW; op = O_DEC; end
		8'h04: begin am = AM_DP;   kind = K_RMW; op = O_TSB; end
		8'h0C: begin am = AM_ABS;  kind = K_RMW; op = O_TSB; end
		8'h14: begin am = AM_DP;   kind = K_RMW; op = O_TRB; end
		8'h1C: begin am = AM_ABS;  kind = K_RMW; op = O_TRB; end
		8'h24: begin am = AM_DP;   kind = K_READ; op = O_BIT; end
		8'h2C: begin am = AM_ABS;  kind = K_READ; op = O_BIT; end
		8'h34: begin am = AM_DPX;  kind = K_READ; op = O_BIT; end
		8'h3C: begin am = AM_ABSX; kind = K_READ; op = O_BIT; end
		8'hA2: begin am = AM_IMM;  kind = K_READ; op = O_LDX; xw = 1'b1; end
		8'hA6: begin am = AM_DP;   kind = K_READ; op = O_LDX; xw = 1'b1; end
		8'hAE: begin am = AM_ABS;  kind = K_READ; op = O_LDX; xw = 1'b1; end
		8'hB6: begin am = AM_DPY;  kind = K_READ; op = O_LDX; xw = 1'b1; end
		8'hBE: begin am = AM_ABSY; kind = K_READ; op = O_LDX; xw = 1'b1; end
		8'hA0: begin am = AM_IMM;  kind = K_READ; op = O_LDY; xw = 1'b1; end
		8'hA4: begin am = AM_DP;   kind = K_READ; op = O_LDY; xw = 1'b1; end
		8'hAC: begin am = AM_ABS;  kind = K_READ; op = O_LDY; xw = 1'b1; end
		8'hB4: begin am = AM_DPX;  kind = K_READ; op = O_LDY; xw = 1'b1; end
		8'hBC: begin am = AM_ABSX; kind = K_READ; op = O_LDY; xw = 1'b1; end
		8'h86: begin am = AM_DP;   kind = K_WRITE; op = O_STX; xw = 1'b1; end
		8'h8E: begin am = AM_ABS;  kind = K_WRITE; op = O_STX; xw = 1'b1; end
		8'h96: begin am = AM_DPY;  kind = K_WRITE; op = O_STX; xw = 1'b1; end
		8'h84: begin am = AM_DP;   kind = K_WRITE; op = O_STY; xw = 1'b1; end
		8'h8C: begin am = AM_ABS;  kind = K_WRITE; op = O_STY; xw = 1'b1; end
		8'h94: begin am = AM_DPX;  kind = K_WRITE; op = O_STY; xw = 1'b1; end
		8'hE0: begin am = AM_IMM;  kind = K_READ; op = O_CPX; xw = 1'b1; end
		8'hE4: begin am = AM_DP;   kind = K_READ; op = O_CPX; xw = 1'b1; end
		8'hEC: begin am = AM_ABS;  kind = K_READ; op = O_CPX; xw = 1'b1; end
		8'hC0: begin am = AM_IMM;  kind = K_READ; op = O_CPY; xw = 1'b1; end
		8'hC4: begin am = AM_DP;   kind = K_READ; op = O_CPY; xw = 1'b1; end
		8'hCC: begin am = AM_ABS;  kind = K_READ; op = O_CPY; xw = 1'b1; end
		8'h64: begin am = AM_DP;   kind = K_WRITE; op = O_STZ; end
		8'h74: begin am = AM_DPX;  kind = K_WRITE; op = O_STZ; end
		8'h9C: begin am = AM_ABS;  kind = K_WRITE; op = O_STZ; end
		8'h9E: begin am = AM_ABSX; kind = K_WRITE; op = O_STZ; end
		default: ;
		endcase
	end

	wire w8 = xw ? x8 : m8;
	wire dp_mode = (am == AM_DP || am == AM_DPX || am == AM_DPY || am == AM_IND ||
	                am == AM_INDX || am == AM_INDY || am == AM_INDL || am == AM_INDLY);
	wire idx_y = (am == AM_DPY || am == AM_ABSY || am == AM_INDY || am == AM_INDLY || am == AM_SRY);
	wire [15:0] ix = idx_y ? Y : X;
	wire        dl0 = (D[7:0] == 8'h00);
	wire [15:0] store_val = (op == O_STA) ? A : (op == O_STX) ? X : (op == O_STY) ? Y : 16'h0000;
	wire [5:0]  data_st = (kind == K_WRITE) ? S_WLO : S_RLO;    // after the address

	// --- decimal / binary add and subtract (all inputs passed: xsim-safe) --------------------
	// returns {V, C, result[15:0]}
	function [17:0] addsub;
		input [15:0] a, b;
		input        cin, dec, eight, sub;
		reg   [15:0] bb, res, pre;
		reg   [16:0] bin;
		reg   [5:0]  dg;
		reg          c, v, bw;
		integer      k;
		begin
			bb  = sub ? ~b : b;
			bin = eight ? ({9'd0, a[7:0]} + {9'd0, bb[7:0]} + {16'd0, cin})
			            : ({1'b0, a} + {1'b0, bb} + {16'd0, cin});
			c   = eight ? bin[8] : bin[16];
			v   = eight ? (~(a[7] ^ bb[7]) & (a[7] ^ bin[7])) : (~(a[15] ^ bb[15]) & (a[15] ^ bin[15]));
			res = bin[15:0];
			if (dec && sub) begin            // digit by digit with a borrow; C and V binary
				res = 16'd0;
				bw  = ~cin;
				for (k = 0; k < 4; k = k + 1) begin
					if (!eight || k < 2) begin
						dg = {2'b00, a[k*4 +: 4]} - {2'b00, b[k*4 +: 4]} - {5'd0, bw};
						bw = dg[5];                          // (the borrow out, before the adjust)
						if (bw) dg = dg - 6'd6;
						res[k*4 +: 4] = dg[3:0];
					end
				end
			end else if (dec) begin          // digit by digit with a carry; V before the top adjust
				res = 16'd0; pre = 16'd0; c = cin;
				for (k = 0; k < 4; k = k + 1) begin
					if (!eight || k < 2) begin
						dg = {2'b00, a[k*4 +: 4]} + {2'b00, b[k*4 +: 4]} + {5'd0, c};
						pre[k*4 +: 4] = dg[3:0];
						if (dg > 6'd9) dg = dg + 6'd6;     // (up to 37: six bits)
						c = (dg > 6'd15);
						res[k*4 +: 4] = dg[3:0];
					end
				end
				if (eight) v = ~(a[7] ^ b[7]) & (a[7] ^ pre[7]);
				else       v = ~(a[15] ^ b[15]) & (a[15] ^ pre[15]);
			end
			if (eight) res[15:8] = 8'h00;
			addsub = {v, c, res};
		end
	endfunction

	// --- executing a read op: the value and the results, combinational -----------------------
	reg  [15:0] rv;                  // the operand, by the state it arrives in
	always @(*) begin
		case (st)
		S_OP2:   rv = {din, o1};
		S_RHI:   rv = {din, dat[7:0]};
		default: rv = {8'h00, din};          // S_OP1 (8-bit immediate), S_RLO (8-bit)
		endcase
	end
	wire [15:0] accv = m8 ? {8'h00, A[7:0]} : A;
	wire [17:0] as_r = addsub(accv, rv, P[FC], P[FD], m8, op == O_SBC);
	reg  [15:0] ex_A, ex_X, ex_Y;
	reg  [7:0]  ex_P;
	reg  [15:0] ex_r, ex_reg;
	reg  [16:0] ex_cmp;
	always @(*) begin
		ex_A = A; ex_X = X; ex_Y = Y; ex_P = P;
		ex_r = 16'd0; ex_reg = 16'd0; ex_cmp = 17'd0;
		case (op)
		O_ORA, O_AND, O_EOR, O_LDA, O_ADC, O_SBC: begin
			case (op)
			O_ORA: ex_r = accv | rv;
			O_AND: ex_r = accv & rv;
			O_EOR: ex_r = accv ^ rv;
			O_LDA: ex_r = rv;
			default: begin ex_r = as_r[15:0]; ex_P[FC] = as_r[16]; ex_P[FV] = as_r[17]; end
			endcase
			if (m8) begin ex_A[7:0] = ex_r[7:0]; ex_P[FN] = ex_r[7]; ex_P[FZ] = (ex_r[7:0] == 8'h00); end
			else    begin ex_A = ex_r;           ex_P[FN] = ex_r[15]; ex_P[FZ] = (ex_r == 16'h0000); end
		end
		O_LDX, O_LDY: begin
			ex_r = x8 ? {8'h00, rv[7:0]} : rv;
			if (op == O_LDX) ex_X = ex_r; else ex_Y = ex_r;
			ex_P[FN] = x8 ? ex_r[7] : ex_r[15];
			ex_P[FZ] = x8 ? (ex_r[7:0] == 8'h00) : (ex_r == 16'h0000);
		end
		O_CMP, O_CPX, O_CPY: begin
			ex_reg = (op == O_CMP) ? accv : (op == O_CPX) ? X : Y;
			if (w8) begin
				ex_cmp = {9'd0, ex_reg[7:0]} - {9'd0, rv[7:0]};
				ex_P[FC] = !ex_cmp[8]; ex_P[FN] = ex_cmp[7]; ex_P[FZ] = (ex_cmp[7:0] == 8'h00);
			end else begin
				ex_cmp = {1'b0, ex_reg} - {1'b0, rv};
				ex_P[FC] = !ex_cmp[16]; ex_P[FN] = ex_cmp[15]; ex_P[FZ] = (ex_cmp[15:0] == 16'h0000);
			end
		end
		O_BIT: begin
			if (m8) begin ex_P[FZ] = ((A[7:0] & rv[7:0]) == 8'h00); ex_P[FN] = rv[7];  ex_P[FV] = rv[6]; end
			else    begin ex_P[FZ] = ((A & rv) == 16'h0000);         ex_P[FN] = rv[15]; ex_P[FV] = rv[14]; end
		end
		O_BITI: ex_P[FZ] = m8 ? ((A[7:0] & rv[7:0]) == 8'h00) : ((A & rv) == 16'h0000);
		default: ;
		endcase
	end

	// --- read-modify-write and the accumulator forms -------------------------------------------
	reg [15:0] rmw_r;
	reg        rmw_c;
	always @(*) begin
		rmw_r = dat; rmw_c = P[FC];
		case (op)
		O_ASL: begin rmw_r = {dat[14:0], 1'b0}; rmw_c = w8 ? dat[7] : dat[15]; end
		O_LSR: begin rmw_r = w8 ? {9'h000, dat[7:1]} : {1'b0, dat[15:1]}; rmw_c = dat[0]; end
		O_ROL: begin rmw_r = {dat[14:0], P[FC]}; rmw_c = w8 ? dat[7] : dat[15]; end
		O_ROR: begin rmw_r = w8 ? {8'h00, P[FC], dat[7:1]} : {P[FC], dat[15:1]}; rmw_c = dat[0]; end
		O_INC: rmw_r = dat + 16'd1;
		O_DEC: rmw_r = dat - 16'd1;
		O_TSB: rmw_r = dat | accv;
		O_TRB: rmw_r = dat & ~accv;
		default: ;
		endcase
		if (w8) rmw_r[15:8] = 8'h00;
	end
	wire rmw_tz = w8 ? ((dat[7:0] & A[7:0]) == 8'h00) : ((dat & A) == 16'h0000);

	reg [15:0] acc_r;
	reg        acc_c;
	always @(*) begin
		acc_r = accv; acc_c = P[FC];
		case (ir)
		8'h0A: begin acc_r = {accv[14:0], 1'b0}; acc_c = m8 ? accv[7] : accv[15]; end
		8'h4A: begin acc_r = m8 ? {9'h000, accv[7:1]} : {1'b0, accv[15:1]}; acc_c = accv[0]; end
		8'h2A: begin acc_r = {accv[14:0], P[FC]}; acc_c = m8 ? accv[7] : accv[15]; end
		8'h6A: begin acc_r = m8 ? {8'h00, P[FC], accv[7:1]} : {P[FC], accv[15:1]}; acc_c = accv[0]; end
		8'h1A: acc_r = accv + 16'd1;
		8'h3A: acc_r = accv - 16'd1;
		default: ;
		endcase
		if (m8) acc_r[15:8] = 8'h00;
	end

	reg br_take;
	always @(*) begin
		case (ir)
		8'h10: br_take = !P[FN]; 8'h30: br_take = P[FN];
		8'h50: br_take = !P[FV]; 8'h70: br_take = P[FV];
		8'h90: br_take = !P[FC]; 8'hB0: br_take = P[FC];
		8'hD0: br_take = !P[FZ]; 8'hF0: br_take = P[FZ];
		default: br_take = 1'b1;          // BRA
		endcase
	end
	wire is_branch = (ir[4:0] == 5'h10) || (ir == 8'h80);

	// --- the stack -------------------------------------------------------------------------
	// (6502 instructions keep S in page 1 in emulation mode; the new ones may leave it and
	// have it put back when they end)
	wire [15:0] s_dec = (E && !new_stk) ? {8'h01, S[7:0] - 8'd1} : S - 16'd1;
	wire [15:0] s_inc = (E && !new_stk) ? {8'h01, S[7:0] + 8'd1} : S + 16'd1;

	// --- the bus: a function of the state -----------------------------------------------------
	always @(*) begin
		addr = {PBR, PC}; dout = 8'h00; we = 1'b0; vda = 1'b0; vpa = 1'b0;
		case (st)
		S_FETCH: begin vda = 1'b1; vpa = 1'b1; end
		S_OP1, S_OP2, S_OP3, S_JSL_OP3: vpa = 1'b1;
		S_PLO, S_PHI, S_PBK, S_JRD_LO, S_JRD_HI, S_JRD_BK: begin addr = {ptrb, ptr}; vda = 1'b1; end
		S_RLO: begin addr = ea;  vda = 1'b1; end
		S_RHI: begin addr = ea2; vda = 1'b1; end
		S_WLO, S_MWLO: begin addr = ea;  vda = 1'b1; we = 1'b1; dout = dat[7:0]; end
		S_WHI, S_MWHI: begin addr = ea2; vda = 1'b1; we = 1'b1; dout = dat[15:8]; end
		S_PUSH_BK: begin addr = {8'h00, S}; vda = 1'b1; we = 1'b1; dout = PBR; end
		S_PUSH_HI: begin addr = {8'h00, S}; vda = 1'b1; we = 1'b1; dout = push_val[15:8]; end
		S_PUSH_LO: begin addr = {8'h00, S}; vda = 1'b1; we = 1'b1; dout = push_val[7:0]; end
		S_PUSH_P:  begin addr = {8'h00, S}; vda = 1'b1; we = 1'b1;
		                 dout = E ? ((P & 8'hEF) | (brk_sw ? 8'h10 : 8'h00)) : P; end
		S_PULL_LO, S_PULL_HI, S_PULL_BK, S_PULL_P: begin addr = {8'h00, s_inc}; vda = 1'b1; end
		S_VEC_LO: begin addr = {16'h00FF, vec_lo};         vda = 1'b1; end
		S_VEC_HI: begin addr = {16'h00FF, vec_lo + 8'd1};  vda = 1'b1; end
		S_MV_R: begin addr = {o2, X}; vda = 1'b1; end
		S_MV_W: begin addr = {o1, Y}; vda = 1'b1; we = 1'b1; dout = dat[7:0]; end
		default: ;          // internal cycles
		endcase
	end
	assign sync = (st == S_FETCH);

	function pen;                    // a,X / a,Y / (d),Y take the extra cycle
		input [15:0] base, idx;
		input        x8f, wr;
		reg   [15:0] s;
		begin
			s = base + idx;
			pen = wr || !x8f || (s[15:8] != base[15:8]);
		end
	endfunction

	wire int_now = nmi_pend || (irq && !P[FI]);
	reg [15:0] t16;
	reg [7:0]  np;

	// --- the machine -------------------------------------------------------------------------
	always @(posedge clk) begin
		if (rst) begin
			E <= 1'b1; P <= 8'h34; S <= 16'h01FF; D <= 16'h0000; DBR <= 8'h00; PBR <= 8'h00;
			X[15:8] <= 8'h00; Y[15:8] <= 8'h00;
			stopped <= 1'b0; waiting <= 1'b0; nmi_pend <= 1'b0; new_stk <= 1'b0;
			vec_lo <= 8'hFC; brk_sw <= 1'b0; ir <= 8'h00;
			st <= S_VEC_LO;              // reset: straight to the vector at FFFC
		end else begin
			if (nmi) nmi_pend <= 1'b1;
			if (ce) begin
			case (st)
			// ===== the opcode ========================================================
			S_FETCH: begin
				new_stk <= 1'b0;
				if (int_now) begin
					// an interrupt in place of this opcode: the read is thrown away
					ir <= 8'h00; brk_sw <= 1'b0;
					vec_lo <= nmi_pend ? (E ? 8'hFA : 8'hEA) : (E ? 8'hFE : 8'hEE);
					if (nmi_pend) nmi_pend <= 1'b0;
					push_val <= PC;
					st <= S_INT_IO;
				end else begin
					ir <= din;
					PC <= PC + 16'd1;
					st <= S_OP1;
					case (din)
					8'h0A, 8'h4A, 8'h2A, 8'h6A, 8'h1A, 8'h3A,
					8'hAA, 8'hA8, 8'h8A, 8'h98, 8'h9B, 8'hBB, 8'hBA, 8'h9A, 8'h1B, 8'h3B, 8'h5B, 8'h7B,
					8'hE8, 8'hC8, 8'hCA, 8'h88,
					8'h18, 8'h38, 8'h58, 8'h78, 8'hB8, 8'hD8, 8'hF8, 8'hFB, 8'hEA, 8'hEB, 8'h42:
						st <= S_IO1;
					8'h48, 8'hDA, 8'h5A, 8'h08, 8'h8B, 8'h4B, 8'h0B,
					8'h68, 8'hFA, 8'h7A, 8'h28, 8'hAB, 8'h2B,
					8'h60, 8'h6B, 8'h40, 8'hCB, 8'hDB:
						st <= S_SQ_IO;
					default: ;
					endcase
					case (din)
					8'h22, 8'hFC, 8'h6B, 8'hAB, 8'h0B, 8'h2B, 8'hF4, 8'hD4, 8'h62: new_stk <= 1'b1;
					default: ;
					endcase
				end
			end
			S_INT_IO: st <= E ? S_PUSH_HI : S_PUSH_BK;

			// ===== operands ==========================================================
			S_OP1: begin
				o1 <= din; PC <= PC + 16'd1;
				if (am == AM_IMM) begin
					if (!w8) st <= S_OP2;
					else begin A <= ex_A; X <= ex_X; Y <= ex_Y; P <= ex_P; st <= S_FETCH; end
				end else if (dp_mode) begin
					ea  <= {8'h00, D + {8'h00, din}}; ew <= 2'd1;
					ptr <= D + {8'h00, din}; ptrb <= 8'h00;
					dat <= store_val;
					if (!dl0) st <= S_IODL;
					else if (am == AM_DPX || am == AM_DPY || am == AM_INDX) st <= S_IOX;
					else if (am == AM_DP) st <= data_st;
					else st <= S_PLO;
				end else if (am == AM_SR || am == AM_SRY) begin
					st <= S_IOS;
				end else if (am != AM_SPECIAL) begin
					st <= S_OP2;
				end else begin
					case (ir)
					8'hC2: begin np = P & ~din; P <= E ? (np | 8'h30) : np;
					             if (E || np[4]) begin X[15:8] <= 8'h00; Y[15:8] <= 8'h00; end
					             st <= S_IO2; end                                  // REP
					8'hE2: begin np = P | din; P <= E ? (np | 8'h30) : np;
					             if (E || np[4]) begin X[15:8] <= 8'h00; Y[15:8] <= 8'h00; end
					             st <= S_IO2; end                                  // SEP
					8'h00, 8'h02: begin                                        // BRK, COP
						brk_sw <= 1'b1;
						vec_lo <= (ir == 8'h00) ? (E ? 8'hFE : 8'hE6) : (E ? 8'hF4 : 8'hE4);
						push_val <= PC + 16'd1;
						st <= E ? S_PUSH_HI : S_PUSH_BK;
					end
					8'hD4: begin                                               // PEI
						ptr <= D + {8'h00, din}; ptrb <= 8'h00;
						st <= dl0 ? S_JRD_LO : S_IODL;
					end
					8'hFC: begin push_val <= PC + 16'd1; st <= S_PUSH_HI; end  // JSR (a,X): push first
					default: begin
						if (is_branch) st <= br_take ? S_BR1 : S_FETCH;
						else st <= S_OP2;
					end
					endcase
				end
			end
			S_OP2: begin
				o2 <= din; PC <= PC + 16'd1;
				if (am == AM_IMM) begin
					A <= ex_A; X <= ex_X; Y <= ex_Y; P <= ex_P; st <= S_FETCH;
				end else if (am == AM_ABS || am == AM_ABSX || am == AM_ABSY) begin
					ea <= {DBR, din, o1} + ((am == AM_ABS) ? 24'd0 : {8'h00, ix}); ew <= 2'd0;
					dat <= store_val;
					if (am != AM_ABS && pen({din, o1}, ix, x8, kind != K_READ)) st <= S_IOP;
					else st <= data_st;
				end else if (am == AM_LONG || am == AM_LONGX) begin
					st <= S_OP3;
				end else begin
					case (ir)
					8'h4C: begin PC <= {din, o1}; st <= S_FETCH; end                       // JMP a
					8'h5C: st <= S_OP3;                                                     // JML
					8'h6C, 8'hDC: begin ptr <= {din, o1}; ptrb <= 8'h00; st <= S_JRD_LO; end // JMP (a), JML [a]
					8'h7C, 8'h20, 8'h82, 8'hFC: st <= S_SQ_IO;     // JMP (a,X), JSR a, BRL, JSR (a,X)
					8'h22: st <= S_PUSH_BK;                                                 // JSL
					8'hF4: begin push_val <= {din, o1}; st <= S_PUSH_HI; end               // PEA
					8'h62: st <= S_PER_IO;                                                  // PER
					8'h44, 8'h54: begin DBR <= o1; st <= S_MV_R; end                        // MVP, MVN
					default: st <= S_FETCH;
					endcase
				end
			end
			S_OP3: begin
				o3 <= din; PC <= PC + 16'd1;
				if (am == AM_LONG || am == AM_LONGX) begin
					ea <= {din, o2, o1} + ((am == AM_LONGX) ? {8'h00, X} : 24'd0); ew <= 2'd0;
					dat <= store_val;
					st <= data_st;
				end else begin                                                              // JML
					PC <= {o2, o1}; PBR <= din; st <= S_FETCH;
				end
			end
			S_JSL_OP3: begin
				o3 <= din; PC <= PC + 16'd1;
				push_val <= PC;               // the bank byte's address: return - 1
				st <= S_PUSH_HI;
			end

			// ===== addressing =======================================================
			S_IODL: begin
				if (ir == 8'hD4) st <= S_JRD_LO;
				else if (am == AM_DPX || am == AM_DPY || am == AM_INDX) st <= S_IOX;
				else if (am == AM_DP) st <= data_st;
				else st <= S_PLO;
			end
			S_IOX: begin
				if (E && dl0) begin
					ea  <= {8'h00, D[15:8], o1 + ix[7:0]}; ew <= 2'd2;
					ptr <= {D[15:8], o1 + ix[7:0]};
				end else begin
					ea  <= {8'h00, D + {8'h00, o1} + ix}; ew <= 2'd1;
					ptr <= D + {8'h00, o1} + ix;
				end
				st <= (am == AM_INDX) ? S_PLO : data_st;
			end
			S_IOS: begin
				ea  <= {8'h00, S + {8'h00, o1}}; ew <= 2'd1;
				ptr <= S + {8'h00, o1}; ptrb <= 8'h00;
				dat <= store_val;
				st <= (am == AM_SRY) ? S_PLO : data_st;
			end
			S_PLO: begin
				ea[7:0] <= din;               // (the pointer's bytes gather in ea)
				if ((am == AM_INDX && E) || ((am == AM_IND || am == AM_INDY) && E && dl0))
					ptr <= {ptr[15:8], ptr[7:0] + 8'd1};      // its high byte from the same page
				else
					ptr <= ptr + 16'd1;
				st <= S_PHI;
			end
			S_PHI: begin
				t16 = {din, ea[7:0]};
				ew <= 2'd0;
				dat <= store_val;
				if (am == AM_INDL || am == AM_INDLY) begin
					ea[15:8] <= din; ptr <= ptr + 16'd1; st <= S_PBK;
				end else if (am == AM_INDY) begin
					ea <= {DBR, t16} + {8'h00, Y};
					st <= pen(t16, Y, x8, kind != K_READ) ? S_IOP : data_st;
				end else if (am == AM_SRY) begin
					ea <= {DBR, t16} + {8'h00, Y};
					st <= S_IOS2;
				end else begin
					ea <= {DBR, t16};
					st <= data_st;
				end
			end
			S_PBK: begin
				ea <= {din, ea[15:0]} + ((am == AM_INDLY) ? {8'h00, Y} : 24'd0); ew <= 2'd0;
				st <= data_st;
			end
			S_IOP, S_IOS2: st <= data_st;

			// ===== data ===============================================================
			S_RLO: begin
				dat <= {8'h00, din};
				if (!w8) st <= S_RHI;
				else if (kind == K_RMW) st <= S_MIO;
				else begin A <= ex_A; X <= ex_X; Y <= ex_Y; P <= ex_P; st <= S_FETCH; end
			end
			S_RHI: begin
				dat[15:8] <= din;
				if (kind == K_RMW) st <= S_MIO;
				else begin A <= ex_A; X <= ex_X; Y <= ex_Y; P <= ex_P; st <= S_FETCH; end
			end
			S_WLO: st <= w8 ? S_FETCH : S_WHI;
			S_WHI: st <= S_FETCH;
			S_MIO: begin
				dat <= rmw_r;
				if (op == O_TSB || op == O_TRB) P[FZ] <= rmw_tz;
				else begin
					P[FN] <= w8 ? rmw_r[7] : rmw_r[15];
					P[FZ] <= w8 ? (rmw_r[7:0] == 8'h00) : (rmw_r == 16'h0000);
					if (op == O_ASL || op == O_LSR || op == O_ROL || op == O_ROR) P[FC] <= rmw_c;
				end
				st <= w8 ? S_MWLO : S_MWHI;
			end
			S_MWHI: st <= S_MWLO;
			S_MWLO: st <= S_FETCH;

			// ===== implied ===========================================================
			S_IO1: begin
				st <= S_FETCH;
				case (ir)
				8'h0A, 8'h4A, 8'h2A, 8'h6A, 8'h1A, 8'h3A: begin
					if (m8) A[7:0] <= acc_r[7:0]; else A <= acc_r;
					P[FN] <= m8 ? acc_r[7] : acc_r[15];
					P[FZ] <= m8 ? (acc_r[7:0] == 8'h00) : (acc_r == 16'h0000);
					if (ir != 8'h1A && ir != 8'h3A) P[FC] <= acc_c;
				end
				8'hAA, 8'hA8, 8'hBA, 8'h9B, 8'hBB, 8'hE8, 8'hC8, 8'hCA, 8'h88: begin
					case (ir)
					8'hAA, 8'hA8: t16 = A;
					8'hBA:        t16 = S;
					8'h9B:        t16 = X;
					8'hBB:        t16 = Y;
					8'hE8:        t16 = X + 16'd1;
					8'hCA:        t16 = X - 16'd1;
					8'hC8:        t16 = Y + 16'd1;
					default:      t16 = Y - 16'd1;    // DEY
					endcase
					if (x8) t16[15:8] = 8'h00;
					if (ir == 8'hAA || ir == 8'hBA || ir == 8'hBB || ir == 8'hE8 || ir == 8'hCA) X <= t16; else Y <= t16;
					P[FN] <= x8 ? t16[7] : t16[15];
					P[FZ] <= x8 ? (t16[7:0] == 8'h00) : (t16 == 16'h0000);
				end
				8'h8A, 8'h98: begin
					t16 = (ir == 8'h8A) ? X : Y;
					if (m8) A[7:0] <= t16[7:0]; else A <= t16;
					P[FN] <= m8 ? t16[7] : t16[15];
					P[FZ] <= m8 ? (t16[7:0] == 8'h00) : (t16 == 16'h0000);
				end
				8'h9A: S <= E ? {8'h01, X[7:0]} : X;
				8'h1B: S <= E ? {8'h01, A[7:0]} : A;
				8'h3B, 8'h5B, 8'h7B: begin
					t16 = (ir == 8'h3B) ? S : (ir == 8'h5B) ? A : D;
					if (ir == 8'h5B) D <= t16; else A <= t16;
					P[FN] <= t16[15]; P[FZ] <= (t16 == 16'h0000);
				end
				8'h18: P[FC] <= 1'b0; 8'h38: P[FC] <= 1'b1; 8'h58: P[FI] <= 1'b0; 8'h78: P[FI] <= 1'b1;
				8'hB8: P[FV] <= 1'b0; 8'hD8: P[FD] <= 1'b0; 8'hF8: P[FD] <= 1'b1;
				8'hFB: begin                                   // XCE
					E <= P[FC]; P[FC] <= E;
					if (P[FC]) begin
						P[FM] <= 1'b1; P[FX] <= 1'b1; X[15:8] <= 8'h00; Y[15:8] <= 8'h00;
						S <= {8'h01, S[7:0]};
					end
				end
				8'hEB: st <= S_IO2;                           // XBA: two internal cycles
				8'h42: PC <= PC + 16'd1;                      // WDM skips its byte
				default: ;
				endcase
			end
			S_IO2: begin
				st <= S_FETCH;
				if (ir == 8'hEB) begin
					A <= {A[7:0], A[15:8]};
					P[FN] <= A[15]; P[FZ] <= (A[15:8] == 8'h00);
				end
			end

			// ===== branches =========================================================
			S_BR1: begin
				t16 = PC + {{8{o1[7]}}, o1};
				if (E && (t16[15:8] != PC[15:8])) st <= S_BR2;
				else begin PC <= t16; st <= S_FETCH; end
			end
			S_BR2: begin PC <= PC + {{8{o1[7]}}, o1}; st <= S_FETCH; end

			// ===== sequences ==========================================================
			S_SQ_IO: begin
				case (ir)
				8'h48: begin push_val <= A; st <= m8 ? S_PUSH_LO : S_PUSH_HI; end   // PHA
				8'hDA: begin push_val <= X; st <= x8 ? S_PUSH_LO : S_PUSH_HI; end   // PHX
				8'h5A: begin push_val <= Y; st <= x8 ? S_PUSH_LO : S_PUSH_HI; end   // PHY
				8'h08: begin push_val <= {8'h00, P};   st <= S_PUSH_LO; end         // PHP
				8'h8B: begin push_val <= {8'h00, DBR}; st <= S_PUSH_LO; end         // PHB
				8'h4B: begin push_val <= {8'h00, PBR}; st <= S_PUSH_LO; end         // PHK
				8'h0B: begin push_val <= D; st <= S_PUSH_HI; end                    // PHD
				8'h20: begin push_val <= PC - 16'd1; st <= S_PUSH_HI; end           // JSR a
				8'h22: st <= S_JSL_OP3;                                             // JSL: the bank
				8'h82: begin PC <= PC + {o2, o1}; st <= S_FETCH; end                // BRL
				8'h7C, 8'hFC: begin ptr <= {o2, o1} + X; ptrb <= PBR; st <= S_JRD_LO; end
				default: st <= S_SQ_IO2;      // pulls, returns, WAI, STP
				endcase
			end
			S_SQ_IO2: begin
				case (ir)
				8'h28, 8'h40: st <= S_PULL_P;
				8'h68, 8'hFA, 8'h7A, 8'hAB, 8'h2B, 8'h60, 8'h6B: st <= S_PULL_LO;
				8'hCB, 8'hDB: st <= S_SQ_IO3;
				default: st <= S_FETCH;
				endcase
			end
			S_SQ_IO3: begin
				if (ir == 8'hCB) waiting <= 1'b1; else stopped <= 1'b1;
				st <= S_WAIT;
			end
			S_PER_IO: begin push_val <= PC + {o2, o1}; st <= S_PUSH_HI; end
			S_RTS_IO: st <= S_FETCH;

			// pushes (write at S, then S moves)
			S_PUSH_BK: begin
				S <= s_dec;
				st <= (ir == 8'h22) ? S_SQ_IO : S_PUSH_HI;    // JSL: an internal cycle next
			end
			S_PUSH_HI: begin S <= s_dec; st <= S_PUSH_LO; end
			S_PUSH_LO: begin
				S <= s_dec;
				case (ir)
				8'h00, 8'h02: st <= S_PUSH_P;                                    // BRK, COP, interrupts
				8'h20: begin PC <= {o2, o1}; st <= S_FETCH; end                  // JSR a
				8'h22: begin PC <= {o2, o1}; PBR <= o3; st <= S_FETCH;          // JSL
				             if (E) S <= {8'h01, s_dec[7:0]}; end
				8'hFC: st <= S_OP2;                                               // JSR (a,X): its high byte
				8'h0B, 8'hF4, 8'hD4, 8'h62: begin st <= S_FETCH; if (E) S <= {8'h01, s_dec[7:0]}; end
				default: st <= S_FETCH;
				endcase
			end
			S_PUSH_P: begin S <= s_dec; st <= S_VEC_LO; end
			S_VEC_LO: begin dat[7:0] <= din; st <= S_VEC_HI; end
			S_VEC_HI: begin
				PC <= {din, dat[7:0]}; PBR <= 8'h00;
				P[FI] <= 1'b1; P[FD] <= 1'b0;
				brk_sw <= 1'b0;
				st <= S_FETCH;
			end

			// pulls (S moves, then read at S)
			S_PULL_P: begin
				S <= s_inc;
				np = E ? (din | 8'h30) : din;
				P <= np;
				if (E || np[4]) begin X[15:8] <= 8'h00; Y[15:8] <= 8'h00; end
				st <= (ir == 8'h40) ? S_PULL_LO : S_FETCH;     // RTI goes on to the PC
			end
			S_PULL_LO: begin
				S <= s_inc; dat[7:0] <= din;
				case (ir)
				8'h68: if (m8) begin A[7:0] <= din; P[FN] <= din[7]; P[FZ] <= (din == 8'h00); st <= S_FETCH; end else st <= S_PULL_HI;
				8'hFA: if (x8) begin X <= {8'h00, din}; P[FN] <= din[7]; P[FZ] <= (din == 8'h00); st <= S_FETCH; end else st <= S_PULL_HI;
				8'h7A: if (x8) begin Y <= {8'h00, din}; P[FN] <= din[7]; P[FZ] <= (din == 8'h00); st <= S_FETCH; end else st <= S_PULL_HI;
				8'hAB: begin DBR <= din; P[FN] <= din[7]; P[FZ] <= (din == 8'h00); st <= S_FETCH;
				             if (E) S <= {8'h01, s_inc[7:0]}; end
				default: st <= S_PULL_HI;
				endcase
			end
			S_PULL_HI: begin
				S <= s_inc;
				t16 = {din, dat[7:0]};
				case (ir)
				8'h68: begin A <= t16; P[FN] <= t16[15]; P[FZ] <= (t16 == 16'h0000); st <= S_FETCH; end
				8'hFA: begin X <= t16; P[FN] <= t16[15]; P[FZ] <= (t16 == 16'h0000); st <= S_FETCH; end
				8'h7A: begin Y <= t16; P[FN] <= t16[15]; P[FZ] <= (t16 == 16'h0000); st <= S_FETCH; end
				8'h2B: begin D <= t16; P[FN] <= t16[15]; P[FZ] <= (t16 == 16'h0000); st <= S_FETCH;
				             if (E) S <= {8'h01, s_inc[7:0]}; end
				8'h60: begin PC <= t16 + 16'd1; st <= S_RTS_IO; end
				8'h6B: begin PC <= t16 + 16'd1; st <= S_PULL_BK; end
				8'h40: begin PC <= t16; st <= E ? S_FETCH : S_PULL_BK; end
				default: st <= S_FETCH;
				endcase
			end
			S_PULL_BK: begin
				S <= s_inc;
				PBR <= din;
				if (ir == 8'h6B && E) S <= {8'h01, s_inc[7:0]};
				st <= S_FETCH;
			end

			// through a pointer: JMP (a) / (a,X), JML [a], JSR (a,X), PEI
			S_JRD_LO: begin dat[7:0] <= din; ptr <= ptr + 16'd1; st <= S_JRD_HI; end
			S_JRD_HI: begin
				t16 = {din, dat[7:0]};
				case (ir)
				8'hDC: begin dat[15:8] <= din; ptr <= ptr + 16'd1; st <= S_JRD_BK; end
				8'hD4: begin push_val <= t16; st <= S_PUSH_HI; end
				8'hFC: begin PC <= t16; st <= S_FETCH; if (E) S <= {8'h01, S[7:0]}; end
				default: begin PC <= t16; st <= S_FETCH; end
				endcase
			end
			S_JRD_BK: begin PC <= dat; PBR <= din; st <= S_FETCH; end

			// block moves: one byte, then the instruction again
			S_MV_R: begin dat[7:0] <= din; st <= S_MV_W; end
			S_MV_W: st <= S_MV_IO1;
			S_MV_IO1: st <= S_MV_IO2;
			S_MV_IO2: begin
				if (x8) begin
					X <= {8'h00, X[7:0] + ((ir == 8'h54) ? 8'h01 : 8'hFF)};
					Y <= {8'h00, Y[7:0] + ((ir == 8'h54) ? 8'h01 : 8'hFF)};
				end else begin
					X <= X + ((ir == 8'h54) ? 16'h0001 : 16'hFFFF);
					Y <= Y + ((ir == 8'h54) ? 16'h0001 : 16'hFFFF);
				end
				A <= A - 16'd1;
				if (A != 16'h0000) PC <= PC - 16'd3;
				st <= S_FETCH;
			end

			S_WAIT: if (waiting && (nmi_pend || irq)) begin waiting <= 1'b0; st <= S_FETCH; end
			default: st <= S_FETCH;
			endcase
			end
		end
	end
endmodule
