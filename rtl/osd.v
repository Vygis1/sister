//////////////////////////////////////////////////////////////////////////////////
// osd.v - text over the HDMI picture: the menu. 40 x 30 cells of 16 x 16 pixels (an
// 8 x 8 glyph, doubled) over the whole 640 x 480, written over the bus (clk) and drawn
// in hdmi_tx's pixel clock.
//
// The bus page (regfile's PAGE_OSD):
//   0x0000  "OSD2"                          read only (version 1 said "OSD1")
//   0x0004  CTRL   [0] show  [1] the game's picture dimmed behind the text  [2] a black
//                  background (else the plain one: a dark gradient)
//   0x0040 + 4 * i  the palette, i 0-7: 24-bit RGB (from power-up: white, yellow, grey,
//                  green, pink, red, cyan, orange)
//   0x2000 + 4 * (row * 40 + col)           a cell:
//                  [7:0]   the glyph
//                  [8]     highlight (a bright bar behind it)
//                  [10:9]  the ink's colour, low bits  ([12] its high bit: palette 0-7)
//                  [11]    a bar (the header's and footer's lighter background)
//                  [13]    the background is palette colour [16:14], not the plain one
//   0x4000 + 4 * (glyph * 8 + row)          a glyph's row, [7:0], bit 0 the leftmost
//                  pixel: glyphs 0-127 are the font from power-up (osd_glyphs.v), 128-255
//                  start empty -- the menu's own tiles
// A version-1 menu's writes mean what they meant: its cells' upper bits are zero.
// The font's control codes 0x01-0x07 and 0x0F draw a frame (corners, lines, a block)
// and a diamond.
//
// The pixel side is a clock behind the request like every source of hdmi_tx: the
// cell and glyph are fetched two pixels ahead (x counts the whole 800-clock line, so
// "two ahead" past its end is the next line's first two).
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module osd (
	// the bus (clk)
	input  wire        clk,
	input  wire        rst,
	input  wire        we,
	input  wire [15:0] off,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	output reg         err,
	// the picture (pclk)
	input  wire        pclk,
	input  wire [9:0]  x,
	input  wire [9:0]  y,
	input  wire [23:0] rgb_in,          // the console's pixel for the request a clock ago
	output wire [23:0] rgb
);
	reg [2:0] ctrl;
	(* ram_style = "block" *) reg [16:0] cells [0:2047];
	integer k; initial for (k = 0; k < 2048; k = k + 1) cells[k] = 17'h00020;   // spaces (the block RAM's initial contents)
	reg [23:0] pal [0:7];
	initial begin
		pal[0] = 24'hF0F0F0; pal[1] = 24'hFFE040; pal[2] = 24'h8890A8; pal[3] = 24'h60E070;
		pal[4] = 24'hFF8FB0; pal[5] = 24'hFF5050; pal[6] = 24'h60C8FF; pal[7] = 24'hFFA040;
	end
	wire [10:0] widx = off[12:2];
	wire        pal_hit = off[15:5] == 11'h002;               // 0x0040-0x005F
	always @(posedge clk) begin
		if (rst) ctrl <= 3'd0;
		else if (we && off == 16'h0004) ctrl <= wdata[2:0];
		if (we && off[15:13] == 3'd1 && widx < 11'd1200) cells[widx] <= wdata[16:0];
		if (we && pal_hit) pal[off[4:2]] <= wdata[23:0];
	end
	always @* begin
		err = 1'b0; rdata = 32'd0;
		if (pal_hit) rdata = {8'd0, pal[off[4:2]]};
		else case (off)
		16'h0000: rdata = 32'h4F53_4432;      // "OSD2"
		16'h0004: rdata = {29'd0, ctrl};
		default:  if (off[15:13] != 3'd1 && off[15:13] != 3'd2) err = 1'b1;
		endcase
	end

	// --- the pixel side ---------------------------------------------------------------
	reg [2:0] c1, c2;
	always @(posedge pclk) begin c1 <= ctrl; c2 <= c1; end

	// the pixel two ahead
	wire [10:0] x2  = {1'b0, x} + 11'd2;
	wire        nxt = x2 >= 11'd800;
	wire [9:0]  xa  = nxt ? x2[9:0] - 10'd800 : x2[9:0];
	wire [9:0]  ya  = !nxt ? y : (y == 10'd524) ? 10'd0 : y + 10'd1;     // (525 lines)
	wire [5:0]  col = xa[9:4];
	wire [4:0]  row = ya[8:4];
	wire [10:0] cidx = {row, 5'd0} + {2'd0, row, 3'd0} + {5'd0, col};   // row * 40 + col
	wire        inside = xa < 10'd640 && ya < 10'd480;

	// stage 1: the cell
	reg [16:0] cel; reg [2:0] gr1, gb1; reg in1;
	always @(posedge pclk) begin
		cel <= cells[cidx];
		gr1 <= ya[3:1]; gb1 <= xa[3:1]; in1 <= inside;
	end
	// stage 2: the glyph's row
	wire [7:0] grow;
	osd_glyphs u_glyphs (.clk(clk), .we(we && off[15:13] == 3'd2), .wa(off[12:2]), .wd(wdata[7:0]),
	                     .pclk(pclk), .ra({cel[7:0], gr1}), .q(grow));
	reg [2:0] gb2; reg in2; reg hl2, bar2, sol2; reg [2:0] col2, bgc2;
	always @(posedge pclk) begin
		gb2 <= gb1; in2 <= in1; hl2 <= cel[8]; col2 <= {cel[12], cel[10:9]}; bar2 <= cel[11];
		sol2 <= cel[13]; bgc2 <= cel[16:14];
	end
	// stage 3: the pixel, registered so it lines up with rgb_in
	reg fg3, hl3, in3, bar3, sol3; reg [23:0] ink3, bgi3;
	always @(posedge pclk) begin
		fg3 <= grow[gb2]; hl3 <= hl2; in3 <= in2; bar3 <= bar2; sol3 <= sol2;
		ink3 <= pal[col2]; bgi3 <= pal[bgc2];
	end
	// the background: lighter at the top, 60 steps down the screen
	wire [5:0] gt = 6'd59 - y[8:3];
	wire [23:0] grad = {8'd8 + {4'd0, gt[5:2]}, 8'd10 + {4'd0, gt[5:2]} + {6'd0, gt[5:4]}, 8'd24 + {3'd0, gt[5:1]}};

	wire [23:0] dim = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]} + 24'h080818;
	wire [23:0] bg  = hl3 ? 24'h2C58C8 : sol3 ? bgi3 : bar3 ? 24'h26325E : c2[1] ? dim : c2[2] ? 24'h000000 : grad;
	assign rgb = (c2[0] && in3) ? (fg3 ? ink3 : bg) : rgb_in;
endmodule

`default_nettype wire
