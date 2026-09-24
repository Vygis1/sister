//////////////////////////////////////////////////////////////////////////////////
// nes_palette.v - NES colour index to RGB332.
//
// The PPU emits a 6-bit index into the console's fixed 64-colour palette; this
// turns that into the framebuffer's pixel format. GENERATED -- edit the
// generator, not this file.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module nes_palette (
	input  wire [5:0] idx,
	output reg  [7:0] rgb332
);

	always @* begin
		case (idx)
		6'd0 : rgb332 = 8'h6D;   // #626262
		6'd1 : rgb332 = 8'h02;   // #001FB2
		6'd2 : rgb332 = 8'h23;   // #2404C8
		6'd3 : rgb332 = 8'h42;   // #5200B2
		6'd4 : rgb332 = 8'h61;   // #730076
		6'd5 : rgb332 = 8'h80;   // #800024
		6'd6 : rgb332 = 8'h60;   // #730B00
		6'd7 : rgb332 = 8'h44;   // #522800
		6'd8 : rgb332 = 8'h28;   // #244400
		6'd9 : rgb332 = 8'h08;   // #005700
		6'd10: rgb332 = 8'h08;   // #005C00
		6'd11: rgb332 = 8'h08;   // #005324
		6'd12: rgb332 = 8'h05;   // #003C76
		6'd13: rgb332 = 8'h00;   // #000000
		6'd14: rgb332 = 8'h00;   // #000000
		6'd15: rgb332 = 8'h00;   // #000000
		6'd16: rgb332 = 8'hB6;   // #ABABAB
		6'd17: rgb332 = 8'h0B;   // #0D57FF
		6'd18: rgb332 = 8'h47;   // #4B30FF
		6'd19: rgb332 = 8'h83;   // #8A13FF
		6'd20: rgb332 = 8'hA3;   // #BC08D6
		6'd21: rgb332 = 8'hC1;   // #D21269
		6'd22: rgb332 = 8'hC4;   // #C72E00
		6'd23: rgb332 = 8'h88;   // #9D5400
		6'd24: rgb332 = 8'h6C;   // #607B00
		6'd25: rgb332 = 8'h30;   // #209800
		6'd26: rgb332 = 8'h14;   // #00A300
		6'd27: rgb332 = 8'h11;   // #009942
		6'd28: rgb332 = 8'h0E;   // #007DB4
		6'd29: rgb332 = 8'h00;   // #000000
		6'd30: rgb332 = 8'h00;   // #000000
		6'd31: rgb332 = 8'h00;   // #000000
		6'd32: rgb332 = 8'hFF;   // #FFFFFF
		6'd33: rgb332 = 8'h57;   // #53AEFF
		6'd34: rgb332 = 8'h93;   // #9085FF
		6'd35: rgb332 = 8'hCF;   // #D365FF
		6'd36: rgb332 = 8'hEB;   // #FF57FF
		6'd37: rgb332 = 8'hEB;   // #FF5DCF
		6'd38: rgb332 = 8'hED;   // #FF7757
		6'd39: rgb332 = 8'hF0;   // #FA9E00
		6'd40: rgb332 = 8'hB8;   // #BDC700
		6'd41: rgb332 = 8'h7C;   // #7AE700
		6'd42: rgb332 = 8'h5C;   // #43F611
		6'd43: rgb332 = 8'h3D;   // #26EF7E
		6'd44: rgb332 = 8'h3B;   // #2CD5F6
		6'd45: rgb332 = 8'h49;   // #4E4E4E
		6'd46: rgb332 = 8'h00;   // #000000
		6'd47: rgb332 = 8'h00;   // #000000
		6'd48: rgb332 = 8'hFF;   // #FFFFFF
		6'd49: rgb332 = 8'hBF;   // #B6E1FF
		6'd50: rgb332 = 8'hDB;   // #CED1FF
		6'd51: rgb332 = 8'hFB;   // #E9C3FF
		6'd52: rgb332 = 8'hF7;   // #FFBCFF
		6'd53: rgb332 = 8'hF7;   // #FFBDF4
		6'd54: rgb332 = 8'hFB;   // #FFC6C3
		6'd55: rgb332 = 8'hFA;   // #FFD59A
		6'd56: rgb332 = 8'hFE;   // #E9E681
		6'd57: rgb332 = 8'hDE;   // #CEF481
		6'd58: rgb332 = 8'hBE;   // #B6FB9A
		6'd59: rgb332 = 8'hBF;   // #A9FAC3
		6'd60: rgb332 = 8'hBF;   // #A9F0F4
		6'd61: rgb332 = 8'hB6;   // #B8B8B8
		6'd62: rgb332 = 8'h00;   // #000000
		6'd63: rgb332 = 8'h00;   // #000000
		default: rgb332 = 8'h00;
		endcase
	end

endmodule

`default_nettype wire
