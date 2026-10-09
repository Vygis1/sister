//////////////////////////////////////////////////////////////////////////////////
// tb_r3000_gt2 - the CPU and the GTE through Gran Turismo 2's colour path (tools/ps1/gt2seq.py),
// with the enable dropping at random and the fetch cache missing at random: on the board a
// packet's command word now and then came out as the previous polygon's.
//
//   python tools/ps1/gt2seq.py sim/roms/mips/gt2seq.hex 3000; ./tools/sim.sh tb_r3000_gt2
// (made from tb_r3000:) the CPU against the program tools/ps1/mipstest.py generates.
//
// The program knows its own answers; this only has to run it, raise one
// interrupt when asked, and read the four result words. A failing case prints
// its number and both values, and the case number indexes straight into the
// generator's sweep.
//
//   ./tools/sim.sh tb_r3000
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_r3000_gt2;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One enable in three: a CPU that only works with memory answering every
	// cycle works in exactly one testbench.
	// a random enable: mostly on, now and then off for a while (the pace credit running out, a
	// DMA owning the bus), and a fetch cache that misses now and then
	reg [31:0] lf = 32'h1234_5678;
	reg [7:0]  gap = 0;
	reg        ce_r = 1'b1;
	always @(posedge clk) begin
		lf <= {lf[30:0], lf[31] ^ lf[21] ^ lf[1] ^ lf[0]};
		if (gap != 0) begin gap <= gap - 8'd1; ce_r <= 1'b0; end
		else if (lf[7:0] < 8'd6) begin gap <= {3'd0, lf[12:8]}; ce_r <= 1'b0; end
		else ce_r <= (lf[15:13] != 3'd0);
	end
	wire ce = ce_r;

	wire [31:0] addr, dout;
	reg  [31:0] din;
	wire [3:0]  be;
	wire        we, req;
	reg  [5:0]  irq = 6'd0;
	wire [31:0] pc, ir;
	wire        halted;

	// a real GTE behind the processor: the moves to and from it, and the
	// interlock on a running command, are the processor's business too
	wire        c2_we, c2_ctl, c2_cmd, c2_busy;
	wire [4:0]  c2_reg, c2_wreg; wire c2_wctl;
	wire [31:0] c2_wdata, c2_rdata;
	wire [24:0] c2_word;
	ps1_gte gte (
		.gte_old(4'd0),
		.clk(clk), .rst(rst),
		.we(c2_we), .ctl(c2_ctl), .reg_i(c2_reg), .wreg_i(c2_wreg), .wctl(c2_wctl), .wdata(c2_wdata), .rdata(c2_rdata),
		.cmd(c2_cmd), .word(c2_word), .busy(c2_busy),
		// the debug snapshot tied off: left open its inputs are X, `!snap_take` with them, and no
		// command ever started -- every GTE result read 0
		.snap_arm(1'b0), .snap_go(1'b0), .snap_skip(16'd0), .snap_idx(7'd0), .snap_data(), .snap_word(), .snap_state()
	);

	r3000 dut (
		.clk(clk), .rst(rst), .ce(ce), .wq_off(1'b0),
		.addr(addr), .din(din), .dout(dout), .be(be), .we(we), .req(req),
		.fetch_addr(fetch_addr), .fetch_hit(fetch_hit), .fetch_word(fetch_word),
		.fetching(), .no_overlap(!overlap),
		.irq(irq),
		.c2_we(c2_we), .c2_ctl(c2_ctl), .c2_reg(c2_reg), .c2_wreg(c2_wreg), .c2_wctl(c2_wctl), .c2_wdata(c2_wdata), .c2_rdata(c2_rdata),
		.c2_cmd(c2_cmd), .c2_word(c2_word), .c2_busy(c2_busy),
		.dbg_pc(pc), .dbg_ir(ir), .dbg_halted(halted)
	);

	// --- memory ----------------------------------------------------------------
	// The console's map, physically: RAM in the bottom 2 MB, the BIOS at
	// $1FC00000. Words, byte-enabled, answering one enable after the address.
	reg [31:0] ram [0:262143];      // 1 MB is plenty for the test
	reg [31:0] rom [0:65535];       // 256 kB of program space

	// An instruction cache that always hits, so the processor takes the path it
	// takes on the board: one instruction per clock, fetched without the bus.
	// `overlap = 0` runs the same program the long way round, which is how the
	// two are compared.
	reg         overlap = 1'b1;
	wire [31:0] fetch_addr;
	wire        fa_rom = (fetch_addr[28:22] == 7'b1111111);
	wire        fetch_hit  = overlap && fa_rom && (lf[19:17] != 3'd0);
	wire [31:0] fetch_word = rom[fetch_addr[17:2]];


	wire in_rom = (addr[28:22] == 7'b1111111);   // $1FC00000
	wire [17:0] ra = addr[19:2];
	wire [15:0] ro = addr[17:2];

	integer k;
	always @(posedge clk) if (ce) begin
		if (req && we && !in_rom) begin
			for (k = 0; k < 4; k = k + 1)
				if (be[k]) ram[ra][k*8 +: 8] <= dout[k*8 +: 8];
		end
		din <= in_rom ? rom[ro] : ram[ra];
	end

	// The interrupt case: the program stores $DEAD0001 to $2040, then waits
	// for the exception count to reach seven. Raise line 0 when we see the
	// store, drop it when the handler runs (it reads CAUSE, which we watch).
	// interrupts at random, as VBlank and the timers land on the board: anywhere in the sequence
	integer irqs = 0;
	always @(posedge clk) if (!irq[0] && lf[31:23] == 9'd0 && lf[3]) begin irq[0] <= 1'b1; irqs = irqs + 1; end
	always @(posedge clk) if (ce && dut.st == 3'd5 && dut.exc_code == 5'd0)
		irq[0] <= 1'b0;

	integer cycles;
	integer pass, failures;
	initial begin
		failures = 0;
		for (k = 0; k < 65536; k = k + 1) rom[k] = 32'd0;
		$readmemh("../../sim/roms/mips/gt2seq.hex", rom);

		// TWICE: once with the fetch cache always hitting, which is the path
		// the board takes, and once with it off so every instruction arrives
		// over the bus. They are not the same processor to test. The GTE's
		// LZCR bug was right on the fast path and wrong on the slow one --
		// `c2_reg` was driven from the word a cycle ahead, which is the next
		// instruction when fetches overlap and the last one written when they
		// do not -- so a suite that only runs one of them can pass while the
		// machine is broken.
		for (pass = 0; pass < 2; pass = pass + 1) begin
		overlap = (pass == 0);
		$display("");
		$display("  --- fetches %s ---", overlap ? "overlapped (the board's path)" : "one at a time");
		rst = 1;
		for (k = 0; k < 262144; k = k + 1) ram[k] = 32'd0;
		repeat (6) @(posedge clk);
		rst = 0;

		// Run until the program parks itself: both `done` and `halt` are a
		// jump to self, so the PC stops moving.
		begin : run
			reg [31:0] last;
			integer same;
			last = 0; same = 0;
			for (cycles = 0; cycles < 40_000_000; cycles = cycles + 1) begin
				@(posedge clk);
				if (ce) begin
					if (pc == last) same = same + 1; else same = 0;
					last = pc;
					if (same > 64) disable run;
				end
			end
		end

		$display("  first failing iteration : %0d (variant %0d)", ram[32'h1000 >> 2], ram[32'h1014 >> 2]);
		$display("  iterations run          : %0d", ram[32'h1004 >> 2]);
		$display("  interrupts raised       : %0d", irqs);
		$display("  wrong command words     : %0d", ram[32'h1010 >> 2]);
		if (ram[32'h1000 >> 2] != 0) begin
			$display("  stored   : %08h", ram[32'h1008 >> 2]);
			$display("  expected : %08h", ram[32'h100C >> 2]);
			$display("  FAIL at iteration %0d", ram[32'h1000 >> 2]);
			failures = failures + 1;
		end else if (ram[32'h1004 >> 2] == 0) begin
			$display("  stopped at PC      : %08h  ir %08h", pc, ir);
			$display("  FAIL - never reached the end (%0d cycles)", cycles);
			failures = failures + 1;
		end else
			$display("  %0d checks passed", ram[32'h1004 >> 2]);
		end
		$display("");
		if (failures == 0) $display("tb_r3000_gt2: all checks passed, both fetch paths");
		else               $display("tb_r3000_gt2: %0d FAIL(s)", failures);
		$finish;
	end
endmodule

`default_nettype wire
