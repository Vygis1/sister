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

module decode_regs(
    input               clk,
    input               rst_n,
    
    input               dec_reset,
    
    input       [3:0]   fetch_valid,
    // (SiSTer: fetch_valid as it is when pr_reset is low. decoder_count takes the accepted count only when
    //  dec_reset is low; dec_reset is exc_dec_reset | wr_req_reset_dec and pr_reset is wr_req_reset_pr, the
    //  same expression (autogen/write_commands.v), so then pr_reset is low and fetch_valid is fetch_valid_nopr)
    input       [3:0]   fetch_valid_nopr,
    input       [63:0]  fetch,
    
    input       [3:0]   prefix_count,
    // (SiSTer: consume_count arrives as its two possible values and the late select between them --
    //  consume_count == (consume_stall)? consume_count_stall : consume_count_go -- so the stall chain
    //  (write stage -> read stage -> micro_busy) meets the decoder only at the last mux before the
    //  registers; the next state is computed for both values and chosen at the end. decode.v)
    input       [3:0]   consume_count_go,
    input       [3:0]   consume_count_stall,
    input               consume_stall,
    
    output      [3:0]   dec_acceptable,
    
    output reg  [95:0]  decoder,            // decoding buffer
    output reg  [3:0]   decoder_count
);

//------------------------------------------------------------------------------

wire [4:0] total_count;

wire [3:0] acceptable_1;
wire [3:0] acceptable_2;

wire [3:0] accepted;

//------------------------------------------------------------------------------

assign total_count         = prefix_count + decoder_count;

//------------------------------------------------------------------------------

// acceptable by decoder
// nand2mario: remove " + consume_count" for now to improve critical path timing
//             this makes fetching more conservative, but next cycle, we'll fetch these bytes
assign acceptable_1     = 4'd12 - decoder_count;
                                
// acceptable by total instruction length
assign acceptable_2     = (total_count < 5'd15)? 4'd15 - total_count[3:0] : 4'd0;

// nand2mario: remove " < acceptable_2" for now to improve critical path timing
//             acceptable_2 is useful only for detecting illegal instructions longer than 15 bytes
//             ignore that for now
assign dec_acceptable   = (dec_reset)?                      4'd0 :
                          acceptable_1;
//                          (acceptable_1 < acceptable_2)?    acceptable_1 : acceptable_2;

assign accepted         = (dec_acceptable > fetch_valid)? fetch_valid : dec_acceptable;

// (SiSTer: accepted as it is when dec_reset is low -- dec_acceptable is acceptable_1 and pr_reset is low --
//  the only time decoder_count takes it)
wire [3:0] accepted_nr  = (acceptable_1 > fetch_valid_nopr)? fetch_valid_nopr : acceptable_1;

//------------------------------------------------------------------------------

// (SiSTer: the original after_consume / decoder_next, built once for each value consume_count can
//  take -- decode_regs_next below is that logic unchanged -- and the late consume_stall picks)
wire [95:0] decoder_next_go,     decoder_next_stall;
wire [3:0]  count_next_go,       count_next_stall;
wire [3:0]  count_next_go_nr,    count_next_stall_nr;   // (SiSTer: with accepted_nr)

decode_regs_next next_go_inst(
    .decoder(decoder), .decoder_count(decoder_count), .fetch(fetch), .accepted(accepted),
    .consume_count(consume_count_go), .decoder_next(decoder_next_go), .count_next(count_next_go), .accepted_nr(accepted_nr), .count_next_nr(count_next_go_nr));

decode_regs_next next_stall_inst(
    .decoder(decoder), .decoder_count(decoder_count), .fetch(fetch), .accepted(accepted),
    .consume_count(consume_count_stall), .decoder_next(decoder_next_stall), .count_next(count_next_stall), .accepted_nr(accepted_nr), .count_next_nr(count_next_stall_nr));

wire [95:0] decoder_next = (consume_stall)? decoder_next_stall : decoder_next_go;

//------------------------------------------------------------------------------

always @(posedge clk) begin
    if(rst_n == 1'b0)   decoder <= 96'd0;
    else                decoder <= decoder_next;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)   decoder_count <= 4'd0;
    else if(dec_reset)  decoder_count <= 4'd0;
    else                decoder_count <= (consume_stall)? count_next_stall_nr : count_next_go_nr;   // (SiSTer: dec_reset is low here: accepted_nr)
end

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------

endmodule

// (SiSTer: decode_regs' original next-state logic, unchanged, as a module of its own so that
//  decode_regs can build it for both values of consume_count)
module decode_regs_next(
    input       [95:0]  decoder,
    input       [3:0]   decoder_count,
    input       [63:0]  fetch,
    input       [3:0]   accepted,
    input       [3:0]   consume_count,
    output      [95:0]  decoder_next,
    output      [3:0]   count_next,
    input       [3:0]   accepted_nr,
    output      [3:0]   count_next_nr
);

wire [3:0] after_consume_count;
wire [95:0] after_consume;

assign after_consume_count = decoder_count - consume_count;

assign after_consume = decoder >> (consume_count * 8);

assign decoder_next =
    (after_consume_count == 4'd0)?   { 32'd0,fetch } :
    (after_consume_count == 4'd1)?   { 24'd0,fetch,       after_consume[7:0] } :
    (after_consume_count == 4'd2)?   { 16'd0,fetch,       after_consume[15:0] } :
    (after_consume_count == 4'd3)?   { 8'd0, fetch,       after_consume[23:0] } :
    (after_consume_count == 4'd4)?   {       fetch,       after_consume[31:0] } :
    (after_consume_count == 4'd5)?   {       fetch[55:0], after_consume[39:0] } :
    (after_consume_count == 4'd6)?   {       fetch[47:0], after_consume[47:0] } :
    (after_consume_count == 4'd7)?   {       fetch[39:0], after_consume[55:0] } :
    (after_consume_count == 4'd8)?   {       fetch[31:0], after_consume[63:0] } :
    (after_consume_count == 4'd9)?   {       fetch[23:0], after_consume[71:0] } :
    (after_consume_count == 4'd10)?  {       fetch[15:0], after_consume[79:0] } :
    (after_consume_count == 4'd11)?  {       fetch[7:0],  after_consume[87:0] } :
                                                          after_consume;

assign count_next = after_consume_count + accepted;
assign count_next_nr = after_consume_count + accepted_nr;   // (SiSTer)

endmodule
