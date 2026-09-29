#!/bin/sh
# Build the release runtime and copy it to the repository-level bin/.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
make -C "$root/xnet2lua" -j"$jobs" xnet BUILD_MODE=release WITH_XPROC=1
mkdir -p "$root/bin"
cp -f "$root/xnet2lua/bin/xnet" "$root/bin/xnet"
