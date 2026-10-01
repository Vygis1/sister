//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_cdaudio - CD audio in ps1_cdrom.v: the table of contents, Play and its
// PCM, report mode, GetlocP, Mute, the volume matrix, auto-pause, and XA-ADPCM
// routing with the filter, the queue for the PC and the FIFO of its samples.
//
// The disc: track 1 data from LBA 0, track 2 audio from 1000, track 3 audio from
// 1004, the lead-out at 1010. A transport model serves every sector the drive
// asks for: audio sectors are PCM whose every sample is a known function of its
// LBA and position, data sectors carry a real header and subheader, and LBAs
// 500.. are Mode 2 with XA audio interleaved (file 1 channel 2, file 1 channel 3)
// between data sectors.
//
//   ./tools/sim.sh tb_ps1_cdaudio
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none
module tb_ps1_cdaudio;
	reg clk = 0; always #5 clk = ~clk;
	reg rst = 1;
	reg sel = 0, we = 0; reg [3:0] addr = 0, be = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; wire irq;
	// the transport
	wire [23:0] fill_lba; wire [3:0] fill_room; wire fill_run;
	reg  sb_we = 0, sb_done = 0; reg [11:0] sb_addr = 0; reg [7:0] sb_data = 0; reg [23:0] sb_lba = 0;
	// the TOC, the audio, XA
	reg  toc_we = 0; reg [7:0] toc_addr = 0; reg [31:0] toc_data = 0;
	reg  tick = 0;
	wire signed [15:0] cd_l, cd_r;
	wire [23:0] xa_lba; wire [4:0] xa_count; wire [12:0] xa_level; wire [7:0] xa_gen;
	reg  xa_pop = 0, xa_we = 0; reg [31:0] xa_wdata = 0;

	ps1_cdrom #(.ACK_CYCLES(200), .SECOND_CYCLES(400), .SEEK_CYCLES(500), .SECTOR_1X(4000), .SECTOR_2X(2000)) dut (
		.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .irq(irq),
		.dma_rd(1'b0), .dma_rdata(), .dma_rvalid(),
		.disc_in(1'b1), .fill_lba(fill_lba), .fill_room(fill_room), .fill_run(fill_run),
		.sb_we(sb_we), .sb_addr(sb_addr), .sb_data(sb_data), .sb_done(sb_done), .sb_lba(sb_lba), .sb_abort(1'b0),
		.ev_v(1'b0), .ev_data(32'd0), .trace_idx(6'd0),
		.toc_we(toc_we), .toc_addr(toc_addr), .toc_data(toc_data),
		.tick(tick), .cd_l(cd_l), .cd_r(cd_r),
		.xa_lba(xa_lba), .xa_count(xa_count), .xa_pop(xa_pop), .xa_we(xa_we), .xa_wdata(xa_wdata),
		.xa_level(xa_level), .xa_gen(xa_gen), .xa_filt());

	// --- the sample clock: a tick every 64 clocks ----------------------------------------
	integer tdiv = 0;
	always @(posedge clk) begin tick <= (tdiv == 63); tdiv <= (tdiv == 63) ? 0 : tdiv + 1; end

	// --- the disc --------------------------------------------------------------------------
	function [15:0] pcm; input integer lba, n, ch;    // never zero, so silence is told apart
		pcm = ((lba * 589 + n * 37 + ch * 1013) & 16'hFFFF) | 16'h0001;
	endfunction
	function [7:0] bcd; input integer v; bcd = ((v / 10) << 4) | (v % 10); endfunction
	function is_audio; input integer lba; is_audio = (lba >= 1000); endfunction
	// LBAs 500..: XA interleave. 4k: audio file 1 ch 2; 4k+1: audio file 1 ch 3; else data
	function [7:0] submode; input integer lba;
		submode = (lba >= 500 && lba < 600 && lba % 4 == 0) ? 8'h64
		        : (lba >= 500 && lba < 600 && lba % 4 == 1) ? 8'h64 : 8'h08;
	endfunction
	function [7:0] channel; input integer lba;
		channel = (lba >= 500 && lba < 600 && lba % 4 == 1) ? 8'd3 : 8'd2;
	endfunction
	function [7:0] sector_byte; input integer lba, i; integer a;
		begin
			if (is_audio(lba)) begin
				sector_byte = (i % 2 == 0) ? pcm(lba, i / 4, (i / 2) % 2) : (pcm(lba, i / 4, (i / 2) % 2) >> 8);
			end else begin
				a = lba + 150;
				if (i == 0 || i == 11) sector_byte = 8'h00;
				else if (i < 11) sector_byte = 8'hFF;
				else if (i == 12) sector_byte = bcd(a / 4500);
				else if (i == 13) sector_byte = bcd((a / 75) % 60);
				else if (i == 14) sector_byte = bcd(a % 75);
				else if (i == 15) sector_byte = 8'h02;
				else if (i == 16 || i == 20) sector_byte = 8'h01;              // file
				else if (i == 17 || i == 21) sector_byte = channel(lba);
				else if (i == 18 || i == 22) sector_byte = submode(lba);
				else if (i == 19 || i == 23) sector_byte = 8'h00;              // coding
				else sector_byte = lba + i;
			end
		end
	endfunction
	// the transport serves whatever the drive asks for, a byte a clock
	integer fi, flba;
	initial begin
		forever begin
			@(negedge clk);
			if (!rst && fill_run && fill_room != 4'd0) begin
				flba = fill_lba;
				for (fi = 0; fi < 2352; fi = fi + 1) begin
					sb_we = 1; sb_addr = fi; sb_data = sector_byte(flba, fi); @(negedge clk);
				end
				sb_we = 0; sb_done = 1; sb_lba = flba; @(negedge clk); sb_done = 0;
			end
		end
	end

	// --- the register face (as tb_ps1_cdrom) ------------------------------------------------
	integer errors = 0;
	task wr8; input [1:0] a; input [7:0] v; begin
		@(negedge clk); sel = 1; we = 1; addr = a; be = 4'b0001 << a; wdata = {4{v}}; @(negedge clk); sel = 0; we = 0;
	end endtask
	task rd8; input [1:0] a; output [7:0] v; begin
		@(negedge clk); sel = 1; we = 0; addr = a; be = 4'b0001 << a; #1 v = rdata[a*8 +: 8]; @(negedge clk); sel = 0;
	end endtask
	task check; input c; input [8*48-1:0] what; begin
		if (!c) begin errors = errors + 1; if (errors < 30) $display("  FAIL %0s", what); end
	end endtask
	reg [7:0] v, r [0:7]; integer n, k, got;
	task wait_irq; begin n = 0; while (!irq && n < 400000) begin @(negedge clk); n = n + 1; end
		if (!irq) begin $display("  FAIL: no IRQ"); errors = errors + 1; end end endtask
	// one interrupt: its number, and up to eight response bytes; then acknowledge
	task take_int; output [2:0] num; input integer nb; begin
		wait_irq; wr8(0, 1); rd8(3, v); num = v[2:0];
		for (k = 0; k < nb; k = k + 1) begin rd8(1, v); r[k] = v; end
		wr8(3, 8'h07); wr8(0, 0);
	end endtask
	reg [2:0] inum;
	task command; input [7:0] c; input integer np; input [7:0] p0, p1, p2; input integer nresp; begin
		wr8(0, 0);
		if (np > 0) wr8(2, p0); if (np > 1) wr8(2, p1); if (np > 2) wr8(2, p2);
		wr8(1, c);
		take_int(inum, nresp);
	end endtask
	task toc; input [7:0] a; input [31:0] d; begin
		@(negedge clk); toc_we = 1; toc_addr = a; toc_data = d; @(negedge clk); toc_we = 0;
	end endtask
	// the sample a tick produced: cd_l/cd_r settle well before the next tick
	reg signed [15:0] sl, sr;
	task sample; begin @(posedge tick); repeat (40) @(posedge clk); sl = cd_l; sr = cd_r; end endtask
	task volume; input [7:0] ll, lr, rr, rl; begin
		wr8(0, 2); wr8(2, ll); wr8(3, lr); wr8(0, 3); wr8(1, rr); wr8(2, rl); wr8(3, 8'h20); wr8(0, 0);
	end endtask

	integer s0, i, lba0, idx0, nint1, nrep, reports;
	reg [15:0] el, er;
	initial begin
		#100 rst = 0; #50;
		wr8(0, 1); wr8(2, 8'h1F); wr8(3, 8'h1F); wr8(0, 0);
		// the disc: 1 data at 0, 2 audio at 1000, 3 audio at 1004, lead-out 1010
		toc(8'h01, 32'd0); toc(8'h02, {7'd0, 1'b1, 24'd1000}); toc(8'h03, {7'd0, 1'b1, 24'd1004}); toc(8'h00, 32'd1010);
		toc(8'h81, {19'd0, 7'd0, 6'd2}); toc(8'h82, {19'd0, 7'd0, 6'd15}); toc(8'h83, {19'd0, 7'd0, 6'd15});
		toc(8'h80, {19'd0, 7'd0, 6'd15}); toc(8'hFF, {17'd0, 7'd1, 1'b0, 7'd3});

		// ---- the table of contents ----
		command(8'h13, 0, 0, 0, 0, 3);
		check(inum == 3 && r[1] == 8'h01 && r[2] == 8'h03, "GetTN: tracks 1..3");
		command(8'h14, 1, 8'h02, 0, 0, 3);
		check(inum == 3 && r[1] == 8'h00 && r[2] == 8'h15, "GetTD(2): 00:15");
		command(8'h14, 1, 8'h04, 0, 0, 2);
		check(inum == 5 && r[1] == 8'h10, "GetTD(4): no such track, INT5 10h");

		// ---- Play(2), with report mode: the PCM, a report, GetlocP ----
		command(8'h0E, 1, 8'h04, 0, 0, 1);                       // Setmode: report
		command(8'h03, 1, 8'h02, 0, 0, 1);
		check(inum == 3 && r[0] == 8'h82, "Play: INT3, stat playing");
		// the first sample that is not silence must be track 2's first, and every
		// one after it the next, across a sector boundary
		got = 0;
		for (i = 0; i < 4000 && !got; i = i + 1) begin sample; if (sl != 0) got = 1; end
		check(got, "Play: sound starts");
		check(sl == pcm(1000, 0, 0) && sr == pcm(1000, 0, 1), "Play: the first sample is LBA 1000's first");
		for (i = 1; i < 700; i = i + 1) begin
			sample;
			el = pcm(1000 + i / 588, i % 588, 0); er = pcm(1000 + i / 588, i % 588, 1);
			if (sl !== el || sr !== er) begin
				if (errors < 30) $display("  FAIL Play sample %0d: %04h %04h, want %04h %04h", i, sl, sr, el, er);
				errors = errors + 1;
			end
		end
		// a report comes as INT1 with the track and a position
		take_int(inum, 8);
		check(inum == 1 && r[1] == 8'h02 && r[2] == 8'h01, "report: INT1, track 02, index 01");
		command(8'h11, 0, 0, 0, 0, 8);                           // GetlocP
		check(inum == 3 && r[0] == 8'h02 && r[1] == 8'h01 && r[5] == 8'h00 && r[6] == 8'h15, "GetlocP: track 02, index 01, abs 00:15");
		check(r[2] == 8'h00 && r[3] == 8'h00 && r[4] != 8'h00 && r[4] < 8'h05, "GetlocP: a few frames into the track");

		// ---- Mute, Demute, the volume matrix ----
		command(8'h0B, 0, 0, 0, 0, 1);
		repeat (3) sample;
		check(sl == 0 && sr == 0, "Mute: silence");
		command(8'h0C, 0, 0, 0, 0, 1);
		volume(8'h40, 8'h00, 8'h80, 8'h00);                    // left at half
		repeat (3) sample;
		check(sl != 0, "Demute: sound again");
		check(sl == (dut.mx_l >>> 1) && sr == dut.mx_r, "matrix: left at half, right whole");
		volume(8'h00, 8'h80, 8'h80, 8'h00);                    // L->R and R->R: everything right, nothing left
		repeat (3) sample;
		check(sl == 0 && sr != 0, "matrix: L->R and R->R only");
		volume(8'h80, 8'h00, 8'h80, 8'h00);

		// ---- auto-pause: the end of track 2 (four sectors) is the end of Play ----
		command(8'h0E, 1, 8'h02, 0, 0, 1);                       // Setmode: auto-pause, no reports
		command(8'h03, 1, 8'h02, 0, 0, 1);
		take_int(inum, 1);
		check(inum == 4, "auto-pause: INT4 at the start of track 3");
		check(dut.cur_trk == 7'd3 || dut.pos >= 24'd1003, "auto-pause: where track 3 begins");

		// ---- XA: interleaved audio, the filter, the queue, the samples ----
		command(8'h09, 0, 0, 0, 0, 1); take_int(inum, 1);       // Pause (INT3, INT2)
		command(8'h0E, 1, 8'h48, 0, 0, 1);                       // Setmode: XA, filter
		command(8'h0D, 2, 8'h01, 8'h02, 0, 1);                   // Setfilter: file 1, channel 2
		command(8'h02, 3, 8'h00, 8'h08, 8'h50, 1);               // Setloc 00:08:50 = LBA 500
		command(8'h1B, 0, 0, 0, 0, 1);                           // ReadS
		nint1 = 0;
		for (i = 0; i < 4; i = i + 1) begin take_int(inum, 1); if (inum == 1) nint1 = nint1 + 1; end
		check(nint1 == 4, "XA: four data sectors, four INT1");
		check(xa_count >= 5'd2, "XA: channel 2 audio queued for the PC");
		check(xa_lba == 24'd500, "XA: the first queued is LBA 500");
		@(negedge clk); xa_pop = 1; @(negedge clk); xa_pop = 0;
		check(xa_lba == 24'd504, "XA: then 504 (501, 505: channel 3, filtered out)");
		// the PC's samples come out, through the matrix
		for (i = 0; i < 40; i = i + 1) begin
			@(negedge clk); xa_we = 1; xa_wdata = {16'h1000 + i[15:0], 16'h2000 + i[15:0]};
		end
		@(negedge clk); xa_we = 0;
		// one may play while the rest are still going in: from the first one heard,
		// they must come out in order, left and right as pushed
		got = 0;
		for (i = 0; i < 60 && !got; i = i + 1) begin sample; if (sl >= 16'h2000 && sl < 16'h2004) got = 1; end
		check(got && sr == sl - 16'h1000, "XA: the pushed samples play");
		el = sl;
		for (i = 1; i < 30; i = i + 1) begin sample; if (sl !== el + i || sr !== el + i - 16'h1000) got = 0; end
		check(got, "XA: in order, thirty of them");
		k = xa_gen;
		command(8'h09, 0, 0, 0, 0, 1); take_int(inum, 1);       // Pause: XA stops, the FIFO is flushed
		check(xa_level == 13'd0 && xa_gen != k[7:0], "Pause: the XA FIFO is flushed and the PC told");

		// ---- a data read into audio: passed over, no INT1, on to the end of the disc ----
		// (the BIOS reads an audio CD this way and must time out to its CD player;
		//  a drive that refused the headerless sectors stalled at the first one)
		command(8'h0E, 1, 8'h00, 0, 0, 1);                       // Setmode: plain data
		command(8'h02, 3, 8'h00, 8'h15, 8'h23, 1);               // Setloc 00:15:23 = LBA 998
		command(8'h06, 0, 0, 0, 0, 1);                           // ReadN
		take_int(inum, 1); check(inum == 1, "read into audio: INT1 for data LBA 998"); wr8(0, 0); wr8(3, 8'h00); wr8(3, 8'h80);   // the CPU drops the last sector, takes this one
		take_int(inum, 1); check(inum == 1, "read into audio: INT1 for data LBA 999"); wr8(0, 0); wr8(3, 8'h00); wr8(3, 8'h80);   // the CPU drops the last sector, takes this one
		take_int(inum, 1); check(inum == 4, "read into audio: no INT1 for audio, INT4 at the lead-out");
		check(dut.pos >= 24'd1009, "read into audio: the drive went on through the audio");
		if (errors == 0) $display("tb_ps1_cdaudio: all checks passed -- TOC, Play, report, GetlocP, Mute, matrix, auto-pause, XA, data read over audio");
		else             $display("tb_ps1_cdaudio: %0d FAIL", errors);
		$finish;
	end
	initial begin #400_000_000; $display("tb_ps1_cdaudio: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
