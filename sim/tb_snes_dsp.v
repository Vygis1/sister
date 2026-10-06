// tb_snes_dsp.v - rtl/wip/snes_dsp.v replaying what the model's S-DSP was told, comparing every
// sample (left, right) and ENDX / ENVX / OUTX with the model's (tools/snes/dsprec.py writes
// build/dsp.vec).
//
//   python tools/snes/dsprec.py ROM.sfc && ./tools/simwip.sh tb_snes_dsp
`timescale 1ns/1ps
`default_nettype none
module tb_snes_dsp;
	reg clk = 0, rst = 1;
	always #5 clk = ~clk;
	reg r_we = 0; reg [6:0] r_addr = 0; reg [7:0] r_wdata = 0;
	wire [7:0] r_rdata;
	reg sample = 0;
	wire [15:0] ram_a; reg [7:0] ram_q; wire ram_we; wire [7:0] ram_wd;
	wire signed [15:0] out_l, out_r; wire out_stb;
	snes_dsp dut (.clk(clk), .rst(rst), .sample(sample), .r_we(r_we), .r_addr(r_addr), .r_wdata(r_wdata), .r_rdata(r_rdata),
	              .ram_a(ram_a), .ram_q(ram_q), .ram_we(ram_we), .ram_wd(ram_wd), .out_l(out_l), .out_r(out_r), .out_stb(out_stb));
	reg [7:0] ram [0:65535];
	always @(posedge clk) begin
		ram_q <= ram[ram_a];
		if (ram_we) ram[ram_a] <= ram_wd;
	end

	integer fd, r, k, ns, bad, shown, cyc, maxcyc;
	reg [8*8-1:0] tag;
	reg [31:0] a, d, wl, wr_, wx;
	reg [7:0] wenv [0:7], wout [0:7];
	reg mism;

	initial begin
		for (k = 0; k < 65536; k = k + 1) ram[k] = 8'h00;
		fd = $fopen("../../build/dsp.vec", "r");
		if (fd == 0) begin $display("tb_snes_dsp: FAIL no build/dsp.vec"); $finish; end
		repeat (4) @(posedge clk); rst = 0; @(posedge clk);
		ns = 0; bad = 0; shown = 0; maxcyc = 0;
		while (!$feof(fd)) begin
			r = $fscanf(fd, "%s", tag);
			if (r != 1) begin end
			else if (tag == "M") begin r = $fscanf(fd, "%h %h", a, d); ram[a[15:0]] = d[7:0]; end
			else if (tag == "W") begin
				r = $fscanf(fd, "%h %h", a, d);
				@(negedge clk); r_addr = a[6:0]; r_wdata = d[7:0]; r_we = 1; @(negedge clk); r_we = 0;
			end else if (tag == "S") begin
				r = $fscanf(fd, "%s", tag);        // E
				r = $fscanf(fd, "%h %h %h", wl, wr_, wx);
				for (k = 0; k < 8; k = k + 1) begin r = $fscanf(fd, "%h", d); wenv[k] = d; end
				for (k = 0; k < 8; k = k + 1) begin r = $fscanf(fd, "%h", d); wout[k] = d; end
				@(negedge clk); sample = 1; @(negedge clk); sample = 0;
				cyc = 0;
				while (!out_stb && cyc < 5000) begin @(posedge clk); cyc = cyc + 1; end
				if (cyc >= 5000) begin $display("tb_snes_dsp: FAIL sample %0d never came", ns); $finish; end
				// (the echo's write-back, until the work is done: the sample's whole time, which must
				// fit the 1562 clocks a 32 kHz sample has at 50 MHz)
				while (dut.ws != 5'd0 && cyc < 5000) begin @(posedge clk); cyc = cyc + 1; end
				if (cyc > maxcyc) maxcyc = cyc;
				repeat (2) @(posedge clk);
				mism = (out_l !== wl[15:0]) || (out_r !== wr_[15:0]) || (dut.R[7'h7C] !== wx[7:0]);
				for (k = 0; k < 8; k = k + 1) if (dut.R[{k[2:0], 4'h8}] !== wenv[k] || dut.R[{k[2:0], 4'h9}] !== wout[k]) mism = 1;
				if (mism) begin
					bad = bad + 1;
					if (shown < 10) begin
						$display("  sample %0d: ours %04x %04x endx %02x env0 %02x out0 %02x | want %04x %04x endx %02x env0 %02x out0 %02x",
						         ns, out_l, out_r, dut.R[7'h7C], dut.R[7'h08], dut.R[7'h09], wl[15:0], wr_[15:0], wx[7:0], wenv[0], wout[0]);
						$display("     main_l %0d fl %0d mvol %02x evol %02x echo_l %0d flg %02x", dut.main_l, dut.fl, dut.R[7'h0C], dut.R[7'h2C], dut.echo_l, dut.R[7'h6C]);
						shown = shown + 1;
					end
				end
				ns = ns + 1;
			end
		end
		$display("tb_snes_dsp: %0d samples, %0d differ; the longest took %0d clocks (of 1562 at 50 MHz)", ns, bad, maxcyc);
		if (bad == 0 && ns > 0 && maxcyc < 1500) $display("tb_snes_dsp: all checks passed"); else $display("tb_snes_dsp: FAIL");
		$finish;
	end
endmodule
