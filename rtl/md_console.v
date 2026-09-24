`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// md_console.v - the Mega Drive, in the shape the rest of this project expects.
//
// md_top.v is the machine. This is the adapter around it: the clock enables that
// make its four chips run at their own speeds, and the conversion from the VDP's
// colours to the framebuffer's. Everything that is specific to THIS project
// rather than to a Mega Drive lives here, so that md_top stays a description of
// the console and not of the board it happens to be on.
//
// --- the clock ---------------------------------------------------------------------
//
// A Mega Drive's master clock is 53.693175 MHz, and every part of it is that
// divided by an integer:
//
//   68000    / 7    7.67 MHz
//   VDP      / 4   13.42 MHz   in H40; the real part uses / 5 for H32
//   Z80      / 15   3.58 MHz
//   YM2612   / 7 / 144         53.3 kHz
//
// So this module wants 53.693 MHz, not the board's 50, and expects an MMCM in
// front of it. Running it at 50 would make every one of those ratios wrong
// together -- which sounds harmless, and means a game's music runs seven per
// cent flat and its frame rate is 56 Hz rather than 60.
//
// --- the picture --------------------------------------------------------------------
//
// The VDP produces nine bits of colour, three each way. The framebuffer here
// takes eight, RGB332, so one bit of blue is dropped -- the same bit the Mega
// Drive's own composite output loses to the encoder, as it happens.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module md_console (
	input  wire        clk,          // 53.693 MHz, from an MMCM
	input  wire        rst,

	// --- the cartridge, through the cache, out to DDR3 ----------------------------
	output wire [19:0]  mem_addr,
	output wire         mem_req,
	input  wire         mem_ready,
	input  wire [127:0] mem_data,
	input  wire         mem_valid,

	// --- controllers --------------------------------------------------------------
	input  wire [7:0]  joy1,
	input  wire [7:0]  joy2,

	// --- pixels for the framebuffer -------------------------------------------------
	output wire        px_valid,
	output wire [8:0]  px_x,
	output wire [8:0]  px_y,
	output wire [7:0]  px_rgb,

	// --- audio ------------------------------------------------------------------------
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	output wire [31:0] dbg_pc
);

	// --- the four enables ---------------------------------------------------------------
	// Free-running dividers rather than one chain, because the ratios between
	// them are not powers of two and a chain would make them drift apart.
	reg [2:0]  d_cpu;
	reg [1:0]  d_vdp;
	reg [3:0]  d_z80;
	reg [10:0] d_fm;

	wire cpu_ce = (d_cpu == 3'd6);
	wire vdp_ce = (d_vdp == 2'd3);
	wire snd_ce = (d_z80 == 4'd14);
	wire fm_ce  = (d_fm  == 11'd1007);    // 7 * 144

	always @(posedge clk) begin
		if (rst) begin
			d_cpu <= 3'd0;
			d_vdp <= 2'd0;
			d_z80 <= 4'd0;
			d_fm  <= 11'd0;
		end else begin
			d_cpu <= cpu_ce ? 3'd0  : d_cpu + 3'd1;
			d_vdp <= vdp_ce ? 2'd0  : d_vdp + 2'd1;
			d_z80 <= snd_ce ? 4'd0  : d_z80 + 4'd1;
			d_fm  <= fm_ce  ? 11'd0 : d_fm + 11'd1;
		end
	end

	// --- the machine -----------------------------------------------------------------------
	wire [9:0] vx, vy;
	wire       vpe;
	wire [8:0] vcol;

	md_top md (
		.clk(clk), .rst(rst),
		.cpu_ce(cpu_ce), .vdp_ce(vdp_ce), .snd_ce(snd_ce), .fm_ce(fm_ce),
		.mem_addr(mem_addr), .mem_req(mem_req), .mem_ready(mem_ready),
		.mem_data(mem_data), .mem_valid(mem_valid),
		.px(vx), .py(vy), .pixel_en(vpe), .color(vcol),
		.audio_l(audio_l), .audio_r(audio_r),
		.joy1(joy1), .joy2(joy2),
		.h40(md_h40),
		.dbg_pc(dbg_pc), .dbg_halted()
	);

	// --- to the framebuffer -------------------------------------------------------------------
	// The VDP's colour word is blue, green, red, three bits each, in that order.
	// RGB332 wants red first and has only two bits of blue, so the bottom bit of
	// blue is the one that goes.
	// In H32 the picture is 256 across and the framebuffer is 320, so the last 64
	// columns of every line belong to nobody. Left alone they keep whatever was
	// there before -- which is the video generator's colour bars, sitting down
	// the right-hand edge of the game looking like a fault in it.
	//
	// So keep emitting past the end of the picture and emit black. The line is
	// 342 clocks wide in H32, so there is room for all 320 either way.
	wire        md_h40;
	wire [9:0]  active_w = md_h40 ? 10'd320 : 10'd256;
	wire        in_line  = (vy < 10'd224);

	assign px_valid = vdp_ce && in_line && (vx < 10'd320);
	assign px_x     = vx[8:0];
	assign px_y     = vy[8:0];
	assign px_rgb   = (vx < active_w) ? {vcol[2:0], vcol[5:3], vcol[8:7]} : 8'h00;

endmodule

`default_nettype wire
