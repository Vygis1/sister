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

module read(
    input               clk,
    input               rst_n,
    
    input               rd_reset,
    
    //debug input
    input       [31:0]  dr0,
    input       [31:0]  dr1,
    input       [31:0]  dr2,
    input       [31:0]  dr3,
    input       [31:0]  dr7,
    
    input       [2:0]   debug_len0,
    input       [2:0]   debug_len1,
    input       [2:0]   debug_len2,
    input       [2:0]   debug_len3,
    
    //global input
    input       [63:0]  glob_descriptor,
    
    input       [31:0]  glob_param_1,
    input       [31:0]  glob_param_2,
    input       [31:0]  glob_param_3,
    
    input       [31:0]  glob_desc_limit,
    input       [31:0]  glob_desc_base,
    
    //general input
    input       [15:0]  gdtr_limit,
    
    input       [31:0]  gdtr_base,
    input       [31:0]  idtr_base,
    
    input               es_cache_valid,
    input       [63:0]  es_cache,
    
    input               cs_cache_valid,
    input       [63:0]  cs_cache,
    
    input               ss_cache_valid,
    input       [63:0]  ss_cache,
    
    input               ds_cache_valid,
    input       [63:0]  ds_cache,
    
    input               fs_cache_valid,
    input       [63:0]  fs_cache,
    
    input               gs_cache_valid,
    input       [63:0]  gs_cache,
    
    input               tr_cache_valid,
    input       [63:0]  tr_cache,
    input       [15:0]  tr,
    
    input               ldtr_cache_valid,
    input       [63:0]  ldtr_cache,
    
    input       [1:0]   cpl,
    
    input       [1:0]   iopl,
    
    input               cr0_pg,
    
    input               real_mode,
    input               v8086_mode,
    input               protected_mode,
    
    input               io_allow_check_needed,
    
    input       [31:0]  eax,
    input       [31:0]  ebx,
    input       [31:0]  ecx,
    input               ecx_lo_is_0,    // (SiSTer: ecx[15:0] == 0, registered with ecx -- write_register.v)
    input               ecx_hi_is_0,    // (SiSTer: ecx[31:16] == 0)
    input       [31:0]  edx,
    input       [31:0]  esp,
    input       [31:0]  ebp,
    input       [31:0]  esi,
    input       [31:0]  edi,
    
    //pipeline input
    input               exe_trigger_gp_fault,
    
    input       [10:0]  exe_mutex,
    input       [10:0]  wr_mutex,
    
    input       [31:0]  wr_esp_prev,
    
    input       [7:0]   exc_vector,
    
    //rd exception
    output              rd_io_allow_fault,
    output      [15:0]  rd_error_code,
    output              rd_descriptor_gp_fault,
    output reg          rd_seg_gp_fault,
    output reg          rd_seg_ss_fault,
    output              rd_ss_esp_from_tss_fault,
    
    //pipeline state
    output              rd_dec_is_front,
    output              rd_is_front,
    
    //glob output
    output              rd_glob_descriptor_set,
    output      [63:0]  rd_glob_descriptor_value,
    
    output              rd_glob_descriptor_2_set,
    output      [63:0]  rd_glob_descriptor_2_value,
    
    output              rd_glob_param_1_set,
    output      [31:0]  rd_glob_param_1_value,
    output              rd_glob_param_2_set,
    output      [31:0]  rd_glob_param_2_value,
    output              rd_glob_param_3_set,
    output      [31:0]  rd_glob_param_3_value,
    output              rd_glob_param_4_set,
    output      [31:0]  rd_glob_param_4_value,
    output              rd_glob_param_5_set,
    output      [31:0]  rd_glob_param_5_value,
    
    //io_read
    output              io_read_do,
    output      [15:0]  io_read_address,
    output      [2:0]   io_read_length,
    input       [31:0]  io_read_data,
    input               io_read_done,
    
    //read
    output              read_do,
    input               read_done,
    input               read_done_r0,   // (SiSTer: read_done when rd_reset is low)
    input               read_page_fault,
    input               read_ac_fault,
    
    output      [1:0]   read_cpl,
    output      [31:0]  read_address,
    output      [3:0]   read_length,
    output              read_lock,
    output              read_rmw,
    input       [63:0]  read_data,
    
    //micro pipeline
    output              rd_busy,
    // (SiSTer: rd_busy == rd_busy_nw || rd_stall_w; rd_stall_w is the write stage's wr_busy reaching back
    //  through the execute stage -- microcode.v and decode.v take it last)
    output              rd_busy_nw,
    output              rd_stall_w,
    input               exe_busy_nw,
    input               exe_has_cmd,
    input               exe_waiting,
    input               wr_busy,
    input               micro_ready,
        
    input       [87:0]  micro_decoder,
    input       [31:0]  micro_eip,
    input               micro_operand_32bit,
    input               micro_address_32bit,
    input       [1:0]   micro_prefix_group_1_rep,
    input               micro_prefix_group_1_lock,
    input       [2:0]   micro_prefix_group_2_seg,
    input               micro_prefix_2byte,
    input       [3:0]   micro_consumed,
    input       [2:0]   micro_modregrm_len,
    input               micro_is_8bit,
    input       [6:0]   micro_cmd,
    input       [3:0]   micro_cmdex,
    
    //rd pipeline
    input               exe_busy,
    output              rd_ready,
    
    output reg  [87:0]  rd_decoder,
    output reg  [31:0]  rd_eip,
    output reg          rd_operand_32bit,
    output reg          rd_address_32bit,
    output reg  [1:0]   rd_prefix_group_1_rep,
    output reg          rd_prefix_group_1_lock,
    output reg          rd_prefix_2byte,
    output reg  [3:0]   rd_consumed,
    output reg          rd_is_8bit,
    output reg  [6:0]   rd_cmd,
    output reg  [3:0]   rd_cmdex,
    output      [31:0]  rd_modregrm_imm,
    output      [10:0]  rd_mutex_next,
    output              rd_dst_is_reg,
    output              rd_dst_is_rm,
    output              rd_dst_is_memory,
    output              rd_dst_is_eax,
    output              rd_dst_is_edx_eax,
    output              rd_dst_is_implicit_reg,
    output      [31:0]  rd_extra_wire,
    output      [31:0]  rd_linear,
    output      [3:0]   rd_debug_read,
    output      [31:0]  src_wire,
    output      [31:0]  dst_wire,
    output      [31:0]  rd_address_effective
);

//------------------------------------------------------------------------------

wire r_load;

wire [1:0]  rd_modregrm_mod;
wire [2:0]  rd_modregrm_reg;
wire [2:0]  rd_modregrm_rm;
wire [7:0]  rd_sib;

wire        rd_operand_16bit;
wire        rd_address_16bit;


wire        rd_descriptor_not_in_limits;
wire [31:0] rd_descriptor_offset;

reg  rd_address_effective_ready_delayed;
wire write_virtual_check_ready;

//------------------------------------------------------------------------------

wire memory_read_system;
reg  rd_one_mem_read;
wire read_for_rd_ready;

wire [31:0] read_4;
wire [63:0] read_8;

//------------------------------------------------------------------------------

wire rd_io_ready;
reg  rd_one_io_read;


//------------------------------------------------------------------------------

wire [2:0]  src_reg_index;
wire [2:0]  dst_reg_index;

//------------------------------------------------------------------------------

reg [31:0]  rd_memory_last;

//------------------------------------------------------------------------------

wire [31:0] rd_seg_linear;

wire [31:0] tr_base;
wire [31:0] ldtr_base;

wire [31:0] tr_limit;
wire [31:0] ldtr_limit;

//------------------------------------------------------------------------------

wire        rd_address_effective_ready;

wire        rd_address_effective_do;

//------------------------------------------------------------------------------

wire rd_mutex_busy_active;
wire rd_mutex_busy_memory;
wire rd_mutex_busy_eflags;
wire rd_mutex_busy_ebp;
wire rd_mutex_busy_esp;
wire rd_mutex_busy_edx;
wire rd_mutex_busy_ecx;
wire rd_mutex_busy_eax;
wire rd_mutex_busy_modregrm_reg;
wire rd_mutex_busy_modregrm_rm;
wire rd_mutex_busy_implicit_reg;

wire rd_address_waiting;

//------------------------------------------------------------------------------

wire [31:0] rd_system_linear;
wire        rd_waiting;

wire rd_req_memory;
wire rd_req_eflags;
wire rd_req_all;
wire rd_req_reg;
wire rd_req_rm;
wire rd_req_implicit_reg;
wire rd_req_reg_not_8bit;
wire rd_req_edi;
wire rd_req_esi;
wire rd_req_ebp;
wire rd_req_esp;
wire rd_req_ebx;
wire rd_req_edx_eax;
wire rd_req_edx;
wire rd_req_ecx;
wire rd_req_eax;

wire address_enter_init;
wire address_enter;
wire address_enter_last;
wire address_leave;
wire address_esi;
wire address_edi;
wire address_xlat_transform;
wire address_bits_transform;
wire address_stack_pop;
wire address_stack_pop_speedup;
wire address_stack_pop_next;
wire address_stack_pop_esp_prev;
wire address_stack_pop_for_call;
wire address_stack_save;
wire address_stack_add_4_to_saved;
wire address_stack_for_ret_first;
wire address_stack_for_ret_second;
wire address_stack_for_iret_first;
wire address_stack_for_iret_second;
wire address_stack_for_iret_third;
wire address_stack_for_iret_last;
wire address_stack_for_iret_to_v86;
wire address_stack_for_call_param_first;
wire address_ea_buffer;
wire address_ea_buffer_plus_2;
wire address_memoffset;

wire read_virtual;
wire read_rmw_virtual;
wire write_virtual_check;

wire read_system_descriptor;
wire read_system_word;
wire read_system_dword;
wire read_system_qword;
wire read_rmw_system_dword;

wire read_length_word;
wire read_length_dword;

wire rd_src_is_memory;
wire rd_src_is_io;
wire rd_src_is_modregrm_imm;
wire rd_src_is_modregrm_imm_se;
wire rd_src_is_imm;
wire rd_src_is_imm_se;
wire rd_src_is_1;
wire rd_src_is_eax;
wire rd_src_is_ecx;
wire rd_src_is_cmdex;
wire rd_src_is_implicit_reg;
wire rd_src_is_rm;
wire rd_src_is_reg; //not used

wire rd_dst_is_0;
wire rd_dst_is_modregrm_imm_se;
wire rd_dst_is_modregrm_imm;
wire rd_dst_is_memory_last;
wire rd_dst_is_eip;


//------------------------------------------------------------------------------

// (SiSTer: rd_ready and rd_busy settled for both values of rd_reset, the late end of the write stage's
//  reset requests, and chosen by it last. Was
//      rd_ready = ~(rd_reset) && ~(rd_waiting) && rd_cmd != `CMD_NULL && ~(exe_busy);
//      rd_busy  = rd_waiting || (rd_ready == `FALSE && rd_cmd != `CMD_NULL);
//  rd_reset low: rd_waiting is rd_waiting_r0 (read_commands_r0_inst: the same logic fed with
//  read_done_r0 and write_virtual_check_ready_r0, which equal read_done and write_virtual_check_ready
//  whenever rd_reset is low), so rd_ready = ~rd_waiting_r0 && cmd && ~exe_busy and
//  rd_busy = rd_waiting_r0 || (cmd && exe_busy).
//  rd_reset high: rd_ready is 0, and rd_busy = rd_waiting || cmd = cmd -- every rd_waiting term needs
//  an rd_cmd other than CMD_NULL (autogen/read_commands.v), so rd_waiting implies rd_cmd != CMD_NULL)
wire rd_waiting_r0;
wire rd_waiting_r0_f0, rd_waiting_r0_f1;   // (SiSTer: read_commands_r0f0/f1_inst)
// (SiSTer, further: exe_busy is exe_busy_nw || exe_waiting || (exe_has_cmd && wr_busy) (execute.v), so
//      rd_ready = rd_ready_nw && ~exe_waiting && ~(exe_has_cmd && wr_busy)
//      rd_busy  = rd_busy_nw || rd_stall_w,   rd_stall_w = ~rd_reset && rd_cmd != NULL && (exe_waiting || (exe_has_cmd && wr_busy))
//  with the _nw terms the same expressions with exe_busy_nw; they are kept as nets of their own so that
//  exe_waiting and wr_busy meet only the last gate)
(* keep = "true" *) wire rd_ready_nw = ~(rd_reset) && ~(rd_waiting_r0) && ~(rd_io_allow_2_fault_w) && rd_cmd != `CMD_NULL && ~(exe_busy_nw);
(* keep = "true" *) wire rd_has_cmd_nr = ~(rd_reset) && rd_cmd != `CMD_NULL;

assign rd_ready = rd_ready_nw && ~(exe_waiting) && ~(exe_has_cmd && wr_busy);

assign rd_busy_nw = (rd_reset)? rd_cmd != `CMD_NULL : rd_waiting_r0 || rd_io_allow_2_fault_w || (rd_cmd != `CMD_NULL && exe_busy_nw);
assign rd_stall_w = rd_has_cmd_nr && (exe_waiting || (exe_has_cmd && wr_busy));
assign rd_busy    = rd_busy_nw || rd_stall_w;

// (SiSTer: both read_commands instances are built with io_allow_2_fault_off, as if CMD_io_allow's step-2
//  permission compare (rd_memory_last + port/8 >= tr_limit: an add and a compare) were false, and it is
//  applied here, last. It is cond_36 of autogen/read_commands.v and only ever true with cond_35 (rd_cmd ==
//  CMD_io_allow, step 2); every output that reads it has its cond_35 terms ahead of any other term for
//  that command (all of their other terms need another rd_cmd), so with the compare c:
//      rd_io_allow_fault = nf || c       (it is rd_io_allow_1_fault || rd_io_allow_2_fault)
//      rd_waiting        = nf || c       ((cond_35 && cond_36)? TRUE : (cond_35 && ~cond_36 && cond_5)? ...)
//      read_system_word  = nf && ~c      ((cond_35 && ~cond_36)? TRUE)
//      rd_src_is_memory  = nf && ~c      ((cond_35 && ~cond_36)? TRUE)
//  where nf is the output built with the compare false; rd_ready_r0 and rd_busy above use rd_waiting_r0 || c)
wire rd_io_allow_fault_nf;
wire rd_io_allow_2_fault_w;
wire rd_src_is_memory_nf;
wire read_system_word_nf;
assign rd_io_allow_fault = rd_io_allow_fault_nf || rd_io_allow_2_fault_w;
assign read_system_word  = read_system_word_nf && ~(rd_io_allow_2_fault_w);
assign rd_src_is_memory  = rd_src_is_memory_nf && ~(rd_io_allow_2_fault_w);

assign r_load = micro_ready;

//------------------------------------------------------------------------------

reg [2:0]   rd_modregrm_len;
reg [2:0]   rd_prefix_group_2_seg;

always @(posedge clk) begin if(rst_n == 1'b0) rd_decoder              <= 88'd0;     else if(r_load) rd_decoder              <= micro_decoder;              end
always @(posedge clk) begin if(rst_n == 1'b0) rd_eip                  <= 32'd0;     else if(r_load) rd_eip                  <= micro_eip;                  end
always @(posedge clk) begin if(rst_n == 1'b0) rd_operand_32bit        <= `FALSE;    else if(r_load) rd_operand_32bit        <= micro_operand_32bit;        end
always @(posedge clk) begin if(rst_n == 1'b0) rd_address_32bit        <= `FALSE;    else if(r_load) rd_address_32bit        <= micro_address_32bit;        end
always @(posedge clk) begin if(rst_n == 1'b0) rd_prefix_group_1_rep   <= 2'd0;      else if(r_load) rd_prefix_group_1_rep   <= micro_prefix_group_1_rep;   end
always @(posedge clk) begin if(rst_n == 1'b0) rd_prefix_group_1_lock  <= `FALSE;    else if(r_load) rd_prefix_group_1_lock  <= micro_prefix_group_1_lock;  end
always @(posedge clk) begin if(rst_n == 1'b0) rd_prefix_group_2_seg   <= 3'd3;      else if(r_load) rd_prefix_group_2_seg   <= micro_prefix_group_2_seg;   end
always @(posedge clk) begin if(rst_n == 1'b0) rd_prefix_2byte         <= `FALSE;    else if(r_load) rd_prefix_2byte         <= micro_prefix_2byte;         end
always @(posedge clk) begin if(rst_n == 1'b0) rd_consumed             <= 4'd0;      else if(r_load) rd_consumed             <= micro_consumed;             end
always @(posedge clk) begin if(rst_n == 1'b0) rd_modregrm_len         <= 3'd0;      else if(r_load) rd_modregrm_len         <= micro_modregrm_len;         end
always @(posedge clk) begin if(rst_n == 1'b0) rd_is_8bit              <= `FALSE;    else if(r_load) rd_is_8bit              <= micro_is_8bit;              end
always @(posedge clk) begin if(rst_n == 1'b0) rd_cmdex                <= 4'd0;      else if(r_load) rd_cmdex                <= micro_cmdex;                end

always @(posedge clk) begin
    if(rst_n == 1'b0)   rd_cmd <= `CMD_NULL;
    else if(rd_reset)   rd_cmd <= `CMD_NULL;
    else if(r_load)     rd_cmd <= micro_cmd;
    else if(rd_ready)   rd_cmd <= `CMD_NULL;
end

//------------------------------------------------------------------------------

assign rd_modregrm_mod = rd_decoder[15:14];
assign rd_modregrm_reg = rd_decoder[13:11];
assign rd_modregrm_rm  = rd_decoder[10:8];
assign rd_sib          = rd_decoder[23:16];

assign rd_operand_16bit = ~(rd_operand_32bit);
assign rd_address_16bit = ~(rd_address_32bit);

//------------------------------------------------------------------------------

// synthesis translate_off
wire _unused_ok = &{ 1'b0, rd_src_is_reg, 1'b0 };
// synthesis translate_on

//------------------------------------------------------------------------------

always @(posedge clk) begin
    if(rst_n == 1'b0)                       rd_memory_last <= 32'd0;
    else if(read_for_rd_ready && rd_ready)  rd_memory_last <= read_4;
end

//------------------------------------------------------------------------------

assign rd_modregrm_imm =
    (rd_modregrm_len == 3'd2)?   rd_decoder[47:16] :
    (rd_modregrm_len == 3'd3)?   rd_decoder[55:24] :
    (rd_modregrm_len == 3'd4)?   rd_decoder[63:32] :
    (rd_modregrm_len == 3'd6)?   rd_decoder[79:48] :
                                 rd_decoder[87:56]; //rd_modregrm_len == 3'd7

assign src_reg_index =
    (rd_src_is_cmdex)?          rd_cmdex[2:0] :
    (rd_src_is_implicit_reg)?   rd_decoder[2:0] :
    (rd_src_is_rm)?             rd_modregrm_rm :
                                rd_modregrm_reg;

assign dst_reg_index =
    (rd_dst_is_implicit_reg)?   rd_decoder[2:0] :
    (rd_dst_is_rm)?             rd_modregrm_rm :
                                rd_modregrm_reg;

//------------------------------------------------------------------------------

// (SiSTer: was (rd_src_is_memory)? read_4 : <the rest>; rd_src_is_memory == rd_src_is_memory_nf &&
//  ~rd_io_allow_2_fault (see rd_busy), so the slow io-permission compare is applied last)
wire [31:0] src_wire_rest;
assign src_wire = (rd_src_is_memory_nf && ~(rd_io_allow_2_fault_w))? read_4 : src_wire_rest;

assign src_wire_rest =
    (rd_src_is_io)?                                         io_read_data :
    (rd_src_is_modregrm_imm)?                               rd_modregrm_imm :
    (rd_src_is_modregrm_imm_se)?                            { {24{rd_modregrm_imm[7]}}, rd_modregrm_imm[7:0] } :
    (rd_src_is_imm || (rd_src_is_imm_se && ~(rd_is_8bit)))? rd_decoder[39:8] :
    (rd_src_is_imm_se)?                                     { {24{rd_decoder[15]}}, rd_decoder[15:8] } :
    (rd_src_is_1)?                                          32'd1 :
    (rd_src_is_eax)?                                        eax :
    (rd_src_is_ecx)?                                        ecx :
    (src_reg_index == 3'd0)?                                eax :
    (src_reg_index == 3'd1)?                                ecx :
    (src_reg_index == 3'd2)?                                edx :
    (src_reg_index == 3'd3)?                                ebx :
    (src_reg_index == 3'd4 && rd_is_8bit)?                  { 24'd0, eax[15:8] } :
    (src_reg_index == 3'd4)?                                esp :
    (src_reg_index == 3'd5 && rd_is_8bit)?                  { 24'd0, ecx[15:8] } :
    (src_reg_index == 3'd5)?                                ebp :
    (src_reg_index == 3'd6 && rd_is_8bit)?                  { 24'd0, edx[15:8] } :
    (src_reg_index == 3'd6)?                                esi :
    (src_reg_index == 3'd7 && rd_is_8bit)?                  { 24'd0, ebx[15:8] } :
                                                            edi;


assign dst_wire =
    (rd_dst_is_0)?                              32'd0 :
    (rd_dst_is_modregrm_imm_se)?                { {24{rd_modregrm_imm[7]}}, rd_modregrm_imm[7:0] } :
    (rd_dst_is_modregrm_imm)?                   rd_modregrm_imm : //must be before reg
    (rd_dst_is_memory)?                         read_4 :
    (rd_dst_is_memory_last)?                    rd_memory_last :
    (rd_dst_is_eip)?                            rd_eip :
    (rd_dst_is_eax || rd_dst_is_edx_eax)?       eax :
    (dst_reg_index == 3'd0)?                    eax :
    (dst_reg_index == 3'd1)?                    ecx :
    (dst_reg_index == 3'd2)?                    edx :
    (dst_reg_index == 3'd3)?                    ebx :
    (dst_reg_index == 3'd4 && rd_is_8bit)?      { 24'd0, eax[15:8] } :
    (dst_reg_index == 3'd4)?                    esp :
    (dst_reg_index == 3'd5 && rd_is_8bit)?      { 24'd0, ecx[15:8] } :
    (dst_reg_index == 3'd5)?                    ebp :
    (dst_reg_index == 3'd6 && rd_is_8bit)?      { 24'd0, edx[15:8] } :
    (dst_reg_index == 3'd6)?                    esi :
    (dst_reg_index == 3'd7 && rd_is_8bit)?      { 24'd0, ebx[15:8] } :
                                                edi;

//------------------------------------------------------------------------------ io_read

always @(posedge clk) begin
    if(rst_n == 1'b0)               rd_one_io_read <= `FALSE;
    else if(rd_ready || rd_reset)   rd_one_io_read <= `FALSE;
    else if(io_read_done)           rd_one_io_read <= `TRUE;
end

assign io_read_length =
    (rd_is_8bit)?       3'd1 :
    (rd_operand_16bit)? 3'd2 :
                        3'd4;

wire io_read;

//NOTE: gp fault from CMDEX_io_allow_2
assign io_read_do = io_read && ~(io_read_done) && ~(rd_one_io_read) && ~(rd_reset) && ~(exe_trigger_gp_fault);

assign rd_io_ready = rd_one_io_read || io_read_done;

//------------------------------------------------------------------------------

wire rd_seg_gp_fault_init;
wire rd_seg_ss_fault_init;
wire rd_seg_fault_init;     // (SiSTer: rd_seg_gp_fault_init || rd_seg_ss_fault_init -- read_segment.v)

always @(posedge clk) begin
    if(rst_n == 1'b0)               rd_seg_gp_fault <= `FALSE;
    else if(rd_ready || rd_reset)   rd_seg_gp_fault <= `FALSE;
    else                            rd_seg_gp_fault <= rd_seg_gp_fault_init;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)               rd_seg_ss_fault <= `FALSE;
    else if(rd_ready || rd_reset)   rd_seg_ss_fault <= `FALSE;
    else                            rd_seg_ss_fault <= rd_seg_ss_fault_init;
end


//------------------------------------------------------------------------------ read memory

// (SiSTer: the same with read_system_word_nf, for read_do and read_segment: they differ from the exact ones
//  only under CMD_io_allow step 2 with its permission compare true, when read_do is low anyway
//  (~rd_io_allow_fault) and read_segment's fault needs seg_read/seg_write, never set for CMD_io_allow)
wire memory_read_system_nf = read_system_descriptor || read_system_word_nf || read_system_dword || read_system_qword || read_rmw_system_dword;
wire [3:0] read_length_nf =
    read_system_word_nf?        4'd2 :
    read_system_dword?          4'd4 :
    read_system_qword?          4'd8 :
    read_rmw_system_dword?      4'd4 :
    read_system_descriptor?     4'd8 :
    rd_is_8bit?                 4'd1 :
    read_length_word?           4'd2 :
    read_length_dword?          4'd4 :
    rd_operand_16bit?           4'd2 :
                                4'd4;

// (SiSTer: was read_system_descriptor || read_system_word || read_system_dword || read_system_qword ||
//  read_rmw_system_dword. read_system_word is read_system_word_nf && ~c (c: the io-permission compare,
//  rd_io_allow_2_fault_w), so this is memory_read_system_nf with c applied last: when one of the other four
//  is set both are 1, else both are read_system_word_nf && ~c)
assign memory_read_system = memory_read_system_nf &&
    ~(rd_io_allow_2_fault_w && ~(read_system_descriptor || read_system_dword || read_system_qword || read_rmw_system_dword));


assign read_cpl  = (memory_read_system)? 2'd0 : cpl;
assign read_rmw  = read_rmw_virtual || read_rmw_system_dword;
assign read_lock = rd_prefix_group_1_lock;


assign read_address =
    (read_rmw_virtual || read_virtual)?     rd_seg_linear :
    (read_system_descriptor)?               rd_descriptor_offset :
                                            rd_system_linear; //used by read_rmw_system_dword, read_system_dword,read_system_word,read_system_qword

// (SiSTer: read_system_word is read_system_word_nf && ~c, so read_length is read_length_nf when c is low and
//  the same chain with read_system_word low when c is high: c, the slow io-permission compare, picks last)
wire [3:0] read_length_w0 =
    read_system_dword?          4'd4 :
    read_system_qword?          4'd8 :
    read_rmw_system_dword?      4'd4 :
    read_system_descriptor?     4'd8 :
    rd_is_8bit?                 4'd1 :
    read_length_word?           4'd2 :
    read_length_dword?          4'd4 :
    rd_operand_16bit?           4'd2 :
                                4'd4;
// (was: read_system_word? 4'd2 : <the chain of read_length_w0>)
assign read_length = (rd_io_allow_2_fault_w)? read_length_w0 : read_length_nf;

always @(posedge clk) begin
    if(rst_n == 1'b0)                                               rd_one_mem_read <= `FALSE;
    else if(rd_ready || rd_reset)                                   rd_one_mem_read <= `FALSE;
    else if(read_done && ~(read_page_fault) && ~(read_ac_fault))    rd_one_mem_read <= `TRUE;
end

assign read_do = 
    ~(rd_reset) &&
    ((rd_address_effective_ready && (read_rmw_virtual || read_virtual)) || memory_read_system_nf) &&   // (SiSTer: _nf, see above)
    ~(rd_one_mem_read) && ~(read_page_fault) && ~(read_ac_fault) &&
    ~(rd_seg_fault_init) && ~(rd_seg_gp_fault) && ~(rd_descriptor_gp_fault) && ~(rd_seg_ss_fault) && ~(rd_io_allow_fault) && ~(rd_ss_esp_from_tss_fault);   // (SiSTer: ~gp_init && ~ss_init is ~rd_seg_fault_init)
        
assign read_for_rd_ready = rd_one_mem_read || (read_done && ~(read_page_fault) && ~(read_ac_fault));

// (SiSTer: the same when rd_reset is low, for read_commands_r0_inst)
wire read_for_rd_ready_r0 = rd_one_mem_read || (read_done_r0 && ~(read_page_fault) && ~(read_ac_fault));
assign rd_waiting_r0 = (read_for_rd_ready_r0)? rd_waiting_r0_f1 : rd_waiting_r0_f0;   // (SiSTer: see read_commands_r0f0_inst)

assign read_4 = read_data[31:0];
assign read_8 = read_data;

//------------------------------------------------------------------------------ write check

always @(posedge clk) begin
    if(rst_n == 1'b0)                                       rd_address_effective_ready_delayed <= `FALSE;
    else if(rd_ready || rd_reset || ~(write_virtual_check)) rd_address_effective_ready_delayed <= `FALSE;
    else                                                    rd_address_effective_ready_delayed <= rd_address_effective_ready;
end

assign write_virtual_check_ready =
    ~(rd_reset) &&
    rd_address_effective_ready_delayed &&
    ~(rd_seg_gp_fault) && ~(rd_descriptor_gp_fault) && ~(rd_seg_ss_fault) && ~(rd_io_allow_fault) && ~(rd_ss_esp_from_tss_fault);

// (SiSTer: for read_commands_r0_inst, whose only output used is rd_waiting: the same with rd_reset low, and
//  without the three faults that need a command under which rd_waiting never reads it. rd_waiting reads
//  write_virtual_check_ready (its cond_29 and cond_215) only in terms for PUSH_MOV_SEG, POP, SMSW,
//  SETcc, MOV, SGDT and SIDT; rd_descriptor_gp_fault needs read_system_descriptor (call/jmp/int/iret/
//  load_seg/LAR/LSL/VERx/task-switch steps), rd_io_allow_fault CMD_io_allow, rd_ss_esp_from_tss_fault
//  CALL_2/int_2 -- so in those terms they are always low. What is left is registers)
wire write_virtual_check_ready_r0 =
        rd_address_effective_ready_delayed &&
    ~(rd_seg_gp_fault) && ~(rd_seg_ss_fault);

//------------------------------------------------------------------------------ misc

assign rd_address_effective_do = ~(rd_address_waiting) && rd_cmd != `CMD_NULL;
    
assign rd_linear = (read_rmw_system_dword)? rd_system_linear : rd_seg_linear;

assign rd_dec_is_front = rd_cmd == `CMD_NULL && ~(rd_mutex_busy_active);

assign rd_is_front     = rd_cmd != `CMD_NULL && ~(rd_mutex_busy_active);

//------------------------------------------------------------------------------ load descriptor

assign rd_descriptor_offset =
    (glob_param_1[2] == 1'b0)?   gdtr_base + { 16'd0, glob_param_1[15:3], 3'd0 } :
                                 ldtr_base + { 16'd0, glob_param_1[15:3], 3'd0 };

assign rd_descriptor_gp_fault = read_system_descriptor && rd_descriptor_not_in_limits;
    
assign rd_descriptor_not_in_limits =
        (glob_param_1[2] == 1'b0 &&  { glob_param_1[15:3], 3'd7 } > gdtr_limit) ||
        (glob_param_1[2] == 1'b1 && ({ 16'd0, glob_param_1[15:3], 3'd7 } > ldtr_limit || ~(ldtr_cache_valid)));

        
//------------------------------------------------------------------------------

read_segment read_segment_inst(
    
    //general input
    .es_cache                   (es_cache),                     //input [63:0]
    .cs_cache                   (cs_cache),                     //input [63:0]
    .ss_cache                   (ss_cache),                     //input [63:0]
    .ds_cache                   (ds_cache),                     //input [63:0]
    .fs_cache                   (fs_cache),                     //input [63:0]
    .gs_cache                   (gs_cache),                     //input [63:0]
    .tr_cache                   (tr_cache),                     //input [63:0]
    .ldtr_cache                 (ldtr_cache),                   //input [63:0]
    
    .es_cache_valid             (es_cache_valid),               //input
    .cs_cache_valid             (cs_cache_valid),               //input
    .ss_cache_valid             (ss_cache_valid),               //input
    .ds_cache_valid             (ds_cache_valid),               //input
    .fs_cache_valid             (fs_cache_valid),               //input
    .gs_cache_valid             (gs_cache_valid),               //input
    
    //address control
    .address_stack_pop          (address_stack_pop),            //input
    .address_stack_pop_next     (address_stack_pop_next),       //input
    .address_enter_last         (address_enter_last),           //input
    .address_enter              (address_enter),                //input
    .address_leave              (address_leave),                //input
    
    .address_edi                (address_edi),                  //input
    
    //read control
    .read_virtual               (read_virtual),                 //input
    .read_rmw_virtual           (read_rmw_virtual),             //input
    .write_virtual_check        (write_virtual_check),          //input
    
    .rd_address_effective       (rd_address_effective),         //input [31:0]
    .rd_address_effective_ready (rd_address_effective_ready),   //input
    .read_length                (read_length_nf),               //input [3:0] (SiSTer: _nf, see read_length_nf)
    
    .rd_prefix_group_2_seg      (rd_prefix_group_2_seg),        //input [2:0]
    
    //output
    .tr_base                    (tr_base),                      //output [31:0]
    .ldtr_base                  (ldtr_base),                    //output [31:0]
    .tr_limit                   (tr_limit),                     //output [31:0]
    .ldtr_limit                 (ldtr_limit),                   //output [31:0]
    
    .rd_seg_gp_fault_init       (rd_seg_gp_fault_init),         //output
    .rd_seg_ss_fault_init       (rd_seg_ss_fault_init),         //output
    .rd_seg_fault_init          (rd_seg_fault_init),            //output (SiSTer)
    
    .rd_seg_linear              (rd_seg_linear)                 //output [31:0]
);

//------------------------------------------------------------------------------

//------------------------------------------------------------------------------

read_effective_address read_effective_address_inst(
    .clk                                (clk),
    .rst_n                              (rst_n),
    
    .rd_reset                           (rd_reset),                             //input

    .rd_address_effective_do            (rd_address_effective_do),              //input
    .rd_ready                           (rd_ready),                             //input
    
    //general input
    .eax                                (eax),                                  //input [31:0]
    .ebx                                (ebx),                                  //input [31:0]
    .ecx                                (ecx),                                  //input [31:0]
    .edx                                (edx),                                  //input [31:0]
    .esp                                (esp),                                  //input [31:0]
    .ebp                                (ebp),                                  //input [31:0]
    .esi                                (esi),                                  //input [31:0]
    .edi                                (edi),                                  //input [31:0]
    
    .ss_cache                           (ss_cache),                             //input [63:0]
    .glob_param_3                       (glob_param_3),                         //input [31:0]
    
    .wr_esp_prev                        (wr_esp_prev),                          //input [31:0]
    
    //rd input
    .rd_address_16bit                   (rd_address_16bit),                     //input
    .rd_address_32bit                   (rd_address_32bit),                     //input
    .rd_operand_16bit                   (rd_operand_16bit),                     //input
    .rd_operand_32bit                   (rd_operand_32bit),                     //input
    .rd_decoder                         (rd_decoder),                           //input [87:0]
    .rd_modregrm_rm                     (rd_modregrm_rm),                       //input [2:0]
    .rd_modregrm_reg                    (rd_modregrm_reg),                      //input [2:0]
    .rd_modregrm_mod                    (rd_modregrm_mod),                      //input [1:0]
    .rd_sib                             (rd_sib),                               //input [7:0]
    
    //address control
    .address_enter_init                 (address_enter_init),                   //input
    .address_enter                      (address_enter),                        //input
    .address_enter_last                 (address_enter_last),                   //input
    .address_leave                      (address_leave),                        //input
    .address_esi                        (address_esi),                          //input
    .address_edi                        (address_edi),                          //input
    .address_xlat_transform             (address_xlat_transform),               //input
    .address_bits_transform             (address_bits_transform),               //input
    
    .address_stack_pop                  (address_stack_pop),                    //input
    .address_stack_pop_speedup          (address_stack_pop_speedup),            //input
    
    .address_stack_pop_next             (address_stack_pop_next),               //input
    .address_stack_pop_esp_prev         (address_stack_pop_esp_prev),           //input
    .address_stack_pop_for_call         (address_stack_pop_for_call),           //input
    .address_stack_save                 (address_stack_save),                   //input
    .address_stack_add_4_to_saved       (address_stack_add_4_to_saved),         //input
    
    .address_stack_for_ret_first        (address_stack_for_ret_first),          //input
    .address_stack_for_ret_second       (address_stack_for_ret_second),         //input
    .address_stack_for_iret_first       (address_stack_for_iret_first),         //input
    .address_stack_for_iret_second      (address_stack_for_iret_second),        //input
    .address_stack_for_iret_third       (address_stack_for_iret_third),         //input
    .address_stack_for_iret_last        (address_stack_for_iret_last),          //input
    .address_stack_for_iret_to_v86      (address_stack_for_iret_to_v86),        //input
    .address_stack_for_call_param_first (address_stack_for_call_param_first),   //input
    
    .address_ea_buffer                  (address_ea_buffer),                    //input
    .address_ea_buffer_plus_2           (address_ea_buffer_plus_2),             //input
    
    .address_memoffset                  (address_memoffset),                    //input
    
    //output
    .rd_address_effective_ready         (rd_address_effective_ready),           //output
    .rd_address_effective               (rd_address_effective)                  //output [31:0]
);
 
//------------------------------------------------------------------------------

read_debug read_debug_inst(
    .clk            (clk),
    .rst_n          (rst_n),
    
    .dr0            (dr0),          //input [31:0]
    .dr1            (dr1),          //input [31:0]
    .dr2            (dr2),          //input [31:0]
    .dr3            (dr3),          //input [31:0]
    .dr7            (dr7),          //input [31:0]
    
    .debug_len0     (debug_len0),   //input [2:0]
    .debug_len1     (debug_len1),   //input [2:0]
    .debug_len2     (debug_len2),   //input [2:0]
    .debug_len3     (debug_len3),   //input [2:0]
    
    .rd_ready       (rd_ready),     // input
    
    .read_do        (read_do),      //input
    .read_address   (read_address), //input [31:0]
    .read_length    (read_length),  //input [3:0]
    
    .rd_debug_read  (rd_debug_read) //output [3:0]
);

//------------------------------------------------------------------------------

read_commands read_commands_inst(
    .clk                                (clk),
    .rst_n                              (rst_n),
    
    //general input
    .glob_descriptor                    (glob_descriptor),                      //input [63:0]
    .glob_param_1                       (glob_param_1),                         //input [31:0]
    .glob_param_2                       (glob_param_2),                         //input [31:0]
    .glob_param_3                       (glob_param_3),                         //input [31:0]
    
    .glob_desc_base                     (glob_desc_base),                       //input [31:0]
    .glob_desc_limit                    (glob_desc_limit),                      //input [31:0]
    
    .tr                                 (tr),                                   //input [15:0]
    .tr_base                            (tr_base),                              //input [31:0]
    .tr_cache                           (tr_cache),                             //input [63:0]
    .tr_cache_valid                     (tr_cache_valid),                       //input
    .tr_limit                           (tr_limit),                             //input [31:0]
    
    .gdtr_base                          (gdtr_base),                            //input [31:0]
    .idtr_base                          (idtr_base),                            //input [31:0]
        
    .ecx                                (ecx),                                  //input [31:0]
    .ecx_lo_is_0                        (ecx_lo_is_0),                          //input (SiSTer)
    .ecx_hi_is_0                        (ecx_hi_is_0),                          //input (SiSTer)
    .edx                                (edx),                                  //input [31:0]
        
    .iopl                               (iopl),                                 //input [1:0]
    
    .exc_vector                         (exc_vector),                           //input [7:0]
    
    .io_allow_check_needed              (io_allow_check_needed),                //input
    
    .cpl                                (cpl),                                  //input [1:0]
    .cr0_pg                             (cr0_pg),                               //input
    
    .real_mode                          (real_mode),                            //input
    .v8086_mode                         (v8086_mode),                           //input
    .protected_mode                     (protected_mode),                       //input
    
    .exe_mutex                          (exe_mutex),                            //input [10:0]
    
    //rd input
    .rd_decoder                         (rd_decoder),                           //input [87:0]
    .rd_cmd                             (rd_cmd),                               //input [6:0]
    .rd_cmdex                           (rd_cmdex),                             //input [3:0]
    .rd_modregrm_mod                    (rd_modregrm_mod),                      //input [1:0]
    .rd_operand_16bit                   (rd_operand_16bit),                     //input
    .rd_operand_32bit                   (rd_operand_32bit),                     //input
    .rd_memory_last                     (rd_memory_last),                       //input [31:0]
    .rd_prefix_group_1_rep              (rd_prefix_group_1_rep),                //input [1:0]
    .rd_address_16bit                   (rd_address_16bit),                     //input
    .rd_address_32bit                   (rd_address_32bit),                     //input
    .rd_ready                           (rd_ready),                             //input
                                 
    .dst_wire                           (dst_wire),                             //input [31:0]
    
    .rd_descriptor_not_in_limits        (rd_descriptor_not_in_limits),          //input
    .rd_consumed                        (rd_consumed),                          //input [3:0]

    //rd mutex busy
    .rd_mutex_busy_active               (rd_mutex_busy_active),                 //input
    .rd_mutex_busy_memory               (rd_mutex_busy_memory),                 //input
    .rd_mutex_busy_eflags               (rd_mutex_busy_eflags),                 //input
    .rd_mutex_busy_ebp                  (rd_mutex_busy_ebp),                    //input
    .rd_mutex_busy_esp                  (rd_mutex_busy_esp),                    //input
    .rd_mutex_busy_edx                  (rd_mutex_busy_edx),                    //input
    .rd_mutex_busy_ecx                  (rd_mutex_busy_ecx),                    //input
    .rd_mutex_busy_eax                  (rd_mutex_busy_eax),                    //input
    .rd_mutex_busy_modregrm_reg         (rd_mutex_busy_modregrm_reg),           //input
    .rd_mutex_busy_modregrm_rm          (rd_mutex_busy_modregrm_rm),            //input
    .rd_mutex_busy_implicit_reg         (rd_mutex_busy_implicit_reg),           //input
    
    //rd output
    .rd_extra_wire                      (rd_extra_wire),                        //output [31:0]
    .rd_system_linear                   (rd_system_linear),                     //output [31:0]
    
    .rd_error_code                      (rd_error_code),                        //output [15:0]
                                 
    .rd_ss_esp_from_tss_fault           (rd_ss_esp_from_tss_fault),             //output
    
    .rd_waiting                         (rd_waiting),                           //output
    
    //mutex req
    .rd_req_memory                      (rd_req_memory),                        //output
    .rd_req_eflags                      (rd_req_eflags),                        //output
    .rd_req_all                         (rd_req_all),                           //output
    .rd_req_reg                         (rd_req_reg),                           //output
    .rd_req_rm                          (rd_req_rm),                            //output
    .rd_req_implicit_reg                (rd_req_implicit_reg),                  //output
    .rd_req_reg_not_8bit                (rd_req_reg_not_8bit),                  //output
    .rd_req_edi                         (rd_req_edi),                           //output
    .rd_req_esi                         (rd_req_esi),                           //output
    .rd_req_ebp                         (rd_req_ebp),                           //output
    .rd_req_esp                         (rd_req_esp),                           //output
    .rd_req_ebx                         (rd_req_ebx),                           //output
    .rd_req_edx_eax                     (rd_req_edx_eax),                       //output
    .rd_req_edx                         (rd_req_edx),                           //output
    .rd_req_ecx                         (rd_req_ecx),                           //output
    .rd_req_eax                         (rd_req_eax),                           //output
    
    //address control
    .address_enter_init                 (address_enter_init),                   //output
    .address_enter                      (address_enter),                        //output
    .address_enter_last                 (address_enter_last),                   //output
    .address_leave                      (address_leave),                        //output
    .address_esi                        (address_esi),                          //output
    .address_edi                        (address_edi),                          //output
    .address_xlat_transform             (address_xlat_transform),               //output
    .address_bits_transform             (address_bits_transform),               //output
    
    .address_stack_pop                  (address_stack_pop),                    //output
    .address_stack_pop_speedup          (address_stack_pop_speedup),            //output
    
    .address_stack_pop_next             (address_stack_pop_next),               //output
    .address_stack_pop_esp_prev         (address_stack_pop_esp_prev),           //output
    .address_stack_pop_for_call         (address_stack_pop_for_call),           //output
    .address_stack_save                 (address_stack_save),                   //output
    .address_stack_add_4_to_saved       (address_stack_add_4_to_saved),         //output
    
    .address_stack_for_ret_first        (address_stack_for_ret_first),          //output
    .address_stack_for_ret_second       (address_stack_for_ret_second),         //output
    .address_stack_for_iret_first       (address_stack_for_iret_first),         //output
    .address_stack_for_iret_second      (address_stack_for_iret_second),        //output
    .address_stack_for_iret_third       (address_stack_for_iret_third),         //output
    .address_stack_for_iret_last        (address_stack_for_iret_last),          //output
    .address_stack_for_iret_to_v86      (address_stack_for_iret_to_v86),        //output
    .address_stack_for_call_param_first (address_stack_for_call_param_first),   //output
    
    .address_ea_buffer                  (address_ea_buffer),                    //output
    .address_ea_buffer_plus_2           (address_ea_buffer_plus_2),             //output
    
    .address_memoffset                  (address_memoffset),                    //output
   
    //read control
    .read_virtual                       (read_virtual),                         //output
    .read_rmw_virtual                   (read_rmw_virtual),                     //output
    .write_virtual_check                (write_virtual_check),                  //output
    
    .read_system_descriptor             (read_system_descriptor),               //output
    .read_system_word                   (read_system_word_nf),                  //output (SiSTer: with io_allow_2_fault_off)
    .read_system_dword                  (read_system_dword),                    //output
    .read_system_qword                  (read_system_qword),                    //output
    .read_rmw_system_dword              (read_rmw_system_dword),                //output
    
    .read_length_word                   (read_length_word),                     //output
    .read_length_dword                  (read_length_dword),                    //output
    
    .read_for_rd_ready                  (read_for_rd_ready),                    //input
    .write_virtual_check_ready          (write_virtual_check_ready),            //input
    
    .rd_address_effective_ready         (rd_address_effective_ready),           //input
    
    .read_4                             (read_4),                               //input [31:0]
    .read_8                             (read_8),                               //input [63:0]

    //read signals
    .rd_src_is_memory                   (rd_src_is_memory_nf),                  //output (SiSTer: with io_allow_2_fault_off)
    .rd_src_is_io                       (rd_src_is_io),                         //output
    .rd_src_is_modregrm_imm             (rd_src_is_modregrm_imm),               //output
    .rd_src_is_modregrm_imm_se          (rd_src_is_modregrm_imm_se),            //output
    .rd_src_is_imm                      (rd_src_is_imm),                        //output
    .rd_src_is_imm_se                   (rd_src_is_imm_se),                     //output
    .rd_src_is_1                        (rd_src_is_1),                          //output
    .rd_src_is_eax                      (rd_src_is_eax),                        //output
    .rd_src_is_ecx                      (rd_src_is_ecx),                        //output
    .rd_src_is_cmdex                    (rd_src_is_cmdex),                      //output
    .rd_src_is_implicit_reg             (rd_src_is_implicit_reg),               //output
    .rd_src_is_rm                       (rd_src_is_rm),                         //output
    .rd_src_is_reg                      (rd_src_is_reg),                        //output

    .rd_dst_is_0                        (rd_dst_is_0),                          //output
    .rd_dst_is_modregrm_imm_se          (rd_dst_is_modregrm_imm_se),            //output
    .rd_dst_is_modregrm_imm             (rd_dst_is_modregrm_imm),               //output
    .rd_dst_is_memory                   (rd_dst_is_memory),                     //output
    .rd_dst_is_memory_last              (rd_dst_is_memory_last),                //output
    .rd_dst_is_eip                      (rd_dst_is_eip),                        //output
    .rd_dst_is_eax                      (rd_dst_is_eax),                        //output
    .rd_dst_is_edx_eax                  (rd_dst_is_edx_eax),                    //output
    .rd_dst_is_implicit_reg             (rd_dst_is_implicit_reg),               //output
    .rd_dst_is_rm                       (rd_dst_is_rm),                         //output
    .rd_dst_is_reg                      (rd_dst_is_reg),                        //output
    
    //global set
    .rd_glob_descriptor_set             (rd_glob_descriptor_set),               //output
    .rd_glob_descriptor_value           (rd_glob_descriptor_value),             //output [63:0]
    
    .rd_glob_descriptor_2_set           (rd_glob_descriptor_2_set),             //output
    .rd_glob_descriptor_2_value         (rd_glob_descriptor_2_value),           //output [63:0]
    
    .rd_glob_param_1_set                (rd_glob_param_1_set),                  //output
    .rd_glob_param_1_value              (rd_glob_param_1_value),                //output [31:0]
    
    .rd_glob_param_2_set                (rd_glob_param_2_set),                  //output
    .rd_glob_param_2_value              (rd_glob_param_2_value),                //output [31:0]
    
    .rd_glob_param_3_set                (rd_glob_param_3_set),                  //output
    .rd_glob_param_3_value              (rd_glob_param_3_value),                //output [31:0]
    
    .rd_glob_param_4_set                (rd_glob_param_4_set),                  //output
    .rd_glob_param_4_value              (rd_glob_param_4_value),                //output [31:0]
    
    .rd_glob_param_5_set                (rd_glob_param_5_set),                  //output
    .rd_glob_param_5_value              (rd_glob_param_5_value),                //output [31:0]
    
    //io
    .io_read                            (io_read),                              //output
    .io_read_address                    (io_read_address),                      //output [15:0]
    .rd_io_ready                        (rd_io_ready),                          //input
    
    .rd_io_allow_fault                  (rd_io_allow_fault_nf),                 //output (SiSTer: with io_allow_2_fault_off)
    .io_allow_2_fault_off               (1'b1),                                 //input (SiSTer)
    .rd_io_allow_2_fault_out            (rd_io_allow_2_fault_w)                 //output (SiSTer)
);

// (SiSTer: read_commands once more, with read_for_rd_ready and write_virtual_check_ready as they are
//  when rd_reset is low (their only rd_reset terms); only its rd_waiting is used, as rd_waiting_r0)
// (SiSTer: and that copy twice, with read_for_rd_ready fixed low and high: the memory read's completion, late
//  from the TLB and the bus, then picks between the two rd_waiting values last -- rd_waiting_r0 below)
read_commands read_commands_r0f0_inst(
    .clk                                (clk),
    .rst_n                              (rst_n),
    
    //general input
    .glob_descriptor                    (glob_descriptor),                      //input [63:0]
    .glob_param_1                       (glob_param_1),                         //input [31:0]
    .glob_param_2                       (glob_param_2),                         //input [31:0]
    .glob_param_3                       (glob_param_3),                         //input [31:0]
    
    .glob_desc_base                     (glob_desc_base),                       //input [31:0]
    .glob_desc_limit                    (glob_desc_limit),                      //input [31:0]
    
    .tr                                 (tr),                                   //input [15:0]
    .tr_base                            (tr_base),                              //input [31:0]
    .tr_cache                           (tr_cache),                             //input [63:0]
    .tr_cache_valid                     (tr_cache_valid),                       //input
    .tr_limit                           (tr_limit),                             //input [31:0]
    
    .gdtr_base                          (gdtr_base),                            //input [31:0]
    .idtr_base                          (idtr_base),                            //input [31:0]
        
    .ecx                                (ecx),                                  //input [31:0]
    .ecx_lo_is_0                        (ecx_lo_is_0),                          //input (SiSTer)
    .ecx_hi_is_0                        (ecx_hi_is_0),                          //input (SiSTer)
    .edx                                (edx),                                  //input [31:0]
        
    .iopl                               (iopl),                                 //input [1:0]
    
    .exc_vector                         (exc_vector),                           //input [7:0]
    
    .io_allow_check_needed              (io_allow_check_needed),                //input
    
    .cpl                                (cpl),                                  //input [1:0]
    .cr0_pg                             (cr0_pg),                               //input
    
    .real_mode                          (real_mode),                            //input
    .v8086_mode                         (v8086_mode),                           //input
    .protected_mode                     (protected_mode),                       //input
    
    .exe_mutex                          (exe_mutex),                            //input [10:0]
    
    //rd input
    .rd_decoder                         (rd_decoder),                           //input [87:0]
    .rd_cmd                             (rd_cmd),                               //input [6:0]
    .rd_cmdex                           (rd_cmdex),                             //input [3:0]
    .rd_modregrm_mod                    (rd_modregrm_mod),                      //input [1:0]
    .rd_operand_16bit                   (rd_operand_16bit),                     //input
    .rd_operand_32bit                   (rd_operand_32bit),                     //input
    .rd_memory_last                     (rd_memory_last),                       //input [31:0]
    .rd_prefix_group_1_rep              (rd_prefix_group_1_rep),                //input [1:0]
    .rd_address_16bit                   (rd_address_16bit),                     //input
    .rd_address_32bit                   (rd_address_32bit),                     //input
    .rd_ready                           (rd_ready),                             //input
                                 
    .dst_wire                           (dst_wire),                             //input [31:0]
    
    .rd_descriptor_not_in_limits        (rd_descriptor_not_in_limits),          //input
    .rd_consumed                        (rd_consumed),                          //input [3:0]

    //rd mutex busy
    .rd_mutex_busy_active               (rd_mutex_busy_active),                 //input
    .rd_mutex_busy_memory               (rd_mutex_busy_memory),                 //input
    .rd_mutex_busy_eflags               (rd_mutex_busy_eflags),                 //input
    .rd_mutex_busy_ebp                  (rd_mutex_busy_ebp),                    //input
    .rd_mutex_busy_esp                  (rd_mutex_busy_esp),                    //input
    .rd_mutex_busy_edx                  (rd_mutex_busy_edx),                    //input
    .rd_mutex_busy_ecx                  (rd_mutex_busy_ecx),                    //input
    .rd_mutex_busy_eax                  (rd_mutex_busy_eax),                    //input
    .rd_mutex_busy_modregrm_reg         (rd_mutex_busy_modregrm_reg),           //input
    .rd_mutex_busy_modregrm_rm          (rd_mutex_busy_modregrm_rm),            //input
    .rd_mutex_busy_implicit_reg         (rd_mutex_busy_implicit_reg),           //input
    
    //rd output
    .rd_extra_wire                      (),                        //output (unused)
    .rd_system_linear                   (),                     //output (unused)
    
    .rd_error_code                      (),                        //output (unused)
                                 
    .rd_ss_esp_from_tss_fault           (),             //output (unused)
    
    .rd_waiting                         (rd_waiting_r0_f0),                           //output (SiSTer)
    
    //mutex req
    .rd_req_memory                      (),                        //output (unused)
    .rd_req_eflags                      (),                        //output (unused)
    .rd_req_all                         (),                           //output (unused)
    .rd_req_reg                         (),                           //output (unused)
    .rd_req_rm                          (),                            //output (unused)
    .rd_req_implicit_reg                (),                  //output (unused)
    .rd_req_reg_not_8bit                (),                  //output (unused)
    .rd_req_edi                         (),                           //output (unused)
    .rd_req_esi                         (),                           //output (unused)
    .rd_req_ebp                         (),                           //output (unused)
    .rd_req_esp                         (),                           //output (unused)
    .rd_req_ebx                         (),                           //output (unused)
    .rd_req_edx_eax                     (),                       //output (unused)
    .rd_req_edx                         (),                           //output (unused)
    .rd_req_ecx                         (),                           //output (unused)
    .rd_req_eax                         (),                           //output (unused)
    
    //address control
    .address_enter_init                 (),                   //output (unused)
    .address_enter                      (),                        //output (unused)
    .address_enter_last                 (),                   //output (unused)
    .address_leave                      (),                        //output (unused)
    .address_esi                        (),                          //output (unused)
    .address_edi                        (),                          //output (unused)
    .address_xlat_transform             (),               //output (unused)
    .address_bits_transform             (),               //output (unused)
    
    .address_stack_pop                  (),                    //output (unused)
    .address_stack_pop_speedup          (),            //output (unused)
    
    .address_stack_pop_next             (),               //output (unused)
    .address_stack_pop_esp_prev         (),           //output (unused)
    .address_stack_pop_for_call         (),           //output (unused)
    .address_stack_save                 (),                   //output (unused)
    .address_stack_add_4_to_saved       (),         //output (unused)
    
    .address_stack_for_ret_first        (),          //output (unused)
    .address_stack_for_ret_second       (),         //output (unused)
    .address_stack_for_iret_first       (),         //output (unused)
    .address_stack_for_iret_second      (),        //output (unused)
    .address_stack_for_iret_third       (),         //output (unused)
    .address_stack_for_iret_last        (),          //output (unused)
    .address_stack_for_iret_to_v86      (),        //output (unused)
    .address_stack_for_call_param_first (),   //output (unused)
    
    .address_ea_buffer                  (),                    //output (unused)
    .address_ea_buffer_plus_2           (),             //output (unused)
    
    .address_memoffset                  (),                    //output (unused)
   
    //read control
    .read_virtual                       (),                         //output (unused)
    .read_rmw_virtual                   (),                     //output (unused)
    .write_virtual_check                (),                  //output (unused)
    
    .read_system_descriptor             (),               //output (unused)
    .read_system_word                   (),                     //output (unused)
    .read_system_dword                  (),                    //output (unused)
    .read_system_qword                  (),                    //output (unused)
    .read_rmw_system_dword              (),                //output (unused)
    
    .read_length_word                   (),                     //output (unused)
    .read_length_dword                  (),                    //output (unused)
    
    .read_for_rd_ready                  (1'b0)          ,                    //input (SiSTer)
    .write_virtual_check_ready          (write_virtual_check_ready_r0),            //input (SiSTer)
    
    .rd_address_effective_ready         (rd_address_effective_ready),           //input
    
    .read_4                             (read_4),                               //input [31:0]
    .read_8                             (read_8),                               //input [63:0]

    //read signals
    .rd_src_is_memory                   (),                     //output (unused)
    .rd_src_is_io                       (),                         //output (unused)
    .rd_src_is_modregrm_imm             (),               //output (unused)
    .rd_src_is_modregrm_imm_se          (),            //output (unused)
    .rd_src_is_imm                      (),                        //output (unused)
    .rd_src_is_imm_se                   (),                     //output (unused)
    .rd_src_is_1                        (),                          //output (unused)
    .rd_src_is_eax                      (),                        //output (unused)
    .rd_src_is_ecx                      (),                        //output (unused)
    .rd_src_is_cmdex                    (),                      //output (unused)
    .rd_src_is_implicit_reg             (),               //output (unused)
    .rd_src_is_rm                       (),                         //output (unused)
    .rd_src_is_reg                      (),                        //output (unused)

    .rd_dst_is_0                        (),                          //output (unused)
    .rd_dst_is_modregrm_imm_se          (),            //output (unused)
    .rd_dst_is_modregrm_imm             (),               //output (unused)
    .rd_dst_is_memory                   (),                     //output (unused)
    .rd_dst_is_memory_last              (),                //output (unused)
    .rd_dst_is_eip                      (),                        //output (unused)
    .rd_dst_is_eax                      (),                        //output (unused)
    .rd_dst_is_edx_eax                  (),                    //output (unused)
    .rd_dst_is_implicit_reg             (),               //output (unused)
    .rd_dst_is_rm                       (),                         //output (unused)
    .rd_dst_is_reg                      (),                        //output (unused)
    
    //global set
    .rd_glob_descriptor_set             (),               //output (unused)
    .rd_glob_descriptor_value           (),             //output (unused)
    
    .rd_glob_descriptor_2_set           (),             //output (unused)
    .rd_glob_descriptor_2_value         (),           //output (unused)
    
    .rd_glob_param_1_set                (),                  //output (unused)
    .rd_glob_param_1_value              (),                //output (unused)
    
    .rd_glob_param_2_set                (),                  //output (unused)
    .rd_glob_param_2_value              (),                //output (unused)
    
    .rd_glob_param_3_set                (),                  //output (unused)
    .rd_glob_param_3_value              (),                //output (unused)
    
    .rd_glob_param_4_set                (),                  //output (unused)
    .rd_glob_param_4_value              (),                //output (unused)
    
    .rd_glob_param_5_set                (),                  //output (unused)
    .rd_glob_param_5_value              (),                //output (unused)
    
    //io
    .io_read                            (),                              //output (unused)
    .io_read_address                    (),                      //output (unused)
    .rd_io_ready                        (rd_io_ready),                          //input
    
    .rd_io_allow_fault                  (),                    //output (unused)
    .io_allow_2_fault_off               (1'b1),                //input (SiSTer)
    .rd_io_allow_2_fault_out            ()                     //output (unused)
);

read_commands read_commands_r0f1_inst(
    .clk                                (clk),
    .rst_n                              (rst_n),
    
    //general input
    .glob_descriptor                    (glob_descriptor),                      //input [63:0]
    .glob_param_1                       (glob_param_1),                         //input [31:0]
    .glob_param_2                       (glob_param_2),                         //input [31:0]
    .glob_param_3                       (glob_param_3),                         //input [31:0]
    
    .glob_desc_base                     (glob_desc_base),                       //input [31:0]
    .glob_desc_limit                    (glob_desc_limit),                      //input [31:0]
    
    .tr                                 (tr),                                   //input [15:0]
    .tr_base                            (tr_base),                              //input [31:0]
    .tr_cache                           (tr_cache),                             //input [63:0]
    .tr_cache_valid                     (tr_cache_valid),                       //input
    .tr_limit                           (tr_limit),                             //input [31:0]
    
    .gdtr_base                          (gdtr_base),                            //input [31:0]
    .idtr_base                          (idtr_base),                            //input [31:0]
        
    .ecx                                (ecx),                                  //input [31:0]
    .ecx_lo_is_0                        (ecx_lo_is_0),                          //input (SiSTer)
    .ecx_hi_is_0                        (ecx_hi_is_0),                          //input (SiSTer)
    .edx                                (edx),                                  //input [31:0]
        
    .iopl                               (iopl),                                 //input [1:0]
    
    .exc_vector                         (exc_vector),                           //input [7:0]
    
    .io_allow_check_needed              (io_allow_check_needed),                //input
    
    .cpl                                (cpl),                                  //input [1:0]
    .cr0_pg                             (cr0_pg),                               //input
    
    .real_mode                          (real_mode),                            //input
    .v8086_mode                         (v8086_mode),                           //input
    .protected_mode                     (protected_mode),                       //input
    
    .exe_mutex                          (exe_mutex),                            //input [10:0]
    
    //rd input
    .rd_decoder                         (rd_decoder),                           //input [87:0]
    .rd_cmd                             (rd_cmd),                               //input [6:0]
    .rd_cmdex                           (rd_cmdex),                             //input [3:0]
    .rd_modregrm_mod                    (rd_modregrm_mod),                      //input [1:0]
    .rd_operand_16bit                   (rd_operand_16bit),                     //input
    .rd_operand_32bit                   (rd_operand_32bit),                     //input
    .rd_memory_last                     (rd_memory_last),                       //input [31:0]
    .rd_prefix_group_1_rep              (rd_prefix_group_1_rep),                //input [1:0]
    .rd_address_16bit                   (rd_address_16bit),                     //input
    .rd_address_32bit                   (rd_address_32bit),                     //input
    .rd_ready                           (rd_ready),                             //input
                                 
    .dst_wire                           (dst_wire),                             //input [31:0]
    
    .rd_descriptor_not_in_limits        (rd_descriptor_not_in_limits),          //input
    .rd_consumed                        (rd_consumed),                          //input [3:0]

    //rd mutex busy
    .rd_mutex_busy_active               (rd_mutex_busy_active),                 //input
    .rd_mutex_busy_memory               (rd_mutex_busy_memory),                 //input
    .rd_mutex_busy_eflags               (rd_mutex_busy_eflags),                 //input
    .rd_mutex_busy_ebp                  (rd_mutex_busy_ebp),                    //input
    .rd_mutex_busy_esp                  (rd_mutex_busy_esp),                    //input
    .rd_mutex_busy_edx                  (rd_mutex_busy_edx),                    //input
    .rd_mutex_busy_ecx                  (rd_mutex_busy_ecx),                    //input
    .rd_mutex_busy_eax                  (rd_mutex_busy_eax),                    //input
    .rd_mutex_busy_modregrm_reg         (rd_mutex_busy_modregrm_reg),           //input
    .rd_mutex_busy_modregrm_rm          (rd_mutex_busy_modregrm_rm),            //input
    .rd_mutex_busy_implicit_reg         (rd_mutex_busy_implicit_reg),           //input
    
    //rd output
    .rd_extra_wire                      (),                        //output (unused)
    .rd_system_linear                   (),                     //output (unused)
    
    .rd_error_code                      (),                        //output (unused)
                                 
    .rd_ss_esp_from_tss_fault           (),             //output (unused)
    
    .rd_waiting                         (rd_waiting_r0_f1),                           //output (SiSTer)
    
    //mutex req
    .rd_req_memory                      (),                        //output (unused)
    .rd_req_eflags                      (),                        //output (unused)
    .rd_req_all                         (),                           //output (unused)
    .rd_req_reg                         (),                           //output (unused)
    .rd_req_rm                          (),                            //output (unused)
    .rd_req_implicit_reg                (),                  //output (unused)
    .rd_req_reg_not_8bit                (),                  //output (unused)
    .rd_req_edi                         (),                           //output (unused)
    .rd_req_esi                         (),                           //output (unused)
    .rd_req_ebp                         (),                           //output (unused)
    .rd_req_esp                         (),                           //output (unused)
    .rd_req_ebx                         (),                           //output (unused)
    .rd_req_edx_eax                     (),                       //output (unused)
    .rd_req_edx                         (),                           //output (unused)
    .rd_req_ecx                         (),                           //output (unused)
    .rd_req_eax                         (),                           //output (unused)
    
    //address control
    .address_enter_init                 (),                   //output (unused)
    .address_enter                      (),                        //output (unused)
    .address_enter_last                 (),                   //output (unused)
    .address_leave                      (),                        //output (unused)
    .address_esi                        (),                          //output (unused)
    .address_edi                        (),                          //output (unused)
    .address_xlat_transform             (),               //output (unused)
    .address_bits_transform             (),               //output (unused)
    
    .address_stack_pop                  (),                    //output (unused)
    .address_stack_pop_speedup          (),            //output (unused)
    
    .address_stack_pop_next             (),               //output (unused)
    .address_stack_pop_esp_prev         (),           //output (unused)
    .address_stack_pop_for_call         (),           //output (unused)
    .address_stack_save                 (),                   //output (unused)
    .address_stack_add_4_to_saved       (),         //output (unused)
    
    .address_stack_for_ret_first        (),          //output (unused)
    .address_stack_for_ret_second       (),         //output (unused)
    .address_stack_for_iret_first       (),         //output (unused)
    .address_stack_for_iret_second      (),        //output (unused)
    .address_stack_for_iret_third       (),         //output (unused)
    .address_stack_for_iret_last        (),          //output (unused)
    .address_stack_for_iret_to_v86      (),        //output (unused)
    .address_stack_for_call_param_first (),   //output (unused)
    
    .address_ea_buffer                  (),                    //output (unused)
    .address_ea_buffer_plus_2           (),             //output (unused)
    
    .address_memoffset                  (),                    //output (unused)
   
    //read control
    .read_virtual                       (),                         //output (unused)
    .read_rmw_virtual                   (),                     //output (unused)
    .write_virtual_check                (),                  //output (unused)
    
    .read_system_descriptor             (),               //output (unused)
    .read_system_word                   (),                     //output (unused)
    .read_system_dword                  (),                    //output (unused)
    .read_system_qword                  (),                    //output (unused)
    .read_rmw_system_dword              (),                //output (unused)
    
    .read_length_word                   (),                     //output (unused)
    .read_length_dword                  (),                    //output (unused)
    
    .read_for_rd_ready                  (1'b1)          ,                    //input (SiSTer)
    .write_virtual_check_ready          (write_virtual_check_ready_r0),            //input (SiSTer)
    
    .rd_address_effective_ready         (rd_address_effective_ready),           //input
    
    .read_4                             (read_4),                               //input [31:0]
    .read_8                             (read_8),                               //input [63:0]

    //read signals
    .rd_src_is_memory                   (),                     //output (unused)
    .rd_src_is_io                       (),                         //output (unused)
    .rd_src_is_modregrm_imm             (),               //output (unused)
    .rd_src_is_modregrm_imm_se          (),            //output (unused)
    .rd_src_is_imm                      (),                        //output (unused)
    .rd_src_is_imm_se                   (),                     //output (unused)
    .rd_src_is_1                        (),                          //output (unused)
    .rd_src_is_eax                      (),                        //output (unused)
    .rd_src_is_ecx                      (),                        //output (unused)
    .rd_src_is_cmdex                    (),                      //output (unused)
    .rd_src_is_implicit_reg             (),               //output (unused)
    .rd_src_is_rm                       (),                         //output (unused)
    .rd_src_is_reg                      (),                        //output (unused)

    .rd_dst_is_0                        (),                          //output (unused)
    .rd_dst_is_modregrm_imm_se          (),            //output (unused)
    .rd_dst_is_modregrm_imm             (),               //output (unused)
    .rd_dst_is_memory                   (),                     //output (unused)
    .rd_dst_is_memory_last              (),                //output (unused)
    .rd_dst_is_eip                      (),                        //output (unused)
    .rd_dst_is_eax                      (),                        //output (unused)
    .rd_dst_is_edx_eax                  (),                    //output (unused)
    .rd_dst_is_implicit_reg             (),               //output (unused)
    .rd_dst_is_rm                       (),                         //output (unused)
    .rd_dst_is_reg                      (),                        //output (unused)
    
    //global set
    .rd_glob_descriptor_set             (),               //output (unused)
    .rd_glob_descriptor_value           (),             //output (unused)
    
    .rd_glob_descriptor_2_set           (),             //output (unused)
    .rd_glob_descriptor_2_value         (),           //output (unused)
    
    .rd_glob_param_1_set                (),                  //output (unused)
    .rd_glob_param_1_value              (),                //output (unused)
    
    .rd_glob_param_2_set                (),                  //output (unused)
    .rd_glob_param_2_value              (),                //output (unused)
    
    .rd_glob_param_3_set                (),                  //output (unused)
    .rd_glob_param_3_value              (),                //output (unused)
    
    .rd_glob_param_4_set                (),                  //output (unused)
    .rd_glob_param_4_value              (),                //output (unused)
    
    .rd_glob_param_5_set                (),                  //output (unused)
    .rd_glob_param_5_value              (),                //output (unused)
    
    //io
    .io_read                            (),                              //output (unused)
    .io_read_address                    (),                      //output (unused)
    .rd_io_ready                        (rd_io_ready),                          //input
    
    .rd_io_allow_fault                  (),                    //output (unused)
    .io_allow_2_fault_off               (1'b1),                //input (SiSTer)
    .rd_io_allow_2_fault_out            ()                     //output (unused)
);

//------------------------------------------------------------------------------

read_mutex read_mutex_inst(
    .rd_req_memory                  (rd_req_memory),                //input
    .rd_req_eflags                  (rd_req_eflags),                //input
    
    .rd_req_all                     (rd_req_all),                   //input
    .rd_req_reg                     (rd_req_reg),                   //input
    .rd_req_rm                      (rd_req_rm),                    //input
    .rd_req_implicit_reg            (rd_req_implicit_reg),          //input
    .rd_req_reg_not_8bit            (rd_req_reg_not_8bit),          //input
    .rd_req_edi                     (rd_req_edi),                   //input
    .rd_req_esi                     (rd_req_esi),                   //input
    .rd_req_ebp                     (rd_req_ebp),                   //input
    .rd_req_esp                     (rd_req_esp),                   //input
    .rd_req_ebx                     (rd_req_ebx),                   //input
    .rd_req_edx_eax                 (rd_req_edx_eax),               //input
    .rd_req_edx                     (rd_req_edx),                   //input
    .rd_req_ecx                     (rd_req_ecx),                   //input
    .rd_req_eax                     (rd_req_eax),                   //input
    
    .rd_decoder                     (rd_decoder),                   //input [87:0]
    .rd_is_8bit                     (rd_is_8bit),                   //input
    .rd_modregrm_mod                (rd_modregrm_mod),              //input [1:0]
    .rd_modregrm_reg                (rd_modregrm_reg),              //input [2:0]
    .rd_modregrm_rm                 (rd_modregrm_rm),               //input [2:0]
    .rd_address_16bit               (rd_address_16bit),             //input
    .rd_address_32bit               (rd_address_32bit),             //input
    .rd_sib                         (rd_sib),                       //input [7:0]
    
    .exe_mutex                      (exe_mutex),                    //input [10:0]
    .wr_mutex                       (wr_mutex),                     //input [10:0]
    
    .address_bits_transform         (address_bits_transform),       //input
    .address_xlat_transform         (address_xlat_transform),       //input
    .address_stack_pop              (address_stack_pop),            //input
    .address_stack_pop_next         (address_stack_pop_next),       //input
    .address_enter                  (address_enter),                //input
    .address_enter_last             (address_enter_last),           //input
    .address_leave                  (address_leave),                //input
    .address_esi                    (address_esi),                  //input
    .address_edi                    (address_edi),                  //input
    
    
    .rd_mutex_next                  (rd_mutex_next),                //output [10:0]
    
    .rd_mutex_busy_active           (rd_mutex_busy_active),         //output
    .rd_mutex_busy_memory           (rd_mutex_busy_memory),         //output
    .rd_mutex_busy_eflags           (rd_mutex_busy_eflags),         //output
    .rd_mutex_busy_ebp              (rd_mutex_busy_ebp),            //output
    .rd_mutex_busy_esp              (rd_mutex_busy_esp),            //output
    .rd_mutex_busy_edx              (rd_mutex_busy_edx),            //output
    .rd_mutex_busy_ecx              (rd_mutex_busy_ecx),            //output
    .rd_mutex_busy_eax              (rd_mutex_busy_eax),            //output
    .rd_mutex_busy_modregrm_reg     (rd_mutex_busy_modregrm_reg),   //output
    .rd_mutex_busy_modregrm_rm      (rd_mutex_busy_modregrm_rm),    //output
    .rd_mutex_busy_implicit_reg     (rd_mutex_busy_implicit_reg),   //output

    .rd_address_waiting             (rd_address_waiting)            //output
);

//------------------------------------------------------------------------------

endmodule
