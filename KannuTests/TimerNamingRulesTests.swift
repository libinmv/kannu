//
//  TimerNamingRulesTests.swift
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

/// The timer views are not compiled into the logic target, so the naming wiring is read from their
/// source (the `LaunchGateRulesTests` idiom): every session a view starts takes the name the user
/// typed, and every view that shows a running session lets the user rename it. A start path added
/// later without the typed name would silently drop it.
final class TimerNamingRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    private static let startingViews = [
        "Kannu/components/Notch/NotchTimerView.swift",
        "Kannu/components/Timer/TimerPopover.swift",
    ]

    func testEverySessionAViewStartsTakesTheTypedName() throws {
        for path in Self.startingViews {
            let source = Self.code(try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8))
            let starts = Self.calls(of: "startTimer(", in: source)
            XCTAssertFalse(starts.isEmpty, "\(path): no start found; this pin would be vacuous")
            XCTAssertEqual(Self.offenders(starts), [], "\(path) starts a session without the typed name")
        }
    }

    func testEveryRunningSessionCanBeRenamed() throws {
        for path in Self.startingViews {
            let source = Self.code(try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8))
            XCTAssertTrue(source.contains("renameSession(to:"), "\(path) shows a running session it cannot rename")
        }
    }

    /// A rename is saved when the view goes away (the notch closes, the tab or popover is left),
    /// and only into the session it began in, because that save can land after a new one started.
    func testARenameIsSavedWhenTheViewGoesAwayAndOnlyIntoItsOwnSession() throws {
        for path in Self.startingViews {
            let source = Self.code(try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8))
            let disappears = Self.modifiers(".onDisappear", in: source)
            XCTAssertTrue(disappears.contains { $0.contains("commitRename()") }, "\(path) drops a rename when it closes")
            let renames = Self.calls(of: "renameSession(", in: source)
            XCTAssertFalse(renames.isEmpty)
            XCTAssertEqual(renames.filter { !$0.contains("session:") }, [], "\(path) renames without the session it began in")
        }
    }

    /// In the notch, a click into another app leaves the field focused in a background window.
    func testTheNotchSavesARenameWhenItsWindowGoesToTheBackground() throws {
        let path = Self.startingViews[0]
        let source = Self.code(try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8))
        let observers = Self.modifiers(".onReceive", in: source)
        XCTAssertTrue(
            observers.contains { $0.contains("didResignKeyNotification") && $0.contains("commitRename()") },
            "\(path) keeps an unsaved rename when the user clicks into another app"
        )
    }

    func testTheScannerCatchesAPlantedOffender() {
        let planted = Self.code("""
            // timerManager.startTimer(duration: 1, name: "in a comment")
            timerManager.startTimer(duration: 60, name: preset.name, preset: preset)
            timerManager.startTimer(
                duration: 60,
                name: TimerSessionName.resolved(typed: typed, fallback: "Focus")
            )
            """)
        let starts = Self.calls(of: "startTimer(", in: planted)
        XCTAssertEqual(starts.count, 2, "the comment is skipped; the multi-line call is read whole")
        XCTAssertEqual(Self.offenders(starts).count, 1)
    }

    func testTheModifierScannerReadsArgumentsAndTrailingClosure() {
        let planted = """
            .onDisappear {
                commitRename()
            }
            .onReceive(center.publisher(for: X)) { note in
                if note.object is KannuWindow { commitRename() }
            }
            .onDisappear { other() }
            """
        let disappears = Self.modifiers(".onDisappear", in: planted)
        XCTAssertEqual(disappears.count, 2)
        XCTAssertTrue(disappears[0].contains("commitRename()"))
        XCTAssertFalse(disappears[1].contains("commitRename()"), "one modifier's closure never reaches the next")
        let receives = Self.modifiers(".onReceive", in: planted)
        XCTAssertEqual(receives.count, 1)
        XCTAssertTrue(receives[0].contains("publisher(for: X)") && receives[0].hasSuffix("}"))
    }

    // MARK: - Scanning

    /// Each use of a modifier: its name, its balanced argument list if any, then its trailing closure if any.
    private static func modifiers(_ name: String, in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: name, range: searchStart..<text.endIndex) {
            var index = range.upperBound
            for (open, close) in [(Character("("), Character(")")), (Character("{"), Character("}"))] {
                var probe = index
                while probe < text.endIndex, text[probe] == " " { probe = text.index(after: probe) }
                guard probe < text.endIndex, text[probe] == open else { continue }
                var depth = 0
                repeat {
                    if text[probe] == open { depth += 1 } else if text[probe] == close { depth -= 1 }
                    probe = text.index(after: probe)
                } while probe < text.endIndex && depth > 0
                index = probe
            }
            found.append(String(text[range.lowerBound..<index]))
            searchStart = range.upperBound
        }
        return found
    }

    private static func offenders(_ starts: [String]) -> [String] {
        starts.filter { !$0.contains("TimerSessionName.resolved(") }
    }

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Each call that starts with `opener` (which ends in "("), through its balanced closing parenthesis.
    private static func calls(of opener: String, in text: String) -> [String] {
        var found: [String] = []
        var searchStart = text.startIndex
        while let range = text.range(of: opener, range: searchStart..<text.endIndex) {
            var depth = 1
            var index = range.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "(" { depth += 1 } else if text[index] == ")" { depth -= 1 }
                index = text.index(after: index)
            }
            found.append(String(text[range.lowerBound..<index]))
            searchStart = range.upperBound
        }
        return found
    }
}
