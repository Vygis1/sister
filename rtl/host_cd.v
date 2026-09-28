//////////////////////////////////////////////////////////////////////////////////
// host_cd.v - the PlayStation's disc from the PC, over the register link.
//
// The same job cd_feed.v does for the ESP32, for when the ESP32 cannot (its SD
// card stopped answering on 2026-09-28, and its Wi-Fi path is known to lose a
// sector). The PC reads what the drive wants (ctrl 0x128 in console_top), writes
// the 2352-byte raw sector into the window at ctrl 0x4000..0x492F with block
// writes, and commits it with its LBA at ctrl 0x12C; the drive takes it only if
// it is the sector it asked for. ctrl 0x130 bit 0 hands the drive to the PC,
// bit 1 says a disc is in.
//
// The bus writes a word at a time and the drive's ring takes a byte at a time,
// so words queue (16 deep: a word takes four clocks to go in, and the bus can
// bring them faster than that) and go in a byte a clock, low byte first. The
// commit waits for the queue to empty.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module host_cd (
	input  wire        clk,
	input  wire        rst,
	input  wire        we,
	input  wire [15:0] off,
	input  wire [31:0] wdata,
	output reg         own,
	output reg         disc,
	output wire        sb_we,
	output wire [11:0] sb_addr,
	output wire [7:0]  sb_data,
	output reg         sb_done,
	output reg  [23:0] sb_lba
);
	reg [41:0] q [0:15];             // {word index, word}
	reg [4:0]  wp, rp;
	reg [1:0]  b;                    // the byte of the head word that goes next
	reg        pend;                 // a commit waiting for the queue to drain
	reg [23:0] pend_lba;
	wire       empty = (wp == rp);
	wire [41:0] head = q[rp[3:0]];
	wire       win = we && (off[15:12] == 4'h4) && (off[11:2] < 10'd588);

	assign sb_we   = !empty;
	assign sb_addr = {head[41:32], b};
	assign sb_data = head[{b, 3'b000} +: 8];

	always @(posedge clk) begin
		sb_done <= 1'b0;
		if (rst) begin own <= 1'b0; disc <= 1'b0; wp <= 5'd0; rp <= 5'd0; b <= 2'd0; pend <= 1'b0; end
		else begin
			if (we && off == 16'h0130) begin own <= wdata[0]; disc <= wdata[1]; end
			if (we && off == 16'h012C) begin pend <= 1'b1; pend_lba <= wdata[23:0]; end
			if (win && (wp - rp) != 5'd16) begin q[wp[3:0]] <= {off[11:2], wdata}; wp <= wp + 5'd1; end
			if (!empty) begin
				b <= b + 2'd1;
				if (b == 2'd3) rp <= rp + 5'd1;
			end
			if (pend && empty && !win) begin pend <= 1'b0; sb_done <= 1'b1; sb_lba <= pend_lba; end
		end
	end
endmodule
`default_nettype wire
