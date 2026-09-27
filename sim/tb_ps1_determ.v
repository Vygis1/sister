//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_determ - the same drawing must give the same pixels, whatever the
// memory does.
//
// Measured on the board 2026-09-25 with the game PAUSED, so the scene was
// frozen: two dumps of the display list in RAM were 5 lines different out of
// 12,288 -- the processor builds the same list every frame -- and yet 4.4% of
// the picture changed from one frame to the next, with crates drawn leaning in
// one and square in the next. Same input, different output, so the race is in
// the drawing engine.
//
// This draws one fixed scene and hashes the video memory it produced. The only
// thing that differs between runs is how long the memory takes to answer
// (+LAT=n). A design without a race gives the same hash every time.
//
//   ./tools/ps1determ.sh
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_ps1_determ;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	integer LAT;
	initial LAT = 6;

	reg        sel = 0, we = 0, a4 = 0;
	reg [31:0] wdata = 0;
	wire [31:0] rdata;
	wire [28:0] v_addr, s_addr;
	wire        v_req, v_we, s_req;
	wire [127:0] s_vline, v_wdata128, v_line, x_line, gp_line;
	wire [3:0]  v_be;
	wire [31:0] v_wdata, v_rdata, s_rdata;
	wire        v_lwe, v_around, x_valid, v_ack, s_ack;
	wire [24:0] x_addr;
	wire        px_valid; wire [8:0] px_x, px_y; wire [7:0] px_rgb;
	wire        vblank, hblank, dot_ce, irq;
	wire        v_lin_w, g_lin_w;
	wire        dma_ready; wire [31:0] dma_rdata; wire dma_rvalid;

	ps1_gpu gpu ( .v_lin(v_lin_w),
		.clk(clk), .rst(rst),
		.sel(sel), .we(we), .a4(a4), .dma_active(1'b0), .cap_every_vsync(1'b0), .gpu_fast(1'b1),
		.no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0), .wdata(wdata), .rdata(rdata),
		.dma_wr(1'b0), .dma_data(32'd0), .dma_ready(dma_ready),
		.dma_rd(1'b0), .dma_rdata(dma_rdata), .dma_rvalid(dma_rvalid),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack),
		.s_addr(s_addr), .s_req(s_req), .s_rdata(s_rdata), .s_ack(s_ack), .s_line(s_vline),
		.scan_hold(1'b0), .scan_enable(1'b0), .scan_lines(1'b0),
		.tx_valid(x_valid), .tx_addr(x_addr), .tx_line(x_line), .v_around(v_around),
		.fl_valid(), .fl_data(), .fl_x(), .fl_y(),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb),
		.vblank(vblank), .hblank(hblank), .dot_ce(dot_ce), .irq(irq)
	);

	wire [23:0]  m_addr; wire m_req, m_we; wire [127:0] m_wdata;
	reg          m_ready; reg [127:0] m_rdata = 0; reg m_valid = 0;
	wire [15:0]  m_wmask;
	wire [28:0]  gp_addr; wire gp_req, gp_around, gp_ack; wire [31:0] gp_rdata;
	wire [23:0]  bk_addr, vc_addr; wire bk_req, bk_we, bk_ready, vc_req, vc_we, vc_ready, vc_valid;
	wire [127:0] bk_wdata, vc_wdata, vc_rdata; wire [15:0] bk_wmask, vc_wmask;
	wire         inv_v; wire [24:0] inv_line; wire bk_busy;

	ps1_vram_port vp ( .v_lin(v_lin_w), .g_lin(g_lin_w),
		.clk(clk), .rst(rst),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata),
		.v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(v_around),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack), .eng_idle(!gpu.busy),
		.host_flush(1'b0), .busy(bk_busy),
		.g_addr(gp_addr), .g_req(gp_req), .g_around(gp_around), .g_rdata(gp_rdata),
		.g_line(gp_line), .g_ack(gp_ack),
		.m_addr(bk_addr), .m_req(bk_req), .m_we(bk_we), .m_wdata(bk_wdata),
		.m_wmask(bk_wmask), .m_ready(bk_ready),
		.inv_v(inv_v), .inv_line(inv_line));

	wire [1:0] p_ready, p_valid; wire [255:0] p_rdata;
	assign bk_ready = p_ready[1]; assign vc_ready = p_ready[0];
	assign vc_valid = p_valid[0]; assign vc_rdata = p_rdata[127:0];
	mem_arb #(.PORTS(2), .AW(24)) arb (
		.clk(clk), .rst(rst),
		.p_addr({bk_addr, vc_addr}), .p_req({bk_req, vc_req}), .p_we({bk_we, vc_we}),
		.p_wdata({bk_wdata, vc_wdata}), .p_wmask({bk_wmask, vc_wmask}),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid));

	ps1_cache #(.IDXBITS(6), .A_AROUND(1)) vram ( .a_lin(g_lin_w),
		.b_first(1'b0), .flush(1'b0), .flush_busy(), .inv_v(inv_v), .inv_line(inv_line),
		.clk(clk), .rst(rst),
		.a_addr(gp_addr), .a_req(gp_req), .a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0),
		.a_we(1'b0), .a_be(4'hF), .a_wdata(32'd0),
		.a_around(gp_around), .x_valid(x_valid), .x_addr(x_addr), .x_line(x_line),
		.a_rdata(gp_rdata), .a_ack(gp_ack),
		.b_addr(rd_addr), .b_req(rd_req), .b_we(1'b0), .b_be(4'hF), .b_wdata(32'd0),
		.b_rdata(s_rdata), .b_ack(s_ack), .b_line(s_vline), .a_line(gp_line),
		.m_addr(vc_addr), .m_req(vc_req), .m_we(vc_we), .m_wdata(vc_wdata), .m_wmask(vc_wmask),
		.m_ready(vc_ready), .m_rdata(vc_rdata), .m_valid(vc_valid),
		.dbg_hits(), .dbg_misses());

	// THE FRAME CAPTURE, as a reader on port B. On the board the capture is
	// reading video memory for about half of every frame, through this same
	// cache and arbiter, while the drawing engine works -- and it is given
	// priority over the engine. Leaving it out is why a first version of this
	// bench found the drawing perfectly deterministic: the one large piece of
	// concurrency the machine actually has was missing from it.
	reg [28:0] rd_addr; reg rd_req;
	always @(posedge clk) begin
		if (rst) begin rd_addr <= 29'd0; rd_req <= 1'b0; end
		else begin
			rd_req <= 1'b1;
			if (rd_req && s_ack) begin
				rd_addr <= rd_addr + 29'd16;                 // the next line along
				if (rd_addr > 29'd300000) rd_addr <= 29'd0;
			end
		end
	end

	// The memory, with a settable latency. This is the ONLY thing that differs
	// between runs, so any difference in the picture is a race.
	reg [127:0] mem [0:65535];
	localparam MAXLAT = 24;
	reg [127:0] pd [0:MAXLAT-1];
	reg         pv [0:MAXLAT-1];
	integer pi;
	always @(*) m_ready = m_req;
	always @(posedge clk) begin
		m_valid <= pv[LAT-1]; m_rdata <= pd[LAT-1];
		for (pi = MAXLAT-1; pi > 0; pi = pi - 1) begin pv[pi] <= pv[pi-1]; pd[pi] <= pd[pi-1]; end
		pv[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) begin
				for (pi = 0; pi < 16; pi = pi + 1)
					if (m_wmask[pi]) mem[m_addr[15:0]][pi*8 +: 8] <= m_wdata[pi*8 +: 8];
			end else begin pv[0] <= 1'b1; pd[0] <= mem[m_addr[15:0]]; end
		end
	end

	task gp0; input [31:0] w; begin
		@(negedge clk); while (gpu.f_full) @(negedge clk);
		sel = 1; we = 1; a4 = 0; wdata = w;
		@(negedge clk); sel = 0; we = 0;
	end endtask
	task gp1; input [31:0] w; begin
		@(negedge clk); sel = 1; we = 1; a4 = 1; wdata = w;
		@(negedge clk); sel = 0; we = 0;
	end endtask
	task drain; begin
		@(negedge clk);
		while (!(gpu.f_empty && !gpu.busy && !bk_busy)) @(negedge clk);
		repeat (8) @(negedge clk);
	end endtask

	integer i, j, t, errors, nz, nzall;
	reg [31:0] h, hash0;
	reg [31:0] w0, w1, w2;
	integer lat_of [0:4];

	// draw the scene, from reset, and hash what ended up in video memory
	task run_scene; output [31:0] hh; begin
		rst = 1;
		for (i = 0; i < 65536; i = i + 1) mem[i] = 128'd0;
		for (i = 0; i < MAXLAT; i = i + 1) begin pv[i] = 0; pd[i] = 0; end
		repeat (8) @(posedge clk); rst = 0; repeat (4) @(posedge clk);

		gp1(32'h0000_0000);
		// Texture page 4 (x = 256), row 1 (y = 256), FIFTEEN BIT colour. With
		// the four-bit depth this started with, every texel indexes a palette
		// that was never set up, they all come out transparent, and the bench
		// happily agreed with itself about a blank screen.
		gp0(32'hE1000000 + 32'd256 + 32'd16 + 32'd4);   // bits 8:7 = 2 is 15-bit
		gp0(32'hE3000000);
		gp0(32'hE4000000 + (32'd239 * 1024) + 32'd511);
		gp0(32'hE5000000);

		// the texture itself, into that page
		gp0(32'hA0000000);
		gp0((32'd256 * 65536) + 32'd256);
		// 32 wide by 16 tall is 512 pixels, which is 256 words. Sending fewer
		// words than the size asks for leaves the engine waiting for ever.
		gp0((32'd16 * 65536) + 32'd32);
		for (i = 0; i < 256; i = i + 1) gp0(32'h4210BDEF + i * 32'h00010001);
		drain();

		// a run of shaded textured triangles of the kind a scene is made of,
		// each drawn over the last so the destination path is exercised too
		for (j = 0; j < 40; j = j + 1) begin
			w0 = ((32'd30 + j * 3) * 65536) + (32'd20 + j);
			w1 = ((32'd40 + j * 3) * 65536) + (32'd80 + j * 2);
			w2 = ((32'd120 + j * 2) * 65536) + (32'd60 + j);
			// A shaded textured polygon carries its palette in the TOP half of the
			// first texture-coordinate word and its TEXTURE PAGE in the top half
			// of the second. Leaving those zero selects page 0 at four bits per
			// texel with no palette, every texel comes out transparent, and
			// nothing is drawn at all -- which is exactly what this bench did
			// until it was made to count the pixels it had put down.
			gp0(32'h34808080);
			gp0(w0); gp0(32'h00000000);                 // uv 0,0
			gp0(32'h00C0C0C0);
			gp0(w1); gp0(32'h0114001F);                 // texpage 0x114, uv 31,0
			gp0(32'h00808080);
			gp0(w2); gp0(32'h00000F00);                 // uv 0,15
			// NO drain here on purpose. A game streams its polygons back to back
			// through the DMA, so one primitive's setup overlaps the last one's
			// drawing -- and that overlap is where a race lives. Draining after
			// every polygon hides it: the scene came out identical at every
			// memory latency that way.
		end
		drain();

		// A video memory row is 2048 bytes, which is 128 of these lines, so the
		// triangles at y 30..125 live in lines 3840..16000. Hashing only the
		// first 4096 lines hashed 32 rows of zeros and every latency agreed
		// about nothing.
		h = 32'h811C9DC5;
		nz = 0; nzall = 0;
		for (i = 0; i < 20000; i = i + 1) begin
			if (mem[i] !== 128'd0) nz = nz + 1;
			for (j = 0; j < 4; j = j + 1)
				h = (h ^ mem[i][j*32 +: 32]) * 32'd16777619;
		end
		for (i = 0; i < 65536; i = i + 1) if (mem[i] !== 128'd0) nzall = nzall + 1;
		hh = h;
	end endtask

	initial begin
		lat_of[0] = 6; lat_of[1] = 4; lat_of[2] = 9; lat_of[3] = 14; lat_of[4] = 20;
		errors = 0;
		for (t = 0; t < 5; t = t + 1) begin
			LAT = lat_of[t];
			run_scene(h);
			if (t == 0) hash0 = h;
			$display("  memory latency %2d clocks -> %0d lines in the triangle area, %0d anywhere, hash %08x%0s",
			         LAT, nz, nzall, h, (t != 0 && h !== hash0) ? "   <== DIFFERENT" : "");
			if (t != 0 && h !== hash0) errors = errors + 1;
		end
		// A bench that draws nothing agrees with itself perfectly. Guard it.
		if (nz < 500) begin
			$display("tb_ps1_determ: FAIL - only %0d lines were drawn, the scene is not being drawn at all", nz);
			errors = errors + 100;
		end
		if (errors == 0)
			$display("tb_ps1_determ: all checks passed -- the same drawing gives the same pixels at every memory latency");
		else begin
			$display("tb_ps1_determ: %0d of 4 latencies drew a DIFFERENT picture from the same commands", errors);
			$fatal(1);
		end
		$finish;
	end

	initial begin
		#400_000_000;
		$display("tb_ps1_determ: TIMED OUT");
		$fatal(1);
	end
endmodule

`default_nettype wire
