//////////////////////////////////////////////////////////////////////////////////
// esp_bus.v - the ESP32 as a second master on the console image's register bus:
// everything the PC does over Ethernet (load a cartridge, read the pads, write the
// menu's text), done over the four SPI wires instead.
//
// Frames, through esp_link (byte 0 out is always the signature A5):
//   CMD_PING / CMD_STATUS  01 / 02   reply: A5 VERSION CORE_ID busy -- as the shell's,
//                                   so the sketch tells a core from the shell the
//                                   same way
//   CMD_BUS_WRITE  40   address (4 bytes, big-endian), then words of 4 bytes, each
//                       little-endian; the address goes up by 4 a word. A word goes
//                       onto the bus when its fourth byte is in (3.2 us a word at
//                       10 MHz: the bus takes a few clocks).
//   CMD_BUS_READ   41   address (4 bytes, big-endian), 4 bytes of anything (the read
//                       happens meanwhile), then the word comes back little-endian
//                       in out-bytes 9..12.
//   CMD_BUS_RDBLK  42   the same, and on: word after word (address up by 4) for as
//                       long as chip select stays low -- each one read while the one
//                       before it goes out. What the ESP32 checks a game load with.
//
// The bus side holds its request until the acknowledge, like net_core's.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module esp_bus #(
	parameter [7:0] VERSION = 8'd1,
	parameter [7:0] CORE_ID = 8'h43      // 'C': a console image
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        spi_sclk,
	input  wire        spi_mosi,
	output wire        spi_miso,
	input  wire        spi_cs_n,
	// the bus (a master)
	output reg  [31:0] bus_addr,
	output reg  [31:0] bus_wdata,
	output reg         bus_we,
	output reg         bus_re,
	input  wire [31:0] bus_rdata,
	input  wire        bus_ack,
	output reg  [7:0]  cmd               // this frame's command (another slave on the wires answers some)
);
	wire        frame_start, frame_end, rx_stb;
	wire [7:0]  rx_byte;
	wire [23:0] rx_index;
	reg  [7:0]  tx_byte;
	esp_link u_link (
		.clk(clk), .rst(rst),
		.spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
		.frame_start(frame_start), .frame_end(frame_end),
		.rx_byte(rx_byte), .rx_stb(rx_stb), .rx_index(rx_index),
		.tx_byte(tx_byte)
	);
	localparam [7:0] CMD_PING = 8'h01, CMD_STATUS = 8'h02, CMD_BUS_WRITE = 8'h40, CMD_BUS_READ = 8'h41,
	                 CMD_BUS_RDBLK = 8'h42;

	reg [15:0] rn;                       // bytes received this frame (saturating)
	reg [31:0] sh;                       // bytes gathering
	reg [31:0] rword;                    // the word read
	reg [31:0] oword;                    // (block read) the word going out
	wire       busy = bus_we || bus_re;

	// out-byte rn (combinational: the link takes it within half an SPI clock)
	always @* begin
		case (cmd)
		CMD_PING, CMD_STATUS:
			case (rn)
			16'd1:   tx_byte = VERSION;
			16'd2:   tx_byte = CORE_ID;
			default: tx_byte = {7'd0, busy};
			endcase
		CMD_BUS_RDBLK:
			if (rn >= 16'd9)
				case (rn[1:0])            // out-bytes 9, 10, 11, 12 / 13, 14 ... : bytes 0..3 of each word
				2'd1:    tx_byte = oword[7:0];
				2'd2:    tx_byte = oword[15:8];
				2'd3:    tx_byte = oword[23:16];
				default: tx_byte = oword[31:24];
				endcase
			else tx_byte = {7'd0, busy};
		CMD_BUS_READ:
			case (rn)
			16'd9:   tx_byte = rword[7:0];
			16'd10:  tx_byte = rword[15:8];
			16'd11:  tx_byte = rword[23:16];
			16'd12:  tx_byte = rword[31:24];
			default: tx_byte = {7'd0, busy};
			endcase
		default: tx_byte = {7'd0, busy};
		endcase
	end

	always @(posedge clk) begin
		if (rst) begin
			cmd <= 8'd0; rn <= 16'd0; sh <= 32'd0; rword <= 32'd0; oword <= 32'd0;
			bus_addr <= 32'd0; bus_wdata <= 32'd0; bus_we <= 1'b0; bus_re <= 1'b0;
		end else begin
			if (bus_ack) begin
				if (bus_re) rword <= bus_rdata;
				bus_we <= 1'b0; bus_re <= 1'b0;
				if (bus_we) bus_addr <= bus_addr + 32'd4;
			end
			if (frame_start) rn <= 16'd0;
			else if (rx_stb) begin
				if (rn != 16'hFFFF) rn <= rn + 16'd1;
				sh <= {sh[23:0], rx_byte};
				if (rn == 16'd0) cmd <= rx_byte;
				// the address: bytes 1..4, big-endian
				if (rn == 16'd4 && (cmd == CMD_BUS_WRITE || cmd == CMD_BUS_READ || cmd == CMD_BUS_RDBLK)) begin
					bus_addr <= {sh[23:0], rx_byte};
					if (cmd != CMD_BUS_WRITE) bus_re <= 1'b1;
				end
				// a block read: at the end of each word's time the word read meanwhile goes out
				// next, and the one after it is asked for
				if (cmd == CMD_BUS_RDBLK && rn >= 16'd8 && rn[1:0] == 2'd0) begin
					oword <= rword;
					bus_addr <= bus_addr + 32'd4; bus_re <= 1'b1;
				end
				// a word of a write: bytes 5.., little-endian, on the bus at its fourth
				if (cmd == CMD_BUS_WRITE && rn >= 16'd5 && rn[1:0] == 2'd0) begin
					bus_wdata <= {rx_byte, sh[7:0], sh[15:8], sh[23:16]};
					bus_we <= 1'b1;
				end
			end
		end
	end
endmodule

`default_nettype wire
