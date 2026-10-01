`timescale 1ns/1ps
// The controller port as the kernel drives it: select, 01h 42h 00h 00h 00h with
// an /ACK interrupt after each of the first four bytes, and the pad's answer.
module tb_ps1_sio;
	reg clk = 0; always #5 clk = ~clk;
	reg rst = 1; reg sel = 0, we = 0; reg [3:0] addr = 0, be = 0; reg [31:0] wdata = 0;
	wire [31:0] rdata; wire irq; reg [15:0] buttons = 16'h0000;
	ps1_sio #(.SHIFT_CYCLES(100), .ACK_DELAY(10), .ACK_LOW(20)) dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .buttons(buttons), .irq(irq),
		.rst_q(rst), .card_in(1'b0), .card2_in(1'b0), .buttons2(16'd0), .m_line(), .m_req(), .m_we(), .m_wdata(), .m_ready(1'b0), .m_valid(1'b0), .m_rdata(128'd0),
		.wq_sector(), .wq_count(), .wq_ovf(), .wq_pop(1'b0), .wq_clr_ovf(1'b0));
	integer errors = 0, n;
	task wr16; input [3:0] a; input [15:0] v; begin
		@(negedge clk); sel = 1; we = 1; addr = a; be = (a[1] ? 4'b1100 : 4'b0011); wdata = a[1] ? {v, 16'd0} : {16'd0, v}; @(negedge clk); sel = 0; we = 0; end endtask
	task wr8; input [3:0] a; input [7:0] v; begin
		@(negedge clk); sel = 1; we = 1; addr = a; be = 4'b0001 << a[1:0]; wdata = {4{v}}; @(negedge clk); sel = 0; we = 0; end endtask
	task rd; input [3:0] a; output [31:0] v; begin @(negedge clk); sel = 1; we = 0; addr = a; be = 4'hF; #1 v = rdata; @(negedge clk); sel = 0; end endtask
	task expect; input [31:0] got, want; input [8*28:1] what; begin if (got !== want) begin $display("FAIL %0s: got %08h want %08h", what, got, want); errors = errors + 1; end end endtask
	reg [31:0] v;
	task xfer; input [7:0] b; input [7:0] want; input want_ack; input [8*28:1] what; begin
		wr8(4'h0, b);
		n = 0; while (!(dut.rx_full) && n < 1000) begin @(negedge clk); n = n + 1; end
		rd(4'h0, v); expect(v[7:0], want, what);
		if (want_ack) begin
			n = 0; while (!irq && n < 200) begin @(negedge clk); n = n + 1; end
			if (!irq) begin $display("FAIL %0s: no /ACK interrupt", what); errors = errors + 1; end
			rd(4'h4, v); if (!v[7] && !v[9]) begin $display("FAIL %0s: STAT shows neither /ACK nor IRQ", what); errors = errors + 1; end
			wr16(4'hA, 16'h1013);          // acknowledge, keep TXEN | select | ACK irq enable
		end else begin
			repeat (60) @(negedge clk);
			if (irq) begin $display("FAIL %0s: /ACK after the last byte", what); errors = errors + 1; end
		end
	end endtask
	initial begin
		#50 rst = 0; #20;
		rd(4'h4, v); expect(v[15:0] & 16'h0007, 16'h0005, "STAT idle: TX ready, TX idle, RX empty");
		wr16(4'hE, 16'h0088);                // baud
		wr16(4'h8, 16'h000D);                // mode
		wr16(4'hA, 16'h1003);                // TXEN | /JOY select | /ACK interrupt enable
		buttons = 16'h4008;                  // cross + start pressed
		xfer(8'h01, 8'hFF, 1, "byte 0: hi-z");
		xfer(8'h42, 8'h41, 1, "byte 1: id lo");
		xfer(8'h00, 8'h5A, 1, "byte 2: id hi");
		xfer(8'h00, 8'hF7, 1, "byte 3: SWLO (start)");
		xfer(8'h00, 8'hBF, 0, "byte 4: SWHI (cross)");
		wr16(4'hA, 16'h0000);                // deselect
		// slot 2: the second pad, with its own buttons (nothing pressed here)
		wr16(4'hA, 16'h3003);
		xfer(8'h01, 8'hFF, 1, "slot 2: pad address");
		xfer(8'h42, 8'h41, 1, "slot 2: 42h -> digital pad");
		wr16(4'hA, 16'h0000);
		if (errors == 0) $display("tb_ps1_sio: all checks passed"); else $display("tb_ps1_sio: %0d FAIL", errors);
		$finish;
	end
endmodule
