// ============================================================
// File        : defines.vh
// Project     : Out-of-Order Issue Queue - Tesla AI Hardware Portfolio
// Author      : Mayank
// Description : Global parameters, opcode encodings, and state constants.
//               RS_DEPTH may be overridden at compile time: -DRS_DEPTH=4
// ============================================================

`ifndef DEFINES_VH
`define DEFINES_VH

// ---- Overridable via -D flag ----------------------------------------
`ifndef RS_DEPTH
`define RS_DEPTH 8        // Reservation station entries (4/8/16)
`endif

`ifndef ROB_DEPTH
`define ROB_DEPTH 16      // Reorder buffer entries (must be power of 2)
`endif

// ---- Fixed microarchitecture parameters ----------------------------
`define NUM_REGS    32    // Architectural register count (x0x31)
`define DATA_WIDTH  32    // Data path width in bits
`define NUM_FU      1     // Functional unit count (ALU only)
`define ALU_LATENCY 2     // Pipeline stages inside integer_alu

// Derived widths (hardcoded to avoid $clog2 in preprocessor)
`define TAG_WIDTH   4     // log2(ROB_DEPTH=16): ROB index / rename tag
`define REG_ADDR_W  5     // log2(NUM_REGS=32): architectural register index
`define SEQW        8     // Dispatch sequence counter width (age tracking)

// ---- Instruction encoding (32-bit) ---------------------------------
//   [31:27] rd   [26:22] rs1   [21:17] rs2   [16:14] opcode   [13:0] imm
`define RD_HI   31
`define RD_LO   27
`define RS1_HI  26
`define RS1_LO  22
`define RS2_HI  21
`define RS2_LO  17
`define OP_HI   16
`define OP_LO   14

// ---- ALU opcode encoding -------------------------------------------
`define OP_ADD  3'b000
`define OP_SUB  3'b001
`define OP_MUL  3'b010
`define OP_SHL  3'b011
`define OP_SHR  3'b100
`define OP_NOP  3'b111   // No-op / architectural x0 write sink

// ---- RS entry valid / invalid flag ---------------------------------
`define RS_INVALID 1'b0
`define RS_VALID   1'b1

`endif // DEFINES_VH
