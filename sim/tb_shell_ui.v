//////////////////////////////////////////////////////////////////////////////////
// tb_shell_ui - the menu image's composer (rtl/shell_ui.v) against its reference: the memories
// of a list tools/menu/ui_model.cpp built (a home screen: the real fonts and logos) loaded as the
// ESP32 would leave them, a frame scanned as hdmi_tx scans it, every pixel compared with the
// model's expected.ppm. Also: no line overran its time.
//
//   g++ -O2 -std=c++17 -Iesp32/console tools/menu/ui_model.cpp -o build/ui_model.exe
//   build/ui_model.exe build/menu_logos build/ui_test
//   ./tools/sim.sh tb_shell_ui                   (actual.ppm in its run directory)
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_shell_ui;
	reg clk = 0, pclk = 0, pclk5 = 0;
	always #10 clk = ~clk;
	always #4 pclk5 = ~pclk5;              // 125 MHz here (8 ns), and
	always #20 pclk = ~pclk;               // the pixel clock a fifth of it, edges together
	reg rst = 1, we = 0; reg [19:0] addr = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata;
	reg [9:0] x = 0, y = 520;
	wire [23:0] rgb;
	shell_ui dut (.clk(clk), .rst(rst), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
		.pclk(pclk), .pclk5(pclk5), .x(x), .y(y), .rgb(rgb));

	// hdmi_tx's scan: x across 800, y down 525; rgb is the pixel asked for a clock before
	reg [9:0] xd, yd;
	always @(posedge pclk) begin
		xd <= x; yd <= y;
		if (x == 10'd799) begin x <= 10'd0; y <= (y == 10'd524) ? 10'd0 : y + 10'd1; end
		else x <= x + 10'd1;
	end

	integer worst = 0;
	reg [7:0] expv [0:921599];
	reg [23:0] got [0:307199];
	integer fd, i, fails = 0, frames = 0, n;
	reg [8*20-1:0] hdr;
	initial begin
		$readmemh("../../build/ui_test/obj0.hex", dut.obj0); $readmemh("../../build/ui_test/obj1.hex", dut.obj1);
		$readmemh("../../build/ui_test/obj2.hex", dut.obj2); $readmemh("../../build/ui_test/obj3.hex", dut.obj3);
		$readmemh("../../build/ui_test/str0.hex", dut.str0); $readmemh("../../build/ui_test/str1.hex", dut.str1);
		$readmemh("../../build/ui_test/str2.hex", dut.str2); $readmemh("../../build/ui_test/str3.hex", dut.str3);
		$readmemh("../../build/ui_test/gly0.hex", dut.gly0); $readmemh("../../build/ui_test/gly1.hex", dut.gly1);
		$readmemh("../../build/ui_test/fnt.hex", dut.fnt); $readmemh("../../build/ui_test/img.hex", dut.img);
		$readmemh("../../build/ui_test/asc.hex", dut.asc);
		// the expected picture: the PPM's bytes after its 15-byte header ("P6\n640 480\n255\n")
		fd = $fopen("../../build/ui_test/expected.ppm", "rb");
		for (i = 0; i < 15; i = i + 1) n = $fgetc(fd);
		for (i = 0; i < 921600; i = i + 1) expv[i] = $fgetc(fd);
		$fclose(fd);
		dut.ever = 1'b1;                       // (the ESP32's list: not the built-in picture's bar widths)
		repeat (4) @(posedge clk); rst = 0;
		@(negedge clk); addr = 20'h90004; wdata = 1; we = 1; @(negedge clk); we = 0;
		// a frame from its first line
		wait (y == 10'd0 && x == 10'd0);
		// (the clock that takes the request (0, 0) is the one rgb answers it after)
		while (!(yd == 10'd479 && xd == 10'd639)) begin
			@(posedge pclk); #1;
			if (yd < 480 && xd < 640) got[yd * 640 + xd] = rgb;
		end
		for (i = 0; i < 307200; i = i + 1)
			if (got[i] !== {expv[3 * i], expv[3 * i + 1], expv[3 * i + 2]}) begin
				fails = fails + 1;
				if (fails <= 12) $display("FAIL pixel %0d,%0d: %06x, want %02x%02x%02x", i % 640, i / 640, got[i], expv[3 * i], expv[3 * i + 1], expv[3 * i + 2]);
			end
		fd = $fopen("actual.ppm", "wb");
		$fwrite(fd, "P6\n640 480\n255\n");
		for (i = 0; i < 307200; i = i + 1) $fwrite(fd, "%c%c%c", got[i][23:16], got[i][15:8], got[i][7:0]);
		$fclose(fd);
		if (dut.overrun) begin fails = fails + 1; $display("FAIL: a line was not finished in time"); end
		$display("  the busiest line took %0d of its 4760 clocks", worst);
		$display("  %0d of 307200 pixels differ", fails);
		if (fails == 0) $display("tb_shell_ui: PASS"); else $display("tb_shell_ui: FAIL (%0d)", fails);
		$finish;
	end
	// the slowest line (clocks of pclk5)
	always @(posedge pclk5) if (!dut.busy && dut.budget > worst) worst = dut.budget;
endmodule
