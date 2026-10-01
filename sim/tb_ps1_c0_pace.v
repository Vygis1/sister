//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_dma - the GPU -> RAM DMA read-back (channel 2, VRAM -> CPU), which the
// BIOS never uses and the board hangs on: a 1024x1 C0 read moved by a 512-word
// DMA into RAM. Prints every hand-over between the GPU and the DMA.
//   ./tools/sim.sh tb_ps1_dma
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps
module tb_ps1_c0_pace;
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
		.cap_every_vsync(0), .cc_flush(0), .cd_trace_idx(0), .dbg_perf_sel(0), .dbg_rsel(0), .dbg_watch(0), .fb_cap_go(0), .fbr_addr(0), .fbr_req(0), .hr_go(0), .hr_line(0), .joy1(0), .vram_flush(0), .dma_relax(1'b0), .ev_idx(6'd0), .card_in(1'b0), .card_fill(1'b0), .card_wq_pop(1'b0), .card_wq_clr(1'b0), 
		.cpu_halt(1'b0),   // nothing halts the processor in simulation
		.gte_old(4'd0),
		.clk(clk), .rst(rst), .cpu_run(cpu_run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid), .d_calibrated(1'b1),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .dbg_pc(pc),
		// the two fast answer paths, both on
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b0), .gpu_fast(1'b0), .no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0), .cd_disc_in(1'b0), .cd_sb_we(1'b0), .cd_sb_addr(12'd0), .cd_sb_data(8'd0), .cd_sb_done(1'b0), .cd_sb_lba(24'd0),
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
	integer i, cycles, n_rd, n_rvalid, n_have, done;
	reg dma_rd_d, rvalid_d, have_d; reg [3:0] dst_d;
	// every pixel the C0 read fetches, and every hand-over of a word
	integer npx; initial npx = 0;
	integer nsb = 0;
	reg sbv_d = 0;
	always @(posedge clk) sbv_d <= dut.sb_v;
	always @(posedge clk) if (nsb < 20 && (dut.sb_v !== sbv_d)) begin
		nsb = nsb + 1;
		$display("    SB @%0t v=%b addr=%07h ce=%b c_req=%b c_we=%b cc_ack=%b calib=%b",
		         $time, dut.sb_v, dut.sb_addr, dut.cpu_ce, dut.c_req, dut.c_we,
		         dut.cc_ack, dut.d_calibrated);
	end

	always @(posedge clk) if (dut.gpu.ds == 6'd26 && dut.v_ack && npx < 12) begin npx = npx + 1;
		$display("    px @%0t cx=%0d cy=%0d cphase=%b rd_have=%b v_rdata=%08h", $time, dut.gpu.cx, dut.gpu.cy, dut.gpu.cphase, dut.gpu.rd_have, dut.v_rdata); end
	always @(posedge clk) if (dut.gpu.rd_have && (dut.gpu.dma_rd || (dut.gpu.sel && !dut.gpu.we && !dut.gpu.a4)))
		$display("    TAKE @%0t by %s word=%08h c_addr=%08h", $time, dut.gpu.dma_rd ? "DMA" : "CPU", dut.gpu.rd_word, dut.c_addr);
	always @(posedge clk) if (dut.gpu.ds == 6'd1) $display("    GP0 dispatch @%0t cmd=%02h w1=%08h w2=%08h", $time, dut.gpu.cmd, dut.gpu.w1, dut.gpu.w2);
	integer nrd; initial nrd = 0;
	always @(posedge clk) if (dut.cpu.st == 3'd3 && dut.cpu_ce && dut.c_addr == 32'h1F801810 && nrd < 8) begin nrd = nrd + 1;
		$display("    CPU-READ GPUREAD @%0t din=%08h (rd_have now %b)", $time, dut.cpu.din, dut.gpu.rd_have); end
	integer nst, nok; initial begin nst = 0; nok = 0; end
	always @(posedge clk) if (dut.c_req && dut.c_we && dut.cpu_ce && dut.c_addr[20:8] == 13'h1001) begin
		$display("    CPU-STORE @%0t addr=%08h data=%08h", $time, dut.c_addr, dut.c_dout);
		if (dut.c_dout == (32'h2000_1000 + (dut.c_addr[4:2] * 32'h0001_0001))) nok = nok + 1; nst = nst + 1; end
	always @(posedge clk) if (dut.gpu.sel && !dut.gpu.we && !dut.gpu.a4)
		$display("    SEL-READ @%0t rd_have=%b rdata=%08h c_req=%b cpu st=%0d ce=%b", $time, dut.gpu.rd_have, dut.gpu.rdata, dut.c_req, dut.cpu.st, dut.cpu_ce);
	initial begin
		for (i = 0; i < 262144; i = i + 1) mem[i] = {$random, $random, $random, $random};
		for (i = 0; i < 1024; i = i + 1) prog[i] = 32'd0;
		$readmemh("../../sim/roms/ps1/c0test.hex", prog);
		for (i = 0; i < 1024; i = i + 4) mem[24'h03_0000 + (i >> 2)] = {prog[i+3], prog[i+2], prog[i+1], prog[i]};
		repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge clk); cpu_run = 1;
		n_rd = 0; n_rvalid = 0; n_have = 0; done = 0; dma_rd_d = 0; rvalid_d = 0; have_d = 0; dst_d = 0;
		for (cycles = 0; cycles < 2_000_000 && !done; cycles = cycles + 1) begin
			@(posedge clk);
			if (dut.u_dma.st != dst_d) begin dst_d = dut.u_dma.st;
				$display("  @%0d DMA st=%0d words=%0d addr=%06h  gpu ds=%0d busy=%b rd_have=%b cx=%0d cy=%0d", cycles, dut.u_dma.st, dut.u_dma.words, dut.u_dma.addr, dut.gpu.ds, dut.gpu.busy, dut.gpu.rd_have, dut.gpu.cx, dut.gpu.cy); end
			if (dut.gpu.rd_have && !have_d) n_have = n_have + 1;
			if (dut.u_dma.gpu_rd && !dma_rd_d) n_rd = n_rd + 1;
			if (dut.gpu.dma_rvalid) n_rvalid = n_rvalid + 1;
			have_d = dut.gpu.rd_have; dma_rd_d = dut.u_dma.gpu_rd;
			if (dut.c_addr == 32'h1F80A000 && dut.c_req) done = 1;
		end
		$display("  cycles=%0d done=%0d  words produced (rd_have rises)=%0d  dma requests=%0d  rvalids=%0d", cycles, done, n_have, n_rd, n_rvalid);
		$display("  RAM word0=%08h (expect 62086208)  DMA st=%0d words left=%0d  GPU busy=%b ds=%0d", mem[24'h01_0000 + 24'h10000/16 * 0 + 24'h1000][31:0], dut.u_dma.st, dut.u_dma.words, dut.gpu.busy, dut.gpu.ds);
		$display("  words the CPU collected at 0x80100100: %08h %08h %08h %08h", mem[24'h01_0000 + 24'h10010][31:0], mem[24'h01_0000 + 24'h10010][63:32], mem[24'h01_0000 + 24'h10010][95:64], mem[24'h01_0000 + 24'h10010][127:96]);
		$display("  final: gpu ds=%0d busy=%b rd_have=%b cx=%0d cy=%0d | wc st=%0d acc_v=%b c_req=%b | vcache st=%0d | cpu pc=%08h", dut.gpu.ds, dut.gpu.busy, dut.gpu.rd_have, dut.gpu.cx, dut.gpu.cy, dut.u_wc.st, dut.u_wc.acc_v, dut.u_wc.c_req, dut.vcache.st, pc);
		$display("  stores=%0d correct=%0d", nst, nok);
		if (nst == 8 && nok == 8) $display("tb_ps1_c0: PASS"); else $display("tb_ps1_c0: FAIL");
		$finish;
	end
endmodule
`default_nettype wire
