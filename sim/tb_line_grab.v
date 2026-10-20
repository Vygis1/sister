// tb_line_grab - line_grab.v takes the line asked for, pixel for pixel, from an hdmi_tx-shaped
// source (rgb a clock after req, 800 x 525 with 640 x 480 shown): the pixel's value is made of its
// own x and y, so every word read back can be checked.
`timescale 1ns/1ps
module tb_line_grab;
	reg clk = 0, pclk = 0;
	always #5 clk = ~clk;
	always #20 pclk = ~pclk;
	reg [9:0] hc = 0, vc = 0;
	reg [9:0] x = 0, y = 0; reg req = 0;
	always @(posedge pclk) begin
		hc <= (hc == 799) ? 0 : hc + 1;
		if (hc == 799) vc <= (vc == 524) ? 0 : vc + 1;
		req <= hc < 640 && vc < 480; x <= hc; y <= vc;
	end
	// the pixel at (x, y) next clock: r = y, g = x low, b = x high
	reg [23:0] rgb = 0;
	always @(posedge pclk) rgb <= {y[7:0], x[7:0], {6'd0, x[9:8]}};
	function [15:0] p565(input [9:0] px, input [9:0] py);
		reg [23:0] c; begin c = {py[7:0], px[7:0], {6'd0, px[9:8]}}; p565 = {c[23:19], c[15:10], c[7:3]}; end
	endfunction

	reg go = 0; reg [9:0] go_y = 0; reg [8:0] idx = 0;
	wire [31:0] data; wire done;
	line_grab dut (.clk(clk), .go(go), .go_y(go_y), .rd_idx(idx), .rd_data(data), .done(done),
		.pclk(pclk), .vid_x(x), .vid_y(y), .vid_req(req), .vid_rgb(rgb));

	integer bad = 0, k, line, n;
	reg [31:0] want;
	initial begin
		for (n = 0; n < 3; n = n + 1) begin
			line = (n == 0) ? 0 : (n == 1) ? 237 : 479;
			@(posedge clk); go_y <= line; go <= 1; @(posedge clk); go <= 0;
			@(posedge clk);
			if (done) begin $display("FAIL: done straight after go"); bad = bad + 1; end
			wait (done);
			for (k = 0; k < 320; k = k + 1) begin
				@(posedge clk) idx <= k; @(posedge clk); @(posedge clk);
				want = {p565(2 * k + 1, line), p565(2 * k, line)};
				if (data !== want) begin
					if (bad < 8) $display("FAIL: line %0d word %0d = %h, want %h", line, k, data, want);
					bad = bad + 1;
				end
			end
		end
		if (bad == 0) $display("PASS: three lines, 320 words each, exact");
		else $display("FAIL: %0d words wrong", bad);
		$finish;
	end
	initial begin #200_000_000; $display("FAIL: timeout"); $finish; end
endmodule
