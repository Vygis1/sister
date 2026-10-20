//////////////////////////////////////////////////////////////////////////////////
// cd_feed.v - the ESP32's way of handing the PlayStation its disc, over the
//             same four SPI wires the shell uses to take a core.
//
// The ESP32 is the SPI master and it has the image (on its card); the console
// image of the FPGA answers with the same signature and status frame the shell
// does, so the sketch can tell which it is talking to, and two commands more:
//
//   CMD_CD_STATUS  0x30   reply: A5 VERSION CORE_ID busy, then
//                         [4] disc_in [5] running [6] room
//                         [7..9] the LBA wanted next, big-endian
//   CMD_CD_SECTOR  0x31   payload: LBA (3 bytes, big-endian) then 2352 bytes of
//                         the raw sector; taken when chip select rises with all
//                         of it in and the LBA is the one the drive wants
//   CMD_CD_DISC    0x32   payload: 1 byte: 1 = a disc is in the drive (the
//                         ESP32 has an image to serve), 0 = the tray is empty
//
// The ESP32 polls status every millisecond or so, and while `running` it sends
// the wanted sector whenever `room` is not zero -- the drive says which one, so
// nothing is negotiated. A frame that stops short (chip select rises early) is
// dropped without a trace; the next status names the same sector again.
//
// Bytes off the wire go straight into the drive's ring (sb_we) as they arrive:
// the ring slot is the drive's, and a short frame leaves a half-written slot
// that the next full frame writes over. At 10 MHz a sector frame is 1.9 ms,
// which against the 6.7 ms a double-speed sector takes leaves the wire mostly
// idle for the shell-style status frames in between.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module cd_feed #(
	parameter [7:0] VERSION = 8'd1,
	parameter [7:0] CORE_ID = 8'h50      // 'P': the PlayStation console image
)(
	input  wire        clk,
	input  wire        rst,
	// the pins
	input  wire        spi_sclk,
	input  wire        spi_mosi,
	output wire        spi_miso,
	input  wire        spi_cs_n,
	// the drive (ps1_cdrom.v)
	input  wire [23:0] fill_lba,
	input  wire [3:0]  fill_room,
	input  wire        fill_run,
	output reg         disc_in,
	output reg         sb_we,
	output reg  [11:0] sb_addr,
	output reg  [7:0]  sb_data,
	output reg         sb_done,
	output reg  [23:0] sb_lba,
	// for a debug register
	output reg  [31:0] sectors_in,     // sectors accepted since reset
	output reg  [15:0] frames_short    // sector frames that stopped early
);
	wire        frame_start, frame_end, rx_stb;
	wire [7:0]  rx_byte;
	wire [23:0] rx_index;
	reg  [7:0]  tx_byte;
	esp_link u_link (
		.clk(clk), .rst(rst),
		.spi_sclk(spi_sclk), .spi_mosi(spi_mosi), .spi_miso(spi_miso), .spi_cs_n(spi_cs_n),
		.spi_d1(1'b0), .spi_d2(1'b0), .spi_d3(1'b0), .spi_miso_t(),
		.frame_start(frame_start), .frame_end(frame_end),
		.rx_byte(rx_byte), .rx_stb(rx_stb), .rx_index(rx_index),
		.tx_byte(tx_byte)
	);
	localparam [7:0] CMD_PING = 8'h01, CMD_STATUS = 8'h02,
	                 CMD_CD_STATUS = 8'h30, CMD_CD_SECTOR = 8'h31, CMD_CD_DISC = 8'h32;
	reg [7:0]  cmd;
	reg [11:0] rn;                      // bytes received this frame (saturating)
	reg [23:0] lba_in;
	// the status snapshot is taken when the frame starts, so the reply is one
	// consistent picture rather than bytes from different clocks
	reg [23:0] st_lba; reg [3:0] st_room; reg st_run;

	// Combinational: the link needs the next byte ready within half an SPI
	// clock of the last one arriving. `rn` counts bytes RECEIVED; the byte
	// going out while rn == k is out-byte k (0 is the signature, sent by the
	// link itself).
	always @* begin
		case (rn)
		12'd1:   tx_byte = VERSION;
		12'd2:   tx_byte = CORE_ID;
		12'd3:   tx_byte = 8'd0;                       // busy: never, here
		12'd4:   tx_byte = {7'd0, disc_in};
		12'd5:   tx_byte = {7'd0, st_run};
		12'd6:   tx_byte = {4'd0, st_room};
		12'd7:   tx_byte = st_lba[23:16];
		12'd8:   tx_byte = st_lba[15:8];
		12'd9:   tx_byte = st_lba[7:0];
		default: tx_byte = 8'd0;
		endcase
	end

	always @(posedge clk) begin
		if (rst) begin
			cmd <= 8'd0; rn <= 12'd0; lba_in <= 24'd0; disc_in <= 1'b0;
			sb_we <= 1'b0; sb_addr <= 12'd0; sb_data <= 8'd0; sb_done <= 1'b0; sb_lba <= 24'd0;
			sectors_in <= 32'd0; frames_short <= 16'd0;
			st_lba <= 24'd0; st_room <= 4'd0; st_run <= 1'b0;
		end else begin
			sb_we <= 1'b0; sb_done <= 1'b0;
			if (frame_start) begin
				rn <= 12'd0; cmd <= 8'd0;
				st_lba <= fill_lba; st_room <= fill_room; st_run <= fill_run;
			end
			if (rx_stb) begin
				if (rn != 12'hFFF) rn <= rn + 12'd1;
				if (rx_index == 24'd0) cmd <= rx_byte;
				else case (cmd)
				CMD_CD_SECTOR: begin
					if (rx_index <= 24'd3)
						lba_in <= {lba_in[15:0], rx_byte};             // bytes 1..3: the LBA
					else if (rx_index <= 24'd2355) begin               // bytes 4..2355: the sector
						sb_we <= 1'b1; sb_addr <= rx_index[11:0] - 12'd4; sb_data <= rx_byte;
					end
				end
				CMD_CD_DISC: if (rx_index == 24'd1) disc_in <= rx_byte[0];
				default: ;
				endcase
			end
			if (frame_end && cmd == CMD_CD_SECTOR) begin
				if (rn == 12'd2356) begin
					sb_done <= 1'b1; sb_lba <= lba_in;
					sectors_in <= sectors_in + 32'd1;
				end else
					frames_short <= frames_short + 16'd1;
			end
		end
	end
endmodule

`default_nettype wire
