# pangenome-pipeline

Reproducible, profiled runs of the `pangenome-index` → `gafpack` → `validate_gaf` workflow.

## Quick start

```bash
# Build the index once per dataset (slow: hours on HPRC scale)
./build_index.sh yeast235-chrII-normalized.env [index-tag]   # → runs/<index-tag>/

# Query the index (fast: minutes), once per reads set
./query.sh yeast235-chrII-normalized.env <index-tag> [query-name]
                                                             # → runs/<index-tag>/queries/<query-name>/

# Compare a query's outputs against a reference
./compare.sh yeast235-chrII-normalized.env <index-tag> <query-name> [ref-query-dir]
```

Both scripts use `[ -f <output> ]` resume guards — re-running skips any step
whose output exists. Delete an output to force its step.

See `BUILD_QUERY_LAYOUT.md` for the full directory layout and config contract.

## Layout

```
configs/<name>.env                 inputs ($GBZ, $READS), params, reference dir
build_index.sh                     steps 01–08b (gbz_stats → ... → build_lightweight_tags)
query.sh                           steps 09–11 (find_mems → gafpack → validate_gaf)
compare.sh                         md5/size + set-equality diff vs a reference query
bootstrap_vesuvio.sh               per-user install of all deps on a fresh Linux host
BUILD_QUERY_LAYOUT.md              full directory + config contract documentation
vesuvio-build-issues.md            field notes on porting to Guix-on-Debian
CLAUDE.md                          agent guide: pipeline shape, correctness contract, footguns
runs/<index-tag>/                  one dir per index build
  RUN_INFO.txt                     host, date, config, pangenome-index commit
  config.env -> ...                symlink to the config used for the build
  logs/                            01..08b *.log/*.time + timing_summary.txt
  <BASE>.{seq,rl_bwt,ri,tags,_compressed.tags,ltags,paths,gfa}    index artifacts
  queries/<query-name>/            one subdir per query.sh invocation
    RUN_INFO.txt                   query provenance + index file mtimes
    config.env -> ...              symlink to the query config
    reads -> ...                   symlink to the reads file
    logs/                          09..11 *.log/*.time + timing_summary.txt
    mems_path_pos_v2.bin           find_mems output (step 09)
    mems_seq_id_starts.out
    alignment.gaf                  gafpack output (step 10)
    alignment_coverage.csv
  FINDINGS.md                      hand-written analysis (when there is one)
perf/                              performance characterization
  perf_harness.sh                  N-trial timed harness; --compare-v1 for A/B
  perf_lite_harness.sh             lite-pipeline phase breakdown harness
  summarize.py                     mean ± σ aggregator over perf/<tag>/{v1,v2}/trial-*/
  <tag>/                           per-tag trial data + SUMMARY.tsv + FINDINGS_PERF.md
PLAN_find_mems_binary_io_v2.md     canonical record-format spec + correctness gates
PLAN_find_mems_binary_io.md        v1 spec (superseded; historical)
```

## Performance profiling

Run against a pre-built index (use `INDEX_DIR` to point at one):

```bash
./perf/perf_harness.sh yeast235-chrII-normalized.env 3              # v2-only, 3 trials
./perf/perf_harness.sh yeast235-chrII-normalized.env 5 --compare-v1 # v1 vs v2 A/B
python3 perf/summarize.py perf/<tag>                                # aggregate
```

The harness requires `runs/<INDEX_DIR>/${BASE}.{ri,ltags,paths,gfa}` from
`build_index.sh`. Defaults `INDEX_DIR=runs/v1-current/`.

## Adding a dataset

Copy `configs/yeast235-chrII-normalized.env`, set `GBZ`, `BASE`, `READS`, and the
pipeline parameters (`KMER`, `MEM_LEN`, `MIN_OCC`, `THREADS`, `VALIDATE_SAMPLE`).
Optionally set `REF_DIR` for `compare.sh`. `GFA` is deprecated (derived in
step 01b) and `OUT` is obsolete (per-query subdir name replaces it).

## Correctness

A query passes iff step 11 (`validate_gaf_v2.py`) reports ≥99.9% valid on
the random sample. Index files won't byte-match `final_output2/` because
that was built pre-refactor — see `CLAUDE.md` for the full validation
contract and known footguns (notably `convert_tags --num-seq`).
