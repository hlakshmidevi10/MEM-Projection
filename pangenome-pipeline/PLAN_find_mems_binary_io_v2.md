# Plan: find_mems v2 — 16-byte path_bp-sorted records + linear-merge path-walker

**Status:** **CANONICAL** — this is the on-disk record format the pipeline uses. All correctness gates PASS on yeast-235 chrII (`runs/v2-yeast235/FINDINGS.md`); performance characterized in `perf/yeast235-chrII/FINDINGS_PERF.md`.
**Supersedes:** the on-disk record format defined in `PLAN_find_mems_binary_io.md` (Phase 2). Steps 01–08 of the pipeline are unchanged. The v1 plan's Phase 1 (in-memory bucket sort in `find_mems`) and Phase 2's `_seq_id_starts.out` semantics are preserved.
**Scope:** record-layout change + walker rewrite. No changes to MEM finding, tag-array querying, r-index API, GBZ/GFA parsing, or `validate_gaf_v2.py`.

> **Correction during implementation:** the original plan kept `is_rev` as a per-record sanity bit in `match_len_rev` bit 31. This was **wrong** — `is_rev(graph_pos)` from the BWT hit (per-node strand) is independent of bucket parity (`seq_id & 1`, the path strand) and the equality assertion silently dropped ~1.4M valid records on yeast-235. The final v2 record drops `is_rev` entirely and `match_len` uses the full u32. See `runs/v2-yeast235/FINDINGS.md § "Bug postmortem"` for details.

## Motivation

The v1 record carries six u32s (24 B): `node_id, offset_rev, match_len, read_st, read_id, path_bp`. After the v1 binary-handoff branch landed, three observations made the layout look over-specified:

1. **`node_id` and `offset` are recoverable from `path_bp`** given the path's step list and node-length prefix sum that gafpack already builds (`gafpack/src/main.rs:403-410`). They are therefore redundant on disk.
2. **`gafpack` already does a `partition_point` on `cum_bp` per record** (`main.rs:433`) to find the containing step. If records are pre-sorted by `path_bp`, the walker can advance a single step cursor monotonically — O(steps + records) instead of O(records · log steps) — and the redundant `node_id`/`offset` are no longer needed even for the lookup, only for the consistency check.
3. **The consistency check itself** (`main.rs:418-425`, `mismatch_node` / `mismatch_off` counters) exists *because* of the redundancy. Removing the redundancy removes the failure mode. The end-to-end safety net is `validate_gaf_v2.py`, which is independent of the record format.

A side benefit: **the known footgun "`gafpack` infinite-loops on bad input" (`CLAUDE.md:61`) is eliminated** — the `loop {}` over steps is replaced by a forward-only step cursor with a hard upper bound.

## Wins (measured against v1, same inputs)

| Axis | v1 | v2 | Δ |
|---|---|---|---|
| Record size | 24 B | 16 B | **−33 %** I/O + RAM |
| `_path_pos.bin` size on disk | N · 24 B | N · 16 B | **−33 %** |
| Walker per-record cost | O(log S) `partition_point` | O(1) amortized cursor advance | const factor |
| `find_mems` per-bucket sort key | `u32 node_id` | `u32 path_bp` | wash |
| `gafpack` ∞-loop footgun on corrupt input | present | **removed** | qualitative |

## Non-goals

- No change to MEM-finding algorithm, r-index queries, or tag-array semantics.
- No change to `_seq_id_starts.out` (still a prefix sum of record indices, line `k` = first record for `seq_id k`).
- No change to the `seq_id = 2 × path_idx + orientation` convention.
- No change to `validate_gaf_v2.py` or `compare.sh`'s sorted-line-set diff for `.gaf` / `_coverage.csv`.
- No change to `find_mems`' CLI surface (positional args + `--tsv` / `--debug-stats` / `--verbose`).

---

## Record format (v2, as shipped)

**16 bytes, little-endian, naturally 8-byte aligned (no pad).**

```
struct Record {           // sorted by path_bp within each seq_id bucket
    u32 path_bp;          // bp offset of hit within the path text (= r_index.seqOffset)
    u32 match_len;        // full u32; reads ≤ 20 Kbp in practice
    u32 read_st;          // start position within the read
    u32 read_id;          // 1-based line number in the reads file
}
```

The GAF strand is the XOR of bucket parity (`seq_id & 1`) and the GFA step's `+`/`-` orient — already correctly computed in `gafpack` `traverse_nodes()`. No per-record strand bit is required or stored.

**On-disk filename:** `<OUT>_path_pos_v2.bin` (separate filename from v1 so `compare.sh` and the `[ -f <out> ]` resume-guards distinguish formats cleanly; no embedded magic bytes needed).

**`_seq_id_starts.out`:** unchanged in format and semantics. Byte offset into v2 file = `record_index × 16` (was `× 24` for v1).

### Why these fields (and not the others)

| Field | Kept? | Rationale |
|---|---|---|
| `path_bp` | yes | Sort key + sole positional source-of-truth. |
| `match_len` | yes | Walker needs it to call `traverse_nodes`; not derivable. |
| `read_st` | yes | Goes into the GAF row; not derivable. |
| `read_id` | yes | Goes into the GAF row; not derivable. |
| `is_rev` | **dropped** (was kept in plan v0) | `is_rev(graph_pos)` is the per-node BWT strand, NOT the path-strand. Bucket parity already encodes the latter; the former is unused downstream. Earlier draft asserted equality between the two and silently dropped 1.4M valid records — see postmortem. |
| `node_id` | dropped | Derivable from `path_bp` via `cum_bp` prefix sum. |
| `offset` | dropped | Derivable from `path_bp - cum_bp[step]`. |
| `_pad` | dropped | 4 × u32 is already 8-byte aligned. |

### Per-bucket sort key

v1: `node_id` ascending. v2: **`path_bp` ascending**. Tie-break is unspecified (current sort is unstable, same as v1). Tie-breaking is not required for correctness — the consumer treats each record independently — but if we later want byte-stable `_path_pos_v2.bin` md5s across runs, extend the sort key to `(path_bp, read_id, read_st)`.

---

## Walker algorithm (v2)

Per `(P-line, orientation)` slice `recs = &records[starts[seq_id] .. starts[seq_id+1]]`, pre-sorted by `path_bp`:

```text
// Build the path's step_node_ids[] and cum_bp[] prefix sum (same as today).
// cum_bp[i]  = sum of node lengths for steps 0..i-1
// cum_bp[N]  = path_total_bp

i   = 0                                 // monotonic step cursor
cum = 0                                 // = cum_bp[i]

for r in recs:                          // recs sorted by r.path_bp ascending
    assert (r.match_len_rev >> 31) == (seq_id & 1)   // is_rev sanity
    if r.path_bp >= path_total_bp:                   // existing guard, kept
        log "path_bp out of range"; continue

    // Advance cursor to the step containing r.path_bp.
    // Amortized O(1) across the whole slice: i only moves forward.
    while i + 1 < step_node_ids.len()
          and r.path_bp >= cum_bp[i + 1]:
        cum = cum_bp[i + 1]
        i  += 1

    offset = r.path_bp - cum
    traverse_nodes(&steps[i..], offset, r.match_len, ...)
    write_gaf_row(r, seq_id, ...)
    // coverage updates happen inside traverse_nodes, unchanged
```

Loop-invariant: `cum_bp[i] <= r.path_bp < cum_bp[i+1]` after the `while`. Total work across the slice: at most `steps.len()` cursor advances + `recs.len()` constant-time pops. **No `partition_point`, no per-record search, no loop-with-no-explicit-bound.**

The cursor *cannot* leak across paths or orientations because `process_path_matches` is called fresh per `(P-line, orientation)` and each call gets its own `i` / `cum`.

### What goes away from v1's walker

- `partition_point` call (`main.rs:433`).
- `mismatch_node` / `mismatch_off` counters and their warn-log machinery (`main.rs:418-425`).
- The implicit unbounded scan for `node_id` in steps — i.e. the footgun.

### What stays

- `traverse_nodes` (`main.rs:169-222`): byte-for-byte identical. Strand XOR rule, coverage updates, GAF `path_str` construction unchanged.
- GAF row format and column order unchanged (`main.rs:466-468`).
- `_coverage.csv` writer unchanged (`main.rs:733-755`).
- Twice-per-P-line invocation (forward, then reverse) unchanged.

---

## Implementation phases

### Phase A — `find_mems.cpp` (writer side)

Branch: `find-mems-binary-io-v2` off current `find-mems-binary-io` head.

1. Rename `BinRecord` → `BinRecordV2`, define as the 16-byte struct above. `static_assert(sizeof(BinRecordV2) == 16, "v2 record must be 16 bytes")`.
2. Shrink `PackedEntry` to `{ uint32_t seq_id; uint32_t path_bp; uint32_t match_len; uint32_t read_st; uint32_t read_id; uint8_t is_rev; }` (or pack `is_rev` into bit 31 of `match_len` in-memory too — preferred, keeps PackedEntry to 5 × u32 = 20 B).
3. In `dump_mem_info_unique_runs` (`find_mems.cpp:316-505`): drop node-id/offset capture; keep the existing tag-run iteration, `r_index.seqId(sa)`, `r_index.seqOffset(sa)` logic — those still produce `seq_id` and `path_bp`. Push the slimmer `PackedEntry`.
4. In `write_sorted_entries` (`find_mems.cpp:508-578`):
   - Bucket-scatter unchanged.
   - Per-bucket sort: change comparator from `node_id` to `path_bp` ascending.
   - Output filename: `<OUT>_path_pos_v2.bin`. Single contiguous `ofstream::write` of `N × 16 B`.
   - `_seq_id_starts.out` writer unchanged.
5. `--tsv` writer: emit columns `path_bp match_len is_rev read_st read_id` (drop `node_id`, `offset`). Update header comment.
6. Document the new layout at the top of the file.

### Phase B — `gafpack/src/main.rs` (reader side)

Branch: `find-mems-binary-io-v2` off `find-mems-binary-io` head.

1. Mirror `Record` as 4 × u32 `#[repr(C)] #[derive(Copy, Clone, Pod, Zeroable)]`. Inline helpers `match_len(&self) -> u32` and `is_rev(&self) -> bool`.
2. Add `const_assert_eq!(mem::size_of::<Record>(), 16)`.
3. CLI: add `--path-pos-v2 <path>` as the v2 entry point. Keep `--path-pos` working against v1 files for the duration of the transition (one-line dispatch in `main`, distinguishable by filename suffix). Both code paths share the parsed GFA, path-name map, and coverage vec.
4. Rewrite `process_path_matches` body per the algorithm above. Keep the function signature compatible (`records: &[Record]`, `seq_id`, `steps`, ...); only the loop changes.
5. Delete `mismatch_node` / `mismatch_off` declarations, increments, and the end-of-function warn lines.
6. Sanity assertion: `assert!(r.is_rev() == (seq_id & 1 == 1), ...)`. Bail on mismatch with an error message that names the file and record index — this is exactly the failure that the old `mismatch_node` counter would have surfaced.

### Phase C — pipeline glue

1. `run.sh`:
   - Step 09 output guard → `[ -f "${OUT}_path_pos_v2.bin" ]`.
   - Step 10 flag → `--path-pos-v2 "${OUT}_path_pos_v2.bin"`.
2. `compare.sh`:
   - Add a `_path_pos_v2.bin` size line: `(N records × 16)`.
   - Keep the existing v1 line for runs that predate the switch.
3. `CLAUDE.md`:
   - Step 09 output list: `_path_pos_v2.bin` (+ `_path_pos.tsv` via `--tsv`).
   - Replace the 24-byte record layout description with the 16-byte one.
   - Move "gafpack ∞-loop footgun" from "known footguns" to "historical (fixed in v2)".
   - Bump triage step 2 to reference the new TSV column set.

### Phase D — docs

- This file (`PLAN_find_mems_binary_io_v2.md`) is the spec of record.
- Add a one-paragraph entry in `Readme.md` pointing at this file from the step-10 / coverage section.
- Append a `FINDINGS.md` to the v2 validation runs with measured size & timing deltas vs v1.

---

## Validation strategy

Correctness gates apply **in this order**. Each phase must pass all gates above it.

### Gate 1 — round-trip identity + walker edge cases (synthetic)

Before touching the pipeline, two synthetic test suites must pass.

#### 1a — record round-trip

C++ side (gtest or a standalone `.cpp` under `pangenome-index-latest/tests/`):
1. Constructs 1000 random `BinRecordV2` records covering `path_bp ∈ [0, 2^32)`, `match_len ∈ [1, 20000]`, both `is_rev` values.
2. Writes them to a temp file.
3. Reads them back via the same struct.
4. Asserts byte-for-byte equality and that `match_len` / `is_rev` accessors round-trip.

Rust side (`#[test]` in `gafpack/src/main.rs`): cast a `Vec<u8>` of known contents (hand-encoded little-endian) to `&[Record]` and verify field decoding for each of: `path_bp = 0`, `path_bp = u32::MAX`, `match_len = 1`, `match_len = 20_000`, `match_len = 0x7FFF_FFFF` (max representable), `is_rev = false`, `is_rev = true`. **This catches endianness, alignment, and bit-31 packing bugs before any real data is touched.**

#### 1b — walker derivation edge cases

Rust side (`#[test]` in `gafpack/src/main.rs`), unit-testing `process_path_matches` (or the inner derivation extracted into a pure helper). Construct a synthetic path with `step_node_ids = [10, 20, 30, 40]` and node lengths `[5, 7, 1, 3]`, giving `cum_bp = [0, 5, 12, 13, 16]` and `path_total_bp = 16`. For each case below, feed in a single `Record` and assert the resulting `(node_id, offset)` and acceptance/rejection.

| # | `path_bp` | Expected outcome | What it tests |
|---|---|---|---|
| E1 | 0 | accept, `node_id=10`, `offset=0` | first bp of first node |
| E2 | 4 | accept, `node_id=10`, `offset=4` | last bp of first node (off-by-one inside a node) |
| E3 | 5 | accept, `node_id=20`, `offset=0` | exact step boundary — must land on the *new* step, not the previous one |
| E4 | 6 | accept, `node_id=20`, `offset=1` | first bp inside a multi-bp node |
| E5 | 11 | accept, `node_id=20`, `offset=6` | last bp of a multi-bp node |
| E6 | 12 | accept, `node_id=30`, `offset=0` | entry to a **single-bp node** (cursor must advance exactly one step) |
| E7 | 13 | accept, `node_id=40`, `offset=0` | exit from a single-bp node into the next — cursor advanced twice in a row to cross a 1-bp node |
| E8 | 15 | accept, `node_id=40`, `offset=2` | **last valid bp on the entire path** (`path_total_bp - 1`) |
| E9 | 16 | **reject** (matches existing `path_bp >= path_total_bp` guard) | one past the end |
| E10 | 17 | **reject** | clearly past the end |
| E11 | 0xFFFF_FFFF | **reject** | maximum u32; must not overflow / wrap the cursor |

Then a **monotonic-cursor stress case**: a synthetic slice of 100 records with `path_bp = [0, 1, 1, 2, 5, 5, 5, 6, 12, 12, 13, 15]` (intentionally including repeats, exact boundaries, and gaps), fed in order, must produce the correct `(node_id, offset)` for each and the cursor `i` must be **monotonically non-decreasing** across the whole slice. (Add an internal assertion in the test that `i_after >= i_before` per iteration.)

A **multi-orientation isolation case**: call `process_path_matches` twice on the same path with disjoint record slices, verify that the cursor for the second call starts at `i=0` (not at the end of the first call). This is the "cursor reset between orientations" question from the Open Questions list.

A **`match_len` interaction case**: `path_bp = 14`, `match_len = 2` on the path above (`path_total_bp = 16`). The hit ends exactly at the path end. `traverse_nodes` must emit a valid GAF row with no out-of-bounds read. Same setup with `match_len = 3` should be rejected by `traverse_nodes`' own bounds check (or logged as an error, matching v1 behavior for over-long matches — verify behavior parity with v1 first and document the decision).

**Pass criterion: every case above behaves as tabulated, no panics, no silent corrections.** If any case fails, the walker is wrong; fix and re-run Gate 1 before proceeding to Gate 2.

### Gate 2 — derivability check (yeast-8, the smallest dataset)

Run the v1 pipeline once (`runs/v1-baseline-yeast8/`) and the v2 pipeline once (`runs/v2-yeast8/`) on the same inputs. Then for every record in `runs/v2-yeast8/${OUT}_path_pos_v2.bin`:

1. Find the `seq_id` it belongs to via `_seq_id_starts.out`.
2. Compute the expected `(node_id, offset)` from `path_bp` using the same `cum_bp` walk gafpack uses.
3. Look up the v1 record with matching `(seq_id, read_id, read_st, match_len, is_rev, path_bp)` in `runs/v1-baseline-yeast8/${OUT}_path_pos.bin`.
4. Assert `derived_node_id == v1.node_id` and `derived_offset == v1.offset_rev & 0x7FFF_FFFF`.

This is the **strongest single test**: it proves the v2 record format is information-equivalent to v1 for every real query position the pipeline produces. Implement as `scripts/diff_path_pos_v1_v2.py` (read both `.bin` files via `numpy.fromfile` with the appropriate dtype). Pass criterion: **100 % of v2 records match a v1 record under the derivation**. The reverse direction (every v1 record present in v2) follows by record-count equality.

### Gate 3 — sorted GAF set-equality (yeast-8)

```bash
diff <(sort runs/v1-baseline-yeast8/${OUT}.gaf) \
     <(sort runs/v2-yeast8/${OUT}.gaf)
```

**Pass criterion: empty diff.** The v2 walker must produce the identical *set* of GAF rows as v1 (row order within a `seq_id` bucket changes — v1 emits sorted by `node_id`, v2 by `path_bp` — but the multiset of rows is identical because every record produces exactly one row and the row content is a deterministic function of the record + path).

If this diff is non-empty:
- A non-zero number of "missing in v2" rows ⇒ records dropped (e.g. `path_bp == path_total_bp` boundary case mishandled, or the `while` loop terminates early). **Block the merge.**
- A non-zero number of "extra in v2" rows ⇒ records double-emitted (cursor reset bug). **Block the merge.**
- Both ⇒ different `(path_str, path_st)` for some records ⇒ walker step-mapping bug. **Block the merge.**

### Gate 4 — coverage set-equality (yeast-8)

```bash
diff <(sort runs/v1-baseline-yeast8/${OUT}_coverage.csv) \
     <(sort runs/v2-yeast8/${OUT}_coverage.csv)
```

**Pass criterion: empty diff.** Coverage is a deterministic sum over GAF rows; if Gate 3 passes, Gate 4 should pass for free. If it doesn't, suspect a floating-point reduction-order issue (extremely unlikely with integer-bp coverage; flagged for completeness).

### Gate 5 — `validate_gaf_v2.py` rate parity (yeast-8 and yeast-235)

Run with the same `--sample N` and the same random seed (add `random.seed(0)` at the top of the script for this comparison; revert after) on both v1 and v2 outputs. Compare the **invalid-entry count exactly**.

**Pass criterion:**
- yeast-8: `invalid_v2 == invalid_v1`. Ideally both 0.
- yeast-235: `invalid_v2 == invalid_v1` ± 0. The known baseline rate is ~0.02 % (`CLAUDE.md:14`); v2 must reproduce it exactly, neither better nor worse. **A drop in invalid count is a red flag, not a win** — it most likely means v2 silently dropped the problematic records rather than fixing them.

If the rate differs, run `validate_gaf_v2.py --verbose` on both, diff the per-entry `(VALID|INVALID)` decisions, and triage the entries where they disagree.

### Gate 6 — independent re-derivation (yeast-235, post-merge)

After all yeast-8 gates pass, on the full yeast-235 dataset:
1. Pick 50 GAF rows where `match_len > 100` and the path traverses ≥ 3 nodes.
2. For each, manually reconstruct the path substring from the GFA (not via gaftools) and compare to the corresponding read substring `[read_st, read_st+match_len)`.
3. All 50 must match exactly.

This catches walker bugs that `validate_gaf_v2.py` might tolerate at the 0.02 % noise floor. Implement once as `scripts/spot_check_gaf.py`; keep around.

### Gate 7 — performance check (yeast-235)

After all correctness gates pass, record in `runs/v2-yeast235/FINDINGS.md`:
- `_path_pos.bin` v1 size vs `_path_pos_v2.bin` v2 size (expect ratio 24:16 = 1.5).
- Step 09 wall-clock and peak RSS deltas.
- Step 10 wall-clock and peak RSS deltas.
- `validate_gaf_v2.py` invalid count (must equal v1).

Performance regressions are not blocking (a small regression is acceptable if correctness is intact), but a **>10 % regression in step 09 or step 10 wall-clock is unexpected** and should be investigated before merge.

---

## Rollback

- All edits live on `find-mems-binary-io-v2` branches in both repos.
- The v1 reader path in `gafpack` is preserved for the duration of the transition (`--path-pos` continues to work against `_path_pos.bin`).
- `run.sh` change is one line per step; reverting restores v1 invocation.
- `_path_pos_v2.bin` is a different filename from `_path_pos.bin`, so v1 and v2 outputs can coexist in the same `runs/<tag>/` directory during A/B comparison.

## Open questions to revisit before merge

1. **Tie-break stability.** Worth extending the sort key to `(path_bp, read_id, read_st)` for byte-stable `_path_pos_v2.bin` md5s? Cost: a few extra cycles in `std::sort`'s comparator. Benefit: `compare.sh` could md5-check the binary instead of relying solely on the sorted-GAF diff. *Recommendation: yes, do it — it's a cheap and durable correctness aid.*
2. **Format version byte.** Currently encoded via filename. If we ever need multiple v2 variants on disk simultaneously, a leading 8-byte header `("PPV2\0\0\0\0", u32 record_size, u32 record_count)` would be more robust. *Recommendation: defer until needed; filename is sufficient now.*
3. **Cursor reset between orientations.** The forward and reverse passes use disjoint slices of `records`, so the cursor is naturally fresh per call. But worth a single-line comment in `process_path_matches` to prevent a future refactor from sharing state. *Recommendation: add the comment.*

---

## Summary

v2 trades a redundant `(node_id, offset)` pair on disk for a sort-key change (`node_id` → `path_bp`) and a walker rewrite (binary search → linear merge). The result is 33 % smaller I/O, an O(1) per-record walker, and the elimination of an infinite-loop footgun. Correctness is gated by an explicit v1-vs-v2 record-derivability check (Gate 2), sorted-line-set equality of `.gaf` and `_coverage.csv` (Gates 3–4), exact `validate_gaf_v2.py` invalid-count parity (Gate 5), and independent manual spot-checks at the full-dataset scale (Gate 6). Nothing merges until every gate above its phase passes.
