//////////////////////////////////////////////////////////////////////////////////
// ps1_gpu_blk.v - the drawing engine's way out to VRAM: 32-byte blocks, posted.
//
// The engine used to push every write through a write-combiner into an 8 KB
// write-back cache, and waited: for the combiner to hand a line over, for the
// cache to evict and allocate, and (until the byte mask went in) for a line to
// be READ before a partial write could land. Measured on the board that was the
// largest single cost per pixel, and it is a cost the fast PlayStation cores do
// not have at all. They gather pixels into a block and post it.
//
// So: pixels arrive as words (two 16-bit pixels, with byte enables) or as whole
// 16-byte lines, and are gathered into the 32-byte block they belong to --
// sixteen pixels, two of the memory's lines, keyed by the address above bit 4.
// When a write lands in a different block, or the engine says flush, the
// gathered block goes into a small queue and the engine carries straight on;
// the queue drains to the memory arbiter as masked line writes, fire and
// forget. The engine waits only when the queue is full, which takes a burst of
// writes to unrelated blocks faster than the memory can post them.
//
// Nothing here reads. A block that must be blended with what is under it is
// read by the engine ahead of time through the video cache's read-around, and
// the caches are told which line was just written (inv_*) so a copy they hold
// is dropped: the write went past them.
//
// Ordering: writes to the same block are gathered in order; blocks leave in the
// order they were gathered; the arbiter and the memory keep that order. A read
// the engine issues of a line that may still be queued must wait for `idle`.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_gpu_blk #(
	parameter QAW = 2                     // 2^QAW blocks may wait to be written
)(
	input  wire         clk,
	input  wire         rst,

	// --- the engine's writes ------------------------------------------------------
	input  wire         w_req,            // held until w_ack
	input  wire [28:0]  w_addr,           // byte address: word aligned, or line aligned with w_lwe
	input  wire [3:0]   w_be,
	input  wire [31:0]  w_wdata,
	input  wire         w_lwe,            // a whole 16-byte line at once
	input  wire [127:0] w_wdata128,
	output wire         w_ack,            // taken this clock
	input  wire         flush,            // hand over what is gathered
	output wire         idle,             // nothing gathered, queued or being written

	// --- memory: an arbiter port, 16-byte lines with a byte mask -------------------
	output reg  [23:0]  m_addr,           // line address
	output reg          m_req,
	output wire         m_we,
	output reg  [127:0] m_wdata,
	output reg  [15:0]  m_wmask,
	input  wire         m_ready,

	// --- a line just went to memory past the caches ---------------------------------
	output reg          inv_v,
	output reg  [24:0]  inv_line,         // byte address >> 4

	// --- a read the engine wants: is a write to it still on its way? ---------------
	// The block in hand is forwarded (r_fwd_*: the bytes of that line it holds);
	// a block queued, draining or being told to the caches means wait. A run
	// read (r_run: the whole aligned run of PFL lines a read-around fetches)
	// cannot be forwarded, so for it the block in hand means wait too.
	input  wire [24:0]  r_line,
	input  wire         r_run,
	output wire         r_hold,
	output wire [15:0]  r_fwd_m,
	output wire [127:0] r_fwd_d
);
	assign m_we = 1'b1;

	// --- the block being gathered ---------------------------------------------------
	reg          acc_v;
	reg  [23:0]  acc_blk;                 // w_addr[28:5]
	reg  [255:0] acc_d;
	reg  [31:0]  acc_m;                   // one bit per byte

	wire [23:0] w_blk = w_addr[28:5];
	wire        same  = acc_v && (w_blk == acc_blk);

	// --- the queue of gathered blocks ------------------------------------------------
	localparam QD = 1 << QAW;
	reg  [23:0]  q_blk [0:QD-1];
	reg  [255:0] q_d   [0:QD-1];
	reg  [31:0]  q_m   [0:QD-1];
	reg  [QAW:0] q_wp, q_rp;
	wire         q_empty = (q_wp == q_rp);
	wire         q_full  = ((q_wp - q_rp) == QD[QAW:0]);

	// A write is taken when it joins the block in hand, starts one from nothing,
	// or can push the block in hand into the queue and start the next.
	// flush is remembered: a pulse that lands while the queue is full would
	// otherwise be lost, and the block in hand would sit there for ever
	reg  flush_p;
	wire hand_over = acc_v && ((w_req && !same) || flush || flush_p);
	assign w_ack   = w_req && (same || !acc_v || !q_full);
	wire   push    = hand_over && !q_full;

	// what this write contributes: bytes and their mask, positioned in the block
	reg  [255:0] w_bits;
	reg  [31:0]  w_mask;
	integer k;
	always @(*) begin
		w_bits = 256'd0;
		w_mask = 32'd0;
		if (w_lwe) begin
			w_bits[w_addr[4]*128 +: 128] = w_wdata128;
			w_mask[w_addr[4]*16  +: 16]  = 16'hFFFF;
		end else begin
			for (k = 0; k < 4; k = k + 1)
				if (w_be[k]) begin
					w_bits[w_addr[4:2]*32 + k*8 +: 8] = w_wdata[k*8 +: 8];
					w_mask[w_addr[4:2]*4 + k]         = 1'b1;
				end
		end
	end

	// merge: bytes this write covers replace what is gathered, the rest stay
	reg [255:0] merged_d;
	integer b;
	always @(*) begin
		for (b = 0; b < 32; b = b + 1)
			merged_d[b*8 +: 8] = w_mask[b] ? w_bits[b*8 +: 8] : acc_d[b*8 +: 8];
	end

	always @(posedge clk) begin
		if (rst) begin
			acc_v <= 1'b0; acc_blk <= 24'd0; acc_d <= 256'd0; acc_m <= 32'd0;
			q_wp <= 0; flush_p <= 1'b0;
		end else begin
			if (flush && acc_v && !push) flush_p <= 1'b1;
			else if (push || !acc_v)       flush_p <= 1'b0;
			if (push) begin
				q_blk[q_wp[QAW-1:0]] <= acc_blk;
				q_d  [q_wp[QAW-1:0]] <= acc_d;
				q_m  [q_wp[QAW-1:0]] <= acc_m;
				q_wp <= q_wp + 1'b1;
			end
			if (w_ack) begin
				if (same) begin
					acc_d <= merged_d;
					acc_m <= acc_m | w_mask;
				end else begin
					// a new block: only this write's bytes are real
					acc_v   <= 1'b1;
					acc_blk <= w_blk;
					acc_d   <= w_bits;
					acc_m   <= w_mask;
				end
			end else if (push) begin
				acc_v <= 1'b0;             // handed over on a flush, nothing new
			end
		end
	end

	// --- draining: each block is up to two masked line writes ---------------------------
	localparam D_IDLE = 2'd0, D_LOW = 2'd1, D_HIGH = 2'd2;
	reg [1:0]  ds;
	wire [23:0]  d_blk = q_blk[q_rp[QAW-1:0]];
	wire [255:0] d_d   = q_d  [q_rp[QAW-1:0]];
	wire [31:0]  d_m   = q_m  [q_rp[QAW-1:0]];

	always @(posedge clk) begin
		if (rst) begin
			ds <= D_IDLE; m_req <= 1'b0; m_addr <= 24'd0; m_wdata <= 128'd0; m_wmask <= 16'd0;
			q_rp <= 0; inv_v <= 1'b0; inv_line <= 25'd0;
		end else begin
			inv_v <= 1'b0;
			case (ds)
			D_IDLE: if (!q_empty) begin
					if (d_m[15:0] != 16'd0) begin
						m_addr <= {d_blk[22:0], 1'b0}; m_wdata <= d_d[127:0]; m_wmask <= d_m[15:0];
						m_req <= 1'b1; ds <= D_LOW;
					end else if (d_m[31:16] != 16'd0) begin
						m_addr <= {d_blk[22:0], 1'b1}; m_wdata <= d_d[255:128]; m_wmask <= d_m[31:16];
						m_req <= 1'b1; ds <= D_HIGH;
					end else begin
						q_rp <= q_rp + 1'b1;   // nothing in it after all
					end
				end
			D_LOW: if (m_ready) begin
					inv_v <= 1'b1; inv_line <= {d_blk, 1'b0};
					if (d_m[31:16] != 16'd0) begin
						m_addr <= {d_blk[22:0], 1'b1}; m_wdata <= d_d[255:128]; m_wmask <= d_m[31:16];
						ds <= D_HIGH;          // m_req stays up for the second line
					end else begin
						m_req <= 1'b0; q_rp <= q_rp + 1'b1; ds <= D_IDLE;
					end
				end
			D_HIGH: if (m_ready) begin
					inv_v <= 1'b1; inv_line <= {d_blk, 1'b1};
					m_req <= 1'b0; q_rp <= q_rp + 1'b1; ds <= D_IDLE;
				end
			default: ds <= D_IDLE;
			endcase
		end
	end

	// --- the read check -----------------------------------------------------------------
	wire [23:0] r_blk = r_line[24:1];
	function match;
		input [23:0] a, b; input run;
		match = run ? (a[23:2] == b[23:2]) : (a == b);
	endfunction
	// slot j is occupied when it is fewer than (wp - rp) slots past rp
	wire [QAW:0] q_cnt = q_wp - q_rp;
	reg q_match;
	integer j;
	always @(*) begin
		q_match = 1'b0;
		for (j = 0; j < QD; j = j + 1)
			if (({1'b0, j[QAW-1:0] - q_rp[QAW-1:0]} < q_cnt) && match(q_blk[j], r_blk, r_run)) q_match = 1'b1;
	end
	wire acc_match = acc_v && match(acc_blk, r_blk, r_run);
	assign r_hold  = q_match
	              || ((ds != D_IDLE) && match(d_blk, r_blk, r_run))
	              || (inv_v && match(inv_line[24:1], r_blk, r_run))
	              || (r_run && acc_match);
	assign r_fwd_m = (acc_match && !r_run) ? acc_m[r_line[0]*16  +: 16]  : 16'd0;
	assign r_fwd_d = acc_d[r_line[0]*128 +: 128];

	assign idle = !acc_v && q_empty && (ds == D_IDLE);
endmodule

`default_nettype wire
