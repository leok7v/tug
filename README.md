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

## Layout

```
Makefile            download → toolchain → toybox/tcc → rootfs → ext2 → boot
compat/             macOS build shims (keep vendored source pristine)
patches/            functional emulator patches (rdtime CSR), applied on extract
scripts/            smoke.sh, bootfs.sh — non-interactive boot assertions
docs/kernel.md      reproducible "our 6.x kernel on TinyEMU" recipe
vendors/            downloads + extracted sources + build (gitignored)
```

## Next

- Fix virtio-net on 6.x+TinyEMU (mkroot's init networking currently times out);
  resolve tcc in-guest self-linking against a tcc-friendly libc.
- Phase 2: standalone host-orchestrator C shell; measure RSS/overhead.
- Deferred until a baseline benchmark exists: direct-threaded interpreter,
  Mach-exception MMU, register pinning, AOT (see `PLAN.md` §3).
