//////////////////////////////////////////////////////////////////////////////////
// tb_osd - osd.v behind hdmi_tx (SIM): a screen of cells written over the bus, and
// every pixel of the 640 x 480 picture must be the glyph's pixel in the cell's ink,
// the highlight bar or the background -- or, with the menu off, the console's own
// pixel. Checks the two-ahead fetch lines up at every column, line ends included.
// (sim/osd_font_ref.hex: the font as tools/gen_osd_font.py wrote it.)
//
//   ./tools/sim.sh tb_osd
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_osd;
	reg clk = 0, pclk = 0;
	always #10 clk = ~clk;
	always #20 pclk = ~pclk;
	wire [9:0] x, y; wire req;
	hdmi_tx #(.SIM(1)) u_tx (.clk50(1'b0), .rst(1'b0), .sim_pclk(pclk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0),
		.pclk(), .x(x), .y(y), .req(req), .rgb(24'd0), .frame_start(), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(16'd0), .aud_r(16'd0), .aud_tog(1'b0));

	// the console's picture: a clock behind the request, a pattern of x and y
	reg [23:0] con;
	always @(posedge pclk) con <= {x[7:0], y[7:0], x[9:2]};

	reg we = 0; reg [15:0] off = 0; reg [31:0] wdata = 0; wire [31:0] rdata; wire err;
	wire [23:0] rgb;
	osd dut (.clk(clk), .rst(1'b0), .we(we), .off(off), .wdata(wdata), .rdata(rdata), .err(err),
		.pclk(pclk), .x(x), .y(y), .rgb_in(con), .rgb(rgb));

	reg [7:0] font [0:1023];
	initial $readmemh("../../sim/osd_font_ref.hex", font);
	function [10:0] cellv; input integer i; cellv = {i[4:3], i[2] & i[0], 4'd0, i[6:0] ^ i[11:7]} | 11'h20; endfunction

	reg show = 0;
	integer i;
	task wr; input [15:0] o; input [31:0] d; begin @(posedge clk); we <= 1; off <= o; wdata <= d; @(posedge clk); we <= 0; end endtask
	initial begin
		for (i = 0; i < 1200; i = i + 1) wr(16'h2000 + 4 * i, {21'd0, cellv(i)});
		wr(16'h0004, 32'd1); show = 1;
	end

	reg [9:0] x1, y1; reg r1; reg [23:0] con1;
	always @(posedge pclk) begin x1 <= x; y1 <= y; r1 <= req; end
	integer errors = 0, checked = 0, frames = 0, ci, glyph;
	reg [10:0] cv; reg fg; reg [23:0] want, ink;
	always @(posedge pclk) if (x == 10'd0 && y == 10'd0 && req && show) frames = frames + 1;
	always @(posedge pclk) if (r1 && frames >= 2) begin
		ci = (y1 >> 4) * 40 + (x1 >> 4);
		cv = cellv(ci);
		glyph = font[{cv[6:0], y1[3:1]}];
		fg = glyph[x1[3:1]];
		ink = (cv[10:9] == 2'd1) ? 24'hFFE040 : (cv[10:9] == 2'd2) ? 24'h8890A8 : (cv[10:9] == 2'd3) ? 24'h60E070 : 24'hF0F0F0;
		want = fg ? ink : cv[8] ? 24'h2C58C8 : 24'h101830;
		checked = checked + 1;
		if (rgb !== want) begin
			errors = errors + 1;
			if (errors < 8) $display("tb_osd: (%0d,%0d) cell %0d char %02x got %06x want %06x | c2 %b in3 %b fg3 %b hl3 %b col3 %b cel %h grow %h gb2 %d", x1, y1, ci, cv[6:0], rgb, want, dut.c2, dut.in3, dut.fg3, dut.hl3, dut.col3, dut.cel, dut.grow, dut.gb2);
		end
	end
	initial begin
		#(800 * 525 * 40 * 3);
		$display("tb_osd: %0d pixels checked, %0d wrong", checked, errors);
		if (errors == 0 && checked >= 307200 && rdata !== 32'hx) $display("tb_osd: all checks passed"); else $display("tb_osd: FAIL");
		$finish;
	end
endmodule

`default_nettype wire
