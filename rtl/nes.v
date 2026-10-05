//////////////////////////////////////////////////////////////////////////////////
// nes.v - the console: CPU, PPU, RAM, cartridge, DMA and controllers.
//
// Clocking is the first thing that has to be right. One CPU cycle per three PPU
// dots is not an approximation -- it is the ratio games assume when they count
// cycles to hit a scanline, so `ce` here is the PPU dot rate and the CPU gets
// every third one.
//
// CPU memory map:
//   $0000-$1FFF  2 KB RAM, mirrored four times
//   $2000-$3FFF  PPU registers, eight bytes mirrored across the whole range
//   $4014        OAM DMA
//   $4016/$4017  controllers
//   $6000-$7FFF  cartridge RAM -- blargg's test ROMs report their results here
//   $8000-$FFFF  cartridge PRG ROM
//
// PPU memory map:
//   $0000-$1FFF  pattern tables, from the cartridge
//   $2000-$2FFF  nametables: 2 KB of internal RAM, arranged by the cartridge's
//                mirroring. Horizontal and vertical differ only in which
//                address bit selects the half, and getting it backwards makes
//                scrolling wrap the wrong way.
//   $3F00-$3F1F  palette, internal to the PPU
//
// OAM DMA halts the CPU for 513 cycles while 256 bytes are copied a byte at a
// time. Games depend on that stall: it is how they budget VBlank.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module nes #(
	parameter PRG_AW = 18,
	parameter CHR_AW = 17
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        ce,             // one PPU dot

	// --- cartridge ----------------------------------------------------------
	// The addresses are ROM-wide, not window-wide: the mapper has already turned
	// the CPU's $8000-$FFFF and the PPU's $0000-$1FFF into an offset into the
	// whole cartridge.
	output wire [PRG_AW-1:0] prg_addr,
	input  wire [7:0]        prg_din,
	output wire [CHR_AW-1:0] chr_addr,
	input  wire [7:0]        chr_din,
	output wire [7:0]        chr_dout,
	output wire              chr_we,
	input  wire              chr_is_ram,
	input  wire [3:0]  mapper_id,      // iNES mapper number: 0 NROM, 4 MMC3
	input  wire        hdr_mirror_v,   // header mirroring; the mapper may override
	input  wire [5:0]  prg_last,       // (PRG size / 8 KB) - 1

	// --- controllers --------------------------------------------------------
	// bit 0 A, 1 B, 2 Select, 3 Start, 4 Up, 5 Down, 6 Left, 7 Right
	input  wire [7:0]  joy1,
	input  wire [7:0]  joy2,

	// --- audio --------------------------------------------------------------
	output wire [15:0] audio,          // signed 16-bit, at whatever rate ce runs

	// --- video --------------------------------------------------------------
	output wire [8:0]  px,
	output wire [8:0]  py,
	output wire        pixel_en,
	output wire [5:0]  color,
	output wire        frame_start,

	// --- debug --------------------------------------------------------------
	output wire [15:0] dbg_pc,
	output wire        dbg_sync,
	output wire        dbg_nmi
);

	// --- clocks --------------------------------------------------------------
	reg [1:0] dot;
	wire cpu_tick = ce && (dot == 2'd2);
	always @(posedge clk) begin
		if (rst) dot <= 2'd0;
		else if (ce) dot <= (dot == 2'd2) ? 2'd0 : dot + 2'd1;
	end

	reg        dma_active;
	reg [7:0]  dma_page;
	reg [8:0]  dma_count;
	reg        dma_phase;              // 0 = read from CPU space, 1 = write to OAM
	reg [7:0]  dma_data;
	reg        dma_write;

	// The CPU is stalled outright during DMA rather than being told to wait.
	// The delta player takes one cycle off the CPU when it needs a sample byte.
	// Real hardware takes up to four; one is enough to stop the cartridge bus
	// being driven by two things at once, which is the part that matters.
	//
	// The acknowledge has to be ONE CLOCK, not the whole cycle. `dmc_fetch`
	// stays up for a full CPU period -- twenty-seven clocks here -- and the APU
	// advances its sample pointer on every clock the acknowledge is high. Wired
	// straight through, the player tore through its sample twenty-seven times
	// too fast and read mostly the wrong bytes, which is audible as a buzz
	// under the music rather than as silence.
	reg  dmc_fetch, dmc_ack;
	wire apu_dmc_req;
	wire [15:0] apu_dmc_addr;
	always @(posedge clk) begin
		if (rst) begin
			dmc_fetch <= 1'b0;
			dmc_ack   <= 1'b0;
		end else begin
			dmc_ack <= 1'b0;
			if (cpu_tick) begin
				if (dmc_fetch) begin
					// The byte has had a whole CPU cycle to arrive, and the
					// address is still on the bus this clock.
					dmc_fetch <= 1'b0;
					dmc_ack   <= 1'b1;
				end else if (apu_dmc_req && !dma_active) begin
					dmc_fetch <= 1'b1;
				end
			end
		end
	end

	wire cpu_ce = cpu_tick && !dma_active && !dmc_fetch;

	// --- CPU -----------------------------------------------------------------
	wire [15:0] cpu_addr;
	wire [7:0]  cpu_dout;
	wire        cpu_we;
	reg  [7:0]  cpu_din;
	wire        ppu_nmi;
	assign dbg_nmi = ppu_nmi;

	cpu6502 #(.DECIMAL(0)) u_cpu (
		.clk(clk), .rst(rst), .ce(cpu_ce),
		.addr(cpu_addr), .din(cpu_din), .dout(cpu_dout), .we(cpu_we),
		.irq(cart_irq || apu_irq), .nmi(ppu_nmi),
		.sync(dbg_sync),
		.dbg_a(), .dbg_x(), .dbg_y(), .dbg_s(), .dbg_p(), .dbg_pc(dbg_pc)
	);

	// --- RAM ------------------------------------------------------------------
	reg [7:0] ram [0:2047];
	integer ri;
	// Block RAM on this part powers up zeroed, and an `initial` block is how that
	// is spelled for both Vivado and the simulator. Without it simulation starts
	// from X where hardware starts from 0, and X propagating out of unwritten
	// memory hides real bugs behind fake ones.
	initial for (ri = 0; ri < 2048; ri = ri + 1) ram[ri] = 8'd0;
	reg [7:0] ram_q;
	always @(posedge clk) begin
		if (cpu_ce && cpu_we && cpu_addr < 16'h2000) ram[cpu_addr[10:0]] <= cpu_dout;
		ram_q <= ram[cpu_addr[10:0]];
	end

	// Cartridge RAM at $6000: blargg's ROMs write their status byte here.
	reg [7:0] prg_ram [0:8191];
	integer pri;
	initial for (pri = 0; pri < 8192; pri = pri + 1) prg_ram[pri] = 8'd0;
	reg [7:0] prg_ram_q;
	always @(posedge clk) begin
		if (cpu_ce && cpu_we && cpu_addr[15:13] == 3'b011) prg_ram[cpu_addr[12:0]] <= cpu_dout;
		prg_ram_q <= prg_ram[cpu_addr[12:0]];
	end

	// --- decode ---------------------------------------------------------------
	wire sel_ram  = (cpu_addr < 16'h2000);
	wire sel_ppu  = (cpu_addr >= 16'h2000) && (cpu_addr < 16'h4000);
	wire sel_dma  = (cpu_addr == 16'h4014);
	wire sel_joy1 = (cpu_addr == 16'h4016);
	wire sel_joy2 = (cpu_addr == 16'h4017);
	wire sel_pram = (cpu_addr[15:13] == 3'b011);
	wire sel_prg  = (cpu_addr >= 16'h8000);
	// $4000-$4017 is the APU, minus the two holes the DMA and the pads sit in.
	// $4017 is both the frame-counter WRITE and the pad-2 READ, which is why
	// the direction is part of the decode rather than the address alone.
	wire sel_apu  = (cpu_addr >= 16'h4000) && (cpu_addr <= 16'h4017)
	                && !sel_dma && !sel_joy1;
	wire sel_stat = (cpu_addr == 16'h4015);

	// --- PPU ------------------------------------------------------------------
	wire [7:0]  ppu_dout;
	wire [13:0] vram_addr;
	wire [7:0]  vram_dout;
	wire        vram_rd, vram_wr;
	reg  [7:0]  vram_din;

	// Register strobes last exactly one clock, because the PPU samples them
	// every clock rather than on its own dot enable.
	wire ppu_rd = cpu_ce && sel_ppu && !cpu_we;
	wire ppu_wr = cpu_ce && sel_ppu &&  cpu_we;

	// OAM DMA writes go to $2004 as if the CPU had written them.
	wire ppu_wr_eff   = ppu_wr || dma_write;
	wire [2:0] ppu_a  = dma_write ? 3'd4 : cpu_addr[2:0];
	wire [7:0] ppu_d  = dma_write ? dma_data : cpu_dout;

	ppu u_ppu (
		.clk(clk), .rst(rst), .ce(ce),
		.cpu_addr(ppu_a), .cpu_din(ppu_d), .cpu_dout(ppu_dout),
		.cpu_rd(ppu_rd), .cpu_wr(ppu_wr_eff), .nmi(ppu_nmi),
		.vram_addr(vram_addr), .vram_din(vram_din), .vram_dout(vram_dout),
		.vram_rd(vram_rd), .vram_wr(vram_wr),
		.cycle(px), .scanline(py), .pixel_en(pixel_en), .pixel(color),
		.frame_start(frame_start), .vblank_start()
	);

	// --- the cartridge's mapper ------------------------------------------------
	// The delta player reads sample bytes out of the cartridge, so the address
	// the mapper translates is not always the CPU's. On real hardware this
	// costs the CPU a cycle, which is modelled by stalling it below.
	wire [15:0] bus_addr = dmc_fetch ? apu_dmc_addr : cpu_addr;
	wire cart_irq;
	wire [1:0] mirror;

	mapper #(.PRG_AW(PRG_AW), .CHR_AW(CHR_AW)) u_mapper (
		.clk(clk), .rst(rst), .ce(ce), .cpu_ce(cpu_ce),
		.mapper_id(mapper_id), .hdr_mirror_v(hdr_mirror_v), .prg_last(prg_last),
		.cpu_addr(bus_addr), .cpu_dout(cpu_dout), .cpu_we(cpu_we),
		.ppu_addr(vram_addr), .ppu_rd(vram_rd),
		.prg_addr(prg_addr), .chr_addr(chr_addr),
		.mirror(mirror), .irq(cart_irq)
	);

	// --- PPU memory -----------------------------------------------------------
	// Four arrangements, not two. Horizontal mirroring stacks the two name
	// tables vertically and vertical places them side by side -- one address
	// bit chooses, and which bit is the whole difference. The one-screen modes
	// point both at the same kilobyte, which MMC1 cartridges use to get a
	// scrolling status bar without a second table.
	reg nt_hi;
	always @* begin
		case (mirror)
		2'd0:    nt_hi = 1'b0;             // one screen, lower
		2'd1:    nt_hi = 1'b1;             // one screen, upper
		2'd2:    nt_hi = vram_addr[10];    // vertical
		default: nt_hi = vram_addr[11];    // horizontal
		endcase
	end
	wire [10:0] nt_index = {nt_hi, vram_addr[9:0]};

	reg [7:0] vram_nt [0:2047];
	integer vi;
	initial for (vi = 0; vi < 2048; vi = vi + 1) vram_nt[vi] = 8'd0;
	reg [7:0] nt_q;
	always @(posedge clk) begin
		if (vram_wr && vram_addr >= 14'h2000) vram_nt[nt_index] <= vram_dout;
		nt_q <= vram_nt[nt_index];
	end

	// Both memories answer a clock after they are addressed, so which one answered is
	// the last clock's address too. A $2007 read drives the bus for one clock only:
	// choosing on the current address picked whatever the rendering fetch was
	// pointing at by then -- a name-table byte for half the reads of tile ROM, and
	// Super Mario Bros., which copies its title screen out of tile ROM through
	// $2007, drew it as garbage and left the garbage in its status bar.
	reg vram_chr_q;
	always @(posedge clk) vram_chr_q <= (vram_addr < 14'h2000);
	always @* vram_din = vram_chr_q ? chr_din : nt_q;

	// A cartridge with no tile ROM has RAM there instead, and the PPU writes it
	// through the same $2007 port it uses for name tables.
	assign chr_dout = vram_dout;
	assign chr_we   = chr_is_ram && vram_wr && (vram_addr < 14'h2000);

	// --- the sound half ---------------------------------------------------------
	wire [7:0]  apu_status;
	wire        apu_irq;
	wire [15:0] apu_sample;

	apu u_apu (
		// (every CPU cycle, the ones the CPU spends halted for DMA too: the sound chip does
		// not stop for them -- stopping it each frame wobbled every note at 60 Hz)
		.clk(clk), .rst(rst), .cpu_ce(cpu_tick),
		.addr(cpu_addr[4:0]), .din(cpu_dout),
		.we(cpu_ce && cpu_we && sel_apu),
		.rd_status(cpu_ce && !cpu_we && sel_stat),
		.status(apu_status), .irq(apu_irq),
		.dmc_addr(apu_dmc_addr), .dmc_data(prg_din),
		.dmc_req(apu_dmc_req), .dmc_ack(dmc_ack),
		.sample(apu_sample)
	);

	assign audio = apu_sample;

	// --- OAM DMA ---------------------------------------------------------------
	wire [15:0] dma_addr = {dma_page, dma_count[7:0]};

	// DMA reads come from the same places the CPU would read.
	reg [7:0] dma_src_q;
	always @(posedge clk) dma_src_q <= ram[dma_addr[10:0]];
	wire [7:0] dma_src = (dma_addr < 16'h2000) ? dma_src_q : prg_din;


	always @(posedge clk) begin
		if (rst) begin
			dma_active <= 1'b0; dma_count <= 9'd0; dma_phase <= 1'b0;
			dma_write  <= 1'b0;
		end else begin
			dma_write <= 1'b0;
			if (cpu_ce && cpu_we && sel_dma) begin
				dma_active <= 1'b1;
				dma_page   <= cpu_dout;
				dma_count  <= 9'd0;
				dma_phase  <= 1'b0;
			end else if (dma_active && cpu_tick) begin
				if (!dma_phase) begin
					dma_data  <= dma_src;
					dma_phase <= 1'b1;
				end else begin
					dma_write <= 1'b1;
					dma_phase <= 1'b0;
					if (dma_count == 9'd255) dma_active <= 1'b0;
					else                     dma_count  <= dma_count + 9'd1;
				end
			end
		end
	end

	// --- controllers ------------------------------------------------------------
	reg [7:0] joy1_sr, joy2_sr;
	reg       joy_strobe;

	always @(posedge clk) begin
		if (rst) begin
			joy_strobe <= 1'b0; joy1_sr <= 8'd0; joy2_sr <= 8'd0;
		end else begin
			// While strobe is high the shift registers track the buttons; the
			// latch happens when it falls.
			if (joy_strobe) begin
				joy1_sr <= joy1;
				joy2_sr <= joy2;
			end
			if (cpu_ce && cpu_we && sel_joy1) joy_strobe <= cpu_dout[0];
			if (cpu_ce && !cpu_we && !joy_strobe) begin
				if (sel_joy1) joy1_sr <= {1'b1, joy1_sr[7:1]};
				if (sel_joy2) joy2_sr <= {1'b1, joy2_sr[7:1]};
			end
		end
	end

	// --- read mux ---------------------------------------------------------------
	always @* begin
		if      (sel_ram)  cpu_din = ram_q;
		else if (sel_ppu)  cpu_din = ppu_dout;
		else if (sel_joy1) cpu_din = {7'h40, joy1_sr[0]};
		else if (sel_stat) cpu_din = apu_status;
		else if (sel_joy2) cpu_din = {7'h40, joy2_sr[0]};
		else if (sel_pram) cpu_din = prg_ram_q;
		else if (sel_prg)  cpu_din = prg_din;
		else               cpu_din = 8'h00;
	end

endmodule

`default_nettype wire
