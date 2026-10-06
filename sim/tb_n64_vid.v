// tb_n64_vid - n64_vid's picture, frame for frame, against tools/vidref.py's model.
//
// tools/vidref.py gen CASE writes the source lines (sim/vid/img.hex: 512 lines of 128
// 144-bit words) and the settings (sim/vid/cfg.hex); this bench answers the pixel
// side's line requests the way n64_top / fb_ddr do -- late, a word every other clock --
// runs hdmi_tx's counters, and writes the third frame to out.hex; vidref.py check
// compares it with the model. (tools/vidref.py all does every case.)
`timescale 1ns / 1ps

module tb_n64_vid;
	reg clk = 0, pclk = 0;
	always #10 clk = ~clk;          // 50 MHz: the slowest console clock
	always #20 pclk = ~pclk;        // 25 MHz

	reg [143:0] img [0:65535];
	reg [31:0]  cfg [0:7];
	initial begin
		$readmemh("../../sim/vid/img.hex", img);
		$readmemh("../../sim/vid/cfg.hex", cfg);
	end
	wire        ps1    = cfg[0][0];
	wire [11:0] width  = cfg[1][11:0];
	wire [9:0]  height = cfg[2][9:0];
	wire        bpp32  = cfg[3][0];
	wire        hid_ok = cfg[4][0];
	wire [15:0] opt    = cfg[5][15:0];
	wire [16:0] vist   = cfg[6][16:0];
	wire [6:0]  nwords = cfg[7][6:0];

	// hdmi_tx's counters: x, y over the whole frame, req in the picture; rgb wanted a clock later
	reg [9:0] x = 0, y = 0; reg req = 0;
	always @(posedge pclk) begin
		if (x == 799) begin x <= 0; y <= (y == 524) ? 10'd0 : y + 10'd1; end else x <= x + 10'd1;
	end
	always @(*) req = x < 640 && y < 480;

	// the fetcher: on a new want, wait (as DDR3 would), then a word every other clock
	reg        wr_en = 0; reg [8:0] wr_addr = 0; reg [143:0] wr_data = 0;
	wire [8:0] want_n, want_p;
	wire [8:0] want = ps1 ? want_p : want_n;
	reg  [8:0] line = 9'h1FF; reg busy = 0; reg [10:0] dly = 0; reg [6:0] k = 0; reg ph = 0;
	integer seed = 7;
	always @(posedge clk) begin
		wr_en <= 1'b0;
		if (!busy && want != line) begin
			line <= want; busy <= 1'b1; k <= 0; ph <= 0;
			dly <= 11'd200 + ($random(seed) & 11'h1FF);       // 4..14 us before the first word
		end else if (busy) begin
			if (dly != 0) dly <= dly - 11'd1;
			else begin
				ph <= !ph;
				if (ph) begin
					wr_en <= 1'b1; wr_addr <= {line[1:0], k}; wr_data <= img[{line, k}];
					if (k + 7'd1 >= nwords) busy <= 1'b0; else k <= k + 7'd1;
				end
			end
		end
	end

	wire [23:0] rgb_n, rgb_p;
	n64_vid #(.PS1(0)) u_n (.clk(clk), .wr_en(wr_en && !ps1), .wr_addr(wr_addr), .wr_data(wr_data), .want(want_n),
		.width(width), .height(height), .bpp32(bpp32), .on(1'b1), .hid_ok(hid_ok), .vist(vist), .opt(opt),
		.pclk(pclk), .x(x), .y(y), .req(req), .rgb(rgb_n));
	n64_vid #(.PS1(1)) u_p (.clk(clk), .wr_en(wr_en && ps1), .wr_addr(wr_addr), .wr_data(wr_data), .want(want_p),
		.width(width), .height(height), .bpp32(1'b0), .on(1'b1), .hid_ok(1'b0), .vist(17'd0), .opt(opt),
		.pclk(pclk), .x(x), .y(y), .req(req), .rgb(rgb_p));
	wire [23:0] rgb = ps1 ? rgb_p : rgb_n;

	// the third frame out: the pixel asked for at (x, y) comes on the next clock
	integer fd, frame = 0, n = 0;
	reg [9:0] px, py; reg pv = 0;
	reg under = 0;
	always @(posedge pclk) begin
		px <= x; py <= y; pv <= req;
		if (x == 0 && y == 0) frame = frame + 1;
		if (frame == 3 && pv) begin $fwrite(fd, "%06x\n", rgb); n = n + 1; end
		if (frame >= 2 && (ps1 ? u_p.underrun : u_n.underrun)) under = 1;
	end
	initial begin
		fd = $fopen("out.hex", "w");
		wait (frame == 4);
		$fclose(fd);
		if (under) $display("tb_n64_vid: FAIL - a row reader ran out of pixels");
		else if (n != 640 * 480) $display("tb_n64_vid: FAIL - %0d pixels", n);
		else $display("tb_n64_vid: a frame written (%0d pixels), no reader ran dry", n);
		$finish;
	end
	initial begin #60_000_000; $display("tb_n64_vid: TIMEOUT"); $finish; end
endmodule
