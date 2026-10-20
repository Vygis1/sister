//////////////////////////////////////////////////////////////////////////////////
// pc_cdda.v - the PC's CD audio: the stereo samples of the CD's audio tracks, which the ESP32 reads
// off the image and pushes in a sector at a time (2352 bytes, 588 samples), played at 44.1 kHz.
//
// After MiSTer's ao486 cdda.v (a FIFO of two sectors, a sector asked for whenever one fits, silence
// when it runs dry), on one clock: the 44.1 kHz tick from an accumulator on CLK_HZ.
//   push   a sample {right[31:16], left[15:0]} (the CD's own byte order: left first, little-endian)
//   req    a whole sector fits (the ESP32 looks at it with the disk's requests)
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module pc_cdda #(
	parameter integer CLK_HZ = 50_000_000
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        push,
	input  wire [31:0] sample,
	output reg         req,
	output reg  [15:0] audio_l,
	output reg  [15:0] audio_r
);
	localparam integer SECTOR = 588;               // samples a sector
	localparam integer AW = 12;                    // 4096 samples, 93 ms: the ESP32 serves the hard disk from the same loop
	reg [31:0] fifo [0:(1 << AW) - 1];
	reg [AW-1:0] wa, ra;
	reg [AW:0]   filled;
	reg [31:0]   q;

	// 44.1 kHz
	reg [31:0] acc;
	wire [32:0] acc_n = {1'b0, acc} + 33'd44_100;
	wire tick = acc_n >= CLK_HZ;

	wire take = tick && filled != 0;
	wire put  = push && filled != (1 << AW);
	always @(posedge clk) begin
		if (rst) begin
			acc <= 32'd0; wa <= 0; ra <= 0; filled <= 0; req <= 1'b0; audio_l <= 16'd0; audio_r <= 16'd0;
		end else begin
			acc <= tick ? acc_n[31:0] - CLK_HZ : acc_n[31:0];
			if (put) begin fifo[wa] <= sample; wa <= wa + 1'd1; end
			if (tick) begin
				if (filled != 0) begin audio_l <= q[15:0]; audio_r <= q[31:16]; ra <= ra + 1'd1; end
				else begin audio_l <= 16'd0; audio_r <= 16'd0; end
			end
			filled <= filled + put - take;
			req <= ((1 << AW) - filled) >= SECTOR;
		end
		q <= fifo[ra];
	end
endmodule

`default_nettype wire
