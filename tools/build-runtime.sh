#!/bin/sh
# Build the release runtime (LuaJIT, xproc, MPSCQ, HTTPS) and copy it to the
# repository-level bin/. rpmalloc is off: libc indexes as fast, and rpmalloc
# keeps each exited parse thread's pages committed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
luajit="$root/xnet2lua/3rd/luajit"
flags="BUILD_MODE=release WITH_XPROC=1 WITH_MPSCQ=1 WITH_RPMALLOC=0 LUA_BACKEND=luajit"
mkdir -p "$root/bin"

if [ "$(uname -s)" != Darwin ]; then
    # Rebuild LuaJIT so a library from other flags is never reused.
    make -C "$luajit" clean > /dev/null
    # shellcheck disable=SC2086 # $flags is a fixed list of make variables
    make -C "$root/xnet2lua" -j"$jobs" xnet $flags
    cp -f "$root/xnet2lua/bin/xnet" "$root/bin/xnet"
    exit 0
fi

# macOS: one universal binary for Apple Silicon and Intel. clang otherwise
# targets the build host's macOS version, so pin the minimum (11.0 is the first
# release with Apple Silicon). Each slice is a separate build: the Makefile
# picks libdeflate's cpu_features.c by XNET_HOST_ARCH, and LuaJIT needs its
# own library per CPU, with build tools compiled for this machine (HOST_CC).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
set --
for arch in ${XNET_MAC_ARCHS:-arm64 x86_64}; do
    make -C "$root/xnet2lua" clean > /dev/null
    make -C "$luajit" clean > /dev/null
    make -C "$luajit/src" -j"$jobs" libluajit.a BUILDMODE=static HOST_CC=cc CC=cc \
        TARGET_FLAGS="-arch $arch" XCFLAGS=-DLUAJIT_ENABLE_LUA52COMPAT
    # shellcheck disable=SC2086
    make -C "$root/xnet2lua" -j"$jobs" xnet $flags CC="cc -arch $arch" XNET_HOST_ARCH="$arch"
    cp -f "$root/xnet2lua/bin/xnet" "$root/bin/xnet-$arch"
    set -- "$@" "$root/bin/xnet-$arch"
done
lipo -create -output "$root/bin/xnet" "$@"
rm -f "$@"
cp -f "$root/bin/xnet" "$root/xnet2lua/bin/xnet"
