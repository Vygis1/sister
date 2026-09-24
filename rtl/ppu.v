//////////////////////////////////////////////////////////////////////////////////
// ppu.v - the NES picture processing unit (2C02).
//
// Frame geometry is 341 PPU cycles by 262 scanlines, and it is not negotiable:
// games drive raster effects by writing PPU registers at exact points in the
// frame, so the counters here ARE the interface, not an implementation detail.
//
//   scanline 0..239   visible
//   scanline 240      post-render, idle
//   scanline 241      VBlank starts at cycle 1; NMI fires here
//   scanline 242..260 VBlank
//   scanline 261      pre-render; VBlank clears at cycle 1
//
// On odd frames, cycle 340 of the pre-render line is skipped when rendering is
// enabled. That one missing cycle is what keeps the colour phase aligned on real
// hardware, and games with tight raster timing notice when it is absent.
//
// Scrolling uses the internal v/t/x/w registers as the hardware does rather than
// a tidier abstraction, because $2005 and $2006 share them: writing a scroll
// value changes the address register and vice versa. Games rely on that overlap,
// so the messy version is the correct one.
//
//   v  15-bit current VRAM address   yyy NN YYYYY XXXXX
//   t  15-bit latched address        (fine Y, nametable, coarse Y, coarse X)
//   x  3-bit fine X scroll
//   w  write toggle, shared by $2005 and $2006, cleared by reading $2002
//
// Reading $2002 has side effects -- it clears the VBlank flag and the write
// toggle -- so it must only act on a real CPU read, never on a stray decode.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ppu (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,             // one PPU dot per assertion

	// --- CPU interface ($2000-$2007) ---------------------------------------
	input  wire [2:0]  cpu_addr,
	input  wire [7:0]  cpu_din,
	output reg  [7:0]  cpu_dout,
	input  wire        cpu_rd,
	input  wire        cpu_wr,
	output wire        nmi,

	// --- VRAM interface -----------------------------------------------------
	output wire [13:0] vram_addr,
	input  wire [7:0]  vram_din,
	output wire [7:0]  vram_dout,
	output wire        vram_rd,
	output wire        vram_wr,

	// --- video out ----------------------------------------------------------
	output wire [8:0]  cycle,          // 0..340
	output wire [8:0]  scanline,       // 0..261
	output wire        pixel_en,       // this dot is a visible pixel
	output wire [5:0]  pixel,          // palette index
	output wire        frame_start,
	output wire        vblank_start
);

	localparam CYCLES_PER_LINE = 341;
	localparam LINES_PER_FRAME = 262;
	localparam LINE_POST       = 240;
	localparam LINE_VBLANK     = 241;
	localparam LINE_PRERENDER  = 261;

	// --- registers -----------------------------------------------------------
	reg [1:0] ctrl_nt;          // $2000 bits 1:0 -> t bits 11:10
	reg       ctrl_inc;         // 0 = +1 across, 1 = +32 down
	reg       ctrl_spr_tbl;
	reg       ctrl_bg_tbl;
	reg       ctrl_spr_16;
	reg       ctrl_nmi;

	reg       mask_grey, mask_bg_left, mask_spr_left, mask_bg, mask_spr;
	reg [2:0] mask_emph;

	reg       stat_vblank, stat_spr0, stat_overflow;
	// Requested by the render logic, applied by the CPU block so the status
	// register keeps a single driver.
	reg       stat_overflow_set;
	wire      spr0_hit;

	reg [14:0] v, t;
	reg [2:0]  x;
	reg        w;

	reg [7:0]  oam_addr;
	reg [7:0]  read_buffer;     // $2007 reads are delayed by one
	reg [7:0]  open_bus;

	// --- frame timing --------------------------------------------------------
	reg [8:0] cyc;
	reg [8:0] sl;
	reg       odd_frame;

	assign cycle    = cyc;
	assign scanline = sl;

	wire rendering = mask_bg || mask_spr;
	wire visible   = (sl < LINE_POST);
	wire prerender = (sl == LINE_PRERENDER);
	wire fetching  = rendering && (visible || prerender);

	// The odd-frame short line: cycle 340 of the pre-render scanline does not
	// happen when rendering is on.
	wire skip_dot  = odd_frame && prerender && rendering && (cyc == 9'd339);
	wire line_end  = (cyc == CYCLES_PER_LINE - 1) || skip_dot;

	assign frame_start  = (sl == 9'd0) && (cyc == 9'd0);
	assign vblank_start = (sl == LINE_VBLANK) && (cyc == 9'd1);

	always @(posedge clk) begin
		if (rst) begin
			cyc <= 9'd0; sl <= 9'd0; odd_frame <= 1'b0;
		end else if (ce) begin
			if (line_end) begin
				cyc <= 9'd0;
				if (sl == LINES_PER_FRAME - 1) begin
					sl        <= 9'd0;
					odd_frame <= ~odd_frame;
				end else sl <= sl + 9'd1;
			end else cyc <= cyc + 9'd1;
		end
	end

	assign nmi = ctrl_nmi && stat_vblank;

	// --- OAM -----------------------------------------------------------------
	reg [7:0] oam [0:255];
	integer oi;
	// Block RAM on this part powers up zeroed, and an `initial` block is how that
	// is spelled for both Vivado and the simulator. Without it simulation starts
	// from X where hardware starts from 0, and X propagating out of unwritten
	// memory hides real bugs behind fake ones.
	initial for (oi = 0; oi < 256; oi = oi + 1) oam[oi] = 8'd0;

	// --- palette -------------------------------------------------------------
	// 32 entries of 6-bit NES colour, internal to the PPU rather than out in
	// VRAM. Entries $10/$14/$18/$1C are mirrors of $00/$04/$08/$0C -- the
	// backdrop is shared between background and sprites, so writing the sprite
	// backdrop changes the background one.
	reg [5:0] palette [0:31];

	function [4:0] pal_index;
		input [4:0] a;
		begin
			pal_index = ((a & 5'h13) == 5'h10) ? (a & 5'h0F) : a;
		end
	endfunction

	wire        pal_sel  = (v[13:8] == 6'h3F);
	wire [4:0]  pal_addr = pal_index(v[4:0]);

	// --- scroll address stepping ---------------------------------------------
	// Coarse X wraps into the horizontal nametable bit; fine Y wraps into coarse
	// Y, which wraps at 29 rather than 31 because the last two rows of a
	// nametable are attribute data.
	wire coarse_x_max = (v[4:0] == 5'd31);
	wire fine_y_max   = (v[14:12] == 3'd7);
	wire coarse_y_29  = (v[9:5] == 5'd29);

	integer pi;

	// --- CPU access ----------------------------------------------------------
	// $2007 accesses drive the VRAM bus for one dot; the rest of the time the
	// rendering fetches own it.
	reg        cpu_vram_rd, cpu_vram_wr;
	reg [7:0]  cpu_vram_dout;
	// The address a $2007 access uses has to be captured before v increments.
	// Driving the bus from v itself puts every write one byte past where the
	// game meant it, which shifts whole nametable rows sideways -- and a status
	// bar shifted by one tile is a sprite 0 hit that never happens.
	reg [13:0] cpu_vram_addr;
	reg        cpu_vram_rd_d;

	wire [14:0] v_inc = v + (ctrl_inc ? 15'd32 : 15'd1);

	always @(posedge clk) begin
		if (rst) begin
			ctrl_nt <= 2'd0; ctrl_inc <= 1'b0; ctrl_spr_tbl <= 1'b0;
			ctrl_bg_tbl <= 1'b0; ctrl_spr_16 <= 1'b0; ctrl_nmi <= 1'b0;
			mask_grey <= 1'b0; mask_bg_left <= 1'b0; mask_spr_left <= 1'b0;
			mask_bg <= 1'b0; mask_spr <= 1'b0; mask_emph <= 3'd0;
			stat_vblank <= 1'b0; stat_spr0 <= 1'b0; stat_overflow <= 1'b0;
			v <= 15'd0; t <= 15'd0; x <= 3'd0; w <= 1'b0;
			oam_addr <= 8'd0; read_buffer <= 8'd0; open_bus <= 8'd0;
			for (pi = 0; pi < 32; pi = pi + 1) palette[pi] <= 6'd0;
			cpu_vram_rd <= 1'b0; cpu_vram_wr <= 1'b0;
			cpu_vram_addr <= 14'd0; cpu_vram_rd_d <= 1'b0;
		end else begin
			cpu_vram_rd <= 1'b0;
			cpu_vram_wr <= 1'b0;
			// VRAM answers a clock after it is addressed, so the buffer fills a
			// clock after the read goes out.
			cpu_vram_rd_d <= cpu_vram_rd;
			if (cpu_vram_rd_d) read_buffer <= vram_din;

			// VBlank is raised and cleared by the frame counters, not by the CPU.
			if (ce) begin
				if (sl == LINE_VBLANK && cyc == 9'd1) stat_vblank <= 1'b1;
				if (prerender && cyc == 9'd1) begin
					stat_vblank   <= 1'b0;
					stat_spr0     <= 1'b0;
					stat_overflow <= 1'b0;
				end else begin
					// Requested by the render logic; set here so the status
					// register keeps a single driver.
					if (spr0_hit)          stat_spr0     <= 1'b1;
					if (stat_overflow_set) stat_overflow <= 1'b1;
				end
			end

			// Scroll stepping lives here, not in the render block: `v` is
			// written by both the CPU ($2006/$2007) and by rendering, and a
			// register driven from two always blocks is multi-driven, which
			// synthesis rejects and simulation quietly tolerates.
			if (ce && fetching) begin
				// Horizontal step every eight dots across the visible line and
				// the prefetch at the end of it.
				if (((cyc >= 9'd8 && cyc <= 9'd256) || cyc == 9'd328 || cyc == 9'd336)
				    && (cyc[2:0] == 3'd0)) begin
					if (coarse_x_max) begin
						v[4:0] <= 5'd0;
						v[10]  <= ~v[10];
					end else v[4:0] <= v[4:0] + 5'd1;
				end

				// Vertical step at the end of the visible part of the line.
				if (cyc == 9'd256) begin
					if (!fine_y_max) v[14:12] <= v[14:12] + 3'd1;
					else begin
						v[14:12] <= 3'd0;
						if (coarse_y_29) begin
							v[9:5] <= 5'd0;
							v[11]  <= ~v[11];
						end else if (v[9:5] == 5'd31) begin
							v[9:5] <= 5'd0;          // no nametable flip past 31
						end else v[9:5] <= v[9:5] + 5'd1;
					end
				end

				// Horizontal position reloads from t at cycle 257.
				if (cyc == 9'd257) begin
					v[4:0] <= t[4:0];
					v[10]  <= t[10];
				end

				// Vertical position reloads through the pre-render line.
				if (prerender && cyc >= 9'd280 && cyc <= 9'd304) begin
					v[14:11] <= t[14:11];
					v[9:5]   <= t[9:5];
				end
			end

			if (cpu_wr) begin
				open_bus <= cpu_din;
				case (cpu_addr)
				3'd0: begin                              // $2000 PPUCTRL
					ctrl_nt      <= cpu_din[1:0];
					ctrl_inc     <= cpu_din[2];
					ctrl_spr_tbl <= cpu_din[3];
					ctrl_bg_tbl  <= cpu_din[4];
					ctrl_spr_16  <= cpu_din[5];
					ctrl_nmi     <= cpu_din[7];
					t[11:10]     <= cpu_din[1:0];
				end
				3'd1: begin                              // $2001 PPUMASK
					mask_grey     <= cpu_din[0];
					mask_bg_left  <= cpu_din[1];
					mask_spr_left <= cpu_din[2];
					mask_bg       <= cpu_din[3];
					mask_spr      <= cpu_din[4];
					mask_emph     <= cpu_din[7:5];
				end
				3'd3: oam_addr <= cpu_din;               // $2003 OAMADDR
				3'd4: begin                              // $2004 OAMDATA
					oam[oam_addr] <= cpu_din;
					oam_addr      <= oam_addr + 8'd1;
				end
				3'd5: begin                              // $2005 PPUSCROLL
					if (!w) begin
						t[4:0] <= cpu_din[7:3];
						x      <= cpu_din[2:0];
						w      <= 1'b1;
					end else begin
						t[9:5]   <= cpu_din[7:3];
						t[14:12] <= cpu_din[2:0];
						w        <= 1'b0;
					end
				end
				3'd6: begin                              // $2006 PPUADDR
					if (!w) begin
						t[13:8] <= cpu_din[5:0];
						t[14]   <= 1'b0;                 // bit 14 always clears
						w       <= 1'b1;
					end else begin
						t[7:0] <= cpu_din;
						v      <= {t[14:8], cpu_din};
						w      <= 1'b0;
					end
				end
				3'd7: begin                              // $2007 PPUDATA
					if (pal_sel) palette[pal_addr] <= cpu_din[5:0];
					else begin
						cpu_vram_dout <= cpu_din;
						cpu_vram_wr   <= 1'b1;
						cpu_vram_addr <= v[13:0];
					end
					v <= v_inc;
				end
				default: ;
				endcase
			end

			if (cpu_rd) begin
				case (cpu_addr)
				3'd2: begin                              // $2002 PPUSTATUS
					// Reading clears VBlank and the write toggle. Side effects,
					// so this must only happen on a genuine read.
					stat_vblank <= 1'b0;
					w           <= 1'b0;
				end
				3'd4: open_bus <= oam[oam_addr];
				3'd7: begin                              // $2007 PPUDATA
					// Reads are one behind: the value returned is what the last
					// read fetched. Palette space is the exception and returns
					// immediately.
					cpu_vram_rd   <= 1'b1;
					cpu_vram_addr <= v[13:0];
					v             <= v_inc;
				end
				default: ;
				endcase
			end
		end
	end

	always @* begin
		cpu_dout = open_bus;
		case (cpu_addr)
		3'd2: cpu_dout = {stat_vblank, stat_spr0, stat_overflow, open_bus[4:0]};
		3'd4: cpu_dout = oam[oam_addr];
		// Palette reads come back immediately; everything else is one behind.
		3'd7: cpu_dout = pal_sel ? {2'b00, palette[pal_addr]} : read_buffer;
		default: ;
		endcase
	end

	// --- sprites --------------------------------------------------------------
	// Eight sprites per scanline, evaluated for the NEXT line while this one is
	// still being drawn, then their pattern bytes fetched. Any more than eight
	// on a line sets the overflow flag and the rest simply do not appear -- that
	// limit is part of how NES games look, not a shortcut.
	// Two sets. `spr_*` is what the current scanline draws from; `n_*` is what
	// is being gathered for the next one. Sharing one set means evaluation at
	// cycle 65 corrupts the sprites the same line is still drawing from pixel 65
	// onward -- which looks like sprites vanishing halfway across the screen.
	reg [7:0]  spr_x  [0:7];
	reg [7:0]  spr_a  [0:7];
	reg [7:0]  spr_lo [0:7];
	reg [7:0]  spr_hi [0:7];
	reg        spr_z  [0:7];
	reg [3:0]  spr_n;

	reg [7:0]  n_y    [0:7];
	reg [7:0]  n_tile [0:7];
	reg [7:0]  n_a    [0:7];
	reg [7:0]  n_x    [0:7];
	reg [7:0]  n_lo   [0:7];
	reg [7:0]  n_hi   [0:7];
	reg        n_z    [0:7];
	reg [3:0]  n_count;

	integer si;

	// Evaluation for line N+1 runs during line N and compares OAM Y against N,
	// which is why a sprite with Y appears on lines Y+1..Y+8 rather than Y..Y+7.
	// The pre-render line counts as -1 here, and that is not a special case to
	// work around: it is what stops any sprite from appearing on scanline 0.
	wire [8:0] eval_line = prerender ? 9'h1FF : sl;
	wire [7:0] eval_idx  = cyc[7:0] - 8'd65;          // OAM entry, cycles 65..128
	wire [7:0] eval_y    = oam[{eval_idx[5:0], 2'b00}];
	wire [8:0] eval_row  = eval_line - {1'b0, eval_y};
	wire       eval_hit  = (eval_row < (ctrl_spr_16 ? 9'd16 : 9'd8));

	// Cycle 257 starts the fetches, and 257 is not a multiple of eight -- using
	// cyc[2:0] directly puts every latch one cycle out.
	wire [5:0] sf        = cyc[5:0] - 6'd1;           // 0..63 across 257..320
	wire [2:0] fetch_spr = sf[5:3];
	wire [2:0] fetch_ph  = sf[2:0];

	wire [7:0] f_attr    = n_a[fetch_spr];
	wire [7:0] f_tile    = n_tile[fetch_spr];
	wire [8:0] f_row_raw = eval_line - {1'b0, n_y[fetch_spr]};
	// Vertical flip counts from the bottom of the sprite.
	wire [3:0] f_row     = f_attr[7] ? ((ctrl_spr_16 ? 4'd15 : 4'd7) - f_row_raw[3:0])
	                                 : f_row_raw[3:0];

	wire [13:0] spr_fetch_addr = ctrl_spr_16
		? {1'b0, f_tile[0], f_tile[7:1], f_row[3], 1'b0, f_row[2:0]}
		: {1'b0, ctrl_spr_tbl, f_tile, 1'b0, f_row[2:0]};

	// --- background fetch ----------------------------------------------------
	// One tile every eight dots: nametable, attribute, pattern low, pattern
	// high, two dots each. The shifters reload on the eighth.
	reg [7:0]  nt_byte, at_byte, bg_lo;
	reg [15:0] shift_lo, shift_hi;
	reg [7:0]  attr_lo, attr_hi;
	reg [1:0]  at_latch;

	wire [13:0] nt_fetch_addr = {2'b10, v[11:0]};
	wire [13:0] at_fetch_addr = {2'b10, v[11:10], 4'b1111, v[9:7], v[4:2]};
	wire [13:0] pt_fetch_addr = {1'b0, ctrl_bg_tbl, nt_byte, 1'b0, v[14:12]};

	wire spr_fetch_phase = (cyc >= 9'd257) && (cyc <= 9'd320);

	reg [13:0] fetch_addr;
	always @* begin
		if (spr_fetch_phase) begin
			// Phases 4-5 fetch the low plane, 6-7 the high plane.
			fetch_addr = fetch_ph[2] && fetch_ph[1] ? (spr_fetch_addr | 14'd8)
			                                        : spr_fetch_addr;
		end else begin
			case (cyc[2:0])
			3'd1, 3'd2: fetch_addr = nt_fetch_addr;
			3'd3, 3'd4: fetch_addr = at_fetch_addr;
			3'd5, 3'd6: fetch_addr = pt_fetch_addr;
			default:    fetch_addr = pt_fetch_addr | 14'd8;
			endcase
		end
	end

	assign vram_addr = cpu_vram_rd || cpu_vram_wr ? cpu_vram_addr : fetch_addr;
	assign vram_dout = cpu_vram_dout;
	assign vram_rd   = cpu_vram_rd || fetching;
	assign vram_wr   = cpu_vram_wr;

	always @(posedge clk) begin
		if (rst) begin
			shift_lo <= 16'd0; shift_hi <= 16'd0;
			attr_lo  <= 8'd0;  attr_hi  <= 8'd0;
			spr_n <= 4'd0; n_count <= 4'd0; stat_overflow_set <= 1'b0;
			for (si = 0; si < 8; si = si + 1) begin
				spr_x[si] <= 8'hFF; spr_a[si] <= 8'd0;
				spr_lo[si] <= 8'd0; spr_hi[si] <= 8'd0; spr_z[si] <= 1'b0;
				n_y[si] <= 8'hFF; n_x[si] <= 8'hFF; n_a[si] <= 8'd0;
				n_tile[si] <= 8'd0; n_lo[si] <= 8'd0; n_hi[si] <= 8'd0; n_z[si] <= 1'b0;
			end
		end else if (ce) begin
			// --- sprite evaluation, cycles 65..128 --------------------------
			// One OAM entry per cycle, into the NEXT set.
			if (rendering && (visible || prerender)) begin
				if (cyc == 9'd64) begin
					n_count           <= 4'd0;
					stat_overflow_set <= 1'b0;
					// Secondary OAM clears to $FF, not zero, and the tile byte
					// is the part that matters beyond "this slot is empty": an
					// unused slot still runs its pattern fetch, and with 8x16
					// sprites the table is chosen by bit 0 of the tile number.
					// Tile $FF therefore pulls PPU A12 high once per scanline
					// even on a line with no sprites, which is what a cartridge
					// scanline counter counts. Clearing to zero holds A12 down
					// and the counter never advances.
					for (si = 0; si < 8; si = si + 1) begin
						n_y[si] <= 8'hFF; n_tile[si] <= 8'hFF;
						n_a[si] <= 8'hFF; n_x[si] <= 8'hFF; n_z[si] <= 1'b0;
					end
				end else if (cyc >= 9'd65 && cyc <= 9'd128) begin
					if (eval_hit) begin
						if (n_count < 4'd8) begin
							n_y   [n_count[2:0]] <= eval_y;
							n_tile[n_count[2:0]] <= oam[{eval_idx[5:0], 2'b01}];
							n_a   [n_count[2:0]] <= oam[{eval_idx[5:0], 2'b10}];
							n_x   [n_count[2:0]] <= oam[{eval_idx[5:0], 2'b11}];
							n_z   [n_count[2:0]] <= (eval_idx[5:0] == 6'd0);
							n_count <= n_count + 4'd1;
						end else begin
							// More than eight on a line: the rest do not appear,
							// and the overflow flag says so.
							stat_overflow_set <= 1'b1;
						end
					end
				end

				// --- sprite pattern fetch, cycles 257..320 ------------------
				if (spr_fetch_phase) begin
					if (fetch_ph == 3'd5) n_lo[fetch_spr] <= vram_din;
					if (fetch_ph == 3'd7) n_hi[fetch_spr] <= vram_din;
				end

				// --- hand the gathered set over, after the fetches finish ---
				if (cyc == 9'd340) begin
					spr_n <= n_count;
					for (si = 0; si < 8; si = si + 1) begin
						spr_x[si]  <= n_x[si];
						spr_a[si]  <= n_a[si];
						spr_lo[si] <= n_lo[si];
						spr_hi[si] <= n_hi[si];
						spr_z[si]  <= n_z[si];
					end
				end
			end

			if (fetching) begin
				// Latch each fetch as it completes.
				case (cyc[2:0])
				3'd2: nt_byte <= vram_din;
				3'd4: at_byte <= vram_din;
				3'd6: bg_lo   <= vram_din;
				default: ;
				endcase

				// The reload happens on the last dot of each eight-dot fetch,
				// not the first dot of the next one. A dot later and every tile
				// reaches the top of the shifter one pixel behind where it is
				// wanted: the picture is shifted right by one and column zero
				// shows the tail of the previous line.
				//
				// It also has to be this dot for the attribute. Coarse X steps
				// on this same edge, so reading v here picks the quadrant of the
				// tile just fetched; a dot later it picks the next tile's.
				if ((cyc >= 9'd1 && cyc <= 9'd256) || (cyc >= 9'd322 && cyc <= 9'd336)) begin
					shift_lo <= {shift_lo[14:0], 1'b0};
					shift_hi <= {shift_hi[14:0], 1'b0};
					attr_lo  <= {attr_lo[6:0], at_latch[0]};
					attr_hi  <= {attr_hi[6:0], at_latch[1]};

					if (cyc[2:0] == 3'd0) begin
						shift_lo[7:0] <= bg_lo;
						// The high plane is arriving from VRAM on this very dot,
						// so it comes straight off the bus rather than from a
						// latch that would not be written until after the reload.
						shift_hi[7:0] <= vram_din;
						at_latch      <= at_byte[{v[6], v[1], 1'b0} +: 2];
					end
				end
			end
		end
	end

	// --- sprite pixel selection ------------------------------------------------
	// The lowest-numbered sprite with an opaque pixel wins, which is why the
	// search runs backwards: later assignments overwrite earlier ones.
	wire [8:0] cur_x = cyc - 9'd1;

	reg [1:0] spr_pix;
	reg [1:0] spr_pal;
	reg       spr_pri;
	reg       spr_zero;
	integer   sj;
	reg [8:0] sdx;
	reg [2:0] sbit;

	always @* begin
		spr_pix  = 2'b00;
		spr_pal  = 2'b00;
		spr_pri  = 1'b0;
		spr_zero = 1'b0;
		for (sj = 7; sj >= 0; sj = sj - 1) begin
			sdx  = cur_x - {1'b0, spr_x[sj]};
			// Horizontal flip reads the pattern byte the other way round.
			sbit = spr_a[sj][6] ? sdx[2:0] : (3'd7 - sdx[2:0]);
			if (sdx < 9'd8 && sj < spr_n) begin
				if ({spr_hi[sj][sbit], spr_lo[sj][sbit]} != 2'b00) begin
					spr_pix  = {spr_hi[sj][sbit], spr_lo[sj][sbit]};
					spr_pal  = spr_a[sj][1:0];
					spr_pri  = spr_a[sj][5];
					spr_zero = spr_z[sj];
				end
			end
		end
	end

	// --- pixel ---------------------------------------------------------------
	wire [3:0] bg_bit = {attr_hi[7 - x], attr_lo[7 - x],
	                     shift_hi[15 - x], shift_lo[15 - x]};

	// A background pixel with both pattern bits clear is transparent and shows
	// the universal backdrop colour rather than its own palette entry.
	wire bg_opaque = |bg_bit[1:0];

	wire bg_visible  = mask_bg  && !(!mask_bg_left  && cyc <= 9'd8);
	wire spr_visible = mask_spr && !(!mask_spr_left && cyc <= 9'd8);

	wire bg_show  = bg_visible  && bg_opaque;
	wire spr_show = spr_visible && (spr_pix != 2'b00);

	// Sprite 0 hit: an opaque sprite-zero pixel over an opaque background pixel,
	// with both layers enabled. Games use it to find a scanline, so the x = 255
	// exclusion matters -- hardware never reports it there.
	assign spr0_hit = spr_show && bg_show && spr_zero && visible
	                  && (cur_x != 9'd255) && pixel_en;

	// Priority: an opaque sprite wins unless its priority bit puts it behind,
	// and behind still shows through where the background is transparent.
	wire use_spr = spr_show && (!bg_show || !spr_pri);

	wire [4:0] px_pal = use_spr ? {1'b1, spr_pal, spr_pix}
	                  : bg_show ? {1'b0, bg_bit}
	                            : 5'd0;

	assign pixel_en = visible && (cyc >= 9'd1) && (cyc <= 9'd256);
	// Greyscale forces the low four bits off, collapsing every hue to its grey.
	assign pixel    = mask_grey ? (palette[px_pal] & 6'h30) : palette[px_pal];

endmodule

`default_nettype wire
