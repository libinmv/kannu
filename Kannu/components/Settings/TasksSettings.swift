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

/// Brain › Tasks: where tasks come from, the Tasks options, Time to log, Interrupted sessions, and a
/// "Task list ›" row that opens the Task list: the task order with its filters, Add a task, and
/// Done and hidden. Brain has no navigation stack, so the Task list is an in-tab view swap; search
/// lands on the visible "Task list" row (the Advanced precedent, docs/SETTINGS.md), and any Tasks
/// search or deep link closes the Task list so its row is on screen — except
/// `SettingsDeepLink.tasksListOpenID`, which opens it ("Show all in Brain", a reminder's click).
///
/// Built only from the `SettingsComponents` shapes (docs/SETTINGS.md). A task row carries a ▶ and a
/// `SettingsMoreMenu`, so it is a raw `LabeledContent` with a `SettingsRowLabel` — the `analysisRow`
/// shape — never a `SettingsRow`, whose `.labelsHidden()` would erase the menu. Task titles are the
/// user's own text and render verbatim.
///
/// With tasks off nothing here touches `TasksManager`, so the tab never reads the task file.
///
/// The Sources section (Jira Cloud, GitLab) shows what the Defaults display copies say, and only
/// connects: Sync Jira and Sync GitLab decide what is fetched, never what is listed. Every task Kannu
/// holds is in the Task list; its filters are the Task list's own, and it says when they hide
/// anything. This file never reads the Keychain: a sync does, off the main actor, in `TasksManager`.
struct TasksSettings: View {
    @Default(.enableTasks) private var enableTasks
    @Default(.tasksDefaultSessionMinutes) private var defaultSessionMinutes

    // On the Form, not on a row: rows of a long, lazy Form may not exist when these change.
    @State private var sheet: TaskSheet?
    @State private var pendingDelete: TaskItem?
    @State private var newTitle = ""
    @State private var newEstimate: Int?
    @State private var confirmsJiraDisconnect = false
    @State private var confirmsGitLabDisconnect = false
    @State private var showsTaskList = false
    @ObservedObject private var highlights = SettingsHighlightCoordinator.shared

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    var body: some View {
        Form {
            if enableTasks && showsTaskList {
                TaskListPage(
                    sheet: $sheet,
                    pendingDelete: $pendingDelete,
                    newTitle: $newTitle,
                    newEstimate: $newEstimate,
                    close: { showsTaskList = false }
                )
            } else {
                tasksPage
            }
        }
        .navigationTitle(enableTasks && showsTaskList ? "Task list" : "Tasks")
        // Search and deep links land on rows of the Tasks page, never inside the Task list; only
        // the Task list's own deep link opens it. `initial`: the link may arrive before this tab is built.
        .onChange(of: highlights.activeHighlightID, initial: true) { _, id in
            guard let id, id.hasPrefix(highlightID("")) else { return }
            showsTaskList = id == SettingsDeepLink.tasksListOpenID
        }
        // Tasks off: every reminder, waiting or on screen, is taken back. `TaskReminders` only —
        // this never builds `TasksManager`.
        .onChange(of: enableTasks) { _, isOn in
            if !isOn { TaskReminders.withdrawAll() }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .connectJira:
                JiraConnectSheet()
            case .connectGitLab:
                GitLabConnectSheet()
            case .tags(let taskID, let title, let current, let existing):
                TaskTagsSheet(taskID: taskID, title: title, current: current, existing: existing)
            default:
                TaskValueSheet(sheet: sheet) { value in apply(value, from: sheet) }
            }
        }
        .alert(
            Text(verbatim: String(localized: "Delete “\(pendingDelete?.title ?? "")”?")),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { task in
            Button("Delete", role: .destructive) { TasksManager.shared.delete(task.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its recorded time is deleted too.")
        }
        .confirmationDialog("Disconnect Jira?", isPresented: $confirmsJiraDisconnect, titleVisibility: .visible) {
            Button("Keep Jira Tasks") { TasksManager.shared.disconnectJira(removeTasks: false) }
            Button("Remove Jira Tasks", role: .destructive) { TasksManager.shared.disconnectJira(removeTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kannu forgets the token. Keep the Jira tasks and their time, or remove them.")
        }
        .confirmationDialog("Disconnect GitLab?", isPresented: $confirmsGitLabDisconnect, titleVisibility: .visible) {
            Button("Keep GitLab Tasks") { TasksManager.shared.disconnectGitLab(removeTasks: false) }
            Button("Remove GitLab Tasks", role: .destructive) { TasksManager.shared.disconnectGitLab(removeTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kannu forgets the token. Keep the GitLab tasks and their time, or remove them.")
        }
    }

    @ViewBuilder
    private var tasksPage: some View {
        if enableTasks {
            TaskSourcesSection(
                sheet: $sheet,
                confirmsJiraDisconnect: $confirmsJiraDisconnect,
                confirmsGitLabDisconnect: $confirmsGitLabDisconnect
            )
        }

        Section {
            SettingsRow("Enable tasks", description: "Plan your work and time it.") {
                Defaults.Toggle(key: .enableTasks) {
                    Text("Enable tasks")
                }
            }
            .settingsHighlight(id: highlightID("Enable tasks"))

            SettingsStepperRow(
                "Default session length",
                description: "Timer length when a task has no estimate.",
                value: $defaultSessionMinutes,
                in: 5...240,
                step: 5,
                valueText: Text("\(defaultSessionMinutes) min")
            )
            .settingsHighlight(id: highlightID("Default session length"))

            SettingsRow("Sound when the estimate is reached", description: "Play the timer sound at the estimate.") {
                Defaults.Toggle(key: .tasksSoundAtEstimate) {
                    Text("Sound when the estimate is reached")
                }
            }
            .settingsHighlight(id: highlightID("Sound when the estimate is reached"))
        } header: {
            SettingsSectionHeader("Tasks")
        } footer: {
            SettingsFooter("Tasks and their time stay on this Mac.")
        }

        if enableTasks {
            TaskOverviewSections(sheet: $sheet, openTaskList: { showsTaskList = true })
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
        case (.schedule(let taskID, _, _), .date(let date)):
            TasksManager.shared.setSchedule(date, for: taskID)
        case (.schedule(let taskID, _, _), .cleared):
            TasksManager.shared.setSchedule(nil, for: taskID)
        default:
            break
        }
    }
}

/// Where tasks come from: Jira Cloud and GitLab. Connection only: Sync Jira and Sync GitLab decide
/// what is fetched, and a paused source's tasks stay listed (its Sync row says so). The user's own
/// tasks need no source. A separate view so `TasksManager` is created only once tasks are turned
/// on. Each source has its own rows, status and Refresh: one failing never shows on the other.
///
/// Status comes from the Defaults display copies and the manager's sync state, never from the
/// Keychain. The page appearing asks for a sync only when the last one is stale.
private struct TaskSourcesSection: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.jiraEnabled) private var jiraEnabled
    @Default(.jiraSiteHost) private var jiraSiteHost
    @Default(.jiraAccountDisplayName) private var jiraAccountDisplayName
    @Default(.jiraJQL) private var jiraJQL
    @Default(.gitlabEnabled) private var gitlabEnabled
    @Default(.gitlabHost) private var gitlabHost
    @Default(.gitlabUsername) private var gitlabUsername
    @Default(.gitlabAccountDisplayName) private var gitlabAccountDisplayName
    @Default(.gitlabCanLogTime) private var gitlabCanLogTime
    @Default(.gitlabIncludeMergeRequests) private var gitlabIncludeMergeRequests
    @Binding private var sheet: TaskSheet?
    @Binding private var confirmsJiraDisconnect: Bool
    @Binding private var confirmsGitLabDisconnect: Bool
    @State private var showsAdvanced = false

    init(sheet: Binding<TaskSheet?>, confirmsJiraDisconnect: Binding<Bool>, confirmsGitLabDisconnect: Binding<Bool>) {
        _sheet = sheet
        _confirmsJiraDisconnect = confirmsJiraDisconnect
        _confirmsGitLabDisconnect = confirmsGitLabDisconnect
    }

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    private var isConnected: Bool { !jiraSiteHost.isEmpty }

    var body: some View {
        Section {
            jiraRow

            if isConnected, let problem = jiraProblem {
                SettingsErrorText(problem)
            }
            if isConnected, manager.jiraSync == .needsKeychainApproval {
                SettingsActionRow("Keychain access", description: "Let Kannu read the saved Jira token.") {
                    Button("Allow Keychain Access") { manager.refreshJira() }
                }
            }
            if !isConnected, manager.jiraTokenRemovalFailed {
                SettingsErrorText(String(localized: "Couldn't remove the Jira token from your Keychain."))
                SettingsActionRow("Saved Jira token", description: "Or delete com.kannu.app.secure-secrets (jira-credential) in Keychain Access.") {
                    Button("Remove Token") { manager.retryRemovingJiraToken() }
                }
            }

            if isConnected {
                SettingsRow("Sync Jira", description: jiraEnabled
                    ? Text("Fetch your open Jira issues.")
                    : Text("Sync paused. Jira tasks stay listed.")) {
                    Defaults.Toggle(key: .jiraEnabled) {
                        Text("Sync Jira")
                    }
                }
                .settingsHighlight(id: highlightID("Sync Jira"))

                jiraIssuesRow
                    .settingsHighlight(id: highlightID("Jira issues"))

                DisclosureGroup(isExpanded: $showsAdvanced) {
                    issueFilterRow
                } label: {
                    SettingsRowLabel("Advanced")
                }
                .settingsHighlight(id: highlightID("Issue filter"))
            }

            gitlabRows
        } header: {
            SettingsSectionHeader("Sources")
        } footer: {
            SettingsFooterStack {
                SettingsFooter("Tokens stay in your Keychain. Kannu writes nothing until you choose Log.")
                SettingsFooter("Make tokens just for Kannu, with an expiry date.")
            }
        }
    }

    // MARK: - Jira Cloud

    private var jiraRow: some View {
        LabeledContent {
            if isConnected {
                Button("Disconnect…") { confirmsJiraDisconnect = true }
            } else {
                Button("Connect…") { sheet = .connectJira }
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text("Jira Cloud")
                SettingsStatusText(statusText, isReady: isConnected && jiraEnabled && jiraProblem == nil)
                if isConnected {
                    Text(verbatim: String(localized: "Site \(jiraSiteHost) · Filter: \(JiraAPI.filterSummary(jql: jiraJQL))"))
                        .settingsDescriptionStyle()
                } else {
                    Text("Your open issues. Needs your site, email and a token.")
                        .settingsDescriptionStyle()
                }
            }
        }
        .settingsHighlight(id: SettingsDeepLink.tasksSourcesHighlightID)
        .onAppear { manager.syncJiraIfStale() }
        .onChange(of: jiraEnabled) { _, isOn in
            if isOn { manager.syncJiraIfStale() }
        }
    }

    private var statusText: String {
        guard isConnected else { return String(localized: "Not connected") }
        let name = jiraAccountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Connected") : String(localized: "Connected as \(name)")
    }

    /// A problem the user has to act on. Offline and rate limits are not: they read in the
    /// Jira issues caption and clear on their own.
    private var jiraProblem: String? {
        switch manager.jiraSync {
        case .authFailed(let status):
            return String(localized: "Token rejected (\(status)). Disconnect, then connect with a new token.")
        case .needsReconnect:
            return String(localized: "Saved Jira sign-in missing or for another site. Disconnect, then connect again.")
        case .failed(let message):
            return message
        case .idle, .syncing, .synced, .offline, .rateLimited, .needsKeychainApproval:
            return nil
        }
    }

    private var rateLimitedUntil: Date? {
        if case .rateLimited(let until) = manager.jiraSync { return until }
        return nil
    }

    /// Refresh, with what the last sync found. While Jira asks Kannu to wait, the button is off
    /// until the time it gave; the timeline redraws once, then, with no polling.
    private var jiraIssuesRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if manager.isJiraSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
                TimelineView(.explicit(rateLimitedUntil.map { [$0] } ?? [])) { context in
                    Button("Refresh") { manager.refreshJira() }
                        .disabled(!canRefresh(at: context.date))
                }
            }
        } label: {
            TimelineView(.explicit(rateLimitedUntil.map { [$0] } ?? [])) { context in
                SettingsRowLabel("Jira issues", description: Text(verbatim: syncCaption(at: context.date)))
            }
        }
    }

    private func canRefresh(at date: Date) -> Bool {
        guard jiraEnabled, manager.isReady, !manager.isJiraSyncing else { return false }
        return rateLimitedUntil.map { $0 <= date } ?? true
    }

    private func syncCaption(at date: Date) -> String {
        guard jiraEnabled else { return String(localized: "Sync paused.") }
        switch manager.jiraSync {
        case .idle:
            return String(localized: "Not synced yet.")
        case .syncing:
            return String(localized: "Syncing…")
        case .synced(let at, let count, let complete):
            let time = at.formatted(date: .omitted, time: .shortened)
            if !complete {
                return String(localized: "Synced \(time) · Showing the first \(count) — narrow the filter")
            }
            return count == 1
                ? String(localized: "Synced \(time) · 1 issue")
                : String(localized: "Synced \(time) · \(count) issues")
        case .offline:
            return String(localized: "Offline.")
        case .rateLimited(let until):
            guard until > date else { return String(localized: "You can refresh again.") }
            return String(localized: "Rate limited until \(until.formatted(date: .omitted, time: .shortened))")
        case .authFailed, .needsKeychainApproval, .needsReconnect, .failed:
            return String(localized: "Not synced.")
        }
    }

    private var issueFilterRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                TextField("Issue filter (JQL)", text: $jiraJQL, prompt: Text(verbatim: JiraAPI.defaultJQL))
                    .labelsHidden()
                    .onSubmit { manager.refreshJira() }
                Button("Reset") {
                    jiraJQL = JiraAPI.defaultJQL
                    manager.refreshJira()
                }
                .disabled(JiraAPI.effectiveJQL(jiraJQL) == JiraAPI.defaultJQL)
            }
        } label: {
            SettingsRowLabel("Issue filter (JQL)", description: "Which issues appear. Return applies it.")
        }
    }

    // MARK: - GitLab

    private var isGitLabConnected: Bool { !gitlabHost.isEmpty }

    @ViewBuilder
    private var gitlabRows: some View {
        gitlabRow

        if isGitLabConnected, let problem = gitlabProblem {
            SettingsErrorText(problem)
        }
        if isGitLabConnected, manager.gitlabSync == .needsKeychainApproval {
            SettingsActionRow("GitLab Keychain access", description: "Let Kannu read the saved GitLab token.") {
                Button("Allow Keychain Access") { manager.refreshGitLab() }
            }
        }
        if !isGitLabConnected, manager.gitlabTokenRemovalFailed {
            SettingsErrorText(String(localized: "Couldn't remove the GitLab token from your Keychain."))
            SettingsActionRow("Saved GitLab token", description: "Or delete com.kannu.app.secure-secrets (gitlab-credential) in Keychain Access.") {
                Button("Remove Token") { manager.retryRemovingGitLabToken() }
            }
        }

        if isGitLabConnected {
            SettingsRow("Sync GitLab", description: gitlabEnabled
                ? Text("Fetch your open GitLab issues.")
                : Text("Sync paused. GitLab tasks stay listed.")) {
                Defaults.Toggle(key: .gitlabEnabled) {
                    Text("Sync GitLab")
                }
            }
            .settingsHighlight(id: highlightID("Sync GitLab"))

            SettingsRow("Include merge requests", description: "Also show MRs assigned to you or awaiting your review.") {
                Defaults.Toggle(key: .gitlabIncludeMergeRequests) {
                    Text("Include merge requests")
                }
            }
            .settingsHighlight(id: highlightID("Include merge requests"))
            // On the row that holds the switch, so it exists whenever the switch is clicked. The
            // task order follows the switch on its own; this brings the fetch in line with it.
            .onChange(of: gitlabIncludeMergeRequests) { _, _ in
                manager.gitlabMergeRequestsSwitched()
            }

            gitlabItemsRow
                .settingsHighlight(id: highlightID("GitLab items"))
        }
    }

    private var gitlabRow: some View {
        LabeledContent {
            if isGitLabConnected {
                Button("Disconnect…") { confirmsGitLabDisconnect = true }
            } else {
                Button("Connect…") { sheet = .connectGitLab }
            }
        } label: {
            VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                Text("GitLab")
                SettingsStatusText(gitlabStatusText, isReady: isGitLabConnected && gitlabEnabled && gitlabProblem == nil)
                if isGitLabConnected {
                    Text(verbatim: gitlabListsText)
                        .settingsDescriptionStyle()
                } else {
                    Text("Your issues and MRs, from gitlab.com or your server.")
                        .settingsDescriptionStyle()
                }
            }
        }
        .settingsHighlight(id: highlightID("GitLab"))
        .onAppear { manager.syncGitLabIfStale() }
        .onChange(of: gitlabEnabled) { _, isOn in
            if isOn { manager.syncGitLabIfStale() }
        }
    }

    /// "Connected as @dana · gitlab.com (can log time)", or "(read-only)" for a `read_api` token.
    private var gitlabStatusText: String {
        guard isGitLabConnected else { return String(localized: "Not connected") }
        let server = GitLabHost.displayName(gitlabHost)
        return gitlabCanLogTime
            ? String(localized: "Connected as @\(gitlabUsername) · \(server) (can log time)")
            : String(localized: "Connected as @\(gitlabUsername) · \(server) (read-only)")
    }

    private var gitlabListsText: String {
        let lists = gitlabIncludeMergeRequests
            ? String(localized: "Lists your open issues and merge requests")
            : String(localized: "Lists your open issues")
        let name = gitlabAccountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? lists : "\(name) · \(lists)"
    }

    /// A problem the user has to act on. Offline and rate limits are not: they read in the
    /// GitLab items caption and clear on their own.
    private var gitlabProblem: String? {
        switch manager.gitlabSync {
        case .authFailed(let status):
            return String(localized: "Token rejected (\(status)). Disconnect, then connect with a new token.")
        case .needsReconnect:
            return String(localized: "Saved GitLab sign-in missing or for another server. Disconnect, then connect again.")
        case .failed(let message):
            return message
        case .idle, .syncing, .synced, .offline, .rateLimited, .needsKeychainApproval:
            return nil
        }
    }

    private var gitlabRateLimitedUntil: Date? {
        if case .rateLimited(let until) = manager.gitlabSync { return until }
        return nil
    }

    /// Refresh, with what the last sync found. While GitLab asks Kannu to wait, the button is off
    /// until the time it gave; the timeline redraws once, then, with no polling.
    private var gitlabItemsRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if manager.isGitLabSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
                TimelineView(.explicit(gitlabRateLimitedUntil.map { [$0] } ?? [])) { context in
                    Button("Refresh") { manager.refreshGitLab() }
                        .disabled(!canRefreshGitLab(at: context.date))
                }
            }
        } label: {
            TimelineView(.explicit(gitlabRateLimitedUntil.map { [$0] } ?? [])) { context in
                SettingsRowLabel("GitLab items", description: Text(verbatim: gitlabSyncCaption(at: context.date)))
            }
        }
    }

    private func canRefreshGitLab(at date: Date) -> Bool {
        guard gitlabEnabled, manager.isReady, !manager.isGitLabSyncing else { return false }
        return gitlabRateLimitedUntil.map { $0 <= date } ?? true
    }

    private func gitlabSyncCaption(at date: Date) -> String {
        guard gitlabEnabled else { return String(localized: "Sync paused.") }
        switch manager.gitlabSync {
        case .idle:
            return String(localized: "Not synced yet.")
        case .syncing:
            return String(localized: "Syncing…")
        case .synced(let at, let count, let complete):
            let time = at.formatted(date: .omitted, time: .shortened)
            if !complete {
                return String(localized: "Synced \(time) · Showing the first \(count)")
            }
            return count == 1
                ? String(localized: "Synced \(time) · 1 item")
                : String(localized: "Synced \(time) · \(count) items")
        case .offline:
            return String(localized: "Offline.")
        case .rateLimited(let until):
            guard until > date else { return String(localized: "You can refresh again.") }
            return String(localized: "Rate limited until \(until.formatted(date: .omitted, time: .shortened))")
        case .authFailed, .needsKeychainApproval, .needsReconnect, .failed:
            return String(localized: "Not synced.")
        }
    }
}

/// The Tasks page below the options: Time to log, Interrupted sessions, and the "Task list ›" row.
/// A separate view so `TasksManager` is created only once tasks are turned on.
private struct TaskOverviewSections: View {
    @ObservedObject private var manager = TasksManager.shared
    @Binding private var sheet: TaskSheet?
    private let openTaskList: () -> Void

    init(sheet: Binding<TaskSheet?>, openTaskList: @escaping () -> Void) {
        _sheet = sheet
        self.openTaskList = openTaskList
    }

    var body: some View {
        if case .failed(let reason) = manager.loadState {
            Section {
                SettingsErrorText(String(localized: "Couldn't read the task list, so it can't change. \(reason)"))
            } header: {
                SettingsSectionHeader("Task list")
            }
        }
        TimeToLogSection()
        interruptedSection
        taskListSection
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
                            Button("Set End Time") {
                                sheet = .endTime(taskID: entry.task.id, segmentID: entry.segment.id, title: entry.task.title, start: entry.segment.start)
                            }
                            Button("Discard") {
                                manager.discardInterruptedSession(segmentID: entry.segment.id, taskID: entry.task.id)
                            }
                        }
                    } label: {
                        SettingsRowLabel(
                            Text(verbatim: entry.task.title),
                            description: Text(verbatim: String(localized: "Timing since \(entry.segment.start.formatted(date: .abbreviated, time: .shortened))"))
                        )
                    }
                }
            } header: {
                SettingsSectionHeader("Interrupted sessions")
            } footer: {
                SettingsFooter("Kannu stopped while timing these. Set an end time or discard.")
            }
        }
    }

    // MARK: - Task list ›

    /// "12 to do · 3 in progress" — every task Kannu holds, whatever the Task list's filters hide —
    /// and the button that opens the Task list.
    private var taskListSection: some View {
        let counts = TaskFacets.counts(manager.activeTasks)
        return Section {
            LabeledContent {
                Button(action: openTaskList) {
                    HStack(spacing: SettingsMetrics.iconGap) {
                        Text("Open")
                        Image(systemName: "chevron.right")
                    }
                }
                .accessibilityLabel("Open task list")
            } label: {
                SettingsRowLabel(
                    "Task list",
                    description: Text(verbatim: String(localized: "\(counts.toDo) to do · \(counts.inProgress) in progress"))
                )
            }
            .settingsHighlight(id: SettingsDeepLink.tasksListHighlightID)
        } header: {
            SettingsSectionHeader("Your tasks")
        }
    }
}

/// The Task list: a back row, the filters, Add a task, the task order and Done and hidden. It lists
/// every task Kannu holds — local, Jira and GitLab, synced or paused (`TasksManager.activeTasks`).
///
/// The filters are this page's own, a view filter only: they persist in Defaults
/// (`tasksListSourceFilter` and the rest), change nothing anywhere else, and while they hide
/// anything the list opens with a "Filtered" row, "3 of 12 tasks", whose Show All clears them.
/// Every move — drag, Move Up and Move Down — counts only the rows shown, so a filtered drag lands
/// where it was dropped.
/// A row is dragged with `draggable` and dropped on with `dropDestination`, which work inside a
/// grouped `Form` on macOS, where `ForEach.onMove` never drags; ⋯ › Move to Top / Up / Down stay
/// as the keyboard and VoiceOver path. The rows here carry no highlight ids: their search entries
/// land on the Tasks page's "Task list" row.
private struct TaskListPage: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    @Default(.tasksListSourceFilter) private var sourceFilter
    @Default(.tasksListProjectFilter) private var projectFilter
    @Default(.tasksListStatusFilter) private var statusFilter
    @Default(.tasksListTagFilter) private var tagFilter
    @Binding private var sheet: TaskSheet?
    @Binding private var pendingDelete: TaskItem?
    @Binding private var newTitle: String
    @Binding private var newEstimate: Int?
    private let close: () -> Void
    @State private var showsDoneAndHidden = false
    /// The row being dragged, once the drag has begun: it says which edge the insertion line takes.
    @State private var draggingID: UUID?
    /// The row the pointer is over during a drag.
    @State private var dropTargetID: UUID?

    private static let estimateChoices = [15, 30, 60, 120, 240, 480].map { $0 * 60 }

    init(sheet: Binding<TaskSheet?>, pendingDelete: Binding<TaskItem?>, newTitle: Binding<String>,
         newEstimate: Binding<Int?>, close: @escaping () -> Void) {
        _sheet = sheet
        _pendingDelete = pendingDelete
        _newTitle = newTitle
        _newEstimate = newEstimate
        self.close = close
    }

    private var filter: TaskFilter {
        TaskFilter(source: sourceFilter, project: TaskFacets.normalizedProjectFilter(projectFilter),
                   status: statusFilter, tag: tagFilter)
    }

    var body: some View {
        Section {
            // The one sanctioned lone leading button in Brain (docs/SETTINGS.md): a sub-page's back
            // row. It carries the Task list's own deep link, so an opened link lands here.
            Button(action: close) {
                Label("Tasks", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back to Tasks")
            .settingsHighlight(id: SettingsDeepLink.tasksListOpenID)
        }
        .onAppear {
            manager.checkReminderPermission()
            // A Project filter saved before project keys: rewrite it once, so the picker selects it.
            let project = TaskFacets.normalizedProjectFilter(projectFilter)
            if project != projectFilter { projectFilter = project }
        }

        if case .failed(let reason) = manager.loadState {
            Section {
                SettingsErrorText(String(localized: "Couldn't read the task list, so it can't change. \(reason)"))
            }
        }
        filtersSection
        tasksSection
        doneAndHiddenSection
    }

    // MARK: - Filters

    /// The pickers offer what every task Kannu holds has, not what the filters left, so a choice
    /// never vanishes from its own picker.
    private var filtersSection: some View {
        let active = manager.activeTasks
        let projects = TaskFacets.projects(in: active)
        let tags = TaskFacets.tags(in: active)
        return Section {
            SettingsRow("Source") {
                Picker("Source", selection: $sourceFilter) {
                    ForEach(TaskSourceFilter.allCases) { choice in
                        Text(choice.localizedName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }

            SettingsRow("Project") {
                Picker("Project", selection: $projectFilter) {
                    Text("All").tag(TaskFacets.anyProject)
                    ForEach(projects, id: \.self) { project in
                        Text(verbatim: TaskFacets.projectName(project)).tag(project)
                    }
                    if TaskFacets.hasTaskWithoutProject(in: active) {
                        Text("No project").tag(TaskFacets.noProject)
                    }
                    // A saved choice no task has any more still shows, so the picker is never blank.
                    if projectFilter != TaskFacets.anyProject, projectFilter != TaskFacets.noProject,
                       !projects.contains(projectFilter) {
                        Text(verbatim: TaskFacets.projectName(projectFilter)).tag(projectFilter)
                    }
                }
            }

            SettingsRow("Status") {
                Picker("Status", selection: $statusFilter) {
                    ForEach(TaskStatusFilter.allCases) { choice in
                        Text(choice.localizedName).tag(choice)
                    }
                }
            }

            SettingsRow("Tag") {
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
            }
        } header: {
            SettingsSectionHeader("Filters")
        }
    }

    /// Show All: every filter back to its default, so every task shows.
    private func showAll() {
        sourceFilter = .all
        projectFilter = TaskFacets.anyProject
        statusFilter = .toDoAndInProgress
        tagFilter = TaskFacets.anyTag
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

            addTaskRow

            LabeledContent {
                // Filtered, the count is on the Filtered row: one fact, said once.
                if !filter.isNarrowing {
                    SettingsValueText(String(localized: "\(total) open"))
                }
            } label: {
                SettingsRowLabel("Task order", description: "Drag to reorder. ▶ starts the timer.")
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
                SettingsActionRow("No tasks match", description: "Change the filters, or show all tasks.") {
                    Button("Show All", action: showAll)
                }
            }

            ForEach(rows) { task in
                draggableRow(task, filter: filter)
            }
        } header: {
            SettingsSectionHeader("Tasks")
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
            SettingsRowLabel("Add a task", description: "Title and optional estimate.")
        }
    }

    private var estimateMenu: some View {
        Menu {
            Button(String(localized: "No estimate")) { newEstimate = nil }
            ForEach(Self.estimateChoices, id: \.self) { seconds in
                Button(WorkDuration.format(seconds)) { newEstimate = seconds }
            }
            Divider()
            Button(String(localized: "Custom")) { sheet = .customEstimateForNewTask(current: newEstimate) }
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

    // MARK: - Drag and drop

    /// A task row that can be dragged onto another, with an insertion line while it is targeted:
    /// above the row when the dragged task comes from below, below it when it comes from above.
    private func draggableRow(_ task: TaskItem, filter: TaskFilter) -> some View {
        let edge = dropTargetID == task.id ? insertionEdge(onto: task.id, filter: filter) : nil
        return taskRow(task, filter: filter)
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
    private func insertionEdge(onto target: UUID, filter: TaskFilter) -> TaskOrdering.DropEdge? {
        guard let draggingID else { return .above }
        return manager.dropEdge(dragging: draggingID, onto: target, filter: filter)
    }

    // MARK: - Rows

    @ViewBuilder
    private func taskRow(_ task: TaskItem, filter: TaskFilter) -> some View {
        let isTimed = manager.timing?.taskID == task.id
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if isTimed {
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
                SettingsMoreMenu {
                    moreItems(for: task, isTimed: isTimed, filter: filter)
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
    private func moreItems(for task: TaskItem, isTimed: Bool, filter: TaskFilter) -> some View {
        let order = manager.listedTasks(filter)
        let position = order.firstIndex { $0.id == task.id }
        // No "…": each acts in place or opens a small sheet (docs/SETTINGS.md).
        Button("Set Estimate") {
            sheet = .estimate(taskID: task.id, title: task.title, current: task.localEstimateSeconds)
        }
        Button("Add Time") {
            sheet = .addTime(taskID: task.id, title: task.title)
        }
        Button("Add Tags") {
            sheet = .tags(taskID: task.id, title: task.title, current: task.tags,
                          existing: TaskFacets.tags(in: manager.tasks))
        }
        if task.source == .local {
            Button("Schedule") {
                sheet = .schedule(taskID: task.id, title: task.title, current: task.scheduledAt)
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
            Button("Delete", role: .destructive) { pendingDelete = task }
                .disabled(isTimed)
        } else {
            // A remote task is finished in its source, and hidden here; deleting it would only
            // bring it back on the next sync.
            if let link = openLink(for: task) {
                Button(link.title) { NSWorkspace.shared.open(link.url) }
            }
            // Whether the time recorded on it is offered in Time to log. Never asking keeps it here.
            if task.logPolicy == .ask {
                Button("Never Ask to Log") { manager.setAsksToLogTime(false, for: task.id) }
            } else {
                Button("Ask to Log") { manager.setAsksToLogTime(true, for: task.id) }
            }
            Button("Hide") { manager.hide(task.id) }
        }
    }

    /// Open in Jira or Open in GitLab, with the page built from (Jira) or checked against (GitLab)
    /// the task's own site or server; nil for a local task or a page Kannu would not open.
    private func openLink(for task: TaskItem) -> (title: LocalizedStringKey, url: URL)? {
        if let url = manager.jiraBrowseURL(for: task) { return ("Open in Jira", url) }
        if let url = manager.gitlabBrowseURL(for: task) { return ("Open in GitLab", url) }
        return nil
    }

    private func taskLabel(_ task: TaskItem, now: Date) -> some View {
        SettingsRowLabel(Text(verbatim: task.title), description: progressText(for: task, now: now))
    }

    /// "42m of 2h", with "10m over" in orange past the estimate. Tracked time is exact, in minutes.
    /// A remote task leads with its key and status and ends with the time its source already has:
    /// "PROJ-123 · In Progress · 42m of 2h · 10m over · Jira logged 3h", "group/app#45 · Open ·
    /// 42m of 2h · GitLab spent 3h", "group/app!12 · Review requested" (the "!" already says merge
    /// request). Then the schedule as one segment ("Due Today 15:00", "Overdue Mon 10:00") and,
    /// last, the tags ("#writing #urgent"). Keys, Jira statuses and tags are verbatim.
    private func progressText(for task: TaskItem, now: Date) -> Text {
        let tracked = manager.trackedSeconds(of: task, now: now)
        let estimate = task.effectiveEstimateSeconds
        var parts: [String] = []
        if let remote = task.remote {
            parts.append(remote.key)
            if let status = TaskFacets.statusName(for: task) { parts.append(status) }
        }
        if let timing = manager.timing, timing.taskID == task.id {
            parts.append(timing.isPaused ? String(localized: "Paused") : String(localized: "Timing now"))
        }
        let progress = TaskTimeMath.progress(tracked: tracked, estimate: estimate)
        parts.append(progress.text)
        var text = Text(verbatim: parts.joined(separator: " · "))
        if let over = progress.over {
            text = text
                + Text(verbatim: " · ")
                + Text(verbatim: String(localized: "\(WorkDuration.format(over)) over")).foregroundStyle(.orange)
        }
        if let spent = task.remote?.remoteSpentSeconds, spent > 0 {
            switch task.source {
            case .jira:
                text = text + Text(verbatim: " · " + String(localized: "Jira logged \(WorkDuration.format(spent))"))
            case .gitlab:
                text = text + Text(verbatim: " · " + String(localized: "GitLab spent \(WorkDuration.format(spent))"))
            case .local:
                break
            }
        }
        if task.source == .local, let scheduled = task.scheduledAt {
            let when = TaskReminderPlan.when(scheduled, now: now)
            text = text + Text(verbatim: " · ")
                + Text(verbatim: Self.scheduleText(scheduled, when: when))
                    .foregroundStyle(when == .overdue ? Color.orange : Color.secondary)
        }
        if !task.tags.isEmpty {
            text = text + Text(verbatim: " · " + task.tags.map { "#\($0)" }.joined(separator: " "))
        }
        return text
    }

    /// One caption segment: "Due Today 15:00", "Due Tomorrow 09:30", "Overdue Mon 10:00", or
    /// "Due Thu 9 Oct, 15:00".
    private static func scheduleText(_ date: Date, when: TaskReminderPlan.When) -> String {
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

    // MARK: - Done and hidden

    private var doneAndHiddenSection: some View {
        let finished = manager.doneAndHiddenTasks
        return Section {
            DisclosureGroup(isExpanded: $showsDoneAndHidden) {
                if finished.isEmpty {
                    SettingsNoteRow("Nothing here yet", description: "Tasks you mark done appear here.")
                }
                ForEach(finished) { task in
                    doneRow(task)
                }
            } label: {
                SettingsRowLabel("Done and hidden", description: "Finished tasks keep their time.")
            }
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
        // A remote task's key comes first, so a hidden PROJ-123 is found by its key.
        let line = task.remote.map { "\($0.key) · \(state)" } ?? state
        let link = openLink(for: task)
        // Every row ends in the same pair, Reopen or Show then ⋯, so the trailing edges line up. A
        // task its source no longer lists comes back only with the source; a remote task with no
        // page Kannu would open has nothing in its ⋯.
        return LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                Button(task.visibility == .done ? String(localized: "Reopen") : String(localized: "Show")) {
                    manager.reopen(task.id)
                }
                .disabled(task.visibility != .done && task.visibility != .hidden)
                SettingsMoreMenu {
                    if task.source == .local {
                        Button("Delete", role: .destructive) { pendingDelete = task }
                    } else if let link {
                        Button(link.title) { NSWorkspace.shared.open(link.url) }
                    }
                }
                .disabled(task.source != .local && link == nil)
            }
        } label: {
            SettingsRowLabel(Text(verbatim: task.title), description: Text(verbatim: line))
        }
    }
}

/// What a task sheet edits.
private enum TaskSheet: Identifiable {
    /// "Custom" in the Add a task row's estimate menu.
    case customEstimateForNewTask(current: Int?)
    case estimate(taskID: UUID, title: String, current: Int?)
    case addTime(taskID: UUID, title: String)
    case endTime(taskID: UUID, segmentID: UUID, title: String, start: Date)
    /// Add Tags on any task, served by `TaskTagsSheet`. `existing` are the tags in use on any task.
    case tags(taskID: UUID, title: String, current: [String], existing: [String])
    /// Schedule on a local task.
    case schedule(taskID: UUID, title: String, current: Date?)
    /// Connect… on the Jira Cloud row: served by `JiraConnectSheet`, not `TaskValueSheet`.
    case connectJira
    /// Connect… on the GitLab row: served by `GitLabConnectSheet`.
    case connectGitLab

    var id: String {
        switch self {
        case .connectJira: return "connect-jira"
        case .connectGitLab: return "connect-gitlab"
        case .customEstimateForNewTask: return "new-task-estimate"
        case .estimate(let taskID, _, _): return "estimate-\(taskID)"
        case .addTime(let taskID, _): return "add-time-\(taskID)"
        case .endTime(_, let segmentID, _, _): return "end-time-\(segmentID)"
        case .tags(let taskID, _, _, _): return "tags-\(taskID)"
        case .schedule(let taskID, _, _): return "schedule-\(taskID)"
        }
    }
}

/// The small sheet behind Custom, Set Estimate, Add Time, Set End Time and Schedule. Its confirm
/// button says what it does: Save, Add or Schedule. A sheet pads its own content; a Form row never
/// does.
private struct TaskValueSheet: View {
    enum Value {
        /// Nil removes an estimate.
        case duration(Int?)
        case date(Date)
        /// Clear Schedule.
        case cleared
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
        case .addTime, .endTime, .schedule, .tags, .connectJira, .connectGitLab:
            _text = State(initialValue: "")
        }
        switch sheet {
        case .endTime(_, _, _, let start):
            // Kannu never guesses the end: the picker starts where the session started.
            _date = State(initialValue: start)
        case .schedule(_, _, let current):
            _date = State(initialValue: current.flatMap { $0 > Date() ? $0 : nil } ?? Self.nextHour())
        default:
            _date = State(initialValue: Date())
        }
    }

    /// The next whole hour: a schedule's starting point.
    private static func nextHour(after now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return calendar.date(byAdding: .hour, value: 1, to: hour) ?? now.addingTimeInterval(3600)
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
            if case .schedule = sheet {
                ReminderPermissionNote()
            }
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
                if case .schedule(_, _, .some) = sheet {
                    Button("Clear Schedule") {
                        onSave(.cleared)
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
        switch sheet {
        case .endTime(_, _, _, let start):
            DatePicker("Stopped working at", selection: $date, in: start...max(start, Date()),
                       displayedComponents: [.date, .hourAndMinute])
        case .schedule:
            DatePicker("Remind me at", selection: $date, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])
        default:
            TextField("Length", text: $text, prompt: Text("1h 30m"))
                .onSubmit(save)
                .onChange(of: text) { _, _ in problem = nil }
        }
    }

    private var heading: LocalizedStringKey {
        switch sheet {
        case .customEstimateForNewTask: return "Custom Estimate"
        case .estimate: return "Set Estimate"
        case .addTime: return "Add Time"
        case .endTime: return "Set End Time"
        case .tags: return "Tags"
        case .schedule: return "Schedule"
        case .connectJira: return "Connect Jira Cloud"
        case .connectGitLab: return "Connect GitLab"
        }
    }

    /// The task's own title, verbatim.
    private var subject: String? {
        switch sheet {
        case .customEstimateForNewTask, .tags, .connectJira, .connectGitLab: return nil
        case .estimate(_, let title, _), .addTime(_, let title), .endTime(_, _, let title, _),
             .schedule(_, let title, _):
            return title
        }
    }

    private var explanation: LocalizedStringKey {
        switch sheet {
        case .customEstimateForNewTask, .estimate:
            return "Such as 1h 30m, 90m or 1.5h."
        case .addTime:
            return "Time worked without the timer, ending now."
        case .endTime:
            return "When did you stop working on it?"
        case .schedule:
            return "A reminder with a Start button."
        case .tags, .connectJira, .connectGitLab:
            return ""
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch sheet {
        case .addTime: return "Add"
        case .schedule: return "Schedule"
        case .customEstimateForNewTask, .estimate, .endTime, .tags, .connectJira, .connectGitLab: return "Save"
        }
    }

    private func save() {
        switch sheet {
        case .endTime, .schedule:
            onSave(.date(date))
            dismiss()
            return
        default:
            break
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEstimate: Bool
        switch sheet {
        case .customEstimateForNewTask, .estimate: isEstimate = true
        default: isEstimate = false
        }
        if trimmed.isEmpty, isEstimate {
            onSave(.duration(nil))
            dismiss()
            return
        }
        guard let seconds = WorkDuration.parse(trimmed), seconds >= 60 else {
            problem = String(localized: "Type at least a minute, such as 1h 30m.")
            return
        }
        onSave(.duration(seconds))
        dismiss()
    }
}

/// The button to macOS's Notifications pane. One literal, for the Task list note and the Schedule
/// sheet (`BrainNamingRulesTests` allows it once: it means the macOS pane, not Brain).
private let openNotificationSettingsTitle: LocalizedStringKey = "Open Notification Settings"

/// "Notifications are off" with a way to turn them on, while macOS blocks Kannu's notifications.
private struct ReminderPermissionNote: View {
    @ObservedObject private var manager = TasksManager.shared

    var body: some View {
        if manager.remindersBlocked {
            HStack(spacing: SettingsMetrics.rowContent) {
                Text("Notifications are off for Kannu.")
                    .settingsDescriptionStyle(tint: .orange)
                Button(openNotificationSettingsTitle) { TaskReminders.openNotificationSettings() }
            }
        }
    }
}

/// Connect… on the Jira Cloud row. The token lives only in this sheet's state until Jira has
/// accepted it; the manager then stores it in the Keychain and the field is cleared. A sheet pads
/// its own content; a Form row never does.
private struct JiraConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    @State private var problem: String?
    @State private var connecting: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text("Connect Jira Cloud")
                .font(.headline)
            Text("Checked with your site, then kept in your Keychain.")
                .settingsDescriptionStyle()
            TextField("Site", text: $site, prompt: Text(verbatim: "acme.atlassian.net"))
            TextField("Email", text: $email, prompt: Text(verbatim: "you@example.com"))
            SecureField("API token", text: $token)
            Link("Create API token…", destination: JiraAPI.createTokenURL)
            if let problem {
                Text(verbatim: problem)
                    .settingsDescriptionStyle(tint: .red)
            }
            HStack(spacing: SettingsMetrics.rowContent) {
                if connecting != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting != nil || !canConnect)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 420)
        .onDisappear {
            connecting?.cancel()
            token = ""
        }
    }

    private var canConnect: Bool {
        !site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.isEmpty
    }

    private func connect() {
        problem = nil
        connecting = Task { @MainActor in
            let failure = await TasksManager.shared.connectJira(siteInput: site, email: email, token: token)
            guard !Task.isCancelled else { return }
            connecting = nil
            if let failure {
                problem = failure
            } else {
                token = ""
                dismiss()
            }
        }
    }

    private func close() {
        connecting?.cancel()
        connecting = nil
        token = ""
        dismiss()
    }
}

/// Connect… on the GitLab row. The server field starts at gitlab.com; a self-managed server is any
/// HTTPS address, with a path if it has one. The token lives only in this sheet's state until GitLab
/// has accepted it; the manager then stores it in the Keychain and the field is cleared. A sheet
/// pads its own content; a Form row never does.
private struct GitLabConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = GitLabHost.defaultServer
    @State private var token = ""
    @State private var problem: String?
    @State private var connecting: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text("Connect GitLab")
                .font(.headline)
            Text("Checked with your server, then kept in your Keychain.")
                .settingsDescriptionStyle()
            TextField("Server", text: $server, prompt: Text(verbatim: GitLabHost.defaultServer))
                .onChange(of: server) { _, _ in problem = nil }
            SecureField("Personal access token", text: $token)
            Text("`api` to log time; `read_api` lists only")
                .settingsDescriptionStyle()
            if let createTokenURL {
                Link("Create token…", destination: createTokenURL)
            }
            if let problem {
                Text(verbatim: problem)
                    .settingsDescriptionStyle(tint: .red)
            }
            HStack(spacing: SettingsMetrics.rowContent) {
                if connecting != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting != nil || !canConnect)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 420)
        .onDisappear {
            connecting?.cancel()
            token = ""
        }
    }

    /// The token page on the server typed so far, once it is an address Kannu would connect to.
    private var createTokenURL: URL? {
        guard case .success(let base) = GitLabHost.normalize(server) else { return nil }
        return GitLabHost.createTokenURL(base: base)
    }

    private var canConnect: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !token.isEmpty
    }

    private func connect() {
        problem = nil
        connecting = Task { @MainActor in
            let failure = await TasksManager.shared.connectGitLab(serverInput: server, token: token)
            guard !Task.isCancelled else { return }
            connecting = nil
            if let failure {
                problem = failure
            } else {
                token = ""
                dismiss()
            }
        }
    }

    private func close() {
        connecting?.cancel()
        connecting = nil
        token = ""
        dismiss()
    }
}
