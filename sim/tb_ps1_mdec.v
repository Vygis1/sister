//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_mdec - rtl/ps1_mdec.v against the model (tools/ps1/mdec.py): the words of
// sim/ps1mdec/in.txt go in as DMA0 sends them (when the FIFO has room), the out FIFO is read
// as DMA1 reads it (in bursts, with gaps), and every word must be the model's
// (sim/ps1mdec/out.txt).
//
//   python tools/ps1/mdecvec.py [MACROBLOCKS] [SEED]
//   ./tools/sim.sh tb_ps1_mdec
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none
module tb_ps1_mdec;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	reg sel = 0, we = 0, a2 = 0; reg [31:0] wdata = 0; wire [31:0] rdata;
	reg in_wr = 0; reg [31:0] in_data = 0; wire in_ready, dreq0;
	reg out_rd = 0; wire [31:0] out_data; wire out_valid, dreq1;
	ps1_mdec dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .a2(a2), .wdata(wdata), .rdata(rdata),
		.in_wr(in_wr), .in_data(in_data), .in_ready(in_ready), .dreq0(dreq0),
		.out_rd(out_rd), .out_data(out_data), .out_valid(out_valid), .dreq1(dreq1));

	reg [31:0] iv [0:65535]; reg [7:0] ik [0:65535];
	reg [31:0] ov [0:65535];
	integer nin, nout, fd, r, i, got, bad, t;
	reg [7:0] kc; reg [31:0] v;
	initial begin
		fd = $fopen("../../sim/ps1mdec/in.txt", "r"); nin = 0;
		while (!$feof(fd)) begin r = $fscanf(fd, "%c %h\n", kc, v); if (r == 2) begin ik[nin] = kc; iv[nin] = v; nin = nin + 1; end end
		$fclose(fd);
		fd = $fopen("../../sim/ps1mdec/out.txt", "r"); nout = 0;
		while (!$feof(fd)) begin r = $fscanf(fd, "%h\n", v); if (r == 1) begin ov[nout] = v; nout = nout + 1; end end
		$fclose(fd);
		$display("tb_ps1_mdec: %0d words in, %0d expected out", nin, nout);
	end

	// the reader: DMA1-like, a burst while out_valid, now and then a pause
	always @(posedge clk) begin
		out_rd <= 1'b0;
		if (!rst && out_valid && !out_rd && ($random & 3) != 0) out_rd <= 1'b1;
	end
	always @(posedge clk) if (out_rd && out_valid) begin
		if (got < nout && out_data !== ov[got]) begin
			bad = bad + 1;
			if (bad <= 8) $display("tb_ps1_mdec: word %0d is %08x, the model's %08x", got, out_data, ov[got]);
		end
		got = got + 1;
	end

	initial begin
		got = 0; bad = 0;
		repeat (5) @(posedge clk); rst = 0;
		@(posedge clk);
		for (i = 0; i < nin; i = i + 1) begin
			if (ik[i] == "C") begin
				@(negedge clk); sel = 1; we = 1; a2 = 1; wdata = iv[i];
				@(negedge clk); sel = 0; we = 0;
			end else begin
				@(negedge clk);
				while (!in_ready) @(negedge clk);
				in_wr = 1; in_data = iv[i];
				@(negedge clk); in_wr = 0;
			end
		end
		t = 0;
		while (got < nout && t < 2000000) begin @(posedge clk); t = t + 1; end
		repeat (200) @(posedge clk);
		$display("tb_ps1_mdec: %0d of %0d words out, %0d wrong", got, nout, bad);
		if (got == nout && bad == 0) $display("tb_ps1_mdec: all checks passed"); else $display("tb_ps1_mdec: FAIL");
		$finish;
	end
endmodule
`default_nettype wire
