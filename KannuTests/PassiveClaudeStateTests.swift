import XCTest

final class PassiveClaudeStateTests: XCTestCase {
    private typealias Tail = AgentSessionLogParser.ClaudeTailResult

    private let now = Date(timeIntervalSince1970: 1_787_300_000)
    private let collapseMs: Int64 = 8_000
    private let inactiveMs: Int64 = 300_000

    private func resolve(
        tail: Tail,
        jsonlMtime: Date? = nil
    ) -> (rawState: String, state: AgentTrafficLightState, visible: Bool, updatedAtMs: Int64) {
        AgentTrafficLightMapper.passiveClaudeState(
            tail: tail,
            jsonlMtime: jsonlMtime,
            fallbackTsMs: Int64(now.timeIntervalSince1970 * 1000) - 60_000,
            now: now,
            collapseMs: collapseMs,
            inactiveMs: inactiveMs
        )
    }

    func testFreshWorkingIsThinking() {
        let tail = Tail(state: .working, recordTimestamp: now.addingTimeInterval(-120))
        let result = resolve(tail: tail)
        XCTAssertEqual(result.state, .thinking)
        XCTAssertTrue(result.visible)
    }

    func testStaleWorkingGoesInactive() {
        let tail = Tail(state: .working, recordTimestamp: now.addingTimeInterval(-660))
        let result = resolve(tail: tail, jsonlMtime: now.addingTimeInterval(-660))
        XCTAssertEqual(result.state, .inactive)
        XCTAssertEqual(result.rawState, "idle")
        XCTAssertTrue(result.visible)
    }

    func testStaleWorkingWithFreshMtimeStaysThinking() {
        // Bookkeeping or interim writes count as life signs for an owed response.
        let tail = Tail(state: .working, recordTimestamp: now.addingTimeInterval(-660))
        let result = resolve(tail: tail, jsonlMtime: now.addingTimeInterval(-30))
        XCTAssertEqual(result.state, .thinking)
    }

    func testWorkingWithNoEvidenceStaysThinking() {
        let tail = Tail(state: .working, recordTimestamp: nil)
        XCTAssertEqual(resolve(tail: tail, jsonlMtime: nil).state, .thinking)
    }

    func testLongToolRunStaysExecuting() {
        // 30 minutes into a tool with zero writes — must never age out.
        let tail = Tail(state: .toolInFlight, recordTimestamp: now.addingTimeInterval(-1800))
        let result = resolve(tail: tail, jsonlMtime: now.addingTimeInterval(-1800))
        XCTAssertEqual(result.state, .executing)
        XCTAssertTrue(result.visible)
    }

    func testFreshTurnFinishedIsStoppedAndVisible() {
        let tail = Tail(state: .turnFinished, recordTimestamp: now.addingTimeInterval(-2))
        let result = resolve(tail: tail)
        XCTAssertEqual(result.state, .stopped)
        XCTAssertTrue(result.visible)
        XCTAssertEqual(result.rawState, "stopped")
    }

    func testOldTurnFinishedIsDimNotRed() {
        // 20 minutes past the stop: past collapse+inactive, shown as a dim card.
        let tail = Tail(state: .turnFinished, recordTimestamp: now.addingTimeInterval(-1200))
        let result = resolve(tail: tail)
        XCTAssertEqual(result.state, .inactive)
        XCTAssertTrue(result.visible)
    }

    func testTurnFinishedAgesFromRecordNotMtime() {
        // Bookkeeping bumped mtime 3 s ago, but the stop happened 20 min ago — no red flash.
        let tail = Tail(state: .turnFinished, recordTimestamp: now.addingTimeInterval(-1200))
        let result = resolve(tail: tail, jsonlMtime: now.addingTimeInterval(-3))
        XCTAssertEqual(result.state, .inactive)
        // updatedAt must track the stop record so later writes cannot resurrect it.
        XCTAssertEqual(result.updatedAtMs, Int64(now.addingTimeInterval(-1200).timeIntervalSince1970 * 1000))
    }

    func testUnknownWithFreshMtimeIsThinking() {
        let result = resolve(tail: Tail(state: .unknown, recordTimestamp: nil), jsonlMtime: now.addingTimeInterval(-3))
        XCTAssertEqual(result.state, .thinking)
    }

    /// An unreadable tail on a live process must not dim the session: the reconciler's
    /// demote arm acts on passive verdicts, so `.inactive` here would drag a correctly-green
    /// session dark on a single torn read.
    func testUnknownWithQuietFileStaysThinking() {
        let result = resolve(tail: Tail(state: .unknown, recordTimestamp: nil), jsonlMtime: now.addingTimeInterval(-60))
        XCTAssertEqual(result.state, .thinking)
        XCTAssertEqual(result.rawState, "thinking")
        XCTAssertTrue(result.visible)
    }
}
