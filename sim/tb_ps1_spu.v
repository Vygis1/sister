//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_spu - the SPU against its reference model, sample for sample.
//
// tools/ps1/spu_ref.py writes sim/spu_test/: a sample bank (ram.hex), a register
// script (script.hex: {tick, offset, value}), and every output sample the model
// makes (expect.hex) plus ENDX at the end. This uploads the bank the way a game
// does -- TSA, transfer mode "DMA write", words through the DMA port -- into a
// DDR3-shaped memory with latency and back-pressure, then plays the script and
// checks every {right, left} the SPU produces against the model's.
//
// The bank goes in through the FIFO and the write-combiner, so the transfer path
// is tested by the sound coming out right, not by peeking at memory.
//
//   python tools/ps1/spu_ref.py && ./tools/sim.sh tb_ps1_spu
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_ps1_spu;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	localparam TICKS = 2500;
	localparam [23:0] SPU_LINE = 24'h08_0000;

	reg        sel = 0, we = 0;
	reg [9:0]  addr = 0;
	reg [3:0]  be = 0;
	reg [31:0] wdata = 0;
	wire [31:0] rdata;
	reg        tick = 0;
	wire       irq;
	reg        dma_wr = 0; reg [31:0] dma_wdata = 0; wire dma_ready;
	wire [31:0] dma_rdata; wire dma_rvalid;
	wire [23:0] m_addr; wire m_req, m_we; wire [127:0] m_wdata; wire [15:0] m_wmask;
	reg         m_ready = 0; reg [127:0] m_rdata = 0; reg m_valid = 0;
	wire [31:0] out_lr; wire out_we;
	// CD audio in: a known value every tick. The script never sets SPUCNT bit 0, so
	// none of it reaches the mix -- but the capture buffers take it anyway, as the
	// chip's do (psx-spx: CD capture is always active)
	reg  [15:0] cdl = 16'h0000, cdr = 16'h0000;

	ps1_spu #(.SPU_LINE(SPU_LINE)) dut (
		.clk(clk), .rst(rst),
		.sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata),
		.tick(tick), .cd_l(cdl), .cd_r(cdr), .irq(irq),
		.dma_wr(dma_wr), .dma_wdata(dma_wdata), .dma_ready(dma_ready),
		.dma_rd(1'b0), .dma_rdata(dma_rdata), .dma_rvalid(dma_rvalid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid),
		.out_lr(out_lr), .out_we(out_we)
	);

	// --- DDR3, as the arbiter presents it: accept when ready, reads in order -------
	reg [127:0] mem [0:32767];
	integer k;
	initial for (k = 0; k < 32768; k = k + 1) mem[k] = 128'd0;
	reg [31:0] rnd = 32'hACE1_2468;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};
	localparam LAT = 24;
	reg [14:0] q_a [0:LAT-1]; reg q_v [0:LAT-1];
	initial for (k = 0; k < LAT; k = k + 1) begin q_v[k] = 0; q_a[k] = 0; end
	integer mwrites = 0, mreads = 0;
	integer mk;   // its own: sharing the bench's `k` rewrote the upload's loop counter every clock
	always @(posedge clk) begin
		m_ready <= (rnd[1:0] != 2'b00);            // a quarter of the time: busy
		m_valid <= q_v[LAT-1]; m_rdata <= mem[q_a[LAT-1]];
		for (mk = LAT-1; mk > 0; mk = mk - 1) begin q_v[mk] <= q_v[mk-1]; q_a[mk] <= q_a[mk-1]; end
		q_v[0] <= 1'b0;
		if (m_req && m_ready) begin
			if (m_we) begin
				mwrites = mwrites + 1;
				for (mk = 0; mk < 16; mk = mk + 1) if (m_wmask[mk]) mem[m_addr - SPU_LINE][mk*8 +: 8] <= m_wdata[mk*8 +: 8];
			end else begin
				mreads = mreads + 1;
				q_v[0] <= 1'b1; q_a[0] <= m_addr - SPU_LINE;
			end
		end
	end

	// --- the CPU's 16-bit accesses ----------------------------------------------------
	task w16; input [9:0] off; input [15:0] d; begin
		@(negedge clk);
		sel = 1; we = 1; addr = {off[9:2], 2'b00};
		be = off[1] ? 4'b1100 : 4'b0011; wdata = off[1] ? {d, 16'h0000} : {16'h0000, d};
		@(negedge clk);
		sel = 0; we = 0; be = 0;
	end endtask
	task r16; input [9:0] off; output [15:0] d; begin
		@(negedge clk);
		addr = {off[9:2], 2'b00};
		#1 d = off[1] ? rdata[31:16] : rdata[15:0];
	end endtask

	reg [31:0] ramw   [0:4095];
	reg [47:0] script [0:255];
	reg [31:0] expect [0:TICKS-1];
	reg [31:0] endx_x [0:0];
	integer nwords, nscript;
	integer errors = 0, got = 0;
	reg [15:0] st;

	// a trace of every voice with a volume, on the ticks named by +DBG=<tick>
	integer dbg_t = -1;
	initial if (!$value$plusargs("DBG=%d", dbg_t)) dbg_t = -1;
	always @(posedge clk) if (dut.es == 4'd10 && got >= dbg_t && got <= dbg_t + 1 && dut.w_vol != 0)
		$display("  rtl   t%0d v%-2d out %6d env %04h cnt %05h dec %2d need %0d ph %0d h [%0d, %0d, %0d, %0d] stall %0d",
		         got, dut.v, dut.w_out, dut.w_env, dut.w_cnt, dut.w_dec, dut.w_need, dut.w_ph, dut.h0, dut.h1, dut.h2, dut.h3, dut.w_stall);
	// every output sample, checked as it comes
	always @(posedge clk) if (out_we) begin
		if (got < TICKS && out_lr !== expect[got]) begin
			errors = errors + 1;
			if (errors <= 8) $display("  FAIL tick %0d: SPU gave %08h, the model %08h", got, out_lr, expect[got]);
		end
		got = got + 1;
	end

	integer t, si, c, nz;

	// --- the capture buffers: what each tick should leave in SPU RAM -------------------
	// CD left at 000h, CD right at 400h, voice 1 at 800h, voice 3 at C00h, a halfword a
	// tick at position 0..511 (DuckStation's WriteToCaptureBuffers). The CD values are
	// this bench's own; the voices' are the SPU's voice outputs of that tick.
	reg  [15:0] cap_x [0:3][0:511];
	reg         cap_seen [0:511];
	integer     ncap = 0, cap_prev = -1, cap_seq_bad = 0, ci, ck;
	initial for (ci = 0; ci < 512; ci = ci + 1) cap_seen[ci] = 1'b0;
	always @(posedge clk) if (dut.es == 5'd30 && dut.spucnt[15]) begin
		cap_x[0][dut.cap_i] <= cdl; cap_x[1][dut.cap_i] <= cdr;
		cap_x[2][dut.cap_i] <= dut.v1_out; cap_x[3][dut.cap_i] <= dut.v3_out;
		cap_seen[dut.cap_i] <= 1'b1;
		if (cap_prev >= 0 && dut.cap_i != ((cap_prev + 1) % 512)) cap_seq_bad = cap_seq_bad + 1;
		cap_prev = dut.cap_i; ncap = ncap + 1;

	end
	// and every capture write as it goes out, so a voice that sounds only for a
	// while is checked while it does (the buffers end up holding the last lap only)
	integer     capw = 0, capw_bad = 0, capw_v1 = 0, cw_line, cw_j, cw_pos;
	always @(posedge clk) if (m_req && m_ready && m_we && dut.m_kind == 2'd3) begin
		cw_line = m_addr - SPU_LINE;
		cw_j = 0; for (mk = 0; mk < 8; mk = mk + 1) if (m_wmask == (16'b11 << (2 * mk))) cw_j = mk + 8;
		cw_pos = (cw_line % 64) * 8 + (cw_j - 8);
		capw = capw + 1;
		if (cw_line >= 256 || cw_j < 8 || m_wdata[(cw_j - 8) * 16 +: 16] !== cap_x[cw_line / 64][cw_pos]) begin
			capw_bad = capw_bad + 1;
			if (capw_bad <= 6) $display("  FAIL capture write: line %0d mask %04h data %04h, want %04h", cw_line, m_wmask,
			                            m_wdata[(cw_j - 8) * 16 +: 16], cap_x[cw_line / 64][cw_pos]);
		end
		if (cw_line / 64 == 2 && m_wdata[(cw_j - 8) * 16 +: 16] != 0) capw_v1 = capw_v1 + 1;
	end
	function [15:0] spu_hw; input integer byte_addr;
		spu_hw = mem[byte_addr >> 4][(byte_addr & 15) * 8 +: 16];
	endfunction
	initial begin
		#(64'd200_000_000);
		$display("tb_ps1_spu: TIMED OUT (samples %0d, dma_ready %b, fifo level %0d, wc_valid %b wc_flush %b m_req %b es %0d)",
		         got, dma_ready, dut.f_level, dut.wc_valid, dut.wc_flush, m_req, dut.es);
		$finish;
	end
	initial begin
		for (k = 0; k < 4096; k = k + 1) ramw[k] = 32'hxxxx_xxxx;
		for (k = 0; k < 256; k = k + 1) script[k] = 48'hFFFF_FFFF_FFFF;
		$readmemh("../../sim/spu_test/ram.hex", ramw);
		$readmemh("../../sim/spu_test/script.hex", script);
		$readmemh("../../sim/spu_test/expect.hex", expect);
		$readmemh("../../sim/spu_test/endx.hex", endx_x);
		nwords = 0; while (nwords < 4096 && ramw[nwords] !== 32'hxxxx_xxxx) nwords = nwords + 1;
		nscript = 0; while (nscript < 256 && script[nscript] !== 48'hFFFF_FFFF_FFFF) nscript = nscript + 1;
		$display("tb_ps1_spu: %0d words of samples, %0d register writes, %0d ticks", nwords, nscript, TICKS);

		repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);

		// --- the upload, as libspu does it --------------------------------------------
		w16(10'h1AA, 16'h0000);                       // transfer mode: stop
		w16(10'h1A6, 16'h1000 >> 3);                  // TSA = 1000h
		w16(10'h1AA, 16'h0020);                       // DMA write
		r16(10'h1AE, st);
		if (st[5:0] !== 6'h20) begin $display("  FAIL SPUSTAT does not mirror SPUCNT: %04h", st); errors = errors + 1; end
		for (k = 0; k < nwords; k = k + 1) begin
			@(negedge clk); while (!dma_ready) @(negedge clk);
			dma_wr = 1; dma_wdata = ramw[k];
			@(negedge clk); dma_wr = 0;
			repeat (3) @(negedge clk);                    // the DMA spends a few clocks a word
			if (k % 1024 == 1023) $display("    uploaded %0d words", k + 1);
		end
		$display("    upload done at %0t", $time);
		// wait for the transfer to be done, as SpuIsTransferCompleted does
		c = 0;
		begin : busy_wait
			forever begin r16(10'h1AE, st); if (!st[10]) disable busy_wait; c = c + 1; if (c > 100000) disable busy_wait; end
		end
		if (st[10]) begin $display("  FAIL SPUSTAT busy never cleared"); errors = errors + 1; end
		repeat (100) @(posedge clk);                    // the last line goes out after a moment
		w16(10'h1AA, 16'h0000);

		// --- the script, a tick at a time ------------------------------------------
		si = 0;
		for (t = 0; t <= TICKS; t = t + 1) begin
			while (si < nscript && script[si][47:32] == t) begin
				w16(script[si][25:16], script[si][15:0]); si = si + 1;
			end
			if (t == TICKS) t = TICKS + 1;
			else begin
				cdl = 16'h1000 + t * 7; cdr = 16'h8000 - t * 13;
				@(negedge clk); tick = 1; @(negedge clk); tick = 0;
				if (t % 500 == 0) $display("    tick %0d, %0d samples out, %0d mismatches", t, got, errors);
				repeat (1130) @(posedge clk);
			end
		end
		repeat (2000) @(posedge clk);

		r16(10'h19C, st);
		$display("  %0d samples out; DDR3: %0d line writes, %0d line reads; ENDX %04h (model %04h)",
		         got, mwrites, mreads, st, endx_x[0][15:0]);
		if (st !== endx_x[0][15:0]) begin $display("  FAIL ENDX"); errors = errors + 1; end
		if (got != TICKS) begin $display("  FAIL %0d samples for %0d ticks", got, TICKS); errors = errors + 1; end
		nz = 0; for (k = 0; k < TICKS; k = k + 1) if (expect[k] != 0) nz = nz + 1;
		if (nz < TICKS / 2) begin $display("  FAIL the model's output is mostly silence: the test proves nothing"); errors = errors + 1; end
		// the capture buffers, read out of the memory the SPU wrote them to
		c = 0;
		for (ci = 0; ci < 512; ci = ci + 1) if (cap_seen[ci])
			for (ck = 0; ck < 4; ck = ck + 1)
				if (spu_hw(ck * 1024 + ci * 2) !== cap_x[ck][ci]) begin
					c = c + 1;
					if (c <= 6) $display("  FAIL capture buffer %0d position %0d: %04h, want %04h", ck, ci, spu_hw(ck * 1024 + ci * 2), cap_x[ck][ci]);
				end
		errors = errors + c;
		$display("  capture: %0d ticks, %0d writes (%0d wrong, %0d of voice 1 sounding); in memory at the end %0d wrong; %0d out of sequence",
		         ncap, capw, capw_bad, capw_v1, c, cap_seq_bad);
		errors = errors + capw_bad;
		if (capw != 4 * ncap) begin $display("  FAIL capture: %0d writes for %0d ticks", capw, ncap); errors = errors + 1; end
		if (ncap < 512) begin $display("  FAIL capture: fewer ticks than one lap of the buffers"); errors = errors + 1; end
		if (cap_seq_bad) begin $display("  FAIL capture: the position did not step by one a tick"); errors = errors + 1; end
		if (capw_v1 < 30) begin $display("  FAIL capture: voice 1 never sounded, its writes prove nothing (%0d)", capw_v1); errors = errors + 1; end
		// the IRQ address on a capture position: the interrupt comes when the
		// buffers are written there, and not before
		w16(10'h1AA, 16'hC000);                                   // IRQ off: acknowledge
		c = (dut.cap_i + 8) & 9'h1FC;                             // a position a few ticks ahead, 8-byte aligned
		w16(10'h1A4, (16'd2 << 7) | (c >> 2));                    // in the voice-1 buffer
		w16(10'h1AA, 16'hC040);                                   // IRQ on
		nz = 0;
		for (t = 0; t < 20 && !irq; t = t + 1) begin
			if (dut.cap_i == c) nz = 1;                           // reached it
			@(negedge clk); tick = 1; @(negedge clk); tick = 0; repeat (1130) @(posedge clk);
		end
		if (!irq) begin $display("  FAIL capture IRQ: none at position %0d", c); errors = errors + 1; end
		else if (!nz && dut.cap_i != ((c + 1) & 9'h1FF)) begin $display("  FAIL capture IRQ: early, at position %0d for %0d", dut.cap_i, c); errors = errors + 1; end
		else $display("  capture IRQ at position %0d", c);
		if (errors == 0) $display("tb_ps1_spu: all checks passed -- every sample matches the model, and the capture buffers");
		else             $display("tb_ps1_spu: FAIL -- %0d mismatches", errors);
		$finish;
	end
endmodule

`default_nettype wire
