//
//  AgentSecurityFindingTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

final class AgentSecurityFindingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot() throws -> ADRSnapshot {
        try ADRSnapshot.decode(Data(ADRSnapshotFixture.json.utf8))
    }

    private func finding(_ id: String, _ severity: AgentSecurityFinding.Severity, seen: TimeInterval = 0, title: String = "t") -> AgentSecurityFinding {
        AgentSecurityFinding(id: id, source: .kannu, rule: "r", severity: severity, title: title, summary: "s",
                             evidence: [], assetName: nil, assetPath: nil, sessionID: nil,
                             firstSeen: t0.addingTimeInterval(seen))
    }

    // MARK: - Mapping from a Discovery snapshot

    func testDiscoveryFindingsAreJoinedToTheirAssets() throws {
        let findings = AgentSecurityFinding.findings(from: try snapshot(), now: t0)
        XCTAssertEqual(findings.count, 1)
        let f = findings[0]
        XCTAssertEqual(f.source, .discovery)
        XCTAssertEqual(f.rule, "unpinned_mcp_server")
        XCTAssertEqual(f.severity, .medium)
        XCTAssertEqual(f.title, "Unpinned MCP server")
        XCTAssertEqual(f.summary, "notion resolves its package at launch time")
        XCTAssertEqual(f.assetName, "notion")
        XCTAssertEqual(f.assetPath, "/Users/dev/.claude/mcp.json")
        XCTAssertEqual(f.evidence, ["no version in the resolved operand — /Users/dev/.claude/mcp.json"])
        XCTAssertEqual(f.firstSeen, t0)
    }

    func testIDIsStableAcrossScansAndChangesWithEvidence() throws {
        let a = AgentSecurityFinding.findings(from: try snapshot(), now: t0)[0]
        let b = AgentSecurityFinding.findings(from: try snapshot(), now: t0.addingTimeInterval(86_400))[0]
        XCTAssertEqual(a.id, b.id, "same finding on the next scan is the same finding")
        XCTAssertEqual(a.id.count, 24)

        let changed = ADRSnapshotFixture.json.replacingOccurrences(of: "no version in the resolved operand", with: "image tag is not a digest")
        let c = AgentSecurityFinding.findings(from: try ADRSnapshot.decode(Data(changed.utf8)), now: t0)[0]
        XCTAssertNotEqual(a.id, c.id, "different evidence is a new finding")
    }

    func testFirstSeenSurvivesARescan() throws {
        let first = AgentSecurityFinding.findings(from: try snapshot(), now: t0)
        let later = AgentSecurityFinding.findings(from: try snapshot(), existing: first, now: t0.addingTimeInterval(3_600))
        XCTAssertEqual(later[0].firstSeen, t0)
    }

    /// The invariant `publishFindings()` rests on, and the one nothing pinned before 1.3.2.
    ///
    /// Findings are never persisted — all five sources are rebuilt on every publish, and
    /// `combined != findings` is the only gate stopping `@Published findings` from firing each
    /// time. So a rebuild from unchanged input must be **equal**, including when the rebuild
    /// happens at a different wall-clock time. In 1.3.1 two builders took a fresh `Date()` for
    /// `lastSeen`, the gate never held, and the notch, the closed pill and Settings re-rendered
    /// continuously: 41% CPU and 928 idle wakeups a second, from an app documented at 0.9% and 12.
    func testRebuildingFromUnchangedInputIsEqual() throws {
        let snap = try snapshot()
        let sessions = [session("a", unattended: true), session("b", unattended: true)]

        let discoveryFirst = AgentSecurityFinding.findings(from: snap, now: t0)
        let nativeFirst = AgentSecurityFinding.nativeFindings(from: sessions, now: t0)

        // A later publish, with the previous round fed back in exactly as the store does it.
        let discoveryAgain = AgentSecurityFinding.findings(from: snap, existing: discoveryFirst, now: t0.addingTimeInterval(7))
        let nativeAgain = AgentSecurityFinding.nativeFindings(from: sessions, existing: nativeFirst, now: t0.addingTimeInterval(7))

        XCTAssertEqual(discoveryAgain, discoveryFirst, "a Discovery rebuild moved, so every publish would republish")
        XCTAssertEqual(nativeAgain, nativeFirst, "an unattended rebuild moved, so every publish would republish")

        // And once more, to catch a value that only settles on the second pass.
        XCTAssertEqual(AgentSecurityFinding.findings(from: snap, existing: discoveryAgain, now: t0.addingTimeInterval(900)), discoveryFirst)
        XCTAssertEqual(AgentSecurityFinding.nativeFindings(from: sessions, existing: nativeAgain, now: t0.addingTimeInterval(900)), nativeFirst)
    }

    func testDiscoveryLastSeenIsTheScanTimeNotTheRebuildTime() throws {
        let findings = AgentSecurityFinding.findings(from: try snapshot(), now: t0)
        // The fixture's own "timestamp": 2026-09-09T02:00:00+00:00.
        XCTAssertEqual(findings[0].lastSeen, Date(timeIntervalSince1970: 1_788_919_200))
    }

    func testDiscoveryLastSeenIsNilRatherThanNowWhenTheScanHasNoTimestamp() throws {
        let undated = ADRSnapshotFixture.json.replacingOccurrences(
            of: "\"timestamp\": \"2026-09-09T02:00:00+00:00\"", with: "\"timestamp\": \"\"")
        let snap = try ADRSnapshot.decode(Data(undated.utf8))
        let first = AgentSecurityFinding.findings(from: snap, now: t0)
        XCTAssertNil(first[0].lastSeen, "an unknown last-seen must not become the rebuild's clock")
        // Still stable, and a carried value still survives.
        XCTAssertEqual(AgentSecurityFinding.findings(from: snap, existing: first, now: t0.addingTimeInterval(60)), first)
    }

    func testUnattendedLastSeenIsTheSessionsOwnClock() {
        let findings = AgentSecurityFinding.nativeFindings(from: [session("a", unattended: true)], now: t0.addingTimeInterval(5_000))
        XCTAssertEqual(findings[0].lastSeen, t0, "the session's updatedAt, not the rebuild's Date()")
    }

    func testSeverityWordsAndUnknownRuleTitles() {
        XCTAssertEqual(AgentSecurityFinding.Severity(adr: "high"), .high)
        XCTAssertEqual(AgentSecurityFinding.Severity(adr: "critical"), .high)
        XCTAssertEqual(AgentSecurityFinding.Severity(adr: "medium"), .medium)
        XCTAssertEqual(AgentSecurityFinding.Severity(adr: "low"), .info)
        XCTAssertEqual(AgentSecurityFinding.Severity(adr: "weird"), .medium, "an unknown word is still a finding")
        XCTAssertEqual(AgentSecurityFinding.title(forRule: "undeclared_mcp_server"), "Running MCP server nobody declared")
        XCTAssertEqual(AgentSecurityFinding.title(forRule: "brand_new_rule"), "Brand new rule")
    }

    // MARK: - Kannu-native findings

    private func session(_ id: String, unattended: Bool, visible: Bool = true) -> AgentSessionStatus {
        var s = AgentSessionStatus(
            id: "claude-\(id)", provider: "claude", conversationID: id, chatName: "Chat \(id)", projectName: "proj",
            rawState: "executing", displayState: .executing, updatedAt: t0, isVisible: visible,
            executionStartedAt: nil, cwd: "/Users/dev/proj", hostPID: nil
        )
        s.isUnattended = unattended
        return s
    }

    func testUnattendedSessionsBecomeHighNativeFindingsWhileVisible() {
        let sessions = [session("a", unattended: true), session("b", unattended: false), session("c", unattended: true, visible: false)]
        let findings = AgentSecurityFinding.nativeFindings(from: sessions, now: t0)
        XCTAssertEqual(findings.count, 1)
        let f = findings[0]
        XCTAssertEqual(f.source, .kannu)
        XCTAssertEqual(f.rule, "unattended_execution")
        XCTAssertEqual(f.severity, .high)
        XCTAssertEqual(f.sessionID, "a")
        XCTAssertEqual(f.assetPath, "/Users/dev/proj")
        XCTAssertEqual(f.title, "Permission checks bypassed")
        // Same session next cycle: same id, original firstSeen.
        let again = AgentSecurityFinding.nativeFindings(from: sessions, existing: findings, now: t0.addingTimeInterval(60))
        XCTAssertEqual(again[0].id, f.id)
        XCTAssertEqual(again[0].firstSeen, t0)
        // Session gone: finding gone.
        XCTAssertTrue(AgentSecurityFinding.nativeFindings(from: [session("b", unattended: false)], existing: findings, now: t0).isEmpty)
    }

    func testUnattendedFlagSurvivesReconstruction() {
        let flagged = session("a", unattended: true)
        XCTAssertTrue(flagged.withDisplayState(.stopped, visible: true).isUnattended)
        XCTAssertTrue(flagged.replacingChatName("x").isUnattended)
        XCTAssertTrue(flagged.replacingProjectName("y").isUnattended)
        let plain = session("a", unattended: false)
        XCTAssertTrue(plain.carryingExtras(from: flagged).isUnattended, "the flag is an OR across a merge seam")
        XCTAssertFalse(plain.carryingExtras(from: plain).isUnattended)
    }

    // MARK: - Priority

    func testRankingOrdersBySeverityThenRecency() {
        let findings = [
            finding("m-old", .medium, seen: 0),
            finding("h-old", .high, seen: 0),
            finding("i", .info, seen: 100),
            finding("h-new", .high, seen: 50),
            finding("m-new", .medium, seen: 10),
        ]
        let ranking = SecurityFindingPriority.rank(findings, acknowledged: [], snoozes: [], now: t0)
        XCTAssertEqual(ranking.visible.map(\.id), ["h-new", "h-old", "m-new", "m-old", "i"])
        XCTAssertEqual(ranking.pinned?.id, "h-new")
        XCTAssertEqual(ranking.pendingHighCount, 2)
    }

    func testAcknowledgedAndSnoozedAreHiddenUntilTheSnoozeExpires() {
        let findings = [finding("a", .high), finding("b", .high), finding("c", .medium)]
        let snoozes = [SecurityFindingSnooze(id: "b", until: t0.addingTimeInterval(3_600))]
        let during = SecurityFindingPriority.rank(findings, acknowledged: ["a"], snoozes: snoozes, now: t0)
        XCTAssertEqual(during.visible.map(\.id), ["c"])
        XCTAssertNil(during.pinned)
        XCTAssertEqual(during.pendingHighCount, 0)

        let after = SecurityFindingPriority.rank(findings, acknowledged: ["a"], snoozes: snoozes, now: t0.addingTimeInterval(3_601))
        XCTAssertEqual(after.visible.map(\.id), ["b", "c"])
        XCTAssertEqual(after.pinned?.id, "b")
    }

    func testPrunedDropsExpiredAndVanishedSnoozes() {
        let snoozes = [
            SecurityFindingSnooze(id: "keep", until: t0.addingTimeInterval(10)),
            SecurityFindingSnooze(id: "expired", until: t0.addingTimeInterval(-1)),
            SecurityFindingSnooze(id: "gone", until: t0.addingTimeInterval(10)),
        ]
        XCTAssertEqual(SecurityFindingPriority.pruned(snoozes, keeping: ["keep", "expired"], now: t0).map(\.id), ["keep"])
    }
}
