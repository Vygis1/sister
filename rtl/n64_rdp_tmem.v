//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_tmem.v - the RDP's texture memory and its loads (LOAD_BLOCK, LOAD_TILE,
// LOAD_TLUT), done forward, a source doubleword at a time, as the chip does them.
// tools/n64rdp.py (from parallel-RDP) works the same loads out backwards (which
// source writes each TMEM word last); the two are checked against each other on
// TMEM's contents (tools/n64rdpsim.py, sim/tb_n64_rdp.v).
//
// TMEM is 2048 16-bit words (tools/n64rdp.py's indexing: word i is bytes 2i,
// 2i+1), kept as four banks of 512 by the word's index & 3, so a doubleword is
// written in one clock and four words can be read at once.
//
// The loads (tools/n64rdp.py RDP.load, load_iteration, tmem_word_*):
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
	// the sampler's reads: four words, by index (a clock later)
	input  wire [10:0]  ra0, ra1, ra2, ra3,
	output wire [15:0]  rq0, rq1, rq2, rq3,
	// tests: TMEM word by index, a clock later
	input  wire [10:0]  dbg_a,
	output reg  [15:0]  dbg_q
);
	// --- the memory: four copies of 512 doublewords, one block RAM each, written
	// together (a doubleword's 16-bit lanes by enable), each read by one of the
	// sampler's ports. Word i is lane i[1:0] (lane 0 the high bits) of doubleword i[10:2].
	reg  [63:0]  cp0 [0:511], cp1 [0:511], cp2 [0:511], cp3 [0:511];
	reg  [3:0]   wen;                     // the lanes written
	reg  [8:0]   wa;                      // the doubleword
	reg  [63:0]  wdw;
	integer      b;
	always @(posedge clk) begin
		for (b = 0; b < 4; b = b + 1) if (wen[b]) begin
			cp0[wa][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			cp1[wa][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			cp2[wa][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
			cp3[wa][63 - 16 * b -: 16] <= wdw[63 - 16 * b -: 16];
		end
	end
	reg  [63:0]  q0, q1, q2, q3;  reg [1:0] l0, l1, l2, l3;
	always @(posedge clk) begin
		q0 <= cp0[ra0[10:2]]; q1 <= cp1[ra1[10:2]]; q2 <= cp2[ra2[10:2]]; q3 <= cp3[ra3[10:2]];
		l0 <= ra0[1:0]; l1 <= ra1[1:0]; l2 <= ra2[1:0]; l3 <= ra3[1:0];
	end
	assign rq0 = q0[63 - 16 * l0 -: 16], rq1 = q1[63 - 16 * l1 -: 16];
	assign rq2 = q2[63 - 16 * l2 -: 16], rq3 = q3[63 - 16 * l3 -: 16];
	// (tests read through port 0's copy, with the loads done)
	reg  [63:0]  dq;  reg [1:0] dl;
	always @(posedge clk) begin dq <= cp0[dbg_a[10:2]]; dl <= dbg_a[1:0]; end
	always @(*) dbg_q = dq[63 - 16 * dl -: 16];

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
