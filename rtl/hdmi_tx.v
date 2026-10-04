//////////////////////////////////////////////////////////////////////////////////
// hdmi_tx.v - 640x480 at 60 Hz over TMDS (DVI signalling, which every HDMI display
// takes): the timing, three TMDS encoders and the serialisers.
//
// Timing (VESA DMT, 25.175 MHz nominal; this takes what pclk is, 25.156 MHz from
// the MMCM below is within a monitor's tolerance):
//   horizontal: 640 active, 16 front porch, 96 sync, 48 back porch = 800
//   vertical:   480 active, 10 front porch,  2 sync, 33 back porch = 525
//   both syncs negative.
//
// The source is asked for a pixel a clock ahead: x, y and req (the pixel at x, y is
// wanted on the next clock, in rgb), so a block RAM line buffer can answer it.
//
// Serialising: each 10-bit symbol through an OSERDESE2 master/slave pair in 10:1
// DDR mode, CLKDIV = pclk, CLK = 5 x pclk, bit 0 first; then OBUFDS (the XDC makes
// them TMDS_33). The clocks come from clk50 through one MMCM: VCO 50 x 20.125 =
// 1006.25 MHz, /40 = 25.156 MHz, /8 = 125.78 MHz.
//
// PSEUDO = 1: each wire of a pair is its own single-ended output, + and - driven
// opposite (two serialiser pairs a channel, the second fed the inverted symbols) --
// for a connector whose + and - do not land on a true P/N pair of balls (the QMTECH
// headers pair across their rows; an HDMI breakout puts a pair's + and - in one).
// The XDC makes them LVCMOS33, fast slew.
//
// sym_* are the symbols before the serialisers (for the testbench, and for anything
// that wants to look).
//
// AUDIO = 1: HDMI, not DVI -- 48 kHz stereo L-PCM in data islands, one island in each
// line's blanking: an 8-clock preamble at 644 (CTL0, CTL2), a 2-clock guard band, two
// 32-clock packets, a guard band; the active picture gets its own preamble (CTL0) and
// guard band in the line's last 10 clocks. Packet A carries the audio samples waiting
// (48 kHz is ~1.5 a line; up to 4), or is a null packet; packet B is the AVI InfoFrame
// on line 0 (640x480, VIC 1, RGB), the Audio InfoFrame on line 1 (2 channels), and
// Audio Clock Regeneration otherwise (N 6144, CTS 25000: exact at a 25.000 MHz pixel
// clock and 48 kHz). Data islands are TERC4 coded; channel 0 carries {1, header bit,
// VSYNC, HSYNC}, channels 1 and 2 the four subpackets' even and odd bits, each packet
// part protected by its BCH code (x^8 + x^7 + x^6 + 1, bit 0 first). From the HDMI 1.4
// data island structure, checked against hdl-util/hdmi (MIT/Apache).
// Samples come in from any clock: aud_l/aud_r held, aud_tog toggled at 48 kHz.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module hdmi_tx #(
	parameter SIM = 0,                   // 1: no MMCM/serialisers (pclk comes in on sim_pclk)
	parameter PSEUDO = 1,                // 1: single-ended + and - (see above); 0: OBUFDS
	parameter EXT_CLK = 0,               // 1: the clocks come in (ext_*), from an MMCM already there
	parameter AUDIO = 1,                 // 1: HDMI with audio; 0: DVI
	parameter NULLPK = 0,                // (bring-up) 1: every packet a null packet
	parameter PKMASK = 4'b1111,          // (bring-up) packets sent: [0] audio, [1] ACR, [2] AVI, [3] Audio InfoFrame
	parameter FS441 = 0                  // 1: 44.1 kHz audio (the PlayStation's), else 48 kHz
)(
	input  wire        clk50,
	input  wire        rst,
	input  wire        sim_pclk,
	input  wire        ext_pclk,         // (EXT_CLK) the pixel clock, 5 x it, and their MMCM's lock
	input  wire        ext_pclk5,
	input  wire        ext_locked,
	output wire        pclk,             // the pixel clock, for the source's read side
	// the source: the pixel at (x, y) next clock, while req
	output reg  [9:0]  x,
	output reg  [9:0]  y,
	output reg         req,
	input  wire [23:0] rgb,              // {r, g, b}
	output wire        frame_start,      // a clock at the start of each frame (y wraps to 0)
	// TMDS out: [2:0] = data channels 2 (red), 1 (green), 0 (blue)
	output wire [2:0]  tmds_p,
	output wire [2:0]  tmds_n,
	output wire        tmds_clk_p,
	output wire        tmds_clk_n,
	output wire [9:0]  sym_0, sym_1, sym_2,
	// audio (any clock): a new sample each time aud_tog changes, held in aud_l/aud_r
	input  wire [15:0] aud_l,
	input  wire [15:0] aud_r,
	input  wire        aud_tog
);
	localparam H_ACT = 640, H_FP = 16, H_SYNC = 96, H_BP = 48, H_TOT = 800;
	localparam V_ACT = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33, V_TOT = 525;

	// --- clocks --------------------------------------------------------------------
	wire pclk5, locked;
	generate if (SIM) begin : g_simclk
		assign pclk = sim_pclk; assign pclk5 = 1'b0; assign locked = 1'b1;
	end else if (EXT_CLK) begin : g_ext
		assign pclk = ext_pclk; assign pclk5 = ext_pclk5; assign locked = ext_locked;
	end else begin : g_mmcm
		wire fb, c0, c1;
		MMCME2_BASE #(
			.CLKIN1_PERIOD(20.0), .DIVCLK_DIVIDE(1), .CLKFBOUT_MULT_F(20.125),
			.CLKOUT0_DIVIDE_F(40.0), .CLKOUT1_DIVIDE(8)
		) u_mmcm (
			.CLKIN1(clk50), .CLKFBIN(fb), .CLKFBOUT(fb), .CLKOUT0(c0), .CLKOUT1(c1),
			.LOCKED(locked), .PWRDWN(1'b0), .RST(rst),
			.CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
			.CLKOUT4(), .CLKOUT5(), .CLKOUT6()
		);
		BUFG u_bp (.I(c0), .O(pclk));
		BUFG u_b5 (.I(c1), .O(pclk5));
	end endgenerate
	// reset, held until the MMCM locks, in the pixel clock's domain
	reg [3:0] prst = 4'hF;
	always @(posedge pclk or negedge locked)
		if (!locked) prst <= 4'hF; else prst <= {prst[2:0], 1'b0};
	wire pr = prst[3];

	// --- timing ------------------------------------------------------------------------
	reg  [9:0] hc, vc;
	always @(posedge pclk) begin
		if (pr) begin hc <= 10'd0; vc <= 10'd0; end
		else if (hc == H_TOT - 1) begin
			hc <= 10'd0;
			vc <= (vc == V_TOT - 1) ? 10'd0 : vc + 10'd1;
		end else hc <= hc + 10'd1;
	end
	assign frame_start = !pr && hc == 10'd0 && vc == 10'd0;
	// the request runs a clock ahead of the symbols' de
	always @(posedge pclk) begin
		req <= !pr && hc < H_ACT && vc < V_ACT;
		x <= hc; y <= vc;
	end
	reg de, hs, vs;
	// hd/vd: where the symbols being made now are (de's position: hc two clocks ago)
	reg [9:0] h1, hd, v1, vd;
	always @(posedge pclk) begin
		de <= req;
		hs <= !(hc >= H_ACT + H_FP + 1 && hc < H_ACT + H_FP + H_SYNC + 1);     // (a clock behind hc, as req)
		vs <= !(vc >= V_ACT + V_FP && vc < V_ACT + V_FP + V_SYNC);
		h1 <= hc; hd <= h1; v1 <= vc; vd <= v1;
	end

	// --- the periods (AUDIO): video preamble and guard band, data island ------------------
	wire next_act = (vd == V_TOT - 1) || (vd < V_ACT - 1);           // the next line has a picture
	wire vpre  = AUDIO && next_act && hd >= 10'd790 && hd < 10'd798;
	wire vgb   = AUDIO && next_act && hd >= 10'd798;
	wire dpre  = AUDIO && hd >= 10'd644 && hd < 10'd652;
	wire dgb   = AUDIO && ((hd >= 10'd652 && hd < 10'd654) || (hd >= 10'd718 && hd < 10'd720));
	wire ddat  = AUDIO && hd >= 10'd654 && hd < 10'd718;

	// --- encoders: blue with the syncs on channel 0; the preambles' CTL bits on 1 and 2 ----
	wire [9:0] e0, e1, e2;
	hdmi_tmds u_e0 (.clk(pclk), .de(de), .d(rgb[7:0]),   .c0(hs),           .c1(vs),   .q(e0));
	hdmi_tmds u_e1 (.clk(pclk), .de(de), .d(rgb[15:8]),  .c0(vpre || dpre), .c1(1'b0), .q(e1));
	hdmi_tmds u_e2 (.clk(pclk), .de(de), .d(rgb[23:16]), .c0(dpre),         .c1(1'b0), .q(e2));

	// --- audio in: a toggle per sample from the other clock; the latest sample is taken
	// into an 8-deep queue 48000 times a second counted on THIS clock -- the rate the sink
	// rebuilds from the ACR packets (25 MHz x 6144 / 25000 / 128). Pushing at the source's
	// rate instead, on a clock that drifts against this one, over- or under-runs the queue
	// every few seconds: a click each time.
	reg [2:0] at;  reg [15:0] ql [0:7], qr [0:7];  reg [2:0] qw, qrd;  reg [3:0] qn;
	// (44.1 kHz: 441 a time against 250000 -- 25 MHz / 44100 -- as the ACR says: N 7056,
	// CTS 31250, exact at 25 MHz)
	localparam [17:0] A_ADD = FS441 ? 18'd441 : 18'd48, A_TOP = FS441 ? 18'd250000 : 18'd25000;
	reg [15:0] hl, hr;  reg [17:0] a48;  reg a_new;
	initial begin hl = 16'd0; hr = 16'd0; a48 = 18'd0; a_new = 1'b0; end
	always @(posedge pclk) begin
		at <= {at[1:0], aud_tog};
		if (at[2] != at[1]) begin hl <= aud_l; hr <= aud_r; end
		a_new <= a48 + A_ADD >= A_TOP;
		a48 <= (a48 + A_ADD >= A_TOP) ? a48 + A_ADD - A_TOP : a48 + A_ADD;
	end

	// --- packets ---------------------------------------------------------------------------
	function [7:0] bch; input [55:0] dbits; input integer n; integer i; reg [7:0] e; reg fb; begin
		e = 8'd0;
		for (i = 0; i < 56; i = i + 1) if (i < n) begin
			fb = e[0] ^ dbits[i];
			e = (e >> 1) ^ (fb ? 8'h83 : 8'h00);
		end
		bch = e;
	end endfunction
	function [9:0] terc4; input [3:0] dd; begin
		case (dd)
		4'h0: terc4 = 10'b1010011100; 4'h1: terc4 = 10'b1001100011; 4'h2: terc4 = 10'b1011100100; 4'h3: terc4 = 10'b1011100010;
		4'h4: terc4 = 10'b0101110001; 4'h5: terc4 = 10'b0100011110; 4'h6: terc4 = 10'b0110001110; 4'h7: terc4 = 10'b0100111100;
		4'h8: terc4 = 10'b1011001100; 4'h9: terc4 = 10'b0100111001; 4'hA: terc4 = 10'b0110011100; 4'hB: terc4 = 10'b1011000110;
		4'hC: terc4 = 10'b1010001110; 4'hD: terc4 = 10'b1001110001; 4'hE: terc4 = 10'b0101100011; default: terc4 = 10'b1011000011;
		endcase
	end endfunction
	// a sample subpacket: L and R (16 bits, in the top of 24), SB6 = {PR CR UR VR PL CL UL VL}
	// (V = 0: valid; U = 0; P: even parity over the sample, V, U and C)
	function [55:0] smp; input [15:0] l, r; input csl, csr; reg pl, pr2; begin
		pl = ^{l, csl}; pr2 = ^{r, csr};
		smp = {pr2, csr, 1'b0, 1'b0, pl, csl, 1'b0, 1'b0, r, 8'd0, l, 8'd0};
	end endfunction
	// the two packets of this line's island, made the clock before it starts
	reg [31:0] hdr0, hdr1;                // {ECC, HB2, HB1, HB0}
	reg [63:0] s00, s01, s02, s03, s10, s11, s12, s13;   // {ECC, SB6 .. SB0}
	reg [7:0]  fc;                        // the frame (sample) count in the 192-frame channel-status block
	// (whole packets of four, as hdl-util/hdmi sends them)
	wire [3:0] take = (qn >= 4'd4) ? 4'd4 : 4'd0;
	// a channel's status bit for frame f: copying permitted (2), channel 1 left / 2 right (20/21),
	// 48 kHz (25), 16-bit words (33)
	function cst; input [7:0] f; input right; begin
		cst = f == 8'd2 || (f == 8'd25 && !FS441) || f == 8'd33 || f == (right ? 8'd21 : 8'd20);   // (44.1 kHz: bits 24-27 0000)
	end endfunction
	// the frame count of each sample in the packet, and its channel-status bits (as wires:
	// a function call inside another's arguments simulates wrong in xsim)
	wire [7:0]  fc1 = (fc == 8'd191) ? 8'd0 : fc + 8'd1;
	wire [7:0]  fc2 = (fc1 == 8'd191) ? 8'd0 : fc1 + 8'd1;
	wire [7:0]  fc3 = (fc2 == 8'd191) ? 8'd0 : fc2 + 8'd1;
	wire [7:0]  fc4 = (fc3 == 8'd191) ? 8'd0 : fc3 + 8'd1;
	wire        csl_fc = cst(fc, 1'b0), csr_fc = cst(fc, 1'b1);
	wire        csl_fc1 = cst(fc1, 1'b0), csr_fc1 = cst(fc1, 1'b1);
	wire        csl_fc2 = cst(fc2, 1'b0), csr_fc2 = cst(fc2, 1'b1);
	wire        csl_fc3 = cst(fc3, 1'b0), csr_fc3 = cst(fc3, 1'b1);
	// the subpackets of packet A: sample i if it is there
	wire [55:0] sa0 = (take > 4'd0) ? smp(ql[qrd],        qr[qrd],        csl_fc, csr_fc) : 56'd0;
	wire [55:0] sa1 = (take > 4'd1) ? smp(ql[qrd + 3'd1], qr[qrd + 3'd1], csl_fc1, csr_fc1) : 56'd0;
	wire [55:0] sa2 = (take > 4'd2) ? smp(ql[qrd + 3'd2], qr[qrd + 3'd2], csl_fc2, csr_fc2) : 56'd0;
	wire [55:0] sa3 = (take > 4'd3) ? smp(ql[qrd + 3'd3], qr[qrd + 3'd3], csl_fc3, csr_fc3) : 56'd0;
	wire [3:0]  present = (take == 4'd0) ? 4'b0000 : (take == 4'd1) ? 4'b0001 : (take == 4'd2) ? 4'b0011 : (take == 4'd3) ? 4'b0111 : 4'b1111;
	wire [3:0]  bflag = present & {fc3 == 8'd0, fc2 == 8'd0, fc1 == 8'd0, fc == 8'd0};
	wire [23:0] ha = (take != 4'd0) ? {bflag, 4'd0, 3'd0, 1'b0, present, 8'h02} : 24'd0;
	wire [7:0]  fcn = (take == 4'd0) ? fc : (take == 4'd1) ? fc1 : (take == 4'd2) ? fc2 : (take == 4'd3) ? fc3 : fc4;
	// packet B: AVI InfoFrame {PB6..PB0} = {0, 0, VIC 1, 0, M 4:3 R same, RGB, checksum};
	// Audio InfoFrame {.., PB1 2 channels, checksum}; or clock regeneration {N, CTS, 0}
	wire [55:0] avi = {8'h00, 8'h00, 8'h01, 8'h00, 8'h18, 8'h00, 8'h56};   // (PB0: 0x82+0x02+0x0D+0x18+0x01 = 0xAA, -0xAA = 0x56)
	wire [55:0] aif = {8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h70};
	wire [55:0] acr = FS441 ? {8'h90, 8'h1B, 8'h00, 8'h12, 8'h7A, 8'h00, 8'h00}    // N 7056, CTS 31250
	                        : {8'h00, 8'h18, 8'h00, 8'hA8, 8'h61, 8'h00, 8'h00};   // N 6144, CTS 25000
	// (clock regeneration on every 32nd line, ~980 a second as hdl-util/hdmi sends it -- not
	// every line; a null packet on the others)
	wire        acr_line = vd[4:0] == 5'd2;
	wire [23:0] hb  = (vd == 10'd0) ? 24'h0D0282 : (vd == 10'd1) ? 24'h0A0184 : acr_line ? 24'h000001 : 24'h000000;
	wire [55:0] b0  = (vd == 10'd0) ? avi : (vd == 10'd1) ? aif : acr_line ? acr : 56'd0;
	wire [55:0] b1  = (vd > 10'd1 && acr_line) ? acr : 56'd0;
	always @(posedge pclk) begin
		if (pr) begin qw <= 3'd0; qrd <= 3'd0; qn <= 4'd0; fc <= 8'd0; end
		else begin
			if (a_new && qn != 4'd8) begin ql[qw] <= hl; qr[qw] <= hr; qw <= qw + 3'd1; end
			if (AUDIO && hd == 10'd653) begin
				s00 <= {bch(sa0, 56), sa0}; s01 <= {bch(sa1, 56), sa1}; s02 <= {bch(sa2, 56), sa2}; s03 <= {bch(sa3, 56), sa3};
				hdr0 <= (NULLPK || !PKMASK[0]) ? 32'd0 : {bch({32'd0, ha}, 24), ha};
				fc <= fcn; qrd <= qrd + take[2:0];
				s10 <= {bch(b0, 56), b0}; s11 <= {bch(b1, 56), b1}; s12 <= {bch(b1, 56), b1}; s13 <= {bch(b1, 56), b1};
				hdr1 <= (NULLPK || (vd == 10'd0 ? !PKMASK[2] : vd == 10'd1 ? !PKMASK[3] : !PKMASK[1])) ? 32'd0 : {bch({32'd0, hb}, 24), hb};
			end
			qn <= qn + {3'd0, a_new && qn != 4'd8} - ((AUDIO && hd == 10'd653) ? take : 4'd0);
		end
	end

	// --- the island's and guard bands' symbols, a clock behind like the encoders' ------------
	wire [4:0]  kk = hd[4:0] - 5'd14;                        // the clock in the packet (654 = 20 x 32 + 14)
	wire        pk = hd >= 10'd686;
	wire [31:0] hh = pk ? hdr1 : hdr0;
	wire [63:0] q0 = pk ? s10 : s00, q1 = pk ? s11 : s01, q2 = pk ? s12 : s02, q3 = pk ? s13 : s03;
	reg  [9:0]  t0, t1, t2;  reg tsel;
	initial begin t0 = 10'd0; t1 = 10'd0; t2 = 10'd0; tsel = 1'b0; hdr0 = 32'd0; hdr1 = 32'd0;
		s00 = 64'd0; s01 = 64'd0; s02 = 64'd0; s03 = 64'd0; s10 = 64'd0; s11 = 64'd0; s12 = 64'd0; s13 = 64'd0; end
	always @(posedge pclk) begin
		tsel <= vgb || dgb || ddat;
		if (vgb) begin t0 <= 10'b1011001100; t1 <= 10'b0100110011; t2 <= 10'b1011001100; end
		else if (dgb) begin t0 <= terc4({2'b11, vs, hs}); t1 <= 10'b0100110011; t2 <= 10'b0100110011; end
		else begin
			t0 <= terc4({1'b1, hh[kk], vs, hs});
			t1 <= terc4({q3[{kk, 1'b0}], q2[{kk, 1'b0}], q1[{kk, 1'b0}], q0[{kk, 1'b0}]});
			t2 <= terc4({q3[{kk, 1'b1}], q2[{kk, 1'b1}], q1[{kk, 1'b1}], q0[{kk, 1'b1}]});
		end
	end
	assign sym_0 = tsel ? t0 : e0;
	assign sym_1 = tsel ? t1 : e1;
	assign sym_2 = tsel ? t2 : e2;

	// --- serialisers -----------------------------------------------------------------
	generate if (!SIM && PSEUDO) begin : g_ser
		// Single-ended: a 10:1 OSERDESE2 is two cascaded, the second in the OLOGIC of the
		// ball's differential partner -- here another HDMI pin, so the cascades collide.
		// Instead each pin has an ODDR (in its own OLOGIC) fed two bits a 5x clock from a
		// 10-bit shift register, loaded with the symbol once a pixel clock (the pixel
		// clock's toggle, seen from the 5x clock, says when: they come from one MMCM).
		wire [9:0] syms [0:3];
		assign syms[0] = sym_0; assign syms[1] = sym_1; assign syms[2] = sym_2;
		assign syms[3] = 10'b0000011111;                // the clock channel: one pixel clock period
		reg  ptog = 1'b0;
		always @(posedge pclk) ptog <= ~ptog;
		reg  [2:0] t5;                                   // ptog as the 5x clock saw it, three clocks
		always @(posedge pclk5) t5 <= {t5[1:0], ptog};
		wire load = t5[2] != t5[1];
		genvar ch, pol;
		for (ch = 0; ch < 4; ch = ch + 1) begin : g_ch
		for (pol = 0; pol < 2; pol = pol + 1) begin : g_pol
			reg  [9:0] sh;
			always @(posedge pclk5) sh <= load ? (pol ? ~syms[ch] : syms[ch]) : {2'b00, sh[9:2]};
			wire ser;
			ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC")) u_oddr (
				.Q(ser), .C(pclk5), .CE(1'b1), .D1(sh[0]), .D2(sh[1]), .R(1'b0), .S(1'b0));
			if (ch < 3 && pol == 0) begin : g_dp OBUF u_ob (.I(ser), .O(tmds_p[ch])); end
			if (ch < 3 && pol == 1) begin : g_dn OBUF u_ob (.I(ser), .O(tmds_n[ch])); end
			if (ch == 3 && pol == 0) begin : g_cp OBUF u_ob (.I(ser), .O(tmds_clk_p)); end
			if (ch == 3 && pol == 1) begin : g_cn OBUF u_ob (.I(ser), .O(tmds_clk_n)); end
		end
		end
	end else if (!SIM) begin : g_ser
		wire [9:0] syms [0:3];
		assign syms[0] = sym_0; assign syms[1] = sym_1; assign syms[2] = sym_2;
		assign syms[3] = 10'b0000011111;                // the clock channel: one pixel clock period
		genvar ch, pol;
		for (ch = 0; ch < 4; ch = ch + 1) begin : g_ch
		for (pol = 0; pol < (PSEUDO ? 2 : 1); pol = pol + 1) begin : g_pol
			wire s1, s2, ser;
			wire [9:0] sy = pol ? ~syms[ch] : syms[ch];
			OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10), .SERDES_MODE("MASTER"),
			            .TRISTATE_WIDTH(1)) u_m (
				.OQ(ser), .OFB(), .TQ(), .TFB(), .SHIFTOUT1(), .SHIFTOUT2(), .TBYTEOUT(),
				.CLK(pclk5), .CLKDIV(pclk),
				.D1(sy[0]), .D2(sy[1]), .D3(sy[2]), .D4(sy[3]),
				.D5(sy[4]), .D6(sy[5]), .D7(sy[6]), .D8(sy[7]),
				.OCE(1'b1), .RST(pr), .SHIFTIN1(s1), .SHIFTIN2(s2),
				.T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
			);
			OSERDESE2 #(.DATA_RATE_OQ("DDR"), .DATA_RATE_TQ("SDR"), .DATA_WIDTH(10), .SERDES_MODE("SLAVE"),
			            .TRISTATE_WIDTH(1)) u_s (
				.OQ(), .OFB(), .TQ(), .TFB(), .SHIFTOUT1(s1), .SHIFTOUT2(s2), .TBYTEOUT(),
				.CLK(pclk5), .CLKDIV(pclk),
				.D1(1'b0), .D2(1'b0), .D3(sy[8]), .D4(sy[9]),
				.D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
				.OCE(1'b1), .RST(pr), .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
				.T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0), .TBYTEIN(1'b0), .TCE(1'b0)
			);
			if (PSEUDO) begin : g_se
				if (ch < 3 && pol == 0) begin : g_dp OBUF u_ob (.I(ser), .O(tmds_p[ch])); end
				if (ch < 3 && pol == 1) begin : g_dn OBUF u_ob (.I(ser), .O(tmds_n[ch])); end
				if (ch == 3 && pol == 0) begin : g_cp OBUF u_ob (.I(ser), .O(tmds_clk_p)); end
				if (ch == 3 && pol == 1) begin : g_cn OBUF u_ob (.I(ser), .O(tmds_clk_n)); end
			end else begin : g_df
				if (ch < 3) begin : g_d
					OBUFDS u_ob (.I(ser), .O(tmds_p[ch]), .OB(tmds_n[ch]));
				end else begin : g_c
					OBUFDS u_ob (.I(ser), .O(tmds_clk_p), .OB(tmds_clk_n));
				end
			end
		end
		end
	end else begin : g_noser
		assign tmds_p = 3'b000; assign tmds_n = 3'b111; assign tmds_clk_p = 1'b0; assign tmds_clk_n = 1'b1;
	end endgenerate
endmodule

`default_nettype wire
