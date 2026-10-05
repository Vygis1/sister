//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_tmem.v - the RDP's texture memory and its loads (LOAD_BLOCK, LOAD_TILE,
// LOAD_TLUT), done forward, a source doubleword at a time, as the chip does them.
// tools/n64/n64rdp.py (from parallel-RDP) works the same loads out backwards (which
// source writes each TMEM word last); the two are checked against each other on
// TMEM's contents (tools/n64/n64rdpsim.py, sim/tb_n64_rdp.v).
//
// TMEM is 2048 16-bit words (tools/n64/n64rdp.py's indexing: word i is bytes 2i,
// 2i+1), kept as four banks of 512 by the word's index & 3, so a doubleword is
// written in one clock and four words can be read at once.
//
// The loads (tools/n64/n64rdp.py RDP.load, load_iteration, tmem_word_*):
//   LOAD_BLOCK: the texels from (sl, tl) on, in a line, into consecutive TMEM
//     doublewords from the tile's address. A line counter t adds dxt for each
//     doubleword: where its integer part ((i * dxt) >> 11) is odd, the
//     doubleword's 32-bit halves are swapped.
//   LOAD_TILE: rows tl..th of sl..sh, row r at the tile's address + r * its
//     line; odd rows swapped the same way.
//   32-bit and YUV texels split: R and G to the low 2 kB, B and A to the high.
//   LOAD_TLUT: 16-bit entries into the high half, each written four times.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_tmem (
	input  wire         clk,
	input  wire         rst,
	// a load: the command (0x30 TLUT, 0x33 BLOCK, 0x34 TILE) and its words, the
	// tile's descriptor, the texture image
	input  wire         go,
	output wire         busy,
	input  wire [5:0]   op,
	input  wire [31:0]  w0, w1,
	input  wire [2:0]   t_fmt,
	input  wire [1:0]   t_size,
	input  wire [8:0]   t_line,           // SET_TILE's line (in doublewords)
	input  wire [8:0]   t_tmem,           // SET_TILE's address (in doublewords)
	input  wire [23:0]  img_addr,
	input  wire [9:0]   img_width_m1,
	input  wire [1:0]   img_size,
	// RDRAM reads
	output reg          mr_req,
	input  wire         mr_ack,
	output reg  [23:0]  mr_line,
	input  wire [127:0] mr_data,
	// the sampler's reads, a clock later, held while ce is low: four words by index
	// (fa*, a texel's first read, either half), and four more in the high half (sa*,
	// the second read: a TLUT's entry, a 32-bit texel's blue and alpha), on the port
	// the loads write through (a load and a draw never overlap)
	input  wire         ce,
	input  wire [10:0]  fa0, fa1, fa2, fa3,
	output wire [15:0]  fq0, fq1, fq2, fq3,
	input  wire [10:0]  sa0, sa1, sa2, sa3,
	output wire [15:0]  sq0, sq1, sq2, sq3
);
	// --- the memory: four copies, one per sampler port, each in two halves (the low and
	// high 2 kB: 256 doublewords, a block RAM each), written together (a doubleword's
	// 16-bit lanes by enable). Word i is lane i[1:0] (lane 0 the high bits) of doubleword
	// i[10:2]; i[10] is the half.
	reg  [63:0]  lo0 [0:255], lo1 [0:255], lo2 [0:255], lo3 [0:255];
	reg  [63:0]  hi0 [0:255], hi1 [0:255], hi2 [0:255], hi3 [0:255];
	reg  [3:0]   wen;                     // the lanes written
	reg  [8:0]   wa;                      // the doubleword
	reg  [63:0]  wdw;
	integer      b;
	reg  [63:0]  fl0, fl1, fl2, fl3, fh0, fh1, fh2, fh3, sh0, sh1, sh2, sh3;
	reg  [1:0]   lf0, lf1, lf2, lf3, ls0, ls1, ls2, ls3;
	reg          hf0, hf1, hf2, hf3;
	// the low halves: the loads (port A), the first reads (port B)
	always @(posedge clk) begin
		for (b = 0; b < 4; b = b + 1) if (wen[b] && !wa[8]) begin
			lo0[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			lo1[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			lo2[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			lo3[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
		end
	end
	always @(posedge clk) if (ce) begin
		fl0 <= lo0[fa0[9:2]]; fl1 <= lo1[fa1[9:2]]; fl2 <= lo2[fa2[9:2]]; fl3 <= lo3[fa3[9:2]];
	end
	// the high halves: the loads and the second reads (port A), the first reads (port B)
	always @(posedge clk) begin
		for (b = 0; b < 4; b = b + 1) if (wen[b] && wa[8]) begin
			hi0[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			hi1[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			hi2[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			hi3[wa[7:0]][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
		end
		if (ce) begin sh0 <= hi0[sa0[9:2]]; sh1 <= hi1[sa1[9:2]]; sh2 <= hi2[sa2[9:2]]; sh3 <= hi3[sa3[9:2]]; end
	end
	always @(posedge clk) if (ce) begin
		fh0 <= hi0[fa0[9:2]]; fh1 <= hi1[fa1[9:2]]; fh2 <= hi2[fa2[9:2]]; fh3 <= hi3[fa3[9:2]];
	end
	always @(posedge clk) if (ce) begin
		lf0 <= fa0[1:0]; lf1 <= fa1[1:0]; lf2 <= fa2[1:0]; lf3 <= fa3[1:0];
		hf0 <= fa0[10]; hf1 <= fa1[10]; hf2 <= fa2[10]; hf3 <= fa3[10];
		ls0 <= sa0[1:0]; ls1 <= sa1[1:0]; ls2 <= sa2[1:0]; ls3 <= sa3[1:0];
	end
	wire [63:0]  f0 = hf0 ? fh0 : fl0, f1 = hf1 ? fh1 : fl1, f2 = hf2 ? fh2 : fl2, f3 = hf3 ? fh3 : fl3;
	assign fq0 = f0[63 - 16 * lf0 -: 16], fq1 = f1[63 - 16 * lf1 -: 16];
	assign fq2 = f2[63 - 16 * lf2 -: 16], fq3 = f3[63 - 16 * lf3 -: 16];
	assign sq0 = sh0[63 - 16 * ls0 -: 16], sq1 = sh1[63 - 16 * ls1 -: 16];
	assign sq2 = sh2[63 - 16 * ls2 -: 16], sq3 = sh3[63 - 16 * ls3 -: 16];

	// --- the load ------------------------------------------------------------------------------
	wire [11:0]  slo = w0[23:12], tlo = w0[11:0], shi = w1[23:12], thi = w1[11:0];
	wire [10:0]  width = {1'b0, img_width_m1} + 11'd1;
	reg  [1:0]   mode;                    // 0 tile, 1 tlut, 2 block
	localparam [1:0] M_TILE = 2'd0, M_TLUT = 2'd1, M_BLOCK = 2'd2;
	reg  [23:0]  src;                     // the next source doubleword's byte address
	reg  [23:0]  row_src;                 // the row's first
	reg  [11:0]  nwords, wi;              // doublewords a row, and this one
	reg  [11:0]  rows, row;
	reg  [11:0]  dxt;
	reg  [22:0]  tacc;                    // LOAD_BLOCK's line counter (i * dxt)
	reg  [10:0]  dst;                     // the TMEM doubleword the next goes to (in 16-bit words: << 2)
	reg  [10:0]  row_dst;
	reg  [9:0]   hdst, row_hdst;          // 32-bit: the index in each 2 kB half (two texels a doubleword)
	reg  [4:0]   tstep;                   // LOAD_TLUT: TMEM words from one entry to the next
	reg  [63:0]  dw;                      // the source doubleword, big-endian
	reg          split;                   // 32-bit or YUV: halves to the two 2 kB
	reg  [127:0] lbuf; reg [18:0] ltag; reg lv;
	localparam [2:0] L_IDLE = 3'd0, L_FETCH = 3'd1, L_WAIT = 3'd2, L_WRITE = 3'd3, L_WRITE2 = 3'd4, L_NEXT = 3'd5;
	reg  [2:0]   ls;
	assign busy = ls != L_IDLE;
	wire [63:0]  dw_line = {lbuf[8 * {src[3], 3'd0} +: 8], lbuf[8 * {src[3], 3'd1} +: 8], lbuf[8 * {src[3], 3'd2} +: 8],
	                        lbuf[8 * {src[3], 3'd3} +: 8], lbuf[8 * {src[3], 3'd4} +: 8], lbuf[8 * {src[3], 3'd5} +: 8],
	                        lbuf[8 * {src[3], 3'd6} +: 8], lbuf[8 * {src[3], 3'd7} +: 8]};
	// this doubleword's swap: the row's (LOAD_TILE) or the line counter's (LOAD_BLOCK)
	wire         odd = (mode == M_BLOCK) ? tacc[11] : row[0];

	always @(posedge clk) begin
		wen <= 4'd0;
		if (mr_ack) mr_req <= 1'b0;
		if (rst) begin
			ls <= L_IDLE; mr_req <= 1'b0; lv <= 1'b0;
		end else case (ls)
		L_IDLE: if (go) begin : start
			reg [11:0] npix; reg [23:0] base;
			lv <= 1'b0;
			split <= (t_size == 2'd3) || (t_fmt == 3'd1);
			case (op)
			6'h33: begin                                             // LOAD_BLOCK
				mode <= M_BLOCK;
				npix = shi - slo + 12'd1;
				base = img_addr + ((({13'd0, width} * {12'd0, tlo}) + {12'd0, slo}) << (img_size - 2'd1));
				src <= base; row_src <= base;
				// doublewords: the texels' bytes, rounded up
				nwords <= ((({12'd0, npix} << img_size) >> 1) + 24'd7) >> 3;
				rows <= 12'd1; row <= 12'd0; wi <= 12'd0;
				dxt <= thi; tacc <= 23'd0;
				dst <= {t_tmem, 2'b00}; row_dst <= {t_tmem, 2'b00};
				hdst <= {t_tmem[7:0], 2'b00}; row_hdst <= {t_tmem[7:0], 2'b00};
				ls <= (npix == 12'd0 || npix > 12'd2048 || img_size == 2'd0) ? L_IDLE : L_FETCH;
			end
			6'h34: begin                                             // LOAD_TILE
				mode <= M_TILE;
				npix = shi[11:2] - slo[11:2] + 12'd1;
				base = img_addr + ((({13'd0, width} * {14'd0, tlo[11:2]}) + {14'd0, slo[11:2]}) << (img_size - 2'd1));
				src <= base; row_src <= base;
				nwords <= ((({12'd0, npix} << img_size) >> 1) + 24'd7) >> 3;
				rows <= thi[11:2] - tlo[11:2] + 12'd1; row <= 12'd0; wi <= 12'd0;
				tacc <= 23'd0;
				dst <= {t_tmem, 2'b00}; row_dst <= {t_tmem, 2'b00};
				hdst <= {t_tmem[7:0], 2'b00}; row_hdst <= {t_tmem[7:0], 2'b00};
				ls <= (thi[11:2] < tlo[11:2] || img_size == 2'd0) ? L_IDLE : L_FETCH;
			end
			6'h30: begin                                             // LOAD_TLUT
				mode <= M_TLUT;
				npix = shi[11:2] - slo[11:2] + 12'd1;
				base = img_addr + ((({13'd0, width} * {14'd0, tlo[11:2]}) + {14'd0, slo[11:2]}) << 1);
				tstep <= 5'd4 << t_size;
				src <= base; row_src <= base;
				nwords <= npix;                                      // (one entry at a time)
				rows <= 12'd1; row <= 12'd0; wi <= 12'd0;
				dst <= {t_tmem, 2'b00}; row_dst <= {t_tmem, 2'b00};
				ls <= (img_size != 2'd2) ? L_IDLE : L_FETCH;
			end
			default: ;
			endcase
		end
		L_FETCH: begin
			if (lv && ltag == src[22:4]) begin dw <= dw_line; ls <= L_WRITE; end
			else begin mr_req <= 1'b1; mr_line <= {5'd0, src[22:4]}; ls <= L_WAIT; end
		end
		L_WAIT: if (mr_ack) begin lbuf <= mr_data; ltag <= src[22:4]; lv <= 1'b1; ls <= L_FETCH; end
		L_WRITE: begin
			// the doubleword into TMEM
			if (mode == M_TLUT) begin : tl
				// the entry (16 bits at src) four times, at TMEM word 0x400 + 4n
				reg [15:0] e;
				e = src[2] ? (src[1] ? dw[15:0] : dw[31:16]) : (src[1] ? dw[47:32] : dw[63:48]);
				wa <= dst[10:2]; wdw <= {e, e, e, e}; wen <= 4'hF;
				ls <= L_NEXT;
			end else if (!split) begin
				// four words, swapped in pairs on odd lines
				wa <= dst[10:2];
				wdw <= odd ? {dw[31:0], dw[63:32]} : dw;                // (lanes 0,1 <-> 2,3)
				wen <= 4'hF;
				ls <= L_NEXT;
			end else begin
				// 32-bit: two texels' RG to the low half (words dst/2 .. +1, swapped on odd lines)
				// (hdst is even: the two words share a doubleword, lanes l and l + 1)
				begin : lo
					reg [10:0] ix;
					ix = {1'b0, hdst ^ (odd ? 10'd2 : 10'd0)};
					wa <= ix[10:2];
					wdw <= {2{dw[63:48], dw[31:16]}};
					wen <= ix[1] ? 4'b1100 : 4'b0011;
				end
				ls <= L_WRITE2;
			end
		end
		L_WRITE2: begin
			// and their BA to the high half
			begin : hi
				reg [10:0] ix;
				ix = {1'b1, hdst ^ (odd ? 10'd2 : 10'd0)};
				wa <= ix[10:2];
				wdw <= {2{dw[47:32], dw[15:0]}};
				wen <= ix[1] ? 4'b1100 : 4'b0011;
			end
			ls <= L_NEXT;
		end
		L_NEXT: begin
			// on: the next doubleword of the row, or the next row
			tacc <= tacc + {11'd0, dxt};
			if (mode == M_TLUT) begin
				src <= src + 24'd2; dst <= dst + {6'd0, tstep};
			end else begin
				src <= src + 24'd8; dst <= dst + 11'd4; hdst <= hdst + 10'd2;
			end
			if (wi + 12'd1 < nwords) begin wi <= wi + 12'd1; ls <= L_FETCH; end
			else if (row + 12'd1 < rows) begin
				row <= row + 12'd1; wi <= 12'd0;
				row_src <= row_src + ({13'd0, width} << (img_size - 2'd1));
				src <= row_src + ({13'd0, width} << (img_size - 2'd1));
				row_dst <= row_dst + {t_line, 2'b00};
				dst <= row_dst + {t_line, 2'b00};
				row_hdst <= row_hdst + {t_line[7:0], 2'b00};
				hdst <= row_hdst + {t_line[7:0], 2'b00};
				ls <= L_FETCH;
			end else ls <= L_IDLE;
		end
		default: ls <= L_IDLE;
		endcase
	end
endmodule

`default_nettype wire
