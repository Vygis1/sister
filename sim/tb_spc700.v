// tb_spc700.v - rtl/wip/spc700.v against SingleStepTests spc700, one bus cycle at a time.
//
//   python tools/snes/spc2vec.py build/spc700.vec --n 200
//   ./tools/simwip.sh tb_spc700
//
// Each test: the core put in the state before (an opcode fetch at PC), run for exactly the
// suite's number of cycles, every cycle held against the suite's (internal, or a read /
// write at the address, with the data for writes), then the registers and memory after.
`timescale 1ns/1ps
`default_nettype none
module tb_spc700;
	reg clk = 0, rst = 1, ce = 0;
	reg [7:0] din;
	wire [15:0] addr; wire [7:0] dout; wire brd, bwe;
	spc700 dut (.clk(clk), .rst(rst), .ce(ce), .addr(addr), .dout(dout), .bus_rd(brd), .bus_we(bwe),
	            .din(din), .sync(), .dbg_pc());
	always #5 clk = ~clk;

	reg [15:0] ma [0:127];
	reg [7:0]  mv [0:127];
	integer    nm;
	reg [15:0] ca [0:63];
	reg [7:0]  cv [0:63];
	integer    ct [0:63];
	integer    fd, ntest, t, k, n, r, nc, bad, fails, opc, pass_ops, shown;
	reg [31:0] ir_[0:5], fr[0:5], a, v, ty;
	integer    op_ok [0:255], op_n [0:255];

	function [7:0] mem_rd;
		input [15:0] ad;
		integer j;
		begin
			mem_rd = 8'h00;
			for (j = 0; j < nm; j = j + 1) if (ma[j] == ad) mem_rd = mv[j];
		end
	endfunction

	task mem_wr;
		input [15:0] ad; input [7:0] val;
		integer j, found;
		begin
			found = 0;
			for (j = 0; j < nm; j = j + 1) if (ma[j] == ad) begin mv[j] = val; found = 1; end
			if (!found) begin ma[nm] = ad; mv[nm] = val; nm = nm + 1; end
		end
	endtask

	initial begin
		fd = $fopen("../../build/spc700.vec", "r");
		if (fd == 0) begin $display("tb_spc700: FAIL no vector file"); $finish; end
		r = $fscanf(fd, "%h", ntest);
		for (k = 0; k < 256; k = k + 1) begin op_ok[k] = 0; op_n[k] = 0; end
		repeat (3) @(posedge clk);
		rst = 0;
		fails = 0; shown = 0;
		for (t = 0; t < ntest; t = t + 1) begin
			r = $fscanf(fd, "%h", opc);
			for (k = 0; k < 6; k = k + 1) r = $fscanf(fd, "%h", ir_[k]);
			r = $fscanf(fd, "%h", nm);
			for (k = 0; k < nm; k = k + 1) begin r = $fscanf(fd, "%h %h", a, v); ma[k] = a; mv[k] = v; end
			r = $fscanf(fd, "%h", nc);
			for (k = 0; k < nc; k = k + 1) begin r = $fscanf(fd, "%h %h %h", a, v, ty); ca[k] = a; cv[k] = v; ct[k] = ty; end
			for (k = 0; k < 6; k = k + 1) r = $fscanf(fd, "%h", fr[k]);
			@(negedge clk);
			dut.A = ir_[0]; dut.X = ir_[1]; dut.Y = ir_[2]; dut.SP = ir_[3]; dut.PSW = ir_[4]; dut.PC = ir_[5];
			dut.t = 0; dut.stopped = 0; dut.addr = ir_[5]; dut.bus_rd = 1; dut.bus_we = 0;
			bad = 0;
			for (k = 0; k < nc; k = k + 1) begin
				#1;
				if (ct[k] == 2) begin
					if (brd || bwe) begin
						bad = bad + 1;
						if (shown < 20) $display("  %02x test %0d cycle %0d: ours %s %04x, want internal", opc, t, k, bwe ? "write" : "read", addr);
					end
				end else if (!(brd || bwe) || addr !== ca[k] || bwe !== (ct[k] == 1) || (ct[k] == 1 && dout !== cv[k])) begin
					bad = bad + 1;
					if (shown < 20) $display("  %02x test %0d cycle %0d: ours %s %04x %02x, want %s %04x %02x", opc, t, k,
						bwe ? "write" : brd ? "read" : "internal", addr, dout, ct[k] == 1 ? "write" : "read", ca[k], cv[k]);
				end
				din = mem_rd(addr);
				if (bwe) mem_wr(addr, dout);
				@(posedge clk); ce = 1; @(negedge clk); ce = 0;
			end
			if (dut.A !== fr[0][7:0] || dut.X !== fr[1][7:0] || dut.Y !== fr[2][7:0] || dut.SP !== fr[3][7:0] ||
			    dut.PSW !== fr[4][7:0] || dut.PC !== fr[5][15:0]) begin
				bad = bad + 1;
				if (shown < 20) $display("  %02x test %0d regs: a %02x/%02x x %02x/%02x y %02x/%02x sp %02x/%02x psw %02x/%02x pc %04x/%04x",
					opc, t, dut.A, fr[0], dut.X, fr[1], dut.Y, fr[2], dut.SP, fr[3], dut.PSW, fr[4], dut.PC, fr[5]);
			end
			r = $fscanf(fd, "%h", n);
			for (k = 0; k < n; k = k + 1) begin
				r = $fscanf(fd, "%h %h", a, v);
				if (mem_rd(a) !== v[7:0]) begin
					bad = bad + 1;
					if (shown < 20) $display("  %02x test %0d ram[%04x] = %02x want %02x", opc, t, a, mem_rd(a), v);
				end
			end
			if (bad) begin fails = fails + 1; shown = shown + 1; end
			op_n[opc] = op_n[opc] + 1;
			if (!bad) op_ok[opc] = op_ok[opc] + 1;
		end
		pass_ops = 0;
		for (k = 0; k < 256; k = k + 1) begin
			if (op_n[k] && op_ok[k] != op_n[k]) $display("  %02x %0d of %0d", k, op_ok[k], op_n[k]);
			else if (op_n[k]) pass_ops = pass_ops + 1;
		end
		$display("tb_spc700: %0d tests, %0d failing; %0d opcodes all pass", ntest, fails, pass_ops);
		if (fails) $display("tb_spc700: FAIL"); else $display("tb_spc700: all checks passed");
		$finish;
	end
endmodule
