//////////////////////////////////////////////////////////////////////////////////
// tb_md_z80trace - how a game hands its sound driver to the Z80: every write the
// 68000 makes to the bus request ($A11100) and reset ($A11200), how many it makes
// into the Z80's RAM and when, and where the Z80 runs -- the first time it leaves
// its RAM, and the spread of its PC after. A game whose Z80 ends up running in the
// cartridge window ($8000 up) is silent.
//
//   ./tools/sim.sh tb_md_z80trace ROM=../../sim/roms/md/btdd.hex CLOCKS=6000000
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps

module tb_md_z80trace;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	reg [3:0] div = 0;
	always @(posedge clk) div <= div + 4'd1;
	wire cpu_ce = (div[2:0] == 3'd6);
	wire vdp_ce = (div[1:0] == 2'd3);
	wire snd_ce = (div[2:0] == 3'd7);
	reg [6:0] fmdiv = 0;
	always @(posedge clk) fmdiv <= fmdiv + 7'd1;
	wire fm_ce = (fmdiv == 7'd127);

	wire [9:0] px, py; wire pixel_en; wire [8:0] color; wire [31:0] pc; wire halted;
	wire [19:0] mem_addr; wire mem_req;
	reg mem_ready = 1; reg [127:0] mem_data = 0; reg mem_valid = 0;
	wire signed [15:0] audio_l, audio_r;
	reg [15:0] cart [0:2097151];
	reg [19:0] mem_line; integer mi;
	initial forever begin
		@(posedge clk);
		if (mem_req && mem_ready) begin
			mem_line = mem_addr; mem_ready <= 1'b0;
			repeat (24) @(posedge clk);
			for (mi = 0; mi < 8; mi = mi + 1) mem_data[mi*16 +: 16] <= cart[{mem_line[17:0], mi[2:0]}];
			mem_valid <= 1'b1; @(posedge clk); mem_valid <= 1'b0; mem_ready <= 1'b1;
		end
	end
	md_top dut (
		.clk(clk), .rst(rst), .cpu_ce(cpu_ce), .vdp_ce(vdp_ce), .snd_ce(snd_ce), .fm_ce(fm_ce),
		.mem_addr(mem_addr), .mem_req(mem_req), .mem_ready(mem_ready), .mem_data(mem_data), .mem_valid(mem_valid),
		.audio_l(audio_l), .audio_r(audio_r), .joy1(8'hFF), .joy2(8'd0),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color), .dbg_pc(pc), .dbg_z80_pc(), .dbg_halted(halted));

	wire [15:0] zpc = dut.snd.cpu.dbg_pc;
	wire [23:0] a = dut.cpu_addr;
	wire        w = dut.cpu_req && dut.cpu_we && dut.cpu_en;
	integer clocks = 0, ram_writes = 0, first_ram = -1, last_ram = -1, left = -1, n_ram = 0, n_out = 0;
	integer lo = 65535, hi = 0;
	reg [23:0] last_a = 24'hFFFFFF;
	// the Z80's last 16 PCs, and its bank writes
	reg [15:0] hist [0:15]; integer hp = 0, nbank = 0, k; reg [15:0] lastpc = 16'hFFFF;
	always @(posedge clk) if (!rst && dut.snd.z_run && zpc != lastpc) begin
		lastpc = zpc; hist[hp % 16] = zpc; hp = hp + 1;
	end
	always @(posedge clk) if (!rst && dut.snd.z_run && dut.snd.z_we && dut.snd.z_bank) begin
		nbank = nbank + 1;
		if (nbank <= 40 || (nbank % 9 == 0 && nbank < 400))
			$display("  @%0d  Z80 bank write #%0d: bit %0d -> bank %03x (the window at $%06x) pc %04x", clocks, nbank, dut.snd.z_dout[0],
			         {dut.snd.z_dout[0], dut.snd.bank[8:1]}, {dut.snd.z_dout[0], dut.snd.bank[8:1], 15'd0}, zpc);
	end
	always @(posedge clk) if (!rst) begin
		clocks = clocks + 1;
		if (w && a != last_a) begin
			if (a[23:8] == 16'hA111 || a[23:8] == 16'hA112)
				$display("  @%0d  68000 writes $%06x = %04x (pc %06x)  -> busreq %0d reset_n %0d", clocks, a, dut.cpu_dout, pc,
				         dut.z80_busreq, dut.z80_reset_n);
			if (a[23:13] == 11'b1010_0000_000) begin
				ram_writes = ram_writes + 1;
				if (first_ram < 0) first_ram = clocks;
				last_ram = clocks;
			end
		end
		last_a = w ? a : 24'hFFFFFF;
		if (dut.z80_reset_n && !dut.z80_busreq) begin
			if (zpc < 16'h2000) n_ram = n_ram + 1;
			else begin
				n_out = n_out + 1;
				if (left < 0) begin
					left = clocks;
					$display("  @%0d  the Z80 leaves its RAM: pc %04x, bank %03x (window at $%06x)", clocks, zpc, dut.snd.bank, {dut.snd.bank, 15'd0});
					for (k = 0; k < 16; k = k + 1) $write(" %04x", hist[(hp + k) % 16]);
					$display("");

				end
				if (zpc < lo) lo = zpc; if (zpc > hi) hi = zpc;
			end
		end
	end

	integer peak = 0, nchg = 0, firstsnd = -1; reg signed [15:0] lastl = 0;
	integer nzint = 0, nh38 = 0; reg zi_d = 0, at38 = 0;
	always @(posedge clk) if (!rst) begin
		zi_d <= dut.z80_int; if (dut.z80_int && !zi_d) nzint = nzint + 1;
		if (zpc == 16'h0038 && !at38) nh38 = nh38 + 1;
		at38 <= (zpc == 16'h0038);
	end
	always @(posedge clk) if (!rst && audio_l != lastl) begin
		nchg = nchg + 1; lastl = audio_l;
		if (audio_l > peak) peak = audio_l; if (-audio_l > peak) peak = -audio_l;
		if (firstsnd < 0 && (audio_l > 500 || audio_l < -500)) begin firstsnd = clocks; $display("  @%0d  sound starts", clocks); end
	end
	reg [1023:0] romfile; integer limit;
	initial begin
		if (!$value$plusargs("ROM=%s", romfile)) romfile = "../../sim/roms/md/btdd.hex";
		if (!$value$plusargs("CLOCKS=%d", limit)) limit = 5000000;
		$readmemh(romfile, cart);
		repeat (16) @(posedge clk); rst = 0;
		wait (clocks >= limit);
		$display("tb_md_z80trace: %0d writes into the Z80's RAM (clocks %0d .. %0d)", ram_writes, first_ram, last_ram);
		$display("tb_md_z80trace: the Z80 ran in its RAM %0d clocks, outside it %0d (pc %04x .. %04x)", n_ram, n_out, lo, hi);
		$display("tb_md_z80trace: the left channel changed %0d times, peak %0d", nchg, peak);
		$display("tb_md_z80trace: %0d Z80 interrupts from the VDP, the handler at $38 entered %0d times", nzint, nh38);
		$finish;
	end
endmodule

`default_nettype wire
