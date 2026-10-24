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

import AppKit
import Defaults
import SwiftUI

/// The task rows of a list — a project, a source with one project or none, Local tasks, All tasks —
/// in the task order, narrowed by `filter`. A row is the task's colour dot, its title (two lines at
/// most) and one caption (`TaskRowCaption`), then ▶ or ■ and a › to the task's page. Everything else
/// a task can do is on its page and on the row's right-click menu.
///
/// Rows are not dragged, numbered or stepped up and down (David, 2026-10-23: "no drag and order
/// tasks or numbering"). The menu's Move to Top is the one move — it picks what the notch's Up next
/// shows first — and is a named accessibility action too, the keyboard and VoiceOver path.
///
/// The rows are worked out once per render (`TaskListRows`: each task's colour, whether it is first
/// in the whole order, whether it is timed), so a row does O(1) work and holds no observer of its
/// own. The rows carry no highlight ids (docs/SETTINGS.md); each is `.id(task.id)`, so going back
/// scrolls to it.
struct TaskRowList: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    private let filter: TaskFilter
    private let onProjectPage: Bool
    private let context: TasksPageContext

    init(filter: TaskFilter, onProjectPage: Bool = false, context: TasksPageContext) {
        self.filter = filter
        self.onProjectPage = onProjectPage
        self.context = context
    }

    var body: some View {
        let list = TaskListRows(
            manager.listedTasks(filter),
            tagColors: manager.tagColors,
            integrationColors: manager.integrationColors,
            topTaskID: manager.activeTasks.first?.id,
            timedTaskID: manager.timing?.taskID,
            timingIsPaused: manager.timing?.isPaused ?? false
        )
        let canStart = enableTimerFeature && manager.isReady
        ForEach(list.rows) { row in
            taskRow(row, showsColorDot: list.showsColorDots, canStart: canStart)
                .id(row.id)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func taskRow(_ row: TaskListRows.Row, showsColorDot: Bool, canStart: Bool) -> some View {
        let task = row.task
        let isTimed = row.timing != nil
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                TaskTimingButton(isTimed: isTimed, canStart: canStart,
                                 start: { manager.start(task.id) }, stop: { manager.stopTiming() })
                Button {
                    context.open(.task(task.id))
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show Details")
            }
        } label: {
            if isTimed {
                // Only the row being timed changes on its own, once a minute.
                TimelineView(.everyMinute) { timeline in
                    taskLabel(row, now: timeline.date, showsColorDot: showsColorDot)
                }
            } else {
                taskLabel(row, now: Date(), showsColorDot: showsColorDot)
            }
        }
        .contextMenu {
            Button("Show Details") { context.open(.task(task.id)) }
            Divider()
            moreItems(for: task, isFirst: row.isFirst, isTimed: isTimed)
        }
        // The keyboard and VoiceOver path to the one move, offered while the task is not first.
        .accessibilityActions {
            if !row.isFirst {
                Button("Move to Top") { manager.moveToTop(task.id) }
            }
        }
    }

    @ViewBuilder
    private func moreItems(for task: TaskItem, isFirst: Bool, isTimed: Bool) -> some View {
        // No "…": each acts in place or opens a small sheet (docs/SETTINGS.md).
        Button("Set Estimate") {
            context.sheet.wrappedValue = .estimate(taskID: task.id, title: task.title, draft: TaskFormDraft(editing: task))
        }
        Button("Add Time") {
            context.sheet.wrappedValue = .addTime(taskID: task.id, title: task.title)
        }
        Button("Add Tags") {
            context.sheet.wrappedValue = .tags(taskID: task.id, title: task.title, current: task.tags,
                                               existing: TaskFacets.tags(in: manager.tasks))
        }
        if task.source == .local {
            Button("Schedule") {
                context.sheet.wrappedValue = .schedule(taskID: task.id, title: task.title, current: task.scheduledAt)
            }
            if task.scheduledAt != nil {
                Button("Clear Schedule") { manager.setSchedule(nil, for: task.id) }
            }
        }
        Divider()
        // The one move: first in the whole order, the notch's Up next shows it first.
        Button("Move to Top") { manager.moveToTop(task.id) }
            .disabled(isFirst)
        Divider()
        if task.source == .local {
            Button("Mark Done") { manager.markDone(task.id) }
            Button("Archive") { manager.archive(task.id) }
            Button("Delete", role: .destructive) { context.pendingDelete.wrappedValue = task }
                .disabled(isTimed)
        } else {
            // A remote task is finished in its source, and archived here: that is its delete,
            // since a deleted one would only come back on the next sync.
            if let link = taskOpenLink(for: task, manager: manager) {
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
            // Whether the time recorded on it is offered in Time to log, where its source takes time.
            // Never asking keeps it here.
            if task.source.logsTime {
                if task.logPolicy == .ask {
                    Button("Never Ask to Log") { manager.setAsksToLogTime(false, for: task.id) }
                } else {
                    Button("Ask to Log") { manager.setAsksToLogTime(true, for: task.id) }
                }
            }
            Button("Archive") { manager.archive(task.id) }
        }
    }

    /// The task's colour as a dot (worked out once, `TaskListRows`), then its title and caption. No
    /// dot column while every listed task is glass (`showsColorDot`); in a mixed list a glass task's
    /// dot is empty, so the titles still line up. Two lines at most for each.
    private func taskLabel(_ row: TaskListRows.Row, now: Date, showsColorDot: Bool) -> some View {
        let task = row.task
        let caption = TaskRowCaption(task: task, tracked: manager.trackedSeconds(of: task, now: now), timing: row.timing,
                                     now: now, onProjectPage: onProjectPage)
        return HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.rowContent) {
            if showsColorDot {
                TaskColorDot(color: row.color)
            }
            SettingsRowLabel(Text(verbatim: task.title), description: Self.text(of: caption))
                .lineLimit(2)
        }
    }

    /// The caption's segments joined with " · ", an alert in orange; nil when it says nothing.
    static func text(of caption: TaskRowCaption) -> Text? {
        guard !caption.segments.isEmpty else { return nil }
        var text = Text(verbatim: "")
        for (index, segment) in caption.segments.enumerated() {
            if index > 0 { text = text + Text(verbatim: " · ") }
            let part = Text(verbatim: segment.text)
            text = text + (segment.isAlert ? part.foregroundStyle(.orange) : part)
        }
        return text
    }
}

/// ▶ starts timing the task, ■ stops it; off while it cannot start (the timer off, the task file
/// not ready). Values only — the list or the page passes them — so a row observes nothing.
struct TaskTimingButton: View {
    let isTimed: Bool
    let canStart: Bool
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        if isTimed {
            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop timing")
        } else {
            Button(action: start) {
                Image(systemName: "play.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(!canStart)
            .accessibilityLabel("Start timing")
        }
    }
}

/// A typed estimate, as the notch's task form takes it (`TaskFormDraft`): 45m, 1.5h or 2d 3h, with
/// the presets on a chevron. Text it cannot read turns orange and is never saved; while focused it
/// shows what it understood ("= 19h"); leaving it writes a readable length the standard way. A
/// Jira or GitLab task with none of Kannu's shows its source's ("2h from Jira") as the prompt.
/// Brain's New Task sheet, a task's Time row and the Set Estimate sheet share it.
struct TaskEstimateField: View {
    @Binding var draft: TaskFormDraft
    var onSubmit: () -> Void = {}
    /// The draft after leaving the field or picking a preset, so a caller saves the value it sees
    /// rather than reading state just written.
    var onSettle: (TaskFormDraft) -> Void = { _ in }
    /// Escape; nil leaves Escape to whatever holds the field (a sheet's Cancel).
    var onCancel: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: SettingsMetrics.iconGap) {
            field
            if focused, let echo = draft.estimateEcho {
                Text(verbatim: echo)
                    .settingsDescriptionStyle()
                    .lineLimit(1)
                    .fixedSize()
            }
            Menu {
                Button(String(localized: "No estimate")) { choose(nil) }
                ForEach(draft.estimateMenuChoices, id: \.self) { seconds in
                    Button(WorkDuration.format(seconds)) { choose(seconds) }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Estimate presets")
        }
        .onChange(of: focused) { _, isFocused in
            guard !isFocused else { return }
            var next = draft
            next.settleEstimateText()
            draft = next
            onSettle(next)
        }
    }

    @ViewBuilder
    private var field: some View {
        let text = TextField("Estimate", text: Binding(get: { draft.estimateText }, set: { draft.typeEstimate($0) }),
                             prompt: Text(verbatim: draft.estimatePrompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .foregroundStyle(draft.estimateReading == .unreadable ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .focused($focused)
            .onSubmit(onSubmit)
            .help(Text("Type 45m, 1.5h or 2d 3h"))
            .accessibilityHint(Text(accessibilityHint))
        if let onCancel {
            text.onExitCommand(perform: onCancel)
        } else {
            text
        }
    }

    /// Why Add or Save waits, or what was understood: VoiceOver cannot see the orange.
    private var accessibilityHint: String {
        switch draft.estimateReading {
        case .unreadable: return String(localized: "Not a length. Type 45m, 1.5h or 2d 3h.")
        case .length: return draft.estimateEcho ?? String(localized: "Type 45m, 1.5h or 2d 3h")
        case .none: return String(localized: "Type 45m, 1.5h or 2d 3h")
        }
    }

    private func choose(_ seconds: Int?) {
        var next = draft
        next.chooseEstimate(seconds)
        draft = next
        onSettle(next)
    }
}

/// Add a task: one row whose New Task button opens `NewTaskSheet`, which holds every field a task
/// takes — never fields inline in the list (David, 2026-10-24: "a add task button maybe giving
/// popup"). A new task goes on top. On Local tasks' page and All tasks; `listFilter` is what the
/// list shows, so a task it would hide opens on its own page. ⌘N lives on the tab's Form
/// (`TasksSettings`), since this row may not exist once scrolled away.
struct TaskAddRow: View {
    @ObservedObject private var manager = TasksManager.shared
    let context: TasksPageContext
    var listFilter: TaskFilter = .all

    var body: some View {
        SettingsActionRow("Add a task", description: "Title, estimate, tags and a reminder.") {
            Button("New Task") { context.sheet.wrappedValue = .newTask(listFilter: listFilter) }
                .buttonStyle(.borderedProminent)
                .disabled(!manager.isReady)
        }
    }
}

/// "Open in Jira", "Open in GitHub": the item's page, built from or checked against the task's own
/// site or server (`TasksManager.browseURL`); nil for a task with no page Kannu would open.
@MainActor
func taskOpenLink(for task: TaskItem, manager: TasksManager) -> (title: String, url: URL)? {
    guard let title = task.source.browseLabel, let url = manager.browseURL(for: task) else { return nil }
    return (title, url)
}
