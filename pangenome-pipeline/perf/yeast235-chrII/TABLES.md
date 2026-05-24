# Headline tables — yeast-235 chrII

n=3 trials, warm cache, interleaved v1/v2. Steps 09 (`find_mems`) + 10 (`gafpack`). Host: M-Q7Q6XPVH36 (Apple Silicon, macOS 24.6.0). Full method: `FINDINGS_PERF.md`.

## Table 1 — Test dataset

| Dataset | Total input sequence (RLBWT input) | Pangenome graph | Query reads |
|---|---|---|---|
| **yeast-235 chrII** | **337.4 Mbp** (317 paths × 2 strands) | **1.28 M nodes / 1.58 M edges / 87.7 Mbp** | **100,000 × 200 bp (20.0 Mbp)** |

**Sources:**
- *Total input sequence* = size of the `.seq` file (the linearized two-strand concatenation that grlbwt consumes): `stat -f%z .../yeast235_chrII_100kb_normalized.seq` = 337,356,602 B ≈ **337.4 Mbp**.
- *Paths* from `gbz_stats`: "317 paths with names" × 2 orientations = 634 sequences.
- *Nodes / edges* from GFA S- and L-line counts: 1,282,246 S-lines / 1,575,322 L-lines.
- *Graph total bp* = sum of segment lengths over all S-lines: 87,727,654 bp ≈ **87.7 Mbp**.
- *Query reads*: 100,000 reads × 200 bp each = exactly 20,000,000 bp.

## Table 2 — Coverage pipeline performance (n=3 mean, v2)

| MEMs found | Total hits | Wall time (cov-only) | Throughput (reads/s) | Throughput (Kbp/s) | Peak memory |
|---|---|---|---|---|---|
| **114.3 K** | **4.95 M** | **25.76 ± 0.44 s** | **3,882** | **776** | **1232 MB** (find_mems) / **198 MB** (gafpack) |

**Sources & computations:**
- *MEMs found* = total MEM intervals across all reads. `find_mems` reports "Average MEMs per read: 1.14281" × 100,000 reads = **114,281** MEMs.
- *Total hits* = total (MEM × tag-run) records written to `_path_pos_v2.bin`. File size 79,273,456 B ÷ 16 B = **4,954,591** records.
- *Wall time (cov-only)* = sum of step 09 + step 10 wall per trial, then mean ± σ across n=3.
- *Throughput (reads/s)* = 100,000 / 25.76 = **3,882 reads/s**.
- *Throughput (Kbp/s)* = 20,000,000 bp / 25.76 / 1000 = **776 Kbp/s**.
- *Peak memory* = `gtime -v` "Maximum resident set size" mean across n=3. The two steps run sequentially so the pipeline-peak is the larger of the two; we report both for clarity. `find_mems` dominates at ~1.2 GB (held by the r-index + tag array).

## Table 2b — Same, v1 baseline (for comparison)

| MEMs found | Total hits | Wall time (cov-only) | Throughput (reads/s) | Throughput (Kbp/s) | Peak memory |
|---|---|---|---|---|---|
| 114.3 K | 4.95 M | 25.53 ± 0.25 s | 3,916 | 783 | 1296 MB (find_mems) / 244 MB (gafpack) |

## Table 2c — v2 deltas vs v1

| metric | v1 | v2 | Δ |
|---|---|---|---|
| Wall time (cov-only) | 25.53 ± 0.25 s | 25.76 ± 0.44 s | +0.9% (within noise) |
| Throughput (reads/s) | 3,916 | 3,882 | −0.9% |
| `find_mems` peak RSS | 1296 ± 54 MB | 1232 ± 60 MB | **−4.9%** |
| `gafpack` peak RSS | 244 ± 5 MB | 198 ± 5 MB | **−18.8%** |
| `gafpack` wall | 2.06 ± 0.01 s | 1.85 ± 0.01 s | **−10.2%** |
| `_path_pos.bin` on disk | 118.9 MB | 79.3 MB | **−33.3%** |

End-to-end wall is statistically unchanged (the pipeline is dominated by tag/locate I/O in find_mems, which v2 doesn't touch). The wins concentrate in:
- the **on-disk artifact (−33%)** — fewer bytes written by `find_mems`, fewer bytes read by `gafpack`,
- **`gafpack` runtime (−10% wall, −19% RSS)** from the linear-merge walker + smaller mmap.
