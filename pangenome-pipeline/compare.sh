#!/bin/bash
# =============================================================================
# Compare a query run's outputs against a reference (md5 + size).
#
# Usage:  ./compare.sh <config.env> <index-tag> <query-name> [ref-query-dir]
#
#   config.env     — see configs/*.env (for $BASE, $REF_DIR, $REF_BASE)
#   index-tag      — runs/<index-tag>/ (our run)
#   query-name     — runs/<index-tag>/queries/<query-name>/ (our query)
#   ref-query-dir  — absolute path to the reference QUERY directory, OR
#                    a name resolved against $REF_DIR. Default: $REF_DIR
#                    from config + same query-name.
#
# Index files (runs/<tag>/<BASE>.*) are compared by md5+size.
# Query files (queries/<q>/{mems_*.{bin,out},alignment.*}) similarly.
# .gaf / _coverage.csv use set-equality (sorted line diff) since row order
# is unstable across find_mems / gafpack versions.
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

[ $# -ge 3 ] || { echo "Usage: $0 <config.env> <index-tag> <query-name> [ref-query-dir]"; exit 2; }
CONFIG="$1"; [ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"

INDEX_TAG="$2"
QUERY_NAME="$3"
RUN_INDEX_DIR="$PIPE_DIR/runs/$INDEX_TAG"
RUN_QUERY_DIR="$RUN_INDEX_DIR/queries/$QUERY_NAME"

# ---- Reference layout resolution ------------------------------------------
# Optional 4th arg lets the user point at a specific ref query dir directly
# (handy when the reference uses an unrelated tag/name). Otherwise default to:
#   $REF_DIR  (must be set in config) + queries/$QUERY_NAME
REF_QUERY_DIR="${4:-}"
if [ -z "$REF_QUERY_DIR" ]; then
    [ -n "${REF_DIR:-}" ] || { echo "ERROR: no 4th arg and config doesn't set REF_DIR"; exit 2; }
    REF_QUERY_DIR="$REF_DIR/queries/$QUERY_NAME"
fi
# REF_INDEX_DIR is the parent of the query dir
REF_INDEX_DIR="$(dirname "$(dirname "$REF_QUERY_DIR")")"

[ -d "$RUN_INDEX_DIR" ] || { echo "Index dir not found: $RUN_INDEX_DIR"; exit 1; }
[ -d "$RUN_QUERY_DIR" ] || { echo "Query dir not found: $RUN_QUERY_DIR"; exit 1; }
[ -d "$REF_INDEX_DIR" ] || { echo "Reference index dir not found: $REF_INDEX_DIR"; exit 1; }
[ -d "$REF_QUERY_DIR" ] || { echo "Reference query dir not found: $REF_QUERY_DIR"; exit 1; }

RB="${REF_BASE:-$BASE}"

# ---- Cross-platform helpers ----------------------------------------------
fsize() {
    # File size in bytes. Handles macOS BSD stat and Linux GNU stat.
    stat -Lc%s "$1" 2>/dev/null || stat -Lf%z "$1" 2>/dev/null || wc -c < "$1"
}
fmd5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    else
        md5 -q "$1"
    fi
}

cmp_file() {
    local label="$1" new="$2" ref="$3"
    if [ ! -f "$new" ]; then printf "  %-32s NEW MISSING\n" "$label"; return; fi
    if [ ! -f "$ref" ]; then printf "  %-32s REF MISSING (new=%s)\n" "$label" "$(fsize "$new")"; return; fi
    local ns rs; ns=$(fsize "$new"); rs=$(fsize "$ref")
    if [ "$ns" = "$rs" ] && [ "$(fmd5 "$new")" = "$(fmd5 "$ref")" ]; then
        printf "  %-32s IDENTICAL  (%14d B)\n" "$label" "$ns"
    else
        printf "  %-32s DIFFER     new=%14d  ref=%14d\n" "$label" "$ns" "$rs"
    fi
}

cmp_sorted() {
    # Row order is unstable across find_mems / gafpack versions; compare line *sets*.
    local label="$1" new="$2" ref="$3"
    if [ ! -f "$new" ]; then printf "  %-32s NEW MISSING\n" "$label"; return; fi
    if [ ! -f "$ref" ]; then printf "  %-32s REF MISSING (new=%s)\n" "$label" "$(fsize "$new")"; return; fi
    local d; d=$(diff <(sort "$new") <(sort "$ref") | wc -l | tr -d ' ')
    if [ "$d" = "0" ]; then
        printf "  %-32s SET-EQUAL  (%14d B)\n" "$label" "$(fsize "$new")"
    else
        printf "  %-32s SET-DIFFER (%s diff lines)\n" "$label" "$d"
    fi
}

echo "Run:       index=$RUN_INDEX_DIR  query=$QUERY_NAME"
echo "Reference: index=$REF_INDEX_DIR  query=$(basename "$REF_QUERY_DIR")"
echo

# ---- Index files (parent dirs) --------------------------------------------
echo "=== Index files (runs/<tag>/) ==="
cmp_file ".seq"               "$RUN_INDEX_DIR/${BASE}.seq"               "$REF_INDEX_DIR/${RB}.seq"
cmp_file ".rl_bwt"            "$RUN_INDEX_DIR/${BASE}.rl_bwt"            "$REF_INDEX_DIR/${RB}.rl_bwt"
cmp_file ".ri"                "$RUN_INDEX_DIR/${BASE}.ri"                "$REF_INDEX_DIR/${RB}.ri"
cmp_file ".tags"              "$RUN_INDEX_DIR/${BASE}.tags"              "$REF_INDEX_DIR/${RB}.tags"
cmp_file "_compressed.tags"   "$RUN_INDEX_DIR/${BASE}_compressed.tags"   "$REF_INDEX_DIR/${RB}_compressed.tags"
cmp_file ".ltags"             "$RUN_INDEX_DIR/${BASE}.ltags"             "$REF_INDEX_DIR/${RB}.ltags"
cmp_file ".paths"             "$RUN_INDEX_DIR/${BASE}.paths"             "$REF_INDEX_DIR/${RB}.paths"
cmp_file ".gfa"               "$RUN_INDEX_DIR/${BASE}.gfa"               "$REF_INDEX_DIR/${RB}.gfa"

echo
echo "=== Query files (runs/<tag>/queries/<query>/) ==="
cmp_file "mems_seq_id_starts.out" "$RUN_QUERY_DIR/mems_seq_id_starts.out" "$REF_QUERY_DIR/mems_seq_id_starts.out"

BIN="$RUN_QUERY_DIR/mems_path_pos_v2.bin"
if [ -f "$BIN" ]; then
    bs=$(fsize "$BIN")
    printf "  %-32s %14d B  (%d records × 16)\n" "mems_path_pos_v2.bin" "$bs" "$((bs / 16))"
fi

cmp_sorted "alignment.gaf"            "$RUN_QUERY_DIR/alignment.gaf"            "$REF_QUERY_DIR/alignment.gaf"
cmp_sorted "alignment_coverage.csv"   "$RUN_QUERY_DIR/alignment_coverage.csv"   "$REF_QUERY_DIR/alignment_coverage.csv"
