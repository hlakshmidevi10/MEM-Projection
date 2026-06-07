# pangenome-pipeline — agent guide

## What this directory is
Reusable driver for the `pangenome-index-latest` → `gafpack` → `validate_gaf` workflow. Bifurcated into expensive **index build** (steps 01–08b) and cheap **per-query projection** (steps 09–11), with per-query subdirs under one shared index.

```
build_index.sh               ./build_index.sh <config.env> <index-tag>          → runs/<index-tag>/
query.sh                     ./query.sh <config.env> <index-tag> [query-name] [--gaf] [--full-tag]
                                 → runs/<index-tag>/queries/<query-name>/{lightweight,full-tag}/
compare.sh                   ./compare.sh <config.env> <index-tag> <query-name> [ref-query-dir]
bootstrap_vesuvio.sh         per-user install of all deps on a fresh Linux host
configs/*.env                inputs + params (see yeast235-chrII-normalized.env for the contract)
runs/<index-tag>/            one shared index per build; queries/<q>/ per query
BUILD_QUERY_LAYOUT.md        full directory + config contract documentation
vesuvio-build-issues.md      field notes on porting to Guix-on-Debian — read before debugging build failures on a non-Mac host
```

## Correctness criterion
**A query is correct iff its sorted `.gaf` line set matches a known-good reference, and `validate_gaf_v2.py` reports 100% valid on the sample.** `validate_gaf_v2.py` checks that every sampled GAF entry's `(read_id, read_st, match_len, node_id, offset)` actually corresponds to a real substring match between the read and the path the GAF claims — there is no biological reason for a correctly-built pipeline to ever produce an invalid entry. Any `Invalid > 0` indicates a real bug somewhere in the build_index/query chain (commonly: stale tag index, GBZ ↔ GFA node-ID mismatch, off-by-one in convert_tags), NOT noise.

**Invariant #1 — GBZ ↔ GFA node-ID parity.** Every node-ID-bearing artifact (tags, MEMs, GAF rows) references the GBZ's node ID space; gafpack walks a GFA. The two must agree. The mechanism that enforces this is **`build_index.sh` step 01b** (`vg convert -fW --no-translation $GBZ > $BASE.gfa`): the pipeline-facing GFA is always derived from the GBZ, never user-supplied. This matters because `prepare_inputs.sh` runs `gfa2gbwt -m 1024`, which may split source segments > 1024 bp into multiple GBZ nodes — after which GBZ node IDs no longer equal source-GFA segment IDs. Step 01b makes that split invisible to everything downstream. `-m 1024` (not `-m 0`) is required because `build_tags` uses a 10-bit per-node offset field and aborts on nodes ≥ 1024 bp (`Node offset 1024 is too large`); see `vesuvio-build-issues.md` hurdle #14.

**Threading.** Most `pangenome-index-latest` binaries (`build_rindex`, `build_tags`, `convert_tags`, `print_stats`, `build_lightweight_tags`) parallelize via OpenMP **without exposing a `-t` CLI flag** — they call `omp_get_max_threads()` internally and otherwise grab every available core. `build_index.sh` defends against this by `export OMP_NUM_THREADS="${OMP_NUM_THREADS:-$THREADS}"` immediately after sourcing the config, so the binaries respect the `THREADS` knob (and a CLI-level `OMP_NUM_THREADS=N ./build_index.sh ...` still wins). Steps with explicit `-t` flags (`gbz_extract`, `grlbwt-cli`) pass `$THREADS` directly — those are unaffected by the OMP cap and are bounded twice over.

Verified clean runs:
- yeast-235 chrII normalized: **2000/2000 valid** (100%)
- HPRC chr6 ref (grch38#1#chr6#0 reads): **2000/2000 valid** (100%)
- HPRC chr6 alt (HG00438#2#JAHBCA010000010.1#0 reads): **2000/2000 valid** (100%)

> Earlier (pre-lightweight-tags) runs occasionally showed 1–3 invalid in a 2000-sample, attributed at the time to gafpack v1 path-walker edge cases. That tolerance is obsolete now — the lightweight pipeline (build_lightweight_tags + find_mems --lightweight-tags + gafpack --dedup-read-node) has zero observed false-positive entries across all our HPRC-scale runs. Anything <100% is now a bug signal.

> **Note on out-of-graph reads:** the 100% target applies to the *emitted* GAF entries, regardless of where the reads came from. Even when reads come from a haplotype NOT represented in the graph (e.g. HPRCv2 HG002 reads queried against the HPRCv1 graph), find_mems should only emit MEMs that are genuine exact matches — so the validation should still hit 100%. What changes for out-of-graph reads is how *many* entries get emitted (fewer, since fewer ≥MEM_LEN matches exist), and how many reads contribute zero entries at all. Coverage will be sparser, but every reported entry should still be valid.

Index files (`.ri` / `_compressed.tags` / `.ltags` / `.gfa`) and query outputs (`mems_path_pos_v2.bin` / `alignment.gaf` / `alignment_coverage.csv`) will NOT md5-match `final_output2/` — encoding and row order have changed (and the binary record format itself differs from the v1 24-byte layout that `final_output2` was built against). Only `.seq` / `.rl_bwt` / `.tags` / `.paths` / `mems_seq_id_starts.out` are byte-stable. `compare.sh` does a sorted line-set diff for `alignment.gaf` / `alignment_coverage.csv`; SET-EQUAL there is the pass signal.

## Running
```bash
cd mem-projection/pangenome-pipeline

# Build the index once (slow)
./build_index.sh yeast235-chrII-normalized.env yeast-2026-06-03

# Run queries (each lands in queries/<name>/<tag-mode>/ — modes don't collide)
./query.sh yeast235-chrII-normalized.env yeast-2026-06-03                      # default: lightweight + coverage-only
./query.sh yeast235-chrII-ref-reads.env  yeast-2026-06-03 ref-reads --gaf      # + alignment.gaf + validate
./query.sh yeast235-chrII-ref-reads.env  yeast-2026-06-03 ref-reads --full-tag # full-tag mode (A/B vs lightweight)

# Compare a query against a reference
./compare.sh yeast235-chrII-normalized.env yeast-2026-06-03 normalized
```
- Every step is guarded by `[ -f <out> ]`, so re-invoking resumes after the last completed file. To force a step, delete its output (or `rm -rf` the per-tag-mode subdir).
- Per-step `/usr/bin/time -v` → `logs/NN_*.time`; one-line summary in `logs/timing_summary.txt`. Build logs at `runs/<index-tag>/logs/`; query logs at `runs/<index-tag>/queries/<q>/<tag-mode>/logs/`.
- `RUN_INFO.txt` at the index level records config, host, date, and pangenome-index commit. `RUN_INFO.txt` at the query level additionally records tag mode, GAF mode, and index file mtimes (so you can spot stale queries if the index was rebuilt).
- New dataset: copy a config under `configs/`, set `GBZ`, `BASE`, `READS`, and the pipeline parameters. `OUT` is no longer needed (per-query subdir name replaces it). `GFA` is deprecated (derived in step 01b).
- Two query mode axes: `--gaf` controls output (coverage-only by default; `--gaf` adds alignment.gaf + step 11 validation), `--full-tag` controls the tag index (lightweight by default; `--full-tag` uses the older non-lite pipeline for A/B comparisons).

## Pipeline shape & file roles
| Step | Tool | In | Out | Notes |
|---|---|---|---|---|
| 01 | `gbz_stats` | `.gbz` | log only | parsed for `NUM_SEQ` |
| 02 | `gbz_extract -b -t -p` | `.gbz` | `.seq` | both orientations; size ≈ 2 × `gbz_stats -p` path length (fwd + rev complement of each path). NOT a multiple of `-i Total length`, which is in BWT node-visits, not bp. HPRCv2 chr6: `.seq` = 160.7 GB = 2 × 80.34 Gbp. |
| 03 | `grlbwt-cli` | `.seq` | `.rl_bwt` | |
| 04 | `build_rindex` | `.rl_bwt` | `.ri` | new encoding (~60% smaller than pre-refactor) |
| 05 | `build_tags -k K` | `.gbz` `.rl_bwt` | `.tags` | slow step (~1 h on yeast-235) |
| 06 | `convert_tags --num-seq N` | `.tags` | `_compressed.tags` | **flag is mandatory**, see below |
| 07 | `path_extract` | `.gbz` | `.paths` | path name list, 1/line |
| 08 | `print_stats` | `.ri` `.ctags` | log only | index sizes |
| 09 | `find_mems` | `.ri` `.ctags` reads | `_path_pos_v2.bin` + `_seq_id_starts.out` | `--tsv` also emits `_path_pos.tsv` |
| 10 | `gafpack` | `.gfa` `_path_pos_v2.bin` `_seq_id_starts.out` `.paths` | `.gaf` `_coverage.csv` | |
| 11 | `validate_gaf_v2.py` | `.gaf` reads `.gfa` | log only | **the pass/fail gate** |

### Record format

`_path_pos_v2.bin` is a packed array of **16-byte** little-endian records:
```
u32 path_bp | u32 match_len | u32 read_st | u32 read_id
```
Records are sorted by `(seq_id, path_bp)` with `seq_id` stripped from disk. `_seq_id_starts.out` holds per-seq_id record-index boundaries (line `k` = first record for seq_id `k`; byte offset = `idx × 16`). `seq_id = 2 × path_idx + orientation`; `path_idx` = line number in `.paths`. gafpack derives `(node_id, offset)` by walking `path_bp` against the path's cum_bp prefix sum (linear merge via a monotonic step cursor — see `gafpack/src/main.rs:advance_step_cursor`).

See `PLAN_find_mems_binary_io_v2.md` for the design + correctness gates; `runs/v2-yeast235/FINDINGS.md` for the validated reference run; `perf/yeast235-chrII/FINDINGS_PERF.md` for performance characterization. Pass `--tsv` to `find_mems` for a human-readable `_path_pos.tsv` (columns: `path_bp match_len read_st read_id`).

> **Legacy v1 format** (24-byte records `node_id|offset_rev|match_len|read_st|read_id|path_bp`, sorted by `node_id`) lived on the PI branch `upstream-sync` / gafpack branch `path-walker` prior to the v2 refactor. Preserved there for archeology and recoverable via git; the current pipeline does not read or write it. `PLAN_find_mems_binary_io.md` documents the v1 design.

## How validation works
`validate_gaf_v2.py <gaf> <reads> <gfa> --sample N`:
1. Loads all GAF entries and reads.
2. Samples N entries; for each, reconstructs the path sequence via `gaftools` and the GFA, then checks the read substring `[read_st, read_st+match_len)` matches the path sequence at the GAF-specified offset.
3. Prints `Valid / Invalid / Total`. **Anything <100% means a wrong `(seq_id, node_id, offset)` somewhere upstream — investigate, don't tolerate.**

Validation is gated behind `query.sh --gaf`; the default (coverage-only) mode skips both GAF generation and validation. Before deploying any new index/binary combination to prod, run a query with `--gaf` at least once and confirm 100% valid.

Baseline numbers for comparison live in `$REF_DIR/PERFORMANCE_COMPARISON.md` (use the *normalized-graph* column).

## Known footguns
- **`convert_tags` without `--num-seq` silently produces a misaligned index.** It always strips endmarker runs (`Skipping pure endmarker run` in the log) and only re-prepends them if `--num-seq` is given. Without it, `bwt_intervals` is short by `NUM_SEQ`, every BWT-position→tag-run lookup is offset, and `find_mems` emits `(seq_id, node_id)` pairs where the node isn't on that seq's path. `build_index.sh` derives `NUM_SEQ` from `gbz_stats` output. Sanity check: `convert_tags` log should report `bwt_intervals size == n+1` where `n` = `.seq` byte length.
- **`gafpack` v1 infinite-loops on bad input.** `process_path_matches` on the `path-walker` branch had a `loop {}` that only exits when every record's `node_id` is found on its path's step list. v2 replaces this with a monotonic step cursor — no implicit unbounded loop possible. Footgun is **gone** as of v2.
- **`find_mems` reports two different n/r ratios; the per-MEM mean is outlier-skewed.** The log prints both `Mean per-MEM n/r ratio = (1/N)·Σ(mem.size/tag_runs)` and `Global n/r ratio = Σmem.size / Σtag_runs`. The per-MEM mean is dominated by a long tail of high-occurrence MEMs (e.g. HPRCv2 chr6 alt-noisy: mean=218 vs global=4.08, a 50× distortion). For cross-dataset comparison ALWAYS use the global ratio; the per-MEM mean is only useful as a distribution-shape proxy. Older find_mems builds only printed the per-MEM mean (labeled "Average n/r ratio").
- **`build_tags` k-mer arg is `-k K`**, not positional. The legacy `final_output2` script passed it positionally; the current binary silently ignores trailing args.
- **macOS `/usr/bin/time -l`** fails on some hosts with `sysctl kern.clockrate: Operation not permitted` and always exits 1. `build_index.sh` and `query.sh` auto-detect and prefer `gtime` (brew install gnu-time) which is reliable. Without either, RSS metrics will be 0 in the summary but the pipeline still runs.
- **GAF set-equality (not just validate_gaf percentage) is the first thing to check after any find_mems/gafpack change.** `validate_gaf_v2.py --sample N` counts how many *present* GAF rows are valid; it cannot detect silently *dropped* rows. v2 plan iteration 0 had this exact bug — 100% validate but 1.4M missing rows. Always run `diff <(sort old.gaf) <(sort new.gaf) | wc -l` against a known-good baseline before declaring success.

## Quick triage when validation fails
1. `compare.sh` — confirm `.seq/.rl_bwt/.tags/.paths` are IDENTICAL and `.gaf` is SET-EQUAL to a known-good ref. If index files differ, the input or steps 2–5 changed.
2. Rerun `find_mems` with `--tsv`, then spot-check: pick a node that lives on exactly one GFA path; for each seq_id block in `_seq_id_starts.out`, scan `_path_pos.tsv` rows in that range for the node — it should appear under exactly 2 seq_ids (`2×path_idx` and `2×path_idx+1`). More than 2 ⇒ tag/locate desync.
3. Check `convert_tags` log: `bwt_intervals size` must equal `.seq` size + 1.
4. `git -C <pangenome-index-latest> log -1` — record the commit in FINDINGS.

## Do not
- Edit `pangenome-index-latest/` source from here. Record bugs in `runs/<tag>/FINDINGS.md` instead.
- Delete `runs/<tag>/` without checking for a `FINDINGS.md` — that's the durable record.
