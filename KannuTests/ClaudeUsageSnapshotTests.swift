import XCTest

final class ClaudeUsageSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func makeJSON(
        tsMs: Int64,
        fiveHourPct: Double? = nil,
        fiveHourResetsAt: Double? = nil,
        sevenDayPct: Double? = nil,
        sevenDayResetsAt: Double? = nil
    ) -> [String: Any] {
        var json: [String: Any] = ["ts": NSNumber(value: tsMs)]
        if let fiveHourPct { json["five_hour_pct"] = NSNumber(value: fiveHourPct) }
        if let fiveHourResetsAt { json["five_hour_resets_at"] = NSNumber(value: fiveHourResetsAt) }
        if let sevenDayPct { json["seven_day_pct"] = NSNumber(value: sevenDayPct) }
        if let sevenDayResetsAt { json["seven_day_resets_at"] = NSNumber(value: sevenDayResetsAt) }
        return json
    }

    private func makeWindowJSON(tsMs: Int64, _ windows: [[String: Any]]) -> [String: Any] {
        ["ts": NSNumber(value: tsMs), "windows": windows]
    }

    private func makeSnapshot(
        fiveHour: (pct: Double, resetsAt: Date?)? = nil,
        sevenDay: (pct: Double, resetsAt: Date?)? = nil,
        extra: [ClaudeUsageSnapshot.Window] = [],
        observedAt: Date
    ) -> ClaudeUsageSnapshot {
        var windows: [ClaudeUsageSnapshot.Window] = []
        if let fiveHour {
            windows.append(.init(key: ClaudeUsageSnapshot.fiveHourKey,
                                 percent: fiveHour.pct, resetsAt: fiveHour.resetsAt))
        }
        if let sevenDay {
            windows.append(.init(key: ClaudeUsageSnapshot.sevenDayKey,
                                 percent: sevenDay.pct, resetsAt: sevenDay.resetsAt))
        }
        return ClaudeUsageSnapshot(windows: windows + extra, observedAt: observedAt)
    }

    // MARK: - Legacy flat shape

    func testParsesAllFields() {
        let snapshot = ClaudeUsageSnapshot.parse(json: makeJSON(
            tsMs: 1_788_000_000_000,
            fiveHourPct: 41.5, fiveHourResetsAt: 1_788_010_000,
            sevenDayPct: 72.3, sevenDayResetsAt: 1_788_345_600
        ))
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.fiveHourPercent, 41.5)
        XCTAssertEqual(snapshot?.sevenDayPercent, 72.3)
        XCTAssertEqual(snapshot?.fiveHourResetsAt, Date(timeIntervalSince1970: 1_788_010_000))
        XCTAssertEqual(snapshot?.observedAt, Date(timeIntervalSince1970: 1_788_000_000))
    }

    func testParsesPartialWindows() {
        let snapshot = ClaudeUsageSnapshot.parse(json: makeJSON(tsMs: 1_788_000_000_000, sevenDayPct: 50))
        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.fiveHourPercent)
        XCTAssertEqual(snapshot?.sevenDayPercent, 50)
    }

    func testRejectsEmptyOrMissingTs() {
        XCTAssertNil(ClaudeUsageSnapshot.parse(json: makeJSON(tsMs: 1_788_000_000_000)))
        XCTAssertNil(ClaudeUsageSnapshot.parse(json: ["five_hour_pct": NSNumber(value: 10)]))
        XCTAssertNil(ClaudeUsageSnapshot.parse(json: [:]))
    }

    // MARK: - Open-ended window list

    func testParsesWindowListIncludingUnknownKeys() {
        let snapshot = ClaudeUsageSnapshot.parse(json: makeWindowJSON(tsMs: 1_788_000_000_000, [
            ["key": "five_hour", "pct": NSNumber(value: 17.5), "resets_at": NSNumber(value: 1_788_010_000)],
            ["key": "seven_day", "pct": NSNumber(value: 63.25)],
            ["key": "seven_day_opus", "pct": NSNumber(value: 88)]
        ]))
        XCTAssertEqual(snapshot?.windows.count, 3)
        XCTAssertEqual(snapshot?.fiveHourPercent, 17.5)
        // An unrecognised window must survive parsing — the display decides what to do with it.
        XCTAssertEqual(snapshot?.window("seven_day_opus")?.percent, 88)
        XCTAssertNil(snapshot?.window("seven_day_opus")?.resetsAt)
    }

    func testWindowListSkipsMalformedEntriesAndKeepsOrder() {
        let snapshot = ClaudeUsageSnapshot.parse(json: makeWindowJSON(tsMs: 1_788_000_000_000, [
            ["key": "seven_day_cowork", "pct": NSNumber(value: 12)],
            ["key": "", "pct": NSNumber(value: 5)],
            ["pct": NSNumber(value: 9)],
            ["key": "seven_day_sonnet"],
            ["key": "seven_day_opus", "pct": NSNumber(value: 30)]
        ]))
        XCTAssertEqual(snapshot?.windows.map(\.key), ["seven_day_cowork", "seven_day_opus"])
    }

    func testWindowListShapeWinsOverLegacyFields() {
        var json = makeWindowJSON(tsMs: 1_788_000_000_000, [
            ["key": "five_hour", "pct": NSNumber(value: 20)]
        ])
        json["five_hour_pct"] = NSNumber(value: 99)
        XCTAssertEqual(ClaudeUsageSnapshot.parse(json: json)?.fiveHourPercent, 20)
    }

    func testDisplayOrderPutsKnownWindowsFirst() {
        let snapshot = ClaudeUsageSnapshot(windows: [
            .init(key: "seven_day_opus", percent: 88, resetsAt: nil),
            .init(key: "seven_day", percent: 63, resetsAt: nil),
            .init(key: "seven_day_sonnet", percent: 10, resetsAt: nil),
            .init(key: "five_hour", percent: 17, resetsAt: nil)
        ], observedAt: now)
        XCTAssertEqual(snapshot.displayWindows(now: now).map(\.key),
                       ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])
    }

    // MARK: - Per-model windows

    func testModelScopedWindowKeepsItsServerLabel() {
        // Per-model weekly windows are named by the server, not by a key we could recognise.
        let snapshot = ClaudeUsageSnapshot.parse(json: makeWindowJSON(tsMs: 1_788_000_000_000, [
            ["key": "five_hour", "pct": NSNumber(value: 9)],
            ["key": "seven_day", "pct": NSNumber(value: 63)],
            ["key": "model_scoped:Fable", "label": "Fable", "pct": NSNumber(value: 89),
             "resets_at": NSNumber(value: 1_788_359_400)]
        ]))
        let fable = snapshot?.window("model_scoped:Fable")
        XCTAssertEqual(fable?.percent, 89)
        XCTAssertEqual(fable?.label, "Fable")
        XCTAssertEqual(fable?.resetsAt, Date(timeIntervalSince1970: 1_788_359_400))
        // It sorts after the two universal windows, never before them.
        XCTAssertEqual(snapshot?.displayWindows(now: now).map(\.key),
                       ["five_hour", "seven_day", "model_scoped:Fable"])
    }

    func testLabelIsNilWhenAbsentOrEmpty() {
        let snapshot = ClaudeUsageSnapshot.parse(json: makeWindowJSON(tsMs: 1_788_000_000_000, [
            ["key": "five_hour", "pct": NSNumber(value: 9)],
            ["key": "model_scoped:Blank", "label": "", "pct": NSNumber(value: 12)]
        ]))
        XCTAssertNil(snapshot?.window("five_hour")?.label)
        XCTAssertNil(snapshot?.window("model_scoped:Blank")?.label)
    }

    func testExpiredModelScopedWindowIsHidden() {
        let snapshot = ClaudeUsageSnapshot(windows: [
            .init(key: "five_hour", percent: 9, resetsAt: now.addingTimeInterval(600)),
            .init(key: "model_scoped:Fable", percent: 89,
                  resetsAt: now.addingTimeInterval(-1), label: "Fable")
        ], observedAt: now)
        XCTAssertEqual(snapshot.displayWindows(now: now).map(\.key), ["five_hour"])
        XCTAssertFalse(snapshot.isEmpty(now: now))
    }

    // MARK: - Staleness

    func testFreshnessBoundary() {
        let fresh = makeSnapshot(fiveHour: (10, nil), observedAt: now.addingTimeInterval(-599))
        XCTAssertEqual(fresh.freshness(now: now), .fresh)
        let aged = makeSnapshot(fiveHour: (10, nil), observedAt: now.addingTimeInterval(-601))
        XCTAssertEqual(aged.freshness(now: now), .aged)
    }

    func testExpiredWindowHidden() {
        // 5h reset already passed: its percentage is stale fiction, must not show.
        let snapshot = makeSnapshot(
            fiveHour: (88, now.addingTimeInterval(-60)),
            sevenDay: (40, now.addingTimeInterval(86_400)),
            observedAt: now.addingTimeInterval(-3600))
        XCTAssertNil(snapshot.fiveHourDisplayPercent(now: now))
        XCTAssertEqual(snapshot.sevenDayDisplayPercent(now: now), 40)
        XCTAssertFalse(snapshot.isEmpty(now: now))
    }

    func testExpiredExtraWindowHidden() {
        let snapshot = ClaudeUsageSnapshot(windows: [
            .init(key: "seven_day_opus", percent: 88, resetsAt: now.addingTimeInterval(-1))
        ], observedAt: now)
        XCTAssertTrue(snapshot.displayWindows(now: now).isEmpty)
        XCTAssertTrue(snapshot.isEmpty(now: now))
    }

    func testAllWindowsExpiredIsEmpty() {
        let snapshot = makeSnapshot(
            fiveHour: (88, now.addingTimeInterval(-60)),
            sevenDay: (40, now.addingTimeInterval(-30)),
            observedAt: now.addingTimeInterval(-7200))
        XCTAssertTrue(snapshot.isEmpty(now: now))
    }

    func testWindowWithoutResetStaysVisible() {
        let snapshot = makeSnapshot(fiveHour: (25, nil), observedAt: now)
        XCTAssertEqual(snapshot.fiveHourDisplayPercent(now: now), 25)
    }

    // MARK: - Refresh cadence

    func testFirstReadHappensEvenWhenIdle() {
        // Opening the usage card cold must show something, so the very first read is unconditional.
        XCTAssertTrue(ClaudeUsageSnapshot.shouldRefresh(
            now: now, lastRead: nil, state: .inactive, hasSnapshot: false))
    }

    func testRetriesWhileNothingHasBeenParsedYet() {
        // A read that found no usable file leaves no snapshot; keep trying rather than latching off.
        XCTAssertTrue(ClaudeUsageSnapshot.shouldRefresh(
            now: now, lastRead: now.addingTimeInterval(-1), state: .inactive, hasSnapshot: false))
    }

    func testDoesNotRefreshWhileNoAgentIsOnScreen() {
        XCTAssertFalse(ClaudeUsageSnapshot.shouldRefresh(
            now: now, lastRead: now.addingTimeInterval(-86_400), state: .inactive, hasSnapshot: true))
    }

    func testRefreshIntervalBoundaryWhileActive() {
        for state in [AgentTrafficLightState.executing, .thinking, .awaitingInput, .stopped] {
            XCTAssertFalse(ClaudeUsageSnapshot.shouldRefresh(
                now: now, lastRead: now.addingTimeInterval(-599), state: state, hasSnapshot: true),
                "\(state) should not re-read before the interval elapses")
            XCTAssertTrue(ClaudeUsageSnapshot.shouldRefresh(
                now: now, lastRead: now.addingTimeInterval(-600), state: state, hasSnapshot: true),
                "\(state) should re-read once the interval elapses")
        }
    }

    // MARK: - Merging sources

    private func window(_ key: String, pct: Double, resetsIn seconds: TimeInterval?, label: String? = nil,
                        severity: String? = nil) -> ClaudeUsageSnapshot.Window {
        .init(key: key, percent: pct, resetsAt: seconds.map { now.addingTimeInterval($0) },
              label: label, severity: severity)
    }

    func testMergeFillsLapsedKeyFromLowerSourceAndKeepsHigherLiveSiblings() {
        let higher = ClaudeUsageSnapshot(windows: [
            window("five_hour", pct: 61, resetsIn: -60),
            window("model_scoped:Fable", pct: 95, resetsIn: 3_600, label: "Fable", severity: "critical")
        ], observedAt: now.addingTimeInterval(-100))
        let lower = ClaudeUsageSnapshot(windows: [
            window("five_hour", pct: 25, resetsIn: 600)
        ], observedAt: now.addingTimeInterval(-50))

        let merged = ClaudeUsageSnapshot.merged([higher, lower], now: now)
        XCTAssertEqual(merged?.windows.map(\.key), ["model_scoped:Fable", "five_hour"])
        XCTAssertEqual(merged?.window("five_hour")?.percent, 25, "the lapsed higher copy must yield to the live lower one")
        XCTAssertEqual(merged?.window("five_hour")?.resetsAt, now.addingTimeInterval(600))
        XCTAssertEqual(merged?.window("model_scoped:Fable")?.severity, "critical")
    }

    func testMergeUsesLowerSourceWhenHigherIsEntirelyLapsed() {
        let higher = ClaudeUsageSnapshot(windows: [
            window("five_hour", pct: 61, resetsIn: -60),
            window("seven_day", pct: 80, resetsIn: -30)
        ], observedAt: now)
        let lower = ClaudeUsageSnapshot(windows: [
            window("five_hour", pct: 25, resetsIn: 600),
            window("seven_day", pct: 13, resetsIn: 6_000)
        ], observedAt: now.addingTimeInterval(-10))

        let merged = ClaudeUsageSnapshot.merged([higher, lower], now: now)
        XCTAssertEqual(merged?.fiveHourPercent, 25)
        XCTAssertEqual(merged?.sevenDayPercent, 13)
    }

    func testMergePrefersHigherSourceForAKeyLiveInBoth() {
        let higher = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 40, resetsIn: 300)], observedAt: now)
        let lower = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 45, resetsIn: 900)], observedAt: now)

        let merged = ClaudeUsageSnapshot.merged([higher, lower], now: now)
        XCTAssertEqual(merged?.windows.count, 1)
        XCTAssertEqual(merged?.fiveHourPercent, 40)
        XCTAssertEqual(merged?.fiveHourResetsAt, now.addingTimeInterval(300))
    }

    func testMergeIsNilWhenNothingIsLiveAnywhere() {
        let lapsed = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 61, resetsIn: -1)], observedAt: now)
        XCTAssertNil(ClaudeUsageSnapshot.merged([nil, lapsed, nil], now: now))
        XCTAssertNil(ClaudeUsageSnapshot.merged([], now: now))
    }

    func testMergeOfIdenticalInputsIsEqual() {
        let a = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 40, resetsIn: 300)], observedAt: now)
        let b = ClaudeUsageSnapshot(windows: [window("seven_day", pct: 10, resetsIn: 3_000)], observedAt: now.addingTimeInterval(-5))
        XCTAssertEqual(ClaudeUsageSnapshot.merged([a, b], now: now), ClaudeUsageSnapshot.merged([a, b], now: now))
    }

    func testMergeNilResetFillsOnlyAMissingKey() {
        let nilReset = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 100, resetsIn: nil)], observedAt: now)

        let liveHigher = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 40, resetsIn: 300)], observedAt: now)
        XCTAssertEqual(ClaudeUsageSnapshot.merged([liveHigher, nilReset], now: now)?.fiveHourPercent, 40)

        let lapsedHigher = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 40, resetsIn: -300)], observedAt: now)
        XCTAssertEqual(ClaudeUsageSnapshot.merged([lapsedHigher, nilReset], now: now)?.fiveHourPercent, 100)
    }

    func testMergeObservedAtIsNewestContributingSource() {
        let older = ClaudeUsageSnapshot(windows: [window("five_hour", pct: 40, resetsIn: 300)], observedAt: now.addingTimeInterval(-500))
        let newerLapsed = ClaudeUsageSnapshot(windows: [window("seven_day", pct: 80, resetsIn: -1)], observedAt: now)
        XCTAssertEqual(ClaudeUsageSnapshot.merged([older, newerLapsed], now: now)?.observedAt, now.addingTimeInterval(-500),
                       "a source that contributed nothing must not advertise freshness")

        let newerLive = ClaudeUsageSnapshot(windows: [window("seven_day", pct: 80, resetsIn: 100)], observedAt: now)
        XCTAssertEqual(ClaudeUsageSnapshot.merged([older, newerLive], now: now)?.observedAt, now)
    }
}
