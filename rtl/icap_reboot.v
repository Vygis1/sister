//////////////////////////////////////////////////////////////////////////////////
// icap_reboot.v - restart configuration from flash address 0, the shell: how a
// console image hands the board back (the ESP32 asks, to switch consoles). The
// sequence is shell_top's: dummy, sync, NOOP, WBSTAR = 0, CMD = IPROG, each word
// with its bits reversed within each byte, which is what ICAPE2 wants.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module icap_reboot (
	input  wire clk,
	input  wire rst,
	input  wire go
);
	function [31:0] bitswap;
		input [31:0] v;
		integer b;
		begin
			for (b = 0; b < 8; b = b + 1) begin
				bitswap[b]      = v[7  - b];
				bitswap[8  + b] = v[15 - b];
				bitswap[16 + b] = v[23 - b];
				bitswap[24 + b] = v[31 - b];
			end
		end
	endfunction

	reg        run;
	reg [3:0]  step;
	reg        csib;
	reg [31:0] din;
	always @(posedge clk) begin
		if (rst) begin
			run <= 1'b0; step <= 4'd0; csib <= 1'b1; din <= 32'hFFFFFFFF;
		end else if (!run) begin
			if (go) run <= 1'b1;
		end else begin
			csib <= 1'b0;
			case (step)
			4'd0: din <= bitswap(32'hFFFFFFFF);   // dummy
			4'd1: din <= bitswap(32'hAA995566);   // sync word
			4'd2: din <= bitswap(32'h20000000);   // NOOP
			4'd3: din <= bitswap(32'h30020001);   // write 1 word to WBSTAR
			4'd4: din <= bitswap(32'h00000000);   // address 0: the shell
			4'd5: din <= bitswap(32'h30008001);   // write 1 word to CMD
			4'd6: din <= bitswap(32'h0000000F);   // IPROG
			default: din <= bitswap(32'h20000000);
			endcase
			if (step != 4'd15) step <= step + 4'd1;
		end
	end

	ICAPE2 #(.ICAP_WIDTH("X32")) u_icap (
		.O(), .CLK(clk), .CSIB(csib), .I(din), .RDWRB(1'b0)
	);
endmodule

`default_nettype wire
