`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_con_a26 - the Atari 2600 as the board has it: console_top built with CORE_A26 only,
// at the board's 50 MHz, loaded and run the way the menu does it, and its picture and
// sound checked where HDMI takes them.
//
//   - the cartridge goes in as 32-bit words through the program window (prog_we with
//     md_windex, as regfile drives them from the ESP32's writes), a word every 40 clocks;
//     the bench compares the core's 32 kB cartridge RAM with the file afterwards
//   - ctrl 0x1C8 the size and scheme, 0x20 console 8, 0x04 run; 0x20 reads back the
//     Atari's CORES_BUILT bit (bit 24) and the console number
//   - the gate kernel (tools/a26/kernels/test.asm, sim/roms/a2600/test.hex: tb_a26 checks
//     the same picture at the TIA's output) is run for its frames; at a VSYNC the frame
//     buffer frame_hdmi keeps must hold the picture: the window from the kernel's first
//     visible line, 192 lines, and three whole lines of it compared pixel by pixel
//   - the HDMI side: pixels read back through frame_hdmi's pixel port land three wide and
//     two tall, centred (x 80..559, y 48..431), in the palette's colours
//   - the sound: audio_lr takes the Atari's two sides at 48 kHz and they move
//
//   ./tools/sim.sh tb_con_a26
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module tb_con_a26;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz
	reg pclk = 0;
	always #20 pclk = ~pclk;               // 25 MHz, HDMI's

	reg  [15:0] off = 16'd0;
	reg  [31:0] wdata = 32'd0;
	reg         ctrl_we = 1'b0, prog_we = 1'b0, fill_end = 1'b0;
	reg  [15:0] md_windex = 16'd0;
	reg  [9:0]  vid_x = 10'd0, vid_y = 10'd0;
	reg         vid_req = 1'b0;
	wire [31:0] ctrl_rdata, audio_lr;
	wire        audio_lr_we;
	wire [23:0] vid_rgb;
	wire [15:0] audio;

	console_top #(.CORE_NES(0), .CORE_SMS(0), .CORE_A26(1), .PROG_AW(12), .CHAR_AW(12), .CLK_HZ(50_000_000)) dut (
		.clk(clk), .rst(rst), .ce(1'b0),
		.off(off), .con_index(10'd0), .con_rdata(),
		.prog_windex(10'd0), .md_windex_full({6'd0, md_windex}), .md_windex(md_windex), .char_windex(10'd0),
		.esp_sclk(1'b0), .esp_mosi(1'b0), .esp_miso(), .esp_cs_n(1'b1),
		.ctrl_we(ctrl_we),
		.stream_en(), .stream_port(), .stream_base(), .stream_words(), .stream_rowlen(), .stream_stride(),
		.stream_ready(), .stream_done_tog(1'b0), .stream_direct(), .stream_fdata(), .stream_fvalid(), .stream_frd(1'b0),
		.fill_end(fill_end), .prog_we(prog_we), .char_we(1'b0), .wdata(wdata),
		.d_addr(), .d_req(), .d_we(), .d_wdata(), .d_wmask(),
		.d_ready(1'b0), .d_rdata(128'd0), .d_valid(1'b0), .d_calibrated(1'b0),
		.ctrl_rdata(ctrl_rdata), .prog_rdata(), .char_rdata(),
		.audio(audio), .audio_lr(audio_lr), .audio_lr_we(audio_lr_we),
		.px_valid(), .px_x(), .px_y(), .px_rgb(),
		.fbr_addr(18'd0), .fbr_req(1'b0), .fbr_rdata(), .fbr_ack(),
		.pclk(pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(vid_rgb)
	);

	integer fails = 0;
	task check;
		input cond;
		input [1023:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); fails = fails + 1; end
		end
	endtask

	// --- the host's writes, as regfile makes them --------------------------------------------
	task ctrl_write;
		input [15:0] a;
		input [31:0] d;
		begin
			@(posedge clk); off <= a; wdata <= d; ctrl_we <= 1'b1;
			@(posedge clk); ctrl_we <= 1'b0;
		end
	endtask
	task prog_write;
		input [15:0] idx;
		input [31:0] d;
		begin
			@(posedge clk); md_windex <= idx; wdata <= d; prog_we <= 1'b1;
			@(posedge clk); prog_we <= 1'b0;
			repeat (38) @(posedge clk);
		end
	endtask

	// --- the gate's picture (tb_a26's) -----------------------------------------------------------
	localparam [6:0] C_BK = 7'h00, C_P0 = 7'h23, C_P1 = 7'h43, C_PF = 7'h64;
	function pf_lit;
		input integer x;
		integer c4;
		begin
			c4 = (x % 80) / 4;
			if (c4 < 4)         pf_lit = 1;
			else if (c4 < 12)   pf_lit = ((8'h55 >> (11 - c4)) & 1) != 0;
			else                pf_lit = 0;
		end
	endfunction
	function [6:0] want_at;
		input integer x;
		begin
			want_at = pf_lit(x) ? C_PF : C_BK;
			if (x >= 3 && x <= 10)  want_at = C_P0;
			if (x == 39)            want_at = C_P0;
			if (x == 80 || x == 87) want_at = C_P1;
			if (x == 99)            want_at = C_PF;
		end
	endfunction

	// --- the sound: every sample HDMI is handed -------------------------------------------------
	integer lr_n = 0, lr_min = 0, lr_max = 0, lr_lr_differ = 0;
	always @(posedge clk) if (audio_lr_we && dut.run) begin
		lr_n = lr_n + 1;
		if ($signed(audio_lr[15:0]) < lr_min) lr_min = $signed(audio_lr[15:0]);
		if ($signed(audio_lr[15:0]) > lr_max) lr_max = $signed(audio_lr[15:0]);
		if (audio_lr[31:16] != audio_lr[15:0]) lr_lr_differ = lr_lr_differ + 1;
	end

	// --- the HDMI side: one pixel read through frame_hdmi's port --------------------------------
	reg [23:0] got_rgb;
	task hdmi_pixel;
		input [9:0] x;
		input [9:0] y;
		begin
			// (frame_hdmi registers the word and its visibility on the clock that samples x, y)
			@(posedge pclk); vid_x <= x; vid_y <= y; vid_req <= 1'b1;
			@(posedge pclk); #1 got_rgb = vid_rgb; vid_req <= 1'b0;
		end
	endtask

	reg [7:0] img [0:32767];
	integer i, n, x, y, frames = 0, row, len, scheme, gate, nfr, cfg, tmp, bad;
	reg [6:0] want;
	initial begin
		for (i = 0; i < 32768; i = i + 1) img[i] = 8'd0;
		$readmemh("../../sim/roms/a2600/test.hex", img);
		len = 4096; scheme = 0; gate = 1; nfr = 4;
		cfg = $fopen("../../sim/roms/a2600/test_cfg.txt", "r");
		if (cfg) begin
			tmp = $fscanf(cfg, "%d", len); tmp = $fscanf(cfg, "%d", scheme); tmp = $fscanf(cfg, "%d", gate);
			if ($fscanf(cfg, "%d", tmp) == 1) nfr = tmp;
			$fclose(cfg);
		end
		$display("tb_con_a26: %0d bytes, scheme %0d, %0d frames", len, scheme, nfr);
		if (!gate) $display("  (test.hex is not the gate kernel: run tools/a26/asm.py on kernels/test.asm)");

		repeat (8) @(posedge clk); rst = 0;
		repeat (8) @(posedge clk);
		// the menu's order: held, the console chosen, the cartridge, its shape, run
		ctrl_write(16'h0004, 32'd0);
		ctrl_write(16'h0020, 32'd8);
		off <= 16'h0020; @(posedge clk); #1;
		check(ctrl_rdata[24] === 1'b1 && ctrl_rdata[23:16] === 8'd0 && ctrl_rdata[3:0] === 4'd8,
		      "0x20 reads the Atari built (bit 24) and selected (8)");
		for (i = 0; i < len; i = i + 4)
			prog_write(i >> 2, {img[i + 3], img[i + 2], img[i + 1], img[i]});
		ctrl_write(16'h01C8, {12'd0, scheme[3:0], len[15:0]});
		repeat (8) @(posedge clk);
		bad = 0;
		for (i = 0; i < len; i = i + 1) if (dut.g_a26.u_a26.rom[i] !== img[i]) bad = bad + 1;
		check(bad == 0, "the cartridge RAM holds the file, a byte at a time from 32-bit writes");
		ctrl_write(16'h0004, 32'd1);

		// the kernel's frames, and one more so the measured window has settled
		while (frames < nfr + 2) begin
			@(posedge clk);
			if (dut.a26_frame_st) frames = frames + 1;
		end
		// at the VSYNC: the frame before it is whole in the buffer, and the next has not begun
		$display("  window: from line %0d, %0d lines", dut.g_a26.w_top, dut.g_a26.w_h);
		check(dut.g_a26.w_h == 9'd192, "the window is the kernel's 192 lines");
		check(dut.g_a26.w_top >= 9'd30 && dut.g_a26.w_top <= 9'd50, "...starting where VBLANK ends");
		bad = 0;
		for (n = 0; n < 3; n = n + 1) begin
			row = 10 + n * 85;
			for (x = 0; x < 160; x = x + 1) begin
				want = want_at(x);
				if (dut.g_a26.u_hdmi.fb[row * 320 + x] !== want) begin
					if (bad < 8) $display("  FAIL buffer row %0d x %0d: 0x%02X, want 0x%02X", row, x, dut.g_a26.u_hdmi.fb[row * 320 + x], want);
					bad = bad + 1;
				end
			end
		end
		check(bad == 0, "three lines of the buffer are the kernel's picture, pixel for pixel");
		bad = 0;
		for (x = 0; x < 160; x = x + 1) if (dut.g_a26.u_hdmi.fb[191 * 320 + x] === 7'bx) bad = bad + 1;
		check(bad == 0, "the window's last line was written");

		// HDMI: 160 x 192 shown 480 x 384 from (80, 48)
		hdmi_pixel(10'd80 + 3 * 5 + 1, 10'd48 + 2 * 10 + 1);
		check(got_rgb === dut.g_a26.u_hdmi.a26_rom[C_P0], "player 0 at column 5, line 10, on the TV at (96, 69)");
		hdmi_pixel(10'd80 + 3 * 87 + 2, 10'd48 + 2 * 95);
		check(got_rgb === dut.g_a26.u_hdmi.a26_rom[C_P1], "player 1 at column 87, line 95, on the TV at (343, 238)");
		hdmi_pixel(10'd80 + 3 * 60, 10'd48 + 2 * 10);
		check(got_rgb === dut.g_a26.u_hdmi.a26_rom[C_BK] && got_rgb != 24'd0, "the background at column 60 is TIA colour 0 through the palette");
		hdmi_pixel(10'd79, 10'd100);
		check(got_rgb === 24'd0, "black left of the picture (x 79)");
		hdmi_pixel(10'd560, 10'd100);
		check(got_rgb === 24'd0, "black right of it (x 560)");
		hdmi_pixel(10'd200, 10'd432);
		check(got_rgb === 24'd0, "black below it (y 432)");

		$display("  sound: %0d samples to HDMI, %0d..%0d", lr_n, lr_min, lr_max);
		check(lr_n > 1000, "HDMI was handed samples at 48 kHz");
		check(lr_min == -15360 && lr_max == 0, "they are the kernel's tone (-15360..0: one channel at volume 15)");
		check(lr_lr_differ == 0, "both sides the same (the 2600 is mono)");

		// the menu's pause (ctrl 0x04 bit 2): nothing moves until it is let go
		ctrl_write(16'h0004, 32'd5);
		repeat (16) @(posedge clk);
		n = dut.a26_dbg_pc; tmp = frames; bad = 0;
		for (i = 0; i < 1_000_000; i = i + 1) begin
			@(posedge clk);
			if (dut.a26_frame_st || dut.a26_dbg_pc != n) bad = 1;
		end
		check(bad == 0, "paused: no frame and the processor still for a million clocks (more than a frame)");
		ctrl_write(16'h0004, 32'd1);
		bad = 1;
		for (i = 0; i < 1_000_000 && bad; i = i + 1) begin @(posedge clk); if (dut.a26_frame_st) bad = 0; end
		check(bad == 0, "let go, it runs on");

		$display("");
		if (fails == 0) $display("tb_con_a26: all checks passed");
		else            $display("tb_con_a26: %0d FAIL(s)", fails);
		$finish;
	end
	initial begin #600_000_000; $display("TIMEOUT"); $display("tb_con_a26: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
