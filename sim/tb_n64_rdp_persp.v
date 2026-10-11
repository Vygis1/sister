`timescale 1ns/1ps
// tb_n64_rdp_persp - n64_rdp_persp against tools/n64/n64rdp.py perspective_divide: vectors
// {s, t, w, so, to, overflow} from tools/n64/mkpersp.py (sim/n64d/persp.hex), its answer a clock after the input is registered
module tb_n64_rdp_persp;
	reg clk = 0; always #5 clk = ~clk;
	reg  signed [15:0] s, t, w;
	wire signed [16:0] so, to; wire ov;
	n64_rdp_persp dut (.clk(clk), .ce(1'b1), .s(s), .t(t), .w(w), .so(so), .to(to), .overflow(ov));
	reg [99:0] v [0:65535];
	integer n, i, bad;
	reg [99:0] e0, e1, e2;
	initial begin
		$readmemh("../../sim/n64d/persp.hex", v);
		n = v[0][31:0]; bad = 0;
		for (i = 1; i <= n + 1; i = i + 1) begin
			if (i <= n) begin s = v[i][98:83]; t = v[i][82:67]; w = v[i][66:51]; end
			@(posedge clk); #1;
			if (i >= 2) begin
				e2 = v[i - 1];
				if (so !== $signed(e2[50:34]) || to !== $signed(e2[33:17]) || ov !== e2[16]) begin
					bad = bad + 1;
					if (bad <= 12) $display("  s %6d t %6d w %6d: RTL %7d %7d %b, model %7d %7d %b",
						$signed(e2[98:83]), $signed(e2[82:67]), $signed(e2[66:51]), so, to, ov,
						$signed(e2[50:34]), $signed(e2[33:17]), e2[16]);
				end
			end
		end
		$display("tb_n64_rdp_persp: %0d of %0d differ", bad, n);
		$finish;
	end
endmodule
