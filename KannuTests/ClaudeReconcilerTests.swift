import XCTest

/// Pins the Claude hook/passive reconciler — the merge that regressed repeatedly while it
/// lived inline in the monitor (docs/REGRESSIONS.md entries 5 and 7).
final class ClaudeReconcilerTests: XCTestCase {
    private func session(
        provider: String = "claude",
        conversation: String = "conv-1",
        chatName: String? = nil,
        projectName: String? = nil,
        rawState: String = "executing",
        display: AgentTrafficLightState = .executing,
        updatedAt: Date = Date(timeIntervalSince1970: 1_000),
        visible: Bool = true,
        cwd: String? = nil,
        hostPID: Int? = nil
    ) -> AgentSessionStatus {
        AgentSessionStatus(
            id: "\(provider)-\(conversation)",
            provider: provider,
            conversationID: conversation,
            chatName: chatName,
            projectName: projectName,
            rawState: rawState,
            displayState: display,
            updatedAt: updatedAt,
            isVisible: visible,
            executionStartedAt: nil,
            cwd: cwd,
            hostPID: hostPID
        )
    }

    private func reconcile(
        hooks: [AgentSessionStatus],
        passive: [AgentSessionStatus],
        dead: Set<String> = []
    ) -> [AgentSessionStatus] {
        AgentTrafficLightMapper.reconcileClaudeSessions(
            hookSessions: hooks,
            passiveSessions: passive,
            deadPIDConversationIDs: dead,
            collapseMs: 60_000,
            inactiveMs: 120_000,
            nowMs: 2_000_000
        )
    }

    // MARK: - Entry 7: every passive-only field must survive the hook shadowing

    func testInheritedFieldsCarryAcrossOnDemote() {
        let hook = session(rawState: "executing", display: .executing,
                           updatedAt: Date(timeIntervalSince1970: 1_000))
        let passive = session(chatName: "Fix the parser", projectName: "kannu",
                              rawState: "stopped", display: .stopped,
                              updatedAt: Date(timeIntervalSince1970: 1_500),
                              cwd: "/tmp/proj", hostPID: 4242)
        let out = reconcile(hooks: [hook], passive: [passive])
        XCTAssertEqual(out.count, 1)
        let merged = out[0]
        // The demote itself:
        XCTAssertEqual(merged.displayState, .stopped)
        // Entry 7's field set — dropping ANY of these from inheritingPassiveData fails here:
        XCTAssertEqual(merged.chatName, "Fix the parser")
        XCTAssertEqual(merged.projectName, "kannu")
        XCTAssertEqual(merged.cwd, "/tmp/proj")
        XCTAssertEqual(merged.hostPID, 4242)
    }

    func testInheritedFieldsCarryAcrossOnUnchangedSession() {
        // Hook active, passive ALSO active (no demote, no promote arm change) — the
        // pass-through exit must still inherit. This is the arm that lost fields twice.
        let hook = session(rawState: "executing", display: .executing)
        let passive = session(chatName: "Title", rawState: "executing", display: .executing,
                              updatedAt: Date(timeIntervalSince1970: 900), hostPID: 7)
        let out = reconcile(hooks: [hook], passive: [passive])
        XCTAssertEqual(out[0].chatName, "Title")
        XCTAssertEqual(out[0].hostPID, 7)
        XCTAssertEqual(out[0].displayState, .executing)
    }

    // MARK: - Demotion

    func testDeadPIDWithoutPassiveDemotesFromHookTimestamp() {
        let hook = session(rawState: "executing", display: .executing,
                           updatedAt: Date(timeIntervalSince1970: 1_999))
        let out = reconcile(hooks: [hook], passive: [], dead: ["conv-1"])
        XCTAssertFalse(out[0].displayState.isActiveRun,
                       "a dead process must not stay green")
    }

    func testFreshHookIsNotDemotedByOlderPassiveEvidence() {
        let hook = session(rawState: "executing", display: .executing,
                           updatedAt: Date(timeIntervalSince1970: 1_800))
        let passive = session(rawState: "stopped", display: .stopped,
                              updatedAt: Date(timeIntervalSince1970: 1_200))
        let out = reconcile(hooks: [hook], passive: [passive])
        XCTAssertEqual(out[0].displayState, .executing,
                       "older passive evidence must not demote a fresher hook")
    }

    // MARK: - Promotion (long tool, aged-out hook)

    func testAgedOutHookIsPromotedByLivePassiveRun() {
        let hook = session(rawState: "executing", display: .inactive,
                           updatedAt: Date(timeIntervalSince1970: 500), visible: false)
        let passive = session(rawState: "executing", display: .executing,
                              updatedAt: Date(timeIntervalSince1970: 1_900))
        let out = reconcile(hooks: [hook], passive: [passive])
        XCTAssertEqual(out[0].displayState, .executing)
        XCTAssertTrue(out[0].isVisible)
        XCTAssertEqual(out[0].updatedAt, Date(timeIntervalSince1970: 1_900))
    }

    // MARK: - Structure

    func testPassiveOnlySessionsAreAppended() {
        let hook = session(conversation: "conv-1")
        let passiveOnly = session(conversation: "conv-2", chatName: "Solo",
                                  rawState: "stopped", display: .stopped)
        let out = reconcile(hooks: [hook], passive: [passiveOnly])
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out.contains(where: { $0.conversationID == "conv-2" && $0.chatName == "Solo" }))
    }

    func testNonClaudeSessionsPassThroughUntouched() {
        let cursor = session(provider: "cursor", conversation: "c-9",
                             rawState: "executing", display: .executing)
        let passive = session(conversation: "c-9", rawState: "stopped", display: .stopped,
                              updatedAt: Date(timeIntervalSince1970: 1_999))
        let out = reconcile(hooks: [cursor], passive: [passive], dead: ["c-9"])
        XCTAssertEqual(out.first(where: { $0.provider == "cursor" })?.displayState, .executing)
    }

    func testEmptyPassiveAndNoDeadPIDsIsIdentity() {
        let hook = session()
        let out = reconcile(hooks: [hook], passive: [])
        XCTAssertEqual(out, [hook])
    }
}
