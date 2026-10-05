//////////////////////////////////////////////////////////////////////////////////
// tb_vr4300_fpu - the FPU unit against tools/n64/n64fpu.py, vector by vector.
//
//   python tools/n64/n64fpuvec.py 20000 > sim/n64/fpu_vectors.hex
//   ./tools/sim.sh tb_vr4300_fpu
//
// Each vector is an operation and the model's answer: whether fd is written and
// with what, whether it traps, FCR31's new cause and the flags it adds, and the
// condition bit for a compare. Any difference is printed and fails the run.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_vr4300_fpu;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg         start = 0;
	reg  [4:0]  fmt; reg [5:0] fn; reg [63:0] a, b; reg [1:0] rm; reg [4:0] en; reg fs;
	wire        done, res32, wr, trap, cmp_wr, cmp_val;
	wire [63:0] res; wire [5:0] cause; wire [4:0] flags;

	vr4300_fpu dut (
		.clk(clk), .rst(rst), .start(start), .fmt(fmt), .fn(fn), .fs_v(a), .ft_v(b),
		.rm(rm), .en(en), .fs_flush(fs),
		.done(done), .res(res), .res32(res32), .wr(wr), .trap(trap), .cause(cause), .flags(flags),
		.cmp_wr(cmp_wr), .cmp_val(cmp_val)
	);

	// a line: fmt fn a b ctl wr trap cause flags res cmp_wr cmp_val, as one wide word
	reg [263:0] vec [0:199999];
	integer n, i, bad, t, fd, code;
	reg [7:0] v_fmt, v_fn, v_ctl, v_cause, v_flags; reg [63:0] v_a, v_b, v_res; reg [3:0] v_wr, v_trap, v_cw, v_cv;
	initial begin
		bad = 0; n = 0;
		fd = $fopen("../../sim/n64/fpu_vectors.hex", "r");
		if (fd == 0) begin $display("tb_vr4300_fpu: FAIL no vectors"); $finish; end
		repeat (3) @(posedge clk); rst = 0;
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h\n",
			               v_fmt, v_fn, v_a, v_b, v_ctl, v_wr, v_trap, v_cause, v_flags, v_res, v_cw, v_cv);
			if (code == 12) begin
				@(negedge clk);
				fmt = v_fmt[4:0]; fn = v_fn[5:0]; a = v_a; b = v_b;
				rm = v_ctl[1:0]; en = v_ctl[6:2]; fs = v_ctl[7];
				start = 1; @(negedge clk); start = 0;
				t = 0;
				while (!done && t < 400) begin @(negedge clk); t = t + 1; end
				if (!done) begin
					bad = bad + 1;
					if (bad <= 20) $display("HUNG     fmt %0d fn %02x a %016x b %016x ctl %02x", v_fmt, v_fn, v_a, v_b, v_ctl);
				end else if (wr !== v_wr[0] || trap !== v_trap[0] || cause !== v_cause[5:0] || flags !== v_flags[4:0]
				             || (v_wr[0] && res !== v_res) || cmp_wr !== v_cw[0] || (v_cw[0] && cmp_val !== v_cv[0])) begin
					bad = bad + 1;
					if (bad <= 20)
						$display("MISMATCH fmt %0d fn %02x a %016x b %016x ctl %02x: rtl wr %b trap %b cause %02x flags %02x res %016x c %b%b / model wr %0d trap %0d cause %02x flags %02x res %016x c %0d%0d",
						         v_fmt, v_fn, v_a, v_b, v_ctl, wr, trap, cause, flags, res, cmp_wr, cmp_val,
						         v_wr, v_trap, v_cause, v_flags, v_res, v_cw, v_cv);
				end
				n = n + 1;
			end
		end
		if (bad == 0) $display("tb_vr4300_fpu: PASS, %0d operations agree with the model", n);
		else $display("tb_vr4300_fpu: FAIL, %0d of %0d operations differ", bad, n);
		$finish;
	end
endmodule

`default_nettype wire
