//////////////////////////////////////////////////////////////////////////////////
// synth.v - eight-voice oscillator bank, read out over Ethernet.
//
// There is no DAC and no analog pin. Samples go into a ring buffer and leave the
// board as UDP, which means the audio arrives in software bit-exact: no
// converter, no filter, no cable, nothing to solder. The PC does whatever it
// likes with them -- play, record, analyse.
//
// Sample rate is 50 MHz / 1024 = 48828.125 Hz. Unusual, but it is reported in a
// register, and WAV files carry their own rate so a recording is exact rather
// than merely close.
//
// Eight voices share ONE datapath, computed serially: 1024 clocks are available
// between samples and eight are used. Adding voices later costs clocks, not
// logic.
//
// Each voice is a 32-bit phase accumulator. Adding a constant every sample gives
// a linear ramp that wraps on overflow -- which IS a sawtooth, for free, and its
// top bits index every other waveform. Frequency is therefore just that constant:
//
//     phase_inc = freq * 2^32 / 48828.125     (about 87961 per Hz)
//
// The envelope is a plain linear attack/release ramp. Not expressive, but it is
// what stops every note-on from being an audible click, which matters more.
//
// Register map, offsets within page 0x0003_0000:
//
//   0x00  ID          "SY"
//   0x04  CTRL        bit 0 = enable
//   0x08  MASTER_VOL  0..65535
//   0x0C  SAMPLE_RATE read-only, Hz
//   0x10  ATTACK      envelope step per sample while gated
//   0x14  RELEASE     envelope step per sample while released
//   0x20  WCOUNT      read-only, total words ever written to the ring buffer
//   0x40 + v*4  PHASE_INC[v]
//   0x60 + v*4  CTRL[v]   bit 0 gate, bits 3:1 waveform, bits 31:16 volume
//
// The ring buffer itself is page 0x0004_0000: 16384 words, TWO 16-bit samples
// per word (low half first), so 16384 samples, about 336 ms of history. WCOUNT is a
// free-running total rather than an index, so the host can tell "nothing new"
// from "I fell so far behind the buffer wrapped" -- an index alone cannot.
//
// Waveforms: 0 square, 1 saw, 2 triangle, 3 noise.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module synth #(
	parameter CLK_HZ  = 50_000_000,
	parameter DIV     = 1024,
	// Ring buffer words = 1 << BUF_AW. Each word is two samples, so 8192 words
	// is 336 ms at the 48.8 kHz sample rate. The browser polls every 60 ms and
	// the endpoint resyncs -- an audible gap -- if more than a bufferful goes by
	// between polls, so this is the stall the stream can absorb. 12 was enough
	// to work and not enough to be comfortable.
	parameter BUF_AW  = 13
)(
	input  wire        clk,
	input  wire        rst,

	input  wire [15:0] off,
	input  wire        we,
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,
	output reg         err,

	// The console's sound shares this ring buffer rather than having its own.
	// Everything downstream -- the packing, the cursor, the browser's audio
	// worklet -- then works for both without knowing which is playing.
	input  wire [15:0] ext_sample,
	input  wire [BUF_AW-1:0] buf_addr,
	output wire [31:0]       buf_rdata
);

	localparam SAMPLE_HZ = CLK_HZ / DIV;

	// --- sample clock -------------------------------------------------------
	reg [15:0] srdiv;
	wire sample_tick = (srdiv == DIV - 1);
	always @(posedge clk) begin
		if (rst) srdiv <= 16'd0;
		else     srdiv <= sample_tick ? 16'd0 : srdiv + 16'd1;
	end

	// --- registers ----------------------------------------------------------
	reg        enable;
	reg [15:0] master_vol;
	reg [15:0] attack, release_;

	// The reset arrives from the top of the design and fans out to everything.
	// Reaching this module's registers directly took nineteen nanoseconds of
	// pure routing and was the worst path in the whole build. A local copy
	// costs one clock at reset, which nothing here can tell.
	reg rst_q;
	always @(posedge clk) rst_q <= rst;

	reg [31:0] phase_inc [0:7];
	reg [15:0] vol       [0:7];
	reg [2:0]  wave      [0:7];
	reg [7:0]  gate;

	reg [31:0] phase     [0:7];
	reg [15:0] env       [0:7];

	integer i;

	// --- noise --------------------------------------------------------------
	reg [31:0] lfsr;
	wire lfsr_bit = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];

	// --- serial voice engine ------------------------------------------------
	reg [3:0]  vidx;
	reg        running;
	// 0 = the synth's own voices, 1 = the console plugged into the same buffer.
	reg        ext_src;
	reg signed [23:0] mixacc;
	reg [15:0] out_reg;
	reg        sample_done;

	wire [31:0] ph = phase[vidx[2:0]];
	wire [15:0] p  = ph[31:16];

	// Shapes as unsigned 0..65535 so they share one centring step.
	wire [15:0] w_sqr = p[15] ? 16'hFFFF : 16'h0000;
	wire [15:0] w_saw = p;
	// Fold the top half back down: up-ramp then down-ramp, no discontinuity.
	wire [15:0] w_tri = p[15] ? ~{p[14:0], 1'b0} : {p[14:0], 1'b0};
	wire [15:0] w_nse = lfsr[15:0];

	reg [15:0] wav;
	always @* begin
		case (wave[vidx[2:0]])
			3'd0:    wav = w_sqr;
			3'd1:    wav = w_saw;
			3'd2:    wav = w_tri;
			default: wav = w_nse;
		endcase
	end

	// Centre, then apply the envelope. The envelope doubles as per-voice volume,
	// because it ramps towards vol[] rather than towards full scale.
	wire signed [16:0] wav_s   = $signed({1'b0, wav}) - 17'sd32768;
	wire signed [32:0] scaled  = wav_s * $signed({1'b0, env[vidx[2:0]]});
	wire signed [16:0] contrib = scaled[32:16];

	// Master volume, then clamp. Eight voices at full tilt overflow 16 bits, and
	// wrapping sounds like destructive buzzing rather than like distortion.
	wire signed [39:0] mixed   = mixacc * $signed({1'b0, master_vol});
	wire signed [23:0] mixed_s = mixed[39:16];
	wire signed [15:0] clamped = (mixed_s >  24'sd32767) ?  16'sd32767 :
	                             (mixed_s < -24'sd32768) ? -16'sd32768 :
	                                                       mixed_s[15:0];

	always @(posedge clk) begin
		sample_done <= 1'b0;

		if (rst_q) begin
			enable     <= 1'b0;
			ext_src    <= 1'b0;
			master_vol <= 16'h2000;
			attack     <= 16'd400;
			release_   <= 16'd200;
			gate       <= 8'd0;
			lfsr       <= 32'hACE1_2345;
			running    <= 1'b0;
			vidx       <= 4'd0;
			mixacc     <= 24'sd0;
			out_reg    <= 16'h8000;
			for (i = 0; i < 8; i = i + 1) begin
				phase_inc[i] <= 32'd0;
				vol[i]       <= 16'hC000;
				wave[i]      <= 3'd2;
				phase[i]     <= 32'd0;
				env[i]       <= 16'd0;
			end
		end else begin

			if (sample_tick) begin
				vidx    <= 4'd0;
				mixacc  <= 24'sd0;
				running <= 1'b1;
				lfsr    <= {lfsr[30:0], lfsr_bit};
			end else if (running) begin

				phase[vidx[2:0]] <= ph + phase_inc[vidx[2:0]];
				mixacc <= mixacc + {{7{contrib[16]}}, contrib};

				// Saturating both ways, so it cannot wrap past the target.
				if (gate[vidx[2:0]]) begin
					if ({1'b0, env[vidx[2:0]]} + {1'b0, attack} >= {1'b0, vol[vidx[2:0]]})
						env[vidx[2:0]] <= vol[vidx[2:0]];
					else
						env[vidx[2:0]] <= env[vidx[2:0]] + attack;
				end else begin
					if (env[vidx[2:0]] <= release_) env[vidx[2:0]] <= 16'd0;
					else                            env[vidx[2:0]] <= env[vidx[2:0]] - release_;
				end

				if (vidx == 4'd7) begin
					running     <= 1'b0;
					out_reg     <= enable ? (clamped + 16'sd32768) : 16'h8000;
					sample_done <= 1'b1;
				end else begin
					vidx <= vidx + 4'd1;
				end
			end

			// --- register writes ----------------------------------------
			if (we) begin
				casez (off)
				16'h0004: begin enable <= wdata[0]; ext_src <= wdata[1]; end
				16'h0008: master_vol <= wdata[15:0];
				16'h0010: attack     <= wdata[15:0];
				16'h0014: release_   <= wdata[15:0];
				16'b0000_0000_010?_????: phase_inc[off[4:2]] <= wdata;   // 0x40..0x5F
				16'b0000_0000_011?_????: begin                           // 0x60..0x7F
						gate[off[4:2]] <= wdata[0];
						wave[off[4:2]] <= wdata[3:1];
						vol[off[4:2]]  <= wdata[31:16];
					end
				default: ;
				endcase
			end
		end
	end

	// --- ring buffer ---------------------------------------------------------
	// Which source is recorded is decided here, at the point the sample is
	// taken, so the rate and packing are identical either way.
	// Two 16-bit samples per 32-bit word, low half first, so a 255-word
	// READ_BLOCK carries 510 samples -- about 10 ms of audio per packet and
	// roughly 96 packets a second, rather than 191.
	wire [15:0] src_sample = ext_src ? ext_sample : out_reg;

	reg [31:0] abuf [0:(1<<BUF_AW)-1];
	reg [31:0] wcount;
	reg [15:0] pair_lo;
	reg        pair_hi;
	reg [31:0] abuf_q;

	assign buf_rdata = abuf_q;

	always @(posedge clk) begin
		if (rst_q) begin
			wcount  <= 32'd0;
			pair_hi <= 1'b0;
		end else if (sample_done) begin
			if (!pair_hi) begin
				pair_lo <= src_sample;
				pair_hi <= 1'b1;
			end else begin
				abuf[wcount[BUF_AW-1:0]] <= {src_sample, pair_lo};
				wcount  <= wcount + 32'd1;
				pair_hi <= 1'b0;
			end
		end
		abuf_q <= abuf[buf_addr];
	end

	// --- register reads ------------------------------------------------------
	always @* begin
		rdata = 32'd0;
		err   = 1'b0;
		casez (off)
		16'h0000: rdata = 32'h5359_0001;                 // "SY"
		16'h0004: rdata = {30'd0, ext_src, enable};
		16'h0008: rdata = {16'd0, master_vol};
		16'h000C: rdata = SAMPLE_HZ;
		16'h0010: rdata = {16'd0, attack};
		16'h0014: rdata = {16'd0, release_};
		// How big the ring actually is, so the host does not have to be told
		// separately every time it changes.
		16'h0018: rdata = 32'd1 << BUF_AW;
		16'h0020: rdata = wcount;
		16'b0000_0000_010?_????: rdata = phase_inc[off[4:2]];
		16'b0000_0000_011?_????: rdata = {vol[off[4:2]], 12'd0,
		                                  wave[off[4:2]], gate[off[4:2]]};
		default:  err = 1'b1;
		endcase
	end

endmodule

`default_nettype wire
