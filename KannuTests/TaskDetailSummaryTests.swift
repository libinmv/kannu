//
//  TaskDetailSummaryTests.swift
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

/// The words on the timer tab's expanded task card. The title is the issue's own and is never
/// prefixed by a key (a GitLab path key once ate the whole card); the key is short; the facts come
/// most important first, each with its icon; the user's own name is never a fact.
final class TaskDetailSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 08:53:20 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func remote(key: String, status: String = "", kind: GitLabKind? = nil, iid: Int? = nil,
                        spent: Int? = nil, estimate: Int? = nil, category: String? = nil,
                        labels: [String]? = nil) -> RemoteTaskInfo {
        RemoteTaskInfo(remoteID: key, key: key, hostScope: "https://example.test", status: status,
                       isDoneRemotely: false, remoteEstimateSeconds: estimate, remoteSpentSeconds: spent,
                       gitlabProjectID: nil, gitlabIID: iid, lastSeenAt: now, gitlabKind: kind,
                       gitlabWebURL: nil, statusCategory: category, labels: labels)
    }

    private func summary(_ task: TaskItem, tracked: Int = 0, selfNames: Set<String> = []) -> TaskDetailSummary {
        TaskDetailSummary(task: task, tracked: tracked, now: now, selfNames: selfNames, calendar: calendar)
    }

    /// "20 Oct" as the card formats it, so the assertions hold in every locale.
    private func day(_ ymd: String) -> String {
        RemoteTaskInfo.dayDate(ymd, calendar: calendar)!.formatted(TaskDetailSummary.dayStyle(calendar))
    }

    // MARK: - Title and key

    func testTheTitleIsTheIssuesOwnAndTheGitLabKeyIsShort() {
        let task = TaskItem(source: .gitlab, title: "hc: convert AWS EC2 instance checks to datapoints",
                            remote: remote(key: "discern_security/applications/ds-vendors#4264", status: "opened", kind: .issue, iid: 4264))
        let card = summary(task)
        XCTAssertEqual(card.title, "hc: convert AWS EC2 instance checks to datapoints")
        XCTAssertEqual(card.shortKey, "ds-vendors #4264", "the project's last path component and the number")
    }

    func testShortKeysForAMergeRequestAnIDOnlyProjectJiraAndLocal() {
        let request = TaskItem(source: .gitlab, title: "Add tests",
                               remote: remote(key: "group/app!12", status: "opened", kind: .mergeRequest, iid: 12))
        XCTAssertEqual(summary(request).shortKey, "app !12")
        var byID = TaskItem(source: .gitlab, title: "Known by id", remote: remote(key: "#7", kind: .issue, iid: 7))
        byID.remote?.gitlabProjectID = 42
        XCTAssertEqual(summary(byID).shortKey, "Project 42 #7")
        XCTAssertEqual(summary(TaskItem(source: .jira, title: "J", remote: remote(key: "PROJ-123"))).shortKey, "PROJ-123")
        XCTAssertNil(summary(TaskItem(title: "Mine")).shortKey)
    }

    // MARK: - Status, draft and labels

    func testStatusReadsTheSourcesWordWithTheFacetsPhase() {
        let jira = TaskItem(source: .jira, title: "J", remote: remote(key: "P-1", status: "In Review", category: "indeterminate"))
        XCTAssertEqual(summary(jira).status, .init(name: "In Review", phase: .inProgress))
        let gitlab = TaskItem(source: .gitlab, title: "G", remote: remote(key: "g/a#1", status: "opened", kind: .issue, iid: 1))
        XCTAssertEqual(summary(gitlab).status, .init(name: "Open", phase: .toDo))
        XCTAssertEqual(summary(TaskItem(title: "Local")).status, .init(name: "To Do", phase: .toDo))
        var started = TaskItem(title: "Started")
        started.segments = [WorkSegment(start: now, end: now.addingTimeInterval(60), origin: .timer)]
        XCTAssertEqual(summary(started).status, .init(name: "In Progress", phase: .inProgress))
    }

    func testAClosedTaskIsClosedWhateverItsSourceSaid() {
        var closedRemotely = remote(key: "P-2", status: "Done", category: "done")
        closedRemotely.isDoneRemotely = true
        XCTAssertEqual(summary(TaskItem(source: .jira, title: "J", remote: closedRemotely)).status,
                       .init(name: "Closed", phase: .closed), "its server says so")
        let gone = TaskItem(source: .gitlab, title: "G", remote: remote(key: "g/a#2", status: "opened", kind: .issue, iid: 2),
                            visibility: .gone)
        XCTAssertEqual(summary(gone).status, .init(name: "Closed", phase: .closed), "no longer listed is ended")
        let archived = TaskItem(source: .gitlab, title: "A", remote: remote(key: "g/a#3", status: "opened", kind: .issue, iid: 3),
                                visibility: .archived)
        XCTAssertEqual(summary(archived).status.phase, .closed)
        XCTAssertEqual(summary(TaskItem(title: "Mine", visibility: .done)).status, .init(name: "Done", phase: .closed))
    }

    func testADraftMergeRequestSaysSo() {
        var info = remote(key: "g/a!3", status: "review requested", kind: .mergeRequest, iid: 3)
        info.isDraft = true
        XCTAssertTrue(summary(TaskItem(source: .gitlab, title: "D", remote: info)).isDraft)
        XCTAssertFalse(summary(TaskItem(title: "Local")).isDraft)
    }

    func testScopedLabelsShowTheirValueAndTagsComeAfter() {
        let task = TaskItem(source: .gitlab, title: "L",
                            remote: remote(key: "g/a#1", kind: .issue, iid: 1, labels: ["workflow::sprint_backlog", "backend", "a::b::c", "odd::"]),
                            tags: ["urgent"])
        XCTAssertEqual(summary(task).labels, ["sprint_backlog", "backend", "c", "odd::", "#urgent"])
        XCTAssertEqual(TaskDetailSummary.labelDisplay("plain"), "plain")
    }

    // MARK: - Facts

    func testTheFactsComeMostImportantFirstEachWithItsIcon() {
        var info = remote(key: "g/a#9", status: "opened", kind: .issue, iid: 9)
        info.dueDate = RemoteTaskInfo.dayDate("2025-10-20", calendar: calendar)
        info.healthStatus = "at_risk"
        info.milestone = "Sprint 42"
        info.iteration = "Iteration 5"
        info.weight = 8
        info.parentTitle = "Health Check Migration"
        info.assignee = "Kim Lee"
        info.checklistDone = 2
        info.checklistTotal = 5
        info.linkedMergeRequests = 2
        info.commentCount = 1
        info.updatedAt = now.addingTimeInterval(-3 * 3600)
        let facts = summary(TaskItem(source: .gitlab, title: "All of it", remote: info)).facts
        XCTAssertEqual(facts.map(\.text), [
            "Due \(day("2025-10-20"))", "At risk", "2 linked MRs", "Sprint 42", "Iteration 5", "Weight 8",
            "Health Check Migration", "Kim Lee", "2 of 5 done", "1 comment", "Updated 3h ago",
        ])
        XCTAssertEqual(facts.map(\.icon), [
            "calendar", "heart.text.square", "arrow.triangle.pull", "flag", "hourglass", "scalemass",
            "square.stack", "person", "checklist", "bubble.left", "clock",
        ])
        // David: the linked MRs open their list, so the fact is a button within the four shown.
        XCTAssertEqual(facts.filter { $0.action != nil }.map(\.text), ["2 linked MRs"])
        XCTAssertEqual(facts[2].action, .linkedMergeRequests)
        XCTAssertEqual(facts.filter(\.isAlert).map(\.text), ["At risk"], "only what needs attention is orange")
    }

    func testTheUsersOwnNameIsNeverAFactButSomeoneElsesIs() {
        var mine = remote(key: "g/a#1", status: "opened", kind: .issue, iid: 1)
        mine.assignee = "David Mundackal"
        XCTAssertEqual(summary(TaskItem(source: .gitlab, title: "Mine", remote: mine), selfNames: ["david mundackal"]).facts, [],
                       "every issue on the list is assigned to the user: their name says nothing")

        var review = remote(key: "g/a!4", status: "review requested", kind: .mergeRequest, iid: 4)
        review.assignee = "David Mundackal"
        review.author = "Kim Lee"
        review.hasConflicts = true
        let facts = summary(TaskItem(source: .gitlab, title: "Review", remote: review), selfNames: ["David Mundackal"]).facts
        XCTAssertEqual(facts.map(\.text), ["Conflicts", "Kim Lee"], "the author asking for review, and the conflicts first")
        XCTAssertEqual(facts.first, .init(icon: "exclamationmark.triangle", text: "Conflicts", isAlert: true))
    }

    func testHealthWords() {
        XCTAssertEqual(TaskDetailSummary.healthText("on_track")?.text, "On track")
        XCTAssertEqual(TaskDetailSummary.healthText("on_track")?.isAlert, false)
        XCTAssertEqual(TaskDetailSummary.healthText("needs_attention")?.isAlert, true)
        XCTAssertNil(TaskDetailSummary.healthText("unknown"), "a word this version does not know is not shown")
    }

    func testRelativeTimes() {
        func ago(_ seconds: TimeInterval) -> String { TaskDetailSummary.ago(now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        XCTAssertEqual(ago(30), "just now")
        XCTAssertEqual(ago(5 * 60), "5m ago")
        XCTAssertEqual(ago(3 * 3600), "3h ago")
        XCTAssertEqual(ago(12 * 3600), "yesterday", "08:53 minus 12 h is the evening before")
        XCTAssertEqual(ago(4 * 86_400), "4d ago")
        XCTAssertEqual(ago(20 * 86_400), "2w ago")
        XCTAssertEqual(ago(90 * 86_400), now.addingTimeInterval(-90 * 86_400).formatted(TaskDetailSummary.dayStyle(calendar)))
    }

    func testARemoteDueDateIsOverdueFromTheNextDay() {
        var info = remote(key: "g/a#1", kind: .issue, iid: 1)
        info.dueDate = RemoteTaskInfo.dayDate("2025-10-09", calendar: calendar)   // today
        XCTAssertEqual(summary(TaskItem(source: .gitlab, title: "T", remote: info)).facts.first,
                       .init(icon: "calendar", text: "Due today", isAlert: false))
        info.dueDate = RemoteTaskInfo.dayDate("2025-10-08", calendar: calendar)
        XCTAssertEqual(summary(TaskItem(source: .gitlab, title: "Y", remote: info)).facts.first,
                       .init(icon: "calendar", text: "Overdue \(day("2025-10-08"))", isAlert: true))
    }

    func testALocalTaskShowsItsReminderAndItsOwnTime() {
        var task = TaskItem(title: "Local", scheduledAt: now.addingTimeInterval(2 * 3600))
        task.segments = [
            WorkSegment(start: now.addingTimeInterval(-3 * 86_400), end: now.addingTimeInterval(-3 * 86_400 + 600), origin: .timer),
            WorkSegment(start: now.addingTimeInterval(-26 * 3600), end: now.addingTimeInterval(-25 * 3600), origin: .timer),
        ]
        let facts = summary(task).facts
        XCTAssertEqual(facts.count, 3)
        XCTAssertTrue(facts[0].text.hasPrefix("Due Today "), facts[0].text)
        XCTAssertEqual(facts[1], .init(icon: "stopwatch", text: "Timed yesterday"))
        XCTAssertEqual(facts[2], .init(icon: "list.number", text: "2 sessions"))
        let late = TaskItem(title: "Late", scheduledAt: now.addingTimeInterval(-3600))
        XCTAssertTrue(summary(late).facts[0].isAlert)
    }

    func testALocalTaskNeverTimedSaysSo() {
        // David: a local task with no time showed nothing between its title and Start.
        XCTAssertEqual(summary(TaskItem(title: "Fresh")).note, "No time recorded yet. Start the task to track it.")
        XCTAssertEqual(summary(TaskItem(title: "Reminded", scheduledAt: now.addingTimeInterval(3600))).note,
                       "No time recorded yet. Start the task to track it.", "a reminder is not time")
        var timed = TaskItem(title: "Timed")
        timed.segments = [WorkSegment(start: now.addingTimeInterval(-600), end: now, origin: .timer)]
        XCTAssertNil(summary(timed).note)
        XCTAssertNil(summary(TaskItem(title: "Running"), tracked: 30).note, "time running now is time")
        XCTAssertNil(summary(TaskItem(source: .jira, title: "J", remote: remote(key: "P-1"))).note,
                     "a remote task has its own facts; its time may live on the server")
    }

    // MARK: - Time, delete, open

    func testTimeShowsOnlyWhenItSaysSomething() {
        let local = TaskItem(title: "Over", localEstimateSeconds: 30 * 60)
        let over = summary(local, tracked: 40 * 60)
        XCTAssertEqual(over.time, "40m of 30m")
        XCTAssertEqual(over.overtime, "10m over")
        XCTAssertTrue(over.showsTime)
        XCTAssertFalse(summary(TaskItem(title: "Fresh")).showsTime, "no estimate and nothing tracked: nothing beside Start")
        XCTAssertTrue(summary(TaskItem(title: "Tracked"), tracked: 300).showsTime)
        XCTAssertTrue(summary(TaskItem(title: "Estimated", localEstimateSeconds: 3600)).showsTime)
    }

    func testOnlyALocalTaskCanBeDeletedAndARemoteOneOpens() {
        let local = summary(TaskItem(title: "Mine"))
        XCTAssertTrue(local.canDelete)
        XCTAssertNil(local.browseLabel)
        let jira = summary(TaskItem(source: .jira, title: "J", remote: remote(key: "P-1")))
        XCTAssertFalse(jira.canDelete, "a remote task would come back on the next sync")
        XCTAssertEqual(jira.browseLabel, "Open in Jira")
        let gitlab = summary(TaskItem(source: .gitlab, title: "G", remote: remote(key: "g/a#1", kind: .issue, iid: 1)))
        XCTAssertEqual(gitlab.browseLabel, "Open in GitLab")
    }
}
