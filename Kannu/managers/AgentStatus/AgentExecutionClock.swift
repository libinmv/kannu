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

import Foundation

/// When a card's run clock starts, for sessions that have no hook turn to read it from.
///
/// The preferred source is `HookTurn.startedAt`, recorded on disk by the hook script, and issue #14's
/// headline symptom — "execution time resets when thinking mode happens" — was fixed there: thinking
/// events only bump `turn_tool_calls` and leave the turn keys alone, and a prompt opens a turn only
/// when none is already open. This is the fallback for everything with no turn: passive sources
/// (Warp, Claude Desktop agent mode, transcript-only Cursor) and hook files written before v39.
///
/// The fallback had its own reset, reached by a different route. It treated "the previous cycle was not
/// an active run" as "this is a new run" and stamped `now`, so **any** non-active dip restarted the
/// clock — including the `activeStaleMs` demotion that fires during a long quiet thinking phase, where
/// the raw state never stopped being `executing`. A twenty-minute turn could therefore show a few
/// seconds, which is exactly what the issue describes.
///
/// The rule now separates a *demotion* from an *end*. `displayState` is what the staleness ladder
/// concluded; `rawState` is what the source actually reported. A session whose display state dipped
/// while its raw state stayed active has not ended, so its clock is kept and resumed. Only a raw state
/// that is no longer active clears it — and a genuinely new request after a real stop still restarts,
/// because the entry is gone by then.
enum AgentExecutionClock {
    /// What the rule needs to know about one session. Deliberately not `AgentSessionStatus`: the rule
    /// is about four facts, and a test should not have to build a whole session to state them.
    struct Input {
        let conversationID: String
        /// `displayState.isActiveRun` — after the staleness ladder has had its say.
        let isActiveRun: Bool
        /// `hasActiveRawState` — what the source reported, before the ladder.
        let hasActiveRawState: Bool
        let updatedAt: Date
        /// Whether the previously published state for this conversation was an active run.
        let previousWasActiveRun: Bool
    }

    struct Resolution: Equatable {
        /// The clock to carry into the next cycle.
        var startByConversationID: [String: Date]
        /// What each conversation's card should show. A conversation absent here shows nothing, which
        /// is the case for every session that is not currently an active run.
        var displayedStartByConversationID: [String: Date]
    }

    /// - Parameters:
    ///   - inputs: one per session in the freshly built list.
    ///   - existing: the clock carried from the previous cycle.
    ///   - now: the rescan's clock.
    static func resolve(inputs: [Input], existing: [String: Date], now: Date) -> Resolution {
        // Drop conversations that are no longer on the list at all, so the map cannot grow forever.
        let liveConversationIDs = Set(inputs.map(\.conversationID))
        var carried = existing.filter { liveConversationIDs.contains($0.key) }
        var displayed: [String: Date] = [:]

        for input in inputs {
            guard input.isActiveRun else {
                if input.hasActiveRawState {
                    // A demotion, not an end: the staleness ladder dimmed a card whose source still
                    // says it is working. Keep the clock so the next active tick resumes it rather
                    // than restarting from zero.
                    continue
                }
                // A genuine end. The next request starts a new run and a new clock.
                carried.removeValue(forKey: input.conversationID)
                continue
            }

            let start: Date
            if input.previousWasActiveRun {
                // Mid-run: `updatedAt` is the fallback only for a run already in progress when Kannu
                // started watching it, where there is nothing better to date it from.
                start = carried[input.conversationID] ?? input.updatedAt
            } else {
                // Becoming active again. `carried` is non-nil exactly when the dip was a demotion
                // rather than an end, which is what makes the clock survive it.
                start = carried[input.conversationID] ?? now
            }
            carried[input.conversationID] = start
            displayed[input.conversationID] = start
        }

        return Resolution(startByConversationID: carried, displayedStartByConversationID: displayed)
    }
}
