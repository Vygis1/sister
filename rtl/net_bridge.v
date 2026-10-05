//////////////////////////////////////////////////////////////////////////////////
// net_bridge.v - net_core's register bus, from the Ethernet PHY's clock into the
// console's. The console runs from the board's own oscillator; the LAN8720 module
// (and its 50 MHz REF_CLK, which net_core's RMII must use) may not even be plugged
// in. Without it this side never asks for anything and the console does not care.
//
// The bus is one transfer at a time: a master holds we/re (and the address and
// data) until a one-clock ack, with the read data and error in that clock. Here:
// the request is latched on the PHY side and a toggle crosses; the console side
// makes the transfer and sends a toggle back with the answer latched. What crosses
// with each toggle was latched clocks before it and is held until after, so only
// the toggles are synchronised.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module net_bridge (
	// net_core's side (the PHY's REF_CLK)
	input  wire        n_clk,
	input  wire        n_rst,
	input  wire [31:0] n_addr,
	input  wire [31:0] n_wdata,
	input  wire        n_we,
	input  wire        n_re,
	output reg  [31:0] n_rdata,
	output reg  [1:0]  n_err,
	output reg         n_ack,
	// the console's side
	input  wire        c_clk,
	input  wire        c_rst,
	output wire [31:0] c_addr,
	output wire [31:0] c_wdata,
	output wire        c_we,
	output wire        c_re,
	input  wire [31:0] c_rdata,
	input  wire [1:0]  c_err,
	input  wire        c_ack
);
	// --- the PHY's side ---------------------------------------------------------------
	reg  [31:0] q_addr, q_wdata;
	reg         q_we, q_re;
	reg         busy, req_t;
	(* ASYNC_REG = "TRUE" *) reg [1:0] ack_s;
	reg         ack_seen;
	reg         ack_t;                    // (the console's, below)
	reg  [31:0] a_rdata;
	reg  [1:0]  a_err;
	always @(posedge n_clk) begin
		ack_s <= {ack_s[0], ack_t};
		n_ack <= 1'b0;
		if (n_rst) begin
			busy <= 1'b0; req_t <= 1'b0; ack_seen <= ack_s[1];
		end else if (busy) begin
			if (ack_s[1] != ack_seen) begin
				ack_seen <= ack_s[1]; busy <= 1'b0;
				n_ack <= 1'b1; n_rdata <= a_rdata; n_err <= a_err;
			end
		end else if ((n_we || n_re) && !n_ack) begin
			// (not on the clock its ack is out: the master is still holding the old one)
			q_addr <= n_addr; q_wdata <= n_wdata; q_we <= n_we; q_re <= n_re;
			req_t <= !req_t; busy <= 1'b1;
		end
	end

	// --- the console's side -----------------------------------------------------------
	(* ASYNC_REG = "TRUE" *) reg [1:0] req_s;
	reg         req_seen, pend;
	always @(posedge c_clk) begin
		req_s <= {req_s[0], req_t};
		if (c_rst) begin
			pend <= 1'b0; req_seen <= req_s[1]; ack_t <= 1'b0;
		end else if (!pend) begin
			if (req_s[1] != req_seen) begin req_seen <= req_s[1]; pend <= 1'b1; end
		end else if (c_ack) begin
			pend <= 1'b0; a_rdata <= c_rdata; a_err <= c_err; ack_t <= !ack_t;
		end
	end
	assign c_addr  = q_addr;
	assign c_wdata = q_wdata;
	assign c_we    = pend && q_we;
	assign c_re    = pend && q_re;
endmodule
`default_nettype wire
