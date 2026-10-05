`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_md_vdp - the Mega Drive VDP's front door.
//
// Before anything is drawn, a game spends its first few thousand cycles doing
// nothing but talking to this port: setting registers, then walking VRAM, CRAM
// and VSRAM through a two-word command whose bits are scattered across both
// halves. If that is wrong, nothing that comes later can be debugged, because
// every symptom looks like a rendering bug.
//
// So this checks the protocol on its own, and checks the parts of it that only
// go wrong at the edges: the upper address bits that live in the second word,
// the byte swap on an odd VRAM address, and the status read that abandons a
// half-written command.
//////////////////////////////////////////////////////////////////////////////////

module tb_md_vdp;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One enable in two. The real chip has a pixel clock slower than anything it
	// is built out of, and a renderer that only works when every clock is a pixel
	// is a renderer that works in exactly one testbench.
	reg ph = 0;
	always @(posedge clk) ph <= ~ph;
	wire ce = ph;

	reg         cpu_sel = 0, cpu_ctrl = 0, cpu_wr = 0;
	reg  [15:0] cpu_din = 0;
	wire [15:0] cpu_dout;
	wire [7:0]  dbg_reg0;
	wire [16:0] dbg_addr;
	wire [5:0]  dbg_code;
	wire        dbg_pending;

	wire [2:0] ipl_n;
	reg        int_ack = 0;

	// The 68000's memory, as far as a DMA is concerned: three words and a
	// responder that answers a request on the cycle after it sees one.
	wire        dma_req;
	wire [22:0] dma_addr;
	reg  [15:0] dma_din = 0;
	reg         dma_ack = 0;
	reg  [15:0] dma_mem [0:7];
	always @(posedge clk) begin
		if (dma_req && !dma_ack) begin
			dma_din <= dma_mem[dma_addr[2:0]];
			dma_ack <= 1'b1;
		end else
			dma_ack <= 1'b0;
	end
	wire [9:0] px, py;
	wire       pixel_en;
	wire [5:0] color_ix;
	wire [8:0] color;

	md_vdp dut (
		.clk(clk), .rst(rst), .ce(ce),
		.ipl_n(ipl_n), .int_ack(int_ack),
		.dma_req(dma_req), .dma_addr(dma_addr),
		.dma_din(dma_din), .dma_ack(dma_ack),
		.cpu_sel(cpu_sel), .cpu_ctrl(cpu_ctrl), .cpu_wr(cpu_wr),
		.cpu_din(cpu_din), .cpu_dout(cpu_dout),
		.px(px), .py(py), .pixel_en(pixel_en),
		.color_ix(color_ix), .color(color),
		.dbg_reg0(dbg_reg0), .dbg_addr(dbg_addr), .dbg_code(dbg_code),
		.dbg_pending(dbg_pending)
	);

	integer errors = 0;

	task check;
		input condition;
		input [1023:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin
				$display("  FAIL %0s", what);
				errors = errors + 1;
			end
		end
	endtask

	task expect16;
		input [1023:0] what;
		input [15:0]  got;
		input [15:0]  want;
		begin
			if (got === want) $display("  ok   %0s = %04x", what, got);
			else begin
				$display("  FAIL %0s = %04x, wanted %04x", what, got, want);
				errors = errors + 1;
			end
		end
	endtask

	// --- the bus, as the 68000 drives it -------------------------------------------
	task wr;
		input       ctrl;
		input [15:0] d;
		begin
			@(negedge clk);
			cpu_sel = 1; cpu_ctrl = ctrl; cpu_wr = 1; cpu_din = d;
			@(negedge clk);
			cpu_sel = 0; cpu_wr = 0;
		end
	endtask

	task rd;
		input ctrl;
		begin
			@(negedge clk);
			cpu_sel = 1; cpu_ctrl = ctrl; cpu_wr = 0;
			@(negedge clk);
			cpu_sel = 0;
			// The chip answers in the same cycle it was selected, so the value
			// is on cpu_dout by the time this returns.
			@(negedge clk);
		end
	endtask

	// A register write: one word, top two bits 10.
	task setreg;
		input [4:0] n;
		input [7:0] v;
		begin wr(1, {3'b100, n, v}); end
	endtask

	// The two-word command. Note where each half of the address goes: this task
	// existing at all is the point, because writing it out by hand at every call
	// site is how the upper bits end up in the wrong word.
	task command;
		input [5:0]  cd;
		input [16:0] a;
		begin
			wr(1, {cd[1:0], a[13:0]});
			wr(1, {8'd0, cd[5:2], 1'b0, a[16:14]});
		end
	endtask

	localparam CD_VRAM_RD  = 6'b000000,
	           CD_VRAM_WR  = 6'b000001,
	           CD_CRAM_WR  = 6'b000011,
	           CD_VSRAM_RD = 6'b000100,
	           CD_VSRAM_WR = 6'b000101,
	           CD_CRAM_RD  = 6'b001000;

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		@(posedge clk);

		$display("tb_md_vdp");
		$display(" registers:");
		setreg(5'd0, 8'h04);
		expect16("register 0", {8'd0, dbg_reg0}, 16'h0004);
		setreg(5'd15, 8'h20);
		check(dut.r[15] === 8'h20, "register 15, the auto-increment");
		// A register write must not leave a command half-started, or the next
		// control write is read as the second half of something.
		check(dbg_pending === 1'b0, "a register write starts no command");

		$display(" the two-word command:");
		// $1F000 needs bits that only exist in the second word. An address that
		// fits in fourteen bits proves nothing here.
		command(CD_VRAM_WR, 17'h1F002);
		expect16("address low half",  {15'd0, dbg_addr[1:0]}, 16'd2);
		check(dbg_addr === 17'h1F002, "the whole 17-bit address arrived");
		check(dbg_code === CD_VRAM_WR, "and so did the 6-bit code");
		check(dbg_pending === 1'b0, "the command is complete");

		$display(" VRAM:");
		setreg(5'd15, 8'd2);
		command(CD_VRAM_WR, 17'h0100);
		wr(0, 16'hCAFE);
		wr(0, 16'hBEEF);
		check(dut.vram[15'h0080] === 16'hCAFE, "the first word landed at $0100");
		check(dut.vram[15'h0081] === 16'hBEEF, "and the second at $0102");
		check(dbg_addr === 17'h0104, "the address stepped by two, twice");

		// An odd address swaps the bytes on the way in. This is not a curiosity:
		// it is how a byte written to an odd address ends up in the right half.
		command(CD_VRAM_WR, 17'h0201);
		wr(0, 16'h1234);
		check(dut.vram[15'h0100] === 16'h3412,
		      "an odd VRAM address swaps the bytes");

		setreg(5'd15, 8'd4);
		command(CD_VRAM_WR, 17'h0300);
		wr(0, 16'h1111);
		wr(0, 16'h2222);
		check(dut.vram[15'h0180] === 16'h1111 && dut.vram[15'h0182] === 16'h2222,
		      "an auto-increment of four leaves a gap");

		command(CD_VRAM_RD, 17'h0100);
		rd(0);
		expect16("reading back what was written", cpu_dout, 16'hCAFE);

		$display(" CRAM:");
		setreg(5'd15, 8'd2);
		command(CD_CRAM_WR, 17'h0000);
		// 0000 BBB0 GGG0 RRR0 -- blue 7, green 0, red 7.
		wr(0, 16'h0E0E);
		check(dut.cram[0] === 9'b111_000_111, "a colour packs down to nine bits");
		command(CD_CRAM_RD, 17'h0000);
		rd(0);
		// It comes back in the same shape, with the gaps read as zero.
		expect16("and comes back out spread apart again", cpu_dout, 16'h0E0E);

		$display(" VSRAM:");
		command(CD_VSRAM_WR, 17'h0004);
		wr(0, 16'h07FF);
		check(dut.vsram[2] === 11'h7FF, "eleven bits of vertical scroll");
		command(CD_VSRAM_RD, 17'h0004);
		rd(0);
		expect16("read back", cpu_dout, 16'h07FF);

		$display(" the status read:");
		// Half a command, then a status read, then the other half. The second
		// half must be treated as a FIRST half -- this is what makes a status
		// read in the wrong place resynchronise rather than corrupt.
		wr(1, {CD_VRAM_WR[1:0], 14'h1234});
		check(dbg_pending === 1'b1, "the first word is pending");
		rd(1);
		expect16("the status word", cpu_dout, 16'h3600);
		check(dbg_pending === 1'b0, "reading the status abandoned it");
		wr(1, 16'h4000);
		check(dbg_addr[13:0] === 14'h0000 && dbg_pending === 1'b1,
		      "the next write started a new command rather than finishing the old");

		// A data-port access also clears it, for the same reason.
		rd(1);
		wr(1, {CD_VRAM_WR[1:0], 14'h0010});
		check(dbg_pending === 1'b1, "pending again");
		wr(0, 16'h0000);
		check(dbg_pending === 1'b0, "a data write abandons a half-written command");

		// ==================================================================
		// Rendering.
		//
		// The picture is built out of things whose every pixel is known: one
		// tile that is a diagonal line of colour 1 on a transparent field, and
		// another that is solid colour 2. Then the checks are about WHERE those
		// pixels come out, which is the part that goes wrong -- a plane fetched
		// one cell early, a row taken from the wrong half of a pattern, a flip
		// that reverses the wrong eight pixels.
		// ==================================================================
		setup_picture;

		$display(" timing:");
		wait_pixel(10'd0, 10'd0);
		check(pixel_en === 1'b1, "the top left corner is inside the picture");
		wait_pixel(10'd319, 10'd0);
		check(pixel_en === 1'b1, "and so is the last pixel of the line");
		wait_pixel(10'd320, 10'd0);
		check(pixel_en === 1'b0, "one further along is not");

		$display(" plane B:");
		// Tile 1 is a diagonal: pixel n of row n is colour 1, everything else 0.
		// So cell (0,0) of the plane has a lit pixel at (0,0) and at (3,3), and
		// dark ones either side of them.
		expect_pixel(10'd0, 10'd0, 6'h01, "the diagonal's first pixel");
		expect_pixel(10'd1, 10'd0, 6'h00, "next to it, transparent, so backdrop");
		expect_pixel(10'd3, 10'd3, 6'h01, "and the diagonal four rows down");
		expect_pixel(10'd4, 10'd3, 6'h00, "past it on the same row");

		// The second cell along holds the same tile FLIPPED horizontally, so the
		// diagonal runs the other way: lit at x=15 on row 0, not at x=8.
		expect_pixel(10'd15, 10'd0, 6'h01, "a flipped cell mirrors the row");
		expect_pixel(10'd8,  10'd0, 6'h00, "and is dark where the unflipped one lit");

		// The third holds it flipped vertically: row 0 shows what row 7 had, so
		// the lit pixel is at x=23 rather than x=16.
		expect_pixel(10'd23, 10'd0, 6'h01, "a vertically flipped cell shows row 7");
		expect_pixel(10'd16, 10'd0, 6'h00, "not row 0");

		$display(" palettes and priority:");
		// The fourth cell is the solid tile in palette 2, so every pixel of it is
		// entry $22 -- palette 2, colour 2.
		expect_pixel(10'd25, 10'd0, 6'h22, "palette 2 shifts the whole cell");

		// Plane A is in front where both are opaque...
		expect_pixel(10'd40, 10'd0, 6'h12, "plane A covers plane B");
		// ...but a high-priority cell of B beats a low-priority cell of A, which
		// is the whole point of the priority bit and the thing a plane-ordering
		// renderer gets wrong.
		expect_pixel(10'd48, 10'd0, 6'h32, "a high-priority B cell beats a low-priority A");

		$display(" scrolling:");
		// Plane B scrolled right by three: what was at x=0 is now at x=3.
		set_hscroll_b(10'd3);
		expect_pixel(10'd3, 10'd0, 6'h01, "the diagonal moved right by three");
		expect_pixel(10'd0, 10'd0, 6'h00, "and left transparent behind it");
		set_hscroll_b(10'd0);

		// Vertical scroll of one line: row 0 now shows what row 1 had, so the
		// diagonal's lit pixel moves from x=0 to x=1.
		set_vscroll_b(11'd1);
		expect_pixel(10'd1, 10'd0, 6'h01, "a vertical scroll of one line");
		set_vscroll_b(11'd0);

		// ==================================================================
		// Interrupts.
		// ==================================================================
		$display(" interrupts:");
		setreg(5'd1, 8'h64);                    // display on, VBlank enabled
		setreg(5'd0, 8'h04);                    // line interrupt off for now

		// A flag set on an earlier frame stays set until something clears it,
		// which is correct and is also why this has to start from a clean slate
		// rather than from whatever the rendering tests left behind.
		wait_pixel(10'd0, 10'd100);
		rd(1);
		check(ipl_n === 3'b111, "nothing pending in the middle of the picture");
		// ...and the VBlank one arrives as the last line of it ends.
		wait_pixel(10'd0, 10'd224);
		check(ipl_n === 3'b001, "VBlank asks for level 6");
		rd(1);
		check(cpu_dout[3] === 1'b1, "and the status says the beam is in VBlank");
		check(ipl_n === 3'b111, "reading the status cleared it");

		// With the enable off the flag still sets, because a game that polls
		// instead of using interrupts has nothing else to look at.
		setreg(5'd1, 8'h44);
		wait_pixel(10'd0, 10'd224);
		check(ipl_n === 3'b111, "disabled, so nothing is asked for");
		rd(1);
		check(cpu_dout[7] === 1'b1, "but the status bit is set anyway");

		// The line counter: a register of 0 fires on every line, so it is
		// pending again almost immediately after being acknowledged.
		setreg(5'd1, 8'h44);
		setreg(5'd10, 8'd0);
		setreg(5'd0, 8'h14);                    // line interrupt on
		wait_pixel(10'd0, 10'd10);
		check(ipl_n === 3'b011, "the line counter asks for level 4");
		ack;
		check(ipl_n === 3'b111, "acknowledging cleared it");

		// A register of 3 fires every fourth line, so one line later it is
		// still quiet.
		setreg(5'd10, 8'd3);
		wait_pixel(10'd0, 10'd240);             // let it reload in the blanking
		ack;                                    // and clear what the last count left
		wait_pixel(10'd0, 10'd1);
		check(ipl_n === 3'b111, "a count of three does not fire on the first line");
		wait_pixel(10'd0, 10'd4);
		check(ipl_n === 3'b011, "but does on the fourth");
		ack;
		setreg(5'd0, 8'h04);

		// ==================================================================
		// DMA.
		//
		// Each of the three kinds is checked on what it does to the bytes AROUND
		// the ones it should touch, as well as to those. A fill and a copy both
		// move single bytes to addresses that may be odd, and the way they go
		// wrong is by taking the neighbouring byte with them.
		// ==================================================================
		$display(" DMA:");
		setreg(5'd1,  8'h54);                   // display on, DMA allowed
		setreg(5'd15, 8'd1);                    // step one byte at a time

		// Something recognisable to overwrite, so an untouched byte is visible.
		command(CD_VRAM_WR, 17'h1000);
		setreg(5'd15, 8'd2);
		wr(0, 16'h1111);
		wr(0, 16'h1111);
		wr(0, 16'h1111);
		setreg(5'd15, 8'd1);

		// A fill of four bytes, on top of the ordinary write that carries the
		// value in. The value's HIGH byte is what gets repeated.
		setreg(5'd19, 8'd4);
		setreg(5'd20, 8'd0);
		setreg(5'd23, 8'h80);                   // mode 10: fill
		command(6'b100001, 17'h1000);           // CD5 set, VRAM write
		wr(0, 16'hAB00);
		wait_dma;
		check(dut.vram[15'h0800] === 16'hABAB,
		      "the first word: the ordinary write, then the fill's first byte");
		check(dut.vram[15'h0801] === 16'hABAB, "the second, both bytes filled");
		// The fourth byte lands in the high half and must leave the low half be.
		check(dut.vram[15'h0802] === 16'hAB11,
		      "and the last byte left its neighbour alone");

		// A copy, from an even source to an ODD destination, which is where the
		// byte lanes have to cross over.
		setreg(5'd15, 8'd2);
		command(CD_VRAM_WR, 17'h3000);
		wr(0, 16'h1234);
		wr(0, 16'h5678);
		command(CD_VRAM_WR, 17'h2000);
		wr(0, 16'h9999);
		wr(0, 16'h9999);
		setreg(5'd15, 8'd1);

		setreg(5'd19, 8'd3);
		setreg(5'd20, 8'd0);
		setreg(5'd21, 8'h00);                   // source byte address $3000
		setreg(5'd22, 8'h30);
		setreg(5'd23, 8'hC0);                   // mode 11: VRAM to VRAM
		command(6'b100001, 17'h2001);
		wait_dma;
		check(dut.vram[15'h1000] === 16'h9912,
		      "the first byte went to the odd half, leaving the even one");
		check(dut.vram[15'h1001] === 16'h3456, "and the next two filled a word");

		// From the 68000's memory: whole words, so the auto-increment goes back
		// to two.
		dma_mem[0] = 16'h1122;
		dma_mem[1] = 16'h3344;
		dma_mem[2] = 16'h5566;
		setreg(5'd15, 8'd2);
		setreg(5'd19, 8'd3);
		setreg(5'd20, 8'd0);
		setreg(5'd21, 8'h00);
		setreg(5'd22, 8'h00);
		setreg(5'd23, 8'h00);                   // mode 0x: from the 68000
		command(6'b100001, 17'h4000);
		wait_dma;
		check(dut.vram[15'h2000] === 16'h1122, "the first word arrived");
		check(dut.vram[15'h2001] === 16'h3344, "and the second");
		check(dut.vram[15'h2002] === 16'h5566, "and the third");

		// The same engine serves CRAM, because the destination is whatever the
		// command's code field said and nothing about the engine knows otherwise.
		dma_mem[0] = 16'h0EEE;
		setreg(5'd19, 8'd1);
		setreg(5'd20, 8'd0);
		setreg(5'd21, 8'h00);
		setreg(5'd22, 8'h00);
		command(6'b100011, 17'h0004);           // CD5 set, CRAM write
		wait_dma;
		check(dut.cram[2] === 9'b111_111_111, "a DMA into CRAM works too");

		// And with DMAs disabled the command is just a command.
		setreg(5'd1, 8'h44);
		setreg(5'd19, 8'd4);
		setreg(5'd23, 8'h80);
		command(6'b100001, 17'h5000);
		wr(0, 16'hCD00);
		check(dut.dma_active === 1'b0, "register 1 can switch DMA off entirely");
		check(dut.vram[15'h2800] === 16'hCD00, "and the write still happens");

		// ==================================================================
		// Sprites.
		//
		// Placed over a part of the picture where both planes are empty, so that
		// anything that appears came from the sprite layer and anything that does
		// not is the backdrop. The three things worth checking are the ones that
		// go wrong: which sprite wins where two overlap, where a wide sprite gets
		// its second tile from, and whether a sprite's position is the one asked
		// for or eight pixels off it.
		// ==================================================================
		setup_sprites;

		$display(" sprites:");
		expect_pixel(10'd200, 10'd0, 6'h13, "a sprite lands where it was put");
		expect_pixel(10'd207, 10'd7, 6'h13, "and is eight by eight");
		expect_pixel(10'd199, 10'd0, 6'h00, "with nothing to the left of it");
		expect_pixel(10'd208, 10'd0, 6'h33, "the second sprite, four pixels along");
		// The list's order is the priority order, so where they overlap the one
		// that comes FIRST is the one that shows -- not the one drawn last.
		expect_pixel(10'd204, 10'd0, 6'h13,
		             "and the first sprite wins where they overlap");

		// A two-cell sprite takes its second tile from the next index, because
		// the tiles of a sprite run down each column before moving across.
		expect_pixel(10'd240, 10'd0, 6'h13, "a wide sprite's first cell");
		expect_pixel(10'd248, 10'd0, 6'h15, "and its second, from the next tile");

		// ==================================================================
		// A busy line. The engine walks the WHOLE list for every line, so a long
		// list costs time even when most of it is off screen -- and what it has not
		// reached when the line ends is not drawn. A game's character screens put
		// the eyes and mouths on as extra sprites late in the list: they vanished
		// for frames at a time on the board. 59 sprites off the screen, then 21 on
		// line 0 (where the planes are empty, x 64 to 255): the twentieth must show (H40
		// allows twenty to a line) and the twenty-first must not (the real chip's
		// limit, which games rely on).
		// ==================================================================
		setup_busy_line;

		$display(" a busy line:");
		expect_pixel(10'd64,  10'd0, 6'h13, "the first of the line's sprites");
		expect_pixel(10'd242, 10'd0, 6'h13, "the twentieth, the 79th entry of the list");
		expect_pixel(10'd251, 10'd0, 6'h00, "and not the twenty-first: twenty to a line in H40");

		// ==================================================================
		// The window.
		//
		// It is not a layer on top of plane A, it is plane A's REPLACEMENT in the
		// region it covers -- so the check that matters is one where plane A has
		// something to show and the window covers it up with nothing.
		// ==================================================================
		setup_window;

		$display(" the window:");
		expect_pixel(10'd31, 10'd0, 6'h22, "outside the window, the planes as before");
		expect_pixel(10'd32, 10'd0, 6'h31, "inside it, the window's own cell");
		expect_pixel(10'd33, 10'd0, 6'h00,
		             "transparent there, so plane B shows through");
		// Plane A has a solid cell here. If the window were merely drawn over the
		// top of it, a transparent window cell would let plane A's $12 show.
		expect_pixel(10'd40, 10'd0, 6'h02,
		             "and where the window is empty, plane A is GONE, not behind it");

		$display("");
		if (errors == 0) $display("tb_md_vdp: all checks passed");
		else             $display("tb_md_vdp: %0d FAIL(s)", errors);
		$finish;
	end

	// --- waiting for a particular pixel ------------------------------------------------
	task wait_pixel;
		input [9:0] x;
		input [9:0] y;
		integer k;
		begin
			k = 0;
			// The output is combinational on the counters, so the moment to look
			// is while they hold the wanted values and ce is about to advance them.
			while (!(px === x && py === y && ce === 1'b1) && k < 400000) begin
				@(negedge clk); k = k + 1;
			end
			if (k >= 400000) begin
				$display("    *** never reached pixel %0d,%0d", x, y);
				errors = errors + 1;
			end
		end
	endtask

	task expect_pixel;
		input [9:0]   x;
		input [9:0]   y;
		input [5:0]   want;
		input [1023:0] what;
		begin
			wait_pixel(x, y);
			if (color_ix === want)
				$display("  ok   (%0d,%0d) = $%02x  %0s", x, y, color_ix, what);
			else begin
				$display("  FAIL (%0d,%0d) = $%02x, wanted $%02x  %0s",
				         x, y, color_ix, want, what);
				errors = errors + 1;
			end
		end
	endtask

	// --- a window down the right-hand side ------------------------------------------------
	task setup_window;
		integer k;
		begin
			setreg(5'd15, 8'd2);
			// The table is 64 cells wide in H40 whatever the planes are set to.
			command(CD_VRAM_WR, 17'hA000);
			for (k = 0; k < 64; k = k + 1)
				wr(0, (k == 4) ? 16'h6001 : 16'h0000);

			setreg(5'd3,  8'h28);   // the window table at $A000
			setreg(5'd17, 8'h82);   // from cell 4 rightwards
			setreg(5'd18, 8'h00);   // and no vertical window at all
			wait_pixel(10'd0, 10'd240);
		end
	endtask

	// --- three sprites, over an empty part of the picture ---------------------------------
	localparam SAT = 17'hF000;

	task setup_sprites;
		integer k;
		begin
			setreg(5'd15, 8'd2);

			// Two more solid tiles: colour 3 at index 3, colour 5 at index 4.
			command(CD_VRAM_WR, 17'h0060);
			for (k = 0; k < 16; k = k + 1) wr(0, 16'h3333);
			command(CD_VRAM_WR, 17'h0080);
			for (k = 0; k < 16; k = k + 1) wr(0, 16'h5555);

			// The attribute table. Y and X are both offset by 128, so 128 is the
			// top left corner of the picture. Where it is (register 5) is set FIRST,
			// as a game does: the chip keeps each entry's first two words in a cache
			// filled by the writes that land on the table where it is at the time.
			setreg(5'd5, 8'h78);  // the table is at $F000, which is $78 * $200
			command(CD_VRAM_WR, SAT);
			wr(0, 16'd128);       // sprite 0: at the top
			wr(0, 16'h0001);      //   one cell each way, linked to sprite 1
			wr(0, 16'h2003);      //   palette 1, tile 3
			wr(0, 16'd328);       //   x = 200

			wr(0, 16'd128);       // sprite 1: four pixels to the right
			wr(0, 16'h0002);      //   linked to sprite 2
			wr(0, 16'h6003);      //   palette 3, so the overlap is visible
			wr(0, 16'd332);       //   x = 204

			wr(0, 16'd128);       // sprite 2: two cells wide
			wr(0, 16'h0400);      //   width 2, height 1, and the list ends here
			wr(0, 16'h2003);      //   palette 1, tiles 3 and 4
			wr(0, 16'd368);       //   x = 240

			setreg(5'd1, 8'h44);  // display on

			// Let a whole frame go by, so the buffer being read was filled with
			// all of this rather than half of it.
			wait_pixel(10'd0, 10'd240);
			wait_pixel(10'd0, 10'd240);
		end
	endtask

	// --- a busy line: 80 entries, the last 21 on line 0 -------------------------------------
	task setup_busy_line;
		integer k;
		begin
			command(CD_VRAM_WR, SAT);
			for (k = 0; k < 80; k = k + 1) begin
				wr(0, k < 59 ? 16'd0 : 16'd128);              // off the top, or line 0
				wr(0, k == 79 ? 16'h0000 : k + 1);              // 8 x 8, linked to the next
				wr(0, 16'h2003);                                // palette 1, tile 3
				wr(0, k < 59 ? 16'd0 : 16'd128 + 64 + 9 * (k - 59));   // x 64, 73, 82 ... 244
			end
			wait_pixel(10'd0, 10'd240);
			wait_pixel(10'd0, 10'd240);
		end
	endtask

	// Wait for a DMA to finish. A game polls the busy bit in the status word for
	// this; here the signal itself will do.
	task wait_dma;
		integer k;
		begin
			k = 0;
			while (dut.dma_active !== 1'b0 && k < 400000) begin
				@(negedge clk); k = k + 1;
			end
			if (k >= 400000) begin
				$display("    *** the DMA never finished");
				errors = errors + 1;
			end
			@(negedge clk);
		end
	endtask

	// An interrupt acknowledge, as the 68000 will drive it.
	task ack;
		begin
			@(negedge clk); int_ack = 1;
			@(negedge clk); int_ack = 0;
			@(negedge clk);
		end
	endtask

	// --- building the picture -------------------------------------------------------------
	localparam NT_A = 17'hC000;      // plane A name table, byte address
	localparam NT_B = 17'hE000;
	localparam HSCR = 17'hB000;

	task setup_picture;
		integer k;
		begin
			// Tile 0 first, all zeroes. Every empty cell points at it, and
			// block RAM that has never been written reads as X -- which would
			// come straight out of the priority logic and make every check
			// below meaningless.
			command(CD_VRAM_WR, 17'h0000);
			for (k = 0; k < 16; k = k + 1) wr(0, 16'h0000);

			// Tile 1: a diagonal of colour 1. Row n has colour 1 in pixel n.
			// Written as two words a row, four bits a pixel, leftmost at the top.
			command(CD_VRAM_WR, 17'h0020);          // tile 1 starts at $20
			for (k = 0; k < 8; k = k + 1) begin
				wr(0, (k < 4) ? (16'h1000 >> (k * 4)) : 16'h0000);
				wr(0, (k < 4) ? 16'h0000 : (16'h1000 >> ((k - 4) * 4)));
			end

			// Tile 2: solid colour 2, every pixel.
			command(CD_VRAM_WR, 17'h0040);
			for (k = 0; k < 16; k = k + 1) wr(0, 16'h2222);

			// Plane B's name table: the diagonal, then the same flipped each way,
			// then the solid tile in palette 2. Priority low throughout except at
			// cell 6, which is where the priority check looks.
			command(CD_VRAM_WR, NT_B);
			wr(0, 16'h0001);                        // cell 0: tile 1
			wr(0, 16'h0801);                        // cell 1: h-flipped
			wr(0, 16'h1001);                        // cell 2: v-flipped
			wr(0, 16'h4002);                        // cell 3: tile 2, palette 2
			wr(0, 16'h0000);                        // cell 4: empty
			wr(0, 16'h0002);                        // cell 5: solid, palette 0
			wr(0, 16'hE002);                        // cell 6: solid, palette 3, HIGH
			for (k = 7; k < 32; k = k + 1) wr(0, 16'h0000);

			// Plane A: empty except over cells 5 and 6 of B, where it is the
			// solid tile at palette 1 and low priority.
			command(CD_VRAM_WR, NT_A);
			for (k = 0; k < 5; k = k + 1) wr(0, 16'h0000);
			wr(0, 16'h2002);                        // cell 5: palette 1, low
			wr(0, 16'h2002);                        // cell 6: palette 1, low
			for (k = 7; k < 32; k = k + 1) wr(0, 16'h0000);

			// The scroll table: both planes at zero.
			command(CD_VRAM_WR, HSCR);
			wr(0, 16'h0000);
			wr(0, 16'h0000);

			// Colours. Only the index is checked, but a palette of zeroes makes a
			// waveform impossible to read.
			command(CD_CRAM_WR, 17'h0000);
			for (k = 0; k < 64; k = k + 1) wr(0, k * 2);

			command(CD_VSRAM_WR, 17'h0000);
			wr(0, 16'h0000);
			wr(0, 16'h0000);

			setreg(5'd2,  8'h30);                   // plane A at $C000
			setreg(5'd4,  8'h07);                   // plane B at $E000
			setreg(5'd13, 8'h2C);                   // scroll table at $B000
			setreg(5'd16, 8'h00);                   // both planes 32 by 32
			setreg(5'd11, 8'h00);                   // whole-screen scrolling
			setreg(5'd7,  8'h00);                   // backdrop is entry 0
			setreg(5'd12, 8'h81);                   // H40
			setreg(5'd1,  8'h44);                   // display on, V28
		end
	endtask

	task set_hscroll_b;
		input [9:0] v;
		begin
			command(CD_VRAM_WR, HSCR + 17'd2);
			wr(0, {6'd0, v});
			// The value is picked up during the next line's blanking, so give it
			// a whole frame to take effect rather than guessing.
			wait_pixel(10'd0, 10'd200);
		end
	endtask

	task set_vscroll_b;
		input [10:0] v;
		begin
			command(CD_VSRAM_WR, 17'h0002);
			wr(0, {5'd0, v});
			wait_pixel(10'd0, 10'd200);
		end
	endtask

	initial begin
		// A frame is 420 by 262 pixels at one pixel every two clocks, so a
		// timeout has to be counted in frames -- twenty thousand clocks does not
		// reach the first line of the first one.
		repeat (20000000) @(posedge clk);
		$display("tb_md_vdp: FAIL timeout");
		$finish;
	end

endmodule
