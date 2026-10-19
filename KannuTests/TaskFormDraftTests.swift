//
//  TaskFormDraftTests.swift
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

/// The timer tab's task form: a new task needs a title; an edit changes only what the user changed;
/// a Jira or GitLab task's title and reminder are not Kannu's to change.
final class TaskFormDraftTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 08:53:20 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func remote(key: String, estimate: Int? = nil) -> RemoteTaskInfo {
        RemoteTaskInfo(remoteID: key, key: key, hostScope: "https://example.test", status: "",
                       isDoneRemotely: false, remoteEstimateSeconds: estimate, remoteSpentSeconds: nil,
                       gitlabProjectID: nil, gitlabIID: nil, lastSeenAt: now, gitlabKind: nil,
                       gitlabWebURL: nil, statusCategory: nil, labels: nil)
    }

    func testTheEstimateChoicesAreBrainsAddRowsOwn() {
        XCTAssertEqual(TaskFormDraft.estimateChoices, [900, 1800, 3600, 7200, 14_400, 28_800])
    }

    func testANewTaskNeedsATitleAndIsLocal() {
        var draft = TaskFormDraft()
        XCTAssertTrue(draft.isNew)
        XCTAssertTrue(draft.canEditTitle)
        XCTAssertTrue(draft.canSchedule)
        XCTAssertFalse(draft.canSave, "no title")
        draft.title = "   "
        XCTAssertFalse(draft.canSave, "spaces are no title")
        draft.title = "Write the notes"
        XCTAssertTrue(draft.canSave)
        XCTAssertEqual(draft.estimateLabel, "No estimate")
    }

    func testAnEditStartsFromTheTask() {
        let task = TaskItem(title: "Local", localEstimateSeconds: 3600, tags: ["docs", "urgent"],
                            scheduledAt: now)
        let draft = TaskFormDraft(editing: task)
        XCTAssertEqual(draft.editing, task.id)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.title, "Local")
        XCTAssertEqual(draft.estimateSeconds, 3600)
        XCTAssertEqual(draft.tagsText, "docs, urgent")
        XCTAssertEqual(draft.reminder, now)
        XCTAssertEqual(draft.edits(to: task), [], "nothing typed, nothing changes")
    }

    func testAnEditChangesOnlyWhatChanged() {
        let task = TaskItem(title: "Local", localEstimateSeconds: 3600, tags: ["docs"])
        var draft = TaskFormDraft(editing: task)
        draft.title = "  Local   notes "
        draft.tagsText = "docs, #Urgent"
        XCTAssertEqual(draft.edits(to: task), [.title("Local notes"), .tags(["docs", "Urgent"])])
        draft.estimateSeconds = 0
        draft.reminder = now
        XCTAssertEqual(draft.edits(to: task), [.title("Local notes"), .estimate(nil), .tags(["docs", "Urgent"]), .schedule(now)],
                       "zero is no estimate")
    }

    func testARemoteTaskKeepsItsServersTitleAndHasNoReminder() {
        let task = TaskItem(source: .jira, title: "Fix login", remote: remote(key: "PROJ-1", estimate: 7200))
        var draft = TaskFormDraft(editing: task)
        XCTAssertFalse(draft.canEditTitle)
        XCTAssertFalse(draft.canSchedule)
        XCTAssertTrue(draft.canSave, "its title is the server's, never empty here")
        XCTAssertEqual(draft.estimateLabel, "2h from Jira", "the source's estimate while Kannu has none")
        draft.title = "Renamed"
        draft.reminder = now
        draft.estimateSeconds = 1800
        XCTAssertEqual(draft.edits(to: task), [.estimate(1800)], "the title and reminder are not Kannu's to change")
        XCTAssertEqual(draft.estimateLabel, "30m")
    }

    func testTagsAreCommaSeparatedAndCleaned() {
        var draft = TaskFormDraft()
        draft.tagsText = "deep work, #docs,, Docs , " + String(repeating: "x", count: 40)
        XCTAssertEqual(draft.tags, ["deep work", "docs", String(repeating: "x", count: 24)],
                       "a space stays inside a tag; duplicates and blanks go; a long tag is cut")
        draft.tagsText = (1...12).map { "t\($0)" }.joined(separator: ",")
        XCTAssertEqual(draft.tags.count, 10, "at most ten")
    }

    func testAnEstimateFromBrainsCustomSheetShowsInTheMenu() {
        var draft = TaskFormDraft()
        XCTAssertEqual(draft.estimateMenuChoices, TaskFormDraft.estimateChoices)
        draft.estimateSeconds = 45 * 60
        XCTAssertEqual(draft.estimateMenuChoices, [900, 1800, 2700, 3600, 7200, 14_400, 28_800])
        XCTAssertEqual(draft.estimateLabel, "45m")
    }

    func testANewReminderStartsAtTheNextWholeHour() {
        XCTAssertEqual(TaskFormDraft.defaultReminder(now: now, calendar: calendar),
                       Date(timeIntervalSince1970: 1_760_000_000 + 400), "08:53:20 is 400 s before 09:00")
    }

    // MARK: - The typed estimate (David: hours, days and minutes, not only six presets)

    func testATypedEstimateReadsMinutesHoursAndWorkdays() {
        var draft = TaskFormDraft()
        draft.typeEstimate("2d 3h")
        XCTAssertEqual(draft.estimateReading, .length(19 * 3600), "a day is a workday")
        XCTAssertEqual(draft.estimateSeconds, 19 * 3600)
        XCTAssertEqual(draft.estimateEcho, "= 19h")
        draft.typeEstimate("45")
        XCTAssertEqual(draft.estimateSeconds, 45 * 60, "a bare number is minutes")
        draft.typeEstimate("1.5h")
        XCTAssertEqual(draft.estimateSeconds, 90 * 60)
        draft.typeEstimate("1h 30m")
        XCTAssertNil(draft.estimateEcho, "it reads as typed: nothing to echo")
    }

    func testAnUnreadableEstimateWaitsAndKeepsTheLastOne() {
        var draft = TaskFormDraft()
        draft.title = "Write"
        draft.typeEstimate("2h")
        draft.typeEstimate("2hx")
        XCTAssertEqual(draft.estimateReading, .unreadable)
        XCTAssertEqual(draft.estimateSeconds, 2 * 3600, "the last readable length stays")
        XCTAssertFalse(draft.canSave, "fixed first, never dropped without a word")
        draft.typeEstimate("20s")
        XCTAssertEqual(draft.estimateReading, .unreadable, "under a minute")
        draft.typeEstimate("")
        XCTAssertEqual(draft.estimateReading, .none)
        XCTAssertNil(draft.estimateSeconds, "emptied: no estimate")
        XCTAssertTrue(draft.canSave)
    }

    func testPresetsAndLeavingTheFieldWriteItTheStandardWay() {
        var draft = TaskFormDraft()
        draft.chooseEstimate(2 * 3600)
        XCTAssertEqual(draft.estimateText, "2h")
        draft.chooseEstimate(nil)
        XCTAssertEqual(draft.estimateText, "")
        XCTAssertNil(draft.estimateSeconds)
        draft.typeEstimate("90m")
        draft.settleEstimateText()
        XCTAssertEqual(draft.estimateText, "1h 30m")
        draft.typeEstimate("0")
        draft.settleEstimateText()
        XCTAssertEqual(draft.estimateText, "", "0 is no estimate")
    }

    func testAnEditStartsWithItsEstimateTypedAndARemoteOneAsThePrompt() {
        let local = TaskFormDraft(editing: TaskItem(title: "Local", localEstimateSeconds: 3600))
        XCTAssertEqual(local.estimateText, "1h")
        XCTAssertEqual(local.estimatePrompt, "Estimate")
        let jira = TaskFormDraft(editing: TaskItem(source: .jira, title: "J", remote: remote(key: "P-1", estimate: 7200)))
        XCTAssertEqual(jira.estimateText, "")
        XCTAssertEqual(jira.estimatePrompt, "2h from Jira", "the source's own estimate shows until one is typed")
    }

    // MARK: - Tags in use, offered while typing (David: the notch did not offer existing tags)

    func testTheFragmentFollowsTheLastComma() {
        var draft = TaskFormDraft()
        XCTAssertEqual(draft.tagFragment, "")
        XCTAssertEqual(draft.tagsBeforeFragment, [])
        draft.tagsText = "docs, #Urgent,  rev"
        XCTAssertEqual(draft.tagFragment, "rev")
        XCTAssertEqual(draft.tagsBeforeFragment, ["docs", "Urgent"])
        draft.tagsText = "docs, "
        XCTAssertEqual(draft.tagFragment, "", "a comma ends a tag")
        XCTAssertEqual(draft.tagsBeforeFragment, ["docs"])
    }

    func testCompletingATagReplacesWhatWasBeingTyped() {
        var draft = TaskFormDraft()
        draft.tagsText = "docs, rev"
        draft.completeTag("review")
        XCTAssertEqual(draft.tagsText, "docs, review, ", "a comma follows, ready for the next")
        XCTAssertEqual(draft.tags, ["docs", "review"])
        draft.completeTag("#deep work")
        XCTAssertEqual(draft.tags, ["docs", "review", "deep work"], "cleaned as a task keeps it")
        var empty = TaskFormDraft()
        empty.completeTag("docs")
        XCTAssertEqual(empty.tagsText, "docs, ")
        empty.completeTag("   ")
        XCTAssertEqual(empty.tagsText, "docs, ", "nothing left of it: nothing changes")
    }

    func testSuggestionsAreBrainsAndSkipTagsAlreadyTyped() {
        let existing = ["backend", "docs", "review", "urgent"]
        var draft = TaskFormDraft()
        XCTAssertEqual(draft.tagSuggestions(existing: existing).map(\.tag), existing, "the quick picks with nothing typed")
        draft.tagsText = "docs, "
        XCTAssertFalse(draft.tagSuggestions(existing: existing).map(\.tag).contains("docs"), "never one already typed")
        draft.tagsText = "docs, re"
        XCTAssertEqual(draft.tagSuggestions(existing: existing), [.use("review"), .create("re")],
                       "those that start with it, then a new one")
    }

    func testNothingIsOfferedOnceTenTagsAreTyped() {
        var draft = TaskFormDraft()
        draft.tagsText = (1...10).map { "t\($0)" }.joined(separator: ", ") + ", "
        XCTAssertEqual(draft.tagSuggestions(existing: ["other"]), [])
    }
}
