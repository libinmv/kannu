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

import CryptoKit
import Foundation

/// One security finding, whoever produced it. Additive to the traffic light — it never becomes
/// a light colour — and stable across re-scans: the id is a digest of what the finding is
/// *about*, so the same finding on the next scan is the same finding (acknowledgements hold)
/// and one whose evidence changed is new again.
struct AgentSecurityFinding: Equatable, Hashable, Identifiable, Codable {
    enum Source: String, Codable {
        /// ADR Discovery snapshot (configuration and inventory findings).
        case discovery
        /// ADR Detection verdict on a finished session (phase 3).
        case detection
        /// Kannu's own native checks (e.g. a bypass-permissions launch seen by the hook).
        case kannu
    }

    /// Ordered so the highest can be picked with `max()`.
    enum Severity: Int, Codable, Comparable, CaseIterable {
        case info = 0
        case medium = 1
        case high = 2

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        /// ADR uses the words `high` / `medium` / `low`; anything unknown lands on medium
        /// rather than being dropped, since an unknown rule is still a rule.
        init(adr word: String) {
            switch word.lowercased() {
            case "high", "critical": self = .high
            case "low", "info": self = .info
            default: self = .medium
            }
        }

        var label: String {
            switch self {
            case .high: return String(localized: "High")
            case .medium: return String(localized: "Medium")
            case .info: return String(localized: "Info")
            }
        }
    }

    let id: String
    let source: Source
    let rule: String
    let severity: Severity
    let title: String
    let summary: String
    /// Short, human-readable proofs. Never raw payloads.
    let evidence: [String]
    let assetName: String?
    let assetPath: String?
    let sessionID: String?
    let firstSeen: Date
    /// Lines shown only inside Kannu — never pushed, never copied for an agent (the decoded
    /// hidden text is one). Empty by default, so a rebuild that forgets it can only hide a line,
    /// never leak one: everything that leaves Kannu reads `evidence`.
    var kannuOnlyEvidence: [String] = []

    /// What Kannu itself shows: Kannu-only lines first, then the evidence, without repeats.
    var displayedEvidence: [String] {
        var lines: [String] = []
        for line in kannuOnlyEvidence + evidence where !lines.contains(line) { lines.append(line) }
        return lines
    }

    /// `subject` is what the finding is about (an asset id, a session id, a config path);
    /// `evidence` is the proof list. Same inputs, same id — across scans and app launches.
    static func stableID(source: Source, rule: String, subject: String, evidence: [String]) -> String {
        let material = ([source.rawValue, rule, subject] + evidence).joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Human titles for the rules ADR Discovery raises today; unknown rules are prettified so a
    /// new upstream rule still reads as a sentence.
    static func title(forRule rule: String) -> String {
        switch rule {
        case "unpinned_mcp_server": return String(localized: "Unpinned MCP server")
        case "plaintext_transport": return String(localized: "MCP server over plain HTTP")
        case "undeclared_mcp_server": return String(localized: "Running MCP server nobody declared")
        case "unattended_execution": return String(localized: "Permission checks bypassed")
        case "third_party_destination": return String(localized: "MCP server reaches outside your domains")
        default:
            let words = rule.split(separator: "_").map(String.init)
            guard let first = words.first else { return rule }
            return ([first.capitalized] + words.dropFirst()).joined(separator: " ")
        }
    }

    /// Maps a Discovery snapshot's findings, joining each to its asset for a name and a path.
    /// `existing` lets a finding keep its original `firstSeen` across re-scans.
    static func findings(
        from snapshot: ADRSnapshot,
        existing: [AgentSecurityFinding] = [],
        now: Date = Date()
    ) -> [AgentSecurityFinding] {
        let firstSeenByID = Dictionary(existing.map { ($0.id, $0.firstSeen) }, uniquingKeysWith: { a, _ in a })
        return snapshot.findings.map { finding in
            let asset = snapshot.asset(id: finding.assetId)
            let evidence = finding.evidence.map { item -> String in
                item.path.isEmpty ? item.proof : "\(item.proof) — \(item.path)"
            }
            let id = stableID(source: .discovery, rule: finding.rule, subject: finding.assetId, evidence: evidence)
            return AgentSecurityFinding(
                id: id,
                source: .discovery,
                rule: finding.rule,
                severity: Severity(adr: finding.severity),
                title: title(forRule: finding.rule),
                summary: finding.summary,
                evidence: evidence,
                assetName: asset?.name,
                assetPath: asset?.installPath,
                sessionID: nil,
                firstSeen: firstSeenByID[id] ?? now
            )
        }
    }
}

extension AgentSecurityFinding {
    /// Kannu's own findings, derived from what the hooks see and ADR cannot on macOS: a visible
    /// session running with permission checks bypassed. One finding per session, gone when the
    /// session is; `existing` keeps `firstSeen` stable across rescans.
    static func nativeFindings(
        from sessions: [AgentSessionStatus],
        existing: [AgentSecurityFinding] = [],
        now: Date = Date()
    ) -> [AgentSecurityFinding] {
        let firstSeenByID = Dictionary(existing.map { ($0.id, $0.firstSeen) }, uniquingKeysWith: { a, _ in a })
        return sessions
            .filter { $0.isVisible && $0.isUnattended }
            .map { session in
                let provider = AgentSessionStatus.providerLabel(for: session.provider)
                // The id keeps its original material, so acknowledgements hold; the shown line no
                // longer carries a session id (the summary names the chat, and nothing that can
                // lead to a transcript goes into a copied request).
                let idEvidence = ["\(provider) session \(session.conversationID.prefix(8)) started without permission prompts"]
                let evidence = [String(localized: "\(provider) session started without permission prompts")]
                let id = stableID(source: .kannu, rule: "unattended_execution", subject: session.conversationID, evidence: idEvidence)
                return AgentSecurityFinding(
                    id: id,
                    source: .kannu,
                    rule: "unattended_execution",
                    severity: .high,
                    title: title(forRule: "unattended_execution"),
                    summary: String(localized: "\(session.displayChatName) runs with permission checks bypassed"),
                    evidence: evidence,
                    assetName: session.displayProjectName,
                    assetPath: session.cwd,
                    sessionID: session.conversationID,
                    firstSeen: firstSeenByID[id] ?? now
                )
            }
    }
}

/// A snooze on one finding id. Lives here (Foundation-only) so the priority logic is testable;
/// the app target adds `Defaults.Serializable` next to its key.
struct SecurityFindingSnooze: Codable, Equatable, Hashable {
    let id: String
    let until: Date
}

/// The one place that decides what the user sees, in what order, and what is pinned.
enum SecurityFindingPriority {
    struct Ranking: Equatable {
        /// Everything not acknowledged or snoozed, highest severity first, newest first within.
        let visible: [AgentSecurityFinding]
        /// The single high finding that owns the pinned card and the closed-notch cue, if any.
        let pinned: AgentSecurityFinding?
        /// Unacknowledged, unsnoozed high findings — what the notch cue counts.
        let pendingHighCount: Int
    }

    /// The earliest snooze that ends after `now`: when the visible findings next change by
    /// themselves. The store wakes once at that moment instead of re-ranking on a timer.
    static func nextSnoozeExpiry(_ snoozes: [SecurityFindingSnooze], after now: Date) -> Date? {
        snoozes.map(\.until).filter { $0 > now }.min()
    }

    static func rank(
        _ findings: [AgentSecurityFinding],
        acknowledged: Set<String>,
        snoozes: [SecurityFindingSnooze],
        now: Date = Date()
    ) -> Ranking {
        let snoozed = Set(snoozes.filter { $0.until > now }.map(\.id))
        let visible = findings
            .filter { !acknowledged.contains($0.id) && !snoozed.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
                if lhs.firstSeen != rhs.firstSeen { return lhs.firstSeen > rhs.firstSeen }
                return lhs.title < rhs.title
            }
        let highs = visible.filter { $0.severity == .high }
        return Ranking(visible: visible, pinned: highs.first, pendingHighCount: highs.count)
    }

    /// Drops expired snoozes and any for findings that no longer exist.
    static func pruned(_ snoozes: [SecurityFindingSnooze], keeping ids: Set<String>, now: Date = Date()) -> [SecurityFindingSnooze] {
        snoozes.filter { $0.until > now && ids.contains($0.id) }
    }
}
