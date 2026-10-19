//
//  TaskRowCaptionTests.swift
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

/// The line under a task's title in Brain's lists. David: the Task list "is a mess" — a row led
/// with "discern_security/applications/ds-vendors#4326" and ran to eight parts. Now it leads with
/// the short key, drops what says nothing, and leaves the rest to the task's own page.
final class TaskRowCaptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 08:53:20 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func remote(key: String, status: String = "", kind: GitLabKind? = nil, iid: Int? = nil,
                        spent: Int? = nil, estimate: Int? = nil) -> RemoteTaskInfo {
        RemoteTaskInfo(remoteID: key, key: key, hostScope: "https://example.test", status: status,
                       isDoneRemotely: false, remoteEstimateSeconds: estimate, remoteSpentSeconds: spent,
                       gitlabProjectID: nil, gitlabIID: iid, lastSeenAt: now, gitlabKind: kind,
                       gitlabWebURL: nil, statusCategory: nil, labels: nil)
    }

    private func caption(_ task: TaskItem, tracked: Int = 0, timing: TaskRowCaption.Timing? = nil,
                         onProjectPage: Bool = false) -> TaskRowCaption {
        TaskRowCaption(task: task, tracked: tracked, timing: timing, now: now, onProjectPage: onProjectPage, calendar: calendar)
    }

    private var gitlabIssue: TaskItem {
        TaskItem(source: .gitlab, title: "Convert the checks",
                 remote: remote(key: "discern_security/applications/ds-vendors#4326", status: "opened", kind: .issue, iid: 4326, spent: 3 * 3600))
    }

    func testAGitLabRowLeadsWithTheShortKeyAndDropsOpen() {
        XCTAssertEqual(caption(gitlabIssue).text, "ds-vendors #4326",
                       "no full path, no \"Open\", nothing tracked or estimated, and GitLab's own time is on the task's page")
        XCTAssertEqual(caption(gitlabIssue, onProjectPage: true).text, "#4326", "its project's page already names the project")
    }

    func testAMergeRequestKeepsAStatusThatSaysSomething() {
        let mr = TaskItem(source: .gitlab, title: "Fix the login",
                          remote: remote(key: "group/app!12", status: "review requested", kind: .mergeRequest, iid: 12))
        XCTAssertEqual(caption(mr).text, "app !12 · Review requested")
    }

    func testTimeAndOvertime() {
        let jira = TaskItem(source: .jira, title: "Ship it", remote: remote(key: "PROJ-7", status: "In Progress", estimate: 3600))
        let over = caption(jira, tracked: 90 * 60, timing: .running)
        XCTAssertEqual(over.text, "PROJ-7 · In Progress · Timing now · 1h 30m of 1h · 30m over")
        XCTAssertEqual(over.segments.filter(\.isAlert).map(\.text), ["30m over"], "only the overtime is orange")
        XCTAssertEqual(caption(jira, onProjectPage: true).text, "PROJ-7 · In Progress · 0m of 1h", "a Jira key is short already")
        let local = TaskItem(title: "Write", tags: ["docs", "urgent"])
        XCTAssertEqual(caption(local, tracked: 30, timing: .paused).text, "Paused · #docs #urgent",
                       "under a minute and no estimate: no \"No estimate\" noise")
        XCTAssertEqual(caption(local, tracked: 42 * 60).text, "42m tracked · #docs #urgent")
    }

    func testWhenItIsDue() {
        let overdue = TaskItem(title: "Call", scheduledAt: now.addingTimeInterval(-26 * 3600))
        let segment = caption(overdue).segments.last
        XCTAssertEqual(segment?.isAlert, true, "an overdue reminder reads orange")
        XCTAssertTrue(segment?.text.hasPrefix("Overdue") == true, segment?.text ?? "")
        var info = remote(key: "PROJ-8", status: "To Do")
        info.dueDate = RemoteTaskInfo.dayDate("2025-10-20", calendar: calendar)
        let due = caption(TaskItem(source: .jira, title: "Plan", remote: info))
        XCTAssertEqual(due.segments.last?.isAlert, false)
        XCTAssertTrue(due.text.hasPrefix("PROJ-8 · To Do · Due "), due.text)
    }
}
