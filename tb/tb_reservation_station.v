`timescale 1ns/1ps
`include "rtl/defines.vh"

// ============================================================
// Testbench : tb_reservation_station
// Tests     : 1) Fill to rs_full  2) Dispatch+issue round-trip
//             3) CDB operand capture  4) Age-based priority
//             5) Flush clears all entries
//
// Timing note: issue_valid is combinational and stays HIGH for exactly
// one clock cycle (from when the entry becomes READY until the RS clears
// it at the next rising edge).  Checks below sample issue_valid BEFORE
// that clearing edge, not after.
// ============================================================

module tb_reservation_station;

localparam RS  = 4;
localparam DW  = 32;
localparam TW  = 4;
localparam AW  = 5;
localparam OW  = 3;
localparam SW  = 8;
localparam CLK = 10;

reg        clk, rst_n, flush;
reg        dispatch_valid;
reg [OW-1:0] dispatch_opcode;
reg [AW-1:0] dispatch_rs1, dispatch_rs2, dispatch_rd;
reg          dispatch_s1_rdy, dispatch_s2_rdy;
reg [DW-1:0] dispatch_s1_data, dispatch_s2_data;
reg [TW-1:0] dispatch_s1_tag,  dispatch_s2_tag;
reg [TW-1:0] dispatch_dest_tag;
reg          fu_ready;
reg          cdb_valid;
reg [TW-1:0] cdb_tag;
reg [DW-1:0] cdb_data;

wire         issue_valid;
wire [OW-1:0] issue_opcode;
wire [DW-1:0] issue_src1, issue_src2;
wire [TW-1:0] issue_tag;
wire          rs_full, rs_empty;

integer errors;

reservation_station #(
    .RS_DEPTH(RS), .DW(DW), .TW(TW), .AW(AW), .OW(OW), .SEQW(SW)
) dut (
    .clk(clk), .rst_n(rst_n), .flush(flush),
    .dispatch_valid(dispatch_valid), .dispatch_opcode(dispatch_opcode),
    .dispatch_rs1(dispatch_rs1), .dispatch_rs2(dispatch_rs2),
    .dispatch_rd(dispatch_rd),
    .dispatch_s1_rdy(dispatch_s1_rdy), .dispatch_s1_data(dispatch_s1_data),
    .dispatch_s1_tag(dispatch_s1_tag),
    .dispatch_s2_rdy(dispatch_s2_rdy), .dispatch_s2_data(dispatch_s2_data),
    .dispatch_s2_tag(dispatch_s2_tag),
    .dispatch_dest_tag(dispatch_dest_tag),
    .fu_ready(fu_ready),
    .issue_valid(issue_valid), .issue_opcode(issue_opcode),
    .issue_src1(issue_src1), .issue_src2(issue_src2), .issue_tag(issue_tag),
    .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data),
    .rs_full(rs_full), .rs_empty(rs_empty)
);

initial clk = 0;
always #(CLK/2) clk = ~clk;

// Drive dispatch for one clock, both operands ready
// Returns at T(dispatch_edge)+1 while issue_valid is still HIGH.
task dispatch_ready(
    input [OW-1:0] op,
    input [DW-1:0] s1, s2,
    input [TW-1:0] dtag
);
    begin
        dispatch_valid    = 1;
        dispatch_opcode   = op;
        dispatch_s1_rdy   = 1; dispatch_s1_data = s1; dispatch_s1_tag = 0;
        dispatch_s2_rdy   = 1; dispatch_s2_data = s2; dispatch_s2_tag = 0;
        dispatch_dest_tag = dtag;
        dispatch_rs1 = 0; dispatch_rs2 = 0; dispatch_rd = 0;
        @(posedge clk); #1;
        dispatch_valid = 0;
    end
endtask

// Drive dispatch with src1 pending on tag t1
// Returns at T(dispatch_edge)+1.
task dispatch_pending_s1(
    input [OW-1:0] op,
    input [TW-1:0] t1,
    input [DW-1:0] s2,
    input [TW-1:0] dtag
);
    begin
        dispatch_valid    = 1;
        dispatch_opcode   = op;
        dispatch_s1_rdy   = 0; dispatch_s1_data = 0; dispatch_s1_tag = t1;
        dispatch_s2_rdy   = 1; dispatch_s2_data = s2; dispatch_s2_tag = 0;
        dispatch_dest_tag = dtag;
        dispatch_rs1 = 0; dispatch_rs2 = 0; dispatch_rd = 0;
        @(posedge clk); #1;
        dispatch_valid = 0;
    end
endtask

initial begin
    $dumpfile("sim/waves/rs_tb.vcd");
    $dumpvars(0, tb_reservation_station);
    errors = 0;

    rst_n = 0; flush = 0;
    dispatch_valid = 0; fu_ready = 1; cdb_valid = 0;
    dispatch_opcode = 0; dispatch_rs1 = 0; dispatch_rs2 = 0; dispatch_rd = 0;
    dispatch_s1_rdy = 0; dispatch_s2_rdy = 0;
    dispatch_s1_data = 0; dispatch_s2_data = 0;
    dispatch_s1_tag = 0; dispatch_s2_tag = 0;
    dispatch_dest_tag = 0; cdb_tag = 0; cdb_data = 0;
    repeat(4) @(posedge clk);
    rst_n = 1; #1;

    // ============================================================
    // TEST 1: Fill RS to full, then verify rs_full asserts
    // ============================================================
    $display("TEST 1: Fill RS_DEPTH=%0d entries", RS);
    fu_ready = 0;
    repeat(RS) begin
        dispatch_ready(`OP_ADD, 32'd10, 32'd20, 4'd0);
        @(posedge clk); #1;
    end
    if (!rs_full) begin
        $display("  FAIL: rs_full not asserted after %0d dispatches", RS);
        errors = errors + 1;
    end else
        $display("  PASS: rs_full asserted");

    flush = 1; @(posedge clk); #1; flush = 0;
    if (!rs_empty) begin
        $display("  FAIL: rs_empty not asserted after flush");
        errors = errors + 1;
    end else
        $display("  PASS: rs_empty after flush");

    // ============================================================
    // TEST 2: Both operands ready at dispatch -> issues the same cycle
    // Check issue_valid at T(dispatch_edge)+1 BEFORE the clearing edge.
    // ============================================================
    $display("TEST 2: Ready instruction issues in dispatch cycle");
    fu_ready = 1;
    dispatch_ready(`OP_ADD, 32'd5, 32'd3, 4'd1);
    // Now at T(dispatch_edge)+1.  NBAs have settled.  issue_valid is HIGH.
    if (!issue_valid || issue_src1 !== 32'd5 || issue_src2 !== 32'd3
                     || issue_tag !== 4'd1) begin
        $display("  FAIL: issue_valid=%0d src1=%0d src2=%0d tag=%0d",
                 issue_valid, issue_src1, issue_src2, issue_tag);
        errors = errors + 1;
    end else
        $display("  PASS: issue_valid, src1=%0d src2=%0d tag=%0d",
                 issue_src1, issue_src2, issue_tag);
    @(posedge clk); #1; // entry is cleared here

    // ============================================================
    // TEST 3: CDB captures pending src1 -> issues same CDB cycle
    // ============================================================
    $display("TEST 3: CDB operand capture");
    fu_ready = 0;
    dispatch_pending_s1(`OP_SUB, 4'd3, 32'd7, 4'd2);
    @(posedge clk); #1;
    // Entry in RS, src1 not ready, fu_ready=0 -> no issue
    if (issue_valid) begin
        $display("  FAIL: issued before CDB (fu_ready=0)");
        errors = errors + 1;
    end
    // Drive CDB and enable FU simultaneously
    fu_ready  = 1;
    cdb_valid = 1; cdb_tag = 4'd3; cdb_data = 32'd42;
    #1; // combinational settle; NO clock edge yet
    if (!issue_valid || issue_src1 !== 32'd42 || issue_src2 !== 32'd7) begin
        $display("  FAIL: CDB fwd wrong: issue_valid=%0d src1=%0d src2=%0d",
                 issue_valid, issue_src1, issue_src2);
        errors = errors + 1;
    end else
        $display("  PASS: CDB forwarded src1=%0d, issued", issue_src1);
    @(posedge clk); #1; // entry cleared, CDB capture committed
    cdb_valid = 0;
    @(posedge clk); #1;

    // ============================================================
    // TEST 4: Age-based priority - oldest ready entry issues first
    // ============================================================
    $display("TEST 4: Age-based issue priority");
    fu_ready = 0;
    // First dispatch gets seq=0 (lower -> older -> higher priority)
    dispatch_ready(`OP_ADD, 32'd100, 32'd1, 4'd5);
    @(posedge clk); #1; // extra idle cycle (fu_ready=0, nothing issues)
    // Second dispatch gets seq=1
    dispatch_ready(`OP_ADD, 32'd200, 32'd2, 4'd6);
    // At T(second_dispatch_edge)+1: both entries valid, no issue (fu_ready=0).
    // Enable FU without a clock edge to check combinational priority.
    fu_ready = 1;
    #1; // settle
    if (!issue_valid || issue_src1 !== 32'd100) begin
        $display("  FAIL: oldest not selected; issue_valid=%0d src1=%0d",
                 issue_valid, issue_src1);
        errors = errors + 1;
    end else
        $display("  PASS: oldest (src1=%0d) issued first", issue_src1);
    @(posedge clk); #1; // entry 0 cleared; entry 1 should now be selected
    if (!issue_valid || issue_src1 !== 32'd200) begin
        $display("  FAIL: second entry not issued; issue_valid=%0d src1=%0d",
                 issue_valid, issue_src1);
        errors = errors + 1;
    end else
        $display("  PASS: second entry (src1=%0d) issued", issue_src1);
    @(posedge clk); #1; // entry 1 cleared

    // ============================================================
    // TEST 5: Flush mid-flight clears all entries
    // ============================================================
    $display("TEST 5: Flush clears entries");
    fu_ready = 0;
    dispatch_ready(`OP_MUL, 32'd9, 32'd9, 4'd7);
    flush = 1; @(posedge clk); #1; flush = 0;
    @(posedge clk); #1;
    fu_ready = 1; #1;
    if (issue_valid) begin
        $display("  FAIL: issue_valid after flush");
        errors = errors + 1;
    end else
        $display("  PASS: no issue after flush");

    // ==============================================    // ============================================================
    $display("--------------------------------------------");
    if (errors == 0)
        $display("reservation_station TB: RESULT: PASS");
    else
        $display("reservation_station TB: %0d errors, RESULT: FAIL", errors);
    $display("--------------------------------------------");
    $finish;
end

initial begin
    #100000; $display("TIMEOUT"); $finish;
end

endmodule
