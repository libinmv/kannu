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

/// Grouping, driven by the numbers off a real Mac rather than invented ones. On 2026-09-26 that Mac
/// held **27 sighting rows that were 3 problems**, and 28 acknowledged finding ids to match:
///
/// | problem | rows | occurrences | spread |
/// |---|---|---|---|
/// | `aws_access_key` / `ASIA` via Bash | 21 | 22 | 21 distinct fingerprints, one chat |
/// | `command` / `ssh` via Bash | 4 | 7 | 3 chats, Sep 17 → Sep 25 |
/// | `command` / `yt-dlp` via Bash | 2 | 2 | one chat |
///
/// The `ASIA` prefix is an AWS **STS temporary** credential: it rotates by design, so an identity
/// containing the fingerprint could never converge and the row count grew forever.
final class AgentSecurityFindingGroupTests: XCTestCase {
    private let t0: Int64 = 1_790_000_000_000

    private func ms(_ offset: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(t0 + offset) / 1000)
    }

    // MARK: - The real cases

    /// Twenty-one rotating STS keys are one problem with twenty-one keys in it.
    func testRotatingCredentialsCollapseToOneRow() {
        let findings = (0..<21).map { index in
            SecretSighting(
                kind: .awsAccessKey, location: .toolInput, tool: "Bash", prefix: "ASIA", length: 20,
                // Every re-issue has its own fingerprint. That is exactly what must not split the row.
                fingerprint: String(format: "%012x", index),
                eventCount: index == 15 ? 2 : 1,
                firstSeenMs: t0 + Int64(index) * 60_000, lastSeenMs: t0 + Int64(index) * 60_000
            )
            .finding(conversationID: "chat-seo", provider: "claude",
                     chatName: "AI SEO and crawler metadata", projectName: "kannu-site", cwd: "/x/kannu-site")
        }

        let groups = AgentSecurityFindingGroup.group(findings)
        XCTAssertEqual(groups.count, 1, "21 rotations of one credential are one problem, not 21")
        let group = groups[0]
        XCTAssertEqual(group.occurrences, 22, "counts add up across the members")
        XCTAssertEqual(group.distinctFindings, 21, "and the row still knows 21 distinct keys were seen")
        XCTAssertEqual(group.firstSeen, ms(0))
        XCTAssertEqual(group.lastSeen, ms(20 * 60_000))
        XCTAssertEqual(group.projects, ["kannu-site"])
    }

    /// The same policy rule in three different chats is one row, and the count and span come with it.
    func testOnePolicyRuleAcrossThreeChatsIsOneRow() {
        let chats = [
            ("chat-a", "Tenant Delete Agent", "Vendors", 2, Int64(0)),
            ("chat-b", "gitlab orchestration", "Vendors", 3, Int64(86_400_000)),
            ("chat-c", "Claude token usage", "kannu", 2, Int64(8 * 86_400_000)),
        ]
        let findings = chats.map { id, chat, project, events, offset in
            PolicySighting(kind: .command, matched: "ssh", tool: "Bash", blocked: false,
                           eventCount: events, firstSeenMs: t0 + offset, lastSeenMs: t0 + offset + 1_000)
                .finding(conversationID: id, provider: "claude", chatName: chat,
                         projectName: project, cwd: "/x/\(project)")
        }

        let groups = AgentSecurityFindingGroup.group(findings)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].occurrences, 7)
        XCTAssertEqual(groups[0].projects, ["Vendors", "kannu"], "sorted, de-duplicated")
        XCTAssertEqual(groups[0].firstSeen, ms(0))
        XCTAssertEqual(groups[0].lastSeen, ms(8 * 86_400_000 + 1_000))
    }

    /// Two different rules stay two rows — grouping must not over-merge.
    func testDifferentRulesStayApart() {
        let ssh = PolicySighting(kind: .command, matched: "ssh", tool: "Bash", blocked: false,
                                 eventCount: 1, firstSeenMs: t0, lastSeenMs: t0)
            .finding(conversationID: "c", provider: "claude", chatName: "x", projectName: "p", cwd: "/p")
        let ytdlp = PolicySighting(kind: .command, matched: "yt-dlp", tool: "Bash", blocked: false,
                                   eventCount: 1, firstSeenMs: t0, lastSeenMs: t0)
            .finding(conversationID: "c", provider: "claude", chatName: "x", projectName: "p", cwd: "/p")
        XCTAssertEqual(AgentSecurityFindingGroup.group([ssh, ytdlp]).count, 2)
    }

    /// A different secret *kind* is a different problem even with the same prefix and tool.
    func testSecretKindStillSeparates() {
        func secret(_ kind: SecretSighting.Kind) -> AgentSecurityFinding {
            SecretSighting(kind: kind, location: .toolInput, tool: "Bash", prefix: "ASIA", length: 20,
                           fingerprint: "0123456789ab", eventCount: 1, firstSeenMs: t0, lastSeenMs: t0)
                .finding(conversationID: "c", provider: "claude", chatName: "x", projectName: "p", cwd: "/p")
        }
        XCTAssertEqual(AgentSecurityFindingGroup.group([secret(.awsAccessKey), secret(.githubToken)]).count, 2)
    }

    /// Detection is the one family that stays per-chat: a verdict is about one conversation. What it
    /// must stop doing is splitting on a re-analysis, whose confidence sits in the finding id.
    func testDetectionStaysPerChatButNotPerConfidence() {
        func analysis(chat: String, confidence: Double) -> AgentSecurityFinding? {
            ADRSessionAnalysis(
                conversationID: chat, chatName: chat, date: Date(timeIntervalSince1970: 1),
                isMalicious: true, confidence: confidence, tactic: "permission_abuse",
                explanation: "e", threatMessages: 3, totalMessages: 9, method: nil, modelUsed: "m",
                inputTokens: nil, outputTokens: nil, costUSD: nil, triageEnabled: false,
                reportPath: nil
            ).finding()
        }
        let reanalysed = [analysis(chat: "chat-1", confidence: 0.91), analysis(chat: "chat-1", confidence: 0.92)]
            .compactMap { $0 }
        XCTAssertEqual(reanalysed.count, 2, "two findings, because confidence is in the id")
        XCTAssertNotEqual(reanalysed[0].id, reanalysed[1].id)
        XCTAssertEqual(AgentSecurityFindingGroup.group(reanalysed).count, 1,
                       "but re-analysing one chat is one problem")

        let twoChats = [analysis(chat: "chat-1", confidence: 0.91), analysis(chat: "chat-2", confidence: 0.91)]
            .compactMap { $0 }
        XCTAssertEqual(AgentSecurityFindingGroup.group(twoChats).count, 2,
                       "two chats judged malicious are two things to read")
    }

    // MARK: - Roll-up details

    /// A group is as bad as its worst member, and speaks as that member.
    func testTheGroupTakesItsWorstSeverity() {
        let ran = PolicySighting(kind: .command, matched: "ssh", tool: "Bash", blocked: false,
                                 eventCount: 1, firstSeenMs: t0, lastSeenMs: t0)
            .finding(conversationID: "a", provider: "claude", chatName: "a", projectName: "p", cwd: "/p")
        let blocked = PolicySighting(kind: .command, matched: "ssh", tool: "Bash", blocked: true,
                                     eventCount: 1, firstSeenMs: t0, lastSeenMs: t0)
            .finding(conversationID: "b", provider: "claude", chatName: "b", projectName: "p", cwd: "/p")
        XCTAssertEqual(ran.severity, .high, "it ran — worse than Kannu refusing it")
        XCTAssertEqual(blocked.severity, .medium)

        let group = AgentSecurityFindingGroup.group([blocked, ran])
        XCTAssertEqual(group.count, 1)
        XCTAssertEqual(group[0].severity, .high)
        XCTAssertEqual(group[0].representative.severity, .high, "the row speaks as its worst member")
    }

    /// A finding that opts out of grouping is its own group of one, never merged by accident.
    func testAFindingWithNoGroupSubjectStandsAlone() {
        var a = Self.bare(id: "one")
        var b = Self.bare(id: "two")
        a.groupSubject = nil
        b.groupSubject = nil
        let groups = AgentSecurityFindingGroup.group([a, b])
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.map(\.id)), ["one", "two"], "ungrouped rows key on their own id")
    }

    func testGroupingIsStableAndStartsEmpty() {
        XCTAssertTrue(AgentSecurityFindingGroup.group([]).isEmpty)
        let findings = (0..<5).map { Self.bare(id: "f\($0)", subject: "same") }
        XCTAssertEqual(AgentSecurityFindingGroup.group(findings).map(\.id),
                       AgentSecurityFindingGroup.group(findings).map(\.id))
    }

    private static func bare(id: String, subject: String? = nil) -> AgentSecurityFinding {
        var finding = AgentSecurityFinding(
            id: id, source: .kannu, rule: "r", severity: .medium, title: "t", summary: "s",
            evidence: [], assetName: nil, assetPath: nil, sessionID: nil,
            firstSeen: Date(timeIntervalSince1970: 1)
        )
        finding.groupSubject = subject
        return finding
    }
}
