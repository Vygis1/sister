//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_cc.v - one cycle of the RDP's colour combiner, (A - B) * C + D on the
// four channels, as tools/n64rdp.py combiner_raw does it (combiner.h).
//
// Combinational: the selectors (SET_COMBINE's fields for this cycle), the
// inputs (9-bit where the model's are; COMBINED is the last cycle's unclamped
// result), the constants each selector reads (combiner_constants, in
// n64_rdp_ccconst below), and out the four unclamped channels.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_cc (
	input  wire [3:0]   sa, sb,           // rgb A and B selectors
	input  wire [4:0]   sc,               // rgb C
	input  wire [2:0]   sd,               // rgb D
	input  wire [2:0]   aa, ab, ac, ad,   // alpha A, B, C, D
	// the inputs: {r, g, b, a}, each 10 bits signed (9 significant, as the model's)
	input  wire [39:0]  combined, texel0, texel1, shade,
	input  wire [8:0]   lod_frac, noise,
	// the constants for this cycle's selectors (n64_rdp_ccconst)
	input  wire [26:0]  ka, kb, kc, kd,   // rgb, 9 bits a channel (K4 and K5 have nine)
	input  wire [8:0]   kaa, kab, kac, kad,
	output wire [39:0]  out               // {r, g, b, a}, 10 bits signed each (unclamped)
);
	function [9:0] ch; input [39:0] v; input [1:0] i; ch = v[39 - 10 * i -: 10]; endfunction

	// one channel's (A - B) * C + D: combiner_equation
	function [9:0] eqn; input [9:0] a, b, c, d;
		reg signed [9:0] a9, b9, d9;  reg signed [9:0] c9;  reg signed [19:0] p;  reg signed [10:0] diff;
	begin
		a9 = {1'b0, a[8:0] + 9'h80};          // ((a + 0x80) & 0x1FF), 0..511
		b9 = {1'b0, b[8:0] + 9'h80};
		d9 = {1'b0, d[8:0] + 9'h80};
		c9 = {c[8], c[8:0]};                  // sext(c, 9)
		diff = a9 - b9;
		p = diff * c9 + 20'sd128;
		eqn = (p >>> 8) + d9 - 10'sd128;
	end endfunction

	genvar i;
	generate for (i = 0; i < 3; i = i + 1) begin : g_rgb
		wire [9:0] a = (sa == 4'd0) ? ch(combined, i) : (sa == 4'd1) ? ch(texel0, i) : (sa == 4'd2) ? ch(texel1, i)
		             : (sa == 4'd4) ? ch(shade, i) : (sa == 4'd6) ? 10'h100 : (sa == 4'd7) ? {1'b0, noise}
		             : {1'b0, ka[26 - 9 * i -: 9]};
		wire [9:0] b = (sb == 4'd0) ? ch(combined, i) : (sb == 4'd1) ? ch(texel0, i) : (sb == 4'd2) ? ch(texel1, i)
		             : (sb == 4'd4) ? ch(shade, i) : {1'b0, kb[26 - 9 * i -: 9]};
		wire [9:0] c = (sc == 5'd0) ? ch(combined, i) : (sc == 5'd1) ? ch(texel0, i) : (sc == 5'd2) ? ch(texel1, i)
		             : (sc == 5'd4) ? ch(shade, i) : (sc == 5'd7) ? ch(combined, 3) : (sc == 5'd8) ? ch(texel0, 3)
		             : (sc == 5'd9) ? ch(texel1, 3) : (sc == 5'd11) ? ch(shade, 3) : (sc == 5'd13) ? {1'b0, lod_frac}
		             : {1'b0, kc[26 - 9 * i -: 9]};
		wire [9:0] d = (sd == 3'd0) ? ch(combined, i) : (sd == 3'd1) ? ch(texel0, i) : (sd == 3'd2) ? ch(texel1, i)
		             : (sd == 3'd4) ? ch(shade, i) : (sd == 3'd6) ? 10'h100 : {1'b0, kd[26 - 9 * i -: 9]};
		assign out[39 - 10 * i -: 10] = eqn(a, b, c, d);
	end endgenerate
	wire [9:0] a_abd_a = (aa == 3'd0) ? ch(combined, 3) : (aa == 3'd1) ? ch(texel0, 3) : (aa == 3'd2) ? ch(texel1, 3)
	                   : (aa == 3'd4) ? ch(shade, 3) : (aa == 3'd6) ? 10'h100 : {1'b0, kaa};
	wire [9:0] a_abd_b = (ab == 3'd0) ? ch(combined, 3) : (ab == 3'd1) ? ch(texel0, 3) : (ab == 3'd2) ? ch(texel1, 3)
	                   : (ab == 3'd4) ? ch(shade, 3) : (ab == 3'd6) ? 10'h100 : {1'b0, kab};
	wire [9:0] a_c     = (ac == 3'd0) ? {1'b0, lod_frac} : (ac == 3'd1) ? ch(texel0, 3) : (ac == 3'd2) ? ch(texel1, 3)
	                   : (ac == 3'd4) ? ch(shade, 3) : {1'b0, kac};
	wire [9:0] a_abd_d = (ad == 3'd0) ? ch(combined, 3) : (ad == 3'd1) ? ch(texel0, 3) : (ad == 3'd2) ? ch(texel1, 3)
	                   : (ad == 3'd4) ? ch(shade, 3) : (ad == 3'd6) ? 10'h100 : {1'b0, kad};
	assign out[9:0] = eqn(a_abd_a, a_abd_b, a_c, a_abd_d);
endmodule

// the constant each selector of a cycle reads: combiner_constants
module n64_rdp_ccconst (
	input  wire [3:0]   sa, sb,
	input  wire [4:0]   sc,
	input  wire [2:0]   sd, aa, ab, ac, ad,
	input  wire [31:0]  prim, env,
	input  wire [23:0]  key_center, key_scale,   // r, g, b
	input  wire [8:0]   k4, k5,                   // SET_CONVERT's K4, K5
	input  wire [7:0]   prim_lod_frac,
	output wire [26:0]  ka, kb, kc, kd,
	output wire [8:0]   kaa, kab, kac, kad
);
	wire [26:0] prgb = {1'b0, prim[31:24], 1'b0, prim[23:16], 1'b0, prim[15:8]};
	wire [26:0] ergb = {1'b0, env[31:24], 1'b0, env[23:16], 1'b0, env[15:8]};
	wire [26:0] kcen = {1'b0, key_center[23:16], 1'b0, key_center[15:8], 1'b0, key_center[7:0]};
	wire [26:0] kscl = {1'b0, key_scale[23:16], 1'b0, key_scale[15:8], 1'b0, key_scale[7:0]};
	assign ka = (sa == 4'd3) ? prgb : (sa == 4'd5) ? ergb : 27'd0;
	assign kb = (sb == 4'd3) ? prgb : (sb == 4'd5) ? ergb : (sb == 4'd6) ? kcen : (sb == 4'd7) ? {3{k4}} : 27'd0;
	assign kc = (sc == 5'd3) ? prgb : (sc == 5'd5) ? ergb : (sc == 5'd6) ? kscl : (sc == 5'd10) ? {3{1'b0, prim[7:0]}}
	          : (sc == 5'd12) ? {3{1'b0, env[7:0]}} : (sc == 5'd14) ? {3{1'b0, prim_lod_frac}} : (sc == 5'd15) ? {3{k5}} : 27'd0;
	assign kd = (sd == 3'd3) ? prgb : (sd == 3'd5) ? ergb : 27'd0;
	function [8:0] al; input [2:0] s; input [31:0] p, e; al = (s == 3'd3) ? {1'b0, p[7:0]} : (s == 3'd5) ? {1'b0, e[7:0]} : 9'd0; endfunction
	assign kaa = al(aa, prim, env);
	assign kab = al(ab, prim, env);
	assign kad = al(ad, prim, env);
	assign kac = (ac == 3'd3) ? {1'b0, prim[7:0]} : (ac == 3'd5) ? {1'b0, env[7:0]} : (ac == 3'd6) ? {1'b0, prim_lod_frac} : 9'd0;
endmodule

`default_nettype wire
