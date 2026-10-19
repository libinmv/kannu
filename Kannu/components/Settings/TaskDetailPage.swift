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
///   with Set Estimate and Add Time;
/// - its facts, most important first; a local task's reminder; Open in Jira or GitLab, and whether
///   its time is offered in Time to log;
/// - what ends it: Mark Done, Archive or Delete, or, once closed or archived, Reopen and Restore.
///
/// Its rows carry no highlight ids (docs/SETTINGS.md). A task deleted while its page is open
/// leaves the page (`TasksSettings`); one gone some other way says so.
struct TaskDetailPage: View {
    @ObservedObject private var manager = TasksManager.shared
    let taskID: UUID
    let context: TasksPageContext

    var body: some View {
        if let task = manager.tasks.first(where: { $0.id == taskID }) {
            if manager.timing?.taskID == task.id {
                // Only the task being timed changes on its own, once a minute.
                TimelineView(.everyMinute) { timeline in
                    content(task, now: timeline.date)
                }
            } else {
                content(task, now: Date())
            }
        } else {
            Section {
                SettingsNoteRow("This task is gone", description: "It was deleted, or cleared from the archive.")
            }
        }
    }

    @ViewBuilder
    private func content(_ task: TaskItem, now: Date) -> some View {
        let summary = TaskDetailSummary(task: task, tracked: manager.trackedSeconds(of: task, now: now), now: now,
                                        selfNames: Self.selfNames)
        overviewSection(task, summary: summary)
        detailsSection(task, summary: summary)
        endSection(task)
    }

    // MARK: - Title, tags and time

    private func overviewSection(_ task: TaskItem, summary: TaskDetailSummary) -> some View {
        let remoteLabels = (task.remote?.labels ?? []).map(TaskDetailSummary.labelDisplay)
        let line = [summary.shortKey, summary.status.name, summary.isDraft ? String(localized: "Draft") : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return Section {
            LabeledContent {
                if task.visibility == .active {
                    TaskTimingButton(task: task)
                }
            } label: {
                SettingsRowLabel(Text(verbatim: summary.title), description: Text(verbatim: line))
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
                    Button("Set Estimate") {
                        context.sheet.wrappedValue = .estimate(taskID: task.id, title: task.title, current: task.localEstimateSeconds)
                    }
                    Button("Add Time") {
                        context.sheet.wrappedValue = .addTime(taskID: task.id, title: task.title)
                    }
                }
            } label: {
                SettingsRowLabel("Time", description: timeText(summary))
            }
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
            }

            if let remote = task.remote {
                LabeledContent {
                    if let link = taskOpenLink(for: task, manager: manager) {
                        Button(link.title) { NSWorkspace.shared.open(link.url) }
                    }
                } label: {
                    SettingsRowLabel("Source", description: Text(verbatim: remote.key))
                }

                SettingsRow("Ask to log its time", description: "Offer its recorded time in Time to log.") {
                    Toggle("Ask to log its time", isOn: Binding(
                        get: { task.logPolicy == .ask },
                        set: { manager.setAsksToLogTime($0, for: task.id) }
                    ))
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

    /// The connected accounts, so the user's own name never takes a fact.
    private static var selfNames: Set<String> {
        Set([Defaults[.gitlabAccountDisplayName], Defaults[.gitlabUsername], Defaults[.jiraAccountDisplayName]]
            .filter { !$0.isEmpty })
    }
}
