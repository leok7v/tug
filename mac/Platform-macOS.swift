import SwiftUI
import AppKit

struct RootView: View {
    let console: Console

    var body: some View {
        TerminalView(console: console)
            .frame(maxWidth: .infinity, maxHeight: .infinity) // fill the window
            .frame(minWidth: 520, minHeight: 360)
            .background(Term.bg)
    }
}

enum Pasteboard {
    static var string: String? { NSPasteboard.general.string(forType: .string) }
    static func set(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

extension View {
    func shiftClickExtend(in space: String, _ action: @escaping (CGPoint) -> Void) -> some View {
        highPriorityGesture(
            SpatialTapGesture(coordinateSpace: .named(space))
                .modifiers(.shift)
                .onEnded { action($0.location) })
    }
}

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
