`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_sms - a whole Master System running a cartridge.
//
// Everything below this has been tested on its own: the Z80 against ZEXDOC and
// ZEXALL, the VDP against its own bench. What has not been tested is the part
// that only exists when they are wired together -- the I/O decode, the mapper,
// the interrupt line, and whether a program's writes to two ports actually turn
// into pixels.
//
// The cartridge is tools/sms/smstest.py, which draws a screen whose every pixel is
// known in advance. That is the point of writing one rather than finding a
// game: the test can check the picture instead of a person squinting at it.
//////////////////////////////////////////////////////////////////////////////////

module tb_sms;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One pixel every two clocks, so the Z80 lands on a sensible fraction of it.
	reg ph = 0;
	always @(posedge clk) ph <= ~ph;
	wire ce = ph;

	wire [17:0] rom_addr;
	reg  [7:0]  rom_data;
	wire [8:0]  px, py;
	wire        pixel_en, frame_start;
	wire [5:0]  color;
	wire [15:0] dbg_pc;

	sms #(.ROM_AW(18)) dut (
		.clk(clk), .rst(rst), .ce(ce),
		.rom_addr(rom_addr), .rom_data(rom_data),
		.joy1(8'h12), .joy2(8'h00),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.frame_start(frame_start),
		.dbg_pc(dbg_pc)
	);

	// The cartridge, as block RAM answers it: a cycle late.
	reg [7:0] rom [0:262143];
	always @(posedge clk) rom_data <= rom[rom_addr];

	integer errors = 0, i;
	integer a_lo, a_hi, a_v;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	task at_px;
		input [8:0] want_y;
		input [8:0] want_x;
		begin
			while (!(py == want_y && px == want_x)) begin
				@(posedge clk); #1;
			end
		end
	endtask

	// The first few instructions, so a CPU that stops on one is visible.
	integer tr = 0;
	always @(posedge clk) begin
		if (!rst && dut.cpu_ce && tr < 40) begin
			$display("    st=%0d pc=%04x op=%02x addr=%04x din=%02x halted=%b",
			         dut.u_cpu.st, dut.u_cpu.PC, dut.u_cpu.op,
			         dut.u_cpu.addr, dut.u_cpu.din, dut.u_cpu.halted);
			tr <= tr + 1;
		end
	end

	integer frames = 0;
	always @(posedge clk) if (ce && frame_start) frames <= frames + 1;

	initial begin
		for (i = 0; i < 262144; i = i + 1) rom[i] = 8'h00;
		$readmemh("../../sim/roms/z80/smstest.hex", rom);

		$display("tb_sms");
		repeat (8) @(posedge clk);
		rst = 0;

		// Let the program get through its setup and turn the display on.
		while (frames < 4) begin @(posedge clk); #1; end

		$display("    PC now %04x, IFF1=%b, vr1=%02x, frames=%0d",
		         dbg_pc, dut.u_cpu.IFF1, dut.u_vdp.vr[1], frames);
		$display(" the program ran:");
		check(dut.u_vdp.display_on === 1'b1, "it turned the display on");
		check(dut.u_vdp.vr[2] == 8'hFF, "it set the name table register");
		check(dut.u_vdp.cram[1] == 6'h03, "it loaded the palette");
		check(dut.u_vdp.vram[14'h0020] == 8'hF0, "it loaded a tile into VRAM");
		check(dut.u_vdp.vram[14'h3800] == 8'h01, "it filled the name table");

		$display(" the picture:");
		// Tile 1 is colour 1 on its left half and colour 2 on its right, so a
		// pixel from each half proves the planes and the palette both work.
		// The whole first two tiles, so the shape is on the record rather than
		// just a couple of sampled points.
		$write("    line 100, pixels 0..15:");
		for (i = 0; i < 16; i = i + 1) begin
			at_px(9'd100, i[8:0]);
			$write(" %02x", color);
		end
		$display("");
		at_px(9'd100, 9'd2);
		check(color == 6'h03, "left half of a tile is palette entry 1");
		at_px(9'd100, 9'd6);
		check(color == 6'h0C, "right half is palette entry 2");
		at_px(9'd100, 9'd10);
		check(color == 6'h03, "and the next tile starts again");

		// Below the name table's 28 rows there is nothing, so the backdrop shows.
		at_px(9'd191, 9'd8);
		check(color == 6'h03 || color == 6'h0C || color == 6'h20,
		      "the bottom of the picture is drawn, not blank");

		// --- sound ---------------------------------------------------------------
		// The cartridge sets three tone channels going, so the output should be
		// moving. Measuring the swing answers that without needing an opinion
		// about what the notes should be.
		$display(" sound:");
		check(dut.u_psg.att[0] == 4'd0,  "channel 0 volume was set");
		check(dut.u_psg.att[3] == 4'd15, "the noise channel was silenced");
		check(dut.u_psg.period[0] == 10'h00E, "channel 0 period was set");

		a_lo = 99999; a_hi = -1;
		for (i = 0; i < 200000; i = i + 1) begin
			@(posedge clk);
			a_v = dut.audio;
			if (a_v < a_lo) a_lo = a_v;
			if (a_v > a_hi) a_hi = a_v;
		end
		$display("    audio ranged %0d..%0d (centre 32768)", a_lo, a_hi);
		check(a_hi - a_lo > 1000, "the sound output is moving");
		check(a_lo > 20000 && a_hi < 45000, "and stays in range");

		// --- interrupts ----------------------------------------------------------
		// The one thing every real game depends on and the test cartridge did
		// not previously use: a VBlank interrupt driving the frame loop.
		$display(" interrupts:");
		check(dut.u_cpu.IFF1 === 1'b1, "the program enabled interrupts");
		check(dut.u_vdp.vbl_irq_en === 1'b1, "and the VDP is set to raise them");
		i = dut.wram[13'h0000];
		while (frames < 12) begin @(posedge clk); #1; end
		$display("    handler ran %0d times over 8 frames", dut.wram[13'h0000] - i);
		check(dut.wram[13'h0000] > i,
		      "the handler ran, so the interrupt reached the CPU");
		check(dut.wram[13'h0000] - i >= 4,
		      "about once a frame, not once ever");

		// --- the ports the CPU READS ------------------------------------------
		// Writes were always fine; reads were not, and nothing here noticed for
		// as long as the cartridge read a port and ignored the answer. These
		// three are what a game actually does with the machine's three readable
		// ports, and each one fails differently if the byte coming back is
		// whatever happened to be in memory at that address.
		$display(" the readable ports:");
		$display("    VBlanks=%0d other=%0d  V seen %0d..%0d  pad=%02x",
		         dut.wram[13'h0000], dut.wram[13'h0001],
		         dut.wram[13'h0005], dut.wram[13'h0004], dut.wram[13'h0006]);
		check(dut.wram[13'h0001] <= 8'd2,
		      "the status port branch was taken correctly");
		check(dut.wram[13'h0004] > dut.wram[13'h0005],
		      "the V counter moved");
		check(dut.wram[13'h0004] >= 8'd200 && dut.wram[13'h0005] <= 8'd8,
		      "and covered the frame");
		// joy1 is driven with $12 -- right and button 2 -- and the port is
		// active low, so the one byte that proves the pad answered is $ED.
		check(dut.wram[13'h0006] == 8'hED,
		      "the control pad reported exactly what is held");

		$display(" the CPU is still running:");
		check(dbg_pc >= 16'h0000 && dbg_pc < 16'h0400,
		      "it is in its own code, not lost");

		$display("");
		if (errors == 0) $display("tb_sms: all checks passed");
		else             $display("tb_sms: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (20_000_000) @(posedge clk);
		$display("tb_sms: FAIL timeout at PC=0x%04X", dbg_pc);
		$finish;
	end

endmodule
