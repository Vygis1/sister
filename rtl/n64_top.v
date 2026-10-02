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
// run is raised and the boot ROM (rtl/n64_boot_rom.v, tools/n64bootrom.py)
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
	output wire [31:0]  vi_status,
	output wire [31:0]  vi_origin,
	output wire [31:0]  vi_width,
	output wire [31:0]  vi_yscale,
	output wire [31:0]  dbg_pc,
	output wire [31:0]  dbg_retired
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

	vr4300 cpu (
		.clk(clk), .rst(cpu_rst),
		.i_req(i_req), .i_addr(i_addr), .i_cached(i_cached), .i_ready(i_ready), .i_rdata(i_rdata),
		.d_req(c_dreq), .d_we(c_dwe), .d_addr(c_daddr), .d_cached(c_dcached), .d_be(c_dbe), .d_wdata(c_dwdata),
		.d_cache(c_dcache), .d_cop(c_dcop),
		.d_ready(c_dready), .d_rdata(c_drdata),
		.irq({4'd0, mi_irq}), .count_tick(1'b1),
		.tr_valid(tr_valid), .tr_pc(tr_pc), .tr_we(tr_we), .tr_rd(tr_rd), .tr_val(tr_val),
		.tr_exc(tr_exc), .tr_code(tr_code)
	);
	reg [31:0] last_pc;
	always @(posedge clk) begin
		if (cpu_rst) retired <= 32'd0;
		else if (tr_valid) begin retired <= retired + 32'd1; last_pc <= tr_pc; end
	end
	assign dbg_pc = last_pc;
	assign dbg_retired = retired;

	// =============================================================================
	// block memories: the boot ROM (PIF ROM), PIF RAM, SP DMEM/IMEM
	// =============================================================================
	// the boot ROM: rtl/n64_boot_rom.v, generated by tools/n64bootrom.py
	wire [31:0] boot_i, boot_d0, boot_d1;
	n64_boot_rom u_boot_i  (.a(i_addr[7:2]),             .q(boot_i));
	n64_boot_rom u_boot_d0 (.a({c_daddr[7:3], 1'b0}),    .q(boot_d0));
	n64_boot_rom u_boot_d1 (.a({c_daddr[7:3], 1'b1}),    .q(boot_d1));
	reg [63:0] spmem [0:1023];                 // DMEM then IMEM, 8 kB
	reg [31:0] pifram [0:15];
	integer k;
	initial begin
		for (k = 0; k < 1024; k = k + 1) spmem[k] = 64'd0;
		for (k = 0; k < 16; k = k + 1) pifram[k] = 32'd0;
	end

	// =============================================================================
	// the RCP's registers
	// =============================================================================
	reg  [31:0] vi [0:13];
	reg  [9:0]  vi_line;
	reg  [10:0] vi_clk;
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
	reg  [23:0]  pd_rd_line, pd_wr_line;
	reg  [127:0] pd_rd_data, pd_wr_data;
	reg  [15:0]  pd_wr_mask;
	reg  [31:0] sp_status;
	initial for (k = 0; k < 14; k = k + 1) vi[k] = 32'd0;
	initial for (k = 5; k < 13; k = k + 1) pi_dom[k] = 32'd0;
	assign vi_status = vi[0];
	assign vi_origin = vi[1];
	assign vi_width  = vi[2];
	assign vi_yscale = vi[13];
	assign mi_irq = |(mi_intr & mi_mask);
	wire [9:0]  vi_vsync = (vi[6][9:0] != 10'd0) ? vi[6][9:0] : 10'd525;

	// the VI's clock: a half-line every HALFLINE clocks; V_INTR raises the MI's VI bit
	always @(posedge clk) begin
		if (cpu_rst) begin vi_line <= 10'd0; vi_clk <= 11'd0; end
		else if (vi_clk == HALFLINE - 11'd1) begin
			vi_clk <= 11'd0;
			vi_line <= (vi_line >= vi_vsync) ? 10'd0 : vi_line + 10'd1;
		end else vi_clk <= vi_clk + 11'd1;
	end
	wire vi_hit = (vi_clk == HALFLINE - 11'd1) && (((vi_line >= vi_vsync) ? 10'd0 : vi_line + 10'd1) == vi[3][9:0]);

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
				4'd4: reg_read = {28'd0, mi_intr[4], 2'b00, pi_busy};
				default: reg_read = (a[5:2] <= 4'd12) ? pi_dom[a[5:2]] : 32'd0;
				endcase
			end else if (a[31:20] == 12'h040 && a[19:16] == 4'h4) begin  // SP
				reg_read = (a[4:2] == 3'd4) ? sp_status : 32'd0;
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
	// tags: {valid, physical address [31:12]}, in LUT RAM; data in block RAM
	(* ram_style = "distributed" *) reg [20:0] itag [0:511];      // 512 lines of 32 bytes
	(* ram_style = "distributed" *) reg [20:0] dtag [0:511];      // 512 lines of 16 bytes
	(* ram_style = "block" *) reg [127:0] idata [0:1023];         // 16 kB
	(* ram_style = "block" *) reg [127:0] ddata [0:511];          //  8 kB
	initial for (k = 0; k < 512; k = k + 1) begin itag[k] = 21'd0; dtag[k] = 21'd0; end
	wire        i_cacheable = i_cached && is_rdram(i_addr);
	wire        d_cacheable = c_dcached && is_rdram(c_daddr);
	wire [8:0]  i_idx = i_addr[13:5];
	wire [8:0]  d_idx = c_daddr[12:4];
	wire        i_hit_now = itag[i_idx] == {1'b1, i_addr[31:12]};
	wire        d_hit_now = dtag[d_idx] == {1'b1, c_daddr[31:12]};

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
	           S_PREAD = 4'd9, S_PWRITE = 4'd10;
	reg  [3:0]   st;
	// the host's fill: four words to a line. A finished line moves to its own
	// buffer for the write, so the next line's first word can arrive while that
	// write waits (clearing one shared buffer lost exactly those words).
	reg  [127:0] fill_buf, fill_wbuf;
	reg  [19:0]  fill_line, fill_wline;
	reg  [1:0]   fill_cnt;
	reg          fill_pending;
	reg          hr_pending;
	reg  [8:0]   sweep;               // while held: the caches are invalidated, a line a clock

	integer bk;
	always @(posedge clk) begin
		// block RAM reads: the request's line, or a replay after a fill
		if (i_req) i_bram <= idata[i_addr[13:4]];
		else if (i_replay) i_bram <= idata[ipa[13:4]];
		if (c_dreq) d_bram <= ddata[d_idx];
		else if (d_replay) d_bram <= ddata[dpa[12:4]];

		if (rst) begin
			st <= S_IDLE; d_req <= 1'b0; d_we <= 1'b0; d_addr <= 24'd0; d_wdata <= 128'd0; d_wmask <= 16'd0;
			il_v <= 1'b0; dl_v <= 1'b0; ip <= 1'b0; dp <= 1'b0; ip_fill <= 1'b0; dp_fill <= 1'b0;
			dp_store <= 1'b0; dp_cop <= 1'b0; i_replay <= 1'b0; d_replay <= 1'b0;
			i_ready_r <= 1'b0; d_ready_r <= 1'b0; i_from_cache <= 1'b0; d_from_cache <= 1'b0;
			wb_wp <= 3'd0; wb_rp <= 3'd0;
			fill_pending <= 1'b0; fill_cnt <= 2'd0; fill_buf <= 128'd0; fill_line <= 20'd0;
			hr_pending <= 1'b0; hr_done <= 1'b0; sweep <= 9'd0;
			pd_rd_ack <= 1'b0; pd_wr_ack <= 1'b0;
			mi_intr <= 6'd0; mi_mask <= 6'd0; mi_mode <= 32'd0; sp_status <= 32'd1;
			pi_we <= 1'b0;
		end else begin
			if (!pd_rd_req) pd_rd_ack <= 1'b0;          // the engine has taken it
			if (!pd_wr_req) pd_wr_ack <= 1'b0;
			i_replay <= 1'b0; d_replay <= 1'b0; pi_we <= 1'b0;
			// a DMA has finished: the PI's interrupt; the uncached lines may be stale
			if (pi_done) begin mi_intr[4] <= 1'b1; il_v <= 1'b0; dl_v <= 1'b0; end
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
			if (vi_hit) mi_intr[3] <= 1'b1;
			// held: the caches go empty, so a new cartridge never meets an old line
			if (!run) begin
				itag[sweep] <= 21'd0; dtag[sweep] <= 21'd0; sweep <= sweep + 9'd1;
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
					i_ready_r <= 1'b1; i_rdata_r <= i_addr[2] ? spmem[i_addr[12:3]][31:0] : spmem[i_addr[12:3]][63:32];
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
						if (d_cacheable && d_hit_now)
							for (bk = 0; bk < 16; bk = bk + 1) if (c_mask[bk]) ddata[d_idx][8 * bk +: 8] <= c_line[8 * bk +: 8];
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
					d_ready_r <= 1'b1; d_rdata_r <= {pifram[{c_daddr[5:3], 1'b0}], pifram[{c_daddr[5:3], 1'b1}]};
					if (c_dwe) begin
						if (c_dbe[3:0] != 4'd0) pifram[{c_daddr[5:3], 1'b0}] <= c_dwdata[63:32];
						if (c_dbe[7:4] != 4'd0) pifram[{c_daddr[5:3], 1'b1}] <= c_dwdata[31:0];
					end
				end else if (is_sp(c_daddr)) begin
					d_ready_r <= 1'b1; d_rdata_r <= spmem[c_daddr[12:3]];
					if (c_dwe) for (bk = 0; bk < 8; bk = bk + 1)
						if (c_dbe[bk]) spmem[c_daddr[12:3]][63 - 8 * bk -: 8] <= c_dwdata[63 - 8 * bk -: 8];
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
						end else if (wa[31:20] == 12'h040 && wa[19:16] == 4'h4) begin  // SP status
							if (wa[4:2] == 3'd4) begin
								if (wv[1]) sp_status[0] <= 1'b1;
								if (wv[3]) mi_intr[0] <= 1'b0;
							end
						end else if (wa[31:20] == 12'h045) begin                        // AI: acknowledge
							if (wa[4:2] == 3'd3) mi_intr[2] <= 1'b0;
						end else if (wa[31:20] == 12'h048) begin                        // SI: acknowledge
							if (wa[4:2] == 3'd6) mi_intr[1] <= 1'b0;
						end
					end
				end
			end

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
					if (dpcop[1:0] == 2'd0) begin
						if (dpcop[4:2] == 3'd0 || dpcop[4:2] == 3'd2 ||
						    (dpcop[4:2] == 3'd4 && itag[dpa[13:5]] == {1'b1, dpa[31:12]}))
							itag[dpa[13:5]] <= 21'd0;
					end else if (dpcop[1:0] == 2'd1) begin
						if (dpcop[4:2] == 3'd0 || dpcop[4:2] == 3'd2 || dpcop[4:2] == 3'd3 ||
						    ((dpcop[4:2] == 3'd4 || dpcop[4:2] == 3'd5) && dtag[dpa[12:4]] == {1'b1, dpa[31:12]}))
							dtag[dpa[12:4]] <= 21'd0;
					end
					dp_cop <= 1'b0; d_ready_r <= 1'b1;
				end else if (dp && !c_dreq) begin
					d_addr <= line_of(dpa); d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1;
					d_for <= dpa; st <= dp_fill ? S_DFILL : S_DREAD;
				end else if (ip && !i_req) begin
					d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; i_for <= ipa;
					if (ip_fill) begin d_addr <= line_of({ipa[31:5], 5'd0}); st <= S_IFILL0; end
					else begin d_addr <= line_of(ipa); st <= S_IREAD; end
				end else if (pd_rd_req && !pd_rd_ack) begin
					d_addr <= pd_rd_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_PREAD;
				end else if (pd_wr_req && !pd_wr_ack) begin
					d_addr <= pd_wr_line; d_wdata <= pd_wr_data; d_wmask <= pd_wr_mask;
					d_we <= 1'b1; d_req <= 1'b1; st <= S_PWRITE;
				end else if (hr_pending) begin
					d_addr <= hr_line; d_we <= 1'b0; d_wmask <= 16'hFFFF; d_req <= 1'b1; st <= S_HREAD;
				end
			end
			S_FILL: if (d_ready) begin
				d_req <= 1'b0; fill_pending <= 1'b0; st <= S_IDLE;
			end
			S_PWRITE: if (d_ready) begin
				d_req <= 1'b0; pd_wr_ack <= 1'b1; st <= S_IDLE;
			end
			S_WB: if (d_ready) begin
				d_req <= 1'b0; wb_rp <= wb_rp + 3'd1; st <= S_IDLE;
			end
			S_DREAD, S_DFILL, S_IREAD, S_IFILL0, S_IFILL1, S_HREAD, S_PREAD: begin
				if (d_ready) d_req <= 1'b0;
				if (d_valid) begin
					st <= S_IDLE;
					case (st)
					S_DREAD: begin
						dl <= d_rdata; dl_tag <= d_addr; dl_v <= 1'b1;
						dp <= 1'b0; d_ready_r <= 1'b1; d_rdata_r <= lanes_in(d_rdata, dpa[3]);
					end
					S_DFILL: begin
						ddata[d_for[12:4]] <= d_rdata; dtag[d_for[12:4]] <= {1'b1, d_for[31:12]};
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
						// the first half of the 32-byte line; then the second
						idata[{i_for[13:5], 1'b0}] <= d_rdata;
						d_addr <= d_addr + 24'd1; d_req <= 1'b1; st <= S_IFILL1;
					end
					S_IFILL1: begin
						idata[{i_for[13:5], 1'b1}] <= d_rdata; itag[i_for[13:5]] <= {1'b1, i_for[31:12]};
						// answer the fetch it was for, by reading the line again next clock
						// (and stop waiting now, as for the data side)
						if (ip && ipa == i_for && !i_req) begin ip <= 1'b0; i_replay <= 1'b1; end
					end
					S_PREAD: begin pd_rd_data <= d_rdata; pd_rd_ack <= 1'b1; end
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
	// After ares/n64/pi/dma.cpp (and tools/n64model.py pi_dma_write): blocks of up
	// to 128 bytes that never cross a 2 kB row of RDRAM, read from the cartridge a
	// halfword at a time. A block whose RDRAM address is not 8-aligned writes that
	// many bytes fewer, and RDRAM's address then rounds up to 8; the first block
	// writes byte by byte, the rest a pair at a time (an odd count gains a byte).
	// When it is done both addresses have moved on and the length reads 127 (or
	// 127 less the last misalignment).
	//
	// Byte-serial: a block is read into a buffer, then written out, a byte a
	// clock, through one line of each kind -- which still beats the real PI.
	reg  [7:0]   pd_blk [0:127];
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
	wire [7:0]   pd_byte = pd_blk[pd_i[6:0]];
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
					pd_blk[pd_i[6:0]] <= 8'd0; pd_blk[pd_i[6:0] + 7'd1] <= 8'd0;
					pi_cart <= pi_cart + 32'd2; pd_len <= pd_len - 26'sd2; pd_i <= pd_i + 8'd2;
				end else if (pd_cl_v && pd_cl_tag == pd_cart_line) begin
					pd_blk[pd_i[6:0]]         <= pd_cl[8 * pi_cart[3:0] +: 8];
					pd_blk[pd_i[6:0] + 7'd1]  <= pd_cl[8 * (pi_cart[3:0] + 4'd1) +: 8];
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

endmodule

`default_nettype wire
