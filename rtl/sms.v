//////////////////////////////////////////////////////////////////////////////////
// sms.v - a Sega Master System: Z80, VDP, work RAM and the cartridge mapper.
//
// The machine is simpler than the NES in every way except one. There is no
// picture-processor bus to share, no DMA, no cycle-counting to hit a raster
// line -- the video chip has a line interrupt for that. What it does have is a
// mapper in every cartridge rather than in a minority of them, because the Z80
// can only see 64 kB and Sega's ROMs went past that almost immediately.
//
// --- the memory map ------------------------------------------------------------
//
//   $0000-$03FF   cartridge, ALWAYS bank 0
//   $0400-$3FFF   cartridge, bank chosen by $FFFD
//   $4000-$7FFF   cartridge, bank chosen by $FFFE
//   $8000-$BFFF   cartridge, bank chosen by $FFFF
//   $C000-$DFFF   8 kB of work RAM
//   $E000-$FFFF   the same 8 kB again
//
// The first kilobyte is unpaged on purpose: the interrupt vectors and the reset
// entry live there, and a game that banked them out mid-interrupt would never
// come back. The mapper registers sit at the very top of the address space --
// inside the RAM mirror -- so a write there lands in BOTH the RAM and the
// mapper, which is why the bank registers can be read back as ordinary memory.
//
// --- the ports ------------------------------------------------------------------
//
//   $7E/$7F   V and H counters to read, the sound chip to write
//   $BE       VDP data
//   $BF       VDP control, and the status flags when read
//   $DC/$DD   the control pads, active LOW
//
// Only address bits 7..6 and 0 really matter to the decode, which is why the
// pads answer at $C0/$C1 as well as $DC/$DD.
//
// --- clocks -----------------------------------------------------------------------
//
// The real machine runs its Z80 at 3.58 MHz and its VDP at 5.37 MHz, both
// divided from one 10.7 MHz crystal: the CPU gets one tick in three, the video
// chip one in two. So the CPU runs at two thirds of the pixel rate, and that
// ratio is what makes a game's timing come out right.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module sms #(
	parameter ROM_AW = 18                 // 256 kB of cartridge
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,                // one VDP pixel

	// cartridge, in the shared memory
	output wire [ROM_AW-1:0] rom_addr,
	input  wire [7:0]        rom_data,

	// pads: bit 0 up, 1 down, 2 left, 3 right, 4 button 1, 5 button 2
	input  wire [7:0]  joy1,
	input  wire [7:0]  joy2,

	// video
	output wire [8:0]  px,
	output wire [8:0]  py,
	output wire        pixel_en,
	output wire [5:0]  color,
	output wire        frame_start,

	output wire [15:0] audio,

	output wire [15:0] dbg_pc
);

	// --- the CPU's clock ----------------------------------------------------------
	// Two ticks in every three pixels.
	reg [1:0] phase;
	wire cpu_ce = ce && (phase != 2'd2);
	always @(posedge clk) begin
		if (rst) phase <= 2'd0;
		else if (ce) phase <= (phase == 2'd2) ? 2'd0 : phase + 2'd1;
	end

	// --- the Z80 -------------------------------------------------------------------
	wire [15:0] cpu_addr;
	wire [7:0]  cpu_dout;
	reg  [7:0]  cpu_din;
	wire        cpu_we, cpu_io;
	wire        vdp_irq_n;

	z80 u_cpu (
		.clk(clk), .rst(rst), .ce(cpu_ce),
		.addr(cpu_addr), .din(cpu_din), .dout(cpu_dout),
		.we(cpu_we), .io(cpu_io), .m1(),
		.int_n(vdp_irq_n), .nmi_n(1'b1),
		.dbg_pc(dbg_pc), .dbg_sp(), .dbg_af(), .dbg_bc(), .dbg_de(),
		.dbg_hl(), .dbg_m1()
	);

	// --- work RAM -------------------------------------------------------------------
	reg [7:0] wram [0:8191];
	integer wi;
	initial for (wi = 0; wi < 8192; wi = wi + 1) wram[wi] = 8'd0;

	wire sel_ram = cpu_addr[15] && cpu_addr[14];      // $C000 and up
	wire ram_we  = cpu_ce && cpu_we && !cpu_io && sel_ram;

	reg [7:0] ram_q;
	always @(posedge clk) begin
		if (ram_we) wram[cpu_addr[12:0]] <= cpu_dout;
		ram_q <= wram[cpu_addr[12:0]];
	end

	// --- the cartridge mapper ---------------------------------------------------------
	reg [5:0] bank0, bank1, bank2;

	always @(posedge clk) begin
		if (rst) begin
			// What the machine comes up with, and what a game expects before it
			// has written anything: the first three banks in order.
			bank0 <= 6'd0; bank1 <= 6'd1; bank2 <= 6'd2;
		end else if (cpu_ce && cpu_we && !cpu_io) begin
			case (cpu_addr)
			16'hFFFD: bank0 <= cpu_dout[5:0];
			16'hFFFE: bank1 <= cpu_dout[5:0];
			16'hFFFF: bank2 <= cpu_dout[5:0];
			default: ;
			endcase
		end
	end

	// The first kilobyte never moves, whatever $FFFD says.
	reg [5:0] bank_sel;
	always @* begin
		if (cpu_addr[15:14] == 2'b00)      bank_sel = (cpu_addr < 16'h0400) ? 6'd0 : bank0;
		else if (cpu_addr[15:14] == 2'b01) bank_sel = bank1;
		else                               bank_sel = bank2;
	end

	wire [19:0] rom_full = {bank_sel, cpu_addr[13:0]};
	assign rom_addr = rom_full[ROM_AW-1:0];

	// --- the VDP ----------------------------------------------------------------------
	wire vdp_sel = cpu_ce && cpu_io && (cpu_addr[7:6] == 2'b10);
	wire [7:0] vdp_dout;

	vdp u_vdp (
		.clk(clk), .rst(rst), .ce(ce),
		.cpu_sel(vdp_sel), .cpu_ctrl(cpu_addr[0]), .cpu_wr(cpu_we),
		.cpu_din(cpu_dout), .cpu_dout(vdp_dout),
		.irq_n(vdp_irq_n),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.frame_start(frame_start)
	);

	// --- the sound chip ---------------------------------------------------------
	// It answers at $7E and $7F, the same pair of addresses whose READS are the
	// video chip's line and pixel counters. Direction is part of the decode.
	wire psg_we = cpu_ce && cpu_io && cpu_we && (cpu_addr[7:6] == 2'b01);

	psg u_psg (
		.clk(clk), .rst(rst), .ce(cpu_ce),
		.din(cpu_dout), .we(psg_we),
		.sample(audio)
	);

	// --- reading -----------------------------------------------------------------------
	// The CPU asks and answers on different cycles. `io` is a STROBE: it is high
	// for the one enable cycle in which the access happens, because that is what
	// makes the VDP advance its address exactly once per port write. But the Z80
	// reads I/O the same way it reads memory -- present, wait, sample -- so it
	// takes the byte on the FOLLOWING enable cycle, by which time the strobe is
	// gone even though the address is still there.
	//
	// So the mux below needs the direction held one cycle longer than the strobe
	// that caused the side effect. Without this every IN on the machine returns
	// whatever lives in memory at {A, port}, which is why the one thing every
	// game does -- read the VDP status in its interrupt handler to ask "was that
	// VBlank?" -- always answered no.
	//
	// Reads only: holding it across a write would point the mux at a port during
	// the cycle after an OUT, and OTIR reads memory very soon after one.
	reg io_rd_hold;
	always @(posedge clk) begin
		if (rst)          io_rd_hold <= 1'b0;
		else if (cpu_ce)  io_rd_hold <= cpu_io && !cpu_we;
	end
	wire io_rd = cpu_io || io_rd_hold;

	// The pads are active low, and the unused bits read high, so an unconnected
	// port looks like nothing pressed rather than everything pressed.
	wire [7:0] port_dc = ~{joy2[1:0], joy1[5:0]};
	wire [7:0] port_dd = {2'b11, 1'b1, 1'b1, ~joy2[5:2], 2'b00} | 8'hF0;

	// The V counter reports the SCANLINE, and it is eight bits for 262 lines, so
	// it repeats a stretch rather than wrapping: 0..$DA counts up with the line,
	// then it jumps back to $D5 and counts to $FF. Games use it to find their
	// place in the frame, so the shape of the jump matters, not just the range.
	wire [7:0] vcounter = (py <= 9'd218) ? py[7:0] : (py[7:0] - 8'd6);

	always @* begin
		if (io_rd) begin
			casez (cpu_addr[7:0])
			8'b01??_???0: cpu_din = vcounter;          // $7E, the V counter
			8'b01??_???1: cpu_din = px[8:1];           // $7F, the H counter
			8'b10??_????: cpu_din = vdp_dout;          // $BE and $BF
			8'b11??_???0: cpu_din = port_dc;
			8'b11??_???1: cpu_din = port_dd;
			default:      cpu_din = 8'hFF;
			endcase
		end else begin
			cpu_din = sel_ram ? ram_q : rom_data;
		end
	end

endmodule

`default_nettype wire
