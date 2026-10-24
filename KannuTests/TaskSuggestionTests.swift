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

/// The typed search under the timer tab's bar and a new task's title: the same title first, then
/// titles that start with what was typed, then any other match; two tasks and a New row at most,
/// nothing for one letter or no match; and the keyboard's highlight never picks a moved row.
final class TaskSuggestionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func remote(key: String) -> RemoteTaskInfo {
        RemoteTaskInfo(remoteID: key, key: key, hostScope: "https://example.test", status: "",
                       isDoneRemotely: false, remoteEstimateSeconds: nil, remoteSpentSeconds: nil,
                       gitlabProjectID: nil, gitlabIID: nil, lastSeenAt: now, gitlabKind: nil,
                       gitlabWebURL: nil, statusCategory: nil, labels: nil)
    }

    func testNothingIsOfferedForOneLetterOrSpaces() {
        let tasks = [TaskItem(title: "Deep work")]
        XCTAssertEqual(TaskSearch.suggestions(tasks, typed: "d"), [])
        XCTAssertEqual(TaskSearch.suggestions(tasks, typed: "    "), [])
        XCTAssertEqual(TaskSearch.suggestions(tasks, typed: "de").map(\.title), ["Deep work"])
    }

    func testTheSameTitleComesFirstThenTitlesStartingWithItThenOtherMatches() {
        let other = TaskItem(title: "Plan the deep work week")
        let starting = TaskItem(title: "Deep work: notch")
        let same = TaskItem(title: "Deep work")
        let found = TaskSearch.suggestions([other, starting, same], typed: "déep WORK", limit: 3)
        XCTAssertEqual(found.map(\.id), [same.id, starting.id, other.id])
    }

    func testEachGroupKeepsTheOrderGiven() {
        let a = TaskItem(title: "Deep dive A")
        let b = TaskItem(title: "Deep dive B")
        XCTAssertEqual(TaskSearch.suggestions([b, a], typed: "deep").map(\.id), [b.id, a.id])
    }

    func testAtMostTwoTasksAreOffered() {
        let tasks = (1...5).map { TaskItem(title: "Deep task \($0)") }
        XCTAssertEqual(TaskSearch.suggestions(tasks, typed: "deep").count, TaskSearch.suggestionLimit)
        XCTAssertEqual(TaskSearch.suggestionLimit, 2)
    }

    func testEveryWordMustMatchAndAKeyMatchesToo() {
        let jira = TaskItem(source: .jira, title: "Deep link fix", remote: remote(key: "ABC-123"))
        XCTAssertEqual(TaskSearch.suggestions([jira], typed: "abc-123").map(\.id), [jira.id])
        XCTAssertEqual(TaskSearch.suggestions([jira], typed: "deep frontend"), [])
    }

    func testANameThatMatchesNothingHasNoRowsNotEvenTheNewRow() {
        XCTAssertEqual(TaskSuggestionState.rows(for: [], typed: "Lunch"), [])
        let task = TaskItem(title: "Lunch with Sam")
        XCTAssertEqual(TaskSuggestionState.rows(for: [task], typed: " lunch "),
                       [.task(id: task.id, title: "Lunch with Sam"), .newTask("lunch")], "the New row comes last")
    }

    func testNothingIsHighlightedUntilTheArrowsMove() {
        let task = TaskItem(title: "Deep work")
        var state = TaskSuggestionState()
        state.show(TaskSuggestionState.rows(for: [task], typed: "deep"))
        XCTAssertNil(state.highlightedRow, "Return keeps its meaning")
        XCTAssertTrue(state.move(1))
        XCTAssertEqual(state.highlightedRow, .task(id: task.id, title: "Deep work"))
        XCTAssertTrue(state.move(1))
        XCTAssertEqual(state.highlightedRow, .newTask("deep"))
        XCTAssertTrue(state.move(1))
        XCTAssertEqual(state.highlightedRow, .newTask("deep"), "Down stops at the last row")
        XCTAssertTrue(state.move(-1))
        XCTAssertTrue(state.move(-1))
        XCTAssertNil(state.highlightedRow, "Up from the first row highlights nothing again")
        XCTAssertTrue(state.move(-1))
        XCTAssertEqual(state.highlightedRow, .newTask("deep"), "Up from nothing goes to the last row")
    }

    func testTheArrowsDoNothingWithoutRows() {
        var state = TaskSuggestionState()
        XCTAssertFalse(state.move(1), "the caret keeps the key")
    }

    func testAHighlightClearsWhenItsRowChanges() {
        let a = TaskItem(title: "Deep A")
        let b = TaskItem(title: "Deep B")
        var state = TaskSuggestionState()
        state.show(TaskSuggestionState.rows(for: [a, b], typed: "deep"))
        _ = state.move(1)
        state.show(TaskSuggestionState.rows(for: [a, b], typed: "deep"))
        XCTAssertEqual(state.highlightedRow, .task(id: a.id, title: "Deep A"), "the same row stays")
        state.show(TaskSuggestionState.rows(for: [b, a], typed: "deep"))
        XCTAssertNil(state.highlightedRow, "a reorder never leaves Return on another task")
    }

    func testAClosedListShowsAgainOnlyOnceTheTextDiffers() {
        var state = TaskSuggestionState()
        state.close(on: "deep")
        XCTAssertTrue(state.isClosed(for: "deep"))
        state.textChanged(to: "deepx")
        XCTAssertFalse(state.isClosed(for: "deepx"))
        state.textChanged(to: "deep")
        XCTAssertFalse(state.isClosed(for: "deep"), "typing on and back opens it again")
    }

    func testAFormsListStartsClosedOnItsOpeningTitle() {
        let state = TaskSuggestionState(closedOn: "Deep work")
        XCTAssertTrue(state.isClosed(for: "Deep work"))
        XCTAssertFalse(state.isClosed(for: "Deep work 2"))
    }

    func testClosingDropsTheHighlightAndTheHover() {
        let task = TaskItem(title: "Deep work")
        var state = TaskSuggestionState()
        state.show(TaskSuggestionState.rows(for: [task], typed: "deep"))
        state.isHovered = true
        _ = state.move(1)
        state.close(on: "deep")
        XCTAssertNil(state.highlightedRow)
        XCTAssertFalse(state.isHovered)
    }

    // MARK: - When the list shows, and which key closes it first

    private func stateWithRows(hovered: Bool = false, closedOn: String? = nil) -> TaskSuggestionState {
        var state = TaskSuggestionState(closedOn: closedOn)
        state.show(TaskSuggestionState.rows(for: [TaskItem(title: "Deep work")], typed: "deep"))
        state.isHovered = hovered
        return state
    }

    func testTheListShowsWhileItsFieldIsFocusedWithTextAndRows() {
        let state = stateWithRows()
        XCTAssertTrue(state.shows(enabled: true, typed: "deep", fieldFocused: true))
        XCTAssertFalse(state.shows(enabled: false, typed: "deep", fieldFocused: true), "tasks off, or a task picked")
        XCTAssertFalse(state.shows(enabled: true, typed: "", fieldFocused: true), "nothing typed")
        XCTAssertFalse(state.shows(enabled: true, typed: "deep", fieldFocused: false), "focus gone, pointer away")
        XCTAssertFalse(TaskSuggestionState().shows(enabled: true, typed: "deep", fieldFocused: true),
                       "no rows: nothing to show, so the composer stays")
        XCTAssertTrue(TaskSuggestionState().wantsToShow(enabled: true, typed: "deep", fieldFocused: true),
                      "but the list is in place to find its rows")
    }

    func testThePointerOnTheListHoldsItOnlyWhileNoOtherFieldHasFocus() {
        let hovered = stateWithRows(hovered: true)
        XCTAssertTrue(hovered.shows(enabled: true, typed: "deep", fieldFocused: false),
                      "a click lands though the field let go of focus")
        XCTAssertFalse(hovered.shows(enabled: true, typed: "deep", fieldFocused: false, otherFieldFocused: true),
                       "another field focused under it is never hidden by it")
    }

    func testAListClosedOnTheTextStaysClosedUntilItChanges() {
        var state = stateWithRows(closedOn: "deep")
        XCTAssertFalse(state.shows(enabled: true, typed: "deep", fieldFocused: true))
        state.textChanged(to: "deep w")
        XCTAssertTrue(state.shows(enabled: true, typed: "deep w", fieldFocused: true))
    }

    func testReturnPicksOnlyAHighlightedRowOfAShowingList() {
        var state = stateWithRows()
        XCTAssertEqual(state.answerReturn(showing: true), .passOn, "nothing highlighted: Return keeps its meaning")
        _ = state.move(1)
        XCTAssertEqual(state.answerReturn(showing: true), .pick(state.highlightedRow!))
        XCTAssertEqual(state.answerReturn(showing: false), .passOn, "a hidden list never takes Return")
    }

    /// The bar's Escape closes the list on its text even before rows arrive: rows found later (the
    /// task file read, a sync) for the same text do not reopen it.
    func testAListClosedBeforeItsRowsArriveStaysClosedWhenTheyDo() {
        var state = TaskSuggestionState()
        state.close(on: "Lunch")
        state.show(TaskSuggestionState.rows(for: [TaskItem(title: "Lunch with Sam")], typed: "Lunch"))
        XCTAssertFalse(state.shows(enabled: true, typed: "Lunch", fieldFocused: true))
    }

    func testEscapeClosesAShowingListBeforeItLeaves() {
        let state = stateWithRows()
        XCTAssertEqual(state.answerEscape(showing: true), .closeList)
        XCTAssertEqual(state.answerEscape(showing: false), .passOn, "then Escape leaves the form")
    }
}
