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

// MARK: - The typed search under the timer tab's bar and a new task's title

extension TaskSearch {
    /// How many tasks the typed search offers (`TimerTaskSuggestions`), before its New row: with
    /// that row, three rows end above Start and Reset, and above the form's buttons.
    static let suggestionLimit = 2
    /// The fewest characters it searches for: one letter matches nearly every task.
    static let suggestionMinimumLength = 2

    /// The tasks offered for `typed`, best first: the same title (`TaskItem.nameKey`), then titles
    /// that start with it, then any other match (a word of the title, a key, a tag, a label). Each
    /// group keeps the order given, the user's own. Nothing under the minimum length.
    static func suggestions(_ tasks: [TaskItem], typed: String, limit: Int = suggestionLimit) -> [TaskItem] {
        guard let query = TaskItem.cleanedTitle(typed), query.count >= suggestionMinimumLength else { return [] }
        let key = TaskItem.nameKey(query)
        let start = folded(query)
        var same: [TaskItem] = [], starting: [TaskItem] = [], other: [TaskItem] = []
        for task in tasks where matches(task, query: query) {
            if TaskItem.nameKey(task.title) == key {
                same.append(task)
            } else if folded(task.title).hasPrefix(start) {
                starting.append(task)
            } else {
                other.append(task)
            }
        }
        return Array((same + starting + other).prefix(max(0, limit)))
    }

    /// A whole title, case and accents ignored, for the "starts with" group.
    private static func folded(_ text: String) -> String {
        (TaskItem.cleanedTitle(text) ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The typed search's list where it shows, under the timer tab's bar or a new task's title: its
/// rows, the row the keyboard highlights, and the text it was closed on.
///
/// Pure, in the logic target.
struct TaskSuggestionState: Equatable {
    enum Row: Hashable {
        case task(id: UUID, title: String)
        /// `New task "…"`: what was typed, kept as a new task.
        case newTask(String)
    }

    private(set) var rows: [Row] = []
    /// Nil until ↑ or ↓, so Return keeps the field's own meaning until the user moves.
    private(set) var highlighted: Int?
    /// The pointer is on the list: it stays while a click lands, though the field lets go of focus.
    var isHovered = false
    /// The text Esc, Return, Tab or a pick closed the list on; it shows again once the text differs.
    private(set) var closedOn: String?

    init(closedOn: String? = nil) {
        self.closedOn = closedOn
    }

    /// The rows for the tasks found for `typed`: none without a task, so a name that matches
    /// nothing leaves the composer alone; else the tasks, then the New row.
    static func rows(for tasks: [TaskItem], typed: String) -> [Row] {
        guard !tasks.isEmpty, let name = TaskItem.cleanedTitle(typed) else { return [] }
        return tasks.map { Row.task(id: $0.id, title: $0.title) } + [.newTask(name)]
    }

    func isClosed(for typed: String) -> Bool {
        closedOn == typed
    }

    /// Whether the list shows for its field: `enabled` (the bar with tasks on and nothing picked; a
    /// new task's title), text typed, the field focused or the pointer on the list while no other
    /// field has focus, and not closed on this text. With no rows there is nothing to show.
    func shows(enabled: Bool, typed: String, fieldFocused: Bool, otherFieldFocused: Bool = false) -> Bool {
        wantsToShow(enabled: enabled, typed: typed, fieldFocused: fieldFocused, otherFieldFocused: otherFieldFocused)
            && !rows.isEmpty
    }

    /// `shows`, before the rows are known: the list is in place, to find them.
    func wantsToShow(enabled: Bool, typed: String, fieldFocused: Bool, otherFieldFocused: Bool = false) -> Bool {
        enabled && !typed.isEmpty && (fieldFocused || (isHovered && !otherFieldFocused)) && !isClosed(for: typed)
    }

    /// What a key does while the field has the list.
    enum KeyAnswer: Equatable {
        /// The highlighted row is picked.
        case pick(Row)
        /// The list closes; the key does nothing else.
        case closeList
        /// The field's own meaning: Return leaves the bar or adds; Escape leaves the form.
        case passOn
    }

    /// Return picks the highlighted row while the list shows; else it keeps its own meaning.
    func answerReturn(showing: Bool) -> KeyAnswer {
        if showing, let row = highlightedRow { return .pick(row) }
        return .passOn
    }

    /// Escape closes a showing list first; else it keeps its own meaning.
    func answerEscape(showing: Bool) -> KeyAnswer {
        showing ? .closeList : .passOn
    }

    var highlightedRow: Row? {
        highlighted.flatMap { rows.indices.contains($0) ? rows[$0] : nil }
    }

    /// New rows. A highlight stays only on the same row in the same place, so Return never picks a
    /// task that moved under it (a sync reordering the list).
    mutating func show(_ new: [Row]) {
        if let index = highlighted,
           !(rows.indices.contains(index) && new.indices.contains(index) && rows[index] == new[index]) {
            highlighted = nil
        }
        rows = new
    }

    /// The text changed: no highlight, and a list closed on other text may show again.
    mutating func textChanged(to typed: String) {
        highlighted = nil
        if closedOn != typed { closedOn = nil }
    }

    mutating func close(on typed: String) {
        closedOn = typed
        highlighted = nil
        isHovered = false
    }

    /// ↓ with nothing highlighted: the first row; ↑: the last (New). ↑ from the first row: nothing
    /// again; ↓ stops at the last. False with no rows, so the caret keeps the key.
    mutating func move(_ step: Int) -> Bool {
        guard !rows.isEmpty, step != 0 else { return false }
        switch (highlighted, step > 0) {
        case (nil, true): highlighted = 0
        case (nil, false): highlighted = rows.count - 1
        case (let index?, true): highlighted = min(index + 1, rows.count - 1)
        case (let index?, false): highlighted = index == 0 ? nil : index - 1
        }
        return true
    }
}
