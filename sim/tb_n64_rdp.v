//////////////////////////////////////////////////////////////////////////////////
// tb_n64_rdp - the RDP by itself, repeating a window of the model's RDP work.
//
//   python tools/n64/n64rdpsim.py ROM [...]     (writes sim/n64d/)
//   ./tools/sim.sh tb_n64_rdp
//   python tools/n64/n64rdpsim.py --check [--png]
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
	// the raster's span reads: taken one a clock at most (rq_ready, a clock long, as
	// n64_top gives it), answered in order RLAT clocks later with the line as it was when
	// the read was taken (memory keeps order: a read sees the writes before it, not after)
	wire         rq_valid;  wire [23:0] rq_line;
	reg          rq_ready = 0, rs_valid = 0;
	reg  [127:0] rs_data = 0;
	localparam   RLAT = 24;
	reg  [127:0] rqd [0:63];  reg [63:0] rqt [0:63];
	reg  [5:0]   rq_h = 0, rq_t = 0;
	reg  [63:0]  now = 0;
	reg          cf_ack = 0, cw_ack = 0;
	wire [23:0]  cf_line, cw_line;
	reg  [127:0] cf_data = 0;
	wire [127:0] cw_data;
	wire [15:0]  cw_mask;
	wire [8:0]   xb_dw;
	wire [255:0] regs_flat;

	n64_rdp2 dut (
		.clk(clk), .rst(rst), .no_dither(1'b0),
		.c_we(c_we), .c_idx(c_idx), .c_wd(c_wd), .r_we(1'b0), .r_idx(3'd0), .r_wd(32'd0),
		.regs_flat(regs_flat),
		.cf_req(cf_req), .cf_ack(cf_ack), .cf_line(cf_line), .cf_data(cf_data),
		.cw_req(cw_req), .cw_ack(cw_ack), .cw_line(cw_line), .cw_data(cw_data), .cw_mask(cw_mask),
		.rq_valid(rq_valid), .rq_ready(rq_ready), .rq_line(rq_line), .rs_valid(rs_valid), .rs_data(rs_data),
		.xb_req(xb_req), .xb_dw(xb_dw), .xb_ack(1'b0), .xb_data(64'd0),
		.irq(irq), .idle(idle), .log_stop(1'b0), .log_idx(5'd0), .log_q(), .log_n()
	);

	// --- RDRAM ----------------------------------------------------------------------
	reg  [127:0] mem [0:524287];
	reg          written [0:524287];
	integer      i, n, fd, code, nw, irqs;
	reg  [3:0]   lat;
	always @(posedge clk) begin
		now <= now + 1;
		rq_ready <= 1'b0; rs_valid <= 1'b0;
		// (a read every other clock, as mem_arb takes them)
		if (rq_valid && !rq_ready && !now[0] && (rq_t - rq_h) < 6'd60) begin
			rqd[rq_t] <= mem[rq_line[18:0]]; rqt[rq_t] <= now + RLAT; rq_t <= rq_t + 6'd1;
			rq_ready <= 1'b1;
		end
		if (rq_h != rq_t && rqt[rq_h] <= now) begin
			rs_valid <= 1'b1; rs_data <= rqd[rq_h]; rq_h <= rq_h + 6'd1;
		end
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

	// where the raster's clocks go: a count per state, and the memory requests waited on
	reg  [63:0]  st_clk [0:31];
	reg  [63:0]  walk_clk, cf_wait, cw_wait, busy_clk, stall_clk;
	integer      si;
	initial begin
		for (si = 0; si < 32; si = si + 1) st_clk[si] = 0;
		walk_clk = 0; cf_wait = 0; cw_wait = 0; busy_clk = 0; stall_clk = 0;
	end
	always @(posedge clk) if (!rst) begin
		if (!idle) busy_clk = busy_clk + 1;
		if (!dut.u_raster.pce) stall_clk = stall_clk + 1;
		if (dut.u_raster.st != 5'd0) st_clk[dut.u_raster.st] = st_clk[dut.u_raster.st] + 1;
		else if (!idle) walk_clk = walk_clk + 1;
		if (cf_req) cf_wait = cf_wait + 1;
		if (cw_req) cw_wait = cw_wait + 1;
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
		// TMEM as the model had it: word i is lane i[1:0] of doubleword i[10:2], in all four copies (its low or high half)
		for (i = 0; i < 2048; i = i + 1) begin
			if (i < 1024) begin
				dut.u_tmem.lo0[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
				dut.u_tmem.lo1[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
				dut.u_tmem.lo2[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
				dut.u_tmem.lo3[i >> 2][63 - 16 * (i & 3) -: 16] = tm[i];
			end else begin
				dut.u_tmem.hi0[(i >> 2) - 256][63 - 16 * (i & 3) -: 16] = tm[i];
				dut.u_tmem.hi1[(i >> 2) - 256][63 - 16 * (i & 3) -: 16] = tm[i];
				dut.u_tmem.hi2[(i >> 2) - 256][63 - 16 * (i & 3) -: 16] = tm[i];
				dut.u_tmem.hi3[(i >> 2) - 256][63 - 16 * (i & 3) -: 16] = tm[i];
			end
		end
		repeat (4) @(posedge clk);
		for (n = 0; n < nw; n = n + 1) begin
			code = $fscanf(fd, "%h %h %h", wkind, widx, wline);
			wval = wline[31:0];
			// the RDP idle first: everything before this write has been done
			t = 0;
			@(negedge clk);
			while (!(idle && !cf_req && !cw_req && !rq_valid && rq_h == rq_t) && t < 5000000) begin @(negedge clk); t = t + 1; end
			if (t >= 5000000) begin $display("tb_n64_rdp: TIMED OUT before write %0d (current %06x end %06x, walk %0d, raster %0d, y %0d x %0d)", n, dut.current, dut.endp, dut.ws, dut.u_raster.st, dut.u_raster.y, dut.u_raster.x); n = nw; end
			if (wkind == 1) mem[widx[18:0]] = wline;          // a line the CPU (or the RSP) wrote
			else begin
				c_we = 1; c_idx = widx[2:0]; c_wd = wval;
				@(negedge clk); c_we = 0;
				repeat (2) @(negedge clk);
			end
		end
		t = 0;
		while (!(idle && !cf_req && !cw_req && !rq_valid && rq_h == rq_t) && t < 5000000) begin @(negedge clk); t = t + 1; end
		repeat (20) @(negedge clk);
		of = $fopen("../../sim/n64d/rtl_lines.hex", "w");
		n = 0;
		for (i = 0; i < 524288; i = i + 1)
			if (written[i]) begin $fwrite(of, "%05x %032x\n", i, mem[i]); n = n + 1; end
		$fclose(of);
		$display("clocks: busy %0d, raster idle while busy (walk, decode, loads) %0d, memory reads waited %0d, writes waited %0d, pipeline stalled %0d",
			busy_clk, walk_clk, cf_wait, cw_wait, stall_clk);
		for (si = 0; si < 32; si = si + 1) if (st_clk[si] != 0) $display("  raster state %0d: %0d clocks", si, st_clk[si]);
		$display("tb_n64_rdp: done, %0d writes made, %0d lines written, %0d DP interrupts", nw, n, irqs);
		$finish;
	end
endmodule

`default_nettype wire
