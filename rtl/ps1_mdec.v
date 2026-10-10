//////////////////////////////////////////////////////////////////////////////////
// ps1_mdec.v - the MDEC (motion decoder): run-length halfwords in, pixels out -- the
// PlayStation's video decompression. docs/MDEC_NOTES.md has the chip; tools/ps1/mdec.py is the
// model this is checked against (sim/tb_ps1_mdec.v), word for word.
//
//   1F801820h  write: a command, then its parameters (also DMA channel 0)
//              read:  the data-out FIFO (also DMA channel 1)
//   1F801824h  write: [31] reset  [30] DMA0 request enable  [29] DMA1 request enable
//              read:  the status (MDEC_NOTES section 1)
//
// The arithmetic is Mednafen's, as the notes recommend: dequantisation to a 15-bit IDCT input,
// two IDCT passes (vertical first) with (sum + 4000h) >> 15 and the scale table cut to 13
// bits, a 9-bit wrap and clamp; YCbCr -> RGB with 359 / -88 / -183 / 454.
//
// A colour macroblock is kept whole and handed out as the chip does: four 8x8 blocks (Y1 Y2 Y3 Y4),
// each row by row. DMA1 puts them in 16-pixel rows as it writes RAM (ps1_dma.v, psx-spx); a CPU
// reading the port gets the blocks (ps1-tests mdec/frame re-orders them itself, and came out in
// stripes when they were already in rows). One multiply-accumulate a clock:
// about 1100 clocks a block, 7000 a macroblock -- ~7500 macroblocks a second at 52.6 MHz,
// near the chip's 9000.
//
// The requests: dreq0 when a command wants more words and the 256-word input FIFO has room for
// a 32-word block (DMA0's size); dreq1 when 32 words are out, or the last few once decoding is done.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module ps1_mdec (
	input  wire        clk,
	input  wire        rst,
	// the CPU: 1F801820h / 24h
	input  wire        sel,          // an access this clock (one clock)
	input  wire        we,
	input  wire        a2,           // 0: 1820h, 1: 1824h
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,        // (combinational; a read of 1820h pops)
	// DMA channel 0: words in
	input  wire        in_wr,
	input  wire [31:0] in_data,
	output wire        in_ready,     // room in the FIFO
	output wire        dreq0,
	// DMA channel 1: words out
	input  wire        out_rd,       // pop (when out_valid)
	output wire [31:0] out_data,
	output wire        out_valid,
	output wire        dreq1,
	// a CPU read of the data port finds nothing yet while a decode is under way: the CPU waits
	// for the word rather than taking a stale one (ps1-tests mdec/frame reads a whole frame
	// word by word without looking, and came out as blocks of noise)
	output wire        rd_stall,
	output wire [1:0]  out_depth,    // the depth being put out (DMA1 re-orders 15- and 24-bit)
	output wire [31:0] dbg_stat,     // (debug) the status word, as 1F801824h reads
	input  wire [2:0]  dbg_idx,      // (debug) the per-command word counts, the last 8 commands:
	output reg  [31:0] dbg_cnt       //   {words pushed in [15:0] of the command's, words read out}
);
	// --- the FIFOs: 32 words each -------------------------------------------------------------
	// The data-in FIFO: 256 words, asked for 32 at a time whenever 32 are free -- DuckStation's
	// (mdec.cpp: DATA_IN_FIFO_SIZE 1024 bytes, data_in_request at 32 words of space). With 32 words
	// taken only when empty, DMA0 was still reading a frame's last words when Syphon Filter's player
	// wrote the next frame over them (one buffer for both): the MDEC decoded the head of one frame
	// and the tail of the next, put out 27 macroblocks too few, and the player dropped the movie.
	(* ram_style = "distributed" *) reg [31:0] ififo [0:255]; reg [7:0] iw, ir; reg [8:0] icnt;
	reg [31:0] ofifo [0:31]; reg [4:0] ow, orr; reg [5:0] ocnt;
	wire       cpu_push = sel && we && !a2;
	wire       cpu_pop  = sel && !we && !a2;
	wire       push     = in_wr || cpu_push;
	wire [31:0] push_d  = in_wr ? in_data : wdata;
	assign in_ready = icnt != 9'd256;
	assign out_data = ofifo[orr];
	assign out_valid = ocnt != 6'd0;

	// --- the command ----------------------------------------------------------------------------
	reg        en_in, en_out;
	reg [1:0]  depth; reg sgn, b15;
	reg [1:0]  kind;                  // 0 none, 1 decode, 2 quant tables, 3 scale table
	reg [15:0] left;                  // its words still to be taken from the FIFO
	reg [15:0] to_come;               // its words still to arrive in the FIFO (for dreq0)
	reg [5:0]  tix;                   // table upload index (words)
	reg        tcol;                  // the quant upload has the chroma table too
	// The tables are kept a word as it came per entry -- four quant bytes, two scale halves --
	// so each upload is ONE write: written four (two) entries a clock, synthesis built them in
	// flip-flops (1,900 of them, and the console stopped fitting the chip).
	reg [31:0] qtw [0:31];            // quant bytes, luma 0-63 then chroma 64-127 (by zigzag index), four a word
	reg [25:0] scw [0:31];            // the scale table >> 3, [f*8 + p], two a word
	wire       mono = !depth[1];

	// --- the block being read in ---------------------------------------------------------------
	reg        dc_next;               // the next halfword is a DC (or padding)
	reg [6:0]  k;                     // the coefficient's zigzag index
	reg [5:0]  qs;                    // q_scale
	reg [2:0]  blk;                   // colour: 0 Cr 1 Cb 2-5 Y1-Y4
	reg [14:0] coef [0:63];           // the IDCT's input, by matrix position
	reg [63:0] cval;                  // which coefficients were written (the rest are 0)
	// a column u of the coefficients with nothing in it (most of a movie's): pass 1 gives zeros for
	// it, so it is passed over in a clock and pass 2 reads its t[y][u] as 0
	wire [7:0] cnz;
	genvar gu;
	generate for (gu = 0; gu < 8; gu = gu + 1) begin : g_cnz
		assign cnz[gu] = cval[gu] | cval[8+gu] | cval[16+gu] | cval[24+gu] | cval[32+gu] | cval[40+gu] | cval[48+gu] | cval[56+gu];
	end endgenerate
	reg [7:0]  tnz;                   // pass 1's columns that were worked out
	reg [15:0] hw;                    // the halfword in hand
	reg        hw_hi;                 // the word's high half is next
	reg [15:0] hw_next;               // that high half

	function [5:0] zz; input [5:0] i;   // zigzag index -> matrix position
		case (i)
		6'd0: zz=0; 6'd1: zz=1; 6'd2: zz=8; 6'd3: zz=16; 6'd4: zz=9; 6'd5: zz=2; 6'd6: zz=3; 6'd7: zz=10;
		6'd8: zz=17; 6'd9: zz=24; 6'd10: zz=32; 6'd11: zz=25; 6'd12: zz=18; 6'd13: zz=11; 6'd14: zz=4; 6'd15: zz=5;
		6'd16: zz=12; 6'd17: zz=19; 6'd18: zz=26; 6'd19: zz=33; 6'd20: zz=40; 6'd21: zz=48; 6'd22: zz=41; 6'd23: zz=34;
		6'd24: zz=27; 6'd25: zz=20; 6'd26: zz=13; 6'd27: zz=6; 6'd28: zz=7; 6'd29: zz=14; 6'd30: zz=21; 6'd31: zz=28;
		6'd32: zz=35; 6'd33: zz=42; 6'd34: zz=49; 6'd35: zz=56; 6'd36: zz=57; 6'd37: zz=50; 6'd38: zz=43; 6'd39: zz=36;
		6'd40: zz=29; 6'd41: zz=22; 6'd42: zz=15; 6'd43: zz=23; 6'd44: zz=30; 6'd45: zz=37; 6'd46: zz=44; 6'd47: zz=51;
		6'd48: zz=58; 6'd49: zz=59; 6'd50: zz=52; 6'd51: zz=45; 6'd52: zz=38; 6'd53: zz=31; 6'd54: zz=39; 6'd55: zz=46;
		6'd56: zz=53; 6'd57: zz=60; 6'd58: zz=61; 6'd59: zz=54; 6'd60: zz=47; 6'd61: zz=55; 6'd62: zz=62; default: zz=63;
		endcase
	endfunction

	// --- the macroblock: Cr 0-63, Cb 64-127, Y 128-383 (16x16 row-major); mono: Y in 0-63 --------
	(* ram_style = "distributed" *) reg [7:0] mb [0:383];

	// --- the IDCT -------------------------------------------------------------------------------
	reg [15:0] tt [0:63];             // pass 1's results: [y*8 + u]

	// --- the state machine ----------------------------------------------------------------------
	localparam S_IDLE = 4'd0, S_CMD = 4'd1, S_TBL = 4'd2, S_WORD = 4'd3, S_HALF = 4'd4, S_DQ = 4'd5,
	           S_P1 = 4'd6, S_P1W = 4'd7, S_P2 = 4'd8, S_P2W = 4'd9, S_BEND = 4'd10, S_COL = 4'd11,
	           S_MONO = 4'd12, S_COLW = 4'd13, S_DQ1 = 4'd14, S_DQ2 = 4'd15;
	reg [3:0]  st;
	reg [2:0]  i_a, i_b;              // IDCT: the output index pair (u / y, then y / x)
	reg [2:0]  i_k;                   // and the sum's term
	wire [25:0] sc_w = scw[{i_k, i_b[2:1]}];
	wire [12:0] sc_q = i_b[0] ? sc_w[25:13] : sc_w[12:0];   // sc[{i_k, i_b}]
	// Two sums at once: the scale table holds two neighbouring entries a word (M[k][b], M[k][b+1]),
	// so one coefficient times both gives the outputs b and b+1 together -- ~700 clocks a block
	// where one multiply a clock took ~1100. DuckStation takes 448 CPU clocks (13 us) a block; at
	// 1100 of ours (22 us) Syphon Filter's player wrote its next frame over input DMA0 had not yet
	// read, and the MDEC put out a frame short.
	reg signed [31:0] acc, acc1;
	reg        mac_v; reg signed [15:0] mac_c; reg signed [12:0] mac_m, mac_m1;
	reg        w2;                    // the second of the pair is written next
	reg        last_term;
	reg [8:0]  cp;                    // colour / mono output: the pixel
	reg [1:0]  pk;                    // 24-bit packing: bytes in hand
	reg [23:0] pb;                    // the bytes in hand
	reg [31:0] ow_d; reg ow_v;        // a word for the out FIFO (one a clock at most)

	// dequantisation: the coefficient at k from level (10-bit signed)
	reg signed [9:0]  dq_lvl; reg [5:0] dq_k;
	wire [6:0]  dq_qi  = {(mono || blk >= 3'd2) ? 1'b0 : 1'b1, dq_k};
	wire [31:0] dq_qw  = qtw[dq_qi[6:2]];
	wire [7:0]  dq_qt  = dq_qw[8 * dq_qi[1:0] +: 8];
	// Three clocks, S_DQ1 -> S_DQ2 -> S_DQ: in one, the table read, both multiplies and the
	// rounding were 25 levels and 20.9 ns, the worst path in the console (it failed 52.6 MHz
	// by 2.4 ns). dq_lvl, dq_k, qs and blk hold still through all three.
	wire [13:0] dq_q_w = (dq_k == 6'd0) ? {6'd0, dq_qt} : dq_qt * qs;
	reg  [13:0] dq_q;                                      // S_DQ1: the quant step
	reg  signed [24:0] dq_p0;                              // S_DQ2: times the level
	wire signed [24:0] dq_p  = (dq_k == 6'd0) ? dq_p0 : (dq_p0 >>> 3);
	wire signed [29:0] dq_c0 = (dq_q == 14'd0) ? $signed({dq_lvl, 5'd0})
	                         : (dq_lvl > 0) ? ((dq_p <<< 4) - 30'sd8) : (dq_lvl < 0) ? ((dq_p <<< 4) + 30'sd8) : 30'sd0;
	wire [14:0] dq_c   = (dq_c0 < -30'sd16384) ? 15'h4000 : (dq_c0 > 30'sd16383) ? 15'h3FFF : dq_c0[14:0];

	// a signed sum's low 9 bits as signed, clamped to a byte
	function [7:0] wclamp; input [8:0] v;
		wclamp = (v[8] && v[7:0] < 8'h80) ? 8'h80 : (!v[8] && v[7]) ? 8'h7F : v[7:0];
	endfunction

	// colour conversion of the pixel cp -- in block order: Y1..Y4, 8 x 8 each -- from the
	// row-major 16x16: row {block[1], r}, column {block[0], x}
	wire [7:0] cpr  = {cp[7], cp[5:3], cp[6], cp[2:0]};
	wire [7:0] c_y  = mb[9'd128 + {1'b0, cpr}];
	wire [5:0] c_ci = {cpr[7:5], cpr[3:1]};               // (y >> 1) * 8 + (x >> 1)
	wire signed [7:0] c_cr = mb[{3'd0, c_ci}];
	wire signed [7:0] c_cb = mb[9'd64 + {3'd0, c_ci}];
	wire signed [17:0] m_r  = 18'sd359 * c_cr + 18'sd128;
	wire signed [17:0] m_gb = (-18'sd88 * c_cb) & ~18'sh1F;
	wire signed [17:0] m_gr = (-18'sd183 * c_cr) & ~18'sh07;
	wire signed [17:0] m_g  = m_gb + m_gr + 18'sd128;
	wire signed [17:0] m_b  = 18'sd454 * c_cb + 18'sd128;
	wire signed [9:0]  c_y9 = {{2{c_y[7]}}, c_y};
	wire [7:0] px_r = wclamp(c_y9 + m_r[17:8]);
	wire [7:0] px_g = wclamp(c_y9 + m_g[17:8]);
	wire [7:0] px_b = wclamp(c_y9 + m_b[17:8]);
	// the unsigned / signed bytes and the 15-bit pixel
	function [7:0] ub; input [7:0] v; input s; ub = s ? v : v ^ 8'h80; endfunction
	function [4:0] c5; input [7:0] u; reg [8:0] t; begin t = {1'b0, u} + 9'd4; c5 = (t[8:3] > 6'd31) ? 5'd31 : t[7:3]; end endfunction
	wire [7:0] u_r = px_r ^ 8'h80, u_g = px_g ^ 8'h80, u_b = px_b ^ 8'h80;
	// 15-bit: from the sum with the colour term's fraction still in it, rounded once to five
	// bits. Rounded to a byte first and then to five, a byte ending in 100b went up every time;
	// the console's goes either way by what was below it. Measured offline against ps1-tests
	// mdec/frame's own picture: 15,777 pixels off by a step -> 8,358 (the rest is the IDCT).
	wire signed [18:0] f_y  = {{3{c_y[7]}}, c_y, 8'd0};
	wire signed [18:0] f_r  = f_y + (19'sd359 * c_cr);
	wire signed [18:0] f_g  = f_y + ((-19'sd88 * c_cb) & ~19'sh1F) + ((-19'sd183 * c_cr) & ~19'sh07);
	wire signed [18:0] f_b  = f_y + (19'sd454 * c_cb);
	function [4:0] f5; input signed [18:0] v; reg signed [19:0] u; begin
		u  = {v[18], v} + 20'sh08400;                  // + 128 (unsigned) and half a step, in 1/256ths
		f5 = u[19] ? 5'd0 : (u[18:11] > 8'd31) ? 5'd31 : u[15:11];
	end endfunction
	wire [15:0] px15 = {b15, f5(f_b), f5(f_g), f5(f_r)} ^ (sgn ? 16'h4210 : 16'h0000);
	reg [15:0] px15_lo;

	// mono: the pixel cp of the block in mb[0..63]
	wire [7:0] m_y  = mb[{3'd0, cp[5:0]}];
	wire [7:0] m_n4 = ($signed(m_y) > 8'sd119) ? 8'd127 : m_y + 8'd8;   // min(127, y + 8)
	wire [3:0] m_nib = m_n4[7:4] ^ (sgn ? 4'h0 : 4'h8);
	reg [27:0] mono_w;

	// the status
	reg busy;
	assign rd_stall = (ocnt == 6'd0) && busy;
	assign out_depth = depth;
	wire       want_more = (kind != 2'd0) && (to_come != 16'd0);
	assign dreq0 = en_in && want_more && icnt <= 9'd224;
	assign dreq1 = en_out && (ocnt >= 6'd32 || (ocnt != 6'd0 && !busy));
	assign dbg_stat = {ocnt == 6'd0, icnt == 9'd256, busy, dreq0, dreq1, depth, sgn, b15, 4'd0,
		              mono ? 3'd4 : (blk < 3'd2 ? {2'b10, blk[0]} : {1'b0, blk[1:0] - 2'd2}),
		              (kind == 2'd1) ? left - 16'd1 : (kind != 2'd0 ? left : 16'hFFFF)};
	always @(*) begin
		if (!a2) rdata = (ocnt != 6'd0) ? ofifo[orr] : 32'hFFFFFFFF;
		else rdata = {ocnt == 6'd0, icnt == 9'd256, busy, dreq0, dreq1, depth, sgn, b15, 4'd0,
		              mono ? 3'd4 : (blk < 3'd2 ? {2'b10, blk[0]} : {1'b0, blk[1:0] - 2'd2}),
		              (kind == 2'd1) ? left - 16'd1 : (kind != 2'd0 ? left : 16'hFFFF)};
	end

	// (debug) words in and out per decode command: Syphon Filter's player waited for 12 macroblocks
	// of a frame that never came out -- lost going in, or coming out?
	reg [15:0] cn_in, cn_out; reg [31:0] cn_log [0:7]; reg [2:0] cn_wp; reg [15:0] cn_cmd; reg [12:0] cn_drop;
	always @(posedge clk) begin
		if (rst) begin cn_in <= 16'd0; cn_out <= 16'd0; cn_wp <= 3'd0; cn_drop <= 13'd0; end
		else begin
			if (st == S_IDLE && icnt != 9'd0 && ififo[ir][31:29] == 3'd1) begin
				cn_log[cn_wp] <= {cn_in, cn_out}; cn_wp <= cn_wp + 3'd1;
				cn_in <= 16'd0; cn_out <= 16'd0; cn_cmd <= ififo[ir][15:0];
			end else begin
				if (push && icnt != 9'd256) cn_in <= cn_in + 16'd1;
				if ((cpu_pop || out_rd) && ocnt != 6'd0) cn_out <= cn_out + 16'd1;
			end
			if (push && icnt == 9'd256) cn_drop <= cn_drop + 13'd1;   // (a word pushed into a full FIFO: lost)
		end
		dbg_cnt <= (dbg_idx == 3'd0) ? {cn_in, cn_out} : (dbg_idx == 3'd1) ? {cn_cmd, cn_drop, cn_wp} : cn_log[cn_wp - dbg_idx + 3'd1];
	end
	integer n;
	always @(posedge clk) begin
		// --- the FIFOs' pushes and pops (the engine's below) --------------------------------------
		if (push && icnt != 9'd256) begin ififo[iw] <= push_d; iw <= iw + 8'd1; end
		if ((cpu_pop || out_rd) && ocnt != 6'd0) orr <= orr + 5'd1;
		if (ow_v) begin ofifo[ow] <= ow_d; ow <= ow + 5'd1; end
		ocnt <= ocnt + (ow_v ? 6'd1 : 6'd0) - (((cpu_pop || out_rd) && ocnt != 6'd0) ? 6'd1 : 6'd0);
		ow_v <= 1'b0;
		if (push && icnt != 9'd256 && to_come != 16'd0) to_come <= to_come - 16'd1;

		// --- the control register -----------------------------------------------------------------
		if (sel && we && a2) begin
			en_in <= wdata[30]; en_out <= wdata[29];
		end

		mac_v <= 1'b0;
		if (mac_v) begin acc <= acc + mac_c * mac_m; acc1 <= acc1 + mac_c * mac_m1; end

		begin : eng
			reg pop_in;
			pop_in = 1'b0;
			case (st)
			S_IDLE: if (icnt != 9'd0) begin
					pop_in = 1'b1;
					depth <= ififo[ir][28:27]; sgn <= ififo[ir][26]; b15 <= ififo[ir][25];
					case (ififo[ir][31:29])
					3'd1: if (ififo[ir][15:0] != 16'd0) begin
					            kind <= 2'd1; left <= ififo[ir][15:0]; to_come <= ({7'd0, icnt} - 16'd1 >= ififo[ir][15:0]) ? 16'd0 : ififo[ir][15:0] - ({7'd0, icnt} - 16'd1);
					            dc_next <= 1'b1; blk <= 3'd0; busy <= 1'b1; st <= S_WORD; end
					3'd2: begin kind <= 2'd2; left <= ififo[ir][0] ? 16'd32 : 16'd16; tcol <= ififo[ir][0];
					            to_come <= ({7'd0, icnt} - 16'd1 >= (ififo[ir][0] ? 16'd32 : 16'd16)) ? 16'd0 : (ififo[ir][0] ? 16'd32 : 16'd16) - ({7'd0, icnt} - 16'd1); tix <= 6'd0; busy <= 1'b1; st <= S_TBL; end
					3'd3: begin kind <= 2'd3; left <= 16'd32; to_come <= ({7'd0, icnt} - 16'd1 >= 16'd32) ? 16'd0 : 16'd32 - ({7'd0, icnt} - 16'd1); tix <= 6'd0; busy <= 1'b1; st <= S_TBL; end
					default: ;            // no function: the word is taken, nothing else
					endcase
				end
			// a table's words
			S_TBL: if (left == 16'd0) begin kind <= 2'd0; busy <= 1'b0; st <= S_IDLE; end
				else if (icnt != 9'd0) begin
					pop_in = 1'b1;
					if (kind == 2'd2) qtw[tix[4:0]] <= ififo[ir];
					else              scw[tix[4:0]] <= {ififo[ir][31:19], ififo[ir][15:3]};
					tix <= tix + 6'd1;
					left <= left - 16'd1;
				end
			// decoding: the next word's two halfwords
			S_WORD: if (left == 16'd0) begin
					// the command's words are all taken (the block in hand is dropped)
					kind <= 2'd0; busy <= 1'b0; st <= S_IDLE;
				end else if (icnt != 9'd0) begin
					pop_in = 1'b1;
					left <= left - 16'd1;
					hw <= ififo[ir][15:0]; hw_next <= ififo[ir][31:16];
					hw_hi <= 1'b1;
					st <= S_HALF;
				end
			S_HALF: begin
					// a halfword: a DC (or padding), or an AC
					if (dc_next) begin
						if (hw != 16'hFE00) begin
							qs <= hw[15:10]; cval <= 64'd0;
							dq_lvl <= hw[9:0]; dq_k <= 6'd0; k <= 7'd0;
							dc_next <= 1'b0;
							st <= S_DQ1;
						end else st <= S_BEND;          // (padding: on to the next halfword)
					end else begin
						if ({1'b0, k} + {2'b0, hw[15:10]} + 8'd1 <= 8'd63) begin
							k <= k + {1'b0, hw[15:10]} + 7'd1;
							dq_lvl <= hw[9:0]; dq_k <= k[5:0] + hw[15:10] + 6'd1;
							st <= S_DQ1;
						end else begin
							// past 63: the block is done (the level is dropped)
							k <= 7'd64;
							i_a <= 3'd0; i_b <= 3'd0; i_k <= 3'd0; acc <= 32'sd0; acc1 <= 32'sd0; w2 <= 1'b0; last_term <= 1'b0;
							st <= S_P1;
						end
					end
				end
			S_DQ1: begin dq_q <= dq_q_w; st <= S_DQ2; end
			S_DQ2: begin dq_p0 <= dq_lvl * $signed({1'b0, dq_q}); st <= S_DQ; end
			S_DQ: begin
					coef[zz(dq_k)] <= dq_c; cval[zz(dq_k)] <= 1'b1;
					if (dq_k == 6'd63) begin
						i_a <= 3'd0; i_b <= 3'd0; i_k <= 3'd0; acc <= 32'sd0; acc1 <= 32'sd0; w2 <= 1'b0; last_term <= 1'b0;
						st <= S_P1;
					end else st <= S_BEND;
				end
			// the next halfword: the word's high half, or a new word
			S_BEND: begin
					if (hw_hi) begin hw <= hw_next; hw_hi <= 1'b0; st <= S_HALF; end
					else st <= S_WORD;
				end
			// pass 1: t[y][u] = round(sum_v c[v][u] * M[v][y]); i_a = u, i_b = y, i_k = v
			S_P1: if (i_b == 3'd0 && i_k == 3'd0 && !cnz[i_a]) begin   // an empty column
					tnz[i_a] <= 1'b0;
					if (i_a == 3'd7) begin i_a <= 3'd0; st <= S_P2; end
					else i_a <= i_a + 3'd1;
				end else begin
					tnz[i_a] <= 1'b1;
					mac_v <= 1'b1;
					mac_c <= cval[{i_k, i_a}] ? {{1{coef[{i_k, i_a}][14]}}, coef[{i_k, i_a}]} : 16'sd0;
					mac_m <= sc_w[12:0]; mac_m1 <= sc_w[25:13];          // (i_b even: y and y+1)
					i_k <= i_k + 3'd1;
					if (i_k == 3'd7) st <= S_P1W;
				end
			S_P1W: if (!mac_v) begin
					if (!w2) begin tt[{i_b, i_a}] <= (acc + 32'sd16384) >>> 15; w2 <= 1'b1; end
					else begin
						tt[{i_b | 3'd1, i_a}] <= (acc1 + 32'sd16384) >>> 15;
						w2 <= 1'b0; acc <= 32'sd0; acc1 <= 32'sd0;
						if (i_b == 3'd6) begin
							i_b <= 3'd0;
							if (i_a == 3'd7) begin i_a <= 3'd0; st <= S_P2; end
							else begin i_a <= i_a + 3'd1; st <= S_P1; end
						end else begin i_b <= i_b + 3'd2; st <= S_P1; end
					end
				end
			// pass 2: s[y][x] = round(sum_u t[y][u] * M[u][x]); i_a = y, i_b = x, i_k = u
			S_P2: begin
					mac_v <= 1'b1;
					mac_c <= tnz[i_k] ? tt[{i_a, i_k}] : 16'sd0;
					mac_m <= sc_w[12:0]; mac_m1 <= sc_w[25:13];          // (x and x+1)
					i_k <= i_k + 3'd1;
					if (i_k == 3'd7) st <= S_P2W;
				end
			S_P2W: if (!mac_v) begin : p2w
					reg [31:0] s; reg [8:0] base; reg [2:0] xb;
					s  = ((w2 ? acc1 : acc) + 32'sd16384) >>> 15;
					xb = w2 ? (i_b | 3'd1) : i_b;
					// where the block's pixel goes: mono 0-63, Cr 0-63, Cb 64-127, Y in the 16x16 at 128
					if (mono) base = 9'd0;
					else if (blk == 3'd0) base = 9'd0;
					else if (blk == 3'd1) base = 9'd64;
					else base = 9'd128;
					// (Y1 top left, Y2 top right, Y3 bottom left, Y4 bottom right: blk 2-5, so the
					// bottom half is blk[2] and the right half blk[0])
					if (mono || blk < 3'd2) mb[base + {3'd0, i_a, xb}] <= wclamp(s[8:0]);
					else mb[9'd128 + {1'b0, blk[2], i_a, blk[0], xb}] <= wclamp(s[8:0]);
					w2 <= !w2;
					if (!w2) ;                                            // (the pair's second next clock)
					else if (i_b == 3'd6) begin
						acc <= 32'sd0; acc1 <= 32'sd0;
						i_b <= 3'd0;
						if (i_a == 3'd7) begin
							i_a <= 3'd0;
							// the block is done
							dc_next <= 1'b1;
							if (mono) begin cp <= 9'd0; mono_w <= 28'd0; st <= S_MONO; end
							else if (blk == 3'd5) begin blk <= 3'd0; cp <= 9'd0; pk <= 2'd0; st <= S_COL; end
							else begin blk <= blk + 3'd1; st <= (k == 7'd63) ? S_BEND : S_BEND; end
						end else begin i_a <= i_a + 3'd1; st <= S_P2; end
					end else begin i_b <= i_b + 3'd2; st <= S_P2; acc <= 32'sd0; acc1 <= 32'sd0; end
				end
			// a colour macroblock out, row-major: 15-bit two pixels a word, 24-bit three bytes each
			// (a word out only when the FIFO, with the one already on its way, has room)
			S_COL: if (ocnt + {5'd0, ow_v} <= 6'd31) begin
					cp <= cp + 9'd1;
					if (depth == 2'd3) begin
						if (!cp[0]) px15_lo <= px15;
						else begin ow_v <= 1'b1; ow_d <= {px15, px15_lo}; end
					end else begin
						// in hand: pk bytes in pb (the oldest lowest)
						case (pk)
						2'd0: begin pb <= {ub(px_b, sgn), ub(px_g, sgn), ub(px_r, sgn)}; pk <= 2'd3; end
						2'd1: begin ow_v <= 1'b1; ow_d <= {ub(px_b, sgn), ub(px_g, sgn), ub(px_r, sgn), pb[7:0]}; pk <= 2'd0; end
						2'd2: begin ow_v <= 1'b1; ow_d <= {ub(px_g, sgn), ub(px_r, sgn), pb[15:0]}; pb <= {16'd0, ub(px_b, sgn)}; pk <= 2'd1; end
						default: begin ow_v <= 1'b1; ow_d <= {ub(px_r, sgn), pb[23:0]}; pb <= {8'd0, ub(px_b, sgn), ub(px_g, sgn)}; pk <= 2'd2; end
						endcase
					end
					if (cp == 9'd255) st <= S_COLW;
				end
			S_COLW: st <= S_BEND;
			// a mono block out: 8-bit four a word, 4-bit eight
			S_MONO: if (ocnt + {5'd0, ow_v} <= 6'd31) begin
					cp <= cp + 9'd1;
					if (depth == 2'd1) begin
						if (cp[1:0] == 2'd3) begin ow_v <= 1'b1; ow_d <= {ub(m_y, sgn), mono_w[23:0]}; end
						else mono_w[8 * cp[1:0] +: 8] <= ub(m_y, sgn);
					end else begin
						if (cp[2:0] == 3'd7) begin ow_v <= 1'b1; ow_d <= {m_nib, mono_w}; end
						else mono_w[4 * cp[2:0] +: 4] <= m_nib;
					end
					if (cp == 9'd63) st <= S_BEND;
				end
			default: st <= S_IDLE;
			endcase
			if (pop_in) ir <= ir + 8'd1;
			icnt <= icnt + ((push && icnt != 9'd256) ? 9'd1 : 9'd0) - (pop_in ? 9'd1 : 9'd0);
		end

		// --- reset: a write of bit 31 of 1824h (the tables stay) -----------------------------------
		if (rst || (sel && we && a2 && wdata[31])) begin
			iw <= 8'd0; ir <= 8'd0; icnt <= 9'd0; ow <= 5'd0; orr <= 5'd0; ocnt <= 6'd0; ow_v <= 1'b0;
			kind <= 2'd0; left <= 16'd0; to_come <= 16'd0; busy <= 1'b0; st <= S_IDLE; blk <= 3'd0;
			dc_next <= 1'b1; mac_v <= 1'b0; depth <= 2'd0; sgn <= 1'b0; b15 <= 1'b0;
			if (rst) begin en_in <= 1'b0; en_out <= 1'b0; end
		end
	end
endmodule

`default_nettype wire
