# Out-of-Order Issue Queue with Scoreboard (Tomasulo-style)

**Tesla AI Hardware Portfolio - Project 3**

A parameterized, synthesizable Verilog-2001 implementation of a Tomasulo-style
out-of-order execution engine for a single integer functional unit. Demonstrates
microarchitecture specification, RTL design, area/timing analysis, and simulation
with waveform debugging.

## Architecture

```
Dispatch -> RAT (rename) -> RS (buffer, age-priority issue)
                         -> ROB (in-order commit)
                    CDB (broadcast) <- ALU (2-stage pipeline)
```

Key design features:
- Age-based oldest-first issue priority (dispatch sequence number per RS entry)
- Same-cycle CDB-to-issue operand forwarding (no 1-cycle penalty on last operand)
- WAW guard at commit (newer rename not cleared by older retiring instruction)
- One-slot-wasted ROB (no extra count register)
- Parameterized RS_DEPTH (4/8/16), synthesized and analyzed at all three points

## Directory Structure

```
ooo_issue_queue/
  rtl/
    defines.vh              - Global parameters and opcode encodings
    integer_alu.v           - 2-stage pipelined ALU (ADD/SUB/MUL/SHL/SHR)
    common_data_bus.v       - CDB combinational passthrough
    register_alias_table.v  - RAT with rename, CDB forwarding, WAW guard
    reservation_station.v   - Age-priority RS with CAM tag snoop
    reorder_buffer.v        - Circular ROB, in-order commit
    ooo_top.v               - Top-level: decode, dispatch, auto-commit
  tb/
    tb_ooo_top.v            - Integration testbench (5 tests, shadow RF check)
    tb_reservation_station.v - RS unit testbench (5 tests)
    tb_reorder_buffer.v     - ROB unit testbench (4 tests)
    tb_rat.v                - RAT unit testbench (5 tests)
    golden_model.py         - In-order reference model
    gen_stimulus.py         - Random instruction generator (RAW hazard knob)
  sim/
    run_sim.sh              - Compile and run all testbenches
    run_all_tests.sh        - Generate stimuli + regression against golden model
    waves/                  - VCD waveform output directory
  synth/
    synth_rs{4,8,16}.ys    - Yosys synthesis scripts
    constraints.sdc         - SDC timing constraints (500 MHz target)
    reports/
      area_rs{4,8,16}.rpt  - Area reports (generic cells, pre-mapping)
      timing_summary.md    - Critical path analysis and scaling
  docs/
    microarch_spec.md       - Full architecture description
    tradeoff_analysis.md    - RS depth vs IPC vs area trade-off
    signal_interface_table.md - Complete port reference
```

## Simulation

Requires iverilog >= 10.0.

```bash
# Run all testbenches
bash sim/run_sim.sh

# Random regression (64 instructions, 40% RAW hazard rate)
bash sim/run_all_tests.sh --num 64 --seed 42 --hazard 0.4
```

No-root iverilog install (if `apt install` unavailable):
```bash
dpkg-deb -x iverilog_11.0-1.1_amd64.deb /tmp/ivl
export IVL_BIN=/tmp/ivl/usr/bin/
export IVL_LIB=/tmp/ivl/usr/lib/x86_64-linux-gnu/ivl
bash sim/run_sim.sh
```

### Simulation Results

```
RAT unit:  5/5 PASS  - rename, in-flight, WAW guard, CDB forwarding, flush
ROB unit:  4/4 PASS  - fill-to-full, OoO complete, in-order commit, flush
RS  unit:  5/5 PASS  - fill/flush, dispatch+issue, CDB capture, age priority
OoO top:   5/5 PASS  - RAW chain, WAW, IPC burst, flush, random regression
```

## Synthesis

Requires yosys >= 0.23 with abc.

```bash
cd synth
yosys synth_rs8.ys   # synthesize RS_DEPTH=8 (default)
yosys synth_rs4.ys   # synthesize RS_DEPTH=4
yosys synth_rs16.ys  # synthesize RS_DEPTH=16
```

### Area Summary (generic cells, before tech-mapping)

| RS_DEPTH | Comb. cells | Est. FFs | Critical path | Meets 500 MHz |
|----------|-------------|----------|---------------|---------------|
| 4        | 229         | 388      | ~12 levels    | Yes           |
| 8        | 409         | 768      | ~14 levels    | Yes           |
| 16       | 769         | 1,528    | ~17 levels    | Marginal      |

Full `ooo_top` (RS=8, ROB=16): **865 generic cells**.

Combinational area scales linearly with RS_DEPTH (dominated by CAM tag comparators
and age-priority muxes). RS_DEPTH=8 is the recommended operating point for 500 MHz.
See `synth/reports/timing_summary.md` for critical path breakdown.

## Performance

Single-issue engine with 2-cycle integer ALU:
- Steady-state IPC (independent stream, saturated RS): 1.0
- Measured IPC (8 independent instructions, drain method): 0.47
- RAW chain of depth D: effective IPC ≈ 1/2 for D >> 1

The RS hides ALU latency for independent instructions. Once RS_DEPTH > ALU_LATENCY
(> 2), additional depth provides diminishing IPC returns for a single FU.
See `docs/tradeoff_analysis.md` for quantitative IPC vs area trade-off.

## Design Notes

**Why oldest-first?** Age-based priority prevents starvation and is the standard
choice for out-of-order CPUs. The dispatch_seq counter assigns a monotonically
increasing number at dispatch; the RS issue logic picks the minimum seq among all
ready entries. Cost: O(RS_DEPTH) comparators in the priority select loop.

**Why same-cycle CDB forwarding?** Without it, an instruction whose last operand
arrives on the CDB must wait an extra cycle before issuing. For a 2-cycle ALU, this
would reduce the effective IPC ceiling by ~10% under high-dependency workloads.

**Why Verilog-2001?** Broadest synthesizer compatibility. No SystemVerilog features
are required; all synthesis-critical constructs (generate blocks, `$clog2`, packed
arrays) are V-2001 compliant.
