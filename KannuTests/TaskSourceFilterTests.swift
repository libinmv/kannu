//
//  TaskSourceFilterTests.swift
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

/// With a source switched off (Local tasks, Sync Jira), its tasks leave the task order but keep
/// their place in the file. Moves and drags count only what is on screen, so one click on Move Up
/// always changes what the user sees, and a drag lands where it was dropped.
final class TaskSourceFilterTests: XCTestCase {
    typealias Order = TaskOrdering

    /// "a J b K": lower case is a local task, upper case a Jira task; all active.
    private func tasks(_ spec: String) -> [TaskItem] {
        spec.split(separator: " ").map { name in
            TaskItem(source: name.uppercased() == name ? .jira : .local, title: String(name))
        }
    }

    private func titles(_ tasks: [TaskItem]) -> String {
        tasks.map(\.title).joined(separator: " ")
    }

    private func id(_ title: String, in tasks: [TaskItem]) -> UUID {
        tasks.first { $0.title == title }!.id
    }

    private let jiraOnly = Order.listedFilter(showLocal: false, showJira: true, alwaysListed: nil)

    func testTheFilterFollowsTheSources() {
        let list = tasks("a J b K")
        XCTAssertEqual(titles(Order.active(list, listed: jiraOnly)), "J K")
        XCTAssertEqual(titles(Order.active(list, listed: Order.listedFilter(showLocal: true, showJira: false, alwaysListed: nil))), "a b")
        XCTAssertEqual(titles(Order.active(list, listed: Order.listedFilter(showLocal: true, showJira: true, alwaysListed: nil))), "a J b K")
        XCTAssertEqual(titles(Order.active(list)), "a J b K", "the default lists every active task")
    }

    func testTheTimedTaskIsAlwaysListed() {
        let list = tasks("a J b")
        let listed = Order.listedFilter(showLocal: false, showJira: true, alwaysListed: id("b", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: listed)), "J b")
    }

    func testMovesStepOverTasksOfAHiddenSource() {
        let list = tasks("J a b K")
        XCTAssertEqual(titles(Order.movingUp(id("K", in: list), in: list, listed: jiraOnly)), "K J a b")
        XCTAssertEqual(titles(Order.active(Order.movingUp(id("K", in: list), in: list, listed: jiraOnly), listed: jiraOnly)), "K J")
        XCTAssertEqual(titles(Order.movingDown(id("J", in: list), in: list, listed: jiraOnly)), "a b K J")
        XCTAssertEqual(Order.movingUp(id("J", in: list), in: list, listed: jiraOnly), list, "already at the top of what is shown")
        XCTAssertEqual(Order.movingDown(id("K", in: list), in: list, listed: jiraOnly), list, "already at the bottom of what is shown")
    }

    func testADragCountsListedTasksOnly() {
        // On screen: "J K L". Drag L (offset 2) to the top (offset 0).
        let list = tasks("J a K b L")
        let moved = Order.moving(activeOffsets: [2], toActiveOffset: 0, in: list, listed: jiraOnly)
        XCTAssertEqual(titles(Order.active(moved, listed: jiraOnly)), "L J K")
        XCTAssertEqual(titles(moved), "L J a K b")
        // Drag J (offset 0) to the end (offset 3).
        let toEnd = Order.moving(activeOffsets: [0], toActiveOffset: 3, in: list, listed: jiraOnly)
        XCTAssertEqual(titles(Order.active(toEnd, listed: jiraOnly)), "K L J")
        XCTAssertEqual(titles(toEnd), "a K b L J")
    }
}
