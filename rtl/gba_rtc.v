//////////////////////////////////////////////////////////////////////////////////
// gba_rtc - a Game Boy Advance cartridge's GPIO port and the Seiko S-3511 clock behind it
// (Pokemon Ruby / Sapphire / Emerald, Boktai).
//
// The port: four pins at the cartridge's 0x080000C4 (data), 0x080000C6 (direction: 1 = the
// console drives the pin) and 0x080000C8 (bit 0: the three read back; 0 = write only, reads 0).
// The clock on pins 0 SCK, 1 SIO, 2 CS: CS high starts a transfer; a command byte comes in on SCK
// rising edges, low bit first -- low nibble 0110, bits 6:4 the command, bit 7 reading -- then
// its data bytes, in or out. Commands: 0 reset (control 0), 2 date and time (7 bytes: year,
// month, day, weekday, hour, minute, second, BCD), 4 control (1 byte: bit 6 24-hour, bit 7
// power lost), 6 time (3 bytes). Setting the time is taken and ignored: the time is the
// console's, written by the menu (now_bcd). This follows mGBA's gba/cart/gpio.c step for step,
// its SIO races included.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module gba_rtc (
	input  wire        clk,
	input  wire        rst,
	input  wire        en,                 // the cartridge has the port and the clock
	input  wire        we,                 // a halfword write to the port: wa 0 data, 1 direction, 2 control
	input  wire [1:0]  wa,
	input  wire [3:0]  wd,
	input  wire [1:0]  ra,                 // a read: the same registers
	output wire [15:0] rq,
	output wire        readable,           // the control register's bit 0
	input  wire [55:0] now_bcd             // {year, month, day, weekday, hour (24), minute, second}
);
	reg [3:0] latch, pins, dir; reg rw;
	reg [3:0] nbits;                       // bits of the byte in/out so far
	reg [3:0] left;                        // the command's data bytes still to go
	reg [7:0] bits, cmd, ctl;
	reg       active, sck_q, sio;
	reg [55:0] t;                          // the time, taken when a time command starts

	function [2:0] nbytes; input [2:0] c;
		nbytes = (c == 3'd2) ? 3'd7 : (c == 3'd4) ? 3'd1 : (c == 3'd6) ? 3'd3 : 3'd0;
	endfunction
	// the hour on a 12-hour clock (BCD in, BCD out)
	function [7:0] h12; input [7:0] h;
		reg [4:0] b;
		begin
			b = h[7:4] * 4'd10 + h[3:0];
			if (b >= 5'd12) b = b - 5'd12;
			h12 = (b >= 5'd10) ? {4'd1, b[3:0] - 4'd10} : {4'd0, b[3:0]};
		end
	endfunction
	// the byte going out: the time (from the year) or the control register
	function [7:0] obyte; input [7:0] c; input [3:0] n; input [55:0] tm; input [7:0] cr;
		begin
			obyte = 8'hFF;
			if (c[6:4] == 3'd4) obyte = cr;
			else if (c[6:4] == 3'd2 || c[6:4] == 3'd6)
				case (4'd7 - n)
					4'd0: obyte = tm[55:48]; 4'd1: obyte = tm[47:40]; 4'd2: obyte = tm[39:32]; 4'd3: obyte = tm[31:24];
					4'd4: obyte = tm[23:16]; 4'd5: obyte = tm[15:8]; 4'd6: obyte = tm[7:0];
					default: obyte = 8'hFF;
				endcase
		end
	endfunction

	// the time as it goes out: the hour on the clock the control register asks for (not a call
	// inside obyte: xsim gets nested function calls wrong)
	wire [55:0] t_out = {t[55:24], ctl[6] ? t[23:16] : h12(t[23:16]), t[15:0]};
	assign readable = rw;
	assign rq = !rw ? 16'd0 : (ra == 2'd0) ? {12'd0, pins} : (ra == 2'd1) ? {12'd0, dir} : (ra == 2'd2) ? {15'd0, rw} : 16'd0;

	reg [3:0] p, d, l; reg [7:0] b; reg [3:0] n, lf; reg act, sq, so; reg [7:0] c, cr;
	always @(posedge clk) begin
		if (rst) begin
			latch <= 4'd0; pins <= 4'd0; dir <= 4'd0; rw <= 1'b0;
			nbits <= 4'd0; left <= 4'd0; bits <= 8'd0; cmd <= 8'd0; ctl <= 8'h40; active <= 1'b0; sck_q <= 1'b1; sio <= 1'b1; t <= 56'd0;
		end else if (we && en) begin
			p = pins; d = dir; l = latch; b = bits; n = nbits; lf = left; act = active; sq = sck_q; so = sio; c = cmd; cr = ctl;
			if (wa == 2'd0) begin l = wd; p = (p & ~d) | (l & d); end
			else if (wa == 2'd1) begin d = wd; p = (p & ~d) | (l & d); end
			else rw <= wd[0];
			if (wa != 2'd2) begin
				// the clock sees the pins: it holds SCK, CS and the spare low, SIO high unless sending
				p = (p & d) | (p & 4'b0010 & ~d);
				if (!p[2]) begin
					n = 4'd0; lf = 4'd0; act = 1'b0; c = 8'd0; sq = 1'b1; so = 1'b1;
					p = (p & d) | (4'b0010 & ~d);
				end else begin
					if (!act) begin
						// the command byte coming in
						p = (p & d) | (4'b0010 & ~d);
						if (!p[0] && n < 4'd8) b[n[2:0]] = p[1];
						if (!sq && p[0]) begin
							n = n + 4'd1;
							if (n == 4'd8) begin
								if (b[3:0] == 4'b0110) begin
									c = b; lf = {1'b0, nbytes(b[6:4])}; act = 1'b1;
									if (b[6:4] == 3'd0) cr = 8'd0;
									if (b[6:4] == 3'd2 || b[6:4] == 3'd6) t <= now_bcd;
								end
								b = 8'd0; n = 4'd0;
							end
						end
					end else if (!c[7]) begin
						// data coming in (only the control register keeps it)
						p = (p & d) | (4'b0010 & ~d);
						if (!p[0] && n < 4'd8) b[n[2:0]] = p[1];
						if (!sq && p[0]) begin
							if (n < 4'd8 && (b[n[2:0]] ^ p[1])) b[n[2:0]] = 1'b0;
							n = n + 4'd1;
							if (n == 4'd8) begin
								if (c[6:4] == 3'd4) cr = b;
								b = 8'd0; n = 4'd0;
								lf = (lf <= 4'd1) ? {1'b0, nbytes(c[6:4])} : lf - 4'd1;
							end
						end
					end else begin
						// data going out on SCK falling edges
						if (sq && !p[0]) begin
							so = obyte(c, lf, t_out, cr) >> n[2:0];
							n = n + 4'd1;
							if (n == 4'd8) begin
								lf = (lf <= 4'd1) ? {1'b0, nbytes(c[6:4])} : lf - 4'd1;
								n = 4'd0;
							end
						end
						p = (p & d) | ({2'b00, so, 1'b0} & ~d);
					end
					sq = p[0];
				end
			end
			pins <= p; dir <= d; latch <= l; bits <= b; nbits <= n; left <= lf; active <= act; sck_q <= sq; sio <= so; cmd <= c; ctl <= cr;
		end
	end
endmodule
`default_nettype wire
