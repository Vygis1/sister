//////////////////////////////////////////////////////////////////////////////////
// ps1_spu.v - the SPU's registers, and nothing behind them yet.
//
// There is no sound: no voices, no SPU RAM, no mixing. What exists is the 512
// bytes of registers at 1F801C00h-1F801DFFh, kept as written so that what a
// program writes it reads back, and SPUSTAT (1F801DAEh) composed the way the
// chip composes it: its low six bits mirror SPUCNT's (mode, IRQ enable, the
// transfer mode), and the busy and request bits are always clear, because a
// transfer here is over the moment it is asked for (ps1_dma.v ends channel 4
// at once).
//
// libspu insists on this. Every transfer it makes waits for SPUSTAT to agree
// with what it just wrote to SPUCNT, before the DMA and again after it; with
// zeros here each wait ran to its 5000-try timeout, and the game sat in its
// loading state. Sound proper is a separate piece of work.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module ps1_spu (
	input  wire        clk,
	input  wire        rst,
	input  wire        sel,          // a CPU access to 1F801C00h..1F801DFFh
	input  wire        we,
	input  wire [8:0]  addr,         // byte offset within the range
	input  wire [3:0]  be,
	input  wire [31:0] wdata,
	output wire [31:0] rdata
);
	// One 32-bit word per register pair, in distributed RAM (a reset loop would
	// make it 4096 flops with byte-lane enables, which is what the router choked
	// on; a block RAM would answer a clock too late for the I/O bus).
	// The BIOS and libspu write every register they read, so no reset is needed;
	// the initial block keeps simulation free of X.
	reg [31:0] r [0:127];
	integer i;
	initial for (i = 0; i < 128; i = i + 1) r[i] = 32'd0;
	wire [6:0] wi = addr[8:2];
	always @(posedge clk) if (sel && we) begin
		if (be[0]) r[wi][7:0]   <= wdata[7:0];
		if (be[1]) r[wi][15:8]  <= wdata[15:8];
		if (be[2]) r[wi][23:16] <= wdata[23:16];
		if (be[3]) r[wi][31:24] <= wdata[31:24];
	end
	reg [15:0] cnt;                                        // SPUCNT 1F801DAAh, kept beside the RAM for SPUSTAT
	always @(posedge clk) begin
		if (rst) cnt <= 16'd0;
		else if (sel && we && wi == 7'h6A) begin           // 1DA8h: SPUCNT is the high half
			if (be[2]) cnt[7:0]  <= wdata[23:16];
			if (be[3]) cnt[15:8] <= wdata[31:24];
		end
	end
	wire [15:0] stat = {10'd0, cnt[5:0]};                  // SPUSTAT 1F801DAEh: the mode bits mirrored, never busy
	wire [31:0] q = r[wi];                                 // read in the same clock (distributed RAM): the bus latches it at the clock's end
	assign rdata = (wi == 7'h6B) ? {stat, q[15:0]} : q;    // 1DACh: {SPUSTAT, 1DACh}
endmodule
`default_nettype wire
