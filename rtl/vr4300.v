//////////////////////////////////////////////////////////////////////////////////
// vr4300.v - the Nintendo 64's CPU: a NEC VR4300, MIPS III, 64-bit, big-endian.
//
// Behaviour is tools/n64model.py's, which follows ares (ISC licence) instruction
// for instruction, including the chip's odd corners: MULT multiplies rs as 64
// bits by rt as 35, DIV divides rs as 32 bits sign-extended by rt as 64, SRA
// shifts the whole register before taking the low word, LWR sign-extends only a
// whole word, and the likely-and-link branches write RA either way.
//
// --- the pipeline ------------------------------------------------------------------
//
// Five stages, as the chip has:
//
//   F   the fetch address goes to the instruction port
//   D   the instruction word arrives; decode; register read
//   E   ALU, branch decision, address, exceptions (the commit point)
//   M   the data port gets the address (and a store its data)
//   W   load data arrives and is aligned; the register file is written
//
// Results forward from M and W into E. A load's data reaches E from W, so an
// instruction that uses a load's result right after it waits one clock. A taken
// branch is decided in E, after its delay slot was fetched; the fetch behind the
// delay slot is dropped, so a taken branch costs one clock. A likely branch not
// taken drops its delay slot instead.
//
// Everything is decided in E: an exception there kills what is behind it in D
// and F, and nothing of the faulting instruction reaches M. So exceptions are
// precise, and interrupts are taken on the instruction in E, before it runs.
//
// --- the ports ----------------------------------------------------------------------
//
// Both are the same handshake. A request (req, address, and for stores the data
// and byte enables) is taken in a clock where the pipeline advances; its answer
// (ready, and data) may come any clock after, and stays until the next request.
// Until it comes the pipeline holds. A cache or plain memory can sit behind
// either without the pipeline knowing which.
//
// The instruction port may ABANDON a request: the fetch behind a taken
// branch's delay slot is dropped, and with D then empty the next fetch is
// issued without waiting for its answer. A new request supersedes any
// unanswered one; memory must not deliver the old answer for the new request. The data port is 64 bits wide,
// big-endian: byte enable 0 and d_rdata[63:56] are the byte at offset 0.
//
// --- not yet --------------------------------------------------------------------------
//
// The TLB lookup (mapped addresses raise a TLB refill exception, which is what an
// empty TLB does), COP1 (the FPU: coprocessor-unusable, or a reserved instruction
// when enabled), and the caches (CACHE is a no-op while nothing is cached).
// 64-bit addressing (Status.KX) is not handled; no N64 game uses it.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module vr4300 #(
	parameter [31:0] RESET_PC = 32'hBFC0_0000
) (
	input  wire        clk,
	input  wire        rst,

	// --- instructions: address in F, word in D -----------------------------------
	output wire        i_req,
	output wire [31:0] i_addr,       // physical
	output wire        i_cached,     // KSEG0 (as opposed to KSEG1)
	input  wire        i_ready,
	input  wire [31:0] i_rdata,

	// --- data: address in M, data in W -------------------------------------------
	output wire        d_req,
	output wire        d_we,
	output wire [31:0] d_addr,       // physical, doubleword-aligned for the lanes
	output wire        d_cached,
	output wire [7:0]  d_be,         // bit k = the byte at offset k
	output wire [63:0] d_wdata,
	input  wire        d_ready,
	input  wire [63:0] d_rdata,

	// --- the rest -------------------------------------------------------------------
	input  wire [4:0]  irq,          // Cause.IP2..IP6 (the N64 uses IP2 for the MI)
	input  wire        count_tick,   // Count advances on these (half the CPU clock on the chip)

	// --- a retire trace, for the benches -------------------------------------------
	output reg         tr_valid,     // an instruction left W this clock
	output reg  [31:0] tr_pc,
	output reg         tr_we,
	output reg  [4:0]  tr_rd,
	output reg  [63:0] tr_val,
	output reg         tr_exc,       // an exception was taken in E this clock
	output reg  [4:0]  tr_code
);

	// =============================================================================
	// helpers
	// =============================================================================
	function [63:0] sx32; input [31:0] v; sx32 = {{32{v[31]}}, v}; endfunction
	function [63:0] sx16; input [15:0] v; sx16 = {{48{v[15]}}, v}; endfunction

	// exception codes
	localparam [4:0] X_INT = 5'd0, X_MOD = 5'd1, X_TLBL = 5'd2, X_TLBS = 5'd3, X_ADEL = 5'd4,
	                 X_ADES = 5'd5, X_SYS = 5'd8, X_BP = 5'd9, X_RI = 5'd10, X_CPU = 5'd11,
	                 X_OV = 5'd12, X_TR = 5'd13;

	// =============================================================================
	// COP0 state (written in E)
	// =============================================================================
	reg  [31:0] c0_status, c0_cause_ip01, c0_epc, c0_errorepc, c0_badvaddr;
	reg  [4:0]  c0_exccode;
	reg  [1:0]  c0_ce;
	reg         c0_bd;
	reg  [32:0] c0_count, c0_compare;     // in half counts: Count = count[32:1]
	reg         c0_timer;                  // Cause.IP7
	reg  [5:0]  c0_index, c0_wired;
	reg         c0_probe;
	reg  [63:0] c0_entryhi, c0_entrylo0, c0_entrylo1, c0_pagemask, c0_context, c0_xcontext;
	reg  [31:0] c0_config, c0_lladdr, c0_taglo, c0_watchlo, c0_watchhi;
	reg  [63:0] c0_latch;
	reg         llbit;
	reg  [4:0]  rnd;                       // Random, counting down from 31 to Wired

	wire        st_ie  = c0_status[0];
	wire        st_exl = c0_status[1];
	wire        st_erl = c0_status[2];
	wire [1:0]  st_ksu = c0_status[4:3];
	wire        st_bev = c0_status[22];
	wire        kernel = st_exl || st_erl || st_ksu == 2'b00;
	wire [7:0]  cause_ip = {c0_timer, irq, c0_cause_ip01[1:0]};
	wire        int_pending = st_ie && !st_exl && !st_erl && |(cause_ip & c0_status[15:8]);

	// =============================================================================
	// the register file: 32 x 64, written in W, read in D (write-through)
	// =============================================================================
	reg  [63:0] rf [0:31];
	integer k;
	initial for (k = 0; k < 32; k = k + 1) rf[k] = 64'd0;

	// =============================================================================
	// pipeline registers
	// =============================================================================
	// F
	reg  [31:0] f_pc;
	reg         f_valid;           // the fetch issued last advance belongs on the path
	// D
	reg         d_valid;
	reg  [31:0] d_pc;
	reg  [4:0]  d_fexc;            // a fetch exception travelling with it (0 = none, else code+1)
	// E
	reg         e_valid;
	reg  [31:0] e_pc, e_ir;
	reg  [4:0]  e_fexc;
	reg         e_bd;              // in a branch delay slot
	reg  [63:0] e_a, e_b;          // rs, rt as read in D (forwarding fixes them in E)
	// M
	reg         m_valid, m_mem, m_load, m_we_rf;
	reg  [4:0]  m_rd;
	reg  [63:0] m_res;             // ALU result, or a store's data
	reg  [31:0] m_pc;
	reg  [2:0]  m_lsel;            // the load kind
	reg  [2:0]  m_off;             // the byte offset within the doubleword
	reg  [63:0] m_rt;              // rt's old value, for the merging loads
	reg  [31:0] m_paddr;
	reg         m_cached, m_store;
	reg  [7:0]  m_be;
	reg  [63:0] m_wdata;
	reg  [2:0]  m_kind;            // merging load: {1, 0 LWL 1 LWR 2 LDL 3 LDR}, else 0
	reg         m_xmark, w_xmark;  // an exception was taken here: for the trace, in program order
	reg  [4:0]  m_xcode, w_xcode;
	// W
	reg  [2:0]  w_kind;
	wire [63:0] w_value;           // W's final value (a load's aligned data, or the result)
	wire        md_busy;
	reg         w_valid, w_load, w_we_rf;
	reg  [4:0]  w_rd;
	reg  [63:0] w_res, w_rt;
	reg  [31:0] w_pc;
	reg  [2:0]  w_lsel, w_off;
	reg         w_mem;

	// =============================================================================
	// stall
	// =============================================================================
	wire w_wait = w_valid && w_mem && !d_ready;          // data not back yet
	wire d_wait = d_valid && !i_ready;                   // instruction word not back yet
	wire e_hazard;                                       // E needs a load still in M
	wire e_muldiv_wait;                                  // E needs HI/LO, or the unit, still busy
	wire stall_all = w_wait || d_wait;
	wire stall_e   = e_hazard || e_muldiv_wait;          // E holds; a bubble goes to M
	wire adv       = !stall_all && !stall_e;             // F, D, E advance
	wire adv_mw    = !stall_all;                         // M, W advance

	// =============================================================================
	// D: decode what arrived, read the registers
	// =============================================================================
	wire [31:0] ir = i_rdata;
	wire [4:0]  d_rs = ir[25:21], d_rt = ir[20:16];
	// write-through: what W writes this clock is what D reads
	wire [63:0] rf_a = (w_valid && w_we_rf && w_rd == d_rs && d_rs != 5'd0) ? w_value : rf[d_rs];
	wire [63:0] rf_b = (w_valid && w_we_rf && w_rd == d_rt && d_rt != 5'd0) ? w_value : rf[d_rt];

	// =============================================================================
	// E: the instruction's fields
	// =============================================================================
	wire [5:0]  op  = e_ir[31:26];
	wire [4:0]  rs  = e_ir[25:21];
	wire [4:0]  rt  = e_ir[20:16];
	wire [4:0]  rd  = e_ir[15:11];
	wire [4:0]  sa  = e_ir[10:6];
	wire [5:0]  fn  = e_ir[5:0];
	wire [15:0] imm = e_ir[15:0];
	wire [63:0] simm = sx16(imm);
	wire [63:0] zimm = {48'd0, imm};

	// forwarding into E: M's result, then W's
	wire        fw_m_a = m_valid && m_we_rf && !m_load && m_rd == rs && rs != 5'd0;
	wire        fw_w_a = w_valid && w_we_rf && w_rd == rs && rs != 5'd0;
	wire        fw_m_b = m_valid && m_we_rf && !m_load && m_rd == rt && rt != 5'd0;
	wire        fw_w_b = w_valid && w_we_rf && w_rd == rt && rt != 5'd0;
	wire [63:0] a = fw_m_a ? m_res : fw_w_a ? w_value : e_a;
	wire [63:0] b = fw_m_b ? m_res : fw_w_b ? w_value : e_b;

	// which operands E actually reads (so a load in M only stalls what needs it)
	wire uses_rs = !(op == 6'h02 || op == 6'h03 || op == 6'h0F || op == 6'h10)
	               && !(op == 6'h00 && (fn == 6'h00 || fn == 6'h02 || fn == 6'h03 || fn == 6'h38 || fn == 6'h3A || fn == 6'h3B
	                                    || fn == 6'h3C || fn == 6'h3E || fn == 6'h3F || fn == 6'h10 || fn == 6'h12 || fn == 6'h0C || fn == 6'h0D || fn == 6'h0F));
	wire uses_rt = (op == 6'h00) || op == 6'h04 || op == 6'h05 || op == 6'h14 || op == 6'h15
	               || (op >= 6'h28 && op <= 6'h2F) || op == 6'h38 || op == 6'h3C || op == 6'h3F
	               || op == 6'h22 || op == 6'h26 || op == 6'h1A || op == 6'h1B
	               || (op == 6'h10 && (rs == 5'h04 || rs == 5'h05));
	wire ld_in_m = m_valid && m_load && m_we_rf && m_rd != 5'd0;
	assign e_hazard = e_valid && ld_in_m && ((uses_rs && m_rd == rs) || (uses_rt && m_rd == rt));

	// =============================================================================
	// E: the ALU
	// =============================================================================
	wire [63:0] sum   = a + b;
	wire [63:0] sumi  = a + simm;
	wire [63:0] diff  = a - b;
	wire [31:0] sum32 = a[31:0] + b[31:0];
	wire [31:0] sumi32 = a[31:0] + simm[31:0];
	wire [31:0] diff32 = a[31:0] - b[31:0];
	wire        ov_add  = ~(a[31] ^ b[31]) & (a[31] ^ sum32[31]);
	wire        ov_addi = ~(a[31] ^ simm[31]) & (a[31] ^ sumi32[31]);
	wire        ov_sub  = (a[31] ^ b[31]) & (a[31] ^ diff32[31]);
	wire        ov_dadd  = ~(a[63] ^ b[63]) & (a[63] ^ sum[63]);
	wire        ov_daddi = ~(a[63] ^ simm[63]) & (a[63] ^ sumi[63]);
	wire        ov_dsub  = (a[63] ^ b[63]) & (a[63] ^ diff[63]);
	wire        lt_s  = $signed(a) < $signed(b);
	wire        lt_u  = a < b;
	wire        lti_s = $signed(a) < $signed(simm);
	wire        lti_u = a < simm;

	// shifts: the 32-bit ones take the low word (SRA the whole register), the
	// doubleword ones all 64 bits
	wire [4:0]  sh5  = (fn[2]) ? a[4:0] : sa;                          // variable or immediate
	wire [5:0]  sh6  = (fn == 6'h14 || fn == 6'h16 || fn == 6'h17) ? a[5:0]
	                 : (fn[2]) ? {1'b1, sa} : {1'b0, sa};               // DSxx32 add 32
	wire [31:0] sll32 = b[31:0] << sh5;
	wire [31:0] srl32 = b[31:0] >> sh5;
	wire [63:0] sra64_5 = $signed(b) >>> sh5;
	wire [63:0] dsll = b << sh6;
	wire [63:0] dsrl = b >> sh6;
	wire [63:0] dsra = $signed(b) >>> sh6;

	// branches and jumps
	wire [31:0] br_target = e_pc + 32'd4 + {simm[29:0], 2'b00};
	wire [31:0] pc4       = e_pc + 32'd4;
	wire [31:0] j_target  = {pc4[31:28], e_ir[25:0], 2'b00};
	wire        eq = a == b;
	wire        ltz = a[63];
	wire        lez = a[63] || a == 64'd0;

	// =============================================================================
	// E: decode into what happens
	// =============================================================================
	reg  [63:0] res;          // the value for rd/rt
	reg         we_rf;        // writes a register
	reg  [4:0]  dst;
	reg         take_br;      // a taken branch or jump
	reg  [31:0] br_to;
	reg         is_br;        // any branch or jump (its next instruction is a delay slot)
	reg         likely_skip;  // a likely branch not taken: drop the delay slot
	reg  [4:0]  exc;          // 0 none, else code + 1
	reg         is_mem, is_load, is_store;
	reg  [2:0]  lsel;         // 0 LB 1 LBU 2 LH 3 LHU 4 LW 5 LWU 6 LD, 7 = merging (see mkind)
	reg  [2:0]  mkind;        // 0 LWL 1 LWR 2 LDL 3 LDR
	reg  [1:0]  msize;        // 0 byte 1 half 2 word 3 dword (alignment)
	reg         c0_wr;        // MTC0/DMTC0
	reg         is_eret, is_ll, is_sc;
	reg         md_start;     // starts the multiply/divide unit
	reg  [2:0]  md_op;        // 0 MULT 1 MULTU 2 DIV 3 DIVU 4 DMULT 5 DMULTU 6 DDIV 7 DDIVU
	reg         hi_wr, lo_wr; // MTHI, MTLO
	reg         reads_hilo;   // MFHI, MFLO
	reg  [63:0] c0_rdata;

	wire d64_ok = kernel || c0_status[7] && st_ksu == 2'b00 || (st_ksu == 2'b01 && c0_status[6]) || (st_ksu == 2'b10 && c0_status[5]);
	wire [63:0] hi, lo;

	// COP0 read
	always @(*) begin
		case (rd)
		5'd0:  c0_rdata = {32'd0, c0_probe, 25'd0, c0_index};
		5'd1:  c0_rdata = {59'd0, rnd};
		5'd2:  c0_rdata = c0_entrylo0;
		5'd3:  c0_rdata = c0_entrylo1;
		5'd4:  c0_rdata = c0_context;
		5'd5:  c0_rdata = c0_pagemask;
		5'd6:  c0_rdata = {58'd0, c0_wired};
		5'd8:  c0_rdata = sx32(c0_badvaddr);
		5'd9:  c0_rdata = {32'd0, c0_count[32:1]};
		5'd10: c0_rdata = c0_entryhi;
		5'd11: c0_rdata = {32'd0, c0_compare[32:1]};
		5'd12: c0_rdata = {32'd0, c0_status};
		5'd13: c0_rdata = {32'd0, c0_bd, 1'b0, c0_ce, 12'd0, cause_ip, 1'b0, c0_exccode, 2'b00};
		5'd14: c0_rdata = sx32(c0_epc);
		5'd15: c0_rdata = 64'h0B22;
		5'd16: c0_rdata = {32'd0, c0_config};
		5'd17: c0_rdata = {32'd0, c0_lladdr};
		5'd18: c0_rdata = {32'd0, c0_watchlo};
		5'd19: c0_rdata = {32'd0, c0_watchhi};
		5'd20: c0_rdata = c0_xcontext;
		5'd28: c0_rdata = {32'd0, c0_taglo};
		5'd29: c0_rdata = 64'd0;
		5'd30: c0_rdata = sx32(c0_errorepc);
		default: c0_rdata = c0_latch;
		endcase
	end

	always @(*) begin
		res = 64'd0; we_rf = 1'b0; dst = rd;
		take_br = 1'b0; br_to = br_target; is_br = 1'b0; likely_skip = 1'b0;
		exc = 5'd0;
		is_mem = 1'b0; is_load = 1'b0; is_store = 1'b0; lsel = 3'd0; mkind = 3'd0; msize = 2'd0;
		c0_wr = 1'b0; is_eret = 1'b0; is_ll = 1'b0; is_sc = 1'b0;
		md_start = 1'b0; md_op = 3'd0; hi_wr = 1'b0; lo_wr = 1'b0; reads_hilo = 1'b0;
		case (op)
		6'h00: begin
			we_rf = 1'b1;
			case (fn)
			6'h00: res = sx32(sll32);
			6'h02: res = sx32(srl32);
			6'h03: res = sx32(sra64_5[31:0]);
			6'h04: res = sx32(sll32);
			6'h06: res = sx32(srl32);
			6'h07: res = sx32(sra64_5[31:0]);
			6'h08: begin we_rf = 1'b0; is_br = 1'b1; take_br = 1'b1; br_to = a[31:0]; end
			6'h09: begin res = sx32(e_pc + 32'd8); is_br = 1'b1; take_br = 1'b1; br_to = a[31:0]; end
			6'h0C: begin we_rf = 1'b0; exc = X_SYS + 5'd1; end
			6'h0D: begin we_rf = 1'b0; exc = X_BP + 5'd1; end
			6'h0F: we_rf = 1'b0;                                       // SYNC
			6'h10: begin res = hi; reads_hilo = 1'b1; end
			6'h11: begin we_rf = 1'b0; hi_wr = 1'b1; end
			6'h12: begin res = lo; reads_hilo = 1'b1; end
			6'h13: begin we_rf = 1'b0; lo_wr = 1'b1; end
			6'h14: if (d64_ok) res = dsll; else begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			6'h16: if (d64_ok) res = dsrl; else begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			6'h17: if (d64_ok) res = dsra; else begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			6'h18, 6'h19, 6'h1A, 6'h1B: begin we_rf = 1'b0; md_start = 1'b1; md_op = {1'b0, fn[1:0]}; end
			6'h1C, 6'h1D, 6'h1E, 6'h1F: begin
				we_rf = 1'b0;
				if (d64_ok) begin md_start = 1'b1; md_op = {1'b1, fn[1:0]}; end else exc = X_RI + 5'd1;
			end
			6'h20: if (ov_add) begin we_rf = 1'b0; exc = X_OV + 5'd1; end else res = sx32(sum32);
			6'h21: res = sx32(sum32);
			6'h22: if (ov_sub) begin we_rf = 1'b0; exc = X_OV + 5'd1; end else res = sx32(diff32);
			6'h23: res = sx32(diff32);
			6'h24: res = a & b;
			6'h25: res = a | b;
			6'h26: res = a ^ b;
			6'h27: res = ~(a | b);
			6'h2A: res = {63'd0, lt_s};
			6'h2B: res = {63'd0, lt_u};
			6'h2C: if (!d64_ok) begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			       else if (ov_dadd) begin we_rf = 1'b0; exc = X_OV + 5'd1; end else res = sum;
			6'h2D: if (d64_ok) res = sum; else begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			6'h2E: if (!d64_ok) begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			       else if (ov_dsub) begin we_rf = 1'b0; exc = X_OV + 5'd1; end else res = diff;
			6'h2F: if (d64_ok) res = diff; else begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			6'h30: begin we_rf = 1'b0; if (!lt_s) exc = X_TR + 5'd1; end      // TGE
			6'h31: begin we_rf = 1'b0; if (!lt_u) exc = X_TR + 5'd1; end      // TGEU
			6'h32: begin we_rf = 1'b0; if (lt_s)  exc = X_TR + 5'd1; end      // TLT
			6'h33: begin we_rf = 1'b0; if (lt_u)  exc = X_TR + 5'd1; end      // TLTU
			6'h34: begin we_rf = 1'b0; if (eq)    exc = X_TR + 5'd1; end      // TEQ
			6'h36: begin we_rf = 1'b0; if (!eq)   exc = X_TR + 5'd1; end      // TNE
			6'h38, 6'h3A, 6'h3B, 6'h3C, 6'h3E, 6'h3F:
				if (!d64_ok) begin we_rf = 1'b0; exc = X_RI + 5'd1; end
				else res = (fn[1:0] == 2'b00) ? dsll : (fn[1:0] == 2'b10) ? dsrl : dsra;
			default: begin we_rf = 1'b0; exc = X_RI + 5'd1; end
			endcase
		end
		6'h01: begin                                                   // REGIMM
			case (rt)
			5'h00, 5'h02, 5'h10, 5'h12: begin
				is_br = 1'b1; take_br = ltz; likely_skip = rt[1] && !ltz;
				if (rt[4]) begin we_rf = 1'b1; dst = 5'd31; res = sx32(e_pc + 32'd8); end
			end
			5'h01, 5'h03, 5'h11, 5'h13: begin
				is_br = 1'b1; take_br = !ltz; likely_skip = rt[1] && ltz;
				if (rt[4]) begin we_rf = 1'b1; dst = 5'd31; res = sx32(e_pc + 32'd8); end
			end
			5'h08: if (!lti_s) exc = X_TR + 5'd1;                           // TGEI
			5'h09: if (!lti_u) exc = X_TR + 5'd1;                           // TGEIU
			5'h0A: if (lti_s)  exc = X_TR + 5'd1;                           // TLTI
			5'h0B: if (lti_u)  exc = X_TR + 5'd1;                           // TLTIU
			5'h0C: if (a == simm) exc = X_TR + 5'd1;                        // TEQI
			5'h0E: if (a != simm) exc = X_TR + 5'd1;                        // TNEI
			default: exc = X_RI + 5'd1;
			endcase
		end
		6'h02: begin is_br = 1'b1; take_br = 1'b1; br_to = j_target; end
		6'h03: begin is_br = 1'b1; take_br = 1'b1; br_to = j_target; we_rf = 1'b1; dst = 5'd31; res = sx32(e_pc + 32'd8); end
		6'h04, 6'h14: begin is_br = 1'b1; take_br = eq;  likely_skip = op[4] && !eq; end
		6'h05, 6'h15: begin is_br = 1'b1; take_br = !eq; likely_skip = op[4] && eq; end
		6'h06, 6'h16: begin is_br = 1'b1; take_br = lez; likely_skip = op[4] && !lez; end
		6'h07, 6'h17: begin is_br = 1'b1; take_br = !lez; likely_skip = op[4] && lez; end
		6'h08: begin dst = rt; if (ov_addi) exc = X_OV + 5'd1; else begin we_rf = 1'b1; res = sx32(sumi32); end end
		6'h09: begin dst = rt; we_rf = 1'b1; res = sx32(sumi32); end
		6'h0A: begin dst = rt; we_rf = 1'b1; res = {63'd0, lti_s}; end
		6'h0B: begin dst = rt; we_rf = 1'b1; res = {63'd0, lti_u}; end
		6'h0C: begin dst = rt; we_rf = 1'b1; res = a & zimm; end
		6'h0D: begin dst = rt; we_rf = 1'b1; res = a | zimm; end
		6'h0E: begin dst = rt; we_rf = 1'b1; res = a ^ zimm; end
		6'h0F: begin dst = rt; we_rf = 1'b1; res = sx32({imm, 16'd0}); end
		6'h10: begin                                                   // COP0
			if (!kernel && !c0_status[28]) exc = X_CPU + 5'd1;
			else case (rs)
			5'h00: begin dst = rt; we_rf = 1'b1; res = sx32(c0_rdata[31:0]); end          // MFC0
			5'h01: begin dst = rt; we_rf = 1'b1; res = c0_rdata; end                      // DMFC0
			5'h04, 5'h05: c0_wr = 1'b1;                                                   // MTC0, DMTC0
			default:
				if (rs[4]) begin
					case (fn)
					6'h01, 6'h02, 6'h06, 6'h08: ;          // TLBR/TLBWI/TLBWR/TLBP: in the COP0 block below
					6'h18: is_eret = 1'b1;
					default: exc = X_RI + 5'd1;
					endcase
				end else exc = X_RI + 5'd1;
			endcase
		end
		6'h11, 6'h31, 6'h35, 6'h39, 6'h3D: begin                       // COP1 and its loads/stores: not yet
			if (!c0_status[29]) begin exc = X_CPU + 5'd1; end
			else exc = X_RI + 5'd1;
		end
		6'h12, 6'h13: exc = (c0_status[30 + op[0]] ? X_RI : X_CPU) + 5'd1;
		6'h18: begin dst = rt;
			if (!d64_ok) exc = X_RI + 5'd1;
			else if (ov_daddi) exc = X_OV + 5'd1; else begin we_rf = 1'b1; res = sumi; end
		end
		6'h19: begin dst = rt; if (d64_ok) begin we_rf = 1'b1; res = sumi; end else exc = X_RI + 5'd1; end
		6'h1A, 6'h1B: begin dst = rt;                                          // LDL, LDR
			if (!d64_ok) exc = X_RI + 5'd1;
			else begin is_mem = 1'b1; is_load = 1'b1; we_rf = 1'b1; lsel = 3'd7; mkind = {2'b01, op[0]}; msize = 2'd0; end
		end
		6'h20, 6'h21, 6'h23, 6'h24, 6'h25, 6'h27, 6'h37: begin dst = rt;
			if (op == 6'h37 && !d64_ok) exc = X_RI + 5'd1;
			else begin
				is_mem = 1'b1; is_load = 1'b1; we_rf = 1'b1;
				case (op)
				6'h20: begin lsel = 3'd0; msize = 2'd0; end
				6'h24: begin lsel = 3'd1; msize = 2'd0; end
				6'h21: begin lsel = 3'd2; msize = 2'd1; end
				6'h25: begin lsel = 3'd3; msize = 2'd1; end
				6'h23: begin lsel = 3'd4; msize = 2'd2; end
				6'h27: begin lsel = 3'd5; msize = 2'd2; end
				default: begin lsel = 3'd6; msize = 2'd3; end
				endcase
			end
		end
		6'h22, 6'h26: begin dst = rt; is_mem = 1'b1; is_load = 1'b1; we_rf = 1'b1; lsel = 3'd7; mkind = {2'b00, op[2]}; msize = 2'd0; end
		6'h28: begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd0; end
		6'h29: begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd1; end
		6'h2B: begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd2; end
		6'h3F: if (d64_ok) begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd3; end else exc = X_RI + 5'd1;
		6'h2A, 6'h2E: begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd0; end           // SWL, SWR
		6'h2C, 6'h2D: if (d64_ok) begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd0; end else exc = X_RI + 5'd1;
		6'h2F: ;                                                                       // CACHE: nothing cached yet
		6'h30: begin dst = rt; is_mem = 1'b1; is_load = 1'b1; we_rf = 1'b1; lsel = 3'd4; msize = 2'd2; is_ll = 1'b1; end
		6'h34: begin dst = rt;
			if (!d64_ok) exc = X_RI + 5'd1;
			else begin is_mem = 1'b1; is_load = 1'b1; we_rf = 1'b1; lsel = 3'd6; msize = 2'd3; is_ll = 1'b1; end
		end
		6'h38: begin dst = rt; we_rf = 1'b1; is_sc = 1'b1; res = {63'd0, llbit};
			if (llbit) begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd2; end
		end
		6'h3C: begin dst = rt;
			if (!d64_ok) exc = X_RI + 5'd1;
			else begin we_rf = 1'b1; is_sc = 1'b1; res = {63'd0, llbit};
				if (llbit) begin is_mem = 1'b1; is_store = 1'b1; msize = 2'd3; end
			end
		end
		default: exc = X_RI + 5'd1;
		endcase
	end

	// =============================================================================
	// E: the address, and the exceptions it raises
	// =============================================================================
	wire [63:0] va64 = sumi;                 // rs + offset
	wire [31:0] va   = va64[31:0];
	wire        va_ext_bad = va64 != sx32(va);   // not a sign-extended 32-bit address
	wire        va_misal = (msize == 2'd1 && va[0]) || (msize == 2'd2 && va[1:0] != 2'd0) || (msize == 2'd3 && va[2:0] != 3'd0);
	wire [2:0]  seg  = va[31:29];
	// segments in 32-bit addressing: kseg0 (100) and kseg1 (101) are direct in
	// kernel mode; everything else is mapped -- and with no TLB yet, unmapped
	wire        va_direct = kernel && (seg == 3'b100 || seg == 3'b101);
	wire        va_user_bad = !kernel && va[31];             // user/supervisor reaching kernel space
	reg  [4:0]  mem_exc;
	always @(*) begin
		mem_exc = 5'd0;
		if (is_mem) begin
			if (va_misal || va_ext_bad || va_user_bad) mem_exc = (is_store ? X_ADES : X_ADEL) + 5'd1;
			else if (!va_direct) mem_exc = (is_store ? X_TLBS : X_TLBL) + 5'd1;
		end
	end
	wire [31:0] pa = {3'b000, va[28:0]};

	// stores: the lanes and enables. The data is big-endian (byte k is bits
	// [63-8k -: 8]); the enables are not ordered that way -- bit k of the mask is
	// the byte at offset k, so offset 0 is bit 0.
	reg  [7:0]  st_be;
	reg  [63:0] st_data;
	reg  [3:0]  wmask;
	always @(*) begin
		st_be = 8'd0; st_data = b; wmask = 4'd0;
		case (op)
		6'h28: begin st_be = 8'b0000_0001 << va[2:0]; st_data = {8{b[7:0]}}; end
		6'h29: begin st_be = 8'b0000_0011 << va[2:0]; st_data = {4{b[15:0]}}; end
		6'h2B, 6'h38: begin st_be = 8'b0000_1111 << va[2:0]; st_data = {2{b[31:0]}}; end
		6'h3F, 6'h3C: begin st_be = 8'hFF; st_data = b; end
		6'h2A: begin                                                    // SWL: bytes k..3 of the word
			wmask = 4'hF << va[1:0];
			st_be = va[2] ? {wmask, 4'd0} : {4'd0, wmask};
			st_data = {2{b[31:0] >> (8 * va[1:0])}};
		end
		6'h2E: begin                                                    // SWR: bytes 0..k of the word
			wmask = 4'hF >> (2'd3 - va[1:0]);
			st_be = va[2] ? {wmask, 4'd0} : {4'd0, wmask};
			st_data = {2{b[31:0] << (8 * (2'd3 - va[1:0]))}};
		end
		6'h2C: begin st_be = 8'hFF << va[2:0]; st_data = b >> (8 * va[2:0]); end               // SDL: bytes k..7
		6'h2D: begin st_be = 8'hFF >> (3'd7 - va[2:0]); st_data = b << (8 * (3'd7 - va[2:0])); end  // SDR: bytes 0..k
		default: ;
		endcase
	end

	// =============================================================================
	// E: what is taken -- the commit point
	// =============================================================================
	wire [4:0]  e_exc_any = e_fexc != 5'd0 ? e_fexc : exc != 5'd0 ? exc : mem_exc;
	wire        e_go    = e_valid && !stall_e && adv_mw;           // the instruction in E completes this clock
	wire        e_int   = e_go && int_pending;
	wire        e_trap  = e_go && !int_pending && e_exc_any != 5'd0;
	wire        e_redir_exc = e_int || e_trap;
	wire        e_ok    = e_go && !e_redir_exc;                    // it runs
	wire        e_eret  = e_ok && is_eret;
	wire        e_taken = e_ok && take_br;
	wire        e_skip  = e_ok && likely_skip;
	wire [31:0] vec_base = st_bev ? 32'hBFC0_0200 : 32'h8000_0000;
	wire        refill  = !st_exl && (e_exc_any == X_TLBL + 5'd1 || e_exc_any == X_TLBS + 5'd1) && !e_int;
	// the TLB refill vector is 080 when addressing is 64-bit in the current mode
	wire        bits64  = (st_exl || st_erl || st_ksu == 2'b00) ? c0_status[7] : (st_ksu == 2'b01) ? c0_status[6] : c0_status[5];
	wire [31:0] vector  = vec_base + (refill ? (bits64 ? 32'h080 : 32'h000) : 32'h180);

	// =============================================================================
	// the multiply/divide unit
	// =============================================================================
	// The unit takes its operands whenever E moves on, and is told a clock later
	// whether the instruction really ran: the start then hangs off a register,
	// not off E's exception decision (overflow, traps, the address checks),
	// which was the end of the CPU's longest path. The unit counts as busy for
	// that clock, so a MFHI/MFLO right behind still waits.
	reg         md_go_q, hi_wr_q, lo_wr_q;
	reg  [2:0]  md_op_q;
	reg  [63:0] md_a_q, md_b_q;
	always @(posedge clk) begin
		md_go_q <= !rst && e_ok && md_start;
		hi_wr_q <= !rst && e_ok && hi_wr;
		lo_wr_q <= !rst && e_ok && lo_wr;
		if (e_go) begin md_op_q <= md_op; md_a_q <= a; md_b_q <= b; end
	end
	vr4300_muldiv md (
		.clk(clk), .rst(rst),
		.start(md_go_q), .op(md_op_q), .a(md_a_q), .b(md_b_q),
		.wr_hi(hi_wr_q), .wr_lo(lo_wr_q), .wdata(md_a_q),
		.busy(md_busy), .hi(hi), .lo(lo)
	);
	assign e_muldiv_wait = e_valid && (md_busy || md_go_q || hi_wr_q || lo_wr_q) && (reads_hilo || md_start || hi_wr || lo_wr);

	// =============================================================================
	// the pipeline
	// =============================================================================
	// F's address: translated the same way as data (kseg0/kseg1 direct)
	wire [2:0]  fseg = f_pc[31:29];
	wire        f_direct = kernel && (fseg == 3'b100 || fseg == 3'b101);
	wire        f_bad  = f_pc[1:0] != 2'b00 || (!kernel && f_pc[31]);
	assign i_addr   = {3'b000, f_pc[28:0]};
	assign i_cached = fseg == 3'b100;
	// a fetch that would fault is not issued; the fault travels with it instead
	assign i_req    = adv && !f_bad && f_direct;
	wire [4:0]  f_exc = f_bad ? X_ADEL + 5'd1 : !f_direct ? X_TLBL + 5'd1 : 5'd0;

	// the next fetch address
	wire [31:0] next_pc = e_redir_exc ? vector
	                    : e_eret ? (st_erl ? c0_errorepc : c0_epc)
	                    : e_taken ? br_to
	                    : f_pc + 32'd4;

	// D's word: the fault, if the fetch was not issued, carries a dummy (a NOP)
	reg         d_noissue;               // the fetch for D was not sent (it faults)

	always @(posedge clk) begin
		tr_valid <= 1'b0; tr_exc <= 1'b0;
		if (rst) begin
			f_pc <= RESET_PC; f_valid <= 1'b1;
			d_valid <= 1'b0; e_valid <= 1'b0; m_valid <= 1'b0; w_valid <= 1'b0;
			d_noissue <= 1'b0; m_xmark <= 1'b0; w_xmark <= 1'b0;
		end else begin
			// --- F and D ---------------------------------------------------------------
			if (adv) begin
				f_pc <= next_pc;
				// what F fetched this clock enters D -- unless E redirects (the
				// fetch behind a taken branch's delay slot, or anything behind an
				// exception or ERET, is off the path)
				d_valid   <= !(e_redir_exc || e_eret || e_taken);
				d_pc      <= f_pc;
				d_fexc    <= f_exc;
				d_noissue <= f_exc != 5'd0;
				// D moves to E, unless killed: by an exception or ERET in E, or as
				// the delay slot of a likely branch not taken
				e_valid <= d_valid && !(e_redir_exc || e_eret || e_skip);
				e_pc    <= d_pc;
				e_ir    <= d_noissue ? 32'd0 : ir;
				e_fexc  <= d_fexc;
				e_a     <= rf_a;
				e_b     <= rf_b;
				e_bd    <= e_valid && is_br && e_ok;
			end
			// --- E to M ------------------------------------------------------------------
			if (adv_mw) begin
				m_valid  <= e_ok && !(e_valid && stall_e);
				m_mem    <= is_mem && !(is_sc && !llbit);
				m_load   <= is_load;
				m_store  <= is_store;
				m_we_rf  <= we_rf && dst != 5'd0;
				m_rd     <= dst;
				m_res    <= res;
				m_pc     <= e_pc;
				m_lsel   <= lsel;
				m_off    <= va[2:0];
				m_rt     <= b;
				m_paddr  <= {pa[31:3], 3'b000};
				m_cached <= seg == 3'b100;
				m_be     <= is_load ? 8'hFF : st_be;
				m_wdata  <= st_data;
				m_kind   <= (is_load && lsel == 3'd7) ? {1'b1, mkind[1:0]} : 3'd0;
				m_xmark  <= e_redir_exc;
				m_xcode  <= e_int ? X_INT : e_exc_any - 5'd1;
				w_xmark  <= m_xmark;
				w_xcode  <= m_xcode;
				// --- M to W ----------------------------------------------------------
				w_valid <= m_valid;
				w_load  <= m_load;
				w_mem   <= m_valid && m_mem;
				w_we_rf <= m_we_rf;
				w_rd    <= m_rd;
				w_res   <= m_res;
				w_rt    <= m_rt;
				w_pc    <= m_pc;
				w_lsel  <= m_lsel;
				w_off   <= m_off;
				w_kind  <= m_kind;
				// --- W: retire ---------------------------------------------------------
				if (w_valid) begin
					if (w_we_rf && w_rd != 5'd0) rf[w_rd] <= w_value;
					tr_valid <= 1'b1; tr_pc <= w_pc; tr_rd <= w_rd; tr_val <= w_value;
					tr_we <= w_we_rf && w_rd != 5'd0 && rf[w_rd] != w_value;
				end
				if (w_xmark) begin tr_exc <= 1'b1; tr_code <= w_xcode; end
			end
		end
	end


	// =============================================================================
	// M: the data port
	// =============================================================================
	assign d_req    = m_valid && m_mem && adv_mw;
	assign d_we     = m_store;
	assign d_addr   = m_paddr;
	assign d_cached = m_cached;
	assign d_be     = m_be;
	assign d_wdata  = m_wdata;

	// =============================================================================
	// W: align the load
	// =============================================================================
	reg  [63:0] ld;
	wire [63:0] dw = d_rdata;
	wire [7:0]  lb = dw[63 - 8 * w_off -: 8];
	wire [15:0] lh = dw[63 - 8 * w_off -: 16];
	wire [31:0] lw = dw[63 - 8 * w_off -: 32];
	wire [31:0] lw_word = w_off[2] ? dw[31:0] : dw[63:32];         // the aligned word, for LWL/LWR
	wire [1:0]  k4 = w_off[1:0];
	// (masks built by shifting all-ones: a subtractor here was a 64-bit carry chain
	//  at the head of the CPU's longest path)
	wire [31:0] lwl = (lw_word << (8 * k4)) | (w_rt[31:0] & ~(32'hFFFF_FFFF << (8 * k4)));
	wire [31:0] lwr_keep = ~(32'hFFFF_FFFF >> (8 * (3 - k4)));
	wire [31:0] lwr = (w_rt[31:0] & lwr_keep) | (lw_word >> (8 * (3 - k4)));
	wire [63:0] ldl = (dw << (8 * w_off)) | (w_rt & ~(64'hFFFF_FFFF_FFFF_FFFF << (8 * w_off)));
	wire [63:0] ldr_keep = ~(64'hFFFF_FFFF_FFFF_FFFF >> (8 * (7 - w_off)));
	wire [63:0] ldr = (w_rt & ldr_keep) | (dw >> (8 * (7 - w_off)));
	always @(*) begin
		if (w_kind[2]) begin
			case (w_kind[1:0])
			2'd0: ld = sx32(lwl);
			2'd1: ld = (k4 == 2'd3) ? sx32(lwr) : {w_rt[63:32], lwr};
			2'd2: ld = ldl;
			default: ld = ldr;
			endcase
		end else begin
			case (w_lsel)
			3'd0: ld = {{56{lb[7]}}, lb};
			3'd1: ld = {56'd0, lb};
			3'd2: ld = sx16(lh);
			3'd3: ld = {48'd0, lh};
			3'd4: ld = sx32(lw);
			3'd5: ld = {32'd0, lw};
			default: ld = dw;
			endcase
		end
	end
	assign w_value = w_load ? ld : w_res;

	// =============================================================================
	// COP0: exceptions, ERET, MTC0, the TLB instructions, Count/Compare, LL/SC
	// =============================================================================
	always @(posedge clk) begin
		if (rst) begin
			c0_status <= 32'h0040_0004;                                   // BEV, ERL
			// power-on values, as krom's tests read them on hardware: Cause
			// B000007C, EPC/ErrorEPC/BadVAddr all ones, Context 007FFFF0
			c0_cause_ip01 <= 32'd0; c0_exccode <= 5'd31; c0_ce <= 2'd3; c0_bd <= 1'b1;
			c0_epc <= 32'hFFFF_FFFF; c0_errorepc <= 32'hFFFF_FFFF; c0_badvaddr <= 32'hFFFF_FFFF;
			c0_count <= 33'd0; c0_compare <= 33'd0; c0_timer <= 1'b0;
			c0_index <= 6'd0; c0_probe <= 1'b0; c0_wired <= 6'd0; rnd <= 5'd31;
			c0_entryhi <= 64'd0; c0_entrylo0 <= 64'd0; c0_entrylo1 <= 64'd0; c0_pagemask <= 64'd0;
			c0_context <= 64'h0000_0000_007F_FFF0; c0_xcontext <= 64'd0;
			c0_config <= 32'h7006_E463; c0_lladdr <= 32'd0; c0_taglo <= 32'd0; c0_watchlo <= 32'd0; c0_watchhi <= 32'd0;
			c0_latch <= 64'd0; llbit <= 1'b0;
		end else begin
			// Count: one tick per count_tick; Compare matching it raises IP7
			if (count_tick) begin
				c0_count <= c0_count + 33'd1;
				if (c0_count + 33'd1 == c0_compare) c0_timer <= 1'b1;
			end
			if (adv) rnd <= (rnd == c0_wired[4:0] || rnd == 5'd0) ? 5'd31 : rnd - 5'd1;
			if (e_redir_exc) begin
				// the exception: EPC only when not already at exception level
				if (!st_exl) begin
					c0_epc <= e_bd ? e_pc - 32'd4 : e_pc;
					c0_bd  <= e_bd;
				end
				c0_exccode <= e_int ? X_INT : e_exc_any - 5'd1;
				c0_ce <= (op == 6'h11 || op == 6'h31 || op == 6'h35 || op == 6'h39 || op == 6'h3D) ? 2'd1
				       : (op == 6'h12) ? 2'd2 : (op == 6'h13) ? 2'd3 : 2'd0;
				c0_status[1] <= 1'b1;
				if (!e_int && (e_exc_any == X_ADEL + 5'd1 || e_exc_any == X_ADES + 5'd1 ||
				               e_exc_any == X_TLBL + 5'd1 || e_exc_any == X_TLBS + 5'd1 || e_exc_any == X_MOD + 5'd1)) begin
					c0_badvaddr <= e_fexc != 5'd0 ? e_pc : va;
					c0_context[22:4]  <= (e_fexc != 5'd0 ? e_pc[31:13] : va[31:13]);
					c0_xcontext[30:4] <= {{8{(e_fexc != 5'd0 ? e_pc[31] : va[31])}}, (e_fexc != 5'd0 ? e_pc[31:13] : va[31:13])};
					c0_entryhi[39:13] <= {{8{(e_fexc != 5'd0 ? e_pc[31] : va[31])}}, (e_fexc != 5'd0 ? e_pc[31:13] : va[31:13])};
				end
			end else if (e_eret) begin
				if (st_erl) c0_status[2] <= 1'b0; else c0_status[1] <= 1'b0;
				llbit <= 1'b0;
			end else if (e_ok && c0_wr) begin
				c0_latch <= b;
				case (rd)
				5'd0:  begin c0_index <= b[5:0]; c0_probe <= b[31]; end
				5'd2:  c0_entrylo0 <= {34'd0, b[29:0]};
				5'd3:  c0_entrylo1 <= {34'd0, b[29:0]};
				5'd4:  c0_context[63:23] <= b[63:23];
				5'd5:  c0_pagemask <= {39'd0, b[24:13], 13'd0};
				5'd6:  begin c0_wired <= b[5:0]; rnd <= 5'd31; end
				5'd9:  c0_count <= {b[31:0], 1'b0};
				5'd10: c0_entryhi <= {b[63:62], 22'd0, b[39:13], 5'd0, b[7:0]};
				5'd11: begin c0_compare <= {b[31:0], 1'b0}; c0_timer <= 1'b0; end
				5'd12: c0_status <= (b[31:0] & ~32'h0020_0000) | (c0_status & 32'h0020_0000);
				5'd13: c0_cause_ip01 <= {30'd0, b[9:8]};
				5'd14: c0_epc <= b[31:0];
				5'd16: c0_config <= (c0_config & ~32'h0F00_800F) | (b[31:0] & 32'h0F00_800F);
				5'd17: c0_lladdr <= b[31:0];
				5'd18: c0_watchlo <= b[31:0];
				5'd19: c0_watchhi <= b[31:0];
				5'd20: c0_xcontext[63:33] <= b[63:33];
				5'd28: c0_taglo <= b[31:0];
				5'd30: c0_errorepc <= b[31:0];
				default: ;
				endcase
			end
			if (e_ok && op == 6'h10 && rs[4] && fn == 6'h08) begin c0_probe <= 1'b1; c0_index <= 6'd0; end   // TLBP: nothing in an empty TLB
			if (e_ok && is_ll) begin llbit <= 1'b1; c0_lladdr <= {4'd0, pa[31:4]}; end
		end
	end

endmodule


// =================================================================================
// vr4300_muldiv - HI and LO, and the unit that fills them
//
// Multiply: four 33 x 33 partial products, one a clock, summed into 128 bits.
// Each operand is taken as 65 bits -- sign- or zero-extended -- so one datapath
// does all four: MULT (rs as 64 bits, rt as 35, the chip's quirk), MULTU (32 by
// 32 unsigned), DMULT and DMULTU. Divide: restoring, a bit a clock, 32 steps for
// DIV/DIVU and 64 for DDIV/DDIVU, with the signs taken off before and put back
// after -- 37 and 69 clocks on the chip, about the same here.
// =================================================================================
module vr4300_muldiv (
	input  wire        clk,
	input  wire        rst,
	input  wire        start,
	input  wire [2:0]  op,          // 0 MULT 1 MULTU 2 DIV 3 DIVU 4 DMULT 5 DMULTU 6 DDIV 7 DDIVU
	input  wire [63:0] a,
	input  wire [63:0] b,
	input  wire        wr_hi,
	input  wire        wr_lo,
	input  wire [63:0] wdata,
	output wire        busy,
	output reg  [63:0] hi,
	output reg  [63:0] lo
);
	function [63:0] sx32; input [31:0] v; sx32 = {{32{v[31]}}, v}; endfunction

	reg  [2:0]   kind;
	reg  [6:0]   n;            // steps left
	reg          run;
	assign busy = run;

	// --- multiply ---------------------------------------------------------------------
	reg  [64:0]  ma, mb;       // 65-bit operands
	reg  [127:0] acc;
	reg  [1:0]   step;
	// the four parts: low halves unsigned 32, high halves signed 33
	wire [32:0]  pa_ = step[1] ? ma[64:32] : {1'b0, ma[31:0]};
	wire [32:0]  pb_ = step[0] ? mb[64:32] : {1'b0, mb[31:0]};
	wire signed [65:0] part = $signed(pa_) * $signed(pb_);
	wire [7:0]   shift = ({1'b0, step[1]} + {1'b0, step[0]}) * 8'd32;
	// the product is registered before it is added: multiply in one clock,
	// accumulate in the next (five clocks for a MULT, as on the chip)
	reg  [65:0]  part_q;
	reg  [7:0]   shift_q;
	reg          part_v;       // part_q holds a product still to be added
	reg          mdone;        // all four products issued
	wire [127:0] acc_next = acc + ({{62{part_q[65]}}, part_q} << shift_q);

	// --- divide -------------------------------------------------------------------------
	reg  [63:0]  q, d;          // quotient (shifting in), divisor
	reg  [64:0]  r;             // partial remainder
	reg          neg_q, neg_r;
	reg  [63:0]  rs_orig;
	wire [64:0]  r_sh = {r[63:0], q[63]};
	wire [64:0]  r_sub = r_sh - {1'b0, d};

	always @(posedge clk) begin
		if (rst) begin
			run <= 1'b0; hi <= 64'd0; lo <= 64'd0;
		end else begin
			if (wr_hi) hi <= wdata;
			if (wr_lo) lo <= wdata;
			if (start) begin
				kind <= op;
				run  <= 1'b1;
				rs_orig <= a;
				case (op)
				3'd0: begin ma <= {a[63], a}; mb <= {{30{b[34]}}, b[34:0]}; end
				3'd1: begin ma <= {33'd0, a[31:0]}; mb <= {33'd0, b[31:0]}; end
				3'd4: begin ma <= {a[63], a}; mb <= {b[63], b}; end
				3'd5: begin ma <= {1'b0, a}; mb <= {1'b0, b}; end
				default: ;
				endcase
				acc  <= 128'd0;
				step <= 2'd0;
				part_v <= 1'b0;
				mdone  <= 1'b0;
				n    <= (op[1] == 1'b0) ? 7'd4 : (op[2] ? 7'd64 : 7'd32);
				// divide: magnitudes, signs remembered
				if (op[1]) begin
					case (op)
					3'd2: begin // DIV: rs as 32 bits sign-extended, rt as 64
						q <= a[31] ? -sx32(a[31:0]) : sx32(a[31:0]);
						d <= b[63] ? -b : b;
						neg_q <= a[31] ^ b[63]; neg_r <= a[31];
					end
					3'd3: begin q <= {32'd0, a[31:0]}; d <= {32'd0, b[31:0]}; neg_q <= 1'b0; neg_r <= 1'b0; end
					3'd6: begin q <= a[63] ? -a : a; d <= b[63] ? -b : b; neg_q <= a[63] ^ b[63]; neg_r <= a[63]; end
					default: begin q <= a; d <= b; neg_q <= 1'b0; neg_r <= 1'b0; end
					endcase
					// 32-step divides start with the dividend in the top half
					if (op[2] == 1'b0) begin
						q <= (op == 3'd2) ? ((a[31] ? -sx32(a[31:0]) : sx32(a[31:0])) << 32) : ({32'd0, a[31:0]} << 32);
					end
					r <= 65'd0;
				end
			end else if (run) begin
				if (kind[1] == 1'b0) begin
					// multiply: accumulate one partial product a clock
					if (part_v) acc <= acc_next;
					if (!mdone) begin
						part_q <= part; shift_q <= shift; part_v <= 1'b1;
						step <= step + 2'd1;
						if (step == 2'd3) mdone <= 1'b1;
					end else part_v <= 1'b0;
					if (mdone && part_v) begin            // the last product is going in now
						run <= 1'b0;
						if (kind[2]) begin
							lo <= acc_next[63:0];
							hi <= acc_next[127:64];
						end else begin
							lo <= sx32(acc_next[31:0]);
							hi <= sx32(acc_next[63:32]);
						end
					end
				end else if (n != 7'd0) begin
					// divide: one bit a clock
					if (!r_sub[64]) begin r <= r_sub; q <= {q[62:0], 1'b1}; end
					else begin r <= r_sh; q <= {q[62:0], 1'b0}; end
					n <= n - 7'd1;
				end else begin
					// the last step is in: the results, and the unit is free
					run <= 1'b0;
					if (d == 64'd0) begin
						// divide by zero: LO = -1 (+1 for a negative signed dividend), HI = rs
						case (kind)
						3'd2: begin lo <= rs_orig[31] ? 64'd1 : {64{1'b1}}; hi <= sx32(rs_orig[31:0]); end
						3'd3: begin lo <= {64{1'b1}}; hi <= sx32(rs_orig[31:0]); end
						3'd6: begin lo <= rs_orig[63] ? 64'd1 : {64{1'b1}}; hi <= rs_orig; end
						default: begin lo <= {64{1'b1}}; hi <= rs_orig; end
						endcase
					end else if (kind[2]) begin
						lo <= neg_q ? -q : q;
						hi <= neg_r ? -r[63:0] : r[63:0];
					end else begin
						lo <= sx32(neg_q ? -q[31:0] : q[31:0]);
						hi <= sx32(neg_r ? -r[31:0] : r[31:0]);
					end
				end
			end
		end
	end

endmodule

`default_nettype wire
