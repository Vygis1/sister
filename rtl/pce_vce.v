`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// pce_vce.v - the PC Engine's colour encoder, the HuC6260: the clocks and the colours.
//
// The chip makes the dot clock from the 21.477 MHz master clock -- divided by 4, 3 or 2 as
// register $0400's low bits say (5.37, 7.16 or 10.74 MHz: 256, 352 or 512 pixels across
// the same picture) -- and a line is 1365 master clocks, a frame 262 or 263 of them (bit 2).
// Here the master clock is an enable made from the system clock, and `dot_ce`, `line_start`,
// `frame_start`, `dot` and `line` are what the VDC runs on.
//
// Its 512 colours, 9 bits each (GGGRRRBBB), are reached through $0402/$0403 (the entry) and
// $0404/$0405 (its low byte, its high bit; the entry steps after the high byte). The VDC gives
// an entry number a dot; the colour comes out of the table a clock later.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module pce_vce #(
	parameter CLK_HZ = 50_000_000
) (
	input  wire        clk,
	input  wire        rst,
	// the processor's port: physical $1FE400 + a[2:0]
	input  wire        sel,
	input  wire [2:0]  a,
	input  wire        we,
	input  wire        rd,
	input  wire [7:0]  d,
	output reg  [7:0]  q,
	// the clocks
	output reg         dot_ce,
	output reg         line_start,
	output reg         frame_start,
	output reg  [9:0]  dot,
	output reg  [8:0]  line,
	output wire [1:0]  dot_rate,      // 0: 5.37 MHz, 1: 7.16, 2/3: 10.74
	// the colour of the VDC's pixel
	input  wire [8:0]  idx,
	input  wire        idx_en,
	output reg  [8:0]  rgb,           // GGGRRRBBB
	output reg         rgb_en
);
	reg [7:0] ctrl;
	reg [8:0] cta;                    // the colour table entry
	reg [7:0] ctlo;
	assign dot_rate = ctrl[1:0];

	// --- the master clock, 21477272 Hz from CLK_HZ; the dot from it -------------------------------
	localparam [31:0] MASTER_HZ = 32'd21_477_272;
	reg  [31:0] acc;
	reg         m_ce;
	reg  [1:0]  div;
	reg  [10:0] mcount;               // master clocks into the line, 0..1364
	wire [8:0]  lines = ctrl[2] ? 9'd263 : 9'd262;
	always @(posedge clk) begin
		m_ce <= 1'b0; dot_ce <= 1'b0; line_start <= 1'b0; frame_start <= 1'b0;
		if (rst) begin acc <= 0; div <= 0; mcount <= 0; dot <= 0; line <= 0; end
		else begin
			if (acc + MASTER_HZ >= CLK_HZ) begin acc <= acc + MASTER_HZ - CLK_HZ; m_ce <= 1'b1; end
			else acc <= acc + MASTER_HZ;
			if (m_ce) begin
				// the line and the frame, in master clocks
				if (mcount == 11'd1364) begin
					mcount <= 11'd0;
					line <= (line == lines - 9'd1) ? 9'd0 : line + 9'd1;
				end else mcount <= mcount + 11'd1;
				// the dot: every 4th, 3rd or 2nd master clock; the first of a line is the line's start
				if (mcount == 11'd1364) begin
					div <= 2'd0; dot_ce <= 1'b1; line_start <= 1'b1; dot <= 10'd0;
					if (line == lines - 9'd1) frame_start <= 1'b1;
				end else if (div == (ctrl[1] ? 2'd1 : ctrl[0] ? 2'd2 : 2'd3)) begin
					div <= 2'd0; dot_ce <= 1'b1; dot <= dot + 10'd1;
				end else div <= div + 2'd1;
			end
		end
	end

	// --- the colours --------------------------------------------------------------------------------
	(* ram_style = "block" *) reg [8:0] ct [0:511];
	reg [8:0] ct_q, ct_cpu;
	reg       idx_en_q;               // (the table takes a clock: the enable goes along with the colour)
	always @(posedge clk) begin
		if (sel && we && a == 3'd5) ct[cta] <= {d[0], ctlo};
		ct_q <= ct[idx];
		ct_cpu <= ct[cta];
	end
	always @(posedge clk) begin
		if (rst) begin ctrl <= 8'd0; cta <= 9'd0; ctlo <= 8'd0; rgb_en <= 1'b0; rgb <= 9'd0; idx_en_q <= 1'b0; end
		else begin
			if (sel && we) case (a)
				3'd0: ctrl <= d;
				3'd2: cta[7:0] <= d;
				3'd3: cta[8] <= d[0];
				3'd4: ctlo <= d;
				3'd5: cta <= cta + 9'd1;
				default: ;
			endcase
			if (sel && rd && a == 3'd5) cta <= cta + 9'd1;
			idx_en_q <= idx_en; rgb <= ct_q; rgb_en <= idx_en_q;
		end
	end
	always @(*) begin
		case (a)
			3'd2: q = cta[7:0];
			3'd3: q = {7'd0, cta[8]};
			3'd4: q = ct_cpu[7:0];
			3'd5: q = {7'h7F, ct_cpu[8]};
			default: q = 8'hFF;
		endcase
	end

endmodule

`default_nettype wire
