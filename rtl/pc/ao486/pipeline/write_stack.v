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

`include "defines.v"

module write_stack(
    
    
    input       [63:0]  glob_descriptor,
    
    input       [31:0]  esp,
    
    input       [63:0]  ss_cache,
    input       [31:0]  ss_base,
    input       [31:0]  ss_limit,
    input       [31:0]  ss_bound_r,         // (SiSTer: w_push_bound below, registered -- write_register.v)
    input       [31:0]  ss_bound_lo_r,      // (SiSTer: w_push_bound - 2, registered)
    input               ss_bound_ge2_r,     // (SiSTer: w_push_bound >= 2, registered)
    
    input       [31:0]  glob_desc_base,
    input       [31:0]  glob_desc_limit,
    
    input               wr_operand_16bit,
    input       [31:0]  wr_stack_offset,
    
    input               wr_new_push_ss_fault_check,
    input               wr_push_length_word,
    input               wr_push_length_dword,
    
    input               wr_push_ss_fault_check,
    
    //output
    
    output      [31:0]  wr_stack_esp,
    output      [31:0]  wr_push_linear,
    
    output      [31:0]  wr_new_stack_esp,
    output      [31:0]  wr_new_push_linear,
    
    output      [2:0]   wr_push_length,
    
    output              wr_push_ss_fault,
    output              wr_new_push_ss_fault
);

//------------------------------------------------------------------------------ stack

wire [2:0]  wr_push_length_minus_1;

assign wr_stack_esp = (ss_cache[`DESC_BIT_D_B])? wr_stack_offset : { esp[31:16], wr_stack_offset[15:0] };

assign wr_push_linear = ss_base + wr_stack_offset;

assign wr_push_length = (wr_push_length_word || (~(wr_push_length_dword) && wr_operand_16bit))?  3'd2 : 3'd4;

assign wr_push_length_minus_1 =  wr_push_length - 3'd1;

//------------------------------------------------------------------------------ write_new_stack_virtual

wire [31:0] w_new_upper_limit;
wire        w_new_push_not_fit;
wire        w_new_push_limit_overflow;

assign wr_new_stack_esp = (glob_descriptor[`DESC_BIT_D_B])? wr_stack_offset : { esp[31:16], wr_stack_offset[15:0] };

assign wr_new_push_linear = glob_desc_base + wr_stack_offset;


assign w_new_upper_limit = (glob_descriptor[`DESC_BIT_D_B])? 32'hFFFFFFFF : 32'h0000FFFF; //d-b

// (CODE or not EXPAND-DOWN)
// (SiSTer: was
//      (glob_descriptor[43] || ~(glob_descriptor[42]))?
//          glob_desc_limit   - wr_stack_offset < { 29'd0, wr_push_length_minus_1 } :
//          w_new_upper_limit - wr_stack_offset < { 29'd0, wr_push_length_minus_1 };
//  wr_push_length is 2 or 4, so wr_push_length_minus_1 is 1 or 3: both compares are made from the
//  registers alone and the push length, decoded late from the command, picks one at the end)
// (SiSTer, further: room = (bound - wr_stack_offset) mod 2^32; room < 1 is wr_stack_offset == bound, and room < 3
//  is wr_stack_offset in [bound - 2, bound] mod 2^32 -- compares against bounds from the descriptor alone, with
//  no subtract in series with wr_stack_offset)
// (SiSTer, further: wr_stack_offset in [bound - 2, bound] mod 2^32 is wr_stack_offset + k == bound for k = 0, 1 or 2
//  (mod 2^32): three equality compares, the two sums from the register alone, instead of the bound's subtract
//  and the two range compares in series. Was
//      w_new_push_bound_lo = w_new_push_bound - 2;
//      w_new_push_room_lt3 = (w_new_push_bound >= 2)? (off >= bound_lo && off <= bound) : (off >= bound_lo || off <= bound))
wire [31:0] w_new_push_bound    = (glob_descriptor[43] || ~(glob_descriptor[42]))? glob_desc_limit : w_new_upper_limit;
wire [31:0] w_stack_offset_p1   = wr_stack_offset + 32'd1;
wire [31:0] w_stack_offset_p2   = wr_stack_offset + 32'd2;
wire        w_new_push_room_0   = wr_stack_offset == w_new_push_bound;
wire        w_new_push_room_lt3 = w_new_push_room_0 || w_stack_offset_p1 == w_new_push_bound || w_stack_offset_p2 == w_new_push_bound;
assign w_new_push_not_fit = (wr_push_length == 3'd2)? w_new_push_room_0 : w_new_push_room_lt3;
  
// (SiSTer: was
//      ((glob_descriptor[43] || !glob_descriptor[42]) &&  wr_stack_offset >  glob_desc_limit) ||
//      (!glob_descriptor[43] &&  glob_descriptor[42]  && (wr_stack_offset <= glob_desc_limit || wr_stack_offset > w_new_upper_limit));
//  the bound is glob_desc_limit in the first case and w_new_upper_limit in the second)
assign w_new_push_limit_overflow =
    wr_stack_offset > w_new_push_bound || (!glob_descriptor[43] && glob_descriptor[42] && wr_stack_offset <= glob_desc_limit);

// code or read-only
assign wr_new_push_ss_fault = wr_new_push_ss_fault_check &&
    (glob_descriptor[43] || ~glob_descriptor[41] || w_new_push_not_fit || w_new_push_limit_overflow);

//------------------------------------------------------------------------------

wire [31:0] w_upper_limit;
wire        w_push_not_fit;
wire        w_push_limit_overflow;

assign w_upper_limit = (ss_cache[`DESC_BIT_D_B])? 32'hFFFFFFFF : 32'h0000FFFF;

// (CODE or not EXPAND-DOWN)
// (SiSTer: was
//      (ss_cache[43] || ~(ss_cache[42]))?
//          ss_limit      - wr_stack_offset < { 29'd0, wr_push_length_minus_1 } :
//          w_upper_limit - wr_stack_offset < { 29'd0, wr_push_length_minus_1 };
//  the same split as w_new_push_not_fit above)
// (SiSTer, further: the same window compares as w_new_push_not_fit above)
// (SiSTer, further: the bound, bound - 2 and bound >= 2 are registers kept beside ss_cache (write_register.v:
//  the same functions of the same next value), so only the compares with wr_stack_offset are left here.
//  Was: w_push_bound = (ss_cache[43] || ~(ss_cache[42]))? ss_limit : w_upper_limit; w_push_bound_lo = w_push_bound - 2)
wire [31:0] w_push_bound    = ss_bound_r;
wire [31:0] w_push_bound_lo = ss_bound_lo_r;
wire        w_push_room_0   = wr_stack_offset == w_push_bound;
wire        w_push_room_lt3 = (ss_bound_ge2_r)? (wr_stack_offset >= w_push_bound_lo && wr_stack_offset <= w_push_bound) :
                                                (wr_stack_offset >= w_push_bound_lo || wr_stack_offset <= w_push_bound);
assign w_push_not_fit = (wr_push_length == 3'd2)? w_push_room_0 : w_push_room_lt3;

// (SiSTer: was
//      ((ss_cache[43] || !ss_cache[42]) && wr_stack_offset > ss_limit) ||
//      (!ss_cache[43] && ss_cache[42] && (wr_stack_offset <= ss_limit || wr_stack_offset > w_upper_limit));
//  the bound is ss_limit in the first case and w_upper_limit in the second, so it is the same as below)
assign w_push_limit_overflow =
    wr_stack_offset > w_push_bound || (!ss_cache[43] && ss_cache[42] && wr_stack_offset <= ss_limit);
    
assign wr_push_ss_fault = wr_push_ss_fault_check && (w_push_not_fit || w_push_limit_overflow);

//------------------------------------------------------------------------------

// synthesis translate_off
wire _unused_ok = &{ 1'b0, glob_descriptor[63:55], glob_descriptor[53:44], glob_descriptor[40:0], esp[15:0], ss_cache[63:55], ss_cache[53:44], ss_cache[41:0], 1'b0 };
// synthesis translate_on

//------------------------------------------------------------------------------

endmodule

