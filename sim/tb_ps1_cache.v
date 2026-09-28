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
module tb_ps1_cache_bram;
`else
module tb_ps1_cache;
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

	reg [31:0] got;
	integer k, addr, port, we, be, wd, bad;
	initial begin
		for (k = 0; k < 4096; k = k + 1) mem[k] = {4{32'hA5A50000 | k}};
		for (k = 0; k < 65536; k = k + 1) ref[k] = mem[k >> 4][(k & 15) * 8 +: 8];
		for (k = 0; k < RD; k = k + 1) begin pipe_v[k] = 0; pipe_d[k] = 0; end
		repeat (4) @(posedge clk);
		rst = 0;

		$display("--- directed ---");
		acc_a(29'h0000_0100, 0, 4'hF, 0, got);
		check(got === refword(29'h100), "read miss fills and answers the right word");
		check(misses == 1 && hits == 0, "and it counted as a miss");
		acc_a(29'h0000_0104, 0, 4'hF, 0, got);
		check(got === refword(29'h104) && hits == 1, "the next word in the line is a hit");
		acc_a(29'h0000_0108, 1, 4'hF, 32'hDEADBEEF, got);
		acc_a(29'h0000_0108, 0, 4'hF, 0, got);
		check(got === 32'hDEADBEEF, "a store is visible to the next read");
		acc_a(29'h0000_0109, 1, 4'b0010, 32'h0000CC00, got);
		acc_a(29'h0000_0108, 0, 4'hF, 0, got);
		check(got === 32'hDEADCCEF, "a byte store touches only its byte");
		check(mem[29'h100 >> 4] !== dut.data[0], "and DDR3 has not been written yet (write-back)");
		// same index, different tag: evicts, which must write the dirty line back
		acc_a(29'h0000_0100 + 16 * 16, 0, 4'hF, 0, got);
		check(got === refword(29'h100 + 256), "a conflicting line evicts and answers");
		check(mem[29'h100 >> 4][95:64] === 32'hDEADCCEF, "the evicted dirty line reached DDR3");
		acc_b(29'h0000_0200, 0, 4'hF, 0, got);
		check(got === refword(29'h200), "port B reads through the same cache");
		acc_b(29'h0000_0200, 1, 4'hF, 32'h12345678, got);
		acc_a(29'h0000_0200, 0, 4'hF, 0, got);
		check(got === 32'h12345678, "port A sees port B's store: one view");

		// a flush writes every dirty line back: the memory then holds the store
		acc_a(29'h0000_0300, 1, 4'hF, 32'hF1A5_F1A5, got);
		check(mem[29'h300 >> 4][31:0] !== 32'hF1A5_F1A5, "before the flush DDR3 still has the old word");
		@(negedge clk); flush = 1; @(negedge clk); flush = 0;
		@(posedge clk); while (flush_busy) @(posedge clk);
		repeat (RD + 4) @(posedge clk);
		check(mem[29'h300 >> 4][31:0] === 32'hF1A5_F1A5, "after the flush DDR3 has the store");
		acc_a(29'h0000_0300, 0, 4'hF, 0, got);
		check(got === 32'hF1A5_F1A5, "and the cache still answers it");
		$display("--- random: 10000 accesses, both ports, 16-line cache ---");
		bad = 0;
		for (n = 0; n < 10000; n = n + 1) begin
			addr = ($random & 32'h0000_3FFC);            // 16 kB, word aligned
			port = $random & 1;
			we   = $random & 1;
			be   = we ? ($random & 15) : 4'hF;
			if (we && be == 0) be = 4'hF;
			wd   = $random;
			if (port) acc_b(addr, we, be, wd, got); else acc_a(addr, we, be, wd, got);
			if (!we && got !== refword(addr)) begin
				if (bad < 5) $display("  MISMATCH #%0d port %0d addr %05h: got %08h ref %08h",
				                      n, port, addr, got, refword(addr));
				bad = bad + 1;
			end
		end
		check(bad == 0, "every random read matched the reference");
		$display("  hits %0d, misses %0d", hits, misses);

		$display("");
		// --- line writes: a full line with no fetch, and a masked partial one --------
		begin : linetest
			reg [31:0] r0, r1;
			// a full line to an address nobody has touched: must not read DDR3 for it
			@(posedge clk); a_addr <= 29'h0001_2340; a_we <= 1; a_lwe <= 1; a_be16 <= 16'hFFFF;
			a_wdata128 <= 128'h4444_4444_3333_3333_2222_2222_1111_1111; a_req <= 1;
			@(posedge clk); while (!a_ack) @(posedge clk); a_req <= 0; a_we <= 0; a_lwe <= 0; @(posedge clk);
			@(posedge clk); a_addr <= 29'h0001_2348; a_req <= 1;
			@(posedge clk); while (!a_ack) @(posedge clk); r0 = a_rdata; a_req <= 0; @(posedge clk);
			check(r0 == 32'h3333_3333, "a full line write is readable word by word");
			// a masked line write onto it: only the enabled bytes change
			@(posedge clk); a_addr <= 29'h0001_2340; a_we <= 1; a_lwe <= 1; a_be16 <= 16'h0F00;
			a_wdata128 <= 128'hAAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA_AAAA; a_req <= 1;
			@(posedge clk); while (!a_ack) @(posedge clk); a_req <= 0; a_we <= 0; a_lwe <= 0; @(posedge clk);
			@(posedge clk); a_addr <= 29'h0001_2348; a_req <= 1;
			@(posedge clk); while (!a_ack) @(posedge clk); r1 = a_rdata; a_req <= 0; @(posedge clk);
			check(r1 == 32'hAAAA_AAAA, "a masked line write changes only its bytes (word 2)");
			@(posedge clk); a_addr <= 29'h0001_234C; a_req <= 1;
			@(posedge clk); while (!a_ack) @(posedge clk); r1 = a_rdata; a_req <= 0; @(posedge clk);
			check(r1 == 32'h4444_4444, "and leaves the others (word 3)");
		end
		if (errors == 0) $display("tb_ps1_cache: all checks passed");
		else             $display("tb_ps1_cache: %0d FAIL(s)", errors);
		$finish;
	end
endmodule

`default_nettype wire
