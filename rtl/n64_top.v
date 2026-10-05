//////////////////////////////////////////////////////////////////////////////////
// n64_top.v - the Nintendo 64 as far as its CPU needs one: the VR4300 with its
// caches, RDRAM and the cartridge in DDR3, our own boot ROM where the PIF ROM
// sits, SP memory, and the RCP's registers -- the MI's interrupts, the VI's
// timing, the rest answering.
//
// --- memory -------------------------------------------------------------------------
//
// DDR3 holds both memories, byte for byte in address order: byte A of RDRAM is
// byte A%16 of line RDRAM_LINE + A/16, and the cartridge is the ROM file as the
// host sent it (the host packs it little-endian into 32-bit words, so the bytes
// land in file order) from CART_LINE. The CPU is big-endian, so the adapter here
// turns a line's bytes into the CPU's lanes (byte k of a doubleword is bits
// [63-8k -: 8]) on the way in and back on the way out.
//
// --- the caches ----------------------------------------------------------------------
//
// The VR4300's sizes: a 16 kB instruction cache of 32-byte lines and an 8 kB data
// cache of 16-byte lines, both direct-mapped, both for KSEG0's view of RDRAM. The
// tags are LUT RAM, so a lookup is decided in the clock the request comes and the
// answer -- registered, with the data out of block RAM -- is there the next: a hit
// costs the CPU nothing.
//
// The data cache writes through: a store updates the line if it holds it and goes
// to RDRAM through a small buffer, so the CPU does not wait for DDR3 either. The
// chip writes back instead; the only program that can tell is one that relies on
// dirty data NOT reaching memory, and the game library's DMA routines all do the
// opposite (write back before a DMA out, invalidate after a DMA in), which a
// write-through cache satisfies by construction. CACHE's write-backs are
// therefore nothing to do, and its invalidates invalidate.
//
// Reads wait for the write buffer to empty, so no read can overtake a store.
// Uncached (KSEG1) accesses keep the last line each port read, and stores update
// those too. An uncached store does NOT update the caches -- nor does the chip's.
//
// --- what the PC does -----------------------------------------------------------------
//
// With run low the CPU is held in reset, the caches are swept empty, and the
// host's fill owns the DDR3 port: the cartridge goes in, a line at a time; then
// run is raised and the boot ROM (rtl/n64_boot_rom.v, tools/n64/n64bootrom.py)
// copies the game into RDRAM and jumps to it. The host reads RDRAM back through
// hr_* -- a line on request -- which is how the framebuffer gets off the board
// until the VI streams it.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module n64_top #(
	parameter [23:0] RDRAM_LINE = 24'h00_0000,     // RDRAM at DDR3 0
	parameter [23:0] CART_LINE  = 24'h10_0000,     // the cartridge at 16 MB
	parameter [10:0] HALFLINE   = 11'd1587         // 50 MHz / (60 Hz x 525 half-lines)
) (
	input  wire         clk,
	input  wire         rst,
	input  wire         run,            // low: the CPU in reset and the host filling the cartridge
	// --- the host filling the cartridge -----------------------------------------
	input  wire [21:0]  host_windex,    // 32-bit word index into the cartridge
	input  wire         host_we,
	input  wire [31:0]  host_wdata,
	input  wire         fill_end,
	// --- the host reading a line (the framebuffer, for now) -------------------------
	input  wire         hr_go,
	input  wire [23:0]  hr_line,
	output reg          hr_done,
	output reg  [127:0] hr_data,
	// --- DDR3 ---------------------------------------------------------------------------
	output reg  [23:0]  d_addr,
	output reg          d_req,
	output reg          d_we,
	output reg  [127:0] d_wdata,
	output reg  [15:0]  d_wmask,
	input  wire         d_ready,
	input  wire [127:0] d_rdata,
	input  wire         d_valid,
	input  wire         d_calibrated,
	// --- for the host ---------------------------------------------------------------
	input  wire [15:0]  joy1,
	input  wire         vi_slow,        // the VI at half rate (the game at half speed)
	output wire [31:0]  vi_status,
	output wire [31:0]  vi_origin,
	output wire [31:0]  vi_width,
	output wire [31:0]  vi_yscale,
	output wire [31:0]  dbg_pc,
	output wire [31:0]  dbg_retired,
	// the debug window: dbg_sel picks what dbg_q shows (see "the debug window" below)
	input  wire [31:0]  dbg_sel,        // [5:0] what dbg_q shows, [15:8] the DMA log's entry, [25:16] a DMEM/IMEM doubleword
	output reg  [31:0]  dbg_q,
	// --- the picture, for the frame stream ------------------------------------------
	// word i of the frame is RDRAM at the VI's origin + 4i, its bytes in address
	// order (the first byte on top: the network sends a word top byte first, so
	// the packet carries the framebuffer byte for byte)
	input  wire         fbr_req,
	input  wire [18:0]  fbr_word,
	output reg          fbr_ack,
	output reg  [31:0]  fbr_rdata,
	// the picture for HDMI (hdmi_tx asks for a pixel a clock ahead, in its pixel clock)
	input  wire         pclk,
	input  wire [9:0]   vid_x,
	input  wire [9:0]   vid_y,
	input  wire         vid_req,
	output wire [23:0]  vid_rgb,
	output wire [17:0]  fb_words,        // the frame, in words
	output wire [15:0]  fb_wpr,          // a row, in words
	output wire         fb_halve,        // too big for the stream: every other row is sent
	// --- the controllers and the save chip (n64_pif.v) --------------------------------------
	input  wire [15:0]  stick1,          // controller 1's stick: X [15:8], Y [7:0], signed
	input  wire [3:0]   pad_present,     // which controllers are plugged in
	input  wire [1:0]   eep_size,        // the cartridge's EEPROM: 0 none, 1 4 kbit, 2 16 kbit
	input  wire         eh_we,           // the EEPROM from the host (saving and loading it)
	input  wire [10:0]  eh_addr,
	input  wire [7:0]   eh_wdata,
	output wire [7:0]   eh_rdata,
	// --- sound: 44.1 kHz stereo for the host's ring (ps1_aring.v) ----------------------------
	output reg  [31:0]  audio_lr,        // {right, left}, signed
	output reg          audio_lr_we
);
	// =============================================================================
	// the CPU
	// =============================================================================
	wire        i_req, i_cached, c_dreq, c_dwe, c_dcached, c_dcache;
	wire [4:0]  c_dcop;
	wire [31:0] i_addr, c_daddr;
	wire [7:0]  c_dbe;
	wire [63:0] c_dwdata;
	wire        i_ready, c_dready;
	wire [31:0] i_rdata;
	wire [63:0] c_drdata;
	wire        tr_valid, tr_we, tr_exc;
	wire [31:0] tr_pc;
	wire [4:0]  tr_rd, tr_code;
	wire [63:0] tr_val;
	wire        cpu_rst = rst || !run;
	wire        mi_irq;
	reg  [31:0] retired;
	wire [7:0]  cpu_stall;
	// (debugging) clocks the CPU waited for reason dbg_sel[10:8] (see vr4300's dbg_stall)
	reg  [31:0] n_stall;
	always @(posedge clk) n_stall <= cpu_rst ? 32'd0 : n_stall + {31'd0, cpu_stall[dbg_sel[10:8]]};

	vr4300 cpu (
		.clk(clk), .rst(cpu_rst),
		.i_req(i_req), .i_addr(i_addr), .i_cached(i_cached), .i_ready(i_ready), .i_rdata(i_rdata),
		.d_req(c_dreq), .d_we(c_dwe), .d_addr(c_daddr), .d_cached(c_dcached), .d_be(c_dbe), .d_wdata(c_dwdata),
		.d_cache(c_dcache), .d_cop(c_dcop),
		.d_ready(c_dready), .d_rdata(c_drdata),
		.irq({4'd0, mi_irq}), .count_tick(1'b1),
		.tr_valid(tr_valid), .tr_pc(tr_pc), .tr_we(tr_we), .tr_rd(tr_rd), .tr_val(tr_val),
		.tr_exc(tr_exc), .tr_code(tr_code), .dbg_stall(cpu_stall)
	);
	reg [31:0] last_pc;
	always @(posedge clk) begin
		if (cpu_rst) retired <= 32'd0;
		else if (tr_valid) begin retired <= retired + 32'd1; last_pc <= tr_pc; end
	end
	// (debugging) instructions retired in SM64's idle loop (80246dd0..80246ddf): the rest is
	// the CPU's real work
	reg [31:0] retired_idle;
	always @(posedge clk) begin
		if (cpu_rst) retired_idle <= 32'd0;
		else if (tr_valid && tr_pc[31:4] == 28'h80246DD) retired_idle <= retired_idle + 32'd1;
	end
	assign dbg_pc = last_pc;
	assign dbg_retired = retired;

	// =============================================================================
	// block memories: the boot ROM (PIF ROM), PIF RAM, SP DMEM/IMEM
	// =============================================================================
	// the boot ROM: rtl/n64_boot_rom.v, generated by tools/n64/n64bootrom.py
	wire [31:0] boot_i, boot_d0, boot_d1;
	n64_boot_rom u_boot_i  (.a(i_addr[7:2]),             .q(boot_i));
	n64_boot_rom u_boot_d0 (.a({c_daddr[7:3], 1'b0}),    .q(boot_d0));
	n64_boot_rom u_boot_d1 (.a({c_daddr[7:3], 1'b1}),    .q(boot_d1));
	integer k;                                 // (SP memory is the RSP's: n64_rsp.v)

	// =============================================================================
	// the RCP's registers
	// =============================================================================
	reg  [31:0] vi [0:13];
	reg  [9:0]  vi_line;
	reg  [11:0] vi_clk;
	reg  [5:0]  mi_intr, mi_mask;
	reg  [31:0] mi_mode;
	// the PI: its registers and DMA engine are below (pi_*); these say what the
	// CPU wrote, for the engine to take
	reg         pi_we;
	reg  [3:0]  pi_widx;
	reg  [31:0] pi_wval;
	reg  [23:0] pi_dram, pi_rdlen, pi_wrlen;
	reg  [31:0] pi_cart;
	reg         pi_busy, pi_done;
	reg  [31:0] pi_dom [5:12];                   // the domain timing registers: stored, unused
	// the DMA engine's line requests to the DDR3 port (it is below)
	reg          pd_rd_req, pd_rd_ack, pd_wr_req, pd_wr_ack;
	// the SI: its registers, a CPU write handed to its engine, and its DDR3 requests
	reg  [23:0]  si_dram;
	reg  [31:0]  si_rd, si_wr;
	reg          si_busy, si_done;
	reg          si_we;
	reg  [2:0]   si_widx;
	reg  [31:0]  si_wval;
	reg          sd_rd_req, sd_rd_ack, sd_wr_req, sd_wr_ack;
	// the AI: its registers, a CPU write handed to it, and its DDR3 line reads
	reg  [23:0]  ai_addr0, ai_addr1;
	reg  [17:0]  ai_len0, ai_len1;
	reg  [1:0]   ai_count;
	reg          ai_enable;
	reg  [13:0]  ai_dacrate;
	reg          ai_we, ai_irq;
	reg  [2:0]   ai_widx;
	reg  [31:0]  ai_wval;
	reg          ad_rd_req, ad_rd_ack;
	// the RSP's DMA and the RDP's command reads
	wire         rd_rd_req, rd_wr_req, cf_req, cw_req;
	reg          rd_rd_ack, rd_wr_ack, cf_ack, cw_ack;
	wire [23:0]  rd_rd_line, rd_wr_line, cf_line, cw_line;
	wire [127:0] cw_data;  wire [15:0] cw_mask;      // the RDP's line writes
	// the RDP's span reads: pipelined. Each request is taken on rq_ready (a clock); the lines
	// come back in order on rs_valid. While any are outstanding no one else may read, so
	// every line that returns then is the RDP's (writes go on as before)
	wire         rq_valid;  wire [23:0] rq_line;
	reg          rq_ready, rs_valid;
	reg  [127:0] rs_data;
	reg  [6:0]   rdp_out;                             // pipelined reads outstanding (the RDP's, the RSP's)
	// Every read taken is noted with its owner in one queue, in order (the lines come back in
	// that order): 0 the RDP's, 1 the RSP read-ahead's, 2 the one read a state below is
	// waiting for (the CPU's, PI's, ...). So the CPU need not wait for the pipelined reads to
	// drain (it waited for them, and the read-aheads keep some in flight nearly always: SM64's
	// CPU ran at 0.4 instructions a clock). At most 4 reads out in all (ddr3_mem drops a line
	// past its return queue).
	reg          if_b;                                // the I-cache line's second half is asked for
	reg  [1:0]   one_out;                             // single reads out (two: an I-cache line's halves)
	wire [1:0]   q_head;                              // the owner of the next line back
	wire         rd_ok = rdp_out + {5'd0, one_out} < 7'd12;  // room for another read (ddr3_mem's return queue holds 32)
	wire         head_one = q_head == 2'd2;
	// the RSP's DMA reads go through a read-ahead (n64_rdp_stream.v) on the same pipelined
	// port: it waited a whole DDR3 round trip a line, about 0.5 bytes a clock, and SM64's
	// microcode spent most of its time in its DMA wait. Each read taken is noted with its
	// owner (0 the RDP, 1 the RSP), so the lines coming back go to whoever asked.
	wire         x_qv;  wire [19:0] x_ql;             // the RSP read-ahead's request
	reg          x_qr, x_rs;                          // taken; a line back for it
	wire         x_ack;  wire [127:0] x_data;
	reg          x_flush_p;                           // a write landed in the read-ahead: empty it
	wire         x_snoop_hit;
	reg          rq_own;                              // the owner of the read in S_RQ
	reg  [1:0]   rq_tag [0:15];  reg [3:0] rq_tw, rq_tr;  // owners of the reads taken, oldest at rq_tr
	assign q_head = rq_tag[rq_tr];
	reg  [127:0] rd_rd_data, cf_data;
	wire [127:0] rd_wr_data;
	wire [15:0]  rd_wr_mask;
	wire         sp_irq_set, sp_irq_clr, dp_irq;
	// the CPU's accesses to SP memory, waiting for the RSP's port
	reg          dsp_pend, isp_pend;
	wire [63:0]  sp_q;
	wire         sp_ack;
	reg          sp_busy, sp_for_d, sp_ia2;
	reg  [7:0]   c_dbe_q;
	reg          c_dwe_q;
	reg  [63:0]  c_dwdata_q;
	reg  [23:0]  ad_rd_line;
	reg  [127:0] ad_rd_data;
	reg  [23:0]  sd_rd_line, sd_wr_line;
	reg  [127:0] sd_rd_data, sd_wr_data;
	reg  [15:0]  sd_wr_mask;
	wire [511:0] pif_flat;             // PIF RAM (n64_pif.v), word i in [511 - 32 i -: 32]
	wire         pif_busy;
	reg  [23:0]  pd_rd_line, pd_wr_line;
	reg  [127:0] pd_rd_data, pd_wr_data;
	reg  [15:0]  pd_wr_mask;
	// the RSP's and the RDP's registers, all of them, for reading
	wire [31:0]  sp_regs [0:8];
	wire [255:0] dp_flat;
	initial for (k = 0; k < 14; k = k + 1) vi[k] = 32'd0;
	initial for (k = 5; k < 13; k = k + 1) pi_dom[k] = 32'd0;
	assign vi_status = vi[0];
	assign vi_origin = vi[1];
	assign vi_width  = vi[2];
	assign vi_yscale = vi[13];
	assign mi_irq = |(mi_intr & mi_mask);
	wire [9:0]  vi_vsync = (vi[6][9:0] != 10'd0) ? vi[6][9:0] : 10'd525;
	// the framebuffer's shape: a row of WIDTH pixels at 4 bytes (status 3) or 2,
	// and Y_SCALE (2.10) framebuffer lines to 240 on screen, 480 at most
	// (registered, a step at a time: it changes when the VI is set up, and two
	//  multiplies in a row were feeding the network core's frame counter)
	reg  [21:0] vi_h22;
	reg  [9:0]  vi_h;
	reg  [15:0] fb_wpr_r;
	reg  [25:0] fb_w26, fb_h26;
	reg         fb_halve_r;
	reg  [17:0] fb_words_r;
	always @(posedge clk) begin
		vi_h22   <= ({10'd0, vi[13][11:0]} * 22'd240) >> 10;
		vi_h     <= (vi_h22 > 22'd480) ? 10'd480 : (vi_h22 == 22'd0) ? 10'd240 : vi_h22[9:0];
		fb_wpr_r <= (vi[0][1:0] == 2'd3) ? {4'd0, vi[2][11:0]} : {5'd0, vi[2][11:1]};
		fb_w26   <= fb_wpr_r * vi_h;
		fb_h26   <= fb_wpr_r * {1'b0, vi_h[9:1]};
		fb_halve_r <= fb_w26 > 26'd262143;
		fb_words_r <= fb_halve_r ? fb_h26[17:0] : fb_w26[17:0];
	end
	assign fb_wpr   = fb_wpr_r;
	// the stream counts a frame's words in 18 bits: a frame bigger than that (640 x
	// 480 at 32 bits, which is how krom's tests draw) goes out every other row
	assign fb_halve = fb_halve_r;
	assign fb_words = fb_words_r;

	// the VI's clock: a half-line every HALFLINE clocks (twice that with vi_slow: the
	// game then has twice the clocks a frame, and runs at half speed); V_INTR raises the
	// MI's VI bit
	wire [11:0] halfline_n = vi_slow ? {HALFLINE, 1'b0} : {1'b0, HALFLINE};
	always @(posedge clk) begin
		if (cpu_rst) begin vi_line <= 10'd0; vi_clk <= 12'd0; end
		else if (vi_clk == halfline_n - 12'd1) begin
			vi_clk <= 12'd0;
			vi_line <= (vi_line >= vi_vsync) ? 10'd0 : vi_line + 10'd1;
		end else vi_clk <= vi_clk + 12'd1;
	end
	wire vi_hit = (vi_clk == halfline_n - 12'd1) && (((vi_line >= vi_vsync) ? 10'd0 : vi_line + 10'd1) == vi[3][9:0]);

	function [31:0] reg_read; input [31:0] a;
		begin
			reg_read = 32'd0;
			if (a[31:20] == 12'h043) begin                          // MI
				case (a[3:2])
				2'd0: reg_read = mi_mode;
				2'd1: reg_read = 32'h0202_0102;
				2'd2: reg_read = {26'd0, mi_intr};
				2'd3: reg_read = {26'd0, mi_mask};
				endcase
			end else if (a[31:20] == 12'h044) begin                 // VI
				reg_read = (a[5:2] == 4'd4) ? {22'd0, vi_line} : vi[a[5:2]];
			end else if (a[31:20] == 12'h046) begin                 // PI: never busy here
				case (a[5:2])
				4'd0: reg_read = {8'd0, pi_dram};
				4'd1: reg_read = pi_cart;
				4'd2: reg_read = {8'd0, pi_rdlen};
				4'd3: reg_read = {8'd0, pi_wrlen};
				// busy from the clock the DMA is asked for, not two later when its
				// engine has it: a status read in between said "free", and software
				// started the next DMA on top of the running one
				4'd4: reg_read = {28'd0, mi_intr[4], 2'b00, pi_busy || (pi_we && (pi_widx == 4'd2 || pi_widx == 4'd3))};
				default: reg_read = (a[5:2] <= 4'd12) ? pi_dom[a[5:2]] : 32'd0;
				endcase
			end else if (a[31:20] == 12'h045) begin                 // AI
				// AI_STATUS, as ares has it; anything else reads the length playing
				reg_read = (a[4:2] == 3'd3)
				         ? {ai_count > 2'd1, ai_count > 2'd0, 4'd0, ai_enable, 1'b1, 3'd0, 1'b1, 19'd0, ai_count > 2'd1}
				         : {14'd0, ai_len0};
			end else if (a[31:20] == 12'h048) begin                 // SI
				case (a[4:2])
				3'd0: reg_read = {8'd0, si_dram};
				3'd1: reg_read = si_rd;
				3'd4: reg_read = si_wr;
				// busy from the clock the DMA is asked for (see PI_STATUS)
				3'd6: reg_read = {19'd0, mi_intr[1], 11'd0, si_busy || (si_we && (si_widx == 3'd1 || si_widx == 3'd4))};
				default: reg_read = 32'd0;
				endcase
			end else if (a[31:20] == 12'h040 && a[19:16] == 4'h4) begin  // SP
				reg_read = sp_regs[{1'b0, a[4:2]}];
			end else if (a[31:20] == 12'h040 && a[19:16] == 4'h8) begin  // SP_PC
				reg_read = (a[4:2] == 3'd0) ? sp_regs[8] : 32'd0;
			end else if (a[31:20] == 12'h041) begin                 // DP
				reg_read = dp_flat[255 - 32 * a[4:2] -: 32];
			end
		end
	endfunction

	// =============================================================================
	// the memory adapter
	// =============================================================================
	// regions of the physical map
	function is_rdram; input [31:0] a; is_rdram = a < 32'h0080_0000; endfunction
	function is_cart;  input [31:0] a; is_cart  = a >= 32'h1000_0000 && a < 32'h1400_0000; endfunction
	function is_boot;  input [31:0] a; is_boot  = a >= 32'h1FC0_0000 && a < 32'h1FC0_07C0; endfunction
	function is_pifr;  input [31:0] a; is_pifr  = a >= 32'h1FC0_07C0 && a < 32'h1FC0_0800; endfunction
	function is_sp;    input [31:0] a; is_sp    = a >= 32'h0400_0000 && a < 32'h0400_2000; endfunction
	function [23:0] line_of; input [31:0] a;
		line_of = is_rdram(a) ? RDRAM_LINE + {4'd0, a[22:4]} : CART_LINE + {4'd0, a[25:4]};
	endfunction
	// a 16-byte line (byte j in bits [8j+7:8j]) to the CPU's doubleword at a[3]
	function [63:0] lanes_in; input [127:0] l; input a3;
		integer j;
		for (j = 0; j < 8; j = j + 1) lanes_in[63 - 8 * j -: 8] = l[8 * (j + (a3 ? 8 : 0)) +: 8];
	endfunction
	// a 32-bit word out of the doubleword at a[3]
	function [31:0] word_of; input [127:0] l; input [31:0] a;
		reg [63:0] dw;
		begin dw = lanes_in(l, a[3]); word_of = a[2] ? dw[31:0] : dw[63:32]; end
	endfunction

	// --- the caches' arrays -------------------------------------------------------------
	// Four and eight times the VR4300's: a 64 kB I-cache and a 64 kB D-cache, direct-mapped with
	// its line sizes. Only the timing differs (SM64 missed 8.3 and 17.2 times a 1000
	// instructions in the chip's sizes, 2.1 and 6.3 in these -- the misses were a third of
	// the CPU's clocks). A CACHE op by index names a line of the chip's cache: it acts on
	// the lines here that share that index, four or eight (see cop_k).
	// Only RDRAM is cached (below 8 MB): tags are {valid, address [22:16]}.
	(* ram_style = "distributed" *) reg [7:0] itag [0:2047];      // 2048 lines of 32 bytes
	(* ram_style = "distributed" *) reg [7:0] dtag [0:4095];      // 4096 lines of 16 bytes
	(* ram_style = "block" *) reg [127:0] idata [0:4095];         // 64 kB
	(* ram_style = "block" *) reg [127:0] ddata [0:4095];         // 64 kB
	initial for (k = 0; k < 2048; k = k + 1) itag[k] = 8'd0;
	initial for (k = 0; k < 4096; k = k + 1) dtag[k] = 8'd0;
	wire        i_cacheable = i_cached && is_rdram(i_addr);
	wire        d_cacheable = c_dcached && is_rdram(c_daddr);
	wire [10:0] i_idx = i_addr[15:5];
	wire [11:0] d_idx = c_daddr[15:4];
	wire        i_hit_now = itag[i_idx] == {1'b1, i_addr[22:16]};
	wire        d_hit_now = dtag[d_idx] == {1'b1, c_daddr[22:16]};

	// the CPU's lanes into a line (byte k of the doubleword is byte 8*a[3]+k of the line)
	wire [127:0] c_line;
	wire [15:0]  c_mask;
	genvar g;
	generate for (g = 0; g < 8; g = g + 1) begin : g_lane
		assign c_line[8 * g +: 8]       = c_dwdata[63 - 8 * g -: 8];
		assign c_line[8 * (g + 8) +: 8] = c_dwdata[63 - 8 * g -: 8];
		assign c_mask[g]     = !c_daddr[3] && c_dbe[g];
		assign c_mask[g + 8] =  c_daddr[3] && c_dbe[g];
	end endgenerate

	// --- the answers: a cache hit answers out of block RAM, everything else out of a register
	reg          i_from_cache, d_from_cache;     // how the last request is being answered
	reg          i_ready_r, d_ready_r;
	reg  [31:0]  i_rdata_r;
	reg  [63:0]  d_rdata_r;
	reg  [127:0] i_bram, d_bram;                 // the block RAMs' outputs
	reg  [31:0]  ipa, dpa;                       // the request being answered
	assign i_ready  = i_ready_r;
	assign c_dready = d_ready_r;
	assign i_rdata  = i_from_cache ? word_of(i_bram, ipa) : i_rdata_r;
	assign c_drdata = d_from_cache ? lanes_in(d_bram, dpa[3]) : d_rdata_r;

	// --- uncached: the line each port read last --------------------------------------------
	reg  [23:0]  il_tag, dl_tag;
	reg          il_v, dl_v;
	reg  [127:0] il, dl;

	// --- the write buffer: stores on their way to DDR3 ---------------------------------------
	reg  [23:0]  wb_addr [0:3];
	reg  [127:0] wb_data [0:3];
	reg  [15:0]  wb_mask [0:3];
	reg  [2:0]   wb_wp, wb_rp;
	wire [2:0]   wb_n = wb_wp - wb_rp;
	wire         wb_full = wb_n == 3'd4;
	wire         wb_empty = wb_n == 3'd0;

	// --- requests waiting for the DDR3 port ------------------------------------------------
	// The CPU may give up a fetch: the one behind a taken branch's delay slot is
	// abandoned, and the next fetch comes without waiting for its answer. A new
	// fetch supersedes any unanswered one. A DDR3 read remembers which address it
	// was launched for, and answers only if that is still the address wanted (a
	// read for an abandoned fetch still fills its line, and answers nobody).
	reg          ip, dp;              // a fetch / a data access waits for the port
	reg          ip_fill, dp_fill;    // ... to fill a cache line (else: an uncached read)
	reg          dp_store;            // a store waiting for room in the write buffer
	reg          dp_cop;              // a CACHE operation waiting to be done
	reg  [4:0]   dpcop;
	reg  [127:0] dpline;
	reg  [15:0]  dpmask;
	reg  [31:0]  i_for, d_for;
	reg          i_replay, d_replay;  // a fill has finished: read the line again to answer

	localparam S_IDLE = 4'd0, S_FILL = 4'd1, S_WB = 4'd2, S_DREAD = 4'd3, S_DFILL = 4'd4,
	           S_IREAD = 4'd5, S_IFILL0 = 4'd6, S_IFILL1 = 4'd7, S_HREAD = 4'd8,
	           S_PREAD = 4'd9, S_PWRITE = 4'd10, S_FREAD = 4'd11, S_SREAD = 4'd12, S_SWRITE = 4'd13, S_AREAD = 4'd14,
	           S_RREAD = 5'd15, S_RWRITE = 5'd16, S_CREAD = 5'd17, S_CWRITE = 5'd18, S_RQ = 5'd19, S_VREAD = 5'd20;
	reg  [4:0]   st;
	// the single read taken: its state requesting, the memory taking it
	wire         one_take = d_req && d_ready && (st == S_DREAD || st == S_DFILL || st == S_IREAD || st == S_IFILL0 || st == S_IFILL1 || st == S_VREAD
	                     || st == S_HREAD || st == S_PREAD || st == S_FREAD || st == S_SREAD || st == S_AREAD || st == S_RREAD || st == S_CREAD);
	// the host's fill: four words to a line. A finished line moves to its own
	// buffer for the write, so the next line's first word can arrive while that
	// write waits (clearing one shared buffer lost exactly those words).
	reg  [127:0] fill_buf, fill_wbuf;
	reg  [19:0]  fill_line, fill_wline;
	reg  [1:0]   fill_cnt;
	reg          fill_pending;
	reg          hr_pending;
	// --- the picture for HDMI: VI's framebuffer lines into n64_vid's two-line buffer ---------
	// When the pixel side wants a new source line, its DDR3 lines are read one at a time
	// (S_VREAD) at VI_ORIGIN + line x stride; a line is up to 80 of them.
	wire [8:0]   hv_want;
	reg  [8:0]   hv_line;             // the line fetched last (or being fetched)
	reg          hv_busy;             // fetching it
	reg  [6:0]   hv_k, hv_n;          // the DDR3 line next / how many a source line has
	reg  [23:0]  hv_base;             // its first byte in RDRAM
	reg  [23:0]  hv_org;              // VI_ORIGIN as it was at the top of this HDMI frame
	reg          hv_we;  reg [7:0] hv_wa;  reg [127:0] hv_wd;
	wire         hv_bpp32 = vi[0][1:0] == 2'd3;
	wire [13:0]  hv_stride = hv_bpp32 ? {vi[2][11:0], 2'b00} : {1'b0, vi[2][11:0], 1'b0};
	wire         hv_go = hv_busy && hv_k != hv_n;
	n64_vid u_vid (.clk(clk), .wr_en(hv_we), .wr_addr(hv_wa), .wr_data(hv_wd), .want(hv_want),
		.width(vi[2][11:0]), .bpp32(hv_bpp32), .on(vi[0][1:0] != 2'd0),
		.pclk(pclk), .x(vid_x), .y(vid_y), .req(vid_req), .rgb(vid_rgb));
	reg  [11:0]  sweep;               // while held: the caches are invalidated, a line a clock
	reg  [2:0]   cop_k;               // a CACHE op by index: which of the lines (4 I, 8 D) it is on
	wire         cop_idx;
	// (debugging) where the CPU's clocks go: clocks a fetch / a data access waited for DDR3,
	// and how many times one began to
	reg  [31:0]  n_ipw, n_dpw, n_ipn, n_dpn;  reg ip_was, dp_was;
	reg  [31:0]  n_ifill, n_dfill;       // lines filled (the real misses)
	always @(posedge clk) begin
		ip_was <= ip; dp_was <= dp;
		if (cpu_rst) begin n_ipw <= 0; n_dpw <= 0; n_ipn <= 0; n_dpn <= 0; n_ifill <= 0; n_dfill <= 0; end
		else begin
			if (st == S_IFILL1 && d_valid && head_one) n_ifill <= n_ifill + 1;
			if (st == S_DFILL && d_valid && head_one) n_dfill <= n_dfill + 1;
			if (ip) n_ipw <= n_ipw + 1;
			if (dp) n_dpw <= n_dpw + 1;
			if (ip && !ip_was) n_ipn <= n_ipn + 1;
			if (dp && !dp_was) n_dpn <= n_dpn + 1;
		end
	end
	// the frame stream's reads: one line in hand
	reg          fr_pending, fr_v;
	reg  [23:0]  fr_tag, fr_for;
	reg  [127:0] fr_line;
	wire [23:0]  fr_byte = vi[1][23:0] + {3'd0, fbr_word, 2'b00};
	wire [23:0]  fr_lidx = RDRAM_LINE + {4'd0, fr_byte[22:4]};

	// block RAM reads: the request's line, or a replay after a fill -- through ONE
	// address each. Two reads with their own addresses are two read ports, and
	// with the fill's write that is three: more than a block RAM has, and the
	// synthesis quietly built 24 kB of cache out of LUTs instead.
	wire [11:0] i_ridx = i_req ? i_addr[15:4] : ipa[15:4];
	wire [11:0] d_ridx = c_dreq ? d_idx : dpa[15:4];
	integer bk;
	always @(posedge clk) begin
		if (i_req || i_replay) i_bram <= idata[i_ridx];
		if (c_dreq || d_replay) d_bram <= ddata[d_ridx];

		if (rst) begin
			st <= S_IDLE; d_req <= 1'b0; d_we <= 1'b0; d_addr <= 24'd0; d_wdata <= 128'd0; d_wmask <= 16'd0;
			il_v <= 1'b0; dl_v <= 1'b0; ip <= 1'b0; dp <= 1'b0; ip_fill <= 1'b0; dp_fill <= 1'b0;
			dp_store <= 1'b0; dp_cop <= 1'b0; i_replay <= 1'b0; d_replay <= 1'b0;
			i_ready_r <= 1'b0; d_ready_r <= 1'b0; i_from_cache <= 1'b0; d_from_cache <= 1'b0;
			wb_wp <= 3'd0; wb_rp <= 3'd0;
			fill_pending <= 1'b0; fill_cnt <= 2'd0; fill_buf <= 128'd0; fill_line <= 20'd0;
			hr_pending <= 1'b0; hr_done <= 1'b0; sweep <= 12'd0; cop_k <= 3'd0;
			fr_pending <= 1'b0; fr_v <= 1'b0; fbr_ack <= 1'b0;
			hv_busy <= 1'b0; hv_line <= 9'h1FF; hv_we <= 1'b0; hv_k <= 7'd0; hv_n <= 7'd0;
			pd_rd_ack <= 1'b0; pd_wr_ack <= 1'b0; sd_rd_ack <= 1'b0; sd_wr_ack <= 1'b0; si_we <= 1'b0;
			ad_rd_ack <= 1'b0; ai_we <= 1'b0; rd_rd_ack <= 1'b0; rd_wr_ack <= 1'b0; cf_ack <= 1'b0; cw_ack <= 1'b0;
			rq_ready <= 1'b0; rs_valid <= 1'b0; rdp_out <= 7'd0; x_qr <= 1'b0; x_rs <= 1'b0; rq_tw <= 4'd0; rq_tr <= 4'd0;
			one_out <= 2'd0;
			dsp_pend <= 1'b0; isp_pend <= 1'b0;
			mi_intr <= 6'd0; mi_mask <= 6'd0; mi_mode <= 32'd0;
			pi_we <= 1'b0;
		end else begin
			if (!pd_rd_req) pd_rd_ack <= 1'b0;          // the engine has taken it
			if (!pd_wr_req) pd_wr_ack <= 1'b0;
			if (!sd_rd_req) sd_rd_ack <= 1'b0;
			if (!sd_wr_req) sd_wr_ack <= 1'b0;
			if (!ad_rd_req) ad_rd_ack <= 1'b0;
			if (!rd_wr_req) rd_wr_ack <= 1'b0;
			// (the RDP's acks are a clock long: it may ask again on the clock it takes one)
			cf_ack <= 1'b0; cw_ack <= 1'b0; rq_ready <= 1'b0; rs_valid <= 1'b0; x_qr <= 1'b0; x_rs <= 1'b0;
			// the pipelined reads: taken (S_RQ) and returned, to their owners
			rdp_out <= rdp_out + {6'd0, st == S_RQ && d_ready} - {6'd0, d_valid && !head_one};
			// each read taken, its owner queued: a pipelined read (S_RQ), or the single read (its
			// state, the clock the memory takes it)
			if (st == S_RQ && d_ready) begin rq_tag[rq_tw] <= {1'b0, rq_own}; rq_tw <= rq_tw + 4'd1; end
			if (one_take) begin rq_tag[rq_tw] <= 2'd2; rq_tw <= rq_tw + 4'd1; end
			one_out <= one_out + {1'b0, one_take} - {1'b0, d_valid && head_one};
			if (d_valid) rq_tr <= rq_tr + 4'd1;
			if (d_valid && !head_one) begin
				rs_data <= d_rdata;
				if (q_head[0]) x_rs <= 1'b1; else rs_valid <= 1'b1;
			end
			// the RSP's DMA reads: its read-ahead answers
			if (!rd_rd_req) rd_rd_ack <= 1'b0;
			if (x_ack) begin rd_rd_ack <= 1'b1; rd_rd_data <= x_data; end
			si_we <= 1'b0; ai_we <= 1'b0;
			if (ai_irq) mi_intr[2] <= 1'b1;
			if (si_done) begin mi_intr[1] <= 1'b1; il_v <= 1'b0; dl_v <= 1'b0; end
			if (sp_irq_set) mi_intr[0] <= 1'b1;
			if (sp_irq_clr) mi_intr[0] <= 1'b0;
			if (dp_irq) mi_intr[5] <= 1'b1;
			// the RSP's memory's answers
			if (sp_ack && sp_for_d) begin d_ready_r <= 1'b1; d_rdata_r <= sp_q; dsp_pend <= 1'b0; end
			if (sp_ack && !sp_for_d) begin i_ready_r <= 1'b1; i_rdata_r <= sp_ia2 ? sp_q[31:0] : sp_q[63:32]; isp_pend <= 1'b0; end
			i_replay <= 1'b0; d_replay <= 1'b0; pi_we <= 1'b0;
			// a DMA has finished: the PI's interrupt; the uncached lines may be stale
			if (pi_done) begin mi_intr[4] <= 1'b1; il_v <= 1'b0; dl_v <= 1'b0; end
			// (the uncached reads' lines too: dropped when another writer writes them)
			if (d_req && d_ready && d_we && st != S_WB && d_addr == dl_tag) dl_v <= 1'b0;
			if (d_req && d_ready && d_we && st != S_WB && d_addr == il_tag) il_v <= 1'b0;
			// --- the host's fill (only while the CPU is held) --------------------------------
			if (host_we) begin
				fill_line <= host_windex[21:2];
				fill_cnt  <= host_windex[1:0];
				if (host_windex[1:0] == 2'd3) begin
					fill_wbuf <= {host_wdata, fill_buf[95:0]};
					fill_wline <= host_windex[21:2];
					fill_buf <= 128'd0;
					fill_pending <= 1'b1;
				end else fill_buf[host_windex[1:0] * 32 +: 32] <= host_wdata;
			end
			if (fill_end && fill_cnt != 2'd3) begin       // the short last line
				fill_wbuf <= fill_buf; fill_wline <= fill_line; fill_buf <= 128'd0; fill_pending <= 1'b1;
			end
			if (hr_go) begin hr_pending <= 1'b1; hr_done <= 1'b0; end
			// the streamer's word: out of the line in hand, or the line fetched
			fbr_ack <= 1'b0;
			// the picture: a new source line wanted (none being fetched) -- where it is, how long
			hv_we <= 1'b0;
			if (!hv_busy && hv_want != hv_line) begin : hv_start
				reg [14:0] bytes;
				bytes = hv_bpp32 ? {1'b0, vi[2][11:0], 2'b00} : {2'b00, vi[2][11:0], 1'b0};
				hv_line <= hv_want; hv_k <= 7'd0; hv_busy <= 1'b1;
				hv_n <= (bytes + 15'd15 > 15'd1280) ? 7'd80 : bytes[10:4] + {6'd0, bytes[3:0] != 4'd0};
				// (the origin taken once a frame, at its first line: a flip half way down would
				// otherwise show the rest of the frame from the other buffer)
				hv_base <= (hv_want == 9'd0 ? vi[1][23:0] : hv_org) + hv_want * hv_stride;
				if (hv_want == 9'd0) hv_org <= vi[1][23:0];
			end else if (hv_busy && hv_k == hv_n && st != S_VREAD) hv_busy <= 1'b0;
			if (fbr_req && !fbr_ack) begin
				if (fr_v && fr_tag == fr_lidx) begin
					fbr_rdata <= {fr_line[8 * {fr_byte[3:2], 2'd0} +: 8], fr_line[8 * {fr_byte[3:2], 2'd1} +: 8],
					              fr_line[8 * {fr_byte[3:2], 2'd2} +: 8], fr_line[8 * {fr_byte[3:2], 2'd3} +: 8]};
					fbr_ack <= 1'b1;
				end else if (!fr_pending) begin
					fr_pending <= 1'b1; fr_for <= fr_lidx;
				end
			end
			if (vi_hit) mi_intr[3] <= 1'b1;
			// held: the caches go empty, so a new cartridge never meets an old line
			if (!run) begin
				sweep <= sweep + 12'd1;                          // (the tags: their write ports below)
				il_v <= 1'b0; dl_v <= 1'b0;
			end

			// --- the instruction port ----------------------------------------------------
			if (i_req) begin
				ip <= 1'b0;                                   // whatever was waiting is given up
				ipa <= i_addr;
				i_from_cache <= 1'b0;
				if (i_cacheable && i_hit_now) begin
					i_ready_r <= 1'b1; i_from_cache <= 1'b1;
				end else if (i_cacheable) begin
					i_ready_r <= 1'b0; ip <= 1'b1; ip_fill <= 1'b1;
				end else if (is_boot(i_addr)) begin
					i_ready_r <= 1'b1; i_rdata_r <= boot_i;
				end else if ((is_rdram(i_addr) || is_cart(i_addr)) && il_v && il_tag == line_of(i_addr)) begin
					i_ready_r <= 1'b1; i_rdata_r <= word_of(il, i_addr);
				end else if (is_rdram(i_addr) || is_cart(i_addr)) begin
					i_ready_r <= 1'b0; ip <= 1'b1; ip_fill <= 1'b0;
				end else if (is_sp(i_addr)) begin
					i_ready_r <= 1'b0; isp_pend <= 1'b1;            // the RSP's memory answers in two clocks
				end else begin
					i_ready_r <= 1'b1; i_rdata_r <= 32'd0;
				end
			end

			// --- the data port ---------------------------------------------------------------
			if (c_dreq) begin
				dpa <= c_daddr;
				d_from_cache <= 1'b0;
				if (c_dcache) begin
					// CACHE: the tags are changed by the port's state machine (their one writer)
					d_ready_r <= 1'b0; dp_cop <= 1'b1; dpcop <= c_dcop;
				end else if (c_dwe && (is_rdram(c_daddr) || is_cart(c_daddr))) begin
					if (is_rdram(c_daddr)) begin
						// a store: the cached line (if held) now, RDRAM through the buffer
						// (the cached line, if held, is written by the data array's port below)
						if (dl_v && dl_tag == line_of(c_daddr))
							for (bk = 0; bk < 16; bk = bk + 1) if (c_mask[bk]) dl[8 * bk +: 8] <= c_line[8 * bk +: 8];
						if (il_v && il_tag == line_of(c_daddr))
							for (bk = 0; bk < 16; bk = bk + 1) if (c_mask[bk]) il[8 * bk +: 8] <= c_line[8 * bk +: 8];
						if (!wb_full) begin
							wb_addr[wb_wp[1:0]] <= line_of(c_daddr); wb_data[wb_wp[1:0]] <= c_line; wb_mask[wb_wp[1:0]] <= c_mask;
							wb_wp <= wb_wp + 3'd1;
							d_ready_r <= 1'b1;
						end else begin
							d_ready_r <= 1'b0; dp_store <= 1'b1; dpline <= c_line; dpmask <= c_mask;
						end
					end else d_ready_r <= 1'b1;                   // the cartridge is not written
				end else if (d_cacheable && d_hit_now) begin
					d_ready_r <= 1'b1; d_from_cache <= 1'b1;
				end else if (d_cacheable) begin
					d_ready_r <= 1'b0; dp <= 1'b1; dp_fill <= 1'b1;
				end else if ((is_rdram(c_daddr) || is_cart(c_daddr)) && dl_v && dl_tag == line_of(c_daddr)) begin
					d_ready_r <= 1'b1; d_rdata_r <= lanes_in(dl, c_daddr[3]);
				end else if (is_rdram(c_daddr) || is_cart(c_daddr)) begin
					d_ready_r <= 1'b0; dp <= 1'b1; dp_fill <= 1'b0;
				end else if (is_boot(c_daddr)) begin
					d_ready_r <= 1'b1; d_rdata_r <= {boot_d0, boot_d1};
				end else if (is_pifr(c_daddr)) begin
					d_ready_r <= 1'b1; d_rdata_r <= pif_flat[511 - 64 * c_daddr[5:3] -: 64];   // (writes: n64_pif)
				end else if (is_sp(c_daddr)) begin
					d_ready_r <= 1'b0; dsp_pend <= 1'b1;            // the RSP's memory answers in two clocks
				end else begin
					// registers: 32 bits each, the word at offset 0 in the upper lanes
					d_ready_r <= 1'b1;
					d_rdata_r <= {reg_read({c_daddr[31:3], 3'b000}), reg_read({c_daddr[31:3], 3'b100})};
					if (c_dwe) begin : regw
						reg [31:0] wa; reg [31:0] wv;
						wa = c_dbe[3:0] != 4'd0 ? {c_daddr[31:3], 3'b000} : {c_daddr[31:3], 3'b100};
						wv = c_dbe[3:0] != 4'd0 ? c_dwdata[63:32] : c_dwdata[31:0];
						if (wa[31:20] == 12'h043) begin                                 // MI
							if (wa[3:2] == 2'd0) begin
								mi_mode <= {25'd0, wv[6:0]};
								if (wv[11]) mi_intr[5] <= 1'b0;                        // clear DP
							end else if (wa[3:2] == 2'd3) begin
								for (bk = 0; bk < 6; bk = bk + 1) begin
									if (wv[2 * bk]) mi_mask[bk] <= 1'b0;
									if (wv[2 * bk + 1]) mi_mask[bk] <= 1'b1;
								end
							end
						end else if (wa[31:20] == 12'h044) begin                        // VI
							if (wa[5:2] == 4'd4) mi_intr[3] <= 1'b0;                   // V_CURRENT write clears the VI interrupt
							else vi[wa[5:2]] <= wv;
						end else if (wa[31:20] == 12'h046) begin                        // PI: to the DMA engine
							if (wa[5:2] == 4'd4 && wv[1]) mi_intr[4] <= 1'b0;
							pi_we <= 1'b1; pi_widx <= wa[5:2]; pi_wval <= wv;
						end else if (wa[31:20] == 12'h040 && wa[19:16] == 4'h4) begin  // SP: n64_rsp.v takes it
						
						end else if (wa[31:20] == 12'h045) begin                        // AI: to its engine
							if (wa[4:2] == 3'd3) mi_intr[2] <= 1'b0;
							ai_we <= 1'b1; ai_widx <= wa[4:2]; ai_wval <= wv;
						end else if (wa[31:20] == 12'h048) begin                        // SI: to its engine
							if (wa[4:2] == 3'd6) mi_intr[1] <= 1'b0;
							si_we <= 1'b1; si_widx <= wa[4:2]; si_wval <= wv;
						end
					end
				end
			end

			// an interrupt raised on the clock the CPU clears it stays raised: the event is newer
			// than the clear. (The clears above came last and won, and a lost DP or SP interrupt
			// left SM64's scheduler waiting for ever, the RSP idle, after a few thousand tasks.)
			if (sp_irq_set) mi_intr[0] <= 1'b1;
			if (si_done) mi_intr[1] <= 1'b1;
			if (ai_irq) mi_intr[2] <= 1'b1;
			if (vi_hit) mi_intr[3] <= 1'b1;
			if (pi_done) mi_intr[4] <= 1'b1;
			if (dp_irq) mi_intr[5] <= 1'b1;

			// a fill's replay: the block RAM is re-read this clock, so the answer is now
			if (i_replay && !i_req) begin i_ready_r <= 1'b1; i_from_cache <= 1'b1; end
			if (d_replay) begin d_ready_r <= 1'b1; d_from_cache <= 1'b1; end

			// a store waiting for room goes in as soon as there is some
			if (dp_store && !wb_full && !c_dreq) begin
				wb_addr[wb_wp[1:0]] <= line_of(dpa); wb_data[wb_wp[1:0]] <= dpline; wb_mask[wb_wp[1:0]] <= dpmask;
				wb_wp <= wb_wp + 3'd1;
				dp_store <= 1'b0; d_ready_r <= 1'b1;
			end

			// --- the DDR3 port, and the caches' one writer ------------------------------------
			case (st)
			S_IDLE: begin
				d_req <= 1'b0;
				if (!d_calibrated) ;
				else if (fill_pending && !run) begin
					d_addr <= CART_LINE + {4'd0, fill_wline}; d_wdata <= fill_wbuf; d_wmask <= 16'hFFFF;
					d_we <= 1'b1; d_req <= 1'b1; st <= S_FILL;
				end else if (!wb_empty) begin
					d_addr <= wb_addr[wb_rp[1:0]]; d_wdata <= wb_data[wb_rp[1:0]]; d_wmask <= wb_mask[wb_rp[1:0]];
					d_we <= 1'b1; d_req <= 1'b1; st <= S_WB;
				end else if (dp_cop && !c_dreq) begin
					// CACHE: {operation [4:2], cache [1:0]}; 0 = I, 1 = D. Write-backs are
					// nothing to do (the data cache writes through); the rest invalidate --
					// by index, or by index when the tag matches (the hit forms)
					// (the invalidate itself: the tag arrays' write ports below; an op by index
					// goes over the four lines that share the chip's index, a clock each)
					if (cop_idx && dpcop[1:0] == 2'd0 && cop_k != 3'd3) cop_k <= cop_k + 3'd1;   // (the I-cache's)
					else begin dp_cop <= 1'b0; d_ready_r <= 1'b1; cop_k <= 3'd0; end
				end else if (dp && !c_dreq && rd_ok) begin
					d_addr <= line_of(dpa); d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1;
					d_for <= dpa; st <= dp_fill ? S_DFILL : S_DREAD;
				end else if (ip && !i_req && rd_ok) begin
					d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; i_for <= ipa;
					if (ip_fill) begin d_addr <= line_of({ipa[31:5], 5'd0}); st <= S_IFILL0; if_b <= 1'b0; end
					else begin d_addr <= line_of(ipa); st <= S_IREAD; end
				end else if (hv_go && rd_ok) begin
					// (the picture next: it has a deadline the others do not)
					d_addr <= RDRAM_LINE + {4'd0, hv_base[22:4]} + {17'd0, hv_k}; d_we <= 1'b0; d_wmask <= 16'hFFFF;
					d_req <= 1'b1; st <= S_VREAD;
				end else if (pd_rd_req && !pd_rd_ack && rd_ok) begin
					d_addr <= pd_rd_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_PREAD;
				end else if (pd_wr_req && !pd_wr_ack) begin
					d_addr <= pd_wr_line; d_wdata <= pd_wr_data; d_wmask <= pd_wr_mask;
					d_we <= 1'b1; d_req <= 1'b1; st <= S_PWRITE;
				end else if (1'b0) begin                     // (the RSP's DMA reads: the read-ahead, below)
					st <= S_RREAD;
				end else if (rd_wr_req && !rd_wr_ack) begin
					d_addr <= rd_wr_line; d_wdata <= rd_wr_data; d_wmask <= rd_wr_mask;
					d_we <= 1'b1; d_req <= 1'b1; st <= S_RWRITE;
				// (at most 4 outstanding: ddr3_mem's return queue holds 8 and drops a line that
				// arrives when it looks full -- MIG cannot be held off -- and across the clock
				// crossing it looks fuller than it is, by the pops not yet seen. 56 and then 6 both
				// lost lines and hung the RDP.)
				end else if (rq_valid && !rq_ready && rd_ok) begin
					d_addr <= rq_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_RQ; rq_own <= 1'b0;
				end else if (x_qv && !x_qr && !x_flush_p && rd_ok) begin
					d_addr <= RDRAM_LINE + {4'd0, x_ql}; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_RQ; rq_own <= 1'b1;
				end else if (cf_req && !cf_ack && rd_ok) begin
					d_addr <= cf_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_CREAD;
				end else if (cw_req && !cw_ack) begin
					d_addr <= cw_line; d_wdata <= cw_data; d_wmask <= cw_mask;
					d_we <= 1'b1; d_req <= 1'b1; st <= S_CWRITE;
				end else if (ad_rd_req && !ad_rd_ack && rd_ok) begin
					d_addr <= ad_rd_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_AREAD;
				end else if (sd_rd_req && !sd_rd_ack && rd_ok) begin
					d_addr <= sd_rd_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_SREAD;
				end else if (sd_wr_req && !sd_wr_ack) begin
					d_addr <= sd_wr_line; d_wdata <= sd_wr_data; d_wmask <= sd_wr_mask;
					d_we <= 1'b1; d_req <= 1'b1; st <= S_SWRITE;
				end else if (fr_pending && rd_ok) begin
					d_addr <= fr_for; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_FREAD;
				end else if (hr_pending && rd_ok) begin
					d_addr <= hr_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_HREAD;
				end
			end
			S_FILL: if (d_ready) begin
				d_req <= 1'b0; fill_pending <= 1'b0; st <= S_IDLE;
			end
			S_PWRITE: if (d_ready) begin
				d_req <= 1'b0; pd_wr_ack <= 1'b1; st <= S_IDLE;
			end
			S_SWRITE: if (d_ready) begin
				d_req <= 1'b0; sd_wr_ack <= 1'b1; st <= S_IDLE;
			end
			S_RWRITE: if (d_ready) begin
				d_req <= 1'b0; rd_wr_ack <= 1'b1; st <= S_IDLE;
			end
			S_CWRITE: if (d_ready) begin
				d_req <= 1'b0; cw_ack <= 1'b1; st <= S_IDLE;
			end
			S_RQ: if (d_ready) begin
				d_req <= 1'b0; st <= S_IDLE;
				if (rq_own) x_qr <= 1'b1; else rq_ready <= 1'b1;
			end
			S_WB: if (d_ready) begin
				d_req <= 1'b0; wb_rp <= wb_rp + 3'd1; st <= S_IDLE;
			end
			S_DREAD, S_DFILL, S_IREAD, S_IFILL0, S_IFILL1, S_HREAD, S_PREAD, S_FREAD, S_SREAD, S_AREAD, S_RREAD, S_CREAD, S_VREAD: begin
				if (d_ready) d_req <= 1'b0;
				// an I-cache line: the second half asked for the clock the first is taken (two
				// round trips one after the other were 18% of the CPU's clocks)
				if (st == S_IFILL0 && d_ready && !if_b) begin d_addr <= d_addr + 24'd1; d_req <= 1'b1; if_b <= 1'b1; end
				if (d_valid && head_one) begin
					st <= S_IDLE;
					case (st)
					S_DREAD: begin
						dl <= d_rdata; dl_tag <= d_addr; dl_v <= 1'b1;
						dp <= 1'b0; d_ready_r <= 1'b1; d_rdata_r <= lanes_in(d_rdata, dpa[3]);
					end
					S_DFILL: begin
						// (the data and the tag: the arrays' write ports below)
						// no longer waiting -- now, or the idle state next clock launches the
						// same fill again, and ITS replay answers the CPU's next request out of
						// a line never filled; the answer comes with the re-read, next clock
						dp <= 1'b0; d_replay <= 1'b1;
					end
					S_IREAD: begin
						il <= d_rdata; il_tag <= d_addr; il_v <= 1'b1;
						if (ip && ipa == i_for && !i_req) begin
							ip <= 1'b0; i_ready_r <= 1'b1; i_rdata_r <= word_of(d_rdata, ipa);
						end
					end
					S_IFILL0: begin
						// the first half of the 32-byte line; the second is on its way
						st <= S_IFILL1;
					end
					S_IFILL1: begin
						// (the data and the tag: the arrays' write ports below)
						// answer the fetch it was for, by reading the line again next clock
						// (and stop waiting now, as for the data side)
						if (ip && ipa == i_for && !i_req) begin ip <= 1'b0; i_replay <= 1'b1; end
					end
					S_PREAD: begin pd_rd_data <= d_rdata; pd_rd_ack <= 1'b1; end
					S_SREAD: begin sd_rd_data <= d_rdata; sd_rd_ack <= 1'b1; end
					S_AREAD: begin ad_rd_data <= d_rdata; ad_rd_ack <= 1'b1; end
					S_RREAD: begin rd_rd_data <= d_rdata; rd_rd_ack <= 1'b1; end
					S_CREAD: begin cf_data <= d_rdata; cf_ack <= 1'b1; end
					S_VREAD: begin hv_we <= 1'b1; hv_wa <= {hv_line[0], hv_k}; hv_wd <= d_rdata; hv_k <= hv_k + 7'd1; end
					// a frame line: in hand now
					S_FREAD: begin fr_line <= d_rdata; fr_tag <= fr_for; fr_v <= 1'b1; fr_pending <= 1'b0; end
					default: begin hr_data <= d_rdata; hr_done <= 1'b1; hr_pending <= 1'b0; end
					endcase
				end
			end
			default: st <= S_IDLE;
			endcase
		end
	end

	// =============================================================================
	// the PI's DMA: cartridge to RDRAM, exactly as the PI does it
	// =============================================================================
	// After ares/n64/pi/dma.cpp (and tools/n64/n64model.py pi_dma_write): blocks of up
	// to 128 bytes that never cross a 2 kB row of RDRAM, read from the cartridge a
	// halfword at a time. A block whose RDRAM address is not 8-aligned writes that
	// many bytes fewer, and RDRAM's address then rounds up to 8; the first block
	// writes byte by byte, the rest a pair at a time (an odd count gains a byte).
	// When it is done both addresses have moved on and the length reads 127 (or
	// 127 less the last misalignment).
	//
	// Byte-serial: a block is read into a buffer, then written out, a byte a
	// clock, through one line of each kind -- which still beats the real PI.
	// (a halfword an entry: written a pair at a time, so one write port -- distributed RAM;
	// as 128 bytes written two at once it was a thousand flip-flops and 1,200 LUTs of mux)
	(* ram_style = "distributed" *) reg [15:0] pd_blk [0:63];
	reg  [3:0]   pd_st;
	reg  signed [25:0] pd_len;
	reg  [7:0]   pd_cur, pd_i, pd_n, pd_maxblk;
	reg  [2:0]   pd_mis;
	reg          pd_first, pd_dist_short;
	reg  [23:0]  pd_cl_tag;                 // the cartridge line in hand
	reg  [127:0] pd_cl;
	reg          pd_cl_v;
	reg          pd_wl_v;                   // the RDRAM line being gathered
	localparam P_IDLE = 4'd0, P_BLOCK = 4'd1, P_READ = 4'd2, P_RWAIT = 4'd3, P_WRITE = 4'd4,
	           P_FLUSH = 4'd5, P_FWAIT = 4'd6, P_NEXT = 4'd7, P_END = 4'd8, P_EWAIT = 4'd9;
	wire [23:0]  pd_cart_off = pi_cart[23:0];
	wire         pd_in_cart  = pi_cart >= 32'h1000_0000 && pi_cart < 32'h1400_0000;
	wire [23:0]  pd_cart_line = CART_LINE + {2'd0, pi_cart[25:4]};
	wire [11:0]  pd_dist = 12'h800 - {1'b0, pi_dram[10:0]};
	wire [8:0]   pd_room = {1'b0, pd_maxblk} - {6'd0, pi_dram[2:0]};
	wire [11:0]  pd_lim  = (pd_dist < {3'd0, pd_room}) ? pd_dist : {3'd0, pd_room};
	wire [15:0]  pd_half = pd_blk[pd_i[6:1]];
	wire [7:0]   pd_byte = pd_i[0] ? pd_half[7:0] : pd_half[15:8];
	integer pk;

	always @(posedge clk) begin
		pi_done <= 1'b0;
		if (rst) begin
			pd_st <= P_IDLE; pd_rd_req <= 1'b0; pd_wr_req <= 1'b0; pd_cl_v <= 1'b0; pd_wl_v <= 1'b0;
			pi_busy <= 1'b0;
			// the PI as IPL3 leaves it, after its last DMA (krom's DMA test reads this back)
			pi_dram <= 24'h10_1000; pi_cart <= 32'h1000_000C; pi_rdlen <= 24'h7F; pi_wrlen <= 24'h7F;
		end else begin
			if (pd_rd_ack) pd_rd_req <= 1'b0;
			if (pd_wr_ack) pd_wr_req <= 1'b0;
			// the CPU's writes: the addresses masked as they go in; the lengths start DMAs
			if (pi_we) begin
				case (pi_widx)
				4'd0: pi_dram <= pi_wval[23:0] & 24'hFF_FFFE;
				4'd1: pi_cart <= pi_wval & 32'hFFFF_FFFE;
				4'd2: begin pi_rdlen <= (pi_wval[23:0] | 24'd1) + 24'd1; pi_done <= 1'b1; end   // RDRAM -> a ROM: nothing to write
				4'd3: if (!pi_busy) begin
					pi_wrlen <= pi_wval[23:0];
					pd_len <= {2'b00, pi_wval[23:0]} + 26'd1;
					pd_first <= 1'b1; pd_maxblk <= 8'd128;
					pi_busy <= 1'b1; pd_cl_v <= 1'b0; pd_wl_v <= 1'b0;
					pd_st <= P_BLOCK;
				end
				4'd4: if (pi_wval[0]) begin pi_busy <= 1'b0; pd_st <= P_IDLE; end      // reset the DMA
				default: if (pi_widx >= 4'd5 && pi_widx <= 4'd12) pi_dom[pi_widx] <= pi_wval;
				endcase
			end

			case (pd_st)
			P_BLOCK: begin
				if (pd_len <= 0) pd_st <= P_END;
				else begin
					// this block: misalignment, and its length
					pd_mis <= pi_dram[2:0];
					pd_dist_short <= pd_dist < 12'd8;
					pd_cur <= ($signed({14'd0, pd_lim}) < pd_len) ? pd_lim[7:0] : pd_len[7:0];
					pd_i <= 8'd0;
					pd_st <= P_READ;
				end
			end
			P_READ: begin
				// a halfword from the cartridge into the block
				if (pd_i >= pd_cur) begin
					// how many of them go to RDRAM
					pd_n <= ((pd_cur <= {5'd0, pd_mis}) ? 8'd0 :
					         (pd_first && {1'b0, pd_cur} < 9'd127 - {6'd0, pd_mis}) ? pd_cur - {5'd0, pd_mis}
					         : ((pd_cur - {5'd0, pd_mis} + 8'd1) & 8'hFE));
					pd_i <= 8'd0;
					pd_st <= P_WRITE;
				end else if (!pd_in_cart) begin
					pd_blk[pd_i[6:1]] <= 16'd0;
					pi_cart <= pi_cart + 32'd2; pd_len <= pd_len - 26'sd2; pd_i <= pd_i + 8'd2;
				end else if (pd_cl_v && pd_cl_tag == pd_cart_line) begin
					pd_blk[pd_i[6:1]] <= {pd_cl[8 * pi_cart[3:0] +: 8], pd_cl[8 * (pi_cart[3:0] + 4'd1) +: 8]};
					pi_cart <= pi_cart + 32'd2; pd_len <= pd_len - 26'sd2; pd_i <= pd_i + 8'd2;
				end else begin
					pd_rd_line <= pd_cart_line; pd_rd_req <= 1'b1; pd_st <= P_RWAIT;
				end
			end
			P_RWAIT: if (pd_rd_ack) begin
				pd_cl <= pd_rd_data; pd_cl_tag <= pd_rd_line; pd_cl_v <= 1'b1; pd_st <= P_READ;
			end
			P_WRITE: begin
				if (pd_i >= pd_n) pd_st <= P_NEXT;
				else if (pi_dram >= 24'h80_0000) begin
					pi_dram <= pi_dram + 24'd1; pd_i <= pd_i + 8'd1;      // past RDRAM: nowhere to put it
				end else if (pd_wl_v && pd_wr_line != RDRAM_LINE + {4'd0, pi_dram[22:4]}) begin
					pd_st <= P_FLUSH;                                       // a new line: the old one out first
				end else begin
					if (!pd_wl_v) begin pd_wr_line <= RDRAM_LINE + {4'd0, pi_dram[22:4]}; pd_wr_mask <= 16'd0; pd_wl_v <= 1'b1; end
					pd_wr_data[8 * pi_dram[3:0] +: 8] <= pd_byte;
					pd_wr_mask <= (pd_wl_v ? pd_wr_mask : 16'd0) | (16'd1 << pi_dram[3:0]);
					pi_dram <= pi_dram + 24'd1; pd_i <= pd_i + 8'd1;
				end
			end
			P_FLUSH: begin pd_wr_req <= 1'b1; pd_st <= P_FWAIT; end
			P_FWAIT: if (pd_wr_ack) begin pd_wl_v <= 1'b0; pd_st <= P_WRITE; end
			P_NEXT: begin
				// the block is done: RDRAM's address up to 8, the length register, the next block's size
				pi_dram <= (pi_dram + 24'd7) & 24'hFF_FFF8;
				pi_wrlen <= (pd_cur <= 8'd8) ? 24'd127 - {21'd0, pd_mis} : 24'd127;
				pd_first <= 1'b0;
				pd_maxblk <= pd_dist_short ? 8'd128 - {5'd0, pd_mis} : 8'd128;
				pd_st <= P_BLOCK;
			end
			P_END: begin
				if (pd_wl_v) begin pd_wr_req <= 1'b1; pd_st <= P_EWAIT; end
				else begin pi_busy <= 1'b0; pi_done <= 1'b1; pd_st <= P_IDLE; end
			end
			P_EWAIT: if (pd_wr_ack) begin pd_wl_v <= 1'b0; pi_busy <= 1'b0; pi_done <= 1'b1; pd_st <= P_IDLE; end
			default: ;
			endcase
		end
	end

	// the caches' data arrays, one write port each: a fill, or a store into a line
	// the D-cache holds (byte enables), or each half of an I-cache line's fill
	// (the fill's own line: a pipelined read's may come back while it waits -- head_one)
	wire         dw_fill = !rst && st == S_DFILL && d_valid && head_one;
	// (a store through the uncached window updates a line the D-cache holds too: the cache
	// always equals memory, see dsn_w)
	wire         dw_hit  = !rst && c_dreq && !c_dcache && c_dwe && is_rdram(c_daddr) && d_hit_now;
	wire [11:0]  dw_idx  = dw_fill ? d_for[15:4] : d_idx;
	wire [15:0]  dw_be   = dw_fill ? 16'hFFFF : dw_hit ? c_mask : 16'h0000;
	wire [127:0] dw_data = dw_fill ? d_rdata : c_line;
	wire         iw_en   = !rst && (st == S_IFILL0 || st == S_IFILL1) && d_valid && head_one;
	wire [11:0]  iw_idx  = {i_for[15:5], st == S_IFILL1};
	integer wk;
	always @(posedge clk) begin
		for (wk = 0; wk < 16; wk = wk + 1) if (dw_be[wk]) ddata[dw_idx][8 * wk +: 8] <= dw_data[8 * wk +: 8];
		if (iw_en) idata[iw_idx] <= d_rdata;
	end

	// the tag arrays, one write port each -- the sweep while held, a fill, or a CACHE
	// invalidate -- so they are distributed RAM. Written from three places with their
	// own addresses they were 21,000 flip-flops and a mux over the whole array per
	// writer: 190,000 LUTs, which no build was ever going to fit.
	wire         tw_sweep = !rst && !run;
	wire         cop_go   = !rst && st == S_IDLE && d_calibrated && !(fill_pending && !run) && wb_empty && dp_cop && !c_dreq;
	// by index (0, 2, and the D-cache's 3): the four lines {cop_k, the chip's index}; the hit
	// forms (4, 5): the line the address names, invalidated without looking at its tag (it
	// writes through, so a line dropped that did not match costs only a miss)
	assign       cop_idx  = dpcop[4:2] == 3'd0 || dpcop[4:2] == 3'd2 || (dpcop[1:0] == 2'd1 && dpcop[4:2] == 3'd3);
	wire         cop_hit  = dpcop[4:2] == 3'd4 || (dpcop[1:0] == 2'd1 && dpcop[4:2] == 3'd5);
	wire         icop_w   = cop_go && dpcop[1:0] == 2'd0 && (cop_idx || cop_hit);
	// The D-cache is kept equal to memory: it writes through, a store updates a line it holds
	// (cached or not), and every other writer's line is dropped (dsn_w). So its CACHE ops have
	// nothing to do: SM64 wrote back and invalidated the whole cache by index before every RSP
	// task, and the board filled 9.7 lines a 1000 instructions where the model, keeping them,
	// filled 1.8.
	wire         dcop_w   = 1'b0;
	// a write to RDRAM by anyone but the CPU (the RSP's DMA, the RDP, the PI, the SI), taken
	// this clock: the D-cache's line for it, if it holds that line, is dropped
	wire [23:0]  sn_rel   = d_addr - RDRAM_LINE;
	wire         dsn_w    = !rst && d_req && d_ready && d_we && st != S_WB && st != S_FILL && sn_rel[23:19] == 5'd0
	                        && dtag[sn_rel[11:0]] == {1'b1, sn_rel[18:12]};
	wire [10:0]  icop_ix  = cop_idx ? {cop_k[1:0], dpa[13:5]} : dpa[15:5];
	wire [11:0]  dcop_ix  = cop_idx ? {cop_k, dpa[12:4]} : dpa[15:4];
	wire         ifill_w  = !rst && st == S_IFILL1 && d_valid && head_one;
	wire         itw_en   = tw_sweep || ifill_w || icop_w;
	wire [10:0]  itw_idx  = tw_sweep ? sweep[10:0] : ifill_w ? i_for[15:5] : icop_ix;
	wire [7:0]   itw_val  = (!tw_sweep && ifill_w) ? {1'b1, i_for[22:16]} : 8'd0;
	wire         dtw_en   = tw_sweep || dw_fill || dsn_w;
	wire [11:0]  dtw_idx  = tw_sweep ? sweep : dw_fill ? d_for[15:4] : sn_rel[11:0];
	wire [7:0]   dtw_val  = (!tw_sweep && dw_fill) ? {1'b1, d_for[22:16]} : 8'd0;
	always @(posedge clk) begin
		if (itw_en) itag[itw_idx] <= itw_val;
		if (dtw_en) dtag[dtw_idx] <= dtw_val;
	end

	// =============================================================================
	// the SI and the PIF: 64 bytes between RDRAM and PIF RAM, and the joybus
	// =============================================================================
	reg          pif_dma_we, pif_dma_last, pif_go;
	reg  [3:0]   pif_dma_idx;
	reg  [31:0]  pif_dma_data;
	n64_pif u_pif (
		.clk(clk), .rst(rst),
		// the CPU's stores land in the clock they are made, so a load right behind sees them
		.cpu_we(c_dreq && c_dwe && !c_dcache && is_pifr(c_daddr)), .cpu_dw(c_daddr[5:3]),
		.cpu_wsel({c_dbe[3:0] != 4'd0, c_dbe[7:4] != 4'd0}), .cpu_wdata(c_dwdata), .ram_flat(pif_flat),
		.dma_we(pif_dma_we), .dma_widx(pif_dma_idx), .dma_wdata(pif_dma_data), .dma_last(pif_dma_last),
		.go_run(pif_go), .busy(pif_busy),
		.pad0({joy1, stick1}), .pad1(32'd0), .pad2(32'd0), .pad3(32'd0), .pad_present(pad_present),
		.eep_size(eep_size), .eh_we(eh_we), .eh_addr(eh_addr), .eh_wdata(eh_wdata), .eh_rdata(eh_rdata)
	);

	// the engine: a word at a time, each through the DDR3 line that holds it.
	// RDRAM to PIF RAM reads the lines and hands the words over; PIF RAM to RDRAM
	// first runs the joybus, then gathers the words into lines and writes them
	// with byte masks (the 64 bytes start 8-aligned, so they may touch 5 lines).
	localparam [3:0] SI_IDLE = 4'd0, SI_RD = 4'd1, SI_RWAIT = 4'd2, SI_RUN = 4'd3, SI_RUN1 = 4'd4,
	                 SI_RUNW = 4'd5, SI_WR = 4'd6, SI_WWAIT = 4'd7, SI_WEND = 4'd8, SI_EWAIT = 4'd9, SI_END = 4'd10;
	reg  [3:0]   si_st;
	reg  [4:0]   si_w;                 // the word, 0..16
	reg          si_lv;                // the line in hand (reading) or being gathered (writing)
	reg  [18:0]  si_ltag;
	reg  [127:0] si_line;
	wire [23:0]  si_a = si_dram + {17'd0, si_w[3:0], 2'b00};
	wire [31:0]  si_word_in = {si_line[8 * si_a[3:0] +: 8], si_line[8 * (si_a[3:0] + 4'd1) +: 8],
	                           si_line[8 * (si_a[3:0] + 4'd2) +: 8], si_line[8 * (si_a[3:0] + 4'd3) +: 8]};
	wire [31:0]  si_word_out = pif_flat[511 - 32 * si_w[3:0] -: 32];
	integer sk;
	always @(posedge clk) begin
		si_done <= 1'b0; pif_dma_we <= 1'b0; pif_dma_last <= 1'b0; pif_go <= 1'b0;
		if (sd_rd_ack) sd_rd_req <= 1'b0;
		if (sd_wr_ack) sd_wr_req <= 1'b0;
		if (rst) begin
			si_st <= SI_IDLE; si_busy <= 1'b0; sd_rd_req <= 1'b0; sd_wr_req <= 1'b0;
			si_dram <= 24'd0; si_rd <= 32'd0; si_wr <= 32'd0;
		end else begin
			if (si_we && si_widx == 3'd0) si_dram <= {si_wval[23:3], 3'b000};
			case (si_st)
			SI_IDLE: begin
				if (si_we && si_widx == 3'd1) begin                  // PIF RAM to RDRAM
					si_rd <= {si_wval[31:1], 1'b0}; si_busy <= 1'b1; si_st <= SI_RUN;
				end else if (si_we && si_widx == 3'd4) begin         // RDRAM to PIF RAM
					si_wr <= {si_wval[31:1], 1'b0}; si_busy <= 1'b1; si_w <= 5'd0; si_lv <= 1'b0; si_st <= SI_RD;
				end
			end
			// --- RDRAM to PIF RAM -----------------------------------------------------------
			SI_RD: begin
				if (si_w == 5'd16) si_st <= SI_END;
				else if (si_lv && si_ltag == si_a[22:4]) begin
					pif_dma_we <= 1'b1; pif_dma_idx <= si_w[3:0]; pif_dma_data <= si_word_in;
					pif_dma_last <= si_w == 5'd15;
					si_w <= si_w + 5'd1;
				end else begin
					sd_rd_line <= RDRAM_LINE + {5'd0, si_a[22:4]}; sd_rd_req <= 1'b1; si_st <= SI_RWAIT;
				end
			end
			SI_RWAIT: if (sd_rd_ack) begin
				si_line <= sd_rd_data; si_ltag <= si_a[22:4]; si_lv <= 1'b1; si_st <= SI_RD;
			end
			// --- PIF RAM to RDRAM: the joybus first --------------------------------------------
			SI_RUN: if (!pif_busy) begin pif_go <= 1'b1; si_st <= SI_RUN1; end
			SI_RUN1: si_st <= SI_RUNW;
			SI_RUNW: if (!pif_busy) begin si_w <= 5'd0; si_lv <= 1'b0; si_st <= SI_WR; end
			SI_WR: begin
				if (si_w == 5'd16) si_st <= SI_WEND;
				else if (si_lv && si_ltag != si_a[22:4]) begin
					sd_wr_req <= 1'b1; si_st <= SI_WWAIT;                 // the line is done: out with it
				end else begin
					if (!si_lv) begin sd_wr_mask <= 16'd0; sd_wr_line <= RDRAM_LINE + {5'd0, si_a[22:4]}; end
					for (sk = 0; sk < 4; sk = sk + 1) sd_wr_data[8 * (si_a[3:0] + sk) +: 8] <= si_word_out[31 - 8 * sk -: 8];
					sd_wr_mask <= (si_lv ? sd_wr_mask : 16'd0) | (16'hF << si_a[3:0]);
					si_lv <= 1'b1; si_ltag <= si_a[22:4];
					si_w <= si_w + 5'd1;
				end
			end
			SI_WWAIT: if (sd_wr_ack) begin si_lv <= 1'b0; si_st <= SI_WR; end
			SI_WEND: begin sd_wr_req <= 1'b1; si_st <= SI_EWAIT; end
			SI_EWAIT: if (sd_wr_ack) si_st <= SI_END;
			SI_END: begin si_busy <= 1'b0; si_done <= 1'b1; si_st <= SI_IDLE; end
			default: si_st <= SI_IDLE;
			endcase
		end
	end

	// =============================================================================
	// the AI: two DMAs queued, played at the video clock / (DACRATE + 1)
	// =============================================================================
	// As ares has it (ares/n64/ai): a buffer's address and length are queued by
	// writing them; the first plays, a sample pair (a word, left in the upper
	// half) at a time, at the DAC's rate; when it runs out the second takes its
	// place, and the AI interrupts -- as it does when the first is queued. The
	// address counter carries from bit 12 into bit 13 a sample late, as the
	// hardware's does: invisible within a buffer, but a buffer ending on an 8 kB
	// boundary leaves the carry for the next one, which then plays from 8 kB
	// above its address. The DAC's rate is counted in NTSC video clocks
	// (48,681,812 Hz) against our 50 MHz; the host's ring takes a sample at a
	// steady 44.1 kHz, whatever the game's rate, by holding the last one.
	reg  [25:0]  vclk_acc;               // 50 MHz -> the video clock
	reg  [13:0]  dac_div;
	reg  [25:0]  out_acc;                // 50 MHz -> 44.1 kHz
	reg          ai_carry, ai_pend;
	reg  [18:0]  al_tag, al_rtag;        // the line in hand, and the one asked for
	reg          al_v;
	reg  [127:0] al_data;
	reg  [15:0]  dac_l, dac_r;
	reg  [15:0]  n_ai_samp, n_ai_lost;   // (debugging) samples played; DAC ticks that found the last one still pending
	// DAC ticks owed: one that comes while the last sample still waits for its line is
	// not lost but owed, and played as soon as that one is. (They were merged away: a
	// line fetch slower than a sample period -- the AI's DDR3 reads wait behind the
	// CPU's, the RSP's and the RDP's -- cost SM64 a quarter of its 32 kHz, measured
	// 24.4 kHz on the board, and its audio driver, keeping time against the AI, made
	// the music come out wrong.)
	reg  [2:0]   ai_debt;
	wire [23:0]  ai_a = ai_carry ? {ai_addr0[23:13] + 11'd1, ai_addr0[12:0]} : ai_addr0;
	wire [31:0]  ai_word = {al_data[8 * ai_a[3:0] +: 8], al_data[8 * (ai_a[3:0] + 4'd1) +: 8],
	                        al_data[8 * (ai_a[3:0] + 4'd2) +: 8], al_data[8 * (ai_a[3:0] + 4'd3) +: 8]};
	wire         vtick = vclk_acc + 26'd48_681_812 >= 26'd50_000_000;
	always @(posedge clk) begin
		ai_irq <= 1'b0; audio_lr_we <= 1'b0;
		if (ad_rd_ack) ad_rd_req <= 1'b0;
		if (rst) begin
			ai_count <= 2'd0; ai_enable <= 1'b0; ai_dacrate <= 14'd0; ai_carry <= 1'b0; ai_pend <= 1'b0;
			al_v <= 1'b0; ad_rd_req <= 1'b0; vclk_acc <= 26'd0; dac_div <= 14'd0; out_acc <= 26'd0;
			dac_l <= 16'd0; dac_r <= 16'd0; ai_len0 <= 18'd0; ai_len1 <= 18'd0; n_ai_samp <= 16'd0; n_ai_lost <= 16'd0; ai_debt <= 3'd0;
		end else begin
			// the host's 44.1 kHz
			if (out_acc + 26'd44_100 >= 26'd50_000_000) begin
				out_acc <= out_acc + 26'd44_100 - 26'd50_000_000;
				audio_lr <= {dac_r, dac_l}; audio_lr_we <= 1'b1;
			end else out_acc <= out_acc + 26'd44_100;
			// the DAC's: a sample due every DACRATE + 1 video clocks
			vclk_acc <= vtick ? vclk_acc + 26'd48_681_812 - 26'd50_000_000 : vclk_acc + 26'd48_681_812;
			if (vtick && dac_div >= ai_dacrate) begin
				dac_div <= 14'd0;
				if (ai_count != 2'd0) begin
					if (ai_pend) begin
						if (ai_debt != 3'd7) ai_debt <= ai_debt + 3'd1;
						n_ai_lost <= n_ai_lost + 16'd1;
					end else ai_pend <= 1'b1;
				end
			end else begin
				if (vtick) dac_div <= dac_div + 14'd1;
				// a tick owed: as soon as the last sample is out
				if (!ai_pend && ai_debt != 3'd0 && ai_count != 2'd0) begin ai_pend <= 1'b1; ai_debt <= ai_debt - 3'd1; end
			end
			// the CPU's writes
			if (ai_we) begin
				case (ai_widx)
				3'd0: if (ai_count == 2'd0) ai_addr0 <= {ai_wval[23:3], 3'b000};
				      else if (ai_count == 2'd1) ai_addr1 <= {ai_wval[23:3], 3'b000};
				3'd1: if (ai_count < 2'd2) begin
					if (ai_count == 2'd0) begin ai_len0 <= {ai_wval[17:3], 3'b000}; ai_irq <= 1'b1; end
					else ai_len1 <= {ai_wval[17:3], 3'b000};
					ai_count <= ai_count + 2'd1;
				end
				3'd2: ai_enable <= ai_wval[0];
				3'd4: ai_dacrate <= ai_wval[13:0];
				default: ;
				endcase
			end
			// a sample: out of the line in hand, or the line fetched first
			if (ai_pend && !ai_we) begin
				if (ai_count == 2'd0) ai_pend <= 1'b0;
				else if (ai_len0 == 18'd0 || !ai_enable) begin
					ai_pend <= 1'b0;
					if (ai_len0 == 18'd0) begin                        // this one is done: the next
						ai_count <= ai_count - 2'd1;
						if (ai_count == 2'd2) begin ai_addr0 <= ai_addr1; ai_len0 <= ai_len1; ai_irq <= 1'b1; end
					end
				end else if (al_v && al_tag == ai_a[22:4]) begin
					dac_l <= ai_word[31:16]; dac_r <= ai_word[15:0]; n_ai_samp <= n_ai_samp + 16'd1;
					ai_addr0 <= {ai_a[23:13], ai_a[12:0] + 13'd4};
					ai_carry <= ai_a[12:0] + 13'd4 == 13'd0;
					ai_len0 <= ai_len0 - 18'd4;
					ai_pend <= 1'b0;
					// played out: the queue moves now, as in ares's sample()
					if (ai_len0 == 18'd4) begin
						ai_count <= ai_count - 2'd1;
						if (ai_count == 2'd2) begin ai_addr0 <= ai_addr1; ai_len0 <= ai_len1; ai_irq <= 1'b1; end
					end
				end else if (!ad_rd_req) begin
					ad_rd_line <= RDRAM_LINE + {5'd0, ai_a[22:4]}; al_rtag <= ai_a[22:4]; ad_rd_req <= 1'b1;
				end
			end
			if (ad_rd_ack && ad_rd_req) begin al_data <= ad_rd_data; al_tag <= al_rtag; al_v <= 1'b1; end
			// a new buffer: whatever line is in hand may since have been written over
			if (ai_irq) al_v <= 1'b0;
			if (ai_count == 2'd0) begin dac_l <= 16'd0; dac_r <= 16'd0; ai_debt <= 3'd0; end
		end
	end

	// =============================================================================
	// the RSP and the RDP's front
	// =============================================================================
	// The CPU's SP-memory requests go to the RSP's port B one at a time (data
	// first); its answer comes two clocks later.
	wire         sp_go_d = dsp_pend && !sp_busy;
	wire         sp_go_i = isp_pend && !sp_busy && !dsp_pend;
	always @(posedge clk) begin
		if (rst) sp_busy <= 1'b0;
		else if (sp_go_d || sp_go_i) begin sp_busy <= 1'b1; sp_for_d <= sp_go_d; sp_ia2 <= ipa[2]; end
		else if (sp_ack) sp_busy <= 1'b0;
	end
	// the SP's registers, written by the CPU
	wire         sp_reg_we = c_dreq && c_dwe && !c_dcache && c_daddr[31:20] == 12'h040 && (c_daddr[19:16] == 4'h4 || c_daddr[19:16] == 4'h8);
	wire [31:0]  sp_reg_wa = c_dbe[3:0] != 4'd0 ? {c_daddr[31:3], 3'b000} : {c_daddr[31:3], 3'b100};
	wire [31:0]  sp_reg_wv = c_dbe[3:0] != 4'd0 ? c_dwdata[63:32] : c_dwdata[31:0];
	// the semaphore sets when it is read (the doubleword holding it: the CPU's loads
	// come here a doubleword at a time)
	wire         sp_sem_re = c_dreq && !c_dwe && !c_dcache && c_daddr[31:3] == 29'h0080_8003;
	wire [3:0]   sp_ridx;
	wire [2:0]   dp_ridx_rsp;
	wire         dp_we_rsp;
	wire [2:0]   dp_idx_rsp;
	wire [31:0]  dp_wd_rsp;
	wire         xb_req, xb_ack;
	wire [8:0]   xb_dw;
	wire [63:0]  xb_q;
	wire [31:0]  sp_cq;
	wire [287:0] sp_regs_flat;
	wire         rsp_halted;
	wire [95:0]  rsp_dbg, rsp_dlog;
	wire [31:0]  rsp_dlog_n;
	wire [63:0]  rsp_dbg_dq;
	wire         rsp_frozen;
	// (debugging) the RSP's pace: instructions, clocks running, clocks its DMA is busy
	wire         rsp_tr;
	wire         rsp_dm_new;
	reg  [31:0]  n_rsp_ins, n_rsp_run, n_rsp_dma;
	reg  [31:0]  n_dma_go, n_dma_rl, n_dma_wl;          // its DMAs started; lines read, lines written
	reg  [31:0]  n_dma_rc, n_dma_wc;                    // clocks it spent reading RDRAM, writing it
	// (debugging) clocks the running RSP spent in state dbg_sel[11:8]; with dbg_sel[12], in R_EX
	// held by a hazard (dbg_sel[8]: 0 a vector op's result, 1 a vector load's)
	reg  [31:0]  n_rsp_st;
	wire [1:0]   rsp_dm_phase;
	// ... by the task's type (1 graphics, 2 audio, other): starts, instructions, clocks running
	wire [7:0]   rsp_type;
	reg  [1:0]   cur_t;
	reg          t_hd;                    // the RSP halted a clock ago
	wire         rsp_go = t_hd && !rsp_dbg[95];
	reg  [31:0]  t_go [0:2], t_ins [0:2], t_run [0:2];
	integer      ti;
	always @(posedge clk) begin
		t_hd <= rsp_dbg[95];
		if (cpu_rst) for (ti = 0; ti < 3; ti = ti + 1) begin t_go[ti] <= 0; t_ins[ti] <= 0; t_run[ti] <= 0; end
		else begin
			if (rsp_go) begin
				cur_t <= (rsp_type == 8'd1) ? 2'd0 : (rsp_type == 8'd2) ? 2'd1 : 2'd2;
				t_go[(rsp_type == 8'd1) ? 0 : (rsp_type == 8'd2) ? 1 : 2] <= t_go[(rsp_type == 8'd1) ? 0 : (rsp_type == 8'd2) ? 1 : 2] + 1;
			end
			if (rsp_tr) t_ins[cur_t] <= t_ins[cur_t] + 1;
			if (!rsp_dbg[95]) t_run[cur_t] <= t_run[cur_t] + 1;
		end
	end
	always @(posedge clk) begin
		if (cpu_rst) begin n_rsp_ins <= 0; n_rsp_run <= 0; n_rsp_dma <= 0; n_dma_go <= 0; n_dma_rl <= 0; n_dma_wl <= 0; n_dma_rc <= 0; n_dma_wc <= 0; n_rsp_st <= 0; end
		else begin
			if (rsp_tr) n_rsp_ins <= n_rsp_ins + 1;
			if (rsp_dm_new) n_dma_go <= n_dma_go + 1;
			if (rsp_dm_phase[0]) n_dma_rc <= n_dma_rc + 1;
			if (!rsp_dbg[95] && (dbg_sel[12] ? rsp_dbg[94 - dbg_sel[8]] : rsp_dbg[83:80] == dbg_sel[11:8])) n_rsp_st <= n_rsp_st + 1;
			if (rsp_dm_phase[1]) n_dma_wc <= n_dma_wc + 1;
			if (x_ack) n_dma_rl <= n_dma_rl + 1;
			if (st == S_RWRITE && d_ready) n_dma_wl <= n_dma_wl + 1;
			if (!rsp_dbg[95]) n_rsp_run <= n_rsp_run + 1;
			if (sp_regs_flat[287 - 32 * 6 - 31]) n_rsp_dma <= n_rsp_dma + 1;    // SP_DMA_BUSY's bit 0
		end
	end
	wire         x_hold = x_qv || (st == S_RQ && rq_own) || x_qr;   // a read of the read-ahead's in the arbiter's hands
	wire         x_flush = x_flush_p && !x_hold;
	always @(posedge clk) begin
		if (rst) x_flush_p <= 1'b0;
		// (not at every DMA's start: then every DMA paid a DDR3 round trip, even one going on
		// where the last left off -- the display list, 64 bytes at a time. A line goes stale
		// only when something writes it: every write to RDRAM, whoever's, is snooped)
		else if (x_snoop_hit) x_flush_p <= 1'b1;
		else if (x_flush) x_flush_p <= 1'b0;
	end
	n64_rdp_stream u_rsp_ra (.clk(clk), .rst(rst), .flush(x_flush), .hold(x_hold), .stop(x_flush_p),
		.s_v(d_req && d_ready && d_we), .s_line(d_addr - RDRAM_LINE), .s_hit(x_snoop_hit),
		.c_req(rd_rd_req && !rd_rd_ack && !x_flush_p), .c_line(rd_rd_line[19:0] - RDRAM_LINE[19:0]),
		.c_ack(x_ack), .c_data(x_data),
		.q_valid(x_qv), .q_line(x_ql), .q_ready(x_qr), .q_rs(x_rs), .q_rs_data(rs_data));
	n64_rsp #(.RDRAM_LINE(RDRAM_LINE), .DEBUG_FREEZE(0)) u_rsp (
		.clk(clk), .rst(rst || !run),
		.c_mem_en(sp_go_d || sp_go_i), .c_mem_we(sp_go_d && c_dwe_q ? c_dbe_q : 8'd0),
		.c_mem_dw(sp_go_d ? dpa[12:3] : ipa[12:3]), .c_mem_wd(c_dwdata_q),
		.c_mem_q(sp_q), .c_mem_ack(sp_ack),
		.c_reg_we(sp_reg_we), .c_reg_re(sp_sem_re),
		.c_reg_idx(sp_reg_wa[19:16] == 4'h8 ? 4'd8 : {1'b0, sp_reg_wa[4:2]}), .c_reg_wd(sp_reg_wv), .c_reg_q(sp_cq),
		.x_req(xb_req), .x_dw(xb_dw), .x_ack(xb_ack), .x_q(xb_q),
		.dp_we(dp_we_rsp), .dp_idx(dp_idx_rsp), .dp_wd(dp_wd_rsp), .dp_q(dp_flat[255 - 32 * dp_ridx_rsp -: 32]), .dp_ridx(dp_ridx_rsp),
		.dm_rd_req(rd_rd_req), .dm_rd_ack(rd_rd_ack), .dm_rd_line(rd_rd_line), .dm_rd_data(rd_rd_data), .dm_new(rsp_dm_new), .dm_phase(rsp_dm_phase),
		.dm_wr_req(rd_wr_req), .dm_wr_ack(rd_wr_ack), .dm_wr_line(rd_wr_line), .dm_wr_data(rd_wr_data), .dm_wr_mask(rd_wr_mask),
		.irq_set(sp_irq_set), .irq_clr(sp_irq_clr), .halted_o(rsp_halted),
		.sp_regs_flat(sp_regs_flat), .dbg(rsp_dbg), .dlog_idx(dbg_sel[15:8]), .dlog_q(rsp_dlog), .dlog_n(rsp_dlog_n),
		.dbg_dw(dbg_sel[25:16]), .dbg_dq(rsp_dbg_dq), .frozen(rsp_frozen),
		.tr_valid(rsp_tr), .tr_pc(), .tr_ir(), .task_type(rsp_type)
	);
	genvar gs;
	generate for (gs = 0; gs < 9; gs = gs + 1) begin : g_spr
		assign sp_regs[gs] = sp_regs_flat[287 - 32 * gs -: 32];
	end endgenerate
	// the store's data and enables, kept for the request that waits for the port
	always @(posedge clk) if (c_dreq) begin c_dbe_q <= c_dbe; c_dwe_q <= c_dwe; c_dwdata_q <= c_dwdata; end

	wire         dp_cpu_we = c_dreq && c_dwe && !c_dcache && c_daddr[31:20] == 12'h041;
	wire [63:0]  rdp_dbg, rdp_dbg2;
	wire [87:0]  rdp_log_q;  wire [31:0] rdp_log_n;
	n64_rdp2 #(.RDRAM_LINE(RDRAM_LINE)) u_rdp (
		.clk(clk), .rst(rst || !run),
		.c_we(dp_cpu_we), .c_idx(sp_reg_wa[4:2]), .c_wd(sp_reg_wv),
		.r_we(dp_we_rsp), .r_idx(dp_idx_rsp), .r_wd(dp_wd_rsp),
		.regs_flat(dp_flat),
		.cf_req(cf_req), .cf_ack(cf_ack), .cf_line(cf_line), .cf_data(cf_data),
		.cw_req(cw_req), .cw_ack(cw_ack), .cw_line(cw_line), .cw_data(cw_data), .cw_mask(cw_mask),
		.rq_valid(rq_valid), .rq_ready(rq_ready), .rq_line(rq_line), .rs_valid(rs_valid), .rs_data(rs_data),
		.xb_req(xb_req), .xb_dw(xb_dw), .xb_ack(xb_ack), .xb_data(xb_q),
		.irq(dp_irq), .idle(),
		.log_stop(1'b1), .log_idx(dbg_sel[12:8]), .log_q(rdp_log_q), .log_n(rdp_log_n), .dbg(rdp_dbg), .dbg2(rdp_dbg2)
	);

	// --- debugging: the last 16 writes to RDRAM below 0x400 (the exception vectors and
	// below the Z buffer), and who made them: 1 the CPU, 2 PI, 3 the RSP, 4 the RDP, 5 SI
	reg  [4:0]   st_q;
	// =============================================================================
	// the debug window: what the RSP, the RDP and the interrupts have been doing,
	// for the PC to read while a game runs (console_top 0x170 select, 0x174 data)
	//   0-8   SP registers 0-7 and SP_PC        9-16  DP registers 0-7
	//   17    {mi_mask, mi_intr} (6 bits each)  18    RSP starts (halt cleared)
	//   19    SP interrupts raised              20    DP interrupts (SYNC_FULL)
	//   21    AI interrupts   22 VI interrupts  23    SI DMAs done   24 PI DMAs done
	//   25    CPU exceptions  26 of them interrupts (code 0)
	//   27    the last exception: {code, 0, its pc[23:0]}   28 the last non-interrupt one
	//   29    the RSP: {halted, st, pc}   30 its instruction   31 its last COP0 read {reg, value[27:0]}
	//   32    RSP DMAs started   33-35 the DMA log's entry dbg_sel[15:8] (n64_rsp.v dlog), words 0-2
	//   36-37 while the RSP is frozen: DMEM/IMEM doubleword dbg_sel[25:16] ([25] IMEM)   38 frozen
	// =============================================================================
	reg  [31:0] n_rsp_go, n_sp_irq, n_dp_irq, n_ai_irq, n_vi_irq, n_si, n_pi, n_exc, n_exc_int, last_exc, last_fault;
	reg         rsp_halted_d;
	always @(posedge clk) begin
		rsp_halted_d <= rsp_halted;
		if (cpu_rst) begin
			n_rsp_go <= 32'd0; n_sp_irq <= 32'd0; n_dp_irq <= 32'd0; n_ai_irq <= 32'd0; n_vi_irq <= 32'd0;
			n_si <= 32'd0; n_pi <= 32'd0; n_exc <= 32'd0; n_exc_int <= 32'd0; last_exc <= 32'd0; last_fault <= 32'd0;
		end else begin
			if (rsp_halted_d && !rsp_halted) n_rsp_go <= n_rsp_go + 32'd1;
			if (sp_irq_set) n_sp_irq <= n_sp_irq + 32'd1;
			if (dp_irq) n_dp_irq <= n_dp_irq + 32'd1;
			if (ai_irq) n_ai_irq <= n_ai_irq + 32'd1;
			if (vi_hit) n_vi_irq <= n_vi_irq + 32'd1;
			if (si_done) n_si <= n_si + 32'd1;
			if (pi_done) n_pi <= n_pi + 32'd1;
			if (tr_exc) begin
				n_exc <= n_exc + 32'd1;
				last_exc <= {tr_code, 3'd0, last_pc[23:0]};
				if (tr_code == 5'd0) n_exc_int <= n_exc_int + 32'd1;
				else last_fault <= {tr_code, 3'd0, last_pc[23:0]};
			end
		end
		case (dbg_sel[5:0])
		6'd0, 6'd1, 6'd2, 6'd3, 6'd4, 6'd5, 6'd6, 6'd7, 6'd8: dbg_q <= sp_regs_flat[287 - 32 * dbg_sel[5:0] -: 32];
		6'd9, 6'd10, 6'd11, 6'd12, 6'd13, 6'd14, 6'd15, 6'd16: dbg_q <= dp_flat[255 - 32 * (dbg_sel[5:0] - 6'd9) -: 32];
		6'd17: dbg_q <= {20'd0, mi_mask, mi_intr};
		6'd18: dbg_q <= n_rsp_go;
		6'd19: dbg_q <= n_sp_irq;
		6'd20: dbg_q <= n_dp_irq;
		6'd21: dbg_q <= n_ai_irq;
		6'd22: dbg_q <= n_vi_irq;
		6'd23: dbg_q <= n_si;
		6'd24: dbg_q <= n_pi;
		6'd25: dbg_q <= n_exc;
		6'd26: dbg_q <= n_exc_int;
		6'd27: dbg_q <= last_exc;
		6'd28: dbg_q <= last_fault;
		6'd29: dbg_q <= {rsp_dbg[95], cur_t, rsp_dbg[92:64]};      // (and the task's type: 0 graphics, 1 audio)
		6'd30: dbg_q <= rsp_dbg[63:32];
		6'd31: dbg_q <= rsp_dbg[31:0];
		6'd32: dbg_q <= rsp_dlog_n;
		6'd33: dbg_q <= rsp_dlog[95:64];
		6'd34: dbg_q <= rsp_dlog[63:32];
		6'd35: dbg_q <= rsp_dlog[31:0];
		6'd36: dbg_q <= rsp_dbg_dq[63:32];
		6'd37: dbg_q <= rsp_dbg_dq[31:0];
		6'd38: dbg_q <= {31'd0, rsp_frozen};
		6'd39: dbg_q <= rdp_dbg[63:32];
		6'd40: dbg_q <= rdp_dbg[31:0];
		6'd54: dbg_q <= n_rsp_ins;
		6'd52: dbg_q <= {ai_count, ai_enable, 15'd0, ai_dacrate};            // the AI: what the game set
		6'd53: dbg_q <= {n_ai_lost, n_ai_samp};                              // samples played / DAC ticks lost
		6'd60: dbg_q <= retired;
		6'd42: dbg_q <= n_ipw;
		6'd46: dbg_q <= n_stall;
		6'd49: dbg_q <= n_dma_rc;
		6'd51: dbg_q <= n_rsp_st;
		6'd50: dbg_q <= n_dma_wc;
		6'd47: dbg_q <= n_ifill;
		6'd48: dbg_q <= n_dfill;
		6'd43: dbg_q <= n_dpw;
		6'd44: dbg_q <= n_ipn;
		6'd45: dbg_q <= n_dpn;
		6'd62: dbg_q <= n_dma_go;
		6'd63: dbg_q <= {n_dma_rl[15:0], n_dma_wl[15:0]};
		6'd61: dbg_q <= retired_idle;
		6'd57: dbg_q <= t_go[dbg_sel[9:8]];
		6'd58: dbg_q <= t_ins[dbg_sel[9:8]];
		6'd59: dbg_q <= t_run[dbg_sel[9:8]];
		6'd55: dbg_q <= n_rsp_run;
		6'd56: dbg_q <= n_rsp_dma;
		6'd41: dbg_q <= {rq_valid, rq_ready, rs_valid, rd_ok, rdp_out, 3'd0, st, cf_req, cf_ack, cw_req, cw_ack, d_req, d_ready, d_valid, 6'd0};
		default: dbg_q <= 32'hDEB0_0000 | {26'd0, dbg_sel[5:0]};
		endcase
	end

endmodule

`default_nettype wire
