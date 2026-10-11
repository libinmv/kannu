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
    private let jiraOnly = Order.viewFilter(showLocal: false, showJira: true, showGitLab: false, alwaysListed: nil)

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
        XCTAssertEqual(titles(Order.movingUp(id("O", in: list), in: list, listed: issuesOnly)), "a J O I M",
                       "a move steps over the hidden merge request")
        let timedM = Order.connectedFilter(showGitLabMergeRequests: false, alwaysListed: id("M", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedM)), "a J I M O", "the timed merge request keeps its Stop button")
    }

    // MARK: - The notch's view filter

    func testTheNotchFilterFollowsShowInNotch() {
        let list = tasks("a J b") + [gitlab("G", kind: .issue)]
        XCTAssertEqual(titles(Order.active(list, listed: jiraOnly)), "J")
        let noJira = Order.viewFilter(showLocal: true, showJira: false, showGitLab: true, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: noJira)), "a b G")
        let noGitLab = Order.viewFilter(showLocal: true, showJira: true, showGitLab: false, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: noGitLab)), "a J b")
        let all = Order.viewFilter(showLocal: true, showJira: true, showGitLab: true, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(list, listed: all)), "a J b G")
    }

    /// The notch narrows what the baseline holds and never brings back what it left out: with
    /// Include merge requests off, Show in notch's GitLab shows the issues only.
    func testTheNotchFilterComposesWithTheBaseline() {
        let list = tasks("a J") + [gitlab("I", kind: .issue), gitlab("M", kind: .mergeRequest)]
        let baseline = Order.active(list, listed: Order.connectedFilter(showGitLabMergeRequests: false, alwaysListed: nil))
        let gitlabOnly = Order.viewFilter(showLocal: false, showJira: false, showGitLab: true, alwaysListed: nil)
        XCTAssertEqual(titles(Order.active(baseline, listed: gitlabOnly)), "I")
        XCTAssertEqual(titles(baseline), "a J I", "the view filter changed nothing in the baseline")
    }

    func testTheTimedTaskAlwaysPassesTheNotchFilter() {
        let list = tasks("a J b") + [gitlab("G", kind: .issue)]
        let timedB = Order.viewFilter(showLocal: false, showJira: true, showGitLab: false, alwaysListed: id("b", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedB)), "J b")
        let timedG = Order.viewFilter(showLocal: true, showJira: true, showGitLab: false, alwaysListed: id("G", in: list))
        XCTAssertEqual(titles(Order.active(list, listed: timedG)), "a J b G")
    }

    /// The notch says "Filtered" exactly while a source is hidden.
    func testTheNotchFilterNarrowsOnlyWhileASourceIsHidden() {
        XCTAssertFalse(Order.isNarrowingView(showLocal: true, showJira: true, showGitLab: true))
        XCTAssertTrue(Order.isNarrowingView(showLocal: false, showJira: true, showGitLab: true))
        XCTAssertTrue(Order.isNarrowingView(showLocal: true, showJira: false, showGitLab: true))
        XCTAssertTrue(Order.isNarrowingView(showLocal: true, showJira: true, showGitLab: false))
        XCTAssertTrue(Order.isNarrowingView(showLocal: false, showJira: false, showGitLab: false))
    }

    // MARK: - Moves count what is shown

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
