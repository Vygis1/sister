`timescale 1ns/1ps
// The CD-ROM controller's protocol as the BIOS drives it: Init, then GetID with
// no disc; checks HSTS, the response bytes, the INT numbers and the IRQ line.
module tb_ps1_cdrom;
	reg clk = 0; always #5 clk = ~clk;
	reg rst = 1;
	reg sel = 0, we = 0; reg [3:0] addr = 0, be = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; wire irq;
	ps1_cdrom #(.ACK_CYCLES(200), .SECOND_CYCLES(400)) dut (
		.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .irq(irq),
		// an empty drive: every input that exists tied, so none of them simulates as X
		.dma_rd(1'b0), .dma_rdata(), .dma_rvalid(),
		.disc_in(1'b0), .fill_lba(), .fill_room(), .fill_run(),
		.sb_we(1'b0), .sb_addr(12'd0), .sb_data(8'd0), .sb_done(1'b0), .sb_lba(24'd0), .sb_abort(1'b0),
		.ev_v(1'b0), .ev_data(32'd0), .trace_idx(6'd0),
		.toc_we(1'b0), .toc_addr(8'd0), .toc_data(32'd0), .tick(1'b0), .cd_l(), .cd_r(),
		.xa_lba(), .xa_count(), .xa_pop(1'b0), .xa_we(1'b0), .xa_wdata(32'd0), .xa_level(), .xa_gen(), .xa_filt());
	integer errors = 0;
	task wr8; input [1:0] a; input [7:0] v; begin
		@(negedge clk); sel = 1; we = 1; addr = a; be = 4'b0001 << a; wdata = {4{v}}; @(negedge clk); sel = 0; we = 0;
	end endtask
	task rd8; input [1:0] a; output [7:0] v; begin
		@(negedge clk); sel = 1; we = 0; addr = a; be = 4'b0001 << a; #1 v = rdata[a*8 +: 8]; @(negedge clk); sel = 0;   // one lane: a read of the response byte pops it
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
		// With no disc the drive says lid open, motor off (10h), as DuckStation's
		// does -- reported spinning, the BIOS waited for ever and never showed its menu.
		// Init (0Ah): INT3(stat) then INT2(stat)
		wr8(0, 0); wr8(1, 8'h0A);
		rd8(0, v); expect(v & 8'h80, 8'h80, "BUSYSTS after command");
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 3, "Init first INT");
		rd8(1, v); expect(v, 8'h10, "Init INT3 stat lid open");
		wr8(3, 8'h07);                       // acknowledge
		#1 if (irq) begin $display("FAIL: IRQ not cleared by ack"); errors = errors + 1; end
		wait_irq; rd8(3, v); expect(v & 7, 2, "Init second INT");
		rd8(1, v); expect(v, 8'h10, "Init INT2 stat no motor");
		rd8(0, v); expect(v & 8'h20, 8'h00, "RSLRRDY clear after last byte");
		wr8(3, 8'h07);
		// GetID (1Ah) with no disc: INT5(stat|error, 80h not ready) at once
		wr8(0, 0); wr8(1, 8'h1A);
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 5, "GetID INT5");
		rd8(1, v); expect(v, 8'h11, "GetID err stat"); rd8(1, v); expect(v, 8'h80, "GetID not ready");
		wr8(3, 8'h07);
		// Test 20h: version
		wr8(0, 0); wr8(2, 8'h20); wr8(1, 8'h19);
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 3, "Test INT");
		rd8(1, v); expect(v, 8'h94, "Test yy"); wr8(3, 8'h07);
		// ReadN with no disc: INT5(stat|error, 80h)
		wr8(0, 0); wr8(1, 8'h06);
		wait_irq; wr8(0, 1); rd8(3, v); expect(v & 7, 5, "ReadN INT5");
		rd8(1, v); expect(v, 8'h11, "ReadN err stat"); rd8(1, v); expect(v, 8'h80, "ReadN no-disc code");
		wr8(3, 8'h07);
		if (errors == 0) $display("tb_ps1_cdrom: all checks passed"); else $display("tb_ps1_cdrom: %0d FAIL", errors);
		$finish;
	end
endmodule
