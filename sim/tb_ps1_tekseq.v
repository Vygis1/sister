//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_tekseq - Tekken 2's vertex transform loop (tools/ps1/tekseq.py) on the whole console:
// the loop runs from RAM through the instruction cache as the game's does, its data through the
// data cache, the main cache and a DDR3 model with a random latency, an ordering-table DMA per
// object. Every screen position it stores in the scratchpad is checked against tools/ps1/gte.py.
//   python tools/ps1/tekseq.py sim/roms/ps1/tekseq 64; ./tools/sim.sh tb_ps1_tekseq
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps
module tb_ps1_tekseq;
	reg clk = 0, rst = 1, cpu_run = 0;
	reg cc_flush_r = 0;
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
		.cap_every_vsync(0), .cc_flush(cc_flush_r), .cd_trace_idx(0), .dbg_perf_sel(0), .dbg_rsel(0), .dbg_watch(0), .fb_cap_go(0), .fbr_addr(0), .fbr_req(0), .hr_go(0), .hr_line(0), .joy1(0), .vram_flush(0), .dma_relax(1'b0), .cd_edc_on(1'b0), .pace_long(1'b1), .wq_off(1'b0), .lead_big(1'b0), .run_ahead(1'b0), .dma_charge(1'b1), .ev_idx(6'd0), .card_in(1'b0), .card_fill(1'b0), .card_wq_pop(1'b0), .card_wq_clr(1'b0), 
		.cpu_halt(1'b0),   // nothing halts the processor in simulation
		.gte_old(4'd0), .gte_snap_arm(1'b0), .gte_snap_go(1'b0), .gte_snap_skip(16'd0), .gte_snap_idx(7'd0), .tty_idx(12'd0), .gtr_idx(11'd0), .gtr_arm(1'b0), .gtr_pops(1'b0), .gtr_halt(1'b0), .fb_hr_raw(1'b0), .fb_hr_base(24'd0),
		.clk(clk), .rst(rst), .cpu_run(cpu_run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid), .d_calibrated(1'b1),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .dbg_pc(pc),
		// the two fast answer paths, both on
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b0), .gpu_fast(1'b1), .no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0), .cd_disc_in(1'b0), .cd_sb_we(1'b0), .cd_sb_addr(12'd0), .cd_sb_data(8'd0), .cd_sb_done(1'b0), .cd_sb_lba(24'd0),
		// the straight-to-network picture path, idle in this bench
		.fs_en(1'b0), .fs_arm(1'b0), .fs_empty(), .fs_rd(1'b0), .fs_data(), .fs_valid(),
		.dbg_icv_pc(), .dbg_icv_got(), .dbg_icv_want(), .dbg_icv_n()
	);
	// DDR3 model: one at a time, LAT cycles
	reg [127:0] mem [0:262143];
	reg [5:0] LAT = 14;
	reg busy = 0; reg [4:0] wait_ct = 0; reg pend_we = 0; reg [23:0] pend_addr = 0;
	assign d_ready = d_req && !busy;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req && d_ready) begin busy <= 1; wait_ct <= 5'd8 + ($random & 31); pend_we <= d_we; pend_addr <= d_addr; if (d_we) mem[d_addr[17:0]] <= (mem[d_addr[17:0]] & ~d_bm) | (d_wdata & d_bm); end
		else if (busy) begin if (wait_ct != 0) wait_ct <= wait_ct - 1; else begin busy <= 0; if (!pend_we) begin d_valid <= 1; d_rdata_r <= mem[pend_addr[17:0]]; end end end
	end
	reg [31:0] prog [0:1023];
	// An interrupt taken on 80010178 -- the loop's MTC2 t0 at the branch target, which is also the
	// delay slot of the MFC2 t0 in the branch's slot -- completes that MFC2 first, so the MTC2 reads
	// the NEW t0 when it runs again after the return. That is the console's own behaviour (psx-spx,
	// CPU load delay: "unless an IRQ occurs between the load and next opcode, in that case the load
	// would complete during IRQ handling, and so, the next opcode would receive the NEW value") --
	// Tekken 2's loop relies on the old value and gets one wrong vertex whenever the timer lands
	// there, on the console as here. Such interrupts are counted, and that many wrong entries are
	// what the console would store. (Which instruction the timer lands on moves with the memory's
	// timing: the processor cache's stream buffer moved it onto this one.)
	integer slot_irqs = 0;
	always @(posedge clk) if (dut.cpu.ce && dut.cpu.st == 3'd5 && dut.cpu.exc_code == 5'd0 && dut.cpu.PC == 32'h80010178 && (dut.cpu.ld_commit || dut.cpu.ld_pend))
		slot_irqs = slot_irqs + 1;
	reg [31:0] ramw [0:131071];
	integer i, cycles, done; reg xr = 0;
	integer n_t2 = 0, n_sys = 0, n_exc = 0;
	always @(posedge clk) begin
		if (dut.tmr_irq[2]) n_t2 = n_t2 + 1;
		if (dut.sys_ce) n_sys = n_sys + 1;
		if (cycles % 100000 == 50 && cycles < 1300000) $display("    @%0d timer2 cnt=%0d mode=%h t2pulses=%0d sys=%0d", cycles, dut.u_timers.cnt[2], dut.u_timers.mode[2], n_t2, n_sys);
	end
	initial begin
		for (i = 0; i < 262144; i = i + 1) mem[i] = {$random, $random, $random, $random};
		for (i = 0; i < 1024; i = i + 1) prog[i] = 32'd0;
		for (i = 0; i < 131072; i = i + 1) ramw[i] = 32'd0;
		$readmemh("../../sim/roms/ps1/tekseq_rom.hex", prog);
		$readmemh("../../sim/roms/ps1/tekseq_ram.hex", ramw);
		for (i = 0; i < 1024; i = i + 4) mem[24'h03_0000 + (i >> 2)] = {prog[i+3], prog[i+2], prog[i+1], prog[i]};
		for (i = 0; i < 131072; i = i + 4) mem[24'h01_1000 + (i >> 2)] = {ramw[i+3], ramw[i+2], ramw[i+1], ramw[i]};   // RAM 0x10000 on
		repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge clk); cpu_run = 1;
		done = 0;
		for (cycles = 0; cycles < 60_000_000 && !done; cycles = cycles + 1) begin
			@(posedge clk);
			if (dut.c_addr == 32'h1F80A000 && dut.c_req) done = 1;
			if (^dut.credit === 1'bx && !xr) begin xr = 1; $display("    X @%0d: t_take=%b t_cost=%h dma_wc=%b sys_ce=%b dma_block=%b gp0_wr=%b spu=%b mdec=%b node=%b dm_req=%b dm_ack=%b dm_we=%b dm_lwe=%b be16=%h", cycles, dut.t_take, dut.t_cost, dut.dma_wc, dut.sys_ce, dut.dma_block, dut.gp0_wr, dut.spu_dma_wr, dut.mdec_wr, dut.dbg_node_v, dut.dm_req, dut.dm_ack, dut.dm_we, dut.dm_lwe, dut.dm_be16); end
			if (cycles == 20000 || cycles == 200000) $display("    @%0d first fetch: c_req=%b c_addr=%08h cpu_ready=%b served=%b cc_ack=%b ccache st=%0d flushing=%b a_req=%b", cycles, dut.c_req, dut.c_addr, dut.cpu_ready, dut.served, dut.cc_ack, dut.ccache.st, dut.ccache.flushing, dut.ccache.a_req);
			if (cycles % 1000000 == 0) $display("    @%0d pc=%08h st=%0d credit=%0d ce=%b dma=%0d", cycles, pc, dut.cpu.st, dut.credit, dut.cpu_ce, dut.u_dma.st);
		end
		// the results are in the write-back cache: put them in memory
		@(posedge clk); cc_flush_r = 1; @(posedge clk); cc_flush_r = 0;
		repeat (200000) @(posedge clk);
		$display("  cycles                  : %0d (%s)", cycles, done ? "finished" : "TIMED OUT");
		$display("  first failing set+1     : %0d (vertex %0d)", mem[24'h01_0100][31:0], mem[24'h01_0101][63:32]);
		$display("  sets run                : %0d", mem[24'h01_0100][63:32]);
		$display("  wrong table entries     : %0d", mem[24'h01_0101][31:0]);
		$display("  interrupts taken        : %0d (timer 2 pulses %0d, console clocks %0d, target %0d, mode %h)", mem[24'h01_0101][95:64], n_t2, n_sys, dut.u_timers.tgt[2], dut.u_timers.mode[2]);
		if (mem[24'h01_0100][31:0] != 0) begin
			$display("  stored   : %08h", mem[24'h01_0100][95:64]);
			$display("  expected : %08h", mem[24'h01_0100][127:96]);
		end
		$display("  interrupts in MFC2's load delay slot: %0d (each one a vertex the console itself gets wrong)", slot_irqs);
		if (done && mem[24'h01_0100][63:32] != 0 && mem[24'h01_0101][31:0] == slot_irqs) $display("tb_ps1_tekseq: PASS");
		else $display("tb_ps1_tekseq: FAIL");
		$finish;
	end
endmodule
`default_nettype wire
