`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_nestest - run nestest.nes and log every instruction for comparison against
// the published reference log.
//
// Klaus's test proved the CPU against a flat 64 KB. This proves it against the
// NES memory map: RAM mirrored four times across $0000-$1FFF, a 16 KB PRG ROM
// appearing at both $8000 and $C000, and everything else reading back as open
// bus. Those mirrors are exactly where an address decode goes wrong.
//
// nestest has an automated entry at $C000 that needs no PPU. The reference log
// records A, X, Y, P and SP before every instruction, so a divergence pins the
// failure to one instruction rather than to a region.
//////////////////////////////////////////////////////////////////////////////////

module tb_nestest;

	localparam [15:0] ENTRY = 16'hC000;
	localparam integer MAX_INSTR = 9000;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	wire [15:0] addr;
	wire [7:0]  dout;
	wire        we, sync;
	reg  [7:0]  din;
	wire [7:0]  a, x, y, s, p;
	wire [15:0] pc;

	cpu6502 dut (
		.clk(clk), .rst(rst), .ce(1'b1),
		.addr(addr), .din(din), .dout(dout), .we(we),
		.irq(1'b0), .nmi(1'b0), .sync(sync),
		.dbg_a(a), .dbg_x(x), .dbg_y(y), .dbg_s(s), .dbg_p(p), .dbg_pc(pc)
	);

	// --- NES memory map ------------------------------------------------------
	reg [7:0] ram [0:2047];         // $0000-$07FF, mirrored to $1FFF
	reg [7:0] prg [0:16383];        // NROM-128: mirrored at $8000 and $C000

	always @* begin
		if (addr < 16'h2000)        din = ram[addr[10:0]];
		else if (addr >= 16'h8000)  din = prg[addr[13:0]];
		else                        din = 8'h00;     // PPU/APU stubs read as 0
	end

	always @(posedge clk)
		if (!rst && we && addr < 16'h2000) ram[addr[10:0]] <= dout;

	// --- logging -------------------------------------------------------------
	integer logf, count;
	integer k;

	initial begin
		for (k = 0; k < 2048; k = k + 1)  ram[k] = 8'h00;
		$readmemh("../../sim/roms/nestest_prg.hex", prg);

		// nestest's automated entry is $C000, not the cartridge's own vector.
		prg[14'h3FFC] = ENTRY[7:0];
		prg[14'h3FFD] = ENTRY[15:8];

		logf  = $fopen("nestest_out.txt", "w");
		count = 0;

		$display("tb_nestest");
		$display("  entry 0x%04X, logging up to %0d instructions", ENTRY, MAX_INSTR);

		repeat (4) @(posedge clk);
		rst = 0;

		forever begin
			@(posedge clk);
			#1;
			if (sync) begin
				if (count >= MAX_INSTR) begin
					$fclose(logf);
					$display("  logged %0d instructions", count);
					$display("tb_nestest: done");
					$finish;
				end
				$fwrite(logf, "%04X %02X %02X %02X %02X %02X\n", addr, a, x, y, p, s);
				count = count + 1;
			end
		end
	end

	initial begin
		#20_000_000;
		$display("FAIL timeout");
		$fclose(logf);
		$finish;
	end

endmodule
