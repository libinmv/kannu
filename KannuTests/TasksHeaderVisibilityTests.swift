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

/// The header's Tasks button: with tasks on, on the timer tab, or on every tab when there is no
/// timer tab; never with tasks off, since its view builds `TasksManager`.
final class TasksHeaderVisibilityTests: XCTestCase {
    func testTheWholeTruthTable() {
        // (enableTasks, currentViewIsTimer, timerTabExists) -> shown
        let table: [(Bool, Bool, Bool, Bool)] = [
            (false, false, false, false),
            (false, false, true, false),
            (false, true, false, false),
            (false, true, true, false),
            (true, false, false, true),   // no timer tab: every tab
            (true, false, true, false),   // a timer tab, another tab current
            (true, true, false, true),
            (true, true, true, true),     // the timer tab is current
        ]
        for (enableTasks, isTimer, tabExists, expected) in table {
            XCTAssertEqual(
                TasksHeaderVisibility.isShown(enableTasks: enableTasks, currentViewIsTimer: isTimer, timerTabExists: tabExists),
                expected,
                "enableTasks: \(enableTasks), currentViewIsTimer: \(isTimer), timerTabExists: \(tabExists)"
            )
        }
    }

    func testTasksOffNeverShowsTheButton() {
        for isTimer in [false, true] {
            for tabExists in [false, true] {
                XCTAssertFalse(TasksHeaderVisibility.isShown(enableTasks: false, currentViewIsTimer: isTimer, timerTabExists: tabExists))
            }
        }
    }
}
