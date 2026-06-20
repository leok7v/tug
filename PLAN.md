# PLAN — Minimalist RISC-V Sandbox Agent

> Status note (2026-06): This is the aspirational design. What actually works
> today is tracked in `README.md`. Two corrections to the original plan, decided
> with the maintainer:
> - **Hypervisor.framework cannot accelerate a RISC-V guest** (no RISC-V silicon
>   on Apple/x86 hosts). The "HVF accel" idea is dropped. The open-platform
>   speedup that keeps a single RISC-V image is JIT/AOT translation (§3 Ext.4),
>   not a hypervisor. A host-arch hypervisor VM is a separate, deferred product
>   with different (arm64/x86) images.
> - The three perf extensions below + AOT are **deferred** until a working
>   baseline + benchmark exists. We proceed in small, proven steps.

Reference projects: TinyEMU (https://bellard.org/tinyemu/), toybox + mkroot
(https://github.com/landley/toybox), tinycc (https://github.com/tinycc/tinycc).

## 1. Core Architecture & Objectives
A highly optimized, zero-dependency sandboxed execution environment for local
agents. An extended TinyEMU (RISC-V 64-bit) runs a bare-metal Linux payload
(mkroot) combined with toybox and tinycc (tcc).

### Principles
* Statically link all host and guest components — no dynamic runtime deps.
* Use native hardware acceleration where the platform allows code execution.
* Fall back to an optimized software interpreter on locked platforms (iOS) to
  respect W^X sandbox constraints.
* Avoid heavy container runtimes, daemons, or complex namespace configuration.

## 2. Component Specifications

### Host Orchestrator & Emulator
* Language: Pure C (C11/C23).
* Core engine: TinyEMU (`riscv_cpu.c`, `machine.c`).
* I/O: serial console over stdio, virtio-block storage, virtio-net.
* Formats: Mach-O for macOS and iOS app integration.

### Guest OS Payload (RISC-V 64-bit)
* Kernel: Linux via mkroot (minimalist build system).
* User space: toybox (static) — shell + core utilities.
* Compiler: tinycc (tcc, rv64, static) for in-guest C compilation.

## 3. Targeted Performance Extensions for TinyEMU (DEFERRED)

### Extension 1: Direct-Threaded RISC-V Interpreter
Replace the switch-based decode loop with a direct-threaded (computed-goto) loop;
pre-decode opcodes into execution tokens with direct handler pointers to cut host
branch mispredicts. (Interpreter-only; compatible with W^X.)

### Extension 2: Mach Exception Native MMU Mapping
Allocate guest RAM as a contiguous host VM block; mirror guest page protections
to host permissions where possible; catch `EXC_BAD_ACCESS` via a Mach exception
handler to service faults/MMIO natively, bypassing the software TLB loop.

### Extension 3: Host Register Pinning
Use compiler global register variables to pin high-frequency guest CPU-state
fields (PC, SP, hot GPRs) into host AArch64 registers. (Fragile on Darwin: x18 is
platform-reserved; measure before investing.)

### Extension 4: Static Binary Translation (AOT)
For known binaries (kernel, toybox, interpreters), translate rv64 ELF → C/LLVM IR
ahead of time and compile into the host app for near-native speed where codegen
is permitted. Agent-generated in-guest code still flows through the interpreter.

## 4. Phase-by-Phase Execution Plan

### Phase 1: Toolchain and Guest Payload Build
1. Acquire a riscv64-linux-musl cross toolchain (prebuilt, pinned).
2. Build a minimalist Linux kernel via mkroot.
3. Cross-compile toybox and tcc as static rv64 binaries.
4. Pack user space into an initramfs/rootfs.
5. Verify boot on an unmodified reference emulator. ✅ (TinyEMU bring-up done)

### Phase 2: Host Orchestrator & Native macOS Integration
1. Integrate the TinyEMU core into a standalone pure-C shell.
2. Wire host↔guest channels via serial console fds.
3. Measure base RSS footprint and execution overhead on Apple Silicon.

### Phase 3: Optimization & Core Extensions
1. Establish a baseline benchmark.
2. Implement Ext.1 (direct threading); measure.
3. Implement Ext.3 (register pinning); measure.
4. Implement Ext.2 (Mach-exception MMU); measure.

### Phase 4: Network and Storage I/O Finalization
1. virtio-block backed by a raw/memory-mapped image.
2. virtio-net bridged to the host stack.
3. Validate that guest execution never breaches the host process sandbox.

---

## 4a. Near-term priorities (do next)

**[HIGH] virtio-block write path: drop per-write `fflush`.**
`tug_block_device_init` in `src/tug.c` currently calls `fflush()` on *every*
`write_async`. Seeding the Alpine userland onto `/dev/vda` is thousands of small
file writes, each forced synchronously to host disk under the interpreter — so
first-boot seeding takes **minutes instead of seconds**, and `apk add` of large
toolchains (clang/rust) would be punishingly slow. Fix: buffer writes and flush
only on guest `sync`/flush requests and at exit (or `mmap` the image / use
`O_DIRECT`-free buffered IO without the forced flush). This is a cheap change
with an outsized payoff for the whole apk-on-disk workflow — land it before the
`apk-integration` branch merges. Verified working but slow via
`make apkboot MODE=test` (mount + seed + `apk` all PASS).

Follow-ups (lower): virtio-block **discard/TRIM** passthrough so deleting guest
files punches holes and the sparse `tug.img` can shrink (today it only grows);
and a host-side `make compact` that rebuilds the image to reclaim space until
discard exists.

---

## 5. Long-Term Targets (forward-looking)

The end goal is an on-device developer sandbox: a real Linux where heavy
toolchains are **downloaded and installed on demand** (SSD is abundant), not
shipped in the app bundle. Targets: latest **Python + pip**, **Node.js + npm**
(JavaScript/TypeScript), **LLVM/clang C++**, and **Rust (rustc + cargo)**.

### 5.1 Feasibility

Doable in principle: each is ordinary `riscv64-linux` userland with upstream/
distro builds (Debian, Alpine). Our guest is a real Linux kernel + userspace, so
"if a riscv64 build exists, it runs." Storage is not a constraint; RAM up to
~1 GB covers all of it except possibly heavy LTO link steps. The only real
constraint is **execution speed**, not feasibility.

### 5.2 Performance guesstimates (pure interpreter, current baseline)

Relative to native; today's interpreter is the floor, JIT/AOT (open platforms)
and Phase-3 extensions are the ceiling.

| Workload                         | Rough slowdown | Felt experience |
|----------------------------------|---------------:|-----------------|
| Python / Node runtime, JS/TS     | ~10–30×        | usable; scripts fine, `pip`/`npm install` slow |
| clang/C++ compile, rustc/cargo   | ~20–50×        | works but painful; a 5 s native build → minutes |
| I/O-bound (download, unpack)     | ~1–3×          | near-native (host-backed) |

These are order-of-magnitude estimates to be replaced by real measurements once
Phase 3 has a benchmark. The compile-bound cases are exactly what the perf
extensions and the open-platform JIT/AOT path must rescue.

### 5.3 Networking (near-term)

Simplest viable path: **slirp user-mode NAT** (already in TinyEMU; just not linked
into `tug` yet). No host privileges, no tap/bridge — guest gets `10.0.2.x`, NAT to
the host's stack for outbound Internet, which `pip`/`npm`/`cargo` need. virtio-net
on 6.x requires `virtio_net.napi_tx=false` (see `docs/kernel.md`). This is the
near-term enabler for on-demand toolchain install.

### 5.4 macOS as an iOS performance proxy

Per-core throughput on an Apple-Silicon Mac approximates a modern iOS device
within single-digit percent, so **interpreter-speed numbers transfer**. Caveat:
macOS *permits* JIT and iOS does not — so any JIT/codegen wins measured on macOS
will **not** exist on locked iOS. The honest iOS proxy is the **pure-interpreter**
number; treat JIT results as the open-platform (macOS/Linux/Windows) tier only.

### 5.5 Terminal

Manual sessions today rely on the **host terminal** (Terminal.app / iTerm) as the
VT100/xterm emulator: `tug` passes the guest's escape codes straight through and
reports window size; the guest exports `TERM=vt100`. That's enough for toybox
(which emits ANSI directly) and any host-driven session. Forward work:

- **Bundle a minimal terminfo DB** (vt100 / linux / xterm) in the rootfs so
  ncurses/readline programs — python/node REPLs, vim, less — work fully. Deferred
  until those toolchains land (§5.1); small footprint.
- **In-app VT100 emulator inside `tug`** for **iOS**, where there is no host
  terminal to render the guest's escapes: a libvterm-class state machine driving a
  text-grid view (parse SGR/cursor/scroll, feed keyboard input). Real but bounded
  code — the iOS counterpart to today's passthrough. Future.
