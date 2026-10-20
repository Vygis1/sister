//////////////////////////////////////////////////////////////////////////////////
// pc_disk.v - the PC's hard disk, served by the ESP32 from an image on its SD card.
//
// To ao486's IDE controller (soc/ide.v) this is the SD-card driver it was written for
// (486Tang's driver_sd: four registers and a stream of words), so the controller is untouched:
//   0  write: where the data goes (ignored: it is always the controller's own FIFO)
//      read:  status -- 2 idle, 3 reading, 4 writing (0 initialising)
//   1  the sector                 2  how many            3  1 init, 2 read, 3 write
//   and a read of register 2 while idle takes the "mutex" the controller asks for first.
// A read's sectors go to the controller as writes into its FIFO (128 words a sector); a
// write's come from it as reads, one every other clock (it counts a held read once).
//
// To the ESP32 it is a request and a buffer of eight sectors (4 kB):
//   req   {valid, write, -, count in this piece (1-8), -}  and the sector it starts at
//   the ESP32, for a read, puts the piece in the buffer and says done; for a write, takes it
//   out of the buffer and says done. Pieces of eight until the controller's count is met.
// Read ahead: the ESP32 fills the buffer with eight sectors from the one asked for and says how many;
// the buffer remembers which they are, and a read of a sector it holds -- the controller asks for one
// sector at a time, and DOS reads a file a sector after the next -- is answered from it, without a
// round trip to the ESP32 (~1 ms each, measured: 14 s of Doom's 49 s start). A write empties it.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module pc_disk (
	input  wire        clk,
	input  wire        rst,

	// the IDE controller's SD master (driver_sd's slave side)
	input  wire [1:0]  avs_address,
	input  wire        avs_read,
	output wire [31:0] avs_readdata,
	input  wire        avs_write,
	input  wire [31:0] avs_writedata,
	// ...and the data: into its FIFO (sd_slave_write) or out of it (sd_slave_read)
	output reg         d_write,
	output reg  [31:0] d_writedata,
	output reg         d_read,
	input  wire [31:0] d_readdata,

	// the ESP32
	output wire [31:0] h_req,          // {valid, write, 10'd0, count[3:0], 16'd0}
	output wire [31:0] h_lba,
	input  wire        h_done,         // a write of DSK_DONE
	input  wire [3:0]  h_done_n,       // ...its value: how many sectors the ESP32 put in the buffer (0: as asked)
	input  wire [9:0]  h_buf_addr,     // the buffer, a word at a time
	input  wire        h_buf_we,
	input  wire [31:0] h_buf_wdata,
	output reg  [31:0] h_buf_rdata
);
	// --- the registers (avalon_slave.v's behaviour) -------------------------------------------
	reg [31:0] sector, count;
	reg [2:0]  status;
	reg [2:0]  mutex;
	localparam ST_INIT = 3'd0, ST_IDLE = 3'd2, ST_READ = 3'd3, ST_WRITE = 3'd4;
	wire idle = (status == ST_IDLE) || (status == ST_INIT);
	assign avs_readdata = (avs_address == 2'd0) ? {29'd0, status} : {29'd0, mutex};
	reg finished;
	always @(posedge clk) begin
		if (rst) mutex <= 3'd0;
		else if (mutex == 3'd0 && avs_read && avs_address != 2'd0) mutex <= {1'b0, avs_address};
		else if (mutex < 3'd4 && avs_write && avs_address == 2'd3) mutex <= 3'd4;
		else if (finished) mutex <= 3'd0;
	end

	// --- the buffer: 1024 words, the ESP32 on one port, the stream on the other -----------------
	reg [31:0] buf_mem [0:1023];
	reg  [9:0] b_addr; reg b_we; reg [31:0] b_wdata, b_q;
	always @(posedge clk) begin
		if (h_buf_we) buf_mem[h_buf_addr] <= h_buf_wdata;
		h_buf_rdata <= buf_mem[h_buf_addr];
	end
	always @(posedge clk) begin
		if (b_we) buf_mem[b_addr] <= b_wdata;
		b_q <= buf_mem[b_addr];
	end

	// --- the operation --------------------------------------------------------------------------
	reg        req_v, req_w;
	reg  [3:0] req_n;
	reg [31:0] req_lba;
	reg [31:0] left;                  // sectors of the controller's count not yet done
	reg  [9:0] wi;                    // words moved in this piece
	reg  [3:0] st;
	localparam S_IDLE = 4'd0, S_RREQ = 4'd1, S_RWAIT = 4'd2, S_RSEND = 4'd3, S_RSEND2 = 4'd4, S_RNEXT = 4'd5,
	           S_WTAKE = 4'd6, S_WTAKE2 = 4'd7, S_WTAKE3 = 4'd8, S_WREQ = 4'd9, S_WWAIT = 4'd10, S_DONE = 4'd11;
	assign h_req = {req_v, req_w, 10'd0, req_n, 16'd0};
	assign h_lba = req_lba;
	wire [3:0] piece = (left > 32'd8) ? 4'd8 : left[3:0];
	reg        ra_v;                  // the buffer holds sectors ra_lba .. ra_lba + ra_n - 1
	reg [31:0] ra_lba;
	reg  [3:0] ra_n;
	wire [31:0] ra_off = req_lba - ra_lba;
	wire       ra_hit = ra_v && req_lba >= ra_lba && ra_off < {28'd0, ra_n};
	wire [3:0] ra_avail = ra_n - ra_off[3:0];
	wire [3:0] ra_take = ({28'd0, ra_avail} < left) ? ra_avail : left[3:0];

	always @(posedge clk) begin
		d_write <= 1'b0; d_read <= 1'b0; b_we <= 1'b0; finished <= 1'b0;
		if (rst) begin
			status <= ST_INIT; st <= S_IDLE; req_v <= 1'b0; sector <= 32'd0; count <= 32'd0; ra_v <= 1'b0;
		end else begin
			if (avs_write && idle) case (avs_address)
				2'd1: sector <= avs_writedata;
				2'd2: count  <= avs_writedata;
				default: ;
			endcase
			case (st)
			S_IDLE: begin
				if (status == ST_INIT) begin status <= ST_IDLE; finished <= 1'b1; end      // (the card's init: nothing to do)
				else if (avs_write && avs_address == 2'd3 && idle) begin
					case (avs_writedata[1:0])
					2'd1: begin status <= ST_IDLE; finished <= 1'b1; end
					2'd2: begin status <= ST_READ;  left <= (count == 32'd0) ? 32'd1 : count; req_lba <= sector; st <= S_RREQ; end
					2'd3: begin status <= ST_WRITE; left <= (count == 32'd0) ? 32'd1 : count; req_lba <= sector; wi <= 10'd0; st <= S_WTAKE; ra_v <= 1'b0; end
					default: ;
					endcase
				end
			end
			// a read: ask for a piece, wait for it, stream it to the controller, the next
			S_RREQ: begin
				if (ra_hit) begin                                              // (in the buffer already)
					req_n <= ra_take; wi <= 10'd0; b_addr <= {ra_off[2:0], 7'd0}; st <= S_RSEND;
				end else begin req_v <= 1'b1; req_w <= 1'b0; req_n <= piece; st <= S_RWAIT; end
			end
			S_RWAIT: if (h_done) begin
				req_v <= 1'b0; wi <= 10'd0; b_addr <= 10'd0; st <= S_RSEND;
				ra_v <= 1'b1; ra_lba <= req_lba; ra_n <= (h_done_n == 4'd0 || h_done_n > 4'd8) ? req_n : h_done_n;
			end
			S_RSEND: begin b_addr <= b_addr + 10'd1; st <= S_RSEND2; end                   // (b_q a clock behind)
			S_RSEND2: begin
				d_write <= 1'b1; d_writedata <= b_q;
				b_addr <= b_addr + 10'd1; wi <= wi + 10'd1;
				if (wi == {req_n, 7'd0} - 10'd1) st <= S_RNEXT;
			end
			S_RNEXT: begin
				req_lba <= req_lba + {28'd0, req_n};
				if (left == {28'd0, req_n}) st <= S_DONE;
				else begin left <= left - {28'd0, req_n}; st <= S_RREQ; end
			end
			// a write: take a piece from the controller (a read, its word a clock later, and a clock
			// apart -- the controller counts a held read once), hand it to the ESP32, the next
			S_WTAKE:  begin d_read <= 1'b1; st <= S_WTAKE2; end
			S_WTAKE2: st <= S_WTAKE3;
			S_WTAKE3: begin
				b_we <= 1'b1; b_addr <= wi; b_wdata <= d_readdata; wi <= wi + 10'd1;
				if (wi == {piece, 7'd0} - 10'd1) begin req_v <= 1'b1; req_w <= 1'b1; req_n <= piece; st <= S_WWAIT; end
				else st <= S_WTAKE;
			end
			S_WWAIT: if (h_done) begin
				req_v <= 1'b0; req_lba <= req_lba + {28'd0, req_n}; wi <= 10'd0;
				if (left == {28'd0, req_n}) st <= S_DONE;
				else begin left <= left - {28'd0, req_n}; st <= S_WTAKE; end
			end
			S_DONE: begin status <= ST_IDLE; finished <= 1'b1; st <= S_IDLE; end
			default: st <= S_IDLE;
			endcase
		end
	end
endmodule

`default_nettype wire
