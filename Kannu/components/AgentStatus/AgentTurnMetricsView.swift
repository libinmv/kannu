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

/// The trailing column of a Recent chats row: this request's run time, and under it its tool calls
/// and tokens ("1h 53m 54s" / "212 tools · 1.4M in · 45k out"; "Ran 2h 3m 12s" once it ended).
///
/// Observes the token follower itself, so a token update re-renders this column only — never the
/// list (whose rows each resolve a click-through target). Only a running request ticks, once a
/// second, and nothing animates. No `.help` and no nested tooltip: the row's Button owns the hover
/// (docs/REGRESSIONS.md entry 9). Digits are never cut: each line falls back to a shorter form, or
/// to nothing, when it does not fit.
struct AgentTurnMetricsView: View {
    let session: AgentSessionStatus
    /// The primary card's larger type.
    var prominent = false

    @ObservedObject private var follower = ClaudeTurnTokenFollower.shared

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            if let display = AgentTurnMetricsView.display(for: session) {
                column(display)
                    .layoutPriority(1)
            }
        }
    }

    static func display(for session: AgentSessionStatus) -> AgentTurnDisplay? {
        AgentTurnDisplay.duration(turn: session.turn, executionStartedAt: session.executionStartedAt,
                                  state: session.displayState, hookReportsWork: session.hasActiveRawState,
                                  updatedAt: session.updatedAt)
    }

    /// Tokens only when they belong to this card's current turn.
    private var tokens: TurnTokens? {
        guard let turn = session.turn, let tokens = follower.tokens[session.conversationID],
              tokens.startedAt == turn.startedAt, tokens.startOffset == turn.transcriptOffset else { return nil }
        return tokens
    }

    @ViewBuilder
    private func column(_ display: AgentTurnDisplay) -> some View {
        let toolCalls = session.turn?.toolCalls ?? 0
        let tokens = self.tokens
        let lines = AgentTurnFormat.metricsLines(toolCalls: toolCalls, tokens: tokens)
        VStack(alignment: .trailing, spacing: 2) {
            switch display {
            case let .live(since):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    durationLine(full: AgentTurnFormat.duration(context.date.timeIntervalSince(since)),
                                 short: AgentTurnFormat.shortDuration(context.date.timeIntervalSince(since)))
                }
            case let .ended(interval):
                durationLine(full: AgentTurnFormat.ran(AgentTurnFormat.duration(interval)),
                             short: AgentTurnFormat.ran(AgentTurnFormat.shortDuration(interval)))
            }
            ViewThatFits(in: .horizontal) {
                if let full = lines.full { Text(full) }
                if let tokensOnly = lines.tokensOnly { Text(tokensOnly) }
                if let toolsOnly = lines.toolsOnly { Text(toolsOnly) }
                EmptyView()
            }
        }
        .font(prominent ? .caption : .caption2)
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentTurnFormat.accessibilityText(display, now: Date(), toolCalls: toolCalls, tokens: tokens))
    }

    private func durationLine(full: String, short: String) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(full)
            Text(short)
            EmptyView()
        }
    }
}
