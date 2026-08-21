# Config index — pick the right `.env` before you run anything

`build_index.sh` and `query.sh` both take a config as their first argument.
Picking the wrong one costs you a full pipeline run; picking a **broken** one
fails instantly with `ERROR: READS file not found`. This file exists so you
don't have to find that out empirically.

**Rule of thumb: use the config named exactly after the dataset** —
`hprcv1-chr6.env`, `hprcv1-chr1.env`, `yeast235-chrII-normalized.env`. Those
are the defaults. Reach for a suffixed variant only when you need its specific
read set or `MEM_LEN`.

`MEM_LEN` is a **query-time** knob — you can vary it freely against one built
index. `KMER` is **build-time**; changing it means rebuilding.

---

## HPRC v1 chr6 — index tag `hprc-chr6-2026-06-02`

| Config | Reads | `MEM_LEN` | Use for |
|---|---|---:|---|
| **`hprcv1-chr6.env`** | alt-noisy | **25** | **default** |
| `hprcv1-chr6-alt-reads.env` | alt-noisy | 50 | reproducing the historical baselines (see gates below) |
| `hprcv1-chr6-alt-reads-L25.env` | alt-noisy | 25 | identical to the default; kept because JR-019 cites this path |
| `hprcv1-chr6-alt-reads-clean.env` | alt (clean) | 50 | clean-vs-noisy comparisons |
| `hprcv1-chr6-alt-noisy.env` | alt-noisy | 30 | |
| `hprcv1-chr6-hg002-noisy-L25.env` | HG002 noisy | 25 | out-of-graph reads |
| `hprcv1-chr6-hg002-clean-L25.env` | HG002 clean | 25 | out-of-graph reads |
| `hprcv1-chr6-hg002-noisy-reads.env` | HG002 noisy | 50 | out-of-graph reads |
| `hprcv1-chr6-ref-reads.env` | reference | 50 | |

"alt-noisy" = `hprcv1/chr6.alt_noisy.reads.txt`, 100K × 200bp from
`HG00438#2#JAHBCA010000010.1#0`. This is the workload nearly every chr6 number
in `RESEARCH_JOURNAL.md` is measured on.

## HPRC v1 chr1 — index tag `hprcv1-chr1-2026-08-12`

| Config | Reads | `MEM_LEN` | Use for |
|---|---|---:|---|
| `hprcv1-chr1-hg00097-noisy-L25.env` | HG00097 noisy | 25 | **the working chr1 query config** |
| `hprcv1-chr1-alt-noisy-L25.env` | alt-noisy | 25 | |
| `hprcv1-chr1.env` | — | — | ⚠️ build-only; `READS` unset (see Broken below) |

## Yeast-235 chrII — index tag `vesuvio-smoke`

| Config | Reads | `MEM_LEN` | Use for |
|---|---|---:|---|
| **`yeast235-chrII-normalized.env`** | S288C chrII | **30** | **default**; fastest end-to-end smoke test |
| `yeast235-chrII-normalized-alt-noisy.env` | alt-noisy | 30 | |
| `yeast235-chrII-normalized-m0.env` | S288C chrII | 30 | ⚠️ `GBZ` missing |

## HPRC v2

`hprcv2-chr6.env`, `hprcv2-chr6-alt-noisy-500k.env`, `hprcv2-mc-chr6.env`
(L=25) and `hprcv1-mc-chr6.env` all resolve. See Broken below for the rest.

---

## Known-good coverage gates

The strongest correctness check in this pipeline is **byte-identity of
`alignment_coverage.csv`** — those are the exact bytes cosigt consumes, so
matching them means downstream genotyping cannot tell two runs apart. It is a
much stronger signal than `validate_gaf`'s 2000-entry sample, which cannot
detect silently *dropped* rows.

| Dataset | Config | `MEM_LEN` | Coverage MD5 |
|---|---|---:|---|
| chr6 alt-noisy | `hprcv1-chr6-alt-reads.env` | 50 | `60f6b8e4a759aebb252b83a870b9ff8c` |
| chr6 clean | `hprcv1-chr6-alt-reads-clean.env` | 50 | `8c242732c837d697fb18c52fd0c0cf6e` |
| chr1 HG00097-noisy (flipped) | `hprcv1-chr1-hg00097-noisy-L25.env` | 25 | `9197ee230c283e816e6119f16feb2f8b` |
| yeast normalized | `yeast235-chrII-normalized.env` | 30 | `1baf368f3cdc59890f88410cc34cc051` |

The chr6-L50, chr1 and yeast rows were re-verified on 2026-08-21 (all with
`validate_gaf` 2000/2000). The chr6-clean row is carried from JR-013/JR-014 and
has not been re-checked since. **No L=25 coverage baseline exists for chr6
yet** — record one the first time you run the default.

Legacy and flipped MEM finders produce byte-identical coverage (JR-007), so
these gates hold with or without `--use-flipped-mems`.

### ⚠️ Trap: stale on-disk baselines

Do **not** assume a coverage file sitting in `runs/<tag>/queries/<q>/` is a
valid target — some predate bug fixes that legitimately changed output. The
known example: yeast's stored `db4ba02af811e72df2790db064b152b9` is the
*pre-Risk-E-fix* result (JR-007's `stage3-flag-off`). Comparing a correct
modern run against it reports a false failure. The correct current value is
`1baf368f…` above. Always check the provenance of a baseline before trusting
it, and prefer the table above.

---

### ⚠️ Trap: the yeast-235 path differs per machine

The yeast configs are **not portable between vesuvio and a dev Mac**, because
the same data lives under a differently-named parent directory on each:

| Host | Directory | Reads |
|---|---|---|
| vesuvio | `yeast-235/yeast-235-chrI/` | `yeast-235-chrI/S288C_chrII_N100K_R1_200_reads.txt` |
| dev Mac | `yeast-235/yeast-235-chrII/` | `yeast-235-chrII/S288C_chrII_N100K_R1_200_reads.txt` |

The contents are chrII on both — vesuvio's directory is simply misnamed. The
committed configs use the **vesuvio (`chrI`) spelling**, since vesuvio is the
canonical benchmarking host; a Mac checkout needs them pointed at `chrII`
locally and those edits must **not** be committed, or vesuvio breaks.

Note this also means prose in `pangenome-index-pvt` that cites a yeast reads
path (`DESIGN_FLIPPED_MEM.md`, `RESEARCH_JOURNAL.md` command examples) is
describing whichever machine its author was on. Treat those paths as
illustrative, not authoritative — resolve against the host you're actually on.
The durable fix is to rename vesuvio's directory to `chrII` and update the
configs in one commit; until someone does that, this divergence stands.

## ⚠️ Broken configs (validated on vesuvio, 2026-08-21)

`READS` missing → `query.sh` fails immediately:

- `hprcv1-chr1.env` — also has no `MEM_LEN`; build-only, not usable for queries
- `hprcv2-chr18.env`
- `hprcv2-chr20.env` — `GBZ` missing too

`GBZ` missing → `build_index.sh` fails; `query.sh` still works, since GBZ is
only carried for provenance at query time:

- `hprcv2-chr6-raw.env`
- `hprcv2-mc-chr6-normalized.env`
- `yeast235-chrII-normalized-m0.env`

`hprcv1-chr6.env` was in the first list until 2026-08-21 — it was an unconverted
`.env.example` whose `READS` was a literal `TODO` placeholder
(`hprcv1/chr6.reads.txt`, a file that never existed). JR-018 and JR-019 both
cite it as the L=50 query config; that role now belongs to
`hprcv1-chr6-alt-reads.env`.

### Re-run the validation sweep

Don't trust the list above indefinitely — regenerate it:

```bash
cd mem-projection/pangenome-pipeline/configs
export MEM_PROJ=$HOME/mem-projection
for f in *.env; do
  r=$(bash -c "source ./$f >/dev/null 2>&1; echo \$READS")
  g=$(bash -c "source ./$f >/dev/null 2>&1; echo \$GBZ")
  [ -n "$r" ] && [ -f "$r" ] && rs=OK || rs=MISSING
  [ -n "$g" ] && [ -f "$g" ] && gs=OK || gs=MISSING
  printf "%-42s READS=%-8s GBZ=%s\n" "$f" "$rs" "$gs"
done
```
