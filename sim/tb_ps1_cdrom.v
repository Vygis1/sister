`timescale 1ns/1ps
// The CD-ROM controller's protocol as the BIOS drives it: Init, then GetID with
// no disc; checks HSTS, the response bytes, the INT numbers and the IRQ line.
module tb_ps1_cdrom;
	reg clk = 0; always #5 clk = ~clk;
	reg rst = 1;
	reg sel = 0, we = 0; reg [3:0] addr = 0, be = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; wire irq;
	ps1_cdrom #(.ACK_CYCLES(200), .SECOND_CYCLES(400)) dut (
		.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .irq(irq));
	integer errors = 0;
	task wr8; input [1:0] a; input [7:0] v; begin
		@(negedge clk); sel = 1; we = 1; addr = a; be = 4'b0001 << a; wdata = {4{v}}; @(negedge clk); sel = 0; we = 0;
	end endtask
	task rd8; input [1:0] a; output [7:0] v; begin
		@(negedge clk); sel = 1; we = 0; addr = a; be = 4'b1111; #1 v = rdata[a*8 +: 8]; @(negedge clk); sel = 0;
	end endtask
	task expect; input [7:0] got, want; input [8*24:1] what; begin
		if (got !== want) begin $display("FAIL %0s: got %02h want %02h", what, got, want); errors = errors + 1; end
	end endtask
	reg [7:0] v; integer n;
	task wait_irq; begin n = 0; while (!irq && n < 5000) begin @(negedge clk); n = n + 1; end
		if (!irq) begin $display("FAIL: no IRQ"); errors = errors + 1; end end endtask
	initial begin
		#50 rst = 0; #20;
		// BIOS-style: index 1, enable all interrupts, acknowledge anything pending
		wr8(0, 1); wr8(2, 8'h1F); wr8(3, 8'h1F);
		rd8(0, v); expect(v & 8'h18, 8'h18, "HSTS empty/not-full");
		// Init (0Ah): INT3(stat) then INT2(stat=02)
		wr8(0, 0); wr8(1, 8'h0A);
		rd8(0, v); expect(v & 8'h80, 8'h80, "BUSYSTS after command");
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 3, "Init first INT");
		rd8(1, v); expect(v, 8'h00, "Init INT3 stat");
		wr8(3, 8'h07);                       // acknowledge
		#1 if (irq) begin $display("FAIL: IRQ not cleared by ack"); errors = errors + 1; end
		wait_irq; rd8(3, v); expect(v & 7, 2, "Init second INT");
		rd8(1, v); expect(v, 8'h02, "Init INT2 stat motor on");
		rd8(0, v); expect(v & 8'h20, 8'h00, "RSLRRDY clear after last byte");
		wr8(3, 8'h07);
		// GetID (1Ah): INT3(stat) then INT5(08 40 00 00 00 00 00 00)
		wr8(0, 0); wr8(1, 8'h1A);
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 3, "GetID first INT");
		rd8(1, v); expect(v, 8'h02, "GetID INT3 stat"); wr8(3, 8'h07);
		wait_irq; rd8(3, v); expect(v & 7, 5, "GetID second INT");
		rd8(1, v); expect(v, 8'h08, "GetID b0"); rd8(1, v); expect(v, 8'h40, "GetID b1");
		rd8(1, v); expect(v, 8'h00, "GetID b2");
		wr8(3, 8'h07);
		// Test 20h: version
		wr8(0, 0); wr8(2, 8'h20); wr8(1, 8'h19);
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 3, "Test INT");
		rd8(1, v); expect(v, 8'h94, "Test yy"); wr8(3, 8'h07);
		// ReadN with no disc: INT5(03, 80)
		wr8(0, 0); wr8(1, 8'h06);
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 5, "ReadN INT5");
		rd8(1, v); expect(v, 8'h03, "ReadN err stat"); rd8(1, v); expect(v, 8'h80, "ReadN no-disc code");
		wr8(3, 8'h07);
		if (errors == 0) $display("tb_ps1_cdrom: all checks passed"); else $display("tb_ps1_cdrom: %0d FAIL", errors);
		$finish;
	end
endmodule
