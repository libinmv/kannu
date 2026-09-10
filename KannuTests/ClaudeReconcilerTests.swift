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
        hostPID: Int? = nil,
        toolErrorCount: Int = 0,
        unattended: Bool = false,
        runError: RunError? = nil,
        desktopSessionID: String? = nil
    ) -> AgentSessionStatus {
        var session = AgentSessionStatus(
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
        session.toolErrorCount = toolErrorCount
        session.isUnattended = unattended
        session.runError = runError
        session.desktopSessionID = desktopSessionID
        return session
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
                              cwd: "/tmp/proj", hostPID: 4242, toolErrorCount: 2, unattended: true,
                              runError: .apiError(status: 429))
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
        XCTAssertEqual(merged.toolErrorCount, 2, "the tool-error count keeps the larger side")
        XCTAssertTrue(merged.isUnattended, "the unattended flag rides the seam too")
        XCTAssertEqual(merged.runError, .apiError(status: 429), "the transcript's verdict fills a hook that has none")
    }

    // MARK: - Entry 12: a held yellow survives passive activity, dies with the process

    func testHeldYellowSurvivesPassiveToolInFlight() {
        // The hook's yellow is old (a prompt left open); the passive side sees a live process
        // with an outstanding tool_use — an active run, so the demote arm must not fire.
        let hook = session(rawState: "awaiting_input", display: .awaitingInput,
                           updatedAt: Date(timeIntervalSince1970: 1_000))
        let passive = session(chatName: "Ask", rawState: "executing", display: .executing,
                              updatedAt: Date(timeIntervalSince1970: 1_900), hostPID: 4242)
        let out = reconcile(hooks: [hook], passive: [passive])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].displayState, .awaitingInput)
        XCTAssertTrue(out[0].isVisible)
        XCTAssertEqual(out[0].hostPID, 4242)
        XCTAssertEqual(out[0].chatName, "Ask")
    }

    func testHeldYellowDemotesWhenTheProcessDies() {
        let hook = session(rawState: "awaiting_input", display: .awaitingInput,
                           updatedAt: Date(timeIntervalSince1970: 1_000))
        let passive = session(rawState: "stopped", display: .stopped,
                              updatedAt: Date(timeIntervalSince1970: 1_950))
        XCTAssertEqual(reconcile(hooks: [hook], passive: [passive], dead: ["conv-1"])[0].displayState, .stopped)
        XCTAssertFalse(reconcile(hooks: [hook], passive: [], dead: ["conv-1"])[0].displayState.isActiveRun)
    }

    func testAgedYellowIsNotPromotedByPassiveActivity() {
        // An expired, unheld yellow stays out of the promote arm: one unreadable tail on a live
        // process (entry 3 maps it to thinking) must not turn it green.
        let hook = session(rawState: "awaiting_input", display: .inactive,
                           updatedAt: Date(timeIntervalSince1970: 500), visible: false)
        let passive = session(rawState: "thinking", display: .thinking,
                              updatedAt: Date(timeIntervalSince1970: 1_900))
        let out = reconcile(hooks: [hook], passive: [passive])
        XCTAssertEqual(out[0].displayState, .inactive)
        XCTAssertFalse(out[0].isVisible)
    }

    func testDesktopSessionIDCarriesAcrossBothReconcilerArms() {
        // Entry 7's field set grows: the Desktop chat locator is passive-only, like hostPID.
        let passiveStopped = session(rawState: "stopped", display: .stopped,
                                     updatedAt: Date(timeIntervalSince1970: 1_500), desktopSessionID: "local_x")
        let demoted = reconcile(hooks: [session(rawState: "executing", display: .executing)], passive: [passiveStopped])
        XCTAssertEqual(demoted[0].displayState, .stopped)
        XCTAssertEqual(demoted[0].desktopSessionID, "local_x", "demote arm")
        let passiveActive = session(rawState: "executing", display: .executing, desktopSessionID: "local_x")
        let unchanged = reconcile(hooks: [session(rawState: "executing", display: .executing)], passive: [passiveActive])
        XCTAssertEqual(unchanged[0].desktopSessionID, "local_x", "pass-through arm")
        let promoted = reconcile(hooks: [session(rawState: "thinking", display: .inactive)], passive: [passiveActive])
        XCTAssertEqual(promoted[0].desktopSessionID, "local_x", "promote arm")
    }

    func testRunVerdictSeamPrefersTheHookThenTheMoreSpecificReason() {
        // Both sides describe the same stop: the more specific reason wins.
        let hookFailed = session(rawState: "stopped", display: .stopped, runError: .failed)
        let passiveApi = session(rawState: "stopped", display: .stopped, runError: .apiError(status: 429))
        XCTAssertEqual(reconcile(hooks: [hookFailed], passive: [passiveApi])[0].runError, .apiError(status: 429))
        // Stop never says whether the turn went well; the transcript saw the API error.
        let hookClean = session(rawState: "stopped", display: .stopped)
        XCTAssertEqual(reconcile(hooks: [hookClean], passive: [passiveApi])[0].runError, .apiError(status: 429))
        // The hook's verdict stands when the transcript has none.
        let passiveClean = session(rawState: "stopped", display: .stopped)
        XCTAssertEqual(reconcile(hooks: [hookFailed], passive: [passiveClean])[0].runError, .failed)
        XCTAssertNil(reconcile(hooks: [hookClean], passive: [passiveClean])[0].runError)
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
