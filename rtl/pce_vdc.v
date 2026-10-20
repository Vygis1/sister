`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pce_vdc.v - the PC Engine's video display controller, the HuC6270.
//
// 64 kB of video RAM (32 k words), a background of 8x8 tiles from a scrolling map of 32/64/128
// by 32/64 tiles, 64 sprites of 16x16 to 32x64 from a 256-word sprite table of its own, 16 of
// them a line, and the registers a program reaches through the two ports: $0000 (status read,
// register select write) and $0002/$0003 (the selected register's low and high byte). The
// chip's behaviour as MAME's huc6270 and the documentation describe it: VRAM written through
// VWR (the high byte commits, MAWR steps by CR's increment), read through VRR (a buffer filled
// from MARR when MARR is written and after each high-byte read), the raster counter at $40 on
// the first displayed line and RCR's interrupt at the start of the line whose number it holds,
// the vertical blank interrupt as the display ends and the sprite table loaded from DVSSR then
// (DCR bit 4: every frame), VRAM-to-VRAM DMA started by LENR's high byte, the status bits
// cleared by reading them.
//
// --- how a line is made -----------------------------------------------------------------------
//
// The VCE (pce_vce) owns the clocks: `dot_ce` is a pixel, `line_start` the first dot of a line,
// `frame_start` the first line of a frame. Horizontal timing from HSR/HDR and vertical from
// VPR/VDW/VCR place the display window inside them, in 8-pixel units and lines.
//
// The background is fetched two tiles ahead of the beam into a line buffer, a tile's three
// words (its map entry, its two pattern words) read just before they are needed, so a scroll
// register written early in the line counts for that line as on the chip. The sprites of the
// NEXT line are found and drawn during this one, into the second of two sprite line buffers
// (each entry tagged with the line it was drawn for, so nothing has to be cleared): the 64
// table entries scanned for the ones covering the line, in order, up to sixteen 16-pixel
// slices (a 32-wide sprite is two), their pattern words read from VRAM and written pixel by
// pixel, the first to reach a pixel keeping it (the lowest sprite wins). More than sixteen
// sets the overflow flag; a later sprite's pixel landing on sprite 0's sets collision. At the
// output, a sprite pixel shows in front of the background when its priority bit says so or the
// background pixel is 0; a background pixel of 0 is the VCE's colour 0.
//
// VRAM is a dual-port block RAM: the program, the read buffer and the DMAs on one port, the
// background fetcher and the sprite drawer on the other, the fetcher first.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module pce_vdc (
	input  wire        clk,
	input  wire        rst,

	// the processor's port: physical $1FE000 + a[1:0]
	input  wire        sel,
	input  wire [1:0]  a,
	input  wire        we,            // one clock
	input  wire        rd,            // one clock: a read is happening (status clears, VRR steps)
	input  wire [7:0]  d,
	output reg  [7:0]  q,
	output wire        irq,

	// the VCE's clocks and counters
	input  wire        dot_ce,
	input  wire        line_start,    // (with dot_ce) the first dot of a line
	input  wire        frame_start,   // (with line_start) the first line of a frame
	input  wire [9:0]  dot,           // the dot within the line, 0 at line_start
	input  wire [8:0]  line,          // the line within the frame

	// the pixel: a colour table index, when `in_disp`, at every dot_ce
	output reg  [8:0]  px_idx,
	output reg         px_en,         // (dot_ce) a dot of the display window
	output reg  [9:0]  px_x,          // its place in the window
	output reg  [8:0]  px_y,
	output wire [9:0]  disp_w,        // the window's size, pixels and lines
	output wire [8:0]  disp_h,
	output reg         disp_start     // pulse: the first line of the display begins
);

	// --- the registers -------------------------------------------------------------------------
	reg [4:0]  rsel;
	reg [15:0] mawr, marr, cr, rcr, bxr, byr, mwr, hsr, hdr, vpr, vdw, vcr, dcr, sour, desr, lenr, dvssr;
	reg [7:0]  lo;                    // the low byte of a 16-bit write, waiting for its high
	reg [15:0] vrr;                   // the read buffer
	reg        st_cr, st_or, st_rr, st_ds, st_dv, st_vd;      // the status bits
	reg        byr_hit;               // BYR written since the line began
	reg        satb_pend;             // a sprite table load is due at the next vertical blank
	wire [15:0] inc = (cr[12:11] == 2'd0) ? 16'd1 : (cr[12:11] == 2'd1) ? 16'd32 : (cr[12:11] == 2'd2) ? 16'd64 : 16'd128;
	assign irq = (st_cr & cr[0]) | (st_or & cr[1]) | (st_rr & cr[2]) | (st_vd & cr[3]) | (st_ds & dcr[0]) | (st_dv & dcr[1]);

	// --- VRAM and the sprite table ---------------------------------------------------------------
	(* ram_style = "block" *) reg [15:0] vram [0:32767];
	reg [15:0] sat [0:255];
	// port A: the program, the read buffer, the DMAs
	reg        a_we; reg [14:0] a_addr; reg [15:0] a_wd; reg [15:0] a_q;
	always @(posedge clk) begin
		if (a_we) vram[a_addr] <= a_wd;
		a_q <= vram[a_addr];
	end
	// port B: the fetcher and the sprite drawer
	// port B: the background fetcher's address, or the sprite fetcher's while it holds the port
	// (s_port; the two never run together) -- one register each, so one driver each
	reg  s_port;                         // a sprite read is out on port B, the fetcher waits
	reg  [14:0] f_baddr, s_baddr; reg [15:0] b_q;
	wire [14:0] b_addr = s_port ? s_baddr : f_baddr;
	always @(posedge clk) b_q <= vram[b_addr];

	// --- the window ---------------------------------------------------------------------------------
	wire [9:0] hds   = ((hsr[14:8] < 7'd2 ? 10'd2 : {3'd0, hsr[14:8]}) + 10'd1) << 3;   // (back porch: at least 2 units)
	wire [9:0] hsw   = ({5'd0, hsr[4:0]} + 10'd1) << 3;
	wire [9:0] h_on  = hsw + hds;                                     // the first displayed dot
	wire [9:0] h_w   = ({3'd0, hdr[6:0]} + 10'd1) << 3;
	wire [8:0] v_on  = {4'd0, vpr[4:0]} + 9'd1 + {1'b0, vpr[15:8]} + 9'd2;   // the first displayed line
	wire [8:0] v_h   = vdw[8:0] + 9'd1;
	assign disp_w = h_w; assign disp_h = v_h;
	wire [9:0] x_disp = dot - h_on;
	wire       h_act = (dot >= h_on) && (x_disp < h_w);
	wire [8:0] y_disp = line - v_on;
	wire       v_act = (line >= v_on) && (y_disp < v_h);
	reg  [9:0] raster;                // $40 on the first displayed line
	reg  [8:0] bg_y;                  // the background row this line (BYR, then counting)
	reg        v_act_q;

	reg s_overflow, s_collide;           // (the sprite drawer's, below)
	// --- the background fetcher: tile k of the line, two ahead of the beam ----------------------
	// A tile's pixels land in bg_buf at x = 8k - (BXR & 7): entry x holds {palette, colour}.
	reg [7:0]  bg_buf [0:527];
	reg [7:0]  bg_q;
	wire [6:0] map_w_sh = (mwr[5:4] == 2'd0) ? 7'd5 : (mwr[5:4] == 2'd1) ? 7'd6 : 7'd7;    // log2 of the map's width
	wire [9:0] map_w_m  = (10'd1 << map_w_sh) - 10'd1;                                     // in tiles, as a mask
	wire [5:0] map_h_m  = mwr[6] ? 6'd63 : 6'd31;
	reg  [6:0] f_tile;                // which tile of the line is being fetched (0..66)
	reg  [2:0] f_st;
	reg  [15:0] f_bat, f_p01;
	reg  [3:0]  f_px;                 // the pixel being written
	wire [9:0] f_x0  = ({3'd0, f_tile} << 3) + (bxr[9:0] & 10'h3F8);        // the tile's first pixel in map space
	wire [6:0] f_col = f_x0[9:3] & map_w_m[6:0];
	wire [5:0] f_row = bg_y[8:3] & map_h_m;
	wire [14:0] f_bat_a = ({9'd0, f_row} << map_w_sh) | {8'd0, f_col};
	wire [14:0] f_tile_a = {f_bat[10:0], 4'd0} | {12'd0, bg_y[2:0]};        // tile x 16 + row (planes 0, 1); + 8 for 2, 3
	wire [9:0]  f_bx  = ({3'd0, f_tile} << 3) - {7'd0, bxr[2:0]} + {6'd0, f_px};   // where the pixel lands
	wire [6:0]  f_want = ((h_w + 10'd15) >> 3) + 7'd1;                       // tiles a line needs
	wire [9:0]  f_due = h_on + ({3'd0, f_tile} << 3) - 10'd16;             // fetch tile k from this dot on
	wire        f_go = v_act && (f_tile < f_want) && f_st == 3'd0 && !s_port && (dot >= f_due || dot + 10'd24 >= h_on + ({3'd0, f_tile} << 3));
	wire        f_busy = (f_st != 3'd0);

	// --- the sprites of the next line ----------------------------------------------------------------
	// Two line buffers, each entry {tag[7:0], priority, palette[3:0], colour[3:0]}: the drawer writes one
	// while the output reads the other (its own read port). The table is scanned in order for the
	// first sixteen slices on the line, then they are drawn last to first, each overwriting, so
	// the lowest sprite ends on top; a bit a pixel remembers what sprite 0 is about to land on.
	// (the tag is the display line's low byte: a stale entry from a line drawn earlier never
	// matches -- a bit would, every fourth line)
	reg [16:0] sp_buf0 [0:511];
	reg [16:0] sp_buf1 [0:511];
	reg [16:0] sp_q0, sp_q1;
	reg [511:0] sp_opq0, sp_opq1;     // an opaque pixel of a sprite other than 0 is there
	reg [8:0]  s_line;                // the line being drawn (the next one)
	reg [3:0]  s_st;
	reg [6:0]  s_i;                   // the table entry being scanned / drawn
	reg [4:0]  s_n;                   // slices found
	reg [6:0]  s_list [0:15];         // {cell, entry}
	reg [4:0]  s_k;                   // the slice being drawn
	reg [15:0] s_y, s_x, s_pat, s_att;
	reg [5:0]  s_row;                 // the row within the sprite (after a flip)
	reg        s_cell;                // the 16-pixel column being drawn (1: the right half of a 32-wide)
	reg [15:0] s_pl0, s_pl1, s_pl2;
	reg [4:0]  s_px;
	reg [1:0]  s_wait;
	wire [8:0] sp_y0 = s_y[9:0] - 10'd64;
	wire [6:0] sp_h  = (s_att[13:12] == 2'd0) ? 7'd16 : (s_att[13:12] == 2'd3) ? 7'd64 : 7'd32;
	wire [8:0] sp_dy = s_line - sp_y0;
	wire       sp_hit = (sp_dy < {2'd0, sp_h});
	wire [5:0] sp_row = s_att[15] ? (sp_h[5:0] - 6'd1 - sp_dy[5:0]) : sp_dy[5:0];
	wire [9:0] sp_pbase = s_pat[10:1] & ~{9'd0, s_att[8]} & ~{8'd0, (sp_h != 7'd16), 1'b0} & ~{7'd0, (sp_h == 7'd64), 2'd0};
	wire       s_cellx = s_att[11] ? ~s_cell : s_cell;                        // X flip swaps the two cells
	wire [14:0] s_cell_a = {sp_pbase + {9'd0, s_att[8] & s_cellx} + {7'd0, s_row[5:4], 1'b0}, 6'd0};
	wire [9:0]  s_x0 = s_x[9:0] - 10'd32 + ({9'd0, s_cell} << 4);
	wire [9:0]  s_xp = s_x0 + (s_att[11] ? 10'd15 - {6'd0, s_px[3:0]} : {6'd0, s_px[3:0]});
	wire [3:0]  s_pix = {b_q[15 - s_px[3:0]], s_pl2[15 - s_px[3:0]], s_pl1[15 - s_px[3:0]], s_pl0[15 - s_px[3:0]]};
	wire [7:0]  s_tag = s_line[7:0];
	wire        s_which = s_line[0];
	reg  [8:0]  s_last;               // the last line sprites were drawn for
	// --- port A: the program first, then the read buffer, then the DMAs -------------------------------
	reg        pf_req; reg [1:0] pf_wait;   // a read-buffer fill is wanted; one is out (two clocks to the word)
	reg        dma_on; reg [1:0] dma_st; reg [15:0] dma_len;
	reg        satb_on; reg [8:0] satb_i; reg [1:0] satb_w;
	always @(posedge clk) begin
		a_we <= 1'b0;
		if (rst) begin
			rsel <= 5'd0; mawr <= 0; marr <= 0; cr <= 0; rcr <= 0; bxr <= 0; byr <= 0; mwr <= 0; raster <= 10'd0;
			hsr <= 16'h0202; hdr <= 16'h031F; vpr <= 16'h0F02; vdw <= 16'h00EF; vcr <= 16'h0004;
			dcr <= 0; sour <= 0; desr <= 0; lenr <= 0; dvssr <= 0; lo <= 0; vrr <= 0;
			st_cr <= 0; st_or <= 0; st_rr <= 0; st_ds <= 0; st_dv <= 0; st_vd <= 0;
			byr_hit <= 0; satb_pend <= 0; pf_req <= 0; pf_wait <= 2'd0;
			dma_on <= 0; dma_st <= 0; dma_len <= 0; satb_on <= 0; satb_i <= 0; satb_w <= 2'd0;
		end else begin
			// --- the program ---------------------------------------------------------------------------
			if (sel && we) case (a)
				2'd0: rsel <= d[4:0];
				2'd2: lo <= d;
				2'd3: case (rsel)
					5'h00: mawr <= {d, lo};
					5'h01: begin marr <= {d, lo}; pf_req <= 1'b1; end
					5'h02: begin a_we <= 1'b1; a_addr <= mawr[14:0]; a_wd <= {d, lo}; mawr <= mawr + inc; end
					5'h05: cr <= {d, lo};
					5'h06: rcr <= {d, lo};
					5'h07: bxr <= {d, lo};
					5'h08: begin byr <= {d, lo}; byr_hit <= 1'b1; end
					5'h09: mwr <= {d, lo};
					5'h0A: hsr <= {d, lo};
					5'h0B: hdr <= {d, lo};
					5'h0C: vpr <= {d, lo};
					5'h0D: vdw <= {d, lo};
					5'h0E: vcr <= {d, lo};
					5'h0F: dcr <= {d, lo};
					5'h10: sour <= {d, lo};
					5'h11: desr <= {d, lo};
					5'h12: begin lenr <= {d, lo}; dma_on <= 1'b1; dma_st <= 2'd0; dma_len <= {d, lo}; end
					5'h13: begin dvssr <= {d, lo}; satb_pend <= 1'b1; end
					default: ;
				endcase
				default: ;
			endcase
			if (sel && rd) begin
				if (a == 2'd0) begin st_cr <= 0; st_or <= 0; st_rr <= 0; st_ds <= 0; st_dv <= 0; st_vd <= 0; end
				if (a == 2'd3 && rsel == 5'h02) begin marr <= marr + inc; pf_req <= 1'b1; end
			end
			// --- the read buffer: filled from MARR (the stepped one) when nothing else wants the port
			if (pf_wait == 2'd1) begin vrr <= a_q; pf_wait <= 2'd0; end
			else if (pf_wait == 2'd2) pf_wait <= 2'd1;
			else if (pf_req && !(sel && we)) begin a_addr <= (sel && rd && a == 2'd3 && rsel == 5'h02) ? marr[14:0] + inc[14:0] : marr[14:0]; pf_req <= 1'b0; pf_wait <= 2'd2; end
			// --- VRAM to VRAM: a word read, a word written -----------------------------------------------
			else if (dma_on && !(sel && we)) case (dma_st)
				2'd0: begin a_addr <= sour[14:0]; dma_st <= 2'd1; end
				2'd1: dma_st <= 2'd2;
				2'd2: begin
					a_we <= 1'b1; a_addr <= desr[14:0]; a_wd <= a_q;
					sour <= dcr[2] ? sour - 16'd1 : sour + 16'd1;
					desr <= dcr[3] ? desr - 16'd1 : desr + 16'd1;
					dma_len <= dma_len - 16'd1;
					if (dma_len == 16'd0) begin dma_on <= 1'b0; st_dv <= 1'b1; end
					dma_st <= 2'd0;
				end
				default: dma_st <= 2'd0;
			endcase
			// --- the sprite table, 256 words from DVSSR at the vertical blank --------------------------
			else if (satb_on && !(sel && we)) begin
				case (satb_w)
				2'd0: begin a_addr <= dvssr[14:0] + {6'd0, satb_i}; satb_w <= 2'd1; end
				2'd1: satb_w <= 2'd2;
				default: begin
					sat[satb_i[7:0]] <= a_q;                    // (the word asked for two clocks ago)
					satb_w <= 2'd0; satb_i <= satb_i + 9'd1;
					if (satb_i == 9'd255) begin satb_on <= 1'b0; satb_i <= 9'd0; st_ds <= 1'b1; end
				end
				endcase
			end
			// --- the raster: interrupts at the start of a line, the blank as the display ends ---------
			if (dot_ce && line_start) begin
				byr_hit <= 1'b0;
				if (line == v_on) raster <= 10'h40;
				else raster <= raster + 10'd1;
				if (line == v_on + {1'b0, v_h}) begin                      // the display is over: the blank
					st_vd <= 1'b1;
					if (satb_pend || dcr[4]) begin satb_on <= 1'b1; satb_i <= 9'd0; satb_w <= 2'd0; satb_pend <= 1'b0; end
				end
				if (((line == v_on) ? 10'h40 : raster + 10'd1) == rcr[9:0]) st_rr <= 1'b1;
			end
			if (s_overflow) st_or <= 1'b1;
			if (s_collide) st_cr <= 1'b1;
		end
	end
	always @(*) begin
		case (a)
			2'd0: q = {1'b0, 1'b0, st_vd, st_dv, st_ds, st_rr, st_or, st_cr};
			2'd2: q = vrr[7:0];                 // (the read buffer, whatever register is selected;
			2'd3: q = vrr[15:8];                //  only with VRR selected does the high byte step MARR)
			default: q = 8'd0;
		endcase
	end

	// --- the background's row counter, the fetcher -------------------------------------------------
	always @(posedge clk) begin
		disp_start <= 1'b0;
		if (rst) begin
			bg_y <= 9'd0; v_act_q <= 1'b0; f_tile <= 7'd0; f_st <= 3'd0; f_px <= 4'd0; f_bat <= 0; f_p01 <= 0;
		end else begin
			if (dot_ce && line_start) begin
				// the row: BYR on the first line, then counting, unless BYR was written
				if (line == v_on) begin bg_y <= byr[8:0]; disp_start <= 1'b1; end
				else if (byr_hit) bg_y <= byr[8:0];
				else bg_y <= bg_y + 9'd1;
				f_tile <= 7'd0; f_st <= 3'd0;
			end
			case (f_st)
			3'd0: if (f_go) begin f_baddr <= f_bat_a; f_st <= 3'd1; end
			3'd1: f_st <= 3'd2;                                             // (the map word arrives)
			3'd2: begin f_bat <= b_q; f_baddr <= {b_q[10:0], 4'd0} | {12'd0, bg_y[2:0]}; f_st <= 3'd3; end
			3'd3: begin f_baddr <= f_tile_a | 15'd8; f_st <= 3'd4; end        // (planes 0,1 arrive next; ask for 2,3)
			3'd4: begin f_p01 <= b_q; f_st <= 3'd5; f_px <= 4'd0; end
			3'd5: begin                                                       // planes 2,3 in b_q: the eight pixels
				if (f_bx < 10'd528)
					bg_buf[f_bx[9:0]] <= {f_bat[15:12], b_q[15 - f_px[2:0]], b_q[7 - f_px[2:0]], f_p01[15 - f_px[2:0]], f_p01[7 - f_px[2:0]]};
				if (f_px == 4'd7) begin f_st <= 3'd0; f_tile <= f_tile + 7'd1; end
				f_px <= f_px + 4'd1;
			end
			default: f_st <= 3'd0;
			endcase
		end
	end

	// --- the sprites of the next line: scan, then fetch and draw last to first ----------------------
	localparam [3:0] SS_IDLE = 0, SS_SCAN_Y = 1, SS_SCAN_T = 2, SS_PICK = 3, SS_PICK_T = 4, SS_FETCH0 = 5,
	                 SS_FETCH1 = 6, SS_FETCH2 = 7, SS_FETCH3 = 8, SS_DRAW = 9;
	wire [8:0] s_xp9 = s_xp[8:0];
	always @(posedge clk) begin
		s_overflow <= 1'b0; s_collide <= 1'b0;
		if (rst) begin s_st <= SS_IDLE; s_i <= 0; s_n <= 0; s_k <= 0; s_line <= 0; s_last <= 9'h1FF; s_cell <= 0; s_px <= 0; s_port <= 0; sp_opq0 <= 0; sp_opq1 <= 0; end
		else begin
			// (the sprites' lines are the display's: the next line, counted from the first displayed)
			if (dot_ce && line_start && s_st == SS_IDLE && line + 9'd1 - v_on != s_last) begin
				s_line <= line + 9'd1 - v_on; s_last <= line + 9'd1 - v_on; s_i <= 7'd0; s_n <= 5'd0; s_st <= SS_SCAN_Y;
				if (!(line[0] ^ v_on[0])) sp_opq1 <= 512'd0; else sp_opq0 <= 512'd0;   // (the buffer about to be drawn)
			end
			case (s_st)
			// the scan: the entry's Y and attributes, is it on the line, note it
			SS_SCAN_Y: begin
				if (s_i == 7'd64) begin s_k <= s_n; s_st <= (s_n == 5'd0) ? SS_IDLE : SS_PICK; end
				else begin s_y <= sat[{s_i[5:0], 2'd0}]; s_att <= sat[{s_i[5:0], 2'd3}]; s_st <= SS_SCAN_T; end
			end
			SS_SCAN_T: begin
				if (sp_hit) begin
					if (s_n + (s_att[8] ? 5'd2 : 5'd1) > 5'd16) begin s_overflow <= 1'b1; s_k <= s_n; s_st <= SS_PICK; end   // too many: the flag, and draw what was found
					else begin
						s_list[s_n] <= {1'b0, s_i[5:0]};
						if (s_att[8]) begin s_list[s_n + 5'd1] <= {1'b1, s_i[5:0]}; s_n <= s_n + 5'd2; end
						else s_n <= s_n + 5'd1;
						s_i <= s_i + 7'd1; s_st <= SS_SCAN_Y;
					end
				end else begin s_i <= s_i + 7'd1; s_st <= SS_SCAN_Y; end
			end
			// the draw: slice s_k - 1 down to 0, its entry's words read again
			SS_PICK: begin
				if (s_k == 5'd0) s_st <= SS_IDLE;
				else begin
					s_i <= {1'b0, s_list[s_k - 5'd1][5:0]}; s_cell <= s_list[s_k - 5'd1][6];
					s_y <= sat[{s_list[s_k - 5'd1][5:0], 2'd0}]; s_x <= sat[{s_list[s_k - 5'd1][5:0], 2'd1}];
					s_pat <= sat[{s_list[s_k - 5'd1][5:0], 2'd2}]; s_att <= sat[{s_list[s_k - 5'd1][5:0], 2'd3}];
					s_k <= s_k - 5'd1; s_st <= SS_PICK_T;
				end
			end
			SS_PICK_T: begin s_row <= sp_row; s_st <= SS_FETCH0; end
			// the four planes of the row, one word each (port B when the fetcher is not on it)
			SS_FETCH0: if (!f_busy && !f_go) begin s_baddr <= s_cell_a | {11'd0, s_row[3:0]}; s_port <= 1'b1; s_st <= SS_FETCH1; end
			SS_FETCH1: begin s_baddr <= s_cell_a | 15'd16 | {11'd0, s_row[3:0]}; s_st <= SS_FETCH2; end
			SS_FETCH2: begin s_pl0 <= b_q; s_baddr <= s_cell_a | 15'd32 | {11'd0, s_row[3:0]}; s_st <= SS_FETCH3; end
			SS_FETCH3: begin s_pl1 <= b_q; s_baddr <= s_cell_a | 15'd48 | {11'd0, s_row[3:0]}; s_st <= SS_DRAW; s_px <= 5'd0; s_wait <= 2'd1; end
			SS_DRAW: begin
				// plane 2 arrives first, then plane 3 stays in b_q for the 16 pixels
				if (s_wait != 2'd0) s_wait <= s_wait - 2'd1;
				if (s_wait == 2'd1) s_pl2 <= b_q;
				else begin
					if (s_pix != 4'd0 && s_xp < 10'd512) begin
						if (s_which) sp_buf1[s_xp9] <= {s_tag, s_att[7], s_att[3:0], s_pix};
						else         sp_buf0[s_xp9] <= {s_tag, s_att[7], s_att[3:0], s_pix};
						if (s_i != 7'd0) begin if (s_which) sp_opq1[s_xp9] <= 1'b1; else sp_opq0[s_xp9] <= 1'b1; end
						else if (s_which ? sp_opq1[s_xp9] : sp_opq0[s_xp9]) s_collide <= 1'b1;
					end
					s_px <= s_px + 5'd1;
					if (s_px == 5'd15) begin s_port <= 1'b0; s_st <= SS_PICK; end
				end
			end
			default: ;
			endcase
		end
	end
	// the output's read of the sprite buffers, a dot ahead
	always @(posedge clk) begin sp_q0 <= sp_buf0[x_disp[8:0] + 9'd1]; sp_q1 <= sp_buf1[x_disp[8:0] + 9'd1]; end
	always @(posedge clk) bg_q <= bg_buf[x_disp[9:0] + 10'd1];

	// --- the output: a colour index a dot ----------------------------------------------------------------
	wire [16:0] o_sp = y_disp[0] ? sp_q1 : sp_q0;
	wire        o_sp_on = cr[6] && (o_sp[16:9] == y_disp[7:0]) && (o_sp[3:0] != 4'd0);
	wire        o_bg_on = cr[7] && (bg_q[3:0] != 4'd0);
	always @(posedge clk) begin
		px_en <= 1'b0;
		if (dot_ce && h_act && v_act) begin
			px_en <= 1'b1; px_x <= x_disp; px_y <= y_disp;
			if (o_sp_on && (o_sp[8] || !o_bg_on)) px_idx <= {1'b1, o_sp[7:4], o_sp[3:0]};
			else if (o_bg_on) px_idx <= {1'b0, bg_q};
			else px_idx <= 9'd0;
		end
	end

endmodule

`default_nettype wire
