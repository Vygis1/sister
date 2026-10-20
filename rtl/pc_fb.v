//////////////////////////////////////////////////////////////////////////////////
// pc_fb.v - the PC's picture: whatever ao486's VGA draws (720x400 text at 70 Hz, 320x200 for
// Doom, 640x480 ...), into DDR3 and out again at the HDMI's 640x480 at 60 Hz.
//
// Capture (clk): the VGA's pixels as it puts them out (a clock enable a pixel, blank_n, the
// syncs), eight at a time as RGB565 into one 16-byte line; a picture line is 2 kB of DDR3 (1024
// pixels at most) at BASE + 128 lines a picture line. The size of the picture -- the widest line
// and how many lines -- is counted as it goes and taken at each vertical sync.
//
// Scanout (pclk, frame_hdmi's interface: x, y, req; the colour a pclk later): the picture
// stretched to fill 640x480, as a VGA monitor fills its 4:3 screen whatever the mode -- source
// x = X * w / 640, y = Y * h / 480. The picture line output line Y needs is fetched while line
// Y-1 is shown, into one of two line buffers (128 lines of 128 bits: 1024 pixels).
//
// SVGA (the VGA's VBE modes, fb_en): the picture is not the VGA's pixels but a framebuffer in DDR3 the
// L2 cache writes the CPU's A0000 window into (MiSTer's ao486 does the same, its ascal reading it):
// a line is fetched from fb_line + y * stride / 16, its pixels 8-bit (through the VGA's palette,
// written here as the VGA writes its own) or 16-bit (RGB565); the size is the VGA's.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module pc_fb #(
	parameter [23:0] BASE = 24'h800000          // a line address: 128 MB into DDR3
)(
	input  wire         clk,
	input  wire         rst,
	// the VGA's output
	input  wire         v_ce,
	input  wire         v_de,                    // blank_n
	input  wire         v_vs,
	input  wire [7:0]   v_r, v_g, v_b,
	// two ports of mem_arb: writes (capture) and reads (scanout)
	output reg  [23:0]  w_addr,
	output reg          w_req,
	output wire         w_we,
	output reg  [127:0] w_data,
	input  wire         w_ready,
	output reg  [23:0]  r_addr,
	output reg          r_req,
	input  wire         r_ready,
	input  wire [127:0] r_data,
	input  wire         r_valid,
	// HDMI
	input  wire         pclk,
	input  wire [9:0]   x,
	input  wire [9:0]   y,
	input  wire         req,
	output wire [23:0]  rgb,
	// (the size seen, for the host)
	output reg  [10:0]  pic_w,
	output reg  [9:0]   pic_h,
	// the border kept round the picture (a television crops a few percent at every edge): the picture
	// is stretched into 640 - 2mx by 480 - 2my, from (mx, my)
	input  wire [6:0]   mx,
	input  wire [6:0]   my,
	// SVGA: a framebuffer in DDR3 (clk)
	input  wire         fb_en,
	input  wire [23:0]  fb_line,           // its first line (byte address / 16)
	input  wire [11:0]  fb_width,
	input  wire [10:0]  fb_height,
	input  wire [13:0]  fb_stride,         // bytes a line
	input  wire         fb_16,             // 16-bit pixels, else 8-bit through the palette
	input  wire  [7:0]  pal_a,
	input  wire [17:0]  pal_d,
	input  wire         pal_we
);
	assign w_we = 1'b1;

	// --- capture ---------------------------------------------------------------------------------
	reg        de_r, vs_r;
	reg [10:0] cx, cur_w, max_w;
	reg [9:0]  cy, lines;
	reg [111:0] sh;                    // the seven pixels before this one
	reg [2:0]  np;                     // pixels in sh
	// a little queue of finished lines for the arbiter (it is never more than a line or two behind)
	reg [127:0] wq_d [0:7]; reg [23:0] wq_a [0:7];
	reg [2:0]  wq_w, wq_r;
	wire [15:0] px = {v_r[7:3], v_g[7:2], v_b[7:3]};
	always @(posedge clk) begin
		if (rst) begin
			de_r <= 1'b0; vs_r <= 1'b0; cx <= 11'd0; cy <= 10'd0; np <= 3'd0; wq_w <= 3'd0;
			pic_w <= 11'd0; pic_h <= 10'd0; max_w <= 11'd0; lines <= 10'd0;
		end else if (v_ce) begin
			de_r <= v_de; vs_r <= v_vs;
			if (v_vs && !vs_r) begin
				pic_w <= max_w; pic_h <= lines; max_w <= 11'd0; lines <= 10'd0; cy <= 10'd0;
			end
			if (v_de) begin
				if (cx < 11'd1024) begin
					if (np == 3'd7) begin
						wq_d[wq_w] <= {px, sh};
						wq_a[wq_w] <= BASE + {7'd0, cy, 7'd0} + {13'd0, cx[10:3]};
						wq_w <= wq_w + 3'd1;
					end
					sh <= {px, sh[111:16]};
					np <= np + 3'd1;
				end
				cx <= cx + 11'd1;
			end else if (de_r) begin                     // a line has ended
				if (cx > max_w) max_w <= cx;
				lines <= lines + 10'd1;
				cy <= cy + 10'd1;
				cx <= 11'd0; np <= 3'd0;
			end
		end
	end
	always @(posedge clk) begin
		if (rst) begin w_req <= 1'b0; wq_r <= 3'd0; end
		else if (w_req) begin if (w_ready) begin w_req <= 1'b0; wq_r <= wq_r + 3'd1; end end
		else if (wq_r != wq_w) begin w_req <= 1'b1; w_addr <= wq_a[wq_r]; w_data <= wq_d[wq_r]; end
	end

	// --- the size, for the scanout: the scale factors, a clock domain away (they change only with a
	// mode change; read by pclk a frame at a time) -- source x = (X - mx) * kx >> 10, y = (Y - my) *
	// ky >> 10, kx = w * 1024 / (640 - 2mx), ky = h * 1024 / (480 - 2my): a bit a clock, the two in turn
	wire [9:0] aw = 10'd640 - {2'b0, mx, 1'b0}, ah = 10'd480 - {2'b0, my, 1'b0};
	reg [11:0] kx, ky;
	reg [6:0]  nlines;                 // 16-byte lines a picture line
	reg [11:0] kt; reg [3:0] kb; reg ks;
	initial begin kt = 12'd0; kb = 4'd11; ks = 1'b0; kx = 12'd1024; ky = 12'd853; end
	wire [11:0] ktry = kt | (12'd1 << kb);
	wire [10:0] eff_w = fb_en ? fb_width[10:0] : pic_w;
	wire [9:0]  eff_h = fb_en ? fb_height[9:0] : pic_h;
	wire [21:0] knum = ks ? {2'b0, (eff_h == 10'd0) ? 10'd400 : eff_h, 10'd0} : {1'b0, (eff_w == 11'd0) ? 11'd640 : eff_w, 10'd0};
	wire [9:0]  kden = ks ? ah : aw;
	wire        kfit = ({10'd0, ktry} * {12'd0, kden}) <= knum;
	wire [11:0] kn = kfit ? ktry : kt;
	always @(posedge clk) begin
		if (kb == 4'd0) begin
			if (ks) ky <= kn; else kx <= kn;
			kt <= 12'd0; kb <= 4'd11; ks <= ~ks;
		end else begin kt <= kn; kb <= kb - 4'd1; end
		// (16-byte lines a picture line, less one: 8 RGB565 pixels a line captured or 16-bit; 16 at 8-bit)
		if (fb_en) nlines <= fb_16 ? ((fb_width > 12'd1024) ? 7'd127 : fb_width[10:3] - 7'd1)
		                           : ((fb_width > 12'd2048) ? 7'd127 : fb_width[11:4] - 7'd1);
		else nlines <= (pic_w == 11'd0) ? 7'd80 : ((pic_w > 11'd1024) ? 7'd127 : pic_w[10:3] - 7'd1);
	end

	// --- scanout: a line asked for (pclk), fetched (clk) ------------------------------------------
	reg [11:0] kx_p, ky_p; reg [6:0] nl_p;
	reg        ask_t;                  // toggles: fetch picture line ask_y into bank ask_b
	wire [9:0] ny = (y == 10'd524) ? 10'd0 : y + 10'd1;     // the output line asked for next
	reg [9:0]  ask_y; reg ask_b;
	always @(posedge pclk) begin
		if (y == 10'd524 && x == 10'd0) begin kx_p <= kx; ky_p <= ky; nl_p <= nlines; end   // (a frame's factors)
		// at the start of line Y-1's blanking (x 640): the line output line Y wants, if Y is in the picture
		if (x == 10'd640 && (y < 10'd479 || y == 10'd524) && ny >= {3'd0, my} && ny < {3'd0, my} + ah) begin
			ask_y <= ((({12'd0, ny} - {15'd0, my}) * {10'd0, ky_p}) >> 10);
			ask_b <= ny[0];
			ask_t <= ~ask_t;
		end
	end
	initial ask_t = 1'b0;
	reg [2:0] at_s; reg [9:0] f_y; reg f_b; reg [6:0] f_n, f_got, f_asked;
	reg f_run;
	// (the framebuffer line's address, ready before the toggle: ask_y is set a pclk before it)
	reg [23:0] fb_row;
	always @(posedge clk) fb_row <= fb_line + (({14'd0, ask_y} * {10'd0, fb_stride}) >> 4);
	reg [127:0] lb [0:255];            // two banks of 128 lines
	always @(posedge clk) begin
		at_s <= {at_s[1:0], ask_t};
		if (rst) begin r_req <= 1'b0; f_run <= 1'b0; end
		else begin
			if (at_s[2] != at_s[1]) begin
				// (ask_y, ask_b were set a pclk before the toggle and are still: two clk flops later)
				f_y <= ask_y; f_b <= ask_b; f_n <= nl_p; f_got <= 7'd0; f_asked <= 7'd0; f_run <= 1'b1;
				r_addr <= fb_en ? fb_row : BASE + {7'd0, ask_y, 7'd0}; r_req <= 1'b1;
			end else if (f_run) begin
				if (r_req && r_ready) begin
					if (f_asked == f_n) r_req <= 1'b0;
					else r_addr <= r_addr + 24'd1;
					f_asked <= f_asked + 7'd1;
				end
				if (r_valid) begin
					lb[{f_b, f_got}] <= r_data;
					f_got <= f_got + 7'd1;
					if (f_got == f_n) f_run <= 1'b0;
				end
			end
		end
	end
	// the pixel: line buffer bank y[0] (the line fetched for it), entry sx / 8, pixel sx % 8
	wire [9:0]  xo  = x - {3'd0, mx};
	wire [21:0] sxw = {12'd0, xo} * {10'd0, kx_p};
	wire [9:0]  sx  = sxw[19:10];
	wire        in_pic = x >= {3'd0, mx} && xo < aw && y >= {3'd0, my} && y < {3'd0, my} + ah;
	// (the mode, a frame at a time in this domain, as the scale factors)
	reg fb8_p;
	always @(posedge pclk) if (y == 10'd524 && x == 10'd0) fb8_p <= fb_en && !fb_16;
	// the palette (SVGA 8-bit): the VGA's, written as it writes its own; read at once (distributed)
	(* ram_style = "distributed" *) reg [17:0] pal [0:255];
	always @(posedge clk) if (pal_we) pal[pal_a] <= pal_d;
	reg [127:0] lq; reg [3:0] lp; reg vis;
	always @(posedge pclk) begin
		lq  <= lb[fb8_p ? {y[0], 1'b0, sx[9:4]} : {y[0], sx[9:3]}];
		lp  <= fb8_p ? sx[3:0] : {1'b0, sx[2:0]};
		vis <= req && in_pic;
	end
	wire [15:0] p   = lq[{lp[2:0], 4'd0} +: 16];
	wire [7:0]  idx = lq[{lp, 3'd0} +: 8];
	wire [17:0] pe  = pal[idx];
	wire [23:0] c8  = {pe[17:12], pe[17:16], pe[11:6], pe[11:10], pe[5:0], pe[5:4]};
	assign rgb = !vis ? 24'd0 : fb8_p ? c8 : {p[15:11], p[15:13], p[10:5], p[10:9], p[4:0], p[4:2]};
endmodule

`default_nettype wire
