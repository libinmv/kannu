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

/// The name a user types for a timer session, before starting it or while it runs.
///
/// A name is one line, at most `maxLength` characters (characters as the user sees them, so an
/// emoji counts once): the notch shows it in a single fixed-width line, and the music-and-timer view
/// has no room for more. An empty name is no name, and the session keeps its default — the preset's
/// name, or "Custom Timer".
enum TimerSessionName {
    static let maxLength = 40

    /// The typed name made safe to show, or nil when nothing is left of it.
    static func cleaned(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        guard joined.count > maxLength else { return joined }
        return String(joined.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    /// The name a session starts with: what the user typed, or the default.
    static func resolved(typed: String, fallback: String) -> String {
        cleaned(typed) ?? fallback
    }

    /// The name a rename sets, or nil when it changes nothing. A rename is saved when the field
    /// loses focus, the notch closes or the window goes to the background, so it can land after a
    /// new session has started: one begun in an earlier session never renames the current one.
    static func renamed(
        _ typed: String,
        begunIn session: UUID,
        current: UUID,
        currentName: String,
        fallback: String
    ) -> String? {
        guard session == current else { return nil }
        let name = resolved(typed: typed, fallback: fallback)
        return name == currentName ? nil : name
    }
}

/// A task picked from the timer tab's typed search for the next session (`TimerTaskSuggestions`).
/// It lasts while the bar still says `name`: editing the text, or clearing it, drops the pick.
///
/// Pure, in the logic target.
struct TimerSessionPick: Equatable {
    /// The picked task; nil for the New row: keep the typed text as a new task, even when a task
    /// with that title exists.
    let taskID: UUID?
    /// What the bar says while the pick lasts.
    let name: String
    /// What the user had typed when they picked; the bar gets it back if the task goes away.
    let typed: String

    var isNew: Bool { taskID == nil }

    /// This pick while the bar still says `name`; nil once the text changed.
    func kept(typed text: String) -> TimerSessionPick? {
        text == name ? self : nil
    }
}

/// How a session started from the timer tab's bar runs (David, 2026-10-23): plain with tasks off,
/// or with nothing typed or picked; a picked task, timed as it is; or a typed name timed as a task,
/// reusing one with that title except after the New row.
///
/// Pure, in the logic target.
enum TimerTypedStart: Equatable {
    case plain
    case pickedTask(UUID)
    case typed(reuse: Bool)

    static func route(tasksAvailable: Bool, typed: String, pick: TimerSessionPick?) -> TimerTypedStart {
        guard tasksAvailable else { return .plain }
        if let taskID = pick?.taskID { return .pickedTask(taskID) }
        guard TimerSessionName.cleaned(typed) != nil else { return .plain }
        return .typed(reuse: pick == nil)
    }
}
