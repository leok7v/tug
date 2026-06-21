#!/usr/bin/env bash
# Stage the guest payload Boat bundles as app resources. Copies the bbl, our 6.x
# kernel, and the (non-apk) interactive initramfs into mac/payload/ with stable
# names the app loads at runtime. Run `make embed` first so the initrd exists.
#
# Usage: stage-payload.sh   (run from mac/, or any dir; paths are repo-relative)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/payload"

bios="$repo/vendors/diskimage/bbl64.bin"
kernel="$repo/vendors/diskimage/Image-c2w"
initrd="$repo/generated/tug-embed.cpio.gz"

for f in "$bios" "$kernel" "$initrd"; do
  [ -f "$f" ] || { echo "stage-payload: missing $f (run 'make embed' first)"; exit 1; }
done

mkdir -p "$out"
cp -f "$bios"   "$out/bios.bin"
cp -f "$kernel" "$out/kernel.bin"
cp -f "$initrd" "$out/initrd.cgz"
echo "staged payload -> $out  (bios.bin kernel.bin initrd.cgz)"
