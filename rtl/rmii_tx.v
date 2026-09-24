//////////////////////////////////////////////////////////////////////////////////
// rmii_tx.v - RMII transmit: a buffer of bytes out onto the wire as a frame.
//
// Pulls its payload from a byte-addressable memory (the frame buffer in
// net_core) rather than taking a stream, because the reply is assembled in place
// before transmission starts and the length is known up front.
//
// What goes on the wire:
//
//   55 x7, D5 | the bytes at rd_addr 0..len-1 | zero padding | FCS(4) | gap
//
// Two details that are easy to get wrong and silent when you do:
//
//   Padding. Ethernet's minimum frame is 60 bytes before the FCS. An ARP reply
//   is 42. Short frames are dropped by the receiving NIC without comment, so the
//   padding is not optional and the CRC must cover it.
//
//   Interframe gap. 12 byte-times of idle after each frame. Skipping it mostly
//   works and occasionally does not, which is the worst kind of bug.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module rmii_tx (
	input  wire        clk,          // 50 MHz REF_CLK from the PHY
	input  wire        rst,

	input  wire        start,        // pulse to send rd_addr 0 .. length-1
	input  wire [10:0] length,

	output reg  [10:0] rd_addr,
	input  wire [7:0]  rd_data,      // valid the cycle after rd_addr changes

	output reg  [1:0]  rmii_txd,
	output reg         rmii_tx_en,
	output wire        busy
);

	localparam MIN_PAYLOAD = 11'd60;   // before the FCS
	localparam IPG_BYTES   = 11'd12;

	localparam S_IDLE = 3'd0, S_PRE = 3'd1, S_DATA = 3'd2,
	           S_FCS  = 3'd3, S_GAP = 3'd4;

	reg [2:0]  state;
	reg [1:0]  dibit;
	reg [10:0] bytecnt;
	reg [10:0] padded_len;
	reg [7:0]  cur;
	reg [31:0] fcs_reg;

	assign busy = (state != S_IDLE);

	wire byte_done = (dibit == 2'd3);

	// --- FCS over the data bytes, padding included --------------------------
	reg         crc_init, crc_en;
	reg  [7:0]  crc_data;
	wire [31:0] crc_fcs;

	eth_crc32 u_crc (
		.clk      (clk),
		.rst_n    (~rst),
		.init     (crc_init),
		.en       (crc_en),
		.data_in  (crc_data),
		.crc      (),
		.fcs      (crc_fcs),
		.fcs_next ()
	);

	// The byte loaded at the end of slot `bytecnt` is the one for slot
	// bytecnt+1, so the padding test has to look one ahead. Testing `bytecnt`
	// here instead lets one stale buffer byte through as the first pad byte.
	wire [7:0] src_byte = ((bytecnt + 11'd1) < length) ? rd_data : 8'h00;

	always @(posedge clk) begin
		crc_init <= 1'b0;
		crc_en   <= 1'b0;

		if (rst) begin
			state      <= S_IDLE;
			rmii_tx_en <= 1'b0;
			rmii_txd   <= 2'b00;
			dibit      <= 2'd0;
			rd_addr    <= 11'd0;
		end else begin
			case (state)
			S_IDLE: begin
				rmii_tx_en <= 1'b0;
				rmii_txd   <= 2'b00;
				dibit      <= 2'd0;
				bytecnt    <= 11'd0;
				rd_addr    <= 11'd0;
				if (start) begin
					state      <= S_PRE;
					crc_init   <= 1'b1;
					cur        <= 8'h55;
					padded_len <= (length < MIN_PAYLOAD) ? MIN_PAYLOAD : length;
				end
			end

			S_PRE: begin
				rmii_tx_en <= 1'b1;
				rmii_txd   <= cur[2*dibit +: 2];
				dibit      <= dibit + 2'd1;
				if (byte_done) begin
					bytecnt <= bytecnt + 11'd1;
					// Seven 0x55 then the SFD, then straight into the data. The
					// first payload byte is already waiting at rd_addr 0.
					if (bytecnt == 11'd6)      cur <= 8'hD5;
					else if (bytecnt == 11'd7) begin
						state   <= S_DATA;
						bytecnt <= 11'd0;
						rd_addr <= 11'd1;      // prefetch byte 1
						cur     <= rd_data;    // byte 0, fetched during preamble
					end
				end
			end

			S_DATA: begin
				rmii_tx_en <= 1'b1;
				rmii_txd   <= cur[2*dibit +: 2];
				dibit      <= dibit + 2'd1;

				if (dibit == 2'd0) begin
					crc_en   <= 1'b1;          // fold this byte in, once
					crc_data <= cur;
				end

				if (byte_done) begin
					if (bytecnt + 11'd1 == padded_len) begin
						state   <= S_FCS;
						bytecnt <= 11'd0;
					end else begin
						bytecnt <= bytecnt + 11'd1;
						cur     <= src_byte;
						// Stop walking the buffer once we are into padding, so
						// rd_addr cannot run off the end.
						if (bytecnt + 11'd2 < length) rd_addr <= bytecnt + 11'd2;
					end
				end
			end

			S_FCS: begin
				rmii_tx_en <= 1'b1;
				// The FCS goes out least-significant byte first, and eth_crc32
				// already presents it in that order.
				if (bytecnt == 11'd0 && dibit == 2'd0) fcs_reg <= crc_fcs;
				rmii_txd <= (bytecnt == 11'd0 && dibit == 2'd0)
				            ? crc_fcs[1:0]
				            : fcs_reg[8*bytecnt + 2*dibit +: 2];
				dibit <= dibit + 2'd1;
				if (byte_done) begin
					if (bytecnt == 11'd3) begin
						state   <= S_GAP;
						bytecnt <= 11'd0;
					end else bytecnt <= bytecnt + 11'd1;
				end
			end

			S_GAP: begin
				rmii_tx_en <= 1'b0;
				rmii_txd   <= 2'b00;
				dibit      <= dibit + 2'd1;
				if (byte_done) begin
					if (bytecnt == IPG_BYTES - 11'd1) state <= S_IDLE;
					else bytecnt <= bytecnt + 11'd1;
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
