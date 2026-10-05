`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_m68k - the 68000, from its very first instruction.
//
// The programs here are hex words written into memory by hand rather than
// assembled by a tool. That is right at this size and will stop being right
// quickly: once there is an ALU group and condition codes to check, the tests
// move to a tools/md/m68ktest.py that assembles them, the way the Z80 and NES tests
// already do.
//
// Two things get checked separately throughout, because they fail separately:
// whether the right VALUE arrived, and whether it arrived in the right PLACE.
// An addressing mode that computes an address two bytes out still moves the
// correct bytes, and a test that only looked at the destination register would
// pass.
//////////////////////////////////////////////////////////////////////////////////

module tb_m68k;

	reg clk = 0, rst = 1;
	// Active low, so all ones means no interrupt is being requested.
	reg [2:0] ipl_n = 3'b111;
	always #10 clk = ~clk;

	// One enable in four. Not one in one: a CPU that only works when memory
	// answers every cycle is a CPU that works in exactly one testbench.
	reg [1:0] phase = 0;
	always @(posedge clk) phase <= phase + 2'd1;
	wire ce = (phase == 2'd3);

	wire [23:0] addr;
	reg  [15:0] din;
	wire [15:0] dout;
	wire        we, req;
	wire [1:0]  ds;
	wire [31:0] pc, d0, a7;
	wire [15:0] ir, sr;
	wire        halted;

	m68k dut (
		.clk(clk), .rst(rst), .ce(ce),
		.addr(addr), .din(din), .dout(dout), .we(we), .ds(ds), .req(req),
		.ipl_n(ipl_n),
		.dbg_pc(pc), .dbg_ir(ir), .dbg_sr(sr), .dbg_halted(halted),
		.dbg_d0(d0), .dbg_a7(a7)
	);

	// Memory as words, answering one enable after the address. Byte writes honour
	// the data strobes -- a memory that ignored them would let a broken byte
	// write pass by clobbering the whole word with the right half in it.
	reg [15:0] mem [0:16383];
	always @(posedge clk) if (ce) begin
		if (req && we) begin
			if (ds[1]) mem[addr[14:1]][15:8] <= dout[15:8];
			if (ds[0]) mem[addr[14:1]][7:0]  <= dout[7:0];
		end
		din <= mem[addr[14:1]];
	end

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	task expect32;
		input [511:0] what;
		input [31:0]  got;
		input [31:0]  want;
		begin
			if (got === want) $display("  ok   %0s = %08x", what, got);
			else begin
				$display("  FAIL %0s = %08x, wanted %08x", what, got, want);
				errors = errors + 1;
			end
		end
	endtask

	// Wait until the CPU is ABOUT TO FETCH the instruction at `target`, which is
	// the only moment the one before it is certainly finished. Waiting on the PC
	// alone is not enough: it moves during a multi-word instruction, so it
	// reaches the next address while the operation is still being carried out.
	localparam ST_FETCH = 7;
	task wait_pc;
		input [31:0] target;
		integer n;
		begin
			n = 0;
			while (!(pc === target && dut.st === ST_FETCH) && n < 20000) begin
				@(posedge clk); n = n + 1;
			end
			if (n >= 20000) begin
				$display("    *** never reached %08x", target);
				errors = errors + 1;
			end
		end
	endtask

	// X N Z V C, in that order, which is how they sit in the low five bits.
	task flags;
		input [511:0] what;
		input [4:0]   want;
		begin
			if (sr[4:0] === want)
				$display("  ok   %0s  XNZVC=%b", what, sr[4:0]);
			else begin
				$display("  FAIL %0s  XNZVC=%b, wanted %b", what, sr[4:0], want);
				errors = errors + 1;
			end
		end
	endtask

	task run_until_halt;
		input integer limit;
		integer n;
		begin
			n = 0;
			while (!halted && n < limit) begin @(posedge clk); n = n + 1; end
			if (!halted) $display("    *** did not halt within %0d clocks", limit);
		end
	endtask

	integer i;
	integer n;

	// A trace of the first stretch of execution. Cheap, and the only way to see
	// an address being computed one word out -- which looks, from the outside,
	// exactly like an instruction that did nothing.
	parameter TRACE = 0;
	integer tn = 0;
	always @(posedge clk) if (TRACE && ce && !rst && tn < 90) begin
		$display("    t%0d st=%0d PC=%06x ir=%04x ea_m=%0d ea_r=%0d ea_addr=%06x addr=%06x din=%04x%s",
		         tn, dut.st, dut.PC, dut.ir, dut.ea_m, dut.ea_r,
		         dut.ea_addr, addr, din, we ? " WR" : "");
		tn = tn + 1;
	end

	initial begin
		$display("tb_m68k");
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;   // NOP everywhere

		// --- what a 68000 finds at power-on --------------------------------
		// Two longwords: the supervisor stack pointer, then the entry point.
		// Not a vector table in the usual sense, and every Mega Drive cartridge
		// starts with exactly this.
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP = $00001000
		mem[2] = 16'h0000; mem[3] = 16'h0400;      // PC  = $00000400

		// --- the program ------------------------------------------------------
		// Each instruction exercises one addressing mode, and the ones that
		// write to memory are checked at the address they should have written
		// to rather than only read back through the same mode that wrote them.
		mem[16'h0400>>1] = 16'h223C;               // MOVE.L #$12345678,D1
		mem[16'h0402>>1] = 16'h1234;
		mem[16'h0404>>1] = 16'h5678;
		mem[16'h0406>>1] = 16'h2401;               // MOVE.L D1,D2
		mem[16'h0408>>1] = 16'h363C;               // MOVE.W #$ABCD,D3
		mem[16'h040A>>1] = 16'hABCD;
		mem[16'h040C>>1] = 16'h207C;               // MOVEA.L #$00002000,A0
		mem[16'h040E>>1] = 16'h0000;
		mem[16'h0410>>1] = 16'h2000;
		mem[16'h0412>>1] = 16'h2081;               // MOVE.L D1,(A0)
		mem[16'h0414>>1] = 16'h2810;               // MOVE.L (A0),D4
		// $31C3, not $30C3. One bit out is destination mode 011 -- (A0)+ -- which
		// stores to the wrong place, bumps A0, and leaves the extension word to
		// be executed as an instruction. Worth the comment: hand-assembled tests
		// fail in ways that look like CPU bugs.
		mem[16'h0416>>1] = 16'h31C3;               // MOVE.W D3,($3000).W
		mem[16'h0418>>1] = 16'h3000;
		mem[16'h041A>>1] = 16'h3A38;               // MOVE.W ($3000).W,D5
		mem[16'h041C>>1] = 16'h3000;
		mem[16'h041E>>1] = 16'h227C;               // MOVEA.L #$00002100,A1
		mem[16'h0420>>1] = 16'h0000;
		mem[16'h0422>>1] = 16'h2100;
		mem[16'h0424>>1] = 16'h2301;               // MOVE.L D1,-(A1)
		mem[16'h0426>>1] = 16'h2C19;               // MOVE.L (A1)+,D6
		mem[16'h0428>>1] = 16'h3E28;               // MOVE.W 2(A0),D7
		mem[16'h042A>>1] = 16'h0002;
		mem[16'h042C>>1] = 16'h4E72;               // STOP
		mem[16'h042E>>1] = 16'h2700;

		repeat (10) @(posedge clk);
		rst = 0;

		run_until_halt(20000);
		$display("    PC=%08x SR=%04x halted=%b", pc, sr, halted);
		check(halted === 1'b1, "the program ran to STOP");

		$display(" immediates and register moves:");
		expect32("D1  (#imm32 -> Dn)",       dut.D[1], 32'h12345678);
		expect32("D2  (Dn -> Dn)",           dut.D[2], 32'h12345678);
		// A word move touches only the low half. If it wrote all 32 bits this
		// would be $FFFFABCD from the sign extension, which is the actual bug
		// this catches.
		expect32("D3  (#imm16 -> Dn, word)", dut.D[3], 32'h0000ABCD);
		expect32("A0  (MOVEA.L)",            dut.A[0], 32'h00002000);

		$display(" memory, indirect:");
		expect32("D4  ((An) -> Dn)",         dut.D[4], 32'h12345678);
		check(mem[16'h2000>>1] === 16'h1234 && mem[16'h2002>>1] === 16'h5678,
		      "MOVE.L Dn,(An) put both halves at $2000, in order");

		$display(" absolute:");
		check(mem[16'h3000>>1] === 16'hABCD,
		      "MOVE.W Dn,(xxx).W landed at $3000 exactly");
		expect32("D5  ((xxx).W -> Dn)",      dut.D[5], 32'h0000ABCD);

		$display(" predecrement and postincrement:");
		check(mem[16'h20FC>>1] === 16'h1234 && mem[16'h20FE>>1] === 16'h5678,
		      "-(An) decremented by four BEFORE writing, not after");
		expect32("D6  ((An)+ -> Dn)",        dut.D[6], 32'h12345678);
		expect32("A1  (back where it was)",  dut.A[1], 32'h00002100);

		$display(" displacement:");
		expect32("D7  (d16(An) -> Dn)",      dut.D[7], 32'h00005678);

		// ==================================================================
		// Second program: the ALU group, and its flags.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;
		mem[2] = 16'h0000; mem[3] = 16'h0500;

		mem[16'h0500>>1] = 16'h203C;  mem[16'h0502>>1] = 16'hFFFF;
		mem[16'h0504>>1] = 16'hFFFF;               // MOVE.L #$FFFFFFFF,D0
		mem[16'h0506>>1] = 16'hD0BC;  mem[16'h0508>>1] = 16'h0000;
		mem[16'h050A>>1] = 16'h0001;               // ADD.L #1,D0   -> 0, carry
		mem[16'h050C>>1] = 16'h4E71;               // NOP  (sample point)

		mem[16'h050E>>1] = 16'h223C;  mem[16'h0510>>1] = 16'h7FFF;
		mem[16'h0512>>1] = 16'hFFFF;               // MOVE.L #$7FFFFFFF,D1
		mem[16'h0514>>1] = 16'hD2BC;  mem[16'h0516>>1] = 16'h0000;
		mem[16'h0518>>1] = 16'h0001;               // ADD.L #1,D1   -> overflow
		mem[16'h051A>>1] = 16'h4E71;               // NOP  (sample point)

		mem[16'h051C>>1] = 16'h243C;  mem[16'h051E>>1] = 16'h0000;
		mem[16'h0520>>1] = 16'h0005;               // MOVE.L #5,D2
		mem[16'h0522>>1] = 16'h94BC;  mem[16'h0524>>1] = 16'h0000;
		mem[16'h0526>>1] = 16'h0003;               // SUB.L #3,D2   -> 2

		mem[16'h0528>>1] = 16'h263C;  mem[16'h052A>>1] = 16'hFF00;
		mem[16'h052C>>1] = 16'hFF00;               // MOVE.L #$FF00FF00,D3
		mem[16'h052E>>1] = 16'hC6BC;  mem[16'h0530>>1] = 16'h0F0F;
		mem[16'h0532>>1] = 16'h0F0F;               // AND.L #$0F0F0F0F,D3

		mem[16'h0534>>1] = 16'h283C;  mem[16'h0536>>1] = 16'hF0F0;
		mem[16'h0538>>1] = 16'hF0F0;               // MOVE.L #$F0F0F0F0,D4
		mem[16'h053A>>1] = 16'h88BC;  mem[16'h053C>>1] = 16'h0F0F;
		mem[16'h053E>>1] = 16'h0F0F;               // OR.L #$0F0F0F0F,D4

		mem[16'h0540>>1] = 16'h2A3C;  mem[16'h0542>>1] = 16'h0000;
		mem[16'h0544>>1] = 16'h1234;               // MOVE.L #$1234,D5
		mem[16'h0546>>1] = 16'hBABC;  mem[16'h0548>>1] = 16'h0000;
		mem[16'h054A>>1] = 16'h1234;               // CMP.L #$1234,D5
		mem[16'h054C>>1] = 16'h4E71;               // NOP  (sample point)

		mem[16'h054E>>1] = 16'h2C3C;  mem[16'h0550>>1] = 16'hFFFF;
		mem[16'h0552>>1] = 16'h0000;               // MOVE.L #$FFFF0000,D6
		mem[16'h0554>>1] = 16'hDC7C;  mem[16'h0556>>1] = 16'h0001;
		                                           // ADD.W #1,D6

		mem[16'h0558>>1] = 16'h247C;  mem[16'h055A>>1] = 16'h0000;
		mem[16'h055C>>1] = 16'h1000;               // MOVEA.L #$1000,A2
		mem[16'h055E>>1] = 16'hD4FC;  mem[16'h0560>>1] = 16'hFFFE;
		                                           // ADDA.W #-2,A2

		mem[16'h0562>>1] = 16'h4E72;  mem[16'h0564>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;

		$display("");
		$display(" ALU flags:");
		// $FFFFFFFF + 1 wraps to zero: carry out, zero set, and X follows C.
		wait_pc(32'h0000050C);
		flags("$FFFFFFFF + 1  ->  0, carry", 5'b10101);

		// $7FFFFFFF + 1 is the classic signed overflow: the sign flips although
		// nothing carried out. V catches it and C does not.
		wait_pc(32'h0000051A);
		flags("$7FFFFFFF + 1  ->  overflow", 5'b01010);

		// Equal compare: Z alone. X must be untouched -- a compare is not
		// arithmetic as far as multi-word chains are concerned.
		wait_pc(32'h0000054C);
		flags("CMP equal      ->  Z only", 5'b00100);

		run_until_halt(20000);
		check(halted === 1'b1, "the ALU program ran to STOP");

		$display(" ALU results:");
		expect32("D0  ($FFFFFFFF + 1)",   dut.D[0], 32'h00000000);
		expect32("D1  ($7FFFFFFF + 1)",   dut.D[1], 32'h80000000);
		expect32("D2  (5 - 3)",           dut.D[2], 32'h00000002);
		expect32("D3  (AND)",             dut.D[3], 32'h0F000F00);
		expect32("D4  (OR)",              dut.D[4], 32'hFFFFFFFF);
		expect32("D5  (CMP left it be)",  dut.D[5], 32'h00001234);
		// A word-sized add must not disturb the upper half of the register.
		expect32("D6  (ADD.W, upper kept)", dut.D[6], 32'hFFFF0001);
		// ADDA.W sign extends its operand before adding: $1000 + (-2), not
		// $1000 + $FFFE.
		expect32("A2  (ADDA.W of -2)",    dut.A[2], 32'h00000FFE);

		// ==================================================================
		// Third program: control flow.
		//
		// Every conditional branch here jumps OVER an instruction that sets a
		// failure marker, so D5 ends at zero only if all of them went the right
		// way. A branch that is wrongly NOT taken leaves its marker behind, and
		// the marker says which one.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0600;      // PC

		mem[16'h0600>>1] = 16'h7A00;               // MOVEQ #0,D5   no failures yet
		mem[16'h0602>>1] = 16'h7006;               // MOVEQ #6,D0
		mem[16'h0604>>1] = 16'hB07C;               // CMP.W #5,D0
		mem[16'h0606>>1] = 16'h0005;               //   6 vs 5: Z=0 N=0 V=0 C=0
		mem[16'h0608>>1] = 16'h6E02;               // BGT  -> $60C
		mem[16'h060A>>1] = 16'h7A01;               //   MOVEQ #1,D5  (skipped)
		mem[16'h060C>>1] = 16'h6602;               // BNE  -> $610
		mem[16'h060E>>1] = 16'h7A02;               //   MOVEQ #2,D5  (skipped)
		mem[16'h0610>>1] = 16'h6402;               // BCC  -> $614
		mem[16'h0612>>1] = 16'h7A03;               //   MOVEQ #3,D5  (skipped)
		mem[16'h0614>>1] = 16'h6A02;               // BPL  -> $618
		mem[16'h0616>>1] = 16'h7A04;               //   MOVEQ #4,D5  (skipped)

		// The other half of the job: a condition that is FALSE must fall
		// through. A CPU that took every branch would pass all of the above.
		mem[16'h0618>>1] = 16'h6702;               // BEQ  -> must NOT be taken
		mem[16'h061A>>1] = 16'h6002;               // BRA  -> $61E, over the marker
		mem[16'h061C>>1] = 16'h7A05;               //   MOVEQ #5,D5  (only if BEQ wrong)

		mem[16'h061E>>1] = 16'h6100;               // BSR.W +8 -> $628
		mem[16'h0620>>1] = 16'h0008;
		mem[16'h0622>>1] = 16'h700A;               // MOVEQ #10,D0   after the return
		mem[16'h0624>>1] = 16'h6000;               // BRA.W +8 -> $62E, over the sub
		mem[16'h0626>>1] = 16'h0008;

		mem[16'h0628>>1] = 16'h7207;               // sub: MOVEQ #7,D1
		mem[16'h062A>>1] = 16'h4E75;               //      RTS

		mem[16'h062E>>1] = 16'h41F9;               // LEA ($00003000).L,A0
		mem[16'h0630>>1] = 16'h0000;
		mem[16'h0632>>1] = 16'h3000;
		mem[16'h0634>>1] = 16'h4EB9;               // JSR ($00000640).L
		mem[16'h0636>>1] = 16'h0000;
		mem[16'h0638>>1] = 16'h0640;
		mem[16'h063A>>1] = 16'h4E72;               // STOP
		mem[16'h063C>>1] = 16'h2700;

		mem[16'h0640>>1] = 16'h7409;               // sub: MOVEQ #9,D2
		mem[16'h0642>>1] = 16'h4E75;               //      RTS

		repeat (4) @(posedge clk);
		rst = 0;
		run_until_halt(40000);

		$display("");
		$display(" control flow:");
		check(halted === 1'b1, "the program reached STOP, so RTS came back twice");
		// D5 names the first branch that misbehaved, which beats "something is
		// wrong with branches".
		expect32("D5  (0 = every branch went the right way)", dut.D[5], 32'd0);
		expect32("D0  (set after BSR returned)",  dut.D[0], 32'd10);
		expect32("D1  (the BSR subroutine ran)",  dut.D[1], 32'd7);
		expect32("D2  (the JSR subroutine ran)",  dut.D[2], 32'd9);
		expect32("A0  (LEA took the address)",    dut.A[0], 32'h00003000);
		// Two calls, two returns: the stack has to be exactly where it started.
		expect32("A7  (stack balanced)",          dut.A[7], 32'h00001000);

		// ==================================================================
		// Fourth program: the quick forms, the loop instruction, and TST.
		//
		// These three are the most common instructions in real 68000 code by a
		// long way -- a Mega Drive boot ROM is mostly ADDQ, DBRA and TST -- so
		// they get checked on the details that are easy to get subtly wrong:
		// the data field of 0 meaning eight, an address register taking all
		// thirty-two bits whatever size the opcode says, DBcc running n+1 times
		// and ending at -1 rather than 0, and TST judging only its own size.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0700;      // PC

		mem[16'h0700>>1] = 16'h7000;               // MOVEQ #0,D0
		mem[16'h0702>>1] = 16'h5280;               // ADDQ.L #1,D0   -> 1
		mem[16'h0704>>1] = 16'h5040;               // ADDQ.W #8,D0   -> 9 (data=0)
		mem[16'h0706>>1] = 16'h5700;               // SUBQ.B #3,D0   -> 6

		mem[16'h0708>>1] = 16'h227C;  mem[16'h070A>>1] = 16'h0000;
		mem[16'h070C>>1] = 16'h1000;               // MOVEA.L #$1000,A1
		mem[16'h070E>>1] = 16'h5089;               // ADDQ.L #8,A1   -> $1008
		mem[16'h0710>>1] = 16'h5549;               // SUBQ.W #2,A1   -> $1006

		mem[16'h0712>>1] = 16'h7600;               // MOVEQ #0,D3
		mem[16'h0714>>1] = 16'h7404;               // MOVEQ #4,D2
		mem[16'h0716>>1] = 16'h5283;               // loop: ADDQ.L #1,D3
		mem[16'h0718>>1] = 16'h51CA;               // DBRA D2,loop
		mem[16'h071A>>1] = 16'hFFFC;               //   -4 from the extension word

		mem[16'h071C>>1] = 16'h7800;               // MOVEQ #0,D4   no failures yet
		mem[16'h071E>>1] = 16'h2A3C;  mem[16'h0720>>1] = 16'h0000;
		mem[16'h0722>>1] = 16'h0100;               // MOVE.L #$00000100,D5
		mem[16'h0724>>1] = 16'h4A85;               // TST.L D5   -> not zero
		mem[16'h0726>>1] = 16'h6602;               // BNE -> $72A
		mem[16'h0728>>1] = 16'h7801;               //   MOVEQ #1,D4  (skipped)
		// The same register, judged a byte at a time, IS zero. A TST that always
		// looked at all thirty-two bits would fall through here.
		mem[16'h072A>>1] = 16'h4A05;               // TST.B D5   -> zero
		mem[16'h072C>>1] = 16'h6702;               // BEQ -> $730
		mem[16'h072E>>1] = 16'h7802;               //   MOVEQ #2,D4  (skipped)
		mem[16'h0730>>1] = 16'h2C3C;  mem[16'h0732>>1] = 16'hFFFF;
		mem[16'h0734>>1] = 16'hFFFF;               // MOVE.L #$FFFFFFFF,D6
		mem[16'h0736>>1] = 16'h4A46;               // TST.W D6   -> negative
		mem[16'h0738>>1] = 16'h6B02;               // BMI -> $73C
		mem[16'h073A>>1] = 16'h7803;               //   MOVEQ #3,D4  (skipped)

		mem[16'h073C>>1] = 16'h4E72;  mem[16'h073E>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;
		run_until_halt(40000);

		$display("");
		$display(" quick forms, DBcc and TST:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D0  (+1, +8, -3 at three sizes)", dut.D[0], 32'h00000006);
		// Word-sized quick arithmetic on an address register still touches all
		// thirty-two bits. $1008 - 2 written as a word would leave $10000006.
		expect32("A1  (ADDQ.L #8 then SUBQ.W #2)",  dut.A[1], 32'h00001006);
		// DBRA #4 runs the body five times, not four.
		expect32("D3  (DBRA #4 body count)",        dut.D[3], 32'd5);
		// ...and leaves the counter at -1, in the low word only.
		expect32("D2  (counter ends at -1, word)",  dut.D[2], 32'h0000FFFF);
		expect32("D4  (0 = every TST judged right)", dut.D[4], 32'd0);

		// ==================================================================
		// Fifth program: the immediate group, and CLR/NEG/NOT.
		//
		// These are the first instructions that read a destination, change it
		// and put it back, so the half that matters is the memory case: the
		// result has to land at the SAME address it came from, and a (An)+
		// destination must step the register once rather than once per access.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0800;      // PC

		mem[16'h0800>>1] = 16'h7A00;               // MOVEQ #0,D5   no failures yet

		mem[16'h0802>>1] = 16'h203C;  mem[16'h0804>>1] = 16'h0000;
		mem[16'h0806>>1] = 16'h1000;               // MOVE.L #$1000,D0
		mem[16'h0808>>1] = 16'h0680;  mem[16'h080A>>1] = 16'h0000;
		mem[16'h080C>>1] = 16'h0234;               // ADDI.L #$234,D0  -> $1234
		mem[16'h080E>>1] = 16'h0440;  mem[16'h0810>>1] = 16'h0034;
		                                           // SUBI.W #$34,D0   -> $1200

		mem[16'h0812>>1] = 16'h223C;  mem[16'h0814>>1] = 16'h0012;
		mem[16'h0816>>1] = 16'hFF0F;               // MOVE.L #$0012FF0F,D1
		mem[16'h0818>>1] = 16'h0241;  mem[16'h081A>>1] = 16'h00F0;
		                                           // ANDI.W #$00F0,D1 -> $00120000
		mem[16'h081C>>1] = 16'h0041;  mem[16'h081E>>1] = 16'h0F00;
		                                           // ORI.W  #$0F00,D1 -> $00120F00
		mem[16'h0820>>1] = 16'h0A41;  mem[16'h0822>>1] = 16'hFFFF;
		                                           // EORI.W #$FFFF,D1 -> $0012F0FF

		mem[16'h0824>>1] = 16'h243C;  mem[16'h0826>>1] = 16'h0000;
		mem[16'h0828>>1] = 16'h0055;               // MOVE.L #$55,D2
		mem[16'h082A>>1] = 16'h0C02;  mem[16'h082C>>1] = 16'h0055;
		                                           // CMPI.B #$55,D2  -> equal
		mem[16'h082E>>1] = 16'h6702;               // BEQ -> $832
		mem[16'h0830>>1] = 16'h7A01;               //   MOVEQ #1,D5  (skipped)
		mem[16'h0832>>1] = 16'h0C02;  mem[16'h0834>>1] = 16'h0054;
		                                           // CMPI.B #$54,D2  -> not equal
		mem[16'h0836>>1] = 16'h6602;               // BNE -> $83A
		mem[16'h0838>>1] = 16'h7A02;               //   MOVEQ #2,D5  (skipped)

		mem[16'h083A>>1] = 16'h263C;  mem[16'h083C>>1] = 16'h1234;
		mem[16'h083E>>1] = 16'h5678;               // MOVE.L #$12345678,D3
		mem[16'h0840>>1] = 16'h4243;               // CLR.W D3   -> $12340000
		mem[16'h0842>>1] = 16'h283C;  mem[16'h0844>>1] = 16'hFFFF;
		mem[16'h0846>>1] = 16'hFF01;               // MOVE.L #$FFFFFF01,D4
		mem[16'h0848>>1] = 16'h4444;               // NEG.W D4   -> $FFFF00FF
		mem[16'h084A>>1] = 16'h2C3C;  mem[16'h084C>>1] = 16'h0000;
		mem[16'h084E>>1] = 16'hF0F0;               // MOVE.L #$0000F0F0,D6
		mem[16'h0850>>1] = 16'h4646;               // NOT.W D6   -> $00000F0F

		// The memory half.
		mem[16'h0852>>1] = 16'h207C;  mem[16'h0854>>1] = 16'h0000;
		mem[16'h0856>>1] = 16'h2000;               // MOVEA.L #$2000,A0
		mem[16'h0858>>1] = 16'h2E3C;  mem[16'h085A>>1] = 16'h1234;
		mem[16'h085C>>1] = 16'h5678;               // MOVE.L #$12345678,D7
		mem[16'h085E>>1] = 16'h2087;               // MOVE.L D7,(A0)
		mem[16'h0860>>1] = 16'h0690;  mem[16'h0862>>1] = 16'h0000;
		mem[16'h0864>>1] = 16'h0005;               // ADDI.L #5,(A0)
		mem[16'h0866>>1] = 16'h2E10;               // MOVE.L (A0),D7  -> $1234567D
		mem[16'h0868>>1] = 16'h4250;               // CLR.W (A0)
		mem[16'h086A>>1] = 16'h2450;               // MOVEA.L (A0),A2 -> $0000567D

		// A destination that has a side effect must have it exactly once, even
		// though the address is used twice.
		mem[16'h086C>>1] = 16'h227C;  mem[16'h086E>>1] = 16'h0000;
		mem[16'h0870>>1] = 16'h2000;               // MOVEA.L #$2000,A1
		mem[16'h0872>>1] = 16'h0659;  mem[16'h0874>>1] = 16'h0001;
		                                           // ADDI.W #1,(A1)+

		mem[16'h0876>>1] = 16'h4E72;  mem[16'h0878>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;
		run_until_halt(40000);

		$display("");
		$display(" immediates, CLR/NEG/NOT:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D0  (ADDI.L then SUBI.W)",   dut.D[0], 32'h00001200);
		expect32("D1  (ANDI, ORI, EORI word)", dut.D[1], 32'h0012F0FF);
		expect32("D2  (CMPI left it alone)",   dut.D[2], 32'h00000055);
		expect32("D5  (0 = both CMPIs judged right)", dut.D[5], 32'd0);
		expect32("D3  (CLR.W, upper kept)",    dut.D[3], 32'h12340000);
		// $FF01 negated as a word is $00FF -- as a longword it would be $000000FF
		// and the upper half would be gone.
		expect32("D4  (NEG.W, upper kept)",    dut.D[4], 32'hFFFF00FF);
		expect32("D6  (NOT.W, upper kept)",    dut.D[6], 32'h00000F0F);
		expect32("D7  (ADDI.L to memory)",     dut.D[7], 32'h1234567D);
		// Read back through a different instruction: the result has to be AT
		// $2000, not merely in some register.
		expect32("A2  (CLR.W (A0) at $2000)",  dut.A[2], 32'h0000567D);
		expect32("A1  (ADDI.W #1,(A1)+ stepped once)", dut.A[1], 32'h00002002);

		// ==================================================================
		// Sixth program: the other direction, EOR, EXT and SWAP.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0900;      // PC

		mem[16'h0900>>1] = 16'h203C;  mem[16'h0902>>1] = 16'h0000;
		mem[16'h0904>>1] = 16'h0080;               // MOVE.L #$80,D0
		mem[16'h0906>>1] = 16'h4880;               // EXT.W D0  -> $0000FF80
		mem[16'h0908>>1] = 16'h48C0;               // EXT.L D0  -> $FFFFFF80

		mem[16'h090A>>1] = 16'h223C;  mem[16'h090C>>1] = 16'h1234;
		mem[16'h090E>>1] = 16'h5678;               // MOVE.L #$12345678,D1
		mem[16'h0910>>1] = 16'h4841;               // SWAP D1   -> $56781234

		mem[16'h0912>>1] = 16'h243C;  mem[16'h0914>>1] = 16'h0000;
		mem[16'h0916>>1] = 16'hFFFF;               // MOVE.L #$FFFF,D2
		mem[16'h0918>>1] = 16'h263C;  mem[16'h091A>>1] = 16'h0000;
		mem[16'h091C>>1] = 16'h0F0F;               // MOVE.L #$0F0F,D3
		mem[16'h091E>>1] = 16'hB742;               // EOR.W D3,D2 -> $0000F0F0

		mem[16'h0920>>1] = 16'h207C;  mem[16'h0922>>1] = 16'h0000;
		mem[16'h0924>>1] = 16'h2000;               // MOVEA.L #$2000,A0
		mem[16'h0926>>1] = 16'h283C;  mem[16'h0928>>1] = 16'h0000;
		mem[16'h092A>>1] = 16'h0100;               // MOVE.L #$100,D4
		mem[16'h092C>>1] = 16'h2084;               // MOVE.L D4,(A0)
		mem[16'h092E>>1] = 16'h2C3C;  mem[16'h0930>>1] = 16'h0000;
		mem[16'h0932>>1] = 16'h0011;               // MOVE.L #$11,D6
		mem[16'h0934>>1] = 16'hDD90;               // ADD.L D6,(A0)  -> $111
		mem[16'h0936>>1] = 16'h2E10;               // MOVE.L (A0),D7
		// SUB in this direction is <ea> minus the register, not the other way
		// round. Backwards, it would leave -$F1 here and the check would catch it.
		mem[16'h0938>>1] = 16'h9D90;               // SUB.L D6,(A0)  -> $100
		mem[16'h093A>>1] = 16'h8750;               // OR.W D3,(A0)   -> $0F0F0100
		mem[16'h093C>>1] = 16'h2450;               // MOVEA.L (A0),A2

		mem[16'h093E>>1] = 16'h4E72;  mem[16'h0940>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;
		run_until_halt(40000);

		$display("");
		$display(" Dn-to-<ea>, EOR, EXT, SWAP:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D0  (EXT.W then EXT.L of $80)", dut.D[0], 32'hFFFFFF80);
		expect32("D1  (SWAP)",                    dut.D[1], 32'h56781234);
		expect32("D2  (EOR.W Dn,Dn)",             dut.D[2], 32'h0000F0F0);
		expect32("D7  (ADD.L D6,(A0) read back)", dut.D[7], 32'h00000111);
		expect32("A2  (SUB.L then OR.W at $2000)", dut.A[2], 32'h0F0F0100);

		// ==================================================================
		// Seventh program: the shifts and rotates.
		//
		// The two things worth checking here are what comes IN at the vacated
		// end -- a sign bit, a zero, the bit that went out, or X -- and the
		// overflow flag, which only ASL has and which latches the moment the
		// sign moves.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0A00;      // PC

		mem[16'h0A00>>1] = 16'h203C;  mem[16'h0A02>>1] = 16'h1234;
		mem[16'h0A04>>1] = 16'h8000;               // MOVE.L #$12348000,D0
		mem[16'h0A06>>1] = 16'hE240;               // ASR.W #1,D0 -> $1234C000
		mem[16'h0A08>>1] = 16'h223C;  mem[16'h0A0A>>1] = 16'h1234;
		mem[16'h0A0C>>1] = 16'h8000;               // MOVE.L #$12348000,D1
		mem[16'h0A0E>>1] = 16'hE249;               // LSR.W #1,D1 -> $12344000

		mem[16'h0A10>>1] = 16'h243C;  mem[16'h0A12>>1] = 16'h0000;
		mem[16'h0A14>>1] = 16'h0040;               // MOVE.L #$40,D2
		mem[16'h0A16>>1] = 16'hE302;               // ASL.B #1,D2 -> $80, V set
		mem[16'h0A18>>1] = 16'h4E71;               // NOP  (sample point)
		mem[16'h0A1A>>1] = 16'h263C;  mem[16'h0A1C>>1] = 16'h0000;
		mem[16'h0A1E>>1] = 16'h0040;               // MOVE.L #$40,D3
		mem[16'h0A20>>1] = 16'hE30B;               // LSL.B #1,D3 -> $80, V clear
		mem[16'h0A22>>1] = 16'h4E71;               // NOP  (sample point)

		mem[16'h0A24>>1] = 16'h283C;  mem[16'h0A26>>1] = 16'h0000;
		mem[16'h0A28>>1] = 16'h1234;               // MOVE.L #$1234,D4
		mem[16'h0A2A>>1] = 16'hE95C;               // ROL.W #4,D4 -> $2341
		mem[16'h0A2C>>1] = 16'h2A3C;  mem[16'h0A2E>>1] = 16'h0000;
		mem[16'h0A30>>1] = 16'h1234;               // MOVE.L #$1234,D5
		mem[16'h0A32>>1] = 16'hE85D;               // ROR.W #4,D5 -> $4123

		// A count held in a register is taken modulo 64, so 68 is a shift of 4.
		mem[16'h0A34>>1] = 16'h2E3C;  mem[16'h0A36>>1] = 16'h0000;
		mem[16'h0A38>>1] = 16'h0044;               // MOVE.L #68,D7
		mem[16'h0A3A>>1] = 16'h2C3C;  mem[16'h0A3C>>1] = 16'h0000;
		mem[16'h0A3E>>1] = 16'h0001;               // MOVE.L #1,D6
		mem[16'h0A40>>1] = 16'hEFAE;               // LSL.L D7,D6 -> $10
		mem[16'h0A42>>1] = 16'h2046;               // MOVEA.L D6,A0

		// ROXL rotates through X, so something has to put a 1 there first. A
		// MOVE does not disturb X, which is what makes this sequence work.
		mem[16'h0A44>>1] = 16'h2E3C;  mem[16'h0A46>>1] = 16'h0000;
		mem[16'h0A48>>1] = 16'h0001;               // MOVE.L #1,D7
		mem[16'h0A4A>>1] = 16'h0607;  mem[16'h0A4C>>1] = 16'h00FF;
		                                           // ADDI.B #$FF,D7 -> 0, X=1
		mem[16'h0A4E>>1] = 16'h2C3C;  mem[16'h0A50>>1] = 16'h0000;
		mem[16'h0A52>>1] = 16'h0000;               // MOVE.L #0,D6
		mem[16'h0A54>>1] = 16'hE316;               // ROXL.B #1,D6 -> $01

		mem[16'h0A56>>1] = 16'h4E72;  mem[16'h0A58>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;

		$display("");
		$display(" shift flags:");
		// $40 shifted arithmetically left becomes $80: the sign moved, which is
		// the whole of what ASL's overflow flag means.
		wait_pc(32'h00000A18);
		flags("ASL.B #1 of $40  ->  V set",   5'b01010);
		// The same shift, logically, is not an overflow of anything.
		wait_pc(32'h00000A22);
		flags("LSL.B #1 of $40  ->  V clear", 5'b01000);

		run_until_halt(40000);

		$display("");
		$display(" shifts and rotates:");
		check(halted === 1'b1, "the program reached STOP");
		// Arithmetic right brings the sign back in; logical right brings a zero.
		expect32("D0  (ASR.W of $8000)",   dut.D[0], 32'h1234C000);
		expect32("D1  (LSR.W of $8000)",   dut.D[1], 32'h12344000);
		expect32("D2  (ASL.B of $40)",     dut.D[2], 32'h00000080);
		expect32("D3  (LSL.B of $40)",     dut.D[3], 32'h00000080);
		expect32("D4  (ROL.W #4 of $1234)", dut.D[4], 32'h00002341);
		expect32("D5  (ROR.W #4 of $1234)", dut.D[5], 32'h00004123);
		expect32("A0  (LSL.L by 68, taken mod 64)", dut.A[0], 32'h00000010);
		expect32("D6  (ROXL.B brought X in)", dut.D[6], 32'h00000001);

		// ==================================================================
		// Eighth program: MOVEM.
		//
		// The awkward part is that the mask means different registers depending
		// on the addressing mode: bit 0 is D0 everywhere except -(An), where it
		// is A7 and the whole list runs backwards. Getting that wrong saves the
		// right number of registers in the wrong order, so the check that
		// matters is storing with -(An) and restoring with (An)+ into DIFFERENT
		// registers -- the values have to come back paired up correctly.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0B00;      // PC

		mem[16'h0B00>>1] = 16'h203C;  mem[16'h0B02>>1] = 16'h1111;
		mem[16'h0B04>>1] = 16'h1111;               // MOVE.L #$11111111,D0
		mem[16'h0B06>>1] = 16'h223C;  mem[16'h0B08>>1] = 16'h2222;
		mem[16'h0B0A>>1] = 16'h2222;               // MOVE.L #$22222222,D1
		mem[16'h0B0C>>1] = 16'h243C;  mem[16'h0B0E>>1] = 16'h3333;
		mem[16'h0B10>>1] = 16'h3333;               // MOVE.L #$33333333,D2
		mem[16'h0B12>>1] = 16'h263C;  mem[16'h0B14>>1] = 16'h4444;
		mem[16'h0B16>>1] = 16'h4444;               // MOVE.L #$44444444,D3
		mem[16'h0B18>>1] = 16'h207C;  mem[16'h0B1A>>1] = 16'h0000;
		mem[16'h0B1C>>1] = 16'h3000;               // MOVEA.L #$3000,A0

		mem[16'h0B1E>>1] = 16'h48D0;  mem[16'h0B20>>1] = 16'h000F;
		                                           // MOVEM.L D0-D3,(A0)
		mem[16'h0B22>>1] = 16'h7000;               // MOVEQ #0,D0
		mem[16'h0B24>>1] = 16'h7200;               // MOVEQ #0,D1
		mem[16'h0B26>>1] = 16'h7400;               // MOVEQ #0,D2
		mem[16'h0B28>>1] = 16'h7600;               // MOVEQ #0,D3
		mem[16'h0B2A>>1] = 16'h4CD0;  mem[16'h0B2C>>1] = 16'h000F;
		                                           // MOVEM.L (A0),D0-D3

		// Push D0, D1 and A0; pull them back into D4, D5 and A2.
		mem[16'h0B2E>>1] = 16'h227C;  mem[16'h0B30>>1] = 16'h0000;
		mem[16'h0B32>>1] = 16'h4000;               // MOVEA.L #$4000,A1
		mem[16'h0B34>>1] = 16'h48E1;  mem[16'h0B36>>1] = 16'hC080;
		                                           // MOVEM.L D0-D1/A0,-(A1)
		mem[16'h0B38>>1] = 16'h4CD9;  mem[16'h0B3A>>1] = 16'h0430;
		                                           // MOVEM.L (A1)+,D4-D5/A2

		// A word loaded into a register is sign extended to all thirty-two bits.
		mem[16'h0B3C>>1] = 16'h2C3C;  mem[16'h0B3E>>1] = 16'h0000;
		mem[16'h0B40>>1] = 16'hFFFF;               // MOVE.L #$0000FFFF,D6
		mem[16'h0B42>>1] = 16'h267C;  mem[16'h0B44>>1] = 16'h0000;
		mem[16'h0B46>>1] = 16'h5000;               // MOVEA.L #$5000,A3
		mem[16'h0B48>>1] = 16'h4893;  mem[16'h0B4A>>1] = 16'h0040;
		                                           // MOVEM.W D6,(A3)
		mem[16'h0B4C>>1] = 16'h4C93;  mem[16'h0B4E>>1] = 16'h0080;
		                                           // MOVEM.W (A3),D7

		mem[16'h0B50>>1] = 16'h4E72;  mem[16'h0B52>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;
		run_until_halt(60000);

		$display("");
		$display(" MOVEM:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D0  (stored and restored)", dut.D[0], 32'h11111111);
		expect32("D1  (stored and restored)", dut.D[1], 32'h22222222);
		expect32("D2  (stored and restored)", dut.D[2], 32'h33333333);
		expect32("D3  (stored and restored)", dut.D[3], 32'h44444444);
		expect32("D4  (came back from -(A1))", dut.D[4], 32'h11111111);
		expect32("D5  (came back from -(A1))", dut.D[5], 32'h22222222);
		expect32("A2  (came back from -(A1))", dut.A[2], 32'h00003000);
		expect32("A0  (the base, untouched)",  dut.A[0], 32'h00003000);
		// Twelve bytes down and twelve bytes back up.
		expect32("A1  (pushed then pulled)",   dut.A[1], 32'h00004000);
		expect32("D7  (MOVEM.W sign extends)", dut.D[7], 32'hFFFFFFFF);

		// ==================================================================
		// Ninth program: the bit instructions and Scc.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0C00;      // PC

		mem[16'h0C00>>1] = 16'h203C;  mem[16'h0C02>>1] = 16'h0000;
		mem[16'h0C04>>1] = 16'h0000;               // MOVE.L #0,D0
		mem[16'h0C06>>1] = 16'h08C0;  mem[16'h0C08>>1] = 16'h0003;
		                                           // BSET #3,D0   -> $08
		mem[16'h0C0A>>1] = 16'h08C0;  mem[16'h0C0C>>1] = 16'h001F;
		                                           // BSET #31,D0  -> $80000008
		mem[16'h0C0E>>1] = 16'h0880;  mem[16'h0C10>>1] = 16'h0003;
		                                           // BCLR #3,D0   -> $80000000
		mem[16'h0C12>>1] = 16'h0840;  mem[16'h0C14>>1] = 16'h0000;
		                                           // BCHG #0,D0   -> $80000001
		mem[16'h0C16>>1] = 16'h0800;  mem[16'h0C18>>1] = 16'h001F;
		                                           // BTST #31,D0  -> Z clear
		mem[16'h0C1A>>1] = 16'h4E71;               // NOP  (sample point)
		mem[16'h0C1C>>1] = 16'h0800;  mem[16'h0C1E>>1] = 16'h0002;
		                                           // BTST #2,D0   -> Z set
		mem[16'h0C20>>1] = 16'h4E71;               // NOP  (sample point)

		mem[16'h0C22>>1] = 16'h7400;               // MOVEQ #0,D2
		mem[16'h0C24>>1] = 16'h7201;               // MOVEQ #1,D1
		mem[16'h0C26>>1] = 16'h03C2;               // BSET D1,D2   -> $02

		// In memory the destination is a byte and the number wraps to eight, so
		// bit 9 is bit 1. A register-width mask would set nothing at all here.
		mem[16'h0C28>>1] = 16'h207C;  mem[16'h0C2A>>1] = 16'h0000;
		mem[16'h0C2C>>1] = 16'h3000;               // MOVEA.L #$3000,A0
		mem[16'h0C2E>>1] = 16'h7600;               // MOVEQ #0,D3
		mem[16'h0C30>>1] = 16'h1083;               // MOVE.B D3,(A0)
		mem[16'h0C32>>1] = 16'h08D0;  mem[16'h0C34>>1] = 16'h0009;
		                                           // BSET #9,(A0) -> $02
		mem[16'h0C36>>1] = 16'h1810;               // MOVE.B (A0),D4

		mem[16'h0C38>>1] = 16'h2C3C;  mem[16'h0C3A>>1] = 16'h1234;
		mem[16'h0C3C>>1] = 16'h5678;               // MOVE.L #$12345678,D6
		mem[16'h0C3E>>1] = 16'h2E3C;  mem[16'h0C40>>1] = 16'h1234;
		mem[16'h0C42>>1] = 16'h5678;               // MOVE.L #$12345678,D7
		mem[16'h0C44>>1] = 16'h7A05;               // MOVEQ #5,D5
		mem[16'h0C46>>1] = 16'h0C05;  mem[16'h0C48>>1] = 16'h0005;
		                                           // CMPI.B #5,D5 -> equal
		mem[16'h0C4A>>1] = 16'h57C6;               // SEQ D6  -> low byte $FF
		mem[16'h0C4C>>1] = 16'h56C7;               // SNE D7  -> low byte $00

		mem[16'h0C4E>>1] = 16'h4E72;  mem[16'h0C50>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;

		$display("");
		$display(" bit tests:");
		// A bit instruction touches Z and nothing else, so the other four flags
		// are still whatever MOVE.L #0 left them.
		wait_pc(32'h00000C1A);
		flags("BTST #31 of $80000001  ->  Z clear", 5'b00000);
		wait_pc(32'h00000C20);
		flags("BTST #2  of $80000001  ->  Z set",   5'b00100);

		run_until_halt(40000);

		$display("");
		$display(" bit instructions and Scc:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D0  (BSET, BSET, BCLR, BCHG)", dut.D[0], 32'h80000001);
		expect32("D2  (BSET with the number in D1)", dut.D[2], 32'h00000002);
		expect32("D4  (BSET #9 on a byte in memory)", dut.D[4], 32'h00000002);
		// Scc writes a byte and leaves the rest of the register alone.
		expect32("D6  (SEQ, condition true)",  dut.D[6], 32'h123456FF);
		expect32("D7  (SNE, condition false)", dut.D[7], 32'h12345600);

		// ==================================================================
		// Tenth program: the indexed and PC-relative addressing modes.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0D00;      // PC

		mem[16'h0D00>>1] = 16'h207C;  mem[16'h0D02>>1] = 16'h0000;
		mem[16'h0D04>>1] = 16'h3000;               // MOVEA.L #$3000,A0
		mem[16'h0D06>>1] = 16'h203C;  mem[16'h0D08>>1] = 16'hAABB;
		mem[16'h0D0A>>1] = 16'hCCDD;               // MOVE.L #$AABBCCDD,D0
		mem[16'h0D0C>>1] = 16'h2080;               // MOVE.L D0,(A0)
		mem[16'h0D0E>>1] = 16'h223C;  mem[16'h0D10>>1] = 16'h1122;
		mem[16'h0D12>>1] = 16'h3344;               // MOVE.L #$11223344,D1
		mem[16'h0D14>>1] = 16'h2141;  mem[16'h0D16>>1] = 16'h0004;
		                                           // MOVE.L D1,4(A0)

		mem[16'h0D18>>1] = 16'h7404;               // MOVEQ #4,D2
		mem[16'h0D1A>>1] = 16'h2630;  mem[16'h0D1C>>1] = 16'h2000;
		                                           // MOVE.L 0(A0,D2.W),D3
		// A displacement relative to PC counts from the extension word, at $0D20
		// and $0D24 -- both of these land on the constant at $0D40.
		mem[16'h0D1E>>1] = 16'h283A;  mem[16'h0D20>>1] = 16'h0020;
		                                           // MOVE.L $20(PC),D4
		mem[16'h0D22>>1] = 16'h2A3B;  mem[16'h0D24>>1] = 16'h2018;
		                                           // MOVE.L $18(PC,D2.W),D5
		// A negative displacement, to prove the byte is sign extended: four
		// forward in the index and four back in the displacement is $3000.
		mem[16'h0D26>>1] = 16'h2C30;  mem[16'h0D28>>1] = 16'h20FC;
		                                           // MOVE.L -4(A0,D2.W),D6

		mem[16'h0D2A>>1] = 16'h4E72;  mem[16'h0D2C>>1] = 16'h2700;   // STOP

		mem[16'h0D40>>1] = 16'hDEAD;  mem[16'h0D42>>1] = 16'hBEEF;

		repeat (4) @(posedge clk);
		rst = 0;
		run_until_halt(40000);

		$display("");
		$display(" indexed and PC-relative addressing:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D3  (0(A0,D2.W))",   dut.D[3], 32'h11223344);
		expect32("D4  ($20(PC))",      dut.D[4], 32'hDEADBEEF);
		expect32("D5  ($18(PC,D2.W))", dut.D[5], 32'hDEADBEEF);
		expect32("D6  (-4(A0,D2.W))",  dut.D[6], 32'hAABBCCDD);

		// ==================================================================
		// Eleventh program: exceptions.
		//
		// STOP is used as the meeting point: the program stops with the mask
		// open, the testbench raises a level 6 request, and the handler has to
		// run and return to exactly where the program was. Then a TRAP does the
		// same thing from the other side -- software rather than hardware -- and
		// the stack has to come back to where it started after both.
		// ==================================================================
		rst = 1;
		ipl_n = 3'b111;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0E00;      // PC
		mem[16'h0078>>1] = 16'h0000;               // vector 30: level 6 autovector
		mem[16'h007A>>1] = 16'h0E40;
		mem[16'h0080>>1] = 16'h0000;               // vector 32: TRAP #0
		mem[16'h0082>>1] = 16'h0E50;

		mem[16'h0E00>>1] = 16'h027C;  mem[16'h0E02>>1] = 16'hF8FF;
		                                           // ANDI #$F8FF,SR -> mask 0
		mem[16'h0E04>>1] = 16'h7200;               // MOVEQ #0,D1
		mem[16'h0E06>>1] = 16'h7400;               // MOVEQ #0,D2
		mem[16'h0E08>>1] = 16'h4E72;  mem[16'h0E0A>>1] = 16'h2000;
		                                           // STOP #$2000 -- wait for it
		mem[16'h0E0C>>1] = 16'h4E40;               // TRAP #0
		mem[16'h0E0E>>1] = 16'h4E72;  mem[16'h0E10>>1] = 16'h2700;
		                                           // STOP #$2700 -- done

		mem[16'h0E40>>1] = 16'h123C;  mem[16'h0E42>>1] = 16'h00A5;
		                                           // handler: MOVE.B #$A5,D1
		mem[16'h0E44>>1] = 16'h4E73;               //          RTE
		mem[16'h0E50>>1] = 16'h143C;  mem[16'h0E52>>1] = 16'h005A;
		                                           // trap:    MOVE.B #$5A,D2
		mem[16'h0E54>>1] = 16'h4E73;               //          RTE

		repeat (4) @(posedge clk);
		rst = 0;

		// Wait for the first STOP, which is the program saying it is ready.
		n = 0;
		while (halted !== 1'b1 && n < 20000) begin @(posedge clk); n = n + 1; end
		$display("");
		$display(" exceptions:");
		check(halted === 1'b1, "the program stopped to wait for an interrupt");
		// ANDI to SR opened the mask; STOP's own operand then set it to the same
		// thing. Supervisor, mask 0.
		expect32("SR while stopped", {16'd0, sr}, 32'h00002000);

		// A level 6 request, held until it is seen.
		ipl_n = 3'b001;
		n = 0;
		while (halted !== 1'b0 && n < 20000) begin @(posedge clk); n = n + 1; end
		check(halted === 1'b0, "the interrupt woke it from STOP");
		// Inside the handler the mask must have come up to 6, or the same
		// interrupt would be taken again on the next instruction boundary.
		wait_pc(32'h00000E40);
		expect32("SR inside the handler (mask raised to 6)",
		         {16'd0, sr}, 32'h00002600);
		ipl_n = 3'b111;

		run_until_halt(40000);
		check(halted === 1'b1, "it reached the final STOP");
		expect32("D1  (the interrupt handler ran)", dut.D[1], 32'h000000A5);
		expect32("D2  (the trap handler ran)",      dut.D[2], 32'h0000005A);
		// Two exceptions, two RTEs, six bytes of frame each.
		expect32("A7  (stack balanced across both)", dut.A[7], 32'h00001000);

		// ==================================================================
		// Twelfth program: multiply and divide.
		//
		// The signed and unsigned forms of the same opcode differ only in one
		// bit, so each is checked against an operand whose top bit is set --
		// where they give genuinely different answers -- rather than against a
		// small positive number where they agree.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h0F00;      // PC
		mem[16'h0014>>1] = 16'h0000;               // vector 5: divide by zero
		mem[16'h0016>>1] = 16'h0F60;

		mem[16'h0F00>>1] = 16'h203C;  mem[16'h0F02>>1] = 16'h0000;
		mem[16'h0F04>>1] = 16'h1234;               // MOVE.L #$1234,D0
		mem[16'h0F06>>1] = 16'h223C;  mem[16'h0F08>>1] = 16'h0000;
		mem[16'h0F0A>>1] = 16'h5678;               // MOVE.L #$5678,D1
		mem[16'h0F0C>>1] = 16'hC0C1;               // MULU.W D1,D0
		mem[16'h0F0E>>1] = 16'h2040;               // MOVEA.L D0,A0  (park it)

		// $FFFF is -1 signed and 65535 unsigned, so these two multiplies of the
		// same pair of registers must not agree.
		mem[16'h0F10>>1] = 16'h243C;  mem[16'h0F12>>1] = 16'h0000;
		mem[16'h0F14>>1] = 16'hFFFF;               // MOVE.L #$FFFF,D2
		mem[16'h0F16>>1] = 16'h263C;  mem[16'h0F18>>1] = 16'h0000;
		mem[16'h0F1A>>1] = 16'h0002;               // MOVE.L #2,D3
		mem[16'h0F1C>>1] = 16'hC7C2;               // MULS.W D2,D3 -> -2
		mem[16'h0F1E>>1] = 16'h283C;  mem[16'h0F20>>1] = 16'h0000;
		mem[16'h0F22>>1] = 16'h0002;               // MOVE.L #2,D4
		mem[16'h0F24>>1] = 16'hC8C2;               // MULU.W D2,D4 -> $0001FFFE

		// The result of a divide is the remainder in the top half and the
		// quotient in the bottom, which is the other way round from how it reads.
		mem[16'h0F26>>1] = 16'h2A3C;  mem[16'h0F28>>1] = 16'h0001;
		mem[16'h0F2A>>1] = 16'h0000;               // MOVE.L #$00010000,D5
		mem[16'h0F2C>>1] = 16'h2C3C;  mem[16'h0F2E>>1] = 16'h0000;
		mem[16'h0F30>>1] = 16'h0003;               // MOVE.L #3,D6
		mem[16'h0F32>>1] = 16'h8AC6;               // DIVU.W D6,D5 -> $0001_5555

		// -100 / 7 is -14 remainder -2: the remainder follows the DIVIDEND's
		// sign, not the quotient's.
		mem[16'h0F34>>1] = 16'h2E3C;  mem[16'h0F36>>1] = 16'hFFFF;
		mem[16'h0F38>>1] = 16'hFF9C;               // MOVE.L #-100,D7
		mem[16'h0F3A>>1] = 16'h8FFC;  mem[16'h0F3C>>1] = 16'h0007;
		                                           // DIVS.W #7,D7 -> $FFFE_FFF2

		// A quotient too big for sixteen bits sets V and writes nothing.
		mem[16'h0F3E>>1] = 16'h203C;  mem[16'h0F40>>1] = 16'hFFFF;
		mem[16'h0F42>>1] = 16'hFFFF;               // MOVE.L #$FFFFFFFF,D0
		mem[16'h0F44>>1] = 16'h80FC;  mem[16'h0F46>>1] = 16'h0001;
		                                           // DIVU.W #1,D0 -> overflow
		mem[16'h0F48>>1] = 16'h4E71;               // NOP  (sample point)

		// And dividing by zero is an exception, not a wrong answer.
		mem[16'h0F4A>>1] = 16'h223C;  mem[16'h0F4C>>1] = 16'h0000;
		mem[16'h0F4E>>1] = 16'h0001;               // MOVE.L #1,D1
		mem[16'h0F50>>1] = 16'h82FC;  mem[16'h0F52>>1] = 16'h0000;
		                                           // DIVU.W #0,D1
		mem[16'h0F54>>1] = 16'h4E72;  mem[16'h0F56>>1] = 16'h2700;
		                                           // STOP  (must NOT be reached)

		mem[16'h0F60>>1] = 16'h7C2A;               // handler: MOVEQ #42,D6
		mem[16'h0F62>>1] = 16'h4E72;  mem[16'h0F64>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;

		$display("");
		$display(" divide overflow:");
		wait_pc(32'h00000F48);
		// Only V moves; N is still what MOVE.L #$FFFFFFFF left.
		flags("DIVU with a quotient too wide  ->  V set", 5'b01010);

		run_until_halt(60000);

		$display("");
		$display(" multiply and divide:");
		check(halted === 1'b1, "the program reached a STOP");
		expect32("A0  (MULU $1234 by $5678)",   dut.A[0], 32'h06260060);
		expect32("D3  (MULS by -1)",            dut.D[3], 32'hFFFFFFFE);
		expect32("D4  (MULU by 65535)",         dut.D[4], 32'h0001FFFE);
		expect32("D5  (DIVU: remainder:quotient)", dut.D[5], 32'h00015555);
		expect32("D7  (DIVS -100 by 7)",        dut.D[7], 32'hFFFEFFF2);
		// The overflowing divide left its dividend where it was.
		expect32("D0  (untouched by the overflow)", dut.D[0], 32'hFFFFFFFF);
		// Reaching the handler at all is the check: the STOP after the divide
		// would have left D6 at 3.
		expect32("D6  (the divide-by-zero handler ran)", dut.D[6], 32'd42);

		// ==================================================================
		// Thirteenth program: the extended arithmetic, in registers, and EXG.
		//
		// ADDX and SUBX exist to carry between the halves of a number wider than
		// the machine, so that is what they are checked doing: a 64-bit add and
		// a 64-bit subtract, each with a borrow that has to cross the middle.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h1000;      // PC

		// $00000001_FFFFFFFF + $00000000_00000001
		mem[16'h1000>>1] = 16'h203C;  mem[16'h1002>>1] = 16'h0000;
		mem[16'h1004>>1] = 16'h0001;               // MOVE.L #1,D0        high a
		mem[16'h1006>>1] = 16'h223C;  mem[16'h1008>>1] = 16'hFFFF;
		mem[16'h100A>>1] = 16'hFFFF;               // MOVE.L #-1,D1       low a
		mem[16'h100C>>1] = 16'h243C;  mem[16'h100E>>1] = 16'h0000;
		mem[16'h1010>>1] = 16'h0000;               // MOVE.L #0,D2        high b
		mem[16'h1012>>1] = 16'h263C;  mem[16'h1014>>1] = 16'h0000;
		mem[16'h1016>>1] = 16'h0001;               // MOVE.L #1,D3        low b
		mem[16'h1018>>1] = 16'hD283;               // ADD.L  D3,D1  -> 0, X set
		mem[16'h101A>>1] = 16'hD182;               // ADDX.L D2,D0  -> 2
		mem[16'h101C>>1] = 16'h4E71;               // NOP  (sample point)

		// 2:0 minus 0:1
		mem[16'h101E>>1] = 16'h283C;  mem[16'h1020>>1] = 16'h0000;
		mem[16'h1022>>1] = 16'h0002;               // MOVE.L #2,D4
		mem[16'h1024>>1] = 16'h2A3C;  mem[16'h1026>>1] = 16'h0000;
		mem[16'h1028>>1] = 16'h0000;               // MOVE.L #0,D5
		mem[16'h102A>>1] = 16'h2C3C;  mem[16'h102C>>1] = 16'h0000;
		mem[16'h102E>>1] = 16'h0000;               // MOVE.L #0,D6
		mem[16'h1030>>1] = 16'h2E3C;  mem[16'h1032>>1] = 16'h0000;
		mem[16'h1034>>1] = 16'h0001;               // MOVE.L #1,D7
		mem[16'h1036>>1] = 16'h9A87;               // SUB.L  D7,D5 -> -1, X set
		mem[16'h1038>>1] = 16'h9986;               // SUBX.L D6,D4 -> 1

		mem[16'h103A>>1] = 16'h247C;  mem[16'h103C>>1] = 16'h0000;
		mem[16'h103E>>1] = 16'h1111;               // MOVEA.L #$1111,A2
		mem[16'h1040>>1] = 16'h267C;  mem[16'h1042>>1] = 16'h0000;
		mem[16'h1044>>1] = 16'h2222;               // MOVEA.L #$2222,A3
		mem[16'h1046>>1] = 16'hC54B;               // EXG A2,A3
		// Swapping a data and an address register moves the SUBX result into A3,
		// so one check covers both instructions.
		mem[16'h1048>>1] = 16'hC98B;               // EXG D4,A3

		mem[16'h104A>>1] = 16'h2E3C;  mem[16'h104C>>1] = 16'hFFFF;
		mem[16'h104E>>1] = 16'hFFFF;               // MOVE.L #-1,D7
		mem[16'h1050>>1] = 16'h0687;  mem[16'h1052>>1] = 16'h0000;
		mem[16'h1054>>1] = 16'h0001;               // ADDI.L #1,D7 -> 0, X set
		mem[16'h1056>>1] = 16'h2E3C;  mem[16'h1058>>1] = 16'h0000;
		mem[16'h105A>>1] = 16'h0005;               // MOVE.L #5,D7  (X survives)
		mem[16'h105C>>1] = 16'h4087;               // NEGX.L D7 -> -6

		mem[16'h105E>>1] = 16'h4E72;  mem[16'h1060>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;

		$display("");
		$display(" extended arithmetic flags:");
		wait_pc(32'h0000101C);
		// The low half came out zero and set Z; the high half did not, and must
		// have CLEARED it. A plain ADD would have left Z set here.
		flags("ADDX after a zero low half  ->  Z cleared", 5'b00000);

		run_until_halt(40000);

		$display("");
		$display(" ADDX, SUBX, NEGX, EXG:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D0  (high half, carry in)",  dut.D[0], 32'h00000002);
		expect32("D1  (low half wrapped)",     dut.D[1], 32'h00000000);
		expect32("D5  (low half borrowed)",    dut.D[5], 32'hFFFFFFFF);
		expect32("A2  (EXG A2,A3)",            dut.A[2], 32'h00002222);
		expect32("D4  (EXG D4,A3 brought $1111 over)", dut.D[4], 32'h00001111);
		expect32("A3  (and took the SUBX result back)", dut.A[3], 32'h00000001);
		expect32("D7  (NEGX of 5 with X set)", dut.D[7], 32'hFFFFFFFA);

		// ==================================================================
		// Fourteenth program: the memory forms -- ADDX and CMPM through
		// pointers, PEA, LINK/UNLK and TAS.
		// ==================================================================
		rst = 1;
		repeat (8) @(posedge clk);
		for (i = 0; i < 16384; i = i + 1) mem[i] = 16'h4E71;
		mem[0] = 16'h0000; mem[1] = 16'h1000;      // SSP
		mem[2] = 16'h0000; mem[3] = 16'h1100;      // PC

		// Build $3000: 1, $FFFFFFFF, 0, 1  -- the same two 64-bit numbers again.
		mem[16'h1100>>1] = 16'h203C;  mem[16'h1102>>1] = 16'h0000;
		mem[16'h1104>>1] = 16'h0001;               // MOVE.L #1,D0
		mem[16'h1106>>1] = 16'h223C;  mem[16'h1108>>1] = 16'hFFFF;
		mem[16'h110A>>1] = 16'hFFFF;               // MOVE.L #-1,D1
		mem[16'h110C>>1] = 16'h207C;  mem[16'h110E>>1] = 16'h0000;
		mem[16'h1110>>1] = 16'h3000;               // MOVEA.L #$3000,A0
		mem[16'h1112>>1] = 16'h20C0;               // MOVE.L D0,(A0)+
		mem[16'h1114>>1] = 16'h20C1;               // MOVE.L D1,(A0)+
		mem[16'h1116>>1] = 16'h243C;  mem[16'h1118>>1] = 16'h0000;
		mem[16'h111A>>1] = 16'h0000;               // MOVE.L #0,D2
		mem[16'h111C>>1] = 16'h263C;  mem[16'h111E>>1] = 16'h0000;
		mem[16'h1120>>1] = 16'h0001;               // MOVE.L #1,D3
		mem[16'h1122>>1] = 16'h20C2;               // MOVE.L D2,(A0)+
		mem[16'h1124>>1] = 16'h20C3;               // MOVE.L D3,(A0)+
		mem[16'h1126>>1] = 16'h2248;               // MOVEA.L A0,A1   ($3010)
		mem[16'h1128>>1] = 16'h207C;  mem[16'h112A>>1] = 16'h0000;
		mem[16'h112C>>1] = 16'h3008;               // MOVEA.L #$3008,A0

		// Both pointers sit one past their number, because -(An) steps first.
		mem[16'h112E>>1] = 16'h44FC;  mem[16'h1130>>1] = 16'h0000;
		                                           // MOVE #0,CCR  -- X clear
		mem[16'h1132>>1] = 16'hD189;               // ADDX.L -(A1),-(A0)  low
		mem[16'h1134>>1] = 16'hD189;               // ADDX.L -(A1),-(A0)  high
		mem[16'h1136>>1] = 16'h2810;               // MOVE.L (A0),D4   -> 2
		mem[16'h1138>>1] = 16'h2A28;  mem[16'h113A>>1] = 16'h0004;
		                                           // MOVE.L 4(A0),D5  -> 0

		mem[16'h113C>>1] = 16'h207C;  mem[16'h113E>>1] = 16'h0000;
		mem[16'h1140>>1] = 16'h3004;               // MOVEA.L #$3004,A0
		mem[16'h1142>>1] = 16'h227C;  mem[16'h1144>>1] = 16'h0000;
		mem[16'h1146>>1] = 16'h3008;               // MOVEA.L #$3008,A1
		mem[16'h1148>>1] = 16'hB189;               // CMPM.L (A1)+,(A0)+  equal
		mem[16'h114A>>1] = 16'h4E71;               // NOP  (sample point)

		mem[16'h114C>>1] = 16'h2C7C;  mem[16'h114E>>1] = 16'h0000;
		mem[16'h1150>>1] = 16'h9999;               // MOVEA.L #$9999,A6
		mem[16'h1152>>1] = 16'h4E56;  mem[16'h1154>>1] = 16'hFFF8;
		                                           // LINK A6,#-8
		mem[16'h1156>>1] = 16'h264E;               // MOVEA.L A6,A3  frame ptr
		mem[16'h1158>>1] = 16'h284F;               // MOVEA.L A7,A4  frame top
		mem[16'h115A>>1] = 16'h4E5E;               // UNLK A6
		mem[16'h115C>>1] = 16'h2A4F;               // MOVEA.L A7,A5  back again

		mem[16'h115E>>1] = 16'h4851;               // PEA (A1)      pushes $300C
		mem[16'h1160>>1] = 16'h2C1F;               // MOVE.L (A7)+,D6

		mem[16'h1162>>1] = 16'h207C;  mem[16'h1164>>1] = 16'h0000;
		mem[16'h1166>>1] = 16'h3020;               // MOVEA.L #$3020,A0
		mem[16'h1168>>1] = 16'h7E00;               // MOVEQ #0,D7
		mem[16'h116A>>1] = 16'h1087;               // MOVE.B D7,(A0)
		mem[16'h116C>>1] = 16'h4AD0;               // TAS (A0)   -> byte becomes $80
		mem[16'h116E>>1] = 16'h1E10;               // MOVE.B (A0),D7

		mem[16'h1170>>1] = 16'h4E72;  mem[16'h1172>>1] = 16'h2700;   // STOP

		repeat (4) @(posedge clk);
		rst = 0;

		$display("");
		$display(" CMPM flags:");
		wait_pc(32'h0000114A);
		flags("CMPM of two equal longwords  ->  Z set", 5'b00100);

		run_until_halt(60000);

		$display("");
		$display(" memory forms:");
		check(halted === 1'b1, "the program reached STOP");
		expect32("D4  (ADDX through pointers, high)", dut.D[4], 32'h00000002);
		expect32("D5  (ADDX through pointers, low)",  dut.D[5], 32'h00000000);
		// After CMPM both pointers have stepped on by four.
		expect32("A0  (CMPM stepped it once)", dut.A[0], 32'h00003020);
		expect32("A1  (CMPM stepped it once)", dut.A[1], 32'h0000300C);
		// LINK pushed the old A6 and pointed it at the frame; UNLK undid both.
		expect32("A3  (frame pointer)",        dut.A[3], 32'h00000FFC);
		expect32("A4  (top of the frame)",     dut.A[4], 32'h00000FF4);
		expect32("A5  (stack after UNLK)",     dut.A[5], 32'h00001000);
		expect32("A6  (old frame pointer back)", dut.A[6], 32'h00009999);
		expect32("D6  (PEA pushed the address)", dut.D[6], 32'h0000300C);
		expect32("D7  (TAS set the high bit)",   dut.D[7], 32'h00000080);

		$display("");
		if (errors == 0) $display("tb_m68k: all checks passed");
		else             $display("tb_m68k: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (400000) @(posedge clk);
		$display("tb_m68k: FAIL timeout at PC=%08x", pc);
		$finish;
	end

endmodule
