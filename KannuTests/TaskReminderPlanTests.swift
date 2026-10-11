/*
 * Kannu (കണ്ണ്)
 * Copyright (C) 2024-2026 Kannu Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import XCTest

/// Which reminders macOS is told to add or take back after each change to the task list.
final class TaskReminderPlanTests: XCTestCase {
    typealias Plan = TaskReminderPlan

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ title: String, at offset: TimeInterval?, source: TaskSource = .local,
                      visibility: TaskVisibility = .active) -> TaskItem {
        TaskItem(source: source, title: title, visibility: visibility, scheduledAt: offset.map { now.addingTimeInterval($0) })
    }

    func testOnlyScheduledActiveLocalTasksWantAReminder() {
        let tasks = [
            task("Soon", at: 600),
            task("Past", at: -600),
            task("None", at: nil),
            task("Done", at: 600, visibility: .done),
            task("Hidden", at: 600, visibility: .hidden),
            task("Jira", at: 600, source: .jira),
        ]
        XCTAssertEqual(Set(Plan.wanted(tasks).values.map(\.title)), ["Soon", "Past"])
    }

    func testAScheduleAddsAndAClearRemoves() {
        var list = [task("Write", at: nil)]
        let id = list[0].id
        let empty = Plan.wanted(list)
        list[0].scheduledAt = now.addingTimeInterval(3600)
        let scheduled = Plan.wanted(list)
        let add = Plan.changes(from: empty, to: scheduled, now: now)
        XCTAssertEqual(add.add.map(\.taskID), [id])
        XCTAssertEqual(add.remove, [])

        XCTAssertTrue(Plan.changes(from: scheduled, to: scheduled, now: now).isEmpty, "nothing changed, nothing sent")

        list[0].scheduledAt = now.addingTimeInterval(7200)
        let moved = Plan.changes(from: scheduled, to: Plan.wanted(list), now: now)
        XCTAssertEqual(moved.add.map(\.date), [now.addingTimeInterval(7200)], "a new time replaces the request")
        XCTAssertEqual(moved.remove, [])

        list[0].scheduledAt = nil
        let cleared = Plan.changes(from: scheduled, to: Plan.wanted(list), now: now)
        XCTAssertEqual(cleared.add, [])
        XCTAssertEqual(cleared.remove, [Plan.identifier(for: id)])
    }

    func testDoneHiddenAndDeletedTakeTheReminderBack() {
        let list = [task("Write", at: 600)]
        let before = Plan.wanted(list)
        for visibility in [TaskVisibility.done, .hidden] {
            var changed = list
            changed[0].visibility = visibility
            XCTAssertEqual(Plan.changes(from: before, to: Plan.wanted(changed), now: now).remove,
                           [Plan.identifier(for: list[0].id)], "\(visibility)")
        }
        XCTAssertEqual(Plan.changes(from: before, to: Plan.wanted([]), now: now).remove, [Plan.identifier(for: list[0].id)])
    }

    func testAReminderThatHasFiredIsLeftAlone() {
        let list = [task("Write", at: 600)]
        let before = Plan.wanted(list)
        let later = now.addingTimeInterval(3600)
        XCTAssertTrue(Plan.changes(from: before, to: Plan.wanted(list), now: later).isEmpty,
                      "the time passing alone never takes a shown reminder away")
        var renamed = list
        renamed[0].title = "Write more"
        XCTAssertEqual(Plan.changes(from: before, to: Plan.wanted(renamed), now: later),
                       Plan.Changes(add: [], remove: [Plan.identifier(for: list[0].id)]), "changed into the past: it can no longer fire")
    }

    func testAResendAddsEveryReminderStillAhead() {
        let list = [task("A", at: 1200), task("B", at: 600), task("C", at: -60)]
        let resend = Plan.resend(Plan.wanted(list), now: now)
        XCTAssertEqual(resend.add.map(\.title), ["B", "A"], "soonest first, past ones skipped")
        // Scheduling task B resends; task C's reminder, already on screen and unanswered, stays.
        XCTAssertEqual(resend.remove, [], "a resend only adds")
    }

    // MARK: - Reconcile with what macOS holds

    func testReconcileAddsWhatMacOSIsMissingOnceAllowed() {
        let list = [task("A", at: 1200), task("B", at: 600), task("Past", at: -60)]
        let wanted = Plan.wanted(list)
        let a = Plan.identifier(for: list[0].id)
        // Notifications were turned on while Kannu was not running: macOS holds only A.
        let allowed = Plan.reconcile(pending: [a], delivered: [], wanted: wanted, now: now, canAdd: true)
        XCTAssertEqual(allowed, Plan.Changes(add: [wanted[list[1].id]!], remove: []),
                       "B is added; A is already held; a past one is never added")
        let refused = Plan.reconcile(pending: [], delivered: [], wanted: wanted, now: now, canAdd: false)
        XCTAssertTrue(refused.isEmpty, "nothing is added while macOS refuses")
    }

    func testReconcileTakesBackRequestsTheListNoLongerWants() {
        let list = [task("Kept", at: 600), task("Shown", at: -60)]
        let wanted = Plan.wanted(list)
        let kept = Plan.identifier(for: list[0].id)
        let shown = Plan.identifier(for: list[1].id)
        let gone = Plan.identifier(for: UUID())
        let other = "com.example.not-a-reminder"
        // tasks.json was moved aside: macOS still holds a request for a task that is gone.
        let changes = Plan.reconcile(pending: [kept, gone, other, Plan.identifierPrefix + "nope"],
                                     delivered: [shown, gone, other], wanted: wanted, now: now, canAdd: true)
        XCTAssertEqual(changes.add, [])
        XCTAssertEqual(changes.remove, [Plan.identifierPrefix + "nope", gone].sorted(),
                       "the gone task's request and shown reminder go; a wanted one shown stays; other apps' stay")
    }

    func testReconcileTakesBackAWaitingRequestThatCanNoLongerFire() {
        let list = [task("Moved into the past", at: -60)]
        let id = Plan.identifier(for: list[0].id)
        XCTAssertEqual(Plan.reconcile(pending: [id], delivered: [], wanted: Plan.wanted(list), now: now, canAdd: true).remove, [id])
    }

    func testTurningTasksOffTakesBackEveryReminder() {
        let ids = [Plan.identifier(for: UUID()), Plan.identifier(for: UUID())]
        let changes = Plan.reconcile(pending: [ids[0]], delivered: [ids[1]], wanted: [:], now: now, canAdd: true)
        XCTAssertEqual(changes, Plan.Changes(add: [], remove: ids.sorted()))
    }

    func testTheIdentifierNamesTheTask() {
        let id = UUID()
        XCTAssertEqual(Plan.taskID(fromIdentifier: Plan.identifier(for: id)), id)
        XCTAssertNil(Plan.taskID(fromIdentifier: id.uuidString), "another notification")
        XCTAssertNil(Plan.taskID(fromIdentifier: Plan.identifierPrefix + "nope"))
    }

    func testHowAScheduleReads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2027-01-15 08:00 UTC.
        let morning = calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 8))!
        XCTAssertEqual(Plan.when(morning.addingTimeInterval(-60), now: morning, calendar: calendar), .overdue)
        XCTAssertEqual(Plan.when(morning, now: morning, calendar: calendar), .overdue, "due now")
        XCTAssertEqual(Plan.when(morning.addingTimeInterval(7 * 3600), now: morning, calendar: calendar), .today)
        XCTAssertEqual(Plan.when(morning.addingTimeInterval(20 * 3600), now: morning, calendar: calendar), .tomorrow)
        XCTAssertEqual(Plan.when(morning.addingTimeInterval(50 * 3600), now: morning, calendar: calendar), .later)
    }
}
