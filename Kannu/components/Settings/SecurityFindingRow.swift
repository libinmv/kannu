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
    let finding: AgentSecurityFinding
    let copyForAgent: () -> Void
    let acknowledge: () -> Void
    let snooze: () -> Void
    /// Nil when the chat the finding came from has no card to go back to.
    let openChat: (() -> Void)?

    /// Survives re-renders; SwiftUI keys it on the finding's id through the enclosing `ForEach`.
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(finding: AgentSecurityFinding, initiallyExpanded: Bool = false,
         copyForAgent: @escaping () -> Void, acknowledge: @escaping () -> Void, snooze: @escaping () -> Void,
         openChat: (() -> Void)? = nil) {
        self.finding = finding
        self.copyForAgent = copyForAgent
        self.acknowledge = acknowledge
        self.snooze = snooze
        self.openChat = openChat
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var isHigh: Bool { finding.severity == .high }

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
                }

                if isExpanded {
                    // One Text: a drag selects across every line (separate Texts never share a selection).
                    Text(SecurityFindingGuide.details(for: finding))
                        .settingsDescriptionStyle()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    detailsToggle
                    Spacer(minLength: 8)
                    moreMenu
                    Button("Acknowledge", action: acknowledge)
                    CopyForAgentButton(copy: copyForAgent)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private var moreMenu: some View {
        SettingsMoreMenu(accessibilityLabel: Text("More actions")) {
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
