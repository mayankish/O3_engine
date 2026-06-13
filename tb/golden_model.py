#!/usr/bin/env python3
"""
golden_model.py — In-order reference model for the OoO Issue Queue.

Reads instructions from a text file (one per line: "opcode rd rs1 rs2")
where opcode is an integer 0-4 (ADD SUB MUL SHL SHR).
Simulates all instructions in program order and writes the final
committed register state to stdout in format: "xNN=0xVALUE".

Usage:
    python3 golden_model.py sim/instrs.txt > sim/golden.txt
    python3 golden_model.py sim/instrs.txt          # prints to stdout
"""

import sys
import struct

MASK32 = 0xFFFF_FFFF

OP_ADD = 0
OP_SUB = 1
OP_MUL = 2
OP_SHL = 3
OP_SHR = 4

def to_signed32(v):
    v = v & MASK32
    return struct.unpack('>i', struct.pack('>I', v))[0]

def add32(a, b):  return (a + b) & MASK32
def sub32(a, b):  return (a - b) & MASK32
def mul32(a, b):  return (to_signed32(a) * to_signed32(b)) & MASK32
def shl32(a, b):  return (a << (b & 0x1F)) & MASK32
def shr32(a, b):  return (to_signed32(a) >> (b & 0x1F)) & MASK32

OPS = {OP_ADD: add32, OP_SUB: sub32, OP_MUL: mul32,
       OP_SHL: shl32, OP_SHR: shr32}

def simulate(filepath):
    rf = [0] * 32  # x0 is always 0 (architectural zero register)

    with open(filepath) as f:
        for lineno, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) != 4:
                print(f"[golden] WARNING line {lineno}: expected 4 tokens, got {len(parts)}", file=sys.stderr)
                continue
            try:
                op, rd, rs1, rs2 = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
            except ValueError:
                print(f"[golden] WARNING line {lineno}: parse error", file=sys.stderr)
                continue

            if op not in OPS:
                continue  # NOP / unsupported

            src1 = rf[rs1]
            src2 = rf[rs2]
            result = OPS[op](src1, src2)

            # x0 is hardwired to 0 — writes are silently discarded
            if rd != 0:
                rf[rd] = result

    return rf

def main():
    if len(sys.argv) < 2:
        print("Usage: golden_model.py <instrs.txt>", file=sys.stderr)
        sys.exit(1)

    rf = simulate(sys.argv[1])
    for i in range(1, 32):  # skip x0
        if rf[i] != 0:
            print(f"x{i}=0x{rf[i]:08x}")

if __name__ == "__main__":
    main()
