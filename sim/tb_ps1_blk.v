`timescale 1ns/1ps
// tb_ps1_blk: the block writer. Pixels go in as words and lines, in scanline
// order and scattered; what reaches the (randomly stalling) memory must equal
// a reference image written the plain way, every byte, and only the bytes that
// were written may be touched.
module tb_ps1_blk;
	reg clk = 0; always #10 clk = ~clk;
	reg rst = 1;

	reg         w_req = 0;
	reg  [28:0] w_addr = 0;
	reg  [3:0]  w_be = 0;
	reg  [31:0] w_wdata = 0;
	reg         w_lwe = 0;
	reg  [127:0] w_wdata128 = 0;
	wire        w_ack;
	reg         flush = 0;
	wire        idle;
	wire [23:0] m_addr; wire m_req, m_we; wire [127:0] m_wdata; wire [15:0] m_wmask;
	reg         m_ready = 0;
	wire        inv_v; wire [24:0] inv_line;

	ps1_gpu_blk #(.QAW(2)) dut (
		.clk(clk), .rst(rst),
		.w_req(w_req), .w_addr(w_addr), .w_be(w_be), .w_wdata(w_wdata),
		.w_lwe(w_lwe), .w_wdata128(w_wdata128), .w_ack(w_ack), .flush(flush), .idle(idle),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask), .m_ready(m_ready),
		.inv_v(inv_v), .inv_line(inv_line));

	// memory: 64 KB, byte addressed; reference the same
	reg [7:0] mem [0:65535];
	reg [7:0] ref [0:65535];
	reg       touched [0:65535];
	integer i, n_lines = 0, n_inv = 0, errors = 0;
	initial for (i = 0; i < 65536; i = i + 1) begin mem[i] = 8'hA5; ref[i] = 8'hA5; touched[i] = 0; end

	// randomly stalling memory sink
	always @(posedge clk) begin
		m_ready <= ($random & 3) != 0;
		if (m_req && m_ready) begin
			if (!m_we) begin $display("FAIL: read from block writer"); errors = errors + 1; end
			for (i = 0; i < 16; i = i + 1)
				if (m_wmask[i]) begin
					mem[{m_addr[11:0], 4'd0} + i] = m_wdata[i*8 +: 8];
					touched[{m_addr[11:0], 4'd0} + i] = 1;
				end
			n_lines = n_lines + 1;
		end
		if (inv_v) n_inv = n_inv + 1;
	end

	reg done;
	task word(input [28:0] a, input [3:0] be, input [31:0] d);
		integer k;
		begin
			w_req = 1; w_addr = a; w_be = be; w_wdata = d; w_lwe = 0;
			done = 0;
			while (!done) begin @(negedge clk); done = w_ack; @(posedge clk); end
			#1 w_req = 0;
			for (k = 0; k < 4; k = k + 1) if (be[k]) ref[a[15:0] + k] = d[k*8 +: 8];
		end
	endtask
	task line(input [28:0] a, input [127:0] d);
		integer k;
		begin
			w_req = 1; w_addr = a; w_lwe = 1; w_wdata128 = d;
			done = 0;
			while (!done) begin @(negedge clk); done = w_ack; @(posedge clk); end
			#1 w_req = 0; w_lwe = 0;
			for (k = 0; k < 16; k = k + 1) ref[a[15:0] + k] = d[k*8 +: 8];
		end
	endtask
	task do_flush;
		begin
			flush = 1; @(posedge clk); #1 flush = 0;
			while (!idle) @(posedge clk);
			@(posedge clk);
		end
	endtask
	task check(input [255:0] what);
		integer k, bad;
		begin
			bad = 0;
			for (k = 0; k < 65536; k = k + 1) if (mem[k] !== ref[k]) bad = bad + 1;
			if (bad) begin $display("FAIL: %0s: %0d bytes differ", what, bad); errors = errors + 1; end
			else $display("ok: %0s (%0d line writes so far)", what, n_lines);
		end
	endtask

	integer x, y, r, l0;
	reg [15:0] px;
	initial begin
		repeat (3) @(posedge clk); #1 rst = 0; repeat (2) @(posedge clk);
		if (!idle) begin $display("FAIL: not idle after reset"); errors = errors + 1; end

		// 1. a flat span: 40 pixels from an odd pixel, word by word, with be
		for (x = 3; x < 43; x = x + 1) begin
			px = 16'h8000 | x;
			word({13'd0, 4'd2, x[9:1], 2'b00} & 29'h1FFF_FFFC, x[0] ? 4'b1100 : 4'b0011, x[0] ? {px, 16'h0} : {16'h0, px});
		end
		do_flush; check("flat span");
		// 3..42 -> bytes 6..85: blocks 0,1,2 -> lines: block0 both, block1 both, block2 low only (bytes 64..85 => 64..79 low, 80..85 high)
		if (n_lines != 6) begin $display("FAIL: flat span took %0d line writes, expected 6", n_lines); errors = errors + 1; end
		if (n_inv != n_lines) begin $display("FAIL: inv count %0d != lines %0d", n_inv, n_lines); errors = errors + 1; end
		for (i = 0; i < 6; i = i + 1) if (touched[i]) begin $display("FAIL: byte %0d written without a write", i); errors = errors + 1; end
		for (i = 86; i < 96; i = i + 1) if (touched[i]) begin $display("FAIL: byte %0d written without a write", i); errors = errors + 1; end

		// 2. whole lines, then a word patch over them, then lines in the other half
		l0 = n_lines;
		line(29'h1000, 128'h0011_2233_4455_6677_8899_AABB_CCDD_EEFF);
		line(29'h1010, 128'hFFEE_DDCC_BBAA_9988_7766_5544_3322_1100);
		word(29'h1004, 4'b1111, 32'hDEAD_BEEF);
		line(29'h1030, {8{16'h7C1F}});
		do_flush; check("lines + patch");
		if (n_lines - l0 != 3) begin $display("FAIL: lines+patch took %0d writes, expected 3", n_lines - l0); errors = errors + 1; end

		// 3. scattered writes (every one a new block) against a slow memory: queue fills, we must wait, nothing lost
		for (r = 0; r < 200; r = r + 1) begin
			x = ($random & 32'h7FF) << 5;
			word({14'd0, x[14:0]} + (($random & 7) << 2), 4'b1111, $random);
		end
		do_flush; check("scattered");

		// 4. a textured triangle-ish walk: rows of varying length, same y then next y, with holes (transparent pixels skipped)
		for (y = 0; y < 24; y = y + 1)
			for (x = y; x < 60 - y; x = x + 1) begin
				if (((x * 7 + y * 3) % 5) == 0) begin end   // hole
				else begin
					px = {1'b0, y[4:0], x[9:0]};
					word({13'd0, y[3:0] + 4'd4, x[9:1], 2'b00} & 29'h1FFF_FFFC, x[0] ? 4'b1100 : 4'b0011, x[0] ? {px, 16'h0} : {16'h0, px});
				end
			end
		do_flush; check("rows with holes");

		// 5. flush with nothing gathered is harmless; idle stays
		do_flush;
		if (!idle) begin $display("FAIL: not idle"); errors = errors + 1; end

		// 6. back-to-back: a write every clock into the same block never stalls
		l0 = 0;
		w_req = 1; w_lwe = 0; w_be = 4'b1111;
		for (x = 0; x < 8; x = x + 1) begin
			w_addr = 29'h4000 + x * 4; w_wdata = 32'h0100_0000 * x;
			for (i = 0; i < 4; i = i + 1) ref[16'h4000 + x*4 + i] = w_wdata[i*8 +: 8];
			@(posedge clk); if (!w_ack) l0 = l0 + 1; #1;
		end
		w_req = 0;
		if (l0) begin $display("FAIL: same-block writes stalled %0d times", l0); errors = errors + 1; end
		do_flush; check("same block, one a clock");

		if (errors == 0) $display("tb_ps1_blk: all checks passed (%0d line writes, %0d invalidates)", n_lines, n_inv);
		else $display("FAIL: tb_ps1_blk %0d errors", errors);
		$finish;
	end
	initial begin #2_000_000; $display("FAIL: timeout"); $finish; end
endmodule
