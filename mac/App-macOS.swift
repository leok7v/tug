// macOS @main entry. A single Window (not a WindowGroup) so there's exactly one
// terminal; closing it quits the app, and quitting (Cmd-Q / window close) powers
// the guest off cleanly first so ext4 is synced + unmounted.
//
// Compiled only for the macOS SDK (see EXCLUDED_SOURCE_FILE_NAMES in project.yml).

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // Single-window app: closing the window quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Power the guest off before we exit. Defer termination, run the (blocking)
    // shutdown off the main thread, then let the app quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = Guest.current else { return .terminateNow }
        // shutdown() blocks on the tug-run thread, which runs at .userInitiated, so
        // wait at the same QoS (no priority inversion).
        DispatchQueue.global(qos: .userInitiated).async {
            engine.shutdown()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

@main
struct BoatApp: SwiftUI.App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var console = Console()

    var body: some Scene {
        Window("Boat", id: "boat") {
            RootView(console: console)
        }
        Settings { BoatSettingsView() }
    }
}

/// Settings (Cmd-,): pick the guest backend. macOS only — iOS has no choice.
struct BoatSettingsView: View {
    @AppStorage("guestArch") private var guestArch = GuestArch.riscv.rawValue

    var body: some View {
        Form {
            Picker("Guest architecture", selection: $guestArch) {
                ForEach(GuestArch.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            Text("RISC-V runs the TinyEMU interpreter (portable, the iOS/Android "
               + "engine). ARM64 runs a hardware-virtualized Linux via Apple "
               + "Virtualization (≈12× faster — macOS only). Switching restarts "
               + "the guest.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 420)
    }
}
