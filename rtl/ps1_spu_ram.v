//////////////////////////////////////////////////////////////////////////////////
// ps1_spu_ram.v - the top 128 KB of SPU RAM (60000h..7FFFFh) in block RAM.
//
// The reverb reads ten and writes four halfwords of SPU RAM for every channel
// step, and its work area is always at the top of RAM (it runs from the address
// in ESA to 7FFFFh; the largest of libspu's presets is 18040h bytes). Through
// DDR3 that would be half a million single-halfword round trips a second; here
// it is one clock each. PSX_MiSTer keeps the top 64 KB of the same area on chip.
//
// The region is SINGLE-HOMED: every access to it -- a voice fetching a block, a
// transfer writing samples, a DMA read, the reverb -- comes here, and DDR3 never
// holds those addresses, so there is nothing to keep coherent.
//
// Two ports, 16-byte lines with a byte mask, one clock of read latency each:
// A for the SPU's line traffic, B for the reverb.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module ps1_spu_ram (
	input  wire         clk,
	input  wire [12:0]  a_addr,     // line within the region
	input  wire         a_we,
	input  wire [15:0]  a_mask,
	input  wire [127:0] a_wdata,
	output reg  [127:0] a_rdata,
	input  wire [12:0]  b_addr,
	input  wire         b_we,
	input  wire [15:0]  b_mask,
	input  wire [127:0] b_wdata,
	output reg  [127:0] b_rdata
);
	(* ram_style = "block" *) reg [127:0] mem [0:8191];
	integer i;
	initial for (i = 0; i < 8192; i = i + 1) mem[i] = 128'd0;
	always @(posedge clk) begin
		if (a_we) for (i = 0; i < 16; i = i + 1) if (a_mask[i]) mem[a_addr][i*8 +: 8] <= a_wdata[i*8 +: 8];
		a_rdata <= mem[a_addr];
	end
	always @(posedge clk) begin
		if (b_we) for (i = 0; i < 16; i = i + 1) if (b_mask[i]) mem[b_addr][i*8 +: 8] <= b_wdata[i*8 +: 8];
		b_rdata <= mem[b_addr];
	end
endmodule
`default_nettype wire
