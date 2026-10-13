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
	wire        pixel_en, frame_start;
	wire signed [15:0] audio_l, audio_r;
	wire [7:0]  sio_data;
	wire        sio_start;
	wire [15:0] dbg_pc;
	wire        dbg_halted;
	wire [7:0]  sav_q;
	wire        cram_dirty;
	reg  [7:0]  joy = 8'h00;

	gb_top #(.CLK_HZ(`GB_TB_CLK)) dut (
		.clk(clk), .rst(rst),
		.rom_addr(rom_addr), .rom_req(rom_req), .rom_ack(rom_ack), .rom_data(rom_data),
		.joy(joy),
		.px_x(px_x), .px_y(px_y), .px_shade(px_shade), .pixel_en(pixel_en), .frame_start(frame_start),
		.audio_l(audio_l), .audio_r(audio_r),
		.sav_addr(15'd0), .sav_q(sav_q), .cram_dirty(cram_dirty), .sav_clear(1'b0),
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
	reg [1:0] frame [0:160*144-1];
	reg [1:0] ref   [0:160*144-1];
	integer frames = 0, want_frames = 0, i, fh, mism, maxclk, clocks = 0;
	reg [1023:0] romfile, reffile;
	reg have_ref = 0;
	always @(posedge clk) begin
		if (pixel_en) frame[px_y * 160 + px_x] <= px_shade;
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
				$display("    dot %0d lx=%0d: object [%0d] starts, bg_cnt=%0d fifo=%04x", dut.u_ppu.dot, dut.u_ppu.lx, dut.u_ppu.sp_match_k, dut.u_ppu.bg_cnt, dut.u_ppu.bg_fifo);
			if (dut.u_ppu.sfetch && dut.u_ppu.sstep == 3'd5)
				$display("    dot %0d: object [%0d] tile=%02x attr=%02x row=%0d lo=%02x hi=%02x cut=%0d ob_fifo %08x -> %08x",
				         dut.u_ppu.dot, dut.u_ppu.sk, dut.u_ppu.stile, dut.u_ppu.sattr, dut.u_ppu.s_row, dut.u_ppu.sdat_lo, dut.u_ppu.fv_q,
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

	// every PPU register write, with where the raster was (REGTRACE<frame>)
	integer regtrace = -1;
	always @(posedge clk) begin
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
				case (frame[i])
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
			for (i = 0; i < 8192; i = i + 1) $fwrite(fh, "%02x\n", dut.u_ppu.vram[i]);
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
		if ($value$plusargs("REF%s", reffile)) begin
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
			end
		end else begin
			if (passed) $display("  ok   the cartridge printed Passed");
			else if (failed) $display("  FAIL the cartridge printed Failed");
			else $display("  FAIL no verdict within %0d clocks (TIMEOUT)", maxclk);
		end

		if ((want_frames == 0 && passed) ||
		    (want_frames != 0 && frames >= want_frames && (!have_ref || mism == 0)))
			$display("%m: all checks passed");
		else $display("%m: 1 FAIL(s)");
		$finish;
	end

endmodule
