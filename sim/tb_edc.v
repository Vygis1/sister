// tb_edc - the drive's EDC function (ps1_cdrom edc8) against a sector's stored EDC. The sector is
// synthetic (random data, its EDC from the table-driven CRC that checks every GT2 sector sampled
// -- 670 of 670 -- on the PC): no game data in the tree.
//   python tools/ps1/edcsector.py sim/roms/ps1/edc_sector.hex; ./tools/sim.sh tb_edc
`timescale 1ns/1ps
module tb_edc;
	function [31:0] edc8; input [31:0] c; input [7:0] b; integer k; reg [31:0] x;
		begin
			x = c ^ {24'd0, b};
			for (k = 0; k < 8; k = k + 1) x = x[0] ? ((x >> 1) ^ 32'hD801_8001) : (x >> 1);
			edc8 = x;
		end
	endfunction
	reg [7:0] s [0:2351];
	reg [31:0] c, stored; integer i;
	initial begin
		$readmemh("../../sim/roms/ps1/edc_sector.hex", s);
		c = 0;
		for (i = 16; i < 12'h818; i = i + 1) c = edc8(c, s[i]);
		stored = {s[12'h81B], s[12'h81A], s[12'h819], s[12'h818]};
		$display("computed %08h stored %08h", c, stored);
		if (c == stored) $display("tb_edc: PASS"); else $display("tb_edc: FAIL");
		$finish;
	end
endmodule
