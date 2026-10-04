//////////////////////////////////////////////////////////////////////////////////
// n64_rdp_stream.v - the RDP's read-ahead for things read in order: the command list
// (the walker) and textures (TMEM loads). A request for line L that is not in hand
// starts a run: L, L+1, L+2, L+3 are asked for at once, pipelined (n64_top takes several
// reads at a time), and as the client moves on, the run moves with it. A line in hand
// answers on the next clock instead of a round trip to DDR3 (some 30 clocks).
//
// The client asks as it did a one-line port: c_req held with c_line until c_ack (a
// clock), with c_data. flush drops everything (the command list grows in place: after an
// END write the lines past the old end are read again); reads already asked for still
// come back, and are thrown away. hold: a read of this unit's may be being taken (it is
// presented, or taken and not yet acknowledged) -- no new run then (nor a flush, the caller
// sees to it), or that read would be counted in the wrong run.
//////////////////////////////////////////////////////////////////////////////////

`default_nettype none

module n64_rdp_stream (
	input  wire         clk,
	input  wire         rst,
	input  wire         flush,
	input  wire         hold,
	input  wire         stop,             // a flush is waiting: ask for nothing more (so hold can fall)
	// the client
	input  wire         c_req,
	input  wire [19:0]  c_line,
	output reg          c_ack,
	output reg  [127:0] c_data,
	// the reads: taken on q_ready; the lines come back in order (q_rs: this unit's)
	output wire         q_valid,
	output wire [19:0]  q_line,
	input  wire         q_ready,
	input  wire         q_rs,
	input  wire [127:0] q_rs_data
);
	reg  [127:0] lines [0:3];             // line l at l[1:0]
	reg  [19:0]  b, n, r;                 // the run: lines b.. in hand up to r, asked for up to n
	reg          live;                    // a run is going
	reg  [3:0]   drop;                    // reads still to come that belong to a dropped run
	assign q_valid = live && !stop && (n - b) < 20'd4;
	assign q_line = n;
	wire         in_hand = live && c_line >= b && c_line < r;
	// (in the run's window: asked for, or about to be -- a run just started has n == b, and
	// was restarted again and again for its own first line)
	wire         asked = live && c_line >= b && c_line < b + 20'd4;
	// this clock's events
	// one more asked for, in the run. (q_ready alone: it answers a read of this unit's that
	// was presented earlier -- counted only while still presented, a read taken just as a
	// flush stopped the requests went uncounted, and its line came back as another's)
	wire         issue = q_ready;
	wire         old = q_rs && drop != 4'd0;            // a dropped run's line back
	wire         got = q_rs && drop == 4'd0;            // the run's next line back
	wire         restart = c_req && !c_ack && !flush && !hold && !in_hand && !asked;
	// what is still to come of the run, were it dropped now
	wire [3:0]   owed = live ? (n[3:0] - r[3:0]) + {3'd0, issue} - {3'd0, got} : 4'd0;
	always @(posedge clk) begin
		c_ack <= 1'b0;
		if (got) lines[r[1:0]] <= q_rs_data;
		if (rst) begin live <= 1'b0; drop <= 4'd0; end
		else if (flush || restart) begin
			drop <= drop - {3'd0, old} + owed;
			live <= restart;
			b <= c_line; n <= c_line; r <= c_line;
		end else begin
			drop <= drop - {3'd0, old};
			if (issue) n <= n + 20'd1;
			if (got) r <= r + 20'd1;
			if (c_req && !c_ack && in_hand) begin
				c_ack <= 1'b1; c_data <= lines[c_line[1:0]];
				b <= c_line;                              // (the lines before it are done with)
			end
		end
	end
endmodule

`default_nettype wire
