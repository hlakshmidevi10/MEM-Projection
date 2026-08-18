# vesuvio-build-issues

Field notes from porting `pangenome-pipeline` from the Mac dev box to **vesuvio**
(Debian 13 + Guix, no sudo, no system compilers). Every hurdle below has a fix
encoded in `bootstrap_vesuvio.sh`. This file exists so a future agent can
understand *why* the script does what it does, and what to expect when the same
class of issue surfaces on the next Linux/Guix host.

If you're setting up a new host: just run `bootstrap_vesuvio.sh --preflight-only`
first, then `bootstrap_vesuvio.sh`. This doc is for debugging when something
goes sideways.

## Environment delta: Mac vs. vesuvio

| Concept | Mac (working baseline) | Vesuvio |
|---|---|---|
| Package manager | Homebrew + manual `cp` to `~/{include,lib}` | Guix (per-user, no sudo) |
| Compiler | Homebrew LLVM 17 (`clang` / `clang++`) | Guix `gcc-toolchain` 15.2.0 |
| stdlib | libc++ | libstdc++ (gcc 13+ pruned transitive includes) |
| `cc` symlink | yes (Homebrew + Debian convention) | no — must `export CC=gcc` |
| CA cert bundle | macOS Keychain (transparent) | absent until `guix install nss-certs` |
| Runtime lib search | macOS finds `~/lib` mostly automatically | Linux requires `LD_LIBRARY_PATH=$HOME/lib` |
| Compiler env vars | `CPPFLAGS`/`LDFLAGS` exports in zshrc | `~/.guix-profile/etc/profile` sets `CPATH`/`LIBRARY_PATH`/`PKG_CONFIG_PATH` automatically |
| Python pip | tolerates `pip install --user` | PEP 668: must use a venv |
| CMake | older 3.x (whatever was installed) | Guix CMake 4.1.3 (dropped pre-3.5 policies) |

The pipeline itself (`build_index.sh` + `query.sh`, the binaries, the configs) is identical across
both hosts. The divergences are all in the toolchain *around* the pipeline.

## The 14 hurdles, in order encountered

> **Note for future readers:** Hurdles 10-12 reference `run.sh`, which was the
> monolithic pipeline driver in use when these issues were debugged. Since
> superseded by `build_index.sh` + `query.sh` (see `BUILD_QUERY_LAYOUT.md`).
> The fixes applied to `run.sh` carry over to both new scripts verbatim — the
> `time(1)` detection, `grlbwt-cli -T` tmpdir, and gaftools-1.3.0 pin all live
> in both `build_index.sh` and `query.sh` now.

Each entry: **(symptom) → (root cause) → (fix in `bootstrap_vesuvio.sh`)**.
Commits referenced are on branch `vesuvio-bootstrap`.

---

### 1. No system compilers at all (preflight failure)

**Symptom:** `gcc`, `g++`, `make`, `cmake` all missing on `$PATH`. `/usr/bin/`
only had `curl`, `git`, `python3`.

**Root cause:** Bare Debian 13 with only `vg` installed via Guix. No
`build-essential` (no sudo to install it either).

**Fix:** Documented `guix install` line in the preflight failure message:
```
guix install \
  gcc-toolchain make cmake pkg-config coreutils \
  autoconf automake libtool gettext m4 \
  zstd zstd:lib openssl bzip2 xz lz4 zlib \
  python python-pip rust rust:cargo \
  nss-certs
```
Note `zstd:lib` (separate output of the `zstd` package — Guix splits dev libs)
and `rust:cargo` (cargo is a separate output of the `rust` package).

After install: `GUIX_PROFILE="$HOME/.guix-profile"; . "$GUIX_PROFILE/etc/profile"`
to re-load PATH/CPATH/LIBRARY_PATH. Commit: `a3ab290`.

---

### 2. CMake 4.x rejects pre-3.5 `cmake_minimum_required`

**Symptom:**
```
CMake Error at CMakeLists.txt:1 (cmake_minimum_required):
  Compatibility with CMake < 3.5 has been removed from CMake.
  Or, add -DCMAKE_POLICY_VERSION_MINIMUM=3.5 to try configuring anyway.
```
Hit on the initial `simongog/sdsl-lite` clone.

**Root cause:** `simongog/sdsl-lite` is abandoned; declares `cmake_minimum_required(2.8.7)`.
Modern CMake refuses to honour that.

**Fix:** Switched `SDSL_REPO` from `simongog/sdsl-lite` to **`vgteam/sdsl-lite`**
(the maintained fork — and the one your Mac was actually using, per
`~/personal/sdsl-lite/.git/config`). vgteam's `CMakeLists.txt` declares 3.13,
no escape hatch needed. Commit: `a1712e7`.

For other CMake projects that *might* hit similar issues, the script passes
`-DCMAKE_POLICY_VERSION_MINIMUM=3.5` defensively to `grlBWT` and `libhandlegraph`
cmake invocations. Commit: `ee01118`.

**Lesson:** When porting to a new host, check what fork/version your local
working setup actually uses — `git remote -v` in the local clone is the source
of truth, not what an upstream README suggests.

---

### 3. `gbwt/gbwt.h` not found during gbwtgraph build

**Symptom:**
```
fatal error: gbwt/gbwt.h: No such file or directory
    4 | #include <gbwt/gbwt.h>
```
during `make -C ~/gbwtgraph`.

**Root cause:** Initial script installed each project into its own source tree
(`~/sdsl-lite/include/`, `~/gbwt/include/`). But gbwtgraph's Makefile sets
`INCLUDES=-Iinclude -I$(INC_DIR)`, where `$(INC_DIR)` comes from
`sdsl-lite/Make.helper`. That only contained sdsl's include dir — not gbwt's.

**Fix:** Install everything into a **single shared prefix**. sdsl's `install.sh
<prefix>` writes `Make.helper` declaring `INC_DIR=<prefix>/include`, which all
downstream Makefiles inherit. Initial fix used `$PREFIX=$HOME/.local`. Commit: `6b48213`.

Where this matters in the script:
- sdsl: `install.sh $PREFIX` (proper install target)
- gbwt: **no install target** — manual `cp -r include/gbwt $PREFIX/include/` + `cp lib/libgbwt.a $PREFIX/lib/`
- libhandlegraph: cmake `-DCMAKE_INSTALL_PREFIX=$PREFIX` (proper install)
- gbwtgraph: **no install target** — manual `cp -r` same as gbwt

**Mac equivalent:** You manually did the same `cp` dance years ago into `~/include/` and `~/lib/`. We just automated it.

---

### 4. README required `--recursive` clone (caught by reading the docs)

**Symptom:** Would have been `cd deps/grlBWT/build: No such file or directory`
inside pangenome-index's `grlbwt` make target.

**Root cause:** `pangenome-index-latest` has a submodule at `deps/grlBWT`; its
makefile builds an embedded `libgrlbwt.a` from it (separate from the top-level
grlBWT we build for `grlbwt-cli`). Plain `git clone` leaves `deps/grlBWT/`
empty.

**Fix:** Bootstrap uses `git clone --recursive --branch upstream-sync ...` for
pangenome-index, plus `git submodule update --init --recursive` on the
update path. Commit: `273bc2e`.

Per the upstream README at `pangenome-index-latest/docs/getting-started/install-and-build.md`.

**Lesson:** Always grep upstream docs for `--recursive` before scripting a clone.

---

### 5. `Could NOT find LibSDSL` in embedded `deps/grlBWT`

**Symptom:**
```
CMake Error: Could NOT find LibSDSL (missing: LIBSDSL_LIBRARY
  LIBDIVSUF_LIBRARY LIBDIVSUF64_LIBRARY LIBSDSL_INCLUDE_DIR)
```
when building pangenome-index, even though sdsl was correctly installed
into `$HOME/.local`.

**Root cause:** `deps/grlBWT/cmake/Modules/FindLibSDSL.cmake` hardcodes its
search paths:
```cmake
find_path(LIBSDSL_INCLUDE_DIR sdsl/csa_sada.hpp
          PATHS $ENV{HOME}/usr/include $ENV{HOME}/include)
find_library(LIBSDSL_LIBRARY NAMES sdsl
             PATHS $ENV{HOME}/usr/lib $ENV{HOME}/lib)
```
It does **NOT** honour `CMAKE_PREFIX_PATH`, `CMAKE_INSTALL_PREFIX`, or
`PKG_CONFIG_PATH`. Only `$HOME/include` and `$HOME/usr/include`.

Discovered by inspecting the **working Mac's** CMakeCache.txt:
```
LIBSDSL_INCLUDE_DIR:PATH=/Users/hlakshmidevi/include
LIBSDSL_LIBRARY:FILEPATH=/Users/hlakshmidevi/lib/libsdsl.a
```
i.e. Mac install prefix is literally `$HOME` (not `$HOME/.local`).

**Fix:** Changed `PREFIX` default from `$HOME/.local` to `$HOME`. Now `$HOME/include/sdsl/`
and `$HOME/lib/libsdsl.a` are exactly where `FindLibSDSL.cmake` looks. Commit: `cf46e74`.

**Lesson:** When a build script "hardcodes" paths, no amount of `-D` flags will help. Sometimes the only path forward is to make the install layout match what the script wants. Inspecting a known-good build's cmake cache is the fastest way to discover hardcoded paths.

---

### 6. gcc 15 transitive-include bugs in grlBWT

**Symptoms:** Two separate compile failures:

```
external/cdt/include/cdt_common.hpp:11: error: 'uint8_t' does not name a type
   note: 'uint8_t' is defined in header '<cstdint>'
```

```
scripts/bwt_stats.cpp:60: error: 'sort' is not a member of 'std'; did you mean 'sqrt'?
```

Neither file `#include`s the header it needs.

**Root cause:** libstdc++ in gcc 13+ pruned transitive includes. Previously,
`<iostream>` transitively included `<cstdint>`, `<algorithm>`, etc. Now it
doesn't, so any source that relied on that "free" include now fails.
Clang/libc++ (your Mac) still does the transitive includes, so the bugs are
invisible there. See <https://gcc.gnu.org/bugzilla/show_bug.cgi?id=109961>.

**Fix:** Two patches in the script:
- **cdt_common.hpp:** bump the `deps/grlBWT` submodule pointer from `f09e7fa`
  to `dca13c4` ("missing header for uint8_t" — upstream's own fix). Single
  commit advance, very low risk.
- **bwt_stats.cpp:** `sed -i '1i #include <algorithm>'`. Idempotent
  (`grep -q` guard). Not yet fixed upstream.

Same `bwt_stats.cpp` patch applied to top-level grlBWT too. Commit: `f948b12`.

**Lesson — this is the biggest divergence.** Anywhere on vesuvio we build code
originally tested on Clang/older-gcc, expect more of these. **They're all
one-line `sed` fixes** but unpredictable until they surface. The error message
always tells you exactly what to `#include`. Pattern:
```
'X' is not a member of 'std'  →  #include <appropriate-header>
'uint8_t' does not name a type →  #include <cstdint>
```

Known common ones:
| Type | Header |
|---|---|
| `std::sort`, `std::find`, `std::min`, `std::max` | `<algorithm>` |
| `uint8_t`, `uint32_t`, `int64_t`, `size_t` | `<cstdint>` |
| `std::ostringstream`, `std::stringstream` | `<sstream>` |
| `std::accumulate`, `std::iota` | `<numeric>` |
| `std::function` | `<functional>` |

---

### 7. `libhandlegraph.so` not found at runtime

**Symptom:**
```
./bin/find_mems: error while loading shared libraries:
libhandlegraph.so: cannot open shared object file
```
even though `~/lib/libhandlegraph.so` exists.

**Root cause:** Linux's dynamic loader doesn't search `$HOME/lib` by default
(macOS is more lenient via different `DYLD_*` rules). libhandlegraph's CMake
install doesn't bake an RPATH into consumers either.

**Fix:** `export LD_LIBRARY_PATH=$HOME/lib`. Already in the script's
generated `~/.pangenome_env.sh` (bootstrap's persistent env file). Already
existed at the time of failure — user just hadn't sourced it yet.

**Lesson:** On Linux always either set `LD_LIBRARY_PATH` or bake `RPATH` into
binaries at link time. macOS muscle memory ("just put it in `~/lib`") doesn't
transfer.

---

### 8. Cargo build broke: missing `cc`, then missing CA certs

Two distinct sub-issues in the gafpack `cargo build --release`.

**8a) `cc` not found:**
```
error occurred in cc-rs: failed to find tool "cc": No such file or directory
```
during build of `bzip2-sys`, `liblzma-sys`, `zstd-sys` (all use `cc-rs` to
compile bundled C sources).

**Root cause:** Guix's `gcc-toolchain` ships `gcc` / `g++` but no `cc` alias.
Debian's `build-essential` creates the symlink, Guix does not. `cc-rs` probes
`$CC` first; if unset it falls back to `cc` and fails.

**Fix:** `CC="${CC:-gcc}" CXX="${CXX:-g++}" cargo build --release`. No-op on
hosts where `/usr/bin/cc` exists. Commit: `def67d6`.

**8b) CA certificate verification failed:**
```
error: failed to get `bytemuck` as a dependency of package `gafpack`
Caused by: server certificate verification failed.
  CAfile: none CRLfile: none
```

**Root cause:** Guix doesn't bundle CA certs in the base profile. Cargo (via
libgit2) uses OpenSSL's compiled-in default CA path, which on Guix points at
a non-existent location.

**Fix:** `guix install nss-certs`. Guix's `etc/profile` then auto-exports
`SSL_CERT_FILE` and `SSL_CERT_DIR`. Cargo + curl + git all honour those.

CA-check moved from preflight (false-positive prone) into the gafpack step
itself, using `cargo search` as the probe (truest test — uses same TLS stack
as the actual fetch). Skipped entirely if gafpack binary already exists.
Commit: `26e3c5a`.

**Lesson:** Guix's "everything is explicit" philosophy means you opt into CA
certs, opt into `cc` symlinks, opt into everything. Different worldview from
Homebrew's "batteries included." When porting builds to a Guix host, expect to
discover an implicit dependency at every layer.

---

### 9. `gaftools` (Python venv) couldn't find `libz.so.1` at runtime

**Symptom:**
```
$ gaftools
ImportError: libz.so.1: cannot open shared object file: No such file or directory
  File ".../site-packages/pysam/__init__.py", line 4, in <module>
    from pysam.libchtslib import *
```

**Root cause:** `gaftools` depends on `pysam`, which ships compiled C extensions
(`libchtslib.so`) linked against zlib's `libz.so.1`. On vesuvio:

- Guix's zlib lives at `~/.guix-profile/lib/libz.so.1`
- Debian-with-Guix puts `~/.guix-profile/bin` on PATH automatically (via the
  profile's `etc/profile`) but does NOT add `~/.guix-profile/lib` to the
  loader's search path
- pip-installed pysam's `libchtslib.so` has soname dependency on `libz.so.1`
  with no RPATH, so the dynamic loader can't find it

**Fix:** Extend `LD_LIBRARY_PATH` in the generated `~/.pangenome_env.sh` to
include `$HOME/.guix-profile/lib` alongside `$PREFIX/lib`:
```bash
export LD_LIBRARY_PATH="$PREFIX/lib:$HOME/.guix-profile/lib:$LD_LIBRARY_PATH"
```

This also defensively covers any future runtime dependencies on Guix-provided
shared libs (openssl, libgomp, lz4, etc).

**Lesson:** Guix's profile activation script handles PATH but not LD_LIBRARY_PATH.
Any pip-installed wheel or build-from-source binary that links a Guix-provided
.so at install time will need this. The fix is universal — always add
`~/.guix-profile/lib` to LD_LIBRARY_PATH on Guix-based hosts.

---

### 10. `/usr/bin/time` doesn't exist (run.sh step 01)

**Symptom:**
```
=== 01 gbz_stats ===
>>> [01_gbz_stats] .../bin/gbz_stats -i .../yeast235...gbz
    FAIL (exit 127) — see .../logs/01_gbz_stats.time
./run.sh: line 118: /usr/bin/time: No such file or directory
```

**Root cause:** `run.sh` profiles every step with `time(1)` to capture wall +
RSS into `logs/NN_*.time`. It tried `gtime` first (macOS Homebrew), fell back
to `/usr/bin/time`. On bare Debian without `build-essential`, `/usr/bin/time`
doesn't exist — it's part of the `time` Debian package which isn't installed
by default.

**Fix:**
1. `guix install time` provides `~/.guix-profile/bin/time` (GNU time, supports `-v`).
2. Patched `run.sh` to search candidates by absolute path:
   ```
   gtime  →  $HOME/.guix-profile/bin/time  →  /usr/bin/time  →  /usr/local/bin/time
   ```
   and probe each for `-v` support. Avoids `command -v time` because bash's
   built-in `time` keyword shadows it. Aborts with a clear "install GNU time"
   message if none found.

**Lesson:** "Standard" Unix binaries (`time`, `bc`, `dc`, `xargs`, `column`)
aren't always present on minimal Debian. Probe by absolute path candidates,
not `command -v`, since shell built-ins can mask them.

---

### 11. `grlbwt-cli` cross-device rename failure (run.sh step 03)

**Symptom:**
```
=== 03 grlbwt ===
>>> [03_grlbwt] .../grlbwt-cli yeast235_chrII_100kb_normalized.seq -t 16 ...
terminate called after throwing an instance of 'std::filesystem::__cxx11::filesystem_error'
  what(): filesystem error: cannot rename: Invalid cross-device link
  [/tmp/grl.bwt.vUCkSR/bwt_lev_0_OP6] [yeast235_chrII_100kb_normalized.rl_bwt]
```

**Root cause:** `grlbwt-cli` writes intermediates to `/tmp/grl.bwt.XXXX/` and
uses `std::filesystem::rename` to move the final output to the run dir.
`rename(2)` requires source and destination to be on the same filesystem
(it's an atomic inode move, not a copy). On vesuvio (and many Linux hosts),
`/tmp` is `tmpfs` (RAM-backed) while `$HOME` is on a regular disk filesystem.
Cross-fs rename → EXDEV → uncaught exception → abort.

The Mac doesn't hit this because macOS `/tmp` is on the same APFS volume as
`/Users/<you>`.

**Fix:** `grlbwt-cli` has a `-T / --tmp` flag. Updated `run.sh` step 03 to
pass `-T $RUN_DIR/grl_tmp`, putting intermediates on the same filesystem as
the final output by construction.

**Lesson:** Any tool that uses `rename(2)` to "move" cross-directory results
needs its tmpdir co-located with its output on Linux. Default-`/tmp` tools
either need `TMPDIR` overridden or an explicit `--tmpdir` flag. Other common
offenders: `sort -T`, `sed --temp` (some builds), various bioinformatics
tools' intermediates.

---

### 12. `gaftools` 1.4.0 is broken; pin to 1.3.0 (run.sh step 11)

**Symptom 1** (with old script + new gaftools):
```
gaftools error: unrecognized arguments: --paths_file yeast...gfa
```
**Symptom 2** (after renaming `--paths_file` → `--paths-file`):
```
File ".../gaftools/cli/find_path.py", line 101, in validate
    if args.nodes and args.regions:
AttributeError: 'Namespace' object has no attribute 'nodes'
```

**Root cause:** gaftools 1.4.0 (the version pip pulls on a fresh install today)
ships with `cli/find_path.py:validate()` reading `args.nodes` and `args.regions`,
but those flags aren't defined in the argument parser. Every `gaftools find_path`
invocation crashes during validation, before the actual logic runs. **It's a
genuine upstream bug in 1.4.0.** 1.3.0 doesn't have it.

The Mac happens to have gaftools 1.3.0 installed (in conda), so the dev box
masks the issue.

**Fix:** Pin to 1.3.0 in `bootstrap_vesuvio.sh`:
```bash
GAFTOOLS_VERSION="${GAFTOOLS_VERSION:-1.3.0}"
pip install --upgrade "gaftools==$GAFTOOLS_VERSION"
```
The script also detects when an existing install is the wrong version and
reinstalls (so re-running after a `pip install gaftools` upgrade auto-recovers).

1.3.0 uses `--paths_file` (underscore); `validate_gaf_v2.py` is updated to
match. When 1.4.x ships a fix, bump `GAFTOOLS_VERSION` and revisit the flag
(`--paths-file` with dash).

**Lesson:** Pip-installed Python tools without a pin will float to whatever
PyPI considers latest. A broken release in transit time can take down a
fresh install. For tools where API stability matters more than getting fixes
fast, pin and bump deliberately.

---

### 13. `curl` fails with `OPENSSL_3.{2,3}.0' not found` (hprcv2/prepare_inputs.sh step 0a)

**Symptom** (running `hprcv2/prepare_inputs.sh` on vesuvio after sourcing
`~/.pangenome_env.sh`):
```
[0a] downloading s3://garrisonlab/hprcv2/gfas/by-chromosome/...gfa.zst -> ...gfa.zst
curl: /home/haril/.guix-profile/lib/libssl.so.3: version `OPENSSL_3.2.0' not found (required by /lib/x86_64-linux-gnu/libcurl.so.4)
curl: /home/haril/.guix-profile/lib/libssl.so.3: version `OPENSSL_3.3.0' not found (required by /lib/x86_64-linux-gnu/libcurl.so.4)
```
curl exits non-zero, `set -euo pipefail` aborts the script before any normalize work runs.

**Root cause:** ABI mismatch driven by `LD_LIBRARY_PATH`. The user runs the
system `/usr/bin/curl`, which is dynamically linked against Debian's
`/lib/x86_64-linux-gnu/libcurl.so.4`. That `libcurl.so.4` was built against a
newer OpenSSL (≥ 3.2.0 / 3.3.0) and lists those versioned symbols as
requirements. The Guix env's
`LD_LIBRARY_PATH=$HOME/lib:$HOME/.guix-profile/lib:...` (set by
`~/.pangenome_env.sh`, hurdle 7) prepends Guix's `~/.guix-profile/lib`, which
ships an older `libssl.so.3` lacking those symbols. The dynamic linker resolves
the Guix `libssl.so.3` first; the system `libcurl.so.4`'s symbol lookups fail.

In short: a system binary inherited the Guix lib search path that was set up
for the *pipeline* binaries (which were linked against the Guix libs and
need them). The same env that fixes hurdle 7 breaks system curl.

**Fix (in `hprcv2/prepare_inputs.sh`):** in step `[0a]`, retry curl with
`LD_LIBRARY_PATH` unset before giving up. `env -u LD_LIBRARY_PATH` runs curl
with the user's normal env minus that one variable, restoring the system
dynamic-linker default (`/etc/ld.so.cache`) and resolving curl against
Debian's matching libssl.

```bash
$TIME_PFX curl ... "$URL" \
  || $TIME_PFX env -u LD_LIBRARY_PATH curl ... "$URL"
```

The fallback only fires if the first attempt fails (network errors, 4xx,
etc. still surface normally), so it doesn't mask legitimate curl problems.

**Why not fix `~/.pangenome_env.sh` instead?** Three reasons:
1. The pipeline binaries (`find_mems`, `build_tags`, `gfa2gbwt`) genuinely
   need `$HOME/.guix-profile/lib` on their lib path — that's hurdle 7.
   Removing it from the global env regresses runtime linkage for everything
   downstream.
2. Appending the Guix dir instead of prepending would help here, but Guix's
   own `etc/profile` prepends — fighting it is more work than per-callsite
   handling.
3. The mismatch only affects *system* binaries that happen to be called
   from inside a Guix-flavored shell. There's exactly one such call
   (`curl` in step 0a). Scope the fix there.

**Workaround if the fallback is missing or also fails:** download manually
in a fresh shell (`ssh vesuvio` → don't source `~/.pangenome_env.sh` →
`curl -fL -o file https://...`) and drop the `.zst` at
`~/mem-projection/hprcv2/`. The script's `[0a]` resume guard
(`elif [ -f "$SMOOTH_ZST" ]; then echo "... already present -- skipping download"`)
picks it up cleanly on re-run.

**Lesson:** When mixing two userland stacks on one host (Guix + Debian
system libs), `LD_LIBRARY_PATH` set globally for one stack's binaries can
silently break the other stack's binaries. Prefer per-callsite scoping
(`env -u`, or wrapper scripts) over a single shared env file when the
pipeline calls out to system tools.

---

### 14. `build_tags` aborts on GBZ nodes > 1024 bp (build_index.sh step 05)

**Symptom** (build_index.sh, ~7 minutes into step 05 on HPRC chr6):
```
=== 05 build_tags ===
>>> [05_build_tags] .../bin/build_tags -k 31 chr6.gbz ...rl_bwt ...tags
index_haplotypes(): Node offset 1024 is too large
```
Hard abort; no `.tags` produced. yeast-235 never tripped this because no
segment in its (much smaller) graph exceeded 1024 bp anyway.

**Root cause:** `build_tags` uses a **10-bit field (1024 values) to encode
per-node offsets** in its internal minimizer index. Any node ≥ 1024 bp
overflows that field. The originally-staged HPRC chr6 GBZ had nodes up to
~193 kb (4364 segments > 1024 bp), so `build_tags` ran fine until it walked
into the first oversized node and aborted.

The oversized nodes came from `prepare_inputs.sh` passing `gfa2gbwt -m 0`,
which **disables** the default 1024-bp segment-split. The intent was
"keep GBZ node IDs equal to GFA segment IDs across rebuilds." For yeast-235
this was harmless (no segment needed splitting); for HPRC it produced a GBZ
that build_tags can't ingest.

The `gfa2gbwt --help` parenthetical even spells out the constraint:

```
-m, --max-node N   break > N bp segments into multiple nodes (default 1024)
                   (minimizer index requires nodes of length <= 1024 bp)
```

**Two design intents in conflict, and build_tags wins** because it is
mandatory for the pipeline.

**Fix:** Switch `gfa2gbwt -m 0` → `gfa2gbwt -m 1024` in both
`hprcv1/prepare_inputs.sh` and `hprcv2/prepare_inputs.sh` (step `[2]`).
For a one-off recovery of an already-built GBZ:

```bash
cd ~/mem-projection/hprcv1
gfa2gbwt -c -p --pan-sn -m 1024 --gbz-v1 -P 8 \
    chr6.pan.fa.a2fb268.4030258.6a1ecc2.smooth.final
# ~5 min; then build_tags completes cleanly (~87 min, 82 GB peak RAM).
```

**Side effect:** with `-m 1024`, gfa2gbwt may split source segments and
**GBZ node IDs no longer match GFA segment IDs.** This is fine — the pipeline
contract "GBZ and GFA must share node IDs" is upheld by `build_index.sh`
step `01b` re-deriving the pipeline-facing GFA from the (post-split) GBZ via
```
vg convert -fW --no-translation $GBZ > $BASE.gfa
```
**That is why step 01b is strictly mandatory at HPRC scale.** Using a
user-supplied GFA with gafpack against a `-m 1024`-built GBZ would silently
produce wrong projections, because gafpack would walk segment IDs that the
GBZ no longer uses verbatim.

For datasets where no segment exceeds 1024 bp (e.g. yeast-235), `-m 0` and
`-m 1024` produce byte-identical GBZs — but defaulting to `-m 1024` keeps
the recipe correct at all scales.

**Lesson:** "Stable IDs across rebuilds" is an attractive property but is
not actually load-bearing for this pipeline — the pipeline already
re-derives the GFA from the GBZ at every build, so any node-ID stability
benefit dissolves at step 01b anyway. Whenever a tool's hard constraint
(build_tags' 10-bit offset) conflicts with a "nice-to-have" upstream
property (`-m 0`'s ID stability), the constraint wins; trying to preserve
the nice-to-have just produces a GBZ that the rest of the pipeline can't
consume.

---

## Layout on vesuvio after successful bootstrap

```
/home/haril/
├── .guix-profile/                      → managed by guix
├── .cargo/                              → rustup-installed (only if Guix's rust unavailable)
├── .venvs/gaftools/                     → python venv with gaftools
├── .pangenome_env.sh                    → exports PI_BIN/GAFPACK/etc + PATH + LD_LIBRARY_PATH
├── include/                             ← matches Mac layout (NOT $HOME/.local)
│   ├── sdsl/, divsufsort*.h
│   ├── gbwt/
│   ├── gbwtgraph/
│   └── handlegraph/
├── lib/
│   ├── libsdsl.a, libdivsufsort*.a
│   ├── libgbwt.a
│   ├── libgbwtgraph.a
│   └── libhandlegraph.{a,so}
├── sdsl-lite/                          ← source trees kept for Make.helper
├── gbwt/
├── gbwtgraph/                          → bin/{gbz_stats, gbz_extract, gfa2gbwt}
├── libhandlegraph/
├── grlBWT/                             → build/grlbwt-cli
├── pangenome-index-latest/             → bin/{find_mems, build_tags, ...}  (14 binaries)
├── gafpack/                            → target/release/gafpack
└── mem-projection/                     → the pipeline repo (build_index.sh + query.sh)
```

`build_index.sh` and `query.sh` require no edits; the env vars in `~/.pangenome_env.sh` override
its Mac-path defaults.

## Commits implementing all fixes

Branch `vesuvio-bootstrap` (off `main`):

```
26e3c5a  bootstrap_vesuvio: move CA cert check from preflight to gafpack step
def67d6  bootstrap_vesuvio: CC=gcc for cargo C-sys deps + CA-cert preflight
f948b12  bootstrap_vesuvio: patch gcc 15 transitive-include bugs in grlBWT
cf46e74  bootstrap_vesuvio: PREFIX=$HOME (match Mac layout, fix FindLibSDSL)
8985e30  bootstrap_vesuvio: tolerate grlBWT aux tool build failures
6b48213  bootstrap_vesuvio: shared-prefix install layout (fixes gbwt.h not found)
273bc2e  bootstrap_vesuvio: --recursive clone for pangenome-index submodules
a1712e7  bootstrap_vesuvio: switch sdsl to vgteam fork, mirror Mac PATH layout
ee01118  bootstrap_vesuvio: handle CMake 4.x removing pre-3.5 policy compat
a3ab290  bootstrap_vesuvio: support Guix + skip vg-only deps + venv gaftools
a872277  Add bootstrap_vesuvio.sh for per-user Linux install
```

`git log -p --follow pangenome-pipeline/bootstrap_vesuvio.sh` from `main` shows
each issue as a focused diff if you need to dig into a specific decision.

## If you're hitting a *new* issue not listed here

Most likely culprits, in order of probability on a Guix/Debian host:

1. **gcc 15 transitive-include error** — `sed -i '1i #include <X>'` the file; see hurdle 6 table.
2. **CMake "Compatibility with CMake <X has been removed"** — add `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` to the cmake invocation.
3. **`find_package(...) NOT found`** — check what paths the `cmake/Modules/Find*.cmake` actually probes (often hardcoded); install into one of those, not `$PREFIX`.
4. **`fatal error: <some-header>.h: No such file or directory`** — check if that lib's headers actually got installed to `$HOME/include/` (the `cp -r` step in the bootstrap might have missed a subdir).
5. **`error while loading shared libraries`** — source `~/.pangenome_env.sh` (sets `LD_LIBRARY_PATH` to include both `$HOME/lib` and `$HOME/.guix-profile/lib`). If still missing, check `find ~/.guix-profile -name 'libNAME.so*'` and prepend that dir.
6. **Cargo TLS / CA failure** — `guix install nss-certs` and re-source profile.
7. **Cargo `ToolNotFound: cc`** — `export CC=gcc CXX=g++`.
8. **`pip: externally-managed-environment`** — use a venv (`python3 -m venv ~/.venvs/<name>`), don't fight PEP 668.

For everything else, check the commit log on `vesuvio-bootstrap` — every fix
has a commit message explaining what the symptom was and what root cause it
addressed. The git history *is* the documentation.

---

### 15. `git pull` reports "Already up to date" but is actually behind

**Symptom:**
```
$ git pull
Already up to date.
$ git log -1 --oneline
7e5ddf2 ...   # <-- should be b2c1608 per Mac
```
`git remote show origin` says "local out of date" but `git pull` does nothing.

**Root cause:** The local branch tracks nothing. `git branch -vv` shows no
upstream (no `[origin/...]`). This happens when the branch was created locally
and pushed with `git push origin <branch>` instead of `git push -u origin <branch>`.
Without an upstream, `git pull` does `git fetch` + `git merge FETCH_HEAD`,
but FETCH_HEAD only updates when you explicitly `git fetch origin <branch>`.
A plain `git pull` fetches the *default* branch (usually main), sees no new
commits there, and reports "Already up to date" — even though the feature
branch is stale.

**Diagnosis:**
```bash
git branch -vv             # check for [origin/branch-name] tracking
git remote show origin     # shows "local out of date" even when pull says ok
git branch -r              # often missing origin/your-branch entirely
```

**Fix:** Three-step recovery:

```bash
# 1. Fetch the branch ref explicitly into remotes namespace
git fetch origin tag-head-samples:refs/remotes/origin/tag-head-samples

# 2. Set tracking for future pulls
git branch --set-upstream-to=origin/tag-head-samples tag-head-samples

# 3. Merge
git merge origin/tag-head-samples
```

**Preventive:** When pushing a new branch, always use `-u`:
```bash
git push -u origin tag-head-samples
```

**Lesson:** On vesuvio (and any remote where you clone + checkout feature
branches), `git pull` silently doing nothing is almost always a tracking
configuration issue. Check `git branch -vv` before assuming the remote has
no new commits.
