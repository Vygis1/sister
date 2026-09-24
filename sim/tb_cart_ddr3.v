//////////////////////////////////////////////////////////////////////////////////
// tb_cart_ddr3.v - a cartridge in DDR3, filled and read back.
//
// The same two questions md_cart's testbench asks, because this is a drop-in for
// it and the answers have to match exactly:
//
//   1. a line request returns the right eight words
//   2. they are BIG-ENDIAN 68000 words, assembled from a little-endian host's
//      32-bit writes
//
// Plus one that only applies here: a cartridge whose length is not a multiple of
// sixteen bytes must still have its last few bytes stored. Four host words make
// one line, so a trailing partial line has to be flushed deliberately -- and
// forgetting to would lose the tail of every cartridge, which for a 68000 image
// is usually padding. It would work for a long time and then not.
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none

module tb_cart_ddr3;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [21:0] host_windex = 0;
	reg         host_we = 0, fill_end = 0;
	reg  [31:0] wdata = 0;

	reg  [19:0]  m_addr = 0;
	reg          m_req = 0;
	wire         m_ready, m_valid;
	wire [127:0] m_data;

	wire [23:0]  d_addr;
	wire         d_req, d_we;
	wire [127:0] d_wdata;
	reg          d_ready = 1;
	reg  [127:0] d_rdata = 0;
	reg          d_valid = 0;
	reg          d_calibrated = 0;

	cart_ddr3 #(.BASE(24'h00_0000)) dut (
		.clk(clk), .rst(rst),
		.host_windex(host_windex), .host_we(host_we), .wdata(wdata),
		.fill_end(fill_end),
		.m_addr(m_addr), .m_req(m_req), .m_ready(m_ready),
		.m_data(m_data), .m_valid(m_valid),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid),
		.d_calibrated(d_calibrated)
	);

	// A memory with a little latency, addressed in lines.
	reg [127:0] mem [0:4095];
	reg [23:0]  rd_a;
	reg         rd_busy = 0;
	integer     rd_wait = 0;

	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (!rst) begin
			if (d_req && d_ready) begin
				if (d_we) mem[d_addr[11:0]] <= d_wdata;
				else begin rd_a <= d_addr; rd_busy <= 1'b1; rd_wait <= 3; end
			end
			if (rd_busy) begin
				if (rd_wait > 0) rd_wait <= rd_wait - 1;
				else begin
					d_rdata <= mem[rd_a[11:0]];
					d_valid <= 1'b1;
					rd_busy <= 1'b0;
				end
			end
		end
	end

	integer fails = 0;
	task ok;
		input cond;
		input [800:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); fails = fails + 1; end
		end
	endtask

	// The ROM image, byte for byte, as a file would be.
	function [7:0] rombyte;
		input integer n;
		rombyte = (n * 7 + 13) & 8'hFF;
	endfunction

	// What the cache must be handed for cartridge word W.
	function [15:0] cartword;
		input integer w;
		cartword = {rombyte(2 * w), rombyte(2 * w + 1)};
	endfunction

	localparam WORDS = 512;       // 2 kB of cartridge, deliberately not a round
	                              // number of lines once the tail is added

	integer i, line, w, bad;
	reg [127:0] got;

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		// Refuses everything until the memory is up.
		ok(!m_ready, "no cartridge reads before the memory has calibrated");
		d_calibrated = 1;
		@(posedge clk);

		// --- fill it the way the host does ------------------------------------------
		for (i = 0; i < WORDS; i = i + 1) begin
			@(negedge clk);
			host_windex = i[21:0];
			wdata = {rombyte(4*i + 3), rombyte(4*i + 2),
			         rombyte(4*i + 1), rombyte(4*i)};
			host_we = 1'b1;
			@(negedge clk);
			host_we = 1'b0;
			// Let a pending line go out before offering the next word.
			while (!m_ready) @(negedge clk);
		end
		@(negedge clk);
		fill_end = 1'b1;
		@(negedge clk);
		fill_end = 1'b0;
		while (!m_ready) @(negedge clk);

		// --- read it back -------------------------------------------------------------
		bad = 0;
		for (line = 0; line < WORDS / 4; line = line + 1) begin
			@(negedge clk);
			m_addr = line[19:0];
			m_req  = 1'b1;
			#1;
			while (!m_ready) @(negedge clk);
			@(negedge clk);
			m_req = 1'b0;
			got = 128'dx;
			for (i = 0; i < 100 && got === 128'dx; i = i + 1) begin
				@(posedge clk);
				if (m_valid) got = m_data;
			end
			for (w = 0; w < 8; w = w + 1)
				if (got[w*16 +: 16] !== cartword(line * 8 + w)) begin
					if (bad < 3)
						$display("      line %0d word %0d: got %04X wanted %04X",
						         line, w, got[w*16 +: 16], cartword(line*8 + w));
					bad = bad + 1;
				end
		end
		ok(bad == 0, "every line reads back as the right big-endian 68000 words");

		// --- the tail -------------------------------------------------------------------
		// One more word, on its own, then end the fill: it must reach memory.
		@(negedge clk);
		host_windex = WORDS[21:0];
		wdata = 32'hAABBCCDD;
		host_we = 1'b1;
		@(negedge clk);
		host_we = 1'b0;
		fill_end = 1'b1;
		@(negedge clk);
		fill_end = 1'b0;
		while (!m_ready) @(negedge clk);

		@(negedge clk);
		m_addr = WORDS[19:0] >> 2;
		m_req = 1'b1;
		#1;
		while (!m_ready) @(negedge clk);
		@(negedge clk);
		m_req = 1'b0;
		got = 128'dx;
		for (i = 0; i < 100 && got === 128'dx; i = i + 1) begin
			@(posedge clk);
			if (m_valid) got = m_data;
		end
		// $AABBCCDD packs DD into lane 0, so the first cartridge word is
		// {DD,CC} and the second {BB,AA}. Writing that expectation backwards is
		// the easiest possible mistake to make here, and it accuses the design
		// of the exact bug this file exists to rule out.
		ok(got[0 +: 16] === 16'hDDCC && got[16 +: 16] === 16'hBBAA,
		   "a cartridge whose last line is short still has its tail stored");

		if (fails == 0) $display("tb_cart_ddr3: all checks passed");
		else            $display("tb_cart_ddr3: %0d FAIL(s)", fails);
		$finish;
	end

endmodule

`default_nettype wire
