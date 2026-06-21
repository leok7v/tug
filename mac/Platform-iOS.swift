// iOS / iPadOS root layout: Terminal on top, 102-key soft keyboard on the bottom
// (a vertical split). A wired or Bluetooth hardware keyboard also works — its keys
// reach the terminal through TerminalView's .onKeyPress, so both inputs coexist.
//
// Compiled only for the iOS SDK (see EXCLUDED_SOURCE_FILE_NAMES in project.yml),
// so there is no `#if os(...)` here.

import SwiftUI

struct RootView: View {
    let console: Console

    var body: some View {
        VStack(spacing: 0) {
            TerminalView(console: console)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            SoftKeyboardView(console: console)
        }
        .background(Term.bg)
        .ignoresSafeArea(.keyboard)   // we render our own keyboard, not the system one
    }
}
