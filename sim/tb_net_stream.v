`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_net_stream - the REAL network core streaming straight from the REAL
// fb_stream queue, read off the wire and put together the way the PC does it.
//
// tb_fbstream checks the queue against a model of the network core. This one
// uses the network core itself: frames go out as Ethernet on the RMII pins, are
// decoded with rmii_rx, and every "FS" slice is filed by (frame id, offset)
// exactly as pc/server.py files it. A frame counts as shown only when all of
// its words have arrived under one id.
//
// The scanout stamps its capture number into every pixel, abandons one capture
// in five part way (a display flip), and now and then stalls longer than the
// network core will wait. The queue here is SMALLER than a frame, so the
// scanout is really held back by it, as on the board.
//
// Every shown frame must be one capture, whole, in order; the abandoned ones
// must never be shown; and frames must keep coming.
//////////////////////////////////////////////////////////////////////////////////

module tb_net_stream;

	localparam [47:0] OUR_MAC   = 48'h02_00_5E_10_00_01;
	localparam [31:0] OUR_IP    = {8'd192, 8'd168, 8'd178, 8'd50};
	localparam [47:0] HOST_MAC  = 48'hAA_BB_CC_DD_EE_FF;
	localparam [31:0] HOST_IP   = {8'd192, 8'd168, 8'd178, 8'd191};
	localparam [15:0] HOST_PORT = 16'd40000;
	localparam [15:0] OUR_PORT  = 16'd5005;

	localparam W     = 256;               // pixels across
	localparam H     = 8;                 // rows: 1024 words, three packets
	localparam NPIX  = W * H;
	localparam WORDS = NPIX / 2;
	localparam TIMEOUT = 50000;           // net_core's millisecond

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	integer errors = 0;
	task check;
		input condition;
		input [1023:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// --- the queue ------------------------------------------------------------
	reg         frame_start = 0, frame_done = 0, abort = 0, px_valid = 0;
	reg  [9:0]  px_x = 0;
	reg  [15:0] px_rgb = 0;
	wire        hold, want, empty, fs_valid, fs_sof, fs_rd;
	wire [31:0] fs_data;

	fb_stream #(.AW(9)) u_fs (
		.clk(clk), .rst(rst),
		.frame_start(frame_start), .frame_done(frame_done), .abort(abort),
		.px_valid(px_valid), .px_x(px_x), .px_rgb(px_rgb), .hold(hold),
		.rd_en(fs_rd), .rd_data(fs_data), .rd_valid(fs_valid), .head_sof(fs_sof),
		.arm(1'b0), .want(want), .empty(empty)
	);

	// --- the network core -------------------------------------------------------
	reg  [1:0] rxd = 2'b00;
	reg        crs_dv = 0;
	wire [1:0] txd;
	wire       tx_en;
	wire [31:0] bus_addr, bus_wdata;
	wire        bus_we, bus_re;
	reg         stream_en = 0;
	wire        stream_done_tog;

	net_core #(.MAC_ADDR(OUR_MAC), .IP_ADDR(OUR_IP), .UDP_PORT(OUR_PORT)) dut (
		.clk(clk), .rst(rst),
		.rmii_rxd(rxd), .rmii_crs_dv(crs_dv),
		.rmii_txd(txd), .rmii_tx_en(tx_en),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(32'h4E45_0001), .bus_ack(bus_we | bus_re), .bus_err(2'b00),
		.rx_frame(), .tx_frame(),
		.stream_en(stream_en), .stream_port(16'd5006), .stream_base(32'd0), .stream_words(WORDS[17:0]),
		.stream_rowlen(16'd0), .stream_stride(16'd0),
		.stream_direct(1'b1), .stream_fdata(fs_data), .stream_fvalid(fs_valid), .stream_frd(fs_rd),
		.stream_ready(fs_sof), .stream_done_tog(stream_done_tog)
	);

	// --- the scanout ----------------------------------------------------------
	integer cap_id = 0, aborted = 0, finished = 0, stalls = 0;
	integer p, stop_at, stall_at;
	reg [31:0] rnd = 32'h2468_ACE0;
	always @(posedge clk) rnd <= {rnd[30:0], rnd[31] ^ rnd[21] ^ rnd[1] ^ rnd[0]};

	task run_capture;
		begin
			cap_id = (cap_id + 1) & 15;
			stop_at  = (rnd[7:5] == 3'd0) ? (200 + (rnd[19:8] % (NPIX - 400))) : NPIX;
			stall_at = ((finished + aborted) % 7 == 3) ? (100 + (rnd[31:24] * 13) % (NPIX - 200)) : -1;   // every seventh capture
			@(negedge clk); frame_start = 1; @(negedge clk); frame_start = 0;
			for (p = 0; p < stop_at; p = p + 1) begin
				while (hold) @(negedge clk);
				// long enough to outlast draining the queue AND the core's wait
				if (p == stall_at) begin stalls = stalls + 1; repeat (3 * TIMEOUT) @(negedge clk); end
				px_valid = 1; px_x = p % W; px_rgb = {cap_id[3:0], p[11:0]};
				@(negedge clk);
				px_valid = 0;
				if (rnd[3:2] == 2'd0) @(negedge clk);
			end
			if (stop_at == NPIX) begin
				frame_done = 1; @(negedge clk); frame_done = 0; finished = finished + 1;
			end else begin
				abort = 1; @(negedge clk); abort = 0; aborted = aborted + 1;
			end
		end
	endtask

	reg scan_on = 0;
	initial begin
		while (1) begin
			@(negedge clk);
			if (scan_on && want && !rst) run_capture;
		end
	end

	// --- the wire: every frame the core transmits ---------------------------------
	wire [7:0]  m_data;
	wire        m_valid, m_sof, m_eof, m_crc_ok;
	wire [10:0] m_len;
	rmii_rx u_mon (
		.clk(clk), .rst(rst),
		.rmii_rxd(txd), .rmii_crs_dv(tx_en),
		.data(m_data), .valid(m_valid), .sof(m_sof), .eof(m_eof),
		.crc_ok(m_crc_ok), .length(m_len)
	);
	reg [7:0] mb [0:1535];
	integer   mi = 0;
	reg       got_reply = 0;

	// --- the host: slices filed by (frame id, offset), as pc/server.py does ------
	reg [31:0] hbuf [0:WORDS-1];
	reg        hgot [0:WORDS-1];
	integer    hfid = -1, hk, slices = 0, bad_crc = 0, bad_hdr = 0;
	integer    shown = 0, spliced = 0, told = 0;
	integer    fid, off, total, nw, k, first, seam;
	reg        complete;

	always @(posedge clk) begin
		if (m_valid) begin
			if (m_sof) mi = 0;
			if (mi < 1536) mb[mi] = m_data;
			mi = mi + 1;
		end
		if (m_eof) begin
			if (mi >= 58 && {mb[42], mb[43]} == 16'h4653) begin     // "FS": a frame slice
				slices = slices + 1;
				if (!m_crc_ok) bad_crc = bad_crc + 1;
				fid   = {mb[44], mb[45]};
				off   = {mb[46], mb[47], mb[48], mb[49]};
				total = {mb[50], mb[51], mb[52], mb[53]};
				nw    = {mb[54], mb[55]};
				if (total != WORDS || off + nw > WORDS || mi < 56 + nw * 4) bad_hdr = bad_hdr + 1;
				else begin
					if (fid != hfid) begin
						hfid = fid;
						for (hk = 0; hk < WORDS; hk = hk + 1) hgot[hk] = 0;
					end
					for (k = 0; k < nw; k = k + 1) begin
						hbuf[off + k] = {mb[56+4*k], mb[57+4*k], mb[58+4*k], mb[59+4*k]};
						hgot[off + k] = 1;
					end
					complete = 1;
					for (hk = 0; hk < WORDS; hk = hk + 1) if (!hgot[hk]) complete = 0;
					if (complete) begin
						shown = shown + 1;
						first = hbuf[0][15:12]; seam = -1;
						for (k = 0; k < WORDS; k = k + 1)
							if (seam < 0 && (hbuf[k][15:12] !== first[3:0] || hbuf[k][31:28] !== first[3:0]
							                 || hbuf[k][11:0] !== (2*k) || hbuf[k][27:16] !== (2*k+1)))
								seam = k;
						if (seam >= 0) begin
							spliced = spliced + 1;
							if (told < 4) begin told = told + 1;
								$display("      shown frame %0d (id %0d) is not one capture in order: wrong from word %0d of %0d",
								         shown, fid, seam, WORDS); end
						end
						hfid = -1;
					end
				end
			end else
				got_reply = 1;
		end
	end

	// --- sending the host's one request, so the core knows where to stream -------
	reg [7:0] tx [0:1535];
	integer   i, n;
	function [31:0] crc_step; input [31:0] c; input [7:0] d; integer kk; reg [31:0] t;
		begin t = c ^ {24'd0, d}; for (kk = 0; kk < 8; kk = kk + 1) t = t[0] ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1); crc_step = t; end
	endfunction
	task put16; input integer a; input [15:0] v; begin tx[a] = v[15:8]; tx[a+1] = v[7:0]; end endtask
	task put32; input integer a; input [31:0] v; begin tx[a]=v[31:24]; tx[a+1]=v[23:16]; tx[a+2]=v[15:8]; tx[a+3]=v[7:0]; end endtask
	task put48; input integer a; input [47:0] v; begin tx[a]=v[47:40]; tx[a+1]=v[39:32]; tx[a+2]=v[31:24]; tx[a+3]=v[23:16]; tx[a+4]=v[15:8]; tx[a+5]=v[7:0]; end endtask
	function [15:0] ip_cksum; input integer start; input integer len; integer kk; reg [31:0] s;
		begin s = 0; for (kk = 0; kk < len; kk = kk + 2) s = s + {tx[start+kk], tx[start+kk+1]};
		      while (s[31:16] != 0) s = s[15:0] + s[31:16]; ip_cksum = ~s[15:0]; end
	endfunction
	task send_byte; input [7:0] b; integer d;
		begin for (d = 0; d < 4; d = d + 1) begin rxd = b[2*d +: 2]; @(posedge clk); #1; end end
	endtask
	task send_frame; input integer len; reg [31:0] crc, fcs; integer kk;
		begin
			@(posedge clk); #1; crs_dv = 1;
			for (kk = 0; kk < 7; kk = kk + 1) send_byte(8'h55);
			send_byte(8'hD5);
			crc = 32'hFFFF_FFFF;
			for (kk = 0; kk < len; kk = kk + 1) begin crc = crc_step(crc, tx[kk]); send_byte(tx[kk]); end
			fcs = ~crc;
			send_byte(fcs[7:0]); send_byte(fcs[15:8]); send_byte(fcs[23:16]); send_byte(fcs[31:24]);
			crs_dv = 0; rxd = 2'b00;
		end
	endtask
	task send_ident; integer udp_len;
		begin
			for (i = 0; i < 1536; i = i + 1) tx[i] = 8'h00;
			udp_len = 8 + 12;
			put48(0, OUR_MAC); put48(6, HOST_MAC); put16(12, 16'h0800);
			tx[14] = 8'h45; tx[15] = 8'h00; put16(16, 20 + udp_len); put16(18, 16'h1234); put16(20, 16'h4000);
			tx[22] = 8'd64; tx[23] = 8'd17; put16(24, 16'h0000); put32(26, HOST_IP); put32(30, OUR_IP);
			put16(24, ip_cksum(14, 20));
			put16(34, HOST_PORT); put16(36, OUR_PORT); put16(38, udp_len); put16(40, 16'h0000);
			put16(42, 16'h4641); tx[44] = 8'd1; tx[45] = 8'h04; put16(46, 16'h00AB); tx[48] = 8'd0; tx[49] = 8'd1;
			put32(50, 32'h0);
			n = 42 + 12;
			send_frame(n);
		end
	endtask

	// how often the core's own one-millisecond timeout fired, and when frames were given up
	integer core_timeouts = 0, core_newcap = 0;
	always @(posedge clk) begin
		if (dut.state == 5'd19 && !fs_valid && dut.st_wait >= 17'd50000) core_timeouts = core_timeouts + 1;
		if (dut.state == 5'd19 && fs_valid && fs_sof && (dut.st_off != 0 || dut.st_i != 0)) core_newcap = core_newcap + 1;
	end

	// --- the run --------------------------------------------------------------
	integer mark, guard;
	initial begin
		repeat (5) @(posedge clk);
		rst = 0;
		repeat (10) @(posedge clk);
		$display("tb_net_stream");
		send_ident;
		guard = 0;
		while (!got_reply && guard < 200000) begin @(posedge clk); guard = guard + 1; end
		check(got_reply && dut.host_known, "the core answered the host and knows where to stream");
		stream_en = 1; scan_on = 1;

		guard = 0;
		while (shown < 30 && guard < 40_000_000) begin @(posedge clk); guard = guard + 1; end
		$display("  captures: %0d finished, %0d abandoned, %0d stalled past the timeout", finished, aborted, stalls);
		$display("  wire: %0d slices, %0d bad FCS, %0d bad headers; %0d frames shown", slices, bad_crc, bad_hdr, shown);
		$display("  core: gave %0d frames up on the timeout, %0d for a new capture", core_timeouts, core_newcap);
		check(shown >= 30, "thirty frames reached the host");
		check(spliced == 0, "every frame the host shows is one capture, whole and in order");
		check(bad_crc == 0 && bad_hdr == 0, "every slice on the wire is well formed");
		check(aborted > 0 && core_newcap > 0 && stalls > 0 && core_timeouts > 0, "abandoned captures and the core's timeout were both exercised");
		mark = shown; guard = 0;
		while (shown <= mark + 3 && guard < 20_000_000) begin @(posedge clk); guard = guard + 1; end
		check(shown > mark + 3, "frames keep coming");
		if (errors == 0) $display("tb_net_stream: all checks passed");
		else             $display("tb_net_stream: FAIL -- %0d checks failed", errors);
		$finish;
	end
endmodule
