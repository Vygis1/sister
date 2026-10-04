//////////////////////////////////////////////////////////////////////////////////
// osd.v - text over the HDMI picture: the menu. 40 x 30 cells of 16 x 16 pixels (the
// 8 x 8 font, doubled) over the whole 640 x 480, written over the bus (clk) and drawn
// in hdmi_tx's pixel clock.
//
// The bus page (regfile's PAGE_OSD):
//   0x0000  "OSD1"                          read only
//   0x0004  CTRL   [0] show  [1] the game's picture dimmed behind the text (else a
//                  plain dark background)
//   0x2000 + 4 * (row * 40 + col)           a cell: [6:0] the character, [8] highlight
//                  (a bright bar behind it), [10:9] colour: 0 white, 1 yellow, 2 grey,
//                  3 green
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
	reg [1:0] ctrl;
	(* ram_style = "block" *) reg [10:0] cells [0:2047];
	integer k; initial for (k = 0; k < 2048; k = k + 1) cells[k] = 11'h020;   // spaces (the block RAM's initial contents)
	wire [10:0] widx = off[12:2];
	always @(posedge clk) begin
		if (rst) ctrl <= 2'd0;
		else if (we && off == 16'h0004) ctrl <= wdata[1:0];
		if (we && off[15:13] == 3'd1 && widx < 11'd1200) cells[widx] <= wdata[10:0];
	end
	always @* begin
		err = 1'b0; rdata = 32'd0;
		case (off)
		16'h0000: rdata = 32'h4F53_4431;      // "OSD1"
		16'h0004: rdata = {30'd0, ctrl};
		default:  if (off[15:13] != 3'd1) err = 1'b1;
		endcase
	end

	// --- the pixel side ---------------------------------------------------------------
	reg [1:0] c1, c2;
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
	reg [10:0] cel; reg [2:0] gr1, gb1; reg in1;
	always @(posedge pclk) begin
		cel <= cells[cidx];
		gr1 <= ya[3:1]; gb1 <= xa[3:1]; in1 <= inside;
	end
	// stage 2: the glyph's row
	wire [7:0] grow;
	osd_font u_font (.clk(pclk), .a({cel[6:0], gr1}), .q(grow));
	reg [2:0] gb2; reg in2; reg hl2; reg [1:0] col2;
	always @(posedge pclk) begin gb2 <= gb1; in2 <= in1; hl2 <= cel[8]; col2 <= cel[10:9]; end
	// stage 3: the pixel, registered so it lines up with rgb_in
	reg fg3, hl3, in3; reg [1:0] col3;
	always @(posedge pclk) begin
		fg3 <= grow[gb2]; hl3 <= hl2; in3 <= in2; col3 <= col2;
	end

	wire [23:0] ink = (col3 == 2'd1) ? 24'hFFE040 : (col3 == 2'd2) ? 24'h8890A8 : (col3 == 2'd3) ? 24'h60E070 : 24'hF0F0F0;
	wire [23:0] dim = {2'b00, rgb_in[23:18], 2'b00, rgb_in[15:10], 2'b00, rgb_in[7:2]} + 24'h080818;
	wire [23:0] bg  = hl3 ? 24'h2C58C8 : c2[1] ? dim : 24'h101830;
	assign rgb = (c2[0] && in3) ? (fg3 ? ink : bg) : rgb_in;
endmodule

`default_nettype wire
