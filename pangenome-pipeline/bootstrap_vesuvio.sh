#!/usr/bin/env bash
# =============================================================================
# bootstrap_vesuvio.sh — install pangenome-pipeline deps under $HOME on Linux.
#
# Target host: Debian 13 (vesuvio), no sudo.
# Installs everything per-user into:
#   $HOME/.local/                       (libhandlegraph headers + libs, gaftools)
#   $HOME/.cargo/                       (rustup)
#   $HOME/{sdsl-lite,gbwt,libhandlegraph,gbwtgraph,grlBWT,
#          pangenome-index-latest,gafpack,mem-projection}/
#
# What it does NOT install: vg (deferred per user request).
# What it ASSUMES already present (preflight checks these): a C/C++ toolchain,
# cmake, pkg-config, libomp-dev, libzstd-dev, libssl-dev, libjansson-dev,
# protobuf, python3+pip, curl, git, autotools.
#
# Usage:
#   chmod +x bootstrap_vesuvio.sh
#   ./bootstrap_vesuvio.sh                    # full run
#   ./bootstrap_vesuvio.sh --preflight-only   # just check deps & exit
#   ./bootstrap_vesuvio.sh --skip-preflight   # if you know better
#   JOBS=8 ./bootstrap_vesuvio.sh             # override parallelism
#
# Re-running is safe: each repo step skips if the bin/lib it produces exists.
# Delete the relevant build artifact to force a rebuild.
# =============================================================================
set -euo pipefail

# ---- Config ----------------------------------------------------------------
ROOT="${ROOT:-$HOME}"
# PREFIX=$HOME (NOT $HOME/.local). This is unusual but required: the embedded
# deps/grlBWT/cmake/Modules/FindLibSDSL.cmake hardcodes its sdsl search to
# only "$ENV{HOME}/include" and "$ENV{HOME}/usr/include" — it does NOT honor
# CMAKE_PREFIX_PATH. Installing sdsl to $HOME/.local works for libhandlegraph
# (which honors the flag) but breaks pangenome-index's embedded grlBWT build.
# The working Mac dev env installs to $HOME directly and everything Just
# Works; we match that. Side effect: ~/include and ~/lib get populated.
PREFIX="${PREFIX:-$HOME}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# Git remotes (your private forks; SSH would be ssh://git@github.com/…)
# Branches matter: pangenome-index-latest uses upstream-sync (v2 record format
# lives there, NOT main); gafpack uses path-walker (only branch with the
# v2 binary-IO reader). mem-projection uses default branch.
PI_REPO="${PI_REPO:-https://github.com/hlakshmidevi10/pangenome-index-pvt.git}"
PI_BRANCH="${PI_BRANCH:-upstream-sync}"
PI_DIR_NAME="pangenome-index-latest"   # local clone name expected by run.sh

MEM_REPO="${MEM_REPO:-https://github.com/hlakshmidevi10/MEM-Projection.git}"
MEM_BRANCH="${MEM_BRANCH:-}"           # empty = default branch
MEM_DIR_NAME="mem-projection"

GAFPACK_REPO="${GAFPACK_REPO:-https://github.com/hlakshmidevi10/gafpack-pvt.git}"
GAFPACK_BRANCH="${GAFPACK_BRANCH:-path-walker}"
GAFPACK_DIR_NAME="gafpack"

# vgteam's maintained fork. Matters because (a) simongog/sdsl-lite is
# abandoned and its libdivsufsort submodule has cmake_minimum_required(2.8.7)
# which CMake 4.x refuses to build, and (b) the vg ecosystem (gbwtgraph,
# pangenome-index-latest) is developed/tested against this fork's headers.
# CMakeLists.txt here declares 3.13, so no -DCMAKE_POLICY_VERSION_MINIMUM
# escape hatch is needed.
SDSL_REPO="https://github.com/vgteam/sdsl-lite.git"
GBWT_REPO="https://github.com/jltsiren/gbwt.git"
LIBHG_REPO="https://github.com/vgteam/libhandlegraph.git"
GBWTGRAPH_REPO="https://github.com/jltsiren/gbwtgraph.git"
GRLBWT_REPO="https://github.com/ddiazdom/grlBWT.git"

# ---- Logging helpers -------------------------------------------------------
log()  { printf '\033[1;34m[%(%H:%M:%S)T]\033[0m %s\n' -1 "$*"; }
ok()   { printf '\033[1;32m  OK\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  WARN\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m  ERR\033[0m %s\n' "$*" >&2; exit 1; }

# ---- Arg parsing -----------------------------------------------------------
PREFLIGHT_ONLY=0
SKIP_PREFLIGHT=0
for arg in "$@"; do
    case "$arg" in
        --preflight-only)  PREFLIGHT_ONLY=1 ;;
        --skip-preflight)  SKIP_PREFLIGHT=1 ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//; $d'
            exit 0 ;;
        *) die "Unknown arg: $arg (try --help)" ;;
    esac
done

# ---- Preflight: required system packages -----------------------------------
preflight() {
    log "Preflight: checking system tools and headers"
    local missing_bins=() missing_libs=() missing_headers=()

    # Binaries that must be on PATH.
    # protoc / jansson were on this list when we planned to build vg from source;
    # vg is now provided externally (apt, conda, or guix) so neither is required.
    # autopoint is part of gettext on Debian but a separate concept on Guix;
    # it's only needed by autotools-using deps (none in this script), so dropped.
    local need_bins=(
        gcc g++ make cmake pkg-config git curl tar
        autoconf automake libtool m4
        python3 pip3
        cargo            # rust toolchain (Guix: install `rust:cargo`; apt: install rustup)
    )
    for b in "${need_bins[@]}"; do
        command -v "$b" >/dev/null 2>&1 || missing_bins+=("$b")
    done

    # pkg-config libraries (provide --cflags / --libs).
    # libcrypto/libssl come from openssl; jansson/protobuf dropped (see above).
    local need_pc=(libzstd libcrypto libssl zlib)
    for p in "${need_pc[@]}"; do
        pkg-config --exists "$p" 2>/dev/null || missing_libs+=("$p")
    done

    # Header probes for things without reliable .pc files
    cat >/tmp/_pf_omp.c <<'EOF'
#include <omp.h>
int main(void){return omp_get_max_threads();}
EOF
    if ! gcc -fopenmp /tmp/_pf_omp.c -o /tmp/_pf_omp 2>/dev/null; then
        missing_headers+=("OpenMP (libomp-dev on apt; bundled in gcc-toolchain on Guix)")
    fi
    rm -f /tmp/_pf_omp /tmp/_pf_omp.c

    for h in zlib.h bzlib.h lzma.h; do
        echo "#include <$h>" | gcc -E -xc - -o /dev/null 2>/dev/null \
            || missing_headers+=("$h")
    done

    # C++17 sanity check
    cat >/tmp/_pf_cxx.cpp <<'EOF'
#include <string_view>
int main(){std::string_view sv="ok";return sv.size()!=2;}
EOF
    g++ -std=c++17 /tmp/_pf_cxx.cpp -o /tmp/_pf_cxx 2>/dev/null \
        || missing_headers+=("C++17 (g++ >=9)")
    rm -f /tmp/_pf_cxx /tmp/_pf_cxx.cpp

    if [ ${#missing_bins[@]}    -eq 0 ] \
    && [ ${#missing_libs[@]}    -eq 0 ] \
    && [ ${#missing_headers[@]} -eq 0 ]; then
        ok "all preflight checks passed"
        return 0
    fi

    echo
    echo "Preflight FAILED — install the following before re-running:"
    [ ${#missing_bins[@]}    -gt 0 ] && echo "  Missing binaries:  ${missing_bins[*]}"
    [ ${#missing_libs[@]}    -gt 0 ] && echo "  Missing .pc libs:  ${missing_libs[*]}"
    [ ${#missing_headers[@]} -gt 0 ] && echo "  Missing headers:   ${missing_headers[*]}"
    echo
    echo "Pick the install path that matches your environment:"
    echo
    echo "--- If you have sudo + apt (Debian/Ubuntu): ---"
    cat <<'EOF'
  sudo apt-get install -y \
    build-essential git cmake pkg-config \
    libomp-dev libzstd-dev libssl-dev libbz2-dev liblzma-dev liblz4-dev \
    zlib1g-dev \
    autoconf automake libtool gettext m4 \
    python3 python3-pip curl cargo
EOF
    echo
    echo "--- If you have guix (per-user, no sudo): ---"
    cat <<'EOF'
  guix install \
    gcc-toolchain make cmake pkg-config coreutils \
    autoconf automake libtool gettext m4 \
    zstd zstd:lib openssl bzip2 xz lz4 zlib \
    python python-pip rust rust:cargo

  # Then re-source profile and retry:
  GUIX_PROFILE="$HOME/.guix-profile"; . "$GUIX_PROFILE/etc/profile"
EOF
    exit 1
}

[ "$SKIP_PREFLIGHT" -eq 1 ] || preflight
[ "$PREFLIGHT_ONLY" -eq 1 ] && exit 0

# ---- Environment setup -----------------------------------------------------
mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/include" "$PREFIX/lib/pkgconfig"

export CPATH="$PREFIX/include:${CPATH:-}"
export LIBRARY_PATH="$PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PATH="$PREFIX/bin:$HOME/.cargo/bin:$PATH"

# ---- Helpers ---------------------------------------------------------------
clone_or_update() {
    # $1 = repo url, $2 = target dir name (under $ROOT), $3 = branch (optional)
    local url="$1" name="$2" branch="${3:-}" dest="$ROOT/$2"
    if [ -d "$dest/.git" ]; then
        log "git fetch + checkout $name${branch:+ (branch: $branch)}"
        git -C "$dest" fetch --all --prune
        if [ -n "$branch" ]; then
            # Switch to the requested branch (creates a tracking branch if needed).
            git -C "$dest" checkout "$branch" 2>/dev/null \
                || git -C "$dest" checkout -b "$branch" "origin/$branch"
            git -C "$dest" pull --ff-only "origin" "$branch" \
                || warn "pull failed on $name/$branch; continuing with local state"
        else
            git -C "$dest" pull --ff-only \
                || warn "pull failed in $name; continuing with local state"
        fi
        # Show what we actually have, so the log captures it for FINDINGS.md.
        local sha; sha=$(git -C "$dest" rev-parse --short HEAD)
        ok "$name @ $(git -C "$dest" rev-parse --abbrev-ref HEAD) ($sha)"
    else
        log "git clone $name${branch:+ (branch: $branch)}"
        if [ -n "$branch" ]; then
            git clone --branch "$branch" --single-branch "$url" "$dest"
        else
            git clone "$url" "$dest"
        fi
    fi
}

# =============================================================================
# Shared-prefix install layout
# =============================================================================
# sdsl-lite, gbwt, gbwtgraph, libhandlegraph all install their headers + .a
# files into a single prefix ($PREFIX = ~/.local by default). This mirrors how
# the working Mac dev env is set up (everything under ~/include and ~/lib).
#
# Why this matters: gbwtgraph's Makefile sets INCLUDES=-Iinclude -I$(INC_DIR),
# where $(INC_DIR) comes from sdsl-lite/Make.helper. If gbwt's headers aren't
# alongside sdsl's in $(INC_DIR), gbwtgraph's compile fails with
#   fatal error: gbwt/gbwt.h: No such file or directory
# pangenome-index-latest's Makefile has the same shape.
#
# sdsl-lite's install.sh sets INC_DIR=<prefix>/include + LIB_DIR=<prefix>/lib
# in Make.helper, then every other project that includes Make.helper inherits
# them. So passing $PREFIX to install.sh wires up the entire chain.
#
# gbwt and gbwtgraph have NO `make install` target — we copy include/ + lib/
# into $PREFIX manually.

# ---- 1. sdsl-lite ----------------------------------------------------------
# install.sh <prefix>:
#   - builds sdsl + libdivsufsort
#   - copies headers     -> <prefix>/include/sdsl, <prefix>/include/divsufsort*.h
#   - copies static libs -> <prefix>/lib/libsdsl.a, libdivsufsort*.a
#   - writes Make.helper with INC_DIR=<prefix>/include, LIB_DIR=<prefix>/lib
if [ ! -f "$PREFIX/lib/libsdsl.a" ]; then
    clone_or_update "$SDSL_REPO" "sdsl-lite"
    log "build + install sdsl-lite into $PREFIX (this is slow, ~5 min)"
    # vgteam fork already handles CMake 4.x; no -DCMAKE_POLICY_VERSION_MINIMUM
    # escape hatch needed (their CMakeLists.txt declares 3.13).
    (cd "$ROOT/sdsl-lite" && ./install.sh "$PREFIX")
    ok "sdsl-lite installed to $PREFIX (libsdsl.a, headers, Make.helper)"
else
    ok "sdsl-lite already installed in $PREFIX"
fi

# ---- 2. gbwt ---------------------------------------------------------------
# gbwt has no `install` target. Build with SDSL_DIR pointing at our $PREFIX
# (it reads Make.helper from there to find INC_DIR/LIB_DIR), then manually
# copy headers + lib into $PREFIX.
if [ ! -f "$PREFIX/lib/libgbwt.a" ]; then
    clone_or_update "$GBWT_REPO" "gbwt"
    log "build gbwt (SDSL_DIR=$PREFIX/include/sdsl from Make.helper)"
    # Trick: sdsl's install.sh dropped Make.helper next to its headers, but
    # gbwt expects SDSL_DIR to be a *source* tree (it includes Make.helper
    # via $(SDSL_DIR)/Make.helper). The simplest fix is to keep SDSL_DIR
    # pointing at the source clone, where Make.helper still lives.
    make -C "$ROOT/gbwt" -j"$JOBS" SDSL_DIR="$ROOT/sdsl-lite"
    log "install gbwt headers + lib into $PREFIX"
    mkdir -p "$PREFIX/include/gbwt" "$PREFIX/lib"
    cp -r "$ROOT/gbwt/include/gbwt/." "$PREFIX/include/gbwt/"
    cp    "$ROOT/gbwt/lib/libgbwt.a"  "$PREFIX/lib/"
    ok "gbwt installed to $PREFIX (libgbwt.a, gbwt/*.h)"
else
    ok "gbwt already installed in $PREFIX"
fi

# ---- 3. libhandlegraph (cmake-based, has proper install target) ------------
if [ ! -f "$PREFIX/lib/libhandlegraph.a" ] && [ ! -f "$PREFIX/lib/libhandlegraph.so" ]; then
    clone_or_update "$LIBHG_REPO" "libhandlegraph"
    log "build + install libhandlegraph to $PREFIX"
    mkdir -p "$ROOT/libhandlegraph/build"
    (cd "$ROOT/libhandlegraph/build" \
        && cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" \
                 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
                 .. \
        && make -j"$JOBS" \
        && make install)
    ok "libhandlegraph installed to $PREFIX"
else
    ok "libhandlegraph already installed at $PREFIX"
fi

# ---- 4. gbwtgraph (provides gbz_stats, gbz_extract, gfa2gbwt) --------------
# Same no-install-target pattern as gbwt. Build with SDSL_DIR pointing at
# sdsl source, then copy headers + lib into $PREFIX so pangenome-index-latest
# can link against them.
if [ ! -x "$ROOT/gbwtgraph/bin/gbz_stats" ]; then
    clone_or_update "$GBWTGRAPH_REPO" "gbwtgraph"
    log "build gbwtgraph (SDSL_DIR=$ROOT/sdsl-lite, gbwt/handlegraph via \$PREFIX)"
    make -C "$ROOT/gbwtgraph" -j"$JOBS" SDSL_DIR="$ROOT/sdsl-lite"
    log "install gbwtgraph headers + lib into $PREFIX"
    mkdir -p "$PREFIX/include/gbwtgraph"
    cp -r "$ROOT/gbwtgraph/include/gbwtgraph/." "$PREFIX/include/gbwtgraph/"
    cp    "$ROOT/gbwtgraph/lib/libgbwtgraph.a"  "$PREFIX/lib/"
    ok "gbwtgraph built + installed; binaries in $ROOT/gbwtgraph/bin"
else
    ok "gbwtgraph already built"
fi

# ---- 5. grlBWT (provides grlbwt-cli) ---------------------------------------
# Only grlbwt-cli is consumed by the pipeline (run.sh step 03). The auxiliary
# tools (bwt_stats, grlbwt2rle, reverse_bwt, split_runs, grl2plain) are not
# used. bwt_stats.cpp has a real upstream bug — calls std::sort without
# #include <algorithm> — that newer libstdc++ (gcc 13+) refuses to fix
# transitively. Rather than patch the source, we treat the overall `make`
# failure as non-fatal as long as grlbwt-cli itself got built.
if [ ! -x "$ROOT/grlBWT/build/grlbwt-cli" ]; then
    clone_or_update "$GRLBWT_REPO" "grlBWT"
    log "build grlBWT"
    mkdir -p "$ROOT/grlBWT/build"
    # grlBWT's CMake uses find_package(LibSDSL). FindLibSDSL.cmake hardcodes
    # $HOME/{include,lib} as a search path (no respect for CMAKE_PREFIX_PATH),
    # which is why we set PREFIX=$HOME so sdsl ends up where it can be found.
    # CMAKE_POLICY_VERSION_MINIMUM=3.5 defends against CMake 4.x dropping
    # pre-3.5 policy compatibility; harmless for projects already on ≥3.5.
    (cd "$ROOT/grlBWT/build" \
        && cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..) \
        || die "grlBWT cmake configure failed"
    # Don't fail the whole bootstrap if an aux tool's source doesn't compile
    # under newer gcc; only the grlbwt-cli binary is required downstream.
    (cd "$ROOT/grlBWT/build" && make -j"$JOBS") \
        || warn "grlBWT make returned non-zero — checking for grlbwt-cli"
    if [ -x "$ROOT/grlBWT/build/grlbwt-cli" ]; then
        ok "grlBWT built; grlbwt-cli at $ROOT/grlBWT/build/grlbwt-cli (aux tools may be missing — harmless)"
    else
        die "grlBWT build failed: grlbwt-cli was not produced (see make output above)"
    fi
else
    ok "grlBWT already built"
fi

# ---- 6. pangenome-index-latest ---------------------------------------------
# Note: the repo's actual name may be "pangenome-index-pvt"; rename to the
# directory name run.sh expects so $PI_BIN works without further overrides.
if [ ! -x "$ROOT/$PI_DIR_NAME/bin/find_mems" ]; then
    if [ ! -d "$ROOT/$PI_DIR_NAME/.git" ]; then
        # --recursive is REQUIRED per docs/getting-started/install-and-build.md.
        # pangenome-index has a submodule at deps/grlBWT, and its makefile
        # links against deps/grlBWT/build/libgrlbwt.a (the embedded build),
        # NOT the top-level ~/grlBWT we built for grlbwt-cli. Without --recursive
        # the submodule is empty and the make `grlbwt` target fails with
        # "deps/grlBWT/build: No such file or directory" or similar.
        log "git clone --recursive $PI_REPO (branch: $PI_BRANCH) -> $PI_DIR_NAME"
        git clone --recursive --branch "$PI_BRANCH" --single-branch "$PI_REPO" "$ROOT/$PI_DIR_NAME"
    else
        log "git fetch + checkout $PI_DIR_NAME (branch: $PI_BRANCH)"
        git -C "$ROOT/$PI_DIR_NAME" fetch --all --prune
        git -C "$ROOT/$PI_DIR_NAME" checkout "$PI_BRANCH" 2>/dev/null \
            || git -C "$ROOT/$PI_DIR_NAME" checkout -b "$PI_BRANCH" "origin/$PI_BRANCH"
        git -C "$ROOT/$PI_DIR_NAME" pull --ff-only origin "$PI_BRANCH" \
            || warn "pull failed on $PI_DIR_NAME/$PI_BRANCH; continuing"
        # Ensure submodules track the branch's pinned commits (handles the
        # case where the bootstrap was previously run before --recursive was
        # added, or where pulling brought in submodule pointer updates).
        git -C "$ROOT/$PI_DIR_NAME" submodule update --init --recursive
    fi
    ok "$PI_DIR_NAME @ $(git -C "$ROOT/$PI_DIR_NAME" rev-parse --abbrev-ref HEAD) ($(git -C "$ROOT/$PI_DIR_NAME" rev-parse --short HEAD))"

    # Pre-build the embedded deps/grlBWT. Reason: pangenome-index's makefile
    # target is literally
    #     grlbwt:
    #         cd deps/grlBWT/build && cmake .. && make
    # The `cmake ..` part works because deps/grlBWT/cmake/Modules/FindLibSDSL.cmake
    # hardcodes $HOME/include and $HOME/lib as search paths (which is why we
    # set PREFIX=$HOME at the top of this script). But the `make` part will
    # fail on the bwt_stats aux tool under gcc 15 (missing <algorithm>
    # include), aborting the whole pangenome-index build before find_mems
    # gets linked. So we run the steps ourselves and tolerate aux-tool
    # failures as long as libgrlbwt.a is produced.
    if [ ! -f "$ROOT/$PI_DIR_NAME/deps/grlBWT/build/libgrlbwt.a" ]; then
        log "pre-build embedded deps/grlBWT (tolerating aux-tool gcc 15 failures)"
        mkdir -p "$ROOT/$PI_DIR_NAME/deps/grlBWT/build"
        (cd "$ROOT/$PI_DIR_NAME/deps/grlBWT/build" \
            && cmake -DCMAKE_POLICY_VERSION_MINIMUM=3.5 ..) \
            || die "embedded deps/grlBWT cmake configure failed"
        (cd "$ROOT/$PI_DIR_NAME/deps/grlBWT/build" && make -j"$JOBS") \
            || warn "embedded deps/grlBWT make returned non-zero — checking libgrlbwt.a"
        [ -f "$ROOT/$PI_DIR_NAME/deps/grlBWT/build/libgrlbwt.a" ] \
            || die "embedded deps/grlBWT build failed: libgrlbwt.a not produced"
        ok "embedded deps/grlBWT: libgrlbwt.a built"
    fi

    log "build pangenome-index-latest"
    # SDSL_DIR points at the sdsl-lite source tree (where Make.helper lives,
    # which has INC_DIR=$PREFIX/include + LIB_DIR=$PREFIX/lib written by
    # install.sh). The makefile defaults to ../sdsl-lite (relative path),
    # which only works if you happen to run make from $ROOT — fragile.
    (cd "$ROOT/$PI_DIR_NAME" && make -j"$JOBS" SDSL_DIR="$ROOT/sdsl-lite")
    ok "pangenome-index-latest built; binaries in $ROOT/$PI_DIR_NAME/bin"
else
    ok "pangenome-index-latest already built"
fi

# ---- 7. Rust toolchain (for gafpack) ---------------------------------------
if ! command -v cargo >/dev/null 2>&1; then
    log "install rustup + stable toolchain into \$HOME/.cargo (per-user)"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --no-modify-path
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
    ok "rust installed: $(rustc --version)"
else
    ok "rust already present: $(rustc --version)"
fi

# ---- 8. gafpack ------------------------------------------------------------
if [ ! -x "$ROOT/$GAFPACK_DIR_NAME/target/release/gafpack" ]; then
    clone_or_update "$GAFPACK_REPO" "$GAFPACK_DIR_NAME" "$GAFPACK_BRANCH"
    log "cargo build --release gafpack"
    (cd "$ROOT/$GAFPACK_DIR_NAME" && cargo build --release)
    ok "gafpack built at $ROOT/$GAFPACK_DIR_NAME/target/release/gafpack"
else
    ok "gafpack already built"
fi

# ---- 9. mem-projection (the pipeline repo itself) --------------------------
if [ ! -d "$ROOT/$MEM_DIR_NAME/.git" ]; then
    clone_or_update "$MEM_REPO" "$MEM_DIR_NAME" "$MEM_BRANCH"
else
    ok "mem-projection clone present (not auto-pulling; pull manually if needed)"
fi

# ---- 10. gaftools (Python) -------------------------------------------------
# On Debian 13 + Python 3.13 (incl. Guix's python), `pip install --user` hits
# PEP 668 "externally managed environment". The clean answer is a per-tool
# venv at $HOME/.venvs/gaftools — fully isolated, no system mutation, and the
# script symlinks its entrypoint into $PREFIX/bin so $PATH discovery still works.
if ! command -v gaftools >/dev/null 2>&1; then
    GAFTOOLS_VENV="$HOME/.venvs/gaftools"
    if [ ! -x "$GAFTOOLS_VENV/bin/gaftools" ]; then
        log "create venv at $GAFTOOLS_VENV and install gaftools"
        python3 -m venv "$GAFTOOLS_VENV"
        "$GAFTOOLS_VENV/bin/pip" install --upgrade pip
        "$GAFTOOLS_VENV/bin/pip" install gaftools
    fi
    ln -sf "$GAFTOOLS_VENV/bin/gaftools" "$PREFIX/bin/gaftools"
    ok "gaftools installed via venv: $PREFIX/bin/gaftools -> $GAFTOOLS_VENV/bin/gaftools"
else
    ok "gaftools already on PATH: $(command -v gaftools)"
fi

# ---- 11. Persistent shell env ---------------------------------------------
# Drop a single file that the user can `source` (or chain from ~/.bashrc) so
# subsequent shells find headers, libs, and binaries without re-exporting.
ENVFILE="$HOME/.pangenome_env.sh"
cat > "$ENVFILE" <<EOF
# Auto-generated by bootstrap_vesuvio.sh on $(date)
# Source from ~/.bashrc:   [ -f \$HOME/.pangenome_env.sh ] && . \$HOME/.pangenome_env.sh
export PREFIX="$PREFIX"
export CPATH="\$PREFIX/include:\${CPATH:-}"
export LIBRARY_PATH="\$PREFIX/lib:\${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="\$PREFIX/lib:\${LD_LIBRARY_PATH:-}"
export PKG_CONFIG_PATH="\$PREFIX/lib/pkgconfig:\${PKG_CONFIG_PATH:-}"

# Tool dirs on PATH (mirrors the Mac dev setup's zshrc).
# Lets you call find_mems, gafpack, gbz_stats, grlbwt-cli, vg directly
# instead of via \$PI_BIN / \$GAFPACK etc.
export PATH="$ROOT/$PI_DIR_NAME/bin:\$PATH"
export PATH="$ROOT/$GAFPACK_DIR_NAME/target/release:\$PATH"
export PATH="$ROOT/grlBWT/build:\$PATH"
export PATH="$ROOT/gbwtgraph/bin:\$PATH"
export PATH="\$PREFIX/bin:\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH"

# Pipeline tool locations (consumed by mem-projection/pangenome-pipeline/run.sh)
export PI_BIN="$ROOT/$PI_DIR_NAME/bin"
export GAFPACK="$ROOT/$GAFPACK_DIR_NAME/target/release/gafpack"
export GRLBWT="$ROOT/grlBWT/build/grlbwt-cli"
export GBZ_STATS="$ROOT/gbwtgraph/bin/gbz_stats"
export GBZ_EXTRACT="$ROOT/gbwtgraph/bin/gbz_extract"
# vg: use whatever's on PATH (Guix profile / apt / source-built).
# If multiple installs exist, override here with an absolute path.
export VG="\$(command -v vg)"
EOF

if ! grep -qs '.pangenome_env.sh' "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# pangenome-pipeline env\n[ -f $HOME/.pangenome_env.sh ] && . $HOME/.pangenome_env.sh\n' \
        >> "$HOME/.bashrc"
    ok "appended source line to ~/.bashrc"
fi
ok "env file written to $ENVFILE"

# ---- Summary ---------------------------------------------------------------
echo
echo "============================================================"
echo "  Bootstrap complete (vg deferred)."
echo "============================================================"
printf "  %-22s %s\n" \
    "sdsl-lite"          "$ROOT/sdsl-lite" \
    "gbwt"               "$ROOT/gbwt" \
    "libhandlegraph"     "$PREFIX  (headers+libs)" \
    "gbwtgraph"          "$ROOT/gbwtgraph/bin/{gbz_stats,gbz_extract,gfa2gbwt}" \
    "grlBWT"             "$ROOT/grlBWT/build/grlbwt-cli" \
    "pangenome-index"    "$ROOT/$PI_DIR_NAME/bin/" \
    "gafpack"            "$ROOT/$GAFPACK_DIR_NAME/target/release/gafpack" \
    "mem-projection"     "$ROOT/$MEM_DIR_NAME" \
    "gaftools"           "$(command -v gaftools)" \
    "env file"           "$ENVFILE"
echo
echo "Next steps:"
echo "  1. source \$HOME/.pangenome_env.sh    (or start a new shell)"
echo "  2. Build vg later, then add  export VG=\$HOME/vg/bin/vg  to $ENVFILE"
echo "  3. cd $ROOT/$MEM_DIR_NAME/pangenome-pipeline  &&  ./run.sh <config.env> <tag>"
echo
echo "NOTE: step 01b (vg convert) WILL FAIL until vg is installed."
echo "      Steps 01..08 still need vg for 01b. To run the rest of the"
echo "      pipeline standalone, install vg first."
