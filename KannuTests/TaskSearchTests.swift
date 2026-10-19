//
//  TaskSearchTests.swift
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

/// The timer tab's task search: it finds a task by any word the user can see on it — title, key,
/// short key, tag, label — whatever the case or accents, and every word typed must be found.
final class TaskSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func remote(key: String, kind: GitLabKind? = nil, iid: Int? = nil, labels: [String]? = nil) -> RemoteTaskInfo {
        RemoteTaskInfo(remoteID: key, key: key, hostScope: "https://example.test", status: "",
                       isDoneRemotely: false, remoteEstimateSeconds: nil, remoteSpentSeconds: nil,
                       gitlabProjectID: nil, gitlabIID: iid, lastSeenAt: now, gitlabKind: kind,
                       gitlabWebURL: nil, statusCategory: nil, labels: labels)
    }

    private lazy var local = TaskItem(title: "Write the Café release notes", tags: ["docs"])
    private lazy var jira = TaskItem(source: .jira, title: "Fix login", remote: remote(key: "PROJ-123"))
    private lazy var gitlab = TaskItem(source: .gitlab, title: "hc: convert EC2 checks",
                                       remote: remote(key: "discern/applications/ds-vendors#4264", kind: .issue, iid: 4264,
                                                      labels: ["workflow::sprint_backlog", "backend"]))

    func testAnEmptyQueryKeepsEveryTaskInOrder() {
        let tasks = [gitlab, local, jira]
        XCTAssertEqual(TaskSearch.filter(tasks, query: "").map(\.id), tasks.map(\.id))
        XCTAssertEqual(TaskSearch.filter(tasks, query: "   ").map(\.id), tasks.map(\.id), "spaces alone search nothing")
    }

    func testTheTitleMatchesWhateverTheCaseOrAccents() {
        XCTAssertTrue(TaskSearch.matches(local, query: "release"))
        XCTAssertTrue(TaskSearch.matches(local, query: "RELEASE"))
        XCTAssertTrue(TaskSearch.matches(local, query: "cafe"), "accents never matter")
        XCTAssertFalse(TaskSearch.matches(local, query: "deploy"))
    }

    func testTheKeyAndTheShortKeyMatch() {
        XCTAssertTrue(TaskSearch.matches(jira, query: "proj-123"))
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "#4264"))
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "ds-vendors #4264"), "the short key the card shows")
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "discern"), "the full path key")
    }

    func testTagsAndLabelsMatchAScopedLabelByItsValueToo() {
        XCTAssertTrue(TaskSearch.matches(local, query: "docs"))
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "backend"))
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "sprint_backlog"))
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "workflow::"))
    }

    func testEveryWordTypedMustBeFoundSomewhere() {
        XCTAssertTrue(TaskSearch.matches(gitlab, query: "convert backend"), "title and label")
        XCTAssertFalse(TaskSearch.matches(gitlab, query: "convert frontend"))
    }

    func testTheFilterKeepsTheOrderGiven() {
        let tasks = [gitlab, local, jira]
        XCTAssertEqual(TaskSearch.filter(tasks, query: "e").map(\.id), [gitlab.id, local.id], "jira's words have no e")
        XCTAssertEqual(TaskSearch.filter(tasks, query: "login").map(\.id), [jira.id])
        XCTAssertEqual(TaskSearch.filter(tasks, query: "nothing like it"), [])
    }
}
