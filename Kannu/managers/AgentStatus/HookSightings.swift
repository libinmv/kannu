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

/// A fact one of the hook's local checks recorded about what an agent read or wrote. The hook
/// records facts; severity, wording and finding identity are decided in Swift, so retuning them
/// needs no hook version bump.
protocol HookSighting: Codable, Equatable {
    /// The same for every later copy of one sighting (kind, place, first seen): the union key.
    var key: String { get }
    var firstSeenMs: Int64 { get }
    var lastSeenMs: Int64 { get }
    static var maxPerSession: Int { get }
    func finding(conversationID: String, provider: String, chatName: String, projectName: String?,
                 cwd: String?) -> AgentSecurityFinding
}

extension HookSighting {
    /// A set union keyed by `key`; the newer copy of one sighting wins, the newest
    /// `maxPerSession` are kept. Empty is the identity.
    static func union(_ lhs: [Self], _ rhs: [Self]) -> [Self] {
        if rhs.isEmpty || lhs == rhs { return lhs }
        if lhs.isEmpty { return rhs }
        var byKey: [String: Self] = [:]
        for sighting in lhs + rhs {
            if let kept = byKey[sighting.key], kept.lastSeenMs >= sighting.lastSeenMs { continue }
            byKey[sighting.key] = sighting
        }
        let sorted = byKey.values.sorted {
            $0.firstSeenMs != $1.firstSeenMs ? $0.firstSeenMs < $1.firstSeenMs : $0.key < $1.key
        }
        return Array(sorted.suffix(maxPerSession))
    }
}

/// Everything the hook's local checks have seen in one session. Hook-only and additive: carried
/// across every reconstruction seam by `carryingExtras` as a union (docs/REGRESSIONS.md entry 7).
/// A new kind of check adds one list here, to `init(hookFile:)`, `union` and `isEmpty`.
struct HookSightings: Equatable {
    var hiddenText: [HiddenTextIncident] = []

    var isEmpty: Bool { hiddenText.isEmpty }

    init(hiddenText: [HiddenTextIncident] = []) {
        self.hiddenText = hiddenText
    }

    /// From a session's status file — untrusted input, re-sanitised by each kind's parser.
    init(hookFile json: [String: Any]) {
        hiddenText = HiddenTextIncident.list(fromHookValue: json["hidden_text"])
    }

    static func union(_ lhs: HookSightings, _ rhs: HookSightings) -> HookSightings {
        HookSightings(hiddenText: HiddenTextIncident.union(lhs.hiddenText, rhs.hiddenText))
    }
}

/// A sighting kept after its session's status file is gone, so it stays until the user
/// acknowledges it.
struct HookSightingRecord<Sighting: HookSighting>: Codable, Equatable {
    let conversationID: String
    let provider: String
    var chatName: String
    var projectName: String?
    var cwd: String?
    var sighting: Sighting

    var key: String { "\(conversationID)|\(sighting.key)" }

    var finding: AgentSecurityFinding {
        sighting.finding(conversationID: conversationID, provider: provider, chatName: chatName,
                         projectName: projectName, cwd: cwd)
    }

    /// New sightings appended, known ones refreshed; least-recently-seen evicted past `cap`.
    /// Returns `records` unchanged when no session carries a sighting of this kind.
    static func upserting(_ sessions: [AgentSessionStatus], _ sightings: (HookSightings) -> [Sighting],
                          into records: [Self], cap: Int) -> [Self] {
        guard sessions.contains(where: { !sightings($0.sightings).isEmpty }) else { return records }
        var out = records
        var index = Dictionary(out.enumerated().map { ($0.element.key, $0.offset) }, uniquingKeysWith: { a, _ in a })
        for session in sessions {
            for sighting in sightings(session.sightings) {
                let fresh = Self(conversationID: session.conversationID, provider: session.provider,
                                 chatName: session.displayChatName, projectName: session.displayProjectName,
                                 cwd: session.cwd, sighting: sighting)
                if let i = index[fresh.key] {
                    var kept = out[i]
                    if sighting.lastSeenMs >= kept.sighting.lastSeenMs { kept.sighting = sighting }
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
            $0.sighting.lastSeenMs != $1.sighting.lastSeenMs ? $0.sighting.lastSeenMs > $1.sighting.lastSeenMs : $0.key < $1.key
        }
        return Array(out.prefix(cap))
    }
}

/// The persisted records, one list per kind, each capped. Decoding tolerates a missing or
/// unreadable list (a kind added later, a kind whose format changed): that list starts empty and
/// the others survive.
struct HookSightingRecords: Codable, Equatable {
    var hiddenText: [HookSightingRecord<HiddenTextIncident>] = []

    static let capPerKind = 50

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenText = (try? container.decodeIfPresent([HookSightingRecord<HiddenTextIncident>].self, forKey: .hiddenText)) ?? []
    }

    var findings: [AgentSecurityFinding] { hiddenText.map(\.finding) }

    func upserting(_ sessions: [AgentSessionStatus], includeHiddenText: Bool) -> HookSightingRecords {
        var out = self
        if includeHiddenText {
            out.hiddenText = HookSightingRecord.upserting(sessions, \.hiddenText, into: hiddenText, cap: Self.capPerKind)
        }
        return out
    }
}
