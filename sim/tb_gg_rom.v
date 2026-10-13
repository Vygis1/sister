//////////////////////////////////////////////////////////////////////////////////
// tb_gg_rom - a real Game Gear program (sim/roms/gg/test.hex, kept out of the tree) on the
// core for CLOCKS clocks, the LCD's 160 x 144 window of the last frame written as a PPM
// (build/sim-tb_gg_rom/frame.ppm) to look at, and the whole 256 x 240 picture as full.ppm.
// A yardstick, not a gate: it reports what the program did (display on, palette entries
// written, frames, lit pixels) and never fails.
//   ./tools/sim.sh tb_gg_rom
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns / 1ps
module tb_gg_rom;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	reg ph = 0;
	always @(posedge clk) ph <= ~ph;
	wire ce = ph;
	wire [17:0] rom_addr;
	reg  [7:0]  rom_data;
	wire [8:0]  px, py;
	wire        pixel_en, frame_start;
	wire [5:0]  color;
	wire [11:0] color12;
	wire [15:0] audio;
	wire signed [15:0] audio_l, audio_r;
	wire [15:0] dbg_pc;
	reg  [7:0]  joy1 = 8'h00;
	sms #(.ROM_AW(18), .GG(1)) dut (
		.clk(clk), .rst(rst), .ce(ce),
		.rom_addr(rom_addr), .rom_data(rom_data),
		.joy1(joy1), .joy2(8'h00),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color), .color12(color12),
		.frame_start(frame_start),
		.audio(audio), .audio_l(audio_l), .audio_r(audio_r),
		.dbg_pc(dbg_pc)
	);
	reg [7:0] rom [0:262143];
	always @(posedge clk) rom_data <= rom[rom_addr];
	// the picture: the Master System's 256 x 240 at most; the Gear shows 160 x 144 of it
	reg [11:0] fb [0:256*240-1];
	reg [8:0]  hmax = 9'd192, hcur = 9'd0;
	integer frames = 0, cram_writes = 0, lit = 0, i, fd, x, y, y0;
	always @(posedge clk) begin
		if (pixel_en && ce && py < 9'd240) begin fb[py * 256 + px] <= color12; if (py > hcur) hcur <= py; end
		if (frame_start) begin frames = frames + 1; hmax <= hcur + 9'd1; hcur <= 9'd0; end
		if (dut.u_vdp.vcode == 2'b11 && dut.cpu_io && dut.cpu_we && dut.cpu_ce && dut.cpu_addr[7:0] == 8'hBE) cram_writes = cram_writes + 1;
	end
	integer CLOCKS = 12_000_000;
	initial begin
		for (i = 0; i < 262144; i = i + 1) rom[i] = 8'hFF;
		$readmemh("../../sim/roms/gg/test.hex", rom);
		for (i = 0; i < 256*240; i = i + 1) fb[i] = 12'd0;
		if ($value$plusargs("CLOCKS=%d", CLOCKS)) ;
		repeat (8) @(posedge clk); rst = 0;
		repeat (CLOCKS) @(posedge clk);
		// the window: columns 48..207, rows centred in the picture's height
		y0 = (hmax >= 9'd144) ? (hmax - 9'd144) / 2 : 0;
		fd = $fopen("frame.ppm", "w");
		$fwrite(fd, "P3\n160 144\n15\n");
		for (y = 0; y < 144; y = y + 1) begin
			for (x = 0; x < 160; x = x + 1)
				$fwrite(fd, "%0d %0d %0d ", fb[(y + y0) * 256 + x + 48][3:0], fb[(y + y0) * 256 + x + 48][7:4], fb[(y + y0) * 256 + x + 48][11:8]);
			$fwrite(fd, "\n");
		end
		$fclose(fd);
		// the whole picture too, and how much of it is lit
		fd = $fopen("full.ppm", "w");
		$fwrite(fd, "P3\n256 240\n15\n");
		for (y = 0; y < 240; y = y + 1) begin
			for (x = 0; x < 256; x = x + 1) begin
				$fwrite(fd, "%0d %0d %0d ", fb[y * 256 + x][3:0], fb[y * 256 + x][7:4], fb[y * 256 + x][11:8]);
				if (fb[y * 256 + x] != 12'd0) lit = lit + 1;
			end
			$fwrite(fd, "\n");
		end
		$fclose(fd);
		$display("tb_gg_rom: %0d lit pixels of 256 x 240; palette entry 0 = %03x, 1 = %03x, 16 = %03x", lit, dut.u_vdp.cram12[0], dut.u_vdp.cram12[1], dut.u_vdp.cram12[16]);
		$display("tb_gg_rom: %0d clocks, %0d frames, picture %0d lines high, %0d palette bytes written, display %0s, pc %04x",
		         CLOCKS, frames, hmax, cram_writes, dut.u_vdp.display_on ? "on" : "off", dbg_pc);
		$display("tb_gg_rom: done (frame.ppm, full.ppm)");
		$finish;
	end
endmodule
`default_nettype wire
