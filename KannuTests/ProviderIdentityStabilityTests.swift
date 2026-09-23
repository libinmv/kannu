import XCTest

/// Pins the rule that a conversation reported by a host provider and the engine it embeds
/// (Cursor's composer driving Claude Code — one uuid, two hook sets) keeps ONE identity:
/// the host names the card, the fresher record supplies the state. Before this, every merge
/// re-picked the whole winning record, so the row's provider, icon and id flapped per rescan.
/// Also pins the grace that keeps a fresh unbacked Cursor hook file alive: one slow read of
/// Cursor's multi-gigabyte state.vscdb must not delete a live card.
final class ProviderIdentityStabilityTests: XCTestCase {
    private func session(
        provider: String,
        conversation: String = "conv-1",
        chatName: String? = nil,
        display: AgentTrafficLightState = .thinking,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        toolErrorCount: Int = 0
    ) -> AgentSessionStatus {
        var session = AgentSessionStatus(
            id: "\(provider)-\(conversation)",
            provider: provider,
            conversationID: conversation,
            chatName: chatName,
            projectName: nil,
            rawState: "thinking",
            displayState: display,
            updatedAt: updatedAt,
            isVisible: true,
            executionStartedAt: nil,
            cwd: nil,
            hostPID: nil
        )
        session.toolErrorCount = toolErrorCount
        return session
    }

    // MARK: - Host identity

    func testHostNamesASameConversationCrossProviderPair() {
        // Claude wins on state (executing outranks thinking), yet the card keeps Cursor's
        // identity and its real title.
        let cursor = session(provider: "cursor", chatName: "Refactor the parser",
                             display: .thinking, updatedAt: Date(timeIntervalSince1970: 1_000))
        let claude = session(provider: "claude", display: .executing,
                             updatedAt: Date(timeIntervalSince1970: 2_000))
        for pair in [(cursor, claude), (claude, cursor)] {
            let picked = AgentTrafficLightMapper.preferredSession(existing: pair.0, incoming: pair.1)
            XCTAssertEqual(picked.provider, "cursor", "the host names the card, whatever the order")
            XCTAssertEqual(picked.id, "cursor-conv-1")
            XCTAssertEqual(picked.displayState, .executing, "the state stays the winner's")
            XCTAssertEqual(picked.chatName, "Refactor the parser")
        }
    }

    func testIdentityIsStableWhicheverSideIsFresher() {
        // The bug: freshness alternated per rescan and took the provider with it. Whichever
        // side is newer, the identity must not move.
        for (cursorAt, claudeAt) in [(1_000.0, 2_000.0), (2_000.0, 1_000.0)] {
            let cursor = session(provider: "cursor", updatedAt: Date(timeIntervalSince1970: cursorAt))
            let claude = session(provider: "claude", updatedAt: Date(timeIntervalSince1970: claudeAt))
            let picked = AgentTrafficLightMapper.preferredSession(existing: cursor, incoming: claude)
            XCTAssertEqual(picked.provider, "cursor")
        }
    }

    func testSameProviderPairKeepsTheWinnerWholesale() {
        let older = session(provider: "claude", chatName: "A", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = session(provider: "claude", chatName: "B", updatedAt: Date(timeIntervalSince1970: 2_000))
        let picked = AgentTrafficLightMapper.preferredSession(existing: older, incoming: newer)
        XCTAssertEqual(picked.chatName, "B")
    }

    func testHostIdentityOnlyCrossesTheHostEngineBoundary() {
        let cursor = session(provider: "cursor")
        let vscode = session(provider: "vscode")
        let claude = session(provider: "claude")
        let codex = session(provider: "codex")
        XCTAssertNil(AgentTrafficLightMapper.hostIdentitySession(cursor, vscode), "two hosts: no crossing")
        XCTAssertNil(AgentTrafficLightMapper.hostIdentitySession(claude, codex), "two engines: no crossing")
        XCTAssertEqual(AgentTrafficLightMapper.hostIdentitySession(cursor, claude)?.provider, "cursor")
        XCTAssertEqual(AgentTrafficLightMapper.hostIdentitySession(codex, vscode)?.provider, "vscode")
    }

    func testDifferentConversationsStayTwoRows() {
        let cursor = session(provider: "cursor", conversation: "conv-a")
        let claude = session(provider: "claude", conversation: "conv-b")
        let rows = AgentTrafficLightMapper.latestSessions([cursor, claude])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.provider)), ["cursor", "claude"])
    }

    func testAdoptingIdentityKeepsStateAndExtrasAndPrefersTheHostsRealTitle() {
        var winner = session(provider: "claude", chatName: "claude-side name",
                             display: .executing, toolErrorCount: 3)
        winner.isUnattended = true
        let host = session(provider: "cursor", chatName: "Cursor title", display: .stopped)
        let adopted = winner.adoptingIdentity(of: host)
        XCTAssertEqual(adopted.provider, "cursor")
        XCTAssertEqual(adopted.id, "cursor-conv-1")
        XCTAssertEqual(adopted.displayState, .executing)
        XCTAssertEqual(adopted.chatName, "Cursor title")
        XCTAssertEqual(adopted.toolErrorCount, 3, "extras ride through carryingExtras — entry 7")
        XCTAssertTrue(adopted.isUnattended)
    }

    func testAdoptingIdentityKeepsTheWinnersNameWhenTheHostHasNone() {
        let winner = session(provider: "claude", chatName: "Only real title")
        let host = session(provider: "cursor", chatName: nil)
        XCTAssertEqual(winner.adoptingIdentity(of: host).chatName, "Only real title")
    }

    // MARK: - Unbacked hook-file grace

    func testFreshUnbackedCursorHookFileSurvivesABackingMiss() {
        let now: Int64 = 1_000_000_000_000
        XCTAssertFalse(AgentTrafficLightMapper.shouldDropUnbackedCursorHookFile(tsMs: now - 60_000, nowMs: now))
        XCTAssertFalse(AgentTrafficLightMapper.shouldDropUnbackedCursorHookFile(
            tsMs: now - AgentTrafficLightMapper.unbackedCursorHookGraceMs, nowMs: now))
    }

    func testStaleUnbackedCursorHookFileIsDropped() {
        let now: Int64 = 1_000_000_000_000
        XCTAssertTrue(AgentTrafficLightMapper.shouldDropUnbackedCursorHookFile(
            tsMs: now - AgentTrafficLightMapper.unbackedCursorHookGraceMs - 1, nowMs: now))
    }
}
