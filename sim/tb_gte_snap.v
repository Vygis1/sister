//////////////////////////////////////////////////////////////////////////////////
// tb_gte_snap - the GTE's debug snapshot (ps1_gte.v): armed to skip one command, the GTE
// must stop BEFORE the second (busy, the registers readable through the read port), run it
// on `go` and stop again after it, and once disarmed let the third run as normal.
//   ./tools/sim.sh tb_gte_snap
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none
module tb_gte_snap;
	reg clk = 0, rst = 1; always #5 clk = ~clk;
	reg we = 0, ctl = 0, cmd = 0; reg [4:0] reg_i = 0; reg [31:0] wdata = 0; reg [24:0] word = 0;
	wire [31:0] rdata; wire busy;
	reg arm = 0, go = 0; reg [15:0] skip = 0; reg [6:0] idx = 0;
	wire [31:0] sdata; wire [24:0] sword; wire [1:0] sstate;
	ps1_gte dut (.gte_old(4'd0), .clk(clk), .rst(rst),
		.we(we), .ctl(ctl), .reg_i(reg_i), .wreg_i(reg_i), .wctl(ctl), .wdata(wdata), .rdata(rdata),
		.cmd(cmd), .word(word), .busy(busy),
		.snap_arm(arm), .snap_go(go), .snap_skip(skip), .snap_idx(idx), .snap_data(sdata), .snap_word(sword), .snap_state(sstate));
	integer errors = 0, t;
	task check; input c; input [8*64:1] m; begin if (c) $display("  ok   %0s", m); else begin errors = errors + 1; $display("  FAIL %0s", m); end end endtask
	task wr; input [4:0] r; input [31:0] v; begin
		@(negedge clk); while (busy) @(negedge clk);
		we = 1; ctl = 0; reg_i = r; wdata = v; @(negedge clk); we = 0;
	end endtask
	// a command as the processor gives it: held until the GTE has it (busy), then dropped
	task op; input [24:0] w; begin
		@(negedge clk); while (busy) @(negedge clk);
		word = w; cmd = 1; @(negedge clk); cmd = 0;
	end endtask
	localparam [24:0] SQR = 25'h0000028;
	initial begin
		repeat (4) @(negedge clk); rst = 0;
		wr(5'd9, 32'd3); wr(5'd10, 32'd4); wr(5'd11, 32'd5);      // IR1..IR3
		arm = 1; skip = 16'd1;
		op(SQR);                                                     // the first: skipped
		t = 0; while (busy && t < 200) begin @(negedge clk); t = t + 1; end
		check(sstate == 2'b00, "the first command ran, not stopped");
		wr(5'd9, 32'd6);                                             // IR1 = 6 for the second
		op(SQR);
		t = 0; while (sstate != 2'b01 && t < 200) begin @(negedge clk); t = t + 1; end
		check(sstate == 2'b01 && busy, "stopped before the second, busy");
		check(sword == SQR, "it holds the command word");
		idx = 7'd9;  #1 check(sdata == 32'd6, "IR1 reads 6 before it ran");
		idx = 7'd25; #1 check(sdata == 32'd9, "MAC1 still the first command's 9");
		repeat (50) @(negedge clk);
		check(sstate == 2'b01, "and it stays stopped");
		go = 1;
		t = 0; while (sstate != 2'b10 && t < 400) begin @(negedge clk); t = t + 1; end
		check(sstate == 2'b10 && busy, "go: it ran and stopped after, busy");
		idx = 7'd25; #1 check(sdata == 32'd36, "MAC1 = 36 after");
		idx = 7'd26; #1 check(sdata == 32'd256, "MAC2 = 256 after (IR2 was the first one's 16)");
		idx = 7'd63; #1 check(sdata[30:0] == 31'd0, "FLAG (control 31) clear");
		arm = 0; go = 0;
		@(negedge clk); @(negedge clk);
		check(sstate == 2'b00 && !busy, "disarmed: free");
		wr(5'd9, 32'd7);
		op(SQR);
		t = 0; while (busy && t < 200) begin @(negedge clk); t = t + 1; end
		reg_i = 5'd25; ctl = 0; #1 check(rdata == 32'd49, "the third ran as normal: MAC1 = 49");
		if (errors == 0) $display("tb_gte_snap: all checks passed"); else $display("tb_gte_snap: %0d FAIL(s)", errors);
		$finish;
	end
endmodule
`default_nettype wire
