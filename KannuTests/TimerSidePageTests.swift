//
//  TimerSidePageTests.swift
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

/// The timer tab's side column: which page it opens on, and what a two-finger swipe does.
final class TimerSidePageTests: XCTestCase {
    // MARK: - The page the tab opens on

    /// Every combination of the four inputs, against the rule: Tasks when tasks are available and
    /// Jira or GitLab is connected; else Presets when presets are available; else Tasks.
    func testTheInitialPageTruthTable() {
        for tasks in [false, true] {
            for presets in [false, true] {
                for jira in [false, true] {
                    for gitlab in [false, true] {
                        let expected: TimerSidePage
                        if tasks && (jira || gitlab) {
                            expected = .tasks
                        } else if presets {
                            expected = .presets
                        } else {
                            expected = .tasks
                        }
                        let page = TimerSidePage.initial(tasksAvailable: tasks, presetsAvailable: presets,
                                                         jiraConnected: jira, gitlabConnected: gitlab)
                        XCTAssertEqual(page, expected, "tasks \(tasks) presets \(presets) jira \(jira) gitlab \(gitlab)")
                    }
                }
            }
        }
    }

    func testAConnectedSourceOpensTasksEvenWithPresetsOn() {
        XCTAssertEqual(TimerSidePage.initial(tasksAvailable: true, presetsAvailable: true, jiraConnected: true, gitlabConnected: false), .tasks)
        XCTAssertEqual(TimerSidePage.initial(tasksAvailable: true, presetsAvailable: true, jiraConnected: false, gitlabConnected: true), .tasks)
    }

    func testWithoutAConnectionPresetsIsTheDeepWorkDefault() {
        XCTAssertEqual(TimerSidePage.initial(tasksAvailable: true, presetsAvailable: true, jiraConnected: false, gitlabConnected: false), .presets)
    }

    func testAConnectionWithoutTheTasksPageNeverOpensTasks() {
        XCTAssertEqual(TimerSidePage.initial(tasksAvailable: false, presetsAvailable: true, jiraConnected: true, gitlabConnected: true), .presets)
    }

    func testTheOnlyPageIsTheOneShown() {
        XCTAssertEqual(TimerSidePage.initial(tasksAvailable: true, presetsAvailable: false, jiraConnected: false, gitlabConnected: false), .tasks)
    }

    // MARK: - Swipe decision

    func testFingersMovingLeftBringInPresets() {
        XCTAssertEqual(TimerSidePage.swiped(from: .tasks, dx: -50, dy: 0), .presets)
    }

    func testFingersMovingRightBringBackTasks() {
        XCTAssertEqual(TimerSidePage.swiped(from: .presets, dx: 50, dy: 0), .tasks)
    }

    func testASwipeTowardTheShownPageChangesNothing() {
        XCTAssertNil(TimerSidePage.swiped(from: .presets, dx: -80, dy: 0))
        XCTAssertNil(TimerSidePage.swiped(from: .tasks, dx: 80, dy: 0))
    }

    func testTheThresholdIsInclusiveAndShortSwipesDoNothing() {
        let threshold = TimerSidePage.swipeThreshold
        XCTAssertEqual(threshold, 40)
        XCTAssertNil(TimerSidePage.swiped(from: .tasks, dx: -(threshold - 1), dy: 0))
        XCTAssertEqual(TimerSidePage.swiped(from: .tasks, dx: -threshold, dy: 0), .presets)
        XCTAssertNil(TimerSidePage.swiped(from: .tasks, dx: -30, dy: 0, threshold: 31))
        XCTAssertEqual(TimerSidePage.swiped(from: .tasks, dx: -30, dy: 0, threshold: 30), .presets)
    }

    func testAVerticalDominantGestureIsIgnored() {
        XCTAssertNil(TimerSidePage.swiped(from: .tasks, dx: -60, dy: 120), "a list scroll that drifts sideways")
        XCTAssertNil(TimerSidePage.swiped(from: .tasks, dx: -60, dy: -60), "diagonal is not clearly horizontal")
        XCTAssertNil(TimerSidePage.swiped(from: .tasks, dx: -60, dy: 45), "60 is not clearly more than 45")
        XCTAssertEqual(TimerSidePage.swiped(from: .tasks, dx: -60, dy: 30), .presets)
    }

    // MARK: - One gesture

    func testAGestureAccumulatesUntilItCrossesTheThreshold() {
        var swipe = TimerSideSwipe()
        XCTAssertNil(swipe.add(dx: -15, dy: 1, current: .tasks))
        XCTAssertNil(swipe.add(dx: -15, dy: 1, current: .tasks))
        XCTAssertEqual(swipe.add(dx: -15, dy: 0, current: .tasks), .presets)
        XCTAssertTrue(swipe.hasFlipped)
    }

    func testAGestureFlipsAtMostOnce() {
        var swipe = TimerSideSwipe()
        XCTAssertEqual(swipe.add(dx: -50, dy: 0, current: .tasks), .presets)
        // The fingers keep going, then come all the way back: still the one flip.
        XCTAssertNil(swipe.add(dx: -50, dy: 0, current: .presets))
        XCTAssertNil(swipe.add(dx: 200, dy: 0, current: .presets))
        XCTAssertNil(swipe.add(dx: 200, dy: 0, current: .presets))
    }

    func testANewGestureCanFlipAgain() {
        var swipe = TimerSideSwipe()
        XCTAssertEqual(swipe.add(dx: -50, dy: 0, current: .tasks), .presets)
        swipe.reset()
        XCTAssertEqual(swipe, TimerSideSwipe())
        XCTAssertEqual(swipe.add(dx: 50, dy: 0, current: .presets), .tasks)
    }

    func testAVerticalGestureNeverFlipsHoweverFarItGoes() {
        var swipe = TimerSideSwipe()
        for _ in 0..<20 {
            XCTAssertNil(swipe.add(dx: -5, dy: 12, current: .tasks))
        }
        XCTAssertFalse(swipe.hasFlipped)
    }

    /// The list scrolled down, then back up, in one gesture with a little sideways drift: the
    /// vertical travel must not cancel out and leave the drift looking like a swipe.
    func testScrollingDownAndBackUpNeverFlips() {
        var swipe = TimerSideSwipe()
        for _ in 0..<20 {
            XCTAssertNil(swipe.add(dx: -2, dy: 10, current: .tasks))
        }
        for _ in 0..<20 {
            XCTAssertNil(swipe.add(dx: -2, dy: -10, current: .tasks))
        }
        XCTAssertFalse(swipe.hasFlipped)
        XCTAssertEqual(swipe.dx, -80)
        XCTAssertEqual(swipe.dy, 400, "vertical travel counts both ways")
    }
}
