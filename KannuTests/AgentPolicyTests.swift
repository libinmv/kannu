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

/// The policy file's shape and caps, as Settings reports them. Matching is the hook's alone and
/// is pinned in `HookScriptTests`; nothing here decides what a rule matches.
final class AgentPolicyTests: XCTestCase {
    private func parse(_ json: String) -> Result<AgentPolicy, AgentPolicy.LoadError> {
        AgentPolicy.parse(Data(json.utf8))
    }

    func testAValidFileParsesEveryRuleShape() throws {
        let policy = try parse(#"{"version": 1, "block": [{"command": "ssh", "reason": "Servers are off limits."}, {"command": "rm -rf /"}, {"tool": "WebFetch"}]}"#).get()
        XCTAssertEqual(policy.rules.count, 3)
        XCTAssertEqual(policy.rules[0], .init(command: "ssh", tool: nil, reason: "Servers are off limits."))
        XCTAssertEqual(policy.rules[1], .init(command: "rm -rf /", tool: nil, reason: nil))
        XCTAssertEqual(policy.rules[2], .init(command: nil, tool: "WebFetch", reason: nil))
        // null is absent for every key — the hook reads it the same way (HookScriptTests).
        let nulls = try parse(#"{"version": 1, "block": [{"command": "ssh", "reason": null}, {"command": null, "tool": "WebFetch", "reason": null}]}"#).get()
        XCTAssertEqual(nulls.rules, [.init(command: "ssh", tool: nil, reason: nil), .init(command: nil, tool: "WebFetch", reason: nil)])
    }

    func testEveryWayAFileIsIgnoredHasAReason() {
        XCTAssertEqual(parse("not json"), .failure(.notJSON))
        XCTAssertEqual(parse("[]"), .failure(.notAnObject))
        XCTAssertEqual(parse(#"{"version": 2, "block": []}"#), .failure(.version))
        XCTAssertEqual(parse(#"{"version": true, "block": []}"#), .failure(.version))
        XCTAssertEqual(parse(#"{"version": 1}"#), .failure(.notAnObject))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{}]}"#), .failure(.rule(0, "needs \"command\" or \"tool\"")))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh", "tool": "Bash"}]}"#),
                       .failure(.rule(0, "use \"command\" or \"tool\", not both")))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh"}, "ssh"]}"#), .failure(.rule(1, "each rule is an object")))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "   "}]}"#).mapError { $0 }, parse(#"{"version": 1, "block": [{"command": ""}]}"#))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"tool": "Web Fetch"}]}"#),
                       .failure(.rule(0, "\"tool\" must be one name of at most 200 characters")))
        let tooLong = String(repeating: "x", count: 201)
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "\#(tooLong)"}]}"#),
                       .failure(.rule(0, "\"command\" must be a word or phrase of at most 200 characters")))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh", "reason": 7}]}"#),
                       .failure(.rule(0, "\"reason\" must be text of at most 200 characters")))
        let many = "[" + Array(repeating: #"{"command": "ssh"}"#, count: 201).joined(separator: ",") + "]"
        XCTAssertEqual(parse(#"{"version": 1, "block": \#(many)}"#), .failure(.tooManyRules(201)))
        let big = #"{"version": 1, "block": [{"command": "ssh", "reason": ""# + String(repeating: "y", count: 70_000) + #""}]}"#
        XCTAssertEqual(parse(big), .failure(.tooLarge(big.utf8.count)))
    }

    func testLoadReportsAMissingFileAndADirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kannu-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(AgentPolicy.load(at: directory.appendingPathComponent("missing.json")), .failure(.notFound))
        XCTAssertEqual(AgentPolicy.load(at: directory), .failure(.unreadable))
        let file = directory.appendingPathComponent("agent-policy.json")
        try Data(#"{"version": 1, "block": [{"tool": "WebFetch"}]}"#.utf8).write(to: file)
        XCTAssertEqual(try AgentPolicy.load(at: file).get().rules.count, 1)
    }

    func testTheDraftingPromptStatesTheFormatAndTheCaps() {
        let prompt = AgentPolicy.draftingPrompt
        XCTAssertTrue(prompt.contains("~/.kannu/agent-policy.json"))
        XCTAssertTrue(prompt.contains(#""version": 1"#))
        XCTAssertTrue(prompt.contains("no regex"))
        XCTAssertTrue(prompt.contains("200 rules"))
        XCTAssertTrue(prompt.contains("64 KB"))
        XCTAssertTrue(prompt.contains("Ask me"))
    }

    func testEveryLoadErrorHasWords() {
        let errors: [AgentPolicy.LoadError] = [.notFound, .unreadable, .notJSON, .tooLarge(70_000), .notAnObject, .version,
                                               .tooManyRules(201), .rule(3, "x")]
        for error in errors { XCTAssertFalse(error.message.isEmpty, "\(error)") }
        XCTAssertTrue(AgentPolicy.LoadError.rule(3, "x").message.contains("Rule 4"))
    }
}
