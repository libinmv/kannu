//
//  TaskOrderTests.swift
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

/// The order is the array's order. Done and hidden tasks keep their place, so every move steps over
/// them: one click on Move Up always changes what the user sees.
final class TaskOrderTests: XCTestCase {
    typealias Order = TaskOrdering

    private func tasks(_ spec: String) -> [TaskItem] {
        // "A B x C": capitals are active, lower case is done.
        spec.split(separator: " ").map { name in
            TaskItem(title: String(name), visibility: name.uppercased() == name ? .active : .done)
        }
    }

    private func titles(_ tasks: [TaskItem]) -> String {
        tasks.map(\.title).joined(separator: " ")
    }

    private func id(_ title: String, in tasks: [TaskItem]) -> UUID {
        tasks.first { $0.title == title }!.id
    }

    func testANewTaskGoesToTheTop() {
        let list = tasks("A B")
        XCTAssertEqual(titles(Order.inserting(TaskItem(title: "N"), into: list)), "N A B")
    }

    func testTheTaskOrderShowsActiveTasksOnly() {
        XCTAssertEqual(titles(Order.active(tasks("A x B y C"))), "A B C")
    }

    func testMoveToTop() {
        let list = tasks("A x B C")
        XCTAssertEqual(titles(Order.movingToTop(id("C", in: list), in: list)), "C A x B")
        XCTAssertEqual(titles(Order.movingToTop(id("A", in: list), in: list)), "A x B C", "already at the top")
    }

    func testMoveUpStepsOverTasksThatAreNotShown() {
        let list = tasks("A x y B C")
        XCTAssertEqual(titles(Order.movingUp(id("B", in: list), in: list)), "B A x y C")
        XCTAssertEqual(titles(Order.movingUp(id("C", in: list), in: list)), "A x y C B")
        XCTAssertEqual(titles(Order.movingUp(id("A", in: list), in: list)), "A x y B C", "no change at the top")
    }

    func testMoveDownStepsOverTasksThatAreNotShown() {
        let list = tasks("A x y B C")
        XCTAssertEqual(titles(Order.movingDown(id("A", in: list), in: list)), "x y B A C")
        XCTAssertEqual(Order.active(Order.movingDown(id("A", in: list), in: list)).map(\.title), ["B", "A", "C"])
        XCTAssertEqual(titles(Order.movingDown(id("C", in: list), in: list)), "A x y B C", "no change at the bottom")
    }

    func testAMoveOfAnUnknownTaskChangesNothing() {
        let list = tasks("A B")
        XCTAssertEqual(Order.movingUp(UUID(), in: list), list)
        XCTAssertEqual(Order.movingDown(UUID(), in: list), list)
        XCTAssertEqual(Order.movingToTop(UUID(), in: list), list)
    }

    func testADragCountsActiveTasksOnly() {
        // The list the user drags in is "A B C"; x sits between A and B in the file.
        let list = tasks("A x B C")
        // Drag A below B (onMove: from 0 to 2).
        XCTAssertEqual(Order.active(Order.moving(activeOffsets: [0], toActiveOffset: 2, in: list)).map(\.title), ["B", "A", "C"])
        // Drag C to the top.
        XCTAssertEqual(titles(Order.moving(activeOffsets: [2], toActiveOffset: 0, in: list)), "C A x B")
        // Drag A to the end.
        XCTAssertEqual(Order.active(Order.moving(activeOffsets: [0], toActiveOffset: 3, in: list)).map(\.title), ["B", "C", "A"])
        // An offset past the list moves nothing.
        XCTAssertEqual(Order.moving(activeOffsets: [7], toActiveOffset: 0, in: list), list)
    }

    func testReopeningPutsATaskBackWhereItWas() {
        var list = tasks("A b C")
        list[1].visibility = .active
        XCTAssertEqual(Order.active(list).map(\.title), ["A", "b", "C"])
    }
}
