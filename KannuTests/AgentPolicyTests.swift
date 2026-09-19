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

    // MARK: - Import: the one write, validated first

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kannu-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testImportCopiesAValidFileByteForByteAndCreatesTheFolder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("picked.json")
        // Odd spacing on purpose: the write is the picked bytes verbatim, never a re-serialisation.
        let bytes = Data(#"{ "version": 1,  "block": [ {"command": "ssh"} ] }"#.utf8)
        try bytes.write(to: source)
        let destination = dir.appendingPathComponent("nested/deeper/agent-policy.json")
        let policy = try AgentPolicy.importPolicy(from: source, to: destination).get()
        XCTAssertEqual(policy.rules, [.init(command: "ssh", tool: nil, reason: nil)])
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testImportOfAnInvalidFileWritesNothingAndKeepsTheExistingPolicy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("agent-policy.json")
        let existing = Data(#"{"version": 1, "block": [{"tool": "WebFetch"}]}"#.utf8)
        try existing.write(to: destination)
        let bad = dir.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: bad)
        XCTAssertEqual(AgentPolicy.importPolicy(from: bad, to: destination), .failure(.notJSON))
        XCTAssertEqual(try Data(contentsOf: destination), existing, "a failed import must not touch the existing file")
        // A missing pick and a directory pick are refused the same way.
        XCTAssertEqual(AgentPolicy.importPolicy(from: dir.appendingPathComponent("gone.json"), to: destination), .failure(.unreadable))
        XCTAssertEqual(AgentPolicy.importPolicy(from: dir, to: destination), .failure(.unreadable))
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    func testImportRefusesAnOversizeFileBySizeAlone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = dir.appendingPathComponent("big.json")
        try Data(repeating: UInt8(ascii: " "), count: AgentPolicy.maxBytes + 1).write(to: big)
        let destination = dir.appendingPathComponent("agent-policy.json")
        guard case .failure(.tooLarge) = AgentPolicy.importPolicy(from: big, to: destination) else {
            return XCTFail("an oversize pick must be refused")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// A valid pick whose destination cannot be written says so — not "could not be read", which
    /// would blame the file the user chose.
    func testAnUnwritableDestinationIsReportedAsSuch() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("good.json")
        try Data(#"{"version": 1, "block": [{"command": "ssh"}]}"#.utf8).write(to: source)
        // A regular file where the destination's folder should be: the write cannot succeed.
        let blocker = dir.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let destination = blocker.appendingPathComponent("agent-policy.json")
        XCTAssertEqual(AgentPolicy.importPolicy(from: source, to: destination), .failure(.notWritten))
    }

    func testImportReplacesAnExistingPolicy() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let destination = dir.appendingPathComponent("agent-policy.json")
        try Data(#"{"version": 1, "block": [{"tool": "WebFetch"}]}"#.utf8).write(to: destination)
        let source = dir.appendingPathComponent("new.json")
        try Data(#"{"version": 1, "block": [{"command": "scp"}]}"#.utf8).write(to: source)
        let policy = try AgentPolicy.importPolicy(from: source, to: destination).get()
        XCTAssertEqual(policy.rules, [.init(command: "scp", tool: nil, reason: nil)])
        XCTAssertEqual(try AgentPolicy.load(at: destination).get().rules, policy.rules)
    }

    /// The View-rules box renders from these; a rule with both keys absent cannot exist past
    /// the parser, so the fallbacks are belt and braces.
    func testRuleDisplayHelpers() {
        XCTAssertEqual(AgentPolicy.Rule(command: "rm -rf /", tool: nil, reason: nil).displayTitle, "rm -rf /")
        XCTAssertEqual(AgentPolicy.Rule(command: "ssh", tool: nil, reason: nil).displayIconName, "terminal")
        XCTAssertEqual(AgentPolicy.Rule(command: nil, tool: "WebFetch", reason: nil).displayTitle, "WebFetch")
        XCTAssertEqual(AgentPolicy.Rule(command: nil, tool: "WebFetch", reason: nil).displayIconName, "wrench.and.screwdriver")
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
        let errors: [AgentPolicy.LoadError] = [.notFound, .unreadable, .notWritten, .notJSON, .tooLarge(70_000), .notAnObject, .version,
                                               .tooManyRules(201), .rule(3, "x"), .notARegularFile, .byteOrderMark, .notUTF8,
                                               .trailingComma, .duplicateKey("block")]
        for error in errors { XCTAssertFalse(error.message.isEmpty, "\(error)") }
        XCTAssertTrue(AgentPolicy.LoadError.rule(3, "x").message.contains("Rule 4"))
        XCTAssertTrue(AgentPolicy.LoadError.duplicateKey("block").message.contains("\"block\""))
        // Only a duplicate key is a file the hook still reads; Settings must not say it is ignored.
        XCTAssertEqual(errors.filter { !$0.hookIgnoresFile }, [.duplicateKey("block")])
    }

    // MARK: - Parity with the hook's load_policy
    //
    // Each case below is one way `JSONSerialization` or Swift's string handling was more lenient
    // than the hook's Python, so Settings counted rules the hook was ignoring. The same bytes go
    // through the real hook in HookScriptTests.testSettingsAndTheHookAgreeOnWhatIsAPolicy.

    func testATrailingCommaIsRefusedAsTheHookRefusesIt() {
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh"},]}"#), .failure(.trailingComma))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh"}],}"#), .failure(.trailingComma))
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh",}]}"#), .failure(.trailingComma))
        XCTAssertEqual(parse("{\"version\": 1, \"block\": [{\"command\": \"ssh\"}\n,\n]}"), .failure(.trailingComma), "whitespace between")
        // Inside a string a comma and a bracket are only text, escaped quote or not.
        XCTAssertEqual(try parse(#"{"version": 1, "block": [{"command": "ssh", "reason": "no ,] here, \",} either"}]}"#).get().rules.count, 1)
    }

    func testARepeatedKeyIsRefusedRatherThanGuessedAt() {
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh"}], "block": []}"#), .failure(.duplicateKey("block")))
        XCTAssertEqual(parse(#"{"version": 1, "block": [], "block": []}"#), .failure(.duplicateKey("block")), "compared decoded")
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh", "command": "scp"}]}"#), .failure(.duplicateKey("command")))
        // The same key in two different objects is not a repeat.
        XCTAssertEqual(try parse(#"{"version": 1, "block": [{"command": "ssh"}, {"command": "scp"}]}"#).get().rules.count, 2)
    }

    func testTheEncodingMustBePlainUTF8() {
        let valid = #"{"version": 1, "block": [{"command": "ssh"}]}"#
        XCTAssertEqual(AgentPolicy.parse(Data([0xEF, 0xBB, 0xBF]) + Data(valid.utf8)), .failure(.byteOrderMark))
        XCTAssertEqual(AgentPolicy.parse(valid.data(using: .utf16)!), .failure(.notUTF8), "JSONSerialization reads UTF-16; the hook does not")
        XCTAssertEqual(AgentPolicy.parse(valid.data(using: .utf32)!), .failure(.notUTF8))
        XCTAssertEqual(AgentPolicy.parse(Data(valid.utf8.prefix(20)) + Data([0xFF]) + Data(valid.utf8.dropFirst(20))), .failure(.notUTF8))
    }

    func testTheVersionIsComparedAsANumberAsPythonComparesIt() {
        XCTAssertNoThrow(try parse(#"{"version": 1.0, "block": []}"#).get())
        XCTAssertEqual(parse(#"{"version": 1.5, "block": []}"#), .failure(.version), "intValue truncated this to 1")
    }

    func testAnEmptyReasonIsNoReason() throws {
        let policy = try parse(#"{"version": 1, "block": [{"command": "ssh", "reason": ""}]}"#).get()
        XCTAssertEqual(policy.rules, [.init(command: "ssh", tool: nil, reason: nil)])
    }

    func testTheLengthCapCountsCodePointsAsPythonCounts() {
        // 150 characters on screen, 300 code points: each "é" is e + a combining accent.
        let heavy = String(repeating: "e\u{301}", count: 150)
        XCTAssertEqual(heavy.count, 150)
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": "ssh", "reason": "\#(heavy)"}]}"#),
                       .failure(.rule(0, "\"reason\" must be text of at most \(AgentPolicy.maxLength) characters")))
    }

    func testWhitespaceMeansUnicodeWhitespaceAsItDoesToTheHook() {
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"command": " "}]}"#),
                       .failure(.rule(0, "\"command\" must be a word or phrase of at most \(AgentPolicy.maxLength) characters")),
                       "a no-break space alone is no word to Python's split()")
        XCTAssertEqual(parse(#"{"version": 1, "block": [{"tool": "WebFetch "}]}"#),
                       .failure(.rule(0, "\"tool\" must be one name of at most \(AgentPolicy.maxLength) characters")),
                       "Python's strip() removes a line separator; CharacterSet.whitespaces does not")
    }

    func testASymlinkIsNoPolicyBecauseTheHookReadsOnlyARegularFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentPolicyTests-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles-policy.json")
        try Data(#"{"version": 1, "block": [{"command": "ssh"}]}"#.utf8).write(to: real)
        let link = dir.appendingPathComponent("agent-policy.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(AgentPolicy.load(at: link), .failure(.notARegularFile))
        XCTAssertEqual(try AgentPolicy.load(at: real).get().rules.count, 1)
    }
}
