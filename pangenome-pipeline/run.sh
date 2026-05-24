#!/bin/bash
# =============================================================================
# pangenome-index pipeline driver
#
# Usage:  ./run.sh <config.env> [run-tag]
#   config.env  — see configs/*.env for the variable contract
#   run-tag     — output dir name under runs/ (default: today's date)
#
# Outputs land in runs/<tag>/ ; per-step logs in runs/<tag>/logs/.
# Each build step is guarded by [ -f <output> ] so re-invocation resumes.
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Tool locations (override via env if needed) ---------------------------
PI_BIN="${PI_BIN:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin}"
GAFPACK="${GAFPACK:-gafpack}"
GRLBWT="${GRLBWT:-grlbwt-cli}"
GBZ_STATS="${GBZ_STATS:-gbz_stats}"
GBZ_EXTRACT="${GBZ_EXTRACT:-gbz_extract}"
VALIDATE_GAF="${VALIDATE_GAF:-$MEM_PROJ/scripts/validate_gaf_v2.py}"

# /usr/bin/time -l on some macOS hosts fails with
#   "time: sysctl kern.clockrate: Operation not permitted"
# and always exits 1 -- which would make every pipeline step look failed.
# Prefer GNU time (`gtime`, brew install gnu-time) which reports wall + RSS
# reliably; fall back to `/usr/bin/time` without -l (no RSS).
if command -v gtime >/dev/null 2>&1; then
    TIME="gtime -v"
    TIME_FLAVOR="gtime"
else
    TIME="/usr/bin/time"
    TIME_FLAVOR="bsd"
fi

# ---- Args ------------------------------------------------------------------
[ $# -ge 1 ] || { echo "Usage: $0 <config.env> [run-tag]"; exit 2; }
CONFIG="$1"
[ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }
TAG="${2:-$(date +%Y-%m-%d)}"

# shellcheck source=/dev/null
source "$CONFIG"

RUN_DIR="$PIPE_DIR/runs/$TAG"
LOGS="$RUN_DIR/logs"
mkdir -p "$LOGS"
cd "$RUN_DIR"

# Record provenance
{
    echo "Run:        $TAG"
    echo "Config:     $CONFIG"
    echo "Started:    $(date)"
    echo "Host:       $(hostname)"
    echo "PI_BIN:     $PI_BIN"
    echo "GAFPACK:    $GAFPACK"
    git -C "$(dirname "$PI_BIN")" log -1 --format='PI commit:  %h %ci %s' 2>/dev/null || true
    (cd "$(dirname "$GAFPACK")" 2>/dev/null && git log -1 --format='GP commit:  %h %ci %s') 2>/dev/null || true
} > "$RUN_DIR/RUN_INFO.txt"
ln -sfn "$CONFIG" "$RUN_DIR/config.env"

TIMING="$LOGS/timing_summary.txt"
: > "$TIMING"

summarize_timing() {
    # Rebuild from all logs/*.time so re-runs (which skip steps) still show full history.
    # Handles both BSD /usr/bin/time output (" 12.34 real ... maximum resident set size <bytes>")
    # and GNU `gtime -v` output ("Elapsed (wall clock) time ... Maximum resident set size (kbytes): N").
    echo "# step                  wall_s  maxrss_MB"
    for t in "$LOGS"/[0-9][0-9]_*.time; do
        [ -f "$t" ] || continue
        local name; name=$(basename "$t" .time)
        local wall rss
        # BSD: "        1.23 real         0.45 user"
        wall=$(awk '/ real /{print int($1+0.5); found=1; exit} END{if(!found) print ""}' "$t")
        # GNU: "Elapsed (wall clock) time (h:mm:ss or m:ss): 0:01.23"
        if [ -z "$wall" ]; then
            wall=$(awk -F': ' '/Elapsed \(wall clock\)/{split($2, a, ":"); n=length(a);
                                if (n==2) {print int(a[1]*60 + a[2] + 0.5)}
                                else if (n==3) {print int(a[1]*3600 + a[2]*60 + a[3] + 0.5)}}' "$t")
        fi
        # BSD: "<bytes> maximum resident set size" (bytes on macOS)
        rss=$(awk '/maximum resident set size/{print int($1/1024/1024)}' "$t")
        # GNU: "Maximum resident set size (kbytes): N"  (always KB regardless of OS)
        if [ -z "$rss" ]; then
            rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$t")
        fi
        printf "%-22s %7s %10s\n" "$name" "${wall:-FAIL}" "${rss:--}"
    done
}

# Extract maxrss in MB from a time log produced by either BSD time or `gtime -v`.
# Returns "" if neither pattern is present (some hosts deny /usr/bin/time stats).
extract_rss_mb() {
    local tlog="$1" rss
    # BSD: "<bytes> maximum resident set size" (macOS reports bytes)
    rss=$(awk '/maximum resident set size/{print int($1/1024/1024); exit}' "$tlog")
    if [ -z "$rss" ]; then
        # GNU `gtime -v`: "  Maximum resident set size (kbytes): N"
        rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024); exit}' "$tlog")
    fi
    echo "${rss:-0}"
}

profile() {
    local name="$1"; shift
    local log="$LOGS/${name}.log" tlog="$LOGS/${name}.time"
    echo ">>> [$name] $*"
    local t0=$SECONDS
    if $TIME "$@" >"$log" 2>"$tlog"; then
        local dt=$((SECONDS - t0))
        local rss; rss=$(extract_rss_mb "$tlog")
        printf "    OK  %5ds  %6dMB\n" "$dt" "$rss"
        printf "%-20s %6d %8d\n" "$name" "$dt" "$rss" >> "$TIMING"
    else
        local rc=$?
        printf "%-20s FAILED (exit %d)\n" "$name" "$rc" >> "$TIMING"
        echo "    FAIL (exit $rc) — see $tlog"; cat "$tlog"; exit $rc
    fi
}

profile_redirect() {
    local name="$1" outfile="$2"; shift 2
    local tlog="$LOGS/${name}.time"
    echo ">>> [$name] $* > $outfile"
    local t0=$SECONDS
    if $TIME "$@" >"$outfile" 2>"$tlog"; then
        local dt=$((SECONDS - t0))
        local rss; rss=$(extract_rss_mb "$tlog")
        printf "    OK  %5ds  %6dMB  -> %s (%s)\n" "$dt" "$rss" "$outfile" "$(du -h "$outfile" | cut -f1)"
        printf "%-20s %6d %8d\n" "$name" "$dt" "$rss" >> "$TIMING"
    else
        local rc=$?
        printf "%-20s FAILED (exit %d)\n" "$name" "$rc" >> "$TIMING"
        echo "    FAIL (exit $rc) — see $tlog"; cat "$tlog"; exit $rc
    fi
}

echo "=== Input check ==="
for f in "$GBZ" "$GFA" "$READS"; do
    [ -e "$f" ] || { echo "Missing input: $f"; exit 1; }
    printf "  %-8s %s (%s)\n" "$(basename "$f"):" "$f" "$(du -h "$f" | cut -f1)"
done
echo

# === Index build ============================================================
echo "=== 01 gbz_stats ==="
profile 01_gbz_stats "$GBZ_STATS" -i "$GBZ"
NUM_SEQ=$(awk '/^Sequences:/ {print $2}' "$LOGS/01_gbz_stats.log")
[ -n "$NUM_SEQ" ] || { echo "Could not parse NUM_SEQ from gbz_stats"; exit 1; }
echo "    NUM_SEQ=$NUM_SEQ"

echo "=== 02 gbz_extract ==="
[ -f "${BASE}.seq" ] || profile_redirect 02_gbz_extract "${BASE}.seq" "$GBZ_EXTRACT" -b -t "$THREADS" -p "$GBZ"

echo "=== 03 grlbwt ==="
[ -f "${BASE}.rl_bwt" ] || profile 03_grlbwt "$GRLBWT" "${BASE}.seq" -t "$THREADS" -o "${BASE}.rl_bwt"

echo "=== 04 build_rindex ==="
[ -f "${BASE}.ri" ] || profile_redirect 04_build_rindex "${BASE}.ri" "$PI_BIN/build_rindex" "${BASE}.rl_bwt"

echo "=== 05 build_tags (k=$KMER) ==="
[ -f "${BASE}.tags" ] || profile 05_build_tags "$PI_BIN/build_tags" -k "$KMER" "$GBZ" "${BASE}.rl_bwt" "${BASE}.tags"

echo "=== 06 convert_tags (--num-seq $NUM_SEQ) ==="
# REQUIRED: convert_tags strips endmarker runs unconditionally and only re-prepends
# them when --num-seq is given. Omitting it shifts every BWT-position lookup. See CLAUDE.md.
[ -f "${BASE}_compressed.tags" ] || profile 06_convert_tags "$PI_BIN/convert_tags" "${BASE}.tags" "${BASE}_compressed.tags" --num-seq "$NUM_SEQ"

echo "=== 07 path_extract ==="
[ -f "${BASE}.paths" ] || profile 07_path_extract "$PI_BIN/path_extract" "$GBZ" "${BASE}.paths"

echo "=== 08 print_stats ==="
profile 08_print_stats "$PI_BIN/print_stats" "${BASE}.ri" "${BASE}_compressed.tags"

# === Query / projection =====================================================
echo "=== 09 find_mems (L=$MEM_LEN, occ>=$MIN_OCC) ==="
[ -f "${OUT}_path_pos_v2.bin" ] || profile 09_find_mems "$PI_BIN/find_mems" \
    "${BASE}.ri" "${BASE}_compressed.tags" "$READS" "$MEM_LEN" "$MIN_OCC" "$OUT"

echo "=== 10 gafpack ==="
[ -f "${OUT}.gaf" ] || profile 10_gafpack "$GAFPACK" \
    --gfa "$GFA" \
    --path-pos "${OUT}_path_pos_v2.bin" \
    --seq-id-starts "${OUT}_seq_id_starts.out" \
    --path-names "${BASE}.paths" \
    --gaf-file-prefix "$OUT"

# === Validation =============================================================
echo "=== 11 validate_gaf (n=$VALIDATE_SAMPLE) ==="
profile 11_validate_gaf python3 "$VALIDATE_GAF" "${OUT}.gaf" "$READS" "$GFA" --sample "$VALIDATE_SAMPLE"

echo
echo "Finished: $(date)" >> "$RUN_DIR/RUN_INFO.txt"
summarize_timing > "$TIMING"
echo "=== TIMING SUMMARY ($TIMING) ==="
cat "$TIMING"
echo
echo "=== OUTPUTS (runs/$TAG/) ==="
ls -lh "${BASE}".* "${BASE}_compressed.tags" "${OUT}"* 2>/dev/null | awk '{printf "  %-55s %8s\n", $NF, $5}'
echo
grep -E '^(Valid|Invalid|Total) entries' "$LOGS/11_validate_gaf.log" || true
