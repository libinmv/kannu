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
    /// Sources: Manage tasks…, Add a source… and the Brain glyph.
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

/// The Tasks popover's filter menu, Show in notch: check items show or hide Local tasks and each
/// connected source's in this popover's Up next, and nothing else. They are the notch's own keys
/// (`TaskSource.showInNotchKey`), never a source's Sync switch: what is fetched, and what Brain's
/// Task list shows, never change from here (`TaskOrdering.viewFilter`). While it hides a source the
/// glyph is filled, and the popover says "Filtered".
///
/// A source that is not connected has no check item; "Add a source…", like "Manage tasks…", opens
/// Brain at Sources: a token is typed only in Brain's Connect sheet, never in the notch. This menu
/// reads Defaults only — never the Keychain.
struct TaskSourceMenu: View {
    @ObservedObject private var preferences = TaskSourcePreferences.shared
    /// Closes the popover, then opens Brain there.
    let openBrain: (TasksBrainDestination) -> Void
    /// The popover's header glyph, or the timer tab's rail icon (`TimerRailIcon`'s square).
    var style: Style = .header

    enum Style {
        case header
        case rail
    }

    /// A source that is not connected has no check item, so it never counts as hidden: its kept
    /// tasks show (`TaskSourcePreferences.hiddenInNotch`; the popover reads it the same way).
    private var isNarrowing: Bool { preferences.isNarrowing }

    var body: some View {
        Menu {
            Section("Show in notch") {
                ForEach([TaskSource.local] + preferences.connected, id: \.self) { source in
                    Toggle(isOn: preferences.shownBinding(for: source)) {
                        Text(verbatim: source.name)
                    }
                }
                if preferences.connected.count < TaskSource.remoteSources.count {
                    Button("Add a source…") { openBrain(.sources) }
                }
            }
            if isNarrowing {
                // Every source back in the notch, without unticking each.
                Button(String(localized: "Show all")) { preferences.showAll() }
            }
            Divider()
            Button("Manage tasks…") { openBrain(.sources) }
        } label: {
            switch style {
            case .header:
                Image(systemName: isNarrowing ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .imageScale(.large)
            case .rail:
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: TimerComposerMetrics.railGlyphSize, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The rail's square is drawn around the menu, not in its label: a borderless menu draws
        // only its label's glyph. Brighter while it hides a source, as the header's glyph fills.
        .modifier(RailSquare(isOn: style == .rail, isActive: isNarrowing))
        .accessibilityLabel("Filter tasks")
        .hoverTooltip(String(localized: "Filter tasks"), edge: .below)
    }
}

/// The rail icon's 21 pt square around the filter menu, in the rail style only.
private struct RailSquare: ViewModifier {
    @Environment(\.notchForeground) private var notchForeground
    let isOn: Bool
    let isActive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isOn {
            content
                .foregroundStyle(notchForeground.opacity(0.85))
                .frame(width: TimerComposerMetrics.railButtonSize, height: TimerComposerMetrics.railButtonSize)
                .background(RailIconBackground(isActive: isActive))
                .contentShape(Rectangle())
        } else {
            content
        }
    }
}
