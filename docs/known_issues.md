# Known Issue: RAT ready/commit conflation causes a permanent RS stall

## Summary

Extended random-instruction benchmarking (`tb/run_ipc_benchmark.py`, see the
README's Benchmarks section) found that `ooo_top` deadlocks on essentially
any multi-register instruction stream long enough to create realistic
program-like traffic. This is a genuine functional bug, not a testbench
artifact, and it was previously undetected because:

1. The unit/integration tests in `tb/` only exercise two hazard shapes that
   happen to avoid it: a pure single-destination-register independent burst
   (`TEST 3` in `tb_ooo_top.v`) and a pure linear RAW chain (`TEST 1`). Both
   sidestep the race described below by construction.
2. The one test that *would* have caught it — the file-based random
   regression (`TEST 5`, driven by `tb/gen_stimulus.py` via
   `sim/run_all_tests.sh`) — was silently running zero instructions due to
   an `$fscanf` parsing bug (documented as a "known quirk" in the top-level
   README before this benchmarking pass). That parsing bug has been fixed;
   fixing it is what surfaced this issue.

## Root cause

`register_alias_table.v` tracks each architectural register with a single
`reg_in_flight[r]` bit. That bit is set at rename (dispatch) and cleared
**only at commit**:

```verilog
// commit block
if (commit_valid && (commit_rd != {AW{1'b0}})) begin
    reg_data[commit_rd] <= commit_data;
    if (reg_tag[commit_rd] == commit_tag)
        reg_in_flight[commit_rd] <= 1'b0;   // <-- only cleared here
end
```

But the *value* becomes available earlier, at completion (CDB broadcast),
via a separate always-block:

```verilog
if (cdb_valid) begin
    for (r = 0; r < NR; r = r + 1)
        if (reg_in_flight[r] && (reg_tag[r] == cdb_tag))
            reg_data[r] <= cdb_data;          // data captured here
end
```

`reservation_station.v` only learns about a completed operand by snooping
the *live* CDB pulse the instant it fires:

```verilog
if (cdb_valid && rs_valid[i] && !rs_s1_rdy[i] && (rs_src1_tag[i] == cdb_tag))
    rs_src1[i] <= cdb_data;   // one-shot: only catches the single broadcast cycle
```

Putting these together: if instruction **A** (dest register `x5`, tag `T`)
completes and broadcasts on the CDB, but has not yet committed because an
**older** instruction ahead of it in the ROB hasn't finished yet (a normal
out-of-order-completion scenario), then `reg_in_flight[x5]` stays `1` even
though `reg_data[x5]` already holds the correct value. If a **new**
instruction **B** is dispatched during that window and reads `x5`, the RAT
reports `rs1_ready = 0` with `rs1_tag = T` (since it only looks at
`reg_in_flight`, not "has this tag already broadcast"). B's reservation
station entry is now waiting for CDB tag `T` — but tag `T` already
broadcast once and will never broadcast again. B can never issue.
`rs_valid` for that entry never clears, so the RS eventually fills
permanently and `pipeline_busy` never deasserts: a hard deadlock, not a
livelock or slowdown.

This requires only three ordinary conditions, all common in real programs:
out-of-order completion (some earlier instruction is still in flight when a
later one finishes), a new consumer of the same architectural register
dispatching inside that window, and no intervening rename. None of it
requires an adversarial hazard rate — see the benchmark data below, where
even `--hazard 0.0` (register selection is uniform-random, not
hazard-seeking) deadlocks 100% of 60-instruction streams, simply because
32 registers are not enough to avoid incidental reuse over that many
instructions ("birthday paradox").

## Measured severity

From `tb/run_ipc_benchmark.py`'s mixed-hazard sweep
(`sim/bench_results/deadlock_benchmark.csv`, `docs/images/deadlock_rate.png`):
every hazard rate from 0.0 to 0.8, at every RS_DEPTH (4/8/16), deadlocked
100% of 60-instruction streams (3/3 seeds each). A supplementary length
sweep at hazard=0.4 found the deadlock is already present at very short
streams and saturates quickly:

| N (instructions) | Deadlocked (of 3 seeds) |
|---|---|
| 5  | 1/3 |
| 8  | 2/3 |
| 10 | 2/3 |
| 15 | 2/3 |
| 20 | 2/3 |
| 25 | 2/3 |
| 30 | 3/3 |

This means the two benchmark workloads that *do* produce clean IPC numbers
in the README (independent single-register bursts, pure RAW chains) are
best-case and worst-case-for-forwarding respectively, but neither is
representative of a real mixed program — a realistic instruction stream
using more than one destination register will almost certainly hit this
bug once it's long enough to matter.

## Suggested fix direction (not implemented here)

Decouple "value known" from "safe to reclaim the rename." Options, roughly
in order of invasiveness:

1. Add a second bit, e.g. `reg_completed[r]`, set the cycle a matching CDB
   tag broadcasts (independent of `reg_in_flight`), and change
   `rs1_ready` to `!reg_in_flight[r] || (reg_completed[r] && reg_tag[r] == <tag at completion>)`.
   Simplest, smallest diff, but still needs a per-register tag-match check
   against a *latched* tag rather than only the live `cdb_tag`.
2. Give the RAT a small content-addressable "recently completed" cache
   (e.g. one entry per ROB slot, mirroring ROB's own `rob_entry_complete` +
   `rob_entry_data`) that dispatch can check in addition to the live CDB,
   so a value that already landed in the ROB (but hasn't committed) can
   still be forwarded. This is effectively exposing the ROB's own
   `rob_entry_complete`/`rob_entry_data` arrays to the dispatch-time read
   path instead of relying solely on the CDB's one-shot broadcast.
3. Guarantee in-order completion (remove the out-of-order execution this
   design exists to demonstrate) — not a real option, just noting it as
   the trivial fix that isn't acceptable here.

Option 2 is the architecturally "correct" fix (it's essentially what real
OoO designs do — dispatch-time operand read checks the ROB, not just the
live CDB), but is a larger RTL change than this benchmarking pass was
scoped to make. Flagging it here rather than patching it live, since a fix
to core rename logic deserves its own review/testbench pass rather than
being folded into a benchmarking exercise.
