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

/// Everything the timer tab's expanded task card says about one task, as text, so the view stays
/// a layout and the words are tested. It reads like the ticket page: the title first, a short key,
/// where the task stands, its labels, then up to four facts in a grid, each with its icon.
///
/// Wording follows Brain › Tasks' row caption (`TasksSettings.progressText`) so the same task
/// reads the same everywhere: "42m of 2h", "10m over", "Jira logged 3h", "Due Today 15:00".
struct TaskDetailSummary: Equatable {
    /// Where a task stands, as the card colours its key pill: to do yellow, in progress green,
    /// closed or ended red.
    enum Phase: Equatable {
        /// To Do, Open, a merge request waiting: not started.
        case toDo
        case inProgress
        /// Closed on its server, marked done, no longer listed by its source, or archived.
        case closed
    }

    struct Status: Equatable {
        /// "To Do", "In Progress", "Open", "Review requested", "Closed" — the source's own word,
        /// or the facet's for a local task. Not shown on the card (its colour is); it is the key
        /// pill's tooltip and what VoiceOver reads.
        let name: String
        let phase: Phase
    }

    /// One cell of the card's fact grid: an SF Symbol and a few words. `isAlert` reads in orange
    /// (overdue, conflicts, a health status that is not on track). A fact with an `action` is a
    /// button on the card.
    struct Fact: Equatable {
        let icon: String
        let text: String
        var isAlert = false
        var action: Action? = nil
    }

    /// What tapping a fact opens.
    enum Action: Equatable {
        /// The merge requests that close the issue (`TasksManager.linkedMergeRequests`).
        case linkedMergeRequests
    }

    /// The issue's title, never prefixed by its key: a GitLab path key would eat the lines.
    let title: String
    /// "PROJ-123", "ds-vendors #4264", "ds-vendors !12"; nil for a local task.
    let shortKey: String?
    let status: Status
    /// A merge request still in draft: a chip of its own beside the status.
    let isDraft: Bool
    /// The source's labels (a scoped `workflow::sprint_backlog` as its value, `sprint_backlog`),
    /// then the user's own tags as "#tag".
    let labels: [String]
    /// Every fact the task has, most important first; the card shows as many as fit (four at
    /// most, two per row).
    let facts: [Fact]
    /// Time against the estimate: "42m of 2h", "42m tracked", "No estimate".
    let time: String
    /// Whether `time` says anything: false with no estimate and nothing tracked, where "No
    /// estimate" beside Start was only noise.
    let showsTime: Bool
    /// "10m over" once a minute or more past the estimate; the view shows it in orange.
    let overtime: String?
    /// A muted line where the facts go, for a local task never timed: without it the card had
    /// nothing between its title and Start.
    let note: String?
    /// Only a local task can be deleted: a remote one would come back on the next sync.
    let canDelete: Bool
    /// "Open in Jira", "Open in GitHub"; nil for a local task or a reminder (`TaskSource.browseLabel`).
    let browseLabel: String?

    /// `selfNames`: the connected accounts' display names and usernames. An assignee or author
    /// that is the user is not shown: the list is the user's own, so "you" said nothing.
    init(task: TaskItem, tracked: Int, now: Date, selfNames: Set<String> = [], calendar: Calendar = .current) {
        title = task.title
        shortKey = Self.shortKey(for: task)

        status = Self.status(of: task)
        isDraft = task.remote?.isDraft == true

        labels = (task.remote?.labels ?? []).map(Self.labelDisplay) + task.tags.map { "#\($0)" }

        let estimate = task.effectiveEstimateSeconds
        let progress = TaskTimeMath.progress(tracked: tracked, estimate: estimate)
        time = progress.text
        showsTime = tracked > 0 || estimate != nil
        overtime = progress.over.map { String(localized: "\(WorkDuration.format($0)) over") }

        facts = Self.facts(for: task, now: now, selfNames: selfNames, calendar: calendar)
        note = task.source == .local && task.segments.isEmpty && tracked == 0
            ? String(localized: "No time recorded yet. Start the task to track it.")
            : nil

        canDelete = task.source == .local
        browseLabel = task.source.browseLabel
    }

    /// Closed when its server says so (`isDoneRemotely`) or it has left the task order (done,
    /// gone, archived); otherwise the facet's To Do or In Progress. The word is the source's own
    /// while it is open; a closed task reads "Done" (local) or "Closed".
    static func status(of task: TaskItem) -> Status {
        if task.visibility != .active || task.remote?.isDoneRemotely == true {
            let word = task.source == .local && task.visibility == .done ? String(localized: "Done") : String(localized: "Closed")
            return Status(name: word, phase: .closed)
        }
        let facet = TaskFacets.status(for: task)
        let phase: Phase = facet == .inProgress ? .inProgress : .toDo
        let phaseName = facet == .inProgress ? TaskStatusFilter.inProgress.localizedName : TaskStatusFilter.toDo.localizedName
        return Status(name: TaskFacets.statusName(for: task) ?? phaseName, phase: phase)
    }

    // MARK: - Facts

    /// In the order they matter on the card: what needs attention and the linked merge requests,
    /// then planning, then who, then activity. A local task has its reminder and its own recorded time instead.
    private static func facts(for task: TaskItem, now: Date, selfNames: Set<String>, calendar: Calendar) -> [Fact] {
        var facts: [Fact] = []
        let remote = task.remote

        if task.source == .local, let scheduled = task.scheduledAt {
            let when = TaskReminderPlan.when(scheduled, now: now, calendar: calendar)
            // A slashed bell when the user turned this task's reminder notification off.
            let icon = task.notifiesForReminder ? "calendar" : "bell.slash"
            facts.append(Fact(icon: icon, text: dueText(scheduled, when: when), isAlert: when == .overdue))
        } else if let due = remote?.dueDate {
            let day = dueDayText(due, now: now, calendar: calendar)
            facts.append(Fact(icon: "calendar", text: day.text, isAlert: day.isOverdue))
        }
        if remote?.hasConflicts == true {
            facts.append(Fact(icon: "exclamationmark.triangle", text: String(localized: "Conflicts"), isAlert: true))
        }
        if let health = remote?.healthStatus.flatMap(healthText) {
            facts.append(Fact(icon: "heart.text.square", text: health.text, isAlert: health.isAlert))
        }
        // Up with what needs attention: it opens the merge requests, so it must be among the four
        // facts the card has room for.
        if let linked = remote?.linkedMergeRequests, linked > 0 {
            facts.append(Fact(icon: "arrow.triangle.pull",
                              text: linked == 1 ? String(localized: "1 linked MR") : String(localized: "\(linked) linked MRs"),
                              action: .linkedMergeRequests))
        }
        if let milestone = remote?.milestone { facts.append(Fact(icon: "flag", text: milestone)) }
        if let iteration = remote?.iteration { facts.append(Fact(icon: "hourglass", text: iteration)) }
        if let weight = remote?.weight { facts.append(Fact(icon: "scalemass", text: String(localized: "Weight \(weight)"))) }
        if let parent = remote?.parentTitle { facts.append(Fact(icon: "square.stack", text: parent)) }
        // Someone else's name is worth a line; the user's own is not (the list is theirs).
        let person = [remote?.author, remote?.assignee].compactMap { $0 }.first { !isSelf($0, selfNames) }
        if let person { facts.append(Fact(icon: "person", text: person)) }
        if let done = remote?.checklistDone, let total = remote?.checklistTotal, total > 0 {
            facts.append(Fact(icon: "checklist", text: String(localized: "\(done) of \(total) done")))
        }
        if let comments = remote?.commentCount, comments > 0 {
            facts.append(Fact(icon: "bubble.left",
                              text: comments == 1 ? String(localized: "1 comment") : String(localized: "\(comments) comments")))
        }
        if let updated = remote?.updatedAt {
            facts.append(Fact(icon: "clock", text: String(localized: "Updated \(ago(updated, now: now, calendar: calendar))")))
        }
        if let priority = remote?.priority { facts.append(Fact(icon: "exclamationmark.circle", text: priority)) }
        if let type = remote?.issueType { facts.append(Fact(icon: "doc.text", text: type)) }
        if let spent = remote?.remoteSpentSeconds, spent > 0 {
            switch task.source {
            case .jira: facts.append(Fact(icon: "checkmark.circle", text: String(localized: "Jira logged \(WorkDuration.format(spent))")))
            case .gitlab: facts.append(Fact(icon: "checkmark.circle", text: String(localized: "GitLab spent \(WorkDuration.format(spent))")))
            case .local, .github, .linear, .todoist, .appleReminders: break
            }
        }
        if task.source == .local, let last = task.segments.map({ $0.end ?? $0.start }).max() {
            facts.append(Fact(icon: "stopwatch", text: String(localized: "Timed \(ago(last, now: now, calendar: calendar))")))
        }
        if task.source == .local, !task.segments.isEmpty {
            let count = task.segments.count
            facts.append(Fact(icon: "list.number", text: count == 1 ? String(localized: "1 session") : String(localized: "\(count) sessions")))
        }
        return facts
    }

    private static func isSelf(_ name: String, _ selfNames: Set<String>) -> Bool {
        selfNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// GitLab's health words: on track is fine; the other two need attention.
    static func healthText(_ status: String) -> (text: String, isAlert: Bool)? {
        switch status {
        case "on_track": return (String(localized: "On track"), false)
        case "needs_attention": return (String(localized: "Needs attention"), true)
        case "at_risk": return (String(localized: "At risk"), true)
        default: return nil
        }
    }

    /// A scoped GitLab label shows its value: `workflow::sprint_backlog` reads `sprint_backlog`.
    static func labelDisplay(_ label: String) -> String {
        guard let range = label.range(of: "::", options: .backwards) else { return label }
        let value = label[range.upperBound...]
        return value.isEmpty ? label : String(value)
    }

    /// "just now", "5m ago", "3h ago", "yesterday", "4d ago", "2w ago", then the day ("12 Aug").
    static func ago(_ date: Date, now: Date, calendar: Calendar) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "just now") }
        if seconds < 3600 { return String(localized: "\(Int(seconds / 60))m ago") }
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "\(Int(seconds / 3600))h ago") }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return String(localized: "yesterday") }
        if days < 14 { return String(localized: "\(days)d ago") }
        if days < 56 { return String(localized: "\(days / 7)w ago") }
        return date.formatted(dayStyle(calendar))
    }

    // MARK: - Chips and key

    /// The chips that fit a character budget, in order, and how many did not. The card itself fits
    /// with `ViewThatFits`; this stays for callers that need a count without a layout.
    func chips(fitting characters: Int) -> (shown: [String], hidden: Int) {
        var shown: [String] = []
        var used = 0
        for label in labels {
            let cost = label.count + 2
            if !shown.isEmpty, used + cost > characters { break }
            shown.append(label)
            used += cost
        }
        return (shown, labels.count - shown.count)
    }

    /// "PROJ-123" as Jira writes it; for GitLab, the project's last path component and the number,
    /// "ds-vendors #4264" / "ds-vendors !12" — the full `group/sub/project#4264` key is what used to
    /// eat the card. A project known only by its id reads "Project 42 #7". Nil for a local task.
    /// `withProject: false` drops the GitLab project, "#4264", where the page already names it.
    /// GitHub reads like GitLab: "repo #7". A source with no keys of its own (Todoist, Reminders)
    /// has none: its `key` is the list the item is in.
    static func shortKey(for task: TaskItem, withProject: Bool = true) -> String? {
        guard let remote = task.remote else { return nil }
        switch task.source.keyStyle {
        case .none, .list:
            return nil
        case .dashed:
            return remote.key
        case .path:
            let number: String
            if let iid = remote.gitlabIID {
                number = (remote.gitlabKind == .mergeRequest ? "!" : "#") + String(iid)
            } else if let marker = remote.key.lastIndex(where: { $0 == "#" || $0 == "!" }), marker > remote.key.startIndex {
                number = String(remote.key[marker...])
            } else {
                return remote.key
            }
            guard withProject, let project = TaskFacets.project(for: task) else { return number }
            return "\(TaskFacets.projectShortName(project)) \(number)"
        }
    }

    // MARK: - Dates

    /// "Due Today 15:00", "Due Tomorrow 09:30", "Overdue Mon 10:00", or "Due Thu 9 Oct, 15:00" —
    /// a local task's reminder, in the words Brain's row uses (`TasksSettings.scheduleText`).
    static func dueText(_ date: Date, when: TaskReminderPlan.When) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        switch when {
        case .today:
            return String(localized: "Due Today \(time)")
        case .tomorrow:
            return String(localized: "Due Tomorrow \(time)")
        case .overdue:
            return String(localized: "Overdue \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
        case .later:
            return String(localized: "Due \(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
        }
    }

    /// A server's date-only due date: "Due today", "Due 20 Oct", or "Overdue 14 Oct" once the day
    /// has passed — a due date has no time, so it is overdue from the next day on.
    static func dueDayText(_ date: Date, now: Date, calendar: Calendar) -> (text: String, isOverdue: Bool) {
        let day = date.formatted(dayStyle(calendar))
        if calendar.isDate(date, inSameDayAs: now) {
            return (String(localized: "Due today"), false)
        }
        if date < calendar.startOfDay(for: now) {
            return (String(localized: "Overdue \(day)"), true)
        }
        return (String(localized: "Due \(day)"), false)
    }

    /// "20 Oct" in the user's locale, in the calendar (and so the time zone) the date was made in.
    static func dayStyle(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: .current, calendar: calendar, timeZone: calendar.timeZone)
            .day()
            .month(.abbreviated)
    }
}

/// The one line under a task's title in Brain's task lists, as segments the view joins with " · "
/// and colours (an alert reads orange). Kept short so a row stays two lines: the short key ("#4326"
/// alone on its project's page), the source's status unless it says nothing (GitLab's "Open"),
/// timing now or paused, time against the estimate and any overtime, when it is due, and the tags.
/// What the source has logged, and every other fact, is on the task's own page.
struct TaskRowCaption: Equatable {
    struct Segment: Equatable {
        let text: String
        var isAlert = false
    }

    enum Timing: Equatable {
        case running
        case paused
    }

    let segments: [Segment]

    init(task: TaskItem, tracked: Int, timing: Timing?, now: Date, onProjectPage: Bool = false,
         calendar: Calendar = .current) {
        var segments: [Segment] = []
        if let key = TaskDetailSummary.shortKey(for: task, withProject: !onProjectPage) {
            segments.append(Segment(text: key))
        }
        // GitLab's "opened" and GitHub's "open" are every open issue's state: they tell one row from
        // another nothing.
        let saysNothing = (task.source == .gitlab && task.remote?.status == "opened")
            || (task.source == .github && task.remote?.status == "open")
        if !saysNothing, let status = TaskFacets.statusName(for: task) {
            segments.append(Segment(text: status))
        }
        switch timing {
        case .running: segments.append(Segment(text: String(localized: "Timing now")))
        case .paused: segments.append(Segment(text: String(localized: "Paused")))
        case nil: break
        }
        // Nothing tracked and no estimate: "No estimate" on every new task was only noise.
        let estimate = task.effectiveEstimateSeconds
        if tracked >= 60 || estimate != nil {
            let progress = TaskTimeMath.progress(tracked: tracked, estimate: estimate)
            segments.append(Segment(text: progress.text))
            if let over = progress.over {
                segments.append(Segment(text: String(localized: "\(WorkDuration.format(over)) over"), isAlert: true))
            }
        }
        if task.source == .local, let scheduled = task.scheduledAt {
            let when = TaskReminderPlan.when(scheduled, now: now, calendar: calendar)
            segments.append(Segment(text: TaskDetailSummary.dueText(scheduled, when: when), isAlert: when == .overdue))
        } else if let due = task.remote?.dueDate {
            let day = TaskDetailSummary.dueDayText(due, now: now, calendar: calendar)
            segments.append(Segment(text: day.text, isAlert: day.isOverdue))
        }
        if !task.tags.isEmpty {
            segments.append(Segment(text: task.tags.map { "#\($0)" }.joined(separator: " ")))
        }
        self.segments = segments
    }

    /// The caption as one string, for VoiceOver and tests.
    var text: String { segments.map(\.text).joined(separator: " · ") }
}

/// A Brain task list's rows, worked out once per render (`TaskRowList`): each task with its colour,
/// whether it is first in the whole task order (Move to Top has nothing to do then), and whether it
/// is being timed. A row reads only this, so each does O(1) work and holds no observer.
///
/// Pure, in the logic target.
struct TaskListRows: Equatable {
    struct Row: Identifiable, Equatable {
        let task: TaskItem
        let color: TaskColor
        /// First in the whole task order (`TasksManager.activeTasks`), which the notch's Up next
        /// reads — not merely the first row of a filtered list.
        let isFirst: Bool
        let timing: TaskRowCaption.Timing?
        var id: UUID { task.id }
    }

    let rows: [Row]
    /// The colour-dot column shows once any listed task has a colour: an all-glass list looks as it
    /// did before colours existed.
    let showsColorDots: Bool

    init(_ tasks: [TaskItem], tagColors: [String: TaskColor], integrationColors: [TaskSource: TaskColor],
         topTaskID: UUID?, timedTaskID: UUID?, timingIsPaused: Bool) {
        rows = tasks.map { task in
            Row(task: task,
                color: TaskColoring.color(of: task, tagColors: tagColors, integrations: integrationColors),
                isFirst: task.id == topTaskID,
                timing: task.id == timedTaskID ? (timingIsPaused ? .paused : .running) : nil)
        }
        showsColorDots = rows.contains { $0.color != .glass }
    }
}
