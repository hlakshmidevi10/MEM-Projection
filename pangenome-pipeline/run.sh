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
# vg is used in step 01b to derive ${BASE}.gfa from $GBZ. This is the only
# safe way to guarantee that gafpack walks the same node IDs that find_mems
# saw via the GBZ; see CLAUDE.md "GFA derivation contract".
VG="${VG:-/Users/hlakshmidevi/personal/vg/bin/vg}"
VALIDATE_GAF="${VALIDATE_GAF:-$MEM_PROJ/scripts/validate_gaf_v2.py}"

# Pick a `time` binary that supports -v (GNU format) and exposes RSS.
# macOS:   /usr/bin/time -l unreliable (kern.clockrate sysctl denied on some
#          hosts); prefer brew's `gtime`.
# Linux:   /usr/bin/time IS GNU time and supports -v.
# Guix-on-Debian: /usr/bin/time may not exist at all (no build-essential);
#                 `guix install time` provides ~/.guix-profile/bin/time.
# bash's built-in `time` keyword shadows command lookups for "time", so we
# search by absolute path candidates instead of `command -v time`.
TIME=""
TIME_FLAVOR=""
for candidate in \
    "$(command -v gtime 2>/dev/null || true)" \
    "$HOME/.guix-profile/bin/time" \
    /usr/bin/time \
    /usr/local/bin/time
do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # Probe: does it support `-v`?
    if "$candidate" -v true >/dev/null 2>&1; then
        TIME="$candidate -v"
        TIME_FLAVOR="gtime"   # GNU format ("Maximum resident set size (kbytes): N")
        break
    fi
    # Falls through to BSD-style if -v unsupported (last resort, no RSS in output).
    TIME="$candidate"
    TIME_FLAVOR="bsd"
done
[ -n "$TIME" ] || {
    echo "ERROR: no usable time(1) binary found. Install GNU time:"
    echo "  Debian/Ubuntu:  sudo apt-get install time"
    echo "  Guix:           guix install time"
    echo "  macOS (Homebrew): brew install gnu-time"
    exit 1
}

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
# $GFA is intentionally NOT in this list anymore. The pipeline derives
# ${BASE}.gfa from $GBZ in step 01b — having the user point at a pre-existing
# GFA is unsafe because there's no way for the script to verify it came from
# the same source as $GBZ (and at HPRC scale, a mismatch silently produces
# wrong projections, not an error). If a config still sets $GFA we ignore it
# with a warning.
# $READS is OPTIONAL: if missing, steps 01..08 still run (index build +
# derive_gfa + path_extract) and the script stops cleanly before step 09.
# Re-invoke once $READS exists to resume from step 09 onward.
[ -e "$GBZ" ] || { echo "Missing input: $GBZ"; exit 1; }
printf "  %-8s %s (%s)\n" "$(basename "$GBZ"):" "$GBZ" "$(du -h "$GBZ" | cut -f1)"
HAVE_READS=0
if [ -n "${READS:-}" ] && [ -e "$READS" ]; then
    HAVE_READS=1
    printf "  %-8s %s (%s)\n" "$(basename "$READS"):" "$READS" "$(du -h "$READS" | cut -f1)"
else
    echo "  READS:   ${READS:-<unset>} (not present) — index-only mode; steps 09-11 will be skipped"
fi
if [ -n "${GFA:-}" ]; then
    echo "  NOTE: config sets GFA=$GFA — ignored. run.sh derives \${BASE}.gfa from \$GBZ."
fi
echo

# === Index build ============================================================
echo "=== 01 gbz_stats ==="
profile 01_gbz_stats "$GBZ_STATS" -i "$GBZ"
NUM_SEQ=$(awk '/^Sequences:/ {print $2}' "$LOGS/01_gbz_stats.log")
[ -n "$NUM_SEQ" ] || { echo "Could not parse NUM_SEQ from gbz_stats"; exit 1; }
echo "    NUM_SEQ=$NUM_SEQ"

# === 01b derive_gfa =========================================================
# The GFA gafpack walks (step 10) and the GFA validate_gaf reconstructs paths
# against (step 11) MUST be derived from $GBZ. Any other GFA — even one that
# "came from" the same upstream source — is unsafe: gfa2gbwt may have split
# segments >1024 bp into multiple GBZ nodes, so the GBZ's node IDs no longer
# match the GFA's segment IDs. Result: find_mems emits records targeting GBZ
# node IDs that don't appear on the GFA's P-lines, gafpack walks the wrong
# graph, and projections are silently wrong (validate_gaf will still pass on
# substring matching but the GAF describes paths that don't exist).
#
# Canonical recipe: vg convert -fW --no-translation $GBZ
#   - matches mem-projection/Readme.md:128, the only documented gbz→gfa form
#   - -W emits haplotypes (decays to P-lines for embedded paths in this vg
#     build; verified against final_output2/*.gfa: 317 P / 0 W)
#   - --no-translation suppresses T-lines so segment IDs in the emitted GFA
#     equal the GBZ's node IDs by construction
echo "=== 01b derive_gfa (vg convert -fW --no-translation) ==="
DERIVED_GFA="${BASE}.gfa"
[ -f "$DERIVED_GFA" ] || profile_redirect 01b_derive_gfa "$DERIVED_GFA" \
    "$VG" convert -fW --no-translation "$GBZ"

echo "=== 02 gbz_extract ==="
[ -f "${BASE}.seq" ] || profile_redirect 02_gbz_extract "${BASE}.seq" "$GBZ_EXTRACT" -b -t "$THREADS" -p "$GBZ"

echo "=== 03 grlbwt ==="
# -T/--tmp: grlbwt-cli writes intermediates to /tmp by default, then uses
# std::filesystem::rename to move the final .rl_bwt to $PWD. On hosts where
# /tmp is a different filesystem from the run dir (Linux with /tmp as tmpfs,
# Guix systems, sometimes /home on a separate volume), rename(2) fails with
# 'Invalid cross-device link'. Pinning tmp inside $RUN_DIR puts intermediates
# on the same filesystem as the output, making the rename atomic again.
GRLBWT_TMP="$RUN_DIR/grl_tmp"
mkdir -p "$GRLBWT_TMP"
[ -f "${BASE}.rl_bwt" ] || profile 03_grlbwt "$GRLBWT" "${BASE}.seq" -t "$THREADS" -T "$GRLBWT_TMP" -o "${BASE}.rl_bwt"
# Clean up tmp if it's empty (grlbwt usually cleans up itself on success)
rmdir "$GRLBWT_TMP" 2>/dev/null || true

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
if [ "$HAVE_READS" -eq 0 ]; then
    echo
    echo "=== Index-only mode complete — \$READS not set/missing ==="
    echo "    Built (in runs/$TAG/):"
    ls -1 "${BASE}".seq "${BASE}".rl_bwt "${BASE}".ri "${BASE}".tags \
          "${BASE}_compressed.tags" "${BASE}".paths "${BASE}".gfa 2>/dev/null | sed 's/^/      /'
    echo
    echo "    To run steps 09-11 (find_mems → gafpack → validate):"
    echo "      1. set READS=<path> in $CONFIG"
    echo "      2. re-invoke: $0 $1 $TAG"
    echo "    Steps 01-08 will be skipped (outputs exist); 09 onward will run."
    summarize_timing > "$TIMING"
    echo
    echo "=== TIMING SUMMARY ($TIMING) ==="
    cat "$TIMING"
    echo "Finished (index-only): $(date)" >> "$RUN_DIR/RUN_INFO.txt"
    exit 0
fi

echo "=== 09 find_mems (L=$MEM_LEN, occ>=$MIN_OCC) ==="
[ -f "${OUT}_path_pos_v2.bin" ] || profile 09_find_mems "$PI_BIN/find_mems" \
    "${BASE}.ri" "${BASE}_compressed.tags" "$READS" "$MEM_LEN" "$MIN_OCC" "$OUT"

echo "=== 10 gafpack ==="
# Uses ${DERIVED_GFA} from step 01b — NOT any GFA from the config.
[ -f "${OUT}.gaf" ] || profile 10_gafpack "$GAFPACK" \
    --gfa "$DERIVED_GFA" \
    --path-pos "${OUT}_path_pos_v2.bin" \
    --seq-id-starts "${OUT}_seq_id_starts.out" \
    --path-names "${BASE}.paths" \
    --gaf-file-prefix "$OUT"

# === Validation =============================================================
echo "=== 11 validate_gaf (n=$VALIDATE_SAMPLE) ==="
# validate_gaf reconstructs path sequences against the same GFA gafpack
# walked, so it MUST also use ${DERIVED_GFA}.
profile 11_validate_gaf python3 "$VALIDATE_GAF" "${OUT}.gaf" "$READS" "$DERIVED_GFA" --sample "$VALIDATE_SAMPLE"

echo
echo "Finished: $(date)" >> "$RUN_DIR/RUN_INFO.txt"
summarize_timing > "$TIMING"
echo "=== TIMING SUMMARY ($TIMING) ==="
cat "$TIMING"
echo
echo "=== OUTPUTS (runs/$TAG/) ==="
# ${BASE}.* covers .seq .rl_bwt .ri .tags .paths .gfa (derived in 01b);
# _compressed.tags is named separately; ${OUT}* is find_mems/gafpack output.
ls -lh "${BASE}".* "${BASE}_compressed.tags" "${OUT}"* 2>/dev/null | awk '{printf "  %-55s %8s\n", $NF, $5}'
echo
grep -E '^(Valid|Invalid|Total) entries' "$LOGS/11_validate_gaf.log" || true
