# Plan: find_mems in-memory sort + binary handoff to gafpack

**Status:** **SUPERSEDED** by `PLAN_find_mems_binary_io_v2.md`. This document describes the v1 24-byte record format that shipped as the first binary handoff (PI branch `upstream-sync`, gafpack branch `path-walker`). v2 replaces the record layout with a 16-byte format and rewrites the gafpack walker — see the v2 plan for the canonical current spec. Kept here for historical context (PRs `find-mems-binary-io` #1 and `find-mems-pathbp` #2).
**Scope (historical):** optimizations A (find_mems) + D (gafpack) only. B (timing/buffer hygiene) and E (gafpack path-walk rewrite) were explicitly **out of scope** for this branch. E was eventually addressed by the v2 walker.

## Branches

| Repo | Base | Branch |
|---|---|---|
| `pangenome-index-latest` | `upstream-sync` @ `6073141` | `find-mems-binary-io` |
| `gafpack` | `path-walker` @ `1b7d437` | `find-mems-binary-io` |
| `mem-projection` | `main` | (no branch — harness/docs edited in place) |

Rollback: `git checkout upstream-sync` / `git checkout path-walker`. Neither base branch is touched.

---

## Phase 1 — find_mems: in-memory entries + bucket sort, **TSV output**

Goal: eliminate the `_tmp.tsv` write→read→parse roundtrip and the string-swapping global sort, **without** changing the gafpack-facing format. Validatable against unmodified gafpack.

### Changes (`src/find_mems.cpp`)

1. New POD struct (kept in-memory, includes `seq_id` for bucketing):
   ```cpp
   struct PackedEntry {
       uint32_t seq_id;
       uint32_t node_id;
       uint32_t offset;     // is_rev packed into bit 31
       uint32_t match_len;
       uint32_t read_st;
       uint32_t read_id;
   };
   ```
2. `dump_mem_info_unique_runs`: replace string-format + file-write (lines ~403–417) with `entries.push_back(PackedEntry{...})`. `seq_id_counter[seq_id]++` stays.
3. After all reads processed:
   - Prefix-sum `seq_id_counter` → `bucket_start[num_seq+1]`.
   - Allocate `out(entries.size())`; one O(n) scatter pass: `out[cursor[e.seq_id]++] = e`.
   - For each seq_id range `[bucket_start[k], bucket_start[k+1])`: `std::sort` by `node_id`.
   - Write `_path_pos.tsv`: 6 tab-separated columns `node_id offset is_rev match_len read_st read_id` (seq_id stripped — same as today).
   - Write `_seq_id_starts.out`: `bucket_start[0..=num_seq]`, one per line (same as today).
4. Delete: `_tmp.tsv` write, `sort_mem_output_by_seq_node()`, `MEMData`, the `reserve(total_mem_matches)` over-allocation.

### Validation gate

```bash
cd mem-projection/pangenome-pipeline
TAG=binio-p1
rm -f runs/$TAG/${OUT}_path_pos.tsv runs/$TAG/${OUT}_seq_id_starts.out runs/$TAG/${OUT}.gaf runs/$TAG/${OUT}_coverage.csv
./run.sh yeast235-chrII-normalized.env $TAG
grep -E '^(Valid|Invalid)' runs/$TAG/logs/11_validate_gaf.log
```

**Pass criterion:** `Invalid entries: 0`.
**Expected diffs vs ref:** `_path_pos.tsv` and `.gaf` md5 will differ (tie-order within `(seq_id, node_id)` groups changes — current `std::sort` is unstable, bucket sort produces a different unstable order). `_seq_id_starts.out` should be md5-identical. `_tmp.tsv` no longer exists.

---

## Phase 2 — binary handoff

Goal: replace text `_path_pos.tsv` with fixed-width `_path_pos.bin`; gafpack indexes directly with zero parsing and zero line-skipping.

### Record format (shared contract)

```
struct Record {            // little-endian, 24 bytes
    u32 node_id;
    u32 offset_rev;        // bit 31 = is_rev, bits 0..30 = node-local offset
    u32 match_len;
    u32 read_st;
    u32 read_id;
    u32 _pad;              // =0; keeps 8-byte alignment for &[Record] casts
}
```

`_seq_id_starts.out` is **unchanged** — its integers are record indices; byte offset = `idx * 24`.

### 2a. find_mems (`src/find_mems.cpp`)

- After Phase-1 sort, write `out` (minus the `seq_id` field) as a contiguous `_path_pos.bin` via one `ofstream::write()`. Either define a separate 24-byte on-disk struct or copy fields into a temp buffer per record.
- Add `--tsv` CLI flag: when set, also emit `_path_pos.tsv` (for debugging/triage). Default off.

### 2b. gafpack (`src/main.rs`)

- Add dep `bytemuck`.
- `#[repr(C)] #[derive(Copy, Clone, Pod, Zeroable)] struct Record { ... }` matching the layout above.
- In `walk_gfa`: `let bytes = std::fs::read(path_pos_path)?; let records: &[Record] = bytemuck::cast_slice(&bytes);` — once, before the GFA loop.
- `process_path_matches` signature changes to take `records: &[Record]` instead of `path_pos_path: &Path`. Body: `for rec in &records[st..end] { ... }`. Delete the open / `read_until` skip / `read_line` / `split('\t')` / `parse` machinery.
- CLI: `--path-pos` now points at the `.bin`.

### 2c. `run.sh`

- Step 09 output guard: `[ -f "${OUT}_path_pos.bin" ]`.
- Step 10 `--path-pos "${OUT}_path_pos.bin"`.

### Validation gate

```bash
TAG=binio-p2
./run.sh yeast235-chrII-normalized.env $TAG
grep -E '^(Valid|Invalid)' runs/$TAG/logs/11_validate_gaf.log
diff <(sort runs/binio-p1/${OUT}.gaf) <(sort runs/$TAG/${OUT}.gaf)   # should be empty
```

**Pass criterion:** `Invalid entries: 0` AND sorted-`.gaf` line sets identical to Phase 1.
Record `09_find_mems` / `10_gafpack` wall time + maxrss vs Phase 1 in `runs/$TAG/FINDINGS.md`.

---

## Phase 3 — docs/tooling

- `compare.sh`: drop md5 on `_path_pos.tsv` / `.gaf` / `_coverage.csv`; add `_path_pos.bin` size check; add sorted-`.gaf` line-set diff.
- `CLAUDE.md`:
  - Step 09 output list: `_path_pos.bin` (+ optional `_path_pos.tsv` via `--tsv`), `_seq_id_starts.out`. `_tmp.tsv` removed.
  - Document the 24-byte record layout.
  - Triage step 2: rerun `find_mems --tsv` and grep that, instead of `_tmp.tsv`.
  - gafpack ∞-loop footgun: **still present** (E is out of scope) — but now triggered by a node_id not on the path; the line-skip variant is gone.

---

## Out of scope (deferred)

- **B** — `find_mems` hot-loop hygiene: per-call `clock::now()` removal, `decoded_runs`/`seen_graph_positions` reuse, skip trailing `locateNext`. Zero output change; do on a separate branch.
- **E** — gafpack `loop {}` → `HashMap<node_id, step_idx>` lookup. Removes ∞-loop footgun. Separate branch.
- Deterministic tie-break (extend sort key to `(node_id, offset, read_st, read_id)`) — nice-to-have for stable diffs, not required for correctness.
