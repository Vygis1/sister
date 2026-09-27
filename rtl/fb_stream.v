//////////////////////////////////////////////////////////////////////////////////
// fb_stream.v - the picture on its way to the network, straight off the
// scanout, through a queue a couple of packets deep.
//
// THE FRAME IS ASSEMBLED ON THE PC, NOT HERE. Every word the network core
// sends carries its frame id and its offset (net_core.v), and the host only
// shows a frame once every word of it has arrived under one id (pc/server.py).
// So this does not need to hold a frame -- it used to: 64K words, 64 block
// RAMs, 256 KB, a quarter of the chip's block RAM, to hold a picture that
// already sits in video memory. Now the scanout reads the picture out of VRAM
// at the network's pace and this holds only what is in flight.
//
// --- frame boundaries travel with the data ------------------------------------
//
// Each word is stored with a flag: the first word of a capture. The queue is
// never emptied underneath the network core (that is what rotated and spliced
// pictures before -- see the history in git). Instead:
//
//   - a capture that is abandoned part way (the game flipped buffers while it
//     was being read) leaves its words in the queue; the network core sends
//     them under the old frame id, meets the next capture's first word, and
//     drops the unfinished frame. The host never completes it, so never shows
//     it. A skipped frame, never a torn one.
//   - at the top of a frame the network core throws away anything that is not
//     a first word, so a frame always starts at a capture's first pixel.
//
// --- when the scanout may start a capture ---------------------------------------
//
// `want` is high when no capture is running and the previous one has left the
// queue. A capture that is abandoned (`abort`) lets the next one start at the
// very flip that abandoned it. Nothing here waits on the network core's
// bookkeeping, so nothing it does -- a timeout, a dropped frame -- can leave
// the scanout waiting for a signal that is never coming.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module fb_stream #(
	parameter AW = 11                 // 2048 words: about six packets in flight
)(
	input  wire        clk,
	input  wire        rst,

	// --- from the GPU's scanout ---------------------------------------------
	input  wire        frame_start,   // this scan begins a frame
	input  wire        frame_done,    // ...and this ends it
	input  wire        abort,         // ...or this: the scan was abandoned at a flip
	input  wire        px_valid,
	input  wire [9:0]  px_x,
	input  wire [15:0] px_rgb,
	output wire        hold,          // nearly full: stop reading pixels

	// --- to the network core ------------------------------------------------
	input  wire        rd_en,         // take the word at the head
	output wire [31:0] rd_data,
	output wire        rd_valid,
	output wire        head_sof,      // the word at the head is the first of a capture

	// --- starting a scan ----------------------------------------------------
	input  wire        arm,           // (unused: see `want` above)
	output wire        want,          // a scan may start
	output wire        empty
);
	localparam DEPTH = 1 << AW;

	reg [32:0] buf_mem [0:DEPTH-1];   // {first word of a capture, two pixels}
	reg [AW:0] wr_ptr, rd_ptr;
	wire [AW:0] level = wr_ptr - rd_ptr;

	assign empty = (wr_ptr == rd_ptr);
	// Nearly full rather than full: the scanout takes a few cycles to notice.
	assign hold  = (level >= DEPTH - 8);

	reg capturing;      // a scan is running
	reg tail;           // a finished scan still has words in the queue
	assign want = !capturing && !tail;

	// Two pixels to a word, the left one in the low half, which is the order the
	// host and the page already expect.
	reg [15:0] lo;
	reg        have_lo;
	reg        sof_next;   // the next word written is the first of a capture

	// The read port is registered: rd_q shows the slot at rd_ptr a clock after
	// it is addressed. A word written into an empty queue is announced by the
	// pointers the next clock, when rd_q still holds what that slot held a lap
	// ago -- so a word is offered only once its slot has been read.
	reg [32:0] rd_q;
	reg        wrote_d;
	wire       wr_now = px_valid && px_x[0] && have_lo && !frame_start;
	always @(posedge clk) wrote_d <= wr_now;
	assign rd_valid = !empty && !(wrote_d && (level == {{AW{1'b0}}, 1'b1}));
	assign rd_data  = rd_q[31:0];
	assign head_sof = rd_valid && rd_q[32];
	always @(posedge clk) rd_q <= buf_mem[rd_ptr[AW-1:0]];

	always @(posedge clk) begin
		if (rst) begin
			wr_ptr <= 0; rd_ptr <= 0; have_lo <= 1'b0; lo <= 16'd0;
			capturing <= 1'b0; tail <= 1'b0; sof_next <= 1'b0;
		end else begin
			if (frame_start) begin
				capturing <= 1'b1;
				sof_next  <= 1'b1;
				have_lo   <= 1'b0;
			end else if (px_valid) begin
				if (!px_x[0]) begin
					lo      <= px_rgb;
					have_lo <= 1'b1;
				end else if (have_lo) begin
					buf_mem[wr_ptr[AW-1:0]] <= {sof_next, px_rgb, lo};
					wr_ptr   <= wr_ptr + 1'b1;
					have_lo  <= 1'b0;
					sof_next <= 1'b0;
				end
			end
			if (frame_done) begin capturing <= 1'b0; tail <= 1'b1; end
			if (abort)      capturing <= 1'b0;
			// the finished capture's last word has left the queue (sent, or thrown
			// away by a network core that gave the frame up)
			if (tail && !capturing && empty && !frame_done) tail <= 1'b0;

			if (rd_en && !empty) rd_ptr <= rd_ptr + 1'b1;
		end
	end
endmodule

`default_nettype wire
