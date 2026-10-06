`timescale 1ns/1ps
`default_nettype none
module tb_aip;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	reg  [15:0] dac_l = 0, dac_r = 0;
	reg  dac_new = 0, out_go = 0;
	reg  [31:0] audio_lr; reg audio_lr_we;
	reg  [15:0]  ip_l0, ip_r0, ip_l1, ip_r1;   // the last two samples, older first
	reg  [12:0]  ip_t, ip_per;             // clocks since dac_l came; between the last two
	reg          ip_run;
	reg  [4:0]   ip_k;
	reg  [13:0]  ip_rem;
	reg  [16:0]  ip_q;
	reg  [12:0]  ip_d;
	reg  [15:0]  ip_cl, ip_cr, ip_pl, ip_pr;
	wire signed [16:0] ip_dl = $signed({ip_cl[15], ip_cl}) - $signed({ip_pl[15], ip_pl});
	wire signed [16:0] ip_dr = $signed({ip_cr[15], ip_cr}) - $signed({ip_pr[15], ip_pr});
	wire [15:0]  ip_f = ip_q[16] ? 16'hFFFF : ip_q[15:0];
	wire signed [33:0] ip_ml = ip_dl * $signed({1'b0, ip_f});
	wire signed [33:0] ip_mr = ip_dr * $signed({1'b0, ip_f});
	always @(posedge clk) begin
		audio_lr_we <= 1'b0;
		if (rst) begin
			ip_t <= 13'd0; ip_per <= 13'd0; ip_run <= 1'b0; ip_l0 <= 16'd0; ip_r0 <= 16'd0; ip_l1 <= 16'd0; ip_r1 <= 16'd0;
			audio_lr <= 32'd0;
		end else begin
			if (dac_new) begin
				// (dac_new comes the clock after the sample went to dac_l: it is the new one --
				// taken as the older of the two, the "interpolation" was holding again)
				ip_l0 <= ip_l1; ip_r0 <= ip_r1; ip_l1 <= dac_l; ip_r1 <= dac_r;
				ip_per <= ip_t; ip_t <= 13'd0;
			end else if (ip_t != 13'h1FFF) ip_t <= ip_t + 13'd1;
			if (out_go && !ip_run) begin
				ip_cl <= ip_l1; ip_cr <= ip_r1; ip_pl <= ip_l0; ip_pr <= ip_r0;
				ip_d <= (ip_per == 13'd0) ? 13'd1 : ip_per;
				ip_rem <= {1'b0, (ip_per == 13'd0) ? 13'd1 : (ip_t > ip_per) ? ip_per : ip_t};
				ip_q <= 17'd0; ip_k <= 5'd0; ip_run <= 1'b1;
			end else if (ip_run) begin
				if (ip_k != 5'd17) begin
					// one bit of t / per: the remainder doubled, the divisor off it when it fits
					if (ip_rem >= {1'b0, ip_d}) begin ip_rem <= (ip_rem - {1'b0, ip_d}) << 1; ip_q <= {ip_q[15:0], 1'b1}; end
					else begin ip_rem <= ip_rem << 1; ip_q <= {ip_q[15:0], 1'b0}; end
					ip_k <= ip_k + 5'd1;
				end else begin
					audio_lr <= {ip_pr + ip_mr[31:16], ip_pl + ip_ml[31:16]}; audio_lr_we <= 1'b1;
					ip_run <= 1'b0;
				end
			end
		end
	end
	integer t = 0, k = 0, nout = 0, rep = 0; reg [31:0] last = 0;
	always @(posedge clk) begin
		t <= t + 1;
		dac_new <= 1'b0; out_go <= 1'b0;
		if (t % 1562 == 0) begin dac_new <= 1'b1; dac_l <= dac_l + 16'd1000; dac_r <= 16'd0; end   // a ramp, 32 kHz
		if (t % 1134 == 0) out_go <= 1'b1;                                                        // 44.1 kHz
		if (audio_lr_we) begin
			nout = nout + 1; if (audio_lr == last) rep = rep + 1; last = audio_lr;
			if (nout < 12) $display("out %0d: L=%0d  (dac_l now %0d, ip_l0 %0d, ip_t %0d, ip_per %0d, q %h)", nout, audio_lr[15:0], dac_l, ip_l0, ip_t, ip_per, ip_q);
		end
	end
	initial begin
		repeat (5) @(posedge clk); rst = 0;
		repeat (200000) @(posedge clk);
		$display("tb_aip: %0d outputs, %0d repeats", nout, rep);
		$finish;
	end
endmodule
`default_nettype wire
