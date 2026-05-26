#!/bin/bash
# =============================================================================
# Performance harness for the LIGHTWEIGHT tag-index pipeline.
#
# Mirror of perf_harness.sh, but runs:
#   1. find_mems --lightweight-tags        (consumes .ltags, no graph-pos dedup)
#   2. gafpack coverage-only               (no --dedup-read-node, raw lite)
#   3. gafpack cov-only --dedup-read-node  (dedup at gafpack)
#   4. gafpack cov+gaf  --dedup-read-node  (dedup at gafpack, with GAF)
#
# Phase 2 measures the cost of NOT deduping (the "lite-raw" upper-bound work
# for gafpack). Phase 3/4 measure the realistic pipeline (lite find_mems +
# dedup gafpack). Side-by-side with perf_harness.sh's v2 numbers, this lets
# us isolate find_mems savings, gafpack dedup overhead, and total wall.
#
# Usage:
#   ./perf/perf_lite_harness.sh <config.env> <N-trials> [tag]
#
# Expects:
#   - find_mems with --lightweight-tags support (lightweight-tags branch)
#   - gafpack  with --dedup-read-node support  (dedup-read-node branch)
#   - INDEX_DIR contains <BASE>.ltags built via build_lightweight_tags
#
# Output: same shape as perf_harness.sh (per-trial dirs, SUMMARY.tsv,
# PROVENANCE.txt, DATASET.md) so summarize.py and table tooling Just Work.
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Default tool locations -------------------------------------------------
PI_BIN="${PI_BIN:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin}"
GAFPACK="${GAFPACK:-/Users/hlakshmidevi/personal/gafpack/target/release/gafpack}"
GBZ_STATS="${GBZ_STATS:-gbz_stats}"

# ---- Args -------------------------------------------------------------------
[ $# -ge 2 ] || { echo "Usage: $0 <config.env> <N-trials> [tag]"; exit 2; }
CONFIG="$1"
N_TRIALS="$2"
[ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }
TAG="${3:-$(basename "$CONFIG" .env)-lite}"

# shellcheck source=/dev/null
source "$CONFIG"

for b in "$PI_BIN/find_mems" "$GAFPACK" "$PI_BIN/build_lightweight_tags"; do
    [ -x "$b" ] || { echo "Missing or non-executable: $b"; exit 1; }
done
command -v gtime >/dev/null 2>&1 || { echo "gtime required (brew install gnu-time)"; exit 1; }

# Pre-built indexes (we don't rebuild; pull from a prior run)
INDEX_DIR="${INDEX_DIR:-$PIPE_DIR/runs/v1-current}"
for f in "$INDEX_DIR/${BASE}.ri" "$INDEX_DIR/${BASE}_compressed.tags" "$INDEX_DIR/${BASE}.paths" "$INDEX_DIR/${BASE}.ltags"; do
    [ -f "$f" ] || { echo "Missing index file: $f"; \
                     echo "Tip: $PI_BIN/build_lightweight_tags <BASE>_compressed.tags <BASE>.ltags"; \
                     exit 1; }
done

PERF_DIR="$PIPE_DIR/perf/$TAG"
SUMMARY="$PERF_DIR/SUMMARY.tsv"
mkdir -p "$PERF_DIR"

if [ ! -f "$SUMMARY" ]; then
    printf '%s\n' "format	trial	phase	wall_s	maxrss_mb	user_s	sys_s	minor_faults	major_faults	gaf_lines	bin_bytes	bin_records	cov_md5	stderr_warns	gafpack_total_entries" > "$SUMMARY"
fi

# ---- helpers ----------------------------------------------------------------
gtime_wall_s() {
    awk -F': ' '/Elapsed \(wall clock\)/{split($2,a,":"); n=length(a);
        if (n==2) print a[1]*60 + a[2]; else if (n==3) print a[1]*3600 + a[2]*60 + a[3]}' "$1"
}
gtime_field() {
    local div="${3:-1}"
    awk -F': ' -v key="$2" -v div="$div" '$0 ~ key {print int($NF/div); exit}' "$1"
}

# Run one (find_mems-lite, gafpack-raw, gafpack-dedup-cov, gafpack-dedup-cov+gaf)
# sequence. Args:
#   $1 = format label (always "lite" for now; reserved for future variants)
#   $2 = trial label (1..N, or "warmup")
#   $3 = output trial dir
#   $4 = "skip_summary" if we shouldn't append to SUMMARY.tsv (warmups)
run_one_trial() {
    local fmt="$1" trial="$2" tdir="$3" skip_sum="${4:-}"
    mkdir -p "$tdir"

    local path_pos_file="${OUT}_path_pos_v2.bin"
    local rec_size=16

    rm -f "$INDEX_DIR/$path_pos_file" \
          "$INDEX_DIR/${OUT}_seq_id_starts.out" \
          "$INDEX_DIR/${OUT}.gaf" \
          "$INDEX_DIR/${OUT}_coverage.csv"

    # ---- Phase 1: find_mems --lightweight-tags ----
    echo ">>> [$fmt trial=$trial] find_mems --lightweight-tags"
    ( cd "$INDEX_DIR" && \
      gtime -v -o "$tdir/find_mems.time" \
        "$PI_BIN/find_mems" \
            "${BASE}.ri" "${BASE}.ltags" "$READS" \
            "$MEM_LEN" "$MIN_OCC" "$OUT" \
            --lightweight-tags \
        > "$tdir/find_mems.log" 2> "$tdir/find_mems.stderr" )

    # ---- Phase 2: gafpack coverage-only WITHOUT dedup (raw lite) ----
    rm -f "$INDEX_DIR/${OUT}_coverage.csv"
    echo ">>> [$fmt trial=$trial] gafpack cov-only (no dedup, RAW LITE)"
    ( cd "$INDEX_DIR" && \
      gtime -v -o "$tdir/gafpack_cov_raw.time" \
        "$GAFPACK" \
            --gfa "$GFA" \
            --path-pos "$path_pos_file" \
            --seq-id-starts "${OUT}_seq_id_starts.out" \
            --path-names "${BASE}.paths" \
            --coverage-prefix "${OUT}_raw" \
        > "$tdir/gafpack_cov_raw.stdout" 2> "$tdir/gafpack_cov_raw.stderr" )

    # ---- Phase 3: gafpack coverage-only WITH --dedup-read-node ----
    rm -f "$INDEX_DIR/${OUT}_coverage.csv"
    echo ">>> [$fmt trial=$trial] gafpack cov-only (--dedup-read-node)"
    ( cd "$INDEX_DIR" && \
      gtime -v -o "$tdir/gafpack_cov_only.time" \
        "$GAFPACK" \
            --gfa "$GFA" \
            --path-pos "$path_pos_file" \
            --seq-id-starts "${OUT}_seq_id_starts.out" \
            --path-names "${BASE}.paths" \
            --coverage-prefix "$OUT" \
            --dedup-read-node \
        > "$tdir/gafpack_cov_only.stdout" 2> "$tdir/gafpack_cov_only.stderr" )

    # ---- Phase 4: gafpack coverage + GAF WITH --dedup-read-node ----
    rm -f "$INDEX_DIR/${OUT}_coverage.csv" "$INDEX_DIR/${OUT}.gaf"
    echo ">>> [$fmt trial=$trial] gafpack cov+gaf (--dedup-read-node)"
    ( cd "$INDEX_DIR" && \
      gtime -v -o "$tdir/gafpack_cov_gaf.time" \
        "$GAFPACK" \
            --gfa "$GFA" \
            --path-pos "$path_pos_file" \
            --seq-id-starts "${OUT}_seq_id_starts.out" \
            --path-names "${BASE}.paths" \
            --gaf-file-prefix "$OUT" \
            --dedup-read-node \
        > "$tdir/gafpack_cov_gaf.stdout" 2> "$tdir/gafpack_cov_gaf.stderr" )

    # Per-trial OUTPUT artifact sizes
    {
        echo "# Output sizes after $fmt trial=$trial"
        for f in "$path_pos_file" "${OUT}_seq_id_starts.out" "${OUT}.gaf" "${OUT}_coverage.csv" "${OUT}_raw_coverage.csv"; do
            if [ -f "$INDEX_DIR/$f" ]; then
                printf "%-50s %15s bytes\n" "$f" "$(stat -f%z "$INDEX_DIR/$f")"
            fi
        done
        echo "# .gaf line count:";       wc -l "$INDEX_DIR/${OUT}.gaf"  2>/dev/null
        echo "# coverage CSV md5:";      md5 -q "$INDEX_DIR/${OUT}_coverage.csv"  2>/dev/null
        echo "# raw coverage CSV md5:";  md5 -q "$INDEX_DIR/${OUT}_raw_coverage.csv" 2>/dev/null
    } > "$tdir/sizes.txt"

    [ "$skip_sum" = "skip_summary" ] && return 0

    local gaf_lines bin_bytes bin_recs cov_md5
    gaf_lines=$(wc -l < "$INDEX_DIR/${OUT}.gaf" | tr -d ' ')
    bin_bytes=$(stat -f%z "$INDEX_DIR/$path_pos_file")
    bin_recs=$((bin_bytes / rec_size))
    cov_md5=$(md5 -q "$INDEX_DIR/${OUT}_coverage.csv")

    append_phase_row() {
        local phase="$1" tfile="$2" sfile="$3"
        local wall rss user sys minor major warns gp_total
        wall=$(gtime_wall_s "$tfile")
        rss=$(gtime_field "$tfile" 'Maximum resident set size' 1024)
        user=$(awk -F': ' '/User time \(seconds\)/{print $NF; exit}' "$tfile")
        sys=$(awk -F': ' '/System time \(seconds\)/{print $NF; exit}' "$tfile")
        minor=$(awk -F': ' '/Minor \(reclaiming a frame\) page faults/{print $NF; exit}' "$tfile")
        major=$(awk -F': ' '/Major \(requiring I\/O\) page faults/{print $NF; exit}' "$tfile")
        warns=$(grep -cE '^(ERROR|WARN)' "$sfile" 2>/dev/null || true)
        [ -z "$warns" ] && warns=0
        gp_total=$(awk -F': ' '/Total GAF entries/{print $NF; exit}' "$sfile" 2>/dev/null | tr -d ' ')
        [ -z "$gp_total" ] && gp_total="-"

        if [ "$phase" = "find_mems" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\t-\t-\t-\n' \
                "$fmt" "$trial" "$phase" "$wall" "$rss" "$user" "$sys" "$minor" "$major"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$fmt" "$trial" "$phase" "$wall" "$rss" "$user" "$sys" "$minor" "$major" \
                "$gaf_lines" "$bin_bytes" "$bin_recs" "$cov_md5" "$warns" "$gp_total"
        fi
    }

    {
        append_phase_row "find_mems"        "$tdir/find_mems.time"        "$tdir/find_mems.stderr"
        append_phase_row "gafpack_cov_raw"  "$tdir/gafpack_cov_raw.time"  "$tdir/gafpack_cov_raw.stderr"
        append_phase_row "gafpack_cov_only" "$tdir/gafpack_cov_only.time" "$tdir/gafpack_cov_only.stderr"
        append_phase_row "gafpack_cov_gaf"  "$tdir/gafpack_cov_gaf.time"  "$tdir/gafpack_cov_gaf.stderr"
    } >> "$SUMMARY"

    local fm_wall co_wall cg_wall fr_wall fm_rss co_rss cg_rss fr_rss
    fm_wall=$(gtime_wall_s "$tdir/find_mems.time")
    fr_wall=$(gtime_wall_s "$tdir/gafpack_cov_raw.time")
    co_wall=$(gtime_wall_s "$tdir/gafpack_cov_only.time")
    cg_wall=$(gtime_wall_s "$tdir/gafpack_cov_gaf.time")
    fm_rss=$(gtime_field "$tdir/find_mems.time"        'Maximum resident set size' 1024)
    fr_rss=$(gtime_field "$tdir/gafpack_cov_raw.time"  'Maximum resident set size' 1024)
    co_rss=$(gtime_field "$tdir/gafpack_cov_only.time" 'Maximum resident set size' 1024)
    cg_rss=$(gtime_field "$tdir/gafpack_cov_gaf.time"  'Maximum resident set size' 1024)
    printf '    find_mems %5ss %4sMB  cov-raw %5ss %4sMB  cov-dedup %5ss %4sMB  cov+gaf-dedup %5ss %4sMB   gaf=%s lines\n' \
        "$fm_wall" "$fm_rss" "$fr_wall" "$fr_rss" "$co_wall" "$co_rss" "$cg_wall" "$cg_rss" "$gaf_lines"
}

# ---- Provenance + dataset context (once per run) ---------------------------
{
    echo "Tag:          $TAG"
    echo "Started:      $(date)"
    echo "Host:         $(hostname)"
    echo "OS:           $(uname -a)"
    echo "Config:       $CONFIG"
    echo "Index dir:    $INDEX_DIR"
    echo "Mode:         lite (find_mems --lightweight-tags + gafpack --dedup-read-node)"
    echo "Trials:       $N_TRIALS"
    echo
    echo "Parameters:"
    echo "  KMER:       ${KMER:-?}      (build_tags -k)"
    echo "  MEM_LEN:    ${MEM_LEN:-?}      (find_mems minimum MEM length)"
    echo "  MIN_OCC:    ${MIN_OCC:-?}      (find_mems minimum BWT occurrences)"
    echo "  THREADS:    ${THREADS:-?}"
    echo
    echo "Binaries:"
    printf "  %-8s %s  md5=%s\n" "PI_lite"        "$PI_BIN/find_mems"              "$(md5 -q "$PI_BIN/find_mems")"
    printf "  %-8s %s  md5=%s\n" "build_ltags"    "$PI_BIN/build_lightweight_tags" "$(md5 -q "$PI_BIN/build_lightweight_tags")"
    printf "  %-8s %s  md5=%s\n" "GP_dedup"       "$GAFPACK"                       "$(md5 -q "$GAFPACK")"
    echo
    echo "Input files (sizes captured once; invariant across trials):"
    for f in "$GBZ" "$GFA" "$READS"; do
        if [ -f "$f" ]; then
            printf "  %-32s %15s bytes  %s\n" "$(basename "$f"):" "$(stat -f%z "$f")" "$f"
        fi
    done
    echo
    echo "Index files in INDEX_DIR (built once via run.sh + build_lightweight_tags):"
    for f in "${BASE}.seq" "${BASE}.rl_bwt" "${BASE}.ri" "${BASE}.tags" "${BASE}_compressed.tags" "${BASE}.ltags" "${BASE}.paths"; do
        if [ -f "$INDEX_DIR/$f" ]; then
            printf "  %-32s %15s bytes\n" "$f:" "$(stat -f%z "$INDEX_DIR/$f")"
        fi
    done
} > "$PERF_DIR/PROVENANCE.txt"

echo "==============================================="
echo " Perf harness (LITE): $TAG"
echo " Config:    $CONFIG"
echo " Trials:    $N_TRIALS"
echo " Index dir: $INDEX_DIR"
echo " PI lite:   $PI_BIN/find_mems  (--lightweight-tags)"
echo " GP dedup:  $GAFPACK  (--dedup-read-node)"
echo " Output:    $PERF_DIR"
echo "==============================================="

echo
echo "===== Warmup =====  (untimed)"
run_one_trial "lite" warmup "$PERF_DIR/lite/warmup" skip_summary

echo
echo "===== Timed trials =====  (N=$N_TRIALS)"
for i in $(seq 1 "$N_TRIALS"); do
    run_one_trial "lite" "$i" "$PERF_DIR/lite/trial-$i"
done

echo
echo "Finished: $(date)" >> "$PERF_DIR/PROVENANCE.txt"
echo
echo "SUMMARY.tsv:  $SUMMARY"
echo "(Compare against perf/yeast235-chrII/SUMMARY.tsv for v2 baseline.)"
