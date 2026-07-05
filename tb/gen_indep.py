#!/usr/bin/env python3
"""
gen_indep.py - Independent-instruction-burst generator for OoO Issue Queue benchmarks.

Every instruction is ADD xD, x0, x0 for a fixed destination register D - i.e.
zero cross-instruction RAW dependency (sources are always the hardwired x0).
This is the same pattern as tb_ooo_top.v's TEST 3 (independent burst / IPC
measurement), extended to arbitrary length so it can be swept across
RS_DEPTH. It intentionally reuses one destination register so the only
hazard type present is WAW, which is unit-tested (TEST 2) and does not
trigger the completed-but-not-committed RAW race documented in
docs/known_issues.md - this generator gives a clean best-case IPC number
uncontaminated by that bug.

Usage:
    python3 gen_indep.py --num 64 --rd 8 > sim/bench_instrs/indep64.txt
"""
import argparse

def main():
    p = argparse.ArgumentParser(description="Independent burst generator")
    p.add_argument("--num", type=int, default=64, help="Number of instructions")
    p.add_argument("--rd",  type=int, default=8,  help="Destination register (WAW only)")
    args = p.parse_args()

    for _ in range(args.num):
        print(f"0 {args.rd} 0 0")

if __name__ == "__main__":
    main()
