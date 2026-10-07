`timescale 1ns/1ps
// tb_cd_feed: the ESP32 feeding the drive over SPI, end to end.
//
// The bench plays the ESP32 (an SPI master at 10 MHz, mode 0, chip select
// framing each command) and the CPU (register pokes as in tb_ps1_cd). It
// declares a disc, polls status, and delivers the sectors the drive asks for
// from the same pattern image tb_ps1_cd uses; the CPU seeks, reads, and checks
// the bytes that come out. A frame cut short must be dropped and not counted.
module tb_cd_feed;
	reg clk = 0; always #10 clk = ~clk;          // 50 MHz
	reg rst = 1;
	// --- the CPU side of the drive ---
	reg sel = 0, we = 0; reg [3:0] addr = 0, be = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; wire irq;
	wire [23:0] fill_lba; wire [3:0] fill_room; wire fill_run;
	wire disc_in, sb_we, sb_done; wire [11:0] sb_addr; wire [7:0] sb_data; wire [23:0] sb_lba;
	wire [31:0] dbg, sectors_in; wire [15:0] frames_short;
	// --- the SPI wires ---
	reg  sclk = 0, mosi = 0, cs_n = 1; wire miso;

	ps1_cdrom #(.ACK_CYCLES(200), .SECOND_CYCLES(400), .SEEK_CYCLES(3000), .SECTOR_1X(40000), .SECTOR_2X(20000)) drive (
		.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .irq(irq),
		.dma_rd(1'b0), .dma_rdata(), .dma_rvalid(),
		.disc_in(disc_in), .fill_lba(fill_lba), .fill_room(fill_room), .fill_run(fill_run),
		.sb_we(sb_we), .sb_addr(sb_addr), .sb_data(sb_data), .sb_done(sb_done), .sb_lba(sb_lba), .sb_abort(1'b0), .dbg(dbg),
		// every input added since tied, so none simulates as X
		.ev_v(1'b0), .ev_data(32'd0), .trace_idx(6'd0), .toc_we(1'b0), .toc_addr(8'd0), .toc_data(32'd0), .tick(1'b0),
		.xa_pop(1'b0), .xa_we(1'b0), .xa_wdata(32'd0));
	cd_feed feed (
		.clk(clk), .rst(rst), .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(miso), .spi_cs_n(cs_n),
		.fill_lba(fill_lba), .fill_room(fill_room), .fill_run(fill_run), .disc_in(disc_in),
		.sb_we(sb_we), .sb_addr(sb_addr), .sb_data(sb_data), .sb_done(sb_done), .sb_lba(sb_lba),
		.sectors_in(sectors_in), .frames_short(frames_short));

	integer errors = 0;
	task check; input c; input [8*72:1] m; begin if (c) $display("  ok   %0s", m); else begin errors = errors + 1; $display("  FAIL %0s", m); end end endtask

	// --- the SPI master: 10 MHz, mode 0 ------------------------------------------------
	task spi_byte; input [7:0] tx; output [7:0] rx; integer b; begin
		for (b = 7; b >= 0; b = b - 1) begin
			mosi = tx[b]; #62; sclk = 1; #3 rx[b] = miso; #63; sclk = 0;   // ~8 MHz, edges off the 50 MHz grid (a 10 MHz SPI on the clock grid races in simulation)
		end
	end endtask
	// one master at a time: the feeder loop and the test body both use the wire
	reg spi_busy = 0;
	task cs_lo; begin while (spi_busy) #100; spi_busy = 1; cs_n = 0; #200; end endtask
	task cs_hi; begin #200; cs_n = 1; #400; spi_busy = 0; end endtask
	reg [7:0] st [0:9];
	task cd_status; integer i; begin
		cs_lo; spi_byte(8'h30, st[0]); for (i = 1; i < 10; i = i + 1) spi_byte(8'h00, st[i]); cs_hi;
	end endtask
	task cd_disc; input v; reg [7:0] d; begin cs_lo; spi_byte(8'h32, d); spi_byte({7'd0, v}, d); cs_hi; end endtask
	function [7:0] img; input [23:0] lba; input [11:0] k; begin
		img = (k == 0 || k == 11) ? 8'h00 : (k < 11) ? 8'hFF :   // sync: a data sector (audio has none)
		      (k == 12) ? bcd(((lba + 150) / 75) / 60) : (k == 13) ? bcd(((lba + 150) / 75) % 60) : (k == 14) ? bcd((lba + 150) % 75) : (k == 15) ? 8'h02 :
		      (k >= 16 && k < 20) ? 8'h55 : (lba * 7 + k) & 8'hFF; end endfunction
	function [7:0] bcd; input [7:0] b; bcd = ((b / 8'd10) << 4) | (b % 8'd10); endfunction
	task cd_sector; input [23:0] lba; input integer nbytes; integer k; reg [7:0] d; begin
		cs_lo; spi_byte(8'h31, d); spi_byte(lba[23:16], d); spi_byte(lba[15:8], d); spi_byte(lba[7:0], d);
		for (k = 0; k < nbytes; k = k + 1) spi_byte(img(lba, k), d);
		cs_hi;
	end endtask
	// the ESP32's loop: poll, and feed while running
	reg feeding = 0; integer fed = 0;
	initial begin
		#5000;
		forever begin
			#2000;
			if (feeding) begin
				cd_status();
				if (st[5] && st[6] != 0) begin cd_sector({st[7], st[8], st[9]}, 2352); fed = fed + 1; end
			end
		end
	end

	// --- the CPU side (as tb_ps1_cd) ---
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
	reg [7:0] rsp [0:15]; integer nrsp;
	task wait_int; output [2:0] n; integer t; reg [7:0] v; begin
		t = 0; n = 0;
		while (n == 0 && t < 400000) begin @(negedge clk); t = t + 1; setidx(1); rd8(3, v); n = v[2:0]; end
		nrsp = 0; setidx(0); rd8(0, v);
		while (v[5] && nrsp < 16) begin rd8(1, rsp[nrsp]); nrsp = nrsp + 1; rd8(0, v); end
		setidx(1); wr8(3, 8'h07);
	end endtask

	reg [2:0] n; reg [7:0] v; integer i, bad;
	reg trace = 0;
	always @(posedge clk) if (trace && feed.frame_start) $display("      frame_start @%0t: fill_run=%0d room=%0d fill_lba=%0d seeking=%0d reading=%0d cmd_pend=%0d", $time, fill_run, fill_room, fill_lba, drive.seeking, drive.reading, drive.cmd_pend);
	always @(posedge clk) if (trace && feed.frame_end) $display("      frame_end   @%0t: cmd=%02x rn=%0d", $time, feed.cmd, feed.rn);
	initial begin
		repeat (4) @(negedge clk); rst = 0; repeat (4) @(negedge clk);
		setidx(1); wr8(2, 8'h1F);
		$display("--- the link ---");
		cd_status(); check(st[0] == 8'hA5 && st[2] == 8'h50, "status: signature and the PlayStation core id");
		$display("      status bytes: %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x  (feed.cmd=%02x rn=%0d)", st[0],st[1],st[2],st[3],st[4],st[5],st[6],st[7],st[8],st[9], feed.cmd, feed.rn);
		check(st[4] == 8'd0, "no disc until the ESP32 says so");
		// (one INT5 at once, stat|error and 80h not ready: as the drive answers and tb_ps1_cdrom checks)
		command(8'h1A); wait_int(n); check(n == 5 && rsp[0] == 8'h11 && rsp[1] == 8'h80, "GetID without a disc: INT5 11h 80h");
		cd_disc(1);
		cd_status(); check(st[4] == 8'd1, "the disc is in");
		$display("      status bytes: %02x %02x %02x %02x %02x  disc_in=%0d", st[0],st[1],st[2],st[3],st[4], disc_in);
		command(8'h1A); wait_int(n); wait_int(n); check(n == 2 && rsp[4] == "S", "GetID with the disc: licensed");
		$display("--- sectors over the wire ---");
		param(8'h80); command(8'h0E); wait_int(n);
		param(8'h00); param(8'h03); param(8'h10); command(8'h02); wait_int(n);    // 00:03:10 = LBA 85
		feeding = 1;
		command(8'h06); wait_int(n); check(n == 3, "ReadN: INT3");
		wait_int(n); check(n == 1, "ReadN: INT1, the first sector came over SPI");
		setidx(0); wr8(3, 8'h80);
		bad = 0;
		for (i = 0; i < 2048; i = i + 1) begin rd8(2, v); if (v != img(85, 24 + i)) begin if (bad < 3) $display("      byte %0d got %02x want %02x", i, v, img(85, 24 + i)); bad = bad + 1; end end
		check(bad == 0, "LBA 85 arrived intact");
		wait_int(n); check(n == 1, "INT1: the second");
		setidx(0); wr8(3, 8'h00); wr8(3, 8'h80);
		bad = 0;
		for (i = 0; i < 2048; i = i + 1) begin rd8(2, v); if (v != img(86, 24 + i)) bad = bad + 1; end
		check(bad == 0, "LBA 86 arrived intact");
		command(8'h09); wait_int(n); wait_int(n);
		feeding = 0; #20000;
		$display("--- a frame cut short ---");
		param(8'h00); param(8'h04); param(8'h00); command(8'h02); wait_int(n);    // 00:04:00 = LBA 150
		command(8'h06); wait_int(n);
		trace = 1; #3000; cd_status(); trace = 0;
		check({st[7], st[8], st[9]} == 24'd150 && st[6] != 0, "the drive asks for LBA 150");
		$display("      status: run=%0d room=%0d lba=%0d  drive: seeking=%0d reading=%0d r_cnt=%0d ld_cnt=%0d fill_lba=%0d", st[5], st[6], {st[7], st[8], st[9]}, drive.seeking, drive.reading, drive.r_cnt, drive.ld_cnt, fill_lba);
		bad = sectors_in;
		cd_sector(24'd150, 1000);                       // ...and the ESP32 gives up half way
		check(frames_short == 16'd1 && sectors_in == bad, "the short frame was dropped, not counted");
		cd_status(); check({st[7], st[8], st[9]} == 24'd150, "and LBA 150 is still the one wanted");
		cd_sector(24'd150, 2352);
		wait_int(n); check(n == 1, "INT1 after the full frame");
		setidx(0); wr8(3, 8'h00); wr8(3, 8'h80); rd8(2, v); check(v == img(150, 24), "and it is LBA 150's data");
		if (errors == 0) $display("tb_cd_feed: all checks passed"); else $display("tb_cd_feed: %0d FAIL(s)", errors);
		$finish;
	end
	initial begin #60_000_000; $display("FAIL: timeout"); $finish; end
endmodule
