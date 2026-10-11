//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_persp.v - the RDP's perspective divide: (s, t) / w with a table
// reciprocal, as tools/n64/n64rdp.py perspective_divide does it (perspective.h,
// parallel-RDP, MIT): 17-bit results and an overflow flag. Two clocks; held while ce is low.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_persp (
	input  wire         clk,
	input  wire         ce,
	input  wire signed [15:0] s, t, w,     // s, t, w >> 16 of the interpolated values
	output reg  signed [16:0] so, to,
	output reg          overflow
);
	// the table: (rcp, slope) by the top bits of the normalised w
	reg  [14:0]  tx;  reg signed [11:0] ty;          // (tx 15 bits: entry 0 is 0x4000)
	reg  [5:0]   ti;
	always @(*) begin
		case (ti)
		6'd0: begin tx = 15'h4000; ty = -12'sd1008; end
		6'd1: begin tx = 15'h3f04; ty = -12'sd976; end
		6'd2: begin tx = 15'h3e10; ty = -12'sd952; end
		6'd3: begin tx = 15'h3d22; ty = -12'sd920; end
		6'd4: begin tx = 15'h3c3c; ty = -12'sd892; end
		6'd5: begin tx = 15'h3b5d; ty = -12'sd872; end
		6'd6: begin tx = 15'h3a83; ty = -12'sd840; end
		6'd7: begin tx = 15'h39b1; ty = -12'sd820; end
		6'd8: begin tx = 15'h38e4; ty = -12'sd800; end
		6'd9: begin tx = 15'h381c; ty = -12'sd776; end
		6'd10: begin tx = 15'h375a; ty = -12'sd756; end
		6'd11: begin tx = 15'h369d; ty = -12'sd736; end
		6'd12: begin tx = 15'h35e5; ty = -12'sd716; end
		6'd13: begin tx = 15'h3532; ty = -12'sd700; end
		6'd14: begin tx = 15'h3483; ty = -12'sd680; end
		6'd15: begin tx = 15'h33d9; ty = -12'sd664; end
		6'd16: begin tx = 15'h3333; ty = -12'sd648; end
		6'd17: begin tx = 15'h3291; ty = -12'sd628; end
		6'd18: begin tx = 15'h31f4; ty = -12'sd620; end
		6'd19: begin tx = 15'h3159; ty = -12'sd600; end
		6'd20: begin tx = 15'h30c3; ty = -12'sd588; end
		6'd21: begin tx = 15'h3030; ty = -12'sd572; end
		6'd22: begin tx = 15'h2fa1; ty = -12'sd560; end
		6'd23: begin tx = 15'h2f15; ty = -12'sd548; end
		6'd24: begin tx = 15'h2e8c; ty = -12'sd536; end
		6'd25: begin tx = 15'h2e06; ty = -12'sd524; end
		6'd26: begin tx = 15'h2d83; ty = -12'sd512; end
		6'd27: begin tx = 15'h2d03; ty = -12'sd500; end
		6'd28: begin tx = 15'h2c86; ty = -12'sd492; end
		6'd29: begin tx = 15'h2c0b; ty = -12'sd480; end
		6'd30: begin tx = 15'h2b93; ty = -12'sd468; end
		6'd31: begin tx = 15'h2b1e; ty = -12'sd460; end
		6'd32: begin tx = 15'h2aab; ty = -12'sd452; end
		6'd33: begin tx = 15'h2a3a; ty = -12'sd440; end
		6'd34: begin tx = 15'h29cc; ty = -12'sd432; end
		6'd35: begin tx = 15'h2960; ty = -12'sd424; end
		6'd36: begin tx = 15'h28f6; ty = -12'sd416; end
		6'd37: begin tx = 15'h288e; ty = -12'sd408; end
		6'd38: begin tx = 15'h2828; ty = -12'sd400; end
		6'd39: begin tx = 15'h27c4; ty = -12'sd392; end
		6'd40: begin tx = 15'h2762; ty = -12'sd384; end
		6'd41: begin tx = 15'h2702; ty = -12'sd376; end
		6'd42: begin tx = 15'h26a4; ty = -12'sd368; end
		6'd43: begin tx = 15'h2648; ty = -12'sd364; end
		6'd44: begin tx = 15'h25ed; ty = -12'sd356; end
		6'd45: begin tx = 15'h2594; ty = -12'sd348; end
		6'd46: begin tx = 15'h253d; ty = -12'sd344; end
		6'd47: begin tx = 15'h24e7; ty = -12'sd340; end
		6'd48: begin tx = 15'h2492; ty = -12'sd332; end
		6'd49: begin tx = 15'h243f; ty = -12'sd324; end
		6'd50: begin tx = 15'h23ee; ty = -12'sd320; end
		6'd51: begin tx = 15'h239e; ty = -12'sd316; end
		6'd52: begin tx = 15'h234f; ty = -12'sd308; end
		6'd53: begin tx = 15'h2302; ty = -12'sd304; end
		6'd54: begin tx = 15'h22b6; ty = -12'sd296; end
		6'd55: begin tx = 15'h226c; ty = -12'sd296; end
		6'd56: begin tx = 15'h2222; ty = -12'sd288; end
		6'd57: begin tx = 15'h21da; ty = -12'sd284; end
		6'd58: begin tx = 15'h2193; ty = -12'sd280; end
		6'd59: begin tx = 15'h214d; ty = -12'sd276; end
		6'd60: begin tx = 15'h2108; ty = -12'sd268; end
		6'd61: begin tx = 15'h20c5; ty = -12'sd268; end
		6'd62: begin tx = 15'h2082; ty = -12'sd260; end
		6'd63: begin tx = 15'h2041; ty = -12'sd260; end
		default: begin tx = 15'd0; ty = 12'sd0; end
		endcase
	end
	function [4:0] msb15; input [14:0] v; integer i; begin
		msb15 = 5'd31;                        // (-1 for 0)
		for (i = 0; i < 15; i = i + 1) if (v[i]) msb15 = i;
	end endfunction
	// stage 1: normalise w, look its reciprocal up
	reg          w_carry;
	reg  [3:0]   shift;
	reg  [7:0]   wnorm;
	reg  signed [15:0] s1, t1;
	always @(*) begin : norm
		reg [14:0] wm; reg [4:0] m; reg [13:0] n;
		wm = w[14:0];
		m = msb15(wm);
		shift = (m == 5'd31) ? 4'd14 : 4'd14 - m[3:0];
		n = (wm << shift);
		ti = n[13:8];
		wnorm = n[7:0];
	end
	wire signed [20:0] rcp_p = ty * $signed({1'b0, wnorm});
	wire signed [16:0] rcp_n = (rcp_p >>> 10) + $signed({2'b00, tx});
	reg  [3:0]   shift_q;  reg w_carry_q;  reg signed [15:0] s_q, t_q;
	reg  signed [16:0] rcp_q;
	always @(posedge clk) if (ce) begin
		shift_q <= shift; w_carry_q <= (w <= 16'sd0); s_q <= s; t_q <= t;
		// (the product in 21 bits: sized by rcp_q's 17, ty * wnorm -- up to 1008 * 255 -- wrapped before
		// the shift, and the reciprocal came out wrong for most w; Mario Kart 64's roads and clouds
		// were a step off in colour where the texture was sampled a fraction away)
		rcp_q <= rcp_n;
	end
	// stage 2: the products, shifted, and checked for overflow
	function [17:0] div1; input signed [15:0] c; input signed [16:0] rcp; input [3:0] sh;
		reg signed [33:0] prod; reg [29:0] tmask, oob; reg signed [33:0] temp; reg ovf;
	begin
		prod = c * rcp;
		tmask = 30'h3FFFFFFF & ~((30'h20000000 >> sh) - 30'd1);           // ((1<<30)-1) & -((1<<29) >> shift)
		oob = prod[29:0] & tmask;
		// (the sign test reads prod after its shift, as the model's does)
		if (sh != 4'd14) begin prod = prod >>> (5'd13 - {1'b0, sh}); temp = prod; end
		else temp = prod <<< 1;
		ovf = 1'b0;
		if (oob != tmask && oob != 30'd0) begin
			temp = prod[29] ? -34'sd32768 : 34'sd32767;
			ovf = 1'b1;
		end
		if (temp < -34'sd65536) temp = -34'sd65536;
		if (temp > 34'sd65535) temp = 34'sd65535;
		div1 = {ovf, temp[16:0]};
	end endfunction
	wire [17:0] ds = div1(s_q, rcp_q, shift_q), dt = div1(t_q, rcp_q, shift_q);
	always @(posedge clk) if (ce) begin
		if (w_carry_q) begin so <= 17'sd32767; to <= 17'sd32767; overflow <= 1'b1; end
		else begin so <= ds[16:0]; to <= dt[16:0]; overflow <= ds[17] | dt[17]; end
	end
endmodule

`default_nettype wire
