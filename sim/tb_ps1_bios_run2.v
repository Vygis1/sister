//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_bios_run2 - the real Sony BIOS, running on the machine.
//
// DDR3 holds VRAM, 2 MB of RAM and the 512 kB BIOS; the BIOS is pre-loaded into
// its region and the CPU is let go from the reset vector. This does not check a
// picture -- it checks that the CPU is alive and getting somewhere: that the PC
// leaves the BIOS's early setup, that it reaches RAM (a stack, the kernel it
// copies there), and that it eventually writes the GPU. A BIOS that hangs sits
// at one PC; a BIOS that runs wanders through thousands.
//
//   ./tools/sim.sh tb_ps1_bios_run2
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_ps1_bios_run2;
	reg clk = 0, rst = 1, cpu_run = 0;
	always #10 clk = ~clk;

	reg [18:0] host_windex = 0;
	reg        host_we = 0;
	reg [31:0] host_wdata = 0;

	wire [23:0]  d_addr;
	wire         d_req, d_we;
	wire [127:0] d_wdata, d_rdata;
	wire [15:0]  d_wmask;
	wire [127:0] d_bm = {{8{d_wmask[15]}}, {8{d_wmask[14]}}, {8{d_wmask[13]}}, {8{d_wmask[12]}}, {8{d_wmask[11]}}, {8{d_wmask[10]}}, {8{d_wmask[9]}}, {8{d_wmask[8]}}, {8{d_wmask[7]}}, {8{d_wmask[6]}}, {8{d_wmask[5]}}, {8{d_wmask[4]}}, {8{d_wmask[3]}}, {8{d_wmask[2]}}, {8{d_wmask[1]}}, {8{d_wmask[0]}}};
	wire         d_ready;
	reg          d_valid = 0;
	reg  [127:0] d_rdata_r = 0;
	assign d_rdata = d_rdata_r;

	wire        px_valid;
	wire [8:0]  px_x, px_y;
	wire [7:0]  px_rgb;
	wire [31:0] pc;

	ps1_top dut (
		.card2_fill(0), .card2_in(0), .joy2(0),
		.toc_addr(0), .toc_data(0), .toc_we(0), .xa_pop(0), .xa_wdata(0), .xa_we(0), // inputs this bench does not drive, tied: an open input simulates as X
		.cap_every_vsync(0), .cc_flush(0), .cd_trace_idx(0), .dbg_perf_sel(0), .dbg_rsel(0), .dbg_watch(0), .fb_cap_go(0), .fbr_addr(0), .fbr_req(0), .hr_go(0), .hr_line(0), .joy1(0), .vram_flush(0), .dma_relax(1'b0), .cd_edc_on(1'b0), .pace_long(1'b0), .wq_off(1'b0), .lead_big(1'b0), .run_ahead(1'b0), .dma_charge(1'b0), .ev_idx(6'd0), .card_in(1'b0), .card_fill(1'b0), .card_wq_pop(1'b0), .card_wq_clr(1'b0), 
		.cpu_halt(1'b0),   // nothing halts the processor in simulation
		.gte_old(4'd0), .gte_snap_arm(1'b0), .gte_snap_go(1'b0), .gte_snap_skip(16'd0), .gte_snap_idx(7'd0), .tty_idx(12'd0), .gtr_idx(11'd0), .gtr_arm(1'b0), .gtr_pops(1'b0), .gtr_halt(1'b0), .fb_hr_raw(1'b0), .fb_hr_base(24'd0),
		.clk(clk), .rst(rst), .cpu_run(cpu_run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid),
		.d_calibrated(1'b1),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.dbg_pc(pc),
		// the two fast answer paths, both on
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b1), .gpu_fast(1'b1), .no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0), .cd_disc_in(1'b0), .cd_sb_we(1'b0), .cd_sb_addr(12'd0), .cd_sb_data(8'd0), .cd_sb_done(1'b0), .cd_sb_lba(24'd0),
		// the straight-to-network picture path, idle in this bench
		.fs_en(1'b0), .fs_arm(1'b0), .fs_empty(), .fs_rd(1'b0), .fs_data(), .fs_valid(),
		.dbg_icv_pc(), .dbg_icv_got(), .dbg_icv_want(), .dbg_icv_n()
	);

	// DDR3: a line memory behaving like ddr3_mem -- one at a time, m_ready when
	// idle, a write that completes silently, a read that answers after latency.
	// 4 MB of it: VRAM + RAM + BIOS.
	reg [127:0] mem [0:262143];
	localparam LAT = 14;
	reg          busy = 0;
	reg [4:0]    wait_ct = 0;
	reg          pend_we = 0;
	reg [23:0]   pend_addr = 0;
	assign d_ready = d_req && !busy;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req && d_ready) begin
			busy <= 1'b1; wait_ct <= LAT; pend_we <= d_we; pend_addr <= d_addr;
			if (d_we) mem[d_addr[17:0]] <= (mem[d_addr[17:0]] & ~d_bm) | (d_wdata & d_bm);
		end else if (busy) begin
			if (wait_ct != 0) wait_ct <= wait_ct - 5'd1;
			else begin
				busy <= 1'b0;
				if (!pend_we) begin d_valid <= 1'b1; d_rdata_r <= mem[pend_addr[17:0]]; end
			end
		end
	end

	// load the BIOS into its DDR3 region (line 0x30000), four words per line
	reg [31:0] bios [0:131071];
	integer i, cycles, gpu_writes;
	reg [31:0] last_pc, lo_pc, hi_pc;
	integer distinct, rp, di;
	reg derailed;
	reg [31:0] ring [0:31];
	reg [31:0] ripc [0:31];
	integer rrp;
	reg [31:0] rring [0:31];
	reg [31:0] rrip [0:31];
	initial begin rp = 0; rrp = 0; end
	// record every REAL executed instruction (S_EXEC with nonzero ir)
	// every committed instruction (S_EXEC with the CPU actually advancing)
	always @(posedge clk) if (!rst && cpu_run && dut.cpu.st == 3'd1 && dut.cpu_ce) begin
		rring[rrp] = pc; rrip[rrp] = dut.cpu.din; rrp = (rrp+1) % 32;
	end

	always @(posedge clk) if (!rst && dut.gpu_hit && dut.c_req && dut.c_we) begin
		if (gpu_writes == 0) $display("  FIRST GPU WRITE at cycle %0d: addr=%08h data=%08h", cycles, dut.c_addr, dut.c_dout);
		gpu_writes = gpu_writes + 1;
	end
	// catch a GPU DMA that never completes: channel 2 busy for too long
	integer noack_ct; initial noack_ct=0;
	integer dvalid_ct; initial dvalid_ct=0;
	reg dma2_busy_d; initial dma2_busy_d=0;
	always @(posedge clk) if (!rst && d_valid) dvalid_ct = dvalid_ct + 1;
	// the picture: what the scanout hands the framebuffer, dumped every 50M
	// cycles so the run can be watched without waiting for it to end
	reg [7:0] frame [0:320*240-1];
	integer fi, ffd, fnz; reg disp_on_d; initial disp_on_d = 0;
	always @(posedge clk) begin
		if (px_valid && px_x < 320 && px_y < 240) frame[px_y*320 + px_x] = px_rgb;
		disp_on_d <= dut.gpu.disp_on;
		if (dut.gpu.disp_on != disp_on_d)
			$display("  DISPLAY %s at cycle %0d: x=%0d y=%0d hres=%0d v480=%b (gpu_writes %0d)",
			  dut.gpu.disp_on ? "ON" : "OFF", cycles, dut.gpu.disp_x, dut.gpu.disp_y, dut.gpu.hres, dut.gpu.vres480, gpu_writes);
	end
	// every command the draw engine dispatches once the display is nearly on:
	// opcode, its first words, and the drawing environment it runs under
	always @(posedge clk) if (!rst && dut.gpu.ds == 6'd1)
		$display("  GP0 @%0d cmd=%02h w0=%08h w1=%08h w2=%08h w3=%08h area=(%0d,%0d)-(%0d,%0d) ofs=(%0d,%0d) disp=(%0d,%0d)",
		  cycles, dut.gpu.cmd, dut.gpu.w0, dut.gpu.w1, dut.gpu.w2, dut.gpu.w3,
		  dut.gpu.da_x0, dut.gpu.da_y0, dut.gpu.da_x1, dut.gpu.da_y1, $signed(dut.gpu.dofs_x), $signed(dut.gpu.dofs_y),
		  dut.gpu.disp_x, dut.gpu.disp_y);
	always @(posedge clk) if (!rst && dut.gpu.sel && dut.gpu.we && dut.gpu.a4)
		$display("  GP1 @%0d %08h", cycles, dut.gpu.wdata);
	// the raw GP0 word stream once the display is on: every word the engine
	// pops, so a packet can be read exactly as the BIOS built it
	// late in the run: every word of textured primitives and CPU->VRAM uploads
	integer texw = 0;
	always @(posedge clk) if (!rst && cycles > 1_700_000_000 && dut.gpu.f_pop && texw < 4000 &&
	                          ((dut.gpu.ds == 6'd0 && (dut.gpu.f_head[31:26] == 6'b001011 || dut.gpu.f_head[31:26] == 6'b001111 || dut.gpu.f_head[31:24] == 8'hA0 ||
	                            (dut.gpu.f_head[31:24] >= 8'h64 && dut.gpu.f_head[31:24] <= 8'h7F))) || (dut.gpu.ds == 6'd2) || (dut.gpu.ds == 6'd23 && texw % 64 == 0))) begin
		texw = texw + 1;
		$display("  TW @%0d ds=%0d %08h", cycles, dut.gpu.ds, dut.gpu.f_head);
	end
	always @(posedge clk) if (!rst && dut.gpu.f_pop && (dut.gpu.f_head[31:24] >= 8'hE1 && dut.gpu.f_head[31:24] <= 8'hE6 || dut.gpu.f_head[31:24] == 8'h02))
		$display("  W @%0d %08h  ofs=(%0d,%0d)", cycles, dut.gpu.f_head, $signed(dut.gpu.dofs_x), $signed(dut.gpu.dofs_y));
	always @(posedge clk) if (!rst && cycles > 520_000_000 && dut.u_dma.dbg_node_v)
		$display("  NODE @%0d addr=%06h hdr=%08h", cycles, dut.u_dma.dbg_node_addr, dut.u_dma.dbg_node_hdr);
	// the header line at RAM 0x138ca0 (DDR3 line 0x238ca, cache index 0x0ca): every
	// CPU store into it, and the cache/DDR3 state when the DMA reads its header
	always @(posedge clk) if (!rst && cycles > 546_000_000 && dut.c_req && dut.c_we && dut.cpu_ce && dut.c_addr[20:4] == 17'h138ca)
		$display("  STORE @%0d pc=%08h addr=%08h data=%08h be=%b", cycles, pc, dut.c_addr, dut.c_dout, dut.c_be);
	always @(posedge clk) if (!rst && cycles > 546_000_000 && dut.u_dma.dbg_node_v && dut.u_dma.dbg_node_addr == 24'h138ca8)
		$display("  HDRREAD @%0d hdr=%08h | cache[0ca] tag=%h valid=%b dirty=%b line=%h | ddr3 line=%h", cycles, dut.u_dma.dbg_node_hdr,
		  dut.ccache.tag[9'h0ca], dut.ccache.valid[9'h0ca], dut.ccache.dirty[9'h0ca], dut.ccache.data[9'h0ca], mem[24'h238ca]);
	always @(posedge clk) if (!rst && cycles > 546_268_000 && cycles < 546_268_700 && (dut.ccache.st == 3'd6))
		$display("  CACHE-ANS @%0d serving_b=%b addr=%h idx=%h hit=%b we=%b refilled=%b a_req=%b b_req=%b", cycles, dut.ccache.serving_b, dut.ccache.addr, dut.ccache.idx, dut.ccache.hit, dut.ccache.we, dut.ccache.refilled, dut.ccache.a_req, dut.ccache.b_req);
	// every CPU load of the ordering-table slot 0x0ebd08 (and its neighbour) after
	// 546M cycles: what the CPU asked for and what it got (S_MEMR samples din)
	always @(posedge clk) if (!rst && cycles > 546_000_000 && dut.cpu.st == 3'd3 && dut.cpu_ce && dut.c_addr[20:4] == 17'h0ebd0)
		$display("  LOAD @%0d pc=%08h addr=%08h -> %08h  (ccache st=%0d serving_b=%b b_req=%b | ddr3 line=%h)", cycles, pc, dut.c_addr, dut.cpu.din, dut.ccache.st, dut.ccache.serving_b, dut.ccache.b_req, mem[24'h01_0000 + 24'h0ebd0]);
	always @(posedge clk) if (!rst && cycles > 546_000_000 && dut.c_req && dut.c_we && dut.cpu_ce && dut.c_addr[20:4] == 17'h0ebd0)
		$display("  OTSTORE @%0d pc=%08h addr=%08h data=%08h be=%b", cycles, pc, dut.c_addr, dut.c_dout, dut.c_be);
	always @(posedge clk) if (!rst && cycles > 546_000_000 && dut.dm_req && dut.dm_we && dut.dm_ack && dut.dm_addr[20:4] == 17'h0ebd0)
		$display("  OTC-WRITE @%0d addr=%08h data=%08h", cycles, dut.dm_addr, dut.dm_wdata);
	// the memcpy that builds packet 0x138ca8: where its bytes come FROM
	always @(posedge clk) if (!rst && cycles > 546_264_000 && cycles < 546_266_000 && dut.cpu.st == 3'd3 && dut.cpu_ce && pc == 32'h800308c0)
		$display("  MEMCPY-SRC @%0d addr=%08h byte=%02h", cycles, dut.c_addr, dut.cpu.din[7:0]);
	// per-frame order for packet 0x138ca8 late in the run: every store to its
	// header, every DMA kick (CHCR2 write), every DMA read of its header
	always @(posedge clk) if (!rst && cycles > 500_000_000 && dut.c_req && dut.c_we && dut.cpu_ce && dut.c_addr[20:2] == 19'h4e32a)
		$display("  HDR-STORE @%0d pc=%08h data=%08h be=%b", cycles, pc, dut.c_dout, dut.c_be);
	always @(posedge clk) if (!rst && cycles > 500_000_000 && dut.dma_hit && dut.c_req && dut.c_we && dut.cpu_ce && dut.c_addr[7:0] == 8'ha8 && dut.c_dout[24])
		$display("  DMA-KICK @%0d pc=%08h chcr2=%08h", cycles, pc, dut.c_dout);
	// s0 (R16) is the GPU-queue handler's mask: report every time it goes from
	// the mask to zero, and every exception entry / rfe late in the run
	reg [31:0] s0_d; integer s0ev = 0, excs = 0;
	always @(posedge clk) if (!rst) begin
		s0_d <= dut.cpu.R[16];
		if (dut.cpu.R[16] != s0_d && s0_d == 32'h10000000 && s0ev < 40) begin
			s0ev = s0ev + 1;
			$display("  S0-CHANGE @%0d %08h -> %08h pc=%08h st=%0d ce=%b hog=%b wb_en=%b wb_reg=%0d ld_commit=%b creg=%0d ld_pend=%b lreg=%0d EPC=%08h",
			  cycles, s0_d, dut.cpu.R[16], pc, dut.cpu.st, dut.cpu_ce, dut.dma_hog, dut.cpu.wb_en, dut.cpu.wb_reg,
			  dut.cpu.ld_commit, dut.cpu.ld_creg, dut.cpu.ld_pend, dut.cpu.ld_reg, dut.cpu.EPC);
		end
	end
	always @(posedge clk) if (!rst && dut.cpu.st == 3'd5 && dut.cpu_ce && cycles > 600_000_000 && excs < 300) begin
		excs = excs + 1;
		$display("  EXC @%0d pc=%08h code=%0d s0=%08h commit=%b creg=%0d pend=%b lreg=%0d hog=%b",
		  cycles, pc, dut.cpu.exc_code, dut.cpu.R[16], dut.cpu.ld_commit, dut.cpu.ld_creg, dut.cpu.ld_pend, dut.cpu.ld_reg, dut.dma_hog);
	end
	// rfe: opcode 010000, bit 25 set, function 010000
	always @(posedge clk) if (!rst && dut.cpu.st == 3'd1 && dut.cpu_ce && cycles > 600_000_000 && excs < 300 &&
	                          dut.cpu.din[31:25] == 7'b0100001 && dut.cpu.din[5:0] == 6'h10) begin
		excs = excs + 1;
		$display("  RFE @%0d pc=%08h s0=%08h s1=%08h s2=%08h k0=%08h SR=%08h", cycles, pc, dut.cpu.R[16], dut.cpu.R[17], dut.cpu.R[18], dut.cpu.R[26], dut.cpu.SR);
	end
	always @(posedge clk) if (!rst && cycles > 500_000_000 && dut.cpu.st == 3'd3 && dut.cpu_ce && pc == 32'h800308c0 && dut.c_addr[20:0] == 21'h138cd0)
		$display("  MEMCPY-138ca8 @%0d (copying from 138ccc)", cycles);
	always @(posedge clk) if (!rst && cycles > 500_000_000 && dut.u_dma.dbg_node_v && dut.u_dma.dbg_node_addr == 24'h138ca8)
		$display("  DMA-HDRREAD @%0d hdr=%08h", cycles, dut.u_dma.dbg_node_hdr);
	task dump_frame; input integer n; begin : df
		reg [255:0] name;
		$sformat(name, "../../build/sim/bios_frame_%0d.bin", n);
		ffd = $fopen(name, "wb"); fnz = 0;
		for (fi = 0; fi < 320*240; fi = fi + 1) begin $fwrite(ffd, "%c", frame[fi]); if (frame[fi] != 0) fnz = fnz + 1; end
		$fclose(ffd);
		$display("  FRAME %0d dumped at cycle %0d: %0d non-zero pixels, disp_on=%b disp=(%0d,%0d) draw=(%0d,%0d)", n, cycles, fnz,
		  dut.gpu.disp_on, dut.gpu.disp_x, dut.gpu.disp_y, dut.gpu.da_x0, dut.gpu.da_y0);
	end endtask
	initial for (fi = 0; fi < 320*240; fi = fi + 1) frame[fi] = 0;
	always @(posedge clk) if (!rst && cpu_run) begin
		// note when a GPU DMA (channel 2) finishes -- busy bit falls
		dma2_busy_d <= dut.u_dma.chcr[2][24];
		if (dma2_busy_d && !dut.u_dma.chcr[2][24])
			$display("  GPU DMA ch2 COMPLETED at cycle %0d (gpu_writes so far %0d)", cycles, gpu_writes);
		// a true stall: the GPU makes no VRAM progress (no v_ack) while a DMA is busy
		if (dut.v_ack) noack_ct = 0;
		else if (dut.u_dma.chcr[2][24]) noack_ct = noack_ct + 1;
		else noack_ct = 0;
		if (noack_ct == 400000) begin
			$display("  *** GPU-DMA CH2 STALL (busy 200k cycles) ***");
			$display("    DMA  st=%0d words=%0d addr=%06h next=%06h chcr2=%08h madr=%06h",
			  dut.u_dma.st, dut.u_dma.words, dut.u_dma.addr, dut.u_dma.next,
			  dut.u_dma.chcr[2], dut.u_dma.madr[2]);
			$display("    GPU  ds=%0d f_wr=%0d f_rd=%0d f_head=%08h dma_ready=%b busy=%b",
			  dut.gpu.ds, dut.gpu.f_wr, dut.gpu.f_rd, dut.gpu.f_head, dut.gpu.dma_ready, dut.gpu.busy);
			$display("    C2V  cx=%0d cy=%0d cw=%0d ch=%0d cxd=%0d cyd=%0d cphase=%b cword=%08h",
			  dut.gpu.cx, dut.gpu.cy, dut.gpu.cw, dut.gpu.ch, dut.gpu.cxd, dut.gpu.cyd, dut.gpu.cphase, dut.gpu.cword);
			$display("    VRAM v_req=%b v_we=%b v_ack=%b v_addr=%08h",
			  dut.gpu.v_req, dut.gpu.v_we, dut.v_ack, dut.gpu.v_addr);
			$display("    VCACHE st=%0d srvB=%b a_req=%b a_ack=%b b_req=%b b_ack=%b m_req=%b m_ready=%b m_valid=%b",
			  dut.vcache.st, dut.vcache.serving_b, dut.vcache.a_req, dut.vcache.a_ack,
			  dut.vcache.b_req, dut.vcache.b_ack, dut.vc_m_req, dut.vc_m_ready, dut.vc_m_valid);
			$display("    SCANOUT s_req=%b s_ack=%b s_addr=%08h",
			  dut.gpu.s_req, dut.s_ack, dut.gpu.s_addr);
			$display("    CCACHE st=%0d srvB=%b m_req=%b m_ready=%b   ARB d_req=%b d_we=%b d_ready=%b d_valid=%b d_addr=%06h",
			  dut.ccache.st, dut.ccache.serving_b, dut.cc_m_req, dut.cc_m_ready,
			  d_req, d_we, d_ready, d_valid, d_addr);
			$display("    ARBQ q_head=%0d q_tail=%0d q_empty=%b (full if head==tail with 16 outstanding)  dvalid_count=%0d",
			  dut.arb.q_head, dut.arb.q_tail, (dut.arb.q_head==dut.arb.q_tail), dvalid_ct);
			$finish;
		end
	end

	// count exceptions the CPU takes, by code -- a COP2 (GTE) instruction with
	// no decoder becomes a reserved-instruction exception (code 10)
	integer exc_total, exc_ri, exc_cop2seen;
	reg [31:0] first_cop2_pc;
	initial begin exc_total=0; exc_ri=0; exc_cop2seen=0; first_cop2_pc=0; end
	always @(posedge clk) if (!rst && dut.cpu.st == 3'd5) begin   // S_EXC
		exc_total = exc_total + 1;
		if (dut.cpu.exc_code == 5'd10) exc_ri = exc_ri + 1;
	end
	// spot a COP2 opcode being fetched (op 0x12)
	always @(posedge clk) if (!rst && dut.cpu.st == 3'd1 && dut.cpu.din[31:26] == 6'h12 && exc_cop2seen == 0) begin
		exc_cop2seen = 1; first_cop2_pc = dut.cpu.PC;
	end

	initial begin
		// The board's DDR3 powers up holding garbage, and zeroed memory hides
		// every write that never lands: VRAM and RAM start random here too.
		for (i = 0; i < 262144; i = i + 1) mem[i] = {$random, $random, $random, $random};
		// RAM as the board had it (dumped after its crash): the BIOS rewrites what it
		// uses, and what it never writes -- the garbage the templates' tags come from
		// -- is then identical, so the sim follows the board's exact path
		$readmemh("../../sim/roms/ps1/ram_board.hex", mem, 24'h01_0000);
		for (i = 0; i < 65536; i = i + 1) mem[i] = 128'd0;     // VRAM after the sweep
		$readmemh("../../sim/roms/ps1/bios.hex", bios);
		// pack into lines at BIOS_LINE (0x30000)
		for (i = 0; i < 131072; i = i + 4)
			mem[24'h03_0000 + (i >> 2)] =
				{bios[i+3], bios[i+2], bios[i+1], bios[i+0]};

		gpu_writes = 0;
		repeat (6) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);
		cpu_run = 1;               // let the CPU go from the reset vector
		// trace the first instructions
		begin : early
			reg [31:0] lp2; integer sh;
			lp2 = 32'hFFFFFFFF; sh = 0;
			while (sh < 40) begin
				@(posedge clk);
				if (dut.cpu.st == 3'd1 && pc != lp2) begin
					$display("    [%0d] pc=%08h din=%08h  cached=%b bios_hit=%b ram_hit=%b cc_ack=%b",
					  sh, pc, dut.cpu.din, dut.cached, dut.bios_hit, dut.ram_hit, dut.cc_ack);
					lp2 = pc; sh = sh + 1;
				end
			end
		end

		lo_pc = 32'hFFFFFFFF; hi_pc = 0; distinct = 0; last_pc = 0;
		derailed = 0;
		for (cycles = 0; cycles < 2_100_000_000; cycles = cycles + 1) begin
			@(posedge clk);
			if (cycles % 50_000_000 == 49_999_999) dump_frame(cycles / 50_000_000);
			if (pc != last_pc) begin
				distinct = distinct + 1;
				if (pc < lo_pc) lo_pc = pc;
				// announce the moment it climbs past the RAM-clear loop (bfc00324)
				if (pc > 32'hbfc00330 && pc[31:12]==20'hbfc00 && pc > hi_pc && hi_pc <= 32'hbfc00330)
					$display("  PROGRESS: past the RAM-clear loop, now at pc=%08h (cycle %0d)", pc, cycles);
				if (pc > hi_pc) hi_pc = pc;
				ring[rp] = pc; ripc[rp] = dut.cpu.ir; rp = (rp+1) % 32;
				// first time PC leaves 0xbfc0xxxx into 0xc0+ (a jump gone wrong)
				if (!derailed && ((pc[31:29]==3'b100 && pc[28:21]!=8'd0) || pc[1:0]!=2'b00 || (dut.cpu.st==3'd5 && dut.cpu.exc_code==5'd4))) begin
					derailed = 1;
					$display("  DERAIL to %08h at cycle %0d. Last 32 committed (pc: instr):", pc, cycles);
					for (di = 0; di < 32; di = di + 1)
						$display("    %08h : %08h", rring[(rrp+di)%32], rrip[(rrp+di)%32]);
				end
				last_pc = pc;
			end
		end

		$display("  STATE: dma st=%0d cur=%0d words=%0d next=%06h chcr2=%08h chcr6=%08h | gpu ds=%0d busy=%b f_wr=%0d f_rd=%0d cmd=%02h rd_have=%b | wc st=%0d acc_v=%b c_req=%b | vcache st=%0d srvB=%b | ccache st=%0d | irq_src=%b I_STAT=%08h I_MASK=%08h cpu_irq=%b SR=%08h",
		  dut.u_dma.st, dut.u_dma.cur, dut.u_dma.words, dut.u_dma.next, dut.u_dma.chcr[2], dut.u_dma.chcr[6],
		  dut.gpu.ds, dut.gpu.busy, dut.gpu.f_wr, dut.gpu.f_rd, dut.gpu.cmd, dut.gpu.rd_have,
		  3'd0, 1'b0, dut.c_req, dut.vcache.st, dut.vcache.serving_b, dut.ccache.st,
		  dut.irq_src, dut.u_irq.stat, dut.u_irq.mask, dut.cpu_irq, dut.cpu.SR);
		// what is it doing at the end? sample a window of PCs and I/O hits
		$display("  --- final 24 distinct PCs ---");
		begin : tailtrace
			reg [31:0] lp; integer shown;
			lp = 0; shown = 0;
			for (i = 0; i < 200000 && shown < 24; i = i + 1) begin
				@(posedge clk);
				if (pc != lp) begin
					lp = pc;
					$display("    pc=%08h  gpu=%b irq=%b tmr=%b dma=%b cd=%b spu?=%b pad=%b cached=%b",
					  pc, dut.gpu_hit, dut.irq_hit, dut.tmr_hit, dut.dma_hit,
					  dut.cd_hit, dut.io_hit&&(dut.c_addr[15:12]==4'h1)&&(dut.c_addr[11:10]==2'b11),
					  dut.pad_hit, dut.cached);
					shown = shown + 1;
				end
			end
		end
		$display("");
		$display("  final PC          : %08h", pc);
		$display("  PC range visited  : %08h .. %08h", lo_pc, hi_pc);
		$display("  distinct PC steps : %0d", distinct);
		$display("  GPU writes        : %0d", gpu_writes);
		$display("  exceptions taken  : %0d  (reserved-instr: %0d)", exc_total, exc_ri);
		$display("  --- last 32 committed instructions (pc: instr) ---");
		for (di = 0; di < 32; di = di + 1)
			$display("      %08h : %08h", rring[(rrp+di)%32], rrip[(rrp+di)%32]);
		$display("  first COP2 opcode : %s at PC %08h", exc_cop2seen?"YES":"no", first_cop2_pc);
		$display("  reached RAM (PC<2MB or accessed RAM)? checking hi_pc/lo_pc");
		// A BIOS that boots runs code in the BIOS window AND in RAM (the kernel
		// it relocates). Reaching RAM means it copied and jumped -- real progress.
		if (distinct > 1000 && (lo_pc < 32'h0020_0000))
			$display("tb_ps1_bios_run2: PASS -- CPU ran BIOS and reached relocated RAM code");
		else if (distinct > 1000)
			$display("tb_ps1_bios_run2: PARTIAL -- CPU ran the BIOS (%0d PCs) but stayed in ROM", distinct);
		else
			$display("tb_ps1_bios_run2: STUCK -- only %0d distinct PCs, last %08h", distinct, pc);
		$finish;
	end
endmodule

`default_nettype wire
