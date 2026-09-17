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

import SwiftUI

/// The "View rules" box: the agent policy's rules, readably, in a small popover — the icon says
/// command or tool, the matched text is exact and monospaced, the reason sits underneath.
/// Pure display: the data is whatever `AgentPolicy.load` returned; nothing here re-reads the file.
struct PolicyRulesView: View {
    let policy: AgentPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(policy.rules.count) rules · ~/.kannu/agent-policy.json")
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
            Divider()
            // A policy can hold 200 rules; the box scrolls instead of towering.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(policy.rules.enumerated()), id: \.offset) { _, rule in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: rule.displayIconName)
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                                .accessibilityLabel(rule.command != nil
                                    ? Text("Command rule") : Text("Tool rule"))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: rule.displayTitle)
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                if let reason = rule.reason, !reason.isEmpty {
                                    Text(verbatim: reason)
                                        .settingsDescriptionStyle()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
        }
        .padding(12)
        .frame(width: 380)
    }
}
