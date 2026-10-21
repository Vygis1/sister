`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_gba_save - the Game Boy Advance's save, end to end, as the menu does it (menu.h
// gbaSaveBegin / gbaSaveService).
//
// console_top built with CORE_GBA only, at 50 MHz, in front of a DDR3 model that answers reads
// in order after a latency and refuses requests (d_ready low) in random bursts of up to 60
// clocks, as the controller does through refresh and calibration. The cartridge is assembled
// here (ARM code; the bench starts the processor at 0x08000000 as the BIOS would leave it).
//
//   1  the save in: ctrl 0x1D0 bit 30, then 128 kB through the program window a word every
//      WGAP clocks (default 10: the quad link's pace); every byte must land in DDR3 at line
//      0x204000 up, whatever the stalls; the written flag (0x1DC) stays down
//   2  game A (a 128 kB flash, Sanyo's ID): reads a byte the host put in and writes it plus one
//      (plain SRAM-style writes), the flash's ID read in ID mode and programmed (AA 55 A0) into
//      the save, a sector erased (AA 55 80 AA 55 30), a byte programmed into it, bank 1 picked
//      (AA 55 B0) and a byte programmed there, bank 0 again and a plain write
//   3  the save out: the flag is up; every line read back through hr_line / hr_data (0x7C,
//      0x80-0x8C) while the game runs is the host's bytes with exactly the game's changes; a
//      write to 0x1DC takes the flag down and an idle game leaves it down
//   4  game B, reset: a chip erase (AA 55 80 AA 55 10) must blank all 128 kB (both banks) and
//      put the flag up, then two programmed bytes, one in each bank
//   5  game A again with flash64 (0x1D0 bit 28): the ID is Panasonic's 64 kB part (32h 1Bh)
//      and the bank command does nothing (bank 1's byte lands in bank 0)
//   6  an EEPROM game, 8 kB (0x1D0 bit 27), driven by DMA3 as the library does it: a write
//      command (81 bits) to block 5, the poll for ready, a read request (17 bits) for block 9 (the
//      host's bytes) and its 68 bits read into IWRAM, then block 5 read back the same way; the
//      block lands at save bytes 40-47 first bit highest, the flag goes up, 0x1DC reads 8 kB
//   7  the same with a 512 B part (73- and 9-bit commands): block 3 written, blocks 1 and 3 read
//
//   ./tools/sim.sh tb_gba_save [WGAP<n>] [LAT<n>]
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module tb_gba_save;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz
	reg pclk = 0;
	always #20 pclk = ~pclk;

	reg  [15:0] off = 16'd0;
	reg  [31:0] wdata = 32'd0;
	reg         ctrl_we = 1'b0, prog_we = 1'b0, fill_end = 1'b0;
	reg  [21:0] windex = 22'd0;
	wire [31:0] ctrl_rdata, audio_lr;
	wire        audio_lr_we;
	wire [23:0] vid_rgb;
	wire [15:0] audio;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata; wire [15:0] d_wmask;
	reg  [127:0] d_rdata = 128'd0; reg d_valid = 1'b0; reg d_ready = 1'b1;

	console_top #(.CORE_NES(0), .CORE_SMS(0), .CORE_GBA(1), .PROG_AW(12), .CHAR_AW(12), .CLK_HZ(50_000_000)) dut (
		.clk(clk), .rst(rst), .ce(1'b0),
		.off(off), .con_index(10'd0), .con_rdata(),
		.prog_windex(10'd0), .md_windex_full(windex), .md_windex(windex[15:0]), .char_windex(10'd0),
		.esp_sclk(1'b0), .esp_mosi(1'b0), .esp_miso(), .esp_cs_n(1'b1),
		.ctrl_we(ctrl_we),
		.stream_en(), .stream_port(), .stream_base(), .stream_words(), .stream_rowlen(), .stream_stride(),
		.stream_ready(), .stream_done_tog(1'b0), .stream_direct(), .stream_fdata(), .stream_fvalid(), .stream_frd(1'b0),
		.fill_end(fill_end), .prog_we(prog_we), .char_we(1'b0), .wdata(wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid), .d_calibrated(1'b1),
		.ctrl_rdata(ctrl_rdata), .prog_rdata(), .char_rdata(),
		.audio(audio), .audio_lr(audio_lr), .audio_lr_we(audio_lr_we),
		.px_valid(), .px_x(), .px_y(), .px_rgb(),
		.fbr_addr(18'd0), .fbr_req(1'b0), .fbr_rdata(), .fbr_ack(),
		.pclk(pclk), .vid_x(10'd0), .vid_y(10'd0), .vid_req(1'b0), .vid_rgb(vid_rgb)
	);

	// --- DDR3: lines folded (the cartridge's below 0x8000, the work RAM's and the save's at
	// 0x200000 up into 0x8000 up); reads in order LAT clocks on; stalls in random bursts --------
	reg [127:0] mem [0:131071];
	function [16:0] fold; input [23:0] a; fold = a[21] ? {2'b01, a[14:0]} : {2'b00, a[14:0]}; endfunction
	integer lat, stall = 0, i, k, bad, n, t, loop_pc;
	reg [7:0] pat [0:131071];
	reg [23:0] rq_a [0:15]; integer rq_t [0:15]; reg [3:0] rq_w = 0, rq_r = 0; integer clocks = 0;
	always @(posedge clk) begin
		clocks <= clocks + 1;
		d_valid <= 1'b0;
		// a stall of 1..60 clocks about every 150
		if (stall > 0) begin stall <= stall - 1; d_ready <= (stall == 1); end
		else if (($urandom % 150) == 0) begin stall <= 1 + $urandom % 60; d_ready <= 1'b0; end
		if (d_req && d_ready) begin
			if (d_we) begin for (k = 0; k < 16; k = k + 1) if (d_wmask[k]) mem[fold(d_addr)][k*8 +: 8] <= d_wdata[k*8 +: 8]; end
			else begin rq_a[rq_w] <= d_addr; rq_t[rq_w] <= clocks + lat; rq_w <= rq_w + 4'd1; end
		end
		if (rq_r != rq_w && clocks >= rq_t[rq_r]) begin
			d_rdata <= mem[fold(rq_a[rq_r])]; d_valid <= 1'b1; rq_r <= rq_r + 4'd1;
		end
	end

	// TRACE: every save-RAM access the console sets up, and each answer
	integer trace = 0;
	always @(posedge clk) if (trace) begin
		if (dut.g_gba.u_gba.setup_any && dut.g_gba.u_gba.r_sram)
			$display("  [%0d] sram %s %08x d %08x fl_st %0d fl_id %0d hs %0d", clocks, dut.g_gba.u_gba.acc_we ? "W" : "R",
				dut.g_gba.u_gba.acc_addr, dut.g_gba.u_gba.acc_wdata, dut.g_gba.u_gba.fl_st, dut.g_gba.u_gba.fl_id, dut.g_gba.u_gba.fl_handshake);
		if (dut.g_gba.u_gba.ext_ack && dut.g_gba.u_gba.l_sram)
			$display("  [%0d]   ack q %08x bs %0d b_addr %08x fl_id %0d", clocks, dut.g_gba.u_gba.ext_rdata, dut.g_gba.u_gba.bs, dut.g_gba.u_gba.b_addr, dut.g_gba.u_gba.fl_id);
	end
	integer fails = 0;
	task check;
		input cond;
		input [1023:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); fails = fails + 1; end
		end
	endtask
	task ctrl_write;
		input [15:0] a;
		input [31:0] d;
		begin
			@(posedge clk); off <= a; wdata <= d; ctrl_we <= 1'b1;
			@(posedge clk); ctrl_we <= 1'b0;
			repeat (10) @(posedge clk);
		end
	endtask
	reg [31:0] rd;
	task ctrl_read;
		input [15:0] a;
		begin
			@(posedge clk); off <= a;
			@(posedge clk); #1 rd = ctrl_rdata;
		end
	endtask
	integer wgap;
	task prog_write;
		input [21:0] idx;
		input [31:0] d;
		begin
			@(posedge clk); windex <= idx; wdata <= d; prog_we <= 1'b1;
			@(posedge clk); prog_we <= 1'b0;
			repeat (wgap - 2) @(posedge clk);
		end
	endtask

	// --- the cartridge, assembled (ARM) ----------------------------------------------------------
	reg [31:0] rom [0:4095];               // 16 kB
	integer pc;
	task w; input [31:0] v; begin rom[pc >> 2] = v; pc = pc + 4; end endtask
	task mov;  input [3:0] rd; input [7:0] imm; input [3:0] rot; begin w(32'hE3A00000 | (rd << 12) | (rot << 8) | imm); end endtask
	task orr;  input [3:0] rd; input [3:0] rn; input [7:0] imm; input [3:0] rot; begin w(32'hE3800000 | (rn << 16) | (rd << 12) | (rot << 8) | imm); end endtask
	task addi; input [3:0] rd; input [3:0] rn; input [7:0] imm; begin w(32'hE2800000 | (rn << 16) | (rd << 12) | imm); end endtask
	task strb; input [3:0] rd; input [3:0] rn; input [11:0] o; begin w(32'hE5C00000 | (rn << 16) | (rd << 12) | o); end endtask
	task ldrb; input [3:0] rd; input [3:0] rn; input [11:0] o; begin w(32'hE5D00000 | (rn << 16) | (rd << 12) | o); end endtask
	task bto;  input [31:0] t; begin w(32'hEA000000 | (((t - (pc + 8)) >> 2) & 32'h00FFFFFF)); end endtask
	task beq;  input [31:0] t; begin w(32'h0A000000 | (((t - (pc + 8)) >> 2) & 32'h00FFFFFF)); end endtask
	task str;  input [3:0] rd; input [3:0] rn; input [11:0] o; begin w(32'hE5800000 | (rn << 16) | (rd << 12) | o); end endtask
	task ldrh; input [3:0] rd; input [3:0] rn; begin w(32'hE1D000B0 | (rn << 16) | (rd << 12)); end endtask
	task tst1; input [3:0] rn; begin w(32'hE3100001 | (rn << 16)); end endtask
	// DMA3, 16-bit units, both addresses counting up, now: r1 the source, r2 the destination (r0 = 0x04000000)
	task dma3; input [7:0] count; begin
		str(1, 0, 12'h0D4); str(2, 0, 12'h0D8); mov(3, 8'h02, 1); orr(3, 3, count, 0); str(3, 0, 12'h0DC);
	end endtask
	integer poll_pc;
	task eep_poll; begin                                     // until the EEPROM reads 1 (r4 = 0x0D000000)
		poll_pc = pc; ldrh(3, 4); tst1(3); beq(poll_pc);
	end endtask
	// the EEPROM game: the bit streams are in IWRAM (put there by the bench): the write at 0x03000000,
	// the read requests at 0x03000200 and 0x03000300; the blocks read to 0x03000400 and 0x03000600
	task build_eep;
		input [7:0] wbits, rbits;
		begin
			for (pc = 0; pc < 16384; pc = pc + 4) rom[pc >> 2] = 32'h00000000;
			pc = 0; bto(32'hC0);
			pc = 32'hC0;
			mov(0, 8'h04, 4); mov(4, 8'h0D, 4);                                   // r0 = 0x04000000, r4 = 0x0D000000
			mov(1, 8'h03, 4); mov(2, 8'h0D, 4); dma3(wbits); eep_poll;            // the write; the poll
			mov(1, 8'h03, 4); orr(1, 1, 8'h02, 12); dma3(rbits);                  // read request A
			mov(1, 8'h0D, 4); mov(2, 8'h03, 4); orr(2, 2, 8'h01, 11); dma3(8'd68);   // its 68 bits to 0x03000400
			mov(1, 8'h03, 4); orr(1, 1, 8'h03, 12); mov(2, 8'h0D, 4); dma3(rbits);   // read request B
			mov(1, 8'h0D, 4); mov(2, 8'h03, 4); orr(2, 2, 8'h06, 12); dma3(8'd68);   // to 0x03000600
			loop_pc = pc; bto(pc);
		end
	endtask
	// the flash's handshake and a command: AA to 5555 (r1), 55 to 2AAA (r2), the command to 5555
	task fcmd; input [7:0] c; begin
		mov(3, 8'hAA, 0); strb(3, 1, 0); mov(3, 8'h55, 0); strb(3, 2, 0); mov(3, c, 0); strb(3, 1, 0);
	end endtask
	task prologue; begin
		for (pc = 0; pc < 16384; pc = pc + 4) rom[pc >> 2] = 32'h00000000;
		pc = 0; bto(32'hC0);                                     // over the header
		pc = 32'hC0;
		mov(0, 8'h0E, 4);                                        // r0 = 0x0E000000
		orr(1, 0, 8'h55, 12); orr(1, 1, 8'h55, 0);               // r1 = 0x0E005555
		orr(2, 0, 8'h2A, 12); orr(2, 2, 8'hAA, 0);               // r2 = 0x0E002AAA
	end endtask
	task build_a; begin
		prologue;
		ldrb(3, 0, 12'h010); addi(3, 3, 8'd1); strb(3, 0, 12'h100);          // [0x100] = [0x10] + 1
		orr(4, 0, 8'hFF, 12); orr(4, 4, 8'hFF, 0); mov(3, 8'h5A, 0); strb(3, 4, 0);   // [0xFFFF] = 5A
		fcmd(8'h90); ldrb(5, 0, 12'h000); ldrb(6, 0, 12'h001); fcmd(8'hF0);  // the ID
		fcmd(8'hA0); strb(5, 0, 12'h200);                                     // [0x200] = maker
		fcmd(8'hA0); strb(6, 0, 12'h201);                                     // [0x201] = part
		orr(7, 0, 8'h30, 12);                                                 // r7 = 0x0E003000
		fcmd(8'h80); mov(3, 8'hAA, 0); strb(3, 1, 0); mov(3, 8'h55, 0); strb(3, 2, 0);
		mov(3, 8'h30, 0); strb(3, 7, 0);                                      // sector 3 erased
		fcmd(8'hA0); mov(3, 8'h42, 0); strb(3, 7, 12'h234);                   // [0x3234] = 42
		fcmd(8'hB0); mov(3, 8'h01, 0); strb(3, 0, 0);                         // bank 1
		fcmd(8'hA0); mov(3, 8'h77, 0); strb(3, 0, 12'h020);                   // [0x10020] = 77
		fcmd(8'hB0); mov(3, 8'h00, 0); strb(3, 0, 0);                         // bank 0
		mov(3, 8'h99, 0); strb(3, 0, 12'h300);                                // [0x300] = 99 (plain)
		loop_pc = pc; bto(pc);
	end endtask
	task build_b; begin
		prologue;
		fcmd(8'h80); fcmd(8'h10);                                             // the chip erased
		fcmd(8'hA0); mov(3, 8'h11, 0); strb(3, 0, 12'h040);                   // [0x40] = 11
		fcmd(8'hB0); mov(3, 8'h01, 0); strb(3, 0, 0);
		fcmd(8'hA0); mov(3, 8'h22, 0); strb(3, 0, 12'h040);                   // [0x10040] = 22
		loop_pc = pc; bto(pc);
	end endtask
	task load_rom;                          // as the menu: the size in 0x1D0, the cartridge through the window, the end strobe
		input [31:0] cfg_bits;
		begin
			ctrl_write(16'h01D0, cfg_bits | 32'd16384);
			for (i = 0; i < 4096; i = i + 1) prog_write(i, rom[i]);
			@(posedge clk); fill_end <= 1'b1; @(posedge clk); fill_end <= 1'b0;
			repeat (100) @(posedge clk);
			bad = 0;
			for (i = 0; i < 4096; i = i + 1) if (mem[i >> 2][32 * (i % 4) +: 32] !== rom[i]) begin
				if (bad < 4) $display("       DDR3 cartridge word %0d: %08x, want %08x", i, mem[i >> 2][32 * (i % 4) +: 32], rom[i]);
				bad = bad + 1;
			end
			check(bad == 0, "the cartridge landed in DDR3 word for word, through the stalls");
		end
	endtask
	task start_game;                        // run; the processor where the BIOS leaves it for the cartridge
		begin
			@(posedge clk); off <= 16'h0004; wdata <= 32'd1; ctrl_we <= 1'b1;
			@(posedge clk); ctrl_we <= 1'b0;
			@(negedge clk);
			dut.g_gba.u_gba.cpu.pc = 32'h08000000; dut.g_gba.u_gba.cpu.cpsr = 32'h0000001F;
			dut.g_gba.u_gba.cpu.R[13] = 32'h03007F00; dut.g_gba.u_gba.cpu.R[23] = 32'h03007FE0; dut.g_gba.u_gba.cpu.R[27] = 32'h03007FA0;
			for (k = 0; k < 13; k = k + 1) dut.g_gba.u_gba.cpu.R[k] = 0;
			dut.g_gba.u_gba.cpu.R[14] = 32'h08000000;
			k = 0;
			while (!(dut.gba_dbg_pc >= loop_pc + 32'h08000000 && dut.gba_dbg_pc <= loop_pc + 32'h08000008) && k < 2_000_000) begin @(posedge clk); k = k + 1; end
			repeat (2000) @(posedge clk);
			check(k < 2_000_000, "the game ran to its loop");
		end
	endtask

	// --- the save as the host sees it -----------------------------------------------------------
	// a command's bits into IWRAM as halfwords (bit 0 of each), from byte offset `at`
	reg [127:0] cbits; integer cn;
	task put_cmd;
		input [15:0] at;
		begin
			for (k = 0; k < cn; k = k + 1)
				dut.g_gba.u_gba.iwram[(at >> 2) + (k >> 1)][16 * (k & 1) +: 16] = {15'd0, cbits[cn - 1 - k]};
		end
	endtask
	task eep_cmds;                          // the write of `wdat` to block wa, read requests for ra and rb
		input big; input [9:0] wa; input [63:0] wdat; input [9:0] ra, rb;
		begin
			cn = big ? 81 : 73; cbits = big ? {2'b10, 4'd0, wa, wdat, 1'b0} : {2'b10, wa[5:0], wdat, 1'b0}; put_cmd(16'h000);
			cn = big ? 17 : 9;  cbits = big ? {2'b11, 4'd0, ra, 1'b0} : {2'b11, ra[5:0], 1'b0}; put_cmd(16'h200);
			cbits = big ? {2'b11, 4'd0, rb, 1'b0} : {2'b11, rb[5:0], 1'b0}; put_cmd(16'h300);
		end
	endtask
	reg [63:0] blk;
	task iw_block;                           // the 68 halfwords read to `at`: four zeros, then the block, first bit highest
		input [15:0] at;
		begin
			bad = 0; blk = 64'd0;
			for (k = 0; k < 68; k = k + 1) begin
				rd = dut.g_gba.u_gba.iwram[(at >> 2) + (k >> 1)];
				rd = (k & 1) ? rd[31:16] : rd[15:0];
				if (k < 4) begin if (rd !== 32'd0) bad = bad + 1; end
				else begin if (rd[15:1] !== 15'd0) bad = bad + 1; blk[67 - k] = rd[0]; end
			end
		end
	endtask
	function [63:0] pat_blk; input [9:0] b; integer j; begin
		for (j = 0; j < 8; j = j + 1) pat_blk[63 - 8 * j -: 8] = pat[8 * b + j];
	end endfunction
	reg [7:0] want [0:131071];
	reg [7:0] got [0:131071];

	task save_in;                           // gbaSaveBegin's order: 0x1D0 bit 30, bank 0, the words, the flag down
		begin
			ctrl_write(16'h01D0, 32'h4000_0000 | 32'd16384);
			for (i = 0; i < 131072; i = i + 4) prog_write(i >> 2, {pat[i + 3], pat[i + 2], pat[i + 1], pat[i]});
			repeat (200) @(posedge clk);
			ctrl_write(16'h01DC, 32'd1);
		end
	endtask
	task save_out;                          // gbaSaveService: a line at a time through 0x7C / 0x80-0x8C
		begin
			for (n = 0; n < 8192; n = n + 1) begin
				ctrl_write(16'h007C, 32'h204000 + n);
				t = 0; rd = 0;
				while (!rd[31] && t < 400) begin ctrl_read(16'h007C); t = t + 1; end
				if (!rd[31]) $display("       line %0d: no answer", n);
				for (k = 0; k < 4; k = k + 1) begin
					ctrl_read(16'h0080 + 4 * k);
					{got[16 * n + 4 * k + 3], got[16 * n + 4 * k + 2], got[16 * n + 4 * k + 1], got[16 * n + 4 * k]} = rd;
				end
			end
		end
	endtask
	task compare;
		input [1023:0] what;
		begin
			bad = 0;
			for (i = 0; i < 131072; i = i + 1) if (got[i] !== want[i]) begin
				if (bad < 6) $display("       byte %05x: %02x, want %02x", i, got[i], want[i]);
				bad = bad + 1;
			end
			if (bad) $display("       %0d bytes differ", bad);
			check(bad == 0, what);
		end
	endtask

	initial begin
		if (!$value$plusargs("WGAP%d", wgap)) wgap = 10;
		if (!$value$plusargs("LAT%d", lat)) lat = 20;
		if (!$value$plusargs("TRACE%d", trace)) trace = 0;
		for (i = 0; i < 131072; i = i + 1) mem[i] = 128'd0;
		for (i = 0; i < 131072; i = i + 1) pat[i] = (i * 7 + (i >> 8) * 13 + (i >> 16) * 101 + 8'h31) & 8'hFF;
		$display("tb_gba_save: a fill word every %0d clocks, DDR3 latency %0d, stalls of up to 60 clocks", wgap, lat);
		repeat (8) @(posedge clk); rst = 0;
		repeat (8) @(posedge clk);
		ctrl_write(16'h0004, 32'd0);
		ctrl_write(16'h0020, 32'd10);
		ctrl_read(16'h0020);
		check(rd[3:0] == 4'd10 && rd[26] == 1'b1, "0x20 reads the Game Boy Advance built and selected");

		// 1 -------------------------------------------------------------------------------------
		save_in;
		bad = 0;
		for (i = 0; i < 131072; i = i + 1) if (mem[17'h0C000 + (i >> 4)][8 * (i % 16) +: 8] !== pat[i]) begin
			if (bad < 6) $display("       DDR3 save byte %05x: %02x, want %02x", i, mem[17'h0C000 + (i >> 4)][8 * (i % 16) +: 8], pat[i]);
			bad = bad + 1;
		end
		check(bad == 0, "1: all 128 kB of the save landed in DDR3 at line 0x204000 up, through the stalls");
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b0, "1: the written flag is down after the load");

		// 2, 3 ----------------------------------------------------------------------------------
		build_a;
		load_rom(32'd0);
		start_game;
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b1, "3: the game's writes put the flag up");
		save_out;
		for (i = 0; i < 131072; i = i + 1) want[i] = pat[i];
		want[17'h00100] = pat[17'h00010] + 8'd1;
		want[17'h0FFFF] = 8'h5A;
		want[17'h00200] = 8'h62; want[17'h00201] = 8'h13;           // Sanyo
		for (i = 17'h03000; i < 17'h04000; i = i + 1) want[i] = 8'hFF;
		want[17'h03234] = 8'h42;
		want[17'h10020] = 8'h77;
		want[17'h00300] = 8'h99;
		compare("3: read back while the game runs: the host's bytes and exactly the game's changes (SRAM writes, ID, sector erase, program, bank 1)");
		ctrl_write(16'h01DC, 32'd1);
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b0, "3: a write to 0x1DC takes the flag down");
		repeat (200_000) @(posedge clk);
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b0, "3: ...and the game idling leaves it down");

		// 4 -------------------------------------------------------------------------------------
		ctrl_write(16'h0004, 32'd0);
		build_b;
		load_rom(32'd0);
		start_game;
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b1, "4: the chip erase and the programs put the flag up");
		save_out;
		for (i = 0; i < 131072; i = i + 1) want[i] = 8'hFF;
		want[17'h00040] = 8'h11; want[17'h10040] = 8'h22;
		compare("4: a chip erase blanks both banks; a byte programmed in each");

		// 5 -------------------------------------------------------------------------------------
		ctrl_write(16'h0004, 32'd0);
		save_in;
		build_a;
		load_rom(32'h1000_0000);
		start_game;
		save_out;
		for (i = 0; i < 131072; i = i + 1) want[i] = pat[i];
		want[17'h00100] = pat[17'h00010] + 8'd1;
		want[17'h0FFFF] = 8'h5A;
		want[17'h00200] = 8'h32; want[17'h00201] = 8'h1B;           // Panasonic
		for (i = 17'h03000; i < 17'h04000; i = i + 1) want[i] = 8'hFF;
		want[17'h03234] = 8'h42;
		want[17'h00020] = 8'h77;                                      // (no bank 1: it lands in bank 0)
		want[17'h00300] = 8'h99;
		compare("5: flash64: Panasonic's 64 kB ID, the bank command ignored");

		// 6 -------------------------------------------------------------------------------------
		ctrl_write(16'h0004, 32'd0);
		save_in;
		build_eep(8'd81, 8'd17);
		load_rom(32'h0800_0000);
		eep_cmds(1'b1, 10'd5, 64'h0123456789ABCDEF, 10'd9, 10'd5);
		start_game;
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b1 && rd[2:1] === 2'b10, "6: EEPROM 8 kB: the write put the flag up, 0x1DC [2:1] says 8 kB");
		iw_block(16'h400);
		check(bad == 0 && blk === pat_blk(10'd9), "6: block 9 read by DMA: four zeros, then the host's eight bytes, first bit highest");
		if (blk !== pat_blk(10'd9)) $display("       got %016x want %016x", blk, pat_blk(10'd9));
		iw_block(16'h600);
		check(bad == 0 && blk === 64'h0123456789ABCDEF, "6: block 5 read back as written");
		if (blk !== 64'h0123456789ABCDEF) $display("       got %016x", blk);
		save_out;
		for (i = 0; i < 131072; i = i + 1) want[i] = pat[i];
		for (i = 0; i < 8; i = i + 1) want[40 + i] = 8'h01 + 8'h22 * i;   // 01 23 45 67 89 AB CD EF
		compare("6: the save memory: block 5 at bytes 40-47 (emulators' layout), nothing else changed");

		// 7 -------------------------------------------------------------------------------------
		ctrl_write(16'h0004, 32'd0);
		save_in;
		build_eep(8'd73, 8'd9);
		load_rom(32'h0800_0000);
		eep_cmds(1'b0, 10'd3, 64'hFEDCBA9876543210, 10'd1, 10'd3);
		start_game;
		ctrl_read(16'h01DC);
		check(rd[0] === 1'b1 && rd[2:1] === 2'b01, "7: EEPROM 512 B: the flag up, 0x1DC [2:1] says 512 B");
		iw_block(16'h400);
		check(bad == 0 && blk === pat_blk(10'd1), "7: block 1 read: the host's bytes");
		iw_block(16'h600);
		check(bad == 0 && blk === 64'hFEDCBA9876543210, "7: block 3 read back as written");
		save_out;
		for (i = 0; i < 131072; i = i + 1) want[i] = pat[i];
		for (i = 0; i < 8; i = i + 1) want[24 + i] = 8'hFE - 8'h22 * i;   // FE DC BA 98 76 54 32 10
		compare("7: the save memory: block 3 at bytes 24-31");

		$display("");
		if (fails == 0) $display("tb_gba_save: all checks passed");
		else            $display("tb_gba_save: %0d FAIL(s)", fails);
		$finish;
	end
	initial begin #(64'd4_000_000_000); $display("TIMEOUT"); $display("tb_gba_save: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
