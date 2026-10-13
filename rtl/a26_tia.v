//////////////////////////////////////////////////////////////////////////////////
// a26_tia.v - the Atari 2600's Television Interface Adaptor, NTSC.
//
// Written from the Stella Programmer's Guide (register map and behaviour), Andrew
// Towers' "TIA hardware notes" (the counters, the motion rules, the delays) and
// the 6507/TIA timing everyone who has written a kernel knows: 228 colour clocks
// a line, 68 of them horizontal blank, three colour clocks to a processor cycle.
//
// What a line looks like, in colour clocks (hcount):
//
//     0 ........ 67 | 68 ........................ 227
//     horizontal blank | 160 visible pixels (px_x 0..159)
//
// An HMOVE in the blank stretches it to 75: the 8 black pixels at the left that
// every player of the console has seen. The objects miss their 8 clocks there and
// the motion sequence hands them (HMxx ^ 8) extra ones, which is how a motion
// register of 0 moves nothing, +7 moves left 7 and -8 moves right 8.
//
// Each movable object has a position counter that runs only while the line is
// visible (it is what makes positions stick from line to line: 160 steps and a
// 228-clock line period). RESxx zeroes it; the object's first pixel comes out when
// the counter reads 5 (players) or 4 (missiles, ball) -- the pipeline delays of the
// real chip, and the reason a RESP0 in horizontal blank puts a player at pixel 3
// while a mid-line one puts it 5 clocks after the write. The classic divide-by-15
// positioning loop lands exactly where the published tables say because of this.
//
// Register writes take effect at the processor's cycle edge (cpu_ce), which is
// the third colour clock of the cycle. All object and playfield pixels are
// generated in the same clock, so the output has no skew between them.
//
// Audio is the two channels' polynomial counters as the programmer's guide
// documents them (4-, 5- and 9-bit polynomials, the pure-tone dividers), ticked
// twice a line; the divide-by-15 / 31 / 93 modes are built as plain dividers of
// the same period rather than as decodes of the 5-bit polynomial's state.
//
// Not here (follow-ups): PAL/SECAM timing, the odd phase effects of RESxx or
// HMOVE landing during an object's own pixels, the HMOVE + HMxx-write-during-
// motion quirks beyond what the counter model gives for free.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module a26_tia (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,          // one colour clock (3.579545 MHz)
	input  wire        cpu_ce,      // the processor's cycle edge: every third ce

	// the 6507 bus. cs is "A12 low, A7 low"; the TIA decodes A5..A0.
	input  wire        cs,
	input  wire [5:0]  addr,
	input  wire        we,
	input  wire [7:0]  din,
	output reg  [7:0]  dout,
	output reg         rdy,         // low from a WSYNC write to the start of the next line

	// INPT0..5 pin levels: 0-3 the paddle/booster inputs (1 = charged), 4-5 the
	// fire buttons (0 = pressed).
	input  wire [5:0]  inpt,

	// video: the 160 visible pixels of every line, blank lines excepted
	output wire [7:0]  px_x,        // 0..159
	output reg  [8:0]  line,        // lines since VSYNC went high
	output wire [6:0]  color,       // the NTSC colour/luminance byte, bits 7:1
	output wire        pixel_en,    // a visible pixel: not blanked, not VBLANK/VSYNC
	output reg         frame_start, // one clock when VSYNC is asserted
	output wire        line_end,    // one clock at the end of every 228-clock line
	output wire        vsync_o,
	output wire        vblank_o,

	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r
);

	// --- the horizontal counter ----------------------------------------------
	reg [7:0] hcount;
	wire      wrap = (hcount == 8'd227);
	assign    line_end = ce && wrap;

	// --- registers -----------------------------------------------------------
	reg       vsync, vblank, inpt_latch_en, inpt_dump;
	reg [5:0] nusiz0, nusiz1;
	reg [6:0] colup0, colup1, colupf, colubk;
	reg [5:0] ctrlpf;              // 0 reflect, 1 score, 2 priority, 5:4 ball size
	reg       refp0, refp1;
	reg [3:0] pf0;                 // PF0 bits 7:4, pixel order 4,5,6,7
	reg [7:0] pf1, pf2;
	reg [7:0] grp0, grp1, grp0_old, grp1_old;
	reg       enam0, enam1, enabl, enabl_old;
	reg [3:0] hmp0, hmp1, hmm0, hmm1, hmbl;
	reg       vdelp0, vdelp1, vdelbl;
	reg       resmp0, resmp1;
	reg [3:0] audc0, audc1, audv0, audv1;
	reg [4:0] audf0, audf1;

	// object position counters, 0..159
	reg [7:0] pos_p0, pos_p1, pos_m0, pos_m1, pos_bl;

	// horizontal motion
	reg       hmove_lat;           // set by HMOVE, cleared when its 16 ticks are done
	reg       hm_run;
	reg [3:0] hm_cnt;
	reg       mov_p0, mov_p1, mov_m0, mov_m1, mov_bl;

	// horizontal blank and its HMOVE extension
	reg       hblank;
	reg       hb_late;             // this line's blank runs to clock 75

	// collision latches
	reg cx_m0p1, cx_m0p0, cx_m1p0, cx_m1p1, cx_p0pf, cx_p0bl, cx_p1pf, cx_p1bl;
	reg cx_m0pf, cx_m0bl, cx_m1pf, cx_m1bl, cx_blpf, cx_p0p1, cx_m0m1;

	// fire button latches (VBLANK bit 6)
	reg inpt4_l, inpt5_l;

	wire wr = cpu_ce && cs && we;

	// --- the processor's view --------------------------------------------------
	// The TIA drives only D7 and D6. The other six float, and on the console they
	// hold what the data bus last carried -- the operand byte of the instruction
	// doing the read, i.e. the register's own address. Games that test with BIT
	// or BPL/BMI never see them; a few that compare the whole byte do.
	always @* begin
		case (addr[3:0])
		4'h0: dout = {cx_m0p1, cx_m0p0, addr};
		4'h1: dout = {cx_m1p0, cx_m1p1, addr};
		4'h2: dout = {cx_p0pf, cx_p0bl, addr};
		4'h3: dout = {cx_p1pf, cx_p1bl, addr};
		4'h4: dout = {cx_m0pf, cx_m0bl, addr};
		4'h5: dout = {cx_m1pf, cx_m1bl, addr};
		4'h6: dout = {cx_blpf, 1'b0,   addr};
		4'h7: dout = {cx_p0p1, cx_m0m1, addr};
		4'h8: dout = {inpt_dump ? 1'b0 : inpt[0], 1'b0, addr};
		4'h9: dout = {inpt_dump ? 1'b0 : inpt[1], 1'b0, addr};
		4'hA: dout = {inpt_dump ? 1'b0 : inpt[2], 1'b0, addr};
		4'hB: dout = {inpt_dump ? 1'b0 : inpt[3], 1'b0, addr};
		4'hC: dout = {inpt_latch_en ? inpt4_l : inpt[4], 1'b0, addr};
		4'hD: dout = {inpt_latch_en ? inpt5_l : inpt[5], 1'b0, addr};
		default: dout = {2'b00, addr};
		endcase
	end

	// --- object clocks ------------------------------------------------------------
	// The position counters step on the clock edges that end colour clocks 66 to
	// 225: 160 of them. Starting two clocks before the picture is what the chip
	// does (it is why a RESxx in horizontal blank gives pixel 3, not 5), and it
	// costs nothing because the first pixel is pipelined 4 or 5 clocks anyway.
	// With the blank extended by HMOVE the first 8 of those edges are skipped.
	wire oclk_window = (hcount >= 8'd66) && (hcount <= 8'd225);
	wire oclk_normal = ce && oclk_window && !(hb_late && hcount < 8'd74);

	// a motion tick every fourth colour clock while the sequence runs
	wire hm_tick = ce && hm_run && (hcount[1:0] == 2'b11);
	wire ext_p0 = hm_tick && mov_p0 && (hm_cnt != (hmp0 ^ 4'h8));
	wire ext_p1 = hm_tick && mov_p1 && (hm_cnt != (hmp1 ^ 4'h8));
	wire ext_m0 = hm_tick && mov_m0 && (hm_cnt != (hmm0 ^ 4'h8));
	wire ext_m1 = hm_tick && mov_m1 && (hm_cnt != (hmm1 ^ 4'h8));
	wire ext_bl = hm_tick && mov_bl && (hm_cnt != (hmbl ^ 4'h8));

	// one counter step, wrapping at 160; two when a motion tick lands on a
	// running clock (a mid-line HMOVE), as the OR of the two pulse trains does
	function [7:0] step160;
		input [7:0] p;
		input       a;
		input       b;
		reg   [8:0] s;
		begin
			s = {1'b0, p} + {8'd0, a} + {8'd0, b};
			step160 = (s >= 9'd160) ? s[7:0] - 8'd160 : s[7:0];
		end
	endfunction

	// where a missile sits when RESMPx parks it on its player: the centre, which
	// for the three player sizes is 3, 6 and 10 pixels in. Missiles pipeline one
	// clock less than players, hence the +2/+5/+9 on the counter.
	function [7:0] park;
		input [7:0] p;
		input [2:0] size;
		reg   [8:0] s;
		begin
			case (size)
			3'd5:    s = {1'b0, p} + 9'd5;
			3'd7:    s = {1'b0, p} + 9'd9;
			default: s = {1'b0, p} + 9'd2;
			endcase
			park = (s >= 9'd160) ? s[7:0] - 8'd160 : s[7:0];
		end
	endfunction

	// --- pixel generation ----------------------------------------------------------
	assign px_x = hcount - 8'd68;
	wire visible = !hblank && (hcount >= 8'd68);

	// playfield: 20 bits across the left half at 4 clocks each, repeated or
	// mirrored on the right
	wire [5:0] pf_q = px_x[7:2];                           // 0..39 across the line
	wire [5:0] pf_r = ctrlpf[0] ? (6'd19 - (pf_q - 6'd20)) : (pf_q - 6'd20);
	wire [5:0] pf_i = (px_x < 8'd80) ? pf_q : pf_r;       // 0..19: the playfield bit
	wire [5:0] pf_1 = 6'd11 - pf_i;                        // PF1 is stored high bit first
	wire [5:0] pf_2 = pf_i - 6'd12;
	reg        pf_bit;
	always @* begin
		if (pf_i < 6'd4)        pf_bit = pf0[pf_i[1:0]];
		else if (pf_i < 6'd12)  pf_bit = pf1[pf_1[2:0]];
		else                    pf_bit = pf2[pf_2[2:0]];
	end

	// a player's pixel: the scan position relative to each copy, divided by the
	// size, picks a bit of the graphics byte. Double and quad sized players start
	// one and two clocks later than a single: their scan counter runs from the
	// divided clock.
	function player_pix;
		input [7:0] pos;
		input [2:0] nusiz;
		input [7:0] grp;
		input       refl;
		reg   [8:0] d0, d1, d2, d3;
		reg   [8:0] width;
		reg   [8:0] d;
		reg         hit;
		reg   [2:0] idx;
		begin
			case (nusiz)
			3'd5:    begin width = 9'd16; d0 = {1'b0, pos} + 9'd160 - 9'd6; end
			3'd7:    begin width = 9'd32; d0 = {1'b0, pos} + 9'd160 - 9'd7; end
			default: begin width = 9'd8;  d0 = {1'b0, pos} + 9'd160 - 9'd5; end
			endcase
			if (d0 >= 9'd160) d0 = d0 - 9'd160;
			d1 = (d0 >= 9'd16) ? d0 - 9'd16 : d0 + 9'd144;   // the copy 16 clocks on
			d2 = (d0 >= 9'd32) ? d0 - 9'd32 : d0 + 9'd128;   // 32
			d3 = (d0 >= 9'd64) ? d0 - 9'd64 : d0 + 9'd96;    // 64
			hit = 1'b0; d = d0;
			if (d0 < width) begin hit = 1'b1; d = d0; end
			else case (nusiz)
				3'd1: if (d1 < width) begin hit = 1'b1; d = d1; end
				3'd2: if (d2 < width) begin hit = 1'b1; d = d2; end
				3'd3: if (d1 < width) begin hit = 1'b1; d = d1; end
				      else if (d2 < width) begin hit = 1'b1; d = d2; end
				3'd4: if (d3 < width) begin hit = 1'b1; d = d3; end
				3'd6: if (d2 < width) begin hit = 1'b1; d = d2; end
				      else if (d3 < width) begin hit = 1'b1; d = d3; end
				default: ;
			endcase
			case (nusiz)
			3'd5:    idx = d[3:1];
			3'd7:    idx = d[4:2];
			default: idx = d[2:0];
			endcase
			player_pix = hit && (refl ? grp[idx] : grp[3'd7 - idx]);
		end
	endfunction

	// a missile's pixel: the same copies as its player, 1/2/4/8 clocks wide
	function missile_pix;
		input [7:0] pos;
		input [5:0] nusiz;
		reg   [8:0] d0, d1, d2, d3;
		reg   [8:0] width;
		reg         hit;
		begin
			width = 9'd1 << nusiz[5:4];
			d0 = {1'b0, pos} + 9'd160 - 9'd4;
			if (d0 >= 9'd160) d0 = d0 - 9'd160;
			d1 = (d0 >= 9'd16) ? d0 - 9'd16 : d0 + 9'd144;
			d2 = (d0 >= 9'd32) ? d0 - 9'd32 : d0 + 9'd128;
			d3 = (d0 >= 9'd64) ? d0 - 9'd64 : d0 + 9'd96;
			hit = (d0 < width);
			case (nusiz[2:0])
			3'd1: hit = hit || (d1 < width);
			3'd2: hit = hit || (d2 < width);
			3'd3: hit = hit || (d1 < width) || (d2 < width);
			3'd4: hit = hit || (d3 < width);
			3'd6: hit = hit || (d2 < width) || (d3 < width);
			default: ;
			endcase
			missile_pix = hit;
		end
	endfunction

	wire [7:0] grp0_eff  = vdelp0 ? grp0_old : grp0;
	wire [7:0] grp1_eff  = vdelp1 ? grp1_old : grp1;
	wire       enabl_eff = vdelbl ? enabl_old : enabl;

	wire p0_pix = player_pix(pos_p0, nusiz0[2:0], grp0_eff, refp0);
	wire p1_pix = player_pix(pos_p1, nusiz1[2:0], grp1_eff, refp1);
	wire m0_pix = enam0 && !resmp0 && missile_pix(pos_m0, nusiz0);
	wire m1_pix = enam1 && !resmp1 && missile_pix(pos_m1, nusiz1);

	wire [8:0] bl_d  = ({1'b0, pos_bl} + 9'd156 >= 9'd160) ? {1'b0, pos_bl} - 9'd4 : {1'b0, pos_bl} + 9'd156;
	wire [8:0] bl_w  = 9'd1 << ctrlpf[5:4];
	wire       bl_pix = enabl_eff && (bl_d < bl_w);

	// all pixels exist only in the picture; the blank gates the lot
	wire p0 = visible && p0_pix;
	wire p1 = visible && p1_pix;
	wire m0 = visible && m0_pix;
	wire m1 = visible && m1_pix;
	wire bl = visible && bl_pix;
	wire pf = visible && pf_bit;

	// colour: players over the playfield unless CTRLPF says otherwise; in score
	// mode each half of the playfield wears its player's colour
	wire [6:0] pf_col = ctrlpf[1] ? ((px_x < 8'd80) ? colup0 : colup1) : colupf;
	reg  [6:0] col;
	always @* begin
		if (!ctrlpf[2]) begin
			if (p0 || m0)      col = colup0;
			else if (p1 || m1) col = colup1;
			else if (pf)       col = pf_col;
			else if (bl)       col = colupf;
			else               col = colubk;
		end else begin
			if (pf)            col = pf_col;
			else if (bl)       col = colupf;
			else if (p0 || m0) col = colup0;
			else if (p1 || m1) col = colup1;
			else               col = colubk;
		end
	end

	// the HMOVE bar is part of the picture: black pixels, not missing ones
	wire hm_bar = hblank && (hcount >= 8'd68);
	assign color    = hm_bar ? 7'd0 : col;
	assign pixel_en = ce && (visible || hm_bar) && !vblank && !vsync;
	assign vsync_o  = vsync;
	assign vblank_o = vblank;

	// --- the sequencer -----------------------------------------------------------------
	always @(posedge clk) begin
		frame_start <= 1'b0;

		if (rst) begin
			hcount <= 8'd0; line <= 9'd0; rdy <= 1'b1;
			hblank <= 1'b1; hb_late <= 1'b0;
			vsync <= 1'b0; vblank <= 1'b0; inpt_latch_en <= 1'b0; inpt_dump <= 1'b0;
			nusiz0 <= 6'd0; nusiz1 <= 6'd0;
			colup0 <= 7'd0; colup1 <= 7'd0; colupf <= 7'd0; colubk <= 7'd0;
			ctrlpf <= 6'd0; refp0 <= 1'b0; refp1 <= 1'b0;
			pf0 <= 4'd0; pf1 <= 8'd0; pf2 <= 8'd0;
			grp0 <= 8'd0; grp1 <= 8'd0; grp0_old <= 8'd0; grp1_old <= 8'd0;
			enam0 <= 1'b0; enam1 <= 1'b0; enabl <= 1'b0; enabl_old <= 1'b0;
			hmp0 <= 4'd0; hmp1 <= 4'd0; hmm0 <= 4'd0; hmm1 <= 4'd0; hmbl <= 4'd0;
			vdelp0 <= 1'b0; vdelp1 <= 1'b0; vdelbl <= 1'b0;
			resmp0 <= 1'b0; resmp1 <= 1'b0;
			audc0 <= 4'd0; audc1 <= 4'd0; audv0 <= 4'd0; audv1 <= 4'd0;
			audf0 <= 5'd0; audf1 <= 5'd0;
			pos_p0 <= 8'd0; pos_p1 <= 8'd0; pos_m0 <= 8'd0; pos_m1 <= 8'd0; pos_bl <= 8'd0;
			hmove_lat <= 1'b0; hm_run <= 1'b0; hm_cnt <= 4'd0;
			mov_p0 <= 1'b0; mov_p1 <= 1'b0; mov_m0 <= 1'b0; mov_m1 <= 1'b0; mov_bl <= 1'b0;
			{cx_m0p1, cx_m0p0, cx_m1p0, cx_m1p1, cx_p0pf, cx_p0bl, cx_p1pf, cx_p1bl} <= 8'd0;
			{cx_m0pf, cx_m0bl, cx_m1pf, cx_m1bl, cx_blpf, cx_p0p1, cx_m0m1} <= 7'd0;
			inpt4_l <= 1'b1; inpt5_l <= 1'b1;
		end else begin
			// -- the line --
			if (ce) begin
				hcount <= wrap ? 8'd0 : hcount + 8'd1;
				if (wrap) begin
					hblank <= 1'b1;
					rdy    <= 1'b1;             // WSYNC releases at the start of the line
					line   <= line + 9'd1;
				end
				// Whether this line's blank is the long one is decided from the
				// HMOVE latch just before the objects would start clocking, and the
				// decision then holds for the blank's two possible ends.
				if (hcount == 8'd65) hb_late <= hmove_lat;
				if (hcount == 8'd67 && !hb_late) hblank <= 1'b0;
				if (hcount == 8'd75) hblank <= 1'b0;
			end

			// -- motion --
			if (hm_tick) begin
				if (mov_p0 && hm_cnt == (hmp0 ^ 4'h8)) mov_p0 <= 1'b0;
				if (mov_p1 && hm_cnt == (hmp1 ^ 4'h8)) mov_p1 <= 1'b0;
				if (mov_m0 && hm_cnt == (hmm0 ^ 4'h8)) mov_m0 <= 1'b0;
				if (mov_m1 && hm_cnt == (hmm1 ^ 4'h8)) mov_m1 <= 1'b0;
				if (mov_bl && hm_cnt == (hmbl ^ 4'h8)) mov_bl <= 1'b0;
				hm_cnt <= hm_cnt + 4'd1;
				if (hm_cnt == 4'd15) begin hm_run <= 1'b0; hmove_lat <= 1'b0; end
			end

			// -- positions --
			pos_p0 <= step160(pos_p0, oclk_normal, ext_p0);
			pos_p1 <= step160(pos_p1, oclk_normal, ext_p1);
			pos_m0 <= resmp0 ? park(pos_p0, nusiz0[2:0]) : step160(pos_m0, oclk_normal, ext_m0);
			pos_m1 <= resmp1 ? park(pos_p1, nusiz1[2:0]) : step160(pos_m1, oclk_normal, ext_m1);
			pos_bl <= step160(pos_bl, oclk_normal, ext_bl);

			// -- collisions: any two objects lit in the same clock --
			if (ce) begin
				if (m0 && p1) cx_m0p1 <= 1'b1;  if (m0 && p0) cx_m0p0 <= 1'b1;
				if (m1 && p0) cx_m1p0 <= 1'b1;  if (m1 && p1) cx_m1p1 <= 1'b1;
				if (p0 && pf) cx_p0pf <= 1'b1;  if (p0 && bl) cx_p0bl <= 1'b1;
				if (p1 && pf) cx_p1pf <= 1'b1;  if (p1 && bl) cx_p1bl <= 1'b1;
				if (m0 && pf) cx_m0pf <= 1'b1;  if (m0 && bl) cx_m0bl <= 1'b1;
				if (m1 && pf) cx_m1pf <= 1'b1;  if (m1 && bl) cx_m1bl <= 1'b1;
				if (bl && pf) cx_blpf <= 1'b1;
				if (p0 && p1) cx_p0p1 <= 1'b1;  if (m0 && m1) cx_m0m1 <= 1'b1;
			end

			// -- button latches: once pressed, stay pressed until re-armed --
			if (!inpt[4]) inpt4_l <= 1'b0;
			if (!inpt[5]) inpt5_l <= 1'b0;

			// -- register writes --
			if (wr) begin
				case (addr)
				6'h00: begin                       // VSYNC
					if (din[1] && !vsync) begin frame_start <= 1'b1; line <= 9'd0; end
					vsync <= din[1];
				end
				6'h01: begin                       // VBLANK
					vblank <= din[1];
					inpt_latch_en <= din[6];
					inpt_dump <= din[7];
					if (!din[6]) begin inpt4_l <= 1'b1; inpt5_l <= 1'b1; end
				end
				6'h02: if (!wrap) rdy <= 1'b0;     // WSYNC; one written as the line ends is void
				6'h03: hcount <= 8'd0;             // RSYNC
				6'h04: nusiz0 <= din[5:0];
				6'h05: nusiz1 <= din[5:0];
				6'h06: colup0 <= din[7:1];
				6'h07: colup1 <= din[7:1];
				6'h08: colupf <= din[7:1];
				6'h09: colubk <= din[7:1];
				6'h0A: ctrlpf <= din[5:0];
				6'h0B: refp0 <= din[3];
				6'h0C: refp1 <= din[3];
				6'h0D: pf0 <= din[7:4];
				6'h0E: pf1 <= din;
				6'h0F: pf2 <= din;
				6'h10: pos_p0 <= 8'd0;             // RESP0
				6'h11: pos_p1 <= 8'd0;
				6'h12: pos_m0 <= 8'd0;
				6'h13: pos_m1 <= 8'd0;
				6'h14: pos_bl <= 8'd0;
				6'h15: audc0 <= din[3:0];
				6'h16: audc1 <= din[3:0];
				6'h17: audf0 <= din[4:0];
				6'h18: audf1 <= din[4:0];
				6'h19: audv0 <= din[3:0];
				6'h1A: audv1 <= din[3:0];
				// The vertical delay works by copying: writing one player's
				// graphics latches the other's into its "old" register, and the
				// ball's enable rides on GRP1. That is the whole mechanism, and it
				// is why a kernel alternates GRP0/GRP1 writes to use it.
				6'h1B: begin grp0 <= din; grp1_old <= grp1; end
				6'h1C: begin grp1 <= din; grp0_old <= grp0; enabl_old <= enabl; end
				6'h1D: enam0 <= din[1];
				6'h1E: enam1 <= din[1];
				6'h1F: enabl <= din[1];
				6'h20: hmp0 <= din[7:4];
				6'h21: hmp1 <= din[7:4];
				6'h22: hmm0 <= din[7:4];
				6'h23: hmm1 <= din[7:4];
				6'h24: hmbl <= din[7:4];
				6'h25: vdelp0 <= din[0];
				6'h26: vdelp1 <= din[0];
				6'h27: vdelbl <= din[0];
				6'h28: resmp0 <= din[1];
				6'h29: resmp1 <= din[1];
				6'h2A: begin                       // HMOVE: start the 16-tick sequence
					hmove_lat <= 1'b1; hm_run <= 1'b1; hm_cnt <= 4'd0;
					mov_p0 <= 1'b1; mov_p1 <= 1'b1; mov_m0 <= 1'b1; mov_m1 <= 1'b1; mov_bl <= 1'b1;
				end
				6'h2B: begin                       // HMCLR
					hmp0 <= 4'd0; hmp1 <= 4'd0; hmm0 <= 4'd0; hmm1 <= 4'd0; hmbl <= 4'd0;
				end
				6'h2C: begin                       // CXCLR
					{cx_m0p1, cx_m0p0, cx_m1p0, cx_m1p1, cx_p0pf, cx_p0bl, cx_p1pf, cx_p1bl} <= 8'd0;
					{cx_m0pf, cx_m0bl, cx_m1pf, cx_m1bl, cx_blpf, cx_p0p1, cx_m0m1} <= 7'd0;
				end
				default: ;
				endcase
			end
		end
	end

	// --- audio -----------------------------------------------------------------------------
	// The audio clock is two pulses a line (31.4 kHz). Each channel divides it by
	// AUDF+1 and feeds the result to its tone generator.
	wire aud_tick = ce && (hcount == 8'd8 || hcount == 8'd122);

	wire [3:0] ch0, ch1;
	a26_tia_audio u_ch0 (.clk(clk), .rst(rst), .tick(aud_tick), .audc(audc0), .audf(audf0), .audv(audv0), .out(ch0));
	a26_tia_audio u_ch1 (.clk(clk), .rst(rst), .tick(aud_tick), .audc(audc1), .audf(audf1), .audv(audv1), .out(ch1));

	// The console is mono: both channels sum onto one pin. 0..30 centred on zero.
	wire [4:0] mix = {1'b0, ch0} + {1'b0, ch1};
	wire signed [15:0] mix_s = $signed({1'b0, mix, 10'd0}) - 16'sd15360;
	assign audio_l = mix_s;
	assign audio_r = mix_s;

endmodule

//////////////////////////////////////////////////////////////////////////////////
// One TIA audio channel: the frequency divider and the tone generator selected
// by AUDC, as the Stella Programmer's Guide lists them:
//
//   0 set to 1          4 div 2 (pure)        8 9-bit poly (noise)   C div 6 (pure)
//   1 4-bit poly        5 div 2               9 5-bit poly           D div 6
//   2 div 15 -> 4-bit   6 div 31 (pure)       A div 31               E div 93
//   3 5-bit -> 4-bit    7 5-bit -> div 2      B set last 4 bits to 1 F 5-bit -> div 6
//
// The polynomial counters are maximal-length shift registers: x^4+x^3+1 (period
// 15), x^5+x^3+1 (31) and x^9+x^5+1 (511). The guide names the div-31 and div-93
// modes only by their period; the waveform's shape inside the period is not
// given there, and the 18-high/13-low split used for div 31 (div 93 is that
// /3) is an assumption to check against a recording of real hardware.
//////////////////////////////////////////////////////////////////////////////////
module a26_tia_audio (
	input  wire       clk,
	input  wire       rst,
	input  wire       tick,       // the 31.4 kHz audio clock
	input  wire [3:0] audc,
	input  wire [4:0] audf,
	input  wire [3:0] audv,
	output wire [3:0] out
);
	reg [4:0] fdiv;
	reg [3:0] p4;
	reg [4:0] p5;
	reg [8:0] p9;
	reg       d2;
	reg [2:0] c6;
	reg [3:0] c15;
	reg [4:0] c31;
	reg [1:0] c3;

	wire ch_tick = tick && (fdiv == audf);

	// the 5-bit polynomial's output this tick, used by the modes that chain it
	wire p5_out = p5[4] ^ p5[2];

	always @(posedge clk) begin
		if (rst) begin
			fdiv <= 5'd0; p4 <= 4'hF; p5 <= 5'h1F; p9 <= 9'h1FF;
			d2 <= 1'b0; c6 <= 3'd0; c15 <= 4'd0; c31 <= 5'd0; c3 <= 2'd0;
		end else if (tick) begin
			fdiv <= ch_tick ? 5'd0 : fdiv + 5'd1;
			if (ch_tick) begin
				p5  <= {p5[3:0], p5_out};
				p9  <= {p9[7:0], p9[8] ^ p9[4]};
				c15 <= (c15 == 4'd14) ? 4'd0 : c15 + 4'd1;
				c31 <= (c31 == 5'd30) ? 5'd0 : c31 + 5'd1;
				if (c31 == 5'd30) c3 <= (c3 == 2'd2) ? 2'd0 : c3 + 2'd1;
				case (audc)
				4'h1:        p4 <= {p4[2:0], p4[3] ^ p4[2]};
				4'h2:        if (c15 == 4'd14) p4 <= {p4[2:0], p4[3] ^ p4[2]};
				4'h3:        if (p5_out) p4 <= {p4[2:0], p4[3] ^ p4[2]};
				4'h4, 4'h5:  d2 <= ~d2;
				4'h7:        if (p5_out) d2 <= ~d2;
				4'hC, 4'hD:  c6 <= (c6 == 3'd5) ? 3'd0 : c6 + 3'd1;
				4'hF:        if (p5_out) c6 <= (c6 == 3'd5) ? 3'd0 : c6 + 3'd1;
				default: ;
				endcase
			end
		end
	end

	reg tone;
	always @* begin
		case (audc)
		4'h0, 4'hB:        tone = 1'b1;
		4'h1, 4'h2, 4'h3:  tone = p4[3];
		4'h4, 4'h5, 4'h7:  tone = d2;
		4'h6, 4'hA:        tone = (c31 < 5'd18);
		4'h8:              tone = p9[8];
		4'h9:              tone = p5[4];
		4'hC, 4'hD, 4'hF:  tone = (c6 < 3'd3);
		4'hE:              tone = (c3 == 2'd0);
		default:           tone = 1'b0;
		endcase
	end
	assign out = tone ? audv : 4'd0;

endmodule
