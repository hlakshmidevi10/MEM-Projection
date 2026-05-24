# v2: 16-byte path_bp-sorted records + linear-merge path-walker

**Dataset:** yeast-235 chrII (100 Kb), 100,000 reads, MEM_LEN=30, MIN_OCC=1
**Reference run:** `../v1-current/` (same indexes, same host, current PI + gafpack `path-walker` binaries)
**Plan:** `../../PLAN_find_mems_binary_io_v2.md`

## Branches

| Repo | Branch | Built into |
|---|---|---|
| `pangenome-index-latest` | `find-mems-binary-io-v2` (off `upstream-sync` @ `5ce98cf`) | `bin/find_mems` |
| `gafpack`                | `find-mems-binary-io-v2` (off `path-walker`)              | `target/release/gafpack` |

v1 baselines used for A/B: PI `upstream-sync` → `bin-v1/find_mems`; gafpack `path-walker` → `target/v1/gafpack`. Sibling tools (build_rindex, build_tags, convert_tags, path_extract, print_stats) are unchanged between v1 and v2 and were symlinked into `bin-v1/`.

## Final v2 record format (16 B)

```c
struct BinRecordV2 {
    uint32_t path_bp;     // sort key within each seq_id bucket
    uint32_t match_len;   // full u32 (no bit-31 packing)
    uint32_t read_st;
    uint32_t read_id;
};
```

`is_rev(graph_pos)` is NOT stored. node_id and offset are derived in the walker.
`_seq_id_starts.out` format unchanged; byte offset into the bin = `idx * 16`.

## Correctness gates

| Gate | Test | Result |
|---|---|---|
| 1a | Rust record round-trip + edge values (3 tests) | **PASS** (cargo test) |
| 1b | Walker derivation E1-E11 + monotonic stress + isolation + single-step (14 tests) | **PASS** (cargo test) |
| 2  | Per-record derivability vs v1 on 4,954,591 yeast-235 records | **PASS** (0 failures) |
| 3  | Sorted GAF set-equality v1 vs v2 (`diff <(sort v1.gaf) <(sort v2.gaf) \| wc -l`) | **PASS** (0 diff lines) |
| 4  | Coverage CSV byte-identical (md5) | **PASS** (md5 `c7ad02f5b5d1388d189a4e1cef70fcce`) |
| 5  | `validate_gaf_v2.py --sample 2000` v1 vs v2 invalid count | **PASS** (0 vs 0) |

Per the plan, Gates 3-4 together prove information-equivalence at the user-facing output level. Gate 2 proves it at the record level. Gate 5 is the end-to-end biological validation.

## Performance

| step               | v1-current      | v2-yeast235     | Δ wall | Δ rss |
|--------------------|-----------------|-----------------|--------|-------|
| 09_find_mems       | 22 s / 1367 MB  | 23 s / 1165 MB  | +1 s   | -202 MB |
| 10_gafpack         | 2 s / 246 MB    | 2 s / 200 MB    | =      | -46 MB  |
| 09+10              | 24 s            | 25 s            | +1 s   | |
| 11_validate_gaf    | 17 s / 1764 MB  | 17 s / 1760 MB  | =      | = |

| artifact           | v1                | v2                | Δ |
|--------------------|-------------------|-------------------|----|
| `_path_pos*.bin`   | 118,910,184 B (4.95M × 24) | 79,273,456 B (4.95M × 16) | **−33.3%** |
| `_seq_id_starts.out` | byte-identical (4.8 KB) | byte-identical | 0 |
| `.gaf`             | 280 MB (4,954,591 rows) | 280 MB (4,954,591 rows) | 0 |
| `_coverage.csv`    | 15 MB             | byte-identical (md5 match) | 0 |

Notes:
- The `.bin` size shrink is the primary win: −39.6 MB on disk per run, −33% read I/O at gafpack startup.
- step 09 +1 s is within noise (1 trial each). Expected behaviour: sort key change (`node_id` → `path_bp`) is a wash; tag-array work is unchanged.
- step 10 RSS down 46 MB tracks the smaller `_path_pos_v2.bin` mmap (113 → 76 MB on this run; runtime parser also smaller without bit-31 unpacking).
- find_mems peak RSS down 202 MB from the slimmer `PackedEntry` (5 × u32 in-memory instead of 7 × u32) — 28 B → 20 B per entry, × 4.95M entries × ~3 retained buffers = ~120 MB saved, matches.

## Bug postmortem: the is_rev sanity check

Plan v1 specified keeping `is_rev` as a per-record sanity bit in `match_len_rev` bit 31 and asserting `record.is_rev == (seq_id & 1)` in gafpack. The first v2 yeast-235 run revealed this assertion fired on **2,291 records across most paths**, causing gafpack to skip them — the v2 GAF was 1,428,106 rows short (3,526,486 vs 4,954,591). validate_gaf still reported 100% on the 2000-sample (the missing rows were absent, not invalid) so the leakage was silent at the validation gate.

**Root cause:** in find_mems, `is_reverse = is_rev(graph_pos)` is the orientation of the BWT hit relative to the underlying *node*, dictated by the node's `+`/`-` orient in the GFA path. Bucket parity (`seq_id & 1`) is the orientation of the *path strand*. These are independent: a forward path can contain `-`-oriented nodes whose hits read out reverse-complement. Asserting equality drops every such hit.

**Fix:** drop the `is_rev` bit from the v2 record entirely. The GAF strand is already correctly derived in `traverse_nodes` from the bucket parity XOR the GFA step's `+`/`-`. No information is lost. Record becomes 4 clean u32s; `match_len` regains the full u32 range.

**Lessons applicable beyond this fix:**
1. Validation gates that count valid rows but not row presence (like `validate_gaf_v2.py --sample 2000`) cannot detect "silent drops". Gate 3 (sorted GAF set-equality vs v1 baseline) caught this immediately and should be the **first** gate run after a code change, not the third.
2. Sanity assertions worth keeping should test invariants that are *load-bearing for correctness*, not invariants that *might be true*. The bucket parity / is_rev check was the latter; deleting it removed a class of false positives entirely.
3. The unit-test grid (Gates 1a, 1b) verified the *new code* was right but couldn't catch a *misunderstanding of the writer's semantics*. Pipeline-scale A/B against a known-good v1 baseline (Gate 3) was indispensable.

## Reproduce

```bash
cd mem-projection/pangenome-pipeline

# v1 baseline (uses bin-v1/find_mems + target/v1/gafpack from path-walker)
BIN_FORMAT=v1 \
PI_BIN=/Users/hlakshmidevi/personal/pangenome-index-latest/bin-v1 \
GAFPACK=/Users/hlakshmidevi/personal/gafpack/target/v1/gafpack \
  ./run.sh yeast235-chrII-normalized.env v1-current

# v2 (uses bin/find_mems + target/release/gafpack from find-mems-binary-io-v2)
BIN_FORMAT=v2 \
  ./run.sh yeast235-chrII-normalized.env v2-yeast235

# Gate 2 (derivability)
python3 ../scripts/derivability_v1_v2.py runs/v1-current runs/v2-yeast235 \
  ../yeast-235/yeast-235-chrI/final_output2/yeast235_chrII_100kb_laced_sorted_normalized_new.gfa

# Gate 3 (sorted GAF set-equality)
diff <(sort runs/v1-current/*.gaf) <(sort runs/v2-yeast235/*.gaf) | wc -l   # → 0

# Gate 4 (coverage CSV)
md5 runs/{v1-current,v2-yeast235}/*_coverage.csv   # → same hash both sides

# Gate 5 (validate_gaf parity) is run automatically at the end of each pipeline.
```
