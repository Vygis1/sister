//////////////////////////////////////////////////////////////////////////////////
// shell_hl.v - the menu's selection, drawn over the picture as it goes out: a rounded rectangle
// whose look is a table by the distance from its edge (inside: a tint; the edge: an outline;
// outside: a glow). Moving it is four register writes (from rtl/shell_fb.v, where it began).
//
// Registers (the menu's page 0x0009):
//   0x0020  [9:0] x, [25:16] y      0x0024  [9:0] w, [25:16] h
//   0x0028  [0] on, [12:8] radius   0x002C  [23:0] its colour
//   0x0040 + 4k  the table, k 0-15: [7:0] how much, [8] which colour (0 white, 1 the register's),
//           for pixels k - 4 from the edge (negative inside)
//   0x0080 + 4k  k 0-13: (radius + k - 3) squared, the corners' distances (no square root here)
// base: the picture's pixel, a pclk after the request (x, y); rgb: with the highlight, the same.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_hl (
	input  wire        clk,
	input  wire        rst,
	input  wire        we,
	input  wire [15:0] off,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	input  wire        pclk,
	input  wire [9:0]  x,
	input  wire [9:0]  y,
	input  wire [23:0] base,
	output reg  [23:0] rgb
);
	// (written on the bus clock, read on the picture's: a change tears at worst one frame)
	reg [9:0]  hx, hy, hw, hh; reg hon; reg [4:0] hr; reg [23:0] hcol;
	reg [8:0]  hlut [0:15];
	reg [12:0] ht [0:13];
	integer k;
	initial begin
		for (k = 0; k < 16; k = k + 1) hlut[k] = 9'd0;
		for (k = 0; k < 14; k = k + 1) ht[k] = 13'd0;
		hcol = 24'd0; hon = 1'b0; hx = 10'd0; hy = 10'd0; hw = 10'd0; hh = 10'd0; hr = 5'd0;
	end
	always @(posedge clk) begin
		if (rst) hon <= 1'b0;
		else if (we) begin
			if (off == 16'h0020) begin hx <= wdata[9:0]; hy <= wdata[25:16]; end
			if (off == 16'h0024) begin hw <= wdata[9:0]; hh <= wdata[25:16]; end
			if (off == 16'h0028) begin hon <= wdata[0]; hr <= wdata[12:8]; end
			if (off == 16'h002C) hcol <= wdata[23:0];
			if (off[15:6] == 10'h001) hlut[off[5:2]] <= wdata[8:0];
			if (off[15:6] == 10'h002 && off[5:2] < 4'd14) ht[off[5:2]] <= wdata[12:0];
		end
	end
	always @* begin
		case (off)
		16'h0020: rdata = {6'd0, hy, 6'd0, hx};
		16'h0024: rdata = {6'd0, hh, 6'd0, hw};
		16'h0028: rdata = {19'd0, hr, 7'd0, hon};
		default:  rdata = 32'd0;
		endcase
	end

	// how far (whole pixels) the request is from the rectangle's edge: outside its "core" (the
	// rectangle less the radius) along each axis; in a corner, which squared distance it is past
	wire signed [11:0] lx = $signed({2'b00, hx}) + $signed({7'b0, hr}) - $signed({2'b00, x});
	wire signed [11:0] rx = $signed({2'b00, x}) - ($signed({2'b00, hx}) + $signed({2'b00, hw}) - 12'sd1 - $signed({7'b0, hr}));
	wire signed [11:0] ty = $signed({2'b00, hy}) + $signed({7'b0, hr}) - $signed({2'b00, y});
	wire signed [11:0] by = $signed({2'b00, y}) - ($signed({2'b00, hy}) + $signed({2'b00, hh}) - 12'sd1 - $signed({7'b0, hr}));
	wire signed [11:0] ax = lx > rx ? lx : rx;
	wire signed [11:0] ay = ty > by ? ty : by;
	wire        corner = ax > 12'sd0 && ay > 12'sd0;
	wire        far = ax > 12'sd63 || ay > 12'sd63;
	wire [12:0] q = ax[5:0] * ax[5:0] + ay[5:0] * ay[5:0];
	reg  [3:0]  cnt;
	always @* begin
		cnt = 4'd0;
		for (k = 0; k < 14; k = k + 1) if (q > ht[k]) cnt = cnt + 4'd1;
	end
	wire signed [11:0] e  = (ax > ay ? ax : ay) - $signed({7'b0, hr}) + 12'sd4;
	wire [3:0]  idx = (corner && far) ? 4'd15 : corner ? cnt : (e < 12'sd0) ? 4'd0 : (e > 12'sd15) ? 4'd15 : e[3:0];
	reg  [3:0]  idx1; reg hon1;
	always @(posedge pclk) begin idx1 <= idx; hon1 <= hon; end
	// the table's colour over the picture: d (256 - a) + c a, over 256, a channel at a time (wires,
	// not one function called three times in an expression: xsim gets that wrong)
	wire [8:0]  lt = hlut[idx1];
	wire [7:0]  al = hon1 ? lt[7:0] : 8'd0;
	wire [23:0] hc = lt[8] ? hcol : 24'hFFFFFF;
	wire [16:0] mr = {1'b0, base[23:16], 8'd0} + {9'd0, hc[23:16]} * {9'd0, al} - {9'd0, base[23:16]} * {9'd0, al};
	wire [16:0] mg = {1'b0, base[15:8], 8'd0} + {9'd0, hc[15:8]} * {9'd0, al} - {9'd0, base[15:8]} * {9'd0, al};
	wire [16:0] mb = {1'b0, base[7:0], 8'd0} + {9'd0, hc[7:0]} * {9'd0, al} - {9'd0, base[7:0]} * {9'd0, al};
	always @* rgb = (al == 8'd0) ? base : {mr[15:8], mg[15:8], mb[15:8]};
endmodule

`default_nettype wire
