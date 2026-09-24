`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_esp_link - drive the SPI slave the way an ESP32 would.
//
// The testbench is the master: it wiggles the four pins with real timing rather
// than poking the module's insides, because the thing most likely to be wrong is
// exactly the relationship between those pins and this clock. A bench that
// called a task on the shift register would prove nothing about that.
//
// The clock ratio is the one the design is specified at -- 50 MHz internal,
// 10 MHz SPI -- so the synchroniser is exercised at the speed it has to work at.
//////////////////////////////////////////////////////////////////////////////////

module tb_esp_link;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;                 // 50 MHz

	reg sclk = 0, mosi = 0, cs_n = 1;
	wire miso;

	wire        frame_start, frame_end, rx_stb;
	wire [7:0]  rx_byte;
	wire [23:0] rx_index;
	reg  [7:0]  tx_byte;

	esp_link dut (
		.clk(clk), .rst(rst),
		.spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(miso), .spi_cs_n(cs_n),
		.frame_start(frame_start), .frame_end(frame_end),
		.rx_byte(rx_byte), .rx_stb(rx_stb), .rx_index(rx_index),
		.tx_byte(tx_byte)
	);

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// --- what the board answers with ------------------------------------------
	// A stand-in for the real command decode: enough to prove that a reply
	// composed byte by byte comes out in the right order.
	reg [7:0] reply [0:7];
	integer   rn = 0;
	always @(posedge clk) begin
		if (frame_start) rn <= 0;
		else if (rx_stb) rn <= rn + 1;
	end
	always @* tx_byte = reply[rn[2:0]];

	// --- the master ------------------------------------------------------------
	// 10 MHz: 50 ns high, 50 ns low. Mode 0, so MOSI changes on the falling edge
	// and both ends sample on the rising one.
	reg [7:0] got;
	task spi_byte;
		input  [7:0] v;
		integer i;
		begin
			for (i = 7; i >= 0; i = i - 1) begin
				mosi = v[i];
				#50 sclk = 1;
				got = {got[6:0], miso};
				#50 sclk = 0;
			end
		end
	endtask

	integer i;
	reg [7:0] seen [0:15];
	integer   nseen = 0;
	always @(posedge clk) if (rx_stb) begin
		seen[rx_index[3:0]] = rx_byte;
		nseen = nseen + 1;
	end

	initial begin
		$display("tb_esp_link");
		for (i = 0; i < 8; i = i + 1) reply[i] = 8'hA5 + i[7:0];
		repeat (10) @(posedge clk);
		rst = 0;
		repeat (10) @(posedge clk);

		// --- a five-byte command -------------------------------------------
		cs_n = 0;
		#200;
		got = 8'd0;
		spi_byte(8'h11);   check(got == 8'hA5, "the first reply byte is the signature");
		spi_byte(8'h02);   check(got == 8'hA6, "and the second follows it");
		spi_byte(8'hDE);
		spi_byte(8'hAD);
		spi_byte(8'hBE);   check(got == 8'hA9, "and the fifth");
		#200 cs_n = 1;
		#500;

		$display("    received %0d bytes: %02x %02x %02x %02x %02x",
		         nseen, seen[0], seen[1], seen[2], seen[3], seen[4]);
		check(nseen == 5, "five bytes arrived");
		check(seen[0] == 8'h11, "the command byte is first");
		check(seen[1] == 8'h02, "then the payload, in order");
		check(seen[2] == 8'hDE && seen[3] == 8'hAD && seen[4] == 8'hBE,
		      "and the rest of it");

		// --- a second frame, to prove the index resets ----------------------
		nseen = 0;
		cs_n = 0;
		#200;
		spi_byte(8'h01);
		spi_byte(8'h7F);
		#200 cs_n = 1;
		#500;
		check(nseen == 2, "a second frame is two bytes, not seven");
		check(seen[0] == 8'h01 && seen[1] == 8'h7F,
		      "and it started counting from zero again");

		// --- a long one ------------------------------------------------------
		// Bitstream pages are 256 bytes and the index has to keep up past 255.
		nseen = 0;
		cs_n = 0;
		#200;
		for (i = 0; i < 300; i = i + 1) spi_byte(i[7:0]);
		#200 cs_n = 1;
		#500;
		check(nseen == 300, "three hundred bytes in one frame");
		check(dut.rx_index == 24'd300, "and the index counted every one");

		$display("");
		if (errors == 0) $display("tb_esp_link: all checks passed");
		else             $display("tb_esp_link: %0d FAIL(s)", errors);
		$finish;
	end

endmodule
