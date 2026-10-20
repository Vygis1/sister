//////////////////////////////////////////////////////////////////////////////////
// tb_gba_cart - the Game Boy Advance's memory plumbing as console_top wires it: the cartridge
// through cart_ddr3 + cart_cache, the work RAM through gba_ewram, both on a two-port mem_arb
// in front of a DDR3 model. A fill of 64 bytes, then halfword reads of it (with the byte order
// gba_top applies) and word reads and writes of the work RAM.
//
//   ./tools/sim.sh tb_gba_cart
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_gba_cart;
	reg clk = 0; always #10 clk = ~clk;
	reg rst = 1;
	reg [21:0] host_windex = 0; reg host_we = 0, fill_end = 0; reg [31:0] wdata = 0;
	wire [47:0] pa_addr; wire [1:0] pa_req, pa_we, pa_ready, pa_valid; wire [255:0] pa_wdata, pa_rdata; wire [31:0] pa_wmask;
	wire [23:0] d_addr; wire d_req, d_we; wire [127:0] d_wdata; wire [15:0] d_wmask;
	reg d_ready = 1; reg [127:0] d_rdata = 0; reg d_valid = 0; reg d_calibrated = 0;
	mem_arb #(.PORTS(2), .AW(24)) u_arb (
		.clk(clk), .rst(rst),
		.p_addr(pa_addr), .p_req(pa_req), .p_we(pa_we), .p_wdata(pa_wdata), .p_wmask(pa_wmask),
		.p_ready(pa_ready), .p_rdata(pa_rdata), .p_valid(pa_valid),
		.m_addr(d_addr), .m_req(d_req), .m_we(d_we), .m_wdata(d_wdata), .m_wmask(d_wmask),
		.m_ready(d_ready), .m_rdata(d_rdata), .m_valid(d_valid));
	wire [19:0] h_m_addr; wire h_m_req, h_m_ready, h_m_valid; wire [127:0] h_m_data;
	cart_ddr3 #(.BASE(24'h00_0000)) u_cart (
		.clk(clk), .rst(rst),
		.host_windex(host_windex), .host_we(host_we), .wdata(wdata), .fill_end(fill_end),
		.m_addr(h_m_addr), .m_req(h_m_req), .m_ready(h_m_ready), .m_data(h_m_data), .m_valid(h_m_valid),
		.d_addr(pa_addr[23:0]), .d_req(pa_req[0]), .d_we(pa_we[0]), .d_wdata(pa_wdata[127:0]),
		.d_ready(pa_ready[0]), .d_rdata(pa_rdata[127:0]), .d_valid(pa_valid[0]), .d_calibrated(d_calibrated));
	assign pa_wmask[15:0] = 16'hFFFF;
	reg [24:0] rom_addr = 0; reg rom_req = 0; wire [15:0] c_word; wire c_ack;
	cart_cache #(.IDXBITS(8)) u_cc (.clk(clk), .rst(rst),
		.a_addr(rom_addr[23:1]), .a_req(rom_req), .a_data(c_word), .a_ack(c_ack),
		.b_addr(23'd0), .b_req(1'b0), .b_data(), .b_ack(),
		.m_addr(h_m_addr), .m_req(h_m_req), .m_ready(h_m_ready), .m_data(h_m_data), .m_valid(h_m_valid),
		.dbg_hits(), .dbg_misses(), .dbg_stall(), .dbg_prefetch());
	reg [16:0] ext_addr = 0; reg ext_req = 0, ext_we = 0; reg [3:0] ext_be = 0; reg [31:0] ext_wdata = 0; wire ext_ack; wire [31:0] ext_rdata;
	gba_ewram #(.BASE(24'h20_0000), .IDXBITS(9)) u_ew (
		.clk(clk), .rst(rst),
		.a_addr(ext_addr), .a_req(ext_req), .a_we(ext_we), .a_be(ext_be), .a_wdata(ext_wdata), .a_ack(ext_ack), .a_rdata(ext_rdata),
		.m_addr(pa_addr[47:24]), .m_req(pa_req[1]), .m_we(pa_we[1]), .m_wdata(pa_wdata[255:128]), .m_wmask(pa_wmask[31:16]),
		.m_ready(pa_ready[1]), .m_rdata(pa_rdata[255:128]), .m_valid(pa_valid[1]));
	// the DDR3: lines, a little latency, a byte mask
	reg [127:0] mem [0:(1<<22)-1];
	reg [23:0] rd_a; reg rd_busy = 0; integer rd_wait = 0, i;
	always @(posedge clk) begin
		d_valid <= 1'b0;
		if (!rst) begin
			if (d_req && d_ready) begin
				$display("  ddr3 %s line %06x mask %04x data %032x", d_we ? "W" : "R", d_addr, d_wmask, d_wdata);
				if (d_we) begin for (i = 0; i < 16; i = i + 1) if (d_wmask[i]) mem[d_addr[21:0]][i*8 +: 8] <= d_wdata[i*8 +: 8]; end
				else begin rd_a <= d_addr; rd_busy <= 1'b1; rd_wait <= 3; end
			end
			if (rd_busy) begin
				if (rd_wait > 0) rd_wait <= rd_wait - 1;
				else begin d_rdata <= mem[rd_a[21:0]]; d_valid <= 1'b1; rd_busy <= 1'b0; end
			end
		end
	end
	integer k, t, fails = 0;
	reg [15:0] got;
	task romrd; input [24:0] a; begin
		@(negedge clk); rom_addr = a; rom_req = 1; t = 0;
		while (!c_ack && t < 2000) begin @(posedge clk); t = t + 1; end
		got = {c_word[7:0], c_word[15:8]}; @(negedge clk); rom_req = 0; @(posedge clk);
	end endtask
	task extacc; input [16:0] a; input we; input [3:0] be; input [31:0] d; begin
		@(negedge clk); ext_addr = a; ext_we = we; ext_be = be; ext_wdata = d; ext_req = 1; t = 0;
		@(posedge clk);
		while (!ext_ack && t < 2000) begin @(posedge clk); t = t + 1; end
		@(negedge clk); ext_req = 0; @(posedge clk);
	end endtask
	initial begin
		for (k = 0; k < 4096; k = k + 1) mem[k] = 0;
		repeat (5) @(posedge clk); rst = 0; d_calibrated = 1; repeat (5) @(posedge clk);
		// a fill: words 0..15 = 0x03020100 + 4k (little-endian bytes k.. as the loader streams them)
		for (k = 0; k < 16; k = k + 1) begin host_windex = k; wdata = 32'h03020100 + k * 32'h04040404; host_we = 1; @(posedge clk); host_we = 0; @(posedge clk); end
		fill_end = 1; @(posedge clk); fill_end = 0; repeat (60) @(posedge clk);
		romrd(25'd0); $display("rom halfword 0: %04x (want 0100) in %0d clocks", got, t); if (got !== 16'h0100) fails = fails + 1;
		romrd(25'd2); $display("rom halfword 2: %04x (want 0302) in %0d clocks", got, t); if (got !== 16'h0302) fails = fails + 1;
		romrd(25'd20); $display("rom halfword 20: %04x (want 1514) in %0d clocks", got, t); if (got !== 16'h1514) fails = fails + 1;
		romrd(25'd40); $display("rom halfword 40: %04x (want 2928) in %0d clocks", got, t); if (got !== 16'h2928) fails = fails + 1;
		extacc(17'd5, 1, 4'hF, 32'hDEADBEEF); $display("ewram write in %0d clocks", t);
		extacc(17'd5, 1, 4'h2, 32'h00005500); $display("ewram byte write in %0d clocks", t);
		extacc(17'd5, 0, 4'h0, 0); $display("ewram word 5: %08x (want dead55ef) in %0d clocks", ext_rdata, t); if (ext_rdata !== 32'hdead55ef) fails = fails + 1;
		extacc(17'd6, 0, 4'h0, 0); $display("ewram word 6: %08x (want 0) in %0d clocks", ext_rdata, t); if (ext_rdata !== 32'h0) fails = fails + 1;
		extacc(17'h10003, 1, 4'h1, 32'h000000A5); extacc(17'h10003, 0, 4'h0, 0); $display("sram word: %08x (want a5)", ext_rdata); if (ext_rdata[7:0] !== 8'hA5) fails = fails + 1;
		if (fails == 0) $display("tb_gba_cart: all checks passed"); else $display("*** tb_gba_cart: %0d failures", fails);
		$finish;
	end
endmodule
