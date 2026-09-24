//////////////////////////////////////////////////////////////////////////////////
// rmii_rx.v - RMII receive: dibits off the PHY into a checked byte stream.
//
// RMII carries two bits per 50 MHz clock, so a byte takes four clocks. A frame
// on the wire looks like:
//
//   55 55 55 55 55 55 55 D5 | dest(6) src(6) type(2) payload... | FCS(4)
//   \------- preamble ----/ ^SFD    \------- what we emit ------/
//
// We hunt for the start-of-frame delimiter rather than counting preamble bytes,
// because the first preamble byte is routinely clipped by the PHY and a
// fixed-length skip would then be off by one for the whole frame.
//
// The FCS is verified by feeding the data AND the trailing FCS through the CRC
// and checking the residue. A CRC32 that has consumed a correct frame plus its
// own FCS always lands on the same constant, which is cheaper than buffering
// four bytes to compare against.
//
// Bytes come out on the fly with no buffering. Whoever consumes them must accept
// a byte per four clocks without stalling: the wire cannot be paused.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module rmii_rx (
	input  wire       clk,          // 50 MHz REF_CLK from the PHY
	input  wire       rst,

	input  wire [1:0] rmii_rxd,
	input  wire       rmii_crs_dv,

	output reg  [7:0] data,
	output reg        valid,        // data is a payload byte this cycle
	output reg        sof,          // first byte of the frame
	output reg        eof,          // pulses one cycle after the last byte
	output reg        crc_ok,       // valid with eof
	output reg [10:0] length        // bytes emitted, excluding FCS
);

	// The residue a reflected CRC32 settles on after consuming a good frame
	// followed by its transmitted FCS. Checked against a real frame in tb_rmii.
	localparam [31:0] CRC_RESIDUE = 32'hDEBB20E3;

	localparam S_IDLE = 2'd0, S_PREAMBLE = 2'd1, S_DATA = 2'd2;

	reg [1:0]  state;
	reg [1:0]  dibit;               // which dibit of the current byte
	reg [7:0]  shifter;
	reg        crs_dv_d;

	// Dibits arrive least-significant first, so a byte assembles by shifting in
	// from the top.
	wire [7:0] byte_now = {rmii_rxd, shifter[7:2]};
	wire       byte_done = (dibit == 2'd3);
	wire       frame_end = (dibit == 2'd0) && !rmii_crs_dv;

	// --- FCS ----------------------------------------------------------------
	// The CRC must see every byte from the destination MAC through the FCS, so
	// it is fed from the raw byte assembly rather than from the gated output.
	// Driven combinationally, not registered. A registered enable would fold
	// each byte in one cycle late, so when carrier drops the final byte would
	// still be in flight and the residue check would run a byte early -- which
	// fails on every valid frame, not just corrupt ones.
	wire        crc_init = (state == S_IDLE) && rmii_crs_dv;
	// Not gated on crs_dv: during the end-of-packet toggle described below the
	// carrier is low for half of each nibble while the data is still valid.
	wire        crc_en   = (state == S_DATA) && byte_done;
	wire [7:0]  crc_data = byte_now;
	wire [31:0] crc_val;

	eth_crc32 u_crc (
		.clk      (clk),
		.rst_n    (~rst),
		.init     (crc_init),
		.en       (crc_en),
		.data_in  (crc_data),
		.crc      (crc_val),
		.fcs      (),
		.fcs_next ()
	);

	// The four FCS bytes trail every frame, so the byte count and the emitted
	// stream both have to run four bytes behind what has been assembled.
	reg [7:0]  d1, d2, d3, d4;
	reg [2:0]  fill;                // how many of the delay stages are loaded

	always @(posedge clk) begin
		valid    <= 1'b0;
		sof      <= 1'b0;
		eof      <= 1'b0;
		crs_dv_d <= rmii_crs_dv;

		if (rst) begin
			state  <= S_IDLE;
			dibit  <= 2'd0;
			fill   <= 3'd0;
			length <= 11'd0;
			crc_ok <= 1'b0;
		end else begin
			case (state)
			S_IDLE: begin
				dibit  <= 2'd0;
				fill   <= 3'd0;
				length <= 11'd0;
				if (rmii_crs_dv) state <= S_PREAMBLE;
			end

			S_PREAMBLE: begin
				if (!rmii_crs_dv) begin
					state <= S_IDLE;         // carrier dropped mid-preamble
				end else begin
					shifter <= byte_now;
					dibit   <= dibit + 2'd1;
					// Watch continuously rather than only on byte boundaries:
					// the alignment of the preamble is not known until the SFD
					// has actually been seen.
					if (byte_now == 8'hD5) begin
						state <= S_DATA;
						dibit <= 2'd0;
					end
				end
			end

			S_DATA: begin
				// End of frame is only ever evaluated on a byte boundary.
				//
				// RMII does not simply drop CRS_DV at the end of a packet. When
				// carrier is lost but receive data is still valid, the PHY
				// TOGGLES CRS_DV at 25 MHz -- asserted for the first dibit of
				// each nibble, de-asserted for the second. Treating any low as
				// end-of-frame truncates real frames mid-flight and fails every
				// CRC, while a testbench driving carrier cleanly never notices.
				//
				// At dibit 0 the toggle is always in its asserted half, so a low
				// seen there is a genuine end of packet.
				if (frame_end) begin
					// Frame over. The last four bytes held in the delay line are
					// the FCS, which the CRC has already absorbed.
					state  <= S_IDLE;
					eof    <= 1'b1;
					crc_ok <= (crc_val == CRC_RESIDUE) && (fill == 3'd4);
				end else begin
					shifter <= byte_now;
					dibit   <= dibit + 2'd1;

					if (byte_done) begin
						// Push through a four-deep delay so the FCS never
						// reaches the consumer.
						d1 <= byte_now;
						d2 <= d1;
						d3 <= d2;
						d4 <= d3;

						if (fill == 3'd4) begin
							data   <= d4;
							valid  <= 1'b1;
							sof    <= (length == 11'd0);
							length <= length + 11'd1;
						end else begin
							fill <= fill + 3'd1;
						end
					end
				end
			end

			default: state <= S_IDLE;
			endcase
		end
	end

endmodule

`default_nettype wire
