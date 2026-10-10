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

    /// The list fills the column, the whole budget tall less its bottom inset (no labels on top,
    /// no link under it), and at the smallest budget that is still at least two task rows.
    func testTheListAreaAndItsInsetFitTheSmallestBudget() {
        let page = M.sidePageHeight(budget: M.minimumTabBudget)
        XCTAssertEqual(page + M.sideBottomInset, M.minimumTabBudget)
        XCTAssertGreaterThanOrEqual(page, M.sideTaskRowsHeight(count: 2), "two task rows do not fit")
        XCTAssertGreaterThan(M.sideBottomInset, 0, "the list would touch the labels' line")
    }

    /// The "Tasks · Presets" labels hang wholly below the tab's bottom line (an overlay, so the tab
    /// does not grow), and wholly inside the painted footer, at least 4 pt clear of its edge.
    func testThePagerFitsTheVisibleFooter() {
        XCTAssertEqual(M.visibleFooterHeight, 18, "the footer arithmetic changed: re-check the offset")
        XCTAssertGreaterThanOrEqual(M.sidePagerFooterOffset, M.sidePagerHeight, "the labels overlap the content")
        XCTAssertGreaterThanOrEqual(M.visibleFooterHeight - M.sidePagerFooterOffset, 4, "the labels touch the notch's edge")
        XCTAssertGreaterThanOrEqual(M.sidePagerHeight, 14, "11 pt labels need the room")
    }

    /// The page swipe's area reaches down past the labels (they are the swipe's only visible cue),
    /// and no further than the notch's painted bottom edge.
    func testTheSwipeAreaHoldsTheWholeLabelRow() {
        let reach = M.tabVerticalPadding + M.pageSwipeFooterReach
        XCTAssertGreaterThanOrEqual(reach, M.sidePagerFooterOffset, "the labels' lower part misses the swipe")
        XCTAssertLessThanOrEqual(reach, M.visibleFooterHeight, "the swipe reaches below the notch")
    }

    /// The 240 pt column beside the stacked composer fits the narrowest open notch (640 pt), with
    /// the composer at its full width: the fields are never shrunk to make room.
    func testTheWiderColumnAndTheComposerFitTheSmallestNotch() {
        XCTAssertEqual(M.sideColumnWidth, 240)
        let composer = M.composerWidthBesideSideColumn(notchWidth: M.smallestOpenNotchWidth)
        XCTAssertGreaterThanOrEqual(composer, M.stackedComposerMinimumWidth)
        // Three 64 pt fields, two 14 pt colons, four 8 pt gaps, and 6 pt padding each side.
        let expected: CGFloat = 192 + 28 + 32 + 12
        XCTAssertEqual(M.stackedComposerMinimumWidth, expected)
    }

    func testTheSideColumnHeightsNeverGoNegative() {
        XCTAssertEqual(M.sidePageHeight(budget: 2), 0)
        XCTAssertEqual(M.sideTaskRowsHeight(count: -1), 0)
        XCTAssertEqual(M.sideTaskRowsHeight(count: 2), 2 * (M.sideTaskRowHeight + M.sideRowSpacing))
    }

    func testTheSideRowsStayReadable() {
        XCTAssertGreaterThanOrEqual(M.sideTaskRowHeight, 32, "two lines of text and a ▶ need the room")
    }

    /// With a single task, the list still has room under the row for its ▶ tooltip, which opens
    /// below inside a ScrollView that clips (docs/TOOLTIPS.md rule 2): the bubble reaches about
    /// 13 pt past the row, and the bottom fade is 16 pt. Checked at the smallest budget.
    func testOneTaskLeavesRoomForItsTooltip() {
        XCTAssertGreaterThanOrEqual(M.sideTaskMinimumRows, 2)
        let page = M.sidePageHeight(budget: M.minimumTabBudget)
        let list = min(page, M.sideTaskRowsHeight(count: M.sideTaskMinimumRows))
        let bubbleOverflow: CGFloat = 13
        let bottomFade: CGFloat = 16
        XCTAssertGreaterThanOrEqual(list, M.sideRowSpacing / 2 + M.sideTaskRowHeight + bubbleOverflow + bottomFade)
    }

    func testTheRulerPointerSitsInsideItsArea() {
        XCTAssertLessThanOrEqual(M.rulerPointerOffset + 12, M.rulerAreaHeight)
        XCTAssertLessThanOrEqual(M.rulerCanvasHeight, M.rulerAreaHeight)
    }
}
