//
//  AgentTrafficLightAttentionTests.swift
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

/// The traffic light's timing and look, pinned so a change in how it is drawn cannot change what
/// people see.
final class AgentTrafficLightAttentionTests: XCTestCase {
    func testThePulseLooksAsItAlwaysHas() {
        XCTAssertEqual(TrafficLightPulseSpec.scale, 1.3)
        XCTAssertEqual(TrafficLightPulseSpec.opacity, 0.5)
        XCTAssertEqual(TrafficLightPulseSpec.halfPeriod, 0.7)
        XCTAssertEqual(TrafficLightPulseSpec.settleDuration, 0.15)
        XCTAssertLessThanOrEqual(TrafficLightPulseSpec.preferredFrameRate, 30, "a breath does not need 120 frames a second")
        XCTAssertGreaterThanOrEqual(TrafficLightPulseSpec.minimumFrameRate, 15)
    }

    private let t0 = Date(timeIntervalSince1970: 1_788_000_000)
    typealias A = AgentTrafficLightAttention

    func testRedBreathesForExactlyFourSecondsThenHolds() {
        XCTAssertTrue(A.pulses(yellowOrGreen: false, red: true, completedAt: t0, now: t0.addingTimeInterval(3.99)))
        XCTAssertFalse(A.pulses(yellowOrGreen: false, red: true, completedAt: t0, now: t0.addingTimeInterval(4)))
        XCTAssertFalse(A.pulses(yellowOrGreen: false, red: true, completedAt: nil, now: t0), "no completion seen, no pulse")
        XCTAssertEqual(A.pulseChange(red: true, completedAt: t0, now: t0.addingTimeInterval(1)), t0.addingTimeInterval(4))
        XCTAssertNil(A.pulseChange(red: true, completedAt: t0, now: t0.addingTimeInterval(4)), "one wake, then nothing")
    }

    func testGreenAndYellowBreatheWhileLitAndInactiveNever() {
        XCTAssertTrue(A.pulses(yellowOrGreen: true, red: false, completedAt: nil, now: t0))
        XCTAssertTrue(A.pulses(yellowOrGreen: true, red: false, completedAt: t0.addingTimeInterval(-600), now: t0))
        XCTAssertFalse(A.pulses(yellowOrGreen: false, red: false, completedAt: t0, now: t0), "inactive")
        XCTAssertNil(A.pulseChange(red: false, completedAt: t0, now: t0), "nothing to wake for while green")
    }

    func testTheFiveSecondPillHidesAtFiveOnlyInThatMode() {
        XCTAssertTrue(A.pillVisible(fiveSecondMode: true, firstSeen: t0, now: t0.addingTimeInterval(4.9)))
        XCTAssertFalse(A.pillVisible(fiveSecondMode: true, firstSeen: t0, now: t0.addingTimeInterval(5)))
        XCTAssertTrue(A.pillVisible(fiveSecondMode: false, firstSeen: t0, now: t0.addingTimeInterval(3600)), "until acknowledged")
        XCTAssertEqual(A.pillChange(fiveSecondMode: true, firstSeen: t0, now: t0), t0.addingTimeInterval(5))
        XCTAssertNil(A.pillChange(fiveSecondMode: true, firstSeen: t0, now: t0.addingTimeInterval(60)),
                     "switching to five-second mode a minute later hides it at once, without a wake")
        XCTAssertNil(A.pillChange(fiveSecondMode: false, firstSeen: t0, now: t0))
    }

    func testTheOpenPanelBlinkStopsAtFiveSeconds() {
        XCTAssertTrue(A.blinks(startedAt: t0, now: t0.addingTimeInterval(4.9)))
        XCTAssertFalse(A.blinks(startedAt: t0, now: t0.addingTimeInterval(5)))
        XCTAssertFalse(A.blinks(startedAt: nil, now: t0))
        XCTAssertEqual(A.blinkChange(startedAt: t0, now: t0.addingTimeInterval(2)), t0.addingTimeInterval(5))
        XCTAssertNil(A.blinkChange(startedAt: t0, now: t0.addingTimeInterval(9)))
    }

    func testTheNextSnoozeExpiryIsTheEarliestStillAhead() {
        let snoozes = [SecurityFindingSnooze(id: "a", until: t0.addingTimeInterval(-10)),
                       SecurityFindingSnooze(id: "b", until: t0.addingTimeInterval(300)),
                       SecurityFindingSnooze(id: "c", until: t0.addingTimeInterval(60))]
        XCTAssertEqual(SecurityFindingPriority.nextSnoozeExpiry(snoozes, after: t0), t0.addingTimeInterval(60))
        XCTAssertNil(SecurityFindingPriority.nextSnoozeExpiry([snoozes[0]], after: t0))
        XCTAssertNil(SecurityFindingPriority.nextSnoozeExpiry([], after: t0))
    }
}
