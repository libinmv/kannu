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

/// Brain › Tasks: the task list in the order the user will work through it, an estimate per task,
/// and the actual time recorded when a task is timed with Kannu's timer.
///
/// Built only from the `SettingsComponents` shapes (docs/SETTINGS.md). A task row carries a ▶ and a
/// `SettingsMoreMenu`, so it is a raw `LabeledContent` with a `SettingsRowLabel` — the `analysisRow`
/// shape — never a `SettingsRow`, whose `.labelsHidden()` would erase the menu. Task titles are the
/// user's own text and render verbatim.
///
/// With tasks off nothing here touches `TasksManager`, so the tab never reads the task file.
///
/// The Sources section (Jira Cloud, GitLab, Local tasks) shows what the Defaults display copies
/// say. This file never reads the Keychain: a sync does, off the main actor, in `TasksManager`.
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

    private func highlightID(_ title: String) -> String { "tasks-\(title)" }

    var body: some View {
        Form {
            if enableTasks {
                TaskSourcesSection(
                    sheet: $sheet,
                    confirmsJiraDisconnect: $confirmsJiraDisconnect,
                    confirmsGitLabDisconnect: $confirmsGitLabDisconnect
                )
            }

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
            switch sheet {
            case .connectJira:
                JiraConnectSheet()
            case .connectGitLab:
                GitLabConnectSheet()
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
            Text("The time recorded on it is deleted too.")
        }
        .confirmationDialog("Disconnect Jira?", isPresented: $confirmsJiraDisconnect, titleVisibility: .visible) {
            Button("Keep Jira Tasks") { TasksManager.shared.disconnectJira(removeTasks: false) }
            Button("Remove Jira Tasks", role: .destructive) { TasksManager.shared.disconnectJira(removeTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kannu forgets the API token and stops syncing. Keep the Jira tasks on this Mac, with the time recorded on them, or remove them.")
        }
        .confirmationDialog("Disconnect GitLab?", isPresented: $confirmsGitLabDisconnect, titleVisibility: .visible) {
            Button("Keep GitLab Tasks") { TasksManager.shared.disconnectGitLab(removeTasks: false) }
            Button("Remove GitLab Tasks", role: .destructive) { TasksManager.shared.disconnectGitLab(removeTasks: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Kannu forgets the personal access token and stops syncing. Keep the GitLab issues and merge requests on this Mac, with the time recorded on them, or remove them.")
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

/// Where tasks come from: Jira Cloud, GitLab and the user's own. A separate view so `TasksManager`
/// is created only once tasks are turned on. Each source has its own rows, status and Refresh: one
/// failing never shows on the other.
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
                SettingsActionRow("Keychain access", description: "macOS asks before Kannu reads the saved Jira token. Allow it and syncing carries on.") {
                    Button("Allow Keychain Access") { manager.refreshJira() }
                }
            }
            if !isConnected, manager.jiraTokenRemovalFailed {
                SettingsErrorText(String(localized: "Kannu could not remove the saved Jira token from your Keychain, so it is still there."))
                SettingsActionRow("Saved Jira token", description: "Try again. If it stays, delete it in Keychain Access: the com.kannu.app.secure-secrets item whose account is jira-credential.") {
                    Button("Remove Token") { manager.retryRemovingJiraToken() }
                }
            }

            if isConnected {
                SettingsRow("Sync Jira", description: "Your Jira issues appear in the task order, mixed with your own, and are refreshed when this page opens. Off: they are not fetched and leave the task order.") {
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

            SettingsRow("Local tasks", description: "The tasks you add here. Off: they leave the task order and Add a task is hidden. Nothing is deleted.") {
                Defaults.Toggle(key: .showLocalTasks) {
                    Text("Local tasks")
                }
            }
            .settingsHighlight(id: highlightID("Local tasks"))
        } header: {
            SettingsSectionHeader("Sources")
        } footer: {
            SettingsFooterStack {
                SettingsFooter("Kannu reads your Jira issues from your Jira site only, over HTTPS, and writes nothing to Jira. The API token is kept in your Keychain. A classic API token carries all of your Jira permissions, so create one just for Kannu and revoke it when you stop using it.")
                SettingsFooter("Kannu reads your GitLab issues and merge requests from your GitLab server only, over HTTPS with a certificate macOS trusts, and writes nothing to GitLab. The personal access token is kept in your Keychain. A read_api token is enough to list; create one just for Kannu, with an expiry date.")
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
                    Text("Your open Jira issues in the task order, beside your own tasks. Needs your site, your Atlassian email and an API token.")
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
            return String(localized: "Token rejected (\(status)): it may have expired or been revoked. Disconnect, then connect again with a new token.")
        case .needsReconnect:
            return String(localized: "The saved Jira sign-in is missing, or belongs to another site. Disconnect, then connect again.")
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
        guard jiraEnabled else { return String(localized: "Sync Jira is off.") }
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
            return String(localized: "Offline. Refresh once you are back online.")
        case .rateLimited(let until):
            guard until > date else { return String(localized: "Jira asked Kannu to wait. You can refresh again.") }
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
            SettingsRowLabel("Issue filter (JQL)", description: "Which issues appear, in Jira's query language. Press Return to apply it. Empty uses the default: your open issues, most recently updated first.")
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
            SettingsActionRow("GitLab Keychain access", description: "macOS asks before Kannu reads the saved GitLab token. Allow it and syncing carries on.") {
                Button("Allow Keychain Access") { manager.refreshGitLab() }
            }
        }
        if !isGitLabConnected, manager.gitlabTokenRemovalFailed {
            SettingsErrorText(String(localized: "Kannu could not remove the saved GitLab token from your Keychain, so it is still there."))
            SettingsActionRow("Saved GitLab token", description: "Try again. If it stays, delete it in Keychain Access: the com.kannu.app.secure-secrets item whose account is gitlab-credential.") {
                Button("Remove Token") { manager.retryRemovingGitLabToken() }
            }
        }

        if isGitLabConnected {
            SettingsRow("Sync GitLab", description: "Your GitLab issues appear in the task order, mixed with your own, and are refreshed when this page opens. Off: they are not fetched and leave the task order.") {
                Defaults.Toggle(key: .gitlabEnabled) {
                    Text("Sync GitLab")
                }
            }
            .settingsHighlight(id: highlightID("Sync GitLab"))

            SettingsRow("Include merge requests", description: "Open merge requests assigned to you or waiting for your review join the task order beside your issues. Off: they leave the task order, and only issues are fetched.") {
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
                    Text("Your open GitLab issues, and the merge requests assigned to you or waiting for your review, in the task order beside your own tasks. gitlab.com or your own GitLab server; needs a personal access token.")
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
            return String(localized: "Token rejected (\(status)): it may have expired or been revoked. Disconnect, then connect again with a new token.")
        case .needsReconnect:
            return String(localized: "The saved GitLab sign-in is missing, or belongs to another server. Disconnect, then connect again.")
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
        guard gitlabEnabled else { return String(localized: "Sync GitLab is off.") }
        switch manager.gitlabSync {
        case .idle:
            return String(localized: "Not synced yet.")
        case .syncing:
            return String(localized: "Syncing…")
        case .synced(let at, let count, let complete):
            let time = at.formatted(date: .omitted, time: .shortened)
            if !complete {
                return String(localized: "Synced \(time) · Showing the first \(count): you have more than Kannu lists")
            }
            return count == 1
                ? String(localized: "Synced \(time) · 1 item")
                : String(localized: "Synced \(time) · \(count) items")
        case .offline:
            return String(localized: "Offline. Refresh once you are back online.")
        case .rateLimited(let until):
            guard until > date else { return String(localized: "GitLab asked Kannu to wait. You can refresh again.") }
            return String(localized: "Rate limited until \(until.formatted(date: .omitted, time: .shortened))")
        case .authFailed, .needsKeychainApproval, .needsReconnect, .failed:
            return String(localized: "Not synced.")
        }
    }
}

/// Everything below the switches. A separate view so `TasksManager` is created only once tasks
/// are turned on.
private struct TaskListSections: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.enableTimerFeature) private var enableTimerFeature
    @Default(.showLocalTasks) private var showLocalTasks
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
            if showLocalTasks {
                addTaskRow
            }

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
        if task.source == .local {
            Button("Mark Done") { manager.markDone(task.id) }
            Button("Delete…", role: .destructive) { pendingDelete = task }
                .disabled(isTimed)
        } else {
            // A remote task is finished in its source, and hidden here; deleting it would only
            // bring it back on the next sync.
            if let link = openLink(for: task) {
                Button(link.title) { NSWorkspace.shared.open(link.url) }
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
    /// "PROJ-123 · In Progress · 42m of 2h · 10m over · Jira logged 3h", "group/app#45 · opened ·
    /// 42m of 2h · GitLab spent 3h", "group/app!12 · MR · review requested". Remote text is verbatim.
    private func progressText(for task: TaskItem, now: Date) -> Text {
        let tracked = manager.trackedSeconds(of: task, now: now)
        let estimate = task.effectiveEstimateSeconds
        var parts: [String] = []
        if let remote = task.remote {
            parts.append(remote.key)
            if remote.gitlabKind == .mergeRequest { parts.append(String(localized: "MR")) }
            if !remote.status.isEmpty { parts.append(remote.status) }
        }
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
        var text = Text(verbatim: parts.joined(separator: " · "))
        let over = TaskTimeMath.overtimeSeconds(estimate: estimate, tracked: tracked)
        if over >= 60 {
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
        return text
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
        // A remote task's key comes first, so a hidden PROJ-123 is found by its key.
        let line = task.remote.map { "\($0.key) · \(state)" } ?? state
        let link = openLink(for: task)
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
                } else if let link {
                    SettingsMoreMenu {
                        Button(link.title) { NSWorkspace.shared.open(link.url) }
                    }
                }
            }
        } label: {
            SettingsRowLabel(Text(verbatim: task.title), description: Text(verbatim: line))
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
        case .addTime, .endTime, .connectJira, .connectGitLab:
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
        case .connectJira: return "Connect Jira Cloud"
        case .connectGitLab: return "Connect GitLab"
        }
    }

    /// The task's own title, verbatim.
    private var subject: String? {
        switch sheet {
        case .customEstimateForNewTask, .connectJira, .connectGitLab: return nil
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
        case .connectJira, .connectGitLab:
            return ""
        }
    }

    private var primaryTitle: LocalizedStringKey {
        switch sheet {
        case .addTime: return "Add"
        case .customEstimateForNewTask, .estimate, .endTime, .connectJira, .connectGitLab: return "Set"
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
        case .addTime, .endTime, .connectJira, .connectGitLab: isEstimate = false
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
            Text("Kannu checks the token with your Jira site before saving it in your Keychain, then lists your issues. It writes nothing to Jira.")
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
            Text("Kannu checks the token with your GitLab server before saving it in your Keychain, then lists your open issues and merge requests. It writes nothing to GitLab.")
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
