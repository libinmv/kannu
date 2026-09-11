//
//  HookSightingsTests.swift
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

/// The container every hook-side check shares: parsing, the union across reconstruction seams,
/// and persisted records that survive a kind they cannot read.
final class HookSightingsTests: XCTestCase {
    private let t0: Int64 = 1_788_000_000_000

    private func incident(first: Int64, last: Int64? = nil) -> HiddenTextIncident {
        HiddenTextIncident(kind: .tags, location: .toolResult, tool: "Read", characterCount: 12, eventCount: 1,
                           preview: "hello", firstSeenMs: first, lastSeenMs: last ?? first)
    }

    func testParsesEachKindFromTheStatusFile() {
        let json: [String: Any] = ["hidden_text": [["kind": "tags", "where": "tool_result", "first_ts": NSNumber(value: t0),
                                                    "preview": "hi"]]]
        XCTAssertEqual(HookSightings(hookFile: json).hiddenText.count, 1)
        XCTAssertTrue(HookSightings(hookFile: [:]).isEmpty)
        XCTAssertTrue(HookSightings(hookFile: ["hidden_text": "junk"]).isEmpty)
    }

    func testUnionIsPerKindAndEmptyIsTheIdentity() {
        let a = HookSightings(hiddenText: [incident(first: t0)])
        let b = HookSightings(hiddenText: [incident(first: t0 + 5)])
        XCTAssertEqual(HookSightings.union(a, HookSightings()), a)
        XCTAssertEqual(HookSightings.union(HookSightings(), a), a)
        XCTAssertEqual(HookSightings.union(a, b).hiddenText.map(\.firstSeenMs), [t0, t0 + 5])
    }

    func testRecordsRoundTripAndSurviveAnUnreadableList() throws {
        var session = AgentSessionStatus(id: "claude-a", provider: "claude", conversationID: "a", chatName: "Chat", projectName: "p",
                                         rawState: "executing", displayState: .executing, updatedAt: Date(timeIntervalSince1970: 1_000),
                                         isVisible: true, executionStartedAt: nil, cwd: "/p", hostPID: nil)
        session.sightings.hiddenText = [incident(first: t0)]
        let records = HookSightingRecords().upserting([session], includeHiddenText: true)
        XCTAssertEqual(records.hiddenText.count, 1)
        XCTAssertEqual(records.findings.count, 1)
        XCTAssertEqual(HookSightingRecords().upserting([session], includeHiddenText: false), HookSightingRecords(),
                       "a check that is off records nothing")
        let data = try JSONEncoder().encode(records)
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: data), records)
        let unreadable = Data(#"{"hiddenText":[{"nonsense":1}],"futureKind":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: unreadable), HookSightingRecords(),
                       "an unreadable list starts empty instead of failing the whole value")
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: Data("{}".utf8)), HookSightingRecords())
    }
}
