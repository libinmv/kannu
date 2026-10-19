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

/// Connect… on the Jira Cloud row. The token lives only in this sheet's state until Jira has
/// accepted it; the manager then stores it in the Keychain and the field is cleared. A sheet pads
/// its own content; a Form row never does.
struct JiraConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var site = ""
    @State private var email = ""
    @State private var token = ""
    /// Saved only when Connect succeeds; Cancel keeps the colour the key had.
    @State private var color = Defaults[.jiraTaskColor]
    @State private var problem: String?
    @State private var connecting: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text("Connect Jira Cloud")
                .font(.headline)
            Text("Checked with your site, then kept in your Keychain.")
                .settingsDescriptionStyle()
            TextField("Site", text: $site, prompt: Text(verbatim: "acme.atlassian.net"))
            TextField("Email", text: $email, prompt: Text(verbatim: "you@example.com"))
            SecureField("API token", text: $token)
            Link("Create API token…", destination: JiraAPI.createTokenURL)
            LabeledContent {
                TaskColorPickerButton(
                    selection: $color,
                    accessibilityLabel: String(localized: "Jira colour: \(color.localizedName)")
                )
            } label: {
                SettingsRowLabel("Jira colour", description: "For Jira tasks that have no tags.")
            }
            if let problem {
                Text(verbatim: problem)
                    .settingsDescriptionStyle(tint: .red)
            }
            HStack(spacing: SettingsMetrics.rowContent) {
                if connecting != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting != nil || !canConnect)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 420)
        .onDisappear {
            connecting?.cancel()
            token = ""
        }
    }

    private var canConnect: Bool {
        !site.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !token.isEmpty
    }

    private func connect() {
        problem = nil
        connecting = Task { @MainActor in
            let failure = await TasksManager.shared.connectJira(siteInput: site, email: email, token: token)
            guard !Task.isCancelled else { return }
            connecting = nil
            if let failure {
                problem = failure
            } else {
                token = ""
                Defaults[.jiraTaskColor] = color
                dismiss()
            }
        }
    }

    private func close() {
        connecting?.cancel()
        connecting = nil
        token = ""
        dismiss()
    }
}

/// Connect… on the GitLab row. The server field starts at gitlab.com; a self-managed server is any
/// HTTPS address, with a path if it has one. The token lives only in this sheet's state until GitLab
/// has accepted it; the manager then stores it in the Keychain and the field is cleared. A sheet
/// pads its own content; a Form row never does.
struct GitLabConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = GitLabHost.defaultServer
    @State private var token = ""
    /// Saved only when Connect succeeds; Cancel keeps the colour the key had.
    @State private var color = Defaults[.gitlabTaskColor]
    @State private var problem: String?
    @State private var connecting: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowContent) {
            Text("Connect GitLab")
                .font(.headline)
            Text("Checked with your server, then kept in your Keychain.")
                .settingsDescriptionStyle()
            TextField("Server", text: $server, prompt: Text(verbatim: GitLabHost.defaultServer))
                .onChange(of: server) { _, _ in problem = nil }
            SecureField("Personal access token", text: $token)
            Text("`api` to log time; `read_api` lists only")
                .settingsDescriptionStyle()
            if let createTokenURL {
                Link("Create token…", destination: createTokenURL)
            }
            LabeledContent {
                TaskColorPickerButton(
                    selection: $color,
                    accessibilityLabel: String(localized: "GitLab colour: \(color.localizedName)")
                )
            } label: {
                SettingsRowLabel("GitLab colour", description: "For GitLab tasks that have no tags.")
            }
            if let problem {
                Text(verbatim: problem)
                    .settingsDescriptionStyle(tint: .red)
            }
            HStack(spacing: SettingsMetrics.rowContent) {
                if connecting != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(connecting != nil || !canConnect)
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(width: 420)
        .onDisappear {
            connecting?.cancel()
            token = ""
        }
    }

    /// The token page on the server typed so far, once it is an address Kannu would connect to.
    private var createTokenURL: URL? {
        guard case .success(let base) = GitLabHost.normalize(server) else { return nil }
        return GitLabHost.createTokenURL(base: base)
    }

    private var canConnect: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !token.isEmpty
    }

    private func connect() {
        problem = nil
        connecting = Task { @MainActor in
            let failure = await TasksManager.shared.connectGitLab(serverInput: server, token: token)
            guard !Task.isCancelled else { return }
            connecting = nil
            if let failure {
                problem = failure
            } else {
                token = ""
                Defaults[.gitlabTaskColor] = color
                dismiss()
            }
        }
    }

    private func close() {
        connecting?.cancel()
        connecting = nil
        token = ""
        dismiss()
    }
}
