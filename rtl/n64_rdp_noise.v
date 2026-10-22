//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_noise.v - the RDP's per-pixel noise, as tools/n64/n64rdp.py reseed_noise works
// it out (parallel-RDP noise.h): from (x, y, the primitive's number), three rounds of
// a' = ((a >> 8) ^ b) * P, b' = ((b >> 8) ^ c) * P, c' = ((c >> 8) ^ a) * P (P = 1103515245,
// all modulo 2^32), and the answer is a >> 16. Only what the last round's a needs is
// made: three products, then two, then one.
//
// `dual` asks for the second cycle's noise instead (the model's R_NEED_NOISE_DUAL:
// reseed_noise(x + 1023, y + 7, prim + 11)).
//
// Ten clocks, a stage for the operands and two for each product (into the DSPs'
// own registers), held while ce is low: what goes in on clock c is out on c + 10.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_noise (
	input  wire         clk,
	input  wire         ce,
	input  wire [12:0]  x,
	input  wire [11:0]  y,
	input  wire [31:0]  prim,
	input  wire         dual,
	output wire [15:0]  noise
);
	localparam [31:0] P = 32'd1103515245;
	reg  [31:0]  a0, b0, c0;
	reg  [31:0]  oa1, ob1, oc1, oa2, ob2, oa3;
	(* use_dsp = "yes" *) reg [31:0] ma1, mb1, mc1, ma2, mb2, ma3;
	(* use_dsp = "yes" *) reg [31:0] pa1, pb1, pc1, pa2, pb2, pa3;
	always @(posedge clk) if (ce) begin
		// 0: the seeds
		a0 <= {19'd0, x} + (dual ? 32'd1023 : 32'd0);
		b0 <= {20'd0, y} + (dual ? 32'd7 : 32'd0);
		c0 <= prim + (dual ? 32'd11 : 32'd0);
		// 1-3: round one
		oa1 <= (a0 >> 8) ^ b0;  ob1 <= (b0 >> 8) ^ c0;  oc1 <= (c0 >> 8) ^ a0;
		ma1 <= oa1 * P;  mb1 <= ob1 * P;  mc1 <= oc1 * P;
		pa1 <= ma1;  pb1 <= mb1;  pc1 <= mc1;
		// 4-6: round two (a and b)
		oa2 <= (pa1 >> 8) ^ pb1;  ob2 <= (pb1 >> 8) ^ pc1;
		ma2 <= oa2 * P;  mb2 <= ob2 * P;
		pa2 <= ma2;  pb2 <= mb2;
		// 7-9: round three (a)
		oa3 <= (pa2 >> 8) ^ pb2;
		ma3 <= oa3 * P;
		pa3 <= ma3;
	end
	assign noise = pa3[31:16];
endmodule

`default_nettype wire
