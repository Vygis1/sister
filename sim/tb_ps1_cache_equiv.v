// tb_ps1_cache_equiv.v - the cache with its valid/dirty bits in LUT-RAM must
// behave EXACTLY as the one with them in flip-flops (sim/ps1_cache_old_model.v).
//
// Two pairs, old and new side by side on the same random traffic, and every
// output compared on every clock:
//   pair V: the VRAM cache's shape (reads go round, invalidations from the
//           block writer, line writes)
//   pair C: the CPU cache's shape (FAST_ACK, both ports write)
// Sixteen lines instead of 512, so evictions, dirty write-backs, a fill and an
// invalidation of the same line on the same clock, and resets with dirty lines
// still in the cache all happen constantly. The one intended difference -- the
// new cache spends LINES clocks after a reset clearing its valid banks -- is
// stepped round by giving neither pair any traffic for that long.
`timescale 1ns/1ps
`default_nettype none

module cache_equiv_pair #(
	parameter IDX = 4,
	parameter B_NOALLOC = 0,
	parameter A_AROUND = 0,
	parameter FAST_ACK = 0,
	parameter USE_INV = 0,
	parameter BWRITES = 0,
	parameter [31:0] SEED = 32'h1
)(
	input wire clk,
	input wire rst,
	input wire quiet
);
	reg [31:0] seed = SEED;
	reg [31:0] r0, r1, r2, r3, r4, r5;
	task step; begin
		seed = seed * 32'd1664525 + 32'd1013904223; r0 = seed ^ (seed >> 13);
		seed = seed * 32'd1664525 + 32'd1013904223; r1 = seed ^ (seed >> 13);
		seed = seed * 32'd1664525 + 32'd1013904223; r2 = seed ^ (seed >> 13);
		seed = seed * 32'd1664525 + 32'd1013904223; r3 = seed ^ (seed >> 13);
		seed = seed * 32'd1664525 + 32'd1013904223; r4 = seed ^ (seed >> 13);
		seed = seed * 32'd1664525 + 32'd1013904223; r5 = seed ^ (seed >> 13);
	end endtask

	integer errors = 0, checks = 0;
	integer a_acks = 0, b_acks = 0, wbacks = 0, invs = 0, collide = 0, reads_out = 0;

	reg  [28:0]  a_addr = 0; reg a_req = 0, a_we = 0, a_lwe = 0, a_around = 0, a_lin = 0;
	reg  [3:0]   a_be = 4'hF; reg [31:0] a_wdata = 0; reg [15:0] a_be16 = 0; reg [127:0] a_wdata128 = 0;
	reg  [28:0]  b_addr = 0; reg b_req = 0, b_we = 0, b_first = 0; reg [3:0] b_be = 4'hF; reg [31:0] b_wdata = 0;
	reg          inv_v = 0; reg [24:0] inv_line = 0; reg flush = 0;
	reg          m_ready = 1;

	wire [31:0]  o_a_rdata, n_a_rdata, o_b_rdata, n_b_rdata;
	wire         o_a_ack, n_a_ack, o_b_ack, n_b_ack;
	wire [127:0] o_a_line, n_a_line, o_b_line, n_b_line;
	wire         o_x_valid, n_x_valid; wire [24:0] o_x_addr, n_x_addr;
	wire [127:0] o_x_line, n_x_line;
	wire [23:0]  o_m_addr, n_m_addr; wire o_m_req, n_m_req, o_m_we, n_m_we;
	wire [127:0] o_m_wdata, n_m_wdata; wire [15:0] o_m_wmask, n_m_wmask;
	reg  [127:0] o_m_rdata = 0, n_m_rdata = 0; reg o_m_valid = 0, n_m_valid = 0;
	wire         o_fb, n_fb; wire [31:0] o_hits, n_hits, o_miss, n_miss;

	ps1_cache_old #(.IDXBITS(IDX), .B_NOALLOC(B_NOALLOC), .A_AROUND(A_AROUND), .FAST_ACK(FAST_ACK)) old (
		.flush(flush), .flush_busy(o_fb), .clk(clk), .rst(rst),
		.a_addr(a_addr), .a_req(a_req), .a_lwe(a_lwe), .a_be16(a_be16), .a_wdata128(a_wdata128),
		.a_we(a_we), .a_around(a_around), .a_lin(a_lin), .a_be(a_be), .a_wdata(a_wdata),
		.a_rdata(o_a_rdata), .a_ack(o_a_ack), .a_line(o_a_line),
		.b_addr(b_addr), .b_first(b_first), .b_req(b_req), .b_we(b_we), .b_be(b_be), .b_wdata(b_wdata),
		.b_rdata(o_b_rdata), .b_ack(o_b_ack), .b_line(o_b_line),
		.x_valid(o_x_valid), .x_addr(o_x_addr), .x_line(o_x_line),
		.inv_v(inv_v), .inv_line(inv_line),
		.m_addr(o_m_addr), .m_req(o_m_req), .m_we(o_m_we), .m_wdata(o_m_wdata), .m_wmask(o_m_wmask),
		.m_ready(m_ready), .m_rdata(o_m_rdata), .m_valid(o_m_valid),
		.dbg_hits(o_hits), .dbg_misses(o_miss));
	ps1_cache #(.IDXBITS(IDX), .B_NOALLOC(B_NOALLOC), .A_AROUND(A_AROUND), .FAST_ACK(FAST_ACK)) nw (
		.flush(flush), .flush_busy(n_fb), .clk(clk), .rst(rst),
		.a_addr(a_addr), .a_req(a_req), .a_lwe(a_lwe), .a_be16(a_be16), .a_wdata128(a_wdata128),
		.a_we(a_we), .a_around(a_around), .a_lin(a_lin), .a_be(a_be), .a_wdata(a_wdata),
		.a_rdata(n_a_rdata), .a_ack(n_a_ack), .a_line(n_a_line),
		.b_addr(b_addr), .b_first(b_first), .b_req(b_req), .b_we(b_we), .b_be(b_be), .b_wdata(b_wdata),
		.b_rdata(n_b_rdata), .b_ack(n_b_ack), .b_line(n_b_line),
		.x_valid(n_x_valid), .x_addr(n_x_addr), .x_line(n_x_line),
		.inv_v(inv_v), .inv_line(inv_line),
		.m_addr(n_m_addr), .m_req(n_m_req), .m_we(n_m_we), .m_wdata(n_m_wdata), .m_wmask(n_m_wmask),
		.m_ready(m_ready), .m_rdata(n_m_rdata), .m_valid(n_m_valid),
		.dbg_hits(n_hits), .dbg_misses(n_miss));

	// --- two identical memories, 64 lines, reads back after a fixed delay -------
	reg [127:0] o_mem [0:63];
	reg [127:0] n_mem [0:63];
	reg [5:0] o_q [0:5]; reg o_qv [0:5];
	reg [5:0] n_q [0:5]; reg n_qv [0:5];
	integer k;
	initial begin
		for (k = 0; k < 64; k = k + 1) begin
			o_mem[k] = {32'hC0FF_EE00 | k, 32'hBEEF_0000 | (k << 4), 32'h1234_0000 ^ k, 32'hA5A5_0000 + k};
			n_mem[k] = o_mem[k];
		end
		for (k = 0; k < 6; k = k + 1) begin o_qv[k] = 0; n_qv[k] = 0; o_q[k] = 0; n_q[k] = 0; end
	end
	always @(posedge clk) begin
		o_m_valid <= o_qv[5]; o_m_rdata <= o_mem[o_q[5]];
		n_m_valid <= n_qv[5]; n_m_rdata <= n_mem[n_q[5]];
		for (k = 5; k > 0; k = k - 1) begin
			o_q[k] <= o_q[k-1]; o_qv[k] <= o_qv[k-1];
			n_q[k] <= n_q[k-1]; n_qv[k] <= n_qv[k-1];
		end
		o_qv[0] <= 1'b0; n_qv[0] <= 1'b0;
		if (o_m_req && m_ready) begin
			if (o_m_we) begin
				for (k = 0; k < 16; k = k + 1) if (o_m_wmask[k]) o_mem[o_m_addr[5:0]][k*8 +: 8] <= o_m_wdata[k*8 +: 8];
			end else begin o_qv[0] <= 1'b1; o_q[0] <= o_m_addr[5:0]; end
		end
		if (n_m_req && m_ready) begin
			if (n_m_we) begin
				for (k = 0; k < 16; k = k + 1) if (n_m_wmask[k]) n_mem[n_m_addr[5:0]][k*8 +: 8] <= n_m_wdata[k*8 +: 8];
			end else begin n_qv[0] <= 1'b1; n_q[0] <= n_m_addr[5:0]; end
		end
	end

	// --- the traffic: held until acknowledged, as the real ports do -------------
	always @(posedge clk) begin
		step;
		m_ready <= r0[0] | r0[1];
		inv_v <= 1'b0; flush <= 1'b0;
		if (rst || quiet) begin a_req <= 1'b0; b_req <= 1'b0; end
		else begin
			if (USE_INV && r0[7:5] == 3'd0) begin inv_v <= 1'b1; inv_line <= {19'd0, r1[5:0]}; end
			if (r0[19:8] == 12'd0 && !o_fb) flush <= 1'b1;
			if (a_req && o_a_ack) a_req <= 1'b0;
			else if (!a_req && r0[20]) begin
				a_req <= 1'b1; a_addr <= {19'd0, r2[9:0]};
				a_we <= r2[10] | r2[11]; a_be <= r2[15:12] | 4'b0001;
				a_wdata <= r3; a_around <= r2[16]; a_lin <= r2[17];
				a_lwe <= (r2[20:18] == 3'd0);
				a_be16 <= r2[21] ? 16'hFFFF : r3[15:0];
				a_wdata128 <= {r3, r4, r5, r1};
			end
			if (b_req && o_b_ack) b_req <= 1'b0;
			else if (!b_req && r0[22]) begin
				b_req <= 1'b1; b_addr <= {19'd0, r4[9:0]};
				b_we <= (BWRITES != 0) && r0[23]; b_be <= r4[13:10] | 4'b0001; b_wdata <= r5;
			end
			b_first <= r0[24];
		end
	end

	// --- what the traffic actually exercised, over the whole run ------------------
	always @(posedge clk) if (!rst && !quiet) begin
		if (o_a_ack) a_acks = a_acks + 1;
		if (o_b_ack) b_acks = b_acks + 1;
		if (o_m_req && m_ready && o_m_we) wbacks = wbacks + 1;
		if (o_m_req && m_ready && !o_m_we) reads_out = reads_out + 1;
		if (nw.vb_we) invs = invs + 1;
		if (nw.vb_we && nw.va_we && nw.inv_idx == nw.idx) collide = collide + 1;
	end

	// --- every output, every clock ------------------------------------------------
	always @(negedge clk) if (!rst && !quiet) begin
		checks = checks + 1;
		if (o_a_ack !== n_a_ack || o_b_ack !== n_b_ack
		 || (o_a_ack && (o_a_rdata !== n_a_rdata || o_a_line !== n_a_line))
		 || (o_b_ack && (o_b_rdata !== n_b_rdata || o_b_line !== n_b_line))
		 || o_x_valid !== n_x_valid || (o_x_valid && (o_x_addr !== n_x_addr || o_x_line !== n_x_line))
		 || o_m_req !== n_m_req || (o_m_req && (o_m_addr !== n_m_addr || o_m_we !== n_m_we))
		 || (o_m_req && o_m_we && (o_m_wdata !== n_m_wdata || o_m_wmask !== n_m_wmask))
		 || o_fb !== n_fb || o_hits !== n_hits || o_miss !== n_miss) begin
			errors = errors + 1;
			if (errors <= 8)
				$display("  FAIL %m t=%0t: ack a %b/%b b %b/%b  m_req %b/%b m_addr %h/%h we %b/%b  hits %0d/%0d miss %0d/%0d",
					$time, o_a_ack, n_a_ack, o_b_ack, n_b_ack, o_m_req, n_m_req, o_m_addr, n_m_addr,
					o_m_we, n_m_we, o_hits, n_hits, o_miss, n_miss);
		end
	end
endmodule

module tb_ps1_cache_equiv;
	localparam IDX = 4, LINES = 1 << IDX;
	localparam CYCLES = 10_000_000;

	reg clk = 0, rst = 1, quiet = 1;
	always #5 clk = ~clk;

	cache_equiv_pair #(.IDX(IDX), .B_NOALLOC(1), .A_AROUND(1), .USE_INV(1), .BWRITES(0), .SEED(32'h1234_5678)) V (.clk(clk), .rst(rst), .quiet(quiet));
	cache_equiv_pair #(.IDX(IDX), .FAST_ACK(1), .USE_INV(0), .BWRITES(1), .SEED(32'h0BAD_F00D)) C (.clk(clk), .rst(rst), .quiet(quiet));
	// the CPU cache with invalidations too, in case one is ever wired there
	cache_equiv_pair #(.IDX(IDX), .FAST_ACK(1), .USE_INV(1), .BWRITES(1), .SEED(32'h5EED_0003)) CI (.clk(clk), .rst(rst), .quiet(quiet));

	// resets now and then, with dirty lines in the caches, and the sweep after each
	integer cyc, next_rst, q_left, resets;
	reg [31:0] s = 32'h7777;
	initial begin
		next_rst = 40_000; q_left = LINES + 4; resets = 0;
		repeat (5) @(posedge clk);
		rst = 0;
		for (cyc = 0; cyc < CYCLES; cyc = cyc + 1) begin
			@(posedge clk);
			if (q_left > 0) begin q_left = q_left - 1; if (q_left == 0) quiet = 0; end
			if (cyc == next_rst) begin
				rst = 1; quiet = 1; resets = resets + 1;
				repeat (3) @(posedge clk);
				rst = 0; q_left = LINES + 4;
				s = s * 32'd1664525 + 32'd1013904223;
				next_rst = cyc + 20_000 + (s[31:8] % 60_000);
			end
		end
		$display("  %0d clocks, %0d resets; comparisons V %0d C %0d CI %0d", CYCLES, resets, V.checks, C.checks, CI.checks);
		$display("  V : %0d port-A answers, %0d port-B, %0d memory writes, %0d reads, %0d invalidations, %0d fill+invalidate of one line on one clock",
			V.a_acks, V.b_acks, V.wbacks, V.reads_out, V.invs, V.collide);
		$display("  C : %0d port-A answers, %0d port-B, %0d memory writes, %0d reads", C.a_acks, C.b_acks, C.wbacks, C.reads_out);
		$display("  CI: %0d port-A answers, %0d port-B, %0d memory writes, %0d reads, %0d invalidations, %0d collisions",
			CI.a_acks, CI.b_acks, CI.wbacks, CI.reads_out, CI.invs, CI.collide);
		if (V.errors + C.errors + CI.errors != 0)
			$display("tb_ps1_cache_equiv: FAIL -- mismatching clocks V %0d C %0d CI %0d", V.errors, C.errors, CI.errors);
		else if (V.a_acks < 100000 || C.a_acks < 100000 || V.wbacks < 10000 || C.wbacks < 10000
		         || V.invs < 1000 || V.collide < 10 || CI.collide < 10)
			$display("tb_ps1_cache_equiv: FAIL -- too little traffic to mean anything");
		else
			$display("tb_ps1_cache_equiv: all checks passed -- the LUT-RAM cache matches the flip-flop one");
		$finish;
	end
endmodule

`default_nettype wire
