//////////////////////////////////////////////////////////////////////////////////
// tb_n64_top - the N64 as the board will run it: the cartridge filled through the
// host's port into DDR3, the run bit raised, our boot ROM copying the game into
// RDRAM and jumping to it, the program running to its end. Then the screen.
//
//   python tools/n64/n64sim.py ROM.N64 --system        (writes sim/n64/cart.hex)
//   ./tools/sim.sh tb_n64_top
//   python tools/n64/n64sim.py --system-check          (the screen against the model's)
//
// DDR3 is a model with latency and back-pressure. The VI runs at the board's
// rate (1587 clocks a half-line): with no caches yet a frame is only ~67k
// instructions, and a shorter one ended tests before they had finished.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_top;
	reg clk = 0, rst = 1, run = 0;
	always #10 clk = ~clk;

	reg  [21:0]  host_windex = 0; reg host_we = 0; reg [31:0] host_wdata = 0; reg fill_end = 0;
	reg          hr_go = 0; reg [23:0] hr_line = 0;
	wire         hr_done; wire [127:0] hr_data;
	wire [23:0]  d_addr; wire d_req, d_we; wire [127:0] d_wdata; wire [15:0] d_wmask;
	reg          d_ready = 0, d_valid = 0; reg [127:0] d_rdata = 0;
	wire [31:0]  vi_status, vi_origin, vi_width, vi_yscale, dbg_pc, dbg_retired;
	reg          fbr_req = 0; reg [17:0] fbr_word = 0;
	reg  [15:0]  joy1 = 16'd0, stick1 = 16'd0;    // controller 1 (the bench's +JOY/+STICK can set them)
	wire         fbr_ack; wire [31:0] fbr_rdata; wire [17:0] fb_words; wire [15:0] fb_wpr; wire fb_halve;

	// HDMI: a pixel clock of its own (unrelated to clk, as on the board) and the transmitter
	// asking for pixels; the video lines fetched are counted
	reg pclk = 0; always #20 pclk = ~pclk;
	wire [9:0] vid_x, vid_y; wire vid_req; wire [23:0] vid_rgb;
	hdmi_tx #(.SIM(1)) u_hdmi (.clk50(1'b0), .rst(1'b0), .sim_pclk(pclk), .ext_pclk(1'b0), .ext_pclk5(1'b0), .ext_locked(1'b0),
		.pclk(), .x(vid_x), .y(vid_y), .req(vid_req), .rgb(vid_rgb), .frame_start(), .tmds_p(), .tmds_n(), .tmds_clk_p(), .tmds_clk_n(),
		.sym_0(), .sym_1(), .sym_2(), .aud_l(16'd0), .aud_r(16'd0), .aud_tog(1'b0));
	n64_top #(.HALFLINE(11'd1587)) dut (
		.clk(clk), .rst(rst), .run(run),
		.host_windex(host_windex), .host_we(host_we), .host_wdata(host_wdata), .fill_end(fill_end),
		.hr_go(hr_go), .hr_line(hr_line), .hr_done(hr_done), .hr_data(hr_data),
		.d_addr(d_addr), .d_req(d_req), .d_we(d_we), .d_wdata(d_wdata), .d_wmask(d_wmask),
		.d_ready(d_ready), .d_rdata(d_rdata), .d_valid(d_valid), .d_calibrated(1'b1),
		.joy1(joy1), .vi_status(vi_status), .vi_origin(vi_origin), .vi_width(vi_width), .vi_yscale(vi_yscale),
		.dbg_pc(dbg_pc), .dbg_retired(dbg_retired), .dbg_sel(32'd0), .dbg_q(), .vi_slow(1'b0),
		.fbr_req(fbr_req), .fbr_word(fbr_word), .fbr_ack(fbr_ack), .fbr_rdata(fbr_rdata),
		.fb_words(fb_words), .fb_wpr(fb_wpr), .fb_halve(fb_halve),
		.stick1(stick1), .pad_present(4'b0001), .eep_size(2'd0),
		.eh_we(1'b0), .eh_addr(11'd0), .eh_wdata(8'd0), .eh_rdata(),
		.audio_lr(), .audio_lr_we(),
		.pclk(pclk), .vid_x(vid_x), .vid_y(vid_y), .vid_req(vid_req), .vid_rgb(vid_rgb)
	);

	// --- DDR3: RDRAM (8 MB) at line 0, the cartridge (16 MB) at line 0x100000 -----------
	reg [127:0] rdram [0:524287];
	reg [127:0] cart  [0:1048575];
	integer i;
	initial begin
		for (i = 0; i < 524288; i = i + 1) rdram[i] = 128'd0;
		for (i = 0; i < 1048576; i = i + 1) cart[i] = 128'd0;
	end
	reg [31:0] rnd = 32'hC0FF_EE11;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
	localparam LAT = 12;
	reg [23:0] q_a [0:LAT-1]; reg q_v [0:LAT-1]; reg [127:0] q_d [0:LAT-1];
	initial for (i = 0; i < LAT; i = i + 1) begin q_v[i] = 0; q_a[i] = 0; q_d[i] = 0; end
	integer mk, rdram_writes = 0;
	always @(posedge clk) begin
		d_ready <= (rnd[1:0] != 2'b00);
		d_valid <= q_v[LAT-1];
		// (a read is answered with memory as it was when the read was taken, as DDR3 does: a
		// write taken after it is not in it)
		d_rdata <= q_d[LAT-1];
		for (mk = LAT-1; mk > 0; mk = mk - 1) begin q_v[mk] <= q_v[mk-1]; q_a[mk] <= q_a[mk-1]; q_d[mk] <= q_d[mk-1]; end
		q_v[0] <= 1'b0;
		if (d_req && d_ready) begin
			if (d_we) begin
				for (mk = 0; mk < 16; mk = mk + 1) if (d_wmask[mk]) begin
					if (d_addr >= 24'h10_0000) cart[d_addr - 24'h10_0000][8 * mk +: 8] <= d_wdata[8 * mk +: 8];
					else rdram[d_addr[18:0]][8 * mk +: 8] <= d_wdata[8 * mk +: 8];
				end
				if (d_addr < 24'h10_0000) rdram_writes = rdram_writes + 1;
			end else begin
				q_v[0] <= 1'b1; q_a[0] <= d_addr;
				q_d[0] <= (d_addr >= 24'h10_0000) ? cart[d_addr - 24'h10_0000] : rdram[d_addr[18:0]];
			end
		end
	end

	// --- the HDMI picture's fetch: every line n64_top puts in n64_vid's buffer must be the
	// RDRAM line it is meant to be (its lines come back pipelined, tagged, among other reads)
	integer vid_lines = 0, vid_bad = 0;
	always @(posedge clk) if (dut.hv_we) begin
		vid_lines = vid_lines + 1;
		if (dut.hv_wd !== rdram[dut.hv_base[22:4] + {12'd0, dut.hv_wa[6:0]}]) begin
			vid_bad = vid_bad + 1;
			if (vid_bad <= 5) $display("tb_n64_top: picture line %0d of source line %0d is %032x, RDRAM has %032x",
			                           dut.hv_wa[6:0], dut.hv_line, dut.hv_wd, rdram[dut.hv_base[22:4] + {12'd0, dut.hv_wa[6:0]}]);
		end
	end
	// --- the D-cache: every line put in it (a fill, or the prefetch's) is memory as it is now
	integer dc_in = 0, dc_pf = 0, dc_bad = 0;
	always @(posedge clk) if (!rst && (dut.dw_fill || dut.dw_pf)) begin
		dc_in = dc_in + 1; if (dut.dw_pf) dc_pf = dc_pf + 1;
		if (d_rdata !== rdram[dut.dw_fill ? dut.line_of(dut.d_for) : dut.pf_line]) begin
			dc_bad = dc_bad + 1;
			if (dc_bad <= 5) $display("tb_n64_top: D-cache line %s at %06x is not memory", dut.dw_pf ? "prefetched" : "filled",
			                          dut.dw_fill ? dut.line_of(dut.d_for) : dut.pf_line);
		end
	end

	// --- the RSP's posted DMA writes: each line handed over reaches the memory as it was, in
	// order, and no read is issued while one of them is still queued
	reg [167:0] rwm [0:4095]; integer rwm_in = 0, rwm_out = 0, rwm_bad = 0, rwm_early = 0;
	reg d_req_was = 0, rw_empty_was = 1;
	always @(posedge clk) if (!rst) begin
		if (dut.rd_wr_req && !dut.rd_wr_ack && !dut.rw_full) begin
			rwm[rwm_in % 4096] = {dut.rd_wr_line, dut.rd_wr_mask, dut.rd_wr_data}; rwm_in = rwm_in + 1;
		end
		if (dut.st == dut.S_RWRITE && d_req && d_ready) begin
			if ({d_addr, d_wmask, d_wdata} !== rwm[rwm_out % 4096]) begin
				rwm_bad = rwm_bad + 1;
				if (rwm_bad <= 5) $display("tb_n64_top: RSP write %0d reached memory as %06x/%04x, was handed over as %06x/%04x",
				                           rwm_out, d_addr, d_wmask, rwm[rwm_out % 4096][167:144], rwm[rwm_out % 4096][143:128]);
			end
			rwm_out = rwm_out + 1;
		end
		// a read chosen (its request rising) while an RSP write was already queued
		if (d_req && !d_req_was && !d_we && !rw_empty_was) rwm_early = rwm_early + 1;
		d_req_was = d_req; rw_empty_was = dut.rw_empty;
	end

	// +VIDTEST (with +JUNK1 +PRELOAD1): VI pointed at a 320-wide 16-bit picture at 1 MB from
	// the start, while the game boots alongside; three HDMI frames of fetches checked
	integer vframes = 0; reg [9:0] vy_was = 0;
	always @(posedge pclk) begin vy_was <= vid_y; if (vid_y == 10'd0 && vy_was != 10'd0) vframes = vframes + 1; end
	initial if ($test$plusargs("VIDTEST")) begin
		wait (!rst); repeat (20) @(posedge clk);
		dut.vi[0] = 32'h0000_3002; dut.vi[1] = 32'h0010_0000; dut.vi[2] = 32'd320;
		wait (vframes >= 4);
		$display("tb_n64_top: VIDTEST %0d picture lines fetched, %0d wrong (one HDMI frame wants 9,600)", vid_lines, vid_bad);
		if (vid_bad == 0 && vid_lines >= 2 * 9600) $display("=== tb_n64_top passed ===");
		else $display("*** tb_n64_top FAILED ***");
		$finish;
	end

	// --- the run --------------------------------------------------------------------------
	reg [31:0] words [0:4194303];          // the cartridge, as the PC sends it: little-endian 32-bit words
	integer nwords, frames = 0, last_frame = 0, last_wr = 0, quiet = 0;
	time    t_run = 0;
	reg [9:0] prev_line = 0;
	always @(posedge clk) begin
		prev_line <= dut.vi_line;
		if (dut.vi_line == 10'd0 && prev_line != 10'd0) frames = frames + 1;
	end
	// (TRACERQ: every pipelined read taken and every line back, once the RSP has started a DMA)
	reg trq = 0; integer trq_n = 0;
	initial trq = $test$plusargs("TRACERQ");
	reg trq_on = 0;
	always @(posedge clk) if (dut.rd_rd_req) trq_on <= 1;
	always @(posedge clk) if (trq && trq_n < 600 && trq_on) begin
		if (dut.st == 5'd19 && d_ready) begin $display("%0t RQ taken own %0d addr %06x out %0d", $time, dut.rq_own, d_addr, dut.rdp_out); trq_n = trq_n + 1; end
		if (d_valid) begin $display("%0t line back: out %0d tag %0d st %0d", $time, dut.rdp_out, dut.rq_tag[dut.rq_tr], dut.st); trq_n = trq_n + 1; end
		if (dut.x_flush) begin $display("%0t flush", $time); trq_n = trq_n + 1; end
		if (dut.u_rsp_ra.restart) begin $display("%0t restart at %05x (live %0d n %05x r %05x drop %0d)", $time, dut.u_rsp_ra.c_line, dut.u_rsp_ra.live, dut.u_rsp_ra.n, dut.u_rsp_ra.r, dut.u_rsp_ra.drop); trq_n = trq_n + 1; end
		if (dut.x_ack) begin $display("%0t ack line", $time); trq_n = trq_n + 1; end
	end

	// an undefined value reaching memory is a bug somewhere before it: say where
	reg xseen = 0;
	always @(negedge clk) if (!xseen && dut.c_dreq && dut.c_dwe && (^dut.c_dwdata === 1'bx)) begin
		xseen = 1;
		$display("tb_n64_top: an UNDEFINED store at %0t: address %08x be %02x data %016x, pc %08x",
		         $time, dut.c_daddr, dut.c_dbe, dut.c_dwdata, dut.cpu.m_pc);
	end
	always @(negedge clk) if (!xseen && dut.c_dready && dut.d_from_cache && dut.cpu.w_valid && dut.cpu.w_mem && (^dut.c_drdata === 1'bx)) begin
		xseen = 1;
		$display("tb_n64_top: an UNDEFINED cached load answer at %0t: address %08x, line %0d, pc %08x",
		         $time, dut.dpa, dut.dpa[12:4], dut.cpu.w_pc);
	end

	// every sample the AI takes, for tools/n64/n64aitest.py's comparison with the model
	integer af;
	initial af = $fopen("../../sim/n64/ai.trace", "w");
	always @(posedge clk)
		if (dut.ai_pend && !dut.ai_we && dut.ai_count != 2'd0 && dut.ai_len0 != 18'd0 && dut.ai_enable
		    && dut.al_v && dut.al_tag == dut.ai_a[22:4]) $fwrite(af, "%08x\n", dut.ai_word);

	// the retire trace, in tools/n64/n64sim.py's format, for comparison with the model
	integer f, tf, sbad, sw, maxf, maxi;
	reg [31:0] pjoy;
	reg [23:0] sa; reg [31:0] sexp;
	initial tf = $fopen("../../sim/n64/sys.trace", "w");
	always @(posedge clk) begin
		if (dut.tr_exc) $fwrite(tf, "X %02x\n", dut.tr_code);
		if (dut.tr_valid) begin
			if (dut.tr_we) $fwrite(tf, "%08x %02d %016x\n", dut.tr_pc, dut.tr_rd, dut.tr_val);
			else           $fwrite(tf, "%08x\n", dut.tr_pc);
		end
	end
	initial begin
		for (i = 0; i < 4194304; i = i + 1) words[i] = 32'hxxxx_xxxx;
		$readmemh("../../sim/n64/cart.hex", words);
		nwords = 0; while (nwords < 4194304 && words[nwords] !== 32'hxxxx_xxxx) nwords = nwords + 1;
		$display("tb_n64_top: cartridge %0d words", nwords);
		repeat (5) @(posedge clk); rst = 0;
		// JUNK1: RDRAM full of leftovers, as the board's is after another program
		if ($test$plusargs("JUNK1")) for (i = 0; i < 524288; i = i + 1)
			rdram[i] = {i[31:0] * 32'h9E3779B1, i[31:0] ^ 32'hA5A5_1234, ~i[31:0] * 32'h85EB_CA6B, i[31:0] + 32'hDEAD_BEEF};
		// PRELOAD1: the cartridge straight into DDR3, for a game too big to fill
		// through the host's port in reasonable simulated time
		if ($test$plusargs("PRELOAD1")) begin
			for (i = 0; i < nwords; i = i + 1) cart[i >> 2][32 * (i & 3) +: 32] = words[i];
			$display("tb_n64_top: preloaded %0d words; line 0 %032x", nwords, cart[0]);
			nwords = 0;
		end
		// the host's fill: a word a clock is faster than the network, which is fine
		for (i = 0; i < nwords; i = i + 1) begin
			@(negedge clk); host_we = 1; host_windex = i; host_wdata = words[i];
			@(negedge clk); host_we = 0;
			repeat (3) @(negedge clk);       // leave the port time to write each line
		end
		if (!$test$plusargs("PRELOAD1")) begin @(negedge clk); fill_end = 1; @(negedge clk); fill_end = 0; end   // (an empty fill would flush a zero line)
		repeat (200) @(negedge clk);
		$display("tb_n64_top: filled; run at %0t", $time);
		run = 1; t_run = $time;
		// controller 1 (+JOY=hex buttons, +STICK=hex X,Y), and a fixed length (+FRAMES=n)
		// for a program that never stops drawing
		if ($value$plusargs("JOY%h", pjoy)) joy1 = pjoy[15:0];
		if ($value$plusargs("STICK%h", pjoy)) stick1 = pjoy[15:0];
		if (!$value$plusargs("FRAMES%d", maxf)) maxf = 0;
		if (!$value$plusargs("MAXI%d", maxi)) maxi = 0;      // stop after this many instructions
		// the end: two frames with no RDRAM write after the boot's copy is done
		while ((quiet < 2 || dbg_retired < 1000) && !(maxf != 0 && frames >= maxf) && !(maxi != 0 && dbg_retired >= maxi)) begin
			@(posedge clk);
			if (frames != last_frame) begin
				quiet = (rdram_writes == last_wr) ? quiet + 1 : 0;
				last_frame = frames; last_wr = rdram_writes;
				if (frames % 10 == 0) $display("  frame %0d: %0d retired, pc %08x", frames, dbg_retired, dbg_pc);
			end
		end
		$display("tb_n64_top: done after %0d instructions, VI origin %08x width %0d status %08x", dbg_retired, vi_origin, vi_width, vi_status);
		$display("tb_n64_top: pipelined reads out %0d, arbiter %0d; RSP read-ahead live %0d b %05x n %05x r %05x drop %0d; DMA busy %0d, RSP halted %0d, rd_rd req %0d ack %0d, flush_p %0d",
		         dut.rdp_out, dut.st, dut.u_rsp_ra.live, dut.u_rsp_ra.b, dut.u_rsp_ra.n, dut.u_rsp_ra.r, dut.u_rsp_ra.drop,
		         dut.u_rsp.dma_busy, dut.u_rsp.halted, dut.rd_rd_req, dut.rd_rd_ack, dut.x_flush_p);
		$display("tb_n64_top: %0d clocks since run, %0d frames; %0d video lines fetched", ($time - t_run) / 20, frames, vid_lines);
		$display("tb_n64_top: D-cache lines put in %0d (%0d prefetched), %0d not memory%s", dc_in, dc_pf, dc_bad, dc_bad ? " -- FAIL" : "");
		$display("tb_n64_top: RSP DMA writes: %0d handed over, %0d written, %0d wrong; %0d reads issued past a queued one%s",
		         rwm_in, rwm_out, rwm_bad, rwm_early, (rwm_bad || rwm_early) ? " -- FAIL" : "");
		// the frame stream's port: words of the picture, against RDRAM at the VI's origin
		sbad = 0;
		for (i = 0; i < (fb_words != 0 ? 3000 : 0); i = i + 1) begin
			sw = (i < 2000) ? i : (fb_words - 1 - (i - 2000));      // the start, and the end of the frame
			@(negedge clk); fbr_word = sw; fbr_req = 1;
			while (!fbr_ack) @(negedge clk);
			sa = vi_origin[23:0] + 4 * sw;
			sexp = {rdram[sa >> 4][8 * (sa[3:0]) +: 8], rdram[sa >> 4][8 * (sa[3:0] + 1) +: 8],
			        rdram[sa >> 4][8 * (sa[3:0] + 2) +: 8], rdram[sa >> 4][8 * (sa[3:0] + 3) +: 8]};
			if (fbr_rdata !== sexp) begin
				sbad = sbad + 1;
				if (sbad < 5) $display("tb_n64_top: stream word %0d is %08x, RDRAM has %08x", sw, fbr_rdata, sexp);
			end
			fbr_req = 0; @(negedge clk);
		end
		$display("tb_n64_top: the stream port: %0d words a frame, %0d a row%s; %0s",
		         fb_words, fb_wpr, fb_halve ? " (every other row)" : "", sbad ? "FAIL" : "3000 words read right");
		f = $fopen("../../sim/n64/sys_rdram.hex", "w");
		for (i = 0; i < 524288; i = i + 1) $fwrite(f, "%032x\n", rdram[i]);
		$fclose(f);
		$finish;
	end
	initial begin
		#(64'd20_000_000_000);
		$display("tb_n64_top: TIMED OUT, %0d retired, pc %08x", dbg_retired, dbg_pc);
		$finish;
	end
endmodule

`default_nettype wire
