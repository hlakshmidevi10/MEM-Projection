# gafpack BufWriter + direct write! (#2 + #4)

Branch: `gafpack-bufwriter` @ `path-walker` (off `ac672d7`).
Change: wrap `.gaf` and `_coverage.csv` outputs in `BufWriter::with_capacity(1<<20, ...)`; replace per-record `format!(...)` + `writeln!` with a single `write!(file, "...\n", ...)`; explicit `flush()` at end.

## Correctness
- `.gaf` **md5-identical** to binio-p2 / p1 / baseline: `b2807d832513247a27adf6dcd0901a34` (293,769,635 B). ✅
- `_coverage.csv` **md5-identical** to binio-p2: `f4bcf640959688b33b047f4064078e87` (16,109,009 B). ✅
- `compare.sh` vs `runs/binio-p2`: all IDENTICAL / SET-EQUAL. ✅
- `validate_gaf_v2.py` n=2000 ×6: {2, 0, 0, 0, 3, 1} invalid — within 902/4.95M baseline noise (E≈0.36). ✅
- `validate_gaf_v2.py` n=50000: 13 invalid (0.026%; baseline rate 0.018%, within sampling variance). ✅
- Second standalone run: 37.88 s, md5 unchanged. ✅

## Performance (yeast235-chrII, 100k reads, 4.95M records)
| step       | baseline (05-03) | binio-p2 (.bin) | bufwriter | Δ vs binio-p2 | Δ vs baseline |
|------------|------------------|-----------------|-----------|---------------|---------------|
| 10_gafpack | 149s / 90MB      | 117s / 202MB    | **39s / 203MB** | **−67%** | **−74%** |
| 09+10      | 181s             | 144s            | **66s**¹  | −54%          | −64%          |

¹ using binio-p2's 27s for step 09 (find_mems unchanged here).

Standalone re-run: 37.88s / 210MB (warm cache; consistent with harness 39s).

## Why the win was this large
4.95M `.gaf` rows + 1.28M `_coverage.csv` rows were each a separate `write(2)` syscall on a raw `File`. On macOS that's ~12–15 µs/call through VFS → ~75–90 s of pure syscall overhead. BufWriter collapses that to ~300 + ~16 syscalls. The `format!` → direct `write!` removes one heap alloc/record but is second-order here.

## Files changed
- `gafpack/src/main.rs`: import `BufWriter`; `gaf_output` type `Option<File>` → `Option<BufWriter<File>>` (signature in `process_path_matches` + `walk_gfa` + creation in `main`); GAF line `format!+writeln!` → `write!`; coverage `output_file` wrapped in `BufWriter`; explicit `flush()` on both.

## #3 + #5 (added 2026-05-11, same branch)
- #3: `traverse_nodes` now writes into a caller-owned `&mut String` (cleared per record); per-node `format!` + `Vec<String>` + `.join("")` → `push(strand_char) + push_str(seg)`. Reuses GFA segment-id `&str` directly (no int→string roundtrip). Return type `(String, usize)` → `usize`.
- #5: `--verbose` / `-v` flag gates per-path/per-record `eprintln!` (394–397, 416–418, 452–454, 600–604). ERROR prints + final summary stay unconditional. stderr 3505 → 27 lines.

**Correctness:** `.gaf` md5 `b2807d…1a34` ×2, `_coverage.csv` md5 `f4bcf6…8e87` ×3 — all byte-identical. `validate_gaf_v2.py` n=2000: 1 invalid (baseline noise). `--verbose` smoke: 3487 stderr lines (matches pre-#5). ✅

**Perf:** noise-level. Instructions retired (most stable metric):
| build | full (GAF+cov) | cov-only |
|---|---|---|
| #2+#4 | — | 498.5B inst / 36.4s |
| +#3 | 514.6B / 39.5s | 505.8B / 38.3s |
| +#3+#5 | 501.4B / 38.6s ×2 | 492.6B / 37.6s |

Net #3+#5 vs #2+#4-only: ≈ −1.2% instructions, wall within ±1.5s run-to-run variance. GAF-write cost (full − cov-only) ≈ 1–2s / 9B inst.

**Why so small:** ~4.95M `traverse_nodes` calls × ~2–3 nodes/call ≈ 12M tiny allocs eliminated, but the outer `loop { for step in steps { seg.parse() } }` does ~10.9M-step scans × multiple passes = the real ~490B-instruction floor. #3/#5 don't touch that.

## Remaining (unchanged by this branch)
- **E (loop→hashmap) is the entire residual ~37s.** Pre-parse `steps` to `Vec<(u32, bool)>` once per path + `HashMap<node_id, Vec<step_idx>>` lookup. Also fixes the ∞-loop footgun.
- ∞-loop footgun still present.
