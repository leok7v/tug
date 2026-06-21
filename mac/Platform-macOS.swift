// macOS root layout: just the Terminal — the Mac's hardware keyboard drives it
// (no on-screen keyboard). Keys reach the terminal via TerminalView's .onKeyPress.
//
// Compiled only for the macOS SDK (see EXCLUDED_SOURCE_FILE_NAMES in project.yml),
// so there is no `#if os(...)` here.

import SwiftUI

struct RootView: View {
    let console: Console

    var body: some View {
        TerminalView(console: console)
            .frame(minWidth: 520, minHeight: 360)
            .background(Term.bg)
    }
}
