//
//  BrainNamingRulesTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// Kannu's Settings window is shown to users as **Brain**; the code keeps the Settings names
/// (`SettingsView`, `SettingsWindowController`, `settingsIconInNotch`). The views are not compiled
/// into the logic target, so the rename is read from the source, the `LaunchGateRulesTests` way:
/// every string literal under `Kannu/` that still says "Settings" (comments do not count) must be
/// on the allowlist below, with the reason it does not mean Kannu's own window.
final class BrainNamingRulesTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root

    /// Never Kannu's window, wherever it appears: macOS's own app, in permission prompts and logs.
    private static let allowedPhrases = ["System Settings"]

    private enum Match {
        case exactly(String)
        case containing(String)

        func matches(_ text: String) -> Bool {
            switch self {
            case .exactly(let literal): return text == literal
            case .containing(let fragment): return text.contains(fragment)
            }
        }
    }

    private struct Allowed {
        let file: String
        let literal: Match
        let reason: String
    }

    /// Each entry must match exactly one literal in its file: a stale entry fails, and so does a
    /// second string hiding behind one.
    private static let allowlist: [Allowed] = [
        Allowed(file: "Kannu/KannuApp.swift", literal: .exactly("Open Accessibility Settings"),
                reason: "a menu item that opens the macOS System Settings pane"),
        Allowed(file: "Kannu/KannuApp.swift", literal: .exactly("Open Full Disk Access Settings"),
                reason: "a menu item that opens the macOS System Settings pane"),
        Allowed(file: "Kannu/KannuApp.swift", literal: .exactly("Open Developer Tools Settings"),
                reason: "a menu item that opens the macOS System Settings pane"),
        Allowed(file: "Kannu/managers/AgentStatus/SecurityFindingGuide.swift", literal: .containing("Settings file: "),
                reason: "an agent's own config file (such as ~/.claude/settings.json), not Kannu's window"),
        Allowed(file: "Kannu/managers/AgentStatus/AgentHookInstaller.swift",
                literal: .containing("# Installed by Kannu: reports AI agent status"),
                reason: "bash comments in the embedded hook script: never shown, and the script must stay "
                    + "byte-identical to scripts/kannu-agent-status.sh (docs/REGRESSIONS.md entry 1)"),
        Allowed(file: "Kannu/components/Settings/SettingsView.swift",
                literal: .containing("BetterDisplay's OSD integration is enabled in Settings"),
                reason: "BetterDisplay's own Settings window"),
        Allowed(file: "Kannu/components/Settings/SettingsView.swift", literal: .exactly("Settings"),
                reason: "the Clipboard section's header: that feature's own group of options inside Brain"),
        Allowed(file: "Kannu/components/Settings/SettingsView.swift", literal: .exactly("Open Settings"),
                reason: "SettingsPermissionCallout's default button, which opens macOS System Settings"),
        Allowed(file: "Kannu/components/Settings/ExtensionsSettings.swift", literal: .exactly("Global Settings"),
                reason: "the section header for options that apply to every extension"),
        Allowed(file: "Kannu/components/Live activities/DynamicIslandBattery.swift", literal: .exactly("Battery Settings"),
                reason: "opens the macOS Battery settings"),
        Allowed(file: "Kannu/components/ScreenAssistant/ChatPanels.swift", literal: .exactly("Open Model Settings"),
                reason: "opens the Screen Assistant's model panel, not Brain"),
    ]

    // MARK: - The rename

    func testNoStringLiteralCallsKannusWindowSettings() {
        XCTAssertGreaterThan(Self.scan.sourceCount, 100, "the scan read almost nothing — check the path, not the rule")
        let offenders = Self.scan.flagged
            .filter { item in !Self.allowlist.contains { $0.file == item.path && $0.literal.matches(item.literal.text) } }
            .map { "\($0.path):\($0.literal.line): \"\($0.literal.text.prefix(120))\"" }
        XCTAssertEqual(offenders, [], """
            User-visible text calls Kannu's window "Settings", which users now see as Brain. Rename the \
            string; if it means something else (macOS, another app, an agent's config file), add it to \
            the allowlist with the reason.
            """)
    }

    func testEveryAllowlistEntryMatchesExactlyOneLiteral() {
        for entry in Self.allowlist {
            let hits = Self.scan.flagged.filter { $0.path == entry.file && entry.literal.matches($0.literal.text) }
            XCTAssertEqual(hits.count, 1, """
                \(entry.file) (\(entry.reason)): \(hits.count) literals match. A stale entry guards \
                nothing, and a shared one hides a new string.
                """)
        }
    }

    func testTheWindowIsTitledKannuBrain() throws {
        let source = Self.code(try Self.read("Kannu/components/Settings/SettingsWindowController.swift"))
        XCTAssertTrue(source.contains(#"window.title = String(localized: "Kannu Brain")"#))
    }

    /// The header button that opens Brain shows the brain symbol. Screen Assistant keeps
    /// `brain.head.profile`, so the two never look alike.
    func testTheNotchHeaderButtonShowsTheBrainSymbol() throws {
        let header = Self.code(try Self.read("Kannu/components/Notch/KannuHeader.swift"))
        let start = try XCTUnwrap(header.range(of: "if Defaults[.settingsIconInNotch] {"),
                                  "the header's Brain button moved — this pin is vacuous")
        let end = try XCTUnwrap(header.range(of: "RecordingIndicator()", range: start.upperBound..<header.endIndex))
        let button = String(header[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(button.contains(#"Image(systemName: "brain")"#), "the button no longer shows the brain")
        XCTAssertFalse(button.contains(#""gear""#), "the button still shows the gear")
        XCTAssertTrue(button.contains(#".accessibilityLabel("Brain")"#))
        XCTAssertTrue(button.contains(#".hoverTooltip(String(localized: "Brain"), edge: .below)"#))
        XCTAssertFalse(button.contains(".help("), "a notch tooltip is .hoverTooltip; .help never renders there (REGRESSIONS entry 9)")
        XCTAssertFalse(header.contains("brain.head.profile"), "brain.head.profile is Screen Assistant's symbol")
    }

    /// `commands` used to be declared and never attached to a scene, so ⌘, did nothing.
    func testCommandCommaOpensBrainFromTheAppScene() throws {
        let source = Self.code(try Self.read("Kannu/KannuApp.swift"))
        let app = try XCTUnwrap(source.range(of: "struct KannuApp: App {"))
        let next = try XCTUnwrap(source.range(of: "final class FirstMouseHostingView"))
        let appStruct = String(source[app.lowerBound..<next.lowerBound])
        let commandsStart = try XCTUnwrap(appStruct.range(of: "var commands: some Commands {"), "the commands went away")
        let body = String(appStruct[..<commandsStart.lowerBound])
        let commands = String(appStruct[commandsStart.lowerBound...])

        XCTAssertTrue(body.contains("var body: some Scene {"))
        XCTAssertTrue(body.contains(".commands { commands }"), "the commands are not attached to a scene, so ⌘, does nothing")
        XCTAssertTrue(commands.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(commands.contains(#"Button(String(localized: "Brain…"))"#))
        XCTAssertTrue(commands.contains(#".keyboardShortcut(",", modifiers: .command)"#))
        XCTAssertFalse(commands.contains("Settings…"))
        // Before the terms are accepted it brings them back, never Brain: nothing runs first.
        let guardAt = try XCTUnwrap(commands.range(of: "guard appDelegate.launchContinued else")?.lowerBound)
        let open = try XCTUnwrap(commands.range(of: "SettingsWindowController.shared.showWindow()")?.lowerBound)
        XCTAssertLessThan(guardAt, open)
        XCTAssertTrue(commands.contains("TermsGateWindowController.shared.bringToFront()"))
    }

    func testTheMenusAndSearchSayBrain() throws {
        let app = Self.code(try Self.read("Kannu/KannuApp.swift"))
        XCTAssertTrue(app.contains(#"menu.addItem(withTitle: String(localized: "Brain"),"#), "the menu bar icon's menu")
        let content = Self.code(try Self.read("Kannu/ContentView.swift"))
        XCTAssertTrue(content.contains(#"Button("Brain") {"#), "the notch's right-click menu")
        let settings = Self.code(try Self.read("Kannu/components/Settings/SettingsView.swift"))
        XCTAssertTrue(settings.contains(#"TextField("Search Brain", text: $text)"#))
        // The row was renamed together with its search entry, and searching the old words still finds it.
        let entry = try XCTUnwrap(settings.components(separatedBy: "\n").first {
            $0.contains("SettingsSearchEntry(") && $0.contains(#"highlightID(for: "Brain icon in notch")"#)
        }, "no search entry lands on the Brain icon row")
        for word in [#""brain""#, #""settings""#, #""gear""#] {
            XCTAssertTrue(entry.contains(word), "searching \(word) must find the Brain icon row")
        }
        XCTAssertTrue(settings.contains(#".settingsHighlight(id: highlightID("Brain icon in notch"))"#))
    }

    // MARK: - The scanner is not vacuous

    func testTheScannerSeesAPlantedOffender() {
        let planted = #"""
            // Text("Open Settings") in a line comment is prose
            /* a block comment, /* nested */, still says "Settings" */
            let a = "Open Settings"
            let b = "System Settings › Privacy"
            let c = "https://example.com" + "Settings"
            let d = #"raw "quoted" Settings"#
            let e = "count: \(n == 1 ? "one Setting" : "Settings")"
            let f = "KannuSettingsWindow"
            let g = """
                first line
                then Settings
                """
            let h = "after"
            """#
        let literals = Self.literals(in: planted)
        let flagged = literals.filter { Self.saysSettings($0.text) }.map(\.line)
        XCTAssertEqual(flagged.sorted(), [3, 5, 6, 7, 9],
                       "comments, a URL's //, a raw string, an interpolation and a multi-line literal")
        XCTAssertTrue(literals.contains(Literal(line: 7, text: "one Setting")), "a literal inside an interpolation is read on its own")
        XCTAssertTrue(literals.contains(Literal(line: 7, text: #"count: \(…)"#)), "the interpolation does not end its literal")
        XCTAssertEqual(literals.last, Literal(line: 13, text: "after"), "lines are counted through comments and literals")
    }

    // MARK: - Scanning

    private struct Literal: Equatable {
        let line: Int
        let text: String
    }

    private struct Flagged {
        let path: String
        let literal: Literal
    }

    /// Every literal under `Kannu/` that says "Settings", read once for the whole class.
    private static let scan: (sourceCount: Int, flagged: [Flagged]) = {
        let root = repoRoot.appendingPathComponent("Kannu")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return (0, []) }
        var count = 0
        var flagged: [Flagged] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            count += 1
            let path = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            for literal in literals(in: text) where saysSettings(literal.text) {
                flagged.append(Flagged(path: path, literal: literal))
            }
        }
        return (count, flagged)
    }()

    private static func saysSettings(_ text: String) -> Bool {
        var remaining = text
        for phrase in allowedPhrases {
            remaining = remaining.replacingOccurrences(of: phrase, with: "")
        }
        return remaining.range(of: #"\bSettings\b"#, options: .regularExpression) != nil
    }

    /// Every string literal in Swift source, comments skipped: `"…"`, `"""…"""`, and raw `#"…"#`
    /// with any number of `#`. An interpolation is read as code, so a literal nested in it is
    /// reported on its own and the outer literal's text shows `\(…)` in its place.
    private static func literals(in source: String) -> [Literal] {
        var scanner = LiteralScanner(bytes: Array(source.utf8))
        scanner.scanCode(insideInterpolation: false)
        return scanner.found
    }

    private struct LiteralScanner {
        private static let quote = UInt8(ascii: "\"")
        private static let hash = UInt8(ascii: "#")
        private static let slash = UInt8(ascii: "/")
        private static let star = UInt8(ascii: "*")
        private static let backslash = UInt8(ascii: "\\")
        private static let newline = UInt8(ascii: "\n")
        private static let openParen = UInt8(ascii: "(")
        private static let closeParen = UInt8(ascii: ")")

        let bytes: [UInt8]
        var index = 0
        var line = 1
        var found: [Literal] = []

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        private func at(_ position: Int) -> UInt8? {
            position < bytes.count ? bytes[position] : nil
        }

        private func hashes(_ count: Int, from position: Int) -> Bool {
            var offset = 0
            while offset < count {
                if at(position + offset) != Self.hash { return false }
                offset += 1
            }
            return true
        }

        /// Reads code to the end, or, inside an interpolation, through its closing parenthesis.
        mutating func scanCode(insideInterpolation: Bool) {
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == Self.slash, at(index + 1) == Self.slash {
                    while index < bytes.count, bytes[index] != Self.newline { index += 1 }
                    continue
                }
                if byte == Self.slash, at(index + 1) == Self.star {
                    skipBlockComment()
                    continue
                }
                if byte == Self.quote || byte == Self.hash, let count = openingHashes() {
                    readLiteral(hashes: count)
                    continue
                }
                if byte == Self.newline { line += 1 }
                if insideInterpolation {
                    if byte == Self.openParen { depth += 1 }
                    if byte == Self.closeParen {
                        if depth == 0 {
                            index += 1
                            return
                        }
                        depth -= 1
                    }
                }
                index += 1
            }
        }

        /// Swift block comments nest.
        private mutating func skipBlockComment() {
            var depth = 0
            while index < bytes.count {
                if bytes[index] == Self.slash, at(index + 1) == Self.star {
                    depth += 1
                    index += 2
                    continue
                }
                if bytes[index] == Self.star, at(index + 1) == Self.slash {
                    depth -= 1
                    index += 2
                    if depth == 0 { return }
                    continue
                }
                if bytes[index] == Self.newline { line += 1 }
                index += 1
            }
        }

        /// The number of `#` before a literal's opening quote, or nil when no literal starts here.
        private func openingHashes() -> Int? {
            var count = 0
            while at(index + count) == Self.hash { count += 1 }
            return at(index + count) == Self.quote ? count : nil
        }

        private func closes(multiline: Bool, hashes count: Int) -> Bool {
            let quotes = multiline ? 3 : 1
            for offset in 0..<quotes where at(index + offset) != Self.quote { return false }
            return hashes(count, from: index + quotes)
        }

        private mutating func readLiteral(hashes count: Int) {
            index += count
            let multiline = at(index) == Self.quote && at(index + 1) == Self.quote && at(index + 2) == Self.quote
            index += multiline ? 3 : 1
            let startLine = line
            var text: [UInt8] = []
            while index < bytes.count {
                if closes(multiline: multiline, hashes: count) {
                    index += (multiline ? 3 : 1) + count
                    break
                }
                let byte = bytes[index]
                if byte == Self.backslash, hashes(count, from: index + 1) {
                    let escaped = index + 1 + count
                    if at(escaped) == Self.openParen {
                        text.append(contentsOf: Array(#"\(…)"#.utf8))
                        index = escaped + 1
                        scanCode(insideInterpolation: true)
                        continue
                    }
                    // Any other escape, kept as written; an escaped newline still ends a line.
                    if escaped < bytes.count {
                        text.append(contentsOf: bytes[index...escaped])
                        if bytes[escaped] == Self.newline { line += 1 }
                    }
                    index = escaped + 1
                    continue
                }
                if byte == Self.newline {
                    if !multiline { break }  // unterminated: only in a file that does not compile
                    line += 1
                }
                text.append(byte)
                index += 1
            }
            found.append(Literal(line: startLine, text: String(decoding: text, as: UTF8.self)))
        }
    }

    // MARK: - Helpers

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    /// Source with comment lines dropped, so prose about a rule never satisfies it.
    private static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
        }.joined(separator: "\n") + "\n"
    }
}
