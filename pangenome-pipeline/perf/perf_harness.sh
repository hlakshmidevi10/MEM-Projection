#!/bin/bash
# =============================================================================
# Performance harness for steps 09 (find_mems) + 10 (gafpack).
#
# Runs N timed trials after a single untimed warmup to stabilize OS disk
# cache. Captures wall, RSS, find_mems' internal phase breakdown, and
# gafpack's stderr stats per trial. Aggregate with `summarize.py`.
#
# Default: profiles the canonical v2 binaries (lightweight pipeline matching
#          query.sh: find_mems --lightweight-tags + gafpack --dedup-read-node).
# With --compare-v1: also runs the legacy v1 binaries (interleaved v1/v2)
#                    for A/B regression checks. Requires the v1 binaries to
#                    have been built and placed at PI_BIN_V1 / GAFPACK_V1.
#                    v1 binaries use the OLD compressed-tags + no-dedup
#                    pipeline (non-lightweight).
#
# Outputs:
#   perf/<tag>/<fmt>/trial-{0..N}/
#     find_mems.{log,stderr,time}
#     gafpack.{stdout,stderr,time}
#     sizes.txt
#   perf/<tag>/SUMMARY.tsv
#   perf/<tag>/PROVENANCE.txt
#
# Usage:
#   ./perf/perf_harness.sh <config.env> <N> [tag] [--compare-v1]
#
# Examples:
#   ./perf/perf_harness.sh yeast235-chrII-normalized.env 3
#   ./perf/perf_harness.sh yeast235-chrII-normalized.env 5 nightly --compare-v1
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Default tool locations -------------------------------------------------
PI_BIN="${PI_BIN:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin}"
GAFPACK="${GAFPACK:-/Users/hlakshmidevi/personal/gafpack/target/release/gafpack}"
# v1 (only used with --compare-v1)
PI_BIN_V1="${PI_BIN_V1:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin-v1}"
GAFPACK_V1="${GAFPACK_V1:-/Users/hlakshmidevi/personal/gafpack/target/v1/gafpack}"

# ---- Args -------------------------------------------------------------------
COMPARE_V1=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --compare-v1) COMPARE_V1=1 ;;
        --help|-h)
            sed -n '2,33p' "$0"; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

[ $# -ge 2 ] || { echo "Usage: $0 <config.env> <N-trials> [tag] [--compare-v1]"; exit 2; }
CONFIG="$1"
N_TRIALS="$2"
[ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }
TAG="${3:-$(basename "$CONFIG" .env)}"

# shellcheck source=/dev/null
source "$CONFIG"

# Always need v2 binaries
for b in "$PI_BIN/find_mems" "$GAFPACK"; do
    [ -x "$b" ] || { echo "Missing or non-executable: $b"; exit 1; }
done

# v1 binaries only required when comparing
if [ "$COMPARE_V1" = "1" ]; then
    for b in "$PI_BIN_V1/find_mems" "$GAFPACK_V1"; do
        [ -x "$b" ] || { echo "Missing v1 binary: $b (required by --compare-v1)"; exit 1; }
    done
fi

# gtime required for consistent -v output (Linux's /usr/bin/time also works
# but the existing parser assumes GNU format; gtime is the cross-platform
# answer that works on macOS without conflict).
command -v gtime >/dev/null 2>&1 || {
    if [ -x "$HOME/.guix-profile/bin/time" ]; then
        gtime() { "$HOME/.guix-profile/bin/time" "$@"; }
    elif /usr/bin/time -v true 2>/dev/null; then
        gtime() { /usr/bin/time "$@"; }
    else
        echo "gtime required (brew install gnu-time | guix install time | apt-get install time)"
        exit 1
    fi
}

# Pre-built index — point at the runs/<index-tag>/ from build_index.sh.
# All required files: BASE.ri, BASE.ltags, BASE.paths, BASE.gfa
INDEX_DIR="${INDEX_DIR:-$PIPE_DIR/runs/v1-current}"
for f in "$INDEX_DIR/${BASE}.ri" "$INDEX_DIR/${BASE}.ltags" "$INDEX_DIR/${BASE}.paths" "$INDEX_DIR/${BASE}.gfa"; do
    [ -f "$f" ] || {
        echo "Missing index file: $f"
        echo "Build the index first:"
        echo "  ./build_index.sh <config> $(basename "$INDEX_DIR")"
        echo "or set INDEX_DIR to a different runs/<index-tag>/"
        exit 1
    }
done

# v1 mode needs the legacy (non-lightweight) tags index too
if [ "$COMPARE_V1" = "1" ]; then
    [ -f "$INDEX_DIR/${BASE}_compressed.tags" ] || {
        echo "Missing $INDEX_DIR/${BASE}_compressed.tags (required by --compare-v1)"
        exit 1
    }
fi

PERF_DIR="$PIPE_DIR/perf/$TAG"
SUMMARY="$PERF_DIR/SUMMARY.tsv"
mkdir -p "$PERF_DIR"

if [ ! -f "$SUMMARY" ]; then
    printf '%s\n' "format	trial	step	wall_s	maxrss_mb	gaf_lines	bin_bytes	bin_records	cov_md5	stderr_warns	gafpack_total_entries" > "$SUMMARY"
fi

# ---- cross-platform helpers ------------------------------------------------
fsize() { stat -Lc%s "$1" 2>/dev/null || stat -Lf%z "$1" 2>/dev/null; }
fmd5() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
    else md5 -q "$1"; fi
}

# ---- helpers ----------------------------------------------------------------

# Run one (find_mems, gafpack) pair. Args:
#   $1 = format label (v1|v2; used for dir name + record-size math)
#   $2 = trial label (1..N, or "warmup")
#   $3 = output trial dir
#   $4 = "skip_summary" if we shouldn't append to SUMMARY.tsv (warmups)
run_one_trial() {
    local fmt="$1" trial="$2" tdir="$3" skip_sum="${4:-}"
    mkdir -p "$tdir"
    cd "$tdir"

    local pi_bin gafpack_bin tag_index path_pos_file rec_size find_mems_extra gafpack_extra
    case "$fmt" in
        v1) pi_bin="$PI_BIN_V1"; gafpack_bin="$GAFPACK_V1"
            tag_index="$INDEX_DIR/${BASE}_compressed.tags"
            path_pos_file="mems_path_pos.bin"; rec_size=24
            find_mems_extra=""
            gafpack_extra="" ;;
        v2) pi_bin="$PI_BIN";    gafpack_bin="$GAFPACK"
            tag_index="$INDEX_DIR/${BASE}.ltags"
            path_pos_file="mems_path_pos_v2.bin"; rec_size=16
            find_mems_extra="--lightweight-tags"
            gafpack_extra="--dedup-read-node" ;;
    esac

    # Clean any prior step-09/10 outputs in this trial dir for a fresh measurement
    rm -f "$path_pos_file" mems_seq_id_starts.out alignment.gaf alignment_coverage.csv

    echo ">>> [$fmt trial=$trial] find_mems"
    # NB: find_mems writes <prefix>_path_pos*.bin and <prefix>_seq_id_starts.out.
    # We pass "mems" so outputs land at mems_path_pos*.bin / mems_seq_id_starts.out.
    gtime -v -o "$tdir/find_mems.time" \
        "$pi_bin/find_mems" \
            "$INDEX_DIR/${BASE}.ri" "$tag_index" "$READS" \
            "$MEM_LEN" "$MIN_OCC" "mems" \
            $find_mems_extra \
        > "$tdir/find_mems.log" 2> "$tdir/find_mems.stderr"

    echo ">>> [$fmt trial=$trial] gafpack"
    gtime -v -o "$tdir/gafpack.time" \
        "$gafpack_bin" \
            --gfa "$INDEX_DIR/${BASE}.gfa" \
            --path-pos "$path_pos_file" \
            --seq-id-starts "mems_seq_id_starts.out" \
            --path-names "$INDEX_DIR/${BASE}.paths" \
            --gaf-file-prefix "alignment" \
            $gafpack_extra \
        > "$tdir/gafpack.stdout" 2> "$tdir/gafpack.stderr"

    # Capture output sizes for posterity
    {
        echo "# Sizes after $fmt trial=$trial"
        for f in "$path_pos_file" mems_seq_id_starts.out alignment.gaf alignment_coverage.csv; do
            if [ -f "$f" ]; then
                printf "%-50s %15s bytes\n" "$f" "$(fsize "$f")"
            fi
        done
        echo "# alignment.gaf line count:"; wc -l alignment.gaf 2>/dev/null
        echo "# alignment_coverage.csv md5:"; fmd5 alignment_coverage.csv 2>/dev/null
    } > "$tdir/sizes.txt"

    [ "$skip_sum" = "skip_summary" ] && return 0

    local fm_wall fm_rss gp_wall gp_rss
    fm_wall=$(awk -F': ' '/Elapsed \(wall clock\)/{split($2,a,":"); n=length(a);
              if (n==2) print a[1]*60 + a[2]; else if (n==3) print a[1]*3600 + a[2]*60 + a[3]}' \
              "$tdir/find_mems.time")
    fm_rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$tdir/find_mems.time")
    gp_wall=$(awk -F': ' '/Elapsed \(wall clock\)/{split($2,a,":"); n=length(a);
              if (n==2) print a[1]*60 + a[2]; else if (n==3) print a[1]*3600 + a[2]*60 + a[3]}' \
              "$tdir/gafpack.time")
    gp_rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$tdir/gafpack.time")

    local gaf_lines bin_bytes bin_recs cov_md5 gp_total gp_warns
    gaf_lines=$(wc -l < alignment.gaf | tr -d ' ')
    bin_bytes=$(fsize "$path_pos_file")
    bin_recs=$((bin_bytes / rec_size))
    cov_md5=$(fmd5 alignment_coverage.csv)
    gp_total=$(awk -F': ' '/Total GAF entries/{print $2}' "$tdir/gafpack.stderr" | tr -d ' ')
    gp_warns=$(grep -cE '^(ERROR|WARN)' "$tdir/gafpack.stderr" 2>/dev/null || true)
    [ -z "$gp_warns" ] && gp_warns=0

    {
        printf '%s\t%s\tfind_mems\t%s\t%s\t-\t-\t-\t-\t-\t-\n' \
            "$fmt" "$trial" "$fm_wall" "$fm_rss"
        printf '%s\t%s\tgafpack\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$fmt" "$trial" "$gp_wall" "$gp_rss" \
            "$gaf_lines" "$bin_bytes" "$bin_recs" "$cov_md5" "$gp_warns" "$gp_total"
    } >> "$SUMMARY"

    echo "    find_mems: ${fm_wall}s / ${fm_rss}MB   gafpack: ${gp_wall}s / ${gp_rss}MB   alignment.gaf: ${gaf_lines} lines"
}

# ---- Provenance + execution -------------------------------------------------

if [ "$COMPARE_V1" = "1" ]; then
    formats=(v1 v2)
    mode_desc="v1 (compressed-tags, no-dedup) + v2 (lightweight + dedup-read-node) (interleaved A/B)"
else
    formats=(v2)
    mode_desc="v2 (lightweight + dedup-read-node, default)"
fi

echo "==============================================="
echo " Perf harness: $TAG"
echo " Config:    $CONFIG"
echo " Mode:      $mode_desc"
echo " Trials:    $N_TRIALS per format"
echo " Index dir: $INDEX_DIR"
echo " PI v2:     $PI_BIN/find_mems"
echo " GP v2:     $GAFPACK"
[ "$COMPARE_V1" = "1" ] && {
    echo " PI v1:     $PI_BIN_V1/find_mems"
    echo " GP v1:     $GAFPACK_V1"
}
echo " Output:    $PERF_DIR"
echo "==============================================="

{
    echo "Tag:          $TAG"
    echo "Started:      $(date)"
    echo "Host:         $(hostname)"
    echo "OS:           $(uname -a)"
    echo "Config:       $CONFIG"
    echo "Index dir:    $INDEX_DIR"
    echo "Mode:         $mode_desc"
    echo "Trials:       $N_TRIALS"
    echo
    echo "Binaries:"
    printf "  %-8s %s  md5=%s\n" "PI_v2"  "$PI_BIN/find_mems" "$(fmd5 "$PI_BIN/find_mems")"
    printf "  %-8s %s  md5=%s\n" "GP_v2"  "$GAFPACK"           "$(fmd5 "$GAFPACK")"
    if [ "$COMPARE_V1" = "1" ]; then
        printf "  %-8s %s  md5=%s\n" "PI_v1" "$PI_BIN_V1/find_mems" "$(fmd5 "$PI_BIN_V1/find_mems")"
        printf "  %-8s %s  md5=%s\n" "GP_v1" "$GAFPACK_V1"          "$(fmd5 "$GAFPACK_V1")"
    fi
} > "$PERF_DIR/PROVENANCE.txt"

# Warmups
echo
echo "===== Warmup =====  (untimed, stabilizes OS disk cache)"
for fmt in "${formats[@]}"; do
    run_one_trial "$fmt" warmup "$PERF_DIR/$fmt/warmup" skip_summary
done

# Timed trials (interleaved when COMPARE_V1 to balance host noise)
echo
echo "===== Timed trials =====  (N=$N_TRIALS)"
for i in $(seq 1 "$N_TRIALS"); do
    for fmt in "${formats[@]}"; do
        run_one_trial "$fmt" "$i" "$PERF_DIR/$fmt/trial-$i"
    done
done

echo
echo "Finished: $(date)" >> "$PERF_DIR/PROVENANCE.txt"
echo
echo "===== Aggregate with: ====="
echo "  python3 $PIPE_DIR/perf/summarize.py $PERF_DIR"
