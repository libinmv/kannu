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

/// A decision the user made about a whole problem, and how far it reaches.
///
/// Acknowledgement used to be a bare set of finding ids, pruned to whatever was on screen
/// (`SecurityFindingsStore.ingest`) on the principle that "if the same finding returns later it
/// should be seen again". That principle is what made the same `ssh` match ask for a fresh
/// acknowledgement in every new chat. It is deliberately replaced here: an acknowledged group stays
/// quiet however often it recurs, and comes back only when it has got *worse*.
///
/// Scope is its own axis because display grouping does not decide it. Deciding `ssh` is fine in one
/// repo says nothing about another, so the default is the narrow one.
struct SecurityFindingAcknowledgement: Codable, Equatable {
    enum Scope: Codable, Equatable {
        /// This problem is settled everywhere, in any project.
        case everywhere
        /// Settled only in these projects. Seeing it in a project not listed here brings it back.
        case projects([String])
    }

    var scope: Scope
    /// The severity when the user decided. A rise means they judged a milder thing than this.
    var severityAtAck: Int
    /// `AgentSecurityFindingGroup.outcomeSignature` when the user decided. A change means the shape
    /// of the problem moved — e.g. a policy match that used to just run is now being blocked.
    var outcomeAtAck: String
    var ackedAt: Date

    /// Folds a project into an existing decision. Acknowledging a second project widens the list;
    /// acknowledging everywhere replaces it, since everywhere already covers every project.
    func adding(project: String?) -> SecurityFindingAcknowledgement {
        var copy = self
        switch scope {
        case .everywhere:
            break
        case .projects(let existing):
            guard let project else { copy.scope = .everywhere; break }
            copy.scope = .projects(Set(existing + [project]).sorted())
        }
        return copy
    }
}

/// Whether a group is on screen, and why.
enum SecurityFindingGroupVisibility: Equatable {
    /// Never acknowledged.
    case unacknowledged
    /// Acknowledged, and it has since got worse — severity rose, or the outcome changed.
    case escalated(reason: String)
    /// Acknowledged in some projects but seen in these others since.
    case partiallyAcknowledged(unacknowledged: [String])
    /// Settled. Not shown unless the user asks to see acknowledged rows.
    case acknowledged

    var isVisible: Bool {
        switch self {
        case .unacknowledged, .escalated, .partiallyAcknowledged: return true
        case .acknowledged: return false
        }
    }
}

extension SecurityFindingAcknowledgement {
    /// The visibility rule, in one place.
    ///
    /// Escalation is checked *before* scope: a problem that got worse is worth re-reading even where
    /// the user said "everywhere", because what they acknowledged is not what is happening now.
    static func visibility(
        of group: AgentSecurityFindingGroup,
        acknowledgement: SecurityFindingAcknowledgement?
    ) -> SecurityFindingGroupVisibility {
        guard let ack = acknowledgement else { return .unacknowledged }

        if group.severity.rawValue > ack.severityAtAck {
            return .escalated(reason: String(localized: "more severe than when you acknowledged it"))
        }
        if group.outcomeSignature != ack.outcomeAtAck {
            return .escalated(reason: String(localized: "changed since you acknowledged it"))
        }

        switch ack.scope {
        case .everywhere:
            return .acknowledged
        case .projects(let acknowledged):
            // A group with no project at all cannot be covered project-by-project; only
            // "everywhere" settles it, so treat a project-scoped ack as not covering it.
            guard !group.projects.isEmpty else { return .partiallyAcknowledged(unacknowledged: []) }
            let outstanding = group.projects.filter { !acknowledged.contains($0) }
            return outstanding.isEmpty ? .acknowledged
                                       : .partiallyAcknowledged(unacknowledged: outstanding)
        }
    }
}
