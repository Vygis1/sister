//////////////////////////////////////////////////////////////////////////////////
// n64_pif.v - the PIF's RAM and its joybus: the controllers and the cartridge's
// EEPROM, as the CPU reaches them through PIF RAM and the SI.
//
// Behaviour is tools/n64/n64pif.py's (after ares, ISC). Our boot skips IPL3, so the
// PIF starts running, its boot handshake done, and only the joybus matters:
//   - a write into PIF RAM (the CPU's, or the SI's DMA) that leaves bit 0 of the
//     command byte (RAM[63]) set clears it -- at once, in the same write -- and
//     finds the channels' packets (parse);
//   - before the SI's DMA out of PIF RAM, the packets found are run: each
//     device's answer goes into its packet.
// Channels 0-3 are controllers (a gamepad with no pak, or nothing), channel 4
// the cartridge's EEPROM (none, 4 kbit or 16 kbit).
//
// One byte a clock (two for an EEPROM read, which waits for its block RAM), so
// a whole run is a few hundred clocks. `busy` covers it.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_pif (
	input  wire         clk,
	input  wire         rst,
	// the CPU: a doubleword of PIF RAM at a time (word k of it is ram[2*dw + k])
	input  wire         cpu_we,
	input  wire [2:0]   cpu_dw,
	input  wire [1:0]   cpu_wsel,       // [1] the upper word is written, [0] the lower
	input  wire [63:0]  cpu_wdata,
	output wire [511:0] ram_flat,       // word i in [511 - 32 i -: 32]
	// the SI's DMA into PIF RAM, a word at a time; `dma_last` on the last word
	input  wire         dma_we,
	input  wire [3:0]   dma_widx,
	input  wire [31:0]  dma_wdata,
	input  wire         dma_last,
	// before the SI's DMA out of PIF RAM: run the packets
	input  wire         go_run,
	output wire         busy,
	// the devices
	input  wire [31:0]  pad0, pad1, pad2, pad3,   // a controller's answer to a read
	input  wire [3:0]   pad_present,
	input  wire [1:0]   eep_size,       // 0 none, 1 4 kbit, 2 16 kbit
	// the EEPROM from outside (saving and loading it), when the joybus is idle
	input  wire         eh_we,
	input  wire [10:0]  eh_addr,
	input  wire [7:0]   eh_wdata,
	output reg  [7:0]   eh_rdata
);
	reg  [31:0] ram [0:15];
	integer k;
	initial for (k = 0; k < 16; k = k + 1) ram[k] = 32'd0;
	genvar g;
	generate for (g = 0; g < 16; g = g + 1) begin : g_flat
		assign ram_flat[511 - 32 * g -: 32] = ram[g];
	end endgenerate

	function [7:0] byte_at; input [5:0] b; byte_at = ram[b[5:2]][31 - 8 * b[1:0] -: 8]; endfunction

	// --- the EEPROM -------------------------------------------------------------------
	reg  [7:0]  eep [0:2047];
	initial for (k = 0; k < 2048; k = k + 1) eep[k] = 8'd0;
	reg         eep_we;
	reg  [10:0] eep_a;
	reg  [7:0]  eep_d, eep_q;
	wire [10:0] eep_mask = (eep_size == 2'd1) ? 11'h1FF : 11'h7FF;
	// two ports, each with its own address: the walker's, and the host's
	always @(posedge clk) begin
		if (eep_we) eep[eep_a] <= eep_d;
		eep_q <= eep[eep_a];
	end
	always @(posedge clk) begin
		if (eh_we) eep[eh_addr] <= eh_wdata;
		eh_rdata <= eep[eh_addr];
	end

	// --- the joybus walker ------------------------------------------------------------
	localparam [3:0] J_IDLE = 4'd0, J_P0 = 4'd1, J_P1 = 4'd2, J_R0 = 4'd3, J_R1 = 4'd4, J_R2 = 4'd5,
	                 J_RIN = 4'd6, J_RDEC = 4'd7, J_ROUT = 4'd8, J_ROUT2 = 4'd9, J_RNEXT = 4'd10, J_ROUTW = 4'd11;
	reg  [3:0]  js;
	assign busy = js != J_IDLE;
	reg  [5:0]  addr [0:4];
	reg  [4:0]  skip, rset;
	reg  [7:0]  off;                 // may run past 63 while parsing
	reg  [2:0]  ch;
	reg  [5:0]  start_, roff;
	reg  [5:0]  slen, rlen;
	reg  [5:0]  i;
	wire [5:0]  in_off = roff + 6'd1 + i;
	wire [7:0]  in_byte = ram[in_off[5:2]][31 - 8 * in_off[1:0] -: 8];   // the byte sent at i (as byte_at, read directly: a function reading ram would go stale here in simulation)
	reg  [7:0]  cmd, a1;
	reg  [7:0]  crc;
	reg         valid, over;
	reg  [2:0]  kind;                // what the answer is
	localparam [2:0] K_PADST = 3'd0, K_PADRD = 3'd1, K_PAKRD = 3'd2, K_PAKWR = 3'd3,
	                 K_EEPST = 3'd4, K_EEPRD = 3'd5, K_EEPWR = 3'd6;
	wire [31:0] pad_w = (ch == 3'd0) ? pad0 : (ch == 3'd1) ? pad1 : (ch == 3'd2) ? pad2 : pad3;
	wire        pad_on = pad_present[ch[1:0]];

	// the pak's data CRC, a byte at a time (x^8 + x^7 + x^2 + x + 1, as 0x85)
	function [7:0] crc_byte; input [7:0] c; input [7:0] b; integer j; reg [7:0] x; begin
		crc_byte = c;
		for (j = 7; j >= 0; j = j - 1) begin
			x = crc_byte[7] ? 8'h85 : 8'h00;
			crc_byte = {crc_byte[6:0], b[j]} ^ x;
		end
	end endfunction

	// the answer's byte o
	reg  [7:0] out_b;
	always @(*) begin
		case (kind)
		K_PADST: out_b = (i == 6'd0) ? 8'h05 : (i == 6'd2) ? 8'h02 : 8'h00;
		K_PADRD: out_b = (i == 6'd0) ? pad_w[31:24] : (i == 6'd1) ? pad_w[23:16] : (i == 6'd2) ? pad_w[15:8] : (i == 6'd3) ? pad_w[7:0] : 8'h00;
		K_PAKRD: out_b = (i == 6'd32) ? 8'hFF : 8'h00;               // no pak: the CRC of zeros, inverted
		K_PAKWR: out_b = (i == 6'd0) ? ((slen >= 6'd35 ? crc_byte(crc, 8'd0) : 8'h00) ^ 8'hFF) : 8'h00;
		K_EEPST: out_b = (i == 6'd1) ? ((eep_size == 2'd1) ? 8'h80 : 8'hC0) : 8'h00;
		K_EEPRD: out_b = eep_q;
		default: out_b = 8'h00;
		endcase
	end

	// the writes into RAM: the CPU's or the DMA's word, and the walker's byte
	reg         jw;
	reg  [5:0]  jw_a;
	reg  [7:0]  jw_d;
	wire [31:0] cpu_hi = cpu_wdata[63:32], cpu_lo = cpu_wdata[31:0];
	// a write whose command byte asks for a parse clears the bit as it lands
	wire        cpu_cmd = cpu_we && cpu_dw == 3'd7 && cpu_wsel[0] && cpu_lo[0];
	wire        dma_cmd = dma_we && dma_widx == 4'd15 && dma_wdata[0];

	always @(posedge clk) begin
		jw <= 1'b0; eep_we <= 1'b0;
		if (cpu_we) begin
			if (cpu_wsel[1]) ram[{cpu_dw, 1'b0}] <= cpu_hi;
			if (cpu_wsel[0]) ram[{cpu_dw, 1'b1}] <= (cpu_dw == 3'd7) ? {cpu_lo[31:1], 1'b0} : cpu_lo;
		end
		if (dma_we) ram[dma_widx] <= (dma_widx == 4'd15) ? {dma_wdata[31:1], 1'b0} : dma_wdata;
		if (jw) ram[jw_a[5:2]][31 - 8 * jw_a[1:0] -: 8] <= jw_d;

		if (rst) begin
			js <= J_IDLE; skip <= 5'h1F; rset <= 5'd0;
		end else case (js)
		J_IDLE: begin
			if (cpu_cmd || (dma_cmd && dma_last)) begin
				skip <= 5'h1F; rset <= 5'd0; off <= 8'd0; ch <= 3'd0; js <= J_P0;
			end else if (go_run && !ram[15][1]) begin      // bit 1 is the CIC challenge: not ours
				ch <= 3'd4; js <= J_R0;
			end
		end

		// --- parse: where each channel's packet is -------------------------------------
		J_P0: begin
			if (ch >= 3'd5 || off >= 8'd64) js <= J_IDLE;
			else case (byte_at(off[5:0]))
			8'hFE: js <= J_IDLE;
			8'hFF: off <= off + 8'd1;
			8'h00: begin ch <= ch + 3'd1; off <= off + 8'd1; end
			8'hFD: begin rset[ch] <= 1'b1; ch <= ch + 3'd1; off <= off + 8'd1; end
			default: begin start_ <= off[5:0]; slen <= byte_at(off[5:0]) & 8'h3F; off <= off + 8'd1; js <= J_P1; end
			endcase
		end
		J_P1: begin
			// off + 1 + send + recv: past the packet
			if (off + 8'd1 + {2'd0, slen} + {2'd0, byte_at(off[5:0]) & 8'h3F} < 8'd64) begin
				addr[ch] <= start_; skip[ch] <= 1'b0; ch <= ch + 3'd1;
			end
			off <= off + 8'd1 + {2'd0, slen} + {2'd0, byte_at(off[5:0]) & 8'h3F};
			js <= J_P0;
		end

		// --- run: the channels from 4 down to 0 ------------------------------------------
		J_R0: begin
			if (rset[ch] || skip[ch]) js <= J_RNEXT;
			else begin roff <= addr[ch]; js <= J_R1; end
		end
		J_R1: begin
			// the send byte: bit 7 skips the channel, bit 6 resets it
			if (byte_at(roff) & 8'hC0) js <= J_RNEXT;
			else begin slen <= byte_at(roff) & 8'h3F; roff <= roff + 6'd1; js <= J_R2; end
		end
		J_R2: begin
			rlen <= byte_at(roff) & 8'h3F;
			jw <= 1'b1; jw_a <= roff; jw_d <= byte_at(roff) & 8'h3F;
			i <= 6'd0; cmd <= 8'd0; a1 <= 8'd0; crc <= 8'd0;
			js <= J_RIN;
		end
		J_RIN: begin
			// the bytes sent: the command, its address, and an EEPROM write's data
			if (i == slen) js <= J_RDEC;
			else begin
				if (i == 6'd0) cmd <= byte_at(roff + 6'd1 + i);
				if (i == 6'd1) a1 <= byte_at(roff + 6'd1 + i);
				if (i >= 6'd3 && i < 6'd35) crc <= crc_byte(crc, in_byte);    // (not crc_byte(.., byte_at(..)): xsim mis-runs a call in a call)
				if (ch == 3'd4 && eep_size != 2'd0 && cmd == 8'h05 && slen >= 6'd2 && rlen >= 6'd1 && i >= 6'd2) begin
					eep_we <= 1'b1; eep_a <= ({a1, 3'b000} + {5'd0, i - 6'd2}) & eep_mask; eep_d <= byte_at(roff + 6'd1 + i);
				end
				i <= i + 6'd1;
			end
		end
		J_RDEC: begin
			valid <= 1'b0; over <= 1'b0;
			if (ch != 3'd4) begin
				if (pad_on) begin
					if (cmd == 8'h00 || cmd == 8'hFF) begin valid <= 1'b1; kind <= K_PADST; end
					else if (cmd == 8'h01) begin valid <= 1'b1; over <= rlen > 6'd4; kind <= K_PADRD; end
					else if (cmd == 8'h02 && slen >= 6'd3 && rlen >= 6'd1) begin valid <= 1'b1; kind <= K_PAKRD; end
					else if (cmd == 8'h03 && slen >= 6'd4 && rlen >= 6'd1) begin valid <= 1'b1; kind <= K_PAKWR; end
				end
			end else if (eep_size != 2'd0) begin
				if (cmd == 8'h00 || cmd == 8'hFF) begin valid <= 1'b1; kind <= K_EEPST; end
				else if (cmd == 8'h04 && slen >= 6'd2) begin valid <= 1'b1; kind <= K_EEPRD; end
				else if (cmd == 8'h05 && slen >= 6'd2 && rlen >= 6'd1) begin valid <= 1'b1; kind <= K_EEPWR; end
			end
			i <= 6'd0;
			js <= J_ROUT;
		end
		J_ROUT: begin
			// the receive byte's flags, then the answer
			if (i == 6'd0 && !valid) begin jw <= 1'b1; jw_a <= roff; jw_d <= 8'h80 | {2'd0, rlen}; js <= J_RNEXT; end
			else begin
				if (i == 6'd0 && over) begin jw <= 1'b1; jw_a <= roff; jw_d <= 8'h40 | {2'd0, rlen}; end
				if (i == rlen) js <= J_RNEXT;
				else begin
					eep_a <= ({a1, 3'b000} + {5'd0, i}) & eep_mask;   // an EEPROM read's byte, two clocks away
					js <= J_ROUTW;
				end
			end
		end
		J_ROUTW: js <= J_ROUT2;
		J_ROUT2: begin
			jw <= 1'b1; jw_a <= roff + 6'd1 + slen + i; jw_d <= out_b;
			i <= i + 6'd1;
			js <= J_ROUT;
		end
		J_RNEXT: begin
			if (ch == 3'd0) js <= J_IDLE;
			else begin ch <= ch - 3'd1; js <= J_R0; end
		end
		default: js <= J_IDLE;
		endcase
	end
endmodule

`default_nettype wire
