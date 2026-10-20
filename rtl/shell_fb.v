//////////////////////////////////////////////////////////////////////////////////
// shell_fb.v - the menu's picture: 640 x 480 in 12-bit colour (4096 colours), drawn by the
// ESP32 a rectangle at a time and shown under osd.v (its rgb_in: the text overlay passes it
// through when it is off, and draws the install's progress over it when the shell turns it on).
//
// Memory: three 4-bit planes of 307200 pixels (red, green, blue), 38 block RAMs each -- every
// pixel its own address, so a rectangle at any x needs no read-modify-write. 114 of the
// chip's 135; the shell has nothing else that wants them.
//
// The bus page (shell_top's 0x0009xxxx):
//   0x0000  "FB01"                         read only
//   0x0004  CTRL [0] the picture is on (else black under the overlay)
//   0x0010  RECT  [9:0] x, [25:16] y        where the next pixels go
//   0x0014  SIZE  [9:0] width, [25:16] height; writing it starts the rectangle again
//   0x0018  FILL  [11:0] a colour: the whole rectangle that colour, a pixel a clock
//   0x001C  BUSY  [0] a fill (or the last pixels) still being written: the ESP32 waits for it
//           to clear after a FILL before it sends pixels
//   0x1000-0xFFFC  PIXELS: words of packed pixels, three words to eight pixels, the first
//           pixel in the low 12 bits of the first word (any address in the window: a burst's
//           rising address stays in it), across the rectangle a row at a time
//   0x0020  HL_POS  [9:0] x, [25:16] y      THE HIGHLIGHT: a rounded rectangle drawn over the
//   0x0024  HL_SIZE [9:0] w, [25:16] h      picture as it goes out -- the menu's selection, moved
//   0x0028  HL_CTL  [0] on, [12:8] radius   by writing these, not by drawing pixels (a tile drawn
//   0x002C  HL_COL  [23:0] its colour        again took the ESP32 a third of a second)
//   0x0040 + 4k  HL_LUT, k 0-15: [7:0] how much of the colour, [8] which (0 white, 1 HL_COL),
//           for the pixels k - 4 from the edge (negative inside; 0 the edge itself; -4 and
//           deeper the inside, 11 and further nothing -- the table says what each is)
//   0x0080 + 4k  HL_T, k 0-13: (radius + k - 3) squared, the corners' distances (the ESP32 works
//           them out: no square root here)
// Colour: [11:8] red, [7:4] green, [3:0] blue; out as 8-bit by repeating the nibble.
//
// The pixel side answers a clock after the request, as every source of hdmi_tx does.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_fb (
	// the bus (clk)
	input  wire        clk,
	input  wire        rst,
	input  wire        we,
	input  wire [15:0] off,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	// the picture (pclk)
	input  wire        pclk,
	input  wire [9:0]  x,
	input  wire [9:0]  y,
	output reg  [23:0] rgb
);
	localparam N = 307200;
	(* ram_style = "block" *) reg [3:0] pr [0:N-1];
	(* ram_style = "block" *) reg [3:0] pg [0:N-1];
	(* ram_style = "block" *) reg [3:0] pb [0:N-1];

	reg        on;
	reg [9:0]  rx, ry, rw, rh;            // the rectangle
	reg [9:0]  cx, cy;                    // the next pixel in it
	reg [18:0] ca;                        // ...its address (cy * 640 + cx)
	reg [11:0] fill_c; reg filling;
	reg [95:0] acc; reg [1:0] nw;         // the words gathering (three to eight pixels)
	reg [3:0]  emit;                      // pixels of acc still to write
	reg        wr; reg [18:0] wa; reg [11:0] wc;
	// the highlight (written on the bus clock, read on the picture's: it changes between frames
	// at worst a frame torn, as the menu moves it)
	reg [9:0]  hx, hy, hw, hh; reg hon; reg [4:0] hr; reg [23:0] hcol;
	reg [8:0]  hlut [0:15];
	reg [12:0] ht [0:13];
	integer k;
	initial begin for (k = 0; k < 16; k = k + 1) hlut[k] = 9'd0; for (k = 0; k < 14; k = k + 1) ht[k] = 13'd0; hcol = 24'd0; hon = 1'b0; end

	always @* begin
		case (off)
		16'h0000: rdata = 32'h4642_3031;   // "FB01"
		16'h0004: rdata = {31'd0, on};
		16'h0010: rdata = {6'd0, ry, 6'd0, rx};
		16'h0014: rdata = {6'd0, rh, 6'd0, rw};
		16'h001C: rdata = {31'd0, filling || emit != 4'd0};
		16'h0020: rdata = {6'd0, hy, 6'd0, hx};
		16'h0024: rdata = {6'd0, hh, 6'd0, hw};
		16'h0028: rdata = {19'd0, hr, 7'd0, hon};
		default:  rdata = 32'd0;
		endcase
	end

	// the cursor, a pixel on (across, then the next row; back to the top at the end)
	wire        last_x = (cx + 10'd1 >= rx + rw);
	wire        last_y = (cy + 10'd1 >= ry + rh);
	task step; begin
		if (last_x) begin
			cx <= rx;
			if (last_y) begin cy <= ry; ca <= {ry, 9'd0} + {2'd0, ry, 7'd0} + {9'd0, rx}; end
			else begin cy <= cy + 10'd1; ca <= ca - {9'd0, cx - rx} + 19'd640; end
		end else begin cx <= cx + 10'd1; ca <= ca + 19'd1; end
	end endtask

	always @(posedge clk) begin
		wr <= 1'b0;
		if (rst) begin
			on <= 1'b0; rx <= 10'd0; ry <= 10'd0; rw <= 10'd640; rh <= 10'd480; cx <= 10'd0; cy <= 10'd0; ca <= 19'd0;
			filling <= 1'b0; nw <= 2'd0; emit <= 4'd0; hon <= 1'b0;
		end else begin
			if (filling) begin
				wr <= 1'b1; wa <= ca; wc <= fill_c;
				step;
				if (last_x && last_y) filling <= 1'b0;
			end else if (emit != 4'd0) begin
				wr <= 1'b1; wa <= ca; wc <= acc[11:0];
				acc <= acc >> 12; emit <= emit - 4'd1;
				step;
			end
			if (we) begin
				if (off == 16'h0004) on <= wdata[0];
				if (off == 16'h0020) begin hx <= wdata[9:0]; hy <= wdata[25:16]; end
				if (off == 16'h0024) begin hw <= wdata[9:0]; hh <= wdata[25:16]; end
				if (off == 16'h0028) begin hon <= wdata[0]; hr <= wdata[12:8]; end
				if (off == 16'h002C) hcol <= wdata[23:0];
				if (off[15:6] == 10'h001) hlut[off[5:2]] <= wdata[8:0];
				if (off[15:6] == 10'h002 && off[5:2] < 4'd14) ht[off[5:2]] <= wdata[12:0];
				if (off == 16'h0010) begin rx <= wdata[9:0]; ry <= wdata[25:16]; end
				if (off == 16'h0014 || off == 16'h0010) begin
					if (off == 16'h0014) begin rw <= wdata[9:0]; rh <= wdata[25:16]; end
					cx <= (off == 16'h0010) ? wdata[9:0] : rx; cy <= (off == 16'h0010) ? wdata[25:16] : ry;
					ca <= (off == 16'h0010) ? {wdata[25:16], 9'd0} + {2'd0, wdata[25:16], 7'd0} + {9'd0, wdata[9:0]}
					                        : {ry, 9'd0} + {2'd0, ry, 7'd0} + {9'd0, rx};
					nw <= 2'd0; filling <= 1'b0; emit <= 4'd0;
				end
				if (off == 16'h0018) begin fill_c <= wdata[11:0]; filling <= 1'b1; cx <= rx; cy <= ry; ca <= {ry, 9'd0} + {2'd0, ry, 7'd0} + {9'd0, rx}; end
				if (off[15:12] != 4'd0) begin
					// a word of pixels (the ESP32 sends a word every 0.8 us at most: eight
					// pixels go out in eight clocks, long before the next three are in)
					case (nw)
					2'd0: begin acc[31:0] <= wdata; nw <= 2'd1; end
					2'd1: begin acc[63:32] <= wdata; nw <= 2'd2; end
					default: begin acc[95:64] <= wdata; nw <= 2'd0; emit <= 4'd8; end
					endcase
				end
			end
		end
	end
	always @(posedge clk) if (wr) begin pr[wa] <= wc[11:8]; pg[wa] <= wc[7:4]; pb[wa] <= wc[3:0]; end

	// the pixel side: the address for the request, the colour a clock later
	wire [18:0] ra = {y[8:0], 9'd0} + {2'd0, y[8:0], 7'd0} + {9'd0, x};
	wire        inside = x < 10'd640 && y < 10'd480;
	reg  [3:0]  qr, qg, qb; reg in1, on1, on2;
	// the highlight for the request: how far (in whole pixels) it is from the rectangle's edge --
	// the distance outside its "core" (the rectangle less the radius) along each axis, and in a
	// corner, which of the squared distances it is past -- as the table's index
	wire signed [11:0] ax = ($signed({2'b00, hx}) + $signed({7'b0, hr}) - $signed({2'b00, x})) > ($signed({2'b00, x}) - ($signed({2'b00, hx}) + $signed({2'b00, hw}) - 12'sd1 - $signed({7'b0, hr})))
	                      ? ($signed({2'b00, hx}) + $signed({7'b0, hr}) - $signed({2'b00, x}))
	                      : ($signed({2'b00, x}) - ($signed({2'b00, hx}) + $signed({2'b00, hw}) - 12'sd1 - $signed({7'b0, hr})));
	wire signed [11:0] ay = ($signed({2'b00, hy}) + $signed({7'b0, hr}) - $signed({2'b00, y})) > ($signed({2'b00, y}) - ($signed({2'b00, hy}) + $signed({2'b00, hh}) - 12'sd1 - $signed({7'b0, hr})))
	                      ? ($signed({2'b00, hy}) + $signed({7'b0, hr}) - $signed({2'b00, y}))
	                      : ($signed({2'b00, y}) - ($signed({2'b00, hy}) + $signed({2'b00, hh}) - 12'sd1 - $signed({7'b0, hr})));
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
	always @(posedge pclk) begin
		qr <= pr[ra]; qg <= pg[ra]; qb <= pb[ra];
		in1 <= inside; on1 <= on; on2 <= on1;
		idx1 <= idx; hon1 <= hon;
	end
	// the picture's pixel, and the highlight's colour over it as the table says
	wire [23:0] base = (in1 && on2) ? {qr, qr, qg, qg, qb, qb} : 24'd0;
	wire [8:0]  lt   = hlut[idx1];
	wire [7:0]  al   = hon1 ? lt[7:0] : 8'd0;
	wire [23:0] hc   = lt[8] ? hcol : 24'hFFFFFF;
	// d (256 - a) + c a, over 256, a channel at a time (wires, not a function called three times
	// in one expression: xsim gets that wrong)
	wire [16:0] mr = {1'b0, base[23:16], 8'd0} + {9'd0, hc[23:16]} * {9'd0, al} - {9'd0, base[23:16]} * {9'd0, al};
	wire [16:0] mg = {1'b0, base[15:8], 8'd0} + {9'd0, hc[15:8]} * {9'd0, al} - {9'd0, base[15:8]} * {9'd0, al};
	wire [16:0] mb = {1'b0, base[7:0], 8'd0} + {9'd0, hc[7:0]} * {9'd0, al} - {9'd0, base[7:0]} * {9'd0, al};
	always @* rgb = (al == 8'd0) ? base : {mr[15:8], mg[15:8], mb[15:8]};
endmodule

`default_nettype wire
