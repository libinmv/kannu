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
import SwiftUI

/// One security finding in Settings, compact until asked: the title, severity and a two-line
/// summary; "Details" opens the rest in place as one block of selectable text (the evidence, what
/// the finding means and what to do). The actions sit on the bottom row, trailing: a "…" menu
/// (Snooze, Reveal File, Reveal Project Folder, Open Chat, Copy Details), Acknowledge and Copy for
/// agent.
///
/// The row shows `displayedEvidence` (Kannu-only lines such as decoded hidden text included);
/// Copy for agent and Copy Details are built elsewhere and never carry those lines.
struct SecurityFindingRow: View {
    let row: SecurityFindingGroups.Row
    let copyForAgent: () -> Void
    /// `nil` projects means everywhere; a list narrows the decision to those projects.
    let acknowledge: ([String]?) -> Void
    let snooze: () -> Void
    /// Nil when the chat the finding came from has no card to go back to.
    let openChat: (() -> Void)?

    /// Survives re-renders; SwiftUI keys it on the group's id through the enclosing `ForEach`.
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(row: SecurityFindingGroups.Row, initiallyExpanded: Bool = false,
         copyForAgent: @escaping () -> Void, acknowledge: @escaping ([String]?) -> Void,
         snooze: @escaping () -> Void, openChat: (() -> Void)? = nil) {
        self.row = row
        self.copyForAgent = copyForAgent
        self.acknowledge = acknowledge
        self.snooze = snooze
        self.openChat = openChat
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var group: AgentSecurityFindingGroup { row.group }
    /// The row speaks as the group's worst, most recent member.
    private var finding: AgentSecurityFinding { group.representative }
    private var isHigh: Bool { group.severity == .high }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isHigh ? "exclamationmark.shield.fill" : "exclamationmark.shield")
                .foregroundStyle(isHigh ? Color.orange : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: finding.title)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityLabel(Text("Security finding, \(finding.severity.label): \(finding.title)"))
                        severityBadge
                    }
                    Text(verbatim: finding.summary)
                        .settingsDescriptionStyle()
                        .lineLimit(isExpanded ? nil : 2)
                    if let recurrence { SettingsValueText(recurrence) }
                    if let state = stateNote { SettingsValueText(state) }
                }

                if isExpanded {
                    // One Text: a drag selects across every line (separate Texts never share a selection).
                    Text(SecurityFindingGuide.details(for: finding))
                        .settingsDescriptionStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let breakdown { SettingsValueText(breakdown) }
                }

                HStack(spacing: 8) {
                    detailsToggle
                    Spacer(minLength: 8)
                    moreMenu
                    Button(acknowledgeLabel) { acknowledge(narrowScope) }
                    CopyForAgentButton(copy: copyForAgent)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    /// "7 occurrences · first 17 Sep at 15:49 · last 25 Sep at 16:41". Omitted when the row stands
    /// for a single sighting, where a count of 1 and two identical dates say nothing.
    private var recurrence: String? {
        guard group.occurrences > 1 || group.distinctFindings > 1 else { return nil }
        let first = group.firstSeen.formatted(date: .abbreviated, time: .shortened)
        let last = group.lastSeen.formatted(date: .abbreviated, time: .shortened)
        var parts = [String(localized: "\(group.occurrences) occurrences")]
        parts.append(String(localized: "first \(first)"))
        if group.lastSeen != group.firstSeen { parts.append(String(localized: "last \(last)")) }
        return parts.joined(separator: " · ")
    }

    /// Why the row is still here after being acknowledged — the honest half of grouping. Without it
    /// a partially acknowledged group looks like the acknowledgement simply failed.
    private var stateNote: String? {
        switch row.visibility {
        case .unacknowledged:
            return nil
        case .escalated(let reason):
            return String(localized: "Back because it is \(reason)")
        case .partiallyAcknowledged(let outstanding):
            guard !outstanding.isEmpty else {
                return String(localized: "Acknowledged for a project, but this one belongs to none — acknowledge everywhere to settle it")
            }
            return String(localized: "Still open in \(outstanding.joined(separator: ", "))")
        case .acknowledged:
            return String(localized: "Acknowledged")
        }
    }

    /// The spread, shown only when expanded: what the row folded together, so the grouping is
    /// legible rather than magic.
    private var breakdown: String? {
        var parts: [String] = []
        if group.distinctFindings > 1 {
            // For a rotating credential this is the number that matters: 21 distinct keys, not 21 rows.
            parts.append(String(localized: "\(group.distinctFindings) separate sightings folded in"))
        }
        if group.projects.count > 1 {
            parts.append(String(localized: "projects: \(group.projects.joined(separator: ", "))"))
        }
        let chats = Set(group.findings.compactMap(\.sessionID)).count
        if chats > 1 { parts.append(String(localized: "across \(chats) chats")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Narrow by default: the projects this group has actually been seen in. `nil` means everywhere,
    /// and is reserved for the menu — or for a group that belongs to no project at all, where
    /// project scoping cannot settle anything.
    private var narrowScope: [String]? { group.projects.isEmpty ? nil : group.projects }

    private var acknowledgeLabel: String {
        switch group.projects.count {
        case 0: return String(localized: "Acknowledge")
        case 1: return String(localized: "Acknowledge for \(group.projects[0])")
        default: return String(localized: "Acknowledge for \(group.projects.count) projects")
        }
    }

    private var moreMenu: some View {
        SettingsMoreMenu(accessibilityLabel: Text("More actions")) {
            if !group.projects.isEmpty {
                // Only worth offering when the primary action was the narrow one.
                Button("Acknowledge everywhere") { acknowledge(nil) }
                Divider()
            }
            Button("Snooze 24h", action: snooze)
            if finding.revealPath != nil || finding.projectFolder != nil || openChat != nil {
                Divider()
            }
            if let path = finding.revealPath {
                Button("Reveal File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if let folder = finding.projectFolder {
                Button("Reveal Project Folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder, isDirectory: true)])
                }
            }
            if let openChat {
                Button("Open Chat", action: openChat)
            }
            Divider()
            Button("Copy Details") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(SecurityFindingGuide.detailsText(for: finding), forType: .string)
            }
        }
    }

    private var severityBadge: some View {
        Text(verbatim: finding.severity.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isHigh ? Color.orange : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill((isHigh ? Color.orange : Color.secondary).opacity(0.15)))
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var detailsToggle: some View {
        Button {
            if reduceMotion {
                isExpanded.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text("Details")
            }
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? Text("Hide details") : Text("Show details"))
    }
}
