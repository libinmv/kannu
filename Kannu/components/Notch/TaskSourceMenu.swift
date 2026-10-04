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

/// Where the notch's Tasks controls open Brain: rows of Brain › Productivity › Tasks, reached
/// through the existing deep link (`SettingsDeepLink`, whose id names the tab), so Brain opens on
/// the Tasks tab and scrolls to the row.
enum TasksBrainDestination {
    /// Sources: Manage tasks…, Connect Jira… / Connect GitLab… and the Brain glyph.
    case sources
    /// Task order: Show all in Brain.
    case taskOrder
    /// Time to log: the entries the popover has no room for.
    case timeToLog

    var highlightID: String {
        switch self {
        case .sources: return SettingsDeepLink.tasksSourcesHighlightID
        case .taskOrder: return SettingsDeepLink.tasksOrderHighlightID
        case .timeToLog: return SettingsDeepLink.tasksTimeToLogHighlightID
        }
    }

    @MainActor
    func open() {
        SettingsWindowController.shared.showWindow(navigatingToAgentStatusHighlight: highlightID)
    }
}

/// The Tasks popover's source menu, the "button with integration toggle": check items switch
/// Jira (Sync Jira), GitLab (Sync GitLab) and Local (Local tasks) — the very keys behind the
/// toggles in Brain › Tasks › Sources, so the two always agree, and the task order follows at once.
///
/// A source that is not connected offers "Connect Jira…" / "Connect GitLab…" instead, which, like
/// "Manage tasks…", opens Brain at Sources: a token is typed only in Brain's Connect sheet, never
/// in the notch. This menu reads Defaults only — never the Keychain.
struct TaskSourceMenu: View {
    @Default(.jiraEnabled) private var jiraEnabled
    @Default(.jiraSiteHost) private var jiraSiteHost
    @Default(.gitlabEnabled) private var gitlabEnabled
    @Default(.gitlabHost) private var gitlabHost
    @Default(.showLocalTasks) private var showLocalTasks
    /// Closes the popover, then opens Brain there.
    let openBrain: (TasksBrainDestination) -> Void

    var body: some View {
        Menu {
            if jiraSiteHost.isEmpty {
                Button("Connect Jira…") { openBrain(.sources) }
            } else {
                Toggle("Jira", isOn: $jiraEnabled)
            }
            if gitlabHost.isEmpty {
                Button("Connect GitLab…") { openBrain(.sources) }
            } else {
                Toggle("GitLab", isOn: $gitlabEnabled)
            }
            Toggle("Local", isOn: $showLocalTasks)
            Divider()
            Button("Manage tasks…") { openBrain(.sources) }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Task sources")
        .hoverTooltip(String(localized: "Task sources"), edge: .below)
    }
}
