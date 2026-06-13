// ============================================================
// Module      : common_data_bus
// Project     : Out-of-Order Issue Queue - Tesla AI Hardware Portfolio
// Author      : Mayank
// Description : Combinational CDB broadcast for a single functional unit.
//               Structured for easy extension to N FUs with round-robin grant.
// Parameters  : DW=32 (data width), TW=4 (tag width), NUM_FU=1
// ============================================================

`include "defines.vh"

module common_data_bus #(
    parameter DW     = `DATA_WIDTH,  // Data path width
    parameter TW     = `TAG_WIDTH,   // ROB tag width
    parameter NUM_FU = `NUM_FU       // Number of functional units
)(
    // FU result inputs (one per FU; extended when NUM_FU > 1)
    input  wire           fu0_valid,  // FU-0 result valid
    input  wire [TW-1:0]  fu0_tag,    // FU-0 destination ROB tag
    input  wire [DW-1:0]  fu0_data,   // FU-0 result data

    // Broadcast outputs (connected to RS, RAT, ROB simultaneously)
    output wire           cdb_valid,  // Broadcast valid this cycle
    output wire [TW-1:0]  cdb_tag,    // Winning tag on the bus
    output wire [DW-1:0]  cdb_data    // Winning data on the bus
);

// Single-FU: straight passthrough.  With NUM_FU > 1 replace with
// a round-robin arbitration tree and add a grant-ack backpressure
// signal back to each FU.
assign cdb_valid = fu0_valid;
assign cdb_tag   = fu0_tag;
assign cdb_data  = fu0_data;

endmodule
