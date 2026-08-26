#!/bin/bash
# =============================================================================
# pangenome-index — QUERY driver (steps 09–11)
#
# Usage:  ./query.sh <config.env> <index-tag> [query-name] [--gaf] [--full-tag|--all-positions]
#   config.env   — see configs/*.env for the variable contract.
#                  Must set: BASE, READS, MEM_LEN, MIN_OCC.
#                  Required only with --gaf: VALIDATE_SAMPLE.
#                  Ignored:  GBZ (not needed at query time — index already built),
#                            OUT  (per-query subdir name disambiguates outputs),
#                            GFA  (uses the derived GFA from build_index.sh).
#   index-tag    — name of an existing runs/<index-tag>/ produced by build_index.sh.
#                  Default tag-index requirement: <BASE>.{ri,ltags,paths,gfa}.
#                  With --full-tag:                <BASE>.{ri,_compressed.tags,paths,gfa}.
#                  With --all-positions:           <BASE>.{ri,paths,gfa}  (no tag index).
#   query-name   — output subdir under runs/<index-tag>/queries/<query-name>/<tag-mode>/.
#                  Default: config filename with `.env` stripped and any leading
#                  `<dataset>-` prefix removed (e.g. `hprcv1-chr6-ref-reads.env`
#                  → `ref-reads`).
#   --gaf        — additionally produce alignment.gaf AND run validate_gaf.
#                  Without --gaf: gafpack runs in coverage-only mode (default).
#                  Production deploys only need coverage; .gaf + validation
#                  are test-only overhead.
#   --full-tag   — use the full compressed-tags index (.tags via convert_tags) +
#                  gafpack without --dedup-read-node, i.e. the pre-lightweight
#                  pipeline. Default is lightweight (.ltags + --dedup-read-node).
#                  Outputs of the two modes are written to SEPARATE subdirs
#                  (queries/<name>/lightweight/ vs queries/<name>/full-tag/) so
#                  they never collide. Use --full-tag for A/B regression checks
#                  against the lightweight default.
#   --all-positions — verification/POC mode. find_mems bypasses the tag array
#                  and emits ONE entry per BWT position in each MEM (mem.size
#                  entries per MEM); gafpack runs with --dedup-read-node. The
#                  deduped result is the ground truth against which the
#                  lightweight pipeline's dedup logic can be checked. Output
#                  volume is large; intended for small reads sets only.
#                  Lands in queries/<name>/all-positions/. Mutually exclusive
#                  with --full-tag.
#
# Output layout:
#   runs/<index-tag>/queries/<query-name>/
#   ├── lightweight/                     ← created without --full-tag (default)
#   │   ├── mems_path_pos_v2.bin         (09: find_mems --lightweight-tags)
#   │   ├── mems_seq_id_starts.out       (09)
#   │   ├── alignment_coverage.csv       (10: gafpack --dedup-read-node)
#   │   ├── alignment.gaf                (10: only with --gaf)
#   │   ├── logs/09_find_mems.{log,time}
#   │   ├── logs/10_gafpack.{log,time}
#   │   ├── logs/11_validate_gaf.{log,time}  (only with --gaf)
#   │   ├── logs/timing_summary.txt
#   │   ├── RUN_INFO.txt
#   │   ├── config.env -> $CONFIG
#   │   └── reads      -> $READS
#   ├── full-tag/                        ← created with --full-tag
#   │   └── ...same structure, different tag index + gafpack flags...
#   └── all-positions/                   ← created with --all-positions
#       └── ...same structure, find_mems w/o tag index + gafpack --dedup-read-node...
#
# Each step is guarded by [ -f <output> ]; re-invocation skips completed steps.
# Adding --gaf to a previously coverage-only run re-runs step 10 in the SAME
# mode subdir (gafpack is fast) to produce alignment.gaf, then runs step 11.
#
# Validation (step 11, only with --gaf) requires gaftools==1.3.0; pinned by
# bootstrap_vesuvio.sh.
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Tool locations --------------------------------------------------------
PI_BIN="${PI_BIN:-$HOME/dev/pangenome-index-pvt/bin}"
GAFPACK="${GAFPACK:-gafpack}"
VALIDATE_GAF="${VALIDATE_GAF:-$MEM_PROJ/scripts/validate_gaf_v2.py}"

# ---- time(1) detection -----------------------------------------------------
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
# Accept flags anywhere in the arg list. Strip them out, leaving positionals.
EMIT_GAF=0
TAG_MODE="lightweight"   # default; --full-tag / --all-positions flip this
TAG_MODE_EXPLICIT=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --gaf)             EMIT_GAF=1 ;;
        --full-tag)        TAG_MODE="full-tag";     TAG_MODE_EXPLICIT=$((TAG_MODE_EXPLICIT+1)) ;;
        --lightweight)     TAG_MODE="lightweight";  TAG_MODE_EXPLICIT=$((TAG_MODE_EXPLICIT+1)) ;;
        --all-positions)   TAG_MODE="all-positions";TAG_MODE_EXPLICIT=$((TAG_MODE_EXPLICIT+1)) ;;
        --help|-h)
            sed -n '2,56p' "$0"; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"
if [ "$TAG_MODE_EXPLICIT" -gt 1 ]; then
    echo "ERROR: --lightweight, --full-tag, and --all-positions are mutually exclusive"; exit 2
fi

[ $# -ge 2 ] || { echo "Usage: $0 <config.env> <index-tag> [query-name] [--gaf] [--full-tag|--all-positions]"; exit 2; }
CONFIG="$1"
INDEX_TAG="$2"
[ -f "$CONFIG" ] || CONFIG="$PIPE_DIR/configs/$CONFIG"
[ -f "$CONFIG" ] || { echo "Config not found: $1"; exit 2; }

# Derive default query name: strip .env, strip common dataset prefixes.
# Examples:
#   hprcv1-chr6-ref-reads.env       → ref-reads
#   hprcv1-chr6-alt-noisy-reads.env → alt-noisy-reads
#   yeast235-chrII-normalized.env   → normalized
default_query_name() {
    local base; base=$(basename "$1" .env)
    # Strip 'hprcvN-chrN-' or 'yeastN-chrN-' style dataset prefixes.
    echo "$base" | sed -E 's/^(hprcv[0-9]+-chr[A-Z0-9]+|yeast[0-9]+-chr[A-Z0-9]+)-//'
}
QUERY_NAME="${3:-$(default_query_name "$CONFIG")}"
# Sanitize: no slashes, no spaces.
case "$QUERY_NAME" in
    */*|*\ *) echo "ERROR: query-name must not contain '/' or whitespace: $QUERY_NAME"; exit 2 ;;
esac

# shellcheck source=/dev/null
source "$CONFIG"

# ---- Required config variables --------------------------------------------
for v in BASE READS MEM_LEN MIN_OCC; do
    [ -n "${!v:-}" ] || { echo "ERROR: config $CONFIG missing required variable: $v"; exit 2; }
done
# VALIDATE_SAMPLE only required with --gaf (validation runs only then)
if [ "$EMIT_GAF" = "1" ] && [ -z "${VALIDATE_SAMPLE:-}" ]; then
    echo "ERROR: --gaf was passed but config $CONFIG missing VALIDATE_SAMPLE"
    exit 2
fi
[ -e "$READS" ] || { echo "ERROR: READS file not found: $READS"; exit 1; }

# ---- Locate + validate the index dir --------------------------------------
INDEX_DIR="$PIPE_DIR/runs/$INDEX_TAG"
[ -d "$INDEX_DIR" ] || { echo "ERROR: index dir not found: $INDEX_DIR (run build_index.sh first)"; exit 1; }

# Required index files differ by tag mode.
REQUIRED_INDEX_FILES=("${BASE}.ri" "${BASE}.paths" "${BASE}.gfa")
case "$TAG_MODE" in
    lightweight)   REQUIRED_INDEX_FILES+=("${BASE}.ltags") ;;
    full-tag)      REQUIRED_INDEX_FILES+=("${BASE}_compressed.tags") ;;
    all-positions) ;;  # tag array bypassed; no extra files required
esac
for f in "${REQUIRED_INDEX_FILES[@]}"; do
    [ -f "$INDEX_DIR/$f" ] || { echo "ERROR: missing index artifact for $TAG_MODE mode: $INDEX_DIR/$f"; exit 1; }
done

# ---- Set up the per-query dir ---------------------------------------------
# Outputs of the two tag modes go to separate subdirs so they never collide.
# queries/<name>/lightweight/  vs  queries/<name>/full-tag/
QUERY_DIR="$INDEX_DIR/queries/$QUERY_NAME/$TAG_MODE"
LOGS="$QUERY_DIR/logs"
mkdir -p "$LOGS"
cd "$QUERY_DIR"

# Provenance — including index file mtimes/sizes so future-you can spot
# whether the index was rebuilt since this query ran.
{
    echo "Query:         $QUERY_NAME"
    echo "Index tag:     $INDEX_TAG"
    echo "Index dir:     $INDEX_DIR"
    echo "Config:        $CONFIG"
    echo "READS:         $READS ($(du -h "$READS" | cut -f1))"
    echo "BASE:          $BASE"
    echo "MEM_LEN:       $MEM_LEN"
    echo "MIN_OCC:       $MIN_OCC"
    case "$TAG_MODE" in
        lightweight)   echo "Tag mode:      lightweight (find_mems --lightweight-tags, gafpack --dedup-read-node)" ;;
        full-tag)      echo "Tag mode:      full-tag (find_mems w/o lightweight, gafpack w/o dedup-read-node)" ;;
        all-positions) echo "Tag mode:      all-positions (find_mems --all-positions [tag array bypassed], gafpack --dedup-read-node)" ;;
    esac
    if [ "$EMIT_GAF" = "1" ]; then
        echo "GAF mode:      --gaf (alignment.gaf produced; validate_gaf runs)"
        echo "VALIDATE_SAMPLE: $VALIDATE_SAMPLE"
    else
        echo "GAF mode:      coverage-only (no .gaf, no validation)"
    fi
    echo "Started:       $(date)"
    echo "Host:          $(hostname)"
    echo "PI_BIN:        $PI_BIN"
    echo "GAFPACK:       $GAFPACK"
    git -C "$(dirname "$PI_BIN")" log -1 --format='PI commit:     %h %ci %s' 2>/dev/null || true
    (cd "$(dirname "$GAFPACK")" 2>/dev/null && git log -1 --format='GP commit:     %h %ci %s') 2>/dev/null || true
    echo
    echo "Index file provenance (mtime, size):"
    for f in "${BASE}.ri" "${BASE}.ltags" "${BASE}.paths" "${BASE}.gfa" "${BASE}_compressed.tags"; do
        if [ -f "$INDEX_DIR/$f" ]; then
            stat_line=$(ls -l --time-style=long-iso "$INDEX_DIR/$f" 2>/dev/null \
                        || stat -f '%Sm %z' -t '%Y-%m-%d %H:%M' "$INDEX_DIR/$f" 2>/dev/null)
            printf "  %-32s %s\n" "$f" "$stat_line"
        fi
    done
} > "$QUERY_DIR/RUN_INFO.txt"
ln -sfn "$CONFIG" "$QUERY_DIR/config.env"
ln -sfn "$READS"  "$QUERY_DIR/reads"

TIMING="$LOGS/timing_summary.txt"
: > "$TIMING"

# ---- profiling helpers (mirror build_index.sh) ----------------------------
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

# ---- Index file paths (we cd-ed into QUERY_DIR; reference the INDEX_DIR) --
RI="$INDEX_DIR/${BASE}.ri"
PATHS="$INDEX_DIR/${BASE}.paths"
GFA="$INDEX_DIR/${BASE}.gfa"
# Tag index varies by mode: .ltags for lightweight, _compressed.tags for full-tag,
# /dev/null for all-positions (find_mems --all-positions ignores the arg).
case "$TAG_MODE" in
    lightweight)   TAG_INDEX="$INDEX_DIR/${BASE}.ltags" ;;
    full-tag)      TAG_INDEX="$INDEX_DIR/${BASE}_compressed.tags" ;;
    all-positions) TAG_INDEX="/dev/null" ;;
esac

echo "=== Query setup ==="
echo "  Index:     $INDEX_DIR"
echo "  Tag mode:  $TAG_MODE  ($(basename "$TAG_INDEX"))"
echo "  Reads:     $READS ($(du -h "$READS" | cut -f1))"
echo "  Output:    $QUERY_DIR"
if [ "$EMIT_GAF" = "1" ]; then
    echo "  GAF mode:  --gaf (gafpack writes alignment.gaf; validate_gaf runs)"
else
    echo "  GAF mode:  coverage-only (no .gaf, no validate; pass --gaf to enable)"
fi
echo

# === 09 find_mems ===========================================================
# Lightweight mode: passes --lightweight-tags so find_mems reads .ltags and
# emits one entry per tag run intersecting each MEM (no graph-pos dedup;
# offloaded to gafpack via --dedup-read-node in step 10).
# Full-tag mode: omits --lightweight-tags; find_mems reads _compressed.tags
# and dedups internally (per-haplotype duplicates still counted separately).
# All-positions mode: passes --all-positions; tag array bypassed; emits one
# entry per BWT position in each MEM. gafpack --dedup-read-node then collapses
# down to (read_id, read_st, node, offset) ground truth for verification.
case "$TAG_MODE" in
    lightweight)
        FIND_MEMS_FLAGS=(--lightweight-tags)
        echo "=== 09 find_mems (L=$MEM_LEN, occ>=$MIN_OCC, --lightweight-tags) ===" ;;
    full-tag)
        FIND_MEMS_FLAGS=()
        echo "=== 09 find_mems (L=$MEM_LEN, occ>=$MIN_OCC, full-tag mode) ===" ;;
    all-positions)
        FIND_MEMS_FLAGS=(--all-positions)
        echo "=== 09 find_mems (L=$MEM_LEN, occ>=$MIN_OCC, --all-positions [verify/POC]) ===" ;;
esac
# find_mems writes <prefix>_path_pos_v2.bin and <prefix>_seq_id_starts.out.
# Using "mems" as the prefix → mems_path_pos_v2.bin, mems_seq_id_starts.out.
#
# Optional env var FIND_MEMS_EXTRA_FLAGS lets callers append extra flags
# (e.g., --use-flipped-mems) without editing this script.  Word-splits into
# the argv unmodified; empty by default.  Mirrors the perf_harness.sh hook.
[ -f "mems_path_pos_v2.bin" ] || profile 09_find_mems "$PI_BIN/find_mems" \
    "$RI" "$TAG_INDEX" "$READS" "$MEM_LEN" "$MIN_OCC" "mems" \
    "${FIND_MEMS_FLAGS[@]}" ${FIND_MEMS_EXTRA_FLAGS:-}

# === 10 gafpack =============================================================
# Two orthogonal axes:
#   tag mode:  lightweight → gafpack needs --dedup-read-node (find_mems' lite
#              output contains per-MEM same-node duplicates that gafpack must
#              dedup; without the flag, coverage counts get inflated)
#              full-tag   → no --dedup-read-node (find_mems already dedups;
#              gafpack treats every record as a distinct event)
#   gaf mode:  --gaf       → --gaf-file-prefix alignment (writes .gaf + cov.csv)
#              default     → --coverage-prefix alignment (writes cov.csv only)
#
# Resume guards key on the artifact each invocation produces:
#   coverage-only → alignment_coverage.csv
#   --gaf         → alignment.gaf
# Adding --gaf to a previously coverage-only run re-runs step 10 (cheap).
GAFPACK_FLAGS=(
    --gfa "$GFA"
    --path-pos "mems_path_pos_v2.bin"
    --seq-id-starts "mems_seq_id_starts.out"
    --path-names "$PATHS"
)
# Both lightweight and all-positions feed gafpack unfiltered records and rely
# on it for graph-position dedup. full-tag's records are already deduped by
# find_mems so we omit the flag there.
if [ "$TAG_MODE" = "lightweight" ] || [ "$TAG_MODE" = "all-positions" ]; then
    GAFPACK_FLAGS+=(--dedup-read-node)
fi

if [ "$EMIT_GAF" = "1" ]; then
    echo "=== 10 gafpack ($TAG_MODE mode, --gaf-file-prefix) ==="
    [ -f "alignment.gaf" ] || profile 10_gafpack "$GAFPACK" \
        "${GAFPACK_FLAGS[@]}" \
        --gaf-file-prefix "alignment"
else
    echo "=== 10 gafpack ($TAG_MODE mode, --coverage-prefix only) ==="
    [ -f "alignment_coverage.csv" ] || profile 10_gafpack "$GAFPACK" \
        "${GAFPACK_FLAGS[@]}" \
        --coverage-prefix "alignment"
fi

# === 11 validate_gaf (only with --gaf) ======================================
if [ "$EMIT_GAF" = "1" ]; then
    echo "=== 11 validate_gaf (n=$VALIDATE_SAMPLE) ==="
    # validate_gaf reconstructs path sequences against the same GFA gafpack walked.
    profile 11_validate_gaf python3 "$VALIDATE_GAF" "alignment.gaf" "$READS" "$GFA" --sample "$VALIDATE_SAMPLE"
fi

# === Summary ================================================================
echo
echo "Finished: $(date)" >> "$QUERY_DIR/RUN_INFO.txt"
summarize_timing > "$TIMING"
echo "=== TIMING SUMMARY ($TIMING) ==="
cat "$TIMING"
echo
echo "=== OUTPUTS ($QUERY_DIR/) ==="
# `|| true` is load-bearing under `set -euo pipefail` (top of file). In
# coverage-only mode alignment.gaf deliberately does not exist, so ls exits 2;
# pipefail propagates that through the pipe and set -e then aborts the script
# *at its own summary* — after all real work has completed. The symptom was a
# successful run reporting exit 2, with the "Coverage-only mode" note below
# never printed. Only --gaf runs were unaffected, since the file exists there.
ls -lh mems_*.bin mems_*.out alignment.gaf alignment_coverage.csv 2>/dev/null \
    | awk '{printf "  %-40s %8s\n", $NF, $5}' || true
if [ "$EMIT_GAF" = "0" ]; then
    echo
    echo "Coverage-only mode (tag=$TAG_MODE) — no .gaf, no validation."
    echo "To get the .gaf and validate: re-run with --gaf"
fi
echo
if [ "$EMIT_GAF" = "1" ]; then
    grep -E '^(Valid|Invalid|Total) entries' "$LOGS/11_validate_gaf.log" || true
fi
