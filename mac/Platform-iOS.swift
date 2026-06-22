// iOS / iPadOS root layout: Terminal on top, 102-key soft keyboard on the bottom
// (a vertical split). A wired or Bluetooth hardware keyboard also works — its keys
// reach the terminal through TerminalView's .onKeyPress, so both inputs coexist.
//
// Compiled only for the iOS SDK (see EXCLUDED_SOURCE_FILE_NAMES in project.yml),
// so there is no `#if os(...)` here.

import SwiftUI
import UIKit

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

/// System clipboard (iOS).
enum Pasteboard {
    static var string: String? { UIPasteboard.general.string }
    static func set(_ s: String) { UIPasteboard.general.string = s }
}

/// iOS has no hardware virtualization — always the RISC-V interpreter.
func makeGuestSession(_ arch: GuestArch,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) -> any GuestSession {
    TugEngine(onOutput: onOutput, onExit: onExit)
}

extension View {
    /// No shift-click on iOS — the hardware-keyboard modifier gesture is macOS-only.
    func shiftClickExtend(in space: String, _ action: @escaping (CGPoint) -> Void) -> some View { self }
}

/// Real metrics of the monospaced system font, so the terminal's cell grid and
/// touch hit-testing match what SwiftUI actually draws.
enum FontMetrics {
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight.rounded(.up)
    }
    static func advance(_ size: CGFloat) -> CGFloat {
        ("M" as NSString).size(withAttributes:
            [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
    }
}
