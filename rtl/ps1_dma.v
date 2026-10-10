//////////////////////////////////////////////////////////////////////////////////
// ps1_dma.v - the DMA controller: seven channels at $1F801080, two that matter.
//
// Each channel has three registers at 16-byte spacing:
//
//   +0  MADR   the RAM address
//   +4  BCR    block count and size, meaning depends on the mode
//   +8  CHCR   control: bit 0 direction (1 = from RAM), bit 1 step (1 = MADR
//              decrements), bits 9-10 sync mode, bit 24 start/busy, bit 28
//              manual trigger
//
// and two global ones after them:
//
//   $F0  DPCR   enable and priority per channel
//   $F4  DICR   interrupt enable per channel and the master flag
//
// Sync modes: 0 = all at once (BCR = word count), 1 = blocks (BCR = size |
// count << 16), 2 = linked list, which the GPU uses for display lists: each
// node is a header word with a 24-bit next address and an 8-bit payload size,
// followed by that many words, ending at $FFFFFF.
//
// Channel 2 is the GPU, in both directions. Channel 6 is the ordering table
// clear: writes BCR words BACKWARDS from MADR, each holding the address of the
// one before it, ending in $FFFFFF -- an empty display list ready to be filled.
// The BIOS uses 6 then 2 to draw its screen, so those two are complete. 0 / 1 are the
// MDEC's (ps1_mdec.v), 3 the CD's, 4 the SPU's. The rest (PIO) are registers that finish the moment they start,
// which is enough for the BIOS to believe they exist. Each gets real when the
// device behind it does.
//
// RAM is reached through the cache's second port, so a display list the CPU
// has just written is the one the GPU gets.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module ps1_dma #(
	// the SPU takes its DMA slowly -- a word every ~32 console cycles here (ps1-tests
	// spu/memory-transfer: a 1 kB write must take 1.6k-18k cycles, with the CPU running
	// between); in board clocks
	parameter SPU_GAP = 47,
	// sync mode 1: the console waits ~10 cycles for the device's next request between blocks
	// (ps1-tests dma/chopping: 2048 one-word blocks take 22819 cycles, 2048 words in one 2196)
	parameter BLK_GAP = 15,
	// ...and between the nodes of a linked list (dma/chain-looping): ~13 system clocks
	parameter LL_GAP = 19,
	parameter HDR_HOLD = 9
) (
	input  wire        clk,
	input  wire        rst,

	// the register bus
	input  wire        sel,
	input  wire        we,
	input  wire [7:0]  a,           // $00..$FF
	input  wire [31:0] wdata,
	output reg  [31:0] rdata,

	// RAM, through the cache
	output reg  [28:0] r_addr,
	output reg         r_req,
	output reg         r_we,
	output reg  [31:0] r_wdata,
	output reg         r_lwe,          // a whole line: r_wdata128 under r_be16 (the ordering-table clear)
	output reg  [15:0] r_be16,
	output reg  [127:0] r_wdata128,
	input  wire [31:0] r_rdata,
	input  wire [127:0] r_line,        // the whole line the word came from (a read)
	// a CPU store to RAM: the line in hand is dropped if it is the one stored to (a CPU that
	// rewrites a list while the DMA walks it -- ps1-tests dma/chain-looping breaks a looping
	// chain that way -- was never seen, and the DMA went round the loop for ever)
	input  wire        snoop_v,
	input  wire [23:0] snoop_a,
	input  wire        r_ack,

	// the GPU's command port: one word at a time when it is ready
	output reg         gp0_wr,
	output reg  [31:0] gp0_data,
	input  wire        gp0_ready,
	// and reading VRAM back
	output reg         gpu_rd,
	input  wire [31:0] gpu_rdata,
	// the CD-ROM's data FIFO, a word at a time (channel 3)
	output reg         cd_rd,
	input  wire [31:0] cd_rdata,
	input  wire        cd_rvalid,
	output reg         cd_go,         // channel 3 started: {8'hD3, chcr[27:24], bcr[19:0]} on cd_go_info
	output reg  [31:0] cd_go_info,
	output reg  [15:0] cd_words,      // words channel 3 has written
	input  wire        gpu_rvalid,
	// the SPU's transfer FIFO (channel 4): RAM -> SPU a word at a time when it
	// can take one, and SPU -> RAM for the rare game that reads sound RAM back
	output reg         spu_wr,
	output wire [31:0] spu_data,
	input  wire        spu_ready,
	output reg         spu_rd,
	input  wire [31:0] spu_rdata,
	input  wire        spu_rvalid,
	// the MDEC (channels 0 and 1): a 32-word block each time it asks (dreq), the CPU running in
	// between -- it decodes the next frame's data while the MDEC decodes this one
	output reg         mdec_wr,       // channel 0: gp0_data into the MDEC's input FIFO
	input  wire        mdec_in_ready,
	input  wire        mdec_dreq0,
	output wire        mdec_pop,      // channel 1: the word on mdec_rdata is taken
	input  wire [31:0] mdec_rdata,
	input  wire        mdec_rvalid,
	input  wire        mdec_dreq1,
	input  wire [1:0]  mdec_depth,     // 3 15-bit, 2 24-bit: DMA1 puts the MDEC's 8x8 blocks in rows

	output wire        irq,
	// The chip's DMA owns the bus for a block transfer (sync mode 0, and the
	// ordering-table clear): the CPU does not run until it is done. Without
	// this the BIOS added primitives to an ordering table the clear had not
	// reached yet and linked them through whatever RAM held there.
	output wire        hog,
	output wire        in_flight,   // a transfer is wanted or running, paused on the GPU or not
	output wire        gpu_active,    // a transfer on the GPU channel is queued or running
	// the engine's state, next-pointer and channel-2 busy, for seeing whether a
	// linked list ever ends
	output wire [31:0] dbg_dma,
	output wire [31:0] dbg_mdma,      // (debug) the MDEC channels: busy, parked, sync modes, blocks to go
	output wire [31:0] dbg_madr1,
	// every linked-list node header as it is read: where it was and what it said
	output reg         ll_hdr,        // a list node's header was taken this clock (any node, empty too)
	output reg         dbg_node_v,
	output reg  [23:0] dbg_node_addr,
	output reg  [31:0] dbg_node_hdr
);
	reg [23:0] madr [0:6];
	reg [31:0] bcr  [0:6];
	reg [31:0] chcr [0:6];
	reg [31:0] dpcr, dicr;

	// DICR: 16-22 enable per channel, 23 master enable, 24-30 flags, 31 = master
	// flag = 23 && any of 24-30
	wire [6:0] flags = dicr[30:24];
	wire       master = dicr[23] && (flags != 7'd0);
	assign irq = dicr[15] || master;      // bit 15 forces one; games do not

	wire [2:0] ch  = a[6:4];
	wire [1:0] rg  = a[3:2];
	wire       glob = (a[7:4] == 4'hF);

	// --- the engine ------------------------------------------------------------------
	localparam S_IDLE = 4'd0,  S_PICK = 4'd1,
	           S_RD   = 4'd2,  S_RDW  = 4'd3,  S_GP0 = 4'd4,
	           S_LL   = 4'd5,  S_LLW  = 4'd6,
	           S_OTC  = 4'd7,  S_OTCW = 4'd8,
	           S_CRD  = 4'd13, S_CWR  = 4'd14, S_CWRW = 4'd15,   // the CD-ROM channel
	           S_GRD  = 4'd9,  S_GWR  = 4'd10, S_GWRW = 4'd11,
	           S_DONE = 4'd12;
	reg [3:0]  st;
	reg [2:0]  cur;
	reg [23:0] addr;
	reg [31:0] words;          // left in this block / node
	reg [15:0] blocks;
	reg [23:0] next;           // linked list: the next node
	reg [7:0]  nsize;

	// which channels are asking: enabled in DPCR, started, and (in mode 0)
	// triggered
	reg [6:0] want;
	// the device behind the block paths: the GPU's, on channel 4 the SPU's, on 0 / 1 the MDEC's
	reg  [7:0]  spu_gap;              // the SPU is not ready for the next word until this runs out
	// DMA1's re-ordering (psx-spx): the MDEC sends a colour macroblock as four 8x8 blocks, each
	// row by row; the words land in RAM as 16-pixel rows. Where this word is in its macroblock --
	// block, row of the block, word of the row -- and so where it goes.
	reg  [1:0]  m1b; reg [2:0] m1r, m1w;
	wire        m1_re   = mdec_depth[1];                       // 15- or 24-bit: colour
	wire [2:0]  m1_wpr  = mdec_depth[0] ? 3'd4 : 3'd6;          // words in a block's row: 8 px x 2 or 3 bytes
	wire [3:0]  m1_row  = {m1b[1], m1r};
	wire [7:0]  m1_off  = mdec_depth[0] ? {1'b0, m1_row, m1b[0], m1w[1:0]}                        // row x 8 + col (15-bit)
	                                    : ({4'd0, m1_row} * 8'd12) + (m1b[0] ? 8'd6 : 8'd0) + {5'd0, m1w};   // row x 12 + col (24-bit)
	// the macroblock starts this many words back from the linear address
	wire [8:0]  m1_kk   = mdec_depth[0] ? {2'd0, m1b, m1r, m1w[1:0]} : ({4'd0, m1b, 3'd0} * 9'd6) + ({6'd0, m1r} * 9'd6) + {6'd0, m1w};
	wire [23:0] m1_addr = addr - {13'd0, m1_kk, 2'b00} + {14'd0, m1_off, 2'b00};
	// the last RAM line read, so a run of words costs one read in four: the console moves a word
	// a cycle, and a read a word took us ~3.5 (the same test: 7100 cycles where it takes 2200)
	reg         lb_v; reg [19:0] lb_tag; reg [127:0] lb_data;
	reg  [5:0]  blk_gap;
	reg  [5:0]  hdr_hold;              // the first clocks of a list's gap: the header, the bus still held
	wire        dev_ready  = (cur == 3'd4) ? (spu_ready && spu_gap == 8'd0) : (cur == 3'd0) ? mdec_in_ready : gp0_ready;
	wire        dev_rvalid = (cur == 3'd4) ? spu_rvalid : (cur == 3'd1) ? mdec_rvalid : gpu_rvalid;
	always @(posedge clk)
		if (rst) spu_gap <= 8'd0;
		else if (spu_wr || (st == S_GWRW && r_ack && cur == 3'd4)) spu_gap <= SPU_GAP[7:0];
		else if (spu_gap != 8'd0) spu_gap <= spu_gap - 8'd1;
	wire [31:0] dev_rdata  = (cur == 3'd4) ? spu_rdata  : (cur == 3'd1) ? mdec_rdata : gpu_rdata;
	assign      spu_data   = gp0_data;
	integer k;
	always @(*) begin
		for (k = 0; k < 7; k = k + 1)
			want[k] = dpcr[k*4 + 3] && chcr[k][24]
			          // (a mode-0 channel waits for bit 28 -- except the SPU's and the GPU's, which go
			          // when their device asks, as on the chip and in DuckStation, where the trigger
			          // stands in for a request only on channels with no device behind them:
			          // ps1-tests spu/memory-transfer and dma/chopping start them without it, and
			          // chopping waited here for ever)
			          && (chcr[k][10:9] != 2'd0 || chcr[k][28] || k == 4 || k == 2)
			          // (the MDEC's: only while it asks for a block)
			          && (k != 0 || mdec_dreq0) && (k != 1 || mdec_dreq1);
	end

	integer i;
	reg [23:0] addr_n;
	reg [31:0] wd;                    // the word in hand, before it is pushed
	reg [31:0] otc_n;                 // slots in the ordering-table line being written
	integer    ok;
	reg [23:0] ll_cur, ll_prev1, ll_prev2;   // the list's node now and the two before
	reg        ll_loop;                      // it has come back to one of them
	// A linked list steps aside between nodes for any other channel that wants the bus, MADR at
	// the next node, and is picked up again after it (MiSTer's dma.vhd: every node ends in PAUSING
	// -> OFF and the channels are arbitrated again). Syphon Filter adds a packet to its list twice
	// and the list goes round it for ever; libgpu's ClearOTag then waits on channel 6 -- which
	// never got the bus here, so it timed out for 4 s and the game skipped its title screen.
	reg        ll_park;
	wire       ll_others = (want & 7'b111_1011) != 7'd0;
	// a linked-list node's header: its payload next, or -- an empty node, most of an ordering
	// table -- straight on to the node it points to (by way of S_DONE that was a clock more a node)
	task ll_node; input [31:0] h; reg [23:0] na;
		begin
			// only nodes that carry something are recorded: an ordering table is mostly empty
			// slots, and recording those flushed the trace of the primitives it was there to catch
			dbg_node_v <= (h[31:24] != 8'd0); dbg_node_addr <= addr; dbg_node_hdr <= h;
			ll_hdr <= 1'b1;
			next   <= h[23:0];
			words  <= {24'd0, h[31:24]};
			addr   <= addr + 24'd4;
			blocks <= 16'd1;
			// (an empty node never reads the word after its header as the next node: that walked
			// off the table into whatever RAM followed and fed the GPU garbage for ever)
			if (h[31:24] != 8'd0) st <= S_RD;          // the payload; S_DONE follows the pointer after
			else if (h[23]) st <= S_DONE;              // the end ($FFFFFF: the chip looks at bit 23 alone)
			else begin
				na = {3'd0, h[20:2], 2'b00};
				addr <= na; next <= 24'hFF_FFFF;
				ll_prev2 <= ll_prev1; ll_prev1 <= ll_cur; ll_cur <= na;
				if (na == ll_cur || na == ll_prev1) ll_loop <= 1'b1;
				// a list seen going round: the bus held for the header as long as the console's (~8
				// cycles, HDR_HOLD clocks), then the processor's window (LL_GAP)
				if (ll_loop) begin blk_gap <= LL_GAP[5:0] + HDR_HOLD[5:0]; hdr_hold <= HDR_HOLD[5:0]; end
				st <= S_LL;
				if (ll_others) begin madr[2] <= na; ll_park <= 1'b1; st <= S_IDLE; end   // (see ll_park)
			end
		end
	endtask

	reg [1:0]  m_park;                // channel 0 / 1 stepped aside part way through a block...
	reg [31:0] m_left0, m_left1;      // ...with this many words of it to go
	always @(posedge clk) begin
		if (rst) begin
			for (i = 0; i < 7; i = i + 1) begin
				madr[i] <= 24'd0; bcr[i] <= 32'd0; chcr[i] <= 32'd0;
			end
			dpcr <= 32'h0765_4321; dicr <= 32'd0;
			st <= S_IDLE; cur <= 3'd0;
			r_req <= 1'b0; r_we <= 1'b0; r_lwe <= 1'b0; r_be16 <= 16'd0; r_wdata128 <= 128'd0; otc_n <= 32'd0; gp0_wr <= 1'b0; gpu_rd <= 1'b0; dbg_node_v <= 1'b0; spu_wr <= 1'b0; spu_rd <= 1'b0;
			cd_rd <= 1'b0; cd_go <= 1'b0; cd_go_info <= 32'd0; cd_words <= 16'd0; mdec_wr <= 1'b0;
			lb_v <= 1'b0; blk_gap <= 6'd0; hdr_hold <= 6'd0; ll_hdr <= 1'b0; ll_loop <= 1'b0; ll_cur <= 24'd0; ll_prev1 <= 24'hFF_FFFF; ll_prev2 <= 24'hFF_FFFF; ll_park <= 1'b0; m_park <= 2'b00; m1b <= 2'd0; m1r <= 3'd0; m1w <= 3'd0;
		end else begin
			if (blk_gap != 6'd0) blk_gap <= blk_gap - 6'd1;
			if (hdr_hold != 6'd0) hdr_hold <= hdr_hold - 6'd1;
			ll_hdr <= 1'b0;
			if (r_req && r_we) lb_v <= 1'b0;                 // (a DMA write: the line in hand may be stale)
			if (snoop_v && snoop_a[20:4] == lb_tag[16:0]) lb_v <= 1'b0;   // (2 MB: the CPU may store through a mirror)
			r_req  <= 1'b0;
			gp0_wr <= 1'b0;
			gpu_rd <= 1'b0;
			spu_wr <= 1'b0;
			spu_rd <= 1'b0;
			mdec_wr <= 1'b0;
			cd_rd <= 1'b0;
			cd_go <= 1'b0;
			dbg_node_v <= 1'b0;

			// --- register writes ------------------------------------------------
			if (sel && we) begin
				if (glob) begin
					if (rg == 2'd0) dpcr <= wdata;
					// DICR: flags 24-30 are acknowledged by writing 1
					// (bits 6-14 are not there: they read 0 -- ps1-tests cpu/io-access-bitwidth)
					if (rg == 2'd1) dicr <= {1'b0, dicr[30:24] & ~wdata[30:24], wdata[23:15], 9'd0, wdata[5:0]};
				end else if (ch <= 3'd6) case (rg)
					2'd0: madr[ch] <= wdata[23:0];
					2'd1: bcr[ch]  <= wdata;
					// only the bits the chip keeps (psx-spx, ps1-tests dma/otc-test): channel 6, the
					// ordering-table clear, has only 30, 28 and 24, and always runs backwards (bit 1)
					2'd2: begin
						chcr[ch] <= (ch == 3'd6) ? ((wdata & 32'h5100_0000) | 32'h0000_0002)
						                         : (wdata & 32'h7177_0703);
						if (ch == 3'd1 && wdata[24]) begin m1b <= 2'd0; m1r <= 3'd0; m1w <= 3'd0; end   // a macroblock starts here
						if (ch <= 3'd1) m_park[ch[0]] <= 1'b0;                 // a new transfer: nothing to resume
					end
					default: ;
				endcase
			end

			case (st)
			S_IDLE: begin
					// lowest channel number first is wrong on the real part
					// (DPCR has priorities) but nothing here runs two at once
					// (a list that stepped aside goes after the channel it stepped aside for)
					for (i = 6; i >= 0; i = i - 1)
						if (want[i] && !(i == 2 && ll_park && ll_others)) cur <= i[2:0];
					if (want != 7'd0) st <= S_PICK;
					if (!ll_others) ll_park <= 1'b0;
				end

			S_PICK: begin
					addr <= madr[cur];
					lb_v <= 1'b0;
					ll_cur <= madr[cur]; ll_prev1 <= 24'hFF_FFFF; ll_prev2 <= 24'hFF_FFFF; ll_loop <= 1'b0;
					case (cur)
					3'd2: begin                                     // GPU
						if (chcr[2][10:9] == 2'd2) st <= S_LL;
						else begin
							words  <= (chcr[2][10:9] == 2'd0) ? bwords(bcr[2][15:0])
							                                  : bwords(bcr[2][15:0]);
							blocks <= (chcr[2][10:9] == 2'd0) ? 16'd1 : bcr[2][31:16];
							st <= chcr[2][0] ? S_RD : S_GRD;
						end
					end
					3'd3: begin                                     // CD-ROM -> RAM: BCR words (mode 0) or blocks (mode 1)
						cd_go <= 1'b1; cd_go_info <= {8'hD3, chcr[3][27:24], bcr[3][19:0]};
						words  <= bwords(bcr[3][15:0]);
						blocks <= (chcr[3][10:9] == 2'd0) ? 16'd1 : bcr[3][31:16];
						st <= S_CRD;
					end
					// Channel 4, the SPU: the same two block paths as the GPU's,
					// with the SPU's FIFO behind them instead of GP0 / GPUREAD. It
					// used to finish the moment it started, and every sample bank
					// a game uploaded went nowhere.
					3'd4: begin
						words  <= bwords(bcr[4][15:0]);
						blocks <= (chcr[4][10:9] == 2'd0) ? 16'd1 : bcr[4][31:16];
						st <= chcr[4][0] ? S_RD : S_GRD;
					end
					// The MDEC: one block per request (its words in BCR's low half), then back to
					// the arbiter with MADR and the block count saved, as the chip does in sync
					// mode 1 -- so channel 1 can drain what channel 0 fed in between.
					3'd0: begin words <= m_park[0] ? m_left0 : bwords(bcr[0][15:0]); m_park[0] <= 1'b0; blocks <= 16'd1; st <= S_RD; end
					3'd1: begin words <= m_park[1] ? m_left1 : bwords(bcr[1][15:0]); m_park[1] <= 1'b0; blocks <= 16'd1; st <= S_GRD; end
					3'd6: begin                                     // OTC
						words <= bwords(bcr[6][15:0]);
						st <= S_OTC;
					end
					default: st <= S_DONE;                          // the rest: instant
					endcase
				end

			// --- RAM -> GP0, block mode ----------------------------------------------
			S_RD: if (words == 32'd0) begin
					if (blocks <= 16'd1) st <= S_DONE;
					else begin
						blocks <= blocks - 16'd1;
						words  <= bwords(bcr[cur][15:0]);
						if (chcr[cur][10:9] == 2'd1) blk_gap <= BLK_GAP[4:0];
					end
				end else if (!chcr[cur][24]) begin madr[cur] <= addr; st <= S_IDLE; end
				else if (cur == 3'd0 && !dev_ready && (want & 7'b111_1110) != 7'd0) begin   // (as channel 1, above)
					madr[0] <= addr; m_left0 <= words; m_park[0] <= 1'b1; st <= S_IDLE;
				end
				else if (dev_ready && blk_gap == 5'd0) begin
					if (lb_v && lb_tag == addr[23:4]) begin
						wd <= lb_data[addr[3:2]*32 +: 32];
						st <= S_GP0;
					end else begin
						r_addr <= {5'd0, addr};
						r_we   <= 1'b0;
						r_req  <= 1'b1;
						st <= S_RDW;
					end
				end
			// The word is held here until the GPU's FIFO can take it. Pushing it
			// straight from S_RDW lost words: S_RD had checked gp0_ready cycles
			// earlier, before the previous push had even been counted, so at a
			// nearly-full FIFO the DMA committed to a word the FIFO then refused,
			// and advanced past it regardless -- one word gone, every command
			// after it misparsed, a triangle waiting forever for its last vertex.
			S_RDW: if (r_ack) begin
					wd <= r_rdata;
					lb_v <= 1'b1; lb_tag <= addr[23:4]; lb_data <= r_line;
					st <= S_GP0;
				end else r_req <= 1'b1;   // hold until the cache takes it
			// A word a clock while the next is in the line in hand: the console's DMA moves one a
			// cycle (ps1-tests dma/chopping: ~1.07 a word against our 1.87, by way of S_RD).
			// Safe back to back: the GPU's ready keeps two words of room, one for the push in
			// flight and one for this.
			S_GP0: if (dev_ready) begin
					if (cur == 3'd4) spu_wr <= 1'b1; else if (cur == 3'd0) mdec_wr <= 1'b1; else gp0_wr <= 1'b1;
					// the word goes out with its write strobe, both registered: the next one may be
					// loaded into wd this same clock (streaming, below) -- loaded straight into
					// gp0_data, it replaced the word before the GPU took it, and every streamed
					// word went out as the one after it (the BIOS logo's quad lost its first vertex)
					gp0_data <= wd;
					addr_n    = chcr[cur][1] ? addr - 24'd4 : addr + 24'd4;
					addr     <= addr_n;
					words    <= words - 32'd1;
					if (cur == 3'd2 && words != 32'd1 && lb_v && lb_tag == addr_n[23:4])
						wd <= lb_data[addr_n[3:2]*32 +: 32];
					else
						st <= S_RD;
				end

			// --- RAM -> GP0, linked list ---------------------------------------------------
			// Between nodes the console's processor has the bus for a while: it runs at about
			// 63% of its speed while a list loops on itself for ever (ps1-tests
			// dma/chain-looping: 25,632 cycles for work that takes 16,040 alone) -- ~8 cycles a
			// header, ~13 for the processor. Held throughout, ours never ran again. But only a
			// list seen going round gets the turns: given to every list, the BIOS copied the
			// next frame's packets over ones not yet walked (our DMA is slower a node than the
			// console's, which keeps ahead) and the list walked into the exception vector.
			S_LL: if (!chcr[2][24]) begin madr[2] <= addr; st <= S_IDLE; end   // stopped by the CPU
				else if (blk_gap != 5'd0) ;
				// the header out of the line in hand: an ordering table's next slot is the word
				// below this one, in the same line three times in four -- each a cache round trip
				// before (ps1-tests in GT2: 4.5% of the race's time waiting on headers)
				else if (lb_v && lb_tag == addr[23:4]) ll_node(lb_data[addr[3:2]*32 +: 32]);
				else begin
					// read the node header
					r_addr <= {5'd0, addr};
					r_we   <= 1'b0;
					r_req  <= 1'b1;
					st <= S_LLW;
				end
			S_LLW: if (r_ack) begin
					lb_v <= 1'b1; lb_tag <= addr[23:4]; lb_data <= r_line;
					ll_node(r_rdata);
				end else r_req <= 1'b1;   // hold until the cache takes it

			// --- the ordering table clear ---------------------------------------------------
			// A line at a time: the slots from this one down to the line's first (or the table's
			// last), each pointing at the one below, the very last at $FFFFFF. Written a word at a
			// time, every line missed and was read from memory only to be overwritten: 3.5% of
			// GT2's race time, where the console clears a slot a cycle.
			S_OTC: if (words == 32'd0) st <= S_DONE;
				else begin
					r_addr  <= {5'd0, addr[23:4], 4'd0};
					r_we    <= 1'b1;
					r_lwe   <= 1'b1;
					for (ok = 0; ok < 4; ok = ok + 1) begin
						// slot ok of the line is (addr[3:2] - ok) slots below the one at addr
						if (ok <= addr[3:2] && ({30'd0, addr[3:2]} - ok) < words) begin
							r_be16[ok*4 +: 4] <= 4'hF;
							r_wdata128[ok*32 +: 32] <= (({30'd0, addr[3:2]} - ok) == words - 32'd1) ? 32'h00FF_FFFF
							                         : {8'd0, addr[23:4], ok[1:0], 2'b00} - 32'd4;
						end else begin
							r_be16[ok*4 +: 4] <= 4'h0;
							r_wdata128[ok*32 +: 32] <= 32'd0;
						end
					end
					otc_n   <= ({29'd0, addr[3:2]} + 32'd1 < words) ? {29'd0, addr[3:2]} + 32'd1 : words;
					r_req   <= 1'b1;
					st <= S_OTCW;
				end
			S_OTCW: if (r_ack) begin
					addr  <= addr - {otc_n[21:0], 2'b00};
					words <= words - otc_n;
					r_lwe <= 1'b0;
					st <= S_OTC;
				end else r_req <= 1'b1;   // hold until the cache takes it

			// --- GPU -> RAM (VRAM read-back) ---------------------------------------------------
			S_GRD: if (words == 32'd0) begin
					if (blocks <= 16'd1) st <= S_DONE;
					else begin blocks <= blocks - 16'd1; words <= bwords(bcr[cur][15:0]); end
				end else begin
					if (cur == 3'd4) spu_rd <= 1'b1; else if (cur != 3'd1) gpu_rd <= 1'b1;
					st <= S_GWR;
				end
			// gpu_rd is held until the word arrives: a one-cycle pulse while the
			// GPU had nothing ready yet was simply missed, and this waited forever
			// A channel the CPU stops (CHCR bit 24 cleared) while it waits on its device lets go:
			// MADR as far as it got, and back to the arbiter. ps1-tests mdec/4bit stops channel 1
			// in the middle of a block the MDEC will never finish, then runs the GPU's -- and
			// this waited for the MDEC for ever with every other channel shut out.
			S_GWR: if (!chcr[cur][24]) begin madr[cur] <= addr; st <= S_IDLE; end
				// an MDEC channel waiting part way through a block on its device steps aside for
				// another that wants the bus, and picks up where it was (ps1-tests mdec/4bit: a
				// GPU transfer started while channel 1 waited for words that never came)
				else if (cur == 3'd1 && !dev_rvalid && (want & 7'b111_1101) != 7'd0) begin
					madr[1] <= addr; m_left1 <= words; m_park[1] <= 1'b1; st <= S_IDLE;
				end
				else if (dev_rvalid) begin
					r_addr  <= (cur == 3'd1 && m1_re) ? {5'd0, m1_addr} : {5'd0, addr};
					r_we    <= 1'b1;
					r_wdata <= dev_rdata;
					r_req   <= 1'b1;
					st <= S_GWRW;
				end else if (cur == 3'd4) begin if (spu_gap == 8'd0) spu_rd <= 1'b1; end   // (the SPU's pace: ask when the gap is out)
				else if (cur != 3'd1) gpu_rd <= 1'b1;
			S_GWRW: if (r_ack) begin
					addr  <= addr + 24'd4;
					words <= words - 32'd1;
					if (cur == 3'd1) begin                       // where the next word of the macroblock goes
						if (m1w != m1_wpr - 3'd1) m1w <= m1w + 3'd1;
						else begin
							m1w <= 3'd0;
							if (m1r != 3'd7) m1r <= m1r + 3'd1;
							else begin m1r <= 3'd0; m1b <= m1b + 2'd1; end
						end
					end
					st <= S_GRD;
				end else r_req <= 1'b1;   // hold until the cache takes it

			S_CRD: if (words == 32'd0) begin
					if (blocks <= 16'd1) st <= S_DONE;
					else begin blocks <= blocks - 16'd1; words <= bwords(bcr[3][15:0]); end
				end else begin
					cd_rd <= 1'b1;
					st <= S_CWR;
				end
			S_CWR: if (cd_rvalid) begin
					r_addr  <= {5'd0, addr};
					r_we    <= 1'b1;
					r_wdata <= cd_rdata;
					r_req   <= 1'b1;
					st <= S_CWRW;
				end
			S_CWRW: if (r_ack) begin
					cd_words <= cd_words + 16'd1;
					addr  <= addr + 24'd4;
					words <= words - 32'd1;
					st <= S_CRD;
				end else r_req <= 1'b1;   // hold until the cache takes it

			S_DONE: begin
					if (cur == 3'd3) begin cd_go <= 1'b1; cd_go_info <= {8'hD4, 8'd0, cd_words}; end   // for the drive's trace
					// a linked list goes on to its next node
					// (the chip ends a list on bit 23 alone, and masks the pointer into RAM)
					if (cur == 3'd2 && chcr[2][10:9] == 2'd2 && !next[23]
					    && st == S_DONE) begin
						addr <= {3'd0, next[20:2], 2'b00};
						next <= 24'hFF_FFFF;
						// a list that comes back to one of its last two nodes is going round for
						// ever; the processor then gets its turn between nodes (below)
						ll_prev2 <= ll_prev1; ll_prev1 <= ll_cur; ll_cur <= {3'd0, next[20:2], 2'b00};
						if ({3'd0, next[20:2], 2'b00} == ll_cur || {3'd0, next[20:2], 2'b00} == ll_prev1) ll_loop <= 1'b1;
						if (ll_loop) begin blk_gap <= LL_GAP[5:0] + HDR_HOLD[5:0]; hdr_hold <= HDR_HOLD[5:0]; end
						st <= S_LL;
						if (ll_others) begin madr[2] <= {3'd0, next[20:2], 2'b00}; ll_park <= 1'b1; st <= S_IDLE; end   // (see ll_park)
					end else if (cur <= 3'd1 && chcr[cur][10:9] == 2'd1 && bcr[cur][31:16] > 16'd1) begin
						// an MDEC block done, more to come: back to the arbiter, not finished
						bcr[cur][31:16] <= bcr[cur][31:16] - 16'd1;
						madr[cur]       <= addr;
						st <= S_IDLE;
					end else begin
						chcr[cur][24] <= 1'b0;                 // not busy
						chcr[cur][28] <= 1'b0;
						madr[cur]     <= addr;
						if (dicr[16 + cur]) dicr[24 + cur] <= 1'b1;   // flag it
						st <= S_IDLE;
					end
				end
			default: st <= S_IDLE;
			endcase

			// A finished linked-list payload: S_RD lands in S_DONE with the
			// list's `next` still set, which S_DONE follows. A block-mode
			// transfer arrives there with next = $FFFFFF (set below) and stops.
			if (st == S_PICK && cur == 3'd2 && chcr[2][10:9] != 2'd2)
				next <= 24'hFF_FFFF;
		end
	end

	always @(*) begin
		if (glob) case (rg)
			2'd0:    rdata = dpcr;
			2'd1:    rdata = {master, dicr[30:0]};
			default: rdata = 32'd0;
			endcase
		else case (rg)
			2'd0:    rdata = {8'd0, madr[ch]};
			2'd1:    rdata = bcr[ch];
			2'd2:    rdata = chcr[ch];
			default: rdata = 32'd0;
			endcase
	end
	// a word count of 0 is 65,536 words (psx-spx)
	function [31:0] bwords;
		input [15:0] n;
		bwords = (n == 16'd0) ? 32'h0001_0000 : {16'd0, n};
	endfunction
	assign dbg_dma = {st, cur, chcr[2][24], next};
	assign dbg_mdma = {chcr[0][24], chcr[1][24], m_park, chcr[0][10:9], chcr[1][10:9], bcr[0][27:16], bcr[1][27:16]};
	assign dbg_madr1 = {madr[0][15:2], 2'b00, madr[1][15:2], 2'b00};
	// channel 1 takes the MDEC's word the clock it writes it to RAM
	assign mdec_pop = (st == S_GWR) && (cur == 3'd1) && mdec_rvalid;
	// ...and from the moment such a transfer is ASKED for: the BIOS starts the
	// ordering-table clear while a linked list is still being drawn, and expects
	// the table clean by its next instruction. Queued or running, it owns the bus.
	// psx-spx: "any read access from RAM ... will stall the CPU until the DMA
	// is finished"; linked-list transfers only give the CPU the bus while the
	// DMA is paused waiting on the GPU. The BIOS relies on it: it kicks the
	// display-list DMA and memcpy's the next frame's packets over the ones the
	// DMA is still walking, and on the chip that memcpy waits. Ours did not, so
	// the DMA read half-built packet headers (garbage `next` -> garbage
	// polylines). So: EVERY transfer, wanted or running, owns the bus, except a
	// GPU transfer that is paused because the GPU is not ready for the word.
	reg hog_want;
	integer hk;
	always @(*) begin
		hog_want = 1'b0;
		for (hk = 0; hk < 7; hk = hk + 1)
			if (want[hk]) hog_want = 1'b1;
	end
	wire gpu_paused = ((st == S_GP0) || (st == S_RD)) && !gp0_ready;   // S_RD and S_GP0 are where a GPU transfer waits on the GPU
	// ...and a transfer FROM the MDEC or the SPU waiting for the device's next word: in sync mode 1
	// the chip gives the CPU the bus until the device asks again. Held, the CPU stood still on
	// its next access for good when the device never had the rest -- ps1-tests mdec/4bit asks
	// for more words than one block decodes, and its timeout loop never got to run.
	wire dev_paused = ((st == S_GWR) && !dev_rvalid && ((cur == 3'd1) || ((cur == 3'd4) && spu_gap != 8'd0)))
	                || ((st == S_RD || st == S_LL) && blk_gap != 6'd0 && hdr_hold == 6'd0)
	                || ((cur == 3'd4) && ((st == S_RD) || (st == S_GP0)) && !dev_ready);
	assign hog = (hog_want || (st != S_IDLE)) && !gpu_paused && !dev_paused;
	assign in_flight = (hog_want || (st != S_IDLE)) && !dev_paused;
	assign gpu_active = want[2] || ((st != S_IDLE) && (cur == 3'd2));

endmodule

`default_nettype wire
