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

/// A tool call the user's agent policy named (hook v42+), recorded under `policy` in the session's
/// status file: which rule matched, the tool, and whether the hook refused the call or — blocking
/// off, or a host whose hook cannot say no — let it run and only reported it. The command line
/// itself is never kept: it can carry a secret, and the rule word is what the user needs.
struct PolicySighting: HookSighting {
    enum Kind: String, Codable, CaseIterable {
        case command
        case tool
    }

    let kind: Kind
    /// The rule as written: `ssh`, `rm -rf /`, `WebFetch`.
    let matched: String
    let tool: String?
    let blocked: Bool
    let eventCount: Int
    let firstSeenMs: Int64
    let lastSeenMs: Int64

    static let maxPerSession = 3
    private static let plausibleMs: Int64 = 1_000_000_000_000

    // MARK: - Parsing (the status file is untrusted input)

    static func list(fromHookValue value: Any?) -> [PolicySighting] {
        guard let items = value as? [Any] else { return [] }
        var out: [PolicySighting] = []
        for case let item as [String: Any] in items {
            guard let kind = (item["kind"] as? String).flatMap(Kind.init(rawValue:)),
                  let rawMatched = item["matched"] as? String,
                  let first = (item["first_ts"] as? NSNumber)?.int64Value, first >= plausibleMs else { continue }
            let matched = SecretSighting.sanitizedPrefix(rawMatched).isEmpty ? "" : String(rawMatched.unicodeScalars
                .filter { (0x20...0x7E).contains($0.value) }.prefix(AgentPolicy.maxLength).map(Character.init))
            guard !matched.isEmpty else { continue }
            let last = max(first, (item["last_ts"] as? NSNumber)?.int64Value ?? first)
            out.append(PolicySighting(
                kind: kind,
                matched: matched,
                tool: HiddenTextIncident.sanitizedTool(item["tool"] as? String),
                blocked: (item["blocked"] as? Bool) == true,
                eventCount: min(max((item["events"] as? NSNumber)?.intValue ?? 1, 1), 999),
                firstSeenMs: first,
                lastSeenMs: last
            ))
        }
        return Array(out.suffix(maxPerSession))
    }

    // MARK: - Identity

    var key: String { "\(kind.rawValue)|\(matched)|\(blocked ? "blocked" : "ran")" }

    // MARK: - As a finding

    /// Blocked is the policy working: worth knowing, not worth a push. Ran is the one to look at —
    /// the agent did the thing the user wrote down not to do.
    var severity: AgentSecurityFinding.Severity { blocked ? .medium : .high }

    static let rulePrefix = "policy_"

    var rule: String { Self.rulePrefix + kind.rawValue }

    var title: String {
        blocked
            ? String(localized: "Policy blocked “\(matched)”")
            : String(localized: "Policy matched “\(matched)” — it ran")
    }

    func summary(chatName: String) -> String {
        var text: String
        let what = kind == .tool ? String(localized: "the \(matched) tool") : String(localized: "a “\(matched)” command")
        if blocked {
            text = String(localized: "Kannu refused \(what) in “\(chatName)” and told the agent why.")
        } else {
            text = String(localized: "The agent used \(what) in “\(chatName)”. Blocking was off, so it ran; this is the report.")
        }
        if eventCount > 1 { text += " " + String(localized: "Seen \(eventCount) times.") }
        return text
    }

    /// Distinct lines (the Settings row iterates them by value).
    func evidence(provider: String) -> [String] {
        var lines: [String] = []
        lines.append(kind == .tool
            ? String(localized: "Rule: tool “\(matched)”")
            : String(localized: "Rule: command “\(matched)”"))
        lines.append(blocked
            ? String(localized: "Refused before it ran; the agent was told the rule.")
            : String(localized: "Ran — blocking is off, or this agent's hook cannot refuse a call."))
        lines.append("\(tool ?? String(localized: "Tool call")) · \(AgentSessionStatus.providerLabel(for: provider))")
        let seen = Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000)
        lines.append(String(localized: "First seen \(seen.formatted(date: .abbreviated, time: .shortened))"))
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        return unique
    }

    /// The same rule with the same outcome in the same chat is one finding, however often it was
    /// seen, so an acknowledgement holds.
    func findingID(conversationID: String) -> String {
        AgentSecurityFinding.stableID(source: .kannu, rule: rule, subject: conversationID,
                                      evidence: [kind.rawValue, matched, blocked ? "blocked" : "ran"])
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
            firstSeen: Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000),
            lastSeen: Date(timeIntervalSince1970: TimeInterval(lastSeenMs) / 1000),
            occurrences: eventCount,
            projectName: projectName,
            // The rule and what it matched, and nothing else: not the conversation, so the same
            // rule firing in another chat is the same row; and not `blocked`, because Kannu
            // starting to refuse a call is a change of outcome for one problem, not a new problem.
            groupSubject: "\(kind.rawValue)|\(matched)",
            outcomeTag: blocked ? "blocked" : "ran"
        )
    }
}
