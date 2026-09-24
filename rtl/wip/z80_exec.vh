//////////////////////////////////////////////////////////////////////////////////
// z80_exec.vh - the decode, included into the sequencer's case in z80.v.
//
// Split out only for length. It is one branch of one case statement in one
// clocked block, and it has to stay that way: several of these registers are
// written both here and by the frame of the sequencer, and splitting them
// across blocks would make them multi-driven.
//
// The order of the tests matters. Specific opcodes are matched before the
// patterns they sit inside -- 0x76 is HALT rather than LD (HL),(HL), 0xE9 is
// JP (HL) rather than a conditional jump -- so every `casez` here is written
// with the exceptions first.
//////////////////////////////////////////////////////////////////////////////////

S_EXEC: begin
	// Default: the instruction is over, and the prefix state does not carry
	// into the next one. A prefix opcode overrides both of these.
	st  <= S_FETCH;
	pfx <= 2'd0;
	cb  <= 1'b0;
	ed  <= 1'b0;

	// ============================ the CB page =============================
	// Rotates, BIT, RES and SET, and completely regular: bits 7:6 pick the
	// group, 5:3 the bit number or shift kind, 2:0 the operand.
	if (cb) begin
		if (op[2:0] == RM) begin
			// The operand is memory. Under DD/FD the address was worked out
			// before the opcode was even fetched, which is why this form has
			// its displacement already in wz.
			if (pfx == 2'd0) wz <= HL;
			ret_st <= S_EXEC;
			cbst   <= 2'd1;
			cb     <= 1'b1;
			pfx    <= pfx;
			st     <= S_MRD;
		end else begin
			cb_val = rd_reg(op[2:0], 1'b1);
			cb_do(op, cb_val);
			if (op[7:6] != 2'b01) wr_reg(op[2:0], alu_r, 1'b1);
			F <= alu_f;
		end
	end

	// ============================ the ED page =============================
	else if (ed) begin
		casez (op)
		// --- 16-bit ALU on HL ---
		8'b01??_1010: begin                       // ADC HL,ss
			adc16(HL, rp16(op[5:4]), 1'b1);
			{R[RH], R[RL]} <= alu16;
			F <= alu_f;
			wz <= HL + 16'd1;
		end
		8'b01??_0010: begin                       // SBC HL,ss
			adc16(HL, rp16(op[5:4]), 1'b0);
			{R[RH], R[RL]} <= alu16;
			F <= alu_f;
			wz <= HL + 16'd1;
		end

		// --- LD (nn),dd and LD dd,(nn) ---
		8'b01??_0011: begin                       // LD (nn),dd
			ed <= 1'b1; pfx <= pfx;
			edst <= 2'd1;
			ret_st <= S_EXEC;
			st <= S_IMMW;
		end
		8'b01??_1011: begin                       // LD dd,(nn)
			ed <= 1'b1; pfx <= pfx;
			edst <= 2'd2;
			ret_st <= S_EXEC;
			st <= S_IMMW;
		end

		8'b01??_?100: begin                       // NEG (all eight encodings)
			do_alu(3'd2, 8'd0, R[RA]);
			R[RA] <= alu_r;
			F <= alu_f;
		end

		8'b01??_?101: begin                       // RETN / RETI
			IFF1 <= IFF2;
			ed <= 1'b1; edst <= 2'd3;
			ret_st <= S_EXEC;
			st <= S_POP1;
		end

		8'b01??_?110: begin                       // IM 0/1/2
			case (op[4:3])
			2'd0, 2'd1: IM <= 2'd0;
			2'd2:       IM <= 2'd1;
			default:    IM <= 2'd2;
			endcase
		end

		8'h47: I  <= R[RA];                       // LD I,A
		8'h4F: Rr <= R[RA];                       // LD R,A
		8'h57: begin                              // LD A,I
			R[RA] <= I;
			F <= {I[7], I == 8'd0, I[5], 1'b0, I[3], IFF2, 1'b0, F[FC]};
		end
		8'h5F: begin                              // LD A,R
			R[RA] <= Rr;
			F <= {Rr[7], Rr == 8'd0, Rr[5], 1'b0, Rr[3], IFF2, 1'b0, F[FC]};
		end

		8'h67, 8'h6F: begin                       // RRD / RLD
			wz <= HL;
			ed <= 1'b1; edst <= 2'd0; rld_kind <= op[3];
			ret_st <= S_EXEC;
			st <= S_MRD;
			edphase <= 1'b1;
		end

		// --- I/O on (C) ---
		8'b01??_?000: begin                       // IN r,(C)
			wz <= BC;
			ed <= 1'b1; pfx <= pfx;
			edst <= 2'd1; edphase <= 1'b1;
			ret_st <= S_EXEC;
			st <= S_IORD;
		end
		8'b01??_?001: begin                       // OUT (C),r
			wz  <= BC;
			tmp <= (op[5:3] == RM) ? 8'd0 : R[op[5:3]];
			ret_st <= S_FETCH;
			st <= S_IOWR;
		end

		// --- block moves and searches ---
		8'b10?0_0000, 8'b10?0_0001,               // LDI/LDD, CPI/CPD
		8'b10?1_0000, 8'b10?1_0001: begin
			wz <= HL;
			ed <= 1'b1; edst <= 2'd2; edphase <= 1'b1;
			ret_st <= S_EXEC;
			st <= S_MRD;
		end

		default: ;                                // the ED page is mostly holes
		endcase
	end

	// ============================ the main page ============================
	else begin
		casez (op)
		// --- prefixes: set the state and go straight back for another opcode --
		8'hDD: begin pfx <= 2'd1; st <= S_FETCH; end
		8'hFD: begin pfx <= 2'd2; st <= S_FETCH; end
		8'hED: begin ed  <= 1'b1; st <= S_FETCH; end
		8'hCB: begin
			cb <= 1'b1;
			pfx <= pfx;
			if (pfx == 2'd0) begin
				st <= S_FETCH;
			end else begin
				// DDCB and FDCB put the displacement BEFORE the opcode, so it
				// has to be collected here and the real opcode fetched after.
				wz <= IDX;
				ret_st <= S_EXEC;
				ddcb <= 1'b1;
				st <= S_IMM;
			end
		end

		// --- 0x00-0x3F ---------------------------------------------------
		8'h00: ;                                          // NOP
		8'h08: begin                                      // EX AF,AF'
			R[RA] <= Rs[RA]; Rs[RA] <= R[RA];
			F <= Fs; Fs <= F;
		end
		8'h10: begin                                      // DJNZ e
			R[RB] <= R[RB] - 8'd1;
			jr_taken <= (R[RB] != 8'd1);
			ret_st <= S_EXEC; jrst <= 1'b1;
			st <= S_IMM;
		end
		8'h18: begin                                      // JR e
			jr_taken <= 1'b1;
			ret_st <= S_EXEC; jrst <= 1'b1;
			st <= S_IMM;
		end
		8'b001?_?000: begin                               // JR cc,e
			jr_taken <= cond_met({1'b0, op[4:3]});
			ret_st <= S_EXEC; jrst <= 1'b1;
			st <= S_IMM;
		end

		8'b00??_0001: begin                               // LD dd,nn
			pfx <= pfx;
			ldst <= 2'd1;
			ret_st <= S_EXEC;
			st <= S_IMMW;
		end
		8'b00??_1001: begin                               // ADD HL,ss
			add16(IDX, rp16(op[5:4]));
			wr_idx(alu16);
			F <= alu_f;
		end

		8'h02: begin wz <= BC; tmp <= R[RA]; ret_st <= S_FETCH; st <= S_MWR; end  // LD (BC),A
		8'h12: begin wz <= DE; tmp <= R[RA]; ret_st <= S_FETCH; st <= S_MWR; end  // LD (DE),A
		8'h0A: begin wz <= BC; dst <= RA; ret_st <= S_EXEC; ldst <= 2'd2; st <= S_MRD; end
		8'h1A: begin wz <= DE; dst <= RA; ret_st <= S_EXEC; ldst <= 2'd2; st <= S_MRD; end

		8'h22: begin pfx <= pfx; ldst <= 2'd3; ret_st <= S_EXEC; st <= S_IMMW; end // LD (nn),HL
		8'h2A: begin pfx <= pfx; ldst <= 2'd0; ret_st <= S_EXEC; st <= S_IMMW; end // LD HL,(nn)
		8'h32: begin ldst <= 2'd3; a_mem <= 1'b1; ret_st <= S_EXEC; st <= S_IMMW; end // LD (nn),A
		8'h3A: begin ldst <= 2'd0; a_mem <= 1'b1; ret_st <= S_EXEC; st <= S_IMMW; end // LD A,(nn)

		8'b00??_0011: wr_rp16(op[5:4], rp16(op[5:4]) + 16'd1);   // INC dd
		8'b00??_1011: wr_rp16(op[5:4], rp16(op[5:4]) - 16'd1);   // DEC dd

		8'b00??_?100: begin                               // INC r
			if (op[5:3] == RM) begin
				pfx <= pfx; incdec <= 1'b0;
				if (pfx == 2'd0) begin
					wz <= HL; ret_st <= S_EXEC; ldst <= 2'd2; incst <= 1'b1; st <= S_MRD;
				end else begin
					wz <= IDX; ret_st <= S_EXEC; dispst <= 1'b1; incst <= 1'b1; st <= S_IMM;
				end
			end else begin
				do_inc(rd_reg(op[5:3], 1'b0));
				wr_reg(op[5:3], alu_r, 1'b0);
				F <= alu_f;
			end
		end
		8'b00??_?101: begin                               // DEC r
			if (op[5:3] == RM) begin
				pfx <= pfx; incdec <= 1'b1;
				if (pfx == 2'd0) begin
					wz <= HL; ret_st <= S_EXEC; ldst <= 2'd2; incst <= 1'b1; st <= S_MRD;
				end else begin
					wz <= IDX; ret_st <= S_EXEC; dispst <= 1'b1; incst <= 1'b1; st <= S_IMM;
				end
			end else begin
				do_dec(rd_reg(op[5:3], 1'b0));
				wr_reg(op[5:3], alu_r, 1'b0);
				F <= alu_f;
			end
		end

		8'b00??_?110: begin                               // LD r,n
			pfx <= pfx; dst <= op[5:3];
			if (op[5:3] == RM && pfx != 2'd0) begin
				wz <= IDX; ret_st <= S_EXEC; dispst <= 1'b1; ldnst <= 1'b1; st <= S_IMM;
			end else begin
				ret_st <= S_EXEC; ldnst <= 1'b1; st <= S_IMM;
			end
		end

		8'h07: begin do_rot(3'd0, R[RA]); R[RA] <= alu_r;  // RLCA
			F <= {F[FS], F[FZ], alu_r[5], 1'b0, alu_r[3], F[FP], 1'b0, alu_f[FC]}; end
		8'h0F: begin do_rot(3'd1, R[RA]); R[RA] <= alu_r;  // RRCA
			F <= {F[FS], F[FZ], alu_r[5], 1'b0, alu_r[3], F[FP], 1'b0, alu_f[FC]}; end
		8'h17: begin do_rot(3'd2, R[RA]); R[RA] <= alu_r;  // RLA
			F <= {F[FS], F[FZ], alu_r[5], 1'b0, alu_r[3], F[FP], 1'b0, alu_f[FC]}; end
		8'h1F: begin do_rot(3'd3, R[RA]); R[RA] <= alu_r;  // RRA
			F <= {F[FS], F[FZ], alu_r[5], 1'b0, alu_r[3], F[FP], 1'b0, alu_f[FC]}; end

		8'h27: begin do_daa(R[RA]); R[RA] <= alu_r; F <= alu_f; end   // DAA
		8'h2F: begin                                                   // CPL
			R[RA] <= ~R[RA];
			F <= {F[FS], F[FZ], (~R[RA]) & 8'h20 ? 1'b1 : 1'b0, 1'b1,
			      (~R[RA]) & 8'h08 ? 1'b1 : 1'b0, F[FP], 1'b1, F[FC]};
		end
		8'h37: F <= {F[FS], F[FZ], R[RA][5], 1'b0, R[RA][3], F[FP], 1'b0, 1'b1};  // SCF
		8'h3F: F <= {F[FS], F[FZ], R[RA][5], F[FC], R[RA][3], F[FP], 1'b0, ~F[FC]}; // CCF

		// --- 0x40-0x7F: LD r,r', with HALT sitting in the middle -----------
		8'h76: begin halted <= 1'b1; st <= S_FETCH; end
		8'b01??_????: begin
			if (op[2:0] == RM) begin                       // LD r,(HL) / (IX+d)
				pfx <= pfx; dst <= op[5:3];
				if (pfx == 2'd0) begin
					wz <= HL; ret_st <= S_EXEC; ldst <= 2'd2; st <= S_MRD;
				end else begin
					wz <= IDX; ret_st <= S_EXEC; dispst <= 1'b1; ldrst <= 1'b1; st <= S_IMM;
				end
			end else if (op[5:3] == RM) begin              // LD (HL),r / (IX+d),r
				pfx <= pfx;
				// The source register is NOT redirected by the prefix here.
				tmp <= rd_reg(op[2:0], 1'b1);
				if (pfx == 2'd0) begin
					wz <= HL; ret_st <= S_FETCH; st <= S_MWR;
				end else begin
					wz <= IDX; ret_st <= S_EXEC; dispst <= 1'b1; ldwst <= 1'b1; st <= S_IMM;
				end
			end else begin
				wr_reg(op[5:3], rd_reg(op[2:0], 1'b0), 1'b0);
			end
		end

		// --- 0x80-0xBF: ALU A,r -------------------------------------------
		8'b10??_????: begin
			if (op[2:0] == RM) begin
				pfx <= pfx; alukind <= op[5:3];
				if (pfx == 2'd0) begin
					wz <= HL; ret_st <= S_EXEC; alust <= 1'b1; st <= S_MRD;
				end else begin
					wz <= IDX; ret_st <= S_EXEC; dispst <= 1'b1; alust <= 1'b1; st <= S_IMM;
				end
			end else begin
				do_alu(op[5:3], R[RA], rd_reg(op[2:0], 1'b0));
				if (op[5:3] != 3'd7) R[RA] <= alu_r;
				F <= alu_f;
			end
		end

		// --- 0xC0-0xFF ------------------------------------------------------
		8'hC9: begin retst <= 1'b1; ret_st <= S_EXEC; st <= S_POP1; end   // RET
		8'b11??_?000: begin                                               // RET cc
			if (cond_met(op[5:3])) begin
				retst <= 1'b1; ret_st <= S_EXEC; st <= S_POP1;
			end
		end

		8'hD9: begin                                                      // EXX
			for (i = 0; i < 6; i = i + 1) begin
				R[i] <= Rs[i]; Rs[i] <= R[i];
			end
		end
		8'hE9: PC <= IDX;                                                 // JP (HL)
		8'hF9: SP <= IDX;                                                 // LD SP,HL

		8'b11??_0001: begin                                               // POP qq
			pfx <= pfx; popst <= 1'b1; ret_st <= S_EXEC; st <= S_POP1;
		end
		8'b11??_0101: begin                                               // PUSH qq
			case (op[5:4])
			2'd0: begin tmp <= R[RC];      tmp2 <= R[RB]; end
			2'd1: begin tmp <= R[RE];      tmp2 <= R[RD]; end
			2'd2: begin tmp <= IDX[7:0];   tmp2 <= IDX[15:8]; end
			default: begin tmp <= F;       tmp2 <= R[RA]; end
			endcase
			ret_st <= S_FETCH;
			st <= S_PUSH1;
		end

		8'hC3: begin jpst <= 2'd1; ret_st <= S_EXEC; st <= S_IMMW; end    // JP nn
		8'b11??_?010: begin                                               // JP cc,nn
			jpst <= cond_met(op[5:3]) ? 2'd1 : 2'd0;
			ret_st <= S_EXEC; st <= S_IMMW;
		end

		8'hCD: begin jpst <= 2'd3; ret_st <= S_EXEC; st <= S_IMMW; end    // CALL nn
		8'b11??_?100: begin                                               // CALL cc,nn
			jpst <= cond_met(op[5:3]) ? 2'd3 : 2'd0;
			ret_st <= S_EXEC; st <= S_IMMW;
		end

		8'b11??_?110: begin                                               // ALU A,n
			alukind <= op[5:3];
			ret_st <= S_EXEC; alust <= 1'b1; st <= S_IMM;
		end

		8'b11??_?111: begin                                               // RST p
			tmp  <= PC[7:0];
			tmp2 <= PC[15:8];
			wz   <= {10'd0, op[5:3], 3'd0};
			rstst <= 1'b1;
			ret_st <= S_EXEC;
			st <= S_PUSH1;
		end

		8'hD3: begin                                                      // OUT (n),A
			outst <= 1'b1; ret_st <= S_EXEC; st <= S_IMM;
		end
		8'hDB: begin                                                      // IN A,(n)
			inst_ <= 1'b1; ret_st <= S_EXEC; st <= S_IMM;
		end

		8'hE3: begin                                                      // EX (SP),HL
			pfx <= pfx; exsp <= 1'b1; wz <= SP;
			ret_st <= S_EXEC; st <= S_MRDW;
		end
		8'hEB: begin                                                      // EX DE,HL
			R[RD] <= R[RH]; R[RE] <= R[RL];
			R[RH] <= R[RD]; R[RL] <= R[RE];
		end

		8'hF3: begin IFF1 <= 1'b0; IFF2 <= 1'b0; end                      // DI
		8'hFB: begin IFF1 <= 1'b1; IFF2 <= 1'b1; end                      // EI

		default: ;
		endcase
	end
end
