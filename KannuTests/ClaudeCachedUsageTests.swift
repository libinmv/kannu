import XCTest

final class ClaudeCachedUsageTests: XCTestCase {
    private let fetchedAtMs = 1_788_000_000_000.0

    private func config(
        limits: [[String: Any]] = [],
        fixed: [String: Any] = [:],
        accountUuid: String? = "acct-1",
        oauthUuid: String? = "acct-1"
    ) -> [String: Any] {
        var utilization: [String: Any] = fixed
        utilization["limits"] = limits
        var cache: [String: Any] = [
            "fetchedAtMs": NSNumber(value: fetchedAtMs),
            "utilization": utilization
        ]
        if let accountUuid { cache["accountUuid"] = accountUuid }
        var json: [String: Any] = ["cachedUsageUtilization": cache]
        if let oauthUuid { json["oauthAccount"] = ["accountUuid": oauthUuid] }
        return json
    }

    private func window(_ pct: Double, resets: String?) -> [String: Any] {
        var d: [String: Any] = ["utilization": NSNumber(value: pct)]
        if let resets { d["resets_at"] = resets }
        return d
    }

    private func scoped(_ name: String, _ pct: Double, kind: String = "weekly_scoped",
                        resets: String? = "2026-07-17T22:59:59.679456+00:00") -> [String: Any] {
        var d: [String: Any] = ["kind": kind, "group": "weekly", "percent": NSNumber(value: pct),
                                "scope": ["model": ["display_name": name]]]
        if let resets { d["resets_at"] = resets }
        return d
    }

    // MARK: - Per-model windows

    func testFableWeeklyIsItsOwnWindowWithItsOwnDenominator() {
        let snapshot = ClaudeCachedUsage.parse(json: config(
            limits: [scoped("Fable", 68)],
            fixed: ["seven_day": window(41, resets: "2026-09-02T12:09:00+00:00")]
        ))
        let fable = snapshot?.window("model_scoped:Fable")
        XCTAssertEqual(fable?.percent, 68)
        XCTAssertEqual(fable?.label, "Fable")
        // Explicitly not derived from the all-models weekly figure.
        XCTAssertEqual(snapshot?.window("seven_day")?.percent, 41)
        XCTAssertNotEqual(fable?.percent, snapshot?.window("seven_day")?.percent)
    }

    func testMicrosecondPrecisionResetParses() {
        // The timestamps carry microseconds; ISO8601DateFormatter resolves to milliseconds, which is
        // far finer than a countdown needs. Assert to the millisecond rather than demanding equality.
        let snapshot = ClaudeCachedUsage.parse(json: config(limits: [scoped("Fable", 68)]))
        let resets = snapshot?.window("model_scoped:Fable")?.resetsAt
        XCTAssertNotNil(resets)
        XCTAssertEqual(resets?.timeIntervalSince1970 ?? 0, 1_784_329_199.679456, accuracy: 0.001)
    }

    func testResetWithoutFractionalSecondsParses() {
        let snapshot = ClaudeCachedUsage.parse(json: config(
            limits: [scoped("Fable", 68, resets: "2026-09-02T12:09:00+00:00")]))
        XCTAssertEqual(snapshot?.window("model_scoped:Fable")?.resetsAt,
                       Date(timeIntervalSince1970: 1_788_350_940))
    }

    func testUnparseableResetYieldsNilRatherThanAWrongDate() {
        let snapshot = ClaudeCachedUsage.parse(json: config(
            limits: [scoped("Fable", 68, resets: "not-a-date")]))
        XCTAssertEqual(snapshot?.window("model_scoped:Fable")?.percent, 68)
        XCTAssertNil(snapshot?.window("model_scoped:Fable")?.resetsAt)
    }

    func testNonScopedKindsAreIgnored() {
        // The plain "weekly" entry duplicates seven_day; only weekly_scoped entries are per-model.
        let snapshot = ClaudeCachedUsage.parse(json: config(
            limits: [scoped("Fable", 41, kind: "weekly"), scoped("Fable", 68)]))
        XCTAssertEqual(snapshot?.windows.filter { $0.key.hasPrefix("model_scoped:") }.count, 1)
        XCTAssertEqual(snapshot?.window("model_scoped:Fable")?.percent, 68)
    }

    func testEntryWithoutAModelNameIsIgnored() {
        var noModel = scoped("Fable", 68)
        noModel["scope"] = ["model": ["display_name": ""]]
        XCTAssertNil(ClaudeCachedUsage.parse(json: config(limits: [noModel])))
    }

    func testEveryScopedModelIsCarried() {
        let snapshot = ClaudeCachedUsage.parse(json: config(
            limits: [scoped("Fable", 68), scoped("Haiku", 12)]))
        XCTAssertEqual(snapshot?.windows.map(\.key).filter { $0.hasPrefix("model_scoped:") },
                       ["model_scoped:Fable", "model_scoped:Haiku"])
    }

    // MARK: - Fixed windows

    func testFixedWindowsUseUtilizationNotUsedPercentage() {
        let snapshot = ClaudeCachedUsage.parse(json: config(fixed: [
            "five_hour": window(32, resets: "2026-08-30T18:27:00+00:00"),
            "seven_day": ["used_percentage": NSNumber(value: 99)]   // wrong field: must be ignored
        ]))
        XCTAssertEqual(snapshot?.fiveHourPercent, 32)
        XCTAssertNil(snapshot?.sevenDayPercent)
    }

    func testObservedAtComesFromFetchedAt() {
        let snapshot = ClaudeCachedUsage.parse(json: config(limits: [scoped("Fable", 68)]))
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: fetchedAtMs / 1000))
    }

    // MARK: - Rejection

    func testCacheForAnotherAccountIsRejected() {
        XCTAssertNil(ClaudeCachedUsage.parse(json: config(
            limits: [scoped("Fable", 68)], accountUuid: "acct-1", oauthUuid: "acct-2")))
    }

    func testMissingKeyOrEmptyPayloadReturnsNil() {
        XCTAssertNil(ClaudeCachedUsage.parse(json: [:]))
        XCTAssertNil(ClaudeCachedUsage.parse(json: ["cachedUsageUtilization": [:]]))
        XCTAssertNil(ClaudeCachedUsage.parse(json: config()))
        XCTAssertNil(ClaudeCachedUsage.load(from: URL(fileURLWithPath: "/nonexistent/.claude.json")))
    }

    func testZeroFetchedAtIsRejected() {
        var json = config(limits: [scoped("Fable", 68)])
        var cache = json["cachedUsageUtilization"] as! [String: Any]
        cache["fetchedAtMs"] = NSNumber(value: 0)
        json["cachedUsageUtilization"] = cache
        XCTAssertNil(ClaudeCachedUsage.parse(json: json))
    }
}
