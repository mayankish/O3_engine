# Signal Interface Table - ooo_top

## Top-Level Ports

| Port           | Dir | Width | Description |
|----------------|-----|-------|-------------|
| clk            | in  | 1     | System clock (rising-edge triggered) |
| rst_n          | in  | 1     | Active-low synchronous reset |
| flush          | in  | 1     | Flush all in-flight instructions (pipeline squash) |
| instr_valid    | in  | 1     | Instruction word is valid and ready to dispatch |
| instr[31:0]    | in  | 32    | Encoded instruction: {rd[4:0], rs1[4:0], rs2[4:0], op[2:0], 14'b0} |
| instr_ready    | out | 1     | Pipeline can accept a new instruction this cycle |
| commit_valid   | out | 1     | Head ROB entry is retiring this cycle |
| commit_rd[4:0] | out | 5     | Architectural destination register of retiring instruction |
| commit_data[31:0] | out | 32 | Result value written to commit_rd |
| commit_tag[TW-1:0] | out | TW | ROB tag of retiring instruction |
| rs_full        | out | 1     | Reservation station has no free entries |
| rob_full       | out | 1     | Reorder buffer has no free entries |
| pipeline_busy  | out | 1     | At least one instruction is in-flight (RS or ROB non-empty) |

## Instruction Encoding

```
 31      27 26      22 21      17 16   14 13         0
 +--------+---------+---------+-------+-------------+
 | rd[4:0] | rs1[4:0] | rs2[4:0] | op[2:0] |  14'b0  |
 +--------+---------+---------+-------+-------------+
```

Opcode table:
| op[2:0] | Operation | Signed? |
|---------|-----------|---------|
| 3'b000  | ADD       | No (wraps) |
| 3'b001  | SUB       | No (wraps) |
| 3'b010  | MUL       | Signed, lower 32 bits |
| 3'b011  | SHL       | Logical left shift by rs2[4:0] |
| 3'b100  | SHR       | Arithmetic right shift by rs2[4:0] |

## Internal Module Interfaces

### reservation_station ports (key subset)

| Port                | Dir | Width | Description |
|---------------------|-----|-------|-------------|
| dispatch_valid      | in  | 1     | Allocate a new RS entry this cycle |
| dispatch_s1_rdy     | in  | 1     | Source-1 data is available (from RAT) |
| dispatch_s1_data    | in  | DW    | Source-1 value when s1_rdy=1 |
| dispatch_s1_tag     | in  | TW    | Source-1 pending ROB tag when s1_rdy=0 |
| fu_ready            | in  | 1     | Functional unit is free |
| issue_valid         | out | 1     | Oldest ready entry is issuing this cycle |
| issue_src1/src2     | out | DW    | Resolved source operands (CDB-bypassed if needed) |
| issue_tag           | out | TW    | Destination ROB tag being issued |
| cdb_valid/tag/data  | in  | 1/TW/DW | CDB broadcast (snooped for same-cycle forwarding) |
| rs_full / rs_empty  | out | 1     | Status flags |

### reorder_buffer ports (key subset)

| Port              | Dir | Width | Description |
|-------------------|-----|-------|-------------|
| alloc_valid       | in  | 1     | Allocate a new ROB tail entry |
| alloc_tag         | out | TW    | Tag assigned to the new entry (= rob_tail before increment) |
| rob_full          | out | 1     | = rob_entry_valid[rob_tail] (one-slot-wasted scheme) |
| complete_valid    | in  | 1     | Mark an entry as computed |
| complete_tag      | in  | TW    | Which ROB entry completed |
| complete_data     | in  | DW    | Result value |
| commit_valid      | out | 1     | Head entry is complete and ready to commit |
| commit_ack        | in  | 1     | Acknowledge commit (advance rob_head) |
| rob_empty         | out | 1     | = !rob_entry_valid[rob_head] |

### register_alias_table ports (key subset)

| Port            | Dir | Width | Description |
|-----------------|-----|-------|-------------|
| rs1_addr/rs2_addr | in | AW  | Register addresses to read at dispatch |
| rs1_ready       | out | 1     | rs1 is architecturally ready (not in-flight, or CDB hit) |
| rs1_data        | out | DW    | rs1 value (or CDB data if cdb_hit) |
| rs1_tag         | out | TW    | Pending ROB tag when rs1_ready=0 |
| rename_valid    | in  | 1     | Rename rd to rename_tag and mark in-flight |
| commit_valid    | in  | 1     | Commit: write commit_data to commit_rd, clear in-flight (WAW-guarded) |
| cdb_valid/tag/data | in | 1/TW/DW | CDB for same-cycle dispatch forwarding |
