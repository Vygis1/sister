//////////////////////////////////////////////////////////////////////////////////
// spc700.v - the SNES's sound CPU (Sony SPC700), cycle by cycle.
//
// Written from Fullsnes to the bus order of the model tools/snes/spc700.py, which
// matches the SingleStepTests spc700 suite bus cycle by bus cycle; checked against the
// same suite by sim/tb_spc700.v (tools/snes/spc2vec.py).
//
// --- the bus ---------------------------------------------------------------------------
// One CPU cycle per `ce`. The cycle in progress is held in registers (bus_rd / bus_we /
// addr / dout) set when the previous one ended; at `ce` it ends and a read takes `din`.
// Neither bus_rd nor bus_we: an internal cycle. Dummy reads are reads -- the chip makes
// them, and a read of a timer counter clears it.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module spc700 (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,
	output reg  [15:0] addr,
	output reg  [7:0]  dout,
	output reg         bus_rd,
	output reg         bus_we,
	input  wire [7:0]  din,
	output wire        sync,          // this cycle reads an opcode
	output wire [15:0] dbg_pc
);
	reg [7:0]  A, X, Y, SP, PSW;
	reg [15:0] PC;
	localparam FC = 0, FZ = 1, FI = 2, FH = 3, FB = 4, FP = 5, FV = 6, FN = 7;
	assign dbg_pc = PC;

	reg [7:0]  ir;
	reg [4:0]  t;                   // the cycle within the instruction (0: the opcode)
	reg [7:0]  o1, o2;              // operand bytes
	reg [15:0] ma;                  // the memory operand's address
	reg [7:0]  dv;                  // a data byte read
	reg [7:0]  dv2;
	reg        stopped;
	assign sync = (t == 5'd0) && !stopped;

	wire [7:0] page = PSW[FP] ? 8'h01 : 8'h00;
	function [15:0] dp;             // the direct page
		input [7:0] o; input p;
		dp = {7'd0, p, o};
	endfunction

	// --- the next cycle ---------------------------------------------------------------------
	// (blocking temporaries in the sequential block decide it; these tasks set the bus regs)
	task rd;   input [15:0] a; begin addr <= a; bus_rd <= 1'b1; bus_we <= 1'b0; end endtask
	task wr;   input [15:0] a; input [7:0] d; begin addr <= a; dout <= d; bus_rd <= 1'b0; bus_we <= 1'b1; end endtask
	task idle; begin bus_rd <= 1'b0; bus_we <= 1'b0; end endtask

	// --- the ALU (all inputs passed) ---------------------------------------------------------
	// {V, H, C, r[7:0]}
	function [10:0] adc8;
		input [7:0] a, b; input c;
		reg [8:0] r; reg [4:0] h;
		begin
			r = {1'b0, a} + {1'b0, b} + {8'd0, c};
			h = {1'b0, a[3:0]} + {1'b0, b[3:0]} + {4'd0, c};
			adc8 = {~(a[7] ^ b[7]) & (a[7] ^ r[7]), h[4], r[8], r[7:0]};
		end
	endfunction

	// --- decode --------------------------------------------------------------------------------
	// the ALU rows: OR AND EOR CMP ADC SBC at 0x, 2x, 4x, 6x, 8x, Ax; columns 4-9 and 14-19
	wire [2:0] alu_k = (ir[7:5] == 3'd0) ? 3'd0 : (ir[7:5] == 3'd1) ? 3'd1 : (ir[7:5] == 3'd2) ? 3'd2 :
	                   (ir[7:5] == 3'd3) ? 3'd3 : (ir[7:5] == 3'd4) ? 3'd4 : 3'd5;
	wire       alu_row = (ir[7:5] <= 3'd5);
	// result of the ALU op k on a, b: {flags to set..., r}
	reg  [7:0] alu_r;
	reg  [7:0] alu_psw;
	reg  [10:0] ar;
	reg  [8:0]  cr;
	task alu;                        // sets alu_r / alu_psw from k, a, b, psw (all passed)
		input [2:0] k; input [7:0] a, b; input [7:0] ps;
		begin
			alu_psw = ps; alu_r = a;
			case (k)
			3'd0: alu_r = a | b;
			3'd1: alu_r = a & b;
			3'd2: alu_r = a ^ b;
			3'd3: begin cr = {1'b0, a} - {1'b0, b}; alu_r = a; alu_psw[FC] = !cr[8];
			            alu_psw[FN] = cr[7]; alu_psw[FZ] = (cr[7:0] == 8'h00); end
			3'd4, 3'd5: begin
				ar = adc8(a, (k == 3'd5) ? ~b : b, ps[FC]);
				alu_r = ar[7:0]; alu_psw[FC] = ar[8]; alu_psw[FH] = ar[9]; alu_psw[FV] = ar[10];
			end
			default: ;
			endcase
			if (k != 3'd3) begin alu_psw[FN] = alu_r[7]; alu_psw[FZ] = (alu_r == 8'h00); end
		end
	endtask

	// shifts / INC / DEC on a byte: {C, r}; op by the opcode row
	reg [7:0] sh_r; reg sh_c;
	task shift;
		input [7:0] opc; input [7:0] v; input c;
		begin
			sh_c = c; sh_r = v;
			case (opc[7:5])
			3'd0: begin sh_r = {v[6:0], 1'b0}; sh_c = v[7]; end        // ASL
			3'd1: begin sh_r = {v[6:0], c};    sh_c = v[7]; end        // ROL
			3'd2: begin sh_r = {1'b0, v[7:1]}; sh_c = v[0]; end        // LSR
			3'd3: begin sh_r = {c, v[7:1]};    sh_c = v[0]; end        // ROR
			3'd4: sh_r = v - 8'd1;                                     // DEC (8B 8C 9B 9C)
			3'd5: sh_r = v + 8'd1;                                     // INC (AB AC BB BC)
			default: ;
			endcase
		end
	endtask

	// the divider: DIV's internal cycles do two quotient bits each
	reg [15:0] dvd;                 // dividend, shifting out as quotient bits shift in
	reg [8:0]  dvs;                 // divisor (1..256)
	reg [8:0]  rem;
	reg        div_big;             // the chip's other branch (Y >= 2X)
	reg [7:0]  div_x;

	reg [15:0] t16, ya;
	reg [16:0] t17;
	reg [8:0]  t9;
	reg [7:0]  t8;
	reg [2:0]  bt;
	reg        tb;
	reg [15:0] nextpc;
	reg [7:0]  ps;

	// end the instruction: the next cycle fetches the opcode at np
	task fin; input [15:0] np; begin PC <= np; rd(np); t <= 5'd0; end endtask

	always @(posedge clk) begin
		if (rst) begin
			A <= 8'h00; X <= 8'h00; Y <= 8'h00; SP <= 8'hEF; PSW <= 8'h02;
			PC <= 16'hFFC0; stopped <= 1'b0;
			t <= 5'd30;                 // reset: read the vector at FFFE
			rd(16'hFFFE);
		end else if (ce) begin
			if (t == 5'd30) begin       // reset vector, low byte
				dv <= din; rd(16'hFFFF); t <= 5'd31;
			end else if (t == 5'd31) begin
				fin({din, dv});
			end else if (stopped) begin
				// asleep: the next byte read, an idle cycle, over and over
				if (bus_rd) idle(); else rd(PC);
			end else if (t == 5'd0) begin
				// ===== the opcode ===========================================================
				ir <= din;
				nextpc = PC + 16'd1;
				PC <= nextpc;
				t <= 5'd1;
				// the first cycle after it: an operand fetch, or -- a one-byte instruction -- a
				// dummy read of the next byte (DBNZ Y reads its offset twice), or idle
				case (din)
				// one-byte instructions (and DBNZ Y): read the next byte, not keep it
				8'h00, 8'h01, 8'h06, 8'h0D, 8'h0F, 8'h11, 8'h19, 8'h1C, 8'h1D, 8'h20, 8'h21, 8'h26,
				8'h2D, 8'h31, 8'h39, 8'h3C, 8'h3D, 8'h40, 8'h41, 8'h46, 8'h4D, 8'h51, 8'h59, 8'h5C,
				8'h5D, 8'h60, 8'h61, 8'h66, 8'h6D, 8'h6F, 8'h71, 8'h79, 8'h7C, 8'h7D, 8'h7F, 8'h80,
				8'h81, 8'h86, 8'h8E, 8'h91, 8'h99, 8'h9C, 8'h9D, 8'h9E, 8'h9F, 8'hA0, 8'hA1, 8'hA6,
				8'hAE, 8'hAF, 8'hB1, 8'hB9, 8'hBC, 8'hBD, 8'hBE, 8'hBF, 8'hC0, 8'hC1, 8'hC6, 8'hCE,
				8'hCF, 8'hD1, 8'hDC, 8'hDD, 8'hDF, 8'hE0, 8'hE1, 8'hE6, 8'hED, 8'hEE, 8'hEF, 8'hF1,
				8'hFC, 8'hFD, 8'hFE, 8'hFF:
					rd(nextpc);
				default: rd(nextpc);    // (operand fetch: same address; the step decides)
				endcase
			end else begin
				// ===== the steps =========================================================
				t <= t + 5'd1;
				casez (ir)
				// ---------- ALU on A: d, abs, (X), [d+X], #, d+X, abs+X, abs+Y, [d]+Y ----------
				8'b???00100, 8'b???00101, 8'b???00110, 8'b???00111, 8'b???01000,
				8'b???10100, 8'b???10101, 8'b???10110, 8'b???10111: if (alu_row) begin
					case ({ir[4], ir[2:0]})
					4'b0100: case (t)                                         // d
						1: begin o1 <= din; PC <= PC + 16'd1; ma <= dp(din, PSW[FP]); rd(dp(din, PSW[FP])); end
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					4'b0101: case (t)                                         // abs
						1: begin o1 <= din; PC <= PC + 16'd1; rd(PC + 16'd1); end
						2: begin PC <= PC + 16'd1; ma <= {din, o1}; rd({din, o1}); end
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					4'b0110: case (t)                                         // (X)
						1: begin rd(dp(X, PSW[FP])); end
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					4'b0111: case (t)                                         // [d+X]
						1: begin o1 <= din; PC <= PC + 16'd1; idle(); end
						2: rd(dp(o1 + X, PSW[FP]));
						3: begin dv <= din; rd(dp(o1 + X + 8'd1, PSW[FP])); end
						4: rd({din, dv});
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					4'b0000: begin                                            // #imm
						alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC + 16'd1);
					end
					4'b1100: case (t)                                         // d+X
						1: begin o1 <= din; PC <= PC + 16'd1; idle(); end
						2: rd(dp(o1 + X, PSW[FP]));
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					4'b1101, 4'b1110: case (t)                                // abs+X, abs+Y
						1: begin o1 <= din; PC <= PC + 16'd1; rd(PC + 16'd1); end
						2: begin PC <= PC + 16'd1; o2 <= din; idle(); end
						3: rd({o2, o1} + {8'h00, ir[1] ? Y : X});
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					default: case (t)                                         // [d]+Y
						1: begin o1 <= din; PC <= PC + 16'd1; idle(); end
						2: rd(dp(o1, PSW[FP]));
						3: begin dv <= din; rd(dp(o1 + 8'd1, PSW[FP])); end
						4: rd({din, dv} + {8'h00, Y});
						default: begin alu(alu_k, A, din, PSW); if (alu_k != 3'd3) A <= alu_r; PSW <= alu_psw; fin(PC); end
						endcase
					endcase
				end else begin
					spc_rest();
				end
				// ---------- dd,ds / d,#imm / (X),(Y) for the ALU rows ----------
				8'b???01001, 8'b???11000, 8'b???11001: if (alu_row) begin
					if (t == 5'd20) fin(PC);      // (after the write / the idle cycle)
					else case ({ir[4], ir[0]})
					2'b01: case (t)                                           // d, ds
						1: begin PC <= PC + 16'd1; rd(dp(din, PSW[FP])); end
						2: begin dv <= din; rd(PC); end
						3: begin PC <= PC + 16'd1; o2 <= din; rd(dp(din, PSW[FP])); end
						default: begin
							alu(alu_k, din, dv, PSW); PSW <= alu_psw;
							if (alu_k == 3'd3) begin idle(); t <= 5'd20; end
							else begin wr(dp(o2, PSW[FP]), alu_r); t <= 5'd20; end
						end
						endcase
					2'b10: case (t)                                           // d, #imm
						1: begin PC <= PC + 16'd1; dv <= din; rd(PC + 16'd1); end
						2: begin PC <= PC + 16'd1; o2 <= din; rd(dp(din, PSW[FP])); end
						default: begin
							alu(alu_k, din, dv, PSW); PSW <= alu_psw;
							if (alu_k == 3'd3) begin idle(); t <= 5'd20; end
							else begin wr(dp(o2, PSW[FP]), alu_r); t <= 5'd20; end
						end
						endcase
					default: case (t)                                         // (X), (Y)
						1: rd(dp(Y, PSW[FP]));
						2: begin dv <= din; rd(dp(X, PSW[FP])); end
						default: begin
							alu(alu_k, din, dv, PSW); PSW <= alu_psw;
							if (alu_k == 3'd3) begin idle(); t <= 5'd20; end
							else begin wr(dp(X, PSW[FP]), alu_r); t <= 5'd20; end
						end
						endcase
					endcase
				end else begin
					spc_rest();
				end
				default: spc_rest();
				endcase
			end
		end
	end

	// --- everything else ------------------------------------------------------------------------
	task spc_rest;
		begin
			case (ir)
			// ---------- shifts / INC / DEC on memory: d, abs, d+X; on A ----------
			8'h0B, 8'h2B, 8'h4B, 8'h6B, 8'h8B, 8'hAB: case (t)                 // d
				1: begin PC <= PC + 16'd1; ma <= dp(din, PSW[FP]); rd(dp(din, PSW[FP])); end
				2: begin shift(ir, din, PSW[FC]); wr(ma, sh_r);
				         PSW[FN] <= sh_r[7]; PSW[FZ] <= (sh_r == 8'h00); if (!ir[7]) PSW[FC] <= sh_c; end
				default: fin(PC);
				endcase
			8'h0C, 8'h2C, 8'h4C, 8'h6C, 8'h8C, 8'hAC: case (t)                 // abs
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; ma <= {din, o1}; rd({din, o1}); end
				3: begin shift(ir, din, PSW[FC]); wr(ma, sh_r);
				         PSW[FN] <= sh_r[7]; PSW[FZ] <= (sh_r == 8'h00); if (!ir[7]) PSW[FC] <= sh_c; end
				default: fin(PC);
				endcase
			8'h1B, 8'h3B, 8'h5B, 8'h7B, 8'h9B, 8'hBB: case (t)                 // d+X
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: begin ma <= dp(o1 + X, PSW[FP]); rd(dp(o1 + X, PSW[FP])); end
				3: begin shift(ir, din, PSW[FC]); wr(ma, sh_r);
				         PSW[FN] <= sh_r[7]; PSW[FZ] <= (sh_r == 8'h00); if (!ir[7]) PSW[FC] <= sh_c; end
				default: fin(PC);
				endcase
			8'h1C, 8'h3C, 8'h5C, 8'h7C, 8'h9C, 8'hBC: begin                     // A
				shift(ir[7] ? {ir[7:5], 5'd0} : ir, A, PSW[FC]);
				A <= sh_r; PSW[FN] <= sh_r[7]; PSW[FZ] <= (sh_r == 8'h00);
				if (!ir[7]) PSW[FC] <= sh_c;
				fin(PC);
			end
			8'h1D, 8'h3D, 8'hDC, 8'hFC: begin                                   // DEC X, INC X, DEC Y, INC Y
				t8 = (ir == 8'h1D) ? X - 8'd1 : (ir == 8'h3D) ? X + 8'd1 : (ir == 8'hDC) ? Y - 8'd1 : Y + 8'd1;
				if (ir == 8'h1D || ir == 8'h3D) X <= t8; else Y <= t8;
				PSW[FN] <= t8[7]; PSW[FZ] <= (t8 == 8'h00);
				fin(PC);
			end

			// ---------- compares on X / Y ----------
			8'h1E, 8'h5E: case (t)                                               // CMP X/Y, abs
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; rd({din, o1}); end
				default: begin t9 = {1'b0, (ir == 8'h1E) ? X : Y} - {1'b0, din};
				               PSW[FC] <= !t9[8]; PSW[FN] <= t9[7]; PSW[FZ] <= (t9[7:0] == 8'h00); fin(PC); end
				endcase
			8'h3E, 8'h7E: case (t)                                               // CMP X/Y, d
				1: begin PC <= PC + 16'd1; rd(dp(din, PSW[FP])); end
				default: begin t9 = {1'b0, (ir == 8'h3E) ? X : Y} - {1'b0, din};
				               PSW[FC] <= !t9[8]; PSW[FN] <= t9[7]; PSW[FZ] <= (t9[7:0] == 8'h00); fin(PC); end
				endcase
			8'hC8, 8'hAD: begin                                                  // CMP X/Y, #imm
				t9 = {1'b0, (ir == 8'hC8) ? X : Y} - {1'b0, din};
				PSW[FC] <= !t9[8]; PSW[FN] <= t9[7]; PSW[FZ] <= (t9[7:0] == 8'h00);
				fin(PC + 16'd1);
			end

			// ---------- loads ----------
			8'hE4, 8'hF8, 8'hEB: case (t)                                        // A/X/Y <- d
				1: begin PC <= PC + 16'd1; rd(dp(din, PSW[FP])); end
				default: begin ld(ir, din); fin(PC); end
				endcase
			8'hE5, 8'hE9, 8'hEC: case (t)                                        // <- abs
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; rd({din, o1}); end
				default: begin ld(ir, din); fin(PC); end
				endcase
			8'hE6: case (t)                                                       // A <- (X)
				1: rd(dp(X, PSW[FP]));
				default: begin ld(ir, din); fin(PC); end
				endcase
			8'hBF: case (t)                                                       // A <- (X)+
				1: rd(dp(X, PSW[FP]));
				2: begin ld(ir, din); idle(); end
				default: begin X <= X + 8'd1; fin(PC); end
				endcase
			8'hE7: case (t)                                                       // A <- [d+X]
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: rd(dp(o1 + X, PSW[FP]));
				3: begin dv <= din; rd(dp(o1 + X + 8'd1, PSW[FP])); end
				4: rd({din, dv});
				default: begin ld(ir, din); fin(PC); end
				endcase
			8'hE8, 8'hCD, 8'h8D: begin ld(ir, din); fin(PC + 16'd1); end         // #imm
			8'hF4, 8'hF9, 8'hFB: case (t)                                        // <- d+X / d+Y / d+X
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: rd(dp(o1 + ((ir == 8'hF9) ? Y : X), PSW[FP]));
				default: begin ld(ir, din); fin(PC); end
				endcase
			8'hF5, 8'hF6: case (t)                                               // A <- abs+X / abs+Y
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; o2 <= din; idle(); end
				3: rd({o2, o1} + {8'h00, (ir == 8'hF6) ? Y : X});
				default: begin ld(ir, din); fin(PC); end
				endcase
			8'hF7: case (t)                                                       // A <- [d]+Y
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: rd(dp(o1, PSW[FP]));
				3: begin dv <= din; rd(dp(o1 + 8'd1, PSW[FP])); end
				4: rd({din, dv} + {8'h00, Y});
				default: begin ld(ir, din); fin(PC); end
				endcase

			// ---------- stores (each reads its address first) ----------
			8'hC4, 8'hD8, 8'hCB: case (t)                                        // d <- A/X/Y
				1: begin PC <= PC + 16'd1; ma <= dp(din, PSW[FP]); rd(dp(din, PSW[FP])); end
				2: wr(ma, st_val(ir));
				default: fin(PC);
				endcase
			8'hC5, 8'hC9, 8'hCC: case (t)                                        // abs
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; ma <= {din, o1}; rd({din, o1}); end
				3: wr(ma, st_val(ir));
				default: fin(PC);
				endcase
			8'hC6: case (t)                                                       // (X) <- A
				1: begin ma <= dp(X, PSW[FP]); rd(dp(X, PSW[FP])); end
				2: wr(ma, A);
				default: fin(PC);
				endcase
			8'hC7: case (t)                                                       // [d+X] <- A
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: rd(dp(o1 + X, PSW[FP]));
				3: begin dv <= din; rd(dp(o1 + X + 8'd1, PSW[FP])); end
				4: begin ma <= {din, dv}; rd({din, dv}); end
				5: wr(ma, A);
				default: fin(PC);
				endcase
			8'hD4, 8'hD9, 8'hDB: case (t)                                        // d+X / d+Y / d+X
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: begin ma <= dp(o1 + ((ir == 8'hD9) ? Y : X), PSW[FP]); rd(dp(o1 + ((ir == 8'hD9) ? Y : X), PSW[FP])); end
				3: wr(ma, st_val(ir));
				default: fin(PC);
				endcase
			8'hD5, 8'hD6: case (t)                                               // abs+X / abs+Y
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; o2 <= din; idle(); end
				3: begin ma <= {o2, o1} + {8'h00, (ir == 8'hD6) ? Y : X}; rd({o2, o1} + {8'h00, (ir == 8'hD6) ? Y : X}); end
				4: wr(ma, A);
				default: fin(PC);
				endcase
			8'hD7: case (t)                                                       // [d]+Y <- A
				1: begin PC <= PC + 16'd1; o1 <= din; rd(dp(din, PSW[FP])); end
				2: begin dv <= din; rd(dp(o1 + 8'd1, PSW[FP])); end
				3: begin ma <= {din, dv} + {8'h00, Y}; idle(); end
				4: rd(ma);
				5: wr(ma, A);
				default: fin(PC);
				endcase
			8'hAF: case (t)                                                       // (X)+ <- A
				1: idle();
				2: wr(dp(X, PSW[FP]), A);
				default: begin X <= X + 8'd1; fin(PC); end
				endcase
			8'h8F: case (t)                                                       // d <- #imm
				1: begin PC <= PC + 16'd1; dv <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; ma <= dp(din, PSW[FP]); rd(dp(din, PSW[FP])); end
				3: wr(ma, dv);
				default: fin(PC);
				endcase
			8'hFA: case (t)                                                       // dd <- ds
				1: begin PC <= PC + 16'd1; rd(dp(din, PSW[FP])); end
				2: begin dv <= din; rd(PC); end
				3: begin PC <= PC + 16'd1; wr(dp(din, PSW[FP]), dv); end
				default: fin(PC);
				endcase

			// ---------- register moves ----------
			8'h5D: begin X <= A; PSW[FN] <= A[7]; PSW[FZ] <= (A == 8'h00); fin(PC); end
			8'h7D: begin A <= X; PSW[FN] <= X[7]; PSW[FZ] <= (X == 8'h00); fin(PC); end
			8'hDD: begin A <= Y; PSW[FN] <= Y[7]; PSW[FZ] <= (Y == 8'h00); fin(PC); end
			8'hFD: begin Y <= A; PSW[FN] <= A[7]; PSW[FZ] <= (A == 8'h00); fin(PC); end
			8'h9D: begin X <= SP; PSW[FN] <= SP[7]; PSW[FZ] <= (SP == 8'h00); fin(PC); end
			8'hBD: begin SP <= X; fin(PC); end

			// ---------- 16-bit ----------
			8'hBA: case (t)                                                       // MOVW YA, d
				1: begin PC <= PC + 16'd1; o1 <= din; rd(dp(din, PSW[FP])); end
				2: begin dv <= din; idle(); end
				3: rd(dp(o1 + 8'd1, PSW[FP]));
				default: begin A <= dv; Y <= din; PSW[FN] <= din[7]; PSW[FZ] <= ({din, dv} == 16'h0000); fin(PC); end
				endcase
			8'hDA: case (t)                                                       // MOVW d, YA
				1: begin PC <= PC + 16'd1; o1 <= din; rd(dp(din, PSW[FP])); end
				2: wr(dp(o1, PSW[FP]), A);
				3: wr(dp(o1 + 8'd1, PSW[FP]), Y);
				default: fin(PC);
				endcase
			8'h3A, 8'h1A: case (t)                                               // INCW / DECW
				1: begin PC <= PC + 16'd1; o1 <= din; rd(dp(din, PSW[FP])); end
				2: begin t9 = (ir == 8'h3A) ? {1'b0, din} + 9'd1 : {1'b0, din} - 9'd1;
				         dv <= t9[7:0]; dv2 <= {7'd0, t9[8]}; wr(dp(o1, PSW[FP]), t9[7:0]); end
				3: rd(dp(o1 + 8'd1, PSW[FP]));
				4: begin
					// the high byte with the low byte's carry / borrow
					t8 = (ir == 8'h3A) ? din + {7'd0, dv2[0]} : din - {7'd0, dv2[0]};
					wr(dp(o1 + 8'd1, PSW[FP]), t8);
					PSW[FN] <= t8[7]; PSW[FZ] <= ({t8, dv} == 16'h0000);
				end
				default: fin(PC);
				endcase
			8'h7A, 8'h9A, 8'h5A: case (t)                                        // ADDW / SUBW / CMPW
				1: begin PC <= PC + 16'd1; o1 <= din; rd(dp(din, PSW[FP])); end
				2: begin dv <= din; if (ir == 8'h5A) rd(dp(o1 + 8'd1, PSW[FP])); else idle(); end
				3: if (ir == 8'h5A) begin
					ya = {Y, A}; t17 = {1'b0, ya} - {1'b0, din, dv};
					PSW[FC] <= !t17[16]; PSW[FN] <= t17[15]; PSW[FZ] <= (t17[15:0] == 16'h0000);
					fin(PC);
				end else rd(dp(o1 + 8'd1, PSW[FP]));
				default: begin
					ya = {Y, A}; t16 = {din, dv};
					if (ir == 8'h7A) begin
						t17 = {1'b0, ya} + {1'b0, t16};
						PSW[FC] <= t17[16];
						PSW[FV] <= ~(ya[15] ^ t16[15]) & (ya[15] ^ t17[15]);
						PSW[FH] <= ({1'b0, ya[11:0]} + {1'b0, t16[11:0]}) > 13'h0FFF;
					end else begin
						t17 = {1'b0, ya} - {1'b0, t16};
						PSW[FC] <= !t17[16];
						PSW[FV] <= (ya[15] ^ t16[15]) & (ya[15] ^ t17[15]);
						PSW[FH] <= ya[11:0] >= t16[11:0];
					end
					A <= t17[7:0]; Y <= t17[15:8];
					PSW[FN] <= t17[15]; PSW[FZ] <= (t17[15:0] == 16'h0000);
					fin(PC);
				end
				endcase
			8'hCF: if (t == 5'd8) begin                                          // MUL
				t16 = Y * A;
				A <= t16[7:0]; Y <= t16[15:8]; PSW[FN] <= t16[15]; PSW[FZ] <= (t16[15:8] == 8'h00);
				fin(PC);
			end else idle();
			8'h9E: begin                                                         // DIV
				if (t == 5'd1) begin
					// set up: the chip's two branches (Fullsnes; the model's _div)
					PSW[FV] <= (Y >= X); PSW[FH] <= (Y[3:0] >= X[3:0]);
					div_x <= X;
					if ({1'b0, Y} < {X, 1'b0}) begin
						div_big <= 1'b0; dvd <= {Y, A}; dvs <= {1'b0, X};
					end else begin
						div_big <= 1'b1; dvd <= {Y, A} - {X, 9'd0}; dvs <= 9'd256 - {1'b0, X};
					end
					rem <= 9'd0;
					idle();
				end else if (t >= 5'd2 && t <= 5'd9) begin
					// two restoring steps a cycle: 16 quotient bits in 8 cycles
					t9 = rem; t16 = dvd;
					for (bt = 0; bt < 2; bt = bt + 1) begin
						t9 = {t9[7:0], t16[15]};
						t16 = {t16[14:0], 1'b0};
						if ({1'b0, t9} >= {1'b0, dvs}) begin t9 = t9 - dvs; t16[0] = 1'b1; end
					end
					rem <= t9; dvd <= t16;
					idle();
				end else if (t == 5'd11) begin
					if (!div_big) begin A <= dvd[7:0]; Y <= rem[7:0]; t8 = dvd[7:0]; end
					else begin t8 = 8'd255 - dvd[7:0]; A <= t8; Y <= div_x + rem[7:0]; end
					PSW[FN] <= t8[7]; PSW[FZ] <= (t8 == 8'h00);
					fin(PC);
				end else idle();
			end
			8'hDF, 8'hBE: if (t == 5'd2) begin                                   // DAA / DAS
				t9 = {1'b0, A}; tb = PSW[FC];
				if (ir == 8'hDF) begin
					if (PSW[FC] || A > 8'h99) begin t9 = t9 + 9'h060; tb = 1'b1; end
					if (PSW[FH] || t9[3:0] > 4'd9) t9 = t9 + 9'd6;
				end else begin
					if (!PSW[FC] || A > 8'h99) begin t9 = t9 - 9'h060; tb = 1'b0; end
					if (!PSW[FH] || t9[3:0] > 4'd9) t9 = t9 - 9'd6;
				end
				A <= t9[7:0]; PSW[FC] <= tb; PSW[FN] <= t9[7]; PSW[FZ] <= (t9[7:0] == 8'h00);
				fin(PC);
			end else idle();
			8'h9F: if (t == 5'd4) begin                                          // XCN
				A <= {A[3:0], A[7:4]}; PSW[FN] <= A[3]; PSW[FZ] <= (A == 8'h00);
				fin(PC);
			end else idle();

			// ---------- bits ----------
			8'h02, 8'h22, 8'h42, 8'h62, 8'h82, 8'hA2, 8'hC2, 8'hE2,                     // SET1 d.b
			8'h12, 8'h32, 8'h52, 8'h72, 8'h92, 8'hB2, 8'hD2, 8'hF2: case (t)              // CLR1 d.b
				1: begin PC <= PC + 16'd1; ma <= dp(din, PSW[FP]); rd(dp(din, PSW[FP])); end
				2: begin t8 = din; t8[ir[7:5]] = !ir[4]; wr(ma, t8); end
				default: fin(PC);
				endcase
			8'h03, 8'h23, 8'h43, 8'h63, 8'h83, 8'hA3, 8'hC3, 8'hE3,                     // BBS
			8'h13, 8'h33, 8'h53, 8'h73, 8'h93, 8'hB3, 8'hD3, 8'hF3: case (t)              // BBC
				1: begin PC <= PC + 16'd1; rd(dp(din, PSW[FP])); end
				2: begin dv <= din; idle(); end
				3: rd(PC);
				4: begin
					PC <= PC + 16'd1;
					if (dv[ir[7:5]] == !ir[4]) begin o1 <= din; idle(); end
					else fin(PC + 16'd1);
				end
				5: idle();
				default: fin(PC + {{8{o1[7]}}, o1});
				endcase
			8'h4A, 8'h6A, 8'h0A, 8'h2A, 8'h8A, 8'hAA, 8'hCA, 8'hEA: case (t)    // the m.b ops
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; o2 <= din; ma <= {3'd0, din[4:0], o1}; rd({3'd0, din[4:0], o1}); end
				3: begin
					bt = o2[7:5]; tb = din[bt];
					dv <= din;
					case (ir)
					8'h4A: begin PSW[FC] <= PSW[FC] & tb;  fin(PC); end    // AND1
					8'h6A: begin PSW[FC] <= PSW[FC] & !tb; fin(PC); end    // AND1 /
					8'h0A: begin PSW[FC] <= PSW[FC] | tb;  idle(); end     // OR1
					8'h2A: begin PSW[FC] <= PSW[FC] | !tb; idle(); end     // OR1 /
					8'h8A: begin PSW[FC] <= PSW[FC] ^ tb;  idle(); end     // EOR1
					8'hAA: begin PSW[FC] <= tb; fin(PC); end               // MOV1 C, m.b
					8'hCA: idle();                                         // MOV1 m.b, C
					default: begin t8 = din; t8[bt] = !tb; wr(ma, t8); end // NOT1
					endcase
				end
				4: if (ir == 8'hCA) begin t8 = dv; t8[o2[7:5]] = PSW[FC]; wr(ma, t8); end
				   else fin(PC);
				default: fin(PC);
				endcase
			8'h0E, 8'h4E: case (t)                                               // TSET1 / TCLR1
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; ma <= {din, o1}; rd({din, o1}); end
				3: begin dv <= din; t8 = A - din; PSW[FN] <= t8[7]; PSW[FZ] <= (t8 == 8'h00); rd(ma); end
				4: wr(ma, (ir == 8'h0E) ? (dv | A) : (dv & ~A));
				default: fin(PC);
				endcase

			// ---------- branches ----------
			8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0, 8'h2F: case (t)
				1: begin
					PC <= PC + 16'd1; o1 <= din;
					if (br(ir, PSW)) idle(); else fin(PC + 16'd1);
				end
				2: idle();
				default: fin(PC + {{8{o1[7]}}, o1});
				endcase
			8'h2E: case (t)                                                       // CBNE d
				1: begin PC <= PC + 16'd1; rd(dp(din, PSW[FP])); end
				2: begin dv <= din; idle(); end
				3: rd(PC);
				4: begin PC <= PC + 16'd1; o1 <= din; if (dv != A) idle(); else fin(PC + 16'd1); end
				5: idle();
				default: fin(PC + {{8{o1[7]}}, o1});
				endcase
			8'hDE: case (t)                                                       // CBNE d+X
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: rd(dp(o1 + X, PSW[FP]));
				3: begin dv <= din; idle(); end
				4: rd(PC);
				5: begin PC <= PC + 16'd1; o1 <= din; if (dv != A) idle(); else fin(PC + 16'd1); end
				6: idle();
				default: fin(PC + {{8{o1[7]}}, o1});
				endcase
			8'h6E: case (t)                                                       // DBNZ d
				1: begin PC <= PC + 16'd1; ma <= dp(din, PSW[FP]); rd(dp(din, PSW[FP])); end
				2: begin dv <= din - 8'd1; wr(ma, din - 8'd1); end
				3: rd(PC);
				4: begin PC <= PC + 16'd1; o1 <= din; if (dv != 8'h00) idle(); else fin(PC + 16'd1); end
				5: idle();
				default: fin(PC + {{8{o1[7]}}, o1});
				endcase
			8'hFE: case (t)                                                       // DBNZ Y
				1: begin Y <= Y - 8'd1; idle(); end
				2: rd(PC);
				3: begin PC <= PC + 16'd1; o1 <= din; if (Y != 8'h00) idle(); else fin(PC + 16'd1); end
				4: idle();
				default: fin(PC + {{8{o1[7]}}, o1});
				endcase

			// ---------- jumps and calls ----------
			8'h5F: case (t)                                                       // JMP !a
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				default: fin({din, o1});
				endcase
			8'h1F: case (t)                                                       // JMP [!a+X]
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; ma <= {din, o1} + {8'h00, X}; idle(); end
				3: rd(ma);
				4: begin dv <= din; rd(ma + 16'd1); end
				default: fin({din, dv});
				endcase
			8'h3F: case (t)                                                       // CALL !a
				1: begin PC <= PC + 16'd1; o1 <= din; rd(PC + 16'd1); end
				2: begin PC <= PC + 16'd1; o2 <= din; idle(); end
				3: begin wr({8'h01, SP}, PC[15:8]); SP <= SP - 8'd1; end
				4: begin wr({8'h01, SP}, PC[7:0]); SP <= SP - 8'd1; end
				5: idle();
				6: idle();
				default: fin({o2, o1});
				endcase
			8'h4F: case (t)                                                       // PCALL u
				1: begin PC <= PC + 16'd1; o1 <= din; idle(); end
				2: begin wr({8'h01, SP}, PC[15:8]); SP <= SP - 8'd1; end
				3: begin wr({8'h01, SP}, PC[7:0]); SP <= SP - 8'd1; end
				4: idle();
				default: fin({8'hFF, o1});
				endcase
			8'h01, 8'h11, 8'h21, 8'h31, 8'h41, 8'h51, 8'h61, 8'h71,                 // TCALL n
			8'h81, 8'h91, 8'hA1, 8'hB1, 8'hC1, 8'hD1, 8'hE1, 8'hF1: case (t)
				1: idle();
				2: begin wr({8'h01, SP}, PC[15:8]); SP <= SP - 8'd1; end
				3: begin wr({8'h01, SP}, PC[7:0]); SP <= SP - 8'd1; end
				4: idle();
				5: rd(16'hFFDE - {11'd0, ir[7:4], 1'b0});
				6: begin dv <= din; rd(16'hFFDF - {11'd0, ir[7:4], 1'b0}); end
				default: fin({din, dv});
				endcase
			8'h0F: case (t)                                                       // BRK
				1: begin wr({8'h01, SP}, PC[15:8]); SP <= SP - 8'd1; end
				2: begin wr({8'h01, SP}, PC[7:0]); SP <= SP - 8'd1; end
				3: begin wr({8'h01, SP}, PSW); SP <= SP - 8'd1; end
				4: idle();
				5: rd(16'hFFDE);
				6: begin dv <= din; rd(16'hFFDF); end
				default: begin PSW[FB] <= 1'b1; PSW[FI] <= 1'b0; fin({din, dv}); end
				endcase
			8'h6F: case (t)                                                       // RET
				1: idle();
				2: rd({8'h01, SP + 8'd1});
				3: begin SP <= SP + 8'd1; dv <= din; rd({8'h01, SP + 8'd2}); end
				default: begin SP <= SP + 8'd1; fin({din, dv}); end
				endcase
			8'h7F: case (t)                                                       // RETI
				1: idle();
				2: rd({8'h01, SP + 8'd1});
				3: begin SP <= SP + 8'd1; PSW <= din; rd({8'h01, SP + 8'd2}); end
				4: begin SP <= SP + 8'd1; dv <= din; rd({8'h01, SP + 8'd2}); end
				default: begin SP <= SP + 8'd1; fin({din, dv}); end
				endcase

			// ---------- the stack ----------
			8'h2D, 8'h4D, 8'h6D, 8'h0D: case (t)                                 // PUSH A/X/Y/PSW
				1: begin wr({8'h01, SP}, (ir == 8'h2D) ? A : (ir == 8'h4D) ? X : (ir == 8'h6D) ? Y : PSW);
				         SP <= SP - 8'd1; end
				2: idle();
				default: fin(PC);
				endcase
			8'hAE, 8'hCE, 8'hEE, 8'h8E: case (t)                                 // POP A/X/Y/PSW
				1: idle();
				2: rd({8'h01, SP + 8'd1});
				default: begin
					SP <= SP + 8'd1;
					case (ir) 8'hAE: A <= din; 8'hCE: X <= din; 8'hEE: Y <= din; default: PSW <= din; endcase
					fin(PC);
				end
				endcase

			// ---------- flags ----------
			8'h20: begin PSW[FP] <= 1'b0; fin(PC); end
			8'h40: begin PSW[FP] <= 1'b1; fin(PC); end
			8'h60: begin PSW[FC] <= 1'b0; fin(PC); end
			8'h80: begin PSW[FC] <= 1'b1; fin(PC); end
			8'hE0: begin PSW[FV] <= 1'b0; PSW[FH] <= 1'b0; fin(PC); end
			8'hED: if (t == 5'd2) begin PSW[FC] <= !PSW[FC]; fin(PC); end else idle();
			8'hA0: if (t == 5'd2) begin PSW[FI] <= 1'b1; fin(PC); end else idle();
			8'hC0: if (t == 5'd2) begin PSW[FI] <= 1'b0; fin(PC); end else idle();
			8'h00: fin(PC);                                                       // NOP
			8'hEF, 8'hFF: case (t)                                                // SLEEP / STOP
				1: idle();
				2: rd(PC);
				3: idle();
				4: rd(PC);
				5: idle();
				default: begin stopped <= 1'b1; rd(PC); end
				endcase
			default: fin(PC);
			endcase
		end
	endtask

	// the value a store writes
	function [7:0] st_val;
		input [7:0] opc;
		st_val = (opc == 8'hD8 || opc == 8'hC9 || opc == 8'hD9) ? X :
		         (opc == 8'hCB || opc == 8'hCC || opc == 8'hDB) ? Y : A;
	endfunction

	// a load: into A / X / Y by opcode, with N and Z
	task ld;
		input [7:0] opc; input [7:0] v;
		begin
			case (opc)
			8'hCD, 8'hF8, 8'hF9, 8'hE9: X <= v;
			8'h8D, 8'hEB, 8'hFB, 8'hEC: Y <= v;
			default: A <= v;
			endcase
			PSW[FN] <= v[7]; PSW[FZ] <= (v == 8'h00);
		end
	endtask

	function br;
		input [7:0] opc; input [7:0] p;
		case (opc)
		8'h10: br = !p[FN]; 8'h30: br = p[FN];
		8'h50: br = !p[FV]; 8'h70: br = p[FV];
		8'h90: br = !p[FC]; 8'hB0: br = p[FC];
		8'hD0: br = !p[FZ]; 8'hF0: br = p[FZ];
		default: br = 1'b1;           // BRA
		endcase
	endfunction
endmodule
