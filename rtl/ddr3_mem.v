//////////////////////////////////////////////////////////////////////////////////
// ddr3_mem.v - the line interface everything here speaks, on top of MIG.
//
// Two jobs, and they are separable but not separate:
//
//   1. turn "give me the 128-bit line at L" into MIG's app_* handshake
//   2. cross from the console's 50 MHz to the controller's 83 MHz user clock
//
// --- the address ------------------------------------------------------------------
//
// `app_addr` counts 16-BIT WORDS, not bytes and not lines. One transaction at a
// 4:1 PHY ratio moves a burst of eight of them -- 128 bits, 16 bytes -- so
// consecutive lines are eight apart:
//
//     app_addr = line * 8
//
// Getting this wrong does not fail: it reads real memory at the wrong place, so
// a cartridge loads and the machine runs and executes somebody else's bytes.
// That is why it is stated here rather than left in a shift.
//
// --- several at a time -----------------------------------------------------------
//
// This used to take one line at a time: request, wait for the answer, then the
// next may start. Measured on the board that ceiling is about a million
// accesses a second, and the PlayStation's drawing engine alone wanted 991,096
// of them -- 99% of everything the memory could do. It could get a quarter of
// the BIOS menu drawn per frame, the machine swapped buffers regardless, and
// the picture arrived in four instalments. That is what the flicker was.
//
// So requests now queue. The console side pushes into a queue and carries on as
// long as there is room; the controller side takes them as fast as MIG will
// accept, and read data comes back in a second queue. MIG returns read data in
// the order the commands were given, which is what lets the arbiter above match
// each line to the client that asked -- it already keeps that order (see
// mem_arb.v), so nothing above here changes.
//
// Writes produce no completion. A client counting lines back must not be handed
// one for a write, and the queue on the return path only ever sees reads.
//
// --- the crossing ---------------------------------------------------------------------
//
// Two Gray-pointer queues, one each way (see async_fifo.v). The toggle
// handshake that was here before could not carry more than one transaction by
// construction, which was the point of it and is now the problem with it.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ddr3_mem #(
	parameter AW = 24               // line address: 24 bits of 16 bytes = 256 MB
)(
	// --- the console's side ------------------------------------------------------
	input  wire            clk,
	input  wire            rst,
	input  wire [AW-1:0]   m_addr,
	input  wire            m_req,
	input  wire            m_we,
	input  wire [127:0]    m_wdata,
	input  wire [15:0]     m_wmask,      // bytes that land; the rest are left alone
	output wire            m_ready,
	output reg  [127:0]    m_rdata,
	output reg             m_valid,
	output wire            m_calibrated,

	// --- the controller's side -----------------------------------------------------
	input  wire            ui_clk,
	input  wire            ui_rst,
	input  wire            calib_done,

	output reg  [27:0]     app_addr,
	output reg  [2:0]      app_cmd,
	output reg             app_en,
	input  wire            app_rdy,

	output reg  [127:0]    app_wdf_data,
	output reg             app_wdf_wren,
	output reg             app_wdf_end,
	output reg  [15:0]     app_wdf_mask,
	input  wire            app_wdf_rdy,

	input  wire [127:0]    app_rd_data,
	input  wire            app_rd_data_valid
);

	localparam CMD_WRITE = 3'd0, CMD_READ = 3'd1;

	// Every byte of every line is written. Nothing here does partial writes:
	// clients deal in whole lines, which is what let the interface stay this
	// simple in the first place.

	// --- calibration, seen from the console's clock -------------------------
	reg [1:0] calib_sync;
	always @(posedge clk) calib_sync <= {calib_sync[0], calib_done};
	assign m_calibrated = calib_sync[1];

	// --- the queue of things to do ------------------------------------------
	wire               rq_full, rq_empty;
	wire [AW+144:0]    rq_dout;
	wire [15:0]        rq_wmask = rq_dout[AW+144:AW+129];
	wire               rq_we    = rq_dout[AW+128];
	wire [AW-1:0]      rq_addr  = rq_dout[AW+127:128];
	wire [127:0]       rq_wdata = rq_dout[127:0];
	reg                rq_take;

	assign m_ready = !rq_full && calib_sync[1];

	async_fifo #(.WIDTH(AW+145), .AW(3)) u_reqq (
		.wr_clk(clk),    .wr_rst(rst),    .wr_en(m_req && m_ready),
		.wr_data({m_wmask, m_we, m_addr, m_wdata}), .wr_full(rq_full),
		.rd_clk(ui_clk), .rd_rst(ui_rst), .rd_en(rq_take),
		.rd_data(rq_dout), .rd_empty(rq_empty)
	);

	// --- and the lines coming back ------------------------------------------
	wire        rs_full, rs_empty;
	wire [127:0] rs_dout;
	reg          rs_pop;

	async_fifo #(.WIDTH(128), .AW(3)) u_rspq (
		.wr_clk(ui_clk), .wr_rst(ui_rst), .wr_en(app_rd_data_valid && !rs_full),
		.wr_data(app_rd_data), .wr_full(rs_full),
		.rd_clk(clk),    .rd_rst(rst),    .rd_en(rs_pop),
		.rd_data(rs_dout), .rd_empty(rs_empty)
	);

	always @(posedge clk) begin
		if (rst) begin m_valid <= 1'b0; m_rdata <= 128'd0; rs_pop <= 1'b0; end
		else begin
			rs_pop  <= 1'b0;
			m_valid <= 1'b0;
			if (!rs_empty && !rs_pop) begin
				m_rdata <= rs_dout;
				m_valid <= 1'b1;
				rs_pop  <= 1'b1;
			end
		end
	end

	// --- handing them to MIG -------------------------------------------------
	// The command and the write data are accepted independently and may be taken
	// on different cycles. Each is held up until it has been, and only then is
	// the transaction done with and the next one started.
	reg cmd_done, data_done;

	always @(posedge ui_clk) begin
		if (ui_rst) begin
			app_en <= 1'b0; app_wdf_wren <= 1'b0; app_wdf_end <= 1'b0;
			app_addr <= 28'd0; app_cmd <= CMD_READ; app_wdf_data <= 128'd0; app_wdf_mask <= 16'h0000;
			cmd_done <= 1'b0; data_done <= 1'b0; rq_take <= 1'b0;
		end else begin
			rq_take <= 1'b0;

			if (app_en && app_rdy) begin app_en <= 1'b0; cmd_done <= 1'b1; end
			if (app_wdf_wren && app_wdf_rdy) begin
				app_wdf_wren <= 1'b0; app_wdf_end <= 1'b0; data_done <= 1'b1;
			end

			if (!app_en && !app_wdf_wren && !rq_empty && !rq_take) begin
				// Eight 16-bit words per line; see the header.
				app_addr     <= {rq_addr, 3'b000};
				app_cmd      <= rq_we ? CMD_WRITE : CMD_READ;
				app_en       <= 1'b1;
				app_wdf_data <= rq_wdata;
				app_wdf_mask <= ~rq_wmask;    // the MIG's mask is 'do not write'
				app_wdf_wren <= rq_we;
				app_wdf_end  <= rq_we;
				cmd_done     <= 1'b0;
				data_done    <= !rq_we;
				rq_take      <= 1'b1;
			end
		end
	end

endmodule

`default_nettype wire
