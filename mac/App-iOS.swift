// iOS / iPadOS @main entry. A WindowGroup with the shared RootView. (Window
// close / app termination isn't user-driven the way it is on macOS, so there's
// no single-window/quit handling here; ext4's journal recovers on next launch.)
//
// Compiled only for the iOS SDK (see EXCLUDED_SOURCE_FILE_NAMES in project.yml).

import SwiftUI

@main
struct BoatApp: SwiftUI.App {
    @State private var console = Console()

    var body: some Scene {
        WindowGroup {
            RootView(console: console)
        }
    }
}
