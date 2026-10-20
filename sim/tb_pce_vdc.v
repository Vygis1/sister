`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_pce_vdc - the PC Engine's video controller on its own: sprites and a background drawn
// where they should be.
//
// The bench plays the VCE's part (341 dots a line, 262 lines) and the processor's, writing
// the registers and VRAM through the port. Then it looks at every pixel of a frame:
//   - a 16x16 sprite of one colour at (20, 10), priority over the background;
//   - a 32x32 one (CGX, CGY) at (100, 50) whose four cells are four colours, flipped both ways;
//   - a background of one tile (colour 3) under everything, scrolled by (5, 3) -- the tile's
//     pixels alternate so the scroll shows; where the first sprite is, it wins; a third sprite
//     with priority 0 at (200, 100) shows only where the background pixel is 0.
// Every pixel of the window is compared with what those rules give.
//
//   ./tools/sim.sh tb_pce_vdc
//////////////////////////////////////////////////////////////////////////////////
module tb_pce_vdc;
	reg clk = 0;
	always #10 clk = ~clk;
	reg rst = 1;

	// --- the port -----------------------------------------------------------------------------------
	reg        sel = 0; reg [1:0] a = 0; reg we = 0, rd = 0; reg [7:0] d = 0;
	wire [7:0] q; wire irq;
	// --- the clocks, as the VCE makes them at the 5.37 MHz rate: a dot every 9 clocks here ----------
	reg        dot_ce = 0, line_start = 0, frame_start = 0;
	reg [9:0]  dot = 0; reg [8:0] line = 0;
	reg [3:0]  dc = 0;
	always @(posedge clk) begin
		dot_ce <= 0; line_start <= 0; frame_start <= 0;
		if (!rst) begin
			if (dc == 4'd8) begin
				dc <= 0; dot_ce <= 1;
				if (dot == 10'd340) begin
					dot <= 0; line_start <= 1;
					if (line == 9'd261) begin line <= 0; frame_start <= 1; end else line <= line + 9'd1;
				end else dot <= dot + 10'd1;
			end else dc <= dc + 4'd1;
		end
	end
	wire [8:0] px_idx; wire px_en; wire [9:0] px_x; wire [8:0] px_y; wire [9:0] disp_w; wire [8:0] disp_h; wire disp_start;

	pce_vdc dut (
		.clk(clk), .rst(rst), .sel(sel), .a(a), .we(we), .rd(rd), .d(d), .q(q), .irq(irq),
		.dot_ce(dot_ce), .line_start(line_start), .frame_start(frame_start), .dot(dot), .line(line),
		.px_idx(px_idx), .px_en(px_en), .px_x(px_x), .px_y(px_y), .disp_w(disp_w), .disp_h(disp_h), .disp_start(disp_start)
	);

	// --- writing the chip ----------------------------------------------------------------------------
	task wr; input [1:0] aa; input [7:0] dd; begin
		@(negedge clk); sel = 1; a = aa; d = dd; we = 1; @(negedge clk); we = 0; sel = 0;
	end endtask
	task reg16; input [4:0] r; input [15:0] v; begin wr(0, {3'd0, r}); wr(2, v[7:0]); wr(3, v[15:8]); end endtask
	task vram; input [15:0] addr; input [15:0] v; begin reg16(5'h00, addr); wr(0, 8'h02); wr(2, v[7:0]); wr(3, v[15:8]); end endtask
	// a 16x16 sprite cell of one colour at word address base: 4 planes x 16 rows
	task spcell; input [14:0] base; input [3:0] colour; integer r; begin
		for (r = 0; r < 16; r = r + 1) begin
			vram(base + r,      colour[0] ? 16'hFFFF : 16'h0000);
			vram(base + 16 + r, colour[1] ? 16'hFFFF : 16'h0000);
			vram(base + 32 + r, colour[2] ? 16'hFFFF : 16'h0000);
			vram(base + 48 + r, colour[3] ? 16'hFFFF : 16'h0000);
		end
	end endtask
	// a sprite table entry at VRAM $7000 + n * 4
	task sprite; input [5:0] n; input [15:0] y, x, pat, att; begin
		vram(16'h7000 + n * 4, y); vram(16'h7001 + n * 4, x); vram(16'h7002 + n * 4, pat); vram(16'h7003 + n * 4, att);
	end endtask

	// --- what each pixel should be --------------------------------------------------------------------
	function [8:0] expect; input [9:0] x; input [8:0] y; reg [8:0] bg; reg [8:0] sp; reg sp_prio; begin
		// the background: tile 1 everywhere, pixels alternating 3 and 0 by (x + y) odd, scrolled (5, 3)
		bg = (((x + 10'd5) + {1'b0, y} + 9'd3) & 1) ? 9'd3 : 9'd0;
		sp = 9'd0; sp_prio = 1'b0;
		// sprite 2 (lowest priority of the three drawn): 16x16 colour 7 at (200, 100), behind the background
		if (x >= 200 && x < 216 && y >= 100 && y < 116) begin sp = 9'h107; sp_prio = 1'b0; end
		// sprite 1: 32x32 at (100, 50), cells 1 2 / 3 4 before the flips, flipped both ways -> 4 3 / 2 1, palette 2
		if (x >= 100 && x < 132 && y >= 50 && y < 82) begin
			sp = 9'h120 | ((x < 116) ? ((y < 66) ? 9'd4 : 9'd2) : ((y < 66) ? 9'd3 : 9'd1)); sp_prio = 1'b1;
		end
		// sprite 0: 16x16 colour 5 at (20, 10), on top
		if (x >= 20 && x < 36 && y >= 10 && y < 26) begin sp = 9'h105; sp_prio = 1'b1; end
		if (sp != 9'd0 && (sp_prio || bg == 9'd0)) expect = sp; else expect = bg;
	end endfunction

	integer errs = 0, seen = 0, frames = 0, i;
	always @(posedge clk) begin
		if (disp_start) frames <= frames + 1;
		if (px_en && frames >= 3) begin
			seen <= seen + 1;
			if (px_idx !== expect(px_x, px_y)) begin
				if (errs < 12) $display("  FAIL pixel (%0d,%0d): got %03x want %03x", px_x, px_y, px_idx, expect(px_x, px_y));
				errs <= errs + 1;
			end
		end
	end

	initial begin
		$display("tb_pce_vdc");
		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);
		// the window: the chip's reset values (256 x 240); control: nothing on yet
		reg16(5'h05, 16'h0000);
		reg16(5'h09, 16'h0000);                       // 32 x 32 map
		// tile $100 at word $1000: planes 0 and 1 set on alternating pixels -> colour 3 where (x + y) odd
		for (i = 0; i < 8; i = i + 1) begin
			vram(16'h1000 + i, (i & 1) ? 16'hAAAA : 16'h5555);   // planes 0, 1 (low, high byte): same pattern
			vram(16'h1008 + i, 16'h0000);
		end
		for (i = 0; i < 1024; i = i + 1) vram(i, 16'h0100);       // the map: tile $100, palette 0
		reg16(5'h07, 16'd5); reg16(5'h08, 16'd3);                // BXR, BYR
		// sprite cells: index $100 (word $4000) colour 5; $104.. a 32x32 of cells 1 2 3 4; $110 colour 7
		spcell(15'h4000, 4'd5);
		spcell(15'h4100, 4'd1); spcell(15'h4140, 4'd2); spcell(15'h4180, 4'd3); spcell(15'h41C0, 4'd4);
		spcell(15'h4400, 4'd7);
		sprite(0, 16'd64 + 16'd10, 16'd32 + 16'd20, 16'h0100 << 1, 16'h0080);
		sprite(1, 16'd64 + 16'd50, 16'd32 + 16'd100, 16'h0104 << 1, 16'h9982);   // VFLIP, CGY 1, HFLIP, CGX, prio, palette 2
		sprite(2, 16'd64 + 16'd100, 16'd32 + 16'd200, 16'h0110 << 1, 16'h0000);
		reg16(5'h13, 16'h7000);                       // the table, from the next blank on
		reg16(5'h05, 16'h00C0);                       // sprites and background on
		while (frames < 5) @(posedge clk);
		$display("  %0d pixels looked at, %0d wrong", seen, errs);
		if (errs == 0 && seen > 100000) $display("tb_pce_vdc: all checks passed");
		else $display("tb_pce_vdc: 1 FAIL(s)");
		$finish;
	end
endmodule
