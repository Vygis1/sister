//////////////////////////////////////////////////////////////////////////////////
// tb_ps1_mcard - the memory card in ps1_sio.v, against the reply bytes
// DuckStation's MemoryCard::Transfer gives, over a line port that stalls.
//
// Drives the SIO registers the way the kernel does -- CTRL select, one byte into
// TX_DATA, wait for it, read RX_DATA, look for /ACK -- and checks every byte of
// every reply, which bytes carry /ACK, the checksum, what lands in memory, the
// FLAG bit, the queue of stored sectors, and that the pad still answers.
//
//   ./tools/sim.sh tb_ps1_mcard
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps
`default_nettype none
module tb_ps1_mcard;
	reg clk = 0, rst = 1;
	always #10 clk = ~clk;

	reg sel = 0, we = 0; reg [3:0] addr = 0, be = 4'hF; reg [31:0] wdata = 0; wire [31:0] rdata;
	reg [15:0] buttons = 16'h0000; wire irq;
	reg card_in = 0, card2_in = 0;
	reg [15:0] buttons2 = 16'h0000;
	wire [13:0] m_line; wire m_req, m_we; wire [127:0] m_wdata;
	reg m_ready = 0, m_valid = 0; reg [127:0] m_rdata = 0;
	wire [10:0] wq_sector; wire [4:0] wq_count; wire wq_ovf;
	reg wq_pop = 0;

	ps1_sio #(.SHIFT_CYCLES(100), .ACK_DELAY(10), .ACK_LOW(20)) dut (
		.clk(clk), .rst(rst), .rst_q(rst), .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata),
		.buttons(buttons), .buttons2(buttons2), .irq(irq), .card_in(card_in), .card2_in(card2_in),
		.m_line(m_line), .m_req(m_req), .m_we(m_we), .m_wdata(m_wdata),
		.m_ready(m_ready), .m_valid(m_valid), .m_rdata(m_rdata),
		.wq_sector(wq_sector), .wq_count(wq_count), .wq_ovf(wq_ovf), .wq_pop(wq_pop), .wq_clr_ovf(1'b0));

	// --- the card's memory: lines, refusing at random, answering reads late -----------
	reg [127:0] mem [0:16383];          // card 1, then card 2
	reg [31:0] rnd = 32'h2468_ACE1;
	integer lat = -1; reg [13:0] lat_line;
	always @(posedge clk) begin
		rnd <= rnd * 1664525 + 1013904223;
		m_valid <= 1'b0;
		if (lat > 0) lat <= lat - 1;
		else if (lat == 0) begin m_valid <= 1'b1; m_rdata <= mem[lat_line]; lat <= -1; end
	end
	always @(*) m_ready = m_req && rnd[20:19] != 2'b00;          // refuses a quarter of the time
	always @(posedge clk) if (m_req && m_ready) begin
		if (m_we) mem[m_line] <= m_wdata;
		else begin lat <= 5 + rnd[27:24]; lat_line <= m_line; end
	end

	// --- /ACK, seen as it happens ---------------------------------------------------------
	reg ack_seen = 0;
	always @(posedge clk) if (dut.ack_low) ack_seen <= 1'b1;

	integer errors = 0;
	task check; input c; input [8*72-1:0] what; begin
		if (!c) begin errors = errors + 1; if (errors < 20) $display("  FAIL %0s", what); end
	end endtask
	task wr; input [3:0] a; input [31:0] d; input [3:0] b; begin
		@(negedge clk); sel = 1; we = 1; addr = a; wdata = d; be = b; @(negedge clk); sel = 0; we = 0; be = 4'hF;
	end endtask
	task rd; input [3:0] a; output [31:0] d; begin
		@(negedge clk); sel = 1; we = 0; addr = a; #1 d = rdata; @(negedge clk); sel = 0;
	end endtask
	// one byte of an exchange: what came back and whether /ACK followed
	task xfer; input [7:0] o; output [7:0] i; output ack; reg [31:0] r; begin
		ack_seen = 0;
		wr(4'h0, {24'd0, o}, 4'b0001);
		wait (dut.busy); wait (!dut.busy);
		repeat (40) @(posedge clk);
		rd(4'h0, r); i = r[7:0]; ack = ack_seen;
	end endtask
	reg slot2 = 0;                       // which slot select() picks
	task select; begin wr(4'h8, slot2 ? 32'h2003_0000 : 32'h0003_0000, 4'b1100); end endtask   // TXEN | /JOY, CTRL bit 13 the slot
	task deselect; begin wr(4'h8, 32'h0000_0000, 4'b0100); repeat (5) @(negedge clk); end endtask

	reg [7:0] got; reg ack; integer k, s;
	reg [7:0] data [0:127]; reg [7:0] chk;
	// expect byte o -> i, with /ACK a
	task ex; input [7:0] o; input [7:0] i; input a; input [8*40-1:0] what; begin
		xfer(o, got, ack);
		if (got !== i || ack !== a) begin
			errors = errors + 1;
			if (errors < 20) $display("  FAIL %0s: sent %02h got %02h ack %b, want %02h ack %b", what, o, got, ack, i, a);
		end
	end endtask

	task read_sector; input [9:0] sec; input [7:0] flag; begin
		select;
		ex(8'h81, 8'hFF, 1, "read: address");
		ex(8'h52, flag,  1, "read: command -> FLAG");
		ex(8'h00, 8'h5A, 1, "read: ID1");
		ex(8'h00, 8'h5D, 1, "read: ID2");
		ex({6'd0, sec[9:8]}, 8'h00, 1, "read: MSB");
		ex(sec[7:0], {6'd0, sec[9:8]}, 1, "read: LSB -> last byte");
		ex(8'h00, 8'h5C, 1, "read: ACK1");
		ex(8'h00, 8'h5D, 1, "read: ACK2");
		ex(8'h00, {6'd0, sec[9:8]}, 1, "read: confirmed MSB");
		ex(8'h00, sec[7:0], 1, "read: confirmed LSB");
		chk = {6'd0, sec[9:8]} ^ sec[7:0];
		for (k = 0; k < 128; k = k + 1) begin
			ex(8'h00, mem[{slot2, sec, 3'd0} + k / 16][(k % 16) * 8 +: 8], 1, "read: data");
			chk = chk ^ mem[{slot2, sec, 3'd0} + k / 16][(k % 16) * 8 +: 8];
		end
		ex(8'h00, chk,   1, "read: checksum");
		ex(8'h00, 8'h47, 0, "read: end");
		deselect;
	end endtask

	task write_sector; input [9:0] sec; input bad; input [7:0] flag; begin
		for (k = 0; k < 128; k = k + 1) begin rnd = rnd * 1664525 + 1013904223; data[k] = rnd[23:16]; end
		chk = {6'd0, sec[9:8]} ^ sec[7:0];
		for (k = 0; k < 128; k = k + 1) chk = chk ^ data[k];
		select;
		ex(8'h81, 8'hFF, 1, "write: address");
		ex(8'h57, flag,  1, "write: command -> FLAG");
		ex(8'h00, 8'h5A, 1, "write: ID1");
		ex(8'h00, 8'h5D, 1, "write: ID2");
		ex({6'd0, sec[9:8]}, 8'h00, 1, "write: MSB");
		ex(sec[7:0], {6'd0, sec[9:8]}, 1, "write: LSB -> last byte");
		ex(data[0], sec[7:0], 1, "write: data 0 -> LSB");
		for (k = 1; k < 128; k = k + 1) ex(data[k], data[k - 1], 1, "write: data -> last byte");
		ex(bad ? ~chk : chk, data[127], 1, "write: checksum -> last byte");
		ex(8'h00, 8'h5C, 1, "write: ACK1");
		ex(8'h00, 8'h5D, 1, "write: ACK2");
		ex(8'h00, bad ? 8'h4E : 8'h47, 0, "write: end");
		deselect;
		repeat (400) @(negedge clk);                                   // the store drains
	end endtask

	reg [127:0] before [0:7];
	initial begin
		for (k = 0; k < 16384; k = k + 1) begin rnd = rnd * 1664525 + 1013904223; mem[k] = {4{rnd}} ^ {k, k, k, k}; end
		repeat (5) @(negedge clk); rst = 0;

		// no card: its address is not answered, and the pad is unaffected
		select; ex(8'h81, 8'hFF, 0, "no card: address"); deselect;
		buttons = 16'h8001;
		select;
		ex(8'h01, 8'hFF, 1, "pad: address"); ex(8'h42, 8'h41, 1, "pad: 42h"); ex(8'h00, 8'h5A, 1, "pad: 5Ah");
		ex(8'h00, 8'hFE, 1, "pad: low buttons"); ex(8'h00, 8'h7F, 0, "pad: high buttons");
		deselect;

		card_in = 1; repeat (3) @(negedge clk);
		read_sector(10'h005, 8'h08);                // a fresh card says so
		read_sector(10'h3FF, 8'h08);

		// get ID
		select;
		ex(8'h81, 8'hFF, 1, "id: address"); ex(8'h53, 8'h08, 1, "id: command -> FLAG");
		ex(8'h00, 8'h5A, 1, "id 1"); ex(8'h00, 8'h5D, 1, "id 2"); ex(8'h00, 8'h5C, 1, "id 3"); ex(8'h00, 8'h5D, 1, "id 4");
		ex(8'h00, 8'h04, 1, "id 5"); ex(8'h00, 8'h00, 1, "id 6"); ex(8'h00, 8'h00, 1, "id 7"); ex(8'h00, 8'h80, 0, "id 8");
		deselect;

		// a write lands, clears FLAG bit 3, and is queued for the PC
		write_sector(10'h123, 0, 8'h08);
		for (k = 0; k < 128; k = k + 1) check(mem[{10'h123, 3'd0} + k / 16][(k % 16) * 8 +: 8] === data[k], "write: stored byte");
		check(wq_count == 5'd1 && wq_sector == 10'h123, "write: queued for the PC");
		read_sector(10'h123, 8'h00);

		// a bad checksum is refused and changes nothing
		for (k = 0; k < 8; k = k + 1) before[k] = mem[{10'h0AA, 3'd0} + k];
		write_sector(10'h0AA, 1, 8'h00);
		for (k = 0; k < 8; k = k + 1) check(mem[{10'h0AA, 3'd0} + k] === before[k], "bad checksum: memory untouched");
		check(wq_count == 5'd1, "bad checksum: nothing queued");

		// back to back, as a save does it: write, read back, several sectors
		for (s = 0; s < 4; s = s + 1) begin
			write_sector(10'h040 + s, 0, 8'h00);
			read_sector(10'h040 + s, 8'h00);
		end
		check(wq_count == 5'd5, "queue: five stored");
		@(negedge clk); wq_pop = 1; @(negedge clk); wq_pop = 0;
		check(wq_count == 5'd4 && wq_sector == 10'h040, "queue: pop gives the next");

		// the pad, after all that
		select;
		ex(8'h01, 8'hFF, 1, "pad again: address"); ex(8'h42, 8'h41, 1, "pad again: 42h"); ex(8'h00, 8'h5A, 1, "pad again: 5Ah");
		ex(8'h00, 8'hFE, 1, "pad again: low"); ex(8'h00, 8'h7F, 0, "pad again: high");
		deselect;

		// an unknown command ends the exchange
		select; ex(8'h81, 8'hFF, 1, "bad cmd: address"); ex(8'h99, 8'h00, 0, "bad cmd: FLAG, no ACK"); deselect;

		// ---- slot 2: its own pad, its own card -------------------------------------------
		slot2 = 1;
		select; ex(8'h81, 8'hFF, 0, "slot 2, no card: address"); deselect;
		buttons2 = 16'h0010;                          // up, on the second pad only
		select;
		ex(8'h01, 8'hFF, 1, "pad 2: address"); ex(8'h42, 8'h41, 1, "pad 2: 42h"); ex(8'h00, 8'h5A, 1, "pad 2: 5Ah");
		ex(8'h00, 8'hEF, 1, "pad 2: low buttons"); ex(8'h00, 8'hFF, 0, "pad 2: high buttons");
		deselect;
		card2_in = 1; repeat (3) @(negedge clk);
		read_sector(10'h007, 8'h08);                  // card 2 is fresh, whatever card 1 has been through
		@(negedge clk); while (wq_count != 5'd0) begin wq_pop = 1; @(negedge clk); wq_pop = 0; @(negedge clk); end
		write_sector(10'h055, 0, 8'h08);
		for (k = 0; k < 128; k = k + 1) check(mem[{1'b1, 10'h055, 3'd0} + k / 16][(k % 16) * 8 +: 8] === data[k], "slot 2 write: stored in card 2");
		check(wq_count == 5'd1 && wq_sector == {1'b1, 10'h055}, "slot 2 write: queued with its slot");
		read_sector(10'h055, 8'h00);
		slot2 = 0;
		read_sector(10'h055, 8'h00);                  // card 1's sector 55h is card 1's, untouched by that
		for (k = 0; k < 8; k = k + 1) check(mem[{1'b0, 10'h055, 3'd0} + k] !== mem[{1'b1, 10'h055, 3'd0} + k], "slot 1 and 2 differ");

		if (errors == 0) $display("tb_ps1_mcard: all checks passed -- read, write, get ID, bad checksum, queue, both pads, both cards");
		else             $display("tb_ps1_mcard: FAIL -- %0d errors", errors);
		$finish;
	end
	initial begin #200_000_000; $display("tb_ps1_mcard: TIMEOUT"); $finish; end
endmodule
`default_nettype wire
