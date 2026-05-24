# v1 vs v2 performance — yeast-235 chrII

**Methodology:** 3 timed trials per format, interleaved (v1,v2,v1,v2,v1,v2), preceded by 1 untimed warmup per format to stabilize OS disk cache. Steps 09 (`find_mems`) and 10 (`gafpack`) only — all other steps are identical between v1 and v2 and were not re-run. Hardlinked input indexes shared between formats so disk-cache state is identical at trial start. `gtime -v` for rusage; `find_mems`' built-in `TIME=1` for internal phase breakdown.

**Run record:**

| Field | Value |
|---|---|
| Host | M-Q7Q6XPVH36 (Apple Silicon, macOS 24.6.0) |
| Date | 2026-05-23, 21:36–21:40 PDT |
| Config | `yeast235-chrII-normalized.env` (100k reads, 100Kb pangenome, MEM_LEN=30, MIN_OCC=1) |
| Index dir | `runs/v1-current/` (shared between v1 and v2 via hardlinks) |
| Trials | 3 timed + 1 warmup per format |
| PI v1 binary | `bin-v1/find_mems` md5 `42ae90e1...` |
| PI v2 binary | `bin/find_mems` md5 `b86ee2d1...` |
| gafpack v1 | `target/v1/gafpack` md5 `714d99f3...` |
| gafpack v2 | `target/release/gafpack` md5 `83b1c5b4...` |
| Warnings | **0** in stderr across all 12 trials (was 2,291 in pre-fix v2; confirms `is_rev` bug is gone) |

---

## TL;DR

- **`_path_pos.bin` shrinks 33.3%** (118.9 MB → 79.3 MB), exactly the 24→16 byte ratio. Headline win.
- **`gafpack` is 10.2% faster** (2.06 → 1.85 s, σ < 1%) and uses **18.8% less RSS** (244 → 198 MB).
- **`find_mems` is essentially unchanged** (within 1σ noise, +1.9% wall ≈ +0.4s). Sort key change is a wash; tag/locate workload is unchanged by design.
- **Combined 09+10 wall:** 25.53 ± 0.25 s (v1) vs 25.76 ± 0.44 s (v2) — **within noise**. The gafpack speedup is offset by find_mems run-to-run variance.
- **GAF and coverage byte-identical** between every v1 and v2 trial (md5 `c7ad02f5...`).

The optimization's value isn't wall time (which was already dominated by tag/locate I/O) — it's the **33% smaller on-disk artifact**, smaller gafpack RSS, and the simpler, more analyzable walker code.

---

## Step 09 — `find_mems`

### Wall time and rusage

| metric | v1 (mean ± σ) | v2 (mean ± σ) | Δ |
|---|---|---|---|
| **wall** | 23.48 ± 0.25 s | 23.91 ± 0.44 s | **+1.9%** |
| user | 21.92 ± 0.13 s | 22.04 ± 0.20 s | +0.5% |
| sys | 1.22 ± 0.02 s | 1.24 ± 0.03 s | +1.1% |
| peak RSS (rusage) | 1.40 GB ± 73 MB | 1.36 GB ± 62 MB | −3.3% |
| peak RSS (reported by find_mems) | 1296 ± 54 MB | 1232 ± 60 MB | −4.9% |
| minor page faults | 160,555 ± 4,982 | 154,219 ± 4,249 | −3.9% |
| major page faults | 48 ± 0 | 49 ± 3 | +2.1% |

### Phase breakdown (from `find_mems`' internal timing)

| phase | v1 | v2 | Δ | Comment |
|---|---|---|---|---|
| **Total** | 23.44 ± 0.25 s | 23.86 ± 0.42 s | +1.8% | |
| R-index load | 0.062 ± 0.001 s | 0.075 ± 0.020 s | +20.6% | Sub-100ms; noise. |
| Tag-index load | 0.680 ± 0.163 s | 1.012 ± 0.466 s | +48.8% | High σ both sides; not significant given variance. |
| **Read processing** | **22.17 ± 0.14 s** | **22.29 ± 0.34 s** | +0.5% | The dominant phase; near-identical. |
| ↳ MEM finding | 13.57 ± 0.09 s | 13.62 ± 0.13 s | +0.4% | Pure r-index work; v2 doesn't touch this. ✓ |
| ↳ MEM processing | 8.45 ± 0.06 s | 8.51 ± 0.21 s | +0.7% | Pure tag/locate work; v2 doesn't touch this. ✓ |
| ↳↳ Tag queries | 0.654 ± 0.005 s | 0.696 ± 0.093 s | +6.3% | Within noise (v2 σ much larger). |
| ↳↳ Locate ops | 7.24 ± 0.06 s | 7.28 ± 0.10 s | +0.5% | Identical workload. ✓ |
| ↳↳↳ First locate | 2.35 ± 0.02 s | 2.36 ± 0.04 s | +0.7% | |
| ↳↳↳ Locate next | 4.89 ± 0.04 s | 4.91 ± 0.06 s | +0.4% | |
| **Bucket sort + write** | 0.521 ± 0.028 s | 0.479 ± 0.016 s | **−8.0%** | v2 wins: smaller records and a simpler write loop, ~40ms saved. |

**Read of phase data:** v2 changes touched ONLY (a) the in-memory `PackedEntry` (5×u32 instead of 7×u32, ~30% smaller), (b) per-bucket sort key (`node_id` → `path_bp`, same comparator complexity), and (c) the write loop (16 B / record instead of 24 B). All other phases — MEM finding, tag query, locate — are bit-for-bit unchanged. The phase breakdown confirms exactly this: the only statistically significant delta is in the sort+write phase (−8%), with everything else within noise.

The headline `+1.9%` on wall is **noise inflation from the tag-load phase** (where the v2 trials happened to see σ=0.466s vs v1's 0.163s — likely OS page-cache scheduling at the start of a trial). Trial-by-trial: v1 read-processing was {22.25, 22.06, 22.21} s, v2 was {22.51, 22.69, 21.69} s — overlapping distributions.

### Memory note

v1 in-memory record is 28 B (PackedEntry: 7 u32). v2 is 20 B (PackedEntry: 5 u32). For 4.95M records that's ~40 MB saved in peak working set, but most of the RSS is the r-index + tag array (each ~700 MB) plus the entry vector's tail allocations. The observed −5% reported peak (−63 MB) is consistent.

---

## Step 10 — `gafpack`

### Wall time and rusage

| metric | v1 (mean ± σ) | v2 (mean ± σ) | Δ |
|---|---|---|---|
| **wall** | 2.06 ± 0.01 s | 1.85 ± 0.01 s | **−10.2%** |
| user | 1.85 ± 0.01 s | 1.65 ± 0.01 s | −10.5% |
| sys | 0.19 ± 0.01 s | 0.17 ± 0.01 s | −7.1% |
| **peak RSS** | 244 ± 5 MB | 198 ± 5 MB | **−18.8%** |
| minor page faults | 15,760 ± 294 | 12,834 ± 300 | **−18.6%** |
| major page faults | 37 ± 0 | 37 ± 1 | +0.9% |

**These are all real wins** — σ is 1% or smaller for every key metric, the deltas are >7× σ. They're driven by:

1. Smaller `.bin` file → less to read, less to mmap, less to touch (−18.6% minor faults tracks this exactly).
2. Linear-merge walker replaces `cum_bp.partition_point()` per record (O(log S) → amortized O(1)).
3. No `mismatch_node`/`mismatch_off` per-record branching.
4. Simpler `Record` struct → smaller stride, better cache behavior.

### Path-scan stats (gafpack stderr)

| metric | v1 | v2 | Δ |
|---|---|---|---|
| records loaded | 4,954,591 | 4,954,591 | **0** |
| bytes loaded | 118,910,184 B | 79,273,456 B | **−33.3%** |
| total GAF entries | 4,954,591 | 4,954,591 | **0** |
| seq_ids visited (non-empty) | 632 | 632 | 0 |
| mean passes/path | 1.00 | 1.00 | 0 |
| step-visits (sum of steps × passes) | 21,591,821 | 21,591,821 | 0 |

**Identical workload at the path-scan level** (same number of records, same number of seq_id buckets, same number of step traversals across all paths). The v1 vs v2 delta is purely in *how* gafpack walks them, not what.

---

## Output artifacts

| artifact | v1 bytes | v2 bytes | Δ | Note |
|---|---|---|---|---|
| `_path_pos*.bin` | 118,910,184 | 79,273,456 | **−33.3%** | Exactly the 24→16 record-size ratio. 4,954,591 records both sides. |
| `_seq_id_starts.out` | 4,957 | 4,957 | 0 | Byte-identical (same bucket boundaries). |
| `.gaf` | 293,739,869 | 293,739,869 | 0 | Same content, identical sorted set-equality (per Gate 3 in correctness suite). |
| `_coverage.csv` | 16,109,019 | 16,109,019 | 0 | md5 `c7ad02f5b5d1388d189a4e1cef70fcce` on both sides for all 6 trials. |

Total bytes written to disk per run: **−39.6 MB** (10.7% of total output size). Total bytes read by `gafpack` at startup: **−39.6 MB** (the same `.bin`).

---

## Combined wall (steps 09+10)

| | mean ± σ |
|---|---|
| v1 | **25.53 ± 0.25 s** |
| v2 | **25.76 ± 0.44 s** |
| Δ | +0.9% (within noise: v2 σ alone is ±1.7%) |

End-to-end wall is statistically indistinguishable, dominated by the unchanged tag/locate work in find_mems. The 10% gafpack speedup is real but only contributes ~0.2s to the combined run.

---

## What this means in practice

- **Disk usage:** every pipeline run writes ~40 MB less. Over many runs (the project has 12+ historical runs in `runs/`), this is multiple hundreds of MB saved.
- **Memory pressure:** `gafpack` peak RSS drops from 244 MB to 198 MB — meaningful on a multi-GB workstation if running many in parallel.
- **I/O pressure:** −18.6% in minor page faults at gafpack startup ≈ a clear and consistent reduction in what the kernel has to fault in.
- **Walker simplicity:** the rewrite traded `partition_point` + redundant `mismatch_node/off` checks for a single monotonic cursor with a `debug_assert!` invariant. Easier to reason about and the v1 infinite-loop footgun on bad input (per `CLAUDE.md`) is **structurally impossible** in v2.
- **Wall time at this scale:** essentially neutral. **The tag/locate work in `find_mems` is the bottleneck**, not record I/O. Future optimization should target there (the "Option B" hot-loop hygiene work flagged out-of-scope in the v1 plan), not the disk format.

---

## Reproducibility

```bash
cd mem-projection/pangenome-pipeline

# Prerequisite: a v1-current run dir with prebuilt indexes (.ri, .tags, etc.)
# These are shared by both formats via the harness's INDEX_DIR.
ls runs/v1-current/   # should show .seq, .rl_bwt, .ri, _compressed.tags, .paths

# Run the harness
./perf_v1_v2.sh yeast235-chrII-normalized.env 3 yeast235-chrII

# Re-summarize at any time
python3 perf/summarize.py perf/yeast235-chrII
```

Raw per-trial logs are preserved under `perf/yeast235-chrII/{v1,v2}/trial-{1,2,3}/`. Each trial dir has `find_mems.log`, `find_mems.stderr`, `find_mems.time`, `gafpack.stdout`, `gafpack.stderr`, `gafpack.time`, `sizes.txt`. The machine-parseable summary lives in `perf/yeast235-chrII/SUMMARY.tsv`.
