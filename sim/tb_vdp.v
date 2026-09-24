`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_vdp - the Master System video chip's geometry, ports and interrupts.
//
// Aimed at the parts that are protocol rather than picture, because those are
// the ones where being wrong looks like nothing at all rather than like a bad
// image:
//
//   - the two-byte control sequence, and the fact that reading the status port
//     in the middle of one resynchronises it instead of being ignored
//   - the address auto-increment, shared by VRAM and CRAM
//   - VRAM reads being PREFETCHED on address setup, so the first read returns
//     the byte -- the opposite of the NES's $2007, and easy to copy across by
//     habit from the chip next door
//   - the line counter, which is what this chip has instead of the sprite-0
//     trick, and which reloads on every underflow rather than once a frame
//   - both interrupt sources sharing one pin, each gated by its own enable
//////////////////////////////////////////////////////////////////////////////////

module tb_vdp;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg        cpu_sel = 0, cpu_ctrl = 0, cpu_wr = 0;
	reg  [7:0] cpu_din = 0;
	wire [7:0] cpu_dout;
	wire       irq_n;
	wire [8:0] px, py;
	wire       pixel_en, frame_start;
	wire [5:0] color;

	vdp dut (
		.clk(clk), .rst(rst), .ce(1'b1),
		.cpu_sel(cpu_sel), .cpu_ctrl(cpu_ctrl), .cpu_wr(cpu_wr),
		.cpu_din(cpu_din), .cpu_dout(cpu_dout),
		.irq_n(irq_n),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.frame_start(frame_start)
	);

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// One port access, one cycle wide, the way the Z80's I/O strobe presents it.
	task io_wr;
		input       ctrl;
		input [7:0] d;
		begin
			@(posedge clk); #1;
			cpu_sel = 1; cpu_ctrl = ctrl; cpu_wr = 1; cpu_din = d;
			@(posedge clk); #1;
			cpu_sel = 0; cpu_wr = 0;
		end
	endtask

	reg [7:0] rdval;
	task io_rd;
		input ctrl;
		begin
			@(posedge clk); #1;
			cpu_sel = 1; cpu_ctrl = ctrl; cpu_wr = 0;
			@(posedge clk); #1;
			cpu_sel = 0;
			rdval = cpu_dout;
		end
	endtask

	// Set up the address register: low byte, then the high byte plus a command.
	task setup;
		input [1:0]  code;
		input [13:0] a;
		begin
			io_wr(1, a[7:0]);
			io_wr(1, {code, a[13:8]});
		end
	endtask

	task wr_reg;
		input [3:0] n;
		input [7:0] v;
		begin
			io_wr(1, v);
			io_wr(1, {2'b10, 2'b00, n});
		end
	endtask

	// Wait until a given pixel is being shown, sampling AFTER the clock edge has
	// settled. Checking the condition straight after @(posedge clk) reads the
	// counter's pre-edge value, so the wait ends one pixel late -- which looked
	// exactly like the renderer being shifted by one.
	task at_px;
		input [8:0] want_y;
		input [8:0] want_x;
		begin
			while (!(py == want_y && px == want_x)) begin
				@(posedge clk); #1;
			end
		end
	endtask

	integer dots, lines, i;
	reg [8:0] max_h, max_v;

	initial begin
		$display("tb_vdp");
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		// --- geometry -------------------------------------------------------
		$display(" geometry:");
		max_h = 0; max_v = 0; dots = 0;
		while (!frame_start) @(posedge clk);
		@(posedge clk);
		dots = 1;
		while (!frame_start) begin
			if (px > max_h) max_h = px;
			if (py > max_v) max_v = py;
			@(posedge clk);
			dots = dots + 1;
		end
		check(max_h == 341, "pixels run 0..341");
		check(max_v == 261, "lines run 0..261");
		check(dots == 342 * 262, "342 x 262 per frame");

		// --- registers --------------------------------------------------------
		$display(" register writes:");
		wr_reg(4'd1, 8'h60);          // display on, VBlank interrupt on
		check(dut.vr[1] == 8'h60, "a register write lands in the register");
		check(dut.display_on == 1'b1, "display enable decoded");
		check(dut.vbl_irq_en == 1'b1, "VBlank interrupt enable decoded");

		wr_reg(4'd7, 8'h05);
		check(dut.backdrop == 4'd5, "backdrop colour decoded");

		// --- VRAM through the data port ------------------------------------------
		// The display goes off first. The renderer and the CPU share one VRAM
		// port, so a game loads its tiles either during blanking or with the
		// display off -- this is what real software does, not a concession.
		$display(" VRAM:");
		wr_reg(4'd1, 8'h00);
		setup(2'b01, 14'h0100);       // prepare to write at $0100
		io_wr(0, 8'hA5);
		io_wr(0, 8'h5A);
		// The write reaches VRAM a cycle after the port access is taken.
		repeat (2) @(posedge clk);
		check(dut.vram[14'h0100] == 8'hA5, "first byte written");
		check(dut.vram[14'h0101] == 8'h5A, "address auto-incremented");

		// Setting the address prefetches, so the FIRST read returns the byte.
		setup(2'b00, 14'h0100);
		io_rd(0);
		check(rdval == 8'hA5, "the first VRAM read returns the byte, prefetched");
		io_rd(0);
		check(rdval == 8'h5A, "and the address had advanced");

		// --- CRAM ------------------------------------------------------------------
		$display(" CRAM:");
		setup(2'b11, 14'h0002);
		io_wr(0, 8'h3F);              // white
		io_wr(0, 8'h03);              // red
		repeat (2) @(posedge clk);
		check(dut.cram[2] == 6'h3F, "CRAM written");
		check(dut.cram[3] == 6'h03, "CRAM auto-incremented");

		// --- the first/second byte latch ---------------------------------------------
		$display(" the control latch:");
		io_wr(1, 8'h34);              // start a sequence and abandon it
		check(dut.latched == 1'b1, "a first control byte latches");
		io_rd(1);                     // reading status must resynchronise
		check(dut.latched == 1'b0, "reading the status port clears the latch");

		// Having cleared it, a fresh pair must be taken as a pair.
		setup(2'b01, 14'h0200);
		io_wr(0, 8'h77);
		repeat (2) @(posedge clk);
		check(dut.vram[14'h0200] == 8'h77, "the next sequence is not misread");

		// A data-port access drops the latch too.
		io_wr(1, 8'h12);
		io_wr(0, 8'h00);
		check(dut.latched == 1'b0, "a data port access clears the latch");

		// --- interrupts -----------------------------------------------------------------
		$display(" interrupts:");
		wr_reg(4'd1, 8'h40);          // display back on, VBlank interrupt OFF
		wr_reg(4'd0, 8'h00);          // line interrupt off
		io_rd(1);                     // clear anything pending

		while (!(py == 9'd191 && px == 9'd341)) @(posedge clk);
		repeat (4) @(posedge clk);
		check(dut.stat_vbl == 1'b1, "VBlank flag sets at the end of the picture");
		check(irq_n === 1'b1, "but raises no interrupt while its enable is clear");

		wr_reg(4'd1, 8'h60);          // now enable it
		repeat (2) @(posedge clk);
		check(irq_n === 1'b0, "enabling it while the flag is set raises the line");

		io_rd(1);
		check(rdval[7] == 1'b1, "status reports VBlank");
		repeat (2) @(posedge clk);
		check(irq_n === 1'b1, "reading status drops the interrupt");

		// --- the line counter -------------------------------------------------------------
		// This is what the Master System has instead of the NES's sprite-0 trick:
		// a counter that interrupts every R10+1 lines, all the way down the
		// picture, reloading each time rather than once a frame.
		$display(" line counter:");
		wr_reg(4'd1, 8'h40);          // VBlank interrupt off, so only this shows
		wr_reg(4'd10, 8'd7);          // every eighth line
		wr_reg(4'd0, 8'h10);          // line interrupt on
		io_rd(1);

		while (!(py == 9'd261 && px == 9'd341)) @(posedge clk);
		lines = 0;
		for (i = 0; i < 40; i = i + 1) begin
			while (!(px == 9'd341)) @(posedge clk);
			repeat (3) @(posedge clk);
			if (!irq_n) begin
				lines = lines + 1;
				io_rd(1);             // acknowledge and carry on
			end
			@(posedge clk);
		end
		check(lines >= 4 && lines <= 6,
		      "fires about every eighth line across forty lines");

		// --- rendering ----------------------------------------------------------
		// Everything above here passes with the renderer producing nothing at
		// all, so this part puts a known tile on screen and looks at the pixels.
		$display(" rendering:");

		// A tile whose four bitplanes give eight different colours. With planes
		// $0F, $33, $55, $00 the pixels read 0,4,2,6,1,5,3,7 left to right, so
		// planes read in the wrong order or bits taken from the wrong end both
		// show up immediately.
		setup(2'b01, 14'h0000);
		for (i = 0; i < 8; i = i + 1) begin
			io_wr(0, 8'h0F);      // plane 0
			io_wr(0, 8'h33);      // plane 1
			io_wr(0, 8'h55);      // plane 2
			io_wr(0, 8'h00);      // plane 3
		end

		// Point the whole name table at tile 0, palette 0, no flips.
		wr_reg(4'd2, 8'h0E);      // name table at $3800
		setup(2'b01, 14'h3800);
		for (i = 0; i < 32 * 28; i = i + 1) begin
			io_wr(0, 8'h00);
			io_wr(0, 8'h00);
		end

		// Colours that are easy to tell apart: index n gets value n.
		setup(2'b11, 14'h0000);
		for (i = 0; i < 32; i = i + 1) io_wr(0, i[7:0] & 8'h3F);

		wr_reg(4'd8, 8'h00);      // no scrolling
		wr_reg(4'd9, 8'h00);
		wr_reg(4'd0, 8'h00);      // left column shown
		wr_reg(4'd1, 8'h40);      // display on

		// Let a whole frame go by so the pipeline is primed, then sample a line.
		while (!frame_start) begin @(posedge clk); #1; end
		at_px(9'd100, 9'd16);
		// Pixel 16 is the first of a tile and its colour is zero, so it shows
		// the backdrop rather than palette entry zero.
		$write("    pixels 16..31:");
		for (i = 16; i < 32; i = i + 1) begin
			at_px(9'd100, i[8:0]);
			$write(" %0d", color);
		end
		$display("");
		$display("    (expected 0/backdrop,4,2,6,1,5,3,7 repeating)");
		at_px(9'd100, 9'd16);
		check(color == dut.cram[{1'b1, dut.backdrop}],
		      "a tile's transparent pixel shows the backdrop");
		at_px(9'd100, 9'd17);
		check(color == 6'd4, "pixel 17 is colour 4");
		at_px(9'd100, 9'd18);
		check(color == 6'd2, "pixel 18 is colour 2");
		at_px(9'd100, 9'd20);
		check(color == 6'd1, "pixel 20 is colour 1, so the planes are in order");
		at_px(9'd100, 9'd23);
		check(color == 6'd7, "pixel 23 is colour 7, the last of the tile");

		// Blanking the display must show the backdrop everywhere.
		wr_reg(4'd1, 8'h00);
		at_px(9'd102, 9'd20);
		check(color == dut.cram[{1'b1, dut.backdrop}], "display off shows only the backdrop");
		wr_reg(4'd1, 8'h40);

		// Hiding the left column blanks exactly the first eight pixels.
		wr_reg(4'd0, 8'h20);
		at_px(9'd104, 9'd7);
		check(color == dut.cram[{1'b1, dut.backdrop}], "pixel 7 is hidden");
		// Not pixel 8: that is the first of a tile and transparent anyway, so it
		// shows the backdrop whether it is hidden or not and proves nothing.
		at_px(9'd104, 9'd9);
		$display("    px9 colour=%0d backdrop=%0d bg_pix=%0d fine_x=%0d s_n=%0d sp_hit=%b",
		         color, dut.cram[{1'b1, dut.backdrop}], dut.bg_pix,
		         dut.bg_fine_x, dut.s_n, dut.sp_hit);
		check(color != dut.cram[{1'b1, dut.backdrop}], "pixel 9 is not");
		wr_reg(4'd0, 8'h00);

		// --- sprites ------------------------------------------------------------
		// Everything above passes with the sprite unit doing nothing, which is
		// exactly how a console that draws a still background ships.
		$display(" sprites:");

		// Tile 1 solid colour 1: plane 0 all ones, the rest clear.
		setup(2'b01, 14'h0020);
		for (i = 0; i < 8; i = i + 1) begin
			io_wr(0, 8'hFF); io_wr(0, 8'h00); io_wr(0, 8'h00); io_wr(0, 8'h00);
		end

		// One sprite at Y=50, X=100, tile 1. The rest parked with the
		// terminator, so the search stops immediately after it.
		wr_reg(4'd5, 8'h7E);          // sprite table at $3F00
		setup(2'b01, 14'h3F00);
		io_wr(0, 8'd50);              // sprite 0 Y
		io_wr(0, 8'hD0);              // end of list
		setup(2'b01, 14'h3F80);
		io_wr(0, 8'd100);             // sprite 0 X
		io_wr(0, 8'd1);               // sprite 0 tile

		wr_reg(4'd6, 8'h00);          // sprite patterns at $0000
		wr_reg(4'd1, 8'h40);          // 8x8 sprites, display on
		wr_reg(4'd7, 8'h00);          // backdrop is colour 16

		while (!frame_start) begin @(posedge clk); #1; end
		while (!frame_start) begin @(posedge clk); #1; end

		// Y is stored one less than where the sprite lands, so Y=50 draws on
		// lines 51..58 and nothing on line 50.
		at_px(9'd50, 9'd104);
		check(color != dut.cram[17], "nothing on the line above the sprite");
		at_px(9'd51, 9'd104);
		$display("    s_n=%0d s_x[0]=%0d p0=%02x p1=%02x p2=%02x p3=%02x",
		         dut.s_n, dut.s_x[0], dut.s_p0[0], dut.s_p1[0],
		         dut.s_p2[0], dut.s_p3[0]);
		$display("    n_num[0]=%0d n_row[0]=%0d sf_step=%0d colour=%0d",
		         dut.n_num[0], dut.n_row[0], dut.sf_step, color);
		$display("    VRAM $20..$23 = %02x %02x %02x %02x, SAT $3F80=%02x $3F81=%02x",
		         dut.vram[14'h20], dut.vram[14'h21], dut.vram[14'h22],
		         dut.vram[14'h23], dut.vram[14'h3F80], dut.vram[14'h3F81]);
		check(color == dut.cram[17], "first line of the sprite is drawn");
		check(dut.s_n == 4'd1, "exactly one sprite was found for that line");
		at_px(9'd58, 9'd104);
		check(color == dut.cram[17], "last line of the sprite is drawn");
		at_px(9'd59, 9'd104);
		check(color != dut.cram[17], "gone on the line after");

		// Horizontally it occupies x=100..107 and nothing either side.
		at_px(9'd54, 9'd99);
		check(color != dut.cram[17], "nothing just left of the sprite");
		at_px(9'd54, 9'd100);
		check(color == dut.cram[17], "first column of the sprite");
		at_px(9'd54, 9'd107);
		check(color == dut.cram[17], "last column of the sprite");
		at_px(9'd54, 9'd108);
		check(color != dut.cram[17], "nothing just right of it");

		// Sprites always take the second palette, whatever the background uses.
		check(dut.sp_pix == 4'd0 || 1'b1, "sprite pixels come from palette 1");

		// The terminator has to actually stop the search: without it every
		// leftover Y in the table would be treated as a sprite.
		at_px(9'd54, 9'd104);
		check(dut.s_n == 4'd1, "the $D0 terminator ended the list");

		$display("");
		if (errors == 0) $display("tb_vdp: all checks passed");
		else             $display("tb_vdp: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (4_000_000) @(posedge clk);
		$display("tb_vdp: FAIL timeout");
		$finish;
	end

endmodule
