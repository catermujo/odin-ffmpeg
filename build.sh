#!/bin/sh
# build.sh — compile FFmpeg source to shared (dynamic) libraries for use with
#            vendor/ffmpeg/ Odin bindings (FFMPEG_LINK=shared).
#            Shared libs enable hot-reloading workflows.
#
# Usage:
#   ./build.sh              # host arch, auto-detect OS
#   ./build.sh arm64        # cross-compile to arm64 (Darwin only)
#   ./build.sh x86_64       # cross-compile to x86_64
#
# Output:
#   Darwin: libXXX.dylib  (install name set to @rpath/libXXX.dylib)
#   Linux:  libXXX.so
#
# Build your app with:
#   odin build . -define:FFMPEG_LINK=shared
#
# Darwin runtime — add rpath pointing at this directory, e.g.:
#   odin build . -define:FFMPEG_LINK=shared \
#       -extra-linker-flags:"-rpath /abs/path/to/vendor/ffmpeg"
# Linux runtime — libs must be on LD_LIBRARY_PATH or rpath-patched with patchelf.

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

case "$HOST_OS" in
    Darwin) OS_EXT=darwin; CPUS=$(sysctl -n hw.ncpu) ;;
    Linux)  OS_EXT=linux;  CPUS=$(nproc) ;;
    *)
        echo "Error: Unsupported OS: $HOST_OS" >&2
        exit 1
        ;;
esac

BUILD_DIR="$SRC/build_${OS_EXT}_${TARGET_ARCH}_shared"

echo "==> Configuring FFmpeg (shared): OS=$OS_EXT arch=$TARGET_ARCH prefix=$BUILD_DIR"
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
    --disable-static \
    --enable-shared \
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

LIBS="avutil avcodec avformat avfilter swscale swresample avdevice"

case "$HOST_OS" in
Darwin)
    echo "==> Copying shared libs to $BASE/..."
    for lib in $LIBS; do
        src="$BUILD_DIR/lib/lib${lib}.dylib"
        dst="$BASE/lib${lib}.dylib"
        if [ -f "$src" ] || [ -L "$src" ]; then
            cp -L "$src" "$dst"
            install_name_tool -id "@rpath/lib${lib}.dylib" "$dst"
            echo "    lib${lib}.dylib"
        else
            echo "    Warning: $src not found, skipping" >&2
        fi
    done

    echo "==> Fixing inter-library @rpath references..."
    for lib in $LIBS; do
        dst="$BASE/lib${lib}.dylib"
        [ -f "$dst" ] || continue
        for dep in $LIBS; do
            otool -L "$dst" | awk '{print $1}' | grep "lib${dep}" | grep -v "@rpath" | while read -r old; do
                install_name_tool -change "$old" "@rpath/lib${dep}.dylib" "$dst"
            done
        done
    done

    echo "==> Done. Shared libs written to $BASE/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=shared"
    echo "    Add rpath:  -extra-linker-flags:\"-rpath \$(pwd)/vendor/ffmpeg\""
    ;;

Linux)
    echo "==> Copying shared libs to $BASE/..."
    for lib in $LIBS; do
        src="$BUILD_DIR/lib/lib${lib}.so"
        dst="$BASE/lib${lib}.so"
        if [ -f "$src" ] || [ -L "$src" ]; then
            cp -L "$src" "$dst"
            echo "    lib${lib}.so"
        else
            echo "    Warning: $src not found, skipping" >&2
        fi
    done

    echo "==> Done. Shared libs written to $BASE/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=shared"
    echo "    Runtime:    LD_LIBRARY_PATH=$BASE:\$LD_LIBRARY_PATH ./your_binary"
    ;;
esac
