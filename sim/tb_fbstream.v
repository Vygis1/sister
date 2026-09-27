//////////////////////////////////////////////////////////////////////////////////
// tb_fbstream - is every frame the network sends ONE capture, whole?
//
// The picture on the page kept restarting part way down: the top of it was the
// frame that had just been captured and the bottom was the NEXT capture
// starting again from its first row, with the black rows above the game's
// drawing area appearing as a band through the middle. Measured on the board
// 2026-09-26, Crash in N. Sanity Beach: 75% of consecutive frames needed a
// 61-row vertical shift to line up with each other, and 39% carried a band.
//
// The cause was a handshake, not the picture: `want` was cleared when a capture
// STARTED, and the scanout's enable was `want || !full_frame`, so the clock
// after a capture finished the enable passed again and the next one began --
// full_frame was high for a single clock. A network core that started sending
// in that clock then read a buffer being rewritten from the top underneath it.
//
// So this drives the real loop. Every capture stamps its own number into every
// pixel, the network side reads words slowly and with gaps as the real one
// does, and the check is simply: every word of a delivered frame carries the
// SAME capture number and the pixels are in order from the first. A frame made
// of two captures fails, and says where it was spliced.
//
// Captures are aborted at random too: an abort produces no frame_done, and the
// scanout has to be free to start again or the picture stops for good.
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

	reg         frame_start = 0, frame_done = 0, px_valid = 0;
	reg  [9:0]  px_x = 0;
	reg  [15:0] px_rgb = 0;
	wire        hold;
	reg         rd_en = 0;
	wire [31:0] rd_data;
	wire        rd_valid;
	reg         arm = 0;
	wire        want, empty, full_frame;

	fb_stream #(.AW(16)) dut (
		.clk(clk), .rst(rst),
		.frame_start(frame_start), .frame_done(frame_done),
		.px_valid(px_valid), .px_x(px_x), .px_rgb(px_rgb), .hold(hold),
		.rd_en(rd_en), .rd_data(rd_data), .rd_valid(rd_valid),
		.arm(arm), .want(want), .empty(empty), .full_frame(full_frame)
	);

	// This is the board's enable, from ps1_top.v: the capture may run when the
	// stream wants one. Nothing else -- adding "or no whole frame is waiting"
	// is exactly the bug.
	wire scan_enable = want;

	integer errors = 0;
	task check; input c; input [511:0] what; begin
		if (c) $display("  ok   %0s", what); else begin $display("  FAIL %0s", what); errors = errors + 1; end
	end endtask

	// --- the scanout -------------------------------------------------------
	integer cap_id = 0, aborted = 0, finished = 0;
	integer p;
	reg [31:0] rnd = 32'h2468_ACE0;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};

	task run_capture;
		integer stop_at;
		begin
			cap_id = (cap_id + 1) & 15;
			// one capture in five is abandoned part way, as a buffer flip does
			stop_at = (rnd[7:5] == 3'd0) ? (200 + (rnd[19:8] % (NPIX - 400))) : NPIX;
			@(negedge clk);
			frame_start = 1;
			@(negedge clk);
			frame_start = 0;
			for (p = 0; p < stop_at; p = p + 1) begin
				while (hold) @(negedge clk);
				px_valid = 1;
				px_x     = p % W;
				px_rgb   = {cap_id[3:0], p[11:0]};
				@(negedge clk);
				px_valid = 0;
				// the scanout does not produce a pixel every clock
				if (rnd[3:2] == 2'd0) @(negedge clk);
			end
			if (stop_at == NPIX) begin
				frame_done = 1;
				@(negedge clk);
				frame_done = 0;
				finished = finished + 1;
			end else begin
				aborted = aborted + 1;
			end
		end
	endtask

	initial begin
		while (1) begin
			@(negedge clk);
			if (scan_enable) run_capture;
		end
	end

	// --- the network side --------------------------------------------------
	// Starts only when a whole frame is waiting, reads WORDS words with gaps
	// between packets, then arms the next capture.
	integer frames_sent = 0, spliced = 0, shown = 0;
	integer k, gap;
	integer first_id, seam;
	reg [31:0] w32;
	reg [15:0] lo16, hi16;

	initial begin
		@(negedge clk);
		while (1) begin
			@(negedge clk);
			if (full_frame) begin
				first_id = -1;
				seam     = -1;
				for (k = 0; k < WORDS; k = k + 1) begin
					// wait for a word, as the real core does
					while (!rd_valid) @(negedge clk);
					w32  = rd_data;
					rd_en = 1;
					@(negedge clk);
					rd_en = 0;
					// The read port is registered: after the pointer moves the next
					// word needs a clock to appear. The real core spends four
					// cycles writing the word into its packet before asking for
					// another, which is what hides this. A consumer that reads
					// back to back gets the same word twice -- that is the
					// TESTBENCH being wrong, and it looked exactly like a splice.
					repeat (4) @(negedge clk);
					lo16 = w32[15:0];
					hi16 = w32[31:16];
					if (first_id < 0) first_id = lo16[15:12];
					if ((lo16[15:12] !== first_id[3:0]) || (hi16[15:12] !== first_id[3:0])
					    || (lo16[11:0] !== (2*k)) || (hi16[11:0] !== (2*k+1))) begin
						if (seam < 0) seam = k;
					end
					// a gap between packets, as the real core paces itself
					if (k % 350 == 349) for (gap = 0; gap < 40; gap = gap + 1) @(negedge clk);
				end
				frames_sent = frames_sent + 1;
				if (seam >= 0) begin
					spliced = spliced + 1;
					if (shown < 4) begin
						shown = shown + 1;
						$display("      frame %0d is two captures: it changes at word %0d of %0d (row %0d of %0d)",
						         frames_sent, seam, WORDS, (seam * 2) / W, H);
					end
				end
				// the frame has gone out
				@(negedge clk);
				arm = 1;
				@(negedge clk);
				arm = 0;
				// Deliberately NOT waiting for full_frame to fall. The real
				// network core does not wait either: it starts the next frame
				// the moment `stream_ready` is high, which it still is until
				// the next capture begins. If fb_stream hands out words in that
				// window the picture arrives rotated, so this models it.
			end
		end
	end

	// --- the run -----------------------------------------------------------
	integer stall, guard;
	initial begin
		repeat (4) @(posedge clk);
		rst = 0;
		// let it settle, then watch for a while
		wait (frames_sent >= 30);
		$display("  %0d captures finished, %0d abandoned part way, %0d frames sent",
		         finished, aborted, frames_sent);
		check(spliced == 0, "every frame the network sent is one capture, whole");
		if (spliced != 0)
			$display("      %0d of %0d frames were two captures stuck together", spliced, frames_sent);
		check(aborted > 0, "some captures were abandoned part way (the retry path was exercised)");

		// and it must not stop: after all that, a fresh frame still has to arrive
		stall = frames_sent;
		guard = 0;
		while (frames_sent <= stall + 2 && guard < 4000000) begin
			@(posedge clk); guard = guard + 1;
		end
		check(frames_sent > stall + 2, "frames keep coming -- the handshake does not deadlock");

		if (errors == 0) $display("tb_fbstream: all checks passed");
		else             $display("tb_fbstream: FAIL -- %0d checks failed", errors);
		$finish;
	end

	initial begin
		#900000000;
		$display("tb_fbstream: TIMED OUT (frames sent %0d)", frames_sent);
		$finish;
	end
endmodule

`default_nettype wire
