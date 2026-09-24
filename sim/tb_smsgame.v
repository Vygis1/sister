`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_smsgame - run a REAL Master System cartridge and report what it does.
//
// tb_sms runs a cartridge I wrote, which is a fine test of the parts but a poor
// test of the machine: it does only what I already knew the machine could do.
// This one runs a commercial ROM and describes the result, because the failure
// being chased -- a black screen -- is by definition something the hand-written
// cartridge never provoked.
//
// It asserts almost nothing. It prints: the registers the game set, whether the
// display came on, what it put in video memory, where the CPU ended up, and
// whether the picture has more than one colour in it. That is the evidence
// needed to tell "the CPU is lost" from "the CPU is fine and the renderer is
// wrong", and those two have completely different fixes.
//////////////////////////////////////////////////////////////////////////////////

module tb_smsgame;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// The board makes one pixel every NINE clocks -- 50 MHz divided down to the
	// VDP's 5.5 MHz -- and the testbench used to make one every two. Both are
	// "a clock enable" and the difference is invisible to anything written
	// correctly, which is exactly why it belongs here: a fetch schedule that
	// accidentally depends on the ratio passes at 2 and fails on the board.
	parameter CE_DIV = 9;
	reg [3:0] phc = 0;
	always @(posedge clk) phc <= (phc == CE_DIV - 1) ? 4'd0 : phc + 4'd1;
	wire ce = (phc == CE_DIV - 1);

	wire [17:0] rom_addr;
	reg  [7:0]  rom_data;
	wire [8:0]  px, py;
	wire        pixel_en, frame_start;
	wire [5:0]  color;
	wire [15:0] dbg_pc;

	sms #(.ROM_AW(18)) dut (
		.clk(clk), .rst(rst), .ce(ce),
		.rom_addr(rom_addr), .rom_data(rom_data),
		.joy1(8'h00), .joy2(8'h00),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.frame_start(frame_start), .audio(),
		.dbg_pc(dbg_pc)
	);

	reg [7:0] rom [0:262143];
	always @(posedge clk) rom_data <= rom[rom_addr];

	parameter NFRAMES = 110;
	integer i, frames = 0, last = 0, vram_writes = 0;
	always @(posedge clk) if (ce && frame_start) frames <= frames + 1;

	// --- what the CPU is doing ------------------------------------------------
	// A histogram by kilobyte rather than a trace: a trace of a game is
	// millions of lines and says nothing, while "it spent the whole run in one
	// kilobyte" says immediately that it is in a wait loop.
	reg [31:0] pc_hits [0:63];
	reg [31:0] io_writes = 0, io_reads = 0, vdp_reg_writes = 0;
	reg [15:0] pc_min = 16'hFFFF, pc_max = 0;

	always @(posedge clk) if (dut.cpu_ce) begin
		pc_hits[dbg_pc[15:10]] <= pc_hits[dbg_pc[15:10]] + 1;
		if (dbg_pc < pc_min) pc_min <= dbg_pc;
		if (dbg_pc > pc_max) pc_max <= dbg_pc;
	end

	// Every VDP register write, in order. A game sets maybe a dozen; seeing the
	// list is the difference between guessing and knowing.
	always @(posedge clk) if (dut.u_vdp.cpu_vram_wr) vram_writes = vram_writes + 1;

	always @(posedge clk) begin
		if (dut.vdp_sel && dut.u_cpu.we && dut.u_cpu.addr[0]
		    && dut.u_vdp.latched && dut.cpu_dout[7:6] == 2'b10) begin
			if (vdp_reg_writes < 40) $display("    VDP reg %0d <= %02x   (t=%0t)",
			         dut.cpu_dout[3:0], dut.u_vdp.first, $time);
			vdp_reg_writes <= vdp_reg_writes + 1;
		end
		if (dut.cpu_ce && dut.u_cpu.io && dut.u_cpu.we) io_writes <= io_writes + 1;
		if (dut.cpu_ce && dut.u_cpu.io && !dut.u_cpu.we) io_reads  <= io_reads + 1;
	end

	// --- the picture ------------------------------------------------------------
	// Not a checked pattern, just: how many distinct colours reached the screen
	// and how many pixels were not the backdrop. Black screen is a statement
	// about this number and nothing else.
	reg [63:0] seen = 0;
	integer nonzero = 0, total = 0, fh = 0;
	reg watch = 0;
	always @(posedge clk) if (ce && watch && py < 192 && px < 256) begin
		seen[color] <= 1'b1;
		total = total + 1;
		if (color != dut.u_vdp.cram[{1'b1, dut.u_vdp.backdrop}]) nonzero = nonzero + 1;
		// The 6-bit colour itself, not a palette index: on this machine the
		// palette is the game's own and the file should not need it to be read.
		if (fh) begin
			$fwrite(fh, "%02x", color);
			if (px == 255) $fwrite(fh, "\n");
		end
	end

	integer ncol;
	initial begin
		for (i = 0; i < 64; i = i + 1) pc_hits[i] = 0;
		for (i = 0; i < 262144; i = i + 1) rom[i] = 8'hFF;
		$readmemh("../../sim/roms/z80/game.hex", rom);

		$display("tb_smsgame");
		repeat (8) @(posedge clk);
		rst = 0;

		last = 0;
		while (frames < NFRAMES) begin
			@(posedge clk); #1;
			if (frames != last && frames % 20 == 0) begin
				last = frames;
				$display("    frame %0d: PC=%04x display_on=%b vram_used=%0d banks=%0d/%0d/%0d",
				         frames, dbg_pc, dut.u_vdp.display_on, vram_writes,
				         dut.bank0, dut.bank1, dut.bank2);
			end
		end

		$display("");
		$display("  after %0d frames:", NFRAMES);
		$display("    PC=%04x  halted=%b  IFF1=%b  SP=%04x",
		         dbg_pc, dut.u_cpu.halted, dut.u_cpu.IFF1, dut.u_cpu.SP);
		$display("    PC range seen: %04x..%04x", pc_min, pc_max);
		$display("    I/O: %0d writes, %0d reads, %0d register writes",
		         io_writes, io_reads, vdp_reg_writes);
		$display("    banks: %0d %0d %0d", dut.bank0, dut.bank1, dut.bank2);
		$write("    VDP regs:");
		for (i = 0; i < 11; i = i + 1) $write(" %0d=%02x", i, dut.u_vdp.vr[i]);
		$display("");
		$display("    display_on=%b  vbl_irq_en=%b  line_irq_en=%b  nt_base=%0d sat=%02x",
		         dut.u_vdp.display_on, dut.u_vdp.vbl_irq_en,
		         dut.u_vdp.line_irq_en, dut.u_vdp.nt_base, dut.u_vdp.sat_base);

		$write("    CRAM:");
		for (i = 0; i < 32; i = i + 1) $write(" %02x", dut.u_vdp.cram[i]);
		$display("");

		ncol = 0;
		for (i = 0; i < 16384; i = i + 1) if (dut.u_vdp.vram[i] != 0) ncol = ncol + 1;
		$display("    VRAM: %0d of 16384 bytes non-zero", ncol);
		$write("    name table @%04x:", {dut.u_vdp.nt_base, 11'd0});
		for (i = 0; i < 16; i = i + 1)
			$write(" %02x", dut.u_vdp.vram[{dut.u_vdp.nt_base, 11'd0} + i]);
		$display("");

		$write("    where the CPU spent its time:");
		for (i = 0; i < 64; i = i + 1)
			if (pc_hits[i] != 0) $write(" %04x:%0d", i * 1024, pc_hits[i]);
		$display("");

		// --- one more frame, watched --------------------------------------------
		fh = $fopen("../../build/sms_sim.txt", "w");
		watch = 1;
		i = frames;
		while (frames < i + 2) begin @(posedge clk); #1; end
		watch = 0;
		$fclose(fh); fh = 0;

		ncol = 0;
		for (i = 0; i < 64; i = i + 1) if (seen[i]) ncol = ncol + 1;
		$display("");
		$display("  the picture: %0d distinct colours, %0d of %0d pixels not backdrop",
		         ncol, nonzero, total);
		$write("    colours seen:");
		for (i = 0; i < 64; i = i + 1) if (seen[i]) $write(" %02x", i);
		$display("");

		$finish;
	end

	initial begin
		repeat (200_000_000) @(posedge clk);
		$display("tb_smsgame: FAIL timeout at PC=%04x (frames=%0d)", dbg_pc, frames);
		$finish;
	end

endmodule
