//////////////////////////////////////////////////////////////////////////////////
// nes_palette888.v - NES colour index to 24-bit RGB, for HDMI. The same 64 colours
// as nes_palette.v (generated from its table), at full depth.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module nes_palette888 (
	input  wire [5:0]  idx,
	output reg  [23:0] rgb
);
	always @* begin
		case (idx)
		6'd0 : rgb = 24'h626262;
		6'd1 : rgb = 24'h001FB2;
		6'd2 : rgb = 24'h2404C8;
		6'd3 : rgb = 24'h5200B2;
		6'd4 : rgb = 24'h730076;
		6'd5 : rgb = 24'h800024;
		6'd6 : rgb = 24'h730B00;
		6'd7 : rgb = 24'h522800;
		6'd8 : rgb = 24'h244400;
		6'd9 : rgb = 24'h005700;
		6'd10: rgb = 24'h005C00;
		6'd11: rgb = 24'h005324;
		6'd12: rgb = 24'h003C76;
		6'd13: rgb = 24'h000000;
		6'd14: rgb = 24'h000000;
		6'd15: rgb = 24'h000000;
		6'd16: rgb = 24'hABABAB;
		6'd17: rgb = 24'h0D57FF;
		6'd18: rgb = 24'h4B30FF;
		6'd19: rgb = 24'h8A13FF;
		6'd20: rgb = 24'hBC08D6;
		6'd21: rgb = 24'hD21269;
		6'd22: rgb = 24'hC72E00;
		6'd23: rgb = 24'h9D5400;
		6'd24: rgb = 24'h607B00;
		6'd25: rgb = 24'h209800;
		6'd26: rgb = 24'h00A300;
		6'd27: rgb = 24'h009942;
		6'd28: rgb = 24'h007DB4;
		6'd29: rgb = 24'h000000;
		6'd30: rgb = 24'h000000;
		6'd31: rgb = 24'h000000;
		6'd32: rgb = 24'hFFFFFF;
		6'd33: rgb = 24'h53AEFF;
		6'd34: rgb = 24'h9085FF;
		6'd35: rgb = 24'hD365FF;
		6'd36: rgb = 24'hFF57FF;
		6'd37: rgb = 24'hFF5DCF;
		6'd38: rgb = 24'hFF7757;
		6'd39: rgb = 24'hFA9E00;
		6'd40: rgb = 24'hBDC700;
		6'd41: rgb = 24'h7AE700;
		6'd42: rgb = 24'h43F611;
		6'd43: rgb = 24'h26EF7E;
		6'd44: rgb = 24'h2CD5F6;
		6'd45: rgb = 24'h4E4E4E;
		6'd46: rgb = 24'h000000;
		6'd47: rgb = 24'h000000;
		6'd48: rgb = 24'hFFFFFF;
		6'd49: rgb = 24'hB6E1FF;
		6'd50: rgb = 24'hCED1FF;
		6'd51: rgb = 24'hE9C3FF;
		6'd52: rgb = 24'hFFBCFF;
		6'd53: rgb = 24'hFFBDF4;
		6'd54: rgb = 24'hFFC6C3;
		6'd55: rgb = 24'hFFD59A;
		6'd56: rgb = 24'hE9E681;
		6'd57: rgb = 24'hCEF481;
		6'd58: rgb = 24'hB6FB9A;
		6'd59: rgb = 24'hA9FAC3;
		6'd60: rgb = 24'hA9F0F4;
		6'd61: rgb = 24'hB8B8B8;
		6'd62: rgb = 24'h000000;
		6'd63: rgb = 24'h000000;
		default: rgb = 24'h000000;
		endcase
	end
endmodule

`default_nettype wire
