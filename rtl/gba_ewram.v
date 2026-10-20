//////////////////////////////////////////////////////////////////////////////////
// gba_ewram - the Game Boy Advance's external work RAM and save RAM, in DDR3 behind a cache.
//
// 256 kB of work RAM and 64 kB of save RAM do not fit in block RAM beside the video memory,
// so they live in DDR3 on a mem_arb port. Reads come from a direct-mapped cache of 16-byte
// lines (a miss fetches the line); writes go straight through with a byte mask, and into the
// cached line if it is there. The console's own bus charges three cycles per halfword for
// this memory, so a hit, answered in a clock, is never late, and a miss (the DDR3's twenty-odd
// clocks) is rare: code and data walk forwards.
//
// The port: a 32-bit word with byte enables; req held until ack.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module gba_ewram #(
	parameter [23:0] BASE = 24'h20_0000,   // the line address of word 0 (EWRAM then SRAM)
	parameter IDXBITS = 9                  // 512 lines = 8 kB
)(
	input  wire         clk,
	input  wire         rst,
	// the console
	input  wire [16:0]  a_addr,            // 32-bit words
	input  wire         a_req,
	input  wire         a_we,
	input  wire [3:0]   a_be,
	input  wire [31:0]  a_wdata,
	output reg          a_ack,
	output reg  [31:0]  a_rdata,
	// the arbiter's port
	output reg  [23:0]  m_addr,
	output reg          m_req,
	output reg          m_we,
	output reg  [127:0] m_wdata,
	output reg  [15:0]  m_wmask,
	input  wire         m_ready,
	input  wire [127:0] m_rdata,
	input  wire         m_valid
);
	localparam LINES = 1 << IDXBITS;
	localparam TAGW = 15 - IDXBITS;        // 17-bit word address = 15 bits of line + 2
	reg [127:0]      line [0:LINES-1];
	reg [TAGW-1:0]   tag  [0:LINES-1];
	reg              vld  [0:LINES-1];
	wire [14:0]      la  = a_addr[16:2];
	wire [IDXBITS-1:0] idx = la[IDXBITS-1:0];
	wire [TAGW-1:0]  tg  = la[14:IDXBITS];
	wire [1:0]       wsel = a_addr[1:0];
	wire             hit = vld[idx] && (tag[idx] == tg);
	reg [1:0]  st;                         // 0 idle, 1 the line coming, 2 the write going
	reg [127:0] lq;
	reg [IDXBITS-1:0] fidx; reg [TAGW-1:0] ftg; reg [1:0] fsel;
	integer i;
	always @(posedge clk) begin
		a_ack <= 1'b0;
		if (rst) begin
			st <= 2'd0; m_req <= 1'b0;
			for (i = 0; i < LINES; i = i + 1) vld[i] <= 1'b0;
		end else case (st)
		2'd0: if (a_req && !a_ack) begin
			if (a_we) begin
				// through to DDR3, the line patched if held
				m_addr <= BASE + {9'd0, la}; m_we <= 1'b1; m_req <= 1'b1;
				m_wdata <= {4{a_wdata}}; m_wmask <= {12'd0, a_be} << {wsel, 2'd0};
				if (hit) for (i = 0; i < 4; i = i + 1) if (a_be[i]) line[idx][wsel * 32 + i * 8 +: 8] <= a_wdata[i * 8 +: 8];
				st <= 2'd2;
			end else if (hit) begin
				a_rdata <= line[idx][wsel * 32 +: 32]; a_ack <= 1'b1;
			end else begin
				m_addr <= BASE + {9'd0, la}; m_we <= 1'b0; m_req <= 1'b1;
				fidx <= idx; ftg <= tg; fsel <= wsel;
				st <= 2'd1;
			end
		end
		2'd1: begin
			if (m_ready) m_req <= 1'b0;
			if (m_valid) begin
				line[fidx] <= m_rdata; tag[fidx] <= ftg; vld[fidx] <= 1'b1;
				a_rdata <= m_rdata[fsel * 32 +: 32]; a_ack <= 1'b1;
				st <= 2'd0;
			end
		end
		default: begin
			if (m_ready) begin m_req <= 1'b0; a_ack <= 1'b1; st <= 2'd0; end
		end
		endcase
	end
endmodule
`default_nettype wire
