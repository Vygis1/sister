//////////////////////////////////////////////////////////////////////////////////
// bus_arb.v - two masters (net_core, the ESP32's esp_bus) taking turns onto
// regfile's bus. Each holds its request until the acknowledge; a turn is one
// transfer; when both ask, the one that did not go last goes first.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module bus_arb (
	input  wire        clk,
	input  wire        rst,
	input  wire [31:0] a_addr, a_wdata,
	input  wire        a_we, a_re,
	output wire        a_ack,
	input  wire [31:0] b_addr, b_wdata,
	input  wire        b_we, b_re,
	output wire        b_ack,
	output wire [31:0] bus_addr, bus_wdata,
	output wire        bus_we, bus_re,
	input  wire        bus_ack
);
	reg [1:0] own = 2'd0;                // 0 none, 1 a, 2 b
	reg       last_a = 1'b0;
	wire      a_ask = a_we || a_re, b_ask = b_we || b_re;
	always @(posedge clk) begin
		if (rst) own <= 2'd0;
		else if (own == 2'd0) begin
			if (a_ask && (!b_ask || !last_a)) begin own <= 2'd1; last_a <= 1'b1; end
			else if (b_ask)                   begin own <= 2'd2; last_a <= 1'b0; end
		end else if (bus_ack) own <= 2'd0;
	end
	assign bus_addr  = (own == 2'd2) ? b_addr  : a_addr;
	assign bus_wdata = (own == 2'd2) ? b_wdata : a_wdata;
	assign bus_we    = (own == 2'd1) ? a_we : (own == 2'd2) ? b_we : 1'b0;
	assign bus_re    = (own == 2'd1) ? a_re : (own == 2'd2) ? b_re : 1'b0;
	assign a_ack     = bus_ack && own == 2'd1;
	assign b_ack     = bus_ack && own == 2'd2;
endmodule

`default_nettype wire
