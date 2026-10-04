//////////////////////////////////////////////////////////////////////////////////
// tb_n64_rdp_stream - n64_rdp_stream.v (the RDP's and the RSP's read-ahead) against a
// memory that answers in order after a random delay, taken by an arbiter that accepts
// at random as n64_top's does (a read presented is taken, held, acknowledged a clock
// later). The client asks for lines in runs with jumps; flushes come at random, held
// back while a read is in the arbiter's hands (hold) and stopping the requests (stop),
// as n64_top wires them. Writes land at random near where the client reads, and are
// snooped (s_v/s_line): a hit flushes, as n64_top's x_flush_p does. Each line has a version
// a write bumps; a read returns the version current when it was taken. Every line handed to
// the client must be the line it asked for, as it is now.
//
//   ./tools/sim.sh tb_n64_rdp_stream
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_rdp_stream;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg          c_req = 0;  reg [19:0] c_line = 0;
	wire         c_ack;  wire [127:0] c_data;
	wire         q_valid;  wire [19:0] q_line;
	reg          q_ready = 0, q_rs = 0;  reg [127:0] q_rs_data = 0;
	reg          flush_p = 0;
	// the arbiter: idle, or a read taken (held for a random time), then its acknowledge
	reg          taking = 0;  reg [19:0] t_line = 0;  integer t_wait = 0;
	wire         hold = q_valid || taking || q_ready;
	wire         flush = flush_p && !hold;
	reg          w_v = 0;  reg [19:0] w_line = 0;  wire s_hit;
	reg  [7:0]   ver [0:65535];  integer lw_t [0:65535];  integer cyc = 0;
	always @(posedge clk) cyc <= cyc + 1;
	integer vi; initial for (vi = 0; vi < 65536; vi = vi + 1) begin ver[vi] = 8'd0; lw_t[vi] = -10; end

	n64_rdp_stream dut (.clk(clk), .rst(rst), .flush(flush), .hold(hold), .stop(flush_p),
		.s_v(w_v), .s_line({4'd0, w_line}), .s_hit(s_hit),
		.c_req(c_req && !flush_p), .c_line(c_line), .c_ack(c_ack), .c_data(c_data),
		.q_valid(q_valid), .q_line(q_line), .q_ready(q_ready), .q_rs(q_rs), .q_rs_data(q_rs_data));

	function [127:0] mem; input [19:0] l; input [7:0] v; mem = {{3{l, 12'hA5C}}, l, 4'h5, v}; endfunction

	// the memory: reads taken go in a queue, each answered after a random delay, in order
	reg  [19:0]  mq [0:63];  reg [7:0] mqv [0:63];  integer mq_h = 0, mq_t = 0, m_wait = 0;
	reg [31:0] rnd = 32'h1234_5678;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
	integer errors = 0, acks = 0, reads = 0, flushes = 0, snoops = 0, i;
	always @(posedge clk) begin
		q_ready <= 1'b0; q_rs <= 1'b0;
		if (!rst) begin
			// take a presented read now and then; acknowledge it after a while
			if (!taking && !q_ready && q_valid && rnd[2:0] != 3'd0) begin   // (not on the acknowledge's clock: n64_top's !x_qr)
				taking <= 1'b1; t_line <= q_line; t_wait <= rnd[6:4];
			end else if (taking) begin
				if (t_wait == 0) begin
					taking <= 1'b0; q_ready <= 1'b1;
					mq[mq_t % 64] <= t_line; mqv[mq_t % 64] <= ver[t_line[15:0]]; mq_t <= mq_t + 1; reads = reads + 1;
				end else t_wait <= t_wait - 1;
			end
			// answer the oldest read after a random delay
			if (mq_h != mq_t) begin
				if (m_wait == 0) begin
					q_rs <= 1'b1; q_rs_data <= mem(mq[mq_h % 64], mqv[mq_h % 64]); mq_h <= mq_h + 1; m_wait <= rnd[12:9];
				end else m_wait <= m_wait - 1;
			end
			if (flush) begin flush_p <= 1'b0; flushes = flushes + 1; end
			// a write now and then near the client (never on the clock a read is taken: one
			// arbiter, as in n64_top); its line's version moves on, and it is snooped
			// (taken on the clock w_v is up: its version moves on then, and it is snooped then)
			if (w_v) begin ver[w_line[15:0]] <= ver[w_line[15:0]] + 8'd1; lw_t[w_line[15:0]] = cyc; end
			w_v <= 1'b0;
			if (!taking && !q_ready && !q_valid && rnd[19:16] == 4'd0) begin   // (the arbiter idle: not taking a read, as n64_top's S_RQ)
				w_v <= 1'b1; w_line <= c_line + {17'd0, rnd[22:20]};
			end
			if (s_hit) begin flush_p <= 1'b1; snoops = snoops + 1; end
			// the client: a line handed over must be the one asked for
			if (c_ack) begin
				acks = acks + 1;
				// (a line handed out on the clock its write was taken may be either: the two are at once)
				if (c_data !== mem(c_line, ver[c_line[15:0]]) && !(lw_t[c_line[15:0]] >= cyc - 1 && c_data === mem(c_line, ver[c_line[15:0]] - 8'd1))) begin
					errors = errors + 1;
					if (errors < 10) $display("tb_n64_rdp_stream: line %05x got %032x at %0d (want v%0d, written at %0d) b %05x r %05x n %05x live %0d drop %0d", c_line, c_data, cyc, ver[c_line[15:0]], lw_t[c_line[15:0]], dut.b, dut.r, dut.n, dut.live, dut.drop);
				end
			end
		end
	end
	// the client's requests: mostly the next line, sometimes a jump; a flush now and then
	// (as a DMA's start or an END write), never on the clock a request is acknowledged
	always @(posedge clk) if (!rst) begin
		if (c_ack) c_req <= 1'b0;
		else if (!c_req && !flush_p && rnd[3:0] != 4'd0) begin
			c_req <= 1'b1;
			case (rnd[15:13])
			3'd0: c_line <= {6'd0, rnd[29:16]};                  // a jump
			3'd1: c_line <= c_line;                      // the same line again
			default: c_line <= c_line + 20'd1;           // the next
			endcase
		end
		if (!c_req && rnd[27:22] == 6'd0) flush_p <= 1'b1;
	end
	initial begin
		repeat (5) @(posedge clk); rst = 0;
		repeat (400000) @(posedge clk);
		$display("tb_n64_rdp_stream: %0d lines handed over, %0d reads, %0d flushes, %0d snoop hits, %0d wrong", acks, reads, flushes, snoops, errors);
		if (errors != 0) $display("tb_n64_rdp_stream: FAIL");
		else $display("tb_n64_rdp_stream: all checks passed");
		$finish;
	end
endmodule

`default_nettype wire
