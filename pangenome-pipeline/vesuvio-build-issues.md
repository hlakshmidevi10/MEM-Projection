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

The pipeline itself (`run.sh`, the binaries, the configs) is identical across
both hosts. The divergences are all in the toolchain *around* the pipeline.

## The 12 hurdles, in order encountered

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

### 12. `gaftools find_path` flag renamed (run.sh step 11)

**Symptom:**
```
=== 11 validate_gaf (n=2000) ===
Running gaftools to get path sequences...
Failed to run gaftools:
  gaftools error: unrecognized arguments: --paths_file yeast...gfa
```

**Root cause:** `scripts/validate_gaf_v2.py` calls
`gaftools find_path --paths_file ...`. Current gaftools (1.3.x as installed by
pip into our venv) renamed that to `--paths-file` (underscore → dash). The
Mac's gaftools install happens to be an older version that still accepts the
underscore form.

**Fix:** One-character change in `validate_gaf_v2.py:105` —
`--paths_file` → `--paths-file`.

**Lesson:** Pip-installed Python tools floating to their latest version on
fresh installs can introduce surface API drift. Pinning gaftools to a specific
version in the bootstrap (`pip install gaftools==X.Y.Z`) would prevent this,
but at the cost of locking out upstream fixes. The trade-off here was to
accept the drift and patch our script — both call sites use the same flag, so
the change is trivial.

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
└── mem-projection/                     → the pipeline repo (run.sh lives here)
```

`run.sh` requires no edits; the env vars in `~/.pangenome_env.sh` override
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
