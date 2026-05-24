# path_bp: find_mems emits seqOffset → gafpack binary-searches cum_bp

Branches: `find-mems-pathbp` @ `upstream-sync@06ef581`; `gafpack-pathbp@79a0d6c` @ `gafpack-hashmap-walk@54925ba`.
Change: find_mems writes `r_index.seqOffset(sa_value)` into `BinRecord` slot 6 (was `_pad=0`). gafpack builds `cum_bp[]` (prefix sum of node lengths along `steps`) once per path, then per record `i = cum_bp.partition_point(|&c| c <= path_bp) - 1`. No node_id map, no cursor state; record order irrelevant.

## Correctness — fixes the 902
- **Full `validate_gaf_v2.py` (all 4,954,591): 0 invalid** (was 902 on every prior run back to `main` baseline). ✅
- n=50000 ×4: {0, 0, 0, 0}. ✅
- Internal cross-check: `step_node_ids[i] == r.node_id` and `path_bp − cum_bp[i] == r.offset` on **all 4.95M records, both strands** — 0 mismatches. find_mems's `seqOffset` and gafpack's GFA-derived cum_bp agree exactly. ✅
- Same-`.bin` head-to-head: E-gafpack (ignores slot 6) → `.gaf` md5 `b2807d…1a34` (canonical) → confirms fields 0–4 of new `.bin` byte-identical to old. pathbp-gafpack → md5 `452755e…29c8` ×3 (stable). **907 rows differ**; since pathbp has 0 invalid and the 4,953,684 unchanged rows are shared, E's 902 invalids ⊂ the 907 changed. The other 5 changed but were already valid (both occurrences happened to spell the same sequence for `match_len` bp).
- Diff inspection: all changed rows are repeated-node walks (e.g. E `>118758>434891>118758>118758>422801…` vs pathbp `>118758>422801…` — different occurrence of 118758 as start). ✅
- 0 `ERROR`/`WARN` in stderr (no `path_bp ≥ path_total_bp`, no skipped records). ✅

## Performance (yeast235-chrII, 100k reads, 4.95M records)
| step 10 | E (hashmap) | **pathbp** | Δ |
|---|---|---|---|
| wall | 3.5–3.9s | **2.41–2.61s**¹ | −31% |
| instructions | 32.1B | **21.4B** | −33% |
| maxrss | 221 MB | 221–239 MB | ≈flat |

¹ one 8.08s outlier with user=1.94s — I/O contention with concurrent full-validate reading the same `.gaf`.

`cum_bp`/`step_node_ids` are per-path `Vec<usize>`, max ~800KB transient (longest path ~50k steps).

| step 09 (find_mems) | 06ef581 | **pathbp** | Δ |
|---|---|---|---|
| wall / inst | 26.6s / 140.3B | 26.3s / 140.4B | ≈0 |
| entries buffer | 113.4 MB | 132.3 MB | +18.9 MB (4.95M × 4B) |
| peak footprint | 1371 MB | 1413 MB | +42 MB |
| maxrss | 786 MB | 1035 MB | +249 MB ⚠ unexplained² |

² Tag-index self-report also moved 602→279 MB between the May-8 and today's run of the same base commit; not attributable to the 4-line PackedEntry change. Needs clean A/B rebuild of unmodified `06ef581` to isolate.

Cumulative step-10: 149s → 117s → 39s → 3.5s → **2.5s** (−98.3% vs baseline), and now **0 invalid**.

## Files changed
- `pangenome-index-latest/src/find_mems.cpp`: `PackedEntry` +`uint32_t path_bp`; `BinRecord._pad`→`path_bp`; populate from `r_index.seqOffset(sa_value)` at emit; write `e.path_bp` instead of `0`.
- `gafpack/src/main.rs`: `Record._pad`→`path_bp`; `process_path_matches` body — `step_index` HashMap → `cum_bp`/`step_node_ids` Vecs + `partition_point`; counted-warn cross-checks.

## Next
- Switch find_mems sort key `node_id`→`path_bp`, replace gafpack `partition_point` with two-pointer merge (drop `cum_bp` array entirely; build prefix on the fly). Then drop `node_id` from `BinRecord` if nothing else needs it.
- Clean A/B on find_mems maxrss anomaly.
- `_coverage.csv` md5 also changed (`c7ad02f…0fcce`) — expected, since the 907 records now contribute coverage from the correct steps. No separate validator for coverage; spot-check if needed.
