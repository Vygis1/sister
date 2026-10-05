//////////////////////////////////////////////////////////////////////////////////
// tb_n64_rdp_cc - the RDP's combiner (n64_rdp_cc.v) against tools/n64/n64rdp.py's,
// on random vectors: python tools/n64/n64rdpvec.py cc N, then ./tools/sim.sh tb_n64_rdp_cc
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_rdp_cc;
	reg  [3:0]  sa, sb;  reg [4:0] sc;  reg [2:0] sd, aa, ab, ac, ad;
	reg  [31:0] prim, env;  reg [23:0] kcen, kscl;  reg [8:0] k4, k5;  reg [7:0] plf;
	reg  [9:0]  cmb [0:3], t0 [0:3], t1 [0:3], sh [0:3];
	reg  [8:0]  lodf, noise;
	reg  [8:0]  expect [0:3];
	wire [26:0] ka, kb, kc, kd;  wire [8:0] kaa, kab, kac, kad;
	wire [39:0] out;
	n64_rdp_ccconst u_k (.sa(sa), .sb(sb), .sc(sc), .sd(sd), .aa(aa), .ab(ab), .ac(ac), .ad(ad),
		.prim(prim), .env(env), .key_center(kcen), .key_scale(kscl), .k4(k4), .k5(k5), .prim_lod_frac(plf),
		.ka(ka), .kb(kb), .kc(kc), .kd(kd), .kaa(kaa), .kab(kab), .kac(kac), .kad(kad));
	n64_rdp_cc u_cc (.sa(sa), .sb(sb), .sc(sc), .sd(sd), .aa(aa), .ab(ab), .ac(ac), .ad(ad),
		.combined({cmb[0], cmb[1], cmb[2], cmb[3]}), .texel0({t0[0], t0[1], t0[2], t0[3]}),
		.texel1({t1[0], t1[1], t1[2], t1[3]}), .shade({sh[0], sh[1], sh[2], sh[3]}),
		.lod_frac(lodf), .noise(noise), .ka(ka), .kb(kb), .kc(kc), .kd(kd),
		.kaa(kaa), .kab(kab), .kac(kac), .kad(kad), .out(out));
	integer fd, code, n, i, j, bad;
	reg [31:0] v;
	initial begin
		fd = $fopen("../../sim/n64d/cc_vec.hex", "r");
		code = $fscanf(fd, "%h", n);
		bad = 0;
		for (i = 0; i < n; i = i + 1) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h", sa, sb, sc, sd, aa, ab, ac, ad);
			code = $fscanf(fd, "%h %h %h %h %h %h %h", prim, env, kcen, kscl, k4, k5, plf);
			for (j = 0; j < 4; j = j + 1) begin code = $fscanf(fd, "%h", v); cmb[j] = v[9:0]; end
			for (j = 0; j < 4; j = j + 1) begin code = $fscanf(fd, "%h", v); t0[j] = v[9:0]; end
			for (j = 0; j < 4; j = j + 1) begin code = $fscanf(fd, "%h", v); t1[j] = v[9:0]; end
			for (j = 0; j < 4; j = j + 1) begin code = $fscanf(fd, "%h", v); sh[j] = v[9:0]; end
			code = $fscanf(fd, "%h %h", lodf, noise);
			for (j = 0; j < 4; j = j + 1) begin code = $fscanf(fd, "%h", v); expect[j] = v[8:0]; end
			#1;
			for (j = 0; j < 4; j = j + 1)
				if (out[39 - 10 * j -: 9 + 1] % 512 != expect[j]) begin
					bad = bad + 1;
					if (bad < 6) $display("tb_n64_rdp_cc: vector %0d channel %0d: sel %h %h %h %h | %h %h %h %h: got %03x, model %03x",
					                      i, j, sa, sb, sc, sd, aa, ab, ac, ad, out[39 - 10 * j -: 10] & 10'h1FF, expect[j]);
				end
		end
		if (bad == 0) $display("tb_n64_rdp_cc: PASS, %0d vectors agree with the model", n);
		else $display("tb_n64_rdp_cc: FAIL, %0d channels differ", bad);
		$finish;
	end
endmodule

`default_nettype wire
