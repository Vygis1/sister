`default_nettype none
`timescale 1ns/1ps
module tb_ps1_fill;
	reg clk=0, rst=1; always #10 clk=~clk;
	reg sel=0, we=0, a4=0; reg [31:0] wdata=0; wire [31:0] rdata;
	wire [28:0] v_addr,s_addr; wire v_req,v_we,s_req; wire [3:0] v_be;
	wire [31:0] v_wdata,v_rdata,s_rdata; wire v_ack,s_ack;
	wire v_lwe; wire [127:0] v_wdata128;
	wire [127:0] v_line;
	wire px_valid; wire [8:0] px_x,px_y; wire [7:0] px_rgb; wire vblank,hblank,dot_ce,irq;
	wire v_lin_w, g_lin_w;
	ps1_gpu gpu ( .every_flip(1'b0), .v_lin(v_lin_w),.clk(clk),.rst(rst),.sel(sel),.we(we),.a4(a4),.dma_active(1'b0),.cap_every_vsync(1'b0), .gpu_fast(1'b1),.wdata(wdata),.rdata(rdata),
		.dma_wr(1'b0),.dma_data(32'd0),.dma_ready(),.dma_rd(1'b0),.dma_rdata(),.dma_rvalid(),
		.v_addr(v_addr),.v_req(v_req),.v_we(v_we),.v_be(v_be),.v_wdata(v_wdata),.v_rdata(v_rdata),.v_line(v_line),.v_ack(v_ack),
		.v_lwe(v_lwe),.v_wdata128(v_wdata128),
		.s_addr(s_addr),.s_req(s_req),.s_rdata(s_rdata),.s_ack(s_ack),
		.scan_lines(1'b0), .tx_valid(1'b0), .tx_addr(25'd0), .tx_line(128'd0),.fl_valid(),.fl_data(),.fl_x(),.fl_y(),
		.px_valid(px_valid),.px_x(px_x),.px_y(px_y),.px_rgb(px_rgb),
		.vblank(vblank),.hblank(hblank),.dot_ce(dot_ce),.irq(irq));
	wire [23:0] m_addr; wire m_req,m_we; wire [127:0] m_wdata;
	reg m_ready; reg [127:0] m_rdata=0; reg m_valid=0; wire [31:0] hits,misses;
	// the engine's writes go to the block writer, its reads on to the cache
	wire [28:0]  gp_addr; wire gp_req, gp_around, gp_ack; wire [31:0] gp_rdata; wire [127:0] gp_line;
	wire [23:0]  bk_addr, vc_addr; wire bk_req, bk_we, bk_ready, vc_req, vc_we, vc_ready, vc_valid; wire [127:0] bk_wdata, vc_wdata, vc_rdata; wire [15:0] bk_wmask, vc_wmask;
	wire         inv_v; wire [24:0] inv_line; wire bk_busy;
	ps1_vram_port vp ( .v_lin(v_lin_w), .g_lin(g_lin_w),
		.clk(clk), .rst(rst),
		.v_addr(v_addr), .v_req(v_req), .v_we(v_we), .v_be(v_be), .v_wdata(v_wdata), .v_lwe(v_lwe), .v_wdata128(v_wdata128), .v_around(1'b0),
		.v_rdata(v_rdata), .v_line(v_line), .v_ack(v_ack), .eng_idle(!gpu.busy), .host_flush(1'b0), .busy(bk_busy),
		.g_addr(gp_addr), .g_req(gp_req), .g_around(gp_around), .g_rdata(gp_rdata), .g_line(gp_line), .g_ack(gp_ack),
		.m_addr(bk_addr), .m_req(bk_req), .m_we(bk_we), .m_wdata(bk_wdata), .m_wmask(bk_wmask), .m_ready(bk_ready),
		.inv_v(inv_v), .inv_line(inv_line));
	wire [1:0] p_ready, p_valid; wire [255:0] p_rdata;
	assign bk_ready = p_ready[1]; assign vc_ready = p_ready[0]; assign vc_valid = p_valid[0]; assign vc_rdata = p_rdata[127:0];
	mem_arb #(.PORTS(2), .AW(24)) arb (
		.clk(clk), .rst(rst),
		.p_addr({bk_addr, vc_addr}), .p_req({bk_req, vc_req}), .p_we({bk_we, vc_we}), .p_wdata({bk_wdata, vc_wdata}), .p_wmask({bk_wmask, vc_wmask}),
		.p_ready(p_ready), .p_rdata(p_rdata), .p_valid(p_valid),
		.m_addr(m_addr), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata), .m_wmask(m_wmask),
		.m_ready(m_ready), .m_rdata(m_rdata), .m_valid(m_valid));
	wire [15:0] m_wmask;
	ps1_cache #(.IDXBITS(6)) vram(.a_lin(g_lin_w), .clk(clk),
		.b_first(1'b0),.rst(rst),.flush(1'b0),.flush_busy(), .inv_v(inv_v), .inv_line(inv_line),
		.a_addr(gp_addr),.a_req(gp_req), .a_lwe(1'b0), .a_be16(16'd0), .a_wdata128(128'd0),.a_we(1'b0),.a_be(4'hF),.a_wdata(32'd0),.a_rdata(gp_rdata),.a_line(gp_line),.a_ack(gp_ack),
		.b_addr(s_addr),.b_req(s_req),.b_we(1'b0),.b_be(4'hF),.b_wdata(32'd0),.b_rdata(s_rdata),.b_ack(s_ack),
		.m_addr(vc_addr),.m_req(vc_req),.m_we(vc_we),.m_wdata(vc_wdata),.m_wmask(vc_wmask),.m_ready(vc_ready),.m_rdata(vc_rdata),.m_valid(vc_valid),
		.dbg_hits(hits),.dbg_misses(misses));
	reg [127:0] mem [0:65535];
	localparam RD=4; reg [127:0] pd[0:RD-1]; reg pv[0:RD-1]; integer pi;
	always @(*) m_ready=m_req;
	always @(posedge clk) begin
		m_valid<=pv[RD-1]; m_rdata<=pd[RD-1];
		for(pi=RD-1;pi>0;pi=pi-1)begin pv[pi]<=pv[pi-1];pd[pi]<=pd[pi-1];end
		pv[0]<=1'b0;
		if(m_req&&m_ready)begin if(m_we) begin for(pi=0;pi<16;pi=pi+1) if(m_wmask[pi]) mem[m_addr[15:0]][pi*8+:8]<=m_wdata[pi*8+:8]; end else begin pv[0]<=1'b1;pd[0]<=mem[m_addr[15:0]];end end
	end
	function [15:0] vpx; input [9:0] x; input [8:0] y; reg [28:0] a; reg [127:0] l; reg [5:0] ix;
		begin a={y,x[9:1],2'b00}; ix=a[9:4];
			if(vram.valid[ix]&&vram.tag[ix]==a[28:10]) l=vram.data[ix]; else l=mem[a[19:4]];
			vpx = x[0]? l[a[3:2]*32+16+:16] : l[a[3:2]*32+:16]; end
	endfunction
	task gp0; input [31:0] w; begin
		@(negedge clk); while(gpu.f_full)@(negedge clk); sel=1;we=1;a4=0;wdata=w; @(negedge clk); sel=0;we=0;
	end endtask
	task idle; begin @(negedge clk); while(!(gpu.f_empty&&!gpu.busy&&!bk_busy))@(negedge clk); repeat(3)@(negedge clk); end endtask
	integer k,errors=0;
	task chk; input c; input [255:0] m; begin if(c)$display("  ok   %0s",m); else begin $display("  FAIL %0s",m);errors=errors+1;end end endtask
	// how much of the fill went out a whole line at a time
	integer oct_writes = 0, pair_writes = 0, one_writes = 0;
	always @(posedge clk) if (gpu.v_req && gpu.v_we && v_ack) begin
		if (gpu.v_lwe)     oct_writes  = oct_writes + 1;
		else if (v_be == 4'hF) pair_writes = pair_writes + 1;
		else               one_writes  = one_writes + 1;
	end

	// the video cache: how the engine's line writes are actually served
	integer wa_n = 0, alloc_n = 0, wb_n = 0, fill_n = 0, hitw_n = 0;
	reg [3:0] vst_d = 0;
	always @(posedge clk) begin
		vst_d <= vram.st;
		if (vram.st == 4'd15 && vst_d != 4'd15) wa_n = wa_n + 1;      // S_WA
		if (vram.st == 4'd7  && vst_d != 4'd7)  alloc_n = alloc_n + 1; // S_ALLOC
		if (vram.st == 4'd2  && vst_d != 4'd2)  wb_n = wb_n + 1;       // S_WB
		if (vram.st == 4'd4  && vst_d != 4'd4)  fill_n = fill_n + 1;   // S_FILL
	end

	initial begin
		for(k=0;k<65536;k=k+1)mem[k]=128'd0; for(k=0;k<RD;k=k+1)begin pv[k]=0;pd[k]=0;end
		repeat(4)@(posedge clk); rst=0; repeat(4)@(posedge clk);
		gp0(32'hE3000000); gp0(32'hE4000000|319|(239<<10)); gp0(32'hE5000000);
		gp0(32'h02602010); gp0(32'h00000000); gp0((240<<16)|320); idle();
		chk(vpx(100,100)=={1'b0,5'h0C,5'h04,5'h02}, "fill colour at 100,100");
		chk(vpx(0,0)=={1'b0,5'h0C,5'h04,5'h02}, "fill colour at 0,0");
		chk(vpx(318,239)=={1'b0,5'h0C,5'h04,5'h02}, "fill colour at 318,239");
		// gouraud triangle
		gp0(32'h3000_00FF); gp0((40<<16)|20); gp0(32'h0000FF00); gp0((60<<16)|200);
		gp0(32'h00FF0000); gp0((200<<16)|100); idle();
		chk(vpx(90,90)!={1'b0,5'h0C,5'h04,5'h02} && vpx(90,90)!=0, "triangle drew at 90,90");
		// a small gouraud QUAD (0x38): (10,10)(80,10)(10,80)(80,80)
		gp0(32'h380000FF); gp0((10<<16)|10); gp0(32'h0000FF00); gp0((10<<16)|80);
		gp0(32'h00FF0000); gp0((80<<16)|10); gp0(32'h00FFFFFF); gp0((80<<16)|80); idle();
		chk(vpx(20,20)!=0, "quad tri-1 drew at 20,20");
		chk(vpx(70,70)!=0, "quad tri-2 drew at 70,70");
		// --- a flat opaque quad, which is what a screen clear is ------------------
		// The BIOS clears the screen with one of these every frame, 640x480, and
		// at two pixels a clock that took 119% of a frame -- the engine could
		// never catch up and the picture could never be still. A flat span has
		// the same colour in all eight pixels of a VRAM line, so it goes out as
		// one 16-byte write. This checks the pixels are right AND that the fast
		// path was actually taken, because falling back to the slow one is
		// invisible in the picture and was exactly the bug that wasted a build.
		oct_writes = 0; pair_writes = 0; one_writes = 0;
		gp0(32'h28204060); gp0((16<<16)|16);  gp0((16<<16)|304);
		gp0((224<<16)|16);  gp0((224<<16)|304); idle();
		chk(vpx(20,20)  == {1'b0,5'h04,5'h08,5'h0C}, "flat quad colour at 20,20");
		chk(vpx(160,120)== {1'b0,5'h04,5'h08,5'h0C}, "flat quad colour in the middle");
		chk(vpx(300,220)== {1'b0,5'h04,5'h08,5'h0C}, "flat quad colour near the far corner");
		chk(vpx(8,8)    != {1'b0,5'h04,5'h08,5'h0C}, "and nothing outside it");
		$display("    flat quad: %0d whole-line writes (%0d px), %0d pairs, %0d singles",
		  oct_writes, oct_writes*8, pair_writes, one_writes);
		chk(pair_writes > 20000, "most of a flat quad goes out two pixels at a time");

		$display("  quad: (20,20)=%04h (70,70)=%04h (45,45)=%04h  hits=%0d misses=%0d",
		  vpx(20,20), vpx(70,70), vpx(45,45), hits, misses);
		$display("    writes: %0d whole lines (%0d px), %0d pairs, %0d singles",
		  oct_writes, oct_writes*8, pair_writes, one_writes);
		$display("    video cache: write-around %0d, allocate %0d, write-back %0d, fill %0d", wa_n, alloc_n, wb_n, fill_n);
		// ps1-tests gpu/triangle clears VRAM with four 512x256 fills; on the board the
		// bottom-right one (512,256) never landed
		gp0(32'h02ffffff); gp0(32'h00000000); gp0(32'h01000200);
		gp0(32'h02ffffff); gp0(32'h00000200); gp0(32'h01000200);
		gp0(32'h02ffffff); gp0(32'h01000000); gp0(32'h01000200);
		gp0(32'h02ffffff); gp0(32'h01000200); gp0(32'h010003f1); idle();   // (the test's own width: 1009 -> 1024)
		chk(vpx(5,5)     == 16'h7fff, "quarter fill top-left");
		chk(vpx(1000,10) == 16'h7fff, "quarter fill top-right");
		chk(vpx(5,300)   == 16'h7fff, "quarter fill bottom-left");
		chk(vpx(600,300) == 16'h7fff, "quarter fill bottom-right");
		chk(vpx(1023,511)== 16'h7fff, "quarter fill last pixel");
		// lines (ps1-tests gpu/lines): a flat horizontal and a shaded diagonal
		gp0(32'hE3000000); gp0(32'hE4000000|1023|(511<<10)); gp0(32'hE5000000);
		gp0(32'h40000000); gp0((300<<16)|16); gp0((300<<16)|60); idle();
		$display("    line: lst=%0d ds=%0d px=%0d py=%0d lk=%0d", gpu.lst, gpu.ds, gpu.px, gpu.py, gpu.lk);
		chk(vpx(30,300) == 16'h0000, "flat line pixel");
		gp0(32'h50000000); gp0((310<<16)|16); gp0(32'h000000FF); gp0((330<<16)|56); idle();
		$display("    shaded: %04h %04h %04h", vpx(16,310), vpx(36,320), vpx(56,330));
		chk(vpx(56,330)[4:0] > 5'd25 && vpx(16,310)[4:0] < 5'd3, "shaded line ends");
		if(errors==0)$display("tb_ps1_fill: all passed"); else $display("tb_ps1_fill: %0d FAIL",errors);
		$finish;
	end
endmodule
`default_nettype wire
