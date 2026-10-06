//////////////////////////////////////////////////////////////////////////////////
// tb_n64_rsp - the RSP by itself, repeating the model's runs of it.
//
//   python tools/n64/n64rspsim.py ROM          (writes sim/n64r/runs.hex and the model's results)
//   ./tools/sim.sh tb_n64_rsp
//   python tools/n64/n64rspsim.py --check
//
// For each run: DMEM and IMEM are loaded through the RSP's CPU port, SP_PC set,
// the halt cleared, and the RSP left to run until it halts again. Its instruction
// trace goes to sim/n64r/rtl.trace and the DMEM it leaves to rtl_dmem.hex. Its
// DMA sees an RDRAM of zeros (the tests this is for do their DMA from the CPU).
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_rsp;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg          c_mem_en = 0; reg [7:0] c_mem_we = 0; reg [9:0] c_mem_dw = 0; reg [63:0] c_mem_wd = 0;
	wire [63:0]  c_mem_q; wire c_mem_ack;
	reg          c_reg_we = 0; reg [3:0] c_reg_idx = 0; reg [31:0] c_reg_wd = 0;
	wire [31:0]  c_reg_q;
	wire         dm_rd_req, dm_wr_req; reg dm_rd_ack = 0, dm_wr_ack = 0;
	wire [23:0]  dm_rd_line, dm_wr_line; wire [127:0] dm_wr_data; wire [15:0] dm_wr_mask;
	wire         irq_set, irq_clr, halted, tr_valid; wire [11:0] tr_pc; wire [31:0] tr_ir;
	wire         dp_we; wire [2:0] dp_idx, dp_ridx; wire [31:0] dp_wd; wire x_ack; wire [63:0] x_q;
	wire [287:0] sp_regs_flat;

	n64_rsp dut (
		.clk(clk), .rst(rst),
		.c_mem_en(c_mem_en), .c_mem_we(c_mem_we), .c_mem_dw(c_mem_dw), .c_mem_wd(c_mem_wd), .c_mem_q(c_mem_q), .c_mem_ack(c_mem_ack),
		.c_reg_we(c_reg_we), .c_reg_re(1'b0), .c_reg_idx(c_reg_idx), .c_reg_wd(c_reg_wd), .c_reg_q(c_reg_q),
		.x_req(1'b0), .x_dw(9'd0), .x_ack(x_ack), .x_q(x_q),
		.dp_we(dp_we), .dp_idx(dp_idx), .dp_wd(dp_wd), .dp_q(dp_val), .dp_ridx(dp_ridx),
		.dm_rd_req(dm_rd_req), .dm_rd_ack(dm_rd_ack), .dm_rd_line(dm_rd_line), .dm_rd_data(dm_rd_data),
		.dm_wr_req(dm_wr_req), .dm_wr_ack(dm_wr_ack), .dm_wr_line(dm_wr_line), .dm_wr_data(dm_wr_data), .dm_wr_mask(dm_wr_mask),
		.irq_set(irq_set), .irq_clr(irq_clr), .halted_o(halted), .sp_regs_flat(sp_regs_flat), .dbg(), .dlog_idx(8'd0), .dlog_q(), .dlog_n(), .dbg_dw(10'd0), .dbg_dq(), .frozen(),
		.tr_valid(tr_valid), .tr_pc(tr_pc), .tr_ir(tr_ir)
	);
	// RDRAM for the RSP's own DMA: zeros, but for the lines each run's DMAs read in
	// the model (sim/n64r/reads.hex, loaded before the run); writes are kept
	reg  [127:0] ram [0:524287];
	// the DP register reads the model's run made, answered in turn (an MFC0 of 8-15)
	reg  [31:0]  dpv [0:65535];
	integer      dpn, dpi, pf;
	wire [31:0]  dp_val = (dpi < dpn) ? dpv[dpi] : 32'd0;
	always @(posedge clk) if (dut.st == 4'd2 && dut.op == 6'h10 && dut.rs == 5'd0 && dut.rd[3]) dpi = dpi + 1;
	reg  [127:0] dm_rd_data;
	integer      rf, rn, rl, ri;
	reg  [127:0] rd_v;
	// (+WSTALL: a write is taken only one clock in four, at random, as n64_top's queue
	// does when it is full -- the DMA must read a doubleword again rather than lose it)
	integer wf;    // sim/n64r/rtl_writes.txt: every line the DMA wrote, with its mask
	integer n_reread = 0;
	always @(posedge clk) if (dut.dst == 3'd3 && dut.w2_v && dut.g_v && dut.g_line != dut.w2_line && !dut.out_free) n_reread = n_reread + 1;
	reg [31:0] wrnd = 32'h1234_5679; reg wstall = 0;
	initial wstall = $test$plusargs("WSTALL");
	always @(posedge clk) wrnd <= {wrnd[30:0], wrnd[31] ^ wrnd[21] ^ wrnd[1] ^ wrnd[0]};
	wire w_take = dm_wr_req && !dm_wr_ack && (!wstall || wrnd[1:0] == 2'b00);
	always @(posedge clk) begin
		dm_rd_ack <= dm_rd_req && !dm_rd_ack;
		dm_wr_ack <= w_take;
		if (dm_rd_req && !dm_rd_ack) dm_rd_data <= ram[dm_rd_line[18:0]];
		if (w_take) $fwrite(wf, "%05x %04x %032x\n", dm_wr_line[18:0], dm_wr_mask, dm_wr_data);
		if (w_take)
			for (ri = 0; ri < 16; ri = ri + 1)
				if (dm_wr_mask[ri]) ram[dm_wr_line[18:0]][8 * ri +: 8] <= dm_wr_data[8 * ri +: 8];
	end

	integer fd, tf, df, vf, nruns, r, i, j, t, code;
	reg [63:0] w;
	reg [11:0] pc0;
	always @(posedge clk) if (tr_valid) $fwrite(tf, "%03x %08x\n", tr_pc, tr_ir);
	// the RSP's own stores into DMEM (port A), for tools/n64/rspstores.py: "pc dw we data we2 data2"
	integer sf, vf2;
	initial sf = $fopen("../../sim/n64r/rtl_stores.txt", "w");
	// and the vector register file's write port: "pc reg lanes data" (lanes: bit g = byte g)
	initial vf2 = $fopen("../../sim/n64r/rtl_vw.txt", "w");
	always @(posedge clk) if (!dut.halted && dut.vw_lane != 16'd0)
		$fwrite(vf2, "%03x %02x %04x %032x\n", dut.ipc, dut.vw_reg, dut.vw_lane, dut.vw_data);
	always @(posedge clk) if (!dut.halted && (dut.da_we != 8'd0 || dut.da_we2 != 8'd0))
		$fwrite(sf, "%03x %03x %02x %016x %02x %016x\n", dut.ipc, dut.da_addr, dut.da_we, dut.da_wd, dut.da_we2, dut.da_wd2);
	// the RSP's pace: clocks running, instructions, clocks R_EX waited on a vector op's result,
	// clocks in each state
	reg [63:0] pc_run = 0, pc_ins = 0, pc_haz = 0; reg [63:0] pc_st [0:15]; integer pi;
	initial for (pi = 0; pi < 16; pi = pi + 1) pc_st[pi] = 0;
	always @(posedge clk) if (!dut.halted) begin
		pc_run = pc_run + 1; pc_st[dut.st] = pc_st[dut.st] + 1;
		if (dut.tr_valid) pc_ins = pc_ins + 1;
		if (dut.st == 4'd2 && dut.v2_haz) pc_haz = pc_haz + 1;
	end

	task mem_write; input [9:0] dw; input [63:0] v; begin
		@(negedge clk); c_mem_en = 1; c_mem_we = 8'hFF; c_mem_dw = dw; c_mem_wd = v;
		@(negedge clk); c_mem_en = 0; c_mem_we = 0;
		while (!c_mem_ack) @(negedge clk);
	end endtask
	task mem_read; input [9:0] dw; output [63:0] v; begin
		@(negedge clk); c_mem_en = 1; c_mem_we = 8'h00; c_mem_dw = dw;
		@(negedge clk); c_mem_en = 0;
		while (!c_mem_ack) @(negedge clk);
		v = c_mem_q;
	end endtask
	task reg_write; input [3:0] idx; input [31:0] v; begin
		@(negedge clk); c_reg_we = 1; c_reg_idx = idx; c_reg_wd = v;
		@(negedge clk); c_reg_we = 0;
	end endtask

	initial begin
		fd = $fopen("../../sim/n64r/runs.hex", "r");
		rf = $fopen("../../sim/n64r/reads.hex", "r");
		pf = $fopen("../../sim/n64r/dpreads.hex", "r");
		for (ri = 0; ri < 524288; ri = ri + 1) ram[ri] = 128'd0;
		tf = $fopen("../../sim/n64r/rtl.trace", "w");
		df = $fopen("../../sim/n64r/rtl_dmem.hex", "w");
		vf = $fopen("../../sim/n64r/rtl_vstate.txt", "w");
		wf = $fopen("../../sim/n64r/rtl_writes.txt", "w");
		if (fd == 0) begin $display("tb_n64_rsp: FAIL no runs"); $finish; end
		code = $fscanf(fd, "%h\n", nruns);
		repeat (4) @(posedge clk); rst = 0;
		for (r = 0; r < nruns; r = r + 1) begin
			code = $fscanf(fd, "%h\n", pc0);
			for (i = 0; i < 1024; i = i + 1) begin
				code = $fscanf(fd, "%h\n", w);
				mem_write(i[9:0], w);                 // DMEM, then IMEM
			end
			@(negedge clk); $fwrite(tf, "RUN %0d\n", r); $fwrite(wf, "RUN %0d\n", r);
			// stop it, if the last run did not halt, before its memory is written
			reg_write(4'd4, 32'h0000_0002);
			repeat (8) @(negedge clk);
			// this run's DP register reads, answered in order
			dpn = 0; dpi = 0;
			if (pf != 0) begin
				code = $fscanf(pf, "%h", dpn);
				for (ri = 0; ri < dpn; ri = ri + 1) code = $fscanf(pf, "%h", dpv[ri]);
			end
			// this run's RDRAM lines
			if (rf != 0) begin
				code = $fscanf(rf, "%h", rn);
				for (ri = 0; ri < rn; ri = ri + 1) begin
					code = $fscanf(rf, "%h %h", rl, rd_v);
					ram[rl] = rd_v;
				end
			end
			reg_write(4'd8, {20'd0, pc0});
			reg_write(4'd4, 32'h0000_0005);              // clear halt and broke
			t = 0;
			@(negedge clk); @(negedge clk);
			while (!halted && t < 2000000) begin @(negedge clk); t = t + 1; end
			if (!halted) $display("tb_n64_rsp: run %0d did not halt", r);
			repeat (4) @(negedge clk);
			// the vector unit's state, as tools/n64/n64rspsim.py writes the model's
			$fwrite(vf, "RUN %0d\n", r);
			for (i = 0; i < 32; i = i + 1) begin
				$fwrite(vf, "v%02d ", i);
				for (j = 0; j < 16; j = j + 1) $fwrite(vf, "%02x", dut.vb[j][i]);
				$fwrite(vf, "\n");
			end
			$fwrite(vf, "acc");
			for (j = 0; j < 8; j = j + 1) $fwrite(vf, " %04x%04x%04x", dut.acch[j], dut.accm[j], dut.accl[j]);
			$fwrite(vf, "\nflags %02x %02x %02x %02x %02x\n", dut.vcoh, dut.vcol, dut.vcch, dut.vccl, dut.vce);
			for (i = 0; i < 512; i = i + 1) begin
				mem_read(i[9:0], w);
				$fwrite(df, "%016x\n", w);
			end
		end
		$fclose(tf); $fclose(df); $fclose(vf);
		$display("pace: %0d clocks running, %0d instructions, CPI %0d.%02d, %0d clocks waiting on a vector result", pc_run, pc_ins,
		         pc_run / (pc_ins ? pc_ins : 1), (pc_run * 100 / (pc_ins ? pc_ins : 1)) % 100, pc_haz);
		for (pi = 0; pi < 16; pi = pi + 1) if (pc_st[pi] != 0) $display("  state %0d: %0d clocks", pi, pc_st[pi]);
		$display("tb_n64_rsp: %0d runs done; the DMA read a doubleword again %0d times (the write output taken)", nruns, n_reread);
		$finish;
	end
endmodule

`default_nettype wire
