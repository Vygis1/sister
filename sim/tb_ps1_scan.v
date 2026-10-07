//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_scan - does the capture read out what is actually in video memory?
//
// Every PlayStation picture fault so far has been chased in the drawing engine.
// This asks the other half of the question, and asks it in a way that cannot be
// argued with: video memory is filled with a pattern that says where each pixel
// lives -- the top seven bits are its row, the bottom nine its column -- and
// then the scanout is made to capture frames. Nothing draws into the window, so
// every pixel the scanout emits has exactly one right answer, and a wrong one
// names the pixel it came from instead. A word held over from an earlier
// address shows up as a column or a row that is off by a known amount.
//
// The scenarios are the ones the board is actually in: a 512-wide double
// buffered game, a 320-wide one, slow memory, the network holding the capture
// off (scan_hold), the drawing engine competing for the same cache, and the
// display flipping buffers in the middle of a capture.
//
//   ./tools/sim.sh tb_ps1_scan
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_ps1_scan;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// --- the register bus into the GPU ----------------------------------------------
	reg        sel = 0, we = 0, a4 = 0;
	reg [31:0] wdata = 0;
	wire [31:0] rdata;

	wire        dma_ready;
	wire [31:0] dma_rdata;
	wire        dma_rvalid;

	wire [28:0] v_addr, s_addr;
	wire        v_req, v_we, s_req;
	wire [127:0] s_vline;
	wire [3:0]  v_be;
	wire [31:0] v_wdata, v_rdata, s_rdata;
	wire        v_lwe;
	wire [127:0] v_wdata128;
	wire        v_around, x_valid;
	wire [24:0] x_addr;
	wire [127:0] x_line;
	wire [127:0] v_line;
	wire        v_ack, s_ack;

	wire        px_valid;
	wire [8:0]  px_x, px_y;
	wire [7:0]  px_rgb;
	wire        vblank, hblank, dot_ce, irq;

	// the full-width picture: this is what the frame streamer and DDR3 both take
	wire        fpx_valid;
	wire [9:0]  fpx_x;
	wire [8:0]  fpx_y;
	wire [15:0] fpx_rgb;
	wire        scan_start, scan_done, scan_busy;
	reg         scan_hold = 1'b0;

	wire v_lin_w, g_lin_w;
	ps1_gpu gpu ( .every_flip(1'b0), .v_lin(v_lin_w),
		.clk(clk), .rst(rst),
		.sel(sel), .we(we), .a4(a4), .dma_active(1'b0), .cap_every_vsync(1'b1), .gpu_fast(1'b1),
		.no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .wdata(wdata), .rdata(rdata),
		.dma_wr(1'b0), .dma_data(32'd0), .dma_ready(dma_ready),
		.dma_rd(1'b0), .dma_rdata(dma_rdata), .dma_rvalid(dma_rvalid),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack),
		.s_addr(s_addr), .s_req(s_req), .s_rdata(s_rdata), .s_ack(s_ack), .s_line(s_vline),
		.scan_hold(scan_hold), .scan_enable(1'b1), .scan_lines(1'b0),
		.tx_valid(x_valid), .tx_addr(x_addr), .tx_line(x_line), .v_around(v_around),
		.fl_valid(), .fl_data(), .fl_x(), .fl_y(),
		.fpx_valid(fpx_valid), .fpx_x(fpx_x), .fpx_y(fpx_y), .fpx_rgb(fpx_rgb),
		.scan_start(scan_start), .scan_done(scan_done), .scan_busy(scan_busy),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.vblank(vblank), .hblank(hblank), .dot_ce(dot_ce), .irq(irq)
	);

	// --- VRAM behind its cache, exactly as on the board ---------------------
	wire [23:0]  m_addr;
	wire         m_req, m_we;
	wire [127:0] m_wdata;
	reg          m_ready;
	reg  [127:0] m_rdata = 0;
	reg          m_valid = 0;
	wire [31:0]  hits, misses;

	wire [28:0]  gp_addr; wire gp_req, gp_around, gp_ack; wire [31:0] gp_rdata; wire [127:0] gp_line;
	wire [23:0]  bk_addr, vc_addr; wire bk_req, bk_we, bk_ready, vc_req, vc_we, vc_ready, vc_valid;
	wire [127:0] bk_wdata, vc_wdata, vc_rdata; wire [15:0] bk_wmask, vc_wmask;
	wire         inv_v; wire [24:0] inv_line; wire bk_busy;
	ps1_vram_port vp ( .v_lin(v_lin_w), .g_lin(g_lin_w),
		.clk(clk), .rst(rst),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(v_around),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack), .eng_idle(!gpu.busy), .host_flush(1'b0), .busy(bk_busy),
		.g_addr(gp_addr), .g_req(gp_req), .g_around(gp_around), .g_rdata(gp_rdata), .g_line(gp_line), .g_ack(gp_ack),
		.m_addr(bk_addr), .m_req(bk_req), .m_we(bk_we), .m_wdata(bk_wdata), .m_wmask(bk_wmask), .m_ready(bk_ready),
		.inv_v(inv_v), .inv_line(inv_line));
	wire [1:0] p_ready, p_valid; wire [255:0] p_rdata;
	assign bk_ready = p_ready[1]; assign vc_ready = p_ready[0]; assign vc_valid = p_valid[0]; assign vc_rdata = p_rdata[127:0];
	mem_arb #(.PORTS(2), .AW(24)) arb (
		.clk(clk), .rst(rst),
		.p_addr({bk_addr, vc_addr}), .p_req({bk_req, vc_req}), .p_we({bk_we, vc_we}),
		.p_wdata({bk_wdata, vc_wdata}), .p_wmask({bk_wmask, vc_wmask}),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid));
	wire [15:0] m_wmask;
	// The parameters the BOARD uses (ps1_top.v's vcache), not smaller ones. With
	// B_NOALLOC off, port B takes the ordinary allocating miss path and never
	// starts a run at all -- the bench then measured a capture that pays a full
	// memory round trip for every line, which is not what the board does, and
	// the run length the whole capture's cost turns on would have been invisible.
	ps1_cache #(.IDXBITS(9), .B_NOALLOC(1), .A_AROUND(1)) vram ( .a_lin(g_lin_w),
		.b_first(scan_busy),
		.flush(1'b0), .flush_busy(), .inv_v(inv_v), .inv_line(inv_line),
		.clk(clk), .rst(rst),
		.a_addr(gp_addr), .a_req(gp_req), .a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0),
		.a_we(1'b0), .a_be(4'hF), .a_wdata(32'd0),
		.a_around(gp_around), .x_valid(x_valid), .x_addr(x_addr), .x_line(x_line),
		.a_rdata(gp_rdata), .a_ack(gp_ack),
		.b_addr(s_addr), .b_req(s_req), .b_we(1'b0), .b_be(4'hF), .b_wdata(32'd0),
		.b_rdata(s_rdata), .b_ack(s_ack), .b_line(s_vline), .a_line(gp_line),
		.m_addr(vc_addr), .m_req(vc_req), .m_we(vc_we), .m_wdata(vc_wdata), .m_wmask(vc_wmask),
		.m_ready(vc_ready), .m_rdata(vc_rdata), .m_valid(vc_valid),
		.dbg_hits(hits), .dbg_misses(misses)
	);

	// --- a megabyte of lines, with a latency the test can change ------------
	localparam MAXRD = 24;
	reg [127:0] mem [0:65535];
	reg [127:0] pd [0:MAXRD-1];
	reg         pv [0:MAXRD-1];
	integer     lat = 6;
	integer pi;
	always @(*) m_ready = m_req;
	always @(posedge clk) begin
		m_valid <= pv[lat-1]; m_rdata <= pd[lat-1];
		for (pi = MAXRD - 1; pi > 0; pi = pi - 1) begin pv[pi] <= pv[pi-1]; pd[pi] <= pd[pi-1]; end
		pv[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) begin
				for (pi = 0; pi < 16; pi = pi + 1)
					if (m_wmask[pi]) mem[m_addr[15:0]][pi*8 +: 8] <= m_wdata[pi*8 +: 8];
			end else begin pv[0] <= 1'b1; pd[0] <= mem[m_addr[15:0]]; end
		end
	end

	// --- the pattern --------------------------------------------------------
	// Sixteen bits that say where the pixel lives: row in the top seven, column
	// in the bottom nine. A capture is at most 640 wide and 240 tall, so inside
	// one frame the value names exactly one pixel -- and a value that is wrong
	// names the pixel the capture actually read.
	function [15:0] pat;
		input [9:0] x; input [8:0] y;
		pat = {y[6:0], x[8:0]};
	endfunction

	task gp0; input [31:0] w; begin
		@(negedge clk); while (gpu.f_full) @(negedge clk);
		sel = 1; we = 1; a4 = 0; wdata = w;
		@(negedge clk); sel = 0; we = 0;
	end endtask
	task gp1; input [31:0] w; begin
		@(negedge clk); sel = 1; we = 1; a4 = 1; wdata = w;
		@(negedge clk); sel = 0; we = 0;
	end endtask

	integer errors = 0;
	task check; input c; input [511:0] what; begin
		if (c) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end
	end endtask

	// --- what came out of the capture ---------------------------------------
	localparam FW = 640, FH = 240;
	reg [15:0] gotv  [0:FW*FH-1];
	reg [31:0] gotg  [0:FW*FH-1];
	reg [31:0] gen = 0;
	integer    npx = 0;
	integer    ovf = 0;

	// the geometry this capture was started with, taken from the scanout itself
	// rather than guessed: a flip in the middle changes what the registers say
	// but not what the capture already committed to.
	reg [9:0] c_x, c_w; reg [8:0] c_y; reg [9:0] c_lines;

	// How long a capture takes, and what it costs the memory. On the board this
	// is the whole problem: a capture that outlasts one of the machine's frames
	// is reading a buffer the game has already started drawing into again, and
	// the bottom of the picture comes back as whatever the game cleared it to.
	// Measured on the board 2026-09-26: 18.67 ms against a console frame of
	// 16.62, and 76% of it spent waiting for video memory.
	integer cap_clks = 0, cap_lines = 0, cap_wait = 0, cap_trips = 0;
	reg     cap_run = 0;
	reg     pfb_dly = 0;
	always @(posedge clk) pfb_dly <= vram.pf_busy;
	always @(posedge clk) begin
		if (scan_start) begin cap_run <= 1'b1; cap_clks <= 0; cap_lines <= 0; cap_wait <= 0; cap_trips <= 0; end
		else if (cap_run) begin
			cap_clks <= cap_clks + 1;
			if (s_req && s_ack) cap_lines <= cap_lines + 1;
			if (s_req && !s_ack) cap_wait <= cap_wait + 1;
			// RUNS the cache started, not requests: a run is PFL back-to-back
			// requests for one round trip, so requests-per-line is 1.0 whether
			// the run works or not. Lines per RUN is the number that tells --
			// four means the capture used all of a run, two means half of every
			// run it paid for was thrown away.
			if (vram.pf_busy && !pfb_dly) cap_trips <= cap_trips + 1;
			if (scan_done) cap_run <= 1'b0;
		end
	end

	always @(posedge clk) begin
		if (scan_start) begin
			gen  <= gen + 1;
			npx  <= 0;
			ovf  <= 0;
			c_x  <= gpu.sc_x; c_y <= gpu.sc_y; c_w <= gpu.sc_w; c_lines <= gpu.sc_lines;
		end else if (fpx_valid) begin
			if (fpx_x < FW && fpx_y < FH) begin
				gotv[fpx_y * FW + fpx_x] <= fpx_rgb;
				gotg[fpx_y * FW + fpx_x] <= gen;
				npx <= npx + 1;
			end else ovf <= ovf + 1;
		end
	end

	integer vx, vy, idx, bad, missing, ow;
	reg [15:0] want16, got16;
	integer shown;

	// Check the frame the capture just finished. `name` says which scenario.
	task verify; input [511:0] name; begin
		bad = 0; missing = 0; shown = 0;
		ow = (c_w > 10'd320) ? (c_w >> 1) : c_w;     // wide pictures come at half width
		for (vy = 0; vy < FH; vy = vy + 1)
			for (vx = 0; vx < ow; vx = vx + 1) begin
				idx = vy * FW + vx;
				want16 = ({1'b0, vy[8:0]} < c_lines)
				         ? pat((c_w > 10'd320) ? (c_x + vx * 2) : (c_x + vx), c_y + vy[8:0])
				         : 16'd0;
				if (gotg[idx] != gen) missing = missing + 1;
				else begin
					got16 = gotv[idx];
					if (got16 !== want16) begin
						bad = bad + 1;
						if (shown < 6) begin
							shown = shown + 1;
							$display("      at column %0d row %0d: wanted %04x (vram %0d,%0d) -- got %04x, which is vram column %0d row %0d",
							         vx, vy, want16,
							         (c_w > 10'd320) ? (c_x + vx*2) : (c_x + vx), c_y + vy[8:0],
							         got16, got16[8:0], got16[15:9]);
						end
					end
				end
			end
		$display("  %0s: %0d pixels, window %0dx%0d at vram %0d,%0d, %0d lines lit",
		         name, npx, ow, FH, c_x, c_y, c_lines);
		$display("      cost: %0d clocks, %0d vram lines read (%0d per row), %0d clocks waiting for them (%0d%%)",
		         cap_clks, cap_lines, cap_lines / FH, cap_wait, (100 * cap_wait) / (cap_clks == 0 ? 1 : cap_clks));
		$display("      %0d runs out to memory -- %0d.%0d lines per run",
		         cap_trips, cap_lines / (cap_trips == 0 ? 1 : cap_trips),
		         (10 * cap_lines / (cap_trips == 0 ? 1 : cap_trips)) % 10);
		if (ovf != 0) $display("      %0d pixels landed outside the frame", ovf);
		check(missing == 0 && bad == 0 && ovf == 0 && npx == ow * FH, name);
		if (missing != 0) $display("      %0d of %0d pixels never arrived", missing, ow * FH);
		if (bad != 0)     $display("      %0d of %0d pixels held the WRONG PIXEL", bad, ow * FH);
	end endtask

	// 24-bit display (GP1(08h) bit 4): pixel n is the three bytes at byte 3n of the row -- red,
	// green, blue -- and goes out as RGB555. Movies are played this way (Gran Turismo 2's intro).
	reg [7:0] b24 [0:2];
	integer bk;
	task verify24; input [511:0] name; begin
		bad = 0; missing = 0; shown = 0;
		ow = (c_w > 10'd320) ? (c_w >> 1) : c_w;
		for (vy = 0; vy < FH; vy = vy + 1)
			for (vx = 0; vx < ow; vx = vx + 1) begin
				idx = vy * FW + vx;
				for (bk = 0; bk < 3; bk = bk + 1) begin
					want16 = pat(c_x + ((((c_w > 10'd320) ? vx * 2 : vx) * 3 + bk) >> 1), c_y + vy[8:0]);
					b24[bk] = ((((c_w > 10'd320) ? vx * 2 : vx) * 3 + bk) & 1) ? want16[15:8] : want16[7:0];
				end
				want16 = ({1'b0, vy[8:0]} < c_lines) ? {1'b0, b24[2][7:3], b24[1][7:3], b24[0][7:3]} : 16'd0;
				if (gotg[idx] != gen) missing = missing + 1;
				else if (gotv[idx] !== want16) begin
					bad = bad + 1;
					if (shown < 6) begin
						shown = shown + 1;
						$display("      24-bit: at column %0d row %0d wanted %04x, got %04x", vx, vy, want16, gotv[idx]);
					end
				end
			end
		$display("  %0s: %0d pixels, window %0dx%0d at vram %0d,%0d", name, npx, ow, FH, c_x, c_y);
		check(missing == 0 && bad == 0 && ovf == 0 && npx == ow * FH, name);
		if (missing != 0) $display("      %0d of %0d pixels never arrived", missing, ow * FH);
		if (bad != 0)     $display("      %0d of %0d pixels held the WRONG PIXEL", bad, ow * FH);
	end endtask

	// Wait for a whole capture, and for one that STARTED after the test asked
	// for it: a capture already running when the display mode was set is half a
	// frame of the old mode, and judging it against the new one is the
	// testbench being wrong, not the hardware. A flip aborts a capture part way
	// through, and the abort is not a failure either -- the next one is what
	// has to be right.
	integer guard;
	reg want24 = 0;
	task capture; input [511:0] name; begin
		guard = 0;
		@(negedge clk);
		while (!scan_start && guard < 40000000) begin @(negedge clk); guard = guard + 1; end
		while (!scan_done && guard < 40000000) begin @(negedge clk); guard = guard + 1; end
		if (guard >= 40000000) begin
			$display("  FAIL %0s: no capture finished", name); errors = errors + 1;
		end else begin
			@(negedge clk);
			if (want24) verify24(name); else verify(name);
		end
	end endtask

	task setmode; input [9:0] dx; input [8:0] dy; input [1:0] hr; begin
		gp1(32'h0800_0000 | {30'd0, hr});
		gp1(32'h0700_0000 | (32'd240 << 10));
		gp1(32'h0500_0000 | {22'd0, dx} | ({23'd0, dy} << 10));
		gp1(32'h0300_0000);                      // display on
	end endtask

	integer k;
	integer hold_on = 0;
	integer draw_on = 0;
	reg [31:0] rnd = 32'h1234_5678;

	// the network holding the capture off, as fb_stream's `hold` does
	always @(posedge clk) begin
		rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
		scan_hold <= hold_on && rnd[7:5] == 3'd0;
	end

	// the drawing engine working in a different part of VRAM while the capture
	// runs: the two share one cache, and this is what evicts the capture's lines
	initial begin
		forever begin
			@(negedge clk);
			if (draw_on) begin
				gp0(32'h0200_1020); gp0({16'd300, 16'd0}); gp0({16'd40, 16'd640});
				gp0(32'h0200_2040); gp0({16'd360, 16'd0}); gp0({16'd40, 16'd640});
			end
		end
	end

	initial begin
		for (k = 0; k < 65536; k = k + 1) begin
			// line k holds the eight pixels starting at column (k & 127) * 8 of row k >> 7
			mem[k] = {pat((k[6:0]*8)+7, k[15:7]), pat((k[6:0]*8)+6, k[15:7]),
			          pat((k[6:0]*8)+5, k[15:7]), pat((k[6:0]*8)+4, k[15:7]),
			          pat((k[6:0]*8)+3, k[15:7]), pat((k[6:0]*8)+2, k[15:7]),
			          pat((k[6:0]*8)+1, k[15:7]), pat((k[6:0]*8)+0, k[15:7])};
		end
		for (k = 0; k < MAXRD; k = k + 1) begin pv[k] = 0; pd[k] = 0; end
		for (k = 0; k < FW*FH; k = k + 1) begin gotv[k] = 0; gotg[k] = 32'hFFFF_FFFF; end

		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);
		gp1(32'h0000_0000);
		gp0(32'hE300_0000);
		gp0(32'hE400_0000 | 32'd1023 | (32'd511 << 10));
		gp0(32'hE500_0000);

		$display("a 512-wide game, the first buffer");
		setmode(10'd0, 9'd0, 2'd2);
		capture("512 wide at vram 0, quiet");
		
		$display("the other buffer");
		setmode(10'd512, 9'd0, 2'd2);
		capture("512 wide at vram 512, quiet");

		$display("slow memory");
		lat = 14;
		capture("512 wide, memory 14 clocks away");
		lat = 20;
		capture("512 wide, memory 20 clocks away");
		lat = 6;

		$display("the network holding the capture off");
		hold_on = 1;
		capture("512 wide, scan_hold pulsing");
		hold_on = 0;


		$display("the drawing engine competing for the same cache");
		draw_on = 1;
		capture("512 wide, engine drawing elsewhere");
		draw_on = 0;

		$display("a 320-wide picture");
		setmode(10'd0, 9'd0, 2'd1);
		capture("320 wide at vram 0, quiet");

		$display("24-bit colour (a movie), 320 wide");
		gp1(32'h0800_0011);                      // 320 wide, 24-bit
		want24 = 1;
		capture("24-bit 320 wide at vram 0");
		capture("24-bit 320 wide at vram 0, again");
		gp1(32'h0500_0000 | 32'd100 | (32'd16 << 10));
		capture("24-bit 320 wide at vram 100,16 (an odd start)");
		gp1(32'h0800_0013);                      // 640 wide, 24-bit: half width, as the others
		gp1(32'h0500_0000);
		capture("24-bit 640 wide at vram 0");
		want24 = 0;

		$display("buffers flipping while the capture runs");
		// A real game flips at its own pace, not at a tidy moment: change where
		// the display points in the middle of captures and keep asking for whole
		// frames. Every one that finishes still has to be a picture of the
		// buffer it started on.
		setmode(10'd0, 9'd0, 2'd2);
		for (k = 0; k < 4; k = k + 1) begin
			repeat (60000) @(posedge clk);
			gp1(32'h0500_0000 | (k[0] ? 32'd512 : 32'd0));
			capture(k[0] ? "flipping: a capture after moving to 512"
			             : "flipping: a capture after moving to 0");
		end

		$display("buffers at y=256, something drawn above them (a movie's buffers in Gran Turismo 2)");
		// The crop keeps the rows drawn since the last flip. Counting only rows under 240, a
		// write up there with the picture at y=256 kept rows that were never on screen, and the
		// whole capture came out black. Draw a strip at rows 100-109 (x 640 on: outside the
		// window), flip, and every capture must still be the whole picture. (Last: the strip is in
		// other scenarios' windows, and their checks do not model the crop.)
		setmode(10'd640, 9'd256, 2'd1);          // (x 640 on: the fills earlier scenarios made are at x 0-639)
		for (k = 0; k < 4; k = k + 1) begin
			gp0(32'h0200_7FFF); gp0({16'd100, 16'd640}); gp0({16'd10, 16'd384});
			repeat (20000) @(posedge clk);
			gp1(32'h0500_0000 | (k[0] ? 32'd672 : 32'd640) | (32'd256 << 10));
			capture(k[0] ? "y=256: a capture after flipping to 672,256" : "y=256: a capture after flipping to 640,256");
		end

		if (errors == 0) $display("tb_ps1_scan: all checks passed -- the capture reads out what video memory holds");
		else             $display("tb_ps1_scan: FAIL -- %0d checks failed", errors);
		$finish;
	end

	initial begin
		#900000000;
		$display("tb_ps1_scan: TIMED OUT");
		$finish;
	end
endmodule

`default_nettype wire
