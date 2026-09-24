//////////////////////////////////////////////////////////////////////////////////
// esp_link.v - the wire the ESP32 talks to the board over.
//
// Four pins and a byte stream. The ESP32 is the master because it is the thing
// with a Wi-Fi stack, an SD card and a person poking at it; the FPGA answers.
//
// --- why SPI and not the serial port -------------------------------------------
//
// Installing a core means moving a 1.9 MB bitstream. At 3 Mbaud -- an optimistic
// UART -- that is seven seconds, every time, with a progress bar. At 10 MHz SPI
// it is a second and a half, and the pins are already on the header. That is the
// entire argument.
//
// --- why 10 MHz and not 40 ------------------------------------------------------
//
// The ESP32 will go to 40 MHz and this will not, because the clock arrives
// asynchronously and has to be brought into the board's 50 MHz domain through
// two flip-flops before its edges can be found. Four clocks per SPI edge is the
// floor for that, which puts the ceiling near 12 MHz. 10 MHz is the round number
// below it. Quadrupling the speed would mean a clock-domain crossing on every
// bit rather than a synchroniser, and saving a second is not worth that.
//
// --- the shape of a transfer ----------------------------------------------------
//
// Chip select frames the whole thing. Byte 0 is the command, everything after it
// is payload, and the byte count is how the payload is addressed -- there is no
// length field, because the master already knows and chip select already says
// when it stops.
//
// Mode 0: the master changes MOSI on the falling edge, both ends sample on the
// rising edge. MISO is set up on the falling edge for the same reason, which
// means the byte being sent has to be ready one byte in advance. `tx_byte` is
// therefore what to send NEXT, not what to send now, and the consumer drives it
// from whatever it learned when the previous byte arrived.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module esp_link #(
	// The first byte of every reply, sent before the master has said what it
	// wants. A fixed value so "is the board alive and configured" is answerable
	// by clocking one byte, with no command and no state on either side.
	parameter [7:0] SIGNATURE = 8'hA5
)(
	input  wire        clk,
	input  wire        rst,

	// --- the pins ---------------------------------------------------------
	input  wire        spi_sclk,
	input  wire        spi_mosi,
	output wire        spi_miso,
	input  wire        spi_cs_n,

	// --- the byte stream ---------------------------------------------------
	output reg         frame_start,  // chip select fell: a command is coming
	output reg         frame_end,    // chip select rose: that was all of it
	output reg  [7:0]  rx_byte,
	output reg         rx_stb,       // one clock, rx_byte and rx_index are good
	output reg  [23:0] rx_index,     // 0 is the command byte
	input  wire [7:0]  tx_byte       // what to send for the byte AFTER this one
);

	// --- getting the pins into this clock domain ---------------------------
	// Three flops, not two. The first two remove metastability; the third is
	// what the edge detector compares against, and without it the "previous"
	// value would be a signal that is still settling.
	reg [2:0] sclk_s, mosi_s, cs_s;
	always @(posedge clk) begin
		sclk_s <= {sclk_s[1:0], spi_sclk};
		mosi_s <= {mosi_s[1:0], spi_mosi};
		cs_s   <= {cs_s[1:0],   spi_cs_n};
	end

	wire sclk_rise = (sclk_s[2:1] == 2'b01);
	wire sclk_fall = (sclk_s[2:1] == 2'b10);
	wire cs_active = ~cs_s[1];
	wire cs_fell   = (cs_s[2:1] == 2'b10);
	wire cs_rose   = (cs_s[2:1] == 2'b01);

	// --- the shift registers -------------------------------------------------
	reg [7:0] shin;
	reg [7:0] shout;
	reg [2:0] bitn;
	reg       byte_done;      // the eighth bit is in; hand over on the next fall

	assign spi_miso = shout[7];

	always @(posedge clk) begin
		if (rst) begin
			shin <= 8'd0; shout <= 8'd0; bitn <= 3'd0; byte_done <= 1'b0;
			rx_byte <= 8'd0; rx_stb <= 1'b0; rx_index <= 24'd0;
			frame_start <= 1'b0; frame_end <= 1'b0;
		end else begin
			rx_stb      <= 1'b0;
			frame_start <= 1'b0;
			frame_end   <= 1'b0;

			if (cs_fell) begin
				// A fresh frame. The consumer cannot have anything useful ready
				// yet -- it has not been told what is wanted -- so the first
				// byte out is the fixed signature rather than whatever happened
				// to be on tx_byte from the last frame.
				bitn        <= 3'd0;
				byte_done   <= 1'b0;
				shout       <= SIGNATURE;
				rx_index    <= 24'd0;
				frame_start <= 1'b1;
			end else if (cs_rose) begin
				frame_end <= 1'b1;
			end else if (cs_active) begin
				if (sclk_rise) begin
					shin <= {shin[6:0], mosi_s[1]};
					if (bitn == 3'd7) begin
						rx_byte   <= {shin[6:0], mosi_s[1]};
						rx_stb    <= 1'b1;
						byte_done <= 1'b1;
					end
					bitn <= bitn + 3'd1;
				end else if (sclk_fall) begin
					// The outgoing byte changes here rather than on the rising
					// edge, because MISO has to be settled BEFORE the master
					// samples it. A flag rather than `bitn == 0`, so that a
					// stray falling edge before the first bit of a frame cannot
					// be mistaken for a byte boundary.
					if (byte_done) begin
						shout     <= tx_byte;
						rx_index  <= rx_index + 24'd1;
						byte_done <= 1'b0;
					end else begin
						shout <= {shout[6:0], 1'b0};
					end
				end
			end
		end
	end

endmodule

`default_nettype wire
