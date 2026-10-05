//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_hdmi - the PlayStation's HDMI picture: frames go through fb_ddr into a
// DDR3 model (requests taken when ready, read data a few clocks later), fb_ddr
// fetches the lines n64_vid (PS1=1) wants, and every pixel of the 640 x 480 picture
// hdmi_tx asks for must be its source pixel, doubled, in 24-bit colour. The scanout
// is modelled as the GPU's pixel stream (fpx: a 320 x 240 RGB555 frame, again and
// again), so the capture and the line reads share the memory port as on the board.
//
//   ./tools/sim.sh tb_ps1_hdmi
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_ps1_hdmi #(parameter W = 256);
	reg clk = 0, pclk = 0, rst = 1;
	always #10 clk = ~clk;                     // 50 MHz
	always #20 pclk = ~pclk;                   // 25 MHz
	wire [9:0] x, y; wire req; wire [23:0] rgb;
	hdmi_tx #(.SIM(1)) u_tx (.clk50(1'b0), .rst(1'b0), .sim_pclk(pclk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0),
		.pclk(), .x(x), .y(y), .req(req), .rgb(rgb), .frame_start(), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(16'd0), .aud_r(16'd0), .aud_tog(1'b0));

	function [15:0] src; input [8:0] py; input [9:0] px; src = {1'b0, px[4:0] ^ py[4:0], px[8:4] + py[3:0], py[7:3] ^ px[2:0]}; endfunction
	function [23:0] to888; input [15:0] p; to888 = {p[4:0], p[4:2], p[9:5], p[9:7], p[14:10], p[14:12]}; endfunction

	// --- the scanout: a frame of pixels, one every other clock, then a gap -------------
	reg fstart = 0, pv = 0; reg [9:0] fx = 0; reg [8:0] fy = 0; reg [15:0] prgb = 0;
	reg [9:0] px_x = 0; reg [8:0] px_y = 0;
	// each captured frame its own: the frame number in the top bits of every pixel
	reg [4:0] fk = 0;
	function [15:0] srck; input [8:0] py; input [9:0] px; input [4:0] k; srck = src(py, px) ^ {1'b0, k, 10'd0}; endfunction
	wire hold, want;
	integer gap = 0;
	always @(posedge clk) if (!rst) begin
		fstart <= 1'b0; pv <= 1'b0;
		if (gap > 0) begin gap = gap - 1; if (gap == 0) begin fstart <= 1'b1; fx <= 0; fy <= 0; end end
		else if (!hold && !pv) begin
			pv <= 1'b1; prgb <= srck(fy, fx, fk); px_x <= fx; px_y <= fy;
			if (fx == W - 1) begin fx <= 0; if (fy == 9'd239) begin gap = 20000; fk <= fk + 5'd1; end else fy <= fy + 9'd1; end
			else fx <= fx + 10'd1;
		end
	end

	// --- DDR3: 512 kB of 128-bit lines from 4 MB, ready 3 clocks in 4, data 6 later ------
	reg [127:0] mem [0:32767];
	wire [23:0] m_addr; wire m_req, m_we; wire [127:0] m_wdata;
	reg [3:0] rr = 0; wire m_ready = rr != 4'd3;
	always @(posedge clk) rr <= rr + 4'd1;
	reg [127:0] rq [0:7]; reg [7:0] rv = 0;
	reg [127:0] m_rdata; reg m_valid = 0;
	integer i;
	always @(posedge clk) begin
		m_valid <= rv[7]; m_rdata <= rq[7];
		for (i = 7; i > 0; i = i - 1) begin rq[i] <= rq[i - 1]; rv[i] <= rv[i - 1]; end
		rv[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) mem[m_addr[14:0]] <= m_wdata;
			else begin rq[0] <= mem[m_addr[14:0]]; rv[0] <= 1'b1; end
		end
	end

	wire lf_we; wire [7:0] lf_addr; wire [127:0] lf_data; wire [8:0] lf_want;
	fb_ddr u_fb (.clk(clk), .rst(rst),
		.frame_start(fstart), .px_valid(pv), .px_x(px_x), .px_y(px_y), .px_rgb(prgb),
		.fl_valid(1'b0), .fl_data(128'd0), .fl_x(10'd0), .fl_y(9'd0),
		.hold(hold), .want(want), .cap_go(1'b0), .cap_ready(),
		.hdmi_on(1'b1), .lf_want(lf_want), .lf_words(W / 8), .lf_we(lf_we), .lf_addr(lf_addr), .lf_data(lf_data),
		.hr_addr(18'd0), .hr_req(1'b0), .hr_rdata(), .hr_ack(),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid));
	n64_vid #(.PS1(1)) u_vid (.clk(clk), .wr_en(lf_we), .wr_addr(lf_addr), .wr_data(lf_data), .want(lf_want),
		.width(W), .bpp32(1'b0), .on(1'b1), .pclk(pclk), .x(x), .y(y), .req(req), .rgb(rgb));

	initial begin repeat (8) @(posedge clk); rst = 0; gap = 10; end

	// check from the third frame (the first capture has to be in memory)
	reg [9:0] x1, y1; reg r1;
	always @(posedge pclk) begin x1 <= x; y1 <= y; r1 <= req; end
	integer errors = 0, checked = 0, frames = 0; reg [23:0] wantc; integer shown_k = 0, last_k = -1, ks_seen = 0, changes = 0;
	always @(posedge pclk) if (x == 10'd0 && y == 10'd0 && req) frames = frames + 1;
	always @(posedge pclk) if (r1 && frames >= 3) begin
		checked = checked + 1;
		// (centred: the doubled picture starts at 320 - W, black either side; every pixel
		// of an HDMI frame from the one capture its first pixel came from)
		if (x1 == 320 - W && y1 == 0) begin : which
			// (pixel 0,0 is the frame number in blue: src(0, 0) is 0. Not a loop over
			// to888(srck(..k)): nested calls in a loop simulate wrong in xsim.)
			shown_k = rgb[7:3];
			ks_seen = ks_seen + 1; if (shown_k != last_k) changes = changes + 1; last_k = shown_k;
			if (ks_seen < 6) $display("tb_ps1_hdmi: frame %0d: first pixel %06x -> capture %0d; disp_b %0d pend %0d", frames, rgb, shown_k, u_fb.disp_b, u_fb.pend);
		end
		wantc = (x1 >= 320 - W && x1 < 320 + W) ? to888(srck(y1[9:1], (x1 - (320 - W)) >> 1, shown_k)) : 24'd0;
		if (rgb !== wantc) begin
			errors = errors + 1;
			if (errors < 8) $display("tb_ps1_hdmi: (%0d,%0d) got %06x want %06x", x1, y1, rgb, wantc);
		end
	end
	initial begin
		#(800 * 525 * 40 * 6);
		$display("tb_ps1_hdmi: %0d pixels checked, %0d wrong; %0d frames shown, the picture changed %0d times", checked, errors, ks_seen, changes);
		if (errors == 0 && checked >= 307200 && changes >= 2) $display("tb_ps1_hdmi: all checks passed"); else $display("tb_ps1_hdmi: FAIL");
		$finish;
	end
endmodule

`default_nettype wire
