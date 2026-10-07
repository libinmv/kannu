//
//  TimerComposerMetricsTests.swift
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

/// The timer tab's composer fits the notch as it is: the notch must not grow for the timer tab (it
/// looked like a glitch), so the composer is sized to the tab's smallest budget instead.
final class TimerComposerMetricsTests: XCTestCase {
    typealias M = TimerComposerMetrics

    func testEveryStyleFitsTheSmallestBudget() {
        for style in M.Style.allCases {
            XCTAssertLessThanOrEqual(M.totalHeight(style), M.minimumTabBudget - M.bottomClearance, "\(style)")
        }
    }

    func testTheButtonsStayComfortablyClickable() {
        XCTAssertGreaterThanOrEqual(M.buttonHeight, 24)
        XCTAssertGreaterThanOrEqual(M.rulerButtonHeight, 24)
        XCTAssertGreaterThanOrEqual(M.nameFieldHeight, 22)
        XCTAssertGreaterThanOrEqual(M.fieldBoxHeight, 30)
    }

    /// The side column with both pages, in the smallest budget: its labels, at least one task row
    /// and "All tasks ›" fit, so the notch never has to grow for them.
    func testTheSideColumnFitsTheSmallestBudget() {
        let page = M.sidePageHeight(budget: M.minimumTabBudget, hasHeader: true)
        let rows = M.sideTaskListHeight(pageHeight: page)
        XCTAssertGreaterThanOrEqual(rows, M.sideTaskRowsHeight(count: 1), "not even one task row fits")
        let column = M.sideColumnInset + M.sideHeaderHeight + M.sideHeaderSpacing
            + M.sideTaskRowsHeight(count: 1) + M.sideLinkSpacing + M.sideLinkHeight
        XCTAssertLessThanOrEqual(column, M.minimumTabBudget)
        XCTAssertEqual(page + M.sideColumnInset + M.sideHeaderHeight + M.sideHeaderSpacing, M.minimumTabBudget)
    }

    func testWithOnePageTheColumnKeepsItsOldHeight() {
        // No labels: the page has exactly the room the preset list always had (budget less 16).
        XCTAssertEqual(M.sidePageHeight(budget: M.minimumTabBudget, hasHeader: false), M.minimumTabBudget - 16)
        XCTAssertEqual(M.sideColumnWidth, 210)
    }

    func testTheSideColumnHeightsNeverGoNegative() {
        XCTAssertEqual(M.sidePageHeight(budget: 10, hasHeader: true), 0)
        XCTAssertEqual(M.sideTaskListHeight(pageHeight: 5), 0)
        XCTAssertEqual(M.sideTaskRowsHeight(count: -1), 0)
        XCTAssertEqual(M.sideTaskRowsHeight(count: 2), 2 * (M.sideTaskRowHeight + M.sideRowSpacing))
    }

    func testTheSideRowsStayReadable() {
        XCTAssertGreaterThanOrEqual(M.sideTaskRowHeight, 32, "two lines of text and a ▶ need the room")
        XCTAssertGreaterThanOrEqual(M.sideHeaderHeight, 14)
        XCTAssertGreaterThanOrEqual(M.sideLinkHeight, 14)
    }

    /// With a single task, the list still has room under the row for its ▶ tooltip, which opens
    /// below inside a ScrollView that clips (docs/TOOLTIPS.md rule 2): the bubble reaches about
    /// 13 pt past the row, and the bottom fade is 16 pt. Checked at the smallest budget, both pages.
    func testOneTaskLeavesRoomForItsTooltip() {
        XCTAssertGreaterThanOrEqual(M.sideTaskMinimumRows, 2)
        let page = M.sidePageHeight(budget: M.minimumTabBudget, hasHeader: true)
        let list = min(M.sideTaskListHeight(pageHeight: page), M.sideTaskRowsHeight(count: M.sideTaskMinimumRows))
        let bubbleOverflow: CGFloat = 13
        let bottomFade: CGFloat = 16
        XCTAssertGreaterThanOrEqual(list, M.sideRowSpacing / 2 + M.sideTaskRowHeight + bubbleOverflow + bottomFade)
    }

    func testTheRulerPointerSitsInsideItsArea() {
        XCTAssertLessThanOrEqual(M.rulerPointerOffset + 12, M.rulerAreaHeight)
        XCTAssertLessThanOrEqual(M.rulerCanvasHeight, M.rulerAreaHeight)
    }
}
