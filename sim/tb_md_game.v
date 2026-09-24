//////////////////////////////////////////////////////////////////////////////////
// tb_md_game - run a real cartridge and say what stops it.
//
// The hand-written test cartridge passes. Commercial games do not, and the way
// they fail is useless on its own: the 68000 ends up spinning in whatever
// address the game's vector table points its error handler at, thousands of
// cycles after the thing that actually went wrong.
//
// So this watches the one signal that names a cause. m68k.v now raises vector 4
// on an opcode it cannot decode and latches the opcode and the PC on the way
// past; this prints them the first time it happens, which turns "Sonic shows a
// black screen" into "it is MOVEP, at $1a2c".
//
//   ./tools/sim.sh tb_md_game            -- defaults to combatcars
//
// Nothing here checks a picture. The picture is the reward for getting the
// instruction set right, and until that happens there is nothing to check.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_md_game;
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

	wire [9:0]  px, py;
	wire        pixel_en;
	wire [8:0]  color;
	wire [31:0] pc;
	wire        halted;

	wire [19:0]  mem_addr;
	wire         mem_req;
	reg          mem_ready = 1;
	reg  [127:0] mem_data  = 0;
	reg          mem_valid = 0;
	wire signed [15:0] audio_l, audio_r;

	// A whole 4 MB of cartridge, because a commercial one does not fit in the
	// 128 kB the other testbenches use.
	reg [15:0] cart [0:2097151];
	reg [19:0] mem_line;
	integer    mi;

	initial begin
		forever begin
			@(posedge clk);
			if (mem_req && mem_ready) begin
				mem_line  = mem_addr;
				mem_ready <= 1'b0;
				repeat (24) @(posedge clk);
				for (mi = 0; mi < 8; mi = mi + 1)
					mem_data[mi*16 +: 16] <= cart[{mem_line[17:0], mi[2:0]}];
				mem_valid <= 1'b1;
				@(posedge clk);
				mem_valid <= 1'b0;
				mem_ready <= 1'b1;
			end
		end
	end

	reg [7:0] joy1 = 8'hFF;

	md_top dut (
		.clk(clk), .rst(rst), .cpu_ce(cpu_ce), .vdp_ce(vdp_ce),
		.snd_ce(snd_ce), .fm_ce(fm_ce),
		.mem_addr(mem_addr), .mem_req(mem_req), .mem_ready(mem_ready),
		.mem_data(mem_data), .mem_valid(mem_valid),
		.audio_l(audio_l), .audio_r(audio_r), .joy1(joy1), .joy2(8'd0),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.dbg_pc(pc), .dbg_halted(halted)
	);

	// --- what could not be decoded -------------------------------------------
	//
	// Report every DISTINCT opcode rather than only the first: one run then
	// names the whole list to implement instead of one instruction per
	// twenty-minute iteration.
	integer nbad = 0;
	reg [15:0] seen [0:63];
	integer si;
	reg dup;

	// Is it drawing anything? A game that runs but paints nothing is still a
	// black screen, so count what reaches the framebuffer, not just that the
	// CPU is alive.
	integer npix = 0, nlit = 0, ncol = 0, nwritten = 0, nvram = 0;
	integer vi;
	reg [511:0] colseen = 0;
	always @(posedge clk) if (!rst && pixel_en) begin
		npix = npix + 1;
		if (color !== 9'd0) nlit = nlit + 1;
		if (!colseen[color]) begin colseen[color] = 1'b1; ncol = ncol + 1; end
	end

	// Capture what the VDP actually paints, so a run can be looked at instead of
	// summarised. H40 is 320 wide and the machine draws 224 lines.
	reg [8:0] fb [0:320*224-1];
	integer fx, fy, fd;
	always @(posedge clk) if (!rst && pixel_en && px < 320 && py < 224)
		fb[py * 320 + px] <= color;

	// Every word the DMA hands the VDP should be the word that is actually in the
	// cartridge at the address it asked for. If the read path ever returns the
	// right-shaped answer for the wrong address, the game still runs -- it just
	// draws rubbish, which looks like a VDP fault and is not one.
	integer dma_checked = 0, dma_bad = 0;
	always @(posedge clk) if (!rst && dut.vdp_dma_ack && dut.cart_region) begin
		dma_checked = dma_checked + 1;
		if (dut.vdp_dma_din !== cart[dut.bus_a[20:0]]) begin
			if (dma_bad < 8)
				$display("  DMA MISMATCH at word $%06h: got $%04h, cart has $%04h",
				         dut.bus_a, dut.vdp_dma_din, cart[dut.bus_a[20:0]]);
			dma_bad = dma_bad + 1;
		end
	end

	// Count what happens to the VBlank interrupt: raised, accepted, or thrown
	// away by a status read before the CPU ever saw it.
	integer vint_sets = 0, vint_taken = 0, vint_stat = 0;
	reg vp_d = 0;
	always @(posedge clk) if (!rst) begin
		if (dut.vdp.vint_pending && !vp_d) vint_sets = vint_sets + 1;
		if (!dut.vdp.vint_pending && vp_d) begin
			if (dut.vdp.status_read) vint_stat = vint_stat + 1;
			else                     vint_taken = vint_taken + 1;
		end
		vp_d <= dut.vdp.vint_pending;
	end

	// Are sprites reaching the screen at all? The car is a sprite, and "the car
	// is not visible" is a different fault from "the track is wrong".
	integer spr_pix = 0, spr_lines = 0;
	reg op_s_d = 0;
	always @(posedge clk) if (!rst && dut.vdp.pixel_en) begin
		if (dut.vdp.op_s) spr_pix = spr_pix + 1;
		if (dut.vdp.op_s && !op_s_d) spr_lines = spr_lines + 1;
		op_s_d <= dut.vdp.op_s;
	end

	// Where does the sprite engine stop? Count how far it gets each line.
	integer n_rd0 = 0, n_test = 0, n_onrow = 0, n_pix = 0, n_wr = 0, n_on = 0;
	always @(posedge clk) if (!rst && dut.vdp.ce) begin
		if (dut.vdp.sp_st == 4'd1)  n_rd0  = n_rd0  + 1;
		if (dut.vdp.sp_st == 4'd5)  n_test = n_test + 1;
		if (dut.vdp.sp_st == 4'd5 && dut.vdp.sp_onrow) n_onrow = n_onrow + 1;
		if (dut.vdp.sp_st == 4'd13) n_pix  = n_pix  + 1;
		if (dut.vdp.sp_st == 4'd13 && dut.vdp.sp_on) n_on = n_on + 1;
		if (dut.vdp.sp_wr) n_wr = n_wr + 1;
	end

	// Is the pattern word itself zero, or is the address wrong?
	integer n_getp = 0, n_getp_nz = 0, shown = 0;
	always @(posedge clk) if (!rst && dut.vdp.ce && dut.vdp.sp_st == 4'd12) begin
		n_getp = n_getp + 1;
		if (dut.vdp.r_data !== 16'd0) n_getp_nz = n_getp_nz + 1;
		if (shown < 6) begin
			$display("  SP_GETP: pat addr $%04h -> word $%04h  (tile $%03h, at $%04h)",
			         dut.vdp.sp_pat, dut.vdp.r_data, dut.vdp.sp_at[10:0], dut.vdp.sp_at);
			shown = shown + 1;
		end
	end

	// At the moment a pixel is decided: is sp_word unknown (a capture landing on
	// the wrong cycle) or genuinely zero (a tile the game never filled)?
	integer w_x = 0, w_zero = 0, w_real = 0;
	always @(posedge clk) if (!rst && dut.vdp.ce && dut.vdp.sp_st == 4'd13) begin
		if (^dut.vdp.sp_word === 1'bx) w_x = w_x + 1;
		else if (dut.vdp.sp_word == 16'd0) w_zero = w_zero + 1;
		else w_real = w_real + 1;
	end

	// A whole sprite entry, as the engine understood it. If Y and X are sensible
	// screen coordinates then the attribute table is being read correctly and
	// the tile index is the game's own -- which moves the question to whether
	// that tile was ever filled.
	integer shown2 = 0;
	always @(posedge clk) if (!rst && dut.vdp.ce && dut.vdp.sp_st == 4'd13
	                          && shown2 < 8 && dut.vdp.sp_k == 2'd0) begin
		$display("  sprite: y=%0d x=%0d w=%0d h=%0d tile=$%03h pal=%0d pri=%b link=%0d",
		         dut.vdp.sp_y - 10'd128, $signed(dut.vdp.sp_px),
		         dut.vdp.sp_w + 1, dut.vdp.sp_h + 1, dut.vdp.sp_at[10:0],
		         dut.vdp.sp_at[14:13], dut.vdp.sp_at[15], dut.vdp.sp_link);
		shown2 = shown2 + 1;
	end

	// RAM -> VRAM DMA: the sprite table travels this way every frame. The cart
	// path was proven clean; this path reads work RAM through a registered
	// port that lags bus_a by a clock, so check it the same way.
	integer rdma_n = 0, rdma_bad = 0, rdma_shown = 0;
	always @(posedge clk) if (!rst && dut.vdp_dma_ack && !dut.cart_region
	                          && dut.bus_a[22:15] == 8'hFF) begin
		rdma_n = rdma_n + 1;
		if (dut.vdp_dma_din !== dut.wram[dut.bus_a[14:0]]) begin
			rdma_bad = rdma_bad + 1;
			if (rdma_shown < 6) begin
				$display("  RAM-DMA MISMATCH word $%06h: got $%04h, wram has $%04h (prev word $%04h)",
				         dut.bus_a, dut.vdp_dma_din, dut.wram[dut.bus_a[14:0]],
				         dut.wram[dut.bus_a[14:0] - 15'd1]);
				rdma_shown = rdma_shown + 1;
			end
		end
	end

	// The four attribute reads of the first sprite, as they happen.
	integer sat_shown = 0;
	always @(posedge clk) if (!rst && dut.vdp.ce && sat_shown < 8
	         && (dut.vdp.sp_st == 4'd2 || dut.vdp.sp_st == 4'd4
	          || dut.vdp.sp_st == 4'd7 || dut.vdp.sp_st == 4'd9)
	         && dut.vdp.sp_wait == 2'd0) begin
		$display("  SAT read st=%0d r_addr=$%04h r_data=$%04h vram[sp_addr=$%04h]=$%04h",
		         dut.vdp.sp_st, dut.vdp.r_addr, dut.vdp.r_data,
		         dut.vdp.sp_addr, dut.vdp.vram[dut.vdp.sp_addr]);
		sat_shown = sat_shown + 1;
	end

	reg [31:0] ring [0:31];
	integer    rp = 0, nring = 0;
	reg [31:0] prev_pc = 32'hFFFF_FFFF;
	reg        derailed = 0;
	integer    stuck = 0;
	integer    wi;
	reg [31:0] stuck_pc = 32'hFFFF_FFFF;
	reg        reported = 0;

	reg [200*8:1] romfile;
	integer cycles;

	initial begin
		if (!$value$plusargs("ROM=%s", romfile))
			romfile = "../../sim/roms/md/combatcars.hex";
		$readmemh(romfile, cart);

		// Work RAM starts defined, because on the board it is.
		//
		// Without this the first DMA out of a location the game has not written
		// returns X, the X reaches the PC, and the run dies in a way the
		// hardware never does -- which sends you looking for a deadlock that is
		// not there. Real DRAM powers up holding something; zero is as good a
		// something as any, and it makes a sim run comparable with a board run.
		for (wi = 0; wi < 32768; wi = wi + 1) dut.wram[wi] = 16'd0;

		repeat (8) @(posedge clk);
		rst = 0;

		for (cycles = 0; cycles < 120000000; cycles = cycles + 1) begin
			@(posedge clk);

			// Where it was, just before it went wrong. The failure is a jump to
			// an address the game never wrote, so the useful question is not
			// "what is at that address" -- nothing is -- but "what was running
			// immediately before the jump".
			if (pc !== prev_pc) begin
				ring[rp] = pc;
				rp = (rp + 1) % 32;
				if (nring < 32) nring = nring + 1;
				prev_pc = pc;
			end
			if (!derailed && (pc >= 32'h00ff0000)) begin
				derailed = 1;
				$display("  PC entered RAM at $%06h, cycle %0d. Last 32 PCs:",
				         pc, cycles);
				for (si = 0; si < nring; si = si + 1)
					$display("      $%06h", ring[(rp + si) % 32]);
			end

			// Deadlock watch. The machine freezing is not the same as the CPU
			// stopping: bus_a follows the DMA, so a DMA that never ends takes
			// the CPU and the renderer with it. Report which it is.
			if (pc === stuck_pc) stuck = stuck + 1;
			else begin stuck = 0; stuck_pc = pc; end
			if (stuck > 2000000 && !reported) begin
				reported = 1;
				$display("  DEADLOCK: pc held at $%06h for %0d cycles", pc, stuck);
				$display("    dma_active %b  mode %b  st %d  len %0d  sa $%06h",
				         dut.vdp.dma_active, dut.vdp.dma_mode, dut.vdp.dma_st,
				         dut.vdp.dma_len, dut.vdp.dma_sa);
				$display("    cart_want %b cart_ready %b cart_have %b  bus_a $%06h",
				         dut.cart_want, dut.cart_ready, dut.cart_have, dut.bus_a);
				$display("    dma_phase %b  vdp_dma_req %b", dut.dma_phase,
				         dut.vdp_dma_req);
			end

			if (dut.cpu.bad_hit) begin
				dup = 0;
				for (si = 0; si < nbad; si = si + 1)
					if (seen[si] === dut.cpu.bad_op) dup = 1;
				if (!dup && nbad < 64) begin
					seen[nbad] = dut.cpu.bad_op;
					nbad = nbad + 1;
					$display("  undecoded $%04h at PC $%06h  (cycle %0d)",
					         dut.cpu.bad_op, dut.cpu.bad_pc, cycles);
				end
			end
		end

		$display("");
		// Has the game set a palette yet? An X here is not a black screen, it
		// is a palette the cartridge has not written -- which after five frames
		// means it is still initialising, not that it has failed.
		nvram = 0;
		for (vi = 0; vi < 32768; vi = vi + 1)
			if (^dut.vdp.vram[vi] !== 1'bx) nvram = nvram + 1;
		nwritten = 0;
		for (si = 0; si < 64; si = si + 1)
			if (^dut.vdp.cram[si] !== 1'bx) nwritten = nwritten + 1;
		$display("  CRAM entries written: %0d of 64", nwritten);
		$display("  VRAM words written  : %0d of 32768", nvram);
		if (nbad == 0)
			$display("tb_md_game: no undecoded opcodes in %0d cycles", cycles);
		else
			$display("tb_md_game: %0d distinct undecoded opcode(s)", nbad);
		fd = $fopen("../../build/md_sim_frame.txt", "w");
		for (fy = 0; fy < 224; fy = fy + 1) begin
			for (fx = 0; fx < 320; fx = fx + 1)
				$fwrite(fd, "%03h\n", fb[fy * 320 + fx]);
		end
		$fclose(fd);
		$display("  frame written to build/md_sim_frame.txt");
		$display("  DMA words checked %0d, wrong %0d", dma_checked, dma_bad);
		$display("  sprite pixels on screen: %0d (in %0d runs)", spr_pix, spr_lines);
		$display("  sprite engine: RD0 %0d, TEST %0d, onrow %0d, PIX %0d, on-screen %0d, writes %0d",
		         n_rd0, n_test, n_onrow, n_pix, n_on, n_wr);
		$display("  SAT base: reg5 $%02h -> word $%04h", dut.vdp.r[5], dut.vdp.sat_base);
		$display("  pattern fetches %0d, non-zero %0d", n_getp, n_getp_nz);
		$display("  at SP_PIX: sp_word unknown %0d, zero %0d, real %0d", w_x, w_zero, w_real);
		$display("  RAM->VRAM DMA words %0d, wrong %0d", rdma_n, rdma_bad);
		$display("  --- interrupts ---");
		$display("    VDP reg1 = $%02h (VBL int enable = %b)",
		         dut.vdp.r[1], dut.vdp.r[1][5]);
		$display("    vint_pending %b  ipl_n %b  int_level %0d",
		         dut.vdp.vint_pending, dut.ipl_n, dut.vdp.int_level);
		$display("    CPU mask I = %0d, S = %b   (VBL is level 6)",
		         dut.cpu.I, dut.cpu.S);
		$display("    vint set %0d times, taken %0d times, cleared by status read %0d",
		         vint_sets, vint_taken, vint_stat);
		$display("  final PC $%06h", pc);
		$display("  last %0d distinct PCs:", nring);
		for (si = 0; si < nring; si = si + 1)
			$display("      $%06h", ring[(rp + si) % 32]);
		$finish;
	end
endmodule

`default_nettype wire
