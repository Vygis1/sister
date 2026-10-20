// tb_simple_fifo - simple_fifo with BLOCK=1 (a registered read: block RAM) against BLOCK=0 (the original
// asynchronous read), the same random pushes, pops and clears into both: empty, full, usedw and the word
// at the head (whenever not empty) must agree every clock.
`include "../../rtl/pc/common/simple_fifo.v"     // (rtl/pc is not in sim.sh's file list)
`timescale 1ns/1ps
module tb_simple_fifo;
	reg clk = 0, rst_n = 0;
	always #5 clk = ~clk;
	reg sclr = 0, rdreq = 0, wrreq = 0; reg [31:0] data = 0;
	wire e0, e1, f0, f1; wire [31:0] q0, q1; wire [4:0] u0, u1;
	simple_fifo #(.width(32), .widthu(5), .BLOCK(0)) a (.clk(clk), .rst_n(rst_n), .sclr(sclr), .rdreq(rdreq), .wrreq(wrreq), .data(data), .empty(e0), .full(f0), .q(q0), .usedw(u0));
	simple_fifo #(.width(32), .widthu(5), .BLOCK(1)) b (.clk(clk), .rst_n(rst_n), .sclr(sclr), .rdreq(rdreq), .wrreq(wrreq), .data(data), .empty(e1), .full(f1), .q(q1), .usedw(u1));
	integer i, bad = 0, cmp = 0, phase;
	initial begin
		repeat (3) @(posedge clk); rst_n <= 1;
		for (i = 0; i < 200000; i = i + 1) begin
			@(negedge clk);
			if (e0 !== e1 || f0 !== f1 || u0 !== u1 || (!e0 && q0 !== q1)) begin
				if (bad < 6) $display("FAIL at %0d: empty %b/%b full %b/%b used %0d/%0d q %h/%h", i, e0, e1, f0, f1, u0, u1, q0, q1);
				bad = bad + 1;
			end
			if (!e0) cmp = cmp + 1;
			phase = (i / 5000) % 4;                     // (phases: filling, draining, balanced, bursts)
			wrreq <= ($random & 3) < (phase == 0 ? 3 : phase == 1 ? 1 : 2);
			rdreq <= ($random & 3) < (phase == 0 ? 1 : phase == 1 ? 3 : 2);
			sclr  <= ($random & 1023) == 0;
			data  <= $random;
		end
		if (bad == 0) $display("PASS: 200000 clocks, the head word compared %0d times, all equal", cmp);
		else $display("FAIL: %0d clocks differ", bad);
		$finish;
	end
endmodule
