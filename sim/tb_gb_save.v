`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_gb_save - the Game Boy's battery save through the host's registers, as the menu does it.
//
// console_top built with CORE_GB only, at 50 MHz, the cartridge in a DDR3 model (as tb_con_gb).
// The cartridge is assembled here (no ROM file): it enables its RAM, reads a byte the host put
// in (bank 1 $A010), writes it plus one to bank 3 $B000 and $5A to bank 3 $BFFF, latches the
// MBC3 clock and copies its five registers (through HRAM) to bank 0 $A100-$A104, and loops.
//
//   A  MBC5 + RAM + battery ($1B), 32 kB of RAM:
//      - with the machine held in reset, the host writes all 32 kB through 0x184 / 0x188 and
//        reads every word back (the round trip); the written flag (0x184 bit 0) stays clear
//      - the game runs: the flag goes up; paused, the host reads all 32 kB and finds exactly
//        the game's writes on top of what it put in (MBC5: "$4000 = 8..12" picks RAM banks
//        0..3, so $A100.. are RAM bytes, not the clock)
//      - a clear (0x184 bit 31) takes the flag down and an idle game leaves it down; a host
//        write while the game runs reads back
//   B  MBC3 + clock + RAM + battery ($10):
//      - the host sets the clock (0x8000 {days, h, m, s}, 0x8004 the day-high register) while
//        in reset and reads it back; the game, let go, latches and reads exactly that
//        (the reset takes the preset), and the host reads the clock back the same
//
//   ./tools/sim.sh tb_gb_save
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module tb_gb_save;
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
	reg  [127:0] d_rdata = 128'd0; reg d_valid = 1'b0;

	console_top #(.CORE_NES(0), .CORE_SMS(0), .CORE_GB(1), .PROG_AW(12), .CHAR_AW(12), .CLK_HZ(50_000_000)) dut (
		.clk(clk), .rst(rst), .ce(1'b0),
		.off(off), .con_index(10'd0), .con_rdata(),
		.prog_windex(10'd0), .md_windex_full(windex), .md_windex(windex[15:0]), .char_windex(10'd0),
		.esp_sclk(1'b0), .esp_mosi(1'b0), .esp_miso(), .esp_cs_n(1'b1),
		.ctrl_we(ctrl_we),
		.stream_en(), .stream_port(), .stream_base(), .stream_words(), .stream_rowlen(), .stream_stride(),
		.stream_ready(), .stream_done_tog(1'b0), .stream_direct(), .stream_fdata(), .stream_fvalid(), .stream_frd(1'b0),
		.fill_end(fill_end), .prog_we(prog_we), .char_we(1'b0), .wdata(wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_ready(1'b1), .d_rdata(d_rdata), .d_valid(d_valid), .d_calibrated(1'b1),
		.ctrl_rdata(ctrl_rdata), .prog_rdata(), .char_rdata(),
		.audio(audio), .audio_lr(audio_lr), .audio_lr_we(audio_lr_we),
		.px_valid(), .px_x(), .px_y(), .px_rgb(),
		.fbr_addr(18'd0), .fbr_req(1'b0), .fbr_rdata(), .fbr_ack(),
		.pclk(pclk), .vid_x(10'd0), .vid_y(10'd0), .vid_req(1'b0), .vid_rgb(vid_rgb)
	);

	// --- DDR3: 1 MB of lines; a write lands at once, a read answers 30 clocks later -------------
	reg [127:0] mem [0:65535];
	integer lat = 30, rd_cnt = 0;
	reg [15:0] rd_a;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req) begin
			if (d_we) mem[d_addr[15:0]] <= d_wdata;
			else begin rd_a <= d_addr[15:0]; rd_cnt <= lat; end
		end else if (rd_cnt > 0) begin
			rd_cnt <= rd_cnt - 1;
			if (rd_cnt == 1) begin d_rdata <= mem[rd_a]; d_valid <= 1'b1; end
		end
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
	// a register write as the bus makes it (one clock), then the bus's own gap
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
	task prog_write;
		input [21:0] idx;
		input [31:0] d;
		begin
			@(posedge clk); windex <= idx; wdata <= d; prog_we <= 1'b1;
			@(posedge clk); prog_we <= 1'b0;
			repeat (22) @(posedge clk);
		end
	endtask

	// --- the cartridge, assembled --------------------------------------------------------------
	reg [7:0] rom [0:32767];
	integer pc;
	task b; input [7:0] v; begin rom[pc] = v; pc = pc + 1; end endtask
	task ld_nn_a; input [15:0] w; begin b(8'hEA); b(w[7:0]); b(w[15:8]); end endtask
	task ld_a_nn; input [15:0] w; begin b(8'hFA); b(w[7:0]); b(w[15:8]); end endtask
	task ld_a_n;  input [7:0] n;  begin b(8'h3E); b(n); end endtask
	integer loop_pc, r;
	task build_rom;
		input [7:0] cart_type;
		begin
			for (pc = 0; pc < 32768; pc = pc + 1) rom[pc] = 8'h00;
			rom[16'h143] = 8'h00;             // a DMG cartridge
			rom[16'h147] = cart_type;
			rom[16'h148] = 8'h00;             // 32 kB of ROM
			rom[16'h149] = 8'h03;             // 32 kB of RAM
			pc = 16'h100; b(8'h00); b(8'hC3); b(8'h50); b(8'h01);          // nop; jp $0150
			pc = 16'h150;
			b(8'h31); b(8'hFE); b(8'hFF);                                   // ld sp, $FFFE
			ld_a_n(8'h0A); ld_nn_a(16'h0000);                               // RAM on
			ld_a_n(8'h01); ld_nn_a(16'h4000);                               // bank 1
			ld_a_nn(16'hA010); b(8'h3C); b(8'h47);                          // ld a,($A010); inc a; ld b,a
			ld_a_n(8'h03); ld_nn_a(16'h4000);                               // bank 3
			b(8'h78); ld_nn_a(16'hB000);                                    // ld a,b; ld ($B000),a
			ld_a_n(8'h5A); ld_nn_a(16'hBFFF);
			ld_a_n(8'h00); ld_nn_a(16'h6000); ld_a_n(8'h01); ld_nn_a(16'h6000);   // latch the clock
			for (r = 0; r < 5; r = r + 1) begin                            // its registers to HRAM
				ld_a_n(8'h08 + r); ld_nn_a(16'h4000); ld_a_nn(16'hA000); b(8'hE0); b(8'h80 + r);
			end
			ld_a_n(8'h00); ld_nn_a(16'h4000);                               // bank 0
			for (r = 0; r < 5; r = r + 1) begin b(8'hF0); b(8'h80 + r); ld_nn_a(16'hA100 + r); end
			loop_pc = pc; b(8'h18); b(8'hFE);                               // jr $
		end
	endtask
	task load_rom;
		begin
			for (pc = 0; pc < 32768; pc = pc + 4)
				prog_write(pc >> 2, {rom[pc + 3], rom[pc + 2], rom[pc + 1], rom[pc]});
			@(posedge clk); fill_end <= 1'b1; @(posedge clk); fill_end <= 1'b0;
			repeat (64) @(posedge clk);
		end
	endtask

	// --- the save RAM as the host sees it --------------------------------------------------------
	reg [7:0] pat [0:32767];
	reg [7:0] want [0:32767];
	reg [7:0] got [0:32767];
	integer i, bad, t;
	task host_put_all;                    // the pattern in, the flag cleared first (the menu's order)
		begin
			ctrl_write(16'h0184, 32'h8000_0000);
			for (i = 0; i < 32768; i = i + 4)
				ctrl_write(16'h0188, {pat[i + 3], pat[i + 2], pat[i + 1], pat[i]});
		end
	endtask
	task host_get_all;
		begin
			for (i = 0; i < 32768; i = i + 4) begin
				ctrl_write(16'h0184, i);
				ctrl_read(16'h0188);
				{got[i + 3], got[i + 2], got[i + 1], got[i]} = rd;
			end
		end
	endtask
	task compare;                          // got against want
		input [1023:0] what;
		begin
			bad = 0;
			for (i = 0; i < 32768; i = i + 1) if (got[i] !== want[i]) begin
				if (bad < 6) $display("       byte %04x: %02x, want %02x", i, got[i], want[i]);
				bad = bad + 1;
			end
			check(bad == 0, what);
		end
	endtask
	task run_to_loop;
		begin
			t = 0;
			while (dut.gb_dbg_pc != loop_pc && t < 3_000_000) begin @(posedge clk); t = t + 1; end
			repeat (2000) @(posedge clk);
			check(dut.gb_dbg_pc == loop_pc || dut.gb_dbg_pc == loop_pc + 1 || dut.gb_dbg_pc == loop_pc + 2,
			      "the game ran to its loop");
		end
	endtask

	initial begin
		for (i = 0; i < 65536; i = i + 1) mem[i] = 128'd0;
		for (i = 0; i < 32768; i = i + 1) pat[i] = (i * 7 + (i >> 8) * 13 + 8'h31) & 8'hFF;
		repeat (8) @(posedge clk); rst = 0;
		repeat (8) @(posedge clk);
		ctrl_write(16'h0004, 32'd0);
		ctrl_write(16'h0020, 32'd7);

		// ---------------- A: MBC5 ----------------
		$display("tb_gb_save: A, MBC5 + RAM + battery");
		host_put_all;
		host_get_all;
		for (i = 0; i < 32768; i = i + 1) want[i] = pat[i];
		compare("held in reset: all 32 kB written through 0x188 read back through it");
		ctrl_read(16'h0184);
		check(rd[0] === 1'b0, "the host's writes leave the written flag down");

		build_rom(8'h1B);
		load_rom;
		ctrl_write(16'h0004, 32'd1);
		run_to_loop;
		ctrl_read(16'h0184);
		check(rd[0] === 1'b1, "the game's writes put the written flag up");
		ctrl_write(16'h0004, 32'd5);                           // paused, as the menu reads
		host_get_all;
		want[16'h7000] = pat[16'h2010] + 8'd1;
		want[16'h7FFF] = 8'h5A;
		for (r = 0; r < 5; r = r + 1) want[16'h0100 + r] = pat[((r + 8) & 3) * 16'h2000];   // (MBC5: RAM banks, no clock)
		compare("paused: the RAM is the host's bytes with the game's writes on top");
		ctrl_write(16'h0184, 32'h8000_0000);
		ctrl_read(16'h0184);
		check(rd[0] === 1'b0, "a clear takes the flag down");
		ctrl_write(16'h0004, 32'd1);
		repeat (200_000) @(posedge clk);
		ctrl_read(16'h0184);
		check(rd[0] === 1'b0, "...and the game idling leaves it down");
		ctrl_write(16'h0184, 32'h0000_1234);                   // a host write while the game runs
		ctrl_write(16'h0188, 32'hCAFE_F00D);
		ctrl_write(16'h0184, 32'h0000_1234);
		ctrl_read(16'h0188);
		check(rd === 32'hCAFE_F00D, "a word written while the game runs reads back");
		ctrl_write(16'h0184, 32'h0000_1236);
		ctrl_read(16'h0188);
		check(rd === {pat[16'h1239], pat[16'h1238], 16'hCAFE}, "...from an unaligned pointer too (bytes 0x1236..0x1239)");

		// ---------------- B: MBC3 and its clock ----------------
		$display("tb_gb_save: B, MBC3 + clock + RAM + battery");
		ctrl_write(16'h0004, 32'd0);                           // held, as the loader does
		ctrl_write(16'h0184, 32'h0000_8000);
		ctrl_write(16'h0188, {8'h2A, 8'd13, 8'd45, 8'd17});    // day $2A, 13:45:17
		ctrl_write(16'h0188, 32'h0000_0081);                   // carry, day bit 8
		ctrl_write(16'h0184, 32'h0000_8000); ctrl_read(16'h0188);
		check(rd === {8'h2A, 8'd13, 8'd45, 8'd17}, "the clock's word at 0x8000 reads back (in reset)");
		ctrl_write(16'h0184, 32'h0000_8004); ctrl_read(16'h0188);
		check(rd === 32'h0000_0081, "...and the day-high word at 0x8004");
		host_put_all;
		build_rom(8'h10);
		load_rom;
		ctrl_write(16'h0004, 32'd1);
		run_to_loop;
		ctrl_write(16'h0004, 32'd5);
		host_get_all;
		for (i = 0; i < 32768; i = i + 1) want[i] = pat[i];
		want[16'h7000] = pat[16'h2010] + 8'd1;
		want[16'h7FFF] = 8'h5A;
		want[16'h0100] = 8'd17; want[16'h0101] = 8'd45; want[16'h0102] = 8'd13; want[16'h0103] = 8'h2A; want[16'h0104] = 8'h81;
		compare("the game read the host's clock (latched) and the RAM is right");
		ctrl_write(16'h0184, 32'h0000_8000); ctrl_read(16'h0188);
		check(rd === {8'h2A, 8'd13, 8'd45, 8'd17}, "the running clock reads back through 0x8000 (well under a second of game time)");
		ctrl_write(16'h0184, 32'h0000_8004); ctrl_read(16'h0188);
		check(rd === 32'h0000_0081, "...and 0x8004");
		// a clock set while running moves the running clock at once
		ctrl_write(16'h0184, 32'h0000_8000);
		ctrl_write(16'h0188, {8'h01, 8'd2, 8'd3, 8'd4});
		ctrl_write(16'h0184, 32'h0000_8000); ctrl_read(16'h0188);
		check(rd === {8'h01, 8'd2, 8'd3, 8'd4}, "a clock written while paused is the running clock");

		$display("");
		if (fails == 0) $display("tb_gb_save: all checks passed");
		else            $display("tb_gb_save: %0d FAIL(s)", fails);
		$finish;
	end
	initial begin #2_000_000_000; $display("TIMEOUT"); $display("tb_gb_save: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
