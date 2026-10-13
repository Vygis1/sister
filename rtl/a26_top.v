//////////////////////////////////////////////////////////////////////////////////
// a26_top.v - the Atari 2600 (VCS): a 6507, a TIA, a 6532 and a cartridge.
//
// One clock domain. The colour clock (3.579545 MHz) is a clock enable made by a
// phase accumulator from CLK_HZ, and the processor runs one cycle every third
// colour clock -- 1.19 MHz, as the console divides it. The processor's bus cycle
// therefore spans three colour clocks and its accesses land on the third, which
// is the timing every TIA trick in every kernel was written against.
//
// Address decode is the console's (the 6507 has 13 address lines):
//
//   A12=0 A7=0        TIA            $0000-$007F and mirrors
//   A12=0 A7=1 A9=0   RIOT RAM       $0080-$00FF and mirrors
//   A12=0 A7=1 A9=1   RIOT I/O       $0280-$029F and mirrors
//   A12=1             cartridge      $1000-$1FFF
//
// The cartridge is a 32 KB block RAM the caller fills through rom_wr_*, plus the
// bank-switching the common boards had. `scheme` picks it; 0 lets the size decide:
//
//   0  auto: 2K/4K plain, 8K F8, 12K FA, 16K F6, 32K F4
//   1  none  2K (mirrored) or 4K
//   2  F8    8K, two 4K banks, hotspots $1FF8/$1FF9
//   3  F6    16K, four banks, $1FF6-$1FF9
//   4  F4    32K, eight banks, $1FF4-$1FFB
//   5  FE    8K (Activision): the bank follows bit 5 of the byte on the bus in the
//            cycle after an access to $01FE -- with the stack pointer at $FF, as
//            these games keep it, that is the new high byte of a JSR or RTS, so
//            $Dxxx code runs from the image's first 4K and $Fxxx from its second
//   6  E0    8K (Parker Brothers): three 1K slices from eight, $1FE0-$1FF7; the
//            top slice fixed to the last bank
//   7  3F    (Tigervision) a write anywhere in $00-$3F picks the 2K bank at $1000
//            (games write $3F, which the TIA does not implement, and reach the TIA
//            through its $40-$7F mirrors); $1800 is fixed to the last 2K
//   8  FA    12K + 256 B RAM (CBS RAM Plus): $1FF8-$1FFA; RAM write $1000, read $1100
//   9  F8SC  F8 with the 128 B "Super Chip" RAM: write $1000-$107F, read $1080-$10FF
//  10  F6SC  F6 with the Super Chip
//  11  F4SC  F4 with the Super Chip
//
// Pads (active high = pressed): bit 0 up, 1 down, 2 left, 3 right, 4 fire. The
// console switches are separate inputs. Video comes out as the TIA's 7-bit colour
// per visible pixel; audio as signed 16-bit, both channels on both sides.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module a26_top #(
	parameter CLK_HZ = 50_000_000,
	parameter PIX_HZ = 3_579_545
)(
	input  wire        clk,
	input  wire        rst,
	// the menu's pause (console_top's cpu_halt): no colour clocks, so the processor, the TIA
	// and the RIOT all stop together and pick up where they were
	input  wire        pause,

	// cartridge load port and description
	input  wire        rom_wr,
	input  wire [14:0] rom_wr_addr,
	input  wire [7:0]  rom_wr_data,
	input  wire [15:0] rom_len,      // bytes, 2048..32768
	input  wire [3:0]  scheme,

	// controls
	input  wire [7:0]  joy0,
	input  wire [7:0]  joy1,
	input  wire        sw_reset,     // 1 = pressed
	input  wire        sw_select,    // 1 = pressed
	input  wire        sw_color,     // 1 = colour, 0 = black and white
	input  wire        sw_diff0,     // 1 = A (expert)
	input  wire        sw_diff1,
	input  wire [3:0]  paddle,       // INPT0-3 pin levels; 0 with nothing plugged in

	// video
	output wire        pix_ce,       // the colour clock enable
	output wire [7:0]  px_x,
	output wire [8:0]  line,
	output wire [6:0]  color,
	output wire        pixel_en,
	output wire        frame_start,
	output wire        line_end,
	output wire        vblank,
	output wire        vsync,

	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	output wire [15:0] dbg_pc,
	output wire        dbg_sync,
	output wire        dbg_rdy
);

	// --- the colour clock ------------------------------------------------------------
	// Phase accumulator: PIX_HZ out of every CLK_HZ clocks carry a colour clock,
	// spread as evenly as integers allow. With CLK_HZ == PIX_HZ every clock does,
	// which is how the benches run.
	reg [31:0] acc;
	reg        ce;
	always @(posedge clk) begin
		if (rst) begin acc <= 32'd0; ce <= 1'b0; end
		else if (acc + PIX_HZ >= CLK_HZ) begin acc <= acc + PIX_HZ - CLK_HZ; ce <= !pause; end
		else begin acc <= acc + PIX_HZ; ce <= 1'b0; end
	end
	assign pix_ce = ce;

	// the processor's cycle: the third colour clock of every three
	reg [1:0] phase;
	always @(posedge clk) begin
		if (rst) phase <= 2'd0;
		else if (ce) phase <= (phase == 2'd2) ? 2'd0 : phase + 2'd1;
	end
	wire cpu_ce = ce && (phase == 2'd2);

	// --- the 6507 ----------------------------------------------------------------------
	wire [15:0] cpu_addr16;
	wire [12:0] cpu_addr = cpu_addr16[12:0];   // the 6507's 13 address pins
	wire [7:0]  cpu_dout;
	reg  [7:0]  cpu_din;
	wire        cpu_we;
	wire        rdy;

	cpu6502 #(.DECIMAL(1), .HAS_RDY(1), .UNDOC_IMM(1)) u_cpu (
		.clk(clk), .rst(rst), .ce(cpu_ce), .rdy(rdy),
		.addr(cpu_addr16), .din(cpu_din), .dout(cpu_dout), .we(cpu_we),
		.irq(1'b0), .nmi(1'b0),
		.sync(dbg_sync),
		.dbg_a(), .dbg_x(), .dbg_y(), .dbg_s(), .dbg_p(), .dbg_pc(dbg_pc)
	);
	assign dbg_rdy = rdy;

	wire sel_tia  = !cpu_addr[12] && !cpu_addr[7];
	wire sel_ram  = !cpu_addr[12] &&  cpu_addr[7] && !cpu_addr[9];
	wire sel_io   = !cpu_addr[12] &&  cpu_addr[7] &&  cpu_addr[9];
	wire sel_cart =  cpu_addr[12];

	// --- the TIA ---------------------------------------------------------------------------
	wire [7:0] tia_dout;
	a26_tia u_tia (
		.clk(clk), .rst(rst), .ce(ce), .cpu_ce(cpu_ce),
		.cs(sel_tia), .addr(cpu_addr[5:0]), .we(cpu_we), .din(cpu_dout), .dout(tia_dout),
		.rdy(rdy),
		.inpt({~joy1[4], ~joy0[4], paddle}),
		.px_x(px_x), .line(line), .color(color), .pixel_en(pixel_en),
		.frame_start(frame_start), .line_end(line_end), .vsync_o(vsync), .vblank_o(vblank),
		.audio_l(audio_l), .audio_r(audio_r)
	);

	// --- the RIOT ----------------------------------------------------------------------------
	// SWCHA: bits 7:4 are player 0's right, left, down, up; 3:0 player 1's. A
	// closed switch reads 0. SWCHB: bit 0 reset, 1 select, 3 colour (1 = colour),
	// 6 and 7 the difficulty switches (1 = A); the unused pins read 0.
	wire [7:0] pa_in = {~joy0[3], ~joy0[2], ~joy0[1], ~joy0[0], ~joy1[3], ~joy1[2], ~joy1[1], ~joy1[0]};
	wire [7:0] pb_in = {sw_diff1, sw_diff0, 2'b00, sw_color, 1'b0, ~sw_select, ~sw_reset};
	wire [7:0] riot_dout;
	a26_riot u_riot (
		.clk(clk), .rst(rst), .cpu_ce(cpu_ce),
		.ram_sel(sel_ram), .io_sel(sel_io), .addr(cpu_addr[6:0]),
		.we(cpu_we), .din(cpu_dout), .dout(riot_dout),
		.pa_in(pa_in), .pb_in(pb_in)
	);

	// --- the cartridge -------------------------------------------------------------------------
	reg [7:0] rom [0:32767];
	integer i;
	initial for (i = 0; i < 32768; i = i + 1) rom[i] = 8'd0;

	// which scheme is in force
	reg [3:0] sch;
	always @* begin
		if (scheme != 4'd0) sch = scheme;
		else if (rom_len <= 16'd4096)  sch = 4'd1;
		else if (rom_len <= 16'd8192)  sch = 4'd2;
		else if (rom_len <= 16'd12288) sch = 4'd8;
		else if (rom_len <= 16'd16384) sch = 4'd3;
		else                           sch = 4'd4;
	end

	// 2K banks in the image, minus one: 3F's mask and its fixed upper bank
	wire [4:0] n_2k    = rom_len[15:11];
	wire [3:0] last_2k = n_2k[3:0] - 4'd1;

	reg [3:0] bank;               // F8/F6/F4/FE/FA/3F
	reg [2:0] slice0, slice1, slice2;   // E0
	reg       fe_arm;             // FE: the $01FE access was this cycle
	wire      superchip = (sch == 4'd9) || (sch == 4'd10) || (sch == 4'd11);
	wire      fa_ram    = (sch == 4'd8);

	wire [11:0] ca = cpu_addr[11:0];
	wire        cart_cyc = cpu_ce && sel_cart;

	// the byte on the bus this cycle, which FE watches
	wire [7:0] bus_byte = cpu_we ? cpu_dout : cpu_din;

	always @(posedge clk) begin
		if (rst) begin
			// Every scheme starts in the bank that holds the reset vector: the last
			// one, except FE where the vector lives in the second ($F000) image.
			bank <= 4'd15; slice0 <= 3'd0; slice1 <= 3'd0; slice2 <= 3'd0; fe_arm <= 1'b0;
		end else if (cpu_ce) begin
			fe_arm <= 1'b0;
			case (sch)
			4'd2, 4'd9:  if (cart_cyc && ca[11:1] == 11'h7FC) bank <= {3'd0, ca[0]};      // $FF8/$FF9
			4'd3, 4'd10: if (cart_cyc && ca >= 12'hFF6 && ca <= 12'hFF9) bank <= {2'd0, ca[1:0] + 2'd2};
			4'd4, 4'd11: if (cart_cyc && ca >= 12'hFF4 && ca <= 12'hFFB) bank <= {1'b0, ca[2:0] - 3'd4};
			4'd8:        if (cart_cyc && ca >= 12'hFF8 && ca <= 12'hFFA) bank <= {2'd0, ca[1:0]};
			4'd5: begin
				if (fe_arm) bank <= bus_byte[5] ? 4'd1 : 4'd0;
				if (cpu_addr == 13'h01FE) fe_arm <= 1'b1;
			end
			4'd6: if (cart_cyc && ca >= 12'hFE0 && ca <= 12'hFF7) begin
				case (ca[4:3])
				2'd0: slice0 <= ca[2:0];
				2'd1: slice1 <= ca[2:0];
				default: slice2 <= ca[2:0];
				endcase
			end
			4'd7: if (cpu_we && sel_tia && !cpu_addr[6]) bank <= cpu_dout[3:0];
			default: ;
			endcase
		end
	end

	// the physical ROM address
	reg  [14:0] phys;
	always @* begin
		case (sch)
		4'd1:    phys = (rom_len <= 16'd2048) ? {4'd0, ca[10:0]} : {3'd0, ca};
		4'd2, 4'd9:  phys = {2'd0, bank[0], ca};
		4'd3, 4'd10: phys = {1'b0, bank[1:0], ca};
		4'd4, 4'd11: phys = {bank[2:0], ca};
		4'd5:    phys = {2'd0, bank[0], ca};
		4'd8:    phys = {1'b0, (bank > 4'd2) ? 2'd2 : bank[1:0], ca};
		4'd6: begin
			case (ca[11:10])
			2'd0: phys = {2'd0, slice0, ca[9:0]};
			2'd1: phys = {2'd0, slice1, ca[9:0]};
			2'd2: phys = {2'd0, slice2, ca[9:0]};
			default: phys = {2'd0, 3'd7, ca[9:0]};
			endcase
		end
		4'd7:    phys = ca[11] ? {last_2k, ca[10:0]} : {bank & last_2k, ca[10:0]};
		default: phys = {3'd0, ca};
		endcase
	end

	// Both the bank register (reset to 15) and the image size clamp the bank to
	// what is there, so a fresh console starts in the last bank of any image.
	wire [14:0] phys_c = (sch == 4'd2 || sch == 4'd9 || sch == 4'd5) ? {2'd0, phys[12:0]} :
	                     (sch == 4'd3 || sch == 4'd10) ? {1'b0, phys[13:0]} : phys;

	reg [7:0] rom_q;
	always @(posedge clk) begin
		if (rom_wr) rom[rom_wr_addr] <= rom_wr_data;
		rom_q <= rom[phys_c];
	end

	// cartridge RAM: 256 bytes serves both the Super Chip (128) and CBS (256)
	reg [7:0] cram [0:255];
	initial for (i = 0; i < 256; i = i + 1) cram[i] = 8'd0;
	wire sc_wr = superchip && ca[11:7] == 5'd0;        // $1000-$107F
	wire sc_rd = superchip && ca[11:7] == 5'd1;        // $1080-$10FF
	wire fa_wr = fa_ram && ca[11:8] == 4'd0;           // $1000-$10FF
	wire fa_rd = fa_ram && ca[11:8] == 4'd1;           // $1100-$11FF
	wire [7:0] cram_a = superchip ? {1'b0, ca[6:0]} : ca[7:0];
	reg [7:0] cram_q;
	always @(posedge clk) begin
		// A write-port access is a write whatever the processor thinks it is doing:
		// reading $1000-$107F on a Super Chip board stores the bus byte there.
		if (cart_cyc && (sc_wr || fa_wr)) cram[cram_a] <= bus_byte;
		cram_q <= cram[cram_a];
	end

	// --- the processor's data in -------------------------------------------------------------------
	always @* begin
		if (sel_tia)              cpu_din = tia_dout;
		else if (sel_ram || sel_io) cpu_din = riot_dout;
		else if (sc_rd || fa_rd)  cpu_din = cram_q;
		else                      cpu_din = rom_q;
	end

endmodule
