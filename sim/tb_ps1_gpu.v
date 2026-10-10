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

module tb_ps1_gpu;
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
	localparam RA = 1;             // the raster's destination read-ahead (ps1_top builds it in)
	wire vn_req, vn_ack; wire [24:0] vn_addr; wire [127:0] vn_line;
	ps1_gpu #(.READ_AHEAD(RA)) gpu ( .vn_req(vn_req), .vn_addr(vn_addr), .vn_ack(vn_ack), .vn_line(vn_line), .every_flip(1'b0), .v_lin(v_lin_w), .v_one(v_one_w),
		.clk(clk), .rst(rst),
		.sel(sel), .we(we), .a4(a4), .dma_active(1'b0), .cap_every_vsync(1'b0), .gpu_fast(1'b1),
		.no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .wdata(wdata), .rdata(rdata),
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
 	ps1_vram_port vp ( .n_req(vn_req), .n_addr(vn_addr), .n_ack(vn_ack), .n_line(vn_line), .v_lin(v_lin_w), .v_one(v_one_w), .g_lin(g_lin_w),
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
`ifdef TB_RD
	localparam RD = `TB_RD;
`else
	localparam RD = 6;
`endif
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

	integer cyc = 0;
	function [31:0] xy; input integer x, y; xy = {5'd0, y[10:0], 5'd0, x[10:0]}; endfunction
	reg trace_ds = 0; reg [5:0] ds_last = 0; integer ds_n = 0;
	always @(posedge clk) if (trace_ds && gpu.ds != ds_last && ds_n < 40) begin
		$display("      t=%0d ds %0d -> %0d (cmd %h argc %0d)", cyc, ds_last, gpu.ds, gpu.cmd, gpu.argc); ds_last = gpu.ds; ds_n = ds_n + 1; end
	always @(posedge clk) cyc = cyc + 1;
	task gp0; input [31:0] w; begin
		@(negedge clk); while (gpu.f_full) @(negedge clk);
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

	integer k, fd, frames, cp_bad, cp_t0, cp_d0, cp_m0, cp_f0, cp_x0, cp_n0, cp_r0;
	integer n_out_clks = 0, r_run_clks = 0;
	always @(posedge clk) begin if (vn_req) n_out_clks = n_out_clks + 1; if (gpu.r_busy) r_run_clks = r_run_clks + 1; end
	reg [15:0] cp_src [0:45*5-1];
	reg [15:0] p;
	integer busy_clks = 0, r_tex = 0, r_dst = 0, r_full = 0, r_clut = 0;
	always @(posedge clk) begin
		if (gpu.busy) busy_clks = busy_clks + 1;
		if (gpu.r_st_tex) r_tex = r_tex + 1; if (gpu.r_st_dst) r_dst = r_dst + 1;
		if (gpu.r_st_full) r_full = r_full + 1; if (gpu.r_st_clut) r_clut = r_clut + 1;
	end

	// what the stops are: the span ending, the next texel line not in hand, or the palette line

	initial begin
		for (k = 0; k < 65536; k = k + 1) mem[k] = 128'd0;
		for (k = 0; k < RD; k = k + 1) begin pv[k] = 0; pd[k] = 0; end
		for (k = 0; k < 320*240; k = k + 1) frame[k] = 8'd0;
		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);

		gp1(32'h0000_0000);                     // reset
		gp0(32'hE100_0000 | 32'h0000_0100);     // texpage 0, 15-bit textures (depth bits 8:7 = 2)
		gp0(32'hE300_0000);                     // draw area 0,0
		gp0(32'hE400_0000 | (10'd319) | (9'd239 << 10));   // .. to 319,239
		gp0(32'hE500_0000);                     // no offset

		// fill the screen dark blue
		gp0(32'h0260_2010); gp0(32'h0000_0000); gp0({7'd0, 9'd240, 6'd0, 10'd320});
		idle();
		p = vram_px(10'd100, 9'd100);
		check(p == {1'b0, 5'h0C, 5'h04, 5'h02}, "fill wrote the colour (BGR555 of 10,20,60)");

		// a Gouraud triangle: red, green, blue corners
		gp0(32'h3000_00FF); gp0({16'd20,  16'd40});
		gp0(32'h0000_FF00); gp0({16'd200, 16'd60});
		gp0(32'h00FF_0000); gp0({16'd100, 16'd200});
		idle();
		p = vram_px(10'd100, 9'd100);
		check(p != {1'b0, 5'h0C, 5'h04, 5'h02} && p != 16'd0, "a pixel inside the triangle changed");
		p = vram_px(10'd45, 9'd45);
		check(p[4:0] > 5'd20 && p[14:10] < 5'd6, "near the red corner it is mostly red");

		// a flat yellow quad, opaque
		gp0(32'h2800_FFFF);
		// vertex words are {y, x}: this is (220,150) (300,150) (220,220) (300,220)
		gp0({16'd150, 16'd220}); gp0({16'd150, 16'd300});
		gp0({16'd220, 16'd220}); gp0({16'd220, 16'd300});
		idle();
		p = vram_px(10'd260, 9'd185);
		check(p == {1'b0, 5'h00, 5'h1F, 5'h1F}, "the quad is yellow inside");
		p = vram_px(10'd260, 9'd230);
		check(p == {1'b0, 5'h0C, 5'h04, 5'h02}, "and the fill survives below it");

		// --- VRAM -> VRAM: a copy out of the triangle's gradient, odd source and destination
		// columns, rows longer than one 16-pixel chunk, to a place nothing else uses
		for (k = 0; k < 45*5; k = k + 1) cp_src[k] = vram_px(10'd61 + k % 45, 9'd81 + k / 45);
		cp_t0 = busy_clks;
		gp0(32'h8000_0000); gp0({16'd81, 16'd61}); gp0({16'd401, 16'd703}); gp0({16'd5, 16'd45});
		idle();
		$display("    copy 45x5: %0d busy clocks", busy_clks - cp_t0);
		cp_bad = 0;
		for (k = 0; k < 45*5; k = k + 1) if (vram_px(10'd703 + k % 45, 9'd401 + k / 45) !== cp_src[k]) cp_bad = cp_bad + 1;
		check(cp_bad == 0, "a VRAM copy lands every pixel where it was sent");
		if (cp_bad != 0) $display("    %0d of 225 copied pixels wrong", cp_bad);
		check(vram_px(10'd702, 9'd401) == 16'd0 && vram_px(10'd748, 9'd401) == 16'd0, "and nothing either side of it");

		// upload a 4x4 15-bit texture at (512,0): a magenta/cyan checker
		gp0(32'hA000_0000); gp0({16'd0, 16'd512}); gp0({16'd4, 16'd4});
		for (k = 0; k < 8; k = k + 1)                // 16 texels, two per word
			gp0(((k & 1) == 0) ? {16'h7C1F, 16'h7FE0} : {16'h7FE0, 16'h7C1F});
		idle();
		p = vram_px(10'd512, 9'd0);
		check(p == 16'h7FE0, "the texture landed in VRAM");

		// texpage at x=512 (unit 8), 15-bit; a textured 32x32 rectangle, raw
		gp0(32'hE100_0000 | 32'h0000_0100 | 32'h0000_0008);
		gp0(32'h6580_8080);                     // textured rect, raw, colour ignored
		gp0({16'd30, 16'd240});                 // at 240,30
		gp0({16'h0000, 8'd0, 8'd0});            // clut (none), uv 0,0
		gp0({16'd32, 16'd32});                  // 32 x 32
		idle();
		p = vram_px(10'd240, 9'd30);
		check(p == 16'h7FE0 || p == 16'h7C1F, "the rectangle shows texels");

		// --- palette textures: the BIOS menu draws its spheres and text this way ---
		gp0(32'hE300_0000); gp0(32'hE400_0000 | 32'd1023 | (32'd511 << 10));   // the whole of VRAM drawable
		// a 16-entry CLUT at (0,480): 0 = transparent, 1 red, 2 green, 3 blue, 4 white
		gp0(32'hA000_0000); gp0({16'd480, 16'd0}); gp0({16'd1, 16'd16});
		gp0({16'h001F, 16'h0000}); gp0({16'h7C00, 16'h03E0}); gp0({16'h0000, 16'h7FFF});
		gp0(32'd0); gp0(32'd0); gp0(32'd0); gp0(32'd0); gp0(32'd0);
		// a 4-bit texture, 8x2 texels, at halfword column 576 (= texpage unit 9):
		// row 0 = 1 2 1 2 3 4 3 4, row 1 = all 0 (transparent)
		gp0(32'hA000_0000); gp0({16'd0, 16'd576}); gp0({16'd2, 16'd2});
		gp0(32'h4343_2121); gp0(32'h0000_0000);
		// an 8-bit texture, 4x1 texels, at column 640 (unit 10): 1 2 3 4
		gp0(32'hA000_0000); gp0({16'd0, 16'd640}); gp0({16'd1, 16'd2});
		gp0(32'h0403_0201);
		// a blue floor under the test area so transparent texels are visible as "untouched"
		gp0(32'h027C_0000); gp0({16'd100, 16'd300}); gp0({16'd4, 16'd64});
		idle();
		// 4-bit rect: texpage unit 9, depth 0; CLUT (0,480) -> 480<<6 = 0x7800
		gp0(32'hE100_0000 | 32'd9);
		gp0(32'h6500_0000); gp0({16'd100, 16'd300}); gp0({16'h7800, 8'd0, 8'd0}); gp0({16'd2, 16'd8});
		idle();
		check(vram_px(10'd300, 9'd100) == 16'h001F, "4-bit CLUT texel 0 -> palette 1 (red)");
		check(vram_px(10'd301, 9'd100) == 16'h03E0, "4-bit CLUT texel 1 -> palette 2 (green)");
		check(vram_px(10'd304, 9'd100) == 16'h7C00, "4-bit CLUT texel 4 -> palette 3 (blue)");
		check(vram_px(10'd307, 9'd100) == 16'h7FFF, "4-bit CLUT texel 7 -> palette 4 (white)");
		check(vram_px(10'd300, 9'd101) == 16'h3C00, "4-bit CLUT index 0 is transparent (floor stays)");
		// 8-bit rect: texpage unit 10, depth 1 (bit 7)
		gp0(32'hE100_0000 | 32'd10 | 32'h80);
		gp0(32'h6500_0000); gp0({16'd100, 16'd320}); gp0({16'h7800, 8'd0, 8'd0}); gp0({16'd1, 16'd4});
		idle();
		check(vram_px(10'd320, 9'd100) == 16'h001F, "8-bit CLUT texel 0 -> red");
		check(vram_px(10'd321, 9'd100) == 16'h03E0, "8-bit CLUT texel 1 -> green");
		check(vram_px(10'd322, 9'd100) == 16'h7C00, "8-bit CLUT texel 2 -> blue");
		check(vram_px(10'd323, 9'd100) == 16'h7FFF, "8-bit CLUT texel 3 -> white");
		$display("    8-bit rect texels: %04h %04h %04h %04h  floor at (300,101) %04h  texture halfwords %04h %04h", vram_px(10'd320, 9'd100), vram_px(10'd321, 9'd100), vram_px(10'd322, 9'd100), vram_px(10'd323, 9'd100), vram_px(10'd300, 9'd101), vram_px(10'd640, 9'd0), vram_px(10'd641, 9'd0));
		// a texture window: mask x = 1 (8 texels), offset 0: u = 9 must sample texel 1 (green)
		gp0(32'hE100_0000 | 32'd9);
		gp0(32'hE200_0000 | 32'd1);
		gp0(32'h6500_0000); gp0({16'd100, 16'd340}); gp0({16'h7800, 8'd0, 8'd9}); gp0({16'd1, 16'd1});
		gp0(32'hE200_0000);
		idle();
		$display("    window texel: %04h   quad texels: %04h %04h %04h %04h", vram_px(10'd340, 9'd100), vram_px(10'd350, 9'd100), vram_px(10'd351, 9'd100), vram_px(10'd352, 9'd100), vram_px(10'd353, 9'd100));
		check(vram_px(10'd340, 9'd100) == 16'h03E0, "texture window wraps u=9 to texel 1 (green)");
		// a raw textured quad (2Dh) over the 8-bit texture: 4x1 at (350,100)
		gp0(32'hE100_0000 | 32'd10 | 32'h80);
		gp0(32'h2D00_0000);
		gp0({16'd100, 16'd350}); gp0({16'h7800, 8'd0, 8'd0});
		gp0({16'd100, 16'd354}); gp0(32'h008A_0004);   // texpage in bits 16-24: x unit 10, depth 8-bit (bit 23); uv (4,0)
		gp0({16'd101, 16'd350}); gp0({16'd0, 8'd1, 8'd0});
		gp0({16'd101, 16'd354}); gp0({16'd0, 8'd1, 8'd4});
		idle();
		check(vram_px(10'd350, 9'd100) == 16'h001F, "raw textured quad, 8-bit: texel 0 red");
		$display("    raw quad pixels 350..353: %04h %04h %04h %04h", vram_px(10'd350, 9'd100), vram_px(10'd351, 9'd100), vram_px(10'd352, 9'd100), vram_px(10'd353, 9'd100));
		check(vram_px(10'd352, 9'd100) == 16'h7C00, "raw textured quad, 8-bit: texel 2 blue");

		// --- a texture big enough to walk out of the line being held -------------
		//
		// Every palette test above is a handful of texels: one 16-byte line covers
		// the whole texture and the whole palette, so the line the engine holds on
		// to is fetched once and hits forever after. That is the one case a stale
		// or misaddressed hold cannot fail.
		//
		// The BIOS draws its text from a texture wide enough that the fetch walks
		// across line after line, and back again on the next row. So: 64 texels a
		// row at 4 bits each is 32 bytes, two whole lines per row, eight rows, and
		// every pixel checked against the palette entry it should have got.
		$display("--- a 64 x 8 4-bit texture, wider than the line being held ---");
		// palette of 16 at (0,482): entry 0 transparent, the rest all different
		gp0(32'hA000_0000); gp0({16'd482, 16'd0}); gp0({16'd1, 16'd16});
		// One call per statement. A Verilog function has ONE set of storage for
		// its arguments, so two calls in the same expression overwrite each
		// other -- which quietly gave every even palette entry the value of
		// entry 0 and looked exactly like a hardware bug.
		for (k = 0; k < 8; k = k + 1) begin
			pa = pal(2*k);
			pb = pal(2*k + 1);
			gp0({pb, pa});
		end
		// the texture at halfword column 704 (texpage unit 11), 8 rows of 16 words
		gp0(32'hA000_0000); gp0({16'd0, 16'd704}); gp0({16'd8, 16'd16});
		for (ty = 0; ty < 8; ty = ty + 1)
			for (tx = 0; tx < 8; tx = tx + 1)
				gp0(texword(tx, ty));
		// a floor so a transparent texel is visibly untouched
		gp0(32'h02FF_FFFF); gp0({16'd200, 16'd400}); gp0({16'd8, 16'd64});
		idle();
		// draw it: texpage unit 11, 4-bit, raw, palette at (0,482) -> 482<<6
		gp0(32'hE100_0000 | 32'd11);
		gp0(32'h6500_0000); gp0({16'd200, 16'd400}); gp0({16'h7880, 8'd0, 8'd0}); gp0({16'd8, 16'd64});
		idle();
		// what the texture actually holds, straight out of VRAM, so a wrong
		// answer can be blamed on the upload or on the lookup but not both
		$display("    texture halfwords 704..707 of row 0: %04h %04h %04h %04h",
		         vram_px(10'd704, 9'd0), vram_px(10'd705, 9'd0),
		         vram_px(10'd706, 9'd0), vram_px(10'd707, 9'd0));
		$display("    palette entries 0..3 at (0,482): %04h %04h %04h %04h",
		         vram_px(10'd0, 9'd482), vram_px(10'd1, 9'd482),
		         vram_px(10'd2, 9'd482), vram_px(10'd3, 9'd482));
		$display("    floor under the draw, off to the side: %04h", vram_px(10'd470, 9'd200));
		bad = 0;
		for (ty = 0; ty < 8; ty = ty + 1)
			for (tx = 0; tx < 64; tx = tx + 1) begin
				want = (((tx + ty) & 15) == 0) ? 16'h7FFF : pal((tx + ty) & 15);
				got16 = vram_px(10'd400 + tx[9:0], 9'd200 + ty[8:0]);
				if (got16 !== want) begin
					bad = bad + 1;
					if (bad < 6)
						$display("    texel (%0d,%0d) index %0d: got %04h want %04h",
						         tx, ty, (tx + ty) & 15, got16, want);
				end
			end
		$display("    %0d of 512 textured pixels wrong", bad);
		check(bad == 0, "a texture wider than one line is sampled correctly throughout");

		// --- the BIOS menu's own "CD PLAYER" packet, with its environment ---
		// CLUT at (0,480): white, dark grey, transparent
		gp0(32'hA000_0000); gp0({16'd480, 16'd0}); gp0({16'd1, 16'd16});
		gp0({16'h0C63, 16'h7FFF}); gp0({16'h0000, 16'h0000});
		gp0(32'd0); gp0(32'd0); gp0(32'd0); gp0(32'd0); gp0(32'd0); gp0(32'd0);
		// a 4-bit sheet at (640,0), 55 halfwords x 48: background index 2, one glyph column of index 0 at u=8..11 (halfword 2)
		gp0(32'hA000_0000); gp0({16'd0, 16'd640}); gp0({16'd48, 16'd55});
		for (k = 0; k < 48 * 55 / 2; k = k + 1) gp0((k < 660) ? 32'h0000_0000 : 32'h2222_2222);   // rows 0..23 glyph (index 0), rows 24..47 background (index 2)
		gp0(32'h027C_0000); gp0({16'd300, 16'd60}); gp0({16'd60, 16'd200});     // a blue floor under the quad
		idle();
		gp0(32'hE100_060A);                     // the menu's E1: page 10, dither on, draw-to-display
		gp0(32'hE200_0000); gp0(32'hE600_0000);
		gp0(32'h2C80_8080);
		gp0({16'd320, 16'd80});  gp0(32'h7800_0000);
		gp0({16'd320, 16'd240}); gp0(32'h000A_009F);
		gp0({16'd344, 16'd80});  gp0(32'h0080_2F00);
		gp0({16'd344, 16'd240}); gp0(32'h0080_2F9F);
		idle();
		$display("    menu text quad: rows v<24 (glyph) at (100,325)=%04h (200,330)=%04h ; rows v>=24 (bg) at (100,340)=%04h", vram_px(10'd100, 9'd325), vram_px(10'd200, 9'd330), vram_px(10'd100, 9'd340));
		// (the menu's E1 dithers, and a modulated texel is dithered: white at (100,325) takes
		// the matrix's +2 and stays 31; at (200,330) it takes -3, 248-3 -> 30 a channel)
		check(vram_px(10'd100, 9'd325) == 16'h7FFF && vram_px(10'd200, 9'd330) == 16'h7BDE, "menu text quad: glyph texels (index 0) are white");
		check(vram_px(10'd100, 9'd340) == 16'h3C00, "menu text quad: background texels (index 2) are transparent");

		// single lines, flat and Gouraud, each followed by a fill that must still
		// parse: a line that eats the wrong number of words desyncs everything after
		gp0(32'h40FF_00FF); gp0({16'd20, 16'd200}); gp0({16'd60, 16'd300});      // magenta (200,20)->(300,60)
		gp0(32'h0200_FF00); gp0({16'd230, 16'd0}); gp0({16'd8, 16'd64});         // green fill 64x8 at (0,230)
		gp0(32'h50FF_FFFF); gp0({16'd150, 16'd10}); gp0(32'h0000_0000); gp0({16'd150, 16'd100});   // white->black (10,150)->(100,150)
		gp0(32'h0200_00FF); gp0({16'd230, 16'd64}); gp0({16'd8, 16'd64});        // red fill 64x8 at (64,230)
		idle();
		p = vram_px(10'd250, 9'd40);
		check(p == 16'h7C1F, "a flat line is drawn (magenta at its midpoint)");
		p = vram_px(10'd20, 9'd233);
		check(p == 16'h03E0, "and the fill after it parsed (green)");
		p = vram_px(10'd12, 9'd150);
		check(p != 16'd0 && p != 16'h03E0, "a Gouraud line is drawn");
		p = vram_px(10'd80, 9'd233);
		check(p == 16'h001F, "and the fill after it parsed (red)");
		check(gpu.busy == 1'b0 && gpu.ds == 6'd0, "engine idle after the lines");

		// a flat polyline of three segments: (10,100) -> (60,100) -> (60,130) -> (110,130)
		gp0(32'h48FF_FFFF); gp0({16'd100, 16'd10}); gp0({16'd100, 16'd60});
		gp0({16'd130, 16'd60}); gp0({16'd130, 16'd110}); gp0(32'h5555_5555);
		idle();
		p = vram_px(10'd85, 9'd130);
		check(p == 16'h7FFF, "the polyline's third segment was drawn");
		p = vram_px(10'd60, 9'd115);
		check(p == 16'h7FFF, "and its second");
		check(gpu.busy == 1'b0 && gpu.ds == 6'd0, "and the engine is idle after the terminator");

		// VRAM -> CPU: read the quad back through GPUREAD. The engine must hold
		// each word until it is collected, and stay busy meanwhile.
		begin : c0test
			integer n, got, k2; reg [31:0] rw;
			gp0(32'hC000_0000); gp0({16'd150, 16'd220}); gp0({16'd2, 16'd8});   // 8x2 at (220,150)
			repeat (3000) @(posedge clk);
			check(gpu.busy == 1'b1, "C0 keeps the engine busy until the words are collected");
			got = 0;
			for (n = 0; n < 8; n = n + 1) begin
				k2 = 0; rw = 0;
				while (rw == 0 && k2 < 2000) begin
					@(posedge clk); sel <= 1; we <= 0; a4 <= 0; #1 rw = rdata; @(posedge clk); sel <= 0; @(posedge clk); k2 = k2 + 1;
				end
				if (rw == 32'h03FF_03FF) got = got + 1;   // BGR555 yellow, twice
			end
			check(got == 8, "and the eight words read back are the quad's yellow");
			idle();
		end

		// display: 320x240 from (0,0), on
		gp1(32'h0500_0000);
		gp1(32'h0800_0001);
		gp1(32'h0300_0000);

		// two frames, so the second is a complete one
		frames = 0;
		while (frames < 2) begin
			@(posedge clk);
			if (gpu.frame_tick) frames = frames + 1;
		end
		// let the second scan finish
		while (gpu.sc != 2'd0) @(posedge clk);
		repeat (100) @(posedge clk);

		check(frame[100 * 320 + 100] != 8'd0, "the display emitted the triangle's pixel");
		check(frame[185 * 320 + 260] == 8'hFC, "and the quad's, as RGB332 yellow");

		fd = $fopen("../../build/sim/gpu_frame.bin", "wb");
		for (k = 0; k < 320 * 240; k = k + 1) $fwrite(fd, "%c", frame[k]);
		$fclose(fd);
		$display("  frame written to build/sim/gpu_frame.bin (cache hits %0d misses %0d)", hits, misses);

		// --- what a small primitive costs, against the console's time for it ------------
		// (fed as fast as this bench feeds, a word every two clocks -- a DMA's pace)
		begin : small_prims
			integer t0, i, n;
			gp0(32'hE300_0000); gp0(32'hE400_0000 | 1023 | (511 << 10)); gp0(32'hE500_0000);   // all of VRAM
			gp0(32'hE100_0008);                         // texture page 8, 4-bit
			idle(); t0 = cyc;
			for (i = 0; i < 64; i = i + 1)               // 8x8 textured sprites
				begin gp0(32'h7480_8080); gp0(xy(20 + (i % 32) * 9, 300 + (i / 32) * 9)); gp0({16'h7800, 8'd0, 8'd0}); end
			idle(); n = cyc - t0;
			$display("    64 sprites 8x8 textured: %0d clocks, %0d each (console ~53)", n, n / 64);
			idle(); t0 = cyc;
			for (i = 0; i < 64; i = i + 1)               // flat triangles, 18 pixels
				begin gp0(32'h2000_FF00); gp0(xy(300 + (i % 32) * 8, 100 + (i / 32) * 8)); gp0(xy(300 + (i % 32) * 8, 106 + (i / 32) * 8)); gp0(xy(306 + (i % 32) * 8, 100 + (i / 32) * 8)); end
			idle(); n = cyc - t0;
			$display("    64 flat triangles (18 px): %0d clocks, %0d each (console ~24)", n, n / 64);
			idle(); t0 = cyc;
			for (i = 0; i < 64; i = i + 1) begin         // Gouraud textured quads, 10x10
				gp0(32'h3C80_8080); gp0(xy(400 + (i % 32) * 11, 320 + (i / 32) * 11)); gp0({16'h7800, 8'd0, 8'd0});
				gp0(32'h0040_4040); gp0(xy(410 + (i % 32) * 11, 320 + (i / 32) * 11)); gp0({16'h0008, 8'd0, 8'd9});
				gp0(32'h0080_8080); gp0(xy(400 + (i % 32) * 11, 330 + (i / 32) * 11)); gp0({16'd0, 8'd9, 8'd0});
				gp0(32'h00FF_FFFF); gp0(xy(410 + (i % 32) * 11, 330 + (i / 32) * 11)); gp0({16'd0, 8'd9, 8'd9});
			end
			idle(); n = cyc - t0;
			$display("    64 Gouraud textured quads 10x10: %0d clocks, %0d each (console ~270)", n, n / 64);
			$display("    drawn? sprite %h  triangle %h  quad %h", vram_px(10'd23, 9'd303), vram_px(10'd301, 9'd101), vram_px(10'd405, 9'd325));
		end

		// the shape of ps1-tests gpu/bandwidth's vramToVram: 320 wide, aligned (here 8 rows of it).
		// The board's old engine took 3.9 clocks a pixel; the console 2.
		cp_t0 = busy_clks;
		gp0(32'h8000_0000); gp0({16'd400, 16'd0}); gp0({16'd400, 16'd320}); gp0({16'd8, 16'd320});
		idle();
		$display("    BANDWIDTH copy 320x8: %0d clocks, %0d.%02d a pixel", busy_clks - cp_t0, (busy_clks - cp_t0) / 2560, ((busy_clks - cp_t0) % 2560) * 100 / 2560);

		// ...and its rectangles: 320x16 opaque, then semi-transparent (console: x1.5)
		gp0(32'hE100_0000 | 32'h0000_0100); gp0(32'hE300_0000); gp0(32'hE400_0000 | 32'd1023 | (32'd511 << 10));
		cp_t0 = busy_clks;
		gp0(32'h6040_2010); gp0({16'd420, 16'd0}); gp0({16'd16, 16'd320});
		idle();
		$display("    BANDWIDTH rect 320x16: %0d clocks", busy_clks - cp_t0);
		cp_t0 = busy_clks; cp_d0 = r_dst; cp_m0 = misses; cp_f0 = r_full; cp_x0 = r_tex; cp_n0 = n_out_clks; cp_r0 = r_run_clks;
		gp0(32'h6240_2010); gp0({16'd440, 16'd0}); gp0({16'd16, 16'd320});
		idle();
		$display("    BANDWIDTH semi rect 320x16: %0d clocks, %0d waiting on the destination, %0d cache misses", busy_clks - cp_t0, r_dst - cp_d0, misses - cp_m0);
		$display("      write held %0d, texel %0d, read-ahead out %0d, raster busy %0d", r_full - cp_f0, r_tex - cp_x0, n_out_clks - cp_n0, r_run_clks - cp_r0);

		// Syphon Filter's title fade (board trace, 2026-10-10): texpage 02C0 (semi mode 2, subtract),
		// a semi-transparent 416x272 rectangle at (-208,-136) over a 320x240 area offset to its middle,
		// then a 2x1 copy. The GPU hung there on the board (the game's DrawSync timed out).
		gp0(32'hE300_0000); gp0(32'hE400_0000 | 32'd319 | (32'd239 << 10)); gp0(32'hE500_0000 | 32'd160 | (32'd120 << 11));
		cp_t0 = busy_clks;
		gp0(32'hE100_02C0); gp0(32'h0000_0000);
		gp0(32'h620F_0F0F); gp0(32'hFF78_FF30); gp0(32'h0110_01A0);
		gp0(32'h8000_0000); gp0(32'h0000_0000); gp0(32'h0000_0000); gp0(32'h0001_0002);
		gp0(32'h0000_0000); gp0(32'h0000_0000);
		fork : fade
			begin idle(); $display("    SYPHON fade + copy done: %0d clocks", busy_clks - cp_t0); disable fade; end
			begin repeat (3000000) @(posedge clk); $display("    SYPHON fade HUNG: gpu ds %0d busy %b raster busy %b", gpu.ds, gpu.busy, gpu.r_busy); errors = errors + 1; disable fade; end
		join
		gp0(32'hE500_0000); gp0(32'hE100_0100);
		$display("");
		$display("    ENGINE BUSY CLOCKS: %0d", busy_clks);
		$display("    raster held: texel line %0d, destination line %0d, block queue %0d, palette %0d clocks", r_tex, r_dst, r_full, r_clut);
		if (errors == 0) $display("tb_ps1_gpu: all checks passed");
		else             $display("tb_ps1_gpu: %0d FAIL(s)", errors);
		$finish;
	end
	// WATCHDOG: a hang prints where everything stood
	integer n_mrd = 0, n_mval = 0, n_pval0 = 0, n_vcreq = 0;
	always @(posedge clk) begin
		if (m_req && m_ready && !m_we) n_mrd = n_mrd + 1;
		if (m_valid) n_mval = n_mval + 1;
		if (p_valid[0]) n_pval0 = n_pval0 + 1;
		if (vc_req && vc_ready && !vc_we) n_vcreq = n_vcreq + 1;
	end
	initial begin
		#40_000_000;
		$display("  mem reads %0d, mem valids %0d, port0 valids %0d, vc reads taken %0d, pf_i=%0d pf_n=%0d arb q_full=%0d", n_mrd, n_mval, n_pval0, n_vcreq, vram.pf_i, vram.pf_n, arb.q_full);
		$display("FAIL: timeout  gpu.ds=%0d busy=%0d v_req=%0d v_we=%0d v_around=%0d v_ack=%0d | vp: r_hold=%0d gp_req=%0d gp_ack=%0d blk: acc_v=%0d q=%0d/%0d ds=%0d flush_p=%0d idle=%0d | vram.st=%0d pf_busy=%0d",
			gpu.ds, gpu.busy, v_req, v_we, v_around, v_ack, vp.r_hold, gp_req, gp_ack, vp.blk.acc_v, vp.blk.q_wp, vp.blk.q_rp, vp.blk.ds, vp.blk.flush_p, vp.blk.idle, vram.st, vram.pf_busy);
		$finish;
	end
endmodule

`default_nettype wire
