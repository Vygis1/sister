//////////////////////////////////////////////////////////////////////////////////
// ps1_sio.v - SIO0, the controller port, with one digital pad in slot 1.
//
// The registers at 1F801040h-1F80104Eh as psx-spx describes them: TX/RX data,
// STAT (TX ready, RX not empty, TX idle, /ACK level, IRQ), MODE, CTRL (TXEN,
// /JOY select, RXEN, acknowledge, reset, /ACK interrupt enable, slot), BAUD.
// Writing TX_DATA with TXEN set shifts one byte out and one byte in over
// SHIFT_CYCLES; if the pad is selected it answers the standard exchange
//     01h 42h 00h 00h 00h  ->  FFh 41h 5Ah SWLO SWHI
// pulsing /ACK after every byte but the last (each pulse raises IRQ7 when the
// DSR interrupt is enabled, which is how the kernel paces the transfer). The
// button word is active low: `buttons` is the host's pressed-bits in PS1 order.
// Slot 2 and memory cards answer nothing (FFh, no /ACK), like empty ports.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_sio #(
	parameter SHIFT_CYCLES = 1400,     // one byte at the BIOS's baud, in core clocks
	parameter ACK_DELAY    = 60,       // byte done -> /ACK low
	parameter ACK_LOW      = 120       // /ACK held low (>= 2 us)
)(
	input  wire        clk,
	input  wire        rst,

	input  wire        sel,
	input  wire        we,
	input  wire [3:0]  addr,
	input  wire [3:0]  be,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,

	input  wire [15:0] buttons,        // pressed = 1, PS1 bit order (0 select .. 15 square)
	output wire        irq             // I_STAT bit 7
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

	// the pad's answer to the byte just shifted in
	reg [7:0] reply; reg reply_ack;
	always @(*) begin
		reply = 8'hFF; reply_ack = 1'b0;
		if (joy_sel && !slot) begin
			case (pad_idx)
			3'd0: if (tx_byte == 8'h01) begin reply = 8'hFF; reply_ack = 1'b1; end
			3'd1: if (pad_active && tx_byte == 8'h42) begin reply = 8'h41; reply_ack = 1'b1; end
			3'd2: if (pad_active) begin reply = 8'h5A; reply_ack = 1'b1; end
			3'd3: if (pad_active) begin reply = ~buttons[7:0]; reply_ack = 1'b1; end
			3'd4: if (pad_active) begin reply = ~buttons[15:8]; reply_ack = 1'b0; end
			default: ;
			endcase
		end
	end

	always @(posedge clk) begin
		if (rst) begin
			txen <= 0; joy_sel <= 0; rxen <= 0; ack_ien <= 0; slot <= 0; mode <= 0; baud <= 0;
			irq_flag <= 0; rx_byte <= 8'hFF; rx_full <= 0; busy <= 0; timer <= 0; tx_byte <= 0; tx_pend <= 0;
			pad_idx <= 0; pad_active <= 0; ack_wait <= 0; ack_low <= 0; ack_timer <= 0;
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
						end
						if (!wdata[17]) begin pad_idx <= 0; pad_active <= 0; end   // deselect ends the exchange
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
				else begin
					busy <= 1'b0;
					rx_byte <= reply; rx_full <= 1'b1;
					if (reply_ack) begin ack_wait <= 1'b1; ack_timer <= 8'd0; end
					if (joy_sel && !slot) begin
						if (pad_idx == 3'd0) pad_active <= (tx_byte == 8'h01);
						if (pad_idx != 3'd7) pad_idx <= pad_idx + 3'd1;
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
		end
	end
endmodule

`default_nettype wire
