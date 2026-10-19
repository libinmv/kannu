//
//  TasksPopoverLogicTests.swift
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

/// What the notch's Tasks button and popover show, decided in the logic target: which Time to log
/// entries light the yellow dot and get a card, which tasks are Up next and how many rows fit, the
/// "42m of 2h" line, the running clock, and each source's one-line sync caption.
final class TasksPopoverLogicTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func draft(_ state: WorklogState, deferred: Bool = false) -> WorklogDraft {
        WorklogDraft(taskID: UUID(), seconds: 900, started: now, hostScope: "acme.atlassian.net",
                     state: state, deferredAt: deferred ? now : nil)
    }

    // MARK: - The dot and the cards

    func testOnlyEntriesWaitingForAnAnswerLightTheDot() {
        XCTAssertTrue(WorklogDrafts.needsAnswer(draft(.awaiting)))
        XCTAssertTrue(WorklogDrafts.needsAnswer(draft(.failed)), "a refusal waits for Retry or Keep local only")
        XCTAssertTrue(WorklogDrafts.needsAnswer(draft(.uncertain)), "may already be logged: the user checks")
        XCTAssertFalse(WorklogDrafts.needsAnswer(draft(.sending)), "being sent waits for nothing")
        XCTAssertFalse(WorklogDrafts.needsAnswer(draft(.awaiting, deferred: true)), "Not now is an answer")
        XCTAssertFalse(WorklogDrafts.needsAnswer(draft(.logged)))
        XCTAssertFalse(WorklogDrafts.needsAnswer(draft(.keptLocal)))
    }

    func testTheWaitingCountCountsOnlyThoseEntries() {
        let drafts = [draft(.awaiting), draft(.sending), draft(.failed), draft(.awaiting, deferred: true), draft(.logged)]
        XCTAssertEqual(WorklogDrafts.waitingCount(drafts), 2)
        XCTAssertEqual(WorklogDrafts.waitingCount([]), 0)
    }

    func testThePopoverShowsACardForEveryOpenEntryNotPutOff() {
        XCTAssertTrue(WorklogDrafts.isAskingNow(draft(.awaiting)))
        XCTAssertTrue(WorklogDrafts.isAskingNow(draft(.sending)), "a Log clicked in the popover stays in sight")
        XCTAssertTrue(WorklogDrafts.isAskingNow(draft(.failed)))
        XCTAssertTrue(WorklogDrafts.isAskingNow(draft(.uncertain)))
        XCTAssertFalse(WorklogDrafts.isAskingNow(draft(.awaiting, deferred: true)), "put off: it waits in Brain")
        XCTAssertFalse(WorklogDrafts.isAskingNow(draft(.logged)))
        XCTAssertFalse(WorklogDrafts.isAskingNow(draft(.keptLocal)))
    }

    // MARK: - Up next

    func testUpNextLeavesOutTheTimedTaskAndStopsAtTheLimit() {
        let tasks = (1...9).map { TaskItem(title: "T\($0)") }
        let upNext = TaskOrdering.upNext(tasks, excluding: tasks[1].id)
        XCTAssertEqual(upNext.map(\.title), ["T1", "T3", "T4", "T5", "T6", "T7"])
        XCTAssertEqual(TaskOrdering.upNextLimit, 6)
        XCTAssertEqual(TaskOrdering.upNext(tasks, excluding: nil, limit: 2).map(\.title), ["T1", "T2"])
        XCTAssertEqual(TaskOrdering.upNext(tasks, excluding: nil, limit: -1), [], "a negative limit lists nothing")
        XCTAssertEqual(TaskOrdering.upNext([], excluding: nil), [])
    }

    func testFewerRowsFitUnderANowCardAndLogTimeCards() {
        XCTAssertEqual(TaskOrdering.upNextRows(showingNow: false, cards: 0), 6)
        XCTAssertEqual(TaskOrdering.upNextRows(showingNow: true, cards: 0), 4)
        XCTAssertEqual(TaskOrdering.upNextRows(showingNow: false, cards: 1), 4)
        XCTAssertEqual(TaskOrdering.upNextRows(showingNow: true, cards: 2), 2, "never fewer than two")
        XCTAssertEqual(TaskOrdering.upNextRows(showingNow: false, cards: -3), 6)
    }

    // MARK: - Time

    func testProgressAgainstTheEstimate() {
        XCTAssertEqual(TaskTimeMath.progress(tracked: 42 * 60, estimate: 2 * 3600).text, "42m of 2h")
        XCTAssertNil(TaskTimeMath.progress(tracked: 42 * 60, estimate: 2 * 3600).over)
        XCTAssertEqual(TaskTimeMath.progress(tracked: 42 * 60, estimate: nil).text, "42m tracked")
        XCTAssertEqual(TaskTimeMath.progress(tracked: 0, estimate: nil).text, "No estimate")
        XCTAssertNil(TaskTimeMath.progress(tracked: 3600, estimate: nil).over, "no estimate, never over")
    }

    func testOverTheEstimateCountsFromAWholeMinute() {
        XCTAssertNil(TaskTimeMath.progress(tracked: 3600 + 59, estimate: 3600).over)
        XCTAssertEqual(TaskTimeMath.progress(tracked: 3600 + 60, estimate: 3600).over, 60)
        XCTAssertEqual(TaskTimeMath.progress(tracked: 70 * 60, estimate: 3600).over, 10 * 60)
        XCTAssertEqual(TaskTimeMath.progress(tracked: 70 * 60, estimate: 3600).text, "1h 10m of 1h")
    }

    func testTheRunningClock() {
        XCTAssertEqual(WorkDuration.clock(0), "0:00")
        XCTAssertEqual(WorkDuration.clock(5), "0:05")
        XCTAssertEqual(WorkDuration.clock(42 * 60 + 5), "42:05")
        XCTAssertEqual(WorkDuration.clock(3600 + 2 * 60 + 3), "1:02:03")
        XCTAssertEqual(WorkDuration.clock(10 * 3600), "10:00:00")
        XCTAssertEqual(WorkDuration.clock(-30), "0:00")
    }

    // MARK: - Sync captions

    func testEachSyncStateHasAShortCaption() {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        XCTAssertEqual(SourceSyncState.idle.shortCaption(now: now), "Not synced yet")
        XCTAssertEqual(SourceSyncState.syncing.shortCaption(now: now), "Syncing…")
        XCTAssertEqual(SourceSyncState.synced(at: now, count: 3, complete: true).shortCaption(now: now), "Synced \(time(now))")
        XCTAssertEqual(SourceSyncState.offline.shortCaption(now: now), "Offline")
        let until = now.addingTimeInterval(600)
        XCTAssertEqual(SourceSyncState.rateLimited(until: until).shortCaption(now: now), "Rate limited until \(time(until))")
        XCTAssertEqual(SourceSyncState.rateLimited(until: now).shortCaption(now: now), "You can refresh again", "the limit is over")
        for problem: SourceSyncState in [.authFailed(status: 401), .needsReconnect, .failed("Jira refused the issue filter")] {
            XCTAssertTrue(problem.shortCaption(now: now).contains("Brain"), "\(problem) is fixed in Brain, so the caption points there")
        }
        XCTAssertEqual(SourceSyncState.needsKeychainApproval.shortCaption(now: now), "Refresh to allow Keychain access")
    }

    func testOnlyARateLimitHasAnEnd() {
        let until = now.addingTimeInterval(60)
        XCTAssertEqual(SourceSyncState.rateLimited(until: until).rateLimitEnd, until)
        XCTAssertNil(SourceSyncState.offline.rateLimitEnd)
        XCTAssertNil(SourceSyncState.synced(at: now, count: 1, complete: true).rateLimitEnd)
    }

    // MARK: - Refresh, in the popover and the timer tab's toolbar

    func testTheSyncLinesAndTheTooltipNameOnlyTheSourcesThatSync() {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .shortened) }
        let synced = SourceSyncState.synced(at: now, count: 3, complete: true)
        XCTAssertEqual(TaskSyncSummary.lines(jira: synced, gitlab: .offline, now: now),
                       ["Jira · Synced \(time(now))", "GitLab · Offline"])
        XCTAssertEqual(TaskSyncSummary.lines(jira: nil, gitlab: .offline, now: now), ["GitLab · Offline"],
                       "a source whose sync is off has no line")
        XCTAssertEqual(TaskSyncSummary.tooltip(jira: synced, gitlab: .offline, now: now),
                       "Jira: Synced \(time(now)) · GitLab: Offline", "one line: a tooltip never wraps")
        XCTAssertEqual(TaskSyncSummary.tooltip(jira: synced, gitlab: nil, now: now), "Jira: Synced \(time(now))")
    }

    func testRefreshNeedsAReadableListAndOneSourceFreeToSync() {
        let later = now.addingTimeInterval(600)
        let limited = SourceSyncState.rateLimited(until: later)
        XCTAssertTrue(TaskSyncSummary.canRefresh(isReady: true, jira: .idle, gitlab: nil, at: now), "one source on is enough")
        XCTAssertFalse(TaskSyncSummary.canRefresh(isReady: false, jira: .idle, gitlab: .idle, at: now), "the task list is not readable")
        XCTAssertFalse(TaskSyncSummary.canRefresh(isReady: true, jira: nil, gitlab: nil, at: now), "nothing syncs")
        XCTAssertFalse(TaskSyncSummary.canRefresh(isReady: true, jira: limited, gitlab: nil, at: now), "rate limited")
        XCTAssertTrue(TaskSyncSummary.canRefresh(isReady: true, jira: limited, gitlab: nil, at: later), "the limit has run out")
        XCTAssertTrue(TaskSyncSummary.canRefresh(isReady: true, jira: limited, gitlab: .offline, at: now), "GitLab is free")
        XCTAssertEqual(TaskSyncSummary.rateLimitEnds(jira: limited, gitlab: .rateLimited(until: now)), [now, later],
                       "earliest first, so the view redraws at each")
        XCTAssertEqual(TaskSyncSummary.rateLimitEnds(jira: .idle, gitlab: nil), [])
    }
}
