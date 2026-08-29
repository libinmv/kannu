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

    func testNoResetTimesAreReported() {
        // The desktop history records percentages only, so the gauge must show no countdown
        // rather than invent one.
        let snapshot = ClaudeDesktopUsageHistory.parse(json: ["samples": [
            sample(t: 1_788_027_991_573, ["fh": 38])
        ]])
        XCTAssertEqual(snapshot?.windows.first?.resetsAt, nil)
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
