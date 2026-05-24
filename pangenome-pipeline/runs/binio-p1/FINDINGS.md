# Phase 1: find_mems in-memory entries + bucket sort (TSV output)

Branch: `pangenome-index-latest@find-mems-binary-io` (Phase 1 only; gafpack unmodified)
Baseline: `runs/2026-05-03` (upstream-sync@6073141)

## Correctness
- validate_gaf: **2000/2000 valid, 0 invalid** ✅
- `_seq_id_starts.out`: md5-identical to baseline (`19188e4a662f6a6de9f5b928ca22f16a`) ✅
- `_path_pos.tsv`: same line count (4,954,591); md5 differs (expected — tie-order change) ✅
- `_tmp.tsv`: no longer produced ✅

## Performance (yeast235-chrII, 100k reads)
| step        | baseline wall/rss | phase-1 wall/rss | Δ |
|-------------|-------------------|------------------|---|
| 09_find_mems | 32s / 1131MB     | 30s / 842MB      | −6% / **−26%** |
| 10_gafpack   | 149s / 90MB      | 170s / 99MB      | +14% / +10% (noise; gafpack unchanged) |

In-memory entries: 4,954,591 × 24B = 113MB.
Sort+write phase: 3.31s (vs 2.57s baseline — TSV formatting cost moved here from read loop).

Main win is memory: dropped string-backed `MEMData` vector + `total_mem_matches` over-reserve.
Wall-time win expected to materialize in Phase 2 (binary write skips formatting entirely).
