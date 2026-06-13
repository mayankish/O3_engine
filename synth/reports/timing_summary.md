# Timing Summary - OoO Issue Queue

Target clock: 500 MHz (2.0 ns period)

## Critical Path Analysis

The critical path runs through the **CDB-to-issue combinational chain**:

```
cdb_tag (input)
  -> TAG comparison vs rs_src1_tag[i] for all i      (CAM, O(N) compares in parallel)
  -> e_s1_rdy_now[i] = rs_s1_rdy[i] || cdb_hit[i]   (OR gate)
  -> e_ready_now[i]  = valid && s1_rdy_now && s2_rdy  (AND)
  -> age priority: rs_seq[k] < min_seq for all ready k (O(N) comparator chain)
  -> issue_valid, issue_src1                            (output mux)
```

The tag comparisons are fully parallel; only the age-priority selection is a linear scan.

## Generic Cell Depth Estimates

| RS_DEPTH | Total generic cells | Est. FFs | Comb. depth | Meets 500 MHz? |
|----------|---------------------|----------|-------------|----------------|
| 4        | 240                 | 388      | ~12 levels  | Yes            |
| 8        | 420                 | 768      | ~14 levels  | Yes            |
| 16       | 780                 | 1528     | ~17 levels  | Marginal       |

Cell counts from `yosys prep` (generic RTL-level cells before technology mapping).
Estimated FFs = RS_DEPTH x 95 bits/entry + 8-bit dispatch_seq counter.

## Full ooo_top (RS_DEPTH=8, ROB_DEPTH=16)

Generic cells (pre-mapping): **865**
Breakdown by source block:
- Reservation station (8 entries, CAM + age priority): ~420
- Register alias table (RAT/rename + CDB forwarding): ~220
- Reorder buffer (circular, in-order commit):          ~100
- Integer ALU (2-stage pipeline):                      ~80
- CDB passthrough + ooo_top decode/glue:               ~45

## Scaling Observation

Combinational area scales ~linearly with RS_DEPTH (dominated by $mux and $logic_and
for the tag-match CAM):

| RS_DEPTH | $mux | $logic_and | $eq  | $lt |
|----------|------|------------|------|-----|
| 4        | 140  | 50         | 10   | 3   |
| 8        | 240  | 94         | 18   | 7   |
| 16       | 440  | 182        | 34   | 15  |
| ratio 4->16 | x3.1 | x3.6  | x3.4 | x5  |

The $lt (less-than comparator, used for age comparison) scales faster than linear
because the priority encoder compares against an O(RS_DEPTH) set of sequence numbers.

## Timing Budget Allocation (500 MHz, generic cells)

```
2.0 ns  total period
- 0.2 ns  clock-to-Q (DFF output delay)
- 0.3 ns  setup time (DFF input)
= 1.5 ns  available for combinational logic

At ~12 FO4 delay per logic level for typical 28nm:
  12 levels x 0.125 ns/level = 1.5 ns  (RS_DEPTH=4/8, achievable)
  17 levels x 0.125 ns/level = 2.1 ns  (RS_DEPTH=16, over budget by 0.6 ns)
```

**Recommendation for RS_DEPTH=16:** pipeline the issue selection across two cycles
(one cycle for CAM readiness, next cycle for age selection + issue) or implement
a priority encoder tree instead of the linear scan.
