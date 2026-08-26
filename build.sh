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
#   Linux:  linux_{arch}/libXXX.so (e.g. linux_x64/libavcodec.so)
#
# Build your app with:
#   odin build . -define:FFMPEG_LINK=shared
#
# Darwin runtime — add rpath pointing at the arch dir, e.g.:
#   odin build . -define:FFMPEG_LINK=shared \
#       -extra-linker-flags:"-rpath /abs/path/to/vendor/ffmpeg/darwin_arm64"
# Linux runtime — libs must be on LD_LIBRARY_PATH or rpath-patched with patchelf.

set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/FFmpeg"
SRC_REMOTE="${FFMPEG_SRC_REMOTE:-https://github.com/FFmpeg/FFmpeg.git}"

if [ ! -f "$SRC/configure" ]; then
    if [ -e "$SRC" ] && [ ! -d "$SRC/.git" ]; then
        echo "Error: $SRC exists but is not a git repository" >&2
        echo "Remove it and re-run build.sh, or clone FFmpeg into that path." >&2
        exit 1
    fi
    if [ ! -d "$SRC/.git" ]; then
        echo "==> FFmpeg source missing. Cloning $SRC_REMOTE into $SRC"
        git clone "$SRC_REMOTE" "$SRC"
    fi
fi

if [ ! -f "$SRC/configure" ]; then
    echo "Error: FFmpeg source not found at $SRC/configure after clone attempt" >&2
    echo "Try: git -C $SRC checkout <valid-ffmpeg-ref>" >&2
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

darwin_arch_dir() {
    case "$1" in
        x86_64 | amd64) echo "darwin_x64" ;;
        aarch64 | arm64) echo "darwin_arm64" ;;
        *) echo "darwin_$1" ;;
    esac
}

case "$HOST_OS" in
    Darwin) OS_EXT=darwin; CPUS=$(sysctl -n hw.ncpu) ;;
    Linux)  OS_EXT=linux;  CPUS=$(nproc) ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Error: Windows host detected. Use build.bat (shared) or build_static.bat (static)." >&2
        exit 1
        ;;
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
    ARCH_DIR="$(darwin_arch_dir "$TARGET_ARCH")"
    OUT_DIR="$BASE/$ARCH_DIR"
    mkdir -p "$OUT_DIR"
    echo "==> Copying shared libs to $OUT_DIR/..."
    for lib in $LIBS; do
        src="$BUILD_DIR/lib/lib${lib}.dylib"
        dst="$OUT_DIR/lib${lib}.dylib"
        if [ -f "$src" ] || [ -L "$src" ]; then
            cp -L "$src" "$dst"
            install_name_tool -id "@rpath/lib${lib}.dylib" "$dst"
            echo "    $ARCH_DIR/lib${lib}.dylib"
        else
            echo "    Warning: $src not found, skipping" >&2
        fi
    done

    echo "==> Fixing inter-library @rpath references..."
    for lib in $LIBS; do
        dst="$OUT_DIR/lib${lib}.dylib"
        [ -f "$dst" ] || continue
        for dep in $LIBS; do
            otool -L "$dst" | awk '{print $1}' | grep "lib${dep}" | grep -v "@rpath" | while read -r old; do
                install_name_tool -change "$old" "@rpath/lib${dep}.dylib" "$dst"
            done
        done
    done

    echo "==> Done. Shared libs written to $OUT_DIR/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=shared"
    echo "    Add rpath:  -extra-linker-flags:\"-rpath $OUT_DIR\""
    ;;

Linux)
    ARCH_DIR="$(linux_arch_dir "$TARGET_ARCH")"
    OUT_DIR="$BASE/$ARCH_DIR"
    mkdir -p "$OUT_DIR"
    echo "==> Copying shared libs to $OUT_DIR/..."
    for lib in $LIBS; do
        found=false
        for src in "$BUILD_DIR"/lib/lib${lib}.so*; do
            if [ ! -f "$src" ] && [ ! -L "$src" ]; then
                continue
            fi
            name=$(basename "$src")
            dst="$OUT_DIR/$name"
            rm -f "$dst"
            cp -P "$src" "$dst"
            echo "    $ARCH_DIR/$name"
            found=true
        done
        if [ "$found" != true ]; then
            echo "    Warning: $BUILD_DIR/lib/lib${lib}.so not found, skipping" >&2
        fi
    done

    echo "==> Done. Shared libs written to $OUT_DIR/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=shared"
    echo "    Runtime:    LD_LIBRARY_PATH=$OUT_DIR:\$LD_LIBRARY_PATH ./your_binary"
    ;;
esac
