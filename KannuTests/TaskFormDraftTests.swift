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

    func testTheEstimatePresetsAreTheChevronsOwn() {
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

    func testATypedEstimateShowsAmongThePresets() {
        var draft = TaskFormDraft()
        XCTAssertEqual(draft.estimateMenuChoices, TaskFormDraft.estimateChoices)
        draft.typeEstimate("45m")
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

    // MARK: - The bell: this task's notification (David, 2026-10-23)

    func testTheBellStartsOnAndFollowsTheTask() {
        XCTAssertTrue(TaskFormDraft().notifies, "a new task's reminder notifies")
        let muted = TaskItem(title: "Quiet", scheduledAt: now, reminderMuted: true)
        XCTAssertFalse(TaskFormDraft(editing: muted).notifies)
    }

    func testTurningTheBellOffIsAnEditBeforeTheSchedule() {
        let task = TaskItem(title: "Call", scheduledAt: now)
        var draft = TaskFormDraft(editing: task)
        draft.notifies = false
        draft.reminder = now.addingTimeInterval(3600)
        XCTAssertEqual(draft.edits(to: task), [.notifies(false), .schedule(now.addingTimeInterval(3600))],
                       "off goes first, so a muted reminder is never sent and taken back")
        draft.notifies = true
        XCTAssertEqual(draft.edits(to: task), [.schedule(now.addingTimeInterval(3600))])
    }

    func testARemoteTaskHasNoBell() {
        var draft = TaskFormDraft(editing: TaskItem(source: .jira, title: "PROJ-1", remote: remote(key: "PROJ-1")))
        draft.notifies = false
        XCTAssertEqual(draft.edits(to: TaskItem(source: .jira, title: "PROJ-1", remote: remote(key: "PROJ-1"))), [])
    }

    // MARK: - What was typed survives the form closing (David, 2026-10-23)

    func testANewTasksTypedTextIsKeptAndAnEmptyFormIsNot() {
        var kept = KeptTaskFormDrafts()
        var draft = TaskFormDraft()
        kept.keep(draft, baseline: nil)
        XCTAssertTrue(kept.isEmpty, "an untouched form keeps nothing")

        draft.title = "preply"
        draft.tagsText = "work"
        kept.keep(draft, baseline: nil)
        XCTAssertEqual(kept.draft(editing: nil, baseline: nil, now: now, calendar: calendar), draft,
                       "opening a task's form or the notch closing does not lose a new task's text")

        draft.title = ""
        draft.tagsText = ""
        kept.keep(draft, baseline: nil)
        XCTAssertNil(kept.draft(editing: nil, baseline: nil, now: now, calendar: calendar), "clearing everything forgets it")
    }

    func testAnEditsDraftComesBackOnlyWhileItsTaskIsUnchanged() {
        let task = TaskItem(title: "preply", localEstimateSeconds: 3600)
        let baseline = TaskFormDraft(editing: task)
        var kept = KeptTaskFormDrafts()
        var draft = baseline
        draft.title = "preply lesson"
        kept.keep(draft, baseline: baseline)
        XCTAssertEqual(kept.draft(editing: task.id, baseline: baseline, now: now, calendar: calendar), draft)

        var renamedElsewhere = task
        renamedElsewhere.title = "preply (Brain)"
        XCTAssertNil(kept.draft(editing: task.id, baseline: TaskFormDraft(editing: renamedElsewhere), now: now, calendar: calendar),
                     "a task changed since opens fresh, so Save never undoes that change")
        XCTAssertNil(kept.draft(editing: task.id, baseline: nil, now: now, calendar: calendar), "a task that is gone has no draft")

        kept.keep(baseline, baseline: baseline)
        XCTAssertNil(kept.draft(editing: task.id, baseline: baseline, now: now, calendar: calendar), "an edit back to the task keeps nothing")
    }

    func testForgettingOneDraftKeepsTheOthers() {
        let task = TaskItem(title: "Edit me")
        var edit = TaskFormDraft(editing: task)
        edit.title = "Edited"
        var new = TaskFormDraft()
        new.title = "New one"
        var kept = KeptTaskFormDrafts()
        kept.keep(edit, baseline: TaskFormDraft(editing: task))
        kept.keep(new, baseline: nil)
        kept.forget(editing: task.id)
        XCTAssertNil(kept.draft(editing: task.id, baseline: TaskFormDraft(editing: task), now: now, calendar: calendar))
        XCTAssertEqual(kept.draft(editing: nil, baseline: nil, now: now, calendar: calendar), new)
    }

    func testTheBellIsNoEditWithoutAReminder() {
        let task = TaskItem(title: "Call", scheduledAt: now)
        var draft = TaskFormDraft(editing: task)
        draft.notifies = false
        draft.reminder = nil
        XCTAssertEqual(draft.edits(to: task), [.schedule(nil)],
                       "removing the reminder clears the mute with it; a mute with no reminder has no bell to show it")
    }

    /// A reminder picked before the notch closed that has passed since comes back as the next whole
    /// hour, so Add never saves one that can no longer notify. An edit's own reminder is left.
    func testAKeptReminderThatHasPassedMovesToTheNextHour() {
        var kept = KeptTaskFormDrafts()
        var new = TaskFormDraft()
        new.title = "Call"
        new.reminder = now.addingTimeInterval(-3600)
        kept.keep(new, baseline: nil)
        XCTAssertEqual(kept.draft(editing: nil, baseline: nil, now: now, calendar: calendar)?.reminder,
                       TaskFormDraft.defaultReminder(now: now, calendar: calendar))

        let overdue = TaskItem(title: "Overdue", scheduledAt: now.addingTimeInterval(-7200))
        let baseline = TaskFormDraft(editing: overdue)
        var edit = baseline
        edit.title = "Overdue, renamed"
        kept.keep(edit, baseline: baseline)
        XCTAssertEqual(kept.draft(editing: overdue.id, baseline: baseline, now: now, calendar: calendar)?.reminder,
                       overdue.scheduledAt, "the task's own overdue time is not moved")
    }

    /// Brain's New Task, opened again on what was typed or added: a reminder that has passed moves to
    /// the next whole hour; one still to come, none, or the one kept stays as it is.
    func testAPassedReminderMovesToTheNextHour() {
        var draft = TaskFormDraft()
        draft.reminder = now.addingTimeInterval(-60)
        draft.movePassedReminder(now: now, calendar: calendar)
        XCTAssertEqual(draft.reminder, TaskFormDraft.defaultReminder(now: now, calendar: calendar))

        let tomorrow = now.addingTimeInterval(86_400)
        draft.reminder = tomorrow
        draft.movePassedReminder(now: now, calendar: calendar)
        XCTAssertEqual(draft.reminder, tomorrow, "a reminder still to come is the user's")

        draft.reminder = nil
        draft.movePassedReminder(now: now, calendar: calendar)
        XCTAssertNil(draft.reminder, "no reminder is not given one")

        let own = now.addingTimeInterval(-7200)
        draft.reminder = own
        draft.movePassedReminder(now: now, calendar: calendar, keeping: own)
        XCTAssertEqual(draft.reminder, own, "the reminder kept is left, overdue or not")

        draft.reminder = now.addingTimeInterval(-60)
        draft.movePassedReminder(now: now, calendar: calendar, keeping: own)
        XCTAssertEqual(draft.reminder, TaskFormDraft.defaultReminder(now: now, calendar: calendar),
                       "a passed reminder other than the one kept still moves")

        draft.reminder = now
        draft.movePassedReminder(now: now, calendar: calendar)
        XCTAssertEqual(draft.reminder, TaskFormDraft.defaultReminder(now: now, calendar: calendar),
                       "a reminder due this very moment has passed: it moves")
    }

    /// Brain's typed estimate (New Task, a task's Time row, Set Estimate) reads what it saves: a
    /// Jira task with none of Kannu's shows its source's as the prompt; a length settles the
    /// standard way; nothing or 0 is no estimate; text it cannot read keeps the last readable value
    /// and Save waits.
    func testBrainsTypedEstimateReadsWhatItSaves() {
        let jira = TaskItem(source: .jira, title: "Fix login", remote: remote(key: "ABC-1", estimate: 7200))
        let page = TaskFormDraft(editing: jira)
        XCTAssertEqual(page.estimateText, "")
        XCTAssertEqual(page.estimatePrompt, "2h from Jira")
        var draft = TaskFormDraft()
        draft.title = "Write notes"
        draft.typeEstimate("1.5h")
        XCTAssertEqual(draft.estimateReading, .length(5400))
        draft.settleEstimateText()
        XCTAssertEqual(draft.estimateText, "1h 30m")
        draft.typeEstimate("")
        XCTAssertEqual(draft.estimateReading, .none)
        XCTAssertNil(draft.estimateSeconds)
        draft.typeEstimate("0")
        XCTAssertEqual(draft.estimateReading, .none, "0 removes the estimate everywhere now")
        draft.typeEstimate("2h")
        draft.typeEstimate("2hx")
        XCTAssertEqual(draft.estimateReading, .unreadable)
        XCTAssertEqual(draft.estimateSeconds, 7200, "the last readable length stays")
        XCTAssertFalse(draft.canSave, "Add and Save wait for it to be fixed")
    }
}
