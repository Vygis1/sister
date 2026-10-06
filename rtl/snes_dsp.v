//////////////////////////////////////////////////////////////////////////////////
// snes_dsp.v - the SNES's sound chip (S-DSP): eight BRR voices with Gaussian interpolation,
// ADSR / GAIN envelopes, pitch modulation, noise, the echo and its 8-tap FIR, the mixer.
//
// One sample per `sample` pulse (every 32 SPC700 cycles, 32 kHz), worked out step by step
// in the order of the model tools/snes/dsp.py -- sim/tb_snes_dsp.v replays what the model
// was told (tools/snes/dsprec.py) and compares every sample, and ENVX / OUTX / ENDX.
// A sample takes ~1200 clocks of a 50 MHz clock; there are ~1560 between pulses.
//
// The registers are the 128-byte array the chip has (the SPC700 reads and writes it
// through $F2 / $F3); ENVX, OUTX and ENDX are written back by the chip each sample.
// The 64 kB of sound RAM is outside: a read port (address, data a clock later) and a
// write port for the echo.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_dsp (
	input  wire        clk,
	input  wire        rst,
	input  wire        sample,         // work out the next sample
	// the SPC700's $F2 / $F3
	input  wire        r_we,
	input  wire [6:0]  r_addr,
	input  wire [7:0]  r_wdata,
	output wire [7:0]  r_rdata,
	// sound RAM
	output reg  [15:0] ram_a,
	input  wire [7:0]  ram_q,
	output reg         ram_we,
	output reg  [7:0]  ram_wd,
	// out
	output reg  signed [15:0] out_l,
	output reg  signed [15:0] out_r,
	output reg         out_stb
);
	// --- the register array ----------------------------------------------------------------
	reg [7:0] R [0:127];
	assign r_rdata = R[r_addr];
	reg [7:0] new_kon;

	// --- per voice --------------------------------------------------------------------------
	reg [10:0] env    [0:7];
	reg [10:0] hidden [0:7];
	reg [1:0]  vmode  [0:7];             // 0 attack 1 decay 2 sustain 3 release
	reg [2:0]  kdel   [0:7];
	reg [15:0] baddr  [0:7];
	reg [3:0]  boff   [0:7];
	reg [3:0]  bpos   [0:7];
	reg [14:0] vpos   [0:7];
	reg signed [15:0] buf_ [0:95];       // 12 decoded samples a voice (15-bit values)
	localparam ATTACK = 2'd0, DECAY = 2'd1, SUSTAIN = 2'd2, RELEASE = 2'd3;

	// --- the Gauss table (Fullsnes) ---------------------------------------------------------
	// snes_gauss.vh - the S-DSP Gauss table (Fullsnes), generated from tools/snes/dsp.py
	function [10:0] gauss_rom;
		input [8:0] i;
		case (i)
		9'd0: gauss_rom = 11'h000;
		9'd1: gauss_rom = 11'h000;
		9'd2: gauss_rom = 11'h000;
		9'd3: gauss_rom = 11'h000;
		9'd4: gauss_rom = 11'h000;
		9'd5: gauss_rom = 11'h000;
		9'd6: gauss_rom = 11'h000;
		9'd7: gauss_rom = 11'h000;
		9'd8: gauss_rom = 11'h000;
		9'd9: gauss_rom = 11'h000;
		9'd10: gauss_rom = 11'h000;
		9'd11: gauss_rom = 11'h000;
		9'd12: gauss_rom = 11'h000;
		9'd13: gauss_rom = 11'h000;
		9'd14: gauss_rom = 11'h000;
		9'd15: gauss_rom = 11'h000;
		9'd16: gauss_rom = 11'h001;
		9'd17: gauss_rom = 11'h001;
		9'd18: gauss_rom = 11'h001;
		9'd19: gauss_rom = 11'h001;
		9'd20: gauss_rom = 11'h001;
		9'd21: gauss_rom = 11'h001;
		9'd22: gauss_rom = 11'h001;
		9'd23: gauss_rom = 11'h001;
		9'd24: gauss_rom = 11'h001;
		9'd25: gauss_rom = 11'h001;
		9'd26: gauss_rom = 11'h001;
		9'd27: gauss_rom = 11'h002;
		9'd28: gauss_rom = 11'h002;
		9'd29: gauss_rom = 11'h002;
		9'd30: gauss_rom = 11'h002;
		9'd31: gauss_rom = 11'h002;
		9'd32: gauss_rom = 11'h002;
		9'd33: gauss_rom = 11'h002;
		9'd34: gauss_rom = 11'h003;
		9'd35: gauss_rom = 11'h003;
		9'd36: gauss_rom = 11'h003;
		9'd37: gauss_rom = 11'h003;
		9'd38: gauss_rom = 11'h003;
		9'd39: gauss_rom = 11'h004;
		9'd40: gauss_rom = 11'h004;
		9'd41: gauss_rom = 11'h004;
		9'd42: gauss_rom = 11'h004;
		9'd43: gauss_rom = 11'h004;
		9'd44: gauss_rom = 11'h005;
		9'd45: gauss_rom = 11'h005;
		9'd46: gauss_rom = 11'h005;
		9'd47: gauss_rom = 11'h005;
		9'd48: gauss_rom = 11'h006;
		9'd49: gauss_rom = 11'h006;
		9'd50: gauss_rom = 11'h006;
		9'd51: gauss_rom = 11'h006;
		9'd52: gauss_rom = 11'h007;
		9'd53: gauss_rom = 11'h007;
		9'd54: gauss_rom = 11'h007;
		9'd55: gauss_rom = 11'h008;
		9'd56: gauss_rom = 11'h008;
		9'd57: gauss_rom = 11'h008;
		9'd58: gauss_rom = 11'h009;
		9'd59: gauss_rom = 11'h009;
		9'd60: gauss_rom = 11'h009;
		9'd61: gauss_rom = 11'h00A;
		9'd62: gauss_rom = 11'h00A;
		9'd63: gauss_rom = 11'h00A;
		9'd64: gauss_rom = 11'h00B;
		9'd65: gauss_rom = 11'h00B;
		9'd66: gauss_rom = 11'h00B;
		9'd67: gauss_rom = 11'h00C;
		9'd68: gauss_rom = 11'h00C;
		9'd69: gauss_rom = 11'h00D;
		9'd70: gauss_rom = 11'h00D;
		9'd71: gauss_rom = 11'h00E;
		9'd72: gauss_rom = 11'h00E;
		9'd73: gauss_rom = 11'h00F;
		9'd74: gauss_rom = 11'h00F;
		9'd75: gauss_rom = 11'h00F;
		9'd76: gauss_rom = 11'h010;
		9'd77: gauss_rom = 11'h010;
		9'd78: gauss_rom = 11'h011;
		9'd79: gauss_rom = 11'h011;
		9'd80: gauss_rom = 11'h012;
		9'd81: gauss_rom = 11'h013;
		9'd82: gauss_rom = 11'h013;
		9'd83: gauss_rom = 11'h014;
		9'd84: gauss_rom = 11'h014;
		9'd85: gauss_rom = 11'h015;
		9'd86: gauss_rom = 11'h015;
		9'd87: gauss_rom = 11'h016;
		9'd88: gauss_rom = 11'h017;
		9'd89: gauss_rom = 11'h017;
		9'd90: gauss_rom = 11'h018;
		9'd91: gauss_rom = 11'h018;
		9'd92: gauss_rom = 11'h019;
		9'd93: gauss_rom = 11'h01A;
		9'd94: gauss_rom = 11'h01B;
		9'd95: gauss_rom = 11'h01B;
		9'd96: gauss_rom = 11'h01C;
		9'd97: gauss_rom = 11'h01D;
		9'd98: gauss_rom = 11'h01D;
		9'd99: gauss_rom = 11'h01E;
		9'd100: gauss_rom = 11'h01F;
		9'd101: gauss_rom = 11'h020;
		9'd102: gauss_rom = 11'h020;
		9'd103: gauss_rom = 11'h021;
		9'd104: gauss_rom = 11'h022;
		9'd105: gauss_rom = 11'h023;
		9'd106: gauss_rom = 11'h024;
		9'd107: gauss_rom = 11'h024;
		9'd108: gauss_rom = 11'h025;
		9'd109: gauss_rom = 11'h026;
		9'd110: gauss_rom = 11'h027;
		9'd111: gauss_rom = 11'h028;
		9'd112: gauss_rom = 11'h029;
		9'd113: gauss_rom = 11'h02A;
		9'd114: gauss_rom = 11'h02B;
		9'd115: gauss_rom = 11'h02C;
		9'd116: gauss_rom = 11'h02D;
		9'd117: gauss_rom = 11'h02E;
		9'd118: gauss_rom = 11'h02F;
		9'd119: gauss_rom = 11'h030;
		9'd120: gauss_rom = 11'h031;
		9'd121: gauss_rom = 11'h032;
		9'd122: gauss_rom = 11'h033;
		9'd123: gauss_rom = 11'h034;
		9'd124: gauss_rom = 11'h035;
		9'd125: gauss_rom = 11'h036;
		9'd126: gauss_rom = 11'h037;
		9'd127: gauss_rom = 11'h038;
		9'd128: gauss_rom = 11'h03A;
		9'd129: gauss_rom = 11'h03B;
		9'd130: gauss_rom = 11'h03C;
		9'd131: gauss_rom = 11'h03D;
		9'd132: gauss_rom = 11'h03E;
		9'd133: gauss_rom = 11'h040;
		9'd134: gauss_rom = 11'h041;
		9'd135: gauss_rom = 11'h042;
		9'd136: gauss_rom = 11'h043;
		9'd137: gauss_rom = 11'h045;
		9'd138: gauss_rom = 11'h046;
		9'd139: gauss_rom = 11'h047;
		9'd140: gauss_rom = 11'h049;
		9'd141: gauss_rom = 11'h04A;
		9'd142: gauss_rom = 11'h04C;
		9'd143: gauss_rom = 11'h04D;
		9'd144: gauss_rom = 11'h04E;
		9'd145: gauss_rom = 11'h050;
		9'd146: gauss_rom = 11'h051;
		9'd147: gauss_rom = 11'h053;
		9'd148: gauss_rom = 11'h054;
		9'd149: gauss_rom = 11'h056;
		9'd150: gauss_rom = 11'h057;
		9'd151: gauss_rom = 11'h059;
		9'd152: gauss_rom = 11'h05A;
		9'd153: gauss_rom = 11'h05C;
		9'd154: gauss_rom = 11'h05E;
		9'd155: gauss_rom = 11'h05F;
		9'd156: gauss_rom = 11'h061;
		9'd157: gauss_rom = 11'h063;
		9'd158: gauss_rom = 11'h064;
		9'd159: gauss_rom = 11'h066;
		9'd160: gauss_rom = 11'h068;
		9'd161: gauss_rom = 11'h06A;
		9'd162: gauss_rom = 11'h06B;
		9'd163: gauss_rom = 11'h06D;
		9'd164: gauss_rom = 11'h06F;
		9'd165: gauss_rom = 11'h071;
		9'd166: gauss_rom = 11'h073;
		9'd167: gauss_rom = 11'h075;
		9'd168: gauss_rom = 11'h076;
		9'd169: gauss_rom = 11'h078;
		9'd170: gauss_rom = 11'h07A;
		9'd171: gauss_rom = 11'h07C;
		9'd172: gauss_rom = 11'h07E;
		9'd173: gauss_rom = 11'h080;
		9'd174: gauss_rom = 11'h082;
		9'd175: gauss_rom = 11'h084;
		9'd176: gauss_rom = 11'h086;
		9'd177: gauss_rom = 11'h089;
		9'd178: gauss_rom = 11'h08B;
		9'd179: gauss_rom = 11'h08D;
		9'd180: gauss_rom = 11'h08F;
		9'd181: gauss_rom = 11'h091;
		9'd182: gauss_rom = 11'h093;
		9'd183: gauss_rom = 11'h096;
		9'd184: gauss_rom = 11'h098;
		9'd185: gauss_rom = 11'h09A;
		9'd186: gauss_rom = 11'h09C;
		9'd187: gauss_rom = 11'h09F;
		9'd188: gauss_rom = 11'h0A1;
		9'd189: gauss_rom = 11'h0A3;
		9'd190: gauss_rom = 11'h0A6;
		9'd191: gauss_rom = 11'h0A8;
		9'd192: gauss_rom = 11'h0AB;
		9'd193: gauss_rom = 11'h0AD;
		9'd194: gauss_rom = 11'h0AF;
		9'd195: gauss_rom = 11'h0B2;
		9'd196: gauss_rom = 11'h0B4;
		9'd197: gauss_rom = 11'h0B7;
		9'd198: gauss_rom = 11'h0BA;
		9'd199: gauss_rom = 11'h0BC;
		9'd200: gauss_rom = 11'h0BF;
		9'd201: gauss_rom = 11'h0C1;
		9'd202: gauss_rom = 11'h0C4;
		9'd203: gauss_rom = 11'h0C7;
		9'd204: gauss_rom = 11'h0C9;
		9'd205: gauss_rom = 11'h0CC;
		9'd206: gauss_rom = 11'h0CF;
		9'd207: gauss_rom = 11'h0D2;
		9'd208: gauss_rom = 11'h0D4;
		9'd209: gauss_rom = 11'h0D7;
		9'd210: gauss_rom = 11'h0DA;
		9'd211: gauss_rom = 11'h0DD;
		9'd212: gauss_rom = 11'h0E0;
		9'd213: gauss_rom = 11'h0E3;
		9'd214: gauss_rom = 11'h0E6;
		9'd215: gauss_rom = 11'h0E9;
		9'd216: gauss_rom = 11'h0EC;
		9'd217: gauss_rom = 11'h0EF;
		9'd218: gauss_rom = 11'h0F2;
		9'd219: gauss_rom = 11'h0F5;
		9'd220: gauss_rom = 11'h0F8;
		9'd221: gauss_rom = 11'h0FB;
		9'd222: gauss_rom = 11'h0FE;
		9'd223: gauss_rom = 11'h101;
		9'd224: gauss_rom = 11'h104;
		9'd225: gauss_rom = 11'h107;
		9'd226: gauss_rom = 11'h10B;
		9'd227: gauss_rom = 11'h10E;
		9'd228: gauss_rom = 11'h111;
		9'd229: gauss_rom = 11'h114;
		9'd230: gauss_rom = 11'h118;
		9'd231: gauss_rom = 11'h11B;
		9'd232: gauss_rom = 11'h11E;
		9'd233: gauss_rom = 11'h122;
		9'd234: gauss_rom = 11'h125;
		9'd235: gauss_rom = 11'h129;
		9'd236: gauss_rom = 11'h12C;
		9'd237: gauss_rom = 11'h130;
		9'd238: gauss_rom = 11'h133;
		9'd239: gauss_rom = 11'h137;
		9'd240: gauss_rom = 11'h13A;
		9'd241: gauss_rom = 11'h13E;
		9'd242: gauss_rom = 11'h141;
		9'd243: gauss_rom = 11'h145;
		9'd244: gauss_rom = 11'h148;
		9'd245: gauss_rom = 11'h14C;
		9'd246: gauss_rom = 11'h150;
		9'd247: gauss_rom = 11'h153;
		9'd248: gauss_rom = 11'h157;
		9'd249: gauss_rom = 11'h15B;
		9'd250: gauss_rom = 11'h15F;
		9'd251: gauss_rom = 11'h162;
		9'd252: gauss_rom = 11'h166;
		9'd253: gauss_rom = 11'h16A;
		9'd254: gauss_rom = 11'h16E;
		9'd255: gauss_rom = 11'h172;
		9'd256: gauss_rom = 11'h176;
		9'd257: gauss_rom = 11'h17A;
		9'd258: gauss_rom = 11'h17D;
		9'd259: gauss_rom = 11'h181;
		9'd260: gauss_rom = 11'h185;
		9'd261: gauss_rom = 11'h189;
		9'd262: gauss_rom = 11'h18D;
		9'd263: gauss_rom = 11'h191;
		9'd264: gauss_rom = 11'h195;
		9'd265: gauss_rom = 11'h19A;
		9'd266: gauss_rom = 11'h19E;
		9'd267: gauss_rom = 11'h1A2;
		9'd268: gauss_rom = 11'h1A6;
		9'd269: gauss_rom = 11'h1AA;
		9'd270: gauss_rom = 11'h1AE;
		9'd271: gauss_rom = 11'h1B2;
		9'd272: gauss_rom = 11'h1B7;
		9'd273: gauss_rom = 11'h1BB;
		9'd274: gauss_rom = 11'h1BF;
		9'd275: gauss_rom = 11'h1C3;
		9'd276: gauss_rom = 11'h1C8;
		9'd277: gauss_rom = 11'h1CC;
		9'd278: gauss_rom = 11'h1D0;
		9'd279: gauss_rom = 11'h1D5;
		9'd280: gauss_rom = 11'h1D9;
		9'd281: gauss_rom = 11'h1DD;
		9'd282: gauss_rom = 11'h1E2;
		9'd283: gauss_rom = 11'h1E6;
		9'd284: gauss_rom = 11'h1EB;
		9'd285: gauss_rom = 11'h1EF;
		9'd286: gauss_rom = 11'h1F3;
		9'd287: gauss_rom = 11'h1F8;
		9'd288: gauss_rom = 11'h1FC;
		9'd289: gauss_rom = 11'h201;
		9'd290: gauss_rom = 11'h205;
		9'd291: gauss_rom = 11'h20A;
		9'd292: gauss_rom = 11'h20F;
		9'd293: gauss_rom = 11'h213;
		9'd294: gauss_rom = 11'h218;
		9'd295: gauss_rom = 11'h21C;
		9'd296: gauss_rom = 11'h221;
		9'd297: gauss_rom = 11'h226;
		9'd298: gauss_rom = 11'h22A;
		9'd299: gauss_rom = 11'h22F;
		9'd300: gauss_rom = 11'h233;
		9'd301: gauss_rom = 11'h238;
		9'd302: gauss_rom = 11'h23D;
		9'd303: gauss_rom = 11'h241;
		9'd304: gauss_rom = 11'h246;
		9'd305: gauss_rom = 11'h24B;
		9'd306: gauss_rom = 11'h250;
		9'd307: gauss_rom = 11'h254;
		9'd308: gauss_rom = 11'h259;
		9'd309: gauss_rom = 11'h25E;
		9'd310: gauss_rom = 11'h263;
		9'd311: gauss_rom = 11'h267;
		9'd312: gauss_rom = 11'h26C;
		9'd313: gauss_rom = 11'h271;
		9'd314: gauss_rom = 11'h276;
		9'd315: gauss_rom = 11'h27B;
		9'd316: gauss_rom = 11'h280;
		9'd317: gauss_rom = 11'h284;
		9'd318: gauss_rom = 11'h289;
		9'd319: gauss_rom = 11'h28E;
		9'd320: gauss_rom = 11'h293;
		9'd321: gauss_rom = 11'h298;
		9'd322: gauss_rom = 11'h29D;
		9'd323: gauss_rom = 11'h2A2;
		9'd324: gauss_rom = 11'h2A6;
		9'd325: gauss_rom = 11'h2AB;
		9'd326: gauss_rom = 11'h2B0;
		9'd327: gauss_rom = 11'h2B5;
		9'd328: gauss_rom = 11'h2BA;
		9'd329: gauss_rom = 11'h2BF;
		9'd330: gauss_rom = 11'h2C4;
		9'd331: gauss_rom = 11'h2C9;
		9'd332: gauss_rom = 11'h2CE;
		9'd333: gauss_rom = 11'h2D3;
		9'd334: gauss_rom = 11'h2D8;
		9'd335: gauss_rom = 11'h2DC;
		9'd336: gauss_rom = 11'h2E1;
		9'd337: gauss_rom = 11'h2E6;
		9'd338: gauss_rom = 11'h2EB;
		9'd339: gauss_rom = 11'h2F0;
		9'd340: gauss_rom = 11'h2F5;
		9'd341: gauss_rom = 11'h2FA;
		9'd342: gauss_rom = 11'h2FF;
		9'd343: gauss_rom = 11'h304;
		9'd344: gauss_rom = 11'h309;
		9'd345: gauss_rom = 11'h30E;
		9'd346: gauss_rom = 11'h313;
		9'd347: gauss_rom = 11'h318;
		9'd348: gauss_rom = 11'h31D;
		9'd349: gauss_rom = 11'h322;
		9'd350: gauss_rom = 11'h326;
		9'd351: gauss_rom = 11'h32B;
		9'd352: gauss_rom = 11'h330;
		9'd353: gauss_rom = 11'h335;
		9'd354: gauss_rom = 11'h33A;
		9'd355: gauss_rom = 11'h33F;
		9'd356: gauss_rom = 11'h344;
		9'd357: gauss_rom = 11'h349;
		9'd358: gauss_rom = 11'h34E;
		9'd359: gauss_rom = 11'h353;
		9'd360: gauss_rom = 11'h357;
		9'd361: gauss_rom = 11'h35C;
		9'd362: gauss_rom = 11'h361;
		9'd363: gauss_rom = 11'h366;
		9'd364: gauss_rom = 11'h36B;
		9'd365: gauss_rom = 11'h370;
		9'd366: gauss_rom = 11'h374;
		9'd367: gauss_rom = 11'h379;
		9'd368: gauss_rom = 11'h37E;
		9'd369: gauss_rom = 11'h383;
		9'd370: gauss_rom = 11'h388;
		9'd371: gauss_rom = 11'h38C;
		9'd372: gauss_rom = 11'h391;
		9'd373: gauss_rom = 11'h396;
		9'd374: gauss_rom = 11'h39B;
		9'd375: gauss_rom = 11'h39F;
		9'd376: gauss_rom = 11'h3A4;
		9'd377: gauss_rom = 11'h3A9;
		9'd378: gauss_rom = 11'h3AD;
		9'd379: gauss_rom = 11'h3B2;
		9'd380: gauss_rom = 11'h3B7;
		9'd381: gauss_rom = 11'h3BB;
		9'd382: gauss_rom = 11'h3C0;
		9'd383: gauss_rom = 11'h3C5;
		9'd384: gauss_rom = 11'h3C9;
		9'd385: gauss_rom = 11'h3CE;
		9'd386: gauss_rom = 11'h3D2;
		9'd387: gauss_rom = 11'h3D7;
		9'd388: gauss_rom = 11'h3DC;
		9'd389: gauss_rom = 11'h3E0;
		9'd390: gauss_rom = 11'h3E5;
		9'd391: gauss_rom = 11'h3E9;
		9'd392: gauss_rom = 11'h3ED;
		9'd393: gauss_rom = 11'h3F2;
		9'd394: gauss_rom = 11'h3F6;
		9'd395: gauss_rom = 11'h3FB;
		9'd396: gauss_rom = 11'h3FF;
		9'd397: gauss_rom = 11'h403;
		9'd398: gauss_rom = 11'h408;
		9'd399: gauss_rom = 11'h40C;
		9'd400: gauss_rom = 11'h410;
		9'd401: gauss_rom = 11'h415;
		9'd402: gauss_rom = 11'h419;
		9'd403: gauss_rom = 11'h41D;
		9'd404: gauss_rom = 11'h421;
		9'd405: gauss_rom = 11'h425;
		9'd406: gauss_rom = 11'h42A;
		9'd407: gauss_rom = 11'h42E;
		9'd408: gauss_rom = 11'h432;
		9'd409: gauss_rom = 11'h436;
		9'd410: gauss_rom = 11'h43A;
		9'd411: gauss_rom = 11'h43E;
		9'd412: gauss_rom = 11'h442;
		9'd413: gauss_rom = 11'h446;
		9'd414: gauss_rom = 11'h44A;
		9'd415: gauss_rom = 11'h44E;
		9'd416: gauss_rom = 11'h452;
		9'd417: gauss_rom = 11'h455;
		9'd418: gauss_rom = 11'h459;
		9'd419: gauss_rom = 11'h45D;
		9'd420: gauss_rom = 11'h461;
		9'd421: gauss_rom = 11'h465;
		9'd422: gauss_rom = 11'h468;
		9'd423: gauss_rom = 11'h46C;
		9'd424: gauss_rom = 11'h470;
		9'd425: gauss_rom = 11'h473;
		9'd426: gauss_rom = 11'h477;
		9'd427: gauss_rom = 11'h47A;
		9'd428: gauss_rom = 11'h47E;
		9'd429: gauss_rom = 11'h481;
		9'd430: gauss_rom = 11'h485;
		9'd431: gauss_rom = 11'h488;
		9'd432: gauss_rom = 11'h48C;
		9'd433: gauss_rom = 11'h48F;
		9'd434: gauss_rom = 11'h492;
		9'd435: gauss_rom = 11'h496;
		9'd436: gauss_rom = 11'h499;
		9'd437: gauss_rom = 11'h49C;
		9'd438: gauss_rom = 11'h49F;
		9'd439: gauss_rom = 11'h4A2;
		9'd440: gauss_rom = 11'h4A6;
		9'd441: gauss_rom = 11'h4A9;
		9'd442: gauss_rom = 11'h4AC;
		9'd443: gauss_rom = 11'h4AF;
		9'd444: gauss_rom = 11'h4B2;
		9'd445: gauss_rom = 11'h4B5;
		9'd446: gauss_rom = 11'h4B7;
		9'd447: gauss_rom = 11'h4BA;
		9'd448: gauss_rom = 11'h4BD;
		9'd449: gauss_rom = 11'h4C0;
		9'd450: gauss_rom = 11'h4C3;
		9'd451: gauss_rom = 11'h4C5;
		9'd452: gauss_rom = 11'h4C8;
		9'd453: gauss_rom = 11'h4CB;
		9'd454: gauss_rom = 11'h4CD;
		9'd455: gauss_rom = 11'h4D0;
		9'd456: gauss_rom = 11'h4D2;
		9'd457: gauss_rom = 11'h4D5;
		9'd458: gauss_rom = 11'h4D7;
		9'd459: gauss_rom = 11'h4D9;
		9'd460: gauss_rom = 11'h4DC;
		9'd461: gauss_rom = 11'h4DE;
		9'd462: gauss_rom = 11'h4E0;
		9'd463: gauss_rom = 11'h4E3;
		9'd464: gauss_rom = 11'h4E5;
		9'd465: gauss_rom = 11'h4E7;
		9'd466: gauss_rom = 11'h4E9;
		9'd467: gauss_rom = 11'h4EB;
		9'd468: gauss_rom = 11'h4ED;
		9'd469: gauss_rom = 11'h4EF;
		9'd470: gauss_rom = 11'h4F1;
		9'd471: gauss_rom = 11'h4F3;
		9'd472: gauss_rom = 11'h4F5;
		9'd473: gauss_rom = 11'h4F6;
		9'd474: gauss_rom = 11'h4F8;
		9'd475: gauss_rom = 11'h4FA;
		9'd476: gauss_rom = 11'h4FB;
		9'd477: gauss_rom = 11'h4FD;
		9'd478: gauss_rom = 11'h4FF;
		9'd479: gauss_rom = 11'h500;
		9'd480: gauss_rom = 11'h502;
		9'd481: gauss_rom = 11'h503;
		9'd482: gauss_rom = 11'h504;
		9'd483: gauss_rom = 11'h506;
		9'd484: gauss_rom = 11'h507;
		9'd485: gauss_rom = 11'h508;
		9'd486: gauss_rom = 11'h50A;
		9'd487: gauss_rom = 11'h50B;
		9'd488: gauss_rom = 11'h50C;
		9'd489: gauss_rom = 11'h50D;
		9'd490: gauss_rom = 11'h50E;
		9'd491: gauss_rom = 11'h50F;
		9'd492: gauss_rom = 11'h510;
		9'd493: gauss_rom = 11'h511;
		9'd494: gauss_rom = 11'h511;
		9'd495: gauss_rom = 11'h512;
		9'd496: gauss_rom = 11'h513;
		9'd497: gauss_rom = 11'h514;
		9'd498: gauss_rom = 11'h514;
		9'd499: gauss_rom = 11'h515;
		9'd500: gauss_rom = 11'h516;
		9'd501: gauss_rom = 11'h516;
		9'd502: gauss_rom = 11'h517;
		9'd503: gauss_rom = 11'h517;
		9'd504: gauss_rom = 11'h517;
		9'd505: gauss_rom = 11'h518;
		9'd506: gauss_rom = 11'h518;
		9'd507: gauss_rom = 11'h518;
		9'd508: gauss_rom = 11'h518;
		9'd509: gauss_rom = 11'h518;
		9'd510: gauss_rom = 11'h519;
		9'd511: gauss_rom = 11'h519;
		default: gauss_rom = 11'h000;
		endcase
	endfunction

	// --- shared state -------------------------------------------------------------------------
	reg [15:0] counter;
	reg [14:0] noise;
	reg [7:0]  kon;
	reg        every_other;
	reg [14:0] echo_idx, echo_len;
	reg signed [15:0] fir_l [0:7], fir_r [0:7];
	reg [2:0]  fir_i;

	// --- rates: (counter + offset) % period == 0, periods 1 / 3 / 5 times a power of two ------
	// rate r (1..31): period = k << n with (k, n) by r; offset by r's kind
	function fires;
		input [15:0] cnt; input [4:0] r;
		reg [15:0] v, q; reg [3:0] n; reg [2:0] k;
		begin
			// period = k << n (k 1, 3 or 5); offset by r's kind
			case (r)
			5'd28: begin k = 1; n = 2; end
			5'd29: begin k = 3; n = 0; end
			5'd30: begin k = 1; n = 1; end
			5'd31: begin k = 1; n = 0; end
			default: case ((r - 5'd1) % 3)
				0: begin k = 1; n = 4'd11 - (r - 5'd1) / 3; end
				1: begin k = 3; n = 4'd9 - (r - 5'd1) / 3; end
				default: begin k = 5; n = 4'd8 - (r - 5'd1) / 3; end
				endcase
			endcase
			case ((r - 5'd1) % 3)
			0: v = cnt;
			1: v = cnt + 16'd1040;
			default: v = cnt + 16'd536;
			endcase
			q = v >> n;
			if (r == 5'd0) fires = 1'b0;
			else fires = ((v & ((16'd1 << n) - 16'd1)) == 16'd0) &&
			             (k == 3'd1 ? 1'b1 : k == 3'd3 ? (q % 3 == 0) : (q % 5 == 0));
		end
	endfunction

	// (32 bits in: the products here are 24 bits, and an expression is sized by where it goes)
	function signed [15:0] clamp16;
		input signed [31:0] v;
		clamp16 = (v > 32'sd32767) ? 16'sd32767 : (v < -32'sd32768) ? -16'sd32768 : v[15:0];
	endfunction

	// --- the work -------------------------------------------------------------------------------
	localparam [4:0]
		W_IDLE = 5'd0, W_START = 5'd1, W_VOICE = 5'd2, W_DIR0 = 5'd3, W_DIR1 = 5'd4, W_DIR2 = 5'd5,
		W_DEC0 = 5'd6, W_DEC1 = 5'd7, W_DEC2 = 5'd8, W_DEC3 = 5'd9, W_DECN = 5'd10,
		W_INT = 5'd11, W_ENV = 5'd12, W_PITCH = 5'd13, W_MIX = 5'd14, W_NEXT = 5'd15,
		W_ECHO0 = 5'd16, W_ECHO1 = 5'd17, W_FIR = 5'd18, W_EOUT = 5'd19, W_EWR = 5'd20, W_END = 5'd21,
		W_BLK0 = 5'd22, W_BLK1 = 5'd23, W_BLK2 = 5'd24, W_RATES = 5'd26, W_NOISE = 5'd27, W_INT2 = 5'd28, W_FIRD = 5'd29;
	reg [4:0]  ws;
	reg [4:0]  wret;                    // where a decode returns
	reg [2:0]  x;                       // the voice
	reg        kphase;                  // this sample takes KON / KOFF
	reg [7:0]  koff;
	reg signed [15:0] prev_out, vout;
	reg signed [31:0] main_l, main_r, echo_l, echo_r;
	reg [7:0]  hdr;
	reg [7:0]  db0, db1;
	reg [2:0]  dk;                      // nibble within the decode
	reg [1:0]  ik;                      // interpolation tap
	reg signed [31:0] iacc;
	reg [15:0] eaddr;
	reg [2:0]  ek;
	reg signed [15:0] echo_in_l, echo_in_r;
	reg [15:0] ew;
	reg signed [15:0] fl, fr;
	reg [3:0]  bufidx;
	reg        dph;                     // the decode's phase
	reg signed [31:0] d_s;
	reg signed [15:0] d_p1, d_p2;
	// (timing: the rate test, the Gauss taps and the FIR are spread over clocks)
	reg [31:0] fires_v;                 // this sample: which of the 32 rates step
	reg [5:0]  rr;                      // the rate being worked out
	reg [15:0] rv; reg [3:0] rn; reg [2:0] rk; reg [4:0] rr_d; reg rvalid;
	reg        iph;                     // the Gauss tap's phase: 0 fetch, 1 multiply-add
	reg signed [15:0] it_s; reg [10:0] it_g;
	reg signed [15:0] isamp;
	reg [3:0]  fk_n;                    // the FIR tap
	reg signed [31:0] fal, far_;

	wire signed [15:0] noise15 = {noise[14], noise};
	wire [6:0] vb = {x, 4'h0};

	integer i;
	reg signed [31:0] s20, p1, p2;
	reg signed [31:0] m32;
	reg [3:0] nib;
	reg [3:0] shift_;
	reg [1:0] filt;
	reg [7:0] gi;
	reg [3:0] tap;
	reg signed [15:0] s16v;
	reg [13:0] step;
	reg [15:0] pstep;
	reg [4:0] rate;
	reg signed [12:0] estep;
	reg signed [12:0] e13;
	reg [10:0] e11;
	reg [7:0] a1, a2, g;
	reg signed [31:0] acc20;
	reg signed [15:0] t16;
	reg [7:0] endx;

	always @(posedge clk) begin
		out_stb <= 1'b0;
		ram_we <= 1'b0;
		if (rst) begin
			for (i = 0; i < 128; i = i + 1) R[i] <= 8'h00;
			R[7'h6C] <= 8'hE0;
			for (i = 0; i < 8; i = i + 1) begin
				env[i] <= 0; hidden[i] <= 0; vmode[i] <= RELEASE; kdel[i] <= 0; baddr[i] <= 0; boff[i] <= 1;
				bpos[i] <= 0; vpos[i] <= 0; fir_l[i] <= 0; fir_r[i] <= 0;
			end
			for (i = 0; i < 96; i = i + 1) buf_[i] <= 16'sd0;
			counter <= 16'd0; noise <= 15'h4000; kon <= 8'h00; new_kon <= 8'h00; every_other <= 1'b0;
			echo_idx <= 0; echo_len <= 0; fir_i <= 0; ws <= W_IDLE;
		end else begin
			// the SPC700's writes (any write to ENDX clears it)
			if (r_we) begin
				R[r_addr] <= (r_addr == 7'h7C) ? 8'h00 : r_wdata;
				if (r_addr == 7'h4C) new_kon <= r_wdata;
			end

			case (ws)
			W_IDLE: if (sample) ws <= W_START;
			W_START: begin
				counter <= (counter == 16'd0) ? 16'h77FF : counter - 16'd1;
				every_other <= !every_other;
				kphase <= !every_other;
				if (!every_other) begin kon <= new_kon; new_kon <= 8'h00; koff <= R[7'h5C]; end
				main_l <= 0; main_r <= 0; echo_l <= 0; echo_r <= 0; prev_out <= 0;
				x <= 3'd0;
				rr <= 6'd0; rvalid <= 1'b0;
				ws <= W_RATES;
			end
			// which rates step this sample: (counter + offset) % (k << n) == 0, two stages a rate
			W_RATES: begin : rates
				reg [3:0] n_; reg [2:0] k_; reg [15:0] off_; reg [15:0] q_;
				// stage 1: rate rr's shape and the counter plus its offset
				case (rr[4:0])
				5'd28: begin k_ = 1; n_ = 2; end
				5'd29: begin k_ = 3; n_ = 0; end
				5'd30: begin k_ = 1; n_ = 1; end
				5'd31: begin k_ = 1; n_ = 0; end
				default: case ((rr[4:0] - 5'd1) % 3)
					0: begin k_ = 1; n_ = 4'd11 - (rr[4:0] - 5'd1) / 3; end
					1: begin k_ = 3; n_ = 4'd9 - (rr[4:0] - 5'd1) / 3; end
					default: begin k_ = 5; n_ = 4'd8 - (rr[4:0] - 5'd1) / 3; end
					endcase
				endcase
				case ((rr[4:0] - 5'd1) % 3)
				0: off_ = 16'd0;
				1: off_ = 16'd1040;
				default: off_ = 16'd536;
				endcase
				rv <= counter + off_; rn <= n_; rk <= k_; rr_d <= rr[4:0]; rvalid <= !rr[5];
				// stage 2: the test, for the rate before
				if (rvalid) begin
					q_ = rv >> rn;
					fires_v[rr_d] <= (rr_d != 5'd0) && ((rv & ((16'd1 << rn) - 16'd1)) == 16'd0) &&
					                 (rk == 3'd1 ? 1'b1 : rk == 3'd3 ? (q_ % 3 == 0) : (q_ % 5 == 0));
				end
				rr <= rr + 6'd1;
				if (rr == 6'd32) ws <= W_NOISE;
			end
			W_NOISE: begin
				if (fires_v[R[7'h6C][4:0]]) noise <= {noise[0] ^ noise[1], noise[14:1]};
				ws <= W_VOICE;
			end

			// ---------- a voice ----------
			W_VOICE: begin
				if (kphase && kon[x]) begin
					// key on: the start address from the directory
					kdel[x] <= 3'd5; vmode[x] <= ATTACK; env[x] <= 0; hidden[x] <= 0;
					vpos[x] <= 0; bpos[x] <= 0;
					for (i = 0; i < 12; i = i + 1) buf_[x * 12 + i] <= 16'sd0;
					R[7'h7C][x] <= 1'b0;
					ram_a <= {R[7'h5D], 8'h00} + {6'd0, R[vb | 7'h4], 2'b00};
					ws <= W_DIR0;
				end else ws <= W_DIR2;
			end
			W_DIR0: begin ram_a <= ram_a + 16'd1; ws <= W_DIR1; end
			W_DIR1: begin baddr[x][7:0] <= ram_q; ws <= W_BLK0; end
			W_BLK0: begin baddr[x][15:8] <= ram_q; boff[x] <= 4'd1; ws <= W_DIR2; end
			W_DIR2: begin
				// key off; FLG's soft reset
				if (kphase && koff[x]) vmode[x] <= RELEASE;
				if (R[7'h6C][7]) begin vmode[x] <= RELEASE; env[x] <= 11'd0; end
				if (kdel[x] != 3'd0) begin
					kdel[x] <= kdel[x] - 3'd1;
					vout <= 16'sd0; vpos[x] <= 15'd0;
					if (kdel[x] == 3'd4 || kdel[x] == 3'd3 || kdel[x] == 3'd2) begin wret <= W_MIX; ws <= W_DEC0; end
					else ws <= W_MIX;
				end else begin
					ik <= 2'd0; iacc <= 32'sd0; iph <= 1'b0;
					ws <= W_INT;
				end
			end

			// ---------- the Gauss interpolation (or the noise) ----------
			W_INT: begin
				if (!iph) begin
					// fetch: the tap's sample and its Gauss weight
					gi = vpos[x][11:4];
					tap = bpos[x] + {1'b0, vpos[x][14:12]} + {2'b0, ik};
					if (tap >= 4'd12) tap = tap - 4'd12;
					if (tap >= 4'd12) tap = tap - 4'd12;
					it_s <= buf_[x * 12 + tap];
					case (ik)
					2'd0: it_g <= gauss_rom(9'h0FF - {1'b0, gi});
					2'd1: it_g <= gauss_rom(9'h1FF - {1'b0, gi});
					2'd2: it_g <= gauss_rom(9'h100 + {1'b0, gi});
					default: it_g <= gauss_rom({1'b0, gi});
					endcase
					iph <= 1'b1;
				end else begin
					m32 = $signed({1'b0, it_g}) * it_s;
					iph <= 1'b0;
					case (ik)
					2'd0, 2'd1: iacc <= iacc + (m32 >>> 10);
					2'd2: begin acc20 = iacc + (m32 >>> 10); iacc <= {{16{acc20[15]}}, acc20[15:0]}; end   // wraps
					default: begin
						acc20 = iacc + (m32 >>> 10);
						t16 = clamp16(acc20);
						isamp <= R[7'h3D][x] ? noise15 : (t16 >>> 1);
						ws <= W_INT2;
					end
					endcase
					ik <= ik + 2'd1;
				end
			end
			W_INT2: begin
				// the 15-bit sample times the envelope
				m32 = isamp * $signed({1'b0, env[x]});
				vout <= (m32 >>> 11) & ~32'sd1;
				ws <= W_ENV;
			end

			// ---------- the envelope ----------
			W_ENV: begin
				a1 = R[vb | 7'h5]; a2 = R[vb | 7'h6]; g = R[vb | 7'h7];
				e13 = {2'b00, env[x]};
				if (vmode[x] == RELEASE) begin
					e13 = e13 - 13'sd8;
					env[x] <= (e13 < 0) ? 11'd0 : e13[10:0];
				end else begin
					rate = 5'd0; estep = 13'sd0;
					if (a1[7]) begin
						case (vmode[x])
						ATTACK: begin rate = {a1[3:0], 1'b1}; estep = (rate == 5'd31) ? 13'sd1024 : 13'sd32; end
						DECAY:  begin rate = {2'b10, a1[6:4]} << 1; rate = {1'b1, a1[6:4], 1'b0}; estep = -($signed({2'b00, env[x]} - 13'sd1) >>> 8) - 13'sd1; end
						default: begin rate = a2[4:0]; estep = -($signed({2'b00, env[x]} - 13'sd1) >>> 8) - 13'sd1; end
						endcase
					end else if (!g[7]) begin
						env[x] <= {g[6:0], 4'd0}; hidden[x] <= {g[6:0], 4'd0};
						e13 = {2'b00, g[6:0], 4'd0};
					end else begin
						rate = g[4:0];
						case (g[6:5])
						2'd0: estep = -13'sd32;
						2'd1: estep = -($signed({2'b00, env[x]} - 13'sd1) >>> 8) - 13'sd1;
						2'd2: estep = 13'sd32;
						default: estep = (hidden[x] < 11'h600) ? 13'sd32 : 13'sd8;
						endcase
					end
					if (vmode[x] == DECAY && e13[10:8] == (a1[7] ? a2[7:5] : g[7:5])) vmode[x] <= SUSTAIN;
					if (fires_v[rate]) begin
						e13 = e13 + estep;
						hidden[x] <= e13[10:0];
						e11 = (e13 < 0) ? 11'd0 : (e13 > 13'sd2047) ? 11'h7FF : e13[10:0];
						env[x] <= e11;
						if (vmode[x] == ATTACK && e11 >= 11'h7E0) vmode[x] <= DECAY;
					end else if (vmode[x] == ATTACK && e13 >= 13'sd2016) vmode[x] <= DECAY;
				end
				ws <= W_PITCH;
			end

			// ---------- the pitch ----------
			W_PITCH: begin
				step = {R[vb | 7'h3][5:0], R[vb | 7'h2]};
				if (R[7'h2D][x] && x != 3'd0) begin
					m32 = $signed({18'd0, step}) * $signed((prev_out >>> 4) + 16'sd1024);
					step = m32[23:10];
					pstep = m32[25:10];
				end else pstep = {2'b00, step};
				if ({1'b0, vpos[x]} + pstep > 17'h7FFF) vpos[x] <= 15'h7FFF;
				else vpos[x] <= vpos[x] + pstep[14:0];
				if (({1'b0, vpos[x]} + pstep) >= 17'h4000) begin
					// (the new position, less 4000h, after the decode)
					wret <= W_MIX; ws <= W_DEC0;
				end else ws <= W_MIX;
			end

			// ---------- four more BRR samples ----------
			W_DEC0: begin ram_a <= baddr[x]; ws <= W_DEC1; end
			W_DEC1: begin ram_a <= baddr[x] + {12'd0, boff[x]}; ws <= W_DEC2; end
			W_DEC2: begin hdr <= ram_q; ram_a <= baddr[x] + {12'd0, boff[x]} + 16'd1; ws <= W_DEC3; end
			W_DEC3: begin db0 <= ram_q; ws <= W_DECN; dk <= 3'd0; dph <= 1'b0; end
			W_DECN: if (!dph) begin
				// (two clocks a sample: this one the nibble and the two before it, read out)
				if (dk == 3'd0) db1 <= ram_q;
				nib = (dk == 3'd0) ? db0[7:4] : (dk == 3'd1) ? db0[3:0] : (dk == 3'd2) ? ram_q[7:4] : db1[3:0];
				if (dk == 3'd2) nib = db1[7:4];
				if (dk == 3'd0) nib = db0[7:4];
				shift_ = hdr[7:4];
				s20 = $signed({{28{nib[3]}}, nib});
				if (shift_ <= 4'd12) s20 = (s20 <<< shift_) >>> 1;
				else s20 = nib[3] ? -20'sd2048 : 20'sd0;
				d_s <= s20;
				bufidx = (bpos[x] == 4'd0) ? 4'd11 : bpos[x] - 4'd1;
				d_p1 <= buf_[x * 12 + bufidx];
				bufidx = (bpos[x] == 4'd0) ? 4'd10 : (bpos[x] == 4'd1) ? 4'd11 : bpos[x] - 4'd2;
				d_p2 <= buf_[x * 12 + bufidx];
				dph <= 1'b1;
			end else begin
				// (this one the filter, and the sample in)
				dph <= 1'b0;
				filt = hdr[3:2];
				s20 = d_s; p1 = d_p1; p2 = d_p2;
				case (filt)
				2'd1: s20 = s20 + p1 + ((-p1) >>> 4);
				2'd2: s20 = s20 + (p1 <<< 1) + ((-(p1 * 3)) >>> 5) - p2 + (p2 >>> 4);
				2'd3: s20 = s20 + (p1 <<< 1) + ((-(p1 * 13)) >>> 6) - p2 + ((p2 * 3) >>> 4);
				default: ;
				endcase
				t16 = clamp16(s20);
				buf_[x * 12 + bpos[x]] <= {t16[14], t16[14:0]};         // (15 bits: bit 15 lost)
				bpos[x] <= (bpos[x] == 4'd11) ? 4'd0 : bpos[x] + 4'd1;
				dk <= dk + 3'd1;
				if (dk == 3'd3) begin
					boff[x] <= boff[x] + 4'd2;
					if (boff[x] + 4'd2 > 4'd8) begin
						boff[x] <= 4'd1;
						if (hdr[0]) begin
							R[7'h7C][x] <= 1'b1;
							ram_a <= {R[7'h5D], 8'h00} + {6'd0, R[vb | 7'h4], 2'b00} + 16'd2;
							if (!hdr[1]) begin vmode[x] <= RELEASE; env[x] <= 11'd0; end
							ws <= W_BLK1;
						end else begin baddr[x] <= baddr[x] + 16'd9; ws <= wret; end
					end else ws <= wret;
					if (wret == W_MIX && kdel[x] == 3'd0) vpos[x] <= vpos[x] - 15'h4000;
				end
			end
			W_BLK1: begin ram_a <= ram_a + 16'd1; ws <= W_BLK2; end
			W_BLK2: begin baddr[x][7:0] <= ram_q; ws <= W_BLK0 + 5'd0; wret <= wret; ws <= 5'd25; end
			5'd25:  begin baddr[x][15:8] <= ram_q; ws <= wret; end

			// ---------- this voice's output, the mixes ----------
			W_MIX: begin
				prev_out <= vout;
				R[vb | 7'h8] <= {1'b0, env[x][10:4]};
				R[vb | 7'h9] <= vout[14:7];
				m32 = vout * $signed(R[vb | 7'h0]);
				main_l <= clamp16(main_l + (m32 >>> 6));
				if (R[7'h4D][x]) echo_l <= clamp16(echo_l + (m32 >>> 6));
				m32 = vout * $signed(R[vb | 7'h1]);
				main_r <= clamp16(main_r + (m32 >>> 6));
				if (R[7'h4D][x]) echo_r <= clamp16(echo_r + (m32 >>> 6));
				x <= x + 3'd1;
				if (x == 3'd7) begin
					if (kphase) kon <= 8'h00;
					eaddr <= {R[7'h6D], 8'h00} + {echo_idx[13:0], 2'b00};
					ek <= 3'd0;
					ws <= W_ECHO0;
				end else ws <= W_VOICE;
			end

			// ---------- the echo ----------
			W_ECHO0: begin ram_a <= eaddr; ek <= 3'd0; fir_i <= fir_i + 3'd1; ws <= W_ECHO1; end
			W_ECHO1: begin
				// four bytes: left lo, hi, right lo, hi
				ram_a <= eaddr + {13'd0, ek} + 16'd1;
				if (ek != 3'd0) begin
					case (ek)
					3'd1: ew[7:0] <= ram_q;
					3'd2: fir_l[fir_i] <= $signed({ram_q, ew[7:0]}) >>> 1;
					3'd3: ew[7:0] <= ram_q;
					default: ;
					endcase
				end
				if (ek == 3'd4) begin fir_r[fir_i] <= $signed({ram_q, ew[7:0]}) >>> 1; ws <= W_FIR; end
				ek <= ek + 3'd1;
			end
			W_FIR: begin
				// the seven oldest taps, one a clock (16-bit sums, no overflow handling)
				fal <= 32'sd0; far_ <= 32'sd0; fk_n <= 4'd0;
				ws <= W_FIRD;
			end
			W_FIRD: begin : fird
				reg [2:0] fk; reg signed [31:0] al, ar;
				fk = fir_i + 3'd1 + fk_n[2:0];          // (fir_i - 7 + k, mod 8)
				if (fk_n != 4'd7) begin
					al = fal + ((fir_l[fk] * $signed(R[{fk_n[2:0], 4'hF}])) >>> 6);
					ar = far_ + ((fir_r[fk] * $signed(R[{fk_n[2:0], 4'hF}])) >>> 6);
					fal <= al; far_ <= ar;
					fk_n <= fk_n + 4'd1;
				end else begin
					// the newest, with the 16-bit wrap first and the clamp after
					al = {{16{fal[15]}}, fal[15:0]};
					ar = {{16{far_[15]}}, far_[15:0]};
					fl <= clamp16(al + ((fir_l[fir_i] * $signed(R[7'h7F])) >>> 6));
					fr <= clamp16(ar + ((fir_r[fir_i] * $signed(R[7'h7F])) >>> 6));
					ws <= W_EOUT;
				end
			end
			W_EOUT: begin
				out_l <= R[7'h6C][6] ? 16'sd0 : clamp16((($signed(main_l[15:0]) * $signed(R[7'h0C])) >>> 7) + ((fl * $signed(R[7'h2C])) >>> 7));
				out_r <= R[7'h6C][6] ? 16'sd0 : clamp16((($signed(main_r[15:0]) * $signed(R[7'h1C])) >>> 7) + ((fr * $signed(R[7'h3C])) >>> 7));
				out_stb <= 1'b1;
				t16 = clamp16(echo_l + ((fl * $signed(R[7'h0D])) >>> 7));
				echo_in_l <= t16 & ~16'sd1;
				t16 = clamp16(echo_r + ((fr * $signed(R[7'h0D])) >>> 7));
				echo_in_r <= t16 & ~16'sd1;
				ek <= 3'd0;
				ws <= W_EWR;
			end
			W_EWR: begin
				if (!R[7'h6C][5]) begin
					ram_we <= 1'b1;
					ram_a <= eaddr + {13'd0, ek};
					case (ek[1:0])
					2'd0: ram_wd <= echo_in_l[7:0];
					2'd1: ram_wd <= echo_in_l[15:8];
					2'd2: ram_wd <= echo_in_r[7:0];
					default: ram_wd <= echo_in_r[15:8];
					endcase
				end
				ek <= ek + 3'd1;
				if (ek == 3'd3) ws <= W_END;
			end
			W_END: begin
				if (echo_idx == 15'd0) echo_len <= {R[7'h7D][3:0], 9'd0} ;
				if (echo_idx + 15'd1 >= ((echo_idx == 15'd0) ? {2'd0, R[7'h7D][3:0], 9'd0} : echo_len)) echo_idx <= 15'd0;
				else echo_idx <= echo_idx + 15'd1;
				ws <= W_IDLE;
			end
			default: ws <= W_IDLE;
			endcase
		end
	end
endmodule
