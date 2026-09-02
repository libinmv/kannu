import XCTest

/// Regression pins for the caffeinate pipeline's two pure stages — the decision (should the
/// Mac be held awake?) and the transition (which single IOPM action follows?). The same
/// tables appear in docs/CAFFEINATE.md; a change to either must update all three in one commit.
final class CaffeinateDecisionTests: XCTestCase {

    // MARK: - Stage 1: decision — exhaustive 16-row matrix

    func testDecisionMatrixIsExactlyTheDocumentedTable() {
        // (smart, manual, feature, activeSession) -> shouldHold
        // Rules: feature off => never; smart on => session activity decides; else manual verbatim.
        for smart in [false, true] {
            for manual in [false, true] {
                for feature in [false, true] {
                    for active in [false, true] {
                        let expected: Bool
                        if !feature {
                            expected = false
                        } else if smart {
                            expected = active
                        } else {
                            expected = manual
                        }
                        let got = AgentTrafficLightMapper.shouldKeepAwake(
                            smartEnabled: smart,
                            manualEnabled: manual,
                            featureEnabled: feature,
                            hasActiveVisibleSession: active
                        )
                        XCTAssertEqual(
                            got, expected,
                            "smart=\(smart) manual=\(manual) feature=\(feature) active=\(active): expected \(expected)"
                        )
                    }
                }
            }
        }
    }

    func testFeatureOffReleasesRegardlessOfEverything() {
        // The stranding regression: with the agent feature off, every caffeinate control is
        // hidden, so nothing may hold the Mac awake.
        XCTAssertFalse(AgentTrafficLightMapper.shouldKeepAwake(
            smartEnabled: true, manualEnabled: true, featureEnabled: false, hasActiveVisibleSession: true
        ))
    }

    // MARK: - Stage 2: transition table

    private func transition(
        isHeld: Bool, heldSmart: Bool?, shouldHold: Bool, smartNow: Bool
    ) -> AgentTrafficLightMapper.CaffeinateTransition {
        AgentTrafficLightMapper.caffeinateTransition(
            isHeld: isHeld, heldModeIsSmart: heldSmart, shouldHold: shouldHold, smartNow: smartNow
        )
    }

    func testTransitionTable() {
        // not held, should be -> create
        XCTAssertEqual(transition(isHeld: false, heldSmart: nil, shouldHold: true, smartNow: false), .create)
        // held, should not be -> release
        XCTAssertEqual(transition(isHeld: true, heldSmart: false, shouldHold: false, smartNow: false), .release)
        // held in the same mode -> none
        XCTAssertEqual(transition(isHeld: true, heldSmart: true, shouldHold: true, smartNow: true), .none)
        XCTAssertEqual(transition(isHeld: true, heldSmart: false, shouldHold: true, smartNow: false), .none)
        // held in the other mode -> refresh, both directions
        XCTAssertEqual(transition(isHeld: true, heldSmart: false, shouldHold: true, smartNow: true), .refresh)
        XCTAssertEqual(transition(isHeld: true, heldSmart: true, shouldHold: true, smartNow: false), .refresh)
        // not held, should not be -> none
        XCTAssertEqual(transition(isHeld: false, heldSmart: nil, shouldHold: false, smartNow: true), .none)
    }

    func testUnknownHeldModeWhileHeldRefreshesRatherThanLies() {
        // heldModeIsSmart is nil only when nothing is held; if state ever disagreed, refreshing
        // (re-stamping the correct reason) is the safe answer — never a silent .none.
        XCTAssertEqual(transition(isHeld: true, heldSmart: nil, shouldHold: true, smartNow: false), .refresh)
    }

    // MARK: - Smart-mode session predicate

    private func session(
        id: String = "conv-real",
        visible: Bool = true,
        display: AgentTrafficLightState = .executing
    ) -> AgentSessionStatus {
        AgentSessionStatus(
            id: "claude-\(id)",
            provider: "claude",
            conversationID: id,
            chatName: nil,
            projectName: nil,
            rawState: "executing",
            displayState: display,
            updatedAt: Date(timeIntervalSince1970: 1_000),
            isVisible: visible,
            executionStartedAt: nil,
            cwd: nil,
            hostPID: nil
        )
    }

    func testActiveVisibleSessionQualifies() {
        XCTAssertTrue(AgentTrafficLightMapper.hasCaffeinateWorthySession([session()]))
        XCTAssertTrue(AgentTrafficLightMapper.hasCaffeinateWorthySession([session(display: .awaitingInput)]))
    }

    func testInvisibleSessionDoesNotQualify() {
        XCTAssertFalse(AgentTrafficLightMapper.hasCaffeinateWorthySession([session(visible: false)]))
    }

    func testSimulationSessionDoesNotQualify() {
        // Same ID conventions isSimulationSession recognizes.
        XCTAssertFalse(AgentTrafficLightMapper.hasCaffeinateWorthySession([session(id: "kannu-test-demo")]))
        XCTAssertFalse(AgentTrafficLightMapper.hasCaffeinateWorthySession([session(id: "test-123")]))
    }

    func testStoppedAndInactiveDoNotQualify() {
        XCTAssertFalse(AgentTrafficLightMapper.hasCaffeinateWorthySession([
            session(display: .stopped), session(display: .inactive),
        ]))
    }

    func testOneQualifyingSessionInAMixedListHolds() {
        XCTAssertTrue(AgentTrafficLightMapper.hasCaffeinateWorthySession([
            session(id: "a", display: .stopped),
            session(id: "b", visible: false),
            session(id: "c", display: .thinking),
        ]))
    }

    func testEmptyListReleases() {
        XCTAssertFalse(AgentTrafficLightMapper.hasCaffeinateWorthySession([]))
    }
}
