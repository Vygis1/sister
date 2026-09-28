//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_cache - the cache against a memory that keeps its own copy.
//
// Directed cases first -- a miss and fill, a hit, a store that dirties a line,
// an eviction that writes it back, port B while A is idle -- and then the test
// that matters: ten thousand random word accesses on both ports, every one
// compared against a plain byte array that applies the same operations. A
// cache can pass every directed case and still return the wrong line under a
// conflict pattern nobody thought to write down; the random run is where that
// shows.
//
//   ./tools/sim.sh tb_ps1_cache
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

`ifdef TB_CACHE_BRAM
// the processor's cache as built: lines in block RAM, answers in the same clock
module tb_ps1_cache_conc_bram;
`else
module tb_ps1_cache_conc;
`endif
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [28:0] a_addr = 0, b_addr = 0;
	reg         a_req = 0, a_we = 0, b_req = 0, b_we = 0;
	reg  [3:0]  a_be = 0, b_be = 0;
	reg  [31:0] a_wdata = 0, b_wdata = 0;
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
	ps1_cache #(.IDXBITS(4)
`ifdef TB_CACHE_BRAM
		, .BRAM(1), .FAST_ACK(1)
`endif
	) dut ( .a_lin(1'b0),        // 16 lines: conflicts happen constantly
		.flush(flush), .flush_busy(flush_busy), .inv_v(1'b0), .inv_line(25'd0),
		.clk(clk),
		.b_first(1'b0), .rst(rst),
		.a_addr(a_addr), .a_req(a_req), .a_we(a_we), .a_be(a_be), .a_wdata(a_wdata),
		.a_lwe(a_lwe), .a_be16(a_be16), .a_wdata128(a_wdata128),
		.a_rdata(a_rdata), .a_ack(a_ack),
		.b_addr(b_addr), .b_req(b_req), .b_we(b_we), .b_be(b_be), .b_wdata(b_wdata),
		.b_rdata(b_rdata), .b_ack(b_ack),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid),
		.dbg_hits(hits), .dbg_misses(misses)
	);

	// --- the memory: lines, with the arbiter's handshake and some latency -------------
	// ready is combinational on req; a read's line comes back RD cycles later.
	reg [127:0] mem [0:4095];           // 64 kB, addressed in lines
	localparam RD = 9;
	reg [127:0] pipe_d [0:RD-1];
	reg         pipe_v [0:RD-1];
	integer     pi;
	reg         busy = 0;
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
			if (m_we) mem[m_addr[11:0]] <= m_wdata;
			else begin
				pipe_v[0] <= 1'b1;
				pipe_d[0] <= mem[m_addr[11:0]];
			end
		end
		// occasionally refuse for a few cycles, as a real controller does
		busy <= ($random % 7 == 0);
	end

	// --- the reference: bytes ------------------------------------------------------------
	reg [7:0] ref [0:65535];

	integer errors = 0, n = 0;
	task check;
		input cond;
		input [511:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// One access on port A, blocking.
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
				if (be[k]) ref[{addr[15:2], 2'b00} + k] = wd[k*8 +: 8];
		end
	endtask

	task acc_b;
		input [28:0] addr; input we; input [3:0] be; input [31:0] wd;
		output [31:0] rd;
		integer k;
		begin
			@(negedge clk);
			b_addr = addr; b_we = we; b_be = be; b_wdata = wd; b_req = 1;
			@(posedge clk);
			while (!b_ack) @(posedge clk);
			#1 rd = b_rdata; b_req = 0;
			if (we) for (k = 0; k < 4; k = k + 1)
				if (be[k]) ref[{addr[15:2], 2'b00} + k] = wd[k*8 +: 8];
		end
	endtask

	function [31:0] refword;
		input [28:0] addr;
		refword = {ref[{addr[15:2], 2'b00} + 3], ref[{addr[15:2], 2'b00} + 2],
		           ref[{addr[15:2], 2'b00} + 1], ref[{addr[15:2], 2'b00}]};
	endfunction


	// --- port B: a DMA-like walker, always reading, always a request pending ------------
	// It reads 0x8000..0xBFFF (disjoint words from port A's 0x0000..0x3FFF) so the
	// two never touch the same word, but with 16 lines they share every index.
	reg [31:0] b_got; integer b_n = 0, b_bad = 0;
	reg [28:0] b_cur = 29'h8000;
	initial begin
		wait (!rst);
		forever begin
			@(negedge clk);
			b_addr = b_cur; b_we = 0; b_be = 4'hF; b_req = 1;
			@(posedge clk);
			while (!b_ack) @(posedge clk);
			#1 b_got = b_rdata; b_req = 0;
			if (b_got !== refword(b_cur)) begin
				b_bad = b_bad + 1;
				if (b_bad < 5) $display("  B MISMATCH addr %05h got %08h ref %08h", b_cur, b_got, refword(b_cur));
			end
			b_n = b_n + 1;
			b_cur = 29'h8000 + (($random & 32'h3FFC));
		end
	end

	reg [31:0] got;
	integer k, addr, we, be, wd, bad;
	initial begin
		for (k = 0; k < 4096; k = k + 1) mem[k] = {4{32'hA5A50000 | k}};
		for (k = 0; k < 65536; k = k + 1) ref[k] = mem[k >> 4][(k & 15) * 8 +: 8];
		for (k = 0; k < RD; k = k + 1) begin pipe_v[k] = 0; pipe_d[k] = 0; end
		repeat (4) @(posedge clk);
		rst = 0;
		bad = 0;
		$display("--- directed: dirty line evicted by port B, then re-read ---");
		acc_a(29'h0000_0100, 1, 4'hF, 32'hCAFE0001, got);
		acc_a(29'h0000_0104, 1, 4'hF, 32'hCAFE0002, got);
		repeat (300) @(posedge clk);                 // port B walks and evicts meanwhile
		acc_a(29'h0000_0100, 0, 4'hF, 0, got);
		check(got === 32'hCAFE0001, "word 0 survives an eviction by port B");
		acc_a(29'h0000_0104, 0, 4'hF, 0, got);
		check(got === 32'hCAFE0002, "word 1 survives an eviction by port B");
		$display("--- random: 20000 port A accesses under a continuous port B stream ---");
		for (k = 0; k < 20000; k = k + 1) begin
			addr = ($random & 32'h0000_3FFC);
			we   = $random & 1;
			be   = we ? ($random & 15) : 4'hF;
			if (be == 0) be = 4'hF;
			wd   = $random;
			acc_a(addr, we, be, wd, got);
			if (!we && got !== refword(addr)) begin
				bad = bad + 1;
				if (bad < 5) $display("  A MISMATCH #%0d addr %05h: got %08h ref %08h", bad, addr, got, refword(addr));
			end
			if (($random & 7) == 0) repeat ($random & 63) @(posedge clk);
		end
		$display("port A: %0d mismatches; port B: %0d reads, %0d mismatches", bad, b_n, b_bad);
		check(bad == 0 && b_bad == 0, "no port sees a stale or wrong word");
		if (errors == 0) $display("tb_ps1_cache_conc: all checks passed");
		else             $display("tb_ps1_cache_conc: %0d FAIL(s)", errors);
		$finish;
	end
endmodule
