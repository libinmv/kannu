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

/// The archive's clock: a closed task moves to the archive after `closedDays`, and an archived
/// Jira or GitLab task is cleared `clearDays` after it was archived. Pure, so the rules are tested;
/// `TasksManager` applies it after loading and after every sync, and nothing else runs it (no timer:
/// a day-scale rule needs no second hand).
///
/// What clearing must never cost:
/// - **Time not yet logged.** A task with an open draft (awaiting, sending, failed, uncertain), an
///   interrupted session, or finished time not folded into a draft that would round to something
///   loggable waits — it clears `clearDays` after that time is logged or kept on this Mac.
/// - **A ticket that is still open.** One the server still lists (`closedAt` is nil) is never
///   cleared: the next sync would only bring it back as a new task, without its history.
/// - **The user's own tasks.** A local task is never cleared; only the user deletes one.
/// - **The task being timed** (or about to be): `protected`.
enum TaskArchive {
    /// Days a closed (done or gone) task stays under Recently closed before it is archived.
    static let closedDays = 3
    /// Days an archived Jira or GitLab task stays in the archive before it is cleared.
    static let clearDays = 7

    struct Result: Equatable {
        var tasks: [TaskItem]
        var drafts: [WorklogDraft]
        var archived: Int
        var cleared: Int
        /// Something was stamped, archived or cleared: worth saving.
        var changed: Bool
    }

    static func apply(_ tasks: [TaskItem], drafts: [WorklogDraft], protected: Set<UUID>, now: Date,
                      calendar: Calendar = .current) -> Result {
        var result: [TaskItem] = []
        var keptDrafts = drafts
        var archived = 0
        var cleared = 0
        var changed = false

        for var task in tasks {
            // Seed: a file written before the archive has closed tasks with no date. A gone one
            // closed about when it was last seen; a done one is counted from now.
            if task.visibility == .done || task.visibility == .gone, task.closedAt == nil {
                task.closedAt = task.visibility == .gone ? (task.remote?.lastSeenAt ?? now) : now
                changed = true
            }

            if task.visibility == .done || task.visibility == .gone, let closed = task.closedAt,
               !protected.contains(task.id), now >= adding(closedDays, to: closed, calendar) {
                task.visibility = .archived
                task.archivedAt = now
                task.archivedByUser = false
                archived += 1
                changed = true
            }

            if task.visibility == .archived, task.archivedAt == nil {
                task.archivedAt = now
                changed = true
            }

            if isClearable(task, drafts: keptDrafts, protected: protected, now: now, calendar: calendar) {
                keptDrafts.removeAll { $0.taskID == task.id }
                cleared += 1
                changed = true
                continue
            }
            result.append(task)
        }
        return Result(tasks: result, drafts: keptDrafts, archived: archived, cleared: cleared, changed: changed)
    }

    /// An archived remote task, archived long enough, that the server no longer lists, holding no
    /// time still to log, and not the task being timed.
    static func isClearable(_ task: TaskItem, drafts: [WorklogDraft], protected: Set<UUID>, now: Date,
                            calendar: Calendar = .current) -> Bool {
        guard task.source != .local, task.visibility == .archived, task.closedAt != nil,
              let archivedAt = task.archivedAt, now >= adding(clearDays, to: archivedAt, calendar),
              !protected.contains(task.id) else { return false }
        return !holdsTimeToLog(task, drafts: drafts)
    }

    /// Time on this task that could still reach Jira or GitLab: an open draft, an interrupted
    /// session (its end is not set yet), or finished time no draft holds that would round to a
    /// loggable amount. Time under that rounding was never going to be logged.
    static func holdsTimeToLog(_ task: TaskItem, drafts: [WorklogDraft]) -> Bool {
        if drafts.contains(where: { $0.taskID == task.id && WorklogDrafts.isOpen($0.state) }) { return true }
        if task.segments.contains(where: \.isInterrupted) { return true }
        guard task.logPolicy == .ask else { return false }
        let unfolded = task.segments
            .filter { $0.end != nil && $0.draftID == nil }
            .reduce(0) { $0 + TaskTimeMath.seconds(of: $1, now: $1.end ?? $1.start) }
        return TaskTimeMath.roundedForLog(unfolded) > 0
    }

    /// Days left before a closed task is archived (0 when it is due), for Brain's caption.
    static func daysUntilArchive(_ task: TaskItem, now: Date, calendar: Calendar = .current) -> Int? {
        guard task.visibility == .done || task.visibility == .gone, let closed = task.closedAt else { return nil }
        return daysLeft(until: adding(closedDays, to: closed, calendar), now: now, calendar: calendar)
    }

    /// Days left before an archived remote task is cleared; nil when it never will be on its own
    /// (local, still listed) — Brain says why instead.
    static func daysUntilClear(_ task: TaskItem, now: Date, calendar: Calendar = .current) -> Int? {
        guard task.source != .local, task.visibility == .archived, task.closedAt != nil,
              let archivedAt = task.archivedAt else { return nil }
        return daysLeft(until: adding(clearDays, to: archivedAt, calendar), now: now, calendar: calendar)
    }

    private static func adding(_ days: Int, to date: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    private static func daysLeft(until date: Date, now: Date, calendar: Calendar) -> Int {
        guard date > now else { return 0 }
        return max(1, Int((date.timeIntervalSince(now) / 86_400).rounded(.up)))
    }
}
