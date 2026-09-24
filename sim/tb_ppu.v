`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_ppu - frame geometry and register behaviour.
//
// These are the parts of the PPU that can be checked without a whole console
// around it, and they are the parts everything else depends on: if the frame is
// the wrong length or VBlank lands on the wrong dot, every game that does raster
// work breaks in ways that look like rendering bugs.
//
// The register side effects matter just as much. Reading $2002 clears VBlank and
// the write toggle, and $2005/$2006 share that toggle -- get it wrong and
// scrolling drifts in ways that are near-impossible to localise later.
//////////////////////////////////////////////////////////////////////////////////

module tb_ppu;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	reg  [2:0] cpu_addr = 0;
	reg  [7:0] cpu_din = 0;
	wire [7:0] cpu_dout;
	reg        cpu_rd = 0, cpu_wr = 0;
	wire       nmi;

	wire [13:0] vram_addr;
	wire [7:0]  vram_dout;
	wire        vram_rd, vram_wr;
	reg  [7:0]  vram_din;

	wire [8:0] cycle, scanline;
	wire       pixel_en, frame_start, vblank_start;
	wire [5:0] pixel;

	ppu dut (
		.clk(clk), .rst(rst), .ce(1'b1),
		.cpu_addr(cpu_addr), .cpu_din(cpu_din), .cpu_dout(cpu_dout),
		.cpu_rd(cpu_rd), .cpu_wr(cpu_wr), .nmi(nmi),
		.vram_addr(vram_addr), .vram_din(vram_din), .vram_dout(vram_dout),
		.vram_rd(vram_rd), .vram_wr(vram_wr),
		.cycle(cycle), .scanline(scanline), .pixel_en(pixel_en), .pixel(pixel),
		.frame_start(frame_start), .vblank_start(vblank_start)
	);

	// A flat VRAM, enough to satisfy fetches.
	reg [7:0] vram [0:16383];
	always @* vram_din = vram[vram_addr];
	always @(posedge clk) if (vram_wr) vram[vram_addr] <= vram_dout;

	task wr;
		input [2:0] a;
		input [7:0] d;
		begin
			@(posedge clk); #1;
			cpu_addr = a; cpu_din = d; cpu_wr = 1;
			@(posedge clk); #1;
			cpu_wr = 0;
		end
	endtask

	// Park the simulation on one exact dot, so a check names the pixel it means.
	task at;
		input [8:0] want_sl;
		input [8:0] want_cyc;
		begin
			@(posedge clk); #1;
			while (!(scanline == want_sl && cycle == want_cyc)) begin
				@(posedge clk); #1;
			end
		end
	endtask

	reg [7:0] rdval;
	task rd;
		input [2:0] a;
		begin
			@(posedge clk); #1;
			cpu_addr = a; cpu_rd = 1;
			#1 rdval = cpu_dout;        // sample while the read is asserted
			@(posedge clk); #1;
			cpu_rd = 0;
		end
	endtask

	integer k, dots, frames;
	reg [8:0] max_cycle, max_line;
	reg saw_nmi;
	integer f_even, f_odd;

	initial begin
		for (k = 0; k < 16384; k = k + 1) vram[k] = k[7:0];

		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		$display("tb_ppu");

		// --- frame geometry, rendering disabled ---------------------------
		$display(" geometry with rendering off:");
		max_cycle = 0; max_line = 0; dots = 0;
		@(posedge clk); #1;
		while (!frame_start) begin @(posedge clk); #1; end
		// Count from one frame start round to the next.
		dots = 0;
		@(posedge clk); #1; dots = dots + 1;
		while (!frame_start) begin
			if (cycle > max_cycle) max_cycle = cycle;
			if (scanline > max_line) max_line = scanline;
			@(posedge clk); #1;
			dots = dots + 1;
		end
		check(max_cycle == 340, "cycles run 0..340");
		check(max_line == 261, "scanlines run 0..261");
		check(dots == 341*262, "341 x 262 dots per frame");

		// --- VBlank and NMI -------------------------------------------------
		$display(" VBlank:");
		wr(3'd0, 8'h80);                       // enable NMI
		saw_nmi = 0;
		while (scanline != 9'd240) begin @(posedge clk); #1; end
		rd(3'd2);
		check(rdval[7] == 1'b0, "VBlank clear during post-render");

		while (!vblank_start) begin @(posedge clk); #1; end
		repeat (2) begin @(posedge clk); #1; end
		check(nmi === 1'b1, "NMI asserted once VBlank is set");
		rd(3'd2);
		check(rdval[7] == 1'b1, "$2002 reports VBlank");
		rd(3'd2);
		check(rdval[7] == 1'b0, "reading $2002 cleared VBlank");
		check(nmi === 1'b0, "NMI released with the flag");

		while (!(scanline == 9'd261 && cycle == 9'd2)) begin @(posedge clk); #1; end
		rd(3'd2);
		check(rdval[7] == 1'b0, "VBlank clear on the pre-render line");

		// --- the write toggle -----------------------------------------------
		$display(" $2005/$2006 share one toggle:");
		rd(3'd2);                              // clears w
		wr(3'd6, 8'h21);                       // first  $2006 write -> t high
		wr(3'd6, 8'h08);                       // second $2006 write -> v
		check(dut.v == 15'h2108, "two $2006 writes load v");
		check(dut.w == 1'b0, "toggle back to first-write state");

		rd(3'd2);
		wr(3'd6, 8'h21);                       // leave the toggle half-set
		rd(3'd2);                              // reading $2002 must reset it
		check(dut.w == 1'b0, "reading $2002 clears a half-finished write");

		rd(3'd2);
		wr(3'd5, 8'h7D);                       // fine X = 5, coarse X = 15
		check(dut.x == 3'd5, "$2005 first write sets fine X");
		check(dut.t[4:0] == 5'd15, "$2005 first write sets coarse X");
		wr(3'd5, 8'h5E);                       // fine Y = 6, coarse Y = 11
		check(dut.t[14:12] == 3'd6, "$2005 second write sets fine Y");
		check(dut.t[9:5] == 5'd11, "$2005 second write sets coarse Y");

		// --- $2007 auto-increment --------------------------------------------
		$display(" $2007 increment:");
		wr(3'd0, 8'h00);                       // increment by 1
		rd(3'd2);
		wr(3'd6, 8'h20); wr(3'd6, 8'h00);
		rd(3'd7);
		check(dut.v == 15'h2001, "increments by 1 when CTRL bit 2 is clear");
		wr(3'd0, 8'h04);                       // increment by 32
		rd(3'd7);
		check(dut.v == 15'h2021, "increments by 32 when CTRL bit 2 is set");

		// --- OAM ---------------------------------------------------------------
		$display(" OAM:");
		wr(3'd3, 8'h10);
		wr(3'd4, 8'hA5);
		check(dut.oam[8'h10] == 8'hA5, "$2004 writes OAM at OAMADDR");
		check(dut.oam_addr == 8'h11, "OAMADDR auto-increments");
		wr(3'd3, 8'h10);
		rd(3'd4);
		check(rdval == 8'hA5, "$2004 reads it back");


		// --- sprites ------------------------------------------------------------
		// Everything above this point passes with the sprite unit ripped out, which
		// is exactly how a console that renders a still background and then freezes
		// gets shipped. This section draws one.
		$display(" sprites:");
		wr(3'd1, 8'h00);                        // rendering off while we set up

		// Tile 0 blank, tile 1 solid colour 1. Nametables all tile 0, so the
		// background is transparent everywhere and a sprite pixel is unambiguous.
		for (k = 0; k < 16; k = k + 1)   vram[k] = 8'h00;
		for (k = 16; k < 24; k = k + 1)  vram[k] = 8'hFF;   // tile 1, low plane
		for (k = 24; k < 32; k = k + 1)  vram[k] = 8'h00;   // tile 1, high plane
		for (k = 16'h2000; k < 16'h3000; k = k + 1) vram[k] = 8'h00;

		rd(3'd2);
		wr(3'd6, 8'h3F); wr(3'd6, 8'h00); wr(3'd7, 8'h0F);  // backdrop
		rd(3'd2);
		wr(3'd6, 8'h3F); wr(3'd6, 8'h11); wr(3'd7, 8'h16);  // sprite palette 0, colour 1

		// Sprite 0 at Y=50, X=100. Every other sprite parked off-screen.
		wr(3'd3, 8'h00);
		wr(3'd4, 8'd50); wr(3'd4, 8'd1); wr(3'd4, 8'h00); wr(3'd4, 8'd100);
		for (k = 4; k < 256; k = k + 1) wr(3'd4, 8'hFF);

		rd(3'd2);
		wr(3'd6, 8'h00); wr(3'd6, 8'h00);       // park v outside the palette
		wr(3'd0, 8'h00);                        // 8x8, sprite table 0, NMI off
		wr(3'd1, 8'h1E);                        // background + sprites, including the left column

		// OAM Y is stored one less than the line the sprite appears on, so a
		// sprite at Y=50 occupies lines 51..58 and nothing on line 50.
		at(9'd50, 9'd120);
		check(dut.spr_n == 4'd0, "no sprite on the line above it (Y=50 -> starts at 51)");

		at(9'd51, 9'd120);
		check(dut.spr_n == 4'd1, "one sprite found on its first line");

		at(9'd51, 9'd100);
		check(pixel == 6'h0F, "backdrop just left of the sprite (x=99)");
		at(9'd51, 9'd101);
		check(pixel == 6'h16, "sprite's first pixel is at x=100");
		at(9'd51, 9'd108);
		check(pixel == 6'h16, "sprite's last pixel is at x=107");
		at(9'd51, 9'd109);
		check(pixel == 6'h0F, "backdrop again at x=108");

		at(9'd58, 9'd104);
		check(pixel == 6'h16, "still drawn on its last line (58)");
		at(9'd59, 9'd120);
		check(dut.spr_n == 4'd0, "gone on line 59");

		// --- sprite 0 hit ---------------------------------------------------------
		// This is the one Super Mario Bros waits on to split its status bar. With
		// no sprites there is no hit, and the game sits in its polling loop forever
		// looking exactly like a crashed CPU.
		$display(" sprite 0 hit:");
		wr(3'd1, 8'h00);
		for (k = 0; k < 8; k = k + 1) vram[k] = 8'hFF;      // tile 0 now opaque
		wr(3'd1, 8'h1E);

		// Clear the flag, then let the sprite cross the background.
		at(9'd261, 9'd10);
		rd(3'd2);
		at(9'd40, 9'd10);
		rd(3'd2);
		check(rdval[6] == 1'b0, "clear before the sprite's line");

		at(9'd51, 9'd200);
		rd(3'd2);
		check(rdval[6] == 1'b1, "set once sprite 0 overlaps opaque background");

		// And it must NOT fire when the background is switched off underneath it.
		wr(3'd1, 8'h14);                        // sprites on, background off
		at(9'd261, 9'd10);
		rd(3'd2);                               // clears the flag for the new frame
		at(9'd51, 9'd200);
		rd(3'd2);
		check(rdval[6] == 1'b0, "no hit while the background layer is off");
		wr(3'd1, 8'h1E);

		$display("");

		// --- the odd-frame short line ------------------------------------------
		$display(" odd-frame dot skip:");
		wr(3'd1, 8'h18);                        // rendering on
		// Measure two consecutive frames; with rendering enabled one of them is
		// a dot shorter than the other.
		@(posedge clk); #1;
		while (!frame_start) begin @(posedge clk); #1; end
		f_even = 0;
		@(posedge clk); #1; f_even = f_even + 1;
		while (!frame_start) begin @(posedge clk); #1; f_even = f_even + 1; end
		f_odd = 0;
		@(posedge clk); #1; f_odd = f_odd + 1;
		while (!frame_start) begin @(posedge clk); #1; f_odd = f_odd + 1; end
		$display("       consecutive frames: %0d and %0d dots", f_even, f_odd);
		check((f_even == 341*262 && f_odd == 341*262 - 1) ||
		      (f_odd == 341*262 && f_even == 341*262 - 1),
		      "one frame of the pair is one dot short");

		$display("");
		if (errors == 0) $display("tb_ppu: all checks passed");
		else             $display("tb_ppu: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		#40_000_000;
		$display("FAIL timeout");
		$finish;
	end

endmodule
