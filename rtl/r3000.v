//////////////////////////////////////////////////////////////////////////////////
// r3000.v - the PlayStation's CPU: a MIPS I R3000A, as the console has it.
//
// No TLB (the console's part has none: the address map is fixed and decoded
// from the top three bits), no FPU, and the "cache" the BIOS clears through
// SR.IsC is honoured by dropping the stores it makes while isolated. Every
// instruction a user program or the BIOS executes is here: the full integer
// set, the unaligned load/store four, multiply and divide into HI/LO, COP0
// with SR/CAUSE/EPC/BadVaddr/PRID, the exception model, and interrupts.
//
// --- the two delay slots -----------------------------------------------------------
//
// The architecture has two, and both are visible to software:
//
//   * A branch's delay slot is executed whether or not the branch is taken.
//   * A load's destination is not visible to the instruction after the load.
//     That instruction reads the OLD value. The R3000 has no interlock; the
//     compiler is expected to schedule around it, and some code reads the old
//     value on purpose.
//
// Both are implemented as what they are rather than smoothed over. A CPU that
// interlocks loads runs a PlayStation program wrongly in ways that take a long
// time to find, because the program was written for the one that does not.
//
// --- the bus ------------------------------------------------------------------------
//
// One access per enable, answered on the next: the same shape as the other
// three CPUs here, so it sits behind the same memory. `addr` is PHYSICAL --
// the segment bits are stripped here, since that is the whole of the memory
// management this chip has -- and `be` says which bytes of the word matter.
//
// The machine advances only when `ce` is high, and the top level withholds it
// while memory is not ready. That is how a fetch from DDR3 stalls the pipeline
// without the pipeline knowing.
//
// --- the shape --------------------------------------------------------------------------
//
// Multi-cycle, not pipelined: fetch, then execute, then a memory cycle if the
// instruction has one. Three or four enables per instruction. The console's CPU
// ran at 33 MHz and issued roughly one instruction per clock; this at 50 MHz
// with three or four per instruction is not that, and it does not need to be
// for the BIOS to draw its logo. When it needs to be, this is the module to
// replace, and the test program will say whether the replacement is right.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module r3000 (
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,

	// --- the bus --------------------------------------------------------------
	output reg  [31:0] addr,        // physical
	input  wire [31:0] din,
	output reg  [31:0] dout,
	output reg  [3:0]  be,
	output reg         we,
	output reg         req,
	// The instruction line the machine is already holding. An instruction cache
	// line is four instructions and instructions come in order, so three fetches
	// out of four are already in hand and need no bus cycle at all: the fetch
	// and its wait state collapse into one clock. Without this the processor
	// spent more than half its clocks waiting for memory it was always going
	// to find.
	output wire [31:0] fetch_addr,   // where the next instruction will come from
	input  wire        fetch_hit,    // it is in the line already held
	input  wire [31:0] fetch_word,   // and this is it
	input  wire        no_overlap,   // switch off running one instruction per clock
	output wire        fetching,     // this bus access is an instruction fetch

	// --- COP2, the GTE --------------------------------------------------------------
	// Register moves are one enable: the index and data go out, the coprocessor
	// answers reads combinationally. A command is a strobe with its 25-bit word;
	// `c2_busy` stalls the next move to the GTE until it has finished, which is
	// the interlock the real pair has.
	output reg         isc_inv,    // a store made with the cache isolated: drop this line
	output reg  [31:0] isc_addr,
	output reg         c2_we,       // MTC2 / CTC2 / LWC2: write c2_wdata to c2_reg
	output reg         c2_ctl,      // ...a control register rather than a data one
	output reg  [4:0]  c2_reg,      // (combinational: see below)
	output reg  [31:0] c2_wdata,
	input  wire [31:0] c2_rdata,    // the register at c2_reg, control if c2_ctl
	output wire [4:0]  c2_wreg,     // the register a WRITE goes to, and whether control: registered with
	output wire        c2_wctl,     // c2_we and c2_wdata, never c2_reg (see below)
	output reg         c2_cmd,      // COP2: execute c2_word
	output reg  [24:0] c2_word,
	input  wire        c2_busy,

	// --- interrupts -------------------------------------------------------------
	// Six external lines into Cause.IP[15:10]; the console wires its interrupt
	// controller to the first. Level-sensitive: hold it until acknowledged.
	input  wire [5:0]  irq,

	// --- for a testbench ---------------------------------------------------------
	output wire [31:0] dbg_pc,
	output wire [31:0] dbg_ir,
	output wire        dbg_exec,     // this cycle commits the instruction at PC (din)
	input  wire [5:0]  dbg_rsel,     // register peek: 0-31 = R, 32 = SR, 33 = CAUSE, 34 = EPC
	output wire [31:0] dbg_rval,
	output wire [31:0] dbg_a0, dbg_a1, dbg_ra, dbg_sp,   // for a snapshot at a watchpoint hit
	output wire [31:0] dbg_t1,                           // ...and t1: the BIOS function number (ps1_top's TTY)
	output reg         t_take,                           // an instruction committed last clock...
	output reg  [6:0]  t_cost,                           // ...and what it cost the console, in its cycles
	// every write into the register file, for a trace of one register:
	// port A is the queued writeback landing, port B an exception entry's load commit
	output wire        dbg_wa_en,
	output wire [4:0]  dbg_wa_reg,
	output wire [31:0] dbg_wa_val,
	output wire        dbg_wb_en,
	output wire [4:0]  dbg_wb_reg,
	output wire [31:0] dbg_wb_val,
	output wire        dbg_halted,
	// COP0 CAUSE and EPC, for reading what exception a program died on and where
	output wire [31:0] dbg_cause,
	output wire [31:0] dbg_epc
);

	// --- registers ------------------------------------------------------------------
	// THE REGISTER FILE IS DISTRIBUTED RAM, NOT FLIP-FLOPS.
	// It was `reg [31:0] R [0:31]`, cleared by a reset loop and written from
	// three places that can fire on the same clock (the queued result, the load
	// commit, and an exception's pending load). Either of those alone stops
	// synthesis using LUT-RAM, so it built 1,024 flip-flops with a write mux on
	// each and a 32-to-1 read mux per read port: 8,310 LUTs drove R, and about
	// 11,000 of the processor's 16,800 were the register file -- measured
	// 2026-09-27 by naming every LUT in the synthesised netlist after the signal
	// it drives. The part is at 100% of its slices; this was the biggest single
	// thing on it.
	//
	// Now: one bank of LUT-RAM per write port, and a live-value table that says
	// which bank last wrote each register. A read looks in all three and takes
	// the live one. `rf_live` stands in for the old reset: a register not
	// written since reset reads zero, exactly as before. Write priority is the
	// old statement order: the queued result, then the load commit, then the
	// exception's pending load, the later winning.
	(* ram_style = "distributed" *) reg [31:0] rf0 [0:31];   // the queued result (wb_*)
	(* ram_style = "distributed" *) reg [31:0] rf1 [0:31];   // the load commit (ld_creg / ld_cval)
	(* ram_style = "distributed" *) reg [31:0] rf2 [0:31];   // an exception's pending load (ld_reg / ld_val)
	reg [31:0] rf_lo, rf_hi;        // the live-value table: 00 bank 0, 01 bank 1, 1x bank 2
	reg [31:0] rf_live;             // written since reset
	reg        rf_w0, rf_w1, rf_w2; // this enable's writes (blocking, decided below)
	reg [31:0] s_a0, s_a1, s_ra, s_sp;   // copies of four registers for the debugger
	reg [31:0] s_t1;
	integer k;
	initial for (k = 0; k < 32; k = k + 1) begin rf0[k] = 32'd0; rf1[k] = 32'd0; rf2[k] = 32'd0; end

	// A register read, written as a macro rather than a function: a continuous
	// assignment is only sensitive to what appears in its own expression, and a
	// function's body is not part of that, so `assign b = `RF_RD(rt)` never saw
	// the register being written and simulated stale values (tb_r3000 case
	// 2184). Hardware would have been right; the benches would have lied.
	`define RF_RD(n) (!rf_live[n] ? 32'd0 : rf_hi[n] ? rf2[n] : rf_lo[n] ? rf1[n] : rf0[n])
`ifndef SYNTHESIS
	// For testbenches that look at `cpu.R[n]`: the register file as the
	// processor sees it, read out of the banks (not a copy kept alongside).
	wire [31:0] R [0:31];
	genvar rg;
	generate for (rg = 0; rg < 32; rg = rg + 1) begin : g_rview
		assign R[rg] = `RF_RD(rg);
	end endgenerate
`endif

	reg [31:0] PC;                  // of the instruction being executed
	reg [31:0] HI, LO;

	// COP0
	reg [31:0] SR, CAUSE, EPC, BADVADDR;
	assign dbg_cause = CAUSE;
	assign dbg_epc   = EPC;
	localparam PRID = 32'h0000_0002;

	// --- the delay slots ------------------------------------------------------------
	reg        br_pend;             // a branch resolved; take it after this one
	reg [31:0] br_target;
	reg        in_slot;             // this instruction IS a delay slot
	reg        ld_pend;             // a load landed; commit it after this one reads
	reg [4:0]  ld_reg;
	reg [31:0] ld_val;
	// A loaded value goes through two fetches before it is written: promoted
	// at the slot's fetch, written at the next. Writing it at the slot's own
	// fetch lands it before the slot reads -- which is exactly the interlock
	// the chip does not have, and case 2190 of the sweep is there to say so.
	reg        ld_commit;
	reg [4:0]  ld_creg;
	reg [31:0] ld_cval;

	// --- state ------------------------------------------------------------------------
	// Memory answers TWO enables after the address: the word is registered on
	// the enable after `req`, and readable on the one after that. So a fetch and
	// a load each spend one enable waiting, as the 68000 here does in S_FETCH2.
	localparam S_FETCH = 3'd0, S_EXEC = 3'd1, S_MEM = 3'd2, S_MEMR = 3'd3,
	           S_DIV   = 3'd4, S_EXC  = 3'd5, S_FETCHW = 3'd6, S_MEMW = 3'd7;
	localparam S_C2W = 4'd8;
	reg [3:0]  st;
	// Where the instruction just executed wants the processor to go. A
	// blocking variable, so the cycle that runs the instruction can read it
	// back and, when nothing is diverting, fetch the next instruction itself
	// instead of spending a whole clock doing it.
	reg [3:0]  nst;
	reg [31:0] lv;                 // the word a load just brought back
	reg [31:0] ir;
	reg [31:0] if_word;            // an instruction taken from the held line
	reg        if_fast;            // ...rather than fetched over the bus
	reg        halted;
	reg        c2_ctl_r;
	reg [4:0]  c2_reg_r;

	assign dbg_pc     = PC;
	assign dbg_ir     = ir;
	assign dbg_exec   = ce && (st == S_EXEC);
	assign dbg_rval   = dbg_rsel[5] ? (dbg_rsel[1:0] == 2'd0 ? SR : dbg_rsel[1:0] == 2'd1 ? CAUSE : EPC)
	                                : (dbg_rsel[4:0] == 5'd0 ? 32'd0 : `RF_RD(dbg_rsel[4:0]));
	assign dbg_halted = halted;

	// the instruction being executed: the one taken from the held line, or the
	// one the bus brought back
	wire [31:0] insn = if_fast ? if_word : din;

	// --- decode ----------------------------------------------------------------------------
	wire [5:0]  op    = ir[31:26];
	wire [4:0]  rs    = ir[25:21];
	wire [4:0]  rt    = ir[20:16];
	wire [4:0]  rd    = ir[15:11];
	wire [4:0]  sh    = ir[10:6];
	wire [5:0]  fn    = ir[5:0];
	wire [15:0] imm   = ir[15:0];
	wire [31:0] simm  = {{16{imm[15]}}, imm};
	wire [31:0] zimm  = {16'd0, imm};
	wire [25:0] jt    = ir[25:0];

	// Operands, with the pending load NOT yet visible -- that is the slot.
	// A register write waiting to land: see rd_reg below.
	reg        wb_en;
	reg [4:0]  wb_reg;
	reg [31:0] wb_val;

	wire [31:0] a = (rs == 5'd0) ? 32'd0 : `RF_RD(rs);
	wire [31:0] b = (rt == 5'd0) ? 32'd0 : `RF_RD(rt);
	// rt with a load to it that has landed but not yet been written back (see LWL/LWR)
	wire [31:0] b_ld = (rt != 5'd0 && ld_commit && ld_creg == rt) ? ld_cval
	                 : (rt != 5'd0 && ld_pend   && ld_reg  == rt) ? ld_val
	                 : b;

	// An instruction's result is queued and lands at the top of the next enable.
	// With a fetch cycle in between it reached the register file in good time;
	// running one instruction per clock there is no cycle in between, so the
	// instruction that wants it has to be handed it directly. Only the operand
	// reads get this: the unaligned-load merge in S_MEMR must see the register
	// as memory left it, and forwarding there corrupts it.
	function [31:0] operand;
		input [4:0] n;
		begin
			if (n == 5'd0)                 operand = 32'd0;
			else if (wb_en && wb_reg == n) operand = wb_val;
			else                           operand = `RF_RD(n);
		end
	endfunction

	wire is_special = (op == 6'h00);
	wire is_regimm  = (op == 6'h01);
	wire is_cop0    = (op == 6'h10);

	// --- the ALU -------------------------------------------------------------------------------
	wire [31:0] alu_b = is_special ? b : simm;
	wire [32:0] sum   = {a[31], a} + {alu_b[31], alu_b};
	wire [32:0] dif   = {a[31], a} - {alu_b[31], alu_b};
	wire        ovf_add = sum[32] != sum[31];
	wire        ovf_sub = dif[32] != dif[31];
	wire [4:0]  shamt = is_special && (fn == 6'h04 || fn == 6'h06 || fn == 6'h07) ? a[4:0] : sh;

	// multiply, one cycle; divide, iterated
	wire signed [63:0] mul_s = $signed(a) * $signed(b);
	wire [63:0]        mul_u = a * b;

	reg [5:0]  div_cnt;
	reg [31:0] div_q, div_r, div_d;
	reg        div_neg_q, div_neg_r, div_signed;
	reg        div_busy;
	reg [2:0]  hl_wait;             // what is parked in S_DIV: 0 MFHI 1 MFLO 2 MTHI 3 MTLO 4 MULT 5 MULTU 6 DIV 7 DIVU
	reg [31:0] hl_a, hl_b;          // its operands
	// The multiplier is pipelined like the divider: operands registered on
	// the instruction, the product a cycle later, HI/LO the cycle after. As
	// one combinational step from the instruction word it was 20 ns from
	// the bus register through four DSPs and a 32-bit add into HI, the
	// worst path of the whole build once the GTE's was fixed.
	reg        mul_busy;
	reg [1:0]  mul_cnt;
	reg [31:0] mul_a, mul_b;
	reg        mul_sgn;
	reg [63:0] mul_p;
	// the product every clock, not only on the processor's enable: its operands change only
	// when a multiply starts, so it is the same value at the same clock -- and the enable
	// (the caches' hit logic) is no longer in front of the multiplier's registers
	always @(posedge clk) mul_p <= $signed({mul_sgn & mul_a[31], mul_a}) * $signed({mul_sgn & mul_b[31], mul_b});
	wire       hl_busy = div_busy || mul_busy;
	reg [4:0]  div_wait_rd;

	// --- exceptions ----------------------------------------------------------------------------
	localparam EXC_INT = 5'd0, EXC_ADEL = 5'd4, EXC_ADES = 5'd5, EXC_SYS = 5'd8,
	           EXC_BP  = 5'd9, EXC_RI   = 5'd10, EXC_OV  = 5'd12, EXC_IBE = 5'd6, EXC_CPU = 5'd11;
	reg [4:0]  exc_code;
	reg [1:0]  exc_ce;                // a coprocessor-unusable exception's coprocessor (Cause 29:28)
	reg        exc_take;
	reg [31:0] exc_bad;
	reg        exc_bd;              // the fault was in a delay slot

	// Interrupts pending: the external lines land in CAUSE.IP[15:10]; IP[9:8]
	// are software-writable. Taken at an instruction boundary when enabled.
	wire [7:0] ip = {irq, CAUSE[9:8]};
	wire irq_now = SR[0] && ((SR[15:8] & ip) != 8'd0);

	// --- the physical address ----------------------------------------------------------------
	// KSEG0/KSEG1 are the low 512 MB with the segment bits removed; KUSEG maps
	// straight through. KSEG2 does not exist on this console.
	wire [31:0] ea   = a + simm;
	wire [31:0] phys = ea[31] ? {3'b000, ea[28:0]} : ea;
	wire [31:0] pc_phys = PC[31] ? {3'b000, PC[28:0]} : PC;
	// code runs from RAM, the BIOS ROM and expansion 1 only: a fetch anywhere else -- the
	// scratchpad, an I/O port -- is an instruction bus error on the chip (ps1-tests
	// cpu/code-in-io), where ours fetched whatever was there and ran it
	// ...and from most I/O ports, which hand back what they hold (SPU, DMA: ps1-tests runs code
	// there), but not from the interrupt controller or the MDEC
	wire        pc_io        = (PC[28:12] == 17'h1F801) && (PC[11:4] != 8'h07) && (PC[11:4] != 8'h82);
	wire        pc_fetchable = (PC[31:29] != 3'b111) && ((PC[28:23] == 6'd0) || (PC[28:19] == 10'h3F8) || (PC[28:23] == 6'h3E) || pc_io);
	// Where the next instruction lives. Execute assigns exactly this to PC on
	// every ordinary instruction, and it is made of registers only, so it is
	// known before the instruction has run -- which is what lets the same cycle
	// fetch it.
	wire [31:0] npc      = br_pend ? br_target : PC + 32'd4;
	wire [31:0] npc_phys = npc[31] ? {3'b000, npc[28:0]} : npc;
	// While executing, ask the cache about the instruction after this one; the
	// rest of the time, about the one being fetched.
	assign fetch_addr = (st == S_EXEC) ? npc_phys : pc_phys;
	assign fetching   = (st == S_FETCHW);
	// this fetch will go straight to execute: the instruction is in hand and
	// nothing is diverting the processor first
	wire fast_go = fetch_hit && !(irq_now && !in_slot) && (PC[1:0] == 2'b00);
	// The same question asked from the states that follow a load or a store,
	// where the program counter already points at the next instruction: can it
	// be taken straight from the cache instead of spending a fetch cycle on it?
	wire mem_go  = !no_overlap && fetch_hit && !irq_now && (PC[1:0] == 2'b00);

	// The GTE's read side is combinational on c2_reg / c2_ctl, so for a move OUT
	// of it those are driven from the instruction being executed (`insn`: the
	// held word on the fast path, the arriving one otherwise). They used to be
	// taken from `din` a cycle ahead, which is the next instruction on the fast
	// path -- right when the move followed another fast instruction, wrong when
	// it arrived through a fetch (a cache miss): the read then used the last
	// register WRITTEN, and a game's square root read LZCS back instead of LZCR.
	// ...and a WRITE has lines of its own. It is registered (c2_we/c2_wdata with c2_reg_r), so it
	// reaches the GTE the clock after its instruction -- the clock a move OUT right behind it puts
	// ITS register number on c2_reg. Through c2_reg the write went to the register being read:
	// libgte's MulMatrix0 does `mtc2 t2,d2 / mfc2 v1,d9`, VXY1 landed in IR1, and Gran Turismo 2's
	// matrices came out with an empty middle row and column -- every vertex on one line.
	assign c2_wreg = c2_reg_r;
	assign c2_wctl = c2_ctl_r;
	always @(*) begin
		c2_reg = c2_reg_r;
		c2_ctl = c2_ctl_r;
		if (st == S_EXEC && insn[31:26] == 6'h12 && !insn[25]
		    && (insn[25:21] == 5'h00 || insn[25:21] == 5'h02)) begin
			c2_reg = insn[15:11];
			c2_ctl = insn[22];     // CFC2 is 5'h02 in bits 25:21, i.e. bit 22 set
		end
		if (st == S_EXEC && insn[31:26] == 6'h3A) begin   // SWC2: data register rt
			c2_reg = insn[20:16];
			c2_ctl = 1'b0;
		end
	end

	// --- the register file write --------------------------------------------------------------
	assign dbg_a0 = s_a0; assign dbg_a1 = s_a1; assign dbg_ra = s_ra; assign dbg_sp = s_sp; assign dbg_t1 = s_t1;
	// (the write-trace ports, after everything they look at is declared)
	assign dbg_wa_en  = ce && wb_en && (wb_reg != 5'd0);
	assign dbg_wa_reg = wb_reg;
	assign dbg_wa_val = wb_val;
	assign dbg_wb_en  = ce && (st == S_EXC) && ((ld_pend && ld_reg != 5'd0) || (ld_commit && ld_creg != 5'd0));
	assign dbg_wb_reg = (ld_pend && ld_reg != 5'd0) ? ld_reg : ld_creg;
	assign dbg_wb_val = (ld_pend && ld_reg != 5'd0) ? ld_val : ld_cval;

	integer i;
	always @(posedge clk) begin
		// THE GTE LINES ARE ONE CLOCK, WHATEVER THE CLOCK ENABLE DOES.
		// They used to be cleared inside `if (ce)` with everything else, so when
		// the processor lost its enable on the clock after issuing a GTE command
		// -- a cache miss, a DMA owning the bus, anything -- `c2_cmd` stayed
		// high. The GTE starts a command on `cmd && !run`, so as soon as the one
		// it was running finished it started the SAME ONE AGAIN, for as long as
		// the enable stayed low. Each extra RTPS pushes another entry through
		// the screen-coordinate FIFO, so a game that projects three vertices and
		// reads SXY0/1/2 gets one corner carrying another vertex's position: the
		// polygon is drawn sheared, with a corner pulled towards the camera.
		// Measured on the board 2026-09-25 with the camera provably static (a
		// distant rock bit-identical across 60 frames): one crate was drawn in
		// four distinct shapes, two upright and two leaning, split 15/16/16/13 --
		// a coin toss every frame, which is what a race on the enable looks like.
		c2_we  <= 1'b0;
		c2_cmd <= 1'b0;
		rf_w0 = 1'b0; rf_w1 = 1'b0; rf_w2 = 1'b0;
		if (rst) begin
			rf_live <= 32'd0; rf_lo <= 32'd0; rf_hi <= 32'd0;
			s_a0 <= 32'd0; s_a1 <= 32'd0; s_ra <= 32'd0; s_sp <= 32'd0; s_t1 <= 32'd0;
			PC       <= 32'hBFC0_0000;
			HI <= 32'd0; LO <= 32'd0;
			SR       <= 32'h0040_0000;     // BEV set, interrupts off, kernel
			CAUSE    <= 32'd0;
			EPC      <= 32'd0;
			BADVADDR <= 32'd0;
			st       <= S_FETCH;
			req <= 1'b0; we <= 1'b0; be <= 4'd0; addr <= 32'd0; dout <= 32'd0;
			if_word <= 32'd0; if_fast <= 1'b0;
			br_pend <= 1'b0; in_slot <= 1'b0;
			ld_pend <= 1'b0; ld_reg <= 5'd0; ld_val <= 32'd0;
			ld_commit <= 1'b0; ld_creg <= 5'd0; ld_cval <= 32'd0;
			halted <= 1'b0;
			exc_take <= 1'b0; exc_code <= 5'd0; exc_bad <= 32'd0; exc_bd <= 1'b0;
			isc_inv <= 1'b0; isc_addr <= 32'd0;
			div_busy <= 1'b0; div_cnt <= 6'd0; mul_busy <= 1'b0; mul_cnt <= 2'd0; hl_wait <= 3'd0;
			wb_en <= 1'b0; wb_reg <= 5'd0; wb_val <= 32'd0;
			ir <= 32'd0;
			c2_we <= 1'b0; c2_ctl_r <= 1'b0; c2_reg_r <= 5'd0; c2_wdata <= 32'd0;
			c2_cmd <= 1'b0; c2_word <= 25'd0;
		end else if (ce) begin
			req <= 1'b0;
			we  <= 1'b0;
			isc_inv <= 1'b0;

			// The external lines are level-sensitive and always visible.
			CAUSE[15:10] <= irq;

			// A pending register write from the previous instruction lands now,
			// before this one's operands are read -- unless it was a load, in
			// which case it waited one instruction already and lands now too.
			if (wb_en && wb_reg != 5'd0) rf_w0 = 1'b1;
			wb_en <= 1'b0;

			// the multiplier runs on its own: 33 x 33 signed covers MULTU too
			if (mul_busy) begin
				mul_cnt <= mul_cnt - 2'd1;
				if (mul_cnt == 2'd1) begin mul_busy <= 1'b0; HI <= mul_p[63:32]; LO <= mul_p[31:0]; end
			end
			// the divider runs on its own
			if (div_busy) begin
				// restoring division, one bit per enable
				if ({div_r[30:0], div_q[31]} >= div_d) begin
					div_r <= {div_r[30:0], div_q[31]} - div_d;
					div_q <= {div_q[30:0], 1'b1};
				end else begin
					div_r <= {div_r[30:0], div_q[31]};
					div_q <= {div_q[30:0], 1'b0};
				end
				div_cnt <= div_cnt - 6'd1;
				if (div_cnt == 6'd1) begin
					div_busy <= 1'b0;
					LO <= div_neg_q ? -({div_q[30:0], ({div_r[30:0], div_q[31]} >= div_d)})
					                :  {div_q[30:0], ({div_r[30:0], div_q[31]} >= div_d)};
					HI <= div_neg_r ? -(({div_r[30:0], div_q[31]} >= div_d)
					                     ? {div_r[30:0], div_q[31]} - div_d
					                     : {div_r[30:0], div_q[31]})
					                :  (({div_r[30:0], div_q[31]} >= div_d)
					                     ? {div_r[30:0], div_q[31]} - div_d
					                     : {div_r[30:0], div_q[31]});
				end
			end

			case (st)
			// ---------------------------------------------------------------------------------
			S_FETCH: begin
					// The load delay slot ends here: whatever the last instruction
					// left pending is committed once the NEXT one has been fetched
					// -- i.e. after this instruction (the slot) has read its
					// operands, which happens in S_EXEC. So the commit is queued
					// through wb_*, which lands at the top of the next enable.
					// An instruction taken straight from the instruction cache
					// goes to execute with no wait state in between, and a write
					// queued here would not reach the register file until the end
					// of the cycle that reads it. On that path the loaded value
					// goes straight in. This is the whole load delay slot: get it
					// wrong and the instruction after the slot reads the register
					// as it was before the load.
					if (ld_commit) begin           // the slot has read; write now
						// ...unless the slot itself wrote this register: its
						// write (queued in wb_*, landing at the top of this
						// enable) is later in program order and wins on the
						// chip. `lw ra,36(sp)` followed by `jal` is exactly the
						// BIOS's shell: the stale ra overwrote the link, the
						// callee returned two levels up, and a function's
						// stack restore was skipped.
						if (!(wb_en && wb_reg == ld_creg)) begin
							if (fast_go) begin
								if (ld_creg != 5'd0) rf_w1 = 1'b1;
							end else begin
								wb_en  <= 1'b1;
								wb_reg <= ld_creg;
								wb_val <= ld_cval;
							end
						end
						ld_commit <= 1'b0;
					end
					if (ld_pend) begin             // this fetch is the slot's
						ld_commit <= 1'b1;
						ld_creg   <= ld_reg;
						ld_cval   <= ld_val;
						ld_pend   <= 1'b0;
					end

					if (irq_now && !in_slot) begin
						// Interrupts are taken between instructions, and never in
						// a delay slot: the branch would be lost.
						exc_code <= EXC_INT;
						exc_bd   <= 1'b0;
						st       <= S_EXC;
					end else if (PC[1:0] != 2'b00) begin
						exc_code <= EXC_ADEL;
						exc_bad  <= PC;
						exc_bd   <= 1'b0;
						st       <= S_EXC;
					end else if (!pc_fetchable) begin
						exc_code <= EXC_IBE;
						exc_bd   <= 1'b0;
						st       <= S_EXC;
					end else if (fetch_hit) begin
						// already in hand: no bus cycle, no wait state
						if_word <= fetch_word;
						if_fast <= 1'b1;
						st      <= S_EXEC;
					end else begin
						addr <= pc_phys;
						be   <= 4'b1111;
						req  <= 1'b1;
						st   <= S_FETCHW;
					end
				end

			S_FETCHW: st <= S_EXEC;         // the word lands on din now
			S_MEMW:   st <= S_MEMR;
			S_C2W:    if (!c2_busy) st <= S_FETCH;   // MFC2 re-executes once the GTE is done

			// ---------------------------------------------------------------------------------
			S_EXEC: begin
					// from the held line if it was there, off the bus if not
					if_fast <= 1'b0;
					ir <= insn;
					// Decode straight off the bus, so `ir` is for the debugger and
					// the exception path; the work below uses `din` through the
					// same wires by way of the continuous decode of `ir` -- which
					// would be a cycle stale. So: decode `din` here, explicitly.
					nst = S_FETCH;
					exec(insn);

					// One instruction per clock. The fetch cycle exists to walk the
					// load delay pipeline on, look for an interrupt, and get the
					// next instruction. When nothing is diverting the processor,
					// the next instruction is already in the cache and no
					// interrupt is waiting, all three can be done here and the
					// next instruction executes on the next clock. Anything
					// unusual -- a load, a store, an exception, a co-processor or
					// divider stall, a misaligned jump, an interrupt, a cache miss
					// -- goes the long way round, which is unchanged.
					if (nst == S_FETCH && !no_overlap && !irq_now
					    && (npc[1:0] == 2'b00) && fetch_hit) begin
						if (ld_commit) begin
							if (!(wb_en && wb_reg == ld_creg) && ld_creg != 5'd0)
								rf_w1 = 1'b1;
							ld_commit <= 1'b0;
						end
						if (ld_pend) begin
							ld_commit <= 1'b1;
							ld_creg   <= ld_reg;
							ld_cval   <= ld_val;
							ld_pend   <= 1'b0;
						end
						if_word <= fetch_word;
						if_fast <= 1'b1;
						st      <= S_EXEC;
					end else st <= nst;
				end

			// ---------------------------------------------------------------------------------
			S_MEM: begin
					// a store was issued last enable; nothing to collect, so the
					// next instruction can be taken here rather than in a cycle
					// of its own
					if (mem_go) begin
						if (ld_commit) begin
							if (!(wb_en && wb_reg == ld_creg) && ld_creg != 5'd0)
								rf_w1 = 1'b1;
							ld_commit <= 1'b0;
						end
						if (ld_pend) begin
							ld_commit <= 1'b1; ld_creg <= ld_reg; ld_cval <= ld_val; ld_pend <= 1'b0;
						end
						if_word <= fetch_word; if_fast <= 1'b1; st <= S_EXEC;
					end else st <= S_FETCH;
				end

			S_MEMR: begin
					// a load was issued last enable; the word is on din now
					case (op)
					6'h20: lv = sext8(byte_of(din, exc_bad[1:0]));           // LB
					6'h24: lv = {24'd0, byte_of(din, exc_bad[1:0])};          // LBU
					6'h21: lv = sext16(half_of(din, exc_bad[1]));             // LH
					6'h25: lv = {16'd0, half_of(din, exc_bad[1])};            // LHU
					6'h23: lv = din;                                          // LW
					// LWL/LWR merge into rt's CURRENT value -- and a compiler
					// issues the pair back to back, so the second one's rt is
					// the first one's result, still on its way to the register
					// file. The chip forwards it; without that the second half
					// merged into the stale register and every unaligned word
					// (an ISO directory's extents, say) came out wrong.
					6'h22: lv = lwl(b_ld, din, exc_bad[1:0]);                 // LWL
					6'h26: lv = lwr(b_ld, din, exc_bad[1:0]);                 // LWR
					default: lv = din;
					endcase
					if (op == 6'h32) begin                                    // LWC2
						ld_pend  <= 1'b0;
						c2_we    <= 1'b1;
						c2_ctl_r <= 1'b0;
						c2_reg_r <= rt;
						c2_wdata <= din;
						st <= S_FETCH;
					end else if (mem_go) begin
						// The fetch cycle would have moved this load from pending
						// to about-to-commit; do that here, with the value that
						// has just arrived, and take the next instruction too.
						// The delay slot still reads the register as it was: the
						// value does not reach the register file until the
						// instruction after it.
						if (ld_commit) begin
							if (!(wb_en && wb_reg == ld_creg) && ld_creg != 5'd0)
								rf_w1 = 1'b1;
						end
						ld_commit <= 1'b1; ld_creg <= rt; ld_cval <= lv;
						ld_pend   <= 1'b0;
						if_word <= fetch_word; if_fast <= 1'b1; st <= S_EXEC;
					end else begin
						ld_pend <= 1'b1;
						ld_reg  <= rt;
						ld_val  <= lv;
						st <= S_FETCH;
					end
				end

			// ---------------------------------------------------------------------------------
			S_DIV: begin
					// MFHI/MFLO after a divide wait for it. Nothing else does;
					// that is the interlock the real chip has. When it lands,
					// the move that was waiting finally happens.
					if (!hl_busy) begin
						case (hl_wait)
						3'd0: wreg(div_wait_rd, HI);
						3'd1: wreg(div_wait_rd, LO);
						3'd2: HI <= hl_a;
						3'd3: LO <= hl_a;
						3'd4, 3'd5: start_mul(hl_a, hl_b, !hl_wait[0]);
						default:    start_div(hl_a, hl_b, !hl_wait[0]);
						endcase
						st <= S_FETCH;
					end
				end

			// ---------------------------------------------------------------------------------
			S_EXC: begin
					// EPC is the faulting instruction, or the branch it was the
					// slot of; BD says which. SR's mode/enable pairs shift up.
					EPC   <= exc_bd ? PC - 32'd4 : PC;
					CAUSE <= {exc_bd, CAUSE[30], (exc_code == EXC_CPU) ? exc_ce : CAUSE[29:28], CAUSE[27:7], exc_code, 2'b00};
					if (exc_code == EXC_ADEL || exc_code == EXC_ADES)
						BADVADDR <= exc_bad;
					SR    <= {SR[31:6], SR[3:0], 2'b00};
					PC    <= SR[22] ? 32'hBFC0_0180 : 32'h8000_0080;
					br_pend <= 1'b0;
					in_slot <= 1'b0;
					// A load whose value is still in the delay pipeline has already
					// executed: it completes now, as on the chip, where the handler
					// sees the loaded register. Dropping it here left the BIOS's
					// `lw ra` unwritten whenever VBlank landed on the next fetch,
					// and the function returned through a stale ra.
					if (ld_commit && ld_creg != 5'd0) rf_w1 = 1'b1;
					if (ld_pend   && ld_reg  != 5'd0) rf_w2 = 1'b1;
					ld_pend <= 1'b0;
					ld_commit <= 1'b0;
					st <= S_FETCH;
				end
			default: st <= S_FETCH;
			endcase

			// The register file's writes, decided above, in the old statement order
			// so that the later one wins where two land on the same register.
			if (rf_w0) begin rf0[wb_reg]  <= wb_val;  rf_lo[wb_reg]  <= 1'b0; rf_hi[wb_reg]  <= 1'b0; rf_live[wb_reg]  <= 1'b1; end
			if (rf_w1) begin rf1[ld_creg] <= ld_cval; rf_lo[ld_creg] <= 1'b1; rf_hi[ld_creg] <= 1'b0; rf_live[ld_creg] <= 1'b1; end
			if (rf_w2) begin rf2[ld_reg]  <= ld_val;  rf_hi[ld_reg]  <= 1'b1; rf_live[ld_reg]  <= 1'b1; end
			if (rf_w0) shadow(wb_reg, wb_val);
			if (rf_w1) shadow(ld_creg, ld_cval);
			if (rf_w2) shadow(ld_reg, ld_val);
		end
	end

	// the debugger's copies of a0, a1, sp and ra
	task shadow;
		input [4:0]  n;
		input [31:0] v;
		begin
			if (n == 5'd4)  s_a0 <= v;
			if (n == 5'd9)  s_t1 <= v;
			if (n == 5'd5)  s_a1 <= v;
			if (n == 5'd29) s_sp <= v;
			if (n == 5'd31) s_ra <= v;
		end
	endtask

	// --- executing one instruction ---------------------------------------------------------
	// A task, so that the decode reads the word on the bus rather than a
	// register that is one enable stale. Everything it assigns is a register of
	// this module, assigned non-blocking, exactly as if it were inline.

	// =====================================================================================
	// The console's clock. This processor runs on the board's clock and spends its own
	// cycles (a load is four states here); what the PlayStation's R3000A would have spent
	// on each instruction is worked out alongside and handed to ps1_top, which lets the
	// processor go on only as fast as the console's 33.8688 MHz pays for it.
	//
	// The costs are the console's own, measured on hardware (ps1-tests cpu/access-time:
	// a load from RAM 5.2 cycles, BIOS ROM 7.6 / 12.9 / 24.9 for 8 / 16 / 32 bits, the
	// scratchpad 1, I/O 3-4, the CD-ROM 8 / 14 / 26, the SPU 18 / 18 / 39) and the
	// documented latencies (psx-spx: MULT 6 / 9 / 13 by the size of rs, DIV 36, each GTE
	// command its own count). Code runs from the 4 kB instruction cache (16-byte lines, a
	// valid bit a word, filled from the missed word to the end of its line, a cycle a word)
	// or, uncached (KSEG1), pays the region's word time for every instruction -- which is
	// why the BIOS crawls until it has copied itself to RAM.
	//
	// t_take pulses the clock after an instruction commits; t_cost is what it cost.
	// =====================================================================================
	reg  [16:0] ict [0:255];             // the instruction cache's tags (physical [28:12])
	reg  [3:0]  icv [0:255];             // ...and a valid bit for each of the line's words
	reg  [15:0] ctime;                   // console cycles spent so far (differences only)
	reg  [15:0] mdu_ready, gte_ready;    // when the multiplier / the GTE has its answer
	reg  [15:0] wq_free;                 // when the write buffer has put its last store into RAM
	integer     ii;
	initial for (ii = 0; ii < 256; ii = ii + 1) begin ict[ii] = 17'd0; icv[ii] = 4'd0; end

	function [6:0] load_wait;            // a load's cycles beyond the instruction's own
		input [31:0] ea; input [1:0] sz;     // sz: 0 byte, 1 half, 2 word
		reg [28:0] p;
		begin
			p = ea[28:0];
			if (ea[31:29] == 3'b111)                 load_wait = (sz == 2'd0) ? 7'd0 : 7'd1;     // cache control
			else if (p[28:23] == 6'd0)               load_wait = 7'd4;                            // RAM (8 MB of mirrors)
			else if (p[28:23] == 6'h3E)              load_wait = (sz == 2'd0) ? 7'd6  : (sz == 2'd1) ? 7'd13 : 7'd25;   // expansion 1
			else if (p[28:10] == 19'h7E000)          load_wait = 7'd0;                            // scratchpad
			else if (p[28:12] == 17'h1F801) begin                                                   // I/O
				// (calibrated on the board against cpu/access-time: our own access already costs
				// a little here, and the CD byte and the SPU word were that much over)
				if (p[11:4] == 8'h80)                load_wait = (sz == 2'd0) ? 7'd6  : (sz == 2'd1) ? 7'd13 : 7'd25;   // CD-ROM
				else if (p[11:10] == 2'b11)          load_wait = (sz == 2'd2) ? 7'd38 : 7'd17;    // SPU
				else if (p[11:4] == 8'h81)           load_wait = (sz == 2'd2) ? 7'd3  : 7'd2;     // GPU
				else if (p[11:4] == 8'h07 || p[11:7] == 5'b00001 || p[11:4] == 8'h82)
				                                     load_wait = (sz == 2'd2) ? 7'd2  : 7'd3;     // IRQ, DMA, MDEC
				else                                 load_wait = 7'd2;
			end
			else if (p[28:13] == 16'hFC01)           load_wait = (sz == 2'd0) ? 7'd10 : (sz == 2'd1) ? 7'd25 : 7'd55;  // expansion 2
			else if (p[28:21] == 8'hFD)              load_wait = (sz == 2'd0) ? 7'd6  : (sz == 2'd1) ? 7'd5  : 7'd9;   // expansion 3
			else if (p[28:19] == 10'h3F8)            load_wait = (sz == 2'd0) ? 7'd6  : (sz == 2'd1) ? 7'd12 : 7'd24;  // BIOS ROM
			else                                     load_wait = 7'd0;
		end
	endfunction
	function [5:0] gte_cycles;
		input [5:0] f;
		case (f)
		6'h01: gte_cycles = 15; 6'h06: gte_cycles = 8;  6'h0C: gte_cycles = 6;  6'h10: gte_cycles = 8;
		6'h11: gte_cycles = 8;  6'h12: gte_cycles = 8;  6'h13: gte_cycles = 19; 6'h14: gte_cycles = 13;
		6'h16: gte_cycles = 44; 6'h1B: gte_cycles = 17; 6'h1C: gte_cycles = 11; 6'h1E: gte_cycles = 14;
		6'h20: gte_cycles = 30; 6'h28: gte_cycles = 5;  6'h29: gte_cycles = 8;  6'h2A: gte_cycles = 17;
		6'h2D: gte_cycles = 5;  6'h2E: gte_cycles = 6;  6'h30: gte_cycles = 23; 6'h3D: gte_cycles = 5;
		6'h3E: gte_cycles = 5;  6'h3F: gte_cycles = 39; default: gte_cycles = 8;
		endcase
	endfunction
	function [5:0] until;                // cycles from `now` to `ready`, 0 if it has passed
		input [15:0] ready, now;
		reg [15:0] d;
		begin d = ready - now; until = (d[15] || d == 16'd0) ? 6'd0 : (d > 16'd63 ? 6'd63 : d[5:0]); end
	endfunction

	// (in two steps: the instruction, its PC and its load address are taken as it commits,
	// and its cost is worked out from those a clock later -- in one, the decode, the address
	// add and the region decode ran on from the instruction register and set the clock)
	reg        k_v;
	reg [31:0] k_w, k_pc, k_ea, k_rsv;
	always @(posedge clk) begin
		k_v <= ce && (st == S_EXEC);
		k_w <= insn; k_pc <= PC;
		k_rsv <= operand(insn[25:21]);
		k_ea  <= operand(insn[25:21]) + {{16{insn[15]}}, insn[15:0]};
	end
	always @(posedge clk) begin : console_clock
		reg [31:0] w, va, ea, rsv;
		reg [5:0]  o, f;
		reg [4:0]  rs_n;
		reg [8:0]  c;
		reg [7:0]  ln;
		reg [16:0] tg;
		reg        hit;
		t_take <= 1'b0;
		if (isc_inv) icv[isc_addr[11:4]] <= 4'd0;          // the BIOS's cache flush
		if (k_v) begin
			w = k_w; o = w[31:26]; f = w[5:0]; rs_n = w[25:21];
			rsv = k_rsv;
			ea  = k_ea;
			c = 9'd1;
			// the instruction's fetch
			ln = k_pc[11:4]; tg = k_pc[28:12];
			if (k_pc[31:29] == 3'b101) begin
				if (k_pc[28:23] == 6'd0)          c = c + 9'd4;
				else if (k_pc[28:19] == 10'h3F8)  c = c + 9'd24;
			end else begin
				hit = (ict[ln] == tg) && icv[ln][k_pc[3:2]];
				if (!hit) begin
					c = c + {7'd0, 2'd3 - k_pc[3:2]} + 9'd1;     // the words from here to the line's end
					ict[ln] <= tg;
					icv[ln] <= ((ict[ln] == tg) ? icv[ln] : 4'd0) | (4'b1111 << k_pc[3:2]);
				end
			end
			// a load that goes out on the bus waits for the write buffer to empty first: a store
			// to RAM keeps the bus ~7 cycles (ps1-tests dma/chain-looping: a load/add/store
			// loop is 16 cycles an iteration on the console, 11 without this)
			if ((o == 6'h20 || o == 6'h21 || o == 6'h22 || o == 6'h23 || o == 6'h24 || o == 6'h25 || o == 6'h26 || o == 6'h32)
			    && !(ea[31:29] != 3'b111 && ea[28:10] == 19'h7E000))
				c = c + until(wq_free, ctime);
			if ((o == 6'h28 || o == 6'h29 || o == 6'h2A || o == 6'h2B || o == 6'h2E || o == 6'h3A)
			    && ea[31:29] != 3'b111 && ea[28:23] == 6'd0)
				wq_free <= ((until(wq_free, ctime) != 6'd0) ? wq_free : ctime) + 16'd7;
			// its data
			case (o)
			6'h20, 6'h24:                       c = c + load_wait(ea, 2'd0);
			6'h21, 6'h25:                       c = c + load_wait(ea, 2'd1);
			6'h22, 6'h23, 6'h26, 6'h32:         c = c + load_wait(ea, 2'd2);
			default: ;
			endcase
			// the multiplier and the GTE answer when they are done
			if (o == 6'h00 && (f == 6'h10 || f == 6'h12))   c = c + until(mdu_ready, ctime);
			if (o == 6'h12 && (w[25] || w[25:21] == 5'd0 || w[25:21] == 5'd2)) c = c + until(gte_ready, ctime);
			if (o == 6'h3A)                                  c = c + until(gte_ready, ctime);
			if (o == 6'h00 && f == 6'h18)
				mdu_ready <= ctime + ((rsv[31:11] == 21'd0 || rsv[31:11] == 21'h1FFFFF) ? 16'd6
				                    : (rsv[31:20] == 12'd0 || rsv[31:20] == 12'hFFF) ? 16'd9 : 16'd13);
			if (o == 6'h00 && f == 6'h19)
				mdu_ready <= ctime + ((rsv[31:11] == 21'd0) ? 16'd6 : (rsv[31:20] == 12'd0) ? 16'd9 : 16'd13);
			if (o == 6'h00 && (f == 6'h1A || f == 6'h1B)) mdu_ready <= ctime + 16'd36;
			if (o == 6'h12 && w[25])                        gte_ready <= ctime + c[5:0] + {10'd0, gte_cycles(f)};
			ctime  <= ctime + {7'd0, c};
			t_cost <= (c > 9'd127) ? 7'd127 : c[6:0];
			t_take <= 1'b1;
		end
	end

	task exec;
		input [31:0] w;
		reg [5:0]  o; reg [4:0] s, t, d, h; reg [5:0] f;
		reg [31:0] va, vb, si, zi, ea_t, ph;
		reg [32:0] sm, df;
		reg        take;
		reg [31:0] link;
		begin
			o = w[31:26]; s = w[25:21]; t = w[20:16]; d = w[15:11]; h = w[10:6]; f = w[5:0];
			va = operand(s);
			vb = operand(t);
			si = {{16{w[15]}}, w[15:0]};
			zi = {16'd0, w[15:0]};
			ea_t = va + si;
			ph   = ea_t[31] ? {3'b000, ea_t[28:0]} : ea_t;
			sm = {va[31], va} + {vb[31], vb};
			df = {va[31], va} - {vb[31], vb};
			link = PC + 32'd8;

			// Where the next instruction comes from: the pending branch if this
			// was its slot, else straight on.
			if (br_pend) begin
				PC      <= br_target;
				br_pend <= 1'b0;
				in_slot <= 1'b0;
			end else begin
				PC      <= PC + 32'd4;
				in_slot <= 1'b0;
			end

			case (o)
			// --- SPECIAL -----------------------------------------------------------------
			6'h00: case (f)
				6'h00: wreg(d, vb << h);                          // SLL
				6'h02: wreg(d, vb >> h);                          // SRL
				6'h03: wreg(d, $signed(vb) >>> h);                // SRA
				6'h04: wreg(d, vb << va[4:0]);                    // SLLV
				6'h06: wreg(d, vb >> va[4:0]);                    // SRLV
				6'h07: wreg(d, $signed(vb) >>> va[4:0]);          // SRAV
				6'h08: begin br_pend <= 1'b1; br_target <= va; in_slot <= 1'b1; end   // JR
				6'h09: begin br_pend <= 1'b1; br_target <= va; in_slot <= 1'b1;
				             wreg(d, link); end                                       // JALR
				6'h0C: raise(EXC_SYS, 32'd0);                     // SYSCALL
				6'h0D: raise(EXC_BP, 32'd0);                      // BREAK
				// HI/LO: anything that touches them while a divide or multiply
				// is still landing parks in S_DIV until it has (the interlock
				// the real chip has for MFHI/MFLO; the rest is to keep the
				// pipelined multiply from landing on top of a later writer)
				6'h10: if (hl_busy) park(3'd0, d, va, vb); else wreg(d, HI);      // MFHI
				6'h11: if (hl_busy) park(3'd2, d, va, vb); else HI <= va;         // MTHI
				6'h12: if (hl_busy) park(3'd1, d, va, vb); else wreg(d, LO);      // MFLO
				6'h13: if (hl_busy) park(3'd3, d, va, vb); else LO <= va;         // MTLO
				6'h18: if (div_busy) park(3'd4, d, va, vb); else start_mul(va, vb, 1'b1);   // MULT
				6'h19: if (div_busy) park(3'd5, d, va, vb); else start_mul(va, vb, 1'b0);   // MULTU
				6'h1A: if (mul_busy) park(3'd6, d, va, vb); else start_div(va, vb, 1'b1);   // DIV
				6'h1B: if (mul_busy) park(3'd7, d, va, vb); else start_div(va, vb, 1'b0);   // DIVU
				6'h20: if (sm[32] != sm[31]) raise(EXC_OV, 32'd0); else wreg(d, sm[31:0]);  // ADD
				6'h21: wreg(d, sm[31:0]);                         // ADDU
				6'h22: if (df[32] != df[31]) raise(EXC_OV, 32'd0); else wreg(d, df[31:0]);  // SUB
				6'h23: wreg(d, df[31:0]);                         // SUBU
				6'h24: wreg(d, va & vb);                          // AND
				6'h25: wreg(d, va | vb);                          // OR
				6'h26: wreg(d, va ^ vb);                          // XOR
				6'h27: wreg(d, ~(va | vb));                       // NOR
				6'h2A: wreg(d, {31'd0, $signed(va) < $signed(vb)});  // SLT
				6'h2B: wreg(d, {31'd0, va < vb});                 // SLTU
				default: raise(EXC_RI, 32'd0);
				endcase

			// --- REGIMM: BLTZ/BGEZ and the linking pair ----------------------------------
			6'h01: begin
					take = t[0] ? !va[31] : va[31];
					if (t[4]) wreg(5'd31, link);
					if (take) begin br_pend <= 1'b1; br_target <= PC + 32'd4 + (si << 2); end
					in_slot <= 1'b1;
				end

			6'h02: begin br_pend <= 1'b1; br_target <= {PC[31:28] , w[25:0], 2'b00}; in_slot <= 1'b1; end          // J
			6'h03: begin br_pend <= 1'b1; br_target <= {PC[31:28] , w[25:0], 2'b00}; in_slot <= 1'b1;
			             wreg(5'd31, link); end                                                                       // JAL
			6'h04: begin if (va == vb)         begin br_pend <= 1'b1; br_target <= PC + 32'd4 + (si << 2); end in_slot <= 1'b1; end  // BEQ
			6'h05: begin if (va != vb)         begin br_pend <= 1'b1; br_target <= PC + 32'd4 + (si << 2); end in_slot <= 1'b1; end  // BNE
			6'h06: begin if (va[31] || va == 0) begin br_pend <= 1'b1; br_target <= PC + 32'd4 + (si << 2); end in_slot <= 1'b1; end // BLEZ
			6'h07: begin if (!va[31] && va != 0) begin br_pend <= 1'b1; br_target <= PC + 32'd4 + (si << 2); end in_slot <= 1'b1; end // BGTZ

			6'h08: begin sm = {va[31], va} + {si[31], si};
			             if (sm[32] != sm[31]) raise(EXC_OV, 32'd0); else wreg(t, sm[31:0]); end   // ADDI
			6'h09: wreg(t, va + si);                                          // ADDIU
			6'h0A: wreg(t, {31'd0, $signed(va) < $signed(si)});               // SLTI
			6'h0B: wreg(t, {31'd0, va < si});                                 // SLTIU
			6'h0C: wreg(t, va & zi);                                          // ANDI
			6'h0D: wreg(t, va | zi);                                          // ORI
			6'h0E: wreg(t, va ^ zi);                                          // XORI
			6'h0F: wreg(t, {w[15:0], 16'd0});                                 // LUI

			// --- COP0 --------------------------------------------------------------------------
			6'h10: begin
					if (w[25]) begin                               // RFE
						SR <= {SR[31:4], SR[5:2]};
					end else case (w[25:21])
					5'h00: case (d)                                // MFC0
						5'd8:  wreg(t, BADVADDR);
						5'd12: wreg(t, SR);
						5'd13: wreg(t, CAUSE);
						5'd14: wreg(t, EPC);
						5'd15: wreg(t, PRID);
						default: wreg(t, 32'd0);
						endcase
					5'h04: case (d)                                // MTC0
						5'd12: SR    <= vb;
						5'd13: CAUSE[9:8] <= vb[9:8];              // only the soft bits
						5'd14: EPC   <= vb;
						default: ;
						endcase
					default: ;
					endcase
				end

			// --- COP2: the GTE ------------------------------------------------------------------
			// Every access waits for a command in flight -- a read because the
			// answer is not there yet, a write or a new command because the GTE
			// would drop it (it takes nothing while it runs) and the program
			// would go on with stale registers. The chip stalls on all of them;
			// only stalling the reads left writes to vanish, which the BIOS's
			// intro turned into an overflow it could not resolve.
			// The hold must also keep the branch bookkeeping: the top of this enable
			// already consumed a pending branch (cleared br_pend and in_slot on the
			// way to PC <= target), and if this instruction is that branch's delay
			// slot, re-executing it later without the branch would fall straight
			// through -- which is how a wait in a delay slot became a jump to
			// address 1. Reassigning them here keeps their pre-enable values.
			// --- the coprocessors' usable bits (SR 28-31): an instruction for one that is
			// switched off is a coprocessor-unusable exception, with its number in Cause;
			// COP1 and COP3 do not exist, so switched on their instructions do nothing
			// (ps1-tests cpu/cop -- it was a reserved-instruction exception either way)
			6'h11, 6'h31, 6'h39: if (!SR[29]) raise_cu(2'd1);
			6'h13, 6'h33, 6'h3B: if (!SR[31]) raise_cu(2'd3);
			6'h30, 6'h38:        if (!SR[28]) raise_cu(2'd0);

			6'h12: if (!SR[30]) raise_cu(2'd2); else begin
					if (c2_busy) begin PC <= PC; br_pend <= br_pend; in_slot <= in_slot; nst = S_C2W; end
					else if (w[25]) begin                          // a GTE command
						c2_cmd  <= 1'b1;
						c2_word <= w[24:0];
					end else case (w[25:21])
					5'h00, 5'h02: wreg(t, c2_rdata);               // MFC2 / CFC2
					5'h04, 5'h06: begin                            // MTC2 / CTC2
						c2_we    <= 1'b1;
						c2_ctl_r <= w[22];
						c2_reg_r <= d;
						c2_wdata <= vb;
					end
					default: ;
					endcase
				end
			6'h32: if (!SR[30]) raise_cu(2'd2); else if (c2_busy) begin PC <= PC; br_pend <= br_pend; in_slot <= in_slot; nst = S_C2W; end
			       else load(ph, 4'b1111, ea_t);                   // LWC2: the value lands in the GTE
			6'h3A: if (!SR[30]) raise_cu(2'd2); else if (c2_busy) begin PC <= PC; br_pend <= br_pend; in_slot <= in_slot; nst = S_C2W; end
			       else store({ph[31:2], 2'b00}, 4'b1111, c2_rdata);   // SWC2: store a GTE data register

			// --- loads: issue now, collect in S_MEMR ------------------------------------
			// A load says which bytes it wants, as a store does. The value is
			// picked out of the word here either way, but a device with a FIFO
			// behind a byte register (the CD-ROM's RDDATA) has to know whether
			// it was that byte or a neighbour the program asked for: with every
			// load claiming all four, polling the drive's status popped a byte
			// of sector data each time, and the game's sectors came in shifted.
			6'h20, 6'h24: load(ph, 4'b0001 << ea_t[1:0], ea_t);                          // LB/LBU
			6'h21, 6'h25: if (ea_t[0]) raise(EXC_ADEL, ea_t); else load(ph, ea_t[1] ? 4'b1100 : 4'b0011, ea_t);   // LH/LHU
			6'h23:        if (ea_t[1:0] != 2'b00) raise(EXC_ADEL, ea_t); else load(ph, 4'b1111, ea_t);  // LW
			6'h22, 6'h26: load(ph, 4'b1111, ea_t);                                       // LWL/LWR

			// --- stores: one enable, data and enables on the bus --------------------------
			// The bus carries the whole register, shifted to the byte's lane -- not the byte
			// copied into every lane: a 32-bit I/O register that ignores the byte enables
			// takes all of it, as on the chip (ps1-tests cpu/io-access-bitwidth: SB of
			// 12345678h to DMA0's address leaves 345678h). Memory and the byte-wide devices
			// see the same byte in the same lane either way.
			6'h28: store({ph[31:2], 2'b00}, 4'b0001 << ea_t[1:0], vb << {ea_t[1:0], 3'b000});    // SB
			6'h29: if (ea_t[0]) raise(EXC_ADES, ea_t);
			       else store({ph[31:2], 2'b00}, ea_t[1] ? 4'b1100 : 4'b0011, vb << {ea_t[1], 4'b0000});  // SH
			6'h2B: if (ea_t[1:0] != 2'b00) raise(EXC_ADES, ea_t);
			       else store({ph[31:2], 2'b00}, 4'b1111, vb);                              // SW
			6'h2A: store({ph[31:2], 2'b00}, swl_be(ea_t[1:0]), swl_data(vb, ea_t[1:0]));   // SWL
			6'h2E: store({ph[31:2], 2'b00}, swr_be(ea_t[1:0]), swr_data(vb, ea_t[1:0]));   // SWR

			default: raise(EXC_RI, 32'd0);
			endcase
		end
	endtask

	// --- helpers used by exec ------------------------------------------------------------
	task wreg;
		input [4:0]  r;
		input [31:0] v;
		begin
			// Lands at the top of the next enable, after this instruction is
			// done and before the next reads anything. Register zero stays zero.
			wb_en  <= 1'b1;
			wb_reg <= r;
			wb_val <= v;
		end
	endtask

	task raise_cu;
		input [1:0] n;
		begin exc_ce <= n; raise(EXC_CPU, 32'd0); end
	endtask
	task raise;
		input [4:0]  code;
		input [31:0] bad;
		begin
			exc_code <= code;
			exc_bad  <= bad;
			exc_bd   <= in_slot;     // as it was when this instruction ran
			// undo the PC advance: EPC wants THIS instruction
			PC       <= PC;
			br_pend  <= br_pend;
			wb_en    <= 1'b0;
			nst = S_EXC;
		end
	endtask

	task load;
		input [31:0] ph;
		input [3:0]  b;
		input [31:0] v;         // the virtual address, kept for the byte lane
		begin
			// SR.IsC: reads while isolated return whatever the cache holds,
			// which here is nothing; the BIOS only isolates to WRITE.
			addr    <= {ph[31:2], 2'b00};
			be      <= b;
			req     <= 1'b1;
			exc_bad <= v;
			nst = S_MEMW;
		end
	endtask

	task store;
		input [31:0] ph;
		input [3:0]  b;
		input [31:0] v;
		begin
			// Isolated (SR.IsC): a store goes to the CACHE, not to memory. That is
			// how a program invalidates code it has just written -- isolate, store
			// over the addresses, un-isolate. We dropped the store and did nothing
			// else, so the instruction cache kept the OLD code. The processor then
			// executed stale words, took a reserved-instruction exception, jumped
			// to the handler, fetched the stale handler and looped there for ever:
			// pc stuck at 80000080 with cause 10 and EPC pointing at the vector.
			if (!SR[16]) begin
				addr <= ph;
				be   <= b;
				dout <= v;
				we   <= 1'b1;
				req  <= 1'b1;
			end else begin
				isc_inv  <= 1'b1;         // drop the line this address maps to
				isc_addr <= ph;
			end
			nst = S_MEM;
		end
	endtask

	task park;
		input [2:0]  what;
		input [4:0]  rd;
		input [31:0] x, y;
		begin
			nst = S_DIV; hl_wait <= what; div_wait_rd <= rd; hl_a <= x; hl_b <= y;
		end
	endtask

	task start_mul;
		input [31:0] x, y;
		input        sgn;
		begin
			mul_a <= x; mul_b <= y; mul_sgn <= sgn; mul_cnt <= 2'd2; mul_busy <= 1'b1;
		end
	endtask

	task start_div;
		input [31:0] n;
		input [31:0] dd;
		input        sgn;
		begin
			if (dd == 32'd0) begin
				// Divide by zero does not trap on this chip; it answers this.
				HI <= n;
				LO <= sgn ? (n[31] ? 32'd1 : 32'hFFFF_FFFF) : 32'hFFFF_FFFF;
			end else if (sgn && n == 32'h8000_0000 && dd == 32'hFFFF_FFFF) begin
				HI <= 32'd0;
				LO <= 32'h8000_0000;
			end else begin
				div_signed <= sgn;
				div_neg_q  <= sgn && (n[31] ^ dd[31]);
				div_neg_r  <= sgn && n[31];
				div_q      <= (sgn && n[31])  ? -n  : n;
				div_d      <= (sgn && dd[31]) ? -dd : dd;
				div_r      <= 32'd0;
				div_cnt    <= 6'd32;
				div_busy   <= 1'b1;
			end
		end
	endtask

	// --- pure functions ----------------------------------------------------------------------
	function [63:0] mul_s_of;
		input [31:0] x, y;
		mul_s_of = $signed(x) * $signed(y);
	endfunction

	function [63:0] mul_u_of;
		input [31:0] x, y;
		mul_u_of = x * y;
	endfunction

	function [7:0] byte_of;
		input [31:0] w;
		input [1:0]  k;
		byte_of = w[k*8 +: 8];
	endfunction

	function [15:0] half_of;
		input [31:0] w;
		input        k;
		half_of = k ? w[31:16] : w[15:0];
	endfunction

	function [31:0] sext8;
		input [7:0] v;
		sext8 = {{24{v[7]}}, v};
	endfunction

	function [31:0] sext16;
		input [15:0] v;
		sext16 = {{16{v[15]}}, v};
	endfunction

	// Little-endian unaligned loads, the console's way round.
	function [31:0] lwl;
		input [31:0] r, w;
		input [1:0]  k;
		case (k)
		2'd0: lwl = {w[7:0],   r[23:0]};
		2'd1: lwl = {w[15:0],  r[15:0]};
		2'd2: lwl = {w[23:0],  r[7:0]};
		default: lwl = w;
		endcase
	endfunction

	function [31:0] lwr;
		input [31:0] r, w;
		input [1:0]  k;
		case (k)
		2'd0: lwr = w;
		2'd1: lwr = {r[31:24], w[31:8]};
		2'd2: lwr = {r[31:16], w[31:16]};
		default: lwr = {r[31:8], w[31:24]};
		endcase
	endfunction

	// SWL/SWR as a masked word write: which bytes, and the word to take them from.
	function [3:0] swl_be;
		input [1:0] k;
		case (k)
		2'd0: swl_be = 4'b0001;
		2'd1: swl_be = 4'b0011;
		2'd2: swl_be = 4'b0111;
		default: swl_be = 4'b1111;
		endcase
	endfunction

	function [31:0] swl_data;
		input [31:0] v;
		input [1:0]  k;
		case (k)
		2'd0: swl_data = {24'd0, v[31:24]};
		2'd1: swl_data = {16'd0, v[31:16]};
		2'd2: swl_data = {8'd0,  v[31:8]};
		default: swl_data = v;
		endcase
	endfunction

	function [3:0] swr_be;
		input [1:0] k;
		case (k)
		2'd0: swr_be = 4'b1111;
		2'd1: swr_be = 4'b1110;
		2'd2: swr_be = 4'b1100;
		default: swr_be = 4'b1000;
		endcase
	endfunction

	function [31:0] swr_data;
		input [31:0] v;
		input [1:0]  k;
		case (k)
		2'd0: swr_data = v;
		2'd1: swr_data = {v[23:0], 8'd0};
		2'd2: swr_data = {v[15:0], 16'd0};
		default: swr_data = {v[7:0], 24'd0};
		endcase
	endfunction

`undef RF_RD
endmodule

`default_nettype wire
