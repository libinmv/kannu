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

/// One task's page (‹ the list it was opened from), in the words of `TaskDetailSummary`, as the
/// notch's card is, so a task reads the same everywhere:
///
/// - its title, with the short key and where it stands, and ▶ or ■; its source's labels; its tags
///   as chips that remove themselves, with Add Tags; its time against the estimate, any overtime,
///   with its estimate typed in place (`TaskEstimateField`) and Add Time;
/// - its facts, most important first; a local task's reminder; Open in Jira or GitLab, and whether
///   its time is offered in Time to log;
/// - what ends it: Mark Done, Archive or Delete, or, once closed or archived, Reopen and Restore.
///
/// Its rows carry no highlight ids (docs/SETTINGS.md). A task deleted while its page is open
/// leaves the page (`TasksSettings`); one gone some other way says so.
struct TaskDetailPage: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    let taskID: UUID
    let context: TasksPageContext
    /// The estimate being typed in the Time row; nil follows the task, so a change from a sync or
    /// the notch shows at once.
    @State private var typedEstimate: TaskFormDraft?
    /// A local task's title being typed in place; nil follows the task.
    @State private var typedTitle: String?
    @FocusState private var titleFocused: Bool
    /// The page's clock, moved on at each whole minute by the Time row's ticker: "42m of 2h" for a
    /// timed task, "Timed … ago", an overdue reminder. A value, not a wrapper, so the Sections reach
    /// the Form as Sections and a timer starting or ending tears nothing down.
    @State private var minute = Date()

    var body: some View {
        if let task = manager.tasks.first(where: { $0.id == taskID }) {
            // Straight to the Form: inside a TimelineView the three Sections reached it as one row,
            // one card with "Details" centred (David's picture, 2026-10-24).
            content(task)
        } else {
            Section {
                SettingsNoteRow("This task is gone", description: "It was deleted, or cleared from the archive.")
            }
        }
    }

    @ViewBuilder
    private func content(_ task: TaskItem) -> some View {
        let now = max(minute, Date())
        let summary = TaskDetailSummary(task: task, tracked: manager.trackedSeconds(of: task, now: now), now: now,
                                        selfNames: TaskSource.selfNames)
        overviewSection(task, summary: summary, isTimed: manager.timing?.taskID == task.id)
        detailsSection(task, summary: summary)
        endSection(task)
    }

    // MARK: - Title, tags and time

    private func overviewSection(_ task: TaskItem, summary: TaskDetailSummary, isTimed: Bool) -> some View {
        let remoteLabels = (task.remote?.labels ?? []).map(TaskDetailSummary.labelDisplay)
        let line = [summary.shortKey, summary.status.name, summary.isDraft ? String(localized: "Draft") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Section {
            LabeledContent {
                if task.visibility == .active {
                    TaskTimingButton(isTimed: isTimed,
                                     canStart: enableTimerFeature && manager.isReady,
                                     start: { manager.start(task.id) }, stop: { manager.stopTiming() })
                }
            } label: {
                if task.source == .local {
                    // A local task's title, typed in place as the notch's form edits it: the Form's own
                    // body font, so it reads as the title, and wrapping as the title did. Return, another
                    // field, leaving the page or closing Brain saves; Escape puts it back and stays, as
                    // the Time row's does. Jira and GitLab titles are their servers'.
                    VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                        TextField("Title", text: Binding(get: { typedTitle ?? task.title }, set: { typedTitle = $0 }),
                                  prompt: Text("What needs doing?"), axis: .vertical)
                            .lineLimit(1...4)
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .focused($titleFocused)
                            .onSubmit { applyTitle(to: task) }
                            .onExitCommand { typedTitle = nil }
                            .help(Text("Click to rename"))
                            .disabled(!manager.isReady)
                        Text(verbatim: line)
                            .settingsDescriptionStyle()
                    }
                } else {
                    SettingsRowLabel(Text(verbatim: summary.title), description: Text(verbatim: line))
                }
            }
            .onChange(of: titleFocused) { _, focused in
                if !focused { applyTitle(to: task) }
            }
            .onDisappear { applyTitle(to: task) }
            // Closing Brain only orders its window out: no focus change, no onDisappear.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard (note.object as? NSWindow)?.identifier == SettingsWindowController.windowIdentifier else { return }
                applyTitle(to: task)
            }

            if !remoteLabels.isEmpty {
                LabeledContent {
                    EmptyView()
                } label: {
                    SettingsRowLabel("Labels", description: Text(verbatim: remoteLabels.joined(separator: " · ")))
                }
            }

            LabeledContent {
                Button("Add Tags") {
                    context.sheet.wrappedValue = .tags(taskID: task.id, title: task.title, current: task.tags,
                                                       existing: TaskFacets.tags(in: manager.tasks))
                }
            } label: {
                VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                    Text("Tags")
                    if task.tags.isEmpty {
                        Text("None yet. The first tag sets the colour.")
                            .settingsDescriptionStyle()
                    } else {
                        SettingsFlowLayout {
                            ForEach(task.tags, id: \.self) { tag in
                                SettingsTagChip(tag, tint: manager.tagColor(for: tag).tint) {
                                    manager.setTags(task.tags.filter { $0 != tag }, for: task.id)
                                }
                                .disabled(!manager.isReady)
                            }
                        }
                    }
                }
            }

            LabeledContent {
                HStack(spacing: SettingsMetrics.rowContent) {
                    // Typed in place (David, 2026-10-23: "inside brain also estimate should be
                    // typeable"): Return, leaving the field, a preset or leaving the page saves it;
                    // Escape puts it back.
                    TaskEstimateField(
                        draft: Binding(get: { typedEstimate ?? TaskFormDraft(editing: task) }, set: { typedEstimate = $0 }),
                        onSubmit: { applyEstimate(typedEstimate, to: task) },
                        onSettle: { applyEstimate($0, to: task) },
                        onCancel: { typedEstimate = nil }
                    )
                    .disabled(!manager.isReady)
                    Button("Add Time") {
                        context.sheet.wrappedValue = .addTime(taskID: task.id, title: task.title)
                    }
                }
                .frame(width: SettingsMetrics.sliderWidth, alignment: .trailing)
            } label: {
                SettingsRowLabel("Time", description: timeText(summary))
            }
            .onDisappear { applyEstimate(typedEstimate, to: task) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                guard (note.object as? NSWindow)?.identifier == SettingsWindowController.windowIdentifier else { return }
                applyEstimate(typedEstimate, to: task)
            }
            // The page's clock, on one row only: on a group of Sections it may run once a row. A
            // lazy Form drops the row once it scrolls away, and the clock pauses with it; it catches
            // up the moment the row is back.
            .task {
                while !Task.isCancelled {
                    let now = Date()
                    minute = now
                    let next = Calendar.current.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime)
                        ?? now.addingTimeInterval(60)
                    try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(now))))
                }
            }
        }
    }

    /// Saves a typed title through `renameTask` (which refuses an empty one, and renames a running
    /// session too); then the field follows the task again.
    private func applyTitle(to task: TaskItem) {
        guard let typed = typedTitle else { return }
        typedTitle = nil
        if let cleaned = TaskItem.cleanedTitle(typed), cleaned != task.title {
            manager.renameTask(task.id, to: cleaned)
        }
    }

    /// Saves a typed estimate the moment it reads: nothing or 0 removes it, a length sets it, and
    /// only when it differs. Text it cannot read stays, orange, and is not saved.
    private func applyEstimate(_ typed: TaskFormDraft?, to task: TaskItem) {
        guard var draft = typed else { return }
        draft.settleEstimateText()
        switch draft.estimateReading {
        case .unreadable:
            typedEstimate = draft
        case .none, .length:
            let seconds = draft.estimateSeconds
            if seconds != task.localEstimateSeconds { manager.setEstimate(seconds, for: task.id) }
            typedEstimate = nil
        }
    }

    /// "42m of 2h", with "10m over" in orange past the estimate.
    private func timeText(_ summary: TaskDetailSummary) -> Text {
        guard let overtime = summary.overtime else { return Text(verbatim: summary.time) }
        return Text(verbatim: summary.time + " · ") + Text(verbatim: overtime).foregroundStyle(.orange)
    }

    // MARK: - Details

    private func detailsSection(_ task: TaskItem, summary: TaskDetailSummary) -> some View {
        Section {
            if let note = summary.note {
                SettingsNoteRow(verbatim: note)
            }
            ForEach(Array(summary.facts.enumerated()), id: \.offset) { _, fact in
                Label {
                    Text(verbatim: fact.text)
                        .foregroundStyle(fact.isAlert ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: fact.icon)
                        .foregroundStyle(fact.isAlert ? Color.orange : Color.secondary)
                }
            }

            if task.source == .local, task.visibility == .active {
                LabeledContent {
                    HStack(spacing: SettingsMetrics.rowContent) {
                        Button("Schedule") {
                            context.sheet.wrappedValue = .schedule(taskID: task.id, title: task.title, current: task.scheduledAt)
                        }
                        if task.scheduledAt != nil {
                            Button("Clear") { manager.setSchedule(nil, for: task.id) }
                        }
                    }
                } label: {
                    SettingsRowLabel("Reminder", description: task.scheduledAt == nil
                        ? Text("None. A reminder comes with a Start button.")
                        : Text(verbatim: task.scheduledAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                }

                // The notch's bell: this reminder's notification on or off; its time stays.
                if task.scheduledAt != nil {
                    SettingsRow("Notify", description: "A notification when the reminder is due.") {
                        Toggle("Notify", isOn: Binding(get: { task.notifiesForReminder },
                                                       set: { manager.setReminderNotifies($0, for: task.id) }))
                    }
                    .disabled(!manager.isReady)
                    if task.notifiesForReminder && manager.notificationsDenied {
                        SettingsActionRow("Notifications are off", description: "Reminders need notifications for Kannu.") {
                            Button(openNotificationSettingsTitle) { TaskReminders.openNotificationSettings() }
                        }
                    }
                }
            }

            if let remote = task.remote {
                LabeledContent {
                    if let link = taskOpenLink(for: task, manager: manager) {
                        Button(link.title) { NSWorkspace.shared.open(link.url) }
                    }
                } label: {
                    SettingsRowLabel("Source", description: Text(verbatim: remote.key))
                }

                // Only where the source takes time (`TaskSource.logsTime`): Jira and GitLab.
                if task.source.logsTime {
                    SettingsRow("Ask to log its time", description: "Offer its recorded time in Time to log.") {
                        Toggle("Ask to log its time", isOn: Binding(
                            get: { task.logPolicy == .ask },
                            set: { manager.setAsksToLogTime($0, for: task.id) }
                        ))
                    }
                }
            }
        } header: {
            SettingsSectionHeader("Details")
        }
    }

    // MARK: - Done, archived, deleted

    /// A local task is finished here: Mark Done, Archive, or Delete. A remote one is finished in its
    /// source and archived here — a deleted one would only come back on the next sync.
    @ViewBuilder
    private func endSection(_ task: TaskItem) -> some View {
        let isTimed = manager.timing?.taskID == task.id
        Section {
            switch task.visibility {
            case .active:
                if task.source == .local {
                    SettingsActionRow("Finish", description: "Done keeps its time; Delete removes it.") {
                        Button("Mark Done") { manager.markDone(task.id) }
                        Button("Archive") { manager.archive(task.id) }
                        Button("Delete", role: .destructive) { context.pendingDelete.wrappedValue = task }
                            .disabled(isTimed)
                    }
                } else {
                    SettingsActionRow("Archive", description: "Out of every list here. Close it in its source.") {
                        Button("Archive") { manager.archive(task.id) }
                    }
                }
            case .done, .gone:
                SettingsActionRow("Closed", description: task.visibility == .done
                    ? String(localized: "Done. Reopen puts it back in the order.")
                    : String(localized: "No longer listed by its source.")) {
                    if task.visibility == .done {
                        Button("Reopen") { manager.reopen(task.id) }
                    }
                    Button("Archive") { manager.archive(task.id) }
                }
            case .archived:
                SettingsActionRow("Archived", description: "Restore puts it back in the order.") {
                    Button("Restore") { manager.reopen(task.id) }
                    if task.source == .local {
                        Button("Delete", role: .destructive) { context.pendingDelete.wrappedValue = task }
                    }
                }
            }
        }
    }
}
