//////////////////////////////////////////////////////////////////////////////////
// tb_shell_screen - shell_screen.v mid-install (a 2.6 MB core erased, half written):
// one frame of its picture into build/shell_screen.ppm, to look at.
//
//   ./tools/sim.sh tb_shell_screen
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none
module tb_shell_screen;
	reg clk = 0, pclk = 0, rst = 1;
	always #10 clk = ~clk;
	always #20 pclk = ~pclk;
	wire [9:0] x, y; wire req; wire [23:0] rgb; wire fs;
	hdmi_tx #(.SIM(1)) u_tx (.clk50(1'b0), .rst(1'b0), .sim_pclk(pclk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0),
		.pclk(), .x(x), .y(y), .req(req), .rgb(24'd0), .frame_start(fs), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(16'd0), .aud_r(16'd0), .aud_tog(1'b0));
	reg op_start = 0; reg [1:0] op = 0; reg [22:0] offset = 0;
	shell_screen dut (.clk(clk), .rst(rst), .op_start(op_start), .op(op), .offset(offset), .boot_go(1'b0),
		.pclk(pclk), .x(x), .y(y), .rgb(rgb));
	integer i, f, n = 0;
	task go; input [1:0] o; input [22:0] a; begin @(posedge clk); op <= o; offset <= a; op_start <= 1; @(posedge clk); op_start <= 0; end endtask
	initial begin
		repeat (4) @(posedge clk); rst <= 0;
		repeat (4) @(posedge clk);
		// as installCard does it: every sector erased, then each written and read back
		// (sector 3 erased again and redone), stopping half way: 20 of 41 sectors
		for (i = 0; i < 41; i = i + 1) go(2'd1, i * 65536);
		for (i = 0; i < 20 * 256; i = i + 1) begin
			go(2'd2, i * 256);
			if (i % 256 == 255) begin : chk
				integer k;
				for (k = i - 255; k <= i; k = k + 1) go(2'd3, 23'h200000 + k * 256);
				if (i / 256 == 3) begin go(2'd1, 3 * 65536); end
			end
		end
	end
	reg [9:0] x1, y1; reg r1;
	always @(posedge pclk) begin x1 <= x; y1 <= y; r1 <= req; end
	reg cap = 0, done = 0;
	always @(posedge pclk) begin
		if (fs && !cap && !done && $time > 2000000) begin cap <= 1; f = $fopen("../../build/shell_screen.ppm", "w"); $fwrite(f, "P3\n640 480\n255\n"); end
		if (cap && r1) begin $fwrite(f, "%0d %0d %0d\n", rgb[23:16], rgb[15:8], rgb[7:0]); n = n + 1;
			if (n == 640 * 480) begin $fclose(f); cap <= 0; done <= 1; $display("tb_shell_screen: frame written; phase %0d size %0d pos %0d", dut.phase, dut.size, dut.pos); $finish; end end
	end
endmodule
`default_nettype wire
