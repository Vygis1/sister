//////////////////////////////////////////////////////////////////////////////////
// async_fifo.v - a small queue between two unrelated clocks.
//
// The textbook Gray-pointer FIFO. Each side keeps a binary pointer for its own
// arithmetic and a Gray copy to hand to the other side, because a Gray code
// changes one bit per step: whatever moment the far side samples it, it reads
// either the old value or the new one, never a mixture of both. A binary
// pointer sampled mid-change can read a value it never held -- 0111 to 1000
// caught halfway is 1111 -- and a queue that believes that is a queue that
// loses or duplicates entries.
//
// The data itself is never synchronised. It is written on one side, sits still
// for many cycles, and is read on the other only after the pointer that
// announces it has crossed. Synchronising 128 bits of data would be both
// unnecessary and wrong: every bit would be an independent chance to sample a
// different cycle.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module async_fifo #(
	parameter WIDTH = 32,
	parameter AW    = 3          // 2^AW entries
)(
	input  wire             wr_clk,
	input  wire             wr_rst,
	input  wire             wr_en,
	input  wire [WIDTH-1:0] wr_data,
	output wire             wr_full,

	input  wire             rd_clk,
	input  wire             rd_rst,
	input  wire             rd_en,
	output wire [WIDTH-1:0] rd_data,
	output wire             rd_empty
);
	localparam DEPTH = 1 << AW;

	(* ram_style = "distributed" *) reg [WIDTH-1:0] mem [0:DEPTH-1];

	reg  [AW:0] wr_bin, wr_gray;
	reg  [AW:0] rd_bin, rd_gray;
	reg  [AW:0] wr_gray_rd0, wr_gray_rd1;   // the writer's pointer, seen from rd_clk
	reg  [AW:0] rd_gray_wr0, rd_gray_wr1;   // the reader's, seen from wr_clk

	function [AW:0] to_gray;
		input [AW:0] b;
		to_gray = b ^ (b >> 1);
	endfunction

	wire [AW:0] wr_bin_next  = wr_bin + {{AW{1'b0}}, (wr_en && !wr_full)};
	wire [AW:0] rd_bin_next  = rd_bin + {{AW{1'b0}}, (rd_en && !rd_empty)};

	// Full when the writer is one lap ahead: the two top bits differ and the
	// rest match, which in Gray is the pointer with both top bits inverted.
	assign wr_full  = (wr_gray == {~rd_gray_wr1[AW:AW-1], rd_gray_wr1[AW-2:0]});
	assign rd_empty = (rd_gray == wr_gray_rd1);
	assign rd_data  = mem[rd_bin[AW-1:0]];

	always @(posedge wr_clk) begin
		if (wr_rst) begin
			wr_bin <= 0; wr_gray <= 0; rd_gray_wr0 <= 0; rd_gray_wr1 <= 0;
		end else begin
			if (wr_en && !wr_full) mem[wr_bin[AW-1:0]] <= wr_data;
			wr_bin  <= wr_bin_next;
			wr_gray <= to_gray(wr_bin_next);
			rd_gray_wr0 <= rd_gray;
			rd_gray_wr1 <= rd_gray_wr0;
		end
	end

	always @(posedge rd_clk) begin
		if (rd_rst) begin
			rd_bin <= 0; rd_gray <= 0; wr_gray_rd0 <= 0; wr_gray_rd1 <= 0;
		end else begin
			rd_bin  <= rd_bin_next;
			rd_gray <= to_gray(rd_bin_next);
			wr_gray_rd0 <= wr_gray;
			wr_gray_rd1 <= wr_gray_rd0;
		end
	end
endmodule

`default_nettype wire
