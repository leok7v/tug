// Boat — a universal SwiftUI terminal shell for tug.
//
// Shared, platform-agnostic code (no `#if os(...)`). The per-platform root layout
// lives in Platform-iOS.swift / Platform-macOS.swift, each of which defines a
// `RootView` — iOS/iPadOS stacks Terminal over a 102-key soft keyboard; macOS is
// just the Terminal. Both also take a hardware (wired/Bluetooth) keyboard.
//
// `Console` drives the real tug RISC-V engine (src/tug.h) via `TugEngine`: the
// guest boots on a background thread, its console bytes stream into `text`, and
// keystrokes are forwarded as terminal bytes. Output is shown raw for now —
// VT100/ANSI interpretation is a later pass.

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

// MARK: - Console (terminal buffer driven by the real tug engine)

@MainActor @Observable
final class Console {
    private(set) var text = ""        // entire visible buffer (raw guest output)
    private let maxChars = 400_000
    private var engine: TugEngine?

    init() { text = "[tug] booting…\r\n" }

    /// Boot the RISC-V guest. Idempotent; called once from the view's onAppear.
    func start() {
        guard engine == nil else { return }
        let e = TugEngine(
            onOutput: { [weak self] bytes in
                Task { @MainActor in self?.append(bytes) }
            },
            onExit: { [weak self] status in
                Task { @MainActor in
                    self?.append(Array("\r\n[tug] guest powered off (status \(status))\r\n".utf8))
                }
            })
        engine = e
        e.start()
    }

    /// Append raw guest bytes. Raw-bytes-first: decoded as UTF-8 and shown as-is
    /// (VT100/ANSI escapes are not yet interpreted — that's a later pass).
    private func append(_ bytes: [UInt8]) {
        text += String(decoding: bytes, as: UTF8.self)
        if text.count > maxChars { text.removeFirst(text.count - maxChars) }
    }

    /// Feed a key from either keyboard to the guest as terminal bytes.
    func send(_ key: KeyInput) { engine?.input(Self.bytes(for: key)) }

    /// Map a resolved key event to the bytes a terminal would send.
    static func bytes(for key: KeyInput) -> [UInt8] {
        switch key {
        case .text(let s):  return Array(s.utf8)
        case .enter:        return [0x0d]               // CR
        case .backspace:    return [0x7f]               // DEL (readline/erase)
        case .tab:          return [0x09]
        case .esc:          return [0x1b]
        case .up:           return [0x1b, 0x5b, 0x41]   // ESC [ A
        case .down:         return [0x1b, 0x5b, 0x42]   // ESC [ B
        case .right:        return [0x1b, 0x5b, 0x43]   // ESC [ C
        case .left:         return [0x1b, 0x5b, 0x44]   // ESC [ D
        case .ctrl(let c):
            // Ctrl-<key> = the key's ASCII & 0x1f (Ctrl-A=1 … Ctrl-C=3 … Ctrl-Z=26)
            guard let a = c.uppercased().unicodeScalars.first?.value, a >= 0x40, a <= 0x5f
            else { return [] }
            return [UInt8(a & 0x1f)]
        }
    }
}

// MARK: - TugEngine (C interop: drives src/tug.h on a background thread)

/// Owns the C `tug` engine: loads the bundled payload, starts the VM on a
/// dedicated thread, streams console bytes out via `onOutput`, and forwards
/// keyboard bytes in via `input`. Not actor-isolated — the C side is driven from
/// its own thread; callbacks marshal to the main actor inside the closures.
final class TugEngine: @unchecked Sendable {
    private var handle: OpaquePointer?                 // tug *
    private var blobs: [UnsafeMutableBufferPointer<UInt8>] = []   // payload, kept alive
    private var thread: Thread?
    private let onOutput: @Sendable ([UInt8]) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(onOutput: @escaping @Sendable ([UInt8]) -> Void,
         onExit:   @escaping @Sendable (Int32) -> Void) {
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func start() {
        guard let bios   = loadResource("bios",   "bin"),
              let kernel = loadResource("kernel", "bin"),
              let initrd = loadResource("initrd", "cgz") else {
            onOutput(Array("[tug] error: bundled payload missing\r\n".utf8)); return
        }

        var settings = tug_settings()
        settings.ram_mb = 256
        settings.bios   = UnsafePointer(bios.baseAddress);   settings.bios_len   = Int32(bios.count)
        settings.kernel = UnsafePointer(kernel.baseAddress); settings.kernel_len = Int32(kernel.count)
        settings.initrd = UnsafePointer(initrd.baseAddress); settings.initrd_len = Int32(initrd.count)

        var host = tug_host()
        host.ctx = Unmanaged.passRetained(self).toOpaque()
        host.console_out = { ctx, data, len in
            guard let ctx, let data, len > 0 else { return }
            let me = Unmanaged<TugEngine>.fromOpaque(ctx).takeUnretainedValue()
            me.onOutput(Array(UnsafeBufferPointer(start: data, count: Int(len))))
        }
        host.exited = { ctx, status in
            guard let ctx else { return }
            let me = Unmanaged<TugEngine>.fromOpaque(ctx).takeUnretainedValue()
            me.onExit(status)
        }

        handle = withUnsafePointer(to: &settings) { sp in
            withUnsafePointer(to: &host) { hp in tug_new(sp, hp) }
        }
        guard handle != nil else { onOutput(Array("[tug] error: tug_new failed\r\n".utf8)); return }

        let t = Thread { [weak self] in
            guard let self, let h = self.handle else { return }
            _ = tug_run(h)        // blocks until guest power-off / stop
        }
        t.name = "tug-run"
        t.stackSize = 8 << 20
        thread = t
        t.start()
    }

    func input(_ bytes: [UInt8]) {
        guard let h = handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { tug_input(h, $0.baseAddress, Int32($0.count)) }
    }

    func resize(cols: Int, rows: Int) {
        guard let h = handle else { return }
        tug_resize(h, Int32(cols), Int32(rows))
    }

    func stop() { if let h = handle { tug_stop(h) } }

    /// Load a bundled resource into a malloc'd buffer that outlives the engine
    /// (tug only reads these blobs; they must stay valid for the VM's lifetime).
    private func loadResource(_ name: String, _ ext: String) -> UnsafeMutableBufferPointer<UInt8>? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
        _ = data.copyBytes(to: buf)
        blobs.append(buf)
        return buf
    }
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
        .onAppear { focused = true; console.start() }
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
