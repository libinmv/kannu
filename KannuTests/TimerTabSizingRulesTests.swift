//
//  TimerTabSizingRulesTests.swift
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

/// The open notch's timer tab is sized in four places: the window (`KannuApp`), the view model
/// (`KannuViewModel`), the SwiftUI frame (`ContentView`) and the tab's own budget
/// (`NotchTimerView`). They disagreed — 250, 200 and a budget derived from the stale 200 — and the
/// composer's Start/Reset row was cut off once the session name field sat above it. All four now
/// read `timerTabOpenNotchHeight`; the sizing file is not in the logic target, so this reads source.
final class TimerTabSizingRulesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let sites = [
        "Kannu/ContentView.swift",
        "Kannu/KannuApp.swift",
        "Kannu/models/KannuViewModel.swift",
        "Kannu/components/Notch/NotchTimerView.swift",
    ]

    /// The tallest composer measured with the session name field: the ruler style (177 pt); the
    /// manual style with presets is 175 pt.
    private static let tallestComposer: CGFloat = 177
    /// The largest header the tab subtracts (a tall custom closed-notch height), and the tab's
    /// fixed vertical allowance (`maxTabContentHeight`'s 36).
    private static let tallestHeader: CGFloat = 38
    private static let verticalAllowance: CGFloat = 36

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func constant(_ name: String, in text: String) -> CGFloat? {
        guard let range = text.range(of: "let \(name): CGFloat = ([0-9.]+)", options: .regularExpression) else { return nil }
        return CGFloat(Double(text[range].split(separator: "=").last!.trimmingCharacters(in: .whitespaces)) ?? -1)
    }

    func testEverySiteReadsTheSharedHeight() throws {
        var files: [String: String] = [:]
        for path in Self.sites { files[path] = try Self.source(path) }
        XCTAssertEqual(Self.problems(files), [])
    }

    func testTheComposerFitsWithItsPadding() throws {
        let sizing = try Self.source("Kannu/sizing/matters.swift")
        let height = try XCTUnwrap(Self.constant("timerTabOpenNotchHeight", in: sizing))
        let padding = try XCTUnwrap(Self.constant("timerTabComposerBottomPadding", in: sizing))
        XCTAssertGreaterThan(padding, 2, "space below the buttons")
        let budget = height - Self.tallestHeader - Self.verticalAllowance - padding
        XCTAssertGreaterThanOrEqual(budget, Self.tallestComposer, "the Start/Reset row must not be cut off")
    }

    func testTheScannerCatchesPlantedOffenders() {
        let good = [
            "Kannu/ContentView.swift": "return CGSize(width: baseSize.width, height: timerTabOpenNotchHeight)",
            "Kannu/KannuApp.swift": "baseSize.height = timerTabOpenNotchHeight",
            "Kannu/models/KannuViewModel.swift": "if coordinator.currentView == .timer { adjustedSize.height = timerTabOpenNotchHeight }",
            "Kannu/components/Notch/NotchTimerView.swift": """
                private var maxTabContentHeight: CGFloat {
                    let available = timerTabOpenNotchHeight - headerHeight - 36
                    return max(130, available)
                }
                """,
        ]
        XCTAssertEqual(Self.problems(good), [])
        var bare = good
        bare["Kannu/KannuApp.swift"] = "baseSize.height = 250 // Extra space for timer presets"
        XCTAssertEqual(Self.problems(bare).count, 1, "a bare height instead of the shared one")
        var stale = good
        stale["Kannu/components/Notch/NotchTimerView.swift"] = """
            private var maxTabContentHeight: CGFloat {
                let available = vm.notchSize.height - headerHeight - 36
                return max(130, available)
            }
            """
        XCTAssertEqual(Self.problems(stale).count, 1, "the budget from the view model's stale size")
    }

    private static func problems(_ files: [String: String]) -> [String] {
        var problems: [String] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            if !path.hasSuffix("NotchTimerView.swift"), !text.contains("timerTabOpenNotchHeight") {
                problems.append("\(path) does not read timerTabOpenNotchHeight")
            }
            if path.hasSuffix("NotchTimerView.swift") {
                let budget = text.range(of: "private var maxTabContentHeight").map { String(text[$0.lowerBound...].prefix(300)) } ?? ""
                if !budget.contains("timerTabOpenNotchHeight") || budget.contains("vm.notchSize") {
                    problems.append("\(path): maxTabContentHeight must use timerTabOpenNotchHeight, not vm.notchSize")
                }
            }
        }
        return problems
    }
}
