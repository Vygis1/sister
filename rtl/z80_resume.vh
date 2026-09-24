//////////////////////////////////////////////////////////////////////////////////
// z80_resume.vh - what to do once a gathered operand has arrived.
//
// Included into S_EXEC in z80.v, and only reached when `cont` is not C_NONE.
// The enclosing block has already defaulted `st <= S_FETCH` (the instruction is
// over) and `cont <= C_NONE` (the next one starts clean); anything needing a
// second step overrides both.
//
// It has to be an include rather than a module: several of these registers are
// also written by the decode and by the sequencer's frame, and splitting them
// across always blocks would make them multi-driven -- which synthesis rejects
// and simulation quietly tolerates, so it would work here and fail on the board.
//////////////////////////////////////////////////////////////////////////////////

case (cont)

// A displacement arrived. Fold it into the address that was parked in wz and
// carry on with whatever needed the address -- that is what `after` holds.
// The displacement is signed, so it is sign-extended, not zero-extended.
C_DISP: begin
	wz   <= wz + {{8{tmp[7]}}, tmp};
	cont <= after;
	st   <= S_EXEC;
	case (after)
	C_LDRM, C_ALUM, C_INCM, C_CBM: begin
		// These all need the byte at the address, so go and read it.
		wz     <= wz + {{8{tmp[7]}}, tmp};
		ret_st <= S_EXEC;
		st     <= S_MRD;
	end
	C_LDMN: begin
		// LD (IX+d),n -- the address is known, the immediate is not yet.
		ret_st <= S_EXEC;
		st     <= S_IMM;
	end
	default: begin
		// LD (IX+d),r -- tmp2 already holds the byte to store.
		tmp    <= tmp2;
		ret_st <= S_FETCH;
		st     <= S_MWR;
	end
	endcase
end

// --- loads ------------------------------------------------------------------
C_LDRN: begin
	if (dst == RM) begin
		// LD (HL),n. The prefixed form went through C_DISP and lands in C_LDMN.
		wz     <= HL;
		ret_st <= S_FETCH;
		st     <= S_MWR;
	end else begin
		wr_reg(dst, tmp, 1'b0);
	end
end

C_LDMN: begin ret_st <= S_FETCH; st <= S_MWR; end

C_LDRM: wr_reg(dst, tmp, 1'b1);        // never redirected by the prefix

C_LDRPNN: wr_rp16(op[5:4], wz, 1'b0);

C_LDNNA: begin tmp <= R[RA]; ret_st <= S_FETCH; st <= S_MWR; end
C_LDANN: begin ret_st <= S_EXEC; cont <= C_LDRM; dst <= RA; st <= S_MRD; end

C_LDNNHL: begin
	tmp    <= IDX[7:0];
	tmp2   <= IDX[15:8];
	ret_st <= S_FETCH;
	st     <= S_MWRW;
end
// The only continuation that still needs its prefix a step later: which
// register the word lands in is not decided until C_LDHLNN2.
C_LDHLNN: begin pfx <= pfx; ret_st <= S_EXEC; cont <= C_LDHLNN2; st <= S_MRDW; end
C_LDHLNN2: if (pfx == 2'd1)      IX <= {tmp2, tmp};
           else if (pfx == 2'd2) IY <= {tmp2, tmp};
           else begin R[RH] <= tmp2; R[RL] <= tmp; end

// --- arithmetic --------------------------------------------------------------
C_ALUM: begin
	do_alu(alukind, R[RA], tmp);
	if (alukind != 3'd7) R[RA] <= alu_r;   // CP discards the result
	F <= alu_f;
end

C_INCM: begin
	if (incdec) do_dec(tmp); else do_inc(tmp);
	F      <= alu_f;
	tmp    <= alu_r;
	ret_st <= S_FETCH;
	st     <= S_MWR;
end

// --- control flow ---------------------------------------------------------------
C_JP: if (taken) PC <= wz;

C_JR: if (taken) PC <= PC + {{8{tmp[7]}}, tmp};

C_CALL: begin
	if (taken) begin
		tmp    <= PC[7:0];
		tmp2   <= PC[15:8];
		cont   <= C_CALL2;
		ret_st <= S_EXEC;
		st     <= S_PUSH1;
	end
end
C_CALL2: PC <= wz;

C_RST: PC <= wz;

C_RET: PC <= {tmp2, tmp};

C_POPRP: wr_rp16(op[5:4], {tmp2, tmp}, 1'b1);

// --- I/O --------------------------------------------------------------------------
// The high half of the address on an IN A,(n) is A itself, not zero.
C_INN: begin
	wz     <= {R[RA], tmp};
	cont   <= C_INN2;
	ret_st <= S_EXEC;
	st     <= S_IORD;
end
C_INN2: R[RA] <= tmp;

C_OUTN: begin
	wz     <= {R[RA], tmp};
	tmp    <= R[RA];
	ret_st <= S_FETCH;
	st     <= S_IOWR;
end

// --- EX (SP),HL ---------------------------------------------------------------------
C_EXSP: begin
	if (pfx == 2'd1)      IX <= {tmp2, tmp};
	else if (pfx == 2'd2) IY <= {tmp2, tmp};
	else begin R[RH] <= tmp2; R[RL] <= tmp; end
	tmp    <= IDX[7:0];
	tmp2   <= IDX[15:8];
	wz     <= SP;
	ret_st <= S_FETCH;
	st     <= S_MWRW;
end

// --- the CB page on memory ------------------------------------------------------------
C_CBM: begin
	cbv = tmp;
	case (op[7:6])
	2'b00: begin
		do_rot(op[5:3], cbv);
		F      <= alu_f;
		tmp    <= alu_r;
		ret_st <= S_FETCH;
		st     <= S_MWR;
	end
	2'b01: begin
		// BIT takes its X and Y from the ADDRESS for the memory forms, not from
		// the operand -- one of the corners ZEXALL exists to catch.
		F <= {cbv[op[5:3]] ? (op[5:3] == 3'd7) : 1'b0,
		      ~cbv[op[5:3]], wz[13], 1'b1, wz[11],
		      ~cbv[op[5:3]], 1'b0, F[FC]};
	end
	2'b10: begin
		tmp    <= cbv & ~(8'd1 << op[5:3]);
		ret_st <= S_FETCH;
		st     <= S_MWR;
	end
	default: begin
		tmp    <= cbv | (8'd1 << op[5:3]);
		ret_st <= S_FETCH;
		st     <= S_MWR;
	end
	endcase
end

// --- DDCB / FDCB ----------------------------------------------------------------------
// These put the displacement BEFORE the opcode, so the operand address is known
// before the operation is.
C_DDCBD: begin
	wz     <= wz + {{8{tmp[7]}}, tmp};
	cont   <= C_DDCBOP;
	ret_st <= S_EXEC;
	st     <= S_IMM;
end
C_DDCBOP: begin
	op     <= tmp;
	cont   <= C_CBM;
	ret_st <= S_EXEC;
	st     <= S_MRD;
end

// --- the ED page's absolute loads ---------------------------------------------------------
C_EDNNW: begin
	case (op[5:4])
	2'd0: begin tmp <= R[RC]; tmp2 <= R[RB]; end
	2'd1: begin tmp <= R[RE]; tmp2 <= R[RD]; end
	2'd2: begin tmp <= R[RL]; tmp2 <= R[RH]; end
	default: begin tmp <= SP[7:0]; tmp2 <= SP[15:8]; end
	endcase
	ret_st <= S_FETCH;
	st     <= S_MWRW;
end
C_EDNNR: begin cont <= C_EDNNR2; ret_st <= S_EXEC; st <= S_MRDW; end
C_EDNNR2: case (op[5:4])
	2'd0: begin R[RB] <= tmp2; R[RC] <= tmp; end
	2'd1: begin R[RD] <= tmp2; R[RE] <= tmp; end
	2'd2: begin R[RH] <= tmp2; R[RL] <= tmp; end
	default: SP <= {tmp2, tmp};
	endcase

// --- the block instructions ------------------------------------------------------
// Each is a read, a write, a pointer update, and a decision about whether to do
// it again. The repeat is done by winding PC back over the two-byte opcode
// rather than by looping inside the instruction, which is also how the real
// thing does it -- and why an interrupt can land in the middle of an LDIR.

// LDI / LDD / LDIR / LDDR: the byte from (HL) is in tmp, so send it to (DE).
C_LDBLK: begin
	wz     <= DE;
	cont   <= C_LDBLK2;
	ret_st <= S_EXEC;
	st     <= S_MWR;
end
C_LDBLK2: begin
	hlx = op[3] ? (HL - 16'd1) : (HL + 16'd1);
	dex = op[3] ? (DE - 16'd1) : (DE + 16'd1);
	bcx = BC - 16'd1;
	R[RH] <= hlx[15:8]; R[RL] <= hlx[7:0];
	R[RD] <= dex[15:8]; R[RE] <= dex[7:0];
	R[RB] <= bcx[15:8]; R[RC] <= bcx[7:0];
	// X and Y come from A plus the byte just moved -- bits 3 and 1 of it, not
	// 3 and 5. One of the odder corners of the instruction set.
	blkn = R[RA] + tmp;
	F <= {F[FS], F[FZ], blkn[1], 1'b0, blkn[3], bcx != 16'd0, 1'b0, F[FC]};
	if (op[4] && bcx != 16'd0) PC <= PC - 16'd2;
end

// CPI / CPD / CPIR / CPDR: compare rather than move, and stop early on a match.
C_CPBLK: begin
	blkd = R[RA] - tmp;
	blkb = R[RA][4] ^ tmp[4] ^ blkd[4];        // the half-borrow
	hlx  = op[3] ? (HL - 16'd1) : (HL + 16'd1);
	bcx  = BC - 16'd1;
	R[RH] <= hlx[15:8]; R[RL] <= hlx[7:0];
	R[RB] <= bcx[15:8]; R[RC] <= bcx[7:0];
	blkn = blkd - {7'd0, blkb[0]};
	F <= {blkd[7], blkd == 8'd0, blkn[1], blkb[0], blkn[3],
	      bcx != 16'd0, 1'b1, F[FC]};          // the carry is left alone
	if (op[4] && bcx != 16'd0 && blkd != 8'd0) PC <= PC - 16'd2;
end

// INI / IND / INIR / INDR: the byte from the port is in tmp, store it at (HL).
C_INBLK: begin
	wz     <= HL;
	cont   <= C_INBLK2;
	ret_st <= S_EXEC;
	st     <= S_MWR;
end
C_INBLK2: begin
	blkb = R[RB] - 8'd1;
	hlx  = op[3] ? (HL - 16'd1) : (HL + 16'd1);
	R[RB] <= blkb;
	R[RH] <= hlx[15:8]; R[RL] <= hlx[7:0];
	F <= {blkb[7], blkb == 8'd0, blkb[5], 1'b0, blkb[3],
	      parity8(blkb), tmp[7], F[FC]};
	if (op[4] && blkb != 8'd0) PC <= PC - 16'd2;
end

// OUTI / OUTD / OTIR / OTDR: B is decremented BEFORE the port write, so the
// address that goes out already carries the new count.
C_OUTBLK: begin
	blkb = R[RB] - 8'd1;
	R[RB] <= blkb;
	wz    <= {blkb, R[RC]};
	cont   <= C_OUTBLK2;
	ret_st <= S_EXEC;
	st     <= S_IOWR;
end
C_OUTBLK2: begin
	hlx = op[3] ? (HL - 16'd1) : (HL + 16'd1);
	R[RH] <= hlx[15:8]; R[RL] <= hlx[7:0];
	F <= {R[RB][7], R[RB] == 8'd0, R[RB][5], 1'b0, R[RB][3],
	      parity8(R[RB]), tmp[7], F[FC]};
	if (op[4] && R[RB] != 8'd0) PC <= PC - 16'd2;
end

// --- RRD / RLD -----------------------------------------------------------------
// A nibble-wide rotate through A's low half and the byte at (HL). Used for
// packed BCD, and the only instructions that move half a byte.
C_RRD: begin
	if (op[3]) begin                            // $6F RLD
		blkn = {tmp[3:0], R[RA][3:0]};
		blkd = {R[RA][7:4], tmp[7:4]};
	end else begin                              // $67 RRD
		blkn = {R[RA][3:0], tmp[7:4]};
		blkd = {R[RA][7:4], tmp[3:0]};
	end
	R[RA] <= blkd;
	F <= {blkd[7], blkd == 8'd0, blkd[5], 1'b0, blkd[3],
	      parity8(blkd), 1'b0, F[FC]};
	tmp    <= blkn;
	ret_st <= S_FETCH;
	st     <= S_MWR;
end

// --- IN r,(C) --------------------------------------------------------------------
// Unlike IN A,(n), this one sets flags. The 110 encoding sets them and stores
// nothing, which is the only way to test a port without disturbing a register.
C_INRC: begin
	if (dst != RM) R[dst] <= tmp;
	F <= {tmp[7], tmp == 8'd0, tmp[5], 1'b0, tmp[3],
	      parity8(tmp), 1'b0, F[FC]};
end

default: ;
endcase
