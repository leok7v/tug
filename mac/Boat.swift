// Boat — a universal SwiftUI terminal shell for tug.
//
// Shared, platform-agnostic code (no `#if os(...)`). The per-platform root layout
// lives in Platform-iOS.swift / Platform-macOS.swift, each of which defines a
// `RootView` — iOS/iPadOS stacks Terminal over a 102-key soft keyboard; macOS is
// just the Terminal. Both also take a hardware (wired/Bluetooth) keyboard.
//
// The shell is a small local demo today; the seam to drive the real tug RISC-V
// engine is `Console.run(_:)` — that's where the emulator plugs in.

import SwiftUI

// MARK: - App entry

@main
struct BoatApp: App {
    @State private var console = Console()
    var body: some Scene {
        WindowGroup {
            RootView(console: console)   // defined per-platform
        }
    }
}

// MARK: - Input model

/// A resolved key event. Soft keys and the hardware keyboard both produce these;
/// the eventual tug bridge converts the "reserved" cases into terminal bytes.
enum KeyInput: Sendable {
    case text(String)        // one or more printable characters
    case enter, backspace, tab, esc
    case ctrl(Character)     // Ctrl + key
    case up, down, left, right
}

// MARK: - Console (terminal state + demo shell)

@MainActor @Observable
final class Console {
    private(set) var text = ""        // entire visible buffer (output + local echo)
    private var lineBuffer = ""       // the command line being typed
    private let prompt = "boat:~$ "
    private let maxChars = 200_000

    init() { emit(Self.banner); emit(prompt) }

    private func emit(_ s: String) {
        text += s
        if text.count > maxChars { text.removeFirst(text.count - maxChars) }
    }

    /// Feed a key from either keyboard.
    func send(_ key: KeyInput) {
        switch key {
        case .text(let s):
            let printable = String(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
            guard !printable.isEmpty else { return }
            lineBuffer += printable
            emit(printable)
        case .enter:
            emit("\n")
            run(lineBuffer.trimmingCharacters(in: .whitespaces))
            lineBuffer = ""
            emit(prompt)
        case .backspace:
            if !lineBuffer.isEmpty { lineBuffer.removeLast(); if !text.isEmpty { text.removeLast() } }
        case .ctrl(let c):
            switch Character(c.lowercased()) {
            case "c": emit("^C\n"); lineBuffer = ""; emit(prompt)
            case "u": while !lineBuffer.isEmpty { lineBuffer.removeLast(); if !text.isEmpty { text.removeLast() } }
            case "l": text = ""; emit(prompt + lineBuffer)
            default: break          // other Ctrl combos: reserved for the tug bridge
            }
        case .tab, .esc, .up, .down, .left, .right:
            break                   // reserved for the tug bridge
        }
    }

    // The seam where the tug RISC-V engine will take over from this demo shell.
    private func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let cmd = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "":        break
        case "help":    emit("commands: help  echo <s>  date  clear  uname  about  ls  whoami\n")
        case "echo":    emit(arg + "\n")
        case "date":    emit(Date().formatted(date: .abbreviated, time: .standard) + "\n")
        case "clear":   text = ""
        case "uname":   emit("Boat 0.1 (riscv64 sandbox shell) — tug engine pending\n")
        case "whoami":  emit("skipper\n")
        case "ls":      emit("bin   etc   home   tmp   usr\n")
        case "about":
            emit("Boat — the terminal for tug.\n")
            emit("A whole Linux in one unprivileged binary will run right here.\n")
            emit("Today this is a local demo shell; the tug RISC-V engine plugs into run().\n")
        default:        emit("boat: command not found: \(cmd)   (try 'help')\n")
        }
    }

    static let banner = """
      ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~ ~
         _____
        /     \\__   .  o            BOAT
       |  tug  |_ \\____            a terminal for the tug sandbox
       \\______(_)___)             type 'help' or 'about'
      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

    """
}

// MARK: - Terminal view (renders the console, takes hardware-keyboard input)

enum Term {
    static let bg = Color(red: 0.043, green: 0.055, blue: 0.078)   // near-black ink
    static let fg = Color(red: 0.84,  green: 0.88,  blue: 0.98)
    static let fontSize: CGFloat = 13
}

struct TerminalView: View {
    let console: Console
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(console.text + "▏")
                    .font(.system(size: Term.fontSize, weight: .regular, design: .monospaced))
                    .foregroundStyle(Term.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("bottom")
            }
            .background(Term.bg)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: console.text) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // .down AND .repeat: macOS coalesces rapid/held presses into key-repeat
        // events, so a .down-only handler swallows fast Return/key presses.
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let mods = press.modifiers
        if mods.contains(.command) { return .ignored }   // leave ⌘-shortcuts to the system
        let key = press.key
        if key == .return        { console.send(.enter);     return .handled }
        if key == .delete        { console.send(.backspace); return .handled }
        if key == .tab           { console.send(.tab);       return .handled }
        if key == .escape        { console.send(.esc);       return .handled }
        if key == .upArrow       { console.send(.up);        return .handled }
        if key == .downArrow     { console.send(.down);      return .handled }
        if key == .leftArrow     { console.send(.left);      return .handled }
        if key == .rightArrow    { console.send(.right);     return .handled }
        if mods.contains(.control), let c = press.characters.first {
            console.send(.ctrl(c)); return .handled
        }
        if !press.characters.isEmpty { console.send(.text(press.characters)); return .handled }
        return .ignored
    }
}

// MARK: - 102-key soft keyboard

enum KeyKind: Sendable {
    case char
    case mod(Mod)
    case special(KeyInput)
    case fn                      // F-keys: present for completeness, reserved
}
enum Mod: Sendable { case shift, ctrl, alt, caps }

struct KKey: Identifiable, Sendable {
    let id = UUID()
    let kind: KeyKind
    let cap: String              // unshifted label / character
    let shiftCap: String         // shifted label / character
    let weight: CGFloat          // relative width within its row

    static func c(_ lower: String, _ upper: String, _ w: CGFloat = 1) -> KKey {
        KKey(kind: .char, cap: lower, shiftCap: upper, weight: w)
    }
    static func k(_ label: String, _ input: KeyInput, _ w: CGFloat = 1) -> KKey {
        KKey(kind: .special(input), cap: label, shiftCap: label, weight: w)
    }
    static func m(_ label: String, _ mod: Mod, _ w: CGFloat = 1) -> KKey {
        KKey(kind: .mod(mod), cap: label, shiftCap: label, weight: w)
    }
    static func fn(_ label: String, _ w: CGFloat = 1) -> KKey {
        KKey(kind: .fn, cap: label, shiftCap: label, weight: w)
    }
}

enum KB {
    static let rows: [[KKey]] = [
        [.k("esc", .esc, 1.3)] + (1...12).map { KKey.fn("F\($0)") },
        [.c("`","~"), .c("1","!"), .c("2","@"), .c("3","#"), .c("4","$"), .c("5","%"),
         .c("6","^"), .c("7","&"), .c("8","*"), .c("9","("), .c("0",")"), .c("-","_"),
         .c("=","+"), .k("⌫", .backspace, 1.8)],
        [.k("⇥", .tab, 1.5), .c("q","Q"), .c("w","W"), .c("e","E"), .c("r","R"), .c("t","T"),
         .c("y","Y"), .c("u","U"), .c("i","I"), .c("o","O"), .c("p","P"), .c("[","{"),
         .c("]","}"), .c("\\","|", 1.5)],
        [.m("⇪", .caps, 1.8), .c("a","A"), .c("s","S"), .c("d","D"), .c("f","F"), .c("g","G"),
         .c("h","H"), .c("j","J"), .c("k","K"), .c("l","L"), .c(";",":"), .c("'","\""),
         .k("⏎", .enter, 2.0)],
        [.m("⇧", .shift, 2.3), .c("z","Z"), .c("x","X"), .c("c","C"), .c("v","V"), .c("b","B"),
         .c("n","N"), .c("m","M"), .c(",","<"), .c(".",">"), .c("/","?"), .m("⇧", .shift, 2.3)],
        [.m("⌃", .ctrl, 1.4), .m("⌥", .alt, 1.2), .k(" ", .text(" "), 6.0),
         .m("⌃", .ctrl, 1.4), .k("←", .left), .k("↑", .up), .k("↓", .down), .k("→", .right)],
    ]
}

struct SoftKeyboardView: View {
    let console: Console
    @State private var shift = false
    @State private var caps  = false
    @State private var ctrl  = false
    @State private var alt   = false

    var body: some View {
        VStack(spacing: 5) {
            ForEach(KB.rows.indices, id: \.self) { r in
                KeyRow(keys: KB.rows[r], upper: shift || caps,
                       active: { active(for: $0) }, tap: tap)
            }
        }
        .padding(6)
        .background(.regularMaterial)
    }

    private func active(for key: KKey) -> Bool {
        switch key.kind {
        case .mod(.shift): return shift
        case .mod(.caps):  return caps
        case .mod(.ctrl):  return ctrl
        case .mod(.alt):   return alt
        default:           return false
        }
    }

    private func tap(_ key: KKey) {
        switch key.kind {
        case .mod(let m):
            switch m {
            case .shift: shift.toggle()
            case .caps:  caps.toggle()
            case .ctrl:  ctrl.toggle()
            case .alt:   alt.toggle()
            }
        case .special(let input):
            console.send(input); shift = false; ctrl = false
        case .fn:
            break                       // reserved for the tug bridge
        case .char:
            let isLetter = key.cap.first?.isLetter ?? false
            let upper = isLetter ? (caps != shift) : shift
            let out = upper ? key.shiftCap : key.cap
            if ctrl, let ch = out.first { console.send(.ctrl(ch)) }
            else { console.send(.text(out)) }
            shift = false; ctrl = false  // one-shot modifiers (caps is sticky)
        }
    }
}

/// One keyboard row: keys sized proportionally to their `weight`.
struct KeyRow: View {
    let keys: [KKey]
    let upper: Bool
    let active: (KKey) -> Bool
    let tap: (KKey) -> Void

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 5
            let total = keys.reduce(0) { $0 + $1.weight }
            let unit = (geo.size.width - spacing * CGFloat(keys.count - 1)) / max(total, 1)
            HStack(spacing: spacing) {
                ForEach(keys) { key in
                    KeyButton(key: key, upper: upper, active: active(key)) { tap(key) }
                        .frame(width: max(unit * key.weight, 1))
                }
            }
        }
        .frame(height: 42)
    }
}

struct KeyButton: View {
    let key: KKey
    let upper: Bool
    let active: Bool
    let action: () -> Void

    private var label: String {
        if case .char = key.kind { return upper ? key.shiftCap : key.cap }
        return key.cap
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? Color.accentColor : Color.primary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
