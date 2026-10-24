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

    // The two columns split the tab's width in the golden ratio around the gap between them (the
    // divider and its spacing): composer : side column = φ : 1, at every notch width, so the
    // notch never grows for it — the columns share what the notch has.
    static let goldenRatio: CGFloat = 1.6180339887
    /// The room between the composer and the side column: the divider and its spacing either side.
    static var columnGap: CGFloat { tabColumnSpacing * 2 + dividerWidth }
    /// The narrowest the side column gets (only below the standard notch widths): two 85 pt fact
    /// columns on a task's card.
    static let minimumSideColumnWidth: CGFloat = 200

    /// The tab's width inside its padding, in an open notch `notchWidth` wide.
    static func tabContentWidth(notchWidth: CGFloat) -> CGFloat {
        notchWidth - openNotchSideInset * 2 - tabHorizontalPadding * 2
    }

    /// The side column's width: what the two columns share, over φ² (so the composer has φ times
    /// it), in whole points, rounded down so the composer takes the fraction. 202 pt in the
    /// narrowest notch, 215 in a 675 pt one.
    static func sideColumnWidth(notchWidth: CGFloat) -> CGFloat {
        let columns = tabContentWidth(notchWidth: notchWidth) - columnGap
        return max(minimumSideColumnWidth, (columns / (goldenRatio * goldenRatio)).rounded(.down))
    }

    /// Two parts of `total` with `spacing` between them in the golden ratio, minor : major = 1 : φ,
    /// in whole points: the task form's estimate and tags, Add and Add & Start.
    static func goldenSplit(_ total: CGFloat, spacing: CGFloat) -> (minor: CGFloat, major: CGFloat) {
        let parts = max(0, total - spacing)
        let minor = (parts / (1 + goldenRatio)).rounded(.down)
        return (minor, parts - minor)
    }

    /// The widths `GoldenRow` gives its views across `total`: one view, the whole width; two, the
    /// golden split, the minor part first; more, the first the minor part and the rest sharing the
    /// major part evenly. A width that is not finite (an HStack measuring its views) gives none: the
    /// caller sizes the views by their own widths instead, never by NaN.
    static func goldenWidths(across total: CGFloat, count: Int, spacing: CGFloat) -> [CGFloat]? {
        guard total.isFinite else { return nil }
        switch count {
        case ..<1: return []
        case 1: return [max(0, total)]
        default:
            let split = goldenSplit(total, spacing: spacing)
            let rest = max(0, (split.major - spacing * CGFloat(count - 2)) / CGFloat(count - 1))
            return [split.minor] + Array(repeating: rest, count: count - 1)
        }
    }

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

    /// The shown page's height: the composer's, name field included (`totalHeight(style)`), so the
    /// page — list, card, divider — ends on the line Start and Reset end on; never past the budget
    /// less the bottom inset. The labels live in the footer, so the page starts level with the
    /// session name field. 122 pt beside the stacked composer: three task rows.
    static func sidePageHeight(budget: CGFloat, style: Style) -> CGFloat {
        max(0, min(budget - sideBottomInset, totalHeight(style)))
    }

    /// The Tasks page's search field, at the page's top while searching: as tall as the session
    /// name field and as far above the list as the field is above the composer, so the two rows
    /// line up across the tab.
    static let sideToolbarHeight: CGFloat = nameFieldHeight
    static let sideToolbarSpacing: CGFloat = nameFieldSpacing

    // The Tasks page's rail (`TimerTasksPage.rail`): its icons in the gap between the columns,
    // centred on the divider's line, which it replaces while the page shows.
    static let railButtonSize: CGFloat = 21
    static let railGlyphSize: CGFloat = 10
    static let railCornerRadius: CGFloat = 6
    /// One icon's slot: the session name field's height, so the first icon is centred on it.
    static var railSlotHeight: CGFloat { nameFieldHeight }
    /// Between slots, and above the hairline: the name field's gap to the composer.
    static var railSpacing: CGFloat { nameFieldSpacing }
    /// How far left of the page the rail's leading edge sits: its centre on the divider's line,
    /// half the gap in, so it keeps the same room from both columns.
    static var railOffset: CGFloat { tabColumnSpacing + dividerWidth / 2 + railButtonSize / 2 }

    /// The task list's height under the search field: the page less the field and its spacing.
    /// Without the search the list has the whole page.
    static func sideListHeight(pageHeight: CGFloat) -> CGFloat {
        max(0, pageHeight - sideToolbarHeight - sideToolbarSpacing)
    }

    // The task form (`TimerTaskForm`), in the composer's place: the title row where the name field
    // is, the estimate and tags, the reminder, then the buttons.
    // 8 pt between rows makes the form exactly the composer's height (122), so the two swap without
    // anything around them moving.
    static let taskFormRowHeight: CGFloat = 24
    static let taskFormRowSpacing: CGFloat = 8
    static var taskFormHeight: CGFloat {
        nameFieldHeight + 2 * taskFormRowHeight + buttonHeight + 3 * taskFormRowSpacing
    }
    /// The New task button beside the session name field: a square as tall as the field.
    static var newTaskButtonSize: CGFloat { nameFieldHeight }

    // The typed search under the bar and a new task's title (`TimerTaskSuggestions`): two tasks
    // and the New row (`TaskSearch.suggestionLimit` + 1), short enough to end above Start and Reset
    // in both composer styles, and above the form's buttons.
    static let suggestionRowHeight: CGFloat = 20
    static let suggestionListPadding: CGFloat = 2
    static let suggestionRowCount = 3
    static var suggestionListHeight: CGFloat {
        CGFloat(suggestionRowCount) * suggestionRowHeight + 2 * suggestionListPadding
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
        tabContentWidth(notchWidth: notchWidth) - columnGap - sideColumnWidth(notchWidth: notchWidth)
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
