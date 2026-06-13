// ============================================================
// Module      : integer_alu
// Project     : Out-of-Order Issue Queue - Tesla AI Hardware Portfolio
// Author      : Mayank
// Description : 2-stage pipelined integer ALU supporting ADD/SUB/MUL/SHL/SHR.
//               Issue-to-CDB-request latency = ALU_LATENCY = 2 cycles.
// Parameters  : DW=32 (data width), TW=4 (tag width), OW=3 (opcode width)
// ============================================================

`include "defines.vh"

module integer_alu #(
    parameter DW = `DATA_WIDTH,   // Operand/result data width
    parameter TW = `TAG_WIDTH,    // ROB tag width
    parameter OW = 3              // Opcode width
)(
    input  wire           clk,           // System clock
    input  wire           rst_n,         // Active-low synchronous reset
    input  wire           flush,         // Pipeline flush (kills in-flight ops)

    // Issue port (from reservation station)
    input  wire           issue_valid,   // Instruction being issued this cycle
    input  wire [OW-1:0]  issue_opcode,  // ALU operation selector
    input  wire [DW-1:0]  issue_src1,    // First source operand
    input  wire [DW-1:0]  issue_src2,    // Second source operand
    input  wire [TW-1:0]  issue_tag,     // Destination ROB tag

    // CDB request port (to common_data_bus)
    output reg            cdb_req_valid, // Result ready to broadcast
    output reg  [TW-1:0]  cdb_req_tag,   // Tag associated with result
    output reg  [DW-1:0]  cdb_req_data   // Computed result
);

// ---- Stage-1 pipeline registers ------------------------------------
reg            s1_valid;
reg  [OW-1:0]  s1_opcode;
reg  [DW-1:0]  s1_src1;
reg  [DW-1:0]  s1_src2;
reg  [TW-1:0]  s1_tag;

// ---- Stage-2 combinational compute ---------------------------------
// Signed wrappers for arithmetic right behaviour
wire signed [DW-1:0] s1_src1_s = $signed(s1_src1);
wire signed [DW-1:0] s1_src2_s = $signed(s1_src2);

// MUL: keep low 32 bits of 64-bit product (truncating multiply)
wire [2*DW-1:0] mul_result = s1_src1_s * s1_src2_s;

// Combinational result mux based on stage-1 opcode
reg [DW-1:0] s2_result_c;
always @(*) begin
    case (s1_opcode)
        `OP_ADD : s2_result_c = s1_src1 + s1_src2;
        `OP_SUB : s2_result_c = s1_src1 - s1_src2;
        `OP_MUL : s2_result_c = mul_result[DW-1:0];
        `OP_SHL : s2_result_c = s1_src1 << s1_src2[4:0];
        `OP_SHR : s2_result_c = s1_src1_s >>> s1_src2[4:0]; // arithmetic shift
        default : s2_result_c = {DW{1'b0}};
    endcase
end

// ---- Stage-1: latch issue inputs -----------------------------------
always @(posedge clk) begin
    if (!rst_n || flush) begin
        s1_valid  <= 1'b0;
        s1_opcode <= {OW{1'b0}};
        s1_src1   <= {DW{1'b0}};
        s1_src2   <= {DW{1'b0}};
        s1_tag    <= {TW{1'b0}};
    end else begin
        s1_valid  <= issue_valid;
        s1_opcode <= issue_opcode;
        s1_src1   <= issue_src1;
        s1_src2   <= issue_src2;
        s1_tag    <= issue_tag;
    end
end

// ---- Stage-2: register computed result  CDB request ---------------
always @(posedge clk) begin
    if (!rst_n || flush) begin
        cdb_req_valid <= 1'b0;
        cdb_req_tag   <= {TW{1'b0}};
        cdb_req_data  <= {DW{1'b0}};
    end else begin
        cdb_req_valid <= s1_valid;
        cdb_req_tag   <= s1_tag;
        cdb_req_data  <= s2_result_c;
    end
end

endmodule
