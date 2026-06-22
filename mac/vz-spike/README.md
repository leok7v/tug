# vz-spike — RISC-V (temu) vs ARM64 (HVF/Virtualization.framework)

A measurement spike: how much faster is a hardware-virtualized ARM64 guest on the
Mac (Apple Virtualization.framework, over HVF) than the RISC-V TinyEMU interpreter
we ship to iOS/Android? Answer, validated end-to-end with our own kernel:

| backend                          | Miter/s | vs temu |
|----------------------------------|--------:|--------:|
| temu riscv64 (iOS/Android path)  |   63.4  |    1×   |
| native arm64 (proxy)             |   ~800  |  ~12.6× |
| **VZ arm64, our own kernel**     | **785** | **12.4×** |

Same workload, identical checksum across all three → a fair comparison. VZ runs
ARM64 at ~98% of native; the proxy (native arm64) matches the real VZ run.

This is why macOS (the prime usage target) should run an ARM64 guest under VZ while
iOS/Android keep the RISC-V interpreter. The terminal UI is backend-agnostic (byte
streams), so the two plug in behind one `GuestSession` seam.

## Files (source; generated artifacts are gitignored)

- `bench.c` — self-timing integer kernel. On Linux it runs as PID 1 (init): time,
  print, power off. On macOS it just times+prints (native proxy).
- `vzboot.swift` — minimal VZ harness: boot kernel + initramfs, wire the virtio
  serial console to stdin/stdout, exit on guest power-off. ~40 lines.
- `vz.entitlements` — `com.apple.security.virtualization`; ad-hoc `codesign -s -`
  is enough for local dev (no provisioning profile).
- `build-arm64-kernel.sh` — builds our own arm64 `Image` natively on macOS,
  mirroring the riscv `docs/kernel.md` recipe: case-sensitive APFS volume + host
  shims (`elf.h`/`endian.h`/`uuid_t`), `LLVM=1` (clang is the only arm64-Linux
  compiler that runs on macOS), Linux 6.12 `defconfig` + virtio/initrd, KVM off.

## Reproduce

```sh
# aarch64 cross sysroot (musl.cc; the gcc binary is Linux-hosted, but its sysroot
# + libgcc are usable by macOS clang) and LLVM/lld:
curl -fSL https://musl.cc/aarch64-linux-musl-cross.tgz | tar xz -C ../../vendors/
brew install llvm lld

CLANG=$(brew --prefix llvm)/bin/clang
LLD=$(brew --prefix lld)/bin/ld.lld
GCC=../../vendors/aarch64-linux-musl-cross
SR=$GCC/aarch64-linux-musl

# benches
../../vendors/toolchain/bin/riscv64-linux-musl-gcc -O2 -static bench.c -o bench-riscv
$CLANG --target=aarch64-linux-musl --sysroot=$SR --gcc-toolchain=$GCC \
       --ld-path=$LLD -static -O2 bench.c -o bench-arm64
clang -O2 bench.c -o bench-native             # native macOS proxy

# initramfs (bench as static /init)
for a in riscv arm64; do rm -rf r && mkdir r && cp bench-$a r/init && chmod +x r/init
  (cd r && find . | cpio -o -H newc 2>/dev/null | gzip) > bench-$a.cpio.gz; done; rm -rf r

# our arm64 kernel  ->  ../../vendors/diskimage/Image-arm64
./build-arm64-kernel.sh

# VZ harness (sign with the entitlement)
swiftc -O vzboot.swift -o vzboot
codesign --force --sign - --entitlements vz.entitlements vzboot

# measure
./vzboot ../../vendors/diskimage/Image-arm64 bench-arm64.cpio.gz       # VZ arm64
./bench-native                                                          # native proxy
( cd ../.. && ./tug -a "console=hvc0" vendors/diskimage/bbl64.bin \
   vendors/diskimage/Image-c2w mac/vz-spike/bench-riscv.cpio.gz )      # temu riscv
```
