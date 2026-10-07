//////////////////////////////////////////////////////////////////////////////////
// ps1_gte.v - the PlayStation's GTE (COP2), the fixed-point geometry engine.
//
// It hangs off the R3000's coprocessor-2 port. Register moves land in one of two
// banks -- data (MTC2/MFC2) and control (CTC2/CFC2) -- and a COP2 command runs
// an operation over some cycles, holding `busy` so the CPU stalls where the real
// pair interlocks. The maths is checked against tools/ps1/gte.py by tb_gte.
//
// --- one datapath, many commands ---------------------------------------------------
//
// Every command is a short chain of the same few steps: a 3x3 matrix times a
// vector plus a translation (into the 44-bit accumulators, then shifted and
// saturated into IR1..3), the colour times IR, the depth-cue interpolation, the
// colour push, the perspective divide. RTPS is one chain, NCDS another, and the
// triple forms just run their chain three times. So the engine is a sequencer:
// the command word picks a chain, `step` walks it a cycle at a time, and each
// step calls one task that does one thing -- each lined up with one function in
// the Python model, which is what makes the sweep worth running.
//
// --- why every multiply has a clock of its own ------------------------------------------
//
// The first version did a whole matrix multiply, or the entire divide, in one
// clock and missed timing by 64 ns. One row per clock brought that to 6 ns, and
// the report showed why: the row's operand mux, three cascaded multipliers, the
// 64-bit add and the overflow compare are one 26 ns path against a 20 ns clock.
// So now each multiply-bearing step is three: latch the operands, multiply into
// product registers, then add/check/saturate. Nothing combinational spans a
// multiplier and an adder. A command takes more cycles than the real chip's;
// the CPU is stalled on `busy` either way, and a sweep says the answers are
// the same to the bit.
//
// Flags are set inline from the values as they are computed; no function has a
// side effect, and nothing writes a register from two places.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_gte (
	input  wire [3:0]  gte_old,   // 0: read-back widths, 1: 44-bit wrap, 2: MAC0 saturates, 3: IR off MAC32
	input  wire        clk,
	input  wire        rst,

	input  wire        we,          // MTC2/CTC2/LWC2
	input  wire        ctl,         // control bank rather than data
	input  wire [4:0]  reg_i,       // the register READ (rdata), and whether control: ctl
	input  wire [4:0]  wreg_i,      // the register WRITTEN (with we/wdata), and whether control
	input  wire        wctl,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,       // combinational read of reg_i/ctl

	input  wire        cmd,         // start a command
	input  wire [24:0] word,
	output wire        busy,
	// A debug snapshot, nothing copied: armed, the GTE stops at the (skip+1)-th command after
	// arming BEFORE running it (busy: the processor waits at its next GTE instruction), and the
	// registers are read where they are, through the read port, as MFC2/CFC2 would see them
	// (idx [5] control, [4:0] the register); `go` runs the command and the GTE stops again
	// when it is done; disarming lets the game go on. tools/ps1/gtesnap.py replays it through
	// tools/ps1/gte.py. (A first version copied all 64 registers aside: 2,000 LUTs and 2,000
	// flip-flops, and the console no longer fitted the chip.)
	input  wire        snap_arm,
	input  wire        snap_go,
	input  wire [15:0] snap_skip,
	input  wire [6:0]  snap_idx,
	output wire [31:0] snap_data,
	output reg  [24:0] snap_word,
	output wire [1:0]  snap_state,   // {stopped after, stopped before}
	output wire        wr_ok,        // a register write taken this clock (for the write trace in ps1_top)
	output wire        snap_busy     // the snapshot has taken a command (the trace stops)
);
	reg [31:0] d [0:31];
	reg [31:0] c [0:31];
	integer k;
	reg [15:0] snap_n; reg [1:0] sst;           // 0 counting, 1 stopped before, 2 running it, 3 stopped after
	wire snap_hold = (sst == 2'd1) || (sst == 2'd3);
	assign snap_state = {sst == 2'd3, sst == 2'd1};
	wire [4:0] rri  = snap_hold ? snap_idx[4:0] : reg_i;    // the read port: the snapshot's while stopped
	wire       rctl = snap_hold ? snap_idx[5]   : ctl;
	assign snap_data = rdata;
	assign snap_busy = (sst != 2'd0);


	// --- sign helpers ----------------------------------------------------------
	function signed [63:0] sx16; input [15:0] v; sx16 = {{48{v[15]}}, v}; endfunction
	function signed [63:0] sx32; input [31:0] v; sx32 = {{32{v[31]}}, v}; endfunction
	// The products are 16 x 16 (or 16 x a short unsigned), so they are made
	// that size and sign-extended afterwards. Written as 64 x 64 of extended
	// operands, the synthesiser built each one as four cascaded DSP slices
	// feeding a 64-bit carry chain, 20 ns from the op register to p0, the
	// slowest path in the whole build.
	function signed [63:0] m16; input [15:0] a, b; reg signed [31:0] p;
		begin p = $signed(a) * $signed(b); m16 = {{32{p[31]}}, p}; end endfunction
	function signed [63:0] m16u17; input [15:0] a; input [16:0] u; reg signed [34:0] p;
		begin p = $signed(a) * $signed({1'b0, u}); m16u17 = {{29{p[34]}}, p}; end endfunction
	function signed [63:0] m16u18; input [15:0] a; input [17:0] u; reg signed [35:0] p;
		begin p = $signed(a) * $signed({1'b0, u}); m16u18 = {{28{p[35]}}, p}; end endfunction

	function [5:0] leadcount; input [31:0] v; reg top; integer i; reg [5:0] n; reg done;
		begin top = v[31]; n = 0; done = 0;
			for (i = 31; i >= 0; i = i - 1)
				if (!done) begin if (v[i] == top) n = n + 1; else done = 1; end
			leadcount = n;
		end
	endfunction

	function [4:0] lz16; input [15:0] v; integer i; reg [4:0] n; reg done;
		begin n = 0; done = 0;
			for (i = 15; i >= 0; i = i - 1)
				if (!done) begin if (v[i] == 1'b0) n = n + 1; else done = 1; end
			lz16 = n;
		end
	endfunction

	// the UNR seed table: 257 entries, precomputed here rather than divided
	// in logic -- a combinational divider was the single deepest path in the
	// first build, 64 ns of it.
	function [8:0] unr_rom; input [8:0] i;
		case (i)
		9'd0: unr_rom = 9'd255;
		9'd1: unr_rom = 9'd253;
		9'd2: unr_rom = 9'd251;
		9'd3: unr_rom = 9'd249;
		9'd4: unr_rom = 9'd247;
		9'd5: unr_rom = 9'd245;
		9'd6: unr_rom = 9'd243;
		9'd7: unr_rom = 9'd241;
		9'd8: unr_rom = 9'd239;
		9'd9: unr_rom = 9'd238;
		9'd10: unr_rom = 9'd236;
		9'd11: unr_rom = 9'd234;
		9'd12: unr_rom = 9'd232;
		9'd13: unr_rom = 9'd230;
		9'd14: unr_rom = 9'd228;
		9'd15: unr_rom = 9'd227;
		9'd16: unr_rom = 9'd225;
		9'd17: unr_rom = 9'd223;
		9'd18: unr_rom = 9'd221;
		9'd19: unr_rom = 9'd220;
		9'd20: unr_rom = 9'd218;
		9'd21: unr_rom = 9'd216;
		9'd22: unr_rom = 9'd214;
		9'd23: unr_rom = 9'd213;
		9'd24: unr_rom = 9'd211;
		9'd25: unr_rom = 9'd209;
		9'd26: unr_rom = 9'd208;
		9'd27: unr_rom = 9'd206;
		9'd28: unr_rom = 9'd205;
		9'd29: unr_rom = 9'd203;
		9'd30: unr_rom = 9'd201;
		9'd31: unr_rom = 9'd200;
		9'd32: unr_rom = 9'd198;
		9'd33: unr_rom = 9'd197;
		9'd34: unr_rom = 9'd195;
		9'd35: unr_rom = 9'd193;
		9'd36: unr_rom = 9'd192;
		9'd37: unr_rom = 9'd190;
		9'd38: unr_rom = 9'd189;
		9'd39: unr_rom = 9'd187;
		9'd40: unr_rom = 9'd186;
		9'd41: unr_rom = 9'd184;
		9'd42: unr_rom = 9'd183;
		9'd43: unr_rom = 9'd181;
		9'd44: unr_rom = 9'd180;
		9'd45: unr_rom = 9'd178;
		9'd46: unr_rom = 9'd177;
		9'd47: unr_rom = 9'd176;
		9'd48: unr_rom = 9'd174;
		9'd49: unr_rom = 9'd173;
		9'd50: unr_rom = 9'd171;
		9'd51: unr_rom = 9'd170;
		9'd52: unr_rom = 9'd169;
		9'd53: unr_rom = 9'd167;
		9'd54: unr_rom = 9'd166;
		9'd55: unr_rom = 9'd164;
		9'd56: unr_rom = 9'd163;
		9'd57: unr_rom = 9'd162;
		9'd58: unr_rom = 9'd160;
		9'd59: unr_rom = 9'd159;
		9'd60: unr_rom = 9'd158;
		9'd61: unr_rom = 9'd156;
		9'd62: unr_rom = 9'd155;
		9'd63: unr_rom = 9'd154;
		9'd64: unr_rom = 9'd153;
		9'd65: unr_rom = 9'd151;
		9'd66: unr_rom = 9'd150;
		9'd67: unr_rom = 9'd149;
		9'd68: unr_rom = 9'd148;
		9'd69: unr_rom = 9'd146;
		9'd70: unr_rom = 9'd145;
		9'd71: unr_rom = 9'd144;
		9'd72: unr_rom = 9'd143;
		9'd73: unr_rom = 9'd141;
		9'd74: unr_rom = 9'd140;
		9'd75: unr_rom = 9'd139;
		9'd76: unr_rom = 9'd138;
		9'd77: unr_rom = 9'd137;
		9'd78: unr_rom = 9'd135;
		9'd79: unr_rom = 9'd134;
		9'd80: unr_rom = 9'd133;
		9'd81: unr_rom = 9'd132;
		9'd82: unr_rom = 9'd131;
		9'd83: unr_rom = 9'd130;
		9'd84: unr_rom = 9'd129;
		9'd85: unr_rom = 9'd127;
		9'd86: unr_rom = 9'd126;
		9'd87: unr_rom = 9'd125;
		9'd88: unr_rom = 9'd124;
		9'd89: unr_rom = 9'd123;
		9'd90: unr_rom = 9'd122;
		9'd91: unr_rom = 9'd121;
		9'd92: unr_rom = 9'd120;
		9'd93: unr_rom = 9'd119;
		9'd94: unr_rom = 9'd117;
		9'd95: unr_rom = 9'd116;
		9'd96: unr_rom = 9'd115;
		9'd97: unr_rom = 9'd114;
		9'd98: unr_rom = 9'd113;
		9'd99: unr_rom = 9'd112;
		9'd100: unr_rom = 9'd111;
		9'd101: unr_rom = 9'd110;
		9'd102: unr_rom = 9'd109;
		9'd103: unr_rom = 9'd108;
		9'd104: unr_rom = 9'd107;
		9'd105: unr_rom = 9'd106;
		9'd106: unr_rom = 9'd105;
		9'd107: unr_rom = 9'd104;
		9'd108: unr_rom = 9'd103;
		9'd109: unr_rom = 9'd102;
		9'd110: unr_rom = 9'd101;
		9'd111: unr_rom = 9'd100;
		9'd112: unr_rom = 9'd99;
		9'd113: unr_rom = 9'd98;
		9'd114: unr_rom = 9'd97;
		9'd115: unr_rom = 9'd96;
		9'd116: unr_rom = 9'd95;
		9'd117: unr_rom = 9'd94;
		9'd118: unr_rom = 9'd93;
		9'd119: unr_rom = 9'd93;
		9'd120: unr_rom = 9'd92;
		9'd121: unr_rom = 9'd91;
		9'd122: unr_rom = 9'd90;
		9'd123: unr_rom = 9'd89;
		9'd124: unr_rom = 9'd88;
		9'd125: unr_rom = 9'd87;
		9'd126: unr_rom = 9'd86;
		9'd127: unr_rom = 9'd85;
		9'd128: unr_rom = 9'd84;
		9'd129: unr_rom = 9'd83;
		9'd130: unr_rom = 9'd83;
		9'd131: unr_rom = 9'd82;
		9'd132: unr_rom = 9'd81;
		9'd133: unr_rom = 9'd80;
		9'd134: unr_rom = 9'd79;
		9'd135: unr_rom = 9'd78;
		9'd136: unr_rom = 9'd77;
		9'd137: unr_rom = 9'd77;
		9'd138: unr_rom = 9'd76;
		9'd139: unr_rom = 9'd75;
		9'd140: unr_rom = 9'd74;
		9'd141: unr_rom = 9'd73;
		9'd142: unr_rom = 9'd72;
		9'd143: unr_rom = 9'd72;
		9'd144: unr_rom = 9'd71;
		9'd145: unr_rom = 9'd70;
		9'd146: unr_rom = 9'd69;
		9'd147: unr_rom = 9'd68;
		9'd148: unr_rom = 9'd67;
		9'd149: unr_rom = 9'd67;
		9'd150: unr_rom = 9'd66;
		9'd151: unr_rom = 9'd65;
		9'd152: unr_rom = 9'd64;
		9'd153: unr_rom = 9'd63;
		9'd154: unr_rom = 9'd63;
		9'd155: unr_rom = 9'd62;
		9'd156: unr_rom = 9'd61;
		9'd157: unr_rom = 9'd60;
		9'd158: unr_rom = 9'd60;
		9'd159: unr_rom = 9'd59;
		9'd160: unr_rom = 9'd58;
		9'd161: unr_rom = 9'd57;
		9'd162: unr_rom = 9'd57;
		9'd163: unr_rom = 9'd56;
		9'd164: unr_rom = 9'd55;
		9'd165: unr_rom = 9'd54;
		9'd166: unr_rom = 9'd54;
		9'd167: unr_rom = 9'd53;
		9'd168: unr_rom = 9'd52;
		9'd169: unr_rom = 9'd51;
		9'd170: unr_rom = 9'd51;
		9'd171: unr_rom = 9'd50;
		9'd172: unr_rom = 9'd49;
		9'd173: unr_rom = 9'd49;
		9'd174: unr_rom = 9'd48;
		9'd175: unr_rom = 9'd47;
		9'd176: unr_rom = 9'd46;
		9'd177: unr_rom = 9'd46;
		9'd178: unr_rom = 9'd45;
		9'd179: unr_rom = 9'd44;
		9'd180: unr_rom = 9'd44;
		9'd181: unr_rom = 9'd43;
		9'd182: unr_rom = 9'd42;
		9'd183: unr_rom = 9'd42;
		9'd184: unr_rom = 9'd41;
		9'd185: unr_rom = 9'd40;
		9'd186: unr_rom = 9'd40;
		9'd187: unr_rom = 9'd39;
		9'd188: unr_rom = 9'd38;
		9'd189: unr_rom = 9'd38;
		9'd190: unr_rom = 9'd37;
		9'd191: unr_rom = 9'd36;
		9'd192: unr_rom = 9'd36;
		9'd193: unr_rom = 9'd35;
		9'd194: unr_rom = 9'd34;
		9'd195: unr_rom = 9'd34;
		9'd196: unr_rom = 9'd33;
		9'd197: unr_rom = 9'd32;
		9'd198: unr_rom = 9'd32;
		9'd199: unr_rom = 9'd31;
		9'd200: unr_rom = 9'd30;
		9'd201: unr_rom = 9'd30;
		9'd202: unr_rom = 9'd29;
		9'd203: unr_rom = 9'd29;
		9'd204: unr_rom = 9'd28;
		9'd205: unr_rom = 9'd27;
		9'd206: unr_rom = 9'd27;
		9'd207: unr_rom = 9'd26;
		9'd208: unr_rom = 9'd25;
		9'd209: unr_rom = 9'd25;
		9'd210: unr_rom = 9'd24;
		9'd211: unr_rom = 9'd24;
		9'd212: unr_rom = 9'd23;
		9'd213: unr_rom = 9'd22;
		9'd214: unr_rom = 9'd22;
		9'd215: unr_rom = 9'd21;
		9'd216: unr_rom = 9'd21;
		9'd217: unr_rom = 9'd20;
		9'd218: unr_rom = 9'd20;
		9'd219: unr_rom = 9'd19;
		9'd220: unr_rom = 9'd18;
		9'd221: unr_rom = 9'd18;
		9'd222: unr_rom = 9'd17;
		9'd223: unr_rom = 9'd17;
		9'd224: unr_rom = 9'd16;
		9'd225: unr_rom = 9'd15;
		9'd226: unr_rom = 9'd15;
		9'd227: unr_rom = 9'd14;
		9'd228: unr_rom = 9'd14;
		9'd229: unr_rom = 9'd13;
		9'd230: unr_rom = 9'd13;
		9'd231: unr_rom = 9'd12;
		9'd232: unr_rom = 9'd12;
		9'd233: unr_rom = 9'd11;
		9'd234: unr_rom = 9'd10;
		9'd235: unr_rom = 9'd10;
		9'd236: unr_rom = 9'd9;
		9'd237: unr_rom = 9'd9;
		9'd238: unr_rom = 9'd8;
		9'd239: unr_rom = 9'd8;
		9'd240: unr_rom = 9'd7;
		9'd241: unr_rom = 9'd7;
		9'd242: unr_rom = 9'd6;
		9'd243: unr_rom = 9'd6;
		9'd244: unr_rom = 9'd5;
		9'd245: unr_rom = 9'd5;
		9'd246: unr_rom = 9'd4;
		9'd247: unr_rom = 9'd4;
		9'd248: unr_rom = 9'd3;
		9'd249: unr_rom = 9'd3;
		9'd250: unr_rom = 9'd2;
		9'd251: unr_rom = 9'd2;
		9'd252: unr_rom = 9'd1;
		9'd253: unr_rom = 9'd1;
		9'd254: unr_rom = 9'd0;
		9'd255: unr_rom = 9'd0;
		9'd256: unr_rom = 9'd0;
		default: unr_rom = 9'd0;
		endcase
	endfunction

	// --- combinational register read ------------------------------------------
	reg signed [63:0] rd1, rd2, rd3;
	reg [4:0] c5r, c5g, c5b;
	function [4:0] clamp5; input signed [63:0] v;
		clamp5 = (v < 0) ? 5'd0 : (v > 31) ? 5'd31 : v[4:0];
	endfunction
	always @(*) begin
		rd1 = sx16(d[9][15:0]) >>> 7; rd2 = sx16(d[10][15:0]) >>> 7; rd3 = sx16(d[11][15:0]) >>> 7;
		c5r = clamp5(rd1); c5g = clamp5(rd2); c5b = clamp5(rd3);
		// What a register READS BACK is not what was written to it. The chip keeps
		// the 16-bit ones as 16 bits and hands them back sign- or zero-extended;
		// we handed back all 32 bits as written. Checked against a real machine
		// (JaCzekanski's gte-fuzz log): a game that reads IR1 back got 00008000
		// from us where the chip gives ffff8000, which is -32768 read as +32768.
		if (rctl) begin
			if (rri == 31) begin
				rdata = c[31] & 32'h7FFFF000;
				if (rdata & 32'h7F87E000) rdata = rdata | 32'h80000000;
			end else if (gte_old[0]) rdata = c[rri];
			else case (rri)
				// RT33, L33, LB3, H, DQA, ZSF3, ZSF4: sixteen bits, sign extended.
				// H is unsigned and still comes back sign extended -- a quirk of
				// the chip, and the fuzz log confirms it.
				5'd4, 5'd12, 5'd20, 5'd26, 5'd27, 5'd29, 5'd30:
					rdata = {{16{c[rri][15]}}, c[rri][15:0]};
				default: rdata = c[rri];
			endcase
		end else case (rri)
			5'd1, 5'd3, 5'd5,                          // VZ0..VZ2
			5'd8, 5'd9, 5'd10, 5'd11:                  // IR0..IR3
				rdata = gte_old[0] ? d[rri] : {{16{d[rri][15]}}, d[rri][15:0]};
			5'd7,                                      // OTZ
			5'd16, 5'd17, 5'd18, 5'd19:                // SZ0..SZ3: unsigned
				rdata = gte_old[0] ? d[rri] : {16'd0, d[rri][15:0]};
			5'd15:        rdata = d[14];
			5'd28, 5'd29: rdata = {17'd0, c5b, c5g, c5r};
			default:      rdata = d[rri];
		endcase
	end

	// ==========================================================================
	// the sequencer
	// ==========================================================================
	reg        run;
	reg [5:0]  op;
	reg        sf, lm;
	reg [1:0]  mx, vx, cv;
	reg [5:0]  step;
	reg [1:0]  vi;
	// Busy from the clock the command arrives, not from the clock after: the
	// processor issues an instruction a clock and checks busy as it goes, so
	// with `run` alone the instruction right behind a command slipped through
	// the one-clock gap -- and a write in that gap (`we && !run` below) was
	// dropped. A game's square root wrote LZCS there, read a stale LZCR, and
	// overflowed.
	assign busy = run || cmd || snap_hold || (sst == 2'd2);
	assign wr_ok = we && !run && !snap_hold;          // (the engine's write condition, below)   // (no clock free between the run and the stop after it)
	// A command is taken on the EDGE of `cmd`, never on the level, so nothing can
	// ever make the sequencer run the same one twice (see r3000.v). The register
	// WRITE line stays level-sensitive: the processor asserts it on consecutive
	// clocks for back-to-back MTC2/CTC2, which is how a game loads a matrix, and
	// an edge there drops the second of every pair -- tried, and it put objects
	// warping across the whole screen.
	reg cmd_d;
	always @(posedge clk) begin
		if (rst) cmd_d <= 1'b0; else cmd_d <= cmd;
	end
	wire cmd_go = cmd && !cmd_d;
	wire [24:0] cw = (sst == 2'd1) ? snap_word : word;     // (the snapshot's command, when it lets it run)
	wire [4:0] shamt = sf ? 5'd12 : 5'd0;

	reg signed [63:0] macw0, macw1, macw2;     // unshifted accumulators between steps
	reg ir3q;                                  // RTPS's IR3 flag, ORed over an RTPT
	reg signed [63:0] vl0, vl1, vl2;           // the vector, latched at row 0
	// operand and product registers: every multiply reads from here and writes here
	reg signed [63:0] e0r, e1r, e2r, x0r, x1r, x2r, trr;
	reg signed [63:0] p0, p1, p2, p3, p4, p5;
	reg signed [63:0] m0, m1, m2;              // the 32-bit MAC values IR saturates off
	reg [63:0] pd;                             // the divide's unsigned product
	reg [4:0]  dz; reg [16:0] ddn; reg [31:0] du, dd1, dd2; reg [16:0] q; reg dov;
	reg [63:0] asum;
	reg [15:0] zsf;                            // AVSZ's ZSF3/ZSF4, latched with the sum

	localparam signed [63:0] P43 = 64'sh0000_0800_0000_0000;
	localparam signed [63:0] N43 = -64'sh0000_0800_0000_0000;

	function signed [63:0] sat_ir; input signed [63:0] v; input lmf;
		sat_ir = (v > 64'sh7FFF) ? 64'sh7FFF : (v < (lmf ? 64'sd0 : -64'sd32768)) ? (lmf ? 64'sd0 : -64'sd32768) : v;
	endfunction
	function ir_of; input signed [63:0] v; input lmf;
		ir_of = (v > 64'sh7FFF) || (v < (lmf ? 64'sd0 : -64'sd32768));
	endfunction
	function signed [63:0] clip; input signed [63:0] v; input signed [63:0] lo; input signed [63:0] hi;
		clip = (v < lo) ? lo : (v > hi) ? hi : v;
	endfunction

	function signed [63:0] mel; input [4:0] base; input [1:0] r; input [1:0] col;
		reg [3:0] idx;
		begin
			idx = r * 3 + col;
			case (idx)
			4'd0: mel = sx16(c[base+0][15:0]);
			4'd1: mel = sx16(c[base+0][31:16]);
			4'd2: mel = sx16(c[base+1][15:0]);
			4'd3: mel = sx16(c[base+1][31:16]);
			4'd4: mel = sx16(c[base+2][15:0]);
			4'd5: mel = sx16(c[base+2][31:16]);
			4'd6: mel = sx16(c[base+3][15:0]);
			4'd7: mel = sx16(c[base+3][31:16]);
			default: mel = sx16(c[base+4][15:0]);
			endcase
		end
	endfunction

	// --- scratch ----------------------------------------------------------------------
	reg signed [63:0] acc, fst, sh, iv, ir0v, s0, s1, s2, i0, i1, i2, a0, a1, a2;
	reg signed [63:0] chk, sxv, syv, dq, nc, av, c0v, c1v, c2v;
	reg [8:0]  ridx;
	reg [1:0]  rr;

	// ---- matrix*vector, one row = three steps: select, multiply, finish ------------
	// mstep 0..8: row = mstep/3, phase = mstep%3
	task mvt_step;
		input [4:0] mbase; input [2:0] vs; input [1:0] ts; input lmf; input [5:0] ms;
		begin
			rr = (ms < 3) ? 2'd0 : (ms < 6) ? 2'd1 : 2'd2;
			case (ms % 3)
			// --- select the operands into registers ---
			6'd0: begin
				if (rr == 2'd0) begin
					case (vs)
					3'd0: begin x0r <= sx16(d[0][15:0]); x1r <= sx16(d[0][31:16]); x2r <= sx16(d[1][15:0]);
					            vl0 <= sx16(d[0][15:0]); vl1 <= sx16(d[0][31:16]); vl2 <= sx16(d[1][15:0]); end
					3'd1: begin x0r <= sx16(d[2][15:0]); x1r <= sx16(d[2][31:16]); x2r <= sx16(d[3][15:0]);
					            vl0 <= sx16(d[2][15:0]); vl1 <= sx16(d[2][31:16]); vl2 <= sx16(d[3][15:0]); end
					3'd2: begin x0r <= sx16(d[4][15:0]); x1r <= sx16(d[4][31:16]); x2r <= sx16(d[5][15:0]);
					            vl0 <= sx16(d[4][15:0]); vl1 <= sx16(d[4][31:16]); vl2 <= sx16(d[5][15:0]); end
					default: begin x0r <= sx16(d[9][15:0]); x1r <= sx16(d[10][15:0]); x2r <= sx16(d[11][15:0]);
					            vl0 <= sx16(d[9][15:0]); vl1 <= sx16(d[10][15:0]); vl2 <= sx16(d[11][15:0]); end
					endcase
				end else begin
					x0r <= vl0; x1r <= vl1; x2r <= vl2;
				end
				if (mbase == 5'd31) begin
					case (rr)
					2'd0: begin e0r <= -sx16({8'd0, d[6][7:0]} << 4); e1r <= sx16({8'd0, d[6][7:0]} << 4); e2r <= sx16(d[8][15:0]); end
					2'd1: begin e0r <= sx16(c[2][15:0]); e1r <= sx16(c[2][15:0]); e2r <= sx16(c[2][15:0]); end
					default: begin e0r <= sx16(c[4][15:0]); e1r <= sx16(c[4][15:0]); e2r <= sx16(c[4][15:0]); end
					endcase
				end else begin
					e0r <= mel(mbase, rr, 2'd0); e1r <= mel(mbase, rr, 2'd1); e2r <= mel(mbase, rr, 2'd2);
				end
				case (ts)
				2'd0: trr <= (rr == 0) ? sx32(c[5])  : (rr == 1) ? sx32(c[6])  : sx32(c[7]);
				2'd1: trr <= (rr == 0) ? sx32(c[13]) : (rr == 1) ? sx32(c[14]) : sx32(c[15]);
				2'd2: trr <= (rr == 0) ? sx32(c[21]) : (rr == 1) ? sx32(c[22]) : sx32(c[23]);
				default: trr <= 0;
				endcase
			end
			// --- the three products ---
			6'd1: begin p0 <= e0r * x0r; p1 <= e1r * x1r; p2 <= e2r * x2r; end
			// --- add, check, shift, saturate, write ---
			default: begin
				if (ts == 2'd2) begin
					fst = (trr <<< 12) + p0;
					if (fst >= P43) c[31][30 - rr] <= 1'b1; if (fst < N43) c[31][27 - rr] <= 1'b1;
					if (ir_of(fst >>> shamt, 1'b0)) c[31][24 - rr] <= 1'b1;
					acc = p1 + p2;
				end else begin
					acc = (trr <<< 12) + p0 + p1 + p2;
				end
				if (acc >= P43) c[31][30 - rr] <= 1'b1; if (acc < N43) c[31][27 - rr] <= 1'b1;
				// The chip's accumulator is 44 BITS and wraps; ours kept the whole
				// 64-bit sum. Past 44 bits the two part company completely: the
				// chip carries on from the wrapped value, so its IR and screen
				// coordinates saturate to the OPPOSITE end from ours. Checked
				// against a real machine (JaCzekanski's gte-fuzz), where our
				// screen coordinate was +1023 for its -1024 and the other way
				// about. The flags above are judged on the true sum, as they are
				// on the chip; the arithmetic below carries on from the wrap.
				if (!gte_old[1]) acc = {{20{acc[43]}}, acc[43:0]};
				sh = acc >>> shamt;
				// IR comes off the 32-bit MAC REGISTER, not the wider accumulator.
				// With the shift off (sf=0) the accumulator runs past 32 bits, and
				// saturating from the wide value put IR at the opposite end from
				// the chip -- every remaining projection difference had sf=0.
				if (ir_of(gte_old[3] ? sh : sx32(sh[31:0]), lmf)) c[31][24 - rr] <= 1'b1;
				iv = sat_ir(gte_old[3] ? sh : sx32(sh[31:0]), lmf);
				case (rr)
				2'd0: begin macw0 <= sh; d[25] <= sh[31:0]; d[9]  <= {16'd0, iv[15:0]}; end
				2'd1: begin macw1 <= sh; d[26] <= sh[31:0]; d[10] <= {16'd0, iv[15:0]}; end
				default: begin macw2 <= sh; d[27] <= sh[31:0]; d[11] <= {16'd0, iv[15:0]}; end
				endcase
			end
			endcase
		end
	endtask

	// MAC = (RGB * IR) << 4  (one multiply each, straight into macw)
	task rgb_ir; begin
		macw0 <= (m16({8'd0, d[6][7:0]}, d[9][15:0]))  <<< 4;
		macw1 <= (m16({8'd0, d[6][15:8]}, d[10][15:0])) <<< 4;
		macw2 <= (m16({8'd0, d[6][23:16]}, d[11][15:0])) <<< 4;
	end endtask

	// depth cue in three: differences into IR (lm=0); products; add + check
	task dcue_step; input [1:0] sub; begin
		case (sub)
		2'd0: begin
			a0 = (sx32(c[21]) <<< 12) - macw0; a1 = (sx32(c[22]) <<< 12) - macw1; a2 = (sx32(c[23]) <<< 12) - macw2;
			if (a0 >= P43) c[31][30] <= 1'b1; if (a0 < N43) c[31][27] <= 1'b1;
			if (a1 >= P43) c[31][29] <= 1'b1; if (a1 < N43) c[31][26] <= 1'b1;
			if (a2 >= P43) c[31][28] <= 1'b1; if (a2 < N43) c[31][25] <= 1'b1;
			s0 = a0 >>> shamt; s1 = a1 >>> shamt; s2 = a2 >>> shamt;
			if (ir_of(s0, 1'b0)) c[31][24] <= 1'b1;
			if (ir_of(s1, 1'b0)) c[31][23] <= 1'b1;
			if (ir_of(s2, 1'b0)) c[31][22] <= 1'b1;
			i0 = sat_ir(s0, 1'b0); i1 = sat_ir(s1, 1'b0); i2 = sat_ir(s2, 1'b0);
			d[9] <= {16'd0, i0[15:0]}; d[10] <= {16'd0, i1[15:0]}; d[11] <= {16'd0, i2[15:0]};
		end
		2'd1: begin
			ir0v = sx16(d[8][15:0]);
			p0 <= m16(d[9][15:0], ir0v[15:0]); p1 <= m16(d[10][15:0], ir0v[15:0]); p2 <= m16(d[11][15:0], ir0v[15:0]);
		end
		default: begin
			a0 = p0 + macw0; a1 = p1 + macw1; a2 = p2 + macw2;
			if (a0 >= P43) c[31][30] <= 1'b1; if (a0 < N43) c[31][27] <= 1'b1;
			if (a1 >= P43) c[31][29] <= 1'b1; if (a1 < N43) c[31][26] <= 1'b1;
			if (a2 >= P43) c[31][28] <= 1'b1; if (a2 < N43) c[31][25] <= 1'b1;
			macw0 <= a0; macw1 <= a1; macw2 <= a2;
		end
		endcase
	end endtask

	// MAC >> shift -> MAC, IR (lm), colour fifo gets MAC/16 (no multiply)
	task mac_color; input lmf; begin
		s0 = macw0 >>> shamt; s1 = macw1 >>> shamt; s2 = macw2 >>> shamt;
		d[25] <= s0[31:0]; d[26] <= s1[31:0]; d[27] <= s2[31:0];
		// IR and the colour both come off the 32-bit MAC REGISTER, not the wider
		// accumulator -- the same thing that was wrong in the transform path, and
		// again every failing case had the shift off (sf=0), where the
		// accumulator runs past 32 bits.
		m0 = gte_old[3] ? s0 : sx32(s0[31:0]);
		m1 = gte_old[3] ? s1 : sx32(s1[31:0]);
		m2 = gte_old[3] ? s2 : sx32(s2[31:0]);
		if (ir_of(m0, lmf)) c[31][24] <= 1'b1;
		if (ir_of(m1, lmf)) c[31][23] <= 1'b1;
		if (ir_of(m2, lmf)) c[31][22] <= 1'b1;
		i0 = sat_ir(m0, lmf); i1 = sat_ir(m1, lmf); i2 = sat_ir(m2, lmf);
		d[9] <= {16'd0, i0[15:0]}; d[10] <= {16'd0, i1[15:0]}; d[11] <= {16'd0, i2[15:0]};
		push_color(m0 >>> 4, m1 >>> 4, m2 >>> 4);
	end endtask

	task push_color; input signed [63:0] r; input signed [63:0] g; input signed [63:0] b; begin
		c0v = clip(r, 0, 255); c1v = clip(g, 0, 255); c2v = clip(b, 0, 255);
		if (c0v != r) c[31][21] <= 1'b1;
		if (c1v != g) c[31][20] <= 1'b1;
		if (c2v != b) c[31][19] <= 1'b1;
		d[20] <= d[21]; d[21] <= d[22];
		d[22] <= {d[6][31:24], c2v[7:0], c1v[7:0], c0v[7:0]};
	end endtask

	// RTPS: SZ push with the IR3 quirk (no multiply)
	task rtp_sz; begin
		chk = macw2 >>> (5'd12 - shamt);
		ir3q <= ir3q | ir_of(chk, 1'b0);
		c[31][22] <= ir3q | ir_of(chk, 1'b0);
		s2 = clip(chk, 0, 65535);
		if (s2 != chk) c[31][18] <= 1'b1;
		d[16] <= d[17]; d[17] <= d[18]; d[18] <= d[19];
		d[19] <= {16'd0, s2[15:0]};
	end endtask

	// the divide: eight steps, one multiply OR one add a step
	task div_step; input [2:0] sub; begin
		case (sub)
		3'd0: begin
			dov <= ({1'b0, c[26][15:0]} >= ({1'b0, d[19][15:0]} << 1));
			dz  <= lz16(d[19][15:0]);
			ddn <= {1'b0, d[19][15:0]} << lz16(d[19][15:0]);
		end
		3'd1: begin
			ridx = ({1'b0, ddn[14:0]} + 16'h40) >> 7;   // 0..256
			du <= {23'd0, unr_rom(ridx)} + 32'h101;
		end
		3'd2: pd  <= ddn * du;
		3'd3: dd1 <= (32'h2000080 - pd[31:0]) >> 8;
		3'd4: pd  <= dd1 * du;
		3'd5: dd2 <= (32'h0000080 + pd[31:0]) >> 8;
		3'd6: pd  <= ({48'd0, c[26][15:0]} << dz) * dd2;
		default: begin
			if (dov) begin q <= 17'h1FFFF; c[31][17] <= 1'b1; end
			else q <= ((pd + 64'h8000) >> 16) > 64'h1FFFF ? 17'h1FFFF : ((pd + 64'h8000) >> 16);
		end
		endcase
	end endtask

	// RTPS: project -- products, then add/clip/push
	task rtp_proj; input sub; begin
		if (sub == 1'b0) begin
			p0 <= m16u17(d[9][15:0], q);
			p1 <= m16u17(d[10][15:0], q);
		end else begin
			sxv = sx32(c[24]) + p0; syv = sx32(c[25]) + p1;
			if (sxv > 64'sh7FFFFFFF) c[31][16] <= 1'b1; if (sxv < -64'sh80000000) c[31][15] <= 1'b1;
			if (syv > 64'sh7FFFFFFF) c[31][16] <= 1'b1; if (syv < -64'sh80000000) c[31][15] <= 1'b1;
			d[24] <= syv[31:0];
			// The screen coordinate comes off a MAC0 that SATURATES, not one that
			// wraps: IR * (H/SZ) overflows 32 bits routinely, and on the chip a
			// positive overflow still projects to the right-hand edge. Truncating
			// first sent it to the opposite edge instead -- which is a vertex
			// thrown across the screen, and a model torn into streaks.
			s0 = (!gte_old[2] && sxv > 64'sh7FFF_FFFF) ? 64'sh7FFF : (!gte_old[2] && sxv < -64'sh8000_0000) ? -64'sh8000 : (sx32(sxv[31:0]) >>> 16);
			s1 = (!gte_old[2] && syv > 64'sh7FFF_FFFF) ? 64'sh7FFF : (!gte_old[2] && syv < -64'sh8000_0000) ? -64'sh8000 : (sx32(syv[31:0]) >>> 16);
			i0 = clip(s0, -1024, 1023); i1 = clip(s1, -1024, 1023);
			if (i0 != s0) c[31][14] <= 1'b1;
			if (i1 != s1) c[31][13] <= 1'b1;
			d[12] <= d[13]; d[13] <= d[14];
			d[14] <= {i1[15:0], i0[15:0]}; d[15] <= {i1[15:0], i0[15:0]};
		end
	end endtask

	// RTPS: depth queue -- product, then add/clip
	task rtp_dq; input sub; begin
		if (sub == 1'b0) p0 <= m16u17(c[27][15:0], q);
		else begin
			dq = sx32(c[28]) + p0;
			if (dq > 64'sh7FFFFFFF) c[31][16] <= 1'b1; if (dq < -64'sh80000000) c[31][15] <= 1'b1;
			d[24] <= dq[31:0];
			s0 = sx32(dq[31:0]) >>> 12;
			i0 = clip(s0, 0, 4096);
			if (i0 != s0) c[31][12] <= 1'b1;
			d[8] <= {16'd0, i0[15:0]};
		end
	end endtask

	// NCLIP in three: three products, three products, the sum
	task nclip_step; input [1:0] sub; begin
		case (sub)
		2'd0: begin p0 <= m16(d[12][15:0], d[13][31:16]);
		            p1 <= m16(d[13][15:0], d[14][31:16]);
		            p2 <= m16(d[14][15:0], d[12][31:16]); end
		2'd1: begin p3 <= m16(d[12][15:0], d[14][31:16]);
		            p4 <= m16(d[13][15:0], d[12][31:16]);
		            p5 <= m16(d[14][15:0], d[13][31:16]); end
		default: begin
			nc = p0 + p1 + p2 - p3 - p4 - p5;
			if (nc > 64'sh7FFFFFFF) c[31][16] <= 1'b1; if (nc < -64'sh80000000) c[31][15] <= 1'b1;
			d[24] <= nc[31:0];
		end
		endcase
	end endtask

	// OP in three
	task op_step; input [1:0] sub; begin
		case (sub)
		2'd0: begin p0 <= m16(d[11][15:0], c[2][15:0]);
		            p1 <= m16(d[9][15:0], c[4][15:0]);
		            p2 <= m16(d[10][15:0], c[0][15:0]); end
		2'd1: begin p3 <= m16(d[10][15:0], c[4][15:0]);
		            p4 <= m16(d[11][15:0], c[0][15:0]);
		            p5 <= m16(d[9][15:0], c[2][15:0]); end
		default: begin
			a0 = p0 - p3; a1 = p1 - p4; a2 = p2 - p5;
			if (a0 >= P43) c[31][30] <= 1'b1; if (a0 < N43) c[31][27] <= 1'b1;
			if (a1 >= P43) c[31][29] <= 1'b1; if (a1 < N43) c[31][26] <= 1'b1;
			if (a2 >= P43) c[31][28] <= 1'b1; if (a2 < N43) c[31][25] <= 1'b1;
			s0 = a0 >>> shamt; s1 = a1 >>> shamt; s2 = a2 >>> shamt;
			d[25] <= s0[31:0]; d[26] <= s1[31:0]; d[27] <= s2[31:0];
			if (ir_of(s0, lm)) c[31][24] <= 1'b1;
			if (ir_of(s1, lm)) c[31][23] <= 1'b1;
			if (ir_of(s2, lm)) c[31][22] <= 1'b1;
			i0 = sat_ir(s0, lm); i1 = sat_ir(s1, lm); i2 = sat_ir(s2, lm);
			d[9] <= {16'd0, i0[15:0]}; d[10] <= {16'd0, i1[15:0]}; d[11] <= {16'd0, i2[15:0]};
		end
		endcase
	end endtask

	// --- the debug snapshot (see the ports) ----------------------------------------
	wire snap_take  = snap_arm && (sst == 2'd0) && cmd_go && !run && (snap_n == snap_skip);
	wire snap_start = (sst == 2'd1) && snap_go;          // the command held back, run now
	always @(posedge clk) begin
		if (rst || !snap_arm) begin
			snap_n <= 16'd0; sst <= 2'd0;
		end else case (sst)
			2'd0: if (snap_take) begin snap_word <= word; sst <= 2'd1; end
			      else if (cmd_go && !run) snap_n <= snap_n + 16'd1;
			2'd1: if (snap_go) sst <= 2'd2;
			2'd2: if (!run) sst <= 2'd3;                      // (run rose with the step into 2)
			default: ;
		endcase
	end

	// ==========================================================================
	// the clocked engine
	// ==========================================================================
	wire [4:0] mvbase = (mx == 2'd0) ? 5'd0 : (mx == 2'd1) ? 5'd8 : (mx == 2'd2) ? 5'd16 : 5'd31;

	always @(posedge clk) begin
		if (rst) begin
			for (k = 0; k < 32; k = k + 1) begin d[k] <= 0; c[k] <= 0; end
			run <= 1'b0; step <= 0; vi <= 0; ir3q <= 0;
		end else if (we && !run && !snap_hold) begin
			if (wctl) c[wreg_i] <= wdata;
			else case (wreg_i)
				5'd7:  d[7]  <= {16'd0, wdata[15:0]};
				5'd15: begin d[12] <= d[13]; d[13] <= d[14]; d[14] <= wdata; d[15] <= wdata; end
				5'd28: begin d[28] <= {17'd0, wdata[14:0]};
				             d[9]  <= {17'd0, wdata[4:0],   7'd0};
				             d[10] <= {17'd0, wdata[9:5],   7'd0};
				             d[11] <= {17'd0, wdata[14:10], 7'd0}; end
				5'd29, 5'd31: ;
				5'd30: begin d[30] <= wdata; d[31] <= {26'd0, leadcount(wdata)}; end
				default: d[wreg_i] <= wdata;
			endcase
		end else if ((cmd_go && !run && !snap_hold && !snap_take) || snap_start) begin
			op <= cw[5:0]; sf <= cw[19]; lm <= cw[10];
			mx <= cw[18:17]; vx <= cw[16:15]; cv <= cw[14:13];
			step <= 0; vi <= 0; c[31] <= 32'd0; ir3q <= 1'b0; run <= 1'b1;
		end else if (run) begin
			step <= step + 6'd1;
			case (op)
			// --- RTPS / RTPT: MVT 0-8, SZ 9, DIV 10-17, PROJ 18-19, DQ 20-21 -----
			6'h01, 6'h30: begin
				if (step < 9) mvt_step(5'd0, {1'b0, vi}, 2'd0, lm, step);
				else if (step == 9) rtp_sz;
				else if (step < 18) div_step(step - 6'd10);
				else if (step == 18) rtp_proj(1'b0);
				else if (step == 19) begin
					rtp_proj(1'b1);
					if (!(op == 6'h01 || vi == 2'd2)) begin vi <= vi + 2'd1; step <= 0; end
				end
				else if (step == 20) rtp_dq(1'b0);
				else begin rtp_dq(1'b1); run <= 1'b0; end
			end
			// --- NCLIP ------------------------------------------------------------------
			6'h06: begin
				if (step < 2) nclip_step(step[1:0]);
				else begin nclip_step(2'd2); run <= 1'b0; end
			end
			// --- OP ---------------------------------------------------------------------
			6'h0C: begin
				if (step < 2) op_step(step[1:0]);
				else begin op_step(2'd2); run <= 1'b0; end
			end
			// --- DPCS / DPCT: load 0, cue 1-3, out 4 ------------------------------------
			6'h10, 6'h2A: begin
				if (step == 0) begin
					if (op == 6'h2A) begin
						macw0 <= sx16({8'd0, d[20][7:0]})   <<< 16;
						macw1 <= sx16({8'd0, d[20][15:8]})  <<< 16;
						macw2 <= sx16({8'd0, d[20][23:16]}) <<< 16;
					end else begin
						macw0 <= sx16({8'd0, d[6][7:0]})   <<< 16;
						macw1 <= sx16({8'd0, d[6][15:8]})  <<< 16;
						macw2 <= sx16({8'd0, d[6][23:16]}) <<< 16;
					end
				end
				else if (step < 4) dcue_step(step - 6'd1);
				else begin
					mac_color(lm);
					if (op == 6'h2A && vi != 2'd2) begin vi <= vi + 2'd1; step <= 0; end
					else run <= 1'b0;
				end
			end
			// --- INTPL ---------------------------------------------------------------------
			6'h11: begin
				if (step == 0) begin macw0 <= sx16(d[9][15:0]) <<< 12; macw1 <= sx16(d[10][15:0]) <<< 12; macw2 <= sx16(d[11][15:0]) <<< 12; end
				else if (step < 4) dcue_step(step - 6'd1);
				else begin mac_color(lm); run <= 1'b0; end
			end
			// --- MVMVA ---------------------------------------------------------------------
			6'h12: begin
				if (step < 8) mvt_step(mvbase, {1'b0, vx}, cv, lm, step);
				else begin mvt_step(mvbase, {1'b0, vx}, cv, lm, 6'd8); run <= 1'b0; end
			end
			// --- NCDS / NCDT: light 0-8, colour 9-17, rgb 18, cue 19-21, out 22 -------
			6'h13, 6'h16: begin
				if (step < 9) mvt_step(5'd8, {1'b0, vi}, 2'd3, lm, step);
				else if (step < 18) mvt_step(5'd16, 3'd3, 2'd1, lm, step - 6'd9);
				else if (step == 18) rgb_ir;
				else if (step < 22) dcue_step(step - 6'd19);
				else begin
					mac_color(lm);
					if (op == 6'h16 && vi != 2'd2) begin vi <= vi + 2'd1; step <= 0; end
					else run <= 1'b0;
				end
			end
			// --- CDP: colour 0-8, rgb 9, cue 10-12, out 13 --------------------------------
			6'h14: begin
				if (step < 9) mvt_step(5'd16, 3'd3, 2'd1, lm, step);
				else if (step == 9) rgb_ir;
				else if (step < 13) dcue_step(step - 6'd10);
				else begin mac_color(lm); run <= 1'b0; end
			end
			// --- NCCS / NCCT: light 0-8, colour 9-17, rgb 18, out 19 -----------------------
			6'h1B, 6'h3F: begin
				if (step < 9) mvt_step(5'd8, {1'b0, vi}, 2'd3, lm, step);
				else if (step < 18) mvt_step(5'd16, 3'd3, 2'd1, lm, step - 6'd9);
				else if (step == 18) rgb_ir;
				else begin
					mac_color(lm);
					if (op == 6'h3F && vi != 2'd2) begin vi <= vi + 2'd1; step <= 0; end
					else run <= 1'b0;
				end
			end
			// --- CC: colour 0-8, rgb 9, out 10 ----------------------------------------------
			6'h1C: begin
				if (step < 9) mvt_step(5'd16, 3'd3, 2'd1, lm, step);
				else if (step == 9) rgb_ir;
				else begin mac_color(lm); run <= 1'b0; end
			end
			// --- NCS / NCT: light 0-8, colour 9-17, push 18 ----------------------------------
			6'h1E, 6'h20: begin
				if (step < 9) mvt_step(5'd8, {1'b0, vi}, 2'd3, lm, step);
				else if (step < 18) mvt_step(5'd16, 3'd3, 2'd1, lm, step - 6'd9);
				else begin
					push_color(sx32(d[25]) >>> 4, sx32(d[26]) >>> 4, sx32(d[27]) >>> 4);
					if (op == 6'h20 && vi != 2'd2) begin vi <= vi + 2'd1; step <= 0; end
					else run <= 1'b0;
				end
			end
			// --- SQR: products, then shift/saturate ------------------------------------------
			6'h28: begin
				if (step == 0) begin
					p0 <= m16(d[9][15:0], d[9][15:0]);
					p1 <= m16(d[10][15:0], d[10][15:0]);
					p2 <= m16(d[11][15:0], d[11][15:0]);
				end else begin
					s0 = p0 >>> shamt; s1 = p1 >>> shamt; s2 = p2 >>> shamt;
					d[25] <= s0[31:0]; d[26] <= s1[31:0]; d[27] <= s2[31:0];
					if (ir_of(s0, lm)) c[31][24] <= 1'b1;
					if (ir_of(s1, lm)) c[31][23] <= 1'b1;
					if (ir_of(s2, lm)) c[31][22] <= 1'b1;
					i0 = sat_ir(s0, lm); i1 = sat_ir(s1, lm); i2 = sat_ir(s2, lm);
					d[9] <= {16'd0, i0[15:0]}; d[10] <= {16'd0, i1[15:0]}; d[11] <= {16'd0, i2[15:0]};
					run <= 1'b0;
				end
			end
			// --- DCPL: rgb 0, cue 1-3, out 4 ----------------------------------------------------
			6'h29: begin
				if (step == 0) rgb_ir;
				else if (step < 4) dcue_step(step - 6'd1);
				else begin mac_color(lm); run <= 1'b0; end
			end
			// --- AVSZ3 / AVSZ4: sum, product, then check/clip ------------------------------------
			6'h2D, 6'h2E: begin
				if (step == 0) begin
					asum <= (op == 6'h2D)
					      ? ({48'd0, d[17][15:0]} + {48'd0, d[18][15:0]} + {48'd0, d[19][15:0]})
					      : ({48'd0, d[16][15:0]} + {48'd0, d[17][15:0]} + {48'd0, d[18][15:0]} + {48'd0, d[19][15:0]});
					zsf  <= (op == 6'h2D) ? c[29][15:0] : c[30][15:0];
				end else if (step == 1) begin
					// The sum of four 16-bit depths is 18 bits, so this is one DSP's
					// worth of multiply, not a 16 x 64 cascade of four: that cascade,
					// fed through the op mux, was the slowest path in the whole build.
					// Both operands are registered at step 0 so nothing else is in it.
					p0 <= m16u18(zsf, asum[17:0]);
				end else begin
					av = p0;
					if (av > 64'sh7FFFFFFF) c[31][16] <= 1'b1; if (av < -64'sh80000000) c[31][15] <= 1'b1;
					d[24] <= av[31:0];
					s0 = av >>> 12;
					i0 = clip(s0, 0, 65535);
					if (i0 != s0) c[31][18] <= 1'b1;
					d[7] <= {16'd0, i0[15:0]};
					run <= 1'b0;
				end
			end
			// --- GPF: products into macw, then out --------------------------------------------------
			6'h3D: begin
				if (step == 0) begin
					ir0v = sx16(d[8][15:0]);
					macw0 <= m16(d[9][15:0], ir0v[15:0]); macw1 <= m16(d[10][15:0], ir0v[15:0]); macw2 <= m16(d[11][15:0], ir0v[15:0]);
				end else begin mac_color(lm); run <= 1'b0; end
			end
			// --- GPL: products, add+check, out ---------------------------------------------------------
			6'h3E: begin
				if (step == 0) begin
					ir0v = sx16(d[8][15:0]);
					p0 <= m16(d[9][15:0], ir0v[15:0]); p1 <= m16(d[10][15:0], ir0v[15:0]); p2 <= m16(d[11][15:0], ir0v[15:0]);
				end else if (step == 1) begin
					a0 = (sx32(d[25]) <<< shamt) + p0; a1 = (sx32(d[26]) <<< shamt) + p1; a2 = (sx32(d[27]) <<< shamt) + p2;
					if (a0 >= P43) c[31][30] <= 1'b1; if (a0 < N43) c[31][27] <= 1'b1;
					if (a1 >= P43) c[31][29] <= 1'b1; if (a1 < N43) c[31][26] <= 1'b1;
					if (a2 >= P43) c[31][28] <= 1'b1; if (a2 < N43) c[31][25] <= 1'b1;
					macw0 <= a0; macw1 <= a1; macw2 <= a2;
				end else begin mac_color(lm); run <= 1'b0; end
			end
			default: run <= 1'b0;
			endcase
		end
	end

endmodule

`default_nettype wire
