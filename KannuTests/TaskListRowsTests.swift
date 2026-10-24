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

/// A Brain task list's rows, worked out once per render (`TaskListRows`): each task's colour (its
/// first tag's, else its source's), whether it is first in the whole task order (Move to Top has
/// nothing to do then, even on a filtered list), and whether it is being timed.
final class TaskListRowsTests: XCTestCase {
    private func rows(_ tasks: [TaskItem], tagColors: [String: TaskColor] = [:],
                      integrations: [TaskSource: TaskColor] = [:], top: UUID? = nil,
                      timed: UUID? = nil, paused: Bool = false) -> TaskListRows {
        TaskListRows(tasks, tagColors: tagColors, integrationColors: integrations,
                     topTaskID: top ?? tasks.first?.id, timedTaskID: timed, timingIsPaused: paused)
    }

    func testEachRowTakesItsFirstTagsColourElseItsSources() {
        let tagged = TaskItem(title: "A", tags: ["docs", "urgent"])
        let untagged = TaskItem(source: .jira, title: "B")
        // A Jira task whose first tag has no colour: glass, though Jira has one.
        let plain = TaskItem(source: .jira, title: "C", tags: ["misc", "docs"])
        let list = rows([tagged, untagged, plain], tagColors: ["docs": .blue, "urgent": .red],
                        integrations: [.jira: .teal])
        XCTAssertEqual(list.rows.map(\.color), [.blue, .teal, .glass],
                       "only the first tag counts, and a tag with no colour is glass, never the source's")
    }

    func testTheDotColumnShowsOnlyOnceARowHasAColour() {
        XCTAssertFalse(rows([TaskItem(title: "A"), TaskItem(title: "B")]).showsColorDots)
        XCTAssertTrue(rows([TaskItem(title: "A"), TaskItem(title: "B", tags: ["x"])], tagColors: ["x": .green]).showsColorDots)
    }

    func testFirstMeansFirstInTheWholeOrderNotTheFilteredList() {
        let top = TaskItem(title: "Top")
        let shown = [TaskItem(title: "B"), TaskItem(title: "C")]
        let filtered = rows(shown, top: top.id)
        XCTAssertEqual(filtered.rows.map(\.isFirst), [false, false],
                       "a filtered list's first row is not first in Up next, so Move to Top still works")
        let whole = rows([top] + shown, top: top.id)
        XCTAssertEqual(whole.rows.map(\.isFirst), [true, false, false])
    }

    func testOnlyTheTimedRowSaysRunningOrPaused() {
        let a = TaskItem(title: "A"), b = TaskItem(title: "B")
        XCTAssertEqual(rows([a, b], timed: b.id).rows.map(\.timing), [nil, .running])
        XCTAssertEqual(rows([a, b], timed: a.id, paused: true).rows.map(\.timing), [.paused, nil])
        XCTAssertEqual(rows([a, b]).rows.map(\.timing), [nil, nil])
    }

    func testTheOrderIsKeptAndAnEmptyListHasNoRows() {
        let tasks = (1...4).map { TaskItem(title: "T\($0)") }
        XCTAssertEqual(rows(tasks).rows.map(\.id), tasks.map(\.id))
        let empty = rows([])
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertFalse(empty.showsColorDots)
    }

    func testAListsColourMatchesTheManagersOne() {
        let task = TaskItem(source: .gitlab, title: "G")
        XCTAssertEqual(TaskColoring.color(of: task, tagColors: [:], integrations: [.gitlab: .orange]),
                       TaskColoring.color(tags: task.tags, tagColors: [:], integration: .orange))
    }
}
