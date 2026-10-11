//
//  NotchTeardownRulesTests.swift
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

/// A window rebuild (display or resolution change) drops the notch's views and reuses the single
/// `KannuViewModel`. The views that held a scroll-gesture or auto-close suppression token, or set a
/// popover flag, get no reliable `.onDisappear` on a borderless panel, so that state would outlive
/// them: a notch that never auto-closes and never scrolls until the next explicit close. The
/// teardown must therefore call `resetTransientInteractionState()`, and the reset must clear every
/// flag `ContentView.hasAnyActivePopovers()` reads. Neither is testable at runtime in this
/// logic-only target, so both are pinned in the source, the way `LaunchGateRulesTests` pins the gate.
final class NotchTeardownRulesTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testTheWindowRebuildResetsTheReusedViewModel() throws {
        let app = try Self.source("Kannu/KannuApp.swift")
        let teardown = try XCTUnwrap(Self.body(ofFunction: "tearDownAllWindows", in: app),
                                     "tearDownAllWindows went away — move this pin to whatever rebuilds the notch window")
        XCTAssertTrue(Self.code(teardown).contains("vm.resetTransientInteractionState()"),
                      "tearDownAllWindows reuses `vm` for the next window without clearing the suppression tokens and popover flags the torn-down views left behind")
    }

    func testTheResetClearsBothSuppressionTokenSets() throws {
        let reset = try Self.resetBody()
        XCTAssertTrue(reset.contains("resetScrollGestureSuppression()"),
                      "the reset leaves scroll-gesture suppression tokens behind; the rebuilt notch never scrolls")
        XCTAssertTrue(reset.contains("resetAutoCloseSuppression()"),
                      "the reset leaves auto-close suppression tokens behind; the rebuilt notch never auto-closes")
    }

    /// Both files are scanned, so a popover flag added to one without the other fails here.
    func testTheResetClearsEveryFlagThePopoverCheckReads() throws {
        let contentView = try Self.source("Kannu/ContentView.swift")
        let viewModel = try Self.source("Kannu/models/KannuViewModel.swift")
        let check = try XCTUnwrap(Self.body(ofFunction: "hasAnyActivePopovers", in: contentView),
                                  "hasAnyActivePopovers went away — point this pin at whatever shouldPreventAutoClose reads now")
        let read = Self.popoverFlags(matching: #"vm\.(is[A-Za-z]+PopoverActive)"#, in: Self.code(check))
        let cleared = Self.popoverFlags(matching: #"\b(is[A-Za-z]+PopoverActive)\s*=\s*false"#, in: try Self.resetBody())
        let declared = Self.popoverFlags(matching: Self.declaredFlagPattern, in: Self.code(viewModel))

        XCTAssertGreaterThanOrEqual(read.count, 6, "the scanner stopped seeing the popover flags; fix the scan, not the rule")
        XCTAssertEqual(read.subtracting(cleared), [],
                       "hasAnyActivePopovers reads flags resetTransientInteractionState never clears — a rebuild with that popover open never auto-closes")
        XCTAssertEqual(cleared.subtracting(read), [],
                       "resetTransientInteractionState clears flags hasAnyActivePopovers does not read — either wire the flag into the check or drop it from the reset")
        XCTAssertEqual(declared.subtracting(read), [],
                       "KannuViewModel declares popover flags hasAnyActivePopovers does not read — a popover that cannot hold the notch open")
    }

    // MARK: - The scanner is not vacuous

    func testTheScannerSeesAPlantedOffender() throws {
        let plantedTeardown = """
            private func tearDownAllWindows() {
                for id in windows.keys { tearDownWindow(forDisplay: id) }
                if let window {
                    vm.onViewTeardown?()
                    // vm.resetTransientInteractionState()
                    window.close()
                }
            }

            func syncPointerTracking() {}
            """
        let teardown = try XCTUnwrap(Self.body(ofFunction: "tearDownAllWindows", in: plantedTeardown))
        XCTAssertTrue(teardown.contains("window.close()"), "the body scan stopped before the end of the function")
        XCTAssertFalse(teardown.contains("syncPointerTracking"), "the body scan ran past the end of the function")
        XCTAssertFalse(Self.code(teardown).contains("vm.resetTransientInteractionState()"),
                       "a commented-out call must not satisfy the pin")

        let plantedReset = """
            func resetTransientInteractionState() {
                resetScrollGestureSuppression()
                isBatteryPopoverActive = false
                isTimerPopoverActive=false
            }
            """
        let plantedCheck = """
            private func hasAnyActivePopovers() -> Bool {
             return vm.isBatteryPopoverActive ||
                 vm.isTimerPopoverActive ||
                 vm.isClipboardPopoverActive
            }
            """
        let cleared = Self.popoverFlags(matching: #"\b(is[A-Za-z]+PopoverActive)\s*=\s*false"#,
                                        in: try XCTUnwrap(Self.body(ofFunction: "resetTransientInteractionState", in: plantedReset)))
        let read = Self.popoverFlags(matching: #"vm\.(is[A-Za-z]+PopoverActive)"#,
                                     in: try XCTUnwrap(Self.body(ofFunction: "hasAnyActivePopovers", in: plantedCheck)))
        XCTAssertEqual(cleared, ["isBatteryPopoverActive", "isTimerPopoverActive"], "the assignment scan misses a flag or invents one")
        XCTAssertEqual(read.subtracting(cleared), ["isClipboardPopoverActive"], "a flag read but never cleared must surface")

        // Every spelling a flag declaration takes in KannuViewModel, including the `private(set)`
        // idiom `isAutoCloseSuppressed` and `notchState` already use. A flag declared that way must
        // not slip past the "declared but never read" check.
        let plantedDeclarations = """
            @Published var isBatteryPopoverActive: Bool = false
            @Published private(set) var isStatsPopoverActive: Bool = false
            @Published public private(set) var isTimerPopoverActive = false
            @Published internal var isClipboardPopoverActive: Bool = false
            @Published var isPopoverActiveCount: Int = 0
            var isColorPickerPopoverActive: Bool = false
            """
        XCTAssertEqual(Self.popoverFlags(matching: Self.declaredFlagPattern, in: plantedDeclarations),
                       ["isBatteryPopoverActive", "isStatsPopoverActive", "isTimerPopoverActive", "isClipboardPopoverActive"],
                       "the declaration scan misses an access-modifier spelling or counts a non-@Published property")
    }

    // MARK: - Helpers

    /// A `@Published` popover flag declaration, with or without access modifiers between the
    /// wrapper and `var` (`private(set)`, `public private(set)`, `internal`, ...).
    static let declaredFlagPattern =
        #"@Published(?:\s+(?:open|public|internal|fileprivate|private)(?:\(set\))?)*\s+var\s+(is[A-Za-z]+PopoverActive)\b"#

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func resetBody() throws -> String {
        let viewModel = try source("Kannu/models/KannuViewModel.swift")
        return Self.code(try XCTUnwrap(body(ofFunction: "resetTransientInteractionState", in: viewModel),
                                       "KannuViewModel.resetTransientInteractionState went away — the rebuild path has nothing to call"))
    }

    /// A function's body by brace matching: from the opening brace after its signature to the
    /// brace that closes it. Nested blocks (loops, `if let`) are part of the body.
    static func body(ofFunction name: String, in text: String) -> String? {
        guard let start = text.range(of: "func \(name)("),
              let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Source with comment lines dropped, so prose about a rule never trips it.
    static func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
        }.joined(separator: "\n") + "\n"
    }

    /// The first capture group of every match of `pattern`, as a set of flag names.
    static func popoverFlags(matching pattern: String, in text: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        })
    }
}
