//////////////////////////////////////////////////////////////////////////////////
// snes_ppu.v - the SNES's picture chips (PPU1 + PPU2): their registers, VRAM / CGRAM / OAM,
// and a line renderer.
//
// To the model tools/snes/ppu.py, rule for rule (that model matches every still krom PPU
// screenshot), and checked against it line by line: sim/tb_snes_ppu.v replays the PPU
// writes the model saw while running a test ROM (tools/snes/ppurec.py) and compares each
// line the RTL draws with the model's.
//
// --- drawing a line ------------------------------------------------------------------------
// `go` with `line` (1..239) draws that line with the registers as they are: the sprites
// into an OBJ line buffer, each BG layer into its own line buffer (index, palette,
// priority; mode 7 a pixel at a time), then the compositor -- priority, windows, colour
// math, brightness -- into an output line, 512 wide (hi-res and pseudo hi-res put the sub
// screen in the even columns; otherwise each pixel twice). `done` when it is there. Two
// output lines alternate (by line parity): one is drawn while the other is shown.
//
// Budget: a line is 1364 master clocks; at a 50 MHz clock that is ~3170 clocks, and the
// heaviest modes take ~2300.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_ppu (
	input  wire        clk,
	input  wire        rst,
	// the B bus ($2100-$213F; addr = the low byte)
	input  wire        b_wr,
	input  wire        b_rd,
	input  wire [7:0]  b_addr,
	input  wire [7:0]  b_wdata,
	output reg  [7:0]  b_rdata,
	// counters for $2137 / $213C / $213D
	input  wire [10:0] h,
	input  wire [8:0]  v,
	// drawing
	input  wire        go,
	input  wire [8:0]  line,
	input  wire        field,
	output reg         done,
	// showing: a line's pixels, BGR555
	input  wire        rd_buf,
	input  wire [8:0]  rd_x,
	output reg  [14:0] rd_px,
	// the frame's shape, for the system
	output wire        overscan,
	output wire        interlace,
	output wire        force_blank
);
	// =============================================================================
	// registers (ppu.py's write())
	// =============================================================================
	reg [7:0]  inidisp, obsel, bgmode, mosaic, m7sel, cgadd, w12sel, w34sel, wobjsel;
	reg [7:0]  wh0, wh1, wh2, wh3, wbglog, wobjlog, tm, ts, tmw, tsw, cgwsel, cgadsub, setini, vmain;
	reg [8:0]  oamadd;
	reg        oam_pri;
	reg [9:0]  oam_addr;
	reg [7:0]  oam_latch;
	reg [7:0]  bgsc [0:3];
	reg [3:0]  nba [0:3];
	reg [9:0]  hofs [0:3], vofs [0:3];
	reg [7:0]  ofs_latch, hofs_latch, m7_latch;
	reg [15:0] vmadd, vram_read;
	reg [15:0] m7 [0:5];
	reg [12:0] m7hofs, m7vofs;
	reg        cg_flip;
	reg [7:0]  cg_latch;
	reg [14:0] fixed;
	reg [23:0] mpy;
	reg [7:0]  stat77;
	reg [8:0]  hlatch, vlatch;
	reg        hl_flip, vl_flip;
	reg [7:0]  ppu1_mdr, ppu2_mdr;
	assign overscan = setini[2];
	reg        stat_set_range, stat_set_time, stat_clear;
	reg        comp_go, comp_run, comp_fin, blank;
	reg [3:0]  lay_on;                    // which BG layers this line has
	assign interlace = setini[0];
	assign force_blank = inidisp[7];

	// --- the memories --------------------------------------------------------------------
	// VRAM: 32K words; port A the CPU, port B the renderer
	// (a true dual-port block RAM: port A the CPU's writes, with byte enables, and its
	// prefetch reads -- those land two clocks later, and the CPU's accesses are at
	// least 14 apart; port B the renderer)
	(* ram_style = "block" *) reg [15:0] vram [0:32767];
	reg  [14:0] va_a;  reg [1:0] va_we;  reg [15:0] va_d;  reg [15:0] va_q;
	always @(posedge clk) begin
		if (va_we[0]) vram[va_a][7:0]  <= va_d[7:0];
		if (va_we[1]) vram[va_a][15:8] <= va_d[15:8];
		va_q <= vram[va_a];
	end
	reg  [14:0] vr_a;              // the renderer's read address
	reg  [15:0] vr_q;              // its data, a clock later
	always @(posedge clk) vr_q <= vram[vr_a];
	reg  [1:0]  vload;             // a prefetch on its way: vram_read takes va_q when it lands
	// CGRAM: two copies (main and sub screen read at once), and the CPU's reads
	reg  [14:0] cgram [0:255];
	reg  [14:0] cgram2 [0:255];
	// OAM: the low table as 128 words of 32 bits, the high table 32 bytes
	reg  [31:0] oam_lo [0:127];
	reg  [7:0]  oam_hi [0:31];

	// the VRAM address after VMAIN's remapping
	function [14:0] vremap;
		input [15:0] a; input [1:0] m;
		case (m)
		2'd1: vremap = {a[14:8], a[4:0], a[7:5]};
		2'd2: vremap = {a[14:9], a[5:0], a[8:6]};
		2'd3: vremap = {a[14:10], a[6:0], a[9:7]};
		default: vremap = a[14:0];
		endcase
	endfunction
	wire [14:0] vaddr = vremap(vmadd, vmain[3:2]);
	wire [15:0] vinc = (vmain[1:0] == 2'd0) ? 16'd1 : (vmain[1:0] == 2'd1) ? 16'd32 : 16'd128;

	function [15:0] s16; input [15:0] x; s16 = x; endfunction

	// --- CPU reads ----------------------------------------------------------------------------
	reg [31:0] ow;
	always @(*) begin
		b_rdata = ppu1_mdr;
		ow = oam_lo[oam_addr[8:2]];
		case (b_addr)
		8'h34: b_rdata = mpy[7:0];
		8'h35: b_rdata = mpy[15:8];
		8'h36: b_rdata = mpy[23:16];
		8'h38: b_rdata = oam_addr[9] ? oam_hi[oam_addr[4:0]] : ow[oam_addr[1:0]*8 +: 8];
		8'h39: b_rdata = vram_read[7:0];
		8'h3A: b_rdata = vram_read[15:8];
		8'h3B: b_rdata = cg_flip ? {ppu2_mdr[7], cgram[cgadd][14:8]} : cgram[cgadd][7:0];
		8'h3C: b_rdata = hl_flip ? {7'd0, hlatch[8]} : hlatch[7:0];
		8'h3D: b_rdata = vl_flip ? {7'd0, vlatch[8]} : vlatch[7:0];
		8'h3E: b_rdata = stat77 | 8'h01;
		8'h3F: b_rdata = 8'h03;
		default: ;
		endcase
	end

	// --- CPU writes (and the side effects of reads) -------------------------------------------
	integer i;
	reg [23:0] prod;
	always @(posedge clk) begin
		if (rst) begin
			inidisp <= 8'h80; obsel <= 0; oamadd <= 0; oam_pri <= 0; oam_addr <= 0; oam_latch <= 0;
			bgmode <= 0; mosaic <= 0; ofs_latch <= 0; hofs_latch <= 0; m7_latch <= 0;
			vmain <= 0; vmadd <= 0; vram_read <= 0; va_we <= 0; vload <= 0; m7sel <= 0; m7hofs <= 0; m7vofs <= 0;
			cgadd <= 0; cg_flip <= 0; cg_latch <= 0;
			w12sel <= 0; w34sel <= 0; wobjsel <= 0; wh0 <= 0; wh1 <= 0; wh2 <= 0; wh3 <= 0;
			wbglog <= 0; wobjlog <= 0; tm <= 0; ts <= 0; tmw <= 0; tsw <= 0; cgwsel <= 0; cgadsub <= 0;
			fixed <= 0; setini <= 0; mpy <= 0; hlatch <= 0; vlatch <= 0; hl_flip <= 0; vl_flip <= 0;
			ppu1_mdr <= 0; ppu2_mdr <= 0;
			for (i = 0; i < 4; i = i + 1) begin bgsc[i] <= 0; nba[i] <= 0; hofs[i] <= 0; vofs[i] <= 0; end
			for (i = 0; i < 6; i = i + 1) m7[i] <= 0;
		end else begin
			va_we <= 2'b00;
			vload <= {vload[0], 1'b0};
			if (vload[1]) vram_read <= va_q;
			if (b_wr) case (b_addr)
			8'h00: inidisp <= b_wdata;
			8'h01: obsel <= b_wdata;
			8'h02: begin oamadd[7:0] <= b_wdata; oam_addr <= {oamadd[8], b_wdata, 1'b0}; end
			8'h03: begin oamadd[8] <= b_wdata[0]; oam_pri <= b_wdata[7]; oam_addr <= {b_wdata[0], oamadd[7:0], 1'b0}; end
			8'h04: begin
				if (oam_addr[9]) oam_hi[oam_addr[4:0]] <= b_wdata;
				else if (!oam_addr[0]) oam_latch <= b_wdata;
				else begin
					// the pair goes in together: the latched even byte and this one
					case (oam_addr[1])
					1'b0: oam_lo[oam_addr[8:2]][15:0]  <= {b_wdata, oam_latch};
					1'b1: oam_lo[oam_addr[8:2]][31:16] <= {b_wdata, oam_latch};
					endcase
				end
				oam_addr <= oam_addr + 10'd1;
			end
			8'h05: bgmode <= b_wdata;
			8'h06: mosaic <= b_wdata;
			8'h07, 8'h08, 8'h09, 8'h0A: bgsc[b_addr[1:0] + 2'd1] <= b_wdata;   // (7 8 9 A -> 0 1 2 3)
			8'h0B: begin nba[0] <= b_wdata[3:0]; nba[1] <= b_wdata[7:4]; end
			8'h0C: begin nba[2] <= b_wdata[3:0]; nba[3] <= b_wdata[7:4]; end
			8'h0D, 8'h0F, 8'h11, 8'h13: begin
				hofs[(b_addr - 8'h0D) >> 1] <= {b_wdata[1:0], ofs_latch[7:3], hofs_latch[2:0]};
				hofs_latch <= b_wdata; ofs_latch <= b_wdata;
				if (b_addr == 8'h0D) begin m7hofs <= {b_wdata[4:0], m7_latch}; m7_latch <= b_wdata; end
			end
			8'h0E, 8'h10, 8'h12, 8'h14: begin
				vofs[(b_addr - 8'h0E) >> 1] <= {b_wdata[1:0], ofs_latch};
				ofs_latch <= b_wdata;
				if (b_addr == 8'h0E) begin m7vofs <= {b_wdata[4:0], m7_latch}; m7_latch <= b_wdata; end
			end
			8'h15: vmain <= b_wdata;
			8'h16: begin vmadd[7:0] <= b_wdata; va_a <= vremap({vmadd[15:8], b_wdata}, vmain[3:2]); vload <= 2'b01; end
			8'h17: begin vmadd[15:8] <= b_wdata; va_a <= vremap({b_wdata, vmadd[7:0]}, vmain[3:2]); vload <= 2'b01; end
			8'h18: begin va_a <= vaddr; va_d <= {8'h00, b_wdata}; va_we <= 2'b01; if (!vmain[7]) vmadd <= vmadd + vinc; end
			8'h19: begin va_a <= vaddr; va_d <= {b_wdata, 8'h00}; va_we <= 2'b10; if (vmain[7])  vmadd <= vmadd + vinc; end
			8'h1A: m7sel <= b_wdata;
			8'h1B, 8'h1C, 8'h1D, 8'h1E, 8'h1F, 8'h20: begin
				m7[b_addr - 8'h1B] <= {b_wdata, m7_latch};
				m7_latch <= b_wdata;
				// $2134-6: M7A times the high byte of M7B, signed
				if (b_addr == 8'h1B) prod = $signed({b_wdata, m7_latch}) * $signed(m7[1][15:8]);
				else if (b_addr == 8'h1C) prod = $signed(m7[0]) * $signed(b_wdata);
				else prod = $signed(m7[0]) * $signed(m7[1][15:8]);
				mpy <= prod;
			end
			8'h21: begin cgadd <= b_wdata; cg_flip <= 1'b0; end
			8'h22: begin
				if (!cg_flip) cg_latch <= b_wdata;
				else begin
					cgram[cgadd]  <= {b_wdata[6:0], cg_latch};
					cgram2[cgadd] <= {b_wdata[6:0], cg_latch};
					cgadd <= cgadd + 8'd1;
				end
				cg_flip <= !cg_flip;
			end
			8'h23: w12sel <= b_wdata;  8'h24: w34sel <= b_wdata;  8'h25: wobjsel <= b_wdata;
			8'h26: wh0 <= b_wdata;  8'h27: wh1 <= b_wdata;  8'h28: wh2 <= b_wdata;  8'h29: wh3 <= b_wdata;
			8'h2A: wbglog <= b_wdata;  8'h2B: wobjlog <= b_wdata;
			8'h2C: tm <= b_wdata;  8'h2D: ts <= b_wdata;  8'h2E: tmw <= b_wdata;  8'h2F: tsw <= b_wdata;
			8'h30: cgwsel <= b_wdata;  8'h31: cgadsub <= b_wdata;
			8'h32: begin
				if (b_wdata[5]) fixed[4:0]   <= b_wdata[4:0];
				if (b_wdata[6]) fixed[9:5]   <= b_wdata[4:0];
				if (b_wdata[7]) fixed[14:10] <= b_wdata[4:0];
			end
			8'h33: setini <= b_wdata;
			default: ;
			endcase
			if (b_rd) case (b_addr)
			8'h34, 8'h35, 8'h36: ppu1_mdr <= b_rdata;
			8'h37: begin hlatch <= h[10:2]; vlatch <= v; end
			8'h38: begin oam_addr <= oam_addr + 10'd1; ppu1_mdr <= b_rdata; end
			8'h39, 8'h3A: begin
				ppu1_mdr <= b_rdata;
				if ((b_addr == 8'h3A) == vmain[7]) begin va_a <= vaddr; vload <= 2'b01; vmadd <= vmadd + vinc; end
			end
			8'h3B: begin ppu2_mdr <= b_rdata; if (cg_flip) cgadd <= cgadd + 8'd1; cg_flip <= !cg_flip; end
			8'h3C: hl_flip <= !hl_flip;
			8'h3D: vl_flip <= !vl_flip;
			8'h3F: begin hl_flip <= 1'b0; vl_flip <= 1'b0; end
			default: ;
			endcase
			if (stat_set_range) stat77[6] <= 1'b1;
			if (stat_set_time)  stat77[7] <= 1'b1;
			if (stat_clear)     stat77 <= 8'h00;
		end
	end

	// =============================================================================
	// the renderer
	// =============================================================================
	wire [2:0] mode = bgmode[2:0];
	wire       hires = (mode == 3'd5) || (mode == 3'd6);
	wire       extbg = (mode == 3'd7) && setini[6];
	wire [7:0] used = tm | ts;
	// bits per pixel of BG n in this mode (0: none)
	function [3:0] bpp_of;
		input [2:0] m; input [1:0] n;
		case (m)
		3'd0: bpp_of = 4'd2;
		3'd1: bpp_of = (n == 2'd2) ? 4'd2 : (n == 2'd3) ? 4'd0 : 4'd4;
		3'd2: bpp_of = (n < 2'd2) ? 4'd4 : 4'd0;
		3'd3: bpp_of = (n == 2'd0) ? 4'd8 : (n == 2'd1) ? 4'd4 : 4'd0;
		3'd4: bpp_of = (n == 2'd0) ? 4'd8 : (n == 2'd1) ? 4'd2 : 4'd0;
		3'd5: bpp_of = (n == 2'd0) ? 4'd4 : (n == 2'd1) ? 4'd2 : 4'd0;
		3'd6: bpp_of = (n == 2'd0) ? 4'd4 : 4'd0;
		default: bpp_of = 4'd0;                                   // (mode 7 apart)
		endcase
	endfunction


	// --- the line buffers ---------------------------------------------------------------------
	// BG layers: {pixel index 8, palette 3, priority 1}, 512 wide; written by the fetcher,
	// read twice at once by the compositor (main and sub columns)
	// (four dual-port block RAMs: the fetcher writes through port A a clock after it
	// decides; the compositor reads the main column on A and the sub column on B)
	reg  [3:0]  lw_en;  reg [8:0] lw_a;  reg [11:0] lw_d0, lw_d1;
	wire [11:0] c_lm [0:3], c_ls [0:3];
	reg  [8:0]  cmp_xm [0:3], cmp_xs [0:3];
	genvar gl;
	generate for (gl = 0; gl < 4; gl = gl + 1) begin : g_lay
		snes_lbuf u_l (.clk(clk), .a_we(lw_en[gl] && !comp_run), .a_a(comp_run ? cmp_xm[gl] : lw_a),
		               .a_d(gl == 1 ? lw_d1 : lw_d0), .a_q(c_lm[gl]), .b_a(cmp_xs[gl]), .b_q(c_ls[gl]));
	end endgenerate
	// OBJ: {colour index 8 (128 + palette * 16 + pixel), priority 2, the line's tag 1}
	reg [10:0] objb [0:255];
	reg        tag;                      // which line wrote an OBJ entry: others are empty
	// output: two lines of 256 pairs {even, odd}
	reg [29:0] outb [0:511];
	always @(posedge clk) begin
		rd_px <= rd_x[0] ? outb[{rd_buf, rd_x[8:1]}][29:15] : outb[{rd_buf, rd_x[8:1]}][14:0];
	end

	// --- the line's state -----------------------------------------------------------------------
	localparam [4:0]
		R_IDLE = 5'd0, R_START = 5'd1,
		R_OE = 5'd2, R_OE2 = 5'd3,              // OBJ: evaluate the 128 entries
		R_OF = 5'd4, R_OF1 = 5'd5, R_OF2 = 5'd6, R_OF3 = 5'd7, R_OW = 5'd8,  // fetch and draw slivers
		R_BG = 5'd9,                           // next layer
		R_BX = 5'd10, R_BMAP = 5'd11, R_BMAP2 = 5'd12, R_BCH = 5'd13, R_BCH2 = 5'd14,
		R_OPT1 = 5'd15, R_OPT2 = 5'd16, R_OPT3 = 5'd17, R_OPT4 = 5'd18,
		R_M7 = 5'd19, R_M7B = 5'd20, R_M7C = 5'd21,
		R_COMP = 5'd22, R_DONE = 5'd23, R_YMOS = 5'd24, R_BLANK = 5'd25, R_M7D = 5'd26;
	reg [4:0]  rs;
	reg [8:0]  ln;                       // the line
	reg        fld;
	reg        obuf;                     // the output line this goes to

	// ---------- sprites ----------
	reg [6:0]  ok;                       // the entry being looked at (0..127 from `first`)
	reg [7:0]  ok_n;
	reg [5:0]  nfound;
	reg [6:0]  f_idx [0:31];
	reg [5:0]  f_dy  [0:31];
	reg        f_big [0:31];
	reg [5:0]  fi;                       // which found sprite is being fetched (counting down)
	reg [3:0]  tc;                       // its tile column
	reg [5:0]  ntiles;
	reg [31:0] so;                       // its OAM word
	reg [1:0]  sh;                       // its high bits
	reg [15:0] sp01, sp23;
	reg [2:0]  ow_k;
	reg [9:0]  sx;                       // the sliver's left x (signed 10)

	// the sizes by OBSEL (small, large): w, h in pixels / 8
	function [3:0] osz;                  // {w8[1:0]... } -> returns width/8 - 1 in [1:0]? use full
		input [2:0] sel; input big; input wh;   // wh 0: width, 1: height; result in 8-pixel units
		reg [3:0] s, l, sh_, lh;
		begin
			case (sel)
			3'd0: begin s = 1; sh_ = 1; l = 2; lh = 2; end
			3'd1: begin s = 1; sh_ = 1; l = 4; lh = 4; end
			3'd2: begin s = 1; sh_ = 1; l = 8; lh = 8; end
			3'd3: begin s = 2; sh_ = 2; l = 4; lh = 4; end
			3'd4: begin s = 2; sh_ = 2; l = 8; lh = 8; end
			3'd5: begin s = 4; sh_ = 4; l = 8; lh = 8; end
			3'd6: begin s = 2; sh_ = 4; l = 4; lh = 8; end
			default: begin s = 2; sh_ = 4; l = 4; lh = 4; end
			endcase
			osz = big ? (wh ? lh : l) : (wh ? sh_ : s);
		end
	endfunction

	// ---------- BG ----------
	reg [1:0]  ly;                       // the layer
	reg [9:0]  bx;                       // its column (0..width-1)
	reg [9:0]  bw;                       // its width
	reg [3:0]  bbpp;
	reg [10:0] by;                       // its line (after mosaic / interlace)
	reg [9:0]  ho, vo;                   // its scroll for this column (offset-per-tile)
	reg [7:0]  opt_col;                  // the column the offsets are for
	reg [15:0] me;                       // the map entry in hand
	reg [14:0] me_a;                     // its address
	reg        me_ok;
	reg [14:0] ch_a;                     // the char row in hand: its first word's address
	reg        ch_ok;
	reg [15:0] cw [0:3];                 // its words (planes 0/1, 2/3, 4/5, 6/7)
	reg [1:0]  cwk;
	reg [15:0] opt_h, opt_v;
	reg [4:0]  ymos_cnt;
	reg [8:0]  ymos_r;

	// ---------- mode 7 ----------
	reg signed [31:0] m7bx, m7by;
	reg [8:0]  m7x;
	reg [4:0]  m7rem;                    // m7x % the mosaic size, kept as m7x steps (no divider)
	reg signed [31:0] m7pa, m7pc;        // A and C times the column, a clock ahead of the sums
	reg [7:0]  m7tile;
	reg        m7ovr;

	// ---------- compositor ----------
	reg [8:0]  cx;

	// per-layer pixel index of BG n at column x (decoded from cw by plane)
	function [7:0] pix_of;
		input [15:0] w0, w1, w2, w3; input [3:0] bp; input [2:0] fx;   // fx: 0 = leftmost
		reg [2:0] b;
		begin
			b = 3'd7 - fx;
			pix_of = {w3[8 + b], w3[b], w2[8 + b], w2[b], w1[8 + b], w1[b], w0[8 + b], w0[b]};
			if (bp == 4'd2) pix_of = {6'd0, pix_of[1:0]};
			else if (bp == 4'd4) pix_of = {4'd0, pix_of[3:0]};
		end
	endfunction

	// the map address of tile (tx, ty) in a BG with screen-select sc
	function [14:0] map_addr;
		input [7:0] sc; input [5:0] mx, my;
		reg [15:0] a;
		begin
			a = {sc[7:2], 10'd0} + {6'd0, my[4:0], mx[4:0]};
			if (mx[5] && sc[0]) a = a + 16'h0400;
			if (my[5] && sc[1]) a = a + (sc[0] ? 16'h0800 : 16'h0400);
			map_addr = a[14:0];
		end
	endfunction

	// --- the BG column in work: what it needs (combinational) ---------------------------------
	wire [4:0] mos_n = {1'b0, mosaic[7:4]} + 5'd1;
	wire       big = bgmode[4 + ly];
	wire [4:0] tw = (big || hires) ? 5'd16 : 5'd8;
	wire [4:0] th = big ? 5'd16 : 5'd8;
	wire       opt = (mode == 3'd2 || mode == 3'd4 || mode == 3'd6) && !ly[1];
	wire [9:0] sx_b = bx;                         // (the x mosaic is the compositor's)
	wire [7:0] col256 = hires ? sx_b[9:1] : sx_b[7:0];
	wire [7:0] opt_c = (col256 + {5'd0, hofs[ly][2:0]}) >> 3;    // the offset column
	wire [11:0] px_b = hires ? ({2'b0, sx_b} + {1'b0, ho, 1'b0}) : ({2'b0, sx_b} + {2'b0, ho});
	wire [11:0] py_b = {1'b0, by} + {2'b0, vo};
	wire [6:0] tx_b = (tw == 5'd16) ? px_b[10:4] : px_b[9:3];
	wire [6:0] ty_b = (th == 5'd16) ? py_b[10:4] : py_b[9:3];
	wire [14:0] me_want = map_addr(bgsc[ly], tx_b[5:0], ty_b[5:0]);
	wire [3:0] fx_raw = (tw == 5'd16) ? px_b[3:0] : {1'b0, px_b[2:0]};
	wire [3:0] fy_raw = (th == 5'd16) ? py_b[3:0] : {1'b0, py_b[2:0]};
	wire [3:0] fx_b = me[14] ? ((tw == 5'd16) ? 4'd15 - fx_raw : 4'd7 - fx_raw) : fx_raw;
	wire [3:0] fy_b = me[15] ? ((th == 5'd16) ? 4'd15 - fy_raw : 4'd7 - fy_raw) : fy_raw;
	wire [9:0] chn = me[9:0] + ((tw == 5'd16 && fx_b[3]) ? 10'd1 : 10'd0) + ((th == 5'd16 && fy_b[3]) ? 10'd16 : 10'd0);
	wire [14:0] ch_want = {nba[ly], 12'd0} + chn * {bbpp, 2'b00} + {12'd0, fy_b[2:0]};   // (words: 4 * bpp a tile)
	wire [1:0] ch_words = (bbpp == 4'd2) ? 2'd0 : (bbpp == 4'd4) ? 2'd1 : 2'd3;

	// --- the compositor's pixel (combinational over the reads in hand) --------------------------
	// reads issued a clock before: c_lm[n] / c_ls[n] (main / sub column), c_ob
	reg [10:0] c_ob;
	reg [8:0]  c_x;                      // the screen column they are for
	reg        c_v;                      // valid

	// window test for a layer: sel4 / log2 at x
	function win;
		input [3:0] sel; input [1:0] lg; input [7:0] x; input [7:0] l1, r1, l2, r2;
		reg w1, w2, e1, e2;
		begin
			e1 = sel[1]; e2 = sel[3];
			w1 = (x >= l1 && x <= r1) ^ sel[0];
			w2 = (x >= l2 && x <= r2) ^ sel[2];
			if (!e1 && !e2) win = 1'b0;
			else if (!e1) win = w2;
			else if (!e2) win = w1;
			else case (lg)
				2'd0: win = w1 | w2;
				2'd1: win = w1 & w2;
				2'd2: win = w1 ^ w2;
				default: win = ~(w1 ^ w2);
			endcase
		end
	endfunction

	// rank of an entry in this mode's front-to-back order (smaller in front; 31: absent)
	// entries: S0..S3 = 0..3, B(n, p) = 4 + n * 2 + p
	function [4:0] rank;
		input [2:0] m; input b3; input ext; input [3:0] e;
		begin
			rank = 5'd31;
			case (m)
			3'd0: case (e)
				4'd3: rank = 0; 4'd5: rank = 1; 4'd7: rank = 2; 4'd2: rank = 3; 4'd4: rank = 4; 4'd6: rank = 5;
				4'd1: rank = 6; 4'd9: rank = 7; 4'd11: rank = 8; 4'd0: rank = 9; 4'd8: rank = 10; 4'd10: rank = 11;
				default: ; endcase
			3'd1: if (b3) case (e)
				4'd9: rank = 0; 4'd3: rank = 1; 4'd5: rank = 2; 4'd7: rank = 3; 4'd2: rank = 4; 4'd4: rank = 5;
				4'd6: rank = 6; 4'd1: rank = 7; 4'd0: rank = 8; 4'd8: rank = 9;
				default: ; endcase
			else case (e)
				4'd3: rank = 0; 4'd5: rank = 1; 4'd7: rank = 2; 4'd2: rank = 3; 4'd4: rank = 4; 4'd6: rank = 5;
				4'd1: rank = 6; 4'd9: rank = 7; 4'd0: rank = 8; 4'd8: rank = 9;
				default: ; endcase
			3'd6: case (e)
				4'd3: rank = 0; 4'd5: rank = 1; 4'd2: rank = 2; 4'd1: rank = 3; 4'd4: rank = 4; 4'd0: rank = 5;
				default: ; endcase
			3'd7: if (ext) case (e)
				4'd3: rank = 0; 4'd2: rank = 1; 4'd7: rank = 2; 4'd1: rank = 3; 4'd4: rank = 4; 4'd0: rank = 5; 4'd6: rank = 6;
				default: ; endcase
			else case (e)
				4'd3: rank = 0; 4'd2: rank = 1; 4'd1: rank = 2; 4'd4: rank = 3; 4'd0: rank = 4;
				default: ; endcase
			default: case (e)              // 2..5
				4'd3: rank = 0; 4'd5: rank = 1; 4'd2: rank = 2; 4'd7: rank = 3; 4'd1: rank = 4; 4'd4: rank = 5;
				4'd0: rank = 6; 4'd6: rank = 7;
				default: ; endcase
			endcase
		end
	endfunction

	// the colour of BG n's pixel
	function [14:0] bgcol;
		input [2:0] m; input [1:0] n; input [11:0] e; input dir;
		input [14:0] c0;                        // cgram at the index below (looked up outside)
		reg [3:0] bp; reg [7:0] p; reg [2:0] pal;
		begin
			p = e[11:4]; pal = e[3:1];
			bp = (m == 3'd7) ? ((n == 2'd1) ? 4'd7 : 4'd8) : bpp_of(m, n);
			if (bp == 4'd8 && dir)
				bgcol = {p[7:6], pal[2], 2'b00, p[5:3], pal[1], 1'b0, p[2:0], pal[0], 1'b0};
			else bgcol = c0;
		end
	endfunction
	// its CGRAM index
	function [7:0] bgidx;
		input [2:0] m; input [1:0] n; input [11:0] e;
		reg [3:0] bp; reg [7:0] p; reg [2:0] pal;
		begin
			p = e[11:4]; pal = e[3:1];
			bp = (m == 3'd7) ? 4'd8 : bpp_of(m, n);
			if (m == 3'd7) bgidx = p;
			else if (bp == 4'd2) bgidx = ((m == 3'd0) ? {1'b0, n, 5'd0} : 8'd0) + {3'd0, pal, p[1:0]};
			else if (bp == 4'd4) bgidx = {1'b0, pal, p[3:0]};
			else bgidx = p;
		end
	endfunction

	function [14:0] blend;
		input [14:0] a, b; input sub, half;
		reg signed [6:0] c;
		integer k;
		begin
			for (k = 0; k < 3; k = k + 1) begin
				if (sub) begin
					c = $signed({2'b00, a[k*5 +: 5]}) - $signed({2'b00, b[k*5 +: 5]});
					if (half) c = c >>> 1;
					if (c < 0) c = 0;
				end else begin
					c = {2'b00, a[k*5 +: 5]} + {2'b00, b[k*5 +: 5]};
					if (half) c = c >>> 1;
					if (c > 31) c = 31;
				end
				blend[k*5 +: 5] = c[4:0];
			end
		end
	endfunction
	function [14:0] bright;
		input [14:0] c; input [3:0] b;
		integer k;
		reg [8:0] t;
		begin
			for (k = 0; k < 3; k = k + 1) begin
				t = {4'd0, c[k*5 +: 5]} * ({5'd0, b} + 9'd1);
				bright[k*5 +: 5] = (b == 4'd15) ? c[k*5 +: 5] : t[8:4];
			end
		end
	endfunction

	// --- composing one screen column (from the reads in hand) ----------------------------------
	reg  [4:0]  bestm, bests;
	reg  [3:0]  em, es;                      // the winning entry (main / sub); 12: backdrop
	reg  [11:0] lv;
	reg  [3:0]  ee;
	reg  [7:0]  cidx_m, cidx_s;
	reg         mobj;
	reg  [14:0] mc, scol, raw, mres, sp, prev_raw;
	reg         prev_on, sub_bd, clip, noblend, math_on, cw_in, have_prev;
	reg  [4:0]  rk;
	integer     q;
	wire [7:0]  cxo = c_x[7:0];
	wire        split = hires || (setini[3] && !hires);
	wire        dirc = cgwsel[0] && (mode == 3'd3 || mode == 3'd4 || mode == 3'd7);

	// one pick: the front entry among the enabled, unwindowed layers
	task pick;
		input [7:0] en, wm; input main;
		output [3:0] wine; output [7:0] widx;
		reg [4:0] best;
		reg [11:0] e;
		reg [10:0] o;
		begin
			best = 5'd31; wine = 4'd12; widx = 8'd0;
			o = c_ob;
			// sprites
			if (en[4] && o[10:3] != 8'd0 &&
			    !(wm[4] && win(wobjsel[3:0], wobjlog[1:0], cxo, wh0, wh1, wh2, wh3))) begin
				rk = rank(mode, bgmode[3], extbg, {2'b00, o[2:1]});
				if (rk < best) begin best = rk; wine = {2'b00, o[2:1]}; widx = o[10:3]; end
			end
			for (q = 0; q < 4; q = q + 1) begin
				e = main ? c_lm[q] : c_ls[q];
				if (en[q] && lay_on[q] && e[11:4] != 8'd0 &&
				    !(wm[q] && win(q == 0 ? w12sel[3:0] : q == 1 ? w12sel[7:4] : q == 2 ? w34sel[3:0] : w34sel[7:4],
				                   wbglog[q*2 +: 2], cxo, wh0, wh1, wh2, wh3))) begin
					rk = rank(mode, bgmode[3], extbg, 4'd4 + q * 2 + {3'd0, e[0]});
					if (rk < best) begin best = rk; wine = 4'd4 + q; widx = bgidx(mode, q, e); end
				end
			end
		end
	endtask

	reg [14:0] colm, cols;
	reg [11:0] em_e, es_e;
	reg [7:0]  ixm, ixs;
	// (the compositor's later stages: 2 the pick, 3 the colours, 4 the maths)
	reg        p_v, q_v;
	reg [8:0]  p_x, q_x;
	reg [3:0]  p_em, p_es;
	reg [7:0]  p_ixm, p_ixs;
	reg [11:0] p_eme, p_ese;
	reg        p_clip, p_noblend, p_math, q_clip, q_noblend, q_math, q_subbd;
	reg [14:0] q_colm, q_cols, q_sub0;

	// the mosaic remainder's next value, for a column one on
	function [4:0] m7next;
		input [4:0] r; input [3:0] msz;
		begin
			m7next = (r + 5'd1 >= {1'b0, msz} + 5'd1) ? 5'd0 : r + 5'd1;
		end
	endfunction

	always @(posedge clk) begin
		done <= 1'b0;
		comp_go <= 1'b0;
		lw_en <= 4'd0;
		stat_set_range <= 1'b0; stat_set_time <= 1'b0; stat_clear <= 1'b0;
		if (rst) begin
			rs <= R_IDLE; tag <= 1'b0;
		end else begin
			case (rs)
			R_IDLE: if (go) begin
				ln <= line; fld <= field; obuf <= line[0];
				tag <= !tag;
				if (line == 9'd1) stat_clear <= 1'b1;
				rs <= inidisp[7] ? R_BLANK : R_START;
				cx <= 9'd0;
			end
			R_BLANK: begin comp_go <= 1'b1; rs <= R_DONE; end     // forced blank: the compositor writes black
			R_START: begin
				lay_on <= 4'd0;
				ok <= oam_pri ? oamadd[7:1] : 7'd0; ok_n <= 8'd0; nfound <= 6'd0;
				rs <= used[4] ? R_OE : R_BG;
				ly <= 2'd0;
			end

			// ---------- sprites: which are on the line ----------
			R_OE: begin
				objb[{ok_n[6:0], 1'b0}] <= 11'd0;          // (clearing the line as we go: 2 a step)
				so <= oam_lo[ok];
				sh <= oam_hi[ok[6:2]][ok[1:0]*2 +: 2];
				rs <= R_OE2;
			end
			R_OE2: begin : oe2
				reg [8:0] xx; reg signed [10:0] xs; reg [7:0] dy; reg [3:0] w8, h8; reg [6:0] hh; reg skip;
				w8 = osz(obsel[7:5], sh[1], 1'b0); h8 = osz(obsel[7:5], sh[1], 1'b1);
				xx = {sh[0], so[7:0]};
				xs = xx[8] ? $signed({2'b11, xx}) : $signed({2'b00, xx});   // (>= 256: x - 512)
				dy = ln[7:0] - 8'd1 - so[15:8];
				hh = {h8, 3'd0};
				skip = 1'b0;
				if (setini[1]) begin
					if ({1'b0, dy} >= {1'b0, hh[6:1]}) skip = 1'b1;
					dy = {dy[6:0], 1'b0} | {7'd0, fld};
				end
				if ({1'b0, dy} >= {1'b0, hh}) skip = 1'b1;
				if ((xs <= -$signed({7'd0, w8, 3'd0}) || xs >= 11'sd256) && xx != 9'h100) skip = 1'b1;
				objb[{ok_n[6:0], 1'b1}] <= 11'd0;
				// (all 128 are looked at, so the whole line is cleared; past 32 found it only
				// raises range-over, as the chip -- and the model -- stop there)
				if (!skip) begin
					if (nfound == 6'd32) stat_set_range <= 1'b1;
					else begin
						f_idx[nfound] <= ok; f_dy[nfound] <= dy[5:0]; f_big[nfound] <= sh[1];
						nfound <= nfound + 6'd1;
					end
				end
				ok <= ok + 7'd1; ok_n <= ok_n + 8'd1;
				if (ok_n == 8'd127) begin
					fi <= (!skip && nfound != 6'd32) ? nfound : nfound - 6'd1;
					ntiles <= 6'd0; tc <= 4'd0;
					rs <= ((!skip && nfound != 6'd32) || nfound != 6'd0) ? R_OF : R_BG;
				end else rs <= R_OE;
			end

			// ---------- sprites: their slivers, the last found first ----------
			R_OF: begin
				so <= oam_lo[f_idx[fi]];
				sh <= oam_hi[f_idx[fi][6:2]][f_idx[fi][1:0]*2 +: 2];
				rs <= R_OF1;
			end
			R_OF1: begin : of1
				reg [8:0] xx; reg signed [10:0] xs, sxs; reg [3:0] w8, h8; reg [6:0] row; reg [3:0] col;
				reg [8:0] name; reg [3:0] r_, c_; reg [15:0] a;
				w8 = osz(obsel[7:5], sh[1], 1'b0); h8 = osz(obsel[7:5], sh[1], 1'b1);
				xx = {sh[0], so[7:0]};
				xs = xx[8] ? $signed({2'b11, xx}) : $signed({2'b00, xx});
				sxs = xs + $signed({4'd0, tc, 3'd0});
				row = so[31] ? ({h8, 3'd0} - 7'd1 - {1'b0, f_dy[fi]}) : {1'b0, f_dy[fi]};
				col = so[30] ? (w8 - 4'd1 - tc) : tc;
				name = {so[24], so[23:16]};
				r_ = name[7:4] + row[6:3];
				c_ = name[3:0] + col;
				a = {obsel[2:0], 13'd0} + {4'd0, r_, c_, 4'd0} + (name[8] ? {1'b0, obsel[4:3] + 2'd1, 12'd0} : 16'd0) + {13'd0, row[2:0]};
				sx <= sxs[9:0];
				if (tc == w8) begin                                   // this sprite is done
					tc <= 4'd0;
					if (fi == 6'd0) rs <= R_BG;
					else begin fi <= fi - 6'd1; rs <= R_OF; end
				end else if (sxs <= -11'sd8 || sxs >= 11'sd256) begin   // off the line
					tc <= tc + 4'd1;
				end else if (ntiles == 6'd34) begin                   // out of time
					stat_set_time <= 1'b1;
					rs <= R_BG;
				end else begin
					ntiles <= ntiles + 6'd1;
					vr_a <= a[14:0]; ch_a <= a[14:0] + 15'd8;
					rs <= R_OF2;
				end
			end
			R_OF2: begin vr_a <= ch_a; rs <= R_OF3; end           // planes 2/3
			R_OF3: begin sp01 <= vr_q; ow_k <= 3'd0; rs <= R_OW; end
			R_OW: begin : ow_
				reg [2:0] fx; reg [3:0] p; reg signed [10:0] xx2; reg [15:0] w23;
				w23 = (ow_k == 3'd0) ? vr_q : sp23;
				if (ow_k == 3'd0) sp23 <= vr_q;
				fx = so[30] ? 3'd7 - ow_k : ow_k;
				p = {w23[8 + 7 - fx], w23[7 - fx], sp01[8 + 7 - fx], sp01[7 - fx]};
				xx2 = $signed({sx[9], sx}) + $signed({8'd0, ow_k});
				if (p != 4'd0 && xx2 >= 0 && xx2 < 256)
					objb[xx2[7:0]] <= {1'b1, so[27:25], p, so[29:28], tag};
				ow_k <= ow_k + 3'd1;
				if (ow_k == 3'd7) begin tc <= tc + 4'd1; rs <= R_OF1; end
			end

			// ---------- BG layers ----------
			R_BG: begin
				if (mode == 3'd7) begin
					if (used[0] || (extbg && used[1])) begin
						lay_on <= {2'b00, extbg, 1'b1};
						rs <= R_YMOS; ly <= 2'd0;
					end else rs <= R_COMP;
				end else if (ly == 2'd3 && !(bpp_of(mode, ly) != 0 && used[ly])) begin
					rs <= R_COMP;
				end else if (bpp_of(mode, ly) != 0 && used[ly]) begin
					lay_on[ly] <= 1'b1;
					bbpp <= bpp_of(mode, ly);
					bw <= hires ? 10'd512 : 10'd256;
					rs <= R_YMOS;
				end else ly <= ly + 2'd1;
				cx <= 9'd0;
				ymos_cnt <= 5'd0;
			end
			// the line after the vertical mosaic: y - (y - 1) % size, by subtraction
			R_YMOS: begin : ym
				reg [4:0] mz; reg mon;
				mz = {1'b0, mosaic[7:4]} + 5'd1;
				mon = (mode == 3'd7) ? mosaic[0] : mosaic[ly];
				if (ymos_cnt == 5'd0) ymos_r <= ln - 9'd1;
				ymos_cnt <= 5'd1;
				if (ymos_cnt != 5'd0) begin
					if (mon && mz != 5'd1 && ymos_r >= {4'd0, mz}) ymos_r <= ymos_r - {4'd0, mz};
					else begin
						by <= (mon && mz != 5'd1) ? {2'b0, ln - ymos_r} : {2'b0, ln};
						if (mode == 3'd7) begin m7x <= 9'd0; m7rem <= 5'd0; rs <= R_M7; end
						else begin
							bx <= 10'd0; me_ok <= 1'b0; ch_ok <= 1'b0;
							opt_col <= 8'hFF;
							ho <= hofs[ly]; vo <= vofs[ly];
							rs <= R_BX;
						end
					end
				end
			end
			R_BX: begin
				// interlace (hi-res): 448 BG rows
				if (hires && setini[0] && by[10:9] == 2'b00 && ymos_cnt == 5'd1) begin
					by <= {by[9:0], fld}; ymos_cnt <= 5'd2;
				end else if (opt && opt_c != opt_col) begin
					// offset-per-tile: this column's scroll from BG3's map
					opt_col <= opt_c;
					if (opt_c == 8'd0) begin ho <= hofs[ly]; vo <= vofs[ly]; end
					else begin
						vr_a <= map_addr(bgsc[2], (({opt_c - 8'd1, 3'd0} + {1'b0, hofs[2][9:3], 3'd0}) >> 3), vofs[2][9:3]);
						rs <= R_OPT1;
					end
				end else if (!me_ok || me_a != me_want) begin
					vr_a <= me_want; me_a <= me_want; rs <= R_BMAP;
				end else if (!ch_ok || ch_a != ch_want) begin
					vr_a <= ch_want; ch_a <= ch_want; cwk <= 2'd0; rs <= R_BCH;
				end else begin
					lw_en <= 4'd1 << ly; lw_a <= bx[8:0];
					lw_d0 <= {pix_of(cw[0], cw[1], cw[2], cw[3], bbpp, fx_b[2:0]), me[12:10], me[13]};
					lw_d1 <= {pix_of(cw[0], cw[1], cw[2], cw[3], bbpp, fx_b[2:0]), me[12:10], me[13]};
					bx <= bx + 10'd1;
					if (bx == bw - 10'd1) begin ly <= ly + 2'd1; rs <= (ly == 2'd3) ? R_COMP : R_BG; end
				end
			end
			R_BMAP: rs <= R_BMAP2;
			R_BMAP2: begin me <= vr_q; me_ok <= 1'b1; ch_ok <= 1'b0; rs <= R_BX; end
			R_BCH: begin
				// words 0 / 8 / 16 / 24 from the row: planes 0-1, 2-3, 4-5, 6-7
				vr_a <= ch_a + {cwk + 2'd1, 3'd0};
				rs <= R_BCH2;
			end
			R_BCH2: begin
				cw[cwk] <= vr_q;
				if (cwk == ch_words) begin ch_ok <= 1'b1; rs <= R_BX; if (bbpp == 4'd2) begin cw[1] <= 16'd0; end
				                           if (bbpp != 4'd8) begin cw[2] <= 16'd0; cw[3] <= 16'd0; end end
				else begin cwk <= cwk + 2'd1; vr_a <= ch_a + {cwk + 2'd2, 3'd0}; end
			end
			R_OPT1: rs <= R_OPT2;
			R_OPT2: begin
				opt_h <= vr_q;
				vr_a <= map_addr(bgsc[2], (({opt_col - 8'd1, 3'd0} + {1'b0, hofs[2][9:3], 3'd0}) >> 3), vofs[2][9:3] + 6'd1);
				rs <= R_OPT3;
			end
			R_OPT3: rs <= R_OPT4;
			R_OPT4: begin : o4
				reg [15:0] eh, ev; reg [15:0] bitn;
				eh = opt_h; ev = vr_q;
				bitn = ly[0] ? 16'h4000 : 16'h2000;
				ho <= hofs[ly]; vo <= vofs[ly];
				if (mode == 3'd4) begin
					if (eh & bitn) begin
						if (eh[15]) vo <= eh[9:0];
						else ho <= {eh[9:3], hofs[ly][2:0]};
					end
				end else begin
					if (eh & bitn) ho <= {eh[9:3], hofs[ly][2:0]};
					if (ev & bitn) vo <= ev[9:0];
				end
				me_ok <= 1'b0;
				rs <= R_BX;
			end

			// ---------- mode 7: a pixel at a time (the tile byte, then the pixel byte) ----------
			R_M7: begin : m7s
				reg signed [15:0] a_, b_, c_, d_; reg signed [13:0] x0, y0, ch_, cv_, hofs_, vofs_;
				reg signed [14:0] dh, dv; reg [8:0] sy;
				reg signed [31:0] t1, t2, t3;
				a_ = m7[0]; b_ = m7[1]; c_ = m7[2]; d_ = m7[3];
				x0 = {m7[4][12], m7[4][12:0]}; y0 = {m7[5][12], m7[5][12:0]};
				hofs_ = {m7hofs[12], m7hofs}; vofs_ = {m7vofs[12], m7vofs};
				dh = hofs_ - x0; dv = vofs_ - y0;
				ch_ = dh[13] ? {4'b1111, dh[9:0]} : {4'b0000, dh[9:0]};
				cv_ = dv[13] ? {4'b1111, dv[9:0]} : {4'b0000, dv[9:0]};
				sy = m7sel[1] ? 9'd255 - by[8:0] : by[8:0];
				t1 = ((a_ * ch_) & ~32'sd63) + ((b_ * cv_) & ~32'sd63) + ((b_ * $signed({1'b0, sy})) & ~32'sd63) + (x0 <<< 8);
				t2 = ((c_ * ch_) & ~32'sd63) + ((d_ * cv_) & ~32'sd63) + ((d_ * $signed({1'b0, sy})) & ~32'sd63) + (y0 <<< 8);
				m7bx <= t1; m7by <= t2;
				rs <= R_M7B; m7x <= 9'd0; m7rem <= 5'd0; cx <= 9'd0;
			end
			R_M7B: begin : m7b
				reg [7:0] sxm; reg [4:0] mz;
				mz = {1'b0, mosaic[7:4]} + 5'd1;
				sxm = (mosaic[0] && mz != 5'd1) ? (m7x[7:0] - {3'd0, m7rem}) : m7x[7:0];
				if (m7sel[0]) sxm = 8'd255 - sxm;
				m7pa <= $signed(m7[0]) * $signed({1'b0, sxm});
				m7pc <= $signed(m7[2]) * $signed({1'b0, sxm});
				rs <= R_M7D;
			end
			R_M7D: begin : m7d
				reg signed [31:0] X, Y;
				X = (m7bx + m7pa) >>> 8;
				Y = (m7by + m7pc) >>> 8;
				m7ovr <= ((X | Y) & ~32'sd1023) != 0;
				if (((X | Y) & ~32'sd1023) != 0 && m7sel[7:6] == 2'd2) begin
					lw_en <= 4'b0011; lw_a <= m7x; lw_d0 <= 12'd0; lw_d1 <= 12'd0;
					m7x <= m7x + 9'd1; m7rem <= m7next(m7rem, mosaic[7:4]);
					rs <= (m7x == 9'd255) ? R_COMP : R_M7B;
				end else begin
					if (((X | Y) & ~32'sd1023) != 0 && m7sel[7:6] == 2'd3) vr_a <= 15'd0;
					else vr_a <= {1'b0, Y[9:3], X[9:3]};
					m7tile <= {X[2:0], Y[2:0], 2'b00};    // (the pixel's place, kept)
					rs <= R_M7C;
				end
			end
			R_M7C: begin
				// VRAM answers a clock after its address is in: 0 wait, 1 the tile number
				// (low byte) is here -> the pixel's address, 2 wait, 3 the pixel (high byte)
				if (cx == 9'd1)
					vr_a <= (m7ovr && m7sel[7:6] == 2'd3) ? {7'd0, m7tile[4:2], m7tile[7:5]} :
					        {vr_q[7:0], m7tile[4:2], m7tile[7:5]};
				if (cx == 9'd3) begin
					lw_en <= 4'b0011; lw_a <= m7x;
					lw_d0 <= {vr_q[15:8], 4'd0};
					lw_d1 <= {1'b0, vr_q[14:8], 3'd0, vr_q[15]};
					cx <= 9'd0;
					m7x <= m7x + 9'd1; m7rem <= m7next(m7rem, mosaic[7:4]);
					rs <= (m7x == 9'd255) ? R_COMP : R_M7B;
				end else cx <= cx + 9'd1;
			end

			// ---------- the compositor ----------
			R_COMP: begin comp_go <= 1'b1; rs <= R_DONE; end
			R_DONE: if (comp_fin) begin done <= 1'b1; rs <= R_IDLE; end
			default: rs <= R_IDLE;
			endcase
		end
	end

	// --- the compositor: one screen column a clock, two stages ------------------------------------
	reg [8:0]  kx;
	reg [3:0]  mzc [0:3];
	// stage 1's addresses: kx's main and sub columns, after the mosaic
	// (the remainders kx's columns leave by the mosaic size, kept as kx steps: no divider)
	reg [4:0] crm, crs;
	always @(*) begin : cmpa
		reg [8:0] xm_, xs_; reg [4:0] mz_; integer n_;
		mz_ = {1'b0, mosaic[7:4]} + 5'd1;
		xm_ = hires ? {kx[7:0], 1'b1} : kx;
		xs_ = hires ? {kx[7:0], 1'b0} : kx;
		for (n_ = 0; n_ < 4; n_ = n_ + 1) begin
			cmp_xm[n_] = xm_; cmp_xs[n_] = xs_;
			if (((mode == 3'd7) ? mosaic[0] : mosaic[n_]) && mz_ != 5'd1) begin
				cmp_xm[n_] = xm_ - {4'd0, crm}; cmp_xs[n_] = xs_ - {4'd0, crs};
			end
		end
	end
	// a remainder one step on (a step is 1, or 2 in hi-res, and the size at least 2 when used)
	function [4:0] mstep;
		input [4:0] r; input [3:0] msz; input two;
		reg [5:0] t;
		begin
			t = {1'b0, r} + (two ? 6'd2 : 6'd1);
			mstep = (t >= {2'b0, msz} + 6'd1) ? t - ({2'b0, msz} + 6'd1) : t[4:0];
		end
	endfunction
	always @(posedge clk) begin : comp
		reg [8:0] xm, xs, xmm, xsm;
		reg [4:0] mz; integer n;
		reg [7:0] wm_, ws_;
		comp_fin <= 1'b0;
		if (rst) begin comp_run <= 1'b0; c_v <= 1'b0; p_v <= 1'b0; q_v <= 1'b0; have_prev <= 1'b0; end
		else begin
			if (comp_go) begin
				comp_run <= 1'b1; kx <= 9'd0; c_v <= 1'b0; have_prev <= 1'b0; blank <= inidisp[7];
				crm <= (hires && mosaic[7:4] != 4'd0) ? 5'd1 : 5'd0; crs <= 5'd0;
			end
			if (comp_run) begin
				// stage 1: the reads for column kx
				mz = {1'b0, mosaic[7:4]} + 5'd1;
				xm = hires ? {kx[7:0], 1'b1} : kx;
				xs = hires ? {kx[7:0], 1'b0} : kx;
				// (the layers' addresses are cmp_xm / cmp_xs, worked out below from kx)
				c_ob <= objb[kx[7:0]];
				c_x <= kx; c_v <= (kx < 9'd256);
				kx <= kx + 9'd1;
				crm <= mstep(crm, mosaic[7:4], hires); crs <= mstep(crs, mosaic[7:4], hires);
				if (kx == 9'd256) begin comp_run <= 1'b0; end
			end else c_v <= 1'b0;
			// stage 2: the pick -- which layer is in front, main and sub, and the window tests
			p_v <= c_v; p_x <= c_x;
			if (c_v) begin
				pick(tm, tmw, 1'b1, em, ixm);
				if ((cgwsel[1] || split)) pick(ts, tsw, 1'b0, es, ixs);
				else es = 4'd12;
				p_em <= em; p_es <= es; p_ixm <= ixm; p_ixs <= ixs;
				p_eme <= (em >= 4'd4 && em < 4'd8) ? c_lm[em - 4'd4] : 12'd0;
				p_ese <= (es >= 4'd4 && es < 4'd8) ? c_ls[es - 4'd4] : 12'd0;
				cw_in = win(wobjsel[7:4], wobjlog[3:2], cxo, wh0, wh1, wh2, wh3);
				p_clip <= (cgwsel[7:6] == 2'd3) || (cgwsel[7:6] == 2'd1 && !cw_in) || (cgwsel[7:6] == 2'd2 && cw_in);
				p_noblend <= (cgwsel[5:4] == 2'd3) || (cgwsel[5:4] == 2'd1 && !cw_in) || (cgwsel[5:4] == 2'd2 && cw_in);
				mobj = (em < 4'd4) && (ixm >= 8'd192);
				p_math <= (em >= 4'd4 && em < 4'd8) ? cgadsub[em - 4'd4] : (em < 4'd4) ? (cgadsub[4] && mobj) : cgadsub[5];
			end
			// stage 3: the colours
			q_v <= p_v; q_x <= p_x; q_clip <= p_clip; q_noblend <= p_noblend; q_math <= p_math;
			if (p_v) begin
				q_colm <= (p_em == 4'd12) ? cgram[0] : (p_em < 4'd4) ? cgram[p_ixm] : bgcol(mode, p_em[1:0], p_eme, dirc, cgram[p_ixm]);
				q_subbd <= (p_es == 4'd12);
				q_cols <= (p_es == 4'd12) ? fixed : (p_es < 4'd4) ? cgram2[p_ixs] : bgcol(mode, p_es[1:0], p_ese, dirc, cgram2[p_ixs]);
				q_sub0 <= cgram2[0];
			end
			// stage 4: colour math, brightness, out
			if (q_v && blank) begin
				outb[{obuf, q_x[7:0]}] <= 30'd0;
				if (q_x == 9'd255) comp_fin <= 1'b1;
			end else if (q_v) begin
				mc = q_clip ? 15'd0 : q_colm;
				raw = mc;
				if (q_math && !q_noblend)
					mc = blend(mc, (cgwsel[1] && !q_subbd) ? q_cols : fixed, cgadsub[7],
					           cgadsub[6] && !q_clip && !(cgwsel[1] && q_subbd));
				mres = bright(mc, inidisp[3:0]);
				if (split) begin
					sp = q_subbd ? q_sub0 : q_cols;
					if (have_prev && prev_on) sp = blend(sp, cgwsel[1] ? prev_raw : fixed, cgadsub[7], cgadsub[6]);
					outb[{obuf, q_x[7:0]}] <= {mres, bright(sp, inidisp[3:0])};
					prev_raw <= raw; prev_on <= q_math && !q_noblend; have_prev <= 1'b1;
				end else outb[{obuf, q_x[7:0]}] <= {mres, mres};
				if (q_x == 9'd255) comp_fin <= 1'b1;
			end
		end
	end
endmodule

// a BG layer's line: 512 entries, port A written by the fetcher or read by the compositor
// (the main column), port B read by the compositor (the sub column)
module snes_lbuf (
	input  wire        clk,
	input  wire        a_we,
	input  wire [8:0]  a_a,
	input  wire [11:0] a_d,
	output reg  [11:0] a_q,
	input  wire [8:0]  b_a,
	output reg  [11:0] b_q
);
	(* ram_style = "block" *) reg [11:0] m [0:511];
	always @(posedge clk) begin
		if (a_we) m[a_a] <= a_d;
		a_q <= m[a_a];
	end
	always @(posedge clk) b_q <= m[b_a];
endmodule
