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

/// A secret the hook found in a prompt or in what an agent handed a tool (hook v35+), recorded
/// under `secrets` in the session's status file. Only the kind, the vendor prefix, the length and
/// a 12-hex SHA-256 fingerprint ever leave the hook — never the secret — so nothing here can show
/// it. Tool results are never scanned: reading a config is an agent's job, and what it reads is
/// the sensitive-file check's business.
struct SecretSighting: HookSighting {
    enum Kind: String, Codable, CaseIterable {
        case privateKey = "private_key"
        case anthropicKey = "anthropic_key"
        case openAIKey = "openai_key"
        case awsAccessKey = "aws_access_key"
        case githubToken = "github_token"
        case gitlabToken = "gitlab_token"
        case slackToken = "slack_token"
        case stripeKey = "stripe_key"
        case googleAPIKey = "google_api_key"
        case npmToken = "npm_token"
        case huggingFaceToken = "huggingface_token"

        /// For evidence lines: "AWS access key".
        var name: String {
            switch self {
            case .privateKey: return String(localized: "Private key")
            case .anthropicKey: return String(localized: "Anthropic API key")
            case .openAIKey: return String(localized: "OpenAI API key")
            case .awsAccessKey: return String(localized: "AWS access key")
            case .githubToken: return String(localized: "GitHub token")
            case .gitlabToken: return String(localized: "GitLab token")
            case .slackToken: return String(localized: "Slack token")
            case .stripeKey: return String(localized: "Stripe live key")
            case .googleAPIKey: return String(localized: "Google API key")
            case .npmToken: return String(localized: "npm token")
            case .huggingFaceToken: return String(localized: "Hugging Face token")
            }
        }

        /// For sentences: "an AWS access key".
        var phrase: String {
            switch self {
            case .privateKey: return String(localized: "a private key")
            case .anthropicKey: return String(localized: "an Anthropic API key")
            case .openAIKey: return String(localized: "an OpenAI API key")
            case .awsAccessKey: return String(localized: "an AWS access key")
            case .githubToken: return String(localized: "a GitHub token")
            case .gitlabToken: return String(localized: "a GitLab token")
            case .slackToken: return String(localized: "a Slack token")
            case .stripeKey: return String(localized: "a Stripe live key")
            case .googleAPIKey: return String(localized: "a Google API key")
            case .npmToken: return String(localized: "an npm token")
            case .huggingFaceToken: return String(localized: "a Hugging Face token")
            }
        }
    }

    enum Location: String, Codable, CaseIterable {
        case prompt
        case toolInput = "tool_input"
    }

    let kind: Kind
    let location: Location
    let tool: String?
    /// The vendor's public prefix ("AKIA", "ghp_") or a private key's type — never key material.
    let prefix: String
    let length: Int
    /// First 12 hex digits of the secret's SHA-256: tells two keys apart, cannot be turned back.
    let fingerprint: String
    let eventCount: Int
    let firstSeenMs: Int64
    let lastSeenMs: Int64

    /// Marker file in the status directory the hook reads (name shared with its tests).
    static let detectionOffMarker = ".kannu-secrets-off"
    static let maxPerSession = 5
    private static let plausibleMs: Int64 = 1_000_000_000_000

    // MARK: - Parsing (the status file is untrusted input)

    static func list(fromHookValue value: Any?) -> [SecretSighting] {
        guard let items = value as? [Any] else { return [] }
        var out: [SecretSighting] = []
        for case let item as [String: Any] in items {
            guard let kind = (item["kind"] as? String).flatMap(Kind.init(rawValue:)),
                  let location = (item["where"] as? String).flatMap(Location.init(rawValue:)),
                  let fingerprint = item["fp"] as? String, isFingerprint(fingerprint),
                  let first = (item["first_ts"] as? NSNumber)?.int64Value, first >= plausibleMs else { continue }
            let last = max(first, (item["last_ts"] as? NSNumber)?.int64Value ?? first)
            out.append(SecretSighting(
                kind: kind,
                location: location,
                tool: HiddenTextIncident.sanitizedTool(item["tool"] as? String),
                prefix: sanitizedPrefix(item["prefix"] as? String ?? ""),
                length: min(max((item["length"] as? NSNumber)?.intValue ?? 0, 0), 99_999),
                fingerprint: fingerprint,
                eventCount: min(max((item["events"] as? NSNumber)?.intValue ?? 1, 1), 999),
                firstSeenMs: first,
                lastSeenMs: last
            ))
        }
        return Array(out.suffix(maxPerSession))
    }

    static func isFingerprint(_ text: String) -> Bool {
        text.count == 12 && text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    static func sanitizedPrefix(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(40)))
    }

    // MARK: - Identity

    var key: String { "\(kind.rawValue)|\(location.rawValue)|\(fingerprint)" }

    // MARK: - As a finding

    /// A file edit may end up committed; a command or a network tool can send the secret
    /// anywhere, so that is the one worth interrupting you for. Your own prompt is medium: you
    /// pasted it, and it has already reached the model provider.
    var severity: AgentSecurityFinding.Severity {
        location == .toolInput && !Self.isFileEditTool(tool) ? .high : .medium
    }

    static func isFileEditTool(_ tool: String?) -> Bool {
        guard let tool else { return false }
        let compact = tool.lowercased().filter { $0.isLetter }
        return ["write", "edit", "multiedit", "notebookedit", "writefile", "editfile", "searchreplace",
                "strreplaceeditor", "applypatch", "replace", "create"].contains(compact)
    }

    static let rulePrefix = "secret_"

    var rule: String { Self.rulePrefix + kind.rawValue }

    var title: String {
        switch location {
        case .prompt:
            return String(localized: "A secret in your prompt")
        case .toolInput:
            return Self.isFileEditTool(tool)
                ? String(localized: "The agent wrote a secret into a file")
                : String(localized: "The agent used a secret in a tool call")
        }
    }

    func summary(chatName: String) -> String {
        var text: String
        switch location {
        case .prompt:
            text = String(localized: "Your prompt in “\(chatName)” held \(kind.phrase), so it went to the model provider.")
        case .toolInput:
            text = tool.map { String(localized: "The agent put \(kind.phrase) into a \($0) call in “\(chatName)”.") }
                ?? String(localized: "The agent put \(kind.phrase) into a tool call in “\(chatName)”.")
        }
        if eventCount > 1 { text += " " + String(localized: "Seen \(eventCount) times.") }
        return text
    }

    /// Distinct lines (the Settings row iterates them by value).
    func evidence(provider: String) -> [String] {
        var lines: [String] = []
        if kind == .privateKey {
            lines.append(String(localized: "\(prefix.isEmpty ? kind.name : prefix) · \(length) characters"))
        } else {
            lines.append(String(localized: "\(kind.name) · starts “\(prefix)” · \(length) characters"))
        }
        lines.append(String(localized: "Fingerprint \(fingerprint): the first 12 hex digits of its SHA-256. Kannu never keeps the secret."))
        let place = location == .prompt ? String(localized: "Prompt") : (tool ?? String(localized: "Tool call"))
        lines.append("\(place) · \(AgentSessionStatus.providerLabel(for: provider))")
        let seen = Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000)
        lines.append(String(localized: "First seen \(seen.formatted(date: .abbreviated, time: .shortened))"))
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        return unique
    }

    /// The same key in the same chat and place is one finding, whenever it was seen — so an
    /// acknowledgement and the once-only push hold even after the hook evicted and re-found it.
    func findingID(conversationID: String) -> String {
        AgentSecurityFinding.stableID(source: .kannu, rule: rule, subject: conversationID,
                                      evidence: [location.rawValue, fingerprint])
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
