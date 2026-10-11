//
//  WorklogDraftTests.swift
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

/// Recorded time becomes at most one waiting log entry per task, rounded to the nearest quarter
/// hour, and only where there is somewhere to log it and the user has not said never to ask.
final class WorklogDraftTests: XCTestCase {
    private let nine = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(minutes: Double) -> Date { nine.addingTimeInterval(minutes * 60) }

    private func remoteTask(policy: LogPolicy = .ask, segments: [WorkSegment]) -> TaskItem {
        TaskItem(
            source: .jira,
            title: "Fix the login redirect",
            remote: RemoteTaskInfo(remoteID: "10042", key: "PROJ-123", hostScope: "acme.atlassian.net",
                                   status: "In Progress", isDoneRemotely: false, remoteEstimateSeconds: nil,
                                   remoteSpentSeconds: nil, gitlabProjectID: nil, gitlabIID: nil, lastSeenAt: nine),
            segments: segments,
            logPolicy: policy
        )
    }

    private func segment(_ from: Double, _ to: Double) -> WorkSegment {
        WorkSegment(start: at(minutes: from), end: at(minutes: to), origin: .timer)
    }

    func testStretchesOfWorkFoldIntoOneDraftPerTask() throws {
        var task = remoteTask(segments: [segment(0, 20)])
        var drafts: [WorklogDraft] = []
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].seconds, 15 * 60, "20m rounds to 15m")

        task.segments.append(segment(30, 40))
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts.count, 1, "one pending draft per task")
        let draft = try XCTUnwrap(drafts.first)
        XCTAssertEqual(draft.seconds, 30 * 60, "the exact 30m total is rounded, not 15m + 15m")
        XCTAssertEqual(draft.started, at(minutes: 0), "starts where the first segment started")
        XCTAssertEqual(draft.hostScope, "acme.atlassian.net")
        XCTAssertEqual(draft.state, .awaiting)
        XCTAssertTrue(task.segments.allSatisfy { $0.draftID == draft.id })
    }

    func testTimeThatRoundsToNothingMakesNoDraftAndCarriesOver() throws {
        var task = remoteTask(segments: [segment(0, 7.4)])
        var drafts: [WorklogDraft] = []
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts, [], "7m24s rounds to 0")
        XCTAssertTrue(task.segments.allSatisfy { $0.draftID == nil }, "the time stays unlogged")

        task.segments.append(segment(10, 15))
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        let draft = try XCTUnwrap(drafts.first, "7m24s + 5m carried over into 15m")
        XCTAssertEqual(draft.seconds, 15 * 60)
        XCTAssertEqual(draft.started, at(minutes: 0))
        XCTAssertEqual(task.segments.filter { $0.draftID == draft.id }.count, 2)
    }

    func testLocalOnlyMakesNoDraft() {
        let task = remoteTask(policy: .localOnly, segments: [segment(0, 120)])
        let result = WorklogDrafts.folding(task, into: [])
        XCTAssertEqual(result.drafts, [])
        XCTAssertEqual(result.task, task)
    }

    func testALocalTaskMakesNoDraft() {
        let task = TaskItem(title: "Local", segments: [segment(0, 120)])
        XCTAssertEqual(WorklogDrafts.folding(task, into: []).drafts, [])
    }

    func testTheLiveSegmentIsNotFoldedUntilItCloses() {
        let task = remoteTask(segments: [WorkSegment(start: at(minutes: 0), origin: .timer)])
        XCTAssertEqual(WorklogDrafts.folding(task, into: []).drafts, [])
    }

    func testTimeAfterADraftLeftAwaitingStartsANewOne() throws {
        var task = remoteTask(segments: [segment(0, 60)])
        var drafts: [WorklogDraft] = []
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        drafts[0].state = .sending
        task.segments.append(segment(90, 120))
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].seconds, 60 * 60, "a draft being sent is never changed")
        XCTAssertEqual(drafts[1].seconds, 30 * 60)
        XCTAssertNotEqual(task.segments[0].draftID, task.segments[1].draftID)
    }

    func testTheStatesADraftMovesThrough() {
        typealias Drafts = WorklogDrafts
        XCTAssertEqual(Drafts.transition(.awaiting, on: .send), .sending)
        XCTAssertEqual(Drafts.transition(.sending, on: .succeeded), .logged)
        XCTAssertEqual(Drafts.transition(.sending, on: .rejected), .failed)
        XCTAssertEqual(Drafts.transition(.sending, on: .ambiguous), .uncertain)
        XCTAssertEqual(Drafts.transition(.failed, on: .retry), .sending)
        XCTAssertEqual(Drafts.transition(.uncertain, on: .succeeded), .logged, "a check found it")
        XCTAssertEqual(Drafts.transition(.awaiting, on: .keepLocal), .keptLocal)
        XCTAssertNil(Drafts.transition(.logged, on: .send), "logged is final")
        XCTAssertNil(Drafts.transition(.keptLocal, on: .send), "kept local is final")
        XCTAssertNil(Drafts.transition(.awaiting, on: .succeeded), "nothing succeeds unsent")
    }

    func testADraftStillSendingAtLaunchIsUncertain() {
        let task = UUID()
        let drafts = [
            WorklogDraft(taskID: task, seconds: 900, started: nine, hostScope: "h", state: .sending),
            WorklogDraft(taskID: task, seconds: 900, started: nine, hostScope: "h", state: .awaiting),
        ]
        XCTAssertEqual(WorklogDrafts.normalizedAtLoad(drafts).map(\.state), [.uncertain, .awaiting])
    }
}
