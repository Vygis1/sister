// tb_snes_ppu.v - rtl/wip/snes_ppu.v replaying what the model's PPU was told, comparing every
// line it draws with the model's (tools/snes/ppurec.py writes build/ppu.vec).
//
//   python tools/snes/ppurec.py ROM.sfc && ./tools/simwip.sh tb_snes_ppu
`timescale 1ns/1ps
`default_nettype none
module tb_snes_ppu;
	reg clk = 0, rst = 1;
	always #5 clk = ~clk;
	reg b_wr = 0, b_rd = 0; reg [7:0] b_addr = 0, b_wdata = 0;
	reg go = 0; reg [8:0] line = 0; reg field = 0;
	wire done;
	reg [8:0] rd_x = 0; wire [14:0] rd_px;
	snes_ppu dut (.clk(clk), .rst(rst), .b_wr(b_wr), .b_rd(b_rd), .b_addr(b_addr), .b_wdata(b_wdata), .b_rdata(),
	              .h(11'd0), .v(9'd0), .go(go), .line(line), .field(field), .done(done),
	              .rd_buf(line[0]), .rd_x(rd_x), .rd_px(rd_px), .overscan(), .interlace(), .force_blank());

	integer fd, r, k, nlines, badlines, badpx, shown, cyc, maxcyc;
	reg [8*8-1:0] tag;
	reg [31:0] a, d;
	reg [14:0] want [0:511];
	integer firstbad;
	reg fsave;
	initial begin
		fd = $fopen("../../build/ppu.vec", "r");
		if (fd == 0) begin $display("tb_snes_ppu: FAIL no build/ppu.vec"); $finish; end
		repeat (4) @(posedge clk); rst = 0; @(posedge clk);
		nlines = 0; badlines = 0; badpx = 0; shown = 0; maxcyc = 0;
		while (!$feof(fd)) begin
			r = $fscanf(fd, "%s", tag);
			if (r != 1) begin end
			else if (tag == "W") begin
				r = $fscanf(fd, "%h %h", a, d);
				@(negedge clk); b_addr = a; b_wdata = d; b_wr = 1; @(negedge clk); b_wr = 0;
			end else if (tag == "R") begin
				r = $fscanf(fd, "%h", a);
				@(negedge clk); b_addr = a; b_rd = 1; @(negedge clk); b_rd = 0;
			end else if (tag == "L") begin
				r = $fscanf(fd, "%h %h", a, d);
				fsave = d[0];                       // (d is reused for the pixels below)
				r = $fscanf(fd, "%s", tag);         // E
				for (k = 0; k < 512; k = k + 1) begin r = $fscanf(fd, "%h", d); want[k] = d; end
				@(negedge clk); line = a; field = fsave; go = 1; @(negedge clk); go = 0;
				cyc = 0;
				while (!done && cyc < 20000) begin @(posedge clk); cyc = cyc + 1; end
				if (cyc > maxcyc) maxcyc = cyc;
				if (cyc >= 20000) begin $display("tb_snes_ppu: FAIL line %0d never finished (rs %0d ly %0d bx %0d by %0d ymos %0d %0d)", line, dut.rs, dut.ly, dut.bx, dut.by, dut.ymos_cnt, dut.ymos_r); $finish; end
				firstbad = -1;
				for (k = 0; k < 512; k = k + 1) begin
					@(negedge clk); rd_x = k; @(posedge clk); @(negedge clk);
					if (rd_px !== want[k]) begin badpx = badpx + 1; if (firstbad < 0) firstbad = k; end
				end
				nlines = nlines + 1;
				if (firstbad >= 0) begin
					badlines = badlines + 1;
					if (shown < 12) begin
						rd_x = firstbad; @(posedge clk); @(negedge clk);
						$display("  line %0d: from x %0d: ours %04x, want %04x", line, firstbad, rd_px, want[firstbad]);
						if (shown < 2) for (k = firstbad; k < firstbad + 24 && k < 512; k = k + 1) begin
							rd_x = k; @(posedge clk); @(negedge clk);
							$display("     x %0d ours %04x want %04x", k, rd_px, want[k]);
						end
						shown = shown + 1;
					end
				end
			end
		end
		$display("tb_snes_ppu: %0d lines drawn, %0d differ (%0d pixels); the longest took %0d clocks", nlines, badlines, badpx, maxcyc);
		if (badlines == 0 && nlines > 0) $display("tb_snes_ppu: all checks passed"); else $display("tb_snes_ppu: FAIL");
		$finish;
	end
endmodule
