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
        let records = HookSightingRecords().upserting([session], enabled: .init())
        XCTAssertEqual(records.hiddenText.count, 1)
        XCTAssertEqual(records.findings.count, 1)
        XCTAssertEqual(HookSightingRecords().upserting([session], enabled: .init(hiddenText: false)), HookSightingRecords(),
                       "a check that is off records nothing")
        let data = try JSONEncoder().encode(records)
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: data), records)
        let unreadable = Data(#"{"hiddenText":[{"nonsense":1}],"futureKind":[]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: unreadable), HookSightingRecords(),
                       "an unreadable list starts empty instead of failing the whole value")
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: Data("{}".utf8)), HookSightingRecords())
    }

    private func secret(first: Int64) -> SecretSighting {
        SecretSighting(kind: .awsAccessKey, location: .prompt, tool: nil, prefix: "AKIA", length: 20,
                       fingerprint: "0123456789ab", eventCount: 1, firstSeenMs: first, lastSeenMs: first)
    }

    private func path(first: Int64) -> SensitivePathSighting {
        SensitivePathSighting(category: .sshKey, access: .read, path: "~/.ssh/id_ed25519", tool: "Read", failed: false,
                              eventCount: 1, firstSeenMs: first, lastSeenMs: first)
    }

    func testEveryKindParsesUnionsAndPersists() throws {
        let json: [String: Any] = [
            "secrets": [["kind": "aws_access_key", "where": "prompt", "prefix": "AKIA", "length": 20, "fp": "0123456789ab",
                         "first_ts": NSNumber(value: t0)]],
            "sensitive_paths": [["category": "ssh_key", "access": "read", "path": "~/.ssh/id_ed25519", "tool": "Read",
                                 "first_ts": NSNumber(value: t0)]],
        ]
        let parsed = HookSightings(hookFile: json)
        XCTAssertEqual(parsed.secrets.count, 1)
        XCTAssertEqual(parsed.sensitivePaths.count, 1)
        XCTAssertFalse(parsed.isEmpty)
        let union = HookSightings.union(HookSightings(secrets: [secret(first: t0)]), HookSightings(sensitivePaths: [path(first: t0)]))
        XCTAssertEqual(union.secrets, [secret(first: t0)])
        XCTAssertEqual(union.sensitivePaths, [path(first: t0)])

        var session = AgentSessionStatus(id: "codex-a", provider: "codex", conversationID: "a", chatName: "Chat", projectName: "p",
                                         rawState: "executing", displayState: .executing, updatedAt: Date(timeIntervalSince1970: 1_000),
                                         isVisible: true, executionStartedAt: nil, cwd: "/p", hostPID: nil)
        session.sightings = union
        let records = HookSightingRecords().upserting([session], enabled: .init())
        XCTAssertEqual(records.secrets.count, 1)
        XCTAssertEqual(records.sensitivePaths.count, 1)
        XCTAssertEqual(records.findings.count, 2)
        let onlyPaths = HookSightingRecords().upserting([session], enabled: .init(secrets: false))
        XCTAssertTrue(onlyPaths.secrets.isEmpty)
        XCTAssertEqual(records.keepingOnly(.init(sensitivePaths: false)).sensitivePaths, [])
        XCTAssertEqual(records.keepingOnly(.init(sensitivePaths: false)).secrets, records.secrets)
        let data = try JSONEncoder().encode(records)
        XCTAssertEqual(try JSONDecoder().decode(HookSightingRecords.self, from: data), records)
        // One unreadable list never takes the others with it.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["secrets"] = [["nonsense": true]]
        let damaged = try JSONDecoder().decode(HookSightingRecords.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(damaged.secrets.isEmpty)
        XCTAssertEqual(damaged.sensitivePaths, records.sensitivePaths)
    }

    func testTerminalLocatorRidesTheSeamAsSelfOrSource() {
        var withTerminal = AgentSessionStatus(id: "codex-a", provider: "codex", conversationID: "a", chatName: "Chat", projectName: "p",
                                              rawState: "executing", displayState: .executing, updatedAt: Date(timeIntervalSince1970: 1_000),
                                              isVisible: true, executionStartedAt: nil, cwd: nil, hostPID: nil)
        withTerminal.terminal = TerminalLocator(tty: "/dev/ttys004", sessionLeaderPID: 4242, sessionLeaderStart: 1_788_000_000)
        var bare = withTerminal
        bare.terminal = nil
        XCTAssertEqual(bare.carryingExtras(from: withTerminal).terminal, withTerminal.terminal)
        XCTAssertEqual(withTerminal.withDisplayState(.stopped, visible: true).terminal, withTerminal.terminal)
        var other = withTerminal
        other.terminal = TerminalLocator(tty: "/dev/ttys009", sessionLeaderPID: 99)
        XCTAssertEqual(other.carryingExtras(from: withTerminal).terminal?.tty, "/dev/ttys009", "self wins")
    }
}
