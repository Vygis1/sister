`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_md_top - the 68000 and the VDP, as one machine.
//
// Everything below this has its own tests and passes them. This is the one that
// says they agree with each other: a real program, assembled by
// tools/md/m68kasm.py, running out of a cartridge at address zero, reaching the
// VDP through the memory map and putting a picture on the screen.
//
// The picture is deliberately trivial -- one red cell in the corner of a black
// field -- because the point is not the picture. The point is that a DMA took
// the bus and gave it back, that a long write to the control port arrived as
// two words, that the registers a game sets in its first hundred instructions
// mean what the VDP thinks they mean, and that the thing reaches its STOP.
//////////////////////////////////////////////////////////////////////////////////

module tb_md_top;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// The real machine runs the 68000 at 7.67 MHz and the VDP's pixels at 13.4.
	// The ratio here is not those numbers, but it is not one either -- which is
	// the part that matters, because a design that only works when the two sides
	// tick together is a design that works in exactly one testbench.
	reg [2:0] div = 0;
	always @(posedge clk) div <= div + 3'd1;
	wire cpu_ce = (div[1:0] == 2'd3);
	wire vdp_ce = div[0];
	wire snd_ce = (div[2:0] == 3'd7);
	// The FM chip's sample rate is far below everything else, so it gets its own
	// slow enable rather than sharing the Z80's -- and it has to be at least 96
	// clocks, which is what its twenty-four operators take to compute.
	reg [6:0] fmdiv = 0;
	always @(posedge clk) fmdiv <= fmdiv + 7'd1;
	wire fm_ce = (fmdiv == 7'd127);

	wire [9:0]  px, py;
	wire        pixel_en;
	wire [8:0]  color;
	wire [31:0] pc;
	wire        halted;

	// The cartridge now sits behind the cache, so what the testbench provides is
	// the SLOW memory: a line of eight words, after a delay. The delay is not
	// decoration -- with a zero-latency model the cache would never be seen to
	// stall anything, and the whole point of putting it here is that the rest of
	// the machine copes when it does.
	wire [19:0]  mem_addr;
	wire         mem_req;
	reg          mem_ready = 1;
	reg  [127:0] mem_data  = 0;
	reg          mem_valid = 0;
	wire signed [15:0] audio_l, audio_r;

	reg [15:0] cart [0:65535];
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
					mem_data[mi*16 +: 16] <= cart[{mem_line[12:0], mi[2:0]}];
				mem_valid <= 1'b1;
				@(posedge clk);
				mem_valid <= 1'b0;
				mem_ready <= 1'b1;
			end
		end
	end
	// Up, right, B and start held down, which gives a different answer in each
	// half of the pad read and so tells them apart.
	reg  [7:0]  joy1 = 8'b1001_1001;

	md_top dut (
		.clk(clk), .rst(rst), .cpu_ce(cpu_ce), .vdp_ce(vdp_ce),
		.snd_ce(snd_ce), .fm_ce(fm_ce),
		.mem_addr(mem_addr), .mem_req(mem_req), .mem_ready(mem_ready),
		.mem_data(mem_data), .mem_valid(mem_valid),
		.audio_l(audio_l), .audio_r(audio_r), .joy1(joy1), .joy2(8'd0),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color),
		.dbg_pc(pc), .dbg_halted(halted)
	);

	integer errors = 0;
	integer n;

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

	task wait_pixel;
		input [9:0] x;
		input [9:0] y;
		integer k;
		begin
			k = 0;
			while (!(px === x && py === y && vdp_ce === 1'b1) && k < 2000000) begin
				@(negedge clk); k = k + 1;
			end
			if (k >= 2000000) begin
				$display("    *** never reached pixel %0d,%0d", x, y);
				errors = errors + 1;
			end
		end
	endtask

	task expect_color;
		input [9:0]    x;
		input [9:0]    y;
		input [8:0]    want;
		input [1023:0] what;
		begin
			wait_pixel(x, y);
			if (color === want)
				$display("  ok   (%0d,%0d) = %03x  %0s", x, y, color, what);
			else begin
				$display("  FAIL (%0d,%0d) = %03x, wanted %03x  %0s",
				         x, y, color, want, what);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		$readmemh("../../sim/roms/md/mdtest.hex", cart);

		repeat (8) @(posedge clk);
		rst = 0;

		$display("tb_md_top");

		// The program clears all 64 kB of VRAM with a fill before it does
		// anything else, so this is not a short wait.
		n = 0;
		while (halted !== 1'b1 && n < 4000000) begin
			@(posedge clk); n = n + 1;
		end
		check(halted === 1'b1, "the program ran to its STOP");
		if (halted !== 1'b1)
			$display("       it got as far as PC=%08x", pc);

		// The fill wrote zeroes over all of it, so a name-table entry the program
		// never touched is a real zero rather than an X -- which is what makes
		// every check below mean something.
		check(dut.vdp.vram[15'h6000] === 16'h0000,
		      "the DMA fill cleared VRAM, including where nothing was written");
		check(dut.vdp.vram[15'h7000] === 16'h0001,
		      "plane B's first cell points at tile 1");
		check(dut.vdp.vram[15'h0010] === 16'h1111,
		      "and tile 1 is solid colour 1");

		$display(" the other computer:");
		// The 68000 loaded a program into the Z80's RAM, let it run, took the bus
		// back and read the byte the Z80 wrote -- then parked it in VRAM. Getting
		// $5A here means all four of those steps worked.
		check(dut.vdp.vram[15'h2800] === 16'h005A,
		      "the Z80 ran the program the 68000 gave it, and the answer came back");

		$display(" the controller:");
		check(dut.vdp.vram[15'h2801] === 16'h0066,
		      "with TH high the pad reports C, B and the directions");
		check(dut.vdp.vram[15'h2802] === 16'h0012,
		      "and with it low, start and A -- a different answer from the same port");

		$display(" the picture:");
		// Colour 1 is red: three bits of red, none of anything else.
		expect_color(10'd0, 10'd0, 9'b000_000_111, "the cell in the corner is red");
		expect_color(10'd7, 10'd7, 9'b000_000_111, "and so is its far corner");
		// One pixel further along is the next cell, which is tile 0 -- cleared,
		// so transparent, so the backdrop shows through.
		expect_color(10'd8, 10'd0, 9'b000_000_000, "next to it is the backdrop");
		expect_color(10'd0, 10'd8, 9'b000_000_000, "and so is below it");

		$display("");
		if (errors == 0) $display("tb_md_top: all checks passed");
		else             $display("tb_md_top: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (8000000) @(posedge clk);
		$display("tb_md_top: FAIL timeout at PC=%08x", pc);
		$finish;
	end

endmodule
