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

/// Settings pane for the notch's Usage tab: the LLM usage monitor and its providers.
/// Lives beside the Agents pane in the "AI Agents" sidebar group, mirroring how the notch
/// presents Agent Status and Usage as sibling tabs. (These sections previously hid inside
/// the Stats pane under Developer.)
struct UsageSettings: View {
    @Default(.enableLLMUsageFeature) var enableLLMUsageFeature

    private func highlightID(_ title: String) -> String {
        "llmUsage-\(title)"
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableLLMUsageFeature) {
                    Text("Enable LLM Usage Monitor")
                }
                .settingsHighlight(id: highlightID("Enable LLM Usage Monitor"))
            } header: {
                Text("Usage Monitor")
            } footer: {
                SettingsFooter("Adds a Usage tab to the notch that tracks token usage and spend across your configured AI providers.")
            }

            if enableLLMUsageFeature {
                Section {
                    Defaults.Toggle(key: .enableClaudeProvider) {
                        Text("Claude")
                    }
                    .settingsHighlight(id: highlightID("Claude Provider"))

                    Defaults.Toggle(key: .enableCodexProvider) {
                        Text("Codex")
                    }
                    .settingsHighlight(id: highlightID("Codex Provider"))

                    Defaults.Toggle(key: .enableCursorProvider) {
                        Text("Cursor")
                    }
                    .settingsHighlight(id: highlightID("Cursor Provider"))

                    Defaults.Toggle(key: .enableAntigravityProvider) {
                        Text("Antigravity")
                    }
                    .settingsHighlight(id: highlightID("Antigravity Provider"))
                } header: {
                    Text("Providers")
                } footer: {
                    SettingsFooter("Choose which AI providers appear in the Usage tab. Claude reads everything from local files and needs no permission; the gauge button on its card hides or shows the rate-limit bars. Codex and Cursor need each CLI signed in locally. Full Disk Access is not required.")
                }

                Section {
                    SettingsRow("Show a gauge beside the lights near a limit", description: "When any usage limit passes 95%, a small gauge appears next to the traffic light. It goes away when the limit resets.") {
                        Defaults.Toggle(key: .showUsageLimitCue) {
                            Text("Show a gauge beside the lights near a limit")
                        }
                    }
                    .settingsHighlight(id: highlightID("Show a gauge beside the lights near a limit"))
                    SettingsRow("Check Codex and Cursor limits in the background", description: "While a Codex or Cursor agent is working, Kannu asks for your usage every 5 minutes — the same request the Usage tab makes when it is open. Off: they update only while the Usage tab is open.") {
                        Defaults.Toggle(key: .checkQuotaInBackground) {
                            Text("Check Codex and Cursor limits in the background")
                        }
                    }
                    .settingsHighlight(id: highlightID("Check Codex and Cursor limits in the background"))
                } header: {
                    Text("Alerts")
                } footer: {
                    SettingsFooter("Each bar also says where it is heading at your current pace, once Kannu has seen it for a little while. A phone push for a nearly full limit is under Agents › Mobile notifications.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Usage")
    }
}

#Preview {
    UsageSettings()
}
