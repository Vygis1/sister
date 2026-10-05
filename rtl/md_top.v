`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// md_top.v - a Mega Drive, as far as it goes.
//
// The 68000 and the VDP built next door, wired together with the memory map
// between them. That map is most of what this file is, and it is worth writing
// out because the Mega Drive's is unusually sparse -- eight megabytes of
// cartridge, a hole, and then everything else crammed into the top.
//
//   $000000-$3FFFFF   cartridge
//   $A00000-$A0FFFF   the Z80's world, seen through a window
//   $A10000-$A1001F   controllers and the version register
//   $A11100           Z80 bus request
//   $A11200           Z80 reset
//   $C00000-$C00007   the VDP: data at 0 and 2, control at 4 and 6
//   $C00008           the H/V counter
//   $FF0000-$FFFFFF   64 kB of work RAM
//
// What is here: the 68000, the VDP, the work RAM, the Z80 and its sound chips,
// and the arbitration between all of them -- including the part where a VDP DMA
// takes the bus away from the 68000 and reads the 68000's own memory with it,
// and the part where the 68000 takes the bus away from the Z80.
//
// What is not: the FM chip's operators. Its registers and timers are real and a
// driver can use them; what it cannot yet do is make an FM sound.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module md_top (
	input  wire        clk,
	input  wire        rst,

	// The 68000 runs at 7.67 MHz and the VDP's pixel clock is 13.4 MHz, so they
	// get separate enables rather than a shared one.
	input  wire        cpu_ce,
	input  wire        vdp_ce,
	input  wire        snd_ce,       // the Z80's, nominally 3.58 MHz
	input  wire        fm_ce,        // one FM sample, nominally 53 kHz

	// --- the cartridge -----------------------------------------------------------
	// Straight through to cart_cache, which is what makes DDR3 look like a ROM.
	// It answers in one cycle when it has the line and in tens when it does not,
	// so everything that reads it here has to be able to wait.
	output wire [19:0] mem_addr,
	output wire        mem_req,
	input  wire        mem_ready,
	input  wire [127:0] mem_data,
	input  wire        mem_valid,

	// --- video out ----------------------------------------------------------------
	output wire [9:0]  px,
	output wire [9:0]  py,
	output wire        pixel_en,
	output wire [8:0]  color,

	// --- audio ---------------------------------------------------------------------
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// --- controllers ------------------------------------------------------------------
	// One bit per button, active HIGH. The inversion the real ports do happens
	// once, below, rather than at every call site.
	//
	//   7 start   6 A   5 C   4 B   3 right   2 left   1 down   0 up
	input  wire [7:0]  joy1,
	input  wire [7:0]  joy2,

	// --- for a testbench to look at -------------------------------------------------
	output wire        h40,
	output wire [31:0] dbg_pc,
	output wire [15:0] dbg_z80_pc,      // the sound CPU's, for the debug window
	output wire        dbg_halted
);

	// --- the 68000 --------------------------------------------------------------------
	wire [23:0] cpu_addr;
	wire [15:0] cpu_dout;
	wire        cpu_we, cpu_req;
	wire [1:0]  cpu_ds;
	reg  [15:0] cpu_din;
	wire [2:0]  ipl_n;

	// A DMA takes the bus, so the processor simply does not get an enable until
	// it is over. That is exactly what the real machine does to it, and it is why
	// a game can start a DMA and assume the next instruction runs afterwards.
	//
	// The cartridge can hold it up too. Both are the same mechanism: no enable,
	// so no progress, so nothing has to know how to retry.
	wire dma_busy;
	wire cart_ready;
	wire cpu_en = cpu_ce && !dma_busy && cart_ready;

	m68k cpu (
		.clk(clk), .rst(rst), .ce(cpu_en),
		.addr(cpu_addr), .din(cpu_din), .dout(cpu_dout),
		.we(cpu_we), .ds(cpu_ds), .req(cpu_req),
		.ipl_n(ipl_n), .iack(cpu_iack),
		.dbg_pc(dbg_pc), .dbg_ir(), .dbg_sr(), .dbg_halted(dbg_halted),
		.dbg_d0(), .dbg_a7()
	);

	// --- the map ------------------------------------------------------------------------
	wire sel_cart = (cpu_addr[23:22] == 2'b00);
	wire sel_ram  = (cpu_addr[23:16] == 8'hFF);
	wire sel_vdp  = (cpu_addr[23:16] == 8'hC0);
	wire sel_z    = (cpu_addr[23:16] == 8'hA0);
	wire sel_io   = (cpu_addr[23:16] == 8'hA1);

	// --- the controller ports ----------------------------------------------------------
	// A three-button pad answers with two different halves depending on which way
	// the TH line is driven, and a game reads it twice to get all six buttons.
	// Everything is active LOW: a pressed button pulls its line down, and an
	// unplugged port reads as all ones, which is why "nothing pressed" and
	// "nothing there" look the same.
	//
	//   TH high   ? 1 C B right left down up
	//   TH low    ? 0 start A 0    0    down up
	reg [7:0] pad_ctrl1, pad_ctrl2;
	reg [7:0] pad_data1, pad_data2;

	function [7:0] pad_read;
		input [7:0] j;
		input       th;
		begin
			// The two zeroes in the low half are not padding: a game reads them
			// to tell a pad that is plugged in from an empty port, where every
			// line floats high.
			pad_read = th ? {1'b0, 1'b1, ~j[5], ~j[4], ~j[3], ~j[2], ~j[1], ~j[0]}
			              : {1'b0, 1'b0, ~j[7], ~j[6], 1'b0,  1'b0,  ~j[1], ~j[0]};
		end
	endfunction

	// The TH line is an output only if the control register says so; otherwise it
	// floats high, which is the state a game finds it in before it sets anything.
	wire th1 = pad_ctrl1[6] ? pad_data1[6] : 1'b1;
	wire th2 = pad_ctrl2[6] ? pad_data2[6] : 1'b1;

	wire hit_pad = sel_io && (cpu_addr[15:8] == 8'h00);
	wire [7:0] pad_wd = cpu_ds[0] ? cpu_dout[7:0] : cpu_dout[15:8];

	always @(posedge clk) begin
		if (rst) begin
			pad_ctrl1 <= 8'd0;  pad_ctrl2 <= 8'd0;
			pad_data1 <= 8'd0;  pad_data2 <= 8'd0;
		end else if (cpu_req && cpu_we && cpu_en && hit_pad) begin
			// Byte registers on a sixteen-bit bus. Which half of the word carries
			// the byte depends on which strobe the processor asserted, and games
			// write these at both the even and the odd address.
			case (cpu_addr[4:1])
			4'h1: pad_data1 <= pad_wd;
			4'h2: pad_data2 <= pad_wd;
			4'h4: pad_ctrl1 <= pad_wd;
			4'h5: pad_ctrl2 <= pad_wd;
			default: ;
			endcase
		end
	end

	// $A10000 is the version register. Bit 7 says the machine is not Japanese,
	// bit 6 that it is 60 Hz, and the low nibble is the hardware revision; a game
	// checks it to decide which of two region lockouts to complain about.
	wire [7:0] pad_q =
		(cpu_addr[4:1] == 4'h0) ? 8'hA0 :
		(cpu_addr[4:1] == 4'h1) ? pad_read(joy1, th1) :
		(cpu_addr[4:1] == 4'h2) ? pad_read(joy2, th2) :
		(cpu_addr[4:1] == 4'h4) ? pad_ctrl1 :
		(cpu_addr[4:1] == 4'h5) ? pad_ctrl2 : 8'hFF;

	// The two registers that decide whether the Z80 is running. Both are read and
	// written at bit 8, which is the top byte of a word write -- a game sets them
	// with MOVE.W #$0100 and clears them with MOVE.W #$0000.
	reg  z80_busreq;
	reg  z80_reset_n;
	wire z80_busack;

	// $A11100 is the bus request and $A11200 the reset line.
	wire hit_busreq = sel_io && (cpu_addr[15:8] == 8'h11);
	wire hit_reset  = sel_io && (cpu_addr[15:8] == 8'h12);

	always @(posedge clk) begin
		if (rst) begin
			z80_busreq  <= 1'b0;
			// Held in reset out of the box: the 68000 loads the sound driver
			// before it lets the Z80 anywhere near it.
			z80_reset_n <= 1'b0;
		end else if (cpu_req && cpu_we && cpu_en) begin
			if (hit_busreq) z80_busreq  <= cpu_dout[8];
			if (hit_reset)  z80_reset_n <= cpu_dout[8];
		end
	end

	// --- the Z80 and the sound chips --------------------------------------------------------
	wire [7:0]  z_dout;
	wire [23:0] z_win_addr;
	wire        z_win_req;
	wire        z_sel = cpu_req && sel_z && cpu_en;

	// The 68000's bus is sixteen bits and the Z80's is eight, so which half of a
	// write carries the byte depends on which strobe is asserted.
	wire [7:0] z_wdata = cpu_ds[1] ? cpu_dout[15:8] : cpu_dout[7:0];



	md_sound snd (
		.clk(clk), .rst(rst), .z_ce(snd_ce), .fm_ce(fm_ce),
		.m_sel(z_sel), .m_addr(cpu_addr[15:0]), .m_wr(cpu_we),
		.m_din(z_wdata), .m_dout(z_dout),
		.busreq(z80_busreq), .z_reset_n(z80_reset_n), .busack(z80_busack),
		.win_addr(z_win_addr), .win_req(z_win_req),
		.win_data(cart_b_data), .win_ready(cart_b_ready),
		.sample_l(audio_l), .sample_r(audio_r), .dbg_pc(dbg_z80_pc)
	);

	// --- the VDP --------------------------------------------------------------------------
	wire        cart_b_ready;
	wire [15:0] cart_b_data;
	wire [15:0] vdp_dout;
	wire        vdp_dma_req;
	wire [22:0] vdp_dma_addr;
	reg  [15:0] vdp_dma_din;
	reg         vdp_dma_ack;

	// One clock wide. The processor holds its request for a whole enable period,
	// which is several clocks, and a VDP that saw it for all of them would carry
	// out the access -- and step its address -- once per clock.
	wire vdp_sel = cpu_req && sel_vdp && cpu_en && !cpu_addr[3];

	// Data at $C00000-$C00003, control at $C00004-$C00007, and the H/V counter at
	// $C00008-$C0000F. Two address bits, not one.
	//
	// Only bit 2 used to be looked at, so $C00008 aliased onto the data port:
	// a game polling the H/V counter read the data port instead, got something
	// that never became the line number it was waiting for, and span there for
	// good. Combat Cars waits for line $D0 that way at $6e9c -- MOVE.B #$68,D0 /
	// ROL.B #1,D0 / CMP.B (8,A6),D0 / BNE -- which is the top of the frame
	// without the cost of an interrupt, and a common enough idiom that it is
	// worth decoding properly rather than special-casing.
	wire vdp_hv   = cpu_addr[3];
	wire vdp_ctrl = cpu_addr[2] && !vdp_hv;

	wire [15:0] vdp_hv_count;

	// The 68000 acknowledging an interrupt is what lets the VDP drop it.
	wire cpu_iack;
	wire int_ack = cpu_iack && cpu_en;

	md_vdp vdp (
		.clk(clk), .rst(rst), .ce(vdp_ce),
		.cpu_sel(vdp_sel), .cpu_ctrl(vdp_ctrl), .cpu_wr(cpu_we),
		.cpu_din(cpu_dout), .cpu_dout(vdp_dout),
		.ipl_n(ipl_n), .int_ack(int_ack),
		.dma_req(vdp_dma_req), .dma_addr(vdp_dma_addr),
		.dma_din(vdp_dma_din), .dma_ack(vdp_dma_ack),
		.dma_busy_out(dma_busy),
		.px(px), .py(py), .pixel_en(pixel_en),
		.color_ix(), .color(color),
		.hv_count(vdp_hv_count), .h40_out(h40),
		.dbg_reg0(), .dbg_addr(), .dbg_code(), .dbg_pending()
	);

	// --- the bus ---------------------------------------------------------------------------
	// Either the processor has it or the DMA does. The address is a word address
	// throughout, because everything on this bus is sixteen bits wide.
	wire [22:0] bus_a  = dma_busy ? vdp_dma_addr : cpu_addr[23:1];
	wire        bus_wr = !dma_busy && cpu_req && cpu_we && cpu_en;

	// --- the cartridge, through its cache -------------------------------------------------
	// The address is whatever the bus is showing, and it is stable for as long as
	// whoever is asking is held up -- which is what lets this be a plain "ask and
	// wait" rather than a queue.
	wire cart_region = (bus_a[22:21] == 2'b00);
	wire bus_read    = dma_busy ? vdp_dma_req : (cpu_req && !cpu_we);
	wire cart_want   = cart_region && bus_read;

	wire [15:0] cart_a_data;
	wire        cart_a_ack;
	reg  [15:0] cart_q;
	reg  [22:0] cart_q_addr;
	reg         cart_have;

	// Ready when nothing is wanted, or when what is held is the answer to what is
	// being asked. Comparing the address rather than trusting a flag is what
	// stops a stale answer from satisfying the next request.
	//
	// The comparison has to drive the REQUEST as well, not just the ready line.
	// It used to ask the cache for `cart_want && !cart_have`, which reads as "ask
	// unless we already have something" -- and something is not the same as the
	// right thing. Holding an answer for a different address then wedged the bus:
	// not ready, because the addresses differ; not asking, because cart_have was
	// set; and cart_have only cleared when nothing was wanted, which never came
	// round again because the requester was still waiting.
	//
	// It needs two requesters to happen, so a test cartridge that only ever reads
	// through the CPU will not find it. The 68000 reads an address, a DMA starts
	// and puts its own source on the bus, and the answer left over from the CPU
	// is for neither. Combat Cars hit it 255 words into a 68000-to-VRAM transfer
	// and stopped the whole machine -- the CPU frozen mid-instruction and the
	// renderer with it, because bus_a follows dma_busy.
	wire cart_hit = cart_have && (cart_q_addr == bus_a);
	assign cart_ready = !cart_want || cart_hit;

	// The address the cache is given has to stay still until it answers.
	//
	// cart_cache reads a_addr combinationally the whole way through a lookup --
	// idle, answer, miss, fill, look again -- and bus_a is not still: it follows
	// dma_busy, so it changes the moment a DMA starts or finishes. A transfer
	// beginning in the middle of a CPU fetch moves the address out from under
	// the lookup, and what comes back is a real word from the wrong place.
	//
	// Nothing stalls and nothing wedges. The data is simply wrong, so tiles land
	// in the wrong entries and the picture degrades as the game keeps writing --
	// which is a much worse failure than the deadlock this replaced, because it
	// looks like the VDP losing its mind rather than a read returning the wrong
	// bytes.
	reg  [22:0] cart_hold;
	reg         cart_busy;
	wire        cart_need  = cart_want && !cart_hit;
	wire        cart_start = cart_need && !cart_busy;
	wire [22:0] cart_addr  = cart_busy ? cart_hold : bus_a;

	always @(posedge clk) begin
		if (rst) cart_busy <= 1'b0;
		else if (cart_start) begin
			cart_hold <= bus_a;
			cart_busy <= 1'b1;
		end else if (cart_a_ack)
			cart_busy <= 1'b0;
	end

	always @(posedge clk) begin
		if (rst) cart_have <= 1'b0;
		else if (cart_a_ack) begin
			cart_q      <= cart_a_data;
			cart_q_addr <= cart_addr;     // what was asked, not what the bus shows now
			cart_have   <= 1'b1;
		end else if (!cart_want)
			cart_have <= 1'b0;
	end

	// The Z80's window is the second requester, and gets the same treatment.
	wire [15:0] cart_b_data_raw;
	wire        cart_b_ack;
	reg  [15:0] cart_b_q;
	reg  [22:0] cart_b_addr;
	reg         cart_b_have;

	wire [22:0] z_word = z_win_addr[23:1];
	// The Z80's window has the same shape and the same hole in it.
	wire cart_b_hit = cart_b_have && (cart_b_addr == z_word);
	assign cart_b_ready = !z_win_req || cart_b_hit;
	assign cart_b_data  = cart_b_q;

	always @(posedge clk) begin
		if (rst) cart_b_have <= 1'b0;
		else if (cart_b_ack) begin
			cart_b_q    <= cart_b_data_raw;
			cart_b_addr <= z_word;
			cart_b_have <= 1'b1;
		end else if (!z_win_req)
			cart_b_have <= 1'b0;
	end

	cart_cache cache (
		.clk(clk), .rst(rst),
		.a_addr(cart_addr), .a_req(cart_need || cart_busy),
		.a_data(cart_a_data), .a_ack(cart_a_ack),
		.b_addr(z_word), .b_req(z_win_req && !cart_b_hit),
		.b_data(cart_b_data_raw), .b_ack(cart_b_ack),
		.m_addr(mem_addr), .m_req(mem_req), .m_ready(mem_ready),
		.m_data(mem_data), .m_valid(mem_valid),
		.dbg_hits(), .dbg_misses(), .dbg_stall(), .dbg_prefetch()
	);

	// --- work RAM ---------------------------------------------------------------------------
	// 64 kB, and the byte strobes matter: a 68000 writing a byte must not take
	// the one next to it.
	reg [15:0] wram [0:32767];
	reg [15:0] wram_q;
	always @(posedge clk) begin
		if (bus_wr && sel_ram) begin
			if (cpu_ds[1]) wram[cpu_addr[15:1]][15:8] <= cpu_dout[15:8];
			if (cpu_ds[0]) wram[cpu_addr[15:1]][7:0]  <= cpu_dout[7:0];
		end
		wram_q <= wram[bus_a[14:0]];
	end

	// --- what a read comes back as -------------------------------------------------------------
	// The controller ports read as all ones, which is "nothing pressed" on a
	// machine whose buttons pull their lines down. An unmapped address reads the
	// same way rather than as an X, so that a game poking about during startup
	// gets an answer instead of poisoning everything downstream.
	wire [15:0] bus_q = cart_region               ? cart_q
	                  : (bus_a[22:15] == 8'hFF)   ? wram_q
	                                              : 16'hFFFF;

	always @(posedge clk) begin
		if (sel_vdp)          cpu_din <= vdp_hv ? vdp_hv_count : vdp_dout;
		// Bit 8 stays SET until the Z80 has actually stopped, which is what a
		// game spins on after asking for the bus.
		else if (hit_busreq)  cpu_din <= {7'd0, ~z80_busack, 8'd0};
		else if (hit_reset)   cpu_din <= 16'h0000;
		else if (hit_pad)     cpu_din <= {pad_q, pad_q};
		else if (sel_io)      cpu_din <= 16'hFFFF;
		// The Z80's bus is eight bits wide, so a word read of it sees the same
		// byte in both halves.
		else if (sel_z)       cpu_din <= {z_dout, z_dout};
		else                  cpu_din <= bus_q;
	end

	// --- answering a DMA -----------------------------------------------------------------------
	// The address is already on the bus, because bus_a follows the DMA the moment
	// it starts. All this does is wait one clock for the memory and say so.
	// Two sources, two latencies. The cartridge answers through a handshake
	// that holds its word until it is taken, so one clock of waiting is exact.
	// Work RAM answers through a registered read -- wram_q is wram[bus_a] as of
	// the PREVIOUS clock -- so taking it after one clock takes the word before
	// the one asked for. Every RAM-to-VRAM transfer then lands one word early:
	// a sprite table's Y becomes the next entry's size, its size the attribute,
	// and the engine goes looking for tiles that were never there. The car is
	// a sprite, and this is why there was no car.
	//
	// The cartridge path was checked word for word and was clean, which is
	// exactly why this one hid: the same test on the RAM path finds 3236 wrong
	// in 21888. So RAM waits a second clock for the register to catch up.
	reg [1:0] dma_phase;
	wire      dma_from_ram = (bus_a[22:15] == 8'hFF);
	always @(posedge clk) begin
		if (rst) begin
			dma_phase   <= 2'd0;
			vdp_dma_ack <= 1'b0;
		end else begin
			vdp_dma_ack <= 1'b0;
			case (dma_phase)
			2'd0: if (vdp_dma_req) dma_phase <= 2'd1;
			2'd1: if (dma_from_ram) dma_phase <= 2'd2;      // let wram_q catch up
			      else if (cart_ready) begin
					vdp_dma_din <= bus_q;
					vdp_dma_ack <= 1'b1;
					dma_phase   <= 2'd0;
				end
			2'd2: begin
					vdp_dma_din <= bus_q;
					vdp_dma_ack <= 1'b1;
					dma_phase   <= 2'd0;
				end
			default: dma_phase <= 2'd0;
			endcase
		end
	end

endmodule

`default_nettype wire
