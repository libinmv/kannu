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

/// One row in Settings › Agent Security: a *problem*, not a sighting of it.
///
/// Findings are identified by `stableID(source:rule:subject:evidence:)`, and for everything the hook
/// reports `subject` is the conversation id while `evidence` carries the churn — a secret's
/// fingerprint, a timestamp. That is right for a sighting and wrong for a row: on one real Mac it
/// turned three problems into twenty-seven rows and twenty-eight acknowledgements. Twenty-one of
/// those were the same AWS **STS temporary** credential being re-issued (an `ASIA` prefix rotates by
/// design), so fingerprint-keyed identity could never converge — the count would have grown forever.
///
/// A group therefore keys on `groupID`, which each builder derives from the parts that do *not*
/// churn, and reports what the user actually asked for: first reported, last reported, how many
/// times. Acknowledgement is a separate axis — see `SecurityFindingAcknowledgement`.
struct AgentSecurityFindingGroup: Identifiable, Equatable {
    /// `groupID` of every finding in it.
    let id: String
    /// The finding the row speaks as: most severe, then most recent. Its title, summary, guide and
    /// reveal paths are the ones shown.
    let representative: AgentSecurityFinding
    /// The worst severity in the group — a group is as bad as its worst member.
    let severity: AgentSecurityFinding.Severity
    let firstSeen: Date
    let lastSeen: Date
    /// Total occurrences across every member. The hook counts per chat and `HookSighting.union`
    /// deliberately replaces rather than sums, so cross-chat totals have to be added up here.
    let occurrences: Int
    /// Projects this group has been seen in, sorted. Empty when the source has no project (ADR's
    /// assets, the new-server check) — then only "acknowledge everywhere" makes sense.
    let projects: [String]
    /// How many distinct findings rolled into the row: "21 distinct keys". 1 means the row is a
    /// single sighting and the count adds nothing.
    let distinctFindings: Int
    /// Every member, newest first, for the Details breakdown.
    let findings: [AgentSecurityFinding]

    /// What "has this got worse?" compares against: severity plus the set of outcomes present.
    ///
    /// Severity alone is not enough, and for the policy checks it actively points the wrong way — a
    /// match that *ran* is high, one Kannu *refused* is medium — so "Kannu started blocking this"
    /// would read as an improvement and stay silent. The outcome set catches it.
    var outcomeSignature: String {
        let outcomes = Set(findings.compactMap(\.outcomeTag)).sorted()
        return "\(severity.rawValue)|\(outcomes.joined(separator: ","))"
    }

    /// Rolls findings into one row each. Order is the caller's concern; grouping is stable and
    /// deterministic so the same input always yields the same rows.
    static func group(_ findings: [AgentSecurityFinding]) -> [AgentSecurityFindingGroup] {
        var buckets: [String: [AgentSecurityFinding]] = [:]
        var order: [String] = []
        for finding in findings {
            let key = finding.groupID
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(finding)
        }

        return order.compactMap { key in
            guard let members = buckets[key], let worst = members.max(by: severityThenRecency) else {
                return nil
            }
            let lastSeens = members.map { $0.lastSeen ?? $0.firstSeen }
            return AgentSecurityFindingGroup(
                id: key,
                representative: worst,
                severity: members.map(\.severity).max() ?? worst.severity,
                firstSeen: members.map(\.firstSeen).min() ?? worst.firstSeen,
                lastSeen: lastSeens.max() ?? worst.firstSeen,
                occurrences: members.reduce(0) { $0 + max(1, $1.occurrences) },
                projects: Set(members.compactMap(\.projectName)).sorted(),
                distinctFindings: Set(members.map(\.id)).count,
                findings: members.sorted { severityThenRecency($1, $0) }
            )
        }
    }

    /// Most severe wins; ties go to the most recently seen.
    private static func severityThenRecency(
        _ lhs: AgentSecurityFinding, _ rhs: AgentSecurityFinding
    ) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        return (lhs.lastSeen ?? lhs.firstSeen) < (rhs.lastSeen ?? rhs.firstSeen)
    }
}

/// What Settings and the notch read: every group with its visibility already decided, worst first.
struct SecurityFindingGroups: Equatable {
    struct Row: Equatable {
        let group: AgentSecurityFindingGroup
        let visibility: SecurityFindingGroupVisibility
    }

    let rows: [Row]

    /// Rows worth showing without being asked.
    var visible: [Row] { rows.filter { $0.visibility.isVisible } }
    /// Settled rows, behind "Show acknowledged and snoozed again".
    var acknowledged: [Row] { rows.filter { !$0.visibility.isVisible } }
    /// The one the notch pins, if any.
    var pinned: Row? { visible.first { $0.group.severity == .high } }
    /// The pinned row's finding, for the notch card and the push, which speak about a finding.
    var pinnedFinding: AgentSecurityFinding? { pinned?.group.representative }
    /// What the notch shield counts. Groups, not sightings — so 21 rotations of one credential are
    /// one thing to deal with, which is the number a person can act on.
    var pendingHighCount: Int { visible.filter { $0.group.severity == .high }.count }

    var isEmpty: Bool { rows.isEmpty }
}
