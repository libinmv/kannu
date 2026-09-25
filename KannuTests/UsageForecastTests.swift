//
//  UsageForecastTests.swift
//  KannuTests
//
//  Copyright (C) 2026 Kannu contributors
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import XCTest

/// The pace-based forecast, the near-limit rule, one push per window instance, and "resumes at".
final class UsageForecastTests: XCTestCase {
    typealias F = UsageForecast
    typealias P = UsageAlertPolicy
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func reading(_ key: String = "five_hour", provider: String = "claude", percent: Double,
                         resetsIn: TimeInterval? = 3 * 3600, severity: String? = nil) -> UsageWindowReading {
        UsageWindowReading(provider: provider, key: key, label: "5-hour", percent: percent,
                           resetsAt: resetsIn.map { now.addingTimeInterval($0) }, severity: severity, observedAt: now)
    }

    /// Samples every `step` minutes ending at `now`, rising `perHour` percent per hour to `end`.
    private func series(end: Double, perHour: Double, count: Int, stepMinutes: Double, resetsIn: TimeInterval? = 3 * 3600) -> [F.Sample] {
        (0..<count).map { i in
            let minutesBefore = Double(count - 1 - i) * stepMinutes
            return F.Sample(at: now.addingTimeInterval(-minutesBefore * 60),
                            percent: end - perHour * minutesBefore / 60,
                            resetsAt: resetsIn.map { now.addingTimeInterval($0) })
        }
    }

    // MARK: - Outlook

    func testTooFewSamplesIsInsufficient() {
        XCTAssertEqual(F.outlook(series(end: 50, perHour: 10, count: 2, stepMinutes: 10), current: reading(percent: 50), now: now),
                       .insufficientData)
        XCTAssertEqual(F.outlook(series(end: 50, perHour: 10, count: 4, stepMinutes: 2), current: reading(percent: 50), now: now),
                       .insufficientData, "three samples over six minutes is not a pace yet")
    }

    func testFlatUsageIsSteady() {
        XCTAssertEqual(F.outlook(series(end: 40, perHour: 0, count: 6, stepMinutes: 10), current: reading(percent: 40), now: now),
                       .steady)
    }

    func testRisingUsageHitsTheLimitBeforeReset() {
        // 70 % now, rising 20 %/h: full in 1.5 h, reset in 3 h.
        let outlook = F.outlook(series(end: 70, perHour: 20, count: 6, stepMinutes: 10), current: reading(percent: 70), now: now)
        guard case .hitsLimit(let at) = outlook else { return XCTFail("\(outlook)") }
        XCTAssertEqual(at.timeIntervalSince(now), 1.5 * 3600, accuracy: 60)
    }

    func testRisingUsageLastsUntilResetWithProjection() {
        // 40 % now, rising 10 %/h, reset in 3 h: about 70 % at reset.
        let outlook = F.outlook(series(end: 40, perHour: 10, count: 6, stepMinutes: 10), current: reading(percent: 40), now: now)
        guard case .lastsUntilReset(let projected) = outlook else { return XCTFail("\(outlook)") }
        XCTAssertEqual(projected, 70, accuracy: 0.5)
    }

    func testAtLimit() {
        XCTAssertEqual(F.outlook([], current: reading(percent: 99.6), now: now), .atLimit)
    }

    func testLookbackIgnoresOldSamples() {
        // Old samples show a steep climb, the last 90 minutes are flat: the recent pace wins.
        var samples = series(end: 30, perHour: 60, count: 4, stepMinutes: 30).map {
            F.Sample(at: $0.at.addingTimeInterval(-3 * 3600), percent: $0.percent - 30, resetsAt: $0.resetsAt)
        }
        samples += series(end: 30, perHour: 0, count: 6, stepMinutes: 15)
        XCTAssertEqual(F.outlook(samples, current: reading(percent: 30), now: now), .steady)
    }

    func testNoResetCapsTheHorizon() {
        // A slow climb with no reported reset would be full in weeks: not a forecast.
        let slow = series(end: 10, perHour: 0.2, count: 6, stepMinutes: 60, resetsIn: nil)
        XCTAssertEqual(F.outlook(slow, current: reading("week", provider: "codex", percent: 10, resetsIn: nil), now: now), .steady)
    }

    // MARK: - Admission

    func testADropStartsANewSeries() {
        let before = series(end: 80, perHour: 10, count: 4, stepMinutes: 10)
        let next = F.Sample(at: now.addingTimeInterval(600), percent: 3, resetsAt: before.last?.resetsAt)
        XCTAssertEqual(F.admitting(next, to: before), [next])
    }

    func testResetChangeStartsANewSeries() {
        let before = series(end: 30, perHour: 10, count: 4, stepMinutes: 10)
        let next = F.Sample(at: now.addingTimeInterval(600), percent: 31, resetsAt: now.addingTimeInterval(8 * 3600))
        XCTAssertEqual(F.admitting(next, to: before), [next])
    }

    func testAdmissionThrottlesAndCaps() {
        let base = [F.Sample(at: now, percent: 10, resetsAt: nil)]
        XCTAssertEqual(F.admitting(F.Sample(at: now, percent: 12, resetsAt: nil), to: base), base, "the same observation twice")
        XCTAssertEqual(F.admitting(F.Sample(at: now.addingTimeInterval(60), percent: 12, resetsAt: nil), to: base), base, "too soon")
        let later = F.Sample(at: now.addingTimeInterval(180), percent: 12, resetsAt: nil)
        XCTAssertEqual(F.admitting(later, to: base), base + [later])
        var many: [F.Sample] = []
        for i in 0..<10 { many = F.admitting(F.Sample(at: now.addingTimeInterval(Double(i) * 200), percent: Double(i), resetsAt: nil), to: many, cap: 4) }
        XCTAssertEqual(many.count, 4)
        XCTAssertEqual(many.last?.percent, 9)
    }

    // MARK: - Captions

    func testCaptionOnlyWhenItMatters() {
        XCTAssertNil(F.caption(.steady, resetsAt: nil, now: now))
        XCTAssertNil(F.caption(.insufficientData, resetsAt: nil, now: now))
        XCTAssertNil(F.caption(.lastsUntilReset(projected: 60), resetsAt: nil, now: now), "nothing to say below 75 %")
        XCTAssertEqual(F.caption(.lastsUntilReset(projected: 88), resetsAt: nil, now: now)?.isWarning, false)
        XCTAssertEqual(F.caption(.hitsLimit(at: now.addingTimeInterval(3600)), resetsAt: nil, now: now)?.isWarning, true)
        XCTAssertEqual(F.caption(.atLimit, resetsAt: now.addingTimeInterval(3600), now: now)?.isWarning, true)
        XCTAssertTrue(F.caption(.hitsLimit(at: now.addingTimeInterval(3600)), resetsAt: nil, now: now)?.text.contains("full by") == true)
    }

    // MARK: - Alerts

    func testNearLimitUsesThresholdOrCriticalAndSkipsLapsed() {
        let readings = [
            reading("five_hour", percent: 96),
            reading("seven_day", percent: 50, severity: "critical"),
            reading("seven_day_opus", percent: 99, resetsIn: -60),
            reading("session", provider: "codex", percent: 94)
        ]
        XCTAssertEqual(P.nearLimit(readings, now: now).map(\.key), ["five_hour", "seven_day"])
    }

    func testPushKeyIsOncePerWindowInstance() {
        let a = reading(percent: 96, resetsIn: 3600)
        let b = reading(percent: 98, resetsIn: 3600)
        let next = reading(percent: 96, resetsIn: 3600 + 5 * 3600)
        XCTAssertEqual(P.pushKey(a), P.pushKey(b), "a rising percent in the same window is one push")
        XCTAssertNotEqual(P.pushKey(a), P.pushKey(next), "the next window cycle is a new one")
        let text = P.pushText(a, now: now)
        XCTAssertTrue(text.title.hasPrefix("Claude 5-hour limit at 96%"))
    }

    func testResumeDateOnlyWhenTheWindowIsFull() {
        let resetsIn: TimeInterval = 2 * 3600
        let full = [reading(percent: 99.6, resetsIn: resetsIn)]
        let half = [reading(percent: 60, resetsIn: resetsIn)]
        let rateLimited = RunError.apiError(status: 429)
        XCTAssertNil(P.resumeDate(provider: "claude", runError: rateLimited, rawState: "stopped", readings: half, now: now),
                     "a 429 below the limit may be short-term throttling")
        XCTAssertEqual(P.resumeDate(provider: "claude", runError: rateLimited, rawState: "stopped", readings: full, now: now),
                       now.addingTimeInterval(resetsIn))
        XCTAssertEqual(P.resumeDate(provider: "claudedesktop", runError: nil, rawState: "quota_exceeded",
                                    readings: [reading(percent: 70, resetsIn: resetsIn, severity: "critical")], now: now),
                       now.addingTimeInterval(resetsIn))
        XCTAssertNil(P.resumeDate(provider: "claude", runError: nil, rawState: "stopped", readings: full, now: now), "a clean stop")
        XCTAssertNil(P.resumeDate(provider: "codex", runError: rateLimited, rawState: "stopped", readings: full, now: now),
                     "another provider's window says nothing about this one")
    }

    func testClaudeReadingsCarryKeysAndLabels() {
        let snapshot = ClaudeUsageSnapshot(windows: [
            .init(key: "five_hour", percent: 42, resetsAt: now.addingTimeInterval(3600)),
            .init(key: "seven_day", percent: 10, resetsAt: now.addingTimeInterval(86_400)),
            .init(key: "model_scoped:fable", percent: 30, resetsAt: now.addingTimeInterval(86_400), label: "Fable"),
            .init(key: "lapsed", percent: 99, resetsAt: now.addingTimeInterval(-10))
        ], observedAt: now)
        let readings = UsageWindowReading.readings(fromClaude: snapshot, now: now)
        XCTAssertEqual(readings.map(\.id), ["claude:five_hour", "claude:seven_day", "claude:model_scoped:fable"])
        XCTAssertEqual(readings.map(\.label), ["5-hour", "weekly", "Fable weekly"])
        XCTAssertEqual(UsageWindowReading.label(provider: "cursor", key: "week"), "billing-cycle")
    }
}
