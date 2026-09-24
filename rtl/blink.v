//////////////////////////////////////////////////////////////////////////////////
// blink.v - the first thing to load on a new board.
//
// Runs off the board's own 50 MHz oscillator and blinks both LEDs at two
// different rates. If both blink, at visibly different speeds, then: the board is
// alive, the 3.3 V rail is up, the oscillator is running, JTAG works, Vivado
// produces valid bitstreams, and the pin constraints reach real pins.
//
// One blinking LED could be a stuck pin. Two at different rates means the counter
// is genuinely running.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module blink (
	input  wire sys_clk,      // 50 MHz onboard oscillator, ball U22
	output wire led0,
	output wire led1
);

reg [26:0] cnt = 27'd0;
always @(posedge sys_clk) cnt <= cnt + 27'd1;

assign led0 =  cnt[25];       // ~0.75 Hz
assign led1 = ~cnt[23];       // ~3 Hz

endmodule

`default_nettype wire
