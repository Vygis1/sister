//////////////////////////////////////////////////////////////////////////////////
// tb_gba_rtc - the cartridge clock (rtl/gba_rtc.v) driven as Pokemon Emerald's own driver drives
// it (pokeemerald src/siirtc.c: the same port writes, in the same order): the status, the date
// and time, the time; a reset and the 24-hour status written back; 12-hour mode.
//
//   ./tools/sim.sh tb_gba_rtc
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps
module tb_gba_rtc;
	reg clk = 0; always #10 clk = ~clk;
	reg rst = 1, en = 1, we = 0; reg [1:0] wa = 0, ra = 0; reg [3:0] wd = 0;
	wire [15:0] rq; wire readable;
	reg [55:0] now = 56'h24101704213456;      // 2024-10-17, Thursday, 21:34:56
	gba_rtc dut (.clk(clk), .rst(rst), .en(en), .we(we), .wa(wa), .wd(wd), .ra(ra), .rq(rq), .readable(readable), .now_bcd(now));
	integer fails = 0;

	localparam SCK = 1, SIO = 2, CS = 4;
	task port(input [1:0] a, input [3:0] v); begin @(negedge clk); wa = a; wd = v; we = 1; @(negedge clk); we = 0; end endtask
	task data(input [3:0] v); port(2'd0, v); endtask
	task dir(input [3:0] v); port(2'd1, v); endtask
	function [3:0] rd_data; input dummy; begin rd_data = rq[3:0]; end endfunction
	task wcmd(input [7:0] v); integer i; reg t; begin
		for (i = 0; i < 8; i = i + 1) begin
			t = v[7 - i];
			data({t, 1'b0} | CS); data({t, 1'b0} | CS); data({t, 1'b0} | CS); data({t, 1'b0} | SCK | CS);
		end
	end endtask
	task wdat(input [7:0] v); integer i; reg t; begin
		for (i = 0; i < 8; i = i + 1) begin
			t = v[i];
			data({t, 1'b0} | CS); data({t, 1'b0} | CS); data({t, 1'b0} | CS); data({t, 1'b0} | SCK | CS);
		end
	end endtask
	task rdat(output [7:0] v); integer i; begin
		v = 0;
		for (i = 0; i < 8; i = i + 1) begin
			data(CS); data(CS); data(CS); data(CS); data(CS); data(SCK | CS);
			ra = 2'd0; #1; v = {rq[1], v[7:1]};
		end
	end endtask
	task begin_x; begin data(SCK); data(SCK | CS); dir(4'd7); end endtask
	task end_x; begin data(SCK); data(SCK); end endtask
	task expect8(input [8*12-1:0] what, input [7:0] got, input [7:0] want); begin
		if (got !== want) begin fails = fails + 1; $display("FAIL %0s: %02x, want %02x", what, got, want); end
		else $display("  %0s %02x", what, got);
	end endtask

	reg [7:0] st, y, mo, d, wdy, h, mi, s;
	initial begin
		repeat (3) @(posedge clk); rst = 0;
		port(2'd2, 4'd1);                                   // EnableGpioPortRead
		if (!readable) begin fails = fails + 1; $display("FAIL: the port does not read back"); end
		// SiiRtcGetStatus
		begin_x; wcmd(8'h63); dir(4'd5); rdat(st); end_x;
		expect8("status", st, 8'h40);
		// SiiRtcGetDateTime
		begin_x; wcmd(8'h65); dir(4'd5);
		rdat(y); rdat(mo); rdat(d); rdat(wdy); rdat(h); rdat(mi); rdat(s); end_x;
		expect8("year", y, 8'h24); expect8("month", mo, 8'h10); expect8("day", d, 8'h17); expect8("weekday", wdy, 8'h04);
		expect8("hour", h, 8'h21); expect8("minute", mi, 8'h34); expect8("second", s, 8'h56);
		// SiiRtcGetTime, a second later
		now = 56'h24101704213457;
		begin_x; wcmd(8'h67); dir(4'd5); rdat(h); rdat(mi); rdat(s); end_x;
		expect8("hour", h, 8'h21); expect8("minute", mi, 8'h34); expect8("second", s, 8'h57);
		// SiiRtcReset + SiiRtcSetStatus(24-hour), then the status again
		begin_x; wcmd(8'h60); end_x;
		begin_x; dir(4'd7); wcmd(8'h62); wdat(8'h40); end_x;
		begin_x; wcmd(8'h63); dir(4'd5); rdat(st); end_x;
		expect8("status", st, 8'h40);
		// 12-hour mode: 21 o'clock reads 09
		begin_x; dir(4'd7); wcmd(8'h62); wdat(8'h00); end_x;
		begin_x; wcmd(8'h67); dir(4'd5); rdat(h); rdat(mi); rdat(s); end_x;
		expect8("hour (12h)", h, 8'h09);
		// write-only again: reads give 0
		port(2'd2, 4'd0); ra = 2'd0; #1;
		if (rq !== 16'd0) begin fails = fails + 1; $display("FAIL: the port reads %04x when write-only", rq); end
		if (fails == 0) $display("tb_gba_rtc: PASS"); else $display("tb_gba_rtc: FAIL (%0d)", fails);
		$finish;
	end
endmodule
