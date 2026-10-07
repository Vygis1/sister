//////////////////////////////////////////////////////////////////////////////////
// ps1_spu.v - the PlayStation's Sound Processing Unit: 24 ADPCM voices.
//
// The behaviour follows psx-spx and, where the sources disagree, DuckStation and
// Mednafen (the spec that was written for this, with every disagreement listed,
// is summarised in the comments below).
//
// CD audio (CD-DA and XA, from ps1_cdrom.v after its volume matrix) comes in on
// cd_l/cd_r a sample a tick and is mixed at the CD volume (1DB0h/1DB2h) when
// SPUCNT bit 0 says so, and into the reverb's input with bit 2. The capture
// buffers -- CD left, CD right, voice 1, voice 3, 512 halfwords each from SPU
// RAM 0000h -- are written a halfword at a time as masked writes, at the lowest
// priority the memory port has (four in a tick's 1134 clocks).
//
// --- the shape ------------------------------------------------------------------
//
// One output sample per `tick` (44.1 kHz: 768 cycles of the console's 33.8688
// MHz clock, derived by the caller from the same enable the timers use). On a
// tick the engine walks voices 0..23 in order -- the order matters, pitch
// modulation reads the previous voice's output of the same tick -- about 15
// clocks a voice, 400 of the 1134 a tick has.
//
// SPU RAM (512 KB) is in DDR3, SPU_LINE onwards, behind the memory arbiter. An
// ADPCM block is 16 bytes and always 16-byte aligned, so it is exactly one line.
// Each voice holds its current block and a PREFETCHED next one: the next block's
// address is known as soon as the current block starts (address + 16, or the
// loop address if the block ends a loop), and it is needed no sooner than seven
// ticks later. The prefetch is checked against the real address at the jump (the
// loop address can change in between) and fetched again if it is wrong. The
// voice decodes lazily -- only the samples the pitch counter has reached, at
// most a handful a tick -- so nothing holds 28 decoded samples.
//
// Transfers (the CPU's FIFO writes and DMA channel 4) go through a 64-halfword
// FIFO into a line write-combiner, then to DDR3 as masked line writes. A write
// throws away every prefetched block (they are fetched again), so a voice never
// plays sample data older than what was uploaded before it started a block.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_spu #(
	parameter [23:0] SPU_LINE = 24'h08_0000      // DDR3 line of SPU RAM byte 0 (8 MB)
)(
	input  wire        clk,
	input  wire        rst,

	// --- the CPU: 1F801C00h..1F801FFFh -------------------------------------------
	input  wire        sel,
	input  wire        we,
	input  wire [9:0]  addr,          // byte offset from 1F801C00h
	input  wire [3:0]  be,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,         // in the same clock

	input  wire        tick,          // one pulse per output sample, 44.1 kHz
	output wire        irq,           // IRQ9, a level: the interrupt controller takes the edge

	// --- DMA channel 4 ----------------------------------------------------------
	input  wire        dma_wr,        // a word for the FIFO: low halfword first
	input  wire [31:0] dma_wdata,
	output wire        dma_ready,
	input  wire        dma_rd,        // held until dma_rvalid
	output reg  [31:0] dma_rdata,
	output reg         dma_rvalid,

	// --- SPU RAM, in lines --------------------------------------------------------
	output reg  [23:0]  m_addr,
	output reg          m_req,
	output reg          m_we,
	output reg  [127:0] m_wdata,
	output reg  [15:0]  m_wmask,
	input  wire         m_ready,
	input  wire [127:0] m_rdata,
	input  wire         m_valid,

	// --- CD audio in, a sample a tick (ps1_cdrom.v) ----------------------------------
	input  wire signed [15:0] cd_l,
	input  wire signed [15:0] cd_r,

	// --- the sound ------------------------------------------------------------------
	output reg  [31:0] out_lr,        // {right, left}, signed
	output reg         out_we
);
	integer i;

	// =============================================================================
	// helpers
	// =============================================================================
	function [15:0] clamp16;
		input signed [31:0] x;
		clamp16 = (x > 32'sd32767) ? 16'h7FFF : (x < -32'sd32768) ? 16'h8000 : x[15:0];
	endfunction

	// a volume register: fixed (bit 15 clear) = bits 14:0 times two; a sweep is
	// taken straight to where it is going (games rarely sweep; see the TODO list)
	function [15:0] volume;
		input [15:0] r;
		volume = !r[15] ? {r[14:0], 1'b0}
		       : r[13] ? 16'h0000                   // decreasing: to silence
		       : r[12] ? 16'h8000                   // negative phase: to -full
		       :         16'h7FFF;                  // increasing: to full
	endfunction

	// =============================================================================
	// registers
	// =============================================================================
	// Everything 1F801C00h..1F801FFFh as written, for reading back; the live
	// values (ENVX, LSAX, ENDX, SPUSTAT, the current volumes) are answered from
	// the engine instead.
	// A byte lane an array, each written once a clock: as one 32-bit array written a lane at a
	// time, synthesis built it in 8,192 flip-flops and a 256-way read multiplexer, most of the
	// SPU's flip-flops on a chip out of slices. The CD volume (1DB0h), which the mixer reads
	// every sample, is kept beside it.
	(* ram_style = "distributed" *) reg [7:0] r0 [0:255];
	(* ram_style = "distributed" *) reg [7:0] r1 [0:255];
	(* ram_style = "distributed" *) reg [7:0] r2 [0:255];
	(* ram_style = "distributed" *) reg [7:0] r3 [0:255];
	reg [31:0] cdvol = 32'd0;              // r[6Ch]
	initial for (i = 0; i < 256; i = i + 1) begin r0[i] = 8'd0; r1[i] = 8'd0; r2[i] = 8'd0; r3[i] = 8'd0; end
	wire [7:0] wi = addr[9:2];
	always @(posedge clk) if (sel && we && be[0]) r0[wi] <= wdata[7:0];
	always @(posedge clk) if (sel && we && be[1]) r1[wi] <= wdata[15:8];
	always @(posedge clk) if (sel && we && be[2]) r2[wi] <= wdata[23:16];
	always @(posedge clk) if (sel && we && be[3]) r3[wi] <= wdata[31:24];
	always @(posedge clk) if (sel && we && wi == 8'h6C) begin
		if (be[0]) cdvol[7:0]   <= wdata[7:0];
		if (be[1]) cdvol[15:8]  <= wdata[15:8];
		if (be[2]) cdvol[23:16] <= wdata[23:16];
		if (be[3]) cdvol[31:24] <= wdata[31:24];
	end

	// the voice registers again, one array per field, for the engine to read by voice
	// LUT-RAM, not block RAM: synthesis put vr_adsr in a block RAM once, and its
	// slow clock-to-output began the worst path of the build (0.007 ns of slack)
	(* ram_style = "distributed" *) reg [31:0] vr_vol   [0:31];   // {VOLR, VOLL}
	(* ram_style = "distributed" *) reg [15:0] vr_pitch [0:31];
	(* ram_style = "distributed" *) reg [15:0] vr_ssa   [0:31];
	(* ram_style = "distributed" *) reg [31:0] vr_adsr  [0:31];   // {ADSR2, ADSR1}
	initial for (i = 0; i < 32; i = i + 1) begin vr_vol[i] = 0; vr_pitch[i] = 0; vr_ssa[i] = 0; vr_adsr[i] = 0; end
	wire       cpu_voice = sel && we && (addr < 10'h180);
	wire [4:0] cv = addr[8:4];
	always @(posedge clk) if (cpu_voice) begin
		case (addr[3:2])
		2'd0: begin if (be[0]) vr_vol[cv][7:0] <= wdata[7:0];   if (be[1]) vr_vol[cv][15:8] <= wdata[15:8];
		            if (be[2]) vr_vol[cv][23:16] <= wdata[23:16]; if (be[3]) vr_vol[cv][31:24] <= wdata[31:24]; end
		2'd1: begin if (be[0]) vr_pitch[cv][7:0] <= wdata[7:0];  if (be[1]) vr_pitch[cv][15:8] <= wdata[15:8];
		            if (be[2]) vr_ssa[cv][7:0] <= wdata[23:16];  if (be[3]) vr_ssa[cv][15:8] <= wdata[31:24]; end
		2'd2: begin if (be[0]) vr_adsr[cv][7:0] <= wdata[7:0];   if (be[1]) vr_adsr[cv][15:8] <= wdata[15:8];
		            if (be[2]) vr_adsr[cv][23:16] <= wdata[23:16]; if (be[3]) vr_adsr[cv][31:24] <= wdata[31:24]; end
		default: ;
		endcase
	end

	// the halves of a CPU write, for the registers that do something when written
	wire        wlo = sel && we && (be[1:0] != 2'b00);
	wire        whi = sel && we && (be[3:2] != 2'b00);
	wire [15:0] dlo = wdata[15:0], dhi = wdata[31:16];
	// a write to the 16-bit register at offset o (its half of the word is o[1])
	`define WR16(o)  ((wi == (o) >> 2) && (((o) & 2) ? whi : wlo))

	reg [15:0] spucnt;
	reg [15:0] mvoll, mvolr;
	reg [15:0] evoll, evolr;          // reverb output volume
	reg [15:0] rv [0:31];             // the reverb configuration, 1DC0h..1DFFh
	reg [17:0] rbase, rcur;           // the reverb work area and where it is, halfwords
	reg [5:0]  rpos;                  // the resampler's position, a tick at a time
	reg [23:0] pmon, non, eon;
	reg [15:0] irqa;
	reg        irqf;
	assign irq = irqf;

	// =============================================================================
	// per-voice state
	// =============================================================================
	// Engine-only state, one array per field, written at the end of each voice.
	reg [16:0]  st_cnt  [0:31];   // pitch counter: [16:12] sample in block, [11:4] interpolation index
	reg [4:0]   st_dec  [0:31];   // the next sample of the block to decode (28 = all of it)
	reg [63:0]  st_h    [0:31];   // the last four decoded samples {h3, h2, h1, h0}, h0 newest
	reg [15:0]  st_addr [0:31];   // the current block, in 8-byte units
	reg [15:0]  st_want [0:31];   // the block wanted next, when st_need
	reg         st_need [0:31];
	reg [2:0]   st_ph   [0:31];   // envelope phase
	reg [15:0]  st_ec   [0:31];   // envelope counter
	reg [127:0] st_blk  [0:31];   // the current block, raw
	initial for (i = 0; i < 32; i = i + 1) begin
		st_cnt[i] = 0; st_dec[i] = 5'd28; st_h[i] = 0; st_addr[i] = 0; st_want[i] = 0; st_need[i] = 0;
		st_ph[i] = 0; st_ec[i] = 0; st_blk[i] = 0;
	end
	localparam PH_OFF = 3'd0, PH_ATT = 3'd1, PH_DEC = 3'd2, PH_SUS = 3'd3, PH_REL = 3'd4;

	// State both the CPU and the engine write.
	reg [15:0] env  [0:23];       // ENVX
	reg [15:0] lsax [0:23];       // LSAX
	reg [23:0] endx, kon_pend, koff_pend, ign_la, first_blk;

	// The prefetched next block, written by the fetcher.
	reg [127:0] nx_blk  [0:31];
	reg [15:0]  nx_addr [0:31];
	reg [15:0]  f_addr  [0:31];   // what the engine asked the fetcher for
	initial for (i = 0; i < 32; i = i + 1) begin nx_blk[i] = 0; nx_addr[i] = 16'hFFFF; f_addr[i] = 0; end
	reg [23:0]  nx_valid, f_req;

	// =============================================================================
	// the transfer FIFO and the line write-combiner
	// =============================================================================
	reg [15:0] fifo [0:63];
	reg [6:0]  f_wp, f_rp;
	wire [6:0] f_level = f_wp - f_rp;
	wire       f_empty = (f_wp == f_rp);
	reg [18:0] xptr;              // the transfer pointer, bytes
	wire [18:0] xnext = xptr + 19'd2;
	reg [15:0] cpu_hw;  reg cpu_hw_v;    // a halfword the CPU wrote to 1DA8, on its way in
	reg [31:0] dma_w;   reg [1:0] dma_w_n;   // a DMA word, two halfwords on their way in
	assign dma_ready = (dma_w_n == 2'd0) && (f_level <= 7'd60);

	reg [14:0]  wc_line;          // the line being combined (SPU RAM line)
	reg [127:0] wc_data;
	reg [15:0]  wc_mask;
	reg         wc_valid, wc_flush;
	reg [4:0]   wc_idle;

	// DMA reads of SPU RAM (transfer mode 3): a line at a time
	reg [14:0]  dr_line; reg [127:0] dr_data; reg dr_valid, dr_want;
	reg [1:0]   dr_st;   reg [15:0] dr_lo;

	// =============================================================================
	// the top 128 KB of SPU RAM, on chip (ps1_spu_ram.v)
	// =============================================================================
	// Port A takes the SPU's line traffic for lines 6000h..7FFFh (a voice fetch, a
	// transfer's write, a DMA read) in place of DDR3; port B is the reverb's.
	reg  [12:0]  ba_addr;  reg ba_we;  reg [15:0] ba_mask;  reg [127:0] ba_wdata;
	wire [127:0] ba_rdata;
	reg          lr_pend, lr_pend2;   // a port-A read on its way: the data is there two clocks on
	wire [12:0]  bb_addr;  wire bb_we;  wire [15:0] bb_mask;  wire [127:0] bb_wdata;
	wire [127:0] bb_rdata;
	ps1_spu_ram u_ram (
		.clk(clk),
		.a_addr(ba_addr), .a_we(ba_we), .a_mask(ba_mask), .a_wdata(ba_wdata), .a_rdata(ba_rdata),
		.b_addr(bb_addr), .b_we(bb_we), .b_mask(bb_mask), .b_wdata(bb_wdata), .b_rdata(bb_rdata)
	);
	function on_chip; input [14:0] line; on_chip = (line[14:13] == 2'b11); endfunction

	// =============================================================================
	// the memory port
	// =============================================================================
	localparam K_WR = 2'd0, K_FETCH = 2'd1, K_DR = 2'd2, K_CAP = 2'd3;
	// the capture buffers: a tick's four halfwords, waiting for the memory port
	reg  [8:0]  cap_i;                // the next position, 0..511
	reg  [8:0]  cap_at;               // the position of the ones waiting
	reg  [3:0]  cap_pend;             // CD left, CD right, voice 1, voice 3
	reg  [15:0] cap_v0, cap_v1, cap_v2, cap_v3;
	reg  [15:0] v1_out, v3_out;       // this tick's voice 1 and 3, after the envelope
	wire [1:0]  cap_k = cap_pend[0] ? 2'd0 : cap_pend[1] ? 2'd1 : cap_pend[2] ? 2'd2 : 2'd3;
	wire [15:0] cap_val = (cap_k == 2'd0) ? cap_v0 : (cap_k == 2'd1) ? cap_v1 : (cap_k == 2'd2) ? cap_v2 : cap_v3;
	reg [1:0]  m_kind;
	reg        rd_out;            // a read is in flight
	reg [1:0]  rd_kind;
	reg [4:0]  fv;                // the voice being fetched for
	reg [15:0] fa;                // ...and the block
	reg        f_stale;           // a transfer wrote RAM while it was in flight

	// the lowest voice asking for a block
	reg [4:0] f_pick; reg f_any;
	always @* begin
		f_pick = 5'd0; f_any = 1'b0;
		for (i = 23; i >= 0; i = i - 1) if (f_req[i]) begin f_pick = i[4:0]; f_any = 1'b1; end
	end
	wire [15:0] f_pick_addr = f_addr[f_pick];
	wire        fetch_clash = wc_valid && (wc_line == f_pick_addr[15:1]);   // the line being fetched has writes pending

	// =============================================================================
	// noise (Mednafen's form, from hardware tests)
	// =============================================================================
	reg [15:0] lfsr; reg [15:0] nz_div; reg [3:0] nz_cnt;
	wire [5:0] nz_rf  = spucnt[13:8];
	wire [15:0] nz_dinc = (nz_rf >= 6'h3C) ? 16'h8000 : (16'd2 << nz_rf[5:2]);
	wire [3:0]  nz_cinc = (nz_rf >= 6'h3C) ? 4'd8 : (4'd4 + {2'd0, nz_rf[1:0]});

	// =============================================================================
	// the engine
	// =============================================================================
	localparam E_IDLE = 5'd0, E_LD = 5'd1, E_LD2 = 5'd2, E_DEC = 5'd3, E_G1 = 5'd4, E_G2 = 5'd5,
	           E_G3 = 5'd6, E_OUT = 5'd7, E_ENV = 5'd8, E_PIT = 5'd9, E_VOL = 5'd10, E_WB = 5'd11,
	           E_MIX1 = 5'd12, E_MIX2 = 5'd13,
	           E_R0 = 5'd14, E_R1 = 5'd15, E_RDS = 5'd16, E_RX = 5'd17, E_RRD = 5'd18,
	           E_RC1 = 5'd19, E_RC2 = 5'd20, E_RC4 = 5'd22, E_RC5 = 5'd23, E_RC6 = 5'd24,
	           E_RC3 = 5'd21, E_RWR = 5'd25, E_RUS = 5'd26, E_RUP = 5'd27, E_ROUT = 5'd28,
	           E_ENV2 = 5'd29, E_CD = 5'd30;
	reg [4:0]  es;
	reg [3:0]  tick_pend;
	reg [4:0]  v;
	reg signed [23:0] sumL, sumR;
	reg signed [23:0] revL, revR;     // the voices with reverb on (EON), for its input
	reg signed [15:0] prev_out;
	reg [15:0] outl_c, outr_c;

	// the voice being worked on
	reg [16:0]  w_cnt;
	reg [4:0]   w_dec;
	reg signed [15:0] h0, h1, h2, h3;
	reg [15:0]  w_addr, w_want;
	reg         w_need, w_stall;
	reg [2:0]   w_ph;
	reg [15:0]  w_ec;
	reg [127:0] w_blk;
	reg [15:0]  w_env;
	reg [31:0]  w_vol, w_adsr;
	reg [15:0]  w_pitch, w_ssa;
	reg signed [31:0] w_acc;
	reg signed [15:0] w_smp, w_out;
	reg         w_freq; reg [15:0] w_faddr;

	// --- ADPCM decode of the sample at w_dec ------------------------------------
	wire [3:0]  d_nib   = w_blk[16 + {w_dec, 2'b00} +: 4];
	wire [3:0]  d_sh0   = w_blk[3:0];
	wire [3:0]  d_shift = (d_sh0 > 4'd12) ? 4'd9 : d_sh0;
	wire [3:0]  d_f     = w_blk[7:4];
	reg  signed [7:0] d_pos, d_neg;
	always @* case (d_f)
		4'd1: begin d_pos = 8'sd60;  d_neg = 8'sd0;   end
		4'd2: begin d_pos = 8'sd115; d_neg = -8'sd52; end
		4'd3: begin d_pos = 8'sd98;  d_neg = -8'sd55; end
		4'd4: begin d_pos = 8'sd122; d_neg = -8'sd60; end
		default: begin d_pos = 8'sd0; d_neg = 8'sd0; end    // 0, and 5..15 as 0 (DS, Mednafen)
	endcase
	wire signed [15:0] d_raw = $signed({d_nib, 12'd0}) >>> d_shift;
	wire signed [23:0] d_p0  = h0 * d_pos;
	wire signed [23:0] d_p1  = h1 * d_neg;
	wire signed [31:0] d_sum = $signed(d_raw) + (d_p0 >>> 6) + (d_p1 >>> 6);
	wire [15:0] d_x = clamp16(d_sum);

	// --- the Gaussian table ---------------------------------------------------------
	// The ROM registers its output, so the address is driven straight from the
	// state it is wanted in: asked in E_G1, answered in E_G2; asked in E_G2,
	// answered in E_G3. (A registered address as well made it two clocks, and the
	// interpolator multiplied by the taps of the voice before.)
	wire [7:0] g_i = w_cnt[11:4];
	wire [8:0] g_a0 = (es == E_G1) ? (9'h0FF - {1'b0, g_i}) : (9'h100 + {1'b0, g_i});
	wire [8:0] g_a1 = (es == E_G1) ? (9'h1FF - {1'b0, g_i}) : {1'b0, g_i};
	wire signed [15:0] g_q0, g_q1;
	ps1_spu_gauss u_gauss (.clk(clk), .a0(g_a0), .a1(g_a1), .q0(g_q0), .q1(g_q1));

	// --- the envelope, one step (section 7 of the spec) --------------------------------
	reg  [6:0] a_r; reg a_exp, a_dec;
	always @* begin
		case (w_ph)
		PH_ATT:  begin a_r = w_adsr[14:8];            a_exp = w_adsr[15]; a_dec = 1'b0;       end
		PH_DEC:  begin a_r = {w_adsr[7:4], 2'b00};    a_exp = 1'b1;       a_dec = 1'b1;       end
		PH_SUS:  begin a_r = w_adsr[28:22];           a_exp = w_adsr[31]; a_dec = w_adsr[30]; end
		default: begin a_r = {w_adsr[20:16], 2'b00};  a_exp = w_adsr[21]; a_dec = 1'b1;       end   // release
		endcase
	end
	wire [4:0]  a_sh   = a_r[6:2];
	wire [2:0]  a_base = 3'd7 - {1'b0, a_r[1:0]};
	wire signed [15:0] a_b = a_dec ? -$signed({13'd0, a_base}) - 16'sd1 : $signed({13'd0, a_base});   // +7..+4 / -8..-5
	wire signed [15:0] a_step = (a_sh < 5'd11) ? (a_b <<< (5'd11 - a_sh)) : a_b;
	wire [15:0] a_inc0 = (a_sh > 5'd11) ? (16'h8000 >> (a_sh - 5'd11)) : 16'h8000;
	wire signed [31:0] a_expd = a_step * $signed({1'b0, w_env[14:0]});
	// the one rate that never steps: 7Fh, or 7Ch for decay and release (shift 31)
	wire a_all = (w_ph == PH_DEC || w_ph == PH_REL) ? (a_r == 7'h7C) : (a_r == 7'h7F);
	reg  signed [15:0] a_s; reg [15:0] a_n;
	always @* begin
		a_s = a_step; a_n = a_inc0;
		if (a_exp && a_dec) a_s = a_expd >>> 15;
		if (a_exp && !a_dec && w_env >= 16'h6000) begin
			if (a_sh < 5'd10)       a_s = a_s >>> 2;
			else if (a_sh >= 5'd11) a_n = a_n >> 2;
			else begin a_s = a_s >>> 1; a_n = a_n >> 1; end
		end
		if (a_n == 16'd0 && !a_all) a_n = 16'd1;
	end
	// The step in two clocks: E_ENV works out the step and the counter (e_s,
	// e_cnt), E_ENV2 applies them. In one it was the worst path of the build.
	wire [15:0] a_cnt  = w_ec + a_n;
	reg  signed [15:0] e_s;
	reg  [15:0] e_cnt;
	wire signed [16:0] a_lv = $signed({1'b0, w_env}) + e_s;
	wire [15:0] a_new  = !e_cnt[15] ? w_env
	                   : a_dec ? ((a_lv < 0) ? 16'd0 : a_lv[15:0])
	                   :         ((a_lv > 17'sd32767) ? 16'h7FFF : a_lv[15:0]);
	wire [16:0] a_sl0  = {1'b0, w_adsr[3:0], 12'd0} >> 1;               // SL * 800h
	wire [16:0] a_sl1  = a_sl0 + 17'h0800;
	wire [15:0] a_sl   = (a_sl1 > 17'h7FFF) ? 16'h7FFF : a_sl1[15:0];   // min((SL+1)*800h, 7FFFh)

	// --- pitch, with modulation by the previous voice -----------------------------------
	wire signed [16:0] p_fac  = $signed({1'b0, prev_out}) ^ 17'sh08000;    // prev_out + 8000h, 0..FFFFh
	wire signed [32:0] p_mod  = $signed(w_pitch) * $signed(p_fac);         // sext16(PITCH) * factor
	wire [15:0] p_step0 = (v != 5'd0 && pmon[v]) ? p_mod[30:15] : w_pitch;
	wire [15:0] p_step  = (p_step0 > 16'h3FFF) ? 16'h3FFF : p_step0;
	wire [16:0] p_cnt   = w_cnt + {1'b0, p_step};
	wire        p_cross = (p_cnt >= 17'h1C000);

	// --- volume --------------------------------------------------------------------------
	wire signed [15:0] vl = volume(w_vol[15:0]);
	wire signed [15:0] vr = volume(w_vol[31:16]);
	wire signed [31:0] o_l = w_out * vl;
	wire signed [31:0] o_r = w_out * vr;
	wire signed [31:0] o_out = w_smp * $signed({1'b0, w_env[14:0]});

	// --- the final mix -------------------------------------------------------------------
	wire signed [31:0] m_l = $signed(outl_c) * $signed(volume(mvoll));
	wire signed [31:0] m_r = $signed(outr_c) * $signed(volume(mvolr));

	// =============================================================================
	// the reverb (spec section 13): one channel a tick, L on odd rpos, R on even
	// =============================================================================
	// the resampler's 39 taps; the odd ones other than the middle are zero
	function signed [15:0] fir;
		input [5:0] k;
		case (k)
		6'd0, 6'd38: fir = -16'sd1;      6'd2, 6'd36: fir = 16'sd2;
		6'd4, 6'd34: fir = -16'sd10;     6'd6, 6'd32: fir = 16'sd35;
		6'd8, 6'd30: fir = -16'sd103;    6'd10, 6'd28: fir = 16'sd266;
		6'd12, 6'd26: fir = -16'sd616;   6'd14, 6'd24: fir = 16'sd1332;
		6'd16, 6'd22: fir = -16'sd2960;  6'd18, 6'd20: fir = 16'sd10246;
		6'd19: fir = 16'sd16384;
		default: fir = 16'sd0;
		endcase
	endfunction
	reg signed [15:0] dsL [0:63];      // the input at 44.1 kHz, for the downsampler
	reg signed [15:0] dsR [0:63];
	reg signed [15:0] usL [0:31];      // the output at 22 kHz, for the upsampler
	reg signed [15:0] usR [0:31];
	initial for (i = 0; i < 64; i = i + 1) begin dsL[i] = 0; dsR[i] = 0; end
	initial for (i = 0; i < 32; i = i + 1) begin usL[i] = 0; usR[i] = 0; end
	reg        rc;                      // this tick's channel: 0 left, 1 right
	reg [5:0]  rk;                      // a filter tap
	reg [3:0]  rj;                      // a RAM access
	reg signed [39:0] racc;
	reg signed [15:0] rin_l, rin_r, rx, ria, rib, riia, riib, rmda, rmdb, rwet, rout_c, rout_o;
	reg signed [31:0] raccs;
	reg signed [15:0] rd [0:9];         // what the ten reads found
	reg [2:0]  rd_hw;                   // the read issued last clock: its halfword...
	reg        rd_in;                   // ...and whether it was on chip (the rest reads as zero)
	wire [5:0] r_dsi = rpos - 6'd38 + rk;
	wire signed [15:0] r_ds = rc ? dsR[r_dsi] : dsL[r_dsi];
	wire [4:0] r_usi = rpos[5:1] - 5'd19 + rk[4:0];
	wire signed [15:0] r_us = rc ? usR[r_usi] : usL[r_usi];
	wire [4:0] r_usm = (rpos[5:1] - 5'd19) + 5'd9;          // the other channel's middle value
	// the register a RAM access reads or writes, and whether it is one halfword back
	reg  [15:0] ra_x;
	reg         ra_m1;
	always @* begin
		ra_m1 = 1'b0;
		if (es == E_RWR) case (rj[1:0])
			2'd0:    ra_x = rv[10 + rc];                       // mSAME
			2'd1:    ra_x = rv[18 + rc];                       // mDIFF
			2'd2:    ra_x = rv[26 + rc];                       // mAPF1
			default: ra_x = rv[28 + rc];                       // mAPF2
		endcase else case (rj)
			4'd0: ra_x = rv[16 + rc];                          // dSAME
			4'd1: ra_x = rv[25 - rc];                          // dDIFF of the OTHER side
			4'd2: begin ra_x = rv[10 + rc]; ra_m1 = 1'b1; end  // mSAME - 1
			4'd3: begin ra_x = rv[18 + rc]; ra_m1 = 1'b1; end  // mDIFF - 1
			4'd4: ra_x = rv[12 + rc];                          // COMB1
			4'd5: ra_x = rv[14 + rc];                          // COMB2
			4'd6: ra_x = rv[20 + rc];                          // COMB3
			4'd7: ra_x = rv[22 + rc];                          // COMB4
			4'd8: ra_x = rv[26 + rc] - rv[0];                  // mAPF1 - dAPF1
			default: ra_x = rv[28 + rc] - rv[1];               // mAPF2 - dAPF2
		endcase
	end
	wire [17:0] ra_off = {ra_x, 2'b00} - {17'd0, ra_m1};
	wire [18:0] ra_t0  = {1'b0, rcur} + {1'b0, ra_off};
	wire [17:0] ra_t   = (ra_t0 >= 19'h40000) ? (ra_t0[17:0] + rbase) : ra_t0[17:0];   // wraps into [base, 3FFFFh]
	wire        ra_in  = (ra_t[17:16] == 2'b11);            // halfwords 30000h.. = bytes 60000h..: on chip
	// port B: the address straight from the state, as for the Gaussian ROM
	assign bb_addr  = ra_t[15:3];
	reg  signed [15:0] rw_val;
	always @* case (rj[1:0]) 2'd0: rw_val = riia; 2'd1: rw_val = riib; 2'd2: rw_val = rmda; default: rw_val = rmdb; endcase
	assign bb_we    = (es == E_RWR) && spucnt[7] && ra_in;
	assign bb_mask  = 16'b11 << {ra_t[2:0], 1'b0};
	assign bb_wdata = {8{rw_val}};
	wire signed [15:0] rb_hw = bb_rdata[{rd_hw, 4'd0} +: 16];
	wire signed [15:0] vIIR  = rv[2];
	wire signed [15:0] vWALL = rv[7];
	wire signed [15:0] vAPF1 = rv[8];
	wire signed [15:0] vAPF2 = rv[9];
	wire signed [15:0] vIN   = rc ? rv[31] : rv[30];
	function signed [39:0] iiasm;
		input signed [15:0] x;
		input signed [15:0] vi;
		begin
			if (vi == -16'sd32768) iiasm = (x == -16'sd32768) ? 40'sd0 : ($signed({{24{x[15]}}, x}) * -40'sd65536);
			else                   iiasm = $signed({{24{x[15]}}, x}) * (40'sd32768 - $signed({{24{vi[15]}}, vi}));
		end
	endfunction
	function signed [15:0] rneg;
		input signed [15:0] x;
		rneg = (x == -16'sd32768) ? 16'sd32767 : -x;
	endfunction
	function signed [31:0] mul;
		input signed [15:0] a, b;
		mul = a * b;
	endfunction
	// the all-pass coefficients negated a clock ahead, out of the multiply's path (the
	// registers change only on a CPU write; a sample's reverb runs long after)
	reg signed [15:0] nAPF1, nAPF2;
	always @(posedge clk) begin nAPF1 <= rneg(vAPF1); nAPF2 <= rneg(vAPF2); end

	// the loop address a jump would take, with this block's own loop-start flag applied
	wire [15:0] lsax_v = lsax[v];

	// =============================================================================
	// the one always block: registers, engine, fetcher, transfers
	// =============================================================================
	wire [4:0] cpu_v = addr[8:4];
	always @(posedge clk) begin
		if (rst) begin
			spucnt <= 16'd0; mvoll <= 16'd0; mvolr <= 16'd0; evoll <= 16'd0; evolr <= 16'd0;
			rbase <= 18'd0; rcur <= 18'd0; rpos <= 6'd0;
			for (i = 0; i < 32; i = i + 1) rv[i] <= 16'd0; pmon <= 0; non <= 0; eon <= 0; irqa <= 0; irqf <= 1'b0;
			endx <= 0; kon_pend <= 0; koff_pend <= 0; ign_la <= 0; first_blk <= 0; nx_valid <= 0; f_req <= 0;
			f_wp <= 0; f_rp <= 0; xptr <= 0; cpu_hw_v <= 1'b0; dma_w_n <= 2'd0;
			wc_valid <= 1'b0; wc_flush <= 1'b0; wc_mask <= 16'd0; wc_idle <= 5'd0;
			dr_valid <= 1'b0; dr_want <= 1'b0; dr_st <= 2'd0; dma_rvalid <= 1'b0;
			m_req <= 1'b0; m_we <= 1'b0; rd_out <= 1'b0; f_stale <= 1'b0; ba_we <= 1'b0; lr_pend <= 1'b0; lr_pend2 <= 1'b0;
			cap_i <= 9'd0; cap_pend <= 4'd0;
			es <= E_IDLE; tick_pend <= 4'd0; out_we <= 1'b0;
			lfsr <= 16'd0; nz_div <= 16'd0; nz_cnt <= 4'd0;
			for (i = 0; i < 24; i = i + 1) begin env[i] <= 16'd0; lsax[i] <= 16'd0; end
		end else begin
			out_we     <= 1'b0;
			dma_rvalid <= 1'b0;
			if (tick && tick_pend != 4'hF) tick_pend <= tick_pend + 4'd1;

			// --- register writes with a side effect ------------------------------
			if (`WR16(10'h188)) kon_pend[15:0]   <= kon_pend[15:0]   | dlo;
			if (`WR16(10'h18A)) kon_pend[23:16]  <= kon_pend[23:16]  | dhi[7:0];
			if (`WR16(10'h18C)) koff_pend[15:0]  <= koff_pend[15:0]  | dlo;
			if (`WR16(10'h18E)) koff_pend[23:16] <= koff_pend[23:16] | dhi[7:0];
			if (`WR16(10'h180)) mvoll <= dlo;
			if (`WR16(10'h182)) mvolr <= dhi;
			if (`WR16(10'h190)) pmon[15:0]  <= dlo;
			if (`WR16(10'h192)) pmon[23:16] <= dhi[7:0];
			if (`WR16(10'h194)) non[15:0]   <= dlo;
			if (`WR16(10'h196)) non[23:16]  <= dhi[7:0];
			if (`WR16(10'h198)) eon[15:0]   <= dlo;
			if (`WR16(10'h19A)) eon[23:16]  <= dhi[7:0];
			if (`WR16(10'h1A4)) irqa <= dlo;
			if (`WR16(10'h184)) evoll <= dlo;
			if (`WR16(10'h186)) evolr <= dhi;
			if (`WR16(10'h1A2)) begin rbase <= {dhi, 2'b00}; rcur <= {dhi, 2'b00}; end
			if (sel && we && wi >= 8'h70 && wi <= 8'h7F) begin
				if (wlo) rv[{wi[3:0], 1'b0}] <= dlo;
				if (whi) rv[{wi[3:0], 1'b1}] <= dhi;
			end
			if (`WR16(10'h1A6)) xptr <= {dhi, 3'd0};
			if (`WR16(10'h1AA)) begin
				spucnt <= dhi;
				if (!dhi[6]) irqf <= 1'b0;                      // writing IRQ enable = 0 acknowledges
			end
			if (`WR16(10'h1A8)) begin cpu_hw <= dlo; cpu_hw_v <= 1'b1; end
			// ENVX and LSAX, per voice
			if (sel && we && addr < 10'h180 && addr[3:2] == 2'd3) begin
				if (be[1:0] != 2'b00) env[cpu_v] <= dlo;
				if (be[3:2] != 2'b00) begin
					lsax[cpu_v] <= dhi;
					// DuckStation's rule: a write sticks against the loop-start flag
					// unless the voice is still in the first block after KON
					if (st_ph[cpu_v] == PH_OFF || !first_blk[cpu_v]) ign_la[cpu_v] <= 1'b1;
				end
			end
			if (dma_wr && dma_ready) begin dma_w <= dma_wdata; dma_w_n <= 2'd2; end

			// --- into the FIFO: the CPU's halfword first, then the DMA's two -------------
			if (cpu_hw_v && f_level < 7'd64) begin
				fifo[f_wp[5:0]] <= cpu_hw; f_wp <= f_wp + 7'd1; cpu_hw_v <= 1'b0;
			end else if (dma_w_n != 2'd0 && f_level < 7'd64) begin
				fifo[f_wp[5:0]] <= (dma_w_n == 2'd2) ? dma_w[15:0] : dma_w[31:16];
				f_wp <= f_wp + 7'd1; dma_w_n <= dma_w_n - 2'd1;
			end

			// --- out of the FIFO, into the write-combiner, a halfword a clock -----------
			if (!f_empty && !wc_flush) begin
				if (wc_valid && wc_line != xptr[18:4]) wc_flush <= 1'b1;     // another line: send this one first
				else begin
					wc_line  <= xptr[18:4];
					wc_valid <= 1'b1;
					wc_data[{xptr[3:1], 4'd0} +: 16] <= fifo[f_rp[5:0]];
					wc_mask[{xptr[3:1], 1'b0} +: 2]  <= 2'b11;
					f_rp <= f_rp + 7'd1;
					xptr <= xptr + 19'd2;
					wc_idle <= 5'd0;
					if (spucnt[6] && spucnt[15] && xnext[18:3] == irqa) irqf <= 1'b1;   // after the step
				end
			end else if (wc_valid && !wc_flush) begin
				// nothing more coming: send it after a moment, so a voice sees it
				if (wc_idle == 5'd16) wc_flush <= 1'b1; else wc_idle <= wc_idle + 5'd1;
			end

			// --- the memory port ----------------------------------------------------------
			ba_we <= 1'b0;
			lr_pend2 <= lr_pend; lr_pend <= 1'b0;
			if (!m_req) begin
				if (wc_flush && on_chip(wc_line)) begin
					// on chip: written now, and done
					ba_addr <= wc_line[12:0]; ba_we <= 1'b1; ba_mask <= wc_mask; ba_wdata <= wc_data;
					wc_valid <= 1'b0; wc_flush <= 1'b0; wc_mask <= 16'd0;
					nx_valid <= 24'd0; f_stale <= 1'b1;
				end else if (wc_flush) begin
					m_addr <= SPU_LINE + {9'd0, wc_line}; m_we <= 1'b1; m_wdata <= wc_data; m_wmask <= wc_mask;
					m_req <= 1'b1; m_kind <= K_WR;
				end else if (!rd_out && f_any && fetch_clash) begin
					wc_flush <= 1'b1;                              // the line it wants has writes pending
				end else if (!rd_out && f_any) begin
					fv <= f_pick; fa <= f_pick_addr; f_stale <= 1'b0;
					f_req[f_pick] <= 1'b0;
					if (on_chip(f_pick_addr[15:1])) begin
						ba_addr <= f_pick_addr[13:1]; lr_pend <= 1'b1; rd_out <= 1'b1; rd_kind <= K_FETCH;
					end else begin
						m_addr <= SPU_LINE + {9'd0, f_pick_addr[15:1]}; m_we <= 1'b0;
						m_req <= 1'b1; m_kind <= K_FETCH;
					end
				end else if (!rd_out && dr_want) begin
					if (on_chip(dr_line)) begin
						ba_addr <= dr_line[12:0]; lr_pend <= 1'b1; rd_out <= 1'b1; rd_kind <= K_DR;
					end else begin
						m_addr <= SPU_LINE + {9'd0, dr_line}; m_we <= 1'b0;
						m_req <= 1'b1; m_kind <= K_DR;
					end
				end else if (cap_pend != 4'd0) begin
					// a capture halfword: buffer k at 400h*k, position cap_at
					m_addr  <= SPU_LINE + {16'd0, cap_k, cap_at[8:3]};
					m_wdata <= {8{cap_val}};
					m_wmask <= 16'b11 << {cap_at[2:0], 1'b0};
					m_we <= 1'b1; m_req <= 1'b1; m_kind <= K_CAP;
					cap_pend[cap_k] <= 1'b0;
				end
			end else if (m_ready) begin
				m_req <= 1'b0;
				if (m_kind == K_WR) begin
					// the line has gone to RAM; every prefetched block may be stale now
					wc_valid <= 1'b0; wc_flush <= 1'b0; wc_mask <= 16'd0;
					nx_valid <= 24'd0; f_stale <= 1'b1;
				end else if (m_kind == K_CAP) begin
					// a capture halfword: nothing to collect, and no voice is told
					// (one playing from the capture area hears it a block late)
				end else begin
					rd_out <= 1'b1; rd_kind <= m_kind;
				end
			end
			if ((m_valid || lr_pend2) && rd_out) begin
				rd_out <= 1'b0;
				if (rd_kind == K_FETCH) begin
					nx_blk[fv]  <= lr_pend2 ? ba_rdata : m_rdata;
					nx_addr[fv] <= fa;
					if (!f_stale) nx_valid[fv] <= 1'b1;
				end else begin
					dr_data <= lr_pend2 ? ba_rdata : m_rdata; dr_valid <= 1'b1; dr_want <= 1'b0;
				end
			end

			// --- DMA reads of SPU RAM: two halfwords a word, a line fetched as needed ---
			case (dr_st)
			2'd0: if (dma_rd && !dma_rvalid) dr_st <= 2'd1;
			2'd1, 2'd2: begin
					if (dr_valid && dr_line == xptr[18:4] && !(wc_valid && wc_line == xptr[18:4])) begin
						if (dr_st == 2'd1) begin dr_lo <= dr_data[{xptr[3:1], 4'd0} +: 16]; dr_st <= 2'd2; end
						else begin
							dma_rdata <= {dr_data[{xptr[3:1], 4'd0} +: 16], dr_lo}; dma_rvalid <= 1'b1; dr_st <= 2'd0;
						end
						xptr <= xptr + 19'd2;
					end else if (wc_valid && wc_line == xptr[18:4]) begin
						wc_flush <= 1'b1; dr_valid <= 1'b0;
					end else if (!dr_want && !(rd_out && rd_kind == K_DR)) begin
						dr_line <= xptr[18:4]; dr_valid <= 1'b0; dr_want <= 1'b1;
					end
				end
			default: dr_st <= 2'd0;
			endcase

			// =====================================================================
			// the engine
			// =====================================================================
			case (es)
			E_IDLE: if (tick_pend != 4'd0) begin
					tick_pend <= tick_pend - (tick ? 4'd0 : 4'd1);
					v <= 5'd0; sumL <= 24'sd0; sumR <= 24'sd0; revL <= 24'sd0; revR <= 24'sd0; prev_out <= 16'sd0;
					es <= E_LD;
				end

			E_LD: begin
					w_cnt <= st_cnt[v]; w_dec <= st_dec[v];
					{h3, h2, h1, h0} <= st_h[v];
					w_addr <= st_addr[v]; w_want <= st_want[v]; w_need <= st_need[v];
					w_ph <= st_ph[v]; w_ec <= st_ec[v]; w_blk <= st_blk[v];
					w_env <= env[v];
					w_vol <= vr_vol[v]; w_pitch <= vr_pitch[v]; w_ssa <= vr_ssa[v]; w_adsr <= vr_adsr[v];
					w_stall <= 1'b0; w_freq <= 1'b0;
					es <= E_LD2;
				end

			E_LD2: begin
					// KOFF, then KON: both latched since the last tick
					if (koff_pend[v]) begin
						koff_pend[v] <= 1'b0;
						if (w_ph != PH_OFF && w_ph != PH_REL) begin w_ph <= PH_REL; w_ec <= 16'd0; end
					end
					if (kon_pend[v]) begin
						kon_pend[v] <= 1'b0;
						w_want <= {w_ssa[15:1], 1'b0}; w_need <= 1'b1;
						w_cnt <= 17'd0; w_dec <= 5'd28;               // nothing of the old block is decoded
						h0 <= 16'sd0; h1 <= 16'sd0; h2 <= 16'sd0; h3 <= 16'sd0;
						w_env <= 16'd0; w_ec <= 16'd0; w_ph <= PH_ATT;
						endx[v] <= 1'b0; ign_la[v] <= 1'b0; first_blk[v] <= 1'b1;
					end
					if (!spucnt[15]) begin w_env <= 16'd0; w_ph <= PH_OFF; end
					es <= E_DEC;
				end

			// Decode, a sample a clock: first what is left of a block being left
			// (the interpolator wants every sample of it), then the new block,
			// then up to the sample the pitch counter has reached.
			E_DEC: begin
					if (w_need && w_dec < 5'd28) begin
						{h3, h2, h1} <= {h2, h1, h0}; h0 <= d_x; w_dec <= w_dec + 5'd1;
					end else if (w_need) begin
						if (nx_valid[v] && nx_addr[v] == w_want) begin
							w_blk <= nx_blk[v]; w_addr <= w_want; w_need <= 1'b0; w_dec <= 5'd0;
							nx_valid[v] <= 1'b0;
							if (nx_blk[v][10] && !ign_la[v]) lsax[v] <= w_want;   // loop start
							if (spucnt[6] && spucnt[15] && (w_want == irqa || w_want + 16'd1 == irqa)) irqf <= 1'b1;
						end else begin
							// not here yet: ask for it, and hold this voice where it is
							if (!f_req[v] && !(rd_out && rd_kind == K_FETCH && fv == v) && !(m_req && m_kind == K_FETCH && fv == v)) begin
								w_freq <= 1'b1; w_faddr <= w_want;
							end
							w_stall <= 1'b1;
							es <= E_G1;
						end
					end else if (w_dec <= w_cnt[16:12]) begin
						{h3, h2, h1} <= {h2, h1, h0}; h0 <= d_x; w_dec <= w_dec + 5'd1;
					end else begin
						// the block after this one, ahead of time
						if (!(nx_valid[v] && nx_addr[v] == (w_blk[8] ? {lsax_v[15:1], 1'b0} : w_addr + 16'd2))
						    && !f_req[v] && !(rd_out && rd_kind == K_FETCH && fv == v) && !(m_req && m_kind == K_FETCH && fv == v)) begin
							w_freq <= 1'b1; w_faddr <= w_blk[8] ? {lsax_v[15:1], 1'b0} : w_addr + 16'd2;
						end
						es <= E_G1;
					end
				end

			E_G1: es <= E_G2;
			E_G2: begin
					w_acc <= g_q0 * h3 + g_q1 * h2;
					es <= E_G3;
				end
			E_G3: begin w_acc <= w_acc + g_q0 * h1 + g_q1 * h0; es <= E_OUT; end
			E_OUT: begin
					w_smp <= non[v] ? $signed(lfsr) : $signed(w_acc[30:15]);
					es <= E_ENV;
				end
			E_ENV: begin
					// the output uses the level from BEFORE this tick's step
					w_out <= o_out >>> 15;
					e_s <= a_s; e_cnt <= a_cnt;
					es <= E_ENV2;
				end
			E_ENV2: begin
					if (w_ph != PH_OFF) begin
						if (e_cnt[15]) w_ec <= 16'd0; else w_ec <= e_cnt;
						w_env <= a_new;
						if (w_ph == PH_ATT && a_new >= 16'h7FFF) begin w_ph <= PH_DEC; w_ec <= 16'd0; end
						if (w_ph == PH_DEC && a_new <= a_sl)     begin w_ph <= PH_SUS; w_ec <= 16'd0; end
						if (w_ph == PH_REL && a_new == 16'd0)    w_ph <= PH_OFF;
					end
					es <= E_PIT;
				end
			E_PIT: begin
					if (!w_stall) begin
						if (p_cross) begin
							w_cnt <= p_cnt - 17'h1C000;
							w_need <= 1'b1; first_blk[v] <= 1'b0;
							if (w_blk[8]) begin                          // loop end
								endx[v] <= 1'b1;
								w_want <= {lsax_v[15:1], 1'b0};
								if (!w_blk[9] && !non[v]) begin w_env <= 16'd0; w_ph <= PH_OFF; end
							end else w_want <= w_addr + 16'd2;
						end else w_cnt <= p_cnt;
					end
					es <= E_VOL;
				end
			E_VOL: begin
					sumL <= sumL + (o_l >>> 15);
					sumR <= sumR + (o_r >>> 15);
					if (eon[v]) begin revL <= revL + (o_l >>> 15); revR <= revR + (o_r >>> 15); end
					prev_out <= w_out;
					if (v == 5'd1) v1_out <= w_out;
					if (v == 5'd3) v3_out <= w_out;
					es <= E_WB;
				end
			E_WB: begin
					env[v] <= w_env;
					if (w_freq) f_req[v] <= 1'b1;
					if (v == 5'd23) es <= E_CD;
					else begin v <= v + 5'd1; es <= E_LD; end
				end
			E_CD: begin
					// CD audio, at the CD volume: into the mix (SPUCNT bit 0) and the
					// reverb (bit 2); and the tick's capture
					if (spucnt[0]) begin
						sumL <= sumL + (mul(cd_l, cdvol[15:0]) >>> 15);
						sumR <= sumR + (mul(cd_r, cdvol[31:16]) >>> 15);
					end
					if (spucnt[2]) begin
						revL <= revL + (mul(cd_l, cdvol[15:0]) >>> 15);
						revR <= revR + (mul(cd_r, cdvol[31:16]) >>> 15);
					end
					if (spucnt[15]) begin
						cap_v0 <= cd_l; cap_v1 <= cd_r; cap_v2 <= v1_out; cap_v3 <= v3_out;
						cap_at <= cap_i; cap_pend <= 4'b1111; cap_i <= cap_i + 9'd1;
						// the IRQ address on any of the four halfwords about to be written
						// (byte 400h*k + 2*cap_i, an 8-byte unit only when cap_i[1:0] is 0),
						// as DuckStation's WriteToCaptureBuffers: games time CD audio by it
						if (spucnt[6] && irqa[15:9] == 7'd0 && irqa[6:0] == cap_i[8:2] && cap_i[1:0] == 2'd0)
							irqf <= 1'b1;
					end
					es <= E_R0;
				end
			// --- the reverb ---------------------------------------------------------------
			E_R0: begin
					// muted: the voices go from the mix AND from the reverb's input
					rin_l <= spucnt[14] ? clamp16(revL) : 16'sd0;
					rin_r <= spucnt[14] ? clamp16(revR) : 16'sd0;
					if (!spucnt[14]) begin sumL <= 24'sd0; sumR <= 24'sd0; end
					es <= E_R1;
				end
			E_R1: begin
					dsL[rpos] <= rin_l; dsR[rpos] <= rin_r;
					rc <= !rpos[0];                                // left on odd, right on even
					rk <= 6'd0; racc <= 40'sd0;
					es <= E_RDS;
				end
			E_RDS: begin                                       // the 39-tap downsampler
					racc <= racc + fir(rk) * r_ds;
					if (rk == 6'd38) es <= E_RX; else rk <= rk + 6'd1;
				end
			E_RX: begin rx <= clamp16(racc >>> 15); rj <= 4'd0; es <= E_RRD; end
			E_RRD: begin                                       // ten reads, a clock each, one behind
					rd_hw <= ra_t[2:0]; rd_in <= ra_in;
					if (rj != 4'd0) rd[rj - 4'd1] <= rd_in ? rb_hw : 16'sd0;
					if (rj == 4'd10) es <= E_RC1; else rj <= rj + 4'd1;
				end
			E_RC1: begin
					ria <= clamp16(((mul(rd[0], vWALL) >>> 14) + (mul(rx, vIN) >>> 14)) >>> 1);
					rib <= clamp16(((mul(rd[1], vWALL) >>> 14) + (mul(rx, vIN) >>> 14)) >>> 1);
					es <= E_RC2;
				end
			E_RC2: begin
					riia <= clamp16(((mul(ria, vIIR) >>> 14) + (iiasm(rd[2], vIIR) >>> 14)) >>> 1);
					riib <= clamp16(((mul(rib, vIIR) >>> 14) + (iiasm(rd[3], vIIR) >>> 14)) >>> 1);
					es <= E_RC3;
				end
			E_RC3: begin
					raccs <= (mul(rd[4], rv[3]) >>> 14) + (mul(rd[5], rv[4]) >>> 14)
					       + (mul(rd[6], rv[5]) >>> 14) + (mul(rd[7], rv[6]) >>> 14);
					es <= E_RC4;
				end
			E_RC4: begin rmda <= clamp16((raccs + (mul(rd[8], nAPF1) >>> 14)) >>> 1); es <= E_RC5; end
			E_RC5: begin
					rmdb <= clamp16(rd[8] + (((mul(rmda, vAPF1) >>> 14) + (mul(rd[9], nAPF2) >>> 14)) >>> 1));
					es <= E_RC6;
				end
			E_RC6: begin rwet <= clamp16(rd[9] + (mul(rmdb, vAPF2) >>> 15)); rj <= 4'd0; es <= E_RWR; end
			E_RWR: begin                                       // four writes (bb_we: only with the master enable)
					if (rj == 4'd3) es <= E_RUS; else rj <= rj + 4'd1;
				end
			E_RUS: begin
					if (rc) usR[rpos[5:1]] <= rwet; else usL[rpos[5:1]] <= rwet;
					rk <= 6'd0; racc <= 40'sd0;
					es <= E_RUP;
				end
			E_RUP: begin                                       // the 20-tap upsampler, this channel
					racc <= racc + fir({rk[4:0], 1'b0}) * r_us;
					if (rk == 6'd19) es <= E_ROUT; else rk <= rk + 6'd1;
				end
			E_ROUT: begin
					rout_c <= clamp16(racc >>> 14);
					rout_o <= rc ? usL[r_usm] : usR[r_usm];
					es <= E_MIX1;
				end
			E_MIX1: begin
					// the wet signal into the mix, at its own volume
					outl_c <= clamp16(sumL + (mul(rc ? rout_o : rout_c, evoll) >>> 15));
					outr_c <= clamp16(sumR + (mul(rc ? rout_c : rout_o, evolr) >>> 15));
					if (rc) rcur <= (rcur == 18'h3FFFF) ? rbase : rcur + 18'd1;   // after R, the area moves on
					rpos <= rpos + 6'd1;
					es <= E_MIX2;
				end
			E_MIX2: begin
					out_lr <= {clamp16(m_r >>> 15), clamp16(m_l >>> 15)};
					out_we <= 1'b1;
					// the noise generator, once a tick
					if (nz_div + nz_dinc >= 16'h8000 || (nz_div + nz_dinc) < nz_div) begin
						nz_div <= 16'd0;
						if (nz_cnt + nz_cinc >= 4'd8) begin
							nz_cnt <= (nz_cnt + nz_cinc) & 4'd7;
							lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[12] ^ lfsr[11] ^ lfsr[10] ^ 1'b1};
						end else nz_cnt <= nz_cnt + nz_cinc;
					end else nz_div <= nz_div + nz_dinc;
					es <= E_IDLE;
				end
			default: es <= E_IDLE;
			endcase
		end
	end

	// the engine's arrays, written once per voice, in one place each
	always @(posedge clk) if (es == E_WB) begin
		st_cnt[v] <= w_cnt; st_dec[v] <= w_dec; st_h[v] <= {h3, h2, h1, h0};
		st_addr[v] <= w_addr; st_want[v] <= w_want; st_need[v] <= w_need;
		st_ph[v] <= w_ph; st_ec[v] <= w_ec; st_blk[v] <= w_blk;
		if (w_freq) f_addr[v] <= w_faddr;
	end

	// =============================================================================
	// register reads (same clock)
	// =============================================================================
	wire [31:0] rq = {r3[wi], r2[wi], r1[wi], r0[wi]};
	wire [15:0] stat = {4'd0, cap_i[8], !f_empty || cpu_hw_v || dma_w_n != 2'd0 || dr_st != 2'd0,
	                    spucnt[5:4] == 2'd2 && f_empty, spucnt[5:4] == 2'd3,
	                    (spucnt[5:4] == 2'd2 && f_empty) || spucnt[5:4] == 2'd3,
	                    irqf, spucnt[5:0]};
	always @* begin
		rdata = rq;
		if (addr < 10'h180) begin
			if (addr[3:2] == 2'd3) rdata = {lsax[cpu_v], env[cpu_v]};
		end else case (wi)
			8'h67: rdata = {8'd0, endx[23:16], endx[15:0]};             // 1D9C ENDX0 / 1D9E ENDX1
			8'h6A: rdata = {rq[31:16], 16'hFFFF};                       // 1DA8 FIFO reads nothing; SPUCNT as written
			8'h6B: rdata = {stat, rq[15:0]};                            // 1DAC, SPUSTAT
			8'h6E: rdata = {volume(mvolr), volume(mvoll)};              // 1DB8/1DBA current main volume
			default: begin
				if (wi >= 8'h80 && wi < 8'h98) rdata = {volume(vr_vol[wi[4:0]][31:16]), volume(vr_vol[wi[4:0]][15:0])};
				else if (wi >= 8'hA0) rdata = 32'hFFFF_FFFF;
			end
		endcase
	end

	`undef WR16
endmodule

`default_nettype wire
