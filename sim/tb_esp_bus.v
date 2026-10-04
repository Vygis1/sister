//////////////////////////////////////////////////////////////////////////////////
// tb_esp_bus - the ESP32 as a bus master: esp_bus behind a 10 MHz SPI master, and
// bus_arb sharing a regfile-shaped bus (request held until the acknowledge on the
// second cycle) with a second master that never stops asking, as net_core's frame
// stream does. PING answers as the shell's does; 64 words written in one frame
// read back right one at a time; the other master's own words are never disturbed.
//
//   ./tools/sim.sh tb_esp_bus
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_esp_bus;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg sclk = 0, mosi = 0, cs_n = 1; wire miso;
	wire [31:0] e_addr, e_wdata, a_addr_w, bus_addr, bus_wdata;
	wire e_we, e_re, e_ack, a_ack, bus_we, bus_re, bus_ack;
	wire [31:0] bus_rdata;
	esp_bus #(.CORE_ID(8'h4E)) dut (.clk(clk), .rst(rst), .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(miso), .spi_cs_n(cs_n),
		.bus_addr(e_addr), .bus_wdata(e_wdata), .bus_we(e_we), .bus_re(e_re), .bus_rdata(bus_rdata), .bus_ack(e_ack));

	// the other master: a read or a write of its own words, back to back
	reg [31:0] a_addr = 0, a_wdata = 0; reg a_we = 0, a_re = 0;
	bus_arb u_arb (.clk(clk), .rst(rst),
		.a_addr(a_addr), .a_wdata(a_wdata), .a_we(a_we), .a_re(a_re), .a_ack(a_ack),
		.b_addr(e_addr), .b_wdata(e_wdata), .b_we(e_we), .b_re(e_re), .b_ack(e_ack),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_we(bus_we), .bus_re(bus_re), .bus_ack(bus_ack));

	// the slave: regfile's two-cycle handshake over 4096 words
	reg [31:0] mem [0:4095]; reg pending = 0; reg [31:0] req_addr; reg req_we;
	wire new_req = (bus_we || bus_re) && !pending;
	always @(posedge clk) begin
		pending <= new_req;
		if (new_req) begin req_addr <= bus_addr; req_we <= bus_we; if (bus_we) mem[bus_addr[13:2]] <= bus_wdata; end
	end
	assign bus_ack = pending;
	assign bus_rdata = mem[req_addr[13:2]];

	integer errors = 0, a_done = 0, k;
	reg [31:0] a_mine [0:63];
	initial for (k = 0; k < 64; k = k + 1) a_mine[k] = 32'hA0A0_0000 + k;
	// the other master writes then reads words 3000.. in a loop, forever
	reg [6:0] ai = 0; reg aphase = 0;
	always @(posedge clk) if (!rst) begin
		if (a_ack) begin
			if (a_re && bus_rdata !== a_mine[ai[5:0]]) begin errors = errors + 1; if (errors < 8) $display("tb_esp_bus: other master read %08x at %0d", bus_rdata, ai); end
			a_we <= 1'b0; a_re <= 1'b0; a_done = a_done + 1;
			if (aphase) ai <= ai + 7'd1;
			aphase <= ~aphase;
		end else if (!a_we && !a_re) begin
			a_addr <= (32'd3000 + ai[5:0]) << 2;
			if (!aphase) begin a_wdata <= a_mine[ai[5:0]]; a_we <= 1'b1; end else a_re <= 1'b1;
		end
	end

	// --- the SPI master: 10 MHz, mode 0 -------------------------------------------------
	task xfer; input [7:0] o; output [7:0] i; integer b; begin
		for (b = 7; b >= 0; b = b - 1) begin
			mosi = o[b]; #50; sclk = 1; i[b] = miso; #50; sclk = 0;
		end
	end endtask
	reg [7:0] r [0:15]; reg [7:0] t;
	integer n, w;
	reg [31:0] got;
	initial begin
		repeat (10) @(posedge clk); rst = 0; #1000;
		// PING
		cs_n = 0; #200; for (n = 0; n < 4; n = n + 1) xfer(n == 0 ? 8'h01 : 8'h00, r[n]); #200; cs_n = 1; #1000;
		if (r[0] !== 8'hA5 || r[1] !== 8'd1 || r[2] !== 8'h4E) begin errors = errors + 1; $display("tb_esp_bus: PING %02x %02x %02x %02x", r[0], r[1], r[2], r[3]); end
		// one frame: 64 words from 0x400
		cs_n = 0; #200;
		xfer(8'h40, t); xfer(8'h00, t); xfer(8'h00, t); xfer(8'h04, t); xfer(8'h00, t);
		for (w = 0; w < 64; w = w + 1) begin
			got = 32'h1234_0000 + w * 32'h0101 + (w << 24);
			xfer(got[7:0], t); xfer(got[15:8], t); xfer(got[23:16], t); xfer(got[31:24], t);
		end
		#400; cs_n = 1; #1000;
		// and back, one frame a word
		for (w = 0; w < 64; w = w + 1) begin
			cs_n = 0; #200;
			got = 32'h400 + 4 * w;
			xfer(8'h41, t); xfer(got[31:24], t); xfer(got[23:16], t); xfer(got[15:8], t); xfer(got[7:0], t);
			for (n = 0; n < 4; n = n + 1) xfer(8'h00, t);
			for (n = 0; n < 4; n = n + 1) xfer(8'h00, r[n]);
			#200; cs_n = 1; #600;
			got = {r[3], r[2], r[1], r[0]};
			if (got !== 32'h1234_0000 + w * 32'h0101 + (w << 24)) begin
				errors = errors + 1;
				if (errors < 8) $display("tb_esp_bus: word %0d read %08x, wrote %08x", w, got, 32'h1234_0000 + w * 32'h0101 + (w << 24));
			end
		end
		$display("tb_esp_bus: the other master made %0d transfers meanwhile", a_done);
		if (errors == 0 && a_done > 10000) $display("tb_esp_bus: all checks passed"); else $display("tb_esp_bus: FAIL (%0d errors)", errors);
		$finish;
	end
endmodule

`default_nettype wire
