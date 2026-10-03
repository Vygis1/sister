//////////////////////////////////////////////////////////////////////////////////
// tb_n64_rdp - the RDP by itself, repeating a window of the model's RDP work.
//
//   python tools/n64rdpsim.py ROM [...]     (writes sim/n64d/)
//   ./tools/sim.sh tb_n64_rdp
//   python tools/n64rdpsim.py --check [--png]
//
// RDRAM is 8 MB of 128-bit lines (sim/n64d/rdram.hex), read with a few clocks of
// latency and written with byte enables; TMEM starts as the model's did
// (tmem.hex). The DP register writes in writes.hex are made in order, each once
// the RDP has gone idle. The lines written go to sim/n64d/rtl_lines.hex.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_rdp;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg          c_we = 0; reg [2:0] c_idx = 0; reg [31:0] c_wd = 0;
	wire         cf_req, cw_req, xb_req, irq, idle;
	reg          cf_ack = 0, cw_ack = 0;
	wire [23:0]  cf_line, cw_line;
	reg  [127:0] cf_data = 0;
	wire [127:0] cw_data;
	wire [15:0]  cw_mask;
	wire [8:0]   xb_dw;
	wire [255:0] regs_flat;

	n64_rdp2 dut (
		.clk(clk), .rst(rst),
		.c_we(c_we), .c_idx(c_idx), .c_wd(c_wd), .r_we(1'b0), .r_idx(3'd0), .r_wd(32'd0),
		.regs_flat(regs_flat),
		.cf_req(cf_req), .cf_ack(cf_ack), .cf_line(cf_line), .cf_data(cf_data),
		.cw_req(cw_req), .cw_ack(cw_ack), .cw_line(cw_line), .cw_data(cw_data), .cw_mask(cw_mask),
		.xb_req(xb_req), .xb_dw(xb_dw), .xb_ack(1'b0), .xb_data(64'd0),
		.irq(irq), .idle(idle)
	);

	// --- RDRAM ----------------------------------------------------------------------
	reg  [127:0] mem [0:524287];
	reg          written [0:524287];
	integer      i, n, fd, code, nw, irqs;
	reg  [3:0]   lat;
	always @(posedge clk) begin
		cf_ack <= 1'b0; cw_ack <= 1'b0;
		if (cf_req && !cf_ack) begin
			if (lat == 4'd6) begin cf_data <= mem[cf_line[18:0]]; cf_ack <= 1'b1; lat <= 4'd0; end
			else lat <= lat + 4'd1;
		end else if (cw_req && !cw_ack) begin
			if (lat == 4'd3) begin
				for (i = 0; i < 16; i = i + 1)
					if (cw_mask[i]) mem[cw_line[18:0]][8 * i +: 8] <= cw_data[8 * i +: 8];
				written[cw_line[18:0]] <= 1'b1;
				cw_ack <= 1'b1; lat <= 4'd0;
			end else lat <= lat + 4'd1;
		end else lat <= 4'd0;
		if (irq) irqs = irqs + 1;
	end

	reg  [31:0]  widx, wval, wkind;
	reg  [127:0] wline;
	reg  [15:0]  tm [0:2047];
	integer      t, of;
	initial begin
		irqs = 0; lat = 0;
		for (i = 0; i < 524288; i = i + 1) written[i] = 1'b0;
		$readmemh("../../sim/n64d/rdram.hex", mem);
		$readmemh("../../sim/n64d/tmem.hex", tm);
		fd = $fopen("../../sim/n64d/writes.hex", "r");
		if (fd == 0) begin $display("tb_n64_rdp: FAIL no writes.hex"); $finish; end
		code = $fscanf(fd, "%h\n", nw);
		repeat (4) @(posedge clk); rst = 0;
		// TMEM as the model had it: word i is lane i[1:0] of doubleword i[10:2], in all four copies
		for (i = 0; i < 2048; i = i + 1) begin
			dut.u_tmem.cp0[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
			dut.u_tmem.cp1[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
			dut.u_tmem.cp2[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
			dut.u_tmem.cp3[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
		end
		repeat (4) @(posedge clk);
		for (n = 0; n < nw; n = n + 1) begin
			code = $fscanf(fd, "%h %h %h", wkind, widx, wline);
			wval = wline[31:0];
			// the RDP idle first: everything before this write has been done
			t = 0;
			@(negedge clk);
			while (!(idle && !cf_req && !cw_req) && t < 5000000) begin @(negedge clk); t = t + 1; end
			if (t >= 5000000) begin $display("tb_n64_rdp: TIMED OUT before write %0d (current %06x end %06x, walk %0d, raster %0d, y %0d x %0d)", n, dut.current, dut.endp, dut.ws, dut.u_raster.st, dut.u_raster.y, dut.u_raster.x); n = nw; end
			if (wkind == 1) mem[widx[18:0]] = wline;          // a line the CPU (or the RSP) wrote
			else begin
				c_we = 1; c_idx = widx[2:0]; c_wd = wval;
				@(negedge clk); c_we = 0;
				repeat (2) @(negedge clk);
			end
		end
		t = 0;
		while (!(idle && !cf_req && !cw_req) && t < 5000000) begin @(negedge clk); t = t + 1; end
		repeat (20) @(negedge clk);
		of = $fopen("../../sim/n64d/rtl_lines.hex", "w");
		n = 0;
		for (i = 0; i < 524288; i = i + 1)
			if (written[i]) begin $fwrite(of, "%05x %032x\n", i, mem[i]); n = n + 1; end
		$fclose(of);
		$display("tb_n64_rdp: done, %0d writes made, %0d lines written, %0d DP interrupts", nw, n, irqs);
		$finish;
	end
endmodule

`default_nettype wire
