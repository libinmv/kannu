/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest

/// The run clock for sessions that have no hook turn — issue #14's remaining half.
///
/// Before this rule existed as a function, it lived inside a `private` method on a `@MainActor` monitor
/// with no test anywhere, which is why "execution time resets" kept being reported and kept being hard
/// to pin down. The distinction it has to hold is between a card being *dimmed by the staleness ladder*
/// and a run actually *ending*; the old code treated both as a new run.
final class AgentExecutionClockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_757_000_000)
    private var now: Date { t0.addingTimeInterval(1200) }

    private func input(
        _ id: String = "c1",
        active: Bool,
        rawActive: Bool,
        updatedAt: Date? = nil,
        previousActive: Bool
    ) -> AgentExecutionClock.Input {
        AgentExecutionClock.Input(
            conversationID: id,
            isActiveRun: active,
            hasActiveRawState: rawActive,
            updatedAt: updatedAt ?? t0,
            previousWasActiveRun: previousActive
        )
    }

    func testANewRunStartsNow() {
        let result = AgentExecutionClock.resolve(
            inputs: [input(active: true, rawActive: true, previousActive: false)],
            existing: [:],
            now: now
        )
        XCTAssertEqual(result.displayedStartByConversationID["c1"], now)
        XCTAssertEqual(result.startByConversationID["c1"], now)
    }

    func testARunInProgressKeepsItsStart() {
        let result = AgentExecutionClock.resolve(
            inputs: [input(active: true, rawActive: true, previousActive: true)],
            existing: ["c1": t0],
            now: now
        )
        XCTAssertEqual(result.displayedStartByConversationID["c1"], t0)
    }

    func testARunAlreadyUnderwayWhenKannuStartedWatchingDatesFromUpdatedAt() {
        // Nothing better to date it from. `now` would claim the run just began.
        let result = AgentExecutionClock.resolve(
            inputs: [input(active: true, rawActive: true, updatedAt: t0, previousActive: true)],
            existing: [:],
            now: now
        )
        XCTAssertEqual(result.displayedStartByConversationID["c1"], t0)
    }

    func testAStaleAgedDemotionDoesNotRestartTheClock() {
        // The reported symptom, reached without any thinking event: a long quiet phase trips the
        // `activeStaleMs` demotion, so the *display* state dips while the source still says executing.
        let dipped = AgentExecutionClock.resolve(
            inputs: [input(active: false, rawActive: true, previousActive: true)],
            existing: ["c1": t0],
            now: now
        )
        // Nothing is shown while the card is not an active run...
        XCTAssertNil(dipped.displayedStartByConversationID["c1"])
        // ...but the clock survives, which is the whole fix.
        XCTAssertEqual(dipped.startByConversationID["c1"], t0)

        let resumed = AgentExecutionClock.resolve(
            inputs: [input(active: true, rawActive: true, previousActive: false)],
            existing: dipped.startByConversationID,
            now: now
        )
        XCTAssertEqual(
            resumed.displayedStartByConversationID["c1"], t0,
            "a demoted-then-resumed run must keep its original start, not restart at now"
        )
    }

    func testAGenuineEndClearsTheClock() {
        let ended = AgentExecutionClock.resolve(
            inputs: [input(active: false, rawActive: false, previousActive: true)],
            existing: ["c1": t0],
            now: now
        )
        XCTAssertNil(ended.startByConversationID["c1"])
        XCTAssertNil(ended.displayedStartByConversationID["c1"])
    }

    func testANewRequestAfterARealStopRestarts() {
        // The property the fix must not break: a stop then a fresh request is a new run, so the clock
        // starts again rather than continuing the previous one.
        let ended = AgentExecutionClock.resolve(
            inputs: [input(active: false, rawActive: false, previousActive: true)],
            existing: ["c1": t0],
            now: now
        )
        let restarted = AgentExecutionClock.resolve(
            inputs: [input(active: true, rawActive: true, previousActive: false)],
            existing: ended.startByConversationID,
            now: now
        )
        XCTAssertEqual(restarted.displayedStartByConversationID["c1"], now)
    }

    func testAConversationThatLeavesTheListIsForgotten() {
        let result = AgentExecutionClock.resolve(
            inputs: [input("c2", active: true, rawActive: true, previousActive: false)],
            existing: ["c1": t0, "c2": t0],
            now: now
        )
        XCTAssertNil(result.startByConversationID["c1"], "the map must not grow forever")
        XCTAssertNotNil(result.startByConversationID["c2"])
    }

    func testSessionsAreIndependent() {
        let result = AgentExecutionClock.resolve(
            inputs: [
                input("c1", active: true, rawActive: true, previousActive: true),
                input("c2", active: true, rawActive: true, previousActive: false),
                input("c3", active: false, rawActive: false, previousActive: true)
            ],
            existing: ["c1": t0, "c3": t0],
            now: now
        )
        XCTAssertEqual(result.displayedStartByConversationID["c1"], t0)
        XCTAssertEqual(result.displayedStartByConversationID["c2"], now)
        XCTAssertNil(result.displayedStartByConversationID["c3"])
        XCTAssertNil(result.startByConversationID["c3"])
    }

    func testAnEmptyListClearsEverything() {
        let result = AgentExecutionClock.resolve(inputs: [], existing: ["c1": t0], now: now)
        XCTAssertEqual(result, AgentExecutionClock.Resolution(
            startByConversationID: [:], displayedStartByConversationID: [:]
        ))
    }
}
