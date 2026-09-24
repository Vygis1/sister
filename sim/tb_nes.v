`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_nes - run a real cartridge and read the result the ROM reports.
//
// blargg's test ROMs are built to run unattended. They put a status byte at
// $6000 and usually a null-terminated message at $6004:
//
//   $80  still running
//   $81  waiting for a reset
//   else finished -- 0 means passed, anything else is the failing test number
//
// Completion is detected as "was $80, then became something else" rather than by
// requiring the $DE $B0 $61 marker at $6001: not every ROM in the family writes
// that marker, and waiting for one that never arrives looks exactly like a hang.
//
// This is what makes the whole console machine-checkable. Without it the only
// way to judge a PPU is to look at pictures and guess.
//////////////////////////////////////////////////////////////////////////////////

module tb_nes;

	localparam integer MAX_DOTS = 400_000_000;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One dot per clock: what matters is the CPU:PPU ratio inside the console,
	// not the absolute rate.
	wire ce = 1'b1;

	wire [17:0] prg_addr;
	wire [16:0] chr_addr;
	reg  [7:0]  prg_din, chr_din;
	reg         mirror_v;
	reg [3:0]   mapper_id;
	reg [5:0]   prg_last;

	wire [8:0]  px, py;
	wire        pixel_en, frame_start;
	wire [5:0]  color;
	wire [15:0] dbg_pc;
	wire        dbg_sync;

	nes dut (
		.clk(clk), .rst(rst), .ce(ce),
		.prg_addr(prg_addr), .prg_din(prg_din),
		.chr_addr(chr_addr), .chr_din(chr_din),
		.mapper_id(mapper_id), .hdr_mirror_v(mirror_v), .prg_last(prg_last),
		.chr_dout(), .chr_we(), .chr_is_ram(1'b0),
		.joy1(8'h00), .joy2(8'h00),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.frame_start(frame_start),
		.dbg_pc(dbg_pc), .dbg_sync(dbg_sync)
	);

	// Sized for the biggest cartridge the console accepts, not for the ROM under
	// test: the mapper hands out ROM-wide addresses.
	reg [7:0] prg [0:262143];
	reg [7:0] chr [0:131071];
	always @* prg_din = prg[prg_addr];
	always @* chr_din = chr[chr_addr];

	// --- result reporting ------------------------------------------------------
	function [7:0] pram;
		input integer a;
		begin pram = dut.prg_ram[a]; end
	endfunction

	// Sampled on the clock, not a continuous assignment: `pram()` reads a memory
	// array, and a wire whose expression indexes an array is not reliably
	// re-evaluated when that array is written. As a wire this never fired and the
	// hang watchdog reported a failure on a ROM that had passed.
	reg saw_running = 0;
	reg finished = 0;
	always @(posedge clk) begin
		if (!rst) begin
			if (pram(0) == 8'h80) saw_running <= 1;
			if (saw_running && pram(0) != 8'h80 && pram(0) != 8'h81) finished <= 1;
		end
	end

	integer i, frames;

	task report;
		begin
			$display("");
			$display("  status $6000 = 0x%02X after %0d frames", pram(0), frames);
			$write("  $6000..$600F:");
			for (i = 0; i < 16; i = i + 1) $write(" %02X", pram(i));
			$display("");
			$write("  message: \"");
			for (i = 4; i < 200; i = i + 1) begin
				if (pram(i) >= 8'h20 && pram(i) < 8'h7F) $write("%c", pram(i));
				else if (pram(i) == 8'h0A) $write(" / ");
			end
			$display("\"");
			$display("");
		end
	endtask

	// --- hang detection --------------------------------------------------------
	localparam TR = 48;
	reg [15:0] tr [0:TR-1];
	integer    ti = 0, same = 0, j;
	reg [15:0] last_pc = 16'hFFFF;
	reg        hung = 0;

	always @(posedge clk) begin
		if (!rst && dbg_sync) begin
			if (dbg_pc == last_pc) same <= same + 1;
			else begin
				same   <= 0;
				tr[ti] <= dbg_pc;
				ti     <= (ti == TR-1) ? 0 : ti + 1;
			end
			last_pc <= dbg_pc;
			if (same > 4000) hung <= 1;
		end
	end

	integer cfg, tmp;
	initial begin
		for (i = 0; i < 262144; i = i + 1) prg[i] = 8'h00;
		for (i = 0; i < 131072; i = i + 1) chr[i] = 8'h00;
		$readmemh("../../sim/roms/test_prg.hex", prg);
		$readmemh("../../sim/roms/test_chr.hex", chr);

		// The converter writes mirroring, mapper number and PRG size; older
		// config files have only the first, so the rest fall back to NROM.
		mirror_v = 1'b0; mapper_id = 4'd0; prg_last = 6'd3;
		cfg = $fopen("../../sim/roms/test_cfg.txt", "r");
		if (cfg) begin
			tmp = $fscanf(cfg, "%d", mirror_v);
			tmp = $fscanf(cfg, "%d", mapper_id);
			tmp = $fscanf(cfg, "%d", prg_last);
			$fclose(cfg);
		end

		$display("tb_nes");
		$display("  mirroring: %0s", mirror_v ? "vertical" : "horizontal");

		frames = 0;
		repeat (8) @(posedge clk);
		rst = 0;

		fork
			begin : watch
				wait (finished);
				repeat (20000) @(posedge clk);   // let the message finish writing
				report;
				if (pram(0) == 8'h00) $display("tb_nes: all checks passed");
				else                  $display("tb_nes: FAIL (code %0d)", pram(0));
				$finish;
			end
			begin : count
				forever begin @(posedge clk); if (frame_start) frames = frames + 1; end
			end
			begin : progress
				forever begin
					repeat (5_000_000) @(posedge clk);
					$display("  %0d frames, PC=0x%04X, $6000=0x%02X", frames, dbg_pc, pram(0));
				end
			end
			begin : hangwatch
				wait (hung);
				if (!finished) begin
					$display("");
					$display("  ROM hung at 0x%04X after %0d frames", last_pc, frames);
					report;
					$display("  recent fetch addresses:");
					for (j = 0; j < TR; j = j + 1) begin
						$write(" %04X", tr[(ti + j) % TR]);
						if (j % 12 == 11) $display("");
					end
					$display("tb_nes: FAIL (hung)");
					$finish;
				end
			end
			begin : limit
				repeat (MAX_DOTS) @(posedge clk);
				$display("  FAIL no result after %0d frames", frames);
				report;
				$display("tb_nes: FAIL");
				$finish;
			end
		join
	end

endmodule
