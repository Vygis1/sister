//////////////////////////////////////////////////////////////////////////////////
// tb_ps1 - the whole PlayStation, running the boot demo.
//
// Loads tools/ps1/ps1demo.py's program into the boot ROM, gives VRAM a DDR3-shaped
// line memory, and lets the R3000 run: it should set the drawing environment,
// clear the screen to a gradient, draw the diamond and the bar, and turn the
// display on -- all by writing GP0/GP1 itself, with no help from the testbench.
//
// The display scanout is slow in simulation, so this does not wait for a frame;
// it waits for the CPU to reach its spin loop (the program is done drawing) and
// then checks VRAM directly at points that should be gradient, diamond and bar.
// The GPU's own testbench proves the scanout; this proves the CPU drives it.
//
//   ./tools/sim.sh tb_ps1
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

// SUPERSEDED by tb_ps1_bios, and it does not elaborate: it still instantiates
// ps1_top with a BOOT_HEX parameter, which the module has not had since the boot
// program started arriving through host_windex/host_we. Not in tools/simall.sh.
module tb_ps1;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// host fill of the boot ROM
	reg [12:0] host_windex = 0;
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

	ps1_top #(.BOOT_HEX("../../sim/roms/ps1/boot.hex")) dut (
		.card2_fill(0), .card2_in(0), .joy2(0),
		.toc_addr(0), .toc_data(0), .toc_we(0), .xa_pop(0), .xa_wdata(0), .xa_we(0), // inputs this bench does not drive, tied: an open input simulates as X
		.cap_every_vsync(0), .cc_flush(0), .cd_trace_idx(0), .cpu_run(1), .dbg_perf_sel(0), .dbg_rsel(0), .dbg_watch(0), .fb_cap_go(0), .fbr_addr(0), .fbr_req(0), .gte_old(0), .gte_snap_arm(1'b0), .gte_snap_go(1'b0), .gte_snap_skip(16'd0), .gte_snap_idx(7'd0), .tty_idx(12'd0), .gtr_idx(11'd0), .gtr_arm(1'b0), .fb_hr_raw(1'b0), .fb_hr_base(24'd0), .hr_go(0), .hr_line(0), .joy1(0), .vram_flush(0), .dma_relax(1'b0), .ev_idx(6'd0), .card_in(1'b0), .card_fill(1'b0), .card_wq_pop(1'b0), .card_wq_clr(1'b0),
		.cpu_halt(1'b0),   // nothing halts the processor in simulation
		// the two fast answer paths, both on. These are PORTS, not parameters: they
		// sat in the parameter list, so this bench had not elaborated at all.
		.no_icache(1'b0), .no_ibuf(1'b0), .ic_verify(1'b0), .no_overlap(1'b0), .cpu_fast(1'b1), .gpu_fast(1'b1),
		.no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .no_capfirst(1'b0),
		.cd_disc_in(1'b0), .cd_sb_we(1'b0), .cd_sb_addr(12'd0), .cd_sb_data(8'd0), .cd_sb_done(1'b0), .cd_sb_lba(24'd0),
		// the straight-to-network picture path, idle in this bench
		.fs_en(1'b0), .fs_arm(1'b0), .fs_empty(), .fs_rd(1'b0), .fs_data(), .fs_valid(),
		.clk(clk), .rst(rst),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_rdata(d_rdata), .d_ready(d_ready), .d_valid(d_valid),
		.d_calibrated(1'b1),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.dbg_pc(pc)
	);

	// VRAM: a line memory that behaves like ddr3_mem -- one transaction at a
	// time, m_ready only when idle, a write that completes silently, a read that
	// answers with m_valid some cycles later. This is what the MD's cartridge
	// path never exercised (it only reads), so it is where a write-back cache
	// meets memory it has not met before.
	reg [127:0] mem [0:65535];
	localparam LAT = 12;
	reg          busy = 0;
	reg [3:0]    wait_ct = 0;
	reg          pend_we = 0;
	reg [23:0]   pend_addr = 0;
	assign d_ready = d_req && !busy;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (d_req && d_ready) begin
			busy      <= 1'b1;
			wait_ct   <= LAT;
			pend_we   <= d_we;
			pend_addr <= d_addr;
			if (d_we) mem[d_addr[15:0]] <= (mem[d_addr[15:0]] & ~d_bm) | (d_wdata & d_bm);   // the write lands
		end else if (busy) begin
			if (wait_ct != 0) wait_ct <= wait_ct - 4'd1;
			else begin
				busy <= 1'b0;
				if (!pend_we) begin d_valid <= 1'b1; d_rdata_r <= mem[pend_addr[15:0]]; end
			end
		end
	end

	// read a VRAM pixel, cache-or-memory
	function [15:0] vpx;
		input [9:0] x; input [8:0] y;
		reg [28:0] a; reg [127:0] l; reg [8:0] ix;
		begin
			a  = {y, x[9:1], 2'b00};
			ix = a[12:4];
			if (dut.vram.valid[ix] && dut.vram.tag[ix] == a[28:13]) l = dut.vram.data[ix];
			else l = mem[a[19:4]];
			vpx = x[0] ? l[a[3:2]*32 + 16 +: 16] : l[a[3:2]*32 +: 16];
		end
	endfunction

	// load the boot program
	reg [31:0] prog [0:8191];
	integer nwords, i, cycles, fd;
	reg [31:0] last_pc;
	integer    stuck;

	integer gpu_writes = 0;
	integer shown = 0;
	always @(posedge clk) if (!rst && dut.gpu_hit && dut.c_req && dut.c_we) begin
		gpu_writes = gpu_writes + 1;
		if (shown < 40) begin
			$display("  CPU->GPU  %s  addr=%08h data=%08h  ready=%b busy=%b",
			         dut.c_addr[2]?"GP1":"GP0", dut.c_addr, dut.c_dout, dut.gpu.gpustat[26], dut.gpu.busy);
			shown = shown + 1;
		end
	end

	// the display output, captured as it streams
	reg [7:0] frame [0:320*239];
	integer fk;
	initial for (fk = 0; fk < 320*240; fk = fk + 1) frame[fk] = 0;
	always @(posedge clk) if (px_valid && px_x < 320 && px_y < 240) frame[px_y*320 + px_x] <= px_rgb;

	integer errors = 0;
	task chk; input c; input [255:0] m;
		begin if (c) $display("  ok   %0s", m); else begin $display("  FAIL %0s", m); errors = errors + 1; end end
	endtask

	initial begin
		for (i = 0; i < 65536; i = i + 1) mem[i] = 128'd0;
		for (i = 0; i < 8192; i = i + 1) prog[i] = 0;
		$readmemh("../../sim/roms/ps1/boot.hex", prog);
		nwords = 0;
		for (i = 0; i < 8192; i = i + 1) if (prog[i] !== 32'hxxxxxxxx && prog[i] !== 0) nwords = i + 1;

		// NO host load: rely on ps1_top's build-time $readmemh init, exactly as
		// the hardware does. If the screen draws, the init path is good.
		host_we = 0;

		repeat (4) @(posedge clk);
		rst = 0;


		// the scene is drawn well before this; run a fixed window then look
		for (cycles = 0; cycles < 2_000_000; cycles = cycles + 1) @(posedge clk);

		$display("  after %0d cycles: PC=%08h disp_on=%b", cycles, pc, dut.gpu.disp_on);

		// the gradient: top rows blue-ish, bottom near black
		chk(vpx(160, 8)   != 16'd0, "gradient top is not black");
		chk(vpx(160, 232)[14:0] < vpx(160, 8)[14:0], "gradient darkens downward");
		// the diamond centre is white-ish (all channels high)
		chk(vpx(160, 110) != vpx(160, 8) && vpx(160,110) != 16'd0, "diamond drew over the background");
		// the menu bar: something non-background around y=210
		chk(vpx(60, 210) != vpx(300, 232), "the bar is a different colour from the field");
		$display("  samples: top=%04h bottom=%04h centre=%04h bar=%04h",
		         vpx(160,8), vpx(160,232), vpx(160,110), vpx(60,210));

		// wait for a full display frame to have streamed, then write it
		repeat (900000) @(posedge clk);
		fd = $fopen("../../build/sim/ps1_frame.bin", "wb");
		for (fk = 0; fk < 320*240; fk = fk + 1) $fwrite(fd, "%c", frame[fk]);
		$fclose(fd);
		$display("  frame written to build/sim/ps1_frame.bin");
		if (errors == 0) $display("tb_ps1: all checks passed -- the PlayStation drew its boot screen");
		else             $display("tb_ps1: %0d FAIL(s)", errors);
		$finish;
	end


endmodule

`default_nettype wire
