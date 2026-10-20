//////////////////////////////////////////////////////////////////////////////////
// tb_shell_fb - the menu's picture (rtl/shell_fb.v): a fill, then a rectangle of packed pixels
// at an odd place (eight pixels to three words, rows wrapping), then every pixel read back
// through the picture side against a model.
//
//   ./tools/sim.sh tb_shell_fb
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_shell_fb;
	reg clk = 0, pclk = 0;
	always #10 clk = ~clk;
	always #19.8 pclk = ~pclk;
	reg rst = 1, we = 0; reg [15:0] off = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; reg [9:0] x = 0, y = 0; wire [23:0] rgb;
	shell_fb dut (.clk(clk), .rst(rst), .we(we), .off(off), .wdata(wdata), .rdata(rdata), .pclk(pclk), .x(x), .y(y), .rgb(rgb));

	reg [11:0] model [0:307199];
	integer i, j, k, fails = 0;
	task wr(input [15:0] a, input [31:0] d); begin @(negedge clk); off = a; wdata = d; we = 1; @(negedge clk); we = 0; repeat (40) @(negedge clk); end endtask
	task busy_wait; begin off = 16'h001C; #1; while (rdata[0]) begin @(negedge clk); off = 16'h001C; #1; end end endtask

	// a rectangle of pixels: colour = f(i, j)
	localparam RX = 101, RY = 33, RW = 13, RH = 7;
	function [11:0] colour; input integer xx, yy; colour = (xx * 37 + yy * 101 + 5) & 12'hFFF; endfunction
	reg [95:0] grp; integer n, w;
	// a pixel's colour with the highlight's table entry `idx` (alpha 16 idx, white) over the fill
	function [7:0] mx; input [7:0] d; input [7:0] a; reg [16:0] t; begin t = {1'b0, d, 8'd0} + 255 * a - d * a; mx = t[15:8]; end endfunction
	task check_hl(input integer xx, input integer yy, input integer idx); reg [7:0] a; reg [23:0] want; begin
		a = 16 * idx; want = {mx(model[yy * 640 + xx][11:8] * 17, a), mx(model[yy * 640 + xx][7:4] * 17, a), mx(model[yy * 640 + xx][3:0] * 17, a)};
		@(negedge pclk); x = xx; y = yy; @(negedge pclk); #1;
		if (rgb !== want) begin fails = fails + 1; $display("FAIL highlight at %0d,%0d: %06x, want %06x (entry %0d)", xx, yy, rgb, want, idx); end
		else $display("  highlight at %0d,%0d: entry %0d", xx, yy, idx);
	end endtask
	initial begin
		repeat (4) @(negedge clk); rst = 0;
		off = 16'h0000; #1; if (rdata !== 32'h46423031) begin fails = fails + 1; $display("FAIL id %08x", rdata); end
		// the whole screen one colour
		wr(16'h0010, 32'd0); wr(16'h0014, {6'd0, 10'd480, 6'd0, 10'd640}); wr(16'h0018, 32'h00000123);
		busy_wait;
		for (k = 0; k < 307200; k = k + 1) model[k] = 12'h123;
		// the rectangle, packed
		wr(16'h0010, {6'd0, 10'd33, 6'd0, 10'd101}); wr(16'h0014, {6'd0, 10'd7, 6'd0, 10'd13});
		n = 0;
		for (j = 0; j < RH; j = j + 1) for (i = 0; i < RW; i = i + 1) begin
			grp[12 * (n % 8) +: 12] = colour(RX + i, RY + j);
			model[(RY + j) * 640 + RX + i] = colour(RX + i, RY + j);
			n = n + 1;
			if (n % 8 == 0) for (w = 0; w < 3; w = w + 1) wr(16'h1000 + 4 * w, grp[32 * w +: 32]);
		end
		// (91 pixels: the last group's 3 extra pixels wrap to the rectangle's top-left -- write them as they are there)
		while (n % 8 != 0) begin
			k = n % (RW * RH);
			grp[12 * (n % 8) +: 12] = colour(RX + k % RW, RY + k / RW);
			n = n + 1;
		end
		for (w = 0; w < 3; w = w + 1) wr(16'h1000 + 4 * w, grp[32 * w +: 32]);
		busy_wait;
		wr(16'h0004, 32'd1);                    // on
		// read back the picture around the rectangle (and some of the fill)
		for (j = RY - 2; j < RY + RH + 2; j = j + 1) for (i = RX - 2; i < RX + RW + 2; i = i + 1) begin
			@(negedge pclk); x = i; y = j;
			@(negedge pclk); #1;
			if (rgb !== {model[j * 640 + i][11:8], model[j * 640 + i][11:8], model[j * 640 + i][7:4], model[j * 640 + i][7:4], model[j * 640 + i][3:0], model[j * 640 + i][3:0]}) begin
				fails = fails + 1;
				if (fails < 10) $display("FAIL at %0d,%0d: %06x, want %03x", i, j, rgb, model[j * 640 + i]);
			end
		end
		// the highlight: x 100 y 50, 60 x 40, radius 8; table k: alpha 16k, white; corners (r+k-3)^2
		wr(16'h0020, {6'd0, 10'd50, 6'd0, 10'd100}); wr(16'h0024, {6'd0, 10'd40, 6'd0, 10'd60});
		for (k = 0; k < 16; k = k + 1) wr(16'h0040 + 4 * k, 16 * k);
		for (k = 0; k < 14; k = k + 1) wr(16'h0080 + 4 * k, (8 + k - 3) * (8 + k - 3));
		wr(16'h0028, {19'd0, 5'd8, 7'd0, 1'b1});
		check_hl(130, 70, 0); check_hl(100, 70, 4); check_hl(95, 70, 9); check_hl(100, 50, 7); check_hl(300, 300, 15);
		if (fails == 0) $display("tb_shell_fb: PASS"); else $display("tb_shell_fb: FAIL (%0d)", fails);
		$finish;
	end
endmodule
