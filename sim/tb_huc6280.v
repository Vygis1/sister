`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_huc6280 - the PC Engine's processor against the SingleStepTests wdc65c02 suite.
//
// Ten thousand tests an opcode: registers and a few bytes of RAM going in, registers and
// RAM coming out. The HuC6280 does what the 65C02 does for all of those (its own opcodes
// and BRK are left out, tools/pce/c02tests.py says which and why), so the core's state after
// the instruction is compared with the suite's, and the cycles it took with the HuC6280's
// count that the converter puts in each record.
//
// The core runs in high speed with ce high, one cycle a clock. Its mapping registers are
// set so that logical and physical addresses agree, except bank 1, mapped onto bank 0, so
// zero page and the stack are at $0000-$01FF of a flat 64 kB RAM as the suite expects
// (the converter drops tests that use $2000-$3FFF). Each test loads the registers straight
// into the hierarchy at a negedge, with the core idle at an opcode fetch.
//
//   ./tools/sim.sh tb_huc6280                 everything in build/65x02tests/all.hex
//   ./tools/sim.sh tb_huc6280 ONLY7c          one opcode (hex). No "=": the .bat wrappers
//   ./tools/sim.sh tb_huc6280 MAXFAIL20       split arguments on it
//////////////////////////////////////////////////////////////////////////////////
module tb_huc6280;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;
	wire [20:0] addr;
	wire [7:0]  dout;
	wire [7:0]  din;
	wire        rd, we, sync, fast;
	wire [7:0]  dbg_a, dbg_x, dbg_y, dbg_s, dbg_p, dbg_mpr1;
	wire [15:0] dbg_pc;

	huc6280 dut (
		.clk(clk), .rst(rst), .ce(1'b1),
		.addr(addr), .din(din), .dout(dout), .we(we), .rd(rd),
		.irq1(1'b0), .irq2(1'b0), .irq_timer(1'b0), .nmi(1'b0),
		.fast(fast), .sync(sync),
		.dbg_a(dbg_a), .dbg_x(dbg_x), .dbg_y(dbg_y), .dbg_s(dbg_s), .dbg_p(dbg_p), .dbg_pc(dbg_pc), .dbg_mpr1(dbg_mpr1)
	);

	// Flat RAM. The core puts an address out at one edge and takes the byte at the next: on
	// the board a cycle is seven clocks and a block RAM answers within it, so here, with a
	// cycle a clock, the RAM answers at once. (Bank 1 is mapped onto bank 0, so the physical
	// address never leaves the low 64 kB.)
	reg [7:0] ram [0:65535];
	assign din = ram[addr[15:0]];
	always @(posedge clk) if (we) ram[addr[15:0]] <= dout;

	// --- the stream ---------------------------------------------------------------------
	integer fd, r;
	reg [31:0] v;
	task rd_word; begin r = $fscanf(fd, "%h", v); end endtask

	integer opid;
	reg [15:0] i_pc, f_pc;
	reg [7:0]  i_s, i_a, i_x, i_y, i_p, e_s, e_a, e_x, e_y, e_p;
	integer    n_iram, n_fram, n_cyc;
	reg [15:0] iram_a [0:63]; reg [7:0] iram_d [0:63];
	reg [15:0] fram_a [0:63]; reg [7:0] fram_d [0:63];

	integer pass_op [0:255];
	integer fail_op [0:255];
	integer total = 0, passed = 0, failed = 0, printed = 0, maxfail = 10;
	integer only = -1;
	integer i, k, bad, got_cyc;
	reg [1023:0] why;
	reg [7:0] got_p;

	task note; input [1023:0] s; begin if (bad == 0) why = s; bad = bad + 1; end endtask

	initial begin
		for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
		for (i = 0; i < 256; i = i + 1) begin pass_op[i] = 0; fail_op[i] = 0; end
		if (!$value$plusargs("MAXFAIL%d", maxfail)) maxfail = 10;
		if (!$value$plusargs("ONLY%h", only)) only = -1;

		$display("tb_huc6280");
		fd = $fopen("../../build/65x02tests/all.hex", "r");
		if (fd == 0) begin
			$display("  FAIL cannot open build/65x02tests/all.hex -- run tools/pce/c02tests.py");
			$finish;
		end

		repeat (4) @(posedge clk);
		rst = 0;
		@(negedge clk);

		rd_word;
		while (r == 1) begin
			opid = v;
			rd_word; i_pc = v; rd_word; i_s = v; rd_word; i_a = v; rd_word; i_x = v; rd_word; i_y = v; rd_word; i_p = v;
			rd_word; n_iram = v;
			for (i = 0; i < n_iram; i = i + 1) begin rd_word; iram_a[i] = v; rd_word; iram_d[i] = v; end
			rd_word; f_pc = v; rd_word; e_s = v; rd_word; e_a = v; rd_word; e_x = v; rd_word; e_y = v; rd_word; e_p = v;
			rd_word; n_fram = v;
			for (i = 0; i < n_fram; i = i + 1) begin rd_word; fram_a[i] = v; rd_word; fram_d[i] = v; end
			rd_word; n_cyc = v;

			if (only < 0 || only == opid) begin
				total = total + 1;
				bad = 0;

				// --- load the core (at a negedge, idle at a fetch) -------------------------------
				for (i = 0; i < n_iram; i = i + 1) ram[iram_a[i]] = iram_d[i];
				dut.A = i_a; dut.X = i_x; dut.Y = i_y; dut.S = i_s; dut.PC = i_pc;
				dut.fN = i_p[7]; dut.fV = i_p[6]; dut.fT = 1'b0; dut.fD = i_p[3]; dut.fI = i_p[2]; dut.fZ = i_p[1]; dut.fC = i_p[0];
				for (i = 0; i < 8; i = i + 1) dut.MPR[i] = (i == 1) ? 8'd0 : i;
				dut.st = dut.S_FETCH; dut.left = 6'd0; dut.penalty = 1'b0; dut.t_mode = 1'b0;
				dut.nmi_pend = 1'b0; dut.irq_sel = 3'd0; dut.fast = 1'b1; dut.slow = 2'd0;
				dut.addr = {8'd0, i_pc[12:0]} | {i_pc[15:13] == 3'd1 ? 8'd0 : {5'd0, i_pc[15:13]}, 13'd0};
				dut.rd = 1'b1; dut.we = 1'b0;

				// --- run until the next opcode fetch, counting cycles ---------------------------
				got_cyc = 0;
				@(negedge clk);                           // the fetch cycle itself
				got_cyc = 1;
				while (!sync && got_cyc < 80) begin @(negedge clk); got_cyc = got_cyc + 1; end
				if (!sync) note("never finished");
				else if (got_cyc != n_cyc) note("cycle count");

				// --- compare ----------------------------------------------------------------
				got_p = dbg_p & 8'hCF;
				if (dut.A != e_a || dut.X != e_x || dut.Y != e_y || dut.S != e_s) note("registers");
				if (got_p != (e_p & 8'hCF)) note("flags");
				if (dut.PC != f_pc) note("pc");
				for (i = 0; i < n_fram; i = i + 1)
					if (ram[fram_a[i]] != fram_d[i]) note("memory");

				if (bad == 0) begin passed = passed + 1; pass_op[opid] = pass_op[opid] + 1; end
				else begin
					failed = failed + 1; fail_op[opid] = fail_op[opid] + 1;
					if (printed < maxfail) begin
						printed = printed + 1;
						$display("  FAIL %02x #%0d: %0s", opid, pass_op[opid] + fail_op[opid], why);
						$display("       in : pc %04x s %02x a %02x x %02x y %02x p %02x", i_pc, i_s, i_a, i_x, i_y, i_p);
						$display("       got: pc %04x s %02x a %02x x %02x y %02x p %02x  %0d cycles", dut.PC, dut.S, dut.A, dut.X, dut.Y, got_p, got_cyc);
						$display("       want pc %04x s %02x a %02x x %02x y %02x p %02x  %0d cycles", f_pc, e_s, e_a, e_x, e_y, e_p & 8'hCF, n_cyc);
						for (i = 0; i < n_fram; i = i + 1)
							if (ram[fram_a[i]] != fram_d[i]) $display("       mem[%04x] = %02x, want %02x", fram_a[i], ram[fram_a[i]], fram_d[i]);
					end
				end
				// the RAM back to zero where the test wrote
				for (i = 0; i < n_iram; i = i + 1) ram[iram_a[i]] = 8'h00;
				for (i = 0; i < n_fram; i = i + 1) ram[fram_a[i]] = 8'h00;
				@(negedge clk);
			end
			rd_word;
		end

		$display("  %0d tests: %0d passed, %0d failed", total, passed, failed);
		for (i = 0; i < 256; i = i + 1)
			if (fail_op[i] != 0) $display("    opcode %02x: %0d of %0d failed", i, fail_op[i], fail_op[i] + pass_op[i]);
		if (failed == 0 && total > 0) $display("tb_huc6280: all checks passed");
		else $display("tb_huc6280: %0d FAIL(s)", failed);
		$finish;
	end
endmodule
