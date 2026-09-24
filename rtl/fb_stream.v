//////////////////////////////////////////////////////////////////////////////////
// fb_stream.v - the picture on its way to the network, without going through
// memory first.
//
// The frame used to be read out of video memory, written to DDR3, and then read
// back out of DDR3 a word at a time so the network core could put it in packets.
// Measured on the wire, that cost 42 ms a frame -- about ten thousand memory
// writes and ten thousand reads, at roughly a microsecond each -- against 25 ms
// actually spent sending. It held the web page to fifteen frames a second.
//
// The scanout already produces exactly the pixels wanted, in order. This takes
// them as they come, pairs them into words, and holds a couple of packets'
// worth so the network core can send one while the next is being read. Nothing
// touches DDR3 on this path at all.
//
// --- keeping in step ------------------------------------------------------------
//
// A scan is started only when the network core has finished the previous frame,
// so the buffer is never cleared underneath a frame that is still going out.
// `hold` stops the scanout when the buffer is nearly full; the scanout is
// pausable between rows and words, which is what that signal is already for.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module fb_stream #(
	parameter AW = 10                 // 1024 words: about three packets in hand
)(
	input  wire        clk,
	input  wire        rst,

	// --- from the GPU's scanout ---------------------------------------------
	input  wire        frame_start,   // this scan begins a frame
	input  wire        frame_done,    // ...and this ends it: the picture is whole
	input  wire        px_valid,
	input  wire [9:0]  px_x,
	input  wire [15:0] px_rgb,
	output wire        hold,          // nearly full: stop reading pixels

	// --- to the network core ------------------------------------------------
	input  wire        rd_en,         // take the word at the head
	output wire [31:0] rd_data,
	output wire        rd_valid,

	// --- starting a scan ----------------------------------------------------
	input  wire        arm,           // the previous frame has gone out
	output reg         want,          // a scan is wanted: the scanout may run
	output wire        empty,
	// A frame is offered to the network only once ALL of it is here. Sending as
	// the scanout produced it meant the network could catch up with the scanout
	// -- the scanout waits on VRAM, the drawing engine has it -- and the network
	// core gives a frame up after a millisecond of nothing, so the page drew a
	// frame with a band missing: its own background showing through the middle
	// of the picture. That is what looked like tearing.
	output reg         full_frame
);
	localparam DEPTH = 1 << AW;

	reg [31:0] buf_mem [0:DEPTH-1];
	reg [AW:0] wr_ptr, rd_ptr;
	wire [AW:0] level = wr_ptr - rd_ptr;

	assign empty    = (wr_ptr == rd_ptr);
	// The read port is registered: rd_q shows the slot at rd_ptr a clock after
	// it is addressed. A word written this clock is announced by the pointers
	// next clock, when rd_q still holds what that slot held a lap ago -- 1024
	// words earlier in the frame. The network core took exactly that whenever
	// it caught the scanout with the buffer empty: a ghost of the picture on
	// scattered rows. So a word is offered only once its slot has been read.

	// Nearly full rather than full: the scanout takes a few cycles to notice.
	assign hold     = (level >= DEPTH - 8);

	// Two pixels to a word, the left one in the low half, which is the order the
	// host and the page already expect from the register path.
	reg [15:0] lo;
	reg        have_lo;

	reg [31:0] rd_q;
	assign rd_data = rd_q;
	reg        wrote_d;
	always @(posedge clk) wrote_d <= px_valid && px_x[0] && have_lo && !frame_start;
	assign rd_valid = !empty && !(wrote_d && (level == {{AW{1'b0}}, 1'b1}));
	always @(posedge clk) rd_q <= buf_mem[rd_ptr[AW-1:0]];

	always @(posedge clk) begin
		if (rst) begin
			wr_ptr <= 0; rd_ptr <= 0; have_lo <= 1'b0; lo <= 16'd0; want <= 1'b1; full_frame <= 1'b0;
		end else begin
			if (arm) want <= 1'b1;

			if (frame_done)  full_frame <= 1'b1;
			if (frame_start) begin
				full_frame <= 1'b0;
				// A scan is starting: nothing of the previous one is wanted, and
				// the network core restarts at the top of the frame with it.
				wr_ptr  <= 0;
				rd_ptr  <= 0;
				have_lo <= 1'b0;
				want    <= 1'b0;
			end else if (px_valid) begin
				if (!px_x[0]) begin
					lo      <= px_rgb;
					have_lo <= 1'b1;
				end else if (have_lo) begin
					buf_mem[wr_ptr[AW-1:0]] <= {px_rgb, lo};
					wr_ptr  <= wr_ptr + 1'b1;
					have_lo <= 1'b0;
				end
			end

			if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;
		end
	end
endmodule

`default_nettype wire
