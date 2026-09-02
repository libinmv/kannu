import XCTest

final class ClaudeDesktopUsageHistoryTests: XCTestCase {
    private func sample(t: Double, _ usage: [String: Double]) -> [String: Any] {
        ["t": NSNumber(value: t), "org": "org-uuid",
         "u": usage.mapValues { NSNumber(value: $0) }]
    }

    func testUsesNewestSampleRegardlessOfPosition() {
        let snapshot = ClaudeDesktopUsageHistory.parse(json: ["version": 2, "samples": [
            sample(t: 1_788_027_991_573, ["fh": 38, "sd": 61]),
            sample(t: 1_788_000_000_000, ["fh": 4, "sd": 12])
        ]])
        XCTAssertEqual(snapshot?.fiveHourPercent, 38)
        XCTAssertEqual(snapshot?.sevenDayPercent, 61)
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: 1_788_027_991.573))
    }

    func testMapsShortCodesToWindowKeysInDisplayOrder() {
        let snapshot = ClaudeDesktopUsageHistory.parse(json: ["samples": [
            sample(t: 1_788_027_991_573, ["sn": 10, "sd": 61, "so": 88, "fh": 38])
        ]])
        XCTAssertEqual(snapshot?.windows.map(\.key),
                       ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])
    }

    func testExtraUsageCreditsAreNotAWindow() {
        // `xu` tracks extra-usage spend, not a rate limit; rendering it as a gauge would be a lie.
        let snapshot = ClaudeDesktopUsageHistory.parse(json: ["samples": [
            sample(t: 1_788_027_991_573, ["fh": 38, "xu": 5])
        ]])
        XCTAssertEqual(snapshot?.windows.map(\.key), ["five_hour"])
    }

    // MARK: - Reset times derived from rollovers

    /// Fixed clock so the future-only rule is deterministic: 2026-08-30 08:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_788_076_800)

    private func series(_ points: [(mins: Double, fh: Double?, sd: Double?)]) -> [String: Any] {
        let base = 1_788_076_800_000.0
        return ["samples": points.map { p -> [String: Any] in
            var u: [String: Double] = [:]
            if let fh = p.fh { u["fh"] = fh }
            if let sd = p.sd { u["sd"] = sd }
            return ["t": NSNumber(value: base + p.mins * 60_000),
                    "u": u.mapValues { NSNumber(value: $0) }]
        }]
    }

    func testFiveHourResetIsFiveHoursAfterTheRollover() {
        // Drops 40 -> 7 at t-60min, so the running window ends 5h after that point.
        let snapshot = ClaudeDesktopUsageHistory.parse(json: series([
            (-120, 30, 50), (-90, 40, 51), (-60, 7, 51), (-30, 9, 52)
        ]), now: now)
        XCTAssertEqual(snapshot?.window("five_hour")?.resetsAt,
                       now.addingTimeInterval(-60 * 60 + 5 * 3600))
    }

    func testWeeklyResetIsSevenDaysAfterTheRollover() {
        let snapshot = ClaudeDesktopUsageHistory.parse(json: series([
            (-120, 10, 82), (-90, 12, 0), (-30, 14, 3)
        ]), now: now)
        XCTAssertEqual(snapshot?.window("seven_day")?.resetsAt,
                       now.addingTimeInterval(-90 * 60 + 7 * 24 * 3600))
    }

    func testSmallDecayIsNotTreatedAsARollover() {
        // A rolling window sheds a point or two as old usage ages out; that is not a reset, so the
        // earlier real rollover must remain the anchor.
        let snapshot = ClaudeDesktopUsageHistory.parse(json: series([
            (-120, 40, 50), (-90, 6, 50), (-60, 17, 50), (-30, 14, 50)
        ]), now: now)
        XCTAssertEqual(snapshot?.window("five_hour")?.resetsAt,
                       now.addingTimeInterval(-90 * 60 + 5 * 3600))
    }

    func testAnyDecreaseLandingOnZeroIsARollover() {
        // 4 -> 0 is a two-point drop but unmistakably a reset.
        let snapshot = ClaudeDesktopUsageHistory.parse(json: series([
            (-120, 30, 50), (-90, 4, 50), (-45, 0, 50), (-30, 2, 50)
        ]), now: now)
        XCTAssertEqual(snapshot?.window("five_hour")?.resetsAt,
                       now.addingTimeInterval(-45 * 60 + 5 * 3600))
    }

    func testResetAlreadyPastIsDroppedAndTheWindowSurvives() {
        // A stale history would otherwise put the reset behind us, and a past reset hides the
        // window entirely. No countdown is the correct degradation, not a vanished bar.
        let snapshot = ClaudeDesktopUsageHistory.parse(json: series([
            (-600, 40, 50), (-540, 3, 50)
        ]), now: now)
        XCTAssertNil(snapshot?.window("five_hour")?.resetsAt)
        XCTAssertEqual(snapshot?.window("five_hour")?.percent, 3)
        XCTAssertFalse(snapshot?.isEmpty(now: now) ?? true)
    }

    func testNoRolloverMeansNoResetButStillReportsPercentages() {
        let snapshot = ClaudeDesktopUsageHistory.parse(json: series([
            (-120, 10, 50), (-60, 20, 51), (-30, 38, 52)
        ]), now: now)
        XCTAssertNil(snapshot?.window("five_hour")?.resetsAt)
        XCTAssertEqual(snapshot?.window("five_hour")?.percent, 38)
        XCTAssertEqual(snapshot?.window("seven_day")?.percent, 52)
    }

    func testRejectsUnusableInput() {
        XCTAssertNil(ClaudeDesktopUsageHistory.parse(json: [:]))
        XCTAssertNil(ClaudeDesktopUsageHistory.parse(json: ["samples": []]))
        XCTAssertNil(ClaudeDesktopUsageHistory.parse(json: ["samples": "not-a-list"]))
        // A sample carrying only unmapped codes yields nothing to show.
        XCTAssertNil(ClaudeDesktopUsageHistory.parse(json: ["samples": [
            sample(t: 1_788_027_991_573, ["xu": 5])
        ]]))
        // Missing or zero timestamps cannot be aged, so they are not usable.
        XCTAssertNil(ClaudeDesktopUsageHistory.parse(json: ["samples": [
            ["u": ["fh": NSNumber(value: 38)]]
        ]]))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(ClaudeDesktopUsageHistory.load(
            from: URL(fileURLWithPath: "/nonexistent/plan-usage-history.json")))
    }
}
