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

    // The tab's own layout (`NotchTimerView`): composer, divider and side column in one row.
    /// The tab's padding, inside the open notch.
    static let tabHorizontalPadding: CGFloat = 16
    static let tabVerticalPadding: CGFloat = 6
    /// The room between the composer, the divider and the side column.
    static let tabColumnSpacing: CGFloat = 20
    static let dividerWidth: CGFloat = 1

    // The open notch around the tab (`ContentView`), mirrored here so the tests can add it up.
    /// `ContentView.mainLayoutBase` pads the open notch's content by 12 pt at the bottom, inside
    /// the notch's clip shape: that strip is painted notch, under every tab.
    static let openNotchBottomPadding: CGFloat = 12
    /// `ContentView.notchHorizontalPadding` while open: `cornerRadiusInsets.opened.bottom` (24)
    /// less 5, the wider of its two cases. Its outer 12 pt padding is added back by the root
    /// frame (`dynamicNotchSize.width + 24`), so the content is the notch's width less this twice.
    static let openNotchSideInset: CGFloat = 19
    /// The narrowest open notch: `recommendedMinimumNotchWidth`'s floor (matters.swift).
    static let smallestOpenNotchWidth: CGFloat = 640

    // The side column beside the composer (`TimerSideColumn`): one page, the whole budget tall.
    static let sideColumnWidth: CGFloat = 240
    /// Room the page leaves under itself, above the tab's bottom line.
    static let sideBottomInset: CGFloat = 4
    /// The "Tasks · Presets" labels, shown only when both pages exist. They are an overlay of the
    /// column, so they take no layout room: they hang below the tab's bottom line, in the footer.
    static let sidePagerHeight: CGFloat = 14
    /// How far below the tab's bottom line the labels' bottom edge sits.
    ///
    /// The painted footer under that line is `visibleFooterHeight`: the tab's own bottom padding
    /// (6) plus the open notch's bottom padding (12), 18 pt, since `NotchTimerView` is the last
    /// thing in `ContentView.NotchLayout`'s stack and the notch's shape is that stack plus its
    /// padding. With the offset at 14 the 14 pt label row spans 0–14 pt below the line: wholly
    /// under the content, wholly inside the notch, and 18 − 14 = 4 pt clear of the bottom edge.
    /// The column's centre sits over 100 pt in from the notch's side, well clear of its 24 pt
    /// bottom corner radius, so the flat bottom edge is the one that counts.
    static let sidePagerFooterOffset: CGFloat = 14
    /// One task row: key and title on one line, "42m of 2h" under it, and ▶.
    static let sideTaskRowHeight: CGFloat = 36
    static let sideRowSpacing: CGFloat = 4
    /// The Tasks list is never shorter than this many rows (room permitting): the first row's ▶
    /// tooltip opens below it, and a list clipped to one row would swallow the bubble.
    static let sideTaskMinimumRows = 2

    /// The painted notch under the tab's bottom line (see `sidePagerFooterOffset`).
    static var visibleFooterHeight: CGFloat { tabVerticalPadding + openNotchBottomPadding }

    /// How far the page swipe's area (`NotchTimerView`'s `HorizontalSwipeMonitor`) reaches below
    /// the tab's padded frame: the open notch's own bottom padding. The padded frame ends
    /// `tabVerticalPadding` (6) under the bottom line; this adds the remaining 12, so the area runs
    /// down to the notch's bottom edge, 18 pt under the line, and holds the whole "Tasks · Presets"
    /// row (0–14 pt under it). Without it the row's lower 8 pt were outside the swipe.
    static var pageSwipeFooterReach: CGFloat { openNotchBottomPadding }

    /// The height left for the shown page: the tab's budget less the bottom inset. The labels
    /// live in the footer, so the page starts level with the session name field.
    static func sidePageHeight(budget: CGFloat) -> CGFloat {
        max(0, budget - sideBottomInset)
    }

    /// Every row's height plus the spacing around it, so a short list ends where its last row does.
    static func sideTaskRowsHeight(count: Int) -> CGFloat {
        CGFloat(max(0, count)) * (sideTaskRowHeight + sideRowSpacing)
    }

    /// `.manualWithPresets` is the stacked layout used whenever the side column shows (presets on,
    /// or the Tasks page available); `.manualWithoutPresets` is the wide one, with no column.
    enum Style: CaseIterable { case manualWithPresets, manualWithoutPresets, ruler }

    static var durationFieldHeight: CGFloat { fieldBoxHeight + captionGap + captionHeight }

    // Widths. The duration row is three fields and two colons; the stacked layout (beside the
    // side column) uses the narrow fields, the wide one the wider fields.
    static let stackedFieldWidth: CGFloat = 64
    static let wideFieldWidth: CGFloat = 78
    static let durationRowSpacing: CGFloat = 8
    /// One ":" at `fieldDigitSize` in the black monospaced face: about 0.6 em, rounded up.
    static let colonWidth: CGFloat = 14

    static func durationRowWidth(fieldWidth: CGFloat) -> CGFloat {
        fieldWidth * 3 + colonWidth * 2 + durationRowSpacing * 4
    }

    /// The stacked composer's narrowest width: its duration row and padding. Start and Reset
    /// share the same width below it, so they are never the narrower part.
    static var stackedComposerMinimumWidth: CGFloat {
        durationRowWidth(fieldWidth: stackedFieldWidth) + composerPadding * 2
    }

    /// The composer's width beside the side column, in an open notch `notchWidth` wide.
    static func composerWidthBesideSideColumn(notchWidth: CGFloat) -> CGFloat {
        notchWidth - openNotchSideInset * 2 - tabHorizontalPadding * 2
            - tabColumnSpacing * 2 - dividerWidth - sideColumnWidth
    }

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
