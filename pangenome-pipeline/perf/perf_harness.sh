#!/bin/bash
# =============================================================================
# perf_harness.sh — query-side performance benchmark for find_mems + gafpack.
#
# For each mode, runs 2 untimed warmups to reach warm-cache steady state,
# then N timed trials contiguously (all of mode A, then all of mode B).
# This matches production behavior — same mode called repeatedly against
# the same index — and avoids cache thrash from mid-run mode switches.
# Captures wall, RSS, find_mems' internal phase breakdown, gafpack's stderr
# stats, and output artifact sizes per trial. Aggregate with
# `summarize.py <perf-tag-dir>`.
#
# Two modes benchmarked by default (matching query.sh's two tag modes):
#   lightweight: find_mems --lightweight-tags + gafpack --dedup-read-node
#                consumes <BASE>.ltags
#   full-tag:    find_mems (no --lightweight-tags) + gafpack (no --dedup)
#                consumes <BASE>_compressed.tags
#
# Both modes run in coverage-only mode (no .gaf, no validation) — matches the
# production query path. To benchmark with .gaf, add --gaf (adds time + disk
# per trial but no validation step).
#
# Outputs:
#   perf/<tag>/<mode>/trial-{0..N}/
#     find_mems.{log,stderr,time}
#     gafpack.{stdout,stderr,time}
#     sizes.txt
#   perf/<tag>/SUMMARY.tsv             machine-readable per-trial rows
#   perf/<tag>/PROVENANCE.txt          host, date, binaries, index, modes
#
# Usage:
#   ./perf/perf_harness.sh <config.env> <N-trials> [tag] [--modes M1,M2,...] [--gaf]
#
# Examples:
#   ./perf/perf_harness.sh hprcv2-chr6.env 5
#   ./perf/perf_harness.sh hprcv2-chr6.env 5 hprcv2-noisy
#   ./perf/perf_harness.sh hprcv2-chr6.env 3 quick --modes lightweight
#   ./perf/perf_harness.sh yeast235-chrII-normalized.env 5 yeast --gaf
#
# Required:
#   - $INDEX_DIR (env var or default runs/v1-current) contains <BASE>.ri,
#     <BASE>.paths, <BASE>.gfa, and EITHER <BASE>.ltags (lightweight mode)
#     OR <BASE>_compressed.tags (full-tag mode), depending on which modes
#     are benchmarked.
#   - $PI_BIN/find_mems built with --lightweight-tags support
#   - $GAFPACK built with --dedup-read-node support
#   - $READS file (one read per line, no FASTA headers)
#   - GNU time (gtime / /usr/bin/time -v / ~/.guix-profile/bin/time)
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Tool locations --------------------------------------------------------
PI_BIN="${PI_BIN:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin}"
GAFPACK="${GAFPACK:-/Users/hlakshmidevi/personal/gafpack/target/release/gafpack}"

# ---- time(1) detection (mirrors build_index.sh / query.sh) -----------------
TIME=""
for candidate in \
    "$(command -v gtime 2>/dev/null || true)" \
    "$HOME/.guix-profile/bin/time" \
    /usr/bin/time \
    /usr/local/bin/time
do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -v true >/dev/null 2>&1; then TIME="$candidate"; break; fi
done
[ -n "$TIME" ] || { echo "ERROR: no GNU time(1) found"; exit 1; }

# ---- Arg parsing -----------------------------------------------------------
EMIT_GAF=0
MODES="lightweight,full-tag"
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --gaf) EMIT_GAF=1 ;;
        --modes=*) MODES="${arg#--modes=}" ;;
        --modes)
            echo "ERROR: --modes requires =value form (e.g. --modes=lightweight,full-tag)" >&2
            exit 2 ;;
        --modes\ *|--modes\=*) MODES="${arg#--modes=}"; MODES="${MODES#--modes }" ;;
        --help|-h)
            sed -n '2,46p' "$0" | sed 's|^# \?||; $d'; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

[ $# -ge 2 ] || { echo "Usage: $0 <config.env> <N-trials> [tag] [--modes=M1,M2] [--gaf]"; exit 2; }
CONFIG="$1"
N_TRIALS="$2"
[ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }
TAG="${3:-$(basename "$CONFIG" .env)}"

case "$N_TRIALS" in
    ''|*[!0-9]*) echo "ERROR: N-trials must be a positive integer: $N_TRIALS"; exit 2 ;;
esac
[ "$N_TRIALS" -ge 1 ] || { echo "ERROR: N-trials must be >= 1"; exit 2; }

# Split MODES into array
IFS=',' read -r -a MODE_ARRAY <<< "$MODES"
for m in "${MODE_ARRAY[@]}"; do
    case "$m" in
        lightweight|full-tag) ;;
        *) echo "ERROR: unknown mode '$m' (valid: lightweight, full-tag)"; exit 2 ;;
    esac
done

# shellcheck source=/dev/null
source "$CONFIG"
for v in BASE READS; do
    [ -n "${!v:-}" ] || { echo "ERROR: config $CONFIG missing required: $v"; exit 2; }
done
[ -e "$READS" ] || { echo "ERROR: READS file not found: $READS"; exit 1; }
[ -n "${MEM_LEN:-}" ] || MEM_LEN=30
[ -n "${MIN_OCC:-}" ] || MIN_OCC=1

# Sanity-check binaries
[ -x "$PI_BIN/find_mems" ] || { echo "Missing or non-executable: $PI_BIN/find_mems"; exit 1; }
[ -x "$GAFPACK" ]          || { echo "Missing or non-executable: $GAFPACK"; exit 1; }

# Locate index
INDEX_DIR="${INDEX_DIR:-$PIPE_DIR/runs/v1-current}"
REQUIRED_INDEX=("${BASE}.ri" "${BASE}.paths" "${BASE}.gfa")
for m in "${MODE_ARRAY[@]}"; do
    case "$m" in
        lightweight) REQUIRED_INDEX+=("${BASE}.ltags") ;;
        full-tag)    REQUIRED_INDEX+=("${BASE}_compressed.tags") ;;
    esac
done
for f in "${REQUIRED_INDEX[@]}"; do
    [ -f "$INDEX_DIR/$f" ] || {
        echo "ERROR: missing index artifact: $INDEX_DIR/$f"
        echo "Build the index first: ./build_index.sh <config> $(basename "$INDEX_DIR")"
        exit 1
    }
done

PERF_DIR="$PIPE_DIR/perf/$TAG"
SUMMARY="$PERF_DIR/SUMMARY.tsv"
mkdir -p "$PERF_DIR"

# TSV header (if file new). Trial labels: "warmup-1", "warmup-2" (untimed,
# not appended to SUMMARY.tsv at all), then "1".."N" for timed trials.
# summarize.py only reads trial-* subdirs; warmup-* are ignored automatically.
if [ ! -f "$SUMMARY" ]; then
    printf '%s\n' "mode	trial	step	wall_s	maxrss_mb	gaf_lines	bin_bytes	bin_records	cov_md5	stderr_warns	gafpack_total_entries" > "$SUMMARY"
fi

# ---- cross-platform helpers ------------------------------------------------
fsize() { stat -Lc%s "$1" 2>/dev/null || stat -Lf%z "$1" 2>/dev/null; }
fmd5() {
    if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
    else md5 -q "$1"; fi
}

# ---- run_one_trial: do one (find_mems, gafpack) pair under one mode -------
# Args:
#   $1 = mode label (lightweight | full-tag)
#   $2 = trial label (1..N, or "warmup")
#   $3 = absolute path to the trial dir
#   $4 = "skip_summary" if we shouldn't append to SUMMARY.tsv (warmups)
run_one_trial() {
    local mode="$1" trial="$2" tdir="$3" skip_sum="${4:-}"
    mkdir -p "$tdir"
    cd "$tdir"

    # Mode-dependent flags + tag index path
    local tag_index find_mems_flags gafpack_flags
    case "$mode" in
        lightweight)
            tag_index="$INDEX_DIR/${BASE}.ltags"
            find_mems_flags="--lightweight-tags"
            gafpack_flags="--dedup-read-node" ;;
        full-tag)
            tag_index="$INDEX_DIR/${BASE}_compressed.tags"
            find_mems_flags=""
            gafpack_flags="" ;;
    esac

    # Always-clean: remove any prior trial artifacts in this dir
    rm -f mems_path_pos_v2.bin mems_seq_id_starts.out \
          alignment.gaf alignment_coverage.csv

    # ---- 09 find_mems ----
    echo ">>> [$mode trial=$trial] find_mems"
    # find_mems writes <prefix>_path_pos_v2.bin + <prefix>_seq_id_starts.out;
    # using "mems" prefix.
    if [ -n "$find_mems_flags" ]; then
        "$TIME" -v -o "$tdir/find_mems.time" \
            "$PI_BIN/find_mems" \
                "$INDEX_DIR/${BASE}.ri" "$tag_index" "$READS" \
                "$MEM_LEN" "$MIN_OCC" "mems" \
                $find_mems_flags \
            > "$tdir/find_mems.log" 2> "$tdir/find_mems.stderr"
    else
        "$TIME" -v -o "$tdir/find_mems.time" \
            "$PI_BIN/find_mems" \
                "$INDEX_DIR/${BASE}.ri" "$tag_index" "$READS" \
                "$MEM_LEN" "$MIN_OCC" "mems" \
            > "$tdir/find_mems.log" 2> "$tdir/find_mems.stderr"
    fi

    # ---- 10 gafpack ----
    echo ">>> [$mode trial=$trial] gafpack ($([ $EMIT_GAF = 1 ] && echo with-gaf || echo coverage-only))"
    local gafpack_out_flag
    if [ "$EMIT_GAF" = "1" ]; then
        gafpack_out_flag="--gaf-file-prefix alignment"
    else
        gafpack_out_flag="--coverage-prefix alignment"
    fi
    # Run, with no shell-quoting surprises around gafpack_flags (may be empty)
    "$TIME" -v -o "$tdir/gafpack.time" \
        "$GAFPACK" \
            --gfa "$INDEX_DIR/${BASE}.gfa" \
            --path-pos "mems_path_pos_v2.bin" \
            --seq-id-starts "mems_seq_id_starts.out" \
            --path-names "$INDEX_DIR/${BASE}.paths" \
            $gafpack_out_flag \
            $gafpack_flags \
        > "$tdir/gafpack.stdout" 2> "$tdir/gafpack.stderr"

    # ---- per-trial output artifact sizes ----
    {
        echo "# Sizes after $mode trial=$trial"
        for f in mems_path_pos_v2.bin mems_seq_id_starts.out \
                 alignment.gaf alignment_coverage.csv; do
            if [ -f "$f" ]; then
                printf "%-40s %15s bytes\n" "$f" "$(fsize "$f")"
            fi
        done
        [ -f alignment.gaf ] && { echo "# alignment.gaf line count:"; wc -l alignment.gaf; }
        [ -f alignment_coverage.csv ] && { echo "# coverage csv md5:"; fmd5 alignment_coverage.csv; }
    } > "$tdir/sizes.txt"

    [ "$skip_sum" = "skip_summary" ] && return 0

    # ---- parse + append SUMMARY.tsv row ----
    local fm_wall fm_rss gp_wall gp_rss
    fm_wall=$(awk -F': ' '/Elapsed \(wall clock\)/{split($2,a,":"); n=length(a);
              if (n==2) print a[1]*60 + a[2]; else if (n==3) print a[1]*3600 + a[2]*60 + a[3]}' \
              "$tdir/find_mems.time")
    fm_rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$tdir/find_mems.time")
    gp_wall=$(awk -F': ' '/Elapsed \(wall clock\)/{split($2,a,":"); n=length(a);
              if (n==2) print a[1]*60 + a[2]; else if (n==3) print a[1]*3600 + a[2]*60 + a[3]}' \
              "$tdir/gafpack.time")
    gp_rss=$(awk -F': ' '/Maximum resident set size/{print int($2/1024)}' "$tdir/gafpack.time")

    local bin_bytes=0 bin_recs=0 gaf_lines=0 cov_md5="-" gp_total="-" gp_warns
    [ -f mems_path_pos_v2.bin ] && {
        bin_bytes=$(fsize mems_path_pos_v2.bin)
        bin_recs=$((bin_bytes / 16))
    }
    [ -f alignment.gaf ] && gaf_lines=$(wc -l < alignment.gaf | tr -d ' ')
    [ -f alignment_coverage.csv ] && cov_md5=$(fmd5 alignment_coverage.csv)
    gp_total=$(awk -F': ' '/Total GAF entries/{print $2}' "$tdir/gafpack.stderr" 2>/dev/null | tr -d ' ')
    [ -z "$gp_total" ] && gp_total="-"
    gp_warns=$(grep -cE '^(ERROR|WARN)' "$tdir/gafpack.stderr" 2>/dev/null || true)
    [ -z "$gp_warns" ] && gp_warns=0

    {
        printf '%s\t%s\tfind_mems\t%s\t%s\t-\t-\t-\t-\t-\t-\n' \
            "$mode" "$trial" "$fm_wall" "$fm_rss"
        printf '%s\t%s\tgafpack\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$mode" "$trial" "$gp_wall" "$gp_rss" \
            "$gaf_lines" "$bin_bytes" "$bin_recs" "$cov_md5" "$gp_warns" "$gp_total"
    } >> "$SUMMARY"

    printf '    find_mems: %ss / %sMB   gafpack: %ss / %sMB' \
        "$fm_wall" "$fm_rss" "$gp_wall" "$gp_rss"
    [ "$EMIT_GAF" = "1" ] && printf '   .gaf: %s lines' "$gaf_lines"
    echo
}

# ---- Provenance + run banner -----------------------------------------------
{
    echo "Tag:          $TAG"
    echo "Started:      $(date)"
    echo "Host:         $(hostname)"
    echo "OS:           $(uname -a)"
    echo "Config:       $CONFIG"
    echo "Index dir:    $INDEX_DIR"
    echo "Modes:        ${MODE_ARRAY[*]}"
    echo "Trials:       $N_TRIALS  (+2 warmups per mode, untimed)"
    echo "Ordering:     contiguous (all of mode A, then all of mode B)"
    echo "GAF output:   $([ $EMIT_GAF = 1 ] && echo enabled || echo coverage-only)"
    echo "MEM_LEN:      $MEM_LEN     MIN_OCC: $MIN_OCC"
    echo
    echo "Binaries:"
    printf "  %-12s %s  md5=%s\n" "find_mems" "$PI_BIN/find_mems" "$(fmd5 "$PI_BIN/find_mems")"
    printf "  %-12s %s  md5=%s\n" "gafpack"   "$GAFPACK"          "$(fmd5 "$GAFPACK")"
    echo
    echo "Input files:"
    [ -f "${GBZ:-}" ] && printf "  %-32s %15s bytes  %s\n" "$(basename "$GBZ"):" "$(fsize "$GBZ")" "$GBZ"
    printf "  %-32s %15s bytes  %s\n" "$(basename "$READS"):" "$(fsize "$READS")" "$READS"
    echo
    echo "Index files in INDEX_DIR (built once via build_index.sh):"
    for f in "${BASE}.seq" "${BASE}.rl_bwt" "${BASE}.ri" "${BASE}.tags" \
             "${BASE}_compressed.tags" "${BASE}.ltags" "${BASE}.paths" "${BASE}.gfa"; do
        if [ -f "$INDEX_DIR/$f" ]; then
            printf "  %-40s %15s bytes\n" "$f:" "$(fsize "$INDEX_DIR/$f")"
        fi
    done
} > "$PERF_DIR/PROVENANCE.txt"

echo "==============================================="
echo " Perf harness: $TAG"
echo " Config:    $CONFIG"
echo " Modes:     ${MODE_ARRAY[*]}"
echo " Trials:    $N_TRIALS per mode (+2 warmups each, contiguous ordering)"
echo " GAF:       $([ $EMIT_GAF = 1 ] && echo enabled || echo coverage-only)"
echo " Index dir: $INDEX_DIR"
echo " Output:    $PERF_DIR"
echo "==============================================="

# ---- Per-mode contiguous: 2 warmups + N timed trials --------------------
# Contiguous (not interleaved) so the OS page cache reaches steady-state
# warm for each mode before timing. Mid-run mode switches would cause cache
# thrash between .ltags (~3.6GB) and _compressed.tags (~19GB), polluting
# the timed numbers. The 2-warmup design: warmup #1 brings the index pages
# into cache; warmup #2 ensures any JIT, allocator-arena, or first-touch
# overhead is amortized. Trade-off: lose protection against host drift
# DURING the run (other users' jobs, thermal throttling). For HPRC scale
# this is acceptable since each per-mode block is bounded (~33 min at
# 5 trials × ~400s).
for mode in "${MODE_ARRAY[@]}"; do
    echo
    echo "===== Mode: $mode ====="
    echo "-- 2 warmups (untimed, stabilizes OS disk cache for this mode)"
    for w in 1 2; do
        run_one_trial "$mode" "warmup-$w" "$PERF_DIR/$mode/warmup-$w" skip_summary
    done
    echo "-- $N_TRIALS timed trials"
    for i in $(seq 1 "$N_TRIALS"); do
        run_one_trial "$mode" "$i" "$PERF_DIR/$mode/trial-$i"
    done
done

echo
echo "Finished: $(date)" >> "$PERF_DIR/PROVENANCE.txt"

# ---- Inline summary --------------------------------------------------------
echo
echo "===== Inline summary (mean ± stdev across trials) ====="
for mode in "${MODE_ARRAY[@]}"; do
    echo
    echo "--- $mode ---"
    # Per-mode means of find_mems wall, find_mems rss, gafpack wall, gafpack rss
    # Warmups are never written to SUMMARY.tsv (skip_summary), so the only
    # filter needed is the mode + step.
    awk -F'\t' -v M="$mode" '
        $1 == M {
            if ($3 == "find_mems") { fm_wall[++fmc] = $4; fm_rss[fmc] = $5 }
            if ($3 == "gafpack")   { gp_wall[++gpc] = $4; gp_rss[gpc] = $5 }
        }
        END {
            function mean(arr, n,    s,i) { for(i=1;i<=n;i++) s+=arr[i]; return s/n }
            function sd(arr, n, m,    s,i) {
                if (n<2) return 0
                for(i=1;i<=n;i++) s+=(arr[i]-m)^2; return sqrt(s/(n-1))
            }
            if (fmc > 0) {
                m1=mean(fm_wall,fmc); s1=sd(fm_wall,fmc,m1)
                m2=mean(fm_rss,fmc);  s2=sd(fm_rss,fmc,m2)
                printf "  find_mems  wall %6.2f ± %4.2f s   peak %6.0f ± %4.0f MB   (n=%d)\n", m1, s1, m2, s2, fmc
            }
            if (gpc > 0) {
                m1=mean(gp_wall,gpc); s1=sd(gp_wall,gpc,m1)
                m2=mean(gp_rss,gpc);  s2=sd(gp_rss,gpc,m2)
                printf "  gafpack    wall %6.2f ± %4.2f s   peak %6.0f ± %4.0f MB   (n=%d)\n", m1, s1, m2, s2, gpc
            }
            if (fmc > 0 && gpc > 0) {
                tot = mean(fm_wall,fmc) + mean(gp_wall,gpc)
                printf "  total 09+10 wall %6.2f s\n", tot
            }
        }
    ' "$SUMMARY"
done

echo
echo "===== Aggregate with: ====="
echo "  python3 $PIPE_DIR/perf/summarize.py $PERF_DIR"
echo "  (or read $SUMMARY directly as TSV)"
