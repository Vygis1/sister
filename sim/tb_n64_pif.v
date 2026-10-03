//////////////////////////////////////////////////////////////////////////////////
// tb_n64_pif - the PIF's joybus against tools/n64pif.py, case by case.
//
//   python tools/n64pifvec.py 500 > sim/n64/pif_vectors.hex
//   ./tools/sim.sh tb_n64_pif
//
// Each case: the devices, a PIF RAM image written in as the SI's DMA writes it
// (which parses it), a run, and all 64 bytes compared with the model's. The
// EEPROM carries over between cases; at the end all 2 kB of it are compared.
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none

module tb_n64_pif;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg          cpu_we = 0; reg [2:0] cpu_dw = 0; reg [1:0] cpu_wsel = 0; reg [63:0] cpu_wdata = 0;
	wire [511:0] ram_flat;
	reg          dma_we = 0, dma_last = 0; reg [3:0] dma_widx = 0; reg [31:0] dma_wdata = 0;
	reg          go_run = 0;
	wire         busy;
	reg  [31:0]  pad0, pad1, pad2, pad3;
	reg  [3:0]   present;
	reg  [1:0]   size;
	reg          eh_we = 0; reg [10:0] eh_addr = 0; reg [7:0] eh_wdata = 0;
	wire [7:0]   eh_rdata;

	n64_pif dut (
		.clk(clk), .rst(rst),
		.cpu_we(cpu_we), .cpu_dw(cpu_dw), .cpu_wsel(cpu_wsel), .cpu_wdata(cpu_wdata), .ram_flat(ram_flat),
		.dma_we(dma_we), .dma_widx(dma_widx), .dma_wdata(dma_wdata), .dma_last(dma_last),
		.go_run(go_run), .busy(busy),
		.pad0(pad0), .pad1(pad1), .pad2(pad2), .pad3(pad3), .pad_present(present), .eep_size(size),
		.eh_we(eh_we), .eh_addr(eh_addr), .eh_wdata(eh_wdata), .eh_rdata(eh_rdata)
	);

	integer fd, code, n, bad, w, t, b;
	reg [511:0] img, exp;
	reg [16383:0] eep_exp;
	reg [8*8-1:0] tag;
	initial begin
		n = 0; bad = 0;
		fd = $fopen("../../sim/n64/pif_vectors.hex", "r");
		if (fd == 0) begin $display("tb_n64_pif: FAIL no vectors"); $finish; end
		repeat (3) @(posedge clk); rst = 0;
		while (!$feof(fd)) begin
			code = $fscanf(fd, "%h %h %h %h %h %h %h %h\n", pad0, pad1, pad2, pad3, present, size, img, exp);
			if (code == 8) begin
				// the SI's DMA in, a word a clock
				for (w = 0; w < 16; w = w + 1) begin
					@(negedge clk); dma_we = 1; dma_widx = w; dma_wdata = img[511 - 32 * w -: 32]; dma_last = (w == 15);
				end
				@(negedge clk); dma_we = 0; dma_last = 0;
				t = 0; while (busy && t < 2000) begin @(negedge clk); t = t + 1; end
				@(negedge clk); go_run = 1; @(negedge clk); go_run = 0;
				@(negedge clk);
				t = 0; while (busy && t < 4000) begin @(negedge clk); t = t + 1; end
				if (busy || ram_flat !== exp) begin
					bad = bad + 1;
					if (bad <= 10) begin
						$display("MISMATCH case %0d (pads present %h, EEPROM %0d)%s", n, present, size, busy ? " HUNG" : "");
						$display("  in    %h", img);
						$display("  rtl   %h", ram_flat);
						$display("  model %h", exp);
					end
				end
				n = n + 1;
			end else begin
				code = $fscanf(fd, "%s %h\n", tag, eep_exp);
				if (code == 2) begin
					for (b = 0; b < 2048; b = b + 1) begin
						@(negedge clk); eh_addr = b; @(negedge clk); @(negedge clk);
						if (eh_rdata !== eep_exp[16383 - 8 * b -: 8]) begin
							bad = bad + 1;
							if (bad <= 10) $display("MISMATCH EEPROM byte %0d: rtl %02x model %02x", b, eh_rdata, eep_exp[16383 - 8 * b -: 8]);
						end
					end
				end
			end
		end
		if (bad == 0) $display("tb_n64_pif: PASS, %0d cases and the EEPROM agree with the model", n);
		else $display("tb_n64_pif: FAIL, %0d differences in %0d cases", bad, n);
		$finish;
	end
endmodule

`default_nettype wire
