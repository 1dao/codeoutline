#!/bin/sh
# CI: run the Lua specs inside a Linux distribution container (see ci.yml).
# usage: ci-distro-test.sh <expect GBK decoding: 0|1> [dnf packages to install]
# GBK decoding needs the system converter, which minimal EL images omit; the
# expectation makes sure the GBK cases really ran (or really skipped).
set -u
want_gbk=$1
shift
if [ $# -gt 0 ]; then
    # Keep diagnostics visible: a repository/network failure must be distinct
    # from a failing compatibility test. Retry once before changing endpoints.
    if ! dnf -y --setopt=timeout=30 --setopt=retries=2 install "$@"; then
        sleep 5
        if ! dnf -y --refresh --setopt=timeout=30 --setopt=retries=2 install "$@"; then
            if [ -r /etc/centos-release ] && grep -q 'CentOS Stream release 9' /etc/centos-release; then
                echo 'Mirror discovery failed; retrying official CentOS Stream 9 repositories.' >&2
                # Only this invocation changes endpoints; retain TLS and RPM
                # signature verification and never skip required GBK coverage.
                dnf -y --refresh --setopt=timeout=30 --setopt=retries=2 \
                    --disablerepo='*' --enablerepo=baseos --enablerepo=appstream \
                    --setopt=baseos.metalink= --setopt=baseos.mirrorlist= \
                    '--setopt=baseos.baseurl=https://mirror.stream.centos.org/9-stream/BaseOS/$basearch/os/' \
                    --setopt=appstream.metalink= --setopt=appstream.mirrorlist= \
                    '--setopt=appstream.baseurl=https://mirror.stream.centos.org/9-stream/AppStream/$basearch/os/' \
                    install "$@" || exit 1
            else
                exit 1
            fi
        fi
    fi
fi
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
