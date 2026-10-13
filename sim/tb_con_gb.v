`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_con_gb - the Game Boy as the board has it: console_top built with CORE_GB only, at
// the board's 50 MHz, its cartridge in a DDR3 model behind cart_ddr3 and cart_cache, loaded
// and run the way the menu does it, and its picture checked where HDMI takes it.
//
//   - ctrl 0x04 held, 0x20 console 7 (it reads back built: bit 23), then the cartridge as
//     32-bit words through the program window (md_windex_full, a word every 24 clocks), the
//     end strobe (fill_end), and run. The DDR3 model answers a read LAT clocks later
//     (default 30; LAT<n>), one at a time, as ddr3_mem does
//   - dmg-acid2 (sim/roms/gb/acid2.hex) runs FRAMES frames (12); at that frame_start the
//     160 x 144 shades in frame_hdmi's buffer must equal the reference
//     (sim/roms/gb/acid2_ref.hex, the one tb_gb uses at the PPU's output)
//   - the HDMI side: the picture tripled and centred (x 80..559, y 24..455), in the
//     palette's greens, black around it
//   - the sound path: audio_lr is the Game Boy's two sides
//   - the menu's pause stops the machine and lets it go
//
//   ./tools/sim.sh tb_con_gb [ROM<hex>] [REF<hex>] [FRAMES<n>] [LAT<n>]
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module tb_con_gb;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz
	reg pclk = 0;
	always #20 pclk = ~pclk;               // 25 MHz, HDMI's

	reg  [15:0] off = 16'd0;
	reg  [31:0] wdata = 32'd0;
	reg         ctrl_we = 1'b0, prog_we = 1'b0, fill_end = 1'b0;
	reg  [21:0] windex = 22'd0;
	reg  [9:0]  vid_x = 10'd0, vid_y = 10'd0;
	reg         vid_req = 1'b0;
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
		.pclk(pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(vid_rgb)
	);

	// --- DDR3: 1 MB of 16-byte lines; a write lands at once, a read answers LAT clocks later -----
	reg [127:0] mem [0:65535];
	integer lat = 30, rd_cnt = 0, n_rd = 0, n_wr = 0;
	reg [15:0] rd_a;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req) begin
			if (d_we) begin mem[d_addr[15:0]] <= d_wdata; n_wr = n_wr + 1; end
			else begin rd_a <= d_addr[15:0]; rd_cnt <= lat; n_rd = n_rd + 1; end
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
	task ctrl_write;
		input [15:0] a;
		input [31:0] d;
		begin
			@(posedge clk); off <= a; wdata <= d; ctrl_we <= 1'b1;
			@(posedge clk); ctrl_we <= 1'b0;
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
	reg [23:0] got_rgb;
	task hdmi_pixel;
		input [9:0] x;
		input [9:0] y;
		begin
			@(posedge pclk); vid_x <= x; vid_y <= y; vid_req <= 1'b1;
			@(posedge pclk); #1 got_rgb = vid_rgb; vid_req <= 1'b0;
		end
	endtask
	function [23:0] green;
		input [1:0] s;
		green = (s == 2'd0) ? 24'hE0F8D0 : (s == 2'd1) ? 24'h88C070 : (s == 2'd2) ? 24'h346856 : 24'h081820;
	endfunction

	// --- the sound: every sample HDMI is handed must be the core's two sides -----------------------
	integer lr_n = 0, lr_bad = 0;
	always @(posedge clk) if (audio_lr_we && dut.run) begin
		lr_n = lr_n + 1;
		if (audio_lr !== {dut.gb_audio_r, dut.gb_audio_l}) lr_bad = lr_bad + 1;
	end

	reg [7:0] rom [0:1048575];
	reg [1:0] ref [0:160 * 144 - 1];
	reg [1023:0] romfile, reffile;
	integer i, n, x, y, frames = 0, want_frames, size, bad, pc0;
	initial begin
		if (!$value$plusargs("ROM%s", romfile)) romfile = "../../sim/roms/gb/acid2.hex";
		if (!$value$plusargs("REF%s", reffile)) reffile = "../../sim/roms/gb/acid2_ref.hex";
		if (!$value$plusargs("FRAMES%d", want_frames)) want_frames = 12;
		if (!$value$plusargs("LAT%d", lat)) lat = 30;
		for (i = 0; i < 1048576; i = i + 1) rom[i] = 8'hFF;
		for (i = 0; i < 160 * 144; i = i + 1) ref[i] = 2'bx;
		$readmemh(romfile, rom);
		$readmemh(reffile, ref);
		for (i = 0; i < 65536; i = i + 1) mem[i] = {16{8'hEE}};
		// the cartridge's size: 32 kB << its header's byte 148h
		size = 32768 << rom[16'h148];
		$display("tb_con_gb: %0s, %0d kB, %0d frames, DDR3 latency %0d", romfile, size / 1024, want_frames, lat);

		repeat (8) @(posedge clk); rst = 0;
		repeat (8) @(posedge clk);
		ctrl_write(16'h0004, 32'd0);
		ctrl_write(16'h0020, 32'd7);
		off <= 16'h0020; @(posedge clk); #1;
		check(ctrl_rdata[23] === 1'b1 && ctrl_rdata[24] === 1'b0 && ctrl_rdata[3:0] === 4'd7,
		      "0x20 reads the Game Boy built (bit 23) and selected (7)");
		for (i = 0; i < size; i = i + 4)
			prog_write(i >> 2, {rom[i + 3], rom[i + 2], rom[i + 1], rom[i]});
		@(posedge clk); fill_end <= 1'b1; @(posedge clk); fill_end <= 1'b0;
		repeat (64) @(posedge clk);
		bad = 0;
		for (i = 0; i < size; i = i + 1) if (mem[i >> 4][8 * (i % 16) +: 8] !== rom[i]) bad = bad + 1;
		check(bad == 0, "DDR3 holds the cartridge byte for byte");
		ctrl_write(16'h0004, 32'd1);

		while (frames < want_frames) begin
			@(posedge clk);
			if (dut.gb_frame_st) frames = frames + 1;
		end
		$display("  %0d frames, PC=%04x, %0d DDR3 reads", frames, dut.gb_dbg_pc, n_rd);
		bad = 0;
		for (y = 0; y < 144; y = y + 1)
			for (x = 0; x < 160; x = x + 1)
				if (dut.g_gb.u_hdmi.fb[y * 320 + x] !== ref[y * 160 + x]) begin
					if (bad < 8) $display("  FAIL buffer (%0d,%0d): %0d, want %0d", x, y, dut.g_gb.u_hdmi.fb[y * 320 + x], ref[y * 160 + x]);
					bad = bad + 1;
				end
		check(bad == 0, "the frame in frame_hdmi's buffer is the reference, all 160 x 144");

		// HDMI: 160 x 144 shown 480 x 432 from (80, 24)
		bad = 0;
		for (n = 0; n < 6; n = n + 1) begin
			x = (n * 37 + 11) % 160; y = (n * 53 + 7) % 144;
			hdmi_pixel(10'd80 + 3 * x + n % 3, 10'd24 + 3 * y + (n + 1) % 3);
			if (got_rgb !== green(ref[y * 160 + x])) begin
				$display("  FAIL HDMI (%0d,%0d) for picture (%0d,%0d): %06x, want %06x", 80 + 3 * x + n % 3, 24 + 3 * y + (n + 1) % 3, x, y, got_rgb, green(ref[y * 160 + x]));
				bad = bad + 1;
			end
		end
		check(bad == 0, "six pixels read through the HDMI port are the picture's, tripled, in greens");
		hdmi_pixel(10'd79, 10'd200);  check(got_rgb === 24'd0, "black left of the picture (x 79)");
		hdmi_pixel(10'd560, 10'd200); check(got_rgb === 24'd0, "black right of it (x 560)");
		hdmi_pixel(10'd300, 10'd23);  check(got_rgb === 24'd0, "black above it (y 23)");
		hdmi_pixel(10'd300, 10'd456); check(got_rgb === 24'd0, "black below it (y 456)");

		$display("  sound: %0d samples to HDMI", lr_n);
		check(lr_n > 1000 && lr_bad == 0, "HDMI was handed the Game Boy's two sides at 48 kHz");

		// the menu's pause
		ctrl_write(16'h0004, 32'd5);
		repeat (64) @(posedge clk);
		pc0 = dut.gb_dbg_pc; bad = 0;
		for (i = 0; i < 1_000_000; i = i + 1) begin
			@(posedge clk);
			if (dut.gb_frame_st || dut.gb_dbg_pc != pc0) bad = 1;
		end
		check(bad == 0, "paused: no frame and the processor still for a million clocks (more than a frame)");
		ctrl_write(16'h0004, 32'd1);
		bad = 1;
		for (i = 0; i < 1_000_000 && bad; i = i + 1) begin @(posedge clk); if (dut.gb_frame_st) bad = 0; end
		check(bad == 0, "let go, it runs on");

		$display("");
		if (fails == 0) $display("tb_con_gb: all checks passed");
		else            $display("tb_con_gb: %0d FAIL(s)", fails);
		$finish;
	end
	initial begin #2_000_000_000; $display("TIMEOUT"); $display("tb_con_gb: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
