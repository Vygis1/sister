`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_a26 - run a cartridge on the Atari 2600 and look at what it draws.
//
// Loads sim/roms/a2600/test.hex (made by tools/a26/rom2hex.py) into the console's
// cartridge RAM, runs FRAMES frames (plusarg, default 4), writes the last one to
// frame.ppm in the bench's build directory and prints what every frame should
// have: 262 lines, a WSYNC count, the visible line span.
//
// When the config file's gate flag is set the image is tools/a26/kernels/test.asm
// and the bench knows the picture it must draw and the values it must leave in
// RAM: the playfield pattern, two players, a missile and a ball at the pixels the
// console's positioning rules put them, the RIOT timer's countdown, the switch
// and button reads, and the collision latches. Those checks are the gate; the
// picture is for eyes.
//
// The clock here is one colour clock per clock (CLK_HZ = PIX_HZ): what matters
// is the 3:1 ratio inside the console, not the rate.
//////////////////////////////////////////////////////////////////////////////////

module tb_a26;

	localparam integer MAX_CLKS = 200_000_000;

	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg  [15:0] rom_len = 16'd4096;
	reg  [3:0]  scheme  = 4'd0;
	reg         gate    = 1'b0;

	// player 0 holds up and fire for the whole run; the kernel reads them into RAM
	reg  [7:0]  joy0 = 8'b0001_0001;
	reg  [7:0]  joy1 = 8'h00;

	wire        pix_ce, pixel_en, frame_start, line_end, vblank, vsync;
	wire [7:0]  px_x;
	wire [8:0]  line;
	wire [6:0]  color;
	wire signed [15:0] audio_l, audio_r;
	wire [15:0] dbg_pc;
	wire        dbg_sync, dbg_rdy;

	a26_top #(.CLK_HZ(3_579_545), .PIX_HZ(3_579_545)) dut (
		.clk(clk), .rst(rst),
		.rom_wr(1'b0), .rom_wr_addr(15'd0), .rom_wr_data(8'd0),
		.rom_len(rom_len), .scheme(scheme),
		.joy0(joy0), .joy1(joy1),
		.sw_reset(1'b0), .sw_select(1'b0), .sw_color(1'b1), .sw_diff0(1'b0), .sw_diff1(1'b0),
		.paddle(4'd0),
		.pix_ce(pix_ce), .px_x(px_x), .line(line), .color(color), .pixel_en(pixel_en),
		.frame_start(frame_start), .line_end(line_end), .vblank(vblank), .vsync(vsync),
		.audio_l(audio_l), .audio_r(audio_r),
		.dbg_pc(dbg_pc), .dbg_sync(dbg_sync), .dbg_rdy(dbg_rdy)
	);

	// --- the frame ---------------------------------------------------------------
	reg [6:0] fb [0:511][0:159];
	integer   vis_first = 9999, vis_last = -1;
	integer   lines_in_frame = 0, lines_last = 0;
	integer   frames = 0, wsyncs = 0;
	reg       rdy_prev = 1;
	integer   fails = 0;
	integer   target_frames = 4;

	always @(posedge clk) begin
		if (!rst) begin
			if (pixel_en) begin
				fb[line][px_x] <= color;
				if (line < vis_first) vis_first = line;
				if (vis_last < 0 || line > vis_last) vis_last = line;
			end
			if (line_end) lines_in_frame = lines_in_frame + 1;
			rdy_prev <= dbg_rdy;
			if (rdy_prev && !dbg_rdy) wsyncs = wsyncs + 1;
		end
	end

	// --- hang detection: the same opcode address fetched over and over --------------------
	// A kernel that waits on WSYNC or the timer fetches different addresses; one
	// that has trapped itself fetches one. 4000 is far longer than any wait loop.
	localparam TR = 48;
	reg [15:0] tr [0:TR-1];
	integer    ti = 0, same = 0;
	reg [15:0] last_pc = 16'hFFFF;
	reg        hung = 0;
	always @(posedge clk) begin
		if (!rst && dbg_sync && pix_ce) begin
			if (dbg_pc == last_pc) same <= same + 1;
			else begin
				same   <= 0;
				tr[ti] <= dbg_pc;
				ti     <= (ti == TR-1) ? 0 : ti + 1;
			end
			last_pc <= dbg_pc;
			if (same > 4000) hung <= 1;
		end
	end

	// --- audio: output changes per frame, and the swing --------------------------------------
	integer aud_cnt = 0, aud_last = -1, aud_min = 32767, aud_max = -32768;
	reg signed [15:0] aud_prev = 0;
	always @(posedge clk) begin
		if (!rst) begin
			if (frame_start) begin aud_last = aud_cnt; aud_cnt = 0; end
			else if (audio_l != aud_prev) aud_cnt = aud_cnt + 1;
			aud_prev <= audio_l;
			if (frames >= 1) begin
				if (audio_l < aud_min) aud_min = audio_l;
				if (audio_l > aud_max) aud_max = audio_l;
			end
		end
	end

	// --- TRACEn (e.g. TRACE5): VSYNC / VBLANK / WSYNC-free timer writes and reads in frame n ------------
	integer trace_frame = -1;
	always @(posedge clk) begin
		if (!rst && frames == trace_frame && dut.cpu_ce && dut.rdy) begin
			if (dut.cpu_we && dut.sel_tia && dut.cpu_addr[5:0] <= 6'h01)
				$display("  TRACE line %3d clk %3d PC %04X  %s <- %02X", line, dut.u_tia.hcount, dbg_pc,
				         dut.cpu_addr[0] ? "VBLANK" : "VSYNC ", dut.cpu_dout);
			if (dut.cpu_we && dut.sel_io && dut.cpu_addr[2] && dut.cpu_addr[4])
				$display("  TRACE line %3d clk %3d PC %04X  TIM%0dT <- %0d", line, dut.u_tia.hcount, dbg_pc,
				         dut.cpu_addr[1:0] == 0 ? 1 : dut.cpu_addr[1:0] == 1 ? 8 : dut.cpu_addr[1:0] == 2 ? 64 : 1024,
				         dut.cpu_dout);
		end
	end

	// --- opcodes the CPU does not decode ----------------------------------------------------
	// Anything other than $EA that decodes to the CPU's do-nothing default is an
	// instruction this console runs as a 1-byte NOP -- an undocumented opcode a
	// cartridge relies on. Named here because the symptom is otherwise a kernel
	// that silently loses sync.
	integer undecoded = 0;
	always @(posedge clk) begin
		if (!rst && dut.cpu_ce && dut.rdy && dut.u_cpu.t == 6'd3 && dut.u_cpu.IR != 8'hEA
		    && dut.u_cpu.op == 6'd0 && dut.u_cpu.mode == 4'd0) begin
			if (undecoded < 8)
				$display("  WARNING opcode 0x%02X at 0x%04X is not decoded (ran as a NOP)",
				         dut.u_cpu.IR, dut.u_cpu.PC - 16'd1);
			undecoded = undecoded + 1;
		end
	end

	// --- the palette: see tools/a26/ntsc_palette.py -------------------------------------
	function [23:0] palette;
		input [6:0] c;
		reg [23:0] pal;
		begin
		case (c)
		7'd0  : pal = 24'h101010;
		7'd1  : pal = 24'h303030;
		7'd2  : pal = 24'h505050;
		7'd3  : pal = 24'h707070;
		7'd4  : pal = 24'h8F8F8F;
		7'd5  : pal = 24'hAFAFAF;
		7'd6  : pal = 24'hCFCFCF;
		7'd7  : pal = 24'hEFEFEF;
		7'd8  : pal = 24'h222400;
		7'd9  : pal = 24'h424400;
		7'd10 : pal = 24'h626400;
		7'd11 : pal = 24'h828400;
		7'd12 : pal = 24'hA2A400;
		7'd13 : pal = 24'hC1C417;
		7'd14 : pal = 24'hE1E337;
		7'd15 : pal = 24'hFFFF57;
		7'd16 : pal = 24'h440E00;
		7'd17 : pal = 24'h642E00;
		7'd18 : pal = 24'h844E00;
		7'd19 : pal = 24'hA36D00;
		7'd20 : pal = 24'hC38D13;
		7'd21 : pal = 24'hE3AD32;
		7'd22 : pal = 24'hFFCD52;
		7'd23 : pal = 24'hFFED72;
		7'd24 : pal = 24'h5C0000;
		7'd25 : pal = 24'h7C1800;
		7'd26 : pal = 24'h9C3704;
		7'd27 : pal = 24'hBC5724;
		7'd28 : pal = 24'hDC7744;
		7'd29 : pal = 24'hFC9764;
		7'd30 : pal = 24'hFFB784;
		7'd31 : pal = 24'hFFD7A4;
		7'd32 : pal = 24'h670004;
		7'd33 : pal = 24'h870624;
		7'd34 : pal = 24'hA72643;
		7'd35 : pal = 24'hC74663;
		7'd36 : pal = 24'hE66683;
		7'd37 : pal = 24'hFF85A3;
		7'd38 : pal = 24'hFFA5C3;
		7'd39 : pal = 24'hFFC5E3;
		7'd40 : pal = 24'h620045;
		7'd41 : pal = 24'h820065;
		7'd42 : pal = 24'hA21C85;
		7'd43 : pal = 24'hC23CA5;
		7'd44 : pal = 24'hE15BC5;
		7'd45 : pal = 24'hFF7BE4;
		7'd46 : pal = 24'hFF9BFF;
		7'd47 : pal = 24'hFFBBFF;
		7'd48 : pal = 24'h4E007D;
		7'd49 : pal = 24'h6E009D;
		7'd50 : pal = 24'h8E1BBD;
		7'd51 : pal = 24'hAE3BDC;
		7'd52 : pal = 24'hCE5BFC;
		7'd53 : pal = 24'hEE7AFF;
		7'd54 : pal = 24'hFF9AFF;
		7'd55 : pal = 24'hFFBAFF;
		7'd56 : pal = 24'h2F00A1;
		7'd57 : pal = 24'h4F04C1;
		7'd58 : pal = 24'h6F24E1;
		7'd59 : pal = 24'h8F43FF;
		7'd60 : pal = 24'hAF63FF;
		7'd61 : pal = 24'hCF83FF;
		7'd62 : pal = 24'hEEA3FF;
		7'd63 : pal = 24'hFFC3FF;
		7'd64 : pal = 24'h0B00AB;
		7'd65 : pal = 24'h2A14CB;
		7'd66 : pal = 24'h4A34EB;
		7'd67 : pal = 24'h6A54FF;
		7'd68 : pal = 24'h8A74FF;
		7'd69 : pal = 24'hAA94FF;
		7'd70 : pal = 24'hCAB4FF;
		7'd71 : pal = 24'hEAD4FF;
		7'd72 : pal = 24'h000A99;
		7'd73 : pal = 24'h072AB9;
		7'd74 : pal = 24'h274AD9;
		7'd75 : pal = 24'h476AF9;
		7'd76 : pal = 24'h678AFF;
		7'd77 : pal = 24'h86AAFF;
		7'd78 : pal = 24'hA6C9FF;
		7'd79 : pal = 24'hC6E9FF;
		7'd80 : pal = 24'h00216F;
		7'd81 : pal = 24'h00418E;
		7'd82 : pal = 24'h0B61AE;
		7'd83 : pal = 24'h2A80CE;
		7'd84 : pal = 24'h4AA0EE;
		7'd85 : pal = 24'h6AC0FF;
		7'd86 : pal = 24'h8AE0FF;
		7'd87 : pal = 24'hAAFFFF;
		7'd88 : pal = 24'h003433;
		7'd89 : pal = 24'h005453;
		7'd90 : pal = 24'h007473;
		7'd91 : pal = 24'h1B9493;
		7'd92 : pal = 24'h3AB4B2;
		7'd93 : pal = 24'h5AD4D2;
		7'd94 : pal = 24'h7AF4F2;
		7'd95 : pal = 24'h9AFFFF;
		7'd96 : pal = 24'h004100;
		7'd97 : pal = 24'h006111;
		7'd98 : pal = 24'h008131;
		7'd99 : pal = 24'h1AA151;
		7'd100: pal = 24'h3AC170;
		7'd101: pal = 24'h5AE190;
		7'd102: pal = 24'h7AFFB0;
		7'd103: pal = 24'h9AFFD0;
		7'd104: pal = 24'h004600;
		7'd105: pal = 24'h006500;
		7'd106: pal = 24'h098500;
		7'd107: pal = 24'h29A514;
		7'd108: pal = 24'h49C534;
		7'd109: pal = 24'h69E554;
		7'd110: pal = 24'h89FF74;
		7'd111: pal = 24'hA9FF94;
		7'd112: pal = 24'h004000;
		7'd113: pal = 24'h056000;
		7'd114: pal = 24'h258000;
		7'd115: pal = 24'h45A000;
		7'd116: pal = 24'h64C008;
		7'd117: pal = 24'h84DF28;
		7'd118: pal = 24'hA4FF48;
		7'd119: pal = 24'hC4FF68;
		7'd120: pal = 24'h083200;
		7'd121: pal = 24'h285200;
		7'd122: pal = 24'h487200;
		7'd123: pal = 24'h689100;
		7'd124: pal = 24'h88B100;
		7'd125: pal = 24'hA8D115;
		7'd126: pal = 24'hC8F134;
		7'd127: pal = 24'hE7FF54;
		default: pal = 24'h000000;
		endcase
		palette = pal;
		end
	endfunction

	// --- checks ---------------------------------------------------------------------------
	task check8;
		input [255:0] what;
		input [7:0]   got;
		input [7:0]   want;
		begin
			if (got !== want) begin
				$display("  FAIL %0s: got 0x%02X, want 0x%02X", what, got, want);
				fails = fails + 1;
			end
		end
	endtask

	task checkpix;
		input integer y;
		input integer x;
		input [6:0]   want;
		begin
			if (fb[y][x] !== want) begin
				$display("  FAIL pixel line %0d x %0d: colour 0x%02X, want 0x%02X", y, x, fb[y][x], want);
				fails = fails + 1;
			end
		end
	endtask

	// the colours the kernel uses, as the 7-bit output carries them (byte >> 1)
	localparam [6:0] C_BK = 7'h00, C_P0 = 7'h23, C_P1 = 7'h43, C_PF = 7'h64;

	// A playfield of PF0=$F0 PF1=$55 PF2=$00, repeated: which 4-pixel cells are lit.
	function pf_lit;
		input integer x;
		integer c4;
		begin
			c4 = (x % 80) / 4;
			if (c4 < 4)         pf_lit = 1;
			else if (c4 < 12)   pf_lit = ((8'h55 >> (11 - c4)) & 1) != 0;
			else                pf_lit = 0;
		end
	endfunction

	integer x, y, cfg, tmp, f, n;
	reg [23:0] rgb;
	reg [6:0] want;

	task gate_checks;
		begin
			$display("  gate: checking the picture and the RAM the kernel left");
			if (lines_last != 262) begin
				$display("  FAIL lines per frame: %0d, want 262", lines_last); fails = fails + 1;
			end
			if (vis_last - vis_first + 1 != 192) begin
				$display("  FAIL visible lines: %0d, want 192", vis_last - vis_first + 1); fails = fails + 1;
			end
			// every pixel of three lines across the picture
			for (n = 0; n < 3; n = n + 1) begin
				y = vis_first + 10 + n * 85;
				for (x = 0; x < 160; x = x + 1) begin
					want = pf_lit(x) ? C_PF : C_BK;
					if (x >= 3 && x <= 10)  want = C_P0;      // player 0, solid, at 3
					if (x == 39)            want = C_P0;      // missile 0
					if (x == 80 || x == 87) want = C_P1;      // player 1, $81, at 80
					if (x == 99)            want = C_PF;      // the ball wears the playfield colour
					checkpix(y, x, want);
				end
			end
			// RAM: the timer (values from the 6532 datasheet's rule, worked in
			// test.asm), the inputs, the collisions
			check8("$80 INTIM 4 cycles after TIM8T=5",  dut.u_riot.ram[7'h00], 8'h04);
			check8("$81 INTIM 17 cycles after",         dut.u_riot.ram[7'h01], 8'h02);
			check8("$82 polls until the flag",          dut.u_riot.ram[7'h02], 8'h03);
			check8("$83 INTIM after underflow",         dut.u_riot.ram[7'h03], 8'hF0);
			check8("$84 TIMINT after the INTIM read",   dut.u_riot.ram[7'h04], 8'h00);
			check8("$90 CXP0FB: player 0 on playfield", dut.u_riot.ram[7'h10], 8'h82);
			check8("$91 CXBLPF: ball clear of it",      dut.u_riot.ram[7'h11], 8'h06);
			check8("$92 CXPPMM: no player collision",   dut.u_riot.ram[7'h12], 8'h07);
			check8("$93 CXP0FB after CXCLR",            dut.u_riot.ram[7'h13], 8'h02);
			check8("$94 SWCHA with P0 up held",         dut.u_riot.ram[7'h14], 8'hEF);
			check8("$95 INPT4 with fire held",          dut.u_riot.ram[7'h15], 8'h0C);
			check8("$96 SWCHB colour, nothing pressed", dut.u_riot.ram[7'h16], 8'h0B);
			if (aud_last != 131) begin
				$display("  FAIL audio: %0d output changes in the last frame, want 131", aud_last); fails = fails + 1;
			end
			if (aud_min != -15360 || aud_max != 0) begin
				$display("  FAIL audio swing %0d..%0d, want -15360..0 (one channel at volume 15)", aud_min, aud_max);
				fails = fails + 1;
			end
			if (audio_r != audio_l) begin
				$display("  FAIL audio: left and right differ"); fails = fails + 1;
			end
			check8("$97 frames the kernel counted",     dut.u_riot.ram[7'h17], target_frames[7:0]);
		end
	endtask

	task write_ppm;
		begin
			f = $fopen("frame.ppm", "w");
			$fwrite(f, "P3\n160 %0d\n255\n", vis_last - vis_first + 1);
			for (y = vis_first; y <= vis_last; y = y + 1) begin
				for (x = 0; x < 160; x = x + 1) begin
					rgb = palette(fb[y][x]);
					$fwrite(f, "%0d %0d %0d ", rgb[23:16], rgb[15:8], rgb[7:0]);
				end
				$fwrite(f, "\n");
			end
			$fclose(f);
			$display("  frame.ppm: 160 x %0d, lines %0d..%0d", vis_last - vis_first + 1, vis_first, vis_last);
		end
	endtask

	// --- run -----------------------------------------------------------------------------------
	integer i, dots = 0;
	reg [31:0] plus;
	initial begin
		for (y = 0; y < 512; y = y + 1) for (x = 0; x < 160; x = x + 1) fb[y][x] = 7'd0;
		$readmemh("../../sim/roms/a2600/test.hex", dut.rom);
		cfg = $fopen("../../sim/roms/a2600/test_cfg.txt", "r");
		if (cfg) begin
			tmp = $fscanf(cfg, "%d", rom_len);
			tmp = $fscanf(cfg, "%d", scheme);
			tmp = $fscanf(cfg, "%d", gate);
			if ($fscanf(cfg, "%d", tmp) == 1) target_frames = tmp;
			$fclose(cfg);
		end
		if ($value$plusargs("FRAMES%d", plus)) target_frames = plus;
		if ($value$plusargs("TRACE%d", plus)) trace_frame = plus;

		$display("tb_a26");
		$display("  cartridge %0d bytes, scheme %0d, gate %0d, %0d frames", rom_len, scheme, gate, target_frames);

		repeat (8) @(posedge clk);
		rst = 0;

		fork
			begin : run
				// frames are counted at VSYNC; the first VSYNC starts frame 1
				while (frames < target_frames + 1) begin
					@(posedge clk);
					if (frame_start) begin
						frames = frames + 1;
						lines_last = lines_in_frame;
						lines_in_frame = 0;
						if (frames > 1)
							$display("  frame %0d: %0d lines, %0d WSYNCs so far, visible %0d..%0d",
							         frames - 1, lines_last, wsyncs, vis_first, vis_last);
						if (frames <= target_frames) begin
							// the frame about to be drawn is the one kept
							vis_first = 9999; vis_last = -1;
						end
					end
				end
				$display("  lines per frame: %0d (expect 262)", lines_last);
				$display("  WSYNC count: %0d", wsyncs);
				if (undecoded) $display("  undecoded opcodes executed: %0d", undecoded);
				$display("  audio: %0d output changes in the last frame, swing %0d..%0d", aud_last, aud_min, aud_max);
				if (vis_last >= vis_first) write_ppm;
				else $display("  no visible pixels were produced");
				if (gate) gate_checks;
				if (fails == 0) $display("tb_a26: all checks passed");
				else            $display("tb_a26: %0d FAIL(s)", fails);
				$finish;
			end
			begin : progress
				forever begin
					repeat (2_000_000) @(posedge clk);
					$display("  %0d frames, PC=0x%04X, line %0d, bank %0d", frames, dbg_pc, line, dut.bank);
				end
			end
			begin : hangwatch
				wait (hung);
				$display("  the processor is looping at 0x%04X after %0d frames; recent fetches:", last_pc, frames);
				for (i = 0; i < TR; i = i + 1) begin
					$write(" %04X", tr[(ti + i) % TR]);
					if (i % 12 == 11) $display("");
				end
				$display("tb_a26: FAIL (hung)");
				$finish;
			end
			begin : limit
				repeat (MAX_CLKS) @(posedge clk);
				$display("  TIMEOUT after %0d frames, PC=0x%04X", frames, dbg_pc);
				$display("tb_a26: FAIL (timeout)");
				$finish;
			end
		join
	end

endmodule
