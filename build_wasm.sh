#!/usr/bin/env bash
# build_wasm.sh — build FFmpeg static libraries for Odin's WebAssembly imports.
#
# Usage:
#   ./build_wasm.sh
#
# Output:
#   avutil.wasm.a, avcodec.wasm.a, avformat.wasm.a, avfilter.wasm.a,
#   swscale.wasm.a, swresample.wasm.a, avdevice.wasm.a
#
# Web has no shared-library mode. The final Emscripten application link supplies
# the JavaScript/WASM runtime and pulls these archives through the Odin bindings.

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT"

SRC="$ROOT/FFmpeg"
SRC_REMOTE="${FFMPEG_SRC_REMOTE:-https://github.com/FFmpeg/FFmpeg.git}"
EMCONFIGURE_BIN="${EMCONFIGURE:-emconfigure}"
EMMAKE_BIN="${EMMAKE:-emmake}"
EMCC_BIN="${EMCC:-emcc}"
EMAR_BIN="${EMAR:-emar}"
EMRANLIB_BIN="${EMRANLIB:-emranlib}"
EMNM_BIN="${EMNM:-emnm}"
EMSTRIP_BIN="${EMSTRIP:-emstrip}"

if [ -e "$SRC" ] && [ ! -d "$SRC/.git" ]; then
    echo "ERROR: $SRC exists but is not a Git checkout. Move it aside and retry." >&2
    exit 1
fi
if [ ! -d "$SRC/.git" ]; then
    echo "==> FFmpeg source missing. Cloning $SRC_REMOTE"
    git clone --depth=1 "$SRC_REMOTE" "$SRC"
fi
if [ ! -f "$SRC/configure" ]; then
    echo "ERROR: FFmpeg source not found at $SRC/configure after clone attempt." >&2
    exit 1
fi

require_command() {
    local name="$1"
    local fix="$2"
    if ! command -v "$name" >/dev/null 2>&1; then
        echo "ERROR: $name not found." >&2
        echo "Fix: $fix" >&2
        exit 1
    fi
}

require_command git "Install Git."
require_command "$EMCONFIGURE_BIN" "Install Emscripten and expose emconfigure on PATH."
require_command "$EMMAKE_BIN" "Install Emscripten and expose emmake on PATH."
require_command "$EMCC_BIN" "Install Emscripten and expose emcc on PATH."
require_command "$EMAR_BIN" "Install Emscripten and expose emar on PATH."
require_command "$EMRANLIB_BIN" "Install Emscripten and expose emranlib on PATH."
require_command "$EMNM_BIN" "Install Emscripten and expose emnm on PATH."
require_command "$EMSTRIP_BIN" "Install Emscripten and expose emstrip on PATH."
require_command make "Install GNU Make."

if [ "$(uname -s)" = "Darwin" ]; then
    CPUS="$(sysctl -n hw.ncpu)"
else
    CPUS="$(nproc)"
fi

BUILD_DIR="${FFMPEG_WASM_BUILD_DIR:-$SRC/build_wasm}"
FFMPEG_WASM_CFLAGS="${FFMPEG_WASM_CFLAGS:--O2 -pthread}"
FFMPEG_WASM_LDFLAGS="${FFMPEG_WASM_LDFLAGS:--pthread}"

echo "==> Configuring FFmpeg (static WebAssembly): prefix=$BUILD_DIR"
cd "$SRC"
"$EMCONFIGURE_BIN" ./configure \
    --prefix="$BUILD_DIR" \
    --cc="$EMCC_BIN" \
    --ar="$EMAR_BIN" \
    --ranlib="$EMRANLIB_BIN" \
    --nm="$EMNM_BIN" \
    --strip="$EMSTRIP_BIN" \
    --arch=x86 \
    --target-os=none \
    --enable-cross-compile \
    --enable-static \
    --disable-shared \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-network \
    --disable-autodetect \
    --disable-asm \
    --disable-inline-asm \
    --disable-runtime-cpudetect \
    --disable-fast-unaligned \
    --enable-pthreads \
    --disable-w32threads \
    --disable-os2threads \
    --disable-iconv \
    --disable-zlib \
    --disable-bzlib \
    --disable-lzma \
    --disable-stripping \
    --extra-cflags="$FFMPEG_WASM_CFLAGS" \
    --extra-ldflags="$FFMPEG_WASM_LDFLAGS"

echo "==> Building (using $CPUS cores)..."
"$EMMAKE_BIN" make -j"$CPUS"

echo "==> Installing static libraries to $BUILD_DIR..."
"$EMMAKE_BIN" make install-libs

LIBS=(avutil avcodec avformat avfilter swscale swresample avdevice)
for lib in "${LIBS[@]}"; do
    source="$BUILD_DIR/lib/lib${lib}.a"
    destination="$ROOT/${lib}.wasm.a"
    if [ ! -f "$source" ]; then
        echo "ERROR: FFmpeg did not produce $source." >&2
        exit 1
    fi
    cp -f "$source" "$destination"
    echo "    $(basename "$destination")"
done

echo "==> Done. Web static libraries written to $ROOT/"
