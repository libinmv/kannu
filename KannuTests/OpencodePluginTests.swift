//
//  OpencodePluginTests.swift
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

import JavaScriptCore
import XCTest

/// Runs Kannu's opencode plugin in JavaScriptCore with a fake `Bun.spawn`, so the event mapping
/// and the "argv array, never awaited, never throws" rules are pinned without opencode installed.
final class OpencodePluginTests: XCTestCase {
    private let script = "/Users/u/.config/opencode/kannu-agent-status.sh"

    /// The plugin as a classic script (JavaScriptCore evaluates no ES modules), a recording
    /// `Bun.spawn`, and a minimal `Blob`.
    private func makeContext(spawnThrows: Bool = false) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail("JavaScript threw: \(exception?.toString() ?? "?")") }
        context.evaluateScript("""
        var calls = [];
        function Blob(parts) { this.parts = parts; }
        var Bun = { spawn: function (argv, options) {
            if (\(spawnThrows ? "true" : "false")) { throw new Error("spawn failed"); }
            calls.push({ argv: argv, payload: JSON.parse(options.stdin.parts.join("")), stdout: options.stdout, stderr: options.stderr });
            return {};
        } };
        """)
        let source = OpencodePluginSource.source(scriptPath: script)
        let classic = source.replacingOccurrences(of: "export { KannuAgentStatus };", with: "")
        context.evaluateScript(classic)
        context.evaluateScript("var hooks = null; KannuAgentStatus({ directory: '/work/app' }).then(function (h) { hooks = h; });")
        XCTAssertTrue(context.evaluateScript("hooks !== null").toBool(), "the factory resolved")
        return context
    }

    private func calls(_ context: JSContext) -> [[String: Any]] {
        (context.evaluateScript("calls").toArray() as? [[String: Any]]) ?? []
    }

    func testPluginEvaluatesAndExportsTheFactory() throws {
        let source = OpencodePluginSource.source(scriptPath: script)
        XCTAssertTrue(source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("export { KannuAgentStatus };"))
        XCTAssertTrue(source.contains(OpencodePluginSource.versionMarker))
        XCTAssertTrue(source.contains("const KANNU_SCRIPT = \"\(script)\";"), "the script path is baked in as a string literal")
        XCTAssertFalse(source.contains("__KANNU_SCRIPT_PATH__"))
        let context = try makeContext()
        XCTAssertEqual(context.evaluateScript("typeof KannuAgentStatus").toString(), "function")
        for hook in ["event", "chat.message", "tool.execute.before", "tool.execute.after"] {
            XCTAssertEqual(context.evaluateScript("typeof hooks['\(hook)']").toString(), "function", hook)
        }
    }

    func testEventsMapToScriptCalls() throws {
        let context = try makeContext()
        context.evaluateScript("""
        hooks.event({ event: { type: 'session.created', properties: { info: { id: 'ses_1', title: 'Fix login' } } } });
        hooks['chat.message']({ sessionID: 'ses_1' }, { parts: [{ type: 'text', text: 'fix it' }, { type: 'file' }] });
        hooks['tool.execute.before']({ tool: 'read', sessionID: 'ses_1', callID: 'c1' }, { args: { filePath: '/work/app/.env' } });
        hooks['tool.execute.after']({ tool: 'read', sessionID: 'ses_1', callID: 'c1' }, { title: 't', output: 'X=1', metadata: {} });
        hooks.event({ event: { type: 'permission.asked', properties: { id: 'p1', sessionID: 'ses_1' } } });
        hooks.event({ event: { type: 'permission.replied', properties: { sessionID: 'ses_1', requestID: 'p1', reply: 'once' } } });
        hooks.event({ event: { type: 'question.asked', properties: { id: 'q1', sessionID: 'ses_1' } } });
        hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'ses_1' } } });
        hooks.event({ event: { type: 'session.error', properties: { sessionID: 'ses_1' } } });
        hooks.event({ event: { type: 'session.deleted', properties: { info: { id: 'ses_1' } } } });
        hooks.event({ event: { type: 'message.part.updated', properties: {} } });
        """)
        let recorded = calls(context)
        XCTAssertEqual(recorded.map { ($0["argv"] as? [String])?.dropFirst().joined(separator: " ") ?? "" }, [
            "idle opencode SessionStart",
            "thinking opencode UserPromptSubmit",
            "executing opencode PreToolUse",
            "thinking opencode PostToolUse",
            "awaiting_input opencode PermissionRequest",
            "thinking opencode PermissionReplied",
            "awaiting_input opencode PermissionRequest",
            "stopped opencode Stop",
            "stopped opencode StopFailure",
            "session_end opencode SessionEnd",
        ])
        let prompt = try XCTUnwrap(recorded[1]["payload"] as? [String: Any])
        XCTAssertEqual(prompt["session_id"] as? String, "ses_1")
        XCTAssertEqual(prompt["prompt"] as? String, "fix it")
        XCTAssertEqual(prompt["cwd"] as? String, "/work/app")
        XCTAssertEqual(prompt["conversation_title"] as? String, "Fix login")
        let after = try XCTUnwrap(recorded[3]["payload"] as? [String: Any])
        XCTAssertEqual((after["tool_input"] as? [String: Any])?["filePath"] as? String, "/work/app/.env",
                       "the arguments reach the post-tool event, where the sensitive-file check looks")
        XCTAssertEqual(after["tool_use_id"] as? String, "c1")
        XCTAssertEqual(recorded.first?["stdout"] as? String, "ignore")
        XCTAssertEqual(recorded.first?["stderr"] as? String, "ignore")
    }

    func testSubagentSessionsAreSkipped() throws {
        let context = try makeContext()
        context.evaluateScript("""
        hooks.event({ event: { type: 'session.created', properties: { info: { id: 'ses_child', parentID: 'ses_1' } } } });
        hooks['tool.execute.before']({ tool: 'bash', sessionID: 'ses_child', callID: 'c9' }, { args: { command: 'ls' } });
        hooks.event({ event: { type: 'session.idle', properties: { sessionID: 'ses_child' } } });
        """)
        XCTAssertTrue(calls(context).isEmpty, "a subagent's activity belongs to its parent's card")
    }

    func testSpawnGetsAnArgvArrayNeverAShellString() throws {
        let context = try makeContext()
        context.evaluateScript("""
        hooks['chat.message']({ sessionID: 'ses_2' }, { parts: [{ type: 'text', text: '$(rm -rf ~); `id`' }] });
        """)
        let argv = try XCTUnwrap(calls(context).first?["argv"] as? [String])
        XCTAssertEqual(argv, [script, "thinking", "opencode", "UserPromptSubmit"], "the prompt travels on stdin, never in argv")
    }

    func testSpawnFailureIsSwallowed() throws {
        let context = try makeContext(spawnThrows: true)
        context.evaluateScript("""
        var settled = 0;
        hooks.event({ event: { type: 'session.created', properties: { info: { id: 'ses_3' } } } }).then(function () { settled += 1; });
        hooks['tool.execute.before']({ tool: 'bash', sessionID: 'ses_3', callID: 'c' }, { args: {} }).then(function () { settled += 1; });
        """)
        XCTAssertEqual(context.evaluateScript("settled").toInt32(), 2, "status reporting never breaks a session")
    }

    func testNodeAcceptsThePluginAsAModule() throws {
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(node != nil, "node not installed")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kannu-plugin-\(UUID().uuidString).mjs")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(OpencodePluginSource.source(scriptPath: script).utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node!)
        process.arguments = ["--check", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testTheScriptPathIsQuotedSafely() {
        XCTAssertEqual(OpencodePluginSource.javaScriptString("/Users/a \"b\"/x.sh"), #""/Users/a \"b\"/x.sh""#)
    }
}
