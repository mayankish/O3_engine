#!/usr/bin/env bash
# run_sim.sh - Compile and run all OoO Issue Queue testbenches
# Usage:  ./sim/run_sim.sh [--waves]
#
# Requires: iverilog >= 10.0 on PATH
#   No-root fallback: export IVL_BIN=/path/to/ivl/usr/bin
#                     export IVL_LIB=/path/to/ivl/usr/lib/.../ivl

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."

IVL="${IVL_BIN:-}iverilog"
VVP="${IVL_BIN:-}vvp"
IVL_FLAGS=()
if [[ -n "${IVL_LIB:-}" ]]; then
    IVL_FLAGS+=(-B "$IVL_LIB")
    VVP_FLAGS=(-M "$IVL_LIB")
else
    VVP_FLAGS=()
fi

WAVES=${1:-}
FAIL=0
PASS=0

mkdir -p "$ROOT/sim/waves"

run_tb() {
    local label="$1" out="$2"; shift 2
    printf "\n\033[1;34m=== %s ===\033[0m\n" "$label"
    if ! "$IVL" "${IVL_FLAGS[@]}" "$@" -o "$ROOT/sim/$out" 2>&1; then
        echo "  COMPILE FAILED"
        FAIL=$((FAIL+1))
        return
    fi
    "$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/$out"
    if grep -q "RESULT: PASS" <<< "$("$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/$out" 2>&1)"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
}

RTL=(
    "$ROOT/rtl/register_alias_table.v"
    "$ROOT/rtl/reservation_station.v"
    "$ROOT/rtl/reorder_buffer.v"
    "$ROOT/rtl/integer_alu.v"
    "$ROOT/rtl/common_data_bus.v"
    "$ROOT/rtl/ooo_top.v"
)
INC=(-I "$ROOT/rtl" -I "$ROOT")

# Unit testbenches
"$IVL" "${IVL_FLAGS[@]}" "${INC[@]}" \
    "$ROOT/rtl/register_alias_table.v" \
    "$ROOT/tb/tb_rat.v" \
    -o "$ROOT/sim/rat_tb.vvp"
printf "\n\033[1;34m=== RAT unit ===\033[0m\n"
"$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/rat_tb.vvp"

"$IVL" "${IVL_FLAGS[@]}" "${INC[@]}" \
    "$ROOT/rtl/reorder_buffer.v" \
    "$ROOT/tb/tb_reorder_buffer.v" \
    -o "$ROOT/sim/rob_tb.vvp"
printf "\n\033[1;34m=== ROB unit ===\033[0m\n"
"$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/rob_tb.vvp"

"$IVL" "${IVL_FLAGS[@]}" "${INC[@]}" -DRS_DEPTH=4 \
    "$ROOT/rtl/reservation_station.v" \
    "$ROOT/tb/tb_reservation_station.v" \
    -o "$ROOT/sim/rs_tb.vvp"
printf "\n\033[1;34m=== RS unit (depth=4) ===\033[0m\n"
"$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/rs_tb.vvp"

# Integration testbench
"$IVL" "${IVL_FLAGS[@]}" "${INC[@]}" \
    "${RTL[@]}" "$ROOT/tb/tb_ooo_top.v" \
    -o "$ROOT/sim/ooo_tb.vvp"
printf "\n\033[1;34m=== OoO top integration ===\033[0m\n"
"$VVP" "${VVP_FLAGS[@]}" "$ROOT/sim/ooo_tb.vvp"

printf "\n\033[1;32mAll simulations complete.\033[0m\n"
