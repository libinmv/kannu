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

/// Keeps a momentary blip in the combined traffic light off the screen.
///
/// A Stop hook followed milliseconds later by a wake event, or a short-lived helper session whose
/// red briefly outranks a working chat's green, computes a real state change on one rescan and
/// takes it back on the next. Publishing both re-staged the light's transition animations and
/// re-armed the notch's reveal window for nothing (the notch never settled while such blips
/// recurred). The rule: **leaving an active run, or hiding the light, must persist for
/// `holdSeconds` before it is published; everything that lights up publishes at once.**
///
/// Deliberately immediate:
/// - the first publish after a start or reset;
/// - any entry into `.executing`, `.thinking` or `.awaitingInput` — yellow follows evidence
///   (`docs/REGRESSIONS.md` entry 12), and a working chat should light up without lag;
/// - showing the light (`shouldShow` false → true), whatever the state.
///
/// Pure and synchronous, like `AgentActivityPulseLatch`: the caller owns the clock and the timer.
/// On `.hold`, the caller schedules a re-evaluation for the returned deadline and feeds the gate
/// the state recomputed *at that time* — never the one captured when the hold was armed. A held
/// candidate that reverts before its deadline was never published, so nothing flickers.
struct TrafficLightPersistenceGate {
    /// How long a calming change must persist before it is published.
    static let holdSeconds: TimeInterval = 1.0

    struct Pair: Equatable {
        var state: AgentTrafficLightState
        var shouldShow: Bool

        /// The states that mean a run is live on screen: green (executing, thinking) and
        /// yellow (awaitingInput). Leaving this set is what the gate delays.
        var isActiveRun: Bool {
            switch state {
            case .executing, .thinking, .awaitingInput: return true
            case .stopped, .inactive: return false
            }
        }
    }

    enum Verdict: Equatable {
        /// Publish this pair now; the gate has recorded it as published.
        case publish
        /// The pair equals what is already published (any pending hold is cancelled) —
        /// publish nothing and cancel the re-evaluation timer.
        case unchanged
        /// A calming change that has not yet persisted: publish nothing now, re-evaluate the
        /// freshest state at `until`.
        case hold(until: Date)
    }

    private var published: Pair?
    private var pending: (pair: Pair, since: Date)?

    /// The single decision point; call it with every computed display pair, including the
    /// re-evaluation the caller schedules for a `.hold` deadline.
    mutating func decide(state: AgentTrafficLightState, shouldShow: Bool, now: Date) -> Verdict {
        let candidate = Pair(state: state, shouldShow: shouldShow)

        if candidate == published {
            pending = nil
            return .unchanged
        }

        guard let published else {
            self.published = candidate
            pending = nil
            return .publish
        }

        let isCalming = (published.isActiveRun && !candidate.isActiveRun)
            || (published.shouldShow && !candidate.shouldShow)
        guard isCalming else {
            self.published = candidate
            pending = nil
            return .publish
        }

        if let pending, pending.pair == candidate {
            let deadline = pending.since.addingTimeInterval(Self.holdSeconds)
            guard now >= deadline else { return .hold(until: deadline) }
            self.published = candidate
            self.pending = nil
            return .publish
        }

        // A new calming candidate (or a different one than was pending): its clock starts now.
        pending = (candidate, now)
        return .hold(until: now.addingTimeInterval(Self.holdSeconds))
    }

    /// Forget everything; the next `decide` publishes immediately. For the monitor's `stop()`,
    /// so a restart never inherits a stale hold or compares against a torn-down published value.
    mutating func reset() {
        published = nil
        pending = nil
    }
}
