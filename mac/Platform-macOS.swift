// macOS root layout: just the Terminal — the Mac's hardware keyboard drives it
// (no on-screen keyboard). Keys reach the terminal via TerminalView's .onKeyPress.
//
// Compiled only for the macOS SDK (see EXCLUDED_SOURCE_FILE_NAMES in project.yml),
// so there is no `#if os(...)` here.

import SwiftUI
import AppKit

struct RootView: View {
    let console: Console

    var body: some View {
        TerminalView(console: console)
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // fill the window (width too)
            .frame(minWidth: 520, minHeight: 360)
            .background(Term.bg)
    }
}

/// System clipboard (macOS).
enum Pasteboard {
    static var string: String? { NSPasteboard.general.string(forType: .string) }
    static func set(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

extension View {
    /// Shift-click extends the terminal selection (macOS; `.modifiers` is macOS-only).
    func shiftClickExtend(in space: String, _ action: @escaping (CGPoint) -> Void) -> some View {
        highPriorityGesture(
            SpatialTapGesture(coordinateSpace: .named(space))
                .modifiers(.shift)
                .onEnded { action($0.location) })
    }
}

/// Real metrics of the monospaced system font, so the terminal's cell grid and
/// the mouse hit-testing match what SwiftUI actually draws.
enum FontMetrics {
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return (f.ascender - f.descender + f.leading).rounded(.up)
    }
    static func advance(_ size: CGFloat) -> CGFloat {
        let f = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: f]).width
    }
}
