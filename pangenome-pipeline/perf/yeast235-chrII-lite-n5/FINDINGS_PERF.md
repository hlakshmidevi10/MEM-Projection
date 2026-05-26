# Lightweight tag pipeline — performance comparison (N=5)

**Run date:** 2026-05-26
**Host:** M-Q7Q6XPVH36 (Darwin 24.6.0 arm64)
**Method:** `perf/perf_harness.sh` (baseline) vs `perf/perf_lite_harness.sh` (lite). Same INDEX_DIR (`runs/v1-current`), same reads, same host. Each phase wrapped in `gtime -v`. N=5 warm-cache trials per pipeline, one untimed warmup per format.

**Branches under test**

| Repo | Branch | Commit | Adds |
|---|---|---|---|
| `pangenome-index-latest` | `lightweight-tags` | `b59aacf` | `LightTagIndex`, `build_lightweight_tags`, `find_mems --lightweight-tags` |
| `gafpack`                | `dedup-read-node`  | `3ce9bba` | `--dedup-read-node` flag (HashSet on `(read_id, read_st, starting_node_id)`) |

---

## 1. Dataset configuration

| | |
|---|---|
| **Dataset** | 235 *S. cerevisiae* genomes, chromosome II |
| **Total input sequence** | 168.7 Mbp across 317 haplotype paths (avg 532 kbp/path) |
| **Indexed text (fwd + rev)** | 337.4 Mbp |
| **Pangenome graph** | 1,282,246 nodes · 1,575,322 edges |
| **Graph sequence (non-redundant, sum of nodes)** | 87.7 Mbp (1.92× compression vs input) |
| **GFA file size** | 226 MB |
| **Query reads** | 100,000 × 200 bp = 20.0 Mbp (simulated from S288C chrII) |
| **MEM parameters** | min length 30 bp, min occurrences 1 |
| **MEMs found (deterministic, identical for both pipelines)** | 114,281 (avg 174.6 bp, avg 87.9 occurrences) → 6,546,374 raw tag-run hits |
| **GAF rows after dedup** | 4,954,592 (baseline, pos_t-dedup) / 4,953,490 (lite, gafpack dedup) |

Sources: `DATASET.md` (auto-generated from `gbz_stats` + GFA scan), `find_mems.log` (`#if TIME` block, per-trial), trial-1 `sizes.txt`.

---

## 2. End-to-end runtime & memory (N=5)

Each trial's E2E wall = sum of *that trial's* find_mems + *that trial's* gafpack phase (paired, not mean+mean — intra-trial OS-state noise is correlated). Peak total RSS = max RSS observed across the two sequential phases (find_mems exits before gafpack starts).

### find_mems + gafpack **coverage-only** (the cosigt path — no `.gaf` output)

| Metric | Lightweight | Baseline | Δ |
|---|---|---|---|
| Wall (s, mean ± σ)        | **23.34 ± 1.01** | 24.58 ± 0.94 | **−1.24 s (−5.1%)** |
| Throughput (reads/s)      | **4,285**        | 4,069        | **+216 (1.05× faster)** |
| Peak total RSS (MB)       | **582**          | 1,290        | **−708 MB (−54.9%) — 2.22× lower** |

### find_mems + gafpack **coverage + GAF**

| Metric | Lightweight | Baseline | Δ |
|---|---|---|---|
| Wall (s, mean ± σ)        | **24.08 ± 1.01** | 25.31 ± 0.98 | **−1.23 s (−4.9%)** |
| Throughput (reads/s)      | **4,153**        | 3,951        | **+202 (1.05× faster)** |
| Peak total RSS (MB)       | **582**          | 1,290        | **−708 MB (−54.9%) — 2.22× lower** |

Sources: `SUMMARY.tsv` (per-trial `wall_s` and `maxrss_mb` columns). Peak RSS is the find_mems-phase value in both pipelines (find_mems dominates; gafpack RSS is smaller in both — see §4).

---

## 3. Per-phase runtime (find_mems vs gafpack, N=5)

| Phase | Lightweight (s, mean ± σ) | Baseline (s, mean ± σ) | Δ |
|---|---|---|---|
| find_mems         | **21.59 ± 0.96** | 23.45 ± 0.96 | **−1.85 s (−7.9%)** |
| gafpack cov-only  | 1.74 ± 0.09      | 1.14 ± 0.03  | +0.61 s (+53.5%) |
| gafpack cov+gaf   | 2.48 ± 0.06      | 1.86 ± 0.06  | +0.62 s (+33.3%) |

The find_mems −1.85 s comes from skipping `encoded_runs_iv` decoding and the per-MEM `unordered_set<pos_t>` dedupe. The gafpack +0.61 s splits as ~0.50 s for processing 32% more input records plus ~0.10 s for the dedup HashSet (per the lite-raw gafpack reference run at 1.64 ± 0.07 s).

Sources: `SUMMARY.tsv` `phase` column, `wall_s` aggregated over 5 trials per (format, phase).

---

## 4. Per-phase peak RSS (N=5)

| Phase | Lightweight (MB) | Baseline (MB) | Δ |
|---|---|---|---|
| find_mems         | **582 ± 32**  | 1,290 ± 56 | **−708 MB (−54.9%)** |
| gafpack cov-only  | 429 ± 9       | 191 ± 11   | +238 MB (+124.7%) |
| gafpack cov+gaf   | 425 ± 10      | 203 ± 10   | +222 MB (+109.2%) |

find_mems RSS drops because `encoded_runs_iv` (the bulk of `_compressed.tags`) is no longer loaded. Gafpack RSS doubles to hold the dedup HashSet (~5M `(u32, u32, usize)` entries × ~40 B Rust overhead = ~200 MB).

Since the two phases run sequentially, the **peak total RSS the system ever sees is bounded by the larger of the two = find_mems in both pipelines** (582 MB lite, 1290 MB baseline).

Sources: `SUMMARY.tsv` `maxrss_mb` column.

---

## 5. Index file sizes on disk

These are the files find_mems and gafpack mmap or load at startup.

| File | Lightweight | Baseline | Role |
|---|---|---|---|
| `.ri` (r-index)             | 152.9 MB    | 152.9 MB  | BWT + sampled SA. Used by both pipelines; identical file on disk. |
| `_compressed.tags`          | — (unused)  | **964.0 MB** | Full positional tag array `(node, offset, strand)` per run. |
| `.ltags`                    | **85.1 MB** | — (unused)  | Run-start bitvector only (sd_vector). |
| `.paths`                    | 5 KB        | 5 KB      | Path-name list (used by gafpack). |
| **Subtotal (r-index + tag-index)** | **238.0 MB** | 1116.9 MB | **4.69× smaller for lite** |

**Tag-index file alone:** `.ltags` is **11.32× smaller** than `_compressed.tags` (964.0 MB → 85.1 MB, 91.2% reduction).

After the lite tag-index optimization, the r-index dominates the on-disk footprint at 64% of the lite total. Further reductions on the lite side would need to target the r-index itself (out of scope for this work).

Sources: `PROVENANCE.txt` block "Index files in INDEX_DIR".

---

## 6. find_mems internal breakdown (trial 1)

Source: `lite/trial-1/find_mems.log` and `../yeast235-chrII-n5/v2/trial-1/find_mems.log` (printed by find_mems's `#if TIME` block; single trial, not aggregated).

### Top-level timing

| Stage | Lightweight | Baseline | Δ |
|---|---|---|---|
| **Total** | **21.81 s** | 23.96 s | −2.14 s (−9%) |
| R-index load (153 MB `.ri`, ~154 MB resident) | 0.066 s | 0.066 s | identical (same file, same code) |
| Tag-index load                                | **0.083 s** (85 MB `.ltags`) | 0.674 s (964 MB `_compressed.tags`) | **−0.59 s (8× faster)** |
| Read processing                               | 21.04 s | 22.76 s | −1.72 s |
| Sorting (post-loop)                           | 0.618 s | 0.471 s | (noise) |

### Read-processing split (the 21.04 s)

| Phase | Lightweight | Baseline | Δ | % of read-proc (lite) |
|---|---|---|---|---|
| **MEM finding** (BWT backward search) | 13.51 s | 13.70 s | (noise) | 64.2% |
| **MEM processing** (tag query + locate + emit) | **7.40 s** | 8.88 s | −1.48 s (−17%) | 35.2% |
| Other overhead | 0.130 s | 0.176 s | — | 0.6% |

### MEM-processing split (the 7.40 s)

| Operation | Lightweight | Baseline | Δ | % of MEM-proc (lite) |
|---|---|---|---|---|
| **Tag queries** (decode + dedup) | **0.102 s** | 0.866 s | **−0.76 s (−88%)** | **1.4%** |
| **Locate operations** (r-index SA recovery) | 6.90 s | 7.45 s | −0.55 s (−7%) | **93.3%** |
| ├─ First locate (1 per MEM)                 | 2.30 s | 2.42 s | −0.11 s | 33% of locate |
| └─ Locate next (chain, 9.7M / 10.0M calls)  | 4.60 s | 5.04 s | −0.43 s | 67% of locate |

### Peak memory (trial 1)

| Component | Lightweight | Baseline |
|---|---|---|
| R-index resident          | 154 MB | 154 MB (identical file) |
| Tag index resident        | **94 MB** | 468 MB (this trial; mean across 5 trials = 1290 MB) |
| **Peak total RSS**        | **488 MB** | 1100 MB |

### Per-MEM workload (sanity check — identical across pipelines)

| Quantity | Lightweight | Baseline |
|---|---|---|
| Reads | 100,000 | 100,000 |
| Total MEMs | 114,281 | 114,281 |
| Avg MEM length | 174.6 bp | 174.6 bp |
| Avg `mem.size` (BWT interval width) | 87.9 | 87.9 |
| Total tag runs visited | 6,546,374 | 6,546,374 |
| Avg tag runs / MEM | 57.3 | 57.3 |
| n/r ratio (mem.size / tag runs) | 2.07 | 2.07 |
| **Entries emitted** | **6,546,374** (no dedup) | **4,954,591** (pos_t-dedup) |
| Avg entries / MEM | 57.3 | 43.4 |

### Visual breakdown (lite)

```
Total: 21.81 s
├─ R-index load        0.07 s  ( 0.3%)
├─ Tag index load      0.08 s  ( 0.4%)   [vs 0.67 s baseline — 8× faster load]
├─ Read processing    21.04 s  (96.5%)
│   ├─ MEM finding    13.51 s  (61.9% of total)
│   └─ MEM processing  7.40 s  (33.9% of total)
│       ├─ Tag query     0.10 s  ( 0.5%)  ← was 0.87 s in baseline (8× faster)
│       └─ Locate ops    6.90 s  (31.6%)
│           ├─ First locate  2.30 s
│           └─ Locate next   4.60 s
└─ Sorting             0.62 s  ( 2.8%)
```

### Takeaways

- **Tag-query work is essentially free** in lite (1.4% of MEM-processing, down from ~10%). This is the headline find_mems win from the lightweight index.
- **Locate operations dominate** lite's MEM-processing (93.3%, all r-index work). Any further find_mems speedup must come from the r-index `locate_sa_value` + `locateNext` chain (out of scope).
- **MEM finding is essentially identical** (13.5 vs 13.7 s, noise). An earlier N=3 measurement showed a ~3 s lite-favorable difference here that we attributed to page-cache effects; that effect does *not* reproduce at N=5, suggesting it was sampling noise.
- **Tag-index load is 8× faster** (0.08 s vs 0.67 s), reflecting the 11× smaller file plus simpler sdsl deserialization.

---

## Appendix A — Correctness

| Check | Result |
|---|---|
| `validate_gaf_v2.py --sample 2000` on lite+dedup GAF       | **2000 / 2000 valid (100%)** |
| `validate_gaf_v2.py --sample 10000` × 5 independent runs   | **50,000 / 50,000 valid (100%)** |
| Coverage cosine vs baseline                                | **0.999952** |
| Per-node coverage exact-match rate                         | 96.1% nodes identical, 96.3% within 1%, 97.6% within 5% |
| Total coverage sum vs baseline                             | −0.0182% |
| Coverage CSV md5 across all 5 lite trials                  | `0bf18bff6bcfe1e0f0452d7cf2dbefe5` (deterministic) |

Validation command (against the GAF left behind by the last harness trial):

```sh
python3 scripts/validate_gaf_v2.py \
    runs/v1-current/S288C_chrII_N100K_R1_200_normalized.gaf \
    yeast-235/yeast-235-chrI/S288C_chrII_N100K_R1_200_reads.txt \
    yeast-235/yeast-235-chrI/final_output2/yeast235_chrII_100kb_laced_sorted_normalized_new.gfa \
    --sample 2000
# -> Valid entries:   2000 (100.00%)
```

The 4% non-identical-coverage nodes are the cross-haplotype collapse cases where the baseline picks a specific (node, offset, strand) representative per MEM and the lite pipeline picks node_id alone. Largest single-node delta is ~10% of that node's value; aggregate cosine impact is 0.00005.

---

## Appendix B — Per-trial raw values (N=5)

End-to-end (paired sums per trial):

| trial | baseline FM+cov-only | baseline FM+cov+gaf | lite FM+cov-only | lite FM+cov+gaf |
|---|---|---|---|---|
| 1 | 25.14 | 25.84 | 23.60 | 24.37 |
| 2 | 24.53 | 25.27 | 23.75 | 24.60 |
| 3 | 23.49 | 24.11 | 24.20 | 24.88 |
| 4 | 25.84 | 26.63 | 23.54 | 24.21 |
| 5 | 23.91 | 24.70 | 21.60 | 22.33 |

Per-phase wall:

| trial | baseline FM | baseline cov-only | baseline cov+gaf | lite FM | lite cov-only | lite cov+gaf |
|---|---|---|---|---|---|---|
| 1 | 24.00 | 1.14 | 1.84 | 21.83 | 1.77 | 2.54 |
| 2 | 23.44 | 1.09 | 1.83 | 22.11 | 1.64 | 2.49 |
| 3 | 22.31 | 1.18 | 1.80 | 22.33 | 1.87 | 2.55 |
| 4 | 24.71 | 1.13 | 1.92 | 21.78 | 1.76 | 2.43 |
| 5 | 22.77 | 1.14 | 1.93 | 19.92 | 1.68 | 2.41 |

Lite beats baseline in 4/5 trials for both E2E modes. Trial 3 is the only inversion (within 1σ). Run-to-run noise (~4% relative) is page-cache fluctuation on a shared machine.

Cross-trial stability of find_mems wall:
- baseline: 24.00 / 23.44 / 22.31 / 24.71 / 22.77 s (mean 23.45 ± 0.96 s)
- lite:     21.83 / 22.11 / 22.33 / 21.78 / 19.92 s (mean 21.59 ± 0.96 s)

Both pipelines show similar absolute variance (~1 s σ).

---

## Appendix C — Caveats

1. **Single dataset (yeast235 chrII).** 235 haplotypes → high node redundancy → maximum potential dedup work. HPRC scale (94k haplotypes, larger graph) will shift both ends: more savings in find_mems tag-decode work, more memory pressure in gafpack's HashSet (likely several GB at HPRC scale; consider sharded/streaming dedup if it becomes binding).
2. **Same host, same INDEX_DIR, same warm-cache protocol** as the baseline. Differences are attributable to code changes, not environment.
3. **`build_lightweight_tags` one-time cost** (not counted above): 0.35 s build + ~8 s validate I/O on this dataset. One-time per `_compressed.tags`, amortized across all query runs.
4. **No `--weight-queries` involved** — gafpack's `_path_pos_v2.bin` code path doesn't honor that flag (confirmed via source). The pipeline's gafpack invocation in `run.sh` step 10 doesn't pass it either.
5. **Cosigt not run.** `validate_gaf_v2.py` confirms each emitted GAF row is locally correct; the cosine 0.999952 strongly suggests cosigt genotype calls will match, but end-to-end cosigt confirmation is left as a follow-up.
6. **N=5 vs the older N=3 numbers.** The earlier N=3 report at `perf/yeast235-chrII-lite/FINDINGS_PERF.md` reported `find_mems −22%` and `end-to-end −19%`. Those were optimistic — N=3's σ is a poor variance estimator with only 2 degrees of freedom, and the lite N=3 run happened to land in a favorable warm-cache window. The N=5 numbers (`find_mems −8%`, `end-to-end −5%`) are more trustworthy.

---

## Appendix D — Sources

All numbers traceable to artifacts on disk. Paths relative to `mem-projection/pangenome-pipeline/`.

| Section | Source |
|---|---|
| §1 Dataset configuration | `perf/yeast235-chrII-n5/DATASET.md` (auto-generated from `gbz_stats` + GFA scan + reads inspection), trial-1 `find_mems.log` for MEM counts. |
| §2 E2E wall + RSS + throughput | `perf/yeast235-chrII-lite-n5/SUMMARY.tsv` (lite), `perf/yeast235-chrII-n5/SUMMARY.tsv` (baseline); per-trial `wall_s` + `maxrss_mb` paired by trial id, then mean/σ over 5 trials. |
| §3 Per-phase wall | Same `SUMMARY.tsv` files; `phase` column groups, `wall_s` aggregated per (format, phase). |
| §4 Per-phase peak RSS | Same `SUMMARY.tsv` files; `maxrss_mb` aggregated per (format, phase). |
| §5 Index file sizes | `PROVENANCE.txt` block "Index files in INDEX_DIR" in each perf dir. |
| §6 find_mems internal breakdown | `perf/yeast235-chrII-lite-n5/lite/trial-1/find_mems.log` (lite), `perf/yeast235-chrII-n5/v2/trial-1/find_mems.log` (baseline). Single-trial, from `#if TIME` block. |
| App A correctness | `runs/v1-current/S288C_chrII_N100K_R1_200_normalized.gaf` (md5 `4ff47cd905209fca4f559611567f0aa8`); 5×10k re-check logs in `/tmp/validate_lite_5x/run_{1..5}.log` (not committed; reproducible from command in Appendix A). |
| App A coverage cosine | Comparison of `runs/v2-yeast235/_coverage.csv` (baseline) vs `runs/v2-yeast235-lite-dedup/_coverage.csv` (lite + gafpack dedup). |
| App B per-trial values | `SUMMARY.tsv` `trial` + `wall_s` columns. |
| Branch commit SHAs | `git -C <repo> rev-parse <branch>` at the time of writing. |
| Binary md5s | `PROVENANCE.txt` block "Binaries:" in each perf dir. |

### Reproducing the run

```sh
cd mem-projection/pangenome-pipeline

# Baseline N=5:
./perf/perf_harness.sh yeast235-chrII-normalized.env 5 yeast235-chrII-n5

# Lite N=5:
#   1. Build the .ltags from the existing _compressed.tags (one-time).
$PI_BIN/build_lightweight_tags \
    runs/v1-current/yeast235_chrII_100kb_normalized_compressed.tags \
    runs/v1-current/yeast235_chrII_100kb_normalized.ltags \
    --validate
#   2. Run the lite harness:
./perf/perf_lite_harness.sh yeast235-chrII-normalized.env 5 yeast235-chrII-lite-n5
```

Both harnesses write `SUMMARY.tsv`, `PROVENANCE.txt`, and per-trial directories; this document was generated by reading those files.
