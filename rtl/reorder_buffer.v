// ============================================================
// Module      : reorder_buffer
// Project     : Out-of-Order Issue Queue - Tesla AI Hardware Portfolio
// Author      : Mayank
// Description : Circular ROB for in-order commit of out-of-order results.
//               Head commits only when the oldest entry is marked complete.
//               alloc_tag (= tail) is the rename tag handed to the RS/RAT.
// Parameters  : DEPTH=16, DW=32, TW=4, AW=5, OW=3
// ============================================================

`include "defines.vh"

module reorder_buffer #(
    parameter DEPTH = `ROB_DEPTH,   // ROB capacity (power of 2)
    parameter DW    = `DATA_WIDTH,  // Data width
    parameter TW    = `TAG_WIDTH,   // Tag / pointer width = log2(DEPTH)
    parameter AW    = `REG_ADDR_W,  // Architectural register address width
    parameter OW    = 3             // Opcode width
)(
    input  wire           clk,          // System clock
    input  wire           rst_n,        // Active-low synchronous reset
    input  wire           flush,        // Flush: drain entire ROB

    // Allocation port (from ooo_top at dispatch)
    input  wire           alloc_valid,  // Dispatch is allocating a ROB slot
    input  wire [AW-1:0]  alloc_rd,     // Destination architectural register
    input  wire [OW-1:0]  alloc_opcode, // Opcode (for later extension: store/branch)
    output wire [TW-1:0]  alloc_tag,    // Assigned ROB tag (= current tail index)
    output wire           rob_full,     // ROB cannot accept a new entry

    // Completion port (from CDB - marks an in-flight entry as done)
    input  wire           complete_valid, // A result is ready to be written
    input  wire [TW-1:0]  complete_tag,   // ROB slot receiving the result
    input  wire [DW-1:0]  complete_data,  // Result value

    // Commit port (to RAT and external observe)
    output wire           commit_valid, // Head entry is complete; committing now
    output wire [AW-1:0]  commit_rd,    // Architectural register to update
    output wire [DW-1:0]  commit_data,  // Value to write into the register file
    output wire [TW-1:0]  commit_tag,   // ROB tag being retired (WAW guard for RAT)
    input  wire           commit_ack,   // Commit acknowledged; advance head

    output wire           rob_empty     // ROB has no allocated entries
);

// ---- Per-entry storage arrays --------------------------------------
reg          rob_entry_valid    [0:DEPTH-1]; // Slot is allocated
reg          rob_entry_complete [0:DEPTH-1]; // Result has been written
reg [AW-1:0] rob_entry_rd      [0:DEPTH-1]; // Destination arch register
reg [OW-1:0] rob_entry_opcode  [0:DEPTH-1]; // Opcode
reg [DW-1:0] rob_entry_data    [0:DEPTH-1]; // Result data

// ---- Head and tail pointers ----------------------------------------
reg [TW-1:0] rob_head; // Index of oldest allocated (not yet committed) entry
reg [TW-1:0] rob_tail; // Index of next slot to allocate

// ---- Combinational status signals ----------------------------------
// Full: allocating would make tail reach head (one slot wasted, standard)
assign rob_full  = rob_entry_valid[rob_tail];
assign rob_empty = !rob_entry_valid[rob_head];

// Allocation tag is the CURRENT tail (before incrementing)
assign alloc_tag = rob_tail;

// ---- Commit: head entry is valid AND complete ----------------------
assign commit_valid = rob_entry_valid[rob_head] && rob_entry_complete[rob_head];
assign commit_rd    = rob_entry_rd  [rob_head];
assign commit_data  = rob_entry_data[rob_head];
assign commit_tag   = rob_head;

// ---- Sequential: allocate, complete, commit, flush -----------------
integer r;
always @(posedge clk) begin
    if (!rst_n) begin
        rob_head <= {TW{1'b0}};
        rob_tail <= {TW{1'b0}};
        for (r = 0; r < DEPTH; r = r + 1) begin
            rob_entry_valid[r]    <= 1'b0;
            rob_entry_complete[r] <= 1'b0;
            rob_entry_rd[r]       <= {AW{1'b0}};
            rob_entry_opcode[r]   <= {OW{1'b0}};
            rob_entry_data[r]     <= {DW{1'b0}};
        end
    end else if (flush) begin
        rob_head <= {TW{1'b0}};
        rob_tail <= {TW{1'b0}};
        for (r = 0; r < DEPTH; r = r + 1) begin
            rob_entry_valid[r]    <= 1'b0;
            rob_entry_complete[r] <= 1'b0;
        end
    end else begin
        // CDB completion: write result into the target ROB slot
        if (complete_valid) begin
            rob_entry_data[complete_tag]     <= complete_data;
            rob_entry_complete[complete_tag] <= 1'b1;
        end

        // Allocation: reserve tail slot for a new instruction
        if (alloc_valid && !rob_full) begin
            rob_entry_valid[rob_tail]    <= 1'b1;
            rob_entry_complete[rob_tail] <= 1'b0;
            rob_entry_rd[rob_tail]       <= alloc_rd;
            rob_entry_opcode[rob_tail]   <= alloc_opcode;
            rob_entry_data[rob_tail]     <= {DW{1'b0}};
            rob_tail                     <= rob_tail + 1'b1; // wraps at DEPTH (power-of-2)
        end

        // Commit: retire head entry when acknowledged
        if (commit_ack && commit_valid) begin
            rob_entry_valid[rob_head]    <= 1'b0;
            rob_entry_complete[rob_head] <= 1'b0;
            rob_head                     <= rob_head + 1'b1;
        end
    end
end

endmodule
