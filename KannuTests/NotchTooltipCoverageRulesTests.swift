/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest

/// Every icon-only control in the notch has a tooltip, and the tooltip is the custom one.
///
/// The user's rule: hovering an icon for a moment shows what it does, for every such icon. A glyph
/// alone does not say what it does, and VoiceOver reads the SF Symbol name instead of the action.
/// `.help(...)` never renders in the notch (docs/TOOLTIPS.md: the app is never active), so the
/// bubble is `HoverTooltip`'s, and the tooltip text doubles as the accessibility label.
///
/// It went wrong in three ways before this test existed (docs/REGRESSIONS.md entry 9):
/// - `TimerControlOverlay` used `.help(...)` in a folder the pre-commit grep did not scan.
/// - `TimerControlButton` had two hover sources, so the bubble fought its own highlight.
/// - Most icon buttons — including the lyrics button that prompted this — had no tooltip at all.
///
/// Three rules, checked over the notch's eight view folders:
/// 1. A call to a shared icon button passes `tooltip:` (or `accessibilityLabel:` for the two that
///    live in fitted panels, where no bubble can show).
/// 2. A plain `Button` whose label is only an `Image(systemName:)` has `.hoverTooltip(` (or
///    `.iconButtonTooltip(`) in its modifier chain, unless its file is allowlisted with a reason.
/// 3. No `.help(` outside comments and string literals.
///
/// The scanner strips comments and blanks string contents first, so prose about the rule never
/// trips it and a tooltip that is only commented out never satisfies it.
final class NotchTooltipCoverageRulesTests: XCTestCase {

    /// The notch's view folders. The pre-commit `.help(` scan lists the same eight.
    static let scannedFolders = [
        "Kannu/components/Notch",
        "Kannu/components/AgentStatus",
        "Kannu/components/Music",
        "Kannu/components/Timer",
        "Kannu/components/Clipboard",
        "Kannu/components/Tabs",
        "Kannu/components/Shelf",
        "Kannu/components/Stats"
    ]

    /// Shared icon buttons whose calls must pass `tooltip:`. Each draws the bubble from its own
    /// hover handler, so the control keeps one hover source.
    static let tooltipButtons = [
        "HoverButton",
        "MinimalisticSquircircleButton",
        "controlButton",
        "playbackButton",
        "TabButton",
        "TimerControlButton"
    ]

    /// Shared icon buttons that live in a panel sized to its own button row
    /// (MusicControlWindowManager, TimerControlWindowManager use `fittingSize`, height = notch
    /// height). A bubble above or below the row falls outside the window and never shows, so these
    /// must pass `accessibilityLabel:` instead — VoiceOver still learns what the glyph does.
    static let accessibilityLabelButtons = [
        "FloatingMediaButton",
        "ControlButton"
    ]

    /// Files whose icon-only Buttons are exempt from rule 2, each with the reason.
    static let iconButtonAllowlist: [String: String] = [
        "Kannu/components/Notch/ClipboardHistoryPopover.swift":
            "Dead code: only its own #Preview references ClipboardHistoryPopover.",
        "Kannu/components/Clipboard/ClipboardWindow.swift":
            "Dead code: ClipboardWindowManager is never referenced, so this window never opens.",
        "Kannu/components/Timer/TimerControlOverlay.swift":
            "Fitted panel: TimerControlWindowManager sizes the window to the button row, so a bubble "
            + "cannot show. ControlButton passes accessibilityLabel: instead (rule 1)."
    ]

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    // MARK: - The rules

    func testSharedIconButtonCallsPassATooltipOrALabel() {
        var offenders: [String] = []
        var calls = 0
        for (path, source) in Self.notchSources() {
            let result = Self.sharedCallOffenders(in: source, path: path)
            offenders += result.offenders
            calls += result.calls
        }
        XCTAssertGreaterThanOrEqual(calls, 25, "Found almost no shared-button calls — check the scanner, not the tree.")
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            A shared icon button is called without its tooltip. Pass tooltip: (it is also the \
            accessibility label), or accessibilityLabel: for FloatingMediaButton / ControlButton. \
            See docs/TOOLTIPS.md, "Every icon-only control has a tooltip".
            """
        )
    }

    func testEveryIconOnlyButtonHasAHoverTooltip() {
        var offenders: [String] = []
        var iconOnly = 0
        for (path, source) in Self.notchSources() {
            let result = Self.iconButtonOffenders(in: source, path: path)
            iconOnly += result.iconOnly
            if Self.iconButtonAllowlist[path] == nil {
                offenders += result.offenders
            } else {
                // An allowlisted file with no icon-only Button left exempts nothing: drop the entry.
                XCTAssertGreaterThan(result.iconOnly, 0, "\(path) is allowlisted but has no icon-only Button.")
            }
        }
        XCTAssertGreaterThanOrEqual(iconOnly, 35, "Found almost no icon-only Buttons — check the scanner, not the tree.")
        XCTAssertEqual(
            offenders.sorted(), [],
            """
            An icon-only Button has no .hoverTooltip(...) in its modifier chain. Add one with a \
            1–3 word, title-case action name, plus .accessibilityLabel with the same text. \
            See docs/TOOLTIPS.md, "Every icon-only control has a tooltip".
            """
        )
    }

    func testNoHelpModifierInTheNotch() {
        var offenders: [String] = []
        for (path, source) in Self.notchSources() {
            offenders += Self.helpOffenders(in: source, path: path)
        }
        XCTAssertEqual(
            offenders.sorted(), [],
            ".help(...) never renders in the notch — the app is never active. Use .hoverTooltip(...). See docs/TOOLTIPS.md."
        )
    }

    /// The rules pass vacuously if the tree is not where the walker looks, or if nobody uses the
    /// tooltip at all.
    func testTheScanIsNotVacuous() {
        let sources = Self.notchSources()
        XCTAssertGreaterThan(sources.count, 50, "The notch scan found almost nothing — check the path, not the rule.")
        XCTAssertNotNil(sources["Kannu/components/Notch/HoverTooltip.swift"])
        let tooltips = sources.values.reduce(0) { $0 + Self.occurrences(of: ".hoverTooltip", calledIn: Self.code($1)) }
        XCTAssertGreaterThanOrEqual(tooltips, 40, "Fewer .hoverTooltip( calls than icon buttons — the scan is looking at the wrong tree.")
    }

    /// An allowlist entry for a file that was renamed or deleted exempts nothing and hides the fact.
    func testEveryAllowlistedPathExistsAndHasAReason() {
        for (path, reason) in Self.iconButtonAllowlist {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.repoRoot.appendingPathComponent(path).path),
                "Allowlisted \(path) does not exist — remove the entry."
            )
            XCTAssertGreaterThan(reason.count, 20, "Allowlisted \(path) needs a real reason.")
        }
    }

    // MARK: - The scanner itself (planted offenders)

    func testScannerFlagsAnIconButtonWithoutATooltip() {
        let planted = """
        Button(action: { clear() }) {
            Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear")

        Button { create() } label: { Image(systemName: "plus") }
            .buttonStyle(.plain)

        Button(action: close, label: { Image(systemName: "xmark") })
        """
        let result = Self.iconButtonOffenders(in: planted, path: "X.swift")
        XCTAssertEqual(result.iconOnly, 3)
        XCTAssertEqual(result.offenders, ["X.swift:1", "X.swift:7", "X.swift:10"])
    }

    /// The chain walk has to step over a modifier with a multi-line trailing closure.
    func testScannerFindsATooltipAfterAMultiLinePopover() {
        let planted = """
        Button { toggle() } label: {
            Capsule().overlay { Image(systemName: "gear") }
        }
        .buttonStyle(PlainButtonStyle())
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack {
                Text("Settings")
            }
        }
        .onChange(of: shown) { _, value in
            update(value)
        }
        .hoverTooltip("Settings", edge: .below)
        """
        let result = Self.iconButtonOffenders(in: planted, path: "X.swift")
        XCTAssertEqual(result.iconOnly, 1)
        XCTAssertEqual(result.offenders, [])
    }

    /// Comments inside the chain are skipped, and a commented-out tooltip does not count.
    func testScannerSkipsCommentsInTheChain() {
        let withTooltip = """
        Button(action: go) {
            Image(systemName: "plus") // "Text(" in a comment is not a title
        }
        // a note between modifiers
        .buttonStyle(.plain) /* and a block one */
        .hoverTooltip("New Note", edge: .below)
        """
        XCTAssertEqual(Self.iconButtonOffenders(in: withTooltip, path: "X.swift").offenders, [])

        let commentedOut = """
        Button(action: go) {
            Image(systemName: "plus")
        }
        .buttonStyle(.plain)
        // .hoverTooltip("New Note", edge: .below)
        /* .hoverTooltip("New Note") */
        """
        XCTAssertEqual(Self.iconButtonOffenders(in: commentedOut, path: "X.swift").offenders, ["X.swift:1"])

        let urlInString = """
        let link = "https://example.com/a//b"
        Button(action: go) { Image(systemName: "link") }
        """
        XCTAssertEqual(Self.iconButtonOffenders(in: urlInString, path: "X.swift").offenders, ["X.swift:2"])
    }

    /// A Button with a visible title already says what it does.
    func testScannerIgnoresTextLabelledButtons() {
        let planted = """
        Button(action: cancel) {
            HStack { Image(systemName: "chevron.left"); Text("Notes") }
        }
        Button("Done") { save() }
        Button(String(localized: "Clear")) { clear() }
        Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
        Button(title) { run() }
        Button("") { paste() }
        """
        let result = Self.iconButtonOffenders(in: planted, path: "X.swift")
        XCTAssertEqual(result.iconOnly, 0)
        XCTAssertEqual(result.offenders, [])
    }

    /// A function declaration named like a shared button is not a call to it; type names and
    /// `PlainButtonStyle` are not calls either.
    func testScannerIgnoresDeclarations() {
        let planted = """
        private func controlButton(icon: String, size: CGFloat = 18) -> some View { EmptyView() }
        private struct TabButton: View { var body: some View { EmptyView() } }
        let effect: HoverButton.PressEffect = .nudge(2)
        Button(action: go) { Image(systemName: "plus") }.buttonStyle(PlainButtonStyle()).hoverTooltip("New")
        """
        let shared = Self.sharedCallOffenders(in: planted, path: "X.swift")
        XCTAssertEqual(shared.calls, 0)
        XCTAssertEqual(shared.offenders, [])
        XCTAssertEqual(Self.iconButtonOffenders(in: planted, path: "X.swift").offenders, [])
    }

    func testScannerChecksSharedButtonArguments() {
        let planted = """
        HoverButton(icon: "shuffle", scale: .medium) { shuffle() }
        HoverButton(icon: "repeat", scale: .medium, tooltip: control.label) { repeatMode() }
        controlButton(icon: "shuffle", tooltip: control.label, isActive: on) { toggle() }
        controlButton(icon: "repeat", isActive: on ? true : false, action: { label(tooltip: 1) })
        FloatingMediaButton(icon: "play.fill", isEnabled: true, action: play)
        FloatingMediaButton(icon: "play.fill", accessibilityLabel: label, action: play)
        ControlButton(icon: "xmark", help: "Cancel", action: stop)
        TimerControlButton(icon: "xmark", tooltip: String(localized: "Cancel"), action: stop)
        """
        let result = Self.sharedCallOffenders(in: planted, path: "X.swift")
        XCTAssertEqual(result.calls, 8)
        // Line 4: `tooltip:` inside a nested closure is not the call's own argument.
        XCTAssertEqual(result.offenders, ["X.swift:1", "X.swift:4", "X.swift:5", "X.swift:7"])
    }

    func testScannerIgnoresHelpInCommentsAndStrings() {
        let prose = """
        /// SwiftUI's `.help(...)` is dead here.
        // never .help("x")
        /* .help("y") */
        let note = "do not use .help(\\(name)) here"
        """
        XCTAssertEqual(Self.helpOffenders(in: prose, path: "X.swift"), [])
        XCTAssertEqual(Self.helpOffenders(in: "Image(systemName: \"x\")\n    .help (\"X\")", path: "X.swift"), ["X.swift:2"])
    }
}

// MARK: - Lexer

extension NotchTooltipCoverageRulesTests {

    private enum LexContext {
        case string(multiline: Bool, hashes: Int)
        case interpolation(depth: Int)
    }

    /// The source as UTF-8 with every comment and every string literal's contents replaced by
    /// spaces. Newlines, the quotes themselves and interpolated code are kept, so offsets and line
    /// numbers still match the file and brackets still balance. Every byte of a multi-byte
    /// character sits inside the blanked span, so the result is valid UTF-8.
    static func code(_ source: String) -> [UInt8] {
        let bytes = Array(source.utf8)
        var out = bytes
        let count = bytes.count
        var stack: [LexContext] = []
        var i = 0

        func blank(_ k: Int) { if out[k] != .newline { out[k] = .space } }
        func hashes(_ from: Int, _ wanted: Int) -> Bool {
            guard wanted > 0 else { return true }
            guard from + wanted <= count else { return false }
            return bytes[from..<(from + wanted)].allSatisfy { $0 == .hash }
        }

        while i < count {
            let c = bytes[i]
            if case .string(let multiline, let delimiter)? = stack.last {
                if c == .backslash && hashes(i + 1, delimiter) {
                    let next = i + 1 + delimiter
                    if next < count && bytes[next] == .openParen {
                        // `\(` opens interpolated code; keep its `(` so parentheses balance.
                        for k in i..<next { blank(k) }
                        stack.append(.interpolation(depth: 1))
                        i = next + 1
                        continue
                    }
                    for k in i...min(next, count - 1) { blank(k) }
                    i = next + 1
                    continue
                }
                if c == .quote {
                    if multiline {
                        if i + 2 < count && bytes[i + 1] == .quote && bytes[i + 2] == .quote && hashes(i + 3, delimiter) {
                            stack.removeLast()
                            i += 3 + delimiter
                            continue
                        }
                    } else if hashes(i + 1, delimiter) {
                        stack.removeLast()
                        i += 1 + delimiter
                        continue
                    }
                }
                blank(i)
                i += 1
                continue
            }

            // Code: top level, or inside an interpolation.
            if c == .slash && i + 1 < count && bytes[i + 1] == .slash {
                while i < count && bytes[i] != .newline { blank(i); i += 1 }
                continue
            }
            if c == .slash && i + 1 < count && bytes[i + 1] == .star {
                // Swift block comments nest.
                var depth = 0
                while i < count {
                    if i + 1 < count && bytes[i] == .slash && bytes[i + 1] == .star {
                        depth += 1; blank(i); blank(i + 1); i += 2
                    } else if i + 1 < count && bytes[i] == .star && bytes[i + 1] == .slash {
                        depth -= 1; blank(i); blank(i + 1); i += 2
                        if depth == 0 { break }
                    } else {
                        blank(i); i += 1
                    }
                }
                continue
            }
            if c == .quote || c == .hash {
                var j = i
                while j < count && bytes[j] == .hash { j += 1 }
                if j < count && bytes[j] == .quote {
                    let multiline = j + 2 < count && bytes[j + 1] == .quote && bytes[j + 2] == .quote
                    stack.append(.string(multiline: multiline, hashes: j - i))
                    i = j + (multiline ? 3 : 1)
                    continue
                }
                i += 1   // `#if`, `#available`, `#Preview`…
                continue
            }
            if case .interpolation(let depth)? = stack.last {
                if c == .openParen {
                    stack[stack.count - 1] = .interpolation(depth: depth + 1)
                } else if c == .closeParen {
                    if depth == 1 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(depth: depth - 1) }
                }
            }
            i += 1
        }
        return out
    }

    // MARK: Scanning primitives (all on `code(_:)` output)

    static func line(of offset: Int, in code: [UInt8]) -> Int {
        code[..<offset].reduce(1) { $0 + ($1 == .newline ? 1 : 0) }
    }

    static func skipSpace(_ code: [UInt8], from start: Int, newlines: Bool = true) -> Int {
        var i = start
        while i < code.count, code[i].isSpace, newlines || code[i] != .newline { i += 1 }
        return i
    }

    /// Index of the bracket closing the one at `open`, or nil if it never closes.
    static func matchClose(_ code: [UInt8], open: Int) -> Int? {
        let opener = code[open]
        let closer: UInt8 = opener == .openParen ? .closeParen : (opener == .openBrace ? .closeBrace : .closeBracket)
        var depth = 0
        var i = open
        while i < code.count {
            if code[i] == opener { depth += 1 } else if code[i] == closer {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    static func identifier(_ code: [UInt8], at start: Int) -> (name: String, end: Int) {
        var i = start
        while i < code.count, code[i].isIdentifier { i += 1 }
        return (String(decoding: code[start..<i], as: UTF8.self), i)
    }

    /// Offsets where `word` appears as a whole identifier. A leading `.` is part of `word` when
    /// it is wanted (`.help`); otherwise a `.` before the word disqualifies it (`SwiftUI.Button`).
    static func wordOffsets(of word: String, in code: [UInt8]) -> [Int] {
        let needle = Array(word.utf8)
        guard !needle.isEmpty, code.count >= needle.count else { return [] }
        var hits: [Int] = []
        var i = 0
        while i <= code.count - needle.count {
            if code[i] == needle[0], Array(code[i..<(i + needle.count)]) == needle {
                let before = i > 0 ? code[i - 1] : .space
                let after = i + needle.count < code.count ? code[i + needle.count] : .space
                let leadingDot = needle[0] == .dot
                let boundaryBefore = leadingDot || (!before.isIdentifier && before != .dot)
                if boundaryBefore, !after.isIdentifier {
                    hits.append(i)
                }
            }
            i += 1
        }
        return hits
    }

    /// How many times `word` is called: followed, after optional spaces, by `(`.
    static func occurrences(of word: String, calledIn code: [UInt8]) -> Int {
        let length = word.utf8.count
        return wordOffsets(of: word, in: code).filter { offset in
            let next = skipSpace(code, from: offset + length)
            return next < code.count && code[next] == .openParen
        }.count
    }

    /// The labels of the arguments directly inside the brackets at `open`...`close`, with the
    /// range of each value. Labels inside nested closures or calls are not included.
    static func topLevelArguments(_ code: [UInt8], open: Int, close: Int) -> [(label: String?, value: Range<Int>)] {
        var arguments: [(label: String?, value: Range<Int>)] = []
        var segmentStart = open + 1
        var depth = 0
        var i = open + 1
        func finish(_ end: Int) {
            let start = skipSpace(code, from: segmentStart)
            guard start < end else { return }
            let (name, nameEnd) = identifier(code, at: start)
            let colon = skipSpace(code, from: nameEnd)
            if !name.isEmpty, colon < end, code[colon] == .colon {
                arguments.append((name, (colon + 1)..<end))
            } else {
                arguments.append((nil, start..<end))
            }
        }
        while i < close {
            switch code[i] {
            case .openParen, .openBrace, .openBracket: depth += 1
            case .closeParen, .closeBrace, .closeBracket: depth -= 1
            case .comma where depth == 0:
                finish(i)
                segmentStart = i + 1
            default: break
            }
            i += 1
        }
        finish(close)
        return arguments
    }

    static func contains(_ needle: String, in code: [UInt8], _ range: Range<Int>) -> Bool {
        let n = Array(needle.utf8)
        guard range.count >= n.count else { return false }
        var i = range.lowerBound
        while i <= range.upperBound - n.count {
            if Array(code[i..<(i + n.count)]) == n { return true }
            i += 1
        }
        return false
    }

    static func precedingWord(_ code: [UInt8], before offset: Int) -> String {
        var end = offset
        while end > 0, code[end - 1].isSpace { end -= 1 }
        var start = end
        while start > 0, code[start - 1].isIdentifier { start -= 1 }
        return String(decoding: code[start..<end], as: UTF8.self)
    }

    /// From the end of a closure or argument list, an optional run of `name: { … }` closures
    /// (`label: { … }`, `message: { … }`). Returns those closures and where the run ends.
    static func labeledClosures(_ code: [UInt8], after start: Int) -> (closures: [(label: String, body: Range<Int>)], end: Int) {
        var closures: [(label: String, body: Range<Int>)] = []
        var end = start
        while true {
            let (name, nameEnd) = identifier(code, at: skipSpace(code, from: end))
            guard !name.isEmpty else { break }
            let colon = skipSpace(code, from: nameEnd)
            guard colon < code.count, code[colon] == .colon else { break }
            let brace = skipSpace(code, from: colon + 1)
            guard brace < code.count, code[brace] == .openBrace, let close = matchClose(code, open: brace) else { break }
            closures.append((name, (brace + 1)..<close))
            end = close + 1
        }
        return (closures, end)
    }

    /// The names of the modifiers chained onto the expression ending at `start`, stepping over
    /// argument lists, trailing closures (however many lines they span) and labeled closures.
    /// Comments are already blank, so they cannot end the walk early or satisfy it.
    static func modifierChain(_ code: [UInt8], from start: Int) -> [String] {
        var names: [String] = []
        var p = start
        while true {
            let dot = skipSpace(code, from: p)
            guard dot < code.count, code[dot] == .dot else { break }
            let (name, nameEnd) = identifier(code, at: skipSpace(code, from: dot + 1))
            guard !name.isEmpty else { break }
            names.append(name)
            p = nameEnd
            var next = skipSpace(code, from: p, newlines: false)
            if next < code.count, code[next] == .openParen, let close = matchClose(code, open: next) {
                p = close + 1
                next = skipSpace(code, from: p, newlines: false)
            }
            if next < code.count, code[next] == .openBrace, let close = matchClose(code, open: next) {
                p = labeledClosures(code, after: close + 1).end
            }
        }
        return names
    }
}

// MARK: - Rules

extension NotchTooltipCoverageRulesTests {

    /// Every Swift file under the eight notch folders, keyed by repo-relative path.
    static func notchSources() -> [String: String] {
        var out: [String: String] = [:]
        for folder in scannedFolders {
            let root = repoRoot.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out[url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")] = text
            }
        }
        return out
    }

    /// Rule 1: calls to the shared icon buttons carry their tooltip (or label) argument.
    static func sharedCallOffenders(in source: String, path: String) -> (offenders: [String], calls: Int) {
        let code = Self.code(source)
        var offenders: [String] = []
        var calls = 0
        for name in tooltipButtons + accessibilityLabelButtons {
            let required = tooltipButtons.contains(name) ? "tooltip" : "accessibilityLabel"
            for offset in wordOffsets(of: name, in: code) {
                let open = skipSpace(code, from: offset + name.utf8.count)
                guard open < code.count, code[open] == .openParen else { continue }
                guard precedingWord(code, before: offset) != "func" else { continue }
                guard let close = matchClose(code, open: open) else { continue }
                calls += 1
                let labels = topLevelArguments(code, open: open, close: close).compactMap(\.label)
                if !labels.contains(required) {
                    offenders.append("\(path):\(line(of: offset, in: code))")
                }
            }
        }
        return (offenders, calls)
    }

    /// Rule 2: a `Button` whose label is only an SF Symbol has a tooltip in its modifier chain.
    static func iconButtonOffenders(in source: String, path: String) -> (offenders: [String], iconOnly: Int) {
        let code = Self.code(source)
        var offenders: [String] = []
        var iconOnly = 0
        for offset in wordOffsets(of: "Button", in: code) {
            var end = offset + "Button".utf8.count
            var arguments: [(label: String?, value: Range<Int>)] = []
            var next = skipSpace(code, from: end)
            if next < code.count, code[next] == .openParen {
                guard let close = matchClose(code, open: next) else { continue }
                arguments = topLevelArguments(code, open: next, close: close)
                end = close + 1
                next = skipSpace(code, from: end)
            }
            // An unlabeled first argument is a title — "…", String(localized:), Text(…), a variable.
            if let first = arguments.first, first.label == nil { continue }

            var actionOrLabel: Range<Int>?
            var labeled: [(label: String, body: Range<Int>)] = []
            if next < code.count, code[next] == .openBrace, let close = matchClose(code, open: next) {
                actionOrLabel = (next + 1)..<close
                let run = labeledClosures(code, after: close + 1)
                labeled = run.closures
                end = run.end
            } else if arguments.isEmpty {
                continue   // `Button` used as a type name, not a call.
            }

            let label: Range<Int>?
            if let argument = arguments.first(where: { $0.label == "label" }) {
                label = argument.value
            } else if let closure = labeled.first(where: { $0.label == "label" }) {
                label = closure.body
            } else if arguments.contains(where: { $0.label == "action" }) {
                label = actionOrLabel
            } else {
                label = nil
            }
            guard let label,
                  contains("Image(systemName", in: code, label),
                  !contains("Text(", in: code, label),
                  !contains("Label(", in: code, label) else { continue }

            iconOnly += 1
            let chain = modifierChain(code, from: end)
            if !chain.contains("hoverTooltip") && !chain.contains("iconButtonTooltip") {
                offenders.append("\(path):\(line(of: offset, in: code))")
            }
        }
        return (offenders, iconOnly)
    }

    /// Rule 3: no `.help(` in code. Comments and string contents are already blank.
    static func helpOffenders(in source: String, path: String) -> [String] {
        let code = Self.code(source)
        return wordOffsets(of: ".help", in: code).compactMap { offset in
            let next = skipSpace(code, from: offset + ".help".utf8.count)
            guard next < code.count, code[next] == .openParen else { return nil }
            return "\(path):\(line(of: offset, in: code))"
        }
    }
}

private extension UInt8 {
    static let newline = UInt8(ascii: "\n")
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let carriageReturn = UInt8(ascii: "\r")
    static let hash = UInt8(ascii: "#")
    static let quote = UInt8(ascii: "\"")
    static let backslash = UInt8(ascii: "\\")
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let dot = UInt8(ascii: ".")
    static let comma = UInt8(ascii: ",")
    static let colon = UInt8(ascii: ":")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")

    var isIdentifier: Bool {
        (self >= 0x30 && self <= 0x39) || (self >= 0x41 && self <= 0x5A)
            || (self >= 0x61 && self <= 0x7A) || self == 0x5F || self >= 0x80
    }

    var isSpace: Bool { self == .space || self == .tab || self == .newline || self == .carriageReturn }
}
