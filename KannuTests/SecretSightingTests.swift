//
//  SecretSightingTests.swift
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

/// Secrets the hook saw: parsed defensively, never holding key material, one finding per key.
final class SecretSightingTests: XCTestCase {
    private let t0: Int64 = 1_788_000_000_000

    private func sighting(_ kind: SecretSighting.Kind = .awsAccessKey, _ location: SecretSighting.Location = .prompt,
                          tool: String? = nil, fingerprint: String = "0123456789ab", events: Int = 1,
                          first: Int64? = nil) -> SecretSighting {
        SecretSighting(kind: kind, location: location, tool: tool, prefix: "AKIA", length: 20, fingerprint: fingerprint,
                       eventCount: events, firstSeenMs: first ?? t0, lastSeenMs: first ?? t0)
    }

    func testParsingDropsJunkAndClamps() {
        let value: [Any] = [
            5, "x", ["kind": "nope"],
            ["kind": "aws_access_key", "where": "prompt", "fp": "NOTHEX123456", "first_ts": NSNumber(value: t0)],
            ["kind": "aws_access_key", "where": "somewhere", "fp": "0123456789ab", "first_ts": NSNumber(value: t0)],
            ["kind": "aws_access_key", "where": "prompt", "fp": "0123456789ab", "first_ts": NSNumber(value: 5)],
            ["kind": "github_token", "where": "tool_input", "tool": "Bash;rm", "prefix": "ghp_", "length": 9_999_999,
             "fp": "abcdef012345", "events": 0, "first_ts": NSNumber(value: t0), "last_ts": NSNumber(value: t0 - 5)],
        ]
        let parsed = SecretSighting.list(fromHookValue: value)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].kind, .githubToken)
        XCTAssertEqual(parsed[0].tool, "Bashrm")
        XCTAssertEqual(parsed[0].length, 99_999)
        XCTAssertEqual(parsed[0].eventCount, 1)
        XCTAssertEqual(parsed[0].lastSeenMs, t0, "last seen never precedes first seen")
        XCTAssertTrue(SecretSighting.list(fromHookValue: "junk").isEmpty)
    }

    func testSeverityFollowsWhereTheSecretWent() {
        XCTAssertEqual(sighting(.awsAccessKey, .prompt).severity, .medium, "you pasted it yourself")
        XCTAssertEqual(sighting(.awsAccessKey, .toolInput, tool: "Bash").severity, .high, "a command can send it anywhere")
        XCTAssertEqual(sighting(.awsAccessKey, .toolInput, tool: "mcp__fetch__fetch").severity, .high)
        XCTAssertEqual(sighting(.privateKey, .toolInput, tool: "Write").severity, .medium, "a file edit")
        XCTAssertEqual(sighting(.privateKey, .toolInput, tool: "apply_patch").severity, .medium)
        XCTAssertEqual(sighting(.privateKey, .toolInput, tool: nil).severity, .high)
    }

    func testWordingNeverCarriesKeyMaterial() {
        let prompt = sighting()
        XCTAssertEqual(prompt.title, "A secret in your prompt")
        XCTAssertTrue(prompt.summary(chatName: "Deploy").contains("an AWS access key"))
        XCTAssertEqual(sighting(.githubToken, .toolInput, tool: "Bash").title, "The agent used a secret in a tool call")
        XCTAssertEqual(sighting(.githubToken, .toolInput, tool: "Write").title, "The agent wrote a secret into a file")
        XCTAssertTrue(sighting(events: 3).summary(chatName: "c").hasSuffix("Seen 3 times."))
        let evidence = prompt.evidence(provider: "claude")
        XCTAssertEqual(evidence.count, Set(evidence).count, "distinct lines")
        XCTAssertTrue(evidence[0].contains("AKIA"))
        XCTAssertTrue(evidence[1].contains("0123456789ab"))
        for kind in SecretSighting.Kind.allCases {
            XCTAssertFalse(kind.name.isEmpty)
            XCTAssertFalse(kind.phrase.isEmpty)
        }
    }

    func testOneFindingPerKeyAndPlace() {
        let id = sighting().findingID(conversationID: "c1")
        XCTAssertEqual(sighting(events: 7, first: t0 + 99_000).findingID(conversationID: "c1"), id,
                       "counts and a later re-sighting keep the id")
        XCTAssertNotEqual(sighting(fingerprint: "ffffffffffff").findingID(conversationID: "c1"), id)
        XCTAssertNotEqual(sighting(.awsAccessKey, .toolInput, tool: "Bash").findingID(conversationID: "c1"), id)
        XCTAssertNotEqual(sighting().findingID(conversationID: "c2"), id)
        XCTAssertEqual(sighting().finding(conversationID: "c1", provider: "claude", chatName: "Chat", projectName: nil, cwd: nil).id, id)
    }
}
