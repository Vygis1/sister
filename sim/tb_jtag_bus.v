// tb_jtag_bus - rtl/jtag_bus.v between an AXI4 master (as jtag_axi drives it) and a register
// bus that answers after 0-3 clocks: a burst read of 8 words, single reads, a burst write of 4
// and a single write; every address the bus sees and every word that comes back is checked.
//   ./tools/sim.sh tb_jtag_bus
`timescale 1ns/1ps
`default_nettype none
module tb_jtag_bus;
	reg clk = 0, rst = 1; always #5 clk = ~clk;
	reg [31:0] awaddr = 0, wdata = 0, araddr = 0; reg [7:0] awlen = 0, arlen = 0;
	reg awvalid = 0, wlast = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
	wire awready, wready, bvalid, arready, rlast, rvalid; wire [1:0] bresp, rresp; wire [31:0] rdata;
	wire [31:0] bus_addr, bus_wdata; wire bus_we, bus_re; reg bus_ack = 0; reg [31:0] bus_rdata = 0;
	jtag_bus dut (.clk(clk), .rst(rst),
		.awaddr(awaddr), .awlen(awlen), .awvalid(awvalid), .awready(awready),
		.wdata(wdata), .wlast(wlast), .wvalid(wvalid), .wready(wready),
		.bresp(bresp), .bvalid(bvalid), .bready(bready),
		.araddr(araddr), .arlen(arlen), .arvalid(arvalid), .arready(arready),
		.rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_we(bus_we), .bus_re(bus_re), .bus_ack(bus_ack), .bus_rdata(bus_rdata));

	// the bus: answers a held request after 0-3 clocks; reads give addr ^ A5A5_0000; writes land in mem
	reg [31:0] mem [0:63]; integer wait_n = 0, errors = 0, nreq = 0;
	always @(posedge clk) begin
		bus_ack <= 1'b0;
		if ((bus_re || bus_we) && !bus_ack) begin
			if (wait_n == 0) begin
				bus_ack <= 1'b1; nreq = nreq + 1;
				if (bus_re) bus_rdata <= bus_addr ^ 32'hA5A5_0000;
				if (bus_we) mem[bus_addr[7:2]] <= bus_wdata;
				wait_n = $random & 3;
			end else wait_n = wait_n - 1;
		end
	end
	task check; input c; input [8*48:1] m; begin if (!c) begin errors = errors + 1; $display("  FAIL %0s", m); end end endtask

	integer i; reg [31:0] got;
	task rd; input [31:0] a; input [7:0] n; begin
		@(negedge clk); araddr = a; arlen = n; arvalid = 1;
		while (!arready) @(negedge clk);
		@(negedge clk); arvalid = 0; rready = 1;
		for (i = 0; i <= n; i = i + 1) begin
			while (!rvalid) @(negedge clk);
			check(rdata == ((a + 4 * i) ^ 32'hA5A5_0000), "read data");
			check(rlast == (i == n), "rlast");
			@(negedge clk);
		end
		rready = 0;
	end endtask
	task wr; input [31:0] a; input [7:0] n; begin
		@(negedge clk); awaddr = a; awlen = n; awvalid = 1;
		while (!awready) @(negedge clk);
		@(negedge clk); awvalid = 0;
		for (i = 0; i <= n; i = i + 1) begin
			wdata = 32'h1000 + i; wlast = (i == n); wvalid = 1;
			@(negedge clk); while (!wready) @(negedge clk);
			@(negedge clk); wvalid = 0;
		end
		bready = 1; while (!bvalid) @(negedge clk); @(negedge clk); bready = 0;
		for (i = 0; i <= n; i = i + 1) check(mem[(a >> 2) + i] == 32'h1000 + i, "written word");
	end endtask

	initial begin
		repeat (4) @(negedge clk); rst = 0;
		rd(32'h0008_0020, 8'd7);
		rd(32'h0008_0014, 8'd0);
		rd(32'h0010_0000, 8'd255);
		wr(32'h0000_0040, 8'd3);
		wr(32'h0000_0010, 8'd0);
		rd(32'h0000_0080, 8'd1);
		$display("tb_jtag_bus: %0d bus transfers", nreq);
		if (errors == 0 && nreq == 8 + 1 + 256 + 4 + 1 + 2) $display("tb_jtag_bus: all checks passed");
		else $display("tb_jtag_bus: FAIL (%0d errors, %0d transfers)", errors, nreq);
		$finish;
	end
endmodule
`default_nettype wire
