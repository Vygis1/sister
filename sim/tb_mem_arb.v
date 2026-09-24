//////////////////////////////////////////////////////////////////////////////////
// tb_mem_arb.v - several masters, one memory, and nobody left behind.
//
// Three things are being checked, and only the first is obvious:
//
//   1. every line a client asks for comes back, to THAT client, in order
//   2. a busy high-priority port cannot starve a low-priority one for ever
//   3. writes take the bus but return nothing, and do not confuse the queue
//
// Point 2 is the one worth a testbench. Fixed priority is the right choice here
// -- a GPU that misses its scanline tears the picture and a disc streamer that
// waits does not care -- but it is exactly the choice that hangs the machine if
// the guard against it is wrong, and a hang looks like a dead core rather than
// a busy bus. So the test holds port 0 down permanently and insists port 3 is
// still served.
//
// Point 1 matters because the memory says nothing about who asked. If the queue
// that remembers is off by one, every client gets somebody else's data -- which
// is not a crash, it is a machine that behaves strangely for reasons nothing
// points at.
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none

module tb_mem_arb;

	localparam PORTS = 4, AW = 24, STARVE = 16;
	localparam BURST = 40;   // deeper than the arbiter's return queue on purpose

	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	reg  [PORTS*AW-1:0]  p_addr  = 0;
	reg  [PORTS-1:0]     p_req   = 0;
	reg  [PORTS-1:0]     p_we    = 0;
	reg  [PORTS*128-1:0] p_wdata = 0;
	wire [PORTS-1:0]     p_ready, p_valid;
	wire [PORTS*128-1:0] p_rdata;

	wire [AW-1:0]  m_addr;
	wire           m_req, m_we;
	wire [127:0]   m_wdata;
	reg            m_ready = 1;
	reg  [127:0]   m_rdata = 0;
	reg            m_valid = 0;

	mem_arb #(.PORTS(PORTS), .AW(AW), .STARVE(STARVE)) dut (
		.clk(clk), .rst(rst),
		.p_addr(p_addr), .p_req(p_req), .p_we(p_we), .p_wdata(p_wdata), .p_wmask({PORTS{16'hFFFF}}),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid)
	);

	// A memory with latency: it takes a request, waits a few cycles, and hands
	// back the address as data so that whose-line-is-this is checkable.
	reg [AW-1:0] pend [0:63];
	reg [5:0]    ph = 0, pt = 0;
	integer      delay = 0;

	reg hold_replies = 1'b0;     // the memory accepts but does not answer

	always @(posedge clk) begin
		m_valid <= 1'b0;
		if (!rst) begin
			if (m_req && m_ready && !m_we) begin
				pend[pt] <= m_addr;
				pt <= pt + 6'd1;
			end
			delay <= delay + 1;
			if ((ph != pt) && (delay[1:0] == 2'b11) && !hold_replies) begin
				m_rdata <= {104'd0, pend[ph]};
				m_valid <= 1'b1;
				ph <= ph + 6'd1;
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

	// --- issuing ONE request, the way a client must -----------------------------
	//
	// `p_ready` is combinational, so every cycle it is high alongside req is a
	// separate accepted transfer. A client that holds req up because it is
	// waiting to "see" ready has issued three or four requests, not one.
	//
	// That is not a fault in the arbiter -- it is how a ready/valid handshake
	// works -- but it is very easy to write a testbench that does it by
	// accident, and the strays surface later as data arriving on a port that
	// asked for nothing. Which is exactly what happened here.
	//
	// Signals change on the falling edge and are sampled on the rising one, so
	// there is never a question of which cycle a transfer belonged to.
	task request;
		input integer port;
		input [AW-1:0] a;
		input          write;
		begin
			@(negedge clk);
			p_addr[port*AW +: AW] = a;
			p_we[port]            = write;
			p_req[port]           = 1'b1;
			// Let the combinational grant settle before reading it.
			//
			// Without this, the blocking assignment above and the read below
			// happen in the same simulation instant and the read can take the
			// value p_ready had BEFORE req went up. The task then waits a full
			// cycle -- during which the grant it was waiting for happens and
			// goes unseen -- and issues a second request on top of the first.
			//
			// Stepping to the next negedge instead has the same effect for the
			// same reason, so the fix is to settle, not to wait longer.
			#1;
			while (!p_ready[port]) @(negedge clk);
			// The transfer is taken on the next rising edge. Drop the request
			// at the falling edge AFTER it, never at the rising edge itself:
			// clearing a signal at the instant the design samples it is a race,
			// and the one it loses here is `we` -- so a write gets recorded as a
			// read, a queue entry appears for it, and data comes back for
			// something that never asked. Stimulus changes on the inactive
			// edge, always.
			@(negedge clk);
			p_req[port] = 1'b0;
			p_we[port]  = 1'b0;
		end
	endtask

	// Let everything in flight come back before judging the next thing.
	task drain;
		integer k;
		begin
			for (k = 0; k < 80; k = k + 1) @(posedge clk);
		end
	endtask

	integer got3, i;
	reg [AW-1:0] want;
	reg          seen;

	// --- the deep-burst driver and checker ------------------------------------
	// Port 1 asks for BURST lines back to back; port 2 is in flight at the same
	// time so the return queue is genuinely shared. Everything is driven and
	// sampled on the clock, so nothing races the arbiter.
	reg        burst_on   = 1'b0;
	reg        burst_done = 1'b0;
	reg        burst_bad  = 1'b0;
	reg [7:0]  burst_i    = 8'd0;
	reg [7:0]  burst_got  = 8'd0;
	reg        burst_run  = 1'b0;

	always @(posedge clk) begin
		if (!burst_on) begin
			burst_i <= 8'd0; burst_got <= 8'd0; burst_done <= 1'b0;
			burst_bad <= 1'b0; burst_run <= 1'b0;
		end else begin
			if (!burst_run) begin
				// first cycle: present the first address and a second port's read
				p_addr[1*AW +: AW] <= 24'h01_0000;
				p_addr[2*AW +: AW] <= 24'h02_2222;
				p_req[1]  <= 1'b1;
				p_req[2]  <= 1'b1;
				burst_run <= 1'b1;
			end else begin
				if (p_ready[2]) p_req[2] <= 1'b0;
				if (p_ready[1] && burst_i < BURST) begin
					burst_i <= burst_i + 8'd1;
					p_addr[1*AW +: AW] <= 24'h01_0000 + {16'd0, burst_i} + 24'd1;
					if (burst_i + 8'd1 == BURST) p_req[1] <= 1'b0;
				end
				if (p_valid[1]) begin
					if (p_rdata[1*128 +: AW] !== 24'h01_0000 + {16'd0, burst_got})
						burst_bad <= 1'b1;
					burst_got <= burst_got + 8'd1;
					if (burst_got + 8'd1 == BURST) burst_done <= 1'b1;
				end
			end
		end
	end

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		// --- one client, one line ------------------------------------------------
		request(0, 24'h00_1234, 1'b0);
		seen = 1'b0;
		for (i = 0; i < 40 && !seen; i = i + 1) begin
			@(posedge clk);
			if (p_valid[0]) seen = 1'b1;
		end
		ok(seen, "a line asked for comes back");
		ok(p_rdata[0*128 +: AW] === 24'h00_1234,
		   "and it is the line that was asked for, on the port that asked");

		// --- two at once: the data must not cross over ----------------------------
		drain();
		request(1, 24'h00_AAAA, 1'b0);
		request(2, 24'h00_BBBB, 1'b0);

		seen = 1'b0;
		for (i = 0; i < 60; i = i + 1) begin
			@(posedge clk);
			if (p_valid[1] && p_rdata[1*128 +: AW] !== 24'h00_AAAA) seen = 1'b1;
			if (p_valid[2] && p_rdata[2*128 +: AW] !== 24'h00_BBBB) seen = 1'b1;
		end
		ok(!seen, "two ports in flight get their own lines, not each other's");

		// --- a write takes the bus and returns nothing -----------------------------
		drain();
		p_wdata[0*128 +: 32] = 32'hDEADBEEF;
		request(0, 24'h00_5555, 1'b1);
		seen = 1'b0;
		for (i = 0; i < 40; i = i + 1) begin
			@(posedge clk);
			if (p_valid[0]) seen = 1'b1;
		end
		ok(!seen, "a write produces no read data and does not desynchronise the queue");

		// --- the starvation guard ---------------------------------------------------
		// Port 0 asks for ever. Port 3 is lowest priority and must still be served.
		got3 = 0;
		p_addr[0*AW +: AW] = 24'h00_0001;
		p_addr[3*AW +: AW] = 24'h00_0003;
		p_req[0] = 1'b1;
		p_req[3] = 1'b1;
		for (i = 0; i < 2000; i = i + 1) begin
			@(posedge clk);
			if (p_ready[3]) got3 = got3 + 1;
		end
		p_req[0] = 1'b0; p_req[3] = 1'b0;
		$display("    port 3 was served %0d times while port 0 never stopped asking", got3);
		ok(got3 > 5, "a port that keeps asking cannot starve a lower one for ever");

		// --- more reads outstanding than the return queue can hold ---------------
		// This is the check that was missing, and its absence cost a build and a
		// dead picture. The video cache asks for a run of sixteen lines in one go
		// while other ports are in flight, so the queue of who-asked really does
		// fill. It had four-bit pointers and no full detection: the head wrapped
		// onto the tail, the queue read as EMPTY while it was full, every reply
		// after that was dropped, and the scanout waited for a count that could
		// never arrive. The screen simply stopped.
		//
		// Driven from a clocked block on purpose: poking the request signals from
		// the test's own loop races the arbiter sampling them on the same edge,
		// which makes the lines come back in an order that looks like a bug and
		// is not.
		drain();
		burst_on = 1'b1;
		for (i = 0; i < 6000 && !burst_done; i = i + 1) @(posedge clk);
		burst_on = 1'b0;
		@(posedge clk);
		$display("    asked for %0d lines back to back, %0d came back", BURST, burst_got);
		ok(burst_got == BURST, "every line of a burst deeper than the return queue comes back");
		ok(!burst_bad, "and each one is the line that was asked for, in order");

		// --- a full read queue must not stop a write ------------------------------
		// The first fix for the overflow chose a winner and THEN refused to issue
		// it if the queue was full. That stops the whole bus: a port with a write
		// to do needs no queue entry, and its completion is part of what lets the
		// queue drain, but it never got a turn. On the board that showed up as no
		// instructions retiring at all and a dead picture. A read that cannot be
		// recorded must simply not contend.
		drain();
		begin : full_then_write
			integer wgot;
			wgot = 0;
			// fill the queue: port 1 asks for ever, memory answers nothing yet
			hold_replies = 1'b1;
			p_addr[1*AW +: AW] = 24'h03_0000;
			p_req[1] = 1'b1;
			for (i = 0; i < 200; i = i + 1) @(posedge clk);
			// now a write turns up on another port
            p_wdata[3*128 +: 32] = 32'hFEEDFACE;
			p_addr[3*AW +: AW] = 24'h03_9999;
			p_we[3]  = 1'b1;
			p_req[3] = 1'b1;
			for (i = 0; i < 200 && wgot == 0; i = i + 1) begin
				@(posedge clk);
				if (p_ready[3]) wgot = 1;
			end
			p_req[1] = 1'b0; p_req[3] = 1'b0; p_we[3] = 1'b0;
			hold_replies = 1'b0;
			ok(wgot == 1, "a write still gets the bus while the read queue is full");
			drain();
		end

		if (fails == 0) $display("tb_mem_arb: all checks passed");
		else            $display("tb_mem_arb: %0d FAIL(s)", fails);
		$finish;
	end

endmodule

`default_nettype wire
