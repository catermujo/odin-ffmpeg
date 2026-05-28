#!/bin/sh
# build_static.sh — compile FFmpeg source to static libraries for use with
#                   vendor/ffmpeg/ Odin bindings (FFMPEG_LINK=static).
#
# Usage:
#   ./build_static.sh              # host arch, auto-detect OS
#   ./build_static.sh arm64        # cross-compile to arm64 (Darwin only)
#   ./build_static.sh x86_64       # cross-compile to x86_64
#
# Output:
#   Darwin: libXXX.darwin.a files placed next to this script.
#   Linux: linux_{arch}/libXXX.linux.a (e.g. linux_x64/libavcodec.linux.a).
# Build with: odin build . -define:FFMPEG_LINK=static

set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/FFmpeg"

if [ ! -f "$SRC/configure" ]; then
    echo "Error: FFmpeg source not found at $SRC/configure" >&2
    echo "Clone it with: git clone https://github.com/FFmpeg/FFmpeg.git $SRC" >&2
    exit 1
fi

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"
TARGET_ARCH="${1:-$HOST_ARCH}"

linux_arch_dir() {
    case "$1" in
        x86_64 | amd64) echo "linux_x64" ;;
        aarch64 | arm64) echo "linux_arm64" ;;
        *) echo "linux_$1" ;;
    esac
}

case "$HOST_OS" in
    Darwin) OS_EXT=darwin; CPUS=$(sysctl -n hw.ncpu) ;;
    Linux)  OS_EXT=linux;  CPUS=$(nproc) ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: Windows host detected. Use build_static.bat." >&2
        exit 1
        ;;
    *)
        echo "Error: Unsupported OS: $HOST_OS" >&2
        exit 1
        ;;
esac

BUILD_DIR="$SRC/build_${OS_EXT}_${TARGET_ARCH}"

echo "==> Configuring FFmpeg (static): OS=$OS_EXT arch=$TARGET_ARCH prefix=$BUILD_DIR"
cd "$SRC"

EXTRA_CFLAGS=""
EXTRA_LDFLAGS=""

# Darwin cross-arch support
if [ "$HOST_OS" = "Darwin" ] && [ "$TARGET_ARCH" != "$HOST_ARCH" ]; then
    EXTRA_CFLAGS="-arch $TARGET_ARCH"
    EXTRA_LDFLAGS="-arch $TARGET_ARCH"
fi

./configure \
    --prefix="$BUILD_DIR" \
    --arch="$TARGET_ARCH" \
    --enable-static \
    --disable-shared \
    --disable-programs \
    --disable-doc \
    --disable-debug \
    --disable-avx \
    --disable-avx2 \
    --disable-iconv \
    --extra-cflags="$EXTRA_CFLAGS" \
    --extra-ldflags="$EXTRA_LDFLAGS"

echo "==> Building (using $CPUS cores)..."
make -j"$CPUS"

echo "==> Installing to $BUILD_DIR..."
make install

if [ "$HOST_OS" = "Linux" ]; then
    ARCH_DIR="$(linux_arch_dir "$TARGET_ARCH")"
    OUT_DIR="$BASE/$ARCH_DIR"
    mkdir -p "$OUT_DIR"
    echo "==> Copying static libs to $OUT_DIR/..."
    for lib in avutil avcodec avformat avfilter swscale swresample avdevice; do
        src="$BUILD_DIR/lib/lib${lib}.a"
        dst="$OUT_DIR/lib${lib}.${OS_EXT}.a"
        if [ -f "$src" ]; then
            cp "$src" "$dst"
            echo "    $ARCH_DIR/lib${lib}.${OS_EXT}.a"
        else
            echo "    Warning: $src not found, skipping" >&2
        fi
    done
    echo "==> Done. Static libs written to $OUT_DIR/"
else
    echo "==> Copying static libs to $BASE/..."
    for lib in avutil avcodec avformat avfilter swscale swresample avdevice; do
        src="$BUILD_DIR/lib/lib${lib}.a"
        dst="$BASE/lib${lib}.${OS_EXT}.a"
        if [ -f "$src" ]; then
            cp "$src" "$dst"
            echo "    lib${lib}.${OS_EXT}.a"
        else
            echo "    Warning: $src not found, skipping" >&2
        fi
    done
    echo "==> Done. Static libs written to $BASE/"
fi

echo "    Build with: odin build . -define:FFMPEG_LINK=static"
