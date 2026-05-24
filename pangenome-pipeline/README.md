# pangenome-pipeline

Reproducible, profiled runs of the `pangenome-index` → `gafpack` → `validate_gaf` workflow.

## Quick start

```bash
./run.sh yeast235-chrII-normalized.env [tag]      # build + query + validate → runs/<tag>/
./compare.sh yeast235-chrII-normalized.env <tag>  # md5/size diff vs reference
```

Re-running the same tag resumes — each step skips if its output file already exists. Delete an output to force that step.

## Layout

```
configs/<name>.env     inputs (GBZ/GFA/READS), params, reference dir
runs/<tag>/            all artifacts for one execution
  RUN_INFO.txt         host, date, config, pangenome-index + gafpack commits
  config.env           symlink to the config used
  logs/                NN_*.log + NN_*.time + timing_summary.txt
  FINDINGS.md          hand-written analysis (when there is one)
  <BASE>.*             index files
  <OUT>_*, <OUT>.gaf   find_mems / gafpack outputs (incl. _path_pos_v2.bin)
perf/                  performance characterization
  perf_harness.sh      N-trial timed harness (warm cache); --compare-v1 for A/B
  summarize.py         mean ± σ aggregator over perf/<tag>/{v1,v2}/trial-*/
  <tag>/               per-tag trial data + SUMMARY.tsv + FINDINGS_PERF.md
PLAN_find_mems_binary_io_v2.md  canonical record-format spec + correctness gates
PLAN_find_mems_binary_io.md     v1 spec (superseded; historical)
CLAUDE.md              agent guide: pipeline shape, correctness contract, footguns
```

## Performance profiling

```bash
./perf/perf_harness.sh yeast235-chrII-normalized.env 3              # v2-only, 3 trials
./perf/perf_harness.sh yeast235-chrII-normalized.env 5 --compare-v1 # v1 vs v2 A/B
python3 perf/summarize.py perf/<tag>                                # aggregate
```

The harness requires pre-built indexes in `runs/<INDEX_DIR>/` (defaults to `runs/v1-current/`); steps 02–07 are not re-run.

## Adding a dataset

Copy `configs/yeast235-chrII-normalized.env`, set `GBZ/GFA/READS/BASE/OUT`, optionally `REF_DIR`.

## Correctness

A run passes iff step 11 (`validate_gaf_v2.py`) reports ≥99.9% valid on the random sample. Index files won't byte-match `final_output2/` because that was built pre-refactor — see `CLAUDE.md` for the full validation contract and known footguns (notably `convert_tags --num-seq`).
