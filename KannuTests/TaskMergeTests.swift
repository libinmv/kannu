//
//  TaskMergeTests.swift
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

/// A sync refreshes what Jira owns and keeps what the user owns: their order, their estimate, the
/// time they recorded and whether they finished or hid a task. Only a complete fetch can say an
/// issue has gone; a failed one changes nothing.
final class TaskMergeTests: XCTestCase {
    private let site = "acme.atlassian.net"
    private let then = Date(timeIntervalSince1970: 1_700_000_000)
    private let now = Date(timeIntervalSince1970: 1_700_003_600)

    private func issue(_ id: String, key: String? = nil, title: String = "Issue", status: String = "To Do",
                       done: Bool = false, estimate: Int? = nil, spent: Int? = nil) -> RemoteIssue {
        RemoteIssue(remoteID: id, key: key ?? "PROJ-\(id)", title: title, status: status, isDoneRemotely: done,
                    estimateSeconds: estimate, spentSeconds: spent)
    }

    private func jiraTask(_ id: String, title: String = "Issue", site: String? = nil,
                          visibility: TaskVisibility = .active) -> TaskItem {
        TaskItem(
            source: .jira,
            title: title,
            remote: RemoteTaskInfo(remoteID: id, key: "PROJ-\(id)", hostScope: site ?? self.site, status: "To Do",
                                   isDoneRemotely: false, remoteEstimateSeconds: nil, remoteSpentSeconds: nil,
                                   gitlabProjectID: nil, gitlabIID: nil, lastSeenAt: then),
            visibility: visibility,
            createdAt: then
        )
    }

    private func merge(_ issues: [RemoteIssue], complete: Bool = true, into tasks: [TaskItem],
                       keepingActive: Set<UUID> = []) -> TaskMerge.Result {
        var counter = 0
        return TaskMerge.apply(.fetched(RemoteFetch(issues: issues, complete: complete)), source: .jira, hostScope: site,
                               to: tasks, now: now, keepingActive: keepingActive, newID: {
                                   counter += 1
                                   return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", counter))!
                               })
    }

    func testAMatchRefreshesWhatJiraOwnsAndKeepsTheRest() {
        var task = jiraTask("1", title: "Old title")
        task.localEstimateSeconds = 1800
        task.segments = [WorkSegment(start: then, end: then.addingTimeInterval(600), origin: .timer)]
        task.logPolicy = .localOnly
        let local = TaskItem(title: "Mine", createdAt: then)

        let result = merge([issue("1", key: "NEW-7", title: "New  title", status: "In Progress", estimate: 7200, spent: 3600)],
                           into: [local, task])

        XCTAssertEqual(result.tasks.map(\.id), [local.id, task.id], "same ids, same order")
        let merged = result.tasks[1]
        XCTAssertEqual(merged.title, "New title")
        XCTAssertEqual(merged.remote?.key, "NEW-7", "a moved issue keeps its task: the match is on the id")
        XCTAssertEqual(merged.remote?.status, "In Progress")
        XCTAssertEqual(merged.remote?.remoteEstimateSeconds, 7200)
        XCTAssertEqual(merged.remote?.remoteSpentSeconds, 3600)
        XCTAssertEqual(merged.remote?.lastSeenAt, now)
        XCTAssertEqual(merged.localEstimateSeconds, 1800, "the user's estimate stays")
        XCTAssertEqual(merged.effectiveEstimateSeconds, 1800, "and still wins")
        XCTAssertEqual(merged.segments, task.segments, "recorded time stays")
        XCTAssertEqual(merged.logPolicy, .localOnly)
        XCTAssertEqual(merged.createdAt, then)
        XCTAssertEqual(result.tasks[0], local, "a local task is never touched")
        XCTAssertEqual(result.updated, 1)
        XCTAssertEqual(result.added, 0)
        XCTAssertEqual(result.gone, 0)
    }

    func testAnUnchangedIssueIsNotAChange() {
        let task = jiraTask("1")
        let result = merge([issue("1")], into: [task])
        XCTAssertEqual(result.updated, 0)
        XCTAssertFalse(result.changed, "only last-seen moved: nothing worth saving")
        XCTAssertEqual(result.tasks[0].remote?.lastSeenAt, now)
    }

    func testNewIssuesAreAppendedInJirasOrder() {
        let existing = [TaskItem(title: "Mine", createdAt: then), jiraTask("1")]
        let result = merge([issue("3", title: "Third"), issue("1"), issue("2", title: "Second")], into: existing)
        XCTAssertEqual(result.tasks.map(\.title), ["Mine", "Issue", "Third", "Second"])
        XCTAssertEqual(result.added, 2)
        let added = result.tasks[2]
        XCTAssertEqual(added.source, .jira)
        XCTAssertEqual(added.visibility, .active)
        XCTAssertEqual(added.logPolicy, .ask)
        XCTAssertNil(added.localEstimateSeconds)
        XCTAssertEqual(added.remote?.hostScope, site)
        XCTAssertEqual(added.remote?.remoteID, "3")
        XCTAssertEqual(added.createdAt, now)
    }

    func testAnIssueListedTwiceCountsOnce() {
        let result = merge([issue("5", title: "First"), issue("5", title: "Second")], into: [])
        XCTAssertEqual(result.tasks.map(\.title), ["First"])
        XCTAssertEqual(result.added, 1)
    }

    func testACompleteFetchMarksOnlyActiveMissingTasksGone() {
        let tasks = [
            jiraTask("1"),
            jiraTask("2"),
            jiraTask("3", visibility: .done),
            jiraTask("4", visibility: .hidden),
            TaskItem(title: "Mine", createdAt: then),
        ]
        let result = merge([issue("1")], into: tasks)
        XCTAssertEqual(result.tasks.map(\.visibility), [.active, .gone, .done, .hidden, .active])
        XCTAssertEqual(result.gone, 1)
    }

    func testACappedFetchMarksNothingGone() {
        let tasks = [jiraTask("1"), jiraTask("2")]
        let result = merge([issue("1")], complete: false, into: tasks)
        XCTAssertEqual(result.tasks.map(\.visibility), [.active, .active])
        XCTAssertEqual(result.gone, 0)
    }

    func testAFailedSyncChangesNothing() {
        let tasks = [jiraTask("1"), TaskItem(title: "Mine", createdAt: then)]
        let result = TaskMerge.apply(.failed, source: .jira, hostScope: site, to: tasks, now: now, keepingActive: [])
        XCTAssertEqual(result.tasks, tasks)
        XCTAssertFalse(result.changed)
    }

    func testHiddenAndDoneTasksKeepTheirStateWhenReturned() {
        let tasks = [jiraTask("1", visibility: .hidden), jiraTask("2", visibility: .done)]
        let result = merge([issue("1", status: "In Progress"), issue("2", status: "In Progress")], into: tasks)
        XCTAssertEqual(result.tasks.map(\.visibility), [.hidden, .done])
        XCTAssertEqual(result.tasks.map { $0.remote?.status }, ["In Progress", "In Progress"])
    }

    func testAGoneTaskThatComesBackIsActiveAgainInItsPlace() {
        let tasks = [jiraTask("1"), jiraTask("2", visibility: .gone), jiraTask("3")]
        let result = merge([issue("1"), issue("2"), issue("3")], into: tasks)
        XCTAssertEqual(result.tasks.map(\.visibility), [.active, .active, .active])
        XCTAssertEqual(result.tasks.map(\.id), tasks.map(\.id))
        XCTAssertEqual(result.updated, 1)
    }

    func testAnotherSitesTasksGoOnAnySuccessfulFetch() {
        let old = jiraTask("1", site: "old.atlassian.net")
        let oldHidden = jiraTask("2", site: "old.atlassian.net", visibility: .hidden)
        let capped = merge([issue("1")], complete: false, into: [old, oldHidden])
        XCTAssertEqual(capped.tasks.count, 3, "the same id on another site is a different issue")
        XCTAssertEqual(capped.tasks[0].visibility, .gone, "even a capped fetch: that site is not connected")
        XCTAssertEqual(capped.tasks[1].visibility, .hidden, "only active tasks become gone")
        XCTAssertEqual(capped.tasks[2].remote?.hostScope, site)
        XCTAssertEqual(capped.added, 1)
        XCTAssertEqual(capped.gone, 1)
    }

    func testTheTimedTaskNeverBecomesGone() {
        // PROJ-1 is being timed when it is resolved in Jira (a complete fetch without it), and
        // PROJ-9 when the user reconnects to another site. Both rows hold the list's Stop button,
        // so both stay in the order; the untimed PROJ-2 goes as usual.
        let timed = jiraTask("1")
        let untimed = jiraTask("2")
        let otherSite = jiraTask("9", site: "old.atlassian.net")
        let result = merge([], into: [timed, untimed, otherSite], keepingActive: [timed.id, otherSite.id])
        XCTAssertEqual(result.tasks.map(\.visibility), [.active, .gone, .active])
        XCTAssertEqual(result.gone, 1)

        let afterTiming = merge([], into: result.tasks)
        XCTAssertEqual(afterTiming.tasks.map(\.visibility), [.gone, .gone, .gone], "the next sync after timing ends decides")
    }

    func testOtherSourcesAreNeverTouched() {
        var gitlab = TaskItem(source: .gitlab, title: "MR", createdAt: then)
        gitlab.remote = RemoteTaskInfo(remoteID: "1", key: "group/app!1", hostScope: "gitlab.com", status: "opened",
                                       isDoneRemotely: false, remoteEstimateSeconds: nil, remoteSpentSeconds: nil,
                                       gitlabProjectID: 1, gitlabIID: 1, lastSeenAt: then)
        let result = merge([issue("1")], into: [gitlab])
        XCTAssertEqual(result.tasks.first, gitlab, "a GitLab item with the same id is not a Jira issue")
        XCTAssertEqual(result.added, 1)
    }

    // MARK: - GitLab

    private let gitlabServer = "https://gitlab.example.com"

    private func gitlabItem(_ id: Int, kind: GitLabKind, iid: Int = 1, status: String = "opened",
                            webURL: String? = nil) -> RemoteIssue {
        let mark = kind == .issue ? "#" : "!"
        return RemoteIssue(remoteID: GitLabAPI.remoteID(kind: kind, id: id), key: "group/app\(mark)\(iid)", title: "Item \(id)",
                           status: status, isDoneRemotely: false, estimateSeconds: nil, spentSeconds: nil,
                           gitlab: RemoteIssue.GitLabRef(kind: kind, projectID: 8, iid: iid, webURL: webURL))
    }

    private func mergeGitLab(_ items: [RemoteIssue], complete: Bool = true, server: String? = nil,
                             into tasks: [TaskItem]) -> TaskMerge.Result {
        TaskMerge.apply(.fetched(RemoteFetch(issues: items, complete: complete)), source: .gitlab,
                        hostScope: server ?? gitlabServer, to: tasks, now: now, keepingActive: [])
    }

    func testAGitLabItemKeepsWhereItLives() {
        let link = "https://gitlab.example.com/group/app/-/merge_requests/12"
        let result = mergeGitLab([gitlabItem(31, kind: .mergeRequest, iid: 12, webURL: link)], into: [])
        let remote = result.tasks.first?.remote
        XCTAssertEqual(result.tasks.first?.source, .gitlab)
        XCTAssertEqual(remote?.gitlabKind, .mergeRequest)
        XCTAssertEqual(remote?.gitlabProjectID, 8)
        XCTAssertEqual(remote?.gitlabIID, 12)
        XCTAssertEqual(remote?.gitlabWebURL, link)
        XCTAssertEqual(remote?.hostScope, gitlabServer)

        let moved = mergeGitLab([gitlabItem(31, kind: .mergeRequest, iid: 14, status: "review requested")], into: result.tasks)
        XCTAssertEqual(moved.tasks.map(\.id), result.tasks.map(\.id), "matched on the global id")
        XCTAssertEqual(moved.tasks.first?.remote?.gitlabIID, 14, "a moved merge request gets its new number")
        XCTAssertEqual(moved.tasks.first?.remote?.key, "group/app!14")
        XCTAssertNil(moved.tasks.first?.remote?.gitlabWebURL, "a page the answer no longer vouches for is dropped")
        XCTAssertEqual(moved.updated, 1)
    }

    func testAnIssueAndAMergeRequestWithTheSameGlobalIDAreTwoTasks() {
        let result = mergeGitLab([gitlabItem(31, kind: .issue), gitlabItem(31, kind: .mergeRequest)], into: [])
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.tasks.compactMap { $0.remote?.gitlabKind }, [.issue, .mergeRequest])
    }

    func testAMergeRequestListedTwiceIsOneTask() {
        let result = mergeGitLab([gitlabItem(31, kind: .mergeRequest, status: "assigned to you"),
                                  gitlabItem(31, kind: .mergeRequest, status: "review requested")], into: [])
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(result.tasks.first?.remote?.status, "assigned to you", "the first listing wins")
    }

    func testSwitchingGitLabServerMakesTheOldServersTasksGone() {
        let first = mergeGitLab([gitlabItem(76, kind: .issue), gitlabItem(31, kind: .mergeRequest)], into: [])
        let switched = mergeGitLab([gitlabItem(76, kind: .issue)], complete: false, server: "https://gitlab.com", into: first.tasks)
        XCTAssertEqual(switched.tasks.count, 3, "the same id on another server is a different item")
        XCTAssertEqual(switched.tasks.prefix(2).map(\.visibility), [.gone, .gone], "even a capped fetch: that server is not connected")
        XCTAssertEqual(switched.tasks[2].remote?.hostScope, "https://gitlab.com")
        XCTAssertEqual(switched.gone, 2)
    }

    func testGitLabAndJiraNeverTouchEachOther() {
        let jira = jiraTask("76")
        let gitlab = mergeGitLab([gitlabItem(76, kind: .issue)], into: [jira])
        XCTAssertEqual(gitlab.tasks.first, jira, "a GitLab sync leaves Jira tasks alone, even with a complete fetch")
        let jiraAgain = merge([], into: gitlab.tasks)
        XCTAssertEqual(jiraAgain.tasks.map(\.visibility), [.gone, .active], "and a complete Jira fetch leaves GitLab tasks alone")
    }

    func testIncludeMergeRequestsOffTakesThemOutAndOnBringsThemBack() {
        let both = mergeGitLab([gitlabItem(76, kind: .issue), gitlabItem(31, kind: .mergeRequest)], into: [])
        let issuesOnly = mergeGitLab([gitlabItem(76, kind: .issue)], into: both.tasks)
        XCTAssertEqual(issuesOnly.tasks.map(\.visibility), [.active, .gone])
        let back = mergeGitLab([gitlabItem(76, kind: .issue), gitlabItem(31, kind: .mergeRequest)], into: issuesOnly.tasks)
        XCTAssertEqual(back.tasks.map(\.visibility), [.active, .active])
        XCTAssertEqual(back.tasks.map(\.id), both.tasks.map(\.id), "the same task, in its place, with its recorded time")
    }

    func testAnEditMadeDuringTheRequestSurvives() {
        // The merge runs against the list as it is when the answer lands, not as it was when the
        // request went out: a task added and a task reordered meanwhile are both still there.
        let before = [jiraTask("1"), jiraTask("2")]
        let added = TaskItem(title: "Added while syncing", createdAt: now)
        let current = [added, before[1], before[0]]
        let result = merge([issue("1"), issue("2")], into: current)
        XCTAssertEqual(result.tasks.map(\.id), current.map(\.id))
    }
}
