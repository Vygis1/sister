`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_con_gg - the Game Gear as the board has it: console_top built the way tools/core.sh gg
// builds it (CORE_NES=0 CORE_SMS=0 CORE_GG=1 CORE_MD=0, PROG_AW 18 / CHAR_AW 17 as regfile
// gives a non-MD image), at the board's 50 MHz with regfile's ce (the NES dot, 5.369318 MHz,
// a fractional strobe), loaded and run the way the menu does it (menu.h, g.m == 6), and its
// picture checked where HDMI takes it.
//
//   - ctrl 0x04 = 4 (stopped, halted), the ROM as 32-bit words through the program window
//     (prog_windex = the word index, prog_we, a word every 24 clocks), 0x20 = 6 (it reads back
//     built: bit 22, selected: 6), then 0x04 = 1 (run)
//   - beside it, a bare sms #(GG=1) on the same ROM, the same reset (the console's z80_rst) and
//     the same ce: the core on its own, the yardstick tb_gg_rom shows the ARMIX splash with
//   - after FRAMES frames (70: ARMIX is scrolling in) the 160 x 144 in frame_hdmi's buffer must hold a picture (not
//     all one colour) and equal the bare core's LCD window, pixel for pixel
//   - the HDMI side: pixels read through vid_x / vid_y / vid_req (vid_rgb one pclk later, as
//     hdmi_tx takes it) are the window's, tripled at (80, 24), black around it
//
//   ./tools/sim.sh tb_con_gg [ROM<hex>] [FRAMES<n>] [FAST1]
//   (FAST1: ce every other clock instead of the board's 5.37 MHz -- the same picture, sooner)
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module tb_con_gg;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz
	reg pclk = 0;
	always #20 pclk = ~pclk;               // 25 MHz, HDMI's

	// the board's ce (regfile.v nes_ce): a strobe 5,369,318 times in 50,000,000 clocks
	integer fast = 0;
	reg [25:0] nes_div = 26'd0;
	reg        ph = 1'b0;
	wire nes_ce = fast ? ph : (nes_div + 26'd5_369_318 >= 26'd50_000_000);
	always @(posedge clk) begin
		ph <= ~ph;
		if (rst) nes_div <= 26'd0;
		else if (nes_ce) nes_div <= nes_div + 26'd5_369_318 - 26'd50_000_000;
		else nes_div <= nes_div + 26'd5_369_318;
	end

	reg  [15:0] off = 16'd0;
	reg  [31:0] wdata = 32'd0;
	reg         ctrl_we = 1'b0, prog_we = 1'b0, fill_end = 1'b0;
	reg  [15:0] windex = 16'd0;
	reg  [9:0]  vid_x = 10'd0, vid_y = 10'd0;
	reg         vid_req = 1'b0;
	wire [31:0] ctrl_rdata, audio_lr;
	wire        audio_lr_we;
	wire [23:0] vid_rgb;
	wire [15:0] audio;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata; wire [15:0] d_wmask;

	console_top #(.CORE_NES(0), .CORE_SMS(0), .CORE_GG(1), .CORE_MD(0), .PROG_AW(18), .CHAR_AW(17), .CLK_HZ(50_000_000)) dut (
		.clk(clk), .rst(rst), .ce(nes_ce),
		.off(off), .con_index(10'd0), .con_rdata(),
		.prog_windex(windex), .md_windex_full({6'd0, windex}), .md_windex(windex), .char_windex(15'd0),
		.esp_sclk(1'b0), .esp_mosi(1'b0), .esp_miso(), .esp_cs_n(1'b1),
		.ctrl_we(ctrl_we),
		.stream_en(), .stream_port(), .stream_base(), .stream_words(), .stream_rowlen(), .stream_stride(),
		.stream_ready(), .stream_done_tog(1'b0), .stream_direct(), .stream_fdata(), .stream_fvalid(), .stream_frd(1'b0),
		.fill_end(fill_end), .prog_we(prog_we), .char_we(1'b0), .wdata(wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_ready(1'b1), .d_rdata(128'd0), .d_valid(1'b0), .d_calibrated(1'b1),
		.ctrl_rdata(ctrl_rdata), .prog_rdata(), .char_rdata(),
		.audio(audio), .audio_lr(audio_lr), .audio_lr_we(audio_lr_we),
		.px_valid(), .px_x(), .px_y(), .px_rgb(),
		.fbr_addr(18'd0), .fbr_req(1'b0), .fbr_rdata(), .fbr_ack(),
		.pclk(pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(vid_rgb)
	);

	// --- the yardstick: the core on its own, in step with the console's ---------------------
	reg  [7:0]  rom [0:262143];
	wire [17:0] r_addr;
	reg  [7:0]  r_data;
	always @(posedge clk) r_data <= rom[r_addr];
	wire [8:0]  r_px, r_py;
	wire        r_pen, r_fs;
	wire [11:0] r_c12;
	wire [15:0] r_pc;
	sms #(.ROM_AW(18), .GG(1)) u_ref (
		.clk(clk), .rst(dut.z80_rst), .ce(nes_ce && !dut.cpu_halt),
		.rom_addr(r_addr), .rom_data(r_data),
		.joy1(8'h00), .joy2(8'h00),
		.px(r_px), .py(r_py), .pixel_en(r_pen), .color(), .color12(r_c12),
		.frame_start(r_fs),
		.audio(), .audio_l(), .audio_r(),
		.dbg_pc(r_pc)
	);
	reg [11:0] rfb [0:160 * 144 - 1];
	always @(posedge clk)
		if (r_pen && nes_ce && r_px >= 9'd48 && r_px < 9'd208 && r_py >= 9'd24 && r_py < 9'd168)
			rfb[(r_py - 9'd24) * 160 + (r_px - 9'd48)] <= r_c12;

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
		input [15:0] idx;
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
	function [23:0] rgb12;                 // frame_hdmi FMT 4: the word is BBBBGGGGRRRR
		input [11:0] q;
		rgb12 = {q[3:0], q[3:0], q[7:4], q[7:4], q[11:8], q[11:8]};
	endfunction

	reg [1023:0] romfile;
	reg [11:0] c0, v;
	integer i, n, x, y, frames = 0, want_frames, size, bad, colours, lit, fd, rlit;
	initial begin
		if (!$value$plusargs("ROM%s", romfile)) romfile = "../../sim/roms/gg/test.hex";
		if (!$value$plusargs("FRAMES%d", want_frames)) want_frames = 70;
		if (!$value$plusargs("FAST%d", fast)) fast = 0;
		for (i = 0; i < 262144; i = i + 1) rom[i] = 8'hFF;
		$readmemh(romfile, rom);
		size = 0;
		for (i = 0; i < 262144; i = i + 1) if (rom[i] !== 8'hFF) size = i + 1;
		size = (size + 16383) / 16384 * 16384;
		for (i = 0; i < 160 * 144; i = i + 1) rfb[i] = 12'd0;
		$display("tb_con_gg: %0s, %0d kB, %0d frames, ce %0s", romfile, size / 1024, want_frames, fast ? "every other clock" : "the board's 5.37 MHz");

		repeat (8) @(posedge clk); rst = 0;
		repeat (8) @(posedge clk);
		// the menu: stop (0x04 bit 2 holds it), the ROM into NES_PRG, the console, run
		ctrl_write(16'h0004, 32'd4);
		for (i = 0; i < size; i = i + 4)
			prog_write(i >> 2, {rom[i + 3], rom[i + 2], rom[i + 1], rom[i]});
		bad = 0;
		for (i = 0; i < size; i = i + 4)
			if (dut.g_cart.u_cart.prog_mem[i >> 2] !== {rom[i + 3], rom[i + 2], rom[i + 1], rom[i]}) bad = bad + 1;
		check(bad == 0, "cart_mem holds the ROM word for word");
		ctrl_write(16'h0020, 32'd6);
		off <= 16'h0020; @(posedge clk); #1;
		check(ctrl_rdata[22] === 1'b1 && ctrl_rdata[3:0] === 4'd6,
		      "0x20 reads the Game Gear built (bit 22) and selected (6)");
		ctrl_write(16'h0004, 32'd1);

		while (frames < want_frames) begin
			@(posedge clk);
			if (dut.sms_frame_start) begin
				frames = frames + 1;
				if (frames % 10 == 0) $display("  frame %0d: console pc %04x (rom addr %05x), bare core pc %04x, display %0s / %0s",
					frames, dut.sms_pc, dut.sms_rom_addr, r_pc,
					dut.g_sms.u_sms.u_vdp.display_on ? "on" : "off", u_ref.u_vdp.display_on ? "on" : "off");
			end
		end
		@(posedge clk);
		$display("  %0d frames, console PC=%04x, bare core PC=%04x", frames, dut.sms_pc, r_pc);

		// the buffer HDMI reads: a picture, and the bare core's
		bad = 0; colours = 0; lit = 0; rlit = 0;
		c0 = dut.g_sms.g_ggfb.u_hdmi.fb[0];
		for (y = 0; y < 144; y = y + 1)
			for (x = 0; x < 160; x = x + 1) begin
				v = dut.g_sms.g_ggfb.u_hdmi.fb[y * 320 + x];
				if (v !== c0) colours = colours + 1;
				if (v !== 12'd0) lit = lit + 1;
				if (rfb[y * 160 + x] !== 12'd0) rlit = rlit + 1;
				if (v !== rfb[y * 160 + x]) begin
					if (bad < 8) $display("  FAIL buffer (%0d,%0d): %03x, the bare core's %03x", x, y, v, rfb[y * 160 + x]);
					bad = bad + 1;
				end
			end
		$display("  frame_hdmi's window: %0d of 23040 lit, %0d differ from (0,0); the bare core's: %0d lit", lit, colours, rlit);
		check(lit > 0 && colours > 0, "the window holds a picture (lit, not one colour)");
		check(bad == 0, "the window equals the bare core's, all 160 x 144");
		fd = $fopen("frame.ppm", "w");
		$fwrite(fd, "P3\n160 144\n15\n");
		for (y = 0; y < 144; y = y + 1) begin
			for (x = 0; x < 160; x = x + 1) begin
				v = dut.g_sms.g_ggfb.u_hdmi.fb[y * 320 + x];
				$fwrite(fd, "%0d %0d %0d ", v[3:0], v[7:4], v[11:8]);
			end
			$fwrite(fd, "\n");
		end
		$fclose(fd);

		// HDMI: 160 x 144 shown 480 x 432 from (80, 24)
		// (16 spread over the window, then the first 16 lit ones it holds)
		bad = 0; lit = 0; i = 0;
		for (n = 0; n < 32; n = n + 1) begin
			x = (n * 37 + 11) % 160; y = (n * 53 + 7) % 144;
			if (n >= 16) begin
				while (i < 160 * 144 && dut.g_sms.g_ggfb.u_hdmi.fb[(i / 160) * 320 + i % 160] === 12'd0) i = i + 1;
				if (i < 160 * 144) begin x = i % 160; y = i / 160; i = i + 1; end
			end
			hdmi_pixel(10'd80 + 3 * x + n % 3, 10'd24 + 3 * y + (n + 1) % 3);
			if (got_rgb !== 24'd0) lit = lit + 1;
			if (got_rgb !== rgb12(dut.g_sms.g_ggfb.u_hdmi.fb[y * 320 + x])) begin
				if (bad < 8) $display("  FAIL HDMI (%0d,%0d) for picture (%0d,%0d): %06x, want %06x", 80 + 3 * x + n % 3, 24 + 3 * y + (n + 1) % 3, x, y,
					got_rgb, rgb12(dut.g_sms.g_ggfb.u_hdmi.fb[y * 320 + x]));
				bad = bad + 1;
			end
		end
		$display("  HDMI: %0d of 32 sampled pixels lit", lit);
		check(bad == 0, "32 pixels read through the HDMI port are the window's, tripled");
		check(lit > 0, "and some of them are not black");
		hdmi_pixel(10'd79, 10'd200);  check(got_rgb === 24'd0, "black left of the picture (x 79)");
		hdmi_pixel(10'd560, 10'd200); check(got_rgb === 24'd0, "black right of it (x 560)");
		hdmi_pixel(10'd300, 10'd23);  check(got_rgb === 24'd0, "black above it (y 23)");
		hdmi_pixel(10'd300, 10'd456); check(got_rgb === 24'd0, "black below it (y 456)");

		$display("");
		if (fails == 0) $display("tb_con_gg: all checks passed (frame.ppm)");
		else            $display("tb_con_gg: %0d FAIL(s)", fails);
		$finish;
	end
endmodule
`default_nettype wire
