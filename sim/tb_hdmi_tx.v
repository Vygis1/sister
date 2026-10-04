//////////////////////////////////////////////////////////////////////////////////
// tb_hdmi_tx - hdmi_tx.v's symbols, decoded back: every active pixel must be the
// pattern for its x and y (the source answers a clock after req, as a block RAM
// does), 640 pixels on each of 480 lines, HSYNC 96 clocks and VSYNC 2 lines low
// (from channel 0's control tokens), and each channel's running disparity -- ones
// less zeros sent -- must stay small (DC balance).
//
//   ./tools/sim.sh tb_hdmi_tx
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_hdmi_tx;
	reg clk = 0, rst = 1;
	always #20 clk = ~clk;                     // pixel clock (any period: SIM takes it as it is)
	wire pclk;
	wire [9:0] x, y; wire req;
	reg  [23:0] rgb;
	wire [9:0] s0, s1, s2;
	wire fs;
	hdmi_tx #(.SIM(1)) dut (.clk50(1'b0), .rst(rst), .sim_pclk(clk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0), .pclk(pclk), .x(x), .y(y), .req(req),
		.rgb(rgb), .frame_start(fs), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(), .sym_0(s0), .sym_1(s1), .sym_2(s2), .aud_l(au), .aud_r(~au), .aud_tog(atog));

	reg [15:0] au = 16'h1000; reg atog = 0; integer acnt = 0;
	always @(posedge clk) begin
		acnt = acnt + 1;
		if (acnt == 521) begin acnt = 0; au <= au + 16'd1; atog <= ~atog; end
	end
	integer df; initial df = $fopen("../../sim/hdmi_syms.txt", "w");
	function [4:0] ter;                      // {valid, the 4 bits} of a TERC4 symbol
		input [9:0] q;
		case (q)
		10'b1010011100: ter = 5'h10; 10'b1001100011: ter = 5'h11; 10'b1011100100: ter = 5'h12; 10'b1011100010: ter = 5'h13;
		10'b0101110001: ter = 5'h14; 10'b0100011110: ter = 5'h15; 10'b0110001110: ter = 5'h16; 10'b0100111100: ter = 5'h17;
		10'b1011001100: ter = 5'h18; 10'b0100111001: ter = 5'h19; 10'b0110011100: ter = 5'h1A; 10'b1011000110: ter = 5'h1B;
		10'b1010001110: ter = 5'h1C; 10'b1001110001: ter = 5'h1D; 10'b0101100011: ter = 5'h1E; 10'b1011000011: ter = 5'h1F;
		default: ter = 5'h00;
		endcase
	endfunction
	function [23:0] pat; input [9:0] px, py; pat = {px[7:0] ^ py[7:0], px[9:2] + py[9:2], px[7:0] * 8'd3 + py[7:0]}; endfunction
	// the source: a clock behind req, as a line buffer
	always @(posedge pclk) rgb <= req ? pat(x, y) : $random;
	// what was asked, to check against: req's x/y a clock ago, and two clocks ago (the
	// symbol for a pixel comes out of the encoder's register a clock after rgb)
	reg [9:0] x1, y1, x2, y2; reg r1, r2;
	always @(posedge pclk) begin x1 <= x; y1 <= y; r1 <= req; x2 <= x1; y2 <= y1; r2 <= r1; end

	function [8:0] dec; input [9:0] q; reg [7:0] d; integer i; begin
		d = q[9] ? ~q[7:0] : q[7:0];
		dec[0] = d[0];
		for (i = 1; i < 8; i = i + 1) dec[i] = q[8] ? (d[i] ^ d[i - 1]) : ~(d[i] ^ d[i - 1]);
		dec[8] = 1'b1;
	end endfunction
	function [2:0] ctl; input [9:0] q; begin                 // {valid, c1, c0}
		case (q)
		10'b1101010100: ctl = 3'b100;
		10'b0010101011: ctl = 3'b101;
		10'b0101010100: ctl = 3'b110;
		10'b1010101011: ctl = 3'b111;
		default:        ctl = 3'b000;
		endcase
	end endfunction
	function integer bal; input [9:0] q; integer i; begin
		bal = 0; for (i = 0; i < 10; i = i + 1) bal = bal + (q[i] ? 1 : -1);
	end endfunction

	integer errors = 0, px = 0, lines = 0, frames = 0, hs_len = 0, hs_run = 0, vs_lines = 0;
	integer d0 = 0, d1 = 0, d2 = 0, dmax = 0;
	reg vs_prev = 1, hs_prev = 1, act_line = 0;
	always @(posedge pclk) if (!rst) begin
		if (!r2) begin : blank
			// blanking: control tokens, a data island (TERC4) or a guard band; the syncs
			// from channel 0 (a control token, or a TERC4 symbol's bits 0 and 1; a video
			// guard band carries none)
			reg [1:0] vh; reg vgbd;
			vgbd = s0 == 10'b1011001100 && s1 == 10'b0100110011 && s2 == 10'b1011001100;
			if (ctl(s0) != 3'b000) vh = ctl(s0)[1:0];
			else if (!vgbd && ter(s0)[4]) vh = ter(s0)[1:0];
			else vh = {vs_prev, hs_prev};
			if (ctl(s0) == 3'b000 && !vgbd && !ter(s0)[4]) begin errors = errors + 1; if (errors < 8) $display("tb_hdmi_tx: blanking symbol %03x on channel 0", s0); end
			$fwrite(df, "%03x %03x %03x\n", s0, s1, s2);
			d0 = 0; d1 = 0; d2 = 0;
			
			if (!vh[0]) hs_run = hs_run + 1;
			else if (hs_run) begin
				if (hs_run != 96) begin errors = errors + 1; if (errors < 8) $display("tb_hdmi_tx: HSYNC %0d clocks", hs_run); end
				hs_run = 0;
			end
			if (!vh[1] && vs_prev) vs_lines = 0;
			if (!vh[1] && hs_run == 1) vs_lines = vs_lines + 1;
			if (vh[1] && !vs_prev) begin
				if (vs_lines != 2) begin errors = errors + 1; if (errors < 8) $display("tb_hdmi_tx: VSYNC %0d lines", vs_lines); end
				frames = frames + 1;
				if (lines != 480) begin errors = errors + 1; if (errors < 8) $display("tb_hdmi_tx: %0d lines in a frame", lines); end
				lines = 0;
			end
			vs_prev = vh[1]; hs_prev = vh[0];
			if (act_line) begin
				if (px != 640) begin errors = errors + 1; if (errors < 8) $display("tb_hdmi_tx: %0d pixels on a line", px); end
				lines = lines + 1; px = 0; act_line = 0;
			end
		end else begin
			if (!r2) begin errors = errors + 1; if (errors < 8) $display("tb_hdmi_tx: data symbol in blanking"); end
			else if ({dec(s2)[7:0], dec(s1)[7:0], dec(s0)[7:0]} !== pat(x2, y2)) begin
				errors = errors + 1;
				if (errors < 8) $display("tb_hdmi_tx: pixel (%0d,%0d) decoded %06x, sent %06x", x2, y2, {dec(s2)[7:0], dec(s1)[7:0], dec(s0)[7:0]}, pat(x2, y2));
			end
			d0 = d0 + bal(s0); d1 = d1 + bal(s1); d2 = d2 + bal(s2);
			if (d0 > dmax) dmax = d0; if (-d0 > dmax) dmax = -d0;
			if (d1 > dmax) dmax = d1; if (-d1 > dmax) dmax = -d1;
			if (d2 > dmax) dmax = d2; if (-d2 > dmax) dmax = -d2;
			px = px + 1; act_line = 1;
		end
	end
	initial begin
		repeat (12) @(posedge clk); @(posedge fs); rst = 0;   // (from a frame's start, the pipelines settled)
		repeat (800 * 525 * 2 + 3000) @(posedge clk);
		if (dmax > 20) begin errors = errors + 1; $display("tb_hdmi_tx: running disparity reached %0d", dmax); end
		$display("tb_hdmi_tx: %0d frames, largest running disparity %0d, %0d errors", frames, dmax, errors);
		if (errors == 0 && frames >= 2) $display("tb_hdmi_tx: all checks passed");
		else $display("tb_hdmi_tx: FAIL");
		$finish;
	end
endmodule

`default_nettype wire
