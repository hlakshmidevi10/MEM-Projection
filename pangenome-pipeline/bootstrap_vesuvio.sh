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
PREFIX="${PREFIX:-$HOME/.local}"
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

SDSL_REPO="https://github.com/simongog/sdsl-lite.git"
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

# ---- 1. sdsl-lite ----------------------------------------------------------
# Header-only-ish; install into ~/sdsl-lite itself (its install.sh deposits
# include/ and lib/ next to the source). pangenome-index-latest and gbwtgraph
# expect SDSL_DIR=../sdsl-lite (sibling layout), which is what we get because
# everything lives under $ROOT.
if [ ! -f "$ROOT/sdsl-lite/lib/libsdsl.a" ]; then
    clone_or_update "$SDSL_REPO" "sdsl-lite"
    log "build sdsl-lite (this is slow, ~5 min)"
    (cd "$ROOT/sdsl-lite" && ./install.sh "$ROOT/sdsl-lite")
    ok "sdsl-lite installed in-tree at $ROOT/sdsl-lite"
else
    ok "sdsl-lite already built (lib/libsdsl.a present)"
fi

# ---- 2. gbwt ---------------------------------------------------------------
if [ ! -f "$ROOT/gbwt/lib/libgbwt.a" ]; then
    clone_or_update "$GBWT_REPO" "gbwt"
    log "build gbwt"
    make -C "$ROOT/gbwt" -j"$JOBS"
    ok "gbwt built"
else
    ok "gbwt already built"
fi

# ---- 3. libhandlegraph (installs to $PREFIX) -------------------------------
if [ ! -f "$PREFIX/lib/libhandlegraph.a" ] && [ ! -f "$PREFIX/lib/libhandlegraph.so" ]; then
    clone_or_update "$LIBHG_REPO" "libhandlegraph"
    log "build + install libhandlegraph to $PREFIX"
    mkdir -p "$ROOT/libhandlegraph/build"
    (cd "$ROOT/libhandlegraph/build" \
        && cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" .. \
        && make -j"$JOBS" \
        && make install)
    ok "libhandlegraph installed to $PREFIX"
else
    ok "libhandlegraph already installed at $PREFIX"
fi

# Also drop a symlink so things expecting sibling layout (../libhandlegraph)
# find headers — gbwtgraph & pangenome-index-latest link against the version
# we just installed, so this is belt-and-suspenders.

# ---- 4. gbwtgraph (provides gbz_stats, gbz_extract, gfa2gbwt) --------------
if [ ! -x "$ROOT/gbwtgraph/bin/gbz_stats" ]; then
    clone_or_update "$GBWTGRAPH_REPO" "gbwtgraph"
    log "build gbwtgraph"
    # gbwtgraph's Makefile picks up SDSL via ../sdsl-lite/Make.helper and
    # libgbwt/libhandlegraph via -L../gbwt/lib + $LIBRARY_PATH (for $PREFIX).
    make -C "$ROOT/gbwtgraph" -j"$JOBS"
    ok "gbwtgraph built; binaries in $ROOT/gbwtgraph/bin"
else
    ok "gbwtgraph already built"
fi

# ---- 5. grlBWT (provides grlbwt-cli) ---------------------------------------
if [ ! -x "$ROOT/grlBWT/build/grlbwt-cli" ]; then
    clone_or_update "$GRLBWT_REPO" "grlBWT"
    log "build grlBWT"
    mkdir -p "$ROOT/grlBWT/build"
    # grlBWT's CMake uses find_package(LibSDSL); point it at our sibling sdsl.
    (cd "$ROOT/grlBWT/build" \
        && cmake -DCMAKE_PREFIX_PATH="$ROOT/sdsl-lite;$PREFIX" .. \
        && make -j"$JOBS")
    ok "grlBWT built; grlbwt-cli at $ROOT/grlBWT/build/grlbwt-cli"
else
    ok "grlBWT already built"
fi

# ---- 6. pangenome-index-latest ---------------------------------------------
# Note: the repo's actual name may be "pangenome-index-pvt"; rename to the
# directory name run.sh expects so $PI_BIN works without further overrides.
if [ ! -x "$ROOT/$PI_DIR_NAME/bin/find_mems" ]; then
    if [ ! -d "$ROOT/$PI_DIR_NAME/.git" ]; then
        log "git clone $PI_REPO (branch: $PI_BRANCH) -> $PI_DIR_NAME"
        git clone --branch "$PI_BRANCH" --single-branch "$PI_REPO" "$ROOT/$PI_DIR_NAME"
    else
        log "git fetch + checkout $PI_DIR_NAME (branch: $PI_BRANCH)"
        git -C "$ROOT/$PI_DIR_NAME" fetch --all --prune
        git -C "$ROOT/$PI_DIR_NAME" checkout "$PI_BRANCH" 2>/dev/null \
            || git -C "$ROOT/$PI_DIR_NAME" checkout -b "$PI_BRANCH" "origin/$PI_BRANCH"
        git -C "$ROOT/$PI_DIR_NAME" pull --ff-only origin "$PI_BRANCH" \
            || warn "pull failed on $PI_DIR_NAME/$PI_BRANCH; continuing"
    fi
    ok "$PI_DIR_NAME @ $(git -C "$ROOT/$PI_DIR_NAME" rev-parse --abbrev-ref HEAD) ($(git -C "$ROOT/$PI_DIR_NAME" rev-parse --short HEAD))"
    log "build pangenome-index-latest (slow; pulls deps/grlBWT internally)"
    # Makefile expects sibling sdsl-lite, gbwt (already at $ROOT). It also
    # links -lgbwtgraph from $LIBRARY_PATH; export it explicitly for safety.
    (cd "$ROOT/$PI_DIR_NAME" \
        && LIBRARY_PATH="$ROOT/gbwtgraph/lib:$ROOT/gbwt/lib:$LIBRARY_PATH" \
           CPATH="$ROOT/gbwtgraph/include:$ROOT/gbwt/include:$CPATH" \
           make -j"$JOBS")
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
