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

/// The notch's Time to log cards, wherever the notch asks "Log time?": the Tasks popover, and the
/// timer tab's task column (its clock button). The first `maxCards` entries still asking, each the
/// very card Brain shows (`WorklogDraftCard`, so Log goes the same one way it does there), stacked
/// to fit a narrow column; then "N more in Brain" for the rest.
struct LogTimeCards: View {
    /// The entries asking now (`WorklogDrafts.isAskingNow`), in the order they ask.
    let asking: [WorklogDraft]
    let maxCards: Int
    /// Opens Brain › Tasks › Time to log, after whatever the caller must close first.
    let openBrain: (TasksBrainDestination) -> Void

    var body: some View {
        let cards = Array(asking.prefix(maxCards))
        let more = asking.count - cards.count
        ForEach(cards) { draft in
            WorklogDraftCard(draft: draft)
                .labeledContentStyle(StackedCardStyle())
                .controlSize(.small)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        if more > 0 {
            Button(more == 1 ? String(localized: "1 more in Brain") : String(localized: "\(more) more in Brain")) {
                openBrain(.timeToLog)
            }
            .buttonStyle(.link)
            .font(.system(size: 12, weight: .medium))
        }
    }
}

/// The Time to log card, stacked to fit the notch: what would be logged on top, then the length,
/// the comment and the answers, trailing. In Brain the same card is a Form row.
struct StackedCardStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
            configuration.content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
