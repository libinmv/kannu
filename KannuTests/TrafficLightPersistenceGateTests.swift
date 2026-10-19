//
//  TrafficLightPersistenceGateTests.swift
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

/// The gate's contract: everything that lights the traffic light publishes at once; a calming
/// change — leaving a running state, or hiding the light — must persist for `holdSeconds` before
/// anyone sees it. A blip that reverts inside the hold was never published, so the notch never
/// reacts to it.
final class TrafficLightPersistenceGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func advanced(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: - Immediate paths

    func testFirstDecisionPublishesWhateverItIs() {
        var gate = TrafficLightPersistenceGate()
        XCTAssertEqual(gate.decide(state: .stopped, shouldShow: true, now: t0), .publish)
    }

    func testEntriesIntoARunningStatePublishAtOnce() {
        var gate = TrafficLightPersistenceGate()
        XCTAssertEqual(gate.decide(state: .inactive, shouldShow: false, now: t0), .publish)
        XCTAssertEqual(gate.decide(state: .executing, shouldShow: true, now: advanced(0.1)), .publish)
        XCTAssertEqual(gate.decide(state: .awaitingInput, shouldShow: true, now: advanced(0.2)), .publish,
                       "yellow follows evidence — it must never wait out a hold")
        XCTAssertEqual(gate.decide(state: .thinking, shouldShow: true, now: advanced(0.3)), .publish)
    }

    func testARepeatOfThePublishedPairIsUnchanged() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        XCTAssertEqual(gate.decide(state: .executing, shouldShow: true, now: advanced(5)), .unchanged)
    }

    // MARK: - The hold

    func testLeavingARunHoldsForTheFullWindowThenPublishes() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        let deadline = advanced(TrafficLightPersistenceGate.holdSeconds)
        XCTAssertEqual(gate.decide(state: .stopped, shouldShow: true, now: t0), .hold(until: deadline))
        // Re-evaluations before the deadline keep the original clock.
        XCTAssertEqual(gate.decide(state: .stopped, shouldShow: true, now: advanced(0.5)), .hold(until: deadline))
        XCTAssertEqual(gate.decide(state: .stopped, shouldShow: true, now: deadline), .publish)
    }

    func testABlipThatRevertsInsideTheHoldWasNeverPublished() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        guard case .hold = gate.decide(state: .stopped, shouldShow: true, now: advanced(0.1)) else {
            return XCTFail("leaving a run must hold")
        }
        // Green is back before the hold matured: nothing to publish, the hold is forgotten…
        XCTAssertEqual(gate.decide(state: .executing, shouldShow: true, now: advanced(0.4)), .unchanged)
        // …so a later real stop starts a fresh clock instead of inheriting the blip's.
        let laterDeadline = advanced(2 + TrafficLightPersistenceGate.holdSeconds)
        XCTAssertEqual(gate.decide(state: .stopped, shouldShow: true, now: advanced(2)), .hold(until: laterDeadline))
    }

    func testHidingTheLightIsAlsoHeld() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .stopped, shouldShow: true, now: t0)
        let deadline = advanced(TrafficLightPersistenceGate.holdSeconds)
        XCTAssertEqual(gate.decide(state: .inactive, shouldShow: false, now: t0), .hold(until: deadline))
        XCTAssertEqual(gate.decide(state: .inactive, shouldShow: false, now: deadline), .publish)
    }

    func testADifferentCalmingCandidateRestartsTheClock() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        _ = gate.decide(state: .stopped, shouldShow: true, now: t0)
        // Half-way through, the computed pair calms differently: its own full window applies.
        let restarted = advanced(0.5 + TrafficLightPersistenceGate.holdSeconds)
        XCTAssertEqual(gate.decide(state: .inactive, shouldShow: false, now: advanced(0.5)), .hold(until: restarted))
        XCTAssertEqual(gate.decide(state: .inactive, shouldShow: false, now: restarted), .publish)
    }

    func testTransitionsAmongRunningStatesNeverHold() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        XCTAssertEqual(gate.decide(state: .awaitingInput, shouldShow: true, now: advanced(0.1)), .publish)
        XCTAssertEqual(gate.decide(state: .executing, shouldShow: true, now: advanced(0.2)), .publish)
    }

    func testAPublishedStopGoingGreenAgainIsImmediate() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        _ = gate.decide(state: .stopped, shouldShow: true, now: advanced(2))
        XCTAssertEqual(gate.decide(state: .stopped, shouldShow: true, now: advanced(2 + TrafficLightPersistenceGate.holdSeconds)), .publish)
        XCTAssertEqual(gate.decide(state: .executing, shouldShow: true, now: advanced(4)), .publish)
    }

    // MARK: - Reset

    func testResetForgetsThePublishedPairAndAnyHold() {
        var gate = TrafficLightPersistenceGate()
        _ = gate.decide(state: .executing, shouldShow: true, now: t0)
        _ = gate.decide(state: .stopped, shouldShow: true, now: advanced(0.1))
        gate.reset()
        // A restart publishes whatever it first computes, with no inherited clock.
        XCTAssertEqual(gate.decide(state: .inactive, shouldShow: false, now: advanced(0.2)), .publish)
    }
}
