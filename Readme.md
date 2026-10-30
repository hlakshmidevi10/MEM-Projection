# MEM Projection

A BWT-based projection pipeline for mapping sequencing reads to pangenome graphs via maximal exact matches, enabling efficient graph-based read mapping and genotyping.

---

## Overview

This pipeline implements a BWT-based projection approach for mapping sequencing reads to pangenome graphs, designed to support downstream graph-based genotyping applications.

### The MEM-Projection Approach

The core methodology identifies **Maximal Exact Matches (MEMs)** between sequencing reads and the pangenome sequence using a full-text index optimized for MEM queries. These matches are then efficiently projected from the linear sequence space onto the graph structure through an auxiliary mapping that links index coordinates (text positions/intervals) to graph coordinates.

### Technical Implementation

The pipeline extends and integrates several core components:

- **r-index**: Full-text index based on the run-length encoded Burrows-Wheeler Transform (RLBWT) for efficient MEM finding
- **Tag-index**: Auxiliary mapping structure that connects BWT positions to graph coordinates
- **path-walker**: Parallel path walker that computes node coverage (and optionally GAF) from match positions

### Workflow Summary

1. **Index Building**: Create RLBWT and r-index from lossless sequence space
2. **Tag Mapping**: Construct auxiliary structure linking BWT coordinates to graph positions
3. **MEM Finding**: Query reads against the r-index to identify maximal exact matches
4. **Graph Projection**: Map MEMs to graph coordinates using the tag index
5. **Coverage Computation**: Calculate node-level coverage for genotyping

Steps 1–2 are `build_index.sh`; steps 3–5 are `query.sh`. The input graph comes from a pangenome graph builder such as PGGB or Minigraph-Cactus.

---

## Installation

### Requirements

A C++17 compiler with OpenMP, CMake, Make, pkg-config, git, curl, Rust (cargo), and the OpenSSL, zstd and zlib development headers.

**macOS**:
```bash
brew install llvm@17 libomp cmake zstd zlib openssl@3 pkg-config rust
```

**Linux (Debian/Ubuntu)**:
```bash
sudo apt install build-essential cmake pkg-config libssl-dev libzstd-dev zlib1g-dev cargo git curl
```

On a server without root, these are usually available as modules or from your admin.

### Install

```bash
git clone https://github.com/hlakshmidevi10/MEM-Projection.git
cd MEM-Projection
./install.sh                         # installs into ~/.mem-projection
source ~/.mem-projection/env.sh      # add this line to ~/.bashrc
```

`install.sh` builds every dependency at a pinned commit into one directory (`./install.sh /some/prefix` to choose another). If a requirement is missing it stops and says what to install. Re-running it resumes where it stopped.

On macOS, vg has no release binary, so `build_index.sh` is not available; querying works.

---

## Building an Index

```bash
./build_index.sh -g graph.gbz -o my_index/ -t 16
```

| Option | |
|---|---|
| `-g` | Graph as `.gbz`, or `.gfa` with PanSN path names (`sample#hap#contig`) |
| `-o` | Output directory |
| `-t` | Threads (default 8) |
| `--tmp DIR` | Temporary directory for the BWT construction (default inside `-o`, must be on the same filesystem) |
| `--keep-intermediates` | Keep the sequence, BWT and full tag files |

The index is `my_index/graph.{ri,ltags,paths,gfa}`, with `index.info` and per-step logs in `logs/`. Re-running the same command resumes from the last completed step.

The build checks before it starts that there is enough free disk and that no node is longer than 1024 bp. A GFA input is converted with `gfa2gbwt -m 1024`, which splits longer nodes.

---

## Querying

```bash
./query.sh -i my_index/ -r reads.fq.gz -o sample_out/ -t 16
```

| Option | |
|---|---|
| `-i` | Index directory from `build_index.sh` |
| `-r` | Reads as FASTQ, FASTA or one sequence per line; optionally gzipped |
| `-o` | Output directory |
| `-l` | Minimum MEM length (default 25) |
| `-t` | Threads (default 8) |
| `--gaf` | Also write `mem.gaf` |
| `--validate` | Check `mem.gaf` against the reads and the graph (implies `--gaf`; needs `pip install gaftools==1.3.0`) |

### Output

| File | |
|---|---|
| `mem_coverage.csv` | `node_id,node_coverage`, one row per graph node: bases of the node covered by MEMs. Node IDs match `my_index/graph.gfa` |
| `mem.gaf` | With `--gaf`: one row per MEM placement (`read_id read_st path_str path_len path_st path_end match_len path_name`) |
| `run.info` | Index, reads, settings and tool versions |
| `logs/` | `find_mems` and `path-walker` logs |

---

## Repository Layout

```
install.sh            build the dependencies
build_index.sh        graph -> index
query.sh              reads + index -> node coverage
scripts/              GAF validation and coverage plotting helpers
pangenome-pipeline/   research drivers, configs and benchmarks used to develop the pipeline
```

---

## Dependencies

Installed by `install.sh` at the commits listed in it:

- **[pangenome-index](https://github.com/hlakshmidevi10/pangenome-index-pvt)** - r-index, tag arrays and `find_mems`
- **[path-walker](https://github.com/hlakshmidevi10/path-walker)** - MEM placements to node coverage and GAF
- **[vg](https://github.com/vgteam/vg)** - writes the graph's GFA from the GBZ
- **[GBWTGraph](https://github.com/jltsiren/gbwtgraph)**, **[GBWT](https://github.com/jltsiren/gbwt)**, **[HandleGraph](https://github.com/vgteam/libhandlegraph)**, **[SDSL](https://github.com/vgteam/sdsl-lite)**, **[grlBWT](https://github.com/ddiazdom/grlBWT)**
