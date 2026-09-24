`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_cpu6502 - run Klaus Dormann's 6502 functional test against the core.
//
// The test is a 64 KB image that exercises every documented instruction, every
// addressing mode, every flag, the page-crossing penalties, the zero-page wrap,
// the JMP indirect page bug and decimal arithmetic. It needs no host support: it
// runs entirely in memory and reports by jumping to itself.
//
// Every failure traps at a distinct address, so "where did it stop" localises the
// bug to a specific test. Reaching 0x382F means the whole suite passed.
//
// The image's own reset vector points at its self-test entry; the convention for
// running it is to start at 0x0400, so the vector is overwritten after loading.
//////////////////////////////////////////////////////////////////////////////////

module tb_cpu6502;

	localparam [15:0] ENTRY   = 16'h0400;
	// Klaus's success is `lda #$f0 / sta test_case / jmp *`. 0x382F, the highest
	// self-jump in the image, is the INTERRUPT test's trap and is not reached
	// without host interrupt support -- assuming the highest address was success
	// cost a debugging round.
	localparam [15:0] SUCCESS   = 16'h3469;
	localparam [15:0] TEST_CASE = 16'h0200;
	localparam [7:0]  DONE_MARK = 8'hF0;
	localparam integer MAX_CYCLES = 300_000_000;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	wire [15:0] addr;
	wire [7:0]  dout;
	wire        we, sync;
	reg  [7:0]  din;

	wire [7:0]  a, x, y, s, p;
	wire [15:0] pc;

	// Klaus's test exercises decimal mode, so it wants a real 6502.
	cpu6502 #(.DECIMAL(1)) dut (
		.clk(clk), .rst(rst), .ce(1'b1),
		.addr(addr), .din(din), .dout(dout), .we(we),
		.irq(1'b0), .nmi(1'b0),
		.sync(sync),
		.dbg_a(a), .dbg_x(x), .dbg_y(y), .dbg_s(s), .dbg_p(p), .dbg_pc(pc)
	);

	// --- memory --------------------------------------------------------------
	reg [7:0] mem [0:65535];
	always @* din = mem[addr];
	always @(posedge clk) if (!rst && we) mem[addr] <= dout;

	// --- trap detection ------------------------------------------------------
	// Every trap in the suite is "JMP to myself", so an opcode fetch repeating
	// at the same address means the test has stopped there.
	reg [15:0] last_fetch = 16'hFFFF;
	reg [15:0] trap_at;
	integer    same_count = 0;
	integer    cycles = 0;
	integer    instrs = 0;
	reg        trapped = 0;

	always @(posedge clk) begin
		if (!rst) begin
			cycles <= cycles + 1;
			if (sync) begin
				instrs <= instrs + 1;
				if (addr == last_fetch) same_count <= same_count + 1;
				else                    same_count <= 0;
				last_fetch <= addr;
				if (same_count >= 2 && !trapped) begin
					trapped <= 1;
					trap_at <= addr;
				end
			end
		end
	end

	// A ring buffer of the last instructions, so a trap shows the path that
	// reached it rather than just the destination.
	localparam TRACE = 48;
	reg [15:0] tr_pc [0:TRACE-1];
	reg [7:0]  tr_a  [0:TRACE-1];
	reg [7:0]  tr_x  [0:TRACE-1];
	reg [7:0]  tr_y  [0:TRACE-1];
	reg [7:0]  tr_s  [0:TRACE-1];
	reg [7:0]  tr_p  [0:TRACE-1];
	integer    tr_i = 0;

	always @(posedge clk) begin
		if (!rst && sync && !trapped) begin
			tr_pc[tr_i] <= addr;
			tr_a[tr_i]  <= a;  tr_x[tr_i] <= x;  tr_y[tr_i] <= y;
			tr_s[tr_i]  <= s;  tr_p[tr_i] <= p;
			tr_i        <= (tr_i == TRACE-1) ? 0 : tr_i + 1;
		end
	end

	task dump_trace;
		integer j, idx;
		begin
			$display("");
			$display("  last %0d instructions before the trap:", TRACE);
			$display("       PC    A  X  Y  S  P   NV-BDIZC");
			for (j = 0; j < TRACE; j = j + 1) begin
				idx = (tr_i + j) % TRACE;
				$display("       %04X  %02X %02X %02X %02X %02X  %b%b%b%b%b%b%b%b",
				         tr_pc[idx], tr_a[idx], tr_x[idx], tr_y[idx], tr_s[idx], tr_p[idx],
				         tr_p[idx][7], tr_p[idx][6], tr_p[idx][5], tr_p[idx][4],
				         tr_p[idx][3], tr_p[idx][2], tr_p[idx][1], tr_p[idx][0]);
			end
		end
	endtask

	integer k;
	initial begin
		for (k = 0; k < 65536; k = k + 1) mem[k] = 8'h00;
		$readmemh("../../sim/roms/klaus.hex", mem);

		// Start at the documented entry point rather than the image's own vector.
		mem[16'hFFFC] = ENTRY[7:0];
		mem[16'hFFFD] = ENTRY[15:8];

		$display("tb_cpu6502");
		$display("  entry 0x%04X, success trap 0x%04X", ENTRY, SUCCESS);

		repeat (4) @(posedge clk);
		rst = 0;

		// Progress, so a long run shows forward motion rather than silence.
		fork
			begin : progress
				forever begin
					repeat (2_000_000) @(posedge clk);
					if (!trapped)
						$display("  %0dM cycles, %0d instrs, PC=0x%04X",
						         cycles / 1_000_000, instrs, pc);
				end
			end
			begin : watch
				wait (trapped);
				repeat (10) @(posedge clk);
				$display("");
				if (trap_at == SUCCESS && mem[TEST_CASE] == DONE_MARK) begin
					$display("  ok   reached the success trap at 0x%04X", trap_at);
					$display("  ok   test_case = 0x%02X (opcode testing complete)", mem[TEST_CASE]);
					$display("  ok   %0d instructions, %0d cycles", instrs, cycles);
					$display("");
					$display("tb_cpu6502: all checks passed");
				end else begin
					$display("  FAIL trapped at 0x%04X (success is 0x%04X), test_case = 0x%02X",
					         trap_at, SUCCESS, mem[TEST_CASE]);
					$display("       A=%02X X=%02X Y=%02X S=%02X P=%02X", a, x, y, s, p);
					$display("       %0d instructions, %0d cycles", instrs, cycles);
					dump_trace;
					$display("");
					$display("tb_cpu6502: FAIL");
				end
				$finish;
			end
			begin : limit
				repeat (MAX_CYCLES) @(posedge clk);
				$display("");
				$display("  FAIL no trap after %0d cycles, PC=0x%04X", cycles, pc);
				$display("tb_cpu6502: FAIL");
				$finish;
			end
		join
	end

endmodule
