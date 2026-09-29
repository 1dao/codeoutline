#!/bin/sh
# CI: run the Lua specs inside a Linux distribution container (see ci.yml).
# usage: ci-distro-test.sh <expect GBK decoding: 0|1> [dnf packages to install]
# GBK decoding needs the system converter, which minimal EL images omit; the
# expectation makes sure the GBK cases really ran (or really skipped).
set -u
want_gbk=$1
shift
if [ $# -gt 0 ]; then dnf -y -q install "$@" > /dev/null || exit 1; fi
rc=0
./bin/xnet tests/lua/codeoutline_spec.lua || rc=1
./bin/xnet tests/lua/stability_spec.lua > /tmp/stability.log 2>&1 || rc=1
cat /tmp/stability.log
if grep -q 'no GBK converter' /tmp/stability.log; then gbk=0; else gbk=1; fi
if [ "$gbk" != "$want_gbk" ]; then
    echo "GBK decoding: expected $want_gbk, got $gbk" >&2
    rc=1
fi
# Runs as root to install packages; hand the runtime's log directory back.
if [ -n "${OWNER:-}" ] && [ -d logs ]; then chown -R "$OWNER" logs; fi
exit $rc
