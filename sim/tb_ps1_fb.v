//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_fb - the display frame in DDR3: the GPU fills four coloured quarters of
// a 320x240 display, the host asks for a capture, and the frame in DDR3 (and the
// host read-back port) must show those colours at full resolution in RGB555.
//   ./tools/sim.sh tb_ps1_fb
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps
module tb_ps1_fb;
	reg clk = 0, rst = 1, cpu_run = 0;
	always #10 clk = ~clk;
	reg [18:0] host_windex = 0; reg host_we = 0; reg [31:0] host_wdata = 0;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata, d_rdata;
	wire [15:0]  d_wmask;
	wire [127:0] d_bm = {{8{d_wmask[15]}}, {8{d_wmask[14]}}, {8{d_wmask[13]}}, {8{d_wmask[12]}}, {8{d_wmask[11]}}, {8{d_wmask[10]}}, {8{d_wmask[9]}}, {8{d_wmask[8]}}, {8{d_wmask[7]}}, {8{d_wmask[6]}}, {8{d_wmask[5]}}, {8{d_wmask[4]}}, {8{d_wmask[3]}}, {8{d_wmask[2]}}, {8{d_wmask[1]}}, {8{d_wmask[0]}}}; wire d_ready;
	reg d_valid = 0; reg [127:0] d_rdata_r = 0; assign d_rdata = d_rdata_r;
	wire px_valid; wire [8:0] px_x, px_y; wire [7:0] px_rgb; wire [31:0] pc;
	reg fb_cap_go = 0; wire fb_cap_ready; wire [9:0] fb_width; wire [8:0] fb_height;
	reg [17:0] fbr_addr = 0; reg fbr_req = 0; wire [31:0] fbr_rdata; wire fbr_ack;
	ps1_top dut (
		.cpu_halt(1'b0),   // nothing halts the processor in simulation
		.gte_old(4'd0),
		.clk(clk), .rst(rst), .cpu_run(cpu_run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid), .d_calibrated(1'b1),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb), .dbg_pc(pc),
		.fb_cap_go(fb_cap_go), .fb_cap_ready(fb_cap_ready), .fb_width(fb_width), .fb_height(fb_height),
		.fbr_addr(fbr_addr), .fbr_req(fbr_req), .fbr_rdata(fbr_rdata), .fbr_ack(fbr_ack),
		// the two fast answer paths, both on
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b1), .gpu_fast(1'b1), .no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0), .cd_disc_in(1'b0), .cd_sb_we(1'b0), .cd_sb_addr(12'd0), .cd_sb_data(8'd0), .cd_sb_done(1'b0), .cd_sb_lba(24'd0),
		// the straight-to-network picture path, idle in this bench
		.fs_en(1'b0), .fs_arm(1'b0), .fs_empty(), .fs_rd(1'b0), .fs_data(), .fs_valid(),
		.dbg_icv_pc(), .dbg_icv_got(), .dbg_icv_want(), .dbg_icv_n()
	);
	reg [127:0] mem [0:524287];       // 8 MB: the frame lives at 4 MB
	localparam LAT = 14;
	reg busy = 0; reg [4:0] wait_ct = 0; reg pend_we = 0; reg [23:0] pend_addr = 0;
	assign d_ready = d_req && !busy;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req && d_ready) begin busy <= 1; wait_ct <= LAT; pend_we <= d_we; pend_addr <= d_addr; if (d_we) mem[d_addr[18:0]] <= (mem[d_addr[18:0]] & ~d_bm) | (d_wdata & d_bm); end
		else if (busy) begin if (wait_ct != 0) wait_ct <= wait_ct - 1; else begin busy <= 0; if (!pend_we) begin d_valid <= 1; d_rdata_r <= mem[pend_addr[18:0]]; end end end
	end
	reg [31:0] prog [0:1023];
	integer i, cycles, errors, k;
	function [15:0] fbpx; input integer x, y; reg [127:0] l; begin
		l = mem[24'h04_0000 + y * 80 + x / 8]; fbpx = l[(x % 8) * 16 +: 16]; end endfunction
	function [15:0] want; input integer x, y; begin
		want = (y < 120) ? ((x < 160) ? 16'h001F : 16'h03E0) : ((x < 160) ? 16'h7C00 : 16'h7FFF); end endfunction
	task check; input cond; input [8*64:1] msg; begin
		if (cond) $display("  ok   %0s", msg); else begin errors = errors + 1; $display("  FAIL %0s", msg); end end endtask
	task hostread; input [17:0] a; output [31:0] v; begin
		@(posedge clk); fbr_addr <= a; fbr_req <= 1;
		@(posedge clk); while (!fbr_ack) @(posedge clk); v = fbr_rdata;
		fbr_req <= 0; @(posedge clk); @(posedge clk); end endtask
	reg [31:0] v0, v1;
	// the video cache behind the write combiner: how line writes are served
	integer wa_n = 0, alloc_n = 0, wb_n = 0, fill_n = 0, lw_n = 0, lwfull_n = 0;
	reg [3:0] vst_d = 0;
	always @(posedge clk) begin
		vst_d <= dut.vcache.st;
		if (dut.vcache.st == 4'd15 && vst_d != 4'd15) wa_n = wa_n + 1;
		if (dut.vcache.st == 4'd7  && vst_d != 4'd7)  alloc_n = alloc_n + 1;
		if (dut.vcache.st == 4'd2  && vst_d != 4'd2)  wb_n = wb_n + 1;
		if (dut.vcache.st == 4'd4  && vst_d != 4'd4)  fill_n = fill_n + 1;
		if (dut.vcache.a_req && dut.vcache.a_we && dut.vcache.a_lwe && dut.vcache.a_ack) begin
			lw_n = lw_n + 1;
			if (&dut.vcache.a_be16) lwfull_n = lwfull_n + 1;
		end
	end

	reg p_trace = 0;
	integer p_ss = 0, p_capt = 0, p_flv = 0, p_flt = 0, p_pxv = 0, p_push = 0, p_wr = 0, p_armed = 0;
	always @(posedge clk) begin
		if (dut.gpu.scan_start) begin p_ss = p_ss + 1; if (dut.u_fb.armed) p_armed = p_armed + 1; end
		if (dut.u_fb.capturing) p_capt = p_capt + 1;
		if (dut.gpu.fl_valid) p_flv = p_flv + 1;
		if (dut.u_fb.fl_take) p_flt = p_flt + 1;
		if (dut.gpu.fpx_valid) p_pxv = p_pxv + 1;
		if (dut.u_fb.push) p_push = p_push + 1;
		if (dut.u_fb.m_req && dut.u_fb.m_we && dut.u_fb.m_ready) begin
			p_wr = p_wr + 1;
			if (p_trace && (p_wr < 4 || p_wr == 4000 || p_wr == 9600 || p_wr == 9601 || p_wr == 19199))
				$display("    fb write #%0d: line %06x data %032x  (fl_y=%0d fl_x=%0d sy=%0d sc_field=%0d d_addr=%06x d_we=%0d)", p_wr, dut.u_fb.m_addr, dut.u_fb.m_wdata, dut.gpu.fl_y, dut.gpu.fl_x, dut.gpu.sy, dut.gpu.sc_field, dut.d_addr, dut.d_we);
		end
	end
	initial begin
		errors = 0;
		for (i = 0; i < 524288; i = i + 1) mem[i] = {$random, $random, $random, $random};
		for (i = 0; i < 1024; i = i + 1) prog[i] = 32'd0;
		$readmemh("../../sim/roms/ps1/fbtest.hex", prog);
		for (i = 0; i < 1024; i = i + 4) mem[24'h03_0000 + (i >> 2)] = {prog[i+3], prog[i+2], prog[i+1], prog[i]};
		repeat (6) @(posedge clk); rst = 0; repeat (4) @(posedge clk); cpu_run = 1;
		// wait for the program to reach its done loop (display on)
		cycles = 0;
		while (!(dut.c_addr == 32'h1F80A000 && dut.c_req) && cycles < 4_000_000) begin @(posedge clk); cycles = cycles + 1; end
		check(cycles < 4_000_000, "the program filled VRAM and turned the display on");
		// ask for a frame
		@(posedge clk); fb_cap_go <= 1; @(posedge clk); fb_cap_go <= 0; @(posedge clk); @(posedge clk);
		cycles = 0;
		while (!fb_cap_ready && cycles < 6_000_000) begin @(posedge clk); cycles = cycles + 1; end
		check(fb_cap_ready, "the capture completed");
		$display("  capture took %0d cycles; width=%0d height=%0d", cycles, fb_width, fb_height);
		check(fb_width == 10'd320 && fb_height == 9'd240, "the frame is reported as 320 x 240");
		// the four quarters, sampled in DDR3
		k = 0;
		for (i = 0; i < 240; i = i + 7) begin
			if (fbpx(20, i) != want(20, i)) k = k + 1;
			if (fbpx(300, i) != want(300, i)) k = k + 1;
			if (fbpx(159, i) != want(159, i)) k = k + 1;
			if (fbpx(160, i) != want(160, i)) k = k + 1;
		end
		check(k == 0, "every sampled pixel in DDR3 has its quarter's colour");
		if (k != 0) $display("    (%0d mismatches; px(20,0)=%04h px(300,0)=%04h px(20,200)=%04h px(300,200)=%04h)", k, fbpx(20,0), fbpx(300,0), fbpx(20,200), fbpx(300,200));
		// the host read port: word 0 = pixels (0,0),(1,0); word 79 = pixels (158,0),(159,0); row 200 word 90 = (180,200),(181,200)
		// --- 480i with drawing to the display area prohibited: the field rule ---
		// (the board's BIOS menu mode; the capture then reads the on-screen field)
		for (i = 24'h04_0000; i < 24'h04_0000 + 240 * 80; i = i + 1) mem[i] = 128'd0;
		dut.gpu.vres480 = 1'b1; dut.gpu.interlace = 1'b1; dut.gpu.draw_display = 1'b0;
		p_wr = 0; p_trace = 1;
		repeat (10) @(posedge clk);
		@(posedge clk); fb_cap_go <= 1; @(posedge clk); fb_cap_go <= 0; @(posedge clk); @(posedge clk);
		cycles = 0;
		while (!fb_cap_ready && cycles < 6_000_000) begin @(posedge clk); cycles = cycles + 1; end
		check(fb_cap_ready, "480i: the capture completed");
		$display("    probes: scan_start %0d, capturing cycles %0d, fl_valid %0d, fl_take %0d, px_valid %0d, pushes %0d, fb writes accepted %0d, armed-at-start %0d, sc_lmode %0d, il_skip %0d", p_ss, p_capt, p_flv, p_flt, p_pxv, p_push, p_wr, p_armed, dut.gpu.sc_lmode, dut.gpu.il_skip);
		$display("  480i capture took %0d cycles", cycles);
		k = 0;
		// (the field is every other VRAM row, and the program filled rows 0..239 only,
		//  so the capture's rows 0..119 are the ones with a picture in them)
		for (i = 0; i < 120; i = i + 7) if (fbpx(20, i) == 16'd0 || fbpx(300, i) == 16'd0) k = k + 1;
		check(k == 0, "480i: the capture landed in DDR3 (no row left at zero)");
		if (k != 0) $display("    (%0d zero samples; px(20,0)=%04h px(300,100)=%04h)", k, fbpx(20,0), fbpx(300,100));
		// and 640 wide, as the menu is: the two-lines-per-output-line path
		for (i = 24'h04_0000; i < 24'h04_0000 + 240 * 80; i = i + 1) mem[i] = 128'd0;
		dut.gpu.hres = 2'd3;
		repeat (10) @(posedge clk);
		@(posedge clk); fb_cap_go <= 1; @(posedge clk); fb_cap_go <= 0; @(posedge clk); @(posedge clk);
		cycles = 0;
		while (!fb_cap_ready && cycles < 6_000_000) begin @(posedge clk); cycles = cycles + 1; end
		check(fb_cap_ready, "480i 640-wide: the capture completed");
		$display("  480i 640-wide capture took %0d cycles; reported %0d x %0d", cycles, fb_width, fb_height);
		k = 0;
		// (640 wide is captured at half width: capture x 150 is VRAM x 300, inside the program's 320)
		for (i = 0; i < 120; i = i + 7) if (fbpx(20, i) == 16'd0 || fbpx(150, i) == 16'd0) k = k + 1;
		check(k == 0, "480i 640-wide: the capture landed in DDR3");
		if (k != 0) $display("    (%0d zero samples; px(20,0)=%04h px(300,100)=%04h)", k, fbpx(20,0), fbpx(300,100));
		dut.gpu.hres = 2'd1; dut.gpu.vres480 = 1'b0; dut.gpu.interlace = 1'b0;
		for (i = 24'h04_0000; i < 24'h04_0000 + 240 * 80; i = i + 1) mem[i] = 128'd0;
		@(posedge clk); fb_cap_go <= 1; @(posedge clk); fb_cap_go <= 0; @(posedge clk); @(posedge clk);
		cycles = 0;
		while (!fb_cap_ready && cycles < 6_000_000) begin @(posedge clk); cycles = cycles + 1; end
		hostread(18'd0, v0);  check(v0 == 32'h001F_001F, "host reads word 0 as two red pixels");
		hostread(18'd79, v1); check(v1 == 32'h001F_001F, "and word 79 (still red)");
		hostread(18'd80, v1); check(v1 == 32'h03E0_03E0, "and word 80 (green)");
		hostread(18'd200 * 320 + 90, v1); check(v1 == 32'h7FFF_7FFF, "and row 200, word 90 (white)");
		$display("    video cache: %0d line writes (%0d full) -> write-around %0d, allocate %0d, write-back %0d, fill %0d", lw_n, lwfull_n, wa_n, alloc_n, wb_n, fill_n);
		if (errors == 0) $display("tb_ps1_fb: all checks passed"); else $display("tb_ps1_fb: %0d FAIL(s)", errors);
		$finish;
	end
endmodule
`default_nettype wire
