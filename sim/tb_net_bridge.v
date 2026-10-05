//////////////////////////////////////////////////////////////////////////////////
// tb_net_bridge - net_bridge between two unrelated clocks: a master on one issues
// random writes and reads (holding each until its ack, as net_core does), a slave
// on the other answers after a random wait (as regfile does), and every read must
// return what the last write to that address left.
//
//   ./tools/sim.sh tb_net_bridge
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_net_bridge;
	reg nclk = 0, cclk = 0, nrst = 1, crst = 1;
	always #10    nclk = ~nclk;          // 50 MHz
	always #6.17  cclk = ~cclk;          // ~81 MHz, drifting against it
	reg [31:0] n_addr = 0, n_wdata = 0; reg n_we = 0, n_re = 0;
	wire [31:0] n_rdata; wire [1:0] n_err; wire n_ack;
	wire [31:0] c_addr, c_wdata; wire c_we, c_re;
	reg  [31:0] c_rdata = 0; reg [1:0] c_err = 0; reg c_ack = 0;

	net_bridge dut (
		.n_clk(nclk), .n_rst(nrst), .n_addr(n_addr), .n_wdata(n_wdata), .n_we(n_we), .n_re(n_re),
		.n_rdata(n_rdata), .n_err(n_err), .n_ack(n_ack),
		.c_clk(cclk), .c_rst(crst), .c_addr(c_addr), .c_wdata(c_wdata), .c_we(c_we), .c_re(c_re),
		.c_rdata(c_rdata), .c_err(c_err), .c_ack(c_ack));

	// the slave: 16 registers, an ack after 0-7 clocks, one clock long; the error
	// says whether the address was odd
	reg [31:0] regs [0:15]; reg [2:0] wait_n = 0; reg busy = 0; integer nwr = 0, nrd = 0;
	integer k; initial for (k = 0; k < 16; k = k + 1) regs[k] = 0;
	always @(posedge cclk) begin
		c_ack <= 1'b0;
		if ((c_we || c_re) && !c_ack) begin
			if (!busy) begin busy <= 1'b1; wait_n <= $random; end
			else if (wait_n != 0) wait_n <= wait_n - 1;
			else begin
				busy <= 1'b0; c_ack <= 1'b1; c_err <= {1'b0, c_addr[0]};
				if (c_we) begin regs[c_addr[3:0]] <= c_wdata; nwr = nwr + 1; end
				else begin c_rdata <= regs[c_addr[3:0]]; nrd = nrd + 1; end
			end
		end
		// (the slave must never see a request change under it)
	end
	reg [31:0] seen_a; reg seen_v = 0; integer bad = 0;
	always @(posedge cclk) begin
		if ((c_we || c_re) && seen_v && c_addr != seen_a) begin bad = bad + 1; $display("address changed under a request"); end
		seen_v <= (c_we || c_re) && !c_ack; seen_a <= c_addr;
		if (c_we && c_re) begin bad = bad + 1; $display("both strobes"); end
	end

	// the master
	reg [31:0] model [0:15]; integer i, n, t;
	initial begin
		for (k = 0; k < 16; k = k + 1) model[k] = 0;
		repeat (5) @(posedge nclk); nrst = 0;
		repeat (3) @(posedge cclk); crst = 0;
		for (n = 0; n < 4000; n = n + 1) begin
			@(posedge nclk);
			i = $random & 15;
			if ($random & 1) begin
				n_addr <= i; n_wdata <= $random; n_we <= 1;
			end else begin
				n_addr <= i; n_re <= 1;
			end
			@(posedge nclk);
			t = 0;
			while (!n_ack) begin @(posedge nclk); t = t + 1; if (t > 200) begin $display("tb_net_bridge: FAIL no ack"); $finish; end end
			if (n_we) model[i] = n_wdata;
			else if (n_rdata !== model[i]) begin bad = bad + 1; $display("read %0d: %h, want %h", i, n_rdata, model[i]); end
			if (n_err !== {1'b0, i[0]}) begin bad = bad + 1; $display("error %b at %0d", n_err, i); end
			n_we <= 0; n_re <= 0;
			// (sometimes the next request straight after the ack, sometimes later)
			if ($random & 1) repeat ($random & 7) @(posedge nclk);
		end
		repeat (20) @(posedge nclk);
		if (bad == 0 && nwr + nrd == 4000) $display("tb_net_bridge: PASS %0d writes, %0d reads", nwr, nrd);
		else $display("tb_net_bridge: FAIL %0d wrong, %0d transfers made", bad, nwr + nrd);
		$finish;
	end
endmodule
`default_nettype wire
