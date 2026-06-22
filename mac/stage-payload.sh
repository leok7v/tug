#!/usr/bin/env bash
# Stage the guest payload Boat bundles as app resources. Copies the bbl, our 6.x
# kernel, and the *apk* initramfs into mac/payload/ with stable names the app
# loads at runtime, and packs the pre-seeded Alpine data disk into a compact
# sparse manifest (the app expands it into Documents on first launch — that's
# where apk / the `essentials` toolchains live and persist).
#
# Prereqs (repo root):  make embed-apk   and   make disk-seeded
# Usage: stage-payload.sh   (run from anywhere; paths are repo-relative)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/payload"

bios="$repo/vendors/diskimage/bbl64.bin"
kernel="$repo/vendors/diskimage/Image-c2w"
initrd="$repo/generated/tug-embed-apk.cpio.gz"   # apk variant (apk + essentials)
seed="$repo/tug-seed.img"                         # pre-seeded Alpine data disk

for f in "$bios" "$kernel" "$initrd"; do
  [ -f "$f" ] || { echo "stage-payload: missing $f (run 'make embed-apk' first)"; exit 1; }
done
[ -f "$seed" ] || { echo "stage-payload: missing $seed (run 'make disk-seeded' first)"; exit 1; }

mkdir -p "$out"
cp -f "$bios"   "$out/bios.bin"
cp -f "$kernel" "$out/kernel.bin"
cp -f "$initrd" "$out/initrd.cgz"
python3 "$here/build-sparse.py" "$seed" "$out/data.sparse"

# ARM64 (macOS/VZ) payload — our own arm64 kernel + the Alpine aarch64 apk
# initramfs (self-seeds /dev/vda on first boot) + an empty ext4 data disk packed
# sparse. Built at the repo root with `make arm64`.
karm="$repo/vendors/diskimage/Image-arm64"
iarm="$repo/generated/tug-arm64-apk.cpio.gz"
darm="$repo/generated/data-arm64.sparse"
if [ -f "$karm" ] && [ -f "$iarm" ] && [ -f "$darm" ]; then
  cp -f "$karm" "$out/kernel-arm64.bin"
  cp -f "$iarm" "$out/initrd-arm64.cgz"
  cp -f "$darm" "$out/data-arm64.sparse"
  echo "staged payload -> $out  (riscv + arm64)"
else
  echo "staged payload -> $out  (riscv only; arm64 stack not built — see mac/vz-spike)"
fi
