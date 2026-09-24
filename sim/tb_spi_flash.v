`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_spi_flash - the flash writer, against a flash chip.
//
// This controller has never run. It synthesises cleanly, which means nothing:
// the first time it does anything real it will be rewriting the flash the board
// boots from, and the failure mode is a board that stops booting.
//
// So every claim it makes gets checked here, in the order the shell will make
// them, and the checks are chosen to fail if the controller has any of the four
// mistakes that are easy to make against this part:
//
//   - forgetting WRITE ENABLE, or issuing it without letting chip select rise
//   - not waiting for the chip to finish before starting the next thing
//   - programming without erasing, which cannot set a bit back to one
//   - getting the byte order or the page wrap wrong
//   - assuming the chip is in single-bit mode when nothing put it there
//////////////////////////////////////////////////////////////////////////////////

module tb_spi_flash;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz

	reg  [1:0]  cmd   = 2'd0;
	reg         start = 1'b0;
	reg  [23:0] addr  = 24'd0;
	wire        busy;

	reg  [5:0]  buf_windex = 6'd0;
	reg         buf_we     = 1'b0;
	reg  [31:0] buf_wdata  = 32'd0;
	wire [31:0] buf_rdata;

	wire cs_n, mosi, sclk, miso;

	localparam CMD_ID = 2'd0,
	           CMD_ERASE = 2'd1, CMD_PROGRAM = 2'd2, CMD_READ = 2'd3;

	spi_flash dut (
		.clk(clk), .rst(rst),
		.cmd(cmd), .start(start), .addr(addr), .busy(busy),
		.buf_windex(buf_windex), .buf_we(buf_we),
		.buf_wdata(buf_wdata), .buf_rdata(buf_rdata),
		.spi_cs_n(cs_n), .spi_mosi(mosi), .spi_miso(miso), .spi_clk(sclk)
	);

	// A small array: the whole 8 Mbyte is not needed to prove the protocol, and
	// 128 kB keeps the simulation quick. Two sectors, which is one more than the
	// test touches -- so "did the erase stop at the sector boundary" is a
	// question that can be asked.
	// CONFUSED: the chip starts in a mode where it does not understand a single
	// thing said to it, which is how a real one is frequently found. Every check
	// below therefore also proves the controller got it back into its senses
	// first -- and if it ever stops doing that, all of them fail at once.
	spiflash_model #(.ADDR_BITS(17), .ERASE_NS(20000), .PROGRAM_NS(2000),
	                 .CONFUSED(1)) flash (
		.cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(miso)
	);

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	task go;
		input [1:0]  c;
		input [23:0] a;
		begin
			// Wait until it can accept one. The controller comes out of reset
			// BUSY -- it spends the first sixteen microseconds waking the
			// configuration clock up -- and a command issued during that is
			// dropped on the floor, exactly as one issued during any other
			// operation would be.
			while (busy) @(negedge clk);
			@(negedge clk);
			cmd = c; addr = a; start = 1'b1;
			@(negedge clk);
			start = 1'b0;
			// busy goes up a cycle later; wait for it to appear and then clear.
			while (!busy) @(negedge clk);
			while (busy)  @(negedge clk);
		end
	endtask

	task fill;                      // load the page buffer with a word each
		input [31:0] seed;
		integer k;
		begin
			for (k = 0; k < 64; k = k + 1) begin
				@(negedge clk);
				buf_windex = k[5:0]; buf_wdata = seed + k; buf_we = 1'b1;
			end
			@(negedge clk);
			buf_we = 1'b0;
		end
	endtask

	function [31:0] want_word;      // what fill() should have put at word k
		input integer k;
		begin want_word = 32'hA5000000 + k; end
	endfunction

	integer i, bad;
	reg [31:0] got;

	initial begin
		$display("tb_spi_flash");
		repeat (10) @(posedge clk);
		rst = 0;
		repeat (10) @(posedge clk);

		// --- who is out there? --------------------------------------------------
		// First, because it is the only question whose answer an absent chip
		// cannot fake: an erased flash and a missing one both read as $FF.
		go(CMD_ID, 24'h000000);
		@(negedge clk); buf_windex = 6'd0;
		@(negedge clk);
		$display("    chip id: %02x %02x %02x",
		         buf_rdata[7:0], buf_rdata[15:8], buf_rdata[23:16]);
		check(buf_rdata[23:0] === 24'h17BA20, "the chip identifies itself");

		// --- the chip answers at all -------------------------------------------
		// Read a page of a fresh part. Everything should be $FF, and if the
		// controller cannot read it cannot verify either.
		go(CMD_READ, 24'h000000);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== 32'hFFFFFFFF) bad = bad + 1;
		end
		$display("    an erased page read back %0d words that were not $FF", bad);
		check(bad == 0, "a fresh part reads as all ones");

		// --- program a page ----------------------------------------------------
		fill(32'hA5000000);
		go(CMD_PROGRAM, 24'h000100);          // page 1, not page 0

		go(CMD_READ, 24'h000100);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			got = buf_rdata;
			if (got !== want_word(i)) begin
				if (bad < 4)
					$display("    word %0d: got %08x want %08x",
					         i, got, want_word(i));
				bad = bad + 1;
			end
		end
		$display("    %0d of 64 words came back wrong", bad);
		check(bad == 0, "a programmed page reads back exactly what was written");

		// --- it went where it was told -----------------------------------------
		// The page above it must be untouched. If the address bytes were sent in
		// the wrong order this is where it shows.
		go(CMD_READ, 24'h000200);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== 32'hFFFFFFFF) bad = bad + 1;
		end
		check(bad == 0, "the next page along was not touched");

		go(CMD_READ, 24'h000000);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== 32'hFFFFFFFF) bad = bad + 1;
		end
		check(bad == 0, "and neither was the page below it");

		// --- flash can only clear bits -----------------------------------------
		// Program all-ones over what is already there. Nothing may change. If
		// this "works" the model is wrong; if the controller skipped the erase
		// on the real part, this is the shape of the corruption that follows.
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk);
			buf_windex = i[5:0]; buf_wdata = 32'hFFFFFFFF; buf_we = 1'b1;
		end
		@(negedge clk); buf_we = 1'b0;
		go(CMD_PROGRAM, 24'h000100);

		go(CMD_READ, 24'h000100);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== want_word(i)) bad = bad + 1;
		end
		check(bad == 0, "writing ones over data changes nothing, as on real flash");

		// --- erase -------------------------------------------------------------
		go(CMD_ERASE, 24'h000000);
		go(CMD_READ, 24'h000100);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== 32'hFFFFFFFF) bad = bad + 1;
		end
		check(bad == 0, "erasing the sector puts it back to all ones");

		// --- and the sector next door survived it ------------------------------
		// Written AFTER the erase so it is proof about the second erase, not a
		// leftover. Sector 1 starts at $10000 on this 128 kB model.
		fill(32'hA5000000);
		go(CMD_PROGRAM, 24'h010000);
		go(CMD_ERASE,   24'h000000);
		go(CMD_READ,    24'h010000);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== want_word(i)) bad = bad + 1;
		end
		check(bad == 0, "erasing one sector leaves the next one alone");

		// --- program a second time after erasing -------------------------------
		// The write enable latch clears itself after every operation. A
		// controller that issued WREN once would get exactly this far and then
		// silently stop writing.
		fill(32'hA5000000);
		go(CMD_PROGRAM, 24'h000400);
		go(CMD_READ,    24'h000400);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== want_word(i)) bad = bad + 1;
		end
		check(bad == 0, "a later write still works, so write-enable is per operation");

		// --- an address that is not a page boundary ----------------------------
		// A page program wraps within its own page: ask for $480 and the last
		// 64 words land back at $400, not in the page above. The controller
		// masks the low byte off so this cannot happen by accident -- the check
		// is that it does, because the alternative is silent corruption of a
		// page nobody meant to touch.
		go(CMD_ERASE, 24'h000000);
		fill(32'hA5000000);
		go(CMD_PROGRAM, 24'h000480);          // deliberately mid-page
		go(CMD_READ,    24'h000400);
		bad = 0;
		for (i = 0; i < 64; i = i + 1) begin
			@(negedge clk); buf_windex = i[5:0];
			@(negedge clk);
			if (buf_rdata !== want_word(i)) bad = bad + 1;
		end
		check(bad == 0, "a mid-page address is rounded down, not wrapped around");

		$display("");
		if (errors == 0) $display("tb_spi_flash: all checks passed");
		else             $display("tb_spi_flash: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (50_000_000) @(posedge clk);
		$display("tb_spi_flash: FAIL timeout (state %0d, busy %b)", dut.st, busy);
		$finish;
	end

endmodule
