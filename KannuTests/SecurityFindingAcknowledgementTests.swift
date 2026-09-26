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

import XCTest

/// Acknowledging a problem should settle it — quietly, however often it recurs — and it should come
/// back only when it has got worse. And because deciding `ssh` is acceptable in one repo says nothing
/// about another, scope is the user's to choose, defaulting to the narrow one.
final class SecurityFindingAcknowledgementTests: XCTestCase {
    private let t0: Int64 = 1_790_000_000_000

    private func policyGroup(
        matched: String = "ssh", blocked: Bool = false, projects: [String] = ["Vendors"], events: Int = 1
    ) -> AgentSecurityFindingGroup {
        let findings = projects.enumerated().map { index, project in
            PolicySighting(kind: .command, matched: matched, tool: "Bash", blocked: blocked,
                           eventCount: events, firstSeenMs: t0 + Int64(index), lastSeenMs: t0 + Int64(index))
                .finding(conversationID: "chat-\(index)", provider: "claude", chatName: "c\(index)",
                         projectName: project, cwd: "/x/\(project)")
        }
        return AgentSecurityFindingGroup.group(findings)[0]
    }

    private func ack(
        _ group: AgentSecurityFindingGroup, scope: SecurityFindingAcknowledgement.Scope
    ) -> SecurityFindingAcknowledgement {
        SecurityFindingAcknowledgement(
            scope: scope,
            severityAtAck: group.severity.rawValue,
            outcomeAtAck: group.outcomeSignature,
            ackedAt: Date(timeIntervalSince1970: 1)
        )
    }

    // MARK: - The quiet path

    func testNeverAcknowledgedIsVisible() {
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(of: policyGroup(), acknowledgement: nil),
            .unacknowledged
        )
    }

    /// The point of the whole change: recurring, unchanged, stays quiet.
    func testRecurringUnchangedStaysQuiet() {
        let group = policyGroup(events: 1)
        let decision = ack(group, scope: .everywhere)
        let later = policyGroup(events: 40)   // same problem, many more occurrences
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(of: later, acknowledgement: decision),
            .acknowledged,
            "forty more of the same thing is not news once you have decided about it"
        )
    }

    // MARK: - Escalation

    /// The case the user asked for by name. Note it cannot be caught by severity: a policy match
    /// that *ran* is high and one Kannu *refused* is medium, so blocking reads as an improvement.
    func testAPolicyMatchThatStartsBeingBlockedComesBack() {
        let ran = policyGroup(blocked: false)
        let decision = ack(ran, scope: .everywhere)
        let nowBlocked = policyGroup(blocked: true)

        XCTAssertLessThan(nowBlocked.severity.rawValue, ran.severity.rawValue,
                          "severity moves the wrong way here — this is why outcome is tracked")
        guard case .escalated = SecurityFindingAcknowledgement.visibility(
            of: nowBlocked, acknowledgement: decision
        ) else {
            return XCTFail("a changed outcome must resurface an acknowledged group")
        }
    }

    func testARiseInSeverityComesBack() {
        let group = policyGroup()
        var decision = ack(group, scope: .everywhere)
        decision.severityAtAck = AgentSecurityFinding.Severity.info.rawValue
        guard case .escalated = SecurityFindingAcknowledgement.visibility(
            of: group, acknowledgement: decision
        ) else {
            return XCTFail("a group more severe than when it was acknowledged must resurface")
        }
    }

    /// Escalation outranks scope: "everywhere" is a decision about what was happening then.
    func testEscalationBeatsAnEverywhereAcknowledgement() {
        let ran = policyGroup(blocked: false, projects: ["Vendors", "kannu"])
        var decision = ack(ran, scope: .everywhere)
        decision.outcomeAtAck = "something else"
        XCTAssertTrue(
            SecurityFindingAcknowledgement.visibility(of: ran, acknowledgement: decision).isVisible
        )
    }

    // MARK: - Scope

    func testAcknowledgingOneProjectLeavesTheOtherVisible() {
        let group = policyGroup(projects: ["Vendors", "kannu"])
        let decision = ack(group, scope: .projects(["Vendors"]))
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(of: group, acknowledgement: decision),
            .partiallyAcknowledged(unacknowledged: ["kannu"]),
            "the row stays, and says which project is still unaddressed"
        )
    }

    func testCoveringEveryProjectHidesIt() {
        let group = policyGroup(projects: ["Vendors", "kannu"])
        let decision = ack(group, scope: .projects(["Vendors", "kannu"]))
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(of: group, acknowledgement: decision),
            .acknowledged
        )
    }

    func testAddingTheSecondProjectWidensTheDecision() {
        let group = policyGroup(projects: ["Vendors", "kannu"])
        let decision = ack(group, scope: .projects(["Vendors"])).adding(project: "kannu")
        XCTAssertEqual(decision.scope, .projects(["Vendors", "kannu"]), "sorted and de-duplicated")
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(of: group, acknowledgement: decision),
            .acknowledged
        )
    }

    func testEverywhereIsNotNarrowedByAddingAProject() {
        let decision = ack(policyGroup(), scope: .everywhere).adding(project: "kannu")
        XCTAssertEqual(decision.scope, .everywhere, "everywhere already covers every project")
    }

    /// A group with no project — ADR's assets, the new-server check — cannot be settled
    /// project-by-project, so only "everywhere" closes it.
    func testAProjectlessGroupIsOnlySettledEverywhere() {
        var finding = AgentSecurityFinding(
            id: "d1", source: .discovery, rule: "unpinned_mcp_server", severity: .high,
            title: "t", summary: "s", evidence: [], assetName: "notion", assetPath: nil,
            sessionID: nil, firstSeen: Date(timeIntervalSince1970: 1)
        )
        finding.groupSubject = "asset-notion"
        let group = AgentSecurityFindingGroup.group([finding])[0]
        XCTAssertTrue(group.projects.isEmpty)

        XCTAssertTrue(
            SecurityFindingAcknowledgement.visibility(
                of: group, acknowledgement: ack(group, scope: .projects(["anything"]))
            ).isVisible,
            "a project-scoped decision cannot cover a finding that belongs to no project"
        )
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(
                of: group, acknowledgement: ack(group, scope: .everywhere)
            ),
            .acknowledged
        )
    }

    /// A group can mix members that have a project with members that have none. Acknowledging "the
    /// projects this group is in" cannot cover the projectless ones, so it must not hide the row —
    /// otherwise a finding nobody assessed disappears because a sibling was assessed.
    func testAProjectlessMemberIsNotCoveredByAProjectScopedAcknowledgement() {
        let named = PolicySighting(kind: .command, matched: "ssh", tool: "Bash", blocked: false,
                                  eventCount: 1, firstSeenMs: t0, lastSeenMs: t0)
            .finding(conversationID: "a", provider: "claude", chatName: "a",
                     projectName: "Vendors", cwd: "/x/Vendors")
        let projectless = PolicySighting(kind: .command, matched: "ssh", tool: "Bash", blocked: false,
                                        eventCount: 1, firstSeenMs: t0 + 1, lastSeenMs: t0 + 1)
            .finding(conversationID: "b", provider: "claude", chatName: "b",
                     projectName: nil, cwd: nil)
        let group = AgentSecurityFindingGroup.group([named, projectless])[0]
        XCTAssertEqual(group.projects, ["Vendors"], "only the named project is listed")

        XCTAssertTrue(
            SecurityFindingAcknowledgement.visibility(
                of: group, acknowledgement: ack(group, scope: .projects(["Vendors"]))
            ).isVisible,
            "the projectless member is still unaddressed, so the row stays"
        )
        XCTAssertEqual(
            SecurityFindingAcknowledgement.visibility(
                of: group, acknowledgement: ack(group, scope: .everywhere)
            ),
            .acknowledged,
            "only everywhere can settle a member that belongs to no project"
        )
    }

    // MARK: - Persistence shape

    func testItRoundTripsThroughJSON() throws {
        let original = SecurityFindingAcknowledgement(
            scope: .projects(["Vendors", "kannu"]), severityAtAck: 2,
            outcomeAtAck: "2|ran", ackedAt: Date(timeIntervalSince1970: 1_790_000)
        )
        let decoded = try JSONDecoder().decode(
            SecurityFindingAcknowledgement.self, from: JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)

        let everywhere = SecurityFindingAcknowledgement(
            scope: .everywhere, severityAtAck: 1, outcomeAtAck: "", ackedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                SecurityFindingAcknowledgement.self, from: JSONEncoder().encode(everywhere)
            ),
            everywhere
        )
    }
}
