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

import SwiftUI

/// Two views side by side in the golden ratio, the first the minor part (1 : φ), across whatever
/// width the row is offered (`TimerComposerMetrics.goldenWidths`); a single view takes the whole
/// row. The row is as tall as its tallest view at those widths. The timer tab's task form: the
/// estimate and the tags, Add and Add & Start; Brain's New Task, the estimate and the tags.
struct GoldenRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // No width, or an infinite one (an HStack measuring its views): the views' own widths, and
        // all of an infinite offer, never a NaN split.
        guard let width = proposal.width,
              let widths = TimerComposerMetrics.goldenWidths(across: width, count: subviews.count, spacing: spacing) else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, subviews.count - 1))
            return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
        }
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = TimerComposerMetrics.goldenWidths(across: bounds.width, count: subviews.count, spacing: spacing) ?? []
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}
