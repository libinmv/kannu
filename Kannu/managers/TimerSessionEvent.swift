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

/// One thing that happened to a timer session started in Kannu, said explicitly.
///
/// `TimerManager` sends these on `sessionEvents` so a listener never has to work out a start or a
/// stop from `$isTimerActive` or `$isPaused`. Those are `@Published` values, and several changes in
/// one main-actor turn arrive as one (docs/REGRESSIONS.md entry 10): a replace (stop the old session,
/// start the new one) would read as nothing happening at all.
///
/// Only sessions started in Kannu have events. A Clock-app timer that Kannu mirrors never sends one.
struct TimerSessionEvent: Equatable {
    enum EndReason: String, Equatable {
        /// The user stopped the session (any stop button: the notch, the popover, the control
        /// overlay, the lock-screen widget).
        case stopped
        /// A new session started while this one was running.
        case replaced
    }

    enum Kind: Equatable {
        case started
        case paused
        case resumed
        case ended(EndReason)
    }

    let kind: Kind
    /// `TimerManager.sessionID` of the session this happened to. An `.ended` event always carries
    /// the ending session's id: it is sent before the next id is minted.
    let session: UUID
    /// When it happened, taken where it happened. Listeners record this date, not the time the
    /// event reaches them, so a hop to another queue does not move the recorded time.
    let at: Date
}
