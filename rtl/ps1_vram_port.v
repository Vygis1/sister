//////////////////////////////////////////////////////////////////////////////////
// ps1_vram_port.v - the drawing engine's one VRAM port, split two ways.
//
// Writes go to the block writer (ps1_gpu_blk.v) and are posted: the engine is
// answered the clock it asks, and sixteen pixels leave for memory together.
// Reads go on to the video cache as before. What this module adds is the
// agreement between the two, so that the engine never reads a stale pixel:
//
//   - a read of a line whose block is still being gathered gets those bytes
//     forwarded over what the cache returns (a blended pixel reads the one
//     under it, which is often the one this block just wrote);
//   - a read of a line whose block is queued or on its way to memory waits
//     until it is there, and the caches have been told to drop their copy;
//   - a read-around (a texel run of eight lines) cannot take a forwarded block,
//     so for it the block in hand is flushed first and waited for;
//   - the block in hand is flushed whenever the engine has nothing to do, so
//     the picture in memory is never more than one primitive behind.
//
// The engine has one request out at a time, so once a read is issued no write
// to its line can be accepted until it is answered; the forwarded bytes are
// stable for the whole of the read.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_vram_port (
	input  wire         clk,
	input  wire         rst,

	// --- the engine ------------------------------------------------------------
	input  wire [28:0]  v_addr,
	input  wire         v_req,
	input  wire         v_we,
	input  wire [3:0]   v_be,
	input  wire [31:0]  v_wdata,
	input  wire         v_lwe,
	input  wire [127:0] v_wdata128,
	input  wire         v_around,
	input  wire         v_lin,
	// The asker uses only the line it asked for (the drawing engine's destination). The
	// video cache still fetches a run, but here it is one line: held only for its own block,
	// and the block in hand's bytes forwarded over it. A semi-transparent span reads the line
	// after the one it has just written, and as a run that read waited for the block in hand
	// to be flushed every eight pixels. The run's other lines are kept right by the cache:
	// the write that makes one stale clears it there when it lands.
	input  wire         v_one,
	output wire [31:0]  v_rdata,
	output wire [127:0] v_line,
	output wire         v_ack,
	input  wire         eng_idle,        // nothing being drawn: flush what is gathered
	input  wire         host_flush,      // the host wants memory to be the picture
	output wire         busy,            // something gathered, queued or on its way

	// --- reads, on to the video cache (through vram_wc) ---------------------
	output wire [28:0]  g_addr,
	output wire         g_req,
	output wire         g_around,
	output wire         g_lin,
	input  wire [31:0]  g_rdata,
	input  wire [127:0] g_line,
	input  wire         g_ack,

	// --- writes, an arbiter port of their own ---------------------------------
	output wire [23:0]  m_addr,
	output wire         m_req,
	output wire         m_we,
	output wire [127:0] m_wdata,
	output wire [15:0]  m_wmask,
	input  wire         m_ready,

	// --- and what the caches must forget ------------------------------------------
	output wire         inv_v,
	output wire [24:0]  inv_line
);
	wire         w_ack, idle, r_hold;
	wire [15:0]  r_fwd_m;
	wire [127:0] r_fwd_d;
	wire         rd = v_req && !v_we;

	ps1_gpu_blk #(.QAW(2)) blk (
		.clk(clk), .rst(rst),
		.w_req(v_req && v_we), .w_addr(v_addr), .w_be(v_be), .w_wdata(v_wdata),
		.w_lwe(v_lwe), .w_wdata128(v_wdata128), .w_ack(w_ack),
		.flush(eng_idle || host_flush || (rd && r_hold)), .idle(idle),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask), .m_ready(m_ready),
		.inv_v(inv_v), .inv_line(inv_line),
		.r_line(v_addr[28:4]), .r_run(v_around && !v_one), .r_hold(r_hold), .r_fwd_m(r_fwd_m), .r_fwd_d(r_fwd_d)
	);
	assign busy = !idle;

	assign g_addr   = v_addr;
	assign g_req    = rd && !r_hold;
	assign g_around = v_around;
	assign g_lin    = v_lin;

	// the gathered bytes over the cache's answer
	reg [127:0] fwd_line;
	integer k;
	always @(*)
		for (k = 0; k < 16; k = k + 1)
			fwd_line[k*8 +: 8] = r_fwd_m[k] ? r_fwd_d[k*8 +: 8] : g_line[k*8 +: 8];
	wire [3:0]  fwd_be = r_fwd_m[v_addr[3:2]*4 +: 4];
	reg  [31:0] fwd_word;
	always @(*)
		for (k = 0; k < 4; k = k + 1)
			fwd_word[k*8 +: 8] = fwd_be[k] ? r_fwd_d[v_addr[3:2]*32 + k*8 +: 8] : g_rdata[k*8 +: 8];

	assign v_rdata = fwd_word;
	assign v_line  = fwd_line;
	assign v_ack   = v_we ? w_ack : (g_ack && !r_hold);
endmodule

`default_nettype wire
