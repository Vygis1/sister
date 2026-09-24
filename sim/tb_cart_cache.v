`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_cart_cache - does DDR3 behind a cache look enough like a cartridge?
//
// This is a MEASUREMENT, not a feature test. docs/MEGADRIVE.md says the first
// DDR3 milestone has to be a number rather than a working thing, because if a
// cached sequential read is not comfortably inside a 68000 bus cycle then the
// Mega Drive needs a different shape and everything built on top of the current
// one is wasted.
//
// So: a model of DDR3 with a latency that is neither fixed nor optimistic, a
// requester that reads the way a 68000 actually reads, and a count at the end of
// how many cycles were spent waiting.
//
// The correctness checks are here too -- every word read is compared against
// what the memory holds -- because a cache that returns the wrong data quickly
// is not a useful measurement of anything.
//////////////////////////////////////////////////////////////////////////////////

module tb_cart_cache;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// --- the cache -------------------------------------------------------------------
	reg  [22:0] a_addr = 0;
	reg         a_req  = 0;
	wire [15:0] a_data;
	wire        a_ack;

	reg  [22:0] b_addr = 0;
	reg         b_req  = 0;
	wire [15:0] b_data;
	wire        b_ack;

	wire [19:0]  m_addr;
	wire         m_req;
	reg          m_ready = 1;
	reg  [127:0] m_data  = 0;
	reg          m_valid = 0;

	wire [31:0] hits, misses, stall, prefetch;

	cart_cache dut (
		.clk(clk), .rst(rst),
		.a_addr(a_addr), .a_req(a_req), .a_data(a_data), .a_ack(a_ack),
		.b_addr(b_addr), .b_req(b_req), .b_data(b_data), .b_ack(b_ack),
		.m_addr(m_addr), .m_req(m_req), .m_ready(m_ready),
		.m_data(m_data), .m_valid(m_valid),
		.dbg_hits(hits), .dbg_misses(misses), .dbg_stall(stall),
		.dbg_prefetch(prefetch)
	);

	// --- the memory -----------------------------------------------------------------------
	// A cartridge, as a function of its address rather than an array: 8 MB of
	// storage in a testbench is avoidable, and a value derived from the address
	// catches a cache handing back the right word from the wrong line, which an
	// array of zeroes would not.
	function [15:0] cart_word;
		input [22:0] a;
		begin cart_word = a[15:0] ^ {a[22:16], 9'h1A5}; end
	endfunction

	// DDR3's latency is not one number. A read that lands in an already-open row
	// comes back quickly; one that has to close a row and open another takes far
	// longer, and which it is depends on what was read before. This models that
	// with a row of 512 lines: same row, 12 cycles; different row, 30.
	integer LAT_SAME = 12;
	integer LAT_DIFF = 30;

	reg [19:0] open_row = 20'hFFFFF;
	integer    lat;
	// The model's own loop variable. Sharing one with the test below looks
	// harmless and is not: they run at the same time, and the model's inner loop
	// resets the counter the test is walking through the cartridge with.
	integer    mk;
	integer    k;

	integer mem_reads = 0;

	// A controller that is busy must SAY so. Left permanently ready, it drops
	// every request that arrives while it is working -- the cache lets go of
	// m_req as soon as it is taken -- and the whole thing deadlocks waiting for
	// a line that was never asked for.
	reg [19:0] req_line;

	initial begin
		m_ready = 1'b1;
		m_valid = 1'b0;
		forever begin
			@(posedge clk);
			if (m_req && m_ready) begin
				req_line  = m_addr;
				m_ready  <= 1'b0;
				mem_reads = mem_reads + 1;
				lat = (req_line[19:9] == open_row[19:9]) ? LAT_SAME : LAT_DIFF;
				open_row = req_line;
				repeat (lat) @(posedge clk);
				for (mk = 0; mk < 8; mk = mk + 1)
					m_data[mk*16 +: 16] <= cart_word({req_line, mk[2:0]});
				m_valid <= 1'b1;
				@(posedge clk);
				m_valid <= 1'b0;
				m_ready <= 1'b1;
			end
		end
	end

	// --- checking and counting ----------------------------------------------------------
	integer errors = 0;
	integer reads  = 0;
	integer waited = 0;
	integer t0;

	// Stimulus is driven on the FALLING edge and sampled there too. Driving it on
	// the rising edge, where the design also samples, is a race -- and one that
	// does not announce itself: it shows up as an answer arriving a cycle early
	// and belonging to the previous request.
	task read_a;
		input [22:0] a;
		integer w;
		begin
			w = 0;
			@(negedge clk);
			a_addr = a;
			a_req  = 1;
			@(negedge clk);
			while (!a_ack && w < 2000) begin @(negedge clk); w = w + 1; end
			a_req = 0;
			if (w >= 2000) begin
				$display("  FAIL no answer for $%06x", a);
				errors = errors + 1;
			end else if (a_data !== cart_word(a)) begin
				$display("  FAIL $%06x = %04x, the cartridge holds %04x",
				         a, a_data, cart_word(a));
				errors = errors + 1;
			end
			reads  = reads + 1;
			waited = waited + w;
			@(negedge clk);
		end
	endtask

	task read_b;
		input [22:0] a;
		integer w;
		begin
			w = 0;
			@(negedge clk);
			b_addr = a;
			b_req  = 1;
			@(negedge clk);
			while (!b_ack && w < 2000) begin @(negedge clk); w = w + 1; end
			b_req = 0;
			if (w >= 2000) begin
				$display("  FAIL the Z80's port got no answer for $%06x", a);
				errors = errors + 1;
			end else if (b_data !== cart_word(a)) begin
				$display("  FAIL the Z80's port read $%06x as %04x, not %04x",
				         a, b_data, cart_word(a));
				errors = errors + 1;
			end
			@(negedge clk);
		end
	endtask

	// The 68000 does not read back to back: an instruction fetch takes several
	// clocks to decode and execute before the next one. Waiting between reads is
	// what gives a prefetch time to land, so leaving it out would make the
	// measurement look far worse than the machine will be.
	task gap;
		input integer n;
		begin repeat (n) @(posedge clk); end
	endtask

	integer h0, m0, s0, p0;

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		$display("tb_cart_cache");

		// --- correctness first ---------------------------------------------------
		$display(" reading:");
		read_a(23'h000000);
		read_a(23'h000001);
		read_a(23'h000007);
		read_a(23'h000008);        // the next line
		read_a(23'h004000);        // somewhere else entirely
		read_a(23'h000002);        // and back, which should still be held
		check_ok("every word read back matched the cartridge");

		// A line that maps to the same slot as one already held must replace it,
		// not be mistaken for it.
		read_a(23'h000000);
		read_a(23'h000800);        // same index, different tag
		read_a(23'h000000);
		check_ok("two lines that share a slot do not get confused");

		// The Z80's port reads the same memory through the same cache.
		read_b(23'h000003);
		read_b(23'h004001);
		check_ok("the Z80's window reads the same cartridge");

		// --- and now the measurement ------------------------------------------------
		// Sixteen kilowords read in order, with a gap between them of about what
		// a 68000 takes to get from one instruction fetch to the next.
		h0 = hits; m0 = misses; s0 = stall; p0 = prefetch;
		reads = 0; waited = 0; mem_reads = 0;

		for (k = 0; k < 4096; k = k + 1) begin
			read_a(k[22:0] + 23'h010000);
			gap(8);
		end

		$display("");
		$display(" streaming 4096 words, a 68000's worth of gap between them:");
		$display("   hits      %0d", hits - h0);
		$display("   misses    %0d", misses - m0);
		$display("   prefetch  %0d lines fetched before they were asked for",
		         prefetch - p0);
		$display("   waiting   %0d cycles in total, %0d per read",
		         waited, waited / 4096);
		// Eight words to a line, so one read in eight can miss at worst. What the
		// prefetch is for is making almost none of them stall.
		check(waited / 4096 <= 4,
		      "a streaming read costs under four cycles a word on average");

		// The other extreme: reads scattered across the cartridge, every one of
		// them a miss. This is what a game looks like when it is chasing pointers,
		// and the number is the floor the cache cannot get below.
		h0 = hits; m0 = misses; reads = 0; waited = 0;
		for (k = 0; k < 256; k = k + 1) begin
			read_a({k[6:0], 16'h0123} + 23'h100000);
			gap(8);
		end
		$display("");
		$display(" jumping about, 256 reads:");
		$display("   hits      %0d", hits - h0);
		$display("   misses    %0d", misses - m0);
		$display("   waiting   %0d cycles in total, %0d per read",
		         waited, waited / 256);

		$display("");
		if (errors == 0) $display("tb_cart_cache: all checks passed");
		else             $display("tb_cart_cache: %0d FAIL(s)", errors);
		$finish;
	end

	task check;
		input condition;
		input [1023:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin
				$display("  FAIL %0s", what);
				errors = errors + 1;
			end
		end
	endtask

	// Report a group of reads as one line, since each read has already checked
	// itself and only a failure is worth printing individually.
	integer last_errors = 0;
	task check_ok;
		input [1023:0] what;
		begin
			check(errors == last_errors, what);
			last_errors = errors;
		end
	endtask

	initial begin
		repeat (4000000) @(posedge clk);
		$display("tb_cart_cache: FAIL timeout");
		$finish;
	end

endmodule
