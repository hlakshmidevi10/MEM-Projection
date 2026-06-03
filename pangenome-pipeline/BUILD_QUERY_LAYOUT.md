# BUILD_QUERY_LAYOUT

The pipeline is split into two scripts so the expensive **index build** is
separated from the cheap **per-query projection**:

```
build_index.sh <config.env> <index-tag>                    → runs/<index-tag>/
query.sh       <config.env> <index-tag> [query-name]       → runs/<index-tag>/queries/<query-name>/
                                                             (coverage-only mode, prod-fast)
query.sh       <config.env> <index-tag> [query-name] --gaf → same + alignment.gaf + validate_gaf
                                                             (test mode, includes step 11)
```

Multiple queries can run against the same index without colliding outputs.
This document captures the directory layout, config contract, and migration
notes from the old `run.sh` flat layout.

## Query modes: coverage-only vs --gaf

`query.sh` defaults to **coverage-only** mode: gafpack runs with
`--coverage-prefix` and produces only `alignment_coverage.csv`. No `.gaf`
is generated; `validate_gaf_v2.py` (step 11) does not run. This matches the
production deployment pattern — the coverage CSV is the only artifact that
downstream consumers need.

Pass `--gaf` to additionally:
1. Have gafpack write `alignment.gaf` (~10× larger than the coverage CSV)
2. Run step 11 (`validate_gaf_v2.py`) to spot-check projection correctness

`--gaf` is useful for:
- First-run validation on a new dataset (confirm pipeline correctness end-to-end)
- Debugging mis-projection symptoms
- Producing the GAF for tools downstream of gafpack that consume alignments

Re-running a query that completed in coverage-only mode with `--gaf` re-runs
step 10 (cheap — gafpack is fast) to produce the GAF, then runs step 11.
Re-running with `--gaf` after a previous `--gaf` run is a no-op (both
existence guards pass).

---

## Directory layout

```
runs/<index-tag>/                            ← built by build_index.sh
├── RUN_INFO.txt                             host, date, config, git commits
├── config.env -> ../../configs/<file>.env   symlink for traceability
├── logs/
│   ├── 01_gbz_stats.{log,time}              per-step logs + GNU-time profiling
│   ├── 01b_derive_gfa.time
│   ├── 02_gbz_extract.time
│   ├── 03_grlbwt.{log,time}
│   ├── 04_build_rindex.time
│   ├── 05_build_tags.{log,time}
│   ├── 06_convert_tags.{log,time}
│   ├── 07_path_extract.{log,time}
│   ├── 08_print_stats.{log,time}
│   ├── 08b_build_lightweight_tags.{log,time}
│   └── timing_summary.txt                   rebuilt from *.time at end
├── <BASE>.seq                               step 02 (huge: ~10× GBZ size)
├── <BASE>.rl_bwt                            step 03
├── <BASE>.ri                                step 04
├── <BASE>.tags                              step 05
├── <BASE>_compressed.tags                   step 06
├── <BASE>.ltags                             step 08b (consumed by find_mems)
├── <BASE>.paths                             step 07 (one path name per line)
├── <BASE>.gfa                               step 01b (DERIVED from GBZ)
└── queries/                                 ← created by query.sh runs
    ├── <query-name-1>/
    │   ├── RUN_INFO.txt                     query provenance + mode + index
    │   │                                    file mtimes (so future-you can spot
    │   │                                    if the index was rebuilt since)
    │   ├── config.env -> ../../../../configs/<file>.env
    │   ├── reads -> /path/to/reads.txt      symlink to the source reads
    │   ├── logs/
    │   │   ├── 09_find_mems.{log,time}
    │   │   ├── 10_gafpack.{log,time}
    │   │   ├── 11_validate_gaf.{log,time}   only present with --gaf
    │   │   └── timing_summary.txt
    │   ├── mems_path_pos_v2.bin             find_mems binary output (step 09)
    │   ├── mems_seq_id_starts.out           find_mems sidecar (step 09)
    │   ├── alignment_coverage.csv           gafpack per-node coverage (step 10)
    │   └── alignment.gaf                    only present with --gaf
    ├── <query-name-2>/                      another query, same layout
    └── ...
```

### Why this layout

- **Per-query subdirs** prevent log overwrites when multiple queries run
  against the same index. Each query's `logs/09_find_mems.{log,time}` is
  preserved independently — the old flat layout lost the ref-reads logs the
  moment the alt-reads run started.
- **Clean filenames inside subdirs** (`alignment.gaf` not
  `hprcv1_chr6_ref_reads.gaf`) because the dir name already disambiguates.
- **Shared index files** at the parent dir level mean only ONE copy of the
  multi-GB `.seq`, `.ri`, `.tags`, `.ltags` is on disk, regardless of how many
  queries reference them.
- **RUN_INFO.txt at both levels** records what was built / queried when, with
  git commits of the upstream tools for reproducibility.

---

## Config contract

A config (`configs/*.env`) is a bash file sourced by the scripts. Required
variables depend on which script you're running:

| Variable | `build_index.sh` | `query.sh` | Description |
|---|---|---|---|
| `GBZ` | **required** | ignored (index already built) | Input pangenome GBZ |
| `BASE` | **required** | **required** | Index file prefix (`<BASE>.ri`, `<BASE>.ltags`, etc.) |
| `KMER` | **required** | ignored | `build_tags -k` argument |
| `THREADS` | **required** | ignored | grlbwt/gbz_extract parallelism |
| `READS` | ignored (warns) | **required** | Reads file (one sequence per line) |
| `MEM_LEN` | ignored | **required** | `find_mems` minimum MEM length |
| `MIN_OCC` | ignored | **required** | `find_mems` minimum occurrence count |
| `VALIDATE_SAMPLE` | ignored | required only with `--gaf` | `validate_gaf_v2.py --sample` size |
| `GFA` | ignored (warns) | ignored | DEPRECATED — pipeline derives it from `$GBZ` |
| `OUT` | ignored (warns) | ignored | DEPRECATED — per-query subdir name replaces it |

`OUT` and `GFA` are accepted-but-warned for backwards-compat with old configs.
New configs should omit them.

### Sharing a config across build + query

A single config can drive both `build_index.sh` and `query.sh`. The unused
variables on each side are warned-about (so you know you set something
irrelevant) but not fatal. Common patterns:

- **Single config, full pipeline**: set all variables; run `build_index.sh`
  then `query.sh` with the same config.
- **Index config + per-query configs**: one config with `GBZ/BASE/KMER/THREADS`
  for the build; multiple smaller configs with `BASE/READS/MEM_LEN/MIN_OCC/
  VALIDATE_SAMPLE` for each query.

### Example: querying one index with multiple reads sets

```bash
# Build once
./build_index.sh hprcv1-chr6.env hprc-chr6-2026-06-02

# Coverage-only queries (prod-fast — no .gaf, no validate)
./query.sh hprcv1-chr6-ref-reads.env       hprc-chr6-2026-06-02
./query.sh hprcv1-chr6-alt-reads.env       hprc-chr6-2026-06-02
./query.sh hprcv1-chr6-alt-noisy-reads.env hprc-chr6-2026-06-02

# Validate a query end-to-end (slower; includes step 11)
./query.sh hprcv1-chr6-ref-reads.env hprc-chr6-2026-06-02 --gaf

# Final layout (coverage-only mode for all three):
#   runs/hprc-chr6-2026-06-02/
#   ├── <index files + logs>
#   └── queries/
#       ├── ref-reads/
#       │   ├── mems_*, alignment_coverage.csv     ← always present
#       │   └── alignment.gaf, logs/11_*           ← only with --gaf
#       ├── alt-reads/
#       └── alt-noisy-reads/
```

### Default query-name derivation

If you don't pass a third arg to `query.sh`, the query name is the config's
filename with `.env` stripped and any leading `<dataset>-` prefix removed.
Examples:

| Config | Default query name |
|---|---|
| `hprcv1-chr6-ref-reads.env` | `ref-reads` |
| `hprcv1-chr6-alt-noisy-reads.env` | `alt-noisy-reads` |
| `yeast235-chrII-normalized.env` | `normalized` |

Override by passing a third arg if defaults would collide:

```bash
./query.sh hprcv1-chr6-ref-reads.env hprc-chr6-2026-06-02 ref-reads-rerun-2
```

---

## Resume + idempotency

Both scripts use `[ -f <output> ]` guards. Re-running the same `<index-tag>`
or `<query-name>` skips any step whose output exists. To force a step:

```bash
# Force rebuild of step 05 (build_tags) — and everything downstream
cd runs/<index-tag>
rm <BASE>.tags <BASE>_compressed.tags <BASE>.ltags
cd ../..
./build_index.sh <config> <index-tag>

# Force re-run of an entire query
rm -rf runs/<index-tag>/queries/<query-name>
./query.sh <config> <index-tag> <query-name>
```

---

## Provenance / "did the index change since this query ran?"

`query.sh` writes the mtime + size of each index file it consumed into the
query's `RUN_INFO.txt`. If you later rebuild the index, comparing the index
file mtimes against any older `runs/<tag>/queries/*/RUN_INFO.txt` shows you
which queries are now stale.

Quick check:

```bash
# All queries' index-provenance lines
grep -A8 'Index file provenance' runs/<index-tag>/queries/*/RUN_INFO.txt
```

---

## Migration from `run.sh` (the pre-split layout)

The old `run.sh` produced everything flat in `runs/<tag>/`:

```
runs/<tag>/
├── <BASE>.{seq,rl_bwt,ri,tags,_compressed.tags,ltags,paths,gfa}
├── <OUT>_path_pos_v2.bin
├── <OUT>_seq_id_starts.out
├── <OUT>.gaf
├── <OUT>_coverage.csv
└── logs/...                  ← OVERWRITTEN by each successive `run.sh` call
```

To migrate an existing `runs/<tag>/` to the new layout:

```bash
cd runs/<tag>
mkdir -p queries/<query-name>/logs

# Move query outputs into the subdir, dropping the OUT prefix
mv <OUT>_path_pos_v2.bin   queries/<query-name>/mems_path_pos_v2.bin
mv <OUT>_seq_id_starts.out queries/<query-name>/mems_seq_id_starts.out
mv <OUT>.gaf               queries/<query-name>/alignment.gaf
mv <OUT>_coverage.csv      queries/<query-name>/alignment_coverage.csv

# Move query-side logs (09, 10, 11)
for stem in 09_find_mems 10_gafpack 11_validate_gaf; do
    mv logs/${stem}.{log,time} queries/<query-name>/logs/ 2>/dev/null
done
```

If you have multiple queries' worth of data sharing one flat dir, only the
LAST query's logs are still there (the others were overwritten when `run.sh`
re-ran). The output files for earlier queries are preserved (their `<OUT>`
prefixes differ). Reconstruct the missing logs from any saved analysis or
conversation transcripts, or just note them as missing.

---

## What `run.sh` did and where it went

`run.sh` is removed. Its responsibilities split as follows:

| `run.sh` did | Now in |
|---|---|
| Steps 01–08b (index build) | `build_index.sh` |
| Steps 09–11 (query + validate) | `query.sh` |
| Conditional index-only mode (`if [ -z "$READS" ]`) | `build_index.sh` always does only index work |
| Resume logic, profiling helpers, GNU-time detection | duplicated in both (single source of truth would be a future refactor) |

For the full debugging history of `run.sh`'s behavior, see git log
on `vesuvio-bootstrap` and earlier branches.
