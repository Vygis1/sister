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
module tb_gba_sys;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;
	integer frames = 0, clocks = 0, maxclk, nframes, trace, from, fd, x, y, k, fastboot, dumpevery;
	// the cartridge and the work RAM, through the console's plumbing: cart_ddr3 + cart_cache and
	// gba_ewram on a two-port mem_arb in front of a DDR3 model; the cartridge filled through the
	// loader's path
	reg [15:0] rom [0:8388607];            // 16 MB
	wire [24:0] rom_addr; wire rom_req; wire rom_ack; wire [15:0] c_word;
	wire [15:0] rom_data = {c_word[7:0], c_word[15:8]};
	reg [24:0] rom_size = 0;
	integer lat, jit;
	reg [21:0] host_windex = 0; reg host_we = 0, fill_end = 0; reg [31:0] wdata = 0;
	wire [47:0] pa_addr; wire [1:0] pa_req, pa_we, pa_ready, pa_valid; wire [255:0] pa_wdata, pa_rdata; wire [31:0] pa_wmask;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata; wire [15:0] d_wmask;
	reg d_ready = 1; reg [127:0] d_rdata = 0; reg d_valid = 0; reg d_calibrated = 0;
	mem_arb #(.PORTS(2), .AW(24)) u_arb (
		.clk(clk), .rst(rst),
		.p_addr(pa_addr), .p_req(pa_req), .p_we(pa_we), .p_wdata(pa_wdata), .p_wmask(pa_wmask),
		.p_ready(pa_ready), .p_rdata(pa_rdata), .p_valid(pa_valid),
		.m_addr(d_addr), .m_req(d_req), .m_we(d_we), .m_wdata(d_wdata), .m_wmask(d_wmask),
		.m_ready(d_ready), .m_rdata(d_rdata), .m_valid(d_valid));
	wire [19:0] h_m_addr; wire h_m_req, h_m_ready, h_m_valid; wire [127:0] h_m_data;
	cart_ddr3 #(.BASE(24'h00_0000)) u_cart (
		.clk(clk), .rst(rst),
		.host_windex(host_windex), .host_we(host_we), .wdata(wdata), .fill_end(fill_end),
		.m_addr(h_m_addr), .m_req(h_m_req), .m_ready(h_m_ready), .m_data(h_m_data), .m_valid(h_m_valid),
		.d_addr(pa_addr[23:0]), .d_req(pa_req[0]), .d_we(pa_we[0]), .d_wdata(pa_wdata[127:0]),
		.d_ready(pa_ready[0]), .d_rdata(pa_rdata[127:0]), .d_valid(pa_valid[0]), .d_calibrated(d_calibrated));
	assign pa_wmask[15:0] = 16'hFFFF;
	cart_cache #(.IDXBITS(8)) u_cc (.clk(clk), .rst(rst),
		.a_addr(rom_addr[23:1]), .a_req(rom_req), .a_data(c_word), .a_ack(rom_ack),
		.b_addr(23'd0), .b_req(1'b0), .b_data(), .b_ack(),
		.m_addr(h_m_addr), .m_req(h_m_req), .m_ready(h_m_ready), .m_data(h_m_data), .m_valid(h_m_valid),
		.dbg_hits(), .dbg_misses(), .dbg_stall(), .dbg_prefetch());
	wire [16:0] ext_addr; wire ext_req, ext_we; wire [3:0] ext_be; wire [31:0] ext_wdata;
	wire ext_ack; wire [31:0] ext_rdata;
	gba_ewram #(.BASE(24'h20_0000), .IDXBITS(9)) u_ew (
		.clk(clk), .rst(rst),
		.a_addr(ext_addr), .a_req(ext_req), .a_we(ext_we), .a_be(ext_be), .a_wdata(ext_wdata), .a_ack(ext_ack), .a_rdata(ext_rdata),
		.m_addr(pa_addr[47:24]), .m_req(pa_req[1]), .m_we(pa_we[1]), .m_wdata(pa_wdata[255:128]), .m_wmask(pa_wmask[31:16]),
		.m_ready(pa_ready[1]), .m_rdata(pa_rdata[255:128]), .m_valid(pa_valid[1]));
	// the DDR3: lines, a byte mask, reads answered in order after `lat` clocks, several in flight
	// (as the real controller's queue allows)
	reg [127:0] mem [0:(1<<21)-1];
	reg [23:0] rq_a [0:15]; integer rq_t [0:15]; reg [3:0] rq_w = 0, rq_r = 0; integer i;
	wire [20:0] fold_w = {d_addr[21], d_addr[19:0]};
	always @(posedge clk) begin
		d_valid <= 1'b0;
		// JIT n: each read up to n clocks later than LAT, and the controller busy (not ready) at random
		// as the real one is through refresh and the other ports
		if (jit > 0) d_ready <= ($urandom % 8) != 0;
		if (!rst) begin
			if (trace == 12 && d_req && d_ready && clocks >= from) $display("  [%0d] ddr3 %s line %06x", clocks, d_we ? "W" : "R", d_addr);
			if (d_req && d_ready) begin
				if (d_we) begin for (i = 0; i < 16; i = i + 1) if (d_wmask[i]) mem[fold_w][i*8 +: 8] <= d_wdata[i*8 +: 8]; end
				else begin rq_a[rq_w] <= d_addr; rq_t[rq_w] <= clocks + lat + (jit > 0 ? $urandom % jit : 0); rq_w <= rq_w + 4'd1; end
			end
			if (rq_r != rq_w && clocks >= rq_t[rq_r]) begin
				d_rdata <= mem[{rq_a[rq_r][21], rq_a[rq_r][19:0]}]; d_valid <= 1'b1; rq_r <= rq_r + 4'd1;
			end
		end
	end
	// the BIOS, loaded
	reg bios_we = 0; reg [11:0] bios_wa = 0; reg [31:0] bios_wd = 0;
	reg [31:0] biosmem [0:4095];
	// the picture
	wire px_we; wire [7:0] px_x, px_y; wire [14:0] px_rgb; wire frame_start;
	reg [14:0] frame [0:38399];
	reg [9:0] keys = 0;
	reg flash64 = 0, eeprom = 0;          // FLASH64 / EEPROM: the save type the menu would set (0x1D0 bits 28 / 27)
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
		.audio_l(audio_l), .audio_r(audio_r), .dbg_pc(dbg_pc), .dbg_bus(), .sram_dirty(), .sram_dirty_clr(1'b0), .flash64(flash64), .eeprom(eeprom), .eep_size(),
		.rtc_en(rtc_en), .rtc_now(56'h24101704123456)
	);
	integer rowcnt [0:159]; integer rc;
	initial for (rc = 0; rc < 160; rc = rc + 1) rowcnt[rc] = 0;
	always @(posedge clk) if (px_we && px_x < 240 && px_y < 160) begin frame[px_y * 240 + px_x] <= px_rgb; rowcnt[px_y] = rowcnt[px_y] + 1; end

	// checkers: every cartridge halfword and every work-RAM / save word the console is given,
	// against what it must be (the ROM array; a shadow of every write)
	reg [31:0] ewsh [0:(1<<17)-1];
	integer ci;
	initial for (ci = 0; ci < (1<<17); ci = ci + 1) ewsh[ci] = (ci >= 32'h10000) ? 32'hFFFFFFFF : 32'd0;
	reg [24:0] chk_ra = 0; integer rom_bad = 0, ew_bad = 0, ew_n = 0, rom_n = 0;
	always @(posedge clk) if (!rst) begin
		if (rom_req) chk_ra <= rom_addr;
		if (rom_ack) begin
			rom_n = rom_n + 1;
			if (rom_data !== rom[chk_ra[23:1]]) begin
				rom_bad = rom_bad + 1;
				if (rom_bad <= 20) $display("  [%0d] ROM BAD %07x: got %04x want %04x (pc %08x)", clocks, chk_ra, rom_data, rom[chk_ra[23:1]], dbg_pc);
			end
		end
		if (ext_ack) begin
			ew_n = ew_n + 1;
			if (ext_we) begin
				for (ci = 0; ci < 4; ci = ci + 1) if (ext_be[ci]) ewsh[ext_addr][ci*8 +: 8] = ext_wdata[ci*8 +: 8];
			end else if (ext_rdata !== ewsh[ext_addr]) begin
				ew_bad = ew_bad + 1;
				if (ew_bad <= 20) $display("  [%0d] EWRAM BAD word %05x: got %08x want %08x (pc %08x)", clocks, ext_addr, ext_rdata, ewsh[ext_addr], dbg_pc);
			end
		end
	end
	// RTC: each command the cartridge clock takes, and what the port read gave the game
	reg rtc_act_q = 0;
	always @(posedge clk) begin
		rtc_act_q <= dut.u_rtc.active;
		if (rtc_en && dut.u_rtc.active && !rtc_act_q) $display("  [%0d] frame %0d: rtc command %02x (control %02x)", clocks, frames, dut.u_rtc.cmd, dut.u_rtc.ctl);
	end
	reg [3:0] rs_q = 0;
	reg [1023:0] romfile, biosfile;
	integer aud_nz = 0, aud_min = 0, aud_max = 0;
	// KEYAT n: from frame n, Start pressed for 6 frames in every 90; AUDIO: the left channel,
	// a sample every 512 console cycles (32.768 kHz), 16-bit little-endian to audio.raw; a line a
	// frame of how much of it the processor spent halted (the game's spare time)
	integer keyat, afd = 0, ffd = 0, adiv = 0, halt_t = 0, tick_t = 0;
	always @(posedge clk) begin
		if (keyat > 0 && frames >= keyat) keys[3] <= ((frames - keyat) % 90) < 6;
		if (afd != 0 && dut.tick) begin
			adiv = adiv + 1;
			if (adiv == 512) begin adiv = 0; $fwrite(afd, "%c%c", audio_l[7:0], audio_l[15:8]); end
		end
		if (dut.tick) begin tick_t = tick_t + 1; if (dut.halted) halt_t = halt_t + 1; end
		// the FIFO A feed: each word in (where the DMA read it), each sample out, for tools/gba checks
		if (ffd != 0 && dut.fifo_a_we) $fwrite(ffd, "W %0d %07x %08x %x n%0d\n", clocks, dut.dma_src[1], dut.fifo_d, dut.fifo_be, dut.u_snd.fa_n);
		if (ffd != 0 && (dut.u_snd.cnt_h[10] ? dut.tm_ov[1] : dut.tm_ov[0])) $fwrite(ffd, "P %0d n%0d\n", clocks, dut.u_snd.fa_n);
		if (ffd != 0 && frame_start) $fwrite(ffd, "F %0d %0d\n", frames, clocks);
		if (frame_start) begin
			if (afd != 0) $display("  frame %0d: halted %0d%% pc %08x", frames, tick_t ? halt_t * 100 / tick_t : 0, dbg_pc);
			halt_t = 0; tick_t = 0;
		end
	end
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
		if (!$value$plusargs("LAT%d", lat)) lat = 8;
		if (!$value$plusargs("JIT%d", jit)) jit = 0;
		if (!$value$plusargs("DUMPEVERY%d", dumpevery)) dumpevery = 0;
		if ($value$plusargs("KEYS%d", k)) keys = k;
		if (!$value$plusargs("KEYAT%d", keyat)) keyat = 0;
		if ($test$plusargs("AUDIO")) afd = $fopen("audio.raw", "wb");
		if ($test$plusargs("AUDIO")) ffd = $fopen("fifo.txt", "w");
		fastboot = $test$plusargs("FASTBOOT");
		rtc_en = $test$plusargs("RTC");
		flash64 = $test$plusargs("FLASH64");
		eeprom = $test$plusargs("EEPROM");
		for (k = 0; k < 8192; k = k + 1) dut.iwram[k] = 0;
		for (k = 0; k < 24576; k = k + 1) dut.vram[k] = 0;
		for (k = 0; k < 256; k = k + 1) dut.oam[k] = 0;
		for (k = 0; k < 512; k = k + 1) begin dut.pram0[k] = 0; dut.pram1[k] = 0; end
		for (k = 0; k < 38400; k = k + 1) frame[k] = 0;
		// the DDR3 model: lines 0..0xFFFFF the cartridge (16 MB), line 0x200000+ (the work RAM, the save) folded to
		// 0x100000+ -- the save RAM at line 0x204000 starts blank (0xFF, as flash)
		for (k = 0; k < (1<<21); k = k + 1) mem[k] = (k >= 21'h104000 && k < 21'h10C000) ? {128{1'b1}} : 128'd0;
		$readmemh(romfile, rom);
		rom_size = 0;
		for (k = 0; k < 8388608; k = k + 1) if (rom[k] !== 16'hxxxx) rom_size = (k + 1) * 2;
		for (k = 0; k < 8388608; k = k + 1) if (rom[k] === 16'hxxxx) rom[k] = 16'h0000;
		$readmemh(biosfile, biosmem);
		$display("cartridge %0d bytes", rom_size);

		rst = 1;
		repeat (4) @(posedge clk);
		for (k = 0; k < 4096; k = k + 1) begin
			bios_we = 1; bios_wa = k; bios_wd = (biosmem[k] === 32'hxxxxxxxx) ? 32'd0 : biosmem[k];
			@(posedge clk);
		end
		bios_we = 0;
		repeat (4) @(posedge clk);
		// the cartridge straight into the DDR3 model, a line (eight halfwords, the first lowest) at a
		// time, as cart_ddr3 lays it out (the loader's path itself is tb_gba_cart's)
		for (k = 0; k < (rom_size + 15) / 16; k = k + 1)
			mem[k] = {rom[k*8+7], rom[k*8+6], rom[k*8+5], rom[k*8+4], rom[k*8+3], rom[k*8+2], rom[k*8+1], rom[k*8]};
		d_calibrated = 1;
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
		if (afd != 0) $fclose(afd);
		$display("  %0d clocks, %0d frames, pc %08x r12 %0d", clocks, frames, dbg_pc, dut.cpu.R[12]);
		$display("  bus: bs %0d addr %08x we %0d dma %0d halted %0d c_req %0d c_ack %0d cpu st %0d req %0d; dma_pend %b ctl %04x %04x %04x %04x ie %04x if %04x ime %0d",
			dut.bs, dut.b_addr, dut.b_we, dut.b_dma, dut.halted, dut.c_req, dut.c_ack, dut.cpu.st, dut.cpu.req, dut.dma_pend,
			dut.dma_ctl[0], dut.dma_ctl[1], dut.dma_ctl[2], dut.dma_ctl[3], dut.ie, dut.iflags, dut.ime);
		$display("  ewram: st %0d a_req %0d a_we %0d m_req %0d m_we %0d m_addr %06x | arb req %b ready %b valid %b | ddr d_req %0d d_we %0d d_ready %0d",
			u_ew.st, u_ew.a_req, u_ew.a_we, u_ew.m_req, u_ew.m_we, u_ew.m_addr, pa_req, pa_ready, pa_valid, d_req, d_we, d_ready);
		$display("  checks: %0d cartridge reads (%0d wrong), %0d work-RAM accesses (%0d wrong)", rom_n, rom_bad, ew_n, ew_bad);
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
