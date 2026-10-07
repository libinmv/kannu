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
    /// The Task list sub-page, opened: Show all in Brain, and a click on a task reminder.
    case taskList
    /// Time to log: the entries the popover has no room for.
    case timeToLog

    var highlightID: String {
        switch self {
        case .sources: return SettingsDeepLink.tasksSourcesHighlightID
        case .taskList: return SettingsDeepLink.tasksListOpenID
        case .timeToLog: return SettingsDeepLink.tasksTimeToLogHighlightID
        }
    }

    @MainActor
    func open() {
        SettingsWindowController.shared.showWindow(navigatingToAgentStatusHighlight: highlightID)
    }
}

/// The Tasks popover's filter menu, Show in notch: check items show or hide Local, Jira and GitLab
/// tasks in this popover's Up next, and nothing else. They are the notch's own keys
/// (`tasksPopoverShowLocal`, `tasksPopoverShowJira`, `tasksPopoverShowGitLab`), never Sync Jira or
/// Sync GitLab: what is fetched, and what Brain's Task list shows, never change from here
/// (`TaskOrdering.viewFilter`). While it hides a source the glyph is filled, and the popover says
/// "Filtered".
///
/// A source that is not connected offers "Connect Jira…" / "Connect GitLab…" instead, which, like
/// "Manage tasks…", opens Brain at Sources: a token is typed only in Brain's Connect sheet, never
/// in the notch. This menu reads Defaults only — never the Keychain.
struct TaskSourceMenu: View {
    @Default(.tasksPopoverShowLocal) private var showLocal
    @Default(.tasksPopoverShowJira) private var showJira
    @Default(.tasksPopoverShowGitLab) private var showGitLab
    @Default(.jiraSiteHost) private var jiraSiteHost
    @Default(.gitlabHost) private var gitlabHost
    /// Closes the popover, then opens Brain there.
    let openBrain: (TasksBrainDestination) -> Void

    /// A source that is not connected has no check item, so it never counts as hidden: its kept
    /// tasks show (the popover reads the keys the same way).
    private var isNarrowing: Bool {
        TaskOrdering.isNarrowingView(showLocal: showLocal, showJira: showJira || jiraSiteHost.isEmpty,
                                     showGitLab: showGitLab || gitlabHost.isEmpty)
    }

    var body: some View {
        Menu {
            Section("Show in notch") {
                Toggle("Local", isOn: $showLocal)
                if jiraSiteHost.isEmpty {
                    Button("Connect Jira…") { openBrain(.sources) }
                } else {
                    Toggle("Jira", isOn: $showJira)
                }
                if gitlabHost.isEmpty {
                    Button("Connect GitLab…") { openBrain(.sources) }
                } else {
                    Toggle("GitLab", isOn: $showGitLab)
                }
            }
            Divider()
            Button("Manage tasks…") { openBrain(.sources) }
        } label: {
            Image(systemName: isNarrowing ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Filter tasks")
        .hoverTooltip(String(localized: "Filter tasks"), edge: .below)
    }
}
