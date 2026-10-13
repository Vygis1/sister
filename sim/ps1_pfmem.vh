// ps1_pfmem.vh - a second memory port for ps1_gpu's texture prefetch (pfm_*), answered off the
// bench's `mem` of 128-bit lines with pf_lat clocks of latency (set pf_lat before the first
// read; it may be the bench's own latency). `include it after `mem` is declared.
wire [23:0]  pfm_addr; wire pfm_req; wire pfm_ready = pfm_req;
reg          pfm_valid = 1'b0; reg [127:0] pfm_rdata = 128'd0;
integer      pf_lat = 20;
reg [127:0]  pfq  [0:63];
reg          pfqv [0:63];
integer      pfk;
initial for (pfk = 0; pfk < 64; pfk = pfk + 1) begin pfqv[pfk] = 1'b0; pfq[pfk] = 128'd0; end
always @(posedge clk) begin
	pfm_valid <= pfqv[pf_lat - 1]; pfm_rdata <= pfq[pf_lat - 1];
	for (pfk = 63; pfk > 0; pfk = pfk - 1) begin pfqv[pfk] <= pfqv[pfk - 1]; pfq[pfk] <= pfq[pfk - 1]; end
	pfqv[0] <= (pfm_req === 1'b1); pfq[0] <= (pfm_req === 1'b1) ? mem[pfm_addr[15:0]] : 128'd0;   // (=== : an X before the core's reset must not travel)
end
