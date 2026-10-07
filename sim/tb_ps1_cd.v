`timescale 1ns/1ps
// tb_ps1_cd: the CD-ROM drive model against a feeder that plays the transport.
//
// The bench is the CPU (byte writes and reads of the four registers, as the
// BIOS makes them) and the ESP32 (sectors delivered on request from a pattern
// image where byte k of sector n is (n*7 + k) & 0xFF, with a real-looking
// header at bytes 12..19). It checks the responses and interrupts of the
// commands the BIOS and a game use, that the sector data comes out right via
// RDDATA and via the DMA word port, and the timing of INT1.
module tb_ps1_cd;
	reg clk = 0; always #10 clk = ~clk;
	reg rst = 1;
	reg        sel = 0, we = 0; reg [3:0] addr = 0, be = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; wire irq;
	reg        dma_rd = 0; wire [31:0] dma_rdata; wire dma_rvalid;
	wire [23:0] fill_lba; wire [3:0] fill_room; wire fill_run;
	reg        sb_we = 0; reg [11:0] sb_addr = 0; reg [7:0] sb_data = 0; reg sb_done = 0; reg [23:0] sb_lba = 0;
	wire [31:0] dbg;

	// short timings so the bench runs in seconds; the ratios are what matter
	ps1_cdrom #(.ACK_CYCLES(200), .SECOND_CYCLES(400), .SEEK_CYCLES(3000), .SECTOR_1X(24000), .SECTOR_2X(12000), .LAST_LBA(24'd268742)) dut (
		.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .irq(irq),
		.dma_rd(dma_rd), .dma_rdata(dma_rdata), .dma_rvalid(dma_rvalid),
		.disc_in(1'b1), .fill_lba(fill_lba), .fill_room(fill_room), .fill_run(fill_run),
		.sb_we(sb_we), .sb_addr(sb_addr), .sb_data(sb_data), .sb_done(sb_done), .sb_lba(sb_lba), .sb_abort(1'b0), .dbg(dbg),
		// every input added since tied, so none simulates as X (ev_v as X stopped the trace's
		// writes, and with them the drive's own block: the bench failed at its first sector)
		.ev_v(1'b0), .ev_data(32'd0), .trace_idx(6'd0), .toc_we(1'b0), .toc_addr(8'd0), .toc_data(32'd0), .tick(1'b0),
		.xa_pop(1'b0), .xa_we(1'b0), .xa_wdata(32'd0));

	integer errors = 0;
	task check; input c; input [8*72:1] m; begin if (c) $display("  ok   %0s", m); else begin errors = errors + 1; $display("  FAIL %0s", m); end end endtask

	// --- the CPU's register accesses (byte lanes of the one word) ---------------------
	task wr8; input [1:0] r; input [7:0] v; begin
		@(negedge clk); sel = 1; we = 1; addr = {2'd0, r}; be = 4'b0001 << r; wdata = {4{v}};
		@(negedge clk); sel = 0; we = 0; be = 0;
	end endtask
	task rd8; input [1:0] r; output [7:0] v; begin
		@(negedge clk); sel = 1; we = 0; addr = {2'd0, r}; be = 4'b0001 << r; #1 v = rdata[r*8 +: 8];
		@(negedge clk); sel = 0; be = 0;
	end endtask
	task setidx; input [1:0] i; begin wr8(0, {6'd0, i}); end endtask
	task param; input [7:0] v; begin setidx(0); wr8(2, v); end endtask
	task command; input [7:0] c; begin setidx(0); wr8(1, c); end endtask
	// wait for an interrupt, return its number, read the response bytes, acknowledge
	reg [7:0] rsp [0:15]; integer nrsp;
	task wait_int; output [2:0] n; integer t; reg [7:0] v; begin
		t = 0; n = 0;
		while (n == 0 && t < 200000) begin @(negedge clk); t = t + 1; setidx(1); rd8(3, v); n = v[2:0]; end
		nrsp = 0;
		setidx(0);
		rd8(0, v);
		while (v[5] && nrsp < 16) begin rd8(1, rsp[nrsp]); nrsp = nrsp + 1; rd8(0, v); end
		setidx(1); wr8(3, 8'h07);      // acknowledge
	end endtask

	// --- the image and the feeder ------------------------------------------------------
	function [7:0] bcd; input [7:0] b; bcd = ((b / 8'd10) << 4) | (b % 8'd10); endfunction
	function [7:0] img; input [23:0] lba; input [11:0] k; begin
		img = (k == 0 || k == 11) ? 8'h00 : (k < 11) ? 8'hFF :                                       // sync: a data sector (audio has none)
		      (k == 12) ? bcd(((lba + 150) / 75) / 60) : (k == 13) ? bcd(((lba + 150) / 75) % 60) : (k == 14) ? bcd((lba + 150) % 75) : (k == 15) ? 8'h02 :   // header: the sector's own MSF, mode 2
		      (k == 16) ? 8'h00 : (k == 17) ? 8'h00 : (k == 18) ? 8'h08 : (k == 19) ? 8'h00 :   // subheader: form 1
		      (lba * 7 + k) & 8'hFF; end endfunction
	integer fed = 0; reg feeding = 0;
	always @(posedge clk) if (feeding && fill_run && fill_room != 0 && !sb_we && !sb_done) begin
		deliver(fill_lba);
	end
	task deliver; input [23:0] lba; integer k; begin
		sb_lba <= lba; sb_we <= 1;
		for (k = 0; k < 2352; k = k + 1) begin sb_addr <= k; sb_data <= img(lba, k); @(posedge clk); end
		sb_we <= 0; sb_done <= 1; @(posedge clk); sb_done <= 0; fed = fed + 1;
		repeat (20) @(posedge clk);   // the SPI is slower than this; leave a gap
	end endtask

	reg [2:0] n; reg [7:0] v; integer i, bad, t0, t1;
	reg [31:0] w;
	initial begin
		repeat (4) @(negedge clk); rst = 0; repeat (4) @(negedge clk);
		setidx(1); wr8(2, 8'h1F);                       // HINTMSK: all
		$display("--- identity ---");
		command(8'h1A); wait_int(n); check(n == 3, "GetID: INT3 first");
		wait_int(n); check(n == 2 && nrsp == 8 && rsp[0] == 8'h02 && rsp[2] == 8'h20 && rsp[4] == "S" && rsp[7] == "A", "GetID: INT2 licensed SCEA disc");
		command(8'h13); wait_int(n); check(n == 3 && rsp[1] == 8'h01 && rsp[2] == 8'h01, "GetTN: one track");
		param(8'h00); command(8'h14); wait_int(n); check(n == 3 && rsp[1] == 8'h59 && rsp[2] == 8'h45, "GetTD(0): 59:45 (268743 sectors + lead-in)");
		param(8'h01); command(8'h14); wait_int(n); check(n == 3 && rsp[1] == 8'h00 && rsp[2] == 8'h02, "GetTD(1): 00:02");
		command(8'h0A); wait_int(n); check(n == 3, "Init: INT3"); wait_int(n); check(n == 2 && rsp[0] == 8'h02, "Init: INT2 motor on");
		param(8'h80); command(8'h0E); wait_int(n); check(n == 3, "Setmode 80h (double speed): INT3");
		$display("--- seek and read ---");
		feeding = 1;
		param(8'h00); param(8'h02); param(8'h16); command(8'h02); wait_int(n); check(n == 3, "Setloc 00:02:16 (LBA 16): INT3");
		command(8'h15); wait_int(n); check(n == 3 && (rsp[0] & 8'h40), "SeekL: INT3 with the seek bit");
		wait_int(n); check(n == 2 && !(rsp[0] & 8'h40), "SeekL: INT2 when there");
		check(fill_lba == 24'd16 || fed > 0, "the feeder was asked for LBA 16 onwards");
		command(8'h06); wait_int(n); check(n == 3 && (rsp[0] & 8'h20), "ReadN: INT3 with the read bit");
		t0 = $time; wait_int(n); check(n == 1, "ReadN: INT1, a sector"); t1 = $time;
		// the data, through RDDATA: 2048 bytes from offset 24 of LBA 16
		setidx(0); wr8(3, 8'h80);                       // want data
		rd8(0, v); check(v[6], "DRQSTS: data ready");
		bad = 0;
		for (i = 0; i < 2048; i = i + 1) begin rd8(2, v); if (v != img(16, 24 + i)) begin if (bad < 4) $display("      byte %0d: got %02x want %02x", i, v, img(16, 24 + i)); bad = bad + 1; end end
		check(bad == 0, "RDDATA: 2048 bytes of LBA 16 correct");
		rd8(0, v); check(!v[6], "DRQSTS clear after the last byte");
		wait_int(n); check(n == 1, "INT1: the next sector"); t0 = $time;
		wait_int(n); check(n == 1, "INT1: and the next"); t1 = $time;
		check((t1 - t0) > 12000 * 20 * 0.9 && (t1 - t0) < 12000 * 20 * 1.5, "sector period at double speed");
		// this one (LBA 18) through the DMA word port: sectors load in order, so
		// LBA 17 is loaded and dropped first (bit 7 cleared abandons it)
		setidx(0); wr8(3, 8'h80); wr8(3, 8'h00); wr8(3, 8'h80);
		bad = 0;
		for (i = 0; i < 512; i = i + 1) begin
			@(negedge clk); dma_rd = 1; @(negedge clk); dma_rd = 0;
			while (!dma_rvalid) @(negedge clk);
			w = {img(18, 24 + i*4 + 3), img(18, 24 + i*4 + 2), img(18, 24 + i*4 + 1), img(18, 24 + i*4)};
			if (dma_rdata !== w) begin if (bad < 3) $display("      word %0d: got %08x want %08x", i, dma_rdata, w); bad = bad + 1; end
		end
		check(bad == 0, "DMA: 512 words of LBA 18 correct");
		command(8'h11); wait_int(n); // (track, index, the time in the track, then on the disc: track 1 starts at 00:02:00)
		check(n == 3 && rsp[0] == 8'h01 && rsp[2] == 8'h00 && rsp[3] == 8'h00 && rsp[4] == 8'h19 && rsp[5] == 8'h00 && rsp[6] == 8'h02 && rsp[7] == 8'h19,
		      "GetlocP: track 1 00:00:19, disc 00:02:19 after three sectors");
		command(8'h10); wait_int(n); check(n == 3 && nrsp == 8 && rsp[3] == 8'h02 && rsp[6] == 8'h08, "GetlocL: the sector's header and subheader");
		command(8'h09); wait_int(n); check(n == 3, "Pause: INT3"); wait_int(n); check(n == 2, "Pause: INT2");
		repeat (20000) @(negedge clk);
		setidx(1); rd8(3, v); check(v[2:0] == 3'd0, "no INT1 after Pause");
		$display("--- whole sectors, seek by ReadN ---");
		param(8'hA0); command(8'h0E); wait_int(n);      // 2x, whole sector
		param(8'h00); param(8'h05); param(8'h00); command(8'h02); wait_int(n);   // 00:05:00 = LBA 225
		command(8'h06); wait_int(n); check(n == 3, "ReadN after Setloc: INT3");
		wait_int(n); check(n == 1, "ReadN after Setloc: INT1 (seek then read)");
		setidx(0); wr8(3, 8'h80);
		bad = 0;
		for (i = 0; i < 2340; i = i + 1) begin rd8(2, v); if (v != img(225, 12 + i)) bad = bad + 1; end
		check(bad == 0, "whole sector: 2340 bytes of LBA 225 from offset 12");
		command(8'h09); wait_int(n); wait_int(n);
		$display("--- the ring under a slow CPU ---");
		param(8'h80); command(8'h0E); wait_int(n);
		param(8'h00); param(8'h10); param(8'h00); command(8'h02); wait_int(n);
		command(8'h06); wait_int(n);
		repeat (240000) @(negedge clk);                 // ~20 sector periods without taking one
		check(fill_room == 4'd0 || fill_room == 4'd1, "the feeder was held once the ring filled");
		wait_int(n); check(n == 1, "INT1 still pending for the first sector");
		setidx(0); wr8(3, 8'h80); rd8(2, v); check(v == img(600, 24), "and it is LBA 600's data (00:10:00)");
		if (v != img(600, 24)) $display("      got %02x want %02x  dbg=%08x fill_lba=%0d room=%0d cur_slot=%0d fifo_slot=%0d bfrd=%0d fifo_rd=%0d", v, img(600, 24), dbg, fill_lba, fill_room, dut.cur_slot, dut.fifo_slot, dut.bfrd, dut.fifo_rd);
		command(8'h08); wait_int(n); while (n != 3) wait_int(n); wait_int(n); check(n == 2 && rsp[0] == 8'h00, "Stop: motor off");
		if (!(n == 2 && rsp[0] == 8'h00)) $display("      got INT%0d rsp0=%02x", n, rsp[0]);
		$display("--- libcd style: one sector, pause, next place ---");
		param(8'h80); command(8'h0E); wait_int(n);
		for (i = 0; i < 3; i = i + 1) begin
			// Setloc to LBA 18, 24, 25 as 00:02:18, 00:02:24, 00:02:25 (BCD)
			param(8'h00); param(8'h02); param((i == 0) ? 8'h18 : (i == 1) ? 8'h24 : 8'h25); command(8'h02); wait_int(n);
			param(8'h80); command(8'h0E); wait_int(n);
			command(8'h06); wait_int(n);
			wait_int(n); check(n == 1, "libcd: INT1");
			setidx(0); wr8(3, 8'h00); wr8(3, 8'h80);       // reset, then want data: as libcd does
			bad = 0;
			for (t0 = 0; t0 < 512; t0 = t0 + 1) begin
				@(negedge clk); dma_rd = 1; @(negedge clk); dma_rd = 0;
				while (!dma_rvalid) @(negedge clk);
				w = {img(18 + ((i == 0) ? 0 : (i == 1) ? 6 : 7), 24 + t0*4 + 3), img(18 + ((i == 0) ? 0 : (i == 1) ? 6 : 7), 24 + t0*4 + 2), img(18 + ((i == 0) ? 0 : (i == 1) ? 6 : 7), 24 + t0*4 + 1), img(18 + ((i == 0) ? 0 : (i == 1) ? 6 : 7), 24 + t0*4)};
				if (dma_rdata !== w) begin if (bad < 2) $display("      read %0d word %0d: got %08x want %08x", i, t0, dma_rdata, w); bad = bad + 1; end
			end
			check(bad == 0, "libcd: the sector asked for, via DMA");
			command(8'h09); wait_int(n); check(n == 3, "libcd: Pause INT3"); wait_int(n); check(n == 2, "libcd: Pause INT2");
		end
		// The BIOS reads a PS-X EXE's header, then Setloc(next)+ReadN for the rest; when the
		// transport is part way through that next sector as ReadN starts the ring again, the
		// frame must not be taken (its start went into another slot): Crash got its header
		// sector as its first 2048 bytes of code.
		$display("--- a frame in flight when ReadN starts the ring again ---");
		feeding = 0; repeat (3000) @(negedge clk);
		param(8'h00); param(8'h15); param(8'h25); command(8'h02); wait_int(n);   // 00:15:25 = LBA 1000
		command(8'h06); wait_int(n);
		while (!(fill_run && fill_lba == 24'd1000)) @(negedge clk);
		deliver(24'd1000);
		wait_int(n); check(n == 1, "restart: INT1 for LBA 1000");
		setidx(0); wr8(3, 8'h80); rd8(2, v); check(v == img(1000, 24), "restart: LBA 1000's data");
		param(8'h00); param(8'h15); param(8'h26); command(8'h02); wait_int(n);   // 00:15:26 = LBA 1001
		fork
			deliver(24'd1001);
			begin while (sb_addr != 12'd1800) @(negedge clk); command(8'h06); end   // (it acts 200 clocks on)
		join
		feeding = 1;
		wait_int(n); check(n == 3, "restart: ReadN INT3");
		wait_int(n); check(n == 1, "restart: INT1 after the seek");
		setidx(0); wr8(3, 8'h80);
		bad = 0;
		for (i = 0; i < 2048; i = i + 1) begin rd8(2, v); if (v != img(1001, 24 + i)) bad = bad + 1; end
		check(bad == 0, "restart: the sector is LBA 1001, not the slot's old contents");
		if (bad) $display("      %0d bytes wrong (LBA 1000's byte 24 is %02x, 1001's %02x)", bad, img(1000, 24), img(1001, 24));
		if (errors == 0) $display("tb_ps1_cd: all checks passed"); else $display("tb_ps1_cd: %0d FAIL(s)", errors);
		$finish;
	end
	initial begin #40_000_000; $display("FAIL: timeout"); $finish; end
endmodule
