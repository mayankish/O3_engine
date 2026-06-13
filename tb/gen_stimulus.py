#!/usr/bin/env python3
"""
gen_stimulus.py — Random instruction stream generator for OoO Issue Queue.

Generates a sequence of integer instructions with controlled hazard rates.
Output format (one line per instruction): "opcode rd rs1 rs2"
where opcode = 0..4 (ADD SUB MUL SHL SHR), registers = 1..31 (never x0 as dest).

Usage:
    python3 gen_stimulus.py --num 100 --seed 42 --hazard 0.35 > sim/instrs.txt
    python3 gen_stimulus.py --num 200 --seed 7  --hazard 0.0  > sim/instrs_indep.txt
"""

import argparse
import random

OP_NAMES = {0: "ADD", 1: "SUB", 2: "MUL", 3: "SHL", 4: "SHR"}
NUM_OPS  = len(OP_NAMES)

def gen(num_instrs: int, seed: int, hazard_rate: float, num_regs: int = 32):
    rng = random.Random(seed)
    instructions = []
    # Track which registers have been written (available as sources with known values)
    written_regs = set()

    for i in range(num_instrs):
        op  = rng.randint(0, NUM_OPS - 1)
        rd  = rng.randint(1, num_regs - 1)   # never x0 as destination

        # Source registers: with hazard_rate chance, pick a recently-written reg
        # to create a RAW hazard; otherwise pick any register.
        def pick_src():
            if written_regs and rng.random() < hazard_rate:
                # RAW hazard: pick one of the recently-written registers
                candidates = list(written_regs)[-8:]  # last 8 written
                return rng.choice(candidates)
            else:
                return rng.randint(0, num_regs - 1)

        rs1 = pick_src()
        rs2 = pick_src()

        instructions.append((op, rd, rs1, rs2))
        written_regs.add(rd)

    return instructions

def main():
    p = argparse.ArgumentParser(description="OoO stimulus generator")
    p.add_argument("--num",    type=int,   default=100,  help="Number of instructions")
    p.add_argument("--seed",   type=int,   default=42,   help="RNG seed")
    p.add_argument("--hazard", type=float, default=0.35, help="RAW hazard probability [0,1]")
    p.add_argument("--regs",   type=int,   default=32,   help="Architectural register count")
    args = p.parse_args()

    instrs = gen(args.num, args.seed, args.hazard, args.regs)

    print(f"# Generated {args.num} instructions  seed={args.seed}  hazard={args.hazard}")
    for op, rd, rs1, rs2 in instrs:
        print(f"{op} {rd} {rs1} {rs2}  # {OP_NAMES[op]} x{rd}, x{rs1}, x{rs2}")

if __name__ == "__main__":
    main()
