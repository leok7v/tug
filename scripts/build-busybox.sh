#!/usr/bin/env bash
# Cross-compile a static riscv64 busybox containing just `vi` (the classic,
# solid vi — toybox's pending vi is buggy). Output: vendors/busybox-VER/busybox
#
# args: <toolchain_dir> <vendor_dir>
set -euo pipefail

TC="${1:?usage: build-busybox.sh <toolchain_dir> <vendor_dir>}"
VENDOR="${2:?missing vendor dir}"
CROSS="$TC/bin/riscv64-linux-musl-"
VER=1.36.1
SRC="$VENDOR/busybox-$VER"

# GNU userland on macOS (busybox build assumes it, like the kernel/toybox).
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
export PATH="$BREW/opt/make/libexec/gnubin:$BREW/opt/gnu-sed/libexec/gnubin:$BREW/opt/coreutils/libexec/gnubin:$TC/bin:$PATH"

if [ ! -x "$SRC/busybox" ]; then
    [ -f "$VENDOR/busybox-$VER.tar.bz2" ] || \
      curl -fsSLo "$VENDOR/busybox-$VER.tar.bz2" "https://busybox.net/downloads/busybox-$VER.tar.bz2"
    rm -rf "$SRC" && tar xjf "$VENDOR/busybox-$VER.tar.bz2" -C "$VENDOR"
    cd "$SRC"
    make allnoconfig >/dev/null
    # NB: no FEATURE_VI_REGEX_SEARCH — it needs GNU regex extensions musl lacks.
    for o in STATIC VI FEATURE_VI_COLON FEATURE_VI_YANKMARK FEATURE_VI_SEARCH \
             FEATURE_VI_USE_SIGNALS FEATURE_VI_DOT_CMD \
             FEATURE_VI_READONLY FEATURE_VI_SETOPTS FEATURE_VI_UNDO \
             FEATURE_VI_WIN_RESIZE FEATURE_VI_ASK_TERMINAL FEATURE_VI_OPTIMIZE_CURSOR; do
        sed -i "s/^# CONFIG_$o is not set/CONFIG_$o=y/" .config
    done
    yes "" 2>/dev/null | make oldconfig >/dev/null || true
    make CROSS_COMPILE="$CROSS" -j"$(sysctl -n hw.ncpu 2>/dev/null || nproc)" busybox
    "${CROSS}strip" busybox
fi

echo "busybox-vi: $SRC/busybox ($(du -h "$SRC/busybox" | cut -f1), $(file "$SRC/busybox" | grep -o RISC-V))"
