//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_gpu - draw a scene into VRAM-in-a-cache and read the frame back.
//
// The GPU behind its own cache behind a line memory, as on the board. A short
// command stream does what the BIOS does: sets the environment, fills the
// screen, draws a Gouraud triangle and a flat quad, uploads a texture and
// draws a textured rectangle from it, then turns the display on. The frame the
// display side emits is written out as 320x240 RGB332 for tools/fb2png.py, and
// a few pixels are checked in VRAM directly -- the fill colour, one inside the
// triangle, one in the rectangle -- so a broken rasteriser fails here before
// anybody squints at a picture.
//
//   ./tools/sim.sh tb_ps1_gpu
//   python tools/fb2png.py build/sim/gpu_frame.bin build/gpu_frame.png 320 240
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_ps1_speed;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// --- the register bus into the GPU ----------------------------------------------
	reg        sel = 0, we = 0, a4 = 0;
	reg [31:0] wdata = 0;
	wire [31:0] rdata;

	// DMA side, unused here
	wire        dma_ready;
	wire [31:0] dma_rdata;
	wire        dma_rvalid;

	// VRAM: two cache ports
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
	wire [127:0] v_line;   // the whole line a read came from: the engine holds on to it
	wire        v_ack, s_ack;

	wire        px_valid;
	wire [8:0]  px_x, px_y;
	wire [7:0]  px_rgb;
	wire        vblank, hblank, dot_ce, irq;

	wire v_lin_w, v_one_w, g_lin_w;
	ps1_gpu gpu ( .every_flip(1'b0), .v_lin(v_lin_w), .v_one(v_one_w),
		.clk(clk), .rst(rst),
		.sel(sel), .we(we), .a4(a4), .dma_active(1'b0), .cap_every_vsync(1'b0), .gpu_fast(1'b1),
		.no_tcache(no_tcache_r), .no_ccache(1'b0), .no_trun(1'b0), .wdata(wdata), .rdata(rdata),
		.dma_wr(1'b0), .dma_data(32'd0), .dma_ready(dma_ready),
		.dma_rd(1'b0), .dma_rdata(dma_rdata), .dma_rvalid(dma_rvalid),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack),
		.s_addr(s_addr), .s_req(s_req), .s_rdata(s_rdata), .s_ack(s_ack), .s_line(s_vline), .scan_hold(1'b0), .scan_enable(1'b1),
		.scan_lines(1'b0), .tx_valid(x_valid), .tx_addr(x_addr), .tx_line(x_line), .v_around(v_around), .fl_valid(), .fl_data(), .fl_x(), .fl_y(),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.vblank(vblank), .hblank(hblank), .dot_ce(dot_ce), .irq(irq)
	);

	// the VRAM cache: drawing on A, display on B
	wire [23:0]  m_addr;
	wire         m_req, m_we;
	wire [127:0] m_wdata;
	reg          m_ready;
	reg  [127:0] m_rdata = 0;
	reg          m_valid = 0;
	wire [31:0]  hits, misses;

	// the engine's writes go to the block writer, its reads on to the cache
	wire [28:0]  gp_addr; wire gp_req, gp_around, gp_ack; wire [31:0] gp_rdata; wire [127:0] gp_line;
	wire [23:0]  bk_addr, vc_addr; wire bk_req, bk_we, bk_ready, vc_req, vc_we, vc_ready, vc_valid; wire [127:0] bk_wdata, vc_wdata, vc_rdata; wire [15:0] bk_wmask, vc_wmask;
	wire         inv_v; wire [24:0] inv_line; wire bk_busy;
	ps1_vram_port vp ( .v_lin(v_lin_w), .v_one(v_one_w), .g_lin(g_lin_w),
		.clk(clk), .rst(rst),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata), .v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(v_around),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack), .eng_idle(!gpu.busy), .host_flush(1'b0), .busy(bk_busy),
		.g_addr(gp_addr), .g_req(gp_req), .g_around(gp_around), .g_rdata(gp_rdata), .g_line(gp_line), .g_ack(gp_ack),
		.m_addr(bk_addr), .m_req(bk_req), .m_we(bk_we), .m_wdata(bk_wdata), .m_wmask(bk_wmask), .m_ready(bk_ready),
		.inv_v(inv_v), .inv_line(inv_line));
	wire [1:0] p_ready, p_valid; wire [255:0] p_rdata;
	assign bk_ready = p_ready[1]; assign vc_ready = p_ready[0]; assign vc_valid = p_valid[0]; assign vc_rdata = p_rdata[127:0];
	mem_arb #(.PORTS(2), .AW(24)) arb (
		.clk(clk), .rst(rst),
		.p_addr({bk_addr, vc_addr}), .p_req({bk_req, vc_req}), .p_we({bk_we, vc_we}), .p_wdata({bk_wdata, vc_wdata}), .p_wmask({bk_wmask, vc_wmask}),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid));
	wire [15:0] m_wmask;
	ps1_cache #(.IDXBITS(9), .A_AROUND(1)) vram ( .a_lin(g_lin_w),
		.b_first(1'b0),                 // the capture's port has no priority here
		.flush(1'b0), .flush_busy(), .inv_v(inv_v), .inv_line(inv_line),
		.clk(clk), .rst(rst),
		.a_addr(gp_addr), .a_req(gp_req), .a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0), .a_we(1'b0), .a_be(4'hF), .a_wdata(32'd0),
		.a_around(gp_around), .x_valid(x_valid), .x_addr(x_addr), .x_line(x_line),
		.a_rdata(gp_rdata), .a_ack(gp_ack),
		.b_addr(s_addr), .b_req(s_req), .b_we(1'b0), .b_be(4'hF), .b_wdata(32'd0),
		.b_rdata(s_rdata), .b_ack(s_ack), .b_line(s_vline), .a_line(gp_line),
		.m_addr(vc_addr), .m_req(vc_req), .m_we(vc_we), .m_wdata(vc_wdata), .m_wmask(vc_wmask),
		.m_ready(vc_ready), .m_rdata(vc_rdata), .m_valid(vc_valid),
		.dbg_hits(hits), .dbg_misses(misses)
	);

	// a megabyte of lines with some latency
	reg [127:0] mem [0:65535];
	localparam RD = 6;
	reg [127:0] pd [0:RD-1];
	reg         pv [0:RD-1];
	integer pi;
	always @(*) m_ready = m_req;
	always @(posedge clk) begin
		m_valid <= pv[RD-1]; m_rdata <= pd[RD-1];
		for (pi = RD - 1; pi > 0; pi = pi - 1) begin pv[pi] <= pv[pi-1]; pd[pi] <= pd[pi-1]; end
		pv[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) begin for (pi = 0; pi < 16; pi = pi + 1) if (m_wmask[pi]) mem[m_addr[15:0]][pi*8 +: 8] <= m_wdata[pi*8 +: 8]; end
			else begin pv[0] <= 1'b1; pd[0] <= mem[m_addr[15:0]]; end
		end
	end

	// what VRAM holds at (x, y), through the cache's own array and the memory
	// behind it -- so a value still dirty in the cache is seen too
	function [15:0] vram_px;
		input [9:0] x; input [8:0] y;
		reg [28:0] a; reg [127:0] l; reg [5:0] ix;
		begin
			a  = {y, x[9:1], 2'b00};
			ix = a[9:4];
			if (vram.valid[ix] && vram.tag[ix] == a[28:10]) l = vram.data[ix];
			else l = mem[a[19:4]];
			vram_px = x[0] ? l[a[3:2]*32 + 16 +: 16] : l[a[3:2]*32 +: 16];
		end
	endfunction

	wire [31:0] rdata_stat = gpu.gpustat;

	task gp0; input [31:0] w; begin
		// gp0_full, not f_full: ps1_top stalls the processor a slot early, and a
		// bench that fills the last slot loses words the machine never loses.
		@(negedge clk); while (gpu.gp0_full) @(negedge clk);
		sel = 1; we = 1; a4 = 0; wdata = w;
		@(negedge clk); sel = 0; we = 0;
	end endtask
	task gp1; input [31:0] w; begin
		@(negedge clk); sel = 1; we = 1; a4 = 1; wdata = w;
		@(negedge clk); sel = 0; we = 0;
	end endtask
	task idle;      // wait for the engine to finish everything queued
		begin
			@(negedge clk);
			while (!(gpu.f_empty && !gpu.busy && !bk_busy)) @(negedge clk);
			repeat (4) @(negedge clk);
		end
	endtask

	// --- helpers for the wide-texture check ---------------------------------
	integer tx, ty, bad;
	reg [15:0] want, got16, pa, pb;
	// a palette entry that is different for every index and never zero
	function [15:0] pal;
		input integer i;
		pal = (i == 0) ? 16'h0000
		                : {1'b0, i[3:0], 1'b1, i[3:0], 1'b1, i[3:0], 1'b1};
	endfunction
	// eight 4-bit texels packed into a word: texel (u,v) is (u + v) & 15
	function [31:0] texword;
		input integer wx, wy;
		integer j;
		begin
			texword = 32'd0;
			for (j = 0; j < 8; j = j + 1)
				texword[j*4 +: 4] = (wx * 8 + j + wy) & 15;
		end
	endfunction

	integer errors = 0;
	task check; input c; input [511:0] what; begin
		if (c) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end
	end endtask

	// the frame, as the display emits it
	reg [7:0] frame [0:320*240-1];
	always @(posedge clk) if (px_valid) frame[px_y * 320 + px_x] <= px_rgb;

	integer k, fd, frames;
	reg [15:0] p;
	integer busy_clks = 0, r_tex = 0, r_dst = 0, r_full = 0, r_clut = 0;
	always @(posedge clk) begin
		if (gpu.busy) busy_clks = busy_clks + 1;
		if (gpu.r_st_tex) r_tex = r_tex + 1; if (gpu.r_st_dst) r_dst = r_dst + 1;
		if (gpu.r_st_full) r_full = r_full + 1; if (gpu.r_st_clut) r_clut = r_clut + 1;
	end

	// what the stops are: the span ending, the next texel line not in hand, or the palette line


	// ==================================================================================
	// tb_ps1_tex: does a texture uploaded between two draws reach the second draw?
	//
	// The board says no. With the rasteriser's texture cache on, a quad drawn
	// after an upload comes out part old texture; with it bypassed the same quad
	// is perfect, every run. This reproduces that: upload generation 1, draw with
	// it, upload generation 2 over the same pixels WITHOUT waiting for the first
	// draw to finish, draw again, and read VRAM back. Every texel names its own
	// (u, v) and which upload it came from, so a wrong pixel says where it came
	// from rather than just being wrong.
	// ==================================================================================
	reg no_tcache_r = 1'b0;

	// ==================================================================================
	// tb_ps1_speed - how fast the engine draws a scene shaped like a game's.
	//
	// The correctness bench (tb_ps1_tex) stretches one texture over the whole
	// screen, so a span walks a quarter of a texel per pixel and every miss is
	// along one texture row. A game does the opposite: many small polygons, the
	// texture at roughly one texel to the pixel, so each span crosses rows as
	// often as columns. Tuning the texture path against the wrong one of those
	// is how a change can measure as worthless and still be the right change.
	//
	// This draws 160 small textured triangles at 1:1 and reports where the
	// drawing time went. No checks: it is a yardstick, not a gate.
	// ==================================================================================
	localparam TEX_X = 512, TEX_Y = 0, TW = 64, TH = 64;
	function [15:0] texel_g;
		input [9:0] tu; input [9:0] tv; input [2:0] tg;
		texel_g = {1'b0, tu[5], tv[5], tg, tv[4:0], tu[4:0]};
	endfunction

	integer busy_clk = 0, tex_stall = 0, own_fills = 0, run_fills = 0, px_pairs = 0;
	integer mem_tex = 0, mem_wr = 0, mem_other = 0;
	always @(posedge clk) if (!rst) begin
		if (gpu.u_raster.busy)        busy_clk  = busy_clk + 1;
		if (gpu.u_raster.st_tex_miss) tex_stall = tex_stall + 1;
		if (gpu.u_raster.own_fill)    own_fills = own_fills + 1;
		if (gpu.u_raster.tx_valid)    run_fills = run_fills + 1;
		if (gpu.u_raster.w_done)      px_pairs  = px_pairs + 1;
		// where the memory transactions go
		if (m_req && m_ready) begin
			if (m_we)                 mem_wr    = mem_wr + 1;
			else if (vram.pf_busy)    mem_tex   = mem_tex + 1;
			else                      mem_other = mem_other + 1;
		end
	end

	integer i, u, v, sx, sy;
	reg [15:0] t0, t1;
	reg [31:0] seed = 32'h1234_5678;
	function [31:0] nxt; input [31:0] s;
		nxt = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
	endfunction

	initial begin
		for (k = 0; k < 65536; k = k + 1) mem[k] = 128'd0;
		for (k = 0; k < RD; k = k + 1) begin pv[k] = 0; pd[k] = 0; end
		repeat (4) @(posedge clk); rst = 0; repeat (4) @(posedge clk);

		gp1(32'h0000_0000);
		gp0(32'hE100_0108);                                  // texture page at VRAM x 512, 15-bit
		gp0(32'hE300_0000);
		gp0(32'hE400_0000 | (10'd319) | (9'd239 << 10));
		gp0(32'hE500_0000); gp0(32'hE600_0000);

		gp0(32'hA000_0000); gp0((TEX_Y << 16) | TEX_X); gp0((TH << 16) | TW);
		for (v = 0; v < TH; v = v + 1)
			for (u = 0; u < TW; u = u + 2) begin
				t0 = texel_g(u[9:0], v[9:0], 3'd1);
				t1 = texel_g(u[9:0] + 10'd1, v[9:0], 3'd1);
				gp0({t1, t0});
			end
		idle();

		busy_clk = 0; tex_stall = 0; own_fills = 0; run_fills = 0; px_pairs = 0;

		// 160 small textured triangles, texture at one texel to the pixel
		for (i = 0; i < 160; i = i + 1) begin
			seed = nxt(seed); sx = 8 + (seed[8:0] % 240);
			seed = nxt(seed); sy = 8 + (seed[8:0] % 200);
			gp0(32'h3480_8080);                                        // gouraud + texture
			gp0(((sy) << 16) | sx);                 gp0((0 << 8) | 0);
			gp0(32'h0080_8080);
			gp0(((sy + 6) << 16) | (sx + 28));      gp0((16'h0108 << 16) | (6 << 8) | 28);
			gp0(32'h0080_8080);
			gp0(((sy + 26) << 16) | (sx + 4));      gp0((26 << 8) | 4);
		end
		idle();

		$display("--- a scene shaped like a game's: 160 small triangles, 1:1 texture ---");
		$display("   engine busy %0d clocks, %0d pixel pairs -> %0d.%02d clocks a pair",
		         busy_clk, px_pairs, busy_clk / (px_pairs == 0 ? 1 : px_pairs),
		         ((busy_clk * 100) / (px_pairs == 0 ? 1 : px_pairs)) % 100);
		$display("   waiting for a texel line %0d clocks (%0d%% of busy)",
		         tex_stall, (100 * tex_stall) / (busy_clk == 0 ? 1 : busy_clk));
		$display("   fetches %0d, lines offered %0d", own_fills, run_fills);
		$display("   memory: %0d texture reads, %0d writes, %0d other reads (%0d total)",
		         mem_tex, mem_wr, mem_other, mem_tex + mem_wr + mem_other);
		$finish;
	end
	initial begin #40_000_000; $display("TIMEOUT"); $finish; end
endmodule
