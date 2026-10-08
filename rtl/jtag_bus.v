//////////////////////////////////////////////////////////////////////////////////
// jtag_bus.v - the JTAG-to-AXI master (Xilinx jtag_axi, tools/jtagaxi.tcl) onto the register
// bus, as one more master of bus_arb: the PC reads and writes the console's registers, its
// frames and its memory windows over the JTAG cable (tools/jtag.py). Debug builds only
// (eth_top JTAG_DBG): the ESP32 is the console's controller and disc, not a debug port.
//
// Every AXI beat is one bus transfer: the request is held until the bus acknowledges, as
// bus_arb wants; a burst steps the address by 4 a beat (INCR; FIXED and WRAP are not used by
// the host side). Byte strobes are ignored: the register bus moves whole words.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module jtag_bus (
	input  wire        clk,
	input  wire        rst,
	// AXI4 slave (from jtag_axi_0)
	input  wire [31:0] awaddr,  input wire [7:0] awlen, input wire awvalid, output reg awready,
	input  wire [31:0] wdata,   input wire wlast, input wire wvalid, output reg wready,
	output reg  [1:0]  bresp,   output reg bvalid, input wire bready,
	input  wire [31:0] araddr,  input wire [7:0] arlen, input wire arvalid, output reg arready,
	output reg  [31:0] rdata,   output reg [1:0] rresp, output reg rlast, output reg rvalid, input wire rready,
	// the register bus (a bus_arb master port)
	output reg  [31:0] bus_addr, output reg [31:0] bus_wdata,
	output reg         bus_we, output reg bus_re,
	input  wire        bus_ack,
	input  wire [31:0] bus_rdata
);
	localparam S_IDLE = 3'd0, S_RD = 3'd1, S_RV = 3'd2, S_WW = 3'd3, S_WR = 3'd4, S_B = 3'd5;
	reg [2:0] st;
	reg [7:0] left;
	always @(posedge clk) begin
		awready <= 1'b0; arready <= 1'b0; wready <= 1'b0;
		if (rst) begin
			st <= S_IDLE; bus_we <= 1'b0; bus_re <= 1'b0; bvalid <= 1'b0; rvalid <= 1'b0;
			bresp <= 2'b00; rresp <= 2'b00; rlast <= 1'b0;
		end else case (st)
		S_IDLE:
			if (arvalid && !arready) begin
				arready <= 1'b1; bus_addr <= {araddr[31:2], 2'b00}; left <= arlen;
				bus_re <= 1'b1; st <= S_RD;
			end else if (awvalid && !awready) begin
				awready <= 1'b1; bus_addr <= {awaddr[31:2], 2'b00}; left <= awlen; st <= S_WW;
			end
		// a read beat: held until the bus answers, then offered until taken
		S_RD: if (bus_ack) begin
				bus_re <= 1'b0; rdata <= bus_rdata; rresp <= 2'b00; rlast <= (left == 8'd0); rvalid <= 1'b1;
				st <= S_RV;
			end
		S_RV: if (rready) begin
				rvalid <= 1'b0;
				if (left == 8'd0) st <= S_IDLE;
				else begin left <= left - 8'd1; bus_addr <= bus_addr + 32'd4; bus_re <= 1'b1; st <= S_RD; end
			end
		// a write beat: its data taken, then held on the bus until acknowledged
		S_WW: if (wvalid && !wready) begin
				wready <= 1'b1; bus_wdata <= wdata; bus_we <= 1'b1; st <= S_WR;
			end
		S_WR: if (bus_ack) begin
				bus_we <= 1'b0;
				if (left == 8'd0) begin bvalid <= 1'b1; bresp <= 2'b00; st <= S_B; end
				else begin left <= left - 8'd1; bus_addr <= bus_addr + 32'd4; st <= S_WW; end
			end
		S_B: if (bready) begin bvalid <= 1'b0; st <= S_IDLE; end
		default: st <= S_IDLE;
		endcase
	end
endmodule
`default_nettype wire
