# mac-setup-guide

Field notes for standing up the `pangenome-pipeline` end-to-end on a fresh
macOS host. Companion to `vesuvio-build-issues.md`, which does the same for
Linux/Guix. **Different environments, different hurdles** — the pipeline
source is identical, everything around it is not.

This document exists so a future agent (or human) can (a) reproduce the
working Mac setup deterministically, (b) understand *why* each step is the
way it is, and (c) write a `bootstrap_macos.sh` from it if desired. It
mirrors the structure of `vesuvio-build-issues.md`: what's the environment,
what are the hurdles, what's the fix.

**Assumed starting state:** macOS (arm64 tested; Intel should work), Xcode
Command Line Tools installed, Homebrew installed, nothing else. If those
are missing, start with:
```bash
xcode-select --install                    # Xcode CLT (native compilers, git, make)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

**Target reference:** working setup on macOS 26.5 (arm64), Homebrew at
`/opt/homebrew`, user `hlakshmidevi` with `$HOME = /Users/hlakshmidevi`.
End state described in "Layout after successful setup" at the bottom.

---

## Environment delta: Mac vs. vesuvio

The Mac is the *original* dev environment — vesuvio was the port. So this
table is the Mac column of `vesuvio-build-issues.md` inverted, plus a few
Mac-specific gotchas.

| Concept | Mac | Vesuvio (Linux) |
|---|---|---|
| Package manager | Homebrew (`/opt/homebrew` on arm64, `/usr/local` on Intel) | Guix (per-user, no sudo) |
| Compiler | Homebrew LLVM 17 (`clang++` from `llvm@17`) | Guix `gcc-toolchain` 15.2.0 |
| Why not Apple Clang? | Apple Clang doesn't ship `libomp` headers by default; the makefile detects Apple Clang and expects Homebrew `libomp` via `-Xpreprocessor -fopenmp` | libgomp built into gcc-toolchain |
| stdlib | libc++ (Homebrew LLVM) | libstdc++ (gcc 13+ pruned transitive includes) |
| Install prefix (`~/include`, `~/lib`) | Direct `cp -r` from each dep's source tree | Same layout, automated in `bootstrap_vesuvio.sh` |
| Runtime lib search | macOS `DYLD_*` finds `~/lib` reasonably well; no `LD_LIBRARY_PATH` needed | Linux dynamic loader needs `LD_LIBRARY_PATH=$HOME/lib` |
| Compiler env | Exported in `~/.zshrc` (`CC/CXX/CPPFLAGS/LDFLAGS/PKG_CONFIG_PATH`) | Guix `etc/profile` auto-manages `CPATH/LIBRARY_PATH/PKG_CONFIG_PATH` |
| Python | miniconda base env (Python 3.13) — gaftools installed via `pip install` | Guix python + venv (PEP 668) |
| CA certs | macOS Keychain (transparent to curl/cargo) | Requires `guix install nss-certs` |
| `gtime` | `brew install gnu-time` → `/opt/homebrew/bin/gtime` | `guix install time` → `~/.guix-profile/bin/time` |

**Mac-specific unpaper:** Homebrew keg-only formulas (`openssl`, `libomp`,
`llvm@17`, `zlib`, `zstd`, `protobuf@29`) don't put their `include`/`lib`
on the default compiler search path. You *must* set `CPPFLAGS`/`LDFLAGS`
or the build fails at link time. The `.zshrc` from a working setup does
this — see the "Shell env" section below.

The pipeline itself (`build_index.sh` + `query.sh`, the C++ binaries, the
configs) is byte-for-byte identical between hosts. Divergences are all in
the toolchain *around* the pipeline.

---

## Directory layout (target)

Everything under `~/personal/` for source repos, plus a shared install
prefix at `~/include` + `~/lib` (matches the vesuvio bootstrap's
`PREFIX=$HOME` decision — required by `deps/grlBWT/cmake/Modules/FindLibSDSL.cmake`
which hardcodes `$HOME/include` and `$HOME/lib`; see hurdle 5 in
`vesuvio-build-issues.md`).

```
~/
├── personal/
│   ├── sdsl-lite/                        # bit-packed data structures (vgteam fork)
│   ├── libhandlegraph/                   # handle-graph interface (vgteam)
│   ├── gbwt/                             # GBWT (jltsiren)
│   ├── gbwtgraph/                        # GBWTGraph + gbz_stats/gbz_extract/gfa2gbwt (jltsiren)
│   ├── grlBWT/                           # grlBWT + grlbwt-cli (ddiazdom fork)
│   ├── pangenome-index-latest/           # THIS repo — find_mems, build_tags, etc.
│   ├── gafpack/                          # Rust GAF/coverage tool
│   └── mem-projection/                   # pipeline driver (build_index.sh + query.sh + configs)
│       └── pangenome-pipeline/           # ← this guide lives here
├── include/                              # shared install prefix (PREFIX=$HOME)
│   ├── sdsl/, divsufsort*.h              # from sdsl-lite install.sh
│   ├── gbwt/                             # from gbwt manual cp -r
│   ├── gbwtgraph/                        # from gbwtgraph manual cp -r
│   └── handlegraph/                      # from libhandlegraph cmake install
├── lib/
│   ├── libsdsl.a, libdivsufsort{,64}.a   # from sdsl-lite install.sh
│   ├── libgbwt.a                         # from gbwt manual cp
│   ├── libgbwtgraph.a                    # from gbwtgraph manual cp
│   ├── libhandlegraph.{a,dylib}          # from libhandlegraph cmake install
│   ├── cmake/, pkgconfig/                # cmake finders / pc files
└── miniconda3/                           # (optional but recommended) hosts gaftools 1.3.0
```

Repos with private forks (URLs from the working Mac):

| Repo | Origin | Branch | HEAD (working Mac) |
|---|---|---|---|
| `pangenome-index-latest` | `https://github.com/hlakshmidevi10/pangenome-index-pvt` (private fork of `parsaeskandar/pangenome-index`) | `tag-head-samples` | `cce36bd` |
| `mem-projection` | `https://github.com/hlakshmidevi10/MEM-Projection.git` | `vesuvio-bootstrap` | `23f54c6` |
| `gafpack` | `https://github.com/hlakshmidevi10/gafpack-pvt.git` | `path-walker` | `87dffd3` |
| `sdsl-lite` | `https://github.com/vgteam/sdsl-lite.git` | `master` | `eb47fbd` |
| `libhandlegraph` | `https://github.com/vgteam/libhandlegraph.git` | `master` | `b95f763` |
| `gbwt` | `https://github.com/jltsiren/gbwt.git` | `master` | `9e92e4f` |
| `gbwtgraph` | `https://github.com/jltsiren/gbwtgraph.git` | `master` | `17dda01` |
| `grlBWT` (top-level, for `grlbwt-cli`) | `https://github.com/ddiazdom/grlBWT.git` | `main` | `dca13c4` |

**Submodule inside pangenome-index-latest:**
```
deps/grlBWT @ f09e7fa (v1.0.1-alpha-36-gf09e7fa)
```
Note this pins an OLDER grlBWT commit (`f09e7fa`) than the standalone top-level clone
(`dca13c4`). Both are needed: the submodule builds the embedded `libgrlbwt.a` linked
into pangenome-index binaries; the top-level clone builds the `grlbwt-cli` executable
used by `build_index.sh` step 03. Do not "consolidate" them — they diverge deliberately.

---

## Step-by-step setup (order matters)

### 0. Prereqs (Homebrew formulas)

The working Mac has exactly these Homebrew keg-only formulas installed and
referenced by `.zshrc` env vars:

```bash
brew install \
    llvm@17          `# clang++/clang, libc++ headers` \
    libomp           `# OpenMP runtime (Apple Clang lacks it)` \
    gnu-time         `# gtime -v; pipeline uses this` \
    zstd             `# .zst compression + link dep` \
    zlib             `# link dep` \
    openssl@3        `# link dep for pangenome-index makefile` \
    protobuf@29      `# link dep for the vg toolchain (older API)` \
    pkg-config       `# used by cmake to find libs` \
    cmake            `# libhandlegraph, grlBWT, embedded deps/grlBWT` \
    gnu-getopt       `# POSIX getopt (some scripts assume GNU behavior)` \
    rust             `# gafpack cargo build` \
    git              `# probably already present via Xcode CLT`
```

**On Apple Silicon**, `brew --prefix` returns `/opt/homebrew`. On Intel it's
`/usr/local`. The `.zshrc` uses `$(brew --prefix ${LLVM})` so it's
architecture-agnostic; hardcoded paths in this doc assume `/opt/homebrew`.

**Why `llvm@17` specifically:** the `sdsl-lite/Make.helper` file records
`MY_CXX=/opt/homebrew/opt/llvm@17/bin/clang++` at install time. If you use
a different LLVM version, either update `Make.helper` post-install or export
`MY_CXX`/`MY_CC` overrides. LLVM 17 is what the working Mac uses.

**Why `protobuf@29`:** the pangenome-index makefile inherits some vg
toolchain expectations that link protobuf. Newer protobuf (5.x) breaks the
API. Keep it pinned.

### 1. Shell env (`.zshrc` additions)

The critical env exports the makefile depends on. Add these to `~/.zshrc`
(or a sourced fragment) BEFORE any pipeline builds:

```bash
export LLVM=llvm@17

# Point clang/clang++ at Homebrew LLVM (Apple Clang doesn't have libomp)
export PATH="$(brew --prefix ${LLVM})/bin:$PATH"
export CC=$(brew --prefix ${LLVM})/bin/clang
export CXX=$(brew --prefix ${LLVM})/bin/clang++

# libomp + Homebrew LLVM linker paths
export LDFLAGS="-L$(brew --prefix libomp)/lib -L$(brew --prefix ${LLVM})/lib"
export CPPFLAGS="-I$(brew --prefix libomp)/include -I$(brew --prefix ${LLVM})/include"

# zlib (keg-only)
export CPPFLAGS="-I$(brew --prefix zlib)/include ${CPPFLAGS}"
export LDFLAGS="-L$(brew --prefix zlib)/lib ${LDFLAGS}"

# protobuf@29 (pinned)
export CPPFLAGS="-I/opt/homebrew/opt/protobuf@29/include ${CPPFLAGS}"
export LDFLAGS="-L/opt/homebrew/opt/protobuf@29/lib ${LDFLAGS}"

# zstd (keg-only)
export CPPFLAGS="-I$(brew --prefix zstd)/include ${CPPFLAGS}"
export LDFLAGS="-L$(brew --prefix zstd)/lib ${LDFLAGS}"

# Autotools uses CFLAGS not CPPFLAGS for -I; keep them synced
export CFLAGS="$CPPFLAGS"

# pkg-config search order (matters for cmake finders)
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:$PKG_CONFIG_PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/zlib/lib/pkgconfig:$PKG_CONFIG_PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/zstd/lib/pkgconfig:$PKG_CONFIG_PATH"
export PKG_CONFIG_PATH="/opt/homebrew/opt/protobuf@29/lib/pkgconfig:$PKG_CONFIG_PATH"

# --- PATH: pipeline binaries ---
# All four dirs have non-overlapping binary names, so order doesn't matter
# functionally. Match the working .zshrc verbatim for consistency.
# gafpack (Rust binary), gbz_stats/gbz_extract/gfa2gbwt (gbwtgraph),
# grlbwt-cli (grlBWT), find_mems / build_tags / convert_tags / ... (pangenome-index)
export PATH=$HOME/personal/gafpack/target/release:$PATH
export PATH=$HOME/personal/gbwtgraph/bin:$PATH
export PATH=$HOME/personal/grlBWT/build:$PATH
export PATH=$HOME/personal/pangenome-index-latest/bin:$PATH
```

**Not needed on Mac** (unlike vesuvio):
- `LD_LIBRARY_PATH` — macOS `DYLD_LIBRARY_PATH` semantics + install-time
  rpaths generally cover this. If you get "cannot load library" errors,
  set `DYLD_LIBRARY_PATH=$HOME/lib` as a fallback.
- `~/.pangenome_env.sh` — that's the vesuvio bootstrap's persistent env
  file. On Mac, `.zshrc` does the same job.

Also handy but non-pipeline (in the working `.zshrc`):
```bash
# vg on PATH if you use it for graph conversions outside the pipeline
export PATH="${PATH}:$HOME/personal/vg/bin"

# gnu-getopt (some scripts assume GNU behavior)
export PATH="/opt/homebrew/opt/gnu-getopt/bin:$PATH"
```

After editing: `source ~/.zshrc` (or open a new terminal). Verify:
```bash
$CC --version         # should print Homebrew clang 17
$CXX --version
which gtime           # /opt/homebrew/bin/gtime
```

### 2. Clone the source repos

`~/personal/` is the canonical location. Clone each; do NOT deviate from
this layout — the makefile uses `SDSL_DIR ?= ../sdsl-lite` (i.e. sibling
directory) and per-project CMakeLists hardcodes `$HOME/{include,lib}`.

```bash
mkdir -p ~/personal
cd ~/personal

# sdsl-lite — MUST be vgteam fork, not simongog (see vesuvio hurdle 2)
git clone https://github.com/vgteam/sdsl-lite.git

# libhandlegraph
git clone https://github.com/vgteam/libhandlegraph.git

# gbwt + gbwtgraph
git clone https://github.com/jltsiren/gbwt.git
git clone https://github.com/jltsiren/gbwtgraph.git

# grlBWT (standalone build for grlbwt-cli)
git clone https://github.com/ddiazdom/grlBWT.git

# pangenome-index-latest (private fork; --recursive for deps/grlBWT submodule)
git clone --recursive \
    https://github.com/hlakshmidevi10/pangenome-index-pvt.git \
    pangenome-index-latest
# checkout the working branch:
cd pangenome-index-latest && git checkout tag-head-samples && cd ..

# mem-projection
git clone https://github.com/hlakshmidevi10/MEM-Projection.git mem-projection
cd mem-projection && git checkout vesuvio-bootstrap && cd ..

# gafpack (private fork; a specific branch is needed)
git clone https://github.com/hlakshmidevi10/gafpack-pvt.git gafpack
cd gafpack && git checkout path-walker && cd ..
```

Verify submodule populated:
```bash
cd ~/personal/pangenome-index-latest
git submodule status
# Expected: f09e7fa7... deps/grlBWT (v1.0.1-alpha-36-gf09e7fa)
```

### 3. Build sdsl-lite (foundation for everything)

```bash
cd ~/personal/sdsl-lite
./install.sh $HOME
```

**What this does:**
1. Builds sdsl-lite via CMake into `~/personal/sdsl-lite/build/`
2. Copies headers into `~/include/{sdsl,divsufsort.h,divsufsort64.h}`
3. Copies libs into `~/lib/{libsdsl.a,libdivsufsort.a,libdivsufsort64.a}`
4. **Writes `~/personal/sdsl-lite/Make.helper`** — this file is critical.
   Downstream Makefiles include it to inherit `INC_DIR`, `LIB_DIR`, `MY_CXX`,
   `MY_CXX_FLAGS`. The pangenome-index makefile does exactly this.

Expected `Make.helper` after install (on this Mac):
```
LIB_DIR = /Users/hlakshmidevi/lib
INC_DIR = /Users/hlakshmidevi/include
MY_CXX_FLAGS= -std=c++17 -DNDEBUG -stdlib=libc++
MY_CXX_OPT_FLAGS= -O3 -ffast-math -funroll-loops ...
MY_CXX=/opt/homebrew/opt/llvm@17/bin/clang++
MY_CC=/opt/homebrew/opt/llvm@17/bin/clang
```

Verify: `ls ~/include/sdsl/ | wc -l` should show ~100+ headers.

### 4. Build libhandlegraph

```bash
cd ~/personal/libhandlegraph
mkdir -p build && cd build
cmake -DCMAKE_INSTALL_PREFIX=$HOME ..
make -j$(sysctl -n hw.ncpu)
make install
```

This installs `~/include/handlegraph/` + `~/lib/libhandlegraph.{a,dylib}`.

### 5. Build gbwt (no install target — manual copy)

```bash
cd ~/personal/gbwt
make -j$(sysctl -n hw.ncpu)

# No `make install` in this repo. Manual copy:
cp -r include/gbwt $HOME/include/
cp lib/libgbwt.a $HOME/lib/
```

Verify: `ls ~/include/gbwt/` shows `gbwt.h`, `dynamic_gbwt.h`, etc.

### 6. Build gbwtgraph (no install target — manual copy)

```bash
cd ~/personal/gbwtgraph
make -j$(sysctl -n hw.ncpu)

# Manual copy of headers + lib:
cp -r include/gbwtgraph $HOME/include/
cp lib/libgbwtgraph.a $HOME/lib/
```

**Also produces binaries** in `~/personal/gbwtgraph/bin/`:
- `gbz_stats` — parsed by `build_index.sh` step 01 for NUM_SEQ
- `gbz_extract` — step 02, produces the bidirectional `.seq`
- `gfa2gbwt` — used by `hprcv{1,2}/prepare_inputs.sh` to build the GBZ

These should already be on PATH via the `.zshrc` `PATH=$HOME/personal/gbwtgraph/bin:$PATH` line.

Sanity: `gbz_stats -h` should print usage (not "command not found").

### 7. Build grlBWT (top-level, for grlbwt-cli)

```bash
cd ~/personal/grlBWT
mkdir -p build && cd build
cmake ..
make -j$(sysctl -n hw.ncpu)
```

Produces `~/personal/grlBWT/build/grlbwt-cli` — used by `build_index.sh`
step 03. On PATH via `.zshrc`. Sanity: `grlbwt-cli --help`.

**gcc-15 transitive-include bugs (vesuvio hurdle 6) do NOT affect the Mac** —
Homebrew LLVM's libc++ still does the transitive includes. If the grlBWT
build ever fails with "'X' is not a member of 'std'", refer to vesuvio
hurdle 6 for the `sed` patch pattern.

### 8. Build pangenome-index-latest

This is the big one: 14+ C++ binaries, links everything installed above.

```bash
cd ~/personal/pangenome-index-latest

# First, the embedded submodule:
make grlbwt          # builds deps/grlBWT/build/libgrlbwt.a (embedded)

# Now the main library + programs:
make -j$(sysctl -n hw.ncpu)
```

Or in one shot: `make -j` (the `all:` target does grlbwt → library → programs).

**Result:** `~/personal/pangenome-index-latest/bin/` populated with 20+
binaries (`find_mems`, `build_tags`, `convert_tags`, `build_rindex`,
`build_lightweight_tags`, `build_tag_head_samples`, ...).

**macOS Apple Clang branch of the makefile:** the makefile has a
`ifeq ($(shell uname -s), Darwin)` block (lines 25–57 in `makefile`) that
auto-configures OpenMP for Apple Clang via `-Xpreprocessor -fopenmp` and
finds libomp under `/opt/homebrew/opt/libomp`. **But we set `CXX=clang++`
in `.zshrc` to point at Homebrew LLVM, not Apple Clang**, so this branch
detects Homebrew LLVM (which supports `-fopenmp` natively) and takes the
simpler path. Either works.

**If build fails with "libomp not found":** verify `brew --prefix libomp`
returns a path that contains `include/omp.h`. If the keg-only formula is
missing, `brew install libomp`.

Sanity check the binaries link cleanly:
```bash
~/personal/pangenome-index-latest/bin/find_mems 2>&1 | head -3
# should print: "Usage: .../find_mems <r_index_file> ..."
```

### 9. Build gafpack (Rust)

```bash
cd ~/personal/gafpack
cargo build --release
```

Produces `~/personal/gafpack/target/release/gafpack` (~1.4MB single binary).
Already on PATH via `.zshrc`. Sanity: `gafpack --version` → `gafpack 0.1.2`.

**Does NOT need the CA-cert / `cc` workarounds from vesuvio hurdle 8** —
macOS Keychain covers CA, and Xcode CLT provides `/usr/bin/cc`.

### 10. Python + gaftools (for validate_gaf)

The working Mac has miniconda3 as the default python (`/Users/hlakshmidevi/miniconda3/bin/python3`),
and `gaftools==1.3.0` installed into the base env via `pip install`. That
version is critical — see vesuvio hurdle 12 for why 1.4.0 is broken.

**If you have miniconda already:**
```bash
pip install "gaftools==1.3.0"
```

**If you don't** — the pipeline also works with system python3 or Homebrew
python@3:
```bash
brew install python@3.13   # if not already
pip3 install "gaftools==1.3.0"
```

**PEP 668 warning:** newer macOS + Homebrew python may refuse `pip install`
into the system-managed env. Two workarounds:
```bash
# Option A: user site-packages
pip3 install --user "gaftools==1.3.0"
export PATH="$HOME/.local/bin:$PATH"   # also in the working .zshrc

# Option B: venv
python3 -m venv ~/.venvs/gaftools
~/.venvs/gaftools/bin/pip install "gaftools==1.3.0"
export PATH="$HOME/.venvs/gaftools/bin:$PATH"
```

Verify:
```bash
gaftools --version                                          # 1.3.0
python3 -c "import gaftools; print(gaftools.__version__)"   # 1.3.0
```

### 11. End-to-end validation (yeast-235)

Run the yeast pipeline end-to-end. This exercises every binary + gafpack +
validate_gaf, in the same shape you'd use for a real query. Reference:
CLAUDE.md lines 100–101, "yeast-235 chrII normalized: 2000/2000 valid".

**Prerequisite input files** (in the `mem-projection` clone — see
`configs/yeast235-chrII-normalized.env`):
- `yeast-235/yeast-235-chrI/final_output2/yeast235_chrII_100kb_laced_sorted_normalized.gbz` (~60 MB)
- `yeast-235/yeast-235-chrI/S288C_chrII_N100K_R1_200_reads.txt` (~20 MB, 100K reads)

If these aren't in your clone, they may live in a separate data drop; ask
the user for the yeast dataset location.

**Full pipeline (build index + query with GAF + validate):**
```bash
cd ~/personal/mem-projection/pangenome-pipeline

# Build index once (~15 min on 8-core Mac):
./build_index.sh yeast235-chrII-normalized.env yeast-fresh

# Query the index (lightweight + coverage-only, default):
./query.sh yeast235-chrII-normalized.env yeast-fresh

# Query with GAF + validation (~1 min total):
./query.sh yeast235-chrII-normalized.env yeast-fresh smoke --gaf
```

**Bar to hit:** the smoke run must produce
```
Total entries:   2000
Valid entries:   2000 (100.00%)
Invalid entries: 0 (0.00%)
```

Anything less is a bug — see CLAUDE.md "Correctness criterion". On the
current working Mac, the numbers were:

| Step | wall | RSS |
|---|---:|---:|
| 09 find_mems (flipped, lightweight) | 21 s | 509 MB |
| 10 gafpack (--dedup-read-node) | 2 s | 264 MB |
| 11 validate_gaf (n=2000) | 18 s | 1617 MB |

**A/B with flipped MEM finder** (mem-projection JR-002 → JR-003):
```bash
FIND_MEMS_EXTRA_FLAGS="--use-flipped-mems" \
  ./query.sh yeast235-chrII-normalized.env yeast-fresh flipped-smoke --gaf
```

Same 100% valid, minor perf delta.

---

## Mac-specific hurdles (recorded here so the next agent knows the pattern)

Analogous to `vesuvio-build-issues.md`'s 15 hurdles, but for Mac. Fewer here
because the pipeline was born on Mac.

### M1. `Make.helper` records the LLVM version at install time

If you install sdsl-lite (step 3) with `CC=/opt/homebrew/opt/llvm@17/bin/clang`
in your env, `Make.helper` bakes that path in. Later upgrading to `llvm@18`
via Homebrew without re-running `install.sh` will break the build with
`clang++: error: no such file or directory: /opt/homebrew/opt/llvm@17/bin/clang++`.

**Fix:** either
- re-run `cd ~/personal/sdsl-lite && ./install.sh $HOME` after changing LLVM version, OR
- manually edit `Make.helper`'s `MY_CXX`/`MY_CC` lines.

### M2. Two `sdsl-lite` clones on the working Mac

The working Mac has `~/sdsl-lite/` AND `~/personal/sdsl-lite/`. **The one
that matters is `~/personal/sdsl-lite/`** — that's the sibling directory
`SDSL_DIR ?= ../sdsl-lite` in the pangenome-index makefile resolves to.
`~/sdsl-lite/` appears to be a legacy clone; do NOT bother creating it on
a fresh Mac. Only create `~/personal/sdsl-lite/`.

### M3. Homebrew keg-only formulas need explicit `-I`/`-L`

`openssl@3`, `libomp`, `llvm@17`, `zlib`, `zstd`, `protobuf@29` are all
keg-only. Homebrew does NOT symlink their `include/lib` into
`/opt/homebrew/{include,lib}`. Every one of them shows up in the `.zshrc`
`CPPFLAGS`/`LDFLAGS` chain. **Don't skip any — even zlib.** Missing zstd
in particular will produce cryptic `undefined symbols: _ZSTD_*` at link
time.

### M4. Apple Clang vs. Homebrew LLVM

Xcode CLT provides `/usr/bin/clang++` (Apple Clang). It lacks libomp
headers and needs `-Xpreprocessor -fopenmp` gymnastics. Homebrew `llvm@17`
provides its own clang++ with `-fopenmp` support out of the box. **Prefer
Homebrew LLVM** by pointing `CXX` at it in `.zshrc` (step 1). The makefile
does auto-detect and adapt if you use Apple Clang, but it's a more brittle
path.

### M5. macOS `/tmp` is on the same volume as `$HOME`

vesuvio hurdle 11 (`grlbwt-cli` cross-device rename fail on Linux where
`/tmp` is tmpfs) doesn't happen on Mac. `grlbwt-cli` can rename freely
without `-T`. `build_index.sh` still passes `-T $RUN_DIR/grl_tmp` because
it's harmless on Mac and required on Linux; don't remove.

### M6. macOS `time -l` (BSD time) exits 1 on some hosts

Some Mac hosts (per vesuvio-build-issues.md's earlier form): `/usr/bin/time -l`
fails with `sysctl kern.clockrate: Operation not permitted` and always exits 1.
`build_index.sh` + `query.sh` auto-detect and prefer `gtime` (Homebrew gnu-time)
which is reliable. If you skip installing `gnu-time`, the pipeline still works
but RSS numbers in logs will be zero.

### M7. miniconda base env is where gaftools lives on the working Mac

The `.zshrc` initializes conda, so `python3` and `gaftools` both come from
`~/miniconda3/bin/`. If you install gaftools into a different env or a venv,
either activate that env before running `query.sh --gaf`, or set
`VALIDATE_GAF` env var to point at a wrapper that activates the right env
first. The pipeline just calls `python3 validate_gaf_v2.py` — whatever
`python3` resolves to must have gaftools 1.3.0 importable.

### M8. `.zshrc` is the durable env file (no equivalent to `~/.pangenome_env.sh`)

vesuvio has `~/.pangenome_env.sh` that both `bootstrap_vesuvio.sh` and
build/query scripts source. Mac has no such file — everything is in
`~/.zshrc`. If you set up an alternate shell (bash, fish), replicate the
exports there. Don't create `~/.pangenome_env.sh` on Mac unless you're
sure you'll source it in every new shell.

---

## Verification checklist

After all 11 steps, these should all succeed:

```bash
# Compilers point at Homebrew LLVM 17
$CC --version | head -1                                          # "Homebrew clang version 17.x"
$CXX --version | head -1

# All build outputs present
ls ~/lib/libsdsl.a ~/lib/libgbwt.a ~/lib/libgbwtgraph.a \
   ~/lib/libhandlegraph.dylib
ls ~/include/sdsl/int_vector.hpp ~/include/gbwt/gbwt.h \
   ~/include/gbwtgraph/gbwtgraph.h ~/include/handlegraph/handle_graph.hpp

# Binaries on PATH
which find_mems build_tags convert_tags build_rindex gafpack \
      grlbwt-cli gbz_stats gbz_extract gfa2gbwt gtime
# All should resolve to ~/personal/... or /opt/homebrew/bin

# find_mems links cleanly (no dyld errors)
find_mems 2>&1 | head -3

# gaftools 1.3.0 importable
python3 -c "import gaftools; print(gaftools.__version__)"        # 1.3.0

# End-to-end: yeast smoke (see step 11)
cd ~/personal/mem-projection/pangenome-pipeline
./query.sh yeast235-chrII-normalized.env <existing-tag> smoke --gaf
grep 'Valid entries' runs/<tag>/queries/smoke/lightweight/logs/11_validate_gaf.log
# Expected: "Valid entries:   2000 (100.00%)"
```

If all of the above pass, the setup is complete and the agent can run any
`build_index.sh` / `query.sh` invocation from `mem-projection/CLAUDE.md`.

---

## Should the agent write `bootstrap_macos.sh` from this?

**Yes, arguably** — but only after verifying steps 1–11 manually first on
the target Mac. The vesuvio bootstrap script exists BECAUSE the manual
process was so painful; on Mac the manual process is straightforward
enough that a script only pays off if this setup will be repeated on many
hosts.

If writing the script:
- Model it on `bootstrap_vesuvio.sh`: preflight for `brew`, `xcode-select -p`,
  `git`; then serial steps for each dep with `[ -f <artifact> ]` skip guards.
- Do NOT try to auto-edit `~/.zshrc` — offer a `.zshrc.d/pangenome.sh` fragment
  the user can source or append.
- Verification step at the end must be the yeast smoke run — that's the
  only test that confirms the whole toolchain is linked correctly.
- Idempotent: re-running with a partial install should complete the missing
  steps and skip the done ones (`[ -f ~/lib/libsdsl.a ] || build_sdsl`).

---

## Where to go from here

- **`vesuvio-build-issues.md`** — the Linux counterpart, for when the same
  pipeline needs to run on a shared cluster host. Some hurdles (gcc 15
  transitive includes, LD_LIBRARY_PATH, tmpfs `/tmp`) transfer wisdom back
  to Mac if a Homebrew formula ever changes stdlib behavior.
- **`CLAUDE.md`** — pipeline-level correctness criteria + footguns.
- **`~/personal/pangenome-index-latest/CLAUDE.md`** — engineering principles
  for changes to the C++ toolkit itself.
- **`~/personal/pangenome-index-latest/RESEARCH_JOURNAL.md`** — append-only
  history of design decisions + measurements. Read the index before opening
  any performance/correctness question.
