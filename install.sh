#!/usr/bin/env bash
# install.sh -- build MEM-Projection and its dependencies into one prefix.
#
# Usage:  ./install.sh [PREFIX]          default PREFIX: ~/.mem-projection
#         JOBS=16 ./install.sh           parallel build jobs (default: all cores)
#
# Then:   source PREFIX/env.sh
#
# Needs a C++17 compiler with OpenMP, cmake, make, pkg-config, git, curl, cargo,
# and the OpenSSL, zstd and zlib development headers. Everything is built into
# PREFIX (cargo keeps its download cache in ~/.cargo). Re-running skips anything
# already built at the pinned commit.
set -euo pipefail

PREFIX="${1:-$HOME/.mem-projection}"
mkdir -p "$PREFIX"/{bin,include,lib,src,logs}
PREFIX="$(cd "$PREFIX" && pwd)"
SRC="$PREFIX/src"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
OS="$(uname -s)"

# name                 repository                                              commit
PINS="
sdsl-lite              https://github.com/vgteam/sdsl-lite.git                 349de444ded81547cb55a718abeada41960531b5
libhandlegraph         https://github.com/vgteam/libhandlegraph.git            b95f7637968b4c8c3c4d1bad13aaa1835c607fe0
gbwt                   https://github.com/jltsiren/gbwt.git                    9e92e4f11bafcb1df92df9adf5991199c0f09f61
gbwtgraph              https://github.com/jltsiren/gbwtgraph.git               8649f806a1fb332ad9090a76c6f0b7583219ef0a
pangenome-index-pvt    https://github.com/hlakshmidevi10/pangenome-index-pvt.git 5355200d6e4ad16018562ead92e7b1a396f95de7
path-walker            https://github.com/hlakshmidevi10/path-walker.git       715a326aec8544bd97152f65d55f1d44638a1607
"
VG_VERSION="v1.71.0"

log() { printf '[install] %s\n' "$*"; }
die() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- Toolchain --------------------------------------------------------------
if [ "$OS" = Darwin ]; then
    command -v brew >/dev/null || die "Homebrew is required on macOS (https://brew.sh)"
    LLVM="$(brew --prefix llvm@17 2>/dev/null || true)"
    [ -x "$LLVM/bin/clang++" ] || die "missing Homebrew LLVM; run: brew install llvm@17 libomp cmake zstd zlib openssl@3 pkg-config rust"
    export PATH="$LLVM/bin:$PATH" CC="$LLVM/bin/clang" CXX="$LLVM/bin/clang++"
    for f in libomp zstd zlib openssl@3; do
        p="$(brew --prefix $f 2>/dev/null || true)"
        [ -d "$p/lib" ] || die "missing $f; run: brew install $f"
        CPPFLAGS="-I$p/include ${CPPFLAGS:-}"; LDFLAGS="-L$p/lib ${LDFLAGS:-}"
        PKG_CONFIG_PATH="$p/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    done
    export CPPFLAGS LDFLAGS PKG_CONFIG_PATH CFLAGS="$CPPFLAGS"
    HINT="brew install llvm@17 libomp cmake zstd zlib openssl@3 pkg-config rust"
else
    command -v cc >/dev/null || export CC="${CC:-gcc}" CXX="${CXX:-g++}"
    HINT="sudo apt install build-essential cmake pkg-config libssl-dev libzstd-dev zlib1g-dev cargo git curl   (or ask your admin)"
fi
CXX="${CXX:-c++}"

missing=""
for t in git curl cmake make pkg-config cargo "$CXX"; do
    command -v "$t" >/dev/null || missing="$missing $t"
done
[ -z "$missing" ] || die "missing:$missing; install with: $HINT"
echo 'int main(){}' | "$CXX" -fopenmp ${CPPFLAGS:-} ${LDFLAGS:-} -x c++ - -o "$PREFIX/logs/omp_test" 2>/dev/null \
    || die "$CXX cannot build with OpenMP; install with: $HINT"
pkg-config --exists libcrypto libzstd || die "OpenSSL or zstd headers not found by pkg-config; install with: $HINT"

# ---- Sources ----------------------------------------------------------------
# step NAME CMD...: run CMD in $SRC/NAME once per pinned commit, logging to logs/NAME.log.
step() {
    local name=$1 commit; shift
    commit="$(echo "$PINS" | awk -v n="$name" '$1==n {print $3}')"
    [ -f "$PREFIX/logs/$name.done" ] && [ "$(cat "$PREFIX/logs/$name.done")" = "$commit" ] \
        && { log "$name: already built"; return; }
    log "$name: building"
    ( cd "$SRC/$name" && "$@" ) > "$PREFIX/logs/$name.log" 2>&1 \
        || { tail -n 20 "$PREFIX/logs/$name.log" >&2; die "$name failed; full log: $PREFIX/logs/$name.log"; }
    echo "$commit" > "$PREFIX/logs/$name.done"
}

echo "$PINS" | while read -r name url commit; do
    [ -n "$name" ] || continue
    [ -d "$SRC/$name/.git" ] || git clone -q "$url" "$SRC/$name"
    git -C "$SRC/$name" checkout -q --detach "$commit" 2>/dev/null \
        || { git -C "$SRC/$name" fetch -q origin && git -C "$SRC/$name" checkout -q --detach "$commit"; }
    git -C "$SRC/$name" submodule update -q --init --recursive
done
echo "$PINS" | awk 'NF==3 {print $1 "\t" $3}' > "$PREFIX/versions.tsv"
echo "vg	$VG_VERSION" >> "$PREFIX/versions.tsv"

# ---- Build ------------------------------------------------------------------
# sdsl-lite writes sdsl-lite/Make.helper, which gbwt, gbwtgraph and
# pangenome-index include to find $PREFIX/include and $PREFIX/lib.
step sdsl-lite ./install.sh "$PREFIX"

# Static library only, so nothing needs LD_LIBRARY_PATH at run time.
step libhandlegraph sh -c "
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX='$PREFIX' -DCMAKE_INSTALL_LIBDIR=lib &&
    cmake --build build -j $JOBS && cmake --install build &&
    rm -f '$PREFIX'/lib/libhandlegraph.so* '$PREFIX'/lib/libhandlegraph*.dylib"

# gbwt and gbwtgraph have no install target.
step gbwt sh -c "make -j $JOBS && cp -r include/gbwt '$PREFIX/include/' && cp lib/libgbwt.a '$PREFIX/lib/'"
step gbwtgraph sh -c "
    make -j $JOBS && cp -r include/gbwtgraph '$PREFIX/include/' && cp lib/libgbwtgraph.a '$PREFIX/lib/' &&
    cp bin/gbz_extract bin/gbz_stats bin/gfa2gbwt '$PREFIX/bin/'"

# grlBWT's FindLibSDSL only searches \$HOME, so configure the submodule with
# explicit SDSL paths first; the makefile's 'grlbwt' target reuses that cache.
PI_TOOLS="build_tags convert_tags build_rindex build_lightweight_tags path_extract find_mems print_stats verify_tag_runs build_tag_head_samples"
step pangenome-index-pvt sh -c "
    cmake -S deps/grlBWT -B deps/grlBWT/build -DCMAKE_BUILD_TYPE=Release \
        -DLIBSDSL_INCLUDE_DIR='$PREFIX/include' -DLIBSDSL_LIBRARY='$PREFIX/lib/libsdsl.a' \
        -DLIBDIVSUF_LIBRARY='$PREFIX/lib/libdivsufsort.a' -DLIBDIVSUF64_LIBRARY='$PREFIX/lib/libdivsufsort64.a' &&
    make -j $JOBS grlbwt directories && make -j $JOBS $(printf 'bin/%s ' $PI_TOOLS) &&
    cp $(printf 'bin/%s ' $PI_TOOLS) deps/grlBWT/build/grlbwt-cli '$PREFIX/bin/'"

step path-walker sh -c "cargo build --release --locked && cp target/release/path-walker '$PREFIX/bin/'"

# ---- vg (Linux release binaries only) ---------------------------------------
if [ "$OS" = Linux ]; then
    case "$(uname -m)" in
        x86_64)  asset=vg ;;
        aarch64) asset=vg-arm64 ;;
        *)       die "no vg release binary for $(uname -m)" ;;
    esac
    have="$("$PREFIX/bin/vg" version 2>/dev/null || true)"
    case "$have" in
        *"$VG_VERSION"*) log "vg: already installed" ;;
        *)  log "vg: downloading $VG_VERSION"
            curl -fsSL -o "$PREFIX/bin/vg" "https://github.com/vgteam/vg/releases/download/$VG_VERSION/$asset"
            chmod +x "$PREFIX/bin/vg" ;;
    esac
else
    log "vg: no macOS release binary; queries work, but build_index.sh needs vg on PATH"
fi

# ---- Environment ------------------------------------------------------------
cat > "$PREFIX/env.sh" <<EOF
export MEM_PROJECTION_HOME="$PREFIX"
export PATH="$PREFIX/bin:\$PATH"
EOF

# ---- Check ------------------------------------------------------------------
# find_mems with no arguments prints its usage and exits 1.
case "$("$PREFIX/bin/find_mems" 2>&1 || true)" in
    Usage*) ;;
    *) die "find_mems does not run; see $PREFIX/logs/pangenome-index-pvt.log" ;;
esac
"$PREFIX/bin/path-walker" --version
if [ -x "$PREFIX/bin/vg" ]; then
    v="$("$PREFIX/bin/vg" version)"; echo "${v%%$'\n'*}"
fi
log "done. Run:  source $PREFIX/env.sh"
