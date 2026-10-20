// tb_pc_ddr64_fill - pc_ddr64's host port (the ESP32 filling the BIOS) against a slow memory: 64 kB of
// words, one every GAP clocks (the quad link's pace at 40 MHz is ~32), the memory taking 20-83 clocks
// a write; every byte must land where it was sent (the z486 PC's BIOS came out shifted, 2026-10-19).
`timescale 1ns/1ps
module tb_pc_ddr64_fill;
	reg clk = 0, rst = 1;
	always #12.5 clk = ~clk;
	reg h_we = 0; reg [31:0] h_addr = 0, h_wdata = 0;
	wire [23:0] m_addr; wire m_req, m_we; wire [127:0] m_wdata; wire [15:0] m_wmask;
	reg m_ready = 0; wire h_lost;
	pc_ddr64 dut (.clk(clk), .rst(rst),
		.a_addr(25'd0), .a_din(64'd0), .a_be(8'd0), .a_burst(8'd0), .a_rd(1'b0), .a_we(1'b0), .a_busy(), .a_dout(), .a_dout_ready(),
		.h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata), .h_lost(h_lost),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(128'd0), .m_valid(1'b0));
	// the memory: 16-byte lines from 0xF000, a write taken after a random wait
	reg [7:0] mem [0:65535];
	integer wait_n = 0, i, b, bad = 0, writes = 0;
	always @(posedge clk) begin
		m_ready <= 1'b0;
		if (m_req && m_we && !m_ready) begin
			if (wait_n == 0) wait_n <= 20 + ($random & 63);
			else if (wait_n == 1) begin
				m_ready <= 1'b1; wait_n <= 0; writes = writes + 1;
				for (b = 0; b < 16; b = b + 1)
					if (m_wmask[b]) mem[((m_addr - 24'h00F000) << 4) + b] <= m_wdata[8*b +: 8];
			end else wait_n <= wait_n - 1;
		end
	end
	function [31:0] word(input integer k); word = {k[7:0] ^ 8'h5A, k[15:8], k[7:0], 8'hC3 ^ k[15:8]}; endfunction
	integer k, GAP;
	initial begin
		if (!$value$plusargs("GAP%d", GAP)) GAP = 20;
		for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
		repeat (5) @(posedge clk); rst <= 0; repeat (5) @(posedge clk);
		for (k = 0; k < 16384; k = k + 1) begin
			@(posedge clk) begin h_we <= 1; h_addr <= 32'h000F0000 + 4 * k; h_wdata <= word(k); end
			@(posedge clk) h_we <= 0;
			repeat (GAP - 1) @(posedge clk);
		end
		repeat (5000) @(posedge clk);
		for (k = 0; k < 16384; k = k + 1)
			if ({mem[4*k+3], mem[4*k+2], mem[4*k+1], mem[4*k]} !== word(k)) begin
				if (bad < 5) $display("FAIL: word %0d = %h, want %h", k, {mem[4*k+3], mem[4*k+2], mem[4*k+1], mem[4*k]}, word(k));
				bad = bad + 1;
			end
		if (h_lost) begin $display("FAIL: h_lost set"); bad = bad + 1; end
		if (bad == 0) $display("PASS: 16384 words, every one in place (GAP %0d, %0d line writes)", GAP, writes);
		else $display("FAIL: %0d of 16384 words wrong", bad);
		$finish;
	end
endmodule
