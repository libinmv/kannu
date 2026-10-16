//
//  TimerComposerMetricsRulesTests.swift
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

/// The views are not in the logic target, so this reads their source: the composer's sizes come
/// from `TimerComposerMetrics` (so the budget test means something), and nothing makes the notch
/// taller for the timer tab.
final class TimerComposerMetricsRulesTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheComposerIsSizedByTheMetrics() throws {
        let notch = try Self.source("Kannu/components/Notch/NotchTimerView.swift")
        let ruler = try Self.source("Kannu/components/Timer/RulerTimerPicker.swift")
        XCTAssertEqual(Self.problems(notch: notch, ruler: ruler), [])
    }

    func testTheNotchDoesNotGrowForTheTimerTab() throws {
        let viewModel = try Self.source("Kannu/models/KannuViewModel.swift")
        XCTAssertFalse(viewModel.contains("currentView == .timer"), "the view model must not give the timer tab its own height")
        for path in ["Kannu/ContentView.swift", "Kannu/KannuApp.swift", "Kannu/components/Notch/NotchTimerView.swift"] {
            XCTAssertFalse(try Self.source(path).contains("timerTabOpenNotchHeight"), path)
        }
    }

    func testTheScannerCatchesPlantedOffenders() {
        let notch = """
            .frame(height: TimerComposerMetrics.nameFieldHeight)
            .frame(width: width, height: TimerComposerMetrics.fieldBoxHeight)
            .frame(height: TimerComposerMetrics.buttonHeight)
            .padding(TimerComposerMetrics.composerPadding)
            """
        let ruler = """
            .frame(height: TimerComposerMetrics.rulerAreaHeight)
            .frame(height: TimerComposerMetrics.rulerButtonHeight)
            """
        XCTAssertEqual(Self.problems(notch: notch, ruler: ruler), [])
        XCTAssertEqual(Self.problems(notch: notch.replacingOccurrences(of: "TimerComposerMetrics.fieldBoxHeight", with: "46"), ruler: ruler).count, 1)
        XCTAssertEqual(Self.problems(notch: notch, ruler: ruler.replacingOccurrences(of: "TimerComposerMetrics.rulerAreaHeight", with: "62")).count, 1)
    }

    private static func problems(notch: String, ruler: String) -> [String] {
        var problems: [String] = []
        for needle in ["TimerComposerMetrics.nameFieldHeight", "TimerComposerMetrics.fieldBoxHeight",
                       "TimerComposerMetrics.buttonHeight", "TimerComposerMetrics.composerPadding"]
        where !notch.contains(needle) {
            problems.append("NotchTimerView does not use \(needle)")
        }
        for needle in ["TimerComposerMetrics.rulerAreaHeight", "TimerComposerMetrics.rulerButtonHeight"] where !ruler.contains(needle) {
            problems.append("RulerTimerPicker does not use \(needle)")
        }
        return problems
    }
}
