//////////////////////////////////////////////////////////////////////////////////
// frame_hdmi.v - a console's picture for HDMI: one frame of its own colour words,
// written as the video chip draws (clk) and read for hdmi_tx (pclk), each pixel
// doubled and the picture centred in 640x480 -- the Master System's and the Mega
// Drive's (nes_hdmi.v is the NES's, with its palette).
//
// The frame is 320 words a line, 240 lines; the picture in it is w x h (the console
// says which: a Mega Drive is 256 or 320 across, 224 lines; a Master System 256 x
// 192), shown 2w x 2h from (320 - w, 240 - h).
//
// FMT picks what a colour word is:
//   1  Master System: 6 bits, --BBGGRR (two bits each)
//   2  Mega Drive:    9 bits, BBBGGGRRR (three bits each)
//   3  PlayStation:  15 bits, BBBBBGGGGGRRRRR (five bits each)
//   4  Game Gear:    12 bits, BBBBGGGGRRRR (four bits each)
//   5  Game Boy:      2 bits, a shade (0 lightest .. 3 darkest), shown in DMG greens
//   6  Atari 2600:    7 bits, the TIA's hue (6:3) and luminance (2:0), through an NTSC palette
//                     (tools/a26/ntsc_palette.py: the encoder through the YIQ matrix)
//
// XSCALE / YSCALE (each 2 or 3; SCALE sets both) stretch the two directions apart: the
// Atari's 160 columns are each three pixels wide and its lines two tall, as wide as a
// television showed them.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module frame_hdmi #(
	parameter FMT = 1,
	parameter DW  = 6,                   // bits a colour word
	parameter SCALE = 2,                 // each pixel doubled (2), or tripled (3: the Game Gear's 160 x 144 as 480 x 432)
	parameter XSCALE = SCALE,            // ...or the two directions apart (the Atari: 3 across, 2 down)
	parameter YSCALE = SCALE
)(
	// the writing side (clk)
	input  wire          clk,
	input  wire          we,
	input  wire [8:0]    wx,
	input  wire [8:0]    wy,
	input  wire [DW-1:0] wd,
	input  wire [8:0]    w,              // the picture's width and height now
	input  wire [8:0]    h,
	// the pixel side (pclk)
	input  wire          pclk,
	input  wire [9:0]    x,
	input  wire [9:0]    y,
	input  wire          req,
	output wire [23:0]   rgb
);
	(* ram_style = "block" *) reg [DW-1:0] fb [0:76799];          // 320 x 240
	wire [16:0] wa = {wy[7:0], 8'd0} + {2'd0, wy[7:0], 6'd0} + {8'd0, wx};   // y * 320 + x
	always @(posedge clk)
		if (we && wx < 9'd320 && wy < 9'd240) fb[wa] <= wd;

	// the shape, from clk: it changes between frames, so two flops each is enough
	reg [8:0] w1, w2, h1, h2;
	always @(posedge pclk) begin w1 <= w; w2 <= w1; h1 <= h; h2 <= h1; end
	// the picture is XSCALE w by YSCALE h, centred: tripled, it starts 3w/2 = w + w/2 left of centre
	wire [10:0] wS = (XSCALE == 3) ? {2'b0, w2} + {1'b0, w2, 1'b0} : {1'b0, w2, 1'b0};
	wire [10:0] hS = (YSCALE == 3) ? {2'b0, h2} + {1'b0, h2, 1'b0} : {1'b0, h2, 1'b0};
	wire [9:0] x0 = (XSCALE == 3) ? 10'd320 - ({1'b0, w2} + {2'b0, w2[8:1]}) : 10'd320 - {1'b0, w2};   // where the picture starts
	wire [9:0] y0 = (YSCALE == 3) ? 10'd240 - ({1'b0, h2} + {2'b0, h2[8:1]}) : 10'd240 - {1'b0, h2};
	wire [9:0] xs = x - x0, ys = y - y0;           // (on the picture: 0 .. XSCALE w - 1, 0 .. YSCALE h - 1)
	wire       on = x >= x0 && {1'b0, xs} < wS && y >= y0 && {1'b0, ys} < hS;
	// a third: xs * 171 >> 9 is exact for every xs under 512
	wire [17:0] xs3 = xs * 10'd171, ys3 = ys * 10'd171;
	wire [8:0] sx = (XSCALE == 3) ? xs3[17:9] : xs[9:1], sy = (YSCALE == 3) ? ys3[17:9] : ys[9:1];
	wire [16:0] ra = {sy[7:0], 8'd0} + {2'd0, sy[7:0], 6'd0} + {8'd0, sx};
	reg  [DW-1:0] q; reg vis;
	always @(posedge pclk) begin
		q <= fb[ra];
		vis <= req && on;
	end

	// The Atari 2600's colours (FMT 6): tools/a26/ntsc_palette.py's table, the TIA's 7-bit
	// colour (its COLUxx register's bits 7:1) to RGB. A ROM read without a clock, and said to
	// be distributed: as a function (a case) synthesis made it a block-RAM ROM, took the frame's
	// read register q for that ROM's address register, and the frame -- left with no read
	// register of its own -- went into 12,000 LUTs of distributed RAM instead of block RAM.
	(* rom_style = "distributed" *) reg [23:0] a26_rom [0:127];
	initial begin
		a26_rom[0] = 24'h101010;
		a26_rom[1] = 24'h303030;
		a26_rom[2] = 24'h505050;
		a26_rom[3] = 24'h707070;
		a26_rom[4] = 24'h8F8F8F;
		a26_rom[5] = 24'hAFAFAF;
		a26_rom[6] = 24'hCFCFCF;
		a26_rom[7] = 24'hEFEFEF;
		a26_rom[8] = 24'h222400;
		a26_rom[9] = 24'h424400;
		a26_rom[10] = 24'h626400;
		a26_rom[11] = 24'h828400;
		a26_rom[12] = 24'hA2A400;
		a26_rom[13] = 24'hC1C417;
		a26_rom[14] = 24'hE1E337;
		a26_rom[15] = 24'hFFFF57;
		a26_rom[16] = 24'h440E00;
		a26_rom[17] = 24'h642E00;
		a26_rom[18] = 24'h844E00;
		a26_rom[19] = 24'hA36D00;
		a26_rom[20] = 24'hC38D13;
		a26_rom[21] = 24'hE3AD32;
		a26_rom[22] = 24'hFFCD52;
		a26_rom[23] = 24'hFFED72;
		a26_rom[24] = 24'h5C0000;
		a26_rom[25] = 24'h7C1800;
		a26_rom[26] = 24'h9C3704;
		a26_rom[27] = 24'hBC5724;
		a26_rom[28] = 24'hDC7744;
		a26_rom[29] = 24'hFC9764;
		a26_rom[30] = 24'hFFB784;
		a26_rom[31] = 24'hFFD7A4;
		a26_rom[32] = 24'h670004;
		a26_rom[33] = 24'h870624;
		a26_rom[34] = 24'hA72643;
		a26_rom[35] = 24'hC74663;
		a26_rom[36] = 24'hE66683;
		a26_rom[37] = 24'hFF85A3;
		a26_rom[38] = 24'hFFA5C3;
		a26_rom[39] = 24'hFFC5E3;
		a26_rom[40] = 24'h620045;
		a26_rom[41] = 24'h820065;
		a26_rom[42] = 24'hA21C85;
		a26_rom[43] = 24'hC23CA5;
		a26_rom[44] = 24'hE15BC5;
		a26_rom[45] = 24'hFF7BE4;
		a26_rom[46] = 24'hFF9BFF;
		a26_rom[47] = 24'hFFBBFF;
		a26_rom[48] = 24'h4E007D;
		a26_rom[49] = 24'h6E009D;
		a26_rom[50] = 24'h8E1BBD;
		a26_rom[51] = 24'hAE3BDC;
		a26_rom[52] = 24'hCE5BFC;
		a26_rom[53] = 24'hEE7AFF;
		a26_rom[54] = 24'hFF9AFF;
		a26_rom[55] = 24'hFFBAFF;
		a26_rom[56] = 24'h2F00A1;
		a26_rom[57] = 24'h4F04C1;
		a26_rom[58] = 24'h6F24E1;
		a26_rom[59] = 24'h8F43FF;
		a26_rom[60] = 24'hAF63FF;
		a26_rom[61] = 24'hCF83FF;
		a26_rom[62] = 24'hEEA3FF;
		a26_rom[63] = 24'hFFC3FF;
		a26_rom[64] = 24'h0B00AB;
		a26_rom[65] = 24'h2A14CB;
		a26_rom[66] = 24'h4A34EB;
		a26_rom[67] = 24'h6A54FF;
		a26_rom[68] = 24'h8A74FF;
		a26_rom[69] = 24'hAA94FF;
		a26_rom[70] = 24'hCAB4FF;
		a26_rom[71] = 24'hEAD4FF;
		a26_rom[72] = 24'h000A99;
		a26_rom[73] = 24'h072AB9;
		a26_rom[74] = 24'h274AD9;
		a26_rom[75] = 24'h476AF9;
		a26_rom[76] = 24'h678AFF;
		a26_rom[77] = 24'h86AAFF;
		a26_rom[78] = 24'hA6C9FF;
		a26_rom[79] = 24'hC6E9FF;
		a26_rom[80] = 24'h00216F;
		a26_rom[81] = 24'h00418E;
		a26_rom[82] = 24'h0B61AE;
		a26_rom[83] = 24'h2A80CE;
		a26_rom[84] = 24'h4AA0EE;
		a26_rom[85] = 24'h6AC0FF;
		a26_rom[86] = 24'h8AE0FF;
		a26_rom[87] = 24'hAAFFFF;
		a26_rom[88] = 24'h003433;
		a26_rom[89] = 24'h005453;
		a26_rom[90] = 24'h007473;
		a26_rom[91] = 24'h1B9493;
		a26_rom[92] = 24'h3AB4B2;
		a26_rom[93] = 24'h5AD4D2;
		a26_rom[94] = 24'h7AF4F2;
		a26_rom[95] = 24'h9AFFFF;
		a26_rom[96] = 24'h004100;
		a26_rom[97] = 24'h006111;
		a26_rom[98] = 24'h008131;
		a26_rom[99] = 24'h1AA151;
		a26_rom[100] = 24'h3AC170;
		a26_rom[101] = 24'h5AE190;
		a26_rom[102] = 24'h7AFFB0;
		a26_rom[103] = 24'h9AFFD0;
		a26_rom[104] = 24'h004600;
		a26_rom[105] = 24'h006500;
		a26_rom[106] = 24'h098500;
		a26_rom[107] = 24'h29A514;
		a26_rom[108] = 24'h49C534;
		a26_rom[109] = 24'h69E554;
		a26_rom[110] = 24'h89FF74;
		a26_rom[111] = 24'hA9FF94;
		a26_rom[112] = 24'h004000;
		a26_rom[113] = 24'h056000;
		a26_rom[114] = 24'h258000;
		a26_rom[115] = 24'h45A000;
		a26_rom[116] = 24'h64C008;
		a26_rom[117] = 24'h84DF28;
		a26_rom[118] = 24'hA4FF48;
		a26_rom[119] = 24'hC4FF68;
		a26_rom[120] = 24'h083200;
		a26_rom[121] = 24'h285200;
		a26_rom[122] = 24'h487200;
		a26_rom[123] = 24'h689100;
		a26_rom[124] = 24'h88B100;
		a26_rom[125] = 24'hA8D115;
		a26_rom[126] = 24'hC8F134;
		a26_rom[127] = 24'hE7FF54;
	end

	// the colour word, to 24 bits (each field's bits repeated down to fill eight)
	wire [23:0] c;
	generate if (FMT == 3) begin : g_ps1
		wire [4:0] r = q[4:0], g = q[9:5], b = q[14:10];
		assign c = {r, r[4:2], g, g[4:2], b, b[4:2]};
	end else if (FMT == 4) begin : g_gg
		assign c = {q[3:0], q[3:0], q[7:4], q[7:4], q[11:8], q[11:8]};   // (the word is BBBBGGGGRRRR: red is the low nibble)
	end else if (FMT == 5) begin : g_gb
		// the four shades in greens, light to dark, the way a DMG's screen tints them
		assign c = (q[1:0] == 2'd0) ? 24'hE0F8D0 : (q[1:0] == 2'd1) ? 24'h88C070
		         : (q[1:0] == 2'd2) ? 24'h346856 : 24'h081820;
	end else if (FMT == 6) begin : g_a26
		assign c = a26_rom[q[6:0]];
	end else if (FMT == 2) begin : g_md
		wire [2:0] r = q[2:0], g = q[5:3], b = q[8:6];
		assign c = {r, r, r[2:1], g, g, g[2:1], b, b, b[2:1]};
	end else begin : g_sms
		wire [1:0] r = q[1:0], g = q[3:2], b = q[5:4];
		assign c = {r, r, r, r, g, g, g, g, b, b, b, b};
	end endgenerate
	assign rgb = vis ? c : 24'd0;
endmodule

`default_nettype wire
