`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_a26_bank - the Atari 2600's cartridge bank switching, one scheme at a time.
//
// The images and the expected results come from tools/a26/bankgate.py:
//
//   python tools/a26/bankgate.py          (writes sim/roms/a2600/bank_*.hex)
//   ./tools/sim.sh tb_a26_bank
//
// Each program records the ID byte of every bank it switches to into RIOT RAM
// from $80, then writes $A5 to $9F. The expected sequences follow from the
// bank-switching documents (see bankgate.py), so a pass means the console's
// decode of the hotspots, the Super Chip / RAM Plus ports, the stack-watching FE
// scheme and the 3F register all behave as documented.
//////////////////////////////////////////////////////////////////////////////////

module tb_a26_bank;

	localparam integer MAX_CLKS_PER_CASE = 200_000;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [15:0] rom_len = 16'd4096;
	reg  [3:0]  scheme  = 4'd0;

	wire [15:0] dbg_pc;

	a26_top #(.CLK_HZ(3_579_545), .PIX_HZ(3_579_545)) dut (
		.clk(clk), .rst(rst), .pause(1'b0),
		.rom_wr(1'b0), .rom_wr_addr(15'd0), .rom_wr_data(8'd0),
		.rom_len(rom_len), .scheme(scheme),
		.joy0(8'h00), .joy1(8'h00),
		.sw_reset(1'b0), .sw_select(1'b0), .sw_color(1'b1), .sw_diff0(1'b0), .sw_diff1(1'b0),
		.paddle(4'd0),
		.pix_ce(), .px_x(), .line(), .color(), .pixel_en(),
		.frame_start(), .line_end(), .vblank(), .vsync(),
		.audio_l(), .audio_r(),
		.dbg_pc(dbg_pc), .dbg_sync(), .dbg_rdy()
	);

	integer cases, fails = 0, ncases = 0;
	integer idx, size, sch, cnt, i, k, r, e, clks;
	reg [8*8-1:0]   name;
	reg [8*64-1:0]  fname;
	integer exp [0:63];
	integer case_fails;

	initial begin
		$display("tb_a26_bank");
		cases = $fopen("../../sim/roms/a2600/bank_cases.txt", "r");
		if (cases == 0) begin
			$display("  FAIL no sim/roms/a2600/bank_cases.txt -- run python tools/a26/bankgate.py");
			$display("tb_a26_bank: FAIL");
			$finish;
		end
		while (!$feof(cases)) begin
			r = $fscanf(cases, "%d %d %d %s %d", idx, size, sch, name, cnt);
			if (r == 5) begin
				for (i = 0; i < cnt; i = i + 1) r = $fscanf(cases, "%d", exp[i]);

				// a fresh console with this cartridge in it
				rst = 1;
				for (k = 0; k < 32768; k = k + 1) dut.rom[k] = 8'h00;
				for (k = 0; k < 256; k = k + 1)   dut.cram[k] = 8'h00;
				for (k = 0; k < 128; k = k + 1)   dut.u_riot.ram[k] = 8'h00;
				$sformat(fname, "../../sim/roms/a2600/bank_%0d.hex", idx);
				$readmemh(fname, dut.rom);
				rom_len = size;
				scheme  = sch;
				repeat (8) @(posedge clk);
				rst = 0;

				clks = 0;
				while (dut.u_riot.ram[7'h1F] != 8'hA5 && clks < MAX_CLKS_PER_CASE) begin
					@(posedge clk);
					clks = clks + 1;
				end

				case_fails = 0;
				if (dut.u_riot.ram[7'h1F] != 8'hA5) begin
					$display("  FAIL %0s: never finished (PC 0x%04X)", name, dbg_pc);
					case_fails = case_fails + 1;
				end else begin
					for (i = 0; i < cnt; i = i + 1)
						if (dut.u_riot.ram[i] !== exp[i][7:0]) begin
							$display("  FAIL %0s: $%02X = 0x%02X, want 0x%02X", name, 8'h80 + i,
							         dut.u_riot.ram[i], exp[i][7:0]);
							case_fails = case_fails + 1;
						end
				end
				$write("  %-5s %5d bytes, scheme %2d: ", name, size, sch);
				for (i = 0; i < cnt && i < 8; i = i + 1) $write("%02X ", dut.u_riot.ram[i]);
				$display("%0s", case_fails ? "-- FAIL" : "ok");
				fails  = fails + case_fails;
				ncases = ncases + 1;
			end
		end
		$fclose(cases);

		if (ncases == 0) begin
			$display("  FAIL no cases read");
			fails = fails + 1;
		end
		if (fails == 0) $display("tb_a26_bank: all checks passed");
		else            $display("tb_a26_bank: %0d FAIL(s)", fails);
		$finish;
	end

endmodule
