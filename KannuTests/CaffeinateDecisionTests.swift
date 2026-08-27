import XCTest

/// Pins the caffeinate arbitration, especially the feature-off override: with the agent
/// feature disabled every caffeinate control is hidden, so nothing may hold the Mac awake.
final class CaffeinateDecisionTests: XCTestCase {
    private func decide(smart: Bool, manual: Bool, feature: Bool = true, active: Bool = false) -> Bool {
        AgentTrafficLightMapper.shouldKeepAwake(
            smartEnabled: smart,
            manualEnabled: manual,
            featureEnabled: feature,
            hasActiveVisibleSession: active
        )
    }

    func testFeatureOffReleasesRegardlessOfEverything() {
        XCTAssertFalse(decide(smart: true, manual: true, feature: false, active: true),
                       "feature off hides every control; holding would strand the user")
        XCTAssertFalse(decide(smart: false, manual: true, feature: false))
    }

    func testSmartWinsOverManual() {
        XCTAssertFalse(decide(smart: true, manual: true, active: false),
                       "smart on with no active run releases even if manual is stale-on")
        XCTAssertTrue(decide(smart: true, manual: false, active: true))
    }

    func testManualHonoredWhenSmartOff() {
        XCTAssertTrue(decide(smart: false, manual: true))
        XCTAssertTrue(decide(smart: false, manual: true, active: false),
                      "manual mode ignores session activity entirely")
    }

    func testAllOffReleases() {
        XCTAssertFalse(decide(smart: false, manual: false))
        XCTAssertFalse(decide(smart: false, manual: false, active: true),
                       "activity alone never holds without a mode enabled")
    }
}
