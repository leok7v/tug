# tug

A minimalist, zero-dependency RISC-V Linux sandbox for agentic use on
execution-locked platforms (iOS/Android), with faster native paths where the
host allows. Guest = a Unix kernel in a box (toybox + tcc + later python/js).

The design rationale lives in `PLAN.md`. This README tracks what actually works.

## Why RISC-V (and not the host ISA)

iOS/Android App Store sandboxes forbid executing code generated at runtime
(W^X, no JIT entitlement), so on those platforms we **interpret**. RISC-V is the
simplest orthogonal ISA to interpret, so it's the portable guest everywhere.

Two speed tiers, deliberately separate:
- **Locked platforms (iOS/Android):** pure interpreter (TinyEMU core). The only
  viable path. This is the spine of the project.
- **Open platforms (macOS/Linux/Windows):** JIT/AOT-translate the *same* RISC-V
  image to host code — one payload everywhere.

Note: Hypervisor.framework / KVM cannot accelerate a RISC-V guest (no RISC-V
silicon on Apple/x86 hosts). A host-arch hypervisor VM is a *separate* product
with *different* (arm64/x86) images; it is deferred, not part of this spine.

## Status

### Milestone 0 — TinyEMU bring-up ✅

[TinyEMU](https://bellard.org/tinyemu/) (Bellard, MIT) builds headless on Apple
Silicon and boots Bellard's stock riscv64 Linux 4.15 to a shell.

- ~260 KB arm64 `temu`, **no external libraries** (FS_NET/SDL/x86/int128 off).
- macOS *build* portability is isolated in `compat/` shim headers; the only
  *functional* change is one tiny patch in `patches/` (see Milestone 1).
- `make smoke` boots non-interactively and asserts a shell is reached.

```sh
make deps      # (macOS, one-time) Homebrew GNU build userland
make vendors   # curl + checksum TinyEMU source and the riscv64 disk image
make build     # compile temu (applies patches/)
make smoke     # boot stock 4.15, assert shell -> SMOKE: PASS
make bootfs    # boot OUR rootfs as init on the stock kernel -> BOOTFS: PASS
```

### Milestone 1 — our own payload, incl. a modern kernel ✅

Built entirely **natively on macOS, no Docker / no fork / no heavy deps**:

- **Toolchain:** riscv64-linux-musl GCC 13.3 via musl-cross-make (`make toolchain`).
- **toybox** rootfs via mkroot (`make rootfs`), packed as ext2 (`make ext2`).
- **tcc** cross-compiler built; codegen verified (in-guest self-link deferred).
- **Our own Linux 6.1.176 kernel** boots on TinyEMU running our toybox userspace
  (`uname` → `6.1.176 … riscv64 Toybox`). The one ingredient TinyEMU lacked was
  the unprivileged `time` CSR (`rdtime`) modern userspace needs — a 6-line CPU
  patch (`patches/tinyemu-rdtime.patch`, auto-applied by `make build`). See
  [`docs/kernel.md`](docs/kernel.md) for the full reproducible recipe.
  `make boot6` boots it to an interactive shell (`make boot6 MODE=test` asserts).

### Phase 2 — standalone host orchestrator ✅ (in progress)

`src/tug.c` (`make orchestrator` → `./tug`) is a ~200 KB pure-C program that drives
the TinyEMU core **programmatically** — no JSON config, no SDL/x86/net — loading
bios/kernel/initrd into memory and wiring the guest console to host stdio. This is
the embeddable "kernel in a box" core for the iOS/Android path.

Measured booting our 6.1 kernel + toybox initramfs to userspace (`./tug -b …`):

| guest RAM | peak RSS | boot wall-time |
|----------:|---------:|---------------:|
| 32 MiB    | 38.5 MiB | 0.15 s |
| 64 MiB    | 70.5 MiB | 0.15 s |
| 128 MiB   | 134.5 MiB| 0.16 s |

→ **~6.5 MiB fixed emulator overhead** (RSS = guest RAM + 6.5), boots in as little
as **32 MiB**, sub-0.2 s to userspace. A full modern Linux sandbox in ~38 MiB.

## Run it interactively (macOS Terminal.app)

The `smoke` / `bootfs` / `boot6 MODE=test` targets assert non-interactively. To
actually *use* the guest from your `zsh` prompt, run one of these in the foreground
(your terminal is attached, so typing works):

**Stock riscv64 Linux — works right after `make build`:**
```sh
make boot                 # Bellard's stock 4.15 image -> a shell
                          # exit the emulator: press Ctrl-a, then x
```

**Our own Linux 6.x -> interactive toybox shell** (needs the 6.x kernel built, see
[`docs/kernel.md`](docs/kernel.md); the artifacts live in `vendors/diskimage/`):
```sh
make boot6                # boots our 6.1 kernel to a toybox shell
# at the  $  prompt, try:
#   uname -a
#   cat /proc/cpuinfo
#   ls -l / ; echo hi > /tmp/x ; cat /tmp/x
# leave with:  poweroff -f   (clean) — or Ctrl-a x to kill the emulator
```

**The standalone orchestrator (`./tug`)** — same guest, driven by our own binary
instead of `temu`. Run `make boot6` once first (it leaves an interactive rootfs at
`vendors/diskimage/tug6.cpio.gz`), then:
```sh
make orchestrator
./tug -a "console=hvc0 virtio_net.napi_tx=false" \
      vendors/diskimage/bbl64.bin \
      vendors/diskimage/Image-c2w \
      vendors/diskimage/tug6.cpio.gz
# add -b for boot-time + peak-RSS stats; poweroff -f to exit
```

## Layout

```
Makefile            download → toolchain → toybox/tcc → rootfs → ext2 → boot
src/tug.c           standalone programmatic orchestrator (make orchestrator)
config/tug-init     TinyEMU-appropriate pid-1 init for the full-system boot
compat/             macOS build shims (keep vendored source pristine)
patches/            functional emulator patches (rdtime CSR), applied on extract
scripts/            smoke.sh, bootfs.sh, boot6.sh — non-interactive boot assertions
docs/kernel.md      reproducible "our 6.x kernel on TinyEMU" recipe
vendors/            downloads + extracted sources + build (gitignored)
```

## Next

- Phase 2 cont.: trim the orchestrator's linked objects (drop 9p/fs, simplefb)
  for a minimal iOS build; embed the payload; stand up iOS/Android targets.
- Phase 3 (now that we have a baseline — ~6.5 MiB overhead, 0.15 s boot):
  direct-threaded interpreter, Mach-exception MMU, register pinning, AOT
  (see `PLAN.md` §3).
- tcc in-guest self-linking (needs a tcc-friendly libc); make the kernel build a
  `make` target.
