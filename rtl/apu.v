//////////////////////////////////////////////////////////////////////////////////
// apu.v - the 2A03's sound half.
//
// Five voices, all of them integer dividers rather than anything resembling an
// oscillator: two pulses, a triangle, a noise channel and a one-bit delta
// player. What makes them sound like a NES is not the waveforms -- those are
// trivial -- but the machinery bolted to each one: a length counter that stops
// a note, an envelope that decays it, a sweep that bends a pulse's pitch. Games
// drive all of it from a table, so a channel with the right waveform and the
// wrong length counter plays the right note forever.
//
// Everything is clocked from `cpu_ce`, one pulse per emulated CPU cycle. The
// pulse and noise dividers run at half that; the triangle runs at the full
// rate, which is why it reaches an octave lower for the same period value and
// ends up being the bass line in nearly every NES soundtrack.
//
// The frame counter is the odd one out: it is not audio, it is a ~240 Hz
// sequencer that ticks the envelopes and length counters, and it can interrupt
// the CPU. Games use it as a timer even when they are not making a sound.
//
// Everything lives in ONE clocked block on purpose. Envelopes are written both
// by the CPU (a note starts) and by the frame counter (a note decays), and
// splitting those across two blocks makes the register multi-driven -- which
// synthesis rejects outright and simulation quietly tolerates, so it would
// have worked here and failed on the board.
//
// One honest inaccuracy: this board runs the console about 3.5% fast (the clock
// enable is 50 MHz / 9 against a real 5.369 MHz), so everything is slightly
// sharp. That is a property of the clock, not of this file.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module apu (
	input  wire        clk,
	input  wire        rst,
	input  wire        cpu_ce,        // one emulated CPU cycle

	// CPU side: $4000-$4017
	input  wire [4:0]  addr,
	input  wire [7:0]  din,
	input  wire        we,
	input  wire        rd_status,     // a real read of $4015, side effects and all
	output wire [7:0]  status,
	output wire        irq,

	// The delta player steals a CPU cycle to read the cartridge.
	output wire [15:0] dmc_addr,
	input  wire [7:0]  dmc_data,
	output reg         dmc_req,
	input  wire        dmc_ack,

	output wire [15:0] sample         // unsigned, 0x8000 is silence
);

	// --- tables that are tables on the die too ---------------------------------
	function [7:0] length_of;
		input [4:0] i;
		case (i)
		5'd0:  length_of = 8'd10;   5'd1:  length_of = 8'd254;
		5'd2:  length_of = 8'd20;   5'd3:  length_of = 8'd2;
		5'd4:  length_of = 8'd40;   5'd5:  length_of = 8'd4;
		5'd6:  length_of = 8'd80;   5'd7:  length_of = 8'd6;
		5'd8:  length_of = 8'd160;  5'd9:  length_of = 8'd8;
		5'd10: length_of = 8'd60;   5'd11: length_of = 8'd10;
		5'd12: length_of = 8'd14;   5'd13: length_of = 8'd12;
		5'd14: length_of = 8'd26;   5'd15: length_of = 8'd14;
		5'd16: length_of = 8'd12;   5'd17: length_of = 8'd16;
		5'd18: length_of = 8'd24;   5'd19: length_of = 8'd18;
		5'd20: length_of = 8'd48;   5'd21: length_of = 8'd20;
		5'd22: length_of = 8'd96;   5'd23: length_of = 8'd22;
		5'd24: length_of = 8'd192;  5'd25: length_of = 8'd24;
		5'd26: length_of = 8'd72;   5'd27: length_of = 8'd26;
		5'd28: length_of = 8'd16;   5'd29: length_of = 8'd28;
		5'd30: length_of = 8'd32;   default: length_of = 8'd30;
		endcase
	endfunction

	function [11:0] noise_period;
		input [3:0] i;
		case (i)
		4'd0:  noise_period = 12'd4;    4'd1:  noise_period = 12'd8;
		4'd2:  noise_period = 12'd16;   4'd3:  noise_period = 12'd32;
		4'd4:  noise_period = 12'd64;   4'd5:  noise_period = 12'd96;
		4'd6:  noise_period = 12'd128;  4'd7:  noise_period = 12'd160;
		4'd8:  noise_period = 12'd202;  4'd9:  noise_period = 12'd254;
		4'd10: noise_period = 12'd380;  4'd11: noise_period = 12'd508;
		4'd12: noise_period = 12'd762;  4'd13: noise_period = 12'd1016;
		4'd14: noise_period = 12'd2034; default: noise_period = 12'd4068;
		endcase
	endfunction

	function [8:0] dmc_period;
		input [3:0] i;
		case (i)
		4'd0:  dmc_period = 9'd428;  4'd1:  dmc_period = 9'd380;
		4'd2:  dmc_period = 9'd340;  4'd3:  dmc_period = 9'd320;
		4'd4:  dmc_period = 9'd286;  4'd5:  dmc_period = 9'd254;
		4'd6:  dmc_period = 9'd226;  4'd7:  dmc_period = 9'd214;
		4'd8:  dmc_period = 9'd190;  4'd9:  dmc_period = 9'd160;
		4'd10: dmc_period = 9'd142;  4'd11: dmc_period = 9'd128;
		4'd12: dmc_period = 9'd106;  4'd13: dmc_period = 9'd84;
		4'd14: dmc_period = 9'd72;   default: dmc_period = 9'd54;
		endcase
	endfunction

	function duty_bit;
		input [1:0] d;
		input [2:0] s;
		case (d)
		2'd0: duty_bit = (s == 3'd1);                       // 12.5%
		2'd1: duty_bit = (s == 3'd1) || (s == 3'd2);        // 25%
		2'd2: duty_bit = (s >= 3'd1) && (s <= 3'd4);        // 50%
		default: duty_bit = !((s == 3'd1) || (s == 3'd2));  // 25% inverted
		endcase
	endfunction

	// --- state -------------------------------------------------------------------
	reg        fc_mode, fc_inhibit;
	reg [14:0] fc_count;
	reg        frame_irq, quarter, half;
	reg        apu_phase;

	// Envelope, shared by the two pulses (0, 1) and the noise channel (2).
	reg [3:0]  env_div   [0:2];
	reg [3:0]  env_vol   [0:2];
	reg        env_start [0:2];
	reg [3:0]  env_period[0:2];      // doubles as the constant volume
	reg        env_loop  [0:2];
	reg        env_const [0:2];

	reg [1:0]  duty      [0:1];
	reg [10:0] pul_per   [0:1];
	reg [10:0] pul_tmr   [0:1];
	reg [2:0]  pul_step  [0:1];
	reg [7:0]  pul_len   [0:1];
	reg        pul_en    [0:1];
	reg        swp_en    [0:1];
	reg [2:0]  swp_per   [0:1];
	reg        swp_neg   [0:1];
	reg [2:0]  swp_shift [0:1];
	reg [2:0]  swp_div   [0:1];
	reg        swp_start [0:1];

	reg [10:0] tri_per, tri_tmr;
	reg [4:0]  tri_step;
	reg [7:0]  tri_len;
	reg [6:0]  tri_lin, tri_lin_reload;
	reg        tri_ctrl, tri_reload, tri_en;

	reg [11:0] noi_tmr;
	reg [3:0]  noi_idx;
	reg        noi_mode;
	reg [14:0] lfsr;
	reg [7:0]  noi_len;
	reg        noi_en;

	reg        dmc_irq_en, dmc_loop, dmc_irq, dmc_have, dmc_silent;
	reg        dmc_ack_q;
	reg [3:0]  dmc_rate, dmc_bits;
	reg [8:0]  dmc_tmr;
	reg [6:0]  dmc_dac;
	reg [14:0] dmc_start, dmc_cur;
	reg [11:0] dmc_len, dmc_left;
	reg [7:0]  dmc_shift, dmc_buf;

	assign dmc_addr = {1'b1, dmc_cur};     // samples always live in $8000-$FFFF

	// --- the sweep's target ------------------------------------------------------
	// Computed even when the sweep is switched off: a channel whose target has
	// run past the top of the range is silenced either way.
	function [11:0] sweep_target;
		input [10:0] period;
		input [2:0]  shift;
		input        negate;
		input        ones_comp;         // pulse 1 subtracts one extra
		reg   [10:0] change;
		begin
			change = period >> shift;
			if (negate)
				sweep_target = ones_comp ? ({1'b0, period} - {1'b0, change} - 12'd1)
				                         : ({1'b0, period} - {1'b0, change});
			else
				sweep_target = {1'b0, period} + {1'b0, change};
		end
	endfunction

	wire [11:0] tgt0 = sweep_target(pul_per[0], swp_shift[0], swp_neg[0], 1'b1);
	wire [11:0] tgt1 = sweep_target(pul_per[1], swp_shift[1], swp_neg[1], 1'b0);

	// Below eight, the divider is too short for the sequencer to make a waveform.
	wire mute0 = (pul_per[0] < 11'd8) || tgt0[11];
	wire mute1 = (pul_per[1] < 11'd8) || tgt1[11];

	wire [14:0] fc_last = fc_mode ? 15'd18640 : 15'd14914;
	wire        pidx    = addr[2];       // $4000/$4004 pick pulse 0 or 1

	integer i;

	always @(posedge clk) begin
		if (rst) begin
			fc_mode <= 1'b0; fc_inhibit <= 1'b0; fc_count <= 15'd0;
			frame_irq <= 1'b0; quarter <= 1'b0; half <= 1'b0; apu_phase <= 1'b0;
			for (i = 0; i < 3; i = i + 1) begin
				env_div[i] <= 4'd0; env_vol[i] <= 4'd0; env_start[i] <= 1'b0;
				env_period[i] <= 4'd0; env_loop[i] <= 1'b0; env_const[i] <= 1'b0;
			end
			for (i = 0; i < 2; i = i + 1) begin
				duty[i] <= 2'd0; pul_per[i] <= 11'd0; pul_tmr[i] <= 11'd0;
				pul_step[i] <= 3'd0; pul_len[i] <= 8'd0; pul_en[i] <= 1'b0;
				swp_en[i] <= 1'b0; swp_per[i] <= 3'd0; swp_neg[i] <= 1'b0;
				swp_shift[i] <= 3'd0; swp_div[i] <= 3'd0; swp_start[i] <= 1'b0;
			end
			tri_per <= 11'd0; tri_tmr <= 11'd0; tri_step <= 5'd0; tri_len <= 8'd0;
			tri_lin <= 7'd0; tri_lin_reload <= 7'd0; tri_ctrl <= 1'b0;
			tri_reload <= 1'b0; tri_en <= 1'b0;
			noi_tmr <= 12'd4; noi_idx <= 4'd0; noi_mode <= 1'b0;
			lfsr <= 15'd1;                       // a zero LFSR would never move
			noi_len <= 8'd0; noi_en <= 1'b0;
			dmc_irq_en <= 1'b0; dmc_loop <= 1'b0; dmc_irq <= 1'b0; dmc_rate <= 4'd0;
			dmc_tmr <= 9'd428; dmc_dac <= 7'd0; dmc_start <= 15'd0; dmc_len <= 12'd0;
			dmc_cur <= 15'd0; dmc_left <= 12'd0; dmc_shift <= 8'd0; dmc_bits <= 4'd0;
			dmc_have <= 1'b0; dmc_buf <= 8'd0; dmc_silent <= 1'b1; dmc_req <= 1'b0;
			dmc_ack_q <= 1'b0;
		end else begin
			quarter <= 1'b0;
			half    <= 1'b0;

			// ---- the frame sequencer -------------------------------------------
			// Boundaries are not evenly spaced, because the real divider is not.
			if (cpu_ce) begin
				fc_count <= (fc_count >= fc_last) ? 15'd0 : fc_count + 15'd1;
				case (fc_count)
				15'd3728:  quarter <= 1'b1;
				15'd7456:  begin quarter <= 1'b1; half <= 1'b1; end
				15'd11185: quarter <= 1'b1;
				15'd14914: if (!fc_mode) begin
						quarter <= 1'b1; half <= 1'b1;
						if (!fc_inhibit) frame_irq <= 1'b1;
					end
				15'd18640: if (fc_mode) begin quarter <= 1'b1; half <= 1'b1; end
				default: ;
				endcase
			end

			// ---- quarter frame: envelopes and the triangle's linear counter -----
			if (quarter) begin
				for (i = 0; i < 3; i = i + 1) begin
					if (env_start[i]) begin
						env_start[i] <= 1'b0;
						env_vol[i]   <= 4'd15;
						env_div[i]   <= env_period[i];
					end else if (env_div[i] == 4'd0) begin
						env_div[i] <= env_period[i];
						if (env_vol[i] != 4'd0) env_vol[i] <= env_vol[i] - 4'd1;
						else if (env_loop[i])   env_vol[i] <= 4'd15;
					end else begin
						env_div[i] <= env_div[i] - 4'd1;
					end
				end

				if (tri_reload)           tri_lin <= tri_lin_reload;
				else if (tri_lin != 7'd0) tri_lin <= tri_lin - 7'd1;
				if (!tri_ctrl)            tri_reload <= 1'b0;
			end

			// ---- half frame: length counters and the sweeps ---------------------
			if (half) begin
				for (i = 0; i < 2; i = i + 1)
					if (pul_len[i] != 8'd0 && !env_loop[i])
						pul_len[i] <= pul_len[i] - 8'd1;
				if (tri_len != 8'd0 && !tri_ctrl)    tri_len <= tri_len - 8'd1;
				if (noi_len != 8'd0 && !env_loop[2]) noi_len <= noi_len - 8'd1;

				if (swp_div[0] == 3'd0 && swp_en[0] && swp_shift[0] != 3'd0 && !mute0)
					pul_per[0] <= tgt0[10:0];
				if (swp_div[0] == 3'd0 || swp_start[0]) begin
					swp_div[0] <= swp_per[0]; swp_start[0] <= 1'b0;
				end else swp_div[0] <= swp_div[0] - 3'd1;

				if (swp_div[1] == 3'd0 && swp_en[1] && swp_shift[1] != 3'd0 && !mute1)
					pul_per[1] <= tgt1[10:0];
				if (swp_div[1] == 3'd0 || swp_start[1]) begin
					swp_div[1] <= swp_per[1]; swp_start[1] <= 1'b0;
				end else swp_div[1] <= swp_div[1] - 3'd1;
			end

			// ---- timers ----------------------------------------------------------
			if (cpu_ce) begin
				apu_phase <= ~apu_phase;

				if (apu_phase) begin
					for (i = 0; i < 2; i = i + 1) begin
						if (pul_tmr[i] == 11'd0) begin
							pul_tmr[i]  <= pul_per[i];
							pul_step[i] <= pul_step[i] + 3'd1;
						end else pul_tmr[i] <= pul_tmr[i] - 11'd1;
					end

					if (noi_tmr == 12'd0) begin
						noi_tmr <= noise_period(noi_idx);
						// Tapping bit 6 instead of bit 1 shortens the sequence
						// from 32767 steps to 93 -- the difference between hiss
						// and a metallic buzz.
						lfsr <= {lfsr[0] ^ (noi_mode ? lfsr[6] : lfsr[1]), lfsr[14:1]};
					end else noi_tmr <= noi_tmr - 12'd1;
				end

				if (tri_tmr == 11'd0) begin
					tri_tmr <= tri_per;
					// Silenced by holding the sequence still rather than by
					// muting the output: stopping mid-step would click.
					if (tri_len != 8'd0 && tri_lin != 7'd0 && tri_per >= 11'd2)
						tri_step <= tri_step + 5'd1;
				end else tri_tmr <= tri_tmr - 11'd1;

				// ---- the delta player -------------------------------------------
				if (dmc_tmr == 9'd0) begin
					dmc_tmr <= dmc_period(dmc_rate);
					if (!dmc_silent) begin
						// Each bit nudges the DAC by two, and it saturates at both
						// ends rather than wrapping round.
						if (dmc_shift[0]) begin
							if (dmc_dac <= 7'd125) dmc_dac <= dmc_dac + 7'd2;
						end else begin
							if (dmc_dac >= 7'd2)   dmc_dac <= dmc_dac - 7'd2;
						end
					end
					dmc_shift <= {1'b0, dmc_shift[7:1]};
					if (dmc_bits == 4'd7) begin
						dmc_bits <= 4'd0;
						if (dmc_have) begin
							dmc_shift  <= dmc_buf;
							dmc_silent <= 1'b0;
							dmc_have   <= 1'b0;
						end else dmc_silent <= 1'b1;
					end else dmc_bits <= dmc_bits + 4'd1;
				end else dmc_tmr <= dmc_tmr - 9'd1;

				if (!dmc_have && !dmc_req && dmc_left != 12'd0) dmc_req <= 1'b1;
			end

			// On the EDGE of the acknowledge, not the level. The caller holds it
			// for as long as its own bus cycle lasts -- twenty-seven clocks in
			// this console -- and advancing once per clock would tear through
			// the sample many times too fast. Taking the edge here means the
			// caller cannot get it wrong.
			dmc_ack_q <= dmc_ack;
			if (dmc_ack && !dmc_ack_q) begin
				dmc_buf  <= dmc_data;
				dmc_have <= 1'b1;
				dmc_req  <= 1'b0;
				dmc_cur  <= dmc_cur + 15'd1;
				if (dmc_left == 12'd1) begin
					if (dmc_loop) begin
						dmc_cur <= dmc_start; dmc_left <= dmc_len;
					end else begin
						dmc_left <= 12'd0;
						if (dmc_irq_en) dmc_irq <= 1'b1;
					end
				end else dmc_left <= dmc_left - 12'd1;
			end

			// ---- register writes, last so a write beats a sequencer tick --------
			if (we) begin
				case (addr)
				5'h00, 5'h04: begin
					duty[pidx]       <= din[7:6];
					env_loop[pidx]   <= din[5];
					env_const[pidx]  <= din[4];
					env_period[pidx] <= din[3:0];
				end
				5'h01, 5'h05: begin
					swp_en[pidx]    <= din[7];
					swp_per[pidx]   <= din[6:4];
					swp_neg[pidx]   <= din[3];
					swp_shift[pidx] <= din[2:0];
					swp_start[pidx] <= 1'b1;
				end
				5'h02, 5'h06: pul_per[pidx][7:0] <= din;
				5'h03, 5'h07: begin
					pul_per[pidx][10:8] <= din[2:0];
					// Starting a note: reload the length, restart the envelope
					// and begin the waveform at the top of its cycle.
					if (pul_en[pidx]) pul_len[pidx] <= length_of(din[7:3]);
					pul_step[pidx]  <= 3'd0;
					env_start[pidx] <= 1'b1;
				end

				5'h08: begin tri_ctrl <= din[7]; tri_lin_reload <= din[6:0]; end
				5'h0A: tri_per[7:0] <= din;
				5'h0B: begin
					tri_per[10:8] <= din[2:0];
					if (tri_en) tri_len <= length_of(din[7:3]);
					tri_reload <= 1'b1;
				end

				5'h0C: begin
					env_loop[2]   <= din[5];
					env_const[2]  <= din[4];
					env_period[2] <= din[3:0];
				end
				5'h0E: begin noi_mode <= din[7]; noi_idx <= din[3:0]; end
				5'h0F: begin
					if (noi_en) noi_len <= length_of(din[7:3]);
					env_start[2] <= 1'b1;
				end

				5'h10: begin
					dmc_irq_en <= din[7];
					dmc_loop   <= din[6];
					dmc_rate   <= din[3:0];
					if (!din[7]) dmc_irq <= 1'b0;
				end
				5'h11: dmc_dac   <= din[6:0];
				// $C000 + n*64, held as an offset from $8000.
				5'h12: dmc_start <= {1'b1, din, 6'd0};
				5'h13: dmc_len   <= {din, 4'd0} + 12'd1;

				5'h15: begin
					pul_en[0] <= din[0]; if (!din[0]) pul_len[0] <= 8'd0;
					pul_en[1] <= din[1]; if (!din[1]) pul_len[1] <= 8'd0;
					tri_en    <= din[2]; if (!din[2]) tri_len    <= 8'd0;
					noi_en    <= din[3]; if (!din[3]) noi_len    <= 8'd0;
					if (!din[4]) dmc_left <= 12'd0;
					else if (dmc_left == 12'd0) begin
						dmc_cur <= dmc_start; dmc_left <= dmc_len;
					end
					dmc_irq <= 1'b0;
				end

				5'h17: begin
					fc_mode    <= din[7];
					fc_inhibit <= din[6];
					fc_count   <= 15'd0;
					if (din[6]) frame_irq <= 1'b0;
					// Selecting the five-step mode clocks everything at once.
					if (din[7]) begin quarter <= 1'b1; half <= 1'b1; end
				end
				default: ;
				endcase
			end

			// Reading $4015 acknowledges the frame interrupt -- a side effect of a
			// real read, so it comes in separately from the read mux.
			if (rd_status) frame_irq <= 1'b0;
		end
	end

	// --- what each voice is worth right now ---------------------------------------
	wire [3:0] vol0 = env_const[0] ? env_period[0] : env_vol[0];
	wire [3:0] vol1 = env_const[1] ? env_period[1] : env_vol[1];
	wire [3:0] voln = env_const[2] ? env_period[2] : env_vol[2];

	wire [3:0] out0 = (pul_len[0] != 8'd0 && !mute0 && duty_bit(duty[0], pul_step[0]))
	                  ? vol0 : 4'd0;
	wire [3:0] out1 = (pul_len[1] != 8'd0 && !mute1 && duty_bit(duty[1], pul_step[1]))
	                  ? vol1 : 4'd0;

	// The triangle has no volume control at all: a fixed 4-bit ramp up and back
	// down, 32 steps.
	wire [3:0] outt = tri_step[4] ? tri_step[3:0] : (4'd15 - tri_step[3:0]);

	// The LFSR's low bit is inverted -- a set bit means silence.
	wire [3:0] outn = (noi_len != 8'd0 && !lfsr[0]) ? voln : 4'd0;

	wire [4:0] pulse_sum = {1'b0, out0} + {1'b0, out1};
	wire [7:0] tnd_sum   = 8'd3 * outt + 8'd2 * outn + {1'b0, dmc_dac};

	wire [15:0] level;
	apu_mix u_mix (.pulse_sum(pulse_sum), .tnd_sum(tnd_sum), .level(level));

	// --- DC blocker -------------------------------------------------------------
	// The mixer's output never goes negative, so it rides on an offset that moves
	// with whatever is playing. A fixed subtraction would not centre it; a slow
	// running mean, subtracted, does -- the same job the output capacitor does on
	// the real console.
	//
	// `dc` holds the mean shifted up 16 places so the filter can converge in
	// steps far smaller than one sample value. Adding diff*4 gives a time
	// constant of 2^14 samples, about 9 ms here, so the corner sits near 18 Hz:
	// below the lowest note the triangle can play, which is the point. A faster
	// filter would eat the bass line.
	reg [31:0] dc;
	wire [15:0] mean = dc[31:16];
	wire signed [16:0] diff = $signed({1'b0, level}) - $signed({1'b0, mean});

	always @(posedge clk) begin
		if (rst)        dc <= 32'd0;
		else if (cpu_ce) dc <= dc + {{13{diff[16]}}, diff, 2'b00};
	end

	// The host reads the ring buffer as unsigned centred on 0x8000, so that is
	// what goes in. Nineteen bits of headroom because diff plus the centre can
	// reach past both ends of the range before clamping.
	wire signed [18:0] centred = $signed({{2{diff[16]}}, diff}) + 19'sd32768;

	assign sample = (centred < 19'sd0)      ? 16'h0000
	              : (centred > 19'sd65535)  ? 16'hFFFF
	                                        : centred[15:0];

	assign status = {dmc_irq, frame_irq, 1'b0,
	                 dmc_left != 12'd0,
	                 noi_len != 8'd0, tri_len != 8'd0,
	                 pul_len[1] != 8'd0, pul_len[0] != 8'd0};

	assign irq = frame_irq || dmc_irq;

endmodule

`default_nettype wire
