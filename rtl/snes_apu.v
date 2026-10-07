//////////////////////////////////////////////////////////////////////////////////
// snes_apu.v - the SNES's sound unit: the SPC700 (spc700.v) with our own boot ROM, 64 kB of
// sound RAM shared with the S-DSP (snes_dsp.v), the registers at $F0-$FF (control, the DSP
// port, the three timers, the four ports to the main CPU).
//
// As the model tools/snes/apu.py: timers 0 / 1 tick every 128 SPC700 cycles (8 kHz), timer 2
// every 16 (64 kHz), the DSP makes a sample every 32. `spc_ce` is one SPC700 cycle
// (1.024 MHz) made by the console from its clock.
//
// The boot ROM is ours (apu.py's IPL, written to the upload handshake Fullsnes documents),
// not Nintendo's.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_apu (
	input  wire        clk,
	input  wire        rst,
	input  wire        spc_ce,
	// the main CPU's side: $2140-$2143
	input  wire        cpu_we,
	input  wire [1:0]  cpu_port,
	input  wire [7:0]  cpu_wdata,
	output wire [7:0]  cpu_rdata,
	// sound out, 32 kHz
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	output wire        audio_stb,
	output wire [15:0] dbg_pc
);
	// --- the SPC700 --------------------------------------------------------------------------
	wire [15:0] s_addr; wire [7:0] s_dout; wire s_rd, s_we;
	reg  [7:0]  s_din;
	spc700 u_spc (.clk(clk), .rst(rst), .ce(spc_ce), .addr(s_addr), .dout(s_dout), .bus_rd(s_rd), .bus_we(s_we),
	              .din(s_din), .sync(), .dbg_pc(dbg_pc));

	// --- sound RAM: port A the SPC700, port B the DSP ------------------------------------------
	(* ram_style = "block" *) reg [7:0] aram [0:65535];
	reg  [7:0]  a_q;
	wire [15:0] d_a; wire d_we; wire [7:0] d_wd; reg [7:0] d_q;
	always @(posedge clk) begin
		a_q <= aram[s_addr];
		if (spc_ce && s_we) aram[s_addr] <= s_dout;      // (writes to $F0-$FF and under the ROM go to RAM too)
	end
	always @(posedge clk) begin
		d_q <= aram[d_a];
		if (d_we) aram[d_a] <= d_wd;
	end

	// --- the registers -----------------------------------------------------------------------
	reg [7:0] to_spc [0:3];
	reg [7:0] to_cpu [0:3];
	reg       ipl_on;
	reg [7:0] dsp_addr;
	reg [2:0] t_en;
	reg [7:0] t_div [0:2], t_stage [0:2];
	reg [3:0] t_out [0:2];
	reg [6:0] cyc;                       // SPC700 cycles, mod 128
	// a timer's output counter steps this clock (timers 0 / 1 on cycle 127 of 128, timer 2 every 16)
	wire [2:0] t_tick;
	wire       t01_now = spc_ce && cyc == 7'h7F, t2_now = spc_ce && cyc[3:0] == 4'hF;
	assign t_tick[0] = t01_now && t_en[0] && (t_stage[0] + 8'd1 == t_div[0]);
	assign t_tick[1] = t01_now && t_en[1] && (t_stage[1] + 8'd1 == t_div[1]);
	assign t_tick[2] = t2_now  && t_en[2] && (t_stage[2] + 8'd1 == t_div[2]);
	reg [7:0] aux [0:1];
	assign cpu_rdata = to_cpu[cpu_port];

	// the DSP
	wire [7:0] dsp_rdata;
	reg        dsp_sample;
	snes_dsp u_dsp (.clk(clk), .rst(rst), .sample(dsp_sample),
	                .r_we(spc_ce && s_we && s_addr == 16'h00F3 && !dsp_addr[7]), .r_addr(dsp_addr[6:0]),
	                .r_wdata(s_dout), .r_rdata(dsp_rdata),
	                .ram_a(d_a), .ram_q(d_q), .ram_we(d_we), .ram_wd(d_wd),
	                .out_l(audio_l), .out_r(audio_r), .out_stb(audio_stb));

	// the boot ROM
	function [7:0] ipl;
		input [5:0] a;
		case (a)
		6'h00: ipl = 8'hCD; 6'h01: ipl = 8'hEF; 6'h02: ipl = 8'hBD; 6'h03: ipl = 8'hE8;
		6'h04: ipl = 8'h00; 6'h05: ipl = 8'hC6; 6'h06: ipl = 8'h1D; 6'h07: ipl = 8'hD0;
		6'h08: ipl = 8'hFC; 6'h09: ipl = 8'h8F; 6'h0A: ipl = 8'hAA; 6'h0B: ipl = 8'hF4;
		6'h0C: ipl = 8'h8F; 6'h0D: ipl = 8'hBB; 6'h0E: ipl = 8'hF5; 6'h0F: ipl = 8'h78;
		6'h10: ipl = 8'hCC; 6'h11: ipl = 8'hF4; 6'h12: ipl = 8'hD0; 6'h13: ipl = 8'hFB;
		6'h14: ipl = 8'hBA; 6'h15: ipl = 8'hF6; 6'h16: ipl = 8'hDA; 6'h17: ipl = 8'h00;
		6'h18: ipl = 8'hFA; 6'h19: ipl = 8'hF4; 6'h1A: ipl = 8'hF4; 6'h1B: ipl = 8'hE4;
		6'h1C: ipl = 8'hF5; 6'h1D: ipl = 8'hF0; 6'h1E: ipl = 8'h19; 6'h1F: ipl = 8'h8D;
		6'h20: ipl = 8'h00; 6'h21: ipl = 8'h7E; 6'h22: ipl = 8'hF4; 6'h23: ipl = 8'hD0;
		6'h24: ipl = 8'hFC; 6'h25: ipl = 8'hE4; 6'h26: ipl = 8'hF5; 6'h27: ipl = 8'hD7;
		6'h28: ipl = 8'h00; 6'h29: ipl = 8'hCB; 6'h2A: ipl = 8'hF4; 6'h2B: ipl = 8'hFC;
		6'h2C: ipl = 8'hD0; 6'h2D: ipl = 8'h02; 6'h2E: ipl = 8'hAB; 6'h2F: ipl = 8'h01;
		6'h30: ipl = 8'h7E; 6'h31: ipl = 8'hF4; 6'h32: ipl = 8'hF0; 6'h33: ipl = 8'hF1;
		6'h34: ipl = 8'h10; 6'h35: ipl = 8'hFA; 6'h36: ipl = 8'h2F; 6'h37: ipl = 8'hDC;
		6'h38: ipl = 8'hFD; 6'h39: ipl = 8'h1F; 6'h3A: ipl = 8'h00; 6'h3B: ipl = 8'h00;
		6'h3C: ipl = 8'h00; 6'h3D: ipl = 8'h00; 6'h3E: ipl = 8'hC0; default: ipl = 8'hFF;
		endcase
	endfunction

	// what a read sees
	always @(*) begin
		s_din = a_q;
		if (s_addr >= 16'h00F0 && s_addr <= 16'h00FF) case (s_addr[3:0])
			4'h0, 4'h1, 4'hA, 4'hB, 4'hC: s_din = 8'h00;      // (write-only)
			4'h2: s_din = dsp_addr;
			4'h3: s_din = dsp_rdata;
			4'h4, 4'h5, 4'h6, 4'h7: s_din = to_spc[s_addr[1:0]];
			4'h8, 4'h9: s_din = aux[s_addr[0]];
			// (a read in the clock a timer ticks sees the tick, as the model does -- returned, then
			// cleared -- else the tick is lost; Super Mario World's driver waits on $FD in an
			// 8-cycle loop, which locks onto the 128-cycle tick and lost every one: it hung)
			4'hD: s_din = {4'h0, t_out[0] + {3'd0, t_tick[0]}};
			4'hE: s_din = {4'h0, t_out[1] + {3'd0, t_tick[1]}};
			default: s_din = {4'h0, t_out[2] + {3'd0, t_tick[2]}};
		endcase
		else if (s_addr >= 16'hFFC0 && ipl_on) s_din = ipl(s_addr[5:0]);
	end

	// --- the clocks of the timers and the DSP: in 16-cycle steps of the SPC700 -------------------
	integer i;
	always @(posedge clk) begin
		dsp_sample <= 1'b0;
		if (rst) begin
			for (i = 0; i < 4; i = i + 1) begin to_spc[i] <= 8'h00; to_cpu[i] <= 8'h00; end
			for (i = 0; i < 3; i = i + 1) begin t_div[i] <= 8'h00; t_stage[i] <= 8'h00; t_out[i] <= 4'h0; end
			aux[0] <= 8'h00; aux[1] <= 8'h00;
			ipl_on <= 1'b1; dsp_addr <= 8'h00; t_en <= 3'd0; cyc <= 7'd0;
		end else begin
			if (cpu_we) to_spc[cpu_port] <= cpu_wdata;
			if (spc_ce) begin
				cyc <= cyc + 7'd1;
				// every 16 cycles: timer 2; every 32: a DSP sample; every 128: timers 0 and 1
				if (cyc[3:0] == 4'hF) begin
					if (t_en[2]) begin
						if (t_stage[2] + 8'd1 == t_div[2]) begin t_stage[2] <= 8'd0; t_out[2] <= t_out[2] + 4'd1; end
						else t_stage[2] <= t_stage[2] + 8'd1;
					end
					if (cyc[4]) dsp_sample <= 1'b1;
					if (cyc == 7'h7F) for (i = 0; i < 2; i = i + 1) if (t_en[i]) begin
						if (t_stage[i] + 8'd1 == t_div[i]) begin t_stage[i] <= 8'd0; t_out[i] <= t_out[i] + 4'd1; end
						else t_stage[i] <= t_stage[i] + 8'd1;
					end
				end
				// the SPC700's accesses to $F0-$FF
				if (s_addr >= 16'h00F0 && s_addr <= 16'h00FF) begin
					if (s_we) case (s_addr[3:0])
						4'h1: begin
							ipl_on <= s_dout[7];
							for (i = 0; i < 3; i = i + 1)
								if (s_dout[i] && !t_en[i]) begin t_stage[i] <= 8'd0; t_out[i] <= 4'h0; end
							t_en <= s_dout[2:0];
							if (s_dout[4]) begin to_spc[0] <= 8'h00; to_spc[1] <= 8'h00; end
							if (s_dout[5]) begin to_spc[2] <= 8'h00; to_spc[3] <= 8'h00; end
						end
						4'h2: dsp_addr <= s_dout;
						4'h4, 4'h5, 4'h6, 4'h7: to_cpu[s_addr[1:0]] <= s_dout;
						4'h8, 4'h9: aux[s_addr[0]] <= s_dout;
						4'hA, 4'hB, 4'hC: t_div[s_addr[3:0] - 4'hA] <= s_dout;
						default: ;
					endcase
					if (s_rd && s_addr[3:0] >= 4'hD) t_out[s_addr[3:0] - 4'hD] <= 4'h0;   // (a read clears it)
				end
			end
		end
	end
endmodule
