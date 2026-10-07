//////////////////////////////////////////////////////////////////////////////////
// fb_ddr.v - the display frame in DDR3: up to 640 x 480 x 16-bit RGB555, captured on
// request, read back by the host.
//
// The block-RAM framebuffer is 320 x 240 x 8 bits because that is what fits
// beside a console in the chip. A PlayStation draws 640 wide in 15-bit colour,
// and the PS1 build has no block RAM left, so its frame goes out to DDR3 and
// the browser fetches it from there.
//
// --- capture ------------------------------------------------------------------------
//
// One frame at a time, when the host asks (cap_go): the next frame the scanout
// starts is written, line by line, and cap_ready says when it is whole. Every
// frame would cost the DDR3 controller 19200 more accesses a frame -- it does
// one at a time, about a microsecond each -- for pictures the host never
// fetches; one per fetch is what the page can actually show.
//
// Pixels arrive one at a time and are gathered into 16-byte lines, eight
// pixels each, queued two deep. `hold` asks the scanout to pause while a line
// is waiting, so no line is ever dropped.
//
// --- read-back ---------------------------------------------------------------------
//
// The host reads words of the frame (row * 320 + x/2) through the register
// bus, which waits for hr_ack. One line is kept, so four consecutive words
// cost one DDR3 read.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module fb_ddr #(
	parameter [23:0] FB_LINE = 24'h04_0000,   // DDR3 line address of the frame: 4 MB
	parameter        STRIDE  = 80             // lines per row: 640 px / 8
)(
	input  wire        clk,
	input  wire        rst,

	// the picture, full width, one pixel at a time
	input  wire        frame_start,     // the scanout begins a frame
	input  wire        px_valid,
	input  wire [9:0]  px_x,
	input  wire [8:0]  px_y,
	input  wire [15:0] px_rgb,

	// ...or a whole 16-byte line of it at once, which is the same eight pixels
	// in the same order and saves taking them apart and putting them back
	input  wire        fl_valid,
	input  wire [127:0] fl_data,
	input  wire [9:0]  fl_x,
	input  wire [8:0]  fl_y,
	output wire        hold,            // please pause the scanout
	output wire        want,            // a capture is armed or running: the scanout is needed

	// capture control
	input  wire        cap_go,
	output reg         cap_ready,
	// HDMI: capture every frame, and fetch the line the picture wants next into its
	// line buffer (n64_vid with PS1=1): lf_words 128-bit words of line lf_want, written
	// to {line[0], word}
	input  wire        hdmi_on,
	input  wire [8:0]  lf_want,
	input  wire [6:0]  lf_words,
	output reg         lf_we,
	output reg  [8:0]  lf_addr,
	output reg  [127:0] lf_data,

	// host read-back: a word of the frame
	input  wire [17:0] hr_addr,
	input  wire        hr_req,
	output reg  [31:0] hr_rdata,
	output reg         hr_ack,

	// the arbiter port
	output reg  [23:0]  m_addr,
	output reg          m_req,
	output reg          m_we,
	output reg  [127:0] m_wdata,
	input  wire         m_ready,
	input  wire [127:0] m_rdata,
	input  wire         m_valid
);
	// --- capture state ---------------------------------------------------------------
	reg armed, capturing, finishing;     // asked / the frame is streaming / its last lines are draining

	// --- line assembly ---------------------------------------------------------------
	reg [23:0]  cur_line;
	reg [127:0] cur_data;
	reg         cur_v;
	// Two frames for HDMI (the second 0xA000 lines -- 640 kB, room for 640 x 480 -- after the first): the
	// capture writes the one not on screen, a finished capture waits (pend) until
	// HDMI starts its next frame and takes it, and no new capture starts meanwhile --
	// so the frame on screen is never written while it is read. (One frame, written
	// while HDMI read it, showed pixels of two frames: a blink's eye pixels one frame
	// wrong.) Without HDMI it is the one frame, as it always was.
	reg         disp_b, pend;
	wire        cap_b     = hdmi_on ? ~disp_b : 1'b0;
	wire [23:0] cap_base  = FB_LINE + (cap_b ? 24'h00_A000 : 24'd0);
	wire [23:0] disp_base = FB_LINE + ((hdmi_on && disp_b) ? 24'h00_A000 : 24'd0);
	wire [23:0] px_line = cap_base + px_y * STRIDE + {17'd0, px_x[9:3]};
	wire [23:0] fl_line = cap_base + fl_y * STRIDE + {17'd0, fl_x[9:3]};
	wire        fl_take = capturing && fl_valid;

	// --- lines waiting to be written -------------------------------------------
	// This was two deep, and `hold` went up as soon as the first of them was
	// occupied -- so the scanout was stopped after every eight pixels until a
	// DDR3 write had been accepted, one line in flight at a time. Measured on
	// the board: reading the screen took 460,363 clocks, 9.21 ms, 55% of a
	// frame, and 169,174 of those clocks were the scanout standing still with a
	// full queue. The machine redraws the screen while it is being read, so more
	// than half a redraw landed inside every capture. That is the tear.
	//
	// Sixteen deep, and `hold` only when there is nowhere left to put the next
	// line, lets the scanout run at its own speed and the writes drain behind
	// it. This is block RAM and registers on a path nothing waits on, so it
	// costs nothing the processor can feel.
	localparam QD = 16, QB = 4;
	reg [23:0]  q_addr [0:QD-1];
	reg [127:0] q_data [0:QD-1];
	reg [QB:0]  q_wp, q_rp;
	wire [QB:0] q_cnt   = q_wp - q_rp;
	wire        q_empty = (q_wp == q_rp);
	assign hold = (q_cnt >= QD[QB:0] - 5'd2);   // two spare, for the line in hand
	assign want = armed || capturing;

	// what needs pushing this cycle: the current line when a pixel starts another
	// line, or when the capture ends
	wire flush_end = capturing && frame_start;
	wire new_line  = px_valid && capturing && cur_v && (px_line != cur_line);
	wire push      = cur_v && (new_line || flush_end);

	// --- the memory side: writes first, then a host read -------------------------------
	localparam R_IDLE = 2'd0, R_WAIT = 2'd1, R_DONE = 2'd2;
	reg [1:0]   rs;
	reg [23:0]  rc_line;            // the line held for the host
	reg [127:0] rc_data;
	reg         rc_v;
	wire [15:0] hr_line = hr_addr[17:2];
	wire        hr_hit  = rc_v && (rc_line == {8'd0, hr_line});
	reg         wr_busy;            // a write is presented to the arbiter
	reg  [8:0]  lf_have, lf_line;   // the line in the buffer / being fetched
	reg  [6:0]  lf_w;
	reg         lf_on, lf_wait;     // fetching / a read of it is out

	always @(posedge clk) begin
		if (rst) begin
			armed <= 1'b0; capturing <= 1'b0; finishing <= 1'b0; cap_ready <= 1'b0;
			cur_v <= 1'b0; cur_line <= 24'd0; cur_data <= 128'd0;
			q_wp <= 0; q_rp <= 0;
			m_req <= 1'b0; m_we <= 1'b0; m_addr <= 24'd0; m_wdata <= 128'd0;
			rs <= R_IDLE; rc_v <= 1'b0; rc_line <= 24'd0; rc_data <= 128'd0;
			hr_ack <= 1'b0; hr_rdata <= 32'd0; wr_busy <= 1'b0;
			lf_have <= 9'h1FF; lf_line <= 9'd0; lf_w <= 7'd0; lf_on <= 1'b0; lf_wait <= 1'b0; lf_we <= 1'b0;
			disp_b <= 1'b0; pend <= 1'b0;
		end else begin
			hr_ack <= 1'b0;
			lf_we  <= 1'b0;

			// --- capture control ------------------------------------------------
			// (HDMI: the next frame is armed as soon as this one is in)
			if (cap_go || (hdmi_on && !armed && !capturing && !finishing && !pend)) begin armed <= 1'b1; cap_ready <= 1'b0; finishing <= 1'b0; end
			// a line wanted that is not in the buffer: fetch it
			if (hdmi_on && !lf_on && lf_want != lf_have && lf_want < 9'd480) begin
				lf_on <= 1'b1; lf_line <= lf_want; lf_w <= 7'd0;
				// the top of HDMI's frame: a finished capture goes on screen
				if (lf_want == 9'd0 && pend) begin disp_b <= ~disp_b; pend <= 1'b0; end
			end
			if (frame_start) begin
				if (armed) begin capturing <= 1'b1; armed <= 1'b0; rc_v <= 1'b0; end
				else if (capturing) begin capturing <= 1'b0; finishing <= 1'b1; end   // the frame is complete
			end
			// ready once the frame's last line has been written
			if (finishing && !cur_v && q_empty && !wr_busy && !push) begin
				cap_ready <= 1'b1; finishing <= 1'b0;
				pend <= hdmi_on;
			end

			// --- gather pixels into lines ------------------------------------------
			// a whole line, or the one being gathered a pixel at a time -- never
			// both, because the scanout does one or the other for a whole frame
			if (fl_take) begin
				q_addr[q_wp[QB-1:0]] <= fl_line;
				q_data[q_wp[QB-1:0]] <= fl_data;
				q_wp <= q_wp + 1'b1;
			end else if (push) begin
				q_addr[q_wp[QB-1:0]] <= cur_line;
				q_data[q_wp[QB-1:0]] <= cur_data;
				q_wp <= q_wp + 1'b1;
				cur_v <= 1'b0;
			end
			if (px_valid && capturing && !flush_end) begin
				if (!cur_v || new_line) begin
					cur_line <= px_line;
					cur_data <= 128'd0;
					cur_data[px_x[2:0]*16 +: 16] <= px_rgb;
					cur_v <= 1'b1;
				end else
					cur_data[px_x[2:0]*16 +: 16] <= px_rgb;
			end

			// --- the arbiter: one write or read at a time ----------------------------
			if (m_req && m_ready) begin
				m_req <= 1'b0;
				if (m_we) begin
					q_rp    <= q_rp + 1'b1;   // the write is taken
					wr_busy <= 1'b0;
				end
			end else if (!m_req) begin
				if (!q_empty && !wr_busy) begin
					m_addr  <= q_addr[q_rp[QB-1:0]];
					m_wdata <= q_data[q_rp[QB-1:0]];
					m_we <= 1'b1; m_req <= 1'b1; wr_busy <= 1'b1;
				end else if (lf_on && !lf_wait && rs == R_IDLE) begin
					// (before the host's reads: the picture cannot wait)
					m_addr <= disp_base + lf_line * STRIDE + {17'd0, lf_w}; m_we <= 1'b0; m_req <= 1'b1;
					lf_wait <= 1'b1;
				end else if (rs == R_IDLE && hr_req && !hr_hit && q_empty && !lf_wait) begin
					m_addr <= disp_base + {8'd0, hr_line}; m_we <= 1'b0; m_req <= 1'b1;
					rs <= R_WAIT;
				end
			end
			if (lf_wait && m_valid) begin
				lf_we <= 1'b1; lf_addr <= {lf_line[1:0], lf_w}; lf_data <= m_rdata;
				lf_wait <= 1'b0;
				if (lf_w + 7'd1 >= lf_words) begin lf_on <= 1'b0; lf_have <= lf_line; end
				else lf_w <= lf_w + 7'd1;
			end

			// --- host reads ----------------------------------------------------------
			case (rs)
			R_IDLE: if (hr_req && hr_hit) begin
					hr_rdata <= rc_data[hr_addr[1:0]*32 +: 32];
					hr_ack <= 1'b1;
					rs <= R_DONE;
				end
			R_WAIT: if (m_valid && !lf_wait) begin
					rc_data <= m_rdata; rc_line <= {8'd0, hr_line}; rc_v <= 1'b1;
					hr_rdata <= m_rdata[hr_addr[1:0]*32 +: 32];
					hr_ack <= 1'b1;
					rs <= R_DONE;
				end
			R_DONE: if (!hr_req) rs <= R_IDLE;    // the bus has dropped the request
			default: rs <= R_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
