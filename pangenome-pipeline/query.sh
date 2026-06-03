#!/bin/bash
# =============================================================================
# pangenome-index — QUERY driver (steps 09–11)
#
# Usage:  ./query.sh <config.env> <index-tag> [query-name] [--gaf]
#   config.env  — see configs/*.env for the variable contract.
#                 Must set: BASE, READS, MEM_LEN, MIN_OCC.
#                 Required only with --gaf: VALIDATE_SAMPLE.
#                 Ignored:  GBZ (not needed at query time — index already built),
#                           OUT  (per-query subdir name disambiguates outputs),
#                           GFA  (uses the derived GFA from build_index.sh).
#   index-tag   — name of an existing runs/<index-tag>/ produced by build_index.sh.
#                 Must contain: <BASE>.{ri,ltags,paths,gfa} (last only with --gaf).
#   query-name  — output subdir under runs/<index-tag>/queries/.
#                 Default: config filename with `.env` stripped and any leading
#                 `<dataset>-` prefix removed (e.g. `hprcv1-chr6-ref-reads.env`
#                 → `ref-reads`). Override to anything if defaults collide.
#   --gaf       — additionally produce alignment.gaf AND run validate_gaf.
#                 Without --gaf: gafpack runs in coverage-only mode (default).
#                 This matches the production deploy pattern where only
#                 coverage is needed; .gaf + validation are test-only overhead.
#
# Outputs (default = coverage-only mode, no --gaf):
#   runs/<index-tag>/queries/<query-name>/
#     mems_path_pos_v2.bin           (09: find_mems --lightweight-tags)
#     mems_seq_id_starts.out         (09)
#     alignment_coverage.csv         (10: gafpack --dedup-read-node, no GAF)
#     logs/09_find_mems.{log,time}
#     logs/10_gafpack.{log,time}
#     logs/timing_summary.txt        rebuilt from this query's *.time files
#     RUN_INFO.txt                   query provenance (incl. index file mtimes)
#     config.env  -> $CONFIG
#     reads       -> $READS
#
# Additional outputs with --gaf:
#     alignment.gaf                  (10: gafpack also writes GAF)
#     logs/11_validate_gaf.{log,time} (11: validate_gaf_v2.py --sample N)
#
# Each step is guarded by [ -f <output> ]; re-invocation skips completed steps.
# Switching modes mid-query (e.g. re-running with --gaf after a coverage-only
# run) re-runs step 10 to produce the .gaf (gafpack is fast). To force a full
# re-run: rm the query subdir.
#
# Validation (step 11, only with --gaf) requires gaftools==1.3.0; pinned by
# bootstrap_vesuvio.sh.
# =============================================================================
set -euo pipefail

PIPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEM_PROJ="$(cd "$PIPE_DIR/.." && pwd)"

# ---- Tool locations --------------------------------------------------------
PI_BIN="${PI_BIN:-/Users/hlakshmidevi/personal/pangenome-index-latest/bin}"
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
# Accept --gaf anywhere in the arg list. Strip it out, leaving positional args.
EMIT_GAF=0
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --gaf) EMIT_GAF=1 ;;
        --help|-h)
            sed -n '2,46p' "$0"; exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

[ $# -ge 2 ] || { echo "Usage: $0 <config.env> <index-tag> [query-name] [--gaf]"; exit 2; }
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
for f in "${BASE}.ri" "${BASE}.ltags" "${BASE}.paths" "${BASE}.gfa"; do
    [ -f "$INDEX_DIR/$f" ] || { echo "ERROR: missing index artifact: $INDEX_DIR/$f"; exit 1; }
done

# ---- Set up the per-query dir ---------------------------------------------
QUERY_DIR="$INDEX_DIR/queries/$QUERY_NAME"
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
    if [ "$EMIT_GAF" = "1" ]; then
        echo "Mode:          --gaf (alignment.gaf produced; validate_gaf runs)"
        echo "VALIDATE_SAMPLE: $VALIDATE_SAMPLE"
    else
        echo "Mode:          coverage-only (no .gaf, no validation)"
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
LTAGS="$INDEX_DIR/${BASE}.ltags"
PATHS="$INDEX_DIR/${BASE}.paths"
GFA="$INDEX_DIR/${BASE}.gfa"

echo "=== Query setup ==="
echo "  Index:     $INDEX_DIR"
echo "  Reads:     $READS ($(du -h "$READS" | cut -f1))"
echo "  Output:    $QUERY_DIR"
if [ "$EMIT_GAF" = "1" ]; then
    echo "  Mode:      --gaf (gafpack writes alignment.gaf; validate_gaf runs)"
else
    echo "  Mode:      coverage-only (no .gaf, no validate; pass --gaf to enable)"
fi
echo

# === 09 find_mems ===========================================================
echo "=== 09 find_mems (L=$MEM_LEN, occ>=$MIN_OCC, --lightweight-tags) ==="
# find_mems writes <prefix>_path_pos_v2.bin and <prefix>_seq_id_starts.out.
# Using "mems" as the prefix → mems_path_pos_v2.bin, mems_seq_id_starts.out.
[ -f "mems_path_pos_v2.bin" ] || profile 09_find_mems "$PI_BIN/find_mems" \
    "$RI" "$LTAGS" "$READS" "$MEM_LEN" "$MIN_OCC" "mems" \
    --lightweight-tags

# === 10 gafpack =============================================================
# Two output modes:
#   default:  --coverage-prefix alignment   → alignment_coverage.csv only
#   --gaf:    --gaf-file-prefix alignment   → alignment_coverage.csv + alignment.gaf
#
# The resume guard differs by mode: coverage-only mode keys on
# alignment_coverage.csv; --gaf mode keys on alignment.gaf. Switching from
# coverage-only to --gaf re-runs step 10 (gafpack is fast); switching the
# other way is a no-op (the .gaf stays put but we don't use it).
if [ "$EMIT_GAF" = "1" ]; then
    echo "=== 10 gafpack (--dedup-read-node + --gaf-file-prefix, with GAF) ==="
    [ -f "alignment.gaf" ] || profile 10_gafpack "$GAFPACK" \
        --gfa "$GFA" \
        --path-pos "mems_path_pos_v2.bin" \
        --seq-id-starts "mems_seq_id_starts.out" \
        --path-names "$PATHS" \
        --gaf-file-prefix "alignment" \
        --dedup-read-node
else
    echo "=== 10 gafpack (--dedup-read-node, coverage-only mode) ==="
    [ -f "alignment_coverage.csv" ] || profile 10_gafpack "$GAFPACK" \
        --gfa "$GFA" \
        --path-pos "mems_path_pos_v2.bin" \
        --seq-id-starts "mems_seq_id_starts.out" \
        --path-names "$PATHS" \
        --coverage-prefix "alignment" \
        --dedup-read-node
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
ls -lh mems_*.bin mems_*.out alignment.gaf alignment_coverage.csv 2>/dev/null \
    | awk '{printf "  %-40s %8s\n", $NF, $5}'
if [ "$EMIT_GAF" = "0" ]; then
    echo
    echo "Coverage-only mode — no .gaf, no validation."
    echo "To get the .gaf and validate: re-run with --gaf"
fi
echo
if [ "$EMIT_GAF" = "1" ]; then
    grep -E '^(Valid|Invalid|Total) entries' "$LOGS/11_validate_gaf.log" || true
fi
