// tb_snes_cpu.v - the 5A22 (rtl/wip/snes_cpu.v) running gilyon's cputest on a bare SNES:
// LoROM from a file, 128 kB of work RAM, the frame timer, and the PPU's VRAM data port
// ($2118) caught as the text the ROM writes. Passes when "Success" is written.
//
//   ./tools/simwip.sh tb_snes_cpu          (+ROM=... picks another ROM; basic by default)
`timescale 1ns/1ps
`default_nettype none
module tb_snes_cpu;
	reg clk = 0, rst = 1;
	always #5 clk = ~clk;
	wire mce = 1'b1;                       // (the bench's clock is the master clock)

	wire [10:0] h; wire [8:0] v;
	snes_timing u_t (.clk(clk), .rst(rst), .mce(mce), .overscan(1'b0), .h(h), .v(v), .field(),
	                 .vblank(), .hblank(), .line_start(), .frame_start());

	wire req, we, is_b; wire [23:0] addr; wire [7:0] wdata, mdr;
	reg  ack; reg [7:0] rdata;
	snes_cpu dut (.clk(clk), .rst(rst), .mce(mce), .h(h), .v(v), .overscan(1'b0),
	              .req(req), .we(we), .is_b(is_b), .addr(addr), .wdata(wdata), .ack(ack), .rdata(rdata),
	              .mdr(mdr), .pad1(16'h0), .pad2(16'h0), .dbg_pc(), .dbg_pbr());

	reg [7:0] rom [0:524287];
	reg [7:0] wram [0:131071];
	integer romsize, fd, k;
	reg [8*256-1:0] romname;
	reg [7:0] text [0:255];
	integer tn;
	reg [16:0] wa;

	// LoROM: banks 00-7D / 80-FF, $8000-$FFFF; work RAM at 7E-7F and the low 8 kB of 00-3F
	always @(posedge clk) begin
		ack <= 1'b0;
		if (req) begin
			ack <= 1'b1;
			rdata <= mdr;
			if (is_b) begin
				if (we && addr[7:0] == 8'h18) begin text[tn % 256] = wdata; tn = tn + 1; end
			end else if (addr[23:17] == 7'b0111111) begin                     // 7E-7F
				wa = addr[16:0];
				if (we) wram[wa] <= wdata; else rdata <= wram[wa];
			end else if (!addr[22] && addr[15:13] == 3'b000) begin             // low RAM mirror
				wa = {4'd0, addr[12:0]};
				if (we) wram[wa] <= wdata; else rdata <= wram[wa];
			end else if (addr[15]) begin
				if (!we) rdata <= rom[{addr[22:16], addr[14:0]} % romsize];
			end
		end
	end

	function has_success;
		input dummy;
		integer j;
		begin
			has_success = 0;
			for (j = 0; j < 249; j = j + 1)
				if (text[j] == "S" && text[j+1] == "u" && text[j+2] == "c" && text[j+3] == "c" &&
				    text[j+4] == "e" && text[j+5] == "s" && text[j+6] == "s") has_success = 1;
		end
	endfunction
	function has_failed;
		input dummy;
		integer j;
		begin
			has_failed = 0;
			for (j = 0; j < 250; j = j + 1)
				if (text[j] == "F" && text[j+1] == "a" && text[j+2] == "i" && text[j+3] == "l" &&
				    text[j+4] == "e" && text[j+5] == "d") has_failed = 1;
		end
	endfunction

	integer frames;
	integer ntr = 0;
	integer nacc = 0;
	always @(posedge clk) if (!rst && nacc < 0 && (req || ack || dut.c_ce)) begin
		$display("  B t=%0t req %b ack %b we %b addr %06x rdata %02x c_ce %b c_din %02x st %0d", $time, req, ack, we, addr, rdata, dut.c_ce, dut.c_din, dut.u_core.st);
		nacc = nacc + 1;
	end
	always @(posedge clk) if (dut.c_ce && dut.u_core.st == 0 && ntr < 0) begin
		$display("  T %02x:%04x op %02x a %04x x %04x y %04x s %04x p %02x", dut.u_core.PBR, dut.u_core.PC, dut.c_din,
		         dut.u_core.A, dut.u_core.X, dut.u_core.Y, dut.u_core.S, dut.u_core.P);
		ntr = ntr + 1;
	end
	initial begin
		if (!$value$plusargs("ROM=%s", romname)) romname = "../../sim/roms/snes/gilyon/cputest/cputest-basic.sfc";
		fd = $fopen(romname, "rb");
		if (fd == 0) begin $display("tb_snes_cpu: FAIL no ROM"); $finish; end
		romsize = $fread(rom, fd);
		$display("  rom %0d bytes, vector %02x%02x", romsize, rom[32765], rom[32764]);
		$fclose(fd);
		for (k = 0; k < 131072; k = k + 1) wram[k] = 8'h00;
		for (k = 0; k < 256; k = k + 1) text[k] = 8'h00;
		tn = 0; frames = 0;
		repeat (5) @(posedge clk);
		rst = 0;
		forever begin
			@(posedge clk);
			if (h == 0 && v == 0) begin
				frames = frames + 1;
				if (frames % 20 == 0) $display("  frame %0d, pc %02x:%04x, test %02x%02x", frames, dut.dbg_pbr, dut.dbg_pc, wram[17], wram[16]);
			end
			if (has_success(0)) begin $display("tb_snes_cpu: Success after %0d frames (test %02x%02x)", frames, wram[17], wram[16]); $display("tb_snes_cpu: all checks passed"); $finish; end
			if (has_failed(0))  begin $display("tb_snes_cpu: FAIL at test %02x%02x", wram[17], wram[16]); $finish; end
			if (frames > 4000)  begin $display("tb_snes_cpu: TIMED OUT at test %02x%02x", wram[17], wram[16]); $finish; end
		end
	end
endmodule
