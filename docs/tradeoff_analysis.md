# Trade-off Analysis: RS Depth vs IPC vs Area

## 1. Motivation

The reservation station depth (RS_DEPTH) is the primary design knob for this engine.
A deeper RS allows more instructions to be buffered, hiding latency under RAW chains
and enabling more ILP extraction. But it costs quadratic combinational area in the
age-priority CAM and linear sequential area in the entry FFs.

## 2. Analytical IPC Model

For an independent instruction stream with ALU latency L=2 cycles and RS_DEPTH=N:

- Sustained throughput (ideal): IPC = 1.0 (one issue per cycle)
- Under a long RAW chain of depth D: effective IPC ≈ 1/L = 0.5 for D>>1

With N RS entries buffering independent instructions, the pipeline fills quickly and
the CDB keeps the FU busy. The benefit of N>L diminishes: once N > L (N > 2 for
our 2-cycle ALU), the RS can always shadow the ALU latency with independent work.

**Update — measured, not just an 8-instruction spot check.** The single-point
"8 independent instructions, IPC=0.47" estimate below has been superseded by
a full sweep in `tb/run_ipc_benchmark.py` (see the README's Benchmarks
section and `sim/bench_results/`). Measured results:

| RS_DEPTH | Independent burst IPC (N=8 -> N=256) | Pure RAW chain IPC (N=8 -> N=128) |
|----------|----------------------------------------|--------------------------------------|
| 4        | 0.62 -> 0.98                            | 0.40 -> 0.49                          |
| 8        | 0.62 -> 0.98                            | 0.40 -> 0.49                          |
| 16       | 0.62 -> 0.98                            | 0.40 -> 0.49                          |

Both curves are identical across RS_DEPTH, confirming the analytical claim
below (a single-register WAW stream or a single dependency chain never
pressures the RS, regardless of depth). Plots: `docs/images/ipc_benchmark.png`.

Old single-point estimate (kept for context): 8 independent instructions,
drain method, RS_DEPTH=4, IPC=0.47 (17 cycles for 8 instrs).

**The "mixed 50% independent" table that used to be here has been removed.**
It was an analytical estimate, never measured, and the benchmarking pass
found that general mixed-register workloads do not produce a stable IPC at
all in the current RTL — they deadlock. See
[`docs/known_issues.md`](known_issues.md) and the README's Benchmarks
section for the root cause (a RAT ready/commit conflation bug) and the
measured deadlock rate (100% of 60-instruction streams across all hazard
rates 0.0-0.8 and all RS_DEPTH values tested). The RS-depth-vs-ILP argument
below is still the right analytical intuition for *why* a deeper RS should
help a mixed workload — it just can't be validated empirically until that
bug is fixed, since any workload that would exercise it currently hangs
instead of completing.

## 3. Area Scaling (from Yosys synthesis)

Generic cell counts from `yosys prep` (pre-technology-mapping):

| RS_DEPTH | Comb. cells | Est. FFs | Total area proxy |
|----------|-------------|----------|------------------|
| 4        | 229         | 388      | 229 + 388x5 = 2,169 NAND2-eq (est.) |
| 8        | 409         | 768      | 409 + 768x5 = 4,249 NAND2-eq (est.) |
| 16       | 769         | 1,528    | 769 + 1528x5 = 8,409 NAND2-eq (est.) |

NAND2 equivalents estimated as: 1 comb cell = 1 NAND2, 1 FF = 5 NAND2.

Combinational area scales **O(RS_DEPTH)** (linear) because the CAM compares are done
in parallel and only the priority encoder adds O(N) compare chain. Sequential area
(FFs) scales exactly linearly with RS_DEPTH.

## 4. Critical Path vs RS_DEPTH

The critical path is the CAM tag comparison followed by the age-priority chain:

```
cdb_tag -> {rs_src1_tag[i] == cdb_tag} x N  (parallel, N tag compares)
        -> e_s1_rdy_now[i], e_ready_now[i]   (OR/AND per entry)
        -> min(rs_seq[k] for ready k)          (linear scan, O(N) chain)
        -> issue_idx, issue_src1, issue_valid  (mux)
```

Estimated combinational logic depth (generic cells, 500 MHz target):

| RS_DEPTH | Logic levels | Meets 500 MHz? |
|----------|-------------|----------------|
| 4        | ~12         | Yes            |
| 8        | ~14         | Yes            |
| 16       | ~17         | Marginal (over by ~0.6 ns) |

For RS_DEPTH=16 at 500 MHz, two microarchitectural options exist:
1. **Priority encoder tree:** O(log N) depth instead of O(N). Requires more area but
   closes timing.
2. **Issue pipelining:** Register the ready vector at cycle N, select the oldest in
   cycle N+1. Adds 1 cycle issue latency but allows arbitrarily deep RS.

## 5. Design Point Recommendation

For this single-FU 500 MHz design targeting AI inference workloads (long independent
MAC streams with occasional RAW hazards): **RS_DEPTH=8** is the optimal point.

- IPC headroom: 8 entries fully shadows the 2-cycle ALU latency under any workload
- Area: 420 generic cells, fits comfortably in a small tile
- Timing: ~14 logic levels, ~0.3 ns margin to 500 MHz target
- Expandability: The parameterized design scales to RS_DEPTH=16 with minor timing
  modifications (priority encoder tree or pipeline register on the issue select)

## 6. Power Consideration

Dynamic power in the RS is dominated by the CDB tag comparison, which fires every
cycle the CDB is valid. At RS_DEPTH=8 with 4-bit tags and 32-bit data:

- CDB broadcast toggles: 4+32 = 36 bits broadcast to 8 entries = 288 toggle events/cycle
- Age priority mux: 8 x 8-bit comparators active every cycle = 64 compares/cycle

For a power-constrained design, gating the tag CAM (only comparing entries where
`rs_valid[i] && !rs_s1_rdy[i]`) reduces switching activity by the fraction of
entries that are still waiting — typically 30-50% for a well-utilized RS.
