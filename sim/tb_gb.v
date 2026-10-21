`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_gb - a whole Game Boy running a cartridge.
//
// The CPU has its own bench against half a million single-step tests; this is
// where it meets the rest of the machine. The cartridge comes from
// sim/roms/gb/*.hex (tools/gb/gbhex.py), through a ROM model that answers after
// a few clocks like a cache would -- or after a random number of them, to prove
// the stall does what it should.
//
// Two kinds of cartridge are run:
//
//   blargg's tests print through the serial port. Every byte written to SB is
//   printed here, and "Passed" or "Failed" in the text ends the run and is the
//   verdict.
//
//   dmg-acid2 draws a face. The frame is kept as the PPU outputs it and, after
//   FRAMES frames, written to frame.ppm and compared pixel for pixel with the
//   reference (REF, made by tools/gb/gbframe.py from the repo's PNG). Any
//   difference is a failure.
//
//   ./tools/sim.sh tb_gb ROM../../sim/roms/gb/06.hex
//   ./tools/sim.sh tb_gb ROM../../sim/roms/gb/acid2.hex FRAMES12 REF../../sim/roms/gb/acid2_ref.hex
//   ./tools/sim.sh tb_gb ROM../../sim/roms/gb/cgb_acid2.hex FRAMES12 REF15../../sim/roms/gb/cgb_acid2_ref.hex
//                                            (cgb-acid2: a Color game; the frame compared in colour)
//   ./tools/sim.sh tb_gb ROM... LAT9           ROM answers 9 clocks late (default 2)
//   ./tools/sim.sh tb_gb ROM... LATRND1        ...or a random 1..24
//   ./tools/sim.sh tb_gb ROM... MAXCLK60000000
//
// No "=" in the plusargs: the .bat wrappers split arguments on it.
//
// The top runs with CLK_HZ = 4194304, one T-cycle per clock, so a frame is 70224
// clocks and a second of the game is 4.2 M -- xsim does a few million a minute.
//////////////////////////////////////////////////////////////////////////////////

// sim/tb_gb_50.v includes this file with these two defined, to run the same
// checks at the board's 50 MHz: twelve clocks to a dot and the phase accumulator
// live, which is the case a one-clock-per-dot bench cannot see.
`ifndef GB_TB_NAME
`define GB_TB_NAME tb_gb
`define GB_TB_CLK  4194304
`endif

module `GB_TB_NAME;

	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;

	wire [22:0] rom_addr;
	wire        rom_req;
	reg         rom_ack = 0;
	reg  [7:0]  rom_data = 8'hFF;
	wire [7:0]  px_x, px_y;
	wire [1:0]  px_shade;
	wire [14:0] px_rgb;
	wire        cgb_mode;
	wire        pixel_en, frame_start;
	wire signed [15:0] audio_l, audio_r;
	wire [7:0]  sio_data;
	wire        sio_start;
	wire [15:0] dbg_pc;
	wire        dbg_halted;
	wire [31:0] sav_word;
	wire        cram_dirty;
	reg  [7:0]  joy = 8'h00;

	gb_top #(.CLK_HZ(`GB_TB_CLK)) dut (
		.clk(clk), .rst(rst), .pause(1'b0),
		.rom_addr(rom_addr), .rom_req(rom_req), .rom_ack(rom_ack), .rom_data(rom_data),
		.joy(joy),
		.px_x(px_x), .px_y(px_y), .px_shade(px_shade), .px_rgb(px_rgb), .cgb_mode(cgb_mode),
		.pixel_en(pixel_en), .frame_start(frame_start),
		.audio_l(audio_l), .audio_r(audio_r),
		.h_ptr(16'd0), .h_load(1'b0), .h_wr(1'b0), .h_wdata(32'd0), .h_word(sav_word), .cram_dirty(cram_dirty), .dirty_clr(1'b0),
		.sio_data(sio_data), .sio_start(sio_start),
		.dbg_pc(dbg_pc), .dbg_halted(dbg_halted)
	);

	// --- the cartridge: up to 1 MB, answering `lat` clocks after a request -------------------
	reg [7:0] rom [0:1048575];
	integer lat = 2, latrnd = 0, cnt = -1;
	reg [22:0] pend_a;
	always @(posedge clk) begin
		rom_ack <= 1'b0;
		if (rom_req && lat == 0 && !latrnd) begin
			// the fastest a cache could be: the byte on the next clock
			rom_ack <= 1'b1; rom_data <= rom[rom_addr[19:0]];
		end else if (rom_req) begin
			pend_a <= rom_addr;
			cnt <= latrnd ? 1 + ($urandom % 24) : lat;
		end else if (cnt > 0) begin
			cnt <= cnt - 1;
			if (cnt == 1) begin rom_ack <= 1'b1; rom_data <= rom[pend_a[19:0]]; end
		end
	end

	// --- the picture --------------------------------------------------------------------------
	reg [1:0]  frame [0:160*144-1];
	reg [1:0]  ref   [0:160*144-1];
	reg [14:0] frame15 [0:160*144-1];        // the Color's picture, BBBBBGGGGGRRRRR
	reg [14:0] ref15   [0:160*144-1];
	integer frames = 0, want_frames = 0, i, fh, mism, maxclk, clocks = 0;
	reg [1023:0] romfile, reffile;
	reg have_ref = 0, have_ref15 = 0;
	always @(posedge clk) begin
		if (pixel_en) begin frame[px_y * 160 + px_x] <= px_shade; frame15[px_y * 160 + px_x] <= px_rgb; end
		if (frame_start) frames <= frames + 1;
		clocks <= clocks + 1;
	end

	// --- the serial port ----------------------------------------------------------------------
	reg [47:0] last6 = 48'd0;
	reg passed = 0, failed = 0;
	always @(posedge clk) begin
		if (sio_start) begin
			$write("%c", sio_data);
			$fflush;
			last6 <= {last6[39:0], sio_data};
		end
	end
	always @(posedge clk) begin
		if (last6 == "Passed") passed <= 1;
		if (last6 == "Failed") failed <= 1;
	end

	// --- a look inside one line's drawing (DBGLINE<n>) ------------------------------------------
	integer dbgline = -1, dbgframe = -1;
	always @(posedge clk) begin
		if (dut.u_ppu.line == dbgline && (dbgframe < 0 || frames == dbgframe) && dut.ce) begin
			if (dut.u_ppu.dot == 9'd80) begin
				$display("  line %0d: %0d objects:", dbgline, dut.u_ppu.sp_n);
				for (i = 0; i < 10; i = i + 1) if (i < dut.u_ppu.sp_n)
					$display("    [%0d] oam %0d x=%0d y=%0d", i, dut.u_ppu.sp_idx[i], dut.u_ppu.sp_x[i], dut.u_ppu.sp_y[i]);
				$display("    lcdc=%02x scx=%0d scy=%0d wx=%0d wy=%0d wy_hit=%b wline=%0d bgp=%02x obp0=%02x obp1=%02x",
				         dut.u_ppu.lcdc, dut.u_ppu.scx, dut.u_ppu.scy, dut.u_ppu.wx, dut.u_ppu.wy, dut.u_ppu.wy_hit, dut.u_ppu.wline,
				         dut.u_ppu.bgp, dut.u_ppu.obp0, dut.u_ppu.obp1);
			end
			if (dut.u_ppu.obj_start)
				$display("    dot %0d lx=%0d: object [%0d] starts, bg_cnt=%0d fifo=%012x", dut.u_ppu.dot, dut.u_ppu.lx, dut.u_ppu.sp_match_k, dut.u_ppu.bg_cnt, dut.u_ppu.bg_fifo[47:0]);
			if (dut.u_ppu.sfetch && dut.u_ppu.sstep == 3'd5)
				$display("    dot %0d: object [%0d] tile=%02x attr=%02x row=%0d lo=%02x hi=%02x cut=%0d ob_fifo %024x -> %024x",
				         dut.u_ppu.dot, dut.u_ppu.sk, dut.u_ppu.stile, dut.u_ppu.sattr, dut.u_ppu.s_row, dut.u_ppu.sdat_lo, dut.u_ppu.s_q,
				         dut.u_ppu.s_cut, dut.u_ppu.ob_fifo, dut.u_ppu.ob_merged);
			if (dut.u_ppu.win_start)
				$display("    dot %0d lx=%0d: window starts", dut.u_ppu.dot, dut.u_ppu.lx);
			if (dut.u_ppu.push)
				$display("    dot %0d lx=%0d: push tile %02x (%s) data %02x %02x ftx=%0d", dut.u_ppu.dot, dut.u_ppu.lx, dut.u_ppu.ftile,
				         dut.u_ppu.win_act ? "win" : "bg", dut.u_ppu.fdat_lo_now, dut.u_ppu.fdat_hi_now, dut.u_ppu.ftx);
			if (dut.u_ppu.pop && dut.u_ppu.discard == 0)
				$write("%0d", dut.u_ppu.shade);
			if (dut.u_ppu.mode == 2'd3 && dut.u_ppu.lx == 8'd159 && dut.u_ppu.pop) $display("");
		end
	end

	// every PPU register write, with where the raster was (REGTRACE<frame>); every I/O write
	// and read of the Color's registers (IOTRACE1), to see a Color game's start
	integer regtrace = -1, iotrace = 0;
	always @(posedge clk) begin
		if (iotrace && dut.m1 && dut.m_end && (dut.a == 16'h0100 || dut.a < 16'h0068))
			$display("    [%0d] fetch at %04x: a restart, or an interrupt vector", clocks, dut.a);
		if (iotrace && dut.rd && dut.sel_io && dut.m_end && (dut.a[7:0] >= 8'h4D || iotrace > 4) && !dut.hd_run)
			$display("    [%0d] pc %04x: FF%02x reads %02x (line %0d dot %0d lcd_on %b mode %0d)", clocks, dbg_pc, dut.a[7:0], dut.cpu_din, dut.u_ppu.line, dut.u_ppu.dot, dut.u_ppu.lcd_on, dut.u_ppu.mode);
		if (iotrace > 3 && dut.m1 && dut.m_end)
			$display("    [%0d] op at %04x: %02x  A=%02x B=%02x C=%02x DE=%02x%02x HL=%02x%02x Z=%b", clocks, dut.a, dut.cpu_din,
			         dut.u_cpu.A, dut.u_cpu.B, dut.u_cpu.C, dut.u_cpu.D, dut.u_cpu.E, dut.u_cpu.H, dut.u_cpu.L, dut.u_cpu.f_z);
		if (iotrace > 2 && dut.rd && !dut.m1 && dut.a == 16'h8103 && dut.ce)
			$display("    [%0d] 8103: t %0d vram_a %04x hd_running %b hd_hold %0d lcd_on %b mode %0d vbk %b q0 %02x din %02x", clocks, dut.tcyc, dut.vram_a, dut.hd_running, dut.hd_hold, dut.u_ppu.lcd_on, dut.u_ppu.mode, dut.u_ppu.vbk, dut.u_ppu.vram0_q_r, dut.cpu_din);
		if (iotrace > 2 && dut.rd && dut.m_end && !dut.m1 && (dut.a[15:12] == 4'h8 || dut.a[15:12] == 4'h4))
			$display("    [%0d] pc %04x: (%04x) reads %02x", clocks, dbg_pc, dut.a, dut.cpu_din);
		if (iotrace > 1 && dut.hd_run && (dut.hd_wr || dut.hd_req))
			$display("    [%0d] hdma st %0d byte %0d src %04x dst %04x req %b wr %b data %02x rom_q %02x rom_pend %b vram_we %b bank %b", clocks,
			         dut.hd_st, dut.hd_byte, dut.hd_src, dut.hd_dst, dut.hd_req, dut.hd_wr, dut.hd_data, dut.rom_q, dut.rom_pend, dut.u_ppu.vram_we, dut.u_ppu.cpu_bank);
		if (iotrace && dut.cpu_wr && dut.sel_io && (dut.a[7:0] >= 8'h40))
			$display("    [%0d] pc %04x: FF%02x <= %02x (line %0d mode %0d)", clocks, dbg_pc, dut.a[7:0], dut.cpu_dout, dut.u_ppu.line, dut.u_ppu.mode);
		if (frames == regtrace && dut.cpu_wr && dut.sel_ppu)
			$display("    line %0d dot %0d mode %0d: FF4%x <= %02x", dut.u_ppu.line, dut.u_ppu.dot, dut.u_ppu.mode, dut.a[3:0], dut.cpu_dout);
		if (frames == regtrace && dut.irq_stat)
			$display("    line %0d dot %0d mode %0d: STAT irq (lyc=%0d)", dut.u_ppu.line, dut.u_ppu.dot, dut.u_ppu.mode, dut.u_ppu.lyc);
	end

	task dump_frame;
		begin
			fh = $fopen("frame.ppm", "wb");
			$fwrite(fh, "P6\n160 144\n255\n");
			for (i = 0; i < 160 * 144; i = i + 1) begin
				// (a Color's colours as cgb-acid2's README scales them: (c << 3) | (c >> 2))
				if (cgb_mode) $fwrite(fh, "%c%c%c", {frame15[i][4:0], frame15[i][4:2]}, {frame15[i][9:5], frame15[i][9:7]}, {frame15[i][14:10], frame15[i][14:12]});
				else case (frame[i])
					2'd0: $fwrite(fh, "%c%c%c", 8'hFF, 8'hFF, 8'hFF);
					2'd1: $fwrite(fh, "%c%c%c", 8'hAA, 8'hAA, 8'hAA);
					2'd2: $fwrite(fh, "%c%c%c", 8'h55, 8'h55, 8'h55);
					default: $fwrite(fh, "%c%c%c", 8'h00, 8'h00, 8'h00);
				endcase
			end
			$fclose(fh);
			$display("  frame.ppm written after %0d frames", frames);
			// and the video memory, for tools/gb/gbrender.py to draw the same frame from
			fh = $fopen("vram.hex", "w");
			for (i = 0; i < 8192; i = i + 1) $fwrite(fh, "%02x\n", dut.u_ppu.vram0[i]);
			for (i = 0; i < 160; i = i + 1) $fwrite(fh, "%02x\n", dut.u_ppu.oam[i]);
			$fwrite(fh, "%02x\n%02x\n%02x\n%02x\n%02x\n%02x\n%02x\n%02x\n%02x\n",
			        dut.u_ppu.lcdc, dut.u_ppu.scy, dut.u_ppu.scx, dut.u_ppu.bgp, dut.u_ppu.obp0, dut.u_ppu.obp1,
			        dut.u_ppu.wy, dut.u_ppu.wx, dut.u_ppu.lyc);
			$fclose(fh);
		end
	endtask

	initial begin
		for (i = 0; i < 160 * 144; i = i + 1) frame[i] = 2'd0;
		if (!$value$plusargs("ROM%s", romfile)) romfile = "../../sim/roms/gb/test.hex";
		if (!$value$plusargs("FRAMES%d", want_frames)) want_frames = 0;
		if (!$value$plusargs("LAT%d", lat)) lat = 2;
		if (!$value$plusargs("LATRND%d", latrnd)) latrnd = 0;
		if (!$value$plusargs("MAXCLK%d", maxclk)) maxclk = 60_000_000;
		if (!$value$plusargs("DBGLINE%d", dbgline)) dbgline = -1;
		if (!$value$plusargs("DBGFRAME%d", dbgframe)) dbgframe = -1;
		if (!$value$plusargs("REGTRACE%d", regtrace)) regtrace = -1;
		if (!$value$plusargs("IOTRACE%d", iotrace)) iotrace = 0;
		if ($value$plusargs("REF15%s", reffile)) begin
			have_ref15 = 1;
			$readmemh(reffile, ref15);
		end else if ($value$plusargs("REF%s", reffile)) begin
			have_ref = 1;
			$readmemh(reffile, ref);
		end
		for (i = 0; i < 1048576; i = i + 1) rom[i] = 8'hFF;
		$readmemh(romfile, rom);

		$display("%m: %0s", romfile);
		repeat (4) @(posedge clk);
		rst = 0;

		while (!passed && !failed && (want_frames == 0 || frames < want_frames) && clocks < maxclk)
			@(posedge clk);
		@(posedge clk);

		$display("");
		$display("  %0d clocks, %0d frames, PC=%04x", clocks, frames, dbg_pc);
		dump_frame;

		if (want_frames != 0) begin
			if (frames < want_frames) $display("  FAIL only %0d of %0d frames", frames, want_frames);
			else if (have_ref) begin
				mism = 0;
				for (i = 0; i < 160 * 144; i = i + 1)
					if (frame[i] !== ref[i]) begin
						if (mism < 10) $display("  FAIL pixel (%0d,%0d): got %0d want %0d", i % 160, i / 160, frame[i], ref[i]);
						mism = mism + 1;
					end
				if (mism == 0) $display("  ok   the frame matches the reference");
				else $display("  FAIL %0d pixels differ from the reference", mism);
			end else if (have_ref15) begin
				mism = 0;
				if (!cgb_mode) $display("  FAIL the cartridge did not put the machine in Color mode");
				for (i = 0; i < 160 * 144; i = i + 1)
					if (frame15[i] !== ref15[i]) begin
						if (mism < 10) $display("  FAIL pixel (%0d,%0d): got %04x want %04x", i % 160, i / 160, frame15[i], ref15[i]);
						mism = mism + 1;
					end
				if (mism == 0 && cgb_mode) $display("  ok   the frame matches the reference");
				else $display("  FAIL %0d pixels differ from the reference", mism);
				if (!cgb_mode) mism = mism + 1;
			end
		end else begin
			if (passed) $display("  ok   the cartridge printed Passed");
			else if (failed) $display("  FAIL the cartridge printed Failed");
			else $display("  FAIL no verdict within %0d clocks (TIMEOUT)", maxclk);
		end

		if ((want_frames == 0 && passed) ||
		    (want_frames != 0 && frames >= want_frames && ((!have_ref && !have_ref15) || mism == 0)))
			$display("%m: all checks passed");
		else $display("%m: 1 FAIL(s)");
		$finish;
	end

endmodule
