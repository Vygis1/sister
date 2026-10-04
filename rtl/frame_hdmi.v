//////////////////////////////////////////////////////////////////////////////////
// frame_hdmi.v - a console's picture for HDMI: one frame of its own colour words,
// written as the video chip draws (clk) and read for hdmi_tx (pclk), each pixel
// doubled and the picture centred in 640x480 -- the Master System's and the Mega
// Drive's (nes_hdmi.v is the NES's, with its palette).
//
// The frame is 320 words a line, 240 lines; the picture in it is w x h (the console
// says which: a Mega Drive is 256 or 320 across, 224 lines; a Master System 256 x
// 192), shown 2w x 2h from (320 - w, 240 - h).
//
// FMT picks what a colour word is:
//   1  Master System: 6 bits, --BBGGRR (two bits each)
//   2  Mega Drive:    9 bits, BBBGGGRRR (three bits each)
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module frame_hdmi #(
	parameter FMT = 1,
	parameter DW  = 6                    // bits a colour word
)(
	// the writing side (clk)
	input  wire          clk,
	input  wire          we,
	input  wire [8:0]    wx,
	input  wire [8:0]    wy,
	input  wire [DW-1:0] wd,
	input  wire [8:0]    w,              // the picture's width and height now
	input  wire [8:0]    h,
	// the pixel side (pclk)
	input  wire          pclk,
	input  wire [9:0]    x,
	input  wire [9:0]    y,
	input  wire          req,
	output wire [23:0]   rgb
);
	(* ram_style = "block" *) reg [DW-1:0] fb [0:76799];          // 320 x 240
	wire [16:0] wa = {wy[7:0], 8'd0} + {2'd0, wy[7:0], 6'd0} + {8'd0, wx};   // y * 320 + x
	always @(posedge clk)
		if (we && wx < 9'd320 && wy < 9'd240) fb[wa] <= wd;

	// the shape, from clk: it changes between frames, so two flops each is enough
	reg [8:0] w1, w2, h1, h2;
	always @(posedge pclk) begin w1 <= w; w2 <= w1; h1 <= h; h2 <= h1; end
	wire [9:0] x0 = 10'd320 - {1'b0, w2};          // where the picture starts
	wire [9:0] y0 = 10'd240 - {1'b0, h2};
	wire [9:0] xs = x - x0, ys = y - y0;           // (on the picture: 0 .. 2w-1, 0 .. 2h-1)
	wire       on = x >= x0 && xs < {w2, 1'b0} && y >= y0 && ys < {h2, 1'b0};
	wire [8:0] sx = xs[9:1], sy = ys[9:1];
	wire [16:0] ra = {sy[7:0], 8'd0} + {2'd0, sy[7:0], 6'd0} + {8'd0, sx};
	reg  [DW-1:0] q; reg vis;
	always @(posedge pclk) begin
		q <= fb[ra];
		vis <= req && on;
	end

	// the colour word, to 24 bits (each field's bits repeated down to fill eight)
	wire [23:0] c;
	generate if (FMT == 2) begin : g_md
		wire [2:0] r = q[2:0], g = q[5:3], b = q[8:6];
		assign c = {r, r, r[2:1], g, g, g[2:1], b, b, b[2:1]};
	end else begin : g_sms
		wire [1:0] r = q[1:0], g = q[3:2], b = q[5:4];
		assign c = {r, r, r, r, g, g, g, g, b, b, b, b};
	end endgenerate
	assign rgb = vis ? c : 24'd0;
endmodule

`default_nettype wire
