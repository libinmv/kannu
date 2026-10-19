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

/// A source's page in Brain › Tasks (‹ Tasks): its connection, then its projects, each a › to its
/// own page — or, with one project or none, its tasks right there. Local tasks has its colour, Add a
/// task, then its tasks.
///
/// The connection rows are the ones the Sources section used to hold: Connect… or Disconnect…, what
/// needs fixing, Sync, the colour a task from it shows with no tags (`TaskColoring`), Refresh, and
/// Jira's issue filter or GitLab's merge requests. Connection only: Sync decides what is fetched,
/// never what is listed, and a paused source's tasks stay listed. Each source has its own rows,
/// status and Refresh, so one failing never shows on the other.
///
/// Like every row below the overview, nothing here carries a highlight id: their search entries
/// land on the source's row on the overview (docs/SETTINGS.md). Status comes from the Defaults
/// display copies and the manager's sync state, never from the Keychain.
struct TaskSourcePage: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.tasksLocalColor) private var localColor
    let source: TaskSource
    let context: TasksPageContext

    var body: some View {
        switch source {
        case .local:
            Section {
                TaskColorRow(
                    "Local tasks colour",
                    description: "For your own tasks that have no tags.",
                    accessibilityLabel: String(localized: "Local tasks colour: \(localColor.localizedName)"),
                    selection: $localColor
                )
            } header: {
                SettingsSectionHeader("Local tasks")
            }
            Section {
                TaskAddRow(context: context)
                TaskRowList(filter: TaskFilter(source: .local), context: context)
            } header: {
                SettingsSectionHeader("Tasks")
            }
        case .jira:
            JiraConnectionSection(context: context)
            projectsOrTasks
        case .gitlab:
            GitLabConnectionSection(context: context)
            projectsOrTasks
        }
    }

    /// Several projects: one row each, "ds-vendors · 40 open ›", the group path telling two "app"
    /// projects apart. One project or none: the tasks themselves, a level saved.
    @ViewBuilder
    private var projectsOrTasks: some View {
        let tasks = manager.activeTasks.filter { $0.source == source }
        let projects = TaskFacets.projectCounts(in: tasks)
        if projects.count > 1 {
            Section {
                ForEach(projects, id: \.key) { project in
                    let page = TasksPage.project(source, project.key)
                    LabeledContent {
                        TasksOpenButton(
                            text: String(localized: "\(project.count) open"),
                            accessibilityLabel: String(localized: "Open \(TasksSettings.title(of: page))")
                        ) { context.open(page) }
                    } label: {
                        SettingsRowLabel(verbatim: TaskFacets.projectShortName(project.key),
                                         description: TaskFacets.projectGroup(project.key))
                    }
                    .id(page)
                }
            } header: {
                SettingsSectionHeader("Projects")
            }
        } else {
            Section {
                if tasks.isEmpty {
                    SettingsNoteRow("No tasks yet", description: "Open tasks appear here after a sync.")
                }
                TaskRowList(filter: TaskFilter(source: TaskSourceFilter(source)), context: context)
            } header: {
                SettingsSectionHeader("Tasks")
            }
        }
    }
}

/// A project's page (‹ its source): its tasks in the task order, each caption without the project
/// the page already names ("#4326").
struct TaskProjectPage: View {
    let source: TaskSource
    let project: String
    let context: TasksPageContext

    var body: some View {
        Section {
            TaskRowList(filter: TaskFilter(source: TaskSourceFilter(source), project: project),
                        onProjectPage: true, context: context)
        } header: {
            SettingsSectionHeader(TaskFacets.projectShortName(project))
        } footer: {
            if let group = TaskFacets.projectGroup(project) {
                SettingsFooter(group)
            }
        }
    }
}

/// What a source's rows say about its connection, from the Defaults display copies and the
/// manager's sync state — never the Keychain. Shared by the overview's rows and the source pages.
enum TaskSourceStatus {
    static func jiraText(connected: Bool, name: String) -> String {
        guard connected else { return String(localized: "Not connected") }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Connected") : String(localized: "Connected as \(name)")
    }

    /// "Connected as @dana · gitlab.com (can log time)", or "(read-only)" for a `read_api` token.
    static func gitlabText(host: String, username: String, canLogTime: Bool) -> String {
        guard !host.isEmpty else { return String(localized: "Not connected") }
        let server = GitLabHost.displayName(host)
        return canLogTime
            ? String(localized: "Connected as @\(username) · \(server) (can log time)")
            : String(localized: "Connected as @\(username) · \(server) (read-only)")
    }

    /// A problem the user has to act on. Offline and rate limits are not: they read in the Refresh
    /// row's caption and clear on their own.
    static func problem(_ sync: SourceSyncState, source: TaskSource) -> String? {
        switch sync {
        case .authFailed(let status):
            return String(localized: "Token rejected (\(status)). Disconnect, then connect with a new token.")
        case .needsReconnect:
            return source == .gitlab
                ? String(localized: "Saved GitLab sign-in missing or for another server. Disconnect, then connect again.")
                : String(localized: "Saved Jira sign-in missing or for another site. Disconnect, then connect again.")
        case .failed(let message):
            return message
        case .idle, .syncing, .synced, .offline, .rateLimited, .needsKeychainApproval:
            return nil
        }
    }

    /// The Refresh row's caption: what the last sync found, issues for Jira and items for GitLab.
    static func syncCaption(_ sync: SourceSyncState, enabled: Bool, at date: Date, source: TaskSource) -> String {
        guard enabled else { return String(localized: "Sync paused.") }
        switch sync {
        case .idle:
            return String(localized: "Not synced yet.")
        case .syncing:
            return String(localized: "Syncing…")
        case .synced(let at, let count, let complete):
            let time = at.formatted(date: .omitted, time: .shortened)
            if source == .jira {
                if !complete {
                    return String(localized: "Synced \(time) · Showing the first \(count) — narrow the filter")
                }
                return count == 1
                    ? String(localized: "Synced \(time) · 1 issue")
                    : String(localized: "Synced \(time) · \(count) issues")
            }
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

    static func rateLimitedUntil(_ sync: SourceSyncState) -> Date? {
        if case .rateLimited(let until) = sync { return until }
        return nil
    }
}

// MARK: - Jira Cloud

/// Jira's page, its connection: Connect… or Disconnect…, what needs fixing, Sync Jira, its colour,
/// Refresh, and the issue filter under Advanced.
private struct JiraConnectionSection: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.jiraEnabled) private var jiraEnabled
    @Default(.jiraSiteHost) private var jiraSiteHost
    @Default(.jiraAccountDisplayName) private var jiraAccountDisplayName
    @Default(.jiraJQL) private var jiraJQL
    @Default(.jiraTaskColor) private var jiraColor
    @State private var showsAdvanced = false
    let context: TasksPageContext

    private var isConnected: Bool { !jiraSiteHost.isEmpty }
    private var problem: String? { TaskSourceStatus.problem(manager.jiraSync, source: .jira) }
    private var rateLimitedUntil: Date? { TaskSourceStatus.rateLimitedUntil(manager.jiraSync) }

    var body: some View {
        Section {
            LabeledContent {
                if isConnected {
                    Button("Disconnect…") { context.confirmsJiraDisconnect.wrappedValue = true }
                } else {
                    Button("Connect…") { context.sheet.wrappedValue = .connectJira }
                }
            } label: {
                VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                    Text("Jira Cloud")
                    SettingsStatusText(TaskSourceStatus.jiraText(connected: isConnected, name: jiraAccountDisplayName),
                                       isReady: isConnected && jiraEnabled && problem == nil)
                    if isConnected {
                        Text(verbatim: String(localized: "Site \(jiraSiteHost) · Filter: \(JiraAPI.filterSummary(jql: jiraJQL))"))
                            .settingsDescriptionStyle()
                    } else {
                        Text("Your open issues. Needs your site, email and a token.")
                            .settingsDescriptionStyle()
                    }
                }
            }

            if isConnected, let problem {
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
                // On the row that holds the switch, so it exists whenever the switch is clicked.
                .onChange(of: jiraEnabled) { _, isOn in
                    if isOn { manager.syncJiraIfStale() }
                }

                TaskColorRow(
                    "Jira colour",
                    description: "For Jira tasks that have no tags.",
                    accessibilityLabel: String(localized: "Jira colour: \(jiraColor.localizedName)"),
                    selection: $jiraColor
                )

                issuesRow

                DisclosureGroup(isExpanded: $showsAdvanced) {
                    issueFilterRow
                } label: {
                    SettingsRowLabel("Advanced")
                }
            }
        } header: {
            SettingsSectionHeader("Connection")
        }
    }

    /// Refresh, with what the last sync found. While Jira asks Kannu to wait, the button is off
    /// until the time it gave; the timeline redraws once, then, with no polling.
    private var issuesRow: some View {
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
                SettingsRowLabel("Jira issues", description: Text(verbatim: TaskSourceStatus.syncCaption(
                    manager.jiraSync, enabled: jiraEnabled, at: context.date, source: .jira)))
            }
        }
    }

    private func canRefresh(at date: Date) -> Bool {
        guard jiraEnabled, manager.isReady, !manager.isJiraSyncing else { return false }
        return rateLimitedUntil.map { $0 <= date } ?? true
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
}

// MARK: - GitLab

/// GitLab's page, its connection: Connect… or Disconnect…, what needs fixing, Sync GitLab, its
/// colour, merge requests, and Refresh.
private struct GitLabConnectionSection: View {
    @ObservedObject private var manager = TasksManager.shared
    @Default(.gitlabEnabled) private var gitlabEnabled
    @Default(.gitlabHost) private var gitlabHost
    @Default(.gitlabUsername) private var gitlabUsername
    @Default(.gitlabAccountDisplayName) private var gitlabAccountDisplayName
    @Default(.gitlabCanLogTime) private var gitlabCanLogTime
    @Default(.gitlabIncludeMergeRequests) private var gitlabIncludeMergeRequests
    @Default(.gitlabTaskColor) private var gitlabColor
    let context: TasksPageContext

    private var isConnected: Bool { !gitlabHost.isEmpty }
    private var problem: String? { TaskSourceStatus.problem(manager.gitlabSync, source: .gitlab) }
    private var rateLimitedUntil: Date? { TaskSourceStatus.rateLimitedUntil(manager.gitlabSync) }

    var body: some View {
        Section {
            LabeledContent {
                if isConnected {
                    Button("Disconnect…") { context.confirmsGitLabDisconnect.wrappedValue = true }
                } else {
                    Button("Connect…") { context.sheet.wrappedValue = .connectGitLab }
                }
            } label: {
                VStack(alignment: .leading, spacing: SettingsMetrics.labelStack) {
                    Text("GitLab")
                    SettingsStatusText(
                        TaskSourceStatus.gitlabText(host: gitlabHost, username: gitlabUsername, canLogTime: gitlabCanLogTime),
                        isReady: isConnected && gitlabEnabled && problem == nil
                    )
                    if isConnected {
                        Text(verbatim: listsText)
                            .settingsDescriptionStyle()
                    } else {
                        Text("Your issues and MRs, from gitlab.com or your server.")
                            .settingsDescriptionStyle()
                    }
                }
            }

            if isConnected, let problem {
                SettingsErrorText(problem)
            }
            if isConnected, manager.gitlabSync == .needsKeychainApproval {
                SettingsActionRow("GitLab Keychain access", description: "Let Kannu read the saved GitLab token.") {
                    Button("Allow Keychain Access") { manager.refreshGitLab() }
                }
            }
            if !isConnected, manager.gitlabTokenRemovalFailed {
                SettingsErrorText(String(localized: "Couldn't remove the GitLab token from your Keychain."))
                SettingsActionRow("Saved GitLab token", description: "Or delete com.kannu.app.secure-secrets (gitlab-credential) in Keychain Access.") {
                    Button("Remove Token") { manager.retryRemovingGitLabToken() }
                }
            }

            if isConnected {
                SettingsRow("Sync GitLab", description: gitlabEnabled
                    ? Text("Fetch your open GitLab issues.")
                    : Text("Sync paused. GitLab tasks stay listed.")) {
                    Defaults.Toggle(key: .gitlabEnabled) {
                        Text("Sync GitLab")
                    }
                }
                // On the row that holds the switch, so it exists whenever the switch is clicked.
                .onChange(of: gitlabEnabled) { _, isOn in
                    if isOn { manager.syncGitLabIfStale() }
                }

                TaskColorRow(
                    "GitLab colour",
                    description: "For GitLab tasks that have no tags.",
                    accessibilityLabel: String(localized: "GitLab colour: \(gitlabColor.localizedName)"),
                    selection: $gitlabColor
                )

                SettingsRow("Include merge requests", description: "Also show MRs assigned to you or awaiting your review.") {
                    Defaults.Toggle(key: .gitlabIncludeMergeRequests) {
                        Text("Include merge requests")
                    }
                }
                // On the row that holds the switch, so it exists whenever the switch is clicked. The
                // task order follows the switch on its own; this brings the fetch in line with it.
                .onChange(of: gitlabIncludeMergeRequests) { _, _ in
                    manager.gitlabMergeRequestsSwitched()
                }

                itemsRow
            }
        } header: {
            SettingsSectionHeader("Connection")
        }
    }

    private var listsText: String {
        let lists = gitlabIncludeMergeRequests
            ? String(localized: "Lists your open issues and merge requests")
            : String(localized: "Lists your open issues")
        let name = gitlabAccountDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? lists : "\(name) · \(lists)"
    }

    /// Refresh, with what the last sync found. While GitLab asks Kannu to wait, the button is off
    /// until the time it gave; the timeline redraws once, then, with no polling.
    private var itemsRow: some View {
        LabeledContent {
            HStack(spacing: SettingsMetrics.rowContent) {
                if manager.isGitLabSyncing {
                    ProgressView()
                        .controlSize(.small)
                }
                TimelineView(.explicit(rateLimitedUntil.map { [$0] } ?? [])) { context in
                    Button("Refresh") { manager.refreshGitLab() }
                        .disabled(!canRefresh(at: context.date))
                }
            }
        } label: {
            TimelineView(.explicit(rateLimitedUntil.map { [$0] } ?? [])) { context in
                SettingsRowLabel("GitLab items", description: Text(verbatim: TaskSourceStatus.syncCaption(
                    manager.gitlabSync, enabled: gitlabEnabled, at: context.date, source: .gitlab)))
            }
        }
    }

    private func canRefresh(at date: Date) -> Bool {
        guard gitlabEnabled, manager.isReady, !manager.isGitLabSyncing else { return false }
        return rateLimitedUntil.map { $0 <= date } ?? true
    }
}

/// A colour row: the title and description, then the preset swatch. A raw `LabeledContent`, never a
/// `SettingsRow`: the swatch anchors a popover, and `SettingsRow`'s `.labelsHidden()` is for
/// controls whose label the row replaces (docs/SETTINGS.md). The swatch's own label replaces the
/// row's for VoiceOver, so `accessibilityLabel` names what it colours as well as the colour.
struct TaskColorRow: View {
    private let title: LocalizedStringKey
    private let description: LocalizedStringKey
    private let accessibilityLabel: String
    @Binding private var selection: TaskColor

    init(
        _ title: LocalizedStringKey,
        description: LocalizedStringKey,
        accessibilityLabel: String,
        selection: Binding<TaskColor>
    ) {
        self.title = title
        self.description = description
        self.accessibilityLabel = accessibilityLabel
        _selection = selection
    }

    var body: some View {
        LabeledContent {
            TaskColorPickerButton(selection: $selection, accessibilityLabel: accessibilityLabel)
        } label: {
            SettingsRowLabel(title, description: description)
        }
    }
}
