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

import Foundation

/// A sensitive file an agent read or changed, as the hook (v35+) records it under
/// `sensitive_paths` after the tool ran: keys, credential and password stores, browser data, shell
/// history — read or changed — and files that run code on their own, start every shell or
/// configure an agent — changed only (reading those is ordinary). The path is shown home-relative
/// ("~/.ssh/id_ed25519"); no file content is ever recorded.
struct SensitivePathSighting: HookSighting {
    enum Category: String, Codable, CaseIterable {
        case sshKey = "ssh_key"
        case cloudCredentials = "cloud_credentials"
        case tokenFile = "token_file"
        case agentCredentials = "agent_credentials"
        case gpgKey = "gpg_key"
        case passwordStore = "password_store"
        case keychain
        case browserData = "browser_data"
        case envFile = "env_file"
        case shellHistory = "shell_history"
        case autorun
        case shellStartup = "shell_startup"
        case agentConfig = "agent_config"
    }

    enum Access: String, Codable, CaseIterable {
        case read
        case write
    }

    let category: Category
    let access: Access
    /// Printable ASCII, at most `pathLimit`; "security find-generic-password" or "crontab" for a
    /// command that reaches the keychain or a schedule without naming a file.
    let path: String
    let tool: String?
    /// Every attempt so far failed (the tool errored); one success clears it.
    let failed: Bool
    let eventCount: Int
    let firstSeenMs: Int64
    let lastSeenMs: Int64

    static let detectionOffMarker = ".kannu-sensitive-paths-off"
    static let maxPerSession = 5
    static let pathLimit = 160
    private static let plausibleMs: Int64 = 1_000_000_000_000

    // MARK: - Parsing (the status file is untrusted input)

    static func list(fromHookValue value: Any?) -> [SensitivePathSighting] {
        guard let items = value as? [Any] else { return [] }
        var out: [SensitivePathSighting] = []
        for case let item as [String: Any] in items {
            guard let category = (item["category"] as? String).flatMap(Category.init(rawValue:)),
                  let access = (item["access"] as? String).flatMap(Access.init(rawValue:)),
                  let first = (item["first_ts"] as? NSNumber)?.int64Value, first >= plausibleMs else { continue }
            let path = sanitizedPath(item["path"] as? String ?? "")
            guard !path.isEmpty else { continue }
            let last = max(first, (item["last_ts"] as? NSNumber)?.int64Value ?? first)
            out.append(SensitivePathSighting(
                category: category,
                access: access,
                path: path,
                tool: HiddenTextIncident.sanitizedTool(item["tool"] as? String),
                failed: (item["failed"] as? Bool) == true,
                eventCount: min(max((item["events"] as? NSNumber)?.intValue ?? 1, 1), 999),
                firstSeenMs: first,
                lastSeenMs: last
            ))
        }
        return Array(out.suffix(maxPerSession))
    }

    static func sanitizedPath(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(pathLimit)))
    }

    // MARK: - Identity

    var key: String { "\(category.rawValue)|\(access.rawValue)|\(path)" }

    // MARK: - As a finding

    /// Reading a .env file or shell history is common agent behaviour, and so is an agent editing
    /// a project's `.vscode/settings.json`: worth a line, not an interruption. Everything else here
    /// is a key, a password, a way to act as you, or a way to run code later.
    var severity: AgentSecurityFinding.Severity {
        switch category {
        case .envFile, .shellHistory:
            return .medium
        case .agentConfig:
            return path.hasSuffix(".vscode/settings.json") ? .medium : .high
        default:
            return .high
        }
    }

    var rule: String { "sensitive_file_" + category.rawValue }

    private var object: String {
        switch category {
        case .sshKey: return String(localized: "an SSH private key")
        case .cloudCredentials: return String(localized: "cloud credentials")
        case .tokenFile: return String(localized: "a file of access tokens")
        case .agentCredentials: return String(localized: "an AI tool's sign-in")
        case .gpgKey: return String(localized: "a GPG private key")
        case .passwordStore: return String(localized: "a password store")
        case .keychain: return String(localized: "the keychain")
        case .browserData: return String(localized: "browser data")
        case .envFile: return String(localized: "a .env file")
        case .shellHistory: return String(localized: "shell history")
        case .autorun: return String(localized: "something that runs on its own")
        case .shellStartup: return String(localized: "a shell startup file")
        case .agentConfig: return String(localized: "an agent's settings")
        }
    }

    var title: String {
        switch (access, failed) {
        case (.read, false): return String(localized: "The agent read \(object)")
        case (.read, true): return String(localized: "The agent tried to read \(object)")
        case (.write, false): return String(localized: "The agent changed \(object)")
        case (.write, true): return String(localized: "The agent tried to change \(object)")
        }
    }

    /// Why it matters, in one plain sentence.
    private var why: String {
        switch category {
        case .sshKey: return String(localized: "Anyone with this file can sign in to your servers and Git hosts as you.")
        case .cloudCredentials: return String(localized: "These files let a program act on your cloud accounts.")
        case .tokenFile: return String(localized: "This file holds tokens for Git hosts or package registries.")
        case .agentCredentials: return String(localized: "This file signs an AI tool in to your account.")
        case .gpgKey: return String(localized: "A GPG private key signs and decrypts in your name.")
        case .passwordStore: return String(localized: "This is a password manager's data.")
        case .keychain: return String(localized: "macOS keeps your saved passwords in the keychain.")
        case .browserData: return String(localized: "Browser profiles hold cookies, saved passwords and history.")
        case .envFile: return String(localized: ".env files usually hold API keys and passwords.")
        case .shellHistory: return String(localized: "Shell history often holds tokens typed on the command line.")
        case .autorun: return String(localized: "Files here run programs on their own: at login, on a schedule, on Git events or on SSH sign-in.")
        case .shellStartup: return String(localized: "Your shell runs this file every time a terminal opens.")
        case .agentConfig: return String(localized: "Agent settings decide what agents may run without asking.")
        }
    }

    func summary(chatName: String) -> String {
        var text = tool.map { String(localized: "\(path), with \($0), in “\(chatName)”.") }
            ?? String(localized: "\(path), in “\(chatName)”.")
        if eventCount > 1 { text += " " + String(localized: "Seen \(eventCount) times.") }
        return text
    }

    func evidence(provider: String) -> [String] {
        var how = access == .read ? String(localized: "Read") : String(localized: "Changed")
        if let tool { how = access == .read ? String(localized: "Read with \(tool)") : String(localized: "Changed with \(tool)") }
        how += " · \(AgentSessionStatus.providerLabel(for: provider))"
        if failed { how += " · " + String(localized: "the call failed") }
        let seen = Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000)
        let lines = [path, why, how, String(localized: "First seen \(seen.formatted(date: .abbreviated, time: .shortened))")]
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        return unique
    }

    func findingID(conversationID: String) -> String {
        AgentSecurityFinding.stableID(source: .kannu, rule: rule, subject: conversationID,
                                      evidence: [access.rawValue, path])
    }

    func finding(conversationID: String, provider: String, chatName: String, projectName: String?, cwd: String?) -> AgentSecurityFinding {
        AgentSecurityFinding(
            id: findingID(conversationID: conversationID),
            source: .kannu,
            rule: rule,
            severity: severity,
            title: title,
            summary: summary(chatName: chatName),
            evidence: evidence(provider: provider),
            assetName: projectName,
            assetPath: cwd,
            sessionID: conversationID,
            firstSeen: Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000)
        )
    }
}
