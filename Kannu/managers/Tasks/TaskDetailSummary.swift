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
    /// (overdue, conflicts, a health status that is not on track).
    struct Fact: Equatable {
        let icon: String
        let text: String
        var isAlert = false
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
    /// Only a local task can be deleted: a remote one would come back on the next sync.
    let canDelete: Bool
    /// "Open in Jira" / "Open in GitLab"; nil for a local task.
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

        canDelete = task.source == .local
        switch task.source {
        case .local: browseLabel = nil
        case .jira: browseLabel = String(localized: "Open in Jira")
        case .gitlab: browseLabel = String(localized: "Open in GitLab")
        }
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

    /// In the order they matter on a 240 pt card: what needs attention, then planning, then who,
    /// then activity. A local task has its reminder and its own recorded time instead.
    private static func facts(for task: TaskItem, now: Date, selfNames: Set<String>, calendar: Calendar) -> [Fact] {
        var facts: [Fact] = []
        let remote = task.remote

        if task.source == .local, let scheduled = task.scheduledAt {
            let when = TaskReminderPlan.when(scheduled, now: now, calendar: calendar)
            facts.append(Fact(icon: "calendar", text: dueText(scheduled, when: when), isAlert: when == .overdue))
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
        if let milestone = remote?.milestone { facts.append(Fact(icon: "flag", text: milestone)) }
        if let iteration = remote?.iteration { facts.append(Fact(icon: "arrow.triangle.2.circlepath", text: iteration)) }
        if let weight = remote?.weight { facts.append(Fact(icon: "scalemass", text: String(localized: "Weight \(weight)"))) }
        if let parent = remote?.parentTitle { facts.append(Fact(icon: "square.stack", text: parent)) }
        // Someone else's name is worth a line; the user's own is not (the list is theirs).
        let person = [remote?.author, remote?.assignee].compactMap { $0 }.first { !isSelf($0, selfNames) }
        if let person { facts.append(Fact(icon: "person", text: person)) }
        if let done = remote?.checklistDone, let total = remote?.checklistTotal, total > 0 {
            facts.append(Fact(icon: "checklist", text: String(localized: "\(done) of \(total) done")))
        }
        if let linked = remote?.linkedMergeRequests, linked > 0 {
            facts.append(Fact(icon: "arrow.triangle.pull",
                              text: linked == 1 ? String(localized: "1 linked MR") : String(localized: "\(linked) linked MRs")))
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
            case .local: break
            }
        }
        if task.source == .local, let last = task.segments.map({ $0.end ?? $0.start }).max() {
            facts.append(Fact(icon: "clock.arrow.circlepath", text: String(localized: "Timed \(ago(last, now: now, calendar: calendar))")))
        }
        if task.source == .local, !task.segments.isEmpty {
            let count = task.segments.count
            facts.append(Fact(icon: "repeat", text: count == 1 ? String(localized: "1 session") : String(localized: "\(count) sessions")))
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
    static func shortKey(for task: TaskItem) -> String? {
        guard let remote = task.remote else { return nil }
        switch task.source {
        case .local:
            return nil
        case .jira:
            return remote.key
        case .gitlab:
            guard let iid = remote.gitlabIID else { return remote.key }
            let mark = remote.gitlabKind == .mergeRequest ? "!" : "#"
            guard let project = TaskFacets.project(for: task) else { return mark + String(iid) }
            let name = project.hasPrefix(TaskFacets.projectIDPrefix)
                ? TaskFacets.projectName(project)
                : String(project.split(separator: "/").last ?? Substring(project))
            return "\(name) \(mark)\(iid)"
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
