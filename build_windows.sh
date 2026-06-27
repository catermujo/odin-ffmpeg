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

ensure_wslpath() {
    if command -v wslpath >/dev/null 2>&1; then
        return 0
    fi
    if ! command -v cygpath >/dev/null 2>&1; then
        return 0
    fi

    local tool_bin_dir="${TMPDIR:-/tmp}/catermujo-tool-bin"
    mkdir -p "$tool_bin_dir"
    cat > "$tool_bin_dir/wslpath" <<'EOF'
#!/usr/bin/env bash
exec cygpath "$@"
EOF
    chmod +x "$tool_bin_dir/wslpath"
    PATH="$tool_bin_dir:$PATH"
    export PATH
}

patch_config_mak() {
    python - "$SRC" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])

config_mak = src / "ffbuild" / "config.mak"
config_text = config_mak.read_text(encoding="utf-8")
config_text = config_text.replace(
    r"xargs -r -d\\n -n1 wslpath -u",
    r"xargs -r -d '\n' -n1 wslpath -m",
)
config_text = config_text.replace(
    r"xargs -r -d '\n' -n1 wslpath -u",
    r"xargs -r -d '\n' -n1 wslpath -m",
)
config_text = config_text.replace(
    'SLIB_CREATE_DEF_CMD=$(file >$@.objs,$(filter %.o,$^))LDFLAGS="$(LDFLAGS)" EXTERN_PREFIX="$(EXTERN_PREFIX)" $(SRC_PATH)/compat/windows/makedef $(SUBDIR)lib$(NAME).ver @$@.objs > $$(@:$(SLIBSUF)=.def)',
    'SLIB_CREATE_DEF_CMD=LDFLAGS="$(LDFLAGS)" EXTERN_PREFIX="$(EXTERN_PREFIX)" $(SRC_PATH)/compat/windows/makedef $(SUBDIR)lib$(NAME).ver $(OBJS) > $$(@:$(SLIBSUF)=.def)',
)
config_mak.write_text(config_text, encoding="utf-8")

library_mak = src / "ffbuild" / "library.mak"
library_text = library_mak.read_text(encoding="utf-8")
wrong_library_block = '$(SUBDIR)$(SLIBNAME_WITH_MAJOR): $(OBJS) $(SHLIBOBJS) $(SUBDIR)lib$(NAME).ver\nifeq ($(RESPONSE_FILES),yes)\nifeq ($(HAVE_BUILTIN_FILE),yes)\n\t$$(file >$$@.objs,$$(filter %.o,$$^))\nelse\n\t$(Q)echo $$(filter %.o,$$^) > $$@.objs\nendif\n\tLDFLAGS=\"$$(LDFLAGS)\" EXTERN_PREFIX=\"$$(EXTERN_PREFIX)\" $$(SRC_PATH)/compat/windows/makedef $$(SUBDIR)lib$$(NAME).ver @$$@.objs > $$(@:$(SLIBSUF)=.def)\n\n\t$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) @$$@.objs $$(call $(NAME)LINK_EXTRA))\nelse\n\t$(SLIB_CREATE_DEF_CMD)\n\t$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) $$(filter %.o,$$^) $$(call $(NAME)LINK_EXTRA))\nendif\n'
fixed_library_block = '$(SUBDIR)$(SLIBNAME_WITH_MAJOR): $(OBJS) $(SHLIBOBJS) $(SUBDIR)lib$(NAME).ver\nifeq ($(RESPONSE_FILES),yes)\nifeq ($(HAVE_BUILTIN_FILE),yes)\n\t$$(file >$$@.objs,$$(filter %.o,$$^))\nelse\n\t$(Q)echo $$(filter %.o,$$^) > $$@.objs\nendif\n\tLDFLAGS=\"$$(LDFLAGS)\" EXTERN_PREFIX=\"$$(EXTERN_PREFIX)\" $(SRC_PATH)/compat/windows/makedef $(SUBDIR)lib$(NAME).ver @$$@.objs > $$(@:$(SLIBSUF)=.def)\n\n\t$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) @$$@.objs $$(call $(NAME)LINK_EXTRA))\nelse\n\t$(SLIB_CREATE_DEF_CMD)\n\t$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) $$(filter %.o,$$^) $$(call $(NAME)LINK_EXTRA))\nendif\n'
library_text = library_text.replace(
    '$(SUBDIR)$(SLIBNAME_WITH_MAJOR): $(OBJS) $(SHLIBOBJS) $(SUBDIR)lib$(NAME).ver\n\t$(SLIB_CREATE_DEF_CMD)\nifeq ($(RESPONSE_FILES),yes)\nifeq ($(HAVE_BUILTIN_FILE),yes)\n\t$$(file >$$@.objs,$$(filter %.o,$$^))\nelse\n\t$(Q)echo $$(filter %.o,$$^) > $$@.objs\nendif\n\n\t$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) @$$@.objs $$(call $(NAME)LINK_EXTRA))\nelse\n\t$$(call LINK,$$(call $(NAME)LINK_SO_ARGS) $$(LD_O) $$(filter %.o,$$^) $$(call $(NAME)LINK_EXTRA))\nendif\n',
    fixed_library_block,
)
library_text = library_text.replace(wrong_library_block, fixed_library_block)
library_text = library_text.replace(
    '$(SUBDIR)lib$(FULLNAME).pc: $(SUBDIR)version.h ffbuild/config.sh | $(SUBDIR)\n',
    '$(SUBDIR)lib$(FULLNAME).pc: $(SUBDIR)version.h $(SUBDIR)lib$(NAME).version $(foreach lib,$(FFLIBS),lib$(lib)/lib$(lib).version) ffbuild/config.sh | $(SUBDIR)\n',
)
library_mak.write_text(library_text, encoding="utf-8")

makedef = src / "compat" / "windows" / "makedef"
makedef_text = makedef.read_text(encoding="utf-8")
makedef_text = makedef_text.replace(
    'for object in "$@"; do\n    if [ ! -f "$object" ]; then\n        echo "Object does not exist: ${object}" >&2\n        exit 1\n    fi\ndone\n',
    'for object in "$@"; do\n    case "$object" in\n    @*)\n        listfile=${object#@}\n        if [ ! -f "$listfile" ]; then\n            echo "Object list does not exist: ${listfile}" >&2\n            exit 1\n        fi\n        for listed in $(cat "$listfile"); do\n            if [ ! -f "$listed" ]; then\n                echo "Object does not exist: ${listed}" >&2\n                exit 1\n            fi\n        done\n        ;;\n    *)\n        if [ ! -f "$object" ]; then\n            echo "Object does not exist: ${object}" >&2\n            exit 1\n        fi\n        ;;\n    esac\ndone\n',
)
makedef.write_text(makedef_text, encoding="utf-8")
PY
}

require_windows_x86asm() {
    python - <<'PY'
from __future__ import annotations

import re
import subprocess
import sys

proc = subprocess.run(["nasm", "-v"], check=False, capture_output=True, text=True)
text = f"{proc.stdout}\n{proc.stderr}"
if proc.returncode != 0:
    print("Error: nasm not found. Install NASM 2.14.03 or newer and keep asm enabled.", file=sys.stderr)
    raise SystemExit(1)

match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", text)
if not match:
    print("Error: could not read NASM version. Need NASM 2.14.03 or newer.", file=sys.stderr)
    raise SystemExit(1)

version = tuple(int(part or 0) for part in match.groups())
if version < (2, 14, 3):
    print(
        f"Error: NASM {version[0]}.{version[1]}.{version[2]} too old for FFmpeg Windows asm. "
        "Install NASM 2.14.03 or newer.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
}

config_matches() {
    local config_mak="$SRC/ffbuild/config.mak"
    if [ ! -f "$config_mak" ]; then
        return 1
    fi

    local expected_config
    expected_config="FFMPEG_CONFIGURATION=${configure_args[*]}"
    grep -Fqx "$expected_config" "$config_mak"
}

if [ ! -f "$SRC/configure" ]; then
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

ensure_wslpath
require_windows_x86asm

if [ "$MODE" = "shared" ]; then
    BUILD_DIR="$SRC/build_windows_${FFMPEG_ARCH}_shared"
    MODE_FLAGS=(--disable-static --enable-shared)
else
    BUILD_DIR="$SRC/build_windows_${FFMPEG_ARCH}_static"
    MODE_FLAGS=(--enable-static --disable-shared)
fi

configure_args=(
    --prefix="$BUILD_DIR"
    --arch="$FFMPEG_ARCH"
    --target-os="$FFMPEG_TARGET_OS"
    --toolchain=msvc
    "${MODE_FLAGS[@]}"
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-avx
    --disable-avx2
    --disable-iconv
)

cd "$SRC"

if config_matches; then
    echo "==> Reusing FFmpeg config ($MODE): os=windows arch=$FFMPEG_ARCH prefix=$BUILD_DIR"
else
    if [ -f "$SRC/ffbuild/config.mak" ] && [ -f "$SRC/Makefile" ]; then
        echo "==> Cleaning stale FFmpeg objects before reconfigure"
        make distclean >/dev/null 2>&1 || true
    fi
    echo "==> Configuring FFmpeg ($MODE): os=windows arch=$FFMPEG_ARCH prefix=$BUILD_DIR"
    ./configure "${configure_args[@]}"
fi

patch_config_mak
find "$SRC" -name '*.d' -delete
while IFS= read -r stale_object; do
    rm -f "$stale_object"
done < <(find "$SRC" -type f -name '*.o' -size 0c -print)

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
    echo "==> Copying import libs to $BASE/$FFMPEG_OUTPUT_DIR/..."
    mkdir -p "$BASE/$FFMPEG_OUTPUT_DIR"
    for lib in "${LIBS[@]}"; do
        copy_first \
            "$BASE/$FFMPEG_OUTPUT_DIR/${lib}.lib" \
            "$BUILD_DIR/lib/${lib}.lib" \
            "$BUILD_DIR/lib/lib${lib}.lib" \
            "$SRC/lib${lib}/${lib}.lib" \
            "$SRC/lib${lib}/lib${lib}.lib" || true
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
            "$BUILD_DIR/lib/${lib}.lib" \
            "$BUILD_DIR/lib/lib${lib}.lib" || true
    done

    echo "==> Done. Static libs written to $BASE/$FFMPEG_OUTPUT_DIR/"
    echo "    Build with: odin build . -define:FFMPEG_LINK=static"
fi
