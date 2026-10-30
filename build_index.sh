#!/usr/bin/env bash
# build_index.sh -- build a MEM-Projection index from a pangenome graph.
#
# Usage:  build_index.sh -g GRAPH -o INDEX_DIR [-t THREADS] [--tmp DIR] [--keep-intermediates]
#
#   -g GRAPH     .gbz, or .gfa with PanSN path names (sample#hap#contig)
#   -o DIR       output directory; re-running resumes where it stopped
#   -t N         threads (default 8)
#   --tmp DIR    grlBWT temporary directory (default DIR/grl_tmp; same filesystem as DIR)
#   --keep-intermediates
#                keep graph.seq, graph.rl_bwt, graph.tags and graph_compressed.tags
#
# Output: DIR/graph.{ri,ltags,paths,gfa}, DIR/index.info, DIR/logs/
# Run `source <install prefix>/env.sh` first.
set -euo pipefail

usage() { sed -n '4,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
log()   { printf '[build_index] %s\n' "$*"; }
die()   { printf '[build_index] ERROR: %s\n' "$*" >&2; exit 1; }

GRAPH="" OUT="" THREADS=8 TMP="" KEEP=0
while [ $# -gt 0 ]; do
    case "$1" in
        -g) GRAPH=$2; shift 2 ;;
        -o) OUT=$2; shift 2 ;;
        -t) THREADS=$2; shift 2 ;;
        --tmp) TMP=$2; shift 2 ;;
        --keep-intermediates) KEEP=1; shift ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done
[ -n "$GRAPH" ] && [ -n "$OUT" ] || usage 1
[ -f "$GRAPH" ] || die "graph not found: $GRAPH"
GRAPH="$(cd "$(dirname "$GRAPH")" && pwd)/$(basename "$GRAPH")"
case "$GRAPH" in
    *.gbz) FORMAT=gbz ;;
    *.gfa) FORMAT=gfa ;;
    *) die "graph must be .gbz or .gfa: $GRAPH" ;;
esac

TOOLS="gbz_stats gbz_extract grlbwt-cli build_rindex build_tags convert_tags build_lightweight_tags path_extract"
[ "$FORMAT" = gfa ] && TOOLS="$TOOLS gfa2gbwt"
for t in $TOOLS; do
    command -v "$t" >/dev/null || die "$t not on PATH; run: source <install prefix>/env.sh"
done
command -v vg >/dev/null || die "vg not on PATH (needed to write graph.gfa); on macOS, build vg from source"

mkdir -p "$OUT/logs" "$OUT/.steps"
OUT="$(cd "$OUT" && pwd)"
TMP="${TMP:-$OUT/grl_tmp}"
mkdir -p "$TMP"
cd "$OUT"
export OMP_NUM_THREADS="$THREADS"

# step NAME CMD...: run CMD once; stdout+stderr go to logs/NAME.log.
step() {
    local name=$1 start=$SECONDS; shift
    [ -f ".steps/$name" ] && { log "$name: done earlier"; return; }
    log "$name"
    "$@" > "logs/$name.log" 2>&1 \
        || { tail -n 20 "logs/$name.log" >&2; die "$name failed; full log: $OUT/logs/$name.log"; }
    log "  $((SECONDS - start)) s"
    touch ".steps/$name"
}
# to FILE CMD...: run CMD with stdout to FILE (stderr goes to the step log).
to() { local f=$1; shift; "$@" > "$f"; }

# ---- 1. GBZ -------------------------------------------------------------------
if [ "$FORMAT" = gfa ]; then
    # gfa2gbwt reads BASE.gfa and writes BASE.gbz; -m 1024 keeps every node
    # within build_tags' 10-bit offset.
    ln -sf "$GRAPH" input.gfa
    step 01_gfa2gbwt gfa2gbwt -c -p --pan-sn -m 1024 --gbz-v1 -P "$THREADS" input
    mv -f input.gbz graph.gbz 2>/dev/null || true
    rm -f input.gfa
    GBZ="$OUT/graph.gbz"
else
    GBZ="$GRAPH"
fi

# ---- 2. Graph statistics and disk check ---------------------------------------
step 02_gbz_stats sh -c "gbz_stats -i '$GBZ' && gbz_stats -p '$GBZ'"
NUM_SEQ=$(awk '/^Sequences:/ {print $2}' logs/02_gbz_stats.log)
PATH_LEN=$(awk '/^Path length/ {print $3}' logs/02_gbz_stats.log)
[ -n "$NUM_SEQ" ] && [ -n "$PATH_LEN" ] || die "could not read Sequences / Path length from logs/02_gbz_stats.log"
SEQ_BYTES=$((2 * PATH_LEN + NUM_SEQ))   # graph.seq: both orientations plus one terminator per sequence

if [ ! -f .steps/05_grlbwt ]; then
    # Peak disk is graph.seq plus grlBWT's temporary files (up to ~1.8x graph.seq).
    need_kb=$((SEQ_BYTES * 3 / 1024))
    for d in "$OUT" "$TMP"; do
        free_kb=$(df -Pk "$d" | awk 'NR==2 {print $4}')
        [ "$free_kb" -ge "$need_kb" ] \
            || die "$d has $((free_kb / 1048576)) GiB free; this graph needs about $((need_kb / 1048576 + 1)) GiB"
    done
fi

# ---- 3. GFA with the GBZ's node IDs --------------------------------------------
step 03_vg_convert to graph.gfa vg convert -fW --no-translation "$GBZ"
MAX_NODE=$(awk -F'\t' '$1=="S" {l=length($3); if (l>m) m=l} END {print m+0}' graph.gfa)
[ "$MAX_NODE" -le 1024 ] || die "graph has a ${MAX_NODE} bp node; build_tags needs nodes <= 1024 bp (rebuild the GBZ with gfa2gbwt -m 1024)"

# ---- 4. Index -------------------------------------------------------------------
step 04_gbz_extract to graph.seq gbz_extract -b -t "$THREADS" -p "$GBZ"
step 05_grlbwt grlbwt-cli graph.seq -t "$THREADS" -T "$TMP" -o graph.rl_bwt
step 06_build_rindex to graph.ri build_rindex graph.rl_bwt
step 07_build_tags build_tags -k 31 "$GBZ" graph.rl_bwt graph.tags
step 08_convert_tags convert_tags graph.tags graph_compressed.tags --num-seq "$NUM_SEQ"

# Every BWT position must map to a tag run: bwt_intervals has one entry per
# graph.seq byte plus one.
INTERVALS=$(grep -oE 'bwt_intervals vector with size [0-9]+' logs/08_convert_tags.log | awk '{print $NF}' || true)
[ "$INTERVALS" = "$((SEQ_BYTES + 1))" ] \
    || die "tag array does not match the BWT (bwt_intervals $INTERVALS, expected $((SEQ_BYTES + 1)))"

step 09_build_lightweight_tags build_lightweight_tags graph_compressed.tags graph.ltags
step 10_path_extract path_extract "$GBZ" graph.paths

# ---- 5. Record and clean up ------------------------------------------------------
{
    echo "graph:      $GRAPH"
    echo "built:      $(date -u '+%Y-%m-%d %H:%M:%S UTC') on $(hostname)"
    echo "threads:    $THREADS"
    echo "kmer:       31"
    echo "sequences:  $NUM_SEQ"
    echo "path_bp:    $PATH_LEN"
    echo "max_node:   $MAX_NODE"
    [ -f "${MEM_PROJECTION_HOME:-}/versions.tsv" ] && sed 's/^/tool:       /' "$MEM_PROJECTION_HOME/versions.tsv"
} > index.info

if [ "$KEEP" = 0 ]; then
    rm -f graph.seq graph.rl_bwt graph.tags graph_compressed.tags
fi
[ "$TMP" = "$OUT/grl_tmp" ] && rm -rf "$TMP"
log "index ready: $OUT"
