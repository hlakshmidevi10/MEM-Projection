# Findings: yeast-235 chrII pipeline reproduction with `pangenome-index-latest` (post-refactor)

**Run dir:** `pangenome-pipeline/runs/2026-05-03/`
**Baseline:** `yeast-235/yeast-235-chrI/final_output2/PERFORMANCE_COMPARISON.md` (normalized-graph column)
**Toolchain:** `pangenome-index-latest` @ `6073141` (2026-05-03), `gafpack` @ Mar 30 build
**Host:** M-Q7Q6XPVH36 (darwin arm64)
**Started:** 2026-05-03 15:55 PDT · **Fixed & re-run:** 2026-05-04 20:59 PDT

---

## TL;DR

| | |
|---|---|
| Index build (steps 1–8) | ✅ Completed; `.seq` `.rl_bwt` `.tags` `.paths` byte-identical to reference |
| `find_mems` → `gafpack` → `validate_gaf` | ✅ **2000/2000 (100%) valid** after fix |
| Root cause of initial failure | **`convert_tags` called without `--num-seq`** → bwt_intervals 634 short → every tag lookup misaligned |
| Performance vs baseline | find_mems −5% wall / **−40% peak RSS**; r-index −70% mem; **tag-query path +469%** (regression) |

The first attempt (May 3) hung at `gafpack` because step 6 omitted `--num-seq 634`. After adding the flag and re-running steps 6–11, all outputs match an independent successful run (`/tmp/y235-full/`) byte-for-byte and validation passes.

---

## Per-step profiling (validated run)

| Step | Wall | MaxRSS | Output | Size | Baseline |
|---|--:|--:|---|--:|---|
| 01 `gbz_stats` | 1s | 252 MB | — | — | — |
| 02 `gbz_extract -b -t16 -p` | 1s | 304 MB | `.seq` | 322 M | identical (md5) |
| 03 `grlbwt-cli -t16` | 13s | 631 MB | `.rl_bwt` | 67 M | identical (md5) |
| 04 `build_rindex` | 20s | 846 MB | `.ri` | 153 M | 406 M (−62%, new encoding) |
| 05 `build_tags -k 31` | 62m 23s | 3,537 MB | `.tags` | 1.3 G | identical (md5) |
| 06 `convert_tags --num-seq 634` | 30s | 1,289 MB | `_compressed.tags` | 964 M | 1.40 G (−31%, new format) |
| 07 `path_extract` | 1s | 252 MB | `.paths` | 4.9 K | identical (md5) |
| 08 `print_stats` | 7s | 1,129 MB | — | — | — |
| 09 `find_mems` | 32s | 1,131 MB | `_path_pos.tsv` | 118 M / 4.95M rows | 34s / 1,886 MB / 4.91M rows |
| 10 `gafpack` | 149s | 90 MB | `.gaf` 280 M, `_coverage.csv` 15 M | | 179.6s / 278 M |
| 11 `validate_gaf_v2.py -n 2000` | 17s | 1,533 MB | **2000/2000 valid** | | 100% valid |

> One of three independent 2000-entry samples reported **1999/2000** (entry on `ALI#1#chrII#0`: read `TGCGAA…` vs path `TTTTGC…` — likely an off-by-one offset). The `.gaf` is md5-identical to `/tmp/y235-full/`, so the same entry exists there. ≈ 1 in 5 M; worth a follow-up but not blocking.

Full per-step `/usr/bin/time -l`: `logs/*.time`; summary: `logs/timing_summary.txt`. Steps 02–05/07 timings are from the initial May 3 run (outputs reused).

### `find_mems` detailed breakdown vs baseline

| Metric | This run | Baseline | Δ |
|---|--:|--:|--:|
| Total time | 32.20 s | 33.95 s | −5.2% |
| Peak memory | 1,131 MB | 1,886 MB | **−40.0%** |
| R-index load | 0.045 s / 154 MB | 0.66 s / 507 MB | −93% / −70% |
| Tag index load | 0.328 s / 974 MB | 1.14 s / 1,087 MB | −71% / −10% |
| Read processing | 29.26 s | 29.17 s | +0.3% |
| ├─ MEM finding | 11.80 s | 17.44 s | **−32.3%** |
| ├─ MEM processing | 16.62 s | 11.48 s | +44.8% |
| │  ├─ **Tag queries** | **6.54 s** | **1.15 s** | **+469%** ⚠️ |
| │  ├─ Locate ops | 6.86 s | 8.05 s | −14.8% |
| │  │  ├─ First locate | 2.28 s | 2.67 s | −14.6% |
| │  │  └─ Locate next | 4.57 s | 5.38 s | −15.1% |
| │  └─ File writes | 2.65 s | 1.64 s | +61.6% |
| Sorting | 2.57 s | 2.99 s | −14.0% |
| MEMs found | 114.2 K | 113.75 K | +0.4% |
| Avg MEM length | 174.6 bp | 175 bp | ≈ |
| n/r ratio | 2.07 | 1.95 | +6.2% |
| Tag runs queried | 6.5 M | 6.4 M | +1.6% |
| **Entries written** | **4.95 M** | **4.91 M** | **+0.8%** |
| Locate ops | 10.1 M | 10.0 M | +1.0% |
| `gafpack` wall | 148.7 s | 179.6 s | −17.2% |

> **Net:** new r-index encoding wins big on load time/memory and locate ops; MEM-finding is much faster; but `query_compressed_decoded_runs` is ~5.7× slower than the legacy compressed-tag query path. Overall wall time still slightly improves because MEM-finding savings outweigh tag-query cost. The +0.8% entry count is the dedup-by-`graph_pos` change in `dump_mem_info_unique_runs` (find_mems.cpp:769).

---

## Root cause of the initial failure: missing `convert_tags --num-seq`

### What happened

The first run called `convert_tags <in> <out>` (no flags), porting the legacy `compress_tags $RI $TAGS $BASE` line. The legacy tool inferred sequence count from the `.ri` argument; the refactored `convert_tags` does not — it needs `--num-seq N` explicitly.

`convert_tags.cpp:151–156` **unconditionally** strips pure-endmarker runs from the input `.tags`:
```
Skipping pure endmarker run: 0+80 0   ... (12 such lines)
// pure endmarker, skip (we prepend endmarkers via --num-seq)
```
and only re-prepends them at L132–138 when `--num-seq` is set. Without it, the 634 `$` positions vanish from `bwt_intervals`:

| `convert_tags` log | broken (no flag) | fixed (`--num-seq 634`) |
|---|--:|--:|
| `bwt_intervals` size | 337,355,969 | **337,356,603** (= n+1) |
| runs | 226,291,958 | 226,291,960 |
| on-disk bytes | 1,010,810,590 | 1,010,810,638 |

Every BWT position ≥ 634 then indexes into the wrong tag run; `find_mems` pairs the (correct) `seq_id` from the r-index with a `graph_pos` from a shifted run.

### Evidence

`_tmp.tsv` (retains seq_id column), marker nodes that live on exactly one path:

| Node | Paths containing it | broken seq_ids | fixed seq_ids | ref seq_ids |
|---|---|---|---|---|
| 84 | CEQ_1a only (idx 177) | 25 distinct ✗ | `{354, 355}` ✓ | `{354, 355}` |
| 574 | AAA only (idx 0) | 58 distinct ✗ | `{0, 1}` ✓ | `{0, 1}` |

`gafpack` then livelocked on the first entry: `process_path_matches` (`gafpack/src/main.rs:419`) `loop {}` only exits when every entry's `node_id` appears on the assigned path's step list — node 84 never appears on path AAA, so it spun for 42,200 s CPU before being killed.

### Exonerating the r-index

The new `.ri` encoding was initially suspect (size dropped 426 M → 160 M). Comparison with the independent successful run `/tmp/y235-full/`:

| File | this run | `/tmp/y235-full/` | |
|---|---|---|---|
| `.ri` | `1edcceb7…` | `1edcceb7…` | **md5-identical** |
| `.tags` | `dabfbe9c…` | `dabfbe9c…` | **md5-identical** |
| `_compressed.tags` (broken) | `6efb10c3…` | `0672d1e9…` | DIFFER |
| `_compressed.tags` (fixed) | `0672d1e9…` | `0672d1e9…` | **md5-identical** |
| `_path_pos.tsv` (fixed) | `22f1fe16…` | `22f1fe16…` | **md5-identical** |
| `.gaf` (fixed) | `f6a0051b…` | `f6a0051b…` | **md5-identical** |

The r-index encoding is fine; the fault was entirely in the convert_tags invocation.

### Recommendations (upstream)

1. **`convert_tags` should fail hard** when endmarker runs are stripped but `--num-seq` is unset (or derive it from the `.tags` header). Current behaviour silently produces a corrupt index.
2. **`gafpack` should bound the outer loop** at `main.rs:419` — if a full pass over `steps` advances `processed_matches` by 0, error out with the offending `(seq_id, node_id)` instead of spinning.

---

## File-level comparison vs `final_output2/` (after fix)

```
.seq              IDENTICAL  (337,356,602 B)
.rl_bwt           IDENTICAL  ( 70,166,771 B)
.tags             IDENTICAL  (1,352,068,728 B)
.paths            IDENTICAL  (      5,025 B)
.ri               DIFFER     new=160,282,045  ref=425,891,837   (new r-index encoding — expected)
_compressed.tags  DIFFER     new=1,010,810,638  ref=1,465,511,359   (convert_tags vs old compress_tags — expected)
_path_pos.tsv     DIFFER     new=4,954,591 rows  ref=4,906,653 rows  (+0.98% — dedup-by-graph_pos change)
_seq_id_starts    DIFFER     new=4,957 B  ref=4,957 B  (same size, content shifts with row counts)
.gaf              DIFFER     new=293,769,635 B  ref=291,308,195 B
_coverage.csv     DIFFER     new=16,109,009 B   ref≈15 M
```

Per the validation contract (`../CLAUDE.md`): only the four format-stable files are expected to md5-match a pre-refactor reference; correctness is established by `validate_gaf_v2.py` = 100%.

---

## Script fixes captured in `pangenome-pipeline/run.sh` (vs `final_output2/build_tag_index_normalized.sh`)

| Original | Problem | Fix |
|---|---|---|
| `build_tags $GBZ $RLBWT $TAGS $KMER_SIZE` | k-mer is positional; current binary uses `getopt -k` so the trailing arg is silently ignored | `build_tags -k $KMER ...` |
| `compress_tags $RI $TAGS $BASE` | binary removed in refactor; replacement needs explicit `--num-seq` | `convert_tags $TAGS $CTAGS --num-seq $NUM_SEQ` (NUM_SEQ parsed from `gbz_stats`) |
| (find_mems / gafpack / validate run by hand) | not scripted | steps 9–11 added with profiling + `[ -f ]` resume guards |

> `.tags` came out byte-identical despite the `-k` fix, so either the default k matches 31 or k doesn't affect the serialised content.

---

## Artifacts

| Path | What |
|---|---|
| `../../run.sh`, `../../compare.sh` | parameterised driver + reference diff |
| `../../configs/yeast235-chrII-normalized.env` | this run's config |
| `RUN_INFO.txt` | host, dates, toolchain commit |
| `logs/timing_summary.txt` | one-line-per-step wall + maxrss |
| `logs/NN_*.log` / `logs/NN_*.time` | per-step stdout / stderr+`time -l` |
| `logs/09_find_mems.log` | full hierarchical timing breakdown |
| `*_tmp.tsv` | pre-sort find_mems output (retains seq_id column — used for bug evidence) |
| `broken/` | May 3 outputs produced **without** `--num-seq` (kept for the diff above) |
| `run_pipeline.sh`, `compare_to_reference.sh` | the original per-run scripts actually executed (historical) |
