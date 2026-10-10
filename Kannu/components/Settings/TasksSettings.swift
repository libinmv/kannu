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

import Defaults
import SwiftUI

/// Brain › Tasks: the task list in the order the user will work through it, an estimate per task,
/// and the actual time recorded when a task is timed with Kannu's timer.
///
/// Built only from the `SettingsComponents` shapes (docs/SETTINGS.md). A task row carries a ▶ and a
/// `SettingsMoreMenu`, so it is a raw `LabeledContent` with a `SettingsRowLabel` — the `analysisRow`
/// shape — never a `SettingsRow`, whose `.labelsHidden()` would erase the menu. Task titles are the
/// user's own text and render verbatim.
///
/// With tasks off nothing here touches `TasksManager`, so the tab never reads the task file.
struct TasksSettings: View {
    @Default(.enableTasks) private var enableTasks
    @Default(.tasksDefaultSessionMinutes) private var defaultSessionMinutes

    // On the Form, not on a row: rows of a long, lazy Form may not exist when these change.
    @State private var sheet: TaskSheet?
    @State private var pendingDelete: TaskItem?
    @State private var newTitle = ""
    @State private var newEstimate: Int?

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    var body: some View {
        Form {
            Section {
                SettingsRow("Enable tasks", description: "Keep a list of what you are working on, in the order you will do it. Time a task with Kannu's timer and its actual time is recorded.") {
                    Defaults.Toggle(key: .enableTasks) {
                        Text("Enable tasks")
                    }
                }
                .settingsHighlight(id: highlightID("Enable tasks"))

                SettingsStepperRow(
                    "Default session length",
                    description: "How long a task's timer runs when the task has no estimate, or has used it up.",
                    value: $defaultSessionMinutes,
                    in: 5...240,
                    step: 5,
                    valueText: Text("\(defaultSessionMinutes) min")
                )
                .settingsHighlight(id: highlightID("Default session length"))

                SettingsRow("Sound when the estimate is reached", description: "Plays the timer sound when a task's timer runs out. Off: the timer runs on past the estimate silently, and that time still counts.") {
                    Defaults.Toggle(key: .tasksSoundAtEstimate) {
                        Text("Sound when the estimate is reached")
                    }
                }
                .settingsHighlight(id: highlightID("Sound when the estimate is reached"))
            } header: {
                SettingsSectionHeader("Tasks")
            } footer: {
                SettingsFooter("Tasks and their recorded time stay on this Mac. Nothing is sent anywhere.")
            }

            if enableTasks {
                TaskListSections(
                    sheet: $sheet,
                    pendingDelete: $pendingDelete,
                    newTitle: $newTitle,
                    newEstimate: $newEstimate
                )
            }
        }
        .navigationTitle("Tasks")
        .sheet(item: $sheet) { sheet in
            TaskValueSheet(sheet: sheet) { value in apply(value, from: sheet) }
        }
        .alert(
            Text(verbatim: String(localized: "Delete “\(pendingDelete?.title ?? "")”?")),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button("Delete", role: .destructive) { TasksManager.shared.delete(task.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The time recorded on it is deleted too.")
        }
    }

    private func apply(_ value: TaskValueSheet.Value, from sheet: TaskSheet) {
        switch (sheet, value) {
        case (.customEstimateForNewTask, .duration(let seconds)):
            newEstimate = seconds
        case (.estimate(let taskID, _, _), .duration(let seconds)):
            TasksManager.shared.setEstimate(seconds, for: taskID)
        case (.addTime(let taskID, _), .duration(let seconds)):
            if let seconds { TasksManager.shared.addManualTime(seconds, to: taskID) }
        case (.endTime(let taskID, let segmentID, _, _), .date(let end)):
            TasksManager.shared.setEndTime(end, segmentID: segmentID, taskID: taskID)
        default:
            break
        }
    }
}

/// Everything below the switches. A separate view so `TasksManager` is created only once tasks
/// are turned on.
private struct TaskListSections: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    @Binding private var sheet: TaskSheet?
    @Binding private var pendingDelete: TaskItem?
    @Binding private var newTitle: String
    @Binding private var newEstimate: Int?
    @State private var showsDoneAndHidden = false

    private static let estimateChoices = [15, 30, 60, 120, 240, 480].map { $0 * 60 }

    init(sheet: Binding<TaskSheet?>, pendingDelete: Binding<TaskItem?>, newTitle: Binding<String>, newEstimate: Binding<Int?>) {
        _sheet = sheet
        _pendingDelete = pendingDelete
        _newTitle = newTitle
        _newEstimate = newEstimate
    }

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    var body: some View {
        if case .failed(let reason) = manager.loadState {
            Section {
                SettingsErrorText(String(localized: "Kannu could not read its task list, so nothing here can change until it can. \(reason)"))
            } header: {
                SettingsSectionHeader("Task list")
            }
        }
        interruptedSection
        taskOrderSection
        doneAndHiddenSection
    }

    // MARK: - Interrupted sessions

    @ViewBuilder
    private var interruptedSection: some View {
        let interrupted = manager.interruptedSessions
        if !interrupted.isEmpty {
            Section {
                ForEach(interrupted) { entry in
                    LabeledContent {
                        HStack(spacing: SettingsMetrics.rowContent) {
                            Button("Set End Time…") {
                                sheet = .endTime(taskID: entry.task.id, segmentID: entry.segment.id, title: entry.task.title, start: entry.segment.start)
                            }
                            Button("Discard") {
                                manager.discardInterruptedSession(segmentID: entry.segment.id, taskID: entry.task.id)
                            }
                        }
                    } label: {
                        SettingsRowLabel(
                            Text(verbatim: entry.task.title),
                            description: Text(verbatim: String(localized: "Was being timed when Kannu stopped, from \(entry.segment.start.formatted(date: .abbreviated, time: .shortened))"))
                        )
                    }
                }
            } header: {
                SettingsSectionHeader("Interrupted sessions")
            } footer: {
                SettingsFooter("Kannu stopped while these were being timed, so it does not know when you stopped working, and it never guesses. Set when you stopped, or discard the time. Until then it counts for nothing.")
            }
        }
    }

    // MARK: - Task order

    private var taskOrderSection: some View {
        Section {
            addTaskRow

            LabeledContent {
                SettingsValueText(String(localized: "\(manager.activeTasks.count) to do"))
            } label: {
                SettingsRowLabel("Task order", description: "The top task is next. Drag a task, or use its ⋯ menu, to move it. ▶ times it with Kannu's timer and records the actual time.")
            }
            .settingsHighlight(id: highlightID("Task order"))

            if !enableTimerFeature {
                SettingsNoteRow("Timing is off", description: "Turn on the timer feature in the Timer tab to time a task.")
            }
            if let name = manager.movedAsideFileName {
                SettingsNoteRow(
                    "A new task list was started",
                    description: String(localized: "The old task file could not be read. It is kept beside the new one as \(name)."),
                    tint: .orange
                )
            }

            ForEach(manager.activeTasks) { task in
                taskRow(task)
            }
            .onMove { offsets, destination in
                manager.move(activeOffsets: offsets, toActiveOffset: destination)
            }
        } header: {
            SettingsSectionHeader("Your tasks")
        }
    }

    private var addTaskRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                TextField("Task title", text: $newTitle, prompt: Text("What needs doing?"))
                    .labelsHidden()
                    .onSubmit(addTask)
                estimateMenu
                Button("Add", action: addTask)
                    .disabled(!manager.isReady || TaskItem.cleanedTitle(newTitle) == nil)
            }
        } label: {
            SettingsRowLabel("Add a task", description: "A title and, if you like, an estimate. New tasks go to the top.")
        }
        .settingsHighlight(id: highlightID("Add a task"))
    }

    private var estimateMenu: some View {
        Menu {
            Button(String(localized: "No estimate")) { newEstimate = nil }
            ForEach(Self.estimateChoices, id: \.self) { seconds in
                Button(WorkDuration.format(seconds)) { newEstimate = seconds }
            }
            Divider()
            Button(String(localized: "Custom…")) { sheet = .customEstimateForNewTask(current: newEstimate) }
        } label: {
            Text(newEstimate.map(WorkDuration.format) ?? String(localized: "No estimate"))
        }
        .fixedSize()
        .accessibilityLabel("Estimate")
    }

    private func addTask() {
        if manager.addTask(title: newTitle, estimateSeconds: newEstimate) {
            newTitle = ""
            newEstimate = nil
        }
    }

    @ViewBuilder
    private func taskRow(_ task: TaskItem) -> some View {
        let isTimed = manager.timing?.taskID == task.id
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if isTimed {
                    Button {
                        manager.stopTiming()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Stop timing")
                } else {
                    Button {
                        manager.start(task.id)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!enableTimerFeature || !manager.isReady)
                    .accessibilityLabel("Start timing")
                }
                SettingsMoreMenu {
                    moreItems(for: task, isTimed: isTimed)
                }
            }
        } label: {
            if isTimed {
                // Only the row being timed changes on its own, once a minute.
                TimelineView(.everyMinute) { context in
                    taskLabel(task, now: context.date)
                }
            } else {
                taskLabel(task, now: Date())
            }
        }
    }

    @ViewBuilder
    private func moreItems(for task: TaskItem, isTimed: Bool) -> some View {
        let order = manager.activeTasks
        let position = order.firstIndex { $0.id == task.id }
        Button("Set Estimate…") {
            sheet = .estimate(taskID: task.id, title: task.title, current: task.localEstimateSeconds)
        }
        Button("Add Time Manually…") {
            sheet = .addTime(taskID: task.id, title: task.title)
        }
        Divider()
        Button("Move to Top") { manager.moveToTop(task.id) }
            .disabled(position == 0)
        Button("Move Up") { manager.moveUp(task.id) }
            .disabled(position == 0)
        Button("Move Down") { manager.moveDown(task.id) }
            .disabled(position == order.count - 1)
        Divider()
        Button("Mark Done") { manager.markDone(task.id) }
        Button("Delete…", role: .destructive) { pendingDelete = task }
            .disabled(isTimed || task.source != .local)
    }

    private func taskLabel(_ task: TaskItem, now: Date) -> some View {
        SettingsRowLabel(Text(verbatim: task.title), description: progressText(for: task, now: now))
    }

    /// "42m of 2h", with "10m over" in orange past the estimate. Tracked time is exact, in minutes.
    private func progressText(for task: TaskItem, now: Date) -> Text {
        let tracked = manager.trackedSeconds(of: task, now: now)
        let estimate = task.effectiveEstimateSeconds
        var parts: [String] = []
        if let timing = manager.timing, timing.taskID == task.id {
            parts.append(timing.isPaused ? String(localized: "Paused") : String(localized: "Timing now"))
        }
        let trackedText = WorkDuration.format(tracked)
        if let estimate {
            parts.append(String(localized: "\(trackedText) of \(WorkDuration.format(estimate))"))
        } else if tracked > 0 {
            parts.append(String(localized: "\(trackedText) tracked"))
        } else {
            parts.append(String(localized: "No estimate"))
        }
        let summary = Text(verbatim: parts.joined(separator: " · "))
        let over = TaskTimeMath.overtimeSeconds(estimate: estimate, tracked: tracked)
        guard over >= 60 else { return summary }
        return summary
            + Text(verbatim: " · ")
            + Text(verbatim: String(localized: "\(WorkDuration.format(over)) over")).foregroundStyle(.orange)
    }

    // MARK: - Done and hidden

    private var doneAndHiddenSection: some View {
        let finished = manager.doneAndHiddenTasks
        return Section {
            DisclosureGroup(isExpanded: $showsDoneAndHidden) {
                if finished.isEmpty {
                    SettingsNoteRow("Nothing here yet", description: "Tasks you mark done move here, with the time recorded on them.")
                }
                ForEach(finished) { task in
                    doneRow(task)
                }
            } label: {
                SettingsRowLabel("Done and hidden", description: "Finished tasks keep their recorded time. Reopen one to put it back where it was in the order.")
            }
            .settingsHighlight(id: highlightID("Done and hidden tasks"))
        }
    }

    private func doneRow(_ task: TaskItem) -> some View {
        let tracked = WorkDuration.format(manager.trackedSeconds(of: task))
        let state: String
        switch task.visibility {
        case .done: state = String(localized: "Done · \(tracked) recorded")
        case .hidden: state = String(localized: "Hidden · \(tracked) recorded")
        case .gone, .active: state = String(localized: "No longer listed by its source · \(tracked) recorded")
        }
        return LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if task.visibility == .done || task.visibility == .hidden {
                    Button(task.visibility == .done ? String(localized: "Reopen") : String(localized: "Show")) {
                        manager.reopen(task.id)
                    }
                }
                if task.source == .local {
                    SettingsMoreMenu {
                        Button("Delete…", role: .destructive) { pendingDelete = task }
                    }
                }
            }
        } label: {
            SettingsRowLabel(Text(verbatim: task.title), description: Text(verbatim: state))
        }
    }
}

/// What a task sheet edits.
private enum TaskSheet: Identifiable {
    /// "Custom…" in the Add a task row's estimate menu.
    case customEstimateForNewTask(current: Int?)
    case estimate(taskID: UUID, title: String, current: Int?)
    case addTime(taskID: UUID, title: String)
    case endTime(taskID: UUID, segmentID: UUID, title: String, start: Date)

    var id: String {
        switch self {
        case .customEstimateForNewTask: return "new-task-estimate"
        case .estimate(let taskID, _, _): return "estimate-\(taskID)"
        case .addTime(let taskID, _): return "add-time-\(taskID)"
        case .endTime(_, let segmentID, _, _): return "end-time-\(segmentID)"
        }
    }
}

/// The small sheet behind Custom…, Set Estimate…, Add Time Manually… and Set End Time…. A sheet
/// pads its own content; a Form row never does.
private struct TaskValueSheet: View {
    enum Value {
        /// Nil removes an estimate.
        case duration(Int?)
        case date(Date)
    }

    let sheet: TaskSheet
    let onSave: (Value) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var date: Date
    @State private var problem: String?

    init(sheet: TaskSheet, onSave: @escaping (Value) -> Void) {
        self.sheet = sheet
        self.onSave = onSave
        switch sheet {
        case .customEstimateForNewTask(let current), .estimate(_, _, let current):
            _text = State(initialValue: current.map(WorkDuration.format) ?? "")
        case .addTime, .endTime:
            _text = State(initialValue: "")
        }
        if case .endTime(_, _, _, let start) = sheet {
            // Kannu never guesses the end: the picker starts where the session started.
            _date = State(initialValue: start)
        } else {
            _date = State(initialValue: Date())
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text(heading)
                .font(.headline)
            if let subject {
                Text(verbatim: subject)
                    .settingsDescriptionStyle()
            }
            Text(explanation)
                .settingsDescriptionStyle()
            field
            if let problem {
                Text(verbatim: problem)
                    .settingsDescriptionStyle(tint: .red)
            }
            HStack(spacing: SettingsMetrics.rowContent) {
                if case .estimate(_, _, .some) = sheet {
                    Button("Remove Estimate") {
                        onSave(.duration(nil))
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 380)
    }

    @ViewBuilder
    private var field: some View {
        if case .endTime(_, _, _, let start) = sheet {
            DatePicker("Stopped working at", selection: $date, in: start...max(start, Date()),
                       displayedComponents: [.date, .hourAndMinute])
        } else {
            TextField("Length", text: $text, prompt: Text("1h 30m"))
                .onSubmit(save)
                .onChange(of: text) { _, _ in problem = nil }
        }
    }

    private var heading: LocalizedStringKey {
        switch sheet {
        case .customEstimateForNewTask: return "Custom Estimate"
        case .estimate: return "Set Estimate"
        case .addTime: return "Add Time Manually"
        case .endTime: return "Set End Time"
        }
    }

    /// The task's own title, verbatim.
    private var subject: String? {
        switch sheet {
        case .customEstimateForNewTask: return nil
        case .estimate(_, let title, _), .addTime(_, let title), .endTime(_, _, let title, _): return title
        }
    }

    private var explanation: LocalizedStringKey {
        switch sheet {
        case .customEstimateForNewTask, .estimate:
            return "How long you expect it to take, such as 1h 30m, 90m or 1.5h. A number on its own is minutes."
        case .addTime:
            return "Time you worked on it without the timer, such as 45m or 1h 15m. It is recorded as ending now."
        case .endTime:
            return "Kannu stopped while this was being timed. When did you stop working on it?"
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch sheet {
        case .addTime: return "Add"
        case .customEstimateForNewTask, .estimate, .endTime: return "Set"
        }
    }

    private func save() {
        if case .endTime = sheet {
            onSave(.date(date))
            dismiss()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEstimate: Bool
        switch sheet {
        case .customEstimateForNewTask, .estimate: isEstimate = true
        case .addTime, .endTime: isEstimate = false
        }
        if trimmed.isEmpty, isEstimate {
            onSave(.duration(nil))
            dismiss()
            return
        }
        guard let seconds = WorkDuration.parse(trimmed), seconds >= 60 else {
            problem = String(localized: "Type a length of at least a minute, such as 1h 30m, 90m or 1.5h.")
            return
        }
        onSave(.duration(seconds))
        dismiss()
    }
}
