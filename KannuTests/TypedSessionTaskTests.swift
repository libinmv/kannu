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

/// A name typed in the timer tab's bar times a task: the first active local task with that title,
/// whatever the case or accents; the bar and a new task's title are one text; and a task picked
/// from the typed search lasts while the bar still says its name.
final class TypedSessionTaskTests: XCTestCase {
    // MARK: - The title key and the reused task

    func testTheNameKeyIgnoresCaseAccentsAndSpacing() {
        XCTAssertEqual(TaskItem.nameKey("Deep work"), TaskItem.nameKey("  deep   WORK "))
        XCTAssertEqual(TaskItem.nameKey("Café notes"), TaskItem.nameKey("cafe NOTES"))
        XCTAssertNotEqual(TaskItem.nameKey("Deep work"), TaskItem.nameKey("Deep works"))
        XCTAssertNil(TaskItem.nameKey("   "), "nothing typed is no name")
    }

    /// The key never depends on the Mac's language: in Turkish, "I" lowercases to a dotless "ı", so
    /// a key folded with the user's locale would lose "INBOX" against "inbox".
    func testTheNameKeyIgnoresTheLocale() {
        XCTAssertEqual(TaskItem.nameKey("INBOX"), TaskItem.nameKey("inbox"))
        let turkish = Locale(identifier: "tr_TR")
        XCTAssertNotEqual("INBOX".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: turkish),
                          "inbox".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: turkish),
                          "the pair does depend on a locale, so the first check proves the key ignores it")
    }

    func testALongTitleIsKeyedByWhatTheBarCanHold() {
        let long = String(repeating: "abcde ", count: 10).trimmingCharacters(in: .whitespaces)   // 59 characters
        let barText = TimerSessionName.cleaned(long)!
        XCTAssertEqual(barText.count, TimerSessionName.maxLength)
        XCTAssertEqual(TaskItem.nameKey(barText), TaskItem.nameKey(long), "the bar holds 40 characters of it")
    }

    func testTheFirstActiveLocalTaskWithTheTitleIsReused() {
        let first = TaskItem(title: "Deep work")
        let second = TaskItem(title: "deep WORK")
        let tasks = [TaskItem(title: "Email"), first, second]
        XCTAssertEqual(TaskItem.reusable(titled: "Déep work", in: tasks)?.id, first.id, "the first in the user's order")
    }

    func testDoneArchivedAndRemoteTasksAreNeverReused() {
        let done = TaskItem(title: "Deep work", visibility: .done)
        let archived = TaskItem(title: "Deep work", visibility: .archived)
        let jira = TaskItem(source: .jira, title: "Deep work")
        XCTAssertNil(TaskItem.reusable(titled: "Deep work", in: [done, archived, jira]))
        let local = TaskItem(title: "Deep work")
        XCTAssertEqual(TaskItem.reusable(titled: "Deep work", in: [jira, done, local])?.id, local.id)
        XCTAssertNil(TaskItem.reusable(titled: "  ", in: [local]), "no name reuses nothing")
    }

    func testALongTitleIsReusedByItsFirstFortyCharacters() {
        let long = TaskItem(title: "Write the quarterly planning document for the platform team")
        let typed = TimerSessionName.cleaned(long.title)!
        XCTAssertEqual(TaskItem.reusable(titled: typed, in: [long])?.id, long.id)
    }

    // MARK: - The bar and a new task's title

    func testAnEmptyBarOpensTheKeptDraftOrAnEmptyForm() {
        var kept = TaskFormDraft()
        kept.title = "Write report"
        kept.chooseEstimate(3600)
        XCTAssertEqual(TaskFormDraft.newTask(bar: "", kept: kept), kept)
        XCTAssertEqual(TaskFormDraft.newTask(bar: "   ", kept: nil), TaskFormDraft())
    }

    func testABarWithNoKeptDraftOpensAFreshDraftWithItsCleanedText() {
        let draft = TaskFormDraft.newTask(bar: "  Deep   work ", kept: nil)
        XCTAssertEqual(draft.title, "Deep work")
        XCTAssertTrue(draft.isNew)
        XCTAssertNil(draft.estimateSeconds)
    }

    func testABarThatIsTheKeptTitleOpensTheKeptDraftWhole() {
        var kept = TaskFormDraft()
        kept.title = "Café notes"
        kept.chooseEstimate(1800)
        kept.tagsText = "writing"
        XCTAssertEqual(TaskFormDraft.newTask(bar: "cafe NOTES", kept: kept), kept, "case and accents")
        var long = TaskFormDraft()
        long.title = "Write the quarterly planning document for the platform team"
        XCTAssertEqual(TaskFormDraft.newTask(bar: TaskFormDraft.barText(long.title), kept: long), long,
                       "the bar's 40 characters of a longer title keep the whole title")
    }

    func testOtherBarTextBecomesTheKeptDraftsTitleAndKeepsTheRest() {
        var kept = TaskFormDraft()
        kept.title = "Write report"
        kept.chooseEstimate(7200)
        kept.tagsText = "docs"
        let draft = TaskFormDraft.newTask(bar: "Lunch", kept: kept)
        XCTAssertEqual(draft.title, "Lunch")
        XCTAssertEqual(draft.estimateSeconds, 7200, "nothing typed is lost")
        XCTAssertEqual(draft.tagsText, "docs")
    }

    func testAnUntitledKeptDraftTakesTheBarsText() {
        var kept = TaskFormDraft()
        kept.chooseEstimate(7200)
        let draft = TaskFormDraft.newTask(bar: "Foo", kept: kept)
        XCTAssertEqual(draft.title, "Foo")
        XCTAssertEqual(draft.estimateSeconds, 7200)
    }

    func testTheBarsTextIsTheTitleCutToFortyCharacters() {
        XCTAssertEqual(TaskFormDraft.barText("  Deep   work "), "Deep work")
        XCTAssertEqual(TaskFormDraft.barText("   "), "")
        XCTAssertEqual(TaskFormDraft.barText(String(repeating: "a", count: 60)).count, TimerSessionName.maxLength)
    }

    /// The loss the review found: the form's title goes back to the bar however the form closes, so
    /// the next New Task finds the same draft.
    func testATitleChangedInTheFormComesBackWithEverythingTyped() {
        var drafts = KeptTaskFormDrafts()
        var draft = TaskFormDraft.newTask(bar: "Foo", kept: nil)
        draft.title = "Foo bar"
        draft.chooseEstimate(3600)
        draft.tagsText = "book"
        drafts.keep(draft, baseline: nil)
        let bar = TaskFormDraft.barText(draft.title)
        let calendar = Calendar(identifier: .gregorian)
        let kept = drafts.draft(editing: nil, baseline: nil, now: Date(), calendar: calendar)
        XCTAssertEqual(TaskFormDraft.newTask(bar: bar, kept: kept), draft)
    }

    // MARK: - A picked task

    func testAPickLastsWhileTheBarStillSaysItsName() {
        let pick = TimerSessionPick(taskID: UUID(), name: "Deep work", typed: "deep")
        XCTAssertEqual(pick.kept(typed: "Deep work"), pick)
        XCTAssertNil(pick.kept(typed: "Deep wor"), "editing the text unpicks")
        XCTAssertNil(pick.kept(typed: ""), "clearing unpicks")
        XCTAssertFalse(pick.isNew)
        XCTAssertTrue(TimerSessionPick(taskID: nil, name: "Deep work", typed: "Deep work").isNew)
    }

    // MARK: - How a start from the bar runs

    func testWithTasksOffEveryStartIsPlain() {
        let pick = TimerSessionPick(taskID: UUID(), name: "Deep work", typed: "deep")
        XCTAssertEqual(TimerTypedStart.route(tasksAvailable: false, typed: "Deep work", pick: pick), .plain)
        XCTAssertEqual(TimerTypedStart.route(tasksAvailable: false, typed: "Deep work", pick: nil), .plain)
    }

    func testAPickedTaskIsTimedAsItIs() {
        let id = UUID()
        let pick = TimerSessionPick(taskID: id, name: "Deep work", typed: "deep")
        XCTAssertEqual(TimerTypedStart.route(tasksAvailable: true, typed: "Deep work", pick: pick), .pickedTask(id))
    }

    func testATypedNameReusesExceptAfterTheNewRow() {
        XCTAssertEqual(TimerTypedStart.route(tasksAvailable: true, typed: "Deep work", pick: nil), .typed(reuse: true))
        let new = TimerSessionPick(taskID: nil, name: "Deep work", typed: "Deep work")
        XCTAssertEqual(TimerTypedStart.route(tasksAvailable: true, typed: "Deep work", pick: new), .typed(reuse: false))
    }

    func testNothingTypedStartsPlain() {
        XCTAssertEqual(TimerTypedStart.route(tasksAvailable: true, typed: "   ", pick: nil), .plain)
    }

    // MARK: - A preset clicked over the task form

    func testANewTasksFormStartsHoldsOrFallsThrough() {
        XCTAssertEqual(TimerFormStart.forNewTask(nil), .fallThrough, "nothing typed")
        var untitled = TaskFormDraft()
        untitled.chooseEstimate(3600)
        XCTAssertEqual(TimerFormStart.forNewTask(untitled), .fallThrough, "no title: as if no form were open")
        var unreadable = TaskFormDraft()
        unreadable.title = "Write spec"
        unreadable.typeEstimate("2x")
        XCTAssertEqual(TimerFormStart.forNewTask(unreadable), .held, "the estimate is fixed first")
        var ready = TaskFormDraft()
        ready.title = "Write spec"
        ready.typeEstimate("2h")
        XCTAssertEqual(TimerFormStart.forNewTask(ready), .started)
    }

    func testAnEditsFormTimesItsTaskUnlessTheTaskIsGone() {
        XCTAssertEqual(TimerFormStart.forEdit(taskInList: true), .started)
        XCTAssertEqual(TimerFormStart.forEdit(taskInList: false), .gone, "never the bar's text or its pick")
    }
}
