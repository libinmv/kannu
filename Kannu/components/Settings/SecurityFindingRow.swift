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
/// summary, with "Copy for agent" and a "…" menu (Acknowledge, Snooze, Reveal in Finder) on the
/// trailing side. "Details" opens the rest in place — the full summary, the evidence, what the
/// finding means and what to do. All of the text can be selected and copied.
///
/// The row shows `displayedEvidence` (Kannu-only lines such as decoded hidden text included);
/// the copied request is built elsewhere and never carries those lines.
struct SecurityFindingRow: View {
    let finding: AgentSecurityFinding
    let copyForAgent: () -> Void
    let acknowledge: () -> Void
    let snooze: () -> Void

    /// Survives re-renders; SwiftUI keys it on the finding's id through the enclosing `ForEach`.
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(finding: AgentSecurityFinding, initiallyExpanded: Bool = false,
         copyForAgent: @escaping () -> Void, acknowledge: @escaping () -> Void, snooze: @escaping () -> Void) {
        self.finding = finding
        self.copyForAgent = copyForAgent
        self.acknowledge = acknowledge
        self.snooze = snooze
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var isHigh: Bool { finding.severity == .high }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isHigh ? "exclamationmark.shield.fill" : "exclamationmark.shield")
                .foregroundStyle(isHigh ? Color.orange : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: finding.title)
                            .fixedSize(horizontal: false, vertical: true)
                        severityBadge
                    }
                    Text(verbatim: finding.summary)
                        .settingsDescriptionStyle()
                        .lineLimit(isExpanded ? nil : 2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Security finding, \(finding.severity.label): \(finding.title). \(finding.summary)"))

                detailsToggle
                if isExpanded {
                    details
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                CopyForAgentButton(copy: copyForAgent)
                SettingsMoreMenu(accessibilityLabel: Text("More")) {
                    Button("Acknowledge", action: acknowledge)
                    Button("Snooze 24h", action: snooze)
                    if let path = finding.assetPath {
                        Divider()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private var severityBadge: some View {
        Text(verbatim: finding.severity.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isHigh ? Color.orange : Color.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill((isHigh ? Color.orange : Color.secondary).opacity(0.15)))
            .fixedSize()
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

    private var details: some View {
        let guide = SecurityFindingGuide(rule: finding.rule)
        return VStack(alignment: .leading, spacing: 6) {
            if !finding.displayedEvidence.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(finding.displayedEvidence, id: \.self) { line in
                        Text(verbatim: line)
                    }
                }
                .settingsDescriptionStyle()
            }
            detailParagraph(Text("What it means"), guide.whatItIs)
            detailParagraph(Text("What to do"), guide.whatToDo)
        }
        .padding(.leading, 14)
        .padding(.top, 2)
    }

    private func detailParagraph(_ heading: Text, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            heading
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: body)
                .settingsDescriptionStyle()
        }
        .textSelection(.enabled)
    }
}
