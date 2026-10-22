 /*
 * 4-way set associative TLB with 32 total entries (8 sets x 4 ways)
 * Interface compatible with tlb_regs.v
 *
 * 9/2025, nand2mario
 */

`include "defines.v"

module tlb_regs(
    input               clk,
    input               rst_n,
    
    //RESP:
    input               tlbflushsingle_do,
    input   [31:0]      tlbflushsingle_address,
    //END
    
    //RESP:
    input               tlbflushall_do,
    //END
    
    input               rw,
    
    //RESP:
    input               tlbregs_write_do,
    input   [31:0]      tlbregs_write_linear,
    input   [31:0]      tlbregs_write_physical,
    
    input               tlbregs_write_pwt,
    input               tlbregs_write_pcd,
    input               tlbregs_write_combined_rw,
    input               tlbregs_write_combined_su,
    //END
    
    //RESP:
    input               translate_do,
    input   [31:0]      translate_linear,
    output              translate_valid,
    output  [31:0]      translate_physical,
    output              translate_pwt,
    output              translate_pcd,
    output              translate_combined_rw,
    output              translate_combined_su,
    output  [3:0]       translate_rgn,      // (SiSTer: the L2 regions of translate_physical)
    // (SiSTer: the way hits and the four entries of the looked-up set, for tlb.v's per-way outputs)
    output  [3:0]       translate_hit,
    output  [49:0]      translate_e0,
    output  [49:0]      translate_e1,
    output  [49:0]      translate_e2,
    output  [49:0]      translate_e3
    //END
);

    // Entry layout:
    // [19:0]  linear page (tag)
    // [39:20] physical page
    // [40]    PWT
    // [41]    PCD
    // [42]    VALID
    // [43]    combined RW
    // [44]    combined SU
    // [45]    DIRTY (set on write fill)
    // [49:46] (SiSTer) the L2 regions of the physical page (ao486_l2_rgn), stored at the fill

    // (SiSTer: only way 0 of each set is ever used. The fill takes the first free way with
    //      casez (free_way) 4'b1???: way 0; 4'b01??: way 1; 4'b001?: way 2; 4'b0001: way 3
    //  where free_way[w] = ~valid[w] -- so while way 3 is free (free_way[3] = 1) it is way 0, and ways 1..3 are only
    //  ever written by a fill that picked them. From reset all are invalid, so by induction ways 1..3 stay invalid
    //  for ever (the flushes and the dirty-miss invalidation only write zeros), way 3 stays free, every fill goes to
    //  way 0 and the round-robin pointer (read only when no way is free) is never read. The TLB is therefore the
    //  8-entry direct-mapped one below: the same hits, the same entries, the same outputs on every clock --
    //  translate_hit[3:1] and translate_e1..e3 are the constant zeros ways 1..3 always held.)
    localparam SETS = 8;
    localparam SETBITS = 3;

    reg  [49:0] tlb   [0:SETS-1];

    wire [19:0] lin_page_t  = translate_linear[31:12];
    wire [SETBITS-1:0] set_t = translate_linear[12 +: SETBITS];    // bits [14:12]
    wire [SETBITS-1:0] set_w = tlbregs_write_linear[12 +: SETBITS];

    wire [49:0] selected = tlb[set_t];
    wire        hit_any  = translate_do && selected[42] && (selected[19:0] == lin_page_t);

    assign translate_hit = { 3'b000, hit_any };
    assign translate_e0  = selected;
    assign translate_e1  = 50'd0;
    assign translate_e2  = 50'd0;
    assign translate_e3  = 50'd0;

    // Outputs (as before, with selected the hit entry -- 0 when nothing hit: it is only read under hit_any)
    wire translate_valid_but_not_dirty = hit_any && rw && ~selected[45];

    assign translate_valid       = hit_any && (~rw || selected[45]);
    assign translate_physical    = translate_valid ? { selected[39:20], translate_linear[11:0] } : translate_linear;
    assign translate_pwt         = hit_any && selected[40];
    assign translate_pcd         = hit_any && selected[41];
    assign translate_combined_rw = hit_any && selected[43];
    assign translate_combined_su = hit_any && selected[44];

    // (SiSTer: the L2 regions of translate_physical: with translate_valid it is { selected[39:20], linear[11:0] }
    //  and the regions read only bits 31..13, the page's, stored at the fill; else it is translate_linear)
    wire [3:0] linear_rgn;
    ao486_l2_rgn linear_rgn_inst(.a(translate_linear), .f(linear_rgn));
    assign translate_rgn = translate_valid ? selected[49:46] : linear_rgn;

    // Single flush comparator against full tag
    wire [19:0] lin_page_flush = tlbflushsingle_address[31:12];

    // Compose write data
    wire [3:0]  write_rgn;     // (SiSTer)
    ao486_l2_rgn write_rgn_inst(.a(tlbregs_write_physical), .f(write_rgn));
    wire [49:0] write_data = { write_rgn, rw, tlbregs_write_combined_su, tlbregs_write_combined_rw, 1'b1,
                               tlbregs_write_pcd, tlbregs_write_pwt,
                               tlbregs_write_physical[31:12], tlbregs_write_linear[31:12] };

    integer si;
    always @(posedge clk) begin
        if (rst_n == 1'b0) begin
            for (si = 0; si < SETS; si = si + 1)
                tlb[si] <= 50'd0;
        end else begin
            // Flush-all
            if (tlbflushall_do) begin
                for (si = 0; si < SETS; si = si + 1)
                    tlb[si] <= 50'd0;
            end else begin
                // Flush single and dirty-miss invalidation
                for (si = 0; si < SETS; si = si + 1) begin
                    if ((tlbflushsingle_do && tlb[si][42] && tlb[si][19:0] == lin_page_flush) ||
                        (translate_valid_but_not_dirty && si[SETBITS-1:0] == set_t))
                        tlb[si] <= 50'd0;
                end
                // Install write (fill): always way 0 (see above)
                if (tlbregs_write_do)
                    tlb[set_w] <= write_data;
            end
        end
    end

    // synthesis translate_off
    wire _unused_ok = &{1'b0, translate_linear[11:0], tlbflushsingle_address[11:0], tlbregs_write_linear[11:0], 1'b0};
    // synthesis translate_on

endmodule
