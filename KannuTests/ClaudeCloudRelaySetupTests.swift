//
//  ClaudeCloudRelaySetupTests.swift
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

/// What Kannu hands out for a repository and a cloud environment. The repository half is shared
/// with teammates and agents, so it must never carry the relay key; the environment half is the
/// only place the key goes.
final class ClaudeCloudRelaySetupTests: XCTestCase {
    typealias Setup = ClaudeCloudRelaySetup

    private func hookGroups() throws -> [String: [[String: Any]]] {
        let object = try JSONSerialization.jsonObject(with: Data(Setup.hooksJSON().utf8)) as? [String: Any]
        return try XCTUnwrap(object?["hooks"] as? [String: [[String: Any]]])
    }

    func testTheHooksMirrorKannusOwnClaudeTable() throws {
        var rows: [String] = []
        for (event, groups) in try hookGroups() {
            for group in groups {
                let handlers = try XCTUnwrap(group["hooks"] as? [[String: Any]])
                XCTAssertEqual(handlers.count, 1)
                let handler = try XCTUnwrap(handlers.first)
                XCTAssertEqual(handler["type"] as? String, "command")
                XCTAssertEqual(handler["async"] as? Bool, true, "a slow relay must never hold a turn up")
                XCTAssertEqual(handler["timeout"] as? Int, 10)
                let command = try XCTUnwrap(handler["command"] as? String)
                let prefix = "bash \"$CLAUDE_PROJECT_DIR/\(Setup.repositoryPath)\" "
                XCTAssertTrue(command.hasPrefix(prefix), "quoted, so a checkout path with a space still runs: \(command)")
                rows.append("\(event)|\(group["matcher"] as? String ?? "")|" + command.dropFirst(prefix.count))
            }
        }
        let expected = AgentHookLayout.claudeHookEntries.map { entry in
            "\(entry.event)|\(entry.matcher ?? "")|\(entry.state) \(entry.event)"
                + (entry.matcher == nil ? "" : " \(entry.matcherKey)")
        }
        XCTAssertEqual(rows.sorted(), expected.sorted())
    }

    func testThePromptCarriesTheScriptAndHooksButNeverAKey() {
        let prompt = Setup.repositoryPrompt()
        XCTAssertTrue(prompt.contains(Setup.scriptSource))
        XCTAssertTrue(prompt.contains(Setup.hooksJSON()))
        XCTAssertTrue(prompt.contains(Setup.repositoryPath))
        XCTAssertTrue(prompt.contains("Do not add any key, secret or environment variable to the repository"))
        XCTAssertNil(prompt.range(of: "[0-9a-f]{64}", options: .regularExpression), "no relay key")
        XCTAssertNil(prompt.range(of: "kannu-[0-9a-f]{32}", options: .regularExpression), "no topic either")
    }

    func testEnvironmentLinesAreDotEnvSafe() {
        let secret = String(repeating: "ab", count: 32)
        XCTAssertEqual(Setup.environmentLines(secret: secret, server: ClaudeCloudRelay.defaultServerURL),
                       "KANNU_RELAY_SECRET=\(secret)\n", "the default relay needs no URL line")
        XCTAssertEqual(Setup.environmentLines(secret: secret, server: ""), "KANNU_RELAY_SECRET=\(secret)\n")
        let custom = Setup.environmentLines(secret: secret, server: " https://relay.example.com/ntfy \n")
        XCTAssertEqual(custom, "KANNU_RELAY_SECRET=\(secret)\nKANNU_RELAY_URL=https://relay.example.com/ntfy\n")
        for line in custom.split(separator: "\n") {
            XCTAssertNotNil(line.range(of: #"^[A-Z_]+=[^\s"'#$`\\]+$"#, options: .regularExpression),
                            "nothing a .env parser would quote, expand or cut: \(line)")
        }
    }

    func testTheAllowlistHostIsTheServersHost() {
        XCTAssertEqual(Setup.allowlistHost(server: ClaudeCloudRelay.defaultServerURL), "ntfy.sh")
        XCTAssertEqual(Setup.allowlistHost(server: " https://Relay.Example.com/ntfy "), "relay.example.com")
        XCTAssertNil(Setup.allowlistHost(server: ""))
    }

    /// The script and the parser are two programs in two languages; these are the facts they share.
    func testTheScriptSpeaksTheParsersVocabulary() throws {
        let source = Setup.scriptSource
        XCTAssertTrue(source.contains("\nVERSION = \(ClaudeCloudRelay.protocolVersion)\n"))
        XCTAssertTrue(source.contains("\nREFRESH_MS = \(Setup.refreshIntervalMs)\n"))
        XCTAssertTrue(source.contains("# " + Setup.scriptVersionMarker + "\n"))
        XCTAssertTrue(source.contains("\"kind\": \"kannu-cloud\""))
        XCTAssertTrue(source.contains("DEFAULT_URL = \"\(ClaudeCloudRelay.defaultServerURL)\""))
        XCTAssertEqual(try pythonSet("STATES", in: source), ClaudeCloudRelay.states)
        XCTAssertEqual(try pythonSet("EVENTS", in: source).union(["Check"]), ClaudeCloudRelay.events)
        XCTAssertEqual(try pythonSet("NOTES", in: source).union([""]), ClaudeCloudRelay.notes)
        XCTAssertTrue(Set(AgentHookLayout.claudeHookEntries.map(\.event)).isSubset(of: try pythonSet("EVENTS", in: source)))
    }

    private func pythonSet(_ name: String, in source: String) throws -> Set<String> {
        let pattern = "\n\(name) = \\{([^}]*)\\}"
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                                  "\(name) not found in the script")
        let body = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
        let items = try NSRegularExpression(pattern: "\"([^\"]*)\"")
            .matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
        return Set(items)
    }
}
