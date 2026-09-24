//////////////////////////////////////////////////////////////////////////////////
// tb_ddr3_mem.v - the line interface, across two clocks, against a fake MIG.
//
// The model here is not Micron's DDR3 part; it is MIG's USER interface, which is
// the thing this module actually talks to. It holds app_rdy and app_wdf_rdy low
// at awkward moments and returns read data after a variable delay, because both
// are how the real controller behaves and both are where a handshake breaks.
//
// What is being checked:
//
//   1. a line written and then read back returns the same 128 bits
//   2. the address arithmetic is right -- app_addr counts 16-bit WORDS, so a
//      line is eight apart, and getting that wrong reads real memory at the
//      wrong place rather than failing
//   3. a write produces no read completion, which would desynchronise a client
//      that counts them
//   4. it survives the command and the write data being accepted on different
//      cycles, which MIG does routinely
//
// The two clocks are deliberately unrelated -- 50 MHz and 83.3 MHz -- because a
// crossing that only works at a tidy ratio is one that has not been tested.
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none

module tb_ddr3_mem;

	localparam AW = 24;

	reg clk = 0;      always #10    clk = ~clk;       // 50 MHz
	reg ui_clk = 0;   always #6.0   ui_clk = ~ui_clk; // ~83 MHz
	reg rst = 1, ui_rst = 1;
	reg calib_done = 0;

	reg  [AW-1:0] m_addr = 0;
	reg           m_req = 0, m_we = 0;
	reg  [127:0]  m_wdata = 0;
	wire          m_ready, m_valid, m_calibrated;
	wire [127:0]  m_rdata;

	wire [27:0]  app_addr;
	wire [2:0]   app_cmd;
	wire         app_en, app_wdf_wren, app_wdf_end;
	wire [127:0] app_wdf_data;
	wire [15:0]  app_wdf_mask;
	reg          app_rdy = 0, app_wdf_rdy = 0;
	reg  [127:0] app_rd_data = 0;
	reg          app_rd_data_valid = 0;

	ddr3_mem #(.AW(AW)) dut (
		.clk(clk), .rst(rst),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(16'hFFFF),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid),
		.m_calibrated(m_calibrated),
		.ui_clk(ui_clk), .ui_rst(ui_rst), .calib_done(calib_done),
		.app_addr(app_addr), .app_cmd(app_cmd), .app_en(app_en), .app_rdy(app_rdy),
		.app_wdf_data(app_wdf_data), .app_wdf_wren(app_wdf_wren),
		.app_wdf_end(app_wdf_end), .app_wdf_mask(app_wdf_mask),
		.app_wdf_rdy(app_wdf_rdy),
		.app_rd_data(app_rd_data), .app_rd_data_valid(app_rd_data_valid)
	);

	// --- a memory that behaves like MIG's user interface --------------------------
	reg [127:0] store [0:1023];
	reg [27:0]  rd_addr;
	integer     rd_wait = 0;
	reg [27:0]  rdq_addr [0:15];
	reg [3:0]   rdq_head = 0, rdq_tail = 0;
	integer j, burst_bad, burst_n, guard;
	time    t_one, t_start, t_burst;
	reg         rd_busy = 0;
	integer     tick = 0;
	integer     writes = 0;

	// Ready is deliberately intermittent, and the two readies are not in step:
	// MIG accepts the command and the write data independently.
	always @(posedge ui_clk) begin
		tick <= tick + 1;
		app_rdy     <= (tick % 3) != 0;
		app_wdf_rdy <= (tick % 4) != 1;

		app_rd_data_valid <= 1'b0;

		if (!ui_rst) begin
			if (app_en && app_rdy) begin
				if (app_cmd == 3'd1) begin
					// Reads queue. The real controller takes a command every
					// cycle it says it is ready and returns the lines in the
					// order they were asked for -- which is the whole basis for
					// asking for several at once, so a model that tracks only
					// one cannot test the thing under test.
					rdq_addr[rdq_tail] <= app_addr;
					rdq_tail <= rdq_tail + 4'd1;
					if (rdq_head == rdq_tail) rd_wait <= 4 + (tick % 5);
				end
			end
			if (app_wdf_wren && app_wdf_rdy) begin
				// The command carries the address; for this test the write
				// address is whatever the command most recently presented.
				store[app_addr[12:3]] <= app_wdf_data;
				writes <= writes + 1;
			end
			if (rdq_head != rdq_tail) begin
				if (rd_wait > 0) rd_wait <= rd_wait - 1;
				else begin
					app_rd_data       <= store[rdq_addr[rdq_head][12:3]];
					app_rd_data_valid <= 1'b1;
					rdq_head          <= rdq_head + 4'd1;
					// the ones behind it follow closely: the row is already open
					rd_wait           <= 1;
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

	task line_write;
		input [AW-1:0] a;
		input [127:0]  d;
		begin
			@(negedge clk);
			m_addr = a; m_wdata = d; m_we = 1'b1; m_req = 1'b1;
			#1;
			while (!m_ready) @(negedge clk);
			@(negedge clk);
			m_req = 1'b0; m_we = 1'b0;
		end
	endtask

	task line_read;
		input [AW-1:0] a;
		output [127:0] d;
		integer k;
		begin
			@(negedge clk);
			m_addr = a; m_we = 1'b0; m_req = 1'b1;
			#1;
			while (!m_ready) @(negedge clk);
			@(negedge clk);
			m_req = 1'b0;
			d = 128'dx;
			for (k = 0; k < 400 && d === 128'dx; k = k + 1) begin
				@(posedge clk);
				if (m_valid) d = m_rdata;
			end
		end
	endtask

	reg [127:0] got;
	integer     i, spurious;
	reg [27:0]  seen_addr;

	initial begin
		repeat (4) @(posedge ui_clk);
		ui_rst = 0;
		repeat (4) @(posedge clk);
		rst = 0;

		ok(!m_ready, "it refuses requests until the memory has calibrated");
		calib_done = 1;
		repeat (4) @(posedge clk);
		ok(m_ready, "and accepts them once it has");

		// --- a line there and back ------------------------------------------------
		line_write(24'h00_0010, 128'hDEADBEEF_CAFEBABE_01234567_89ABCDEF);
		line_read (24'h00_0010, got);
		ok(got === 128'hDEADBEEF_CAFEBABE_01234567_89ABCDEF,
		   "a line written comes back exactly");

		// --- the address arithmetic ------------------------------------------------
		// Line 0x10 must appear on app_addr as 0x80: eight 16-bit words apart.
		seen_addr = 28'd0;
		fork
			begin : watch
				for (i = 0; i < 400; i = i + 1) begin
					@(posedge ui_clk);
					if (app_en && app_rdy) seen_addr = app_addr;
				end
			end
			begin
				line_read(24'h00_0010, got);
			end
		join
		ok(seen_addr === 28'h0000080,
		   "a line address becomes eight 16-bit words on app_addr");

		// --- neighbouring lines do not overlap ---------------------------------------
		line_write(24'h00_0020, 128'h11111111_22222222_33333333_44444444);
		line_write(24'h00_0021, 128'h55555555_66666666_77777777_88888888);
		line_read (24'h00_0020, got);
		ok(got === 128'h11111111_22222222_33333333_44444444,
		   "one line does not land on top of the next");
		line_read (24'h00_0021, got);
		ok(got === 128'h55555555_66666666_77777777_88888888,
		   "and neither does the next on that one");

		// --- a write returns nothing ---------------------------------------------------
		spurious = 0;
		line_write(24'h00_0030, 128'hA5A5A5A5_5A5A5A5A_A5A5A5A5_5A5A5A5A);
		for (i = 0; i < 200; i = i + 1) begin
			@(posedge clk);
			if (m_valid) spurious = spurious + 1;
		end
		ok(spurious == 0, "a write produces no read completion");

		// --- a run of them, to shake the crossing ---------------------------------------
		for (i = 0; i < 24; i = i + 1)
			line_write(24'h00_0100 + i[AW-1:0], {4{32'h1000_0000 + i}});
		spurious = 0;
		for (i = 0; i < 24; i = i + 1) begin
			line_read(24'h00_0100 + i[AW-1:0], got);
			if (got !== {4{32'h1000_0000 + i}}) spurious = spurious + 1;
		end
		ok(spurious == 0, "twenty-four lines survive a round trip across both clocks");

		// --- several in flight at once -------------------------------------------------
		// The point of the queue. Eight reads are asked for without waiting for
		// any of them, and the lines must come back in the order they were asked
		// for: that order is the only thing the arbiter above has to match each
		// line to the client that wanted it.
		for (i = 0; i < 8; i = i + 1)
			line_write(24'h00_0200 + i[AW-1:0], {4{32'h2000_0000 + i}});
		burst_bad = 0; burst_n = 0;
		fork
			begin
				for (j = 0; j < 8; j = j + 1) begin
					@(posedge clk);
					while (!m_ready) @(posedge clk);
					m_addr <= 24'h00_0200 + j[AW-1:0]; m_we <= 1'b0; m_req <= 1'b1;
					@(posedge clk); m_req <= 1'b0;
				end
			end
			begin
				guard = 0;
				while (burst_n < 8 && guard < 20000) begin
					@(posedge clk);
					guard = guard + 1;
					if (m_valid) begin
						if (m_rdata !== {4{32'h2000_0000 + burst_n}}) burst_bad = burst_bad + 1;
						burst_n = burst_n + 1;
					end
				end
			end
		join
		ok(burst_bad == 0 && burst_n == 8,
		   "eight reads asked for without waiting come back in order");

		// and it is faster, which is the whole reason for the change
		t_one = $time;
		for (i = 0; i < 8; i = i + 1) line_read(24'h00_0200 + i[AW-1:0], got);
		t_one = $time - t_one;
		t_burst = $time; burst_n = 0;
		fork
			begin
				for (j = 0; j < 8; j = j + 1) begin
					@(posedge clk);
					while (!m_ready) @(posedge clk);
					m_addr <= 24'h00_0200 + j[AW-1:0]; m_we <= 1'b0; m_req <= 1'b1;
					@(posedge clk); m_req <= 1'b0;
				end
			end
			begin
				guard = 0;
				while (burst_n < 8 && guard < 20000) begin
					@(posedge clk); guard = guard + 1;
					if (m_valid) burst_n = burst_n + 1;
				end
			end
		join
		t_burst = $time - t_burst;
		$display("   eight one at a time: %0t   eight queued: %0t", t_one, t_burst);
		ok(t_burst * 2 < t_one, "queued reads finish in under half the time");

		// --- several in flight at once -------------------------------------------------
		// The point of the queue. Eight reads are asked for without waiting for
		// any of them, and the lines must come back in the order they were asked
		// for: that order is the only thing the arbiter above has to match each
		// line to the client that wanted it.
		for (i = 0; i < 8; i = i + 1)
			line_write(24'h00_0200 + i[AW-1:0], {4{32'h2000_0000 + i}});
		burst_bad = 0; burst_n = 0;
		fork
			begin
				for (j = 0; j < 8; j = j + 1) begin
					@(posedge clk);
					while (!m_ready) @(posedge clk);
					m_addr <= 24'h00_0200 + j[AW-1:0]; m_we <= 1'b0; m_req <= 1'b1;
					@(posedge clk); m_req <= 1'b0;
				end
			end
			begin
				while (burst_n < 8) begin
					@(posedge clk);
					if (m_valid) begin
						if (m_rdata !== {4{32'h2000_0000 + burst_n}}) burst_bad = burst_bad + 1;
						burst_n = burst_n + 1;
					end
				end
			end
		join
		ok(burst_bad == 0 && burst_n == 8,
		   "eight reads asked for without waiting come back in order");

		// and it is faster, which is the whole reason for the change
		t_one = $time;
		for (i = 0; i < 8; i = i + 1) line_read(24'h00_0200 + i[AW-1:0], got);
		t_one = $time - t_one;
		t_burst = $time; burst_n = 0;
		fork
			begin
				for (j = 0; j < 8; j = j + 1) begin
					@(posedge clk);
					while (!m_ready) @(posedge clk);
					m_addr <= 24'h00_0200 + j[AW-1:0]; m_we <= 1'b0; m_req <= 1'b1;
					@(posedge clk); m_req <= 1'b0;
				end
			end
			begin
				while (burst_n < 8) begin @(posedge clk); if (m_valid) burst_n = burst_n + 1; end
			end
		join
		t_burst = $time - t_burst;
		$display("   eight one at a time: %0t ps   eight queued: %0t ps", t_one, t_burst);
		ok(t_burst * 2 < t_one, "queued reads finish in under half the time");

		if (fails == 0) $display("tb_ddr3_mem: all checks passed");
		else            $display("tb_ddr3_mem: %0d FAIL(s)", fails);
		$finish;
	end

endmodule

`default_nettype wire
