//
//  TaskSourceFilterTests.swift
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

/// With a source switched off (Local tasks, Sync Jira, Sync GitLab), its tasks leave the task order but keep
/// their place in the file. Moves and drags count only what is on screen, so one click on Move Up
/// always changes what the user sees, and a drag lands where it was dropped.
final class TaskSourceFilterTests: XCTestCase {
    typealias Order = TaskOrdering

    /// "a J b K": lower case is a local task, upper case a Jira task; all active.
    private func tasks(_ spec: String) -> [TaskItem] {
        spec.split(separator: " ").map { name in
            TaskItem(source: name.uppercased() == name ? .jira : .local, title: String(name))
        }
    }

    private func titles(_ tasks: [TaskItem]) -> String {
        tasks.map(\.title).joined(separator: " ")
    }

    private func id(_ title: String, in tasks: [TaskItem]) -> UUID {
        tasks.first { $0.title == title }!.id
    }

    private let jiraOnly = Order.listedFilter(showLocal: false, showJira: true, showGitLab: false, showGitLabMergeRequests: true, alwaysListed: nil)

    func testTheFilterFollowsTheSources() {
        let list = tasks("a J b K")
        XCTAssertEqual(titles(Order.active(list, listed: jiraOnly)), "J K")
        XCTAssertEqual(titles(Order.active(list, listed: Order.listedFilter(showLocal: true, showJira: false, showGitLab: true, showGitLabMergeRequests: true, alwaysListed: nil))), "a b")
        XCTAssertEqual(titles(Order.active(list, listed: Order.listedFilter(showLocal: true, showJira: true, showGitLab: true, showGitLabMergeRequests: true, alwaysListed: nil))), "a J b K")
        XCTAssertEqual(titles(Order.active(list)), "a J b K", "the default lists every active task")
    }

    func testGitLabTasksFollowSyncGitLabAlone() {
        var list = tasks("a J")
        list.append(TaskItem(source: .gitlab, title: "G"))
        let gitlabOff = Order.listedFilter(showLocal: true, showJira: true, showGitLab: false, showGitLabMergeRequests: true, alwaysListed: nil)
        let gitlabOnly = Order.listedFilter(showLocal: false, showJira: false, showGitLab: true, showGitLabMergeRequests: true, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: gitlabOff)), "a J")
        XCTAssertEqual(titles(Order.active(list, listed: gitlabOnly)), "G")
        let timedG = Order.listedFilter(showLocal: true, showJira: true, showGitLab: false, showGitLabMergeRequests: true, alwaysListed: id("G", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedG)), "a J G", "the timed task shows whatever its source's switch says")
    }

    /// Include merge requests off takes the merge requests out of the task order at once, whatever a
    /// sync in flight or a failed one still holds; issues stay. A GitLab task from a file written
    /// before the kind existed reads as an issue here, so it never vanishes.
    func testIncludeMergeRequestsOffHidesOnlyMergeRequests() {
        func gitlab(_ title: String, kind: GitLabKind?) -> TaskItem {
            let remote = RemoteTaskInfo(
                remoteID: title, key: title, hostScope: "https://gitlab.com", status: "opened", isDoneRemotely: false,
                remoteEstimateSeconds: nil, remoteSpentSeconds: nil, gitlabProjectID: 8, gitlabIID: 1,
                lastSeenAt: Date(timeIntervalSince1970: 0), gitlabKind: kind
            )
            return TaskItem(source: .gitlab, title: title, remote: remote)
        }
        let list = tasks("a J") + [gitlab("I", kind: .issue), gitlab("M", kind: .mergeRequest), gitlab("O", kind: nil)]
        let withMergeRequests = Order.listedFilter(showLocal: true, showJira: true, showGitLab: true, showGitLabMergeRequests: true, alwaysListed: nil)
        let issuesOnly = Order.listedFilter(showLocal: true, showJira: true, showGitLab: true, showGitLabMergeRequests: false, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: withMergeRequests)), "a J I M O")
        XCTAssertEqual(titles(Order.active(list, listed: issuesOnly)), "a J I O")
        XCTAssertEqual(titles(Order.movingUp(id("O", in: list), in: list, listed: issuesOnly)), "a J O I M", "a move steps over the hidden merge request")
        let gitlabOff = Order.listedFilter(showLocal: true, showJira: true, showGitLab: false, showGitLabMergeRequests: true, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: gitlabOff)), "a J", "Sync GitLab off still hides every GitLab task")
        let timedM = Order.listedFilter(showLocal: true, showJira: true, showGitLab: true, showGitLabMergeRequests: false, alwaysListed: id("M", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedM)), "a J I M O", "the timed merge request keeps its Stop button")
    }

    func testTheTimedTaskIsAlwaysListed() {
        let list = tasks("a J b")
        let listed = Order.listedFilter(showLocal: false, showJira: true, showGitLab: false, showGitLabMergeRequests: true, alwaysListed: id("b", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: listed)), "J b")
    }

    func testMovesStepOverTasksOfAHiddenSource() {
        let list = tasks("J a b K")
        XCTAssertEqual(titles(Order.movingUp(id("K", in: list), in: list, listed: jiraOnly)), "K J a b")
        XCTAssertEqual(titles(Order.active(Order.movingUp(id("K", in: list), in: list, listed: jiraOnly), listed: jiraOnly)), "K J")
        XCTAssertEqual(titles(Order.movingDown(id("J", in: list), in: list, listed: jiraOnly)), "a b K J")
        XCTAssertEqual(Order.movingUp(id("J", in: list), in: list, listed: jiraOnly), list, "already at the top of what is shown")
        XCTAssertEqual(Order.movingDown(id("K", in: list), in: list, listed: jiraOnly), list, "already at the bottom of what is shown")
    }

    func testADropCountsListedTasksOnly() {
        // On screen: "J K L". Drop L on J: it goes to the top.
        let list = tasks("J a K b L")
        let moved = Order.move(id: id("L", in: list), onto: id("J", in: list), in: list, listed: jiraOnly)
        XCTAssertEqual(titles(Order.active(moved, listed: jiraOnly)), "L J K")
        XCTAssertEqual(titles(moved), "L J a K b")
        // Drop J on L: it goes to the end.
        let toEnd = Order.move(id: id("J", in: list), onto: id("L", in: list), in: list, listed: jiraOnly)
        XCTAssertEqual(titles(Order.active(toEnd, listed: jiraOnly)), "K L J")
        XCTAssertEqual(titles(toEnd), "a K b L J")
        // A task that is not on screen is neither dragged nor dropped on.
        XCTAssertEqual(Order.move(id: id("a", in: list), onto: id("J", in: list), in: list, listed: jiraOnly), list)
        XCTAssertEqual(Order.move(id: id("J", in: list), onto: id("b", in: list), in: list, listed: jiraOnly), list)
    }
}
