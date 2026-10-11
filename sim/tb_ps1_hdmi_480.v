`timescale 1ns/1ps
`include "tb_ps1_hdmi.v"
// tb_ps1_hdmi_480 - tb_ps1_hdmi in the BIOS logo's mode: 640 x 480 (a source line for every HDMI
// line, 80 DDR3 reads each), a 24-clock round trip, the memory taking two requests in three
module tb_ps1_hdmi_480;
	tb_ps1_hdmi #(.W(640), .H(480), .LAT(24), .RDY(3)) t ();
endmodule
