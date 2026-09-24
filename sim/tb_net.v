`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_net - drive real frames at net_core and check what comes back.
//
// Four things have to work before the web UI can say a word to the board:
//
//   1. ARP     - without it the host cannot even address us
//   2. ICMP    - `ping` working proves RX, TX, CRC, IP and checksums at once
//   3. IDENT   - the first fpgalink round trip
//   4. WRITE then READ - proves the register bus carries data both ways
//
// Replies are decoded with rmii_rx, the same receiver tb_rmii already verified,
// so a failure here is in net_core rather than in the frame plumbing.
//////////////////////////////////////////////////////////////////////////////////

module tb_net;

	localparam [47:0] OUR_MAC   = 48'h02_00_5E_10_00_01;
	localparam [31:0] OUR_IP    = {8'd192, 8'd168, 8'd178, 8'd50};
	localparam [47:0] HOST_MAC  = 48'hAA_BB_CC_DD_EE_FF;
	localparam [31:0] HOST_IP   = {8'd192, 8'd168, 8'd178, 8'd191};
	localparam [15:0] HOST_PORT = 16'd40000;
	localparam [15:0] OUR_PORT  = 16'd5005;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	integer errors = 0;
	task check;
		input condition;
		input [511:0] what;
		begin
			if (condition) $display("  ok   %0s", what);
			else begin $display("  FAIL %0s", what); errors = errors + 1; end
		end
	endtask

	// --- DUT ----------------------------------------------------------------
	reg  [1:0] rxd = 2'b00;
	reg        crs_dv = 0;
	wire [1:0] txd;
	wire       tx_en;

	wire [31:0] bus_addr, bus_wdata, bus_rdata;
	wire        bus_we, bus_re, bus_ack;
	wire [1:0]  bus_err;
	wire        mdc;
	wire        mdio;
	wire mdio_o, mdio_oe;
	assign mdio = mdio_oe ? mdio_o : 1'bz;
	pullup (mdio);

	reg stream_en = 0, stream_ready = 1; reg [15:0] stream_port = 16'd5006; reg [31:0] stream_base = 0; reg [17:0] stream_words = 0;
	reg [15:0] stream_rowlen = 0, stream_stride = 0;
	wire stream_done_tog;
	net_core #(.MAC_ADDR(OUR_MAC), .IP_ADDR(OUR_IP), .UDP_PORT(OUR_PORT)) dut (
		.clk(clk), .rst(rst),
		.rmii_rxd(rxd), .rmii_crs_dv(crs_dv),
		.rmii_txd(txd), .rmii_tx_en(tx_en),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		.rx_frame(), .tx_frame(),
		.stream_en(stream_en), .stream_port(stream_port), .stream_base(stream_base), .stream_words(stream_words),
		.stream_rowlen(stream_rowlen), .stream_stride(stream_stride),
		// this bench streams from the bus, not from a scanout buffer
		.stream_direct(1'b0), .stream_fdata(32'd0), .stream_fvalid(1'b0), .stream_frd(),
		.stream_ready(stream_ready), .stream_done_tog(stream_done_tog)
	);

	// A pattern the capture has to reproduce exactly.
	reg [31:0] probe = 32'd0;
	always @(posedge clk) probe <= {probe[30:0], ~probe[7]};

	regfile u_regs (
		.clk(clk), .rst(rst),
		.la_probe(probe),
		.bus_addr(bus_addr), .bus_wdata(bus_wdata),
		.bus_we(bus_we), .bus_re(bus_re),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack), .bus_err(bus_err),
		// The pad lives at the top level now, so the register file hands out
		// the three signals that make one instead of driving a wire itself.
		.eth_mdc(mdc), .mdio_o(mdio_o), .mdio_oe(mdio_oe), .mdio_i(mdio)
	);

	// --- reply monitor ------------------------------------------------------
	wire [7:0]  m_data;
	wire        m_valid, m_sof, m_eof, m_crc_ok;
	wire [10:0] m_len;

	rmii_rx u_mon (
		.clk(clk), .rst(rst),
		.rmii_rxd(txd), .rmii_crs_dv(tx_en),
		.data(m_data), .valid(m_valid), .sof(m_sof), .eof(m_eof),
		.crc_ok(m_crc_ok), .length(m_len)
	);

	reg [7:0]  rx [0:1535];
	integer    nrx = 0;
	reg        got_reply = 0;
	reg        reply_crc_ok = 0;

	always @(posedge clk) begin
		if (m_valid) begin
			if (nrx < 1536) rx[nrx] = m_data;
			nrx = nrx + 1;
		end
		if (m_eof) begin got_reply = 1; reply_crc_ok = m_crc_ok; end
	end

	// A second view of the same replies, indexed from each frame's own start and
	// never reset by the sender. While the streamer runs, a reply arrives among
	// the frame slices, and nrx -- which send_frame zeroes -- cannot be trusted
	// to line up with it.
	reg [7:0]  mb [0:1535];
	integer    mi = 0;
	reg        got_fl = 0, fl_crc_ok = 0;
	reg [7:0]  fl_rop = 0, fl_rstat = 0;
	reg [31:0] fl_rword = 0;

	always @(posedge clk) begin
		if (m_valid) begin
			if (m_sof) mi = 0;
			if (mi < 1536) mb[mi] = m_data;
			mi = mi + 1;
		end
		if (m_eof && mi >= 58 && {mb[42], mb[43]} == 16'h4641) begin
			got_fl   <= 1'b1;
			fl_crc_ok <= m_crc_ok;
			fl_rop   <= mb[45];
			fl_rstat <= mb[48];
			fl_rword <= {mb[54], mb[55], mb[56], mb[57]};
		end
	end

	// streamer trace: state changes while streaming
	reg [4:0] st_prev = 0; integer st_ev = 0;
	always @(posedge clk) if (stream_en && dut.state != st_prev && st_ev < 40) begin
		st_ev = st_ev + 1; st_prev = dut.state;
		$display("      @%0t state %0d -> %0d  step=%0d st_n=%0d st_i=%0d st_off=%0d words=%0d left=%0d", $time, st_prev, dut.state, dut.step, dut.st_n, dut.st_i, dut.st_off, dut.stream_words, dut.st_left);
	end
	// Every bus address the streamer reads, so a test can say which words of a
	// strided frame it went after.
	reg [31:0] rdaddr [0:255];
	integer    nrd = 0;
	always @(posedge clk) if (bus_re && bus_ack && nrd < 256) begin
		rdaddr[nrd] = bus_addr; nrd = nrd + 1;
	end
	function saw_addr;
		input [31:0] a;
		integer k;
		begin
			saw_addr = 0;
			for (k = 0; k < nrd; k = k + 1) if (rdaddr[k] == a) saw_addr = 1;
		end
	endfunction

	// --- frame construction -------------------------------------------------
	reg [7:0] tx [0:1535];
	integer   i, n, guard;

	function [31:0] crc_step;
		input [31:0] c;
		input [7:0]  d;
		integer k;
		reg [31:0] t;
		begin
			t = c ^ {24'd0, d};
			for (k = 0; k < 8; k = k + 1)
				t = t[0] ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1);
			crc_step = t;
		end
	endfunction

	task put16; input integer a; input [15:0] v;
		begin tx[a] = v[15:8]; tx[a+1] = v[7:0]; end
	endtask
	task put32; input integer a; input [31:0] v;
		begin tx[a]=v[31:24]; tx[a+1]=v[23:16]; tx[a+2]=v[15:8]; tx[a+3]=v[7:0]; end
	endtask
	task put48; input integer a; input [47:0] v;
		begin tx[a]=v[47:40]; tx[a+1]=v[39:32]; tx[a+2]=v[31:24];
		      tx[a+3]=v[23:16]; tx[a+4]=v[15:8]; tx[a+5]=v[7:0]; end
	endtask

	// One's complement sum over a span of the outgoing frame.
	function [15:0] ip_cksum;
		input integer start;
		input integer len;
		integer k;
		reg [31:0] s;
		begin
			s = 0;
			for (k = 0; k < len; k = k + 2)
				s = s + {tx[start+k], tx[start+k+1]};
			while (s[31:16] != 0) s = s[15:0] + s[31:16];
			ip_cksum = ~s[15:0];
		end
	endfunction

	task send_byte;
		input [7:0] b;
		integer d;
		begin
			for (d = 0; d < 4; d = d + 1) begin
				rxd = b[2*d +: 2];
				@(posedge clk);
				// Settle past the edge before the next change. Without this the
				// carrier drop at the end of a frame races the DUT's sampling of
				// the final dibit, and the last byte of every frame is lost.
				#1;
			end
		end
	endtask

	task send_frame;
		input integer len;
		reg [31:0] crc;
		reg [31:0] fcs;
		integer k;
		begin
			nrx = 0; got_reply = 0;
			@(posedge clk);
			#1;
			crs_dv = 1;
			for (k = 0; k < 7; k = k + 1) send_byte(8'h55);
			send_byte(8'hD5);
			crc = 32'hFFFF_FFFF;
			for (k = 0; k < len; k = k + 1) begin
				crc = crc_step(crc, tx[k]);
				send_byte(tx[k]);
			end
			fcs = ~crc;
			send_byte(fcs[7:0]);
			send_byte(fcs[15:8]);
			send_byte(fcs[23:16]);
			send_byte(fcs[31:24]);
			crs_dv = 0;
			rxd = 2'b00;
		end
	endtask

	// Wait for a streamed packet carrying a particular word offset. The streamer
	// builds the next packet while the current one is on the wire, so "the next
	// packet to arrive" is no longer a safe way to name one.
	task await_slice;
		input [31:0] want_off;
		integer guard;
		begin
			guard = 0;
			got_reply = 0; nrx = 0;
			while (guard < 400000) begin
				@(posedge clk);
				guard = guard + 1;
				if (got_reply) begin
					if (nrx > 58 && {rx[42], rx[43]} == 16'h4653 && rxword(46) == want_off)
						guard = 400000;
					else begin got_reply = 0; nrx = 0; end
				end
			end
		end
	endtask

	task await_reply;
		integer guard;
		begin
			guard = 0;
			while (!got_reply && guard < 200000) begin
				@(posedge clk);
				guard = guard + 1;
			end
		end
	endtask

	// --- frame templates ----------------------------------------------------
	task build_arp_request;
		begin
			for (i = 0; i < 64; i = i + 1) tx[i] = 8'h00;
			put48(0, 48'hFF_FF_FF_FF_FF_FF);
			put48(6, HOST_MAC);
			put16(12, 16'h0806);
			put16(14, 16'h0001);       // ethernet
			put16(16, 16'h0800);       // ipv4
			tx[18] = 8'd6; tx[19] = 8'd4;
			put16(20, 16'h0001);       // request
			put48(22, HOST_MAC);
			put32(28, HOST_IP);
			put48(32, 48'h0);
			put32(38, OUR_IP);
			n = 42;
		end
	endtask

	// payload_len counts bytes after the IP header.
	task build_ip;
		input [7:0] proto;
		input integer payload_len;
		begin
			for (i = 0; i < 1536; i = i + 1) tx[i] = 8'h00;
			put48(0, OUR_MAC);
			put48(6, HOST_MAC);
			put16(12, 16'h0800);
			tx[14] = 8'h45;
			tx[15] = 8'h00;
			put16(16, 20 + payload_len);
			put16(18, 16'h1234);
			put16(20, 16'h4000);
			tx[22] = 8'd64;
			tx[23] = proto;
			put16(24, 16'h0000);
			put32(26, HOST_IP);
			put32(30, OUR_IP);
			put16(24, ip_cksum(14, 20));
			n = 34 + payload_len;
		end
	endtask

	task build_fpgalink;
		input [7:0]  op;
		input [7:0]  count;
		input [31:0] addr;
		input integer nwords;      // payload words actually placed
		integer udp_len;
		begin
			udp_len = 8 + 12 + nwords * 4;
			build_ip(8'd17, udp_len);
			put16(34, HOST_PORT);
			put16(36, OUR_PORT);
			put16(38, udp_len);
			put16(40, 16'h0000);
			put16(42, 16'h4641);   // magic
			tx[44] = 8'd1;         // version
			tx[45] = op;
			put16(46, 16'h00AB);   // seq
			tx[48] = 8'd0;
			tx[49] = count;
			put32(50, addr);
			n = 42 + 12 + nwords * 4;
		end
	endtask

	function [31:0] rxword;
		input integer a;
		begin rxword = {rx[a], rx[a+1], rx[a+2], rx[a+3]}; end
	endfunction

	// Verify the reply's IP header: a correct checksum makes the header sum to
	// zero, which is a stronger check than recomputing it the same way twice.
	function ip_header_ok;
		input integer dummy;
		integer k;
		reg [31:0] s;
		begin
			s = 0;
			for (k = 0; k < 20; k = k + 2) s = s + {rx[14+k], rx[15+k]};
			while (s[31:16] != 0) s = s[15:0] + s[31:16];
			ip_header_ok = (s[15:0] == 16'hFFFF);
		end
	endfunction


	initial begin
		repeat (5) @(posedge clk);
		rst = 0;
		repeat (10) @(posedge clk);

		$display("tb_net");

		// --- 1. ARP ---------------------------------------------------------
		$display(" ARP request for our IP:");
		build_arp_request;
		send_frame(n);
		await_reply;
		check(got_reply, "a reply was transmitted");
		check(reply_crc_ok, "reply FCS is valid");
		check({rx[0],rx[1],rx[2],rx[3],rx[4],rx[5]} == HOST_MAC, "reply addressed to the asker");
		check({rx[6],rx[7],rx[8],rx[9],rx[10],rx[11]} == OUR_MAC, "reply sourced from our MAC");
		check({rx[12],rx[13]} == 16'h0806, "ethertype is ARP");
		check({rx[20],rx[21]} == 16'h0002, "operation is reply");
		check({rx[22],rx[23],rx[24],rx[25],rx[26],rx[27]} == OUR_MAC, "sender hardware is our MAC");
		check(rxword(28) == OUR_IP, "sender protocol is our IP");
		check(rxword(38) == HOST_IP, "target protocol is the asker's IP");

		// --- 2. ICMP --------------------------------------------------------
		$display(" ICMP echo request:");
		build_ip(8'd1, 8 + 16);
		tx[34] = 8'd8;            // echo request
		tx[35] = 8'd0;
		put16(38, 16'hBEEF);      // id
		put16(40, 16'h0001);      // seq
		for (i = 0; i < 16; i = i + 1) tx[42+i] = i + 8'h60;
		put16(36, 16'h0000);
		put16(36, ip_cksum(34, 8 + 16));
		send_frame(n);
		await_reply;
		check(got_reply, "a reply was transmitted");
		check(reply_crc_ok, "reply FCS is valid");
		check(rx[34] == 8'd0, "ICMP type is echo reply");
		check(rxword(26) == OUR_IP, "IP source is us");
		check(rxword(30) == HOST_IP, "IP destination is the host");
		check(ip_header_ok(0), "IP header checksum is correct");
		begin : icmp_ck
			integer k; reg [31:0] s;
			s = 0;
			for (k = 0; k < 24; k = k + 2) s = s + {rx[34+k], rx[35+k]};
			while (s[31:16] != 0) s = s[15:0] + s[31:16];
			check(s[15:0] == 16'hFFFF, "ICMP checksum is correct after the type change");
		end
		begin : icmp_payload
			integer k, bad;
			bad = 0;
			for (k = 0; k < 16; k = k + 1) if (rx[42+k] !== (k + 8'h60)) bad = bad + 1;
			check(bad == 0, "echo payload came back unchanged");
		end

		// --- 3. fpgalink IDENT ----------------------------------------------
		$display(" fpgalink IDENT:");
		build_fpgalink(8'h04, 8'd1, 32'h0, 0);
		send_frame(n);
		await_reply;
		check(got_reply, "a reply was transmitted");
		check(reply_crc_ok, "reply FCS is valid");
		check(ip_header_ok(0), "IP header checksum is correct");
		check({rx[34],rx[35]} == OUR_PORT, "UDP source port is ours");
		check({rx[36],rx[37]} == HOST_PORT, "UDP destination is the host's port");
		check({rx[42],rx[43]} == 16'h4641, "fpgalink magic echoed");
		check(rx[45] == 8'h84, "opcode has the response bit set");
		check(rx[48] == 8'h00, "status is OK");
		check(rx[49] == 8'd4, "four words returned");
		check(rxword(54) == 32'h4650_4741, "first word is 'FPGA'");

		// --- 4. WRITE then READ ---------------------------------------------
		$display(" fpgalink WRITE then READ of the scratch register:");
		build_fpgalink(8'h02, 8'd1, 32'h0000_0008, 1);
		put32(54, 32'hDEAD_BEEF);
		n = 42 + 12 + 4;
		send_frame(n);
		await_reply;
		check(got_reply, "write was acknowledged");
		check(rx[45] == 8'h82, "write response opcode");
		check(rx[48] == 8'h00, "write status is OK");

		build_fpgalink(8'h01, 8'd1, 32'h0000_0008, 0);
		send_frame(n);
		await_reply;
		check(got_reply, "read was answered");
		check(rx[45] == 8'h81, "read response opcode");
		check(rx[49] == 8'd1, "one word returned");
		check(rxword(54) == 32'hDEAD_BEEF, "scratch read back what was written");

		// --- 5. rejection ---------------------------------------------------
		$display(" traffic that is not ours:");
		build_arp_request;
		put32(38, {8'd192, 8'd168, 8'd178, 8'd99});   // someone else's IP
		send_frame(n);
		repeat (4000) @(posedge clk);
		check(!got_reply, "ARP for another IP is ignored");

		build_fpgalink(8'h01, 8'd1, 32'hDEAD_0000, 0);
		send_frame(n);
		await_reply;
		check(got_reply, "unmapped address still gets a reply");
		check(rx[48] == 8'h03, "status reports the address as unmapped");

		// --- 6. logic analyzer ----------------------------------------------
		$display(" logic analyzer over fpgalink:");
		build_fpgalink(8'h01, 8'd1, 32'h0001_0000, 0);   // LA ID
		send_frame(n); await_reply;
		check(rxword(54) == 32'h4C41_0001, "LA identifies itself");

		// depth 64, no divisor, small pre-trigger window, free-running trigger
		build_fpgalink(8'h02, 8'd1, 32'h0001_0014, 1); put32(54, 32'd64);
		n = 42+12+4; send_frame(n); await_reply;
		build_fpgalink(8'h02, 8'd1, 32'h0001_0018, 1); put32(54, 32'd16);
		n = 42+12+4; send_frame(n); await_reply;
		build_fpgalink(8'h02, 8'd1, 32'h0001_000C, 1); put32(54, 32'hFFFF_FFFF);
		n = 42+12+4; send_frame(n); await_reply;

		build_fpgalink(8'h02, 8'd1, 32'h0001_0004, 1); put32(54, 32'd1);   // ARM
		n = 42+12+4; send_frame(n); await_reply;
		check(rx[48] == 8'h00, "arm accepted");

		repeat (4000) @(posedge clk);

		build_fpgalink(8'h01, 8'd1, 32'h0001_0008, 0);   // STATUS
		send_frame(n); await_reply;
		check(rxword(54)[2] == 1'b1, "capture reports DONE");
		check(rxword(54)[31:16] == 16'd64, "fill level is the full depth");

		build_fpgalink(8'h03, 8'd1, 32'h0002_0000, 1); put32(54, 32'd8);
		n = 42+12+4; send_frame(n); await_reply;
		check(rx[49] == 8'd8, "READ_BLOCK returned eight samples");
		begin : la_seq
			integer k, bad;
			bad = 0;
			// The probe shifts left every cycle, so consecutive samples must
			// differ. All-identical means the capture never actually ran.
			for (k = 0; k < 7; k = k + 1)
				if (rxword(54 + k*4) === rxword(58 + k*4)) bad = bad + 1;
			check(bad == 0, "captured samples vary, so the buffer holds real data");
		end

		// --- 5. the frame streamer ------------------------------------------
		$display(" frame streamer (one word, the scratch register):");
		repeat (50) @(posedge clk); got_reply = 0; nrx = 0;
		stream_base = 32'h0000_0008; stream_words = 18'd1; #1 stream_en = 1;
		await_reply;
		check(got_reply, "a stream packet was transmitted");
		$display("    packet bytes 0..63: %h %h %h %h %h %h | %h %h %h %h %h %h | %h %h | ip %h %h len %h %h | %h %h | udp %h %h %h %h len %h %h | %h %h fs %h %h %h %h | %h %h %h %h %h %h %h %h | n %h %h | %h %h %h %h", rx[0],rx[1],rx[2],rx[3],rx[4],rx[5], rx[6],rx[7],rx[8],rx[9],rx[10],rx[11], rx[12],rx[13], rx[14],rx[15],rx[16],rx[17], rx[22],rx[23], rx[34],rx[35],rx[36],rx[37],rx[38],rx[39], rx[40],rx[41],rx[42],rx[43],rx[44],rx[45], rx[46],rx[47],rx[48],rx[49],rx[50],rx[51],rx[52],rx[53], rx[54],rx[55], rx[56],rx[57],rx[58],rx[59]);
		$display("    streamer: st_off=%0d st_n=%0d st_frame=%0d host_known=%b state=%0d", dut.st_off, dut.st_n, dut.st_frame, dut.host_known, dut.state);
		check(reply_crc_ok, "its FCS is valid");
		check(ip_header_ok(0), "its IP header checksum is correct");
		check({rx[0],rx[1],rx[2],rx[3],rx[4],rx[5]} == HOST_MAC, "addressed to the host that last spoke");
		check(rxword(30) == HOST_IP, "IP destination is the host");
		check({rx[36],rx[37]} == 16'd5006, "UDP destination is the stream port");
		check({rx[16],rx[17]} == 16'd46, "IP total length = 20 + 8 + 14 + 4");
		check({rx[38],rx[39]} == 16'd26, "UDP length = 8 + 14 + 4");
		check({rx[42],rx[43]} == 16'h4653, "slice magic FS");
		check({rx[44],rx[45]} == 16'd0, "frame id 0");
		check(rxword(46) == 32'd0, "word offset 0");
		check(rxword(50) == 32'd1, "words in the frame: 1");
		check({rx[54],rx[55]} == 16'd1, "words in this packet: 1");
		check(rxword(56) == 32'hDEAD_BEEF, "the word is the scratch register's value");
		stream_en = 0;
		repeat (20000) @(posedge clk);   // let a packet already on the wire finish
		$display(" frame streamer (351 words: two packets):");
		repeat (50) @(posedge clk); got_reply = 0; nrx = 0;
		stream_base = 32'h0000_0100; stream_words = 18'd351; #1 stream_en = 1;
		await_slice(32'd0);
		check(got_reply && {rx[42],rx[43]} == 16'h4653, "first packet transmitted");
		check({rx[54],rx[55]} == 16'd350, "first packet carries 350 words");
		check({rx[16],rx[17]} == 16'd20 + 16'd8 + 16'd14 + 16'd1400, "IP total length covers 350 words");
		check(reply_crc_ok && ip_header_ok(0), "its FCS and IP checksum are valid");
		await_slice(32'd350);
		check(got_reply && {rx[42],rx[43]} == 16'h4653, "second packet transmitted");
		check({rx[54],rx[55]} == 16'd1, "second packet: the last word");
		check(reply_crc_ok && ip_header_ok(0), "second packet's FCS and IP checksum are valid");
		stream_en = 0;
		repeat (20000) @(posedge clk);   // let a packet already on the wire finish
		$display(" frame streamer (250 words: a length that borrows):");
		repeat (50) @(posedge clk); got_reply = 0; nrx = 0;
		// 0x100 and up: unmapped, so every word reads back a defined zero. From
		// zero the walk would cross the MEM register, whose calibration bit is
		// undriven in this bench, and an x byte makes the frame's FCS x too.
		stream_base = 32'h0000_0100; stream_words = 18'd250; #1 stream_en = 1;
		await_slice(32'd0);
		check(got_reply && {rx[42],rx[43]} == 16'h4653, "250-word packet transmitted");
		check({rx[16],rx[17]} == 16'd1042, "IP total length 1042 (20+8+14+1000)");
		check({rx[38],rx[39]} == 16'd1022, "UDP length 1022 (8+14+1000)");
		check(reply_crc_ok && ip_header_ok(0), "FCS and IP checksum valid");
		stream_en = 0;
		repeat (20000) @(posedge clk);

		// --- 8b. rows narrower than their pitch ------------------------------
		// The captured frame sits in memory a row at a time at a wider pitch than
		// the part of it that is sent, so the streamer has to step over the tail
		// of every row. Here: two words of every four, from 0x100 up. Every word
		// of that region reads zero, so the test is on the addresses asked for.
		$display(" frame streamer with a row pitch:");
		repeat (50) @(posedge clk); got_reply = 0; nrx = 0;
		nrd = 0;
		stream_base = 32'h0000_0100; stream_words = 18'd6;
		stream_rowlen = 16'd2; stream_stride = 16'd4; #1 stream_en = 1;
		await_slice(32'd0);
		check(got_reply && {rx[42],rx[43]} == 16'h4653, "the strided packet went out");
		check({rx[54],rx[55]} == 16'd6, "six words in the frame");
		check(saw_addr(32'h0000_0100) && saw_addr(32'h0000_0104), "row 0: the first two words");
		check(saw_addr(32'h0000_0110) && saw_addr(32'h0000_0114), "row 1: over the pitch");
		check(saw_addr(32'h0000_0120) && saw_addr(32'h0000_0124), "row 2: over the pitch again");
		check(!saw_addr(32'h0000_0108) && !saw_addr(32'h0000_010C), "the tail of a row is never read");
		stream_en = 0; stream_rowlen = 0; stream_stride = 0;
		repeat (20000) @(posedge clk);

		// --- 9. a request while the streamer is running ----------------------
		// The receiver used to live inside the FSM's S_RX state, so every frame
		// that arrived during a streamed packet was thrown away and the register
		// link starved as soon as video streaming was switched on.
		$display(" a request that arrives mid-frame-stream:");
		repeat (50) @(posedge clk);
		got_fl = 0; got_reply = 0; nrx = 0;
		stream_base = 32'h0000_0100; stream_words = 18'd4000; #1 stream_en = 1;
		repeat (2000) @(posedge clk);          // well inside the first packet
		build_fpgalink(8'h01, 8'd1, 32'h0000_0008, 0);
		n = 42 + 12 + 4;
		send_frame(n);
		guard = 0;
		while (!got_fl && guard < 200000) begin @(posedge clk); guard = guard + 1; end
		check(got_fl, "the read was answered while the frame was streaming");
		check(fl_crc_ok, "its FCS is valid");
		check(fl_rop == 8'h81 && fl_rstat == 8'h00, "read response, status OK");
		check(fl_rword == 32'hDEAD_BEEF, "it carried the scratch register's value");
		stream_en = 0;

		$display("");
		if (errors == 0) $display("tb_net: all checks passed");
		else             $display("tb_net: %0d FAIL(s)", errors);
		$finish;
	end

	initial begin
		#40_000_000;
		$display("FAIL timeout");
		$finish;
	end

endmodule
