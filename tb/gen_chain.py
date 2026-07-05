#!/usr/bin/env python3
"""
gen_chain.py - Pure RAW dependency-chain generator for OoO Issue Queue benchmarks.

Every instruction reads the register the previous instruction just wrote,
producing a strict linear RAW chain (100% dependency rate) - the true
worst case for CDB same-cycle forwarding. Complements gen_stimulus.py's
probabilistic hazard rate, which approximates but does not guarantee a
pure chain. Output format matches gen_stimulus.py: 4 whitespace-separated
integers per line, no header, no inline comments.

Usage:
    python3 gen_chain.py --num 64 > sim/bench_instrs/chain64.txt
"""
import argparse

def main():
    p = argparse.ArgumentParser(description="Pure RAW chain generator")
    p.add_argument("--num", type=int, default=64, help="Chain length")
    args = p.parse_args()

    prev_rd = 0  # x0 = 0, first instruction reads x0
    for i in range(args.num):
        rd = (i % 31) + 1
        print(f"0 {rd} {prev_rd} 0")
        prev_rd = rd

if __name__ == "__main__":
    main()
