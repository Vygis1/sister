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
//
// --- tracks and CD audio -----------------------------------------------------------
//
// The table of contents comes from whoever holds the image (toc_*): each
// track's first LBA, whether it is audio, and its start as mm:ss for GetTD.
// Without one the disc is a single data track of LAST_LBA+1 sectors.
//
// Play (CD-DA): an audio sector is 588 stereo samples of 16-bit PCM, 1/75 s at
// 44.1 kHz, delivered into the ring like any other. The player reads the
// current one out four bytes a sample through the header port (which is idle
// while playing) and asks for the next when it has played all 588, so the
// drive's position advances exactly as fast as the audio is heard. Report mode
// sends INT1 with the position every ten frames; auto-pause stops at the end of
// the track with INT4.
//
// XA-ADPCM: with Setmode bit 6, a Mode 2 sector whose submode says real-time
// audio is not data. It is checked against Setfilter (bit 3), and if it passes
// its LBA is queued for the PC (xa_*), which decodes it, resamples to 44.1 kHz
// and streams the samples back into a 4096-sample FIFO that plays a sample a
// tick. Decoding on the PC rather than here costs four block RAMs instead of a
// decoder and a 25-tap resampler on a chip that has no room for them.
//
// Both go through the CD volume matrix (the CD-ROM's own registers, applied by
// ADPCTL bit 5) and out on cd_l/cd_r for the SPU, which mixes them.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module ps1_cdrom #(
	parameter ACK_CYCLES    = 20000,     // command -> INT3 first response
	parameter SECOND_CYCLES = 120000,    // INT3 acknowledged -> INT2/INT5 second response
	// the console's own delays where they differ (psx-spx, ps1-tests cdrom/timing): Init is
	// acknowledged later than other commands and completes in ~14 ms, Pause in ~30 ms
	parameter INIT_ACK_CYCLES  = ACK_CYCLES,
	parameter INIT_DONE_CYCLES = SECOND_CYCLES,
	parameter PAUSE_DONE_CYCLES = SECOND_CYCLES,
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
	input  wire        edc_on,        // check each data sector's EDC and have a bad one sent again
	output reg  [15:0] dbg_edc_bad,   // (debug) data sectors refused for a bad EDC
	input  wire [23:0] sb_lba,        // ...and it is this one: accepted only if it is fill_lba
	input  wire        sb_abort,      // (the transport gave up on it: forget the bytes so far)

	// --- the table of contents, from whoever holds the image ----------------------------
	// 00-63h: track n's first sector {audio, lba} (0: the lead-out)
	// 80-E3h: track n's start {mm[6:0], ss[5:0]}, binary, for GetTD (80h: the lead-out)
	// FFh:    {first[14:8], last[6:0]}
	input  wire        toc_we,
	input  wire [7:0]  toc_addr,
	input  wire [31:0] toc_data,

	// --- CD audio: one stereo sample a tick (44.1 kHz), after the volume matrix ---------
	input  wire        tick,
	output reg  signed [15:0] cd_l,
	output reg  signed [15:0] cd_r,

	// --- XA-ADPCM: the sectors to decode, and the samples that come back ----------------
	output wire [23:0] xa_lba,        // the oldest sector waiting to be decoded
	output wire [4:0]  xa_count,      // how many are waiting
	input  wire        xa_pop,        // the PC has taken it
	input  wire        xa_we,         // a decoded sample, {right, left}, 44.1 kHz
	input  wire [31:0] xa_wdata,
	output wire [12:0] xa_level,      // samples in the FIFO
	output reg  [7:0]  xa_gen,        // counts flushes: a stream the PC was decoding has been cut
	output wire        xa_filt,       // Setmode bit 3: only the Setfilter file/channel is queued

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
	// the table of contents
	// ==================================================================================
	localparam [23:0] DEF_END = LAST_LBA + 24'd1;
	localparam [23:0] DEF_END_S = (DEF_END + 24'd150) / 75;
	localparam [6:0]  DEF_MM = DEF_END_S / 60;
	localparam [5:0]  DEF_SS = DEF_END_S % 60;
	(* ram_style = "distributed" *) reg [24:0] toc_lba [0:127];   // {audio, first lba}
	(* ram_style = "distributed" *) reg [12:0] toc_msf [0:127];   // {mm, ss}
	reg [6:0]  toc_first, toc_last;
	reg [23:0] leadout;
	reg        disc_audio;            // track 1 is audio: an audio CD (GetID says so)
	integer ti;
	initial begin
		for (ti = 0; ti < 128; ti = ti + 1) begin toc_lba[ti] = 25'd0; toc_msf[ti] = 13'd0; end
		toc_lba[0] = {1'b0, DEF_END};
		toc_msf[0] = {DEF_MM, DEF_SS};
		toc_msf[1] = {7'd0, 6'd2};
		toc_first = 7'd1; toc_last = 7'd1; leadout = DEF_END; disc_audio = 1'b0;
	end
	always @(posedge clk) if (toc_we) begin
		if (toc_addr == 8'hFF) begin toc_first <= toc_data[14:8]; toc_last <= toc_data[6:0]; end
		else if (toc_addr[7]) toc_msf[toc_addr[6:0]] <= toc_data[12:0];
		else begin
			toc_lba[toc_addr[6:0]] <= toc_data[24:0];
			if (toc_addr[6:0] == 7'd0) leadout <= toc_data[23:0];
			if (toc_addr[6:0] == 7'd1) disc_audio <= toc_data[24];
		end
	end

	// ==================================================================================
	// registers and the sequencer
	// ==================================================================================
	reg [1:0]  index;
	reg [7:0]  stat;                  // 0 error, 1 motor, 2 seek err, 3 id err, 4 shell, 5 read, 6 seek, 7 play
	// GetlocL has something to report only once a header has been read since Init: a sector's
	// own, or after a seek the target's (the drive read it getting there). ps1-tests cdrom/getloc.
	reg         hdr_valid, hdr_seek;
	reg [23:0]  sl_bcd;               // the last Setloc, BCD mm ss ff
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
	wire       rsp_empty = !(rsp_rd < rsp_wr);
	// the command in flight and its scheduling
	reg [7:0]  cmd;
	reg        cmd_pend;
	reg        eod_pend;             // a read ran into the lead-out: INT4 (data end) when the drive is free
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
	// CD audio
	reg        playing;               // Play: audio sectors go to the speakers, not to the CPU
	reg        seek_then_play;        // a Play with somewhere to go first
	reg [6:0]  play_trk;              // the track Play is in (0: not known yet), for auto-pause
	reg        muted;                 // Mute / Demute
	reg [7:0]  flt_file, flt_chan;    // Setfilter
	reg        xa_play;               // XA-ADPCM sectors are being played
	reg [3:0]  xa_wait;               // a sector was delivered with XA on: its subheader is being read
	reg [23:0] xa_cur;                // ...and it is this one
	reg [7:0]  slot_skip;             // delivered slots that are not data: the FIFO loader steps over them
	reg [7:0]  rep_nib;               // report mode: the frame's tens digit last reported
	reg [6:0]  cur_trk;               // the track the head is in
	reg [7:0]  rel_mm, rel_ss, rel_ff;// and how far into it, for GetlocP and reports
	// the CD-DA player's state (the player itself is further down)
	reg  [7:0]  hdr_byte;
	reg  [2:0]  pl_slot;
	reg  [9:0]  pl_i;                 // the sample being fetched, 0..587
	reg  [2:0]  pl_k;                 // its byte, 0..3, and a fifth clock for the last to land
	reg  [31:0] pl_next;
	reg         pl_have;              // pl_next is a whole sample, not yet played
	reg         pl_fetching;
	reg         pl_done;              // the last sample of the sector has been played
	reg  [14:0] pk_l, pk_r;           // the sector's peak, for report mode
	reg signed [15:0] cdda_l, cdda_r;
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
	assign fill_run = reading || seeking || playing;
	assign xa_filt  = mode[3];
	assign dbg = {stat, reading, seeking, cur_v, r_cnt[2:0], fill_lba[17:0]};   // 8+1+1+1+3+18 = 32
	assign dbg_seek = {int_flag, 5'd0, loc};
	assign dbg_hdr  = {cur_hdr[0], cur_hdr[1], cur_hdr[2], cur_hdr[3]};

	// BCD helpers
	function [7:0] bin2bcd; input [7:0] b; bin2bcd = ((b / 8'd10) << 4) | (b % 8'd10); endfunction
	function [7:0] bcd2bin; input [7:0] b; bcd2bin = b[7:4] * 8'd10 + b[3:0]; endfunction
	// The TOC has two read ports and no more: the track finder's, and this one,
	// for the command in hand (Play's track, GetTD's track; one past the last is
	// GetTD's error and Play's "this track", and 0 is the lead-out). Every other
	// use reads a register. A constant-index read (toc_lba[1]) once made Vivado
	// give up on the RAM and build 128 x 25 flip-flops with a 128-way multiplexer
	// per read: 2,800 LUTs, and the design no longer routed.
	wire [7:0]  prm0_bin = bcd2bin(prm[0]);
	wire [6:0]  tq_a     = (prm0_bin > {1'b0, toc_last}) ? cur_trk : prm0_bin[6:0];
	wire [24:0] tq_lba   = toc_lba[tq_a];
	wire [12:0] tq_msf   = toc_msf[tq_a];
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
	// An audio sector has no sync pattern (00, ten FFs, 00) and so no header to
	// check. A data read that runs into one takes it and skips it, with no INT1,
	// as the drive does (DuckStation's DoSectorRead): the BIOS reads an audio CD
	// that way, times out, and opens its CD player. Refused, it was asked for
	// again forever and the BIOS sat at its logo.
	reg         sb_audio;
	always @(posedge clk) if (sb_we && sb_addr < 12'd12) begin
		if (sb_addr == 12'd0) sb_audio <= (sb_data != 8'h00);
		else                  sb_audio <= sb_audio | (sb_data != ((sb_addr == 12'd11) ? 8'h00 : 8'hFF));
	end
	reg  [7:0]  slot_audio;           // which ring slots hold audio sectors
	// A frame that began before the ring started again is never taken. Its first bytes went
	// into the slot being filled THEN, the rest into slot 0, and its label and header -- both
	// read at the start -- can name the sector the new read wants: the BIOS reads Crash's
	// header (112018), the drive reads ahead, the transport is part way through 112019 when
	// Setloc(112019)+ReadN restarts the ring, and slot 0 -- still the header -- went to the
	// game as its first 2048 bytes of code. One boot in three to five on the board. The
	// transport sends the sector the drive wants next, so a refused frame comes again.
	// The sector's own check. A data sector carries an EDC -- a CRC-32 over its subheader and data
	// (Mode 2 Form 1: bytes 16..817h, kept at 818h; Form 2: 16..92Bh at 92Ch, 0 meaning none) --
	// and a drive reads a sector again when it does not match. The link from the ESP32 flips or
	// drops a bit now and then (one page in ten thousand, measured); GT2's attract mode, loading
	// cars and tracks without end, took one in its data every half hour or so and divided by the
	// zero it put there (libgcc's __udivdi3 BREAK, then A(40h)). A refused frame is simply sent
	// again, as a mislabelled one is; three in a row for the same sector and it is taken anyway
	// (a disc image whose own EDC is wrong must still play).
	function [31:0] edc8; input [31:0] c; input [7:0] b; integer k; reg [31:0] x;
		begin
			x = c ^ {24'd0, b};
			for (k = 0; k < 8; k = k + 1) x = x[0] ? ((x >> 1) ^ 32'hD801_8001) : (x >> 1);
			edc8 = x;
		end
	endfunction
	reg  [31:0] edc_run, edc_f1, edc_st1, edc_st2;
	reg  [7:0]  edc_mode, edc_sub;
	always @(posedge clk) if (sb_we) begin
		if (sb_addr == 12'd16) edc_run <= edc8(32'd0, sb_data);
		else if (sb_addr > 12'd16 && sb_addr <= 12'h92B) edc_run <= edc8(edc_run, sb_data);
		if (sb_addr == 12'h818) edc_f1 <= edc_run;            // (the CRC through 817h)
		if (sb_addr == 12'd15) edc_mode <= sb_data;
		if (sb_addr == 12'd18) edc_sub  <= sb_data;
		if (sb_addr >= 12'h818 && sb_addr <= 12'h81B) edc_st1[(sb_addr[1:0]) * 8 +: 8] <= sb_data;
		if (sb_addr >= 12'h92C && sb_addr <= 12'h92F) edc_st2[(sb_addr[1:0]) * 8 +: 8] <= sb_data;
	end
	wire        edc_ok = sb_audio || (edc_mode != 8'd2)
	                     || (edc_sub[5] ? ((edc_st2 == 32'd0) || (edc_st2 == edc_run)) : (edc_st1 == edc_f1));
	reg  [23:0] edc_lba; reg [1:0] edc_tries;
	wire        edc_pass = !edc_on || edc_ok || ((edc_lba == fill_lba) && (edc_tries == 2'd3));
	reg         sb_stale;
	wire        sb_take = sb_done && !sb_stale && (sb_lba == fill_lba) && (held < 4'd7)
	                      && ((hdr_lba == fill_lba) || playing || seek_then_play || sb_audio) && edc_pass;
	always @(posedge clk)
		if (rst) begin dbg_edc_bad <= 16'd0; edc_lba <= 24'hFFFFFF; edc_tries <= 2'd0; end
		else if (sb_done && !sb_stale && (sb_lba == fill_lba) && !edc_pass) begin
			dbg_edc_bad <= dbg_edc_bad + 16'd1;
			if (edc_lba != fill_lba) begin edc_lba <= fill_lba; edc_tries <= 2'd1; end
			else edc_tries <= edc_tries + 2'd1;
		end
	reg  [15:0] sb_mislabelled;      // frames whose header did not match their label (a debug count)
	always @(posedge clk) if (rst) sb_mislabelled <= 16'd0; else if (sb_done && (sb_lba == fill_lba) && (hdr_lba != fill_lba)) sb_mislabelled <= sb_mislabelled + 16'd1;
	wire        want_wr   = sel && we && be[3] && (index == 2'd0) && wdata[31];
	wire        lp_skip   = (ld_cnt != 4'd0) && slot_skip[r_lp];
	wire        fifo_load = (want_wr || bfrd_pend) && (ld_cnt != 4'd0) && !(bfrd && fifo_has) && !lp_skip
	                        && (xa_wait == 4'd0);
	wire        pop = reading && (sec_timer == (mode[7] ? SECTOR_2X[21:0] : SECTOR_1X[21:0]))
	                  && ring_has && int_flag == 3'd0 && !cmd_pend && !second_wait && !seeking;
	// Play takes the next sector when the player has heard all of the last one
	reg         pl_v;                 // the player has a sector
	wire        play_pop = playing && !seeking && !pl_v && ring_has;
	wire        any_pop  = pop || play_pop;
	// A sector nobody collects is overwritten, as on the drive: when a fifth would be held
	// delivered-but-unread, the oldest goes. Kept, a program that only counts INT1s
	// (ps1-tests cdrom/timing) filled the ring in seven sectors and the drive stopped.
	wire        ld_drop   = any_pop && (ld_cnt >= 4'd4) && !lp_skip && !fifo_load;
	wire [7:0]  ff_bcd   = bin2bcd(pos_ff);

	// XA: the queue of sectors for the PC, and the FIFO of samples it sends back
	(* ram_style = "distributed" *) reg [23:0] xaq [0:15];
	reg  [4:0]  xaq_wp, xaq_rp;
	assign xa_count = xaq_wp - xaq_rp;
	assign xa_lba   = xaq[xaq_rp[3:0]];
	reg  [31:0] xa_mem [0:4095];
	reg  [12:0] xa_wp, xa_rp;
	assign xa_level = xa_wp - xa_rp;
	always @(posedge clk) begin
		if (rst) xa_wp <= 13'd0;
		else if (xa_we && xa_level != 13'd4096) begin xa_mem[xa_wp[11:0]] <= xa_wdata; xa_wp <= xa_wp + 13'd1; end
	end
	reg         xa_rd;
	reg  [31:0] xa_q;
	always @(posedge clk) if (xa_rd) xa_q <= xa_mem[xa_rp[11:0]];
	// The CD volume matrix: written to the "next" set, applied by ADPCTL bit 5
	reg  [7:0]  vn_ll, vn_lr, vn_rr, vn_rl, v_ll, v_lr, v_rr, v_rl;
	reg         adp_mute;

	integer k;
	always @(posedge clk) begin
		if (rst) begin
			index <= 2'd0; stat <= 8'h02; int_flag <= 3'd0; int_mask <= 5'd0; busy <= 1'b0; mode <= 8'h00;
			hdr_valid <= 1'b0; hdr_seek <= 1'b0; sl_bcd <= 24'd0;
			prm_wr <= 5'd0; prm_rd <= 5'd0; rsp_wr <= 5'd0; rsp_rd <= 5'd0;
			cmd <= 8'd0; cmd_pend <= 1'b0; eod_pend <= 1'b0; timer <= 22'd0; dbg_cmds <= 32'd0; dbg_setloc <= 32'd0; trace_w <= 6'd0;
			tr_v <= 1'b0; tr_d <= 32'd0;
			second_pend <= 1'b0; second_int <= 3'd0; second_len <= 4'd0; second_wait <= 1'b0;
			for (k = 0; k < 8; k = k + 1) second_b[k] <= 8'd0;
			loc <= 24'd0; loc_v <= 1'b0; pos <= 24'd0; seeking <= 1'b0; reading <= 1'b0; read_s <= 1'b0;
			pos_mm <= 8'd0; pos_ss <= 8'd2; pos_ff <= 8'd0; loc_mm <= 8'd0; loc_ss <= 8'd2; loc_ff <= 8'd0;
			sec_timer <= 22'd0; seek_then_read <= 1'b0;
			playing <= 1'b0; seek_then_play <= 1'b0; play_trk <= 7'd0; muted <= 1'b0; flt_file <= 8'd0; flt_chan <= 8'd0;
			xa_play <= 1'b0; xa_wait <= 4'd0; slot_skip <= 8'd0; rep_nib <= 8'hFF; xaq_wp <= 5'd0; xaq_rp <= 5'd0;
			xa_rp <= 13'd0; xa_gen <= 8'd0; xa_rd <= 1'b0; adp_mute <= 1'b0;
			vn_ll <= 8'h80; vn_lr <= 8'h00; vn_rr <= 8'h80; vn_rl <= 8'h00;
			v_ll  <= 8'h80; v_lr  <= 8'h00; v_rr  <= 8'h80; v_rl  <= 8'h00;
			cur_slot <= 3'd0; cur_v <= 1'b0; fifo_slot <= 3'd0; fifo_rd <= 12'd0; fifo_end <= 12'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0;
			r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; r_cnt <= 4'd0; ld_cnt <= 4'd0; r_base <= 24'd0; fill_lba <= 24'd0;
			dma_rdata <= 32'd0; dma_rvalid <= 1'b0; dma_st <= 3'd0; int1_fire <= 1'b0; dma_dry <= 8'd0;
			sb_stale <= 1'b0;
		end else begin
			dma_rvalid <= 1'b0; int1_fire <= 1'b0;
			if (sb_we && sb_addr == 12'd0) sb_stale <= 1'b0;     // (a frame starting now goes where it should)

			// ---- the ring: a sector arrives, a sector is taken ----
			if (sb_take) begin
				slot_audio[r_wp] <= sb_audio;
				r_wp  <= r_wp + 3'd1;
				fill_lba <= fill_lba + 24'd1;
			end
			r_cnt  <= r_cnt + {3'd0, sb_take} - {3'd0, any_pop};
			ld_cnt <= ld_cnt + {3'd0, any_pop} - {3'd0, fifo_load} - {3'd0, lp_skip} - {3'd0, ld_drop};
			if (lp_skip || ld_drop) begin r_lp <= r_lp + 3'd1; slot_skip[r_lp] <= 1'b0; end
			xa_rd <= 1'b0;
			if (xa_pop && xa_count != 5'd0) xaq_rp <= xaq_rp + 5'd1;

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
					cmd <= wdata[15:8]; cmd_pend <= 1'b1; busy <= 1'b1; timer <= 22'd0; eod_pend <= 1'b0;
					dbg_cmds <= {dbg_cmds[23:0], wdata[15:8]};
					tr_v <= 1'b1;
					tr_d <= {wdata[15:8], prm[0], prm[1], prm[2]};
				end
				if (be[1] && index == 2'd3) vn_rr <= wdata[15:8];              // 1F801801.3: right CD -> right SPU
				if (be[2]) begin
					case (index)
					2'd0: if (!prm_full) begin prm[prm_wr[3:0]] <= wdata[23:16]; prm_wr <= prm_wr + 5'd1; end  // PARAMETER
					2'd1: int_mask <= wdata[20:16];                                // HINTMSK
					2'd2: vn_ll <= wdata[23:16];                                   // left CD -> left SPU
					default: vn_rl <= wdata[23:16];                                // right CD -> left SPU
					endcase
				end
				if (be[3] && index == 2'd2) vn_lr <= wdata[31:24];             // left CD -> right SPU
				if (be[3] && index == 2'd3) begin                              // ADPCTL
					adp_mute <= wdata[24];
					if (wdata[29]) begin v_ll <= vn_ll; v_lr <= vn_lr; v_rr <= vn_rr; v_rl <= vn_rl; end
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
							// ...and the reply stays readable: the drive's controller only drains it
							// when it posts the next one. PSn00bSDK acknowledges FIRST and reads the
							// reply a few microseconds later (psxcd common.c); drained here, every
							// status and position it read came back 00.
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
			end else if (sel && !we && (be == 4'b0010)) begin
				// RESULT: past the reply it reads 00 to the 16th byte, then starts again at the
				// first (psx-spx) -- it never stops on an empty FIFO
				rsp_rd <= (rsp_rd[3:0] == 4'd15) ? 5'd0 : rsp_rd + 5'd1;
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
				if (timer != ((cmd == 8'h0A) ? INIT_ACK_CYCLES[21:0] : ACK_CYCLES[21:0])) timer <= timer + 22'd1;
				else if (int_flag == 3'd0) begin
					cmd_pend <= 1'b0; busy <= 1'b0;
					rsp_wr <= 5'd0; rsp_rd <= 5'd0;
					prm_wr <= 5'd0; prm_rd <= 5'd0;              // parameters are consumed by the command
					second_pend <= 1'b0; second_wait <= 1'b0;
					case (cmd)
					8'h01, 8'h0B, 8'h0C, 8'h0D: begin                        // Getstat / Mute / Demute / Setfilter
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							if (cmd == 8'h0B) muted <= 1'b1;
							if (cmd == 8'h0C) muted <= 1'b0;
							if (cmd == 8'h0D) begin flt_file <= prm[0]; flt_chan <= prm[1]; end
							// the lid bit is reported once after a disc goes in, then cleared
							if (cmd == 8'h01 && disc_in) stat <= stat & 8'hEF;
						end
					8'h02: begin                                             // Setloc(mm, ss, ff)
							loc <= (bcd2bin(prm[0]) * 24'd60 + bcd2bin(prm[1])) * 24'd75 + bcd2bin(prm[2]) - 24'd150;
							loc_mm <= bcd2bin(prm[0]); loc_ss <= bcd2bin(prm[1]); loc_ff <= bcd2bin(prm[2]);
							dbg_setloc <= {prm[0], prm[1], prm[2], mode};
							sl_bcd <= {prm[0], prm[1], prm[2]};
							loc_v <= 1'b1;
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h0E: begin                                             // Setmode
							mode <= prm[0];
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h0F: begin                                             // Getparam: stat, mode, 00, file, channel
							rsp[0] <= stat; rsp[1] <= mode; rsp[2] <= 8'h00; rsp[3] <= flt_file; rsp[4] <= flt_chan;
							rsp_wr <= 5'd5; int_flag <= 3'd3;
						end
					8'h10: begin                                             // GetlocL: the last sector's header
							if (!hdr_valid) begin                      // nothing read since Init: INT5(stat, 80h)
								rsp[0] <= stat; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
							end else if (hdr_seek) begin               // after a seek: where it landed
								rsp[0] <= sl_bcd[23:16]; rsp[1] <= sl_bcd[15:8]; rsp[2] <= sl_bcd[7:0]; rsp[3] <= 8'd2;
								rsp[4] <= 8'd0; rsp[5] <= 8'd0; rsp[6] <= 8'h08; rsp[7] <= 8'd0;
								rsp_wr <= 5'd8; int_flag <= 3'd3;
							end else begin
								for (k = 0; k < 8; k = k + 1) rsp[k] <= cur_hdr[k];
								rsp_wr <= 5'd8; int_flag <= 3'd3;
							end
						end
					8'h11: begin                                             // GetlocP: track, index, mm, ss, ff (relative), amm, ass, aff
							rsp[0] <= bin2bcd({1'b0, cur_trk}); rsp[1] <= 8'h01;
							rsp[2] <= bin2bcd(rel_mm); rsp[3] <= bin2bcd(rel_ss); rsp[4] <= bin2bcd(rel_ff);
							rsp[5] <= bin2bcd(pos_mm); rsp[6] <= bin2bcd(pos_ss); rsp[7] <= bin2bcd(pos_ff);
							rsp_wr <= 5'd8; int_flag <= 3'd3;
						end
					8'h13: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // GetTN: first and last track
							rsp[0] <= stat; rsp[1] <= bin2bcd({1'b0, toc_first}); rsp[2] <= bin2bcd({1'b0, toc_last});
							rsp_wr <= 5'd3; int_flag <= 3'd3;
						end
					8'h14: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else if (bcd2bin(prm[0]) > {1'b0, toc_last}) begin   // no such track: INT5(stat|error, 10h)
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h10; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // GetTD(track): its start, mm:ss (0 = the lead-out)
							rsp[0] <= stat;
							rsp[1] <= bin2bcd({1'b0, tq_msf[12:6]});
							rsp[2] <= bin2bcd({2'b0, tq_msf[5:0]});
							rsp_wr <= 5'd3; int_flag <= 3'd3;
						end
					8'h15, 8'h16: if (!disc_in) begin                        // nothing to seek on
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else if (loc_v && loc >= leadout) begin              // off the end: INT3, then INT5 seek error
							loc_v <= 1'b0;
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd5; second_b[0] <= stat | 8'h04; second_b[1] <= 8'h04; second_len <= 4'd2;
						end else begin                                       // SeekL / SeekP: INT3(stat), INT2(stat) when there
							stat <= (stat & 8'h1F) | 8'h42;                  // motor, seeking
							seeking <= 1'b1; reading <= 1'b0; seek_then_read <= 1'b0;
							playing <= 1'b0; seek_then_play <= 1'b0; pl_v <= 1'b0;
							xa_play <= 1'b0; xa_rp <= xa_wp; xa_gen <= xa_gen + 8'd1;
							sec_timer <= 22'd0;
							if (loc_v) begin fill_lba <= loc; r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0; slot_skip <= 8'd0; sb_stale <= 1'b1; end
							rsp[0] <= (stat & 8'h1F) | 8'h42; rsp_wr <= 5'd1; int_flag <= 3'd3;
						end
					8'h06, 8'h1B: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else if (loc_v && loc >= leadout) begin
							loc_v <= 1'b0;
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd5; second_b[0] <= stat | 8'h04; second_b[1] <= 8'h04; second_len <= 4'd2;
						end else begin                                       // ReadN / ReadS: INT3(stat), then INT1 per sector
							read_s <= (cmd == 8'h1B);
							rsp[0] <= (stat & 8'h1F) | 8'h22; rsp_wr <= 5'd1; int_flag <= 3'd3;
							playing <= 1'b0; seek_then_play <= 1'b0; pl_v <= 1'b0;
							xa_play <= 1'b0; xa_rp <= xa_wp; xa_gen <= xa_gen + 8'd1;
							if (loc_v) begin                                 // a new place: seek there first
								stat <= (stat & 8'h1F) | 8'h42;
								seeking <= 1'b1; reading <= 1'b0; seek_then_read <= 1'b1;
								fill_lba <= loc; r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0; slot_skip <= 8'd0; sb_stale <= 1'b1;
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
							playing <= 1'b0; seek_then_play <= 1'b0; pl_v <= 1'b0;
							xa_play <= 1'b0; xa_rp <= xa_wp; xa_gen <= xa_gen + 8'd1;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= stat & 8'h1F; second_len <= 4'd1;
						end
					8'h08: begin                                             // Stop: INT3(stat), INT2(stat) motor off
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							reading <= 1'b0; seeking <= 1'b0; seek_then_read <= 1'b0;
							stat <= 8'h00;
							playing <= 1'b0; seek_then_play <= 1'b0; pl_v <= 1'b0;
							xa_play <= 1'b0; xa_rp <= xa_wp; xa_gen <= xa_gen + 8'd1;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= 8'h00; second_len <= 4'd1;
						end
					8'h0A: begin                                             // Init: INT3(stat), INT2(stat)
							stat <= disc_in ? 8'h02 : 8'h10; mode <= 8'h00;
							hdr_valid <= 1'b0; hdr_seek <= 1'b0;
							reading <= 1'b0; seeking <= 1'b0; seek_then_read <= 1'b0; loc_v <= 1'b0;
							playing <= 1'b0; seek_then_play <= 1'b0; pl_v <= 1'b0;
							xa_play <= 1'b0; xa_rp <= xa_wp; xa_gen <= xa_gen + 8'd1;
							rsp[0] <= disc_in ? 8'h02 : 8'h10; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= disc_in ? 8'h02 : 8'h10; second_len <= 4'd1;
						end
					8'h1A: if (!disc_in) begin                               // GetID with no disc: INT5(stat|error, 80h not ready)
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // GetID: INT3(stat), then INT2(02 00 20 00 'S' 'C' 'E' 'A')
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_len <= 4'd8;
							if (disc_audio) begin                         // an audio CD: INT5(stat|ID error, 90h unlicensed+audio)
								second_int <= 3'd5;
								second_b[0] <= stat | 8'h08; second_b[1] <= 8'h90; second_b[2] <= 8'h20; second_b[3] <= 8'h00;
								second_b[4] <= 8'h00; second_b[5] <= 8'h00; second_b[6] <= 8'h00; second_b[7] <= 8'h00;
							end else if (disc_in) begin
								second_int <= 3'd2;
								second_b[0] <= 8'h02; second_b[1] <= 8'h00; second_b[2] <= 8'h20; second_b[3] <= 8'h00;
								second_b[4] <= 8'h53; second_b[5] <= 8'h43; second_b[6] <= 8'h45; second_b[7] <= 8'h41;
							end
						end
					8'h1E, 8'h12: if (!disc_in) begin
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // ReadTOC / SetSession: INT3(stat), INT2(stat)
							rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd3;
							second_pend <= 1'b1; second_int <= 3'd2; second_b[0] <= stat; second_len <= 4'd1;
						end
					8'h03: if (!disc_in) begin                               // Play, with no disc
							rsp[0] <= stat | 8'h01; rsp[1] <= 8'h80; rsp_wr <= 5'd2; int_flag <= 3'd5;
						end else begin                                       // Play([track]): INT3(stat), then the audio
							rsp[0] <= (stat & 8'h1F) | 8'h82; rsp_wr <= 5'd1; int_flag <= 3'd3;
							stat <= (stat & 8'h1F) | 8'h82;
							reading <= 1'b0; seek_then_read <= 1'b0; pl_v <= 1'b0; rep_nib <= 8'hFF;
							xa_play <= 1'b0; xa_rp <= xa_wp; xa_gen <= xa_gen + 8'd1;
							r_wp <= 3'd0; r_rp <= 3'd0; r_lp <= 3'd0; bfrd <= 1'b0; bfrd_pend <= 1'b0; slot_skip <= 8'd0; sb_stale <= 1'b1;
							if (prm_wr != 5'd0 && prm[0] != 8'h00) begin    // a track: go to its start
								play_trk <= tq_a;
								loc <= tq_lba[23:0];
								loc_mm <= {1'b0, tq_msf[12:6]};
								loc_ss <= {2'b0, tq_msf[5:0]};
								loc_ff <= 8'd0; loc_v <= 1'b1;
								fill_lba <= tq_lba[23:0];
								seeking <= 1'b1; seek_then_play <= 1'b1; playing <= 1'b0; sec_timer <= 22'd0;
							end else if (loc_v) begin                        // where Setloc said
								play_trk <= 7'd0;
								fill_lba <= loc;
								seeking <= 1'b1; seek_then_play <= 1'b1; playing <= 1'b0; sec_timer <= 22'd0;
							end else begin                                   // from here
								play_trk <= 7'd0;
								fill_lba <= pos; r_base <= pos; r_cnt <= 4'd0; ld_cnt <= 4'd0;
								playing <= 1'b1;
							end
						end
					8'h04, 8'h05, 8'h07: begin                               // Forward / Backward / MotorOn: nothing to hear
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
				if (timer != ((cmd == 8'h0A) ? INIT_DONE_CYCLES[21:0] : (cmd == 8'h09) ? PAUSE_DONE_CYCLES[21:0] : SECOND_CYCLES[21:0])) timer <= timer + 22'd1;
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
					if (loc_v) begin r_cnt <= 4'd0; ld_cnt <= 4'd0; slot_skip <= 8'd0; end   // (the chain restarted in the command's clock)
					sec_timer <= 22'd1;
				end else if (sec_timer != SEEK_CYCLES[21:0]) sec_timer <= sec_timer + 22'd1;
				else if (!cmd_pend && !second_pend && int_flag == 3'd0) begin
					seeking <= 1'b0; sec_timer <= 22'd0;
					if (seek_then_read) begin
						seek_then_read <= 1'b0; reading <= 1'b1;
						stat <= (stat & 8'h1F) | 8'h22;
					end else if (seek_then_play) begin
						seek_then_play <= 1'b0; playing <= 1'b1; pl_v <= 1'b0;
						stat <= (stat & 8'h1F) | 8'h82;
					end else begin
						// a plain seek finishes with INT2(stat), the target's header read on the way
						hdr_valid <= 1'b1; hdr_seek <= 1'b1;
						stat <= (stat & 8'h1F) | 8'h02;
						rsp_rd <= 5'd0; rsp[0] <= (stat & 8'h1F) | 8'h02; rsp_wr <= 5'd1; int_flag <= 3'd2;
					end
				end
			end else if (reading) begin
				if (sec_timer != (mode[7] ? SECTOR_2X[21:0] : SECTOR_1X[21:0])) sec_timer <= sec_timer + 22'd1;
				else if (pop) begin
					// the sector is due and here: it becomes the current one, INT1(stat)
					sec_timer <= 22'd0;
					if (slot_audio[r_rp]) slot_skip[r_rp] <= 1'b1;            // audio: passed over, never data
					else begin cur_slot <= r_rp; cur_v <= 1'b1; int1_fire <= 1'b1; hdr_valid <= 1'b1; hdr_seek <= 1'b0; end
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
					if (slot_audio[r_rp]) ;
					else if (mode[6]) begin xa_wait <= 4'd12; xa_cur <= r_base; end   // XA on: what is it?
					else begin rsp_rd <= 5'd0; rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd1; end
					if (pos + 24'd1 >= leadout) begin              // the end of the disc: INT4 next time
						reading <= 1'b0; stat <= stat & 8'h1F; eod_pend <= 1'b1;
					end
				end
			end else if (eod_pend) begin
				// a sector time after the last one, as DuckStation's StopReadingWithDataEnd
				if (sec_timer != (mode[7] ? SECTOR_2X[21:0] : SECTOR_1X[21:0])) sec_timer <= sec_timer + 22'd1;
				else if (int_flag == 3'd0 && !cmd_pend && !second_wait) begin
					sec_timer <= 22'd0; eod_pend <= 1'b0;
					rsp_rd <= 5'd0; rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd4;
				end
			end else if (playing) begin
				if (play_pop) begin
					// the next audio sector: the player has it, the CPU never sees it
					slot_skip[r_rp] <= 1'b1;
					pl_v <= 1'b1;
					r_rp <= r_rp + 3'd1;
					r_base <= r_base + 24'd1;
					pos <= r_base + 24'd1;
					if (pos_ff == 8'd74) begin
						pos_ff <= 8'd0;
						if (pos_ss == 8'd59) begin pos_ss <= 8'd0; pos_mm <= pos_mm + 8'd1; end
						else pos_ss <= pos_ss + 8'd1;
					end else pos_ff <= pos_ff + 8'd1;
					if (play_trk == 7'd0) play_trk <= cur_trk;
					if (pos + 24'd1 >= leadout || (mode[1] && play_trk != 7'd0 && cur_trk != play_trk)) begin
						// the end of the disc, or of the track with auto-pause: INT4(stat)
						playing <= 1'b0; pl_v <= 1'b0; stat <= stat & 8'h1F;
						rsp_rd <= 5'd0; rsp[0] <= stat & 8'h1F; rsp_wr <= 5'd1; int_flag <= 3'd4;
					end else if (mode[2] && int_flag == 3'd0 && !cmd_pend && !second_wait
					             && ff_bcd[7:4] != rep_nib[3:0]) begin
						// report mode: where the music is, every ten frames, absolute and
						// track-relative in turn, and how loud
						rep_nib <= {4'd0, ff_bcd[7:4]};
						rsp_rd <= 5'd0;
						rsp[0] <= stat; rsp[1] <= bin2bcd({1'b0, cur_trk}); rsp[2] <= 8'h01;
						if (ff_bcd[4]) begin
							rsp[3] <= bin2bcd(rel_mm); rsp[4] <= bin2bcd(rel_ss) | 8'h80; rsp[5] <= bin2bcd(rel_ff);
						end else begin
							rsp[3] <= bin2bcd(pos_mm); rsp[4] <= bin2bcd(pos_ss); rsp[5] <= bin2bcd(pos_ff);
						end
						rsp[6] <= pos_ss[0] ? pk_r[7:0] : pk_l[7:0];
						rsp[7] <= {pos_ss[0], pos_ss[0] ? pk_r[14:8] : pk_l[14:8]};
						rsp_wr <= 5'd8; int_flag <= 3'd1;
					end
				end
				if (pl_done) pl_v <= 1'b0;
			end

			// XA on: the delivered sector's subheader is in; audio goes to the PC to
			// decode (if the filter lets it), data gets its INT1
			if (xa_wait != 4'd0) begin
				xa_wait <= xa_wait - 4'd1;
				if (xa_wait == 4'd1) begin
					if (cur_hdr[3] == 8'd2 && cur_hdr[6][6] && cur_hdr[6][2]) begin
						slot_skip[cur_slot] <= 1'b1;               // real-time audio: never data
						if (!mode[3] || (cur_hdr[4] == flt_file && cur_hdr[5] == flt_chan)) begin
							if (xa_count != 5'd16) begin xaq[xaq_wp[3:0]] <= xa_cur; xaq_wp <= xaq_wp + 5'd1; end
							xa_play <= 1'b1;
						end
					end else begin
						rsp_rd <= 5'd0; rsp[0] <= stat; rsp_wr <= 5'd1; int_flag <= 3'd1;
					end
				end
			end

			// a tick: the next XA sample out of the FIFO
			if (tick && xa_play && xa_level != 13'd0) begin xa_rd <= 1'b1; xa_rp <= xa_rp + 13'd1; end
			// While no disc is in, the drive says so: lid open, motor off --
			// DuckStation's motor_on = CanReadMedia(), shell_open = !CanReadMedia().
			// Reported spinning, the BIOS waited for ever for a disc to come up to
			// speed and never showed its menu.
			if (!disc_in) stat <= 8'h10;
		end
	end

	// ==================================================================================
	// the CD-DA player: four bytes a sample out of the slot being played, through
	// the header's read port (the header is never read while playing)
	// ==================================================================================
	wire        hdr_busy;
	// the size of a sample, saturated to 15 bits
	function [14:0] mag15; input [15:0] x; reg [15:0] a;
		begin a = x[15] ? (~x + 16'd1) : x; mag15 = a[15] ? 15'h7FFF : a[14:0]; end
	endfunction
	always @(posedge clk) begin
		pl_done <= 1'b0;
		if (rst || !playing) begin
			pl_have <= 1'b0; pl_fetching <= 1'b0; pl_i <= 10'd0; pl_k <= 3'd0;
			cdda_l <= 16'sd0; cdda_r <= 16'sd0; pk_l <= 15'd0; pk_r <= 15'd0;
		end else begin
			if (play_pop) begin
				pl_slot <= r_rp; pl_i <= 10'd0; pl_have <= 1'b0; pl_fetching <= 1'b0; pl_k <= 3'd0;
				pk_l <= 15'd0; pk_r <= 15'd0;
			end else if (pl_v && !pl_have && !pl_fetching && !hdr_busy && !pl_done) begin
				pl_fetching <= 1'b1; pl_k <= 3'd0;
			end else if (pl_fetching) begin
				if (pl_k != 3'd0) pl_next[(pl_k - 3'd1) * 8 +: 8] <= hdr_byte;
				if (pl_k == 3'd4) begin pl_fetching <= 1'b0; pl_have <= 1'b1; end
				else pl_k <= pl_k + 3'd1;
			end
			if (tick) begin
				if (pl_have && pl_v) begin
					cdda_l <= pl_next[15:0]; cdda_r <= pl_next[31:16];
					if (mag15(pl_next[15:0])  > pk_l) pk_l <= mag15(pl_next[15:0]);
					if (mag15(pl_next[31:16]) > pk_r) pk_r <= mag15(pl_next[31:16]);
					pl_have <= 1'b0;
					if (pl_i == 10'd587) pl_done <= 1'b1;
					else pl_i <= pl_i + 10'd1;
				end else begin
					cdda_l <= 16'sd0; cdda_r <= 16'sd0;           // nothing in time: silence
				end
			end
		end
	end

	// ==================================================================================
	// the track the head is in, and how far into it (a slow walk, never in a hurry)
	// ==================================================================================
	reg  [6:0]  trk_i, trk_best;
	reg  [23:0] best_lba, cur_start;  // where those tracks begin
	wire [24:0] tf_lba = toc_lba[trk_i];
	always @(posedge clk) begin
		if (rst) begin cur_trk <= 7'd1; trk_i <= 7'd1; trk_best <= 7'd1; best_lba <= 24'd0; cur_start <= 24'd0; end
		else if (trk_i > toc_last || trk_i == 7'd0) begin
			cur_trk <= trk_best; cur_start <= best_lba;
			trk_i <= toc_first; trk_best <= toc_first; best_lba <= 24'd0;
		end else begin
			if (tf_lba[23:0] <= pos) begin trk_best <= trk_i; best_lba <= tf_lba[23:0]; end
			trk_i <= trk_i + 7'd1;
		end
	end
	reg  [23:0] cv_r;
	reg  [1:0]  cv_st;
	reg  [7:0]  cv_m, cv_s;
	always @(posedge clk) begin
		if (rst) begin cv_st <= 2'd0; rel_mm <= 8'd0; rel_ss <= 8'd0; rel_ff <= 8'd0; end
		else case (cv_st)
		2'd0: begin
				cv_r <= (pos >= cur_start) ? pos - cur_start : 24'd0;
				cv_m <= 8'd0; cv_s <= 8'd0; cv_st <= 2'd1;
			end
		2'd1: if (cv_r >= 24'd4500) begin cv_r <= cv_r - 24'd4500; cv_m <= cv_m + 8'd1; end else cv_st <= 2'd2;
		default: if (cv_r >= 24'd75) begin cv_r <= cv_r - 24'd75; cv_s <= cv_s + 8'd1; end
		         else begin rel_mm <= cv_m; rel_ss <= cv_s; rel_ff <= cv_r[7:0]; cv_st <= 2'd0; end
		endcase
	end

	// ==================================================================================
	// the output: CD-DA or XA, through the volume matrix, a sample a tick
	// ==================================================================================
	reg  [2:0]  mx_st;
	reg  signed [15:0] mx_l, mx_r;
	reg  signed [24:0] mx_acc;
	function signed [15:0] sat16; input signed [24:0] v;
		sat16 = (v > 25'sd32767) ? 16'sh7FFF : (v < -25'sd32768) ? -16'sh8000 : v[15:0];
	endfunction
	always @(posedge clk) begin
		if (rst) begin mx_st <= 3'd0; cd_l <= 16'sd0; cd_r <= 16'sd0; end
		else case (mx_st)
		3'd0: if (tick) mx_st <= 3'd1;
		3'd1: mx_st <= 3'd2;                                       // the CD-DA sample and the XA read land
		3'd2: begin
				if (muted) begin mx_l <= 16'sd0; mx_r <= 16'sd0; end
				else if (playing) begin mx_l <= cdda_l; mx_r <= cdda_r; end
				else if (xa_play && !adp_mute) begin mx_l <= xa_q[15:0]; mx_r <= xa_q[31:16]; end
				else begin mx_l <= 16'sd0; mx_r <= 16'sd0; end
				mx_st <= 3'd3;
			end
		3'd3: begin mx_acc <= mx_l * $signed({1'b0, v_ll}) + mx_r * $signed({1'b0, v_rl}); mx_st <= 3'd4; end
		3'd4: begin cd_l <= sat16(mx_acc >>> 7);
		            mx_acc <= mx_l * $signed({1'b0, v_lr}) + mx_r * $signed({1'b0, v_rr}); mx_st <= 3'd5; end
		default: begin cd_r <= sat16(mx_acc >>> 7); mx_st <= 3'd0; end
		endcase
	end

	// the header and subheader of the sector that just became current, for
	// GetlocL: bytes 12..19 of the slot, read out over the nine clocks after
	// it is chosen (hdr_byte is a clock behind h_addr). While playing, the
	// same port reads audio for the player.
	reg [3:0]   hdr_i;
	assign hdr_busy = (hdr_i != 4'd9);
	wire [14:0] h_addr = hdr_busy ? cur_slot * 15'd2352 + 15'd12 + {12'd0, hdr_i[2:0]}
	                              : pl_slot * 15'd2352 + {3'd0, pl_i, 2'b00} + {12'd0, pl_k[1:0]};
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
