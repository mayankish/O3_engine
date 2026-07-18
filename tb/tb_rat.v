`timescale 1ns/1ps
`include "rtl/defines.vh"

// ============================================================
// Testbench : tb_rat
// Tests     : 1) Fresh register returns ready  2) Rename marks in-flight
//             3) WAW guard at commit  4) CDB same-cycle forwarding
//             5) Flush clears in-flight bits
//             6) ROB-completion forwarding (Fix #1 — post-CDB deadlock fix)
//                Verifies that a source register whose CDB broadcast happened
//                in a previous cycle is correctly reported as ready via the
//                rob_rsN_complete path, closing the permanent-stall window.
// ============================================================

module tb_rat;

localparam DW  = 32;
localparam TW  = 4;
localparam AW  = 5;
localparam NR  = 32;
localparam CLK = 10;

reg        clk, rst_n, flush;
reg [AW-1:0] rs1_addr, rs2_addr;
wire         rs1_ready, rs2_ready;
wire [DW-1:0] rs1_data, rs2_data;
wire [TW-1:0] rs1_tag, rs2_tag;
reg          rename_valid;
reg [AW-1:0] rename_rd;
reg [TW-1:0] rename_tag;
reg          commit_valid;
reg [AW-1:0] commit_rd;
reg [DW-1:0] commit_data;
reg [TW-1:0] commit_tag;
reg          cdb_valid;
reg [TW-1:0] cdb_tag;
reg [DW-1:0] cdb_data;

// [Fix #1] ROB-lookup inputs — driven to 0 for tests 1-5 (simulates no ROB hit)
// Test 6 exercises them explicitly to prove the deadlock fix.
reg          rob_rs1_complete, rob_rs2_complete;
reg [DW-1:0] rob_rs1_data,    rob_rs2_data;

integer errors;

register_alias_table #(.DW(DW),.TW(TW),.AW(AW),.NR(NR)) dut (
    .clk(clk), .rst_n(rst_n), .flush(flush),
    .rs1_addr(rs1_addr), .rs2_addr(rs2_addr),
    .rs1_ready(rs1_ready), .rs1_data(rs1_data), .rs1_tag(rs1_tag),
    .rs2_ready(rs2_ready), .rs2_data(rs2_data), .rs2_tag(rs2_tag),
    .rename_valid(rename_valid), .rename_rd(rename_rd), .rename_tag(rename_tag),
    .commit_valid(commit_valid), .commit_rd(commit_rd),
    .commit_data(commit_data), .commit_tag(commit_tag),
    .cdb_valid(cdb_valid), .cdb_tag(cdb_tag), .cdb_data(cdb_data),
    // [Fix #1] new ports
    .rob_rs1_complete(rob_rs1_complete), .rob_rs1_data(rob_rs1_data),
    .rob_rs2_complete(rob_rs2_complete), .rob_rs2_data(rob_rs2_data)
);

initial clk = 0;
always #(CLK/2) clk = ~clk;

initial begin
    $dumpfile("sim/waves/rat_tb.vcd");
    $dumpvars(0, tb_rat);
    errors = 0;

    rst_n = 0; flush = 0;
    rs1_addr = 0; rs2_addr = 0;
    rename_valid = 0; rename_rd = 0; rename_tag = 0;
    commit_valid = 0; commit_rd = 0; commit_data = 0; commit_tag = 0;
    cdb_valid = 0; cdb_tag = 0; cdb_data = 0;
    // [Fix #1] Default: no ROB hit
    rob_rs1_complete = 0; rob_rs1_data = 0;
    rob_rs2_complete = 0; rob_rs2_data = 0;
    repeat(4) @(posedge clk);
    rst_n = 1; #1;

    // TEST 1: Fresh register is ready (no in-flight bit)
    $display("TEST 1: Fresh register returns ready");
    rs1_addr = 5'd5;
    #1;
    if (!rs1_ready) begin
        $display("  FAIL: x5 should be ready after reset");
        errors = errors + 1;
    end else
        $display("  PASS: x5 is ready");

    // TEST 2: Rename marks register in-flight
    $display("TEST 2: Rename marks register in-flight");
    rename_valid = 1; rename_rd = 5'd5; rename_tag = 4'd3;
    @(posedge clk); #1;
    rename_valid = 0;
    rs1_addr = 5'd5;
    #1;
    if (rs1_ready) begin
        $display("  FAIL: x5 should be in-flight after rename");
        errors = errors + 1;
    end else if (rs1_tag !== 4'd3) begin
        $display("  FAIL: rs1_tag=%0d expected 3", rs1_tag);
        errors = errors + 1;
    end else
        $display("  PASS: x5 in-flight with tag=%0d", rs1_tag);

    // TEST 3: WAW guard - rename twice, old commit doesn't clear in-flight
    $display("TEST 3: WAW guard at commit");
    rename_valid = 1; rename_rd = 5'd5; rename_tag = 4'd7;
    @(posedge clk); #1;
    rename_valid = 0;
    commit_valid = 1; commit_rd = 5'd5; commit_data = 32'hAAAA; commit_tag = 4'd3;
    @(posedge clk); #1;
    commit_valid = 0; #1;
    rs1_addr = 5'd5;
    #1;
    if (rs1_ready) begin
        $display("  FAIL: WAW guard failed - in_flight wrongly cleared by old commit");
        errors = errors + 1;
    end else
        $display("  PASS: WAW guard correct, x5 still in-flight (tag 7 current)");
    commit_valid = 1; commit_rd = 5'd5; commit_data = 32'hBBBB; commit_tag = 4'd7;
    @(posedge clk); #1;
    commit_valid = 0; #1;
    rs1_addr = 5'd5;
    #1;
    if (!rs1_ready) begin
        $display("  FAIL: x5 should be ready after tag-7 commit");
        errors = errors + 1;
    end else
        $display("  PASS: x5 ready after tag-7 commit, data=%h", rs1_data);

    // TEST 4: CDB same-cycle forwarding
    $display("TEST 4: CDB same-cycle forwarding at dispatch");
    rename_valid = 1; rename_rd = 5'd10; rename_tag = 4'd5;
    @(posedge clk); #1;
    rename_valid = 0;
    cdb_valid = 1; cdb_tag = 4'd5; cdb_data = 32'hC0FFEE;
    rs1_addr = 5'd10;
    #1;
    if (!rs1_ready) begin
        $display("  FAIL: CDB forwarding not working - rs1_ready=0");
        errors = errors + 1;
    end else if (rs1_data !== 32'hC0FFEE) begin
        $display("  FAIL: CDB forward wrong data: got %h expected C0FFEE", rs1_data);
        errors = errors + 1;
    end else
        $display("  PASS: CDB forwarded data=%h to dispatch read", rs1_data);
    cdb_valid = 0;
    @(posedge clk); #1;

    // TEST 5: Flush clears all in-flight bits
    $display("TEST 5: Flush clears in-flight");
    rename_valid = 1; rename_rd = 5'd15; rename_tag = 4'd9;
    @(posedge clk); #1; rename_valid = 0;
    flush = 1; @(posedge clk); #1; flush = 0; #1;
    rs1_addr = 5'd15;
    #1;
    if (!rs1_ready) begin
        $display("  FAIL: x15 still in-flight after flush");
        errors = errors + 1;
    end else
        $display("  PASS: x15 ready after flush");

    // ================================================================
    // TEST 6: ROB-completion forwarding — Fix #1 regression test
    // Scenario: consumer dispatches AFTER the CDB broadcast cycle for its
    // source, but BEFORE commit.  Without the fix this permanently stalls;
    // with the fix the ROB-hit path returns rs1_ready=1 immediately.
    // ================================================================
    $display("TEST 6: ROB-completion forwarding (post-CDB pre-commit readiness)");

    // Step 1: rename x20 to tag 11
    rename_valid = 1; rename_rd = 5'd20; rename_tag = 4'd11;
    @(posedge clk); #1;
    rename_valid = 0;

    // Step 2: simulate CDB broadcast for tag 11 — x20 in flight, CDB fires
    cdb_valid = 1; cdb_tag = 4'd11; cdb_data = 32'hDEADBEEF;
    @(posedge clk); #1;
    // After this clock edge: reg_data[20] = 0xDEADBEEF (latched by sequential block)
    //                        reg_in_flight[20] still 1 (only cleared at commit)
    cdb_valid = 0;  // CDB is now GONE
    #1;

    // Step 3: consumer dispatches NOW (one cycle after CDB).
    // No live CDB this cycle.  Without Fix #1: rs1_ready=0 → deadlock.
    // With Fix #1: assert rob_rs1_complete=1, rob_rs1_data=0xDEADBEEF (simulating
    // what the ROB lookup port would return after the CDB captured the result).
    rs1_addr = 5'd20;
    rob_rs1_complete = 1'b1;
    rob_rs1_data     = 32'hDEADBEEF;
    #1;
    if (!rs1_ready) begin
        $display("  FAIL: deadlock — rs1_ready=0 when ROB complete (Fix #1 not working)");
        errors = errors + 1;
    end else if (rs1_data !== 32'hDEADBEEF) begin
        $display("  FAIL: ROB-hit data wrong: got %h expected DEADBEEF", rs1_data);
        errors = errors + 1;
    end else
        $display("  PASS: rs1_ready=1 via ROB-hit, data=%h", rs1_data);

    // Step 4: commit arrives — in_flight clears, rob_rs1_complete back to 0
    rob_rs1_complete = 1'b0;
    commit_valid = 1; commit_rd = 5'd20; commit_data = 32'hDEADBEEF; commit_tag = 4'd11;
    @(posedge clk); #1;
    commit_valid = 0; #1;
    rs1_addr = 5'd20;
    #1;
    if (!rs1_ready) begin
        $display("  FAIL: x20 not ready after commit");
        errors = errors + 1;
    end else
        $display("  PASS: x20 ready after commit (in_flight cleared)");

    $display("--------------------------------------------");
    if (errors == 0)
        $display("register_alias_table TB: RESULT: PASS");
    else
        $display("register_alias_table TB: %0d errors, RESULT: FAIL", errors);
    $display("--------------------------------------------");
    $finish;
end

initial begin
    #100000; $display("TIMEOUT"); $finish;
end

endmodule
