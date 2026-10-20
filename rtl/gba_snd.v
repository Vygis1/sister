//////////////////////////////////////////////////////////////////////////////////
// gba_snd - the Game Boy Advance's sound: the Game Boy's four channels and two sample FIFOs.
//
// The four "PSG" channels are the Game Boy's, register for register (SOUND1CNT_L is NR10 and so
// on), so they are gb_apu with its addresses translated. The two Direct Sound channels are 32-byte
// FIFOs of signed 8-bit samples that a timer's overflow pops; when a FIFO is down to half, the
// DMA controller is asked for 16 more bytes. SOUNDCNT_H mixes them: the PSG at 1/4, 1/2 or
// full, each FIFO at half or full, to either side.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none

module gba_snd (
	input  wire        clk,
	input  wire        rst,
	input  wire        tick,               // 16.78 MHz
	// registers 0x04000060-0x9F: a word write with byte enables (taken a byte a clock), a word read
	// (four clocks after rd_req)
	input  wire [6:2]  wr_a,
	input  wire        wr_we,
	input  wire [31:0] wr_d,
	input  wire [3:0]  wr_be,
	input  wire [6:2]  rd_a,
	input  wire        rd_req,
	output reg  [31:0] rd_q,
	output reg         rd_done,
	// the FIFOs: 32-bit words in
	input  wire        fifo_a_we,
	input  wire        fifo_b_we,
	input  wire [31:0] fifo_d,
	input  wire [3:0]  fifo_be,
	// the timers' overflows
	input  wire        tm0_ov,
	input  wire        tm1_ov,
	output reg         dma_a_req,          // pulses: 16 bytes wanted
	output reg         dma_b_req,
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r
);
	// ---- the Game Boy's channels ------------------------------------------------------------------
	// its T cycle is every fourth of ours; the frame sequencer 512 Hz = every 8192 of those
	reg [1:0]  tq; reg [12:0] fsq;
	wire       ce = tick && (tq == 2'd3);
	reg        fs_tick;
	always @(posedge clk) begin
		fs_tick <= 1'b0;
		if (rst) begin tq <= 2'd0; fsq <= 13'd0; end
		else if (tick) begin
			tq <= tq + 2'd1;
			if (tq == 2'd3) begin
				fsq <= fsq + 13'd1;
				if (fsq == 13'd8191) fs_tick <= 1'b1;
			end
		end
	end
	// the register's Game Boy address, or none
	function [6:0] gbreg;
		input [6:0] a;
		case (a)
			7'h60: gbreg = 7'h10; 7'h62: gbreg = 7'h11; 7'h63: gbreg = 7'h12; 7'h64: gbreg = 7'h13; 7'h65: gbreg = 7'h14;
			7'h68: gbreg = 7'h16; 7'h69: gbreg = 7'h17; 7'h6C: gbreg = 7'h18; 7'h6D: gbreg = 7'h19;
			7'h70: gbreg = 7'h1A; 7'h72: gbreg = 7'h1B; 7'h73: gbreg = 7'h1C; 7'h74: gbreg = 7'h1D; 7'h75: gbreg = 7'h1E;
			7'h78: gbreg = 7'h20; 7'h79: gbreg = 7'h21; 7'h7C: gbreg = 7'h22; 7'h7D: gbreg = 7'h23;
			7'h80: gbreg = 7'h24; 7'h81: gbreg = 7'h25; 7'h84: gbreg = 7'h26;
			default: gbreg = (a >= 7'h90 && a < 7'hA0) ? {2'b01, 1'b1, a[3:0]} : 7'h7F;   // wave RAM $30-$3F
		endcase
	endfunction
	// the write queue: one byte a clock
	reg  [3:0]  wq_be; reg [31:0] wq_d; reg [6:2] wq_a;
	reg  [6:0]  reg_a; reg reg_we; reg [7:0] reg_d; reg [7:0] reg_q;
	reg  [2:0]  rd_st;
	always @(posedge clk) begin
		reg_we <= 1'b0; rd_done <= 1'b0;
		if (rst) begin wq_be <= 4'd0; rd_st <= 3'd0; end
		else begin
			if (wr_we) begin wq_be <= wr_be; wq_d <= wr_d; wq_a <= wr_a; end
			else if (wq_be != 4'd0) begin
				reg_we <= 1'b1;
				reg_a <= {wq_a, wq_be[0] ? 2'd0 : wq_be[1] ? 2'd1 : wq_be[2] ? 2'd2 : 2'd3};
				reg_d <= wq_be[0] ? wq_d[7:0] : wq_be[1] ? wq_d[15:8] : wq_be[2] ? wq_d[23:16] : wq_d[31:24];
				wq_be <= wq_be & (wq_be - 4'd1);
			end
			// the read: four bytes, one a clock
			if (rd_req) begin rd_st <= 3'd1; reg_a <= {rd_a, 2'd0}; end
			else if (rd_st != 3'd0) begin
				case (rd_st)
					3'd1: begin rd_q[7:0] <= reg_q; reg_a <= {rd_a, 2'd1}; rd_st <= 3'd2; end
					3'd2: begin rd_q[15:8] <= reg_q; reg_a <= {rd_a, 2'd2}; rd_st <= 3'd3; end
					3'd3: begin rd_q[23:16] <= reg_q; reg_a <= {rd_a, 2'd3}; rd_st <= 3'd4; end
					default: begin rd_q[31:24] <= reg_q; rd_done <= 1'b1; rd_st <= 3'd0; end
				endcase
			end
		end
	end
	wire [6:0] ga = gbreg(reg_a);
	wire       gb_hit = (ga != 7'h7F);
	wire [7:0] gb_q;
	wire signed [15:0] gb_l, gb_r;
	gb_apu #(.GBA(1)) u_apu (
		.clk(clk), .rst(rst), .ce(ce), .fs_tick(fs_tick),
		.reg_a(ga[5:0]), .reg_we(reg_we && gb_hit), .reg_d(reg_d), .reg_q(gb_q),
		.audio_l(gb_l), .audio_r(gb_r)
	);

	// ---- SOUNDCNT_H, the FIFOs ----------------------------------------------------------------------
	reg [15:0] cnt_h;
	reg [15:0] bias;
	reg [7:0]  fa [0:31], fb [0:31];
	reg [5:0]  fa_wp, fa_rp, fb_wp, fb_rp;   // 6 bits: the count is wp - rp
	wire [5:0] fa_n = fa_wp - fa_rp, fb_n = fb_wp - fb_rp;
	reg signed [7:0] sa, sb;               // the current samples
	integer i;
	always @(posedge clk) begin
		dma_a_req <= 1'b0; dma_b_req <= 1'b0;
		if (rst) begin
			cnt_h <= 16'd0; bias <= 16'h0200; fa_wp <= 0; fa_rp <= 0; fb_wp <= 0; fb_rp <= 0; sa <= 0; sb <= 0;
		end else begin
			if (reg_we) begin
				case (reg_a)
					7'h82: cnt_h[7:0] <= reg_d;
					7'h83: begin
						cnt_h[15:8] <= reg_d & 8'h77;
						if (reg_d[3]) begin fa_wp <= 0; fa_rp <= 0; end
						if (reg_d[7]) begin fb_wp <= 0; fb_rp <= 0; end
					end
					7'h88: bias[7:0] <= reg_d;
					7'h89: bias[15:8] <= reg_d;
					default: ;
				endcase
			end
			// bytes in (a word at a time; the bytes the access carried)
			if (fifo_a_we) begin
				for (i = 0; i < 4; i = i + 1) if (fifo_be[i] && fa_n + i < 32) fa[fa_wp[4:0] + i] <= fifo_d[i*8 +: 8];
				fa_wp <= fa_wp + fifo_be[0] + fifo_be[1] + fifo_be[2] + fifo_be[3];
			end
			if (fifo_b_we) begin
				for (i = 0; i < 4; i = i + 1) if (fifo_be[i] && fb_n + i < 32) fb[fb_wp[4:0] + i] <= fifo_d[i*8 +: 8];
				fb_wp <= fb_wp + fifo_be[0] + fifo_be[1] + fifo_be[2] + fifo_be[3];
			end
			// a sample out on the timer
			if (cnt_h[10] ? tm1_ov : tm0_ov) begin
				if (fa_n != 6'd0) begin sa <= fa[fa_rp[4:0]]; fa_rp <= fa_rp + 6'd1; end
				if (fa_n <= 6'd17) dma_a_req <= 1'b1;
			end
			if (cnt_h[14] ? tm1_ov : tm0_ov) begin
				if (fb_n != 6'd0) begin sb <= fb[fb_rp[4:0]]; fb_rp <= fb_rp + 6'd1; end
				if (fb_n <= 6'd17) dma_b_req <= 1'b1;
			end
		end
	end
	always @(*) begin
		case (reg_a)
			7'h82: reg_q = cnt_h[7:0];
			7'h83: reg_q = cnt_h[15:8];
			7'h88: reg_q = bias[7:0];
			7'h89: reg_q = bias[15:8];
			default: reg_q = gb_hit ? gb_q : 8'd0;
		endcase
	end

	// ---- the mix ----------------------------------------------------------------------------------
	// the Game Boy's mix is +-30720 at full volume; a FIFO sample is +-128 and sits in the console's
	// 10-bit output as +-512 at full volume, where the PSG's four channels at full are +-512 too
	wire signed [15:0] psg_l = (cnt_h[1:0] == 2'd0) ? (gb_l >>> 2) : (cnt_h[1:0] == 2'd1) ? (gb_l >>> 1) : gb_l;
	wire signed [15:0] psg_r = (cnt_h[1:0] == 2'd0) ? (gb_r >>> 2) : (cnt_h[1:0] == 2'd1) ? (gb_r >>> 1) : gb_r;
	wire signed [15:0] da = cnt_h[2] ? {sa[7], sa, 7'd0} : {{2{sa[7]}}, sa, 6'd0};     // +-16384 / +-8192
	wire signed [15:0] db = cnt_h[3] ? {sb[7], sb, 7'd0} : {{2{sb[7]}}, sb, 6'd0};
	wire signed [17:0] sum_l = psg_l + (cnt_h[9] ? da : 16'sd0) + (cnt_h[13] ? db : 16'sd0);
	wire signed [17:0] sum_r = psg_r + (cnt_h[8] ? da : 16'sd0) + (cnt_h[12] ? db : 16'sd0);
	assign audio_l = (sum_l > 18'sd32767) ? 16'sd32767 : (sum_l < -18'sd32768) ? -16'sd32768 : sum_l[15:0];
	assign audio_r = (sum_r > 18'sd32767) ? 16'sd32767 : (sum_r < -18'sd32768) ? -16'sd32768 : sum_r[15:0];
endmodule
`default_nettype wire
