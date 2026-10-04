//////////////////////////////////////////////////////////////////////////////////
// tb_frame_hdmi - frame_hdmi.v behind hdmi_tx (SIM), both formats at once: a Master
// System picture (256 x 192, 6-bit) and a Mega Drive one (320 x 224, 9-bit) are
// written into their frames, and every pixel of the 640 x 480 picture hdmi_tx asks
// for must be its source pixel doubled, centred, in 24-bit colour -- black around it.
//
//   ./tools/sim.sh tb_frame_hdmi
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_frame_hdmi;
	reg clk = 0, pclk = 0;
	always #10 clk = ~clk;                     // 50 MHz
	always #20 pclk = ~pclk;                   // 25 MHz, unrelated phase
	wire [9:0] x, y; wire req;
	hdmi_tx #(.SIM(1)) u_tx (.clk50(1'b0), .rst(1'b0), .sim_pclk(pclk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0),
		.pclk(), .x(x), .y(y), .req(req), .rgb(24'd0), .frame_start(), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(16'd0), .aud_r(16'd0), .aud_tog(1'b0));

	function [5:0] s6; input [8:0] px, py; s6 = px[5:0] ^ {py[2:0], py[5:3]}; endfunction
	function [8:0] m9; input [8:0] px, py; m9 = {px[8:0]} ^ {py[4:0], py[8:5]} ^ 9'h0A5; endfunction

	reg we = 0; reg [8:0] wx = 0, wy = 0;
	wire [23:0] rgb_s, rgb_m;
	frame_hdmi #(.FMT(1), .DW(6)) u_s (.clk(clk), .we(we), .wx(wx), .wy(wy), .wd(s6(wx, wy)), .w(9'd256), .h(9'd192),
		.pclk(pclk), .x(x), .y(y), .req(req), .rgb(rgb_s));
	frame_hdmi #(.FMT(2), .DW(9)) u_m (.clk(clk), .we(we), .wx(wx), .wy(wy), .wd(m9(wx, wy)), .w(9'd320), .h(9'd224),
		.pclk(pclk), .x(x), .y(y), .req(req), .rgb(rgb_m));

	integer i, j;
	initial begin
		for (j = 0; j < 240; j = j + 1)
			for (i = 0; i < 320; i = i + 1) begin
				@(posedge clk); we <= 1'b1; wx <= i; wy <= j;
			end
		@(posedge clk); we <= 1'b0;
	end

	function [23:0] e6; input [5:0] c; e6 = {{4{c[1:0]}}, {4{c[3:2]}}, {4{c[5:4]}}}; endfunction
	function [23:0] e9; input [8:0] c; e9 = {c[2:0], c[2:0], c[2:1], c[5:3], c[5:3], c[5:4], c[8:6], c[8:6], c[8:7]}; endfunction

	// the pixel hdmi_tx asked for a clock ago
	reg [9:0] x1, y1; reg r1;
	always @(posedge pclk) begin x1 <= x; y1 <= y; r1 <= req; end
	integer errors = 0, checked = 0, frames = 0;
	reg [23:0] ws, wm;
	always @(posedge pclk) if (x == 10'd0 && y == 10'd0 && req) frames = frames + 1;
	always @(posedge pclk) if (r1 && frames >= 2) begin
		// Master System: 512 x 384 from (64, 48)
		ws = (x1 >= 64 && x1 < 576 && y1 >= 48 && y1 < 432) ? e6(s6((x1 - 64) >> 1, (y1 - 48) >> 1)) : 24'd0;
		// Mega Drive: 640 x 448 from (0, 16)
		wm = (y1 >= 16 && y1 < 464) ? e9(m9(x1 >> 1, (y1 - 16) >> 1)) : 24'd0;
		checked = checked + 1;
		if (rgb_s !== ws || rgb_m !== wm) begin
			errors = errors + 1;
			if (errors < 8) $display("tb_frame_hdmi: (%0d,%0d) SMS %06x want %06x, MD %06x want %06x", x1, y1, rgb_s, ws, rgb_m, wm);
		end
	end
	initial begin
		#(800 * 525 * 40 * 3);
		$display("tb_frame_hdmi: %0d pixels checked, %0d wrong", checked, errors);
		if (errors == 0 && checked >= 307200) $display("tb_frame_hdmi: all checks passed"); else $display("tb_frame_hdmi: FAIL");
		$finish;
	end
endmodule

`default_nettype wire
