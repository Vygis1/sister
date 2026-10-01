//////////////////////////////////////////////////////////////////////////////////
// ps1_sio.v - SIO0, the controller ports: a digital pad and a memory card in each slot.
//
// The registers at 1F801040h-1F80104Eh as psx-spx describes them: TX/RX data,
// STAT (TX ready, RX not empty, TX idle, /ACK level, IRQ), MODE, CTRL (TXEN,
// /JOY select, RXEN, acknowledge, reset, /ACK interrupt enable, slot), BAUD.
// Writing TX_DATA with TXEN set shifts one byte out and one byte in over
// SHIFT_CYCLES. The first byte of an exchange says who answers:
//
//   01h  the pad:  01h 42h 00h 00h 00h  ->  FFh 41h 5Ah SWLO SWHI
//   81h  the card: read, write or get-ID, below
//
// with /ACK pulsed after every byte but the last (each pulse raises IRQ7 when
// the DSR interrupt is enabled, which is how the kernel paces the transfer).
// The button word is active low: `buttons` is the host's pressed-bits in PS1
// order. Slot 2 is the same again (CTRL bit 13 picks the slot): its own pad
// (`buttons2`) and its own card (`card2_in`), which lives 128 kB after card 1
// and whose stored sectors are queued with the slot in bit 10.
//
// --- the memory card -------------------------------------------------------------
//
// Byte for byte what DuckStation's MemoryCard::Transfer does (the project's
// reference emulator), where "last" is the byte the console sent just before:
//
//   81h            -> FFh               the card is here
//   52h/57h/53h    -> FLAG              read / write / get ID
//   read:   00h 00h MSB LSB 00h 00h 00h 00h, 128 x 00h, 00h 00h
//        -> 5Ah 5Dh 00h last 5Ch 5Dh MSB LSB, the sector,  CHK 47h
//   write:  00h 00h MSB LSB, 128 data bytes, CHK, 00h 00h 00h
//        -> 5Ah 5Dh 00h last, last x 128,   last, 5Ch 5Dh 47h
//   get ID: 00h x 8 -> 5Ah 5Dh 5Ch 5Dh 04h 00h 00h 80h
//
// The last byte of each carries no /ACK. CHK is MSB ^ LSB ^ every data byte.
// FLAG bit 3 says "not written since power-on" and the first write clears it
// (games use it to notice a card was swapped). A write whose checksum is wrong
// ends 4Eh and is not stored, as on the card; DuckStation stores it and ends
// 47h, but no correct program sends one.
//
// The card's 128 kB live in DDR3 (CARD_LINE in ps1_top.v), because block RAM
// is full. A sector at a time comes through a 128-byte buffer here and one
// line port: a read's sector is fetched while the console is still clocking
// the four bytes in front of it (about 5,600 clocks; the fetch takes a few
// hundred), and a written sector goes out after its checksum. Should a fetch
// ever be late, the byte that needs it simply takes longer to shift -- the
// console waits for the /ACK anyway.
//
// Every sector stored is also queued (wq_*), so the PC can copy it into the
// card's file: that is what makes a save outlive the power. The queue is on the
// global reset, not the console's, so a console reset cannot lose a save the PC
// has not collected yet; if it ever overflows, wq_ovf says so and the PC reads
// the whole card back instead.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_sio #(
	parameter SHIFT_CYCLES = 1400,     // one byte at the BIOS's baud, in core clocks
	parameter ACK_DELAY    = 60,       // byte done -> /ACK low
	parameter ACK_LOW      = 120       // /ACK held low (>= 2 us)
)(
	input  wire        clk,
	input  wire        rst,               // the console's reset
	input  wire        rst_q,             // the board's: the save queue lives on it

	input  wire        sel,
	input  wire        we,
	input  wire [3:0]  addr,
	input  wire [3:0]  be,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,

	input  wire [15:0] buttons,        // pressed = 1, PS1 bit order (0 select .. 15 square)
	input  wire [15:0] buttons2,       // the pad in slot 2
	output wire        irq,            // I_STAT bit 7

	// --- the memory card ------------------------------------------------------------
	input  wire        card_in,        // a card is in slot 1 (the PC has loaded one)
	input  wire        card2_in,       // ...and in slot 2
	output reg  [13:0] m_line,         // {slot, sector, k}: the line within the two cards
	output reg         m_req,
	output reg         m_we,
	output wire [127:0] m_wdata,
	input  wire        m_ready,        // request taken
	input  wire        m_valid,        // a read's line is here
	input  wire [127:0] m_rdata,

	output wire [10:0] wq_sector,      // the oldest stored sector the PC has not copied: {slot, sector}
	output wire [4:0]  wq_count,
	output reg         wq_ovf,
	input  wire        wq_pop,         // the PC has it
	input  wire        wq_clr_ovf
);
	reg        txen, joy_sel, rxen, ack_ien, slot;
	reg [15:0] mode, baud;
	reg        irq_flag;
	reg [7:0]  rx_byte;
	reg        rx_full;
	reg        busy;                  // a byte is being shifted
	reg [11:0] timer;
	reg [7:0]  tx_byte;
	reg        tx_pend;               // a byte written before TXEN: starts when TXEN comes (psx-spx)
	reg [2:0]  pad_idx;               // where the pad is in the 5-byte exchange
	reg        pad_active;            // the exchange started with 01h
	reg        ack_wait, ack_low;
	reg [7:0]  ack_timer;

	assign irq = irq_flag;
	wire [15:0] stat = {6'd0, irq_flag, 1'b0, ack_low, 4'd0, !busy, rx_full, 1'b1};
	wire [15:0] ctrl = {2'd0, slot, ack_ien, 1'b0, 1'b0, 2'd0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, rxen, joy_sel, txen};

	always @(*) begin
		case (addr[3:2])
		2'd0:    rdata = {24'hFFFFFF, rx_full ? rx_byte : 8'hFF};
		2'd1:    rdata = {16'd0, stat};
		2'd2:    rdata = {ctrl, mode};
		default: rdata = {baud, 16'd0};
		endcase
	end

	// ================================================================================
	// the memory card's state
	// ================================================================================
	localparam MC_R = 2'd1, MC_W = 2'd2, MC_ID = 2'd3;
	reg        mc_active;             // this exchange is the card's
	reg [1:0]  mc_cmd;
	reg [7:0]  mc_idx;                // byte of the exchange being shifted (0 is the 81h)
	reg [7:0]  mc_last;               // the byte the console sent before this one
	reg [7:0]  mc_msb, mc_lsb;
	reg [7:0]  mc_chk;
	reg        mc_flag_new, mc_flag_new2;   // FLAG bit 3, per card
	reg        card2_in_d;
	reg        mc_slot;                 // the slot of the card the exchange is with
	wire       card_here = slot ? card2_in : card_in;
	wire [15:0] btn      = slot ? buttons2 : buttons;
	reg        mc_chk_bad;
	reg        card_in_d;
	wire [9:0] mc_sector = {mc_msb[1:0], mc_lsb};

	// the sector buffer: eight lines, LUT-RAM
	(* ram_style = "distributed" *) reg [127:0] mbuf [0:7];
	// byte j of the sector for a read's data phase (reply index 10..137)
	wire [7:0]  rd_j    = mc_idx - 8'd10;
	wire [127:0] rd_line = mbuf[rd_j[6:4]];
	wire [7:0]  rd_byte = rd_line[{rd_j[3:0], 3'b000} +: 8];
	// byte j for a write's data phase (index 6..133)
	wire [7:0]  wr_j    = mc_idx - 8'd6;
	wire [127:0] wr_line = mbuf[wr_j[6:4]];

	// the line port's sequencer: fetch a sector into the buffer, or store it
	reg        job_rd, job_wr;        // a fetch / a store is running
	reg        job_wait;              // a read is out; waiting for its line
	reg [2:0]  job_k;
	reg        have;                  // the buffer holds the sector being read
	reg        wr_queued;             // a store is waiting for a fetch to finish (never in practice)
	reg [9:0]  job_sector;
	reg        job_slot;
	assign m_wdata = mbuf[job_k];

	// ---- the reply to the byte being shifted: the pad's or the card's ------------------
	reg [7:0] reply; reg reply_ack;
	always @(*) begin
		reply = 8'hFF; reply_ack = 1'b0;
		if (joy_sel) begin
			if (mc_active) begin
				case (mc_cmd)
				2'd0:    begin reply = {4'd0, slot ? mc_flag_new2 : mc_flag_new, 3'd0};    // the command byte
				               reply_ack = (tx_byte == 8'h52 || tx_byte == 8'h57 || tx_byte == 8'h53); end
				MC_ID:   case (mc_idx)
				         8'd2: begin reply = 8'h5A; reply_ack = 1'b1; end
				         8'd3: begin reply = 8'h5D; reply_ack = 1'b1; end
				         8'd4: begin reply = 8'h5C; reply_ack = 1'b1; end
				         8'd5: begin reply = 8'h5D; reply_ack = 1'b1; end
				         8'd6: begin reply = 8'h04; reply_ack = 1'b1; end
				         8'd7: begin reply = 8'h00; reply_ack = 1'b1; end
				         8'd8: begin reply = 8'h00; reply_ack = 1'b1; end
				         8'd9: begin reply = 8'h80; reply_ack = 1'b0; end
				         default: ;
				         endcase
				default: case (mc_idx)                                                     // read and write share 2..5
				         8'd2: begin reply = 8'h5A; reply_ack = 1'b1; end
				         8'd3: begin reply = 8'h5D; reply_ack = 1'b1; end
				         8'd4: begin reply = 8'h00; reply_ack = 1'b1; end
				         8'd5: begin reply = mc_last; reply_ack = 1'b1; end
				         default:
				             if (mc_cmd == MC_R) begin
				                 if      (mc_idx == 8'd6)  begin reply = 8'h5C;  reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd7)  begin reply = 8'h5D;  reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd8)  begin reply = mc_msb; reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd9)  begin reply = mc_lsb; reply_ack = 1'b1; end
				                 else if (mc_idx < 8'd138) begin reply = rd_byte; reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd138) begin reply = mc_chk; reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd139) begin reply = 8'h47; reply_ack = 1'b0; end
				             end else begin
				                 if      (mc_idx < 8'd135) begin reply = mc_last; reply_ack = 1'b1; end   // data and checksum
				                 else if (mc_idx == 8'd135) begin reply = 8'h5C; reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd136) begin reply = 8'h5D; reply_ack = 1'b1; end
				                 else if (mc_idx == 8'd137) begin reply = mc_chk_bad ? 8'h4E : 8'h47; reply_ack = 1'b0; end
				             end
				         endcase
				endcase
			end else if (pad_idx == 3'd0 && tx_byte == 8'h81) begin
				reply = 8'hFF; reply_ack = card_here;                                      // the card answers its address
			end else begin
				case (pad_idx)
				3'd0: if (tx_byte == 8'h01) begin reply = 8'hFF; reply_ack = 1'b1; end
				3'd1: if (pad_active && tx_byte == 8'h42) begin reply = 8'h41; reply_ack = 1'b1; end
				3'd2: if (pad_active) begin reply = 8'h5A; reply_ack = 1'b1; end
				3'd3: if (pad_active) begin reply = ~btn[7:0]; reply_ack = 1'b1; end
				3'd4: if (pad_active) begin reply = ~btn[15:8]; reply_ack = 1'b0; end
				default: ;
				endcase
			end
		end
	end

	// A read's data phase needs the sector: the byte that needs it waits for it.
	wire need_buf = mc_active && (mc_cmd == MC_R) && (mc_idx >= 8'd10) && (mc_idx < 8'd138) && !have;
	// the card's exchange ends: deselected, reset, or a byte without /ACK
	wire byte_done = busy && (timer == SHIFT_CYCLES[11:0]) && !need_buf;

	always @(posedge clk) begin
		if (rst) begin
			txen <= 0; joy_sel <= 0; rxen <= 0; ack_ien <= 0; slot <= 0; mode <= 0; baud <= 0;
			irq_flag <= 0; rx_byte <= 8'hFF; rx_full <= 0; busy <= 0; timer <= 0; tx_byte <= 0; tx_pend <= 0;
			pad_idx <= 0; pad_active <= 0; ack_wait <= 0; ack_low <= 0; ack_timer <= 0;
			mc_active <= 1'b0; mc_cmd <= 2'd0; mc_idx <= 8'd0; mc_last <= 8'd0; mc_flag_new <= 1'b1; mc_flag_new2 <= 1'b1;
		end else begin
			// ---- register writes ----
			if (sel && we) begin
				case (addr[3:2])
				2'd0: if (be[0]) begin tx_byte <= wdata[7:0]; tx_pend <= 1'b1; end   // starts below, once TXEN is on and the line idle
				2'd2: begin
					if (be[0]) mode[7:0] <= wdata[7:0];
					if (be[1]) mode[15:8] <= wdata[15:8];
					if (be[2]) begin
						txen <= wdata[16]; joy_sel <= wdata[17]; rxen <= wdata[18];
						if (wdata[20]) irq_flag <= 1'b0;                       // acknowledge
						if (wdata[22]) begin                                   // reset
							txen <= 0; joy_sel <= 0; rxen <= 0; irq_flag <= 0; rx_full <= 0; busy <= 0; tx_pend <= 0;
							pad_idx <= 0; pad_active <= 0; ack_wait <= 0; ack_low <= 0;
							mc_active <= 1'b0; mc_cmd <= 2'd0; mc_idx <= 8'd0;
						end
						if (!wdata[17]) begin                                  // deselect ends the exchange
							pad_idx <= 0; pad_active <= 0;
							mc_active <= 1'b0; mc_cmd <= 2'd0; mc_idx <= 8'd0;
						end
					end
					if (be[3]) begin ack_ien <= wdata[28]; slot <= wdata[29]; end
				end
				2'd3: if (be[2]) baud[7:0] <= wdata[23:16]; else if (be[3]) baud[15:8] <= wdata[31:24];
				default: ;
				endcase
				if (addr[3:2] == 2'd3 && be[2] && be[3]) baud <= wdata[31:16];
			end else if (sel && !we && addr[3:2] == 2'd0) begin
				rx_full <= 1'b0;                                                  // RX_DATA read
			end

			// ---- the byte shifting out and in ----
			if (tx_pend && txen && !busy) begin tx_pend <= 1'b0; busy <= 1'b1; timer <= 12'd0; end
			if (busy) begin
				if (timer != SHIFT_CYCLES[11:0]) timer <= timer + 12'd1;
				else if (byte_done) begin
					busy <= 1'b0;
					rx_byte <= reply; rx_full <= 1'b1;
					if (reply_ack) begin ack_wait <= 1'b1; ack_timer <= 8'd0; end
					if (joy_sel) begin
						if (pad_idx == 3'd0) pad_active <= (tx_byte == 8'h01);
						if (pad_idx != 3'd7) pad_idx <= pad_idx + 3'd1;

						// the card follows its exchange
						mc_last <= tx_byte;
						if (!mc_active) begin
							if (pad_idx == 3'd0 && tx_byte == 8'h81 && card_here) begin mc_active <= 1'b1; mc_cmd <= 2'd0; mc_idx <= 8'd1; mc_slot <= slot; end
						end else begin
							if (!reply_ack) mc_active <= 1'b0;                  // its last byte, or a command it does not know
							if (mc_idx != 8'hFF) mc_idx <= mc_idx + 8'd1;
							if (mc_cmd == 2'd0)
								mc_cmd <= (tx_byte == 8'h52) ? MC_R : (tx_byte == 8'h57) ? MC_W : MC_ID;
							if (mc_idx == 8'd4) mc_msb <= tx_byte & 8'h03;      // sector 0..3FFh, as DuckStation masks it
							if (mc_idx == 8'd5) begin
								mc_lsb <= tx_byte;
								mc_chk <= (mc_msb & 8'h03) ^ tx_byte;
							end
							if (mc_cmd == MC_R && mc_idx >= 8'd10 && mc_idx < 8'd138) mc_chk <= mc_chk ^ rd_byte;
							if (mc_cmd == MC_W && mc_idx >= 8'd6 && mc_idx < 8'd134) begin
								mc_chk <= mc_chk ^ tx_byte;
								if (mc_idx == 8'd6) begin                         // the first write since power-on
									if (mc_slot) mc_flag_new2 <= 1'b0; else mc_flag_new <= 1'b0;
								end
							end
							if (mc_cmd == MC_W && mc_idx == 8'd134) mc_chk_bad <= (tx_byte != mc_chk);
						end
					end
				end
			end

			// ---- /ACK: a pulse a little after the byte, raising IRQ7 if enabled ----
			if (ack_wait) begin
				if (ack_timer != ACK_DELAY[7:0]) ack_timer <= ack_timer + 8'd1;
				else begin ack_wait <= 1'b0; ack_low <= 1'b1; ack_timer <= 8'd0; if (ack_ien) irq_flag <= 1'b1; end
			end else if (ack_low) begin
				if (ack_timer != ACK_LOW[7:0]) ack_timer <= ack_timer + 8'd1;
				else ack_low <= 1'b0;
			end

			// a card going in is a fresh card
			card_in_d <= card_in; card2_in_d <= card2_in;
			if (card_in && !card_in_d) mc_flag_new <= 1'b1;
			if (card2_in && !card2_in_d) mc_flag_new2 <= 1'b1;
		end
	end

	// ================================================================================
	// the sector buffer and the line port
	// ================================================================================
	// Written from the console's bytes (a write's data phase) and from memory (a
	// fetch); the two never meet, a fetch running only between the address and
	// the data of a read.
	wire wbyte = byte_done && joy_sel && mc_active && mc_cmd == MC_W
	             && mc_idx >= 8'd6 && mc_idx < 8'd134;
	wire [127:0] wr_merged = merge8(wr_line, wr_j[3:0], tx_byte);
	function [127:0] merge8; input [127:0] l; input [3:0] b; input [7:0] v;
		begin merge8 = l; merge8[{b, 3'b000} +: 8] = v; end
	endfunction
	// what starts a job: a read's address is in, or a write's checksum checked out
	wire start_rd = byte_done && joy_sel && mc_active && mc_cmd == MC_R && mc_idx == 8'd5;
	wire start_wr = byte_done && joy_sel && mc_active && mc_cmd == MC_W && mc_idx == 8'd134
	                && tx_byte == mc_chk;

	always @(posedge clk) begin
		if (wbyte)                              mbuf[wr_j[6:4]] <= wr_merged;
		else if (job_rd && job_wait && m_valid) mbuf[job_k]     <= m_rdata;
	end

	always @(posedge clk) begin
		if (rst) begin
			job_rd <= 1'b0; job_wr <= 1'b0; job_wait <= 1'b0; job_k <= 3'd0; have <= 1'b0;
			m_req <= 1'b0; m_we <= 1'b0; wr_queued <= 1'b0;
		end else begin
			if (start_rd) begin
				have <= 1'b0;
				job_rd <= 1'b1; job_k <= 3'd0; job_wait <= 1'b0;
				job_sector <= {mc_msb[1:0], tx_byte}; job_slot <= mc_slot;
				m_line <= {mc_slot, mc_msb[1:0], tx_byte, 3'd0}; m_we <= 1'b0; m_req <= 1'b1;
			end else if (job_rd) begin
				if (m_req && m_ready) begin m_req <= 1'b0; job_wait <= 1'b1; end
				if (job_wait && m_valid) begin
					job_wait <= 1'b0;
					if (job_k == 3'd7) begin job_rd <= 1'b0; have <= 1'b1; end
					else begin job_k <= job_k + 3'd1; m_line <= m_line + 14'd1; m_req <= 1'b1; end
				end
			end

			// a store: eight lines out of the buffer, one after another
			if (start_wr) begin
				if (job_rd) wr_queued <= 1'b1;
				else begin job_wr <= 1'b1; job_k <= 3'd0; m_line <= {mc_slot, mc_sector, 3'd0}; m_we <= 1'b1; m_req <= 1'b1; end
				job_sector <= mc_sector; job_slot <= mc_slot;
			end else if (wr_queued && !job_rd) begin
				wr_queued <= 1'b0;
				job_wr <= 1'b1; job_k <= 3'd0; m_line <= {job_slot, job_sector, 3'd0}; m_we <= 1'b1; m_req <= 1'b1;
			end else if (job_wr && m_req && m_ready) begin
				if (job_k == 3'd7) begin job_wr <= 1'b0; m_req <= 1'b0; m_we <= 1'b0; end
				else begin job_k <= job_k + 3'd1; m_line <= m_line + 14'd1; end
			end
		end
	end

	// ================================================================================
	// the queue of stored sectors, for the PC to copy into the card's file
	// ================================================================================
	(* ram_style = "distributed" *) reg [10:0] wq [0:15];
	reg [4:0] wq_wp, wq_rp;
	wire      wq_push = job_wr && m_req && m_ready && job_k == 3'd7;   // the sector's last line is taken
	assign wq_count  = wq_wp - wq_rp;
	assign wq_sector = wq[wq_rp[3:0]];
	always @(posedge clk) begin
		if (rst_q) begin wq_wp <= 5'd0; wq_rp <= 5'd0; wq_ovf <= 1'b0; end
		else begin
			if (wq_push) begin
				if (wq_count == 5'd16) wq_ovf <= 1'b1;
				else begin wq[wq_wp[3:0]] <= {job_slot, job_sector}; wq_wp <= wq_wp + 5'd1; end
			end
			if (wq_pop && wq_count != 5'd0) wq_rp <= wq_rp + 5'd1;
			if (wq_clr_ovf) wq_ovf <= 1'b0;
		end
	end
endmodule

`default_nettype wire
