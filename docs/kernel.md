# Building & booting our own Linux 6.x kernel on TinyEMU (native macOS, no Docker)

This documents the proven recipe for building a modern Linux (6.1 LTS) riscv64
kernel **natively on macOS arm64** and booting it on the vendored TinyEMU with our
toybox rootfs. No Docker, no fork, no OpenSBI, no QEMU required.

The single emulator change needed is `patches/tinyemu-rdtime.patch` (applied
automatically by `make build`); everything else is kernel-config + host-tool setup.

## Why it didn't "just work", and the fix

- The 2019 TinyEMU is **capable** of booting Linux 6.x — `ktock/container2wasm`
  does it on an unmodified copy. The blocker was a CPU-completeness gap:
- TinyEMU never implemented the unprivileged **`time` CSR (`rdtime`, `0xc01`)** —
  its own comment says *"the 'time' counter is usually emulated"* (by firmware).
  Linux 4.15 tolerated the trap; **6.x does not**, so musl userspace `rdtime`
  faults → `SIGILL` → *"Attempted to kill init"*. `patches/tinyemu-rdtime.patch`
  adds the CSR (returns `insn_counter / RTC_FREQ_DIV`, matching the CLINT mtime).
- Boot firmware: the **stock `bbl64.bin`** (from Bellard's disk image) works as-is.
- Use a **full-ish kernel config** (container2wasm's), not a bare `allnoconfig`.

## Prerequisites (one-time)

```sh
make deps          # Homebrew GNU userland (make, gnu-sed, gawk, bison, flex, …)
make toolchain     # riscv64-linux-musl gcc (musl-cross-make)  [~20-40 min]
make headers       # riscv kernel headers into the sysroot
make rootfs        # toybox initramfs (also needed for the root fs)
```

The kernel build needs two extra macOS host fixes:

1. **Case-sensitive filesystem.** The Linux tree has files differing only in case
   (e.g. `xt_CONNMARK.h` vs `xt_connmark.h`) that collide on macOS's default
   case-insensitive APFS. Build on a case-sensitive APFS volume/image:
   ```sh
   hdiutil create -size 8g -type SPARSE -fs 'Case-sensitive APFS' \
     -volname tugbuild vendors/tugbuild.sparseimage
   hdiutil attach vendors/tugbuild.sparseimage          # -> /Volumes/tugbuild
   ```
2. **Host-tool headers.** Kernel host tools `#include <elf.h>` (absent on macOS)
   and clash with Darwin's `uuid_t`. We shim with `vendors/khostinc/` (an `elf.h`
   copied from the musl sysroot + a builtin-based `byteswap.h`) and pass
   `-D_UUID_T -D__GETHOSTUUID_H` (the upstream/bee-headers fix) via `HOSTCFLAGS`.

## Build the kernel

```sh
TC=$PWD/vendors/toolchain
GNU=/opt/homebrew/opt
export PATH="$GNU/make/libexec/gnubin:$GNU/bison/bin:$GNU/flex/bin:\
$GNU/coreutils/libexec/gnubin:$GNU/gnu-sed/libexec/gnubin:$GNU/gawk/libexec/gnubin:/opt/homebrew/bin:$PATH"

# kernel source on the case-sensitive volume
curl -fSLo /tmp/linux.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.1.176.tar.xz
tar xf /tmp/linux.tar.xz -C /Volumes/tugbuild
cd /Volumes/tugbuild/linux-6.1.176

# host-tool shim
mkdir -p "$OLDPWD/vendors/khostinc"
cp "$TC/riscv64-linux-musl/include/elf.h" "$OLDPWD/vendors/khostinc/"
printf '#pragma once\n#define bswap_16 __builtin_bswap16\n#define bswap_32 __builtin_bswap32\n#define bswap_64 __builtin_bswap64\n' > "$OLDPWD/vendors/khostinc/byteswap.h"

# config: container2wasm's TinyEMU config + initrd support
curl -fSLo .config https://raw.githubusercontent.com/ktock/container2wasm/main/config/tinyemu/linux_rv64_config
printf 'CONFIG_BLK_DEV_INITRD=y\nCONFIG_RD_GZIP=y\n' >> .config
make ARCH=riscv CROSS_COMPILE="$TC/bin/riscv64-linux-musl-" olddefconfig

# build (the uuid_t / elf.h host-tool fix is in HOSTCFLAGS)
make ARCH=riscv CROSS_COMPILE="$TC/bin/riscv64-linux-musl-" \
  HOSTCFLAGS="-I$OLDPWD/vendors/khostinc -D_UUID_T -D__GETHOSTUUID_H" \
  -j$(sysctl -n hw.ncpu) Image
cp arch/riscv/boot/Image "$OLDPWD/vendors/diskimage/Image-c2w"
```

## Boot it

`make build` produces a `temu` with the rdtime patch. Boot config
(`vendors/diskimage/*.cfg`), using the stock `bbl64.bin` + our kernel + an
initramfs:

```
{ version: 1, machine: "riscv64", memory_size: 256,
  bios: "bbl64.bin", kernel: "Image-c2w", initrd: "<rootfs>.cpio.gz",
  cmdline: "console=hvc0" }
```

`uname` inside the guest then reports `Linux ... 6.1.176 ... riscv64 Toybox`.

## Known issues / TODO

- **virtio-net** does not work on 6.1 + TinyEMU (NETDEV TX watchdog timeout), so
  mkroot's `/init` hangs on its `ifconfig`/`sntp` networking. Boot with a
  network-free init for now; fixing virtio-net negotiation is a follow-up.
- This kernel build is not yet a `make` target (the case-sensitive volume + host
  shims make it macOS-specific); the steps above are the authoritative recipe.
- A freshly built `riscv-pk` bbl (container2wasm static-HTIF recipe) did not work
  in our hands (empty binary); the stock `bbl64.bin` is used instead.
