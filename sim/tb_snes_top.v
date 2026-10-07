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
	reg [16:0] sram_mask;

	wire [19:0] m_addr; wire m_req; reg m_valid = 0; reg [127:0] m_data;
	wire px_we; wire [8:0] px_x, px_y; wire [14:0] px_rgb; wire [8:0] lines; wire frame_start;
	wire [23:0] dbg_pc; wire [15:0] dbg_spc;
	reg [12:0] h_ptr = 0; reg h_load = 0, h_wr = 0, dclr = 0; reg [31:0] h_wdata = 0; wire [31:0] h_word; wire dirty;
	integer hbad;
	snes_top #(.CLK_HZ(50_000_000)) dut (.clk(clk), .rst(rst), .pause(1'b0), .rom_hi(rom_hi), .rom_mask(rom_mask), .sram_mask(sram_mask),
		.m_addr(m_addr), .m_req(m_req), .m_ready(1'b1), .m_data(m_data), .m_valid(m_valid),
		.pad1(16'h0), .pad2(16'h0), .px_we(px_we), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .lines(lines),
		.frame_start(frame_start), .audio_l(), .audio_r(), .audio_stb(),
		.h_ptr(h_ptr), .h_load(h_load), .h_wr(h_wr), .h_wdata(h_wdata), .h_word(h_word), .sram_dirty(dirty), .dirty_clr(dclr),
		.dbg_pc(dbg_pc), .dbg_spc_pc(dbg_spc));

	// the cartridge: a line a few clocks after it is asked for -- or, with a slow cartridge
	// (build/tb_snes_slow.txt holding 1), 20 to 147 clocks, as DDR3 behind other users does
	reg [19:0] pend_a; reg [7:0] pend_n; reg pend; integer slow, seed;
	always @(posedge clk) begin
		m_valid <= 1'b0;
		if (m_req && !pend) begin pend <= 1'b1; pend_a <= m_addr; pend_n <= slow ? 8'd20 + ($random(seed) & 8'h7F) : 8'd6; end
		else if (pend) begin
			if (pend_n == 0) begin
				for (k = 0; k < 8; k = k + 1)
					m_data[16*k +: 16] <= {rom[({pend_a, 4'd0} + 2*k) % romsize], rom[({pend_a, 4'd0} + 2*k + 1) % romsize]};
				m_valid <= 1'b1; pend <= 1'b0;
			end else pend_n <= pend_n - 8'd1;
		end
		if (rst) pend <= 1'b0;
	end

	// every change of the four mailbox ports, both ways, with the frame (build/snes_ports.txt):
	// tools/snes compares the sequence with the model's
	integer pf, pk; reg [7:0] p_ts [0:3], p_tc [0:3];
	initial begin pf = $fopen("../../build/snes_ports.txt", "w"); for (pk = 0; pk < 4; pk = pk + 1) begin p_ts[pk] = 0; p_tc[pk] = 0; end end
	always @(posedge clk) if (!rst)
		for (pk = 0; pk < 4; pk = pk + 1) begin
			if (dut.u_apu.to_spc[pk] !== p_ts[pk]) begin $fdisplay(pf, "%0d S%0d %02x", frames, pk, dut.u_apu.to_spc[pk]); p_ts[pk] = dut.u_apu.to_spc[pk]; end
			if (dut.u_apu.to_cpu[pk] !== p_tc[pk]) begin $fdisplay(pf, "%0d C%0d %02x", frames, pk, dut.u_apu.to_cpu[pk]); p_tc[pk] = dut.u_apu.to_cpu[pk]; end
		end
	// the sound CPU's instructions between two frames (build/tb_snes_spclog.txt: "FROM TO"),
	// one line each as it starts: its address, opcode, A X Y SP PSW (build/snes_spc.txt)
	integer sf, s_from, s_to; reg [4:0] s_pt;
	initial begin
		s_from = -1; s_to = -1;
		sf = $fopen("../../build/tb_snes_spclog.txt", "r");
		if (sf != 0) begin r = $fscanf(sf, "%d %d", s_from, s_to); $fclose(sf); end
		sf = $fopen("../../build/snes_spc.txt", "w");
	end
	always @(posedge clk) begin
		s_pt <= dut.u_apu.u_spc.t;
		if (frames >= s_from && frames < s_to && dut.u_apu.u_spc.t == 5'd1 && s_pt != 5'd1)
			$fdisplay(sf, "%04x %02x %02x %02x %02x %02x %02x", dut.u_apu.u_spc.PC - 16'd1, dut.u_apu.u_spc.ir,
			          dut.u_apu.u_spc.A, dut.u_apu.u_spc.X, dut.u_apu.u_spc.Y, dut.u_apu.u_spc.SP, dut.u_apu.u_spc.PSW);
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
		slow = 0; seed = 7;
		fd = $fopen("../../build/tb_snes_slow.txt", "r");
		if (fd != 0) begin r = $fscanf(fd, "%d", slow); $fclose(fd); end
		if (slow) $display("  a slow cartridge: 20-147 clocks a line");
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
		// the save RAM's size from the header, as the loader takes it (1 << n kB, 8 kB at most)
		k = rom[(rom_hi ? 32'hFFC0 : 32'h7FC0) + 24];
		sram_mask = (k == 0) ? 17'd0 : (17'd1 << ((k + 10) > 13 ? 13 : (k + 10))) - 17'd1;
		// the memories as block RAM comes up on the board: zeros (not the simulator's x)
		for (k = 0; k < 131072; k = k + 1) dut.wram[k] = 8'h00;
		for (k = 0; k < 8192; k = k + 1) dut.sram[k] = 8'h00;
		for (k = 0; k < 32768; k = k + 1) dut.u_ppu.vram[k] = 16'h0000;
		for (k = 0; k < 65536; k = k + 1) dut.u_apu.aram[k] = 8'h00;
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
