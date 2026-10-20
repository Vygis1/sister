`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_gb_cpu - the SM83 against the SingleStepTests sm83 suite.
//
// Every legal opcode has a thousand tests: registers and a few bytes of RAM going
// in, registers and RAM coming out, and the bus activity of every M-cycle in
// between. All of them run in one xsim session, read from the hex stream that
// tools/gb/sm83tests.py makes out of the JSON.
//
// Each test loads the core's registers straight into the hierarchy -- there is
// no reset vector that could put arbitrary values there -- and a 64 kB flat RAM
// stands in for the whole memory map. Then the core runs exactly as many M-cycles
// as the test lists; the bus is compared cycle by cycle, and the instruction must
// be over (back at an opcode fetch) at precisely that point: a cycle early or
// late is a failure like a wrong flag is.
//
//   ./tools/sim.sh tb_gb_cpu                 everything in build/sm83tests/all.hex
//   ./tools/sim.sh tb_gb_cpu ONLY1cb         one opcode (hex id; 1xx is CB xx). No "=": the
//   ./tools/sim.sh tb_gb_cpu MAXFAIL20       .bat wrappers split arguments on it
//////////////////////////////////////////////////////////////////////////////////

module tb_gb_cpu;

	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;

	wire [15:0] addr;
	wire [7:0]  dout;
	reg  [7:0]  din;
	wire        rd, we, wr_strobe, m_end, m1;
	wire        halted, stop_p, ime, ime_pend, irq_ack;
	wire [2:0]  irq_n;
	wire [15:0] dbg_pc;

	gb_cpu dut (
		.clk(clk), .rst(rst), .ce(1'b1), .cgb(1'b0), .wake(1'b0),
		.addr(addr), .din(din), .dout(dout), .rd(rd), .we(we),
		.wr_strobe(wr_strobe), .m_end(m_end), .m1(m1),
		.irq(5'd0), .irq_ack(irq_ack), .irq_n(irq_n),
		.halted(halted), .stop(stop_p), .ime(ime), .ime_pend(ime_pend),
		.dbg_pc(dbg_pc)
	);

	// Flat RAM, answering a clock late as block RAM does.
	reg [7:0] ram [0:65535];
	always @(posedge clk) begin
		din <= ram[addr];
		if (wr_strobe) ram[addr] <= dout;
	end

	// --- the stream ---------------------------------------------------------------------
	integer fd, r;
	reg [31:0] v;
	task rd_word;
		begin
			r = $fscanf(fd, "%h", v);
		end
	endtask

	// the test being run
	integer opid;
	reg [15:0] i_pc, i_sp, f_pc, f_sp;
	reg [7:0]  i_a, i_f, i_b, i_c, i_d, i_e, i_h, i_l;
	reg [7:0]  e_a, e_f, e_b, e_c, e_d, e_e, e_h, e_l;
	integer    i_ime, e_ime, e_ei;
	integer    n_iram, n_fram, n_cyc;
	reg [15:0] iram_a [0:63];
	reg [7:0]  iram_d [0:63];
	reg [15:0] fram_a [0:63];
	reg [7:0]  fram_d [0:63];
	integer    cyc_t [0:15];
	reg [15:0] cyc_a [0:15];
	reg [7:0]  cyc_d [0:15];

	// results
	integer pass_op [0:511];
	integer fail_op [0:511];
	integer total = 0, passed = 0, failed = 0, printed = 0, maxfail = 10;
	integer only = -1;
	integer i, k, bad, got_cyc;
	reg [15:0] g_addr;
	reg [7:0]  g_data;
	integer    g_type;
	reg [1023:0] why;
	reg [7:0] got_f;

	task note;
		input [1023:0] s;
		begin
			if (bad == 0) why = s;
			bad = bad + 1;
		end
	endtask

	initial begin
		for (i = 0; i < 65536; i = i + 1) ram[i] = 8'h00;
		for (i = 0; i < 512; i = i + 1) begin pass_op[i] = 0; fail_op[i] = 0; end
		if (!$value$plusargs("MAXFAIL%d", maxfail)) maxfail = 10;
		if (!$value$plusargs("ONLY%h", only)) only = -1;

		$display("tb_gb_cpu");
		fd = $fopen("../../build/sm83tests/all.hex", "r");
		if (fd == 0) begin
			$display("  FAIL cannot open build/sm83tests/all.hex -- run tools/gb/sm83tests.py");
			$finish;
		end

		repeat (4) @(posedge clk);
		rst = 0;
		@(negedge clk);

		rd_word;
		while (r == 1) begin
			opid = v;
			// --- read the record -----------------------------------------------------------
			rd_word; i_pc = v; rd_word; i_sp = v;
			rd_word; i_a = v; rd_word; i_f = v; rd_word; i_b = v; rd_word; i_c = v;
			rd_word; i_d = v; rd_word; i_e = v; rd_word; i_h = v; rd_word; i_l = v;
			rd_word; i_ime = v;
			rd_word; n_iram = v;
			for (i = 0; i < n_iram; i = i + 1) begin
				rd_word; iram_a[i] = v; rd_word; iram_d[i] = v;
			end
			rd_word; f_pc = v; rd_word; f_sp = v;
			rd_word; e_a = v; rd_word; e_f = v; rd_word; e_b = v; rd_word; e_c = v;
			rd_word; e_d = v; rd_word; e_e = v; rd_word; e_h = v; rd_word; e_l = v;
			rd_word; e_ime = v; rd_word; e_ei = v;
			rd_word; n_fram = v;
			for (i = 0; i < n_fram; i = i + 1) begin
				rd_word; fram_a[i] = v; rd_word; fram_d[i] = v;
			end
			rd_word; n_cyc = v;
			for (i = 0; i < n_cyc; i = i + 1) begin
				rd_word; cyc_t[i] = v; rd_word; cyc_a[i] = v; rd_word; cyc_d[i] = v;
			end

			if (only < 0 || only == opid) begin
				total = total + 1;
				bad = 0;

				// --- load the core -----------------------------------------------------------
				// At a negedge, between clocks: the core is idle (nothing is in flight
				// because the previous test ended on an opcode-fetch boundary).
				for (i = 0; i < n_iram; i = i + 1) ram[iram_a[i]] = iram_d[i];
				dut.A = i_a; dut.B = i_b; dut.C = i_c; dut.D = i_d; dut.E = i_e; dut.H = i_h; dut.L = i_l;
				dut.f_z = i_f[7]; dut.f_n = i_f[6]; dut.f_h = i_f[5]; dut.f_c = i_f[4];
				dut.PC = i_pc; dut.SP = i_sp;
				dut.ime = i_ime[0]; dut.ime_pend = 1'b0;
				dut.halted = 1'b0; dut.halt_bug = 1'b0;
				dut.state = 5'd0; dut.t = 2'd0;
				dut.addr = i_pc; dut.rd = 1'b1; dut.we = 1'b0; dut.m1 = 1'b1;
				din = ram[i_pc];

				// --- run the M-cycles -------------------------------------------------------
				for (k = 0; k < n_cyc; k = k + 1) begin
					// to the last T-cycle of this M-cycle
					while (dut.t != 2'd3) @(negedge clk);
					g_addr = addr;
					g_type = rd ? 1 : we ? 2 : 0;
					g_data = rd ? din : dout;
					if (g_type != cyc_t[k])
						note("cycle type");
					else if (g_type != 0 && (g_addr != cyc_a[k] || g_data != cyc_d[k]))
						note("cycle addr/data");
					@(negedge clk);                 // the step has happened
					if (k < n_cyc - 1 && dut.state == 5'd0 && !dut.halted)
						note("instruction ended early");
				end
				if (dut.state != 5'd0 && !dut.halted) note("instruction still running");

				// --- compare ----------------------------------------------------------------
				got_f = {dut.f_z, dut.f_n, dut.f_h, dut.f_c, 4'b0000};
				if (dut.A != e_a || got_f != e_f || dut.B != e_b || dut.C != e_c ||
				    dut.D != e_d || dut.E != e_e || dut.H != e_h || dut.L != e_l)
					note("registers");
				if (dut.PC != f_pc) note("PC");
				if (dut.SP != f_sp) note("SP");
				if (dut.ime != e_ime[0]) note("IME");
				if (e_ei != 2 && dut.ime_pend != e_ei[0]) note("EI pending");
				for (i = 0; i < n_fram; i = i + 1)
					if (ram[fram_a[i]] !== fram_d[i]) note("RAM");

				if (bad == 0) begin
					passed = passed + 1; pass_op[opid] = pass_op[opid] + 1;
				end else begin
					failed = failed + 1; fail_op[opid] = fail_op[opid] + 1;
					if (printed < maxfail) begin
						printed = printed + 1;
						$display("  FAIL op %03x test %0d: %0s", opid, pass_op[opid] + fail_op[opid] - 1, why);
						$display("    in : PC=%04x SP=%04x AF=%02x%02x BC=%02x%02x DE=%02x%02x HL=%02x%02x ime=%0d",
						         i_pc, i_sp, i_a, i_f, i_b, i_c, i_d, i_e, i_h, i_l, i_ime);
						$display("    exp: PC=%04x SP=%04x AF=%02x%02x BC=%02x%02x DE=%02x%02x HL=%02x%02x ime=%0d ei=%0d",
						         f_pc, f_sp, e_a, e_f, e_b, e_c, e_d, e_e, e_h, e_l, e_ime, e_ei);
						$display("    got: PC=%04x SP=%04x AF=%02x%02x BC=%02x%02x DE=%02x%02x HL=%02x%02x ime=%0d ei=%0d state=%0d",
						         dut.PC, dut.SP, dut.A, got_f, dut.B, dut.C, dut.D, dut.E, dut.H, dut.L, dut.ime, dut.ime_pend, dut.state);
						$write("    exp bus:");
						for (i = 0; i < n_cyc; i = i + 1) $write(" %0s%04x:%02x", cyc_t[i] == 1 ? "r" : cyc_t[i] == 2 ? "w" : "-", cyc_a[i], cyc_d[i]);
						$display("");
						$write("    ram in :");
						for (i = 0; i < n_iram; i = i + 1) $write(" %04x=%02x", iram_a[i], iram_d[i]);
						$display("");
						$write("    ram exp:");
						for (i = 0; i < n_fram; i = i + 1) $write(" %04x=%02x", fram_a[i], fram_d[i]);
						$display("");
						$write("    ram got:");
						for (i = 0; i < n_fram; i = i + 1) $write(" %04x=%02x", fram_a[i], ram[fram_a[i]]);
						$display("");
					end
				end

				// --- clean up -----------------------------------------------------------------
				for (i = 0; i < n_iram; i = i + 1) ram[iram_a[i]] = 8'h00;
				for (i = 0; i < n_fram; i = i + 1) ram[fram_a[i]] = 8'h00;
				// a halted core has to be woken for the next test
				dut.halted = 1'b0;
				dut.state = 5'd0;
			end
			rd_word;
		end
		$fclose(fd);

		$display("  %0d tests, %0d passed, %0d failed", total, passed, failed);
		if (failed != 0) begin
			$display("  opcodes with failures (op: fail/total):");
			for (i = 0; i < 512; i = i + 1)
				if (fail_op[i] != 0) $display("    %03x: %0d/%0d", i, fail_op[i], fail_op[i] + pass_op[i]);
		end
		if (failed == 0 && total > 0) $display("tb_gb_cpu: all checks passed");
		else $display("tb_gb_cpu: %0d FAIL(s)", failed + (total == 0 ? 1 : 0));
		$finish;
	end

	// A bound on the whole run.
	initial begin
		#(64'd20 * 64'd200_000_000);
		$display("tb_gb_cpu: TIMEOUT");
		$finish;
	end

endmodule
