#!/usr/bin/env bash
# build_windows.sh — build vendored FFmpeg on Windows using MSVC toolchain.
#
# Usage:
#   ./build_windows.sh shared [x86_64|arm64]
#   ./build_windows.sh static [x86_64|arm64]
#
# Requirements:
#   - Run from a shell where MSVC tools are available (cl.exe/link.exe).
#   - bash + make available (Git Bash/MSYS2).
#   - pkg-config available on PATH.
#   - FFmpeg's NVENC, AMF, and oneVPL development headers/libraries available.
#   - Set FFMPEG_EXTRA_CFLAGS/LDFLAGS when those SDKs are outside compiler defaults.

set -euo pipefail

MODE="${1:-shared}"
TARGET_ARCH="${2:-x86_64}"

case "$MODE" in
shared | static) ;;
*)
    echo "Usage: $0 <shared|static> [x86_64|arm64]" >&2
    exit 1
    ;;
esac

case "$TARGET_ARCH" in
x86_64 | amd64)
    FFMPEG_ARCH="x86_64"
    FFMPEG_TARGET_OS="win64"
    FFMPEG_OUTPUT_DIR="windows_x64"
    ;;
x64)
    FFMPEG_ARCH="x86_64"
    FFMPEG_TARGET_OS="win64"
    FFMPEG_OUTPUT_DIR="windows_x64"
    ;;
arm64 | aarch64)
    FFMPEG_ARCH="aarch64"
    FFMPEG_TARGET_OS="win64"
    FFMPEG_OUTPUT_DIR="windows_arm64"
    ;;
*)
    echo "Error: Unsupported target arch '$TARGET_ARCH' (expected x86_64 or arm64)." >&2
    exit 1
    ;;
esac

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/FFmpeg"
SRC_REMOTE="${FFMPEG_SRC_REMOTE:-https://github.com/FFmpeg/FFmpeg.git}"

if [ ! -f "$SRC/configure" ]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git not found; cannot clone FFmpeg source." >&2
        echo "Fix: scoop install git" >&2
        exit 1
    fi
    if [ -e "$SRC" ] && [ ! -d "$SRC/.git" ]; then
        echo "Error: $SRC exists but is not a git repository" >&2
        echo "Remove it and re-run build_windows.sh, or clone FFmpeg into that path." >&2
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

for patch in "$BASE"/patches/*.patch; do
    [ -f "$patch" ] || continue
    subject="$(sed -n 's/^Subject: \[PATCH\] //p' "$patch" | sed 's/\r$//' | head -n 1)"
    if [ -n "$subject" ] && git -C "$SRC" log --format=%s --all | grep -Fxe "$subject" >/dev/null; then
        continue
    fi
    if ! git -C "$SRC" am --3way "$patch"; then
        git -C "$SRC" am --abort || true
        echo "Error: failed to apply FFmpeg patch $(basename "$patch")" >&2
        exit 1
    fi
done

require_command() {
    local name="$1"
    local fix="$2"
    if ! command -v "$name" >/dev/null 2>&1; then
        echo "Error: $name not found." >&2
        echo "Fix: $fix" >&2
        exit 1
    fi
}

require_pkg_config() {
    local package="$1"
    local requirement="$2"
    local fix="$3"
    if ! pkg-config --exists "$requirement"; then
        echo "Error: $package missing from pkg-config ($requirement)." >&2
        echo "Fix: $fix" >&2
        echo "Then add the directory containing its .pc file to PKG_CONFIG_PATH." >&2
        exit 1
    fi
}

require_command cl.exe "Install Visual Studio 2022 C++ tools, then use an x64 Native Tools prompt."
require_command make "scoop install make, or install make with MSYS2."
require_command pkg-config "scoop install pkg-config, or install pkgconf with MSYS2."

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

FFMPEG_EXTRA_CFLAGS="${FFMPEG_EXTRA_CFLAGS:-}"
FFMPEG_EXTRA_LDFLAGS="${FFMPEG_EXTRA_LDFLAGS:-}"

require_pkg_config ffnvcodec "ffnvcodec" "vcpkg install ffnvcodec:x64-windows"
require_pkg_config libvpl "vpl >= 2.6" "build and install oneVPL from source; see README.md"

echo "==> Configuring FFmpeg ($MODE): os=windows arch=$FFMPEG_ARCH prefix=$BUILD_DIR"
cd "$SRC"

if ! ./configure \
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
    --disable-iconv \
    --enable-nvenc \
    --enable-amf \
    --enable-libvpl \
    --extra-cflags="$FFMPEG_EXTRA_CFLAGS" \
    --extra-ldflags="$FFMPEG_EXTRA_LDFLAGS"; then
    echo "FFmpeg configure failed. AMF needs version 1.5.2 or newer in FFMPEG_EXTRA_CFLAGS." >&2
    echo "Use the Windows FFmpeg hardware encoder instructions in README.md if amd-amf is too old." >&2
    echo "See README.md in the repository for the complete Windows hardware-encoder setup." >&2
    exit 1
fi

echo "==> Building (using $CPUS cores)..."
make -j"$CPUS"

echo "==> Installing to $BUILD_DIR..."
make install-libs

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
    echo "==> Copying import libs to $BASE/$FFMPEG_OUTPUT_DIR/..."
    mkdir -p "$BASE/$FFMPEG_OUTPUT_DIR"
    for lib in "${LIBS[@]}"; do
        copy_first \
            "$BASE/$FFMPEG_OUTPUT_DIR/${lib}.lib" \
            "$BUILD_DIR/bin/${lib}.lib" \
            "$BUILD_DIR/lib/${lib}.lib" \
            "$BUILD_DIR/lib/lib${lib}.lib" || true
    done

    echo "==> Copying DLLs to $BASE/$FFMPEG_OUTPUT_DIR/..."
    for lib in "${LIBS[@]}"; do
        dll=""
        for cand in "$BUILD_DIR/bin/${lib}"*.dll "$BUILD_DIR/bin/lib${lib}"*.dll; do
            if [ -f "$cand" ]; then
                dll="$cand"
                break
            fi
        done
        if [ -n "$dll" ]; then
            cp -f "$dll" "$BASE/$FFMPEG_OUTPUT_DIR/$(basename "$dll")"
            echo "    $(basename "$dll")"
        else
            echo "    Warning: DLL for ${lib} not found" >&2
        fi
    done

    echo "==> Done. Shared libs written to $BASE/$FFMPEG_OUTPUT_DIR/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=shared"
else
    echo "==> Copying static libs to $BASE/$FFMPEG_OUTPUT_DIR/..."
    mkdir -p "$BASE/$FFMPEG_OUTPUT_DIR"
    for lib in "${LIBS[@]}"; do
        copy_first \
            "$BASE/$FFMPEG_OUTPUT_DIR/${lib}_static.lib" \
            "$BUILD_DIR/bin/${lib}.lib" \
            "$BUILD_DIR/lib/${lib}.lib" \
            "$BUILD_DIR/lib/lib${lib}.lib" || true
    done

    echo "==> Done. Static libs written to $BASE/$FFMPEG_OUTPUT_DIR/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=static"
fi
