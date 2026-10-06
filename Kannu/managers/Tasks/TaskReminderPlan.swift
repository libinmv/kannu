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

/// Which task reminders should be waiting with macOS, and what to change after an edit. Pure: the
/// notification center calls live in `TaskReminders.swift`, which applies `changes`.
///
/// A reminder belongs to a local, active task with a `scheduledAt`. Marking it done, hiding it,
/// deleting it or clearing its schedule takes it out of `wanted`, and `changes` turns that into a
/// removal — of the waiting request and of a reminder already shown. A reminder whose time has
/// passed stays wanted, so one already on screen is left alone. Its identifier is the task's id
/// behind a fixed prefix, so a later change replaces the request instead of adding a second one.
///
/// `changes` trusts that macOS holds what it was last told; `reconcile` checks what macOS actually
/// holds, which catches notifications turned on while Kannu was not running, a task file replaced,
/// and tasks turned off.
enum TaskReminderPlan {
    struct Reminder: Equatable {
        let taskID: UUID
        let title: String
        let date: Date
    }

    struct Changes: Equatable {
        /// Requests to add, or to replace when the date or title changed. Soonest first.
        var add: [Reminder] = []
        /// Identifiers to take back: waiting, or already shown.
        var remove: [String] = []

        var isEmpty: Bool { add.isEmpty && remove.isEmpty }
    }

    static let identifierPrefix = "kannu.task-reminder."

    static func identifier(for taskID: UUID) -> String {
        identifierPrefix + taskID.uuidString
    }

    /// The task a reminder is for; nil for any other notification.
    static func taskID(fromIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
    }

    /// The reminders the task list asks for, by task, past ones included.
    static func wanted(_ tasks: [TaskItem]) -> [UUID: Reminder] {
        var result: [UUID: Reminder] = [:]
        for task in tasks where task.source == .local && task.visibility == .active {
            guard let date = task.scheduledAt else { continue }
            result[task.id] = Reminder(taskID: task.id, title: task.title, date: date)
        }
        return result
    }

    /// What to tell macOS to go from `old` to `new`. A new or changed reminder still ahead of `now`
    /// is added (replacing any earlier request); one changed to a time already past is taken back,
    /// since it can no longer fire; one no longer wanted is taken back. Unchanged ones are left
    /// alone, past or not.
    static func changes(from old: [UUID: Reminder], to new: [UUID: Reminder], now: Date) -> Changes {
        let changed = new.values.filter { old[$0.taskID] != $0 }
        let add = soonestFirst(changed.filter { $0.date > now })
        let withdrawn = old.keys.filter { new[$0] == nil } + changed.filter { $0.date <= now }.map(\.taskID)
        return Changes(add: add, remove: withdrawn.map(identifier(for:)).sorted())
    }

    /// Sends every wanted reminder still ahead again, once macOS allows them. Adds only: a resend
    /// never takes anything back, so a reminder already on screen for another task stays there.
    static func resend(_ wanted: [UUID: Reminder], now: Date) -> Changes {
        Changes(add: soonestFirst(wanted.values.filter { $0.date > now }))
    }

    /// What to tell macOS so it holds what the task list wants, judged from what macOS says it
    /// holds rather than from what the file assumes. `pending` and `delivered` are identifiers
    /// macOS reports; any without `identifierPrefix` are ignored.
    ///
    /// - A waiting request is taken back when its task no longer wants one, or wants one whose time
    ///   has passed (it can never fire).
    /// - A reminder on screen is taken back only when its task no longer wants one at all.
    /// - With `canAdd`, every wanted reminder still ahead that macOS is not holding is added.
    static func reconcile(pending: [String], delivered: [String], wanted: [UUID: Reminder],
                          now: Date, canAdd: Bool) -> Changes {
        let pendingIDs = pending.filter { $0.hasPrefix(identifierPrefix) }
        let deliveredIDs = delivered.filter { $0.hasPrefix(identifierPrefix) }
        let stalePending = pendingIDs.filter { identifier in
            guard let reminder = taskID(fromIdentifier: identifier).flatMap({ wanted[$0] }) else { return true }
            return reminder.date <= now
        }
        let staleDelivered = deliveredIDs.filter { identifier in
            taskID(fromIdentifier: identifier).flatMap { wanted[$0] } == nil
        }
        let held = Set(pendingIDs)
        let add = canAdd
            ? soonestFirst(wanted.values.filter { $0.date > now && !held.contains(identifier(for: $0.taskID)) })
            : []
        return Changes(add: add, remove: Array(Set(stalePending + staleDelivered)).sorted())
    }

    private static func soonestFirst(_ reminders: [Reminder]) -> [Reminder] {
        reminders.sorted { ($0.date, $0.taskID.uuidString) < ($1.date, $1.taskID.uuidString) }
    }

    /// How a schedule reads on a row: "Today 15:00", "Tomorrow 09:30", "Overdue · Mon 10:00", or the
    /// date for anything later.
    enum When: Equatable {
        case overdue
        case today
        case tomorrow
        case later
    }

    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> When {
        if date <= now { return .overdue }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return .tomorrow }
        return .later
    }
}
