#!/bin/bash
# Compare a run's outputs against a reference directory (md5 + size).
# Usage:  ./compare.sh <config.env> <run-tag> [ref-dir]
#   ref-dir defaults to $REF_DIR from the config.
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

[ $# -ge 2 ] || { echo "Usage: $0 <config.env> <run-tag> [ref-dir]"; exit 2; }
CONFIG="$1"; [ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
# shellcheck source=/dev/null
source "$CONFIG"
RUN_DIR="$PIPE_DIR/runs/$2"
REF="${3:-${REF_DIR:-}}"
[ -d "$RUN_DIR" ] || { echo "Run dir not found: $RUN_DIR"; exit 1; }
[ -d "$REF" ]     || { echo "Reference dir not found: $REF"; exit 1; }

RB="${REF_BASE:-$BASE}"
RO="${REF_OUT:-$OUT}"

cmp_file() {
    local label="$1" new="$RUN_DIR/$2" ref="$REF/$3"
    if [ ! -f "$new" ]; then printf "%-22s NEW MISSING\n" "$label"; return; fi
    if [ ! -f "$ref" ]; then printf "%-22s REF MISSING (new=%s)\n" "$label" "$(stat -Lf%z "$new")"; return; fi
    local ns rs; ns=$(stat -Lf%z "$new"); rs=$(stat -Lf%z "$ref")
    if [ "$ns" = "$rs" ] && [ "$(md5 -q "$new")" = "$(md5 -q "$ref")" ]; then
        printf "%-22s IDENTICAL  (%'14d B)\n" "$label" "$ns"
    else
        printf "%-22s DIFFER     new=%'14d  ref=%'14d\n" "$label" "$ns" "$rs"
    fi
}

cmp_sorted() {
    # Row order is unstable across find_mems versions; compare line *sets*.
    local label="$1" new="$RUN_DIR/$2" ref="$REF/$3"
    if [ ! -f "$new" ]; then printf "%-22s NEW MISSING\n" "$label"; return; fi
    if [ ! -f "$ref" ]; then printf "%-22s REF MISSING (new=%s)\n" "$label" "$(stat -Lf%z "$new")"; return; fi
    local d; d=$(diff <(sort "$new") <(sort "$ref") | wc -l | tr -d ' ')
    if [ "$d" = "0" ]; then
        printf "%-22s SET-EQUAL  (%'14d B)\n" "$label" "$(stat -Lf%z "$new")"
    else
        printf "%-22s SET-DIFFER (%s diff lines)\n" "$label" "$d"
    fi
}

echo "Run:       $RUN_DIR"
echo "Reference: $REF"
echo
cmp_file ".seq"               "${BASE}.seq"               "${RB}.seq"
cmp_file ".rl_bwt"            "${BASE}.rl_bwt"            "${RB}.rl_bwt"
cmp_file ".ri"                "${BASE}.ri"                "${RB}.ri"
cmp_file ".tags"              "${BASE}.tags"              "${RB}.tags"
cmp_file "_compressed.tags"   "${BASE}_compressed.tags"   "${RB}_compressed.tags"
cmp_file ".paths"             "${BASE}.paths"             "${RB}.paths"
cmp_file "_seq_id_starts.out" "${OUT}_seq_id_starts.out"  "${RO}_seq_id_starts.out"

BIN="$RUN_DIR/${OUT}_path_pos_v2.bin"
if [ -f "$BIN" ]; then
    bs=$(stat -Lf%z "$BIN")
    printf "%-22s %'14d B  (%d records × 16)\n" "_path_pos_v2.bin" "$bs" "$((bs / 16))"
fi
cmp_sorted ".gaf"             "${OUT}.gaf"                "${RO}.gaf"
cmp_sorted "_coverage.csv"    "${OUT}_coverage.csv"       "${RO}_coverage.csv"
