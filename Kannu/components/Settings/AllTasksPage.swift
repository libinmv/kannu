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

/// All tasks (‹ Tasks): every task Kannu holds — local, Jira and GitLab, synced or paused
/// (`TasksManager.activeTasks`) — in one order. First a Find row, a search field with one Filter
/// menu beside it holding the Source, Project, Status and Tag filters; then Add a task, the task
/// order and its rows (`TaskRowList`); and, folded at the end, Recently closed, the Archive and Tag
/// colours.
///
/// The filters are this page's own, a view filter only: they persist in Defaults
/// (`tasksListSourceFilter` and the rest) and change nothing anywhere else; Find is never saved.
/// While either hides anything the list opens with a "Filtered" row, "3 of 12 tasks", whose Show
/// All clears both. The rows here carry no highlight ids: their search entries land on the
/// overview's All tasks row.
struct AllTasksPage: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    @Default(.tasksListSourceFilter) private var sourceFilter
    @Default(.tasksListProjectFilter) private var projectFilter
    @Default(.tasksListStatusFilter) private var statusFilter
    @Default(.tasksListTagFilter) private var tagFilter
    @Binding private var query: String
    private let context: TasksPageContext
    @State private var showsRecentlyClosed = false
    @State private var showsArchive = false
    @State private var showsTagColors = false

    init(query: Binding<String>, context: TasksPageContext) {
        _query = query
        self.context = context
    }

    private var filter: TaskFilter {
        TaskFilter(source: sourceFilter, project: TaskFacets.normalizedProjectFilter(projectFilter),
                   status: statusFilter, tag: tagFilter, query: query)
    }

    var body: some View {
        Section {
            findRow
        }
        .onAppear {
            manager.checkReminderPermission()
            // Recently closed and the Archive read their days from now, not from the last sync.
            manager.refreshArchive()
            // A Project filter saved before project keys: rewrite it once, so the menu selects it.
            let project = TaskFacets.normalizedProjectFilter(projectFilter)
            if project != projectFilter { projectFilter = project }
        }

        if case .failed(let reason) = manager.loadState {
            Section {
                SettingsErrorText(String(localized: "Couldn't read the task list, so it can't change. \(reason)"))
            }
        }
        tasksSection
        recentlyClosedSection
        archiveSection
        tagColorsSection
    }

    // MARK: - Find and the filters

    private var findRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                TextField("Find", text: $query, prompt: Text("Title, key or tag"))
                    .labelsHidden()
                filterMenu
            }
        } label: {
            SettingsRowLabel("Find", description: "Narrows the list as you type.")
        }
    }

    /// The four filters in one menu, each a submenu with its choice ticked. They offer what every
    /// task Kannu holds has, not what the filters left, so a choice never vanishes from its own
    /// menu. The icon is filled while any of them narrows.
    private var filterMenu: some View {
        let active = manager.activeTasks
        let projects = TaskFacets.projects(in: active)
        let tags = TaskFacets.tags(in: active)
        let narrowsByFilter = filter.source != .all || filter.project != TaskFacets.anyProject
            || filter.status != .toDoAndInProgress || filter.tag != TaskFacets.anyTag
        return Menu {
            Picker("Source", selection: $sourceFilter) {
                ForEach(TaskSourceFilter.allCases) { choice in
                    Text(choice.localizedName).tag(choice)
                }
            }
            Picker("Project", selection: $projectFilter) {
                Text("All").tag(TaskFacets.anyProject)
                ForEach(projects, id: \.self) { project in
                    Text(verbatim: TaskFacets.projectName(project)).tag(project)
                }
                if TaskFacets.hasTaskWithoutProject(in: active) {
                    Text("No project").tag(TaskFacets.noProject)
                }
                // A saved choice no task has any more still shows, so the menu is never blank.
                if projectFilter != TaskFacets.anyProject, projectFilter != TaskFacets.noProject,
                   !projects.contains(projectFilter) {
                    Text(verbatim: TaskFacets.projectName(projectFilter)).tag(projectFilter)
                }
            }
            Picker("Status", selection: $statusFilter) {
                ForEach(TaskStatusFilter.allCases) { choice in
                    Text(choice.localizedName).tag(choice)
                }
            }
            Picker("Tag", selection: $tagFilter) {
                Text("All").tag(TaskFacets.anyTag)
                ForEach(tags, id: \.self) { tag in
                    Text(verbatim: "#\(tag)").tag(tag)
                }
                if tagFilter != TaskFacets.anyTag,
                   !tags.contains(where: { $0.lowercased() == tagFilter.lowercased() }) {
                    Text(verbatim: "#\(tagFilter)").tag(tagFilter)
                }
            }
            Divider()
            Button("Show All", action: showAll)
                .disabled(!filter.isNarrowing)
        } label: {
            Image(systemName: narrowsByFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filters")
    }

    /// Show All: every filter back to its default and Find emptied, so every task shows.
    private func showAll() {
        sourceFilter = .all
        projectFilter = TaskFacets.anyProject
        statusFilter = .toDoAndInProgress
        tagFilter = TaskFacets.anyTag
        query = ""
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        let filter = filter
        let rows = manager.listedTasks(filter)
        let total = manager.activeTasks.count
        return Section {
            // First, so a narrowed list never passes for the whole one.
            if filter.isNarrowing {
                SettingsActionRow("Filtered", description: String(localized: "\(rows.count) of \(total) tasks")) {
                    Button("Show All", action: showAll)
                }
            }

            TaskAddRow(context: context)

            LabeledContent {
                // Filtered, the count is on the Filtered row: one fact, said once.
                if !filter.isNarrowing {
                    SettingsValueText(String(localized: "\(total) open"))
                }
            } label: {
                SettingsRowLabel("Task order", description: "Drag to reorder. Right-click a task for more.")
            }

            if !enableTimerFeature {
                SettingsNoteRow("Timing is off", description: "Turn on the timer in the Timer tab.")
            }
            if let name = manager.movedAsideFileName {
                SettingsNoteRow(
                    "A new task list was started",
                    description: String(localized: "The old file couldn't be read; it's kept as \(name)."),
                    tint: .orange
                )
            }
            if manager.remindersBlocked {
                SettingsActionRow("Notifications are off", description: "Reminders need notifications for Kannu.") {
                    Button(openNotificationSettingsTitle) { TaskReminders.openNotificationSettings() }
                }
            }
            if rows.isEmpty && filter.isNarrowing {
                SettingsActionRow("No tasks match", description: "Change the filters or Find, or show all tasks.") {
                    Button("Show All", action: showAll)
                }
            }

            TaskRowList(filter: filter, context: context)
        } header: {
            SettingsSectionHeader("Tasks")
        }
    }

    // MARK: - Recently closed and Archive

    /// Done and gone tasks, for `TaskArchive.closedDays`, then the archive takes them.
    private var recentlyClosedSection: some View {
        let closed = manager.recentlyClosedTasks
        return Section {
            DisclosureGroup(isExpanded: $showsRecentlyClosed) {
                if closed.isEmpty {
                    SettingsNoteRow("Nothing closed lately", description: "Tasks you mark done, and tickets closed in Jira or GitLab, appear here.")
                }
                ForEach(closed) { task in
                    closedRow(task)
                }
            } label: {
                SettingsRowLabel("Recently closed", description: "Moved to the archive after \(TaskArchive.closedDays) days.")
            }
        }
    }

    /// Archived tasks: out of every other list. A Jira or GitLab task clears itself
    /// `TaskArchive.clearDays` after it was archived, never while it holds time to log.
    private var archiveSection: some View {
        let archived = manager.archivedTasks
        return Section {
            DisclosureGroup(isExpanded: $showsArchive) {
                if archived.isEmpty {
                    SettingsNoteRow("The archive is empty", description: "Archived tasks keep their time here.")
                }
                ForEach(archived) { task in
                    archivedRow(task)
                }
            } label: {
                SettingsRowLabel("Archive", description: "Jira and GitLab tasks clear after \(TaskArchive.clearDays) days; yours stay.")
            }
        }
    }

    private func closedRow(_ task: TaskItem) -> some View {
        let tracked = WorkDuration.format(manager.trackedSeconds(of: task))
        let state = task.visibility == .done
            ? String(localized: "Done · \(tracked) recorded")
            : String(localized: "No longer listed by its source · \(tracked) recorded")
        let days = TaskArchive.daysUntilArchive(task, now: Date()) ?? TaskArchive.closedDays
        let when = days == 0 ? String(localized: "archiving now") : String(localized: "archives in \(days)d")
        // A remote task's short key comes first, so a closed PROJ-123 is found by its key.
        let line = [TaskDetailSummary.shortKey(for: task), state, when].compactMap { $0 }.joined(separator: " · ")
        // Every row ends in the same pair, a button then ⋯, so the trailing edges line up. A task
        // its source no longer lists comes back only with the source: it can be archived now.
        return LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if task.visibility == .done {
                    Button("Reopen") { manager.reopen(task.id) }
                } else {
                    Button("Archive") { manager.archive(task.id) }
                }
                moreMenu(for: task, archiveItem: task.visibility == .done)
            }
        } label: {
            SettingsRowLabel(Text(verbatim: task.title), description: Text(verbatim: line))
        }
    }

    private func archivedRow(_ task: TaskItem) -> some View {
        let tracked = WorkDuration.format(manager.trackedSeconds(of: task))
        let fate: String
        if task.source == .local {
            fate = String(localized: "Archived · \(tracked) recorded")
        } else if TaskArchive.holdsTimeToLog(task, drafts: manager.drafts) {
            fate = String(localized: "Archived · kept until its time is logged")
        } else if let days = TaskArchive.daysUntilClear(task, now: Date()) {
            fate = days == 0 ? String(localized: "Archived · clearing now") : String(localized: "Archived · clears in \(days)d")
        } else {
            // Still open on its server: clearing it would only bring it back as new.
            fate = String(localized: "Archived · kept while still open in its source")
        }
        let line = [TaskDetailSummary.shortKey(for: task), fate].compactMap { $0 }.joined(separator: " · ")
        return LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                Button("Restore") { manager.reopen(task.id) }
                moreMenu(for: task, archiveItem: false)
            }
        } label: {
            SettingsRowLabel(Text(verbatim: task.title), description: Text(verbatim: line))
        }
    }

    /// The ⋯ on a closed or archived row: Show Details, Archive (a done task), Delete (a local
    /// task), or the task's page in its source (a remote one).
    private func moreMenu(for task: TaskItem, archiveItem: Bool) -> some View {
        let link = taskOpenLink(for: task, manager: manager)
        return SettingsMoreMenu {
            Button("Show Details") { context.open(.task(task.id)) }
            if archiveItem {
                Button("Archive") { manager.archive(task.id) }
            }
            if task.source == .local {
                Button("Delete", role: .destructive) { context.pendingDelete.wrappedValue = task }
            } else if let link {
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
        }
    }

    // MARK: - Tag colours

    /// Every tag on any task Kannu holds, done and hidden ones too, with its colour. A colour is
    /// the tag's, shared by every task carrying it (`TasksManager.setTagColor`).
    private var tagColorsSection: some View {
        let tags = TaskFacets.tags(in: manager.tasks)
        return Section {
            DisclosureGroup(isExpanded: $showsTagColors) {
                if tags.isEmpty {
                    SettingsNoteRow("No tags yet", description: "Tags you add to tasks appear here.")
                }
                ForEach(tags, id: \.self) { tag in
                    LabeledContent {
                        TaskColorPickerButton(
                            selection: tagColorBinding(for: tag),
                            accessibilityLabel: String(localized: "Colour of tag \(tag): \(manager.tagColor(for: tag).localizedName)")
                        )
                        .disabled(!manager.isReady)
                    } label: {
                        SettingsRowLabel(Text(verbatim: "#\(tag)"))
                    }
                }
            } label: {
                SettingsRowLabel("Tag colours", description: "A task takes its first tag's colour; untagged ones, their source's.")
            }
        }
    }

    private func tagColorBinding(for tag: String) -> Binding<TaskColor> {
        Binding(
            get: { manager.tagColor(for: tag) },
            set: { manager.setTagColor($0, for: tag) }
        )
    }
}
