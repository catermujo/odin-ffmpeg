#!/bin/sh
set -eu

prefix="$1"
jobs="$2"
src="$prefix/source"
revision=6040962bed5cc68c5ad01234c38c08b8b2822068

if [ ! -d "$src/.git" ]; then
    git init --quiet "$src"
    git -C "$src" remote add origin https://github.com/ultravideo/kvazaar.git
fi
if [ "$(git -C "$src" rev-parse --verify --quiet HEAD || true)" != "$revision" ]; then
    if ! git -C "$src" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$src" fetch --depth=1 origin "$revision"
    fi
    git -C "$src" checkout --quiet --detach "$revision"
fi

cmake -S "$src" -B "$prefix/cmake" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF -DBUILD_KVAZAAR_BINARY=OFF -DGIT_SUBMODULE=OFF
cmake --build "$prefix/cmake" --parallel "$jobs"
cmake --install "$prefix/cmake"
# The CMake pkg-config template omits the dependencies of the static library.
sed -i 's/^Libs: .* -lkvazaar$/& -lm -pthread/' "$prefix/lib/pkgconfig/kvazaar.pc"
