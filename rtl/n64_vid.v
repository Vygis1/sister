//////////////////////////////////////////////////////////////////////////////////
// n64_vid.v - the N64's picture for HDMI: a two-line buffer between n64_top (which
// fetches VI's framebuffer lines out of RDRAM, clk) and hdmi_tx (which asks for a
// pixel a clock ahead, pclk).
//
// The pixel side says which source line it needs next (want: during the picture,
// the line after the one on screen; in blanking, line 0); n64_top fetches it into
// the other half of the buffer while this half is shown. A source line is 320
// pixels or fewer (shown doubled, 640x480) or up to 640 (shown 1:1); 16-bit RGBA5551
// or 32-bit RGBA8888, as VI_STATUS says.
//
// Written a 128-bit DDR3 line at a time (slot, word); a line's bytes are little-
// endian in the word (byte k at bits 8k+7:8k) and the N64's pixels big-endian in
// them, as n64_top's frame reads.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_vid (
	// the fetch side (clk)
	input  wire         clk,
	input  wire         wr_en,
	input  wire [7:0]   wr_addr,           // {slot, word}
	input  wire [127:0] wr_data,
	output reg  [8:0]   want,              // (clk) the source line the pixel side needs next
	input  wire [11:0]  width,             // VI_WIDTH (pixels a line)
	input  wire         bpp32,
	input  wire         on,                // VI is showing a picture
	// the pixel side (pclk)
	input  wire         pclk,
	input  wire [9:0]   x,
	input  wire [9:0]   y,
	input  wire         req,
	output wire [23:0]  rgb
);
	(* ram_style = "block" *) reg [127:0] lbuf [0:255];
	always @(posedge clk) if (wr_en) lbuf[wr_addr] <= wr_data;

	// --- the pixel side ------------------------------------------------------------------
	// (the settings, from clk: they change between frames, so two flops each is enough)
	reg [11:0] w1, w2; reg b1, b2, o1, o2;
	always @(posedge pclk) begin w1 <= width; w2 <= w1; b1 <= bpp32; b2 <= b1; o1 <= on; o2 <= o1; end
	wire       dbl = w2 <= 12'd320;                       // shown doubled
	wire [9:0] sx = dbl ? {1'b0, x[9:1]} : x;
	wire [8:0] sy = dbl ? y[9:1] : y[8:0];
	// the word with this pixel: 8 pixels a word at 16 bits, 4 at 32
	wire [6:0] wd = b2 ? sx[8:2] : {1'b0, sx[8:3]};
	reg  [127:0] q;  reg [2:0] sel; reg vis;
	always @(posedge pclk) begin
		q <= lbuf[{sy[0], wd}];
		sel <= b2 ? {1'b0, sx[1:0]} : sx[2:0];
		vis <= req && o2 && {2'd0, sx} < w2;
	end
	// pixel n of the word: bytes 2n, 2n+1 (16-bit) or 4n..4n+3 (32-bit), big-endian
	wire [15:0] p16 = {q[8 * {sel, 1'b0} +: 8], q[8 * {sel, 1'b1} +: 8]};
	wire [31:0] p32 = {q[8 * {sel[1:0], 2'd0} +: 8], q[8 * {sel[1:0], 2'd1} +: 8], q[8 * {sel[1:0], 2'd2} +: 8], q[8 * {sel[1:0], 2'd3} +: 8]};
	assign rgb = !vis ? 24'd0
	           : b2 ? p32[31:8]
	           : {p16[15:11], p16[15:13], p16[10:6], p16[10:8], p16[5:1], p16[5:3]};

	// the line wanted next: the one after the line on screen; in blanking, the first
	reg [8:0] want_p;
	always @(posedge pclk) want_p <= (y >= 10'd480) ? 9'd0 : (dbl ? {1'b0, y[9:1]} + 9'd1 : y[8:0] + 9'd1);
	// to clk: it holds for two lines at a time, so a value read the same twice is good
	reg [8:0] wa, wb;
	always @(posedge clk) begin
		wa <= want_p; wb <= wa;
		if (wa == wb) want <= wb;
	end
endmodule

`default_nettype wire
