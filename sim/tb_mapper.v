`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_mapper - does bank switching actually switch banks?
//
// The cartridge from tools/nes/uxtest.py walks its seven switchable banks, calling
// a routine in each that writes its own number to memory. If banking works the
// numbers 0..6 appear in order. If it does not -- if every window read comes
// from the same place -- the same number appears seven times, which is exactly
// the failure a test that only checked "does it run" would sail past.
//
// Only seven: the eighth is the fixed bank at $C000, where the vectors live.
//
// The same cartridge is built for UxROM and for MMC1, which take their bank
// number in completely different ways -- one plain write against five serial
// ones -- so running it twice exercises both protocols against one known
// answer.
//////////////////////////////////////////////////////////////////////////////////

module tb_mapper;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	wire ce = 1'b1;

	wire [17:0] prg_addr;
	wire [16:0] chr_addr;
	reg  [7:0]  prg_din, chr_din;
	wire [15:0] dbg_pc;
	reg  [3:0]  mapper_id = 4'd2;

	nes #(.PRG_AW(18), .CHR_AW(17)) dut (
		.clk(clk), .rst(rst), .ce(ce),
		.prg_addr(prg_addr), .prg_din(prg_din),
		.chr_addr(chr_addr), .chr_din(chr_din),
		.chr_dout(), .chr_we(), .chr_is_ram(1'b1),
		.mapper_id(mapper_id), .hdr_mirror_v(1'b1), .prg_last(6'd15),
		.joy1(8'h00), .joy2(8'h00),
		.audio(), .px(), .py(), .pixel_en(), .color(), .frame_start(),
		.dbg_pc(dbg_pc), .dbg_sync(), .dbg_nmi()
	);

	reg [7:0] prg [0:262143];
	reg [7:0] chr [0:131071];
	always @* prg_din = prg[prg_addr];
	always @* chr_din = chr[chr_addr];

	integer errors = 0, i, cfg, tmp;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	initial begin
		for (i = 0; i < 262144; i = i + 1) prg[i] = 8'h00;
		for (i = 0; i < 131072; i = i + 1) chr[i] = 8'h00;
		// Its own file, not the shared test_prg.hex: several benches use that one
		// and whichever ran the converter last would decide what this loaded.
		cfg = $fopen("../../sim/roms/bank_cfg.txt", "r");
		if (cfg) begin tmp = $fscanf(cfg, "%d", mapper_id); $fclose(cfg); end
		else mapper_id = 4'd2;
		if (mapper_id == 4'd1) $readmemh("../../sim/roms/mmc1_prg.hex", prg);
		else                   $readmemh("../../sim/roms/ux_prg.hex", prg);
		$display("  mapper %0d", mapper_id);

		$display("tb_mapper");
		repeat (8) @(posedge clk);
		rst = 0;

		// Long enough for the loop to walk all eight banks.
		repeat (200000) @(posedge clk);

		$display(" banking:");
		$write("    $0300..$0306:");
		for (i = 0; i < 7; i = i + 1) $write(" %02x", dut.ram[11'h300 + i]);
		$display("");

		for (i = 0; i < 7; i = i + 1)
			check(dut.ram[11'h300 + i] == i[7:0],
			      i == 0 ? "bank 0 ran from bank 0" :
			      i == 6 ? "and bank 6 from bank 6" :
			               "each bank ran its own code");

		$display("");
		if (errors == 0) $display("tb_mapper: all checks passed");
		else             $display("tb_mapper: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (2_000_000) @(posedge clk);
		$display("tb_mapper: FAIL timeout at PC=0x%04X", dbg_pc);
		$finish;
	end

endmodule
