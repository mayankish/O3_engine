#!/usr/bin/env python3
"""
run_ipc_benchmark.py - Orchestrates the O3_engine IPC / stall / deadlock
benchmark suite described in docs/tradeoff_analysis.md and the README
Benchmarks section.

For each RS_DEPTH in {4, 8, 16}, compiles tb/tb_bench_ipc.v against the RTL
and runs three benchmark classes:

  1. Independent burst (tb/gen_indep.py) swept over instruction count ->
     best-case IPC vs RS_DEPTH, plus RS-full stall cycles.
  2. Pure RAW chain (tb/gen_chain.py) swept over chain length ->
     worst-case IPC vs RS_DEPTH (CDB same-cycle forwarding stress test).
  3. General mixed-hazard streams (tb/gen_stimulus.py) swept over hazard
     rate x seed -> deadlock-rate finding (see docs/known_issues.md). These
     do NOT produce a valid IPC number; the harness times out and reports
     IPC=DEADLOCK, which this script tallies as a pass/fail rate rather
     than plotting as a performance curve.

Requires: iverilog/vvp on PATH (or IVL_BIN/IVL_LIB env vars per
sim/run_sim.sh's no-root fallback convention), python3, matplotlib.

Usage:
    python3 tb/run_ipc_benchmark.py
"""
import csv
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IVL_BIN = os.environ.get("IVL_BIN", "")
IVL_LIB = os.environ.get("IVL_LIB", "")

RTL = [
    "rtl/register_alias_table.v",
    "rtl/reservation_station.v",
    "rtl/reorder_buffer.v",
    "rtl/integer_alu.v",
    "rtl/common_data_bus.v",
    "rtl/ooo_top.v",
]

RS_DEPTHS = [4, 8, 16]
INDEP_LENGTHS = [8, 16, 32, 64, 128, 256]
CHAIN_LENGTHS = [8, 16, 32, 64, 128]
HAZARD_RATES = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8]
HAZARD_SEEDS = [1, 2, 3]
HAZARD_N = 60

BENCH_DIR = os.path.join(ROOT, "sim", "bench_instrs")
RESULTS_DIR = os.path.join(ROOT, "sim", "bench_results")
IMAGES_DIR = os.path.join(ROOT, "docs", "images")

BENCH_RE = re.compile(
    r"BENCH RS_DEPTH=(\d+) ROB_DEPTH=(\d+) N=(\d+) CYCLES=(\d+) COMMITS=(\d+) "
    r"IPC=(DEADLOCK|[\d.]+) STALL_RS=(\d+) STALL_ROB=(\d+) STALL_BOTH=(\d+) FILE=(.+)"
)


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=ROOT, **kw)


def compile_bench(rs_depth):
    out = os.path.join(ROOT, "sim", f"bench_rs{rs_depth}.vvp")
    ivl = f"{IVL_BIN}iverilog"
    flags = f"-B {IVL_LIB}" if IVL_LIB else ""
    cmd = (
        f'{ivl} {flags} -DRS_DEPTH={rs_depth} -I rtl -I . '
        f'{" ".join(RTL)} tb/tb_bench_ipc.v -o {out}'
    )
    r = sh(cmd)
    if r.returncode != 0:
        print(f"COMPILE FAILED (RS_DEPTH={rs_depth}):\n{r.stdout}\n{r.stderr}")
        sys.exit(1)
    return out


def run_bench(vvp_path, instr_file):
    vvp = f"{IVL_BIN}vvp"
    flags = f"-M {IVL_LIB}" if IVL_LIB else ""
    cmd = f"{vvp} {flags} {vvp_path} +INSTR_FILE={instr_file}"
    r = sh(cmd, timeout=30)
    m = BENCH_RE.search(r.stdout)
    if not m:
        print(f"  WARNING: no BENCH line for {instr_file}\n{r.stdout[-500:]}")
        return None
    rs_depth, rob_depth, n, cycles, commits, ipc, srs, srob, sboth, fname = m.groups()
    return {
        "rs_depth": int(rs_depth), "rob_depth": int(rob_depth), "n": int(n),
        "cycles": int(cycles), "commits": int(commits),
        "ipc": None if ipc == "DEADLOCK" else float(ipc),
        "deadlock": ipc == "DEADLOCK",
        "stall_rs": int(srs), "stall_rob": int(srob), "stall_both": int(sboth),
        "file": fname,
    }


def main():
    os.makedirs(BENCH_DIR, exist_ok=True)
    os.makedirs(RESULTS_DIR, exist_ok=True)
    os.makedirs(IMAGES_DIR, exist_ok=True)

    indep_rows, chain_rows, deadlock_rows = [], [], []

    for rs_depth in RS_DEPTHS:
        print(f"=== Compiling RS_DEPTH={rs_depth} ===")
        vvp_path = compile_bench(rs_depth)

        print(f"--- Independent burst sweep (RS_DEPTH={rs_depth}) ---")
        for n in INDEP_LENGTHS:
            fpath = os.path.join(BENCH_DIR, f"indep_{n}.txt")
            if not os.path.exists(fpath):
                sh(f"python3 tb/gen_indep.py --num {n} --rd 8 > {fpath}")
            res = run_bench(vvp_path, os.path.relpath(fpath, ROOT))
            if res:
                res["workload"] = "independent"
                indep_rows.append(res)
                print(f"  N={n:4d}  IPC={res['ipc']:.4f}  stall_rs={res['stall_rs']}")

        print(f"--- Pure RAW chain sweep (RS_DEPTH={rs_depth}) ---")
        for n in CHAIN_LENGTHS:
            fpath = os.path.join(BENCH_DIR, f"chain_{n}.txt")
            if not os.path.exists(fpath):
                sh(f"python3 tb/gen_chain.py --num {n} > {fpath}")
            res = run_bench(vvp_path, os.path.relpath(fpath, ROOT))
            if res:
                res["workload"] = "chain"
                chain_rows.append(res)
                print(f"  N={n:4d}  IPC={res['ipc']:.4f}  stall_rs={res['stall_rs']}")

        print(f"--- Mixed-hazard deadlock sweep (RS_DEPTH={rs_depth}) ---")
        for hz in HAZARD_RATES:
            for seed in HAZARD_SEEDS:
                fpath = os.path.join(BENCH_DIR, f"hz{hz}_s{seed}.txt")
                if not os.path.exists(fpath):
                    sh(f"python3 tb/gen_stimulus.py --num {HAZARD_N} --seed {seed} "
                       f"--hazard {hz} --regs 32 > {fpath}")
                res = run_bench(vvp_path, os.path.relpath(fpath, ROOT))
                if res:
                    res["workload"] = "mixed"
                    res["hazard"] = hz
                    res["seed"] = seed
                    deadlock_rows.append(res)
            n_dl = sum(1 for r in deadlock_rows
                       if r["rs_depth"] == rs_depth and r["hazard"] == hz and r["deadlock"])
            print(f"  hazard={hz:.1f}  deadlocked={n_dl}/{len(HAZARD_SEEDS)}")

    # ---- Write CSVs ----
    def write_csv(rows, name, extra_fields=()):
        path = os.path.join(RESULTS_DIR, name)
        fields = ["workload", "rs_depth", "rob_depth", "n", "cycles", "commits",
                  "ipc", "deadlock", "stall_rs", "stall_rob", "stall_both", "file"] + list(extra_fields)
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            for r in rows:
                w.writerow({k: r.get(k, "") for k in fields})
        print(f"Wrote {path}")

    write_csv(indep_rows, "indep_benchmark.csv")
    write_csv(chain_rows, "chain_benchmark.csv")
    write_csv(deadlock_rows, "deadlock_benchmark.csv", extra_fields=("hazard", "seed"))

    # ---- Plots ----
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    # Plot 1: IPC vs instruction count, one line per RS_DEPTH, independent + chain
    fig, axes = plt.subplots(1, 2, figsize=(11, 4.2))
    for rs_depth in RS_DEPTHS:
        xs = [r["n"] for r in indep_rows if r["rs_depth"] == rs_depth]
        ys = [r["ipc"] for r in indep_rows if r["rs_depth"] == rs_depth]
        axes[0].plot(xs, ys, marker="o", label=f"RS_DEPTH={rs_depth}")
    axes[0].set_xlabel("Instruction count (independent burst)")
    axes[0].set_ylabel("IPC")
    axes[0].set_title("Best case: independent burst IPC")
    axes[0].set_ylim(0, 1.05)
    axes[0].legend()
    axes[0].grid(alpha=0.3)

    for rs_depth in RS_DEPTHS:
        xs = [r["n"] for r in chain_rows if r["rs_depth"] == rs_depth]
        ys = [r["ipc"] for r in chain_rows if r["rs_depth"] == rs_depth]
        axes[1].plot(xs, ys, marker="o", label=f"RS_DEPTH={rs_depth}")
    axes[1].axhline(0.5, color="gray", linestyle="--", linewidth=1, label="analytical 1/ALU_LATENCY")
    axes[1].set_xlabel("Chain length (pure RAW dependency)")
    axes[1].set_ylabel("IPC")
    axes[1].set_title("Worst case: RAW chain IPC")
    axes[1].set_ylim(0, 1.05)
    axes[1].legend()
    axes[1].grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(os.path.join(IMAGES_DIR, "ipc_benchmark.png"), dpi=130)
    print("Wrote docs/images/ipc_benchmark.png")

    # Plot 2: stall breakdown vs RS_DEPTH for the largest independent burst
    fig2, ax2 = plt.subplots(figsize=(6, 4.2))
    max_n = max(INDEP_LENGTHS)
    depths = RS_DEPTHS
    stalls = [next(r["stall_rs"] for r in indep_rows
                   if r["rs_depth"] == d and r["n"] == max_n) for d in depths]
    cycles = [next(r["cycles"] for r in indep_rows
                    if r["rs_depth"] == d and r["n"] == max_n) for d in depths]
    pct = [100.0 * s / c if c else 0 for s, c in zip(stalls, cycles)]
    ax2.bar([str(d) for d in depths], pct, color="#4C72B0")
    ax2.set_xlabel("RS_DEPTH")
    ax2.set_ylabel("% cycles stalled on rs_full")
    ax2.set_title(f"RS-full stall rate, independent burst N={max_n}")
    ax2.grid(alpha=0.3, axis="y")
    fig2.tight_layout()
    fig2.savefig(os.path.join(IMAGES_DIR, "stall_breakdown.png"), dpi=130)
    print("Wrote docs/images/stall_breakdown.png")

    # Plot 3: deadlock rate vs hazard rate
    fig3, ax3 = plt.subplots(figsize=(6.5, 4.2))
    for rs_depth in RS_DEPTHS:
        rates = []
        for hz in HAZARD_RATES:
            subset = [r for r in deadlock_rows if r["rs_depth"] == rs_depth and r["hazard"] == hz]
            n_dl = sum(1 for r in subset if r["deadlock"])
            rates.append(100.0 * n_dl / len(subset) if subset else 0)
        ax3.plot(HAZARD_RATES, rates, marker="o", label=f"RS_DEPTH={rs_depth}")
    ax3.set_xlabel("RAW hazard rate (gen_stimulus.py --hazard)")
    ax3.set_ylabel("% of streams that deadlock")
    ax3.set_title(f"Deadlock rate vs hazard rate (N={HAZARD_N} instrs, {len(HAZARD_SEEDS)} seeds)")
    ax3.set_ylim(-5, 105)
    ax3.legend()
    ax3.grid(alpha=0.3)
    fig3.tight_layout()
    fig3.savefig(os.path.join(IMAGES_DIR, "deadlock_rate.png"), dpi=130)
    print("Wrote docs/images/deadlock_rate.png")

    print("\nDone.")


if __name__ == "__main__":
    main()
