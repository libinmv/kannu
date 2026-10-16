//
//  TaskModelCodingTests.swift
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

/// `tasks.json` has to read back exactly, read a file a newer Kannu wrote, and read a file an
/// older one wrote. A file that fails to decode is moved aside and the list starts empty, so a
/// decode that is stricter than it needs to be costs the user their task list.
final class TaskModelCodingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func sampleFile() -> TasksFile {
        let draftID = UUID()
        let local = TaskItem(
            title: "Write the release notes",
            localEstimateSeconds: 7200,
            segments: [
                WorkSegment(start: start, end: start.addingTimeInterval(1500), origin: .timer),
                WorkSegment(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(4200), origin: .manual),
            ],
            createdAt: start
        )
        let remote = TaskItem(
            source: .jira,
            title: "Fix the login redirect",
            remote: RemoteTaskInfo(
                remoteID: "10042", key: "PROJ-123", hostScope: "acme.atlassian.net", status: "In Progress",
                isDoneRemotely: false, remoteEstimateSeconds: 14400, remoteSpentSeconds: 3600,
                gitlabProjectID: nil, gitlabIID: nil, lastSeenAt: start
            ),
            segments: [WorkSegment(start: start, end: start.addingTimeInterval(900), origin: .timer, draftID: draftID)],
            logPolicy: .ask,
            visibility: .active,
            createdAt: start
        )
        let draft = WorklogDraft(id: draftID, taskID: remote.id, seconds: 900, started: start, hostScope: "acme.atlassian.net")
        return TasksFile(tasks: [local, remote], drafts: [draft])
    }

    func testAFileReadsBackExactly() throws {
        let file = sampleFile()
        let data = try TasksFile.makeEncoder().encode(file)
        XCTAssertEqual(try TasksFile.makeDecoder().decode(TasksFile.self, from: data), file)
    }

    func testAnUnknownFutureFieldIsTolerated() throws {
        let file = sampleFile()
        let data = try TasksFile.makeEncoder().encode(file)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["syncCursor"] = "abc"
        var tasks = try XCTUnwrap(json["tasks"] as? [[String: Any]])
        tasks[0]["priority"] = 3
        var segments = try XCTUnwrap(tasks[0]["segments"] as? [[String: Any]])
        segments[0]["note"] = "pairing"
        tasks[0]["segments"] = segments
        json["tasks"] = tasks
        let edited = try JSONSerialization.data(withJSONObject: json)

        XCTAssertEqual(try TasksFile.makeDecoder().decode(TasksFile.self, from: edited), file,
                       "a field a newer Kannu added is ignored, and nothing else is lost")
    }

    func testAnOlderFileWithoutTheNewerFieldsReads() throws {
        let id = UUID()
        let json = """
        {"version": 1, "tasks": [{"id": "\(id.uuidString)", "title": "Old task"}]}
        """
        let decoded = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
        let task = try XCTUnwrap(decoded.tasks.first)
        XCTAssertEqual(task.id, id)
        XCTAssertEqual(task.source, .local)
        XCTAssertEqual(task.segments, [])
        XCTAssertEqual(task.logPolicy, .ask)
        XCTAssertEqual(task.visibility, .active)
        XCTAssertEqual(decoded.drafts, [])
    }

    func testAGitLabTaskReadsBackExactly() throws {
        let mergeRequest = TaskItem(
            source: .gitlab,
            title: "Fix the redirect",
            remote: RemoteTaskInfo(
                remoteID: "mr:31", key: "group/app!12", hostScope: "https://gitlab.example.com", status: "review requested",
                isDoneRemotely: false, remoteEstimateSeconds: 1800, remoteSpentSeconds: nil,
                gitlabProjectID: 8, gitlabIID: 12, lastSeenAt: start, gitlabKind: .mergeRequest,
                gitlabWebURL: "https://gitlab.example.com/group/app/-/merge_requests/12",
                statusCategory: "indeterminate", labels: ["bug"],
                weight: 3, milestone: "Sprint 42", dueDate: start, assignee: "Dana Example",
                parentTitle: "Login epic", priority: "High", issueType: "Bug",
                updatedAt: start, commentCount: 4, checklistDone: 1, checklistTotal: 3, linkedMergeRequests: 2,
                iteration: "Iteration 5", healthStatus: "on_track", isDraft: true, hasConflicts: false, author: "Kim Lee"
            ),
            createdAt: start
        )
        let file = TasksFile(tasks: [mergeRequest], drafts: [])
        let data = try TasksFile.makeEncoder().encode(file)
        XCTAssertEqual(try TasksFile.makeDecoder().decode(TasksFile.self, from: data), file)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""gitlabKind" : "mergeRequest""#))
        // A property left out of CodingKeys is silently never written: every standard fact is.
        for key in ["weight", "milestone", "dueDate", "assignee", "parentTitle", "priority", "issueType",
                    "updatedAt", "commentCount", "checklistDone", "checklistTotal", "linkedMergeRequests",
                    "iteration", "healthStatus", "isDraft", "hasConflicts", "author"] {
            XCTAssertTrue(text.contains("\"\(key)\" :"), "\(key) is not written to the file")
        }
    }

    func testAFileWrittenBeforeGitLabStillReads() throws {
        // The Jira task exactly as the previous version wrote it: no gitlabKind, no gitlabWebURL.
        let id = UUID()
        let json = """
        {"version": 1, "tasks": [{"id": "\(id.uuidString)", "source": "jira", "title": "Fix the login redirect",
          "remote": {"remoteID": "10042", "key": "PROJ-123", "hostScope": "acme.atlassian.net", "status": "In Progress",
                     "isDoneRemotely": false, "remoteEstimateSeconds": 14400, "lastSeenAt": "2026-10-04T10:00:00Z"}}]}
        """
        let decoded = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
        let remote = try XCTUnwrap(decoded.tasks.first?.remote)
        XCTAssertEqual(remote.key, "PROJ-123")
        XCTAssertNil(remote.gitlabKind, "the default")
        XCTAssertNil(remote.gitlabWebURL)
        XCTAssertNil(remote.gitlabProjectID)
        XCTAssertNil(remote.remoteSpentSeconds)
        XCTAssertNil(remote.weight, "the standard facts came later still")
        XCTAssertNil(remote.dueDate)
        XCTAssertNil(remote.assignee)
    }

    func testADayDateIsTheStartOfThatDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RemoteTaskInfo.dayDate("2026-10-20", calendar: calendar), Date(timeIntervalSince1970: 1_792_454_400))
        XCTAssertNil(RemoteTaskInfo.dayDate(nil, calendar: calendar))
        XCTAssertNil(RemoteTaskInfo.dayDate("", calendar: calendar))
        XCTAssertNil(RemoteTaskInfo.dayDate("2026-13-01", calendar: calendar), "no thirteenth month")
        XCTAssertNil(RemoteTaskInfo.dayDate("2026-10-20T10:00:00Z", calendar: calendar), "date-only, as both servers send it")
    }

    func testServerTimestampsInBothServersShapes() {
        let expected = Date(timeIntervalSince1970: 1_792_141_954.567)   // 2026-10-16T09:12:34.567Z
        let gitlab = RemoteTaskInfo.serverTimestamp("2026-10-16T09:12:34.567Z")
        XCTAssertEqual(gitlab?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001)
        let jira = RemoteTaskInfo.serverTimestamp("2026-10-16T14:42:34.567+0530")
        XCTAssertEqual(jira?.timeIntervalSince1970 ?? 0, expected.timeIntervalSince1970, accuracy: 0.001,
                       "Jira's offset has no colon")
        XCTAssertEqual(RemoteTaskInfo.serverTimestamp("2026-10-16T09:12:34Z")?.timeIntervalSince1970 ?? 0,
                       1_792_141_954, accuracy: 0.001, "no fractions")
        XCTAssertNil(RemoteTaskInfo.serverTimestamp("yesterday"))
        XCTAssertNil(RemoteTaskInfo.serverTimestamp(nil))
    }

    func testAKindFromANewerKannuDoesNotCostTheFile() throws {
        let id = UUID()
        let json = """
        {"version": 1, "tasks": [{"id": "\(id.uuidString)", "source": "gitlab", "title": "An epic",
          "remote": {"remoteID": "epic:9", "key": "group&9", "hostScope": "https://gitlab.com", "status": "opened",
                     "isDoneRemotely": false, "lastSeenAt": "2026-10-04T10:00:00Z", "gitlabKind": "epic"}}]}
        """
        let decoded = try TasksFile.makeDecoder().decode(TasksFile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.tasks.count, 1)
        XCTAssertNil(decoded.tasks.first?.remote?.gitlabKind, "an unknown kind reads as nil, the rest of the file survives")
    }

    func testTheLocalEstimateWinsOverTheRemoteOne() {
        var task = sampleFile().tasks[1]
        XCTAssertEqual(task.effectiveEstimateSeconds, 14400)
        task.localEstimateSeconds = 3600
        XCTAssertEqual(task.effectiveEstimateSeconds, 3600)
    }

    func testAnOpenSegmentAtLoadIsInterruptedAndCountsForNothing() {
        var file = sampleFile()
        file.tasks[0].segments.append(WorkSegment(start: start.addingTimeInterval(5000), origin: .timer))
        XCTAssertEqual(file.markOpenSegmentsInterrupted(), 1)
        let segment = file.tasks[0].segments[2]
        XCTAssertEqual(segment.origin, .recovered)
        XCTAssertNil(segment.end, "Kannu never guesses when the work ended")
        XCTAssertTrue(segment.isInterrupted)
        XCTAssertEqual(file.tasks[0].segments[0].origin, .timer, "closed segments are untouched")
        XCTAssertEqual(TaskTimeMath.seconds(of: segment, now: start.addingTimeInterval(99_999)), 0)
        XCTAssertEqual(file.markOpenSegmentsInterrupted(), 0, "already marked")
    }

    func testATaskTitleIsOneCleanLine() {
        XCTAssertEqual(TaskItem.cleanedTitle("  Review   PR \n 42 "), "Review PR 42")
        XCTAssertNil(TaskItem.cleanedTitle(" \n\t "))
        XCTAssertEqual(TaskItem.cleanedTitle(String(repeating: "a", count: 500))?.count, TaskItem.maxTitleLength)
    }
}
