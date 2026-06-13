#!/usr/bin/env bash
# run_all_tests.sh - Generate random stimuli, simulate, compare against golden model
# Usage:  ./sim/run_all_tests.sh [--num N] [--seed S] [--hazard P]
#
# Requires: iverilog, python3 on PATH

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NUM=64
SEED=42
HAZARD=0.4

while [[ $# -gt 0 ]]; do
    case $1 in
        --num)    NUM=$2; shift 2 ;;
        --seed)   SEED=$2; shift 2 ;;
        --hazard) HAZARD=$2; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

IVL="${IVL_BIN:-}iverilog"
VVP="${IVL_BIN:-}vvp"
IVL_FLAGS=()
VVP_FLAGS=()
if [[ -n "${IVL_LIB:-}" ]]; then
    IVL_FLAGS+=(-B "$IVL_LIB")
    VVP_FLAGS+=(-M "$IVL_LIB")
fi

mkdir -p "$ROOT/sim/waves"

echo "Generating $NUM instructions (seed=$SEED, hazard=$HAZARD)..."
python3 "$ROOT/tb/gen_stimulus.py" \
    --num "$NUM" --seed "$SEED" --hazard "$HAZARD" \
    --regs 16 \
    > "$ROOT/sim/instrs.txt"

echo "Running golden model..."
python3 "$ROOT/tb/golden_model.py" "$ROOT/sim/instrs.txt" \
    > "$ROOT/sim/golden.txt"

echo "Compiling integration TB..."
"$IVL" "${IVL_FLAGS[@]}" -I "$ROOT/rtl" -I "$ROOT" \
    "$ROOT/rtl/register_alias_table.v" \
    "$ROOT/rtl/reservation_station.v" \
    "$ROOT/rtl/reorder_buffer.v" \
    "$ROOT/rtl/integer_alu.v" \
    "$ROOT/rtl/common_data_bus.v" \
    "$ROOT/rtl/ooo_top.v" \
    "$ROOT/tb/tb_ooo_top.v" \
    -o "$ROOT/sim/ooo_tb.vvp"

echo "Running simulation..."
"$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/ooo_tb.vvp" 2>&1

echo ""
echo "Simulation complete.  Golden model output:"
cat "$ROOT/sim/golden.txt"
