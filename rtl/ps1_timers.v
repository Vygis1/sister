//////////////////////////////////////////////////////////////////////////////////
// ps1_timers.v - the three root counters at $1F801100.
//
// Each is sixteen bits with a mode word and a target, at 16-byte spacing:
//
//   +0  COUNTER   read, or write to set
//   +4  MODE      see below
//   +8  TARGET
//
// MODE:
//   0     sync enable (with 1-2 the sync mode; only "free run" and "pause
//         during blank" matter to anything here)
//   3     reset the counter to zero when it reaches TARGET (else at $FFFF)
//   4     interrupt when it reaches TARGET
//   5     interrupt when it wraps at $FFFF
//   6     repeat: keep interrupting, rather than once
//   7     toggle: bit 10 flips per interrupt rather than pulsing
//   8-9   clock source. Counter 0: 0/2 system clock, 1/3 dot clock.
//         Counter 1: 0/2 system clock, 1/3 horizontal blank.
//         Counter 2: 0/1 system clock, 2/3 system clock / 8.
//   10    interrupt request, INVERTED: 0 means one is being asked for
//   11    reached TARGET   } read-only, and cleared by reading MODE
//   12    reached $FFFF    }
//
// Writing MODE zeroes the counter and sets bit 10 (nothing asked for). The
// BIOS uses these for its delays, and a game uses counter 2 for its frame
// pacing, so "close enough" is not good enough: a counter that is 5% fast
// makes a game 5% fast.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_timers (
	input  wire        clk,
	input  wire        rst,
	input  wire        sys_ce,      // the console's 33.8688 MHz, as an enable
	input  wire        dot_ce,      // one dot of the GPU
	input  wire        hblank,      // level: in horizontal blanking
	input  wire        vblank,      // level: in vertical blanking

	input  wire        sel,
	input  wire        we,
	input  wire [5:0]  a,           // $00..$2F
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,

	output wire [2:0]  irq          // one per counter, a one-clock pulse per event
);
	reg [15:0] cnt  [0:2];
	reg [15:0] tgt  [0:2];
	reg [12:0] mode [0:2];
	reg [2:0]  irq_r;
	reg        hb_d;
	reg [2:0]  div8;

	assign irq = irq_r;

	wire [1:0] which = a[5:4];
	wire [1:0] reg_  = a[3:2];

	// which clock ticks each counter this cycle
	wire tick0 = mode[0][8] ? dot_ce : sys_ce;
	wire tick1 = mode[1][8] ? (hblank && !hb_d) : sys_ce;
	wire tick2 = mode[2][9] ? (sys_ce && div8 == 3'd7) : sys_ce;
	wire [2:0] tick = {tick2, tick1, tick0};

	// sync mode 0-2: pause/reset around blanking. Only "pause during blank"
	// (mode 0) and "free run" (sync disabled) are modelled; mode 3 (wait for
	// blank then free run) starts free-running immediately.
	wire blank0 = hblank, blank1 = vblank, blank2 = 1'b0;
	wire [2:0] paused = {mode[2][0] && (mode[2][2:1] == 2'd0) && blank2,
	                     mode[1][0] && (mode[1][2:1] == 2'd0) && blank1,
	                     mode[0][0] && (mode[0][2:1] == 2'd0) && blank0};

	integer i;
	always @(posedge clk) begin
		if (rst) begin
			for (i = 0; i < 3; i = i + 1) begin
				cnt[i] <= 16'd0; tgt[i] <= 16'd0; mode[i] <= 13'h0400;
			end
			irq_r <= 3'd0; hb_d <= 1'b0; div8 <= 3'd0;
		end else begin
			hb_d <= hblank;
			if (sys_ce) div8 <= div8 + 3'd1;

			irq_r <= 3'd0;                                   // a pulse per event (see fire)
			for (i = 0; i < 3; i = i + 1) begin
				if (tick[i] && !paused[i]) begin
					if (cnt[i] == tgt[i] && mode[i][3]) begin
						cnt[i] <= 16'd0;
					end else
						cnt[i] <= cnt[i] + 16'd1;

					if (cnt[i] == tgt[i]) begin
						mode[i][11] <= 1'b1;
						if (mode[i][4]) fire(i);
					end
					if (cnt[i] == 16'hFFFF) begin
						mode[i][12] <= 1'b1;
						if (mode[i][5]) fire(i);
					end
				end
			end

			if (sel) begin
				if (we) case (reg_)
					2'd0: cnt[which]  <= wdata[15:0];
					2'd1: begin
							mode[which] <= {3'b001, wdata[9:0]};   // bit 10 set, 11-12 clear
							cnt[which]  <= 16'd0;
							irq_r[which] <= 1'b0;
						end
					2'd2: tgt[which]  <= wdata[15:0];
					default: ;
					endcase
				else if (reg_ == 2'd1) begin
					// reading MODE clears the reached bits
					mode[which][12:11] <= 2'b00;
				end
			end
		end
	end

	// An interrupt: bit 10 drops (or toggles) and the line goes up for one
	// clock. Once-only unless repeat is set; a second one is then ignored until
	// MODE is written. A pulse, not a level: the interrupt controller takes
	// edges, and the kernel's timer handlers acknowledge only the controller,
	// never the timer -- held high until the next MODE write, the line gave one
	// interrupt per programming, and a game's music tick (root counter 2 at
	// 240 Hz) ran exactly once.
	task fire;
		input integer w;
		begin
			if (mode[w][7]) mode[w][10] <= ~mode[w][10];
			else            mode[w][10] <= 1'b0;
			if (mode[w][6] || mode[w][10]) irq_r[w] <= 1'b1;
		end
	endtask

	always @(*) begin
		case (reg_)
		2'd0:    rdata = {16'd0, cnt[which]};
		2'd1:    rdata = {19'd0, mode[which]};
		2'd2:    rdata = {16'd0, tgt[which]};
		default: rdata = 32'd0;
		endcase
	end
endmodule

`default_nettype wire
