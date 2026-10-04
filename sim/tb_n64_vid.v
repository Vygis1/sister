//////////////////////////////////////////////////////////////////////////////////
// tb_n64_vid - n64_vid.v behind hdmi_tx (SIM): the fetch side is modelled here --
// whenever the pixel side wants a new source line, that line of a 320x240 RGBA5551
// test picture is written into the buffer as RDRAM's lines arrive (16 bytes a word,
// byte k of the word at bits 8k+7:8k, each pixel big-endian) -- and every pixel of
// the 640x480 picture hdmi_tx asks for must be its source pixel, doubled, in RGB888.
//
//   ./tools/sim.sh tb_n64_vid
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_vid;
	reg clk = 0, pclk = 0;
	always #10 clk = ~clk;                     // 50 MHz
	always #20 pclk = ~pclk;                   // 25 MHz, unrelated phase
	wire [9:0] x, y; wire req; wire [23:0] rgb;
	hdmi_tx #(.SIM(1)) u_tx (.clk50(1'b0), .rst(1'b0), .sim_pclk(pclk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0),
		.pclk(), .x(x), .y(y), .req(req), .rgb(rgb), .frame_start(), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(),
		.sym_0(), .sym_1(), .sym_2());

	reg wr_en = 0; reg [7:0] wr_addr = 0; reg [127:0] wr_data = 0;
	wire [8:0] want;
	n64_vid dut (.clk(clk), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .want(want),
		.width(12'd320), .bpp32(1'b0), .on(1'b1), .pclk(pclk), .x(x), .y(y), .req(req), .rgb(rgb));

	function [15:0] src; input [8:0] ly; input [9:0] lx; src = {lx[4:0] ^ ly[4:0], lx[9:5] + ly[4:0], ly[7:3], lx[0]}; endfunction
	function [23:0] to888; input [15:0] p; to888 = {p[15:11], p[15:13], p[10:6], p[10:8], p[5:1], p[5:3]}; endfunction

	// the fetch side: a new wanted line -> its 40 words, a word every few clocks
	reg [8:0] have = 9'h1FF; integer k, j;
	always @(posedge clk) begin
		wr_en <= 1'b0;
		if (want != have && want < 9'd240) begin : fetch
			reg [127:0] w;
			have <= want;
			for (k = 0; k < 40; k = k + 1) begin
				for (j = 0; j < 8; j = j + 1) begin
					// pixel 8k+j: bytes 2j (high) and 2j+1 (low) of the word
					w[8 * (2 * j) +: 8]     = src(want, 8 * k + j) >> 8;
					w[8 * (2 * j + 1) +: 8] = src(want, 8 * k + j);
				end
				@(posedge clk); wr_en <= 1'b1; wr_addr <= {want[0], k[6:0]}; wr_data <= w;
				@(posedge clk); wr_en <= 1'b0;
			end
		end
	end

	// check: the pixel hdmi_tx asked for a clock ago
	reg [9:0] x1, y1; reg r1;
	always @(posedge pclk) begin x1 <= x; y1 <= y; r1 <= req; end
	integer errors = 0, checked = 0, frames = 0;
	// (the first frame starts with no blanking before it, so its first line was never fetched)
	always @(posedge pclk) if (x == 10'd0 && y == 10'd0 && req) frames = frames + 1;
	always @(posedge pclk) if (r1 && frames >= 2) begin
		checked = checked + 1;
		if (rgb !== to888(src(y1[9:1], {1'b0, x1[9:1]}))) begin
			errors = errors + 1;
			if (errors < 8) $display("tb_n64_vid: (%0d,%0d) got %06x want %06x", x1, y1, rgb, to888(src(y1[9:1], {1'b0, x1[9:1]})));
		end
	end
	initial begin
		// a frame to settle (the first lines are fetched in its blanking), then two checked
		#(800 * 525 * 40 * 3);
		$display("tb_n64_vid: %0d pixels checked, %0d wrong", checked, errors);
		if (errors == 0 && checked >= 614400) $display("tb_n64_vid: all checks passed"); else $display("tb_n64_vid: FAIL");
		$finish;
	end
endmodule

`default_nettype wire
