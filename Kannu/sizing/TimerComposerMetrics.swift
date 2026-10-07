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

import CoreGraphics

/// Every vertical size of the open notch's timer composer (the session name field, the duration
/// fields or the ruler, and Start/Reset), so its total height is known and fits the timer tab
/// without the notch growing. The tab's budget is the notch's height less the header and 36 pt,
/// never under `minimumTabBudget`. Raising the notch for the timer tab instead looked like a glitch:
/// the notch jumped in size when you switched to it.
enum TimerComposerMetrics {
    /// `NotchTimerView.maxTabContentHeight`'s floor.
    static let minimumTabBudget: CGFloat = 130
    /// Room kept free under the composer inside the budget.
    static let bottomClearance: CGFloat = 4

    static let nameFieldHeight: CGFloat = 24
    static let nameFieldSpacing: CGFloat = 6

    static let composerPadding: CGFloat = 6
    static let rowSpacing: CGFloat = 6

    static let fieldBoxHeight: CGFloat = 34
    static let fieldDigitSize: CGFloat = 22
    static let captionGap: CGFloat = 2
    static let captionHeight: CGFloat = 12

    static let buttonHeight: CGFloat = 26
    static let buttonFontSize: CGFloat = 13
    static let buttonColumnSpacing: CGFloat = 6

    static let rulerAreaHeight: CGFloat = 46
    static let rulerCanvasHeight: CGFloat = 36
    static let rulerPointerOffset: CGFloat = 32
    static let rulerControlTopPadding: CGFloat = 6
    static let rulerButtonHeight: CGFloat = 28
    static let rulerReadoutHeight: CGFloat = 30
    static let rulerReadoutFontSize: CGFloat = 26

    // The side column beside the composer (`TimerSideColumn`): "Tasks · Presets" over one page.
    static let sideColumnWidth: CGFloat = 210
    /// Room the column leaves under itself inside the budget.
    static let sideColumnInset: CGFloat = 16
    /// The "Tasks · Presets" labels, shown only when both pages exist.
    static let sideHeaderHeight: CGFloat = 16
    static let sideHeaderSpacing: CGFloat = 6
    /// One task row: key and title on one line, "42m of 2h" under it, and ▶.
    static let sideTaskRowHeight: CGFloat = 36
    static let sideRowSpacing: CGFloat = 4
    /// The Tasks list is never shorter than this many rows (room permitting): the first row's ▶
    /// tooltip opens below it, and a list clipped to one row would swallow the bubble.
    static let sideTaskMinimumRows = 2
    /// The "All tasks ›" link under the rows.
    static let sideLinkHeight: CGFloat = 16
    static let sideLinkSpacing: CGFloat = 4

    /// The height left for the shown page: the tab's budget less the inset and, with both pages,
    /// the labels.
    static func sidePageHeight(budget: CGFloat, hasHeader: Bool) -> CGFloat {
        let header = hasHeader ? sideHeaderHeight + sideHeaderSpacing : 0
        return max(0, budget - sideColumnInset - header)
    }

    /// The Tasks page's rows: the page less the All tasks link.
    static func sideTaskListHeight(pageHeight: CGFloat) -> CGFloat {
        max(0, pageHeight - sideLinkSpacing - sideLinkHeight)
    }

    /// Every row's height plus the spacing around it, so a short list ends where its last row does.
    static func sideTaskRowsHeight(count: Int) -> CGFloat {
        CGFloat(max(0, count)) * (sideTaskRowHeight + sideRowSpacing)
    }

    /// `.manualWithPresets` is the stacked layout used whenever the side column shows (presets on,
    /// or the Tasks page available); `.manualWithoutPresets` is the wide one, with no column.
    enum Style: CaseIterable { case manualWithPresets, manualWithoutPresets, ruler }

    static var durationFieldHeight: CGFloat { fieldBoxHeight + captionGap + captionHeight }

    /// The composer's height, padding included.
    static func composerHeight(_ style: Style) -> CGFloat {
        let content: CGFloat
        switch style {
        case .manualWithPresets:
            content = durationFieldHeight + rowSpacing + buttonHeight
        case .manualWithoutPresets:
            content = max(durationFieldHeight, buttonHeight * 2 + buttonColumnSpacing)
        case .ruler:
            content = rulerAreaHeight + rulerControlTopPadding + max(rulerButtonHeight, rulerReadoutHeight)
        }
        return content + composerPadding * 2
    }

    /// The name field, its spacing and the composer: what the tab must hold before a timer runs.
    static func totalHeight(_ style: Style) -> CGFloat {
        nameFieldHeight + nameFieldSpacing + composerHeight(style)
    }
}
