// tb_w65816.v - rtl/wip/w65816.v against SingleStepTests, one bus cycle at a time.
//
//   python tools/snes/sst2vec.py build/w65816.vec --n 200
//   ./tools/simwip.sh tb_w65816 VEC=../../build/w65816.vec
//
// Each test: the core is put in the state before (straight into its registers, at an
// opcode fetch), run for exactly as many cycles as the suite lists, and every cycle is
// held against the suite's -- internal, or a read / write at the address, with the data
// for writes. Then the registers and the memory after. MVN / MVP are checked mid-block
// the same way (the suite stops them after 100 cycles).
`timescale 1ns/1ps
`default_nettype none
module tb_w65816;
	reg clk = 0, rst = 1, ce = 0;
	reg [7:0] din;
	wire [23:0] addr; wire [7:0] dout; wire we, vda, vpa;
	w65816 dut (.clk(clk), .rst(rst), .ce(ce), .addr(addr), .dout(dout), .we(we), .vda(vda), .vpa(vpa),
	            .din(din), .nmi(1'b0), .irq(1'b0), .e_flag(), .m_flag(), .x_flag(), .sync(), .dbg_pc(), .dbg_pbr());
	always #5 clk = ~clk;

	reg [23:0] ma [0:127];
	reg [7:0]  mv [0:127];
	integer    nm;
	reg [23:0] ca [0:1023];
	reg [7:0]  cv [0:1023];
	integer    ct [0:1023];
	integer    fd, ntest, t, k, n, r, nc, bad, fails, opc, mode, pass_files;
	reg [31:0] ir_[0:9], fr[0:9], a, v, ty;
	reg [8*128-1:0] vecname;
	integer    file_ok [0:511], file_n [0:511];
	integer    shown;

	function [7:0] mem_rd;
		input [23:0] ad;
		integer j;
		begin
			mem_rd = 8'h00;
			for (j = 0; j < nm; j = j + 1) if (ma[j] == ad) mem_rd = mv[j];
		end
	endfunction

	task mem_wr;
		input [23:0] ad; input [7:0] val;
		integer j, found;
		begin
			found = 0;
			for (j = 0; j < nm; j = j + 1) if (ma[j] == ad) begin mv[j] = val; found = 1; end
			if (!found) begin ma[nm] = ad; mv[nm] = val; nm = nm + 1; end
		end
	endtask

	initial begin
		if (!$value$plusargs("VEC=%s", vecname)) vecname = "../../build/w65816.vec";
		fd = $fopen(vecname, "r");
		if (fd == 0) begin $display("tb_w65816: FAIL no vector file"); $finish; end
		r = $fscanf(fd, "%h", ntest);
		for (k = 0; k < 512; k = k + 1) begin file_ok[k] = 0; file_n[k] = 0; end
		repeat (3) @(posedge clk);
		rst = 0;
		fails = 0; shown = 0;
		for (t = 0; t < ntest; t = t + 1) begin
			r = $fscanf(fd, "%h %h", opc, mode);
			for (k = 0; k < 10; k = k + 1) r = $fscanf(fd, "%h", ir_[k]);
			r = $fscanf(fd, "%h", nm);
			for (k = 0; k < nm; k = k + 1) begin r = $fscanf(fd, "%h %h", a, v); ma[k] = a; mv[k] = v; end
			r = $fscanf(fd, "%h", nc);
			for (k = 0; k < nc; k = k + 1) begin r = $fscanf(fd, "%h %h %h", a, v, ty); ca[k] = a; cv[k] = v; ct[k] = ty; end
			for (k = 0; k < 10; k = k + 1) r = $fscanf(fd, "%h", fr[k]);
			// the state before
			@(negedge clk);
			dut.PC = ir_[0]; dut.S = ir_[1]; dut.P = ir_[2]; dut.A = ir_[3]; dut.X = ir_[4]; dut.Y = ir_[5];
			dut.DBR = ir_[6]; dut.D = ir_[7]; dut.PBR = ir_[8]; dut.E = ir_[9];
			dut.st = 0; dut.new_stk = 0; dut.waiting = 0; dut.stopped = 0; dut.nmi_pend = 0;
			// (what the chip itself keeps true, and the suite's random states do not: in
			// emulation mode S is in page 1 and M, X are set; with X set the index highs are 0)
			if (ir_[9][0]) begin dut.S = {8'h01, ir_[1][7:0]}; dut.P = ir_[2][7:0] | 8'h30; end
			if (dut.P[4]) begin dut.X = {8'h00, ir_[4][7:0]}; dut.Y = {8'h00, ir_[5][7:0]}; end
			bad = 0;
			for (k = 0; k < nc; k = k + 1) begin
				#1;
				if (ct[k] == 2) begin
					if (vda || vpa) begin
						bad = bad + 1;
						if (shown < 20) $display("  %02x.%0s test %0d cycle %0d: ours %s %06x, want internal", opc, mode ? "n" : "e", t, k, we ? "write" : "read", addr);
					end
				end else begin
					if (!(vda || vpa) || addr !== ca[k] || we !== (ct[k] == 1) || (ct[k] == 1 && dout !== cv[k])) begin
						bad = bad + 1;
						if (shown < 20) $display("  %02x.%0s test %0d cycle %0d: ours %s %06x %02x (vda %0d vpa %0d), want %s %06x %02x",
							opc, mode ? "n" : "e", t, k, (vda || vpa) ? (we ? "write" : "read") : "internal", addr, dout, vda, vpa,
							ct[k] == 1 ? "write" : "read", ca[k], cv[k]);
					end
				end
				din = (ct[k] == 0) ? cv[k] : 8'h00;
				if (ct[k] == 1 && we) mem_wr(addr, dout);
				@(posedge clk); ce = 1; @(negedge clk); ce = 0;
			end
			// the state after
			if (dut.PC !== fr[0][15:0] || dut.S !== fr[1][15:0] || dut.P !== fr[2][7:0] || dut.A !== fr[3][15:0] ||
			    dut.X !== fr[4][15:0] || dut.Y !== fr[5][15:0] || dut.DBR !== fr[6][7:0] || dut.D !== fr[7][15:0] ||
			    dut.PBR !== fr[8][7:0] || dut.E !== fr[9][0]) begin
				bad = bad + 1;
				if (shown < 20) $display("  %02x.%0s test %0d regs: pc %04x/%04x s %04x/%04x p %02x/%02x a %04x/%04x x %04x/%04x y %04x/%04x dbr %02x/%02x d %04x/%04x pbr %02x/%02x e %0d/%0d",
					opc, mode ? "n" : "e", t, dut.PC, fr[0], dut.S, fr[1], dut.P, fr[2], dut.A, fr[3], dut.X, fr[4], dut.Y, fr[5],
					dut.DBR, fr[6], dut.D, fr[7], dut.PBR, fr[8], dut.E, fr[9]);
			end
			r = $fscanf(fd, "%h", n);
			for (k = 0; k < n; k = k + 1) begin
				r = $fscanf(fd, "%h %h", a, v);
				if (mem_rd(a) !== v[7:0]) begin
					bad = bad + 1;
					if (shown < 20) $display("  %02x.%0s test %0d ram[%06x] = %02x want %02x", opc, mode ? "n" : "e", t, a, mem_rd(a), v);
				end
			end
			if (bad) begin fails = fails + 1; shown = shown + 1; end
			file_n[opc * 2 + mode] = file_n[opc * 2 + mode] + 1;
			if (!bad) file_ok[opc * 2 + mode] = file_ok[opc * 2 + mode] + 1;
		end
		pass_files = 0;
		for (k = 0; k < 512; k = k + 1) begin
			if (file_n[k] && file_ok[k] != file_n[k])
				$display("  %02x.%0s %0d of %0d", k / 2, (k % 2) ? "n" : "e", file_ok[k], file_n[k]);
			else if (file_n[k]) pass_files = pass_files + 1;
		end
		$display("tb_w65816: %0d tests, %0d failing; %0d opcode/mode files all pass", ntest, fails, pass_files);
		if (fails) $display("tb_w65816: FAIL"); else $display("tb_w65816: all checks passed");
		$finish;
	end
endmodule
