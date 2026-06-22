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
        guard let engine = TugEngine.current else { return .terminateNow }
        // .default QoS: shutdown blocks on the tug-run thread (also .default), so a
        // higher-QoS waiter here would be a priority inversion.
        DispatchQueue.global(qos: .default).async {
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
    }
}
