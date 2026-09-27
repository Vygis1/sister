//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_cache_around - port B reading around the cache.
//
// Two things have to be true at once, and they pull against each other:
//
//   it must not allocate   the whole point is that the scanout walking the
//                          displayed frame stops throwing out the lines the
//                          drawing engine is using. Proved by filling every
//                          line from port A, sweeping port B across addresses
//                          that share those indices, and requiring that port A
//                          then misses zero times.
//
//   it must not go stale   port B is answered from memory and from a 64-byte
//                          run held ahead of it, neither of which sees a write
//                          sitting dirty in the cache. Proved by pointing port
//                          A's writes and port B's reads at the same addresses
//                          and checking every read against a plain byte array.
//
// The second is the one with teeth: a run can hold a copy of a line that is
// also dirty in the cache, and stays right only because reads of that line hit
// the cache instead, and because the run is dropped when the line is evicted.
//
//   ./tools/sim.sh tb_ps1_cache_around
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_ps1_cache_around;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [28:0] a_addr = 0, b_addr = 0;
	reg         a_req = 0, a_we = 0, b_req = 0;
	reg  [3:0]  a_be = 0;
	reg  [31:0] a_wdata = 0;
	wire [31:0] a_rdata, b_rdata;
	wire        a_ack, b_ack;

	wire [23:0]  m_addr;
	wire         m_req, m_we;
	wire [127:0] m_wdata;
	reg          m_ready = 0;
	reg  [127:0] m_rdata = 0;
	reg          m_valid = 0;
	wire [31:0]  hits, misses;

	reg         a_lwe = 0; reg [15:0] a_be16 = 0; reg [127:0] a_wdata128 = 0;
	reg flush = 0; wire flush_busy;
	ps1_cache #(.IDXBITS(4), .B_NOALLOC(1)) dut ( .a_lin(1'b0),   // 16 lines: conflicts constantly
		.flush(flush), .flush_busy(flush_busy), .inv_v(1'b0), .inv_line(25'd0),
		.clk(clk),
		.b_first(1'b0), .rst(rst),
		.a_addr(a_addr), .a_req(a_req), .a_we(a_we), .a_be(a_be), .a_wdata(a_wdata),
		.a_lwe(a_lwe), .a_be16(a_be16), .a_wdata128(a_wdata128),
		.a_rdata(a_rdata), .a_ack(a_ack),
		.b_addr(b_addr), .b_req(b_req), .b_we(1'b0), .b_be(4'hF), .b_wdata(32'd0),
		.b_rdata(b_rdata), .b_ack(b_ack),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid),
		.dbg_hits(hits), .dbg_misses(misses)
	);

	// --- the memory: lines, answered in order, with latency ------------------------
	reg [127:0] mem [0:4095];
	localparam RD = 9;
	reg [127:0] pipe_d [0:RD-1];
	reg         pipe_v [0:RD-1];
	integer     pi;
	reg         busy = 0;
	integer     m_reads = 0, m_writes = 0;
	// The arbiter in front of the real memory takes one request every few
	// cycles, which is slower than the memory answers. A run of four therefore
	// gets its first line back long before its fourth has gone out. Held low,
	// this model takes requests as fast as they arrive, the overlap never
	// happens, and the bug it hides is fatal: the run collected nothing early,
	// then waited for lines that had already been delivered.
	reg          slow_issue = 0;
	reg [2:0]    gap = 0;
	always @(*) m_ready = m_req && !busy;
	always @(posedge clk) begin
		m_valid <= pipe_v[RD-1];
		m_rdata <= pipe_d[RD-1];
		for (pi = RD - 1; pi > 0; pi = pi - 1) begin
			pipe_v[pi] <= pipe_v[pi-1];
			pipe_d[pi] <= pipe_d[pi-1];
		end
		pipe_v[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) begin mem[m_addr[11:0]] <= m_wdata; m_writes = m_writes + 1; end
			else begin
				pipe_v[0] <= 1'b1;
				pipe_d[0] <= mem[m_addr[11:0]];
				m_reads = m_reads + 1;
			end
		end
		gap  <= gap + 3'd1;
		busy <= slow_issue ? (gap != 3'd0) : ($random % 7 == 0);
	end

	// --- the reference ---------------------------------------------------------------
	reg [7:0] refm [0:65535];

	integer errors = 0;
	task check;
		input cond;
		input [511:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	task acc_a;
		input [28:0] addr; input we; input [3:0] be; input [31:0] wd;
		output [31:0] rd;
		integer k;
		begin
			@(negedge clk);
			a_addr = addr; a_we = we; a_be = be; a_wdata = wd; a_req = 1;
			@(posedge clk);
			while (!a_ack) @(posedge clk);
			#1 rd = a_rdata; a_req = 0;
			if (we) for (k = 0; k < 4; k = k + 1)
				if (be[k]) refm[{addr[15:2], 2'b00} + k] = wd[k*8 +: 8];
		end
	endtask

	task read_b;
		input [28:0] addr;
		output [31:0] rd;
		begin
			@(negedge clk);
			b_addr = addr; b_req = 1;
			@(posedge clk);
			while (!b_ack) @(posedge clk);
			#1 rd = b_rdata; b_req = 0;
			@(negedge clk);
		end
	endtask

	function [31:0] refword;
		input [28:0] addr;
		refword = {refm[{addr[15:2], 2'b00} + 3], refm[{addr[15:2], 2'b00} + 2],
		           refm[{addr[15:2], 2'b00} + 1], refm[{addr[15:2], 2'b00}]};
	endfunction

	reg [31:0] got, got_b;
	integer k, addr, we, be, wd, bad, bad_b;
	integer m0, m1, r0;
	initial begin
		for (k = 0; k < 4096; k = k + 1) mem[k] = {4{32'hA5A50000 | k}};
		for (k = 0; k < 65536; k = k + 1) refm[k] = mem[k >> 4][(k & 15) * 8 +: 8];
		for (k = 0; k < RD; k = k + 1) begin pipe_v[k] = 0; pipe_d[k] = 0; end
		repeat (4) @(posedge clk);
		rst = 0;
		bad = 0; bad_b = 0;

		// --- 1. port B does not evict anything -------------------------------------
		$display("--- port B must not throw port A's lines out ---");
		for (k = 0; k < 16; k = k + 1) acc_a(k * 16, 0, 4'hF, 0, got);   // every index
		// count port A's HITS, not the shared miss counter: port B's own misses
		// land in that one too, so it cannot tell the two ports apart.
		for (k = 0; k < 200; k = k + 1)                                  // same indices,
			read_b(29'h8000 + k * 16, got_b);                            // different tags
		m0 = hits;
		for (k = 0; k < 16; k = k + 1) acc_a(k * 16, 0, 4'hF, 0, got);
		m1 = hits;
		$display("  of port A's 16 lines, %0d survived 200 port B reads over their indices", m1 - m0);
		check(m1 - m0 == 16, "port A keeps every line while port B sweeps past it");

		// --- 2. a run is fetched once and reused ------------------------------------
		// Port B's run is a STRIP: four lines straight along the row. It used to
		// be the tile that port A wants for textures -- two lines here and two on
		// the row below -- and for port B that is simply wrong. Port B is the
		// scanout, and the scanout walks one row from end to end eight pixels at
		// a time; the row below is 128 lines away and it will not be there for
		// another sixty-four reads. Half of every run it paid for was thrown
		// away, so it went back to memory twice as often as it needed to.
		// Measured in tb_ps1_scan: 2.0 lines a run against 4.0, and 7,680 round
		// trips for a capture against 3,840.
		$display("--- port B's run is a strip along the row, and costs one trip ---");
		read_b(29'h9000, got_b);          // starts a run at line 0x900
		r0 = m_reads;
		read_b(29'h9004, got_b);          // rest of the line asked for
		read_b(29'h9010, got_b);          // the next line along
		read_b(29'h9020, got_b);          // and the next
		read_b(29'h9030, got_b);          // and the last of the four
		$display("  4 further reads inside the strip cost %0d memory reads", m_reads - r0);
		check(m_reads == r0, "the rest of the strip is answered without going out");

		// --- 3. port B never sees a word port A has moved on from -------------------
		// Port A writes all over the range port B is walking, which is exactly the
		// case the run buffer can get wrong: it holds lines that may also be sitting
		// dirty in the cache, or be evicted out from under it.
		$display("--- 20000 interleaved: port A writes where port B reads ---");
		for (k = 0; k < 20000; k = k + 1) begin
			addr = ($random & 32'h0000_3FFC);
			we   = $random & 1;
			be   = we ? ($random & 15) : 4'hF;
			if (be == 0) be = 4'hF;
			wd   = $random;
			acc_a(addr, we, be, wd, got);
			if (!we && got !== refword(addr)) begin
				bad = bad + 1;
				if (bad < 5) $display("  A MISMATCH #%0d addr %05h: got %08h ref %08h",
				                      bad, addr, got, refword(addr));
			end
			// port B walks the same region the way a scanout walks a frame
			read_b((k * 4) & 32'h3FFC, got_b);
			if (got_b !== refword((k * 4) & 32'h3FFC)) begin
				bad_b = bad_b + 1;
				if (bad_b < 5) $display("  B STALE #%0d addr %05h: got %08h ref %08h",
				                        bad_b, (k*4) & 32'h3FFC, got_b, refword((k*4) & 32'h3FFC));
			end
			if (($random & 15) == 0) repeat ($random & 31) @(posedge clk);
		end
		// --- 4. the same, with the memory answering mid-run -------------------------
		$display("--- 3000 more with requests taken slower than lines come back ---");
		slow_issue = 1;
		for (k = 0; k < 3000; k = k + 1) begin
			addr = ($random & 32'h0000_3FFC);
			we   = $random & 1;
			be   = we ? ($random & 15) : 4'hF;
			if (be == 0) be = 4'hF;
			wd   = $random;
			acc_a(addr, we, be, wd, got);
			if (!we && got !== refword(addr)) bad = bad + 1;
			read_b((k * 4) & 32'h3FFC, got_b);
			if (got_b !== refword((k * 4) & 32'h3FFC)) bad_b = bad_b + 1;
		end
		slow_issue = 0;

		$display("port A: %0d mismatches; port B: %0d stale reads", bad, bad_b);
		check(bad == 0, "port A still sees its own writes");
		check(bad_b == 0, "port B never reads around a write it should have seen");

		if (errors == 0) $display("tb_ps1_cache_around: all checks passed");
		else             $display("tb_ps1_cache_around: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		#400_000_000;
		$display("tb_ps1_cache_around: FAIL - TIMEOUT, the design stopped making progress");
		$finish;
	end
endmodule
