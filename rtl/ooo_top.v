// ============================================================
// Module      : ooo_top
// Project     : Out-of-Order Issue Queue - Tesla AI Hardware Portfolio
// Author      : Mayank
// Description : Top-level out-of-order execution engine integrating the RAT,
//               RS, ROB, ALU, and CDB.  Implements single-issue dispatch with
//               stall on RS-full or ROB-full.  In-order commit via ROB head.
// Parameters  : RS_DEPTH=8, ROB_DEPTH=16, NUM_REGS=32, DATA_WIDTH=32
// ============================================================

`include "defines.vh"

module ooo_top #(
    parameter RS_DEPTH  = `RS_DEPTH,   // Reservation station entries
    parameter ROB_DEPTH = `ROB_DEPTH,  // Reorder buffer entries
    parameter NR        = `NUM_REGS,   // Architectural registers
    parameter DW        = `DATA_WIDTH, // Data width
    parameter TW        = `TAG_WIDTH,  // ROB tag width
    parameter AW        = `REG_ADDR_W  // Register address width
)(
    input  wire           clk,          // System clock
    input  wire           rst_n,        // Active-low synchronous reset
    input  wire           flush,        // External flush (e.g. branch mispredict)

    // Instruction fetch interface (one instruction per cycle)
    input  wire           instr_valid,  // Instruction available from fetch
    input  wire [31:0]    instr,        // Encoded instruction word
    output wire           instr_ready,  // Engine can accept an instruction

    // Commit visibility (for testbench checking / external observe)
    output wire           commit_valid, // A result is being committed this cycle
    output wire [AW-1:0]  commit_rd,    // Architectural register being written
    output wire [DW-1:0]  commit_data,  // Committed value
    output wire [TW-1:0]  commit_tag,   // ROB tag being retired

    // Status
    output wire           rs_full,      // RS backpressure indicator
    output wire           rob_full,     // ROB backpressure indicator
    output wire           pipeline_busy // Any instructions in flight
);

// ---- Instruction decode --------------------------------------------
// Encoding: [31:27]=rd  [26:22]=rs1  [21:17]=rs2  [16:14]=opcode  [13:0]=imm
wire [AW-1:0]  dec_rd     = instr[`RD_HI  :`RD_LO ];
wire [AW-1:0]  dec_rs1    = instr[`RS1_HI :`RS1_LO];
wire [AW-1:0]  dec_rs2    = instr[`RS2_HI :`RS2_LO];
wire [2:0]     dec_opcode = instr[`OP_HI  :`OP_LO ];

// ---- Dispatch enable -----------------------------------------------
// Single-cycle dispatch when instruction available and engine not stalled
wire dispatch_en = instr_valid && !rs_full && !rob_full;
assign instr_ready = !rs_full && !rob_full;

// ---- CDB wires (broadcast across RS, RAT, ROB) --------------------
wire        cdb_valid;
wire [TW-1:0] cdb_tag;
wire [DW-1:0] cdb_data;

// ---- RAT outputs at dispatch time ----------------------------------
wire         rat_rs1_ready, rat_rs2_ready;
wire [DW-1:0] rat_rs1_data,  rat_rs2_data;
wire [TW-1:0] rat_rs1_tag,   rat_rs2_tag;

// ---- ROB allocation tag (combinational: current tail) -------------
wire [TW-1:0] alloc_tag;

// ---- Commit wires from ROB -----------------------------------------
wire         commit_valid_i;
wire [AW-1:0] commit_rd_i;
wire [DW-1:0] commit_data_i;
wire [TW-1:0] commit_tag_i;

// Auto-acknowledge every commit (RAT always accepts)
wire commit_ack = commit_valid_i;

assign commit_valid = commit_valid_i;
assign commit_rd    = commit_rd_i;
assign commit_data  = commit_data_i;
assign commit_tag   = commit_tag_i;

// ---- ALU issue wires -----------------------------------------------
wire         issue_valid_w;
wire [2:0]   issue_opcode_w;
wire [DW-1:0] issue_src1_w, issue_src2_w;
wire [TW-1:0] issue_tag_w;

// ---- ALU CDB request -----------------------------------------------
wire         cdb_req_valid;
wire [TW-1:0] cdb_req_tag;
wire [DW-1:0] cdb_req_data;

// ---- Status --------------------------------------------------------
wire rs_empty;
wire rob_empty_w;
assign pipeline_busy = !rs_empty || !rob_empty_w;

// ============================================================
// Module instantiations
// ============================================================

// ---- Register Alias Table -----------------------------------------
register_alias_table #(
    .DW(DW), .TW(TW), .AW(AW), .NR(NR)
) u_rat (
    .clk          (clk),
    .rst_n        (rst_n),
    .flush        (flush),
    // Dispatch read
    .rs1_addr     (dec_rs1),
    .rs2_addr     (dec_rs2),
    .rs1_ready    (rat_rs1_ready),
    .rs1_data     (rat_rs1_data),
    .rs1_tag      (rat_rs1_tag),
    .rs2_ready    (rat_rs2_ready),
    .rs2_data     (rat_rs2_data),
    .rs2_tag      (rat_rs2_tag),
    // Rename
    .rename_valid (dispatch_en),
    .rename_rd    (dec_rd),
    .rename_tag   (alloc_tag),
    // Commit
    .commit_valid (commit_valid_i),
    .commit_rd    (commit_rd_i),
    .commit_data  (commit_data_i),
    .commit_tag   (commit_tag_i),
    // CDB snoop
    .cdb_valid    (cdb_valid),
    .cdb_tag      (cdb_tag),
    .cdb_data     (cdb_data)
);

// ---- Reservation Station ------------------------------------------
reservation_station #(
    .RS_DEPTH(RS_DEPTH), .DW(DW), .TW(TW), .AW(AW)
) u_rs (
    .clk              (clk),
    .rst_n            (rst_n),
    .flush            (flush),
    // Dispatch
    .dispatch_valid   (dispatch_en),
    .dispatch_opcode  (dec_opcode),
    .dispatch_rs1     (dec_rs1),
    .dispatch_rs2     (dec_rs2),
    .dispatch_rd      (dec_rd),
    .dispatch_s1_rdy  (rat_rs1_ready),
    .dispatch_s1_data (rat_rs1_data),
    .dispatch_s1_tag  (rat_rs1_tag),
    .dispatch_s2_rdy  (rat_rs2_ready),
    .dispatch_s2_data (rat_rs2_data),
    .dispatch_s2_tag  (rat_rs2_tag),
    .dispatch_dest_tag(alloc_tag),
    // Issue
    .fu_ready         (1'b1),         // Single ALU always ready after clearing
    .issue_valid      (issue_valid_w),
    .issue_opcode     (issue_opcode_w),
    .issue_src1       (issue_src1_w),
    .issue_src2       (issue_src2_w),
    .issue_tag        (issue_tag_w),
    // CDB snoop
    .cdb_valid        (cdb_valid),
    .cdb_tag          (cdb_tag),
    .cdb_data         (cdb_data),
    // Status
    .rs_full          (rs_full),
    .rs_empty         (rs_empty)
);

// ---- Reorder Buffer -----------------------------------------------
reorder_buffer #(
    .DEPTH(ROB_DEPTH), .DW(DW), .TW(TW), .AW(AW)
) u_rob (
    .clk            (clk),
    .rst_n          (rst_n),
    .flush          (flush),
    // Allocation
    .alloc_valid    (dispatch_en),
    .alloc_rd       (dec_rd),
    .alloc_opcode   (dec_opcode),
    .alloc_tag      (alloc_tag),
    .rob_full       (rob_full),
    // Completion from CDB
    .complete_valid (cdb_valid),
    .complete_tag   (cdb_tag),
    .complete_data  (cdb_data),
    // Commit
    .commit_valid   (commit_valid_i),
    .commit_rd      (commit_rd_i),
    .commit_data    (commit_data_i),
    .commit_tag     (commit_tag_i),
    .commit_ack     (commit_ack),
    .rob_empty      (rob_empty_w)
);

// ---- Integer ALU --------------------------------------------------
integer_alu #(
    .DW(DW), .TW(TW)
) u_alu (
    .clk          (clk),
    .rst_n        (rst_n),
    .flush        (flush),
    .issue_valid  (issue_valid_w),
    .issue_opcode (issue_opcode_w),
    .issue_src1   (issue_src1_w),
    .issue_src2   (issue_src2_w),
    .issue_tag    (issue_tag_w),
    .cdb_req_valid(cdb_req_valid),
    .cdb_req_tag  (cdb_req_tag),
    .cdb_req_data (cdb_req_data)
);

// ---- Common Data Bus ---------------------------------------------
common_data_bus #(
    .DW(DW), .TW(TW), .NUM_FU(1)
) u_cdb (
    .fu0_valid (cdb_req_valid),
    .fu0_tag   (cdb_req_tag),
    .fu0_data  (cdb_req_data),
    .cdb_valid (cdb_valid),
    .cdb_tag   (cdb_tag),
    .cdb_data  (cdb_data)
);

endmodule
