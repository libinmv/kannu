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

/// Claude Code cloud sessions (docs/CLOUD-SESSIONS.md), a section of the Agents tab. Off by default
/// and behind a consent alert. Kannu never writes into a repository: the repository half is handed
/// to the user's own agent to commit, and the key goes only to the Keychain and, marked concealed,
/// to the clipboard.
struct AgentCloudSessionsSettings: View {
    @ObservedObject private var relay = ClaudeCloudRelayManager.shared
    @Default(.claudeCloudRelayEnabled) private var enabled
    @Default(.claudeCloudRelayConsentedAt) private var consentedAt
    @Default(.claudeCloudRelayServerURL) private var serverURL
    @State private var showConsent = false
    @State private var confirmNewKey = false
    @State private var copiedVariables = false
    @State private var copiedResetTask: Task<Void, Never>?

    /// The literal form: `SettingsTab` is private to SettingsView.swift, and the highlight
    /// inventory test accepts exactly this shape (the UsageSettings precedent).
    private func highlightID(_ title: String) -> String {
        "agentStatus-\(title)"
    }

    var body: some View {
        Section {
            // Consent through a SwiftUI alert, as ADR Detection asks for it: a modal inside the
            // binding's setter fought the toggle's own state update.
            SettingsRow("Show cloud sessions", description: "Opt-in. Claude Code sessions running in the cloud report their light through a relay: from repositories that carry Kannu's relay hook, in cloud environments that hold your relay key.") {
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        guard newValue else { enabled = false; return }
                        if consentedAt == nil {
                            showConsent = true
                            return
                        }
                        enabled = true
                    }
                )) {
                    Text("Show cloud sessions")
                }
            }
            .settingsHighlight(id: highlightID("Show cloud sessions"))
            .alert("Show Claude Code cloud sessions?", isPresented: $showConsent) {
                Button("Turn on") {
                    consentedAt = Date()
                    enabled = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ClaudeCloudRelaySetup.consentText)
            }

            if enabled {
                setupRows
            }
        } header: {
            SettingsSectionHeader("Cloud Sessions")
        } footer: {
            SettingsFooter("A report carries the session id, the light's state, the hook event, the notification kind, the repository folder's name and a timestamp. Never a prompt, a command, a file or any output. Turning this off keeps the key; New key revokes it.")
        }
    }

    @ViewBuilder
    private var setupRows: some View {
        TextField("Relay server", text: $serverURL)
            .textFieldStyle(.roundedBorder)
            .settingsHighlight(id: highlightID("Relay server"))
        if !SecurityURLPolicy.isAllowedCloudRelayServerURL(serverURL) {
            SettingsErrorText(String(localized: "Use the https:// address of a public server, such as https://ntfy.sh."))
        }

        SettingsActionRow("Relay key", description: "Paste these variables into each cloud environment that should report, never into a repository. They are copied marked as private, so clipboard managers skip them.") {
            Button {
                copiedVariables = relay.copyEnvironmentVariables()
                copiedResetTask?.cancel()
                copiedResetTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    copiedVariables = false
                }
            } label: {
                Text("Copy variables")
                    .opacity(copiedVariables ? 0 : 1)
                    .overlay { if copiedVariables { Text("Copied") } }
            }
            Button("New key…") { confirmNewKey = true }
        }
        .settingsHighlight(id: highlightID("Relay key"))
        .alert("Replace the relay key?", isPresented: $confirmNewKey) {
            Button("Replace", role: .destructive) { relay.regenerateKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every cloud environment holding the current key stops reporting until you paste the new variables into it. Use this if the key may have leaked.")
        }
        .onDisappear { copiedResetTask?.cancel() }

        SettingsActionRow("Prepare a repository", description: "Copies a request for your coding agent, run in the repository: add Kannu's relay hook and commit it. It contains no key.") {
            CopyForAgentButton(help: "Copies a request for your coding agent to add the relay hook to the repository it runs in. It contains no key, and nothing is sent.") {
                Self.copy(ClaudeCloudRelaySetup.repositoryPrompt())
            }
            SettingsMoreMenu {
                Button("Copy the script") { Self.copy(ClaudeCloudRelaySetup.scriptSource) }
                Button("Copy the hooks") { Self.copy(ClaudeCloudRelaySetup.hooksJSON()) }
            }
        }
        .settingsHighlight(id: highlightID("Prepare a repository"))

        SettingsNoteRow("Cloud environment", description: environmentNote)
            .settingsHighlight(id: highlightID("Cloud environment"))

        SettingsRow("Status") {
            SettingsStatusText(statusText, isReady: relay.status == .listening)
        }
        .settingsHighlight(id: highlightID("Cloud relay status"))
    }

    private var host: String {
        ClaudeCloudRelaySetup.allowlistHost(server: serverURL) ?? String(localized: "the relay server")
    }

    private var environmentNote: String {
        String(localized: "In the cloud environment's settings, set Network access to Custom and allow \(host), then paste the variables. Use an environment only you use: anyone who can start a session in it can read the key. To test, run bash .claude/hooks/kannu-cloud-relay.sh --check in a cloud session.")
    }

    private var statusText: String {
        var parts: [String]
        switch relay.status {
        case .off:
            parts = [String(localized: "Off")]
        case .invalidServer:
            parts = [String(localized: "Not listening: the relay server is not a public https:// address")]
        case .connecting:
            parts = [String(localized: "Connecting to \(host)…")]
        case .listening:
            parts = [String(localized: "Listening on \(host)")]
            let count = relay.snapshot.events.count
            if count == 1 {
                parts.append(String(localized: "1 cloud session"))
            } else if count > 1 {
                parts.append(String(localized: "\(count) cloud sessions"))
            }
        case .retrying(let at, let httpStatus):
            let time = at.formatted(date: .omitted, time: .shortened)
            switch httpStatus {
            case 429?:
                parts = [String(localized: "\(host) refused: its quota for this network is used up. Retrying at \(time)")]
            case let status?:
                parts = [String(localized: "\(host) refused the stream (HTTP \(status)). Retrying at \(time)")]
            case nil:
                parts = [String(localized: "Can't reach \(host). Retrying at \(time)")]
            }
        }
        if let check = relay.snapshot.lastCheckAt {
            parts.append(String(localized: "test received at \(check.formatted(date: .omitted, time: .shortened))"))
        }
        return parts.joined(separator: " · ")
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#if DEBUG
extension AgentCloudSessionsSettings {
    /// `--kannu-snapshots`: the rows shown once the feature is on, whatever this Mac's setting.
    static func snapshotSetupRows() -> AnyView {
        let settings = AgentCloudSessionsSettings()
        return AnyView(Form {
            Section { settings.setupRows } header: { SettingsSectionHeader("Cloud Sessions") }
        })
    }
}
#endif
