// ARM64 guest backend for macOS: a hardware-virtualized Linux VM via Apple's
// Virtualization.framework (over HVF) — ~native speed (≈12× the RISC-V
// interpreter, measured in mac/vz-spike). Boots our own arm64 kernel
// (Image-arm64) + an Alpine aarch64 initramfs, wiring the virtio serial console
// to the same byte streams the terminal already consumes.
//
// Compiled only for the macOS SDK (see EXCLUDED_SOURCE_FILE_NAMES); the iOS
// factory in Platform-iOS.swift never references VZ.

import Foundation
import Virtualization

final class ARM64Session: NSObject, GuestSession, VZVirtualMachineDelegate, @unchecked Sendable {
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let q = DispatchQueue(label: "tug.vz")
    private let inPipe = Pipe()          // host -> guest console
    private let outPipe = Pipe()         // guest -> host console
    private let stopped = DispatchSemaphore(value: 0)
    private var vm: VZVirtualMachine?
    private var socketDevice: VZVirtioSocketDevice?   // host->guest terminal resize
    private var lastCols = 0, lastRows = 0
    private var didShutdown = false

    init(onOutput: @escaping @Sendable ([UInt8]) -> Void,
         onExit:   @escaping @Sendable (Int32) -> Void) {
        self.onOutput = onOutput
        self.onExit = onExit
        super.init()
    }

    func start() {
        guard let kernel = Bundle.main.url(forResource: "kernel-arm64", withExtension: "bin"),
              let initrd = Bundle.main.url(forResource: "initrd-arm64", withExtension: "cgz") else {
            onOutput(Array("[tug] error: arm64 payload missing\r\n".utf8)); return
        }

        let cfg = VZVirtualMachineConfiguration()
        cfg.cpuCount = max(2, min(VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                                  ProcessInfo.processInfo.processorCount))
        cfg.memorySize = 2 << 30          // 2 GiB

        let boot = VZLinuxBootLoader(kernelURL: kernel)
        boot.initialRamdiskURL = initrd
        boot.commandLine = "console=hvc0 panic=-1"
        cfg.bootLoader = boot

        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inPipe.fileHandleForReading,
            fileHandleForWriting: outPipe.fileHandleForWriting)
        cfg.serialPorts = [serial]
        cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        cfg.socketDevices = [VZVirtioSocketDeviceConfiguration()]   // resize channel

        let net = VZVirtioNetworkDeviceConfiguration()      // NAT (no special entitlement)
        net.attachment = VZNATNetworkDeviceAttachment()
        cfg.networkDevices = [net]

        // Persistent Alpine data disk -> /dev/vda. The empty ext4 is expanded from
        // a bundled sparse manifest into Documents on first launch; the guest's
        // initramfs self-seeds Alpine onto it and switch_roots (apk persists).
        if let diskPath = DiskStore.dataDiskPath(resource: "data-arm64",
                                                 filename: "tug-data-arm64.img"),
           let att = try? VZDiskImageStorageDeviceAttachment(
               url: URL(fileURLWithPath: diskPath), readOnly: false) {
            cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: att)]
        } else {
            onOutput(Array("[tug] warning: arm64 data disk unavailable — apk won't persist\r\n".utf8))
        }

        // guest console -> terminal
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            if !d.isEmpty { self?.onOutput([UInt8](d)) }
        }

        do { try cfg.validate() }
        catch { onOutput(Array("[tug] vz config invalid: \(error)\r\n".utf8)); return }

        Guest.current = self
        q.async { [weak self] in
            guard let self else { return }
            let vm = VZVirtualMachine(configuration: cfg, queue: self.q)
            vm.delegate = self
            self.vm = vm
            self.socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice
            vm.start { result in
                if case .failure(let e) = result {
                    self.onOutput(Array("[tug] vz start failed: \(e)\r\n".utf8))
                }
            }
            // re-send the size a few times so it lands once the guest agent is up
            for d in [2.0, 4.0, 7.0] {
                self.q.asyncAfter(deadline: .now() + d) { [weak self] in
                    guard let s = self, s.lastCols > 0 else { return }
                    s.sendWinsize(s.lastCols, s.lastRows)
                }
            }
        }
    }

    func input(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        inPipe.fileHandleForWriting.write(Data(bytes))
    }

    // VZ's serial console has no window-size channel, so send the geometry over
    // vsock to the guest's tug-winsize agent, which sets /dev/console's winsize.
    func resize(cols: Int, rows: Int) {
        lastCols = cols; lastRows = rows
        sendWinsize(cols, rows)
    }

    private func sendWinsize(_ cols: Int, _ rows: Int) {
        q.async { [weak self] in
            guard let dev = self?.socketDevice else { return }
            dev.connect(toPort: 5000) { result in
                guard let conn = try? result.get() else { return }
                let msg = "\(cols) \(rows)\n"
                _ = msg.withCString { write(conn.fileDescriptor, $0, strlen($0)) }
                conn.close()
            }
        }
    }

    func shutdown(timeout: TimeInterval) {
        guard !didShutdown else { return }
        didShutdown = true
        input(Array("poweroff -f\n".utf8))          // clean guest power-off
        if stopped.wait(timeout: .now() + timeout) == .timedOut {
            q.sync { vm?.stop { _ in } }             // force
            _ = stopped.wait(timeout: .now() + 2)
        }
    }

    // VZVirtualMachineDelegate (fires on q)
    func guestDidStop(_ vm: VZVirtualMachine) { stopped.signal(); onExit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError e: Error) {
        stopped.signal(); onExit(1)
    }
}

/// macOS factory: RISC-V interpreter or ARM64 (Virtualization.framework).
func makeGuestSession(_ arch: GuestArch,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) -> any GuestSession {
    switch arch {
    case .riscv: return TugEngine(onOutput: onOutput, onExit: onExit)
    case .arm64: return ARM64Session(onOutput: onOutput, onExit: onExit)
    }
}
