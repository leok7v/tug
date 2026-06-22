// Minimal VZ harness: boot an arm64 Linux kernel + initramfs, wire the virtio
// serial console to this process's stdin/stdout, and exit when the guest stops.
// Usage: vzboot <Image> <initramfs.cpio.gz> [cmdline]
import Virtualization
import Foundation

func die(_ s: String) -> Never { FileHandle.standardError.write(Data((s+"\n").utf8)); exit(1) }

let a = CommandLine.arguments
guard a.count >= 3 else { die("usage: vzboot Image initramfs [cmdline]") }
let cmdline = a.count >= 4 ? a[3] : "console=hvc0 panic=-1"
let diskPath: String? = a.count >= 5 ? a[4] : nil

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError e: Error) { die("vm error: \(e)") }
}

let cfg = VZVirtualMachineConfiguration()
cfg.cpuCount = 4
cfg.memorySize = 2 << 30          // 2 GiB

let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: a[1]))
boot.initialRamdiskURL = URL(fileURLWithPath: a[2])
boot.commandLine = cmdline
cfg.bootLoader = boot

let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
serial.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: FileHandle.standardInput,
    fileHandleForWriting: FileHandle.standardOutput)
cfg.serialPorts = [serial]
cfg.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
if let dp = diskPath {
    let att = try! VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: dp), readOnly: false)
    cfg.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: att)]
    let net = VZVirtioNetworkDeviceConfiguration(); net.attachment = VZNATNetworkDeviceAttachment()
    cfg.networkDevices = [net]
}

do { try cfg.validate() } catch { die("validate: \(error)") }

let q = DispatchQueue(label: "vm")
let delegate = Delegate()
var vm: VZVirtualMachine!
q.sync { vm = VZVirtualMachine(configuration: cfg, queue: q); vm.delegate = delegate }
q.async { vm.start { if case .failure(let e) = $0 { die("start: \(e)") } } }
dispatchMain()
