`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// gb_cpu.v - the Game Boy's processor, the Sharp SM83.
//
// An 8-bit core that looks like a Z80 from a distance and is not one up close:
// no IX/IY, no alternate register set, no I/O instructions, no parity flag --
// but it has LDH for the $FF00 page, LD (HL+)/(HL-), SWAP, and a STOP it barely
// uses. Every instruction is some whole number of M-cycles (machine cycles), and
// an M-cycle is four T-cycles of the 4.194304 MHz clock. One bus access per
// M-cycle, at most; the fetch of an opcode is one M-cycle like any other read.
//
// --- how this file is organised ---------------------------------------------------
//
// The core steps once per M-cycle, at the LAST of the four T-cycles (the ce where
// `t` is 3). The address, rd/we and dout for an M-cycle are registered at the end
// of the cycle before, so they are stable for the whole cycle and the memory in
// the top has the full four T-cycles (48 system clocks on the board) to answer;
// `din` is sampled at the same last T-cycle the state advances on.
//
// The state is which M-cycle of which instruction we are in: FETCH reads the
// opcode and executes the one-cycle instructions entirely at its end; the others
// hand over to one of a small set of generic bus states (read an immediate, read
// memory, write memory, an internal cycle) whose meaning is decided by the opcode
// held in `ir`. The cycle counts come out of the official tables because every
// bus access and every internal cycle is a state of its own; nothing is "timed",
// it is just the number of steps.
//
// --- what lives where -------------------------------------------------------------
//
// IE ($FFFF) and IF ($FF0F) are in the top with the rest of the memory map; this
// core receives their AND on `irq` (bit 0 VBlank, 1 STAT, 2 timer, 3 serial, 4
// joypad) and pulses irq_ack with the number of the one it dispatches so the top
// can clear its IF bit. The vector is chosen at the end of the cycle that pushes
// the high byte of PC, which is when the real one decides: a push that lands on
// IE and turns the interrupt off sends the core to $0000, as it does on the
// console.
//
// --- the parts that are easy to get wrong ----------------------------------------
//
// EI takes effect one instruction late: IME goes high at the end of the NEXT
// opcode fetch, so the instruction after EI always runs before any handler. DI
// cancels a pending EI. RETI sets IME at once, and a pending interrupt is taken
// straight after it.
//
// HALT with IME clear and an interrupt already pending does not halt. It also
// fails to increment PC on the following fetch, so the next byte is executed
// twice -- the "HALT bug". Games hit it by accident and depend on it by then.
//
// STOP is treated as HALT plus a pulse on `stop`, which the top uses to reset
// DIV. The real one also switches the clocks off until a joypad press; nothing we
// run needs that, and the tests only ask that it be a one-byte instruction that
// takes an idle cycle or two.
//
// The 11 undefined opcodes lock a real SM83 up. Here they are a NOP, so a
// program that strays into them is at least visible on dbg_pc instead of silent.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module gb_cpu (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,          // one pulse per T-cycle (4.194304 MHz); four make an M-cycle

	// the bus: valid for a whole M-cycle, din sampled at the cycle's last T
	output reg  [15:0] addr,
	input  wire [7:0]  din,
	output reg  [7:0]  dout,
	output reg         rd,          // this M-cycle reads addr
	output reg         we,          // this M-cycle writes dout to addr
	output wire        wr_strobe,   // one clock pulse at the end of a write cycle: commit it now
	output wire        m_end,       // one clock pulse at the end of every M-cycle
	output wire [1:0]  tcyc,        // which T-cycle of the M-cycle this is
	output reg         m1,          // this M-cycle is an opcode fetch

	// interrupts
	input  wire [4:0]  irq,         // IE & IF
	output reg         irq_ack,     // pulse: interrupt irq_n is being dispatched, clear its IF bit
	output reg  [2:0]  irq_n,

	output reg         halted,
	output reg         stop,        // pulse: a STOP was executed
	output reg         ime,
	output reg         ime_pend,    // an EI has run; IME is set after the next instruction

	output wire [15:0] dbg_pc
);

	// --- registers -------------------------------------------------------------------
	reg [7:0]  A, B, C, D, E, H, L;
	reg        f_z, f_n, f_h, f_c;
	reg [15:0] SP, PC;
	reg [7:0]  Z, W;                // temporaries: an immediate, a low then a high byte
	reg [7:0]  ir;                  // the opcode being executed
	reg [7:0]  cb;                  // the second byte of a CB-prefixed one
	reg        halt_bug;            // next fetch must not increment PC

	assign dbg_pc = PC;

	wire [15:0] HL = {H, L};
	wire [15:0] BC = {B, C};
	wire [15:0] DE = {D, E};
	wire [7:0]  F  = {f_z, f_n, f_h, f_c, 4'b0000};

	// --- the T-cycle counter -----------------------------------------------------------
	reg [1:0] t;
	always @(posedge clk) begin
		if (rst) t <= 2'd0;
		else if (ce) t <= t + 2'd1;
	end
	wire step = ce && (t == 2'd3);
	assign tcyc      = t;
	assign m_end     = step;
	// A write lands in the third T-cycle, not the last: the real one writes in the
	// middle of the cycle too, and it matters -- a write to IF that requests an
	// interrupt has to be visible when the instruction boundary checks for one.
	// blargg's 02-interrupts runs the handler before the next instruction.
	assign wr_strobe = ce && (t == 2'd2) && we;

	// --- states --------------------------------------------------------------------------
	localparam [4:0]
		S_FETCH = 5'd0,   // read opcode at PC
		S_RD_N  = 5'd1,   // read immediate at PC into Z
		S_RD_N2 = 5'd2,   // read second immediate at PC into W
		S_RD_CB = 5'd3,   // read the byte after a CB prefix
		S_RD_M  = 5'd4,   // read memory at addr
		S_WR_M  = 5'd5,   // write memory
		S_WR_M2 = 5'd6,   // the second write (LD (nn),SP; PUSH/CALL/RST low byte)
		S_IDLE1 = 5'd7,   // internal cycles: what happens at their end depends on ir
		S_IDLE2 = 5'd8,
		S_POP1  = 5'd9,   // read low byte at SP
		S_POP2  = 5'd10,  // read high byte at SP
		S_RET   = 5'd11,  // the idle cycle that ends RET / RETI / RET cc
		S_HALT  = 5'd12,
		S_INT1  = 5'd13,  // interrupt dispatch: two idle cycles,
		S_INT2  = 5'd14,
		S_INT3  = 5'd15,  // push PC high (and choose the vector),
		S_INT4  = 5'd16,  // push PC low,
		S_INT5  = 5'd17;  // set PC

	reg [4:0] state;

	// --- decode fields -------------------------------------------------------------------
	// During FETCH the opcode is still on the bus; afterwards it is in ir.
	wire [7:0] op = (state == S_FETCH) ? din : ir;
	wire [1:0] op_x = op[7:6];
	wire [2:0] op_y = op[5:3];
	wire [2:0] op_z = op[2:0];
	wire [1:0] op_p = op[5:4];
	wire       op_q = op[3];

	// the condition codes: NZ, Z, NC, C
	reg cc_true;
	always @(*) begin
		case (op_y[1:0])
			2'd0: cc_true = !f_z;
			2'd1: cc_true = f_z;
			2'd2: cc_true = !f_c;
			default: cc_true = f_c;
		endcase
	end

	// register operands by index: 0 B, 1 C, 2 D, 3 E, 4 H, 5 L, (6 is (HL)), 7 A
	reg [7:0] r_z, r_y, r_din;
	always @(*) begin
		case (op_z)
			3'd0: r_z = B; 3'd1: r_z = C; 3'd2: r_z = D; 3'd3: r_z = E;
			3'd4: r_z = H; 3'd5: r_z = L; default: r_z = A;
		endcase
		case (op_y)
			3'd0: r_y = B; 3'd1: r_y = C; 3'd2: r_y = D; 3'd3: r_y = E;
			3'd4: r_y = H; 3'd5: r_y = L; default: r_y = A;
		endcase
		// the CB opcode's operand, while that opcode is still on the bus
		case (din[2:0])
			3'd0: r_din = B; 3'd1: r_din = C; 3'd2: r_din = D; 3'd3: r_din = E;
			3'd4: r_din = H; 3'd5: r_din = L; default: r_din = A;
		endcase
	end

	// 16-bit pairs by index: 0 BC, 1 DE, 2 HL, 3 SP
	reg [15:0] rr_p;
	always @(*) begin
		case (op_p)
			2'd0: rr_p = BC; 2'd1: rr_p = DE; 2'd2: rr_p = HL; default: rr_p = SP;
		endcase
	end

	// --- the ALU -----------------------------------------------------------------------------
	// {z, n, h, c, result}. Pure functions of their arguments, on purpose: xsim
	// re-evaluates a function called from combinational code only when its
	// arguments change, so one that peeked at a register would go stale.
	function [11:0] alu8;
		input [2:0] fop;    // 0 ADD 1 ADC 2 SUB 3 SBC 4 AND 5 XOR 6 OR 7 CP
		input [7:0] a, b;
		input       cin;
		reg [8:0] s;
		reg [4:0] lo;
		reg       cu;
		begin
			cu = (fop == 3'd1 || fop == 3'd3) ? cin : 1'b0;
			case (fop)
				3'd0, 3'd1: begin
					s  = {1'b0, a} + {1'b0, b} + {8'd0, cu};
					lo = {1'b0, a[3:0]} + {1'b0, b[3:0]} + {4'd0, cu};
					alu8 = {s[7:0] == 8'd0, 1'b0, lo[4], s[8], s[7:0]};
				end
				3'd2, 3'd3, 3'd7: begin
					s  = {1'b0, a} - {1'b0, b} - {8'd0, cu};
					lo = {1'b0, a[3:0]} - {1'b0, b[3:0]} - {4'd0, cu};
					alu8 = {s[7:0] == 8'd0, 1'b1, lo[4], s[8], (fop == 3'd7) ? a : s[7:0]};
				end
				3'd4: alu8 = {(a & b) == 8'd0, 1'b0, 1'b1, 1'b0, a & b};
				3'd5: alu8 = {(a ^ b) == 8'd0, 1'b0, 1'b0, 1'b0, a ^ b};
				default: alu8 = {(a | b) == 8'd0, 1'b0, 1'b0, 1'b0, a | b};
			endcase
		end
	endfunction

	function [11:0] rot8;
		input [2:0] fop;    // 0 RLC 1 RRC 2 RL 3 RR 4 SLA 5 SRA 6 SWAP 7 SRL
		input [7:0] v;
		input       cin;
		reg [7:0] r;
		reg       c;
		begin
			case (fop)
				3'd0: begin r = {v[6:0], v[7]}; c = v[7]; end
				3'd1: begin r = {v[0], v[7:1]}; c = v[0]; end
				3'd2: begin r = {v[6:0], cin};  c = v[7]; end
				3'd3: begin r = {cin, v[7:1]};  c = v[0]; end
				3'd4: begin r = {v[6:0], 1'b0}; c = v[7]; end
				3'd5: begin r = {v[7], v[7:1]}; c = v[0]; end
				3'd6: begin r = {v[3:0], v[7:4]}; c = 1'b0; end
				default: begin r = {1'b0, v[7:1]}; c = v[0]; end
			endcase
			rot8 = {r == 8'd0, 1'b0, 1'b0, c, r};
		end
	endfunction

	// INC/DEC leave carry alone; the caller keeps f_c.
	function [10:0] incdec8;     // {z, n, h, result}
		input       dec;
		input [7:0] v;
		reg [7:0] r;
		begin
			r = dec ? v - 8'd1 : v + 8'd1;
			incdec8 = {r == 8'd0, dec, dec ? (v[3:0] == 4'h0) : (v[3:0] == 4'hF), r};
		end
	endfunction

	// DAA: fix A up after a BCD add or subtract. In add mode a digit over 9 or a
	// half-carry gets 6 added, and the high digit the same with $60 and the carry
	// flag; in subtract mode only the flags say what happened, and carry is kept.
	function [11:0] daa8;        // {z, n, h, c, result}
		input [7:0] a;
		input n, h, c;
		reg [7:0] adj, r;
		reg       co;
		begin
			adj = 8'd0;
			co  = c;
			if (!n) begin
				if (h || a[3:0] > 4'd9) adj = adj | 8'h06;
				if (c || a > 8'h99) begin adj = adj | 8'h60; co = 1'b1; end
				r = a + adj;
			end else begin
				if (h) adj = adj | 8'h06;
				if (c) adj = adj | 8'h60;
				r = a - adj;
			end
			daa8 = {r == 8'd0, n, 1'b0, co, r};
		end
	endfunction

	// SP + signed e, with the flags from the LOW byte's addition -- that is what the
	// hardware does, and it is why ADD SP,e can set H and C with a negative e.
	wire [15:0] sp_e     = SP + {{8{Z[7]}}, Z};
	wire [4:0]  sp_e_lo4 = {1'b0, SP[3:0]} + {1'b0, Z[3:0]};
	wire [8:0]  sp_e_lo8 = {1'b0, SP[7:0]} + {1'b0, Z};

	// ADD HL,rr: H is the carry out of bit 11.
	wire [16:0] hl_add    = {1'b0, HL} + {1'b0, rr_p};
	wire [12:0] hl_add_lo = {1'b0, HL[11:0]} + {1'b0, rr_p[11:0]};

	// --- register write by index ---------------------------------------------------------
	task wr_r;
		input [2:0] i;
		input [7:0] v;
		begin
			case (i)
				3'd0: B <= v; 3'd1: C <= v; 3'd2: D <= v; 3'd3: E <= v;
				3'd4: H <= v; 3'd5: L <= v; 3'd7: A <= v;
				default: ;
			endcase
		end
	endtask

	task set_flags;
		input [3:0] f;
		begin
			f_z <= f[3]; f_n <= f[2]; f_h <= f[1]; f_c <= f[0];
		end
	endtask

	// Set up a read or write for the coming M-cycle.
	task bus_rd;
		input [15:0] a;
		begin
			addr <= a; rd <= 1'b1; we <= 1'b0; m1 <= 1'b0;
		end
	endtask
	task bus_wr;
		input [15:0] a;
		input [7:0]  d;
		begin
			addr <= a; dout <= d; rd <= 1'b0; we <= 1'b1; m1 <= 1'b0;
		end
	endtask
	task bus_idle;
		begin
			rd <= 1'b0; we <= 1'b0; m1 <= 1'b0;
		end
	endtask

	// The instruction is over: fetch the next one from `pc_next` (the caller has
	// just assigned it to PC too), or take an interrupt. `ime_now` is IME as it
	// stands after this instruction -- RETI passes a 1 the register has not got yet.
	task next_instr;
		input [15:0] pc_next;
		input        ime_now;
		begin
			if (ime_now && |irq) begin
				state <= S_INT1;
				ime   <= 1'b0;
				bus_idle;
			end else begin
				state <= S_FETCH;
				bus_rd(pc_next);
				m1 <= 1'b1;
			end
		end
	endtask

	// --- the vector --------------------------------------------------------------------------
	reg [2:0] vec_n;
	always @(*) begin
		if (irq[0])      vec_n = 3'd0;
		else if (irq[1]) vec_n = 3'd1;
		else if (irq[2]) vec_n = 3'd2;
		else if (irq[3]) vec_n = 3'd3;
		else             vec_n = 3'd4;
	end
	reg [15:0] vec_addr;

	// --- the machine -----------------------------------------------------------------------------
	reg [11:0] f8;     // scratch for ALU results inside the block
	reg [10:0] id8;
	reg [15:0] s16;

	always @(posedge clk) begin
		irq_ack <= 1'b0;
		stop    <= 1'b0;
		if (rst) begin
			// The values the DMG boot ROM leaves behind; there is no boot ROM here.
			A <= 8'h01; f_z <= 1'b1; f_n <= 1'b0; f_h <= 1'b1; f_c <= 1'b1;
			B <= 8'h00; C <= 8'h13; D <= 8'h00; E <= 8'hD8; H <= 8'h01; L <= 8'h4D;
			SP <= 16'hFFFE; PC <= 16'h0100;
			Z <= 8'd0; W <= 8'd0; ir <= 8'd0; cb <= 8'd0;
			ime <= 1'b0; ime_pend <= 1'b0; halted <= 1'b0; halt_bug <= 1'b0;
			state <= S_FETCH; addr <= 16'h0100; rd <= 1'b1; we <= 1'b0; m1 <= 1'b1; dout <= 8'd0;
			irq_n <= 3'd0; vec_addr <= 16'd0;
		end else if (step) begin
			case (state)

			// ----------------------------------------------------------------------------
			S_FETCH: begin
				ir <= din;
				if (halt_bug) halt_bug <= 1'b0;
				else PC <= PC + 16'd1;
				// EI lands here: the instruction being fetched runs with IME off.
				if (ime_pend) begin ime <= 1'b1; ime_pend <= 1'b0; end

				case (op_x)
				// -- x = 0 -------------------------------------------------------------
				2'd0: case (op_z)
					3'd0: case (op_y)
						3'd0: next_instr(PC + 16'd1, ime);                   // NOP
						3'd1: begin state <= S_RD_N; bus_rd(PC + 16'd1); end // LD (nn),SP
						3'd2: begin                                          // STOP
							stop <= 1'b1;
							state <= S_HALT; halted <= 1'b1; bus_idle;
						end
						default: begin state <= S_RD_N; bus_rd(PC + 16'd1); end // JR e / JR cc,e
					endcase
					3'd1: begin
						if (!op_q) begin state <= S_RD_N; bus_rd(PC + 16'd1); end // LD rr,nn
						else begin state <= S_IDLE1; bus_idle; end               // ADD HL,rr
					end
					3'd2: begin                                              // LD (rr),A / LD A,(rr)
						case (op_p)
							2'd0: if (op_q) bus_rd(BC); else bus_wr(BC, A);
							2'd1: if (op_q) bus_rd(DE); else bus_wr(DE, A);
							default: if (op_q) bus_rd(HL); else bus_wr(HL, A);
						endcase
						state <= op_q ? S_RD_M : S_WR_M;
					end
					3'd3: begin state <= S_IDLE1; bus_idle; end              // INC/DEC rr
					3'd4, 3'd5: begin                                        // INC/DEC r
						if (op_y == 3'd6) begin state <= S_RD_M; bus_rd(HL); end
						else begin
							id8 = incdec8(op_z[0], r_y);
							wr_r(op_y, id8[7:0]);
							f_z <= id8[10]; f_n <= id8[9]; f_h <= id8[8];
							next_instr(PC + 16'd1, ime);
						end
					end
					3'd6: begin state <= S_RD_N; bus_rd(PC + 16'd1); end     // LD r,n / LD (HL),n
					default: begin                                           // rotates on A, DAA, CPL, SCF, CCF
						case (op_y)
							3'd0, 3'd1, 3'd2, 3'd3: begin
								f8 = rot8(op_y, A, f_c);
								A <= f8[7:0];
								set_flags({1'b0, 1'b0, 1'b0, f8[8]});        // RLCA etc clear Z
							end
							3'd4: begin
								f8 = daa8(A, f_n, f_h, f_c);
								A <= f8[7:0]; set_flags(f8[11:8]);
							end
							3'd5: begin A <= ~A; f_n <= 1'b1; f_h <= 1'b1; end
							3'd6: begin f_n <= 1'b0; f_h <= 1'b0; f_c <= 1'b1; end
							default: begin f_n <= 1'b0; f_h <= 1'b0; f_c <= ~f_c; end
						endcase
						next_instr(PC + 16'd1, ime);
					end
				endcase

				// -- x = 1: LD r,r' and HALT --------------------------------------------
				2'd1: begin
					if (op == 8'h76) begin
						// HALT. With IME off and something already pending the core
						// does not halt at all -- and the next fetch repeats a byte.
						if (!ime && |irq) begin
							halt_bug <= 1'b1;
							next_instr(PC + 16'd1, ime);
						end else begin
							state <= S_HALT; halted <= 1'b1; bus_idle;
						end
					end else if (op_y == 3'd6) begin state <= S_WR_M; bus_wr(HL, r_z); end
					else if (op_z == 3'd6) begin state <= S_RD_M; bus_rd(HL); end
					else begin wr_r(op_y, r_z); next_instr(PC + 16'd1, ime); end
				end

				// -- x = 2: ALU A,r -----------------------------------------------------------
				2'd2: begin
					if (op_z == 3'd6) begin state <= S_RD_M; bus_rd(HL); end
					else begin
						f8 = alu8(op_y, A, r_z, f_c);
						A <= f8[7:0]; set_flags(f8[11:8]);
						next_instr(PC + 16'd1, ime);
					end
				end

				// -- x = 3 -----------------------------------------------------------------------
				default: case (op_z)
					3'd0: begin
						if (!op_y[2]) begin state <= S_IDLE1; bus_idle; end           // RET cc
						else begin state <= S_RD_N; bus_rd(PC + 16'd1); end          // LDH (n),A / ADD SP,e / LDH A,(n) / LD HL,SP+e
					end
					3'd1: begin
						if (!op_q) begin state <= S_POP1; bus_rd(SP); end             // POP rr
						else case (op_p)
							2'd0, 2'd1: begin state <= S_POP1; bus_rd(SP); end         // RET / RETI
							2'd2: begin PC <= HL; next_instr(HL, ime); end             // JP HL
							default: begin state <= S_IDLE1; bus_idle; end             // LD SP,HL
						endcase
					end
					3'd2: case (op_y)
						3'd4: begin state <= S_WR_M; bus_wr({8'hFF, C}, A); end       // LD (C),A
						3'd6: begin state <= S_RD_M; bus_rd({8'hFF, C}); end         // LD A,(C)
						default: begin state <= S_RD_N; bus_rd(PC + 16'd1); end      // JP cc,nn / LD (nn),A / LD A,(nn)
					endcase
					3'd3: case (op_y)
						3'd0: begin state <= S_RD_N; bus_rd(PC + 16'd1); end         // JP nn
						3'd1: begin state <= S_RD_CB; bus_rd(PC + 16'd1); end        // CB prefix
						3'd6: begin ime <= 1'b0; ime_pend <= 1'b0; next_instr(PC + 16'd1, 1'b0); end // DI
						3'd7: begin ime_pend <= 1'b1; next_instr(PC + 16'd1, ime); end // EI
						default: next_instr(PC + 16'd1, ime);                        // undefined
					endcase
					3'd4: begin
						if (op_y[2]) next_instr(PC + 16'd1, ime);                    // undefined
						else begin state <= S_RD_N; bus_rd(PC + 16'd1); end          // CALL cc,nn
					end
					3'd5: begin
						if (!op_q) begin state <= S_IDLE1; bus_idle; end              // PUSH rr
						else if (op_p == 2'd0) begin state <= S_RD_N; bus_rd(PC + 16'd1); end // CALL nn
						else next_instr(PC + 16'd1, ime);                            // undefined
					end
					3'd6: begin state <= S_RD_N; bus_rd(PC + 16'd1); end             // ALU A,n
					default: begin state <= S_IDLE1; bus_idle; end                   // RST
				endcase
				endcase
			end

			// ----------------------------------------------------------------------------
			// The byte after the opcode.
			S_RD_N: begin
				Z  <= din;
				PC <= PC + 16'd1;
				case (op_x)
				2'd0: case (op_z)
					3'd0: begin
						if (op_y == 3'd1) begin state <= S_RD_N2; bus_rd(PC + 16'd1); end // LD (nn),SP
						else if (op_y == 3'd3 || cc_true) begin state <= S_IDLE1; bus_idle; end // JR taken
						else next_instr(PC + 16'd1, ime);                               // JR cc not taken
					end
					3'd1: begin state <= S_RD_N2; bus_rd(PC + 16'd1); end               // LD rr,nn
					default: begin                                                      // LD r,n / LD (HL),n
						if (op_y == 3'd6) begin state <= S_WR_M; bus_wr(HL, din); end
						else begin wr_r(op_y, din); next_instr(PC + 16'd1, ime); end
					end
				endcase
				default: case (op_z)
					3'd0: case (op_y)
						3'd4: begin state <= S_WR_M; bus_wr({8'hFF, din}, A); end          // LDH (n),A
						3'd6: begin state <= S_RD_M; bus_rd({8'hFF, din}); end            // LDH A,(n)
						default: begin state <= S_IDLE1; bus_idle; end                     // ADD SP,e / LD HL,SP+e
					endcase
					3'd6: begin                                                         // ALU A,n
						f8 = alu8(op_y, A, din, f_c);
						A <= f8[7:0]; set_flags(f8[11:8]);
						next_instr(PC + 16'd1, ime);
					end
					default: begin state <= S_RD_N2; bus_rd(PC + 16'd1); end            // JP/CALL/LD (nn): high byte next
				endcase
				endcase
			end

			// ----------------------------------------------------------------------------
			// The second immediate byte: nn is now {din, Z}.
			S_RD_N2: begin
				W  <= din;
				PC <= PC + 16'd1;
				case (op_x)
				2'd0: begin
					if (op_z == 3'd0) begin state <= S_WR_M; bus_wr({din, Z}, SP[7:0]); end // LD (nn),SP
					else begin                                                             // LD rr,nn
						case (op_p)
							2'd0: {B, C} <= {din, Z};
							2'd1: {D, E} <= {din, Z};
							2'd2: {H, L} <= {din, Z};
							default: SP <= {din, Z};
						endcase
						next_instr(PC + 16'd1, ime);
					end
				end
				default: case (op_z)
					3'd2: begin
						if (op_y == 3'd5) begin state <= S_WR_M; bus_wr({din, Z}, A); end   // LD (nn),A
						else if (op_y == 3'd7) begin state <= S_RD_M; bus_rd({din, Z}); end // LD A,(nn)
						else if (cc_true) begin state <= S_IDLE1; bus_idle; end             // JP cc taken
						else next_instr(PC + 16'd1, ime);
					end
					3'd4: begin
						if (cc_true) begin state <= S_IDLE1; bus_idle; end                   // CALL cc taken
						else next_instr(PC + 16'd1, ime);
					end
					default: begin state <= S_IDLE1; bus_idle; end                           // JP nn / CALL nn
				endcase
				endcase
			end

			// ----------------------------------------------------------------------------
			S_RD_CB: begin
				cb <= din;
				PC <= PC + 16'd1;
				if (din[2:0] == 3'd6) begin state <= S_RD_M; bus_rd(HL); end
				else begin
					case (din[7:6])
						2'd0: begin
							f8 = rot8(din[5:3], r_din, f_c);
							wr_r(din[2:0], f8[7:0]); set_flags(f8[11:8]);
						end
						2'd1: begin                                                        // BIT
							f_z <= ~r_din[din[5:3]]; f_n <= 1'b0; f_h <= 1'b1;
						end
						2'd2: wr_r(din[2:0], r_din & ~(8'd1 << din[5:3]));                 // RES
						default: wr_r(din[2:0], r_din | (8'd1 << din[5:3]));               // SET
					endcase
					next_instr(PC + 16'd1, ime);
				end
			end

			// ----------------------------------------------------------------------------
			// A byte read from memory.
			S_RD_M: begin
				Z <= din;
				if (ir == 8'hCB) begin
					case (cb[7:6])
						2'd0: begin
							f8 = rot8(cb[5:3], din, f_c);
							set_flags(f8[11:8]);
							state <= S_WR_M; bus_wr(HL, f8[7:0]);
						end
						2'd1: begin                                                        // BIT b,(HL)
							f_z <= ~din[cb[5:3]]; f_n <= 1'b0; f_h <= 1'b1;
							next_instr(PC, ime);
						end
						2'd2: begin state <= S_WR_M; bus_wr(HL, din & ~(8'd1 << cb[5:3])); end
						default: begin state <= S_WR_M; bus_wr(HL, din | (8'd1 << cb[5:3])); end
					endcase
				end else case (op_x)
				2'd0: begin
					if (op_z == 3'd2) begin                                            // LD A,(rr) and the HL+/- forms
						A <= din;
						if (op_p == 2'd2) {H, L} <= HL + 16'd1;
						if (op_p == 2'd3) {H, L} <= HL - 16'd1;
						next_instr(PC, ime);
					end else begin                                                     // INC/DEC (HL)
						id8 = incdec8(op_z[0], din);
						f_z <= id8[10]; f_n <= id8[9]; f_h <= id8[8];
						state <= S_WR_M; bus_wr(HL, id8[7:0]);
					end
				end
				2'd1: begin wr_r(op_y, din); next_instr(PC, ime); end                  // LD r,(HL)
				2'd2: begin                                                             // ALU A,(HL)
					f8 = alu8(op_y, A, din, f_c);
					A <= f8[7:0]; set_flags(f8[11:8]);
					next_instr(PC, ime);
				end
				default: begin A <= din; next_instr(PC, ime); end                       // LD A,(C) / LDH A,(n) / LD A,(nn)
				endcase
			end

			// ----------------------------------------------------------------------------
			S_WR_M: begin
				if (op_x == 2'd0 && op_z == 3'd0) begin                               // LD (nn),SP: high byte next
					state <= S_WR_M2; bus_wr({W, Z} + 16'd1, SP[15:8]);
				end else if (op_x == 2'd0 && op_z == 3'd2) begin                       // LD (HL+/-),A
					if (op_p == 2'd2) {H, L} <= HL + 16'd1;
					if (op_p == 2'd3) {H, L} <= HL - 16'd1;
					next_instr(PC, ime);
				end else if (op_x == 2'd3 && (op_z == 3'd4 || op_z == 3'd5 || op_z == 3'd7)) begin
					// PUSH / CALL / RST: the high byte is in memory, now the low one
					SP <= SP - 16'd1;
					state <= S_WR_M2;
					if (op_z == 3'd5 && !op_q) begin
						case (op_p)
							2'd0: bus_wr(SP - 16'd1, C);
							2'd1: bus_wr(SP - 16'd1, E);
							2'd2: bus_wr(SP - 16'd1, L);
							default: bus_wr(SP - 16'd1, F);
						endcase
					end else bus_wr(SP - 16'd1, PC[7:0]);
				end else next_instr(PC, ime);
			end

			S_WR_M2: begin
				if (op_x == 2'd3 && op_z == 3'd7) begin                               // RST
					PC <= {10'd0, op_y, 3'd0};
					next_instr({10'd0, op_y, 3'd0}, ime);
				end else if (op_x == 2'd3 && (op_z == 3'd4 || (op_z == 3'd5 && op_q))) begin // CALL
					PC <= {W, Z};
					next_instr({W, Z}, ime);
				end else next_instr(PC, ime);                                          // PUSH, LD (nn),SP
			end

			// ----------------------------------------------------------------------------
			// Internal cycles.
			S_IDLE1: begin
				case (op_x)
				2'd0: case (op_z)
					3'd0: begin                                                     // JR: PC += e
						s16 = PC + {{8{Z[7]}}, Z};
						PC <= s16;
						next_instr(s16, ime);
					end
					3'd1: begin                                                     // ADD HL,rr
						{H, L} <= hl_add[15:0];
						f_n <= 1'b0; f_c <= hl_add[16]; f_h <= hl_add_lo[12];
						next_instr(PC, ime);
					end
					default: begin                                                  // INC/DEC rr
						s16 = op_q ? rr_p - 16'd1 : rr_p + 16'd1;
						case (op_p)
							2'd0: {B, C} <= s16;
							2'd1: {D, E} <= s16;
							2'd2: {H, L} <= s16;
							default: SP <= s16;
						endcase
						next_instr(PC, ime);
					end
				endcase
				default: case (op_z)
					3'd0: begin
						if (!op_y[2]) begin                                         // RET cc: the condition is checked here
							if (cc_true) begin state <= S_POP1; bus_rd(SP); end
							else next_instr(PC, ime);
						end else if (op_y == 3'd5) begin                            // ADD SP,e: one more idle cycle
							state <= S_IDLE2; bus_idle;
						end else begin                                              // LD HL,SP+e
							{H, L} <= sp_e;
							set_flags({1'b0, 1'b0, sp_e_lo4[4], sp_e_lo8[8]});
							next_instr(PC, ime);
						end
					end
					3'd1: begin SP <= HL; next_instr(PC, ime); end                  // LD SP,HL
					3'd2, 3'd3: begin PC <= {W, Z}; next_instr({W, Z}, ime); end    // JP nn / JP cc
					3'd5: begin
						SP <= SP - 16'd1; state <= S_WR_M;
						if (!op_q) case (op_p)                                      // PUSH: high byte
							2'd0: bus_wr(SP - 16'd1, B);
							2'd1: bus_wr(SP - 16'd1, D);
							2'd2: bus_wr(SP - 16'd1, H);
							default: bus_wr(SP - 16'd1, A);
						endcase
						else bus_wr(SP - 16'd1, PC[15:8]);                          // CALL nn
					end
					default: begin                                                  // CALL cc / RST: push PCH
						SP <= SP - 16'd1; state <= S_WR_M; bus_wr(SP - 16'd1, PC[15:8]);
					end
				endcase
				endcase
			end

			S_IDLE2: begin                                                          // ADD SP,e
				SP <= sp_e;
				set_flags({1'b0, 1'b0, sp_e_lo4[4], sp_e_lo8[8]});
				next_instr(PC, ime);
			end

			// ----------------------------------------------------------------------------
			S_POP1: begin
				Z  <= din;
				SP <= SP + 16'd1;
				state <= S_POP2; bus_rd(SP + 16'd1);
			end
			S_POP2: begin
				SP <= SP + 16'd1;
				// POP is z=1 q=0; RET cc is z=0 (and C0/D0 have q clear too, which
				// is why bit 3 alone is not enough to tell them apart).
				if (op_z == 3'd1 && !op_q) begin                                    // POP rr
					case (op_p)
						2'd0: {B, C} <= {din, Z};
						2'd1: {D, E} <= {din, Z};
						2'd2: {H, L} <= {din, Z};
						default: begin A <= din; set_flags(Z[7:4]); end
					endcase
					next_instr(PC, ime);
				end else begin                                                      // RET / RETI / RET cc
					W <= din;
					state <= S_RET; bus_idle;
				end
			end
			S_RET: begin
				PC <= {W, Z};
				if (ir == 8'hD9) begin                                              // RETI
					ime <= 1'b1;
					next_instr({W, Z}, 1'b1);
				end else next_instr({W, Z}, ime);
			end

			// ----------------------------------------------------------------------------
			S_HALT: begin
				if (|irq) begin
					halted <= 1'b0;
					next_instr(PC, ime);    // IME on: the dispatch; off: carry on after HALT
				end else bus_idle;
			end

			// ----------------------------------------------------------------------------
			// Interrupt dispatch: five cycles, PC pushed in the third and fourth.
			S_INT1: begin state <= S_INT2; bus_idle; end
			S_INT2: begin
				SP <= SP - 16'd1;
				state <= S_INT3; bus_wr(SP - 16'd1, PC[15:8]);
			end
			S_INT3: begin
				// The vector is settled now, after the high byte is in memory.
				SP <= SP - 16'd1;
				vec_addr <= (|irq) ? {8'h00, 2'b01, vec_n, 3'b000} : 16'h0000;
				irq_ack  <= |irq;
				irq_n    <= vec_n;
				state <= S_INT4; bus_wr(SP - 16'd1, PC[7:0]);
			end
			S_INT4: begin
				PC <= vec_addr;
				state <= S_INT5; bus_idle;
			end
			S_INT5: next_instr(PC, 1'b0);

			default: next_instr(PC, ime);
			endcase
		end
	end

endmodule
