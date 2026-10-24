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

/// What the timer tab's task form holds while the user types (`TimerTaskForm`): a new task, or an
/// edit of one. Nothing is saved until Add or Save; then `edits(to:)` says what changed, so an
/// edit touches only what the user changed.
///
/// A Jira or GitLab task's title and reminder are not Kannu's to change: the title is the server's
/// and the next sync would put it back, and reminders are for local tasks
/// (`TasksManager.setSchedule`). Its estimate and tags are Kannu's own and can be edited.
///
/// Pure, in the logic target.
struct TaskFormDraft: Equatable {
    /// The chevron's presets, in the notch's task form and Brain's typed estimate (New Task, a
    /// task's Time row, Set Estimate): 15m, 30m, 1h, 2h, 4h, 8h.
    static let estimateChoices = [15, 30, 60, 120, 240, 480].map { $0 * 60 }

    enum Edit: Equatable {
        case title(String)
        case estimate(Int?)
        case tags([String])
        /// The task's reminder notification on or off, before its schedule so a muted reminder is
        /// never sent first and taken back.
        case notifies(Bool)
        case schedule(Date?)
    }

    /// The task being edited; nil for a new one.
    let editing: UUID?
    let source: TaskSource
    /// The source's own estimate, shown when Kannu has none of its own.
    let remoteEstimate: Int?
    var title: String
    /// The estimate kept on Add or Save; what `estimateText` last said readably, or a preset.
    var estimateSeconds: Int?
    /// The estimate as typed in the notch's field: "2d 3h", "90m", "1.5h", "45".
    var estimateText: String
    /// Tags as typed, comma separated: "writing, #urgent".
    var tagsText: String
    var reminder: Date?
    /// Whether the reminder raises a notification; the bell beside it. On for a new task.
    var notifies: Bool

    /// A new local task.
    init() {
        editing = nil
        source = .local
        remoteEstimate = nil
        title = ""
        estimateSeconds = nil
        estimateText = ""
        tagsText = ""
        reminder = nil
        notifies = true
    }

    init(editing task: TaskItem) {
        editing = task.id
        source = task.source
        remoteEstimate = task.remote?.remoteEstimateSeconds
        title = task.title
        estimateSeconds = task.localEstimateSeconds
        estimateText = task.localEstimateSeconds.map(WorkDuration.format) ?? ""
        tagsText = task.tags.joined(separator: ", ")
        reminder = task.scheduledAt
        notifies = task.notifiesForReminder
    }

    var isNew: Bool { editing == nil }

    // MARK: - The timer tab's bar and a new task's title: one text

    /// What the timer tab's session bar shows for `title` (`TimerSessionName`, at most 40
    /// characters); "" when nothing is left.
    static func barText(_ title: String) -> String {
        TimerSessionName.cleaned(title) ?? ""
    }

    /// Whether `bar`, the session bar's text, is this draft's title: the same `TaskItem.nameKey`, so
    /// case, accents and a title cut to the bar's 40 characters still match. Never for an empty bar.
    func isTitled(_ bar: String) -> Bool {
        guard let key = TaskItem.nameKey(bar) else { return false }
        return TaskItem.nameKey(title) == key
    }

    /// The draft New Task opens on, `kept` being the kept new-task draft. An empty bar opens `kept`
    /// (or an empty form). A bar that is `kept`'s title opens it whole. Any other bar text becomes
    /// the title — of `kept`, whose estimate, tags and reminder stay (nothing typed is lost; the user
    /// clears what they do not want), or of a fresh draft.
    static func newTask(bar: String, kept: TaskFormDraft?) -> TaskFormDraft {
        guard let title = TaskItem.cleanedTitle(bar) else { return kept ?? TaskFormDraft() }
        var draft = kept ?? TaskFormDraft()
        if !draft.isTitled(bar) { draft.title = title }
        return draft
    }

    var canEditTitle: Bool { source == .local }
    var canSchedule: Bool { source == .local }

    var tags: [String] { TaskItem.parsedTags(tagsText) }

    /// A new task or a local one needs a title; a remote one keeps its server's. An estimate that
    /// cannot be read is fixed first, never dropped without a word.
    var canSave: Bool {
        (!canEditTitle || TaskItem.cleanedTitle(title) != nil) && estimateReading != .unreadable
    }

    /// What saving changes on `task`, in the order the manager applies it: only what differs.
    func edits(to task: TaskItem) -> [Edit] {
        var edits: [Edit] = []
        if canEditTitle, let cleaned = TaskItem.cleanedTitle(title), cleaned != task.title {
            edits.append(.title(cleaned))
        }
        let estimate = estimateSeconds.flatMap { $0 > 0 ? $0 : nil }
        if estimate != task.localEstimateSeconds { edits.append(.estimate(estimate)) }
        if tags != task.tags { edits.append(.tags(tags)) }
        // The bell belongs to a reminder: without one there is nothing to mute, and clearing the
        // schedule clears the mute (`TasksManager.setSchedule`).
        if canSchedule, reminder != nil, notifies != task.notifiesForReminder { edits.append(.notifies(notifies)) }
        if canSchedule, reminder != task.scheduledAt { edits.append(.schedule(reminder)) }
        return edits
    }

    /// "No estimate", "2h", or the source's own "2h from Jira" while Kannu has none.
    var estimateLabel: String {
        if let estimateSeconds, estimateSeconds > 0 { return WorkDuration.format(estimateSeconds) }
        if let remoteEstimate, remoteEstimate > 0, source != .local {
            return String(localized: "\(WorkDuration.format(remoteEstimate)) from \(source.name)")
        }
        return String(localized: "No estimate")
    }

    // MARK: - The typed estimate

    enum EstimateReading: Equatable {
        /// Nothing typed, or 0: no estimate.
        case none
        case length(Int)
        /// Not a length, or under a minute.
        case unreadable
    }

    /// What the typed text says (`WorkDuration.parse`: "2d 3h" is 19 hours, a day being a workday).
    var estimateReading: EstimateReading {
        let trimmed = estimateText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .none }
        guard let seconds = WorkDuration.parse(trimmed) else { return .unreadable }
        if seconds == 0 { return .none }
        return seconds >= 60 ? .length(seconds) : .unreadable
    }

    /// Typing: the estimate follows the text whenever it reads; while it does not, the last readable
    /// one stays and `canSave` waits.
    mutating func typeEstimate(_ text: String) {
        estimateText = text
        switch estimateReading {
        case .none: estimateSeconds = nil
        case .length(let seconds): estimateSeconds = seconds
        case .unreadable: break
        }
    }

    /// A preset, or none: the field shows it the standard way.
    mutating func chooseEstimate(_ seconds: Int?) {
        estimateSeconds = seconds.flatMap { $0 > 0 ? $0 : nil }
        estimateText = estimateSeconds.map(WorkDuration.format) ?? ""
    }

    /// "= 19h", what a length typed another way comes to; nil when it reads as typed.
    var estimateEcho: String? {
        guard case .length(let seconds) = estimateReading else { return nil }
        let standard = WorkDuration.format(seconds)
        let compact = { (text: String) in text.lowercased().filter { !$0.isWhitespace } }
        return compact(standard) == compact(estimateText) ? nil : "= \(standard)"
    }

    /// Leaving the field: a readable length is written the standard way, nothing becomes empty, and
    /// unreadable text stays to be fixed.
    mutating func settleEstimateText() {
        switch estimateReading {
        case .none: estimateText = ""
        case .length(let seconds): estimateText = WorkDuration.format(seconds)
        case .unreadable: break
        }
    }

    /// The field's prompt while empty: the source's own estimate when Kannu has none, else "Estimate".
    var estimatePrompt: String {
        if let remoteEstimate, remoteEstimate > 0, source != .local {
            return estimateLabel
        }
        return String(localized: "Estimate")
    }

    /// The menu's choices with the current estimate among them, in order, when it is none of them
    /// (a typed one, such as 45m), so the menu can show it as chosen.
    var estimateMenuChoices: [Int] {
        guard let estimateSeconds, estimateSeconds > 0, !Self.estimateChoices.contains(estimateSeconds) else {
            return Self.estimateChoices
        }
        return (Self.estimateChoices + [estimateSeconds]).sorted()
    }

    // MARK: - Tags in use, offered while typing

    /// Where the tag being typed starts: after the last comma or line break.
    private var fragmentStart: String.Index {
        tagsText.lastIndex { $0 == "," || $0 == "\n" }.map { tagsText.index(after: $0) } ?? tagsText.startIndex
    }

    /// The tag being typed: the text after the last comma, trimmed.
    var tagFragment: String {
        String(tagsText[fragmentStart...]).trimmingCharacters(in: .whitespaces)
    }

    /// The tags typed before it.
    var tagsBeforeFragment: [String] {
        TaskItem.parsedTags(String(tagsText[..<fragmentStart]))
    }

    /// Brain's own suggestions (`TaskTagEditing.suggestions`) for the tag being typed, among the tags
    /// in use: the first few with nothing typed, else those that start with it, then those that
    /// contain it, then a new one. Never one already typed; nothing once ten are.
    func tagSuggestions(existing: [String]) -> [TaskTagEditing.Suggestion] {
        TaskTagEditing.suggestions(for: tagFragment, existing: existing, current: tagsBeforeFragment)
    }

    /// A suggestion picked: it takes the place of what was being typed, and a comma follows, ready
    /// for the next one.
    mutating func completeTag(_ tag: String) {
        guard let cleaned = TaskTagEditing.cleaned(tag) else { return }
        let before = String(tagsText[..<fragmentStart]).trimmingCharacters(in: .whitespaces)
        tagsText = (before.isEmpty ? cleaned : before + " " + cleaned) + ", "
    }

    /// Where a new reminder starts: the next whole hour.
    static func defaultReminder(now: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600)
    }

    /// A reminder picked that has passed since moves to the next whole hour, as a fresh "Add a
    /// reminder" would, so Add never saves one that can no longer notify. `keeping` is a reminder
    /// left as it is, overdue or not: an edit's own, unchanged.
    mutating func movePassedReminder(now: Date, calendar: Calendar, keeping kept: Date? = nil) {
        guard let picked = reminder, picked <= now, picked != kept else { return }
        reminder = Self.defaultReminder(now: now, calendar: calendar)
    }
}

/// The task form's unsaved drafts, kept while the form is closed, so what was typed survives the
/// notch closing, another task's form opening, or the × on a new task. In memory only: Add or Save
/// forgets a draft, and so does the × on an edit (that one means "without saving").
///
/// An edit's draft is restored only while its task still reads the way it did when the draft was
/// kept (`baseline`): a task changed elsewhere since, by a sync or in Brain, opens fresh, so an old
/// draft can never undo that change on Save. A draft that changes nothing is not kept.
///
/// Pure, in the logic target.
struct KeptTaskFormDrafts: Equatable {
    private struct Entry: Equatable {
        let draft: TaskFormDraft
        /// `TaskFormDraft(editing:)` of the task when the draft was kept; nil for a new task.
        let baseline: TaskFormDraft?
    }

    /// By the task edited; the nil key is the new task.
    private var entries: [UUID?: Entry] = [:]

    var isEmpty: Bool { entries.isEmpty }

    /// Keeps `draft`, or forgets its slot when it changes nothing: a new task's empty form, or an
    /// edit equal to its task. `baseline` is the edited task's current draft; nil for a new task.
    mutating func keep(_ draft: TaskFormDraft, baseline: TaskFormDraft?) {
        let untouched = draft.isNew ? draft == TaskFormDraft() : draft == baseline
        if untouched || (!draft.isNew && baseline == nil) {
            entries[draft.editing] = nil
        } else {
            entries[draft.editing] = Entry(draft: draft, baseline: draft.isNew ? nil : baseline)
        }
    }

    /// The kept draft for a new task (nil) or the task with `id`, when one is kept and, for an edit,
    /// its task still reads as `baseline` says. A reminder the user picked that has passed since
    /// moves to the next whole hour, as a fresh "Add a reminder" would, so Add never saves one that
    /// can no longer notify; an edit's unchanged reminder (the task's own, overdue or not) is left.
    func draft(editing id: UUID?, baseline: TaskFormDraft?, now: Date, calendar: Calendar) -> TaskFormDraft? {
        guard let entry = entries[id] else { return nil }
        if id != nil {
            guard let baseline, entry.baseline == baseline else { return nil }
        }
        var draft = entry.draft
        draft.movePassedReminder(now: now, calendar: calendar, keeping: id == nil ? nil : baseline?.reminder)
        return draft
    }

    mutating func forget(editing id: UUID?) {
        entries[id] = nil
    }
}

/// What a preset clicked while the timer tab's task form shows does (`TimerTaskForm.startFromForm`).
///
/// Pure, in the logic target.
enum TimerFormStart: Equatable {
    /// The form's task is timed (or added and timed): the form's work is done.
    case started
    /// A new task whose estimate cannot be read: nothing starts, and the form stays to be fixed,
    /// as Add waits, with focus on the estimate.
    case held
    /// The edited task left the list: nothing starts, and the form closes. An edit never falls
    /// through to the bar's text or its pick.
    case gone
    /// A new task with no title: the start goes on as if no form were open, and the form closes
    /// keeping its draft.
    case fallThrough

    /// A new task's form, from its kept draft: added and timed when it can be saved; held while its
    /// estimate cannot be read; falling through with no title.
    static func forNewTask(_ kept: TaskFormDraft?) -> TimerFormStart {
        guard let kept, TaskItem.cleanedTitle(kept.title) != nil else { return .fallThrough }
        return kept.canSave ? .started : .held
    }

    /// An edit's form: its task is timed while it is in the list, saved or not.
    static func forEdit(taskInList: Bool) -> TimerFormStart {
        taskInList ? .started : .gone
    }
}
