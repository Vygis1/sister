`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_console - the machine as the register bus sees it.
//
// Every other testbench here reaches inside: tb_nes drives `nes`, tb_sms drives
// `sms`. That is the right way to test those modules and it leaves a hole
// exactly the shape of `console_top`, which is where the cartridge address mux,
// the core select and the pixel path live -- none of them inside either core.
//
// A bug lived in that hole. `z80_addr` was declared sixteen bits wide when the
// cartridge address is eighteen, so the Master System could only ever see the
// first 64 kB of a cartridge and everything above it folded down onto the
// bottom. Both cores passed their own benches; a 32 kB test cartridge passed on
// hardware; a 256 kB game showed a black screen.
//
// So this bench does the only two things that could have caught it: it goes
// through the register interface rather than around it, and it runs a cartridge
// that is bigger than 64 kB and says so.
//////////////////////////////////////////////////////////////////////////////////

module tb_console;

	localparam PROG_AW = 18, CHAR_AW = 17;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// One pixel every nine clocks, which is what regfile.v makes from 50 MHz.
	reg [3:0] phc = 0;
	always @(posedge clk) phc <= (phc == 4'd8) ? 4'd0 : phc + 4'd1;
	wire ce = (phc == 4'd8);

	reg  [15:0] off = 0;
	reg  [PROG_AW-3:0] prog_windex = 0;
	reg         ctrl_we = 0, prog_we = 0;
	reg  [31:0] wdata = 0;
	wire [31:0] ctrl_rdata, prog_rdata;
	wire        px_valid;
	wire [8:0]  px_x, px_y;
	wire [7:0]  px_rgb;

	console_top #(.PROG_AW(PROG_AW), .CHAR_AW(CHAR_AW)) dut (
		.clk(clk), .rst(rst), .ce(ce),
		.off(off), .con_index(10'd0), .con_rdata(),
		.prog_windex(prog_windex), .char_windex({(CHAR_AW-2){1'b0}}),
		.ctrl_we(ctrl_we), .prog_we(prog_we), .char_we(1'b0),
		.wdata(wdata),
		.ctrl_rdata(ctrl_rdata), .prog_rdata(prog_rdata), .char_rdata(),
		.audio(),
		.px_valid(px_valid), .px_x(px_x), .px_y(px_y), .px_rgb(px_rgb)
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

	// --- the register bus, as the host drives it ------------------------------
	task wr_ctrl;
		input [15:0] a;
		input [31:0] v;
		begin
			@(negedge clk);
			off = a; wdata = v; ctrl_we = 1;
			@(negedge clk);
			ctrl_we = 0;
		end
	endtask

	task wr_prog;
		input [PROG_AW-3:0] widx;
		input [31:0] v;
		begin
			@(negedge clk);
			prog_windex = widx; wdata = v; prog_we = 1;
			@(negedge clk);
			prog_we = 0;
		end
	endtask

	// --- what came out of it ---------------------------------------------------
	integer lit = 0, pixels = 0;
	reg watching = 0;
	always @(posedge clk) if (px_valid && watching && px_y < 9'd192) begin
		pixels = pixels + 1;
		if (px_rgb != 8'd0) lit = lit + 1;
	end

	// The cartridge, read as bytes and fed in as words: the host packs four at a
	// time and the board unpacks them, so doing it any other way here would test
	// a path nothing uses.
	reg [7:0] rom [0:262143];
	integer i, f;

	localparam CTRL = 16'h0004, CONSOLE = 16'h0020, FRAME = 16'h0010, PC = 16'h0028;

	initial begin
		$display("tb_console");
		for (i = 0; i < 262144; i = i + 1) rom[i] = 8'h00;
		$readmemh("../../sim/roms/z80/smsbank.hex", rom);

		repeat (20) @(posedge clk);
		rst = 0;
		repeat (10) @(posedge clk);

		// --- what does this bitstream contain? ------------------------------
		@(negedge clk); off = CONSOLE;
		repeat (2) @(posedge clk); #1;
		$display("    CONSOLE reads %08x", ctrl_rdata);
		check(ctrl_rdata[19:16] == 4'b0011,
		      "it reports which cores were built in");

		// --- load 128 kB of cartridge ----------------------------------------
		wr_ctrl(CTRL, 32'd0);                   // held in reset while loading
		for (i = 0; i < 32768; i = i + 1)
			wr_prog(i[PROG_AW-3:0], {rom[i*4+3], rom[i*4+2], rom[i*4+1], rom[i*4]});

		// Read one word back from the far end, where a sixteen-bit address
		// cannot reach, to prove the memory itself is the size it claims.
		@(negedge clk); prog_windex = 16'h7FFC;   // byte $1FFF0
		repeat (3) @(posedge clk); #1;
		$display("    word at $1FFF0 reads %08x", prog_rdata);

		// --- run it -----------------------------------------------------------
		wr_ctrl(CONSOLE, 32'd1);                // the Master System
		wr_ctrl(CTRL, 32'd1);

		@(negedge clk); off = FRAME;
		while (ctrl_rdata < 32'd6) begin @(posedge clk); #1; end

		@(negedge clk); off = PC;
		repeat (2) @(posedge clk); #1;
		$display("    after 6 frames the Z80 is at %04x, banks %0d/%0d/%0d",
		         ctrl_rdata[15:0],
		         dut.g_sms.u_sms.bank0, dut.g_sms.u_sms.bank1, dut.g_sms.u_sms.bank2);
		$display("    the walk reached bank %0d of 8",
		         dut.g_sms.u_sms.wram[13'h0020]);

		// The cartridge turns the display on only if all eight banks answered
		// with their own number, so this single check is the whole test.
		check(dut.g_sms.u_sms.wram[13'h0020] == 8'd7,
		      "every one of the eight banks read back as itself");
		check(dut.g_sms.u_sms.u_vdp.display_on === 1'b1,
		      "so the cartridge turned the display on");

		watching = 1;
		@(negedge clk); off = FRAME;
		repeat (3) @(posedge clk); #1;
		f = ctrl_rdata;
		while (ctrl_rdata < f + 2) begin @(posedge clk); #1; end
		watching = 0;

		$display("    %0d of %0d pixels were lit", lit, pixels);
		check(pixels > 40000, "a whole frame of pixels came out of the console");
		check(lit > 40000, "and they are the picture, not a black screen");

		$display("");
		if (errors == 0) $display("tb_console: all checks passed");
		else             $display("tb_console: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		repeat (100_000_000) @(posedge clk);
		$display("tb_console: FAIL timeout");
		$finish;
	end

endmodule
