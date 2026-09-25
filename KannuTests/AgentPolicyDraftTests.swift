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

/// The rule editor's model and its Save. Validity is `AgentPolicy.parse` throughout, so these pin
/// what the editor does with a file, not what counts as a policy (AgentPolicyTests, and the
/// differential test in HookScriptTests, pin that).
final class AgentPolicyDraftTests: XCTestCase {
    private static let sample = Data(#"{"version": 1, "block": [{"command": "ssh", "reason": "Servers are off limits."}, {"tool": "WebFetch"}]}"#.utf8)

    private func draft(_ json: String) -> AgentPolicyDraft? { AgentPolicyDraft(fileBytes: Data(json.utf8)) }

    func testAFileRoundTripsToTheSameRules() throws {
        let draft = try XCTUnwrap(AgentPolicyDraft(fileBytes: Self.sample))
        XCTAssertEqual(draft.rows.map(\.kind), [.command, .tool])
        XCTAssertEqual(draft.rows.map(\.text), ["ssh", "WebFetch"])
        XCTAssertEqual(draft.rows.map(\.reason), ["Servers are off limits.", ""])
        XCTAssertNil(draft.problem)
        XCTAssertEqual(try AgentPolicy.parse(draft.fileBytes()).get(), try AgentPolicy.parse(Self.sample).get())
    }

    func testNoFileIsAnEmptyDraftAndABrokenFileIsNoDraft() {
        let empty = AgentPolicyDraft(fileBytes: nil)
        XCTAssertEqual(empty?.rows.count, 0)
        XCTAssertNil(empty?.original)
        XCTAssertNil(draft(#"{"version": 1, "block": [{"command": "ssh"},]}"#), "the editor must not save over a file it cannot read")
        XCTAssertNil(draft("not json"))
    }

    func testWhatTheUserWroteByHandSurvivesASave() throws {
        var edited = try XCTUnwrap(draft(#"{"version": 1, "note": "team policy", "block": [{"command": "ssh", "ticket": "SEC-12"}]}"#))
        edited.rows[0].reason = "No servers"
        edited.addRow()
        edited.rows[1].text = "scp"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: edited.fileBytes()) as? [String: Any])
        XCTAssertEqual(object["note"] as? String, "team policy", "a top-level key is kept")
        let block = try XCTUnwrap(object["block"] as? [[String: Any]])
        XCTAssertEqual(block[0]["ticket"] as? String, "SEC-12", "a rule's own key is kept")
        XCTAssertEqual(block[0]["reason"] as? String, "No servers")
        XCTAssertEqual(block[1]["command"] as? String, "scp")
    }

    func testAnEmptyReasonIsLeftOutAndSwitchingKindMovesTheText() throws {
        var edited = try XCTUnwrap(AgentPolicyDraft(fileBytes: Self.sample))
        edited.rows[0].reason = ""
        edited.rows[0].kind = .tool
        edited.rows[0].text = "Bash"
        let block = try XCTUnwrap((JSONSerialization.jsonObject(with: edited.fileBytes()) as? [String: Any])?["block"] as? [[String: Any]])
        XCTAssertEqual(block[0].keys.sorted(), ["tool"], "no reason key, no stale command key")
        XCTAssertEqual(block[0]["tool"] as? String, "Bash")
    }

    func testABlankRowIsLeftOutRatherThanBlockingSave() throws {
        var edited = try XCTUnwrap(AgentPolicyDraft(fileBytes: Self.sample))
        edited.addRow()
        XCTAssertNil(edited.problem, "an unused + does not block Save")
        XCTAssertEqual(try AgentPolicy.parse(edited.fileBytes()).get().rules.count, 2)
    }

    func testAProblemNamesTheRowTheUserSees() throws {
        var edited = try XCTUnwrap(AgentPolicyDraft(fileBytes: Self.sample))
        edited.rows.insert(.init(), at: 0)                     // blank, shown first, not saved
        edited.rows[2] = .init(kind: .tool, text: "Web Fetch")  // third on screen, second saved
        XCTAssertEqual(edited.problem, AgentPolicy.LoadError.rule(2, "\"tool\" must be one name of at most \(AgentPolicy.maxLength) characters").message)
        XCTAssertTrue(edited.problem?.hasPrefix("Rule 3") == true)
        edited.rows[2].text = "WebFetch"
        XCTAssertNil(edited.problem)
        // A reason with no rule to hang on is not blank, so it is refused, not dropped.
        edited.rows[0].reason = "why?"
        XCTAssertTrue(edited.problem?.hasPrefix("Rule 1") == true)
    }

    func testTheCapsSurfaceTheParsersWords() {
        var many = AgentPolicyDraft(fileBytes: nil)!
        for index in 0...AgentPolicy.maxRules { many.rows.append(.init(text: "cmd\(index)")) }
        XCTAssertEqual(many.problem, AgentPolicy.LoadError.tooManyRules(AgentPolicy.maxRules + 1).message)
    }

    // MARK: - Save

    private func temporaryPolicy() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgentPolicyDraftTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("agent-policy.json")
    }

    func testSaveWritesWhatTheEditorShowsAndCreatesTheFile() throws {
        let url = try temporaryPolicy()
        var fresh = AgentPolicyDraft(fileBytes: nil)!
        fresh.rows = [.init(text: "ssh")]
        guard case .saved(let policy) = AgentPolicy.save(fresh.fileBytes(), expecting: nil, to: url) else { return XCTFail("not saved") }
        XCTAssertEqual(policy.rules.map(\.displayTitle), ["ssh"])
        XCTAssertEqual(try AgentPolicy.load(at: url).get(), policy)
    }

    func testSaveRefusesWhenTheFileChangedWhileEditingUnlessTheUserReplaces() throws {
        let url = try temporaryPolicy()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.sample.write(to: url)
        var edited = try XCTUnwrap(AgentPolicyDraft(fileBytes: Self.sample))
        edited.rows[0].text = "scp"
        let theirs = Data(#"{"version": 1, "block": [{"command": "rm -rf /"}]}"#.utf8)
        try theirs.write(to: url)   // someone saved meanwhile
        XCTAssertEqual(AgentPolicy.save(edited.fileBytes(), expecting: edited.original, to: url), .changedOnDisk)
        XCTAssertEqual(try Data(contentsOf: url), theirs, "nothing written on a conflict")
        guard case .saved = AgentPolicy.save(edited.fileBytes(), expecting: edited.original, ignoringChanges: true, to: url) else {
            return XCTFail("Replace should write")
        }
        XCTAssertEqual(try AgentPolicy.load(at: url).get().rules.first?.displayTitle, "scp")
    }

    func testSaveNeverWritesAnInvalidDraft() throws {
        let url = try temporaryPolicy()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.sample.write(to: url)
        var edited = try XCTUnwrap(AgentPolicyDraft(fileBytes: Self.sample))
        edited.rows[1].text = "Web Fetch"
        guard case .failed(.rule) = AgentPolicy.save(edited.fileBytes(), expecting: edited.original, to: url) else { return XCTFail() }
        XCTAssertEqual(try Data(contentsOf: url), Self.sample)
    }
}
