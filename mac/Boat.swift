// Boat — a universal SwiftUI terminal shell for tug.
//
// Shared, platform-agnostic code (no `#if os(...)`). The per-platform root layout
// lives in Platform-iOS.swift / Platform-macOS.swift, each of which defines a
// `RootView` — iOS/iPadOS stacks Terminal over a 102-key soft keyboard; macOS is
// just the Terminal. Both also take a hardware (wired/Bluetooth) keyboard.
//
// `Console` drives the real tug RISC-V engine (src/tug.h) via `TugEngine`: the
// guest boots on a background thread, its console bytes are parsed by the
// VT100/xterm emulator in Terminal.swift into a cell grid, and keystrokes are
// forwarded back as terminal bytes.

import SwiftUI

// The @main App entry lives per-platform in App-macOS.swift / App-iOS.swift
// (each compiled only for its SDK), so the macOS app can be a single Window that
// quits on close and powers the guest off cleanly on terminate.

// MARK: - Input model

/// A resolved key event. Soft keys and the hardware keyboard both produce these;
/// the eventual tug bridge converts the "reserved" cases into terminal bytes.
enum KeyInput: Sendable {
    case text(String)        // one or more printable characters
    case enter, backspace, tab, esc
    case ctrl(Character)     // Ctrl + key
    case up, down, left, right
}

// MARK: - GuestSession (backend seam: RISC-V temu or ARM64 VZ)

/// A running guest the terminal drives. Both backends — the RISC-V TinyEMU engine
/// (iOS/Android + macOS) and the ARM64 Virtualization.framework VM (macOS only) —
/// speak raw console bytes, so the terminal/UI above is backend-agnostic.
protocol GuestSession: AnyObject, Sendable {
    func start()
    func input(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
    func shutdown(timeout: TimeInterval)
}

extension GuestSession { func shutdown() { shutdown(timeout: 6) } }

/// The single live guest, for the app lifecycle (clean power-off on quit/close).
enum Guest { nonisolated(unsafe) static weak var current: (any GuestSession)? }

// MARK: - Console (VT100 terminal + the real tug engine)

@MainActor @Observable
final class Console {
    let terminal = Terminal()
    private var engine: (any GuestSession)?

    /// Bumped on keyboard/paste input, so the view scrolls the prompt into view.
    private(set) var inputSeq = 0

    init() { terminal.feedString("[tug] booting…\r\n") }

    /// Boot the RISC-V guest. Idempotent; called once from the view's onAppear.
    func start() {
        guard engine == nil else { return }
        terminal.respond = { [weak self] bytes in self?.engine?.input(bytes) }
        let e = TugEngine(
            onOutput: { [weak self] bytes in
                Task { @MainActor in self?.terminal.feed(bytes) }
            },
            onExit: { [weak self] status in
                Task { @MainActor in
                    self?.terminal.feedString("\r\n[tug] guest powered off (status \(status))\r\n")
                }
            })
        engine = e
        e.start()
    }

    /// Feed a key from either keyboard to the guest as terminal bytes.
    func send(_ key: KeyInput) { inputSeq &+= 1; engine?.input(terminal.bytes(for: key)) }

    /// Match the on-screen grid to the guest's terminal size.
    func setSize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        engine?.resize(cols: cols, rows: rows)
    }

    // MARK: - Selection + clipboard

    /// A cell *boundary* in the combined scrollback+grid buffer: `col` is 0…width,
    /// so a selection covers cells in `[lo.col, hi.col)`.
    struct GridPoint: Equatable { var row: Int; var col: Int }

    private(set) var selAnchor: GridPoint?
    private(set) var selFocus: GridPoint?

    /// Selection ordered in reading order, or nil if empty (anchor == focus).
    var selectionRange: (lo: GridPoint, hi: GridPoint)? {
        guard let a = selAnchor, let f = selFocus, a != f else { return nil }
        let before = a.row < f.row || (a.row == f.row && a.col <= f.col)
        return before ? (a, f) : (f, a)
    }

    func selectBegin(_ p: GridPoint) { selAnchor = p; selFocus = p }
    func selectExtend(_ p: GridPoint) { if selAnchor == nil { selAnchor = p }; selFocus = p }
    func selectClear() { selAnchor = nil; selFocus = nil }

    /// Double-click: select the whitespace-delimited word under `p`.
    func selectWord(_ p: GridPoint) {
        let cells = terminal.lineCells(p.row)
        guard !cells.isEmpty else { selectClear(); return }
        let col = min(p.col, cells.count - 1)
        func word(_ c: Cell) -> Bool { c.scalar != " " }
        guard word(cells[col]) else {            // on a space: select just it
            selAnchor = GridPoint(row: p.row, col: col)
            selFocus  = GridPoint(row: p.row, col: col + 1); return
        }
        var s = col; while s > 0, word(cells[s - 1]) { s -= 1 }
        var e = col; while e + 1 < cells.count, word(cells[e + 1]) { e += 1 }
        selAnchor = GridPoint(row: p.row, col: s)
        selFocus  = GridPoint(row: p.row, col: e + 1)
    }

    /// Which cells of row `r` are selected (or nil) — for the highlight.
    func selectedCols(row r: Int) -> Range<Int>? {
        guard let (lo, hi) = selectionRange, r >= lo.row, r <= hi.row else { return nil }
        let w = terminal.lineCells(r).count
        let s = (r == lo.row) ? lo.col : 0
        let e = (r == hi.row) ? hi.col : w
        return s < e ? s..<e : nil
    }

    /// The selected text, trailing spaces trimmed per line (lines joined with \n).
    func selectedText() -> String {
        guard let (lo, hi) = selectionRange else { return "" }
        var lines: [String] = []
        for r in lo.row...hi.row {
            let cells = terminal.lineCells(r)
            let s = (r == lo.row) ? lo.col : 0
            let e = (r == hi.row) ? hi.col : cells.count
            var line = ""
            for c in max(0, s)..<min(e, cells.count) { line.append(Character(cells[c].scalar)) }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func copySelection() {
        let s = selectedText()
        if !s.isEmpty { Pasteboard.set(s) }
    }

    /// Cmd-V: send the clipboard to the guest (newlines normalised to CR).
    func paste() {
        guard let s = Pasteboard.string, !s.isEmpty else { return }
        let cr = s.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        inputSeq &+= 1
        engine?.input(Array(cr.utf8))
    }
}

// MARK: - TugEngine (C interop: drives src/tug.h on a background thread)

/// Owns the C `tug` engine: loads the bundled payload, starts the VM on a
/// dedicated thread, streams console bytes out via `onOutput`, and forwards
/// keyboard bytes in via `input`. Not actor-isolated — the C side is driven from
/// its own thread; callbacks marshal to the main actor inside the closures.
final class TugEngine: GuestSession, @unchecked Sendable {
    private var handle: OpaquePointer?                 // tug *
    private var blobs: [UnsafeMutableBufferPointer<UInt8>] = []   // payload, kept alive
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0) // signaled when tug_run returns
    private var didShutdown = false
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

        // Writable Alpine data disk (apk userland + the `essentials` toolchains),
        // expanded from the bundled sparse image into Documents on first launch.
        let diskPath = DiskStore.dataDiskPath()
        if diskPath == nil {
            onOutput(Array("[tug] warning: data disk unavailable — apk won't persist\r\n".utf8))
        }

        var settings = tug_settings()
        settings.ram_mb = 512
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

        // disk_path only needs to be valid across tug_new (it opens the file there).
        func makeEngine() -> OpaquePointer? {
            withUnsafePointer(to: &settings) { sp in
                withUnsafePointer(to: &host) { hp in tug_new(sp, hp) }
            }
        }
        if let dp = diskPath {
            handle = dp.withCString { c in settings.disk_path = c; return makeEngine() }
        } else {
            handle = makeEngine()
        }
        guard handle != nil else { onOutput(Array("[tug] error: tug_new failed\r\n".utf8)); return }

        Guest.current = self
        let t = Thread { [weak self] in
            guard let self, let h = self.handle else { return }
            _ = tug_run(h)        // blocks until guest power-off / stop
            self.finished.signal()
        }
        t.name = "tug-run"
        t.stackSize = 8 << 20
        // Run at .userInitiated so it's never *lower* QoS than the thread that
        // waits on it in shutdown() — a block dispatched from the main thread can
        // inherit its user-initiated QoS, and a higher-QoS waiter on a lower-QoS
        // thread is the priority inversion the Thread Performance Checker flags.
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func input(_ bytes: [UInt8]) {
        guard let h = handle, !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { tug_input(h, $0.baseAddress, Int32($0.count)) }
    }

    /// Power the guest off cleanly on app quit/close: send `poweroff -f` (the
    /// guest syncs + unmounts ext4), wait for the VM loop to return, then free the
    /// engine (fsyncs the data disk). Blocks up to `timeout` s; runs once; callable
    /// from any thread. If the guest doesn't stop in time, force it and free anyway.
    func shutdown(timeout: TimeInterval = 6) {
        guard let h = handle, !didShutdown else { return }
        didShutdown = true
        input(Array("poweroff -f\n".utf8))
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            tug_stop(h)
            _ = finished.wait(timeout: .now() + 1.5)
        }
        tug_free(h)               // fsync + close the data disk
        handle = nil
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

// MARK: - DiskStore (first-launch sparse-expand of the bundled data disk)

/// The Alpine data disk is shipped as a compact sparse manifest (build-sparse.py)
/// because iOS can't create an ext4 filesystem and the raw image is 32 GB. On
/// first launch we expand it into the app's Documents as a sparse file (only the
/// ~26 MB of real data consumes storage; it grows as apk installs packages).
enum DiskStore {
    private struct Bad: Error {}

    /// Path to the writable data disk, expanding it on first use. Nil on failure.
    static func dataDiskPath() -> String? {
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true) else { return nil }
        let dst = docs.appendingPathComponent("tug-data.img")
        if fm.fileExists(atPath: dst.path) { return dst.path }
        guard let src = Bundle.main.url(forResource: "data", withExtension: "sparse") else { return nil }
        do { try expand(from: src, to: dst); return dst.path }
        catch { try? fm.removeItem(at: dst); return nil }
    }

    private static func expand(from src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src, options: .mappedIfSafe)
        var i = 0
        func need(_ n: Int) throws { if i + n > data.count { throw Bad() } }
        func u64() throws -> UInt64 {
            try need(8)
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(data[i + k]) << (8 * k) }
            i += 8
            return v
        }
        try need(8)
        guard data[0..<8].elementsEqual("TUGSPRS1".utf8) else { throw Bad() }
        i = 8
        let total = try u64()

        let fd = open(dst.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw Bad() }
        defer { close(fd) }
        guard ftruncate(fd, off_t(total)) == 0 else { throw Bad() }   // sparse hole

        while i < data.count {
            let off = try u64()
            let len = Int(try u64())
            try need(len)
            let wrote = data.withUnsafeBytes { raw -> Int in
                pwrite(fd, raw.baseAddress!.advanced(by: i), len, off_t(off))
            }
            guard wrote == len else { throw Bad() }
            i += len
        }
    }
}

// MARK: - Terminal view (renders the console, takes hardware-keyboard input)

enum Term {
    static let bg = Color(red: 0.043, green: 0.055, blue: 0.078)   // near-black ink
    static let fg = Color(red: 0.84,  green: 0.88,  blue: 0.98)
    static let selection = Color(red: 0.20, green: 0.42, blue: 0.78)  // drag-select highlight
    static let fontSize: CGFloat = 13
}

struct TerminalView: View {
    let console: Console
    @FocusState private var focused: Bool

    var body: some View {
        TerminalScreenView(console: console, focused: focused) { cols, rows in
            console.setSize(cols: cols, rows: rows)
        }
        .padding(4)
        .background(Term.bg)
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
        if mods.contains(.command) {                     // clipboard; rest -> system
            switch press.characters {
            case "c": if console.selectionRange != nil { console.copySelection(); return .handled }
            case "v": console.paste(); return .handled
            default: break
            }
            return .ignored
        }
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
