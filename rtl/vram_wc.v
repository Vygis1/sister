//////////////////////////////////////////////////////////////////////////////////
// vram_wc.v - write combining between the GPU's draw port and the VRAM cache.
//
// The rasteriser writes one pixel at a time: a 16-bit half of a 32-bit word,
// through a cache that takes three cycles per access and, on a miss, a DDR3
// round trip. A full-screen quad is 153600 of those. Pixels along a scanline
// are consecutive, so eight of them make one 16-byte line: this gathers a
// line's worth of writes and hands the cache ONE line write, with a byte mask
// for the parts that were touched. The engine sees its acknowledge a cycle
// after asking, whatever the cache is doing.
//
// Reads (texels, blends, the CPU read-back, copies) flush the gathered line
// first, so the engine never reads around its own writes. A line that has been
// waiting IDLE cycles with nothing following it is flushed too, so the last
// pixels of a primitive land before anyone looks.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module vram_wc #(
	parameter IDLE = 32
)(
	input  wire        clk,
	input  wire        rst,

	// the engine's side: the same word port the cache used to be
	input  wire [28:0] g_addr,
	input  wire        g_req,
	input  wire        g_we,
	input  wire [3:0]  g_be,
	input  wire [31:0] g_wdata,
	input  wire        g_around,    // this read may go round the cache
	input  wire        g_lin,      // ...and the run it wants is along one row
	// a whole 16-byte line in one write: every byte, no merging to do
	input  wire        g_lwe,
	input  wire [127:0] g_wdata128,
	output reg  [31:0] g_rdata,
	output reg  [127:0] g_line,    // the whole 16 bytes that read came from
	output wire        g_ack,

	// the cache's port A, with its line-write mode
	output reg  [28:0]  c_addr,
	output reg          c_req,
	output reg          c_we,
	output reg          c_around,
	output reg          c_lin,
	output reg          c_lwe,
	output reg  [3:0]   c_be,
	output reg  [31:0]  c_wdata,
	output reg  [15:0]  c_be16,
	output reg  [127:0] c_wdata128,
	input  wire [31:0]  c_rdata,
	input  wire [127:0] c_line,
	input  wire         c_ack
);
	// the gathered line
	reg         acc_v;
	reg [24:0]  acc_line;
	reg [127:0] acc_data;
	reg [15:0]  acc_be;
	reg [7:0]   idle_ct;

	wire        same_line = acc_v && (g_addr[28:4] == acc_line);
	wire [1:0]  wsel = g_addr[3:2];

	localparam S_IDLE = 2'd0, S_FLUSH = 2'd1, S_READ = 2'd2;
	reg [1:0] st;

	// --- one line already travelling, one waiting behind it -------------------
	// Measured on the board: the drawing engine spent 1.55 clocks PER PIXEL in
	// D_WRITEW, waiting for a finished line to be taken. It could only hand one
	// over at a time, so every time a span crossed a 16-byte boundary while a
	// write-back was still in flight -- which is most of them, with the scanout
	// reading through the same cache -- the engine stopped. A real PlayStation
	// sustains about a pixel a clock; this was a third of the gap on its own.
	//
	// One more slot is enough: the accumulator is then always free to take the
	// next write, and the two drain in order behind it.
	reg         pend_v;
	reg [24:0]  pend_line;
	reg [127:0] pend_data;
	reg [15:0]  pend_be;

	// see the note at the top of this file
	reg         g_ack_r;
	wire        take_now = (st == S_IDLE) && g_req && g_we
	                       && ((!acc_v || same_line) || !pend_v);
	assign g_ack = g_ack_r | take_now;
	reg       after_flush_read;      // the flush was for a read: do the read next

	integer k;
	always @(posedge clk) begin
		if (rst) begin
			acc_v <= 1'b0; acc_line <= 25'd0; acc_data <= 128'd0; acc_be <= 16'd0; idle_ct <= 8'd0;
			pend_v <= 1'b0; pend_line <= 25'd0; pend_data <= 128'd0; pend_be <= 16'd0;
			g_ack_r <= 1'b0;
			st <= S_IDLE; c_req <= 1'b0; c_we <= 1'b0; c_lwe <= 1'b0; c_around <= 1'b0; c_lin <= 1'b0; c_be <= 4'd0; c_wdata <= 32'd0;
			c_be16 <= 16'd0; c_wdata128 <= 128'd0; c_addr <= 29'd0; g_rdata <= 32'd0;
			g_line <= 128'd0;
			after_flush_read <= 1'b0;
		end else begin
			g_ack_r <= 1'b0;
			// the write-back is done with; the one waiting behind it goes next
			if (c_ack) begin c_req <= 1'b0; c_we <= 1'b0; c_lwe <= 1'b0; end
			else if (!c_req && pend_v) begin
				c_addr <= {pend_line, 4'd0}; c_we <= 1'b1; c_lwe <= 1'b1;
				c_be16 <= pend_be; c_wdata128 <= pend_data; c_req <= 1'b1;
				pend_v <= 1'b0;
			end

			case (st)
			S_IDLE: begin
				if (g_req && g_we) begin
					if (!acc_v || same_line) begin
						// gather: merge the bytes this write enables
						if (!acc_v) begin acc_line <= g_addr[28:4]; acc_be <= 16'd0; end
						if (g_lwe) begin
							// the whole line, so whatever was gathered is covered
							acc_data <= g_wdata128; acc_be <= 16'hFFFF;
						end else
							for (k = 0; k < 4; k = k + 1)
								if (g_be[k]) begin
									acc_data[wsel*32 + k*8 +: 8] <= g_wdata[k*8 +: 8];
									acc_be[wsel*4 + k] <= 1'b1;
								end
						acc_v <= 1'b1; idle_ct <= 8'd0;
					end else if (!c_req && !pend_v) begin
						// A different line, and the bus is free. Hand the gathered
						// one straight over and start the new one in the same
						// clock: the c_* registers hold what is going out, so the
						// accumulator is free now.
						c_addr <= {acc_line, 4'd0}; c_we <= 1'b1; c_lwe <= 1'b1;
						c_be16 <= acc_be; c_wdata128 <= acc_data; c_req <= 1'b1;
						acc_line <= g_addr[28:4]; acc_be <= 16'd0;
						if (g_lwe) begin
							acc_data <= g_wdata128; acc_be <= 16'hFFFF;
						end else
							for (k = 0; k < 4; k = k + 1)
								if (g_be[k]) begin
									acc_data[wsel*32 + k*8 +: 8] <= g_wdata[k*8 +: 8];
									acc_be[wsel*4 + k] <= 1'b1;
								end
						acc_v <= 1'b1; idle_ct <= 8'd0;
					end else if (!pend_v) begin
						// A different line and the bus is busy: park the finished
						// one and carry straight on, rather than stopping.
						pend_line <= acc_line; pend_be <= acc_be; pend_data <= acc_data;
						pend_v <= 1'b1;
						acc_line <= g_addr[28:4]; acc_be <= 16'd0;
						if (g_lwe) begin
							acc_data <= g_wdata128; acc_be <= 16'hFFFF;
						end else
							for (k = 0; k < 4; k = k + 1)
								if (g_be[k]) begin
									acc_data[wsel*32 + k*8 +: 8] <= g_wdata[k*8 +: 8];
									acc_be[wsel*4 + k] <= 1'b1;
								end
						acc_v <= 1'b1; idle_ct <= 8'd0;
					end
					// else: both slots are full. Say nothing and the engine holds
					// its request until one frees up.
				end else if (g_req && !g_we && !g_ack_r && !c_req && !pend_v) begin
					if (acc_v) begin
						c_addr <= {acc_line, 4'd0}; c_we <= 1'b1; c_lwe <= 1'b1;
						c_be16 <= acc_be; c_wdata128 <= acc_data; c_req <= 1'b1;
						acc_v <= 1'b0; after_flush_read <= 1'b1;
						st <= S_FLUSH;
					end else begin
						c_addr <= g_addr; c_around <= g_around; c_lin <= g_lin; c_we <= 1'b0; c_lwe <= 1'b0; c_be <= g_be; c_req <= 1'b1;
						st <= S_READ;
					end
				end else if (acc_v && !c_req && !pend_v) begin
					// nothing asked: after a while, let the line go
					if (idle_ct == IDLE) begin
						c_addr <= {acc_line, 4'd0}; c_we <= 1'b1; c_lwe <= 1'b1;
						c_be16 <= acc_be; c_wdata128 <= acc_data; c_req <= 1'b1;
						acc_v <= 1'b0; after_flush_read <= 1'b0;
						st <= S_FLUSH;
					end else idle_ct <= idle_ct + 8'd1;
				end
			end

			S_FLUSH: if (c_ack) begin
					c_we <= 1'b0; c_lwe <= 1'b0;
					if (after_flush_read) begin
						c_addr <= g_addr; c_around <= g_around; c_lin <= g_lin; c_be <= g_be; c_req <= 1'b1;
						st <= S_READ;
					end else
						st <= S_IDLE;     // the write that caused the flush is taken next
				end

			S_READ: if (c_ack) begin
					g_rdata <= c_rdata; g_line <= c_line; g_ack_r <= 1'b1;
					st <= S_IDLE;
				end
			default: st <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
