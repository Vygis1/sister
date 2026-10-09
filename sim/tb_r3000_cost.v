//////////////////////////////////////////////////////////////////////////////////
// tb_r3000_cost - the CPU pace model's console cycles for ps1-tests' own timing loops
// (tools/ps1/costloops.py), against the console's: access-time RAM reads 5.21/5.30/5.14 a read,
// chain-looping's volatile g += i 16.04 an iteration. Prints the model's ctime between markers.
//   python tools/ps1/costloops.py sim/roms/mips/costloops.hex; ./tools/sim.sh tb_r3000_cost
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps

module tb_r3000_cost;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One enable in three: a CPU that only works with memory answering every
	// cycle works in exactly one testbench.
	wire ce = 1'b1;

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
		.clk(clk), .rst(rst), .ce(ce), .wq_off(1'b0), .dbg_cost(),
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
	wire        fetch_hit  = overlap && fa_rom;
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

	// markers: a store to 0x1F00 of k notes the model's console time
	reg [15:0] mk [0:7]; integer m;
	always @(posedge clk) if (ce && req && we && addr[28:0] == 29'h1F00 && dout < 8) begin
		mk[dout] = dut.ctime; $display("  marker %0d  ctime %0d", dout, dut.ctime);
	end
	integer cyc;
	initial begin
		for (k = 0; k < 65536; k = k + 1) rom[k] = 32'd0;
		for (k = 0; k < 262144; k = k + 1) ram[k] = 32'd0;
		rom[0] = 32'h3C01_8001; rom[1] = 32'h0020_0008; rom[2] = 32'd0;   // lui at,8001h; jr at; nop
		$readmemh("../../sim/roms/mips/costloops.hex", ram, 32'h4000);
		repeat (6) @(posedge clk); rst = 0;
		for (cyc = 0; cyc < 400000 && !(dut.PC == 32'h80010000 + 4*44); cyc = cyc + 1) @(posedge clk);
		repeat (200) @(posedge clk);
		$display("  nop loop      : %0d cycles / 100", (mk[2] - mk[1]) & 16'hFFFF);
		$display("  lbu loop      : %0d cycles / 100  -> %0d.%02d a read (console 5.21)", (mk[3] - mk[2]) & 16'hFFFF,
		         (((mk[3] - mk[2]) & 16'hFFFF) - ((mk[2] - mk[1]) & 16'hFFFF)) / 100, (((mk[3] - mk[2]) & 16'hFFFF) - ((mk[2] - mk[1]) & 16'hFFFF)) % 100);
		$display("  lw loop       : %0d cycles / 100  -> %0d.%02d a read (console 5.14)", (mk[4] - mk[3]) & 16'hFFFF,
		         (((mk[4] - mk[3]) & 16'hFFFF) - ((mk[2] - mk[1]) & 16'hFFFF)) / 100, (((mk[4] - mk[3]) & 16'hFFFF) - ((mk[2] - mk[1]) & 16'hFFFF)) % 100);
		$display("  g += i        : %0d cycles / 1000 (console 16040)", (mk[6] - mk[5]) & 16'hFFFF);
		$display("tb_r3000_cost: done");
		$finish;
	end
endmodule

`default_nettype wire
