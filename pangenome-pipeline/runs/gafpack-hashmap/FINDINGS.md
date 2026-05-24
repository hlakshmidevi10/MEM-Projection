# gafpack E: loop→hashmap (`process_path_matches`)

Branch: `gafpack-hashmap-walk` @ `gafpack-bufwriter@5b96c63` (off `path-walker@ac672d7`).
Change: replace `loop { for step in steps { while seg_id == curr_node_id { ... } } }` with a single-pass `for idx in st..end` over records, using `HashMap<node_id, Vec<step_idx>>` built once per path. Missing node_id → `eprintln!` + skip (was: ∞-loop).

## Correctness
- `.gaf` md5 `b2807d832513247a27adf6dcd0901a34` ×3 (full runs E2_full, E2_b, E2_c) — **byte-identical** to bufwriter / binio-p2 / baseline. ✅
- `_coverage.csv` md5 `f4bcf640959688b33b047f4064078e87` ×3 + cov-only run — byte-identical. ✅
- `validate_gaf_v2.py` n=2000 ×3: {0, 0, 0} invalid; n=50000: 9 invalid (0.018%, within 902/4.95M baseline). ✅
- stderr summary: `Path-scan passes: total=632 over 632 seq_ids (mean=1.0, max=1); step-visits≈21591821` (was mean=229.2, max=1138, ≈6.2B step-visits). ✅
- ∞-loop footgun closed: node_id not on path now prints `ERROR: node_id ... not on path ...; skipping record` and continues.

## Performance (yeast235-chrII, 100k reads, 4.95M records)
| step       | baseline (05-03) | binio-p2 | bufwriter (#2-5) | **E (this)** | Δ vs bufwriter | Δ vs baseline |
|------------|------------------|----------|------------------|--------------|----------------|---------------|
| 10_gafpack | 149s / 90MB      | 117s / 202MB | 38.6s / 203MB | **3.5s / ~230MB** | **−91%** | **−97.6%** |
| 09+10      | 181s             | 144s     | 66s              | **~30.5s**¹  | −54%           | −83%          |

¹ 27s (binio-p2 step 09) + 3.5s.

| build | full (GAF+cov) | cov-only |
|---|---|---|
| #2-5 (bufwriter) | 501.4B inst / 38.6s | 492.6B inst / 37.6s |
| **E** | **32.2B inst / 3.50–3.92s** ×3 | **23.3B inst / 2.87s** |

maxrss ~220–245MB (+~15–40MB vs bufwriter: per-path `Vec<usize>` occurrence lists, transient).

## Why byte-identity needed cursor tracking
First attempt used `HashMap<node_id, first_step_idx>`. Faster (2.5s / 24B inst) but `.gaf` md5 diverged on **7 / 4,954,591** records, all on paths where a node_id appears at multiple step indices. The old `loop{for}` picks the first occurrence **≥ current for-cursor** (cursor = last-matched-step + 1 when node_id changes; wraps to 0 on pass restart). Replicated via:
- `step_index: HashMap<usize, Vec<usize>>` (all occurrences, ascending by construction)
- on node_id change: `occs.partition_point(|&j| j < cursor)` → first occ ≥ cursor, else `occs[0]`; `cursor = i+1`
- cursor only advances on node_id change (old `while` consumed all same-node_id records at one step)

Cost of cursor-tracking vs first-occurrence: ~+8B inst (~+1s) from per-node `Vec` allocs + binary search.

**Side finding (deferred):** the 7 cursor-dependent records are all on repeated-node paths — same class as the 902 pre-existing GAF invalids ("path-offset bug on cyclic/repeated-node walks", `project_upstream_sync_validation.md`). First-occurrence output validated at 903 invalid (net +1). Occurrence selection on repeated nodes is a concrete lead for the 902 root-cause; the cursor-tracking choice is *byte-identical to old behavior*, not necessarily *correct*.

## Files changed
- `gafpack/src/main.rs`: `process_path_matches` body — build `step_index` once, single `for idx in st..end` loop with cursor/prev_node_id/i state; `let-else` on missing node_id; return `Ok((total_gaf_entries, 1))`. `use std::collections::HashMap`.

## Remaining
- 902-invalid root cause (now with repeated-node-occurrence lead).
- find_mems B1-3.
- Deterministic tie-break, mmap (nice-to-haves).
