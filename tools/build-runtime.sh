#!/bin/sh
# Build the release runtime and copy it to the repository-level bin/.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
mkdir -p "$root/bin"

if [ "$(uname -s)" != Darwin ]; then
    make -C "$root/xnet2lua" -j"$jobs" xnet BUILD_MODE=release WITH_XPROC=1
    cp -f "$root/xnet2lua/bin/xnet" "$root/bin/xnet"
    exit 0
fi

# macOS: one universal binary for Apple Silicon and Intel. clang otherwise
# targets the build host's macOS version, so pin the minimum (11.0 is the first
# release with Apple Silicon). Each slice is a separate build because the
# Makefile picks libdeflate's cpu_features.c by XNET_HOST_ARCH.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
set --
for arch in ${XNET_MAC_ARCHS:-arm64 x86_64}; do
    make -C "$root/xnet2lua" clean > /dev/null
    make -C "$root/xnet2lua" -j"$jobs" xnet BUILD_MODE=release WITH_XPROC=1 \
        CC="cc -arch $arch" XNET_HOST_ARCH="$arch"
    cp -f "$root/xnet2lua/bin/xnet" "$root/bin/xnet-$arch"
    set -- "$@" "$root/bin/xnet-$arch"
done
lipo -create -output "$root/bin/xnet" "$@"
rm -f "$@"
cp -f "$root/bin/xnet" "$root/xnet2lua/bin/xnet"
