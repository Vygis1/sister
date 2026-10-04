//////////////////////////////////////////////////////////////////////////////////
// shell_screen.v - the shell's picture: while the ESP32 installs a core (erase, write,
// read back) the TV says so, with a bar, instead of going dark. Nothing in the console
// images pays for it: the shell is its own bitstream.
//
// The text is osd.v's, its cells filled by a small writer that redraws four lines
// about thirty times a second from what the flash is being asked to do:
//   erase  at offset o: the image reaches at least o + 64 kB (the eraser goes first and
//                       covers the whole image, so its furthest sector is the size)
//   write  at offset o: written to o + 256
//   read   at 2 MB + o: checked to o + 256 (reads are absolute; the slot is at 2 MB)
//   boot:               starting the console
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module shell_screen (
	input  wire        clk,
	input  wire        rst,
	// the flash commands as the shell starts them
	input  wire        op_start,
	input  wire [1:0]  op,                // 1 erase, 2 write, 3 read
	input  wire [22:0] offset,
	input  wire        boot_go,
	// the picture
	input  wire        pclk,
	input  wire [9:0]  x,
	input  wire [9:0]  y,
	output wire [23:0] rgb
);
	// --- progress -------------------------------------------------------------------
	reg [2:0]  phase;                     // 0 idle, 1 erase, 2 write, 3 check, 4 starting
	reg [23:0] size, pos;
	always @(posedge clk) begin
		if (rst) begin phase <= 3'd0; size <= 24'd0; pos <= 24'd0; end
		else if (boot_go) phase <= 3'd4;
		else if (op_start) case (op)
			2'd1: begin
				if (phase != 3'd1) size <= 24'd0;
				phase <= 3'd1;
				if ({1'b0, offset} + 24'h10000 > size) size <= {1'b0, offset} + 24'h10000;
				pos <= {1'b0, offset} + 24'h10000;
			end
			2'd2: begin phase <= 3'd2; pos <= {1'b0, offset} + 24'd256; end
			2'd3: if (offset >= 23'h200000) begin phase <= 3'd3; pos <= {1'b0, offset} - 24'h200000 + 24'd256; end
			default: ;
		endcase
	end

	// --- the lines ---------------------------------------------------------------------
	// line 0 (row 11): FPGA CONSOLE; 1 (row 13): what is happening; 2 (row 15): the step;
	// 3 (row 17): the bar
	function [7:0] ch; input [8*24-1:0] s; input [4:0] len; input [5:0] col; reg [5:0] c0; begin
		c0 = (6'd40 - {1'b0, len}) >> 1;
		if (col >= c0 && col < c0 + len) ch = s[8 * (len - 1 - (col - c0)) +: 8];
		else ch = " ";
	end endfunction

	// --- the writer: one cell a clock, round and round --------------------------------
	reg  [1:0]  line;
	reg  [5:0]  col;
	reg  [28:0] acc;                      // the bar: col * size, against pos * 30
	reg         we;
	reg  [15:0] woff;
	reg  [31:0] wdata;
	reg  [19:0] wait_n;
	reg         ctrl_done;
	wire [4:0]  row = line == 2'd0 ? 5'd11 : line == 2'd1 ? 5'd13 : line == 2'd2 ? 5'd15 : 5'd17;
	wire [10:0] cidx = {row, 5'd0} + {2'd0, row, 3'd0} + {5'd0, col};
	reg  [7:0]  c; reg [1:0] colour; reg hl;
	wire        bar_on = phase >= 3'd1 && phase <= 3'd3;
	wire [28:0] pos30 = pos * 5'd30;
	always @* begin
		c = " "; colour = 2'd0; hl = 1'b0;
		case (line)
		2'd0: begin c = ch("FPGA CONSOLE", 5'd12, col); colour = 2'd1; end
		2'd1: c = (phase == 3'd0) ? ch("READY", 5'd5, col)
		        : (phase == 3'd4) ? ch("STARTING THE CONSOLE", 5'd20, col)
		        :                   ch("SWITCHING CONSOLE", 5'd17, col);
		2'd2: begin
			colour = 2'd2;
			c = (phase == 3'd1) ? ch("erasing the flash", 5'd17, col)
			  : (phase == 3'd2) ? ch("writing the core", 5'd16, col)
			  : (phase == 3'd3) ? ch("checking it", 5'd11, col)
			  :                   " ";
		end
		default: begin
			// 30 cells from column 5: lit (a highlighted space) up to the fraction done
			if (bar_on && col >= 6'd5 && col < 6'd35) begin
				hl = pos30 > acc;
				c = hl ? " " : ".";
				colour = 2'd2;
			end
		end
		endcase
	end
	always @(posedge clk) begin
		we <= 1'b0;
		if (rst) begin line <= 2'd0; col <= 6'd0; acc <= 29'd0; wait_n <= 20'd0; ctrl_done <= 1'b0; end
		else if (!ctrl_done) begin we <= 1'b1; woff <= 16'h0004; wdata <= 32'd1; ctrl_done <= 1'b1; end
		else if (wait_n != 20'd0) wait_n <= wait_n - 20'd1;
		else begin
			we <= 1'b1;
			woff <= 16'h2000 + {3'd0, cidx, 2'b00};
			wdata <= {21'd0, colour, hl, 1'b0, c[6:0]};
			acc <= (col >= 6'd5) ? acc + {5'd0, size} : 29'd0;
			if (col == 6'd39) begin
				col <= 6'd0; acc <= 29'd0;
				if (line == 2'd3) begin line <= 2'd0; wait_n <= 20'hFFFFF; end   // ~20 ms between redraws
				else line <= line + 2'd1;
			end else col <= col + 6'd1;
		end
	end

	osd u_osd (.clk(clk), .rst(rst), .we(we), .off(woff), .wdata(wdata), .rdata(), .err(),
		.pclk(pclk), .x(x), .y(y), .rgb_in(24'd0), .rgb(rgb));
endmodule

`default_nettype wire
