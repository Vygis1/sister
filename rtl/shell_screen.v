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
	// The installer (esp32/console/console.ino installCard) erases the whole image
	// first, then writes it a sector at a time, reading each sector back as it goes
	// and erasing and rewriting one that came back wrong. So: the erases before the
	// first write give the size; after that the bar is the furthest page written, the
	// read-backs and any re-erase change nothing on screen, and two quiet seconds
	// end it. (It used to switch "writing"/"checking" on every op and take the size
	// from whatever had been erased last: with the sector-at-a-time installer it
	// flickered between the two and the bar meant nothing.)
	reg [2:0]  phase;                     // 0 idle, 1 erase, 2 write (and check), 4 starting
	reg [23:0] size, pos;
	reg [26:0] quiet;                     // clocks since the last flash op
	always @(posedge clk) begin
		if (rst) begin phase <= 3'd0; size <= 24'd0; pos <= 24'd0; quiet <= 27'd0; end
		else if (boot_go) phase <= 3'd4;
		else if (op_start) begin
			quiet <= 27'd0;
			case (op)
			2'd1: if (phase == 3'd0 || phase == 3'd4) begin          // a new install
				phase <= 3'd1; size <= {1'b0, offset} + 24'h10000; pos <= 24'd0;
			end else if (phase == 3'd1) begin
				if ({1'b0, offset} + 24'h10000 > size) size <= {1'b0, offset} + 24'h10000;
			end                                                       // (phase 2: a sector redone)
			2'd2: begin
				phase <= 3'd2;
				if ({1'b0, offset} + 24'd256 > pos) pos <= {1'b0, offset} + 24'd256;
			end
			default: ;                                                // (reads: the checking)
			endcase
		end else if (phase != 3'd0 && phase != 3'd4) begin
			if (quiet == 27'd100_000_000) phase <= 3'd0;              // 2 s at 50 MHz
			else quiet <= quiet + 27'd1;
		end
	end

	// --- the screen ---------------------------------------------------------------------
	// As the menu draws its own (esp32/console/menu.h): the header bar (rows 0-2) with the
	// name, the footer bar (27-29), and a framed box (rows 10-18, columns 2-37) saying
	// what is happening (row 12), the step (14) and the bar (16).
	function [7:0] ch; input [8*24-1:0] s; input [4:0] len; input [5:0] col; reg [5:0] c0; begin
		c0 = (6'd40 - {1'b0, len}) >> 1;
		if (col >= c0 && col < c0 + len) ch = s[8 * (len - 1 - (col - c0)) +: 8];
		else ch = " ";
	end endfunction
	function [7:0] at; input [8*24-1:0] s; input [4:0] len; input [5:0] col; input [5:0] c0; begin
		if (col >= c0 && col < c0 + len) at = s[8 * (len - 1 - (col - c0)) +: 8];
		else at = " ";
	end endfunction

	// --- the writer: one cell a clock, the whole screen, round and round -----------------
	reg  [4:0]  row;
	reg  [5:0]  col;
	reg  [28:0] acc;                      // the bar: col * size, against pos * 30
	reg         we;
	reg  [15:0] woff;
	reg  [31:0] wdata;
	reg  [19:0] wait_n;
	reg         ctrl_done;
	wire [10:0] cidx = {row, 5'd0} + {2'd0, row, 3'd0} + {5'd0, col};
	reg  [7:0]  c; reg [1:0] colour; reg hl, bar;
	wire        bar_on = phase == 3'd2;
	wire [28:0] pos30 = pos * 5'd30;
	wire        in_box  = row >= 5'd10 && row <= 5'd18 && col >= 6'd2 && col <= 6'd37;
	wire        box_top = row == 5'd10, box_bot = row == 5'd18, box_l = col == 6'd2, box_r = col == 6'd37;
	always @* begin
		c = " "; colour = 2'd0; hl = 1'b0;
		bar = row <= 5'd2 || row >= 5'd27;
		if (row == 5'd1) begin
			colour = 2'd1;
			c = (col == 6'd2) ? 8'h0F : at("FPGA CONSOLE", 5'd12, col, 6'd4);         // the diamond, the name
		end else if (in_box && (box_top || box_bot || box_l || box_r)) begin
			colour = 2'd2;
			c = (box_top && box_l) ? 8'h01 : (box_top && box_r) ? 8'h02 : (box_bot && box_l) ? 8'h03
			  : (box_bot && box_r) ? 8'h04 : (box_top || box_bot) ? 8'h05 : 8'h06;
		end else if (row == 5'd12) begin
			c = (phase == 3'd0) ? ch("READY", 5'd5, col)
			  : (phase == 3'd4) ? ch("STARTING THE CONSOLE", 5'd20, col)
			  :                   ch("SWITCHING CONSOLE", 5'd17, col);
		end else if (row == 5'd14) begin
			colour = 2'd2;
			c = (phase == 3'd1) ? ch("erasing the flash", 5'd17, col)
			  : (phase == 3'd2) ? ch("writing the core", 5'd16, col)
			  :                   " ";
		end else if (row == 5'd16 && bar_on && col >= 6'd5 && col < 6'd35) begin
			// 30 cells from column 5: lit (a highlighted space) up to the fraction done
			hl = pos30 > acc;
			c = hl ? " " : ".";
			colour = 2'd2;
		end
	end
	always @(posedge clk) begin
		we <= 1'b0;
		if (rst) begin row <= 5'd0; col <= 6'd0; acc <= 29'd0; wait_n <= 20'd0; ctrl_done <= 1'b0; end
		else if (!ctrl_done) begin we <= 1'b1; woff <= 16'h0004; wdata <= 32'd1; ctrl_done <= 1'b1; end
		else if (wait_n != 20'd0) wait_n <= wait_n - 20'd1;
		else begin
			we <= 1'b1;
			woff <= 16'h2000 + {3'd0, cidx, 2'b00};
			wdata <= {20'd0, bar, colour, hl, 1'b0, c[6:0]};
			acc <= (col >= 6'd5) ? acc + {5'd0, size} : 29'd0;
			if (col == 6'd39) begin
				col <= 6'd0; acc <= 29'd0;
				if (row == 5'd29) begin row <= 5'd0; wait_n <= 20'hFFFFF; end    // ~20 ms between redraws
				else row <= row + 5'd1;
			end else col <= col + 6'd1;
		end
	end

	osd u_osd (.clk(clk), .rst(rst), .we(we), .off(woff), .wdata(wdata), .rdata(), .err(),
		.pclk(pclk), .x(x), .y(y), .rgb_in(24'd0), .rgb(rgb));
endmodule

`default_nettype wire
