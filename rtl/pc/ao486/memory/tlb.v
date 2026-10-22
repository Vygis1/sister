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

//PARSED_COMMENTS: this file contains parsed script comments

module tlb(
    input               clk,
    input               rst_n,

    input               pr_reset,
    input               rd_reset,
    input               exe_reset,
    input               wr_reset,
    
    // from control
    input               cr0_pg,
    input               cr0_wp,
    input               cr0_am,
    input               cr0_cd,
    input               cr0_nw,
    
    input               acflag,
    
    input   [31:0]      cr3,
    
    input               pipeline_after_read_empty,
    input               pipeline_after_prefetch_empty,
    
    output reg  [31:0]  tlb_code_pf_cr2,
    output reg  [15:0]  tlb_code_pf_error_code,
    
    output reg  [31:0]  tlb_check_pf_cr2,
    output reg  [15:0]  tlb_check_pf_error_code,
    
    output reg  [31:0]  tlb_write_pf_cr2,
    output reg  [15:0]  tlb_write_pf_error_code,
        
    output reg  [31:0]  tlb_read_pf_cr2,
    output reg  [15:0]  tlb_read_pf_error_code,
    
    //RESP:
    input               tlbflushsingle_do,
    output              tlbflushsingle_done,
    input   [31:0]      tlbflushsingle_address,
    //END
    
    //RESP:
    input               tlbflushall_do,
    //END
    
    //RESP:
    input               tlbread_do,
    output              tlbread_done,
    output              tlbread_page_fault,
    output              tlbread_ac_fault,
    output              tlbread_retry,
    
    input   [1:0]       tlbread_cpl,
    input   [31:0]      tlbread_address,
    input   [3:0]       tlbread_length,
    input   [3:0]       tlbread_length_full,
    input               tlbread_lock,
    input               tlbread_rmw,
    output  [63:0]      tlbread_data,
    //END
    
    //RESP:
    input               tlbwrite_do,
    output              tlbwrite_done,
    output              tlbwrite_page_fault,
    output              tlbwrite_ac_fault,
    
    input   [1:0]       tlbwrite_cpl,
    input   [31:0]      tlbwrite_address,
    input   [2:0]       tlbwrite_length,
    input   [2:0]       tlbwrite_length_full,
    input               tlbwrite_lock,
    input               tlbwrite_rmw,
    input   [31:0]      tlbwrite_data,
    //END
    
    //RESP:
    input               tlbcheck_do,
    output reg          tlbcheck_done,
    output              tlbcheck_page_fault,
    
    input   [31:0]      tlbcheck_address,
    input               tlbcheck_rw,
    //END
    
    //REQ:
    output              dcacheread_do,
    input               dcacheread_done,
    
    output  [3:0]       dcacheread_length,
    output              dcacheread_cache_disable,
    output  [31:0]      dcacheread_address,
    output  [3:0]       dcacheread_rgn,     // (SiSTer: the L2 regions of dcacheread_address)
    input   [63:0]      dcacheread_data,
    //END
    
    //REQ:
    output              dcachewrite_do,
    input               dcachewrite_done,
    
    output  [2:0]       dcachewrite_length,
    output              dcachewrite_cache_disable,
    output  [31:0]      dcachewrite_address,
    output  [3:0]       dcachewrite_rgn,    // (SiSTer: the L2 regions of dcachewrite_address)
    output              dcachewrite_write_through,
    output  [31:0]      dcachewrite_data,
    //END
    
    //RESP:
    input               tlbcoderequest_do,
    input       [31:0]  tlbcoderequest_address,
    input               tlbcoderequest_su,
    //END

    //REQ:
    output              tlbcode_do,
    output      [31:0]  tlbcode_linear,
    output      [31:0]  tlbcode_physical,
    output              tlbcode_cache_disable,
    //END
    
    //REQ:
    output              prefetchfifo_signal_pf_do
    //END
);

//------------------------------------------------------------------------------

reg [4:0]   state;

reg [31:0]  linear;
reg         su;
reg         rw;
reg         wp;
reg [1:0]   current_type;

reg [31:0]  pde;
reg [31:0]  pte;

reg         code_pf;
reg         check_pf;

reg         write_pf;
reg         write_ac;

reg         read_pf;
reg         read_ac;

reg         pr_reset_waiting;

reg         tlbflushall_do_waiting;

reg [1:0]   write_double_state;
reg [31:0]  write_double_linear;

//------------------------------------------------------------------------------

wire [31:0] memtype_physical;
wire        memtype_cache_disable;
wire        memtype_write_transparent;

wire        rw_entry;
wire        su_entry;
wire        fault;

wire        rw_entry_before_pte;
wire        su_entry_before_pte;
wire        fault_before_pte;

wire [31:0] cr3_base;
wire        cr3_pwt;
wire        cr3_pcd;

assign cr3_base = { cr3[31:12], 12'd0 };
assign cr3_pwt  = cr3[3];
assign cr3_pcd  = cr3[4];

//------------------------------------------------------------------------------

localparam [4:0] STATE_IDLE             = 5'd0;
localparam [4:0] STATE_CODE_CHECK       = 5'd1;
localparam [4:0] STATE_LOAD_PDE         = 5'd2;
localparam [4:0] STATE_LOAD_PTE_START   = 5'd3;
localparam [4:0] STATE_LOAD_PTE         = 5'd4;
localparam [4:0] STATE_LOAD_PTE_END     = 5'd5;
localparam [4:0] STATE_SAVE_PDE         = 5'd6;
localparam [4:0] STATE_SAVE_PTE_START   = 5'd7;
localparam [4:0] STATE_SAVE_PTE         = 5'd8;
localparam [4:0] STATE_CHECK_CHECK      = 5'd9;
localparam [4:0] STATE_WRITE_CHECK      = 5'd10;
localparam [4:0] STATE_WRITE_WAIT_START = 5'd11;
localparam [4:0] STATE_WRITE_WAIT       = 5'd12;
localparam [4:0] STATE_WRITE_DOUBLE     = 5'd13;
localparam [4:0] STATE_READ_CHECK       = 5'd14;
localparam [4:0] STATE_READ_WAIT_START  = 5'd15;
localparam [4:0] STATE_READ_WAIT        = 5'd16;
localparam [4:0] STATE_RETRY            = 5'd17;

localparam [1:0] TYPE_CODE  = 2'd0;
localparam [1:0] TYPE_CHECK = 2'd1;
localparam [1:0] TYPE_WRITE = 2'd2;
localparam [1:0] TYPE_READ  = 2'd3;

localparam [1:0] WRITE_DOUBLE_NONE    = 2'd0;
localparam [1:0] WRITE_DOUBLE_CHECK   = 2'd1;
localparam [1:0] WRITE_DOUBLE_RESTART = 2'd2;

wire translate_combined_rw;
wire translate_combined_su;


wire        translate_do;
wire        translate_valid;
wire [31:0] translate_physical;
wire [3:0]  translate_rgn;      // (SiSTer: tlb_regs)
wire        translate_pwt;
wire        translate_pcd;

wire        tlbregs_write_do;
wire [31:0] tlbregs_write_linear;
wire [31:0] tlbregs_write_physical;
wire        tlbregs_write_pwt;
wire        tlbregs_write_pcd;
wire        tlbregs_write_combined_rw;
wire        tlbregs_write_combined_su;

wire  code_pf_to_reg;
wire  check_pf_to_reg;
wire  read_pf_to_reg;
wire  read_ac_to_reg;
wire  write_pf_to_reg;
wire  write_ac_to_reg;

//------------------------------------------------------------------------------

assign tlbread_data       = dcacheread_data;
assign tlbread_page_fault = read_pf;
assign tlbread_ac_fault   = read_ac;

assign tlbwrite_page_fault = write_pf;
assign tlbwrite_ac_fault   = write_ac;

assign tlbcheck_page_fault = check_pf;

assign rw_entry = (state == STATE_LOAD_PTE_END)? pde[1] & pte[1] : translate_combined_rw;
assign su_entry = (state == STATE_LOAD_PTE_END)? pde[2] & pte[2] : translate_combined_su;    

assign fault =
    // user can not access supervisor
    (su && ~(su_entry)) ||
    // user can not write on read-only page
    (su && su_entry && ~(rw_entry) && rw) ||
    // supervisor can not write on read-only page when write-protect is on
    (wp && ~(su) && ~(rw_entry) && rw);

assign rw_entry_before_pte = pde[1] & dcacheread_data[1];
assign su_entry_before_pte = pde[2] & dcacheread_data[2];
    
assign fault_before_pte =
    // user can not access supervisor
    (su && ~(su_entry_before_pte)) ||
    // user can not write on read-only page
    (su && su_entry_before_pte && ~(rw_entry_before_pte) && rw) ||
    // supervisor can not write on read-only page when write-protect is on
    (wp && ~(su) && ~(rw_entry_before_pte) && rw);

    
assign tlbcode_linear = linear;
// reg [31:0] linears[0:7] /* synthesis syn_preserve = "true" */;   // nand2mario: replicated `linear` to reduce fanout

//------------------------------------------------------------------------------

tlb_memtype tlb_memtype_inst(
    .physical           (memtype_physical),             //input [31:0]
                       
    .cache_disable      (memtype_cache_disable),        //output
    .write_transparent  (memtype_write_transparent)     //output
);

// (SiSTer: tlb_regs' way hits and looked-up entries -- see tlb_out below)
wire [3:0]  tr_hit;
wire [49:0] tr_e0, tr_e1, tr_e2, tr_e3;
wire tlbregs_tlbflushsingle_do;
wire tlbregs_tlbflushall_do;

tlb_regs tlb_regs_inst(
    .clk                        (clk),
    .rst_n                      (rst_n),
    
    //RESP:
    .tlbflushsingle_do          (tlbregs_tlbflushsingle_do),    //input
    .tlbflushsingle_address     (tlbflushsingle_address),       //input [31:0]
    //END
    
    //RESP:
    .tlbflushall_do             (tlbregs_tlbflushall_do),       //input
    //END
    
    .rw                         (rw),                           //input
    
    //RESP:
    .tlbregs_write_do           (tlbregs_write_do),             //input
    .tlbregs_write_linear       (tlbregs_write_linear),         //input [31:0]
    .tlbregs_write_physical     (tlbregs_write_physical),       //input [31:0]
    
    .tlbregs_write_pwt          (tlbregs_write_pwt),            //input
    .tlbregs_write_pcd          (tlbregs_write_pcd),            //input
    .tlbregs_write_combined_rw  (tlbregs_write_combined_rw),    //input
    .tlbregs_write_combined_su  (tlbregs_write_combined_su),    //input
    //END
    
    //RESP:
    .translate_do               (translate_do),                 //input
    .translate_linear           (linear),                       //input [31:0]
    .translate_valid            (translate_valid),              //output
    .translate_physical         (translate_physical),           //output [31:0]
    .translate_rgn              (translate_rgn),                //output [3:0] (SiSTer)
    .translate_hit              (tr_hit),                       //output [3:0] (SiSTer)
    .translate_e0               (tr_e0),                        //output [49:0] (SiSTer)
    .translate_e1               (tr_e1),                        //output [49:0] (SiSTer)
    .translate_e2               (tr_e2),                        //output [49:0] (SiSTer)
    .translate_e3               (tr_e3),                        //output [49:0] (SiSTer)
    .translate_pwt              (translate_pwt),                //output
    .translate_pcd              (translate_pcd),                //output
    .translate_combined_rw      (translate_combined_rw),        //output
    .translate_combined_su      (translate_combined_su)         //output
    //END
);

//------------------------------------------------------------------------------

always @(posedge clk) begin
    if(rst_n == 1'b0)   code_pf <= `FALSE;
    else if(pr_reset)   code_pf <= `FALSE;
    else                code_pf <= code_pf_to_reg;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)   check_pf <= `FALSE;
    else if(exe_reset)  check_pf <= `FALSE;
    else                check_pf <= check_pf_to_reg;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)   read_pf <= `FALSE;
    else if(rd_reset)   read_pf <= `FALSE;
    else                read_pf <= read_pf_to_reg;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)   read_ac <= `FALSE;
    else if(rd_reset)   read_ac <= `FALSE;
    else                read_ac <= read_ac_to_reg;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)   write_pf <= `FALSE;
    else if(wr_reset)   write_pf <= `FALSE;
    else                write_pf <= write_pf_to_reg;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)   write_ac <= `FALSE;
    else if(wr_reset)   write_ac <= `FALSE;
    else                write_ac <= write_ac_to_reg;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)                           pr_reset_waiting <= `FALSE;
    else if(pr_reset && state != STATE_IDLE)    pr_reset_waiting <= `TRUE;
    else if(state == STATE_IDLE)                pr_reset_waiting <= `FALSE;
end

always @(posedge clk) begin
    if(rst_n == 1'b0)                               tlbflushall_do_waiting <= `FALSE;
    else if(tlbflushall_do && state != STATE_IDLE)  tlbflushall_do_waiting <= `TRUE;
    else if(tlbregs_tlbflushall_do)                 tlbflushall_do_waiting <= `FALSE;
end

//------------------------------------------------------------------------------

// synthesis translate_off
wire _unused_ok = &{ 1'b0, cr3[11:5], cr3[2:0], tlbread_lock, tlbwrite_lock, tlbwrite_rmw, cr3_base[11:0], 1'b0 };
// synthesis translate_on

//------------------------------------------------------------------------------

/*******************************************************************************SCRIPT
NO_ALWAYS_BLOCK(code_pf);
NO_ALWAYS_BLOCK(check_pf);
NO_ALWAYS_BLOCK(read_pf);
NO_ALWAYS_BLOCK(write_pf);
NO_ALWAYS_BLOCK(read_ac);
NO_ALWAYS_BLOCK(write_ac);
*/
    
/*******************************************************************************SCRIPT
IF(state == STATE_IDLE);
    
    SAVE(tlbcheck_done, `FALSE);
    SAVE(tlbcode_do,    `FALSE);
    SAVE(read_pf,       `FALSE);
    SAVE(write_pf,      `FALSE);
    
    IF(tlbflushsingle_do);
    
        SET(tlbregs_tlbflushsingle_do);
        SET(tlbflushsingle_done);
    
    ELSE_IF(tlbflushall_do || tlbflushall_do_waiting);
        
        SET(tlbregs_tlbflushall_do);
    
    ELSE_IF(~(wr_reset) && tlbwrite_do && ~(write_ac) && cr0_am && acflag && tlbwrite_cpl == 2'd3 &&
             ( (tlbwrite_length_full == 3'd2 && tlbwrite_address[0] != 1'b0) || (tlbwrite_length_full == 3'd4 && tlbwrite_address[1:0] != 2'b00) )
    );
        
        SAVE(write_ac, `TRUE);
    
    ELSE_IF(~(wr_reset) && tlbwrite_do && ~(write_pf) && ~(write_ac));
        
        SAVE(rw,             `TRUE);
        SAVE(su,             tlbwrite_cpl == 2'd3);
        SAVE(wp,             cr0_wp);

        SAVE(write_double_state, (cr0_pg && tlbwrite_length != tlbwrite_length_full && { 1'b0, tlbwrite_address[11:0] } + { 10'd0, tlbwrite_length_full } >= 13'h1000)? WRITE_DOUBLE_CHECK : WRITE_DOUBLE_NONE);
        
        SAVE(linear, tlbwrite_address);
        SAVE(state,  STATE_WRITE_CHECK);
        
    ELSE_IF(~(exe_reset) && tlbcheck_do && ~(tlbcheck_done) && ~(check_pf));
    
        SAVE(rw,             tlbcheck_rw);
        SAVE(su,             `FALSE);
        SAVE(wp,             cr0_wp);
        
        SAVE(write_double_state, WRITE_DOUBLE_NONE);
        
        SAVE(linear, tlbcheck_address);
        SAVE(state,  STATE_CHECK_CHECK);
        
    ELSE_IF(~(rd_reset) && tlbread_do && ~(read_ac) && cr0_am && acflag && tlbread_cpl == 2'd3 &&
             ( (tlbread_length_full == 4'd2 && tlbread_address[0] != 1'b0) || (tlbread_length_full == 4'd4 && tlbread_address[1:0] != 2'b00))
    );
        
        SAVE(read_ac, `TRUE);
    
    ELSE_IF(~(rd_reset) && tlbread_do && ~(read_pf) && ~(read_ac));
        
        SAVE(rw,             tlbread_rmw);
        SAVE(su,             tlbread_cpl == 2'd3);
        SAVE(wp,             cr0_wp);
        
        SAVE(write_double_state, WRITE_DOUBLE_NONE);
        
        SAVE(linear, tlbread_address);
        SAVE(state,  STATE_READ_CHECK);
        
        
    ELSE_IF(~(pr_reset) && tlbcoderequest_do && ~(code_pf) && ~(tlbcode_do));
        
        SAVE(rw,             `FALSE);
        SAVE(su,             tlbcoderequest_su);
        SAVE(wp,             cr0_wp);
        
        SAVE(write_double_state, WRITE_DOUBLE_NONE);
        
        SAVE(linear, tlbcoderequest_address);
        SAVE(state,  STATE_CODE_CHECK);
        
    ENDIF();
ENDIF();
*/

/*******************************************************************************SCRIPT

IF(state == STATE_WRITE_DOUBLE);
    
    IF(write_double_state == WRITE_DOUBLE_CHECK);
        SAVE(linear, { linear[31:12], 12'd0 } + 32'h00001000);
        SAVE(write_double_linear, linear);
        
        SAVE(write_double_state, WRITE_DOUBLE_RESTART);
        SAVE(state,              STATE_WRITE_CHECK);
    ELSE();
        SAVE(linear, write_double_linear);
        
        SAVE(write_double_state, WRITE_DOUBLE_NONE);
        SAVE(state,              STATE_WRITE_CHECK);
    ENDIF();
ENDIF();

*/

/*******************************************************************************SCRIPT
IF(state == STATE_WRITE_WAIT);

    IF(dcachewrite_done);
        SET(tlbwrite_done);
        
        SAVE(state, STATE_IDLE);
    ENDIF();

ENDIF();
*/

/*******************************************************************************SCRIPT
    
IF(state == STATE_READ_WAIT);

    IF(dcacheread_done);
        SET(tlbread_done);
        
        SAVE(state, STATE_IDLE);
    ENDIF();

ENDIF();
*/
    
/*******************************************************************************SCRIPT

IF(state == STATE_READ_CHECK);
    
    IF(cr0_pg);
        SET(translate_do);
    ENDIF();
    
    IF(~(cr0_pg) || translate_valid);
        
        IF(cr0_pg && fault);
            SAVE(read_pf,            `TRUE);
            
            SAVE(tlb_read_pf_cr2,        linear);
            SAVE(tlb_read_pf_error_code, { 13'd0, su, rw, `TRUE });
            
            SAVE(state, STATE_IDLE);
            
        ELSE();

            SET(memtype_physical, translate_physical);
        
            SET(dcacheread_do);
            SET(dcacheread_address,          memtype_physical);
            SET(dcacheread_length,           tlbread_length);
            SET(dcacheread_cache_disable,    cr0_cd || translate_pcd || memtype_cache_disable);
            
            SAVE(state, STATE_READ_WAIT);
        ENDIF();

    ELSE();
        
        SET(memtype_physical, { cr3_base[31:12], linear[31:22], 2'd0 });
        
        SET(dcacheread_do);
        SET(dcacheread_address,          memtype_physical);
        SET(dcacheread_length,           4'd4);
        SET(dcacheread_cache_disable,    cr0_cd || cr3_pcd || memtype_cache_disable);
        
        SAVE(current_type,   TYPE_READ);
        SAVE(state,          STATE_LOAD_PDE);
    
    ENDIF();
    
ENDIF();
*/

/*******************************************************************************SCRIPT
    
IF(state == STATE_WRITE_CHECK);
    
    IF(cr0_pg);
        SET(translate_do);
    ENDIF();
    
    IF(~(cr0_pg) || translate_valid);
        
        IF(cr0_pg && fault);
            SAVE(write_pf,                `TRUE);
            
            SAVE(tlb_write_pf_cr2,        linear);
            SAVE(tlb_write_pf_error_code, { 13'd0, su, rw, `TRUE });
            
            SAVE(state, STATE_IDLE);
            
        ELSE_IF(translate_valid && write_double_state != WRITE_DOUBLE_NONE);
        
            SAVE(state, STATE_WRITE_DOUBLE);
            
        ELSE();
            
            SET(memtype_physical, translate_physical);

            SET(dcachewrite_do);
            SET(dcachewrite_address,         memtype_physical);
            SET(dcachewrite_length,          tlbwrite_length);
            SET(dcachewrite_cache_disable,   cr0_cd || translate_pcd || memtype_cache_disable);
            SET(dcachewrite_write_through,   cr0_nw || translate_pwt || memtype_write_transparent);
            SET(dcachewrite_data,            tlbwrite_data);
            
            SAVE(state, STATE_WRITE_WAIT);
        ENDIF();

    ELSE();
        
        SET(memtype_physical, { cr3_base[31:12], linear[31:22], 2'd0 });
        
        SET(dcacheread_do);
        SET(dcacheread_address,          memtype_physical);
        SET(dcacheread_length,           4'd4);
        SET(dcacheread_cache_disable,    cr0_cd || cr3_pcd || memtype_cache_disable);
        
        SAVE(current_type,   TYPE_WRITE);
        SAVE(state,          STATE_LOAD_PDE);
    
    ENDIF();
    
ENDIF();
*/
    
/*******************************************************************************SCRIPT
 
IF(state == STATE_CHECK_CHECK);

    IF(cr0_pg);
        SET(translate_do);
    ENDIF();
    
    IF(~(cr0_pg) || translate_valid);
        
        IF(cr0_pg && fault);
            SAVE(check_pf,               `TRUE);
            
            SAVE(tlb_check_pf_cr2,       linear);
            SAVE(tlb_check_pf_error_code,{ 13'd0, su, rw, `TRUE });
            
        ELSE();
            SAVE(tlbcheck_done, `TRUE);
        ENDIF();
        
        SAVE(state, STATE_IDLE);
        
    ELSE();
        
        SET(memtype_physical, { cr3_base[31:12], linear[31:22], 2'd0 });
        
        SET(dcacheread_do);
        SET(dcacheread_address,          memtype_physical);
        SET(dcacheread_length,           4'd4);
        SET(dcacheread_cache_disable,    cr0_cd || cr3_pcd || memtype_cache_disable);
        
        SAVE(current_type,   TYPE_CHECK);
        SAVE(state,          STATE_LOAD_PDE);
    
    ENDIF();
    
ENDIF();
*/
    
/*******************************************************************************SCRIPT

IF(state == STATE_CODE_CHECK);
    
    IF(cr0_pg);
        SET(translate_do);
    ENDIF();
    
    IF(pr_reset || pr_reset_waiting); //NOTE: pr_reset required
        
        SAVE(state, STATE_IDLE);
        
    ELSE_IF(~(cr0_pg) || translate_valid);
    
        IF(cr0_pg && fault);
            SAVE(code_pf,                `TRUE);
            
            SAVE(tlb_code_pf_cr2,       linear);
            SAVE(tlb_code_pf_error_code,{ 13'd0, su, rw, `TRUE });
            
            SET(prefetchfifo_signal_pf_do);

        ELSE();
            
            SET(memtype_physical, translate_physical);
            
            SET(tlbcode_do, `TRUE);
            SET(tlbcode_physical,        memtype_physical);
            //SET(tlbcode_cache_disable,   cr0_cd || translate_pcd || memtype_cache_disable);
            SET(tlbcode_cache_disable,   `FALSE);
        
        ENDIF();
        
        SAVE(state, STATE_IDLE);
        
    ELSE();
        
        SET(memtype_physical, { cr3_base[31:12], linear[31:22], 2'd0 });
        
        
        SET(dcacheread_do);
        SET(dcacheread_address,          memtype_physical);
        SET(dcacheread_length,           4'd4);
        SET(dcacheread_cache_disable,    cr0_cd || cr3_pcd || memtype_cache_disable);
        
        SAVE(current_type,   TYPE_CODE);
        SAVE(state,          STATE_LOAD_PDE);
    ENDIF();
ENDIF();
*/
    
/*******************************************************************************SCRIPT

IF(state == STATE_LOAD_PDE);

    IF(dcacheread_done);
    
        SAVE(pde, dcacheread_data[31:0]);
    
        IF(dcacheread_data[0] == `FALSE);
            
            IF(current_type == TYPE_CODE && ~(pr_reset) && ~(pr_reset_waiting));
            
                SAVE(code_pf,                `TRUE);
                SAVE(tlb_code_pf_cr2,        linear);
                SAVE(tlb_code_pf_error_code, { 13'd0, su, rw, `FALSE });

                SET(prefetchfifo_signal_pf_do);
                
            ELSE_IF(current_type == TYPE_CHECK);
                
                SAVE(check_pf,               `TRUE);
                SAVE(tlb_check_pf_cr2,       linear);
                SAVE(tlb_check_pf_error_code,{ 13'd0, su, rw, `FALSE });
            
            ELSE_IF(current_type == TYPE_WRITE);
            
                SAVE(write_pf,               `TRUE);
                SAVE(tlb_write_pf_cr2,       linear);
                SAVE(tlb_write_pf_error_code,{ 13'd0, su, rw, `FALSE });
                
            ELSE_IF(current_type == TYPE_READ);
            
                SAVE(read_pf,                `TRUE);
                SAVE(tlb_read_pf_cr2,        linear);
                SAVE(tlb_read_pf_error_code, { 13'd0, su, rw, `FALSE });
                
            ENDIF();
            
            SAVE(state, STATE_IDLE);
            
        ELSE();
        
            SAVE(state, STATE_LOAD_PTE_START);
            
        ENDIF();
    ENDIF();
ENDIF();
*/
    
/*******************************************************************************SCRIPT
IF(state == STATE_LOAD_PTE_START);

    SET(memtype_physical, { pde[31:12], linear[21:12], 2'd0 });
            
    SET(dcacheread_do);
    SET(dcacheread_address,          memtype_physical);
    SET(dcacheread_length,           4'd4);
    SET(dcacheread_cache_disable,    cr0_cd || pde[4] || memtype_cache_disable);
    
    SAVE(state, STATE_LOAD_PTE);

ENDIF();
*/

/*******************************************************************************SCRIPT
IF(state == STATE_RETRY);

    SAVE(state, STATE_IDLE);
    
    SET(tlbread_retry, current_type == TYPE_READ);
ENDIF();
*/

/*******************************************************************************SCRIPT
IF(state == STATE_LOAD_PTE);

    IF(dcacheread_done);
    
        SAVE(pte, dcacheread_data[31:0]);
    
        IF(dcacheread_data[0] == `FALSE || fault_before_pte);
            
            IF(current_type == TYPE_CODE && ~(pr_reset) && ~(pr_reset_waiting));
        
                SAVE(code_pf,                `TRUE);
                SAVE(tlb_code_pf_cr2,        linear);
                SAVE(tlb_code_pf_error_code, { 13'd0, su, rw, dcacheread_data[0] });

                SET(prefetchfifo_signal_pf_do);
            
            ELSE_IF(current_type == TYPE_CHECK);
                
                SAVE(check_pf,               `TRUE);
                SAVE(tlb_check_pf_cr2,       linear);
                SAVE(tlb_check_pf_error_code,{ 13'd0, su, rw, dcacheread_data[0] });
            
            ELSE_IF(current_type == TYPE_WRITE);
                
                SAVE(write_pf,               `TRUE);
                SAVE(tlb_write_pf_cr2,       linear);
                SAVE(tlb_write_pf_error_code,{ 13'd0, su, rw, dcacheread_data[0] });
            
            ELSE_IF(current_type == TYPE_READ);
                
                SAVE(read_pf,            `TRUE);
                SAVE(tlb_read_pf_cr2,        linear);
                SAVE(tlb_read_pf_error_code, { 13'd0, su, rw, dcacheread_data[0] });
                
            ENDIF();
            
            SAVE(state, STATE_IDLE);
                
        ELSE_IF(((current_type == TYPE_READ && ~(pipeline_after_read_empty)) || (current_type == TYPE_CODE && (~(pipeline_after_prefetch_empty) || pr_reset_waiting))) &&
                 (pde[5] == `FALSE || dcacheread_data[5] == `FALSE || (dcacheread_data[6] == `FALSE && rw)));
            
                // no side effects for read or code possible yet
                SAVE(state, STATE_RETRY);

//AO-notlb: ELSE_IF(current_type == TYPE_CODE && (pr_reset || pr_reset_waiting));
//AO-notlb: SAVE(state, STATE_IDLE);

        ELSE();
            SAVE(state, STATE_LOAD_PTE_END);
        ENDIF();
    ENDIF();
ENDIF();
*/


/*******************************************************************************SCRIPT
IF(state == STATE_LOAD_PTE_END);

//NOTE: always write to TLB: IF(cr0_cd == `FALSE && pde[4] == `FALSE && pte[4] == `FALSE);
    
    SET(tlbregs_write_do);
    SET(tlbregs_write_linear,        linear);
    SET(tlbregs_write_physical,      { pte[31:12], linear[11:0] });
    SET(tlbregs_write_pwt,           pte[3]);
    SET(tlbregs_write_pcd,           pte[4]);
    SET(tlbregs_write_combined_rw,   rw_entry);
    SET(tlbregs_write_combined_su,   su_entry);
    
    // PDE not accessed
    IF(pde[5] == `FALSE);
        
        SET(memtype_physical, { cr3_base[31:12], linear[31:22], 2'd0 });
        
        SET(dcachewrite_do);
        SET(dcachewrite_address,         memtype_physical);
        SET(dcachewrite_length,          3'd4);
        SET(dcachewrite_cache_disable,   cr0_cd || cr3_pcd || memtype_cache_disable);
        SET(dcachewrite_write_through,   cr0_nw || cr3_pwt || memtype_write_transparent);
        SET(dcachewrite_data,            pde | 32'h00000020);
        
        SAVE(state, STATE_SAVE_PDE);
        
    // PTE not accessed or has to become dirty
    ELSE_IF(pte[5] == `FALSE || (pte[6] == `FALSE && rw));
        
        SET(memtype_physical, { pde[31:12], linear[21:12], 2'b00 });
    
        SET(dcachewrite_do);
        SET(dcachewrite_address,         memtype_physical);
        SET(dcachewrite_length,          3'd4);
        SET(dcachewrite_cache_disable,   cr0_cd || pde[4] || memtype_cache_disable);
        SET(dcachewrite_write_through,   cr0_nw || pde[3] || memtype_write_transparent);
        SET(dcachewrite_data,            pte[31:0] | 32'h00000020 | ((pte[6] == `FALSE && rw)? 32'h00000040 : 32'h00000000));
    
        SAVE(state, STATE_SAVE_PTE);
        
    ELSE();
        
        IF(current_type == TYPE_WRITE && write_double_state != WRITE_DOUBLE_NONE);
        
            SAVE(state, STATE_WRITE_DOUBLE);
        
        ELSE_IF(current_type == TYPE_WRITE);
        
            SET(memtype_physical, { pte[31:12], linear[11:0] });

            SET(dcachewrite_do);
            SET(dcachewrite_address,         memtype_physical);
            SET(dcachewrite_length,          tlbwrite_length);
            SET(dcachewrite_cache_disable,   cr0_cd || pte[4] || memtype_cache_disable);
            SET(dcachewrite_write_through,   cr0_nw || pte[3] || memtype_write_transparent);
            SET(dcachewrite_data,            tlbwrite_data);
        
            SAVE(state, STATE_WRITE_WAIT);
        
        ELSE_IF(current_type == TYPE_READ);
        
            SAVE(state, STATE_READ_WAIT_START);

//AO-notlb: ELSE_IF(current_type == TYPE_CODE && pr_reset == 1'b0 && pr_reset_waiting == 1'b0);
//AO-notlb: SAVE(tlbcode_do, `TRUE);
//AO-notlb: SAVE(tlbcode_physical,    { pte[31:12], linear[11:0] });
//AO-notlb: SAVE(tlbcode_cache_disable,   cr0_cd);
//AO-notlb: SAVE(state, STATE_IDLE);
        ELSE();
        
            SAVE(state, STATE_IDLE);
        ENDIF();
    ENDIF();
ENDIF();
*/

/*******************************************************************************SCRIPT
IF(state == STATE_READ_WAIT_START);
    
    SET(memtype_physical, { pte[31:12], linear[11:0] });
                    
    SET(dcacheread_do);
    SET(dcacheread_address,          memtype_physical);
    SET(dcacheread_length,           tlbread_length);
    SET(dcacheread_cache_disable,    cr0_cd || pte[4] || memtype_cache_disable);

    SAVE(state, STATE_READ_WAIT);
    
ENDIF();
*/

/*******************************************************************************SCRIPT
    
IF(state == STATE_SAVE_PDE);

    IF(dcachewrite_done);
        
        // PTE not accessed or has to become dirty
        IF(pte[5] == `FALSE || (pte[6] == `FALSE && rw));
        
            SAVE(state, STATE_SAVE_PTE_START);
        
        ELSE();
            
            IF(current_type == TYPE_WRITE);
                
                SAVE(state, STATE_WRITE_WAIT_START);
                
            ELSE_IF(current_type == TYPE_READ);
                
                SET(memtype_physical, { pte[31:12], linear[11:0] });

                SET(dcacheread_do);
                SET(dcacheread_address,          memtype_physical);
                SET(dcacheread_length,           tlbread_length);
                SET(dcacheread_cache_disable,    cr0_cd || pte[4] || memtype_cache_disable);

                SAVE(state, STATE_READ_WAIT);
                
//AO-notlb: ELSE_IF(current_type == TYPE_CODE && pr_reset == 1'b0 && pr_reset_waiting == 1'b0);
//AO-notlb: SAVE(tlbcode_do, `TRUE);
//AO-notlb: SAVE(tlbcode_physical,    { pte[31:12], linear[11:0] });
//AO-notlb: SAVE(tlbcode_cache_disable,   cr0_cd);
//AO-notlb: SAVE(state, STATE_IDLE);

            ELSE();
        
                SAVE(state, STATE_IDLE);
                
            ENDIF();
            
        ENDIF();
    ENDIF();
ENDIF();
*/

/*******************************************************************************SCRIPT

IF(state == STATE_SAVE_PTE_START);

    SET(memtype_physical, { pde[31:12], linear[21:12], 2'b00 });
            
    SET(dcachewrite_do);
    SET(dcachewrite_address,         memtype_physical);
    SET(dcachewrite_length,          3'd4);
    SET(dcachewrite_cache_disable,   cr0_cd || pde[4] || memtype_cache_disable);
    SET(dcachewrite_write_through,   cr0_nw || pde[3] || memtype_write_transparent);
    SET(dcachewrite_data,            pte[31:0] | 32'h00000020 | ((pte[6] == `FALSE && rw)? 32'h00000040 : 32'h00000000));

    SAVE(state, STATE_SAVE_PTE);

ENDIF();
*/

/*******************************************************************************SCRIPT

IF(state == STATE_WRITE_WAIT_START);
    
    IF(current_type == TYPE_WRITE && write_double_state != WRITE_DOUBLE_NONE);
        
        SAVE(state, STATE_WRITE_DOUBLE);
    
    ELSE();
    
        SET(memtype_physical, { pte[31:12], linear[11:0] });

        SET(dcachewrite_do);
        SET(dcachewrite_address,         memtype_physical);
        SET(dcachewrite_length,          tlbwrite_length);
        SET(dcachewrite_cache_disable,   cr0_cd || pte[4] || memtype_cache_disable);
        SET(dcachewrite_write_through,   cr0_nw || pte[3] || memtype_write_transparent);
        SET(dcachewrite_data,            tlbwrite_data);

        SAVE(state, STATE_WRITE_WAIT);
    ENDIF();
ENDIF();
*/

/*******************************************************************************SCRIPT

IF(state == STATE_SAVE_PTE);

    IF(dcachewrite_done);

        IF(current_type == TYPE_WRITE);
                
            SAVE(state, STATE_WRITE_WAIT_START);
            
        ELSE_IF(current_type == TYPE_READ);
                
            SET(memtype_physical, { pte[31:12], linear[11:0] });
            
            SET(dcacheread_do);
            SET(dcacheread_address,          memtype_physical);
            SET(dcacheread_length,           tlbread_length);
            SET(dcacheread_cache_disable,    cr0_cd || pte[4] || memtype_cache_disable);

            SAVE(state, STATE_READ_WAIT);
            
//AO-notlb: ELSE_IF(current_type == TYPE_CODE && pr_reset == 1'b0 && pr_reset_waiting == 1'b0);
//AO-notlb: SAVE(tlbcode_do, `TRUE);
//AO-notlb: SAVE(tlbcode_physical,    { pte[31:12], linear[11:0] });
//AO-notlb: SAVE(tlbcode_cache_disable,   cr0_cd);
//AO-notlb: SAVE(state, STATE_IDLE);

        ELSE();
            
            SAVE(state, STATE_IDLE);
        ENDIF();
        
    ENDIF();
ENDIF();
*/

//------------------------------------------------------------------------------

//======================================================== conditions
wire cond_0 = state == STATE_IDLE;
wire cond_1 = tlbflushsingle_do;
wire cond_2 = tlbflushall_do || tlbflushall_do_waiting;
wire cond_3 = ~(wr_reset) && tlbwrite_do && ~(write_ac) && cr0_am && acflag && tlbwrite_cpl == 2'd3 &&
             ( (tlbwrite_length_full == 3'd2 && tlbwrite_address[0] != 1'b0) || (tlbwrite_length_full == 3'd4 && tlbwrite_address[1:0] != 2'b00) )
    ;
wire cond_4 = ~(wr_reset) && tlbwrite_do && ~(write_pf) && ~(write_ac);
wire cond_5 = ~(exe_reset) && tlbcheck_do && ~(tlbcheck_done) && ~(check_pf);
wire cond_6 = ~(rd_reset) && tlbread_do && ~(read_ac) && cr0_am && acflag && tlbread_cpl == 2'd3 &&
             ( (tlbread_length_full == 4'd2 && tlbread_address[0] != 1'b0) || (tlbread_length_full == 4'd4 && tlbread_address[1:0] != 2'b00))
    ;
wire cond_7 = ~(rd_reset) && tlbread_do && ~(read_pf) && ~(read_ac);
wire cond_8 = ~(pr_reset) && tlbcoderequest_do && ~(code_pf) && ~(tlbcode_do);
wire cond_9 = state == STATE_WRITE_DOUBLE;
wire cond_10 = write_double_state == WRITE_DOUBLE_CHECK;
wire cond_11 = state == STATE_WRITE_WAIT;
wire cond_12 = dcachewrite_done;
wire cond_13 = state == STATE_READ_WAIT;
wire cond_14 = dcacheread_done;
wire cond_15 = state == STATE_READ_CHECK;
wire cond_16 = cr0_pg;
wire cond_17 = ~(cr0_pg) || translate_valid;
wire cond_18 = cr0_pg && fault;
wire cond_19 = state == STATE_WRITE_CHECK;
wire cond_20 = translate_valid && write_double_state != WRITE_DOUBLE_NONE;
wire cond_21 = state == STATE_CHECK_CHECK;
wire cond_22 = state == STATE_CODE_CHECK;
wire cond_23 = pr_reset || pr_reset_waiting;
wire cond_24 = state == STATE_LOAD_PDE;
wire cond_25 = dcacheread_data[0] == `FALSE;
wire cond_26 = current_type == TYPE_CODE && ~(pr_reset) && ~(pr_reset_waiting);
wire cond_27 = current_type == TYPE_CHECK;
wire cond_28 = current_type == TYPE_WRITE;
wire cond_29 = current_type == TYPE_READ;
wire cond_30 = state == STATE_LOAD_PTE_START;
wire cond_31 = state == STATE_RETRY;
wire cond_32 = state == STATE_LOAD_PTE;
wire cond_33 = dcacheread_data[0] == `FALSE || fault_before_pte;
wire cond_34 = ((current_type == TYPE_READ && ~(pipeline_after_read_empty)) || (current_type == TYPE_CODE && (~(pipeline_after_prefetch_empty) || pr_reset_waiting))) &&
                 (pde[5] == `FALSE || dcacheread_data[5] == `FALSE || (dcacheread_data[6] == `FALSE && rw));
wire cond_35 = state == STATE_LOAD_PTE_END;
wire cond_36 = pde[5] == `FALSE;
wire cond_37 = pte[5] == `FALSE || (pte[6] == `FALSE && rw);
wire cond_38 = current_type == TYPE_WRITE && write_double_state != WRITE_DOUBLE_NONE;
wire cond_39 = state == STATE_READ_WAIT_START;
wire cond_40 = state == STATE_SAVE_PDE;
wire cond_41 = state == STATE_SAVE_PTE_START;
wire cond_42 = state == STATE_WRITE_WAIT_START;
wire cond_43 = state == STATE_SAVE_PTE;
//======================================================== saves
wire [1:0] current_type_to_reg =
    (cond_15 && ~cond_17)? (   TYPE_READ) :
    (cond_19 && ~cond_17)? (   TYPE_WRITE) :
    (cond_21 && ~cond_17)? (   TYPE_CHECK) :
    (cond_22 && ~cond_23 && ~cond_17)? (   TYPE_CODE) :
    current_type;
assign  read_pf_to_reg =
    (cond_0)? (       `FALSE) :
    (cond_15 && cond_17 && cond_18)? (            `TRUE) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && ~cond_27 && ~cond_28 && cond_29)? (                `TRUE) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && ~cond_27 && ~cond_28 && cond_29)? (            `TRUE) :
    read_pf;
wire [31:0] pde_to_reg =
    (cond_24 && cond_14)? ( dcacheread_data[31:0]) :
    pde;
assign  write_pf_to_reg =
    (cond_0)? (      `FALSE) :
    (cond_19 && cond_17 && cond_18)? (                `TRUE) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && ~cond_27 && cond_28)? (               `TRUE) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && ~cond_27 && cond_28)? (               `TRUE) :
    write_pf;
wire [4:0] state_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && cond_4)? (  STATE_WRITE_CHECK) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && cond_5)? (  STATE_CHECK_CHECK) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && cond_7)? (  STATE_READ_CHECK) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && ~cond_7 && cond_8)? (  STATE_CODE_CHECK) :
    (cond_9 && cond_10)? (              STATE_WRITE_CHECK) :
    (cond_9 && ~cond_10)? (              STATE_WRITE_CHECK) :
    (cond_11 && cond_12)? ( STATE_IDLE) :
    (cond_13 && cond_14)? ( STATE_IDLE) :
    (cond_15 && cond_17 && cond_18)? ( STATE_IDLE) :
    (cond_15 && cond_17 && ~cond_18)? ( STATE_READ_WAIT) :
    (cond_15 && ~cond_17)? (          STATE_LOAD_PDE) :
    (cond_19 && cond_17 && cond_18)? ( STATE_IDLE) :
    (cond_19 && cond_17 && ~cond_18 && cond_20)? ( STATE_WRITE_DOUBLE) :
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? ( STATE_WRITE_WAIT) :
    (cond_19 && ~cond_17)? (          STATE_LOAD_PDE) :
    (cond_21 && cond_17)? ( STATE_IDLE) :
    (cond_21 && ~cond_17)? (          STATE_LOAD_PDE) :
    (cond_22 && cond_23)? ( STATE_IDLE) :
    (cond_22 && ~cond_23 && cond_17)? ( STATE_IDLE) :
    (cond_22 && ~cond_23 && ~cond_17)? (          STATE_LOAD_PDE) :
    (cond_24 && cond_14 && cond_25)? ( STATE_IDLE) :
    (cond_24 && cond_14 && ~cond_25)? ( STATE_LOAD_PTE_START) :
    (cond_30)? ( STATE_LOAD_PTE) :
    (cond_31)? ( STATE_IDLE) :
    (cond_32 && cond_14 && cond_33)? ( STATE_IDLE) :
    (cond_32 && cond_14 && ~cond_33 && cond_34)? ( STATE_RETRY) :
    (cond_32 && cond_14 && ~cond_33 && ~cond_34)? ( STATE_LOAD_PTE_END) :
    (cond_35 && cond_36)? ( STATE_SAVE_PDE) :
    (cond_35 && ~cond_36 && cond_37)? ( STATE_SAVE_PTE) :
    (cond_35 && ~cond_36 && ~cond_37 && cond_38)? ( STATE_WRITE_DOUBLE) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? ( STATE_WRITE_WAIT) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && ~cond_28 && cond_29)? ( STATE_READ_WAIT_START) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && ~cond_28 && ~cond_29)? ( STATE_IDLE) :
    (cond_39)? ( STATE_READ_WAIT) :
    (cond_40 && cond_12 && cond_37)? ( STATE_SAVE_PTE_START) :
    (cond_40 && cond_12 && ~cond_37 && cond_28)? ( STATE_WRITE_WAIT_START) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && cond_29)? ( STATE_READ_WAIT) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && ~cond_29)? ( STATE_IDLE) :
    (cond_41)? ( STATE_SAVE_PTE) :
    (cond_42 && cond_38)? ( STATE_WRITE_DOUBLE) :
    (cond_42 && ~cond_38)? ( STATE_WRITE_WAIT) :
    (cond_43 && cond_12 && cond_28)? ( STATE_WRITE_WAIT_START) :
    (cond_43 && cond_12 && ~cond_28 && cond_29)? ( STATE_READ_WAIT) :
    (cond_43 && cond_12 && ~cond_28 && ~cond_29)? ( STATE_IDLE) :
    state;
wire [31:0] tlb_read_pf_cr2_to_reg =
    (cond_15 && cond_17 && cond_18)? (        linear) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && ~cond_27 && ~cond_28 && cond_29)? (        linear) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && ~cond_27 && ~cond_28 && cond_29)? (        linear) :
    tlb_read_pf_cr2;
wire [31:0] tlb_code_pf_cr2_to_reg =
    (cond_22 && ~cond_23 && cond_17 && cond_18)? (       linear) :
    (cond_24 && cond_14 && cond_25 && cond_26)? (        linear) :
    (cond_32 && cond_14 && cond_33 && cond_26)? (        linear) :
    tlb_code_pf_cr2;
assign  check_pf_to_reg =
    (cond_21 && cond_17 && cond_18)? (               `TRUE) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && cond_27)? (               `TRUE) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && cond_27)? (               `TRUE) :
    check_pf;
wire  su_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && cond_4)? (             tlbwrite_cpl == 2'd3) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && cond_5)? (             `FALSE) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && cond_7)? (             tlbread_cpl == 2'd3) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && ~cond_7 && cond_8)? (             tlbcoderequest_su) :
    su;
wire [15:0] tlb_check_pf_error_code_to_reg =
    (cond_21 && cond_17 && cond_18)? ({ 13'd0, su, rw, `TRUE }) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && cond_27)? ({ 13'd0, su, rw, `FALSE }) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && cond_27)? ({ 13'd0, su, rw, dcacheread_data[0] }) :
    tlb_check_pf_error_code;
wire [15:0] tlb_write_pf_error_code_to_reg =
    (cond_19 && cond_17 && cond_18)? ( { 13'd0, su, rw, `TRUE }) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && ~cond_27 && cond_28)? ({ 13'd0, su, rw, `FALSE }) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && ~cond_27 && cond_28)? ({ 13'd0, su, rw, dcacheread_data[0] }) :
    tlb_write_pf_error_code;
wire [31:0] write_double_linear_to_reg =
    (cond_9 && cond_10)? ( linear) :
    write_double_linear;
assign tlbcode_cache_disable = 1'b0;
//wire  tlbcode_cache_disable_to_reg =
//    (cond_22 && ~cond_23 && cond_17 && ~cond_18)? (   cr0_cd || translate_pcd || memtype_cache_disable) :
//    tlbcode_cache_disable;
wire [31:0] linear_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && cond_4)? ( tlbwrite_address) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && cond_5)? ( tlbcheck_address) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && cond_7)? ( tlbread_address) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && ~cond_7 && cond_8)? ( tlbcoderequest_address) :
    (cond_9 && cond_10)? ( { linear[31:12], 12'd0 } + 32'h00001000) :
    (cond_9 && ~cond_10)? ( write_double_linear) :
    linear;
wire [15:0] tlb_code_pf_error_code_to_reg =
    (cond_22 && ~cond_23 && cond_17 && cond_18)? ({ 13'd0, su, rw, `TRUE }) :
    (cond_24 && cond_14 && cond_25 && cond_26)? ( { 13'd0, su, rw, `FALSE }) :
    (cond_32 && cond_14 && cond_33 && cond_26)? ( { 13'd0, su, rw, dcacheread_data[0] }) :
    tlb_code_pf_error_code;
//wire  tlbcode_do_to_reg =
//    (cond_0)? (    `FALSE) :
//    (cond_22 && ~cond_23 && cond_17 && ~cond_18)? ( `TRUE) :
//    tlbcode_do;
wire  wp_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && cond_4)? (             cr0_wp) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && cond_5)? (             cr0_wp) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && cond_7)? (             cr0_wp) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && ~cond_7 && cond_8)? (             cr0_wp) :
    wp;
wire  tlbcheck_done_to_reg =
    (cond_0)? ( `FALSE) :
    (cond_21 && cond_17 && ~cond_18)? ( `TRUE) :
    tlbcheck_done;
wire [31:0] tlb_write_pf_cr2_to_reg =
    (cond_19 && cond_17 && cond_18)? (        linear) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && ~cond_27 && cond_28)? (       linear) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && ~cond_27 && cond_28)? (       linear) :
    tlb_write_pf_cr2;
assign  read_ac_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && cond_6)? ( `TRUE) :
    read_ac;
wire [31:0] pte_to_reg =
    (cond_32 && cond_14)? ( dcacheread_data[31:0]) :
    pte;
wire [31:0] tlb_check_pf_cr2_to_reg =
    (cond_21 && cond_17 && cond_18)? (       linear) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && cond_27)? (       linear) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && cond_27)? (       linear) :
    tlb_check_pf_cr2;
wire [15:0] tlb_read_pf_error_code_to_reg =
    (cond_15 && cond_17 && cond_18)? ( { 13'd0, su, rw, `TRUE }) :
    (cond_24 && cond_14 && cond_25 && ~cond_26 && ~cond_27 && ~cond_28 && cond_29)? ( { 13'd0, su, rw, `FALSE }) :
    (cond_32 && cond_14 && cond_33 && ~cond_26 && ~cond_27 && ~cond_28 && cond_29)? ( { 13'd0, su, rw, dcacheread_data[0] }) :
    tlb_read_pf_error_code;
wire [1:0] write_double_state_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && cond_4)? ( (cr0_pg && tlbwrite_length != tlbwrite_length_full && { 1'b0, tlbwrite_address[11:0] } + { 10'd0, tlbwrite_length_full } >= 13'h1000)? WRITE_DOUBLE_CHECK : WRITE_DOUBLE_NONE) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && cond_5)? ( WRITE_DOUBLE_NONE) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && cond_7)? ( WRITE_DOUBLE_NONE) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && ~cond_7 && cond_8)? ( WRITE_DOUBLE_NONE) :
    (cond_9 && cond_10)? ( WRITE_DOUBLE_RESTART) :
    (cond_9 && ~cond_10)? ( WRITE_DOUBLE_NONE) :
    write_double_state;
assign  write_ac_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && cond_3)? ( `TRUE) :
    write_ac;
//wire [31:0] tlbcode_physical_to_reg =
//    (cond_22 && ~cond_23 && cond_17 && ~cond_18)? (        memtype_physical) :
//    tlbcode_physical;
assign tlbcode_physical = memtype_physical;
//wire [31:0] tlbcode_physical_to_reg =
//    (cond_22 && ~cond_23 && cond_17 && ~cond_18)? (        memtype_physical) :
//    tlbcode_physical;
wire  rw_to_reg =
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && cond_4)? (             `TRUE) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && cond_5)? (             tlbcheck_rw) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && cond_7)? (             tlbread_rmw) :
    (cond_0 && ~cond_1 && ~cond_2 && ~cond_3 && ~cond_4 && ~cond_5 && ~cond_6 && ~cond_7 && cond_8)? (             `FALSE) :
    rw;
assign  code_pf_to_reg =
    (cond_22 && ~cond_23 && cond_17 && cond_18)? (                `TRUE) :
    (cond_24 && cond_14 && cond_25 && cond_26)? (                `TRUE) :
    (cond_32 && cond_14 && cond_33 && cond_26)? (                `TRUE) :
    code_pf;
    
//======================================================== always
always @(posedge clk) begin
    if(rst_n == 1'b0) current_type <= 2'd0;
    else              current_type <= current_type_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) pde <= 32'd0;
    else              pde <= pde_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) state <= 5'd0;
    else              state <= state_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_read_pf_cr2 <= 32'd0;
    else              tlb_read_pf_cr2 <= tlb_read_pf_cr2_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_code_pf_cr2 <= 32'd0;
    else              tlb_code_pf_cr2 <= tlb_code_pf_cr2_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) su <= 1'd0;
    else              su <= su_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_check_pf_error_code <= 16'd0;
    else              tlb_check_pf_error_code <= tlb_check_pf_error_code_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_write_pf_error_code <= 16'd0;
    else              tlb_write_pf_error_code <= tlb_write_pf_error_code_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) write_double_linear <= 32'd0;
    else              write_double_linear <= write_double_linear_to_reg;
end
//always @(posedge clk) begin
//    if(rst_n == 1'b0) tlbcode_cache_disable <= 1'd0;
//    else              tlbcode_cache_disable <= tlbcode_cache_disable_to_reg;
//end
always @(posedge clk) begin
    if(rst_n == 1'b0) begin
        linear <= 32'd0;
        // linears[0] <= 32'd0;
        // linears[1] <= 32'd0;
        // linears[2] <= 32'd0;
        // linears[3] <= 32'd0;
        // linears[4] <= 32'd0;
        // linears[5] <= 32'd0;
        // linears[6] <= 32'd0;
        // linears[7] <= 32'd0;
    end
    else begin
        linear <= linear_to_reg;
        // linears[0] <= linear_to_reg;
        // linears[1] <= linear_to_reg;
        // linears[2] <= linear_to_reg;
        // linears[3] <= linear_to_reg;
        // linears[4] <= linear_to_reg;
        // linears[5] <= linear_to_reg;
        // linears[6] <= linear_to_reg;
        // linears[7] <= linear_to_reg;
    end
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_code_pf_error_code <= 16'd0;
    else              tlb_code_pf_error_code <= tlb_code_pf_error_code_to_reg;
end
//always @(posedge clk) begin
//    if(rst_n == 1'b0) tlbcode_do <= 1'd0;
//    else              tlbcode_do <= tlbcode_do_to_reg;
//end
always @(posedge clk) begin
    if(rst_n == 1'b0) wp <= 1'd0;
    else              wp <= wp_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlbcheck_done <= 1'd0;
    else              tlbcheck_done <= tlbcheck_done_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_write_pf_cr2 <= 32'd0;
    else              tlb_write_pf_cr2 <= tlb_write_pf_cr2_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) pte <= 32'd0;
    else              pte <= pte_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_check_pf_cr2 <= 32'd0;
    else              tlb_check_pf_cr2 <= tlb_check_pf_cr2_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) tlb_read_pf_error_code <= 16'd0;
    else              tlb_read_pf_error_code <= tlb_read_pf_error_code_to_reg;
end
always @(posedge clk) begin
    if(rst_n == 1'b0) write_double_state <= 2'd0;
    else              write_double_state <= write_double_state_to_reg;
end
//always @(posedge clk) begin
//    if(rst_n == 1'b0) tlbcode_physical <= 32'd0;
//    else              tlbcode_physical <= tlbcode_physical_to_reg;
//end
always @(posedge clk) begin
    if(rst_n == 1'b0) rw <= 1'd0;
    else              rw <= rw_to_reg;
end
//======================================================== sets
assign tlbregs_tlbflushall_do =
    (cond_0 && ~cond_1 && cond_2)? (`TRUE) :
    1'd0;
assign tlbregs_write_combined_rw =
    (cond_35)? (   rw_entry) :
    1'd0;
assign tlbregs_write_pcd =
    (cond_35)? (           pte[4]) :
    1'd0;
assign tlbwrite_done =
    (cond_11 && cond_12)? (`TRUE) :
    1'd0;
assign tlbread_retry =
    (cond_31)? ( current_type == TYPE_READ) :
    1'd0;
assign dcachewrite_address = memtype_physical;
assign tlbregs_write_pwt =
    (cond_35)? (           pte[3]) :
    1'd0;
assign tlbregs_write_linear = linear;
assign tlbread_done =
    (cond_13 && cond_14)? (`TRUE) :
    1'd0;
assign tlbregs_tlbflushsingle_do =
    (cond_0 && cond_1)? (`TRUE) :
    1'd0;
assign translate_do =
    (cond_15 && cond_16)? (`TRUE) :
    (cond_19 && cond_16)? (`TRUE) :
    (cond_21 && cond_16)? (`TRUE) :
    (cond_22 && cond_16)? (`TRUE) :
    1'd0;
assign tlbregs_write_physical = { pte[31:12], linear[11:0] } ;
assign tlbregs_write_do =
    (cond_35)? (`TRUE) :
    1'd0;
assign tlbflushsingle_done =
    (cond_0 && cond_1)? (`TRUE) :
    1'd0;
assign dcacheread_address = memtype_physical;
assign tlbregs_write_combined_su =
    (cond_35)? (   su_entry) :
    1'd0;

// (SiSTer: the L2 regions (ao486_l2_rgn) of memtype_physical -- and so of dcacheread_address and
//  dcachewrite_address, which are memtype_physical -- from the same condition chain, each value's regions
//  from where the value comes from: translate_physical's from tlb_regs (stored with the entry), the page-walk
//  addresses' from cr3_base, pde, pte (registers). They are there as early as the address is, and the L2
//  cache uses them instead of decoding the address at the end of the path)
wire [3:0] memtype_rgn;
wire [3:0] memtype_rgn_v1; ao486_l2_rgn memtype_rgn_v1_inst(.a({ cr3_base[31:12], linear[31:22], 2'd0 }), .f(memtype_rgn_v1));
wire [3:0] memtype_rgn_v2; ao486_l2_rgn memtype_rgn_v2_inst(.a({ pde[31:12], linear[21:12], 2'd0 }), .f(memtype_rgn_v2));
wire [3:0] memtype_rgn_v3; ao486_l2_rgn memtype_rgn_v3_inst(.a({ pde[31:12], linear[21:12], 2'b00 }), .f(memtype_rgn_v3));
wire [3:0] memtype_rgn_v4; ao486_l2_rgn memtype_rgn_v4_inst(.a({ pte[31:12], linear[11:0] }), .f(memtype_rgn_v4));
assign dcacheread_rgn  = memtype_rgn;
assign dcachewrite_rgn = memtype_rgn;


//------------------------------------------------------------------------------
// (SiSTer: the translation-dependent outputs, made by tlb_out (below) once per candidate: way 0..3 of the
//  looked-up set taken as the hit (translate_valid, _physical, _rgn, _pwt, _pcd, _combined_rw/_su, and so fault,
//  from that way's entry: tlb_regs' selected), and no hit (selected = 0, the physical address the linear one).
//  tlb_regs selects the first way that hits (its unique case, a priority mux in simulation), so taking the
//  candidate of the first hit, else the no-hit one, is the same value -- with the compare only at the last mux)
wire [3:0]  tr_linear_rgn;
ao486_l2_rgn tr_linear_rgn_inst(.a(linear), .f(tr_linear_rgn));
wire       c_dcachewrite_do [0:4];
wire [3:0] c_dcacheread_length [0:4];
wire [2:0] c_dcachewrite_length [0:4];
wire [31:0] c_dcachewrite_data [0:4];
wire       c_dcachewrite_write_through [0:4];
wire       c_dcachewrite_cache_disable [0:4];
wire       c_dcacheread_do [0:4];
wire [31:0] c_memtype_physical [0:4];
wire       c_prefetchfifo_signal_pf_do [0:4];
wire       c_dcacheread_cache_disable [0:4];
wire [3:0] c_memtype_rgn [0:4];
wire       c_tlbcode_do [0:4];
genvar tc;
generate
    for(tc = 0; tc < 5; tc = tc + 1) begin : g_tr
        wire [49:0] e        = (tc == 0)? tr_e0 : (tc == 1)? tr_e1 : (tc == 2)? tr_e2 : (tc == 3)? tr_e3 : 50'd0;
        wire        hit_any  = (tc < 4);
        wire        tv       = hit_any && (~(rw) || e[45]);
        wire [31:0] tphys    = tv ? { e[39:20], linear[11:0] } : linear;
        wire [3:0]  trgn     = tv ? e[49:46] : tr_linear_rgn;
        wire        rw_e     = (state == STATE_LOAD_PTE_END)? pde[1] & pte[1] : e[43];
        wire        su_e     = (state == STATE_LOAD_PTE_END)? pde[2] & pte[2] : e[44];
        wire        flt      = (su && ~(su_e)) || (su && su_e && ~(rw_e) && rw) || (wp && ~(su) && ~(rw_e) && rw);
        wire        c17      = ~(cr0_pg) || tv;
        wire        c18      = cr0_pg && flt;
        wire        c20      = tv && write_double_state != WRITE_DOUBLE_NONE;
        wire [43:0] cv       = { cond_43, cond_42, cond_41, cond_40, cond_39, cond_38, cond_37, cond_36, cond_35, cond_34,
                                 cond_33, cond_32, cond_31, cond_30, cond_29, cond_28, cond_27, cond_26, cond_25, cond_24,
                                 1'b0,    cond_22, cond_21, c20,     cond_19, c18,     c17,     cond_16, cond_15, cond_14,
                                 cond_13, cond_12, cond_11, cond_10, cond_9,  cond_8,  cond_7,  cond_6,  cond_5,  cond_4,
                                 cond_3,  cond_2,  cond_1,  cond_0 };
        tlb_out tlb_out_inst(
            .c(cv), .tlbread_length(tlbread_length), .tlbwrite_length(tlbwrite_length), .tlbwrite_data(tlbwrite_data),
            .pde(pde), .pte(pte), .rw(rw), .linear(linear), .cr3_base(cr3_base), .cr0_cd(cr0_cd), .cr0_nw(cr0_nw),
            .cr3_pcd(cr3_pcd), .cr3_pwt(cr3_pwt), .translate_physical(tphys), .translate_rgn(trgn),
            .translate_pcd(e[41]), .translate_pwt(e[40]),
            .memtype_rgn_v1(memtype_rgn_v1), .memtype_rgn_v2(memtype_rgn_v2), .memtype_rgn_v3(memtype_rgn_v3), .memtype_rgn_v4(memtype_rgn_v4),
            .dcachewrite_do(c_dcachewrite_do[tc]),
            .dcacheread_length(c_dcacheread_length[tc]),
            .dcachewrite_length(c_dcachewrite_length[tc]),
            .dcachewrite_data(c_dcachewrite_data[tc]),
            .dcachewrite_write_through(c_dcachewrite_write_through[tc]),
            .dcachewrite_cache_disable(c_dcachewrite_cache_disable[tc]),
            .dcacheread_do(c_dcacheread_do[tc]),
            .memtype_physical(c_memtype_physical[tc]),
            .prefetchfifo_signal_pf_do(c_prefetchfifo_signal_pf_do[tc]),
            .dcacheread_cache_disable(c_dcacheread_cache_disable[tc]),
            .memtype_rgn(c_memtype_rgn[tc]),
            .tlbcode_do(c_tlbcode_do[tc])
        );
    end
endgenerate
// (SiSTer: and cond_23 (pr_reset || pr_reset_waiting, late from the write stage) is taken last too: the candidates
//  are made with it low, and with it high only cond_22 && cond_23 changes anything -- in STATE_CODE_CHECK every term
//  of these outputs then fails (the other terms need another state), so each is its final else, written here;
//  cond_26, which also reads pr_reset, is left as it is in the candidates)
wire tr_c22_23 = cond_22 && cond_23;
assign dcachewrite_do = tr_c22_23? 1'b0 : tr_hit[0]? c_dcachewrite_do[0] : tr_hit[1]? c_dcachewrite_do[1] : tr_hit[2]? c_dcachewrite_do[2] : tr_hit[3]? c_dcachewrite_do[3] : c_dcachewrite_do[4];
assign dcacheread_length = tr_c22_23? 4'd0 : tr_hit[0]? c_dcacheread_length[0] : tr_hit[1]? c_dcacheread_length[1] : tr_hit[2]? c_dcacheread_length[2] : tr_hit[3]? c_dcacheread_length[3] : c_dcacheread_length[4];
assign dcachewrite_length = tr_c22_23? 3'd0 : tr_hit[0]? c_dcachewrite_length[0] : tr_hit[1]? c_dcachewrite_length[1] : tr_hit[2]? c_dcachewrite_length[2] : tr_hit[3]? c_dcachewrite_length[3] : c_dcachewrite_length[4];
// (SiSTer: dcachewrite_data is not taken from the candidates: its first term (cond_19 && cond_17 && ~cond_18 &&
//  ~cond_20, in STATE_WRITE_CHECK) gives tlbwrite_data, and in STATE_WRITE_CHECK every later term fails (they need
//  STATE_LOAD_PTE_END, STATE_SAVE_PTE_START or STATE_WRITE_WAIT_START) and the else is tlbwrite_data too -- so
//  without that term it is the same value, and the translation does not reach it)
assign dcachewrite_data =
    (cond_35 && cond_36)? (            pde | 32'h00000020) :
    (cond_35 && ~cond_36 && cond_37)? (            pte[31:0] | 32'h00000020 | ((pte[6] == `FALSE && rw)? 32'h00000040 : 32'h00000000)) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? (            tlbwrite_data) :
    (cond_41)? (            pte[31:0] | 32'h00000020 | ((pte[6] == `FALSE && rw)? 32'h00000040 : 32'h00000000)) :
    tlbwrite_data; // (cond_42 && ~cond_38)
assign dcachewrite_write_through = tr_c22_23? 1'b0 : tr_hit[0]? c_dcachewrite_write_through[0] : tr_hit[1]? c_dcachewrite_write_through[1] : tr_hit[2]? c_dcachewrite_write_through[2] : tr_hit[3]? c_dcachewrite_write_through[3] : c_dcachewrite_write_through[4];
assign dcachewrite_cache_disable = tr_c22_23? 1'b0 : tr_hit[0]? c_dcachewrite_cache_disable[0] : tr_hit[1]? c_dcachewrite_cache_disable[1] : tr_hit[2]? c_dcachewrite_cache_disable[2] : tr_hit[3]? c_dcachewrite_cache_disable[3] : c_dcachewrite_cache_disable[4];
assign dcacheread_do = tr_c22_23? 1'b0 : tr_hit[0]? c_dcacheread_do[0] : tr_hit[1]? c_dcacheread_do[1] : tr_hit[2]? c_dcacheread_do[2] : tr_hit[3]? c_dcacheread_do[3] : c_dcacheread_do[4];
assign memtype_physical = tr_c22_23? { pte[31:12], linear[11:0] } : tr_hit[0]? c_memtype_physical[0] : tr_hit[1]? c_memtype_physical[1] : tr_hit[2]? c_memtype_physical[2] : tr_hit[3]? c_memtype_physical[3] : c_memtype_physical[4];
assign prefetchfifo_signal_pf_do = tr_c22_23? 1'b0 : tr_hit[0]? c_prefetchfifo_signal_pf_do[0] : tr_hit[1]? c_prefetchfifo_signal_pf_do[1] : tr_hit[2]? c_prefetchfifo_signal_pf_do[2] : tr_hit[3]? c_prefetchfifo_signal_pf_do[3] : c_prefetchfifo_signal_pf_do[4];
assign dcacheread_cache_disable = tr_c22_23? 1'b0 : tr_hit[0]? c_dcacheread_cache_disable[0] : tr_hit[1]? c_dcacheread_cache_disable[1] : tr_hit[2]? c_dcacheread_cache_disable[2] : tr_hit[3]? c_dcacheread_cache_disable[3] : c_dcacheread_cache_disable[4];
assign memtype_rgn = tr_c22_23? memtype_rgn_v4 : tr_hit[0]? c_memtype_rgn[0] : tr_hit[1]? c_memtype_rgn[1] : tr_hit[2]? c_memtype_rgn[2] : tr_hit[3]? c_memtype_rgn[3] : c_memtype_rgn[4];
assign tlbcode_do = tr_c22_23? 1'b0 : tr_hit[0]? c_tlbcode_do[0] : tr_hit[1]? c_tlbcode_do[1] : tr_hit[2]? c_tlbcode_do[2] : tr_hit[3]? c_tlbcode_do[3] : c_tlbcode_do[4];

endmodule

//------------------------------------------------------------------------------
// (SiSTer: the outputs of tlb.v that depend on the translation (cond_17 = ~cr0_pg || translate_valid,
//  cond_18 = cr0_pg && fault, cond_20 = translate_valid && write_double_state != NONE, translate_*), exactly the
//  original assigns, for one candidate translation. tlb.v makes one per TLB way of the looked-up set (as if that
//  way were the first that hit) and one for no hit, and the way hits pick at the end -- so the hit compare meets
//  only the last mux instead of the whole chain of selects behind translate_valid)
module tlb_out(
    input       [43:0]  c,              // cond_0 .. cond_43 of tlb.v (17, 18, 20 for this candidate)
    input       [3:0]   tlbread_length,
    input       [2:0]   tlbwrite_length,
    input       [31:0]  tlbwrite_data,
    input       [31:0]  pde,
    input       [31:0]  pte,
    input               rw,
    input       [31:0]  linear,
    input       [31:0]  cr3_base,
    input               cr0_cd,
    input               cr0_nw,
    input               cr3_pcd,
    input               cr3_pwt,
    input       [31:0]  translate_physical,
    input       [3:0]   translate_rgn,
    input               translate_pcd,
    input               translate_pwt,
    input       [3:0]   memtype_rgn_v1,
    input       [3:0]   memtype_rgn_v2,
    input       [3:0]   memtype_rgn_v3,
    input       [3:0]   memtype_rgn_v4,
    output              dcachewrite_do,
    output      [3:0]   dcacheread_length,
    output      [2:0]   dcachewrite_length,
    output      [31:0]  dcachewrite_data,
    output              dcachewrite_write_through,
    output              dcachewrite_cache_disable,
    output              dcacheread_do,
    output      [31:0]  memtype_physical,
    output              prefetchfifo_signal_pf_do,
    output              dcacheread_cache_disable,
    output      [3:0]   memtype_rgn,
    output              tlbcode_do
);

wire cond_0 = c[0];
wire cond_1 = c[1];
wire cond_2 = c[2];
wire cond_3 = c[3];
wire cond_4 = c[4];
wire cond_5 = c[5];
wire cond_6 = c[6];
wire cond_7 = c[7];
wire cond_8 = c[8];
wire cond_9 = c[9];
wire cond_10 = c[10];
wire cond_11 = c[11];
wire cond_12 = c[12];
wire cond_13 = c[13];
wire cond_14 = c[14];
wire cond_15 = c[15];
wire cond_16 = c[16];
wire cond_17 = c[17];
wire cond_18 = c[18];
wire cond_19 = c[19];
wire cond_20 = c[20];
wire cond_21 = c[21];
wire cond_22 = c[22];
wire cond_23 = c[23];
wire cond_24 = c[24];
wire cond_25 = c[25];
wire cond_26 = c[26];
wire cond_27 = c[27];
wire cond_28 = c[28];
wire cond_29 = c[29];
wire cond_30 = c[30];
wire cond_31 = c[31];
wire cond_32 = c[32];
wire cond_33 = c[33];
wire cond_34 = c[34];
wire cond_35 = c[35];
wire cond_36 = c[36];
wire cond_37 = c[37];
wire cond_38 = c[38];
wire cond_39 = c[39];
wire cond_40 = c[40];
wire cond_41 = c[41];
wire cond_42 = c[42];
wire cond_43 = c[43];
localparam [1:0] TYPE_CODE  = 2'd0;
localparam [1:0] TYPE_CHECK = 2'd1;
localparam [1:0] TYPE_WRITE = 2'd2;
localparam [1:0] TYPE_READ  = 2'd3;
wire memtype_cache_disable;
wire memtype_write_transparent;
tlb_memtype tlb_memtype_inst(.physical(memtype_physical), .cache_disable(memtype_cache_disable), .write_transparent(memtype_write_transparent));
assign dcachewrite_do =
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? (`TRUE) :
    (cond_35 && cond_36)? (`TRUE) :
    (cond_35 && ~cond_36 && cond_37)? (`TRUE) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? (`TRUE) :
    (cond_41)? (`TRUE) :
    (cond_42 && ~cond_38)? (`TRUE) :
    1'd0;
assign dcacheread_length =
    (cond_15 && cond_17 && ~cond_18)? (           tlbread_length) :
    (cond_15 && ~cond_17)? (           4'd4) :
    (cond_19 && ~cond_17)? (           4'd4) :
    (cond_21 && ~cond_17)? (           4'd4) :
    (cond_22 && ~cond_23 && ~cond_17)? (           4'd4) :
    (cond_30)? (           4'd4) :
    (cond_39)? (           tlbread_length) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && cond_29)? (           tlbread_length) :
    (cond_43 && cond_12 && ~cond_28 && cond_29)? (           tlbread_length) :
    4'd0;
assign dcachewrite_length =
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? (          tlbwrite_length) :
    (cond_35 && cond_36)? (          3'd4) :
    (cond_35 && ~cond_36 && cond_37)? (          3'd4) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? (          tlbwrite_length) :
    (cond_41)? (          3'd4) :
    (cond_42 && ~cond_38)? (          tlbwrite_length) :
    3'd0;
assign dcachewrite_data =
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? (            tlbwrite_data) :
    (cond_35 && cond_36)? (            pde | 32'h00000020) :
    (cond_35 && ~cond_36 && cond_37)? (            pte[31:0] | 32'h00000020 | ((pte[6] == `FALSE && rw)? 32'h00000040 : 32'h00000000)) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? (            tlbwrite_data) :
    (cond_41)? (            pte[31:0] | 32'h00000020 | ((pte[6] == `FALSE && rw)? 32'h00000040 : 32'h00000000)) :
    tlbwrite_data; // (cond_42 && ~cond_38)
assign dcachewrite_write_through =
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? (   cr0_nw || translate_pwt || memtype_write_transparent) :
    (cond_35 && cond_36)? (   cr0_nw || cr3_pwt || memtype_write_transparent) :
    (cond_35 && ~cond_36 && cond_37)? (   cr0_nw || pde[3] || memtype_write_transparent) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? (   cr0_nw || pte[3] || memtype_write_transparent) :
    (cond_41)? (   cr0_nw || pde[3] || memtype_write_transparent) :
    (cond_42 && ~cond_38)? (   cr0_nw || pte[3] || memtype_write_transparent) :
    1'd0;
assign dcachewrite_cache_disable =
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? (   cr0_cd || translate_pcd || memtype_cache_disable) :
    (cond_35 && cond_36)? (   cr0_cd || cr3_pcd || memtype_cache_disable) :
    (cond_35 && ~cond_36 && cond_37)? (   cr0_cd || pde[4] || memtype_cache_disable) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? (   cr0_cd || pte[4] || memtype_cache_disable) :
    (cond_41)? (   cr0_cd || pde[4] || memtype_cache_disable) :
    (cond_42 && ~cond_38)? (   cr0_cd || pte[4] || memtype_cache_disable) :
    1'd0;
assign dcacheread_do =
    (cond_15 && cond_17 && ~cond_18)? (`TRUE) :
    (cond_15 && ~cond_17)? (`TRUE) :
    (cond_19 && ~cond_17)? (`TRUE) :
    (cond_21 && ~cond_17)? (`TRUE) :
    (cond_22 && ~cond_23 && ~cond_17)? (`TRUE) :
    (cond_30)? (`TRUE) :
    (cond_39)? (`TRUE) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && cond_29)? (`TRUE) :
    (cond_43 && cond_12 && ~cond_28 && cond_29)? (`TRUE) :
    1'd0;
assign memtype_physical =
    (cond_15 && cond_17 && ~cond_18)? ( translate_physical) :
    (cond_15 && ~cond_17)? ( { cr3_base[31:12], linear[31:22], 2'd0 }) :
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? ( translate_physical) :
    (cond_19 && ~cond_17)? ( { cr3_base[31:12], linear[31:22], 2'd0 }) :
    (cond_21 && ~cond_17)? ( { cr3_base[31:12], linear[31:22], 2'd0 }) :
    (cond_22 && ~cond_23 && cond_17 && ~cond_18)? ( translate_physical) :
    (cond_22 && ~cond_23 && ~cond_17)? ( { cr3_base[31:12], linear[31:22], 2'd0 }) :
    (cond_30)? ( { pde[31:12], linear[21:12], 2'd0 }) :
    (cond_35 && cond_36)? ( { cr3_base[31:12], linear[31:22], 2'd0 }) :
    (cond_35 && ~cond_36 && cond_37)? ( { pde[31:12], linear[21:12], 2'b00 }) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? ( { pte[31:12], linear[11:0] }) :
    (cond_39)? ( { pte[31:12], linear[11:0] }) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && cond_29)? ( { pte[31:12], linear[11:0] }) :
    (cond_41)? ( { pde[31:12], linear[21:12], 2'b00 }) :
    (cond_42 && ~cond_38)? ( { pte[31:12], linear[11:0] }) :
    { pte[31:12], linear[11:0] }; // (cond_43 && cond_12 && ~cond_28 && cond_29)
assign prefetchfifo_signal_pf_do =
    (cond_22 && ~cond_23 && cond_17 && cond_18)? (`TRUE) :
    (cond_24 && cond_14 && cond_25 && cond_26)? (`TRUE) :
    (cond_32 && cond_14 && cond_33 && cond_26)? (`TRUE) :
    1'd0;
assign dcacheread_cache_disable =
    (cond_15 && cond_17 && ~cond_18)? (    cr0_cd || translate_pcd || memtype_cache_disable) :
    (cond_15 && ~cond_17)? (    cr0_cd || cr3_pcd || memtype_cache_disable) :
    (cond_19 && ~cond_17)? (    cr0_cd || cr3_pcd || memtype_cache_disable) :
    (cond_21 && ~cond_17)? (    cr0_cd || cr3_pcd || memtype_cache_disable) :
    (cond_22 && ~cond_23 && ~cond_17)? (    cr0_cd || cr3_pcd || memtype_cache_disable) :
    (cond_30)? (    cr0_cd || pde[4] || memtype_cache_disable) :
    (cond_39)? (    cr0_cd || pte[4] || memtype_cache_disable) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && cond_29)? (    cr0_cd || pte[4] || memtype_cache_disable) :
    (cond_43 && cond_12 && ~cond_28 && cond_29)? (    cr0_cd || pte[4] || memtype_cache_disable) :
    1'd0;

//------------------------------------------------------------------------------
assign memtype_rgn =
    (cond_15 && cond_17 && ~cond_18)? ( translate_rgn) :
    (cond_15 && ~cond_17)? ( memtype_rgn_v1) :
    (cond_19 && cond_17 && ~cond_18 && ~cond_20)? ( translate_rgn) :
    (cond_19 && ~cond_17)? ( memtype_rgn_v1) :
    (cond_21 && ~cond_17)? ( memtype_rgn_v1) :
    (cond_22 && ~cond_23 && cond_17 && ~cond_18)? ( translate_rgn) :
    (cond_22 && ~cond_23 && ~cond_17)? ( memtype_rgn_v1) :
    (cond_30)? ( memtype_rgn_v2) :
    (cond_35 && cond_36)? ( memtype_rgn_v1) :
    (cond_35 && ~cond_36 && cond_37)? ( memtype_rgn_v3) :
    (cond_35 && ~cond_36 && ~cond_37 && ~cond_38 && cond_28)? ( memtype_rgn_v4) :
    (cond_39)? ( memtype_rgn_v4) :
    (cond_40 && cond_12 && ~cond_37 && ~cond_28 && cond_29)? ( memtype_rgn_v4) :
    (cond_41)? ( memtype_rgn_v3) :
    (cond_42 && ~cond_38)? ( memtype_rgn_v4) :
    memtype_rgn_v4;
assign tlbcode_do = (cond_22 && ~cond_23 && cond_17 && ~cond_18)? ( `TRUE) : `FALSE;

endmodule
