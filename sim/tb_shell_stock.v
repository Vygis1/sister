//////////////////////////////////////////////////////////////////////////////////
// tb_shell_stock - the menu image's built-in picture (before the ESP32 draws): shell_ui's list in
// its bitstream (the background, a panel, the progress bar) with shell_screen's text over it,
// see-through, mid-install as tb_shell_screen has it. One frame into build/shell_stock.ppm.
//
//   ./tools/sim.sh tb_shell_stock
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
`default_nettype none
module tb_shell_stock;
	reg clk = 0, pclk = 0, pclk5 = 0, rst = 1;
	always #10 clk = ~clk;
	always #4 pclk5 = ~pclk5;
	always #20 pclk = ~pclk;
	reg [9:0] x = 0, y = 520;
	always @(posedge pclk) begin
		if (x == 10'd799) begin x <= 10'd0; y <= (y == 10'd524) ? 10'd0 : y + 10'd1; end
		else x <= x + 10'd1;
	end
	wire [23:0] bg, rgb; wire [9:0] pw; wire pon, gfx;
	shell_ui u_ui (.clk(clk), .rst(rst), .we(1'b0), .addr(20'd0), .wdata(32'd0), .rdata(),
		.pclk(pclk), .pclk5(pclk5), .x(x), .y(y), .rgb(bg), .prog_w(pw), .prog_on(pon), .gfx(gfx));
	reg op_start = 0; reg [1:0] op = 0; reg [22:0] offset = 0;
	shell_screen u_scr (.clk(clk), .rst(rst), .op_start(op_start), .op(op), .offset(offset), .boot_go(1'b0),
		.ext_we(1'b0), .ext_off(16'd0), .ext_wdata(32'd0), .ext_rdata(),
		.pclk(pclk), .x(x), .y(y), .bg(bg), .rgb(rgb), .prog_w(pw), .bar_shown(pon), .gfx(gfx));
	integer i, f, n = 0;
	task go; input [1:0] o; input [22:0] a; begin @(posedge clk); op <= o; offset <= a; op_start <= 1; @(posedge clk); op_start <= 0; end endtask
	initial begin
		repeat (4) @(posedge clk); rst <= 0;
		repeat (4) @(posedge clk);
		for (i = 0; i < 41; i = i + 1) go(2'd1, i * 65536);
		for (i = 0; i < 20 * 256; i = i + 1) go(2'd2, i * 256);
	end
	reg [9:0] xd, yd; reg cap = 0, done = 0;
	always @(posedge pclk) begin
		xd <= x; yd <= y;
		if (x == 0 && y == 0 && !cap && !done && $time > 4000000) begin
			cap <= 1; f = $fopen("../../build/shell_stock.ppm", "w"); $fwrite(f, "P3\n640 480\n255\n");
		end
		if (cap && xd < 640 && yd < 480) begin
			$fwrite(f, "%0d %0d %0d\n", rgb[23:16], rgb[15:8], rgb[7:0]); n = n + 1;
			if (n == 640 * 480) begin $fclose(f); cap <= 0; done <= 1; $display("tb_shell_stock: frame written (bar %0d of 420)", pw); $finish; end
		end
	end
endmodule
`default_nettype wire
