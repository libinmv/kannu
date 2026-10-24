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

/// Two filters, never one. The connected baseline (`connectedFilter`) is every task Kannu holds:
/// Sync Jira and Sync GitLab only decide what is fetched, so a paused source's tasks stay, and only
/// Include merge requests narrows it. A view narrows the baseline with a filter of its own — the
/// notch's Show in notch (`viewFilter`) — that changes nothing else. Moves and drags count only
/// what is on screen, so one click on Move Up always changes what the user sees, and a drag lands
/// where it was dropped.
final class TaskSourceFilterTests: XCTestCase {
    typealias Order = TaskOrdering

    /// "a J b K": lower case is a local task, upper case a Jira task; all active.
    private func tasks(_ spec: String) -> [TaskItem] {
        spec.split(separator: " ").map { name in
            TaskItem(source: name.uppercased() == name ? .jira : .local, title: String(name))
        }
    }

    private func gitlab(_ title: String, kind: GitLabKind?) -> TaskItem {
        let remote = RemoteTaskInfo(
            remoteID: title, key: title, hostScope: "https://gitlab.com", status: "opened", isDoneRemotely: false,
            remoteEstimateSeconds: nil, remoteSpentSeconds: nil, gitlabProjectID: 8, gitlabIID: 1,
            lastSeenAt: Date(timeIntervalSince1970: 0), gitlabKind: kind
        )
        return TaskItem(source: .gitlab, title: title, remote: remote)
    }

    private func titles(_ tasks: [TaskItem]) -> String {
        tasks.map(\.title).joined(separator: " ")
    }

    private func id(_ title: String, in tasks: [TaskItem]) -> UUID {
        tasks.first { $0.title == title }!.id
    }

    private let everything = Order.connectedFilter(showGitLabMergeRequests: true, alwaysListed: nil)
    private let jiraOnly = Order.viewFilter(hidden: [.local, .gitlab], alwaysListed: nil)

    // MARK: - The connected baseline

    /// Every source, whatever is synced: the baseline reads no switch but Include merge requests.
    func testTheBaselineListsEveryConnectedTask() {
        let list = tasks("a J b K") + [gitlab("I", kind: .issue), gitlab("M", kind: .mergeRequest)]
        XCTAssertEqual(titles(Order.active(list, listed: everything)), "a J b K I M")
        XCTAssertEqual(titles(Order.active(list)), "a J b K I M", "the default lists every active task")
        var finished = list
        finished[0].visibility = .done
        XCTAssertEqual(titles(Order.active(finished, listed: everything)), "J b K I M", "done tasks are never in the order")
    }

    /// Include merge requests off takes the merge requests out of the baseline at once, whatever a
    /// sync in flight or a failed one still holds; issues stay. A GitLab task from a file written
    /// before the kind existed reads as an issue here, so it never vanishes.
    func testIncludeMergeRequestsOffHidesOnlyMergeRequests() {
        let list = tasks("a J") + [gitlab("I", kind: .issue), gitlab("M", kind: .mergeRequest), gitlab("O", kind: nil)]
        let issuesOnly = Order.connectedFilter(showGitLabMergeRequests: false, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: everything)), "a J I M O")
        XCTAssertEqual(titles(Order.active(list, listed: issuesOnly)), "a J I O")
        let timedM = Order.connectedFilter(showGitLabMergeRequests: false, alwaysListed: id("M", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedM)), "a J I M O", "the timed merge request keeps its Stop button")
    }

    // MARK: - The notch's view filter

    func testTheNotchFilterFollowsShowInNotch() {
        let list = tasks("a J b") + [gitlab("G", kind: .issue)]
        XCTAssertEqual(titles(Order.active(list, listed: jiraOnly)), "J")
        let noJira = Order.viewFilter(hidden: [.jira], alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: noJira)), "a b G")
        let noGitLab = Order.viewFilter(hidden: [.gitlab], alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: noGitLab)), "a J b")
        let all = Order.viewFilter(hidden: [], alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: all)), "a J b G")
    }

    /// The notch narrows what the baseline holds and never brings back what it left out: with
    /// Include merge requests off, Show in notch's GitLab shows the issues only.
    func testTheNotchFilterComposesWithTheBaseline() {
        let list = tasks("a J") + [gitlab("I", kind: .issue), gitlab("M", kind: .mergeRequest)]
        let baseline = Order.active(list, listed: Order.connectedFilter(showGitLabMergeRequests: false, alwaysListed: nil))
        let gitlabOnly = Order.viewFilter(hidden: [.local, .jira], alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(baseline, listed: gitlabOnly)), "I")
        XCTAssertEqual(titles(baseline), "a J I", "the view filter changed nothing in the baseline")
    }

    func testTheTimedTaskAlwaysPassesTheNotchFilter() {
        let list = tasks("a J b") + [gitlab("G", kind: .issue)]
        let timedB = Order.viewFilter(hidden: [.local, .gitlab], alwaysListed: id("b", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedB)), "J b")
        let timedG = Order.viewFilter(hidden: [.gitlab], alwaysListed: id("G", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedG)), "a J b G")
    }

    /// Every source answers to Show in notch the same way, the newer ones too: hidden only when it
    /// is in the set.
    func testEverySourceFollowsShowInNotch() {
        let list = TaskSource.allCases.map { source in
            TaskItem(source: source, title: source.rawValue,
                     remote: source == .local ? nil : RemoteTaskInfo(remoteID: source.rawValue, key: "K-1", hostScope: "h", status: "",
                                                                    isDoneRemotely: false, lastSeenAt: Date(timeIntervalSince1970: 0)))
        }
        XCTAssertEqual(Order.active(list, listed: Order.viewFilter(hidden: [], alwaysListed: nil)).count, TaskSource.allCases.count)
        let noReminders = Order.viewFilter(hidden: [.appleReminders, .todoist], alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: noReminders)), "local jira gitlab github linear")
    }
}
