//
//  SensitivePathSightingTests.swift
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

/// Sensitive files the hook saw an agent touch: parsed defensively, graded, one finding per path.
final class SensitivePathSightingTests: XCTestCase {
    private let t0: Int64 = 1_788_000_000_000

    private func sighting(_ category: SensitivePathSighting.Category = .sshKey, _ access: SensitivePathSighting.Access = .read,
                          path: String = "~/.ssh/id_ed25519", failed: Bool = false, events: Int = 1) -> SensitivePathSighting {
        SensitivePathSighting(category: category, access: access, path: path, tool: "Bash", failed: failed,
                              eventCount: events, firstSeenMs: t0, lastSeenMs: t0)
    }

    func testParsingDropsJunkAndSanitises() {
        let value: [Any] = [
            ["category": "ssh_key", "access": "read", "path": "", "first_ts": NSNumber(value: t0)],
            ["category": "made_up", "access": "read", "path": "~/x", "first_ts": NSNumber(value: t0)],
            ["category": "ssh_key", "access": "sideways", "path": "~/x", "first_ts": NSNumber(value: t0)],
            ["category": "autorun", "access": "write", "path": "~/Library/LaunchAgents/é.plist" + String(repeating: "a", count: 300),
             "failed": "yes", "first_ts": NSNumber(value: t0)],
        ]
        let parsed = SensitivePathSighting.list(fromHookValue: value)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].path.count, SensitivePathSighting.pathLimit)
        XCTAssertFalse(parsed[0].path.contains("é"), "printable ASCII only")
        XCTAssertFalse(parsed[0].failed, "only a literal true counts")
    }

    func testSeverity() {
        XCTAssertEqual(sighting(.sshKey).severity, .high)
        XCTAssertEqual(sighting(.keychain).severity, .high)
        XCTAssertEqual(sighting(.autorun, .write).severity, .high)
        XCTAssertEqual(sighting(.envFile, path: "/p/.env").severity, .medium)
        XCTAssertEqual(sighting(.shellHistory, path: "~/.zsh_history").severity, .medium)
        XCTAssertEqual(sighting(.agentConfig, .write, path: "/p/.claude/settings.json").severity, .high)
        XCTAssertEqual(sighting(.agentConfig, .write, path: "/p/.vscode/settings.json").severity, .medium)
    }

    func testTitlesAndEvidence() {
        XCTAssertEqual(sighting().title, "The agent read an SSH private key")
        XCTAssertEqual(sighting(failed: true).title, "The agent tried to read an SSH private key")
        XCTAssertEqual(sighting(.shellStartup, .write, path: "~/.zshrc").title, "The agent changed a shell startup file")
        XCTAssertEqual(sighting(.autorun, .write, failed: true).title, "The agent tried to change something that runs on its own")
        for category in SensitivePathSighting.Category.allCases {
            for access in SensitivePathSighting.Access.allCases {
                let s = sighting(category, access)
                XCTAssertFalse(s.title.isEmpty)
                XCTAssertEqual(s.evidence(provider: "claude").count, Set(s.evidence(provider: "claude")).count)
            }
        }
        XCTAssertTrue(sighting().summary(chatName: "Chat").contains("~/.ssh/id_ed25519"))
        XCTAssertTrue(sighting(events: 2).summary(chatName: "Chat").hasSuffix("Seen 2 times."))
        XCTAssertTrue(sighting(failed: true).evidence(provider: "codex").contains { $0.contains("the call failed") })
    }

    func testOneFindingPerPathAndAccess() {
        let id = sighting().findingID(conversationID: "c1")
        XCTAssertEqual(sighting(failed: true, events: 9).findingID(conversationID: "c1"), id)
        XCTAssertNotEqual(sighting(.sshKey, .write).findingID(conversationID: "c1"), id)
        XCTAssertNotEqual(sighting(path: "~/.ssh/id_rsa").findingID(conversationID: "c1"), id)
    }
}
