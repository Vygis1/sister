//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_mdecdma - a movie frame through the MDEC as Syphon Filter's player sends it: the frame
// by DMA0, the picture back by DMA1 in 20 slices of 1920 words, each started when the last one
// is done, with an ordering-table clear beside each. Every one of the 38,400 words must reach RAM
// (on the board the player waited for a slice the MDEC never filled and dropped the movie).
// Program and data: tools/ps1/mkmdecdma.py.
//   ./tools/sim.sh tb_ps1_mdecdma
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps
module tb_ps1_mdecdma;
	reg clk = 0, rst = 1, cpu_run = 0;
	always #10 clk = ~clk;
	reg [18:0] host_windex = 0; reg host_we = 0; reg [31:0] host_wdata = 0;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata, d_rdata;
	wire [15:0]  d_wmask;
	wire [127:0] d_bm = {{8{d_wmask[15]}}, {8{d_wmask[14]}}, {8{d_wmask[13]}}, {8{d_wmask[12]}}, {8{d_wmask[11]}}, {8{d_wmask[10]}}, {8{d_wmask[9]}}, {8{d_wmask[8]}}, {8{d_wmask[7]}}, {8{d_wmask[6]}}, {8{d_wmask[5]}}, {8{d_wmask[4]}}, {8{d_wmask[3]}}, {8{d_wmask[2]}}, {8{d_wmask[1]}}, {8{d_wmask[0]}}}; wire d_ready;
	reg d_valid = 0; reg [127:0] d_rdata_r = 0; assign d_rdata = d_rdata_r;
	wire px_valid; wire [8:0] px_x, px_y; wire [7:0] px_rgb; wire [31:0] pc;
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
		// the two fast answer paths, both on
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b1), .gpu_fast(1'b1), .no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0), .cd_disc_in(1'b0), .cd_sb_we(1'b0), .cd_sb_addr(12'd0), .cd_sb_data(8'd0), .cd_sb_done(1'b0), .cd_sb_lba(24'd0),
		// the straight-to-network picture path, idle in this bench
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
	reg [31:0] prog [0:1023];
	integer i, cycles, result, out_words, fd, r, want_n;
	reg [31:0] a, w, want_sum;
	always @(posedge clk) if (dut.u_dma.st == 4'd11 && dut.u_dma.r_ack && dut.u_dma.cur == 3'd1) out_words = out_words + 1;
	initial begin
		for (i = 0; i < 262144; i = i + 1) mem[i] = 128'd0;
		for (i = 0; i < 1024; i = i + 1) prog[i] = 32'd0;
		$readmemh("../../sim/roms/ps1/mdecdma.hex", prog);
		for (i = 0; i < 1024; i = i + 4) mem[24'h03_0000 + (i >> 2)] = {prog[i+3], prog[i+2], prog[i+1], prog[i]};
		fd = $fopen("../../sim/roms/ps1/mdecdma_data.hex", "r");
		while (!$feof(fd)) begin
			r = $fscanf(fd, "%h %h\n", a, w);
			if (r == 2) mem[24'h01_0000 + (a >> 4)][a[3:2]*32 +: 32] = w;
		end
		$fclose(fd);
		fd = $fopen("../../sim/roms/ps1/mdecdma_sum.txt", "r"); r = $fscanf(fd, "%d %h", want_n, want_sum); $fclose(fd);
		repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge clk); cpu_run = 1;
		result = 0; out_words = 0;
		for (cycles = 0; cycles < 40_000_000 && result == 0; cycles = cycles + 1) begin
			@(posedge clk);
			if (dut.c_req && dut.c_addr == 32'h1F80A000) result = 1;
			if (dut.c_req && dut.c_addr == 32'h1F80A004) result = 2;
		end
		repeat (200) @(posedge clk);
		$display("  cycles=%0d result=%0d (1 = all slices done, 2 = a slice timed out)  words DMA1 wrote %0d of %0d  mdec busy=%b left=%h ocnt=%0d  dma1 busy=%b blocks=%0d",
		         cycles, result, out_words, want_n, dut.u_mdec.busy, dut.u_mdec.left, dut.u_mdec.ocnt, dut.u_dma.chcr[1][24], dut.u_dma.bcr[1][31:16]);
		if (result == 1 && out_words == want_n) $display("tb_ps1_mdecdma: PASS");
		else $display("tb_ps1_mdecdma: FAIL");
		$finish;
	end
endmodule
`default_nettype wire
