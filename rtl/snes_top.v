//////////////////////////////////////////////////////////////////////////////////
// snes_top.v - the Super Nintendo: the CPU chip (snes_cpu.v), the picture chips (snes_ppu.v),
// the sound unit (snes_apu.v), 128 kB of work RAM, the cartridge (through cart_cache's
// 128-bit line port, filled into DDR3 by console_top as the Mega Drive's is) and its save
// RAM, the frame's timing, and the picture handed on a line at a time.
//
// Clocks: everything runs on `clk` (the console's, CLK_HZ) with enables made by phase
// accumulators -- `mce` at the SNES master clock (21.477 MHz), `spc_ce` at the sound CPU's
// 1.024 MHz. A line is 1364 master clocks: ~3170 of a 50 MHz clock, and the PPU draws one
// in at most ~1550.
//
// Cartridge: rom_hi picks HiROM over LoROM; rom_mask is the ROM's size rounded up to a
// power of two, less one (mirroring above it); sram_mask the save RAM's (0: none).
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_top #(
	parameter CLK_HZ = 50_000_000
)(
	input  wire        clk,
	input  wire        rst,
	input  wire        pause,         // (the menu is open: the whole machine stands still)
	// the cartridge
	input  wire        rom_hi,
	input  wire [23:0] rom_mask,
	input  wire [16:0] sram_mask,
	output wire [19:0] m_addr,
	output wire        m_req,
	input  wire        m_ready,
	input  wire [127:0] m_data,
	input  wire        m_valid,
	// the pads, as $4218 reads them (B Y Sel Start Up Down Left Right A X L R 0 0 0 0)
	input  wire [15:0] pad1,
	input  wire [15:0] pad2,
	// the picture: a line at a time, BGR555, 256 wide (hi-res pairs averaged)
	output reg         px_we,
	output reg  [8:0]  px_x,
	output reg  [8:0]  px_y,
	output reg  [14:0] px_rgb,
	output wire [8:0]  lines,         // 224 or 239
	output wire        frame_start,
	// sound: 32 kHz
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	output wire        audio_stb,
	// for a debug window
	output wire [23:0] dbg_pc,
	output wire [15:0] dbg_spc_pc
);
	// --- clocks -----------------------------------------------------------------------------
	localparam [31:0] M_INC = (64'd21477273 << 32) / CLK_HZ;
	localparam [31:0] S_INC = (64'd1024000 << 32) / CLK_HZ;
	reg [31:0] m_acc, s_acc;
	reg        mce, spc_ce;
	always @(posedge clk) begin
		{mce, m_acc} <= {1'b0, m_acc} + {1'b0, pause ? 32'd0 : M_INC};
		{spc_ce, s_acc} <= {1'b0, s_acc} + {1'b0, pause ? 32'd0 : S_INC};
		if (rst) begin m_acc <= 32'd0; s_acc <= 32'd0; mce <= 1'b0; spc_ce <= 1'b0; end
	end

	// --- the frame ----------------------------------------------------------------------------
	wire [10:0] h; wire [8:0] v; wire field, ovs;
	snes_timing u_t (.clk(clk), .rst(rst), .mce(mce), .overscan(ovs), .h(h), .v(v), .field(field),
	                 .vblank(), .hblank(), .line_start(), .frame_start(frame_start));
	assign lines = ovs ? 9'd239 : 9'd224;

	// --- the CPU chip -------------------------------------------------------------------------
	wire        req, we, is_b; wire [23:0] addr; wire [7:0] wdata, mdr;
	reg         ack; reg [7:0] rdata;
	wire [15:0] c_pc; wire [7:0] c_pbr;
	snes_cpu u_cpu (.clk(clk), .rst(rst), .mce(mce), .h(h), .v(v), .overscan(ovs),
	                .req(req), .we(we), .is_b(is_b), .addr(addr), .wdata(wdata), .ack(ack), .rdata(rdata),
	                .mdr(mdr), .pad1(pad1), .pad2(pad2), .dbg_pc(c_pc), .dbg_pbr(c_pbr));
	assign dbg_pc = {c_pbr, c_pc};

	// --- the PPU -----------------------------------------------------------------------------
	wire       b_ppu = is_b && (addr[7:6] == 2'b00);          // $2100-$213F
	wire       b_apu = is_b && (addr[7:6] == 2'b01);          // $2140-$217F
	wire       b_wram = is_b && (addr[7:2] == 6'b100000);     // $2180-$2183
	wire [7:0] ppu_rdata;
	reg        ppu_go;
	wire       ppu_done;
	reg  [8:0] rd_x; wire [14:0] rd_px;
	reg        rd_buf;
	wire       ilace;
	snes_ppu u_ppu (.clk(clk), .rst(rst), .b_wr(req && we && b_ppu), .b_rd(req && !we && b_ppu), .b_addr(addr[7:0]),
	                .b_wdata(wdata), .b_rdata(ppu_rdata), .h(h), .v(v), .go(ppu_go), .line(v), .field(field),
	                .done(ppu_done), .rd_buf(rd_buf), .rd_x(rd_x), .rd_px(rd_px),
	                .overscan(ovs), .interlace(ilace), .force_blank());

	// --- the APU ------------------------------------------------------------------------------
	wire [7:0] apu_rdata;
	snes_apu u_apu (.clk(clk), .rst(rst), .spc_ce(spc_ce),
	                .cpu_we(req && we && b_apu), .cpu_port(addr[1:0]), .cpu_wdata(wdata), .cpu_rdata(apu_rdata),
	                .audio_l(audio_l), .audio_r(audio_r), .audio_stb(audio_stb), .dbg_pc(dbg_spc_pc));

	// --- work RAM and its port -----------------------------------------------------------------
	(* ram_style = "block" *) reg [7:0] wram [0:131071];
	reg [16:0] wmadd;
	reg [16:0] w_a; reg [7:0] w_q; reg w_we; reg [7:0] w_d;
	always @(posedge clk) begin
		w_q <= wram[w_a];
		if (w_we) wram[w_a] <= w_d;
	end

	// --- save RAM ----------------------------------------------------------------------------------
	(* ram_style = "block" *) reg [7:0] sram [0:8191];      // (8 kB: most games' all; block RAM is short)
	reg [12:0] sr_a; reg [7:0] sr_q; reg sr_we; reg [7:0] sr_d;
	always @(posedge clk) begin
		sr_q <= sram[sr_a];
		if (sr_we) sram[sr_a] <= sr_d;
	end

	// --- the cartridge ------------------------------------------------------------------------------
	reg  [22:0] c_waddr; reg c_req; wire [15:0] c_word; wire c_ack;
	cart_cache #(.IDXBITS(8)) u_cc (.clk(clk), .rst(rst),
		.a_addr(c_waddr), .a_req(c_req), .a_data(c_word), .a_ack(c_ack),
		.b_addr(23'd0), .b_req(1'b0), .b_data(), .b_ack(),
		.m_addr(m_addr), .m_req(m_req), .m_ready(m_ready), .m_data(m_data), .m_valid(m_valid));

	// where an A-bus address lands
	wire [7:0]  bank = addr[23:16];
	wire [15:0] off = addr[15:0];
	wire        sys_bank = !bank[6];                                     // 00-3F, 80-BF
	wire        is_wram = (bank[7:1] == 7'b0111111) || (sys_bank && off < 16'h2000);
	wire [16:0] wram_a = (bank[7:1] == 7'b0111111) ? {bank[0], off} : {4'd0, off[12:0]};
	// LoROM: 00-7D / 80-FF at 8000-FFFF (and 40-7D / C0-FF at 0000-7FFF where no RAM is);
	// HiROM: 40-7D / C0-FF whole, and 00-3F / 80-BF at 8000-FFFF
	wire        lo_sram = !rom_hi && (bank[6:4] == 3'b111) && (bank[3:0] <= 4'hD) && !off[15] && (sram_mask != 17'd0);
	wire        hi_sram = rom_hi && sys_bank && bank[5] && (off[15:13] == 3'b011) && (sram_mask != 17'd0);
	wire        is_sram = lo_sram || hi_sram;
	wire [16:0] sram_a = lo_sram ? ({bank[3:0], off[14:0]} & sram_mask) : ({bank[4:0], off[12:0]} & sram_mask);
	wire        is_rom = !is_wram && !is_sram && (rom_hi ? (bank[6] || off[15]) : (off[15] || (bank[6] && bank[7:1] != 7'b0111111)));
	wire [23:0] rom_a = (rom_hi ? {2'b00, bank[5:0], off} : {1'b0, bank[6:0], off[14:0]}) & rom_mask;

	// answering the CPU chip: one access at a time
	localparam [2:0] A_IDLE = 3'd0, A_WRAM = 3'd1, A_WRAM2 = 3'd2, A_SRAM = 3'd3, A_SRAM2 = 3'd4, A_ROM = 3'd5;
	reg [2:0] as;
	reg       rom_lo;
	always @(posedge clk) begin
		ack <= 1'b0; w_we <= 1'b0; sr_we <= 1'b0; c_req <= 1'b0;
		if (rst) begin as <= A_IDLE; wmadd <= 17'd0; end
		else case (as)
		A_IDLE: if (req) begin
			if (is_b) begin
				if (b_ppu) begin rdata <= ppu_rdata; ack <= 1'b1; end
				else if (b_apu) begin rdata <= apu_rdata; ack <= 1'b1; end
				else if (b_wram) begin
					case (addr[1:0])
					2'd0: begin                                    // $2180: the port
						w_a <= wmadd; wmadd <= wmadd + 17'd1;
						if (we) begin w_we <= 1'b1; w_d <= wdata; ack <= 1'b1; end
						else as <= A_WRAM;
					end
					2'd1: begin if (we) wmadd[7:0] <= wdata; rdata <= mdr; ack <= 1'b1; end
					2'd2: begin if (we) wmadd[15:8] <= wdata; rdata <= mdr; ack <= 1'b1; end
					default: begin if (we) wmadd[16] <= wdata[0]; rdata <= mdr; ack <= 1'b1; end
					endcase
				end else begin rdata <= mdr; ack <= 1'b1; end     // (open bus)
			end else if (is_wram) begin
				w_a <= wram_a;
				if (we) begin w_we <= 1'b1; w_d <= wdata; ack <= 1'b1; end
				else as <= A_WRAM;
			end else if (is_sram) begin
				sr_a <= sram_a[12:0];
				if (we) begin sr_we <= 1'b1; sr_d <= wdata; ack <= 1'b1; end
				else as <= A_SRAM;
			end else if (is_rom && !we) begin
				c_waddr <= rom_a[23:1]; rom_lo <= rom_a[0]; c_req <= 1'b1;
				as <= A_ROM;
			end else begin rdata <= mdr; ack <= 1'b1; end
		end
		A_WRAM: as <= A_WRAM2;
		A_WRAM2: begin rdata <= w_q; ack <= 1'b1; as <= A_IDLE; end
		A_SRAM: as <= A_SRAM2;
		A_SRAM2: begin rdata <= sr_q; ack <= 1'b1; as <= A_IDLE; end
		A_ROM: if (c_ack) begin
			// (a stored word is {even byte, odd byte}: see cart_ddr3.v)
			rdata <= rom_lo ? c_word[7:0] : c_word[15:8];
			ack <= 1'b1; as <= A_IDLE;
		end
		default: as <= A_IDLE;
		endcase
	end

	// --- the picture: draw each line as it starts, hand the last one on -------------------------
	function [14:0] avg555;
		input [14:0] p, q;
		reg [5:0] r, g, b;
		begin
			r = {1'b0, p[4:0]} + {1'b0, q[4:0]};
			g = {1'b0, p[9:5]} + {1'b0, q[9:5]};
			b = {1'b0, p[14:10]} + {1'b0, q[14:10]};
			avg555 = {b[5:1], g[5:1], r[5:1]};
		end
	endfunction
	// (line v is drawn into output buffer v & 1 while v - 1's is copied out)
	reg [8:0] cp_line; reg cp_go; reg [9:0] cp_k; reg [14:0] cp_even;
	reg [8:0] last_v;
	always @(posedge clk) begin
		ppu_go <= 1'b0; px_we <= 1'b0;
		if (rst) begin last_v <= 9'h1FF; cp_go <= 1'b0; end
		else begin
			if (v != last_v) begin
				last_v <= v;
				if (v >= 9'd1 && v <= lines) ppu_go <= 1'b1;
				// the line before is drawn by now: copy it out
				if (v >= 9'd2 && v <= lines + 9'd1) begin cp_line <= v - 9'd1; cp_go <= 1'b1; cp_k <= 10'd0; end
			end
			if (cp_go) begin
				// pixel k's read goes out at cp_k = k and is in hand at cp_k = k + 2: pairs
				// (even, odd) averaged into one of the 256
				rd_buf <= cp_line[0];
				rd_x <= cp_k[8:0];
				cp_k <= cp_k + 10'd1;
				if (cp_k >= 10'd2) begin
					if (cp_k[0]) begin                     // pixel cp_k - 2 is odd
						px_we <= 1'b1; px_x <= (cp_k[9:1]) - 9'd1; px_y <= cp_line - 9'd1;
						px_rgb <= avg555(cp_even, rd_px);
					end else cp_even <= rd_px;
				end
				if (cp_k == 10'd513) cp_go <= 1'b0;
			end
		end
	end
endmodule
