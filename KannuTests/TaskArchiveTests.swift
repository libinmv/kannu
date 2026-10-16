//
//  TaskArchiveTests.swift
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

/// The archive's clock: closed for `closedDays` → archived; archived remote for `clearDays` →
/// cleared. What clearing must never cost: time still to log, a ticket still open on its server,
/// the user's own local tasks, the task being timed.
final class TaskArchiveTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func remoteTask(_ visibility: TaskVisibility, closed: TimeInterval? = nil, archived: TimeInterval? = nil,
                            byUser: Bool = false, lastSeen: TimeInterval = -10 * 86_400) -> TaskItem {
        TaskItem(source: .gitlab, title: "Ticket",
                 remote: RemoteTaskInfo(remoteID: UUID().uuidString, key: "g/a#1", hostScope: "https://gitlab.example.com",
                                        status: "opened", isDoneRemotely: false, remoteEstimateSeconds: nil,
                                        remoteSpentSeconds: nil, gitlabProjectID: 1, gitlabIID: 1,
                                        lastSeenAt: now.addingTimeInterval(lastSeen)),
                 visibility: visibility, createdAt: now.addingTimeInterval(-30 * day),
                 closedAt: closed.map { now.addingTimeInterval($0) },
                 archivedAt: archived.map { now.addingTimeInterval($0) }, archivedByUser: byUser)
    }

    private func apply(_ tasks: [TaskItem], drafts: [WorklogDraft] = [], protected: Set<UUID> = []) -> TaskArchive.Result {
        TaskArchive.apply(tasks, drafts: drafts, protected: protected, now: now, calendar: calendar)
    }

    private func draft(for task: TaskItem, _ state: WorklogState) -> WorklogDraft {
        WorklogDraft(id: UUID(), taskID: task.id, seconds: 900, started: now.addingTimeInterval(-20 * day),
                     hostScope: "https://gitlab.example.com", state: state)
    }

    // MARK: - Closed → archived

    func testAClosedTaskIsArchivedAfterThreeDaysNotBefore() {
        let fresh = remoteTask(.gone, closed: -2 * day)
        let due = remoteTask(.gone, closed: -3 * day)
        var done = TaskItem(title: "Mine", visibility: .done)
        done.closedAt = now.addingTimeInterval(-4 * day)
        let result = apply([fresh, due, done])
        XCTAssertEqual(result.tasks.map(\.visibility), [.gone, .archived, .archived])
        XCTAssertEqual(result.tasks[1].archivedAt, now)
        XCTAssertFalse(result.tasks[1].archivedByUser, "archived on its own: it may come back if listed again")
        XCTAssertEqual(result.archived, 2)
        XCTAssertTrue(result.changed)
    }

    func testAFileFromBeforeTheArchiveIsSeeded() {
        let gone = remoteTask(.gone, lastSeen: -5 * day)
        let done = TaskItem(title: "Done", visibility: .done)
        let result = apply([gone, done])
        XCTAssertEqual(result.tasks[0].visibility, .archived, "a gone task closed when it was last seen: 5 days ago")
        XCTAssertEqual(result.tasks[1].visibility, .done, "a done one is counted from now")
        XCTAssertEqual(result.tasks[1].closedAt, now)
        XCTAssertTrue(result.changed)
    }

    func testActiveTasksAndTheTimedOneAreNeverArchived() {
        let active = remoteTask(.active)
        let timed = remoteTask(.gone, closed: -9 * day)
        let result = apply([active, timed], protected: [timed.id])
        XCTAssertEqual(result.tasks.map(\.visibility), [.active, .gone])
    }

    // MARK: - Archived → cleared

    func testAnArchivedRemoteTaskClearsAfterSevenDaysNotBefore() {
        let six = remoteTask(.archived, closed: -10 * day, archived: -6 * day)
        let seven = remoteTask(.archived, closed: -10 * day, archived: -7 * day)
        let result = apply([six, seven])
        XCTAssertEqual(result.tasks.map(\.id), [six.id])
        XCTAssertEqual(result.cleared, 1)
    }

    func testALocalTaskIsNeverCleared() {
        var local = TaskItem(title: "Mine", visibility: .archived)
        local.closedAt = now.addingTimeInterval(-90 * day)
        local.archivedAt = now.addingTimeInterval(-60 * day)
        XCTAssertEqual(apply([local]).tasks.map(\.id), [local.id])
    }

    func testATicketTheServerStillListsIsNeverCleared() {
        let stillOpen = remoteTask(.archived, closed: nil, archived: -30 * day, byUser: true)
        XCTAssertEqual(apply([stillOpen]).tasks.map(\.id), [stillOpen.id], "cleared, the next sync would bring it back new")
    }

    func testTimeStillToLogKeepsItEachReason() {
        let open = remoteTask(.archived, closed: -20 * day, archived: -10 * day)
        for state in [WorklogState.awaiting, .sending, .failed, .uncertain] {
            XCTAssertEqual(apply([open], drafts: [draft(for: open, state)]).tasks.count, 1, "\(state) holds it")
        }

        var interrupted = remoteTask(.archived, closed: -20 * day, archived: -10 * day)
        interrupted.segments = [WorkSegment(start: now.addingTimeInterval(-15 * day), end: nil, origin: .recovered)]
        XCTAssertEqual(apply([interrupted]).tasks.count, 1, "an interrupted session's end is not set yet")

        var unfolded = remoteTask(.archived, closed: -20 * day, archived: -10 * day)
        unfolded.segments = [WorkSegment(start: now.addingTimeInterval(-15 * day),
                                         end: now.addingTimeInterval(-15 * day + 3600), origin: .timer)]
        XCTAssertEqual(apply([unfolded]).tasks.count, 1, "an hour no draft holds is still loggable")

        var tiny = unfolded
        tiny.segments = [WorkSegment(start: now.addingTimeInterval(-15 * day),
                                     end: now.addingTimeInterval(-15 * day + 5), origin: .timer)]
        XCTAssertEqual(apply([tiny]).tasks.count, 0, "seconds that round to nothing were never going to be logged")

        var localOnly = unfolded
        localOnly.logPolicy = .localOnly
        XCTAssertEqual(apply([localOnly]).tasks.count, 0, "time kept local is never offered for logging")

        let timed = remoteTask(.archived, closed: -20 * day, archived: -10 * day)
        XCTAssertEqual(apply([timed], protected: [timed.id]).tasks.count, 1)
    }

    func testSettledDraftsGoWithTheirTaskAndOthersStay() {
        let settled = remoteTask(.archived, closed: -20 * day, archived: -10 * day)
        let other = remoteTask(.active)
        let drafts = [draft(for: settled, .logged), draft(for: settled, .keptLocal), draft(for: other, .awaiting)]
        let result = apply([settled, other], drafts: drafts)
        XCTAssertEqual(result.tasks.map(\.id), [other.id])
        XCTAssertEqual(result.drafts.map(\.taskID), [other.id])
    }

    // MARK: - Captions

    func testDaysLeftForBrainsCaptions() {
        let closed = remoteTask(.gone, closed: -1 * day)
        XCTAssertEqual(TaskArchive.daysUntilArchive(closed, now: now, calendar: calendar), 2)
        let archived = remoteTask(.archived, closed: -10 * day, archived: -2 * day)
        XCTAssertEqual(TaskArchive.daysUntilClear(archived, now: now, calendar: calendar), 5)
        XCTAssertNil(TaskArchive.daysUntilClear(remoteTask(.archived, closed: nil, archived: -2 * day), now: now, calendar: calendar),
                     "still listed: never cleared on its own")
        XCTAssertNil(TaskArchive.daysUntilClear(TaskItem(title: "Mine", visibility: .archived), now: now, calendar: calendar))
    }

    func testNothingToDoChangesNothing() {
        let result = apply([remoteTask(.active), TaskItem(title: "Mine")])
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.archived + result.cleared, 0)
    }
}
