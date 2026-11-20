#!/bin/sh
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="$BASE/FFmpeg"
SRC_REMOTE="${FFMPEG_SRC_REMOTE:-https://github.com/FFmpeg/FFmpeg.git}"
# Match the upstream base of the AMF and Vulkan ProRes patch stack.
SRC_REVISION=9997fd060680d427bcc0c0715d163346da7ebd6f

if [ ! -d "$SRC/.git" ]; then
    if [ -e "$SRC" ]; then
        echo "Error: $SRC exists but is not a git repository" >&2
        exit 1
    fi
    git init --quiet "$SRC"
    git -C "$SRC" remote add origin "$SRC_REMOTE"
fi

patch_hashes="$(
    for patch in "$BASE"/patches/*.patch; do
        [ -f "$patch" ] || continue
        git hash-object "$patch"
    done
)"
head="$(git -C "$SRC" rev-parse --verify --quiet HEAD || true)"
prepared="$(git -C "$SRC" config --local --get ffmpeg.preparedSource || true)"
if [ -f "$SRC/configure" ] && [ "$prepared" = "$head $SRC_REVISION $patch_hashes" ]; then
    exit 0
fi

tracked_edits="$(git -C "$SRC" status --porcelain --untracked-files=no)"
if [ -n "$tracked_edits" ]; then
    echo "Error: FFmpeg source has tracked edits. Commit or stash them before the build." >&2
    exit 1
fi

if [ "$head" != "$SRC_REVISION" ]; then
    if ! git -C "$SRC" cat-file -e "$SRC_REVISION^{commit}" 2>/dev/null; then
        echo "==> Fetching FFmpeg source at $SRC_REVISION"
        git -C "$SRC" fetch --depth=1 origin "$SRC_REVISION"
    fi
    if [ -n "$head" ]; then
        # Keep the previous source commit reachable after checkout detaches HEAD.
        git -C "$SRC" update-ref "refs/ffmpeg/previous/$head" "$head"
    fi
fi
git -C "$SRC" checkout --detach --no-overwrite-ignore "$SRC_REVISION"

sh "$BASE/apply_patches.sh" "$SRC"
head="$(git -C "$SRC" rev-parse HEAD)"
git -C "$SRC" config --local ffmpeg.preparedSource "$head $SRC_REVISION $patch_hashes"
