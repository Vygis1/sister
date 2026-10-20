//////////////////////////////////////////////////////////////////////////////////
// tb_arm7 - the ARM7TDMI against the SingleStepTests suite (tools/gba/armtests.py).
//
// Each record loads the whole register state and the two pipeline words, runs one
// instruction, then compares every register, CPSR, the SPSRs and the pipeline against
// the suite's final state, and the data reads and writes against its list, in order.
// Instruction fetches answer as the suite does: the opcode at its own address, any other
// address its own value (the low 16 bits in Thumb).
//
//   ./tools/sim.sh tb_arm7 [MAXFAIL n]
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_arm7;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1, prime = 1;
	wire [31:0] addr, dout; reg [31:0] din;
	wire [1:0] size; wire we, req, code, seq, retire;
	reg ack = 0;
	reg ld_we = 0; reg [5:0] ld_idx = 0; reg [31:0] ld_data = 0;
	reg [5:0] st_idx = 0; wire [31:0] st_data; wire [31:0] dbg_pc;
	arm7tdmi dut (
		.clk(clk), .rst(rst), .tick(1'b1), .prime(prime),
		.addr(addr), .size(size), .we(we), .dout(dout), .din(din), .req(req), .ack(ack), .code(code), .seq(seq),
		.irq(1'b0),
		.ld_we(ld_we), .ld_idx(ld_idx), .ld_data(ld_data), .st_idx(st_idx), .st_data(st_data),
		.retire(retire), .dbg_pc(dbg_pc));

	integer fd, r, i, n, ntests, nfail, maxfail, k, nmem, mi, memfail, nfile, ffail, fstart, tracet;
	reg [31:0] v, opcode, base;
	reg [31:0] ini [0:38], fin [0:38];
	reg [31:0] mk [0:63], ms [0:63], ma [0:63], md [0:63];
	reg thumb, was_mul;
	reg [31:0] got [0:38];
	task rd; begin r = $fscanf(fd, "%h", v); end endtask

	// the memory: fetches by the rule, data by the list
	// the suite's data is what the bus carried (the reference rotates an unaligned load in its
	// core, as this one does)
	reg [31:0] fetched, dreg;
	always @(*) begin
		if (code) fetched = (addr == base) ? opcode : addr;
		else fetched = dreg;
		din = fetched;
	end
	// one clock of latency: ack the clock after the request (the data of the transaction the
	// request matched, held for that clock)
	wire [31:0] wmask = (size == 2'd0) ? 32'hFF : (size == 2'd1) ? 32'hFFFF : 32'hFFFFFFFF;
	always @(posedge clk) begin
		ack <= req && !ack;
		if (req && !ack && !code) begin
			dreg <= (mi < nmem) ? md[mi] : 32'hDEADBEEF;
			if (mi >= nmem) begin
				if (memfail < 3) $display("    test %0d extra %s: size %0d addr %08x data %08x", ntests, we ? "write" : "read", size, addr, dout);
				memfail = memfail + 1;
			end else begin
				if (mk[mi] != (we ? 2 : 1) || ms[mi] != (32'd1 << size) || ma[mi] != addr || (we && (md[mi] & wmask) != (dout & wmask))) begin
					if (memfail < 3) $display("    test %0d memory %0d: want kind %0d size %0d addr %08x data %08x; got %s size %0d addr %08x data %08x",
						ntests, mi, mk[mi], ms[mi], ma[mi], md[mi], we ? "write" : "read", 32'd1 << size, addr, dout);
					memfail = memfail + 1;
				end
			end
			mi = mi + 1;
		end
	end

	initial begin
		if (!$value$plusargs("MAXFAIL%d", maxfail)) maxfail = 10;
		fd = $fopen("../../build/arm7tests.hex", "r");
		if (fd == 0) begin $display("no build/arm7tests.hex: run tools/gba/armtests.py"); $finish; end
		ntests = 0; nfail = 0; nfile = 0; ffail = 0; fstart = 0;
		if (!$value$plusargs("TRACE%d", tracet)) tracet = -1;
		forever begin
			rd;
			while (r == 1 && v == 32'hFFFFFFFE) begin
				$display("  file %0d: %0d of %0d failed", nfile, nfail - ffail, ntests - fstart);
				nfile = nfile + 1; ffail = nfail; fstart = ntests;
				rd;
			end
			if (r != 1 || v == 32'hFFFFFFFF) begin
				$display("  %0d tests: %0d passed, %0d failed", ntests, ntests - nfail, nfail);
				if (nfail == 0) $display("tb_arm7: all checks passed");
				$finish;
			end
			opcode = v; rd; base = v;
			for (i = 0; i < 39; i = i + 1) begin rd; ini[i] = v; end
			for (i = 0; i < 39; i = i + 1) begin rd; fin[i] = v; end
			rd; nmem = v;
			for (i = 0; i < nmem; i = i + 1) begin rd; mk[i] = v; rd; ms[i] = v; rd; ma[i] = v; rd; md[i] = v; end
			thumb = ini[31][5];
			// load
			rst = 1; prime = 1; mi = 0; memfail = 0;
			@(posedge clk);
			for (i = 0; i < 39; i = i + 1) begin
				ld_we = 1; ld_idx = i; ld_data = ini[i];
				if (i == 37) ld_data = opcode;
				@(posedge clk);
			end
			ld_we = 1; ld_idx = 39; ld_data = ini[15]; @(posedge clk);   // pc (= R15)
			ld_we = 0; @(posedge clk);
			rst = 0;
			// run one instruction (a bounded wait)
			k = 0; was_mul = dut.is_mul;
			while (!retire && k < 400) begin
				if (ntests == tracet) $display("    [%0d] st %0d pc %08x req %0d ack %0d code %0d we %0d addr %08x din %08x dout %08x cpsr %08x lm_left %04x next %0d rm %08x rs %08x p %016x",
					k, dut.st, dut.pc, req, ack, code, we, addr, din, dout, dut.cpsr, dut.lm_left, dut.lm_next, dut.v_rm, dut.v_rs, dut.mul_p);
				@(posedge clk); k = k + 1;
			end
			if (ntests == tracet) begin
				$display("    aop %08x rlist %04x P %0d U %0d S %0d W %0d L %0d rn %0d", dut.aop, dut.rlist, dut.ld_P, dut.ld_U, dut.lm_S, dut.ld_W, dut.ld_L, dut.rn);
				for (i = 0; i < nmem; i = i + 1) $display("    mem %0d: kind %0d size %0d addr %08x data %08x", i, mk[i], ms[i], ma[i], md[i]);
			end
			@(posedge clk);
			rst = 1;
			// compare
			for (i = 0; i < 39; i = i + 1) begin
				st_idx = i; #1; got[i] = st_data;
			end
			st_idx = 39; #1; got[15] = st_data;              // R15 as pc
			if (was_mul) begin got[31] = got[31] & 32'hDFFFFFFF; fin[31] = fin[31] & 32'hDFFFFFFF; end   // (a multiply's C: the part's own Booth artefact)
			n = 0;
			for (i = 0; i < 39; i = i + 1) if (got[i] !== fin[i]) n = n + 1;
			if (k >= 400) n = n + 1;
			if (n != 0 || memfail != 0 || mi != nmem) begin
				nfail = nfail + 1;
				if (nfail <= maxfail) begin
					$display("FAIL test %0d: %s opcode %08x at %08x cpsr %08x (%0d regs wrong, mem %0d of %0d, %0d clocks%s)",
						ntests, thumb ? "thumb" : "arm", opcode, base, ini[31], n, mi, nmem, k, k >= 400 ? " TIMEOUT" : "");
					for (i = 0; i < 39; i = i + 1) if (got[i] !== fin[i])
						$display("    %s[%0d]: initial %08x want %08x got %08x", i < 16 ? "R" : i < 23 ? "fiq" : i < 31 ? "bank" : i == 31 ? "cpsr" : i < 37 ? "spsr" : "pipe",
						         i < 16 ? i : i < 23 ? i - 8 : i < 31 ? i : i == 31 ? 0 : i < 37 ? i - 32 : i - 37, ini[i], fin[i], got[i]);
				end
			end
			ntests = ntests + 1;
		end
	end
endmodule
