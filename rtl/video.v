//////////////////////////////////////////////////////////////////////////////////
// video.v - a 320x240 framebuffer with a pattern generator in front of it.
//
// 320x240 because the Mega Drive in H40 is 320 across. It was 256 -- the NES's
// width -- and the Mega Drive lost its right quarter to it: those pixels were
// dropped rather than wrapped, so a game showed its left three quarters and
// looked like a broken VDP rather than a buffer that was too narrow.
//
// The narrower machines still write 256 and simply leave the last 64 columns of
// each row alone. What reads the buffer crops to the running core's active
// width; the stride is always 320.
//
// Pixels are RGB332: three bits red, three green, two blue. One byte each, so
// the browser decodes them with shifts and no palette lookup. A real NES core
// would store palette INDICES here instead and put the palette after this stage;
// the storage format does not change.
//
// Four pixels per 32-bit word. That is not a detail -- it is what makes the
// frame readable over the register bus at a sane packet count: 15360 words
// instead of 61440 byte reads.
//
// The generator walks the whole frame once per frame period, one word (four
// pixels) per clock. 15360 clocks out of the 833333 in a 60 Hz frame, so it uses
// under 2% of the time available and a PPU can later take the same port without
// anything having to be rearranged.
//
// Register map, offsets within page 0x0006_0000:
//
//   0x00  ID       "VI"
//   0x04  CTRL     bit 0 = enable, bit 1 = take pixels from the NES
//   0x08  WIDTH    read-only, 320 -- the STRIDE, not the active width
//   0x0C  HEIGHT   read-only, 240
//   0x10  FRAME    read-only, increments once per generated frame
//   0x14  PATTERN  0 bars, 1 plasma, 2 checker, 3 bouncing box
//   0x18  WORDS    read-only, words per frame (19200)
//
// The framebuffer itself is pages 0x0010_0000-0x0011_0000: 19200 words no
// longer fit the single 64 KB page it used to live in.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module video #(
	parameter W        = 320,
	parameter H        = 240,
	parameter CLK_HZ   = 50_000_000,
	parameter FPS      = 60,
	parameter FB_AW    = 15,             // 19200 words needs 15 bits
	parameter FB_DDR   = 0               // 1: the frame lives in DDR3; no block RAM here
)(
	input  wire        clk,
	input  wire        rst,

	input  wire [15:0] off,
	input  wire        we,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	output reg         err,

	// framebuffer read port, one 32-bit word = four RGB332 pixels
	input  wire [FB_AW-1:0] fb_addr,
	output wire [31:0]      fb_rdata,

	// external pixel source (the NES PPU), one pixel at a time
	input  wire        ext_valid,
	input  wire [8:0]  ext_x,
	input  wire [8:0]  ext_y,
	input  wire [7:0]  ext_rgb,

	output reg  [31:0] frame_count
);

	localparam WORDS_PER_LINE  = W / 4;                  // 80
	localparam WORDS_PER_FRAME = (W / 4) * H;            // 19200
	localparam FRAME_CYCLES    = CLK_HZ / FPS;

	// --- registers ----------------------------------------------------------
	reg        enable;
	reg        use_ext;      // 0 = pattern generator, 1 = external pixels
	reg [1:0]  pattern;

	// --- frame timing -------------------------------------------------------
	reg [23:0] frame_div;
	wire       frame_start = (frame_div == FRAME_CYCLES - 1);
	always @(posedge clk) begin
		if (rst) frame_div <= 24'd0;
		else     frame_div <= frame_start ? 24'd0 : frame_div + 24'd1;
	end

	// --- generator ----------------------------------------------------------
	reg [FB_AW-1:0] wr_idx;
	reg             drawing;
	reg [8:0]       gx;                  // pixel x of the first of the four
	reg [8:0]       gy;

	// Four pixels are produced per clock, so each needs its own x.
	wire [8:0] x0 = gx, x1 = gx + 9'd1, x2 = gx + 9'd2, x3 = gx + 9'd3;
	wire [7:0] f  = frame_count[7:0];

	function [7:0] pixel;
		input [8:0] x;
		input [8:0] y;
		input [1:0] pat;
		input [7:0] t;
		reg [2:0] r, g;
		reg [1:0] b;
		reg [8:0] bx, by;
		begin
			case (pat)
			2'd0: begin                                  // vertical colour bars
				r = x[7:5];
				g = y[7:5];
				b = x[4:3];
			end
			2'd1: begin                                  // drifting plasma
				r = x[7:5] + t[7:5];
				g = y[7:5] - t[7:5];
				b = x[6:5] ^ y[6:5];
			end
			2'd2: begin                                  // scrolling checkerboard
				r = ((x[4] ^ y[4]) ^ t[4]) ? 3'b111 : 3'b001;
				g = ((x[5] ^ y[5]) ^ t[5]) ? 3'b111 : 3'b001;
				b = ((x[3] ^ y[3])) ? 2'b11 : 2'b00;
			end
			default: begin                               // box bouncing on a grid
				// Triangle-wave position from the frame counter, so it turns
				// around at the edges instead of wrapping.
				bx = t[6] ? (9'd190 - {2'b0, t[5:0], 1'b0}) : {2'b0, t[5:0], 1'b0};
				by = t[7] ? (9'd170 - {2'b0, t[6:1], 1'b0}) : {2'b0, t[6:1], 1'b0};
				if (x >= bx && x < bx + 9'd64 && y >= by && y < by + 9'd64) begin
					r = 3'b111; g = 3'b110; b = 2'b01;
				end else begin
					r = (x[3] & y[3]) ? 3'b001 : 3'b000;
					g = 3'b000;
					b = 2'b01;
				end
			end
			endcase
			pixel = {r, g, b};
		end
	endfunction

	// Little-endian within the word: pixel x+0 in the low byte, so the host can
	// treat the stream as plain left-to-right bytes.
	wire [31:0] quad = {pixel(x3, gy, pattern, f),
	                    pixel(x2, gy, pattern, f),
	                    pixel(x1, gy, pattern, f),
	                    pixel(x0, gy, pattern, f)};

	// --- framebuffer --------------------------------------------------------
	// Four byte-wide banks rather than one 32-bit memory: the pattern generator
	// writes four pixels at once, but a PPU produces one pixel per dot, and a
	// single wide memory would force a read-modify-write for every pixel.
	// Banking by the low two bits of x lets both write naturally.
	reg [7:0] fb0 [0:WORDS_PER_FRAME-1];
	reg [7:0] fb1 [0:WORDS_PER_FRAME-1];
	reg [7:0] fb2 [0:WORDS_PER_FRAME-1];
	reg [7:0] fb3 [0:WORDS_PER_FRAME-1];
	reg [7:0] q0, q1, q2, q3;

	assign fb_rdata = {q3, q2, q1, q0};

	// One pixel from the external source: pick its bank and word.
	// ext_x[8:2], not [7:2]. Six bits reach column 255 and no further, which was
	// exactly enough while the buffer was 256 wide and silently wrong the moment
	// it was not: every pixel from 256 on folded back onto the start of its own
	// row. Seven bits carry the full 320.
	wire [FB_AW-1:0] ext_idx = ext_y[7:0] * (W/4) + {8'd0, ext_x[8:2]};
	wire ext_ok = ext_valid && (ext_x < W) && (ext_y < H);

	wire gen_wr = drawing && !use_ext;
	wire e0 = ext_ok && (ext_x[1:0] == 2'd0);
	wire e1 = ext_ok && (ext_x[1:0] == 2'd1);
	wire e2 = ext_ok && (ext_x[1:0] == 2'd2);
	wire e3 = ext_ok && (ext_x[1:0] == 2'd3);

	// One write address and one write enable per bank. Writing the same memory
	// from two different address expressions inside one block stops Vivado
	// inferring block RAM, and 60 kB then lands in distributed RAM -- which is
	// how a 4% design became a 50% one.
	wire [FB_AW-1:0] wa = gen_wr ? wr_idx : ext_idx;
	wire [7:0] wd0 = gen_wr ? quad[7:0]   : ext_rgb;
	wire [7:0] wd1 = gen_wr ? quad[15:8]  : ext_rgb;
	wire [7:0] wd2 = gen_wr ? quad[23:16] : ext_rgb;
	wire [7:0] wd3 = gen_wr ? quad[31:24] : ext_rgb;
	wire we0 = gen_wr || e0;
	wire we1 = gen_wr || e1;
	wire we2 = gen_wr || e2;
	wire we3 = gen_wr || e3;

	generate if (!FB_DDR) begin : g_bram
		always @(posedge clk) begin
			if (we0) fb0[wa] <= wd0;
			q0 <= fb0[fb_addr];
		end
		always @(posedge clk) begin
			if (we1) fb1[wa] <= wd1;
			q1 <= fb1[fb_addr];
		end
		always @(posedge clk) begin
			if (we2) fb2[wa] <= wd2;
			q2 <= fb2[fb_addr];
		end
		always @(posedge clk) begin
			if (we3) fb3[wa] <= wd3;
			q3 <= fb3[fb_addr];
		end
	end else begin : g_nobram
		// the frame is in DDR3 (fb_ddr.v); nothing is kept here
		always @(posedge clk) begin q0 <= 8'd0; q1 <= 8'd0; q2 <= 8'd0; q3 <= 8'd0; end
	end endgenerate

	always @(posedge clk) begin
		if (rst) begin
			drawing     <= 1'b0;
			wr_idx      <= {FB_AW{1'b0}};
			gx          <= 9'd0;
			gy          <= 9'd0;
			frame_count <= 32'd0;
			enable      <= 1'b1;
			use_ext     <= 1'b0;
			pattern     <= 2'd1;
		end else begin
			if (frame_start && enable && !use_ext && !drawing) begin
				drawing <= 1'b1;
				wr_idx  <= {FB_AW{1'b0}};
				gx      <= 9'd0;
				gy      <= 9'd0;
			end else if (drawing) begin
				wr_idx <= wr_idx + 1'b1;
				if (gx + 9'd4 >= W) begin
					gx <= 9'd0;
					gy <= gy + 9'd1;
				end else begin
					gx <= gx + 9'd4;
				end
				if (wr_idx == WORDS_PER_FRAME - 1) begin
					drawing     <= 1'b0;
					frame_count <= frame_count + 32'd1;
				end
			end

			if (we) begin
				case (off)
				16'h0004: begin enable <= wdata[0]; use_ext <= wdata[1]; end
				16'h0014: pattern <= wdata[1:0];
				default: ;
				endcase
			end
		end
	end

	// --- register reads ------------------------------------------------------
	always @* begin
		rdata = 32'd0;
		err   = 1'b0;
		case (off)
		16'h0000: rdata = 32'h5649_0001;         // "VI"
		16'h0004: rdata = {30'd0, use_ext, enable};
		16'h0008: rdata = W;
		16'h000C: rdata = H;
		16'h0010: rdata = frame_count;
		16'h0014: rdata = {30'd0, pattern};
		16'h0018: rdata = WORDS_PER_FRAME;
		default:  err = 1'b1;
		endcase
	end

endmodule

`default_nettype wire
