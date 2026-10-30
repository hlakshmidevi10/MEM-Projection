#!/usr/bin/env bash
# query.sh -- project reads onto a MEM-Projection index as per-node coverage.
#
# Usage:  query.sh -i INDEX_DIR -r READS -o OUT_DIR [-l MIN_MEM_LEN] [-t THREADS] [--gaf] [--validate]
#
#   -i DIR       index from build_index.sh (or any directory with one *.ri and
#                matching .ltags, .paths and .gfa)
#   -r READS     FASTQ, FASTA or one sequence per line; optionally .gz
#   -o DIR       output directory
#   -l N         minimum MEM length (default 25)
#   -t N         threads (default 8)
#   --gaf        also write OUT_DIR/mem.gaf
#   --validate   check mem.gaf against the reads and graph (implies --gaf;
#                needs: pip install gaftools==1.3.0)
#
# Output: OUT_DIR/mem_coverage.csv (node_id,node_coverage), OUT_DIR/run.info, OUT_DIR/logs/
# Run `source <install prefix>/env.sh` first.
set -euo pipefail

usage() { sed -n '4,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()   { printf '[query] %s\n' "$*"; }
die()   { printf '[query] ERROR: %s\n' "$*" >&2; exit 1; }

INDEX="" READS="" OUT="" MEM_LEN=25 THREADS=8 GAF=0 VALIDATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        -i) INDEX=$2; shift 2 ;;
        -r) READS=$2; shift 2 ;;
        -o) OUT=$2; shift 2 ;;
        -l) MEM_LEN=$2; shift 2 ;;
        -t) THREADS=$2; shift 2 ;;
        --gaf) GAF=1; shift ;;
        --validate) GAF=1; VALIDATE=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done
[ -n "$INDEX" ] && [ -n "$READS" ] && [ -n "$OUT" ] || usage 1
[ -f "$READS" ] || die "reads not found: $READS"
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---- Index ----------------------------------------------------------------------
if [ -f "$INDEX/graph.ri" ]; then
    BASE="$INDEX/graph"
else
    ris=$(ls "$INDEX"/*.ri 2>/dev/null || true)
    [ "$(echo "$ris" | grep -c .)" = 1 ] || die "expected one .ri file in $INDEX"
    BASE="${ris%.ri}"
fi
BASE="$(cd "$(dirname "$BASE")" && pwd)/$(basename "$BASE")"
for ext in ri ltags paths gfa; do
    [ -e "$BASE.$ext" ] || die "index is missing $BASE.$ext"
done

for t in find_mems path-walker; do
    command -v "$t" >/dev/null || die "$t not on PATH; run: source <install prefix>/env.sh"
done
if [ "$VALIDATE" = 1 ]; then
    command -v gaftools >/dev/null || die "--validate needs gaftools; run: pip install gaftools==1.3.0"
    gaftools --help >/dev/null 2>&1 || die "gaftools is installed but does not run; check: gaftools --help"
fi

mkdir -p "$OUT/logs"
OUT="$(cd "$OUT" && pwd)"
export OMP_NUM_THREADS="$THREADS"

# ---- Reads -> one sequence per line ------------------------------------------------
log "reads: $READS"
open_reads() { case "$READS" in *.gz) gzip -dc "$READS" ;; *) cat "$READS" ;; esac; }
first=$(open_reads | head -c 1 || true)
case "$first" in
    @)  open_reads | awk 'NR % 4 == 2' ;;
    \>) open_reads | awk '/^>/ {if (s != "") print s; s = ""; next} {s = s $0} END {if (s != "") print s}' ;;
    *)  open_reads ;;
esac | tr -d '\r' | tr 'acgtn' 'ACGTN' > "$OUT/reads.txt"
NUM_READS=$(wc -l < "$OUT/reads.txt" | tr -d ' ')
[ "$NUM_READS" -gt 0 ] || die "no reads found in $READS"

# ---- MEMs -> coverage ----------------------------------------------------------------
log "find_mems: $NUM_READS reads, MEM length >= $MEM_LEN"
start=$SECONDS
find_mems "$BASE.ri" "$BASE.ltags" "$OUT/reads.txt" "$MEM_LEN" 1 "$OUT/mem" \
    --lightweight-tags --use-flipped-mems > "$OUT/logs/find_mems.log" 2>&1 \
    || { tail -n 20 "$OUT/logs/find_mems.log" >&2; die "find_mems failed; full log: $OUT/logs/find_mems.log"; }
log "  $((SECONDS - start)) s"

log "path-walker"
start=$SECONDS
if [ "$GAF" = 1 ]; then out_flag=(--gaf-file-prefix "$OUT/mem"); else out_flag=(--coverage-prefix "$OUT/mem"); fi
path-walker --gfa "$BASE.gfa" --path-pos "$OUT/mem_path_pos_v2.bin" --seq-id-starts "$OUT/mem_seq_id_starts.out" \
    --path-names "$BASE.paths" --dedup-read-node --threads "$THREADS" "${out_flag[@]}" > "$OUT/logs/path_walker.log" 2>&1 \
    || { tail -n 20 "$OUT/logs/path_walker.log" >&2; die "path-walker failed; full log: $OUT/logs/path_walker.log"; }
log "  $((SECONDS - start)) s"

if [ "$VALIDATE" = 1 ]; then
    log "validate: 2000 sampled GAF records"
    python3 "$HERE/scripts/validate_gaf_v2.py" "$OUT/mem.gaf" "$OUT/reads.txt" "$BASE.gfa" --sample 2000 \
        > "$OUT/logs/validate.log" 2>&1 || die "validation failed; see $OUT/logs/validate.log"
    grep -E '^(Valid|Invalid|Total) entries' "$OUT/logs/validate.log" | sed 's/^/[query]   /' || true
fi

# ---- Record and clean up ---------------------------------------------------------------
{
    echo "index:      $BASE"
    echo "reads:      $READS ($NUM_READS reads)"
    echo "min_mem:    $MEM_LEN"
    echo "threads:    $THREADS"
    echo "finished:   $(date -u '+%Y-%m-%d %H:%M:%S UTC') on $(hostname)"
    [ -f "${MEM_PROJECTION_HOME:-}/versions.tsv" ] && sed 's/^/tool:       /' "$MEM_PROJECTION_HOME/versions.tsv"
} > "$OUT/run.info"
rm -f "$OUT/mem_path_pos_v2.bin" "$OUT/mem_seq_id_starts.out" "$OUT/reads.txt"
log "coverage: $OUT/mem_coverage.csv"
