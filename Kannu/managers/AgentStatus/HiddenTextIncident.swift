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

/// One sighting of hidden Unicode in what an agent read or wrote, as the hook script (v34+)
/// records it in a session's status file under `hidden_text`. The hook records facts; severity,
/// wording and finding identity are decided here, so retuning them needs no hook version bump.
///
/// The four kinds, written independently from their public specifications (nothing ported from
/// ADR): Unicode tag characters (U+E0000–E007F, "ASCII smuggling"; flag emoji excluded per
/// UTS #51), bytes hidden in variation-selector runs (Butler 2025), right-to-left overrides on a
/// line with no right-to-left letters (Trojan Source, CVE-2021-42574), long zero-width runs.
struct HiddenTextIncident: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case tags
        case variationSelectors = "variation_selectors"
        case bidi
        case zeroWidth = "zero_width"
    }

    enum Location: String, Codable, CaseIterable {
        case toolResult = "tool_result"
        case prompt
        case toolInput = "tool_input"
        case agentReply = "agent_reply"
        case other
    }

    let kind: Kind
    let location: Location
    let tool: String?
    let characterCount: Int
    let eventCount: Int
    /// Printable ASCII only, at most `previewLimit`: the decoded text for tags, variation
    /// selectors and bit-encoded zero-width runs; the line in logical order for bidi. Shown in
    /// Kannu only — never pushed, never sent to the agent.
    let preview: String
    let firstSeenMs: Int64
    let lastSeenMs: Int64

    /// Marker files in the status directory the hook script reads (names shared with its tests).
    static let detectionOffMarker = ".kannu-hidden-text-off"
    static let warnAgentMarker = ".kannu-hidden-text-warn-agent"
    static let maxPerSession = 3
    static let previewLimit = 160
    private static let plausibleMs: Int64 = 1_000_000_000_000

    // MARK: - Parsing (the status file is untrusted input)

    static func list(fromHookValue value: Any?) -> [HiddenTextIncident] {
        guard let items = value as? [Any] else { return [] }
        var out: [HiddenTextIncident] = []
        for case let item as [String: Any] in items {
            guard let kindRaw = item["kind"] as? String, let kind = Kind(rawValue: kindRaw),
                  let first = (item["first_ts"] as? NSNumber)?.int64Value, first >= plausibleMs else { continue }
            let location = (item["where"] as? String).flatMap(Location.init(rawValue:)) ?? .other
            let last = max(first, (item["last_ts"] as? NSNumber)?.int64Value ?? first)
            out.append(HiddenTextIncident(
                kind: kind,
                location: location,
                tool: sanitizedTool(item["tool"] as? String),
                characterCount: min(max((item["chars"] as? NSNumber)?.intValue ?? 0, 0), 999_999),
                eventCount: min(max((item["events"] as? NSNumber)?.intValue ?? 1, 1), 999),
                preview: sanitizedPreview(item["preview"] as? String ?? ""),
                firstSeenMs: first,
                lastSeenMs: last
            ))
        }
        return Array(out.suffix(maxPerSession))
    }

    static func sanitizedPreview(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(previewLimit)))
    }

    static func sanitizedTool(_ text: String?) -> String? {
        guard let text else { return nil }
        let allowed = text.unicodeScalars.filter {
            ($0.value < 0x80) && (CharacterSet.alphanumerics.contains($0) || "_.:-".unicodeScalars.contains($0))
        }
        let clean = String(String.UnicodeScalarView(allowed.prefix(64)))
        return clean.isEmpty ? nil : clean
    }

    // MARK: - Merging across reconstruction seams (REGRESSIONS entry 7)

    var key: String { "\(kind.rawValue)|\(location.rawValue)|\(firstSeenMs)" }

    /// A set union keyed by (kind, location, firstSeenMs); the newer copy of one sighting wins,
    /// newest three kept. Empty is the identity.
    static func union(_ lhs: [HiddenTextIncident], _ rhs: [HiddenTextIncident]) -> [HiddenTextIncident] {
        if rhs.isEmpty || lhs == rhs { return lhs }
        if lhs.isEmpty { return rhs }
        var byKey: [String: HiddenTextIncident] = [:]
        for incident in lhs + rhs {
            if let kept = byKey[incident.key], kept.lastSeenMs >= incident.lastSeenMs { continue }
            byKey[incident.key] = incident
        }
        let sorted = byKey.values.sorted {
            $0.firstSeenMs != $1.firstSeenMs ? $0.firstSeenMs < $1.firstSeenMs : $0.key < $1.key
        }
        return Array(sorted.suffix(maxPerSession))
    }

    // MARK: - As a finding

    /// High when the characters decode to something readable — that is a message someone hid.
    var severity: AgentSecurityFinding.Severity {
        kind != .bidi && preview.count >= 4 ? .high : .medium
    }

    var rule: String { "hidden_text_" + kind.rawValue }

    var title: String {
        if kind == .bidi {
            return String(localized: "Text that shows differently than it reads")
        }
        switch location {
        case .toolResult: return String(localized: "Hidden text in a tool result")
        case .prompt: return String(localized: "Hidden text in your prompt")
        case .toolInput: return String(localized: "Hidden text the agent wrote")
        case .agentReply: return String(localized: "Hidden text in the agent's reply")
        case .other: return String(localized: "Hidden text in agent input")
        }
    }

    private var place: String {
        switch location {
        case .toolResult: return tool.map { String(localized: "a \($0) result") } ?? String(localized: "a tool result")
        case .toolInput: return tool.map { String(localized: "the input of a \($0) call") } ?? String(localized: "a tool call's input")
        case .prompt: return String(localized: "your prompt")
        case .agentReply: return String(localized: "the agent's reply")
        case .other: return String(localized: "the agent's input")
        }
    }

    private var characterWord: String {
        switch kind {
        case .bidi:
            return characterCount == 1 ? String(localized: "text-direction control") : String(localized: "text-direction controls")
        default:
            return characterCount == 1 ? String(localized: "invisible character") : String(localized: "invisible characters")
        }
    }

    /// One line for the card and for a push. Never the preview: that stays in `evidence`, which
    /// is shown in Kannu only.
    func summary(chatName: String) -> String {
        var text = String(localized: "\(characterCount) \(characterWord) in \(place), in “\(chatName)”.")
        if eventCount > 1 { text += " " + String(localized: "Seen \(eventCount) times.") }
        return text
    }

    private var technicalKind: String {
        switch kind {
        case .tags: return String(localized: "tag characters (U+E0000–E007F)")
        case .variationSelectors: return String(localized: "variation selectors")
        case .bidi: return String(localized: "bidirectional controls")
        case .zeroWidth: return String(localized: "zero-width characters")
        }
    }

    /// Distinct lines (the Settings row iterates them by value), the decoded text first.
    func evidence(provider: String) -> [String] {
        var lines: [String] = []
        if !preview.isEmpty {
            lines.append(kind == .bidi ? String(localized: "Logical order: \(preview)") : String(localized: "Decodes to: “\(preview)”"))
        }
        var detail = "\(characterCount) \(technicalKind) · \(location.rawValue.replacingOccurrences(of: "_", with: " "))"
        if let tool { detail += " · \(tool)" }
        detail += " · \(AgentSessionStatus.providerLabel(for: provider))"
        lines.append(detail)
        let seen = Date(timeIntervalSince1970: TimeInterval(firstSeenMs) / 1000)
        lines.append(String(localized: "First seen \(seen.formatted(date: .abbreviated, time: .shortened))"))
        var unique: [String] = []
        for line in lines where !unique.contains(line) { unique.append(line) }
        return unique
    }

    /// From the parts that never change for one sighting, so later counts, a longer preview or a
    /// resolved chat name keep the id — and with it the acknowledgement and the once-only push.
    func findingID(conversationID: String) -> String {
        AgentSecurityFinding.stableID(source: .kannu, rule: rule, subject: conversationID,
                                      evidence: [location.rawValue, String(firstSeenMs)])
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

    // MARK: - Persisted sightings

    /// What Kannu keeps after the session's status file is gone, so an incident stays until the
    /// user acknowledges it.
    struct Record: Codable, Equatable {
        let conversationID: String
        let provider: String
        var chatName: String
        var projectName: String?
        var cwd: String?
        var incident: HiddenTextIncident

        var key: String { "\(conversationID)|\(incident.key)" }

        var finding: AgentSecurityFinding {
            incident.finding(conversationID: conversationID, provider: provider, chatName: chatName,
                             projectName: projectName, cwd: cwd)
        }

        /// New sightings appended, known ones refreshed; least-recently-seen evicted past `cap`.
        /// Returns `records` unchanged when no session carries a sighting.
        static func upserting(_ sessions: [AgentSessionStatus], into records: [Record], cap: Int) -> [Record] {
            guard sessions.contains(where: { !$0.hiddenText.isEmpty }) else { return records }
            var out = records
            var index = Dictionary(out.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })
            for session in sessions {
                for incident in session.hiddenText {
                    let fresh = Record(conversationID: session.conversationID, provider: session.provider,
                                       chatName: session.displayChatName, projectName: session.displayProjectName,
                                       cwd: session.cwd, incident: incident)
                    if let i = index[fresh.key] {
                        var kept = out[i]
                        if incident.lastSeenMs >= kept.incident.lastSeenMs { kept.incident = incident }
                        kept.chatName = fresh.chatName
                        kept.projectName = fresh.projectName ?? kept.projectName
                        kept.cwd = fresh.cwd ?? kept.cwd
                        out[i] = kept
                    } else {
                        index[fresh.key] = out.count
                        out.append(fresh)
                    }
                }
            }
            out.sort {
                $0.incident.lastSeenMs != $1.incident.lastSeenMs ? $0.incident.lastSeenMs > $1.incident.lastSeenMs : $0.key < $1.key
            }
            return Array(out.prefix(cap))
        }
    }
}
