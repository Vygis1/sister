//////////////////////////////////////////////////////////////////////////////////
// tb_host_cd - does a sector written word by word through the PC's window come
// out into the drive's ring as the right 2352 bytes, at the right offsets, with
// the right LBA on the commit?
//
// Words arrive with random gaps (never closer than the register bus can bring
// them), several sectors in a row, and every byte the module writes is checked.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none
module tb_host_cd;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	reg we = 0; reg [15:0] off = 0; reg [31:0] wdata = 0;
	wire own, disc, sb_we, sb_done; wire [11:0] sb_addr; wire [7:0] sb_data; wire [23:0] sb_lba;
	host_cd dut (.clk(clk), .rst(rst), .we(we), .off(off), .wdata(wdata), .own(own), .disc(disc),
	             .sb_we(sb_we), .sb_addr(sb_addr), .sb_data(sb_data), .sb_done(sb_done), .sb_lba(sb_lba));

	reg [7:0] ring [0:2351];
	reg [7:0] want [0:2351];
	integer errors = 0, bytes = 0, k, s, g;
	reg [23:0] got_lba; reg got_done;
	always @(posedge clk) begin
		if (sb_we) begin ring[sb_addr] <= sb_data; bytes = bytes + 1; end
		if (sb_done) begin got_done <= 1'b1; got_lba <= sb_lba; end
	end
	reg [31:0] rnd = 32'h1234_5678;
	task w; input [15:0] o; input [31:0] d; begin
		@(negedge clk); we = 1; off = o; wdata = d; @(negedge clk); we = 0;
	end endtask

	initial begin
		repeat (4) @(posedge clk); rst = 0;
		w(16'h0130, 32'd3);
		if (!own || !disc) begin $display("  FAIL the control register"); errors = errors + 1; end
		for (s = 0; s < 6; s = s + 1) begin
			for (k = 0; k < 2352; k = k + 1) begin rnd = rnd * 1664525 + 1013904223; want[k] = rnd[23:16]; ring[k] = 8'hxx; end
			bytes = 0; got_done = 0;
			for (k = 0; k < 588; k = k + 1) begin
				w(16'h4000 + k * 4, {want[4*k+3], want[4*k+2], want[4*k+1], want[4*k]});
				// the network core spends at least ten clocks a word (net_core.v:
				// S_FL_RDREQ, S_FL_BUS, S_FL_NEXT); sector 3 opens with a burst of 16
				// back to back instead, to show the queue absorbs one
				rnd = rnd * 1664525 + 1013904223;
				if (!(s == 3 && k < 16)) for (g = 0; g < 8 + rnd[26:24]; g = g + 1) @(negedge clk);
			end
			repeat (8) @(negedge clk);
			w(16'h012C, 24'd1000 + s);
			repeat (2) @(negedge clk);
			for (k = 0; k < 2352; k = k + 1) if (ring[k] !== want[k]) begin
				if (errors < 8) $display("  FAIL sector %0d byte %0d: %02h, want %02h", s, k, ring[k], want[k]);
				errors = errors + 1;
			end
			if (bytes != 2352) begin $display("  FAIL sector %0d: %0d bytes written", s, bytes); errors = errors + 1; end
			if (!got_done || got_lba != 24'd1000 + s) begin $display("  FAIL sector %0d commit: %b lba %0d", s, got_done, got_lba); errors = errors + 1; end
		end
		if (errors == 0) $display("tb_host_cd: all checks passed -- 6 sectors, every byte in place");
		else             $display("tb_host_cd: FAIL -- %0d errors", errors);
		$finish;
	end
endmodule
`default_nettype wire
