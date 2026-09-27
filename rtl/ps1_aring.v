//////////////////////////////////////////////////////////////////////////////////
// ps1_aring.v - the PlayStation's sound on its way to the host: a ring buffer of
// stereo samples the host polls, answering at the synthesiser's addresses.
//
// The other cores share `synth`'s ring (mono, 16 bits, two samples a word, at
// its own 48.8 kHz). The PlayStation's SPU makes 44.1 kHz STEREO, so this is
// the same idea shaped for it: one word per sample pair, {right, left}, signed,
// and a register that says so. Everything the host already does -- the
// free-running write count as a cursor, reading a run of words out of page
// 0x0004_0000, the rate at 0x0003_000C -- works unchanged; the host reads the
// channel count at 0x0003_0024 (the synth answers that with a bus error, which
// it takes as "mono").
//
//   0x0003_0000  ID      "SY" 0002
//   0x0003_000C  RATE    44100
//   0x0003_0018  SIZE    ring length in words
//   0x0003_0020  WCOUNT  words ever written (the cursor)
//   0x0003_0024  CHANS   2
//   0x0004_0000  the ring, one {R, L} word per sample
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_aring #(
	parameter BUF_AW = 14            // 16384 words: 371 ms at 44.1 kHz
)(
	input  wire        clk,
	input  wire        rst,

	input  wire [31:0] sample,       // {right, left}, signed
	input  wire        sample_we,

	input  wire [15:0] off,
	output reg  [31:0] rdata,
	output reg         err,

	input  wire [BUF_AW-1:0] buf_addr,
	output wire [31:0]       buf_rdata
);
	reg [31:0] ring [0:(1 << BUF_AW) - 1];
	reg [31:0] wcount;
	reg [31:0] q;
	assign buf_rdata = q;

	always @(posedge clk) begin
		if (rst) wcount <= 32'd0;
		else if (sample_we) begin
			ring[wcount[BUF_AW-1:0]] <= sample;
			wcount <= wcount + 32'd1;
		end
		q <= ring[buf_addr];
	end

	always @* begin
		rdata = 32'd0;
		err   = 1'b0;
		case (off)
		16'h0000: rdata = 32'h5359_0002;
		16'h0004, 16'h0008, 16'h0010, 16'h0014: rdata = 32'd0;
		16'h000C: rdata = 32'd44100;
		16'h0018: rdata = 32'd1 << BUF_AW;
		16'h0020: rdata = wcount;
		16'h0024: rdata = 32'd2;
		default:  err = 1'b1;
		endcase
	end
endmodule

`default_nettype wire
