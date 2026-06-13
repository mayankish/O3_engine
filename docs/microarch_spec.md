# Microarchitecture Specification
# Out-of-Order Issue Queue (Tomasulo-style)

## 1. Overview

This design implements a parameterized out-of-order execution engine for a single
integer functional unit. It demonstrates the core mechanisms of Tomasulo's algorithm:
register renaming via a Register Alias Table (RAT), instruction buffering in a
Reservation Station (RS), precise in-order commit via a Reorder Buffer (ROB), and
result broadcast over a Common Data Bus (CDB).

The block diagram below shows the steady-state dataflow for a single-issue pipeline:

```
              instr_valid / instr[31:0]
                          |
                    +-----v------+
                    |  ooo_top   |  decode: rd, rs1, rs2, opcode
                    |  dispatch  |
                    +--+----+----+
                       |    |
           rename_valid|    | alloc_valid
                       v    v
              +--------+    +--------+
              |  RAT   |    |  ROB   |
              | rename |    | alloc  |
              | /read  |    |        |
              +--------+    +--------+
               s1_rdy,data   alloc_tag
                  |               |
            dispatch_*            | dest_tag
                  |               |
                  +-------+-------+
                          |
                   +------v------+
                   |   RS (N)    |  age-priority issue
                   |  entries    |  CAM tag snoop
                   +------+------+
                          | issue_valid, src1, src2, tag
                          v
                   +------+------+
                   | Integer ALU |  2-cycle pipeline
                   | (2-stage)   |
                   +------+------+
                          | cdb_valid, cdb_tag, cdb_data
                          v
                   +------+------+
                   |    CDB      |  combinational broadcast
                   +--+----+--+--+
                      |    |  |
                      v    v  v
                    RAT   RS  ROB   (snoop / capture / complete)
                                |
                           commit_valid, commit_data -> architectural state
```

## 2. Pipeline Stages

### 2.1 Fetch / Dispatch (1 cycle)

`ooo_top` decodes the 32-bit instruction word:

```
Instruction encoding (Verilog-2001):
  [31:27] rd     - destination register (5-bit arch address)
  [26:22] rs1    - source register 1
  [21:17] rs2    - source register 2
  [16:14] opcode - ALU operation (ADD/SUB/MUL/SHL/SHR)
  [13:0]  unused
```

Dispatch fires when `instr_valid && !rs_full && !rob_full`. In the same cycle:
- RAT provides operand values / readiness (including CDB forwarding)
- ROB allocates a new tail entry and returns `alloc_tag`
- RS allocates a free slot and stores the operand snapshot

### 2.2 Issue (combinational, no extra pipeline stage)

The RS continuously monitors all entries. An entry is issuable when both source
operands are ready, accounting for same-cycle CDB forwarding:

```verilog
e_s1_rdy_now[i] = rs_s1_rdy[i] ||
    (cdb_valid && rs_valid[i] && !rs_s1_rdy[i] && rs_src1_tag[i] == cdb_tag);
```

Among all issuable entries, the one with the **lowest dispatch sequence number**
(oldest instruction) is selected. This gives age-based, oldest-first priority.

Issue fires when `issue_valid_c && fu_ready`. The issued entry is cleared in the
same clock cycle (non-blocking assignment at posedge).

### 2.3 Execute (2 cycles)

The integer ALU is a 2-stage registered pipeline:

```
Cycle N   (issue): ALU inputs captured in stage-1 registers
Cycle N+1        : Stage-2 computes result, asserts cdb_req_valid
Cycle N+2 (CDB)  : cdb_valid HIGH; result broadcast to RS, RAT, ROB
```

The CDB is a combinational passthrough from the ALU's stage-2 output — no extra
register stage, so end-to-end execute latency from issue to CDB-visible = 2 cycles.

Operations: ADD, SUB, MUL (lower 32 bits), SHL (logical), SHR (arithmetic, signed).

### 2.4 Writeback / Broadcast (cycle N+2, combinational)

The CDB carries `{cdb_valid, cdb_tag[TW-1:0], cdb_data[DW-1:0]}`. Three consumers
snoop it simultaneously:

- **RS:** Updates `rs_s1_rdy`/`rs_src1` and `rs_s2_rdy`/`rs_src2` for all waiting
  entries whose tag matches.
- **RAT:** Captures data into `reg_data[rd]` and clears `reg_in_flight[rd]` for the
  matching register (WAW guard: only clears if `reg_tag[rd] == cdb_tag`).
- **ROB:** Marks the matching entry `rob_entry_complete` and stores the data.

### 2.5 Commit (in-order, 1 per cycle)

The ROB head is committed when `rob_entry_valid[head] && rob_entry_complete[head]`.
Commit is automatic (`commit_ack = commit_valid` in ooo_top) — the pipeline commits
one instruction per cycle as long as the head entry is complete. This enforces the
in-order architectural state update required for precise exceptions.

## 3. Hazard Handling

| Hazard | Mechanism |
|--------|-----------|
| RAW    | Operand captured at dispatch if CDB match; otherwise entry waits in RS for CDB broadcast |
| WAW    | RAT uses per-register tag: only the latest rename owns the in-flight bit. Old commit cannot clear newer rename (WAW guard on `reg_tag[rd] == commit_tag`). |
| WAR    | Eliminated by renaming: RS stores operand values at dispatch, not register addresses. |

## 4. Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| RS_DEPTH  | 8       | Reservation station entries (4/8/16, must be power of 2) |
| ROB_DEPTH | 16      | Reorder buffer depth (must be power of 2) |
| TAG_WIDTH | 4       | ROB tag bits: log2(ROB_DEPTH) |
| DATA_WIDTH| 32      | Operand and result width |
| REG_ADDR_W| 5       | Architectural register address width (32 registers) |
| SEQW      | 8       | Dispatch sequence counter width (wraps at 256) |

## 5. Key Design Decisions

**Age-based issue priority.** Each RS entry stores a `dispatch_seq` counter value
assigned at dispatch (monotonically increasing). The issue logic picks the entry with
the minimum seq among all ready entries. This prevents starvation and gives
deterministic, youngest-last ordering identical to program order.

**Same-cycle CDB forwarding.** The issue readiness check (`e_s1_rdy_now`) and the
issue data mux (`s1_via_cdb`) both use the current-cycle CDB signals combinationally.
This avoids a one-cycle penalty when an instruction's last operand arrives on the CDB
in the same cycle that the instruction would otherwise be blocked.

**One-slot-wasted ROB.** `rob_full = rob_entry_valid[rob_tail]` avoids a separate
count register. The ROB sacrifices one slot to distinguish full from empty without
an extra counter bit.

**Synthesizable Verilog-2001.** No SystemVerilog features. All parameter-dependent
loops use `generate`/`genvar` or integer `for` inside `always @(*)`. Array range-
index reduction avoided (illegal in V2001); OR-reduce uses explicit for loop.

## 6. Simulation Results

| Test                         | Result | Notes |
|------------------------------|--------|-------|
| RAW chain (5 dependent ADDs) | PASS   | All 5 commits, correct order |
| WAW hazard                   | PASS   | Second write wins, RAT guard verified |
| Independent burst (8 instrs) | PASS   | IPC = 0.47 over 17 cycles (drain method) |
| Flush mid-flight             | PASS   | Pipeline clears, resumes cleanly |
| RAT: CDB same-cycle forward  | PASS   | rs1_ready asserted same cycle as CDB |
| RAT: WAW guard               | PASS   | Old commit doesn't clear newer rename |
| ROB: OoO complete, in-order commit | PASS | Entry 1 completed first, entry 0 commits first |
| RS: Age-based priority       | PASS   | Older entry (lower seq) issues first |
| RS: CDB operand capture      | PASS   | Issue fires in same cycle as CDB asserts |

Steady-state IPC approaches 1.0 when the instruction window is saturated; the 0.47
figure reflects the fill+drain overhead for 8 instructions with a 2-cycle ALU.
