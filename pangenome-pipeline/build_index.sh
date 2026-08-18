#!/bin/bash
# =============================================================================
# pangenome-index — INDEX BUILD driver (steps 01–08b)
#
# Usage:  ./build_index.sh <config.env> [index-tag]
#   config.env  — see configs/*.env for the variable contract.
#                 Must set: GBZ, BASE, KMER, THREADS.
#                 Ignored (warns):  READS, OUT, GFA.
#                 (READS and OUT are for query.sh; GFA is derived in 01b.)
#   index-tag   — output dir name under runs/ (default: today's date).
#
# Outputs:
#   runs/<index-tag>/
#     <BASE>.gfa                     (01b: vg convert -fW --no-translation $GBZ)
#     <BASE>.seq                     (02: gbz_extract -b)
#     <BASE>.rl_bwt                  (03: grlbwt-cli)
#     <BASE>.ri                      (04: build_rindex)
#     <BASE>.tags                    (05: build_tags -k $KMER)
#     <BASE>_compressed.tags         (06: convert_tags --num-seq)
#     <BASE>.paths                   (07: path_extract)
#     <BASE>.ltags                   (08b: build_lightweight_tags)
#     logs/NN_<step>.{log,time}      per-step output + GNU-time profiling
#     logs/timing_summary.txt        rebuilt at end from all *.time files
#     RUN_INFO.txt                   index-build provenance
#     config.env -> $CONFIG          symlink for traceability
#
# Each step is guarded by [ -f <output> ]; re-invocation resumes after the
# last completed artifact. To force a step, delete its output and re-run.
#
# Once the index is built, point query.sh at this dir:
#   ./query.sh <reads-config.env> <index-tag> [query-name]
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Tool locations (override via env if needed) ---------------------------
PI_BIN="${PI_BIN:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin}"
GRLBWT="${GRLBWT:-grlbwt-cli}"
GBZ_STATS="${GBZ_STATS:-gbz_stats}"
GBZ_EXTRACT="${GBZ_EXTRACT:-gbz_extract}"
# vg derives ${BASE}.gfa from $GBZ in step 01b. The derived GFA's segment IDs
# equal the GBZ's node IDs by construction; see CLAUDE.md "GFA derivation contract".
VG="${VG:-/Users/hlakshmidevi/personal/vg/bin/vg}"

# ---- time(1) detection (see run.sh history for full rationale) -------------
TIME=""
TIME_FLAVOR=""
for candidate in \
    "$(command -v gtime 2>/dev/null || true)" \
    "$HOME/.guix-profile/bin/time" \
    /usr/bin/time \
    /usr/local/bin/time
do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -v true >/dev/null 2>&1; then
        TIME="$candidate -v"
        TIME_FLAVOR="gtime"
        break
    fi
    TIME="$candidate"
    TIME_FLAVOR="bsd"
done
[ -n "$TIME" ] || {
    echo "ERROR: no usable time(1). Install: apt-get install time | guix install time | brew install gnu-time"
    exit 1
}

# ---- Args ------------------------------------------------------------------
[ $# -ge 1 ] || { echo "Usage: $0 <config.env> [index-tag]"; exit 2; }
CONFIG="$1"
[ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }
TAG="${2:-$(date +%Y-%m-%d)}"

# shellcheck source=/dev/null
source "$CONFIG"

# ---- Required config variables --------------------------------------------
for v in GBZ BASE KMER THREADS; do
    [ -n "${!v:-}" ] || { echo "ERROR: config $CONFIG missing required variable: $v"; exit 2; }
done
[ -e "$GBZ" ] || { echo "Missing input: $GBZ"; exit 1; }

# ---- Cap OpenMP parallelism -----------------------------------------------
# Bind OMP_NUM_THREADS to $THREADS so OpenMP-using binaries (build_rindex,
# build_tags, convert_tags, print_stats, build_lightweight_tags -- all link
# the parallel headers in pangenome-index-latest/include/pangenome_index/)
# respect the config rather than grabbing every core via omp_get_max_threads().
# Without this, a 96-core host runs build_tags at 96 threads regardless of
# what THREADS says, which (a) hides config-vs-actual mismatches in timing
# logs and (b) is antisocial on shared hosts. Honor any pre-set value so
# `OMP_NUM_THREADS=8 ./build_index.sh ...` still overrides at the CLI.
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-$THREADS}"

RUN_DIR="$PIPE_DIR/runs/$TAG"
LOGS="$RUN_DIR/logs"
mkdir -p "$LOGS"
cd "$RUN_DIR"

# Record provenance
{
    echo "Run:        $TAG (index build)"
    echo "Config:     $CONFIG"
    echo "Started:    $(date)"
    echo "Host:       $(hostname)"
    echo "PI_BIN:     $PI_BIN"
    echo "VG:         $VG"
    echo "GBZ:        $GBZ ($(du -h "$GBZ" | cut -f1))"
    echo "BASE:       $BASE"
    echo "KMER:       $KMER"
    echo "THREADS:    $THREADS"
    git -C "$(dirname "$PI_BIN")" log -1 --format='PI commit:  %h %ci %s' 2>/dev/null || true
} > "$RUN_DIR/RUN_INFO.txt"
ln -sfn "$CONFIG" "$RUN_DIR/config.env"

TIMING="$LOGS/timing_summary.txt"
: > "$TIMING"

# ---- profiling helpers (identical to run.sh; preserved for behavior parity) -
summarize_timing() {
    echo "# step                  wall_s  maxrss_MB"
    for t in "$LOGS"/[0-9][0-9]*_*.time; do
        [ -f "$t" ] || continue
        local name; name=$(basename "$t" .time)
        local wall rss
        wall=$(awk '/ real /{print int($1+0.5); found=1; exit} END{if(!found) print ""}' "$t")
        if [ -z "$wall" ]; then
            wall=$(awk -F': ' '/Elapsed \(wall clock\)/{split($2, a, ":"); n=length(a);
                                if (n==2) {print int(a[1]*60 + a[2] + 0.5)}
                                else if (n==3) {print int(a[1]*3600 + a[2]*60 + a[3] + 0.5)}}' "$t")
        fi
        rss=$(awk '/maximum resident set size/{print int($1/1024/1024)}' "$t")
        if [ -z "$rss" ]; then
            rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$t")
        fi
        printf "%-28s %7s %10s\n" "$name" "${wall:-FAIL}" "${rss:--}"
    done
}

extract_rss_mb() {
    local tlog="$1" rss
    rss=$(awk '/maximum resident set size/{print int($1/1024/1024); exit}' "$tlog")
    if [ -z "$rss" ]; then
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
        printf "%-26s %6d %8d\n" "$name" "$dt" "$rss" >> "$TIMING"
    else
        local rc=$?
        printf "%-26s FAILED (exit %d)\n" "$name" "$rc" >> "$TIMING"
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
        printf "%-26s %6d %8d\n" "$name" "$dt" "$rss" >> "$TIMING"
    else
        local rc=$?
        printf "%-26s FAILED (exit %d)\n" "$name" "$rc" >> "$TIMING"
        echo "    FAIL (exit $rc) — see $tlog"; cat "$tlog"; exit $rc
    fi
}

# ---- Input check + warnings about query-only variables --------------------
echo "=== Input check ==="
printf "  %-8s %s (%s)\n" "$(basename "$GBZ"):" "$GBZ" "$(du -h "$GBZ" | cut -f1)"
[ -n "${READS:-}" ] && \
    echo "  NOTE: config sets READS=$READS — ignored. Index build does not consume reads. Use query.sh for steps 09-11."
[ -n "${OUT:-}" ] && \
    echo "  NOTE: config sets OUT=$OUT — ignored. Index build does not produce per-query outputs."
[ -n "${GFA:-}" ] && \
    echo "  NOTE: config sets GFA=$GFA — ignored. \${BASE}.gfa is derived from \$GBZ in step 01b."
echo

# === Index build ============================================================
echo "=== 01 gbz_stats ==="
profile 01_gbz_stats "$GBZ_STATS" -i "$GBZ"
NUM_SEQ=$(awk '/^Sequences:/ {print $2}' "$LOGS/01_gbz_stats.log")
[ -n "$NUM_SEQ" ] || { echo "Could not parse NUM_SEQ from gbz_stats"; exit 1; }
echo "    NUM_SEQ=$NUM_SEQ"

# === 01b derive_gfa =========================================================
echo "=== 01b derive_gfa (vg convert -fW --no-translation) ==="
DERIVED_GFA="${BASE}.gfa"
[ -f "$DERIVED_GFA" ] || profile_redirect 01b_derive_gfa "$DERIVED_GFA" \
    "$VG" convert -fW --no-translation "$GBZ"

echo "=== 02 gbz_extract ==="
[ -f "${BASE}.seq" ] || profile_redirect 02_gbz_extract "${BASE}.seq" "$GBZ_EXTRACT" -b -t "$THREADS" -p "$GBZ"

echo "=== 03 grlbwt ==="
# -T pins grlbwt-cli's tmpdir inside $RUN_DIR (same FS as output), avoiding
# cross-device rename(2) errors on Linux hosts where /tmp is tmpfs.
GRLBWT_TMP="$RUN_DIR/grl_tmp"
mkdir -p "$GRLBWT_TMP"
[ -f "${BASE}.rl_bwt" ] || profile 03_grlbwt "$GRLBWT" "${BASE}.seq" -t "$THREADS" -T "$GRLBWT_TMP" -o "${BASE}.rl_bwt"
rmdir "$GRLBWT_TMP" 2>/dev/null || true

echo "=== 04 build_rindex ==="
[ -f "${BASE}.ri" ] || profile_redirect 04_build_rindex "${BASE}.ri" "$PI_BIN/build_rindex" "${BASE}.rl_bwt"

echo "=== 05 build_tags (k=$KMER) ==="
[ -f "${BASE}.tags" ] || profile 05_build_tags "$PI_BIN/build_tags" -k "$KMER" "$GBZ" "${BASE}.rl_bwt" "${BASE}.tags"

echo "=== 06 convert_tags (--num-seq $NUM_SEQ) ==="
# REQUIRED flag: convert_tags strips endmarker runs unconditionally and only
# re-prepends them with --num-seq. Omitting it shifts every BWT-position lookup.
[ -f "${BASE}_compressed.tags" ] || profile 06_convert_tags \
    "$PI_BIN/convert_tags" "${BASE}.tags" "${BASE}_compressed.tags" --num-seq "$NUM_SEQ"

echo "=== 07 path_extract ==="
[ -f "${BASE}.paths" ] || profile 07_path_extract "$PI_BIN/path_extract" "$GBZ" "${BASE}.paths"

echo "=== 08 print_stats ==="
profile 08_print_stats "$PI_BIN/print_stats" "${BASE}.ri" "${BASE}_compressed.tags"

# === 08b build_lightweight_tags =============================================
# Lightweight tags are consumed by find_mems --lightweight-tags in query.sh.
# Per perf/yeast235-chrII/FINDINGS_PERF.md: ~24% faster query overall.
echo "=== 08b build_lightweight_tags ==="
[ -f "${BASE}.ltags" ] || profile 08b_build_lightweight_tags \
    "$PI_BIN/build_lightweight_tags" "${BASE}_compressed.tags" "${BASE}.ltags"

# === Summary ================================================================
echo
echo "=== Index build complete (runs/$TAG/) ==="
echo "    Artifacts:"
ls -lh "${BASE}".seq "${BASE}".rl_bwt "${BASE}".ri "${BASE}".tags \
       "${BASE}_compressed.tags" "${BASE}".ltags "${BASE}".paths \
       "${BASE}".gfa 2>/dev/null | awk '{printf "      %-50s %8s\n", $NF, $5}'

summarize_timing > "$TIMING"
echo
echo "=== TIMING SUMMARY ($TIMING) ==="
cat "$TIMING"
echo
echo "Finished (index): $(date)" >> "$RUN_DIR/RUN_INFO.txt"
echo "=== Next: query this index ==="
echo "  ./query.sh <reads-config.env> $TAG [query-name]"
echo "  Outputs land in runs/$TAG/queries/<query-name>/"
