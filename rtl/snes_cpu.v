//////////////////////////////////////////////////////////////////////////////////
// snes_cpu.v - the SNES's CPU chip (the 5A22): the 65816 core (w65816.v), each of its
// cycles timed by its address, the registers at $4200-$421F and $4300-$437F, the
// interrupts, the pad auto-read, and the DMA and HDMA engines.
//
// To the model tools/snes/snes.py, which has the same rules: the 6 / 8 / 12-clock regions,
// DMA's 8 clocks a byte, HDMA at H = 1104, NMI on the first line of vblank, the H / V IRQ.
// Fullsnes for the rest.
//
// --- the bus ----------------------------------------------------------------------------
// One port for everything outside the chip: req / we / is_b / addr / wdata, answered by
// ack with rdata any number of clocks later (a cartridge read from DDR3 may take a while;
// the slot then stretches). is_b: a B-bus access, addr[7:0] = $21xx's low byte -- the
// CPU's own accesses to $2100-$21FF go there too, as on the console.
//
// Everything happens in slots: a CPU cycle, a DMA byte, an HDMA step, an overhead. A slot
// lasts its number of master clocks (mce), or until its accesses are answered, whichever
// is later; a DMA byte is two accesses in one slot, the read then the write. The
// controller (cs) picks the next slot when one ends.
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
module snes_cpu (
	input  wire        clk,
	input  wire        rst,
	input  wire        mce,
	input  wire [10:0] h,
	input  wire [8:0]  v,
	input  wire        overscan,
	output reg         req,
	output reg         we,
	output reg         is_b,
	output reg  [23:0] addr,
	output reg  [7:0]  wdata,
	input  wire        ack,
	input  wire [7:0]  rdata,
	output reg  [7:0]  mdr,           // open bus: the last byte the bus carried
	// the pads, as $4218/$4219 read them (bit 15 B ... bit 4 R)
	input  wire [15:0] pad1,
	input  wire [15:0] pad2,
	output wire [15:0] dbg_pc,
	output wire [7:0]  dbg_pbr
);
	// --- the 65816 -----------------------------------------------------------------------
	wire [23:0] c_addr; wire [7:0] c_dout; wire c_we, c_vda, c_vpa;
	reg         c_ce;
	reg  [7:0]  c_din;
	reg         nmi_pulse;
	reg         timeup;
	w65816 u_core (.clk(clk), .rst(rst), .ce(c_ce), .addr(c_addr), .dout(c_dout), .we(c_we),
	               .vda(c_vda), .vpa(c_vpa), .din(c_din), .nmi(nmi_pulse), .irq(timeup),
	               .e_flag(), .m_flag(), .x_flag(), .sync(), .dbg_pc(dbg_pc), .dbg_pbr(dbg_pbr));

	// --- registers ------------------------------------------------------------------------
	reg [7:0]  nmitimen, wrmpya, memsel, hdmaen;
	reg [15:0] wrdiv, rddiv, rdmpy;
	reg [8:0]  htime, vtime;
	reg        rdnmi;
	reg [15:0] joy1, joy2;
	reg [7:0]  dmap [0:7], bbad [0:7], a1b [0:7], dasb [0:7], ntrl [0:7], dunused [0:7];
	reg [15:0] a1t [0:7], das [0:7], a2a [0:7];
	reg [7:0]  hdma_done, hdma_do;
	wire [8:0] last_line = overscan ? 9'd239 : 9'd224;

	// the master clocks a CPU cycle takes, by its address
	function [4:0] speed;
		input [23:0] a; input valid; input fast;
		reg [15:0] o;
		begin
			o = a[15:0];
			if (!valid) speed = 5'd6;
			else if (!a[22]) begin
				if (o < 16'h2000) speed = 5'd8;
				else if (o < 16'h4000) speed = 5'd6;
				else if (o < 16'h4200) speed = 5'd12;
				else if (o < 16'h6000) speed = 5'd6;
				else if (o < 16'h8000) speed = 5'd8;
				else speed = (a[23] && fast) ? 5'd6 : 5'd8;
			end else speed = (a[23] && fast) ? 5'd6 : 5'd8;
		end
	endfunction

	wire        c_io_bank = !c_addr[22];
	wire [15:0] c_off = c_addr[15:0];
	wire        c_own = c_io_bank && ((c_off >= 16'h4200 && c_off < 16'h4220) || (c_off >= 16'h4300 && c_off < 16'h4380) ||
	                                  c_off == 16'h4016 || c_off == 16'h4017);
	wire        c_bbus = c_io_bank && (c_off[15:8] == 8'h21);

	// the chip's own registers, read
	reg [7:0] own_rd;
	reg [2:0] rc;
	always @(*) begin
		own_rd = mdr;
		rc = c_off[6:4];
		if (c_off == 16'h4016 || c_off == 16'h4017) own_rd = {mdr[7:2], 2'b00};
		else if (c_off[15:8] == 8'h42) case (c_off[7:0])
			8'h10: own_rd = {rdnmi, mdr[6:4], 4'h2};
			8'h11: own_rd = {timeup, mdr[6:0]};
			8'h12: own_rd = {(v > last_line), (h < 11'd4) || (h >= 11'd1096), mdr[5:1],
			                 (v > last_line) && (v < last_line + 9'd4)};
			8'h13: own_rd = 8'h00;
			8'h14: own_rd = rddiv[7:0];  8'h15: own_rd = rddiv[15:8];
			8'h16: own_rd = rdmpy[7:0];  8'h17: own_rd = rdmpy[15:8];
			8'h18: own_rd = joy1[7:0];   8'h19: own_rd = joy1[15:8];
			8'h1A: own_rd = joy2[7:0];   8'h1B: own_rd = joy2[15:8];
			8'h1C, 8'h1D, 8'h1E, 8'h1F: own_rd = 8'h00;
			default: own_rd = mdr;
		endcase
		else if (c_off[15:8] == 8'h43) case (c_off[3:0])
			4'h0: own_rd = dmap[rc];       4'h1: own_rd = bbad[rc];
			4'h2: own_rd = a1t[rc][7:0];   4'h3: own_rd = a1t[rc][15:8];
			4'h4: own_rd = a1b[rc];        4'h5: own_rd = das[rc][7:0];
			4'h6: own_rd = das[rc][15:8];  4'h7: own_rd = dasb[rc];
			4'h8: own_rd = a2a[rc][7:0];   4'h9: own_rd = a2a[rc][15:8];
			4'hA: own_rd = ntrl[rc];
			default: own_rd = dunused[rc];
		endcase
	end

	// --- the slot sequencer -----------------------------------------------------------------
	localparam [4:0]
		C_CPU = 5'd0,
		C_DMA_GO = 5'd1, C_DMA_CH = 5'd2, C_DMA_BYTE = 5'd3,
		C_HI_GO = 5'd4, C_HI_CH = 5'd5, C_HI_NTRL = 5'd6, C_HI_IND1 = 5'd7, C_HI_IND2 = 5'd8,
		C_HR_GO = 5'd9, C_HR_CH = 5'd10, C_HR_UNIT = 5'd11, C_HR_NTRL = 5'd12,
		C_HR_IND1 = 5'd13, C_HR_IND2 = 5'd14, C_HR_DEC = 5'd15;
	reg [4:0]  cs;
	reg        slot_live;
	reg [4:0]  slot_len, slot_cnt;
	reg        a1_pending, a2_pending, acc_out;
	reg        a2_b; reg [23:0] a2_addr; reg a2_blocked;
	reg [7:0]  got;
	reg        cpu_slot;
	reg        dma_pend;
	reg [7:0]  dma_mask, todo;
	reg [2:0]  ch;
	reg [2:0]  unit_k;
	reg        hdma_line_done, hdma_init_done, irq_done;

	function [1:0] pat;                       // byte k's B-bus offset, by transfer mode
		input [2:0] m; input [2:0] k;
		case (m)
		3'd0, 3'd2, 3'd6: pat = 2'd0;
		3'd1, 3'd5: pat = {1'b0, k[0]};
		3'd3, 3'd7: pat = {1'b0, k[1]};
		default: pat = k[1:0];                // 4
		endcase
	endfunction
	function [2:0] units;                     // bytes in one unit
		input [2:0] m;
		case (m)
		3'd0: units = 3'd1;
		3'd1, 3'd2, 3'd6: units = 3'd2;
		default: units = 3'd4;
		endcase
	endfunction
	function a_blocked;                       // an A-bus address DMA does not reach
		input [23:0] a;
		a_blocked = !a[22] && ((a[15:8] == 8'h21) || (a[15:7] == 9'b0100_0011_0) ||
		            a[15:0] == 16'h420B || a[15:0] == 16'h420C);
	endfunction
	function [2:0] lowest;
		input [7:0] m;
		integer j;
		begin lowest = 3'd0; for (j = 7; j >= 0; j = j - 1) if (m[j]) lowest = j; end
	endfunction

	wire hdma_due      = (h >= 11'd1104) && !hdma_line_done && (v <= last_line) && |(hdmaen & ~hdma_done);
	wire hdma_init_due = (v == 9'd0) && (h >= 11'd6) && !hdma_init_done && (hdmaen != 8'h00);

	task xfer_slot;                           // a DMA / HDMA byte: bus A at aa <-> channel ch's B register
		input [23:0] aa; input [2:0] k;
		reg [23:0] bb;
		begin
			bb = {16'h0021, bbad[ch] + {6'd0, pat(dmap[ch][2:0], k)}};
			slot_len <= 5'd8; slot_cnt <= 5'd0; slot_live <= 1'b1; cpu_slot <= 1'b0;
			a1_pending <= 1'b1; a2_pending <= 1'b1; we <= 1'b0;
			a2_blocked <= a_blocked(aa);
			if (!dmap[ch][7]) begin is_b <= 1'b0; addr <= aa; a2_b <= 1'b1; a2_addr <= bb; end   // A -> B
			else              begin is_b <= 1'b1; addr <= bb; a2_b <= 1'b0; a2_addr <= aa; end   // B -> A
		end
	endtask
	task read_slot;
		input [23:0] aa;
		begin
			slot_len <= 5'd8; slot_cnt <= 5'd0; slot_live <= 1'b1; cpu_slot <= 1'b0;
			a1_pending <= 1'b1; a2_pending <= 1'b0; we <= 1'b0; is_b <= 1'b0; addr <= aa;
		end
	endtask
	task idle_slot;
		input [4:0] n;
		begin
			slot_len <= n; slot_cnt <= 5'd0; slot_live <= 1'b1; cpu_slot <= 1'b0;
			a1_pending <= 1'b0; a2_pending <= 1'b0;
		end
	endtask

	task own_write;                           // the chip's registers, written by the CPU
		input [15:0] o; input [7:0] d;
		reg [2:0] c;
		begin
			c = o[6:4];
			if (o[15:8] == 8'h42) case (o[7:0])
				8'h00: begin nmitimen <= d; if (d[5:4] == 2'd0) timeup <= 1'b0; end
				8'h02: wrmpya <= d;
				8'h03: begin rdmpy <= wrmpya * d; rddiv <= {8'h00, d}; end
				8'h04: wrdiv[7:0] <= d;
				8'h05: wrdiv[15:8] <= d;
				8'h06: if (d == 8'h00) begin rddiv <= 16'hFFFF; rdmpy <= wrdiv; end
				       else begin rddiv <= wrdiv / d; rdmpy <= wrdiv % d; end
				8'h07: htime[7:0] <= d;  8'h08: htime[8] <= d[0];
				8'h09: vtime[7:0] <= d;  8'h0A: vtime[8] <= d[0];
				8'h0B: if (d != 8'h00) begin dma_pend <= 1'b1; dma_mask <= d; end
				8'h0C: hdmaen <= d;
				8'h0D: memsel <= d;
				default: ;
			endcase
			else if (o[15:8] == 8'h43) case (o[3:0])
				4'h0: dmap[c] <= d;  4'h1: bbad[c] <= d;
				4'h2: a1t[c][7:0] <= d;  4'h3: a1t[c][15:8] <= d;
				4'h4: a1b[c] <= d;
				4'h5: das[c][7:0] <= d;  4'h6: das[c][15:8] <= d;
				4'h7: dasb[c] <= d;
				4'h8: a2a[c][7:0] <= d;  4'h9: a2a[c][15:8] <= d;
				4'hA: ntrl[c] <= d;
				default: dunused[c] <= d;
			endcase
		end
	endtask

	integer i;
	reg [2:0] c3;
	reg [7:0] n8;
	always @(posedge clk) begin
		c_ce <= 1'b0;
		nmi_pulse <= 1'b0;
		req <= 1'b0;
		if (rst) begin
			nmitimen <= 8'h00; memsel <= 8'h00; hdmaen <= 8'h00; wrmpya <= 8'hFF; wrdiv <= 16'hFFFF;
			htime <= 9'h1FF; vtime <= 9'h1FF; rdnmi <= 1'b0; timeup <= 1'b0; joy1 <= 16'h0; joy2 <= 16'h0;
			rddiv <= 16'h0; rdmpy <= 16'h0; mdr <= 8'h00;
			cs <= C_CPU; slot_live <= 1'b0; acc_out <= 1'b0; a1_pending <= 1'b0; a2_pending <= 1'b0;
			dma_pend <= 1'b0; dma_mask <= 8'h00; hdma_done <= 8'hFF; hdma_do <= 8'h00; todo <= 8'h00;
			hdma_line_done <= 1'b0; hdma_init_done <= 1'b0; irq_done <= 1'b0;
			we <= 1'b0; is_b <= 1'b0; addr <= 24'd0; wdata <= 8'h00;
			for (i = 0; i < 8; i = i + 1) begin
				dmap[i] <= 8'hFF; bbad[i] <= 8'hFF; a1t[i] <= 16'hFFFF; a1b[i] <= 8'hFF; das[i] <= 16'hFFFF;
				dasb[i] <= 8'hFF; a2a[i] <= 16'hFFFF; ntrl[i] <= 8'hFF; dunused[i] <= 8'hFF;
			end
		end else begin
			// ---- the frame's events ----
			if (mce && h == 11'd0) begin
				hdma_line_done <= 1'b0;
				irq_done <= 1'b0;
				if (v == 9'd0) begin rdnmi <= 1'b0; hdma_init_done <= 1'b0; end
				if (v == last_line + 9'd1) begin
					rdnmi <= 1'b1;
					if (nmitimen[7]) nmi_pulse <= 1'b1;
					if (nmitimen[0]) begin joy1 <= pad1; joy2 <= pad2; end
				end
			end
			if (nmitimen[5:4] != 2'd0 && !irq_done &&
			    ((nmitimen[5:4] == 2'd1 && h >= {htime, 2'b00} + 11'd14) ||
			     (nmitimen[5:4] == 2'd2 && v == vtime) ||
			     (nmitimen[5:4] == 2'd3 && v == vtime && h >= {htime, 2'b00} + 11'd14))) begin
				timeup <= 1'b1; irq_done <= 1'b1;
			end

			if (slot_live) begin
				// ---- a slot in progress: its accesses, its clocks ----
				if (mce && slot_cnt != 5'd31) slot_cnt <= slot_cnt + 5'd1;
				if ((a1_pending || a2_pending) && !acc_out) begin
					req <= 1'b1; acc_out <= 1'b1;
				end else if (acc_out && ack) begin
					acc_out <= 1'b0;
					if (a1_pending) begin
						a1_pending <= 1'b0;
						if (!we) begin got <= rdata; mdr <= rdata; if (cpu_slot) c_din <= rdata; end
						else mdr <= wdata;
						if (a2_pending) begin                // the DMA byte's write, to the other bus
							we <= 1'b1; is_b <= a2_b; addr <= a2_addr;
							wdata <= (a2_b && a2_blocked) ? mdr : rdata;   // (A-side blocked: the bus's old byte)
							if (!a2_b && a2_blocked) a2_pending <= 1'b0;   // (nor is it written)
						end
					end else begin
						a2_pending <= 1'b0;
						mdr <= wdata;
					end
				end
				if (!a1_pending && !a2_pending && !acc_out && slot_cnt >= slot_len) begin
					slot_live <= 1'b0;
					if (cpu_slot) begin
						c_ce <= 1'b1;
						if (!c_we && c_own && c_off == 16'h4210) rdnmi <= 1'b0;
						if (!c_we && c_own && c_off == 16'h4211) timeup <= 1'b0;
					end
				end
			end else if (!c_ce) begin
				// ---- the next slot (not on the clock the core moves on: its bus is not yet
				// the next cycle's) ----
				case (cs)
				C_CPU: begin
					if (hdma_init_due) begin cs <= C_HI_GO; hdma_init_done <= 1'b1; end
					else if (hdma_due) begin cs <= C_HR_GO; hdma_line_done <= 1'b1; end
					else if (dma_pend) cs <= C_DMA_GO;
					else begin
						slot_len <= speed(c_addr, c_vda | c_vpa, memsel[0]);
						slot_cnt <= 5'd0; slot_live <= 1'b1; cpu_slot <= 1'b1;
						a1_pending <= 1'b0; a2_pending <= 1'b0;
						if (c_vda | c_vpa) begin
							if (c_own) begin
								if (!c_we) c_din <= own_rd; else own_write(c_off, c_dout);
								mdr <= c_we ? c_dout : own_rd;
							end else begin
								we <= c_we; is_b <= c_bbus;
								addr <= c_bbus ? {16'h0021, c_off[7:0]} : c_addr; wdata <= c_dout;
								a1_pending <= 1'b1;
							end
						end
					end
				end
				// GP-DMA: 8 clocks to start, 8 a channel, 8 a byte; the lowest channel first
				C_DMA_GO: begin idle_slot(5'd8); cs <= C_DMA_CH; end
				C_DMA_CH: begin
					if (dma_mask == 8'h00) begin dma_pend <= 1'b0; cs <= C_CPU; end
					else begin ch <= lowest(dma_mask); unit_k <= 3'd0; idle_slot(5'd8); cs <= C_DMA_BYTE; end
				end
				C_DMA_BYTE: begin
					xfer_slot({a1b[ch], a1t[ch]}, unit_k);
					unit_k <= unit_k + 3'd1;
					if (!dmap[ch][3]) a1t[ch] <= dmap[ch][4] ? a1t[ch] - 16'd1 : a1t[ch] + 16'd1;
					das[ch] <= das[ch] - 16'd1;
					if (das[ch] == 16'd1) begin dma_mask[ch] <= 1'b0; cs <= C_DMA_CH; end
				end
				// HDMA at the frame's start: each enabled channel's first entry
				C_HI_GO: begin idle_slot(5'd18); todo <= hdmaen; hdma_done <= ~hdmaen; hdma_do <= 8'h00; cs <= C_HI_CH; end
				C_HI_CH: begin
					if (todo == 8'h00) cs <= C_CPU;
					else begin
						c3 = lowest(todo); ch <= c3; todo[c3] <= 1'b0;
						a2a[c3] <= a1t[c3] + 16'd1;
						read_slot({a1b[c3], a1t[c3]});
						cs <= C_HI_NTRL;
					end
				end
				// (a table byte read has landed in `got`)
				C_HI_NTRL, C_HR_NTRL: begin
					ntrl[ch] <= got;
					if (got == 8'h00) begin hdma_done[ch] <= 1'b1; cs <= (cs == C_HI_NTRL) ? C_HI_CH : C_HR_CH; end
					else begin
						hdma_do[ch] <= 1'b1;
						if (dmap[ch][6]) begin
							read_slot({a1b[ch], a2a[ch]}); a2a[ch] <= a2a[ch] + 16'd1;
							cs <= (cs == C_HI_NTRL) ? C_HI_IND1 : C_HR_IND1;
						end else cs <= (cs == C_HI_NTRL) ? C_HI_CH : C_HR_CH;
					end
				end
				C_HI_IND1, C_HR_IND1: begin
					das[ch][7:0] <= got;
					read_slot({a1b[ch], a2a[ch]}); a2a[ch] <= a2a[ch] + 16'd1;
					cs <= (cs == C_HI_IND1) ? C_HI_IND2 : C_HR_IND2;
				end
				C_HI_IND2, C_HR_IND2: begin
					das[ch][15:8] <= got;
					cs <= (cs == C_HI_IND2) ? C_HI_CH : C_HR_CH;
				end
				// HDMA on a line: each active channel's unit, then its line counter
				C_HR_GO: begin idle_slot(5'd18); todo <= hdmaen & ~hdma_done; cs <= C_HR_CH; end
				C_HR_CH: begin
					if (todo == 8'h00) cs <= C_CPU;
					else begin
						c3 = lowest(todo); ch <= c3; todo[c3] <= 1'b0; unit_k <= 3'd0;
						idle_slot(5'd8);
						cs <= hdma_do[c3] ? C_HR_UNIT : C_HR_DEC;
					end
				end
				C_HR_UNIT: begin
					if (dmap[ch][6]) begin xfer_slot({dasb[ch], das[ch]}, unit_k); das[ch] <= das[ch] + 16'd1; end
					else begin xfer_slot({a1b[ch], a2a[ch]}, unit_k); a2a[ch] <= a2a[ch] + 16'd1; end
					unit_k <= unit_k + 3'd1;
					if (unit_k + 3'd1 == units(dmap[ch][2:0])) cs <= C_HR_DEC;
				end
				C_HR_DEC: begin
					n8 = ntrl[ch] - 8'd1;
					ntrl[ch] <= n8;
					hdma_do[ch] <= n8[7];
					if (n8[6:0] == 7'd0) begin
						read_slot({a1b[ch], a2a[ch]}); a2a[ch] <= a2a[ch] + 16'd1;
						cs <= C_HR_NTRL;
					end else cs <= C_HR_CH;
				end
				default: cs <= C_CPU;
				endcase
			end
		end
	end
endmodule
