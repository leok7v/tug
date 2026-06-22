#!/usr/bin/env bash
# Build our own arm64 Linux Image for VZ, natively on macOS (mirrors the riscv
# docs/kernel.md recipe but LLVM=1, since the only arm64-Linux compiler that runs
# on macOS is clang). Output: vendors/diskimage/Image-arm64
set -euo pipefail
REPO=/Users/leo/code/tug
KVER=6.12
SR=$REPO/vendors/aarch64-linux-musl-cross/aarch64-linux-musl
BREW=$(brew --prefix)
LLVM=$(brew --prefix llvm)/bin
LLD=$(brew --prefix lld)/bin
# GNU userland (kernel Kbuild assumes GNU) + LLVM toolchain
export PATH="$LLVM:$LLD:$BREW/opt/make/libexec/gnubin:$BREW/opt/bison/bin:$BREW/opt/flex/bin:$BREW/opt/findutils/libexec/gnubin:$BREW/opt/coreutils/libexec/gnubin:$BREW/opt/gnu-sed/libexec/gnubin:$BREW/opt/gawk/libexec/gnubin:$BREW/bin:$PATH"

VOL=/Volumes/tugkbuild
if [ ! -d "$VOL" ]; then
  hdiutil create -size 16g -type SPARSE -fs 'Case-sensitive APFS' -volname tugkbuild "$REPO/vendors/tugkbuild.sparseimage" >/dev/null
  hdiutil attach "$REPO/vendors/tugkbuild.sparseimage" >/dev/null
fi
SRC="$VOL/linux-$KVER"
[ -d "$SRC" ] || tar xf /tmp/linux.tar.xz -C "$VOL"
cd "$SRC"

# host-tool shim: macOS lacks <elf.h>/<byteswap.h>; uuid_t clashes (same as riscv)
mkdir -p khostinc
cp "$SR/include/elf.h" khostinc/ 2>/dev/null || true
printf '#pragma once\n#define bswap_16 __builtin_bswap16\n#define bswap_32 __builtin_bswap32\n#define bswap_64 __builtin_bswap64\n' > khostinc/byteswap.h
cat > khostinc/endian.h <<'EH'
#pragma once
#include <libkern/OSByteOrder.h>
#define htole16(x) OSSwapHostToLittleInt16(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)
#define htobe16(x) OSSwapHostToBigInt16(x)
#define htobe32(x) OSSwapHostToBigInt32(x)
#define htobe64(x) OSSwapHostToBigInt64(x)
#define be16toh(x) OSSwapBigToHostInt16(x)
#define be32toh(x) OSSwapBigToHostInt32(x)
#define be64toh(x) OSSwapBigToHostInt64(x)
EH
HOSTFIX="-I$SRC/khostinc -D_UUID_T -D__GETHOSTUUID_H"

make LLVM=1 ARCH=arm64 defconfig
# guarantee initramfs + the virtio devices VZ exposes
./scripts/config --enable BLK_DEV_INITRD --enable RD_GZIP \
  --enable VIRTIO --enable VIRTIO_PCI --enable PCI_HOST_GENERIC \
  --enable VIRTIO_MMIO --enable VIRTIO_CONSOLE --enable VIRTIO_BLK \
  --enable VIRTIO_NET --enable HW_RANDOM_VIRTIO \
  --enable DEVTMPFS --enable DEVTMPFS_MOUNT \
  --disable KVM
make LLVM=1 ARCH=arm64 HOSTCFLAGS="$HOSTFIX" olddefconfig
make LLVM=1 ARCH=arm64 HOSTCFLAGS="$HOSTFIX" -j"$(sysctl -n hw.ncpu)" Image
cp arch/arm64/boot/Image "$REPO/vendors/diskimage/Image-arm64"
echo "KERNEL-DONE: $(ls -la "$REPO/vendors/diskimage/Image-arm64" | awk '{print $5}') bytes"
