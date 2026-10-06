// tb_snes_top.v - the whole SNES (rtl/wip/snes_top.v) running a ROM: the cartridge served as
// DDR3 lines (cart_ddr3's byte-swapped words), the picture it hands out caught into a frame,
// written out after N frames for tools/snes/rtlframe.py to compare with the model's.
//
//   echo PATH.sfc > build/tb_snes_rom.txt; echo N > build/tb_snes_frames.txt
//   ./tools/simwip.sh tb_snes_top
`timescale 1ns/1ps
`default_nettype none
module tb_snes_top;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // (50 MHz)

	reg [7:0] rom [0:4194303];
	integer romsize, fd, k, r, frames, nframes;
	reg [8*256-1:0] romname;
	reg rom_hi;
	reg [23:0] rom_mask;

	wire [19:0] m_addr; wire m_req; reg m_valid = 0; reg [127:0] m_data;
	wire px_we; wire [8:0] px_x, px_y; wire [14:0] px_rgb; wire [8:0] lines; wire frame_start;
	wire [23:0] dbg_pc; wire [15:0] dbg_spc;
	reg [12:0] h_ptr = 0; reg h_load = 0, h_wr = 0, dclr = 0; reg [31:0] h_wdata = 0; wire [31:0] h_word; wire dirty;
	integer hbad;
	snes_top #(.CLK_HZ(50_000_000)) dut (.clk(clk), .rst(rst), .pause(1'b0), .rom_hi(rom_hi), .rom_mask(rom_mask), .sram_mask(17'h01FFF),
		.m_addr(m_addr), .m_req(m_req), .m_ready(1'b1), .m_data(m_data), .m_valid(m_valid),
		.pad1(16'h0), .pad2(16'h0), .px_we(px_we), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .lines(lines),
		.frame_start(frame_start), .audio_l(), .audio_r(), .audio_stb(),
		.h_ptr(h_ptr), .h_load(h_load), .h_wr(h_wr), .h_wdata(h_wdata), .h_word(h_word), .sram_dirty(dirty), .dirty_clr(dclr),
		.dbg_pc(dbg_pc), .dbg_spc_pc(dbg_spc));

	// the cartridge: a line a few clocks after it is asked for
	reg [19:0] pend_a; reg [3:0] pend_n; reg pend;
	always @(posedge clk) begin
		m_valid <= 1'b0;
		if (m_req && !pend) begin pend <= 1'b1; pend_a <= m_addr; pend_n <= 4'd6; end
		else if (pend) begin
			if (pend_n == 0) begin
				for (k = 0; k < 8; k = k + 1)
					m_data[16*k +: 16] <= {rom[({pend_a, 4'd0} + 2*k) % romsize], rom[({pend_a, 4'd0} + 2*k + 1) % romsize]};
				m_valid <= 1'b1; pend <= 1'b0;
			end else pend_n <= pend_n - 4'd1;
		end
		if (rst) pend <= 1'b0;
	end

	reg [14:0] fb [0:57343];
	always @(posedge clk) if (px_we && px_y < 224) fb[px_y * 256 + px_x] <= px_rgb;

	function integer score;                // a header's likelihood at off
		input integer off;
		reg [15:0] ck, cs; reg [7:0] mode;
		begin
			score = 0;
			if (off + 32 <= romsize) begin
				mode = rom[off + 21];
				ck = {rom[off + 29], rom[off + 28]}; cs = {rom[off + 31], rom[off + 30]};
				if ((ck ^ cs) == 16'hFFFF) score = score + 2;
				if (off == 32'h7FC0 && (mode & 8'hEF) == 8'h20 || off == 32'h7FC0 && (mode & 8'hEF) == 8'h30) score = score + 1;
				if (off == 32'hFFC0 && ((mode & 8'hEF) == 8'h21 || (mode & 8'hEF) == 8'h31)) score = score + 1;
			end
		end
	endfunction

	initial begin
		romname = "../../sim/roms/snes/krom/SNES-master/HelloWorld/HelloWorld.sfc";
		fd = $fopen("../../build/tb_snes_rom.txt", "r");
		if (fd != 0) begin r = $fscanf(fd, "%s", romname); $fclose(fd); end
		nframes = 30;
		fd = $fopen("../../build/tb_snes_frames.txt", "r");
		if (fd != 0) begin r = $fscanf(fd, "%d", nframes); $fclose(fd); end
		fd = $fopen(romname, "rb");
		if (fd == 0) begin $display("tb_snes_top: FAIL no ROM"); $finish; end
		romsize = $fread(rom, fd); $fclose(fd);
		rom_hi = score(32'hFFC0) > score(32'h7FC0);
		rom_mask = 24'd1; while (rom_mask < romsize) rom_mask = rom_mask << 1; rom_mask = rom_mask - 24'd1;
		$display("  rom %0d bytes, %s, mask %06x, %0d frames", romsize, rom_hi ? "HiROM" : "LoROM", rom_mask, nframes);
		for (k = 0; k < 57344; k = k + 1) fb[k] = 15'd0;
		repeat (8) @(posedge clk); rst = 0;
		frames = 0;
		while (frames < nframes) begin
			@(posedge clk);
			if (frame_start) begin
				frames = frames + 1;
				if (frames % 10 == 0) $display("  frame %0d, cpu %06x, spc %04x", frames, dbg_pc, dbg_spc);
			end
		end
		// (the frame just ended has been handed out line by line; dump it)
		fd = $fopen("../../build/snes_rtl_frame.txt", "w");
		for (k = 0; k < 57344; k = k + 1) $fdisplay(fd, "%04x", fb[k]);
		$fclose(fd);
		fd = $fopen("../../build/snes_rtl_wram.txt", "w");
		for (k = 0; k < 1024; k = k + 1) $fdisplay(fd, "%02x", dut.wram[k]);
		$fclose(fd);
		$display("tb_snes_top: %0d frames run, frame written", nframes);
		// the save RAM from outside: four words in at 0x1F00, read back, and the written flag
		// left alone by them (the ROM under test may have set it itself: cleared first)
		hbad = 0;
		@(negedge clk); dclr = 1; @(negedge clk); dclr = 0;
		for (k = 0; k < 4; k = k + 1) begin
			@(negedge clk); h_ptr = 13'h1F00 + 4 * k; h_wdata = 32'hA5000000 + k * 32'h01020304; h_wr = 1;
			@(negedge clk); h_wr = 0; repeat (8) @(negedge clk);
		end
		for (k = 0; k < 4; k = k + 1) begin
			@(negedge clk); h_ptr = 13'h1F00 + 4 * k; h_load = 1;
			@(negedge clk); h_load = 0; repeat (8) @(negedge clk);
			if (h_word !== 32'hA5000000 + k * 32'h01020304) begin hbad = hbad + 1; $display("  save word %0d: %08x", k, h_word); end
		end
		if (dut.sram[13'h1F00] !== 8'h00 || dut.sram[13'h1F03] !== 8'hA5) begin hbad = hbad + 1; $display("  save RAM bytes in the wrong order"); end
		if (dirty) begin hbad = hbad + 1; $display("  the outside's writes set the written flag"); end
		if (hbad) begin $display("tb_snes_top: FAIL the save RAM port"); $finish; end
		$display("tb_snes_top: the save RAM port reads back what it wrote");
		$display("tb_snes_top: all checks passed");
		$finish;
	end
endmodule
