// ============================================================
// Module      : ooo_top
// Project     : Out-of-Order Issue Queue - Tesla AI Hardware Portfolio
// Author      : Mayank
// Description : Top-level out-of-order execution engine integrating the RAT,
//               RS, ROB, ALU, and CDB.  Implements single-issue dispatch with
//               stall on RS-full or ROB-full.  In-order commit via ROB head.
//
// Fix #1 — RAT deadlock:
//   ROB now exposes two combinational tag-lookup ports (lk1/lk2).  These are
//   wired to the RAT so it can see whether a source register's current rename
//   tag is already complete in the ROB, even after the CDB broadcast cycle has
//   passed but before commit fires.
//
// Fix #2 — multi-FU CDB interface:
//   CDB now has fu1_* ports and a round-robin arbiter (fu1 tied to 0 here;
//   LSU plugs in later).  fu0_grant feeds back into the ALU's cdb_req_grant
//   input and drives fu_ready to the RS — the RS won't issue another
//   instruction if the ALU's output stage is backed up waiting for the bus.
//
// Fix #3 — ROB fault bit / conditional commit_ack:
//   commit_ack is no longer an unconditional pass-through of commit_valid.
//   If the ROB head faulted (commit_fault=1), commit_ack stays low, stalling
//   the ROB head until an external flush clears the pipeline.  A new top-level
//   output commit_fault lets the surrounding CPU core trigger the trap handler.
//   alloc_fault is hardwired to 0 until a fault source exists.
//
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
    output wire           commit_fault, // [Fix #3] Head instruction faulted

    // Status
    output wire           rs_full,      // RS backpressure indicator
    output wire           rob_full,     // ROB backpressure indicator
    output wire           pipeline_busy // Any instructions in flight
);

// ---- Instruction decode --------------------------------------------
wire [AW-1:0]  dec_rd     = instr[`RD_HI  :`RD_LO ];
wire [AW-1:0]  dec_rs1    = instr[`RS1_HI :`RS1_LO];
wire [AW-1:0]  dec_rs2    = instr[`RS2_HI :`RS2_LO];
wire [2:0]     dec_opcode = instr[`OP_HI  :`OP_LO ];

// ---- Dispatch enable -----------------------------------------------
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
wire          commit_fault_i; // [Fix #3]

// [Fix #3] Only auto-ack a non-faulting commit.
// A faulting head stalls here until an external flush resolves it.
wire commit_ack = commit_valid_i && !commit_fault_i;

assign commit_valid = commit_valid_i;
assign commit_rd    = commit_rd_i;
assign commit_data  = commit_data_i;
assign commit_tag   = commit_tag_i;
assign commit_fault = commit_fault_i;

// ---- [Fix #1] ROB tag-lookup wires for RAT readiness ---------------
wire         rob_lk1_complete, rob_lk2_complete;
wire [DW-1:0] rob_lk1_data,    rob_lk2_data;

// ---- ALU issue wires -----------------------------------------------
wire         issue_valid_w;
wire [2:0]   issue_opcode_w;
wire [DW-1:0] issue_src1_w, issue_src2_w;
wire [TW-1:0] issue_tag_w;

// ---- ALU CDB request -----------------------------------------------
wire         cdb_req_valid;
wire [TW-1:0] cdb_req_tag;
wire [DW-1:0] cdb_req_data;

// ---- [Fix #2] CDB arbiter grant for fu0 (the ALU) ------------------
wire fu0_grant_w;

// fu_ready: RS should not issue if the ALU output stage is stalled.
// With NUM_FU=1: fu0_grant = cdb_req_valid always, so this is always 1
// (identical to the original 1'b1 tie).
wire alu_fu_ready = !cdb_req_valid || fu0_grant_w;

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
    .clk              (clk),
    .rst_n            (rst_n),
    .flush            (flush),
    // Dispatch read
    .rs1_addr         (dec_rs1),
    .rs2_addr         (dec_rs2),
    .rs1_ready        (rat_rs1_ready),
    .rs1_data         (rat_rs1_data),
    .rs1_tag          (rat_rs1_tag),
    .rs2_ready        (rat_rs2_ready),
    .rs2_data         (rat_rs2_data),
    .rs2_tag          (rat_rs2_tag),
    // Rename
    .rename_valid     (dispatch_en),
    .rename_rd        (dec_rd),
    .rename_tag       (alloc_tag),
    // Commit
    .commit_valid     (commit_valid_i),
    .commit_rd        (commit_rd_i),
    .commit_data      (commit_data_i),
    .commit_tag       (commit_tag_i),
    // CDB snoop
    .cdb_valid        (cdb_valid),
    .cdb_tag          (cdb_tag),
    .cdb_data         (cdb_data),
    // [Fix #1] ROB lookup for post-CDB, pre-commit readiness
    .rob_rs1_complete (rob_lk1_complete),
    .rob_rs1_data     (rob_lk1_data),
    .rob_rs2_complete (rob_lk2_complete),
    .rob_rs2_data     (rob_lk2_data)
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
    // Issue: [Fix #2] fu_ready now tracks ALU backpressure
    .fu_ready         (alu_fu_ready),
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
    .alloc_fault    (1'b0),         // [Fix #3] No fault source yet; LSU/branch will drive
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
    .commit_fault   (commit_fault_i), // [Fix #3]
    .commit_ack     (commit_ack),
    .rob_empty      (rob_empty_w),
    // [Fix #1] Tag-lookup ports for RAT readiness
    .lk1_tag        (rat_rs1_tag),
    .lk1_complete   (rob_lk1_complete),
    .lk1_data       (rob_lk1_data),
    .lk2_tag        (rat_rs2_tag),
    .lk2_complete   (rob_lk2_complete),
    .lk2_data       (rob_lk2_data)
);

// ---- Integer ALU --------------------------------------------------
integer_alu #(
    .DW(DW), .TW(TW)
) u_alu (
    .clk           (clk),
    .rst_n         (rst_n),
    .flush         (flush),
    .issue_valid   (issue_valid_w),
    .issue_opcode  (issue_opcode_w),
    .issue_src1    (issue_src1_w),
    .issue_src2    (issue_src2_w),
    .issue_tag     (issue_tag_w),
    .cdb_req_valid (cdb_req_valid),
    .cdb_req_tag   (cdb_req_tag),
    .cdb_req_data  (cdb_req_data),
    .cdb_req_grant (fu0_grant_w)    // [Fix #2] backpressure from CDB arbiter
);

// ---- Common Data Bus ----------------------------------------------
common_data_bus #(
    .DW(DW), .TW(TW), .NUM_FU(`NUM_FU)
) u_cdb (
    .clk       (clk),             // [Fix #2] needed for round-robin state
    .rst_n     (rst_n),
    // FU-0: integer ALU
    .fu0_valid (cdb_req_valid),
    .fu0_tag   (cdb_req_tag),
    .fu0_data  (cdb_req_data),
    .fu0_grant (fu0_grant_w),     // [Fix #2] grant feedback to ALU
    // FU-1: reserved for LSU (tied off until LSU is built)
    .fu1_valid (1'b0),
    .fu1_tag   ({TW{1'b0}}),
    .fu1_data  ({DW{1'b0}}),
    .fu1_grant (),                // unconnected: LSU will use this
    // Broadcast
    .cdb_valid (cdb_valid),
    .cdb_tag   (cdb_tag),
    .cdb_data  (cdb_data)
);

endmodule
