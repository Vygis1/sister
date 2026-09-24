`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_smb - run a real commercial game and write out what it draws.
//
// The blargg ROMs report a pass/fail byte, so they can be checked automatically.
// A game cannot. What it can do is draw, and two frames far enough apart are
// enough to answer the only question that matters here: is it still running, or
// is it sitting in a polling loop drawing the same picture forever?
//
// Frames are written as plain palette indices, one hex byte per pixel, and
// turned into PNGs outside. Keeping the conversion out of Verilog means the
// testbench has no opinion about colour.
//////////////////////////////////////////////////////////////////////////////////

module tb_game;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	wire ce = 1'b1;

	wire [17:0] prg_addr;
	wire [16:0] chr_addr;
	reg  [7:0]  prg_din, chr_din;
	reg  [7:0]  joy1 = 8'h00;
	// Which cartridge chip, how it mirrors and how big it is: written by
	// tools/nes2hex.py alongside the ROM image, so one testbench runs any game.
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
		.joy1(joy1), .joy2(8'h00),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.frame_start(frame_start),
		.dbg_pc(dbg_pc), .dbg_sync(dbg_sync), .dbg_nmi()
	);

	// Sized for the biggest cartridge the console accepts, not for the ROM under
	// test: the mapper hands out ROM-wide addresses.
	reg [7:0] prg [0:262143];
	reg [7:0] chr [0:131071];
	always @* prg_din = prg[prg_addr];
	always @* chr_din = chr[chr_addr];

	// --- capture --------------------------------------------------------------
	reg [7:0] fb [0:256*240-1];
	integer   i, frames = 0, fh, cfg, tmp;

	always @(posedge clk) begin
		if (pixel_en && px >= 9'd1 && px <= 9'd256 && py < 9'd240)
			fb[py * 256 + (px - 9'd1)] <= {2'b00, color};
	end

	task dump;
		input integer n;
		begin
			if (n == 1)      fh = $fopen("../../build/game_a.txt", "w");
			else if (n == 2) fh = $fopen("../../build/game_b.txt", "w");
			else             fh = $fopen("../../build/game_c.txt", "w");
			for (i = 0; i < 256*240; i = i + 1) begin
				$fwrite(fh, "%02x", fb[i]);
				if (i % 256 == 255) $fwrite(fh, "\n");
			end
			$fclose(fh);
			$display("  frame %0d captured", frames);
		end
	endtask

	// --- is the CPU going anywhere? --------------------------------------------
	// A histogram would be overkill; the low and high water marks of the PC over
	// a window say whether the CPU is ranging over the ROM or stuck in a handful
	// of bytes, which is the distinction being tested.
	reg [15:0] pc_lo = 16'hFFFF, pc_hi = 16'h0000;
	always @(posedge clk) begin
		if (!rst && dbg_sync) begin
			if (dbg_pc < pc_lo) pc_lo <= dbg_pc;
			if (dbg_pc > pc_hi) pc_hi <= dbg_pc;
		end
	end

	// What the game actually put in OAM, and what it asked the PPU to show. If
	// sprite 0 is not where the game thinks it is, no amount of correct sprite
	// rendering will produce the hit it is waiting for.
	task oamdump;
		begin
			$display("    nmi=%b spr16=%b bgtbl=%b sprtbl=%b | bg=%b spr=%b bgL=%b sprL=%b | OAMADDR=%02X",
			         dut.u_ppu.ctrl_nmi, dut.u_ppu.ctrl_spr_16,
			         dut.u_ppu.ctrl_bg_tbl, dut.u_ppu.ctrl_spr_tbl,
			         dut.u_ppu.mask_bg, dut.u_ppu.mask_spr,
			         dut.u_ppu.mask_bg_left, dut.u_ppu.mask_spr_left,
			         dut.u_ppu.oam_addr);
			$display("    OAM[0..3] = %02X %02X %02X %02X   (Y tile attr X)",
			         dut.u_ppu.oam[0], dut.u_ppu.oam[1],
			         dut.u_ppu.oam[2], dut.u_ppu.oam[3]);
			$display("    OAM[4..15]= %02X %02X %02X %02X  %02X %02X %02X %02X  %02X %02X %02X %02X",
			         dut.u_ppu.oam[4], dut.u_ppu.oam[5], dut.u_ppu.oam[6], dut.u_ppu.oam[7],
			         dut.u_ppu.oam[8], dut.u_ppu.oam[9], dut.u_ppu.oam[10], dut.u_ppu.oam[11],
			         dut.u_ppu.oam[12], dut.u_ppu.oam[13], dut.u_ppu.oam[14], dut.u_ppu.oam[15]);
		end
	endtask

	// A game that is running should be driving the sound chip too. Measuring the
	// swing over a window answers "is anything coming out" without needing an
	// opinion about what the music should sound like.
	// Unsigned, centred on 0x8000 -- the same convention the ring buffer uses.
	// Copied into an integer first: comparing an unsigned wire against a signed
	// integer makes the comparison unsigned, and the running maximum would never
	// move off its initial value.
	integer a_lo = 99999, a_hi = -1, a_moved = 0, a_v;
	always @(posedge clk) begin
		if (!rst) begin
			a_v = dut.audio;
			if (a_v < a_lo) a_lo <= a_v;
			if (a_v > a_hi) a_hi <= a_v;
			if (dut.audio != 16'h8000) a_moved <= a_moved + 1;
		end
	end

	task audioreport;
		begin
			$display("    audio: %0d..%0d (swing %0d, centre 32768), %0d samples off centre",
			         a_lo, a_hi, a_hi - a_lo, a_moved);
			$display("    channels enabled: p1=%b p2=%b tri=%b noi=%b dmc=%b",
			         dut.u_apu.pul_en[0], dut.u_apu.pul_en[1],
			         dut.u_apu.tri_en, dut.u_apu.noi_en,
			         dut.u_apu.dmc_left != 12'd0);
			a_lo = 99999; a_hi = -1; a_moved = 0;
		end
	endtask

	// Sprite 0 hit is an AND of four things. Counting each one separately says
	// which of them is the one that never happens, instead of leaving "no hit"
	// as a single undifferentiated symptom.
	integer n_zero = 0, n_zero_show = 0, n_zero_bg = 0, n_hit = 0;
	reg [8:0] hit_x, hit_y;
	reg [8:0] z_x, z_y;
	reg       z_seen = 0;

	always @(posedge clk) begin
		if (!rst && dut.u_ppu.pixel_en) begin
			if (dut.u_ppu.spr_zero) begin
				n_zero <= n_zero + 1;
				if (!z_seen) begin
					z_seen <= 1; z_x <= px - 9'd1; z_y <= py;
				end
				if (dut.u_ppu.spr_show) begin
					n_zero_show <= n_zero_show + 1;
					if (dut.u_ppu.bg_show) n_zero_bg <= n_zero_bg + 1;
				end
			end
			if (dut.u_ppu.spr0_hit) begin
				n_hit <= n_hit + 1;
				hit_x <= px - 9'd1; hit_y <= py;
			end
		end
	end

	task hitreport;
		begin
			$display("    sprite0 pixels=%0d  opaque=%0d  over opaque bg=%0d  hits=%0d",
			         n_zero, n_zero_show, n_zero_bg, n_hit);
			if (z_seen) $display("    first sprite-0 pixel at x=%0d y=%0d", z_x, z_y);
			if (n_hit)  $display("    first hit at x=%0d y=%0d", hit_x, hit_y);
			$display("    $2002 sprite0 flag now = %b", dut.u_ppu.stat_spr0);
		end
	endtask

	// The status bar lives in the top four tile rows of nametable 0. Sprite 0
	// sits on it, so what is written there decides whether a hit is possible.
	task ntdump;
		integer row, col;
		begin
			$display("    nametable rows 0..3 (tile indices):");
			for (row = 0; row < 4; row = row + 1) begin
				$write("      row %0d:", row);
				for (col = 0; col < 32; col = col + 1)
					$write(" %02x", dut.vram_nt[row*32 + col]);
				$display("");
			end
		end
	endtask

	// MMC3's counter is meant to fire once at a chosen scanline. Logging the line
	// it actually fires on is the only way to tell a counter that is off by a
	// line from one that is counting something else entirely.
	integer irqs = 0;
	reg     irq_q = 0;
	reg [8:0] irq_lines [0:15];
	integer   irq_n = 0, ii;

	always @(posedge clk) begin
		if (!rst) begin
			irq_q <= dut.cart_irq;
			if (dut.cart_irq && !irq_q) begin
				irqs <= irqs + 1;
				if (irq_n < 16) begin
					irq_lines[irq_n] <= py;
					irq_n <= irq_n + 1;
				end
			end
		end
	end

	// Separate the two ways the counter can stall: no edges reaching it at all,
	// or edges arriving and being rejected by the filter.
	integer raw_rise = 0, filt_rise = 0, cycles = 0;
	reg raw_q = 0;
	always @(posedge clk) begin
		if (!rst && dut.u_mapper.ppu_cycle) begin
			cycles <= cycles + 1;
			raw_q  <= dut.vram_addr[12];
			if (dut.vram_addr[12] && !raw_q) raw_rise <= raw_rise + 1;
		end
		if (!rst && dut.u_mapper.a12_rise) filt_rise <= filt_rise + 1;
	end

	integer hit_zero = 0, hit_zero_en = 0, reloads = 0, decs = 0;
	always @(posedge clk) begin
		if (!rst && dut.u_mapper.a12_rise) begin
			if (dut.u_mapper.reload) reloads <= reloads + 1;
			else                     decs    <= decs + 1;
			if (dut.u_mapper.next_cnt == 8'd0) begin
				hit_zero <= hit_zero + 1;
				if (dut.u_mapper.irq_enable) hit_zero_en <= hit_zero_en + 1;
			end
		end
	end

	task irqreport;
		begin
			$display("    mapper IRQs so far: %0d   latch=%0d enable=%0b counter=%0d",
			         irqs, dut.u_mapper.irq_latch, dut.u_mapper.irq_enable,
			         dut.u_mapper.irq_counter);
			$display("    bg_tbl=%b spr_tbl=%b  bg=%b spr=%b  a12_low=%0d a12=%b",
			         dut.u_ppu.ctrl_bg_tbl, dut.u_ppu.ctrl_spr_tbl,
			         dut.u_ppu.mask_bg, dut.u_ppu.mask_spr,
			         dut.u_mapper.a12_low, dut.u_mapper.a12_q);
			$display("    PPU bus cycles=%0d  A12 rises raw=%0d filtered=%0d",
			         cycles, raw_rise, filt_rise);
			$display("    counter: %0d reloads, %0d decrements, reached zero %0d times (%0d with IRQ enabled)",
			         reloads, decs, hit_zero, hit_zero_en);
			$write("    first fired on scanlines:");
			for (ii = 0; ii < irq_n; ii = ii + 1) $write(" %0d", irq_lines[ii]);
			$display("");
		end
	endtask

	task span;
		input [255:0] label;
		begin
			$display("  %0s: PC ranged 0x%04X..0x%04X over %0d bytes",
			         label, pc_lo, pc_hi, pc_hi - pc_lo);
			pc_lo = 16'hFFFF; pc_hi = 16'h0000;
		end
	endtask

	task wait_frames;
		input integer n;
		integer c;
		begin
			c = 0;
			while (c < n) begin
				@(posedge clk);
				if (frame_start) begin c = c + 1; frames = frames + 1; end
			end
		end
	endtask

	initial begin
		for (i = 0; i < 262144; i = i + 1) prg[i] = 8'h00;
		for (i = 0; i < 131072; i = i + 1) chr[i] = 8'h00;
		for (i = 0; i < 256*240; i = i + 1) fb[i] = 8'h00;
		$readmemh("../../sim/roms/test_prg.hex", prg);
		$readmemh("../../sim/roms/test_chr.hex", chr);

		mirror_v = 1'b0; mapper_id = 4'd0; prg_last = 6'd3;
		cfg = $fopen("../../sim/roms/test_cfg.txt", "r");
		if (cfg) begin
			tmp = $fscanf(cfg, "%d", mirror_v);
			tmp = $fscanf(cfg, "%d", mapper_id);
			tmp = $fscanf(cfg, "%d", prg_last);
			$fclose(cfg);
		end
		$display("  mapper %0d, %0s mirroring, %0d 8K PRG banks",
		         mapper_id, mirror_v ? "vertical" : "horizontal", prg_last + 1);

		$display("tb_game");
		repeat (8) @(posedge clk);
		rst = 0;

		wait_frames(180);
		span("boot");
		irqreport;
		dump(1);

		// Start, then Start again: a game that only needs one press ignores the
		// second, and one with a title and a map screen needs both.
		joy1 = 8'h08; wait_frames(8); joy1 = 8'h00;
		wait_frames(140);
		joy1 = 8'h08; wait_frames(8); joy1 = 8'h00;
		wait_frames(140);
		span("in the level");
		audioreport;
		irqreport;
		oamdump;
		dump(2);

		joy1 = 8'h80;                                 // hold Right
		wait_frames(90);
		span("holding right");
		audioreport;
		irqreport;
		hitreport;
		dump(3);

		$display("tb_game: ran %0d frames", frames);
		$finish;
	end

	// Counted in clocks, not as a `#` delay: a delay literal is 32 bits by
	// default, and the number of nanoseconds in 200 frames does not fit.
	initial begin
		repeat (200_000_000) @(posedge clk);
		$display("tb_game: FAIL timeout");
		$finish;
	end

endmodule
