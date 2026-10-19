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
/// a task can do is on its page and on the row's right-click menu, which holds what the ⋯ menu did;
/// Move Up and Move Down are accessibility actions too, the keyboard path that ⋯ gave.
///
/// A row is dragged with `draggable` and dropped on with `dropDestination`, which work inside a
/// grouped `Form` on macOS, where `ForEach.onMove` never drags. Every move — drag, Move Up and Move
/// Down — counts only the rows shown, so a filtered drag lands where it was dropped. The rows carry
/// no highlight ids (docs/SETTINGS.md); each is `.id(task.id)`, so going back scrolls to it.
struct TaskRowList: View {
    @ObservedObject private var manager = TasksManager.shared
    private let filter: TaskFilter
    private let onProjectPage: Bool
    private let context: TasksPageContext
    /// The row being dragged, once the drag has begun: it says which edge the insertion line takes.
    @State private var draggingID: UUID?
    /// The row the pointer is over during a drag.
    @State private var dropTargetID: UUID?

    init(filter: TaskFilter, onProjectPage: Bool = false, context: TasksPageContext) {
        self.filter = filter
        self.onProjectPage = onProjectPage
        self.context = context
    }

    var body: some View {
        let rows = manager.listedTasks(filter)
        // The dot column appears only once a listed task has a colour: an all-glass list looks as
        // it did before colours existed.
        let showsColorDots = rows.contains { manager.color(of: $0) != .glass }
        ForEach(rows) { task in
            draggableRow(task, showsColorDot: showsColorDots)
                .id(task.id)
        }
    }

    // MARK: - Drag and drop

    /// A task row that can be dragged onto another, with an insertion line while it is targeted:
    /// above the row when the dragged task comes from below, below it when it comes from above.
    private func draggableRow(_ task: TaskItem, showsColorDot: Bool) -> some View {
        let edge = dropTargetID == task.id ? insertionEdge(onto: task.id) : nil
        return taskRow(task, showsColorDot: showsColorDot)
            .draggable(dragPayload(for: task.id))
            .dropDestination(for: String.self) { items, _ in
                defer {
                    draggingID = nil
                    dropTargetID = nil
                }
                guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                manager.move(id, onto: task.id, filter: filter)
                return true
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetID = task.id
                } else if dropTargetID == task.id {
                    dropTargetID = nil
                }
            }
            .overlay(alignment: edge == .below ? .bottom : .top) {
                if edge != nil {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
    }

    /// The drag's payload, the task's id. Evaluated when the drag begins, so it also notes which row
    /// is moving — after the current update, never during one.
    private func dragPayload(for id: UUID) -> String {
        DispatchQueue.main.async { draggingID = id }
        return id.uuidString
    }

    /// Where the insertion line goes; a drag Kannu has not seen begin yet shows it on top.
    private func insertionEdge(onto target: UUID) -> TaskOrdering.DropEdge? {
        guard let draggingID else { return .above }
        return manager.dropEdge(dragging: draggingID, onto: target, filter: filter)
    }

    // MARK: - Rows

    @ViewBuilder
    private func taskRow(_ task: TaskItem, showsColorDot: Bool) -> some View {
        let isTimed = manager.timing?.taskID == task.id
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                TaskTimingButton(task: task)
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
                    taskLabel(task, now: timeline.date, showsColorDot: showsColorDot)
                }
            } else {
                taskLabel(task, now: Date(), showsColorDot: showsColorDot)
            }
        }
        .contextMenu {
            Button("Show Details") { context.open(.task(task.id)) }
            Divider()
            moreItems(for: task, isTimed: isTimed)
        }
        .accessibilityAction(named: Text("Move Up")) { manager.moveUp(task.id, filter: filter) }
        .accessibilityAction(named: Text("Move Down")) { manager.moveDown(task.id, filter: filter) }
    }

    @ViewBuilder
    private func moreItems(for task: TaskItem, isTimed: Bool) -> some View {
        let order = manager.listedTasks(filter)
        let position = order.firstIndex { $0.id == task.id }
        // No "…": each acts in place or opens a small sheet (docs/SETTINGS.md).
        Button("Set Estimate") {
            context.sheet.wrappedValue = .estimate(taskID: task.id, title: task.title, current: task.localEstimateSeconds)
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
        Button("Move to Top") { manager.moveToTop(task.id) }
            .disabled(position == 0)
        Button("Move Up") { manager.moveUp(task.id, filter: filter) }
            .disabled(position == 0)
        Button("Move Down") { manager.moveDown(task.id, filter: filter) }
            .disabled(position == order.count - 1)
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
            // Whether the time recorded on it is offered in Time to log. Never asking keeps it here.
            if task.logPolicy == .ask {
                Button("Never Ask to Log") { manager.setAsksToLogTime(false, for: task.id) }
            } else {
                Button("Ask to Log") { manager.setAsksToLogTime(true, for: task.id) }
            }
            Button("Archive") { manager.archive(task.id) }
        }
    }

    /// The task's colour as a dot, then its title and caption (`TasksManager.color(of:)`). No dot
    /// column while every listed task is glass (`showsColorDot`); in a mixed list a glass task's
    /// dot is empty, so the titles still line up. Two lines at most for each.
    private func taskLabel(_ task: TaskItem, now: Date, showsColorDot: Bool) -> some View {
        let timing: TaskRowCaption.Timing? = manager.timing.flatMap { timing in
            timing.taskID == task.id ? (timing.isPaused ? .paused : .running) : nil
        }
        let caption = TaskRowCaption(task: task, tracked: manager.trackedSeconds(of: task, now: now), timing: timing,
                                     now: now, onProjectPage: onProjectPage)
        return HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.rowContent) {
            if showsColorDot {
                TaskColorDot(color: manager.color(of: task))
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

/// ▶ starts timing the task, ■ stops it. Off while the timer is off or the task file is not ready.
struct TaskTimingButton: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    let task: TaskItem

    var body: some View {
        if manager.timing?.taskID == task.id {
            Button {
                manager.stopTiming()
            } label: {
                Image(systemName: "stop.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Stop timing")
        } else {
            Button {
                manager.start(task.id)
            } label: {
                Image(systemName: "play.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            .disabled(!enableTimerFeature || !manager.isReady)
            .accessibilityLabel("Start timing")
        }
    }
}

/// Add a task: a title and an optional estimate, from the presets or Custom. On Local tasks' page
/// and All tasks.
struct TaskAddRow: View {
    @ObservedObject private var manager = TasksManager.shared
    let context: TasksPageContext

    var body: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                TextField("Task title", text: context.newTitle, prompt: Text("What needs doing?"))
                    .labelsHidden()
                    .onSubmit(addTask)
                estimateMenu
                Button("Add", action: addTask)
                    .disabled(!manager.isReady || TaskItem.cleanedTitle(context.newTitle.wrappedValue) == nil)
            }
        } label: {
            SettingsRowLabel("Add a task", description: "Title and optional estimate.")
        }
    }

    private var estimateMenu: some View {
        let estimate = context.newEstimate.wrappedValue
        return Menu {
            Button(String(localized: "No estimate")) { context.newEstimate.wrappedValue = nil }
            ForEach(TaskFormDraft.estimateChoices, id: \.self) { seconds in
                Button(WorkDuration.format(seconds)) { context.newEstimate.wrappedValue = seconds }
            }
            Divider()
            Button(String(localized: "Custom")) { context.sheet.wrappedValue = .customEstimateForNewTask(current: estimate) }
        } label: {
            Text(estimate.map(WorkDuration.format) ?? String(localized: "No estimate"))
        }
        .fixedSize()
        .accessibilityLabel("Estimate")
    }

    private func addTask() {
        if manager.addTask(title: context.newTitle.wrappedValue, estimateSeconds: context.newEstimate.wrappedValue) != nil {
            context.newTitle.wrappedValue = ""
            context.newEstimate.wrappedValue = nil
        }
    }
}

/// Open in Jira or Open in GitLab, with the page built from (Jira) or checked against (GitLab) the
/// task's own site or server; nil for a local task or a page Kannu would not open.
@MainActor
func taskOpenLink(for task: TaskItem, manager: TasksManager) -> (title: LocalizedStringKey, url: URL)? {
    if let url = manager.jiraBrowseURL(for: task) { return ("Open in Jira", url) }
    if let url = manager.gitlabBrowseURL(for: task) { return ("Open in GitLab", url) }
    return nil
}
