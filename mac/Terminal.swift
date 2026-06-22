// Terminal.swift — a compact VT100/xterm terminal emulator for Boat.
//
// Parses the guest's raw byte stream into a fixed cell grid (so vi, less, and
// bash readline render correctly) and renders it with SwiftUI. Covers the subset
// real CLI/TUI programs need: cursor motion, erase, scroll regions, insert/delete
// lines & chars, SGR colour/attributes (16 / 256 / truecolour), the alternate
// screen (vi/less), cursor visibility, application-cursor-keys, autowrap, and a
// couple of query replies (DSR/DA). Not a goal: scrollback, wide/combining glyph
// metrics, double-width, mouse.

import SwiftUI

// MARK: - Colours

enum TermColor: Equatable {
    case `default`
    case indexed(Int)            // 0…255 xterm palette
    case rgb(UInt8, UInt8, UInt8)

    func color(foreground: Bool) -> Color {
        switch self {
        case .default:            return foreground ? Term.fg : Term.bg
        case .rgb(let r, let g, let b):
            return Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
        case .indexed(let i):     return Self.palette(i)
        }
    }

    // Standard xterm 256-colour palette: 16 base, 6×6×6 cube, 24 greys.
    static func palette(_ i: Int) -> Color {
        if i < 16 {
            let base: [(Double, Double, Double)] = [
                (0,0,0),(0.80,0.20,0.20),(0.20,0.73,0.20),(0.80,0.67,0.10),
                (0.22,0.45,0.86),(0.75,0.30,0.75),(0.20,0.70,0.73),(0.80,0.80,0.80),
                (0.42,0.42,0.42),(0.96,0.36,0.36),(0.40,0.90,0.40),(0.95,0.85,0.35),
                (0.45,0.65,1.00),(0.92,0.52,0.92),(0.40,0.88,0.90),(1.00,1.00,1.00)]
            let c = base[i]; return Color(red: c.0, green: c.1, blue: c.2)
        }
        if i < 232 {
            let n = i - 16
            let r = n / 36, g = (n / 6) % 6, b = n % 6
            func lvl(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + v*40)/255 }
            return Color(red: lvl(r), green: lvl(g), blue: lvl(b))
        }
        let v = Double(8 + (i - 232) * 10) / 255
        return Color(red: v, green: v, blue: v)
    }
}

// MARK: - Cells

struct CellAttrs: Equatable {
    var fg: TermColor = .default
    var bg: TermColor = .default
    var bold = false
    var underline = false
    var inverse = false
    var dim = false
}

struct Cell: Equatable {
    var scalar: Unicode.Scalar = " "
    var attrs = CellAttrs()
}

// MARK: - Terminal model + parser

@MainActor @Observable
final class Terminal {
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var grid: [[Cell]]            // active screen (rows × cols)
    private(set) var cursorRow = 0
    private(set) var cursorCol = 0
    private(set) var cursorVisible = true
    private(set) var version = 0               // bumped after each feed (drives the view)

    // Scrollback: lines that scroll off the top of the primary screen (not alt).
    private(set) var scrollback: [[Cell]] = []
    private(set) var onAlt = false             // alt screen: no scrollback, no scroll
    private let maxScrollback = 2000

    /// Send bytes back to the guest (query replies: DSR cursor position, DA).
    var respond: (([UInt8]) -> Void)?

    // saved/alternate state
    private var savedRow = 0
    private var savedCol = 0
    private var savedAttrs = CellAttrs()
    private var altGrid: [[Cell]]?             // primary screen stashed while on alt

    private var attrs = CellAttrs()
    private var scrollTop = 0
    private var scrollBot = 0
    private var autowrap = true
    private var appCursorKeys = false
    private var pendingWrap = false

    init(cols: Int = 80, rows: Int = 24) {
        let c = max(2, cols), r = max(2, rows)
        self.cols = c
        self.rows = r
        grid = Self.blankGrid(c, r, CellAttrs())
        scrollBot = r - 1
    }

    private static func blankCell(_ a: CellAttrs) -> Cell {
        Cell(scalar: " ", attrs: CellAttrs(fg: .default, bg: a.bg))
    }
    private static func blankRow(_ cols: Int, _ a: CellAttrs) -> [Cell] {
        Array(repeating: blankCell(a), count: cols)
    }
    private static func blankGrid(_ cols: Int, _ rows: Int, _ a: CellAttrs) -> [[Cell]] {
        Array(repeating: blankRow(cols, a), count: rows)
    }

    // MARK: feed

    func feedString(_ s: String) { feed(Array(s.utf8)) }

    func feed(_ bytes: [UInt8]) {
        for b in bytes { step(b) }
        version &+= 1
    }

    // parser state
    private enum State { case ground, esc, csi, osc, oscEsc, charset }
    private var state: State = .ground
    private var params: [Int] = []
    private var curParam: Int? = nil
    private var csiPrivate: UInt8 = 0          // '?', '>', '=' or 0
    // UTF-8 accumulator (ground printable bytes)
    private var u8rem = 0
    private var u8acc: UInt32 = 0

    private func step(_ b: UInt8) {
        switch state {
        case .ground:   ground(b)
        case .esc:      escape(b)
        case .csi:      csi(b)
        case .osc:      if b == 0x07 { state = .ground } else if b == 0x1b { state = .oscEsc }
        case .oscEsc:   state = (b == 0x5c) ? .ground : .osc   // ST = ESC \
        case .charset:  state = .ground                        // consume the designator byte
        }
    }

    private func ground(_ b: UInt8) {
        switch b {
        case 0x1b: u8rem = 0; state = .esc
        case 0x07: break                                       // BEL
        case 0x08: pendingWrap = false; if cursorCol > 0 { cursorCol -= 1 }   // BS
        case 0x09: tab()                                       // HT
        case 0x0a, 0x0b, 0x0c: lineFeed()                      // LF/VT/FF
        case 0x0d: pendingWrap = false; cursorCol = 0          // CR
        case 0x00...0x06, 0x0e...0x1a, 0x1c...0x1f, 0x7f: break // other C0 / DEL
        default:
            if let s = decodeUTF8(b) { putChar(s) }
        }
    }

    private func decodeUTF8(_ b: UInt8) -> Unicode.Scalar? {
        if u8rem == 0 {
            if b < 0x80 { return Unicode.Scalar(b) }
            if b & 0xE0 == 0xC0 { u8acc = UInt32(b & 0x1F); u8rem = 1; return nil }
            if b & 0xF0 == 0xE0 { u8acc = UInt32(b & 0x0F); u8rem = 2; return nil }
            if b & 0xF8 == 0xF0 { u8acc = UInt32(b & 0x07); u8rem = 3; return nil }
            return Unicode.Scalar(0xFFFD)
        }
        guard b & 0xC0 == 0x80 else { u8rem = 0; return Unicode.Scalar(0xFFFD) }
        u8acc = (u8acc << 6) | UInt32(b & 0x3F); u8rem -= 1
        return u8rem == 0 ? (Unicode.Scalar(u8acc) ?? Unicode.Scalar(0xFFFD)) : nil
    }

    // MARK: ESC / CSI

    private func escape(_ b: UInt8) {
        switch b {
        case 0x5b: params = []; curParam = nil; csiPrivate = 0; state = .csi   // [
        case 0x5d: state = .osc                                                 // ]
        case 0x28, 0x29, 0x2a, 0x2b: state = .charset                          // ( ) * +
        case 0x44: lineFeed(); state = .ground                                  // IND
        case 0x45: cursorCol = 0; lineFeed(); state = .ground                   // NEL
        case 0x4d: reverseIndex(); state = .ground                             // RI
        case 0x37: savedRow = cursorRow; savedCol = cursorCol; savedAttrs = attrs; state = .ground // DECSC
        case 0x38: cursorRow = savedRow; cursorCol = savedCol; attrs = savedAttrs; clampCursor(); state = .ground // DECRC
        case 0x63: hardReset(); state = .ground                                // RIS
        default: state = .ground                                                // =, >, others: ignore
        }
    }

    private func csi(_ b: UInt8) {
        switch b {
        case 0x30...0x39:                                       // digit
            curParam = (curParam ?? 0) * 10 + Int(b - 0x30)
        case 0x3b:                                              // ;
            params.append(curParam ?? 0); curParam = nil
        case 0x3f, 0x3e, 0x3d:                                  // ? > = private markers
            csiPrivate = b
        case 0x20...0x2f:                                       // intermediate bytes: ignore
            break
        case 0x40...0x7e:                                       // final byte
            params.append(curParam ?? 0); curParam = nil
            dispatchCSI(b)
            state = .ground
        default:
            state = .ground
        }
    }

    private func p(_ i: Int, _ def: Int = 0) -> Int {
        i < params.count ? params[i] : def
    }
    private func pPos(_ i: Int) -> Int { max(1, p(i, 1)) }     // ≥1 for counts/positions

    private func dispatchCSI(_ b: UInt8) {
        switch b {
        case 0x41: moveCursor(dr: -pPos(0), dc: 0)              // A CUU
        case 0x42: moveCursor(dr:  pPos(0), dc: 0)              // B CUD
        case 0x43: moveCursor(dr: 0, dc:  pPos(0))             // C CUF
        case 0x44: moveCursor(dr: 0, dc: -pPos(0))             // D CUB
        case 0x45: cursorCol = 0; moveCursor(dr:  pPos(0), dc: 0)   // E CNL
        case 0x46: cursorCol = 0; moveCursor(dr: -pPos(0), dc: 0)   // F CPL
        case 0x47: setCursor(row: cursorRow, col: pPos(0) - 1) // G CHA
        case 0x48, 0x66: setCursor(row: pPos(0) - 1, col: pPos(1) - 1) // H/f CUP
        case 0x64: setCursor(row: pPos(0) - 1, col: cursorCol) // d VPA
        case 0x4a: eraseDisplay(p(0))                          // J ED
        case 0x4b: eraseLine(p(0))                             // K EL
        case 0x4c: insertLines(pPos(0))                        // L IL
        case 0x4d: deleteLines(pPos(0))                        // M DL
        case 0x40: insertChars(pPos(0))                        // @ ICH
        case 0x50: deleteChars(pPos(0))                        // P DCH
        case 0x58: eraseChars(pPos(0))                         // X ECH
        case 0x53: scrollUp(pPos(0))                           // S SU
        case 0x54: scrollDown(pPos(0))                         // T SD
        case 0x6d: applySGR()                                  // m
        case 0x72: setScrollRegion()                           // r DECSTBM
        case 0x68: setMode(true)                               // h
        case 0x6c: setMode(false)                              // l
        case 0x73: savedRow = cursorRow; savedCol = cursorCol; savedAttrs = attrs  // s (ANSI save)
        case 0x75: cursorRow = savedRow; cursorCol = savedCol; attrs = savedAttrs; clampCursor() // u
        case 0x6e: deviceStatus(p(0))                          // n DSR
        case 0x63: if csiPrivate == 0 { respond?(Array("\u{1b}[?1;2c".utf8)) } // c DA -> VT100
        default: break
        }
    }

    // MARK: cursor + scrolling primitives

    private func tab() {
        pendingWrap = false
        cursorCol = min(cols - 1, ((cursorCol / 8) + 1) * 8)
    }
    private func clampCursor() {
        cursorRow = min(max(0, cursorRow), rows - 1)
        cursorCol = min(max(0, cursorCol), cols - 1)
    }
    private func setCursor(row: Int, col: Int) {
        pendingWrap = false; cursorRow = row; cursorCol = col; clampCursor()
    }
    private func moveCursor(dr: Int, dc: Int) {
        pendingWrap = false
        cursorRow += dr; cursorCol += dc; clampCursor()
    }
    private func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBot { scrollUp(1) }
        else if cursorRow < rows - 1 { cursorRow += 1 }
    }
    private func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop { scrollDown(1) }
        else if cursorRow > 0 { cursorRow -= 1 }
    }
    private func scrollUp(_ n: Int) {
        let n = min(n, scrollBot - scrollTop + 1)
        guard n > 0 else { return }
        // lines leaving the top of a full-screen primary scroll go to scrollback
        if scrollTop == 0 && !onAlt {
            for r in 0..<n {
                scrollback.append(grid[r])
                if scrollback.count > maxScrollback { scrollback.removeFirst() }
            }
        }
        grid.removeSubrange(scrollTop ..< scrollTop + n)
        grid.insert(contentsOf: (0..<n).map { _ in Self.blankRow(cols, attrs) }, at: scrollBot - n + 1)
    }
    private func scrollDown(_ n: Int) {
        let n = min(n, scrollBot - scrollTop + 1)
        guard n > 0 else { return }
        grid.removeSubrange(scrollBot - n + 1 ... scrollBot)
        grid.insert(contentsOf: (0..<n).map { _ in Self.blankRow(cols, attrs) }, at: scrollTop)
    }

    private func putChar(_ s: Unicode.Scalar) {
        if pendingWrap { cursorCol = 0; lineFeed(); pendingWrap = false }
        grid[cursorRow][cursorCol] = Cell(scalar: s, attrs: attrs)
        if cursorCol == cols - 1 { if autowrap { pendingWrap = true } }
        else { cursorCol += 1 }
    }

    // MARK: erase / insert / delete

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0: eraseLine(0); for r in (cursorRow+1)..<rows { grid[r] = Self.blankRow(cols, attrs) }
        case 1: eraseLine(1); for r in 0..<cursorRow { grid[r] = Self.blankRow(cols, attrs) }
        default: for r in 0..<rows { grid[r] = Self.blankRow(cols, attrs) }   // 2/3
        }
    }
    private func eraseLine(_ mode: Int) {
        let blank = Self.blankCell(attrs)
        switch mode {
        case 0: for c in cursorCol..<cols { grid[cursorRow][c] = blank }
        case 1: for c in 0...min(cursorCol, cols-1) { grid[cursorRow][c] = blank }
        default: grid[cursorRow] = Self.blankRow(cols, attrs)
        }
    }
    private func eraseChars(_ n: Int) {
        let blank = Self.blankCell(attrs)
        for c in cursorCol..<min(cursorCol + n, cols) { grid[cursorRow][c] = blank }
    }
    private func insertChars(_ n: Int) {
        let n = min(n, cols - cursorCol)
        guard n > 0 else { return }
        grid[cursorRow].removeSubrange(cols - n ..< cols)
        grid[cursorRow].insert(contentsOf: Array(repeating: Self.blankCell(attrs), count: n), at: cursorCol)
    }
    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cursorCol)
        guard n > 0 else { return }
        grid[cursorRow].removeSubrange(cursorCol ..< cursorCol + n)
        grid[cursorRow].append(contentsOf: Array(repeating: Self.blankCell(attrs), count: n))
    }
    private func insertLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBot else { return }
        let n = min(n, scrollBot - cursorRow + 1)
        grid.removeSubrange(scrollBot - n + 1 ... scrollBot)
        grid.insert(contentsOf: (0..<n).map { _ in Self.blankRow(cols, attrs) }, at: cursorRow)
    }
    private func deleteLines(_ n: Int) {
        guard cursorRow >= scrollTop, cursorRow <= scrollBot else { return }
        let n = min(n, scrollBot - cursorRow + 1)
        grid.removeSubrange(cursorRow ..< cursorRow + n)
        grid.insert(contentsOf: (0..<n).map { _ in Self.blankRow(cols, attrs) }, at: scrollBot - n + 1)
    }

    // MARK: modes, SGR, status

    private func setScrollRegion() {
        let top = pPos(0) - 1
        let bot = params.count > 1 && p(1) > 0 ? p(1) - 1 : rows - 1
        if top < bot && bot < rows { scrollTop = top; scrollBot = bot; setCursor(row: 0, col: 0) }
    }

    private func setMode(_ on: Bool) {
        if csiPrivate == 0x3f {                 // DEC private modes
            for m in params {
                switch m {
                case 1:    appCursorKeys = on
                case 7:    autowrap = on
                case 25:   cursorVisible = on
                case 47, 1047, 1049:
                    if on { enterAlt(save: m == 1049) } else { exitAlt(restore: m == 1049) }
                default:   break                // 2004 bracketed paste, mouse, etc.: ignore
                }
            }
        }
        // ANSI (non-private) modes: none needed
    }

    private func enterAlt(save: Bool) {
        guard !onAlt else { return }
        if save { savedRow = cursorRow; savedCol = cursorCol; savedAttrs = attrs }
        altGrid = grid
        grid = Self.blankGrid(cols, rows, attrs)
        onAlt = true
        scrollTop = 0; scrollBot = rows - 1
        setCursor(row: 0, col: 0)
    }
    private func exitAlt(restore: Bool) {
        guard onAlt, let g = altGrid else { return }
        grid = g; altGrid = nil; onAlt = false
        scrollTop = 0; scrollBot = rows - 1
        if restore { cursorRow = savedRow; cursorCol = savedCol; attrs = savedAttrs; clampCursor() }
    }

    private func deviceStatus(_ mode: Int) {
        if mode == 6 {                          // cursor position report
            respond?(Array("\u{1b}[\(cursorRow + 1);\(cursorCol + 1)R".utf8))
        }
    }

    private func applySGR() {
        if params.isEmpty { params = [0] }
        var i = 0
        while i < params.count {
            let c = params[i]
            switch c {
            case 0:  attrs = CellAttrs()
            case 1:  attrs.bold = true
            case 2:  attrs.dim = true
            case 4:  attrs.underline = true
            case 7:  attrs.inverse = true
            case 22: attrs.bold = false; attrs.dim = false
            case 24: attrs.underline = false
            case 27: attrs.inverse = false
            case 30...37: attrs.fg = .indexed(c - 30)
            case 39: attrs.fg = .default
            case 40...47: attrs.bg = .indexed(c - 40)
            case 49: attrs.bg = .default
            case 90...97:  attrs.fg = .indexed(c - 90 + 8)
            case 100...107: attrs.bg = .indexed(c - 100 + 8)
            case 38, 48:
                let fg = (c == 38)
                if i + 1 < params.count, params[i+1] == 5, i + 2 < params.count {
                    let idx = params[i+2]; if fg { attrs.fg = .indexed(idx) } else { attrs.bg = .indexed(idx) }
                    i += 2
                } else if i + 1 < params.count, params[i+1] == 2, i + 4 < params.count {
                    let r = UInt8(clamping: params[i+2]), g = UInt8(clamping: params[i+3]), b = UInt8(clamping: params[i+4])
                    if fg { attrs.fg = .rgb(r,g,b) } else { attrs.bg = .rgb(r,g,b) }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    private func hardReset() {
        attrs = CellAttrs()
        scrollTop = 0; scrollBot = rows - 1
        autowrap = true; appCursorKeys = false; cursorVisible = true
        onAlt = false; altGrid = nil
        grid = Self.blankGrid(cols, rows, attrs)
        setCursor(row: 0, col: 0)
    }

    // MARK: resize

    func resize(cols newCols: Int, rows newRows: Int) {
        let nc = max(2, newCols), nr = max(2, newRows)
        guard nc != cols || nr != rows else { return }

        // Grid rows are exactly nc (pad/truncate). Scrollback rows keep their full
        // content (pad short, but never truncate) so a long line captured at a
        // wider width wraps in the view instead of being cut off with "…".
        func gridFit(_ row: [Cell]) -> [Cell] {
            if row.count == nc { return row }
            if row.count > nc { return Array(row[0..<nc]) }
            return row + Array(repeating: Self.blankCell(attrs), count: nc - row.count)
        }
        func keep(_ row: [Cell]) -> [Cell] {
            row.count >= nc ? row : row + Array(repeating: Self.blankCell(attrs), count: nc - row.count)
        }

        if onAlt {
            // Alt screen (vi/less): no scrollback; keep top-left, the app redraws.
            var g = Self.blankGrid(nc, nr, attrs)
            for r in 0..<min(grid.count, nr) { g[r] = gridFit(grid[r]) }
            grid = g
            if let alt = altGrid {
                var ag = Self.blankGrid(nc, nr, attrs)
                for r in 0..<min(alt.count, nr) { ag[r] = gridFit(alt[r]) }
                altGrid = ag
            }
        } else {
            // Primary screen: treat scrollback + grid as one continuous line
            // buffer; the new grid is its bottom `nr` lines (cursor tracked by its
            // absolute position). This anchors the prompt and never duplicates or
            // drops lines across grow/shrink — the bug behind "scrolling is strange
            // after resize" (the boot log reappeared mid-screen).
            let absCursor = scrollback.count + cursorRow
            let all = scrollback + grid
            let start = max(0, all.count - nr)
            var g = all[start...].map(gridFit)
            while g.count < nr { g.append(Self.blankRow(nc, attrs)) }
            grid = g
            scrollback = all[0..<start].map(keep)
            if scrollback.count > maxScrollback {
                scrollback.removeFirst(scrollback.count - maxScrollback)
            }
            cursorRow = max(0, min(nr - 1, absCursor - start))
        }
        cols = nc; rows = nr
        scrollTop = 0; scrollBot = nr - 1
        cursorCol = min(cursorCol, nc - 1)
        pendingWrap = false
        version &+= 1
    }

    // MARK: combined buffer access (scrollback + grid), for text selection

    var totalLines: Int { scrollback.count + grid.count }
    func lineCells(_ r: Int) -> [Cell] {
        if r < 0 { return [] }
        if r < scrollback.count { return scrollback[r] }
        let g = r - scrollback.count
        return g < grid.count ? grid[g] : []
    }

    // MARK: keyboard -> bytes (honours application-cursor-keys)

    func bytes(for key: KeyInput) -> [UInt8] {
        let ss: UInt8 = appCursorKeys ? 0x4f : 0x5b           // ESC O vs ESC [
        switch key {
        case .text(let s): return Array(s.utf8)
        case .enter:       return [0x0d]
        case .backspace:   return [0x7f]
        case .tab:         return [0x09]
        case .esc:         return [0x1b]
        case .up:          return [0x1b, ss, 0x41]
        case .down:        return [0x1b, ss, 0x42]
        case .right:       return [0x1b, ss, 0x43]
        case .left:        return [0x1b, ss, 0x44]
        case .ctrl(let ch):
            guard let a = ch.uppercased().unicodeScalars.first?.value, a >= 0x40, a <= 0x5f else { return [] }
            return [UInt8(a & 0x1f)]
        }
    }
}

// MARK: - Rendering

struct TerminalScreenView: View {
    let console: Console
    let focused: Bool
    /// Called when the fitted grid size (cols × rows) changes with the view.
    let onResize: (Int, Int) -> Void

    @State private var dragging = false
    private var terminal: Terminal { console.terminal }

    // Constant font: resizing the window changes the grid geometry (cols × rows),
    // not the glyph size. cell metrics are derived from the fixed font size.
    private let fontSize: CGFloat = 12
    private let advance: CGFloat = 0.62      // monospaced glyph width / em (a hair
                                             // wide so a full row never overflows)
    private let lineFactor: CGFloat = 1.18

    private var charW: CGFloat { fontSize * advance }
    private var lineH: CGFloat { (fontSize * lineFactor).rounded() }

    /// Map a point in the scroll content to a cell boundary (row, col).
    private func hit(_ loc: CGPoint) -> Console.GridPoint {
        let row = max(0, min(terminal.totalLines - 1, Int(loc.y / lineH)))
        let w = terminal.lineCells(row).count
        let col = max(0, min(w, Int((loc.x / charW).rounded())))
        return Console.GridPoint(row: row, col: col)
    }

    var body: some View {
        GeometryReader { geo in
            let valid = geo.size.width > 1 && geo.size.height > 1
            let fitCols = max(20, min(400, Int(geo.size.width  / charW)))
            let fitRows = max(4,  min(200, Int(geo.size.height / lineH)))
            let _ = terminal.version                          // observe updates

            // Snapshot the rows once (value copies, cheap CoW) so the lazy stack
            // never indexes a mutated buffer, and so every row gets a UNIQUE id.
            let sb = terminal.scrollback
            let grid = terminal.grid
            let curRow = terminal.cursorRow

            Group {
                if terminal.onAlt {
                    // Full-screen TUI (vi/less): fixed viewport, no scroll/selection.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(grid.indices), id: \.self) { r in
                            Text(line(grid[r], isCursorRow: r == curRow, fontSize: fontSize))
                                .frame(height: lineH, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    // Shell: scrollback above the live grid, in ONE ForEach over a
                    // unique 0..<total index space (two ForEaches both id'd 0,1,2…
                    // collide in a LazyVStack -> "undefined results" / jumbled scroll).
                    // Rows wrap (no truncation/"…") and grow vertically; the view
                    // re-pins to the bottom on every update so typed input stays
                    // visible even when scrolled up into history. Mouse drag selects,
                    // double-click selects a word, shift-click extends.
                    let total = sb.count + grid.count
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(0..<total), id: \.self) { idx in
                                    let inGrid = idx >= sb.count
                                    let cells = inGrid ? grid[idx - sb.count] : sb[idx]
                                    Text(line(cells, isCursorRow: inGrid && (idx - sb.count) == curRow,
                                              selCols: console.selectedCols(row: idx), fontSize: fontSize))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, minHeight: lineH, alignment: .topLeading)
                                }
                                Color.clear.frame(height: 1).id("term_bottom")
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .coordinateSpace(name: "term")
                            .gesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .named("term"))
                                    .onChanged { v in
                                        if !dragging { console.selectBegin(hit(v.startLocation)); dragging = true }
                                        console.selectExtend(hit(v.location))
                                    }
                                    .onEnded { _ in dragging = false }
                            )
                            .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named("term"))
                                .onEnded { console.selectWord(hit($0.location)) })
                            .gesture(SpatialTapGesture(count: 1, coordinateSpace: .named("term"))
                                .onEnded { _ in console.selectClear() })
                            // shift-click to extend (macOS only; no-op on iOS)
                            .shiftClickExtend(in: "term") { console.selectExtend(hit($0)) }
                        }
                        // follow the bottom on output/input, but not mid-drag-select
                        .onChange(of: terminal.version) { _, _ in if !dragging { proxy.scrollTo("term_bottom", anchor: .bottom) } }
                        .onAppear { proxy.scrollTo("term_bottom", anchor: .bottom) }
                    }
                }
            }
            .onAppear { if valid { onResize(fitCols, fitRows) } }
            .onChange(of: geo.size) { _, _ in if valid { onResize(fitCols, fitRows) } }
        }
    }

    /// Build one row (a `[Cell]`) as an AttributedString, grouping equal-attribute
    /// runs. `isCursorRow` marks the live grid line the cursor sits on; `selCols`
    /// are the selected cells (highlighted). Trailing blank cells are dropped so
    /// the row wraps tightly and copies cleanly.
    private func line(_ cells: [Cell], isCursorRow: Bool, selCols: Range<Int>? = nil,
                      fontSize: CGFloat) -> AttributedString {
        let showCursor = focused && terminal.cursorVisible && isCursorRow
        func sel(_ i: Int) -> Bool { selCols?.contains(i) ?? false }

        var end = cells.count
        while end > 0, cells[end - 1].scalar == " ", cells[end - 1].attrs == CellAttrs(), !sel(end - 1) { end -= 1 }
        if showCursor { end = max(end, min(terminal.cursorCol + 1, cells.count)) }
        if let s = selCols { end = max(end, min(s.upperBound, cells.count)) }

        var out = AttributedString()
        var i = 0
        while i < end {
            let isCursor = showCursor && i == terminal.cursorCol
            let selected = sel(i)
            let a = cells[i].attrs
            var run = String(cells[i].scalar)
            var j = i + 1
            while j < end, cells[j].attrs == a, sel(j) == selected,
                  !(showCursor && j == terminal.cursorCol), !isCursor {
                run.append(Character(cells[j].scalar)); j += 1
            }
            out.append(styled(run, a, fontSize: fontSize, cursor: isCursor, selected: selected))
            i = isCursor ? i + 1 : j
        }
        return out
    }

    private func styled(_ s: String, _ a: CellAttrs, fontSize: CGFloat,
                        cursor: Bool, selected: Bool) -> AttributedString {
        var as_ = AttributedString(s)
        var fg = a.fg.color(foreground: true)
        var bg = a.bg.color(foreground: false)
        if a.dim { fg = fg.opacity(0.6) }
        if a.inverse != cursor { swap(&fg, &bg) }            // cursor = inverse block
        if selected { bg = Term.selection; fg = .white }     // selection overrides
        as_.font = .system(size: fontSize, weight: a.bold ? .bold : .regular, design: .monospaced)
        as_.foregroundColor = fg
        if bg != Term.bg || cursor || a.inverse || selected { as_.backgroundColor = bg }
        if a.underline { as_.underlineStyle = .single }
        return as_
    }
}
