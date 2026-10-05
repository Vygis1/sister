`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// md_sound.v - the Mega Drive's other computer.
//
// A Z80 with eight kilobytes of its own, sitting next to the sound chips. It is
// a leftover: the machine was designed to run Master System games, and the Z80
// that did that stayed on to drive the music. Games use it that way -- a sound
// driver in Z80 code, fed commands by the 68000 through a byte in shared RAM.
//
// The Z80 here is the one that already passes ZEXDOC and ZEXALL on hardware.
// What this file adds is everything AROUND it:
//
//   $0000-$1FFF  its RAM, mirrored again at $2000
//   $4000-$4003  the YM2612
//   $6000        the bank register, one bit at a time
//   $7F11        the SN76489, the same chip the Master System core drives
//   $8000-$FFFF  a window into the 68000's memory, 32 kB at a time
//
// The window is how a sound driver reads its music out of the cartridge, and
// the bank register is how it chooses which 32 kB. That register is a SHIFT
// REGISTER: nine writes, one bit each, least significant first. A driver that
// sets it with a single write gets whatever one bit it happened to send.
//
// --- who has the bus ---------------------------------------------------------
//
// The 68000 can stop the Z80 and take its RAM, which is how it loads the driver
// in the first place and how it passes commands afterwards. It asks at $A11100
// and lets go by writing zero there; it holds the Z80 in reset from $A11200.
// While either of those is true the Z80 is not running, which is what makes it
// safe for one port of the RAM to serve both.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module md_sound (
	input  wire        clk,
	input  wire        rst,
	input  wire        z_ce,         // nominally 3.58 MHz
	input  wire        fm_ce,        // one FM sample, nominally 53 kHz

	// --- what the 68000 sees at $A00000 -----------------------------------------
	// The 68000 sees the Z80's WHOLE address space through its window, not just
	// the RAM -- which is how a game writes the FM chip without waking the Z80.
	input  wire        m_sel,
	input  wire [15:0] m_addr,
	input  wire        m_wr,
	input  wire [7:0]  m_din,
	output wire [7:0]  m_dout,

	input  wire        busreq,       // the 68000 is asking for the bus
	input  wire        z_reset_n,
	input  wire        z_int,        // the VDP's interrupt (vertical blank, a line long)
	output wire        busack,       // and has it

	// --- the window into the 68000's memory ----------------------------------------
	// A byte address. The cartridge answers with the word containing it -- but it
	// is a cache in front of DDR3, so it may not answer at once, and the Z80 has
	// to be able to wait for it.
	output wire [23:0] win_addr,
	output wire        win_req,
	input  wire [15:0] win_data,
	input  wire        win_ready,

	// --- audio --------------------------------------------------------------------
	output wire signed [15:0] sample_l,
	output wire signed [15:0] sample_r,

	output wire [15:0] dbg_pc
);

	// The Z80 stops for either reason, and only then may the 68000 touch its RAM.
	wire stopped = busreq || !z_reset_n;
	assign busack = stopped;

	wire [15:0] z_addr;
	wire [7:0]  z_dout;
	reg  [7:0]  z_din;
	wire        z_we, z_io, z_m1;

	// --- the map ---------------------------------------------------------------------
	// Above the processor, because whether the Z80 gets an enable at all depends
	// on where it is pointing.
	wire z_ram  = (z_addr[15:14] == 2'b00);     // and its mirror at $2000
	wire z_ym   = (z_addr[15:13] == 3'b010);
	wire z_bank = (z_addr[15:8]  == 8'h60);
	wire z_psg  = (z_addr[15:8]  == 8'h7F);
	wire z_win  = z_addr[15];
	assign win_req = z_win && !stopped;

	// Stopped for the 68000, or waiting for the cartridge. The Z80 has no wait
	// state of its own here; it simply does not get an enable.
	wire z_run = z_ce && !stopped && !(z_win && !win_ready);

	z80 cpu (
		.clk(clk), .rst(rst || !z_reset_n), .ce(z_run),
		.addr(z_addr), .din(z_din), .dout(z_dout),
		.we(z_we), .io(z_io), .m1(z_m1),
		.int_n(!z_int), .nmi_n(1'b1),
		.dbg_pc(dbg_pc), .dbg_sp(), .dbg_af(), .dbg_bc(), .dbg_de(),
		.dbg_hl(), .dbg_m1()
	);

	// --- eight kilobytes, shared ---------------------------------------------------------
	// One write port, with its address and data muxed. The two users can never
	// both want it -- the 68000 only reaches here while the Z80 is stopped -- but
	// saying so with a mux rather than with two conditional writes is what keeps
	// this as block RAM instead of eight thousand flip-flops.
	reg [7:0] zram [0:8191];
	reg [7:0] zram_q, m_q;

	// The 68000 reaches the RAM only while the Z80 is stopped, and only for the
	// part of the window that IS the RAM.
	wire m_ram = m_sel && (m_addr[15:14] == 2'b00);
	wire m_ym  = m_sel && (m_addr[15:13] == 3'b010);

	// Two ports, the Z80's and the 68000's. They were one, its address switched to the
	// 68000's while the Z80 was stopped -- so a Z80 stopped in the middle of a read came
	// back to the 68000's byte instead of its own. Battletoads' driver, stopped in the
	// operand of its JR $, jumped into its interrupt handler instead, returned off an
	// empty stack and ran off into the cartridge: no sound. Now the Z80's read register
	// holds its own byte however long it is stopped.
	always @(posedge clk) begin
		if (z_run && z_we && z_ram) zram[z_addr[12:0]] <= z_dout;
		zram_q <= zram[z_addr[12:0]];
	end
	always @(posedge clk) begin
		if (stopped && m_ram && m_wr) zram[m_addr[12:0]] <= m_din;
		m_q <= zram[m_addr[12:0]];
	end

	// --- the bank register ------------------------------------------------------------------
	// Nine writes, one bit each, arriving least significant first -- so the bit
	// goes in at the TOP and the register shifts down.
	reg [8:0] bank;
	always @(posedge clk) begin
		if (rst) bank <= 9'd0;
		else if (z_run && z_we && z_bank) bank <= {z_dout[0], bank[8:1]};
	end

	assign win_addr = {bank, z_addr[14:0]};

	// --- the sound chips ---------------------------------------------------------------------
	// The SN76489 is the Master System's, unchanged. The FM chip is reachable
	// from either processor -- the Z80 at $4000 in its own space, the 68000
	// through the same addresses in the window -- and a game uses whichever is
	// convenient.
	wire [15:0] psg_sample;
	psg sn (
		.clk(clk), .rst(rst), .ce(z_ce),
		.din(z_dout), .we(z_run && z_we && z_psg),
		.sample(psg_sample)
	);

	wire       ym_cs = (z_run && z_ym) || (stopped && m_ym);
	wire [1:0] ym_a  = stopped ? m_addr[1:0] : z_addr[1:0];
	wire       ym_wr = stopped ? m_wr        : z_we;
	wire [7:0] ym_di = stopped ? m_din       : z_dout;
	wire [7:0] ym_do;
	wire signed [15:0] ym_l, ym_r;

	ym2612 fm (
		.clk(clk), .rst(rst), .ce(fm_ce),
		.cs(ym_cs), .a(ym_a), .wr(ym_wr), .din(ym_di), .dout(ym_do),
		.left(ym_l), .right(ym_r),
		.dbg_timer_a(), .dbg_timer_b(), .dbg_keyon()
	);

	// What the 68000 reads out of the window: the RAM, or the FM chip's status.
	assign m_dout = m_ym ? ym_do : m_q;

	// --- mixing ---------------------------------------------------------------------------------
	// The PSG's samples are unsigned around $8000 and the FM chip's are signed
	// around zero, so they have to be lined up before they can be added. The PSG
	// is halved because on a real Mega Drive it is the quieter of the two by a
	// long way, and the sum is clamped rather than allowed to wrap -- a wrap is
	// not a quiet distortion, it is a full-scale click.
	wire signed [16:0] psg_s = $signed({1'b0, psg_sample}) - 17'sd32768;

	function signed [15:0] clamp;
		input signed [17:0] v;
		begin
			if (v >  18'sd32767)      clamp =  16'sd32767;
			else if (v < -18'sd32768) clamp = -16'sd32768;
			else                      clamp = v[15:0];
		end
	endfunction

	assign sample_l = clamp($signed({{2{ym_l[15]}}, ym_l})
	                        + $signed({{2{psg_s[16]}}, psg_s[16:1]}));
	assign sample_r = clamp($signed({{2{ym_r[15]}}, ym_r})
	                        + $signed({{2{psg_s[16]}}, psg_s[16:1]}));

	// --- what the Z80 reads ----------------------------------------------------------------------
	always @(*) begin
		if (z_ram)      z_din = zram_q;
		else if (z_ym)  z_din = ym_do;
		else if (z_win) z_din = z_addr[0] ? win_data[7:0] : win_data[15:8];
		else            z_din = 8'hFF;
	end

endmodule

`default_nettype wire
