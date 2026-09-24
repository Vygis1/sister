//////////////////////////////////////////////////////////////////////////////////
// ps1_loader.v - the host's way of putting bytes into the PlayStation's memory.
//
// The BIOS, and later a disc image, arrive over fpgalink as 32-bit words with
// a running index, the same way a cartridge does for the other consoles. The
// memory behind this speaks in 128-bit lines, so four words are gathered and
// written as one -- the same packing cart_ddr3 does, for the same reason -- at
// a line address chosen by which region the host is filling:
//
//     region 0  the BIOS      512 kB at BIOS_BASE
//     region 1  main RAM      2 MB   at RAM_BASE   (a test program, or a save)
//     region 2  VRAM          1 MB   at VRAM_BASE  (a picture, for the display test)
//
// A partial line at the end is flushed when the host says it has finished.
// There is no read-back: what is in DDR3 is checked by running it.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_loader #(
	parameter [23:0] BIOS_BASE = 24'h02_0000,   // in lines
	parameter [23:0] RAM_BASE  = 24'h00_0000,
	parameter [23:0] VRAM_BASE = 24'h04_0000
)(
	input  wire         clk,
	input  wire         rst,

	input  wire [1:0]   region,
	input  wire [19:0]  windex,     // 32-bit word index within the region
	input  wire         we,
	input  wire [31:0]  wdata,
	input  wire         fill_end,

	output reg  [23:0]  m_addr,
	output reg          m_req,
	output wire         m_we,
	output reg  [127:0] m_wdata,
	input  wire         m_ready,

	output reg          busy
);
	assign m_we = 1'b1;

	reg [127:0] buf_;
	reg [17:0]  buf_line;
	reg         have;

	wire [23:0] base = (region == 2'd0) ? BIOS_BASE : (region == 2'd1) ? RAM_BASE : VRAM_BASE;
	wire [17:0] line = windex[19:2];

	always @(posedge clk) begin
		if (rst) begin
			m_req <= 1'b0; have <= 1'b0; busy <= 1'b0; buf_ <= 128'd0; buf_line <= 18'd0;
		end else begin
			if (m_req && m_ready) begin m_req <= 1'b0; busy <= 1'b0; end

			if (we) begin
				// a word for a different line than the one being gathered: flush
				if (have && line != buf_line && !m_req) begin
					m_addr  <= base + {6'd0, buf_line};
					m_wdata <= buf_;
					m_req   <= 1'b1;
					busy    <= 1'b1;
				end
				buf_[windex[1:0]*32 +: 32] <= wdata;
				buf_line <= line;
				have <= 1'b1;
				// the fourth word completes the line: write it
				if (windex[1:0] == 2'd3) begin
					m_addr  <= base + {6'd0, line};
					m_wdata <= {wdata, buf_[95:0]};
					m_req   <= 1'b1;
					busy    <= 1'b1;
					have    <= 1'b0;
				end
			end else if (fill_end && have && !m_req) begin
				m_addr  <= base + {6'd0, buf_line};
				m_wdata <= buf_;
				m_req   <= 1'b1;
				busy    <= 1'b1;
				have    <= 1'b0;
			end
		end
	end
endmodule

`default_nettype wire
