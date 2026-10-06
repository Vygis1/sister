`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_shell - the golden image, driven the way an ESP32 will drive it.
//
// The testbench is the master and wiggles four pins at 10 MHz. Nothing reaches
// inside the shell to make it do things: if the ESP32 will have to send it, the
// bench sends it, because the interesting failures all live in the gap between
// "the logic is right" and "the protocol is right".
//
// Some of these checks are not about whether it works. They are about whether
// it can destroy the board. The flash holds the shell at $000000 and one core
// slot from $200000 up, and an offset is checked against the slot size before
// it is added to the slot base -- so the checks below fire offsets far outside
// the slot and confirm nothing below $200000 ever moves.
//////////////////////////////////////////////////////////////////////////////////

module tb_shell;

	reg clk = 0;
	always #10 clk = ~clk;                    // 50 MHz

	reg  sclk = 0, mosi = 0, cs_n = 1;
	wire miso;
	wire led0, led1;
	wire flash_cs_n, flash_mosi, flash_wp_n, flash_hold_n;
	wire flash_miso;

	// The shell now has two front doors. This bench drives the SPI one and
	// leaves Ethernet tied off -- the register path is exercised from the PC by
	// tools/shell.py against real hardware, where a PHY exists. What matters
	// here is that adding the second door did not change the first.
	wire [1:0] eth_txd;
	wire       eth_tx_en, eth_mdc;
	wire       eth_mdio;

	shell_top dut (
		.sys_clk(clk), .led0(led0), .led1(led1),
		.eth_refclk(clk), .eth_rxd(2'b00), .eth_crs_dv(1'b0),
		.eth_txd(eth_txd), .eth_tx_en(eth_tx_en),
		.eth_mdc(eth_mdc), .eth_mdio(eth_mdio),
		.esp_sclk(sclk), .esp_mosi(mosi), .esp_miso(miso), .esp_cs_n(cs_n),
		.flash_cs_n(flash_cs_n), .flash_mosi(flash_mosi),
		.flash_miso(flash_miso),
		.flash_wp_n(flash_wp_n), .flash_hold_n(flash_hold_n)
	);

	// The flash clock leaves the chip through STARTUPE2, which has no output
	// pin a testbench can reach, so the model is wired to the internal net. The
	// one signal in this bench that is not a real wire, and it is that way
	// because on silicon it is not a real wire either.
	spiflash_model #(.ADDR_BITS(23), .ERASE_NS(2000), .PROGRAM_NS(1000)) flash (
		.cs_n(flash_cs_n), .sclk(dut.flash_sck),
		.mosi(flash_mosi), .miso(flash_miso)
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

	// --- being the ESP32 ------------------------------------------------------
	localparam [7:0] CMD_PING  = 8'h01, CMD_STATUS = 8'h02,
	                 CMD_ERASE = 8'h10, CMD_WRITE  = 8'h11,
	                 CMD_READ  = 8'h12, CMD_PAGE   = 8'h13,
	                 CMD_BOOT  = 8'h20;

	reg [7:0] rx [0:511];
	integer   rxn;

	task spi_byte;                  // 10 MHz, mode 0
		input  [7:0] v;
		output [7:0] got;
		integer i;
		begin
			got = 8'd0;
			for (i = 7; i >= 0; i = i - 1) begin
				mosi = v[i];
				#50 sclk = 1;
				got = {got[6:0], miso};
				#50 sclk = 0;
			end
		end
	endtask

	task frame_open;  begin cs_n = 0; #200; rxn = 0; end endtask
	task frame_close; begin #200 cs_n = 1; #400; end endtask

	task send;
		input [7:0] v;
		reg   [7:0] g;
		begin
			spi_byte(v, g);
			rx[rxn] = g;
			rxn = rxn + 1;
		end
	endtask

	// --- waiting for the flash ------------------------------------------------
	// Exactly what the ESP32 does: ask, and keep asking. Nothing in this bench
	// looks at the busy flag inside the shell.
	integer polls;
	task wait_idle;
		begin
			polls = 0;
			begin : poll_loop
				forever begin
					frame_open;
					send(CMD_STATUS); send(8'h00); send(8'h00); send(8'h00);
					frame_close;
					polls = polls + 1;
					if (rx[3] == 8'h00) disable poll_loop;
					if (polls > 20000) begin
						$display("  FAIL the flash never stopped being busy");
						errors = errors + 1;
						disable poll_loop;
					end
				end
			end
		end
	endtask

	task unlock;                    // the frame an erase or a write must follow
		begin
			frame_open; send(8'h15); send(8'hC0); send(8'hDE); send(8'h5A); send(8'hFE); frame_close;
		end
	endtask

	task write_page;                // one page of the pattern below
		input [23:0] off;
		input [7:0]  seed;
		integer i;
		begin
			unlock;
			frame_open;
			send(CMD_WRITE);
			send(off[23:16]); send(off[15:8]); send(off[7:0]);
			for (i = 0; i < 256; i = i + 1) send(seed + i[7:0]);
			frame_close;
			wait_idle;
		end
	endtask

	task erase_sector_raw;          // the same, without the unlock
		input [23:0] off;
		begin
			frame_open;
			send(CMD_ERASE);
			send(off[23:16]); send(off[15:8]); send(off[7:0]);
			frame_close;
			wait_idle;
		end
	endtask

	task erase_sector;              // the 64 kB sector an offset falls in
		input [23:0] off;
		begin
			unlock;
			frame_open;
			send(CMD_ERASE);
			send(off[23:16]); send(off[15:8]); send(off[7:0]);
			frame_close;
			wait_idle;
		end
	endtask

	task read_page;                 // fetch, then dump: two commands, as designed
		input [23:0] off;
		begin
			frame_open;
			send(CMD_READ);
			send(off[23:16]); send(off[15:8]); send(off[7:0]);
			frame_close;
			wait_idle;

			frame_open;
			send(CMD_PAGE);
			begin : dump
				integer i;
				for (i = 0; i < 257; i = i + 1) send(8'h00);
			end
			frame_close;
		end
	endtask

	// --- watching the ICAP sequence -------------------------------------------
	reg [31:0] icap_seen [0:15];
	integer    icap_n = 0;
	always @(posedge clk) if (!dut.icap_csib && icap_n < 16) begin
		icap_seen[icap_n] = dut.icap_din;
		icap_n = icap_n + 1;
	end

	function [31:0] bitswap;
		input [31:0] v;
		integer b;
		begin
			for (b = 0; b < 8; b = b + 1) begin
				bitswap[b]      = v[7  - b];
				bitswap[8  + b] = v[15 - b];
				bitswap[16 + b] = v[23 - b];
				bitswap[24 + b] = v[31 - b];
			end
		end
	endfunction

	integer i, bad, badflash;

	initial begin
		$display("tb_shell");
		// The reset now runs for 65536 cycles, as it does in eth_top: long
		// enough for the PHY's clock and everything on it to settle.
		repeat (70000) @(posedge clk);

		// --- is anything there? ------------------------------------------------
		frame_open;
		send(CMD_PING); send(8'h00); send(8'h00); send(8'h00);
		frame_close;
		$display("    PING -> %02x %02x %02x %02x", rx[0], rx[1], rx[2], rx[3]);
		check(rx[0] == 8'hA5, "the first byte back is the signature");
		check(rx[1] == 8'd2,  "then the protocol version (2: the menu)");
		check(rx[2] == 8'd0,  "and core 0, which is the shell");

		// --- put a page in the core slot and read it back ----------------------
		// Writes are slot-relative and reads are absolute, so the same page is
		// named two different ways here. That asymmetry is deliberate -- a write
		// must not be able to reach the shell and a read has nothing to damage
		// -- and writing it out explicitly is how it stays understood.
		write_page(24'h000000, 8'h10);      // slot + 0
		read_page (24'h200000);             // which is flash $200000
		bad = 0;
		for (i = 0; i < 256; i = i + 1)
			if (rx[i + 2] !== 8'h10 + i[7:0]) begin
				if (bad < 6)
					$display("    read  byte %0d: got %02x want %02x",
					         i, rx[i + 2], 8'h10 + i[7:0]);
				bad = bad + 1;
			end
		$display("    read back: %0d of 256 bytes wrong", bad);
		check(bad == 0, "a page written to the slot reads back byte for byte");

		// Separately: is the flash itself right? That splits a bad write from a
		// bad read-back, which have nothing to do with each other -- and using
		// one variable for both, as an earlier version of this did, means only
		// the second one is ever actually checked.
		badflash = 0;
		for (i = 0; i < 256; i = i + 1)
			if (flash.mem[24'h200000 + i] !== 8'h10 + i[7:0]) begin
				if (badflash < 6)
					$display("    flash byte %0d: got %02x want %02x",
					         i, flash.mem[24'h200000 + i], 8'h10 + i[7:0]);
				badflash = badflash + 1;
			end
		$display("    in the flash: %0d of 256 bytes wrong", badflash);
		check(badflash == 0, "and the flash itself holds those same bytes");
		check(flash.mem[24'h200000] === 8'h10,
		      "at $200000, where the core slot starts");

		// --- a second page, a long way in ---------------------------------------
		// Five megabytes up, which needs all 23 bits of the offset. A narrower
		// field would fold this back somewhere near the bottom of the slot and
		// the read would still succeed, which is why the check is against the
		// flash array and not just the round trip.
		write_page(24'h500000, 8'h80);      // slot + 5 MB
		read_page (24'h700000);             // which is flash $700000
		bad = 0;
		for (i = 0; i < 256; i = i + 1)
			if (rx[i + 2] !== 8'h80 + i[7:0]) bad = bad + 1;
		check(bad == 0, "so does one five megabytes into the slot");
		check(flash.mem[24'h700000] === 8'h80,
		      "at $700000, which is the slot base plus the offset");

		// --- THE GUARD: it must not be able to overwrite itself -----------------
		// An offset larger than the slot. Refused outright rather than clamped:
		// clamping would write SOMEWHERE, and a write nobody asked for is worse
		// than a command that did nothing.
		$display(" the shell protecting itself:");
		write_page(24'hFFFF00, 8'h5A);
		check(flash.mem[24'h000000] === 8'hFF,
		      "an offset larger than the flash cannot reach address zero");
		check(flash.mem[24'h1FFF00] === 8'hFF,
		      "nor anything else below the slot");
		check(flash.mem[24'h200000] === 8'h10,
		      "and it did not land at the bottom of the slot either");
		// Reads are absolute and unguarded on purpose: a read cannot damage
		// anything, and being able to look at the shell's own image is the only
		// independent check that what was written is what is there.
		read_page(24'h000000);
		check(rx[0] == 8'hA5, "a read below the slot is allowed, and answers");

		// $600000 is one byte past the end of the slot: the first offset that
		// must be refused, which is the one an off-by-one would let through.
		write_page(24'h600000, 8'hC3);
		check(flash.mem[24'h200000] === 8'h10,
		      "the first offset past the end of the slot is refused too");

		// --- erase --------------------------------------------------------------
		// Erase is one sector, and the caller erases only what it is about to
		// write. Two sectors here: the one holding the first page and the one
		// five megabytes up, which between them prove the address arithmetic at
		// both ends of the slot.
		$display(" erase:");
		erase_sector(24'h000000);
		check(flash.mem[24'h200000] === 8'hFF, "erasing a sector clears it");
		check(flash.mem[24'h20FFFF] === 8'hFF, "all 64 kB of it");
		check(flash.mem[24'h700000] === 8'h80, "and leaves the far page alone");

		erase_sector(24'h500000);
		check(flash.mem[24'h700000] === 8'hFF, "erasing the far sector clears it");

		check(flash.mem[24'h000000] === 8'hFF, "the shell is untouched throughout");
		check(flash.mem[24'h1FFFFF] === 8'hFF, "right up to its last byte");

		// An erase aimed past the end of the slot must do nothing at all.
		write_page(24'h000000, 8'h10);
		erase_sector(24'h600000);
		check(flash.mem[24'h200000] === 8'h10,
		      "an erase past the end of the slot is refused");

		// --- the menu's door: esp_bus on the same wires --------------------------
		$display(" the menu's bus:");
		frame_open; send(CMD_STATUS); send(8'h00); send(8'h00); send(8'h00); frame_close;
		check(rx[0] === 8'hA5 && rx[1] === 8'd2 && rx[2] === 8'd0, "status: the shell, version 2 (it can draw the menu)");
		// write pad 1 (0x00080008), then read it back
		frame_open; send(8'h40); send(8'h00); send(8'h08); send(8'h00); send(8'h08);
		send(8'h34); send(8'h12); send(8'h00); send(8'h00); frame_close;
		frame_open; send(8'h41); send(8'h00); send(8'h08); send(8'h00); send(8'h08);
		repeat (8) send(8'h00); frame_close;
		check({rx[12], rx[11], rx[10], rx[9]} === 32'h0000_1234, "the pad register reads back what was written");
		// a cell of the menu's text (0x00072000: row 0, column 0), and the OSD's signature
		frame_open; send(8'h40); send(8'h00); send(8'h07); send(8'h20); send(8'h00);
		send(8'h41); send(8'h00); send(8'h00); send(8'h00); frame_close;
		repeat (20) @(posedge clk);
		check(dut.u_screen.u_osd.cells[0] === 12'h041, "the menu's write lands in the OSD's cells");
		check(dut.u_screen.ext_own === 1'b1, "and the menu has the screen");
		frame_open; send(8'h41); send(8'h00); send(8'h07); send(8'h00); send(8'h00);
		repeat (8) send(8'h00); frame_close;
		check({rx[12], rx[11], rx[10], rx[9]} === 32'h4F53_4432, "the OSD's page reads OSD2");

		// --- the guards: no erase without the unlock, no flash from the bus door -----
		$display(" the guards:");
		write_page(24'h000000, 8'h10);
		erase_sector_raw(24'h000000);
		check(flash.mem[24'h200000] === 8'h10, "an erase without the unlock frame is refused");
		frame_open; send(8'h40); send(8'h00); send(8'h00); send(8'h00); send(8'h10);
		send(8'h01); send(8'h00); send(8'h00); send(8'h00); frame_close;     // op 1 (erase), offset 0
		wait_idle;
		check(flash.mem[24'h200000] === 8'h10, "the bus door cannot start the flash engine");
		erase_sector(24'h000000);
		check(flash.mem[24'h200000] === 8'hFF, "with the unlock it erases");

		// --- boot ---------------------------------------------------------------
		// No reply is possible: on real silicon the chip stops being the thing
		// that was listening. What can be checked is that the exact sequence
		// went into the primitive, with the slot address in the right word.
		$display(" boot:");
		frame_open;
		send(CMD_BOOT); send(8'h01);          // 1 = the core
		frame_close;
		repeat (40) @(posedge clk);

		$display("    ICAP got %0d words", icap_n);
		check(icap_n >= 7, "the reconfiguration sequence was issued");
		check(icap_seen[1] === bitswap(32'hAA995566), "word 1 is the sync word");
		check(icap_seen[3] === bitswap(32'h30020001), "word 3 writes WBSTAR");
		check(icap_seen[4] === bitswap(32'h00200000),
		      "word 4 is $200000, which is where the core starts");
		check(icap_seen[5] === bitswap(32'h30008001), "word 5 writes CMD");
		check(icap_seen[6] === bitswap(32'h0000000F), "word 6 is IPROG");

		// --- the pins that are easy to get wrong ---------------------------------
		check(flash_wp_n === 1'b1 && flash_hold_n === 1'b1,
		      "write-protect and hold are driven high, not left to a pulldown");

		$display("");
		if (errors == 0) $display("tb_shell: all checks passed");
		else             $display("tb_shell: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (200_000_000) @(posedge clk);
		$display("tb_shell: FAIL timeout");
		$finish;
	end

endmodule
