//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_tex.v - the RDP's texture sampler: a texel of a tile at (s, t), as
// tools/n64rdp.py sample_texture does it (texture.h): the coordinates shifted,
// clamped, wrapped and mirrored; up to four texels read from TMEM at once (one
// per copy, n64_rdp_tmem.v), through the TLUT where there is one; and the
// filter: 3-tap bilinear, the mid-texel average, or the one texel.
//
// Not yet: YUV, the convert stage (SET_CONVERT's K0-K3) and convert_one.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_tex (
	input  wire         clk,
	input  wire         rst,
	input  wire         go,
	output reg          done,             // a clock, with the texel
	input  wire signed [16:0] s_in, t_in, // s10.5 (the perspective divide's, or straight)
	// the tile (SET_TILE as sent: n64_rdp2.v tile_w; SET_TILE_SIZE)
	input  wire [55:0]  tw,
	input  wire [47:0]  tsz,
	// the modes
	input  wire         tlut, tlut_type, sample_quad, mid_texel_en, bilerp,
	// TMEM's four read ports
	output reg  [10:0]  ra0, ra1, ra2, ra3,
	input  wire [15:0]  rq0, rq1, rq2, rq3,
	output reg  [39:0]  texel              // {r, g, b, a}, 10 bits each, signed
);
	// --- the tile ---------------------------------------------------------------------------
	wire [2:0]   fmt = tw[55:53];
	wire [1:0]   size = tw[52:51];
	wire [8:0]   line = tw[49:41];
	wire [8:0]   tmem = tw[40:32];
	wire [3:0]   palette = tw[23:20];
	wire         clamp_t_b = tw[19], mirror_t = tw[18];
	wire [3:0]   mask_t_r = tw[17:14], shift_t = tw[13:10];
	wire         clamp_s_b = tw[9], mirror_s = tw[8];
	wire [3:0]   mask_s_r = tw[7:4], shift_s = tw[3:0];
	// (SET_TILE: a mask over 10 is 10; a mask of 0 clamps)
	wire [3:0]   mask_s = (mask_s_r > 4'd10) ? 4'd10 : mask_s_r;
	wire [3:0]   mask_t = (mask_t_r > 4'd10) ? 4'd10 : mask_t_r;
	wire         clamp_s = clamp_s_b || mask_s_r == 4'd0;
	wire         clamp_t = clamp_t_b || mask_t_r == 4'd0;
	wire [11:0]  slo = tsz[47:36], tlo = tsz[35:24], shi = tsz[23:12], thi = tsz[11:0];
	wire [11:0]  offset = {tmem, 3'b000};          // bytes
	wire [11:0]  stride = {line, 3'b000};

	// --- the coordinates (clamp_and_shift_coord, texel_mask_s/t) -----------------------------
	function signed [15:0] shift_c; input signed [16:0] c; input [3:0] sh; reg signed [16:0] cc; reg signed [31:0] w; begin
		cc = (c < -17'sd32768) ? -17'sd32768 : (c > 17'sd32767) ? 17'sd32767 : c;
		if (sh < 4'd11) shift_c = cc >>> sh;
		else begin w = {{15{cc[16]}}, cc} <<< (5'd16 - {1'b0, sh}); shift_c = w[15:0]; end
	end endfunction
	function signed [16:0] clamp_c; input clamp; input signed [16:0] c; input [3:0] sh; input [11:0] lo, hi;
		reg signed [15:0] v; reg signed [17:0] d;
	begin
		v = shift_c(c, sh);
		d = {{2{v[15]}}, v} - {3'd0, lo, 3'd0};
		if (clamp) begin
			if ((v >>> 3) >= $signed({4'd0, hi})) clamp_c = {2'b00, (hi[11:2] - lo[11:2]), 5'd0};
			else clamp_c = (d < 0) ? 17'sd0 : d[16:0];
		end else clamp_c = d[16:0];
	end endfunction
	function [10:0] mask_c; input signed [11:0] v; input [3:0] m; input mirror; reg [11:0] x, msk; begin
		x = v;
		if (m != 4'd0) begin
			msk = 12'd1 << m;
			if (mirror && (x & msk) != 12'd0) x = x ^ (msk - 12'd1);
			x = x & (msk - 12'd1);
		end
		mask_c = x[10:0];
	end endfunction

	// --- the texels' addresses -------------------------------------------------------------------
	// _byte_index / _word_index: TMEM bytes (offset + stride * t + s's bytes) & mask, odd lines swapped
	function [11:0] byte_ix; input [11:0] sb; input signed [9:0] t; input [11:0] msk; reg signed [23:0] a; begin
		a = $signed({12'd0, offset}) + $signed({12'd0, stride}) * t + $signed({12'd0, sb});
		byte_ix = (a[11:0] & msk) ^ {9'd0, t[0], 2'b00};
	end endfunction
	function [10:0] word_ix; input [10:0] s; input signed [9:0] t; input [11:0] msk; reg signed [23:0] a; reg [11:0] m; begin
		a = $signed({12'd0, offset}) + $signed({12'd0, stride}) * t + $signed({12'd0, s, 1'b0});
		m = a[11:0] & msk;
		word_ix = m[11:1] ^ {9'd0, t[0], 1'b0};
	end endfunction

	reg  [10:0]  s0, s1;
	reg  signed [9:0] t0, t1;             // t0 & 0xFF, and t1 = that + max(t1 - t0, -255)
	reg  [4:0]   fx, fy;
	reg          upper_raw, upper, mid_texel;   // fx + fy >= 32: as fetched; and after mid-texel
	// a texel's first read: the word index, and (4/8-bit) the byte or nibble in it
	reg  [11:0]  bix [0:3];
	reg  [10:0]  wix [0:3];
	reg  [10:0]  ts [0:3];  reg signed [9:0] tt [0:3];   // each texel's s, t
	reg  [1:0]   lutoff [0:3];

	// --- decoding (texel_*) ------------------------------------------------------------------
	function [39:0] rgba16; input [15:0] w; reg [4:0] r, g, b; begin
		r = w[15:11]; g = w[10:6]; b = w[5:1];
		rgba16 = {2'b00, r, r[4:2], 2'b00, g, g[4:2], 2'b00, b, b[4:2], 2'b00, {8{w[0]}}};
	end endfunction
	function [39:0] ia16; input [15:0] w; ia16 = {2'b00, w[15:8], 2'b00, w[15:8], 2'b00, w[15:8], 2'b00, w[7:0]}; endfunction
	function [39:0] rep4; input [7:0] v; rep4 = {2'b00, v, 2'b00, v, 2'b00, v, 2'b00, v}; endfunction

	reg  [15:0]  fw [0:3];                // the first reads' words
	reg  [7:0]   cidx [0:3];              // a TLUT's index (4/8-bit), or the 16-bit word's high bits
	reg  [39:0]  tx [0:3];                // the four texels: base, t10, t01, t11
	reg  [3:0]   st;
	localparam [3:0] T_IDLE = 4'd0, T_COORD = 4'd1, T_ADDR = 4'd2, T_R1 = 4'd3, T_D1 = 4'd4, T_R2 = 4'd5,
	                 T_D2 = 4'd6, T_FILT = 4'd7;
	integer      i;
	wire [1:0]   fsel = (tlut) ? 2'd3 : 2'd0;

	always @(posedge clk) begin
		done <= 1'b0;
		if (rst) st <= T_IDLE;
		else case (st)
		T_IDLE: if (go) st <= T_COORD;
		T_COORD: begin : coord
			reg signed [16:0] sc, tcv; reg [10:0] sm0, sm1, tm0, tm1; reg signed [11:0] si, ti; reg signed [11:0] td;
			reg [4:0] ffx, ffy;
			sc = clamp_c(clamp_s, s_in, shift_s, slo, shi);
			tcv = clamp_c(clamp_t, t_in, shift_t, tlo, thi);
			ffx = (sample_quad || tlut) ? sc[4:0] : 5'd0;
			ffy = (sample_quad || tlut) ? tcv[4:0] : 5'd0;
			fx <= ffx; fy <= ffy;
			si = sc >>> 5; ti = tcv >>> 5;
			sm0 = mask_c(si, mask_s, mirror_s);
			sm1 = mask_c(si + 12'sd1, mask_s, mirror_s);
			tm0 = mask_c(ti, mask_t, mirror_t);
			tm1 = mask_c(ti + 12'sd1, mask_t, mirror_t);
			td = $signed({1'b0, tm1}) - $signed({1'b0, tm0});
			if (td < -12'sd255) td = -12'sd255;
			s0 <= sm0; s1 <= sm1;
			t0 <= {2'b00, tm0[7:0]};
			t1 <= $signed({2'b00, tm0[7:0]}) + td[9:0];
			mid_texel <= mid_texel_en && bilerp && ffx == 5'h10 && ffy == 5'h10;
			upper_raw <= ({1'b0, ffx} + {1'b0, ffy}) >= 6'h20;
			upper <= ({1'b0, ffx} + {1'b0, ffy}) >= 6'h20 && !(mid_texel_en && bilerp && ffx == 5'h10 && ffy == 5'h10);
			st <= T_ADDR;
		end
		T_ADDR: begin
			// the four texels: base (s1, t1 when the fractions add to a texel or more),
			// t10 (s1, t0), t01 (s0, t1), t11 (s1, t1). Without sample_quad, only the base,
			// at (s0, t0)
			ts[0] <= upper ? s1 : s0;
			tt[0] <= upper ? t1 : t0;
			ts[1] <= s1; tt[1] <= t0;
			ts[2] <= s0; tt[2] <= t1;
			ts[3] <= s1; tt[3] <= t1;
			if (tlut && !sample_quad) begin ts[1] <= s0; ts[3] <= s0; tt[2] <= t0; tt[3] <= t0; ts[0] <= s0; tt[0] <= t0; end
			lutoff[0] <= upper ? 2'd3 : 2'd0; lutoff[1] <= 2'd1; lutoff[2] <= 2'd2; lutoff[3] <= 2'd3;
			st <= T_R1;
		end
		T_R1: begin : r1
			// the first read of each texel
			reg [11:0] bi; reg [10:0] wi; reg [11:0] msk;
			for (i = 0; i < 4; i = i + 1) begin
				msk = (tlut || size == 2'd3) ? 12'h7FF : 12'hFFF;
				if (size == 2'd0) bi = byte_ix({1'b0, ts[i][10:1]}, tt[i], msk);
				else bi = byte_ix({1'b0, ts[i]}, tt[i], msk);
				wi = word_ix(ts[i], tt[i], msk);
				bix[i] <= bi; wix[i] <= wi;
				case (i)
				0: ra0 <= (size[1]) ? wi : bi[11:1];
				1: ra1 <= (size[1]) ? wi : bi[11:1];
				2: ra2 <= (size[1]) ? wi : bi[11:1];
				default: ra3 <= (size[1]) ? wi : bi[11:1];
				endcase
			end
			st <= T_D1;
		end
		T_D1: st <= T_R2;                     // (TMEM answers a clock after the address)
		T_R2: begin : r2
			// the words: decode, or (a TLUT, a 32-bit texel) the second reads
			reg [15:0] w; reg [7:0] byt; reg [3:0] nib; reg [7:0] v; reg [10:0] e;
			for (i = 0; i < 4; i = i + 1) begin
				w = (i == 0) ? rq0 : (i == 1) ? rq1 : (i == 2) ? rq2 : rq3;
				fw[i] <= w;
				byt = bix[i][0] ? w[7:0] : w[15:8];
				nib = ts[i][0] ? byt[3:0] : byt[7:4];
				if (tlut) begin
					// the index, to the TLUT: ((v << 2) + offset) ^ (upper ? 3 : 0), in the high half
					v = (size == 2'd0) ? {palette, nib} : (size == 2'd1) ? byt : w[15:8];
					// (addr_xor ^ 1: 3 when the fractions add to a texel, before mid-texel)
					e = (({3'd0, v} << 2) + {9'd0, lutoff[i]}) ^ (upper_raw ? 11'd3 : 11'd0);
					if (size[1]) e = ({1'b0, w[15:8], 2'b00} + {9'd0, lutoff[i]}) ^ (upper_raw ? 11'd3 : 11'd0);
					case (i)
					0: ra0 <= {1'b1, e[9:0]};
					1: ra1 <= {1'b1, e[9:0]};
					2: ra2 <= {1'b1, e[9:0]};
					default: ra3 <= {1'b1, e[9:0]};
					endcase
				end else if (size == 2'd3 && fmt == 3'd0) begin
					case (i)
					0: ra0 <= wix[0] | 11'h400;
					1: ra1 <= wix[1] | 11'h400;
					2: ra2 <= wix[2] | 11'h400;
					default: ra3 <= wix[3] | 11'h400;
					endcase
				end
				case ({fmt == 3'd0 ? 2'd0 : fmt == 3'd2 ? 2'd1 : fmt == 3'd3 ? 2'd2 : 2'd3, size})
				// RGBA
				4'b00_00: tx[i] <= rep4({nib, nib});
				4'b00_01: tx[i] <= rep4(byt);
				4'b00_10: tx[i] <= rgba16(w);
				// CI (no TLUT)
				4'b01_00: tx[i] <= rep4({palette, nib});
				4'b01_01: tx[i] <= rep4(byt);
				// IA
				4'b10_00: tx[i] <= {2'b00, nib[3:1], nib[3:1], nib[3:2], 2'b00, nib[3:1], nib[3:1], nib[3:2],
				                    2'b00, nib[3:1], nib[3:1], nib[3:2], 2'b00, {8{nib[0]}}};
				4'b10_01: tx[i] <= {2'b00, byt[7:4], byt[7:4], 2'b00, byt[7:4], byt[7:4], 2'b00, byt[7:4], byt[7:4], 2'b00, byt[3:0], byt[3:0]};
				4'b10_10: tx[i] <= ia16(w);
				// I (and the other codes)
				4'b11_00: tx[i] <= rep4({nib, nib});
				4'b11_01: tx[i] <= rep4(byt);
				// the 16-bit CI and I, and every 32-bit but RGBA: w as (hi, lo, hi, lo)
				default: tx[i] <= {2'b00, w[15:8], 2'b00, w[7:0], 2'b00, w[15:8], 2'b00, w[7:0]};
				endcase
			end
			st <= (tlut || (size == 2'd3 && fmt == 3'd0)) ? T_D2 : T_FILT;
		end
		T_D2: st <= T_D2 + 4'd8;              // (a clock for TMEM: T_D2 + 8 is "the second words")
		4'd14: begin
			for (i = 0; i < 4; i = i + 1) begin : w2
				reg [15:0] w;
				w = (i == 0) ? rq0 : (i == 1) ? rq1 : (i == 2) ? rq2 : rq3;
				if (tlut) tx[i] <= tlut_type ? ia16(w) : rgba16(w);
				else tx[i] <= {2'b00, fw[i][15:8], 2'b00, fw[i][7:0], 2'b00, w[15:8], 2'b00, w[7:0]};   // RGBA32
			end
			st <= T_FILT;
		end
		T_FILT: begin : filt
			// the filter: mid-texel average; 3-tap bilinear; or the base texel
			reg signed [11:0] b, a10, a01, a11, r; reg [4:0] ffx, ffy; reg signed [17:0] acc;
			ffx = upper ? 5'd0 - fy : fx;            // (32 - fy, as five bits: 32 - fy is 1..32)
			ffy = upper ? 5'd0 - fx : fy;
			for (i = 0; i < 4; i = i + 1) begin
				b   = {{2{tx[0][39 - 10 * i]}}, tx[0][39 - 10 * i -: 10]};
				a10 = {{2{tx[1][39 - 10 * i]}}, tx[1][39 - 10 * i -: 10]};
				a01 = {{2{tx[2][39 - 10 * i]}}, tx[2][39 - 10 * i -: 10]};
				a11 = {{2{tx[3][39 - 10 * i]}}, tx[3][39 - 10 * i -: 10]};
				if (mid_texel) r = (b + a01 + a10 + a11 + 12'sd2) >>> 2;
				else if (bilerp && (sample_quad || tlut)) begin
					acc = (a10 - b) * $signed({1'b0, upper ? 6'd32 - {1'b0, fy} : {1'b0, fx}})
					    + (a01 - b) * $signed({1'b0, upper ? 6'd32 - {1'b0, fx} : {1'b0, fy}}) + 18'sd16;
					r = (acc >>> 5) + b;
				end else r = b;
				texel[39 - 10 * i -: 10] <= r[9:0];
			end
			done <= 1'b1;
			st <= T_IDLE;
		end
		default: st <= T_IDLE;
		endcase
	end
endmodule

`default_nettype wire
