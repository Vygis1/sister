//////////////////////////////////////////////////////////////////////////////////
// ps1_cdrom.v - the CD-ROM controller, with a drive behind it that reads a
//               disc image somebody else holds.
//
// The register face is the HC05 protocol (psx-spx "CDROM Drive"): the four
// byte registers at 1F801800h-1F801803h with the index selector, the parameter
// and response FIFOs, the interrupt enable/flag pair, and the first/second
// response scheme in which a command acknowledges with INT3(stat) after a delay
// and finishes later with INT2, or fails with INT5. The second response waits
// until the first has been acknowledged (HCLRCTL), as on the chip.
//
// --- the drive ---------------------------------------------------------------------
//
// Behind the registers is a drive with a licensed disc in it, one data track
// (MODE2/2352, as a .bin/.cue rips it). Setloc/SeekL/SeekP move the head;
// ReadN/ReadS deliver a sector every sector period (1/75 s, or 1/150 s at
// double speed) with INT1(stat), into a ring of eight raw 2352-byte sectors.
// The CPU asks for the data with HCHPCTL bit 7 and takes it through RDDATA a
// byte at a time, or DMA channel 3 takes it a word at a time: 2048 bytes from
// offset 24 of the raw sector, or 2340 from offset 12 when Setmode says whole
// sectors.
//
// --- where the sectors come from --------------------------------------------------
//
// The image is not in the FPGA: it is on the ESP32's card (or wherever the
// transport gets it). This module says which sector it wants next (`fill_lba`)
// and how many it has room for (`fill_room`); the transport writes that sector's
// 2352 bytes into the next free slot of the ring (`sb_we/sb_addr/sb_data`) and
// says so (`sb_done`). Sectors arrive in order from `fill_lba`; a seek that
// jumps elsewhere empties the ring and starts the chain again. If the sector
// the drive is due to deliver has not arrived, INT1 simply waits for it -- a
// real drive is late sometimes too, and every game tolerates that.
//
// Addressing: Setloc gives BCD minutes:seconds:frames; sector 0 of the image
// is 00:02:00, so LBA = (mm*60 + ss)*75 + ff - 150.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module ps1_cdrom #(
	parameter ACK_CYCLES    = 20000,     // command -> INT3 first response
	parameter SECOND_CYCLES = 120000,    // INT3 acknowledged -> INT2/INT5 second response
	parameter SEEK_CYCLES   = 2000000,   // a seek: 40 ms (the real drive: 40-800 ms)
	parameter SECTOR_1X     = 666667,    // 1/75 s at 50 MHz
	parameter SECTOR_2X     = 333333,    // 1/150 s
	parameter [23:0] LAST_LBA = 24'd268742   // Crash Bandicoot (USA): 632083536 / 2352 sectors
)(
	input  wire        clk,
	input  wire        rst,
	// the CPU's byte accesses, one word port: addr[1:0] and be say which register
	input  wire        sel,
	input  wire        we,
	input  wire [3:0]  addr,
	input  wire [3:0]  be,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	output wire        irq,           // I_STAT bit 2 source (level while a flag is enabled)

	// --- DMA channel 3: a word of sector data at a time ------------------------------
	input  wire        dma_rd,        // take the next word
	output reg  [31:0] dma_rdata,
	output reg         dma_rvalid,

	// --- the sector transport ----------------------------------------------------------
	input  wire        disc_in,       // the transport has an image to serve: a disc is in the drive
	output reg  [23:0] fill_lba,      // the sector wanted next
	output wire [3:0]  fill_room,     // how many more the ring can take
	output wire        fill_run,      // the drive is reading: keep them coming
	input  wire        sb_we,         // a byte of the sector being delivered
	input  wire [11:0] sb_addr,       // 0..2351 within it
	input  wire [7:0]  sb_data,
	input  wire        sb_done,       // the whole sector is in
	input  wire [23:0] sb_lba,        // ...and it is this one: accepted only if it is fill_lba
	input  wire        sb_abort,      // (the transport gave up on it: forget the bytes so far)

	// what it is doing, for debug registers: the state, the last four commands,
	// the last Setloc's digits and the mode, and the last seek target
	output wire [31:0] dbg,
	output reg  [31:0] dbg_cmds,
	output reg  [31:0] dbg_setloc,
	output wire [31:0] dbg_seek,
	output wire [31:0] dbg_hdr,         // the last delivered sector's header bytes 12..15 (mm ss ff mode)
	// a trace of the last 64 commands: {cmd, p0, p1, p2}, read by index
	input  wire        ev_v,           // something outside worth a trace entry (a DMA start)
	input  wire [31:0] ev_data,
	input  wire [5:0]  trace_idx,
	output wire [31:0] trace_data,
	output wire [5:0]  trace_wp
);
	reg [31:0] trace [0:63];
	reg [5:0]  trace_w;
	reg        tr_v;                  // an entry chosen last clock, waiting for the RAM
	reg [31:0] tr_d;
	reg [31:0] trace_q;               // registered: a 64-way mux is not for a bus read's own clock
	always @(posedge clk) trace_q <= trace[trace_idx];
	assign trace_data = trace_q;
	assign trace_wp   = trace_w;
	// ==================================================================================
	// the ring of sectors
	// ==================================================================================
	localparam SLOTS = 8;
	reg [7:0]  ring [0:SLOTS*2352-1];
	// Three pointers walk the ring: sectors are FILLED by the transport,
	// DELIVERED (INT1) a period at a time, and LOADED into the data FIFO by the
	// CPU's HCHPCTL bit 7, in order and independently of one another -- as the
	// chip's own eight-sector buffer works. A game that acknowledges INT1 late
	// still gets that sector's data when it asks, not the one after.
	reg [2:0]  r_wp, r_rp, r_lp;      // slots: filled next, delivered next, loaded next
	reg [3:0]  r_cnt;                 // filled, not yet delivered
	reg [3:0]  ld_cnt;                // delivered, not yet loaded
	reg [23:0] r_base;                // the LBA in slot r_rp
	// the slot the FIFO is reading is r_lp - 1: never write over it
	wire [3:0] held = r_cnt + ld_cnt;
	assign fill_room = (held >= 4'd7) ? 4'd0 : (4'd7 - held);
	wire ring_has = (r_cnt != 4'd0);

	// the transport's byte lands in the slot being filled
	wire [14:0] w_addr = r_wp * 15'd2352 + {3'd0, sb_addr};
	always @(posedge clk) if (sb_we) ring[w_addr] <= sb_data;

	// ==================================================================================
	// registers and the sequencer
	// ==================================================================================
	reg [1:0]  index;
	reg [7:0]  stat;                  // 0 error, 1 motor, 2 seek err, 3 id err, 4 shell, 5 read, 6 seek, 7 play
	reg [2:0]  int_flag;              // HINTSTS bits 2:0 (INT number, 0 = none)
	reg [4:0]  int_mask;              // HINTMSK bits 4:0
	reg        busy;                  // BUSYSTS: a command is being processed
	reg [7:0]  mode;                  // Setmode: bit 7 2x, bit 5 whole sector, bit 4 ignore, ...
	// parameter FIFO (16 bytes) and response FIFO (16 bytes)
	reg [7:0]  prm [0:15];
	reg [4:0]  prm_wr, prm_rd;
	reg [7:0]  rsp [0:15];
	reg [4:0]  rsp_wr, rsp_rd;
	wire       prm_empty = (prm_wr == prm_rd);
	wire       prm_full  = (prm_wr[3:0] == prm_rd[3:0]) && (prm_wr[4] != prm_rd[4]);
	wire       rsp_empty = (rsp_wr == rsp_rd);
	// the command in flight and its scheduling
	reg [7:0]  cmd;
	reg        cmd_pend;
	reg [21:0] timer;
	reg        second_pend;
	reg [2:0]  second_int;
	reg [7:0]  second_b [0:7];
	reg [3:0]  second_len;
	reg        second_wait;
	// the drive
	reg [23:0] loc;                   // Setloc target (LBA)
	reg        loc_v;                 // set since the last seek
	reg [23:0] pos;                   // where the head is
	reg        seeking, reading;
	reg        read_s;                // ReadS: no retries (same here)
	reg [21:0] sec_timer;
	reg        seek_then_read;        // a read issued with a pending Setloc: seek first
	// the delivered sector: which slot, and the data FIFO over it
	reg [2:0]  cur_slot;
	reg        cur_v;
	reg [2:0]  fifo_slot;             // the slot the data FIFO was loaded from (HCHPCTL bit 7)
	reg [7:0]  cur_hdr [0:7];         // its header + subheader, for GetlocL
	reg [11:0] fifo_rd;               // byte offset of the next byte out
	reg [11:0] fifo_end;              // one past the last
	reg        bfrd;                  // HCHPCTL bit 7: the FIFO is loaded
	reg        bfrd_pend;             // ...asked for with nothing delivered yet: load the next one when it comes
	wire       fifo_has = bfrd && (fifo_rd != fifo_end);
	reg [7:0]  fifo_byte;             // the byte at fifo_rd, a clock behind
	reg        fb_ok;                 // ...and whether there was one
	wire [14:0] f_addr = fifo_slot * 15'd2352 + {3'd0, fifo_rd};
	always @(posedge clk) begin fifo_byte <= ring[f_addr]; fb_ok <= fifo_has; end

	assign irq = (int_flag != 3'd0) && ((int_mask[2:0] & int_flag) != 3'd0);
	assign fill_run = reading || seeking;
	assign dbg = {stat, reading, seeking, cur_v, r_cnt[2:0], fill_lba[17:0]};   // 8+1+1+1+3+18 = 32
	assign dbg_seek = {int_flag, 5'd0, loc};
	assign dbg_hdr  = {cur_hdr[0], cur_hdr[1], cur_hdr[2], cur_hdr[3]};

	// BCD helpers
	function [7:0] bin2bcd; input [7:0] b; bin2bcd = ((b / 8'd10) << 4) | (b % 8'd10); endfunction
	function [7:0] bcd2bin; input [7:0] b; bcd2bin = b[7:4] * 8'd10 + b[3:0]; endfunction
	// the head's position as mm:ss:ff too, kept in step with `pos` (a divide by
	// 75 of a 24-bit number every clock is not something to put on the chip):
	// set from Setloc's own digits at a seek, counted up a frame per sector
	reg [7:0] pos_mm, pos_ss, pos_ff;   // binary
	reg [7:0] loc_mm, loc_ss, loc_ff;   // Setloc's, binary
	localparam [23:0] END_S  = (LAST_LBA + 24'd151) / 75;
	localparam [7:0]  END_MM = END_S / 60;
	localparam [7:0]  END_SS = END_S % 60;
	wire [7:0] end_mm = END_MM, end_ss = END_SS;

	// --- the read side (combinational, like the other I/O) ---------------------
	wire [7:0] hsts = {busy, fifo_has, !rsp_empty, !prm_full, prm_empty, 1'b0, index};
	wire [7:0] r1   = rsp_empty ? 8'h00 : rsp[rsp_rd[3:0]];
	wire [7:0] r2   = fifo_has ? fifo_byte : 8'h00;
	wire [7:0] r3   = index[0] ? {3'b111, 2'b00, int_flag} : {3'b111, int_mask};
	// A 32-bit read of 1F801800h returns HSTS four times and touches no FIFO
	// (the BIU's auto-increment is off by default, and DMA needs it off). Only a
	// byte read of RDDATA pops a data byte, and only a byte read of RESULT pops
	// a response byte: the byte enables say which, so the processor has to send
	// real ones on loads (r3000.v). When every load claimed all four bytes, each
	// poll of the status register popped a byte of sector data, and the game's
	// sectors arrived three bytes short at the front.
	always @(*) rdata = (be == 4'b1111) ? {4{hsts}} : {r3, r2, r1, hsts};

	// a CPU byte read of RDDATA pops a byte; a DMA word gathers four over five
	// clocks (fifo_byte is a clock behind fifo_rd)
	wire cpu_pop = sel && !we && (be == 4'b0100) && fifo_has;
	reg  [2:0]  dma_st;               // 0 idle, 1..4 taking bytes 0..3
	reg  [7:0]  dma_dry;              // DMA bytes served with the FIFO empty, since the last load (for the trace)
	reg         int1_fire;            // a sector just became current: capture its header
	// A sector is taken only if its own header (bytes 12-14: minute, second,
	// frame, BCD) says it is the one wanted: the transport labels its frames,
	// but a label is a claim, and a mislabelled sector in the ring is a wrong
	// sector delivered under the right number with no trace of it.
	reg  [7:0]  hdr_mm, hdr_ss, hdr_ff;
	always @(posedge clk) if (sb_we) begin
		if (sb_addr == 12'd12) hdr_mm <= sb_data;
		if (sb_addr == 12'd13) hdr_ss <= sb_data;
		if (sb_addr == 12'd14) hdr_ff <= sb_data;
	end
	// Registered, not live: this is two multiplies and an add from bytes that
	// arrive two thousand bytes before the frame ends, and computing it in the
	// clock it is used put it on the critical path of the whole design.
	reg  [23:0] hdr_lba;
	always @(posedge clk)
		hdr_lba <= (bcd2bin(hdr_mm) * 24'd60 + bcd2bin(hdr_ss)) * 24'd75 + bcd2bin(hdr_ff) - 24'd150;
	wire        sb_take = sb_done && (sb_lba == fill_lba) && (hdr_lba == fill_lba) && (held < 4'd7);
	reg  [15:0] sb_mislabelled;      // frames whose header did not match their label (a debug count)
	always @(posedge clk) if (rst) sb_mislabelled <= 16'd0; else if (sb_done && (sb_lba == fill_lba) && (hdr_lba != fill_lba)) sb_mislabelled <= sb_mislabelled + 16'd1;
	wire        want_wr   = sel && we && be[3] && (index == 2'd0) && wdata[31];
	wire        fifo_load = (want_wr || bfrd_pend) && (ld_cnt != 4'd0) && !(bfrd && fifo_has);
	wire        pop = reading && (sec_timer == (mode[7] ? SECTOR_2X[21:0] : SECTOR_1X[21:0]))
	                  && ring_has && int_flag == 3'd0 && !cmd_pend && !second_wait && !seeking;

	integer k;
	always @(posedge clk) begin
		if (rst) begin
			index <= 2'd0; stat <= 8'h02; int_flag <= 3'd0; int_mask <= 5'd0; busy <= 1'b0; mode <= 8'h00;
			prm_wr <= 5'd0; prm_rd <= 5'd0; rsp_wr <= 5'd0; rsp_rd <= 5'd0;
			cmd <= 8'd0; cmd_pend <= 1'b0; timer <= 22'd0; dbg_cmds <= 32'd0; dbg_setloc <= 32'd0; trace_w <= 6'd0;
			tr_v <= 1'b0; tr_d <= 32'd0;
			second_pend <= 1'b0; second_int <= 3'd0; second_len <= 4'd0; second_wait <= 1'b0;
			for (k = 0; k < 8; k = k + 1) second_b[k] <= 8'd0;
			loc <= 24'd0; loc_v <= 1'b0; pos <= 24'd0; seeking <= 1'b0; reading <= 1'b0; read_s <= 1'b0;
			pos_mm <= 8'd0; pos_ss <= 8'd2; pos_ff <= 8'd0; loc_mm <= 8'd0; loc_ss <= 8'd2; loc_ff <= 8'd0;
			sec_timer <= 22'd0; seek_then_read <= 1'b0;
			cur_slot <= 3'd0; cur_v <= 1'b0; fifo_slot <= 3'd0; fifo_rd <= 12'd0; fifo_end <= 12'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0;
			r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; r_cnt <= 4'd0; ld_cnt <= 4'd0; r_base <= 24'd0; fill_lba <= 24'd0;
			dma_rdata <= 32'd0; dma_rvalid <= 1'b0; dma_st <= 3'd0; int1_fire <= 1'b0; dma_dry <= 8'd0;
		end else begin
			dma_rvalid <= 1'b0; int1_fire <= 1'b0;

			// ---- the ring: a sector arrives, a sector is taken ----
			if (sb_take) begin
				r_wp  <= r_wp + 3'd1;
				fill_lba <= fill_lba + 24'd1;
			end
			r_cnt  <= r_cnt + {3'd0, sb_take} - {3'd0, pop};
			ld_cnt <= ld_cnt + {3'd0, pop} - {3'd0, fifo_load};

			// ---- the trace: what happened around the data path, one entry a clock ----
			//   D3 = DMA3 start (from ps1_dma), D4 = DMA3 done {dry words, words so far},
			//   B0 = HCHPCTL write {value, ld_cnt, bfrd, fifo_has, fifo_load, r_cnt},
			//   11 = INT1: a sector became current {its position}
			// PIPELINED, and the reason is worth knowing: the entry was built
			// combinationally from the processor's address decode and written
			// straight into the trace's block RAM, and on a chip at 93% that
			// path was the WORST in the whole design -- 19.6 ns of which 15 was
			// routing, setting the clock for the entire console from a
			// diagnostic buffer. Choosing the entry a clock early costs nothing
			// (the trace is for reading afterwards, never for control) and hands
			// the router two short paths instead of one long one.
			tr_v <= 1'b0;
			if (!(sel && we && be[1] && index == 2'd0)) begin
				if (ev_v) begin
					tr_v <= 1'b1;
					tr_d <= (ev_data[31:24] == 8'hD4) ? {ev_data[31:24], dma_dry, ev_data[15:0]} : ev_data;
				end else if (sel && we && be[3] && index == 2'd0) begin
					tr_v <= 1'b1;
					tr_d <= {8'hB0, wdata[31:24], ld_cnt, bfrd, fifo_has, fifo_load, 1'b0, r_cnt, 4'd0};
				end else if (int1_fire) begin
					tr_v <= 1'b1;
					tr_d <= {8'h11, pos[23:0]};
				end else if (sb_done && (sb_lba == fill_lba)) begin
					// a frame for the sector wanted: 5B = taken, 5E = refused because
					// its own header says it is another sector (then that header)
					tr_v <= 1'b1;
					tr_d <= {(hdr_lba == fill_lba) ? 8'h5B : 8'h5E, hdr_lba[23:0]};
				end
			end
			// the write itself, a clock behind, out of a register
			if (tr_v) begin
				trace[trace_w] <= tr_d;
				trace_w <= trace_w + 6'd1;
			end
			if (fifo_load) dma_dry <= 8'd0;
			// ---- CPU access ----
			if (sel && we) begin
				if (be[0]) index <= wdata[1:0];                                  // 1F801800: ADDRESS
				if (be[1] && index == 2'd0) begin                                // 1F801801.0: COMMAND
					cmd <= wdata[15:8]; cmd_pend <= 1'b1; busy <= 1'b1; timer <= 22'd0;
					dbg_cmds <= {dbg_cmds[23:0], wdata[15:8]};
					tr_v <= 1'b1;
					tr_d <= {wdata[15:8], prm[0], prm[1], prm[2]};
				end
				if (be[2]) begin
					case (index)
					2'd0: if (!prm_full) begin prm[prm_wr[3:0]] <= wdata[23:16]; prm_wr <= prm_wr + 5'd1; end  // PARAMETER
					2'd1: int_mask <= wdata[20:16];                                // HINTMSK
					default: ;
					endcase
				end
				if (be[3]) begin
					case (index)
					2'd0: begin                                                    // HCHPCTL: bit 7 loads the data FIFO
						if (wdata[31]) begin
							// load the next delivered sector, unless one is still being
							// read; with none delivered yet, remember the wish
							if (!fifo_load && !(bfrd && fifo_has)) bfrd_pend <= 1'b1;
						end else begin
							bfrd <= 1'b0; bfrd_pend <= 1'b0; fifo_rd <= 12'd0; fifo_end <= 12'd0;
						end
					end
					2'd1: begin                                                    // HCLRCTL
						if (wdata[26:24] != 3'd0) begin
							int_flag <= 3'd0;                                      // acknowledge
							rsp_rd <= rsp_wr;                                      // the response is consumed with it
							if (second_pend) begin second_wait <= 1'b1; timer <= 22'd0; end
						end
						if (wdata[30]) begin prm_wr <= 5'd0; prm_rd <= 5'd0; end   // clear parameter FIFO
						if (wdata[31]) begin                                       // reset decoder
							int_flag <= 3'd0; second_pend <= 1'b0; second_wait <= 1'b0; busy <= 1'b0; cmd_pend <= 1'b0;
							rsp_wr <= 5'd0; rsp_rd <= 5'd0; prm_wr <= 5'd0; prm_rd <= 5'd0;
						end
					end
					default: ;
					endcase
				end
			end else if (sel && !we && (be == 4'b0010) && !rsp_empty) begin
				rsp_rd <= rsp_rd + 5'd1;                                          // RESULT pop
			end

			// ---- the data FIFO: loading, CPU bytes, DMA words ----
			if (fifo_load) begin
				bfrd <= 1'b1; bfrd_pend <= 1'b0; fifo_slot <= r_lp; r_lp <= r_lp + 3'd1;
				fifo_rd  <= mode[5] ? 12'd12 : 12'd24;
				fifo_end <= mode[5] ? 12'd2352 : 12'd2072;
			end
			if (cpu_pop) fifo_rd <= fifo_rd + 12'd1;
			// fifo_byte shows the byte fifo_rd pointed at a clock ago, so the pointer
			// steps on the request and on the first three captures; the four
			// captures then see bytes 0..3 in turn
			case (dma_st)
			3'd0: if (dma_rd) begin dma_st <= 3'd1; if (fifo_has) fifo_rd <= fifo_rd + 12'd1; end
			default: begin
				dma_rdata <= {fb_ok ? fifo_byte : 8'h00, dma_rdata[31:8]};
				if (!fb_ok && dma_dry != 8'hFF) dma_dry <= dma_dry + 8'd1;   // bytes the DMA took with nothing there
				if (dma_st != 3'd4 && fifo_has) fifo_rd <= fifo_rd + 12'd1;
				if (dma_st == 3'd4) begin dma_st <= 3'd0; dma_rvalid <= 1'b1; end
				else dma_st <= dma_st + 3'd1;
			end
			endcase

			// ---- first response, after the acknowledge delay ----
			if (cmd_pend) begin
				if (timer != ACK_CYCLES[21:0]) timer <= timer + 22'd1;
				else if (int_flag == 3'd0) begin
					cmd_pend <= 1'b0; busy <= 1'b0;
					rsp_wr <= 5'd0; rsp_rd <= 5'd0;
					prm_wr <= 5'd0; prm_rd <= 5'd0;              // parameters are consumed by the command
					second_pend <= 1'b0; second_wait <= 1'b0;
					case (cmd)
					8'h01, 8'h0B, 8'h0C, 8'h0D: begin                        // Getstat / Mute / Demute / Setfilter
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h02: begin                                             // Setloc(mm, ss, ff)
							loc <= (bcd2bin(prm[0]) * 24'd60 + bcd2bin(prm[1])) * 24'd75 + bcd2bin(prm[2]) - 24'd150;
							loc_mm <= bcd2bin(prm[0]); loc_ss <= bcd2bin(prm[1]); loc_ff <= bcd2bin(prm[2]);
							dbg_setloc <= {prm[0], prm[1], prm[2], mode};
							loc_v <= 1'b1;
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h0E: begin                                             // Setmode
							mode <= prm[0];
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h0F: begin                                             // Getparam: stat, mode, 00, file, channel
							rsp[0] <= stat; rsp[1] <= mode; rsp[2] <= 8'h00; rsp[3] <= 8'h00; rsp[4] <= 8'h00;
							rsp_wr <= 5'd5; int_flag <= 3'd3;
						end
					8'h10: begin                                             // GetlocL: the last sector's header
							for (k = 0; k < 8; k = k + 1) rsp[k] <= cur_hdr[k];
							rsp_wr <= 5'd8; int_flag <= 3'd3;
						end
					8'h11: begin                                             // GetlocP: track, index, mm, ss, ff (relative), amm, ass, aff
							rsp[0] <= 8'h01; rsp[1] <= 8'h01;
							rsp[2] <= bin2bcd(pos_mm); rsp[3] <= bin2bcd(pos_ss); rsp[4] <= bin2bcd(pos_ff);
							rsp[5] <= bin2bcd(pos_mm); rsp[6] <= bin2bcd(pos_ss); rsp[7] <= bin2bcd(pos_ff);
							rsp_wr <= 5'd8; int_flag <= 3'd3;
						end
					8'h13: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // GetTN: first and last track
							rsp[0] <= stat; rsp[1] <= 8'h01; rsp[2] <= 8'h01; rsp_wr <= 5'd3; int_flag <= 3'd3;
						end
					8'h14: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // GetTD(track): 0 = the end, 1 = 00:02
							rsp[0] <= stat;
							if (prm[0] == 8'h00) begin rsp[1] <= bin2bcd(end_mm); rsp[2] <= bin2bcd(end_ss); end
							else begin rsp[1] <= 8'h00; rsp[2] <= 8'h02; end
							rsp_wr <= 5'd3; int_flag <= 3'd3;
						end
					8'h15, 8'h16: if (!disc_in) begin                        // nothing to seek on
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else if (loc_v && loc > LAST_LBA) begin              // off the end: INT3, then INT5 seek error
							loc_v <= 1'b0;
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd5; second_b[0] <= stat | 8'h04; second_b[1] <= 8'h04; second_len <= 4'd2;
						end else begin                                       // SeekL / SeekP: INT3(stat), INT2(stat) when there
							stat <= (stat & 8'h1F) | 8'h42;                  // motor, seeking
							seeking <= 1'b1; reading <= 1'b0; seek_then_read <= 1'b0;
							sec_timer <= 22'd0;
							if (loc_v) begin fill_lba <= loc; r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0; end
							rsp[0] <= (stat & 8'h1F) | 8'h42; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h06, 8'h1B: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else if (loc_v && loc > LAST_LBA) begin
							loc_v <= 1'b0;
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd5; second_b[0] <= stat | 8'h04; second_b[1] <= 8'h04; second_len <= 4'd2;
						end else begin                                       // ReadN / ReadS: INT3(stat), then INT1 per sector
							read_s <= (cmd == 8'h1B);
							rsp[0] <= (stat & 8'h1F) | 8'h22; rsp_wr <= 5'd1; int_flag <= 3'd3;
							if (loc_v) begin                                 // a new place: seek there first
								stat <= (stat & 8'h1F) | 8'h42;
								seeking <= 1'b1; reading <= 1'b0; seek_then_read <= 1'b1;
								fill_lba <= loc; r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0;
							end else begin
								stat <= (stat & 8'h1F) | 8'h22;
								reading <= 1'b1;
							end
							sec_timer <= 22'd0;
						end
					8'h09: begin                                             // Pause: INT3(stat), INT2(stat)
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							reading <= 1'b0; seeking <= 1'b0; seek_then_read <= 1'b0;
							stat <= stat & 8'h1F;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= stat & 8'h1F; second_len <= 4'd1;
						end
					8'h08: begin                                             // Stop: INT3(stat), INT2(stat) motor off
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							reading <= 1'b0; seeking <= 1'b0; seek_then_read <= 1'b0;
							stat <= 8'h00;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= 8'h00; second_len <= 4'd1;
						end
					8'h0A: begin                                             // Init: INT3(stat), INT2(stat)
							stat <= 8'h02; mode <= 8'h00;
							reading <= 1'b0; seeking <= 1'b0; seek_then_read <= 1'b0; loc_v <= 1'b0;
							rsp[0] <= 8'h02; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= 8'h02; second_len <= 4'd1;
						end
					8'h1A: begin                                             // GetID: INT3(stat), then INT2(02 00 20 00 'S' 'C' 'E' 'A') or INT5(08 40 ..) with no disc
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_len <= 4'd8;
							if (disc_in) begin
								second_int <= 3'd2;
								second_b[0] <= 8'h02; second_b[1] <= 8'h00; second_b[2] <= 8'h20; second_b[3] <= 8'h00;
								second_b[4] <= 8'h53; second_b[5] <= 8'h43; second_b[6] <= 8'h45; second_b[7] <= 8'h41;
							end else begin
								second_int <= 3'd5;
								second_b[0] <= 8'h08; second_b[1] <= 8'h40; second_b[2] <= 8'h00; second_b[3] <= 8'h00;
								second_b[4] <= 8'h00; second_b[5] <= 8'h00; second_b[6] <= 8'h00; second_b[7] <= 8'h00;
							end
						end
					8'h1E, 8'h12: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // ReadTOC / SetSession: INT3(stat), INT2(stat)
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= stat; second_len <= 4'd1;
						end
					8'h03, 8'h04, 8'h05, 8'h07: begin                        // Play / Forward / Backward / MotorOn: nothing to hear
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h19: begin                                             // Test
							if (prm[0] == 8'h20) begin                       // 20h: firmware date/version, BCD
								rsp[0] <= 8'h94; rsp[1] <= 8'h09; rsp[2] <= 8'h19; rsp[3] <= 8'hC0; rsp_wr <= 5'd4; int_flag <= 3'd3;
							end else begin
								rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							end
						end
					default: begin                                           // Sync / unused: INT5(stat|error, 40h)
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h40; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end
					endcase
				end
			end

			// ---- second response, once the first was acknowledged and time has passed ----
			if (second_wait) begin
				if (timer != SECOND_CYCLES[21:0]) timer <= timer + 22'd1;
				else if (int_flag == 3'd0) begin
					second_wait <= 1'b0; second_pend <= 1'b0;
					rsp_rd <= 5'd0;
					for (k = 0; k < 8; k = k + 1) rsp[k] <= second_b[k];
					rsp_wr <= {1'b0, second_len};
					int_flag <= second_int;
				end
			end

			// ---- the drive: seeking, then reading a sector a period ----
			if (seeking) begin
				if (sec_timer == 22'd0) begin
					// the head goes where Setloc said; the ring starts again from there
					pos <= loc_v ? loc : pos;
					if (loc_v) begin pos_mm <= loc_mm; pos_ss <= loc_ss; pos_ff <= loc_ff; end
					loc_v <= 1'b0;
					r_base <= loc_v ? loc : pos;
					if (loc_v) begin r_cnt <= 4'd0; ld_cnt <= 4'd0; end   // (the chain restarted in the command's clock)
					sec_timer <= 22'd1;
				end else if (sec_timer != SEEK_CYCLES[21:0]) sec_timer <= sec_timer + 22'd1;
				else if (!cmd_pend && !second_pend && int_flag == 3'd0) begin
					seeking <= 1'b0; sec_timer <= 22'd0;
					if (seek_then_read) begin
						seek_then_read <= 1'b0; reading <= 1'b1;
						stat <= (stat & 8'h1F) | 8'h22;
					end else begin
						// a plain seek finishes with INT2(stat)
						stat <= (stat & 8'h1F) | 8'h02;
						rsp_rd <= 5'd0; rsp[0] <= (stat & 8'h1F) | 8'h02; rsp_wr <= 5'd1; int_flag <= 3'd2;
					end
				end
			end else if (reading) begin
				if (sec_timer != (mode[7] ? SECTOR_2X[21:0] : SECTOR_1X[21:0])) sec_timer <= sec_timer + 22'd1;
				else if (pop) begin
					// the sector is due and here: it becomes the current one, INT1(stat)
					sec_timer <= 22'd0;
					cur_slot <= r_rp; cur_v <= 1'b1; int1_fire <= 1'b1;
					r_rp <= r_rp + 3'd1;
					r_base <= r_base + 24'd1;
					pos <= r_base + 24'd1;
					// (the data FIFO is left alone: the chip keeps the sector the CPU is
					//  reading; the next HCHPCTL bit 7 write loads this one)
					if (pos_ff == 8'd74) begin
						pos_ff <= 8'd0;
						if (pos_ss == 8'd59) begin pos_ss <= 8'd0; pos_mm <= pos_mm + 8'd1; end
						else pos_ss <= pos_ss + 8'd1;
					end else pos_ff <= pos_ff + 8'd1;
					rsp_rd <= 5'd0; rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd1;
					if (pos >= LAST_LBA) begin                     // the end of the disc: INT4 next time
						reading <= 1'b0; stat <= stat & 8'h1F;
					end
				end
			end
		end
	end

	// the header and subheader of the sector that just became current, for
	// GetlocL: bytes 12..19 of the slot, read out over the nine clocks after
	// it is chosen (hdr_byte is a clock behind h_addr)
	reg [3:0]   hdr_i;
	wire [14:0] h_addr = cur_slot * 15'd2352 + 15'd12 + {12'd0, hdr_i[2:0]};
	reg  [7:0]  hdr_byte;
	always @(posedge clk) hdr_byte <= ring[h_addr];
	always @(posedge clk) begin
		if (rst) hdr_i <= 4'd9;
		else if (int1_fire) hdr_i <= 4'd0;
		else if (hdr_i != 4'd9) begin
			if (hdr_i != 4'd0) cur_hdr[hdr_i - 4'd1] <= hdr_byte;
			hdr_i <= hdr_i + 4'd1;
		end
	end
endmodule

`default_nettype wire
