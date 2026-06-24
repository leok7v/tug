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
