`timescale 1ns/1ps
`include "rtl/defines.vh"

// ============================================================
// Testbench : tb_bench_ipc
// Purpose   : Performance benchmark harness for ooo_top.
//             Drives an instruction stream (tb/gen_indep.py, tb/gen_chain.py,
//             or tb/gen_stimulus.py), measures cycles-to-drain, commit count,
//             IPC, and structural stall cycles (RS-full vs ROB-full). Also
//             acts as a deadlock detector: general mixed-hazard streams can
//             trigger the completed-but-not-committed RAW race documented in
//             docs/known_issues.md, in which case this harness times out and
//             reports IPC=DEADLOCK rather than hanging forever.
//
// Usage (compiled per RS_DEPTH):
//   iverilog -DRS_DEPTH=8 -I rtl -I . rtl/*.v tb/tb_bench_ipc.v -o bench.vvp
//   vvp bench.vvp +INSTR_FILE=sim/bench_instrs/h04.txt
// ============================================================

module tb_bench_ipc;

localparam DW  = `DATA_WIDTH;
localparam TW  = `TAG_WIDTH;
localparam AW  = `REG_ADDR_W;
localparam CLK = 10;
localparam MAX_INSTRS = 4096;
localparam TIMEOUT_NS = 500000;

reg        clk, rst_n, flush;
reg        instr_valid;
reg [31:0] instr;
wire       instr_ready;
wire       commit_valid;
wire [AW-1:0] commit_rd;
wire [DW-1:0] commit_data;
wire [TW-1:0] commit_tag;
wire          rs_full_w, rob_full_w, pipeline_busy;

ooo_top #(.RS_DEPTH(`RS_DEPTH), .ROB_DEPTH(`ROB_DEPTH)) dut (
    .clk(clk), .rst_n(rst_n), .flush(flush),
    .instr_valid(instr_valid), .instr(instr), .instr_ready(instr_ready),
    .commit_valid(commit_valid), .commit_rd(commit_rd),
    .commit_data(commit_data), .commit_tag(commit_tag),
    .rs_full(rs_full_w), .rob_full(rob_full_w),
    .pipeline_busy(pipeline_busy)
);

initial clk = 0;
always #(CLK/2) clk = ~clk;

// ---- Encoding helper -------------------------------------------------
function [31:0] enc;
    input [4:0] rd, rs1, rs2;
    input [2:0] op;
    begin
        enc = {rd, rs1, rs2, op, 14'b0};
    end
endfunction

// ---- Preloaded instruction stream -------------------------------------
integer op_arr [0:MAX_INSTRS-1];
integer rd_arr [0:MAX_INSTRS-1];
integer rs1_arr[0:MAX_INSTRS-1];
integer rs2_arr[0:MAX_INSTRS-1];
integer n_instr;

reg [1024:0] instr_file;

initial begin
    if (!$value$plusargs("INSTR_FILE=%s", instr_file)) begin
        $display("ERROR: +INSTR_FILE=<path> required");
        $finish;
    end
end

// ---- Cycle counter + stall tracking (free-running post-reset) --------
integer cycle_count;
integer stall_rs_full, stall_rob_full, stall_both;
integer total_commits;
integer start_cycle;

always @(posedge clk) begin
    if (!rst_n) begin
        cycle_count    <= 0;
        stall_rs_full  <= 0;
        stall_rob_full <= 0;
        stall_both     <= 0;
        total_commits  <= 0;
    end else begin
        cycle_count <= cycle_count + 1;
        if (instr_valid && !instr_ready) begin
            if (rs_full_w && rob_full_w)
                stall_both <= stall_both + 1;
            else if (rs_full_w)
                stall_rs_full <= stall_rs_full + 1;
            else if (rob_full_w)
                stall_rob_full <= stall_rob_full + 1;
        end
        if (commit_valid && commit_rd != {AW{1'b0}})
            total_commits <= total_commits + 1;
    end
end

// ---- Drive one instruction, respecting stall --------------------------
task drive_instr(input [31:0] i);
    begin
        instr       = i;
        instr_valid = 1;
        @(posedge clk);
        while (!instr_ready) @(posedge clk);
        #1;
        instr_valid = 0;
    end
endtask

task drain;
    begin
        instr_valid = 0;
        while (pipeline_busy) @(posedge clk);
    end
endtask

integer fp, op_i, rd_i, rs1_i, rs2_i, scan_ok;
integer end_cycle;
integer i;
real ipc;

initial begin
    rst_n = 0; flush = 0; instr_valid = 0; instr = 0;
    repeat(4) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // ---- Load instruction stream from file -----------------------
    n_instr = 0;
    fp = $fopen(instr_file, "r");
    if (fp == 0) begin
        $display("ERROR: could not open %0s", instr_file);
        $finish;
    end
    scan_ok = $fscanf(fp, "%d %d %d %d", op_i, rd_i, rs1_i, rs2_i);
    while (scan_ok == 4) begin
        op_arr[n_instr]  = op_i;
        rd_arr[n_instr]  = rd_i;
        rs1_arr[n_instr] = rs1_i;
        rs2_arr[n_instr] = rs2_i;
        n_instr = n_instr + 1;
        scan_ok = $fscanf(fp, "%d %d %d %d", op_i, rd_i, rs1_i, rs2_i);
    end
    $fclose(fp);

    // ---- Drive the stream back-to-back, timed ---------------------
    start_cycle = cycle_count;
    for (i = 0; i < n_instr; i = i + 1) begin
        drive_instr(enc(rd_arr[i][4:0], rs1_arr[i][4:0], rs2_arr[i][4:0], op_arr[i][2:0]));
    end
    drain;
    end_cycle = cycle_count;

    ipc = (end_cycle - start_cycle) > 0
          ? (total_commits * 1.0) / (end_cycle - start_cycle)
          : 0.0;

    $display("BENCH RS_DEPTH=%0d ROB_DEPTH=%0d N=%0d CYCLES=%0d COMMITS=%0d IPC=%0.4f STALL_RS=%0d STALL_ROB=%0d STALL_BOTH=%0d FILE=%0s",
              `RS_DEPTH, `ROB_DEPTH, n_instr, end_cycle - start_cycle,
              total_commits, ipc, stall_rs_full, stall_rob_full, stall_both, instr_file);
    $finish;
end

initial begin
    #TIMEOUT_NS;
    $display("BENCH RS_DEPTH=%0d ROB_DEPTH=%0d N=%0d CYCLES=%0d COMMITS=%0d IPC=DEADLOCK STALL_RS=%0d STALL_ROB=%0d STALL_BOTH=%0d FILE=%0s",
              `RS_DEPTH, `ROB_DEPTH, n_instr, cycle_count - start_cycle,
              total_commits, stall_rs_full, stall_rob_full, stall_both, instr_file);
    $finish;
end

endmodule
