//////////////////////////////////////////////////////////////////////////////////
// vdp.v - the Master System's video chip, a Sega 315-5124.
//
// Descended from the TMS9918 and still carrying its four old modes, none of
// which any Master System game uses. What they use is mode 4, which Sega added,
// and that is what this implements.
//
// Compared with the NES PPU next door the differences are more interesting than
// the similarities:
//
//   - Tiles are FOUR bitplanes, not two, so sixteen colours each rather than
//     four, and a tile is 32 bytes rather than 16.
//   - The palette is writable. The NES picks from 64 colours fixed in silicon;
//     here there are 32 entries of 6-bit RGB that the game loads itself, which
//     is why a Master System picture can look washed out or lurid in a way a
//     NES one never does.
//   - Scrolling is a pair of registers, not a pointer the program has to nudge
//     at exactly the right moment. Much harder to get wrong, much less capable.
//   - There is a line counter that interrupts after a programmable number of
//     scanlines. The NES has no such thing; its games count cycles or abuse
//     sprite 0. This is the civilised version.
//
// --- the ports ----------------------------------------------------------------
//
// Two addresses, and the protocol lives in the sequence rather than the address:
//
//   $BE   read or write VRAM (or CRAM) at the current address, then bump it
//   $BF   write twice to set up: the first byte is the low half of an address,
//         the second says what to do with it. Read it for the status flags.
//
// The second control byte's top two bits choose: 00 prepare to read VRAM,
// 01 prepare to write VRAM, 10 write a register (number in the low nibble,
// value in the first byte), 11 prepare to write CRAM.
//
// Reading the status port clears VBlank, the line interrupt and the first/second
// byte latch. That last one matters: a status read in the middle of a two-byte
// control sequence does not just report, it resynchronises.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module vdp #(
	parameter GG = 0                  // a Game Gear's VDP: the 12-bit palette (color12)
) (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,           // one pixel

	// CPU side. The Z80 reaches this through its I/O space.
	input  wire        cpu_sel,      // an access is happening this cycle
	input  wire        cpu_ctrl,     // 0 = data port $BE, 1 = control port $BF
	input  wire        cpu_wr,
	input  wire [7:0]  cpu_din,
	output reg  [7:0]  cpu_dout,

	output wire        irq_n,        // to the Z80, active low

	// video out
	output wire [8:0]  px,
	output wire [8:0]  py,
	output wire        pixel_en,
	output wire [5:0]  color,        // 6-bit RGB, --BBGGRR
	output wire [11:0] color12,      // (GG) 12-bit RGB, BBBBGGGGRRRR, from the Game Gear's palette
	output wire        frame_start
);

	// --- geometry -----------------------------------------------------------
	// 342 pixels by 262 lines, of which 256 by 192 are picture. The numbers are
	// not round because they come from the NTSC colour subcarrier, not from
	// anyone's convenience.
	localparam H_TOTAL = 342, V_TOTAL = 262;
	localparam H_DISP  = 256, V_DISP  = 192;

	// Where the background starts fetching the NEXT line: hc 256..307 belongs to
	// the sprites, and everything after that to priming the tile pipeline.
	localparam BG_PRIME = 9'd308;

	reg [8:0] hc, vc;
	wire hc_last = (hc == H_TOTAL - 1);
	wire vc_last = (vc == V_TOTAL - 1);

	wire visible = (vc < V_DISP);
	wire active  = visible && (hc < H_DISP);

	// The picture is 192 lines, but the framebuffer downstream is 240 because it
	// was sized for the other console. The remaining 48 are emitted black rather
	// than left holding whatever the NES last drew there.
	localparam V_OUT = 240;
	wire in_frame = (vc < V_OUT) && (hc < H_DISP);

	assign px          = hc;
	assign py          = vc;
	assign pixel_en    = in_frame && ce;
	assign frame_start = ce && hc_last && vc_last;

	always @(posedge clk) begin
		if (rst) begin
			hc <= 9'd0; vc <= 9'd0;
		end else if (ce) begin
			if (hc_last) begin
				hc <= 9'd0;
				vc <= vc_last ? 9'd0 : vc + 9'd1;
			end else hc <= hc + 9'd1;
		end
	end

	// --- registers ------------------------------------------------------------
	reg [7:0] vr [0:15];

	wire       line_irq_en = vr[0][4];
	wire       hide_left   = vr[0][5];   // blank the leftmost 8 pixels
	wire       lock_top    = vr[0][6];   // top two rows ignore horizontal scroll
	wire       lock_right  = vr[0][7];   // right eight columns ignore vertical scroll
	wire       spr_shift   = vr[0][3];   // move every sprite eight pixels left
	wire       spr_16      = vr[1][1];
	wire       vbl_irq_en  = vr[1][5];
	wire       display_on  = vr[1][6];
	wire [2:0] nt_base     = vr[2][3:1];
	wire [5:0] sat_base    = vr[5][6:1];
	wire       spr_pat     = vr[6][2];
	wire [3:0] backdrop    = vr[7][3:0];
	wire [7:0] hscroll     = vr[8];
	wire [7:0] vscroll     = vr[9];

	// Requested by the sprite search, applied where the other status flags live.
	// Two blocks writing one flag is multi-driven: simulation picks a winner and
	// synthesis ties the other driver to a constant, so it would work here and
	// fail on the board.
	reg ovf_req;

	// --- memory ----------------------------------------------------------------
	reg [7:0] vram [0:16383];
	reg [5:0] cram [0:31];
	// The Game Gear's palette: 32 entries of 12 bits (BBBBGGGGRRRR), each written as two bytes --
	// the even address latches the low byte (GGGGRRRR), the odd one commits {----BBBB, latch}.
	reg [11:0] cram12 [0:31];
	reg [7:0]  cram_lo;
	integer mi;
	initial begin
		for (mi = 0; mi < 16384; mi = mi + 1) vram[mi] = 8'd0;
		for (mi = 0; mi < 32; mi = mi + 1)    cram[mi] = 6'd0;
		for (mi = 0; mi < 32; mi = mi + 1)    cram12[mi] = 12'd0;
		cram_lo = 8'd0;
	end

	// --- the control port's two-byte dance ---------------------------------------
	reg        latched;         // a first byte is waiting
	reg [7:0]  first;
	reg [13:0] vaddr;
	reg [1:0]  vcode;           // 00 read VRAM, 01 write VRAM, 10 register, 11 CRAM

	// ONE read port, shared. Two ports cost eight block RAM tiles instead of
	// four because Vivado duplicates the memory, and the design does not have
	// eight to spare once the Master System's work RAM is added.
	//
	// Sharing works because the renderer only fetches during the picture. Off
	// the picture -- which is when a game does its VRAM work, because it has to
	// -- the port belongs to the CPU. A CPU access during active display gets
	// whatever the renderer was reading, which is exactly what the real chip
	// does and why games do not do it.
	reg  [13:0] rd_addr;

	// The renderer's work for a line does not all happen during that line. The
	// picture is fetched as it is drawn, but the sprites and the first two tiles
	// belong to the line AFTER this one and are read during the blanking before
	// it. So the question "who owns the bus" is about the line being prepared,
	// which is this one before hc 256 and the next one after.
	wire vis_now  = (vc < V_DISP);
	wire vis_next = (vc + 9'd1 < V_DISP) || (vc == V_TOTAL - 1);
	wire        renderer_busy = display_on && (hc < 9'd256 ? vis_now : vis_next);
	wire [13:0] vram_ra = renderer_busy ? rd_addr : vaddr;

	// Gated by `ce`, and that is not cosmetic. The fetch schedule is written in
	// PIXELS -- an address asked for in one phase is read two phases later --
	// so the memory has to advance in pixels too. Ungated it advances every
	// clock, the data turns up an enable early, and every fetch reads the wrong
	// byte. With ce tied high in this chip's own testbench the two are
	// indistinguishable, which is how it passed there and failed the moment it
	// was given a real clock enable.
	reg [7:0] vram_q;
	always @(posedge clk) if (ce) vram_q <= vram[vram_ra];

	wire [7:0] rd_data     = vram_q;
	wire [7:0] cpu_rd_data = vram_q;



	reg        stat_vbl, stat_ovf, stat_col;
	reg        line_irq;
	reg [7:0]  line_ctr;

	// Both interrupt sources are level-triggered and share one pin.
	assign irq_n = ~((stat_vbl && vbl_irq_en) || (line_irq && line_irq_en));

	reg  cpu_vram_wr;
	reg [13:0] cpu_vram_addr;
	reg [7:0]  cpu_vram_data;

	// --- CPU access ---------------------------------------------------------------
	integer ri;
	always @(posedge clk) begin
		if (rst) begin
			latched <= 1'b0; first <= 8'd0; vaddr <= 14'd0; vcode <= 2'd0;
			cpu_vram_wr <= 1'b0;
			stat_vbl <= 1'b0; stat_ovf <= 1'b0; stat_col <= 1'b0;
			line_irq <= 1'b0; line_ctr <= 8'd0;
			for (ri = 0; ri < 16; ri = ri + 1) vr[ri] <= 8'd0;
			vr[2] <= 8'h0E; vr[5] <= 8'h7E;      // where the BIOS usually puts them
		end else begin
			cpu_vram_wr <= 1'b0;

			// --- the line counter -----------------------------------------------
			// Reloaded outside the picture and on every line that underflows, so a
			// game gets an interrupt every (R10 + 1) lines rather than once.
			if (ce && hc_last) begin
				if (vc >= V_DISP && vc != V_TOTAL - 1) begin
					line_ctr <= vr[10];
				end else begin
					if (line_ctr == 8'd0) begin
						line_ctr <= vr[10];
						line_irq <= 1'b1;
					end else line_ctr <= line_ctr - 8'd1;
				end

				if (vc == V_DISP - 1) stat_vbl <= 1'b1;
			end

			if (ovf_req) stat_ovf <= 1'b1;

			if (cpu_sel) begin
				if (cpu_ctrl) begin
					if (cpu_wr) begin
						if (!latched) begin
							first   <= cpu_din;
							vaddr[7:0] <= cpu_din;
							latched <= 1'b1;
						end else begin
							latched <= 1'b0;
							vcode   <= cpu_din[7:6];
							vaddr[13:8] <= cpu_din[5:0];
							if (cpu_din[7:6] == 2'b10)
								vr[cpu_din[3:0]] <= first;
						end
					end else begin
						// Reading the status port reports, and also clears both
						// interrupt flags AND the first/second byte latch. A
						// status read part-way through a control sequence
						// resynchronises it rather than being ignored.
						cpu_dout <= {stat_vbl, stat_ovf, stat_col, 5'b11111};
						stat_vbl <= 1'b0;
						stat_ovf <= 1'b0;
						stat_col <= 1'b0;
						line_irq <= 1'b0;
						latched  <= 1'b0;
					end
				end else begin
					// The data port. Any access to it also drops the latch.
					latched <= 1'b0;
					if (cpu_wr) begin
						if (vcode == 2'b11) begin
							if (GG) begin
								if (vaddr[0]) cram12[vaddr[5:1]] <= {cpu_din[3:0], cram_lo};
								else          cram_lo <= cpu_din;
							end else cram[vaddr[4:0]] <= cpu_din[5:0];
						end
						else begin
							cpu_vram_wr   <= 1'b1;
							cpu_vram_addr <= vaddr;
							cpu_vram_data <= cpu_din;
						end
					end else begin
						// Setting up a read address makes the chip fetch that
						// byte straight away, so the first read of the data
						// port returns it rather than a stale buffer. That is
						// the opposite of the NES's $2007 and worth not
						// copying across by habit.
						cpu_dout <= cpu_rd_data;
					end
					vaddr <= vaddr + 14'd1;
				end
			end
		end
	end

	always @(posedge clk) if (cpu_vram_wr) vram[cpu_vram_addr] <= cpu_vram_data;

	// Where the sprite table lives, and the evaluation state. All declared up
	// here because the background fetch below borrows its spare slots to do the
	// reading.
	wire [13:0] sat_addr = {sat_base, 8'd0};

	// A counter of its own rather than anything derived from the background's
	// column. Two reasons: the byte arrives two cycles after it is asked for, by
	// which time a column number has moved on; and horizontal scroll rotates the
	// column order, which would make "the first eight found" stop meaning "the
	// eight lowest-numbered" -- and that ordering IS the sprite priority.
	reg [5:0]  ev_idx;                   // which table entry to ask for next
	reg [5:0]  ev_a, ev_b;               // which two are in flight
	reg        ev_done;                  // a $D0 terminator was found
	reg [3:0]  n_found;
	reg [5:0]  n_num [0:7];
	reg [3:0]  n_row [0:7];

	// --- the pattern fetch, during horizontal blanking ---------------------------
	// Fifty-two cycles for all eight sprites, and the arithmetic behind that
	// number is the whole reason the picture comes out right.
	//
	// The obvious schedule is per sprite: ask for its X and tile, wait two
	// cycles for the memory, ask for its four bitplanes, wait two more. Ten
	// cycles each, eighty for eight -- which fits in the eighty-six of blanking
	// with nothing left over, and "nothing left over" is the problem. The
	// background needs sixteen of those cycles to fetch the first two tiles of
	// the NEXT line, because it runs two tiles ahead and has nowhere else to
	// start. Without them the line opens with a tile of whatever was in the
	// pipeline, which showed up as a two-pixel stripe down the left of every
	// frame.
	//
	// The line is not short of bandwidth -- 204 background reads, 64 for the
	// sprite search and 48 for the sprite patterns is 316 of 342. It was short
	// of SCHEDULE: a fifth of the sprite fetch was spent waiting for a tile
	// number to arrive so the address that depends on it could be formed.
	//
	// So the dependency is hoisted out of the loop. All sixteen X-and-tile
	// bytes are read first, back to back, and only then the thirty-two plane
	// bytes -- by which time every tile number is already in hand and the reads
	// have no stalls between them at all. Two passes of 18 and 34 cycles, and
	// the memory's two-cycle latency is paid once per pass instead of twice per
	// sprite. That frees thirty-four cycles, which is what the background
	// priming runs in.
	reg [5:0] sf_step;                   // 0..51 across the window
	reg [7:0] st_tile [0:7];             // tile numbers, held between the passes

	reg [7:0] s_x  [0:7];
	reg [7:0] s_p0 [0:7], s_p1 [0:7], s_p2 [0:7], s_p3 [0:7];
	reg [3:0] s_n;

	// Pass one: the (X, tile) pairs, two bytes per sprite.
	wire [2:0]  p1_idx  = sf_step[3:1];
	wire [13:0] p1_addr = sat_addr | 14'h80 | {7'd0, n_num[p1_idx], sf_step[0]};
	wire [4:0]  p1_k    = sf_step[4:0] - 5'd2;    // the byte now arriving

	// Pass two: the bitplanes, four bytes per sprite, no stalls.
	wire [5:0]  p2_j    = sf_step - 6'd18;
	wire [2:0]  p2_idx  = p2_j[4:2];
	wire [1:0]  p2_byte = p2_j[1:0];
	wire [7:0]  p2_tile = st_tile[p2_idx];
	wire [3:0]  p2_row  = n_row[p2_idx];
	// In 8x16 mode the tile number's low bit is ignored: the pair is treated as
	// one tall sprite.
	wire [13:0] p2_pat  = spr_16 ? {spr_pat, p2_tile[7:1], p2_row,      2'b00}
	                             : {spr_pat, p2_tile,      p2_row[2:0], 2'b00};
	wire [5:0]  p2_k    = sf_step - 6'd20;        // the plane byte now arriving

	// --- background ---------------------------------------------------------------
	// Each tile needs six reads: two for its name table entry, four for its
	// bitplanes. That does not fit in the eight cycles a tile is on screen for,
	// because the pattern address depends on the name table entry and memory
	// answers a cycle late -- two address cycles, two of latency, four address
	// cycles, two more of latency is ten.
	//
	// So the fetch runs TWO tiles ahead and the data moves along a pipeline:
	// the name table entry for tile n+2 is read while the bitplanes for tile
	// n+1 are read, and both land in time for tile n+1 to be displayed next.
	// Phases 6 and 7 do no reading at all, which is where the sprite fetches
	// will go.
	// Where the background fetch is, in the coordinates of the line it is
	// fetching FOR. During the picture that is just hc on this line. During the
	// tail of blanking it is a negative position on the NEXT one: hc 308 is 34
	// pixels before the start of the line to come, which is written as -34 in
	// eight bits because everything downstream only wants it modulo 256.
	wire       bg_pre   = (hc >= BG_PRIME);
	wire [7:0] bg_hc    = bg_pre ? (hc[7:0] + 8'd170) : hc[7:0];   // -342 mod 256
	wire [8:0] bg_vc    = bg_pre ? ((vc == V_TOTAL - 1) ? 9'd0 : vc + 9'd1) : vc;

	wire [7:0] bg_y      = bg_vc[7:0] + (lock_right && !bg_pre && hc >= 9'd192 ? 8'd0 : vscroll);
	wire [4:0] bg_row    = bg_y[7:3];
	wire [2:0] bg_fine_y = bg_y[2:0];

	// Horizontal scroll moves the picture right, so the column being fetched is
	// to the left of where it will land.
	wire [8:0] bg_x      = {1'b0, bg_hc} - {1'b0, (lock_top && bg_vc < 9'd16) ? 8'd0 : hscroll};
	wire [4:0] bg_col    = bg_x[7:3];
	wire [2:0] bg_fine_x = bg_x[2:0];

	// Attributes travel as {priority, palette, vertical flip, horizontal flip}.
	reg [8:0] f_tile;               // the tile whose planes are being fetched
	reg [3:0] f_attr;
	reg [3:0] c_attr;               // ...and the attributes being displayed
	reg [7:0] n0, n1, n2, n3;       // planes arriving
	reg [7:0] c0, c1, c2, c3;       // planes on screen
	reg [7:0] nt_lo;

	// Vertical flip counts the row from the bottom, and is needed at fetch time
	// rather than display time because it changes which bytes are read.
	wire [2:0]  f_row = f_attr[1] ? (3'd7 - bg_fine_y) : bg_fine_y;
	wire [13:0] f_pat = {f_tile, f_row, 2'b00};

	wire [4:0]  nt_col = bg_col + 5'd2;
	wire [13:0] nt_a   = {nt_base, bg_row, nt_col, 1'b0};

	integer si2;
	always @(posedge clk) begin
		if (rst) begin
			ev_idx <= 6'd0; ev_a <= 6'd0; ev_b <= 6'd0;
			ev_done <= 1'b0; n_found <= 4'd0; ovf_req <= 1'b0;
			sf_step <= 6'd0; s_n <= 4'd0;
			for (si2 = 0; si2 < 8; si2 = si2 + 1) begin
				s_x[si2] <= 8'hFF;
				s_p0[si2] <= 8'd0; s_p1[si2] <= 8'd0;
				s_p2[si2] <= 8'd0; s_p3[si2] <= 8'd0;
				n_num[si2] <= 6'd0; n_row[si2] <= 4'd0;
				st_tile[si2] <= 8'd0;
			end
		end else if (ce) begin
			ovf_req <= 1'b0;

			// A fresh search every line, started at the very end of the line so
			// the list being built is never the list being drawn from.
			if (hc == 9'd341) begin
				n_found <= 4'd0;
				ev_done <= 1'b0;
				ev_idx  <= 6'd0;
			end

			// The sprite fetch borrows the same address bus as the background, so
			// it lives in THIS block. Driving rd_addr from a second always block
			// is multi-driven -- simulation silently picks a winner and corrupts
			// whichever fetch loses, which showed up as the first tiles of every
			// line coming out blank.
			if (hc == 9'd255) begin
				sf_step <= 6'd0;
				s_n     <= n_found;      // hand this line's findings to the renderer
			end

			// Fifty-two cycles, hc 256..307: sixteen address-and-tile reads, then
			// thirty-two plane reads. Each pass issues one address per cycle and
			// takes delivery two cycles behind, so the passes overlap by two and
			// nothing ever waits.
			if (hc >= 9'd256 && hc < BG_PRIME) begin
				if (sf_step < 6'd16) rd_addr <= p1_addr;
				else if (sf_step < 6'd50) rd_addr <= p2_pat | {12'd0, p2_byte};

				if (sf_step >= 6'd2 && sf_step < 6'd18) begin
					if (p1_k[0]) st_tile[p1_k[3:1]] <= rd_data;
					else         s_x    [p1_k[3:1]] <= rd_data;
				end

				if (sf_step >= 6'd20) case (p2_k[1:0])
					2'd0: s_p0[p2_k[4:2]] <= rd_data;
					2'd1: s_p1[p2_k[4:2]] <= rd_data;
					2'd2: s_p2[p2_k[4:2]] <= rd_data;
					2'd3: s_p3[p2_k[4:2]] <= rd_data;
				endcase

				sf_step <= sf_step + 6'd1;
			end

			if (hc < 9'd256 || hc >= BG_PRIME) case (bg_x[2:0])
			3'd0: begin
				rd_addr <= f_pat;
				// The Y byte asked for in phase 6 has arrived.
				if (hc < 9'd256) evaluate(ev_a);
			end
			3'd1: begin
				rd_addr <= f_pat | 14'd1;
				if (hc < 9'd256) evaluate(ev_b);
			end
			3'd2: begin rd_addr <= f_pat | 14'd2; n0 <= rd_data; end
			3'd3: begin rd_addr <= f_pat | 14'd3; n1 <= rd_data; end
			3'd4: begin rd_addr <= nt_a;          n2 <= rd_data; end
			3'd5: begin rd_addr <= nt_a | 14'd1;  n3 <= rd_data; end
			3'd6: begin
				nt_lo <= rd_data;
				// Two spare slots per tile, which is exactly the 64 reads the
				// sprite table needs across a line.
				if (hc < 9'd256) begin
					rd_addr <= sat_addr | {8'd0, ev_idx};
					ev_a    <= ev_idx;
					ev_idx  <= ev_idx + 6'd1;
				end
			end
			default: begin
				if (hc < 9'd256) begin
					rd_addr <= sat_addr | {8'd0, ev_idx};
					ev_b    <= ev_idx;
					ev_idx  <= ev_idx + 6'd1;
				end
				// The handover, at the END of the group rather than the start.
				// These are nonblocking, so loading at phase 0 would leave the
				// new planes invisible until phase 1 and put the whole picture
				// one pixel to the right.
				//
				// c_attr takes the OLD f_attr -- the attributes of the tile
				// whose planes are in n0..n3 -- while f_attr takes the new ones
				// in the same breath.
				c0 <= n0; c1 <= n1; c2 <= n2; c3 <= n3;
				c_attr <= f_attr;
				f_tile <= {rd_data[0], nt_lo};
				f_attr <= {rd_data[4], rd_data[3], rd_data[2], rd_data[1]};
			end
			endcase
		end
	end

	// Horizontal flip reads the row the other way round.
	wire [2:0] bit_sel = c_attr[0] ? bg_fine_x : (3'd7 - bg_fine_x);
	wire [3:0] bg_pix  = {c3[bit_sel], c2[bit_sel], c1[bit_sel], c0[bit_sel]};
	wire       bg_opaque = |bg_pix;

	// --- sprites --------------------------------------------------------------
	// Sixty-four of them, described by a table split in two halves: the first 64
	// bytes are Y positions, and from $80 there are (X, tile) pairs. A Y of $D0
	// ends the list early, which is how a game says "that is all of them" without
	// having to park the rest off screen.
	//
	// Y is stored one less than where the sprite appears, the same convention as
	// the NES. Eight sprites per line, and the ninth sets the overflow flag --
	// that limit is part of how these machines look, not a shortcut.
	//
	// The work is split across the line: evaluation uses the two fetch slots the
	// background leaves free in every group of eight pixels, which comes to
	// exactly the 64 reads needed, and the pattern fetches use the horizontal
	// blanking that follows.
	// Which line the sprites are being gathered for.
	wire [8:0] spr_line = (vc == V_TOTAL - 1) ? 9'd0 : (vc + 9'd1);
	wire [3:0] spr_h    = spr_16 ? 4'd15 : 4'd7;


	// The comparison, done on the byte as it arrives.
	wire [8:0] ev_rel = spr_line - {1'b0, rd_data} - 9'd1;
	wire       ev_hit = (ev_rel <= {5'd0, spr_h});

	task evaluate;
		input [5:0] which;
		begin
			if (!ev_done) begin
				if (rd_data == 8'hD0) begin
					ev_done <= 1'b1;
				end else if (ev_hit) begin
					if (n_found < 4'd8) begin
						n_num[n_found[2:0]] <= which;
						n_row[n_found[2:0]] <= ev_rel[3:0];
						n_found <= n_found + 4'd1;
					end else ovf_req <= 1'b1;
				end
			end
		end
	endtask

	// --- which sprite wins this pixel ---------------------------------------------
	// The lowest-numbered sprite with an opaque pixel, so the search runs
	// backwards and later matches overwrite earlier ones.
	reg [3:0] sp_pix;
	reg       sp_hit, sp_collide;
	integer   sj;
	reg [8:0] sdx;
	reg [2:0] sbit;

	always @* begin
		sp_pix     = 4'd0;
		sp_hit     = 1'b0;
		sp_collide = 1'b0;
		for (sj = 7; sj >= 0; sj = sj - 1) begin
			sdx = {1'b0, hc[7:0]} - {1'b0, s_x[sj]} + (spr_shift ? 9'd8 : 9'd0);
			if (sdx < 9'd8 && sj < s_n) begin
				sbit = 3'd7 - sdx[2:0];
				if ({s_p3[sj][sbit], s_p2[sj][sbit],
				     s_p1[sj][sbit], s_p0[sj][sbit]} != 4'd0) begin
					if (sp_hit) sp_collide = 1'b1;   // two sprites on one pixel
					sp_pix = {s_p3[sj][sbit], s_p2[sj][sbit],
					          s_p1[sj][sbit], s_p0[sj][sbit]};
					sp_hit = 1'b1;
				end
			end
		end
	end

	// --- the picture ------------------------------------------------------------
	// Colour zero of either palette is transparent over the backdrop, and the
	// leftmost eight pixels can be blanked to hide what scrolling drags in.
	wire blanked = !display_on || (hide_left && hc < 9'd8);

	// A background tile with its priority bit set covers sprites, but only where
	// that tile is actually opaque -- which is what lets a game put a sprite
	// behind a fence and in front of the sky it shows through.
	wire spr_wins = sp_hit && !(bg_opaque && c_attr[3]);

	wire [4:0] pal_idx = blanked   ? {1'b1, backdrop}
	                   : spr_wins  ? {1'b1, sp_pix}
	                   : bg_opaque ? {c_attr[2], bg_pix}
	                               : {1'b1, backdrop};

	assign color   = visible ? cram[pal_idx]   : 6'd0;
	assign color12 = visible ? cram12[pal_idx] : 12'd0;

endmodule

`default_nettype wire
