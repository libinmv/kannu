//
//  TaskTimeMathTests.swift
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

/// Actual time on a task: what counts, what an estimate leaves, and the quarter-hour rounding a
/// log entry uses.
final class TaskTimeMathTests: XCTestCase {
    typealias Math = TaskTimeMath
    private let nine = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(minutes: Double) -> Date { nine.addingTimeInterval(minutes * 60) }

    func testTrackedTimeIsClosedSegmentsPlusTheLiveOne() {
        let segments = [
            WorkSegment(start: at(minutes: 0), end: at(minutes: 30), origin: .timer),
            WorkSegment(start: at(minutes: 40), end: at(minutes: 50), origin: .manual),
            WorkSegment(start: at(minutes: 60), origin: .timer),
        ]
        XCTAssertEqual(Math.trackedSeconds(segments, now: at(minutes: 75)), (30 + 10 + 15) * 60)
    }

    func testAnInterruptedSegmentCountsForNothingUntilItsEndIsSet() {
        var segment = WorkSegment(start: at(minutes: 0), origin: .recovered)
        XCTAssertEqual(Math.trackedSeconds([segment], now: at(minutes: 600)), 0)
        segment.end = at(minutes: 45)
        XCTAssertEqual(Math.trackedSeconds([segment], now: at(minutes: 600)), 45 * 60)
    }

    func testOvertimeCountsLikeAnyOtherTime() {
        // A 2h estimate, timed for 2h10m: the timer's overtime is still work.
        let segments = [WorkSegment(start: at(minutes: 0), end: at(minutes: 130), origin: .timer)]
        let tracked = Math.trackedSeconds(segments, now: at(minutes: 200))
        XCTAssertEqual(tracked, 130 * 60)
        XCTAssertEqual(Math.overtimeSeconds(estimate: 7200, tracked: tracked), 10 * 60)
        XCTAssertEqual(Math.remainingSeconds(estimate: 7200, tracked: tracked), -10 * 60)
        XCTAssertEqual(Math.overtimeSeconds(estimate: 7200, tracked: 3600), 0)
        XCTAssertEqual(Math.overtimeSeconds(estimate: nil, tracked: 99_999), 0, "no estimate, no overtime")
    }

    func testASessionRunsForWhatIsLeftOfTheEstimateOrTheDefault() {
        XCTAssertEqual(Math.sessionLengthSeconds(estimate: 7200, tracked: 42 * 60, defaultMinutes: 25), 78 * 60)
        XCTAssertEqual(Math.sessionLengthSeconds(estimate: nil, tracked: 0, defaultMinutes: 25), 25 * 60)
        XCTAssertEqual(Math.sessionLengthSeconds(estimate: 3600, tracked: 3600, defaultMinutes: 25), 25 * 60,
                       "an estimate used up falls back to the default")
        XCTAssertEqual(Math.sessionLengthSeconds(estimate: 3600, tracked: 5000, defaultMinutes: 25), 25 * 60)
    }

    func testSleepSplitsTheTimeAndTheNightIsNotCounted() {
        // Timed from 9:00, the Mac sleeps at 9:30 and wakes at 10:00, stopped at 10:20.
        var segments = Math.opening([], at: at(minutes: 0))
        segments = Math.closing(segments, at: at(minutes: 30))     // willSleep
        segments = Math.opening(segments, at: at(minutes: 60))     // didWake
        segments = Math.closing(segments, at: at(minutes: 80))     // stop
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(Math.trackedSeconds(segments, now: at(minutes: 500)), 50 * 60)
        XCTAssertFalse(segments.contains(where: \.isLive))
    }

    func testOpeningAndClosingAreIdempotent() {
        let open = Math.opening([], at: at(minutes: 0))
        XCTAssertEqual(Math.opening(open, at: at(minutes: 5)), open, "a second open records nothing twice")
        let closed = Math.closing(open, at: at(minutes: 10))
        XCTAssertEqual(Math.closing(closed, at: at(minutes: 20)), closed, "a pause then a stop closes once")
    }

    func testAnEmptySegmentIsDroppedAndAnEndNeverPrecedesTheStart() {
        let open = Math.opening([], at: at(minutes: 10))
        XCTAssertEqual(Math.closing(open, at: at(minutes: 10)), [], "nothing recorded, nothing kept")
        XCTAssertEqual(Math.closing(open, at: at(minutes: 5)), [], "a clock that went back records nothing")
    }

    func testAnInterruptedSegmentIsNeitherClosedNorReopenedByTheTimer() {
        let interrupted = [WorkSegment(start: at(minutes: 0), origin: .recovered)]
        XCTAssertEqual(Math.closing(interrupted, at: at(minutes: 30)), interrupted)
        XCTAssertEqual(Math.opening(interrupted, at: at(minutes: 30)).count, 2, "a new live segment beside it")
    }

    // MARK: - Rounding to the nearest quarter hour

    func testRoundingAtTheQuarterHourBoundaries() {
        let cases: [(seconds: Int, rounded: Int, label: String)] = [
            (0, 0, "nothing"),
            (59, 0, "under a minute"),
            (7 * 60 + 29, 0, "7m29s rounds to 0 and carries over"),
            (7 * 60 + 30, 15 * 60, "7m30s is the first quarter hour"),
            (15 * 60, 15 * 60, "exactly 15m"),
            (22 * 60 + 29, 15 * 60, "22m29s"),
            (22 * 60 + 30, 30 * 60, "22m30s rounds up"),
            (37 * 60 + 29, 30 * 60, "37m29s"),
            (37 * 60 + 30, 45 * 60, "37m30s"),
            (52 * 60 + 30, 60 * 60, "52m30s is an hour"),
            (72 * 60, 75 * 60, "1h 12m is 1h 15m"),
        ]
        for item in cases {
            XCTAssertEqual(Math.roundedForLog(item.seconds), item.rounded, item.label)
        }
        XCTAssertEqual(Math.roundedForLog(-30), 0, "never negative")
    }

    func testFormatting() {
        XCTAssertEqual(WorkDuration.format(0), "0m")
        XCTAssertEqual(WorkDuration.format(59), "0m", "whole minutes, rounded down")
        XCTAssertEqual(WorkDuration.format(42 * 60 + 59), "42m")
        XCTAssertEqual(WorkDuration.format(7200), "2h")
        XCTAssertEqual(WorkDuration.format(72 * 60), "1h 12m")
        XCTAssertEqual(WorkDuration.format(26 * 3600 + 60), "26h 1m")
    }
}
