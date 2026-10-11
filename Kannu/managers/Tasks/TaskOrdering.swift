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
/// nothing re-sorts it.
///
/// Done, hidden and gone tasks keep their place in the array, so reopening one puts it back where
/// it was. The moves below therefore step over them: Move Up swaps with the previous *active* task,
/// so one click always changes what the user sees.
///
/// The same goes for tasks of a source the user switched off (Local tasks, Sync Jira, Sync GitLab): `listed`
/// says which active tasks are on screen, and every move and drop counts only those. Its default
/// lists every active task.
enum TaskOrdering {
    typealias Listed = (TaskItem) -> Bool

    /// Which tasks the task order shows, by source. The task being timed always shows, so it can be
    /// stopped from the list. Jira and GitLab tasks show while their source is synced, and also
    /// while it is not connected at all: tasks kept after a disconnect stay where the user can see
    /// them. `showGitLabMergeRequests` (Include merge requests) narrows the GitLab tasks the same way,
    /// so switching it off takes the merge requests out at once, without waiting for a sync.
    static func listedFilter(showLocal: Bool, showJira: Bool, showGitLab: Bool, showGitLabMergeRequests: Bool, alwaysListed: UUID?) -> Listed {
        { task in
            if task.id == alwaysListed { return true }
            switch task.source {
            case .local: return showLocal
            case .jira: return showJira
            case .gitlab: return showGitLab && (showGitLabMergeRequests || task.remote?.gitlabKind != .mergeRequest)
            }
        }
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

    /// Places the task just before the previous listed active task. No change at the top.
    static func movingUp(_ id: UUID, in tasks: [TaskItem], listed: Listed = { _ in true }) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              let previous = tasks[..<index].lastIndex(where: { $0.visibility == .active && listed($0) }) else { return tasks }
        var result = tasks
        let task = result.remove(at: index)
        result.insert(task, at: previous)
        return result
    }

    /// Places the task just after the next listed active task. No change at the bottom.
    static func movingDown(_ id: UUID, in tasks: [TaskItem], listed: Listed = { _ in true }) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              let next = tasks[(index + 1)...].firstIndex(where: { $0.visibility == .active && listed($0) }) else { return tasks }
        var result = tasks
        let task = result.remove(at: index)
        // `next` shifted down by one with the removal; inserting at it places the task after it.
        result.insert(task, at: next)
        return result
    }

    /// Where a dragged row lands relative to the row it is dropped on.
    enum DropEdge: Equatable {
        /// Dragged up: it lands just above the target.
        case above
        /// Dragged down: it lands just below the target.
        case below
    }

    /// Which side of `target` the dragged task lands on, counting listed active tasks only; nil
    /// when the drop would change nothing (onto itself, or either task not on screen).
    static func dropEdge(dragging id: UUID, onto target: UUID, in tasks: [TaskItem], listed: Listed = { _ in true }) -> DropEdge? {
        guard id != target else { return nil }
        let visible = active(tasks, listed: listed)
        guard let from = visible.firstIndex(where: { $0.id == id }),
              let to = visible.firstIndex(where: { $0.id == target }) else { return nil }
        return from < to ? .below : .above
    }

    /// A drop of the task `id` on the row of `target`: the dragged task takes the target's place.
    /// Dragged down, it lands just after the target; dragged up, just before it. Only listed active
    /// tasks count (`listed` carries the Task list's filters), so a drop never moves a task the user
    /// cannot see, and done, hidden and filtered-out tasks keep their places in the file.
    static func move(id: UUID, onto target: UUID, in tasks: [TaskItem], listed: Listed = { _ in true }) -> [TaskItem] {
        guard let edge = dropEdge(dragging: id, onto: target, in: tasks, listed: listed),
              let from = tasks.firstIndex(where: { $0.id == id }) else { return tasks }
        var result = tasks
        let task = result.remove(at: from)
        guard let anchor = result.firstIndex(where: { $0.id == target }) else { return tasks }
        result.insert(task, at: edge == .above ? anchor : anchor + 1)
        return result
    }
}
