//////////////////////////////////////////////////////////////////////////////////
// tb_nes_smb - Super Mario Bros.' title screen, with the board's memory timing.
//
// tb_nes runs a dot every clock against tile ROM that answers at once. The board
// is neither: a dot every ~9 clocks, and cart_mem answers a clock after it is
// addressed. That difference hid a $2007 read that took its byte from the wrong
// memory (nes.v, vram_chr_q). SMB copies its title screen out of tile ROM through
// $2007, so the title text in the name table is the check: "1 PLAYER GAME" in
// SMB's tile numbers ('0'-'9' 00-09, 'A'-'Z' 0A-23, space 24).
//
//   ./tools/sim.sh tb_nes_smb        (needs build/smb_prg.hex, build/smb_chr.hex)
//////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps

module tb_nes_smb;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;
	reg [3:0] div = 0;
	always @(posedge clk) div <= (div == 4'd8) ? 4'd0 : div + 4'd1;
	wire ce = (div == 4'd8);

	wire [17:0] prg_addr; wire [16:0] chr_addr;
	reg  [7:0]  prg_q, chr_q;
	wire [8:0]  px, py; wire pixel_en, frame_start; wire [5:0] color;
	nes dut (
		.clk(clk), .rst(rst), .ce(ce),
		.prg_addr(prg_addr), .prg_din(prg_q), .chr_addr(chr_addr), .chr_din(chr_q),
		.mapper_id(4'd0), .hdr_mirror_v(1'b1), .prg_last(6'd1),
		.chr_dout(), .chr_we(), .chr_is_ram(1'b0), .joy1(8'h00), .joy2(8'h00),
		.px(px), .py(py), .pixel_en(pixel_en), .color(color), .frame_start(frame_start),
		.dbg_pc(), .dbg_sync()
	);
	// both answer a clock after they are addressed, as cart_mem does
	reg [7:0] prg [0:32767]; reg [7:0] chr [0:8191];
	always @(posedge clk) begin prg_q <= prg[prg_addr[14:0]]; chr_q <= chr[chr_addr[12:0]]; end

	reg [7:0] want [0:12];
	integer frames = 0, i, k, hit, fails = 0;
	always @(posedge clk) if (frame_start && ce) frames = frames + 1;
	initial begin
		$readmemh("../../build/smb_prg.hex", prg);
		$readmemh("../../build/smb_chr.hex", chr);
		// "1 PLAYER GAME"
		want[0] = 8'h01; want[1] = 8'h24; want[2] = 8'h19; want[3] = 8'h15; want[4] = 8'h0A; want[5] = 8'h22;
		want[6] = 8'h0E; want[7] = 8'h1B; want[8] = 8'h24; want[9] = 8'h10; want[10] = 8'h0A; want[11] = 8'h16; want[12] = 8'h0E;
		repeat (20) @(posedge clk); rst = 0;
		wait (frames >= 40);
		hit = -1;
		for (i = 0; i < 2048 - 13; i = i + 1) begin
			k = 0;
			while (k < 13 && dut.vram_nt[i + k] == want[k]) k = k + 1;
			if (k == 13) hit = i;
		end
		if (hit >= 0) $display("tb_nes_smb: \"1 PLAYER GAME\" in the name table at $%03x", hit);
		else begin
			fails = 1;
			$display("tb_nes_smb: FAIL -- \"1 PLAYER GAME\" is not in the name table; the rows that are not blank:");
			for (i = 0; i < 2048; i = i + 32) begin
				k = 0; for (hit = 0; hit < 32; hit = hit + 1) if (dut.vram_nt[i + hit] != 8'h24) k = 1;
				if (k) begin $write("  $%03x:", i); for (hit = 0; hit < 32; hit = hit + 1) $write(" %02x", dut.vram_nt[i + hit]); $display(""); end
			end
		end
		if (!fails) $display("=== tb_nes_smb passed ===");
		$finish;
	end
endmodule

`default_nettype wire
