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
