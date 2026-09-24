`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_rmii - loop rmii_tx straight into rmii_rx and see if the frame survives.
//
// This is a strong self-test despite being a loopback. The transmitter computes
// an FCS and the receiver validates it by residue, so the two agree only if the
// CRC polynomial, the bit ordering, the preamble hunt, the four-byte FCS delay
// line and the residue constant are ALL right. Any one of them wrong and crc_ok
// goes low.
//
// The corrupted-frame case matters just as much: a receiver that reports crc_ok
// unconditionally would pass the first test and fail this one.
//////////////////////////////////////////////////////////////////////////////////

module tb_rmii;

	reg clk = 0;
	reg rst = 1;
	always #10 clk = ~clk;          // 50 MHz

	integer errors = 0;

	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// --- frame source -------------------------------------------------------
	localparam FRAME_LEN = 42;      // an ARP-sized frame, below the 60 minimum
	reg [7:0] mem [0:127];
	integer i;

	wire [10:0] rd_addr;
	reg  [7:0]  rd_data;
	always @(posedge clk) rd_data <= mem[rd_addr[6:0]];

	// --- DUTs ---------------------------------------------------------------
	reg         start = 0;
	reg  [10:0] length = FRAME_LEN;
	wire [1:0]  txd;
	wire        tx_en, tx_busy;

	rmii_tx u_tx (
		.clk(clk), .rst(rst),
		.start(start), .length(length),
		.rd_addr(rd_addr), .rd_data(rd_data),
		.rmii_txd(txd), .rmii_tx_en(tx_en), .busy(tx_busy)
	);

	// The corruption switch flips one dibit mid-frame, which is what a real bit
	// error looks like to the receiver.
	reg corrupt = 0;
	reg [15:0] dibit_count = 0;
	always @(posedge clk) if (tx_en) dibit_count <= dibit_count + 1;
	wire [1:0] rxd_in = (corrupt && dibit_count == 16'd80) ? ~txd : txd;

	wire [7:0]  rx_data;
	wire        rx_valid, rx_sof, rx_eof, rx_crc_ok;
	wire [10:0] rx_length;

	// Emulate the PHY's end-of-packet behaviour: carrier toggling at 25 MHz
	// while receive data stays valid. A receiver that ends the frame on any low
	// will truncate and fail CRC.
	// The toggle is locked to the nibble boundary of the data the PHY is
	// sending, so it is driven from the transmitter's own dibit counter:
	// asserted for dibits 0 and 2, de-asserted for 1 and 3. It also only
	// happens once carrier is lost, never during the preamble, so it is held
	// off until the frame is well underway (the preamble is 32 dibits).
	// rmii_txd is registered, so the dibit sitting on the wire this cycle is the
	// one the transmitter indexed last cycle. Carrier has to be aligned to the
	// wire, not to the counter, or the emulated toggle lands half a nibble out.
	reg toggle_crs = 0;
	reg tx_dibit0_d = 0;
	always @(posedge clk) tx_dibit0_d <= u_tx.dibit[0];
	wire crs_in = tx_en &&
	              ((toggle_crs && dibit_count > 16'd40) ? (tx_dibit0_d == 1'b0)
	                                                    : 1'b1);

	rmii_rx u_rx (
		.clk(clk), .rst(rst),
		.rmii_rxd(rxd_in), .rmii_crs_dv(crs_in),
		.data(rx_data), .valid(rx_valid), .sof(rx_sof), .eof(rx_eof),
		.crc_ok(rx_crc_ok), .length(rx_length)
	);

	// --- capture ------------------------------------------------------------
	reg [7:0] got [0:127];
	integer   ngot = 0;
	reg       saw_eof = 0;
	reg       eof_crc_ok = 0;
	reg [10:0] eof_length = 0;
	integer   nsof = 0;

	always @(posedge clk) begin
		if (rx_valid) begin
			if (ngot < 128) got[ngot] = rx_data;
			ngot = ngot + 1;
			if (rx_sof) nsof = nsof + 1;
		end
		if (rx_eof) begin
			saw_eof    = 1;
			eof_crc_ok = rx_crc_ok;
			eof_length = rx_length;
		end
	end

	task send_frame;
		begin
			ngot = 0; saw_eof = 0; nsof = 0; dibit_count = 0;
			@(posedge clk); start = 1;
			@(posedge clk); start = 0;
			wait (tx_busy);
			wait (!tx_busy);
			repeat (20) @(posedge clk);
		end
	endtask

	initial begin
		for (i = 0; i < 128; i = i + 1) mem[i] = 8'h00;
		// Something that exercises every bit position rather than a flat ramp.
		for (i = 0; i < FRAME_LEN; i = i + 1) mem[i] = (i * 8'h3B) ^ 8'hA5;

		repeat (5) @(posedge clk);
		rst = 0;
		repeat (5) @(posedge clk);

		$display("tb_rmii");
		$display(" clean frame:");
		corrupt = 0;
		send_frame;

		check(saw_eof, "receiver reported end of frame");
		check(eof_crc_ok, "FCS validated (residue constant is correct)");
		check(nsof == 1, "exactly one start-of-frame");
		// The transmitter pads to the 60-byte minimum, so that is what arrives.
		check(ngot == 60, "60 bytes received (42 payload + 18 padding)");
		check(eof_length == 60, "length output agrees with the byte count");

		begin : payload_check
			integer bad;
			bad = 0;
			for (i = 0; i < FRAME_LEN; i = i + 1)
				if (got[i] !== mem[i]) bad = bad + 1;
			check(bad == 0, "payload bytes survived the round trip");
			if (bad != 0)
				for (i = 0; i < FRAME_LEN; i = i + 1)
					if (got[i] !== mem[i])
						$display("       byte %0d: sent %02h got %02h", i, mem[i], got[i]);
		end

		begin : padding_check
			integer bad;
			bad = 0;
			for (i = FRAME_LEN; i < 60; i = i + 1)
				if (got[i] !== 8'h00) bad = bad + 1;
			check(bad == 0, "padding is zeros");
		end

		$display(" carrier toggling at end of packet:");
		corrupt = 0; toggle_crs = 1;
		send_frame;
		check(saw_eof, "frame still ended");
		check(eof_crc_ok, "FCS still validated through the carrier toggle");
		check(ngot == 60, "no bytes lost to the toggle");
		toggle_crs = 0;

		$display(" corrupted frame:");
		corrupt = 1;
		send_frame;
		check(saw_eof, "receiver still reported end of frame");
		check(!eof_crc_ok, "FCS rejected (crc_ok is not stuck high)");

		$display("");
		if (errors == 0) $display("tb_rmii: all checks passed");
		else             $display("tb_rmii: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		#2_000_000;
		$display("FAIL timeout");
		$finish;
	end

endmodule
