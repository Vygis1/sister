//////////////////////////////////////////////////////////////////////////////////
// snes_timing.v - the SNES's frame: the H and V counters every chip times itself by.
//
// Fullsnes "SNES Timings": a 21.477 MHz master clock, 1364 master clocks a line, 262
// lines a frame (NTSC). `mce` is one master clock (the console runs from a faster clock
// and makes it with a fractional enable). h counts master clocks within the line, v the
// line; the dot counter the CPU latches ($2137) is h / 4.
//
// (Not modelled yet: the 4-clock-longer dots 323 and 327, the short line of odd
// non-interlaced frames, interlace's extra line, PAL.)
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_timing (
	input  wire        clk,
	input  wire        rst,
	input  wire        mce,
	input  wire        overscan,      // SETINI bit 2: 239 lines shown, not 224
	output reg  [10:0] h,             // master clocks into the line (0..1363)
	output reg  [8:0]  v,             // the line (0..261)
	output reg         field,
	output wire        vblank,        // from the line after the last shown, to line 0
	output wire        hblank,        // (the HVBJOY bit's span)
	output wire        line_start,    // h = 0 this master clock
	output wire        frame_start    // v = 0, h = 0
);
	localparam LINE = 11'd1364, LINES = 9'd262;
	always @(posedge clk) begin
		if (rst) begin h <= 11'd0; v <= 9'd0; field <= 1'b0; end
		else if (mce) begin
			if (h == LINE - 11'd1) begin
				h <= 11'd0;
				if (v == LINES - 9'd1) begin v <= 9'd0; field <= ~field; end
				else v <= v + 9'd1;
			end else h <= h + 11'd1;
		end
	end
	wire [8:0] last = overscan ? 9'd239 : 9'd224;
	assign vblank = (v > last);
	assign hblank = (h < 11'd4) || (h >= 11'd1096);
	assign line_start = mce && (h == 11'd0);
	assign frame_start = line_start && (v == 9'd0);
endmodule
