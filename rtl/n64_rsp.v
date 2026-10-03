//////////////////////////////////////////////////////////////////////////////////
// n64_rsp.v - the N64's RSP: the scalar unit, its COP0 (the SP's DMA and status;
// the DP's registers are passed out), and the vector unit (COP2).
//
// Behaviour is tools/n64rsp.py's, which follows ares (ISC) operation for
// operation; this is written to be checked against it, not to be fast yet:
//
//   - an instruction takes two clocks: the fetch, then the execution from the
//     block RAM's output; a vector operation one more (its multiply is
//     registered); a load or store walks its bytes one by one, exactly as the
//     model's loops do (two clocks a byte for loads, one for stores).
//   - DMEM and IMEM are 512 x 64 block RAMs, big-endian (byte j of a doubleword
//     in bits [63 - 8j -: 8]), with byte enables. Port A is the RSP's; port B the
//     CPU's and the DMA's (the CPU first).
//   - a vector register is 128 bits, byte 0 in [127:120] (ares's r128.byte(0));
//     element n in [127 - 16n -: 16]. The register file is sixteen byte lanes of
//     LUT RAM, so a load can write one byte of one register.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rsp #(
	parameter [23:0] RDRAM_LINE = 24'h00_0000,
	parameter        DEBUG_FREEZE = 0      // stop at the first DMA from below 1 MB (debugging SM64)
) (
	input  wire         clk,
	input  wire         rst,
	// the CPU: DMEM and IMEM, a doubleword at a time (the answer a clock later)
	input  wire         c_mem_en,
	input  wire [7:0]   c_mem_we,         // byte enables (bit k = offset k); 0 reads
	input  wire [9:0]   c_mem_dw,         // [9] IMEM
	input  wire [63:0]  c_mem_wd,
	output wire [63:0]  c_mem_q,
	output reg          c_mem_ack,        // c_mem_q is the answer (two clocks after the request)
	// the CPU: the SP's registers (0-7) and SP_PC (8)
	input  wire         c_reg_we,
	input  wire         c_reg_re,         // a read happened (the semaphore sets on it)
	input  wire [3:0]   c_reg_idx,
	input  wire [31:0]  c_reg_wd,
	output wire [31:0]  c_reg_q,
	// the RDP's reads of DMEM over the XBUS: a doubleword, port B's last client
	input  wire         x_req,
	input  wire [8:0]   x_dw,
	output reg          x_ack,
	output wire [63:0]  x_q,
	// the DP's registers, for the RSP's own MTC0/MFC0 to 8-15
	output reg          dp_we,
	output reg  [2:0]   dp_idx,
	output reg  [31:0]  dp_wd,
	input  wire [31:0]  dp_q,             // the register dp_idx names, as it reads now
	output wire [2:0]   dp_ridx,
	// the DMA's lines of RDRAM
	output reg          dm_rd_req,
	input  wire         dm_rd_ack,
	output reg  [23:0]  dm_rd_line,
	input  wire [127:0] dm_rd_data,
	output reg          dm_wr_req,
	input  wire         dm_wr_ack,
	output reg  [23:0]  dm_wr_line,
	output reg  [127:0] dm_wr_data,
	output reg  [15:0]  dm_wr_mask,
	// the MI's SP interrupt
	output reg          irq_set,
	output reg          irq_clr,
	output wire         halted_o,
	output wire [287:0] sp_regs_flat,     // the SP's registers 0-7 and SP_PC, for reading
	output wire [95:0]  dbg,              // {halted, st, pc}, the instruction, the last COP0 read {reg, value[27:0]}
	input  wire [7:0]   dlog_idx,         // the DMA log: entry dlog_idx of the last 256 DMAs started
	output reg  [95:0]  dlog_q,
	output reg  [31:0]  dlog_n,           // DMAs started
	input  wire [9:0]   dbg_dw,           // while frozen: the doubleword dbg_dq shows ([9] IMEM)
	output reg  [63:0]  dbg_dq,
	output reg          frozen,           // stopped at the first DMA from below 1 MB (see dlog)
	// a retire trace, for the bench
	output reg          tr_valid,
	output reg  [11:0]  tr_pc,
	output reg  [31:0]  tr_ir
);
	function automatic [31:0] sx16; input [15:0] v; sx16 = {{16{v[15]}}, v}; endfunction
	function automatic [15:0] el;  input [127:0] v; input [2:0] n; el = v[127 - 16 * n -: 16]; endfunction
	function automatic [7:0]  byt; input [127:0] v; input [3:0] i; byt = v[127 - 8 * i -: 8]; endfunction
	function automatic [15:0] sclamp16; input signed [49:0] v;
		sclamp16 = (v < -50'sd32768) ? 16'h8000 : (v > 50'sd32767) ? 16'h7FFF : v[15:0];
	endfunction

	// =============================================================================
	// DMEM and IMEM
	// =============================================================================
	reg  [63:0] dmem [0:511];
	reg  [63:0] imem [0:511];
	integer k;
	initial for (k = 0; k < 512; k = k + 1) begin dmem[k] = 64'd0; imem[k] = 64'd0; end
	// port A: the RSP, addressed by what this clock's step wants (a register here
	// would give the read the address of the step before)
	wire [8:0]  da_addr;  wire [7:0] da_we; wire [63:0] da_wd; reg [63:0] da_q;
	wire [8:0]  ia_addr;  reg [63:0] ia_q;
	always @(posedge clk) begin
		for (k = 0; k < 8; k = k + 1) if (da_we[k]) dmem[da_addr][63 - 8 * k -: 8] <= da_wd[63 - 8 * k -: 8];
		da_q <= dmem[da_addr];
	end
	always @(posedge clk) ia_q <= imem[ia_addr];
	// port B: the CPU, or the DMA
	reg         b_en, b_imem;  reg [8:0] b_addr; reg [7:0] b_we; reg [63:0] b_wd;
	reg  [63:0] db_q, ib_q;
	always @(posedge clk) begin
		if (b_en && !b_imem) begin
			for (k = 0; k < 8; k = k + 1) if (b_we[k]) dmem[b_addr][63 - 8 * k -: 8] <= b_wd[63 - 8 * k -: 8];
			db_q <= dmem[b_addr];
		end
	end
	always @(posedge clk) begin
		if (b_en && b_imem) begin
			for (k = 0; k < 8; k = k + 1) if (b_we[k]) imem[b_addr][63 - 8 * k -: 8] <= b_wd[63 - 8 * k -: 8];
			ib_q <= imem[b_addr];
		end
	end

	// =============================================================================
	// the scalar registers, the vector registers, the accumulator and the flags
	// =============================================================================
	reg  [31:0] sr [0:31];
	initial for (k = 0; k < 32; k = k + 1) sr[k] = 32'd0;
	reg         sr_we; reg [4:0] sr_wa; reg [31:0] sr_wd;
	always @(posedge clk) if (sr_we && sr_wa != 5'd0) sr[sr_wa] <= sr_wd;

	// the vector registers: sixteen byte lanes
	reg  [7:0]  vb [0:15][0:31];
	initial for (k = 0; k < 32; k = k + 1) begin : vinit
		integer j; for (j = 0; j < 16; j = j + 1) vb[j][k] = 8'd0;
	end
	reg  [15:0] vw_lane;                  // which lanes are written: bit g is lane (byte) g
	reg  [4:0]  vw_reg;
	reg  [127:0] vw_data;
	genvar g;
	generate for (g = 0; g < 16; g = g + 1) begin : g_vlane
		always @(posedge clk) if (vw_lane[g]) vb[g][vw_reg] <= vw_data[127 - 8 * g -: 8];
	end endgenerate

	reg  [15:0] acch [0:7], accm [0:7], accl [0:7];
	reg  [7:0]  vcoh, vcol, vcch, vccl, vce;
	reg  [15:0] divin, divout;
	reg         divdp;

	// =============================================================================
	// the status, COP0 and the DMA's registers
	// =============================================================================
	reg         halted, broken, sstep, intbreak, semaphore;
	reg  [7:0]  signal;
	assign halted_o = halted;
	// pending (set up next) and current (running or last run)
	reg  [11:0] p_pbus; reg p_region; reg [23:0] p_dram; reg [11:0] p_len; reg [7:0] p_count; reg [11:0] p_skip;
	reg  [11:0] c_pbus; reg c_region; reg [23:0] c_dram; reg [11:0] c_len; reg [7:0] c_count; reg [11:0] c_skip;
	reg         dma_busy, dma_full, dma_rd, p_rd;

	// the eight registers as read, register i in [255 - 32 i -: 32]. (Wires, not a function
	// reading them: a continuous assignment through a function only re-evaluates when the
	// function's arguments change, so in simulation it went stale.)
	wire [255:0] sp_all = {{19'd0, c_region, c_pbus}, {8'd0, c_dram}, {c_skip, c_count, c_len}, {c_skip, c_count, c_len},
	                       {17'd0, signal, intbreak, sstep, 1'b0, dma_full, dma_busy, broken, halted},
	                       {31'd0, dma_full}, {31'd0, dma_busy}, {31'd0, semaphore}};
	function automatic [31:0] sp_read; input [255:0] all; input [2:0] i; sp_read = all[255 - 32 * i -: 32]; endfunction
	reg  [11:0] pc, npc;
	reg  [31:0] last_c0;
	reg  [95:0] dlog [0:255];
	reg         dlog_stop;
	initial dlog_stop = 1'b0;
	initial frozen = 1'b0;
	reg  [1:0] dbg_v; reg [1:0] dbg_im;
	always @(posedge clk) dlog_q <= dlog[dlog_idx];
	initial dlog_n = 32'd0;
	assign c_reg_q = (c_reg_idx == 4'd8) ? {20'd0, halted ? pc : 12'd0} : sp_read(sp_all, c_reg_idx[2:0]);
	assign sp_regs_flat = {sp_all, {20'd0, halted ? pc : 12'd0}};

	// =============================================================================
	// the sequencer
	// =============================================================================
	localparam [3:0] R_HALT = 4'd0, R_FETCH = 4'd1, R_EX = 4'd2, R_V2 = 4'd3, R_SMEM = 4'd4,
	                 R_SMEM2 = 4'd5, R_VLD = 4'd6, R_VLD2 = 4'd7, R_VST = 4'd8, R_LFV = 4'd9;
	reg  [3:0]  st;
	reg         pc_dw_lo;
	wire [31:0] ir = pc_dw_lo ? ia_q[31:0] : ia_q[63:32];
	assign dp_ridx = ir[13:11];
	wire [5:0]  op = ir[31:26];
	wire [4:0]  rs = ir[25:21], rt = ir[20:16], rd = ir[15:11], sa = ir[10:6];
	wire [5:0]  fn = ir[5:0];
	wire [31:0] a = sr[rs], b = sr[rt];
	wire [31:0] simm = sx16(ir[15:0]);
	wire [11:0] br_t = pc + 12'd4 + {ir[9:0], 2'b00};     // (pc here is the branch's own: see below)
	reg  [11:0] ipc;                      // the executing instruction's address

	// the vector operands
	wire [3:0]  ve = ir[24:21];           // the element of a computational op
	wire [3:0]  me = ir[10:7];            // the element of a move or a load/store
	wire [3:0]  me_1 = me + 4'd1;
	wire [4:0]  vt = ir[20:16], vs = ir[15:11], vd = ir[10:6];
	// (read lane by lane: a function reading vb would go stale in simulation, see sp_all)
	wire [127:0] vtr, vsr;
	generate for (g = 0; g < 16; g = g + 1) begin : g_vrd
		assign vtr[127 - 8 * g -: 8] = vb[g][vt];
		assign vsr[127 - 8 * g -: 8] = vb[g][vs];
	end endgenerate
	// (written without a function call inside another's arguments: xsim 2026.1 returns
	// the previous call's result for those)
	function automatic [127:0] bcast; input [127:0] v; input [3:0] e; integer j; reg [2:0] s; begin
		for (j = 0; j < 8; j = j + 1) begin
			s = e[3] ? e[2:0] : (e[3:2] == 2'b01) ? {j[2], e[1:0]} : (e[3:1] == 3'b001) ? {j[2:1], e[0]} : j[2:0];
			bcast[127 - 16 * j -: 16] = v[127 - 16 * s -: 16];
		end
	end endfunction
	wire [127:0] vte = bcast(vtr, ve);

	// latched for the second clock of a vector op
	reg  [127:0] q_vs, q_vte, q_vtraw;
	reg  [5:0]   q_fn;
	reg  [4:0]   q_vd, q_vs_n;
	reg  [3:0]   q_e;
	reg  [2:0]   q_de;
	reg  signed [33:0] prod [0:7];        // the lanes' products
	// VRCP/VRSQ: what the table lookup needs
	reg  signed [31:0] q_inp, q_mask, q_data;
	reg  [4:0]   q_shift;
	reg          q_sqrt, q_special;
	wire [15:0]  t_recip, t_rsqrt;
	wire [8:0]   t_addr;
	n64_rsp_tables u_tab (.clk(clk), .a(t_addr), .recip(t_recip), .rsqrt(t_rsqrt));
	// the lookup's index, worked out in R_EX so the table answers in R_V2
	wire [15:0]  rc_el  = el(vtr, ve[2:0]);
	wire signed [31:0] rc_inp = (fn[0] && divdp) ? {divin, rc_el} : {{16{rc_el[15]}}, rc_el};
	wire signed [31:0] rc_msk = rc_inp >>> 31;
	wire signed [31:0] rc_dat = (rc_inp ^ rc_msk) - ((rc_inp > -32'sd32768) ? rc_msk : 32'sd0);
	wire [31:0]  rc_sh  = clz32(rc_dat);
	wire [31:0]  rc_idx = ((rc_dat << rc_sh) & 32'h7FC0_0000) >> 22;
	assign t_addr = fn[2] ? ((rc_idx[8:0] & 9'h1FE) | {8'd0, rc_sh[0]}) : rc_idx[8:0];

	// the load/store walk
	reg  [4:0]   ls_kind;                 // the LWC2/SWC2 kind, or 16 + scalar
	reg          ls_store;
	reg  [4:0]   ls_k, ls_n;              // the step, and how many
	reg  [11:0]  ls_a;                    // the scaled address (12 bits are all that matter)
	reg  [3:0]   ls_e;
	reg  [4:0]   ls_t;
	reg  [4:0]   ls_start;                // the first byte offset of a ranged kind
	reg  [3:0]   ls_idx;                  // (index etc., kind by kind)
	reg  [31:0]  ls_acc;                  // a scalar load being assembled
	reg  [127:0] ls_tmp;                  // LFV's elements
	reg  [127:0] ls_v;                    // the register being stored (or LTV/STV's, per step)

	// the address and lane of a load/store step
	reg  [11:0]  sa_addr;
	reg  [3:0]   sa_lane;
	reg  [4:0]   sa_reg;
	reg          sa_elem;                 // writes an element (two lanes) from byte << shift
	reg  [3:0]   sa_shift;
	reg  [7:0]   sa_val;                  // a store's byte
	wire [3:0]   kq = ls_k[3:0];
	wire [3:0]   spv_off = ls_e + kq;               // (off & 15), off = e + k
	wire [11:0]  a7 = ls_a & 12'hFF8, a15 = ls_a & 12'hFF0;
	wire [4:0]   stv_i = {ls_t[4:3], 3'd0} + ((ls_kind == 5'h0B && !ls_store) ? (({2'd0, ls_e[3:1]} + {2'd0, ls_k[3:1]}) & 5'd7) : {2'd0, ls_k[3:1]});
	wire [127:0] stv_r;                   // STV/LTV's register for this step
	generate for (g = 0; g < 16; g = g + 1) begin : g_stv
		assign stv_r[127 - 8 * g -: 8] = vb[g][stv_i];
	end endgenerate
	always @(*) begin
		sa_addr = ls_a + {7'd0, ls_k}; sa_lane = 4'd0; sa_reg = ls_t; sa_elem = 1'b0; sa_shift = 4'd0; sa_val = 8'd0;
		case (ls_kind)
		5'h00: begin sa_addr = ls_a; sa_lane = ls_e; sa_val = byt(ls_v, ls_e); end                      // LBV SBV
		5'h01, 5'h02, 5'h03, 5'h04: begin                                                              // LSV LLV LDV LQV (S..)
			sa_lane = ls_start[3:0] + kq; sa_val = byt(ls_v, ls_start[3:0] + kq);
		end
		5'h05: begin                                                                                  // LRV SRV
			sa_addr = a15 + {7'd0, ls_k};
			sa_lane = ls_store ? (ls_e + kq + ls_idx) : (ls_start[3:0] + kq);
			sa_val = byt(ls_v, ls_e + kq + ls_idx);
		end
		5'h06, 5'h07: begin                                                                           // LPV LUV SPV SUV
			if (ls_store) begin
				sa_addr = ls_a + {7'd0, ls_k};
				if ((spv_off < 4'd8) == (ls_kind == 5'h06))
					sa_val = byt(ls_v, {(ls_e[2:0] + kq[2:0]), 1'b0});
				else sa_val = el(ls_v, ls_e[2:0] + kq[2:0]) >> 7;
			end else begin
				sa_addr = a7 + {8'd0, (ls_idx + kq) & 4'hF};
				sa_lane = {kq[2:0], 1'b0}; sa_elem = 1'b1; sa_shift = (ls_kind == 5'h06) ? 4'd8 : 4'd7;
			end
		end
		5'h08: begin                                                                                  // LHV SHV
			if (ls_store) begin
				sa_addr = a7 + {8'd0, (ls_idx + {kq[2:0], 1'b0}) & 4'hF};
				sa_val = {byt(ls_v, ls_e + {kq[2:0], 1'b0}), 1'b0} | (byt(ls_v, ls_e + {kq[2:0], 1'b0} + 4'd1) >> 7);
			end else begin
				sa_addr = a7 + {8'd0, (ls_idx + {kq[2:0], 1'b0}) & 4'hF};
				sa_lane = {kq[2:0], 1'b0}; sa_elem = 1'b1; sa_shift = 4'd7;
			end
		end
		5'h09: begin                                                                                  // LFV SFV
			if (ls_store) begin
				sa_addr = a7 + {8'd0, (ls_idx + {kq[1:0], 2'b00}) & 4'hF};
				sa_val = sfv_byte(ls_v, ls_e, kq[1:0]);
			end else begin
				sa_addr = a7 + {8'd0, (ls_idx + {kq[1:0], 2'b00} + (kq[2] ? 4'd8 : 4'd0)) & 4'hF};
				sa_lane = {kq[2:0], 1'b0}; sa_elem = 1'b1; sa_shift = 4'd7;
			end
		end
		5'h0A: begin                                                                                  // SWV
			sa_addr = a7 + {8'd0, (ls_idx + kq) & 4'hF};
			sa_val = byt(ls_v, ls_e + kq);
		end
		5'h0B: begin                                                                                  // LTV STV
			if (ls_store) begin
				sa_addr = a7 + {8'd0, (ls_idx + kq) & 4'hF};
				sa_val = byt(stv_r, ls_start[3:0] + kq);
				sa_reg = {ls_t[4:3], 3'd0} + {2'd0, ls_k[3:1]};
			end else begin
				sa_addr = a7 + {8'd0, (ls_idx + kq) & 4'hF};
				sa_lane = kq;
				sa_reg = {ls_t[4:3], 3'd0} + (({2'd0, ls_e[3:1]} + {2'd0, ls_k[3:1]}) & 5'd7);
			end
		end
		default: begin                                                                                // scalar
			sa_addr = ls_a + {7'd0, ls_k};
			sa_val = byt(ls_v, 4'd0 - ls_n[3:0] + kq);        // (16 - n + k): the register's low n bytes
		end
		endcase
	end
	function automatic [7:0] sfv_byte; input [127:0] v; input [3:0] e; input [1:0] k; reg [2:0] o; reg ok; begin
		ok = 1'b1;
		case (e)
		4'd0, 4'd15: o = {1'b0, k};
		4'd1:  o = (k == 2'd0) ? 3'd6 : (k == 2'd1) ? 3'd7 : (k == 2'd2) ? 3'd4 : 3'd5;
		4'd4:  o = (k == 2'd3) ? 3'd0 : {1'b0, k + 2'd1};
		4'd5:  o = (k == 2'd0) ? 3'd7 : {1'b1, k - 2'd1};
		4'd8:  o = {1'b1, k};
		4'd11: o = (k == 2'd0) ? 3'd3 : {1'b0, k - 2'd1};
		4'd12: o = (k == 2'd3) ? 3'd4 : {1'b1, k + 2'd1};
		default: begin o = 3'd0; ok = 1'b0; end
		endcase
		sfv_byte = ok ? (el(v, o) >> 7) : 8'd0;
	end endfunction

	assign ia_addr = pc[11:3];
	assign da_addr = sa_addr[11:3];
	assign da_we   = (st == R_VST && ls_k != ls_n) ? (8'h01 << sa_addr[2:0]) : 8'd0;   // bit k = offset k
	assign da_wd   = {8{sa_val}};
	// the byte a load step brought (the doubleword arrived a clock after its address)
	reg  [2:0]   ld_off;
	wire [7:0]   ld_byte = da_q[63 - 8 * ld_off -: 8];

	// =============================================================================
	// the vector unit's second clock: the lanes
	// =============================================================================
	reg  [127:0] vout;
	reg  [15:0]  n_acch [0:7], n_accm [0:7], n_accl [0:7];
	reg  [7:0]   n_vcoh, n_vcol, n_vcch, n_vccl, n_vce;
	reg          vout_we;
	integer n;
	reg  signed [49:0] acc, sum, prd;
	reg  [15:0] av, bv;
	reg  signed [16:0] as, bs;
	reg  [16:0] usum;
	reg  [31:0] r32;
	reg         c;
	always @(*) begin
		vout = 128'd0; vout_we = 1'b1;
		n_vcoh = vcoh; n_vcol = vcol; n_vcch = vcch; n_vccl = vccl; n_vce = vce;
		for (n = 0; n < 8; n = n + 1) begin
			n_acch[n] = acch[n]; n_accm[n] = accm[n]; n_accl[n] = accl[n];
			av = el(q_vs, n); bv = el(q_vte, n);
			as = {av[15], av}; bs = {bv[15], bv};
			acc = {{2{acch[n][15]}}, acch[n], accm[n], accl[n]};   // signed 48 in 50
			prd = {{16{prod[n][33]}}, prod[n]};
			sum = 50'sd0; r32 = 32'd0; c = 1'b0; usum = 17'd0;
			case (q_fn)
			6'h00, 6'h01, 6'h08, 6'h09: begin                                        // VMULF VMULU VMACF VMACU
				sum = (q_fn[3] ? acc : 50'sd0) + prd * 2 + (q_fn[3] ? 50'sd0 : 50'sd32768);
				{n_acch[n], n_accm[n], n_accl[n]} = sum[47:0];
				if (!q_fn[0]) vout[127 - 16 * n -: 16] = sat(n_acch[n], n_accm[n], n_accl[n], 1'b1, 16'h8000, 16'h7FFF);
				else if (q_fn[3])                                                    // VMACU
					vout[127 - 16 * n -: 16] = n_acch[n][15] ? 16'h0000 : (n_acch[n] != 16'd0 || n_accm[n][15]) ? 16'hFFFF : n_accm[n];
				else                                                                  // VMULU
					vout[127 - 16 * n -: 16] = n_acch[n][15] ? 16'h0000 : (n_acch[n][15] ^ n_accm[n][15]) ? 16'hFFFF : n_accm[n];
			end
			6'h02, 6'h0A: begin                                                      // VRNDP VRNDN
				sum = q_vs_n[0] ? ({{18{bv[15]}}, bv, 16'd0}) : {{34{bv[15]}}, bv};
				if ((q_fn == 6'h0A && acc < 0) || (q_fn == 6'h02 && acc >= 0)) acc = acc + sum;
				acc = {{2{acc[47]}}, acc[47:0]};
				{n_acch[n], n_accm[n], n_accl[n]} = acc[47:0];
				vout[127 - 16 * n -: 16] = sclamp16(acc >>> 16);
			end
			6'h03: begin                                                             // VMULQ
				sum = prd + ((prd < 0) ? 50'sd31 : 50'sd0);
				n_acch[n] = sum[31:16]; n_accm[n] = sum[15:0]; n_accl[n] = 16'd0;
				vout[127 - 16 * n -: 16] = sclamp16(sum >>> 1) & 16'hFFF0;
			end
			6'h0B: begin                                                             // VMACQ
				sum = {{18{acch[n][15]}}, acch[n], accm[n]};
				if (sum < 0 && !sum[5]) sum = sum + 50'sd32;
				else if (sum >= 32 && !sum[5]) sum = sum - 50'sd32;
				n_acch[n] = sum[31:16]; n_accm[n] = sum[15:0];
				vout[127 - 16 * n -: 16] = sclamp16(sum >>> 1) & 16'hFFF0;
			end
			6'h04: begin                                                             // VMUDL
				{n_acch[n], n_accm[n], n_accl[n]} = {32'd0, prod[n][31:16]};
				vout[127 - 16 * n -: 16] = prod[n][31:16];
			end
			6'h05, 6'h06: begin                                                      // VMUDM VMUDN
				{n_acch[n], n_accm[n], n_accl[n]} = prd[47:0];
				vout[127 - 16 * n -: 16] = (q_fn == 6'h05) ? prd[31:16] : prd[15:0];
			end
			6'h07: begin                                                             // VMUDH
				sum = prd <<< 16;
				{n_acch[n], n_accm[n], n_accl[n]} = sum[47:0];
				vout[127 - 16 * n -: 16] = sat(n_acch[n], n_accm[n], n_accl[n], 1'b1, 16'h8000, 16'h7FFF);
			end
			6'h0C: begin                                                             // VMADL
				sum = acc + {34'd0, prod[n][31:16]};
				{n_acch[n], n_accm[n], n_accl[n]} = sum[47:0];
				vout[127 - 16 * n -: 16] = sat(n_acch[n], n_accm[n], n_accl[n], 1'b0, 16'h0000, 16'hFFFF);
			end
			6'h0D, 6'h0E: begin                                                      // VMADM VMADN
				sum = acc + prd;
				{n_acch[n], n_accm[n], n_accl[n]} = sum[47:0];
				vout[127 - 16 * n -: 16] = (q_fn == 6'h0D) ? sat(n_acch[n], n_accm[n], n_accl[n], 1'b1, 16'h8000, 16'h7FFF)
				                                          : sat(n_acch[n], n_accm[n], n_accl[n], 1'b0, 16'h0000, 16'hFFFF);
			end
			6'h0F: begin                                                             // VMADH
				r32 = {acch[n], accm[n]} + prod[n][31:0];
				n_acch[n] = r32[31:16]; n_accm[n] = r32[15:0];
				vout[127 - 16 * n -: 16] = sat(n_acch[n], n_accm[n], accl[n], 1'b1, 16'h8000, 16'h7FFF);
			end
			6'h10, 6'h11: begin                                                      // VADD VSUB
				sum = (q_fn == 6'h10) ? ({{34{av[15]}}, av} + {{34{bv[15]}}, bv} + vcol[n])
				                      : ({{34{av[15]}}, av} - {{34{bv[15]}}, bv} - vcol[n]);
				n_accl[n] = sum[15:0];
				vout[127 - 16 * n -: 16] = sclamp16(sum);
				n_vcol[n] = 1'b0; n_vcoh[n] = 1'b0;
			end
			6'h13: begin                                                             // VABS
				if (av[15]) begin
					if (bv == 16'h8000) begin n_accl[n] = 16'h8000; vout[127 - 16 * n -: 16] = 16'h7FFF; end
					else begin n_accl[n] = -bv; vout[127 - 16 * n -: 16] = -bv; end
				end else if (av != 16'd0) begin n_accl[n] = bv; vout[127 - 16 * n -: 16] = bv; end
				else begin n_accl[n] = 16'd0; vout[127 - 16 * n -: 16] = 16'd0; end
			end
			6'h14: begin                                                             // VADDC
				usum = {1'b0, av} + {1'b0, bv};
				n_accl[n] = usum[15:0]; n_vcol[n] = usum[16]; n_vcoh[n] = 1'b0;
				vout[127 - 16 * n -: 16] = usum[15:0];
			end
			6'h15: begin                                                             // VSUBC
				usum = {1'b0, av} - {1'b0, bv};
				n_accl[n] = usum[15:0]; n_vcol[n] = usum[16]; n_vcoh[n] = usum != 17'd0;
				vout[127 - 16 * n -: 16] = usum[15:0];
			end
			6'h1D: begin                                                             // VSAR
				vout[127 - 16 * n -: 16] = (q_e == 4'd8) ? acch[n] : (q_e == 4'd9) ? accm[n] : (q_e == 4'd10) ? accl[n] : 16'd0;
			end
			6'h20, 6'h21, 6'h22, 6'h23: begin                                        // VLT VEQ VNE VGE
				case (q_fn[1:0])
				2'd0: c = ($signed(av) < $signed(bv)) || (av == bv && vcol[n] && vcoh[n]);
				2'd1: c = !vcoh[n] && av == bv;
				2'd2: c = av != bv || vcoh[n];
				default: c = ($signed(av) > $signed(bv)) || (av == bv && (!vcol[n] || !vcoh[n]));
				endcase
				n_vccl[n] = c; n_accl[n] = c ? av : bv;
				n_vcch[n] = 1'b0; n_vcol[n] = 1'b0; n_vcoh[n] = 1'b0;
				vout[127 - 16 * n -: 16] = c ? av : bv;
			end
			6'h24: begin                                                             // VCL
				if (vcol[n]) begin
					if (vcoh[n]) n_accl[n] = vccl[n] ? -bv : av;
					else begin
						usum = {1'b0, av} + {1'b0, bv};
						c = vce[n] ? (usum[15:0] == 16'd0 || !usum[16]) : (usum[15:0] == 16'd0 && !usum[16]);
						n_vccl[n] = c; n_accl[n] = c ? -bv : av;
					end
				end else begin
					if (vcoh[n]) n_accl[n] = vcch[n] ? bv : av;
					else begin
						c = av >= bv;
						n_vcch[n] = c; n_accl[n] = c ? bv : av;
					end
				end
				n_vcol[n] = 1'b0; n_vcoh[n] = 1'b0; n_vce[n] = 1'b0;
				vout[127 - 16 * n -: 16] = n_accl[n];
			end
			6'h25: begin                                                             // VCH
				if (av[15] ^ bv[15]) begin
					usum = {1'b0, av} + {1'b0, bv};                                 // (the low 16 bits are the s16 sum)
					c = $signed(usum[15:0]) <= 0;
					n_accl[n] = c ? -bv : av;
					n_vccl[n] = c; n_vcch[n] = bv[15]; n_vcol[n] = 1'b1;
					n_vcoh[n] = usum[15:0] != 16'd0 && av != (bv ^ 16'hFFFF);
					n_vce[n] = usum[15:0] == 16'hFFFF;
				end else begin
					usum = {1'b0, av} - {1'b0, bv};
					c = $signed(usum[15:0]) >= 0;
					n_accl[n] = c ? bv : av;
					n_vccl[n] = bv[15]; n_vcch[n] = c; n_vcol[n] = 1'b0;
					n_vcoh[n] = usum[15:0] != 16'd0 && av != (bv ^ 16'hFFFF);
					n_vce[n] = 1'b0;
				end
				vout[127 - 16 * n -: 16] = n_accl[n];
			end
			6'h26: begin                                                             // VCR
				if (av[15] ^ bv[15]) begin
					n_vcch[n] = bv[15];
					c = $signed({av[15], av}) + $signed({bv[15], bv}) + 18'sd1 <= 0;
					n_vccl[n] = c; n_accl[n] = c ? ~bv : av;
				end else begin
					n_vccl[n] = bv[15];
					c = $signed({av[15], av}) - $signed({bv[15], bv}) >= 0;
					n_vcch[n] = c; n_accl[n] = c ? bv : av;
				end
				n_vcol[n] = 1'b0; n_vcoh[n] = 1'b0; n_vce[n] = 1'b0;
				vout[127 - 16 * n -: 16] = n_accl[n];
			end
			6'h27: begin                                                             // VMRG
				n_accl[n] = vccl[n] ? av : bv; n_vcoh[n] = 1'b0; n_vcol[n] = 1'b0;
				vout[127 - 16 * n -: 16] = n_accl[n];
			end
			6'h28, 6'h29, 6'h2A, 6'h2B, 6'h2C, 6'h2D: begin                         // the logic
				case (q_fn[2:0])
				3'd0: n_accl[n] = av & bv;
				3'd1: n_accl[n] = ~(av & bv);
				3'd2: n_accl[n] = av | bv;
				3'd3: n_accl[n] = ~(av | bv);
				3'd4: n_accl[n] = av ^ bv;
				default: n_accl[n] = ~(av ^ bv);
				endcase
				vout[127 - 16 * n -: 16] = n_accl[n];
			end
			6'h37, 6'h3F: vout_we = 1'b0;                                           // VNOP VNULL
			default: begin                                                           // VZERO
				n_accl[n] = av + bv;
				vout[127 - 16 * n -: 16] = 16'd0;
			end
			endcase
		end
	end
	function automatic [15:0] sat; input [15:0] h, m, l; input slice; input [15:0] neg, pos; begin
		if (h[15]) sat = (h != 16'hFFFF || !m[15]) ? neg : (slice ? m : l);
		else       sat = (h != 16'h0000 || m[15]) ? pos : (slice ? m : l);
	end endfunction

	// VRCP/VRSQ's result, from the table's answer
	wire [15:0] tab = q_sqrt ? t_rsqrt : t_recip;
	wire signed [31:0] rq0 = {1'b0, 15'd0, 16'd0} | ({15'd0, 1'b1, tab} << 14);
	wire signed [31:0] rq = q_special ? q_data
	                      : ((q_sqrt ? (rq0 >>> ((5'd31 - q_shift) >> 1)) : (rq0 >>> (5'd31 - q_shift))) ^ q_mask);

	// =============================================================================
	// the DMA
	// =============================================================================
	localparam [2:0] D_IDLE = 3'd0, D_RD = 3'd1, D_RWAIT = 3'd2, D_WRB = 3'd3, D_WRB2 = 3'd4, D_WFLUSH = 3'd5, D_ROW = 3'd6;
	reg  [2:0]   dst;
	reg  [9:0]   d_n;                     // doublewords left in this row
	reg  [127:0] d_line;  reg [18:0] d_tag; reg d_lv;
	reg          d_wv;                    // a line being gathered for RDRAM
	wire [63:0]  d_bq = c_region ? ib_q : db_q;   // port B's answer, for the DMA
	reg          cpu_b;                   // the CPU had port B (its answer comes a clock later)
	reg          cpu_b_imem;
	assign c_mem_q = cpu_b_imem ? ib_q : db_q;
	assign x_q = db_q;
	reg          x_b, x_b2;               // the XBUS had port B; its answer is two clocks on

	// =============================================================================
	// one always block: the sequencer, COP0, the CPU's registers, the DMA
	// =============================================================================
	reg  [31:0] cw;      // a COP0 write's value, and which
	reg  [2:0]  ci;
	reg         cwe;
	// An MTC0 on the clock the CPU writes one of these too is kept and done on the
	// next clock. (It was dropped: a lost semaphore release left SM64's microcode
	// spinning on the semaphore, its task never finishing, after a few thousand.)
	wire        rsp_cw = st == R_EX && op == 6'h10 && rs == 5'h04 && !rd[3];
	wire        cpu_cw = c_reg_we && c_reg_idx[3] == 1'b0;
	reg         rw_pend;
	reg  [2:0]  rw_i;
	reg  [31:0] rw_d;
	always @(*) begin
		cwe = 1'b0; ci = 3'd0; cw = 32'd0;
		if (cpu_cw) begin cwe = 1'b1; ci = c_reg_idx[2:0]; cw = c_reg_wd; end
		else if (rw_pend) begin cwe = 1'b1; ci = rw_i; cw = rw_d; end
		else if (rsp_cw) begin cwe = 1'b1; ci = rd[2:0]; cw = b; end
	end
	always @(posedge clk) begin
		if (rst) rw_pend <= 1'b0;
		else if (cpu_cw && rsp_cw) begin rw_pend <= 1'b1; rw_i <= rd[2:0]; rw_d <= b; end
		else if (!cpu_cw) rw_pend <= 1'b0;
	end

	always @(posedge clk) begin
		sr_we <= 1'b0; vw_lane <= 16'd0; irq_set <= 1'b0; irq_clr <= 1'b0; dp_we <= 1'b0; tr_valid <= 1'b0;
		b_en <= 1'b0; cpu_b <= 1'b0; c_mem_ack <= cpu_b;
		x_b <= 1'b0; x_b2 <= x_b; x_ack <= x_b2;
		if (dm_rd_ack) dm_rd_req <= 1'b0;
		if (dm_wr_ack) dm_wr_req <= 1'b0;
		if (rst) begin
			st <= R_HALT; halted <= 1'b1; dlog_n <= 32'd0; dlog_stop <= 1'b0; frozen <= 1'b0; broken <= 1'b0; sstep <= 1'b0; intbreak <= 1'b0; semaphore <= 1'b0; signal <= 8'd0;
			pc <= 12'd0; npc <= 12'd4;
			dma_busy <= 1'b0; dma_full <= 1'b0; dst <= D_IDLE; d_lv <= 1'b0; d_wv <= 1'b0; dm_rd_req <= 1'b0; dm_wr_req <= 1'b0;
			c_len <= 12'd0; c_count <= 8'd0; c_skip <= 12'd0; c_pbus <= 12'd0; c_region <= 1'b0; c_dram <= 24'd0;
			vcoh <= 8'd0; vcol <= 8'd0; vcch <= 8'd0; vccl <= 8'd0; vce <= 8'd0; divin <= 16'd0; divout <= 16'd0; divdp <= 1'b0;
			for (k = 0; k < 8; k = k + 1) begin acch[k] <= 16'd0; accm[k] <= 16'd0; accl[k] <= 16'd0; end
		end else begin
			// --- the CPU's port B, first ------------------------------------------------
			if (c_mem_en) begin
				b_en <= 1'b1; b_imem <= c_mem_dw[9]; b_addr <= c_mem_dw[8:0]; b_we <= c_mem_we; b_wd <= c_mem_wd;
				cpu_b <= 1'b1; cpu_b_imem <= c_mem_dw[9];
			end
			// --- debugging: while frozen, port B reads the doubleword asked for -------------
			dbg_v <= {dbg_v[0], 1'b0}; dbg_im <= {dbg_im[0], dbg_dw[9]};
			if (dbg_v[1]) dbg_dq <= dbg_im[1] ? ib_q : db_q;
			if (frozen && !c_mem_en && !x_req && !b_en) begin
				b_en <= 1'b1; b_imem <= dbg_dw[9]; b_addr <= dbg_dw[8:0]; b_we <= 8'h00; dbg_v[0] <= 1'b1;
			end
			// --- the XBUS, when the CPU and the DMA leave port B free ------------------------
			if (x_req && !x_b && !x_b2 && !x_ack && !c_mem_en && !(dst == D_RD || dst == D_WRB)) begin
				b_en <= 1'b1; b_imem <= 1'b0; b_addr <= x_dw; b_we <= 8'h00; x_b <= 1'b1;
			end
			// --- the SP's registers (the CPU's, or the RSP's MTC0) -------------------------
			if (c_reg_re && c_reg_idx == 4'd7) semaphore <= 1'b1;
			if (c_reg_we && c_reg_idx == 4'd8) begin pc <= c_reg_wd[11:2] << 2; npc <= (c_reg_wd[11:0] & 12'hFFC) + 12'd4; end
			if (cwe) begin
				case (ci)
				3'd0: begin p_pbus <= cw[11:0] & 12'hFF8; p_region <= cw[12]; end
				3'd1: p_dram <= cw[23:0] & 24'hFFFFF8;
				3'd2, 3'd3: begin
					p_len <= cw[11:0] & 12'hFF8; p_count <= cw[19:12]; p_skip <= {cw[31:23], 3'b000};
					p_rd <= (ci == 3'd2); dma_full <= 1'b1;
				end
				3'd4: begin
					if (cw[0] && !cw[1]) halted <= 1'b0;
					if (cw[1] && !cw[0]) halted <= 1'b1;
					if (cw[2]) broken <= 1'b0;
					if (cw[3] && !cw[4]) irq_clr <= 1'b1;
					if (cw[4] && !cw[3]) irq_set <= 1'b1;
					if (cw[5] && !cw[6]) sstep <= 1'b0;
					if (cw[6] && !cw[5]) sstep <= 1'b1;
					if (cw[7] && !cw[8]) intbreak <= 1'b0;
					if (cw[8] && !cw[7]) intbreak <= 1'b1;
					for (k = 0; k < 8; k = k + 1) begin
						if (cw[9 + 2 * k] && !cw[10 + 2 * k]) signal[k] <= 1'b0;
						if (cw[10 + 2 * k] && !cw[9 + 2 * k]) signal[k] <= 1'b1;
					end
				end
				3'd7: semaphore <= 1'b0;
				default: ;
				endcase
			end

			// --- the DMA -----------------------------------------------------------------
			case (dst)
			// (debugging: an audio command chunk (DMEM 0x380) read from below 1 MB, which SM64 never does, is logged
			// and not started, and everything stops, so DMEM can be read as it was)
			D_IDLE: if (DEBUG_FREEZE && dma_full && !frozen && !dlog_stop && p_rd && p_dram < 24'h10_0000 && p_pbus == 12'h380 && !p_region) begin
				dlog[dlog_n[7:0]] <= {halted, p_rd, p_region, 5'd0, p_dram, ipc, p_pbus, p_count, p_skip, p_len, 8'd0};
				dlog_n <= dlog_n + 32'd1; dlog_stop <= 1'b1; frozen <= 1'b1;
			end else if (dma_full && !frozen && !(cwe && (ci == 3'd2 || ci == 3'd3))) begin
				// (the log stops at the first read from below 0x1000, which no microcode does:
				// what went before it is what is wanted)
				if (!dlog_stop) begin
					dlog[dlog_n[7:0]] <= {halted, p_rd, p_region, 5'd0, p_dram, ipc, p_pbus, p_count, p_skip, p_len, 8'd0};
					dlog_n <= dlog_n + 32'd1;
				end
				c_pbus <= p_pbus; c_region <= p_region; c_dram <= p_dram; c_len <= p_len; c_count <= p_count; c_skip <= p_skip;
				dma_rd <= p_rd; dma_busy <= 1'b1; dma_full <= 1'b0;
				d_n <= p_len[11:3] + 10'd1; d_lv <= 1'b0; d_wv <= 1'b0;
				dst <= p_rd ? D_RD : D_WRB;
			end
			// RDRAM to DMEM/IMEM: a doubleword a clock out of the line in hand
			D_RD: begin
				if (d_n == 10'd0) dst <= D_ROW;
				else if (d_lv && d_tag == c_dram[22:4]) begin
					if (!c_mem_en) begin
						b_en <= 1'b1; b_imem <= c_region; b_addr <= c_pbus[11:3]; b_we <= 8'hFF;
						b_wd <= {d_line[8 * {c_dram[3], 3'd0} +: 8], d_line[8 * {c_dram[3], 3'd1} +: 8], d_line[8 * {c_dram[3], 3'd2} +: 8],
						         d_line[8 * {c_dram[3], 3'd3} +: 8], d_line[8 * {c_dram[3], 3'd4} +: 8], d_line[8 * {c_dram[3], 3'd5} +: 8],
						         d_line[8 * {c_dram[3], 3'd6} +: 8], d_line[8 * {c_dram[3], 3'd7} +: 8]};
						c_dram <= c_dram + 24'd8; c_pbus <= c_pbus + 12'd8; d_n <= d_n - 10'd1;
					end
				end else if (!dm_rd_req) begin
					dm_rd_line <= RDRAM_LINE + {5'd0, c_dram[22:4]}; dm_rd_req <= 1'b1; dst <= D_RWAIT;
				end
			end
			D_RWAIT: if (dm_rd_ack) begin d_line <= dm_rd_data; d_tag <= c_dram[22:4]; d_lv <= 1'b1; dst <= D_RD; end
			// DMEM/IMEM to RDRAM: read a doubleword, then gather it into the line
			D_WRB: begin
				if (d_n == 10'd0) begin
					if (d_wv) begin dm_wr_req <= 1'b1; dst <= D_WFLUSH; end else dst <= D_ROW;
				end else if (d_wv && dm_wr_line != RDRAM_LINE + {5'd0, c_dram[22:4]}) begin
					dm_wr_req <= 1'b1; dst <= D_WFLUSH;
				end else if (!c_mem_en) begin
					b_en <= 1'b1; b_imem <= c_region; b_addr <= c_pbus[11:3]; b_we <= 8'h00; dst <= D_WRB2;
				end
			end
			D_WRB2: dst <= D_ROW + 3'd1;                                 // (the read's answer: next clock)
			3'd7: begin
				if (!d_wv) begin dm_wr_line <= RDRAM_LINE + {5'd0, c_dram[22:4]}; dm_wr_mask <= 16'd0; end
				for (k = 0; k < 8; k = k + 1)
					dm_wr_data[8 * ({c_dram[3], 3'd0} + k) +: 8] <= d_bq[63 - 8 * k -: 8];
				dm_wr_mask <= (d_wv ? dm_wr_mask : 16'd0) | (16'h00FF << {c_dram[3], 3'd0});
				d_wv <= 1'b1;
				c_dram <= c_dram + 24'd8; c_pbus <= c_pbus + 12'd8; d_n <= d_n - 10'd1;
				dst <= D_WRB;
			end
			D_WFLUSH: if (dm_wr_ack) begin d_wv <= 1'b0; dst <= (d_n == 10'd0) ? D_ROW : D_WRB; end
			D_ROW: begin
				if (c_count != 8'd0) begin
					c_count <= c_count - 8'd1; c_dram <= c_dram + {12'd0, c_skip}; d_n <= c_len[11:3] + 10'd1;
					dst <= dma_rd ? D_RD : D_WRB;
				end else begin
					// BUSY stays up when a queued DMA follows (ares starts it in the same step).
					// Dropped for the one clock before D_IDLE took it, a microcode polling BUSY
					// saw it finished: SM64's audio parsed a command chunk before it had come.
					dma_busy <= dma_full; c_len <= 12'hFF8; dst <= D_IDLE;
				end
			end
			default: dst <= D_IDLE;
			endcase

			// --- the sequencer -----------------------------------------------------------
			case (st)
			R_HALT: if (!halted) st <= R_FETCH;
			R_FETCH: begin
				if (halted) st <= R_HALT;
				else if (frozen) ;
				else begin
					pc_dw_lo <= pc[2]; ipc <= pc;
					pc <= npc; npc <= npc + 12'd4;
					st <= R_EX;
				end
			end
			R_EX: begin
				st <= R_FETCH;
				tr_valid <= 1'b1; tr_pc <= ipc; tr_ir <= ir;
				case (op)
				6'h00: begin
					sr_we <= 1'b1; sr_wa <= rd;
					case (fn)
					6'h00: sr_wd <= b << sa;
					6'h02: sr_wd <= b >> sa;
					6'h03: sr_wd <= $signed(b) >>> sa;
					6'h04: sr_wd <= b << a[4:0];
					6'h06: sr_wd <= b >> a[4:0];
					6'h07: sr_wd <= $signed(b) >>> a[4:0];
					6'h08: begin sr_we <= 1'b0; npc <= a[11:0] & 12'hFFC; end
					6'h09: begin npc <= a[11:0] & 12'hFFC; sr_wd <= {20'd0, ipc + 12'd8}; end
					6'h0D: begin sr_we <= 1'b0; halted <= 1'b1; broken <= 1'b1; if (intbreak) irq_set <= 1'b1; end
					6'h20, 6'h21: sr_wd <= a + b;
					6'h22, 6'h23: sr_wd <= a - b;
					6'h24: sr_wd <= a & b;
					6'h25: sr_wd <= a | b;
					6'h26: sr_wd <= a ^ b;
					6'h27: sr_wd <= ~(a | b);
					6'h2A: sr_wd <= {31'd0, $signed(a) < $signed(b)};
					6'h2B: sr_wd <= {31'd0, a < b};
					default: sr_wd <= a >> a[4:0];                         // SPECIAL_INVALID
					endcase
				end
				6'h01: begin
					if (rt == 5'h00 || rt == 5'h10) begin if (a[31]) npc <= ipc + 12'd4 + {ir[9:0], 2'b00}; end
					else if (rt == 5'h01 || rt == 5'h11) begin if (!a[31]) npc <= ipc + 12'd4 + {ir[9:0], 2'b00}; end
					if ((rt == 5'h10 || rt == 5'h11)) begin sr_we <= 1'b1; sr_wa <= 5'd31; sr_wd <= {20'd0, ipc + 12'd8}; end
				end
				6'h02: npc <= {ir[9:0], 2'b00};
				6'h03: begin npc <= {ir[9:0], 2'b00}; sr_we <= 1'b1; sr_wa <= 5'd31; sr_wd <= {20'd0, ipc + 12'd8}; end
				6'h04: if (a == b) npc <= ipc + 12'd4 + {ir[9:0], 2'b00};
				6'h05: if (a != b) npc <= ipc + 12'd4 + {ir[9:0], 2'b00};
				6'h06: if ($signed(a) <= 0) npc <= ipc + 12'd4 + {ir[9:0], 2'b00};
				6'h07: if ($signed(a) > 0) npc <= ipc + 12'd4 + {ir[9:0], 2'b00};
				6'h08, 6'h09: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= a + simm; end
				6'h0A: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= {31'd0, $signed(a) < $signed(simm)}; end
				6'h0B: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= {31'd0, a < simm}; end
				6'h0C: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= a & {16'd0, ir[15:0]}; end
				6'h0D: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= a | {16'd0, ir[15:0]}; end
				6'h0E: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= a ^ {16'd0, ir[15:0]}; end
				6'h0F: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= {ir[15:0], 16'd0}; end
				6'h10: begin                                                     // COP0
					if (rs == 5'h00) begin
						sr_we <= 1'b1; sr_wa <= rt;
						sr_wd <= rd[3] ? dp_q : sp_read(sp_all, rd[2:0]);
						last_c0 <= {rd[3:0], rd[3] ? dp_q[27:0] : sp_all[255 - 32 * rd[2:0] - 4 -: 28]};
						if (!rd[3] && rd[2:0] == 3'd7) semaphore <= 1'b1;
					end else if (rs == 5'h04 && rd[3]) begin
						dp_we <= 1'b1; dp_idx <= rd[2:0]; dp_wd <= b;
					end
					// (the MTC0 to 0-7 went through cwe above)
				end
				6'h12: begin                                                     // COP2
					if (!ir[25]) begin
						case (rs)
						5'h00: begin sr_we <= 1'b1; sr_wa <= rt; sr_wd <= sx16({vsr[127 - 8 * me -: 8], vsr[127 - 8 * me_1 -: 8]}); end
						5'h02: begin
							sr_we <= 1'b1; sr_wa <= rt;
							case (rd[1:0])
							2'd0: sr_wd <= sx16({vcoh, vcol});
							2'd1: sr_wd <= sx16({vcch, vccl});
							default: sr_wd <= sx16({8'd0, vce});
							endcase
						end
						5'h04: begin
							vw_reg <= rd; vw_data <= {16{b[15:8]}} ;
							vw_data[127 - 8 * me -: 8] <= b[15:8];
							if (me != 4'd15) vw_data[127 - 8 * (me + 4'd1) -: 8] <= b[7:0];
							vw_lane <= (16'h0001 << me) | ((me != 4'd15) ? (16'h0001 << (me + 4'd1)) : 16'd0);
						end
						5'h06: begin
							case (rd[1:0])
							2'd0: begin vcol <= rbits(b[7:0]); vcoh <= rbits(b[15:8]); end
							2'd1: begin vccl <= rbits(b[7:0]); vcch <= rbits(b[15:8]); end
							default: vce <= rbits(b[7:0]);
							endcase
						end
						default: ;
						endcase
					end else begin
						// a computational op: operands latched, products registered
						q_vs <= vsr; q_vte <= vte; q_fn <= fn; q_vd <= vd; q_vs_n <= vs; q_e <= ve; q_de <= ir[13:11];
						for (k = 0; k < 8; k = k + 1) prod[k] <= mulop(fn, vsr[127 - 16 * k -: 16], vte[127 - 16 * k -: 16]);
						q_inp <= rc_inp; q_mask <= rc_msk; q_sqrt <= fn[2]; q_shift <= rc_sh[4:0];
						if (rc_dat == 0) begin q_special <= 1'b1; q_data <= 32'h7FFF_FFFF; end
						else if (rc_inp == -32'sd32768) begin q_special <= 1'b1; q_data <= 32'hFFFF_0000; end
						else q_special <= 1'b0;
						st <= R_V2;
					end
				end
				6'h20, 6'h21, 6'h23, 6'h24, 6'h25, 6'h27: begin                // scalar loads
					ls_kind <= 5'h10; ls_store <= 1'b0; ls_a <= a[11:0] + simm[11:0]; ls_k <= 5'd0; ls_t <= rt;
					ls_n <= (op[1:0] == 2'b00) ? 5'd1 : (op[1:0] == 2'b01) ? 5'd2 : 5'd4;
					ls_acc <= 32'd0; ls_idx <= {2'd0, op[2], op[0]};       // [1] unsigned, [0] half/word
					st <= R_SMEM;
				end
				6'h28, 6'h29, 6'h2B: begin                                       // scalar stores
					ls_kind <= 5'h10; ls_store <= 1'b1; ls_a <= a[11:0] + simm[11:0]; ls_k <= 5'd0;
					ls_n <= (op[1:0] == 2'b00) ? 5'd1 : (op[1:0] == 2'b01) ? 5'd2 : 5'd4;
					ls_v <= {96'd0, b};
					st <= R_VST;
				end
				6'h32, 6'h3A: begin                                              // LWC2, SWC2
					ls_kind <= {1'b0, ir[14:11]}; ls_store <= op[3]; ls_e <= me; ls_t <= vt; ls_k <= 5'd0;
					ls_v <= vtr;
					begin : setup
						reg [11:0] sc; reg [6:0] i7; reg [3:0] kk;
						i7 = ir[6:0];
						kk = ir[14:11];
						sc = (kk == 4'd0) ? {{5{i7[6]}}, i7} : (kk == 4'd1) ? {{4{i7[6]}}, i7, 1'b0}
						   : (kk == 4'd2) ? {{3{i7[6]}}, i7, 2'b00} : (kk == 4'd3 || kk == 4'd6 || kk == 4'd7) ? {{2{i7[6]}}, i7, 3'b000}
						   : {i7[6], i7, 4'b0000};
						ls_a <= a[11:0] + sc;
						ls_plan(kk, op[3], a[11:0] + sc, me);
					end
					st <= op[3] ? R_VST : R_VLD;
				end
				default: ;                                                     // everything else does nothing
				endcase
				if (op == 6'h00 && fn == 6'h0D) st <= R_HALT;
			end

			R_V2: begin
				st <= R_FETCH;
				if (q_fn == 6'h30 || q_fn == 6'h31 || q_fn == 6'h34 || q_fn == 6'h35) begin
					divdp <= 1'b0; divout <= rq[31:16];
					for (k = 0; k < 8; k = k + 1) accl[k] <= el(q_vte, k);
					vw_reg <= q_vd; vw_data <= {8{rq[15:0]}};
					vw_lane <= 16'h0003 << {q_de, 1'b0};
				end else if (q_fn == 6'h32 || q_fn == 6'h36) begin           // VRCPH VRSQH
					for (k = 0; k < 8; k = k + 1) accl[k] <= el(q_vte, k);
					divdp <= 1'b1; divin <= el(q_vtraw, q_e[2:0]);
					vw_reg <= q_vd; vw_data <= {8{divout}};
					vw_lane <= 16'h0003 << {q_de, 1'b0};
				end else if (q_fn == 6'h33) begin                               // VMOV
					for (k = 0; k < 8; k = k + 1) accl[k] <= el(q_vte, k);
					vw_reg <= q_vd; vw_data <= q_vte;
					vw_lane <= 16'h0003 << {q_de, 1'b0};
				end else begin
					for (k = 0; k < 8; k = k + 1) begin acch[k] <= n_acch[k]; accm[k] <= n_accm[k]; accl[k] <= n_accl[k]; end
					vcoh <= n_vcoh; vcol <= n_vcol; vcch <= n_vcch; vccl <= n_vccl; vce <= n_vce;
					if (vout_we) begin vw_reg <= q_vd; vw_data <= vout; vw_lane <= 16'hFFFF; end
				end
			end

			// --- a scalar load: a byte at a time, two clocks each -----------------------------
			R_SMEM: begin
				ld_off <= sa_addr[2:0]; st <= R_SMEM2;
			end
			R_SMEM2: begin
				if (ls_k + 5'd1 == ls_n) begin
					sr_we <= 1'b1; sr_wa <= ls_t;
					case (ls_n)
					5'd1: sr_wd <= ls_idx[1] ? {24'd0, ld_byte} : {{24{ld_byte[7]}}, ld_byte};
					5'd2: sr_wd <= ls_idx[1] ? {16'd0, ls_acc[7:0], ld_byte} : {{16{ls_acc[7]}}, ls_acc[7:0], ld_byte};
					default: sr_wd <= {ls_acc[23:0], ld_byte};
					endcase
					st <= R_FETCH;
				end else begin
					ls_acc <= {ls_acc[23:0], ld_byte}; ls_k <= ls_k + 5'd1; st <= R_SMEM;
				end
			end

			// --- a vector load: a byte (or an element) at a time ------------------------------
			R_VLD: begin
				if (ls_k == ls_n) st <= (ls_kind == 5'h09) ? R_LFV : R_FETCH;
				else begin ld_off <= sa_addr[2:0]; st <= R_VLD2; end
			end
			R_VLD2: begin
				if (ls_kind == 5'h09) begin
					ls_tmp[127 - 16 * ls_k[2:0] -: 16] <= {8'd0, ld_byte} << 7;
				end else begin
					vw_reg <= sa_reg;
					if (sa_elem) begin
						vw_data <= {8{({8'd0, ld_byte} << sa_shift)}};
						vw_lane <= 16'h0003 << sa_lane;
					end else begin
						vw_data <= {16{ld_byte}};
						vw_lane <= 16'h0001 << sa_lane;
					end
				end
				ls_k <= ls_k + 5'd1; st <= R_VLD;
			end
			R_LFV: begin                                                        // LFV: the bytes e..e+7 of the elements
				vw_reg <= ls_t; vw_data <= ls_tmp;
				vw_lane <= lfv_mask(ls_e);
				st <= R_FETCH;
			end

			// --- a store: a byte a clock ------------------------------------------------------
			R_VST: begin
				if (ls_k == ls_n) st <= R_FETCH;
				else ls_k <= ls_k + 5'd1;                         // (the byte: da_we above)
			end
			default: st <= R_HALT;
			endcase
		end
	end

	// the bits of the flags in register order (bit n = element n)
	function automatic [7:0] rbits; input [7:0] v; rbits = v; endfunction
	// the multiply each op wants: operands extended by signedness
	function automatic signed [33:0] mulop; input [5:0] f; input [15:0] x, y; reg signed [16:0] sx, sy; begin
		case (f)
		6'h04, 6'h0C: begin sx = {1'b0, x}; sy = {1'b0, y}; end                 // VMUDL VMADL: u x u
		6'h05, 6'h0D: begin sx = {x[15], x}; sy = {1'b0, y}; end                // VMUDM VMADM: s x u
		6'h06, 6'h0E: begin sx = {1'b0, x}; sy = {y[15], y}; end                // VMUDN VMADN: u x s
		default:      begin sx = {x[15], x}; sy = {y[15], y}; end               // s x s
		endcase
		mulop = sx * sy;
	end endfunction
	function automatic [31:0] clz32; input [31:0] v; integer j; reg f; begin
		clz32 = 32; f = 1'b0;
		for (j = 31; j >= 0; j = j - 1) if (!f && v[j]) begin clz32 = 31 - j; f = 1'b1; end
	end endfunction
	function automatic [15:0] lfv_mask; input [3:0] e; integer j; begin
		lfv_mask = 16'd0;
		for (j = 0; j < 16; j = j + 1) if (j >= e && j < e + 8) lfv_mask = lfv_mask | (16'h0001 << j);
	end endfunction

	// the plan of a vector load/store: how many steps, and its per-kind constants
	always @(posedge clk) if (st == R_EX) q_vtraw <= vtr;
	task ls_plan; input [3:0] kk; input store; input [11:0] ad; input [3:0] e; reg [4:0] s, en; begin
		ls_idx <= 4'd0; ls_start <= {1'b0, e};
		case (kk)
		4'd0: ls_n <= 5'd1;
		4'd1, 4'd2, 4'd3: begin
			s = (kk == 4'd1) ? 5'd2 : (kk == 4'd2) ? 5'd4 : 5'd8;
			en = (!store && ({1'b0, e} + s > 5'd16)) ? 5'd16 : {1'b0, e} + s;
			ls_n <= store ? s : (en - {1'b0, e});
		end
		4'd4: begin
			en = {1'b0, e} + 5'd16 - {1'b0, ad[3:0]};
			ls_n <= store ? (5'd16 - {1'b0, ad[3:0]}) : ((en > 5'd16 ? 5'd16 : en) > {1'b0, e} ? ((en > 5'd16 ? 5'd16 : en) - {1'b0, e}) : 5'd0);
		end
		4'd5: begin
			if (store) begin ls_n <= {1'b0, ad[3:0]}; ls_idx <= 4'd0 - ad[3:0]; end    // the byte is (e + k + 16 - a) & 15
			else begin
				// start = 16 - ((a & 15) - e); steps from start to 15
				en = 5'd16 - ({1'b0, ad[3:0]} - {1'b0, e});
				ls_start <= en;
				ls_n <= ({1'b0, ad[3:0]} >= {1'b0, e} && en < 5'd16) ? (5'd16 - en) : 5'd0;
			end
		end
		4'd6, 4'd7: begin ls_n <= 5'd8; ls_idx <= ad[3:0] - e; if (!store) ls_idx <= {1'b0, ad[2:0]} - e; end
		4'd8: begin ls_n <= 5'd8; ls_idx <= store ? {1'b0, ad[2:0]} : ({1'b0, ad[2:0]} - e); end
		4'd9: begin ls_n <= store ? 5'd4 : 5'd8; ls_idx <= store ? {1'b0, ad[2:0]} : ({1'b0, ad[2:0]} - e); end
		4'd10: begin ls_n <= store ? 5'd16 : 5'd0; ls_idx <= {1'b0, ad[2:0]}; end
		4'd11: begin
			ls_n <= 5'd16;
			if (store) begin ls_idx <= {1'b0, ad[2:0]} - {e[3:1], 1'b0}; ls_start <= 5'd16 - {1'b0, e[3:1], 1'b0}; end
			else ls_idx <= (e + (ad[3] ? 4'd8 : 4'd0));
		end
		default: ls_n <= 5'd0;
		endcase
	end endtask

	assign dbg = {halted, 11'd0, st, 4'd0, pc, ir, last_c0};
endmodule

`default_nettype wire
