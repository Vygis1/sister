//////////////////////////////////////////////////////////////////////////////////
// ps1_icache.v - the instruction cache, answered in the same cycle it is asked.
//
// The R3000A has 4 KB of instruction cache on the chip: 256 lines of 16 bytes,
// direct mapped, with a valid bit per word. The two open PlayStation cores that
// run at full speed (PSX_MiSTer's rtl/cpu.vhd and pgate1's Cache_IR.sflp) both
// build exactly that, and both answer a hit combinationally so the processor
// never waits for an instruction it already has.
//
// This tree did not have one. Instruction fetches went through the general
// cache that the DMA also uses, which answers in three or four clocks, and the
// processor sat through every one of them: measured on the board, it spent 58%
// of its clocks waiting for memory it was always going to find, and managed 5.9
// MIPS where the console's own processor does 33.9.
//
// --- how it answers ------------------------------------------------------------
//
// Tags and lines both live in distributed RAM (LUTs) and are read
// combinationally: `hit` and `word` are true of the address being presented
// this cycle. Block RAM was tried for the lines and costs two thousand fewer
// LUTs, but its clock-to-output lands the instruction late enough that the
// multiply it feeds no longer finishes inside the clock, and the design missed
// timing by 1.5 ns. LUTs answer sooner; the multiply has no slack to give.
//
// --- how it is kept honest -----------------------------------------------------
//
// A line is dropped when anything writes to the 16 bytes it maps, whoever wrote
// them: the processor, or a DMA moving a program into RAM. The tag is not even
// consulted -- the index alone is cleared, which throws away a line that may not
// have needed it and costs one refill, against the certainty of never running a
// stale instruction. Loading a program resets the whole thing.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_icache #(
	parameter IDXBITS = 8,           // 256 lines of 16 bytes = 4 KB, as on the chip

	// --- a write that lands in a held line patches it instead of dropping it ---
	// Measured on the board: 99% of the processor's stores land in a line this
	// cache is holding, and the lines they threw away accounted for 99% of every
	// miss it had. The cache was not missing for want of room -- doubling it to
	// 8 KB changed the miss rate by nothing at all, twice -- it was missing
	// because the machine kept destroying its own working set one store at a
	// time.
	//
	// A store of a whole word can simply be written into the line: the value is
	// right there and the memory behind takes the same write. A store of part of
	// a word would need the rest of it read back to merge, which is another read
	// port across the whole thing, so those still drop the line. Instructions do
	// not want this at all and leave it off.
	parameter WR_PATCH = 0
)(
	input  wire        clk,
	input  wire        rst,

	// --- the fetch, answered this cycle ------------------------------------
	input  wire [28:0] fa,           // physical address the processor will fetch
	input  wire        fa_ok,        // it is in cacheable memory (RAM or BIOS)
	output wire        hit,
	output reg  [31:0] word,       // the instruction at `fa`, this cycle
	output wire [127:0] line,      // ...or the whole 16 bytes it came from
	// a second lookup, answered the same cycle: the line one texel step on,
	// so a textured run can cross a line boundary without stopping
	input  wire [28:0] fa2,
	input  wire        fa2_ok,
	output wire        hit2,
	output wire [127:0] line2,

	// --- filling, from a line the bus brought back -------------------------
	input  wire        fill_en,
	input  wire [28:0] fill_addr,
	input  wire [127:0] fill_line,

	// --- writes that could land in a line we hold --------------------------
	input  wire        inv_a_en,
	input  wire [28:0] inv_a_addr,
	input  wire [3:0]  inv_a_be,     // which bytes of the word (WR_PATCH only)
	input  wire [31:0] inv_a_data,   // and what is being written
	input  wire        inv_b_en,
	input  wire [28:0] inv_b_addr
);
	localparam LINES = 1 << IDXBITS;
	localparam TAGW  = 29 - IDXBITS - 4;

	(* ram_style = "distributed" *) reg [TAGW-1:0] tags [0:LINES-1];
	// The line is kept as its four words rather than one 128-bit lump, so that a
	// single word of it can be written without touching the other three. That is
	// one write address and four write enables, which is what distributed RAM
	// does naturally; a partial write of one wide element is not.
	(* ram_style = "distributed" *) reg [31:0] w0 [0:LINES-1];
	(* ram_style = "distributed" *) reg [31:0] w1 [0:LINES-1];
	(* ram_style = "distributed" *) reg [31:0] w2 [0:LINES-1];
	(* ram_style = "distributed" *) reg [31:0] w3 [0:LINES-1];
	reg [LINES-1:0] vbits;

	wire [IDXBITS-1:0] f_idx = fa[IDXBITS+3:4];
	wire [TAGW-1:0]    f_tag = fa[28:IDXBITS+4];

	assign hit = fa_ok && vbits[f_idx] && (tags[f_idx] == f_tag);

	assign line = {w3[f_idx], w2[f_idx], w1[f_idx], w0[f_idx]};

	wire [IDXBITS-1:0] f2_idx = fa2[IDXBITS+3:4];
	wire [TAGW-1:0]    f2_tag = fa2[28:IDXBITS+4];
	assign hit2  = fa2_ok && vbits[f2_idx] && (tags[f2_idx] == f2_tag);
	assign line2 = {w3[f2_idx], w2[f2_idx], w1[f2_idx], w0[f2_idx]};

	always @(*) case (fa[3:2])
		2'd0:    word = w0[f_idx];
		2'd1:    word = w1[f_idx];
		2'd2:    word = w2[f_idx];
		default: word = w3[f_idx];
	endcase

	wire [IDXBITS-1:0] w_idx = fill_addr[IDXBITS+3:4];
	wire [IDXBITS-1:0] a_idx = inv_a_addr[IDXBITS+3:4];
	wire [IDXBITS-1:0] b_idx = inv_b_addr[IDXBITS+3:4];

	// --- a write only drops the line that actually holds it --------------------
	// This used to clear the line by index without looking at the tag: a write
	// anywhere in memory threw away whatever happened to be sitting at the same
	// index. Measured on the board, the processor stores on 3.4% of instructions
	// and loads on 19%, so that was one line thrown away for every five or six
	// loads -- and almost all of them were lines the write never touched.
	//
	// Comparing the tag costs one more read of the tag memory, which is LUTs and
	// nothing else, and a line is now dropped only when the write really lands
	// in it. Dropping the RIGHT line is still the whole of the coherency rule:
	// the word inside it is not patched, so nothing stale can be read.
	wire a_tag_hit = vbits[a_idx] && (tags[a_idx] == inv_a_addr[28:IDXBITS+4]);
	wire b_tag_hit = vbits[b_idx] && (tags[b_idx] == inv_b_addr[28:IDXBITS+4]);

	// a whole-word store into a line we hold, and no fill competing for the port
	wire a_patch = (WR_PATCH != 0) && inv_a_en && a_tag_hit
	               && (inv_a_be == 4'b1111) && !fill_en;

	// one write address, four write enables
	wire [IDXBITS-1:0] wr_idx = fill_en ? w_idx : a_idx;
	wire [127:0]       wr_dat = fill_en ? fill_line : {4{inv_a_data}};
	wire [3:0]         wr_we  = fill_en ? 4'b1111
	                          : a_patch ? (4'b0001 << inv_a_addr[3:2])
	                          :           4'b0000;

	integer k;
	always @(posedge clk) begin
		if (rst) begin
			vbits <= {LINES{1'b0}};
		end else begin
			// A fill and an invalidate can land together. The invalidate wins:
			// the line being filled may be the very one just written, and a
			// refill costs a few clocks where a stale instruction costs the
			// machine.
			if (wr_we[0]) w0[wr_idx] <= wr_dat[31:0];
			if (wr_we[1]) w1[wr_idx] <= wr_dat[63:32];
			if (wr_we[2]) w2[wr_idx] <= wr_dat[95:64];
			if (wr_we[3]) w3[wr_idx] <= wr_dat[127:96];
			if (fill_en) begin
				tags[w_idx]  <= fill_addr[28:IDXBITS+4];
				vbits[w_idx] <= 1'b1;
			end
			// a write that landed in a line we hold and could not be patched
			// into it drops it, exactly as before
			if (inv_a_en && a_tag_hit && !a_patch) vbits[a_idx] <= 1'b0;
			if (inv_b_en && b_tag_hit)             vbits[b_idx] <= 1'b0;
		end
	end
endmodule

`default_nettype wire
