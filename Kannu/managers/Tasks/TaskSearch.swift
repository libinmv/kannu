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

/// The timer tab's task search: what the user types narrows the list as they type, in memory. A
/// few hundred tasks at most, so a plain scan is microseconds and needs no index or debounce.
///
/// A task matches when every word typed is found in one of its words-to-search: the title, the
/// source's key and the card's short key ("PROJ-123", "group/app#42", "app #42"), the user's tags
/// and the source's labels, a scoped label also by its value. `localizedStandardContains`, so case
/// and diacritics never matter ("cafe" finds "Café"), as in Finder.
///
/// Pure, in the logic target.
enum TaskSearch {
    static func matches(_ task: TaskItem, query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let fields = searchable(task)
        return words.allSatisfy { word in
            fields.contains { $0.localizedStandardContains(word) }
        }
    }

    /// The tasks that match, in the order given.
    static func filter(_ tasks: [TaskItem], query: String) -> [TaskItem] {
        guard !query.allSatisfy(\.isWhitespace) else { return tasks }
        return tasks.filter { matches($0, query: query) }
    }

    private static func searchable(_ task: TaskItem) -> [String] {
        var fields = [task.title]
        if let key = task.remote?.key { fields.append(key) }
        if let short = TaskDetailSummary.shortKey(for: task) { fields.append(short) }
        fields += task.tags
        for label in task.remote?.labels ?? [] {
            fields.append(label)
            fields.append(TaskDetailSummary.labelDisplay(label))
        }
        return fields
    }
}
