//////////////////////////////////////////////////////////////////////////////////
// pc_ddr64.v - MiSTer's ao486 L2 cache (rtl/pc/cache/l2_cache.v) on our DDR3: its memory side is
// MiSTer's DDRAM port -- 64-bit words, a read a burst of 1-8 of them, a write one word with byte
// enables, Avalon busy -- and ours is mem_arb's 128-bit lines.
//
// A read: the lines the burst covers asked for back to back, the 64-bit halves handed back in turn,
// one a clock. A write: the word's line, its bytes only. Busy from the clock a command is taken until
// it is done (a read: until its last word has gone back), as pc_mem.
//
// The host port: the ESP32 putting the BIOS and the VGA BIOS in (a 32-bit word at a byte address),
// before the CPU runs. The words are gathered four to a line (the fill runs in address order) and the
// lines queued: a word used to be taken only while nothing else was in flight, and with the quad link a
// word comes every ~32 clocks -- at the z486's 40 MHz a DDR3 write beside the picture's reads took longer,
// words were dropped and the BIOS came out shifted (2026-10-19: the CPU never got past its first lines).
// A part-filled line goes after 256 clocks with no word.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module pc_ddr64 #(
	parameter [23:0] BASE = 24'h000000
)(
	input  wire         clk,
	input  wire         rst,
	// the L2 cache's DDRAM side
	input  wire [24:0]  a_addr,            // a 64-bit word's address
	input  wire [63:0]  a_din,
	input  wire [7:0]   a_be,
	input  wire [7:0]   a_burst,
	input  wire         a_rd,
	input  wire         a_we,
	output wire         a_busy,
	output reg  [63:0]  a_dout,
	output reg          a_dout_ready,
	// the host
	input  wire         h_we,
	input  wire [31:0]  h_addr,
	input  wire [31:0]  h_wdata,
	output reg          h_lost,            // a host word was dropped (the queue was full)
	// a port of mem_arb
	output reg  [23:0]  m_addr,
	output reg          m_req,
	output reg          m_we,
	output reg  [127:0] m_wdata,
	output reg  [15:0]  m_wmask,
	input  wire         m_ready,
	input  wire [127:0] m_rdata,
	input  wire         m_valid
);
	localparam S_IDLE = 2'd0, S_RD = 2'd1, S_WR = 2'd2;
	reg [1:0] st;
	reg [3:0] ask_left;                   // lines not yet taken
	reg [7:0] words_left;                 // 64-bit words not yet handed back
	reg       half;                       // the next word's half of the line at the head
	reg [127:0] q_line [0:7];
	reg [2:0]   q_wr, q_rd;
	wire        q_empty = (q_wr == q_rd);

	assign a_busy = (st != S_IDLE);

	// --- the host's words, four to a line, and a queue of lines ----------------------------------
	reg [23:0]  g_line; reg [127:0] g_data; reg [15:0] g_mask; reg g_v = 1'b0; reg [7:0] g_quiet;
	(* ram_style = "distributed" *) reg [23:0] hq_line [0:31];
	(* ram_style = "distributed" *) reg [127:0] hq_data [0:31];
	(* ram_style = "distributed" *) reg [15:0] hq_mask [0:31];
	reg [4:0]   hq_w = 5'd0, hq_r = 5'd0;
	wire        hq_empty = (hq_w == hq_r);
	wire        hq_fullq = (hq_w + 5'd1 == hq_r);
	wire [23:0] h_line = h_addr[27:4];
	wire [15:0] h_m = 16'h000F << {h_addr[3:2], 2'b00};
	wire [127:0] h_d = {4{h_wdata}};
	// (a push of the gathered line: when a word for another line comes, when the line is whole, after quiet)
	wire        g_full  = g_v && h_we && h_line == g_line && ((g_mask | h_m) == 16'hFFFF);
	wire        g_other = g_v && h_we && h_line != g_line;
	wire        g_old   = g_v && !h_we && g_quiet == 8'hFF;
	wire        hq_pop;
	always @(posedge clk) begin
		if (rst) begin g_v <= 1'b0; hq_w <= 5'd0; g_quiet <= 8'd0; end
		else begin
			g_quiet <= h_we ? 8'd0 : (g_quiet == 8'hFF ? g_quiet : g_quiet + 8'd1);
			if (g_full) begin
				hq_line[hq_w] <= g_line; hq_mask[hq_w] <= 16'hFFFF;
				hq_data[hq_w] <= (g_data & ~mask_bits(h_m)) | (h_d & mask_bits(h_m));
				hq_w <= hq_w + 5'd1; g_v <= 1'b0;
			end else if (g_other || g_old) begin
				hq_line[hq_w] <= g_line; hq_mask[hq_w] <= g_mask; hq_data[hq_w] <= g_data;
				hq_w <= hq_w + 5'd1;
				if (g_other) begin g_line <= h_line; g_mask <= h_m; g_data <= h_d; end
				else g_v <= 1'b0;
			end else if (h_we) begin
				if (!g_v) begin g_v <= 1'b1; g_line <= h_line; g_mask <= h_m; g_data <= h_d; end
				else begin g_mask <= g_mask | h_m; g_data <= (g_data & ~mask_bits(h_m)) | (h_d & mask_bits(h_m)); end
			end
		end
	end
	function [127:0] mask_bits; input [15:0] m; integer b; begin
		for (b = 0; b < 16; b = b + 1) mask_bits[8*b +: 8] = {8{m[b]}};
	end endfunction
	assign hq_pop = (st == S_IDLE) && !rst && !a_rd && !a_we && !hq_empty;
	always @(posedge clk) if (rst) hq_r <= 5'd0; else if (hq_pop) hq_r <= hq_r + 5'd1;
	// (a line pushed into a full queue: lost -- h_lost stays up until the next reset, for the host to see)
	always @(posedge clk) if (rst) h_lost <= 1'b0; else if ((g_full || g_other || g_old) && hq_fullq) h_lost <= 1'b1;

	wire [7:0]  n_words = (a_burst == 8'd0) ? 8'd1 : a_burst;
	wire [8:0]  last_w  = {8'd0, a_addr[0]} + {1'b0, n_words} - 9'd1;
	wire [3:0]  n_lines = last_w[4:1] + 4'd1;

	always @(posedge clk) begin
		a_dout_ready <= 1'b0;
		if (rst) begin
			st <= S_IDLE; m_req <= 1'b0; q_wr <= 3'd0; q_rd <= 3'd0;
		end else case (st)
		S_IDLE: begin
			q_wr <= 3'd0; q_rd <= 3'd0;
			if (a_rd) begin
				m_addr <= BASE + a_addr[24:1]; m_we <= 1'b0; m_req <= 1'b1;
				ask_left <= n_lines; words_left <= n_words; half <= a_addr[0];
				st <= S_RD;
			end else if (a_we) begin
				m_addr <= BASE + a_addr[24:1]; m_we <= 1'b1; m_req <= 1'b1;
				m_wdata <= {a_din, a_din};
				m_wmask <= a_addr[0] ? {a_be, 8'd0} : {8'd0, a_be};
				st <= S_WR;
			end else if (!hq_empty) begin          // (a host line: hq_pop takes it off the queue)
				m_addr <= BASE + hq_line[hq_r]; m_we <= 1'b1; m_req <= 1'b1;
				m_wdata <= hq_data[hq_r];
				m_wmask <= hq_mask[hq_r];
				st <= S_WR;
			end
		end
		S_WR: if (m_ready) begin m_req <= 1'b0; st <= S_IDLE; end
		S_RD: begin
			if (m_req && m_ready) begin
				if (ask_left == 4'd1) m_req <= 1'b0;
				else m_addr <= m_addr + 24'd1;
				ask_left <= ask_left - 4'd1;
			end
			if (m_valid) begin q_line[q_wr] <= m_rdata; q_wr <= q_wr + 3'd1; end
			if (!q_empty) begin
				a_dout <= half ? q_line[q_rd][127:64] : q_line[q_rd][63:0];
				a_dout_ready <= 1'b1;
				half <= ~half;
				if (half) q_rd <= q_rd + 3'd1;
				words_left <= words_left - 8'd1;
				if (words_left == 8'd1) st <= S_IDLE;
			end
		end
		default: st <= S_IDLE;
		endcase
	end
endmodule

`default_nettype wire
