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

module tb_ps1_tex;
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
	ps1_gpu gpu ( .pfm_addr(pfm_addr), .pfm_req(pfm_req), .pfm_ready(pfm_ready), .pfm_rdata(pfm_rdata), .pfm_valid(pfm_valid), .every_flip(1'b0), .v_lin(v_lin_w), .v_one(v_one_w),
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
	ps1_vram_port vp ( .n_req(1'b0), .n_addr(25'd0), .v_lin(v_lin_w), .v_one(v_one_w), .g_lin(g_lin_w),
		.clk(clk), .rst(rst),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata), .v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(v_around),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack), .eng_idle(!gpu.eng_busy), .host_flush(1'b0), .busy(bk_busy),
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
	ps1_cache #(.IDXBITS(6), .A_AROUND(1)) vram ( .a_lin(g_lin_w),
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
	`include "ps1_pfmem.vh"
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
			while (!(gpu.f_empty && !gpu.eng_busy && !bk_busy)) @(negedge clk);
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
	integer stage = 0;
	integer q8i, q8u, q8v;
	function [15:0] pal8; input [7:0] i;   // a palette entry that is different for every index
		pal8 = {1'b0, i[7:3], i[4:0], i[2:0], 2'b01};
	endfunction

	// every line the texture cache takes, against what memory holds there
	integer fill_bad = 0;
	always @(posedge clk) if (!rst && gpu.u_raster.tfill_go) begin
		if (gpu.u_raster.tfill_line !== mem[gpu.u_raster.tfill_addr[19:4]] && fill_bad < 5) begin
			$display("   TEXTURE CACHE took the wrong data for line %07x: got %032x, memory holds %032x",
			         gpu.u_raster.tfill_addr, gpu.u_raster.tfill_line, mem[gpu.u_raster.tfill_addr[19:4]]);
			fill_bad = fill_bad + 1;
		end
	end

	// where the drawing time actually goes
	integer tex_stall_clk = 0, own_fills = 0, run_fills = 0, px_pairs = 0, busy_clk = 0;
	integer blocked_by_write = 0, waiting_for_mem = 0, fetch_issued = 0;
	// what the next miss is, relative to the last one: the line after it (the
	// span walking along the texture row) or a row further down
	reg [24:0] last_miss = 0; reg last_v = 0;
	integer d_next = 0, d_row = 0, d_other = 0;
	always @(posedge clk) if (!rst) begin
		if (gpu.u_raster.busy)                       busy_clk = busy_clk + 1;
		if (gpu.u_raster.st_tex_miss)                tex_stall_clk = tex_stall_clk + 1;
		if (gpu.u_raster.own_fill) begin
			own_fills = own_fills + 1;
			if (last_v) begin
				if (gpu.u_raster.faddr[28:4] - last_miss < 25'd16)       d_next = d_next + 1;
				else if (gpu.u_raster.faddr[28:4] - last_miss == 25'd128) d_row = d_row + 1;
				else                                                      d_other = d_other + 1;
			end
			last_miss = gpu.u_raster.faddr[28:4]; last_v = 1'b1;
		end
		if (gpu.u_raster.tx_valid && !gpu.u_raster.no_trun) run_fills = run_fills + 1;
		if (gpu.u_raster.w_done)                     px_pairs = px_pairs + 1;
		// of the clocks the rasteriser wants a texel line: how many it cannot even
		// ask (its own pixel write owns the port), and how many it has asked and
		// is waiting on memory
		if (gpu.u_raster.st_tex_miss && gpu.u_raster.fs == 2'd0 && gpu.u_raster.wreq) blocked_by_write = blocked_by_write + 1;
		if (gpu.u_raster.st_tex_miss && gpu.u_raster.fs != 2'd0) waiting_for_mem = waiting_for_mem + 1;
		if (gpu.u_raster.fs == 2'd0 && gpu.u_raster.want_fetch && !gpu.u_raster.wreq) fetch_issued = fetch_issued + 1;
	end
	task texreport; begin
		$display("      engine busy %0d clocks: %0d waiting for a texel line (%0d%%)",
		         busy_clk, tex_stall_clk, (100 * tex_stall_clk) / (busy_clk == 0 ? 1 : busy_clk));
		$display("      of the waiting: %0d clocks its own write owned the port, %0d clocks waiting on memory",
		         blocked_by_write, waiting_for_mem);
		$display("      misses: %0d within the run just fetched, %0d exactly one texture row on, %0d elsewhere",
		         d_next, d_row, d_other);
		$display("      fills: %0d fetched by the rasteriser, %0d offered by the video cache; %0d pixel pairs written",
		         own_fills, run_fills, px_pairs);
	end endtask

	integer gi;
	// a ring of the last memory transactions, dumped when the bench gives up
	reg [63:0] ring_t [0:31]; reg [7:0] ring_k [0:31]; reg [23:0] ring_a [0:31];
	integer ring_i = 0, rj;
	always @(posedge clk) if (!rst) begin
		if (m_req && m_ready) begin
			ring_t[ring_i[4:0]] <= $time; ring_k[ring_i[4:0]] <= m_we ? 8'h57 : (bk_req ? 8'h42 : 8'h43);   // W / B=blk read / C=cache read
			ring_a[ring_i[4:0]] <= m_addr; ring_i = ring_i + 1;
		end
		if (m_valid) begin
			ring_t[ring_i[4:0]] <= $time; ring_k[ring_i[4:0]] <= 8'h44;                   // D: data back
			ring_a[ring_i[4:0]] <= 24'd0; ring_i = ring_i + 1;
		end
	end
	task dump_ring;
		begin
			$display("   cache ports: a_req=%0d a_around=%0d a_addr=%07x   b_req=%0d b_addr=%07x   st=%0d pf_i=%0d",
			         vram.a_req, vram.a_around, vram.a_addr, vram.b_req, vram.b_addr, vram.st, vram.pf_i);
			$display("   cache in  : vc_addr=%06x  idx=%0d tg=%05x  nxt_b=%0b serving_b=%0b around=%0b ar_q=%0b  pf_first=%07x pf_valid=%0b",
			         vc_addr, vram.idx, vram.tg, vram.nxt_b, vram.serving_b, vram.around, vram.ar_q, vram.pf_first, vram.pf_valid);
			$display("   cache in2 : valid=%0b dirty=%0b tag=%05x  a_line_q=%0b", vram.valid[vram.idx], vram.dirty[vram.idx], vram.tag[vram.idx], vram.valid_q);
			$display("   last memory transactions (R read, W write, D data back), oldest first:");
			for (rj = 0; rj < 32; rj = rj + 1) begin
				if (ring_t[(ring_i + rj) % 32] != 0)
					$display("      %0t  %0s  %06x", ring_t[(ring_i + rj) % 32],
					         (ring_k[(ring_i + rj) % 32] == 8'h42) ? "R blk  " : (ring_k[(ring_i + rj) % 32] == 8'h43) ? "R cache" : (ring_k[(ring_i + rj) % 32] == 8'h57) ? "W      " : "D      ",
					         ring_a[(ring_i + rj) % 32]);
			end
		end
	endtask

	reg sx1 = 0, sx2 = 0, sx3 = 0;
	always @(posedge clk) if (!rst) begin
		if (!sx1 && (gpu.u_raster.hitC0_r === 1'bx)) begin
			sx1 <= 1'b1;
			$display("   X: hitC0_r @%0t  advBC=%0d hitB0=%0b tvalid=%0b ttagv=%05x taB0=%07x nC0=%07x tfill_go=%0b inv_go=%0b w_done=%0b inv_en=%0b wreq=%0b v_ack=%0b",
			  $time, gpu.u_raster.advBC, gpu.u_raster.hitB0, gpu.u_raster.tvalid[gpu.u_raster.tidx(gpu.u_raster.taB0)],
			  gpu.u_raster.ttagv[gpu.u_raster.tidx(gpu.u_raster.taB0)], gpu.u_raster.taB0, gpu.u_raster.nC0,
			  gpu.u_raster.tfill_go, gpu.u_raster.inv_go, gpu.u_raster.w_done, gpu.u_raster.inv_en, gpu.u_raster.wreq, v_ack);
		end
		if (!sx2 && (gpu.u_raster.wreq === 1'bx)) begin
			sx2 <= 1'b1;
			$display("   X: wreq    @%0t  vE=%0b mvE=%0b landE0=%0b landE1=%0b vD=%0b vC=%0b missC=%0b", $time,
			  gpu.u_raster.vE, gpu.u_raster.mvE, gpu.u_raster.landE0, gpu.u_raster.landE1, gpu.u_raster.vD, gpu.u_raster.vC, gpu.u_raster.missC);
		end
		if (!sx3 && (gpu.u_raster.vD === 1'bx)) begin
			sx3 <= 1'b1;
			$display("   X: vD      @%0t  vC=%0b missC=%0b hitC0=%0b hitC1=%0b needC0=%0b needC1=%0b hitC0_r=%0b tfill_d=%0b cl_loading=%0b",
			  $time, gpu.u_raster.vC, gpu.u_raster.missC, gpu.u_raster.hitC0, gpu.u_raster.hitC1,
			  gpu.u_raster.needC0, gpu.u_raster.needC1, gpu.u_raster.hitC0_r, gpu.u_raster.tfill_d, gpu.u_raster.cl_loading);
		end
	end

	reg seenx = 0;
	integer nstart = 0;
	always @(posedge clk) if (gpu.r_start && nstart < 4) begin
		nstart = nstart + 1;
		$display("   primitive start @%0t: ds=%0d  cu=%08x cv=%08x  du_dx=%08x dv_dx=%08x du_dy=%08x dv_dy=%08x",
		         $time, gpu.ds, gpu.u_raster.cu, gpu.u_raster.cv, gpu.du_dx, gpu.dv_dx, gpu.du_dy, gpu.dv_dy);
		$display("   area=%06x  vu=%02x %02x %02x %02x  vv=%02x %02x %02x %02x  vx=%03x %03x %03x %03x  second=%0d",
		         gpu.area, gpu.vu[0], gpu.vu[1], gpu.vu[2], gpu.vu[3], gpu.vv[0], gpu.vv[1], gpu.vv[2], gpu.vv[3],
		         gpu.vx[0], gpu.vx[1], gpu.vx[2], gpu.vx[3], gpu.second);
		$display("   cu_0=%08x cv_0=%08x  tp_x=%0d tp_y=%0d tp_depth=%0d", gpu.cu, gpu.cv, gpu.tp_x, gpu.tp_y, gpu.tp_depth);
	end

	localparam TEX_X = 512, TEX_Y = 0, TW = 64, TH = 64;
	function [15:0] texel_g;                       // red = u, green = v, bits 12:10 = generation
		input [9:0] tu; input [9:0] tv; input [2:0] tg;
		texel_g = {1'b0, tu[5], tv[5], tg, tv[4:0], tu[4:0]};   // as tools/ps1/ps1texcheck.py encodes it
	endfunction
	task upload;                                   // A0: the whole texture, one word every clock
		input integer g;
		integer u, v;
		reg [15:0] t0, t1;                         // one call per statement: a Verilog function
		begin                                      // is static, so two in one expression collide
			gp0(32'hA000_0000);
			gp0((TEX_Y << 16) | TEX_X);
			gp0((TH << 16) | TW);
			for (v = 0; v < TH; v = v + 1)
				for (u = 0; u < TW; u = u + 2)
				begin
					t0 = texel_g(u[9:0], v[9:0], g[2:0]);
					t1 = texel_g(u[9:0] + 10'd1, v[9:0], g[2:0]);
					gp0({t1, t0});
				end
		end
	endtask
	task quad;                                     // a textured quad over rows y0..y1
		input integer y0; input integer y1;
		begin
			gp0(32'h2D80_8080);
			gp0((y0 << 16) | 0);         gp0((0 << 8) | 0);
			gp0((y0 << 16) | 255);       gp0((16'h0108 << 16) | (0 << 8) | (TW - 1));
			gp0((y1 << 16) | 0);         gp0(((TH - 1) << 8) | 0);
			gp0((y1 << 16) | 255);       gp0((16'h0000 << 16) | ((TH - 1) << 8) | (TW - 1));
		end
	endtask
	integer gen_seen [0:7];
	task survey;                                   // which upload each pixel of a band came from
		input integer y0; input integer y1; input integer want_g;
		integer x, y, g, tot, wrong;
		reg [15:0] q;
		begin
			for (g = 0; g < 8; g = g + 1) gen_seen[g] = 0;
			tot = 0; wrong = 0;
			for (y = y0; y <= y1; y = y + 1)
				for (x = 0; x < 256; x = x + 1) begin
					q = vram_px(x[9:0], y[8:0]);
					g = q[12:10];
					gen_seen[g] = gen_seen[g] + 1;
					tot = tot + 1;
					if (g != want_g) wrong = wrong + 1;
				end
			$display("      rows %0d..%0d: %0d px, from upload 0:%0d 1:%0d 2:%0d 3:%0d  -> %0d not from upload %0d",
			         y0, y1, tot, gen_seen[0], gen_seen[1], gen_seen[2], gen_seen[3], wrong, want_g);
			check(wrong == 0, "every pixel came from the texture that was in VRAM when it was drawn");
		end
	endtask
	task survey_uv;                                // does each pixel sample the texel it should?
		input integer y0; input integer y1;
		integer x, y, wrong, tot, eu, ev, du, dv;
		reg [15:0] q;
		begin
			wrong = 0; tot = 0;
			for (y = y0; y <= y1; y = y + 1)
				for (x = 0; x < 256; x = x + 1) begin
					q = vram_px(x[9:0], y[8:0]);
					du = {q[14], q[4:0]}; dv = {q[13], q[9:5]};   // the same bits, read back
					eu = (x * 63) / 255;
					ev = ((y - y0) * 7) / (y1 - y0);
					tot = tot + 1;
					if (du > eu + 1 || du + 1 < eu || dv > ev + 1 || dv + 1 < ev) begin
						if (wrong < 4) $display("        (%0d,%0d) sampled texel (%0d,%0d), should be about (%0d,%0d)", x, y, du, dv, eu, ev);
						wrong = wrong + 1;
					end
				end
			$display("      rows %0d..%0d: %0d of %0d pixels sampled the wrong texel", y0, y1, wrong, tot);
			check(wrong == 0, "the polygon started at the right row of its texture");
		end
	endtask

	task vram_texture_ok;                          // and VRAM itself holds the last upload
		input integer g;
		integer u, v, wrong;
		reg [15:0] gt, wt;
		begin
			wrong = 0;
			for (v = 0; v < TH; v = v + 1)
				for (u = 0; u < TW; u = u + 1) begin
					gt = vram_px(TEX_X[9:0] + u[9:0], TEX_Y[8:0] + v[8:0]);
					wt = texel_g(u[9:0], v[9:0], g[2:0]);
					if (gt !== wt) begin
						if (wrong < 4) $display("        texel u=%0d v=%0d: got %04x want %04x", u, v, gt, wt);
						wrong = wrong + 1;
					end
				end
			$display("      texture in VRAM: %0d of %0d texels wrong", wrong, TW * TH);
			check(wrong == 0, "the upload itself landed in VRAM intact");
		end
	endtask

	integer nw = 0;
	always @(posedge clk) if (v_req && v_we && v_ack && nw < 8) begin
		$display("      write %0d: addr %07x be %b wdata %08x  (ds=%0d cphase=%0d cx=%0d)",
		         nw, v_addr, v_be, v_wdata, gpu.ds, gpu.cphase, gpu.cx);
		nw = nw + 1;
	end

	initial begin
		for (k = 0; k < 65536; k = k + 1) mem[k] = 128'd0;
		for (k = 0; k < RD; k = k + 1) begin pv[k] = 0; pd[k] = 0; end
		for (k = 0; k < 320*240; k = k + 1) frame[k] = 8'd0;
		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);

		gp1(32'h0000_0000);
		gp0(32'hE100_0108);                                 // texpage x = 8 (VRAM x 512), 15-bit
		gp0(32'hE300_0000);
		gp0(32'hE400_0000 | (10'd319) | (9'd239 << 10));
		gp0(32'hE500_0000);
		gp0(32'hE600_0000);

		$display("probe: %04x %04x %04x %04x", texel_g(0, 0, 1), texel_g(1, 0, 1), texel_g(2, 1, 1), texel_g(33, 40, 2));
		$display("--- upload, draw, upload again, draw again ---");
		stage = 1;
		upload(1);
		idle();
		vram_texture_ok(1);

		stage = 2;
		quad(0, 63);                 // draw with generation 1 ...
		stage = 3;
		upload(2);                   // ... and overwrite the texture while that draw is still running
		stage = 4;
		quad(64, 127);               // then draw again: this must be all generation 2
		stage = 5;
		idle();

		vram_texture_ok(2);
		survey(0, 63, 1);
		survey(64, 127, 2);

		$display("--- a polygon whose first vertex is not the top of its box ---");
		// The gradients are worked out one per clock and the row start is taken
		// from them. Taken in the same clock as the last one is written, it used
		// the PREVIOUS primitive's dv_dy, and a polygon whose vertex 0 sits below
		// the top of its bounding box started at the wrong row of its texture.
		// This triangle has vertex 0 at the bottom and a dv_dy four times smaller
		// than the quad before it, so the old value shows up as a wrong texel.
		gp0(32'h2C80_8080);                                             // textured quad, not gouraud
		gp0((223 << 16) | 0);    gp0((7 << 8) | 0);                     // v0: bottom left,  uv (0, 7)
		gp0((223 << 16) | 255);  gp0((16'h0108 << 16) | (7 << 8) | 63); // v1: bottom right, uv (63, 7)
		gp0((192 << 16) | 0);    gp0((0 << 8) | 0);                     // v2: top left,     uv (0, 0)
		gp0((192 << 16) | 255);  gp0((0 << 8) | 63);                    // v3: top right,    uv (63, 0)
		idle();
		survey_uv(192, 223);

		// ---- 8-bit paletted, which nothing covered before ----------------------
		// STATE 2026-09-24: this check has never passed, and three of its four
		// faults were in the TEST, not the rasteriser:
		//   * the page word said 0x0188, whose colour-depth bits (8:7) are 3 --
		//     a reserved mode -- instead of 1 for 8-bit;
		//   * the CLUT word said 0x0640, which decodes to VRAM (0, 25), while
		//     the palette was uploaded to (512, 200) = 0x3220;
		//   * the texture was uploaded to y=210, but a page's y base is 0 or 256
		//     and nothing between, so the page addressed VRAM the texture was
		//     not in.
		// With those corrected it goes from 2048 of 2048 pixels wrong to 1024:
		// every EVEN texel (the low byte of each halfword) reads as undefined,
		// so the upload is still not writing them. The game draws 8-bit
		// textures with the right colours on the board, so finish the test
		// before suspecting the rasteriser. Not in tools/simps1.sh for this
		// reason -- put it there once it passes.
		// Crash's world is paletted. A 4-bit texture was covered and a 15-bit one
		// was covered; 8-bit was not, and an 8-bit texture is a different address
		// walk (two texels a word, 256-entry palette) and a different CLUT size.
		$display("--- an 8-bit paletted texture ---");
		gp0(32'hA000_0000); gp0((9'd200 << 16) | 10'd512); gp0((32'd1 << 16) | 32'd256);
		for (q8i = 0; q8i < 256; q8i = q8i + 2)
			gp0({pal8(q8i[7:0] + 8'd1), pal8(q8i[7:0])});        // the palette: 256 entries at (512,200)
		// a texture page's y base is 0 or 256, nothing between, so the texture has
		// to sit at one of them or the page addresses VRAM the texture is not in
		gp0(32'hA000_0000); gp0((9'd256 << 16) | 10'd512); gp0((32'd32 << 16) | 32'd32);
		for (q8v = 0; q8v < 32; q8v = q8v + 1)                      // 32 rows of 64 texels, two a byte
			for (q8u = 0; q8u < 64; q8u = q8u + 4)
				gp0({q8u[7:0] + 8'd3, q8u[7:0] + 8'd2, q8u[7:0] + 8'd1, q8u[7:0]});
		idle();
		gp0(32'h2C80_8080);                                     // a quad from it, 8-bit page
		gp0((140 << 16) | 0);    gp0((16'h3220 << 16) | (0 << 8) | 0);     // clut at (512,200): x/16=32, y=200
		gp0((140 << 16) | 63);   gp0((16'h0098 << 16) | (0 << 8) | 63);    // page x base 8 (=512), y base 256 (bit 4), 8-bit (bits 8:7 = 01)
		gp0((171 << 16) | 0);    gp0((31 << 8) | 0);
		gp0((171 << 16) | 63);   gp0((31 << 8) | 63);
		idle();
		bad = 0;
		for (ty = 140; ty <= 171; ty = ty + 1)
			for (tx = 0; tx <= 63; tx = tx + 1) begin
				got16 = vram_px(tx[9:0], ty[8:0]);
				want  = pal8(tx[7:0]);                          // texel u = tx, palette entry u
				if (got16 !== want) begin
					if (bad < 4) $display("        (%0d,%0d) reads %04x, the palette says %04x", tx, ty, got16, want);
					bad = bad + 1;
				end
			end
		$display("      %0d of 2048 pixels of the 8-bit quad are wrong", bad);
		check(bad == 0, "an 8-bit paletted texture draws the colours its palette holds");

		$display("--- a gouraud-shaded textured triangle (what the game hangs on) ---");
		// On the board the rasteriser stops dead inside command 34h with its
		// FIFO full: busy stays up, GPUSTAT never says "ready for commands",
		// and the game's DrawSync never returns. Draw some here.
		for (gi = 0; gi < 8; gi = gi + 1) begin
			gp0(32'h3400_00FF);                                  // 34h: gouraud + texture, colour 0
			gp0(((140 + gi) << 16) | (10 + gi));  gp0((0 << 8) | 0);
			gp0(32'h0000_FF00);                                  // colour 1
			gp0(((150 + gi) << 16) | (200 - gi)); gp0((16'h0108 << 16) | (0 << 8) | (TW - 1));
			gp0(32'h00FF_0000);                                  // colour 2
			gp0(((180 + gi) << 16) | (20 + gi));  gp0(((TH - 1) << 8) | 0);
		end
		idle();
		$display("      the engine finished every one of them");
		check(1'b1, "a gouraud textured triangle completes");

		$display("--- a textured triangle with a very steep texture gradient ---");
		// The texture cache is direct mapped and the rasteriser needs BOTH texels
		// of a pixel pair in hand before the pair may move on. If the two land in
		// the same cache line index with different tags, each fetch evicts what
		// the other one needs and the pipeline never advances. A polygon squeezed
		// to a few pixels while its texture coordinates span the page does
		// exactly that -- which is what a game draws when something is close to
		// the camera and steeply angled.
		// The index is {v[3:0], u[6:3]} and the tag carries v[8:4] and u[9:7], so
		// two texels whose v differs by exactly 16 share an index and differ in
		// tag. dv/dx = 16 puts such a pair under every pixel pair.
		gp0(32'h2480_8080);
		gp0((10 << 16) | 10);   gp0((0 << 8) | 0);                       // uv (0, 0)
		gp0((10 << 16) | 26);   gp0((16'h0108 << 16) | (255 << 8) | 0);  // uv (0, 255): v climbs 16 a pixel
		gp0((26 << 16) | 10);   gp0((0 << 8) | 0);                       // uv (0, 0)
		idle();
		$display("      the engine finished it");
		check(1'b1, "a steep texture gradient does not stop the rasteriser");

		// ...and it must draw the RIGHT texels, not merely finish. A quad whose v
		// climbs 16 a pixel across x collides on every pair, and every texel it
		// asks for is inside the 64x64 texture, so each pixel can be checked
		// against the (u, v) the texel names.
		gp0(32'h2C80_8080);
		gp0((30 << 16) | 10);   gp0((0 << 8) | 0);                        // uv (0, 0)
		gp0((30 << 16) | 13);   gp0((16'h0108 << 16) | (48 << 8) | 0);    // uv (0, 48)
		gp0((45 << 16) | 10);   gp0((0 << 8) | 63);                       // uv (63, 0)
		gp0((45 << 16) | 13);   gp0((48 << 8) | 63);                      // uv (63, 48)
		idle();
		bad = 0;
		for (ty = 30; ty <= 45; ty = ty + 1)
			for (tx = 10; tx <= 13; tx = tx + 1) begin
				got16 = vram_px(tx[9:0], ty[8:0]);
				pa = {got16[14], got16[4:0]};                 // the u it names
				pb = {got16[13], got16[9:5]};                 // the v it names
				want = ((ty - 30) * 63) / 15;
				if (pa > want + 2 || pa + 2 < want) begin
					if (bad < 3) $display("        (%0d,%0d) names texel (%0d,%0d), u should be about %0d", tx, ty, pa, pb, want);
					bad = bad + 1;
				end
			end
		$display("      %0d of 64 pixels of the colliding quad sampled the wrong texel", bad);
		check(bad == 0, "the held line serves the texels the texture actually holds");

		texreport();
		if (errors == 0) $display("tb_ps1_tex: all checks passed");
		else $display("tb_ps1_tex: %0d FAIL(s)", errors);
		$finish;
	end
	initial begin
		#40_000_000;
		$display("FAIL: timeout  stage=%0d  gpu: ds=%0d busy=%0d f_count=%0d gp0_full=%0d  raster busy=%0d  bk_busy=%0d",
		         stage, gpu.ds, gpu.busy, gpu.f_count, gpu.gp0_full, gpu.r_busy, bk_busy);
		$display("   raster: vB=%0d vC=%0d vD=%0d vE=%0d wreq=%0d fs=%0d cl_loading=%0d scanning=%0d",
		         gpu.u_raster.vB, gpu.u_raster.vC, gpu.u_raster.vD, gpu.u_raster.vE, gpu.u_raster.wreq, gpu.u_raster.fs, gpu.u_raster.cl_loading, gpu.u_raster.scanning);
		$display("   fetch : want_tex=%0d want_dst=%0d hitC0=%0d hitC1=%0d needC0=%0d needC1=%0d taC0=%07x taC1=%07x faddr=%07x fwho=%0d",
		         gpu.u_raster.want_tex, gpu.u_raster.want_dst, gpu.u_raster.hitC0, gpu.u_raster.hitC1, gpu.u_raster.needC0, gpu.u_raster.needC1,
		         gpu.u_raster.taC0, gpu.u_raster.taC1, gpu.u_raster.faddr, gpu.u_raster.fwho);
		$display("   port  : v_req=%0d v_we=%0d v_ack=%0d v_addr=%07x  gp_req=%0d gp_ack=%0d  g_around=%0d r_hold=%0d",
		         v_req, v_we, v_ack, v_addr, gp_req, gp_ack, gp_around, vp.r_hold);
		$display("   cache : st=%0d  vc_req=%0d vc_we=%0d vc_ready=%0d vc_valid=%0d  a_req=%0d a_ack=%0d",
		         vram.st, vc_req, vc_we, vc_ready, vc_valid, vram.a_req, vram.a_ack);
		$display("   blk   : bk_req=%0d bk_we=%0d bk_ready=%0d idle=%0d  m_req=%0d m_we=%0d m_addr=%06x  arb p_ready=%b",
		         bk_req, bk_we, bk_ready, vp.idle, m_req, m_we, m_addr, p_ready);
		dump_ring();
		$finish;
	end
endmodule
