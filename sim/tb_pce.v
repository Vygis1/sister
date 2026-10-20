`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_pce - a whole PC Engine running a HuCard.
//
// The card comes from sim/roms/pce/*.hex (tools/pce/pcehex.py) through a ROM model that
// answers a few clocks after a request, like the cache on the board. The picture is kept
// as the VCE puts it out and written to frame.ppm after FRAMES frames (the window's size as
// the game set it), so tools/pce/pceframe.py can turn it into a PNG to look at.
//
//   ./tools/sim.sh tb_pce ROM../../sim/roms/pce/blox.hex FRAMES60
//   ./tools/sim.sh tb_pce ROM... LAT9 MAXCLK200000000 PRESS40      (a pad button held from frame 40:
//                                                                   bit 0 I, 1 II, 2 select, 3 run)
//   ./tools/sim.sh tb_pce ROM... TRACE1                             (every I/O register write)
//
// No "=" in the plusargs: the .bat wrappers split arguments on it. The top runs at 50 MHz
// as on the board: a frame is 833,333 clocks.
//////////////////////////////////////////////////////////////////////////////////
module tb_pce;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;

	wire [19:0] rom_addr; wire rom_req; reg rom_ack = 0; reg [7:0] rom_data = 8'hFF;
	wire [8:0]  px_rgb; wire px_en; wire [9:0] px_x; wire [8:0] px_y; wire [9:0] disp_w; wire [8:0] disp_h; wire [1:0] dot_rate;
	wire        frame_start; wire signed [15:0] audio_l, audio_r; wire [15:0] dbg_pc;
	reg  [7:0]  joy1 = 8'd0;
	reg  [19:0] rom_size = 20'd0;

	pce_top #(.CLK_HZ(50_000_000)) dut (
		.clk(clk), .rst(rst), .pause(1'b0),
		.rom_addr(rom_addr), .rom_req(rom_req), .rom_ack(rom_ack), .rom_data(rom_data), .rom_size(rom_size),
		.joy1(joy1), .joy2(8'd0),
		.px_rgb(px_rgb), .px_en(px_en), .px_x(px_x), .px_y(px_y), .disp_w(disp_w), .disp_h(disp_h), .dot_rate(dot_rate),
		.frame_start(frame_start), .audio_l(audio_l), .audio_r(audio_r), .dbg_pc(dbg_pc)
	);

	// --- the card: up to 1 MB, answering `lat` clocks after a request ----------------------------
	reg [7:0] rom [0:1048575];
	integer lat = 2, cnt = -1, nbytes = 0;
	reg [19:0] pend_a;
	always @(posedge clk) begin
		rom_ack <= 1'b0;
		if (rom_req) begin pend_a <= rom_addr; cnt <= lat; end
		else if (cnt > 0) begin
			cnt <= cnt - 1;
			if (cnt == 1) begin rom_ack <= 1'b1; rom_data <= rom[pend_a]; end
		end
	end

	// --- the picture ---------------------------------------------------------------------------------
	reg [8:0] frame [0:512*256-1];
	integer frames = 0, want_frames = 0, i, fh, maxclk, clocks = 0, press = -1, trace = 0, press_bit = 0, trace_from = 0, selftest = 0;
	reg [1023:0] romfile;
	reg [8:0] fidx [0:512*256-1];            // the colour index behind each pixel: bit 8 = a sprite
	always @(posedge clk) begin
		if (px_en && px_x < 10'd512 && px_y < 9'd256) begin frame[px_y * 512 + px_x] <= px_rgb; fidx[px_y * 512 + px_x] <= dut.u_vdc.px_idx; end
		if (frame_start) frames <= frames + 1;
		clocks <= clocks + 1;
		if (press >= 0 && frames >= press) joy1 <= 8'd1 << press_bit;
	end

	// every write to the hardware page, with the time (TRACE1); every instruction (TRACE2)
	always @(posedge clk) begin
		if (trace == 8 && dut.we_pulse && (dut.c_addr == 21'h1F0007 || dut.c_addr == 21'h1F0008 || dut.c_addr == 21'h1F28AB))
			$display("  [%0d] pc %04x: zp/ram %05x <= %02x  (A %02x X %02x Y %02x)", clocks, dbg_pc, dut.c_addr, dut.c_dout, dut.u_cpu.A, dut.u_cpu.X, dut.u_cpu.Y);
		if (trace == 8 && dut.we_pulse && (dut.c_addr == 21'h1F00F0 || dut.c_addr == 21'h1F00F1))
			$display("  [%0d] pc %04x: zp %02x <= %02x", clocks, dbg_pc, dut.c_addr[7:0], dut.c_dout);
		if (trace == 8 && dut.rd_pulse && dut.sel_vdc)
			$display("  [%0d] pc %04x: VDC port %0d reads %02x (rsel %0d marr %04x vram[marr] %04x vram[marr-1] %04x)", clocks, dbg_pc, dut.c_addr[1:0], dut.c_din,
			         dut.u_vdc.rsel, dut.u_vdc.marr, dut.u_vdc.vram[dut.u_vdc.marr[14:0]], dut.u_vdc.vram[dut.u_vdc.marr[14:0] - 15'd1]);
		if (trace == 8 && dut.we_pulse && dut.sel_vdc && dut.c_addr[1:0] == 2'd3 && dut.u_vdc.rsel == 5'd1)
			$display("  [%0d] pc %04x: MARR <= %02x%02x", clocks, dbg_pc, dut.c_dout, dut.u_vdc.lo);
		if (trace == 7 && px_en && px_y == 9'd100 && px_x < 10'd6)
			$display("  [%0d] px (%0d,%0d) rgb %03x idx %03x bg_q %02x f_tile %0d f_st %0d h_on %0d v_on %0d cr %04x mwr %04x bxr %04x byr %04x", clocks, px_x, px_y, px_rgb, dut.u_vdc.px_idx, dut.u_vdc.bg_q, dut.u_vdc.f_tile, dut.u_vdc.f_st, dut.u_vdc.h_on, dut.u_vdc.v_on, dut.u_vdc.cr, dut.u_vdc.mwr, dut.u_vdc.bxr, dut.u_vdc.byr);
		if (trace > 3 && clocks >= trace_from && clocks < trace_from + 60)
			$display("  [%0d] ce %b cyc %b st %0d addr %05x rd %b | req %b pend %b ack %b rom_data %02x rom_q %02x | din %02x", clocks, dut.cpu_ce, dut.u_cpu.cyc, dut.u_cpu.st, dut.c_addr, dut.c_rd,
			         rom_req, dut.rom_pend, rom_ack, rom_data, dut.rom_q, dut.c_din);
		if (trace > 2 && dut.u_cpu.cyc)
			$display("  [%0d] st %0d left %0d blen %0d src %04x dst %04x iopr %0d addr %05x rd %b we %b din %02x penalty %b", clocks, dut.u_cpu.st, dut.u_cpu.left,
			         dut.u_cpu.blen, dut.u_cpu.bsrc, dut.u_cpu.bdst, dut.u_cpu.iopr, dut.c_addr, dut.c_rd, dut.c_we, dut.c_din, dut.u_cpu.penalty);
		if (trace > 1 && dut.u_cpu.cyc && dut.u_cpu.sync && !dut.u_cpu.penalty)
			$display("  [%0d] %04x: %02x  A=%02x X=%02x Y=%02x S=%02x P=%02x MPR=%02x %02x %02x %02x %02x %02x %02x %02x", clocks, dbg_pc, dut.c_din,
			         dut.u_cpu.A, dut.u_cpu.X, dut.u_cpu.Y, dut.u_cpu.S, dut.u_cpu.P,
			         dut.u_cpu.MPR[0], dut.u_cpu.MPR[1], dut.u_cpu.MPR[2], dut.u_cpu.MPR[3], dut.u_cpu.MPR[4], dut.u_cpu.MPR[5], dut.u_cpu.MPR[6], dut.u_cpu.MPR[7]);
		if (trace && dut.we_pulse && dut.is_io)
			$display("  [%0d] pc %04x: %05x <= %02x", clocks, dbg_pc, dut.c_addr, dut.c_dout);
		if (trace && dut.we_pulse && dut.sel_vdc && dut.c_addr[1:0] == 2'd3)
			$display("        VDC reg %02x = %02x%02x", dut.u_vdc.rsel, dut.c_dout, dut.u_vdc.lo);
	end

	// sprite activity: slices found a line, buffer writes (TRACE5 prints a summary at the end)
	integer sp_writes = 0, satb_loads = 0, sat_hits = 0;
	always @(posedge clk) begin
		if (dut.u_vdc.s_st == 9 && dut.u_vdc.s_wait == 0 && dut.u_vdc.s_pix != 0) sp_writes <= sp_writes + 1;
		if (dut.u_vdc.satb_on && dut.u_vdc.satb_i == 9'd1 && dut.u_vdc.satb_w == 2'd0) satb_loads <= satb_loads + 1;
		if (dut.u_vdc.s_st == 2 && dut.u_vdc.sp_hit) sat_hits <= sat_hits + 1;
	end
	// (TRACE6) in the last frame: the sprite pixels written for each display line, and the cells of sprite 1
	reg [8:0] sp_hist [0:255]; integer hl;
	always @(posedge clk) begin
		if (frames == want_frames - 1 && dut.u_vdc.s_st == 9 && dut.u_vdc.s_wait == 0 && dut.u_vdc.s_pix != 0 && dut.u_vdc.s_line < 9'd256)
			sp_hist[dut.u_vdc.s_line] <= sp_hist[dut.u_vdc.s_line] + 9'd1;
	end
	// (TRACE9) a word a frame on the first two sprites, and the picture every 30 frames
	reg [1023:0] fname;
	always @(posedge clk) begin
		if (trace == 9 && frame_start) begin
			$display("  frame %0d: sprite1 y %0d x %0d  sprite2 y %0d x %0d pat %04x  BAT[0] %04x  CR %04x", frames + 1,
			         dut.u_vdc.sat[4], dut.u_vdc.sat[5], dut.u_vdc.sat[8], dut.u_vdc.sat[9], dut.u_vdc.sat[10], dut.u_vdc.vram[0], dut.u_vdc.cr);
			if ((frames + 1) % 30 == 0) begin $sformat(fname, "frame_%0d.ppm", frames + 1); dump_frame_to(fname); end
		end
	end
	task dump_frame; begin dump_frame_to("frame.ppm"); end endtask
	task dump_frame_to;
		input [1023:0] name;
		integer w, h, x, y; reg [8:0] c;
		begin
			w = disp_w; h = disp_h;
			if (w > 512) w = 512; if (h > 256) h = 256;
			fh = $fopen(name, "wb");
			$fwrite(fh, "P6\n%0d %0d\n255\n", w, h);
			for (y = 0; y < h; y = y + 1) for (x = 0; x < w; x = x + 1) begin
				c = frame[y * 512 + x];
				$fwrite(fh, "%c%c%c", {c[5:3], c[5:3], c[5:4]}, {c[8:6], c[8:6], c[8:7]}, {c[2:0], c[2:0], c[2:1]});
			end
			$fclose(fh);
			if (name == "frame.ppm") begin
			// and what is sprite (green, the colour number's low bits as brightness) and what is not (grey)
			fh = $fopen("frame_sp.ppm", "wb");
			$fwrite(fh, "P6\n%0d %0d\n255\n", w, h);
			for (y = 0; y < h; y = y + 1) for (x = 0; x < w; x = x + 1) begin
				c = fidx[y * 512 + x];
				if (c[8]) $fwrite(fh, "%c%c%c", 8'd0, {4'hF, c[3:0]}, 8'd0);
				else $fwrite(fh, "%c%c%c", {4'd4, c[3:0]}, {4'd4, c[3:0]}, {4'd4, c[3:0]});
			end
			$fclose(fh);
			end
			$display("  %0s written after %0d frames: %0d x %0d, dot rate %0d", name, frames, w, h, dot_rate);
		end
	endtask

	initial begin
		for (i = 0; i < 512 * 256; i = i + 1) begin frame[i] = 9'd0; fidx[i] = 9'd0; end
		for (i = 0; i < 256; i = i + 1) sp_hist[i] = 9'd0;
		if (!$value$plusargs("ROM%s", romfile)) romfile = "../../sim/roms/pce/blox.hex";
		if (!$value$plusargs("FRAMES%d", want_frames)) want_frames = 10;
		if (!$value$plusargs("LAT%d", lat)) lat = 2;
		if (!$value$plusargs("MAXCLK%d", maxclk)) maxclk = 100_000_000;
		if (!$value$plusargs("PRESS%d", press)) press = -1;
		if (!$value$plusargs("PRESSBIT%d", press_bit)) press_bit = 3;
		if (!$value$plusargs("TRACE%d", trace)) trace = 0;
		if (!$value$plusargs("FROM%d", trace_from)) trace_from = 0;
		if (!$value$plusargs("SELFTEST%d", selftest)) selftest = 0;
		// the image, and its size from where the file stops (a card is a multiple of 8 kB); the
		// rest reads $FF. (Counting on the filled array once took a 40 kB card for a 1 MB one,
		// whose size does not fit the port -- 0 -- and the game read bank 4 out of bank 0.)
		$readmemh(romfile, rom);
		nbytes = 0;
		for (i = 0; i < 1048576; i = i + 8192) if (rom[i] !== 8'hxx) nbytes = i + 8192;
		for (i = 0; i < 1048576; i = i + 1) if (rom[i] === 8'hxx) rom[i] = 8'hFF;
		rom_size = (nbytes >= 1048576) ? 20'hFFFFF : nbytes[19:0];
		$display("%m: %0s, %0d bytes", romfile, nbytes);
		repeat (4) @(posedge clk);
		rst = 0;
		while ((want_frames == 0 || frames < want_frames) && clocks < maxclk && (selftest == 0 || dut.wram[13'h100] !== 8'hA5)) @(posedge clk);   // (FRAMES0: to MAXCLK)
		$display("  %0d clocks, %0d frames, PC=%04x", clocks, frames, dbg_pc);
		$display("  sprites: %0d table loads, %0d slices found, %0d pixels written; CR %04x", satb_loads, sat_hits, sp_writes, dut.u_vdc.cr);
		if (trace == 6) begin
			$display("    indices at y=30: x 150..185: %03x %03x %03x %03x %03x %03x %03x %03x | y=44: %03x %03x %03x %03x",
			         fidx[30*512+150], fidx[30*512+155], fidx[30*512+160], fidx[30*512+165], fidx[30*512+170], fidx[30*512+175], fidx[30*512+180], fidx[30*512+185],
			         fidx[44*512+160], fidx[44*512+165], fidx[44*512+170], fidx[44*512+200]);
			begin : vstats
				integer nff, k; nff = 0;
				for (k = 0; k < 32768; k = k + 1) if (dut.u_vdc.vram[k] == 16'hFFFF) nff = nff + 1;
				$display("    VRAM words equal to FFFF: %0d of 32768; tile $201 data: %04x %04x %04x; tile $202: %04x %04x", nff,
				         dut.u_vdc.vram[16'h2010], dut.u_vdc.vram[16'h2011], dut.u_vdc.vram[16'h2018], dut.u_vdc.vram[16'h2020], dut.u_vdc.vram[16'h2028]);
			end
			$display("    VRAM $0000..: %04x %04x %04x | BAT at well (row 5, col 42): %04x; tile data of that tile: %04x %04x", dut.u_vdc.vram[0], dut.u_vdc.vram[1], dut.u_vdc.vram[2], dut.u_vdc.vram[5*64+42], dut.u_vdc.vram[{dut.u_vdc.vram[5*64+42][10:0], 4'd0}], dut.u_vdc.vram[{dut.u_vdc.vram[5*64+42][10:0], 4'd0} + 8]);
			for (hl = 0; hl < 256; hl = hl + 1) if (sp_hist[hl] != 0) $display("    line %0d: %0d sprite pixels", hl, sp_hist[hl]);
			$display("    VRAM $6300: %04x %04x %04x %04x %04x %04x %04x %04x | $6310: %04x %04x | $6320: %04x %04x | $6330: %04x %04x", dut.u_vdc.vram[16'h6300], dut.u_vdc.vram[16'h6301], dut.u_vdc.vram[16'h6302], dut.u_vdc.vram[16'h6303], dut.u_vdc.vram[16'h6304], dut.u_vdc.vram[16'h6305], dut.u_vdc.vram[16'h6306], dut.u_vdc.vram[16'h6307], dut.u_vdc.vram[16'h6310], dut.u_vdc.vram[16'h6311], dut.u_vdc.vram[16'h6320], dut.u_vdc.vram[16'h6321], dut.u_vdc.vram[16'h6330], dut.u_vdc.vram[16'h6331]);
			$display("    VRAM $6340: %04x %04x | $6380: %04x %04x | $63C0: %04x %04x | $5C00: %04x %04x %04x %04x", dut.u_vdc.vram[16'h6340], dut.u_vdc.vram[16'h6341], dut.u_vdc.vram[16'h6380], dut.u_vdc.vram[16'h6381], dut.u_vdc.vram[16'h63C0], dut.u_vdc.vram[16'h63C1], dut.u_vdc.vram[16'h5C00], dut.u_vdc.vram[16'h5C01], dut.u_vdc.vram[16'h5C10], dut.u_vdc.vram[16'h5C20]);
		end
		for (i = 0; i < 64; i = i + 1) if (dut.u_vdc.sat[i * 4] != 16'd0)
			$display("    sprite %0d: y %0d x %0d pattern %04x attr %04x", i, dut.u_vdc.sat[i * 4], dut.u_vdc.sat[i * 4 + 1], dut.u_vdc.sat[i * 4 + 2], dut.u_vdc.sat[i * 4 + 3]);
		dump_frame;
		if (selftest) begin
			if (dut.wram[13'h100] == 8'hA5 && dut.wram[13'h101] == 8'd0) $display("  ok   the test card passed every step\n%m: all checks passed");
			else $display("  FAIL the test card stopped at step %0d (detail %02x)\n%m: 1 FAIL(s)", dut.wram[13'h101], dut.wram[13'h102]);
		end else if (frames >= want_frames || want_frames == 0) $display("%m: all checks passed");
		else $display("%m: 1 FAIL(s) -- only %0d frames", frames);
		$finish;
	end
endmodule
