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
	parameter [7:0] SIGNATURE = 8'hA5,
	// The frames whose data comes four bits a clock, and how many bytes come before it a bit a clock
	// (the command and its address): esp_bus's bus write 0x43 (5); the shell's flash door gives its
	// page write 0x19 (4); the disc feed its sector 0x39 (4). 0: none.
	parameter [7:0] QCMD_A = 8'h43,
	parameter [4:0] QHDR_A = 5'd5,
	parameter [7:0] QCMD_B = 8'h00,
	parameter [4:0] QHDR_B = 5'd0
)(
	input  wire        clk,
	input  wire        rst,

	// --- the pins ---------------------------------------------------------
	input  wire        spi_sclk,
	input  wire        spi_mosi,
	output wire        spi_miso,
	input  wire        spi_cs_n,
	// quad: the data of a 0x43 frame (a bus write) four bits a clock, high nibble first, on MOSI (0),
	// MISO (1: let go meanwhile -- spi_miso_t), and two more wires (2, 3: the ESP32's WP and HD)
	input  wire        spi_d1,
	input  wire        spi_d2,
	input  wire        spi_d3,
	output wire        spi_miso_t,

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
	// SCLK and CS take an edge only when the level held two samples on each side: four wires
	// switching together (a quad write's data) put single-sample glitches on the clock wire, each one
	// an extra nibble (2026-10-17, quadtest: errors only with several wires switching at once). The
	// data are taken at the edge's first sample (stage 2), as the clock's level there.
	reg [4:0] sclk_s, cs_s;
	reg [2:0] mosi_s, d1_s, d2_s, d3_s;
	always @(posedge clk) begin
		sclk_s <= {sclk_s[3:0], spi_sclk};
		mosi_s <= {mosi_s[1:0], spi_mosi};
		cs_s   <= {cs_s[3:0],   spi_cs_n};
		d1_s   <= {d1_s[1:0],   spi_d1};
		d2_s   <= {d2_s[1:0],   spi_d2};
		d3_s   <= {d3_s[1:0],   spi_d3};
	end

	// A bit a clock: the edges as ever (two flops and the one compared against) -- MISO's answer
	// must be out by the master's next rising edge, and only MISO and MOSI switch then. A quad write's
	// data: a rise is two samples low then two high (a one-sample spike either way is no edge), the
	// data taken at its first high sample.
	wire sclk_rise = (sclk_s[2:1] == 2'b01);
	wire sclk_fall = (sclk_s[2:1] == 2'b10);
	wire qrise     = (sclk_s[4:1] == 4'b0011);
	wire cs_active = ~cs_s[2];
	wire cs_fell   = (cs_s[4:1] == 4'b1100);
	wire cs_rose   = (cs_s[4:1] == 4'b0011);

	// --- the shift registers -------------------------------------------------
	reg [7:0] shin;
	reg [7:0] shout;
	reg [2:0] bitn;
	reg       byte_done;      // the eighth bit is in; hand over on the next fall
	reg       quad_cmd;       // the frame is a quad write (its command byte QCMD_A or QCMD_B)
	reg [4:0] qhdr;           // ...and its header's length
	reg       quad;           // ...and its data has begun: four bits a clock, MISO let go
	reg       nib;            // (the second nibble of a byte is next)
	reg [3:0] hi;

	assign spi_miso   = shout[7];
	assign spi_miso_t = quad;

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
				quad_cmd    <= 1'b0; quad <= 1'b0; nib <= 1'b0;
				shout       <= SIGNATURE;
				rx_index    <= 24'd0;
				frame_start <= 1'b1;
			end else if (cs_rose) begin
				frame_end <= 1'b1; quad <= 1'b0;
			end else if (cs_active) begin
				if (quad) begin
					// (the byte's index moves on the clock after its strobe: the consumer reads it with it)
					if (byte_done) begin rx_index <= rx_index + 24'd1; byte_done <= 1'b0; end
					if (qrise) begin
						if (!nib) hi <= {d3_s[2], d2_s[2], d1_s[2], mosi_s[2]};
						else begin
							rx_byte   <= {hi, d3_s[2], d2_s[2], d1_s[2], mosi_s[2]};
							rx_stb    <= 1'b1;
							byte_done <= 1'b1;
						end
						nib <= ~nib;
					end
				end else if (sclk_rise) begin
					if (bitn == 3'd7 && rx_index == 24'd0) begin
						quad_cmd <= ({shin[6:0], mosi_s[1]} == QCMD_A && QCMD_A != 8'h00) || ({shin[6:0], mosi_s[1]} == QCMD_B && QCMD_B != 8'h00);
						qhdr     <= ({shin[6:0], mosi_s[1]} == QCMD_A) ? QHDR_A : QHDR_B;
					end
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
						if (quad_cmd && rx_index == {19'd0, qhdr} - 24'd1) quad <= 1'b1;   // (the header is in: the data comes quad)
					end else begin
						shout <= {shout[6:0], 1'b0};
					end
				end
			end
		end
	end

endmodule

`default_nettype wire
