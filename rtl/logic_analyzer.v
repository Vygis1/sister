//////////////////////////////////////////////////////////////////////////////////
// logic_analyzer.v - 32 channels into block RAM, read back over fpgalink.
//
// The instrument this whole project has been missing. Two LEDs cannot tell you
// what a bus is doing; this can, and the capture comes out in a browser.
//
// Pre-trigger is the feature that makes it worth building. Arming and then
// waiting for an event only ever shows you the aftermath. Here the buffer is
// circular and always running, so when the trigger fires the samples from BEFORE
// it are already captured -- which is how you see what caused something rather
// than what followed it.
//
// Sequence after ARM:
//
//   prefill   collect PRETRIG samples, ignoring the trigger, so there is
//             always a full pre-trigger window to show
//   waiting   trigger armed; the buffer keeps rolling, discarding the oldest
//   post      trigger hit -- collect DEPTH-PRETRIG more, then stop
//
// At rest the buffer therefore holds exactly DEPTH samples: PRETRIG of them
// from before the trigger and the rest from after. The oldest lives at the
// write pointer, and the readout maps logical index to physical position so the
// host sees plain chronological order and never has to know about the wrap.
//
// Trigger precedence: any edge configured wins; otherwise a level match on
// TRIG_MASK; otherwise fire immediately, which makes a free-running capture the
// default rather than something you have to configure.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module logic_analyzer #(
	parameter DEPTH_MAX = 4096,
	parameter AW        = 12          // log2(DEPTH_MAX)
)(
	input  wire        clk,
	input  wire        rst,
	input  wire [31:0] probe,

	// register slave, offsets per docs/PROTOCOL.md
	input  wire [15:0] off,
	input  wire        we,
	input  wire        re,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	output reg         err,           // 1 = offset not mapped

	// capture buffer, logical index
	input  wire [AW-1:0] buf_addr,
	output wire [31:0]   buf_rdata
);

	localparam S_IDLE = 2'd0, S_PREFILL = 2'd1, S_WAIT = 2'd2, S_POST = 2'd3;

	reg [31:0] chan_mask;
	reg [31:0] divisor;
	reg [31:0] depth;
	reg [31:0] pretrig;
	reg [31:0] trig_mask, trig_value, trig_rise, trig_fall;

	reg [1:0]  state;
	reg        triggered, done;

	reg [AW-1:0] wr_ptr;
	reg [AW-1:0] start_ptr;
	reg [31:0]   pre_cnt;
	reg [31:0]   post_cnt;

	// --- sample clock -------------------------------------------------------
	// div_cnt must be reset, not merely assigned. Left uninitialised it is X in
	// simulation, samp = (X >= divisor) is X, and the sample strobe never fires
	// -- a capture that works on silicon (Xilinx flops power up at zero) and is
	// dead in the testbench.
	reg [31:0] div_cnt;
	wire       samp = (div_cnt >= divisor);
	always @(posedge clk) begin
		if (rst) div_cnt <= 32'd0;
		else     div_cnt <= samp ? 32'd0 : div_cnt + 32'd1;
	end

	// --- trigger ------------------------------------------------------------
	wire [31:0] cur = probe & chan_mask;
	reg  [31:0] prev;

	wire level_hit = ((cur ^ trig_value) & trig_mask) == 32'd0;
	wire edge_hit  = |((cur & ~prev) & trig_rise) | |((~cur & prev) & trig_fall);
	wire any_edge  = (trig_rise != 32'd0) || (trig_fall != 32'd0);

	wire trig_hit = any_edge            ? edge_hit
	              : (trig_mask != 32'd0) ? level_hit
	                                     : 1'b1;

	// --- buffer -------------------------------------------------------------
	reg [31:0] mem [0:DEPTH_MAX-1];
	reg [31:0] buf_q;
	assign buf_rdata = buf_q;

	// Logical index to physical slot. buf_addr and start_ptr are both below
	// depth, so their sum is below twice depth and one conditional subtract is
	// enough -- no modulo needed.
	wire [AW:0]   raw_idx  = {1'b0, start_ptr} + {1'b0, buf_addr};
	wire [AW:0]   wrapped  = raw_idx - depth[AW:0];
	wire [AW-1:0] phys_idx = (raw_idx >= depth[AW:0]) ? wrapped[AW-1:0] : raw_idx[AW-1:0];

	wire        capturing = (state != S_IDLE) && !done;
	wire [AW-1:0] next_ptr = (wr_ptr + 1'b1 == depth[AW-1:0]) ? {AW{1'b0}}
	                                                          : wr_ptr + 1'b1;

	always @(posedge clk) begin
		if (capturing && samp) mem[wr_ptr] <= cur;
		buf_q <= mem[phys_idx];
	end

	// --- capture sequencer ---------------------------------------------------
	always @(posedge clk) begin
		if (rst) begin
			state      <= S_IDLE;
			done       <= 1'b0;
			triggered  <= 1'b0;
			wr_ptr     <= {AW{1'b0}};
			start_ptr  <= {AW{1'b0}};
			pre_cnt    <= 32'd0;
			post_cnt   <= 32'd0;
			prev       <= 32'd0;
			chan_mask  <= 32'hFFFF_FFFF;
			divisor    <= 32'd0;
			depth      <= DEPTH_MAX;
			pretrig    <= DEPTH_MAX / 4;
			trig_mask  <= 32'd0;
			trig_value <= 32'd0;
			trig_rise  <= 32'd0;
			trig_fall  <= 32'd0;
		end else begin
			if (samp) prev <= cur;

			case (state)
			S_IDLE: ;

			S_PREFILL: if (samp) begin
				wr_ptr <= next_ptr;
				if (pre_cnt + 32'd1 >= pretrig) state <= S_WAIT;
				else pre_cnt <= pre_cnt + 32'd1;
			end

			S_WAIT: if (samp) begin
				wr_ptr <= next_ptr;
				if (trig_hit) begin
					triggered <= 1'b1;
					post_cnt  <= 32'd0;
					state     <= S_POST;
				end
			end

			S_POST: if (samp) begin
				wr_ptr <= next_ptr;
				if (post_cnt + 32'd1 >= (depth - pretrig)) begin
					// The buffer now holds exactly `depth` samples and the
					// oldest is the one the pointer is about to overwrite.
					start_ptr <= next_ptr;
					done      <= 1'b1;
					state     <= S_IDLE;
				end else post_cnt <= post_cnt + 32'd1;
			end
			endcase

			// --- register writes -------------------------------------------
			if (we) begin
				case (off)
				16'h0004: begin
					if (wdata[2]) begin                   // RESET
						state <= S_IDLE; done <= 1'b0; triggered <= 1'b0;
						wr_ptr <= {AW{1'b0}}; start_ptr <= {AW{1'b0}};
					end
					if (wdata[0]) begin                   // ARM
						state <= S_PREFILL; done <= 1'b0; triggered <= 1'b0;
						wr_ptr <= {AW{1'b0}}; start_ptr <= {AW{1'b0}};
						pre_cnt <= 32'd0; post_cnt <= 32'd0;
					end
					if (wdata[1] && state == S_WAIT) begin // FORCE_TRIG
						triggered <= 1'b1;
						post_cnt  <= 32'd0;
						state     <= S_POST;
					end
				end
				16'h000C: chan_mask  <= wdata;
				16'h0010: divisor    <= wdata;
				// Clamp so a depth larger than the RAM cannot make the pointer
				// arithmetic wrap somewhere the readout cannot follow.
				16'h0014: depth      <= (wdata == 0 || wdata > DEPTH_MAX) ? DEPTH_MAX : wdata;
				16'h0018: pretrig    <= wdata;
				16'h001C: trig_mask  <= wdata;
				16'h0020: trig_value <= wdata;
				16'h0024: trig_rise  <= wdata;
				16'h0028: trig_fall  <= wdata;
				default: ;
				endcase
			end
		end
	end

	// Keep the pre-trigger window inside the buffer whatever the host asked for.
	wire [31:0] pretrig_eff = (pretrig >= depth) ? (depth - 32'd1) : pretrig;

	// How far along the capture is, for the progress readout in the UI.
	wire [31:0] fill_level = done                 ? depth
	                       : (state == S_PREFILL) ? pre_cnt
	                       : (state == S_WAIT)    ? pretrig_eff
	                       : (state == S_POST)    ? (pretrig_eff + post_cnt)
	                                              : 32'd0;

	// --- register reads ------------------------------------------------------
	always @* begin
		rdata = 32'd0;
		err   = 1'b0;
		case (off)
		16'h0000: rdata = 32'h4C41_0001;                          // "LA"
		16'h0004: rdata = {29'd0, 1'b0, triggered, (state != S_IDLE)};
		16'h0008: rdata = {fill_level[15:0], 13'd0, done, triggered, (state != S_IDLE)};
		16'h000C: rdata = chan_mask;
		16'h0010: rdata = divisor;
		16'h0014: rdata = depth;
		16'h0018: rdata = pretrig_eff;
		16'h001C: rdata = trig_mask;
		16'h0020: rdata = trig_value;
		16'h0024: rdata = trig_rise;
		16'h0028: rdata = trig_fall;
		default:  err = 1'b1;
		endcase
	end

endmodule

`default_nettype wire
