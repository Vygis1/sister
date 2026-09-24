`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_z80_unit - fast, targeted checks on the Z80.
//
// ZEXDOC is the real verdict, but it runs for hours in simulation. This is the
// feedback loop that fits between edits: a few hundred cycles per check, aimed
// at the mechanisms most likely to be wrong rather than at coverage.
//
// What it goes after, in rough order of how easy each is to get subtly wrong:
//
//   - the half-carry and overflow flags, which no simple test notices
//   - the undocumented X and Y flag bits, and CP taking them from the operand
//     rather than the result
//   - prefix redirection: DD makes H into IXh, except where it must not
//   - DDCB, where the displacement comes BEFORE the opcode
//   - the 16-bit adds, which take their half-carry from bit 11
//   - the stack, since a wrong push order breaks every CALL in the same way
//
// Each case assembles a couple of instructions into memory, runs until the CPU
// reaches a HALT, then looks at the registers.
//////////////////////////////////////////////////////////////////////////////////

module tb_z80_unit;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	wire [15:0] addr;
	wire [7:0]  dout;
	reg  [7:0]  din;
	wire        we, io, m1;
	wire [15:0] dbg_pc, dbg_sp, dbg_af, dbg_bc, dbg_de, dbg_hl;

	z80 dut (
		.clk(clk), .rst(rst), .ce(1'b1),
		.addr(addr), .din(din), .dout(dout), .we(we), .io(io), .m1(m1),
		.int_n(1'b1), .nmi_n(1'b1),
		.dbg_pc(dbg_pc), .dbg_sp(dbg_sp), .dbg_af(dbg_af),
		.dbg_bc(dbg_bc), .dbg_de(dbg_de), .dbg_hl(dbg_hl), .dbg_m1()
	);

	reg [7:0] mem [0:65535];
	always @(posedge clk) begin
		if (we && !io) mem[addr] <= dout;
		din <= mem[addr];
	end

	integer errors = 0, i;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// Assemble at $0000 and run to the HALT the caller put at the end.
	integer plen;
	task prog;
		input [7:0] b;
		begin mem[plen] = b; plen = plen + 1; end
	endtask

	task start;
		begin
			for (i = 0; i < 256; i = i + 1) mem[i] = 8'h76;   // HALT everywhere
			// A known pattern for the block instructions to move and search.
			mem[16'h0080] = 8'hAA; mem[16'h0081] = 8'hBB;
			mem[16'h0082] = 8'hCC; mem[16'h0083] = 8'hDD;
			for (i = 16'h0090; i < 16'h00A0; i = i + 1) mem[i] = 8'h00;
			plen = 0;
		end
	endtask

	task run;
		integer guard;
		begin
			mem[plen] = 8'h76;
			rst = 1;
			repeat (3) @(posedge clk);
			rst = 0;
			force dut.SP = 16'h0200;
			@(posedge clk);
			release dut.SP;
			guard = 0;
			while (!dut.halted && guard < 4000) begin
				@(posedge clk);
				guard = guard + 1;
			end
			if (guard >= 4000) begin
				$display("  FAIL ran away (PC=0x%04X)", dbg_pc);
				errors = errors + 1;
			end
		end
	endtask

	wire [7:0] A = dbg_af[15:8];
	wire [7:0] Fl = dbg_af[7:0];

	initial begin
		$display("tb_z80_unit");

		// --- the half-carry, which nothing else will catch --------------------
		$display(" flags:");
		start;
		prog(8'h3E); prog(8'h0F);        // LD A,$0F
		prog(8'hC6); prog(8'h01);        // ADD A,$01
		run;
		check(A == 8'h10, "ADD A,n result");
		check(Fl[4] == 1'b1, "half-carry set crossing a nibble");

		start;
		prog(8'h3E); prog(8'h7F);        // LD A,$7F
		prog(8'hC6); prog(8'h01);        // ADD A,$01  -> $80, signed overflow
		run;
		check(Fl[2] == 1'b1, "overflow set when $7F+1 goes negative");
		check(Fl[7] == 1'b1, "sign set");
		check(Fl[0] == 1'b0, "no carry out of $7F+1");

		start;
		prog(8'h3E); prog(8'hFF);
		prog(8'hC6); prog(8'h01);        // $FF+1 -> 0, carry, no overflow
		run;
		check(Fl[6] == 1'b1 && Fl[0] == 1'b1, "zero and carry on $FF+1");
		check(Fl[2] == 1'b0, "no overflow on $FF+1");

		// CP throws its result away and takes X and Y from the OPERAND.
		start;
		prog(8'h3E); prog(8'hFF);        // LD A,$FF
		prog(8'h06); prog(8'h28);        // LD B,$28   (bits 5 and 3 set)
		prog(8'hB8);                     // CP B
		run;
		check(A == 8'hFF, "CP leaves A alone");
		check(Fl[5] == 1'b1 && Fl[3] == 1'b1, "CP takes X and Y from the operand");

		// --- INC and DEC touch H and V but never C ------------------------------
		$display(" inc/dec:");
		start;
		prog(8'h37);                     // SCF, so carry is set going in
		prog(8'h3E); prog(8'h0F);
		prog(8'h3C);                     // INC A
		run;
		check(A == 8'h10 && Fl[4] == 1'b1, "INC sets the half-carry at $0F");
		check(Fl[0] == 1'b1, "INC leaves the carry alone");

		start;
		prog(8'h3E); prog(8'h80);
		prog(8'h3D);                     // DEC A
		run;
		check(A == 8'h7F && Fl[2] == 1'b1, "DEC $80 overflows");
		check(Fl[1] == 1'b1, "DEC sets N");

		// --- 16-bit arithmetic ---------------------------------------------------
		$display(" 16-bit:");
		start;
		prog(8'h21); prog(8'hFF); prog(8'h0F);   // LD HL,$0FFF
		prog(8'h01); prog(8'h01); prog(8'h00);   // LD BC,$0001
		prog(8'h09);                              // ADD HL,BC
		run;
		check(dbg_hl == 16'h1000, "ADD HL,BC result");
		check(Fl[4] == 1'b1, "16-bit half-carry comes from bit 11");

		start;
		prog(8'h21); prog(8'h34); prog(8'h12);   // LD HL,$1234
		prog(8'h11); prog(8'h34); prog(8'h12);   // LD DE,$1234
		prog(8'hED); prog(8'h52);                 // SBC HL,DE  (carry clear)
		run;
		check(dbg_hl == 16'h0000 && Fl[6] == 1'b1, "SBC HL,DE to zero sets Z");

		// --- the stack, and CALL/RET -----------------------------------------------
		$display(" stack:");
		start;
		prog(8'h01); prog(8'h34); prog(8'h12);   // LD BC,$1234
		prog(8'hC5);                              // PUSH BC
		prog(8'hE1);                              // POP HL
		run;
		check(dbg_hl == 16'h1234, "PUSH BC then POP HL round-trips");

		start;
		prog(8'hCD); prog(8'h10); prog(8'h00);   // CALL $0010
		prog(8'h3E); prog(8'h99);                 // LD A,$99 after it returns
		prog(8'h76);
		plen = 16;
		prog(8'h06); prog(8'h42);                 // LD B,$42
		prog(8'hC9);                              // RET
		plen = 6;
		run;
		check(dbg_bc[15:8] == 8'h42, "CALL reached the subroutine");
		check(A == 8'h99, "RET came back to the right place");

		// --- relative jumps ------------------------------------------------------------
		$display(" jumps:");
		start;
		prog(8'h3E); prog(8'h01);
		prog(8'h18); prog(8'h02);                 // JR +2, over the next two bytes
		prog(8'h3E); prog(8'hFF);                 // skipped
		prog(8'h06); prog(8'h07);                 // LD B,$07
		run;
		check(A == 8'h01 && dbg_bc[15:8] == 8'h07, "JR skips forward by its displacement");

		start;
		prog(8'h06); prog(8'h03);                 // LD B,3
		prog(8'h0E); prog(8'h00);                 // LD C,0
		prog(8'h0C);                              // INC C
		prog(8'h10); prog(8'hFD);                 // DJNZ -3
		run;
		check(dbg_bc[7:0] == 8'h03, "DJNZ loops exactly B times");

		// --- the CB page ------------------------------------------------------------------
		$display(" CB page:");
		start;
		prog(8'h3E); prog(8'h01);
		prog(8'hCB); prog(8'h07);                 // RLC A
		run;
		check(A == 8'h02, "RLC A");

		start;
		prog(8'h3E); prog(8'h80);
		prog(8'hCB); prog(8'h07);                 // RLC A -> $01, carry out
		run;
		check(A == 8'h01 && Fl[0] == 1'b1, "RLC wraps the top bit into the carry");

		start;
		prog(8'h3E); prog(8'h00);
		prog(8'hCB); prog(8'hC7);                 // SET 0,A
		prog(8'hCB); prog(8'hFF);                 // SET 7,A
		run;
		check(A == 8'h81, "SET 0 and SET 7");

		start;
		prog(8'h3E); prog(8'hFF);
		prog(8'hCB); prog(8'h87);                 // RES 0,A
		run;
		check(A == 8'hFE, "RES 0,A");

		start;
		prog(8'h3E); prog(8'h00);
		prog(8'hCB); prog(8'h47);                 // BIT 0,A  -> zero, so Z set
		run;
		check(Fl[6] == 1'b1 && Fl[4] == 1'b1, "BIT sets Z on a clear bit, and always H");

		// --- memory through (HL) ------------------------------------------------------------
		$display(" (HL):");
		start;
		prog(8'h21); prog(8'h80); prog(8'h00);   // LD HL,$0080
		prog(8'h36); prog(8'h5A);                 // LD (HL),$5A
		prog(8'h7E);                              // LD A,(HL)
		run;
		check(A == 8'h5A, "LD (HL),n then LD A,(HL)");

		start;
		prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h36); prog(8'h0F);
		prog(8'h34);                              // INC (HL)
		prog(8'h7E);
		run;
		check(A == 8'h10, "INC (HL) reads, modifies and writes back");

		// --- the index registers -------------------------------------------------------------
		$display(" IX / IY:");
		start;
		prog(8'hDD); prog(8'h21); prog(8'h80); prog(8'h00);   // LD IX,$0080
		prog(8'hDD); prog(8'h36); prog(8'h02); prog(8'h77);   // LD (IX+2),$77
		prog(8'h3A); prog(8'h82); prog(8'h00);                // LD A,($0082)
		run;
		check(A == 8'h77, "LD (IX+d),n writes at the displaced address");

		start;
		prog(8'hDD); prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h3E); prog(8'h5E);
		prog(8'hDD); prog(8'h77); prog(8'h03);                // LD (IX+3),A
		prog(8'h06); prog(8'h00);
		prog(8'hDD); prog(8'h46); prog(8'h03);                // LD B,(IX+3)
		run;
		check(dbg_bc[15:8] == 8'h5E, "LD (IX+d),A then LD B,(IX+d)");

		// Under DD, H becomes IXh -- so this must move IX's high byte, not H's.
		start;
		prog(8'hDD); prog(8'h21); prog(8'hAB); prog(8'hCD);   // LD IX,$CDAB
		prog(8'hDD); prog(8'h7C);                              // LD A,IXh
		run;
		check(A == 8'hCD, "under DD, H reads as IXh");

		// ...but the source of a LD r,(IX+d) is never redirected.
		start;
		prog(8'h26); prog(8'h99);                              // LD H,$99
		prog(8'hDD); prog(8'h21); prog(8'h80); prog(8'h00);   // LD IX,$0080
		prog(8'hDD); prog(8'h74); prog(8'h01);                // LD (IX+1),H
		prog(8'h3A); prog(8'h81); prog(8'h00);                // LD A,($0081)
		run;
		check(A == 8'h99, "the source of LD (IX+d),H is plain H, not IXh");

		// --- DDCB, where the displacement precedes the opcode ---------------------------------
		$display(" DDCB:");
		start;
		prog(8'hDD); prog(8'h21); prog(8'h80); prog(8'h00);   // LD IX,$0080
		prog(8'h3E); prog(8'h01);
		prog(8'h32); prog(8'h84); prog(8'h00);                // LD ($0084),A
		prog(8'hDD); prog(8'hCB); prog(8'h04); prog(8'h06);   // RLC (IX+4)
		prog(8'h3A); prog(8'h84); prog(8'h00);
		run;
		check(A == 8'h02, "RLC (IX+4) operates on the displaced byte");

		// --- exchanges ------------------------------------------------------------------------
		$display(" exchanges:");
		start;
		prog(8'h21); prog(8'h34); prog(8'h12);   // LD HL,$1234
		prog(8'h11); prog(8'h78); prog(8'h56);   // LD DE,$5678
		prog(8'hEB);                              // EX DE,HL
		run;
		check(dbg_hl == 16'h5678 && dbg_de == 16'h1234, "EX DE,HL swaps both ways");

		start;
		prog(8'h01); prog(8'h34); prog(8'h12);   // LD BC,$1234
		prog(8'hD9);                              // EXX
		prog(8'h01); prog(8'h78); prog(8'h56);   // LD BC,$5678
		prog(8'hD9);                              // EXX back
		run;
		check(dbg_bc == 16'h1234, "EXX swaps to the shadow set and back");

		start;
		prog(8'h21); prog(8'h34); prog(8'h12);
		prog(8'h01); prog(8'h78); prog(8'h56);
		prog(8'hC5);                              // PUSH BC
		prog(8'hE3);                              // EX (SP),HL
		prog(8'hC1);                              // POP BC
		run;
		check(dbg_hl == 16'h5678 && dbg_bc == 16'h1234, "EX (SP),HL");

		// --- DAA ----------------------------------------------------------------------------------
		$display(" DAA:");
		start;
		prog(8'h3E); prog(8'h09);
		prog(8'hC6); prog(8'h01);                 // $09 + $01 = $0A
		prog(8'h27);                              // DAA -> $10
		run;
		check(A == 8'h10, "DAA turns $0A into $10");

		start;
		prog(8'h3E); prog(8'h99);
		prog(8'hC6); prog(8'h01);                 // $99 + $01 = $9A
		prog(8'h27);                              // DAA -> $00 with carry
		run;
		check(A == 8'h00 && Fl[0] == 1'b1, "DAA carries out of $99 + 1");

		// --- the block instructions -------------------------------------------
		// These are what memcpy and strlen are made of on this machine, so a
		// wrong pointer direction or a repeat that stops one short shows up
		// everywhere at once.
		$display(" block moves:");
		start;
		prog(8'h21); prog(8'h80); prog(8'h00);   // LD HL,$0080  source
		prog(8'h11); prog(8'h90); prog(8'h00);   // LD DE,$0090  destination
		prog(8'h01); prog(8'h04); prog(8'h00);   // LD BC,4
		prog(8'hED); prog(8'hB0);                 // LDIR
		run;
		check(dbg_hl == 16'h0084, "LDIR advanced HL by the count");
		check(dbg_de == 16'h0094, "LDIR advanced DE by the count");
		check(dbg_bc == 16'h0000, "LDIR ran BC down to zero");
		check(mem[16'h0090] == 8'hAA && mem[16'h0093] == 8'hDD,
		      "LDIR copied the whole block");

		start;
		prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h11); prog(8'h90); prog(8'h00);
		prog(8'h01); prog(8'h01); prog(8'h00);   // LD BC,1
		prog(8'hED); prog(8'hA0);                 // LDI -- one byte, no repeat
		run;
		check(dbg_bc == 16'h0000 && mem[16'h0090] == 8'hAA, "LDI moves exactly one byte");
		check(Fl[2] == 1'b0, "LDI clears P/V when BC reaches zero");

		start;
		prog(8'h21); prog(8'h83); prog(8'h00);   // LD HL,$0083
		prog(8'h11); prog(8'h93); prog(8'h00);
		prog(8'h01); prog(8'h04); prog(8'h00);
		prog(8'hED); prog(8'hB8);                 // LDDR -- downwards
		run;
		check(dbg_hl == 16'h007F && dbg_de == 16'h008F, "LDDR counts downwards");
		check(mem[16'h0090] == 8'hAA && mem[16'h0093] == 8'hDD, "LDDR copied the block");

		$display(" block compare:");
		start;
		prog(8'h3E); prog(8'hCC);                 // LD A,$CC -- the third byte
		prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h01); prog(8'h04); prog(8'h00);
		prog(8'hED); prog(8'hB1);                 // CPIR
		run;
		check(dbg_hl == 16'h0083, "CPIR stopped just past the match");
		check(Fl[6] == 1'b1, "CPIR sets Z on the match");
		check(dbg_bc == 16'h0001, "CPIR left the remaining count");

		start;
		prog(8'h3E); prog(8'h11);                 // a value that is not there
		prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h01); prog(8'h04); prog(8'h00);
		prog(8'hED); prog(8'hB1);                 // CPIR
		run;
		check(dbg_bc == 16'h0000 && Fl[6] == 1'b0,
		      "CPIR runs the count out when there is no match");

		$display(" RRD / RLD:");
		start;
		prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h36); prog(8'h42);                 // LD (HL),$42
		prog(8'h3E); prog(8'h37);                 // LD A,$37
		prog(8'hED); prog(8'h6F);                 // RLD
		run;
		// RLD: A=$37 (HL)=$42  ->  A=$34, (HL)=$27
		check(A == 8'h34, "RLD leaves the right nibble in A");
		check(mem[16'h0080] == 8'h27, "RLD leaves the right byte in memory");

		start;
		prog(8'h21); prog(8'h80); prog(8'h00);
		prog(8'h36); prog(8'h42);
		prog(8'h3E); prog(8'h37);
		prog(8'hED); prog(8'h67);                 // RRD
		run;
		// RRD: A=$37 (HL)=$42  ->  A=$32, (HL)=$74
		check(A == 8'h32, "RRD leaves the right nibble in A");
		check(mem[16'h0080] == 8'h74, "RRD leaves the right byte in memory");

		$display("");
		if (errors == 0) $display("tb_z80_unit: all checks passed");
		else             $display("tb_z80_unit: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (4_000_000) @(posedge clk);
		$display("tb_z80_unit: FAIL timeout");
		$finish;
	end

endmodule
