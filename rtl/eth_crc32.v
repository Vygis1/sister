`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// eth_crc32 - the IEEE 802.3 frame check sequence
//
// Every Ethernet frame carries a 4-byte CRC32 trailer. Get it wrong and nothing
// obvious happens locally - frames leave the adapter looking fine and the switch
// at the other end silently discards every one of them. That failure mode is why
// this is a separate module with its own test against published vectors rather
// than something inlined into the MAC and hoped for.
//
// CRC-32/ISO-HDLC as 802.3 specifies it:
//   polynomial   0x04C11DB7, used in reflected form as 0xEDB88320
//   initial      0xFFFFFFFF
//   input        reflected (LSB first, which is also Ethernet's wire order)
//   output       reflected, then inverted
//
// Because the input is processed LSB-first and Ethernet also transmits LSB-first,
// the reflected form falls out naturally - no bit reversal is needed anywhere.
//
// The FCS goes on the wire least-significant byte first, so fcs_be() below is
// what a transmitter should shift out.
//////////////////////////////////////////////////////////////////////////////////

module eth_crc32 (
	input             clk,
	input             rst_n,
	input             init,        // restart for a new frame
	input             en,          // consume data_in this cycle
	input      [7:0]  data_in,
	output     [31:0] crc,         // running register value
	output     [31:0] fcs,         // the four bytes to append, in wire order
	// The FCS as it WILL be once data_in has been folded in. A transmitter
	// needs this to append the trailer without spending an extra clock waiting
	// for the register to update - and on a wire that cannot stall, an extra
	// clock is an extra symbol, which corrupts the frame.
	output     [31:0] fcs_next
);

function [31:0] crc32_byte;
	input [31:0] c_in;
	input [7:0]  d;
	integer i;
	reg [31:0] c;
	begin
		c = c_in ^ {24'd0, d};
		for (i = 0; i < 8; i = i + 1)
			c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
		crc32_byte = c;
	end
endfunction

reg [31:0] crc_r;
assign crc = crc_r;

// Reflected-polynomial byte step. Unrolled by synthesis into pure XOR logic -
// eight levels deep, which closes comfortably even at 146 MHz.


always @(posedge clk) begin
	if (!rst_n)   crc_r <= 32'hFFFF_FFFF;
	else if (init) crc_r <= 32'hFFFF_FFFF;
	else if (en)   crc_r <= crc32_byte(crc_r, data_in);
end

// The transmitted FCS is the inverted register, sent least-significant byte
// first. Presenting it in that order here means the MAC can shift bytes out of
// fcs[7:0], fcs[15:8], ... without thinking about endianness again.
assign fcs      = ~crc_r;
assign fcs_next = ~crc32_byte(crc_r, data_in);

endmodule
