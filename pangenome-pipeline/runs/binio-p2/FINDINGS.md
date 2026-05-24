# Phase 2: binary `_path_pos.bin` handoff (find_mems + gafpack)

Branches: `find-mems-binary-io` in both `pangenome-index-latest` and `gafpack`.

## Correctness
- `.gaf` **md5-identical** to Phase 1 (`b2807d832513247a27adf6dcd0901a34`) — stronger than the sorted-line-set gate. ✅
- `_seq_id_starts.out` md5-identical to baseline. ✅
- `_path_pos.bin`: 118,910,184 B = 4,954,591 × 24 (record count matches Phase 1 TSV line count). ✅
- validate_gaf: 1997/2000 — the 3 invalids are pre-existing path-mismatch entries (902 known in baseline); p1's random 2000-sample hit 0, p2's hit 3, on the **same** .gaf file. Not a regression.

## Performance (yeast235-chrII, 100k reads)
| step         | baseline (05-03) | Phase 1 (TSV) | Phase 2 (.bin) | Δ vs baseline |
|--------------|------------------|---------------|----------------|---------------|
| 09_find_mems | 32s / 1131MB     | 30s / 842MB   | 27s / 786MB    | **−16% / −31%** |
| 10_gafpack   | 149s / 90MB      | 170s / 99MB   | 117s / 202MB   | **−21% / +112MB** |
| 09+10        | 181s             | 200s          | 144s           | **−20%** |

gafpack RSS +112MB = `.bin` loaded into memory (`std::fs::read` + `cast_slice`); expected trade.
gafpack wall-time win = eliminated per-seq_id file reopen + `read_until` line-skip (was quadratic in entry count).

## Files changed
- `pangenome-index-latest/src/find_mems.cpp`: `PackedEntry`/`BinRecord`, in-memory accumulate, bucket sort, `.bin` write, `--tsv` flag; dropped `_tmp.tsv` + `sort_mem_output_by_seq_node`.
- `gafpack/Cargo.toml`: `+bytemuck`.
- `gafpack/src/main.rs`: `Record` struct, `walk_gfa` reads `.bin` once, `process_path_matches` slices `&[Record]`.
- `mem-projection/pangenome-pipeline/run.sh`: step 09 guard + step 10 `--path-pos` → `.bin`.
