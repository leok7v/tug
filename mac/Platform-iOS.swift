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
        .ignoresSafeArea(.keyboard) // we render our own keyboard
    }

}

enum Pasteboard {
    static var string: String? { UIPasteboard.general.string }
    static func set(_ s: String) { UIPasteboard.general.string = s }
}

func makeGuestSession(_ arch: GuestArch,
                      onOutput: @escaping @Sendable ([UInt8]) -> Void,
                      onExit: @escaping @Sendable (Int32) -> Void) -> any Session {
    TugEngine(onOutput: onOutput, onExit: onExit)
}

extension View {

    func shiftClickExtend(in space: String, _ action: @escaping (CGPoint) -> Void) -> some View { self }

}

enum FontMetrics {

    static func lineHeight(_ size: CGFloat) -> CGFloat {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular).lineHeight.rounded(.up)
    }

    static func advance(_ size: CGFloat) -> CGFloat {
        ("M" as NSString).size(withAttributes:
            [.font: UIFont.monospacedSystemFont(ofSize: size, weight: .regular)]).width
    }

}
