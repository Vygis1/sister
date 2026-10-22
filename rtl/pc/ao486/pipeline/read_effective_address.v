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

module read_effective_address(
    input               clk,
    input               rst_n,
    
    input               rd_reset,
    
    input               rd_address_effective_do,
    input               rd_ready,
    
    //general input
    input       [31:0]  eax,
    input       [31:0]  ebx,
    input       [31:0]  ecx,
    input       [31:0]  edx,
    input       [31:0]  esp,
    input       [31:0]  ebp,
    input       [31:0]  esi,
    input       [31:0]  edi,
        
    input       [63:0]  ss_cache,
    input       [31:0]  glob_param_3,
    
    input       [31:0]  wr_esp_prev,
    
    //rd input
    input               rd_address_16bit,
    input               rd_address_32bit,
    input               rd_operand_16bit,
    input               rd_operand_32bit,
    input       [87:0]  rd_decoder,
    input       [2:0]   rd_modregrm_rm,
    input       [2:0]   rd_modregrm_reg,
    input       [1:0]   rd_modregrm_mod,
    input       [7:0]   rd_sib,
    
    //address control
    input               address_enter_init,
    input               address_enter,
    input               address_enter_last,
    input               address_leave,
    input               address_esi,
    input               address_edi,
    input               address_xlat_transform,
    input               address_bits_transform,
    
    input               address_stack_pop,
    input               address_stack_pop_speedup,
    
    input               address_stack_pop_next,
    input               address_stack_pop_esp_prev,
    input               address_stack_pop_for_call,
    input               address_stack_save,
    input               address_stack_add_4_to_saved,
    
    input               address_stack_for_ret_first,
    input               address_stack_for_ret_second,
    input               address_stack_for_iret_first,
    input               address_stack_for_iret_second,
    input               address_stack_for_iret_third,
    input               address_stack_for_iret_last,
    input               address_stack_for_iret_to_v86,
    input               address_stack_for_call_param_first,
    
    input               address_ea_buffer,
    input               address_ea_buffer_plus_2,
    
    input               address_memoffset,
    
    //output
    output reg          rd_address_effective_ready,
    output reg  [31:0]  rd_address_effective
);

//------------------------------------------------------------------------------ modregrm

wire [15:0] address_disp16;
wire [15:0] base16;
wire [15:0] disp16;
wire [15:0] base16_plus_disp16;

wire [31:0] address_disp32_no_sib;
wire [31:0] address_disp32_sib;
wire [31:0] address_disp32;
wire [31:0] sib_base32;
wire [31:0] sib_index32;
wire [31:0] sib_index32_scaled;
wire [31:0] sib_base32_plus_index32_scaled;
wire [31:0] base32;
wire [31:0] disp32;
wire [31:0] base32_plus_disp32;

wire [31:0] address_effective_modrm;

//------------------------------------------------------------------------------ modregrm 16-bit

assign address_disp16  = rd_decoder[31:16]; 


assign base16 =
    (rd_modregrm_rm == 3'b000)?     ebx[15:0] + esi[15:0] :
    (rd_modregrm_rm == 3'b001)?     ebx[15:0] + edi[15:0] :
    (rd_modregrm_rm == 3'b010)?     ebp[15:0] + esi[15:0] :
    (rd_modregrm_rm == 3'b011)?     ebp[15:0] + edi[15:0] :
    (rd_modregrm_rm == 3'b100)?     esi[15:0] :
    (rd_modregrm_rm == 3'b101)?     edi[15:0] :
    (rd_modregrm_rm == 3'b110)?     ebp[15:0] :
                                    ebx[15:0];

assign disp16 =
    (rd_modregrm_mod == 2'b10)?     address_disp16 :
    (rd_modregrm_mod == 2'b01)?     { {8{address_disp16[7]}}, address_disp16[7:0] } :
                                    16'd0;

// (SiSTer: was base16 + disp16, base16 itself a sum of two registers for rm 000..011: the same three-operand
//  sum, mod 2^16, as a carry-save add -- one carry chain instead of two in a row)
wire [15:0] ea16_a =
    (rd_modregrm_rm == 3'b000 || rd_modregrm_rm == 3'b001 || rd_modregrm_rm == 3'b111)?   ebx[15:0] :
    (rd_modregrm_rm == 3'b010 || rd_modregrm_rm == 3'b011 || rd_modregrm_rm == 3'b110)?   ebp[15:0] :
    (rd_modregrm_rm == 3'b100)?                                                         esi[15:0] :
                                                                                        edi[15:0];
wire [15:0] ea16_b =
    (rd_modregrm_rm == 3'b000 || rd_modregrm_rm == 3'b010)?     esi[15:0] :
    (rd_modregrm_rm == 3'b001 || rd_modregrm_rm == 3'b011)?     edi[15:0] :
                                                                16'd0;
wire [15:0] ea16_sum   = ea16_a ^ ea16_b ^ disp16;
wire [15:0] ea16_carry = { (ea16_a[14:0] & ea16_b[14:0]) | (ea16_a[14:0] & disp16[14:0]) | (ea16_b[14:0] & disp16[14:0]), 1'b0 };
assign base16_plus_disp16 = ea16_sum + ea16_carry;

//------------------------------------------------------------------------------ modregrm 32-bit

assign address_disp32_no_sib = rd_decoder[47:16];
assign address_disp32_sib    = rd_decoder[55:24];
assign address_disp32        = (rd_modregrm_rm == 3'b100)? address_disp32_sib : address_disp32_no_sib;

assign sib_base32 =
    (rd_sib[2:0] == 3'b000)?                               eax :
    (rd_sib[2:0] == 3'b001)?                               ecx :
    (rd_sib[2:0] == 3'b010)?                               edx :
    (rd_sib[2:0] == 3'b011)?                               ebx :
    (rd_sib[2:0] == 3'b100)?                               esp :
    (rd_sib[2:0] == 3'b101 && rd_modregrm_mod == 2'b00)?   address_disp32_sib :
    (rd_sib[2:0] == 3'b101)?                               ebp :
    (rd_sib[2:0] == 3'b110)?                               esi :
                                                                edi;

assign sib_index32 =
    (rd_sib[5:3] == 3'b000)?   eax :
    (rd_sib[5:3] == 3'b001)?   ecx :
    (rd_sib[5:3] == 3'b010)?   edx :
    (rd_sib[5:3] == 3'b011)?   ebx :
    (rd_sib[5:3] == 3'b100)?   32'd0 :
    (rd_sib[5:3] == 3'b101)?   ebp :
    (rd_sib[5:3] == 3'b110)?   esi :
                                    edi;

assign sib_index32_scaled =
    (rd_sib[7:6] == 2'b00)?      sib_index32 :
    (rd_sib[7:6] == 2'b01)?    { sib_index32[30:0], 1'b0 } :
    (rd_sib[7:6] == 2'b10)?    { sib_index32[29:0], 2'b0 } :
                                    { sib_index32[28:0], 3'b0 };

assign sib_base32_plus_index32_scaled = sib_base32 + sib_index32_scaled;

assign base32 =
    (rd_modregrm_rm == 3'b000)?     eax :
    (rd_modregrm_rm == 3'b001)?     ecx :
    (rd_modregrm_rm == 3'b010)?     edx :
    (rd_modregrm_rm == 3'b011)?     ebx :
    (rd_modregrm_rm == 3'b100)?     sib_base32_plus_index32_scaled :
    (rd_modregrm_rm == 3'b101)?     ebp :
    (rd_modregrm_rm == 3'b110)?     esi :
                                    edi;

assign disp32 =
    (rd_modregrm_mod == 2'b10)?     address_disp32 :
    (rd_modregrm_mod == 2'b01)?     { {24{address_disp32[7]}}, address_disp32[7:0] } :
                                    32'd0;

// (SiSTer: was base32 + disp32, base32 being sib_base32 + sib_index32_scaled for rm 100: the same sum,
//  mod 2^32, as a carry-save add of three operands -- one carry chain instead of two in a row)
wire [31:0] ea32_a =
    (rd_modregrm_rm == 3'b000)?     eax :
    (rd_modregrm_rm == 3'b001)?     ecx :
    (rd_modregrm_rm == 3'b010)?     edx :
    (rd_modregrm_rm == 3'b011)?     ebx :
    (rd_modregrm_rm == 3'b100)?     sib_base32 :
    (rd_modregrm_rm == 3'b101)?     ebp :
    (rd_modregrm_rm == 3'b110)?     esi :
                                    edi;
wire [31:0] ea32_b = (rd_modregrm_rm == 3'b100)? sib_index32_scaled : 32'd0;
wire [31:0] ea32_sum   = ea32_a ^ ea32_b ^ disp32;
wire [31:0] ea32_carry = { (ea32_a[30:0] & ea32_b[30:0]) | (ea32_a[30:0] & disp32[30:0]) | (ea32_b[30:0] & disp32[30:0]), 1'b0 };
assign base32_plus_disp32 = ea32_sum + ea32_carry;

//------------------------------------------------------------------------------ modregrm final

assign address_effective_modrm =
    (rd_address_16bit && rd_modregrm_mod == 2'b00 && rd_modregrm_rm == 3'b110)?     { 16'd0, address_disp16 } :
    (rd_address_32bit && rd_modregrm_mod == 2'b00 && rd_modregrm_rm == 3'b101)?     address_disp32_no_sib :
    (rd_address_16bit)?                                                             { 16'd0, base16_plus_disp16 } :
                                                                                    base32_plus_disp32;
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------
//------------------------------------------------------------------------------
                                                                                    
//------------------------------------------------------------------------------ string

wire [31:0] esi_offset;
wire [31:0] edi_offset;

assign esi_offset = (rd_address_16bit)? { 16'd0, esi[15:0] } : esi;
assign edi_offset = (rd_address_16bit)? { 16'd0, edi[15:0] } : edi;

//------------------------------------------------------------------------------ stack pop

wire [31:0] pop_next;
wire [31:0] pop_offset_speedup_next;
wire [31:0] pop_offset;

reg [31:0]  pop_offset_speedup;

assign pop_next =
    (address_stack_pop_speedup && rd_operand_16bit)?    pop_offset_speedup + 32'd2 :
    (address_stack_pop_speedup)?                        pop_offset_speedup + 32'd4 :
    (rd_operand_16bit)?                                 esp + 32'd2 :
                                                        esp + 32'd4;

assign pop_offset_speedup_next = (ss_cache[`DESC_BIT_D_B])? pop_next : { 16'd0, pop_next[15:0] };

always @(posedge clk) begin
    if(rst_n == 1'b0)   pop_offset_speedup <= 32'd0;
    else if(rd_ready)   pop_offset_speedup <= pop_offset_speedup_next;
end

assign pop_offset = 
    (address_stack_pop_speedup)?    pop_offset_speedup :
    (ss_cache[`DESC_BIT_D_B])?      esp :
                                    { 16'd0, esp[15:0] };

//------------------------------------------------------------------------------ stack pop for ret

wire [31:0] stack_initial;
wire [31:0] stack;
wire [31:0] stack_for_ret_first;
wire [31:0] stack_for_ret_second_imm_offset;
wire [31:0] stack_for_ret_second;
wire [31:0] stack_for_iret_first;
wire [31:0] stack_for_iret_second;
wire [31:0] stack_for_iret_third;
wire [31:0] stack_for_iret_to_v86;

wire [31:0] stack_for_call_param_first;

wire [31:0] stack_next;

reg  [31:0] stack_saved;

wire [31:0] stack_offset;

wire [4:0]  call_gate_param;

assign stack_initial =
    (address_stack_pop_esp_prev)?   wr_esp_prev :
                                    esp;

assign stack =
    (ss_cache[`DESC_BIT_D_B])?  stack_initial :
                                { 16'd0, stack_initial[15:0] };

assign stack_for_ret_first =
    (rd_operand_16bit)? stack + 32'd2 :
                        stack + 32'd4;

assign stack_for_ret_second_imm_offset =
    (rd_decoder[0] == 1'b0)?    { 16'd0, rd_decoder[23:8] } :
                                32'd0;

assign stack_for_ret_second =
    (rd_operand_16bit)? stack + 32'd6  + stack_for_ret_second_imm_offset :
                        stack + 32'd12 + stack_for_ret_second_imm_offset;
                        
assign stack_for_iret_first =
    (rd_operand_16bit)? stack + 32'd4 :
                        stack + 32'd8;
                        
assign stack_for_iret_second =
    (rd_operand_16bit)? stack + 32'd8 :
                        stack + 32'd16;
                       
assign stack_for_iret_third =
    (rd_operand_16bit)? stack + 32'd6 :
                        stack + 32'd12;
                        
assign stack_for_iret_to_v86 = stack + 32'd12;


assign call_gate_param = glob_param_3[24:20] - 5'd1;

assign stack_for_call_param_first =
    (~(glob_param_3[19]))?  stack + { 26'd0, call_gate_param, 1'b0 } :
                            stack + { 25'd0, call_gate_param, 2'b0 };

assign stack_next =
    (address_stack_pop_for_call && ~(glob_param_3[19]))?    stack_saved - 32'd2 :
    (address_stack_pop_for_call)?                           stack_saved - 32'd4 :
    (rd_operand_16bit)?                                     stack_saved - 32'd2 :
                                                            stack_saved - 32'd4;

always @(posedge clk) begin
    if(rst_n == 1'b0)                                   stack_saved <= 32'd0;
    else if(rd_ready && address_stack_add_4_to_saved)   stack_saved <= stack_saved + 32'd4;
    else if(rd_ready)                                   stack_saved <= stack_next;
    else if(address_stack_save)                         stack_saved <= stack_offset;
end

assign stack_offset =
    (address_stack_for_ret_first)?          stack_for_ret_first :
    (address_stack_for_ret_second)?         stack_for_ret_second :
    (address_stack_for_iret_first)?         stack_for_iret_first :
    (address_stack_for_iret_second)?        stack_for_iret_second :
    (address_stack_for_iret_third)?         stack_for_iret_third :
    (address_stack_for_iret_last)?          stack :
    (address_stack_for_iret_to_v86)?        stack_for_iret_to_v86 :
    (address_stack_for_call_param_first)?   stack_for_call_param_first :
                                            stack_saved;
                                    
//------------------------------------------------------------------------------ XLAT

wire [31:0] xlat_offset;

assign xlat_offset = ebx + { 24'b0, eax[7:0] };

//------------------------------------------------------------------------------ LEAVE

wire [31:0] ebp_for_leave_offset;

assign ebp_for_leave_offset = (ss_cache[`DESC_BIT_D_B])? ebp : { 16'd0, ebp[15:0] };

//------------------------------------------------------------------------------ bit operations

wire [31:0] address_bits_transform_reg;
wire [31:0] address_bits_transform_sum;

assign address_bits_transform_reg =
    (rd_modregrm_reg == 3'b000)?    eax :
    (rd_modregrm_reg == 3'b001)?    ecx :
    (rd_modregrm_reg == 3'b010)?    edx :
    (rd_modregrm_reg == 3'b011)?    ebx :
    (rd_modregrm_reg == 3'b100)?    esp :
    (rd_modregrm_reg == 3'b101)?    ebp :
    (rd_modregrm_reg == 3'b110)?    esi :
                                    edi;

// (SiSTer: was
//      (rd_operand_32bit)? address_effective_modrm + T32 : address_effective_modrm + T16
//  (T: the bit offset's word/dword part, the two constants below), address_effective_modrm being one of four sums.
//  Here T is added to each of the four as one more carry-save stage -- for the 32-bit modrm form the four operands
//  ea32_a + ea32_b + disp32 + T in one carry chain -- and the same four-way choice picks. For the two 16-bit forms
//  only bits 15..0 are used: rd_address_effective takes { {16{rd_address_32bit}} & sum[31:16], sum[15:0] }, and
//  rd_address_32bit is low for them, so their upper halves (here the 16-bit sums' carries out are not kept) are
//  never read. All sums mod 2^32 / 2^16, as before)
wire [31:0] bt_t =
    (rd_operand_32bit)?     { { 3{address_bits_transform_reg[31]}}, address_bits_transform_reg[31:5], 2'b0 } :
                            { {19{address_bits_transform_reg[15]}}, address_bits_transform_reg[15:4], 1'b0 };
wire [31:0] bt32_s = ea32_sum ^ ea32_carry ^ bt_t;
wire [31:0] bt32_c = { (ea32_sum[30:0] & ea32_carry[30:0]) | (ea32_sum[30:0] & bt_t[30:0]) | (ea32_carry[30:0] & bt_t[30:0]), 1'b0 };
wire [31:0] bt32   = bt32_s + bt32_c;
wire [15:0] bt16_s = ea16_sum ^ ea16_carry ^ bt_t[15:0];
wire [15:0] bt16_c = { (ea16_sum[14:0] & ea16_carry[14:0]) | (ea16_sum[14:0] & bt_t[14:0]) | (ea16_carry[14:0] & bt_t[14:0]), 1'b0 };
wire [15:0] bt16   = bt16_s + bt16_c;
wire [15:0] bt_disp16      = address_disp16 + bt_t[15:0];
wire [31:0] bt_disp32      = address_disp32_no_sib + bt_t;
assign address_bits_transform_sum =
    (rd_address_16bit && rd_modregrm_mod == 2'b00 && rd_modregrm_rm == 3'b110)?     { 16'd0, bt_disp16 } :
    (rd_address_32bit && rd_modregrm_mod == 2'b00 && rd_modregrm_rm == 3'b101)?     bt_disp32 :
    (rd_address_16bit)?                                                             { 16'd0, bt16 } :
                                                                                    bt32;

//------------------------------------------------------------------------------ ENTER

wire [31:0] ebp_for_enter_next;
wire [31:0] ebp_for_enter_offset;

reg  [31:0] ebp_for_enter;

wire [31:0] esp_for_enter_next;
wire [31:0] esp_for_enter_offset;


assign ebp_for_enter_next    = (rd_operand_16bit)? ebp_for_enter - 32'd2 : ebp_for_enter - 32'd4;
assign ebp_for_enter_offset = (ss_cache[`DESC_BIT_D_B])? ebp_for_enter_next : { 16'd0, ebp_for_enter_next[15:0] };

always @(posedge clk) begin
    if(rst_n == 1'b0)           ebp_for_enter <= 32'd0;
    else if(address_enter_init) ebp_for_enter <= ebp;
    else if(rd_ready)           ebp_for_enter <= ebp_for_enter_offset;
end

assign esp_for_enter_next    = esp - { 16'd0, rd_decoder[23:8] };
assign esp_for_enter_offset = (ss_cache[`DESC_BIT_D_B])? esp_for_enter_next : { 16'd0, esp_for_enter_next[15:0] };
                            
//------------------------------------------------------------------------------ ea buffer
    
wire [31:0] ea_buffer_sum;
wire [31:0] ea_buffer_next;

reg  [31:0] ea_buffer;
                                        
assign ea_buffer_sum  =
    (rd_operand_16bit || address_ea_buffer_plus_2)? rd_address_effective + 32'd2 :
                                                    rd_address_effective + 32'd4;

assign ea_buffer_next = (rd_address_16bit)? { 16'd0, ea_buffer_sum[15:0] } : ea_buffer_sum;

always @(posedge clk) begin
    if(rst_n == 1'b0)                               ea_buffer <= 32'd0;
    else if(rd_ready && rd_address_effective_ready) ea_buffer <= ea_buffer_next;
end

//------------------------------------------------------------------------------ final effective address

always @(posedge clk) begin
    if(rst_n == 1'b0)                   rd_address_effective_ready <= `FALSE;
    else if(rd_ready || rd_reset)       rd_address_effective_ready <= `FALSE;
    else if(rd_address_effective_do)    rd_address_effective_ready <= `TRUE;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)                               rd_address_effective <= 32'd0;
    else if(address_memoffset && rd_address_16bit)  rd_address_effective <= { 16'd0, rd_decoder[23:8] };
    else if(address_memoffset && rd_address_32bit)  rd_address_effective <= rd_decoder[39:8];
    else if(address_ea_buffer)                      rd_address_effective <= ea_buffer;
    else if(address_enter)                          rd_address_effective <= ebp_for_enter_offset;
    else if(address_enter_last)                     rd_address_effective <= esp_for_enter_offset;
    else if(address_leave)                          rd_address_effective <= ebp_for_leave_offset;
    else if(address_esi)                            rd_address_effective <= esi_offset;
    else if(address_edi)                            rd_address_effective <= edi_offset;
    else if(address_stack_pop)                      rd_address_effective <= pop_offset;
    else if(address_stack_pop_next)                 rd_address_effective <= stack_offset;
    else if(address_xlat_transform)                 rd_address_effective <= { {16{rd_address_32bit}} & xlat_offset[31:16], xlat_offset[15:0] };
    else if(address_bits_transform)                 rd_address_effective <= { {16{rd_address_32bit}} & address_bits_transform_sum[31:16], address_bits_transform_sum[15:0] };
    else                                            rd_address_effective <= address_effective_modrm;
end

//------------------------------------------------------------------------------

// synthesis translate_off
wire _unused_ok = &{ 1'b0, ss_cache[63:55], ss_cache[53:0], glob_param_3[31:25], glob_param_3[18:0], rd_decoder[87:56], rd_decoder[7:1], address_bits_transform_reg[3:0], 1'b0 };
// synthesis translate_on

//------------------------------------------------------------------------------

endmodule
