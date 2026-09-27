//////////////////////////////////////////////////////////////////////////////////
// tb_fbstream - is every frame the host would SHOW one capture, whole, in order?
//
// fb_stream is a queue a few packets deep now, not a frame buffer: the scanout
// reads the picture at the network's pace and the frame is put together on the
// PC from the id and offset each packet carries (see fb_stream.v). So this
// drives the real queue with:
//
//   - a scanout that stamps its capture number into every pixel, pauses at
//     random, abandons one capture in five part way (as a display flip does),
//     and now and then stalls for longer than the network core will wait;
//   - the network core's streamer, modelled rule for rule from net_core.v:
//     350-word packets, four clocks per word, a gap for the wire, the head of
//     the queue stale for two clocks after a take, stray words thrown away
//     between frames, a frame given up when a new capture's first word turns up
//     in the middle of it, and the one-millisecond timeout;
//   - the host, modelled from pc/server.py: words kept by (frame id, offset), a
//     frame shown only when every one of its words has arrived.
//
// Every shown frame must carry ONE capture number, with its pixels in order
// from the first. And frames must keep coming: the timeout path is where a
// handshake that waits for a signal that never comes would stop the picture.
//
//   ./tools/sim.sh tb_fbstream
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none
`timescale 1ns/1ps

module tb_fbstream;
	reg clk = 0, rst = 1;
	always #5 clk = ~clk;

	localparam W     = 256;               // pixels across
	localparam H     = 16;                // rows (short, so the test runs many frames)
	localparam NPIX  = W * H;
	localparam WORDS = NPIX / 2;
	localparam PKT   = 350;
	localparam TIMEOUT = 50000;           // net_core: a millisecond at 50 MHz

	reg         frame_start = 0, frame_done = 0, abort = 0, px_valid = 0;
	reg  [9:0]  px_x = 0;
	reg  [15:0] px_rgb = 0;
	wire        hold;
	reg         rd_en = 0;
	wire [31:0] rd_data;
	wire        rd_valid, head_sof;
	wire        want, empty;

	fb_stream #(.AW(11)) dut (
		.clk(clk), .rst(rst),
		.frame_start(frame_start), .frame_done(frame_done), .abort(abort),
		.px_valid(px_valid), .px_x(px_x), .px_rgb(px_rgb), .hold(hold),
		.rd_en(rd_en), .rd_data(rd_data), .rd_valid(rd_valid), .head_sof(head_sof),
		.arm(1'b0), .want(want), .empty(empty)
	);

	integer errors = 0;
	task check; input c; input [1023:0] what; begin
		if (c) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end
	end endtask

	// --- the scanout -------------------------------------------------------
	integer cap_id = 0, aborted = 0, finished = 0, stalls = 0;
	integer p, stop_at, stall_at;
	reg [31:0] rnd = 32'h2468_ACE0;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};

	task run_capture;
		begin
			cap_id = (cap_id + 1) & 15;
			// one capture in five is abandoned part way, as a buffer flip does
			stop_at  = (rnd[7:5] == 3'd0) ? (200 + (rnd[19:8] % (NPIX - 400))) : NPIX;
			// one in sixteen stalls longer than the network core will wait
			stall_at = (rnd[23:20] == 4'd0) ? (100 + (rnd[31:24] * 13) % (NPIX - 200)) : -1;
			@(negedge clk);
			frame_start = 1;
			@(negedge clk);
			frame_start = 0;
			for (p = 0; p < stop_at; p = p + 1) begin
				while (hold) @(negedge clk);
				if (p == stall_at) begin stalls = stalls + 1; repeat (TIMEOUT + 5000) @(negedge clk); end
				px_valid = 1;
				px_x     = p % W;
				px_rgb   = {cap_id[3:0], p[11:0]};
				@(negedge clk);
				px_valid = 0;
				if (rnd[3:2] == 2'd0) @(negedge clk);   // not a pixel every clock
			end
			if (stop_at == NPIX) begin
				frame_done = 1; @(negedge clk); frame_done = 0;
				finished = finished + 1;
			end else begin
				abort = 1; @(negedge clk); abort = 0;
				aborted = aborted + 1;
			end
		end
	endtask

	initial begin
		while (1) begin
			@(negedge clk);
			if (want && !rst) run_capture;
		end
	end

	// --- the host: words kept by (frame id, offset) -------------------------
	reg [31:0] hbuf [0:WORDS-1];
	reg        hgot [0:WORDS-1];
	integer    hfid = -1, hk;
	integer    shown = 0, spliced = 0, told = 0;
	task host_word; input integer fid; input integer off; input [31:0] w;
		integer first, seam, j;
		reg complete;
		begin
			if (fid != hfid) begin            // a new id: the old frame is forgotten
				hfid = fid;
				for (hk = 0; hk < WORDS; hk = hk + 1) hgot[hk] = 0;
			end
			hbuf[off] = w; hgot[off] = 1;
			complete = 1;
			for (hk = 0; hk < WORDS; hk = hk + 1) if (!hgot[hk]) complete = 0;
			if (complete) begin
				shown = shown + 1;
				first = hbuf[0][15:12]; seam = -1;
				for (j = 0; j < WORDS; j = j + 1)
					if (seam < 0 && (hbuf[j][15:12] !== first[3:0] || hbuf[j][31:28] !== first[3:0]
					                 || hbuf[j][11:0] !== (2*j) || hbuf[j][27:16] !== (2*j+1)))
						seam = j;
				if (seam >= 0) begin
					spliced = spliced + 1;
					if (told < 4) begin told = told + 1;
						$display("      shown frame %0d is not one capture in order: it goes wrong at word %0d of %0d",
						         shown, seam, WORDS); end
				end
				hfid = -1;
			end
		end
	endtask

	// --- the network core's streamer, rule for rule --------------------------
	integer st_off = 0, st_frame = 0, st_i, n, waited, gave_up_new = 0, gave_up_timeout = 0, dropped = 0;
	reg     abandon;
	reg [31:0] pkt [0:PKT-1];
	task take; begin
		rd_en = 1; @(negedge clk); rd_en = 0;
		repeat (2) @(negedge clk);           // the head is stale for two clocks after a take
	end endtask

	initial begin
		wait (!rst);
		while (1) begin
			@(negedge clk);
			if (st_off == 0 && rd_valid && !head_sof) begin
				take; dropped = dropped + 1;       // a stray between frames
			end else if (st_off != 0 || head_sof) begin
				// a packet
				n = (WORDS - st_off > PKT) ? PKT : (WORDS - st_off);
				repeat (56) @(negedge clk);        // the header
				abandon = 0;
				for (st_i = 0; st_i < n && !abandon; st_i = st_i + 1) begin
					waited = 0;
					while (!rd_valid && waited < TIMEOUT) begin @(negedge clk); waited = waited + 1; end
					if (!rd_valid) begin
						// a millisecond of nothing: give the frame up, new id
						abandon = 1; gave_up_timeout = gave_up_timeout + 1;
					end else if (head_sof && (st_off != 0 || st_i != 0)) begin
						// a new capture began: give this one up, new id, word left
						abandon = 1; gave_up_new = gave_up_new + 1;
					end else begin
						pkt[st_i] = rd_data;
						rd_en = 1; @(negedge clk); rd_en = 0;
						repeat (4) @(negedge clk);     // writing it into the packet
					end
				end
				if (abandon) begin
					st_off = 0; st_frame = st_frame + 1;
				end else begin
					repeat (300) @(negedge clk);        // on the wire
					for (st_i = 0; st_i < n; st_i = st_i + 1) host_word(st_frame, st_off + st_i, pkt[st_i]);
					if (st_off + n >= WORDS) begin st_off = 0; st_frame = st_frame + 1; end
					else st_off = st_off + n;
				end
			end
		end
	end

	// --- the run -----------------------------------------------------------
	integer mark, guard;
	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		wait (shown >= 40);
		$display("  captures: %0d finished, %0d abandoned, %0d stalled past the timeout", finished, aborted, stalls);
		$display("  network core: %0d frames shown, %0d given up for a new capture, %0d on the timeout, %0d stray words dropped",
		         shown, gave_up_new, gave_up_timeout, dropped);
		check(spliced == 0, "every frame the host shows is one capture, whole and in order");
		check(aborted > 0 && gave_up_new > 0, "abandoned captures were exercised, and the network core gave those frames up");
		check(gave_up_timeout > 0, "the one-millisecond timeout was exercised");
		check(shown * 10 >= finished * 6, "most finished captures reach the screen");
		mark = shown; guard = 0;
		while (shown <= mark + 3 && guard < 20000000) begin @(posedge clk); guard = guard + 1; end
		check(shown > mark + 3, "frames keep coming -- nothing waits for a signal that never comes");
		if (errors == 0) $display("tb_fbstream: all checks passed");
		else             $display("tb_fbstream: FAIL -- %0d checks failed", errors);
		$finish;
	end

	initial begin
		#(64'd4000000000);
		$display("tb_fbstream: TIMED OUT (shown %0d, finished %0d)", shown, finished);
		$finish;
	end
endmodule

`default_nettype wire
