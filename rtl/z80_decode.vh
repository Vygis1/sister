//////////////////////////////////////////////////////////////////////////////////
// z80_decode.vh - the instruction decode, included into S_EXEC in z80.v.
//
// Only reached when `cont` is C_NONE, so this is always the start of a new
// instruction. The enclosing block has already defaulted `st <= S_FETCH` and
// cleared `pfx`, `cb` and `ed`, so a prefix opcode re-asserts what it needs and
// everything else simply ends.
//
// Order matters throughout. Specific opcodes are matched before the patterns
// they sit inside: 0x76 is HALT and not LD (HL),(HL); 0xE9 is JP (HL) and not a
// conditional jump; 0xEB is EX DE,HL and not a CALL. Each `casez` here is
// written exceptions-first for that reason.
//
// Anything touching memory parks its address in `wz` and hands off to a shared
// gathering state, naming what should happen next in `cont`. Under DD or FD the
// address is IDX and a displacement has to be fetched first, so those forms set
// `after` and go through C_DISP.
//////////////////////////////////////////////////////////////////////////////////

// ================================ the CB page ================================
if (cb) begin
	if (op[2:0] == RM) begin
		wz     <= HL;                   // the prefixed form never reaches here
		cont   <= C_CBM;
		ret_st <= S_EXEC;
		st     <= S_MRD;
	end else begin
		cbv = rd_reg(op[2:0], 1'b1);    // CB operands ignore the prefix
		case (op[7:6])
		2'b00: begin
			do_rot(op[5:3], cbv);
			wr_reg(op[2:0], alu_r, 1'b1);
			F <= alu_f;
		end
		2'b01: F <= {cbv[op[5:3]] ? (op[5:3] == 3'd7) : 1'b0,
		             ~cbv[op[5:3]], cbv[5], 1'b1, cbv[3],
		             ~cbv[op[5:3]], 1'b0, F[FC]};              // BIT
		2'b10: wr_reg(op[2:0], cbv & ~(8'd1 << op[5:3]), 1'b1); // RES
		default: wr_reg(op[2:0], cbv | (8'd1 << op[5:3]), 1'b1); // SET
		endcase
	end
end

// ================================ the ED page ================================
else if (ed) begin
	casez (op)
	8'b01??_1010: begin                              // ADC HL,ss
		do_adc16(HL, rp16(op[5:4], 1'b0), 1'b1);
		R[RH] <= alu16[15:8]; R[RL] <= alu16[7:0];
		F <= alu_f;
	end
	8'b01??_0010: begin                              // SBC HL,ss
		do_adc16(HL, rp16(op[5:4], 1'b0), 1'b0);
		R[RH] <= alu16[15:8]; R[RL] <= alu16[7:0];
		F <= alu_f;
	end
	8'b01??_0011: begin cont <= C_EDNNW; ret_st <= S_EXEC; st <= S_IMMW; end // LD (nn),dd
	8'b01??_1011: begin cont <= C_EDNNR; ret_st <= S_EXEC; st <= S_IMMW; end // LD dd,(nn)

	8'b01??_?100: begin                              // NEG, all eight encodings
		do_alu(3'd2, 8'd0, R[RA]);
		R[RA] <= alu_r;
		F <= alu_f;
	end
	8'b01??_?101: begin                              // RETN / RETI
		IFF1 <= IFF2;
		cont <= C_RET; ret_st <= S_EXEC; st <= S_POP1;
	end
	8'b01??_?110: case (op[4:3])                     // IM 0 / 1 / 2
		2'd0, 2'd1: IM <= 2'd0;
		2'd2:       IM <= 2'd1;
		default:    IM <= 2'd2;
		endcase

	8'h47: I  <= R[RA];
	8'h4F: Rr <= R[RA];
	// LD A,I and LD A,R put the interrupt enable into the parity flag, which is
	// the only way a program can read IFF2.
	8'h57: begin R[RA] <= I;
		F <= {I[7], I == 8'd0, I[5], 1'b0, I[3], IFF2, 1'b0, F[FC]}; end
	8'h5F: begin R[RA] <= Rr;
		F <= {Rr[7], Rr == 8'd0, Rr[5], 1'b0, Rr[3], IFF2, 1'b0, F[FC]}; end

	// RRD and RLD rotate a nibble between A and (HL). $67 is RRD, $6F is RLD,
	// which is bit 3 of the opcode.
	8'h67, 8'h6F: begin
		wz <= HL; cont <= C_RRD; ret_st <= S_EXEC; st <= S_MRD;
	end

	8'b01??_?000: begin                              // IN r,(C)
		wz <= BC; dst <= op[5:3];
		cont <= C_INRC; ret_st <= S_EXEC; st <= S_IORD;
	end
	8'b01??_?001: begin                              // OUT (C),r
		wz  <= BC;
		// The 110 encoding has no register behind it and puts out a zero.
		tmp <= (op[5:3] == RM) ? 8'd0 : R[op[5:3]];
		ret_st <= S_FETCH; st <= S_IOWR;
	end

	// The block instructions: $A0-$A3, $A8-$AB, $B0-$B3, $B8-$BB. Bit 4 says
	// repeat, bit 3 says count downwards, and the low two bits pick the family.
	// Bit 2 is what separates them from the holes around them.
	8'b101?_?0??: case (op[1:0])
		2'd0, 2'd1: begin                            // LDx / CPx
			wz <= HL;
			cont <= op[0] ? C_CPBLK : C_LDBLK;
			ret_st <= S_EXEC; st <= S_MRD;
		end
		2'd2: begin                                  // INx
			wz <= BC;
			cont <= C_INBLK; ret_st <= S_EXEC; st <= S_IORD;
		end
		default: begin                               // OUTx
			wz <= HL;
			cont <= C_OUTBLK; ret_st <= S_EXEC; st <= S_MRD;
		end
		endcase

	default: ;                                       // the ED page is mostly holes
	endcase
end

// =============================== the main page ===============================
else begin
	casez (op)
	// --- prefixes: re-assert and go straight back for another opcode ---------
	8'hDD: begin pfx <= 2'd1; st <= S_FETCH; end
	8'hFD: begin pfx <= 2'd2; st <= S_FETCH; end
	8'hED: begin ed  <= 1'b1; st <= S_FETCH; end
	8'hCB: begin
		cb  <= 1'b1;
		pfx <= pfx;
		if (pfx == 2'd0) begin
			st <= S_FETCH;
		end else begin
			// DDCB and FDCB carry the displacement before the opcode.
			wz     <= IDX;
			cont   <= C_DDCBD;
			ret_st <= S_EXEC;
			st     <= S_IMM;
		end
	end

	// --- 0x00-0x3F ------------------------------------------------------------
	8'h00: ;
	8'h08: begin                                      // EX AF,AF'
		R[RA] <= Rs[RA]; Rs[RA] <= R[RA];
		F     <= Fs;     Fs     <= F;
	end
	8'h10: begin                                      // DJNZ e
		R[RB] <= R[RB] - 8'd1;
		taken <= (R[RB] != 8'd1);
		cont  <= C_JR; ret_st <= S_EXEC; st <= S_IMM;
	end
	8'h18: begin taken <= 1'b1; cont <= C_JR; ret_st <= S_EXEC; st <= S_IMM; end
	8'b001?_?000: begin                               // JR cc,e
		taken <= cond_met({1'b0, op[4:3]});
		cont  <= C_JR; ret_st <= S_EXEC; st <= S_IMM;
	end

	8'h02: begin wz <= BC; tmp <= R[RA]; ret_st <= S_FETCH; st <= S_MWR; end
	8'h12: begin wz <= DE; tmp <= R[RA]; ret_st <= S_FETCH; st <= S_MWR; end
	8'h0A: begin wz <= BC; dst <= RA; cont <= C_LDRM; ret_st <= S_EXEC; st <= S_MRD; end
	8'h1A: begin wz <= DE; dst <= RA; cont <= C_LDRM; ret_st <= S_EXEC; st <= S_MRD; end

	8'h22: begin pfx <= pfx; cont <= C_LDNNHL; ret_st <= S_EXEC; st <= S_IMMW; end
	8'h2A: begin pfx <= pfx; cont <= C_LDHLNN; ret_st <= S_EXEC; st <= S_IMMW; end
	8'h32: begin cont <= C_LDNNA; ret_st <= S_EXEC; st <= S_IMMW; end
	8'h3A: begin cont <= C_LDANN; ret_st <= S_EXEC; st <= S_IMMW; end

	8'b00??_0001: begin pfx <= pfx; cont <= C_LDRPNN; ret_st <= S_EXEC; st <= S_IMMW; end
	8'b00??_1001: begin                               // ADD HL,ss
		do_add16(IDX, rp16(op[5:4], 1'b0));
		if (pfx == 2'd1)      IX <= alu16;
		else if (pfx == 2'd2) IY <= alu16;
		else begin R[RH] <= alu16[15:8]; R[RL] <= alu16[7:0]; end
		F <= alu_f;
	end
	8'b00??_0011: wr_rp16(op[5:4], rp16(op[5:4], 1'b0) + 16'd1, 1'b0);
	8'b00??_1011: wr_rp16(op[5:4], rp16(op[5:4], 1'b0) - 16'd1, 1'b0);

	8'b00??_?100, 8'b00??_?101: begin                 // INC r / DEC r
		incdec <= op[0];
		if (op[5:3] == RM) begin
			pfx <= pfx;
			if (pfx == 2'd0) begin
				wz <= HL; cont <= C_INCM; ret_st <= S_EXEC; st <= S_MRD;
			end else begin
				wz <= IDX; cont <= C_DISP; after <= C_INCM;
				ret_st <= S_EXEC; st <= S_IMM;
			end
		end else begin
			if (op[0]) do_dec(rd_reg(op[5:3], 1'b0));
			else       do_inc(rd_reg(op[5:3], 1'b0));
			wr_reg(op[5:3], alu_r, 1'b0);
			F <= alu_f;
		end
	end

	8'b00??_?110: begin                               // LD r,n
		dst <= op[5:3];
		if (op[5:3] == RM && pfx != 2'd0) begin
			pfx <= pfx;
			wz <= IDX; cont <= C_DISP; after <= C_LDMN;
			ret_st <= S_EXEC; st <= S_IMM;
		end else begin
			pfx <= pfx;
			cont <= C_LDRN; ret_st <= S_EXEC; st <= S_IMM;
		end
	end

	// The four accumulator rotates keep S, Z and P, unlike their CB cousins.
	8'h07, 8'h0F, 8'h17, 8'h1F: begin
		do_rot({1'b0, op[4:3]}, R[RA]);
		R[RA] <= alu_r;
		F <= {F[FS], F[FZ], alu_r[5], 1'b0, alu_r[3], F[FP], 1'b0, alu_f[FC]};
	end

	8'h27: begin do_daa(R[RA]); R[RA] <= alu_r; F <= alu_f; end
	8'h2F: begin                                      // CPL
		R[RA] <= ~R[RA];
		F <= {F[FS], F[FZ], ~R[RA][5], 1'b1, ~R[RA][3], F[FP], 1'b1, F[FC]};
	end
	8'h37: F <= {F[FS], F[FZ], R[RA][5], 1'b0, R[RA][3], F[FP], 1'b0, 1'b1};
	8'h3F: F <= {F[FS], F[FZ], R[RA][5], F[FC], R[RA][3], F[FP], 1'b0, ~F[FC]};

	// --- 0x40-0x7F: LD r,r', with HALT in the middle of it --------------------
	8'h76: begin halted <= 1'b1; st <= S_FETCH; end
	8'b01??_????: begin
		if (op[2:0] == RM) begin                      // LD r,(HL) / (IX+d)
			dst <= op[5:3];
			if (pfx == 2'd0) begin
				wz <= HL; cont <= C_LDRM; ret_st <= S_EXEC; st <= S_MRD;
			end else begin
				pfx <= pfx;
				wz <= IDX; cont <= C_DISP; after <= C_LDRM;
				ret_st <= S_EXEC; st <= S_IMM;
			end
		end else if (op[5:3] == RM) begin             // LD (HL),r / (IX+d),r
			if (pfx == 2'd0) begin
				wz <= HL; tmp <= R[op[2:0]];
				ret_st <= S_FETCH; st <= S_MWR;
			end else begin
				pfx <= pfx;
				// The source is NOT redirected by the prefix, and it is parked
				// in tmp2 because tmp is about to hold the displacement.
				tmp2 <= R[op[2:0]];
				wz <= IDX; cont <= C_DISP; after <= C_NONE;
				ret_st <= S_EXEC; st <= S_IMM;
			end
		end else begin
			wr_reg(op[5:3], rd_reg(op[2:0], 1'b0), 1'b0);
		end
	end

	// --- 0x80-0xBF: ALU A,r ----------------------------------------------------
	8'b10??_????: begin
		alukind <= op[5:3];
		if (op[2:0] == RM) begin
			if (pfx == 2'd0) begin
				wz <= HL; cont <= C_ALUM; ret_st <= S_EXEC; st <= S_MRD;
			end else begin
				pfx <= pfx;
				wz <= IDX; cont <= C_DISP; after <= C_ALUM;
				ret_st <= S_EXEC; st <= S_IMM;
			end
		end else begin
			do_alu(op[5:3], R[RA], rd_reg(op[2:0], 1'b0));
			if (op[5:3] != 3'd7) R[RA] <= alu_r;
			F <= alu_f;
		end
	end

	// --- 0xC0-0xFF --------------------------------------------------------------
	8'hC9: begin cont <= C_RET; ret_st <= S_EXEC; st <= S_POP1; end
	8'hD9: for (i = 0; i < 6; i = i + 1) begin R[i] <= Rs[i]; Rs[i] <= R[i]; end
	8'hE9: PC <= IDX;
	8'hF9: SP <= IDX;

	8'hE3: begin                                      // EX (SP),HL
		pfx <= pfx; wz <= SP;
		cont <= C_EXSP; ret_st <= S_EXEC; st <= S_MRDW;
	end
	8'hEB: begin                                      // EX DE,HL
		R[RD] <= R[RH]; R[RE] <= R[RL];
		R[RH] <= R[RD]; R[RL] <= R[RE];
	end

	8'hF3: begin IFF1 <= 1'b0; IFF2 <= 1'b0; end
	8'hFB: begin IFF1 <= 1'b1; IFF2 <= 1'b1; end

	8'hD3: begin cont <= C_OUTN; ret_st <= S_EXEC; st <= S_IMM; end
	8'hDB: begin cont <= C_INN;  ret_st <= S_EXEC; st <= S_IMM; end

	8'hC3: begin taken <= 1'b1; cont <= C_JP; ret_st <= S_EXEC; st <= S_IMMW; end
	8'hCD: begin taken <= 1'b1; cont <= C_CALL; ret_st <= S_EXEC; st <= S_IMMW; end

	8'b11??_0001: begin pfx <= pfx; cont <= C_POPRP; ret_st <= S_EXEC; st <= S_POP1; end
	8'b11??_0101: begin                               // PUSH qq
		tmp  <= rp16(op[5:4], 1'b1);
		tmp2 <= rp16(op[5:4], 1'b1) >> 8;
		ret_st <= S_FETCH;
		st <= S_PUSH1;
	end

	8'b11??_?000: begin                               // RET cc
		if (cond_met(op[5:3])) begin
			cont <= C_RET; ret_st <= S_EXEC; st <= S_POP1;
		end
	end
	8'b11??_?010: begin                               // JP cc,nn
		taken <= cond_met(op[5:3]);
		cont  <= C_JP; ret_st <= S_EXEC; st <= S_IMMW;
	end
	8'b11??_?100: begin                               // CALL cc,nn
		taken <= cond_met(op[5:3]);
		cont  <= C_CALL; ret_st <= S_EXEC; st <= S_IMMW;
	end
	8'b11??_?110: begin                               // ALU A,n
		alukind <= op[5:3];
		cont <= C_ALUM; ret_st <= S_EXEC; st <= S_IMM;
	end
	8'b11??_?111: begin                               // RST p
		tmp  <= PC[7:0];
		tmp2 <= PC[15:8];
		wz   <= {10'd0, op[5:3], 3'd0};
		cont <= C_RST; ret_st <= S_EXEC; st <= S_PUSH1;
	end

	default: ;
	endcase
end
