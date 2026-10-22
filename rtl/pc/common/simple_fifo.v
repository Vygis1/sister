/*
 * Copyright (c) 2014, Aleksander Osman
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * 
 * * Redistributions of source code must retain the above copyright notice, this
 *   list of conditions and the following disclaimer.
 * 
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

module simple_fifo
#(
   parameter width     = 1,
   parameter widthu    = 1,
   // BLOCK=1 (fpga-console): the read a clock early into a register, so the memory is a block RAM and not
   // LUTs (ide.v's two 2048 x 32 FIFOs were 3,800 LUTs); a word written to the slot being read next is
   // passed straight through. The ports behave exactly as BLOCK=0 (sim/tb_simple_fifo.v compares them).
   parameter BLOCK     = 0
)
(
    input                       clk,
    input                       rst_n,
    input                       sclr,
    
    input                       rdreq,
    input                       wrreq,
    input       [width-1:0]     data,
    
    output                      empty,
    output reg                  full,
    output      [width-1:0]     q,
    output reg  [widthu-1:0]    usedw
);


reg [width-1:0] mem [(2**widthu)-1:0];      // (BLOCK=1: only read synchronously -- a block RAM)

reg [widthu-1:0] rd_index = 0;
reg [widthu-1:0] wr_index = 0;

wire do_rd = rdreq && ~(empty);
wire do_wr = wrreq && (~(full) || rdreq);
// (SiSTer: was (rst_n == 1'b0 || sclr) ? 0 : rd_index + do_rd -- the same, with the increment made from the
//  register alone and the late do_rd only choosing it)
wire [widthu-1:0] rd_index_p1 = rd_index + { {widthu-1{1'b0}}, 1'b1 };
wire [widthu-1:0] rd_next = (rst_n == 1'b0 || sclr) ? {widthu{1'b0}} : (do_rd ? rd_index_p1 : rd_index);
reg  [width-1:0] q_r;
always @(posedge clk) q_r <= (do_wr && wr_index == rd_next) ? data : mem[rd_next];
assign q    = BLOCK ? q_r : mem[rd_index];
assign empty= usedw == 0 && ~(full);

always @(posedge clk) begin
    if(rst_n == 1'b0)           rd_index <= 0;
    else if(sclr)               rd_index <= 0;
    else if(rdreq && ~(empty))  rd_index <= rd_index + { {widthu-1{1'b0}}, 1'b1 };
end

always @(posedge clk) begin
    if(rst_n == 1'b0)                       wr_index <= 0;
    else if(sclr)                           wr_index <= 0;
    else if(wrreq && (~(full) || rdreq))    wr_index <= wr_index + { {widthu-1{1'b0}}, 1'b1 };
end

always @(posedge clk) begin
    if(wrreq && (~(full) || rdreq)) mem[wr_index] <= data;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)                                               full <= 1'b0;
    else if(sclr)                                                   full <= 1'b0;
    else if(rdreq && ~(wrreq) && full)                              full <= 1'b0;
    else if(~(rdreq) && wrreq && ~(full) && usedw == (2**widthu)-1) full <= 1'b1;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)                       usedw <= 0;
    else if(sclr)                           usedw <= 0;
    else if(rdreq && ~(wrreq) && ~(empty))  usedw <= usedw - { {widthu-1{1'b0}}, 1'b1 };
    else if(~(rdreq) && wrreq && ~(full))   usedw <= usedw + { {widthu-1{1'b0}}, 1'b1 };
    else if(rdreq && wrreq && empty)        usedw <= { {widthu-1{1'b0}}, 1'b1 };
end

endmodule
