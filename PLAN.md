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
