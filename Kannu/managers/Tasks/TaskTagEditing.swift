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

/// What the Tags sheet (Add Tags on a task) offers and does, one tag at a time. Pure, so the logic
/// target tests it. Every tag is cleaned by `TaskItem.cleanedTags` — trimmed, a leading "#"
/// dropped, at most `TaskItem.maxTagLength` characters, compared ignoring case, at most
/// `TaskItem.maxTags` on one task — so the sheet can never hold a tag the task would not keep.
enum TaskTagEditing {
    /// One line under the field: a tag already in use somewhere, or a new one.
    enum Suggestion: Hashable {
        /// "#name": a tag another task (or this one, earlier) already uses.
        case use(String)
        /// "Create tag “name”": the typed text, cleaned, when no task uses it yet.
        case create(String)

        /// The tag a pick adds.
        var tag: String {
            switch self {
            case .use(let tag), .create(let tag): return tag
            }
        }
    }

    /// With nothing typed, this many existing tags show as quick picks.
    static let quickPickCount = 5
    /// At most this many existing tags match what is typed.
    static let matchCount = 6

    /// One tag as a task keeps it, or nil when nothing is left of it.
    static func cleaned(_ typed: String) -> String? {
        TaskItem.cleanedTags([typed]).first
    }

    /// What the sheet lists under the field. With nothing typed: the first `quickPickCount` tags in
    /// use. With text: the tags in use that start with it, then those that contain it (each in the
    /// order `existing` gives), then "Create" when no tag in use is the text itself. Tags already on
    /// this task are never offered; text that is one of them offers nothing, so Return cannot add a
    /// longer tag that merely contains it. Nothing is offered once the task has `TaskItem.maxTags`.
    static func suggestions(for typed: String, existing: [String], current: [String]) -> [Suggestion] {
        guard current.count < TaskItem.maxTags else { return [] }
        let onTask = Set(current.map { $0.lowercased() })
        var seen = Set<String>()
        var pool: [String] = []
        var inUse = Set<String>()
        for raw in existing {
            guard let tag = cleaned(raw) else { continue }
            let key = tag.lowercased()
            inUse.insert(key)
            if !onTask.contains(key), seen.insert(key).inserted { pool.append(tag) }
        }
        guard let query = cleaned(typed) else {
            return pool.prefix(quickPickCount).map(Suggestion.use)
        }
        let wanted = query.lowercased()
        guard !onTask.contains(wanted) else { return [] }
        let starting = pool.filter { $0.lowercased().hasPrefix(wanted) }
        let containing = pool.filter { !$0.lowercased().hasPrefix(wanted) && $0.lowercased().contains(wanted) }
        var result = (starting + containing).prefix(matchCount).map(Suggestion.use)
        if !inUse.contains(wanted) {
            result.append(.create(query))
        }
        return result
    }

    /// What Return (or Done, with text still in the field) adds from `suggestions`: a tag in use that
    /// starts with what is typed — the first, as they rank first — or else the typed text as a new
    /// tag. A tag that only contains the text ("review" for "view") needs a click. Nil with nothing
    /// typed, so Return never adds a quick pick nobody chose.
    static func returnPick(for typed: String, in suggestions: [Suggestion]) -> Suggestion? {
        guard let query = cleaned(typed) else { return nil }
        let wanted = query.lowercased()
        if let first = suggestions.first, case .use(let tag) = first, tag.lowercased().hasPrefix(wanted) {
            return first
        }
        return suggestions.first { if case .create = $0 { return true } else { return false } }
    }

    /// The task's tags with `tag` added at the end: cleaned, never a second spelling of one it has,
    /// never past `TaskItem.maxTags`.
    static func adding(_ tag: String, to current: [String]) -> [String] {
        TaskItem.cleanedTags(current + [tag])
    }

    /// The task's tags without `tag`, compared ignoring case.
    static func removing(_ tag: String, from current: [String]) -> [String] {
        current.filter { $0.lowercased() != tag.lowercased() }
    }

    // MARK: - Order

    /// The task's tags with `tag` (compared ignoring case, kept in its own spelling) taken out and
    /// put back at `index` — clamped to the list, so past either end is the first or last place.
    /// Every other tag keeps its order. Unchanged when the task does not carry `tag`, so a drop of
    /// text from elsewhere moves nothing. A drag onto a later pill lands after it, onto an earlier
    /// one before it: the dragged tag takes that pill's place.
    static func moving(_ tag: String, to index: Int, in tags: [String]) -> [String] {
        guard let from = tags.firstIndex(where: { $0.lowercased() == tag.lowercased() }) else { return tags }
        var result = tags
        let moved = result.remove(at: from)
        result.insert(moved, at: min(max(index, 0), result.count))
        return result
    }

    /// The task's tags with `tag` first: the tag that gives the task its colour.
    static func movingToFront(_ tag: String, in tags: [String]) -> [String] {
        moving(tag, to: 0, in: tags)
    }
}
