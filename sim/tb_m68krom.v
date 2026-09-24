`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_m68krom - run the generated 68000 test program.
//
// tb_m68k.v checks instructions one at a time, by hand, and is where a new
// instruction group gets its first test. This one is the other half: a program
// built by tools/m68ktest.py that sweeps thousands of operand pairs against a
// model of the 68000 written in Python from the manual. Two independent
// descriptions of the same rules, disagreeing loudly when either is wrong.
//
// The program stops at the first disagreement and leaves behind which case it
// was, what the processor produced and what it should have. Case numbers are
// listed in sim/roms/m68k/m68ktest.txt -- number 1834 is a line in that file,
// not a number to stare at.
//////////////////////////////////////////////////////////////////////////////////

module tb_m68krom;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One enable in four, as in tb_m68k: a CPU that only works when memory
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
		.ipl_n(3'b111),
		.dbg_pc(pc), .dbg_ir(ir), .dbg_sr(sr), .dbg_halted(halted),
		.dbg_d0(d0), .dbg_a7(a7)
	);

	// A megabyte. The generated program is sixty kilobytes on its own, and it
	// keeps its stack and its results well clear of itself.
	reg [15:0] mem [0:524287];
	always @(posedge clk) if (ce) begin
		if (req && we) begin
			if (ds[1]) mem[addr[20:1]][15:8] <= dout[15:8];
			if (ds[0]) mem[addr[20:1]][7:0]  <= dout[7:0];
		end
		din <= mem[addr[20:1]];
	end

	// Where the program leaves its answer. These have to match the constants at
	// the top of tools/m68ktest.py.
	localparam RESULT = 20'h81000 >> 1;
	localparam COUNT  = 20'h81002 >> 1;
	localparam ACTUAL = 20'h81004 >> 1;
	localparam WANTED = 20'h81008 >> 1;

	integer n;

	initial begin
		$readmemh("../../sim/roms/m68k/m68ktest.hex", mem);

		repeat (8) @(posedge clk);
		rst = 0;

		n = 0;
		while (halted !== 1'b1 && n < 40000000) begin
			@(posedge clk);
			n = n + 1;
			if (n % 200000 == 0)
				$display("    %0d cycles: PC=%08x IR=%04x st=%0d checks=%0d",
				         n, pc, ir, dut.st, mem[COUNT]);
		end

		$display("tb_m68krom");
		if (halted !== 1'b1) begin
			$display("  FAIL timeout after %0d cycles at PC=%08x, %0d checks in",
			         n, pc, {mem[COUNT]});
		end else if (mem[RESULT] === 16'hFFFF) begin
			$display("  FAIL an exception was taken that nothing asked for,");
			$display("       after %0d checks, at PC=%08x", mem[COUNT], pc);
		end else if (mem[RESULT] !== 16'd0) begin
			$display("  FAIL case %0d", mem[RESULT]);
			$display("       got    %04x%04x", mem[ACTUAL], mem[ACTUAL + 1]);
			$display("       wanted %04x%04x", mem[WANTED], mem[WANTED + 1]);
			$display("       see sim/roms/m68k/m68ktest.txt for what case %0d is",
			         mem[RESULT]);
		end else if (mem[COUNT] < 16'd1000) begin
			// A run that reports no failures and almost no checks has not
			// passed, it has not happened: something is wrong with the counter
			// or with how far the program got.
			$display("  FAIL only %0d checks ran, which is far too few",
			         mem[COUNT]);
		end else begin
			$display("  ok   %0d checks, none disagreed", mem[COUNT]);
			$display("tb_m68krom: all checks passed");
		end
		$finish;
	end

endmodule
