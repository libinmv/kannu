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

/// The order the user gives their tasks. The array's order is the order: there is no sort key, and
/// nothing re-sorts it. A new local task goes on top; Move to Top is the one move (David,
/// 2026-10-23: "no drag and order tasks or numbering"), so the user still picks what the notch's
/// Up next shows first.
///
/// Done, hidden and gone tasks keep their place in the array, so reopening one puts it back where
/// it was.
///
/// Which active tasks are on screen is `listed`: the connected baseline (`connectedFilter`),
/// narrowed by a view's own filter — the Task list's filters in Brain, Show in notch in the notch.
/// Its default lists every active task.
enum TaskOrdering {
    typealias Listed = (TaskItem) -> Bool

    /// The connected baseline: every task Kannu holds, whatever any view shows. Local tasks always;
    /// Jira and GitLab tasks always — synced, with their sync paused, or kept after a disconnect —
    /// because Sync Jira and Sync GitLab only decide what is fetched. Only Include merge requests,
    /// which says what GitLab is asked for, narrows it: off (`showGitLabMergeRequests` false), the
    /// merge requests leave the order at once, without waiting for a sync. The task being timed
    /// always shows, so it can be stopped from the list. Reads no view setting.
    static func connectedFilter(showGitLabMergeRequests: Bool, alwaysListed: UUID?) -> Listed {
        { task in
            if task.id == alwaysListed { return true }
            guard task.source == .gitlab else { return true }
            return showGitLabMergeRequests || task.remote?.gitlabKind != .mergeRequest
        }
    }

    /// A view's own filter by source — the notch's Show in notch (`tasksPopoverShowLocal` and the
    /// rest): the sources it hides. It changes nothing but what that view shows: compose it with the
    /// connected baseline (`active(_:listed:)` on `TasksManager.activeTasks`). The task being timed
    /// always passes.
    static func viewFilter(hidden: Set<TaskSource>, alwaysListed: UUID?) -> Listed {
        { task in task.id == alwaysListed || !hidden.contains(task.source) }
    }

    /// The tasks in the task order, top first.
    static func active(_ tasks: [TaskItem], listed: Listed = { _ in true }) -> [TaskItem] {
        tasks.filter { $0.visibility == .active && listed($0) }
    }

    /// How many rows the notch's Tasks popover lists under Up next. The rest are in Brain.
    static let upNextLimit = 6

    /// The notch popover's Up next: the task order without the task being timed, which has its own
    /// Now card, at most `limit` rows, top first.
    static func upNext(_ active: [TaskItem], excluding timed: UUID?, limit: Int = upNextLimit) -> [TaskItem] {
        Array(active.lazy.filter { $0.id != timed }.prefix(max(0, limit)))
    }

    /// How many Up next rows fit: `upNextLimit` on their own, two fewer under a Now card and under
    /// each Log time? card, so the popover stays shorter than the smallest screen it opens on.
    /// Never fewer than 2.
    static func upNextRows(showingNow: Bool, cards: Int) -> Int {
        max(2, upNextLimit - (showingNow ? 2 : 0) - 2 * max(0, cards))
    }

    /// A new task goes to the top.
    static func inserting(_ task: TaskItem, into tasks: [TaskItem]) -> [TaskItem] {
        [task] + tasks
    }

    static func movingToTop(_ id: UUID, in tasks: [TaskItem]) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }), index > 0 else { return tasks }
        var result = tasks
        let task = result.remove(at: index)
        result.insert(task, at: 0)
        return result
    }
}
