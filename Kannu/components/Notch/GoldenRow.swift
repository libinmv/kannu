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
/// width the row is offered (`TimerComposerMetrics.goldenSplit`); a single view takes the whole
/// row. The row is as tall as its tallest view at those widths. The timer tab's task form: the
/// estimate and the tags, Add and Add & Start.
struct GoldenRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let width = proposal.width else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, subviews.count - 1))
            return CGSize(width: natural, height: sizes.map(\.height).max() ?? 0)
        }
        let height = zip(subviews, widths(across: width, count: subviews.count))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(across: bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    /// One view: the whole width. Two: the golden split. More are not a golden row; they share the
    /// major part's width evenly after the first.
    private func widths(across total: CGFloat, count: Int) -> [CGFloat] {
        switch count {
        case 0: return []
        case 1: return [total]
        default:
            let split = TimerComposerMetrics.goldenSplit(total, spacing: spacing)
            let rest = max(0, (split.major - spacing * CGFloat(count - 2)) / CGFloat(count - 1))
            return [split.minor] + Array(repeating: rest, count: count - 1)
        }
    }
}
