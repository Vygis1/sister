//////////////////////////////////////////////////////////////////////////////////
// tb_md_cart.v - does the block-RAM cartridge hand back what the cache expects?
//
// Two things are being checked, and the second is the one that matters:
//
//   1. a line request returns, and returns the right eight words
//   2. those words are BIG-ENDIAN 68000 words, assembled from a little-endian
//      host's 32-bit writes
//
// Point 2 has no visible failure mode short of the CPU dying: a byte-swapped
// cartridge is not a corrupted picture, it is a 68000 reading the halves of
// every instruction the wrong way round. It would look like the CPU being
// broken, which is the most expensive possible place to start looking.
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none

module tb_md_cart;

	localparam AW = 12;                 // 4096 words = 16 kB, plenty to test

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [AW-1:0] host_windex = 0;
	reg           host_we = 0;
	reg  [31:0]   wdata = 0;
	wire [31:0]   host_rdata;

	reg  [19:0]   m_addr = 0;
	reg           m_req = 0;
	wire          m_ready, m_valid;
	wire [127:0]  m_data;

	md_cart #(.AW(AW)) dut (
		.clk(clk), .rst(rst),
		.host_windex(host_windex), .host_we(host_we), .wdata(wdata),
		.host_rdata(host_rdata),
		.m_addr(m_addr), .m_req(m_req), .m_ready(m_ready),
		.m_data(m_data), .m_valid(m_valid)
	);

	integer fails = 0;
	task ok;
		input cond;
		input [800:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); fails = fails + 1; end
		end
	endtask

	// The ROM image, as a flat array of bytes, exactly as a file would be.
	function [7:0] rombyte;
		input integer n;
		rombyte = (n * 7 + 13) & 8'hFF;
	endfunction

	// What the cache should get for cartridge word W: big-endian, high byte
	// first, straight out of the image.
	function [15:0] cartword;
		input integer w;
		cartword = {rombyte(2 * w), rombyte(2 * w + 1)};
	endfunction

	integer i, line, w;
	reg [15:0] got;
	reg        allgood;

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		// Fill it the way the host does: 32-bit words, little-endian byte lanes.
		for (i = 0; i < (1 << AW); i = i + 1) begin
			@(negedge clk);
			host_windex = i[AW-1:0];
			wdata = {rombyte(4 * i + 3), rombyte(4 * i + 2),
			         rombyte(4 * i + 1), rombyte(4 * i)};
			host_we = 1;
		end
		@(negedge clk);
		host_we = 0;

		// --- a line, and the eight words in it ---------------------------------
		for (line = 0; line < 4; line = line + 1) begin
			@(negedge clk);
			m_addr = line[19:0];
			m_req  = 1;
			@(negedge clk);
			m_req  = 0;
			i = 0;
			while (!m_valid && i < 50) begin @(posedge clk); i = i + 1; end
			ok(m_valid, "the line arrives");

			allgood = 1;
			for (w = 0; w < 8; w = w + 1) begin
				got = m_data[w * 16 +: 16];
				if (got !== cartword(line * 8 + w)) begin
					allgood = 0;
					$display("      line %0d word %0d: got %04X, wanted %04X",
					         line, w, got, cartword(line * 8 + w));
				end
			end
			if (line == 0)
				ok(allgood, "all eight words are the right big-endian 68000 words");
			else
				ok(allgood, "and so are the next line's");
			@(posedge clk);
		end

		// --- it goes back to ready ----------------------------------------------
		ok(m_ready === 1'b1, "it is ready for the next line");

		// --- back to back, because the cache prefetches -------------------------
		@(negedge clk); m_addr = 20'd7; m_req = 1;
		@(negedge clk); m_req = 0;
		i = 0;
		while (!m_valid && i < 50) begin @(posedge clk); i = i + 1; end
		allgood = 1;
		for (w = 0; w < 8; w = w + 1)
			if (m_data[w * 16 +: 16] !== cartword(7 * 8 + w)) allgood = 0;
		ok(allgood, "a request straight after the last one is still correct");

		if (fails == 0) $display("tb_md_cart: all checks passed");
		else            $display("tb_md_cart: %0d FAIL(s)", fails);
		$finish;
	end

endmodule

`default_nettype wire
