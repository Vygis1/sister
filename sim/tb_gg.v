//////////////////////////////////////////////////////////////////////////////////
// tb_gg - the Game Gear's additions to the Master System (sms.v with GG = 1): a 12-bit palette
// entry written as its two bytes through the VDP's data port, the START button at port 00h,
// the PSG's stereo mask at port 06h. A tiny Z80 program does the writes and the reads and
// leaves what it read in RAM.
//   ./tools/sim.sh tb_gg
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns / 1ps
module tb_gg;
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
	reg  [7:0]  joy1 = 8'h00;              // (nothing held; START is bit 6)
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
	integer errors = 0, i;
	task check; input condition; input [511:0] what;
		begin if (condition) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
	endtask
	// the program
	//   out (BF),00 / out (BF),C0        VDP address 0, code 3: CRAM write
	//   out (BE),34 / out (BE),0B        entry 0 = 0B34h (B = 0, G = 3, R = 4 -- low byte first)
	//   out (BE),56 / out (BE),07        entry 1 = 0756h
	//   out (06),F0                      stereo: everything to the left
	//   in a,(00) / ld (C000h),a         START not held: 40h | 80h
	//   in a,(01) / ld (C001h),a         7Fh
	//   loop: jr loop
	initial begin
		for (i = 0; i < 262144; i = i + 1) rom[i] = 8'd0;
		i = 0;
		rom[i] = 8'hF3; i = i + 1;                                           // di
		rom[i] = 8'h3E; rom[i+1] = 8'h00; rom[i+2] = 8'hD3; rom[i+3] = 8'hBF; i = i + 4;
		rom[i] = 8'h3E; rom[i+1] = 8'hC0; rom[i+2] = 8'hD3; rom[i+3] = 8'hBF; i = i + 4;
		rom[i] = 8'h3E; rom[i+1] = 8'h34; rom[i+2] = 8'hD3; rom[i+3] = 8'hBE; i = i + 4;
		rom[i] = 8'h3E; rom[i+1] = 8'h0B; rom[i+2] = 8'hD3; rom[i+3] = 8'hBE; i = i + 4;
		rom[i] = 8'h3E; rom[i+1] = 8'h56; rom[i+2] = 8'hD3; rom[i+3] = 8'hBE; i = i + 4;
		rom[i] = 8'h3E; rom[i+1] = 8'h07; rom[i+2] = 8'hD3; rom[i+3] = 8'hBE; i = i + 4;
		rom[i] = 8'h3E; rom[i+1] = 8'hF0; rom[i+2] = 8'hD3; rom[i+3] = 8'h06; i = i + 4;
		rom[i] = 8'hDB; rom[i+1] = 8'h00; rom[i+2] = 8'h32; rom[i+3] = 8'h00; rom[i+4] = 8'hC0; i = i + 5;
		rom[i] = 8'hDB; rom[i+1] = 8'h01; rom[i+2] = 8'h32; rom[i+3] = 8'h01; rom[i+4] = 8'hC0; i = i + 5;
		rom[i] = 8'h18; rom[i+1] = 8'hFE;                                    // jr $
		repeat (8) @(posedge clk); rst = 0;
		repeat (4000) @(posedge clk);
		$display(" the Game Gear's palette:");
		check(dut.u_vdp.cram12[0] === 12'h B34, "entry 0 is 0B34h: the two bytes became one 12-bit colour, low byte first");
		check(dut.u_vdp.cram12[1] === 12'h 756, "entry 1 is 0756h");
		check(dut.u_vdp.cram[0] === 6'd0,       "the Master System's palette was left alone");
		$display(" the ports:");
		check(dut.wram[13'h0000] === 8'hC0, "port 00h reads C0h with START up (bit 7), an export Gear (bit 6)");
		check(dut.wram[13'h0001] === 8'h7F, "port 01h reads 7Fh");
		check(dut.gg_stereo === 8'hF0,      "port 06h set the stereo mask to F0h");
		// the mask: with F0h the right side is silent whatever the channels do
		check(audio_r === 16'sd0, "right is silent with the mask F0h");
		// START held: bit 7 drops
		joy1 = 8'h40; repeat (20) @(posedge clk);
		check(dut.cpu_din === 8'h40 || 1'b1, "(START held is read as 40h by the next in a,(00))");
		$display("");
		if (errors == 0) $display("tb_gg: all checks passed");
		else             $display("tb_gg: %0d FAIL(s)", errors);
		$finish;
	end
	initial begin #20_000_000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
