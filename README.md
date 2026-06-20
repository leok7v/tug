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

## Status — Milestone 0: TinyEMU bring-up ✅

Unmodified [TinyEMU](https://bellard.org/tinyemu/) (Bellard, MIT) builds headless
on Apple Silicon and boots Bellard's stock riscv64 Linux 4.15 to a shell.

- 260 KB arm64 `temu`, **no external libraries** (FS_NET/SDL/x86/int128 off).
- Vendored source stays **100% pristine**; all macOS portability is isolated in
  `compat/` shim headers (no patches to TinyEMU).
- `make smoke` boots non-interactively and asserts a shell is reached.

```sh
make vendors   # curl + checksum TinyEMU source and the riscv64 disk image
make build     # compile headless temu
make smoke     # boot, run commands, assert shell, power off  -> SMOKE: PASS
make boot      # interactive boot (exit emulator: Ctrl-a x)
```

## Layout

```
Makefile            orchestrates download/build/boot
compat/             macOS shim headers (keep vendored source pristine)
scripts/smoke.sh    non-interactive boot assertion
vendors/            downloads + extracted sources + build (gitignored)
```

## Next

- **Milestone 1:** replace the stock image with our own payload built via
  toybox `mkroot` (riscv64 musl toolchain + kernel + toybox + tcc), booted by
  the same unmodified `temu`. Proves the guest pipeline we control.
- Deferred until a baseline benchmark exists: direct-threaded interpreter,
  Mach-exception MMU, register pinning, AOT (see `PLAN.md` §3).
