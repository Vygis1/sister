//////////////////////////////////////////////////////////////////////////////////
// tb_gba - the Game Boy Advance running a cartridge, the picture dumped.
//
//   ./tools/sim.sh tb_gba ROM../../build/game.hex BIOS../../build/gba_bios.hex FRAMES10
//   plusargs: ROM, BIOS (hex from tools/gba/gbahex.py), FRAMES n (stop after n frames),
//   MAXCLK n, KEYS n (pressed bits), LAT n (cartridge latency, clocks), TRACE 1 (every
//   instruction), TRACE 2 (I/O writes), FROM n (trace from clock n)
//
// Stops after FRAMES frames (or MAXCLK clocks), writes frame.ppm (240 x 160) and prints the
// processor's pc and R12 -- jsmolka's test cartridges leave the failed test's number in R12 (0:
// all passed) and sit in a loop.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_gba;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;
	// the cartridge
	reg [15:0] rom [0:8388607];            // 16 MB
	wire [24:0] rom_addr; wire rom_req; reg rom_ack = 0; reg [15:0] rom_data = 0;
	reg [24:0] rom_size = 0;
	integer lat;
	reg [3:0] rl;
	reg rom_pend = 0; reg [24:0] rom_a;
	always @(posedge clk) begin
		rom_ack <= 1'b0;
		if (rom_req) begin rom_pend <= 1'b1; rom_a <= rom_addr; rl <= 0; end     // (a one-clock request)
		else if (rom_pend) begin
			if (rl == lat) begin rom_ack <= 1'b1; rom_data <= rom[rom_a[24:1]]; rom_pend <= 1'b0; end
			else rl <= rl + 1;
		end
	end
	// the external RAM
	reg [31:0] ext [0:131071];             // EWRAM 64K words + SRAM 16K words (at 0x10000)
	wire [16:0] ext_addr; wire ext_req, ext_we; wire [3:0] ext_be; wire [31:0] ext_wdata;
	reg ext_ack = 0; reg [31:0] ext_rdata = 0;
	integer i;
	always @(posedge clk) begin
		ext_ack <= 1'b0;
		if (ext_req && !ext_ack) begin
			ext_ack <= 1'b1;
			ext_rdata <= ext[ext_addr];
			if (ext_we) for (i = 0; i < 4; i = i + 1) if (ext_be[i]) ext[ext_addr][i*8 +: 8] <= ext_wdata[i*8 +: 8];
		end
	end
	// the BIOS, loaded
	reg bios_we = 0; reg [11:0] bios_wa = 0; reg [31:0] bios_wd = 0;
	reg [31:0] biosmem [0:4095];
	// the picture
	wire px_we; wire [7:0] px_x, px_y; wire [14:0] px_rgb; wire frame_start;
	reg [14:0] frame [0:38399];
	reg [9:0] keys = 0;
	reg rtc_en = 0;                        // RTC: the cartridge clock on (2024-10-17, a Thursday, 12:34:56)
	wire signed [15:0] audio_l, audio_r;
	wire [31:0] dbg_pc;
	gba_top dut (
		.clk(clk), .rst(rst), .pause(1'b0),
		.bios_we(bios_we), .bios_wa(bios_wa), .bios_wd(bios_wd),
		.rom_addr(rom_addr), .rom_req(rom_req), .rom_ack(rom_ack), .rom_data(rom_data), .rom_size(rom_size),
		.ext_addr(ext_addr), .ext_req(ext_req), .ext_we(ext_we), .ext_be(ext_be), .ext_wdata(ext_wdata), .ext_ack(ext_ack), .ext_rdata(ext_rdata),
		.keys(keys),
		.px_we(px_we), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .frame_start(frame_start),
		.audio_l(audio_l), .audio_r(audio_r), .dbg_pc(dbg_pc), .dbg_bus(), .sram_dirty(), .sram_dirty_clr(1'b0),
		.rtc_en(rtc_en), .rtc_now(56'h24101704123456)
	);
	integer rowcnt [0:159]; integer rc;
	initial for (rc = 0; rc < 160; rc = rc + 1) rowcnt[rc] = 0;
	always @(posedge clk) if (px_we && px_x < 240 && px_y < 160) begin frame[px_y * 240 + px_x] <= px_rgb; rowcnt[px_y] = rowcnt[px_y] + 1; end

	integer frames = 0, clocks = 0, maxclk, nframes, trace, from, fd, x, y, k, fastboot, dumpevery;
	reg [3:0] rs_q = 0;
	reg [1023:0] romfile, biosfile;
	integer aud_nz = 0, aud_min = 0, aud_max = 0;
	always @(posedge clk) begin
		clocks <= clocks + 1;
		if (frame_start) frames <= frames + 1;
		if (dut.tick && audio_l != 0) aud_nz <= aud_nz + 1;
		if (dut.tick && $signed(audio_l) < aud_min) aud_min <= audio_l;
		if (dut.tick && $signed(audio_l) > aud_max) aud_max <= audio_l;
		if (trace == 1 && dut.cpu.retire && clocks >= from)
			$display("  [%0d] %08x %s%08x  r0 %08x r1 %08x r2 %08x r3 %08x r12 %08x sp %08x lr %08x cpsr %08x", clocks, dbg_pc - (dut.cpu.tbit ? 4 : 8),
				dut.cpu.tbit ? "t " : "", dut.cpu.ir, dut.cpu.R[0], dut.cpu.R[1], dut.cpu.R[2], dut.cpu.R[3], dut.cpu.R[12],
				dut.cpu.R[dut.cpu.rix(13, dut.cpu.mode)], dut.cpu.R[dut.cpu.rix(14, dut.cpu.mode)], dut.cpu.cpsr);
		if (trace == 2 && dut.setup_any && dut.r_io && dut.acc_we && clocks >= from)
			$display("  [%0d] pc %08x: io %03x <= %08x be %x", clocks, dbg_pc, dut.acc_addr[11:0], dut.acc_wdata, dut.be_w);
		if (trace == 4 && dut.c_ack && clocks >= from)
			$display("  [%0d] ack %08x size %0d din %08x mem_q %08x bios_q %08x", clocks, dut.b_addr, dut.b_size, dut.c_din, dut.mem_q, dut.bios_q);
		if (trace == 5 && dut.u_ppu.rs == 4 && dut.u_ppu.oph == 4 && dut.u_ppu.ry == 8'd40 && clocks >= from)
			$display("  [%0d] line 40 oam %0d attr %04x %04x %04x size %0dx%0d osy %0d budget %0d dispcnt %04x", clocks, dut.u_ppu.oi, dut.u_ppu.oa0, dut.u_ppu.oa1, dut.u_ppu.oa2, dut.u_ppu.ow, dut.u_ppu.oh, dut.u_ppu.osy, dut.u_ppu.obudget, dut.u_ppu.rdispcnt);
		if (trace == 6 && dut.u_ppu.rs == 6 && dut.u_ppu.oph == 3 && dut.u_ppu.ry == 8'd40 && clocks >= from)
			$display("  [%0d] line 40 oam %0d px %0d bx %0d word %04x opix %08x idx %02x tx %0d ty %0d", clocks, dut.u_ppu.oi, dut.u_ppu.oxx, dut.u_ppu.o_bx, dut.u_ppu.o_word, dut.u_ppu.opix, dut.u_ppu.o_idx, dut.u_ppu.o_tx, dut.u_ppu.o_ty);
		if (trace == 7 && dut.u_ppu.render_go && clocks >= from)
			$display("  [%0d] render_go line %0d: rs %0d rbg %0d rx %0d oi %0d c_x %0d dispcnt %04x", clocks, dut.u_ppu.line, dut.u_ppu.rs, dut.u_ppu.rbg, dut.u_ppu.rx, dut.u_ppu.oi, dut.u_ppu.c_x, dut.u_ppu.dispcnt);
		if (trace == 8 && px_we && px_y == 8'd0 && clocks >= from)
			$display("  [%0d] px row 0 x %0d rgb %04x", clocks, px_x, px_rgb);
		if (trace == 9 && dut.u_ppu.ry == 8'd0 && dut.u_ppu.rs != rs_q && clocks >= from)
			$display("  [%0d] line 0 render: rs %0d -> %0d (rx %0d c_run %0d c_v %b c_started %0d)", clocks, rs_q, dut.u_ppu.rs, dut.u_ppu.rx, dut.u_ppu.c_run, dut.u_ppu.c_v, dut.u_ppu.c_started);
		rs_q <= dut.u_ppu.rs;
		if (trace == 11 && dut.u_ppu.bgw_we && dut.u_ppu.ry == 8'd12 && dut.u_ppu.bgw_a < 12 && clocks >= from)
			$display("  [%0d] line 12 bg%0d[%0d] <= %04x (tx0 %0d ty %0d tmap %04x cnt %04x)", clocks, dut.u_ppu.bgw_n, dut.u_ppu.bgw_a, dut.u_ppu.bgw_d, dut.u_ppu.tx0, dut.u_ppu.ty, dut.u_ppu.tmap, dut.u_ppu.cnt);
		if (trace == 11 && dut.u_ppu.px_we && dut.u_ppu.px_y == 8'd12 && dut.u_ppu.px_x < 4 && clocks >= from)
			$display("  [%0d] line 12 px %0d = %04x c_bd %04x top %0d pram0[0] %04x", clocks, dut.u_ppu.px_x, dut.u_ppu.px_rgb, dut.u_ppu.c_bd, dut.u_ppu.c_top2, dut.pram0[0]);
		if (trace == 3 && dut.setup_any && clocks >= from)
			$display("  [%0d] pc %08x: %s %08x size %0d %s %08x", clocks, dbg_pc, dut.acc_we ? "W" : "R", dut.acc_addr, dut.acc_size, dut.acc_dma ? "dma" : "cpu", dut.acc_wdata);
	end

	reg [255:0] fname;
	task dump_to;
		input [255:0] name;
		begin
			fd = $fopen(name, "w");
			$fwrite(fd, "P3\n240 160\n255\n");
			for (y = 0; y < 160; y = y + 1) begin
				for (x = 0; x < 240; x = x + 1)
					$fwrite(fd, "%0d %0d %0d ", {frame[y*240+x][4:0], frame[y*240+x][4:2]}, {frame[y*240+x][9:5], frame[y*240+x][9:7]}, {frame[y*240+x][14:10], frame[y*240+x][14:12]});
				$fwrite(fd, "\n");
			end
			$fclose(fd);
		end
	endtask
	task dump;
		begin
			// the picture's state, for tools/gba/ppuref.py
			fd = $fopen("vram.hex", "w"); for (k = 0; k < 24576; k = k + 1) $fwrite(fd, "%08x\n", dut.vram[k]); $fclose(fd);
			fd = $fopen("pram.hex", "w"); for (k = 0; k < 512; k = k + 1) $fwrite(fd, "%04x\n", dut.pram0[k]); $fclose(fd);
			fd = $fopen("oam.hex", "w"); for (k = 0; k < 256; k = k + 1) $fwrite(fd, "%08x\n", dut.oam[k]); $fclose(fd);
			fd = $fopen("regs.txt", "w");
			$fwrite(fd, "dispcnt %04x\n", dut.u_ppu.dispcnt);
			for (k = 0; k < 4; k = k + 1) $fwrite(fd, "bg%0d %04x %03x %03x\n", k, dut.u_ppu.bgcnt[k], dut.u_ppu.bghofs[k], dut.u_ppu.bgvofs[k]);
			for (k = 2; k < 4; k = k + 1) $fwrite(fd, "aff%0d %04x %04x %04x %04x %07x %07x\n", k, dut.u_ppu.pa[k], dut.u_ppu.pb[k], dut.u_ppu.pc[k], dut.u_ppu.pd[k], dut.u_ppu.bgx[k], dut.u_ppu.bgy[k]);
			$fwrite(fd, "win %04x %04x %04x %04x %04x %04x\n", dut.u_ppu.win0h, dut.u_ppu.win1h, dut.u_ppu.win0v, dut.u_ppu.win1v, dut.u_ppu.winin, dut.u_ppu.winout);
			$fwrite(fd, "bld %04x %04x %04x mosaic %04x\n", dut.u_ppu.bldcnt, dut.u_ppu.bldalpha, dut.u_ppu.bldy, dut.u_ppu.mosaic);
			$fclose(fd);
			fd = $fopen("frame.ppm", "w");
			$fwrite(fd, "P3\n240 160\n255\n");
			for (y = 0; y < 160; y = y + 1) begin
				for (x = 0; x < 240; x = x + 1)
					$fwrite(fd, "%0d %0d %0d ", {frame[y*240+x][4:0], frame[y*240+x][4:2]}, {frame[y*240+x][9:5], frame[y*240+x][9:7]}, {frame[y*240+x][14:10], frame[y*240+x][14:12]});
				$fwrite(fd, "\n");
			end
			$fclose(fd);
		end
	endtask

	initial begin
		if (!$value$plusargs("ROM%s", romfile)) romfile = "../../build/gba_rom.hex";
		if (!$value$plusargs("BIOS%s", biosfile)) biosfile = "../../build/gba_bios.hex";
		if (!$value$plusargs("FRAMES%d", nframes)) nframes = 5;
		if (!$value$plusargs("MAXCLK%d", maxclk)) maxclk = 200000000;
		if (!$value$plusargs("TRACE%d", trace)) trace = 0;
		if (!$value$plusargs("FROM%d", from)) from = 0;
		if (!$value$plusargs("LAT%d", lat)) lat = 2;
		if (!$value$plusargs("DUMPEVERY%d", dumpevery)) dumpevery = 0;
		if ($value$plusargs("KEYS%d", k)) keys = k;
		fastboot = $test$plusargs("FASTBOOT");
		rtc_en = $test$plusargs("RTC");
		for (k = 0; k < 8192; k = k + 1) dut.iwram[k] = 0;
		for (k = 0; k < 24576; k = k + 1) dut.vram[k] = 0;
		for (k = 0; k < 256; k = k + 1) dut.oam[k] = 0;
		for (k = 0; k < 512; k = k + 1) begin dut.pram0[k] = 0; dut.pram1[k] = 0; end
		for (k = 0; k < 38400; k = k + 1) frame[k] = 0;
		for (k = 0; k < 131072; k = k + 1) ext[k] = (k >= 65536) ? 32'hFFFFFFFF : 32'd0;   // (the save RAM: blank flash reads 0xFF)
		$readmemh(romfile, rom);
		rom_size = 0;
		for (k = 0; k < 8388608; k = k + 1) if (rom[k] !== 16'hxxxx) rom_size = (k + 1) * 2;
		for (k = 0; k < 8388608; k = k + 1) if (rom[k] === 16'hxxxx) rom[k] = 16'h0000;
		$readmemh(biosfile, biosmem);
		$display("cartridge %0d bytes", rom_size);
		rl = 0;
		rst = 1;
		repeat (4) @(posedge clk);
		for (k = 0; k < 4096; k = k + 1) begin
			bios_we = 1; bios_wa = k; bios_wd = (biosmem[k] === 32'hxxxxxxxx) ? 32'd0 : biosmem[k];
			@(posedge clk);
		end
		bios_we = 0;
		repeat (4) @(posedge clk);
		@(negedge clk);                     // (reset released between clocks: no race with the first fetch)
		rst = 0;
		if (fastboot) begin
			// as the BIOS leaves the machine for the cartridge: system mode, the stacks set
			dut.cpu.pc = 32'h08000000; dut.cpu.cpsr = 32'h0000001F;
			dut.cpu.R[13] = 32'h03007F00; dut.cpu.R[23] = 32'h03007FE0; dut.cpu.R[27] = 32'h03007FA0;
			for (k = 0; k < 13; k = k + 1) dut.cpu.R[k] = 0;
			dut.cpu.R[14] = 32'h08000000;
		end
		while (frames < nframes && clocks < maxclk) begin
			@(posedge clk);
			if (frame_start && dumpevery != 0 && frames % dumpevery == 0) begin
				$sformat(fname, "frame_%0d.ppm", frames);
				dump_to(fname);
			end
		end
		dump;
		$display("  %0d clocks, %0d frames, pc %08x r12 %0d", clocks, frames, dbg_pc, dut.cpu.R[12]);
		$display("  bus: bs %0d addr %08x we %0d dma %0d halted %0d c_req %0d c_ack %0d cpu st %0d req %0d; dma_pend %b ctl %04x %04x %04x %04x ie %04x if %04x ime %0d",
			dut.bs, dut.b_addr, dut.b_we, dut.b_dma, dut.halted, dut.c_req, dut.c_ack, dut.cpu.st, dut.cpu.req, dut.dma_pend,
			dut.dma_ctl[0], dut.dma_ctl[1], dut.dma_ctl[2], dut.dma_ctl[3], dut.ie, dut.iflags, dut.ime);
		$display("  audio: %0d nonzero ticks, min %0d max %0d", aud_nz, aud_min, aud_max);
		begin : rows
			integer lo, hi; lo = -1; hi = -1;
			for (rc = 0; rc < 160; rc = rc + 1) if (rowcnt[rc] < 240 * (frames - 1)) begin if (lo < 0) lo = rc; hi = rc; end
			if (lo >= 0) $display("  rows drawn short of every frame: %0d..%0d (row %0d: %0d pixels of %0d)", lo, hi, lo, rowcnt[lo], 240 * frames);
		end
		$display("tb_gba: done");
		$finish;
	end
endmodule
