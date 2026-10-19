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

    /// David: the list's bottom lines up with Start and Reset. The page is the composer's own
    /// height (name field included) at every budget, never past the budget less its inset, and
    /// holds three task rows beside the stacked composer.
    func testThePageEndsWhereTheComposerDoes() {
        for style in [M.Style.manualWithPresets, .ruler] {
            for budget: CGFloat in [M.minimumTabBudget, 160, 200] {
                let page = M.sidePageHeight(budget: budget, style: style)
                XCTAssertEqual(page, M.totalHeight(style), "\(style) at \(budget)")
                XCTAssertLessThanOrEqual(page + M.sideBottomInset, max(budget, M.minimumTabBudget))
            }
        }
        XCTAssertGreaterThanOrEqual(M.sidePageHeight(budget: M.minimumTabBudget, style: .manualWithPresets),
                                    M.sideTaskRowsHeight(count: 3), "three task rows beside the stacked composer")
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

    /// David: "golden ratio is the goal". The composer and the side column split the tab's width
    /// in the golden ratio around the 41 pt gap, at every notch width, in whole points, and the
    /// stacked composer always keeps its full width: the fields are never shrunk.
    func testTheColumnsSplitInTheGoldenRatio() {
        XCTAssertEqual(M.columnGap, 41)
        for notch: CGFloat in [M.smallestOpenNotchWidth, 675, 690, 770, 1000] {
            let content = M.tabContentWidth(notchWidth: notch)
            let column = M.sideColumnWidth(notchWidth: notch)
            let composer = M.composerWidthBesideSideColumn(notchWidth: notch)
            XCTAssertEqual(composer + column + M.columnGap, content, "\(notch)")
            XCTAssertEqual(column, column.rounded(), "whole points at \(notch)")
            XCTAssertEqual(composer / column, M.goldenRatio, accuracy: 0.01, "\(notch)")
            XCTAssertGreaterThanOrEqual(composer, M.stackedComposerMinimumWidth, "\(notch)")
        }
        XCTAssertEqual(M.sideColumnWidth(notchWidth: M.smallestOpenNotchWidth), 202)
        XCTAssertEqual(M.sideColumnWidth(notchWidth: 675), 215)
        // Three 64 pt fields, two 14 pt colons, four 8 pt gaps, and 6 pt padding each side.
        let expected: CGFloat = 192 + 28 + 32 + 12
        XCTAssertEqual(M.stackedComposerMinimumWidth, expected)
    }

    /// Below the standard notch widths the column keeps two usable fact columns on a card.
    func testTheColumnFloorHolds() {
        XCTAssertEqual(M.sideColumnWidth(notchWidth: 420), M.minimumSideColumnWidth)
        XCTAssertGreaterThanOrEqual(M.minimumSideColumnWidth, 200)
    }

    func testTheGoldenSplitAddsUp() {
        let split = M.goldenSplit(327, spacing: 8)
        XCTAssertEqual(split.minor + split.major + 8, 327)
        XCTAssertEqual(split.major / split.minor, M.goldenRatio, accuracy: 0.02)
        XCTAssertEqual(split.minor, split.minor.rounded(), "whole points")
        XCTAssertEqual(M.goldenSplit(4, spacing: 8).minor, 0, "never negative")
        XCTAssertEqual(M.goldenSplit(4, spacing: 8).major, 0)
    }

    func testTheSideColumnHeightsNeverGoNegative() {
        XCTAssertEqual(M.sidePageHeight(budget: 2, style: .manualWithPresets), 0)
        XCTAssertEqual(M.sideTaskRowsHeight(count: -1), 0)
        XCTAssertEqual(M.sideTaskRowsHeight(count: 2), 2 * (M.sideTaskRowHeight + M.sideRowSpacing))
    }

    /// The Tasks page's toolbar lines up with the session name field across the tab: the same
    /// height, and the same gap to what comes under it.
    func testTheSearchFieldIsLevelWithTheNameField() {
        XCTAssertEqual(M.sideToolbarHeight, M.nameFieldHeight)
        XCTAssertEqual(M.sideToolbarSpacing, M.nameFieldSpacing)
    }

    /// Under the search field, at the smallest budget, the list still holds two whole rows (the
    /// first row's ▶ tooltip needs the second's room).
    func testTheListUnderTheSearchFieldHoldsTwoRows() {
        let page = M.sidePageHeight(budget: M.minimumTabBudget, style: .manualWithPresets)
        let list = M.sideListHeight(pageHeight: page)
        XCTAssertEqual(list, page - M.sideToolbarHeight - M.sideToolbarSpacing)
        XCTAssertGreaterThanOrEqual(list, M.sideTaskRowsHeight(count: 2), "two task rows do not fit under the search field")
        XCTAssertEqual(M.sideListHeight(pageHeight: 10), 0, "never negative")
    }

    /// David: the icons go vertically between the two sides of the tab, smaller. The rail sits in
    /// the 41 pt gap centred on the divider's line, clear of both columns; its first icon is
    /// centred on the session name field; all four slots fit the page beside the stacked composer.
    func testTheRailFitsTheGap() {
        XCTAssertEqual(M.railOffset - M.railButtonSize / 2, M.tabColumnSpacing + M.dividerWidth / 2, "centred on the divider's line")
        XCTAssertGreaterThanOrEqual(M.railOffset - M.railButtonSize, 8, "clear of the task column")
        XCTAssertGreaterThanOrEqual(M.columnGap - M.railOffset, 8, "clear of the composer")
        XCTAssertLessThan(M.railButtonSize, M.nameFieldHeight, "smaller than the name field's own button")
        XCTAssertEqual(M.railSlotHeight, M.nameFieldHeight, "the first icon is centred on the name field")
        let page = M.sidePageHeight(budget: M.minimumTabBudget, style: .manualWithPresets)
        XCTAssertLessThanOrEqual(4 * M.railSlotHeight + 4 * M.railSpacing, page, "search, filter, Refresh and the clock, then the hairline")
    }

    /// The task form takes the composer's place exactly: the same height, so nothing around it
    /// moves when they swap, and inside the smallest budget.
    func testTheTaskFormFitsTheComposersFrame() {
        XCTAssertEqual(M.taskFormHeight, M.nameFieldHeight + 2 * M.taskFormRowHeight + M.buttonHeight + 3 * M.taskFormRowSpacing)
        XCTAssertEqual(M.taskFormHeight, M.totalHeight(.manualWithPresets))
        XCTAssertLessThanOrEqual(M.taskFormHeight, M.minimumTabBudget - M.bottomClearance)
        XCTAssertGreaterThanOrEqual(M.taskFormRowHeight, 22, "a field row stays comfortably clickable")
    }

    /// Beside the New task button the session name field keeps room for its prompt at the
    /// narrowest notch: the composer's width less the button and its gap.
    func testTheNameFieldKeepsItsRoomBesideTheNewTaskButton() {
        XCTAssertEqual(M.newTaskButtonSize, M.nameFieldHeight, "a square as tall as the field")
        let field = M.composerWidthBesideSideColumn(notchWidth: M.smallestOpenNotchWidth) - M.nameFieldSpacing - M.newTaskButtonSize
        XCTAssertGreaterThanOrEqual(field, 240, "\"Do you want to name this session?\" at 12 pt needs about 210 pt and its padding")
    }

    func testTheSideRowsStayReadable() {
        XCTAssertGreaterThanOrEqual(M.sideTaskRowHeight, 32, "two lines of text and a ▶ need the room")
    }

    /// With a single task, the list still has room under the row for its ▶ tooltip, which opens
    /// below inside a ScrollView that clips (docs/TOOLTIPS.md rule 2): the bubble reaches about
    /// 13 pt past the row, and the bottom fade is 16 pt. Checked at the smallest budget.
    func testOneTaskLeavesRoomForItsTooltip() {
        XCTAssertGreaterThanOrEqual(M.sideTaskMinimumRows, 2)
        let page = M.sideListHeight(pageHeight: M.sidePageHeight(budget: M.minimumTabBudget, style: .manualWithPresets))
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
