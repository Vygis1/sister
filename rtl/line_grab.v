// line_grab.v - one line of the picture the core sends to HDMI, kept for the host to read: how a
// console's screen is checked from the PC without looking at the TV (tools/vgrab.py: a line at a
// time, so a still picture comes out whole).
//
// The host writes the line it wants (go), then waits for done: the next time that line goes out,
// its pixels are stored as RGB565, two a word (even pixel in the low half). The host then reads
// the words by index. One 18 kb block RAM; the HDMI side is pclk, the host side clk.
//
// The source contract is hdmi_tx's: rgb is the pixel at (x, y) a clock after req.
`default_nettype none
module line_grab (
	input  wire        clk,
	input  wire        go,               // (clk) a pulse: grab line go_y
	input  wire [9:0]  go_y,
	input  wire [8:0]  rd_idx,           // (clk) the word read: pixels 2*rd_idx, 2*rd_idx+1
	output reg  [31:0] rd_data,
	output wire        done,             // (clk) the line asked for is in
	input  wire        pclk,
	input  wire [9:0]  vid_x,
	input  wire [9:0]  vid_y,
	input  wire        vid_req,
	input  wire [23:0] vid_rgb
);
	// the request into pclk: a toggle, the line held while it crosses
	reg        go_t = 1'b0;
	reg [9:0]  want_y = 10'd0;
	always @(posedge clk) if (go) begin go_t <= ~go_t; want_y <= go_y; end
	(* ASYNC_REG = "TRUE" *) reg [2:0] go_s = 3'd0;
	always @(posedge pclk) go_s <= {go_s[1:0], go_t};
	wire go_p = go_s[2] ^ go_s[1];

	// pclk: armed until the line has gone by once from its start (x 0)
	reg        armed = 1'b0, taking = 1'b0, done_t = 1'b0;
	reg [9:0]  x1 = 10'd0, y1 = 10'd0;
	reg        r1 = 1'b0;
	always @(posedge pclk) begin
		x1 <= vid_x; y1 <= vid_y; r1 <= vid_req;
		if (go_p) begin armed <= 1'b1; taking <= 1'b0; end
		else if (armed && r1 && y1 == want_y && x1 == 10'd0) taking <= 1'b1;
		if (taking && !(r1 && y1 == want_y)) begin taking <= 1'b0; armed <= 1'b0; done_t <= ~done_t; end
	end
	// the pixel, RGB565, held for the pair's even half
	wire [15:0] p565 = {vid_rgb[23:19], vid_rgb[15:10], vid_rgb[7:3]};
	reg  [15:0] even = 16'd0;
	(* ram_style = "block" *) reg [31:0] line [0:511];
	wire take = (taking || (armed && x1 == 10'd0)) && r1 && y1 == want_y;
	always @(posedge pclk) begin
		if (take && !x1[0]) even <= p565;
		if (take && x1[0]) line[x1[9:1]] <= {p565, even};
	end
	always @(posedge clk) rd_data <= line[rd_idx];

	(* ASYNC_REG = "TRUE" *) reg [2:0] done_s = 3'd0;
	reg done_seen = 1'b0, go_seen = 1'b0;
	always @(posedge clk) begin
		done_s <= {done_s[1:0], done_t};
		if (go) go_seen <= 1'b1;
		else if (done_s[2] ^ done_s[1]) go_seen <= 1'b0;
	end
	assign done = !go_seen;
endmodule
`default_nettype wire
