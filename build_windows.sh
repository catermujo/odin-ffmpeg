#!/usr/bin/env bash
# build_windows.sh — build vendored FFmpeg on Windows using MSVC toolchain.
#
# Usage:
#   ./build_windows.sh shared [x86_64]
#   ./build_windows.sh static [x86_64]
#
# Requirements:
#   - Run from a shell where MSVC tools are available (cl.exe/link.exe).
#   - bash + make available (Git Bash/MSYS2).

set -euo pipefail

MODE="${1:-shared}"
TARGET_ARCH="${2:-x86_64}"

case "$MODE" in
shared | static) ;;
*)
    echo "Usage: $0 <shared|static> [x86_64]" >&2
    exit 1
    ;;
esac

case "$TARGET_ARCH" in
x86_64 | amd64)
    FFMPEG_ARCH="x86_64"
    FFMPEG_TARGET_OS="win64"
    ;;
*)
    echo "Error: Unsupported target arch '$TARGET_ARCH' (expected x86_64)." >&2
    exit 1
    ;;
esac

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/FFmpeg"

if [ ! -f "$SRC/configure" ]; then
    echo "Error: FFmpeg source not found at $SRC/configure" >&2
    echo "Clone it with: git clone https://github.com/FFmpeg/FFmpeg.git $SRC" >&2
    exit 1
fi

if ! command -v cl.exe >/dev/null 2>&1; then
    echo "Error: cl.exe not found. Run from a Visual Studio x64 developer shell." >&2
    exit 1
fi

if ! command -v make >/dev/null 2>&1; then
    echo "Error: make not found. Install Git Bash or MSYS2 and ensure make is in PATH." >&2
    exit 1
fi

CPUS="${NUMBER_OF_PROCESSORS:-}"
if [ -z "$CPUS" ] && command -v nproc >/dev/null 2>&1; then
    CPUS="$(nproc)"
fi
if [ -z "$CPUS" ]; then
    CPUS=8
fi

if [ "$MODE" = "shared" ]; then
    BUILD_DIR="$SRC/build_windows_${FFMPEG_ARCH}_shared"
    MODE_FLAGS=(--disable-static --enable-shared)
else
    BUILD_DIR="$SRC/build_windows_${FFMPEG_ARCH}_static"
    MODE_FLAGS=(--enable-static --disable-shared)
fi

echo "==> Configuring FFmpeg ($MODE): os=windows arch=$FFMPEG_ARCH prefix=$BUILD_DIR"
cd "$SRC"

./configure \
    --prefix="$BUILD_DIR" \
    --arch="$FFMPEG_ARCH" \
    --target-os="$FFMPEG_TARGET_OS" \
    --toolchain=msvc \
    "${MODE_FLAGS[@]}" \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-avx \
    --disable-avx2 \
    --disable-iconv

echo "==> Building (using $CPUS cores)..."
make -j"$CPUS"

echo "==> Installing to $BUILD_DIR..."
make install

LIBS=(avutil avcodec avformat avfilter swscale swresample avdevice)

copy_first() {
    local dst="$1"
    shift
    local src=""
    for src in "$@"; do
        if [ -f "$src" ]; then
            cp -f "$src" "$dst"
            echo "    $(basename "$dst")"
            return 0
        fi
    done
    echo "    Warning: no match for $(basename "$dst")" >&2
    return 1
}

if [ "$MODE" = "shared" ]; then
    echo "==> Copying import libs to $BASE/..."
    for lib in "${LIBS[@]}"; do
        copy_first \
            "$BASE/${lib}.lib" \
            "$BUILD_DIR/lib/${lib}.lib" \
            "$BUILD_DIR/lib/lib${lib}.lib" || true
    done

    echo "==> Copying DLLs to $BASE/..."
    for lib in "${LIBS[@]}"; do
        dll=""
        for cand in "$BUILD_DIR/bin/${lib}"*.dll "$BUILD_DIR/bin/lib${lib}"*.dll; do
            if [ -f "$cand" ]; then
                dll="$cand"
                break
            fi
        done
        if [ -n "$dll" ]; then
            cp -f "$dll" "$BASE/$(basename "$dll")"
            echo "    $(basename "$dll")"
        else
            echo "    Warning: DLL for ${lib} not found" >&2
        fi
    done

    echo "==> Done. Shared libs written to $BASE/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=shared"
else
    echo "==> Copying static libs to $BASE/..."
    for lib in "${LIBS[@]}"; do
        copy_first \
            "$BASE/${lib}_static.lib" \
            "$BUILD_DIR/lib/${lib}.lib" \
            "$BUILD_DIR/lib/lib${lib}.lib" || true
    done

    echo "==> Done. Static libs written to $BASE/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=static"
fi
