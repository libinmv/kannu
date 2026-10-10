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
enum TaskOrdering {
    /// The tasks in the task order, top first.
    static func active(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { $0.visibility == .active }
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

    /// Places the task just before the previous active task. No change at the top.
    static func movingUp(_ id: UUID, in tasks: [TaskItem]) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              let previous = tasks[..<index].lastIndex(where: { $0.visibility == .active }) else { return tasks }
        var result = tasks
        let task = result.remove(at: index)
        result.insert(task, at: previous)
        return result
    }

    /// Places the task just after the next active task. No change at the bottom.
    static func movingDown(_ id: UUID, in tasks: [TaskItem]) -> [TaskItem] {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              let next = tasks[(index + 1)...].firstIndex(where: { $0.visibility == .active }) else { return tasks }
        var result = tasks
        let task = result.remove(at: index)
        // `next` shifted down by one with the removal; inserting at it places the task after it.
        result.insert(task, at: next)
        return result
    }

    /// A drag in the task order (`onMove`), whose offsets count active tasks only. The dragged
    /// tasks land just before the active task that was at `destination`, or after the last active
    /// task when dropped at the end.
    static func moving(activeOffsets offsets: IndexSet, toActiveOffset destination: Int, in tasks: [TaskItem]) -> [TaskItem] {
        let visible = active(tasks)
        let moved = offsets.filter { visible.indices.contains($0) }.map { visible[$0].id }
        guard !moved.isEmpty else { return tasks }
        let movedSet = Set(moved)
        // The first active task at or after the drop point that is not itself being moved.
        let anchor = visible[min(destination, visible.count)...].first { !movedSet.contains($0.id) }?.id

        var result = tasks.filter { !movedSet.contains($0.id) }
        let movedTasks = moved.compactMap { id in tasks.first { $0.id == id } }
        if let anchor, let anchorIndex = result.firstIndex(where: { $0.id == anchor }) {
            result.insert(contentsOf: movedTasks, at: anchorIndex)
        } else if let lastActive = result.lastIndex(where: { $0.visibility == .active }) {
            result.insert(contentsOf: movedTasks, at: lastActive + 1)
        } else {
            result.insert(contentsOf: movedTasks, at: 0)
        }
        return result
    }
}
