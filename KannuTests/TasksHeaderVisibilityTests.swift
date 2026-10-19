//
//  TasksHeaderVisibilityTests.swift
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

/// The header's Tasks button: with tasks on, wherever the timer tab's task column cannot show —
/// on every tab when there is no timer tab, and on the timer tab only while a timer runs (the
/// column hides then). Never on the other tabs of a notch with a timer tab, and never with tasks
/// off, since its view builds `TasksManager`.
final class TasksHeaderVisibilityTests: XCTestCase {
    func testTheWholeTruthTable() {
        // (enableTasks, currentViewIsTimer, timerTabExists, timerIsRunning) -> shown
        let table: [(Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, false, false, false),
            (false, false, false, true, false),
            (false, false, true, false, false),
            (false, false, true, true, false),
            (false, true, false, false, false),
            (false, true, false, true, false),
            (false, true, true, false, false),
            (false, true, true, true, false),
            (true, false, false, false, true),   // no timer tab: every tab
            (true, false, false, true, true),
            (true, true, false, false, true),
            (true, true, false, true, true),
            (true, false, true, false, false),   // a timer tab, another tab current
            (true, false, true, true, false),
            (true, true, true, false, false),    // the timer tab, its task column showing
            (true, true, true, true, true),      // the timer tab while a timer runs: no column
        ]
        for (enableTasks, isTimer, tabExists, running, expected) in table {
            XCTAssertEqual(
                TasksHeaderVisibility.isShown(enableTasks: enableTasks, currentViewIsTimer: isTimer,
                                              timerTabExists: tabExists, timerIsRunning: running),
                expected,
                "enableTasks: \(enableTasks), currentViewIsTimer: \(isTimer), timerTabExists: \(tabExists), timerIsRunning: \(running)"
            )
        }
    }

    func testTasksOffNeverShowsTheButton() {
        for isTimer in [false, true] {
            for tabExists in [false, true] {
                for running in [false, true] {
                    XCTAssertFalse(TasksHeaderVisibility.isShown(enableTasks: false, currentViewIsTimer: isTimer,
                                                                 timerTabExists: tabExists, timerIsRunning: running))
                }
            }
        }
    }

    /// David: the timer tab's task column has the list, search, the filter, Refresh and Time to
    /// log, so the button repeats nothing there; while a timer runs the column hides, and the
    /// button is the way to the running task's clock, Up next and Time to log.
    func testTheTimerTabShowsTheButtonOnlyWhileATimerRuns() {
        XCTAssertFalse(TasksHeaderVisibility.isShown(enableTasks: true, currentViewIsTimer: true, timerTabExists: true, timerIsRunning: false))
        XCTAssertTrue(TasksHeaderVisibility.isShown(enableTasks: true, currentViewIsTimer: true, timerTabExists: true, timerIsRunning: true))
    }
}
