//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_cdbios - a sector from the CD-ROM drive into RAM by DMA channel 3, the
// way a game's libcd does it: the whole machine (ps1_top), a MIPS program that
// sets the mode, seeks, reads, waits for INT1, asks for the data and starts
// the DMA, and a feeder that delivers the sectors the drive asks for. The
// 2048 bytes that land at RAM 0x100000 must be the sector's user data.
//   ./tools/sim.sh tb_ps1_cdbios
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps
module tb_ps1_cdbios;
	reg clk = 0, rst = 1, cpu_run = 0;
	always #10 clk = ~clk;
	reg [18:0] host_windex = 0; reg host_we = 0; reg [31:0] host_wdata = 0;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata, d_rdata;
	wire [15:0]  d_wmask;
	wire [127:0] d_bm = {{8{d_wmask[15]}}, {8{d_wmask[14]}}, {8{d_wmask[13]}}, {8{d_wmask[12]}}, {8{d_wmask[11]}}, {8{d_wmask[10]}}, {8{d_wmask[9]}}, {8{d_wmask[8]}}, {8{d_wmask[7]}}, {8{d_wmask[6]}}, {8{d_wmask[5]}}, {8{d_wmask[4]}}, {8{d_wmask[3]}}, {8{d_wmask[2]}}, {8{d_wmask[1]}}, {8{d_wmask[0]}}}; wire d_ready;
	reg d_valid = 0; reg [127:0] d_rdata_r = 0; assign d_rdata = d_rdata_r;
	wire px_valid; wire [8:0] px_x, px_y; wire [7:0] px_rgb; wire [31:0] pc;
	// the drive's transport
	wire [23:0] fill_lba; wire [3:0] fill_room; wire fill_run;
	reg  sb_we = 0; reg [11:0] sb_addr = 0; reg [7:0] sb_data = 0; reg sb_done = 0; reg [23:0] sb_lba = 0;
	ps1_top dut (
		.card2_fill(0), .card2_in(0), .joy2(0),
		.toc_addr(0), .toc_data(0), .toc_we(0), .xa_pop(0), .xa_wdata(0), .xa_we(0), // inputs this bench does not drive, tied: an open input simulates as X
		.cap_every_vsync(0), .cc_flush(0), .cd_trace_idx(0), .dbg_perf_sel(0), .dbg_rsel(0), .dbg_watch(0), .fb_cap_go(0), .fbr_addr(0), .fbr_req(0), .hr_go(0), .hr_line(0), .joy1(0), .vram_flush(0), .dma_relax(1'b0), .cd_edc_on(1'b0), .pace_long(1'b0), .wq_off(1'b0), .lead_big(1'b0), .run_ahead(1'b0), .dma_charge(1'b0), .ev_idx(6'd0), .card_in(1'b0), .card_fill(1'b0), .card_wq_pop(1'b0), .card_wq_clr(1'b0), 
		.cpu_halt(1'b0),   // nothing halts the processor in simulation
		.gte_old(4'd0), .gte_snap_arm(1'b0), .gte_snap_go(1'b0), .gte_snap_skip(16'd0), .gte_snap_idx(7'd0), .tty_idx(12'd0), .gtr_idx(11'd0), .gtr_arm(1'b0), .gtr_pops(1'b0), .gtr_halt(1'b0), .fb_hr_raw(1'b0), .fb_hr_base(24'd0),
		.clk(clk), .rst(rst), .cpu_run(cpu_run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid), .d_calibrated(1'b1),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .dbg_pc(pc),
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b1), .gpu_fast(1'b1), .no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0),
		.cd_disc_in(1'b1), .cd_sb_we(sb_we), .cd_sb_addr(sb_addr), .cd_sb_data(sb_data), .cd_sb_done(sb_done), .cd_sb_lba(sb_lba),
		.cd_fill_lba_o(fill_lba), .cd_fill_room_o(fill_room), .cd_fill_run_o(fill_run),
		.fs_en(1'b0), .fs_arm(1'b0), .fs_empty(), .fs_rd(1'b0), .fs_data(), .fs_valid(),
		.dbg_icv_pc(), .dbg_icv_got(), .dbg_icv_want(), .dbg_icv_n()
	);
	// DDR3 model: one at a time, LAT cycles
	reg [127:0] mem [0:262143];
	localparam LAT = 14;
	reg busy = 0; reg [4:0] wait_ct = 0; reg pend_we = 0; reg [23:0] pend_addr = 0;
	assign d_ready = d_req && !busy;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req && d_ready) begin busy <= 1; wait_ct <= LAT; pend_we <= d_we; pend_addr <= d_addr; if (d_we) mem[d_addr[17:0]] <= (mem[d_addr[17:0]] & ~d_bm) | (d_wdata & d_bm); end
		else if (busy) begin if (wait_ct != 0) wait_ct <= wait_ct - 1; else begin busy <= 0; if (!pend_we) begin d_valid <= 1; d_rdata_r <= mem[pend_addr[17:0]]; end end end
	end
	// the image: byte k of sector n is (n*7 + k) & 0xFF, with a plausible header
	function [7:0] img; input [23:0] lba; input [11:0] k; begin
		// a data sector starts with its sync pattern (00, ten FFs, 00); without it the
		// drive takes it for audio and passes over it, as a real drive does
		img = (k == 0 || k == 11) ? 8'h00 : (k < 11) ? 8'hFF : (k == 12) ? bcd(((lba + 150) / 75) / 60) : (k == 13) ? bcd(((lba + 150) / 75) % 60) : (k == 14) ? bcd((lba + 150) % 75) : (k == 15) ? 8'h02 :
		      (k >= 16 && k < 20) ? 8'h00 : (lba * 7 + k) & 8'hFF; end endfunction
	function [7:0] bcd; input [7:0] b; bcd = ((b / 8'd10) << 4) | (b % 8'd10); endfunction
	integer fed = 0;
	// the ESP32 polls status about once a millisecond and answers one sector a
	// poll (+FEED_GAP<clocks> between deliveries, e.g. ./tools/sim.sh tb_ps1_cdbios FEED_GAP150000; 0 = as fast as the wire allows)
	integer FEED_GAP = 0;
	initial if (!$value$plusargs("FEED_GAP%d", FEED_GAP)) FEED_GAP = 0;
	always @(posedge clk) if (fill_run && fill_room != 0 && !sb_we && !sb_done) deliver(fill_lba);
	task deliver; input [23:0] lba; integer k; begin
		repeat (FEED_GAP) @(posedge clk);
		lba = fill_lba;                       // what the drive wants NOW, as the ESP32 would read from its status
		sb_lba <= lba; sb_we <= 1;
		for (k = 0; k < 2352; k = k + 1) begin sb_addr <= k; sb_data <= img(lba, k); @(posedge clk); end
		sb_we <= 0; sb_done <= 1; @(posedge clk); sb_done <= 0; fed = fed + 1;
		repeat (200) @(posedge clk);
	end endtask
	// every CPU access to the CD-ROM registers: what was written, what was read back
	integer nacc = 0;
	always @(posedge clk) if (dut.cd_hit && dut.c_req && dut.cpu_ce && nacc < 0) begin
		nacc = nacc + 1;
		if (dut.c_we) $display("    CD wr @%0t addr %08h be %b data %08h", $time, dut.c_addr, dut.c_be, dut.c_dout);
		else          $display("    CD rd @%0t addr %08h be %b -> %08h (int_flag=%0d index=%0d)", $time, dut.c_addr, dut.c_be, dut.cd_rdata, dut.u_cd.int_flag, dut.u_cd.index);
	end
	// what the CPU actually consumed for a CD read: the clock after the request
	reg cdrd_d = 0;
	always @(posedge clk) begin
		cdrd_d <= dut.cd_hit && dut.c_req && dut.cpu_ce && !dut.c_we;
		if (cdrd_d && nacc < 0) $display("      -> next clock: c_din %08h din_r %08h cpu st=%0d exc_bad=%08h", dut.c_din, dut.din_r, dut.cpu.st, dut.cpu.exc_bad);
	end
	// the want-data writes and the first DMA words, as the drive sees them
	integer nw = 0;
	always @(posedge clk) begin
		if (dut.cd_hit && dut.c_req && dut.cpu_ce && dut.c_we && dut.c_be[3] && nw < 6) begin nw = nw + 1;
			$display("    HCHPCTL/HCLRCTL wr @%0t index=%0d data=%02h  ld_cnt=%0d bfrd=%0d fifo_has=%0d fifo_load=%0d", $time, dut.u_cd.index, dut.c_dout[31:24], dut.u_cd.ld_cnt, dut.u_cd.bfrd, dut.u_cd.fifo_has, dut.u_cd.fifo_load); end
		if (dut.cd_dma_rd && nw < 12) begin nw = nw + 1;
			$display("    DMA3 word request @%0t: bfrd=%0d fifo_has=%0d fifo_rd=%0d fifo_end=%0d fifo_slot=%0d ld_cnt=%0d", $time, dut.u_cd.bfrd, dut.u_cd.fifo_has, dut.u_cd.fifo_rd, dut.u_cd.fifo_end, dut.u_cd.fifo_slot, dut.u_cd.ld_cnt); end
		if (dut.cd_dma_rvalid && nw < 14) begin nw = nw + 1; $display("    DMA3 word @%0t = %08h", $time, dut.cd_dma_rdata); end
	end
	reg [31:0] prog [0:1023];
	integer i, j, cycles, done, errors, bad;
	reg [31:0] mark4, mark8, markC, mark10;
	integer lbas [0:8];
	reg [127:0] l; reg [7:0] got; reg [24:0] la;
	initial begin
		errors = 0; done = 0; mark4 = 32'hDEAD; mark8 = 32'hDEAD; markC = 32'hDEAD; mark10 = 32'hDEAD; lbas[0] = 4; lbas[1] = 5; lbas[2] = 6; lbas[3] = 7; lbas[4] = 8; lbas[5] = 9; lbas[6] = 10; lbas[7] = 11; lbas[8] = 12;
		for (i = 0; i < 262144; i = i + 1) mem[i] = 128'd0;
		for (i = 0; i < 1024; i = i + 1) prog[i] = 32'd0;
		$readmemh("../../sim/roms/ps1/cdbios.hex", prog);
		for (i = 0; i < 1024; i = i + 4) mem[24'h03_0000 + (i >> 2)] = {prog[i+3], prog[i+2], prog[i+1], prog[i]};
		repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge clk); cpu_run = 1;
		cycles = 0;
		while (!done && cycles < 60_000_000) begin
			@(posedge clk); cycles = cycles + 1;
			if (dut.c_addr == 32'h1F80A000 && dut.c_req) done = 1;
			if (dut.c_addr == 32'h1F80A004 && dut.c_req && dut.c_we && dut.cpu_ce) mark4 = dut.c_dout;
			if (dut.c_addr == 32'h1F80A008 && dut.c_req && dut.c_we && dut.cpu_ce) mark8 = dut.c_dout;
			if (dut.c_addr == 32'h1F80A00C && dut.c_req && dut.c_we && dut.cpu_ce) markC = dut.c_dout;
			if (dut.c_addr == 32'h1F80A010 && dut.c_req && dut.c_we && dut.cpu_ce) mark10 = dut.c_dout;
		end
		if (!done) begin errors = errors + 1; $display("  FAIL the program did not finish (pc=%08h, fed %0d sectors, dma st=%0d, cd int=%0d)", pc, fed, dut.u_dma.st, dut.u_cd.int_flag);
			$display("      drive: stat=%02h reading=%0d seeking=%0d r_cnt=%0d ld_cnt=%0d bfrd=%0d cmds=%08h loc=%0d fill=%0d rsp_wr=%0d rsp_rd=%0d busy=%0d cmd_pend=%0d second_pend=%0d second_wait=%0d", dut.u_cd.stat, dut.u_cd.reading, dut.u_cd.seeking, dut.u_cd.r_cnt, dut.u_cd.ld_cnt, dut.u_cd.bfrd, dut.u_cd.dbg_cmds, dut.u_cd.loc, dut.u_cd.fill_lba, dut.u_cd.rsp_wr, dut.u_cd.rsp_rd, dut.u_cd.busy, dut.u_cd.cmd_pend, dut.u_cd.second_pend, dut.u_cd.second_wait);
			$display("      drive: seek_then_read=%0d sec_timer=%0d pos=%0d r_base=%0d r_wp=%0d r_rp=%0d r_lp=%0d held=%0d loc_v=%0d mode=%02h int_mask=%02h", dut.u_cd.seek_then_read, dut.u_cd.sec_timer, dut.u_cd.pos, dut.u_cd.r_base, dut.u_cd.r_wp, dut.u_cd.r_rp, dut.u_cd.r_lp, dut.u_cd.held, dut.u_cd.loc_v, dut.u_cd.mode, dut.u_cd.int_mask);
		end
		else $display("  ok   the program finished after %0d cycles, %0d sectors fed", cycles, fed);
		// three reads the game's way: LBA 16, 18, 24 into three buffers, checked through the write-back cache
		for (j = 0; j < 9; j = j + 1) begin
			bad = 0;
			for (i = 0; i < 2048; i = i + 1) begin
				la = 24'h01_0000 + ((24'h100000 + j * 24'h800 + i) >> 4);
				if (dut.ccache.valid[la[8:0]] && dut.ccache.tag[la[8:0]] == la[24:9]) l = dut.ccache.data[la[8:0]];
				else l = mem[la];
				got = l[(i % 16) * 8 +: 8];
				if (got !== img(lbas[j], 24 + i)) begin if (bad < 3) $display("      read %0d byte %0d: got %02h want %02h", j, i, got, img(lbas[j], 24 + i)); bad = bad + 1; end
			end
			if (bad == 0) $display("  ok   DMA channel 3 put LBA %0d's 2048 bytes in RAM", lbas[j]); else begin errors = errors + 1; $display("  FAIL read %0d (LBA %0d): %0d of 2048 bytes wrong", j, lbas[j], bad); end
		end
		$display("  the drive's trace (oldest first):");
		for (i = 0; i < 64; i = i + 1) begin l = dut.u_cd.trace[(dut.u_cd.trace_w + i) & 6'h3F]; if (l[31:0] != 32'd0) $display("    %08h", l[31:0]); end
		if (errors == 0) $display("tb_ps1_cdbios: all checks passed"); else $display("tb_ps1_cdbios: %0d FAIL(s)", errors);
		$finish;
	end
endmodule
`default_nettype wire
