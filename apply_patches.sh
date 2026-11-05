#!/bin/sh
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:?FFmpeg source directory is required}"

for patch in "$BASE"/patches/*.patch; do
    [ -f "$patch" ] || continue
    # DUMBAI: Check patch contents because upstream can already include the change.
    if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
        continue
    fi
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
