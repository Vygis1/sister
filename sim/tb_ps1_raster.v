`timescale 1ns/1ps
// tb_ps1_raster: the pixel pipeline against a reference drawn the slow way.
//
// The same primitive is drawn by the pipeline (through the VRAM port, the
// block writer, the video cache and an arbiter, as on the board) and by a
// loop in this bench that follows ps1_gpu.v's rules one pixel at a time. Every
// halfword of VRAM must agree afterwards. Then the pipeline's speed is read:
// clocks per pixel landed.
module tb_ps1_raster;
	reg clk = 0; always #15 clk = ~clk;
	reg rst = 1;

	// --- the primitive ------------------------------------------------------------
	reg        start = 0, always_in = 0;
	reg signed [11:0] bx0, bx1, by0, by1;
	reg signed [23:0] e0_0, e1_0, e2_0, sx0, sx1, sx2, sy0, sy1, sy2;
	reg        apos;
	reg signed [31:0] cr_0, cg_0, cb_0, cu_0, cv_0;
	reg signed [31:0] dr_dx, dg_dx, db_dx, du_dx, dv_dx, dr_dy, dg_dy, db_dy, du_dy, dv_dy;
	reg        is_gour = 0, is_tex = 0, is_semi = 0, is_raw = 0;
	reg [7:0]  fr, fg, fb;
	reg [3:0]  tp_x = 0; reg tp_y = 0; reg [1:0] tp_abr = 0, tp_depth = 0;
	reg [15:0] clut = 0;
	reg [4:0]  tw_mx = 0, tw_my = 0, tw_ox = 0, tw_oy = 0;
	reg [9:0]  da_x0 = 0, da_x1 = 1023; reg [8:0] da_y0 = 0, da_y1 = 511;
	reg        mask_set = 0, mask_chk = 0;
	reg        il_skip = 0, il_field = 0, pace = 0;
	wire       busy;

	// --- the VRAM path, as in ps1_top ------------------------------------------------
	wire [28:0] v_addr; wire v_req, v_we, v_around, v_lin_w, v_one_w, g_lin_w; wire [3:0] v_be; wire [31:0] v_wdata, v_rdata; wire [127:0] v_line; wire v_ack;
	wire        x_valid; wire [24:0] x_addr; wire [127:0] x_line;
	wire        st_tex, st_dst, st_full, st_clut;
	ps1_raster dut (
		.clk(clk), .rst(rst), .start(start), .taken(), .busy(busy), .i_always_in(always_in),
		.i_bx0(bx0), .i_bx1(bx1), .i_by0(by0), .i_by1(by1),
		.e0_0(e0_0), .e1_0(e1_0), .e2_0(e2_0), .i_sx0(sx0), .i_sx1(sx1), .i_sx2(sx2), .i_sy0(sy0), .i_sy1(sy1), .i_sy2(sy2), .i_apos(apos),
		.cr_0(cr_0), .cg_0(cg_0), .cb_0(cb_0), .cu_0(cu_0), .cv_0(cv_0),
		.i_dr_dx(dr_dx), .i_dg_dx(dg_dx), .i_db_dx(db_dx), .i_du_dx(du_dx), .i_dv_dx(dv_dx),
		.i_dr_dy(dr_dy), .i_dg_dy(dg_dy), .i_db_dy(db_dy), .i_du_dy(du_dy), .i_dv_dy(dv_dy),
		.i_is_gour(is_gour), .i_is_tex(is_tex), .i_is_semi(is_semi), .i_is_raw(is_raw), .i_dither(1'b0), .i_fr(fr), .i_fg(fg), .i_fb(fb),
		.i_tp_x(tp_x), .i_tp_y(tp_y), .i_tp_abr(tp_abr), .i_tp_depth(tp_depth), .i_clut(clut),
		.i_tw_mx(tw_mx), .i_tw_my(tw_my), .i_tw_ox(tw_ox), .i_tw_oy(tw_oy),
		.no_tcache(1'b0), .no_ccache(1'b0), .no_trun(1'b0),
		.i_da_x0(da_x0), .i_da_x1(da_x1), .i_da_y0(da_y0), .i_da_y1(da_y1), .i_mask_set(mask_set), .i_mask_chk(mask_chk),
		.i_il_skip(il_skip), .il_field(il_field), .pace(pace), .clut_flush(1'b0), .pace_clr(start), .pace_setup(10'd0),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata), .v_around(v_around), .v_lin(v_lin_w), .v_one(v_one_w),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack),
		.tx_valid(x_valid), .tx_addr(x_addr), .tx_line(x_line),
		.inv_en(1'b0), .inv_line(25'd0),
		.st_tex_miss(st_tex), .st_dst_miss(st_dst), .st_full(st_full), .st_clut(st_clut));

	wire [28:0]  gp_addr; wire gp_req, gp_around, gp_ack; wire [31:0] gp_rdata; wire [127:0] gp_line;
	wire [23:0]  bk_addr, vc_addr; wire bk_req, bk_we, bk_ready, vc_req, vc_we, vc_ready, vc_valid; wire [127:0] bk_wdata, vc_wdata, vc_rdata; wire [15:0] bk_wmask, vc_wmask;
	wire         inv_v; wire [24:0] inv_line; wire bk_busy;
	ps1_vram_port vp ( .n_req(1'b0), .n_addr(25'd0), .v_lin(v_lin_w), .v_one(v_one_w), .g_lin(g_lin_w),
		.clk(clk), .rst(rst),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata), .v_lwe(1'b0), .v_wdata128(128'd0), .v_around(v_around),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack), .eng_idle(!busy), .host_flush(1'b0), .busy(bk_busy),
		.g_addr(gp_addr), .g_req(gp_req), .g_around(gp_around), .g_rdata(gp_rdata), .g_line(gp_line), .g_ack(gp_ack),
		.m_addr(bk_addr), .m_req(bk_req), .m_we(bk_we), .m_wdata(bk_wdata), .m_wmask(bk_wmask), .m_ready(bk_ready),
		.inv_v(inv_v), .inv_line(inv_line));
	wire [23:0] m_addr; wire m_req, m_we; wire [127:0] m_wdata; wire [15:0] m_wmask;
	reg m_ready; reg [127:0] m_rdata = 0; reg m_valid = 0;
	wire [1:0] p_ready, p_valid; wire [255:0] p_rdata;
	assign bk_ready = p_ready[1]; assign vc_ready = p_ready[0]; assign vc_valid = p_valid[0]; assign vc_rdata = p_rdata[127:0];
	mem_arb #(.PORTS(2), .AW(24)) arb (
		.clk(clk), .rst(rst),
		.p_addr({bk_addr, vc_addr}), .p_req({bk_req, vc_req}), .p_we({bk_we, vc_we}), .p_wdata({bk_wdata, vc_wdata}), .p_wmask({bk_wmask, vc_wmask}),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid));
	ps1_cache #(.IDXBITS(6), .A_AROUND(1)) vram ( .a_lin(g_lin_w),
		.b_first(1'b0),                 // the capture's port has no priority here
		.flush(1'b0), .flush_busy(), .inv_v(inv_v), .inv_line(inv_line),
		.clk(clk), .rst(rst),
		.a_addr(gp_addr), .a_req(gp_req), .a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0), .a_we(1'b0), .a_be(4'hF), .a_wdata(32'd0),
		.a_around(gp_around), .x_valid(x_valid), .x_addr(x_addr), .x_line(x_line),
		.a_rdata(gp_rdata), .a_ack(gp_ack),
		.b_addr(29'd0), .b_req(1'b0), .b_we(1'b0), .b_be(4'hF), .b_wdata(32'd0),
		.b_rdata(), .b_ack(), .b_line(), .a_line(gp_line),
		.m_addr(vc_addr), .m_req(vc_req), .m_we(vc_we), .m_wdata(vc_wdata), .m_wmask(vc_wmask),
		.m_ready(vc_ready), .m_rdata(vc_rdata), .m_valid(vc_valid),
		.dbg_hits(), .dbg_misses());

	// a megabyte of lines, some latency
	reg [127:0] mem [0:65535];
	localparam RD = 8;
	reg [127:0] pd [0:RD-1]; reg pv [0:RD-1];
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

	// destination fetch latency (request up to answer), and how often
	integer dfn = 0, dfc = 0, dfr = 0; reg dfo = 0;
	always @(posedge clk) begin
		if (dut.fs == 2'd1 && dut.fwho == 2'd1) begin dfc = dfc + 1; if (!dfo) dfn = dfn + 1; dfo = 1; end
		if (dut.fs == 2'd1 && dut.fwho == 2'd1 && v_ack) dfo = 0;
		if (vc_req && !vc_we && vc_ready) dfr = dfr + 1;
	end
	// --- the reference ----------------------------------------------------------------
	reg [15:0] ref_px [0:1024*512-1];
	function [15:0] mem_px; input [9:0] x; input [8:0] y;
		reg [28:0] a; begin a = {y, x[9:1], 2'b00}; mem_px = mem[a[19:4]][a[3:2]*32 + x[0]*16 +: 16]; end
	endfunction
	task set_px; input [9:0] x; input [8:0] y; input [15:0] p;
		reg [28:0] a; begin a = {y, x[9:1], 2'b00}; mem[a[19:4]][a[3:2]*32 + x[0]*16 +: 16] = p; ref_px[{y, x}] = p; end
	endtask
	function [4:0] sat5; input [5:0] v; sat5 = v[5] ? 5'h1F : v[4:0]; endfunction
	function [15:0] modulate; input [15:0] t; input [7:0] r, g, b; reg [12:0] pr, pg, pb;
		begin pr = t[4:0] * r; pg = t[9:5] * g; pb = t[14:10] * b;
		      modulate = {t[15], sat5(pb[12:7]), sat5(pg[12:7]), sat5(pr[12:7])}; end
	endfunction
	function [15:0] blend; input [15:0] back, fore; input [1:0] mode; reg [5:0] r, g, b;
		begin
			case (mode)
			2'd0: begin r = (back[4:0] + fore[4:0]) >> 1; g = (back[9:5] + fore[9:5]) >> 1; b = (back[14:10] + fore[14:10]) >> 1; end
			2'd1: begin r = back[4:0] + fore[4:0]; g = back[9:5] + fore[9:5]; b = back[14:10] + fore[14:10]; end
			2'd2: begin r = (back[4:0] > fore[4:0]) ? back[4:0] - fore[4:0] : 6'd0;
			            g = (back[9:5] > fore[9:5]) ? back[9:5] - fore[9:5] : 6'd0;
			            b = (back[14:10] > fore[14:10]) ? back[14:10] - fore[14:10] : 6'd0; end
			default: begin r = back[4:0] + (fore[4:0] >> 2); g = back[9:5] + (fore[9:5] >> 2); b = back[14:10] + (fore[14:10] >> 2); end
			endcase
			blend = {fore[15], sat5(b), sat5(g), sat5(r)};
		end
	endfunction

	integer x, y, errors = 0, n_ref = 0;
	reg signed [23:0] e0, e1, e2;
	reg signed [31:0] cr, cg, cb, cu, cv;
	reg [7:0] tu, tv, ix; reg [9:0] tx; reg [15:0] hw, texel, pix, dst; reg inside, semi;
	function rin; input signed [23:0] e, sxx, syy; reg tl;
		begin
			tl  = apos ? (sxx > 0 || (sxx == 0 && syy > 0)) : (sxx < 0 || (sxx == 0 && syy < 0));
			rin = apos ? (e > 0 || (e == 0 && tl)) : (e < 0 || (e == 0 && tl));
		end
	endfunction
	task ref_draw;
		begin
			for (y = by0; y <= by1; y = y + 1)
				for (x = bx0; x <= bx1; x = x + 1) begin
					e0 = e0_0 + sx0 * (x - bx0) + sy0 * (y - by0);
					e1 = e1_0 + sx1 * (x - bx0) + sy1 * (y - by0);
					e2 = e2_0 + sx2 * (x - bx0) + sy2 * (y - by0);
					// the console's fill rule: a pixel exactly on an edge is drawn only for a top or
					// left edge (ps1-tests gpu/quad, gpu/triangle)
					inside = always_in || (rin(e0, sx0, sy0) && rin(e1, sx1, sy1) && rin(e2, sx2, sy2));
					if (inside && x >= 0 && x < 1024 && y >= 0 && y < 512
					    && x >= da_x0 && x <= da_x1 && y >= da_y0 && y <= da_y1
					    && !(il_skip && (y[0] == il_field))) begin
						cr = cr_0 + dr_dx * (x - bx0) + dr_dy * (y - by0);
						cg = cg_0 + dg_dx * (x - bx0) + dg_dy * (y - by0);
						cb = cb_0 + db_dx * (x - bx0) + db_dy * (y - by0);
						cu = cu_0 + du_dx * (x - bx0) + du_dy * (y - by0);
						cv = cv_0 + dv_dx * (x - bx0) + dv_dy * (y - by0);
						if (!is_gour) begin cr = {fr, 16'd0}; cg = {fg, 16'd0}; cb = {fb, 16'd0}; end
						pix = {1'b0, cb[23:19], cg[23:19], cr[23:19]};
						semi = is_semi;
						if (is_tex) begin
							tu = (cu[23:16] & ~{tw_mx, 3'd0}) | ({tw_ox, 3'd0} & {tw_mx, 3'd0});
							tv = (cv[23:16] & ~{tw_my, 3'd0}) | ({tw_oy, 3'd0} & {tw_my, 3'd0});
							case (tp_depth)
							2'd0: tx = {tp_x, 6'd0} + {4'd0, tu[7:2]};
							2'd1: tx = {tp_x, 6'd0} + {3'd0, tu[7:1]};
							default: tx = {tp_x, 6'd0} + {2'd0, tu};
							endcase
							hw = ref_px[{tp_y, tv, tx}];
							case (tp_depth)
							2'd0: begin ix = (hw >> {tu[1:0], 2'b00}) & 8'hF; texel = ref_px[{clut[14:6], {clut[5:0], 4'd0} + ix}]; end
							2'd1: begin ix = (hw >> {tu[0], 3'b000}) & 8'hFF; texel = ref_px[{clut[14:6], {clut[5:0], 4'd0} + ix}]; end
							default: texel = hw;
							endcase
							if (texel == 16'd0) inside = 0;    // transparent
							pix = is_raw ? texel : modulate(texel, cr[23:16], cg[23:16], cb[23:16]);
							semi = is_semi && texel[15];
						end
						if (inside) begin
							dst = ref_px[{y[8:0], x[9:0]}];
							if (!(mask_chk && dst[15])) begin
								if (semi) pix = blend(dst, pix, tp_abr);
								ref_px[{y[8:0], x[9:0]}] = pix | {mask_set, 15'd0};
								n_ref = n_ref + 1;
							end
						end
					end
				end
		end
	endtask

	integer clocks, px_land, bad;
	reg trace = 0; integer tn = 0; reg [3:0] st_d; reg [1:0] fs_d;
	integer c_tex = 0, c_dst = 0, c_full = 0, c_clut = 0;
	always @(posedge clk) if (busy) clocks = clocks + 1;
	always @(posedge clk) if (v_req && v_we && v_ack) px_land = px_land + (v_be[0] ? 1 : 0) + (v_be[2] ? 1 : 0);

	task run; input [255:0] what;
		begin
			n_ref = 0; clocks = 0; px_land = 0;
			@(negedge clk); start = 1; @(negedge clk); start = 0;
			while (busy || bk_busy) @(negedge clk);
			repeat (4) @(negedge clk);
			ref_draw();
			bad = 0;
			for (y = 0; y < 512; y = y + 1) for (x = 0; x < 1024; x = x + 1)
				if (mem_px(x, y) !== ref_px[{y[8:0], x[9:0]}]) begin
					if (bad < 5) $display("      (%0d,%0d): got %04x want %04x", x, y, mem_px(x, y), ref_px[{y[8:0], x[9:0]}]);
					bad = bad + 1;
				end
			if (bad) begin $display("  FAIL %0s: %0d pixels differ", what, bad); errors = errors + 1; end
			else $display("  ok   %0s: %0d px, %0d clocks = %0.2f clk/px  (tex-miss %0d dst-miss %0d full %0d clut %0d)",
			              what, n_ref, clocks, n_ref ? clocks * 1.0 / n_ref : 0.0, c_tex, c_dst, c_full, c_clut);
			if (px_land != n_ref) begin $display("  FAIL %0s: pipeline landed %0d pixels, reference %0d", what, px_land, n_ref); errors = errors + 1; end
			c_tex = 0; c_dst = 0; c_full = 0; c_clut = 0;
		end
	endtask
	always @(posedge clk) begin
		if (st_tex) c_tex = c_tex + 1; if (st_dst) c_dst = c_dst + 1; if (st_full) c_full = c_full + 1; if (st_clut) c_clut = c_clut + 1;
	end

	// a triangle from vertices, as the engine sets it up (edgefn as in ps1_gpu.v)
	function signed [23:0] edgefn; input signed [11:0] ax, ay, bx, by, px, py;
		edgefn = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
	endfunction
	function signed [11:0] min3; input signed [11:0] a, b, c; min3 = (a < b) ? ((a < c) ? a : c) : ((b < c) ? b : c); endfunction
	function signed [11:0] max3; input signed [11:0] a, b, c; max3 = (a > b) ? ((a > c) ? a : c) : ((b > c) ? b : c); endfunction
	task setup_tri; input signed [11:0] x0, y0, x1, y1, x2, y2;
		reg signed [23:0] area;
		begin
			always_in = 0;
			area = edgefn(x0, y0, x1, y1, x2, y2); apos = area > 0;
			bx0 = min3(x0, x1, x2); bx1 = max3(x0, x1, x2); by0 = min3(y0, y1, y2); by1 = max3(y0, y1, y2);
			sx0 = y1 - y2; sx1 = y2 - y0; sx2 = y0 - y1;
			sy0 = x2 - x1; sy1 = x0 - x2; sy2 = x1 - x0;
			e0_0 = edgefn(x1, y1, x2, y2, bx0, by0);
			e1_0 = edgefn(x2, y2, x0, y0, bx0, by0);
			e2_0 = edgefn(x0, y0, x1, y1, bx0, by0);
		end
	endtask
	task rect; input signed [11:0] x0, y0; input [10:0] w; input [9:0] h; input [7:0] u0, v0;
		begin
			always_in = 1; apos = 1;
			bx0 = x0; bx1 = x0 + w - 1; by0 = y0; by1 = y0 + h - 1;
			e0_0 = 0; e1_0 = 0; e2_0 = 0; sx0 = 0; sx1 = 0; sx2 = 0; sy0 = 0; sy1 = 0; sy2 = 0;
			cu_0 = {8'd0, u0, 16'd0}; cv_0 = {8'd0, v0, 16'd0};
			du_dx = 32'h10000; dv_dx = 0; du_dy = 0; dv_dy = 32'h10000;
		end
	endtask
	task grads; input signed [31:0] r0, g0, b0, u0, v0, rdx, gdx, bdx, udx, vdx, rdy, gdy, bdy, udy, vdy;
		begin
			cr_0 = r0; cg_0 = g0; cb_0 = b0; cu_0 = u0; cv_0 = v0;
			dr_dx = rdx; dg_dx = gdx; db_dx = bdx; du_dx = udx; dv_dx = vdx;
			dr_dy = rdy; dg_dy = gdy; db_dy = bdy; du_dy = udy; dv_dy = vdy;
		end
	endtask

	integer i, j;
	initial begin
		for (i = 0; i < 65536; i = i + 1) mem[i] = {8{16'h0000}};
		for (i = 0; i < 1024*512; i = i + 1) ref_px[i] = 16'h0000;
		// a background with a mask bit here and there
		for (j = 0; j < 512; j = j + 1) for (i = 0; i < 1024; i = i + 1)
			set_px(i, j, {(i[4] & j[3]), i[7:3] ^ j[4:0], j[6:2], i[6:2]});
		// a 4-bit texture at page (8, 0) = x 512: 64 x 64 texels = 16 x 64 halfwords; a 15-bit one at page 12 = x 768
		for (j = 0; j < 64; j = j + 1) for (i = 0; i < 16; i = i + 1)
			set_px(512 + i, j, (i * 4 + j * 7 + 1) * 16'h1111 + {j[3:0], i[3:0], 8'd0});
		for (j = 0; j < 256; j = j + 1) for (i = 0; i < 256; i = i + 1)
			set_px(768 + i, j, {i[0] ^ j[0], j[7:3], i[7:3], (i[4:0] + j[4:0])});
		// 4-bit CLUT at (0, 500): entries 1..15 distinct, 0 anything; 8-bit CLUT at (64, 501)
		for (i = 0; i < 16; i = i + 1) set_px(i, 500, {i[0], 5'd31 - i, i[3:0] * 2, i * 2 + 1});
		for (i = 0; i < 256; i = i + 1) set_px(64 + i, 501, (i == 0) ? 16'h0000 : {i[7], i[4:0], i[7:3], 5'd9 + i[3:0]});
		// a second 8-bit CLUT at (128, 502), different colours: palette switching (the raster's second level)
		for (i = 0; i < 256; i = i + 1) set_px(128 + i, 502, (i == 0) ? 16'h0000 : {i[6], i[3:0], i[7], i[7:3], 5'd3 + i[4:0]});

		grads(32'h80_0000, 32'h40_0000, 32'h20_0000, 0, 0,  0,0,0,0,0,  0,0,0,0,0);
		fr = 8'd200; fg = 8'd100; fb = 8'd50;
		repeat (4) @(negedge clk); rst = 0; repeat (4) @(negedge clk);
		$display("--- flat ---");
		setup_tri(10, 10, 120, 30, 40, 90);            run("flat triangle");
		setup_tri(11, 100, 121, 100, 11, 200);         run("flat triangle, odd left edge");
		setup_tri(300, 10, 200, 300, 500, 250);        run("flat triangle, large");
		is_gour = 1;
		grads(32'h10_0000, 32'hF0_0000, 32'h80_0000, 0, 0,  32'h1_8000, -32'h1_2000, 32'h0_4000, 0, 0,  32'h0_9000, 32'h0_3000, -32'h0_7000, 0, 0);
		setup_tri(30, 300, 200, 320, 90, 400);         run("gouraud triangle");
		is_gour = 0;
		da_x0 = 40; da_x1 = 100; da_y0 = 20; da_y1 = 60;
		setup_tri(10, 10, 120, 30, 40, 90);            run("clipped to the drawing area");
		da_x0 = 0; da_x1 = 1023; da_y0 = 0; da_y1 = 511;
		$display("--- semi-transparent, mask ---");
		is_semi = 1;
		for (i = 0; i < 4; i = i + 1) begin tp_abr = i; setup_tri(10 + i * 3, 10, 120, 30, 40, 90); run("blend mode"); end
		is_semi = 0; mask_chk = 1;
		setup_tri(10, 10, 120, 30, 40, 90);            run("mask check");
		mask_set = 1; is_semi = 1; tp_abr = 1;
		setup_tri(10, 10, 120, 30, 40, 90);            run("mask set + blend");
		mask_set = 0; mask_chk = 0; is_semi = 0;
		$display("--- textured ---");
		is_tex = 1; tp_depth = 0; tp_x = 8; tp_y = 0; clut = {1'b0, 9'd500, 6'd0};
		grads(32'h80_0000, 32'h80_0000, 32'h80_0000, 32'h0_8000, 32'h0_8000,  0,0,0, 32'h0_C000, 32'h0_2000,  0,0,0, -32'h0_3000, 32'h1_1000);
		setup_tri(20, 20, 140, 40, 60, 120);           run("4-bit textured, modulated");
		is_raw = 1;
		setup_tri(20, 130, 140, 150, 60, 230);         run("4-bit textured, raw");
		is_raw = 0; is_gour = 1;
		grads(32'h10_0000, 32'hF0_0000, 32'h80_0000, 32'h0_8000, 32'h0_8000,  32'h1_8000, -32'h1_2000, 32'h0_4000, 32'h0_C000, 32'h0_2000,  32'h0_9000, 32'h0_3000, -32'h0_7000, -32'h0_3000, 32'h1_1000);
		setup_tri(200, 20, 320, 40, 240, 120);         run("4-bit textured, gouraud");
		is_gour = 0;
		tp_depth = 1; tp_x = 8; clut = {1'b0, 9'd501, 6'd4};
		grads(32'h80_0000, 32'h80_0000, 32'h80_0000, 32'h0_8000, 32'h0_8000,  0,0,0, 32'h0_A000, 32'h0_1000,  0,0,0, -32'h0_2000, 32'h0_F000);
		setup_tri(200, 130, 320, 150, 240, 230);       run("8-bit textured");
		// switching palettes: A, B, A again (from the second level), B again; then a write into A's
		// entries while B is in use, and A once more -- it must show what VRAM holds now
		clut = {1'b0, 9'd502, 6'd8};
		setup_tri(210, 135, 330, 155, 250, 235);       run("8-bit, a second palette");
		clut = {1'b0, 9'd501, 6'd4};
		setup_tri(205, 140, 325, 160, 245, 240);       run("8-bit, the first palette again (kept)");
		clut = {1'b0, 9'd502, 6'd8};
		setup_tri(215, 145, 335, 165, 255, 245);       run("8-bit, the second again (kept)");
		begin : over_a
			reg [1:0] sd; reg st, sr, sg, ss;
			sd = tp_depth; st = is_tex; ss = is_semi;
			is_tex = 0; is_semi = 0; fr = 8'd16; fg = 8'd200; fb = 8'd96;
			rect(64 + 32, 501, 40, 1, 0, 0);         run("a flat line drawn over the first palette");
			is_tex = st; tp_depth = sd; fr = 8'd200; fg = 8'd100; fb = 8'd50;
		end
		clut = {1'b0, 9'd501, 6'd4};
		setup_tri(200, 150, 320, 170, 240, 250);       run("8-bit, the first palette after the write");
		tp_depth = 2; tp_x = 12;
		grads(32'h80_0000, 32'h80_0000, 32'h80_0000, 32'h0_8000, 32'h0_8000,  0,0,0, 32'h0_A000, 32'h0_1000,  0,0,0, -32'h0_2000, 32'h0_F000);
		setup_tri(400, 20, 620, 40, 460, 220);         run("15-bit textured, large");
		is_semi = 1; tp_abr = 0;
		setup_tri(400, 230, 620, 250, 460, 430);       run("15-bit textured, semi-transparent");
		is_semi = 0;
		tw_mx = 5'b00011; tw_ox = 5'b00100; tw_my = 5'b00001; tw_oy = 5'b00010;
		setup_tri(400, 20, 620, 40, 460, 220);         run("15-bit textured, window");
		tw_mx = 0; tw_ox = 0; tw_my = 0; tw_oy = 0;
		$display("--- rectangles ---");
		tp_depth = 0; tp_x = 8; clut = {1'b0, 9'd500, 6'd0};
		rect(101, 301, 64, 40, 3, 5);            run("4-bit textured rectangle, odd corner");
		tp_depth = 2; tp_x = 12;
		rect(400, 300, 256, 100, 0, 0);          run("15-bit textured rectangle");
		is_tex = 0;
		rect(0, 0, 1024, 32, 0, 0);              run("flat rectangle, full width");
		is_semi = 1; tp_abr = 2;
		dfn = 0; dfc = 0; dfr = 0;
		rect(700, 400, 100, 60, 0, 0);           run("flat rectangle, blended");
		$display("    dest fetches %0d, %0d clocks in F (%0d each), memory reads %0d", dfn, dfc, dfc / (dfn ? dfn : 1), dfr);
		is_semi = 0;
		$display("--- 480i field rule ---");
		il_skip = 1; il_field = 1;
		setup_tri(10, 10, 120, 30, 40, 90);      run("odd field on screen: even rows only");
		il_field = 0;
		setup_tri(11, 100, 121, 100, 11, 200);   run("even field on screen: odd rows only");
		is_tex = 1; tp_depth = 2; tp_x = 12;
		rect(400, 300, 256, 100, 0, 0);          run("textured rectangle, odd rows only");
		is_tex = 0; il_skip = 0;
		$display("--- the console's pace ---");
		pace = 1;
		setup_tri(300, 10, 200, 300, 500, 250);  run("flat triangle at the chip's pace (free)");
		is_tex = 1; tp_depth = 2; tp_x = 12;
		rect(400, 300, 256, 100, 0, 0);          run("textured rectangle at the chip's pace (~1.9 clk/px)");
		is_tex = 0; pace = 0;
		$display("--- degenerate ---");
		rect(50, 50, 0, 5, 0, 0);                run("rectangle of no width");
		rect(50, 50, 5, 0, 0, 0);                run("rectangle of no height");
		rect(1020, 500, 10, 20, 0, 0);           run("rectangle off the edge");
		setup_tri(-20, -10, 30, -5, 5, 40);      run("triangle partly off the top-left");

		if (errors == 0) $display("tb_ps1_raster: all checks passed"); else $display("tb_ps1_raster: %0d FAIL(s)", errors);
		$finish;
	end
	always @(posedge clk) if (trace && tn < 60) begin
		if (1) begin
			$display("    px=%0d py=%0d scanning=%0d hold=%0d a_ok=%0d b_ok=%0d in_a=%0d row_ok=%0d xa_ok=%0d skip8=%0d row_end=%0d last=%0d ea=%0d,%0d,%0d apos=%0d vB=%0d busy=%0d", dut.px, dut.py, dut.scanning, dut.hold, dut.a_ok, dut.b_ok, dut.in_a, dut.row_ok, dut.xa_ok, dut.skip8, dut.row_end, dut.last, dut.ea0, dut.ea1, dut.ea2, dut.apos, dut.vB, busy);
			$display("    t=%0t fs=%0d vram.st=%0d v_req=%0d we=%0d ar=%0d addr=%h v_ack=%0d gp_req=%0d gp_ack=%0d r_hold=%0d tx_valid=%0d tx_addr=%h missC=%0d hit=%0d%0d ta=%h/%h a_go=%0d serving_b=%0d",
				$time, dut.fs, vram.st, v_req, v_we, v_around, v_addr, v_ack, gp_req, gp_ack, vp.r_hold, dut.tx_valid, dut.tx_addr, dut.missC, dut.hitC0, dut.hitC1, dut.taC0, dut.taC1, vram.a_go, vram.serving_b);
			tn = tn + 1;
		end
		st_d <= vram.st; fs_d <= dut.fs;
	end
	initial begin #60_000_000; $display("FAIL: timeout busy=%0d vB=%0d vC=%0d vD=%0d vE=%0d wreq=%0d fs=%0d cl_loading=%0d missC=%0d missE=%0d", busy, dut.vB, dut.vC, dut.vD, dut.vE, dut.wreq, dut.fs, dut.cl_loading, dut.missC, dut.missE); $display("  scanning=%0d px=%0d py=%0d box %0d..%0d x %0d..%0d hold=%0d last=%0d row_end=%0d", dut.scanning, dut.px, dut.py, dut.bx0, dut.bx1, dut.by0, dut.by1, dut.hold, dut.last, dut.row_end); $display("  v_req=%0d v_we=%0d v_around=%0d v_addr=%h r_hold=%0d gp_req=%0d gp_ack=%0d vram.st=%0d pf_busy=%0d acc_v=%0d q=%0d/%0d blk.ds=%0d taC0=%h hitC0=%0d taC1=%h hitC1=%0d needC0=%0d needC1=%0d tfill_d=%0d faddr=%h", v_req, v_we, v_around, v_addr, vp.r_hold, gp_req, gp_ack, vram.st, vram.pf_busy, vp.blk.acc_v, vp.blk.q_wp, vp.blk.q_rp, vp.blk.ds, dut.taC0, dut.hitC0, dut.taC1, dut.hitC1, dut.needC0, dut.needC1, dut.tfill_d, dut.faddr); $finish; end
endmodule
