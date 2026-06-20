#!/usr/bin/env bash
# Boot our mkroot rootfs (packed as an ext2 image) as a FULL SYSTEM — our /init
# as pid 1, our toybox as the shell — using the stock prebuilt riscv64 kernel
# under TinyEMU. Asserts the system comes up. macOS lacks coreutils `timeout`,
# so the emulator is guarded with a background kill.
set -euo pipefail

TEMU="${1:?usage: bootfs.sh <temu> <image_dir>}"
IMG_DIR="${2:?missing image dir}"

# The stock 4.15 kernel has no initramfs support, so we boot our rootfs from a
# virtio-block ext2 root (init=/init), reusing the stock bbl SBI firmware.
cat > "$IMG_DIR/tug-fullsys.cfg" <<'EOF'
{
    version: 1,
    machine: "riscv64",
    memory_size: 256,
    bios: "bbl64.bin",
    kernel: "kernel-riscv64.bin",
    cmdline: "console=hvc0 root=/dev/vda rw init=/init",
    drive0: { file: "tug-root.ext2" },
    eth0: { driver: "user" },
}
EOF

LOG="$(mktemp -t tug_fullsys.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

cd "$IMG_DIR"
( printf 'echo TUG_FULLSYS_OK\nuname -a\n/bin/toybox echo multicall-works\npoweroff -f\n'; sleep 12 ) \
    | "$TEMU" -rw tug-fullsys.cfg >"$LOG" 2>&1 &
TPID=$!
( sleep 22; kill -9 "$TPID" 2>/dev/null ) &
GUARD=$!
disown "$GUARD" 2>/dev/null || true
wait "$TPID" 2>/dev/null || true
kill -9 "$GUARD" 2>/dev/null || true

echo "---- full-system boot (matched lines) ----"
grep -aE 'TUG_FULLSYS_OK|riscv64 Toybox|multicall-works' "$LOG" || true
echo "------------------------------------------"
if grep -aq TUG_FULLSYS_OK "$LOG"; then
    echo "BOOTFS: PASS — our rootfs booted as init on TinyEMU"
    exit 0
fi
echo "BOOTFS: FAIL — full log:"
sed -n '1,60p' "$LOG"
exit 1
