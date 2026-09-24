//////////////////////////////////////////////////////////////////////////////////
// tb_console_sel.v - does a core image come up running a core it CONTAINS?
//
// This exists because it did not.
//
// `console_sel` reset to CONSOLE_NES no matter which machines were compiled in.
// The register that accepts a new selection checks CORES_BUILT and refuses one
// that is not there -- but the reset value went around that check rather than
// through it. So a Master System image came up with the NES selected, which is
// not in the bitstream, so nothing ran and the screen stayed black. The register
// map reported it plainly, if you knew to look: "built: Master System, running:
// NES".
//
// The failure costs a full build to see and looks like a dead core rather than a
// wrong default, which is the expensive kind of wrong. So it is checked here,
// where it costs seconds, for every combination that can be shipped.
//
// What is asserted is deliberately weak: not "SMS-only selects SMS", but "every
// image selects something it contains". That is the actual requirement, and it
// stays true if the numbering or the priority order ever changes.
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps
`default_nettype none

module tb_console_sel;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	// 0x0020 reports {12'd0, CORES_BUILT, 7'd0, test_mode, 4'd0, console_sel}.
	localparam [15:0] OFF_STATUS = 16'h0020;

	wire [31:0] rd_nes, rd_sms, rd_md, rd_both;

	// One instance per shipped combination. They share a clock and a reset and
	// are otherwise inert: nothing is written to them, because the question is
	// what they do with no help at all.
	console_top #(.CORE_NES(1), .CORE_SMS(0), .CORE_MD(0)) u_nes (
		.clk(clk), .rst(rst), .ce(1'b0), .off(OFF_STATUS), .con_index(10'd0),
		.con_rdata(), .prog_windex(16'd0), .md_windex(16'd0),
		.char_windex(15'd0), .ctrl_we(1'b0), .prog_we(1'b0), .char_we(1'b0),
		.wdata(32'd0), .ctrl_rdata(rd_nes), .prog_rdata(), .char_rdata(),
		.audio(), .px_valid(), .px_x(), .px_y(), .px_rgb()
	);

	console_top #(.CORE_NES(0), .CORE_SMS(1), .CORE_MD(0)) u_sms (
		.clk(clk), .rst(rst), .ce(1'b0), .off(OFF_STATUS), .con_index(10'd0),
		.con_rdata(), .prog_windex(16'd0), .md_windex(16'd0),
		.char_windex(15'd0), .ctrl_we(1'b0), .prog_we(1'b0), .char_we(1'b0),
		.wdata(32'd0), .ctrl_rdata(rd_sms), .prog_rdata(), .char_rdata(),
		.audio(), .px_valid(), .px_x(), .px_y(), .px_rgb()
	);

	console_top #(.CORE_NES(0), .CORE_SMS(0), .CORE_MD(1), .MD_AW(12),
	              .PROG_AW(12), .CHAR_AW(12)) u_md (
		.clk(clk), .rst(rst), .ce(1'b0), .off(OFF_STATUS), .con_index(10'd0),
		.con_rdata(), .prog_windex(10'd0), .md_windex(16'd0),
		.char_windex(10'd0), .ctrl_we(1'b0), .prog_we(1'b0), .char_we(1'b0),
		.wdata(32'd0), .ctrl_rdata(rd_md), .prog_rdata(), .char_rdata(),
		.audio(), .px_valid(), .px_x(), .px_y(), .px_rgb()
	);

	console_top #(.CORE_NES(1), .CORE_SMS(1), .CORE_MD(0)) u_both (
		.clk(clk), .rst(rst), .ce(1'b0), .off(OFF_STATUS), .con_index(10'd0),
		.con_rdata(), .prog_windex(16'd0), .md_windex(16'd0),
		.char_windex(15'd0), .ctrl_we(1'b0), .prog_we(1'b0), .char_we(1'b0),
		.wdata(32'd0), .ctrl_rdata(rd_both), .prog_rdata(), .char_rdata(),
		.audio(), .px_valid(), .px_x(), .px_y(), .px_rgb()
	);

	integer fails = 0;
	task ok;
		input cond;
		input [800:0] what;
		begin
			if (cond) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); fails = fails + 1; end
		end
	endtask

	task check;
		input [31:0]  status;
		input [800:0] name;
		reg [3:0] built, sel;
		begin
			built = status[19:16];
			sel   = status[3:0];
			$display("    %0s: built=%04b selected=%0d", name, built, sel);
			ok(built != 4'b0000, "the image reports containing at least one core");
			ok((built >> sel) & 1'b1,
			   "the core it selected out of reset is one it contains");
		end
	endtask

	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);

		check(rd_nes,  "NES only");
		check(rd_sms,  "Master System only");
		check(rd_md,   "Mega Drive only");
		check(rd_both, "NES and Master System");

		if (fails == 0) $display("tb_console_sel: all checks passed");
		else            $display("tb_console_sel: %0d FAIL(s)", fails);
		$finish;
	end

endmodule

`default_nettype wire
