#!/usr/bin/env bash
# Boot the vendored RISC-V Linux image under TinyEMU non-interactively and
# assert it reaches a shell. macOS has no coreutils `timeout`, so we guard
# the emulator with a background kill.
set -euo pipefail

TEMU="${1:?usage: smoke.sh <temu> <image_dir> <cfg>}"
IMG_DIR="${2:?missing image dir}"
CFG="${3:?missing cfg}"

LOG="$(mktemp -t tug_boot.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

cd "$IMG_DIR"
# Feed the guest a couple of commands, then power off. The trailing sleep keeps
# stdin open long enough for the guest to consume the script before EOF.
( printf 'uname -a\necho TUG_BOOT_OK\npoweroff -f\n'; sleep 10 ) \
    | "$TEMU" "$CFG" >"$LOG" 2>&1 &
TPID=$!
( sleep 25; kill -9 "$TPID" 2>/dev/null ) &
GUARD=$!
disown "$GUARD" 2>/dev/null || true
wait "$TPID" 2>/dev/null || true
kill -9 "$GUARD" 2>/dev/null || true

echo "---- boot log (matched lines) ----"
grep -aE 'riscv64 GNU/Linux|TUG_BOOT_OK|Power off' "$LOG" || true
echo "----------------------------------"
if grep -aq TUG_BOOT_OK "$LOG"; then
    echo "SMOKE: PASS — booted riscv64 Linux to an interactive shell"
    exit 0
fi
echo "SMOKE: FAIL — full log:"
sed -n '1,60p' "$LOG"
exit 1
