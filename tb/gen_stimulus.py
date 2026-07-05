#!/usr/bin/env python3
"""
gen_stimulus.py - Random instruction stream generator for OoO Issue Queue.

Generates a sequence of integer instructions with controlled hazard rates.
Output format (one line per instruction): "opcode rd rs1 rs2" - four
whitespace-separated integers, NO header line and NO inline comments. This
is intentional: both tb_ooo_top.v's $fscanf-based file_test and
golden_model.py's line parser expect exactly 4 tokens per line. An earlier
version of this script emitted a "# Generated ..." header line and a
trailing inline "# ADD x.., x.., x.." comment on every data line, which
made $fscanf choke on the very first line (0 conversions -> 0 instructions
silently "replayed", matching the "0 random instrs, all committed" quirk
previously noted in the O3_engine README) and made golden_model.py's
4-token check fail on every line ("expected 4 tokens, got 9"). Use --verbose
to print the human-readable mnemonics to stderr instead, if you want them
without breaking the parsers.

Usage:
    python3 gen_stimulus.py --num 100 --seed 42 --hazard 0.35 > sim/instrs.txt
    python3 gen_stimulus.py --num 200 --seed 7  --hazard 0.0  > sim/instrs_indep.txt
"""

import argparse
import random
import sys

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
    p.add_argument("--verbose", action="store_true",
                    help="Print human-readable mnemonics to stderr (stdout stays parser-clean)")
    args = p.parse_args()

    instrs = gen(args.num, args.seed, args.hazard, args.regs)

    if args.verbose:
        print(f"# Generated {args.num} instructions  seed={args.seed}  hazard={args.hazard}",
              file=sys.stderr)
    for op, rd, rs1, rs2 in instrs:
        print(f"{op} {rd} {rs1} {rs2}")
        if args.verbose:
            print(f"  # {OP_NAMES[op]} x{rd}, x{rs1}, x{rs2}", file=sys.stderr)

if __name__ == "__main__":
    main()
