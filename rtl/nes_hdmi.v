//////////////////////////////////////////////////////////////////////////////////
// nes_hdmi.v - the NES's picture for HDMI: a 256x240 frame of colour indices,
// written as the PPU draws (clk) and read for hdmi_tx (pclk), each pixel doubled
// (512x480) and centred in 640x480, through the palette at 24 bits.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module nes_hdmi (
	input  wire        clk,
	input  wire        pixel_en,
	input  wire [8:0]  px,
	input  wire [8:0]  py,
	input  wire [5:0]  color,
	input  wire        pclk,
	input  wire [9:0]  x,
	input  wire [9:0]  y,
	input  wire        req,
	output wire [23:0] rgb
);
	(* ram_style = "block" *) reg [5:0] fb [0:65535];          // {y, x}
	always @(posedge clk)
		if (pixel_en && px < 9'd256 && py < 9'd240) fb[{py[7:0], px[7:0]}] <= color;

	wire [9:0] xo = x - 10'd64;                                   // the picture starts 64 in
	reg  [5:0] q; reg vis;
	always @(posedge pclk) begin
		q <= fb[{y[8:1], xo[8:1]}];
		vis <= req && x >= 10'd64 && x < 10'd576 && y < 10'd480;
	end
	wire [23:0] pal;
	nes_palette888 u_pal (.idx(q), .rgb(pal));
	assign rgb = vis ? pal : 24'd0;
endmodule

`default_nettype wire
