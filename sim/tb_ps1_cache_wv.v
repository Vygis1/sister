//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_cache_wv - the processor's cache as built (BRAM, FAST_ACK, B_NOALLOC, B_LINE, WVALID:
// a whole-word store that misses claims the line without reading it) against a memory that
// honours the byte mask and a byte array that applies the same operations.
//
// What WVALID can get wrong, and so what this looks at: a read of a line only partly held
// (fetched and merged under the held words), the WHOLE line a read hands back (the L1s and the
// DMA take all of it), a write-back of a partly held line (only its words may land: the mask),
// a partial store into a word not held, the DMA's reads and line writes beside it, a flush.
//   ./tools/sim.sh tb_ps1_cache_wv
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps
`ifdef TB_CACHE_SB
module tb_ps1_cache_sb;                  // the same, with the stream buffer (SBUF)
	localparam SB = 1;
`else
module tb_ps1_cache_wv;
	localparam SB = 0;
`endif
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [28:0] a_addr = 0, b_addr = 0;
	reg         a_req = 0, a_we = 0, b_req = 0, b_we = 0;
	reg  [3:0]  a_be = 0, b_be = 0;
	reg  [31:0] a_wdata = 0, b_wdata = 0;
	wire [31:0] a_rdata, b_rdata;
	wire [127:0] a_line, b_line;
	wire        a_ack, b_ack;
	reg         b_lwe = 0; reg [15:0] b_be16 = 0; reg [127:0] b_wdata128 = 0;

	wire [23:0]  m_addr;
	wire         m_req, m_we;
	wire [127:0] m_wdata;
	wire [15:0]  m_wmask;
	reg          m_ready = 0;
	reg  [127:0] m_rdata = 0;
	reg          m_valid = 0;
	wire [31:0]  hits, misses;
	reg flush = 0; wire flush_busy;

	ps1_cache #(.IDXBITS(4), .FAST_ACK(1), .BRAM(1), .B_LINE(1), .B_NOALLOC(1), .WVALID(1), .SBUF(SB)) dut (
		.a_lin(1'b0), .a_around(1'b0),
		.flush(flush), .flush_busy(flush_busy), .inv_v(1'b0), .inv_line(25'd0),
		.clk(clk), .b_first(1'b0), .rst(rst),
		.a_addr(a_addr), .a_req(a_req), .a_we(a_we), .a_be(a_be), .a_wdata(a_wdata),
		.a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0),
		.a_rdata(a_rdata), .a_ack(a_ack), .a_line(a_line),
		.b_addr(b_addr), .b_req(b_req), .b_we(b_we), .b_be(b_be), .b_wdata(b_wdata),
		.b_lwe(b_lwe), .b_be16(b_be16), .b_wdata128(b_wdata128),
		.b_rdata(b_rdata), .b_ack(b_ack), .b_line(b_line),
		.x_valid(), .x_addr(), .x_line(),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid),
		.dbg_hits(hits), .dbg_misses(misses)
	);

	// --- the memory: lines, a byte mask on writes, latency and refusals ------------------
	reg [127:0] mem [0:4095];
	localparam RD = 9;
	reg [127:0] pipe_d [0:RD-1];
	reg         pipe_v [0:RD-1];
	integer     pi, mk;
	reg         busy = 0;
	always @(*) m_ready = m_req && !busy;
	always @(posedge clk) begin
		m_valid <= pipe_v[RD-1];
		m_rdata <= pipe_d[RD-1];
		for (pi = RD - 1; pi > 0; pi = pi - 1) begin pipe_v[pi] <= pipe_v[pi-1]; pipe_d[pi] <= pipe_d[pi-1]; end
		pipe_v[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) begin
				for (mk = 0; mk < 16; mk = mk + 1)
					if (m_wmask[mk]) mem[m_addr[11:0]][mk*8 +: 8] <= m_wdata[mk*8 +: 8];
			end else begin
				pipe_v[0] <= 1'b1; pipe_d[0] <= mem[m_addr[11:0]];
			end
		end
		busy <= ($random % 7 == 0);
	end

	reg [7:0] ref [0:65535];
	// every write-back, as it is taken, against the reference: the words it carries must be the
	// newest written (the cache holds the only copy of a dirty word)
	integer wb_bad = 0, wbk;
	always @(posedge clk) if (m_req && m_ready && m_we) begin
		for (wbk = 0; wbk < 16; wbk = wbk + 1)
			if (m_wmask[wbk] && m_wdata[wbk*8 +: 8] !== ref[{m_addr[11:0], 4'h0} + wbk]) begin
				wb_bad = wb_bad + 1;
				if (wb_bad < 4) $display("  WRITE-BACK of line %03h at %0t: byte %0d is %02h, newest %02h (mask %04h)", m_addr[11:0], $time, wbk, m_wdata[wbk*8 +: 8], ref[{m_addr[11:0], 4'h0} + wbk], m_wmask);
			end
	end
	function [31:0] refword; input [28:0] a;
		refword = {ref[{a[15:2], 2'b00} + 3], ref[{a[15:2], 2'b00} + 2], ref[{a[15:2], 2'b00} + 1], ref[{a[15:2], 2'b00}]};
	endfunction
	function [127:0] refline; input [28:0] a;
		refline = {refword({a[28:4], 4'hC}), refword({a[28:4], 4'h8}), refword({a[28:4], 4'h4}), refword({a[28:4], 4'h0})};
	endfunction

	integer errors = 0;
	integer sbf = 0;
	always @(posedge clk) if (dut.st == 5'd18) sbf = sbf + 1;      // (S_SBFILL)
	task check; input cond; input [511:0] what;
		begin if (cond) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end end
	endtask

	integer a_bad = 0, a_lbad = 0, b_bad = 0, k;
	task acc_a; input [28:0] addr; input we; input [3:0] be; input [31:0] wd; input chkline;
		reg [31:0] rd; reg [127:0] ln;
		begin
			@(negedge clk);
			a_addr = addr; a_we = we; a_be = be; a_wdata = wd; a_req = 1;
			@(posedge clk);
			while (!a_ack) @(posedge clk);
			#1 rd = a_rdata; ln = a_line; a_req = 0;
			if (we) begin
				for (k = 0; k < 4; k = k + 1) if (be[k]) ref[{addr[15:2], 2'b00} + k] = wd[k*8 +: 8];
			end else begin
				if (rd !== refword(addr)) begin
					a_bad = a_bad + 1;
					if (a_bad < 6) $display("  A word MISMATCH %05h got %08h ref %08h", addr, rd, refword(addr));
				end
				if (chkline && ln !== refline(addr)) begin
					a_lbad = a_lbad + 1;
					if (a_lbad < 6) $display("  A LINE MISMATCH %05h\n     got %032h\n     ref %032h", addr, ln, refline(addr));
				end
			end
		end
	endtask
	task acc_b; input [28:0] addr; input we; input [31:0] wd;
		reg [31:0] rd;
		begin
			@(negedge clk);
			b_addr = addr; b_we = we; b_be = 4'hF; b_wdata = wd; b_lwe = 0; b_req = 1;
			@(posedge clk);
			while (!b_ack) @(posedge clk);
			#1 rd = b_rdata; b_req = 0;
			if (we) for (k = 0; k < 4; k = k + 1) ref[{addr[15:2], 2'b00} + k] = wd[k*8 +: 8];
			else if (rd !== refword(addr)) begin
				b_bad = b_bad + 1;
				if (b_bad < 6) $display("  B MISMATCH %05h got %08h ref %08h", addr, rd, refword(addr));
			end
		end
	endtask
	task acc_bline; input [28:0] addr; input [127:0] wd;
		begin
			@(negedge clk);
			b_addr = {addr[28:4], 4'h0}; b_we = 1; b_be = 4'hF; b_lwe = 1; b_be16 = 16'hFFFF; b_wdata128 = wd; b_req = 1;
			@(posedge clk);
			while (!b_ack) @(posedge clk);
			#1 b_req = 0; b_lwe = 0;
			for (k = 0; k < 16; k = k + 1) ref[{addr[15:4], 4'h0} + k] = wd[k*8 +: 8];
		end
	endtask

	// port B, concurrent: its own words (addr[2] = 1) of the same lines port A uses
	reg b_run = 0; integer b_n = 0;
	reg [28:0] ba;
	initial begin
		wait (!rst);
		forever begin
			if (b_run) begin
				ba = ($random & 32'h0000_3FF8) | 29'h4;
				acc_b(ba, ($random & 3) == 0, $random);
				b_n = b_n + 1;
			end else @(negedge clk);
		end
	end

	integer n, addr, we, be, wd, mbad;
	reg [127:0] lw;
	initial begin
		for (n = 0; n < 4096; n = n + 1) mem[n] = {32'h0B0B0000 | n, 32'h0A0A0000 | n, 32'h09090000 | n, 32'h08080000 | n};
		for (n = 0; n < 65536; n = n + 1) ref[n] = mem[n >> 4][(n & 15) * 8 +: 8];
		for (n = 0; n < RD; n = n + 1) begin pipe_v[n] = 0; pipe_d[n] = 0; end
		repeat (4) @(posedge clk); rst = 0;
		repeat (40) @(posedge clk);                     // the valid sweep (16 lines)

		$display("--- directed: a store claims a line; a read of another word fetches and merges ---");
		acc_a(29'h0000_0204, 1, 4'hF, 32'h11112222, 0);
		acc_a(29'h0000_0200, 0, 4'hF, 0, 1);            // word 0 not held: fetch, merge under word 1
		acc_a(29'h0000_0204, 0, 4'hF, 0, 1);
		acc_a(29'h0000_0308, 1, 4'hF, 32'h33334444, 0); // claims a line at another index...
		acc_a(29'h0000_1308, 1, 4'hF, 32'h55556666, 0); // ...and this one evicts it: a masked write-back
		acc_a(29'h0000_0300, 0, 4'hF, 0, 1);            // memory must hold the old words 0,1,3 and the new 2
		acc_a(29'h0000_1300, 0, 4'hF, 0, 1);
		acc_a(29'h0000_040C, 1, 4'hF, 32'hAAAA_BBBB, 0);
		acc_a(29'h0000_0408, 1, 4'h3, 32'h0000_CCCC, 0); // a partial store to a word not held: fetch first
		acc_a(29'h0000_0408, 0, 4'hF, 0, 1);
		check(a_bad == 0 && a_lbad == 0, "claims, merges, a masked write-back and a partial store");

		$display("--- random: port A alone, 30000 accesses, whole lines checked ---");
		for (n = 0; n < 30000; n = n + 1) begin
			addr = ($random & 32'h0000_3FFC);
			we = (($random & 3) != 0);
			be = we ? ((($random & 3) == 0) ? ($random & 15) : 4'hF) : 4'hF;
			if (be == 0) be = 4'hF;
			acc_a(addr, we, be, $random, 1);
		end
		check(a_bad == 0 && a_lbad == 0, "port A: every word and every whole line as written");

		$display("--- random: port A and port B together on the same lines, 30000 ---");
		a_bad = 0; a_lbad = 0;
		b_run = 1;
		for (n = 0; n < 30000; n = n + 1) begin
			addr = ($random & 32'h0000_3FF8);           // port A: words 0 and 2 of each line
			we = (($random & 3) != 0);
			be = we ? ((($random & 3) == 0) ? ($random & 15) : 4'hF) : 4'hF;
			if (be == 0) be = 4'hF;
			acc_a(addr, we, be, $random, 0);
			if (($random & 15) == 0) repeat ($random & 31) @(posedge clk);
		end
		b_run = 0; repeat (100) @(posedge clk);
		$display("   port B: %0d accesses", b_n);
		check(a_bad == 0 && b_bad == 0, "both ports see their words, with the other writing beside them");

		$display("--- streams: runs of lines read in order, written, evicted dirty, read again ---");
		a_bad = 0; a_lbad = 0;
		b_run = 1;
		for (n = 0; n < 400; n = n + 1) begin : streams
			integer base, len, j, mode;
			base = ($random & 32'h0000_3FF0); len = 2 + ($random & 15); mode = $random & 3;
			for (j = 0; j < len; j = j + 1) begin
				addr = (base + j * 16 + (($random & 3) * 4)) & 32'h0000_3FF8;   // (port A: words 0 and 2)
				if (mode == 0 && (j & 1)) acc_a(addr, 1, 4'hF, $random, 0);          // writes inside a stream
				else acc_a(addr, 0, 4'hF, 0, 0);
				if (mode == 1 && j == 2) acc_a((addr + 32'h1000) & 32'h0000_3FF8, 1, 4'hF, $random, 0);   // the same index, dirty
			end
		end
		b_run = 0; repeat (100) @(posedge clk);
		check(a_bad == 0 && b_bad == 0, "streams read in order, with writes and dirty evictions among them");

		$display("--- the stream buffer's hazard: a line dirty in the cache when the stream reads it ---");
		a_bad = 0; a_lbad = 0;
		for (n = 0; n < 600; n = n + 1) begin : hazard
			integer L;
			L = ($random & 32'h0000_3FF0);
			acc_a(L + 16, 1, 4'hF, $random, 0);                         // line L+1 dirty in the cache
			acc_a(L + 16 + 4, 1, 4'hF, $random, 0);
			acc_a(L, 0, 4'hF, 0, 1);                                     // a miss on L: the stream reads L+1.. from memory
			repeat ($random & 63) @(posedge clk);                         // (time for the slots' reads)
			acc_a((L + 16 + 256) & 32'h0000_3FFC, 0, 4'hF, 0, 1);        // L+1's index, another line: L+1 written back
			acc_a(L + 16, 0, 4'hF, 0, 1);                                // L+1 again: not the slot's old copy
			acc_a(L + 32, 0, 4'hF, 0, 1);                                // and on along the stream
		end
		check(a_bad == 0 && a_lbad == 0, "a line written back is never served from the stream buffer's older copy");

		$display("--- streams with time between them: the buffer in use ---");
		for (n = 0; n < 300; n = n + 1) begin : walk
			integer base, len, j;
			base = ($random & 32'h0000_3FF0); len = 3 + ($random & 15);
			for (j = 0; j < len; j = j + 1) begin
				acc_a((base + j * 16 + ($random & 12)) & 32'h0000_3FFC, (($random & 7) == 0), 4'hF, $random, 1);
				repeat ($random & 15) @(posedge clk);
			end
		end
		check(a_bad == 0 && a_lbad == 0, "walks along lines, the stream buffer serving most of them");

		$display("--- the DMA's whole-line writes among claimed lines ---");
		for (n = 0; n < 3000; n = n + 1) begin
			addr = ($random & 32'h0000_3FFC);
			case ($random & 3)
			0: begin lw = {$random, $random, $random, $random}; acc_bline(addr, lw); end
			1: acc_a(addr, 1, 4'hF, $random, 0);
			default: acc_a(addr, 0, 4'hF, 0, 1);
			endcase
		end
		check(a_bad == 0 && a_lbad == 0, "line writes and claims agree");

		$display("--- flush, then memory itself against the reference ---");
		@(negedge clk); flush = 1; @(negedge clk); flush = 0;
		repeat (5) @(posedge clk);
		while (flush_busy) @(posedge clk);
		repeat (30) @(posedge clk);
		mbad = 0;
		for (n = 0; n < 1024; n = n + 1)
			if (mem[n] !== refline(n << 4)) begin
				mbad = mbad + 1;
				if (mbad < 6) begin
					$display("  MEM line %03h\n     got %032h\n     ref %032h", n, mem[n], refline(n << 4));
					$display("     cache index %0d: tag+wv %h valid %b dirty %b data %032h", n & 15, dut.g_bram.btag[n & 15], dut.va[n & 15] ^ dut.vb[n & 15], dut.dirty[n & 15], dut.g_bram.bdata[n & 15]);
				end
			end
		check(mbad == 0, "after a flush memory holds exactly what was written (masked write-backs)");
		check(wb_bad == 0, "every write-back carried the newest words");
		$display("   hits %0d misses %0d, lines taken from the stream buffer %0d", hits, misses, sbf);
		if (errors == 0) $display("tb_ps1_cache_%0s: all checks passed", SB ? "sb" : "wv");
		else             $display("tb_ps1_cache_%0s: %0d FAIL(s)", SB ? "sb" : "wv", errors);
		$finish;
	end
	initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
`default_nettype wire
