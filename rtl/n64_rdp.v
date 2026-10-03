//////////////////////////////////////////////////////////////////////////////////
// n64_rdp.v - the N64's RDP. So far its registers and its command walk, and no
// drawing: commands are read from RDRAM (or from DMEM, over the XBUS) between
// DPC_CURRENT and DPC_END, each skipped by its length, and SYNC_FULL raises the
// DP interrupt as the real one does when it has finished a list. A game that
// draws therefore runs on, its frames blank, until the rasteriser is here.
//
// The registers are ares's (ares/n64/rdp/io.cpp, ISC): START is taken only while
// no start is pending; END sets the end and, if a start is pending, moves
// CURRENT to it, and the walk resumes; STATUS's write bits clear and set the
// source (XBUS), freeze, flush and the busy counters.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp #(
	parameter [23:0] RDRAM_LINE = 24'h00_0000
) (
	input  wire         clk,
	input  wire         rst,
	// the registers: a write from the CPU or the RSP (the CPU first), and all of
	// them for reading
	input  wire         c_we,
	input  wire [2:0]   c_idx,
	input  wire [31:0]  c_wd,
	input  wire         r_we,
	input  wire [2:0]   r_idx,
	input  wire [31:0]  r_wd,
	output wire [255:0] regs_flat,        // register i in [255 - 32 i -: 32]
	// the commands: a line of RDRAM, or a doubleword of DMEM
	output reg          cf_req,
	input  wire         cf_ack,
	output reg  [23:0]  cf_line,
	input  wire [127:0] cf_data,
	output reg          xb_req,
	output reg  [8:0]   xb_dw,
	input  wire         xb_ack,
	input  wire [63:0]  xb_data,
	output reg          irq
);
	reg  [23:0] start, endp, current;
	reg  [23:0] cmd_end;                  // where the command being passed over ends
	reg         start_valid, source, freeze, flush, start_gclk;
	reg  [23:0] clock;

	wire [31:0] status = {21'd0, start_valid, 1'b0 /*end valid*/, 1'b0 /*DMA busy*/, 1'b1 /*ready*/,
	                      1'b0, 1'b0, 1'b0, start_gclk, flush, freeze, source};
	assign regs_flat = {8'd0, start, 8'd0, endp, 8'd0, current, status, 8'd0, clock, 32'd0, 32'd0, 32'd0};

	// --- the walk ----------------------------------------------------------------------
	localparam [1:0] W_IDLE = 2'd0, W_WAIT = 2'd1;
	reg  [1:0]   ws;
	reg  [127:0] line;  reg [18:0] ltag; reg lv;
	reg          wend;                     // END was written while a line was being fetched
	wire [63:0]  dw_ram = {line[8 * {current[3], 3'd0} +: 8], line[8 * {current[3], 3'd1} +: 8],
	                       line[8 * {current[3], 3'd2} +: 8], line[8 * {current[3], 3'd3} +: 8],
	                       line[8 * {current[3], 3'd4} +: 8], line[8 * {current[3], 3'd5} +: 8],
	                       line[8 * {current[3], 3'd6} +: 8], line[8 * {current[3], 3'd7} +: 8]};
	wire [63:0]  dw_cf  = {cf_data[8 * {current[3], 3'd0} +: 8], cf_data[8 * {current[3], 3'd1} +: 8],
	                       cf_data[8 * {current[3], 3'd2} +: 8], cf_data[8 * {current[3], 3'd3} +: 8],
	                       cf_data[8 * {current[3], 3'd4} +: 8], cf_data[8 * {current[3], 3'd5} +: 8],
	                       cf_data[8 * {current[3], 3'd6} +: 8], cf_data[8 * {current[3], 3'd7} +: 8]};
	// a command's length in doublewords
	function [4:0] cmd_len; input [5:0] op; begin
		if (op[5:3] == 3'b001) cmd_len = 5'd4 + (op[2] ? 5'd8 : 5'd0) + (op[1] ? 5'd8 : 5'd0) + (op[0] ? 5'd2 : 5'd0);
		else if (op == 6'h24 || op == 6'h25) cmd_len = 5'd2;
		else cmd_len = 5'd1;
	end endfunction
	reg  [63:0]  cmd;
	reg          have;

	// a write from either side
	wire         we = c_we || r_we;
	wire [2:0]   widx = c_we ? c_idx : r_idx;
	wire [31:0]  wd = c_we ? c_wd : r_wd;

	always @(posedge clk) begin
		irq <= 1'b0;
		if (cf_ack) cf_req <= 1'b0;
		if (xb_ack) xb_req <= 1'b0;
		if (rst) begin
			start <= 24'd0; endp <= 24'd0; current <= 24'd0; cmd_end <= 24'd0; start_valid <= 1'b0; source <= 1'b0;
			freeze <= 1'b0; flush <= 1'b0; start_gclk <= 1'b0; clock <= 24'd0;
			ws <= W_IDLE; lv <= 1'b0; cf_req <= 1'b0; xb_req <= 1'b0; have <= 1'b0; wend <= 1'b0;
		end else begin
			clock <= clock + 24'd1;
			if (we) begin
				case (widx)
				3'd0: begin if (!start_valid) start <= {wd[23:3], 3'b000}; start_valid <= 1'b1; end
				3'd1: begin
					endp <= {wd[23:3], 3'b000};
					// the line held is dropped at every END: a list grows in place, and the
					// rest of the line it was read from was not written yet (keeping it lost
					// SM64's SYNC_FULL in the stale bytes after three frames)
					lv <= 1'b0; wend <= 1'b1;
					if (start_valid) begin current <= start; cmd_end <= start; start_valid <= 1'b0; end
				end
				3'd3: begin
					if (wd[0]) source <= 1'b0;
					if (wd[1]) source <= 1'b1;
					if (wd[2]) freeze <= 1'b0;
					if (wd[3]) freeze <= 1'b1;
					if (wd[4]) flush <= 1'b0;
					if (wd[5]) flush <= 1'b1;
					if (wd[9]) clock <= 24'd0;
				end
				default: ;
				endcase
			end
			// the walk: a command's first doubleword, then on past the rest of it
			case (ws)
			// CURRENT never passes END: a command the list has only part of (SM64's
			// microcode cuts a list wherever its buffer fills, texture rectangles in
			// two) is passed over up to END, and the rest of it when END moves on. Run
			// past END, CURRENT sat inside the space the microcode was about to write,
			// and it waited for the RDP to leave it, for ever.
			W_IDLE: if (!we && !freeze && !have && current < cmd_end) begin
				if (current < endp) current <= (cmd_end <= endp) ? cmd_end : endp;
			end else if (!we && !freeze && !have && current < endp) begin
				if (source) begin
					xb_dw <= current[11:3]; xb_req <= 1'b1; ws <= W_WAIT;
				end else if (lv && ltag == current[22:4]) begin
					cmd <= dw_ram; have <= 1'b1;
				end else begin
					cf_line <= RDRAM_LINE + {5'd0, current[22:4]}; cf_req <= 1'b1; ws <= W_WAIT; wend <= 1'b0;
				end
			end
			W_WAIT: begin
				if (source && xb_ack) begin cmd <= xb_data; have <= 1'b1; ws <= W_IDLE; end
				// (a line fetched across an END write is used for the one doubleword asked
				// for, which was inside the list, and not kept)
				if (!source && cf_ack) begin
					if (wend || we) begin cmd <= dw_cf; have <= 1'b1; end
					else begin line <= cf_data; ltag <= current[22:4]; lv <= 1'b1; end
					ws <= W_IDLE;
				end
			end
			default: ws <= W_IDLE;
			endcase
			if (have) begin
				have <= 1'b0;
				if (!(we && widx == 3'd1 && start_valid))                 // (unless CURRENT is moving to a new START)
					cmd_end <= current + {16'd0, cmd_len(cmd[61:56]), 3'b000};
				if (cmd[61:56] == 6'h29) begin irq <= 1'b1; start_gclk <= 1'b0; end      // SYNC_FULL
			end
		end
	end
endmodule

`default_nettype wire
