//////////////////////////////////////////////////////////////////////////////////
// hdmi_tmds.v - one TMDS channel's encoder, as the DVI 1.0 specification gives it
// (section 3.3.4): 8 bits of video in, 10 out, a symbol a pixel clock.
//
// While de is high: the 8 bits go through the transition-minimising stage (XOR, or
// XNOR when the byte has more than four ones, or four and a clear bit 0), and then
// the DC balance stage inverts them or not to pull the running disparity (cnt)
// back towards zero. While de is low: one of the four control tokens for {c1, c0}
// (HSYNC and VSYNC on channel 0), and the disparity starts again from zero.
//
// Bit 0 of q goes out first.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module hdmi_tmds (
	input  wire       clk,
	input  wire       de,
	input  wire [7:0] d,
	input  wire       c0,
	input  wire       c1,
	output reg  [9:0] q
);
	function [3:0] ones8; input [7:0] v; integer i; begin
		ones8 = 4'd0;
		for (i = 0; i < 8; i = i + 1) ones8 = ones8 + {3'd0, v[i]};
	end endfunction

	// the transition-minimising stage
	wire [3:0] n1d = ones8(d);
	wire       use_xnor = (n1d > 4'd4) || (n1d == 4'd4 && !d[0]);
	wire [8:0] qm;
	assign qm[0] = d[0];
	genvar i;
	generate for (i = 1; i < 8; i = i + 1) begin : g_qm
		assign qm[i] = use_xnor ? ~(qm[i - 1] ^ d[i]) : (qm[i - 1] ^ d[i]);
	end endgenerate
	assign qm[8] = !use_xnor;

	// the DC balance stage: the running disparity in units of one bit
	wire [3:0]        n1 = ones8(qm[7:0]);
	wire signed [5:0] diff = $signed({2'd0, n1}) - $signed({2'd0, 4'd8 - n1});   // ones less zeros of qm[7:0]
	reg  signed [5:0] cnt;
	always @(posedge clk) begin
		if (!de) begin
			cnt <= 6'sd0;
			case ({c1, c0})
			2'b00:   q <= 10'b1101010100;
			2'b01:   q <= 10'b0010101011;
			2'b10:   q <= 10'b0101010100;
			default: q <= 10'b1010101011;
			endcase
		end else if (cnt == 6'sd0 || diff == 6'sd0) begin
			q <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
			cnt <= qm[8] ? cnt + diff : cnt - diff;
		end else if ((cnt > 6'sd0 && diff > 6'sd0) || (cnt < 6'sd0 && diff < 6'sd0)) begin
			q <= {1'b1, qm[8], ~qm[7:0]};
			cnt <= cnt + {4'd0, qm[8], 1'b0} - diff;
		end else begin
			q <= {1'b0, qm[8], qm[7:0]};
			cnt <= cnt - {4'd0, !qm[8], 1'b0} + diff;
		end
	end
endmodule

`default_nettype wire
