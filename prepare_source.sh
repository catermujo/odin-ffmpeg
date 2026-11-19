#!/bin/sh
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/FFmpeg"
SRC_REMOTE="${FFMPEG_SRC_REMOTE:-https://github.com/FFmpeg/FFmpeg.git}"
# Match the upstream base of the AMF and Vulkan ProRes patch stack.
SRC_REVISION=9997fd060680d427bcc0c0715d163346da7ebd6f

if [ ! -f "$SRC/configure" ]; then
    if [ -e "$SRC" ] && [ ! -d "$SRC/.git" ]; then
        echo "Error: $SRC exists but is not a git repository" >&2
        exit 1
    fi
    if [ ! -d "$SRC/.git" ]; then
        git init --quiet "$SRC"
        git -C "$SRC" remote add origin "$SRC_REMOTE"
    fi
    echo "==> Fetching FFmpeg source at $SRC_REVISION"
    git -C "$SRC" fetch --depth=1 origin "$SRC_REVISION"
    git -C "$SRC" checkout --detach "$SRC_REVISION"
fi

sh "$BASE/apply_patches.sh" "$SRC"
