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

    func testALengthTheUserChoseSurvivesTheNextFold() throws {
        var task = remoteTask(segments: [segment(0, 75)])
        var drafts: [WorklogDraft] = []
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts[0].seconds, 75 * 60)
        // Log with 2h typed, then nothing left this Mac (offline Keychain dialog, a failed save):
        // confirmWorklog stored the typed length and restoreUnsent put the draft back to awaiting.
        drafts[0].seconds = 120 * 60

        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts[0].seconds, 120 * 60, "folding again with nothing new (the next launch) keeps 2h")

        task.segments.append(segment(80, 95))
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].seconds, 135 * 60, "the user's 2h plus only the new 15m")

        var shorter = remoteTask(segments: [segment(0, 75)])
        var shorterDrafts: [WorklogDraft] = []
        (shorter, shorterDrafts) = WorklogDrafts.folding(shorter, into: shorterDrafts)
        shorterDrafts[0].seconds = 30 * 60
        shorter.segments.append(segment(80, 95))
        (shorter, shorterDrafts) = WorklogDrafts.folding(shorter, into: shorterDrafts)
        XCTAssertEqual(shorterDrafts[0].seconds, 45 * 60, "typed shorter: 30m plus the new 15m")

        var untouched = remoteTask(segments: [segment(0, 75)])
        var untouchedDrafts: [WorklogDraft] = []
        (untouched, untouchedDrafts) = WorklogDrafts.folding(untouched, into: untouchedDrafts)
        untouched.segments.append(segment(80, 95))
        (untouched, untouchedDrafts) = WorklogDrafts.folding(untouched, into: untouchedDrafts)
        XCTAssertEqual(untouchedDrafts[0].seconds, 90 * 60, "a draft nobody edited is the rounded total, as before")
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
        let gone = UUID()
        var said = WorklogDraft(taskID: task, seconds: 900, started: nine, hostScope: "h", state: .uncertain)
        said.message = "GitLab did not answer"
        let drafts = [
            WorklogDraft(taskID: task, seconds: 900, started: nine, hostScope: "h", state: .sending),
            WorklogDraft(taskID: task, seconds: 900, started: nine, hostScope: "h", state: .awaiting),
            WorklogDraft(taskID: task, seconds: 900, started: nine, hostScope: "h", state: .uncertain),
            said,
            WorklogDraft(taskID: gone, seconds: 900, started: nine, hostScope: "h", state: .sending),
        ]
        let loaded = WorklogDrafts.normalizedAtLoad(drafts) { $0.taskID == task ? .gitlab : nil }
        XCTAssertEqual(loaded.map(\.state), [.uncertain, .awaiting, .uncertain, .uncertain, .uncertain])
        XCTAssertEqual(loaded[0].message, "May already be logged — check GitLab", "the card says why it is not offered as new")
        XCTAssertNil(loaded[1].message, "an entry still waiting for an answer is untouched")
        XCTAssertEqual(loaded[2].message, "May already be logged — check GitLab", "an uncertain entry saved without a reason gets one")
        XCTAssertEqual(loaded[3].message, "GitLab did not answer", "a reason it already has is kept")
        XCTAssertNil(loaded[4].message, "no task: the card says it cannot be sent instead")
    }

    // MARK: - Rounding to the nearest quarter hour

    func testTheDraftIsRoundedToTheNearest15Minutes() {
        let cases: [(seconds: Double, expected: Int)] = [
            (7 * 60 + 29, 0),           // rounds to nothing: no draft, carried over
            (7 * 60 + 30, 15 * 60),     // halves round up
            (14 * 60, 15 * 60),
            (22 * 60 + 29, 15 * 60),
            (22 * 60 + 30, 30 * 60),
            (67 * 60 + 29, 60 * 60),    // 1h 7m 29s
            (67 * 60 + 30, 75 * 60),    // 1h 7m 30s is 1h 15m
            (75 * 60, 75 * 60),
        ]
        for (seconds, expected) in cases {
            let task = remoteTask(segments: [WorkSegment(start: nine, end: nine.addingTimeInterval(seconds), origin: .timer)])
            let drafts = WorklogDrafts.folding(task, into: []).drafts
            XCTAssertEqual(drafts.first?.seconds ?? 0, expected, "\(Int(seconds)) s")
            XCTAssertEqual(drafts.count, expected == 0 ? 0 : 1, "\(Int(seconds)) s")
        }
    }

    // MARK: - Write-ahead and relaunch

    func testASendSavedAsSendingIsUncertainAfterARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorklogDraftTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var task = remoteTask(segments: [segment(0, 75)])
        var drafts: [WorklogDraft] = []
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        // What confirmWorklog writes, and waits for, before the request goes out.
        drafts[0].state = try XCTUnwrap(WorklogDrafts.transition(drafts[0].state, on: .send))
        XCTAssertEqual(drafts[0].state, .sending)
        let saved = await TaskFileStore(directory: { folder }).save(TasksFile(tasks: [task], drafts: drafts), revision: 1)
        XCTAssertEqual(saved, .written)

        // Kannu stopped before the answer came. Whether it arrived is unknown.
        guard case .loaded(let file) = await TaskFileStore(directory: { folder }).load() else { return XCTFail("the file did not load") }
        let relaunched = WorklogDrafts.normalizedAtLoad(file.drafts) { draft in
            file.tasks.first { $0.id == draft.taskID }?.source
        }
        XCTAssertEqual(relaunched.map(\.state), [.uncertain])
        let message = try XCTUnwrap(relaunched[0].message, "the Jira card says why Retry checks first")
        XCTAssertTrue(message.contains("Retry checks Jira first"), message)
        XCTAssertEqual(relaunched[0].id, drafts[0].id, "the same entry, so Jira's check looks for its marker")
        XCTAssertNil(WorklogDrafts.transition(.uncertain, on: .send), "never sent as if new")
        XCTAssertEqual(WorklogDrafts.transition(.uncertain, on: .retry), .sending, "only through a retry, which checks Jira first")
        XCTAssertTrue(WorklogDrafts.isOpen(.uncertain), "it stays in Time to log")
    }

    func testAReconcileThatFindsTheEntryLogsIt() throws {
        let entry = UUID()
        let found = JiraAPI.matchingWorklog(
            in: [JiraWorklog(id: "100028", accountID: "acc", started: "2026-10-04T08:32:00.000+0000", timeSpentSeconds: 4_500, kannuEntry: entry.uuidString)],
            entry: entry, accountID: "acc", started: Date(timeIntervalSince1970: 1_791_102_720), seconds: 4_500
        )
        XCTAssertEqual(found?.id, "100028")
        let resolution = WorklogDrafts.resolution(of: .logged(remoteID: found?.id), source: .jira)
        XCTAssertEqual(resolution.event, .succeeded)
        XCTAssertNil(resolution.message)
        XCTAssertEqual(WorklogDrafts.transition(.sending, on: resolution.event), .logged, "a lost answer, then found")
        XCTAssertEqual(WorklogDrafts.transition(.uncertain, on: .succeeded), .logged, "Mark as Logged on an uncertain entry")
        XCTAssertFalse(WorklogDrafts.isOpen(.logged))
    }

    func testACheckThatCannotFinishNeverTurnsUncertainIntoFailed() {
        let uncertain = WorklogDrafts.checkFailure(.offline, mayAlreadyBeLogged: true)
        XCTAssertEqual(WorklogDrafts.transition(.sending, on: uncertain.event), .uncertain, "still maybe logged: no plain Retry may send it unchecked")
        let failed = WorklogDrafts.checkFailure(.auth(401), mayAlreadyBeLogged: false)
        XCTAssertEqual(WorklogDrafts.transition(.sending, on: failed.event), .failed)
        XCTAssertTrue(failed.message.contains("Reconnect Jira"), failed.message)
    }

    func testWhatEachAnswerMeans() {
        XCTAssertEqual(WorklogDrafts.verdict(for: .ok(201), reason: nil), .logged(remoteID: nil))
        XCTAssertEqual(WorklogDrafts.verdict(for: .rejected(400), reason: "Off"), .refused(status: 400, reason: "Off"))
        XCTAssertEqual(WorklogDrafts.verdict(for: .rejected(404), reason: nil), .refused(status: 404, reason: nil))
        XCTAssertEqual(WorklogDrafts.verdict(for: .redirected(302), reason: "ignored"), .refused(status: 302, reason: nil))
        XCTAssertEqual(WorklogDrafts.verdict(for: .auth(401), reason: nil), .authRejected(status: 401))
        XCTAssertEqual(WorklogDrafts.verdict(for: .rateLimited(retryAfter: 60), reason: nil), .notSent(.rateLimited(retryAfter: 60)))
        XCTAssertEqual(WorklogDrafts.verdict(for: .offline, reason: nil), .notSent(.offline))
        XCTAssertEqual(WorklogDrafts.verdict(for: .failedBeforeSend, reason: nil), .notSent(.failedBeforeSend))
        XCTAssertEqual(WorklogDrafts.verdict(for: .ambiguous(nil), reason: nil), .uncertain, "a timeout or dropped connection")
        XCTAssertEqual(WorklogDrafts.verdict(for: .ambiguous(502), reason: nil), .uncertain)
        XCTAssertEqual(WorklogDrafts.verdict(for: .ambiguous(504), reason: nil), .uncertain)
        XCTAssertEqual(WorklogDrafts.resolution(of: .uncertain, source: .gitlab).message, "May already be logged — check GitLab")
    }

    // MARK: - Not now

    func testNotNowHoldsUntilMoreTimeIsAdded() throws {
        var task = remoteTask(segments: [segment(0, 30)])
        var drafts: [WorklogDraft] = []
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        drafts[0].deferredAt = at(minutes: 31)

        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertNotNil(drafts[0].deferredAt, "folding again with nothing new does not ask again")

        task.segments.append(segment(40, 45))
        (task, drafts) = WorklogDrafts.folding(task, into: drafts)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertNil(drafts[0].deferredAt, "new time asks again")
        XCTAssertEqual(drafts[0].seconds, 30 * 60, "35m rounds to 30m")
    }

    func testADraftWrittenBeforeNotNowStillReads() throws {
        let json = #"{"id":"6F1C2B9A-3D4E-4F50-8A61-72B3C4D5E6F7","taskID":"0B8C3F5E-1A2B-4C3D-9E8F-112233445566","seconds":900,"started":"2026-10-04T08:32:00Z","hostScope":"acme.atlassian.net","state":"awaiting"}"#
        let draft = try TasksFile.makeDecoder().decode(WorklogDraft.self, from: Data(json.utf8))
        XCTAssertNil(draft.deferredAt)
        XCTAssertEqual(draft.state, .awaiting)
        var deferred = draft
        deferred.deferredAt = nine
        let data = try TasksFile.makeEncoder().encode(deferred)
        XCTAssertEqual(try TasksFile.makeDecoder().decode(WorklogDraft.self, from: data), deferred)
    }

    // MARK: - The length sent

    func testTheTypedLengthIsReadAndSentInWholeMinutes() {
        XCTAssertEqual(WorklogDrafts.loggableSeconds(typed: "1h 15m"), 4_500)
        XCTAssertEqual(WorklogDrafts.loggableSeconds(typed: "75m"), 4_500)
        XCTAssertEqual(WorklogDrafts.loggableSeconds(typed: "1.25h"), 4_500)
        XCTAssertEqual(WorklogDrafts.loggableSeconds(typed: "75"), 4_500, "a bare number is minutes")
        XCTAssertEqual(WorklogDrafts.loggableSeconds(typed: "1.33h"), 80 * 60, "4788 s is sent as 80 whole minutes")
        XCTAssertNil(WorklogDrafts.loggableSeconds(typed: "0"))
        XCTAssertNil(WorklogDrafts.loggableSeconds(typed: "0.4m"), "under a minute")
        XCTAssertNil(WorklogDrafts.loggableSeconds(typed: ""))
        XCTAssertNil(WorklogDrafts.loggableSeconds(typed: "soon"))
        XCTAssertNil(WorklogDrafts.loggableSeconds(typed: "2000h"))
        XCTAssertEqual(WorklogDrafts.loggableSeconds(90), 120, "halves round up")
        XCTAssertNil(WorklogDrafts.loggableSeconds(29))
    }

    // MARK: - Where it can be sent

    func testADraftIsSentOnlyToTheSiteOrServerItWasRecordedAgainst() throws {
        let jiraTask = remoteTask(segments: [])
        let jiraDraft = WorklogDraft(taskID: jiraTask.id, seconds: 900, started: nine, hostScope: "acme.atlassian.net")
        func jira(_ host: String, _ task: TaskItem? = nil) -> WorklogDrafts.Availability {
            WorklogDrafts.availability(of: jiraDraft, task: task ?? jiraTask, jiraHost: host, gitlabHost: "", gitlabCanLogTime: false)
        }
        XCTAssertEqual(jira("acme.atlassian.net"), .ready)
        XCTAssertEqual(jira(""), .notConnected, "disconnected: kept, not sent")
        XCTAssertEqual(jira("other.atlassian.net"), .notConnected, "reconnected elsewhere: never sent there")
        var keyed = jiraTask
        keyed.remote?.remoteID = "PROJ-123"
        XCTAssertEqual(jira("acme.atlassian.net", keyed), .missingDetails)
        XCTAssertEqual(WorklogDrafts.availability(of: jiraDraft, task: nil, jiraHost: "acme.atlassian.net", gitlabHost: "", gitlabCanLogTime: false),
                       .missingDetails)

        let gitlabTask = TaskItem(
            source: .gitlab, title: "Review",
            remote: RemoteTaskInfo(remoteID: "mr:31", key: "group/app!12", hostScope: "https://gitlab.com", status: "review requested",
                                   isDoneRemotely: false, remoteEstimateSeconds: nil, remoteSpentSeconds: nil,
                                   gitlabProjectID: 8, gitlabIID: 12, lastSeenAt: nine, gitlabKind: .mergeRequest)
        )
        let gitlabDraft = WorklogDraft(taskID: gitlabTask.id, seconds: 2_700, started: nine, hostScope: "https://gitlab.com")
        func gitlab(_ host: String, canLogTime: Bool, _ task: TaskItem? = nil) -> WorklogDrafts.Availability {
            WorklogDrafts.availability(of: gitlabDraft, task: task ?? gitlabTask, jiraHost: "", gitlabHost: host, gitlabCanLogTime: canLogTime)
        }
        XCTAssertEqual(gitlab("https://gitlab.com", canLogTime: true), .ready)
        XCTAssertEqual(gitlab("https://gitlab.com", canLogTime: false), .readOnly, "a read_api token: Keep local only")
        XCTAssertEqual(gitlab("https://git.example.com", canLogTime: true), .notConnected)
        var withoutProject = gitlabTask
        withoutProject.remote?.gitlabProjectID = nil
        XCTAssertEqual(gitlab("https://gitlab.com", canLogTime: true, withoutProject), .missingDetails)
    }

    // MARK: - The card

    func testTheCardAsksInPlainWords() {
        XCTAssertEqual(WorklogDrafts.headline(seconds: 4_500, key: "PROJ-123"), "Log 1h 15m to PROJ-123?")
        XCTAssertEqual(WorklogDrafts.headline(seconds: 2_700, key: "group/app!12"), "Log 45m to group/app!12?")
        let now = Date()
        let time = now.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(WorklogDrafts.caption(started: now, now: now, source: .jira), "started today \(time) · Jira")
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(WorklogDrafts.caption(started: yesterday, now: now, source: .gitlab),
                       "started yesterday \(yesterday.formatted(date: .omitted, time: .shortened)) · GitLab")
        XCTAssertTrue(WorklogDrafts.isOpen(.awaiting) && WorklogDrafts.isOpen(.failed) && WorklogDrafts.isOpen(.sending))
        XCTAssertFalse(WorklogDrafts.isOpen(.keptLocal))
    }
}
