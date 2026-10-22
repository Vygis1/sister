//////////////////////////////////////////////////////////////////////////////////
// n64_rdp2.v - the N64's RDP, being built: its registers, the command walk, every
// SET_* command's state, and the primitives handed to n64_rdp_raster.v. (It
// replaces the stand-in, n64_rdp.v, once it draws what SM64 draws.) The behaviour
// is tools/n64/n64rdp.py's (derived from parallel-RDP, MIT); tools/n64/n64rdpsim.py and
// sim/tb_n64_rdp.v check it against that model.
//
// The registers are ares's (ares/n64/rdp/io.cpp, ISC): START is taken only while
// no start is pending; END sets the end and, if a start is pending, moves
// CURRENT to it, and the walk resumes; STATUS's write bits clear and set the
// source (XBUS), freeze, flush and the busy counters.
//
// One thing at a time: the walk gathers a whole command (up to 22 doublewords)
// and the executor runs it before the next is read. CURRENT never passes END: a
// command END cuts in two is held, the doublewords it has so far kept, until END
// moves on (SM64's microcode cuts texture rectangles so).
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp2 #(
	parameter [23:0] RDRAM_LINE = 24'h00_0000
) (
	input  wire         clk,
	input  wire         rst,
	input  wire         no_dither,        // (a setting) colour drawn undithered, whatever the game asks
	// the registers: a write from the CPU or the RSP (the CPU first), and all of
	// them for reading
	input  wire         c_we,
	input  wire [2:0]   c_idx,
	input  wire [31:0]  c_wd,
	input  wire         r_we,
	input  wire [2:0]   r_idx,
	input  wire [31:0]  r_wd,
	output wire [255:0] regs_flat,        // register i in [255 - 32 i -: 32]
	// RDRAM, a 128-bit line at a time (byte k of the line in bits 8k+7:8k)
	output wire         cf_req,
	input  wire         cf_ack,
	output wire [23:0]  cf_line,
	input  wire [127:0] cf_data,
	output wire         cw_req,
	input  wire         cw_ack,
	output wire [23:0]  cw_line,
	output wire [127:0] cw_data,
	output wire [15:0]  cw_mask,          // bit k: byte k is written
	// the raster's span reads: pipelined, taken on rq_ready, answered in order on rs_valid
	output wire         rq_valid,
	input  wire         rq_ready,
	output wire [23:0]  rq_line,
	input  wire         rs_valid,
	input  wire [127:0] rs_data,
	// DMEM, over the XBUS
	output reg          xb_req,
	output reg  [8:0]   xb_dw,
	input  wire         xb_ack,
	input  wire [63:0]  xb_data,
	output reg          irq,
	output wire         idle,             // nothing walking or drawing (for tests)
	// debugging: the last 32 commands decoded ({address after it, w0, w1}), until log_stop
	input  wire         log_stop,
	input  wire [4:0]   log_idx,
	output reg  [87:0]  log_q,
	output reg  [31:0]  log_n,
	output wire [63:0]  dbg,              // {ws, cb_n, raster busy, tmem busy, wk_req, raster_mem, tmem_mem, 0 (3), the raster's 48}
	output wire [63:0]  dbg2              // {the raster's y (16), the command (6), 0 (2), fb_addr (24), z_addr[23:8]}
);
	// =============================================================================
	// the registers
	// =============================================================================
	reg  [23:0] start, endp, current;
	// a new buffer (START, then END) set while the last is still being walked waits for the
	// walk to reach the last one's end: a command cut there goes on at the new START. (Taken
	// at once, the rest of the old list was skipped and a command's tail read from the new
	// one: SM64 then drew with a garbage colour image over its own memory.)
	reg         pend;  reg [23:0] pend_end;
	reg         start_valid, source, freeze, flush, start_gclk;
	reg  [23:0] clock;

	wire [31:0] status = {21'd0, start_valid, 1'b0 /*end valid*/, 1'b0 /*DMA busy*/, 1'b1 /*ready*/,
	                      1'b0, 1'b0, 1'b0, start_gclk, flush, freeze, source};
	assign regs_flat = {8'd0, start, 8'd0, endp, 8'd0, current, status, 8'd0, clock, 32'd0, 32'd0, 32'd0};

	// a write from either side; the RSP's, on the clock the CPU writes too, is kept
	// and done on the next
	reg          rp_we;
	reg  [2:0]   rp_idx;
	reg  [31:0]  rp_wd;
	wire         we = c_we || rp_we || r_we;
	wire [2:0]   widx = c_we ? c_idx : rp_we ? rp_idx : r_idx;
	wire [31:0]  wd = c_we ? c_wd : rp_we ? rp_wd : r_wd;
	always @(posedge clk) begin
		if (rst) rp_we <= 1'b0;
		else if (c_we && r_we) begin rp_we <= 1'b1; rp_idx <= r_idx; rp_wd <= r_wd; end
		else if (!c_we) rp_we <= 1'b0;
	end

	// =============================================================================
	// the command buffer: the doublewords of the command being gathered
	// =============================================================================
	reg  [63:0]  cbuf [0:21];
	reg  [4:0]   cb_n;                    // doublewords gathered
	reg  [4:0]   cb_need;                 // the command's length, once its first is in
	function [4:0] cmd_len; input [5:0] op; begin
		if (op[5:3] == 3'b001) cmd_len = 5'd4 + (op[2] ? 5'd8 : 5'd0) + (op[1] ? 5'd8 : 5'd0) + (op[0] ? 5'd2 : 5'd0);
		else if (op == 6'h24 || op == 6'h25) cmd_len = 5'd2;
		else cmd_len = 5'd1;
	end endfunction

	// =============================================================================
	// the state the commands set (tools/n64/n64rdp.py RDP.execute)
	// =============================================================================
	reg  [31:0] om0, om1;                 // SET_OTHER_MODES
	reg  [31:0] comb0, comb1;             // SET_COMBINE, as sent
	reg  [31:0] fill_color, fog_color, blend_color, prim_color, env_color;
	reg  [4:0]  prim_min_level;
	reg  [7:0]  prim_lod_frac;
	reg  [31:0] key_gb0, key_gb1, key_r1; // SET_KEY_GB (both words), SET_KEY_R (second)
	reg  [53:0] convert;                  // SET_CONVERT's six 9-bit factors
	reg  [11:0] sc_xlo, sc_ylo, sc_xhi, sc_yhi;
	reg         sc_field, sc_odd;
	reg  [14:0] prim_depth;               // SET_PRIM_DEPTH: z (the model's >> 16), dz
	reg  [15:0] prim_dz;
	reg  [23:0] timg_addr;  reg [9:0] timg_width_m1;  reg [2:0] timg_fmt;  reg [1:0] timg_size;
	reg  [23:0] z_addr;
	reg  [23:0] fb_addr;    reg [9:0] fb_width_m1;    reg [2:0] fb_fmt;
	// the tiles: SET_TILE's two words as sent (less the command), SET_TILE_SIZE's
	// {slo, tlo, shi, thi}
	reg  [55:0] tile_w  [0:7];
	reg  [47:0] tile_sz [0:7];

	localparam [2:0] FB_I4 = 3'd0, FB_I8 = 3'd1, FB_RGBA5551 = 3'd2, FB_IA88 = 3'd3, FB_RGBA8888 = 3'd4;

	// =============================================================================
	// the primitive, as n64_rdp_raster.v takes it
	// =============================================================================
	reg  signed [26:0] t_xh, t_xm, t_xl, t_dxhdy, t_dxmdy, t_dxldy;
	reg  signed [13:0] t_yh, t_ym, t_yl;
	reg  [2:0]   t_flags;                 // {skip_xfrac, do_offset, flip}
	reg  [5:0]   t_tile;
	// the attributes, 32 of 32 bits: rgba, drgba_dx, drgba_de, drgba_dy, stzw,
	// dstzw_dx, dstzw_de, dstzw_dy, four each (tools/n64/n64rdp.py Attr)
	reg  [31:0]  attr [0:31];
	wire [4:0]   at_ra;
	reg  [31:0]  at_q;
	always @(posedge clk) at_q <= attr[at_ra];
	reg          pr_go;
	wire         pr_busy;
	reg  [31:0]  prim_n;                  // primitives so far, this one counted (n64rdp.py RDP.prims: the noise's seed)

	// attribute k (group k[4:2], component k[1:0]) from the command in cbuf:
	// tools/n64/n64rdp.py decode_shade/texture/z. Its integer half is a 16-bit half of
	// word wi, its fraction a half of word wj (high halves for even components);
	// texture's w is component 3 but third in its block; z is whole, from the Z
	// block. (Called from the clocked executor only: it reads cbuf.)
	function [31:0] attr_value; input [4:0] k;
		reg [2:0] g; reg [1:0] c, cc; reg [5:0] blk, wi, wj; reg [3:0] i0; reg whole, have; reg [31:0] vi, vj;
	begin
		g = k[4:2]; c = k[1:0];
		i0 = (g[1:0] == 2'd0) ? 4'd0 : (g[1:0] == 2'd1) ? 4'd2 : (g[1:0] == 2'd2) ? 4'd8 : 4'd10;
		whole = 1'b0; cc = c;
		if (!g[2]) begin                                     // shade
			have = cbuf[0][58]; blk = 6'd8;
		end else if (c == 2'd2) begin                        // z
			have = cbuf[0][56]; whole = 1'b1;
			blk = 6'd8 + (cbuf[0][58] ? 6'd16 : 6'd0) + (cbuf[0][57] ? 6'd16 : 6'd0);
		end else begin                                       // texture: s, t, w
			have = cbuf[0][57]; blk = 6'd8 + (cbuf[0][58] ? 6'd16 : 6'd0);
			cc = (c == 2'd3) ? 2'd2 : c;
		end
		wi = whole ? blk + {4'd0, g[1:0]} : blk + {2'd0, i0} + {5'd0, cc[1]};
		wj = blk + {2'd0, i0} + 6'd4 + {5'd0, cc[1]};
		vi = wi[0] ? cbuf[wi[5:1]][31:0] : cbuf[wi[5:1]][63:32];
		vj = wj[0] ? cbuf[wj[5:1]][31:0] : cbuf[wj[5:1]][63:32];
		attr_value = !have ? 32'd0 : whole ? vi : !cc[0] ? {vi[31:16], vj[31:16]} : {vi[15:0], vj[15:0]};
	end endfunction

	// a texture rectangle's attributes (tools/n64/n64rdp.py texture_rectangle): s, t from
	// its second doubleword (<< 16); dsdx, dtdy (<< 11) as s's x slope and t's e and y
	// slopes, or flipped, t's x slope and s's
	function [31:0] texrect_attr; input [4:0] k; reg [31:0] w3; reg signed [31:0] dsdx, dtdy; reg fl; begin
		w3 = cbuf[1][31:0];
		dsdx = $signed({{16{w3[31]}}, w3[31:16]}) <<< 11;
		dtdy = $signed({{16{w3[15]}}, w3[15:0]}) <<< 11;
		fl = cbuf[0][56];                        // (TEXTURE_RECTANGLE_FLIP)
		case (k)
		5'd16: texrect_attr = {cbuf[1][63:48], 16'd0};
		5'd17: texrect_attr = {cbuf[1][47:32], 16'd0};
		5'd20: texrect_attr = fl ? 32'd0 : dsdx;
		5'd21: texrect_attr = fl ? dtdy : 32'd0;
		5'd24: texrect_attr = fl ? dsdx : 32'd0;
		5'd25: texrect_attr = fl ? 32'd0 : dtdy;
		5'd28: texrect_attr = fl ? dsdx : 32'd0;
		5'd29: texrect_attr = fl ? 32'd0 : dtdy;
		default: texrect_attr = 32'd0;
		endcase
	end endfunction

	// =============================================================================
	// the walk and the executor
	// =============================================================================
	localparam [2:0] W_IDLE = 3'd0, W_WAIT = 3'd1, X_DECODE = 3'd2, X_ATTR = 3'd3, X_RUN = 3'd4, X_LOAD = 3'd5;
	reg  [2:0]   ws;
	reg  [127:0] line;  reg [18:0] ltag; reg lv;
	reg          wend;                     // END was written while a line was being fetched
	function [63:0] dw_of; input [127:0] l; input sel; begin
		dw_of = {l[8 * {sel, 3'd0} +: 8], l[8 * {sel, 3'd1} +: 8], l[8 * {sel, 3'd2} +: 8], l[8 * {sel, 3'd3} +: 8],
		         l[8 * {sel, 3'd4} +: 8], l[8 * {sel, 3'd5} +: 8], l[8 * {sel, 3'd6} +: 8], l[8 * {sel, 3'd7} +: 8]};
	end endfunction
	reg  [63:0]  dwin;  reg dwin_v;        // a doubleword fetched, to gather
	wire [5:0]   op0 = cbuf[0][61:56];
	reg  [4:0]   xi;                       // the executor's step
	wire [31:0]  w0 = cbuf[0][63:32], w1 = cbuf[0][31:0];
	// (debugging) the last 32 commands decoded: {the walk address after it, w0, w1}, until log_stop
	(* ram_style = "distributed" *) reg [87:0] cmd_log [0:31];
	always @(posedge clk) begin
		if (ws == X_DECODE && !log_stop) cmd_log[log_n[4:0]] <= {current, w0, w1};
		log_q <= cmd_log[log_idx];
	end
	always @(posedge clk) begin
		if (rst) log_n <= 32'd0;
		else if (ws == X_DECODE && !log_stop) log_n <= log_n + 32'd1;
	end
	wire [31:0]  w2 = cbuf[1][63:32], w3 = cbuf[1][31:0], w4 = cbuf[2][63:32], w5 = cbuf[2][31:0];
	wire [31:0]  w6 = cbuf[3][63:32], w7 = cbuf[3][31:0];
	// the line port: the walk's, or a TMEM load's (the raster has its own, rq/rs)
	reg          raster_mem;               // (a primitive is being drawn)
	reg          wk_req;  reg [23:0] wk_line;
	wire [23:0]  r_rq_line;
	wire         r_rq_valid;              // the raster's span reads
	// --- the read-ahead (n64_rdp_stream.v) for the walk and the TMEM loads, and the one
	// pipelined read port it shares with the raster's span reads. A request presented is
	// held, and its owner kept, until n64_top takes it (rq_ready); each read's owner goes in
	// a queue, so each line that comes back goes to whoever asked for it.
	wire         s_qv;  wire [19:0] s_ql;
	reg          hs, hs_own;              // a request presented and not yet taken; its owner (1 the read-ahead)
	reg  [23:0]  hs_line;
	wire         own_now = !r_rq_valid;   // (the raster first)
	assign rq_valid = hs || r_rq_valid || s_qv;
	assign rq_line = hs ? hs_line : RDRAM_LINE + (own_now ? {4'd0, s_ql} : r_rq_line);
	wire         rdy_r = rq_ready && hs && !hs_own;
	wire         rdy_s = rq_ready && hs && hs_own;
	reg          tagq [0:15];  reg [3:0] tq_w, tq_r;   // the owners of the reads taken, oldest at tq_r
	wire         rs_s = rs_valid && tagq[tq_r];
	wire         rs_r = rs_valid && !tagq[tq_r];
	always @(posedge clk) begin
		if (rst) begin hs <= 1'b0; tq_w <= 4'd0; tq_r <= 4'd0; end
		else begin
			if (!hs && (r_rq_valid || s_qv)) begin hs <= 1'b1; hs_own <= own_now; hs_line <= rq_line; end
			if (hs && rq_ready) begin hs <= 1'b0; tagq[tq_w] <= hs_own; tq_w <= tq_w + 4'd1; end
			if (rs_valid) tq_r <= tq_r + 4'd1;
		end
	end
	reg          tmem_mem;                 // (or a TMEM load's)
	reg          ld_go;                    // a TMEM load, started (n64_rdp_tmem.v)
	wire         ld_busy;
	wire         tl_req;  wire [23:0] tl_line;
	assign cf_req  = 1'b0;                 // (the line port is not used: the read-ahead does its work)
	assign cf_line = 24'd0;
	// the read-ahead's client: a TMEM load, or the walk. It is emptied at every END (the list
	// grows in place) -- once no request of its own is being presented
	reg          s_flush_p;
	wire         s_hold = s_qv || (hs && hs_own);   // a read of the read-ahead's being presented or taken
	wire         s_flush = s_flush_p && !s_hold;
	wire         s_ack;  wire [127:0] s_data;
	n64_rdp_stream u_stream (.clk(clk), .rst(rst), .flush(s_flush), .hold(s_hold), .stop(s_flush_p),
		.s_v(1'b0), .s_line(24'd0), .s_hit(),
		.c_req(!s_flush_p && !(hs && hs_own) && !raster_mem && (tmem_mem ? tl_req : wk_req)),
		.c_line(tmem_mem ? tl_line[19:0] : wk_line[19:0] - RDRAM_LINE[19:0]),
		.c_ack(s_ack), .c_data(s_data),
		.q_valid(s_qv), .q_line(s_ql), .q_ready(rdy_s), .q_rs(rs_s), .q_rs_data(rs_data));
	always @(posedge clk) begin
		if (rst) s_flush_p <= 1'b0;
		else if ((we && widx == 3'd1) || ld_go) s_flush_p <= 1'b1;
		else if (s_flush) s_flush_p <= 1'b0;
	end
	wire         wk_ack = s_ack && !raster_mem && !tmem_mem;
	wire         tl_ack = s_ack && tmem_mem;
	wire         copy_cycle = om0[21:20] == 2'd2, fill_or_copy = om0[21];

	function signed [26:0] sx28h; input [31:0] v; reg [27:0] t; begin   // sext(v, 28) >> 1
		t = v[27:0]; sx28h = $signed(t) >>> 1;
	end endfunction

	always @(posedge clk) begin
		irq <= 1'b0;
		pr_go <= 1'b0;
		ld_go <= 1'b0;
		if (wk_ack) wk_req <= 1'b0;
		if (xb_ack) xb_req <= 1'b0;
		if (rst) begin
			start <= 24'd0; endp <= 24'd0; current <= 24'd0; start_valid <= 1'b0; source <= 1'b0; pend <= 1'b0;
			freeze <= 1'b0; flush <= 1'b0; start_gclk <= 1'b0; clock <= 24'd0;
			ws <= W_IDLE; lv <= 1'b0; wk_req <= 1'b0; tmem_mem <= 1'b0; xb_req <= 1'b0; wend <= 1'b0; raster_mem <= 1'b0;
			cb_n <= 5'd0; cb_need <= 5'd1; dwin_v <= 1'b0; prim_n <= 32'd0;
			om0 <= 32'd0; om1 <= 32'd0; comb0 <= 32'd0; comb1 <= 32'd0;
			fill_color <= 32'd0; fog_color <= 32'd0; blend_color <= 32'd0; prim_color <= 32'd0; env_color <= 32'd0;
			prim_min_level <= 5'd0; prim_lod_frac <= 8'd0; key_gb0 <= 32'd0; key_gb1 <= 32'd0; key_r1 <= 32'd0;
			convert <= 54'd0;
			sc_xlo <= 12'd0; sc_ylo <= 12'd0; sc_xhi <= 12'd0; sc_yhi <= 12'd0; sc_field <= 1'b0; sc_odd <= 1'b0;
			prim_depth <= 15'd0; prim_dz <= 16'd0;
			timg_addr <= 24'd0; timg_width_m1 <= 10'd0; timg_fmt <= 3'd0; timg_size <= 2'd0;
			z_addr <= 24'd0; fb_addr <= 24'd0; fb_width_m1 <= 10'd0; fb_fmt <= FB_RGBA5551;
		end else begin
			clock <= clock + 24'd1;
			if (we) begin
				case (widx)
				3'd0: begin if (!start_valid) start <= {wd[23:3], 3'b000}; start_valid <= 1'b1; end
				3'd1: begin
					// the line held is dropped at every END: a list grows in place, and the
					// rest of the line it was read from was not written yet
					lv <= 1'b0; wend <= 1'b1;
					if (start_valid && (current < endp || pend)) begin
						pend <= 1'b1; pend_end <= {wd[23:3], 3'b000};      // (the old list first)
					end else if (start_valid) begin
						current <= start; endp <= {wd[23:3], 3'b000}; start_valid <= 1'b0;
					end else endp <= {wd[23:3], 3'b000};
				end
				3'd3: begin
					if (wd[0]) source <= 1'b0;
					if (wd[1]) source <= 1'b1;
					if (wd[2]) freeze <= 1'b0;
					if (wd[3]) freeze <= 1'b1;
					if (wd[4]) flush <= 1'b0;
					if (wd[5]) flush <= 1'b1;
					if (wd[9]) clock <= 24'd0;
				end
				default: ;
				endcase
			end
			case (ws)
			// --- the walk: a doubleword at a time into the command buffer ----------------
			W_IDLE: if (dwin_v) begin
				dwin_v <= 1'b0;
				cbuf[cb_n] <= dwin;
				if ((cb_n == 5'd0 ? cmd_len(dwin[61:56]) : cb_need) == cb_n + 5'd1) begin
					cb_n <= 5'd0; ws <= X_DECODE; start_gclk <= 1'b1;
				end else begin
					if (cb_n == 5'd0) cb_need <= cmd_len(dwin[61:56]);
					cb_n <= cb_n + 5'd1;
				end
			end else if (!we && pend && current >= endp) begin
				// the old list walked to its end: the new one, from its START
				current <= start; endp <= pend_end; pend <= 1'b0; start_valid <= 1'b0; lv <= 1'b0;
			end else if (!we && !freeze && current < endp) begin
				if (source) begin
					xb_dw <= current[11:3]; xb_req <= 1'b1; ws <= W_WAIT;
				end else if (lv && ltag == current[22:4]) begin
					dwin <= dw_of(line, current[3]); dwin_v <= 1'b1; current <= current + 24'd8;
				end else begin
					wk_line <= RDRAM_LINE + {5'd0, current[22:4]}; wk_req <= 1'b1; ws <= W_WAIT; wend <= 1'b0;
				end
			end
			W_WAIT: begin
				if (source && xb_ack) begin dwin <= xb_data; dwin_v <= 1'b1; current <= current + 24'd8; ws <= W_IDLE; end
				// (a line fetched across an END write gives the one doubleword asked for,
				// which was inside the list, and is not kept)
				if (!source && wk_ack) begin
					if (!(wend || we)) begin line <= s_data; ltag <= current[22:4]; lv <= 1'b1; end
					dwin <= dw_of(s_data, current[3]); dwin_v <= 1'b1; current <= current + 24'd8;
					ws <= W_IDLE;
				end
			end
			// --- the executor: the command in cbuf -----------------------------------------
			X_DECODE: begin
				ws <= W_IDLE;
				xi <= 5'd0;
				case (op0)
				6'h29: begin irq <= 1'b1; start_gclk <= 1'b0; end                     // SYNC_FULL
				6'h2A: begin key_gb0 <= w0; key_gb1 <= w1; end                        // SET_KEY_GB
				6'h2B: key_r1 <= w1;                                                  // SET_KEY_R
				6'h2C: convert <= {w0[21:0], w1};                                     // SET_CONVERT
				6'h2D: begin                                                          // SET_SCISSOR
					sc_xlo <= w0[23:12]; sc_ylo <= w0[11:0]; sc_xhi <= w1[23:12]; sc_yhi <= w1[11:0];
					sc_field <= w1[25]; sc_odd <= w1[24];
				end
				6'h2E: begin prim_depth <= w1[30:16]; prim_dz <= w1[15:0]; end        // SET_PRIM_DEPTH
				6'h2F: begin om0 <= w0; om1 <= w1; end                                // SET_OTHER_MODES
				6'h32: tile_sz[w1[26:24]] <= {w0[23:12], w0[11:0], w1[23:12], w1[11:0]};   // SET_TILE_SIZE
				6'h35: tile_w[w1[26:24]] <= {w0[23:0], w1[31:0]};                     // SET_TILE
				6'h37: fill_color <= w1;
				6'h38: fog_color <= w1;
				6'h39: blend_color <= w1;
				6'h3A: begin prim_min_level <= w0[12:8]; prim_lod_frac <= w0[7:0]; prim_color <= w1; end
				6'h3B: env_color <= w1;
				6'h3C: begin comb0 <= w0; comb1 <= w1; end                            // SET_COMBINE
				6'h3D: begin timg_addr <= w1[23:0]; timg_width_m1 <= w0[9:0]; timg_fmt <= w0[23:21]; timg_size <= w0[20:19]; end
				6'h3E: z_addr <= w1[23:0];
				6'h3F: begin                                                          // SET_COLOR_IMAGE
					fb_addr <= w1[23:0]; fb_width_m1 <= w0[9:0];
					case (w0[20:19])
					2'd0: fb_fmt <= FB_I4;
					2'd1: fb_fmt <= FB_I8;
					2'd2: fb_fmt <= (w0[23:21] != 3'd0) ? FB_IA88 : FB_RGBA5551;
					default: fb_fmt <= FB_RGBA8888;
					endcase
				end
				6'h08, 6'h09, 6'h0A, 6'h0B, 6'h0C, 6'h0D, 6'h0E, 6'h0F: begin           // a triangle
					prim_n <= prim_n + 32'd1;
					t_yl <= w0[13:0];
					t_ym <= w1[29:16];
					t_yh <= w1[13:0];
					t_xl <= sx28h(w2);
					t_dxldy <= sx28h({2'd0, w3[31:2]});
					t_xh <= sx28h(w4);
					t_dxhdy <= sx28h({2'd0, w5[31:2]});
					t_xm <= sx28h(w6);
					t_dxmdy <= sx28h({2'd0, w7[31:2]});
					t_flags <= {copy_cycle, w0[23] == w5[31], w0[23]};
					t_tile <= w0[21:16];
					ws <= X_ATTR;
				end
				6'h36: begin                                                          // FILL_RECTANGLE
					prim_n <= prim_n + 32'd1;
					t_xh <= {3'd0, w1[23:12], 12'd0} <<< 1;  t_xl <= {3'd0, w0[23:12], 12'd0} <<< 1;
					t_xm <= {3'd0, w0[23:12], 12'd0} <<< 1;
					t_yh <= {2'd0, w1[11:0]};
					t_yl <= {2'd0, w0[11:2], fill_or_copy ? 2'b11 : w0[1:0]};
					t_ym <= {2'd0, w0[11:2], fill_or_copy ? 2'b11 : w0[1:0]};
					t_dxhdy <= 27'sd0; t_dxmdy <= 27'sd0; t_dxldy <= 27'sd0;
					t_flags <= 3'b001; t_tile <= 6'd0;
					ws <= X_ATTR;                                                     // (all zero)
				end
				6'h30, 6'h33, 6'h34: begin                                            // LOAD_TLUT, _BLOCK, _TILE
					// (the load's tile takes its bounds, as tools/n64/n64rdp.py load_iteration's does -- unless
					// RDP.load refuses it first: a tile/TLUT load with no rows or no texels, a block of none
					// or more than 2048)
					if (op0 == 6'h33 ? (w1[23:12] - w0[23:12] + 12'd1 != 12'd0 && w1[23:12] - w0[23:12] + 12'd1 <= 12'd2048)
					                 : (w1[11:2] >= w0[11:2] && {2'd0, w1[23:14]} - {2'd0, w0[23:14]} + 12'd1 != 12'd0))
						tile_sz[w1[26:24]] <= {w0[23:12], w0[11:0], w1[23:12], w1[11:0]};
					ld_go <= 1'b1; tmem_mem <= 1'b1; ws <= X_LOAD;
				end
				6'h24, 6'h25: begin                                                   // TEXTURE_RECTANGLE (_FLIP)
					prim_n <= prim_n + 32'd1;
					t_xh <= {3'd0, w1[23:12], 12'd0} <<< 1;  t_xl <= {3'd0, w0[23:12], 12'd0} <<< 1;
					t_xm <= {3'd0, w0[23:12], 12'd0} <<< 1;
					t_yh <= {2'd0, w1[11:0]};
					t_yl <= {2'd0, w0[11:2], fill_or_copy ? 2'b11 : w0[1:0]};
					t_ym <= {2'd0, w0[11:2], fill_or_copy ? 2'b11 : w0[1:0]};
					t_dxhdy <= 27'sd0; t_dxmdy <= 27'sd0; t_dxldy <= 27'sd0;
					t_flags <= {copy_cycle, 1'b0, 1'b1}; t_tile <= {3'd0, w1[26:24]};
					ws <= X_ATTR;
				end
				default: ;                                       // no-op, syncs
				endcase
			end
			X_ATTR: begin
				// the attributes into attr[], one a clock (zero where the command has none)
				attr[xi] <= (op0[5:3] == 3'b001) ? attr_value(xi) : (op0[5:1] == 5'b10010) ? texrect_attr(xi) : 32'd0;
				xi <= xi + 5'd1;
				if (xi == 5'd31) begin pr_go <= 1'b1; raster_mem <= 1'b1; ws <= X_RUN; end
			end
			X_RUN: if (!pr_go && !pr_busy) begin raster_mem <= 1'b0; ws <= W_IDLE; end
			X_LOAD: if (!ld_go && !ld_busy) begin tmem_mem <= 1'b0; ws <= W_IDLE; end
			default: ws <= W_IDLE;
			endcase
		end
	end
	assign idle = ws == W_IDLE && !dwin_v && current >= endp && cb_n == 5'd0 && !pend;
	wire [63:0]  r_dbg;
	assign dbg = {ws, cb_n, pr_busy, ld_busy, wk_req, raster_mem, tmem_mem, 3'd0, r_dbg[47:0]};
	assign dbg2 = {r_dbg[63:48], op0, 2'd0, fb_addr, z_addr[23:8]};

	// =============================================================================
	// the raster
	// =============================================================================
	wire [23:0] r_mw_line;
	assign cw_line = RDRAM_LINE + r_mw_line;
	// =============================================================================
	// TMEM (n64_rdp_tmem.v): the loads, and the raster's sampler reads it
	// =============================================================================
	wire [10:0]  tfa0, tfa1, tfa2, tfa3, tsa0, tsa1, tsa2, tsa3;
	wire [15:0]  tfq0, tfq1, tfq2, tfq3, tsq0, tsq1, tsq2, tsq3;
	wire         tm_ce;
	wire [55:0]  tw_l = tile_w[w1[26:24]];
	n64_rdp_tmem u_tmem (
		.clk(clk), .rst(rst), .go(ld_go), .busy(ld_busy), .op(op0), .w0(w0), .w1(w1),
		.t_fmt(tw_l[55:53]), .t_size(tw_l[52:51]), .t_line(tw_l[49:41]), .t_tmem(tw_l[40:32]),
		.img_addr(timg_addr), .img_width_m1(timg_width_m1), .img_size(timg_size),
		.mr_req(tl_req), .mr_ack(tl_ack), .mr_line(tl_line), .mr_data(s_data),
		.ce(tm_ce),
		.fa0(tfa0), .fa1(tfa1), .fa2(tfa2), .fa3(tfa3), .fq0(tfq0), .fq1(tfq1), .fq2(tfq2), .fq3(tfq3),
		.sa0(tsa0), .sa1(tsa1), .sa2(tsa2), .sa3(tsa3), .sq0(tsq0), .sq1(tsq1), .sq2(tsq2), .sq3(tsq3)
	);
	// the tiles, all eight, for the pixel pipeline (each pixel's texels may want any)
	wire [447:0] tw_all = {tile_w[0], tile_w[1], tile_w[2], tile_w[3], tile_w[4], tile_w[5], tile_w[6], tile_w[7]};
	wire [383:0] tsz_all = {tile_sz[0], tile_sz[1], tile_sz[2], tile_sz[3], tile_sz[4], tile_sz[5], tile_sz[6], tile_sz[7]};

	n64_rdp_raster u_raster (
		.clk(clk), .rst(rst), .no_dither(no_dither), .go(pr_go), .busy(pr_busy),
		.xh(t_xh), .xm(t_xm), .xl(t_xl), .yh(t_yh), .ym(t_ym), .yl(t_yl),
		.dxhdy(t_dxhdy), .dxmdy(t_dxmdy), .dxldy(t_dxldy), .tflags(t_flags), .tile(t_tile),
		.at_ra(at_ra), .at_q(at_q),
		.om0(om0), .om1(om1), .comb0(comb0), .comb1(comb1),
		.fill_color(fill_color), .fog_color(fog_color), .blend_color(blend_color), .prim_color(prim_color), .env_color(env_color),
		.key_center({key_r1[15:8], key_gb1[31:24], key_gb1[15:8]}), .key_scale({key_r1[7:0], key_gb1[23:16], key_gb1[7:0]}),
		.k4(convert[17:9]), .k5(convert[8:0]), .kconv(convert[53:18]), .prim_n(prim_n), .prim_lod_frac(prim_lod_frac), .prim_min_level(prim_min_level), .prim_dz(prim_dz),
		.sc_xlo(sc_xlo), .sc_ylo(sc_ylo), .sc_xhi(sc_xhi), .sc_yhi(sc_yhi), .sc_field(sc_field), .sc_odd(sc_odd),
		.fb_addr(fb_addr), .fb_width_m1(fb_width_m1), .fb_fmt(fb_fmt), .z_addr(z_addr), .prim_depth(prim_depth),
		.tw_all(tw_all), .tsz_all(tsz_all), .tm_ce(tm_ce),
		.fa0(tfa0), .fa1(tfa1), .fa2(tfa2), .fa3(tfa3), .fq0(tfq0), .fq1(tfq1), .fq2(tfq2), .fq3(tfq3),
		.sa0(tsa0), .sa1(tsa1), .sa2(tsa2), .sa3(tsa3), .sq0(tsq0), .sq1(tsq1), .sq2(tsq2), .sq3(tsq3),
		.rq_valid(r_rq_valid), .rq_ready(rdy_r), .rq_line(r_rq_line), .rs_valid(rs_r), .rs_data(rs_data),
		.dbg(r_dbg),
		.mw_req(cw_req), .mw_ack(cw_ack), .mw_line(r_mw_line), .mw_data(cw_data), .mw_mask(cw_mask)
	);
endmodule

`default_nettype wire
