import XCTest

/// Pins the local 5-hour block reconstruction that backs the "Session (local)" row.
final class ClaudeSessionBlocksTests: XCTestCase {
    private func date(_ hour: Double) -> Date {
        // Hours after an arbitrary hour-aligned epoch, so flooring math is easy to reason about.
        Date(timeIntervalSince1970: 1_800_000_000 + hour * 3600)
    }

    func testSingleBlockAnchorsAtFlooredFirstRecord() {
        let block = ClaudeSessionBlocks.currentBlock(
            records: [(date(0.5), 100), (date(1.0), 200)],
            now: date(2)
        )
        XCTAssertEqual(block?.startedAt, date(0), "anchor floors the first record to the hour")
        XCTAssertEqual(block?.resetsAt, date(5))
        XCTAssertEqual(block?.totalTokens, 300)
    }

    func testGapBeyondFiveHoursStartsANewBlock() {
        let block = ClaudeSessionBlocks.currentBlock(
            records: [(date(0.2), 1_000), (date(6.5), 50)],
            now: date(7)
        )
        XCTAssertEqual(block?.startedAt, date(6), "old block expired; new one anchors at 6:00")
        XCTAssertEqual(block?.totalTokens, 50, "expired block's tokens must not leak in")
        XCTAssertEqual(block?.resetsAt, date(11))
    }

    func testRecordInsideWindowExtendsTheSameBlock() {
        let block = ClaudeSessionBlocks.currentBlock(
            records: [(date(0.1), 10), (date(4.9), 20)],
            now: date(4.95)
        )
        XCTAssertEqual(block?.startedAt, date(0))
        XCTAssertEqual(block?.totalTokens, 30)
    }

    func testExpiredLatestBlockReturnsNil() {
        let block = ClaudeSessionBlocks.currentBlock(
            records: [(date(0.5), 100)],
            now: date(6)
        )
        XCTAssertNil(block, "no active block once the latest window has fully elapsed")
    }

    func testBurnRateIsTokensPerMinuteOverTheBlock() {
        // 600 tokens, block anchored at hour 0, now = 60 minutes in.
        let block = ClaudeSessionBlocks.currentBlock(
            records: [(date(0.0), 600)],
            now: date(1)
        )
        XCTAssertEqual(block?.burnRatePerMinute ?? 0, 10, accuracy: 0.01)
    }

    func testFutureRecordsAreIgnored() {
        let block = ClaudeSessionBlocks.currentBlock(
            records: [(date(0.5), 100), (date(3), 999)],
            now: date(1)
        )
        XCTAssertEqual(block?.totalTokens, 100, "records after `now` must not count")
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(ClaudeSessionBlocks.currentBlock(records: [], now: date(0)))
    }
}
