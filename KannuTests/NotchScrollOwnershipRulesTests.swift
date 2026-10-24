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

/// A vertical scroll inside an open tab's content is that content's, never the notch's
/// swipe-to-close (docs/REGRESSIONS.md entry 21). The views are not in the logic target, so the
/// wiring is read from the source (the `TimerSideColumnRulesTests` idiom):
///
/// - every file of open-notch tab content that holds a vertical `ScrollView`, a `TextEditor` or a
///   `List` marks it `.ownsVerticalScroll()`; a popover is a window of its own and is exempt;
/// - the notch's scroll monitor ends a gesture under way *before* it checks the pointer is still
///   over the notch, and asks the owners before it counts a single delta;
/// - the close gesture clears its blur and dim before its guard, not after;
/// - an owner's view registers when it is made and unregisters when it goes.
///
/// Each detector has a planted-offender test, so a scanner that stops matching fails instead of
/// passing vacuously.
final class NotchScrollOwnershipRulesTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KannuTests/
        .deletingLastPathComponent()   // repo root
    /// The folders whose views are drawn inside the open notch's tabs.
    static let tabContentFolders = [
        "Kannu/components/Notch",
        "Kannu/components/AgentStatus",
        "Kannu/components/Extensions",
        "Kannu/components/Shelf",
        "Kannu/components/Timer",
    ]
    static let panGesturePath = "Kannu/extensions/PanGesture.swift"
    static let ownershipPath = "Kannu/extensions/VerticalScrollOwnership.swift"
    static let contentViewPath = "Kannu/ContentView.swift"

    private static func raw(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func swiftFiles(in folder: String) throws -> [String] {
        let url = repoRoot.appendingPathComponent(folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        return names.filter { $0.hasSuffix(".swift") }.sorted().map { "\(folder)/\($0)" }
    }

    // MARK: - The rules, on the real sources

    func testEveryTabScrollerOwnsItsVerticalScroll() throws {
        var problems: [String] = []
        var scanned = 0
        for folder in Self.tabContentFolders {
            for path in try Self.swiftFiles(in: folder) {
                let source = Self.code(try Self.raw(path))
                if !Self.verticalScrollers(in: source).isEmpty { scanned += 1 }
                problems += Self.ownershipProblems(in: source, path: path)
            }
        }
        XCTAssertEqual(problems, [])
        XCTAssertGreaterThanOrEqual(scanned, 4, "notes, agents, the timer column and the extension tab hold scrollers")
    }

    func testTheScrollMonitorEndsFirstAndAsksTheOwners() throws {
        XCTAssertEqual(Self.monitorProblems(in: Self.code(try Self.raw(Self.panGesturePath))), [])
    }

    func testTheCloseGestureClearsItsBlurBeforeItsGuard() throws {
        XCTAssertEqual(Self.closeGestureProblems(in: Self.code(try Self.raw(Self.contentViewPath))), [])
    }

    func testAnOwnerRegistersAndUnregisters() throws {
        let source = Self.code(try Self.raw(Self.ownershipPath))
        XCTAssertTrue(Self.body(of: "makeNSView", in: source)?.contains("VerticalScrollOwnership.owners.add(") ?? false)
        XCTAssertTrue(Self.body(of: "dismantleNSView", in: source)?.contains("VerticalScrollOwnership.owners.remove(") ?? false)
        XCTAssertTrue(source.contains("override func hitTest(_ point: NSPoint) -> NSView? { nil }"),
                      "the owner's view only measures: it must never take a click or a scroll")
    }

    // MARK: - The scanners catch planted offenders

    func testTheOwnershipScannerCatchesPlantedOffenders() {
        let owned = """
            struct NotesTab: View {
                var body: some View {
                    ScrollView { Text("a") }
                        .ownsVerticalScroll()
                }
            }
            """
        XCTAssertEqual(Self.ownershipProblems(in: owned, path: "a.swift"), [])
        let bare = owned.replacingOccurrences(of: ".ownsVerticalScroll()", with: ".padding()")
        XCTAssertEqual(Self.ownershipProblems(in: bare, path: "a.swift").count, 1)
        let editor = bare.replacingOccurrences(of: "ScrollView { Text(\"a\") }", with: "TextEditor(text: $t)")
        XCTAssertEqual(Self.ownershipProblems(in: editor, path: "a.swift").count, 1)
        let sideways = bare.replacingOccurrences(of: "ScrollView {", with: "ScrollView(.horizontal) {")
        XCTAssertEqual(Self.ownershipProblems(in: sideways, path: "a.swift"), [], "a sideways scroller is not the close gesture's")
        let popover = bare.replacingOccurrences(of: "struct NotesTab", with: "struct OutputPopover")
        XCTAssertEqual(Self.ownershipProblems(in: popover, path: "a.swift"), [], "a popover is a window of its own")
        XCTAssertEqual(Self.ownershipProblems(in: bare, path: "TimerPopover.swift"), [])
    }

    func testTheMonitorScannerCatchesPlantedOffenders() {
        let good = """
            private func handleScroll(_ event: NSEvent) {
                if ends && isUnderWay {
                    endGesture()
                    return
                }
                guard isCursorNearObservedView(using: event) else { return }
                if event.phase.contains(.began) || event.phase.contains(.mayBegin), isUnderWay {
                    endGesture()
                }
                if !direction.isHorizontal, let window = observedView?.window,
                   VerticalScrollOwnership.ownsScroll(at: screenPoint(of: event), in: window) {
                    return
                }
                let s = direction.signed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            }
            """
        XCTAssertEqual(Self.monitorProblems(in: good), [])
        let lateEnd = good
            .replacingOccurrences(of: "if ends && isUnderWay {\n        endGesture()\n        return\n    }\n", with: "")
            .replacingOccurrences(of: "let s = direction", with: "if ends && isUnderWay {\n endGesture()\n }\nlet s = direction")
        XCTAssertEqual(Self.monitorProblems(in: lateEnd).count, 1)
        let noOwners = good.replacingOccurrences(of: "VerticalScrollOwnership.ownsScroll(", with: "false && ownsScroll(")
        XCTAssertEqual(Self.monitorProblems(in: noOwners).count, 1)
        let noReset = good.replacingOccurrences(of: "event.phase.contains(.began)", with: "false")
        XCTAssertEqual(Self.monitorProblems(in: noReset).count, 1)
    }

    func testTheCloseGestureScannerCatchesPlantedOffenders() {
        let good = """
            private func handleCloseScrollGesture(translation: CGFloat, phase: NSEvent.Phase) {
                guard vm.notchState == .open else { return }
                guard phase != .ended, !vm.isScrollGestureActive else {
                    gestureProgress = .zero
                    return
                }
            }
            """
        XCTAssertEqual(Self.closeGestureProblems(in: good), [])
        let old = good.replacingOccurrences(of: "guard phase != .ended, !vm.isScrollGestureActive else {\n        gestureProgress = .zero\n        return\n    }",
                                            with: "guard !vm.isScrollGestureActive else { return }")
        XCTAssertEqual(Self.closeGestureProblems(in: old).count, 1)
        // The guard kept, its reset gone.
        let noClear = good.replacingOccurrences(of: "        gestureProgress = .zero\n", with: "")
        XCTAssertNotEqual(noClear, good, "the plant did not take")
        XCTAssertEqual(Self.closeGestureProblems(in: noClear).count, 1)
    }

    // MARK: - Scanners

    private static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
            }
            .joined(separator: "\n")
    }

    /// The lines that open a vertical scroller, each with the column-0 declaration it sits in.
    private static func verticalScrollers(in code: String) -> [(line: String, declaration: String)] {
        let opener = try! NSRegularExpression(
            pattern: #"ScrollView *\{|ScrollView\(\.vertical|ScrollView\(showsIndicators|TextEditor\(|(^|[^A-Za-z.])List *[\(\{]"#
        )
        let declaration = try! NSRegularExpression(
            pattern: #"^(?:private |fileprivate |public |internal )?(?:final )?(?:struct|class|enum|extension) +([A-Za-z0-9_]+)"#
        )
        var current = ""
        var found: [(String, String)] = []
        for line in code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = declaration.firstMatch(in: line, range: range), let name = Range(match.range(at: 1), in: line) {
                current = String(line[name])
            }
            if opener.firstMatch(in: line, range: range) != nil {
                found.append((line.trimmingCharacters(in: .whitespaces), current))
            }
        }
        return found
    }

    /// A file with a vertical scroller outside a popover applies `.ownsVerticalScroll()`.
    private static func ownershipProblems(in code: String, path: String) -> [String] {
        guard !path.contains("Popover") else { return [] }
        let scrollers = verticalScrollers(in: code).filter { !$0.declaration.contains("Popover") }
        guard !scrollers.isEmpty, !code.contains(".ownsVerticalScroll()") else { return [] }
        return ["\(path): \(scrollers[0].line) (in \(scrollers[0].declaration)) does not own its vertical scroll"]
    }

    private static func monitorProblems(in code: String) -> [String] {
        guard let handle = body(of: "handleScroll", in: code) else { return ["handleScroll not found"] }
        var problems: [String] = []
        let endFirst = handle.range(of: "if ends && isUnderWay {")
        let bounds = handle.range(of: "guard isCursorNearObservedView(using: event)")
        if let endFirst, let bounds, endFirst.lowerBound < bounds.lowerBound {} else {
            problems.append("a gesture under way is not ended before the bounds check")
        }
        let owners = handle.range(of: "VerticalScrollOwnership.ownsScroll(")
        let counting = handle.range(of: "direction.signed(deltaX:")
        if let owners, let counting, owners.lowerBound < counting.lowerBound {} else {
            problems.append("the owners are not asked before a delta is counted")
        }
        if !handle.contains("event.phase.contains(.began)") {
            problems.append("a new gesture does not start from nothing")
        }
        return problems
    }

    private static func closeGestureProblems(in code: String) -> [String] {
        guard let handle = body(of: "handleCloseScrollGesture", in: code) else { return ["handleCloseScrollGesture not found"] }
        // The guard, and in its else the blur cleared before the return: a guard that only returns
        // leaves the notch blurred at the gesture's end.
        guard let guardLine = handle.range(of: "guard phase != .ended, !vm.isScrollGestureActive else {"),
              let exit = handle.range(of: "return", range: guardLine.upperBound..<handle.endIndex),
              handle.range(of: "gestureProgress = .zero", range: guardLine.upperBound..<exit.lowerBound) != nil
        else { return ["the close gesture's end and guard do not clear its blur"] }
        return []
    }

    /// The body of the first `func name(` through its matching brace.
    private static func body(of name: String, in code: String) -> String? {
        guard let start = code.range(of: "func \(name)("),
              let open = code.range(of: "{", range: start.upperBound..<code.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < code.endIndex {
            switch code[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(code[start.lowerBound...index]) }
            default: break
            }
            index = code.index(after: index)
        }
        return nil
    }
}
