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

`make embed` goes one step further: it `.incbin`s the bios + kernel + an
interactive rootfs into the binary, producing **`./tug-embedded`** — a single
**~5 MB self-contained executable** that boots our 6.1 Linux to a shell with **no
external files and no arguments** (run it from anywhere). That's the iOS/Android
app-bundle shape: one binary = the whole sandbox.

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

**Self-contained binary — nothing external:**
```sh
make embed                # -> ./tug-embedded (~5 MB, payload baked in)
./tug-embedded            # boots our 6.1 Linux to a shell, from anywhere, no args
```

### Phase 4 — persistent Alpine userland with `apk` ✅

The toybox guest above is read-only and ephemeral. For an installable, persistent
userland we vendor the **Alpine 3.24 riscv64 minirootfs** and a **persistent ext4
data disk**, so inside the guest you can:

```sh
apk update && apk add bash clang nodejs npm python3 py3-pip cargo
```

…and it **persists across runs**, with room for agents to build code and use `/tmp`.

```sh
make alpine               # vendor the Alpine minirootfs (apk seed), sha256-checked
make disk                 # create tug-data.img — a sparse 32G ext4 disk (~13M on host)
                          #   override size: make disk DISK_SIZE=64G
                          #   (forcing a rebuild ERASES tug-data.img and its contents)
make apkboot              # boot it interactively; first run seeds /dev/vda from the
                          #   baked Alpine seed, then switch_roots into Alpine
make apkboot MODE=test    # non-interactive: assert mount + seed + apk + (slow) update
```

How it works: our 6.1 kernel already has `VIRTIO_BLK` + `EXT4` built in, so the
data disk attaches as `/dev/vda` (no kernel rebuild, no TinyEMU patch — the
orchestrator drives the existing block-device API). A toybox initramfs (`/init`
= `config/tug-apk-init`) mounts `/dev/vda`, and on first boot extracts the Alpine
tarball onto it, drops in DNS (`10.0.2.3`) + our CA bundle, then `switch_root`s
into Alpine. `apk` then reaches `dl-cdn.alpinelinux.org` over the slirp NAT with
TLS — verified: `apk update` pulls both main+community indexes and `apk add bash`
installs and survives a reboot.

Self-contained apk binary (Alpine seed baked in):
```sh
make embed-apk            # -> ./tug-embedded-apk (Alpine seed + apk-init inside)
make disk && ./tug-embedded-apk   # auto-attaches ./tug-data.img (or $TUG_DISK / -d)
```

The disk attaches via `./tug -d tug-data.img …` for the plain orchestrator, or is
auto-detected (`tug-data.img` beside the binary, or `$TUG_DISK`) for the embedded
builds; `-d ""` disables it.

## Layout

```
Makefile            download → toolchain → toybox/tcc → rootfs → ext2 → boot
src/tug.c           standalone programmatic orchestrator (+ virtio-blk data disk)
config/tug-init     TinyEMU-appropriate pid-1 init for the full-system boot
config/tug-apk-init pid-1 init that seeds + switch_roots into the Alpine apk disk
compat/             macOS build shims (keep vendored source pristine)
patches/            functional emulator patches (rdtime CSR), applied on extract
scripts/            smoke.sh, bootfs.sh, boot6.sh, apkboot.sh — boot assertions
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
