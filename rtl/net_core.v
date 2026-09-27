//////////////////////////////////////////////////////////////////////////////////
// net_core.v - a small Ethernet endpoint: ARP, ICMP echo, and fpgalink over UDP.
//
// Everything runs in the PHY's 50 MHz REF_CLK domain. No CPU, no soft core.
//
// The strategy is "reply by mutation". An incoming frame is copied byte for byte
// into a buffer while its headers are latched on the fly. If we want to answer,
// the reply is almost the request with fields swapped -- source and destination
// exchanged, a few bytes rewritten, checksums fixed. That is far less logic than
// building a frame from nothing, and it means ARP, ICMP and UDP share one path.
//
// What it answers:
//
//   ARP request for our IP     -> ARP reply, so the host can find us at all
//   ICMP echo request          -> echo reply, so `ping` works
//   UDP to UDP_PORT, magic ok  -> fpgalink register transaction (docs/PROTOCOL.md)
//
// Everything else is dropped in silence, including anything with a bad FCS.
//
// Frame offsets used below, all from the first byte of the destination MAC:
//
//    0  dest MAC        14  IP ver/IHL      34  ICMP type   34  UDP src port
//    6  src MAC         16  IP total len    35  ICMP code   36  UDP dst port
//   12  ethertype       23  IP protocol     36  ICMP cksum  38  UDP length
//   20  ARP oper        24  IP cksum        38  ICMP body   40  UDP cksum
//   22  ARP SHA         26  IP src                          42  fpgalink header
//   28  ARP SPA         30  IP dst                          54  fpgalink payload
//   38  ARP TPA
//
// IPv4 options are not supported: a header with IHL != 5 is dropped rather than
// mis-parsed, because every offset above assumes a 20-byte IP header.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module net_core #(
	parameter [47:0] MAC_ADDR = 48'h02_00_5E_10_00_01,
	parameter [31:0] IP_ADDR  = {8'd192, 8'd168, 8'd178, 8'd50},
	parameter [15:0] UDP_PORT = 16'd5005,
	parameter [31:0] GATEWARE_VERSION = 32'h0001_0000
)(
	input  wire        clk,
	input  wire        rst,

	input  wire [1:0]  rmii_rxd,
	input  wire        rmii_crs_dv,
	output wire [1:0]  rmii_txd,
	output wire        rmii_tx_en,

	// fpgalink register bus
	output reg  [31:0] bus_addr,
	output reg  [31:0] bus_wdata,
	output reg         bus_we,
	output reg         bus_re,
	input  wire [31:0] bus_rdata,
	input  wire        bus_ack,
	input  wire [1:0]  bus_err,      // 0 ok, 1 unmapped, 2 read-only

	output reg         rx_frame,     // pulses on every accepted frame
	output reg         tx_frame,     // pulses on every reply sent
	// the frame streamer: with stream_en, the words at stream_base (bus address,
	// stream_words of them) go to the last host that spoke to us, UDP port
	// stream_port, unasked, ~350 words a packet; stream_ready gates the start
	// of each frame (a capture that is complete) and stream_done_tog flips
	// when a frame has gone out
	input  wire        stream_en,
	input  wire [15:0] stream_port,
	input  wire [31:0] stream_base,
	input  wire [17:0] stream_words,
	// The frame is stored a row at a time at a pitch that can be wider than the
	// part of it we send -- the PlayStation's capture is 160 words of every
	// 320-word row -- so the streamer walks rows, not one flat run.
	// stream_rowlen 0 means the words are contiguous.
	input  wire [15:0] stream_rowlen,
	input  wire [15:0] stream_stride,
	input  wire        stream_ready,
	// With stream_direct the words come from a buffer the scanout fills, not
	// from bus reads: no memory round trip, which is most of a frame's time.
	input  wire        stream_direct,
	input  wire [31:0] stream_fdata,
	input  wire        stream_fvalid,
	output reg         stream_frd,
	output reg         stream_done_tog
);

	localparam [15:0] ET_ARP  = 16'h0806;
	localparam [15:0] ET_IPV4 = 16'h0800;
	localparam [7:0]  IP_ICMP = 8'd1;
	localparam [7:0]  IP_UDP  = 8'd17;

	localparam [15:0] FL_MAGIC = 16'h4641;
	localparam [7:0]  FL_VER   = 8'd1;
	localparam [7:0]  OP_READ = 8'h01, OP_WRITE = 8'h02,
	                  OP_RDBLK = 8'h03, OP_IDENT = 8'h04;

	// --- frame buffer -------------------------------------------------------
	// One write port and one read port, which is what a block RAM gives us.
	// The receiver and the patch FSM never write at the same time, and the
	// transmitter and the checksum walk never read at the same time.
	reg [7:0] fbuf [0:2047];

	reg  [10:0] wr_addr;
	reg  [7:0]  wr_data;
	reg         wr_en;
	reg  [10:0] fsm_rd_addr;
	reg  [7:0]  rd_q;

	wire [10:0] tx_rd_addr;
	reg         tx_active;
	wire [10:0] rd_addr = tx_active ? tx_rd_addr : fsm_rd_addr;


	// --- RMII ---------------------------------------------------------------
	wire [7:0]  rx_data;
	wire        rx_valid, rx_sof, rx_eof, rx_crc_ok;
	wire [10:0] rx_len;

	rmii_rx u_rx (
		.clk(clk), .rst(rst),
		.rmii_rxd(rmii_rxd), .rmii_crs_dv(rmii_crs_dv),
		.data(rx_data), .valid(rx_valid), .sof(rx_sof), .eof(rx_eof),
		.crc_ok(rx_crc_ok), .length(rx_len)
	);

	reg         tx_start;
	reg  [10:0] tx_len;
	wire        tx_busy;

	rmii_tx u_tx (
		.clk(clk), .rst(rst),
		.start(tx_start), .length(tx_len),
		.rd_addr(tx_rd_addr), .rd_data(rd_q),
		.rmii_txd(rmii_txd), .rmii_tx_en(rmii_tx_en), .busy(tx_busy)
	);

	// --- uptime, for IDENT --------------------------------------------------
	reg [15:0] ms_div;
	reg [31:0] uptime_ms;
	always @(posedge clk) begin
		if (rst) begin ms_div <= 0; uptime_ms <= 0; end
		else if (ms_div == 16'd49999) begin
			ms_div <= 0;
			uptime_ms <= uptime_ms + 1;
		end else ms_div <= ms_div + 1;
	end

	// --- header fields latched during receive -------------------------------
	reg [10:0] rx_idx;
	wire [10:0] idx = rx_sof ? 11'd0 : rx_idx;
	reg [47:0] src_mac;
	reg [47:0] dst_mac;
	reg [15:0] ethertype;

	reg [15:0] arp_oper;
	reg [47:0] arp_sha;
	reg [31:0] arp_spa;
	reg [31:0] arp_tpa;

	reg [7:0]  ip_verihl;
	reg [15:0] ip_len;
	reg [7:0]  ip_proto;
	reg [31:0] ip_src;
	reg [31:0] ip_dst;

	reg [7:0]  icmp_type;
	reg [7:0]  icmp_code;
	reg [15:0] icmp_cksum;

	reg [15:0] udp_sport;
	reg [15:0] udp_dport;

	reg [15:0] fl_magic;
	reg [7:0]  fl_ver;
	reg [7:0]  fl_op;
	reg [7:0]  fl_count;
	reg [31:0] fl_addr;

	wire dst_is_bcast = (dst_mac == 48'hFF_FF_FF_FF_FF_FF);
	wire dst_is_us    = (dst_mac == MAC_ADDR);

	// --- main sequencer -----------------------------------------------------
	localparam S_RX        = 5'd0,  S_CLASSIFY  = 5'd1,
	           S_ARP       = 5'd2,  S_IPCOMMON  = 5'd3,
	           S_ICMP      = 5'd4,  S_FL_START  = 5'd5,
	           S_FL_RDREQ  = 5'd6,  S_FL_BUS    = 5'd7,
	           S_FL_WRRESP = 5'd8,  S_FL_NEXT   = 5'd9,
	           S_FL_HDR    = 5'd10, S_UDPHDR    = 5'd11,
	           S_CKZERO    = 5'd12, S_CKREAD    = 5'd13, S_CKWRITE = 5'd14,
	           S_TX        = 5'd15, S_TXWAIT    = 5'd16, S_DROP    = 5'd17,
	           S_ST_HDR    = 5'd18, S_ST_RD     = 5'd19, S_ST_PUT  = 5'd20,
	           S_ST_SEND   = 5'd21;

	reg [4:0]  state;
	reg [7:0]  step;
	reg [10:0] reply_len;

	reg [7:0]  resp_count;     // fpgalink words in the reply
	reg [7:0]  words_todo;
	reg [7:0]  word_i;
	reg [31:0] cur_addr;
	reg [31:0] cur_word;
	reg [1:0]  err_code;
	reg        is_write;

	reg [16:0] cksum;
	reg [10:0] ck_i;

	// the streamer's bookkeeping
	reg [47:0] host_mac; reg [31:0] host_ip; reg host_known;
	reg [17:0] st_off;         // word offset into the frame
	reg [15:0] st_frame;       // frame counter, so the host can assemble
	reg [8:0]  st_n, st_i;     // words in this packet, words done
	reg [17:0] st_wa;          // word address in the frame, following the row pitch
	reg [15:0] st_cx;          // column within the row
	reg        st_streaming;   // the packet being built is the streamer's
	reg [15:0] st_ipck;        // the header checksum, worked out as it is built
	reg [16:0] st_wait;        // how long the scanout has had nothing to give
	reg [16:0] st_gap;         // cycles since the last streamed packet went out
	// After a word is taken, the head of the queue is stale for two clocks (its
	// read port is registered, and so is stream_frd). Nothing may look at
	// stream_fvalid / stream_ready again until this has counted down.
	reg [1:0]  st_hold;
	localparam [16:0] ST_GAP_PKT = 17'd4;    // the receiver runs on its own now, so barely a pause at all
	localparam [8:0] ST_PKT = 9'd350;
	wire [17:0] st_left = stream_words - st_off;
	wire [10:0] st_bytes = 11'd56 + {st_n, 2'b00};          // headers 42 + ours 14 + words
	wire [10:0] st_iplen = st_bytes - 11'd14;                // (a byte-wise subtraction lost the borrow: the frame's short last packet had a bad UDP length and the host dropped it)
	wire [10:0] st_udplen = st_bytes - 11'd34;
	wire [15:0] st_skip = stream_stride - stream_rowlen;    // the unsent tail of each row

	// Every 16-bit word of the IP header this packet will carry, added up. The
	// header is ours and entirely known before it is written, so there is no
	// need to write it, read it back and walk it -- which is what the reply path
	// does, and what a packet a frame cannot afford.
	wire [19:0] st_ipsum = 20'h04500 + {9'd0, st_iplen} + {4'd0, st_frame}
	                     + 20'h04000 + {4'd0, 8'd64, IP_UDP}
	                     + {4'd0, IP_ADDR[31:16]} + {4'd0, IP_ADDR[15:0]}
	                     + {4'd0, host_ip[31:16]} + {4'd0, host_ip[15:0]};
	wire [16:0] st_ipf1 = {1'b0, st_ipsum[15:0]} + {13'd0, st_ipsum[19:16]};
	wire [15:0] st_ipf2 = st_ipf1[15:0] + {15'd0, st_ipf1[16]};

	// --- the two buffers -----------------------------------------------------
	// The streamer builds and sends its packets from sbuf, so the receiver can
	// go on mirroring an incoming request into fbuf while a streamed packet is
	// in the air. fbuf's single write port is shared between the receiver and
	// the reply-patching FSM, which never want it at the same time: the receiver
	// writes only while fbuf is free (S_RX, or the streamer at work) and the FSM
	// patches a reply only in the states in between.
	reg [7:0] sbuf [0:2047];
	reg  [10:0] rx_waddr; reg [7:0] rx_wdata; reg rx_we;
	wire        fb_we    = rx_we | (wr_en & ~st_streaming);
	wire [10:0] fb_waddr = rx_we ? rx_waddr : wr_addr;
	wire [7:0]  fb_wdata = rx_we ? rx_wdata : wr_data;
	reg  [7:0]  fbuf_q, sbuf_q;

	always @(posedge clk) begin
		if (fb_we)                 fbuf[fb_waddr] <= fb_wdata;
		if (wr_en && st_streaming) sbuf[wr_addr] <= wr_data;
		fbuf_q <= fbuf[rd_addr];
		sbuf_q <= sbuf[rd_addr];
	end
	always @(*) rd_q = st_streaming ? sbuf_q : fbuf_q;

	// Fold the end-around carry until none is left. Two folds always suffice
	// for a 20-byte header.
	function [15:0] fold;
		input [16:0] s;
		reg [16:0] t;
		begin
			t = s[15:0] + s[16];
			fold = t[15:0] + t[16];
		end
	endfunction

	task put;                  // queue one buffer byte write
		input [10:0] a;
		input [7:0]  d;
		begin
			wr_addr <= a;
			wr_data <= d;
			wr_en   <= 1'b1;
		end
	endtask

	// --- the receiver -------------------------------------------------------
	// Mirrors an incoming frame into fbuf and latches the header fields it will
	// need, whatever the FSM is doing. A complete, valid frame addressed to us
	// flips req_tog, and the FSM picks that up the next time it passes through
	// S_RX. This used to live inside S_RX itself, so every frame that arrived
	// during a streamed packet was thrown away and the register link starved as
	// soon as video streaming was switched on.
	//
	// fbuf is the receiver's while the FSM is idle or streaming from sbuf, and
	// only until a request is sitting in it: a frame arriving behind a request
	// would otherwise overwrite it before the FSM had read it.
	reg  req_tog, req_seen;
	reg  rx_live;              // this frame was seen from its first byte
	wire fbuf_free = ((state == S_RX) || st_streaming) && (req_tog == req_seen);

	always @(posedge clk) begin
		rx_we <= 1'b0;
		if (rst) begin
			rx_idx  <= 0;
			req_tog <= 1'b0;
			rx_live <= 1'b0;
		end else if (!fbuf_free) begin
			// whatever is on the wire now, we are missing the start of it
			rx_live <= 1'b0;
		end else begin
			if (rx_sof) rx_live <= 1'b1;
			if (rx_valid && (rx_sof || rx_live)) begin
				// Mirror every byte into the buffer; the reply is built by
				// editing this copy. `idx` rather than rx_idx because a
				// separate "if (rx_sof) rx_idx <= 0" would be overridden by
				// the increment below -- last assignment wins -- leaving the
				// second and every later frame misparsed.
				// idx is 11 bits and the buffer is 2048 deep, so it cannot run
				// past the end. An `idx < 11'd2048` guard here is always FALSE:
				// 2048 does not fit in 11 bits and truncates to zero.
				rx_waddr <= idx;
				rx_wdata <= rx_data;
				rx_we    <= 1'b1;
				rx_idx <= idx + 1'b1;
				case (idx)
				0,1,2,3,4,5:       dst_mac   <= {dst_mac[39:0], rx_data};
				6,7,8,9,10,11:     src_mac   <= {src_mac[39:0], rx_data};
				12,13:             ethertype <= {ethertype[7:0], rx_data};
				20,21:             arp_oper  <= {arp_oper[7:0], rx_data};
				22,23,24,25,26,27: arp_sha   <= {arp_sha[39:0], rx_data};
				28,29,30,31:       arp_spa   <= {arp_spa[23:0], rx_data};
				38,39,40,41:       arp_tpa   <= {arp_tpa[23:0], rx_data};
				default: ;
				endcase
				// IP and ARP overlap in offset but never in the same frame,
				// so both are latched and the classifier picks.
				case (idx)
				14:                ip_verihl <= rx_data;
				16,17:             ip_len    <= {ip_len[7:0], rx_data};
				23:                ip_proto  <= rx_data;
				26,27,28,29:       ip_src    <= {ip_src[23:0], rx_data};
				30,31,32,33:       ip_dst    <= {ip_dst[23:0], rx_data};
				default: ;
				endcase
				case (idx)
				34: begin icmp_type <= rx_data; udp_sport[15:8] <= rx_data; end
				35: begin icmp_code <= rx_data; udp_sport[7:0]  <= rx_data; end
				36: begin icmp_cksum[15:8] <= rx_data; udp_dport[15:8] <= rx_data; end
				37: begin icmp_cksum[7:0]  <= rx_data; udp_dport[7:0]  <= rx_data; end
				42,43:             fl_magic <= {fl_magic[7:0], rx_data};
				44:                fl_ver   <= rx_data;
				45:                fl_op    <= rx_data;
				49:                fl_count <= rx_data;
				50,51,52,53:       fl_addr  <= {fl_addr[23:0], rx_data};
				default: ;
				endcase
			end

			// Driven to "pending" rather than toggled: two frames arriving inside
			// one streamed packet would toggle it back to "nothing waiting".
			// Only a frame followed from its first byte: one we joined halfway
			// through sits in the buffer at the wrong offsets, and its header
			// fields are still the previous frame's. Taking it as a request once
			// turned a stale opcode and address into a write nobody asked for.
			if (rx_eof) begin
				rx_live <= 1'b0;
				if (rx_live && rx_crc_ok && (dst_is_us || dst_is_bcast) && rx_len >= 11'd42)
					req_tog <= ~req_seen;
			end
		end
	end

	always @(posedge clk) begin
		wr_en    <= 1'b0;
		tx_start <= 1'b0;
		bus_we   <= 1'b0;
		stream_frd <= 1'b0;
		bus_re   <= 1'b0;
		rx_frame <= 1'b0;
		tx_frame <= 1'b0;

		if (rst) begin
			state     <= S_RX;
			req_seen  <= 1'b0;
			tx_active <= 1'b0;
			st_gap <= 0;
			host_known <= 1'b0; st_off <= 0; st_frame <= 0; st_streaming <= 1'b0; stream_done_tog <= 1'b0;
			st_ipck <= 16'd0; st_wait <= 0; st_hold <= 2'd0;
			st_wa <= 0; st_cx <= 0;
		end else begin
			case (state)

			// ---------------------------------------------------------------
			S_RX: begin
				tx_active <= 1'b0;
				st_streaming <= 1'b0;
				if (st_gap != 17'h1FFFF) st_gap <= st_gap + 1'b1;
				if (st_hold != 2'd0) st_hold <= st_hold - 2'd1;

				if (req_tog != req_seen) begin
					// A request arrived, possibly while a streamed packet was going
					// out. It is already in fbuf; answer it before streaming on.
					req_seen <= req_tog;
					rx_frame <= 1'b1;
					state    <= S_CLASSIFY;
				end else if (stream_en && stream_direct && host_known && st_off == 0 && st_hold == 2'd0
				             && stream_fvalid && !stream_ready) begin
					// Between frames, and the word in hand is not the first of one:
					// it is what is left of a capture this core gave up on. Throw it
					// away, so that every frame starts at a capture's first pixel.
					stream_frd <= 1'b1;
					st_hold    <= 2'd3;
				end else if (stream_en && host_known && (st_off != 0 || stream_ready)
				             && st_gap >= ST_GAP_PKT && !rx_valid && st_hold == 2'd0) begin
					// nothing arriving: send the next slice of the frame
					st_n  <= (st_left > {9'd0, ST_PKT}) ? ST_PKT : st_left[8:0];
					st_i  <= 0;
					step  <= 0;
					st_streaming <= 1'b1;
					state <= S_ST_HDR;
				end
			end

			// ---------------------------------------------------------------
			S_CLASSIFY: begin
				step <= 0;
				if (ethertype == ET_ARP && arp_oper == 16'd1 && arp_tpa == IP_ADDR) begin
					state <= S_ARP;
				end else if (ethertype == ET_IPV4 && ip_dst == IP_ADDR
				             && ip_verihl == 8'h45) begin
					if (ip_proto == IP_ICMP && icmp_type == 8'd8)
						state <= S_IPCOMMON;
					else if (ip_proto == IP_UDP && udp_dport == UDP_PORT
					         && fl_magic == FL_MAGIC && fl_ver == FL_VER)
						state <= S_IPCOMMON;
					else
						state <= S_DROP;
				end else begin
					state <= S_DROP;
				end
			end

			S_DROP: state <= S_RX;

			// --- ARP reply --------------------------------------------------
			S_ARP: begin
				step <= step + 1'b1;
				case (step)
				0:  put(11'd0,  src_mac[47:40]);
				1:  put(11'd1,  src_mac[39:32]);
				2:  put(11'd2,  src_mac[31:24]);
				3:  put(11'd3,  src_mac[23:16]);
				4:  put(11'd4,  src_mac[15:8]);
				5:  put(11'd5,  src_mac[7:0]);
				6:  put(11'd6,  MAC_ADDR[47:40]);
				7:  put(11'd7,  MAC_ADDR[39:32]);
				8:  put(11'd8,  MAC_ADDR[31:24]);
				9:  put(11'd9,  MAC_ADDR[23:16]);
				10: put(11'd10, MAC_ADDR[15:8]);
				11: put(11'd11, MAC_ADDR[7:0]);
				12: put(11'd21, 8'd2);              // oper = reply
				13: put(11'd22, MAC_ADDR[47:40]);   // sender hardware = us
				14: put(11'd23, MAC_ADDR[39:32]);
				15: put(11'd24, MAC_ADDR[31:24]);
				16: put(11'd25, MAC_ADDR[23:16]);
				17: put(11'd26, MAC_ADDR[15:8]);
				18: put(11'd27, MAC_ADDR[7:0]);
				19: put(11'd28, IP_ADDR[31:24]);    // sender protocol = us
				20: put(11'd29, IP_ADDR[23:16]);
				21: put(11'd30, IP_ADDR[15:8]);
				22: put(11'd31, IP_ADDR[7:0]);
				23: put(11'd32, arp_sha[47:40]);    // target = whoever asked
				24: put(11'd33, arp_sha[39:32]);
				25: put(11'd34, arp_sha[31:24]);
				26: put(11'd35, arp_sha[23:16]);
				27: put(11'd36, arp_sha[15:8]);
				28: put(11'd37, arp_sha[7:0]);
				29: put(11'd38, arp_spa[31:24]);
				30: put(11'd39, arp_spa[23:16]);
				31: put(11'd40, arp_spa[15:8]);
				32: put(11'd41, arp_spa[7:0]);
				default: begin
					reply_len <= 11'd42;
					state     <= S_TX;
				end
				endcase
			end

			// --- MAC and IP swap, shared by ICMP and UDP --------------------
			S_IPCOMMON: begin
				step <= step + 1'b1;
				case (step)
				0:  put(11'd0,  src_mac[47:40]);
				1:  put(11'd1,  src_mac[39:32]);
				2:  put(11'd2,  src_mac[31:24]);
				3:  put(11'd3,  src_mac[23:16]);
				4:  put(11'd4,  src_mac[15:8]);
				5:  put(11'd5,  src_mac[7:0]);
				6:  put(11'd6,  MAC_ADDR[47:40]);
				7:  put(11'd7,  MAC_ADDR[39:32]);
				8:  put(11'd8,  MAC_ADDR[31:24]);
				9:  put(11'd9,  MAC_ADDR[23:16]);
				10: put(11'd10, MAC_ADDR[15:8]);
				11: put(11'd11, MAC_ADDR[7:0]);
				12: put(11'd22, 8'd64);             // fresh TTL
				13: put(11'd26, IP_ADDR[31:24]);
				14: put(11'd27, IP_ADDR[23:16]);
				15: put(11'd28, IP_ADDR[15:8]);
				16: put(11'd29, IP_ADDR[7:0]);
				17: put(11'd30, ip_src[31:24]);
				18: put(11'd31, ip_src[23:16]);
				19: put(11'd32, ip_src[15:8]);
				20: put(11'd33, ip_src[7:0]);
				default: begin
					step <= 0;
					if (ip_proto == IP_ICMP) state <= S_ICMP;
					else                     state <= S_FL_START;
				end
				endcase
			end

			// --- ICMP echo reply --------------------------------------------
			S_ICMP: begin
				step <= step + 1'b1;
				case (step)
				// Type 8 becomes type 0. Rather than re-summing the whole
				// message, adjust the checksum for that one word changing:
				// RFC 1624, HC' = ~(~HC + ~m + m').
				0: put(11'd34, 8'd0);
				1: begin
					cksum <= {1'b0, ~icmp_cksum} + {1'b0, ~{icmp_type, icmp_code}}
					         + {1'b0, {8'd0, icmp_code}};
				end
				2: put(11'd36, ~fold(cksum) >> 8);
				3: put(11'd37, ~fold(cksum) & 16'h00FF);
				default: begin
					// An echo reply is the same size as the request.
					reply_len <= 11'd14 + ip_len;
					step      <= 0;
					state     <= S_CKZERO;
				end
				endcase
			end

			// --- fpgalink ----------------------------------------------------
			S_FL_START: begin
				host_mac <= src_mac; host_ip <= ip_src; host_known <= 1'b1;
				err_code   <= 2'd0;
				word_i     <= 0;
				cur_addr   <= fl_addr;
				resp_count <= 0;
				is_write   <= (fl_op == OP_WRITE);

				case (fl_op)
				OP_IDENT: begin
					words_todo <= 8'd4;
					state      <= S_FL_WRRESP;   // answered from constants
				end
				OP_READ: begin
					words_todo <= 8'd1;
					state      <= S_FL_BUS;
				end
				OP_WRITE: begin
					words_todo <= fl_count;
					state      <= S_FL_RDREQ;
				end
				OP_RDBLK: begin
					// The request payload's first word is the count.
					words_todo <= 8'd1;
					state      <= S_FL_RDREQ;
				end
				default: begin
					err_code   <= 2'd2;          // unknown opcode -> status 0x02
					words_todo <= 0;
					state      <= S_FL_HDR;
				end
				endcase
				step <= 0;
			end

			// Pull one 32-bit big-endian word out of the request payload.
			S_FL_RDREQ: begin
				step <= step + 1'b1;
				case (step)
				0: fsm_rd_addr <= 11'd54 + {word_i, 2'b00};
				1: fsm_rd_addr <= 11'd54 + {word_i, 2'b00} + 11'd1;
				2: begin cur_word[31:24] <= rd_q; fsm_rd_addr <= 11'd54 + {word_i, 2'b00} + 11'd2; end
				3: begin cur_word[23:16] <= rd_q; fsm_rd_addr <= 11'd54 + {word_i, 2'b00} + 11'd3; end
				4: cur_word[15:8] <= rd_q;
				5: cur_word[7:0]  <= rd_q;
				default: begin
					step <= 0;
					if (fl_op == OP_RDBLK) begin
						// That word was the requested length, not data.
						words_todo <= (cur_word[7:0] == 0) ? 8'd1 : cur_word[7:0];
						state      <= S_FL_BUS;
					end else begin
						state <= S_FL_BUS;       // write it to the bus
					end
				end
				endcase
			end

			S_FL_BUS: begin
				bus_addr <= cur_addr;
				if (is_write) begin
					bus_wdata <= cur_word;
					bus_we    <= 1'b1;
				end else begin
					bus_re <= 1'b1;
				end

				if (bus_ack) begin
					bus_we <= 1'b0;
					bus_re <= 1'b0;
					if (bus_err != 2'd0 && err_code == 2'd0)
						err_code <= bus_err;
					if (!is_write) cur_word <= bus_rdata;
					step  <= 0;
					state <= is_write ? S_FL_NEXT : S_FL_WRRESP;
				end
			end

			// Place one response word into the reply payload.
			S_FL_WRRESP: begin
				step <= step + 1'b1;
				if (fl_op == OP_IDENT) begin
					case (step)
					0: put(11'd54, 8'h46);
					1: put(11'd55, 8'h50);
					2: put(11'd56, 8'h47);
					3: put(11'd57, 8'h41);
					4: put(11'd58, GATEWARE_VERSION[31:24]);
					5: put(11'd59, GATEWARE_VERSION[23:16]);
					6: put(11'd60, GATEWARE_VERSION[15:8]);
					7: put(11'd61, GATEWARE_VERSION[7:0]);
					8:  put(11'd62, 8'd0);
					9:  put(11'd63, 8'd0);
					10: put(11'd64, 8'd0);
					11: put(11'd65, 8'd1);       // caps
					12: put(11'd66, uptime_ms[31:24]);
					13: put(11'd67, uptime_ms[23:16]);
					14: put(11'd68, uptime_ms[15:8]);
					15: put(11'd69, uptime_ms[7:0]);
					default: begin
						resp_count <= 8'd4;
						step       <= 0;
						state      <= S_FL_HDR;
					end
					endcase
				end else begin
					case (step)
					0: put(11'd54 + {word_i, 2'b00},          cur_word[31:24]);
					1: put(11'd54 + {word_i, 2'b00} + 11'd1,  cur_word[23:16]);
					2: put(11'd54 + {word_i, 2'b00} + 11'd2,  cur_word[15:8]);
					3: put(11'd54 + {word_i, 2'b00} + 11'd3,  cur_word[7:0]);
					default: begin
						resp_count <= word_i + 8'd1;
						step       <= 0;
						state      <= S_FL_NEXT;
					end
					endcase
				end
			end

			S_FL_NEXT: begin
				step <= 0;
				if (word_i + 8'd1 >= words_todo) begin
					state <= S_FL_HDR;
				end else begin
					word_i   <= word_i + 8'd1;
					cur_addr <= cur_addr + 32'd4;
					state    <= is_write ? S_FL_RDREQ : S_FL_BUS;
				end
			end

			// fpgalink response header
			S_FL_HDR: begin
				step <= step + 1'b1;
				case (step)
				0: put(11'd45, fl_op | 8'h80);
				1: put(11'd48, (err_code == 2'd0) ? 8'h00 :
				               (err_code == 2'd1) ? 8'h03 :
				               (err_code == 2'd2) ? 8'h04 : 8'h02);
				2: put(11'd49, resp_count);
				default: begin
					step  <= 0;
					state <= S_UDPHDR;
				end
				endcase
			end

			// --- UDP and IP lengths ------------------------------------------
			S_UDPHDR: begin
				step <= step + 1'b1;
				case (step)
				0: put(11'd34, UDP_PORT[15:8]);          // we are the source now
				1: put(11'd35, UDP_PORT[7:0]);
				2: put(11'd36, udp_sport[15:8]);         // back to their port
				3: put(11'd37, udp_sport[7:0]);
				// UDP header 8 + fpgalink header 12 + payload
				4: put(11'd38, (16'd20 + {resp_count, 2'b00}) >> 8);
				5: put(11'd39, (16'd20 + {resp_count, 2'b00}) & 16'h00FF);
				6: put(11'd40, 8'd0);                    // checksum optional in IPv4
				7: put(11'd41, 8'd0);
				8: put(11'd16, (16'd40 + {resp_count, 2'b00}) >> 8);   // IP total length
				9: put(11'd17, (16'd40 + {resp_count, 2'b00}) & 16'h00FF);
				default: begin
					reply_len <= 11'd54 + {resp_count, 2'b00};
					step      <= 0;
					state     <= S_CKZERO;
				end
				endcase
			end

			// --- IP header checksum ------------------------------------------
			// --- the streamer: headers, then words off the bus, then the checksum and out
			S_ST_HDR: begin
				step <= step + 1'b1;
				case (step)
				0:  begin put(11'd0, host_mac[47:40]); st_ipck <= ~st_ipf2; end
				1:  put(11'd1,  host_mac[39:32]);
				2:  put(11'd2,  host_mac[31:24]);
				3:  put(11'd3,  host_mac[23:16]);
				4:  put(11'd4,  host_mac[15:8]);
				5:  put(11'd5,  host_mac[7:0]);
				6:  put(11'd6,  MAC_ADDR[47:40]);
				7:  put(11'd7,  MAC_ADDR[39:32]);
				8:  put(11'd8,  MAC_ADDR[31:24]);
				9:  put(11'd9,  MAC_ADDR[23:16]);
				10: put(11'd10, MAC_ADDR[15:8]);
				11: put(11'd11, MAC_ADDR[7:0]);
				12: put(11'd12, 8'h08);
				13: put(11'd13, 8'h00);
				14: put(11'd14, 8'h45);                       // IPv4, 20-byte header
				15: put(11'd15, 8'h00);
				16: put(11'd16, {5'd0, st_iplen[10:8]});      // total length = ours - 14
				17: put(11'd17, st_iplen[7:0]);
				18: put(11'd18, st_frame[15:8]);              // identification
				19: put(11'd19, st_frame[7:0]);
				20: put(11'd20, 8'h40);                       // don't fragment
				21: put(11'd21, 8'h00);
				22: put(11'd22, 8'd64);                       // TTL
				23: put(11'd23, IP_UDP);
				24: put(11'd24, st_ipck[15:8]);               // worked out at step 0
				25: put(11'd25, st_ipck[7:0]);
				26: put(11'd26, IP_ADDR[31:24]);
				27: put(11'd27, IP_ADDR[23:16]);
				28: put(11'd28, IP_ADDR[15:8]);
				29: put(11'd29, IP_ADDR[7:0]);
				30: put(11'd30, host_ip[31:24]);
				31: put(11'd31, host_ip[23:16]);
				32: put(11'd32, host_ip[15:8]);
				33: put(11'd33, host_ip[7:0]);
				34: put(11'd34, UDP_PORT[15:8]);              // from our port
				35: put(11'd35, UDP_PORT[7:0]);
				36: put(11'd36, stream_port[15:8]);           // to the host's stream port
				37: put(11'd37, stream_port[7:0]);
				38: put(11'd38, {5'd0, st_udplen[10:8]});     // UDP length = ours - 34
				39: put(11'd39, st_udplen[7:0]);
				40: put(11'd40, 8'h00);                       // no UDP checksum
				41: put(11'd41, 8'h00);
				42: put(11'd42, 8'h46);                       // "FS": a frame slice
				43: put(11'd43, 8'h53);
				44: put(11'd44, st_frame[15:8]);
				45: put(11'd45, st_frame[7:0]);
				46: put(11'd46, 8'd0);                        // word offset, 32 bits
				47: put(11'd47, {6'd0, st_off[17:16]});
				48: put(11'd48, st_off[15:8]);
				49: put(11'd49, st_off[7:0]);
				50: put(11'd50, 8'd0);                        // words in the frame, 32 bits
				51: put(11'd51, {6'd0, stream_words[17:16]});
				52: put(11'd52, stream_words[15:8]);
				53: put(11'd53, stream_words[7:0]);
				54: put(11'd54, {7'd0, st_n[8]});             // words in this packet
				55: put(11'd55, st_n[7:0]);
				default: begin step <= 0; state <= S_ST_RD; end
				endcase
			end

			S_ST_RD: if (stream_direct) begin                 // one word from the scanout
				if (stream_fvalid && stream_ready && (st_off != 0 || st_i != 0)) begin
					// The first word of a NEW capture, in the middle of this frame:
					// the game flipped while the old one was being read, and the
					// scanout gave it up and started on the new picture. Give this
					// frame up too -- unfinished, it never completes on the host,
					// so it is never shown -- and start the new one at offset 0
					// under a new id. The word is left where it is for that.
					st_wait      <= 0;
					st_off       <= 0; st_wa <= 0; st_cx <= 0;
					st_streaming <= 1'b0;
					st_frame     <= st_frame + 1'b1;
					state        <= S_RX;
				end else if (stream_fvalid) begin
					cur_word   <= stream_fdata;
					stream_frd <= 1'b1;
					step       <= 0;
					st_wait    <= 0;
					state      <= S_ST_PUT;
				end else if (st_wait >= 17'd50000) begin
					// A millisecond with nothing from the scanout. Give this frame
					// up and go back to listening: while this state waits, the
					// whole core waits, and the board answers nothing at all --
					// not a register read, not even a ping. Nothing may be
					// allowed to hold this state machine indefinitely.
					st_wait      <= 0;
					st_off       <= 0; st_wa <= 0; st_cx <= 0;
					st_streaming <= 1'b0;
					// A NEW id for whatever goes out next. Without this the
					// abandoned frame and the one after it shared an id, so the
					// host merged them: the words that arrived twice made up the
					// count for the ones never sent, the frame counted as whole,
					// and the page drew a picture with a black band where the
					// tail should be. That is the half-a-screen the game shows
					// when a scene gets heavy enough to starve the scanout.
					st_frame     <= st_frame + 1'b1;
					stream_done_tog <= ~stream_done_tog;   // ask for another scan
					state        <= S_RX;
				end else st_wait <= st_wait + 1'b1;
			end else begin                                    // one word off the bus
				bus_addr <= stream_base + {12'd0, st_wa, 2'b00};
				bus_re   <= 1'b1;
				if (bus_ack) begin
					bus_re   <= 1'b0;
					cur_word <= bus_rdata;
					step     <= 0;
					state    <= S_ST_PUT;
				end
			end

			S_ST_PUT: begin                                   // big-endian, like a reply's words
				step <= step + 1'b1;
				case (step)
				0: put(11'd56 + {st_i, 2'b00},          cur_word[31:24]);
				1: put(11'd56 + {st_i, 2'b00} + 11'd1,  cur_word[23:16]);
				2: put(11'd56 + {st_i, 2'b00} + 11'd2,  cur_word[15:8]);
				3: put(11'd56 + {st_i, 2'b00} + 11'd3,  cur_word[7:0]);
				default: begin
					step <= 0;
					// on to the next word, stepping over the rest of the row at its end
					if (stream_rowlen != 16'd0 && st_cx + 16'd1 == stream_rowlen) begin
						st_cx <= 16'd0;
						st_wa <= st_wa + {2'd0, st_skip} + 18'd1;
					end else begin
						st_cx <= st_cx + 16'd1;
						st_wa <= st_wa + 18'd1;
					end
					if (st_i + 9'd1 == st_n) begin
						reply_len <= st_bytes;
						state     <= S_ST_SEND;               // the header is already right
					end else begin
						st_i  <= st_i + 9'd1;
						state <= S_ST_RD;
					end
				end
				endcase
			end

			// The header is already right, so the packet goes straight to the
			// transmitter without the read-back-and-walk the reply path uses.
			S_ST_SEND: begin
					tx_active <= 1'b1;
					tx_len    <= reply_len;
					tx_start  <= 1'b1;
					state     <= S_TXWAIT;
				end

			S_CKZERO: begin
				step <= step + 1'b1;
				case (step)
				0: put(11'd24, 8'd0);
				1: put(11'd25, 8'd0);
				default: begin
					cksum       <= 0;
					ck_i        <= 0;
					fsm_rd_addr <= 11'd14;
					step        <= 0;
					state       <= S_CKREAD;
				end
				endcase
			end

			// Sum the 20 header bytes as ten big-endian 16-bit words. The read
			// port has a cycle of latency, so the byte being added is the one
			// requested two steps ago.
			S_CKREAD: begin
				fsm_rd_addr <= 11'd14 + ck_i + 11'd1;
				if (ck_i >= 11'd1) begin
					if (ck_i[0] == 1'b1) cksum <= fold(cksum + {1'b0, rd_q, 8'd0});
					else                 cksum <= fold(cksum + {9'd0, rd_q});
				end
				if (ck_i == 11'd20) begin
					step  <= 0;
					state <= S_CKWRITE;
				end else ck_i <= ck_i + 1'b1;
			end

			S_CKWRITE: begin
				step <= step + 1'b1;
				case (step)
				0: put(11'd24, ~fold(cksum) >> 8);
				1: put(11'd25, ~fold(cksum) & 16'h00FF);
				default: state <= S_TX;
				endcase
			end

			// ---------------------------------------------------------------
			S_TX: begin
				tx_active <= 1'b1;
				tx_len    <= reply_len;
				tx_start  <= 1'b1;
				state     <= S_TXWAIT;
			end

			S_TXWAIT: begin
				tx_active <= 1'b1;
				if (tx_busy) begin
					// wait for it to finish
				end else if (!tx_start) begin
					tx_frame  <= 1'b1;
					tx_active <= 1'b0;
					if (st_streaming) begin
						st_gap <= 0;
						if (st_off + {9'd0, st_n} >= stream_words) begin
							st_off <= 0; st_wa <= 0; st_cx <= 0;
							st_frame <= st_frame + 1'b1; stream_done_tog <= ~stream_done_tog;
						end else st_off <= st_off + {9'd0, st_n};
					end
					state     <= S_RX;
				end
			end

			default: state <= S_RX;
			endcase
		end
	end

endmodule

`default_nettype wire
